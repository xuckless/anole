//! Idle HTTP/1.1 connections that park (`ServerConfig.timeout.idle_park`):
//! they end their task, wait on the executor's shelf, and are served by a
//! new task when the next request arrives. On the real zio runtime, plain and
//! TLS.
const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");
const features = @import("build_options");
const have_tls = features.tls == .boringssl;
const tls = if (have_tls) @import("anole_dusty_tls") else struct {};
const tls_root = if (have_tls) @import("../tls/root.zig") else struct {};
const wait = @import("anole_test_wait");

const Server = dusty.Server(void);
const loopback: dusty.Address = .{ .ip = .{ .ip4 = .loopback(0) } };

fn hello(_: *dusty.Request, res: *dusty.Response) !void {
    res.body = "hello";
}

/// GET /slow: counts itself in, then answers once the test sets
/// `slow_gate`.
var slow_entered: std.atomic.Value(u32) = .init(0);
var slow_gate: std.Io.Event = .unset;
fn slow(req: *dusty.Request, res: *dusty.Response) !void {
    _ = slow_entered.fetchAdd(1, .release);
    try slow_gate.wait(req.io);
    res.body = "slow";
}

/// A client connection, plain or TLS, that writes requests and reads
/// responses with `Content-Length` bodies.
const Client = struct {
    stream: std.Io.net.Stream,
    tcp_reader: std.Io.net.Stream.Reader,
    tcp_writer: std.Io.net.Stream.Writer,
    rbuf: [4096]u8 = undefined,
    wbuf: [4096]u8 = undefined,
    tls_conn: if (have_tls) ?tls.Connection else void = if (have_tls) null else {},
    tls_reader: if (have_tls) tls.Connection.Reader else void = undefined,
    tls_writer: if (have_tls) tls.Connection.Writer else void = undefined,
    plain_in: [if (have_tls) tls.input_buffer_len else 0]u8 = undefined,
    plain_out: [if (have_tls) tls.output_buffer_len else 0]u8 = undefined,

    fn open(self: *Client, io: std.Io, addr: std.Io.net.IpAddress, secure: bool) !void {
        self.stream = try addr.connect(io, .{ .mode = .stream });
        // Callers start from `undefined`, so the field's default never
        // applies: a plain connection must say it has no TLS, or `reader`
        // and `writer` take whatever the bytes happen to hold for one.
        self.tls_conn = if (have_tls) null else {};
        if (comptime have_tls) if (secure) {
            self.tcp_reader = self.stream.reader(io, &self.plain_in);
            self.tcp_writer = self.stream.writer(io, &self.plain_out);
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
            return;
        };
        self.tcp_reader = self.stream.reader(io, &self.rbuf);
        self.tcp_writer = self.stream.writer(io, &self.wbuf);
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

    fn send(self: *Client, bytes: []const u8) !void {
        try self.writer().writeAll(bytes);
        try self.writer().flush();
    }

    /// One response: its status code and body (in the reader's buffer).
    fn response(self: *Client) !struct { status: u16, body: []const u8 } {
        const r = self.reader();
        const status_line = try r.takeDelimiterInclusive('\n');
        const status = try std.fmt.parseInt(u16, status_line[9..12], 10);
        var len: usize = 0;
        while (true) {
            const line = try r.takeDelimiterInclusive('\n');
            if (std.mem.eql(u8, line, "\r\n")) break;
            if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
                len = try std.fmt.parseInt(usize, std.mem.trim(u8, line[15..], " \r\n"), 10);
            }
        }
        return .{ .status = status, .body = try r.take(len) };
    }

    fn get(self: *Client, path: []const u8) !u16 {
        var buf: [128]u8 = undefined;
        try self.send(try std.fmt.bufPrint(&buf, "GET {s} HTTP/1.1\r\nHost: x\r\n\r\n", .{path}));
        return (try self.response()).status;
    }

    /// Whether the server hung up (end of stream, or a reset).
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
    /// `future` was canceled already.
    stopped: bool = false,

    fn start(self: *Fixture, gpa: std.mem.Allocator, executors: usize, secure: bool, timeout: dusty.ServerConfig.Timeout) !void {
        return self.startWith(gpa, executors, secure, timeout, .{ .address = loopback });
    }

    fn startWith(self: *Fixture, gpa: std.mem.Allocator, executors: usize, secure: bool, timeout: dusty.ServerConfig.Timeout, listener: dusty.Listener) !void {
        self.* = .{ .rt = undefined, .io = undefined, .server = undefined };
        self.rt = try zio.Runtime.init(gpa, .{ .executors = .exact(@intCast(executors)) });
        self.io = self.rt.io();
        self.listeners = .{listener};
        if (comptime have_tls) if (secure) {
            self.pem = try tls_root.selfSigned(gpa, .{});
            self.listeners[0].tls = .{ .pem = .{ .cert = self.pem.?.cert, .key = self.pem.?.key }, .alpn_protocols = &.{"http/1.1"} };
        };
        self.server = Server.init(gpa, self.io, .{ .listeners = &self.listeners, .timeout = timeout }, {});
        self.server.router.get("/", hello);
        self.server.router.get("/slow", slow);
        self.future = try self.io.concurrent(struct {
            fn run(s: *Server) anyerror!void {
                try s.run();
            }
        }.run, .{&self.server});
        try self.server.waitReady(self.io);
    }

    fn stop(self: *Fixture, gpa: std.mem.Allocator) void {
        if (!self.stopped) self.future.cancel(self.io) catch {};
        self.server.deinit();
        if (comptime have_tls) if (self.pem) |*p| p.deinit(gpa);
        self.rt.deinit();
    }

    fn addr(self: *Fixture) std.Io.net.IpAddress {
        return self.server.address.ip;
    }

    /// Waits for `n` connections to be parked.
    fn waitParked(self: *Fixture, n: usize) !void {
        const C = struct {
            f: *Fixture,
            n: usize,
            fn parked(c: @This()) bool {
                return c.f.server.parkedConnections() == c.n;
            }
        };
        wait.waitUntil(self.io, "the connections parked", C{ .f = self, .n = n }, C.parked) catch |err| {
            std.debug.print("parked: {d}, want {d}\n", .{ self.server.parkedConnections(), n });
            return err;
        };
    }

    fn waitClosed(self: *Fixture) !void {
        try wait.waitUntil(self.io, "the server has no connections", self, struct {
            fn f(fx: *Fixture) bool {
                return fx.server.active_connections.load(.acquire) == 0;
            }
        }.f);
    }
};

fn parkAndResume(secure: bool, executors: usize) !void {
    if (secure and !have_tls) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var f: Fixture = undefined;
    try f.start(gpa, executors, secure, .{ .idle_park = .fromMilliseconds(30) });
    defer f.stop(gpa);

    var clients: [4]Client = undefined;
    for (&clients) |*c| try c.open(f.io, f.addr(), secure);
    defer for (&clients) |*c| c.close(f.io);

    for (0..3) |_| {
        for (&clients) |*c| try std.testing.expectEqual(200, try c.get("/"));
        try f.waitParked(clients.len);
    }
    // Two requests in one write, to a parked connection: both answered.
    try clients[0].send("GET / HTTP/1.1\r\nHost: x\r\n\r\nGET / HTTP/1.1\r\nHost: x\r\n\r\n");
    try std.testing.expectEqualStrings("hello", (try clients[0].response()).body);
    try std.testing.expectEqualStrings("hello", (try clients[0].response()).body);
    try f.waitParked(clients.len);
}

test "idle park: a plain connection parks and is served again" {
    try parkAndResume(false, 1);
}

test "idle park: a TLS connection parks and is served again" {
    try parkAndResume(true, 1);
}

test "idle park: connections park on the executor that accepted them" {
    try parkAndResume(false, 2);
    try parkAndResume(true, 2);
}

test "idle park: a connection busier than the park delay keeps its task [timing]" {
    // Requests 20 ms apart against a 200 ms delay: on a loaded machine the
    // gap itself can pass the delay (TESTING.md D6).
    try wait.requireTiming();
    const gpa = std.testing.allocator;
    var f: Fixture = undefined;
    try f.start(gpa, 1, false, .{ .idle_park = .fromMilliseconds(200) });
    defer f.stop(gpa);

    var c: Client = undefined;
    try c.open(f.io, f.addr(), false);
    defer c.close(f.io);
    for (0..10) |_| {
        try std.testing.expectEqual(200, try c.get("/"));
        try f.io.sleep(.fromMilliseconds(20), .awake);
        try std.testing.expectEqual(0, f.server.parkedConnections());
    }
}

/// A connection that was parked for the park delay or longer parks again
/// as soon as it has answered what woke it; one that comes back sooner keeps
/// its task for the delay, as a busy connection does.
fn reparkAfterLongPark(secure: bool) !void {
    if (secure and !have_tls) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var f: Fixture = undefined;
    try f.start(gpa, 1, secure, .{ .idle_park = .fromMilliseconds(200) });
    defer f.stop(gpa);

    var c: Client = undefined;
    try c.open(f.io, f.addr(), secure);
    defer c.close(f.io);
    try std.testing.expectEqual(200, try c.get("/"));
    try f.waitParked(1);
    try f.io.sleep(.fromMilliseconds(250), .awake);
    // Parked long: answered, and parked again well within the delay.
    try std.testing.expectEqual(200, try c.get("/"));
    const parked_again = for (0..20) |_| {
        if (f.server.parkedConnections() == 1) break true;
        try f.io.sleep(.fromMilliseconds(5), .awake);
    } else false;
    try std.testing.expect(parked_again);
    // Back after a short park: the task stays for the delay.
    try std.testing.expectEqual(200, try c.get("/"));
    try f.io.sleep(.fromMilliseconds(60), .awake);
    try std.testing.expectEqual(0, f.server.parkedConnections());
    try f.waitParked(1);
}

test "idle park: a connection woken after a long park parks again once answered [timing]" {
    // "Within the delay" and "for the delay" are elapsed-time claims.
    try wait.requireTiming();
    try reparkAfterLongPark(false);
    try reparkAfterLongPark(true);
}

/// Requests sent as close to the park delay as the timing allows, some in
/// two pieces with the second after it, so that bytes arrive while the
/// connection is parking.
fn racePark(secure: bool) !void {
    if (secure and !have_tls) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var f: Fixture = undefined;
    try f.start(gpa, 1, secure, .{ .idle_park = .fromMilliseconds(10) });
    defer f.stop(gpa);

    var c: Client = undefined;
    try c.open(f.io, f.addr(), secure);
    defer c.close(f.io);
    var prng: std.Random.DefaultPrng = .init(0x9a2c);
    const random = prng.random();
    const request = "GET / HTTP/1.1\r\nHost: x\r\n\r\n";
    for (0..80) |i| {
        try f.io.sleep(.fromMicroseconds(8_000 + random.uintLessThan(u32, 4_000)), .awake);
        if (i % 2 == 0) {
            try c.send(request ++ request);
            for (0..2) |_| try std.testing.expectEqualStrings("hello", (try c.response()).body);
        } else {
            const cut = random.uintLessThan(usize, request.len - 1) + 1;
            try c.send(request[0..cut]);
            try f.io.sleep(.fromMicroseconds(random.uintLessThan(u32, 15_000)), .awake);
            try c.send(request[cut..]);
            try std.testing.expectEqualStrings("hello", (try c.response()).body);
        }
    }
}

test "idle park: requests arriving as the connection parks" {
    try racePark(false);
}

test "idle park: requests arriving as a TLS connection parks" {
    try racePark(true);
}

fn keepAliveDeadline(secure: bool) !void {
    if (secure and !have_tls) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var f: Fixture = undefined;
    try f.start(gpa, 1, secure, .{ .idle_park = .fromMilliseconds(30), .keepalive = .fromMilliseconds(600) });
    defer f.stop(gpa);

    var c: Client = undefined;
    try c.open(f.io, f.addr(), secure);
    defer c.close(f.io);
    // Before the request: the wait for the next one starts after this, so
    // the keep-alive deadline (600 ms from that start, never swept early)
    // is at least 600 ms from here, however slow the machine.
    const before = std.Io.Timestamp.now(f.io, .awake);
    try std.testing.expectEqual(200, try c.get("/"));
    try f.waitParked(1);
    const parked_at = std.Io.Timestamp.now(f.io, .awake);
    try std.testing.expect(c.hungUp());
    // Not closed as it parked: closed at its deadline.
    try std.testing.expect(before.untilNow(f.io, .awake).toMilliseconds() >= 600);
    // Not much later than it (the sweep's second): a timing claim.
    const waited = parked_at.untilNow(f.io, .awake).toMilliseconds();
    if (wait.timing()) try std.testing.expect(waited < 2_500);
    try f.waitClosed();
    try std.testing.expectEqual(0, f.server.parkedConnections());
}

test "idle park: a parked connection is closed at its keep-alive deadline" {
    try keepAliveDeadline(false);
}

test "idle park: a parked TLS connection gets a close_notify at its keep-alive deadline" {
    try keepAliveDeadline(true);
}

test "idle park: a connection that never sends a request parks under the request deadline" {
    const gpa = std.testing.allocator;
    var f: Fixture = undefined;
    try f.start(gpa, 1, false, .{ .idle_park = .fromMilliseconds(30), .request = .fromMilliseconds(500) });
    defer f.stop(gpa);

    var c: Client = undefined;
    try c.open(f.io, f.addr(), false);
    defer c.close(f.io);
    try f.waitParked(1);
    try std.testing.expect(c.hungUp());
    try f.waitClosed();
}

test "idle park: a connection parked before its first request can still speak HTTP/2 with prior knowledge" {
    if (!features.http2) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var f: Fixture = undefined;
    try f.startWith(gpa, 1, false, .{ .idle_park = .fromMilliseconds(30) }, .{ .address = loopback, .http2_prior_knowledge = true });
    defer f.stop(gpa);

    var c: Client = undefined;
    try c.open(f.io, f.addr(), false);
    defer c.close(f.io);
    try f.waitParked(1);
    // The preface and an empty SETTINGS: the server's SETTINGS comes back.
    try c.send("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" ++ "\x00\x00\x00\x04\x00\x00\x00\x00\x00");
    const head = try c.reader().takeArray(9);
    try std.testing.expectEqual(0x04, head[3]);
}

test "idle park: the drain answers a parked connection's request 503, and the stop closes the rest" {
    const gpa = std.testing.allocator;
    var f: Fixture = undefined;
    try f.start(gpa, 1, false, .{ .idle_park = .fromMilliseconds(30) });
    defer f.stop(gpa);

    var idle: [3]Client = undefined;
    for (&idle) |*c| try c.open(f.io, f.addr(), false);
    defer for (&idle) |*c| c.close(f.io);
    for (&idle) |*c| try std.testing.expectEqual(200, try c.get("/"));
    try f.waitParked(idle.len);

    // A request the drain waits for (held until the test lets it go), then
    // the drain.
    slow_gate = .unset;
    defer slow_gate.set(f.io);
    const entered = slow_entered.load(.acquire);
    var busy: Client = undefined;
    try busy.open(f.io, f.addr(), false);
    defer busy.close(f.io);
    try busy.send("GET /slow HTTP/1.1\r\nHost: x\r\n\r\n");
    try wait.waitAtLeast(f.io, "the slow request in its handler", &slow_entered, entered + 1);
    var stopper = try f.io.concurrent(struct {
        fn run(fx: *Fixture) void {
            fx.future.cancel(fx.io) catch {};
        }
    }.run, .{&f});
    // A failed wait lets the held request go and waits for the stop before
    // the fixture goes; after the await below this does nothing.
    defer {
        slow_gate.set(f.io);
        stopper.await(f.io);
    }
    try wait.waitUntil(f.io, "the server draining", &f, struct {
        fn draining(fx: *Fixture) bool {
            return fx.server.draining.isSet();
        }
    }.draining);

    // A parked connection woken during the drain is refused.
    try std.testing.expectEqual(503, try idle[0].get("/"));
    slow_gate.set(f.io);
    try std.testing.expectEqualStrings("slow", (try busy.response()).body);
    stopper.await(f.io);
    // The other parked ones were closed when the server stopped.
    for (idle[1..]) |*c| try std.testing.expect(c.hungUp());
    try std.testing.expectEqual(0, f.server.active_connections.load(.acquire));
    // Already canceled and collected.
    f.stopped = true;
}

test "idle park: stopping the server with many parked connections closes them all" {
    const gpa = std.testing.allocator;
    inline for (.{ false, true }) |secure| {
        if (!secure or have_tls) {
            var f: Fixture = undefined;
            try f.start(gpa, 2, secure, .{ .idle_park = .fromMilliseconds(20) });
            var clients: [16]Client = undefined;
            for (&clients) |*c| try c.open(f.io, f.addr(), secure);
            for (&clients) |*c| try std.testing.expectEqual(200, try c.get("/"));
            try f.waitParked(clients.len);
            f.future.cancel(f.io) catch {};
            try std.testing.expectEqual(0, f.server.active_connections.load(.acquire));
            for (&clients) |*c| try std.testing.expect(c.hungUp());
            for (&clients) |*c| c.close(f.io);
            f.server.deinit();
            if (comptime have_tls) if (f.pem) |*p| p.deinit(gpa);
            f.rt.deinit();
        }
    }
}

test "idle park: off, a connection keeps its task" {
    const gpa = std.testing.allocator;
    var f: Fixture = undefined;
    try f.start(gpa, 1, false, .{ .idle_park = null });
    defer f.stop(gpa);

    var c: Client = undefined;
    try c.open(f.io, f.addr(), false);
    defer c.close(f.io);
    try std.testing.expectEqual(200, try c.get("/"));
    try wait.expectStays(f.io, "no connection parks", &f, struct {
        fn noneParked(fx: *Fixture) bool {
            return fx.server.parkedConnections() == 0;
        }
    }.noneParked, wait.short_window);
    try std.testing.expectEqual(200, try c.get("/"));
}

test "idle park: peers that hang up or reset are closed, parked or mid-request" {
    const gpa = std.testing.allocator;
    var f: Fixture = undefined;
    try f.start(gpa, 1, false, .{ .idle_park = .fromMilliseconds(30) });
    defer f.stop(gpa);

    var clients: [8]Client = undefined;
    for (&clients) |*c| {
        try c.open(f.io, f.addr(), false);
        try std.testing.expectEqual(200, try c.get("/"));
    }
    try f.waitParked(clients.len);
    for (&clients, 0..) |*c, i| {
        // Half of them in the middle of a request head.
        if (i % 4 >= 2) try c.send("GET / HTTP/1.1\r\nHo");
        if (i % 2 == 1) {
            const linger = extern struct { onoff: c_int, seconds: c_int }{ .onoff = 1, .seconds = 0 };
            std.posix.setsockopt(c.stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.LINGER, std.mem.asBytes(&linger)) catch {};
        }
        c.close(f.io);
    }
    try f.waitClosed();
    try std.testing.expectEqual(0, f.server.parkedConnections());
}
