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

/// GET /gated: waits for `gated_gate`; when the request's deadline ends the
/// wait, claims it and answers 504.
var gated_timed_out: std.atomic.Value(u32) = .init(0);
var gated_gate: std.Io.Event = .unset;
fn gated(req: *dusty.Request, res: *dusty.Response) !void {
    gated_gate.wait(req.io) catch |err| {
        if (err == error.Canceled and req._claimTimeoutCancel()) {
            _ = gated_timed_out.fetchAdd(1, .release);
            res.status = .gateway_timeout;
            res.body = "late";
            return;
        }
        return err;
    };
    res.body = "gated";
}

/// GET /big: streams 8 MiB, more than the socket buffers hold, and records
/// how its write failed (`big_timed_out` 1, or 2 for another error).
var big_failed: std.atomic.Value(u32) = .init(0);
fn big(_: *dusty.Request, res: *dusty.Response) !void {
    var buf: [16 * 1024]u8 = undefined;
    var body = try res.stream(&buf);
    const chunk: [64 * 1024]u8 = @splat('x');
    for (0..128) |_| {
        body.interface.writeAll(&chunk) catch {
            big_failed.store(if (body.err != null and body.err.? == error.WriteTimeout) 1 else 2, .release);
            return;
        };
    }
}

/// GET /exec: the index of the executor serving the request.
fn exec(req: *dusty.Request, res: *dusty.Response) !void {
    try res.print(.text, "{d}", .{dusty.placement.currentExecutor(req.io) orelse return error.NoExecutor});
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
        self.server.router.get("/exec", exec);
        self.server.router.get("/gated", gated);
        self.server.router.get("/big", big);
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

    /// Deadlines of live connections the shelves' sweeps enforced
    /// (`park.Lazy`), and how many sweeps ran.
    fn lazyFired(self: *Fixture) u32 {
        var n: u32 = 0;
        for (self.server.shelves) |*s| n += s.test_lazy_fired.load(.monotonic);
        return n;
    }

    fn sweeps(self: *Fixture) u32 {
        var n: u32 = 0;
        for (self.server.shelves) |*s| n += s.test_sweeps.load(.monotonic);
        return n;
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

/// With two executors, each connection is served on the executor that
/// accepted it, before and after every park.
fn parkOnAcceptingExecutor(secure: bool) !void {
    if (secure and !have_tls) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var f: Fixture = undefined;
    try f.start(gpa, 2, secure, .{ .idle_park = .fromMilliseconds(30) });
    defer f.stop(gpa);

    var clients: [8]Client = undefined;
    var opened: usize = 0;
    defer for (clients[0..opened]) |*c| c.close(f.io);
    for (&clients) |*c| {
        try c.open(f.io, f.addr(), secure);
        opened += 1;
    }
    var first: [clients.len]u8 = undefined;
    for (&clients, &first) |*c, *e| {
        try c.send("GET /exec HTTP/1.1\r\nHost: x\r\n\r\n");
        e.* = (try c.response()).body[0];
    }
    for (0..3) |_| {
        try f.waitParked(clients.len);
        for (&clients, first) |*c, e| {
            try c.send("GET /exec HTTP/1.1\r\nHost: x\r\n\r\n");
            try std.testing.expectEqual(e, (try c.response()).body[0]);
        }
    }
}

test "idle park: connections park on the executor that accepted them" {
    try parkOnAcceptingExecutor(false);
    try parkOnAcceptingExecutor(true);
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
    // Within a fifth of the delay (TESTING.md D1's 5x margin).
    try wait.waitUntilFor(f.io, "the connection parked again", .fromMilliseconds(40), &f, struct {
        fn one(fx: *Fixture) bool {
            return fx.server.parkedConnections() == 1;
        }
    }.one);
    // Back after a short park: the task stays for the delay (checked at a
    // sixth of it).
    try std.testing.expectEqual(200, try c.get("/"));
    try f.io.sleep(.fromMilliseconds(30), .awake);
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

test "idle park: requests arriving as the connection parks [stress]" {
    // A race hunt: 80 seeded rounds, ~2 s (TESTING.md W3, K1).
    try wait.requireStress();
    try racePark(false);
}

test "idle park: requests arriving as a TLS connection parks [stress]" {
    try wait.requireStress();
    try racePark(true);
}

fn keepAliveDeadline(secure: bool) !void {
    if (secure and !have_tls) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    Server.setParkSweepIntervalForTest(.fromMilliseconds(50));
    defer Server.setParkSweepIntervalForTest(null);
    var f: Fixture = undefined;
    try f.start(gpa, 1, secure, .{ .idle_park = .fromMilliseconds(30), .keepalive = .fromMilliseconds(600) });
    defer f.stop(gpa);

    var c: Client = undefined;
    try c.open(f.io, f.addr(), secure);
    defer c.close(f.io);
    // Before the request: the wait for the next one starts after this, so
    // the keep-alive deadline (600 ms from that start, never swept early)
    // is at least 600 ms from here, however slow the machine. The deadline
    // stays well past the 30 ms park so the parked gauge has a wide window
    // to be seen in; the 50 ms sweep keeps the close prompt after it.
    const before = std.Io.Timestamp.now(f.io, .awake);
    try std.testing.expectEqual(200, try c.get("/"));
    try f.waitParked(1);
    const parked_at = std.Io.Timestamp.now(f.io, .awake);
    try std.testing.expect(c.hungUp());
    // Not closed as it parked: closed at its deadline.
    try std.testing.expect(before.untilNow(f.io, .awake).toMilliseconds() >= 600);
    // Not much later than it (the sweep's 50 ms): a timing claim.
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
    Server.setParkSweepIntervalForTest(.fromMilliseconds(50));
    defer Server.setParkSweepIntervalForTest(null);
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
            defer f.stop(gpa);
            var clients: [16]Client = undefined;
            var opened: usize = 0;
            defer for (clients[0..opened]) |*c| c.close(f.io);
            for (&clients) |*c| {
                try c.open(f.io, f.addr(), secure);
                opened += 1;
            }
            for (&clients) |*c| try std.testing.expectEqual(200, try c.get("/"));
            try f.waitParked(clients.len);
            f.future.cancel(f.io) catch {};
            f.stopped = true;
            try std.testing.expectEqual(0, f.server.active_connections.load(.acquire));
            for (&clients) |*c| try std.testing.expect(c.hungUp());
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

// Deadlines of connections that keep their task (K10): kept to the shelf's
// sweep (`park.Lazy`) rather than to a timer each, on pinned zio, whether
// connections park or not. The sweep runs every 20 ms here; assertions are
// lower bounds (a deadline never fires early), plus the sweep's counter to
// show it was the sweep that fired them.

const ms = std.Io.Duration.fromMilliseconds;

fn elapsedMs(io: std.Io, since: std.Io.Timestamp) i64 {
    return since.untilNow(io, .awake).toMilliseconds();
}

test "deadline sweep: an idle keep-alive connection that keeps its task closes at its keep-alive deadline" {
    const gpa = std.testing.allocator;
    Server.setParkSweepIntervalForTest(ms(20));
    defer Server.setParkSweepIntervalForTest(null);
    // Not parking at all, and parking later than the deadline.
    for ([_]?std.Io.Duration{ null, .fromSeconds(10) }) |idle_park| {
        var f: Fixture = undefined;
        try f.start(gpa, 1, false, .{ .idle_park = idle_park, .keepalive = ms(300) });
        defer f.stop(gpa);
        try std.testing.expect(f.server.shelves.len == 1);

        var c: Client = undefined;
        try c.open(f.io, f.addr(), false);
        defer c.close(f.io);
        const before = std.Io.Timestamp.now(f.io, .awake);
        try std.testing.expectEqual(200, try c.get("/"));
        try std.testing.expect(c.hungUp());
        try std.testing.expect(elapsedMs(f.io, before) >= 300);
        try std.testing.expectEqual(0, f.server.parkedConnections());
        try std.testing.expect(f.lazyFired() >= 1);
        try f.waitClosed();
    }
}

fn headDeadline(secure: bool) !void {
    if (secure and !have_tls) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    Server.setParkSweepIntervalForTest(ms(20));
    defer Server.setParkSweepIntervalForTest(null);
    var f: Fixture = undefined;
    try f.start(gpa, 1, secure, .{ .idle_park = null, .read_header = ms(300) });
    defer f.stop(gpa);

    // The first request's head counts from accept.
    {
        const before = std.Io.Timestamp.now(f.io, .awake);
        var c: Client = undefined;
        try c.open(f.io, f.addr(), secure);
        defer c.close(f.io);
        try c.send("GET / HTTP/1.1\r\nHo");
        try std.testing.expect(c.hungUp());
        try std.testing.expect(elapsedMs(f.io, before) >= 300);
    }
    // A later one's from its first byte.
    {
        var c: Client = undefined;
        try c.open(f.io, f.addr(), secure);
        defer c.close(f.io);
        try std.testing.expectEqual(200, try c.get("/"));
        const before = std.Io.Timestamp.now(f.io, .awake);
        try c.send("GET / HTTP/1.1\r\nHo");
        try std.testing.expect(c.hungUp());
        try std.testing.expect(elapsedMs(f.io, before) >= 300);
    }
    try std.testing.expect(f.lazyFired() >= 2);
    try f.waitClosed();
}

test "deadline sweep: a head that never completes is cut at read_header" {
    try headDeadline(false);
}

test "deadline sweep: a TLS head that never completes is cut at read_header" {
    try headDeadline(true);
}

test "deadline sweep: a head trickled byte by byte is cut at read_header from its first byte" {
    const gpa = std.testing.allocator;
    Server.setParkSweepIntervalForTest(ms(20));
    defer Server.setParkSweepIntervalForTest(null);
    var f: Fixture = undefined;
    try f.start(gpa, 1, false, .{ .idle_park = null, .read_header = ms(300) });
    defer f.stop(gpa);

    var c: Client = undefined;
    try c.open(f.io, f.addr(), false);
    defer c.close(f.io);
    try std.testing.expectEqual(200, try c.get("/"));

    // A header line after each sweep, far longer than the deadline: were
    // each to move it later, the head would never be cut.
    const rounds = 200;
    const Trickle = struct {
        sent: std.atomic.Value(u32) = .init(0),
        fn run(t: *@This(), fx: *Fixture, client: *Client) void {
            for (0..rounds) |_| {
                const Since = struct {
                    fx: *Fixture,
                    seen: u32,
                    fn swept(ctx: @This()) bool {
                        return ctx.fx.sweeps() > ctx.seen;
                    }
                };
                wait.waitUntil(fx.io, "a sweep", Since{ .fx = fx, .seen = fx.sweeps() }, Since.swept) catch return;
                client.send("X-Trickle: x\r\n") catch return;
                _ = t.sent.fetchAdd(1, .release);
            }
        }
    };
    const before = std.Io.Timestamp.now(f.io, .awake);
    try c.send("GET / HTTP/1.1\r\n");
    var trickle: Trickle = .{};
    var future = try f.io.concurrent(Trickle.run, .{ &trickle, &f, &c });
    // After the await below this does nothing.
    defer future.await(f.io);
    try std.testing.expect(c.hungUp());
    try std.testing.expect(elapsedMs(f.io, before) >= 300);
    future.await(f.io);
    try std.testing.expect(trickle.sent.load(.acquire) < rounds);
}

test "deadline sweep: a stalled TLS handshake is cut at the request deadline" {
    if (!have_tls) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    Server.setParkSweepIntervalForTest(ms(20));
    defer Server.setParkSweepIntervalForTest(null);
    var f: Fixture = undefined;
    try f.start(gpa, 1, true, .{ .idle_park = null, .request = ms(300) });
    defer f.stop(gpa);

    const before = std.Io.Timestamp.now(f.io, .awake);
    const stream = try f.addr().connect(f.io, .{ .mode = .stream });
    defer stream.close(f.io);
    var buf: [64]u8 = undefined;
    var r = stream.reader(f.io, &buf);
    // No ClientHello: the server waits for one until the deadline.
    _ = r.interface.takeByte() catch {};
    try std.testing.expect(elapsedMs(f.io, before) >= 300);
    try std.testing.expect(f.lazyFired() >= 1);
    try f.waitClosed();
}

test "deadline sweep: a stream whose peer stops reading ends with WriteTimeout" {
    const gpa = std.testing.allocator;
    Server.setParkSweepIntervalForTest(ms(20));
    defer Server.setParkSweepIntervalForTest(null);
    var f: Fixture = undefined;
    try f.start(gpa, 1, false, .{ .idle_park = null, .write = ms(300) });
    defer f.stop(gpa);
    big_failed.store(0, .release);

    var c: Client = undefined;
    try c.open(f.io, f.addr(), false);
    defer c.close(f.io);
    const before = std.Io.Timestamp.now(f.io, .awake);
    try c.send("GET /big HTTP/1.1\r\nHost: x\r\n\r\n");
    // The client reads none of it.
    _ = try wait.waitNonZero(f.io, "the stream's write failed", &big_failed);
    try std.testing.expectEqual(1, big_failed.load(.acquire));
    try std.testing.expect(elapsedMs(f.io, before) >= 300);
    try std.testing.expect(f.lazyFired() >= 1);
    try f.waitClosed();
}

test "deadline sweep: a handler claims the request deadline the sweep fired, and the connection serves the next request" {
    const gpa = std.testing.allocator;
    Server.setParkSweepIntervalForTest(ms(20));
    defer Server.setParkSweepIntervalForTest(null);
    var f: Fixture = undefined;
    try f.start(gpa, 1, false, .{ .idle_park = null, .request = ms(300) });
    defer f.stop(gpa);
    gated_gate = .unset;
    defer gated_gate.set(f.io);
    const timed_out = gated_timed_out.load(.acquire);

    var c: Client = undefined;
    try c.open(f.io, f.addr(), false);
    defer c.close(f.io);
    for (0..2) |_| {
        const before = std.Io.Timestamp.now(f.io, .awake);
        try c.send("GET /gated HTTP/1.1\r\nHost: x\r\n\r\n");
        const res = try c.response();
        try std.testing.expectEqual(504, res.status);
        try std.testing.expectEqualStrings("late", res.body);
        try std.testing.expect(elapsedMs(f.io, before) >= 300);
        // No cancel left over for the next request's waits.
        try std.testing.expectEqual(200, try c.get("/"));
    }
    try std.testing.expectEqual(timed_out + 2, gated_timed_out.load(.acquire));
}

test "deadline sweep: the drain lets in-flight requests finish and closes idle connections that keep their task" {
    const gpa = std.testing.allocator;
    var f: Fixture = undefined;
    try f.start(gpa, 1, false, .{ .idle_park = null });
    defer f.stop(gpa);

    var idle: [3]Client = undefined;
    for (&idle) |*c| try c.open(f.io, f.addr(), false);
    defer for (&idle) |*c| c.close(f.io);
    for (&idle) |*c| try std.testing.expectEqual(200, try c.get("/"));

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
    defer {
        slow_gate.set(f.io);
        stopper.await(f.io);
    }
    try wait.waitUntil(f.io, "the server draining", &f, struct {
        fn draining(fx: *Fixture) bool {
            return fx.server.draining.isSet();
        }
    }.draining);
    slow_gate.set(f.io);
    try std.testing.expectEqualStrings("slow", (try busy.response()).body);
    stopper.await(f.io);
    for (&idle) |*c| try std.testing.expect(c.hungUp());
    try std.testing.expectEqual(0, f.server.active_connections.load(.acquire));
    f.stopped = true;
}

/// Runs `body` on a task of a one-executor runtime, with a shelf of its own
/// that no driver sweeps: the test sweeps it.
fn onTask(comptime body: fn (std.Io, *Shelf) anyerror!void) !void {
    const rt = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    var future = try io.concurrent(struct {
        fn run(i: std.Io) anyerror!void {
            var shelf: Shelf = .{ .io = i, .long_park = .fromSeconds(1) };
            return body(i, &shelf);
        }
    }.run, .{io});
    try future.await(io);
}

const Shelf = dusty._park.Shelf;
const Timer = dusty._Timer;

/// A moment `d` from the clock the sweep reads.
fn after(io: std.Io, d: std.Io.Duration) std.Io.Clock.Timestamp {
    return dusty._park.now(io).addDuration(d).withClock(.awake);
}

test "deadline sweep: a lazy deadline the sweep found past cancels the task once, and the timer claims it" {
    if (!dusty._park.supported) return error.SkipZigTest;
    try onTask(struct {
        fn body(io: std.Io, shelf: *Shelf) !void {
            var timer: Timer = .init(null);
            timer.register(shelf);
            defer timer.unregister();
            // Not past yet: nothing happens.
            timer.setLazy(io, after(io, .fromSeconds(60)));
            shelf.sweep(dusty._park.now(io));
            try io.checkCancel();
            // Past: one cancel, which `fired` claims.
            timer.setLazy(io, after(io, .zero));
            shelf.sweep(dusty._park.now(io));
            shelf.sweep(dusty._park.now(io));
            try std.testing.expectError(error.Canceled, io.checkCancel());
            try std.testing.expect(timer.fired());
            try io.checkCancel();
            try std.testing.expect(!timer.fired());
            try std.testing.expectEqual(1, shelf.test_lazy_fired.load(.monotonic));
        }
    }.body);
}

test "deadline sweep: a cancel no cancelation point saw is taken back by the next deadline, the exact one, or the clear" {
    if (!dusty._park.supported) return error.SkipZigTest;
    try onTask(struct {
        fn body(io: std.Io, shelf: *Shelf) !void {
            var timer: Timer = .init(null);
            timer.register(shelf);
            defer timer.unregister();
            for (0..3) |how| {
                timer.setLazy(io, after(io, .zero));
                shelf.sweep(dusty._park.now(io));
                // The step finished before any cancelation point.
                switch (how) {
                    0 => timer.setLazy(io, after(io, .fromSeconds(60))),
                    1 => timer.set(io, .{ .duration = .{ .raw = .fromSeconds(60), .clock = .awake } }),
                    else => timer.clear(io),
                }
                try io.checkCancel();
                try std.testing.expect(!timer.fired());
                timer.clear(io);
            }
            // An exact deadline replaces a lazy one: the sweep leaves it.
            timer.setLazy(io, after(io, .zero));
            timer.set(io, .{ .duration = .{ .raw = .fromSeconds(60), .clock = .awake } });
            shelf.sweep(dusty._park.now(io));
            try io.checkCancel();
            timer.clear(io);
        }
    }.body);
}
