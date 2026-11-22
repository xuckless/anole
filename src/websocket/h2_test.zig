//! WebSocket over HTTP/2 (RFC 8441), end to end: the core's HTTP/2 engine with
//! an `anole.websocket` echo handler, and a minimal client on the core's own
//! client role that opens an extended CONNECT and speaks masked frames
//! through websocket-zig's client codec. Autobahn has no RFC 8441 mode, so this is the HTTP/2 path's
//! conformance check alongside the codec's own tests.
const std = @import("std");
const test_wait = @import("anole_test_wait");
const zio = @import("zio");
const dusty = @import("dusty");
const h2c = dusty.h2_core_for_tests;
const tc = h2c.test_client;
const wsc = @import("anole_websocket_codec").client;
const websocket = @import("root.zig");
const H2Socket = @import("h2_socket.zig").H2Socket;
const observe = @import("../observe/root.zig");

var saw_draining: std.atomic.Value(bool) = .init(false);
/// The "wait" handler: set by the test once the echo it holds arrived;
/// whether the handler gave up waiting for that (the echo came late).
var wait_release: std.Io.Event = .unset;
var wait_gave_up: std.atomic.Value(bool) = .init(false);

fn echo(req: *dusty.Request, res: *dusty.Response) !void {
    var ws = (try websocket.upgrade(req, res, .{})) orelse {
        res.status = .bad_request;
        return;
    };
    defer ws.deinit();
    try std.testing.expect(ws.httpVersion() != .http1);
    while (true) {
        const msg = ws.receive() catch |err| switch (err) {
            error.ConnectionClosed => return,
            else => |e| return e,
        };
        switch (msg.type) {
            .text, .binary => {
                // A handler that goes off to wait for something with the
                // peer's next message unread (cut short by the server's
                // shutdown, which closes the socket under it).
                // "wait": its echo is held for the batch while the handler
                // waits for the test, which releases it once the echo has
                // arrived (a hang guard aside: `wait_gave_up` says so).
                const wait = std.mem.eql(u8, msg.data, "wait");
                if (wait) {
                    ws.send(msg.type, msg.data) catch return;
                    wait_release.waitTimeout(req.io, .{ .duration = .{ .raw = test_wait.deadline(), .clock = .awake } }) catch |err| switch (err) {
                        error.Timeout => wait_gave_up.store(true, .release),
                        error.Canceled => {},
                    };
                    return;
                }
                try ws.send(msg.type, msg.data);
            },
            .close => {
                saw_draining.store(ws.draining(), .release);
                return;
            },
            else => {},
        }
    }
}

/// One HTTP/2 connection with one extended-CONNECT stream.
const Client = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,
    read_buf: [16 * 1024]u8 = undefined,
    write_buf: [16 * 1024]u8 = undefined,
    gpa: std.mem.Allocator,
    cn: CC = undefined,
    scratch: []u8 = &.{},
    rx: tc.Rx = .{},
    /// What the core refers to until it is framed (the queued frames).
    arena: std.heap.ArenaAllocator,
    stream_id: u31 = 0,
    status: u16 = 0,
    closed: bool = false,
    close_code: u32 = 0,
    /// WebSocket bytes received.
    incoming: [8192]u8 = undefined,
    in_len: usize = 0,
    /// DATA frames received.
    data_frames: usize = 0,
    /// Drop what arrives instead of keeping it in `incoming` (a test that
    /// only waits for the stream to end).
    discard: bool = false,
    /// The server ended its side of the stream (END_STREAM).
    remote_ended: bool = false,
    /// The `origin` header to send, if any.
    origin: ?[]const u8 = null,
    /// The `sec-websocket-protocol` header to send, if any, and what the
    /// answer carried: that header and `x-user`.
    protocols: ?[]const u8 = null,
    answered_protocol: [32]u8 = undefined,
    answered_protocol_len: usize = 0,
    answered_user: [32]u8 = undefined,
    answered_user_len: usize = 0,
    /// The `sec-websocket-extensions` header to send, if any.
    extensions: ?[]const u8 = null,
    path: []const u8 = "/chat",
    /// The answer's `retry-after`, in seconds; 0 for none.
    retry_after: u16 = 0,

    const CC = h2c.conn.Conn(.client, Client);

    fn init(self: *Client, io: std.Io, addr: std.Io.net.IpAddress) !void {
        const gpa = std.testing.allocator;
        self.* = .{ .io = io, .gpa = gpa, .arena = .init(gpa), .stream = try addr.connect(io, .{ .mode = .stream }), .reader = undefined, .writer = undefined };
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

    fn flushSession(self: *Client) !void {
        try tc.writePending(&self.cn, &self.writer.interface);
        try self.writer.interface.flush();
    }

    /// Sends what is pending, then reads until `done` holds.
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

    /// `pumpUntil` bounded by `test_wait.deadline()`: the pump runs as its
    /// own task, so a peer that never gets to `done` fails as a named wait
    /// instead of a read that never returns (the socket has no timeout).
    fn pumpUntilBounded(self: *Client, comptime what: []const u8, done: *const fn (*Client) bool) !void {
        var finished: std.Io.Event = .unset;
        var pump = try self.io.concurrent(struct {
            fn run(cl: *Client, d: *const fn (*Client) bool, ev: *std.Io.Event) anyerror!void {
                defer ev.set(cl.io);
                try cl.pumpUntil(d);
            }
        }.run, .{ self, done, &finished });
        test_wait.waitEvent(self.io, what, &finished) catch |err| {
            pump.cancel(self.io) catch {};
            return err;
        };
        try pump.await(self.io);
    }

    fn open(self: *Client) !void {
        // :protocol goes out only once the server's SETTINGS allow it.
        try self.pumpUntil(struct {
            fn f(cl: *Client) bool {
                return cl.cn.remote.enable_connect_protocol;
            }
        }.f);
        var nva_buf: [8]tc.Field = undefined;
        const base = [_]tc.Field{
            nv(":method", "CONNECT"),
            nv(":protocol", "websocket"),
            nv(":scheme", "http"),
            nv(":path", self.path),
            nv(":authority", "localhost"),
            nv("sec-websocket-version", "13"),
        };
        @memcpy(nva_buf[0..base.len], &base);
        var n: usize = base.len;
        if (self.origin) |o| {
            nva_buf[n] = nv("origin", o);
            n += 1;
        }
        if (self.protocols) |p| {
            nva_buf[n] = nv("sec-websocket-protocol", p);
            n += 1;
        }
        if (self.extensions) |e| {
            nva_buf[n] = nv("sec-websocket-extensions", e);
            n += 1;
        }
        self.stream_id = (try self.cn.submitRequest(nva_buf[0..n], false, null)).id;
        try self.pumpUntil(struct {
            fn f(cl: *Client) bool {
                return cl.status != 0 or cl.closed;
            }
        }.f);
        if (self.status == 0) {
            std.debug.print("stream closed before a response, error code {d}\n", .{self.close_code});
            return error.StreamClosed;
        }
    }

    /// Queues one masked frame on the stream.
    fn sendFrame(self: *Client, opcode: wsc.Opcode, payload: []const u8) !void {
        var buf: [4096 + 16]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        var copy: [4096]u8 = undefined;
        @memcpy(copy[0..payload.len], payload);
        try wsc.writeFrame(&w, copy[0..payload.len], .{ .opcode = opcode });
        try self.queue(w.buffered(), false);
    }

    /// Queues a masked frame of `len` (126..65535) bytes of 'x' under a zero
    /// key, `first` its FIN bit and opcode: a fragment, which `sendFrame`
    /// can't write.
    fn sendRawFrame(self: *Client, first: u8, len: u16) !void {
        var w: std.Io.Writer.Allocating = .init(self.gpa);
        defer w.deinit();
        try w.writer.writeAll(&.{ first, 0x80 | 126 });
        try w.writer.writeInt(u16, len, .big);
        try w.writer.writeAll(&.{ 0, 0, 0, 0 });
        try w.writer.splatByteAll('x', len);
        try self.queue(w.written(), false);
    }

    /// Ends the request side, once what is queued has gone.
    fn finish(self: *Client) !void {
        try self.queue("", true);
    }

    /// A stream the peer has closed takes nothing (as a resumed nghttp2
    /// stream that is gone did not).
    fn queue(self: *Client, bytes: []const u8, end: bool) !void {
        const s = self.cn.table.get(self.stream_id) orelse return;
        try tc.queue(self.arena.allocator(), &self.cn, s, bytes, end);
    }

    /// Whether the core has framed everything queued on the stream.
    fn allFramed(self: *Client) bool {
        const s = self.cn.table.get(self.stream_id) orelse return true;
        return self.cn.unframed(s) == 0;
    }

    /// Sends what is queued on the stream.
    fn sendQueued(self: *Client) !void {
        try self.pumpUntilBounded("the queued frames sent", struct {
            fn f(cl: *Client) bool {
                return cl.allFramed() or cl.closed;
            }
        }.f);
    }

    /// Reads until a whole server frame is in, and returns its payload.
    fn nextFrame(self: *Client, opcode: *wsc.Opcode, out: []u8) ![]u8 {
        while (true) {
            var parser: wsc.Parser = .init(.{});
            var len: usize = 0;
            var used: usize = 0;
            const input = self.incoming[0..self.in_len];
            parse: while (true) {
                const res = try parser.feed(input[used..]);
                used += res.consumed;
                switch (res.event) {
                    .frame_header => |h| opcode.* = h.opcode,
                    .payload => |p| {
                        @memcpy(out[len..][0..p.len], p);
                        len += p.len;
                    },
                    .frame_end => {
                        std.mem.copyForwards(u8, self.incoming[0 .. self.in_len - used], self.incoming[used..self.in_len]);
                        self.in_len -= used;
                        return out[0..len];
                    },
                    .need_more => break :parse,
                }
            }
            // Not whole yet: read more, then parse from the start again.
            if (self.closed) return error.StreamClosed;
            grow_mark = self.in_len;
            try self.pumpUntil(struct {
                fn f(cl: *Client) bool {
                    return cl.in_len > grow_mark or cl.closed;
                }
            }.f);
        }
    }

    var grow_mark: usize = 0;

    fn nv(name: []const u8, value: []const u8) tc.Field {
        return tc.nv(name, value);
    }

    pub fn onHeadRefused(_: *Client, _: *h2c.conn.Stream) void {}

    pub fn onField(self: *Client, _: *h2c.conn.Stream, name: []const u8, value: []const u8) h2c.conn.Error!void {
        if (std.mem.eql(u8, name, ":status")) self.status = std.fmt.parseInt(u16, value, 10) catch 0;
        if (std.mem.eql(u8, name, "retry-after")) self.retry_after = std.fmt.parseInt(u16, value, 10) catch 0;
        if (std.mem.eql(u8, name, "sec-websocket-protocol") and value.len <= self.answered_protocol.len) {
            @memcpy(self.answered_protocol[0..value.len], value);
            self.answered_protocol_len = value.len;
        }
        if (std.mem.eql(u8, name, "x-user") and value.len <= self.answered_user.len) {
            @memcpy(self.answered_user[0..value.len], value);
            self.answered_user_len = value.len;
        }
    }

    pub fn onHeadersEnd(self: *Client, s: *h2c.conn.Stream, end_stream: bool) h2c.conn.Error!void {
        if (s.id == self.stream_id and end_stream) self.remote_ended = true;
    }

    pub fn onData(self: *Client, s: *h2c.conn.Stream, bytes: []const u8, end_stream: bool) h2c.conn.Error!void {
        self.cn.consumed(s, bytes.len) catch @panic("OOM");
        if (s.id == self.stream_id and end_stream) self.remote_ended = true;
        if (self.discard or bytes.len == 0) return;
        @memcpy(self.incoming[self.in_len..][0..bytes.len], bytes);
        self.in_len += bytes.len;
        self.data_frames += 1;
    }

    pub fn onStreamClose(self: *Client, _: *h2c.conn.Stream, code: h2c.conn.ErrorCode) void {
        self.closed = true;
        self.close_code = @backingInt(code);
    }

    pub fn onWindow(_: *Client, _: ?*h2c.conn.Stream) void {}

    pub fn onGoaway(_: *Client, _: u31, _: h2c.conn.ErrorCode) void {}

    pub fn onPingAck(_: *Client, _: [8]u8) void {}
};

test "WebSocket over HTTP/2 (RFC 8441): echo, ping, close; the metrics record the socket as a 101" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();

    var registry = observe.metrics.Registry.init(gpa, io);
    defer registry.deinit();
    var http = try observe.metrics.HttpMetrics.init(&registry, .{});
    var server = dusty.Server(void).init(gpa, io, .{
        .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } }, .http2_prior_knowledge = true }},
        .http2 = .{ .enable_connect_protocol = true },
    }, {});
    defer server.deinit();
    server.router.use(dusty.Middleware(void).init(&http));
    server.router.get("/chat", echo);
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
    try client.open();
    try std.testing.expectEqual(@as(u16, 200), client.status);

    var op: wsc.Opcode = undefined;
    var buf: [256]u8 = undefined;
    try client.sendFrame(.text, "hello over h2");
    try std.testing.expectEqualStrings("hello over h2", try client.nextFrame(&op, &buf));
    try std.testing.expectEqual(wsc.Opcode.text, op);

    try client.sendFrame(.ping, "are you there");
    try std.testing.expectEqualStrings("are you there", try client.nextFrame(&op, &buf));
    try std.testing.expectEqual(wsc.Opcode.pong, op);

    try client.sendFrame(.binary, &.{ 0, 1, 2, 255 });
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 255 }, try client.nextFrame(&op, &buf));
    try std.testing.expectEqual(wsc.Opcode.binary, op);

    // Close 1000: echoed, then the server ends the stream.
    try client.sendFrame(.close, &.{ 0x03, 0xe8 });
    const closing = try client.nextFrame(&op, &buf);
    try std.testing.expectEqual(wsc.Opcode.close, op);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8 }, closing);
    // The closing handshake is done: end our side of the stream (RFC 8441
    // §5 maps the end of the connection to END_STREAM).
    try client.finish();
    try client.pumpUntil(struct {
        fn f(cl: *Client) bool {
            return cl.closed;
        }
    }.f);

    // Recorded as the 101 an HTTP/1.1 upgrade gets, though the stream's
    // answer was a 200 (RFC 8441 §5). The handler's task ends just after the
    // stream does.
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const Recorded = struct {
        registry: *observe.metrics.Registry,
        out: *std.Io.Writer.Allocating,
        fn as101(r: @This()) !bool {
            r.out.clearRetainingCapacity();
            try r.registry.render(&r.out.writer);
            return std.mem.indexOf(u8, r.out.written(), "route=\"/chat\",status=\"101\"} 1") != null;
        }
    };
    try test_wait.waitUntil(io, "the metrics record the stream as a 101", Recorded{ .registry = &registry, .out = &out }, Recorded.as101);
}

test "WebSocket over HTTP/2: a socket carries more than limits.body_max in total" {
    // Regression: the stream's body reader used the request body limit
    // (1 MiB) as a lifetime cap, so a socket died with BodyTooBig after 1 MiB
    // of traffic. Per-message limits apply; the stream has no total limit.
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();

    var server = dusty.Server(void).init(gpa, io, .{
        .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } }, .http2_prior_knowledge = true }},
        .http2 = .{ .enable_connect_protocol = true },
    }, {});
    defer server.deinit();
    server.router.get("/chat", echo);
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
    try client.open();
    try std.testing.expectEqual(@as(u16, 200), client.status);

    var msg: [1024]u8 = undefined;
    var back: [1024 + 64]u8 = undefined;
    var op: wsc.Opcode = undefined;
    // 1536 x 1 KiB = 1.5 MiB, past the default body_max of 1 MiB.
    for (0..1536) |i| {
        @memset(&msg, @truncate(i));
        try client.sendFrame(.binary, &msg);
        const got = try client.nextFrame(&op, &back);
        try std.testing.expectEqual(wsc.Opcode.binary, op);
        try std.testing.expectEqualSlices(u8, &msg, got);
    }

    try client.sendFrame(.close, &.{ 0x03, 0xe8 });
    _ = try client.nextFrame(&op, &back);
    try std.testing.expectEqual(wsc.Opcode.close, op);
    try client.finish();
    try client.pumpUntil(struct {
        fn f(cl: *Client) bool {
            return cl.closed;
        }
    }.f);
}

test "WebSocket over HTTP/2: the drain closes an open socket with 1001 and does not wait out timeout.shutdown" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    saw_draining.store(false, .release);

    var server = dusty.Server(void).init(gpa, io, .{
        .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } }, .http2_prior_knowledge = true }},
        .http2 = .{ .enable_connect_protocol = true },
        .timeout = .{ .shutdown = .fromSeconds(20) },
    }, {});
    defer server.deinit();
    server.router.get("/chat", echo);
    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) anyerror!void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};
    try server.waitReady(io);

    var client: Client = undefined;
    try client.init(io, server.address.ip);
    defer client.deinit();
    try client.open();
    var op: wsc.Opcode = undefined;
    var buf: [256]u8 = undefined;
    try client.sendFrame(.text, "before");
    try std.testing.expectEqualStrings("before", try client.nextFrame(&op, &buf));

    const start: std.Io.Clock.Timestamp = .now(io, .awake);
    var drain = try io.concurrent(struct {
        fn run(f: *std.Io.Future(anyerror!void), io_: std.Io) !void {
            try std.testing.expectError(error.Canceled, f.cancel(io_));
        }
    }.run, .{ &server_future, io });
    defer drain.cancel(io) catch {};
    const closing = try client.nextFrame(&op, &buf);
    try std.testing.expectEqual(wsc.Opcode.close, op);
    try std.testing.expectEqual(@as(u16, 1001), std.mem.readInt(u16, closing[0..2], .big));
    try std.testing.expectEqualStrings("server shutting down", closing[2..]);
    // Answer the close and end the stream; the server ends its side.
    try client.sendFrame(.close, &.{ 0x03, 0xe9 });
    try client.finish();
    try client.pumpUntil(struct {
        fn f(cl: *Client) bool {
            return cl.closed;
        }
    }.f);
    try drain.await(io);
    if (test_wait.timing()) try std.testing.expect(start.durationTo(.now(io, .awake)).raw.toMilliseconds() < 5000);
    try std.testing.expect(saw_draining.load(.acquire));
}

var route_ended_clean: std.atomic.Value(bool) = .init(false);

/// `route`'s handler shape: a `next` loop, which ends with null on the
/// peer's close.
fn nextEcho(ws: *websocket.Socket) !void {
    while (try ws.next()) |msg| try ws.send(msg.type, msg.data);
    route_ended_clean.store(ws.end_error == null, .release);
}

test "WebSocket over HTTP/2: route() and next(): echo, then the drain's 1001 answered ends the loop" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    route_ended_clean.store(false, .release);

    var server = dusty.Server(void).init(gpa, io, .{
        .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } }, .http2_prior_knowledge = true }},
        .http2 = .{ .enable_connect_protocol = true },
        .timeout = .{ .shutdown = .fromSeconds(20) },
    }, {});
    defer server.deinit();
    server.router.get("/chat", websocket.route(void, nextEcho, .{}));
    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) anyerror!void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};
    try server.waitReady(io);

    var client: Client = undefined;
    try client.init(io, server.address.ip);
    defer client.deinit();
    try client.open();
    try std.testing.expectEqual(@as(u16, 200), client.status);
    var op: wsc.Opcode = undefined;
    var buf: [256]u8 = undefined;
    try client.sendFrame(.text, "through next");
    try std.testing.expectEqualStrings("through next", try client.nextFrame(&op, &buf));
    try client.sendFrame(.ping, "p");
    try std.testing.expectEqualStrings("p", try client.nextFrame(&op, &buf));
    try std.testing.expectEqual(wsc.Opcode.pong, op);

    var drain = try io.concurrent(struct {
        fn run(f: *std.Io.Future(anyerror!void), io_: std.Io) !void {
            try std.testing.expectError(error.Canceled, f.cancel(io_));
        }
    }.run, .{ &server_future, io });
    defer drain.cancel(io) catch {};
    const closing = try client.nextFrame(&op, &buf);
    try std.testing.expectEqual(wsc.Opcode.close, op);
    try std.testing.expectEqual(@as(u16, 1001), std.mem.readInt(u16, closing[0..2], .big));
    try client.sendFrame(.close, &.{ 0x03, 0xe9 });
    try client.finish();
    try client.pumpUntil(struct {
        fn f(cl: *Client) bool {
            return cl.closed;
        }
    }.f);
    try drain.await(io);
    // The loop ended on the close, not on an error.
    try std.testing.expect(route_ended_clean.load(.acquire));
}

var callbacks_closed: std.atomic.Value(bool) = .init(false);

/// `callbacks`' handler shape, which over HTTP/2 runs on the stream's task.
const CallbackEcho = struct {
    pub fn open(ws: *websocket.Socket, _: *dusty.Request) !void {
        try ws.send(.text, "hi");
    }
    pub fn message(ws: *websocket.Socket, msg: websocket.Message) !void {
        try ws.send(msg.type, msg.data);
    }
    pub fn close(ws: *websocket.Socket) void {
        callbacks_closed.store(ws.close_code == .normal, .release);
    }
};

test "WebSocket over HTTP/2: callbacks(): open, echo, ping, close" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    callbacks_closed.store(false, .release);

    var server = dusty.Server(void).init(gpa, io, .{
        .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } }, .http2_prior_knowledge = true }},
        .http2 = .{ .enable_connect_protocol = true },
    }, {});
    defer server.deinit();
    server.router.get("/chat", websocket.callbacks(void, CallbackEcho, .{}));
    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) anyerror!void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};
    try server.waitReady(io);

    var client: Client = undefined;
    try client.init(io, server.address.ip);
    defer client.deinit();
    try client.open();
    try std.testing.expectEqual(@as(u16, 200), client.status);
    var op: wsc.Opcode = undefined;
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("hi", try client.nextFrame(&op, &buf));
    try client.sendFrame(.text, "through callbacks");
    try std.testing.expectEqualStrings("through callbacks", try client.nextFrame(&op, &buf));
    try client.sendFrame(.ping, "p");
    try std.testing.expectEqualStrings("p", try client.nextFrame(&op, &buf));
    try std.testing.expectEqual(wsc.Opcode.pong, op);
    try client.sendFrame(.close, &.{ 0x03, 0xe8 });
    const closing = try client.nextFrame(&op, &buf);
    try std.testing.expectEqual(wsc.Opcode.close, op);
    try std.testing.expectEqual(@as(u16, 1000), std.mem.readInt(u16, closing[0..2], .big));
    try test_wait.waitFlag(io, "the close callback ran", &callbacks_closed);
}

fn startEcho(server: *dusty.Server(void), io: std.Io) !std.Io.Future(anyerror!void) {
    server.router.get("/chat", echo);
    const future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) anyerror!void {
            try s.run();
        }
    }.run, .{server});
    try server.waitReady(io);
    return future;
}

test "WebSocket over HTTP/2: pipelined messages are answered in one DATA frame, in order, a pong in its place" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var server = dusty.Server(void).init(gpa, io, .{
        .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } }, .http2_prior_knowledge = true }},
        .http2 = .{ .enable_connect_protocol = true },
    }, {});
    defer server.deinit();
    var server_future = try startEcho(&server, io);
    defer server_future.cancel(io) catch {};

    var client: Client = undefined;
    try client.init(io, server.address.ip);
    defer client.deinit();
    try client.open();
    var name: [8]u8 = undefined;
    // Queued together, so they leave in one DATA frame.
    for (0..17) |i| {
        if (i == 8) try client.sendFrame(.ping, "p") else try client.sendFrame(.text, try std.fmt.bufPrint(&name, "m{d}", .{i}));
    }
    const before = client.data_frames;
    var op: wsc.Opcode = undefined;
    var buf: [64]u8 = undefined;
    for (0..17) |i| {
        const payload = try client.nextFrame(&op, &buf);
        if (i == 8) {
            try std.testing.expectEqual(wsc.Opcode.pong, op);
            try std.testing.expectEqualStrings("p", payload);
        } else {
            try std.testing.expectEqual(wsc.Opcode.text, op);
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&name, "m{d}", .{i}), payload);
        }
    }
    // One write for the batch; unbatched it was one DATA frame per answer.
    try std.testing.expectEqual(@as(usize, 1), client.data_frames - before);
}

test "WebSocket over HTTP/2: an answer held for a batch goes out while the handler waits on something else" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var server = dusty.Server(void).init(gpa, io, .{
        .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } }, .http2_prior_knowledge = true }},
        .http2 = .{ .enable_connect_protocol = true },
    }, {});
    defer server.deinit();
    var server_future = try startEcho(&server, io);
    defer server_future.cancel(io) catch {};

    var client: Client = undefined;
    try client.init(io, server.address.ip);
    defer client.deinit();
    try client.open();
    // The handler waits for this test with "x" unread: the echo of "wait"
    // comes while it waits, not once it returns.
    wait_release.reset();
    wait_gave_up.store(false, .release);
    defer wait_release.set(io);
    try client.sendFrame(.text, "wait");
    try client.sendFrame(.text, "x");
    const start: std.Io.Clock.Timestamp = .now(io, .awake);
    var op: wsc.Opcode = undefined;
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("wait", try client.nextFrame(&op, &buf));
    try std.testing.expect(!wait_gave_up.load(.acquire));
    if (test_wait.timing()) try std.testing.expect(start.durationTo(.now(io, .awake)).raw.toMilliseconds() < 2000);
}

test "WebSocket over HTTP/2: a page from another origin gets 403, one from the same origin its socket" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var server = dusty.Server(void).init(gpa, io, .{
        .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } }, .http2_prior_knowledge = true }},
        .http2 = .{ .enable_connect_protocol = true },
    }, {});
    defer server.deinit();
    var future = try startEcho(&server, io);
    defer future.cancel(io) catch {};

    var evil: Client = undefined;
    try evil.init(io, server.address.ip);
    defer evil.deinit();
    evil.origin = "https://evil.example";
    try evil.open();
    try std.testing.expectEqual(@as(u16, 403), evil.status);

    var own: Client = undefined;
    try own.init(io, server.address.ip);
    defer own.deinit();
    own.origin = "http://localhost";
    try own.open();
    try std.testing.expectEqual(@as(u16, 200), own.status);
}

test "WebSocket over HTTP/2: under an admission freeze the extended CONNECT gets 503 with retry-after, and the connection then serves a GET" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var server = dusty.Server(void).init(gpa, io, .{
        .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } }, .http2_prior_knowledge = true }},
        .http2 = .{ .enable_connect_protocol = true },
    }, {});
    defer server.deinit();
    server.router.get("/plain", struct {
        fn h(_: *dusty.Request, res: *dusty.Response) !void {
            res.body = "plain";
        }
    }.h);
    var future = try startEcho(&server, io);
    defer future.cancel(io) catch {};
    server.admission.freezeForTest(0);

    var client: Client = undefined;
    try client.init(io, server.address.ip);
    defer client.deinit();
    try client.open();
    try std.testing.expectEqual(@as(u16, 503), client.status);
    try std.testing.expect(client.retry_after >= 5 and client.retry_after <= 15);
    try std.testing.expectEqual(@as(u32, 0), server.admission.live.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), server.admission.refused_load.load(.monotonic));

    // The connection is still good for other streams.
    client.status = 0;
    client.closed = false;
    const nva = [_]tc.Field{
        Client.nv(":method", "GET"),
        Client.nv(":scheme", "http"),
        Client.nv(":path", "/plain"),
        Client.nv(":authority", "localhost"),
    };
    _ = try client.cn.submitRequest(&nva, true, null);
    try client.pumpUntilBounded("the GET's answer", struct {
        fn f(cl: *Client) bool {
            return cl.status != 0;
        }
    }.f);
    try std.testing.expectEqual(@as(u16, 200), client.status);
}

fn budgetEcho(ws: *websocket.Socket) !void {
    while (try ws.next()) |msg| try ws.send(msg.type, msg.data);
}

fn heldIs(server: *dusty.Server(void), n: usize) bool {
    return server.admission.rows[0].held_bytes.load(.monotonic) == n;
}

fn waitHeld(io: std.Io, server: *dusty.Server(void), n: usize) !void {
    const S = struct { s: *dusty.Server(void), n: usize };
    try test_wait.waitUntil(io, "the bytes held of the buffer budget", S{ .s = server, .n = n }, struct {
        fn f(x: S) bool {
            return heldIs(x.s, x.n);
        }
    }.f);
}

/// Sends 33 fragments of 2000 bytes (no FIN): 464 bytes past the 64 KiB
/// a socket keeps between messages.
fn sendPieces(client: *Client) !void {
    for (0..33) |i| {
        try client.sendRawFrame(if (i == 0) 0x02 else 0x00, 2000);
        try client.sendQueued();
    }
}

/// What `sendPieces` holds of the budget: the message buffer's capacity
/// past the 64 KiB kept, grown by half a time across the fragments.
fn piecesHeld() usize {
    var capacity: usize = 0;
    for (0..33) |i| {
        if (H2Socket.messageCapacity(i * 2000, 2000, 0, false, capacity, std.math.maxInt(usize))) |c| capacity = c;
    }
    return capacity - 64 * 1024;
}

test "WebSocket over HTTP/2: a small message passes a full buffer budget; one past the 64 KiB kept holds the rest, and past the budget is closed 1013" {
    const gpa = std.testing.allocator;
    // One executor, so every socket's bytes are on row 0.
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    var server = dusty.Server(void).init(gpa, io, .{
        .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } }, .http2_prior_knowledge = true }},
        .http2 = .{ .enable_connect_protocol = true },
        .buffer_budget = 1024,
    }, {});
    defer server.deinit();
    server.router.get("/chat", websocket.route(void, budgetEcho, .{}));
    var future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) anyerror!void {
            try s.run();
        }
    }.run, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);

    // Others (slow bodies, say) fill the executor's budget.
    const row = &server.admission.rows[0];
    row.held_bytes.store(1024, .monotonic);

    var a: Client = undefined;
    try a.init(io, server.address.ip);
    defer a.deinit();
    try a.open();
    try std.testing.expectEqual(@as(u16, 200), a.status);
    var op: wsc.Opcode = undefined;
    var buf: [256]u8 = undefined;
    try a.sendFrame(.text, "hi");
    try std.testing.expectEqualStrings("hi", try a.nextFrame(&op, &buf));
    try std.testing.expectEqual(@as(u64, 0), server.admission.refused_memory.load(.monotonic));

    // A message past the 64 KiB kept needs the budget: closed 1013.
    try sendPieces(&a);
    const close = try a.nextFrame(&op, &buf);
    try std.testing.expectEqual(wsc.Opcode.close, op);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xf5 }, close);
    try std.testing.expectEqual(@as(u64, 1), server.admission.refused_memory.load(.monotonic));
    try waitHeld(io, &server, 1024);

    // With the budget free, it holds what is past the 64 KiB until the
    // socket goes, and gives it back then.
    row.held_bytes.store(0, .monotonic);
    var b: Client = undefined;
    try b.init(io, server.address.ip);
    var b_open = true;
    defer if (b_open) b.deinit();
    try b.open();
    try sendPieces(&b);
    try waitHeld(io, &server, piecesHeld());
    b.deinit();
    b_open = false;
    try waitHeld(io, &server, 0);
}

var lobby: websocket.Rooms = undefined;

/// Joins the lobby and reads until the socket ends; never leaves.
fn joinLobby(ws: *websocket.Socket) !void {
    try lobby.join("lobby", ws);
    while (try ws.next()) |_| {}
}

test "WebSocket over HTTP/2: a room member that stops reading is closed, its stream ends, and it leaves" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    lobby = .init(gpa, .{ .max_queued_bytes = 256 * 1024, .close_after_ms = 50 });
    defer lobby.deinit();

    var server = dusty.Server(void).init(gpa, io, .{
        .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } }, .http2_prior_knowledge = true }},
        .http2 = .{ .enable_connect_protocol = true },
    }, {});
    defer server.deinit();
    server.router.get("/chat", websocket.route(void, joinLobby, .{}));
    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) anyerror!void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};
    try server.waitReady(io);

    // Opens the socket, then reads nothing more.
    var client: Client = undefined;
    try client.init(io, server.address.ip);
    defer client.deinit();
    try client.open();
    try std.testing.expectEqual(@as(u16, 200), client.status);
    try test_wait.waitUntil(io, "the socket joined the lobby", {}, struct {
        fn joined(_: void) bool {
            return lobby.count("lobby") == 1;
        }
    }.joined);

    const msg = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(msg);
    @memset(msg, 'm');
    // Broadcast until the member that reads nothing is closed and leaves.
    try test_wait.waitUntil(io, "the slow member left the lobby", msg, struct {
        fn left(m: []const u8) bool {
            if (lobby.count("lobby") == 0) return true;
            _ = lobby.broadcast("lobby", .binary, m, null);
            return false;
        }
    }.left);
    // Its stream ends: what was queued drains, then the server ends or
    // resets the stream.
    client.discard = true;
    try client.pumpUntilBounded("the slow member's stream ended or was reset", struct {
        fn ended(cl: *Client) bool {
            return cl.closed or cl.remote_ended;
        }
    }.ended);
}

fn subprotocolSocket(req: *dusty.Request, res: *dusty.Response) !void {
    var ws = (try websocket.upgrade(req, res, .{
        .subprotocols = &.{ "a", "c" },
        .headers = &.{.{ .name = "X-User", .value = "u1" }},
    })) orelse {
        res.status = .bad_request;
        return;
    };
    defer ws.deinit();
    try ws.send(.text, ws.subprotocol orelse "(none)");
    _ = ws.receive() catch return;
}

test "WebSocket over HTTP/2: the selected subprotocol and extra headers ride on the 200" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var server = dusty.Server(void).init(gpa, io, .{
        .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } }, .http2_prior_knowledge = true }},
        .http2 = .{ .enable_connect_protocol = true },
    }, {});
    defer server.deinit();
    server.router.get("/sp", subprotocolSocket);
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
    client.path = "/sp";
    client.protocols = "b, a";
    try client.open();
    try std.testing.expectEqual(@as(u16, 200), client.status);
    try std.testing.expectEqualStrings("a", client.answered_protocol[0..client.answered_protocol_len]);
    try std.testing.expectEqualStrings("u1", client.answered_user[0..client.answered_user_len]);
    var op: wsc.Opcode = undefined;
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("a", try client.nextFrame(&op, &buf));
}

var parked_socket: std.atomic.Value(?*websocket.Socket) = .init(null);

fn park(req: *dusty.Request, res: *dusty.Response) !void {
    var ws = (try websocket.upgrade(req, res, .{})) orelse {
        res.status = .bad_request;
        return;
    };
    defer ws.deinit();
    parked_socket.store(&ws, .release);
    defer parked_socket.store(null, .release);
    // Reads only: everything this socket gets comes from another
    // connection's task.
    while (true) {
        const msg = ws.receive() catch return;
        if (msg.type == .close) return;
    }
}

fn poke(req: *dusty.Request, res: *dusty.Response) !void {
    var ws = (try websocket.upgrade(req, res, .{})) orelse {
        res.status = .bad_request;
        return;
    };
    defer ws.deinit();
    while (true) {
        const msg = ws.receive() catch return;
        switch (msg.type) {
            .text, .binary => {
                const other = parked_socket.load(.acquire) orelse return error.NoParkedSocket;
                try other.send(.text, "from another connection");
                try ws.send(.text, "sent");
            },
            else => return,
        }
    }
}

test "WebSocket over HTTP/2: a message from another connection's task goes out without the peer sending anything" {
    // A socket that only waits got nothing until its own client sent
    // something: its handler, waiting for the stream's first DATA frame,
    // waited on the writer's wake word and took the one wake the other
    // task's send gave, so the writer slept on.
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();

    var server = dusty.Server(void).init(gpa, io, .{
        .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } }, .http2_prior_knowledge = true }},
        .http2 = .{ .enable_connect_protocol = true },
    }, {});
    defer server.deinit();
    server.router.get("/park", park);
    server.router.get("/poke", poke);
    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};
    try server.waitReady(io);

    var a: Client = undefined;
    try a.init(io, server.address.ip);
    defer a.deinit();
    a.path = "/park";
    try a.open();
    try std.testing.expectEqual(@as(u16, 200), a.status);

    var b: Client = undefined;
    try b.init(io, server.address.ip);
    defer b.deinit();
    b.path = "/poke";
    try b.open();
    try std.testing.expectEqual(@as(u16, 200), b.status);

    // The parked handler has run once its 200 is in.
    try test_wait.waitUntil(io, "the parked handler ran", {}, struct {
        fn ran(_: void) bool {
            return parked_socket.load(.acquire) != null;
        }
    }.ran);

    var back: [256]u8 = undefined;
    var op: wsc.Opcode = undefined;
    for (0..3) |_| {
        try b.sendFrame(.text, "go");
        try std.testing.expectEqualStrings("sent", try b.nextFrame(&op, &back));
        try std.testing.expectEqualStrings("from another connection", try a.nextFrame(&op, &back));
    }
}

// ---------------------------------------------------------------------------
// The same client against the HTTP/2 engine on Anole's own protocol core
// (h2/server.zig) served without `Server.run` (h2/test_server.zig); the
// tests above reach it through `Server.run`.

const Serving = dusty.h2_core_for_tests.test_server.Serving(void);

test "WebSocket over HTTP/2 on the new engine: echo, ping, close" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var server = dusty.Server(void).init(gpa, io, .{ .http2 = .{ .enable_connect_protocol = true } }, {});
    defer server.deinit();
    server.router.get("/chat", echo);
    var serving: Serving = undefined;
    try serving.start(&server);
    defer serving.stop();

    var client: Client = undefined;
    try client.init(io, serving.address);
    defer client.deinit();
    try client.open();
    try std.testing.expectEqual(@as(u16, 200), client.status);

    var op: wsc.Opcode = undefined;
    var buf: [256]u8 = undefined;
    try client.sendFrame(.text, "hello over h2");
    try std.testing.expectEqualStrings("hello over h2", try client.nextFrame(&op, &buf));
    try std.testing.expectEqual(wsc.Opcode.text, op);
    try client.sendFrame(.ping, "are you there");
    try std.testing.expectEqualStrings("are you there", try client.nextFrame(&op, &buf));
    try std.testing.expectEqual(wsc.Opcode.pong, op);
    try client.sendFrame(.binary, &.{ 0, 1, 2, 255 });
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 255 }, try client.nextFrame(&op, &buf));

    // Close 1000: echoed, then the server ends the stream.
    try client.sendFrame(.close, &.{ 0x03, 0xe8 });
    const closing = try client.nextFrame(&op, &buf);
    try std.testing.expectEqual(wsc.Opcode.close, op);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8 }, closing);
    try client.finish();
    try client.pumpUntil(struct {
        fn f(cl: *Client) bool {
            return cl.closed;
        }
    }.f);
}

test "WebSocket over HTTP/2 on the new engine: a send from a task on another executor hops to the socket's" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var server = dusty.Server(void).init(gpa, io, .{ .http2 = .{ .enable_connect_protocol = true } }, {});
    defer server.deinit();
    server.router.get("/park", park);
    server.router.get("/poke", poke);
    var serving: Serving = undefined;
    try serving.start(&server);
    defer serving.stop();

    // Connections go to the executors in turn: A on one, B on the other.
    var a: Client = undefined;
    try a.init(io, serving.address);
    defer a.deinit();
    a.path = "/park";
    try a.open();
    try std.testing.expectEqual(@as(u16, 200), a.status);
    var b: Client = undefined;
    try b.init(io, serving.address);
    defer b.deinit();
    b.path = "/poke";
    try b.open();
    try std.testing.expectEqual(@as(u16, 200), b.status);
    try test_wait.waitUntil(io, "the parked handler ran", {}, struct {
        fn ran(_: void) bool {
            return parked_socket.load(.acquire) != null;
        }
    }.ran);

    const hops = dusty.h2_core_for_tests.server.probe.at(.hops).load(.acquire);
    var back: [256]u8 = undefined;
    var op: wsc.Opcode = undefined;
    for (0..3) |_| {
        try b.sendFrame(.text, "go");
        try std.testing.expectEqualStrings("sent", try b.nextFrame(&op, &back));
        try std.testing.expectEqualStrings("from another connection", try a.nextFrame(&op, &back));
    }
    try std.testing.expect(dusty.h2_core_for_tests.server.probe.at(.hops).load(.acquire) >= hops + 3);
}

const HeldSend = enum(u8) { pending, canceled, not_canceled, send_succeeded };
var held_task: std.atomic.Value(?dusty.placement.Task) = .init(null);
/// A `HeldSend`, as its integer (an atomic holds no enum).
var held_outcome: std.atomic.Value(u8) = .init(@backingInt(HeldSend.pending));

/// Sends to the parked socket while the test holds the hop open, then says
/// whether the cancel it got during the hop is still pending.
fn poke_held(req: *dusty.Request, res: *dusty.Response) !void {
    var ws = (try websocket.upgrade(req, res, .{})) orelse {
        res.status = .bad_request;
        return;
    };
    defer ws.deinit();
    _ = ws.receive() catch return;
    const other = parked_socket.load(.acquire) orelse return error.NoParkedSocket;
    held_task.store(dusty.placement.currentTask(req.io), .release);
    const sent = other.send(.text, "never delivered");
    const outcome: HeldSend = if (!std.meta.isError(sent))
        .send_succeeded
    else if (req.io.checkCancel()) .not_canceled else |_| .canceled;
    held_outcome.store(@backingInt(outcome), .release);
}

test "WebSocket over HTTP/2 on the new engine: a send canceled while its hop is pending leaves the cancel pending" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var server = dusty.Server(void).init(gpa, io, .{ .http2 = .{ .enable_connect_protocol = true } }, {});
    defer server.deinit();
    server.router.get("/park", park);
    server.router.get("/poke", poke_held);
    var serving: Serving = undefined;
    try serving.start(&server);
    defer serving.stop();

    var a: Client = undefined;
    try a.init(io, serving.address);
    defer a.deinit();
    a.path = "/park";
    try a.open();
    var b: Client = undefined;
    try b.init(io, serving.address);
    defer b.deinit();
    b.path = "/poke";
    try b.open();
    try test_wait.waitUntil(io, "the parked handler ran", {}, struct {
        fn ran(_: void) bool {
            return parked_socket.load(.acquire) != null;
        }
    }.ran);

    const server_core = dusty.h2_core_for_tests.server;
    var hold: std.Io.Event = .unset;
    server_core.probe.hop_hold.store(&hold, .release);
    defer server_core.probe.hop_hold.store(null, .release);
    held_task.store(null, .release);
    held_outcome.store(@backingInt(HeldSend.pending), .release);
    const hops = server_core.probe.at(.hops).load(.acquire);

    try b.sendFrame(.text, "go");
    try b.sendQueued();
    try test_wait.waitUntil(io, "the send hopped", hops, struct {
        fn hopped(before: usize) bool {
            return dusty.h2_core_for_tests.server.probe.at(.hops).load(.acquire) > before;
        }
    }.hopped);
    // `held_task` is stored before the send, so it is set once the hop is.
    dusty.placement.cancelTask(held_task.load(.acquire).?);
    try test_wait.waitUntil(io, "the sender saw the outcome", {}, struct {
        fn done(_: void) bool {
            return held_outcome.load(.acquire) != @backingInt(HeldSend.pending);
        }
    }.done);
    try std.testing.expectEqual(@backingInt(HeldSend.canceled), held_outcome.load(.acquire));
}

const features = @import("build_options");

/// Whether the last socket `deflateHandler` opened compresses outside the
/// stream's arena.
var deflate_apart: std.atomic.Value(bool) = .init(false);

fn deflateHandler(req: *dusty.Request, res: *dusty.Response) !void {
    var ws = (try websocket.upgrade(req, res, .{})) orelse {
        res.status = .bad_request;
        return;
    };
    defer ws.deinit();
    if (comptime features.compression) if (ws._deflate) |d| deflate_apart.store(d.allocator.ptr != req.arena.ptr, .release);
    ws.close(.normal, "") catch {};
}

// The stream's arena has one owner at a time (`dusty.LocalArena`), and
// tasks on other executors compress what they send (`Rooms`), so the
// compressor's buffers must not come from it (#171).
test "WebSocket over HTTP/2 on the new engine: permessage-deflate keeps its buffers out of the stream's arena" {
    if (comptime !features.compression) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var server = dusty.Server(void).init(gpa, io, .{ .http2 = .{ .enable_connect_protocol = true } }, {});
    defer server.deinit();
    server.router.get("/deflate", deflateHandler);
    var serving: Serving = undefined;
    try serving.start(&server);
    defer serving.stop();

    var client: Client = undefined;
    try client.init(io, serving.address);
    defer client.deinit();
    client.path = "/deflate";
    client.extensions = "permessage-deflate";
    try client.open();
    try std.testing.expectEqual(@as(u16, 200), client.status);
    try test_wait.waitFlag(io, "the deflate handler saw its buffers apart from the arena", &deflate_apart);
}
