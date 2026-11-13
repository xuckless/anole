//! The new HTTP/2 engine (src/http/core/h2/server.zig) on the real zio, one
//! executor: its connection lock is no lock there (`ConnLock.free`, PLAN
//! §3.3), which the core's own suite, on std.Io.Threaded, never runs. A
//! request answered on the reader, one on a task and a body streamed past
//! the window (the flusher, a handler waiting for room) all go through it,
//! under the Debug check that every touch is on the connection's executor.
const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");

const h2 = dusty.h2_core_for_tests;
const frame = h2.frame;
const hpack = h2.hpack;
const E = h2.server.Engine(void);

fn hello(_: *dusty.Request, res: *dusty.Response) !void {
    res.body = "hello";
}

fn user(req: *dusty.Request, res: *dusty.Response) !void {
    try res.print(.text, "user {s}", .{req.params.get("id").?});
}

const big_len = 200 * 1000;

fn big(_: *dusty.Request, res: *dusty.Response) !void {
    var buf: [4096]u8 = undefined;
    var out = try res.stream(&buf);
    for (0..big_len / 1000) |i| try out.interface.print("{d:0>999}\n", .{i});
    try out.end();
}

const Side = struct {
    server: *dusty.Server(void),
    listener: *const dusty.Listener,
    connection: *dusty.Connection,

    fn serve(s: Side) anyerror!void {
        var busy = false;
        try E.serve(s.server, s.listener, false, s.connection, &busy);
    }
};

fn writeFrame(w: *std.Io.Writer, ty: frame.Type, fl: u8, id: u31, payload: []const u8) !void {
    var h: [frame.header_len]u8 = undefined;
    _ = frame.writeHeader(&h, .{ .length = @intCast(payload.len), .type = ty, .flags = fl, .stream_id = id });
    try w.writeAll(&h);
    try w.writeAll(payload);
}

test "h2 engine on zio: the lock-free path on one executor" {
    if (comptime !@import("build_options").http2) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();

    var server = dusty.Server(void).init(gpa, io, .{}, {});
    defer server.deinit();
    server.router.addRouteWith(.get, "/nw/hello", hello, .{ .no_wait = true });
    server.router.get("/users/:id", user);
    server.router.get("/big", big);

    var tcp = try (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{});
    defer tcp.deinit(io);
    const client = try tcp.socket.address.connect(io, .{ .mode = .stream });
    const server_end = try tcp.accept(io);
    defer server_end.close(io);
    var connection: dusty.Connection = undefined;
    try connection.initPlain(gpa, io, server_end);
    defer connection.deinit();
    connection.write_pool = &server.request_buffers;
    const listener: dusty.Listener = .{ .address = .{ .ip = tcp.socket.address } };
    var future = try io.concurrent(Side.serve, .{.{ .server = &server, .listener = &listener, .connection = &connection }});
    var closed = false;
    defer {
        if (!closed) client.close(io);
        future.cancel(io) catch {};
    }

    var wbuf: [4096]u8 = undefined;
    var sw = client.writer(io, &wbuf);
    const w = &sw.interface;
    var rbuf: [32 * 1024]u8 = undefined;
    var sr = client.reader(io, &rbuf);
    const r = &sr.interface;

    var enc: hpack.Encoder = .{};
    try w.writeAll(h2.conn.client_magic);
    try writeFrame(w, .settings, 0, 0, "");
    const paths = [_][]const u8{ "/nw/hello", "/users/7", "/big" };
    for (paths, 0..) |path, i| {
        var block: [256]u8 = undefined;
        const n = try enc.encode(&block, &.{
            .{ .name = ":method", .value = "GET" },
            .{ .name = ":scheme", .value = "http" },
            .{ .name = ":path", .value = path },
            .{ .name = ":authority", .value = "localhost" },
        });
        try writeFrame(w, .headers, frame.flags.end_headers | frame.flags.end_stream, @intCast(1 + 2 * i), block[0..n]);
    }
    try w.flush();

    var dec: hpack.Decoder = .init(.{});
    var scratch: [65536]u8 = undefined;
    var status: [3]u16 = @splat(0);
    var bodies: [3]usize = @splat(0);
    var hello_body: [8]u8 = undefined;
    var ended: usize = 0;
    while (ended < 3) {
        const head = try r.peek(frame.header_len);
        const fh = frame.FrameHeader.parse(head[0..frame.header_len]);
        const payload = (try r.take(frame.header_len + fh.length))[frame.header_len..];
        const i: usize = if (fh.stream_id == 0) 0 else (fh.stream_id - 1) / 2;
        switch (fh.type) {
            .settings => if (fh.flags & frame.flags.ack == 0) try writeFrame(w, .settings, frame.flags.ack, 0, ""),
            .headers => {
                var blk = dec.block(payload, &scratch, scratch.len);
                while (try blk.next()) |f| {
                    if (std.mem.eql(u8, f.name, ":status")) status[i] = try std.fmt.parseInt(u16, f.value, 10);
                }
                if (fh.flags & frame.flags.end_stream != 0) ended += 1;
            },
            .data => {
                if (i == 0 and payload.len <= hello_body.len) @memcpy(hello_body[bodies[0]..][0..payload.len], payload);
                bodies[i] += payload.len;
                if (fh.flags & frame.flags.end_stream != 0) ended += 1;
                if (payload.len > 0) {
                    var b: [4]u8 = undefined;
                    std.mem.writeInt(u32, &b, @intCast(payload.len), .big);
                    try writeFrame(w, .window_update, 0, 0, &b);
                    if (fh.flags & frame.flags.end_stream == 0) try writeFrame(w, .window_update, 0, fh.stream_id, &b);
                }
            },
            .rst_stream, .goaway => return error.UnexpectedFrame,
            else => {},
        }
        try w.flush();
    }
    try std.testing.expect(h2.server.test_lock_free.load(.monotonic));
    try std.testing.expectEqual([3]u16{ 200, 200, 200 }, status);
    try std.testing.expectEqualStrings("hello", hello_body[0..bodies[0]]);
    try std.testing.expectEqual(@as(usize, "user 7".len), bodies[1]);
    try std.testing.expectEqual(@as(usize, big_len), bodies[2]);

    client.close(io);
    closed = true;
    try future.await(io);
}
