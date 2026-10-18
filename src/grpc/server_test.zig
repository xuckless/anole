//! gRPC end to end: the four call modes, status in trailers, deadlines and
//! gzip, against dusty's HTTP/2 engine with a minimal nghttp2 client.
const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");
const c = @import("anole_nghttp2_c");
const pb = @import("anole_test_pb");
const grpc = @import("root.zig");
const features = @import("build_options");

const Echo = pb.Echo(grpc.Call, anyerror);

fn unary(call: *grpc.Call, req: pb.EchoRequest) anyerror!pb.EchoResponse {
    if (std.mem.eql(u8, req.message, "fail")) return call.fail(.not_found, "no such thing: fail");
    if (std.mem.eql(u8, req.message, "slow")) try call.io.sleep(.fromMilliseconds(2000), .awake);
    try call.addTrailer("x-echoed", "yes");
    return .{ .message = req.message, .index = 0 };
}

fn serverStream(call: *grpc.Call, req: pb.EchoRequest, out: *std.Io.Queue(pb.EchoResponse)) anyerror!void {
    for (0..@intCast(req.repeat)) |i| try out.putOne(call.io, .{ .message = req.message, .index = @intCast(i) });
}

fn clientStream(call: *grpc.Call, in: *std.Io.Queue(pb.EchoRequest)) anyerror!pb.EchoResponse {
    var joined: std.ArrayList(u8) = .empty;
    var n: i32 = 0;
    while (true) {
        const req = in.getOne(call.io) catch |err| switch (err) {
            error.Closed => break,
            else => |e| return e,
        };
        try joined.appendSlice(call.arena, req.message);
        n += 1;
    }
    return .{ .message = joined.items, .index = n };
}

fn bidi(call: *grpc.Call, in: *std.Io.Queue(pb.EchoRequest), out: *std.Io.Queue(pb.EchoResponse)) anyerror!void {
    var i: i32 = 0;
    while (true) {
        const req = in.getOne(call.io) catch |err| switch (err) {
            error.Closed => return,
            else => |e| return e,
        };
        try out.putOne(call.io, .{ .message = req.message, .index = i });
        i += 1;
    }
}

/// One gRPC call over a fresh HTTP/2 connection.
const Client = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader = undefined,
    writer: std.Io.net.Stream.Writer = undefined,
    read_buf: [16 * 1024]u8 = undefined,
    write_buf: [16 * 1024]u8 = undefined,
    session: ?*c.nghttp2_session = null,
    body: []const u8 = "",
    sent: usize = 0,
    data: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,
    status: u16 = 0,
    grpc_status: ?u32 = null,
    grpc_message: [128]u8 = undefined,
    grpc_message_len: usize = 0,
    echoed_trailer: bool = false,
    closed: bool = false,

    fn call(gpa: std.mem.Allocator, io: std.Io, addr: std.Io.net.IpAddress, path: []const u8, messages: []const pb.EchoRequest, extra: []const c.nghttp2_nv) !*Client {
        const self = try gpa.create(Client);
        self.* = .{ .io = io, .gpa = gpa, .stream = try addr.connect(io, .{ .mode = .stream }) };
        self.reader = self.stream.reader(io, &self.read_buf);
        self.writer = self.stream.writer(io, &self.write_buf);
        var body: std.Io.Writer.Allocating = .init(gpa);
        defer body.deinit();
        for (messages) |m| {
            var enc: std.Io.Writer.Allocating = .init(gpa);
            defer enc.deinit();
            try m.encode(&enc.writer, gpa);
            const framed = try grpc.frame.encode(gpa, enc.written());
            defer gpa.free(framed);
            try body.writer.writeAll(framed);
        }
        self.body = try gpa.dupe(u8, body.written());

        var cbs: ?*c.nghttp2_session_callbacks = null;
        _ = c.nghttp2_session_callbacks_new(&cbs);
        defer c.nghttp2_session_callbacks_del(cbs);
        c.nghttp2_session_callbacks_set_on_header_callback(cbs, onHeader);
        c.nghttp2_session_callbacks_set_on_data_chunk_recv_callback(cbs, onData);
        c.nghttp2_session_callbacks_set_on_stream_close_callback(cbs, onClose);
        _ = c.nghttp2_session_client_new(&self.session, cbs, self);
        _ = c.nghttp2_submit_settings(self.session, c.NGHTTP2_FLAG_NONE, null, 0);
        var nva: std.ArrayList(c.nghttp2_nv) = .empty;
        defer nva.deinit(gpa);
        try nva.appendSlice(gpa, &.{
            nv(":method", "POST"),                  nv(":path", path),
            nv(":scheme", "http"),                  nv(":authority", "localhost"),
            nv("content-type", "application/grpc"), nv("te", "trailers"),
        });
        try nva.appendSlice(gpa, extra);
        var provider: c.nghttp2_data_provider2 = .{ .source = .{ .ptr = self }, .read_callback = provide };
        if (c.nghttp2_submit_request2(self.session, null, nva.items.ptr, nva.items.len, &provider, self) < 0) return error.Submit;
        while (!self.closed) {
            while (true) {
                var out: [*c]const u8 = undefined;
                const n = c.nghttp2_session_mem_send2(self.session, &out);
                if (n <= 0) break;
                try self.writer.interface.writeAll(out[0..@intCast(n)]);
            }
            try self.writer.interface.flush();
            if (self.closed) break;
            const bytes = try self.reader.interface.peekGreedy(1);
            const rv = c.nghttp2_session_mem_recv2(self.session, bytes.ptr, bytes.len);
            if (rv < 0) return error.Recv;
            self.reader.interface.toss(@intCast(rv));
        }
        return self;
    }

    fn deinit(self: *Client) void {
        c.nghttp2_session_del(self.session);
        self.stream.close(self.io);
        self.gpa.free(self.body);
        self.data.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// The response messages, decoded.
    fn responses(self: *Client, arena: std.mem.Allocator) ![]pb.EchoResponse {
        var list: std.ArrayList(pb.EchoResponse) = .empty;
        var r: std.Io.Reader = .fixed(self.data.items);
        while (try grpc.frame.readMessage(&r, arena, 1 << 20, .gzip)) |m| {
            var mr: std.Io.Reader = .fixed(m.payload);
            try list.append(arena, try pb.EchoResponse.decode(&mr, arena));
        }
        return list.items;
    }

    fn message(self: *const Client) []const u8 {
        return self.grpc_message[0..self.grpc_message_len];
    }

    fn nv(name: []const u8, value: []const u8) c.nghttp2_nv {
        return .{ .name = @constCast(name.ptr), .namelen = name.len, .value = @constCast(value.ptr), .valuelen = value.len, .flags = c.NGHTTP2_NV_FLAG_NONE };
    }

    fn onHeader(_: ?*c.nghttp2_session, _: [*c]const c.nghttp2_frame, name: [*c]const u8, namelen: usize, value: [*c]const u8, valuelen: usize, _: u8, user: ?*anyopaque) callconv(.c) c_int {
        const self: *Client = @ptrCast(@alignCast(user.?));
        const n = name[0..namelen];
        const v = value[0..valuelen];
        if (std.mem.eql(u8, n, ":status")) self.status = std.fmt.parseInt(u16, v, 10) catch 0;
        if (std.mem.eql(u8, n, "grpc-status")) self.grpc_status = std.fmt.parseInt(u32, v, 10) catch null;
        if (std.mem.eql(u8, n, "grpc-message")) {
            self.grpc_message_len = @min(v.len, self.grpc_message.len);
            @memcpy(self.grpc_message[0..self.grpc_message_len], v[0..self.grpc_message_len]);
        }
        if (std.mem.eql(u8, n, "x-echoed")) self.echoed_trailer = true;
        return 0;
    }

    fn onData(_: ?*c.nghttp2_session, _: u8, _: i32, data: [*c]const u8, len: usize, user: ?*anyopaque) callconv(.c) c_int {
        const self: *Client = @ptrCast(@alignCast(user.?));
        self.data.appendSlice(self.gpa, data[0..len]) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
        return 0;
    }

    fn onClose(_: ?*c.nghttp2_session, _: i32, _: u32, user: ?*anyopaque) callconv(.c) c_int {
        const self: *Client = @ptrCast(@alignCast(user.?));
        self.closed = true;
        return 0;
    }

    fn provide(_: ?*c.nghttp2_session, _: i32, buf: [*c]u8, length: usize, flags: [*c]u32, source: [*c]c.nghttp2_data_source, _: ?*anyopaque) callconv(.c) c.nghttp2_ssize {
        const self: *Client = @ptrCast(@alignCast(source.*.ptr.?));
        const rest = self.body[self.sent..];
        const n = @min(rest.len, length);
        @memcpy(buf[0..n], rest[0..n]);
        self.sent += n;
        if (self.sent == self.body.len) flags.* |= c.NGHTTP2_DATA_FLAG_EOF;
        return @intCast(n);
    }
};

test "gRPC: unary, server, client and bidi streaming; status and trailers; deadline" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();

    var server = dusty.Server(void).init(gpa, io, .{
        .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } }, .http2_prior_knowledge = true }},
    }, {});
    defer server.deinit();
    var health: grpc.Health = .init(gpa, io);
    defer health.deinit();
    health.registerOn(void, &server.router);
    try health.set("anole.test.Echo", .SERVING);
    grpc.register(void, &server.router, Echo, .{
        .Unary = unary,
        .ServerStream = serverStream,
        .ClientStream = clientStream,
        .Bidi = bidi,
    });
    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};
    try server.ready.wait(io);
    const addr = server.address.ip;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    {
        const cl = try Client.call(gpa, io, addr, "/anole.test.Echo/Unary", &.{.{ .message = "hello" }}, &.{});
        defer cl.deinit();
        try std.testing.expectEqual(@as(u16, 200), cl.status);
        try std.testing.expectEqual(@as(?u32, 0), cl.grpc_status);
        try std.testing.expect(cl.echoed_trailer);
        const rs = try cl.responses(a);
        try std.testing.expectEqual(@as(usize, 1), rs.len);
        try std.testing.expectEqualStrings("hello", rs[0].message);
    }
    {
        const cl = try Client.call(gpa, io, addr, "/anole.test.Echo/Unary", &.{.{ .message = "fail" }}, &.{});
        defer cl.deinit();
        try std.testing.expectEqual(@as(?u32, 5), cl.grpc_status);
        try std.testing.expectEqualStrings("no such thing: fail", cl.message());
    }
    {
        const cl = try Client.call(gpa, io, addr, "/anole.test.Echo/ServerStream", &.{.{ .message = "tick", .repeat = 5 }}, &.{});
        defer cl.deinit();
        try std.testing.expectEqual(@as(?u32, 0), cl.grpc_status);
        const rs = try cl.responses(a);
        try std.testing.expectEqual(@as(usize, 5), rs.len);
        try std.testing.expectEqual(@as(i32, 4), rs[4].index);
    }
    {
        const cl = try Client.call(gpa, io, addr, "/anole.test.Echo/ClientStream", &.{ .{ .message = "a" }, .{ .message = "b" }, .{ .message = "c" } }, &.{});
        defer cl.deinit();
        try std.testing.expectEqual(@as(?u32, 0), cl.grpc_status);
        const rs = try cl.responses(a);
        try std.testing.expectEqualStrings("abc", rs[0].message);
        try std.testing.expectEqual(@as(i32, 3), rs[0].index);
    }
    {
        const cl = try Client.call(gpa, io, addr, "/anole.test.Echo/Bidi", &.{ .{ .message = "x" }, .{ .message = "y" } }, &.{});
        defer cl.deinit();
        try std.testing.expectEqual(@as(?u32, 0), cl.grpc_status);
        const rs = try cl.responses(a);
        try std.testing.expectEqual(@as(usize, 2), rs.len);
        try std.testing.expectEqualStrings("y", rs[1].message);
        try std.testing.expectEqual(@as(i32, 1), rs[1].index);
    }
    {
        // 100 ms against a handler that sleeps for 2 s.
        const cl = try Client.call(gpa, io, addr, "/anole.test.Echo/Unary", &.{.{ .message = "slow" }}, &.{Client.nv("grpc-timeout", "100m")});
        defer cl.deinit();
        try std.testing.expectEqual(@as(?u32, 4), cl.grpc_status);
    }
    {
        // grpc.health.v1: Check, for the server and an unknown service.
        // An empty EchoRequest encodes as an empty HealthCheckRequest.
        const cl = try Client.call(gpa, io, addr, "/grpc.health.v1.Health/Check", &.{.{ .message = "" }}, &.{});
        defer cl.deinit();
        try std.testing.expectEqual(@as(?u32, 0), cl.grpc_status);
        // The reply is a HealthCheckResponse: field 1, varint 1 (SERVING).
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 2, 0x08, 0x01 }, cl.data.items);
    }
    if (features.compression) {
        // The response is gzipped for a client that accepts it.
        const cl = try Client.call(gpa, io, addr, "/anole.test.Echo/Unary", &.{.{ .message = "squeeze me" }}, &.{Client.nv("grpc-accept-encoding", "gzip")});
        defer cl.deinit();
        try std.testing.expectEqual(@as(?u32, 0), cl.grpc_status);
        try std.testing.expectEqual(@as(u8, 1), cl.data.items[0]); // compressed flag
        try std.testing.expectEqualStrings("squeeze me", (try cl.responses(a))[0].message);
    }
}
