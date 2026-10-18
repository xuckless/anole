//! The HTTP/3 client against Anole's HTTP/3 server engine: plain requests,
//! a streamed body both ways larger than the windows and the ring,
//! trailers, many concurrent streams on one connection, certificate checks,
//! and a server that closes.
const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");
const anole_tls = @import("../tls/root.zig");
const client = @import("client.zig");
const Endpoint = @import("server.zig").Endpoint(void);
const quic_tls = @import("quic_tls.zig");

fn hello(_: *dusty.Request, res: *dusty.Response) !void {
    res.body = "hello over h3";
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

/// The client's certificate as the handler sees it: the DER, or "none".
fn peer(req: *dusty.Request, res: *dusty.Response) !void {
    res.body = req.peerCertificate() orelse "none";
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

fn get(conn: *client.ClientConnection, path: []const u8, gpa: std.mem.Allocator) ![]u8 {
    const s = try conn.request(&.{
        .{ .name = ":method", .value = "GET" },   .{ .name = ":path", .value = path },
        .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
    }, .{});
    defer s.release();
    try s.waitHead();
    try std.testing.expectEqual(@as(u16, 200), s.status);
    return s.reader().allocRemaining(gpa, .unlimited);
}

const Fixture = struct {
    pem: anole_tls.Pem,
    http: *dusty.Server(void),
    ep: *Endpoint,
    future: std.Io.Future(anyerror!void),
    bundle: std.crypto.Certificate.Bundle,

    fn start(gpa: std.mem.Allocator, io: std.Io) !Fixture {
        return startWith(gpa, io, .{ .listeners = &.{} }, .{});
    }

    /// What `startWith` sets on the endpoint beyond the defaults.
    const Extra = struct {
        /// Mutual TLS, with the server's own (CA:TRUE) certificate as the CA.
        client_auth: ?@FieldType(quic_tls.ClientAuth, "mode") = null,
        fd: ?std.posix.fd_t = null,
        secret: ?[32]u8 = null,
        /// GET /hello says it comes from the successor.
        successor: bool = false,
    };

    fn startWith(gpa: std.mem.Allocator, io: std.Io, config: dusty.ServerConfig, extra: Extra) !Fixture {
        var pem = try anole_tls.selfSigned(gpa, .{});
        errdefer pem.deinit(gpa);
        return startWithPem(gpa, io, config, extra, pem);
    }

    /// As `startWith`, with a given certificate (which the fixture owns).
    fn startWithPem(gpa: std.mem.Allocator, io: std.Io, config: dusty.ServerConfig, extra: Extra, pem_in: anole_tls.Pem) !Fixture {
        var pem = pem_in;
        errdefer pem.deinit(gpa);
        const http = try gpa.create(dusty.Server(void));
        errdefer gpa.destroy(http);
        http.* = .init(gpa, io, config, {});
        errdefer http.deinit();
        if (extra.successor) http.router.get("/hello", helloFromSuccessor) else http.router.get("/hello", hello);
        http.router.post("/echo", echo);
        http.router.get("/trailers", withTrailers);
        http.router.get("/slow", slow);
        http.router.get("/stall", stall);
        http.router.get("/peer", peer);
        var bundle = try anole_tls.testing.bundleFromPem(gpa, std.Io.Clock.real.now(io).toSeconds(), pem.cert);
        errdefer bundle.deinit(gpa);
        const ep = try Endpoint.init(gpa, io, http, .{
            .address = .{ .ip4 = .loopback(0) },
            .cert_pem = pem.cert,
            .key_pem = pem.key,
            .max_streams_bidi = 8,
            .client_auth = if (extra.client_auth) |mode| .{ .ca_der = bundle.bytes.items, .mode = mode } else null,
            .fd = extra.fd,
            .secret = extra.secret,
        });
        errdefer ep.deinit();
        const future = try io.concurrent(runEndpoint, .{ep});
        return .{ .pem = pem, .http = http, .ep = ep, .future = future, .bundle = bundle };
    }

    fn runEndpoint(ep: *Endpoint) anyerror!void {
        try ep.run();
    }

    fn stop(f: *Fixture, gpa: std.mem.Allocator, io: std.Io) void {
        f.future.cancel(io) catch {};
        f.ep.deinit();
        f.http.deinit();
        gpa.destroy(f.http);
        f.bundle.deinit(gpa);
        f.pem.deinit(gpa);
    }

    fn connect(f: *Fixture, gpa: std.mem.Allocator, io: std.Io) !*client.ClientConnection {
        return client.ClientConnection.connect(gpa, io, .{
            .host = "localhost",
            .address = f.ep.address(),
            .port = f.ep.address().getPort(),
            .tls = .{ .ca = .{ .pem = f.pem.cert } },
        });
    }
};

test "h3 client: GET, a large streamed echo, trailers and 40 concurrent streams" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);

    const conn = try f.connect(gpa, io);
    defer conn.close();

    const body = try get(conn, "/hello", gpa);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("hello over h3", body);

    {
        // 3 MiB up and back: many windows and rings' worth each way.
        const big = try gpa.alloc(u8, 3 << 20);
        defer gpa.free(big);
        for (big, 0..) |*b, i| b.* = @truncate(i *% 31);
        const s = try conn.request(&.{
            .{ .name = ":method", .value = "POST" },  .{ .name = ":path", .value = "/echo" },
            .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
        }, .{ .body = true });
        defer s.release();
        var sender = try io.concurrent(struct {
            fn send(st: *client.Stream, data: []const u8) !void {
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
            .{ .name = ":method", .value = "GET" },   .{ .name = ":path", .value = "/trailers" },
            .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
        }, .{});
        defer s.release();
        try s.waitHead();
        const b = try s.reader().allocRemaining(gpa, .unlimited);
        defer gpa.free(b);
        try std.testing.expectEqualStrings("body", b);
        try std.testing.expectEqualStrings("abc", s.trailer("x-checksum").?);
    }
    {
        // Forty tasks, one connection, a server limit of 8 streams at once:
        // requests wait for stream credit.
        var group: std.Io.Group = .init;
        defer group.cancel(io);
        var ok: std.atomic.Value(usize) = .init(0);
        for (0..40) |_| try group.concurrent(io, struct {
            fn one(cn: *client.ClientConnection, a: std.mem.Allocator, count: *std.atomic.Value(usize)) std.Io.Cancelable!void {
                const b = get(cn, "/hello", a) catch return;
                defer a.free(b);
                if (std.mem.eql(u8, b, "hello over h3")) _ = count.fetchAdd(1, .monotonic);
            }
        }.one, .{ conn, gpa, &ok });
        try group.await(io);
        try std.testing.expectEqual(@as(usize, 40), ok.load(.monotonic));
    }
}

test "h3 client: certificate checks, and a server that goes away" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    var stopped = false;
    defer if (!stopped) f.stop(gpa, io);

    // No trust in the server's certificate, or the wrong name.
    try std.testing.expectError(error.HandshakeFailed, client.ClientConnection.connect(gpa, io, .{
        .host = "localhost",
        .address = f.ep.address(),
        .port = f.ep.address().getPort(),
        .connect_timeout = .fromSeconds(2),
    }));
    try std.testing.expectError(error.HandshakeFailed, client.ClientConnection.connect(gpa, io, .{
        .host = "example.com",
        .address = f.ep.address(),
        .port = f.ep.address().getPort(),
        .tls = .{ .ca = .{ .pem = f.pem.cert } },
        .connect_timeout = .fromSeconds(2),
    }));

    const conn = try f.connect(gpa, io);
    defer conn.close();
    const body = try get(conn, "/hello", gpa);
    gpa.free(body);

    // The server drains: GOAWAY, then CONNECTION_CLOSE. New requests fail.
    f.stop(gpa, io);
    stopped = true;
    var tries: usize = 0;
    while (tries < 100) : (tries += 1) {
        const b = get(conn, "/hello", gpa) catch |err| {
            try std.testing.expect(err == error.ConnectionClosed or err == error.StreamReset);
            break;
        };
        gpa.free(b);
        try io.sleep(.fromMilliseconds(20), .awake);
    } else return error.TestUnexpectedResult;
}

test "h3 server: a request that outlives timeout.request is reset" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.startWith(gpa, io, .{ .listeners = &.{}, .timeout = .{ .request = .fromMilliseconds(300) } }, .{});
    defer f.stop(gpa, io);
    const conn = try f.connect(gpa, io);
    defer conn.close();

    const started = std.Io.Clock.awake.now(io);
    const s = try conn.request(&.{
        .{ .name = ":method", .value = "GET" },   .{ .name = ":path", .value = "/slow" },
        .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
    }, .{});
    defer s.release();
    if (s.waitHead()) |_| return error.ServedPastTheTimeout else |_| {}
    const took = started.durationTo(std.Io.Clock.awake.now(io));
    try std.testing.expect(took.toMilliseconds() < 3000);

    // The connection carries on.
    const body = try get(conn, "/hello", gpa);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("hello over h3", body);
}

test "h3 server: mutual TLS in request mode, and the client certificate in handlers (PEM or files)" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.startWith(gpa, io, .{ .listeners = &.{} }, .{ .client_auth = .request });
    defer f.stop(gpa, io);

    // No certificate: served, and the handler sees none.
    {
        const conn = try f.connect(gpa, io);
        defer conn.close();
        const body = try get(conn, "/peer", gpa);
        defer gpa.free(body);
        try std.testing.expectEqualStrings("none", body);
    }
    // The server's own certificate (it is its own CA) as the client's.
    {
        const conn = try client.ClientConnection.connect(gpa, io, .{
            .host = "localhost",
            .address = f.ep.address(),
            .port = f.ep.address().getPort(),
            .tls = .{ .ca = .{ .pem = f.pem.cert }, .client_certificate = .{ .pem = .{ .cert = f.pem.cert, .key = f.pem.key } } },
        });
        defer conn.close();
        const body = try get(conn, "/peer", gpa);
        defer gpa.free(body);
        try std.testing.expectEqualSlices(u8, f.bundle.bytes.items, body);
    }
    // The same certificate and the CA from files.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "cert.pem", .data = f.pem.cert });
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "key.pem", .data = f.pem.key });
        const conn = try client.ClientConnection.connect(gpa, io, .{
            .host = "localhost",
            .address = f.ep.address(),
            .port = f.ep.address().getPort(),
            .tls = .{
                .ca = .{ .file = .{ .path = "cert.pem", .dir = tmp.dir } },
                .client_certificate = .{ .cert_path = "cert.pem", .key_path = "key.pem", .dir = tmp.dir },
            },
        });
        defer conn.close();
        const body = try get(conn, "/peer", gpa);
        defer gpa.free(body);
        try std.testing.expectEqualSlices(u8, f.bundle.bytes.items, body);
    }
    // A certificate from a CA the server does not know is refused, even
    // though one was only requested.
    {
        var other = try anole_tls.selfSigned(gpa, .{});
        defer other.deinit(gpa);
        if (client.ClientConnection.connect(gpa, io, .{
            .host = "localhost",
            .address = f.ep.address(),
            .port = f.ep.address().getPort(),
            .tls = .{ .ca = .{ .pem = f.pem.cert }, .client_certificate = .{ .pem = .{ .cert = other.cert, .key = other.key } } },
            .connect_timeout = .fromSeconds(3),
        })) |conn| {
            defer conn.close();
            if (get(conn, "/peer", gpa)) |body| {
                gpa.free(body);
                return error.ServedAnUntrustedCertificate;
            } else |_| {}
        } else |_| {}
    }
}

fn helloFromSuccessor(_: *dusty.Request, res: *dusty.Response) !void {
    res.body = "hello from the successor";
}

test "h3 server: a hand-over closes the connections at once and leaves the socket to the successor" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var old = try Fixture.start(gpa, io);
    var old_stopped = false;
    defer if (!old_stopped) old.stop(gpa, io);

    const conn = try old.connect(gpa, io);
    defer conn.close();
    const body = try get(conn, "/hello", gpa);
    gpa.free(body);

    // The successor: the same socket (a duplicate, as a new process would
    // inherit it), the same secret and certificate, binding nothing.
    const fd = std.c.dup(old.ep.udp.socket.handle);
    try std.testing.expect(fd >= 0);
    const pem_copy: anole_tls.Pem = .{ .cert = try gpa.dupe(u8, old.pem.cert), .key = try gpa.dupe(u8, old.pem.key) };
    var new = try Fixture.startWithPem(gpa, io, .{ .listeners = &.{} }, .{
        .fd = fd,
        .secret = old.ep.secret,
        .successor = true,
    }, pem_copy);
    defer new.stop(gpa, io);
    try std.testing.expectEqual(old.ep.address().getPort(), new.ep.address().getPort());
    try std.testing.expectEqualSlices(u8, &old.ep.secret, &new.ep.secret);

    // The old endpoint hands over: its client hears CONNECTION_CLOSE at
    // once, not after an idle timeout.
    const started = std.Io.Clock.awake.now(io);
    old.ep.handOver();
    old.stop(gpa, io);
    old_stopped = true;
    if (get(conn, "/hello", gpa)) |b| {
        gpa.free(b);
        return error.ServedAfterHandOver;
    } else |err| try std.testing.expect(err == error.ConnectionClosed or err == error.StreamReset);
    try std.testing.expect(started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 2000);

    // Every new connection reaches the successor.
    for (0..5) |_| {
        const c2 = try new.connect(gpa, io);
        defer c2.close();
        const b = try get(c2, "/hello", gpa);
        defer gpa.free(b);
        try std.testing.expectEqualStrings("hello from the successor", b);
    }
}

test "h3 client: request timeouts, for the head and for the body, and the connection carries on" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    const conn = try client.ClientConnection.connect(gpa, io, .{
        .host = "localhost",
        .address = f.ep.address(),
        .port = f.ep.address().getPort(),
        .tls = .{ .ca = .{ .pem = f.pem.cert } },
        .timeout = .fromMilliseconds(300),
    });
    defer conn.close();
    const headers: []const client.Header = &.{
        .{ .name = ":method", .value = "GET" },   .{ .name = ":path", .value = "/slow" },
        .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
    };

    const started = std.Io.Clock.awake.now(io);
    {
        const s = try conn.request(headers, .{});
        defer s.release();
        try std.testing.expectError(error.Timeout, s.waitHead());
    }
    try std.testing.expect(started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 3000);
    {
        const s = try conn.request(&.{
            .{ .name = ":method", .value = "GET" },   .{ .name = ":path", .value = "/stall" },
            .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
        }, .{ .timeout = .{ .duration = .{ .raw = .fromMilliseconds(300), .clock = .awake } } });
        defer s.release();
        try s.waitHead();
        try std.testing.expectError(error.ReadFailed, s.reader().allocRemaining(gpa, .unlimited));
        try std.testing.expectEqual(@as(?client.StreamError, error.Timeout), s.readError());
    }
    {
        const s = try conn.request(headers, .{});
        defer s.release();
        s.cancel();
        try std.testing.expectError(error.Canceled, s.waitHead());
    }
    const body = try get(conn, "/hello", gpa);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("hello over h3", body);
}

test "h3 client: connect_timeout bounds a handshake nobody answers" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    // Bound, never read: the packets go nowhere, and nothing says so.
    const hole = try (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer hole.close(io);
    const started = std.Io.Clock.awake.now(io);
    try std.testing.expectError(error.Timeout, client.ClientConnection.connect(gpa, io, .{
        .host = "localhost",
        .address = hole.address,
        .port = hole.address.getPort(),
        .tls = .{ .insecure_skip_verify = true },
        .connect_timeout = .fromMilliseconds(300),
    }));
    try std.testing.expect(started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 3000);
}
