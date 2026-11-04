//! The WebSocket admission gate (#129) end to end over HTTP/1.1: a refused
//! upgrade's answer, the count every path leaves, the exact cap, the
//! board's reconnect pattern under a freeze, separate Servers, and where
//! the executors' utilization comes from. The gate's arithmetic is tested
//! in src/http/core/admission.zig; the freeze is forced here through the
//! Server's own state (`admission.freezeForTest`).
const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");
const websocket = @import("root.zig");
const wait = @import("anole_test_wait");

const admission = dusty.admission;
const Server = dusty.Server(void);
const loopback: dusty.Address = .{ .ip = .{ .ip4 = .loopback(0) } };

/// Socket handlers that ran (a refused upgrade runs none).
var handler_runs: std.atomic.Value(u32) = .init(0);

fn echo(ws: *websocket.Socket) !void {
    _ = handler_runs.fetchAdd(1, .acq_rel);
    while (try ws.next()) |msg| try ws.send(msg.type, msg.data);
}

const Echo = struct {
    pub fn message(ws: *websocket.Socket, msg: websocket.Message) !void {
        try ws.send(msg.type, msg.data);
    }
};

fn start(server: *Server, io: std.Io) !std.Io.Future(anyerror!void) {
    server.router.get("/ws", websocket.route(void, echo, .{}));
    server.router.get("/cb", websocket.callbacks(void, Echo, .{}));
    var future = try io.concurrent(struct {
        fn run(s: *Server) anyerror!void {
            try s.run();
        }
    }.run, .{server});
    errdefer future.cancel(io) catch {};
    try server.waitReady(io);
    return future;
}

/// A raw HTTP/1.1 client: the handshake's answer head, then short frames.
const Raw = struct {
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,
    rbuf: [1024]u8 = undefined,
    wbuf: [1024]u8 = undefined,
    head: [1024]u8 = undefined,
    head_len: usize = 0,

    fn open(self: *Raw, io: std.Io, addr: std.Io.net.IpAddress, path: []const u8, extra: []const u8) !void {
        self.stream = try addr.connect(io, .{ .mode = .stream });
        errdefer self.stream.close(io);
        self.reader = self.stream.reader(io, &self.rbuf);
        self.writer = self.stream.writer(io, &self.wbuf);
        try self.writer.interface.print("GET {s} HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n{s}\r\n", .{ path, extra });
        try self.writer.interface.flush();
        self.head_len = 0;
        while (std.mem.indexOf(u8, self.head[0..self.head_len], "\r\n\r\n") == null) {
            const line = try self.reader.interface.takeDelimiterInclusive('\n');
            @memcpy(self.head[self.head_len..][0..line.len], line);
            self.head_len += line.len;
        }
    }

    fn close(self: *Raw, io: std.Io) void {
        self.stream.close(io);
    }

    fn status(self: *const Raw) u16 {
        return std.fmt.parseInt(u16, self.head[9..12], 10) catch 0;
    }

    /// A header's value in the answer head (names compared as written).
    fn header(self: *const Raw, name: []const u8) ?[]const u8 {
        var lines = std.mem.splitSequence(u8, self.head[0..self.head_len], "\r\n");
        while (lines.next()) |line| {
            if (line.len > name.len + 1 and std.ascii.eqlIgnoreCase(line[0..name.len], name) and line[name.len] == ':')
                return std.mem.trim(u8, line[name.len + 1 ..], " ");
        }
        return null;
    }

    /// One masked frame (zero key).
    fn send(self: *Raw, opcode: u8, payload: []const u8) !void {
        try self.writer.interface.writeAll(&.{ 0x80 | opcode, 0x80 | @as(u8, @intCast(payload.len)), 0, 0, 0, 0 });
        try self.writer.interface.writeAll(payload);
        try self.writer.interface.flush();
    }

    fn next(self: *Raw, out: []u8) !struct { opcode: u8, payload: []u8 } {
        const h = try self.reader.interface.takeArray(2);
        const len = h[1] & 0x7f;
        try self.reader.interface.readSliceAll(out[0..len]);
        return .{ .opcode = h[0] & 0x0f, .payload = out[0..len] };
    }

    /// A clean close: ours, then the server's answer.
    fn closeHandshake(self: *Raw) !void {
        try self.send(0x8, &.{ 0x03, 0xe8 });
        var buf: [125]u8 = undefined;
        while (true) if ((try self.next(&buf)).opcode == 0x8) return;
    }

    /// Reads until the server closes the connection.
    fn expectEof(self: *Raw) !void {
        var buf: [256]u8 = undefined;
        var sink: std.Io.Writer.Discarding = .init(&buf);
        _ = self.reader.interface.streamRemaining(&sink.writer) catch {};
    }
};

fn wsGauge() i64 {
    var sum: i64 = 0;
    for (0..dusty.gauges.max_executors) |i| sum += dusty.gauges.get(.ws_h1, i);
    return sum;
}

fn liveIs(state: *admission.State, n: u32) bool {
    return state.live.load(.monotonic) == n;
}

fn waitLive(io: std.Io, state: *admission.State, n: u32) !void {
    const S = struct { s: *admission.State, n: u32 };
    try wait.waitUntil(io, "the open WebSockets' count", S{ .s = state, .n = n }, struct {
        fn f(x: S) bool {
            return liveIs(x.s, x.n);
        }
    }.f);
}

test "admission: a frozen server answers an upgrade 503 with Retry-After and Connection: close, before the 101" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var server = Server.init(gpa, io, .{ .listeners = &.{.{ .address = loopback }} }, {});
    defer server.deinit();
    var future = try start(&server, io);
    defer future.cancel(io) catch {};

    handler_runs.store(0, .release);
    const gauge_before = wsGauge();
    server.admission.freezeForTest(0);
    inline for (.{ "/ws", "/cb" }) |path| {
        var c: Raw = undefined;
        try c.open(io, server.address.ip, path, "");
        defer c.close(io);
        try std.testing.expectEqual(@as(u16, 503), c.status());
        const secs = try std.fmt.parseInt(u16, c.header("Retry-After") orelse return error.NoRetryAfter, 10);
        try std.testing.expect(secs >= 5 and secs <= 15);
        try std.testing.expect(std.ascii.eqlIgnoreCase(c.header("Connection") orelse "", "close"));
        try std.testing.expect(c.header("Sec-WebSocket-Accept") == null);
        try c.expectEof();
    }
    try std.testing.expectEqual(@as(u32, 0), handler_runs.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), server.admission.live.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 2), server.admission.refused_load.load(.monotonic));
    try std.testing.expectEqual(gauge_before, wsGauge());

    // A page from another origin still gets 403 under the freeze.
    var evil: Raw = undefined;
    try evil.open(io, server.address.ip, "/ws", "Origin: https://evil.example\r\n");
    defer evil.close(io);
    try std.testing.expectEqual(@as(u16, 403), evil.status());
    try std.testing.expectEqual(@as(u64, 2), server.admission.refused_load.load(.monotonic));

    // Unfrozen, the same upgrade is admitted and counted until it closes.
    server.admission.reset();
    var ok: Raw = undefined;
    try ok.open(io, server.address.ip, "/ws", "");
    defer ok.close(io);
    try std.testing.expectEqual(@as(u16, 101), ok.status());
    try std.testing.expectEqual(@as(u32, 1), server.admission.live.load(.monotonic));
    try ok.closeHandshake();
    try waitLive(io, &server.admission, 0);
}

test "admission: max_websockets refuses the next upgrade with 503, and a close readmits one" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var server = Server.init(gpa, io, .{ .listeners = &.{.{ .address = loopback }}, .max_websockets = 2 }, {});
    defer server.deinit();
    var future = try start(&server, io);
    defer future.cancel(io) catch {};

    var a: Raw = undefined;
    try a.open(io, server.address.ip, "/ws", "");
    defer a.close(io);
    var b: Raw = undefined;
    try b.open(io, server.address.ip, "/cb", "");
    defer b.close(io);
    try std.testing.expectEqual(@as(u16, 101), a.status());
    try std.testing.expectEqual(@as(u16, 101), b.status());

    var third: Raw = undefined;
    try third.open(io, server.address.ip, "/ws", "");
    try std.testing.expectEqual(@as(u16, 503), third.status());
    third.close(io);
    try std.testing.expectEqual(@as(u64, 1), server.admission.refused_cap.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), server.admission.refused_load.load(.monotonic));

    try b.closeHandshake();
    try waitLive(io, &server.admission, 1);
    var fourth: Raw = undefined;
    try fourth.open(io, server.address.ip, "/cb", "");
    defer fourth.close(io);
    try std.testing.expectEqual(@as(u16, 101), fourth.status());
    try std.testing.expectEqual(@as(u32, 2), server.admission.live.load(.monotonic));
}

test "admission: clients that reconnect every 10 frames under a freeze (echo-ws-limited) are never refused" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var server = Server.init(gpa, io, .{ .listeners = &.{.{ .address = loopback }} }, {});
    defer server.deinit();
    var future = try start(&server, io);
    defer future.cancel(io) catch {};

    const clients = 8;
    const rounds = 20;
    const Client = struct {
        var failures: std.atomic.Value(u32) = .init(0);

        fn run(addr: std.Io.net.IpAddress, _io: std.Io, frozen: *std.Io.Event) std.Io.Cancelable!void {
            body(addr, _io, frozen) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                std.debug.print("echo-ws-limited client: {t}\n", .{err});
                _ = failures.fetchAdd(1, .acq_rel);
            };
        }

        fn body(addr: std.Io.net.IpAddress, _io: std.Io, frozen: *std.Io.Event) !void {
            var c: Raw = undefined;
            try c.open(_io, addr, "/ws", "");
            // Everyone connected before the freeze, as on the board.
            try frozen.wait(_io);
            var buf: [16]u8 = undefined;
            for (0..rounds) |round| {
                if (c.status() != 101) {
                    c.close(_io);
                    return error.Refused;
                }
                for (0..10) |_| {
                    try c.send(0x1, "frame");
                    try std.testing.expectEqualStrings("frame", (try c.next(&buf)).payload);
                }
                try c.closeHandshake();
                c.close(_io);
                if (round + 1 < rounds) try c.open(_io, addr, "/ws", "");
            }
        }
    };
    var frozen: std.Io.Event = .unset;
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (0..clients) |_| try group.concurrent(io, Client.run, .{ server.address.ip, io, &frozen });
    try waitLive(io, &server.admission, clients);
    // Frozen as a hot row would: the live count plus one window's closes,
    // here as many as there are clients (each reconnects at most once
    // before its old socket is gone).
    _ = server.admission.rowHot(0, clients);
    frozen.set(io);
    try group.await(io);
    try std.testing.expectEqual(@as(u32, 0), Client.failures.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), server.admission.refused_load.load(.monotonic));
    try waitLive(io, &server.admission, 0);
}

test "admission: two Servers on one runtime count apart, and a new one after a frozen one starts unfrozen" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var one = Server.init(gpa, io, .{ .listeners = &.{.{ .address = loopback }}, .max_websockets = 1 }, {});
    defer one.deinit();
    var one_future = try start(&one, io);
    var two = Server.init(gpa, io, .{ .listeners = &.{.{ .address = loopback }}, .max_websockets = 1 }, {});
    defer two.deinit();
    var two_future = try start(&two, io);
    defer two_future.cancel(io) catch {};

    var a: Raw = undefined;
    try a.open(io, one.address.ip, "/ws", "");
    defer a.close(io);
    var b: Raw = undefined;
    try b.open(io, two.address.ip, "/ws", "");
    defer b.close(io);
    try std.testing.expectEqual(@as(u16, 101), a.status());
    try std.testing.expectEqual(@as(u16, 101), b.status());
    try std.testing.expectEqual(@as(u32, 1), one.admission.live.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), two.admission.live.load(.monotonic));

    // The first stops frozen; a third Server is not.
    one.admission.freezeForTest(0);
    one_future.cancel(io) catch {};
    var three = Server.init(gpa, io, .{ .listeners = &.{.{ .address = loopback }} }, {});
    defer three.deinit();
    var three_future = try start(&three, io);
    defer three_future.cancel(io) catch {};
    var c: Raw = undefined;
    try c.open(io, three.address.ip, "/ws", "");
    defer c.close(io);
    try std.testing.expectEqual(@as(u16, 101), c.status());
}

/// The source the probe on executor 0 should pick, worked out there.
fn expectedSource(io: std.Io) !admission.Source {
    var f = try io.concurrent(struct {
        fn run(_io: std.Io) admission.Source {
            if (dusty.placement.loopIdleNs(_io) != null) return .poll_wall;
            const c = admission.TaskClock.open() catch return .none;
            c.close();
            return .task_clock;
        }
    }.run, .{io});
    return f.await(io);
}

fn sourceIs(row: *admission.Row, want: admission.Source) bool {
    return row.source.load(.monotonic) == want;
}

test "admission: each executor's probe picks its signal, and a denied task clock turns the gate off there" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const want = try expectedSource(io);
    {
        var server = Server.init(gpa, io, .{ .listeners = &.{.{ .address = loopback }} }, {});
        defer server.deinit();
        var future = try start(&server, io);
        defer future.cancel(io) catch {};
        const S = struct { row: *admission.Row, want: admission.Source };
        try wait.waitUntil(io, "the probe picked its source", S{ .row = &server.admission.rows[0], .want = want }, struct {
            fn f(x: S) bool {
                return sourceIs(x.row, x.want);
            }
        }.f);
    }
    // Only io_uring needs the task clock.
    if (want != .task_clock) return;
    admission.test_deny_task_clock = true;
    defer admission.test_deny_task_clock = false;
    var server = Server.init(gpa, io, .{ .listeners = &.{.{ .address = loopback }} }, {});
    defer server.deinit();
    var future = try start(&server, io);
    defer future.cancel(io) catch {};
    const row = &server.admission.rows[0];
    try wait.waitUntil(io, "the probe closed a window", row, struct {
        fn f(r: *admission.Row) bool {
            return r.windows.load(.monotonic) > 0;
        }
    }.f);
    try std.testing.expectEqual(admission.Source.none, row.source.load(.monotonic));
    try std.testing.expect(!row.hot.load(.monotonic));
}

// ---- The upgrade on its own, over a test connection ----

const Rig = struct {
    arena: std.heap.ArenaAllocator,
    out: [64]u8 = undefined,
    conn_writer: std.Io.Writer = undefined,
    connection: dusty.Connection = undefined,
    response: dusty.Response = undefined,
    request: dusty.Request = undefined,
    state: admission.State = .{},

    /// A handshake request against `self.state`; the 101 fails at its
    /// head when `out_len` can't hold it.
    fn init(self: *Rig, out_len: usize) !void {
        self.* = .{ .arena = .init(std.testing.allocator) };
        const a = self.arena.allocator();
        self.conn_writer = .fixed(self.out[0..out_len]);
        self.connection.initWriterForTesting(&self.conn_writer);
        self.connection.tcp_writer.err = error.ConnectionResetByPeer;
        self.response = try dusty.Response._init(a, &self.connection, 32);
        self.request = .{ .arena = a, ._parser = undefined, ._transport = undefined, .method = .get, .io = std.testing.io, .headers = try dusty.Headers.init(a, 8) };
        self.request._config._admission = &self.state;
        try self.request.headers.put("Upgrade", "websocket");
        try self.request.headers.put("Connection", "Upgrade");
        try self.request.headers.put("Sec-WebSocket-Version", "13");
        try self.request.headers.put("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==");
    }

    fn deinit(self: *Rig) void {
        self.arena.deinit();
    }
};

test "admission: the refusal sets Retry-After and closes the HTTP/1.1 connection, and takes nothing" {
    var r: Rig = undefined;
    try r.init(64);
    defer r.deinit();
    r.state.freezeForTest(0);
    try std.testing.expectError(error.ServiceUnavailable, websocket.upgrade(&r.request, &r.response, .{}));
    const secs = try std.fmt.parseInt(u16, r.response.headers.get("Retry-After").?, 10);
    try std.testing.expect(secs >= 5 and secs <= 15);
    try std.testing.expect(!r.response.keepalive);
    try std.testing.expectEqual(@as(u32, 0), r.state.live.load(.monotonic));
    try std.testing.expectEqual(dusty.Request._WsAdmission.refused, r.request._ws_admission);
}

test "admission: a handshake whose 101 fails gives its unit back" {
    var r: Rig = undefined;
    try r.init(4);
    defer r.deinit();
    try std.testing.expectError(error.ConnectionResetByPeer, websocket.upgrade(&r.request, &r.response, .{}));
    try std.testing.expectEqual(@as(u32, 0), r.state.live.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), r.state.closed.load(.monotonic));
    try std.testing.expectEqual(dusty.Request._WsAdmission.none, r.request._ws_admission);
}

test "admission: an upgrade the response can't make (a sink) gives its unit back" {
    var r: Rig = undefined;
    try r.init(64);
    defer r.deinit();
    // `_upgradeWebSocket` returns null for a response with a sink before
    // it touches it.
    r.response._sink = .{ .ptr = undefined, .vtable = undefined };
    try std.testing.expectEqual(@as(?websocket.Socket, null), try websocket.upgrade(&r.request, &r.response, .{}));
    try std.testing.expectEqual(@as(u32, 0), r.state.live.load(.monotonic));
}

test "admission: a unit a caller already holds is not taken again, and stays the caller's" {
    var r: Rig = undefined;
    try r.init(4);
    defer r.deinit();
    try std.testing.expectEqual(@as(?admission.Refusal, null), r.state.reserve());
    r.request._ws_admission = .held;
    // Frozen at the one held: a second reserve would be refused.
    r.state.freezeForTest(1);
    try std.testing.expectError(error.ConnectionResetByPeer, websocket.upgrade(&r.request, &r.response, .{}));
    try std.testing.expectEqual(dusty.Request._WsAdmission.held, r.request._ws_admission);
    try std.testing.expectEqual(@as(u32, 1), r.state.live.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), r.state.refused_load.load(.monotonic));
}
