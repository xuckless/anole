//! The HTTP/2 engine's wakes on the real zio, one executor: a handler
//! waiting for its stream's body must never take a wake meant for the
//! connection's writer (57fdfa9's lost wake). The core's own HTTP/2 tests
//! run on std.Io.Threaded, whose futex wake order is the OS's; zio's is
//! FIFO per bucket, so here the order of the waiters is known and a wake of
//! one goes to whoever waited first. Run on both engines: the nghttp2 one
//! (a writer task, until M6) and the one that serves (no writer task; each
//! stream waits on its own `room`, PLAN §3.3).
const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");
const c = @import("anole_nghttp2_c");
const wait = @import("anole_test_wait");

const h2_nghttp2 = dusty.h2_nghttp2_for_tests;

/// POST /body: says it is about to read, then reads the whole body and
/// answers with its length. On one executor the flag is seen only once the
/// handler has gone to sleep in its first read: nothing yields in between.
var body_waiting: std.atomic.Value(bool) = .init(false);
fn readBody(req: *dusty.Request, res: *dusty.Response) !void {
    body_waiting.store(true, .release);
    var buf: [256]u8 = undefined;
    var body = try req.reader(&buf);
    var n: usize = 0;
    while (true) {
        const chunk = body.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return body.err orelse error.Unexpected,
        };
        n += chunk.len;
        body.interface.toss(chunk.len);
    }
    try res.print(.text, "{d}", .{n});
}

/// GET /live: a parked response whose bursts come from the test's task.
var parked: ?*dusty.Parked = null;
var parked_opened: std.Io.Event = .unset;
fn live(req: *dusty.Request, res: *dusty.Response) !void {
    try res.header("Content-Type", "text/event-stream");
    parked = try res._park(req, .{ .gone = struct {
        fn gone(_: *anyopaque) void {}
    }.gone, .ctx = @ptrCast(&parked) });
    parked_opened.set(req.io);
}

fn hello(_: *dusty.Request, res: *dusty.Response) !void {
    res.body = "hello";
}

/// The nghttp2 engine writer's waits (`h2_nghttp2.test_before_writer_wait`).
var writer_waits: std.atomic.Value(u32) = .init(0);
fn countWriterWait(_: std.Io) void {
    _ = writer_waits.fetchAdd(1, .release);
}

/// A plain nghttp2 client over one connection with a few streams.
const Client = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,
    read_buf: [16 * 1024]u8 = undefined,
    write_buf: [16 * 1024]u8 = undefined,
    session: ?*c.nghttp2_session = null,
    resps: [4]Resp = @splat(.{}),
    used: usize = 0,
    ping_acks: u32 = 0,

    const Resp = struct {
        status: u16 = 0,
        body: [256]u8 = undefined,
        body_len: usize = 0,
        closed: bool = false,
        /// The request body, sent once `send_ready`; until then the
        /// request side stays open with nothing sent.
        send: []const u8 = "",
        send_ready: bool = false,

        fn got(r: *const Resp) []const u8 {
            return r.body[0..r.body_len];
        }
    };

    fn init(self: *Client, io: std.Io, addr: std.Io.net.IpAddress) !void {
        self.* = .{ .io = io, .stream = try addr.connect(io, .{ .mode = .stream }), .reader = undefined, .writer = undefined };
        self.reader = self.stream.reader(io, &self.read_buf);
        self.writer = self.stream.writer(io, &self.write_buf);
        var cbs: ?*c.nghttp2_session_callbacks = null;
        _ = c.nghttp2_session_callbacks_new(&cbs);
        defer c.nghttp2_session_callbacks_del(cbs);
        c.nghttp2_session_callbacks_set_on_header_callback(cbs, onHeader);
        c.nghttp2_session_callbacks_set_on_data_chunk_recv_callback(cbs, onData);
        c.nghttp2_session_callbacks_set_on_stream_close_callback(cbs, onClose);
        c.nghttp2_session_callbacks_set_on_frame_recv_callback(cbs, onFrame);
        if (c.nghttp2_session_client_new(&self.session, cbs, self) != 0) return error.Http2Init;
        if (c.nghttp2_submit_settings(self.session, c.NGHTTP2_FLAG_NONE, null, 0) != 0) return error.Http2Init;
    }

    fn deinit(self: *Client) void {
        c.nghttp2_session_del(self.session);
        self.stream.close(self.io);
    }

    /// Submits a request; `body` keeps the request side open (with a
    /// data provider that has nothing until `sendBody`).
    fn request(self: *Client, method: []const u8, path: []const u8, body: bool) !*Resp {
        const nva = [_]c.nghttp2_nv{ nv(":method", method), nv(":path", path), nv(":scheme", "http"), nv(":authority", "localhost") };
        const resp = &self.resps[self.used];
        self.used += 1;
        var provider: c.nghttp2_data_provider2 = .{ .source = .{ .ptr = resp }, .read_callback = provide };
        const id = c.nghttp2_submit_request2(self.session, null, &nva, nva.len, if (body) &provider else null, resp);
        if (id < 0) return error.Http2Submit;
        return resp;
    }

    /// Sends `bytes` as the whole body of `resp`'s open request.
    fn sendBody(self: *Client, resp: *Resp, id: i32, bytes: []const u8) void {
        resp.send = bytes;
        resp.send_ready = true;
        _ = c.nghttp2_session_resume_data(self.session, id);
    }

    fn flushSession(self: *Client) !void {
        while (true) {
            var data: [*c]const u8 = undefined;
            const n = c.nghttp2_session_mem_send2(self.session, &data);
            if (n < 0) return error.Http2Send;
            if (n == 0) break;
            try self.writer.interface.writeAll(data[0..@intCast(n)]);
        }
        try self.writer.interface.flush();
    }

    fn pumpUntil(self: *Client, done: *const fn (*Client) bool) !void {
        while (true) {
            try self.flushSession();
            if (done(self)) return;
            const r = &self.reader.interface;
            const bytes = try r.peekGreedy(1);
            const rv = c.nghttp2_session_mem_recv2(self.session, bytes.ptr, bytes.len);
            if (rv < 0) return error.Http2Recv;
            r.toss(@intCast(rv));
        }
    }

    /// `pumpUntil` as its own task, bounded by `wait.deadline()`: a server
    /// that never gets there fails as a named wait instead of a read that
    /// never returns (as src/websocket/h2_test.zig's client).
    fn pump(self: *Client, comptime what: []const u8, done: *const fn (*Client) bool) !void {
        var finished: std.Io.Event = .unset;
        var task = try self.io.concurrent(struct {
            fn run(cl: *Client, d: *const fn (*Client) bool, ev: *std.Io.Event) anyerror!void {
                defer ev.set(cl.io);
                try cl.pumpUntil(d);
            }
        }.run, .{ self, done, &finished });
        wait.waitEvent(self.io, what, &finished) catch |err| {
            task.cancel(self.io) catch {};
            return err;
        };
        try task.await(self.io);
    }

    fn nv(name: []const u8, value: []const u8) c.nghttp2_nv {
        return .{ .name = @constCast(name.ptr), .namelen = name.len, .value = @constCast(value.ptr), .valuelen = value.len, .flags = c.NGHTTP2_NV_FLAG_NONE };
    }

    fn respOf(session: ?*c.nghttp2_session, id: i32) ?*Resp {
        const ptr = c.nghttp2_session_get_stream_user_data(session, id) orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn onHeader(session: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, name: [*c]const u8, namelen: usize, value: [*c]const u8, valuelen: usize, _: u8, _: ?*anyopaque) callconv(.c) c_int {
        const resp = respOf(session, frame.*.hd.stream_id) orelse return 0;
        if (std.mem.eql(u8, name[0..namelen], ":status")) resp.status = std.fmt.parseInt(u16, value[0..valuelen], 10) catch 0;
        return 0;
    }

    fn onData(session: ?*c.nghttp2_session, _: u8, id: i32, data: [*c]const u8, len: usize, _: ?*anyopaque) callconv(.c) c_int {
        const resp = respOf(session, id) orelse return 0;
        const n = @min(len, resp.body.len - resp.body_len);
        @memcpy(resp.body[resp.body_len..][0..n], data[0..n]);
        resp.body_len += n;
        return 0;
    }

    fn onFrame(_: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, user: ?*anyopaque) callconv(.c) c_int {
        const self: *Client = @ptrCast(@alignCast(user.?));
        if (frame.*.hd.type == c.NGHTTP2_PING and frame.*.hd.flags & c.NGHTTP2_FLAG_ACK != 0) self.ping_acks += 1;
        return 0;
    }

    fn onClose(session: ?*c.nghttp2_session, id: i32, _: u32, _: ?*anyopaque) callconv(.c) c_int {
        const resp = respOf(session, id) orelse return 0;
        resp.closed = true;
        return 0;
    }

    fn provide(_: ?*c.nghttp2_session, _: i32, buf: [*c]u8, length: usize, flags: [*c]u32, source: [*c]c.nghttp2_data_source, _: ?*anyopaque) callconv(.c) c.nghttp2_ssize {
        const resp: *Resp = @ptrCast(@alignCast(source.*.ptr.?));
        if (!resp.send_ready) return c.NGHTTP2_ERR_DEFERRED;
        const n = @min(resp.send.len, length);
        @memcpy(buf[0..n], resp.send[0..n]);
        resp.send = resp.send[n..];
        if (resp.send.len == 0) flags.* |= c.NGHTTP2_DATA_FLAG_EOF;
        return @intCast(n);
    }
};

test "HTTP/2 on zio: a handler waiting for its body never takes the writer's wake; a parked burst, a PING and a GET all go out first" {
    try run(.anole);
}

test "HTTP/2 on zio: a handler waiting for its body never takes the writer's wake (nghttp2 engine)" {
    try run(.nghttp2);
}

fn run(comptime engine: enum { anole, nghttp2 }) !void {
    // With one wake per kick, the waiters on the writer's word were the
    // writer and every handler waiting for its stream's first DATA frame,
    // in the order they went to sleep. The PING below makes the writer go
    // back to sleep behind the waiting handler, so the next lone kick (a
    // parked burst from another task, which kicks once) woke the handler,
    // which found nothing and slept again, and the burst sat until the
    // client sent something (57fdfa9). Either order of the two fails that
    // engine: the PING's own kick goes to the handler when it is first.
    // The new engine has no writer task: there the PING's ACK is the sync
    // point, and the burst, the GET and the body must still all go out.
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    body_waiting.store(false, .monotonic);
    parked = null;
    parked_opened = .unset;
    if (engine == .nghttp2) h2_nghttp2.test_before_writer_wait = countWriterWait;
    defer if (engine == .nghttp2) {
        h2_nghttp2.test_before_writer_wait = null;
    };

    var server = dusty.Server(void).init(gpa, io, .{
        .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } }, .http2_prior_knowledge = true }},
    }, {});
    defer server.deinit();
    server.test_h2_engine = switch (engine) {
        .anole => .anole,
        .nghttp2 => .nghttp2,
    };
    server.router.post("/body", readBody);
    server.router.get("/live", live);
    server.router.get("/hello", hello);
    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};
    try server.waitReady(io);

    var client: Client = undefined;
    try client.init(io, server.address.ip);
    defer client.deinit();

    // The parked stream, its head out: its data provider has deferred, so
    // a burst resumes it and kicks the writer once.
    const live_resp = try client.request("GET", "/live", false);
    try client.pump("the parked response's head", struct {
        fn f(cl: *Client) bool {
            return cl.resps[0].status != 0;
        }
    }.f);
    try wait.waitEvent(io, "the handler parked", &parked_opened);
    const p = parked.?;
    // A failed check below must not leave the connection's teardown
    // waiting for the park's release.
    var ended = false;
    defer {
        if (!ended) if (p.begin()) p.end();
        p.release();
    }
    try std.testing.expectEqual(@as(u16, 200), live_resp.status);

    // A request whose body has not started: its handler sleeps in its first
    // read, waiting for the first DATA frame.
    const body_resp = try client.request("POST", "/body", true);
    try client.flushSession();
    try wait.waitFlag(io, "the body handler waits for its first DATA frame", &body_waiting);

    // A PING: the reader kicks once, and the writer answers, then sleeps
    // again (behind the waiting handler, in FIFO order).
    const waits = writer_waits.load(.acquire);
    _ = c.nghttp2_submit_ping(client.session, c.NGHTTP2_FLAG_NONE, null);
    try client.flushSession();
    if (engine == .nghttp2) try wait.waitUntil(io, "the writer answered the PING and went back to sleep", waits, struct {
        fn f(before: u32) bool {
            return writer_waits.load(.acquire) > before;
        }
    }.f);
    try client.pump("the PING's ACK", struct {
        fn f(cl: *Client) bool {
            return cl.ping_acks >= 1;
        }
    }.f);

    // A burst from this task, not the connection's: one kick.
    try std.testing.expect(p.begin());
    try p.write(&.{"data: a\n\n"});
    p.endBurst();
    try client.pump("the parked burst", struct {
        fn f(cl: *Client) bool {
            return cl.resps[0].body_len >= "data: a\n\n".len;
        }
    }.f);
    try std.testing.expectEqualStrings("data: a\n\n", live_resp.got());

    // Another stream's answer, while the handler still waits.
    const hello_resp = try client.request("GET", "/hello", false);
    try client.pump("the GET's answer", struct {
        fn f(cl: *Client) bool {
            return cl.resps[2].closed;
        }
    }.f);
    try std.testing.expectEqualStrings("hello", hello_resp.got());
    try std.testing.expect(!body_resp.closed);

    // Then the body: the waiting handler reads it and answers.
    client.sendBody(body_resp, 3, "abcdefg");
    try client.pump("the body handler's answer", struct {
        fn f(cl: *Client) bool {
            return cl.resps[1].closed;
        }
    }.f);
    try std.testing.expectEqual(@as(u16, 200), body_resp.status);
    try std.testing.expectEqualStrings("7", body_resp.got());

    ended = true;
    try std.testing.expect(p.begin());
    p.end();
    try client.pump("the parked stream's end", struct {
        fn f(cl: *Client) bool {
            return cl.resps[0].closed;
        }
    }.f);
}
