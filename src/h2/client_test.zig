//! The HTTP/2 client against dusty's HTTP/2 server engine: plain requests,
//! a streamed body both ways larger than the windows, trailers, concurrent
//! streams on one connection, and TLS.
const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");
const features = @import("build_options");
const h2 = @import("client.zig");

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

fn startServer(gpa: std.mem.Allocator, io: std.Io, listeners: []const dusty.Listener) !*dusty.Server(void) {
    const server = try gpa.create(dusty.Server(void));
    server.* = .init(gpa, io, .{ .listeners = listeners }, {});
    server.router.get("/hello", hello);
    server.router.post("/echo", echo);
    server.router.get("/trailers", withTrailers);
    return server;
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
    try server.ready.wait(io);

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
    try server.ready.wait(io);

    var bundle = try anole_tls.testing.bundleFromPem(gpa, std.Io.Clock.real.now(io).toSeconds(), pem.cert);
    defer bundle.deinit(gpa);
    const conn = try h2.ClientConnection.connect(gpa, io, .{
        .host = "localhost",
        .address = server.address.ip,
        .port = server.address.ip.getPort(),
        .tls = .{ .root_ca = bundle },
    });
    defer conn.close();
    const body = try get(conn, "/hello", gpa);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("hello over h2", body);
}
