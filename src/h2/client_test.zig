//! The HTTP/2 client against dusty's HTTP/2 server engine: plain requests,
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
    const system = (try anole_tls.dusty_tls.clientStore(gpa, io, @as(dusty.TlsCa, .system))).?;
    defer anole_tls.dusty_tls.releaseStore(system);
    try std.testing.expect(anole_tls.dusty_tls.storeCertCount(system) > 0);

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
    opts.tls = .{
        .ca = .{ .file = .{ .path = "ca.pem", .dir = tmp.dir } },
        .client_certificate = .{ .cert_path = "client.pem", .key_path = "client.key", .dir = tmp.dir },
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
    try std.testing.expectEqual(@as(usize, 1), client.pool.idle_len);
    {
        const big = try gpa.alloc(u8, 300 * 1024);
        defer gpa.free(big);
        for (big, 0..) |*b, i| b.* = @truncate(i *% 7);
        var response = try client.fetch(try std.fmt.bufPrint(&url_buf, "https://localhost:{d}/echo", .{h2_port}), .{ .method = .post, .body = big });
        defer response.deinit();
        try std.testing.expectEqual(.ok, response.status());
        try std.testing.expect(std.mem.eql(u8, big, (try response.body()).?));
    }
    try std.testing.expectEqual(@as(usize, 1), client.pool.idle_len);
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
