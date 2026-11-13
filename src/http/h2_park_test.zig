//! The new HTTP/2 engine's lifecycle on the real zio, through `Server.run`
//! (src/http/core/h2/server.zig; research/h2h3-takeover/PLAN.md §3.3,
//! §3.5): idle connections park and resume (D16, #97), the keep-alive,
//! write and send deadlines, and the drain's two-phase GOAWAY. The server
//! picks the engine per instance (`test_h2_engine`) until the switch. The
//! shelves sweep every 20 ms here (`setParkSweepIntervalForTest`); waits
//! are on the engine's and the server's counters, never on time.
const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");
const features = @import("build_options");
const have_tls = features.tls == .boringssl;
const tls = if (have_tls) @import("anole_dusty_tls") else struct {};
const tls_root = if (have_tls) @import("../tls/root.zig") else struct {};
const wait = @import("anole_test_wait");

const h2 = dusty.h2_core_for_tests;
const frame = h2.frame;
const hpack = h2.hpack;
const engine = h2.server;
const F = frame.flags;

const Server = dusty.Server(void);
const loopback: dusty.Address = .{ .ip = .{ .ip4 = .loopback(0) } };

fn hello(_: *dusty.Request, res: *dusty.Response) !void {
    res.body = "hello";
}

fn empty(_: *dusty.Request, res: *dusty.Response) !void {
    res.status = .no_content;
}

/// GET /held: counts itself in, then answers once the test sets
/// `held_gate`.
var held_entered: std.atomic.Value(u32) = .init(0);
var held_gate: std.Io.Event = .unset;
fn held(req: *dusty.Request, res: *dusty.Response) !void {
    _ = held_entered.fetchAdd(1, .release);
    try held_gate.wait(req.io);
    res.body = "held but whole";
}

/// GET /whole: 100 KiB in one piece.
fn whole(_: *dusty.Request, res: *dusty.Response) !void {
    const body: [100 * 1024]u8 = @splat('z');
    res.body = &body;
}

/// GET /big: streams 8 MiB, more than the socket buffers hold.
fn big(_: *dusty.Request, res: *dusty.Response) !void {
    var buf: [16 * 1024]u8 = undefined;
    var body = try res.stream(&buf);
    const chunk: [64 * 1024]u8 = @splat('x');
    for (0..128) |_| try body.interface.writeAll(&chunk);
    try body.end();
}

const Resp = struct {
    status: u16 = 0,
    body_len: usize = 0,
    ended: bool = false,
    rst: ?u32 = null,

    fn done(r: *const Resp) bool {
        return r.ended or r.rst != null;
    }
};

/// A client on our own codecs, plain (prior knowledge) or TLS (ALPN h2).
const Client = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    tcp_reader: std.Io.net.Stream.Reader,
    tcp_writer: std.Io.net.Stream.Writer,
    rbuf: [64 * 1024]u8 = undefined,
    wbuf: [16 * 1024]u8 = undefined,
    tls_conn: if (have_tls) ?tls.Connection else void = if (have_tls) null else {},
    tls_reader: if (have_tls) tls.Connection.Reader else void = undefined,
    tls_writer: if (have_tls) tls.Connection.Writer else void = undefined,
    plain_in: [if (have_tls) tls.input_buffer_len else 0]u8 = undefined,
    plain_out: [if (have_tls) tls.output_buffer_len else 0]u8 = undefined,
    enc: hpack.Encoder = .{},
    dec: hpack.Decoder = .init(.{}),
    scratch: [16 * 1024]u8 = undefined,
    resps: [128]Resp = @splat(.{}),
    next_id: u31 = 1,
    /// GOAWAYs received (last-stream-id each), and PINGs.
    goaways: [4]u31 = @splat(0),
    goaway_count: usize = 0,
    pings: usize = 0,
    /// Answer the server's PINGs (the drain's).
    answer_pings: bool = true,
    /// WINDOW_UPDATEs for what arrives.
    auto_window: bool = true,

    const Opts = struct {
        /// SETTINGS_INITIAL_WINDOW_SIZE to send, if any.
        initial_window: ?u31 = null,
        /// A connection WINDOW_UPDATE of this much right after.
        conn_window_raise: u31 = 0,
    };

    fn open(self: *Client, io: std.Io, addr: std.Io.net.IpAddress, secure: bool, opts: Opts) !void {
        self.* = .{ .io = io, .stream = undefined, .tcp_reader = undefined, .tcp_writer = undefined };
        self.stream = try addr.connect(io, .{ .mode = .stream });
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
                .alpn_protocols = &.{"h2"},
            });
            self.tls_reader = self.tls_conn.?.reader(&self.rbuf);
            self.tls_writer = self.tls_conn.?.writer(&self.wbuf);
        };
        if (!secure) {
            self.tcp_reader = self.stream.reader(io, &self.rbuf);
            self.tcp_writer = self.stream.writer(io, &self.wbuf);
        }
        try self.writer().writeAll(engine.preface);
        if (opts.initial_window) |v| {
            var b: [6]u8 = undefined;
            std.mem.writeInt(u16, b[0..2], @backingInt(frame.SettingId.initial_window_size), .big);
            std.mem.writeInt(u32, b[2..6], v, .big);
            try self.frameOut(.settings, 0, 0, &b);
        } else try self.frameOut(.settings, 0, 0, "");
        if (opts.conn_window_raise > 0) try self.windowUpdate(0, opts.conn_window_raise);
        try self.flush();
    }

    fn close(self: *Client) void {
        if (comptime have_tls) if (self.tls_conn) |*c| c.deinit();
        self.stream.close(self.io);
    }

    fn reader(self: *Client) *std.Io.Reader {
        if (comptime have_tls) if (self.tls_conn != null) return &self.tls_reader.interface;
        return &self.tcp_reader.interface;
    }

    fn writer(self: *Client) *std.Io.Writer {
        if (comptime have_tls) if (self.tls_conn != null) return &self.tls_writer.interface;
        return &self.tcp_writer.interface;
    }

    fn flush(self: *Client) !void {
        try self.writer().flush();
    }

    fn frameOut(self: *Client, ty: frame.Type, fl: u8, id: u31, payload: []const u8) !void {
        var h: [frame.header_len]u8 = undefined;
        _ = frame.writeHeader(&h, .{ .length = @intCast(payload.len), .type = ty, .flags = fl, .stream_id = id });
        try self.writer().writeAll(&h);
        try self.writer().writeAll(payload);
    }

    fn windowUpdate(self: *Client, id: u31, inc: u31) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, inc, .big);
        try self.frameOut(.window_update, 0, id, &b);
    }

    /// The HEADERS of a GET, whole, encoded (not sent).
    fn getBlock(self: *Client, path: []const u8, out: []u8) !usize {
        return self.enc.encode(out, &.{
            .{ .name = ":method", .value = "GET" },
            .{ .name = ":scheme", .value = "https" },
            .{ .name = ":path", .value = path },
            .{ .name = ":authority", .value = "localhost" },
        });
    }

    /// Sends a GET, flushed; its stream ID.
    fn get(self: *Client, path: []const u8) !u31 {
        const id = self.next_id;
        self.next_id += 2;
        var block: [256]u8 = undefined;
        const n = try self.getBlock(path, &block);
        try self.frameOut(.headers, F.end_headers | F.end_stream, id, block[0..n]);
        try self.flush();
        return id;
    }

    fn resp(self: *Client, id: u31) *Resp {
        return &self.resps[(id - 1) / 2];
    }

    /// Reads one frame and acts on it.
    fn readOne(self: *Client) !void {
        const r = self.reader();
        const head = try r.peek(frame.header_len);
        const fh = frame.FrameHeader.parse(head[0..frame.header_len]);
        const payload = (try r.take(frame.header_len + fh.length))[frame.header_len..];
        switch (fh.type) {
            .settings => if (fh.flags & F.ack == 0) {
                try self.frameOut(.settings, F.ack, 0, "");
                try self.flush();
            },
            .ping => if (fh.flags & F.ack == 0) {
                self.pings += 1;
                if (self.answer_pings) {
                    try self.frameOut(.ping, F.ack, 0, payload[0..8]);
                    try self.flush();
                }
            },
            .goaway => {
                if (self.goaway_count < self.goaways.len) self.goaways[self.goaway_count] = @intCast(std.mem.readInt(u32, payload[0..4], .big) & 0x7fffffff);
                self.goaway_count += 1;
            },
            .rst_stream => self.resp(fh.stream_id).rst = std.mem.readInt(u32, payload[0..4], .big),
            .headers => {
                const rs = self.resp(fh.stream_id);
                var blk = self.dec.block(payload, &self.scratch, self.scratch.len);
                while (try blk.next()) |f| {
                    if (std.mem.eql(u8, f.name, ":status")) rs.status = try std.fmt.parseInt(u16, f.value, 10);
                }
                if (fh.flags & F.end_stream != 0) rs.ended = true;
            },
            .data => {
                const rs = self.resp(fh.stream_id);
                rs.body_len += payload.len;
                if (fh.flags & F.end_stream != 0) rs.ended = true;
                if (self.auto_window and payload.len > 0) {
                    try self.windowUpdate(0, @intCast(payload.len));
                    if (!rs.ended) try self.windowUpdate(fh.stream_id, @intCast(payload.len));
                    try self.flush();
                }
            },
            else => {},
        }
    }

    fn until(self: *Client, id: u31) !*Resp {
        const rs = self.resp(id);
        while (!rs.done()) try self.readOne();
        return rs;
    }

    /// A GET answered: its status.
    fn status(self: *Client, path: []const u8) !u16 {
        return (try self.until(try self.get(path))).status;
    }

    /// Reads until the server hangs up (end of stream, or a reset).
    fn untilClosed(self: *Client) void {
        while (true) self.readOne() catch return;
    }

    /// Reads until the server hangs up: how (`error.EndOfStream` for a
    /// clean end, `error.ReadFailed` for a reset).
    fn closeCause(self: *Client) anyerror {
        while (true) self.readOne() catch |err| return err;
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

    fn start(self: *Fixture, gpa: std.mem.Allocator, secure: bool, timeout: dusty.ServerConfig.Timeout) !void {
        self.* = .{ .rt = undefined, .io = undefined, .server = undefined };
        self.rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
        self.io = self.rt.io();
        self.listeners = .{.{ .address = loopback, .http2_prior_knowledge = true }};
        if (comptime have_tls) if (secure) {
            self.pem = try tls_root.selfSigned(gpa, .{});
            self.listeners[0].tls = .{ .pem = .{ .cert = self.pem.?.cert, .key = self.pem.?.key }, .alpn_protocols = &.{ "h2", "http/1.1" } };
        };
        self.server = Server.init(gpa, self.io, .{ .listeners = &self.listeners, .timeout = timeout }, {});
        self.server.test_h2_engine = .anole;
        self.server.router.get("/", hello);
        self.server.router.get("/empty", empty);
        self.server.router.get("/held", held);
        self.server.router.get("/whole", whole);
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

    /// Stops the server (its drain) from another task.
    fn stopper(self: *Fixture) void {
        self.stopped = true;
        self.future.cancel(self.io) catch {};
    }

    fn addr(self: *Fixture) std.Io.net.IpAddress {
        return self.server.address.ip;
    }

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

fn sweepFast() void {
    Server.setParkSweepIntervalForTest(.fromMilliseconds(20));
}

fn sweepNormal() void {
    Server.setParkSweepIntervalForTest(null);
}

fn parkAndResume(secure: bool) !void {
    if (secure and !have_tls) return error.SkipZigTest;
    if (!features.http2) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    sweepFast();
    defer sweepNormal();
    var f: Fixture = undefined;
    try f.start(gpa, secure, .{ .idle_park = .fromMilliseconds(30) });
    defer f.stop(gpa);

    var c: Client = undefined;
    try c.open(f.io, f.addr(), secure, .{});
    defer c.close();
    const parks = engine.test_parks.load(.acquire);
    try std.testing.expectEqual(200, try c.status("/"));
    try f.waitParked(1);
    try wait.waitAtLeast(f.io, "the engine parked it", &engine.test_parks, parks + 1);
    // Parked idle: no task, no read buffer, not in flight for the drain.
    try std.testing.expectEqual(0, engine.test_read_buffers.load(.acquire));
    try std.testing.expectEqual(0, f.server.busy.load(.acquire).count);
    // The next request wakes it, on the same connection.
    try std.testing.expectEqual(200, try c.status("/"));
    try f.waitParked(1);
    try std.testing.expectEqual(204, try c.status("/empty"));
    try f.waitParked(1);
    try std.testing.expect(engine.test_parks.load(.acquire) >= parks + 3);
}

test "h2 lifecycle: an idle connection parks and resumes on the next request" {
    try parkAndResume(false);
}

test "h2 lifecycle: an idle TLS connection parks and resumes on the next request" {
    try parkAndResume(true);
}

test "h2 lifecycle: many idle connections release their buffers" {
    if (!features.http2) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    sweepFast();
    defer sweepNormal();
    var f: Fixture = undefined;
    try f.start(gpa, false, .{ .idle_park = .fromMilliseconds(30) });
    defer f.stop(gpa);

    const n = 64;
    const clients = try gpa.alloc(Client, n);
    defer gpa.free(clients);
    for (clients) |*c| try c.open(f.io, f.addr(), false, .{});
    defer for (clients) |*c| c.close();
    for (clients) |*c| try std.testing.expectEqual(200, try c.status("/"));
    try f.waitParked(n);
    // No read buffer held, no count in flight: what a parked connection
    // keeps is its heap state (the protocol core with its HPACK tables).
    try std.testing.expectEqual(0, engine.test_read_buffers.load(.acquire));
    try std.testing.expectEqual(0, f.server.busy.load(.acquire).count);
    for (clients) |*c| try std.testing.expectEqual(200, try c.status("/"));
    try f.waitParked(n);
}

test "h2 lifecycle: a partial frame keeps the connection on its task until the frame completes, then it parks" {
    if (!features.http2) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    sweepFast();
    defer sweepNormal();
    var f: Fixture = undefined;
    try f.start(gpa, false, .{ .idle_park = .fromMilliseconds(30) });
    defer f.stop(gpa);

    var c: Client = undefined;
    try c.open(f.io, f.addr(), false, .{});
    defer c.close();
    try std.testing.expectEqual(200, try c.status("/"));

    // A HEADERS frame cut after 5 bytes of its header.
    var block: [256]u8 = undefined;
    const len = try c.getBlock("/", &block);
    var h: [frame.header_len]u8 = undefined;
    const id = c.next_id;
    c.next_id += 2;
    _ = frame.writeHeader(&h, .{ .length = @intCast(len), .type = .headers, .flags = F.end_headers | F.end_stream, .stream_id = id });
    const refused = engine.test_park_refused_partial.load(.acquire);
    try c.writer().writeAll(h[0..5]);
    try c.flush();
    try wait.waitAtLeast(f.io, "a wait kept on the task for the partial frame", &engine.test_park_refused_partial, refused + 1);
    try std.testing.expectEqual(0, f.server.parkedConnections());
    try c.writer().writeAll(h[5..]);
    try c.writer().writeAll(block[0..len]);
    try c.flush();
    try std.testing.expectEqual(200, (try c.until(id)).status);
    try f.waitParked(1);
}

fn keepAlive(idle_park: ?std.Io.Duration) !void {
    if (!features.http2) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    sweepFast();
    defer sweepNormal();
    var f: Fixture = undefined;
    try f.start(gpa, false, .{ .idle_park = idle_park, .keepalive = .fromMilliseconds(300) });
    defer f.stop(gpa);

    var c: Client = undefined;
    try c.open(f.io, f.addr(), false, .{});
    defer c.close();
    const closes = engine.test_keepalive_closes.load(.acquire);
    try std.testing.expectEqual(200, try c.status("/"));
    if (idle_park != null) try f.waitParked(1);
    c.untilClosed();
    if (idle_park == null) {
        // Closed by its own task: a GOAWAY(NO_ERROR) first.
        try std.testing.expectEqual(1, c.goaway_count);
        try std.testing.expect(engine.test_keepalive_closes.load(.acquire) > closes);
    }
    try f.waitClosed();
}

test "h2 lifecycle: keepalive closes an idle connection on its task" {
    try keepAlive(null);
}

test "h2 lifecycle: keepalive closes a parked connection" {
    try keepAlive(.fromMilliseconds(30));
}

test "h2 lifecycle: a peer that stops reading is cut at timeouts.write" {
    if (!features.http2) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    sweepFast();
    defer sweepNormal();
    var f: Fixture = undefined;
    try f.start(gpa, false, .{ .write = .fromMilliseconds(300) });
    defer f.stop(gpa);

    var c: Client = undefined;
    // Windows wide open: only the socket holds the server back.
    try c.open(f.io, f.addr(), false, .{ .initial_window = std.math.maxInt(u31), .conn_window_raise = std.math.maxInt(u31) - 65535 });
    defer c.close();
    const timeouts = engine.test_write_timeouts.load(.acquire);
    _ = try c.get("/big");
    // Never read again.
    try wait.waitAtLeast(f.io, "the write cut at timeouts.write", &engine.test_write_timeouts, timeouts + 1);
    try f.waitClosed();
}

test "h2 lifecycle: a finished response the peer never takes is reset at its send deadline" {
    if (!features.http2) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    sweepFast();
    defer sweepNormal();
    var f: Fixture = undefined;
    try f.start(gpa, false, .{ .request = .fromMilliseconds(300) });
    defer f.stop(gpa);

    var c: Client = undefined;
    // A stream window of zero: the head may go, never the body.
    try c.open(f.io, f.addr(), false, .{ .initial_window = 0 });
    defer c.close();
    const resets = engine.test_send_resets.load(.acquire);
    const id = try c.get("/whole");
    const rs = try c.until(id);
    try std.testing.expectEqual(200, rs.status);
    try std.testing.expectEqual(@backingInt(frame.ErrorCode.cancel), rs.rst.?);
    try std.testing.expect(engine.test_send_resets.load(.acquire) > resets);
    // Only that stream: the connection serves on.
    try std.testing.expectEqual(204, try c.status("/empty"));
}

/// The drain with a request in flight: the notice (2^31-1) and the PING,
/// the final GOAWAY naming the held stream (at the PING's ACK, or when the
/// drain asks a second later for a client that does not answer), then the
/// held response whole, then the close.
fn drainInFlight(secure: bool, answer_pings: bool) !void {
    if (secure and !have_tls) return error.SkipZigTest;
    if (!features.http2) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    sweepFast();
    defer sweepNormal();
    var f: Fixture = undefined;
    try f.start(gpa, secure, .{ .idle_park = .fromMilliseconds(30) });
    defer f.stop(gpa);

    var c: Client = undefined;
    try c.open(f.io, f.addr(), secure, .{});
    defer c.close();
    c.answer_pings = answer_pings;
    try std.testing.expectEqual(200, try c.status("/"));

    held_gate = .unset;
    const entered = held_entered.load(.acquire);
    const id = try c.get("/held");
    try wait.waitAtLeast(f.io, "the held request's handler runs", &held_entered, entered + 1);
    var stopper = try f.io.concurrent(Fixture.stopper, .{&f});
    defer stopper.await(f.io);

    while (c.goaway_count < 2) try c.readOne();
    try std.testing.expectEqual(std.math.maxInt(u31), c.goaways[0]);
    try std.testing.expectEqual(id, c.goaways[1]);
    try std.testing.expect(c.pings >= 1);
    held_gate.set(f.io);
    const rs = try c.until(id);
    try std.testing.expectEqual(200, rs.status);
    try std.testing.expectEqual("held but whole".len, rs.body_len);
    c.untilClosed();
}

test "h2 lifecycle: the drain sends the notice GOAWAY and a PING, then the final GOAWAY, and the stream in flight finishes" {
    try drainInFlight(false, true);
}

test "h2 lifecycle: the drain's final GOAWAY comes without the PING's answer" {
    try drainInFlight(false, false);
}

test "h2 lifecycle: the drain over TLS" {
    try drainInFlight(true, true);
}

test "h2 lifecycle: the drain's close lets the peer's late frames in, and it reads a clean end" {
    if (!features.http2) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    sweepFast();
    defer sweepNormal();
    var f: Fixture = undefined;
    try f.start(gpa, false, .{ .idle_park = .fromMilliseconds(30) });
    defer f.stop(gpa);

    var c: Client = undefined;
    try c.open(f.io, f.addr(), false, .{});
    defer c.close();
    held_gate = .unset;
    const entered = held_entered.load(.acquire);
    const id = try c.get("/held");
    try wait.waitAtLeast(f.io, "the held request's handler runs", &held_entered, entered + 1);
    const closes = engine.test_drain_closes.load(.acquire);
    var stopper = try f.io.concurrent(Fixture.stopper, .{&f});
    defer stopper.await(f.io);
    while (c.goaway_count < 2) try c.readOne();
    held_gate.set(f.io);
    try wait.waitAtLeast(f.io, "the drained connection's send side shut", &engine.test_drain_closes, closes + 1);
    // The peer still talks after the server's last frame (credit, a PING),
    // as a client reading a large response does: the server reads and
    // drops it rather than answer it with a reset.
    try c.windowUpdate(0, 1024);
    try c.frameOut(.ping, 0, 0, "late....");
    try c.flush();
    const rs = try c.until(id);
    try std.testing.expectEqual(200, rs.status);
    try std.testing.expectEqual("held but whole".len, rs.body_len);
    try std.testing.expectEqual(error.EndOfStream, c.closeCause());
}

test "h2 lifecycle: keepalive closes a connection with a TLS record half read" {
    if (!have_tls or !features.http2) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    sweepFast();
    defer sweepNormal();
    var f: Fixture = undefined;
    try f.start(gpa, true, .{ .idle_park = .fromMilliseconds(30), .keepalive = .fromMilliseconds(300) });
    defer f.stop(gpa);

    var c: Client = undefined;
    try c.open(f.io, f.addr(), true, .{});
    defer c.close();
    const closes = engine.test_keepalive_closes.load(.acquire);
    try std.testing.expectEqual(200, try c.status("/"));
    // One byte of the next record's header, then silence: the connection
    // can't park with a record half read, and each park delay wakes it
    // for nothing; the keep-alive runs from when it went idle all the same.
    try c.tcp_writer.interface.writeAll(&.{0x17});
    try c.tcp_writer.interface.flush();
    try wait.waitAtLeast(f.io, "the connection closed at its keep-alive", &engine.test_keepalive_closes, closes + 1);
    c.untilClosed();
    try f.waitClosed();
}

test "h2 lifecycle: a parked idle connection is closed at the stop" {
    if (!features.http2) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    sweepFast();
    defer sweepNormal();
    var f: Fixture = undefined;
    try f.start(gpa, false, .{ .idle_park = .fromMilliseconds(30) });
    defer f.stop(gpa);

    var c: Client = undefined;
    try c.open(f.io, f.addr(), false, .{});
    defer c.close();
    try std.testing.expectEqual(200, try c.status("/"));
    try f.waitParked(1);
    // Not counted, so the drain does not wait for it: the stop closes it.
    try std.testing.expectEqual(0, f.server.busy.load(.acquire).count);
    var stopper = try f.io.concurrent(Fixture.stopper, .{&f});
    defer stopper.await(f.io);
    c.untilClosed();
}

test "h2 lifecycle: requests arriving as an h2 connection parks [stress]" {
    // A race hunt: 80 seeded rounds, as the HTTP/1.1 one in park_test.zig.
    try wait.requireStress();
    if (!features.http2) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    sweepFast();
    defer sweepNormal();
    var f: Fixture = undefined;
    try f.start(gpa, false, .{ .idle_park = .fromMilliseconds(10) });
    defer f.stop(gpa);

    var c: Client = undefined;
    try c.open(f.io, f.addr(), false, .{});
    defer c.close();
    var prng: std.Random.DefaultPrng = .init(0x48325061726b);
    const random = prng.random();
    for (0..80) |i| {
        try f.io.sleep(.fromMicroseconds(8_000 + random.uintLessThan(u32, 4_000)), .awake);
        if (i % 2 == 0) {
            try std.testing.expectEqual(200, try c.status("/"));
            continue;
        }
        var block: [256]u8 = undefined;
        const len = try c.getBlock("/", &block);
        var h: [frame.header_len]u8 = undefined;
        const id = c.next_id;
        c.next_id += 2;
        _ = frame.writeHeader(&h, .{ .length = @intCast(len), .type = .headers, .flags = F.end_headers | F.end_stream, .stream_id = id });
        const cut = random.uintLessThan(usize, frame.header_len - 1) + 1;
        try c.writer().writeAll(h[0..cut]);
        try c.flush();
        try f.io.sleep(.fromMicroseconds(random.uintLessThan(u32, 15_000)), .awake);
        try c.writer().writeAll(h[cut..]);
        try c.writer().writeAll(block[0..len]);
        try c.flush();
        try std.testing.expectEqual(200, (try c.until(id)).status);
    }
}
