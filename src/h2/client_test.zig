//! The HTTP/2 client against the core's HTTP/2 server engine: plain requests,
//! a streamed body both ways larger than the windows, trailers, concurrent
//! streams on one connection, and TLS.
const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");
const features = @import("build_options");
const h2 = @import("anole_h2_client");

fn hello(_: *dusty.Request, res: *dusty.Response) !void {
    res.body = "hello over h2";
}

fn echo(req: *dusty.Request, res: *dusty.Response) !void {
    var in_buf: [4096]u8 = undefined;
    var body = try req.reader(&in_buf);
    var out_buf: [4096]u8 = undefined;
    var out = try res.stream(&out_buf);
    _ = body.interface.streamRemaining(&out.interface) catch |err| switch (err) {
        error.ReadFailed => return body.err orelse error.Unexpected,
        error.WriteFailed => return out.err orelse error.Unexpected,
    };
    try out.end();
}

fn withTrailers(_: *dusty.Request, res: *dusty.Response) !void {
    res.body = "body";
    try res.trailer("x-checksum", "abc");
}

fn get(conn: *h2.ClientConnection, path: []const u8, gpa: std.mem.Allocator) ![]u8 {
    const s = try conn.request(&.{
        .{ .name = ":method", .value = "GET" },  .{ .name = ":path", .value = path },
        .{ .name = ":scheme", .value = "http" }, .{ .name = ":authority", .value = "localhost" },
    }, .{});
    defer s.release();
    try s.waitHead();
    try std.testing.expectEqual(@as(u16, 200), s.status);
    return s.reader().allocRemaining(gpa, .unlimited);
}

fn slow(req: *dusty.Request, res: *dusty.Response) !void {
    try req.io.sleep(.fromSeconds(5), .awake);
    res.body = "too late";
}

/// The head and some of the body, then nothing for a while.
fn stall(req: *dusty.Request, res: *dusty.Response) !void {
    var out_buf: [256]u8 = undefined;
    var out = try res.stream(&out_buf);
    try out.interface.writeAll("part of it");
    try out.interface.flush();
    try req.io.sleep(.fromSeconds(5), .awake);
    try out.end();
}

fn redirect(_: *dusty.Request, res: *dusty.Response) !void {
    res.status = .found;
    try res.header("Location", "/hello");
}

fn startServer(gpa: std.mem.Allocator, io: std.Io, listeners: []const dusty.Listener) !*dusty.Server(void) {
    const server = try gpa.create(dusty.Server(void));
    server.* = .init(gpa, io, .{ .listeners = listeners }, {});
    server.router.get("/hello", hello);
    server.router.post("/echo", echo);
    server.router.get("/trailers", withTrailers);
    server.router.get("/slow", slow);
    server.router.get("/stall", stall);
    server.router.get("/redirect", redirect);
    return server;
}

/// A server on a zio runtime, stopped (and freed) by `stop`.
const Running = struct {
    server: *dusty.Server(void),
    future: std.Io.Future(anyerror!void),

    fn start(gpa: std.mem.Allocator, io: std.Io, listeners: []const dusty.Listener) !Running {
        const server = try startServer(gpa, io, listeners);
        errdefer {
            server.deinit();
            gpa.destroy(server);
        }
        const future = try io.concurrent(run, .{server});
        try server.waitReady(io);
        return .{ .server = server, .future = future };
    }

    fn run(s: *dusty.Server(void)) anyerror!void {
        try s.run();
    }

    fn port(r: Running) u16 {
        return r.server.address.ip.getPort();
    }

    fn stop(r: *Running, gpa: std.mem.Allocator, io: std.Io) void {
        r.future.cancel(io) catch {};
        r.server.deinit();
        gpa.destroy(r.server);
    }
};

const loopback: dusty.Address = .{ .ip = .{ .ip4 = .loopback(0) } };

fn request(conn: *h2.ClientConnection, path: []const u8, options: h2.ClientConnection.RequestOptions) !*h2.Stream {
    return conn.request(&.{
        .{ .name = ":method", .value = "GET" },  .{ .name = ":path", .value = path },
        .{ .name = ":scheme", .value = "http" }, .{ .name = ":authority", .value = "localhost" },
    }, options);
}

test "h2 client: GET, a large streamed echo, trailers and 20 concurrent streams" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    const server = try startServer(gpa, io, &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } }, .http2_prior_knowledge = true }});
    defer gpa.destroy(server);
    defer server.deinit();
    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{server});
    defer server_future.cancel(io) catch {};
    try server.waitReady(io);

    const conn = try h2.ClientConnection.connect(gpa, io, .{ .host = "127.0.0.1", .port = server.address.ip.getPort() });
    defer conn.close();

    const body = try get(conn, "/hello", gpa);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("hello over h2", body);

    {
        // 1 MiB up and back: many windows' worth each way.
        const big = try gpa.alloc(u8, 1 << 20);
        defer gpa.free(big);
        for (big, 0..) |*b, i| b.* = @truncate(i *% 31);
        const s = try conn.request(&.{
            .{ .name = ":method", .value = "POST" }, .{ .name = ":path", .value = "/echo" },
            .{ .name = ":scheme", .value = "http" }, .{ .name = ":authority", .value = "localhost" },
        }, .{ .body = true });
        defer s.release();
        var sender = try io.concurrent(struct {
            fn send(st: *h2.Stream, data: []const u8) !void {
                try st.writer().writeAll(data);
                try st.closeSend();
            }
        }.send, .{ s, big });
        try s.waitHead();
        const back = try s.reader().allocRemaining(gpa, .unlimited);
        defer gpa.free(back);
        try sender.await(io);
        try std.testing.expect(std.mem.eql(u8, big, back));
    }
    {
        const s = try conn.request(&.{
            .{ .name = ":method", .value = "GET" },  .{ .name = ":path", .value = "/trailers" },
            .{ .name = ":scheme", .value = "http" }, .{ .name = ":authority", .value = "localhost" },
        }, .{});
        defer s.release();
        try s.waitHead();
        const b = try s.reader().allocRemaining(gpa, .unlimited);
        defer gpa.free(b);
        try std.testing.expectEqualStrings("body", b);
        try std.testing.expectEqualStrings("abc", s.trailer("x-checksum").?);
    }
    {
        // Twenty tasks, one connection.
        var group: std.Io.Group = .init;
        defer group.cancel(io);
        var ok: std.atomic.Value(usize) = .init(0);
        for (0..20) |_| try group.concurrent(io, struct {
            fn one(cn: *h2.ClientConnection, a: std.mem.Allocator, count: *std.atomic.Value(usize)) std.Io.Cancelable!void {
                const b = get(cn, "/hello", a) catch return;
                defer a.free(b);
                if (std.mem.eql(u8, b, "hello over h2")) _ = count.fetchAdd(1, .monotonic);
            }
        }.one, .{ conn, gpa, &ok });
        try group.await(io);
        try std.testing.expectEqual(@as(usize, 20), ok.load(.monotonic));
    }
}

test "h2 client: over TLS with ALPN h2" {
    if (comptime features.tls != .boringssl) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const anole_tls = @import("../tls/root.zig");
    var pem = try anole_tls.selfSigned(gpa, .{});
    defer pem.deinit(gpa);
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    const server = try startServer(gpa, io, &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } }, .tls = .{
        .pem = .{ .cert = pem.cert, .key = pem.key },
        .alpn_protocols = &.{ "h2", "http/1.1" },
    } }});
    defer gpa.destroy(server);
    defer server.deinit();
    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{server});
    defer server_future.cancel(io) catch {};
    try server.waitReady(io);

    const conn = try h2.ClientConnection.connect(gpa, io, .{
        .host = "localhost",
        .address = server.address.ip,
        .port = server.address.ip.getPort(),
        .tls = .{ .ca = .{ .pem = pem.cert } },
    });
    defer conn.close();
    const body = try get(conn, "/hello", gpa);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("hello over h2", body);
}

/// A handler that sleeps for 10 s unless it is canceled, and says how it
/// ended.
const Sleeper = struct {
    var started: std.atomic.Value(bool) = .init(false);
    var canceled: std.atomic.Value(bool) = .init(false);
    var done: std.atomic.Value(bool) = .init(false);

    fn handle(req: *dusty.Request, res: *dusty.Response) !void {
        defer done.store(true, .release);
        started.store(true, .release);
        req.io.sleep(.fromSeconds(10), .awake) catch |err| {
            canceled.store(true, .release);
            return err;
        };
        res.body = "slept";
    }

    fn reset() void {
        started.store(false, .release);
        canceled.store(false, .release);
        done.store(false, .release);
    }

    fn waitStarted(io: std.Io) !void {
        while (!started.load(.acquire)) try io.sleep(.fromMilliseconds(5), .awake);
    }

    /// The handler ended, canceled, within `ms` of `since`.
    fn expectCanceledWithin(io: std.Io, since: std.Io.Clock.Timestamp, ms: i64) !void {
        while (!done.load(.acquire)) {
            try std.testing.expect(since.durationTo(.now(io, .awake)).raw.toMilliseconds() < ms);
            try io.sleep(.fromMilliseconds(5), .awake);
        }
        try std.testing.expect(canceled.load(.acquire));
    }
};

test "h2 engine: a client's RST_STREAM or a lost connection cancels the stream's handler" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    const server = try startServer(gpa, io, &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } }, .http2_prior_knowledge = true }});
    defer gpa.destroy(server);
    defer server.deinit();
    server.router.get("/sleep", Sleeper.handle);
    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{server});
    defer server_future.cancel(io) catch {};
    try server.waitReady(io);

    const sleep_request = [_]h2.Header{
        .{ .name = ":method", .value = "GET" },  .{ .name = ":path", .value = "/sleep" },
        .{ .name = ":scheme", .value = "http" }, .{ .name = ":authority", .value = "localhost" },
    };
    {
        // RST_STREAM: the handler's sleep ends at once with error.Canceled,
        // and the connection serves on.
        const conn = try h2.ClientConnection.connect(gpa, io, .{ .host = "127.0.0.1", .port = server.address.ip.getPort() });
        defer conn.close();
        Sleeper.reset();
        const s = try conn.request(&sleep_request, .{});
        defer s.release();
        try Sleeper.waitStarted(io);
        const reset_at: std.Io.Clock.Timestamp = .now(io, .awake);
        s.cancel();
        try Sleeper.expectCanceledWithin(io, reset_at, 1000);
        const body = try get(conn, "/hello", gpa);
        defer gpa.free(body);
        try std.testing.expectEqualStrings("hello over h2", body);
    }
    {
        // The client goes away with its request whole, without a reset or
        // GOAWAY: the server tells a closed connection from a half-close
        // by its probe, then cancels. By hand, as no client library drops
        // a connection this bluntly.
        Sleeper.reset();
        const socket = try server.address.ip.connect(io, .{ .mode = .stream });
        var buf: [256]u8 = undefined;
        var w = socket.writer(io, &buf);
        try w.interface.writeAll("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n");
        try w.interface.writeAll(&.{ 0, 0, 0, 4, 0, 0, 0, 0, 0 }); // SETTINGS
        // HEADERS, END_STREAM | END_HEADERS, stream 1: GET http /sleep,
        // HPACK static indices and literals with indexed names.
        const block = "\x82\x86\x04\x06/sleep\x01\x09localhost";
        try w.interface.writeAll(&.{ 0, 0, block.len, 1, 0x05, 0, 0, 0, 1 });
        try w.interface.writeAll(block);
        try w.interface.flush();
        try Sleeper.waitStarted(io);
        const closed_at: std.Io.Clock.Timestamp = .now(io, .awake);
        socket.close(io);
        try Sleeper.expectCanceledWithin(io, closed_at, 3000);
    }
}

test "h2 engine: a peer's GOAWAY ends the connection with a FIN, and what it sends after draws no reset" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var r = try Running.start(gpa, io, &.{.{ .address = loopback, .http2_prior_knowledge = true }});
    defer r.stop(gpa, io);

    // h2spec 3.8 and 7: a GOAWAY with no stream open ends the session at
    // once, and a PING follows. By hand, as a client library sends
    // nothing after its GOAWAY.
    const socket = try r.server.address.ip.connect(io, .{ .mode = .stream });
    defer socket.close(io);
    var wbuf: [256]u8 = undefined;
    var w = socket.writer(io, &wbuf);
    try w.interface.writeAll("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n");
    try w.interface.writeAll(&.{ 0, 0, 0, 4, 0, 0, 0, 0, 0 }); // SETTINGS
    // GOAWAY, last stream 0, an unknown error code.
    try w.interface.writeAll(&.{ 0, 0, 8, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff });
    try w.interface.flush();
    // The session has ended by now. Read what the server sent (its
    // SETTINGS frames), so a reset is not hidden behind buffered data.
    try io.sleep(.fromMilliseconds(100), .awake);
    var rbuf: [1024]u8 = undefined;
    var rd = socket.reader(io, &rbuf);
    rd.interface.fillMore() catch return rd.err orelse error.Unexpected;
    rd.interface.tossBuffered();
    // The PING finds the server's side closed: it is thrown away while the
    // server lingers, and draws a reset if the server closed at once.
    try w.interface.writeAll(&([_]u8{ 0, 0, 8, 6, 0, 0, 0, 0, 0 } ++ "h2spec  ".*)); // PING
    try w.interface.flush();
    try io.sleep(.fromMilliseconds(50), .awake);

    // Then the end of the stream, which the server sent without waiting
    // for the peer; a reset fails the read.
    const started: std.Io.Clock.Timestamp = .now(io, .awake);
    _ = rd.interface.discardRemaining() catch return rd.err orelse error.Unexpected;
    try std.testing.expect(started.durationTo(.now(io, .awake)).raw.toMilliseconds() < 500);
}

test "h2 client: request timeouts, for the head and for the body, and the connection carries on" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var srv = try Running.start(gpa, io, &.{.{ .address = loopback, .http2_prior_knowledge = true }});
    defer srv.stop(gpa, io);

    // The connection's default: every request gets 300 ms.
    const conn = try h2.ClientConnection.connect(gpa, io, .{ .host = "127.0.0.1", .port = srv.port(), .timeout = .fromMilliseconds(300) });
    defer conn.close();

    const started = std.Io.Clock.awake.now(io);
    {
        const s = try request(conn, "/slow", .{});
        defer s.release();
        try std.testing.expectError(error.Timeout, s.waitHead());
    }
    try std.testing.expect(started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 3000);

    // The head in time, the body not: the read fails, and says why.
    {
        const s = try request(conn, "/stall", .{ .timeout = .{ .duration = .{ .raw = .fromMilliseconds(300), .clock = .awake } } });
        defer s.release();
        try s.waitHead();
        try std.testing.expectEqual(@as(u16, 200), s.status);
        try std.testing.expectError(error.ReadFailed, s.reader().allocRemaining(gpa, .unlimited));
        try std.testing.expectEqual(@as(?h2.StreamError, error.Timeout), s.readError());
    }

    // `.none` lifts the default; this one ends in time anyway.
    {
        const s = try request(conn, "/hello", .{ .timeout = .none });
        defer s.release();
        try s.waitHead();
        const body = try s.reader().allocRemaining(gpa, .unlimited);
        defer gpa.free(body);
        try std.testing.expectEqualStrings("hello over h2", body);
    }
    // A canceled stream says so.
    {
        const s = try request(conn, "/slow", .{});
        defer s.release();
        s.cancel();
        try std.testing.expectError(error.Canceled, s.waitHead());
        try std.testing.expectError(error.ReadFailed, s.reader().allocRemaining(gpa, .unlimited));
        try std.testing.expectEqual(@as(?h2.StreamError, error.Canceled), s.readError());
    }
    const body = try get(conn, "/hello", gpa);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("hello over h2", body);
}

test "h2 client: connect_timeout bounds a TLS handshake that never answers" {
    if (comptime features.tls != .boringssl) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    // Accepts, then says nothing.
    var listener = try (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{});
    defer listener.deinit(io);
    const started = std.Io.Clock.awake.now(io);
    try std.testing.expectError(error.Timeout, h2.ClientConnection.connect(gpa, io, .{
        .host = "localhost",
        .address = listener.socket.address,
        .port = listener.socket.address.getPort(),
        .tls = .{ .insecure_skip_verify = true },
        .connect_timeout = .fromMilliseconds(200),
    }));
    try std.testing.expect(started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 3000);
}

test "h2 client: the system trust store by default, a CA in memory, mutual TLS from memory and from files" {
    if (comptime features.tls != .boringssl) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const anole_tls = @import("../tls/root.zig");
    var server_pem = try anole_tls.selfSigned(gpa, .{});
    defer server_pem.deinit(gpa);
    // The client's own self-signed certificate, which the server trusts.
    var client_pem = try anole_tls.selfSigned(gpa, .{ .common_name = "client" });
    defer client_pem.deinit(gpa);
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();

    // The default is the system store, which has certificates in it and
    // does not trust a development certificate.
    const system = (try @import("anole_dusty_tls").clientStore(gpa, io, @as(dusty.Ca, .system))).?;
    defer @import("anole_dusty_tls").releaseStore(system);
    try std.testing.expect(@import("anole_dusty_tls").storeCertCount(system) > 0);

    var srv = try Running.start(gpa, io, &.{.{ .address = loopback, .tls = .{
        .pem = .{ .cert = server_pem.cert, .key = server_pem.key },
        .alpn_protocols = &.{ "h2", "http/1.1" },
        .client_auth = .{ .ca = .{ .pem = client_pem.cert } },
    } }});
    defer srv.stop(gpa, io);
    const base: h2.ConnectOptions = .{ .host = "localhost", .address = srv.server.address.ip, .port = srv.port() };

    var opts = base;
    opts.tls = .{};
    try std.testing.expectError(error.CertificateIssuerNotFound, h2.ClientConnection.connect(gpa, io, opts));
    opts.tls = .{ .ca = .none };
    try std.testing.expectError(error.NoCertificateAuthority, h2.ClientConnection.connect(gpa, io, opts));

    // Trusted, but with no certificate of its own the server turns it
    // away: at the handshake, or (TLS 1.3) at the first request.
    opts.tls = .{ .ca = .{ .pem = server_pem.cert } };
    if (h2.ClientConnection.connect(gpa, io, opts)) |conn| {
        defer conn.close();
        try std.testing.expect(if (get(conn, "/hello", gpa)) |b| blk: {
            gpa.free(b);
            break :blk false;
        } else |_| true);
    } else |_| {}

    // The certificate as PEM in memory.
    opts.tls = .{ .ca = .{ .pem = server_pem.cert }, .client_certificate = .{ .pem = .{ .cert = client_pem.cert, .key = client_pem.key } } };
    {
        const conn = try h2.ClientConnection.connect(gpa, io, opts);
        defer conn.close();
        const body = try get(conn, "/hello", gpa);
        defer gpa.free(body);
        try std.testing.expectEqualStrings("hello over h2", body);
    }

    // And from files, the CA too.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "ca.pem", .data = server_pem.cert });
    try tmp.dir.writeFile(io, .{ .sub_path = "client.pem", .data = client_pem.cert });
    try tmp.dir.writeFile(io, .{ .sub_path = "client.key", .data = client_pem.key });
    var ca_buf: [160]u8 = undefined;
    var cert_buf: [160]u8 = undefined;
    var key_buf: [160]u8 = undefined;
    opts.tls = .{
        .ca = .{ .file = try std.fmt.bufPrint(&ca_buf, ".zig-cache/tmp/{s}/ca.pem", .{tmp.sub_path}) },
        .client_certificate = .fromFiles(
            try std.fmt.bufPrint(&cert_buf, ".zig-cache/tmp/{s}/client.pem", .{tmp.sub_path}),
            try std.fmt.bufPrint(&key_buf, ".zig-cache/tmp/{s}/client.key", .{tmp.sub_path}),
        ),
    };
    {
        const conn = try h2.ClientConnection.connect(gpa, io, opts);
        defer conn.close();
        const body = try get(conn, "/hello", gpa);
        defer gpa.free(body);
        try std.testing.expectEqualStrings("hello over h2", body);
    }
}

test "dusty's client over HTTP/2: GET, POST, HEAD, a redirect, reuse, a timeout, and HTTP/1.1 where h2 is not offered" {
    if (comptime features.tls != .boringssl) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const anole_tls = @import("../tls/root.zig");
    var pem = try anole_tls.selfSigned(gpa, .{});
    defer pem.deinit(gpa);
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var srv = try Running.start(gpa, io, &.{
        .{ .address = loopback, .tls = .{ .pem = .{ .cert = pem.cert, .key = pem.key }, .alpn_protocols = &.{ "h2", "http/1.1" } } },
        .{ .address = loopback, .tls = .{ .pem = .{ .cert = pem.cert, .key = pem.key }, .alpn_protocols = &.{"http/1.1"} } },
    });
    defer srv.stop(gpa, io);
    const h2_port = srv.server.addresses[0].ip.getPort();
    const h1_port = srv.server.addresses[1].ip.getPort();

    var client = dusty.Client.init(gpa, io, .{ .tls = .{ .ca = .{ .pem = pem.cert } }, .http2 = true });
    defer client.deinit();
    var url_buf: [128]u8 = undefined;

    {
        var response = try client.fetch(try std.fmt.bufPrint(&url_buf, "https://localhost:{d}/hello", .{h2_port}), .{});
        defer response.deinit();
        try std.testing.expectEqual(.ok, response.status());
        try std.testing.expectEqual(@as(u8, 2), response.version().major);
        try std.testing.expectEqualStrings("hello over h2", (try response.body()).?);
        try std.testing.expect(response.headers().get("content-length") != null);
    }
    // The same connection, from the pool.
    try std.testing.expectEqual(@as(usize, 1), client.pool().idle_len);
    {
        const big = try gpa.alloc(u8, 300 * 1024);
        defer gpa.free(big);
        for (big, 0..) |*b, i| b.* = @truncate(i *% 7);
        var response = try client.fetch(try std.fmt.bufPrint(&url_buf, "https://localhost:{d}/echo", .{h2_port}), .{ .method = .post, .body = big });
        defer response.deinit();
        try std.testing.expectEqual(.ok, response.status());
        try std.testing.expect(std.mem.eql(u8, big, (try response.body()).?));
    }
    try std.testing.expectEqual(@as(usize, 1), client.pool().idle_len);
    {
        var response = try client.fetch(try std.fmt.bufPrint(&url_buf, "https://localhost:{d}/hello", .{h2_port}), .{ .method = .head });
        defer response.deinit();
        try std.testing.expectEqual(.ok, response.status());
        try std.testing.expectEqual(@as(?[]const u8, null), try response.body());
    }
    {
        var response = try client.fetch(try std.fmt.bufPrint(&url_buf, "https://localhost:{d}/redirect", .{h2_port}), .{});
        defer response.deinit();
        try std.testing.expectEqualStrings("hello over h2", (try response.body()).?);
    }
    {
        // Streamed, and released with the body unread: the stream is
        // reset and the connection kept.
        var response = try client.fetch(try std.fmt.bufPrint(&url_buf, "https://localhost:{d}/stall", .{h2_port}), .{ .stream = true });
        var buf: [4]u8 = undefined;
        var r = try response.reader(&buf);
        try std.testing.expectEqualStrings("part", try r.interface.take(4));
        response.deinit();
    }
    try std.testing.expectError(error.Timeout, client.fetch(try std.fmt.bufPrint(&url_buf, "https://localhost:{d}/slow", .{h2_port}), .{
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(300), .clock = .awake } },
    }));
    {
        var response = try client.fetch(try std.fmt.bufPrint(&url_buf, "https://localhost:{d}/hello", .{h2_port}), .{});
        defer response.deinit();
        try std.testing.expectEqualStrings("hello over h2", (try response.body()).?);
    }
    {
        var response = try client.fetch(try std.fmt.bufPrint(&url_buf, "https://localhost:{d}/hello", .{h1_port}), .{});
        defer response.deinit();
        try std.testing.expectEqual(@as(u8, 1), response.version().major);
        try std.testing.expectEqualStrings("hello over h2", (try response.body()).?);
    }
}

/// A scripted HTTP/2 server for the client: the test feeds the frames the
/// client reads (`send`), and what the client writes is thrown away. The
/// client runs on it through `adopt`, over a loopback socket pair that
/// carries nothing (the session's end shuts it down).
const Scripted = struct {
    io: std.Io,
    queue: std.Io.Queue(u8),
    queue_buf: [256 * 1024]u8 = undefined,
    reader: std.Io.Reader,
    read_buf: [16 * 1024]u8 = undefined,
    /// The client's side of the connection: its bytes are kept in `sent`
    /// (as far as it holds them) so a test can wait for a frame to go out.
    sent_writer: std.Io.Writer,
    write_buf: [4096]u8 = undefined,
    sent: [64 * 1024]u8 = undefined,
    /// Bytes of `sent` filled; they never change after.
    sent_len: std.atomic.Value(usize) = .init(0),
    listener: std.Io.net.Server,
    near: std.Io.net.Stream,
    far: std.Io.net.Stream,

    fn create(gpa: std.mem.Allocator, io: std.Io) !*Scripted {
        const self = try gpa.create(Scripted);
        errdefer gpa.destroy(self);
        self.* = .{
            .io = io,
            .queue = undefined,
            .reader = .{ .buffer = &.{}, .seek = 0, .end = 0, .vtable = &.{ .stream = stream } },
            .sent_writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },
            .listener = try (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{}),
            .near = undefined,
            .far = undefined,
        };
        self.queue = .init(&self.queue_buf);
        self.reader.buffer = &self.read_buf;
        self.sent_writer.buffer = &self.write_buf;
        self.near = try self.listener.socket.address.connect(io, .{ .mode = .stream });
        self.far = try self.listener.accept(io);
        // The server's connection preface: an empty SETTINGS.
        try self.send(&frame(4, 0, 0, ""));
        return self;
    }

    fn destroy(self: *Scripted, gpa: std.mem.Allocator) void {
        self.near.close(self.io);
        self.far.close(self.io);
        self.listener.deinit(self.io);
        gpa.destroy(self);
    }

    fn adopt(self: *Scripted, gpa: std.mem.Allocator) !*h2.ClientConnection {
        return h2.ClientConnection.adopt(gpa, self.io, &self.reader, &self.sent_writer, self.near);
    }

    fn send(self: *Scripted, bytes: []const u8) !void {
        try self.queue.putAll(self.io, bytes);
    }

    fn record(self: *Scripted, bytes: []const u8) void {
        const len = self.sent_len.load(.monotonic);
        const n = @min(bytes.len, self.sent.len - len);
        @memcpy(self.sent[len..][0..n], bytes[0..n]);
        self.sent_len.store(len + n, .release);
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Scripted = @alignCast(@fieldParentPtr("sent_writer", w));
        self.record(w.buffered());
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            self.record(d);
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| self.record(last);
        return n + last.len * splat;
    }

    /// Waits until the client has written the HEADERS of stream `id`, so
    /// the stream is open on its side: a frame sent for it before that
    /// would be on an idle stream, which is a connection error. Bounded
    /// generously; nothing here is about time.
    fn waitHeadersSent(self: *Scripted, id: u31) !void {
        for (0..5000) |_| {
            const bytes = self.sent[0..self.sent_len.load(.acquire)];
            // After the 24-byte client preface, whole frames.
            var at: usize = 24;
            while (bytes.len >= at + 9) {
                const len = std.mem.readInt(u24, bytes[at..][0..3], .big);
                const stream_id = std.mem.readInt(u32, bytes[at + 5 ..][0..4], .big) & 0x7fff_ffff;
                if (bytes[at + 3] == 0x1 and stream_id == id) return;
                at += 9 + len;
            }
            try self.io.sleep(.fromMilliseconds(1), .awake);
        }
        return error.TestHeadersNeverSent;
    }

    /// The client reads the end of the connection.
    fn end(self: *Scripted) void {
        self.queue.close(self.io);
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Scripted = @alignCast(@fieldParentPtr("reader", r));
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const n = self.queue.get(self.io, dest, 1) catch return error.EndOfStream;
        w.advance(n);
        return n;
    }
};

/// One HTTP/2 frame: its 9-byte header and `payload`.
fn frame(comptime kind: u8, comptime flags: u8, comptime id: u31, comptime payload: []const u8) [9 + payload.len]u8 {
    var out: [9 + payload.len]u8 = undefined;
    std.mem.writeInt(u24, out[0..3], payload.len, .big);
    out[3] = kind;
    out[4] = flags;
    std.mem.writeInt(u32, out[5..9], id, .big);
    @memcpy(out[9..], payload);
    return out;
}

fn waitClosing(conn: *h2.ClientConnection, io: std.Io) !void {
    var tries: usize = 0;
    while (conn.isOpen()) : (tries += 1) {
        if (tries > 400) return error.TestTimeout;
        try io.sleep(.fromMilliseconds(5), .awake);
    }
}

test "h2 client: a stream released after a graceful GOAWAY stays valid until the server ends it" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const peer = try Scripted.create(gpa, io);
    defer peer.destroy(gpa);
    const conn = try peer.adopt(gpa);
    defer conn.close();

    const s = try request(conn, "/", .{});
    // Its HEADERS go out before the GOAWAY comes.
    try io.sleep(.fromMilliseconds(20), .awake);
    // GOAWAY, last stream 1, NO_ERROR: stream 1 is still the server's to
    // answer.
    try peer.send(&frame(7, 0, 0, &.{ 0, 0, 0, 1, 0, 0, 0, 0 }));
    try waitClosing(conn, io);
    s.release();
    // The answer to the released stream: HEADERS (:status 200), then DATA
    // with END_STREAM.
    try peer.send(&frame(1, 0x4, 1, &.{0x88}));
    try peer.send(&frame(0, 0x1, 1, "late"));
    try io.sleep(.fromMilliseconds(50), .awake);
    peer.end();
}

test "h2 client: a graceful GOAWAY lets the streams it covers finish" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const peer = try Scripted.create(gpa, io);
    defer peer.destroy(gpa);
    const conn = try peer.adopt(gpa);
    defer conn.close();
    defer peer.end();

    const s = try request(conn, "/", .{});
    defer s.release();
    try io.sleep(.fromMilliseconds(20), .awake);
    try peer.send(&frame(7, 0, 0, &.{ 0, 0, 0, 1, 0, 0, 0, 0 }));
    try waitClosing(conn, io);
    try std.testing.expectError(error.ConnectionClosed, request(conn, "/", .{}));
    // Give the client time to act on the GOAWAY before the answer comes.
    try io.sleep(.fromMilliseconds(20), .awake);
    try peer.send(&frame(1, 0x4, 1, &.{0x88}));
    try peer.send(&frame(0, 0x1, 1, "finished"));
    try s.waitHead();
    try std.testing.expectEqual(@as(u16, 200), s.status);
    const body = try s.reader().allocRemaining(gpa, .unlimited);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("finished", body);
}

test "h2 client: a response head past the header list limit resets the stream" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const peer = try Scripted.create(gpa, io);
    defer peer.destroy(gpa);
    const conn = try peer.adopt(gpa);
    defer conn.close();
    defer peer.end();

    const s = try request(conn, "/", .{});
    defer s.release();
    try io.sleep(.fromMilliseconds(20), .awake);
    // :status 200, one 100-byte field added to the dynamic table, then 600
    // one-byte references to it: about 80 KB decoded from 700 bytes.
    const head = [_]u8{ 0x88, 0x40, 5 } ++ "x-big" ++ [_]u8{100} ++ @as([100]u8, @splat('v')) ++ @as([600]u8, @splat(0xbe));
    try peer.send(&frame(1, 0x4, 1, head));
    try std.testing.expectError(error.HeadersTooLarge, s.waitHead());

    // The connection carries on.
    const t = try request(conn, "/", .{});
    defer t.release();
    try io.sleep(.fromMilliseconds(20), .awake);
    try peer.send(&frame(1, 0x5, 3, &.{0x88}));
    try t.waitHead();
    try std.testing.expectEqual(@as(u16, 200), t.status);
}

test "h2 client: informational responses before the final one, up to a limit" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const peer = try Scripted.create(gpa, io);
    defer peer.destroy(gpa);
    const conn = try peer.adopt(gpa);
    defer conn.close();
    defer peer.end();

    // :status 103 (a literal on the static name), with a link field.
    const early = [_]u8{ 0x08, 3 } ++ "103" ++ [_]u8{ 0x00, 4 } ++ "link" ++ [_]u8{5} ++ "</a>;";
    {
        // Five, then the response: its head and fields, not theirs.
        const s = try request(conn, "/", .{});
        defer s.release();
        try io.sleep(.fromMilliseconds(20), .awake);
        for (0..5) |_| try peer.send(&frame(1, 0x4, 1, early));
        try peer.send(&frame(1, 0x4, 1, [_]u8{ 0x88, 0x00, 1 } ++ "x" ++ [_]u8{1} ++ "y"));
        try peer.send(&frame(0, 0x1, 1, "ok"));
        try s.waitHead();
        try std.testing.expectEqual(@as(u16, 200), s.status);
        try std.testing.expectEqualStrings("y", s.header("x").?);
        try std.testing.expect(s.header("link") == null);
        const body = try s.reader().allocRemaining(gpa, .unlimited);
        defer gpa.free(body);
        try std.testing.expectEqualStrings("ok", body);
    }
    {
        // Six is one too many.
        const s = try request(conn, "/", .{});
        defer s.release();
        try io.sleep(.fromMilliseconds(20), .awake);
        for (0..6) |_| try peer.send(&frame(1, 0x4, 3, early));
        try std.testing.expectError(error.TooManyInterimResponses, s.waitHead());
    }
}

test "h2 client: a stream refused with REFUSED_STREAM is unprocessed; one reset with CANCEL is not" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const peer = try Scripted.create(gpa, io);
    defer peer.destroy(gpa);
    const conn = try peer.adopt(gpa);
    defer conn.close();
    defer peer.end();

    const refused = try request(conn, "/", .{});
    defer refused.release();
    const canceled = try request(conn, "/", .{});
    defer canceled.release();
    try std.testing.expectEqual(@as(i32, 1), refused.id);
    try std.testing.expectEqual(@as(i32, 3), canceled.id);
    try peer.waitHeadersSent(3);
    // RST_STREAM: REFUSED_STREAM (7) for stream 1, CANCEL (8) for stream 3.
    try peer.send(&frame(3, 0, 1, &.{ 0, 0, 0, 7 }));
    try peer.send(&frame(3, 0, 3, &.{ 0, 0, 0, 8 }));
    try std.testing.expect(std.meta.isError(refused.waitHead()));
    try std.testing.expect(std.meta.isError(canceled.waitHead()));
    try std.testing.expect(refused.unprocessed());
    try std.testing.expect(!canceled.unprocessed());
}

test "h2 client: after GOAWAY(last=1) stream 3 is unprocessed and stream 1, which is answered, is not" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const peer = try Scripted.create(gpa, io);
    defer peer.destroy(gpa);
    const conn = try peer.adopt(gpa);
    defer conn.close();
    defer peer.end();

    const first = try request(conn, "/", .{});
    defer first.release();
    const second = try request(conn, "/", .{});
    defer second.release();
    try std.testing.expectEqual(@as(i32, 1), first.id);
    try std.testing.expectEqual(@as(i32, 3), second.id);
    try peer.waitHeadersSent(3);
    // GOAWAY: last stream 1, NO_ERROR; then stream 1's answer (:status 200).
    try peer.send(&frame(7, 0, 0, &.{ 0, 0, 0, 1, 0, 0, 0, 0 }));
    try peer.send(&frame(1, 0x5, 1, &.{0x88}));
    try first.waitHead();
    try std.testing.expectEqual(@as(u16, 200), first.status);
    try std.testing.expect(std.meta.isError(second.waitHead()));
    try std.testing.expect(second.unprocessed());
    try std.testing.expect(!first.unprocessed());
}
