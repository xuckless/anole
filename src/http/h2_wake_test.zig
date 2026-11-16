//! The HTTP/2 engine's wakes on the real zio, one executor: a handler
//! waiting for its stream's body must never take a wake meant for the
//! connection's writer (57fdfa9's lost wake). The core's own HTTP/2 tests
//! run on std.Io.Threaded, whose futex wake order is the OS's; zio's is
//! FIFO per bucket, so here the order of the waiters is known and a wake of
//! one goes to whoever waited first. The engine has no writer task: each
//! stream waits on its own `room` (PLAN §3.3), and a PING's ACK is the sync
//! point.
const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");
const wait = @import("anole_test_wait");

const conn = dusty.h2_core_for_tests.conn;
const tc = dusty.h2_core_for_tests.test_client;

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

/// A plain client over one connection with a few streams, on the core's
/// client role (h2/test_client.zig); it is its own `Conn` handler.
const Client = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,
    read_buf: [16 * 1024]u8 = undefined,
    write_buf: [16 * 1024]u8 = undefined,
    cn: CC = undefined,
    scratch: []u8 = &.{},
    rx: tc.Rx = .{},
    arena: std.heap.ArenaAllocator,
    resps: [4]Resp = @splat(.{}),
    used: usize = 0,
    ping_acks: u32 = 0,

    const CC = conn.Conn(.client, Client);

    const Resp = struct {
        id: u31 = 0,
        status: u16 = 0,
        body: [256]u8 = undefined,
        body_len: usize = 0,
        closed: bool = false,
        /// The request body: nothing is sent until `sendBody`, and the
        /// request side stays open until then.
        src: tc.Source = .{ .keep_open = true },
        has_body: bool = false,

        fn got(r: *const Resp) []const u8 {
            return r.body[0..r.body_len];
        }
    };

    fn init(self: *Client, gpa: std.mem.Allocator, io: std.Io, addr: std.Io.net.IpAddress) !void {
        self.* = .{ .io = io, .gpa = gpa, .stream = try addr.connect(io, .{ .mode = .stream }), .reader = undefined, .writer = undefined, .arena = .init(gpa) };
        self.reader = self.stream.reader(io, &self.read_buf);
        self.writer = self.stream.writer(io, &self.write_buf);
        self.scratch = try tc.scratch(gpa, tc.default_options);
        try self.cn.initAt(gpa, self, tc.default_options);
    }

    fn deinit(self: *Client) void {
        self.cn.deinit();
        self.rx.deinit(self.gpa);
        self.arena.deinit();
        self.gpa.free(self.scratch);
        self.stream.close(self.io);
    }

    /// Submits a request; `body` keeps the request side open (nothing is
    /// sent until `sendBody`).
    fn request(self: *Client, method: []const u8, path: []const u8, body: bool) !*Resp {
        const hdrs = [_]tc.Field{ tc.nv(":method", method), tc.nv(":path", path), tc.nv(":scheme", "http"), tc.nv(":authority", "localhost") };
        const resp = &self.resps[self.used];
        self.used += 1;
        resp.has_body = body;
        const s = try self.cn.submitRequest(&hdrs, !body, resp);
        resp.id = s.id;
        return resp;
    }

    /// Sends `bytes` as the whole body of `resp`'s open request.
    fn sendBody(_: *Client, resp: *Resp, bytes: []const u8) void {
        resp.src.data = bytes;
        resp.src.keep_open = false;
    }

    fn flushSession(self: *Client) !void {
        for (self.resps[0..self.used]) |*r| {
            if (!r.has_body or r.closed) continue;
            if (self.cn.table.get(r.id)) |s| try r.src.poll(self.arena.allocator(), &self.cn, s);
        }
        try tc.writePending(&self.cn, &self.writer.interface);
        try self.writer.interface.flush();
    }

    fn pumpUntil(self: *Client, done: *const fn (*Client) bool) !void {
        while (true) {
            try self.flushSession();
            if (done(self)) return;
            const r = &self.reader.interface;
            const bytes = try r.peekGreedy(1);
            try self.rx.feed(self.gpa, &self.cn, bytes, self.scratch);
            r.toss(bytes.len);
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

    fn respOf(s: *conn.Stream) *Resp {
        return @ptrCast(@alignCast(s.user.?));
    }

    pub fn onHeadRefused(_: *Client, _: *conn.Stream) void {}

    pub fn onField(_: *Client, s: *conn.Stream, name: []const u8, value: []const u8) conn.Error!void {
        if (std.mem.eql(u8, name, ":status")) respOf(s).status = std.fmt.parseInt(u16, value, 10) catch 0;
    }

    pub fn onHeadersEnd(_: *Client, _: *conn.Stream, _: bool) conn.Error!void {}

    pub fn onData(h: *Client, s: *conn.Stream, bytes: []const u8, _: bool) conn.Error!void {
        const resp = respOf(s);
        const n = @min(bytes.len, resp.body.len - resp.body_len);
        @memcpy(resp.body[resp.body_len..][0..n], bytes[0..n]);
        resp.body_len += n;
        h.cn.consumed(s, bytes.len) catch @panic("OOM");
    }

    pub fn onStreamClose(_: *Client, s: *conn.Stream, _: conn.ErrorCode) void {
        respOf(s).closed = true;
    }

    pub fn onWindow(_: *Client, _: ?*conn.Stream) void {}

    pub fn onGoaway(_: *Client, _: u31, _: conn.ErrorCode) void {}

    pub fn onPingAck(h: *Client, _: [8]u8) void {
        h.ping_acks += 1;
    }
};

test "HTTP/2 on zio: a handler waiting for its body never takes the writer's wake; a parked burst, a PING and a GET all go out first" {
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

    var server = dusty.Server(void).init(gpa, io, .{
        .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } }, .http2_prior_knowledge = true }},
    }, {});
    defer server.deinit();
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
    try client.init(gpa, io, server.address.ip);
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
    try client.cn.ping(@splat(0));
    try client.flushSession();
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
    client.sendBody(body_resp, "abcdefg");
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
