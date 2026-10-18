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

fn slow(req: *dusty.Request, res: *dusty.Response) !void {
    try req.io.sleep(.fromSeconds(5), .awake);
    res.body = "too late";
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
        return startWith(gpa, io, .{ .listeners = &.{} });
    }

    fn startWith(gpa: std.mem.Allocator, io: std.Io, config: dusty.ServerConfig) !Fixture {
        var pem = try anole_tls.selfSigned(gpa, .{});
        errdefer pem.deinit(gpa);
        const http = try gpa.create(dusty.Server(void));
        errdefer gpa.destroy(http);
        http.* = .init(gpa, io, config, {});
        errdefer http.deinit();
        http.router.get("/hello", hello);
        http.router.post("/echo", echo);
        http.router.get("/trailers", withTrailers);
        http.router.get("/slow", slow);
        const ep = try Endpoint.init(gpa, io, http, .{
            .address = .{ .ip4 = .loopback(0) },
            .cert_pem = pem.cert,
            .key_pem = pem.key,
            .max_streams_bidi = 8,
        });
        errdefer ep.deinit();
        var bundle = try anole_tls.testing.bundleFromPem(gpa, std.Io.Clock.real.now(io).toSeconds(), pem.cert);
        errdefer bundle.deinit(gpa);
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
            .tls = .{ .root_ca = f.bundle },
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
        .handshake_timeout_ms = 2000,
    }));
    try std.testing.expectError(error.HandshakeFailed, client.ClientConnection.connect(gpa, io, .{
        .host = "example.com",
        .address = f.ep.address(),
        .port = f.ep.address().getPort(),
        .tls = .{ .root_ca = f.bundle },
        .handshake_timeout_ms = 2000,
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
    var f = try Fixture.startWith(gpa, io, .{ .listeners = &.{}, .timeout = .{ .request = .fromMilliseconds(300) } });
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
