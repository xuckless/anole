//! WebSocket callbacks (`callbacks`, `Server.wsCallbacks`) over HTTP/1.1 on
//! zio: messages, close, ping and pong, sends from other tasks while the
//! connection is parked, the drain, and stopping with parked sockets.
const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");
const websocket = @import("root.zig");
const features = @import("build_options");
const have_tls = features.tls == .boringssl;
const tls = if (have_tls) @import("anole_dusty_tls") else struct {};
const tls_root = if (have_tls) @import("../tls/root.zig") else struct {};

const Server = dusty.Server(void);
const loopback: dusty.Address = .{ .ip = .{ .ip4 = .loopback(0) } };

/// What the callbacks saw, for the test to check.
var opened: std.atomic.Value(u32) = .init(0);
var closed: std.atomic.Value(u32) = .init(0);
var last_close_code: std.atomic.Value(u16) = .init(0);
var last_end_error: std.atomic.Value(bool) = .init(false);
/// The last socket opened, for sends from the test's own task.
var last_socket: std.atomic.Value(?*websocket.Socket) = .init(null);
/// Tasks the callbacks started, joined by the test.
var background: std.Io.Group = .init;

fn resetCounts() void {
    opened.store(0, .release);
    closed.store(0, .release);
    last_close_code.store(0, .release);
    last_end_error.store(false, .release);
    last_socket.store(null, .release);
}

/// Per-socket state, in `context`.
const PerSocket = struct {
    messages: usize = 0,
};

const Echo = struct {
    pub fn open(ws: *websocket.Socket, req: *dusty.Request) !void {
        if (req.query.get("fail") != null) return error.Refused;
        const state = try std.testing.allocator.create(PerSocket);
        state.* = .{};
        ws.context = state;
        last_socket.store(ws, .release);
        _ = opened.fetchAdd(1, .acq_rel);
        try ws.send(.text, "hello");
    }

    pub fn message(ws: *websocket.Socket, msg: websocket.Message) !void {
        ws.contextAs(PerSocket).messages += 1;
        if (std.mem.eql(u8, msg.data, "fail")) return error.Boom;
        if (std.mem.eql(u8, msg.data, "later")) {
            // A send from another task, after the connection has parked.
            try background.concurrent(ws.io, sendLater, .{ws});
            return;
        }
        if (std.mem.eql(u8, msg.data, "count")) {
            var buf: [32]u8 = undefined;
            return ws.send(.text, try std.fmt.bufPrint(&buf, "{d}", .{ws.contextAs(PerSocket).messages}));
        }
        try ws.send(msg.type, msg.data);
    }

    pub fn close(ws: *websocket.Socket) void {
        if (ws.context) |_| std.testing.allocator.destroy(ws.contextAs(PerSocket));
        last_close_code.store(if (ws.close_code) |c| @backingInt(c) else 0, .release);
        last_end_error.store(ws.end_error != null, .release);
        last_socket.store(null, .release);
        _ = closed.fetchAdd(1, .acq_rel);
    }

    fn sendLater(ws: *websocket.Socket) std.Io.Cancelable!void {
        try ws.io.sleep(.fromMilliseconds(150), .awake);
        ws.send(.text, "later!") catch {};
    }
};

/// A WebSocket client over a plain or TLS connection, masked frames with a
/// zero key, short payloads.
const Client = struct {
    stream: std.Io.net.Stream,
    tcp_reader: std.Io.net.Stream.Reader,
    tcp_writer: std.Io.net.Stream.Writer,
    rbuf: [4096]u8 = undefined,
    wbuf: [4096]u8 = undefined,
    tls_conn: if (have_tls) ?tls.Connection else void = if (have_tls) null else {},
    tls_reader: if (have_tls) tls.Connection.Reader else void = undefined,
    tls_writer: if (have_tls) tls.Connection.Writer else void = undefined,

    fn open(self: *Client, io: std.Io, addr: std.Io.net.IpAddress, secure: bool, path: []const u8) !void {
        self.stream = try addr.connect(io, .{ .mode = .stream });
        self.tls_conn = if (have_tls) null else {};
        if (comptime have_tls) if (secure) {
            self.tcp_reader = self.stream.reader(io, &.{});
            self.tcp_writer = self.stream.writer(io, &.{});
            var rng: std.Random.IoSource = .{ .io = io };
            self.tls_conn = try tls.client(&self.tcp_reader.interface, &self.tcp_writer.interface, .{
                .host = "localhost",
                .root_ca = .empty,
                .insecure_skip_verify = true,
                .now = std.Io.Clock.real.now(io),
                .rng = rng.interface(),
            });
            self.tls_reader = self.tls_conn.?.reader(&self.rbuf);
            self.tls_writer = self.tls_conn.?.writer(&self.wbuf);
        };
        if (!secure) {
            self.tcp_reader = self.stream.reader(io, &self.rbuf);
            self.tcp_writer = self.stream.writer(io, &self.wbuf);
        }
        var buf: [256]u8 = undefined;
        try self.writer().writeAll(try std.fmt.bufPrint(&buf, "GET {s} HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n", .{path}));
        try self.writer().flush();
        const head = try self.reader().takeDelimiterInclusive('\n');
        if (!std.mem.startsWith(u8, head, "HTTP/1.1 101")) return error.NotUpgraded;
        while (true) {
            const line = try self.reader().takeDelimiterInclusive('\n');
            if (std.mem.eql(u8, line, "\r\n")) break;
        }
    }

    fn close(self: *Client, io: std.Io) void {
        if (comptime have_tls) if (self.tls_conn) |*c| c.deinit();
        self.stream.close(io);
    }

    fn reader(self: *Client) *std.Io.Reader {
        if (comptime have_tls) if (self.tls_conn != null) return &self.tls_reader.interface;
        return &self.tcp_reader.interface;
    }

    fn writer(self: *Client) *std.Io.Writer {
        if (comptime have_tls) if (self.tls_conn != null) return &self.tls_writer.interface;
        return &self.tcp_writer.interface;
    }

    fn queue(self: *Client, opcode: u8, payload: []const u8) !void {
        std.debug.assert(payload.len < 126);
        try self.writer().writeAll(&.{ 0x80 | opcode, 0x80 | @as(u8, @intCast(payload.len)), 0, 0, 0, 0 });
        try self.writer().writeAll(payload);
    }

    fn send(self: *Client, opcode: u8, payload: []const u8) !void {
        try self.queue(opcode, payload);
        try self.writer().flush();
    }

    const Frame = struct { opcode: u8, payload: []u8 };

    fn next(self: *Client, out: []u8) !Frame {
        const head = try self.reader().takeArray(2);
        const len = head[1] & 0x7f;
        std.debug.assert(len < 126);
        try self.reader().readSliceAll(out[0..len]);
        return .{ .opcode = head[0] & 0x0f, .payload = out[0..len] };
    }

    fn expectText(self: *Client, text: []const u8) !void {
        var buf: [128]u8 = undefined;
        const f = try self.next(&buf);
        try std.testing.expectEqual(@as(u8, 0x1), f.opcode);
        try std.testing.expectEqualStrings(text, f.payload);
    }

    fn expectClose(self: *Client, code: u16) !void {
        var buf: [128]u8 = undefined;
        const f = try self.next(&buf);
        try std.testing.expectEqual(@as(u8, 0x8), f.opcode);
        try std.testing.expectEqual(code, std.mem.readInt(u16, f.payload[0..2], .big));
    }

    fn hungUp(self: *Client) bool {
        _ = self.reader().takeByte() catch return true;
        return false;
    }
};

const Fixture = struct {
    rt: *zio.Runtime,
    io: std.Io,
    server: Server,
    future: std.Io.Future(anyerror!void) = undefined,
    pem: if (have_tls) ?tls_root.Pem else void = if (have_tls) null else {},
    listeners: [1]dusty.Listener = undefined,
    stopped: bool = false,

    fn start(self: *Fixture, gpa: std.mem.Allocator, secure: bool, config: dusty.ServerConfig) !void {
        self.* = .{ .rt = undefined, .io = undefined, .server = undefined };
        resetCounts();
        background = .init;
        self.rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
        self.io = self.rt.io();
        self.listeners = .{.{ .address = loopback }};
        if (comptime have_tls) if (secure) {
            self.pem = try tls_root.selfSigned(gpa, .{});
            self.listeners[0].tls = .{ .pem = .{ .cert = self.pem.?.cert, .key = self.pem.?.key }, .alpn_protocols = &.{"http/1.1"} };
        };
        var cfg = config;
        cfg.listeners = &self.listeners;
        self.server = Server.init(gpa, self.io, cfg, {});
        self.server.router.get("/ws", websocket.callbacks(void, Echo, .{}));
        self.server.router.get("/quiet", websocket.callbacks(void, Echo, .{ .close_on_drain = false }));
        self.server.router.get("/brief", websocket.callbacks(void, Echo, .{ .timeout = .{ .duration = .{ .raw = .fromMilliseconds(400), .clock = .awake } } }));
        self.future = try self.io.concurrent(struct {
            fn run(s: *Server) anyerror!void {
                try s.run();
            }
        }.run, .{&self.server});
        try self.server.waitReady(self.io);
    }

    fn stopServer(self: *Fixture) void {
        if (self.stopped) return;
        self.stopped = true;
        self.future.cancel(self.io) catch {};
    }

    fn deinit(self: *Fixture, gpa: std.mem.Allocator) void {
        // First: the tasks the callbacks started hold their sockets.
        background.cancel(self.io);
        self.stopServer();
        self.server.deinit();
        if (comptime have_tls) if (self.pem) |*p| p.deinit(gpa);
        self.rt.deinit();
    }

    fn waitParked(self: *Fixture, n: usize) !void {
        for (0..200) |_| {
            if (self.server.parkedConnections() == n) return;
            try self.io.sleep(.fromMilliseconds(5), .awake);
        }
        std.debug.print("parked: {d}, want {d}\n", .{ self.server.parkedConnections(), n });
        return error.TestUnexpectedResult;
    }

    fn waitClosed(self: *Fixture, n: u32) !void {
        for (0..400) |_| {
            if (closed.load(.acquire) == n) return;
            try self.io.sleep(.fromMilliseconds(5), .awake);
        }
        return error.TestUnexpectedResult;
    }
};

const quick: dusty.ServerConfig = .{ .timeout = .{ .idle_park = .fromMilliseconds(30) } };

fn messagesAcrossParking(secure: bool) !void {
    if (secure and !have_tls) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var f: Fixture = undefined;
    try f.start(gpa, secure, quick);
    defer f.deinit(gpa);

    var c: Client = undefined;
    try c.open(f.io, f.server.address.ip, secure, "/ws");
    defer c.close(f.io);
    try c.expectText("hello");
    try c.send(0x1, "one");
    try c.expectText("one");
    try f.waitParked(1);

    for (0..3) |_| {
        // Woken by the next message, parked again after it.
        try c.send(0x2, "two");
        var buf: [16]u8 = undefined;
        const frame = try c.next(&buf);
        try std.testing.expectEqual(@as(u8, 0x2), frame.opcode);
        try std.testing.expectEqualStrings("two", frame.payload);
        try f.waitParked(1);
    }
    // Several in one write: one burst answers them all, in order.
    try c.queue(0x1, "a");
    try c.queue(0x1, "b");
    try c.queue(0x1, "c");
    try c.writer().flush();
    try c.expectText("a");
    try c.expectText("b");
    try c.expectText("c");
    try c.send(0x1, "count");
    try c.expectText("8");
    try f.waitParked(1);

    // A ping to a parked socket is answered; a pong is dropped.
    try c.send(0xA, "pong");
    try c.send(0x9, "ping");
    var buf: [16]u8 = undefined;
    const pong = try c.next(&buf);
    try std.testing.expectEqual(@as(u8, 0xA), pong.opcode);
    try std.testing.expectEqualStrings("ping", pong.payload);
    try f.waitParked(1);

    // The peer's close is echoed and ends the socket.
    try c.send(0x8, &.{ 0x03, 0xE8 });
    try c.expectClose(1000);
    try f.waitClosed(1);
    try std.testing.expectEqual(1000, last_close_code.load(.acquire));
    try std.testing.expect(c.hungUp());
    try std.testing.expectEqual(0, f.server.parkedConnections());
}

test "WebSocket callbacks: messages, ping and close across parking" {
    try messagesAcrossParking(false);
}

test "WebSocket callbacks: messages, ping and close across parking, over TLS" {
    try messagesAcrossParking(true);
}

test "WebSocket callbacks: another task sends to a parked socket" {
    const gpa = std.testing.allocator;
    var f: Fixture = undefined;
    try f.start(gpa, false, quick);
    defer f.deinit(gpa);

    var c: Client = undefined;
    try c.open(f.io, f.server.address.ip, false, "/ws");
    defer c.close(f.io);
    try c.expectText("hello");
    try f.waitParked(1);
    // From this task, as a broadcast would.
    try last_socket.load(.acquire).?.send(.text, "pushed");
    try c.expectText("pushed");
    // From a task a callback started, which sends once the socket parked.
    try c.send(0x1, "later");
    try f.waitParked(1);
    try c.expectText("later!");
    try f.waitParked(1);
    try c.send(0x1, "x");
    try c.expectText("x");
}

test "WebSocket callbacks: a failing callback closes with 1011" {
    const gpa = std.testing.allocator;
    var f: Fixture = undefined;
    try f.start(gpa, false, quick);
    defer f.deinit(gpa);

    var c: Client = undefined;
    try c.open(f.io, f.server.address.ip, false, "/ws");
    defer c.close(f.io);
    try c.expectText("hello");
    try c.send(0x1, "fail");
    try c.expectClose(1011);
    try std.testing.expect(c.hungUp());
    try f.waitClosed(1);
    try std.testing.expect(last_end_error.load(.acquire));

    // `open` failing: 1011 at once, and `close` still runs.
    var d: Client = undefined;
    try d.open(f.io, f.server.address.ip, false, "/ws?fail=1");
    defer d.close(f.io);
    try d.expectClose(1011);
    try std.testing.expect(d.hungUp());
    try f.waitClosed(2);
}

test "WebSocket callbacks: the drain closes parked sockets with 1001" {
    const gpa = std.testing.allocator;
    var f: Fixture = undefined;
    try f.start(gpa, false, quick);
    defer f.deinit(gpa);

    var clients: [3]Client = undefined;
    for (&clients) |*c| {
        try c.open(f.io, f.server.address.ip, false, "/ws");
        try c.expectText("hello");
    }
    defer for (&clients) |*c| c.close(f.io);
    try f.waitParked(clients.len);

    var stopper = try f.io.concurrent(struct {
        fn run(fx: *Fixture) void {
            fx.stopServer();
        }
    }.run, .{&f});
    // Every socket hears 1001; the drain waits for their answers.
    for (&clients) |*c| try c.expectClose(1001);
    try std.testing.expect(f.server.draining.isSet());
    try std.testing.expectEqual(0, closed.load(.acquire));
    for (&clients) |*c| try c.send(0x8, &.{ 0x03, 0xE9 });
    stopper.await(f.io);
    try std.testing.expectEqual(3, closed.load(.acquire));
    for (&clients) |*c| try std.testing.expect(c.hungUp());
}

test "WebSocket callbacks: stopping the server closes parked sockets" {
    const gpa = std.testing.allocator;
    var f: Fixture = undefined;
    try f.start(gpa, false, .{ .timeout = .{ .idle_park = .fromMilliseconds(30), .shutdown = .fromMilliseconds(200) } });
    defer f.deinit(gpa);

    var clients: [4]Client = undefined;
    for (&clients) |*c| {
        try c.open(f.io, f.server.address.ip, false, "/quiet");
        try c.expectText("hello");
    }
    defer for (&clients) |*c| c.close(f.io);
    try f.waitParked(clients.len);
    // No close on drain: the drain gives up at its deadline, and the stop
    // closes them.
    f.stopServer();
    try std.testing.expectEqual(4, closed.load(.acquire));
    for (&clients) |*c| try std.testing.expect(c.hungUp());
    try std.testing.expectEqual(0, f.server.active_connections.load(.acquire));
}

test "WebSocket callbacks: a callback socket closes at its deadline while parked" {
    const gpa = std.testing.allocator;
    var f: Fixture = undefined;
    try f.start(gpa, false, quick);
    defer f.deinit(gpa);

    var c: Client = undefined;
    try c.open(f.io, f.server.address.ip, false, "/brief");
    defer c.close(f.io);
    try c.expectText("hello");
    try f.waitParked(1);
    try std.testing.expect(c.hungUp());
    try f.waitClosed(1);
}
