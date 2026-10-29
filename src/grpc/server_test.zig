//! gRPC end to end: the four call modes, status in trailers, deadlines and
//! gzip, against the core's HTTP/2 engine with a minimal nghttp2 client.
const std = @import("std");
const wait = @import("anole_test_wait");
const zio = @import("zio");
const dusty = @import("dusty");
const c = @import("anole_nghttp2_c");
const pb = @import("anole_test_pb");
const grpc = @import("root.zig");
const frame = @import("frame.zig");
const features = @import("build_options");

const Echo = pb.Echo(grpc.Call, anyerror);
const Lookup = pb.Lookup(grpc.Call, anyerror);

/// The "sleep" call: whether its handler started, was canceled, ended.
const Sleeper = struct {
    var started: std.atomic.Value(bool) = .init(false);
    var canceled: std.atomic.Value(bool) = .init(false);
    var done: std.atomic.Value(bool) = .init(false);
};

fn unary(call: *grpc.Call, req: pb.EchoRequest) anyerror!pb.EchoResponse {
    if (std.mem.eql(u8, req.message, "fail")) return call.fail(.not_found, "no such thing: fail");
    // "slow" runs until the call's deadline cancels it (the wait helper's
    // deadline is only a hang guard): a 100 ms deadline never races it.
    if (std.mem.eql(u8, req.message, "slow")) try call.io.sleep(wait.deadline(), .awake);
    if (std.mem.eql(u8, req.message, "boom")) return error.SecretInternalName;
    if (std.mem.eql(u8, req.message, "sleep")) {
        defer Sleeper.done.store(true, .release);
        Sleeper.started.store(true, .release);
        call.io.sleep(.fromSeconds(10), .awake) catch |err| {
            Sleeper.canceled.store(true, .release);
            return err;
        };
    }
    if (std.mem.eql(u8, req.message, "bin-trailer")) try call.addBinaryTrailer("x-raw-bin", "\x00\r\n\xff");
    if (std.mem.eql(u8, req.message, "reused-buffer")) {
        // The name and the value live in buffers the handler overwrites
        // before it returns: the trailer must copy both.
        var name_buf: [16]u8 = undefined;
        var buf: [16]u8 = undefined;
        try call.addTrailer(try std.fmt.bufPrint(&name_buf, "x-formatted", .{}), try std.fmt.bufPrint(&buf, "value {d}", .{7}));
        @memset(&name_buf, 'q');
        @memset(&buf, 'q');
    }
    try call.addTrailer("x-echoed", "yes");
    return .{ .message = req.message, .index = 0 };
}

/// The Sleeper's sleep: until the call is canceled (or 10 s pass).
fn sleepUntilCanceled(io: std.Io) !void {
    defer Sleeper.done.store(true, .release);
    Sleeper.started.store(true, .release);
    io.sleep(.fromSeconds(10), .awake) catch |err| {
        Sleeper.canceled.store(true, .release);
        return err;
    };
}

fn serverStream(call: *grpc.Call, req: pb.EchoRequest, out: *std.Io.Queue(pb.EchoResponse)) anyerror!void {
    // One message, then the sleep.
    if (std.mem.eql(u8, req.message, "sleep")) {
        try out.putOne(call.io, .{ .message = "first", .index = 0 });
        return sleepUntilCanceled(call.io);
    }
    if (std.mem.eql(u8, req.message, "headers")) {
        // Initial metadata before the first message goes out with it;
        // once the writer has started the response, it is refused.
        try call.addHeader("x-early", "yes");
        try out.putOne(call.io, .{ .message = "first", .index = 0 });
        // Until the writer has started the head with the first message
        // (it does so under the write lock).
        try wait.waitUntil(call.io, "the writer started the response head", call, struct {
            fn started(cl: *grpc.Call) !bool {
                try cl.impl.write_mutex.lock(cl.io);
                defer cl.impl.write_mutex.unlock(cl.io);
                return cl.impl.out != null;
            }
        }.started);
        const late: []const u8 = if (call.addHeader("x-late", "yes")) |_| "added" else |err| @errorName(err);
        try out.putOne(call.io, .{ .message = late, .index = 1 });
        return;
    }
    for (0..@intCast(req.repeat)) |i| try out.putOne(call.io, .{ .message = req.message, .index = @intCast(i) });
}

fn find(_: *grpc.Call, req: pb.EchoRequest) anyerror!pb.EchoResponse {
    return .{ .message = req.message, .index = 7 };
}

fn store(_: *grpc.Call, req: pb.EchoRequest) anyerror!pb.EchoResponse {
    return .{ .message = req.message, .index = 8 };
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

/// Never reads its requests: the client's sends stop at flow control.
fn clientStreamUnread(call: *grpc.Call, in: *std.Io.Queue(pb.EchoRequest)) anyerror!pb.EchoResponse {
    _ = in;
    try sleepUntilCanceled(call.io);
    return .{ .message = "", .index = 0 };
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
    early_header: bool = false,
    late_header: bool = false,
    closed: bool = false,

    fn call(gpa: std.mem.Allocator, io: std.Io, addr: std.Io.net.IpAddress, path: []const u8, messages: []const pb.EchoRequest, extra: []const c.nghttp2_nv) !*Client {
        return callCompressed(gpa, io, addr, path, messages, extra, .identity);
    }

    /// `call` with the request messages in `compression` (the caller sends
    /// the matching grpc-encoding in `extra`).
    fn callCompressed(gpa: std.mem.Allocator, io: std.Io, addr: std.Io.net.IpAddress, path: []const u8, messages: []const pb.EchoRequest, extra: []const c.nghttp2_nv, compression: grpc.Compression) !*Client {
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
            const framed = try frame.encodeWithCompression(gpa, enc.written(), compression);
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
        // A hang fails with error.Timeout after the wait helper's deadline.
        const bound: dusty.Deadline = .init(io, .{ .duration = .{ .raw = wait.deadline(), .clock = .awake } });
        try bound.run(exchange, .{self});
        return self;
    }

    /// Sends the request and reads until the stream closes.
    fn exchange(self: *Client) !void {
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
        while (try frame.readMessage(&r, arena, 1 << 20, .gzip)) |m| {
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
        if (std.mem.eql(u8, n, "x-early")) self.early_header = true;
        if (std.mem.eql(u8, n, "x-late")) self.late_header = true;
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

/// A server on a fresh runtime for `body`: Echo (with `echo_options`),
/// Lookup (64-byte messages, `.accepted` response compression) and
/// grpc.health.v1 with Echo SERVING, on a plain loopback listener that
/// takes HTTP/2 by prior knowledge and HTTP/1.1.
const EchoEnv = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    addr: std.Io.net.IpAddress,
    port: u16,
    arena: std.mem.Allocator,
};

fn withEchoServer(comptime echo_options: grpc.RegisterOptions, comptime body: fn (*EchoEnv) anyerror!void) !void {
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
    grpc.registerWith(void, &server.router, Echo, .{
        .Unary = unary,
        .ServerStream = serverStream,
        .ClientStream = clientStream,
        .Bidi = bidi,
    }, echo_options);
    grpc.registerWith(void, &server.router, Lookup, .{ .Find = find, .Store = store }, .{ .max_message_size = 64, .response_compression = .accepted });
    var server_future = try startServer(&server, io);
    defer server_future.cancel(io) catch {};
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var env: EchoEnv = .{ .gpa = gpa, .io = io, .addr = server.address.ip, .port = server.address.ip.getPort(), .arena = arena_state.allocator() };
    try body(&env);
}

test "gRPC: the four call modes and trailing metadata over h2 (raw nghttp2 client)" {
    try withEchoServer(.{}, struct {
        fn run(env: *EchoEnv) !void {
            const gpa = env.gpa;
            const io = env.io;
            const addr = env.addr;
            const a = env.arena;
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
        }
    }.run);
}

test "gRPC: a handler's fail status and message reach the client" {
    try withEchoServer(.{}, struct {
        fn run(env: *EchoEnv) !void {
            const cl = try Client.call(env.gpa, env.io, env.addr, "/anole.test.Echo/Unary", &.{.{ .message = "fail" }}, &.{});
            defer cl.deinit();
            try std.testing.expectEqual(@as(?u32, 5), cl.grpc_status);
            try std.testing.expectEqualStrings("no such thing: fail", cl.message());
        }
    }.run);
}

test "gRPC: grpc-timeout cancels a handler that waits: DEADLINE_EXCEEDED" {
    try withEchoServer(.{}, struct {
        fn run(env: *EchoEnv) !void {
            // 100 ms against a handler that runs until canceled.
            const cl = try Client.call(env.gpa, env.io, env.addr, "/anole.test.Echo/Unary", &.{.{ .message = "slow" }}, &.{Client.nv("grpc-timeout", "100m")});
            defer cl.deinit();
            try std.testing.expectEqual(@as(?u32, 4), cl.grpc_status);
        }
    }.run);
}

test "gRPC: grpc.health.v1 Check answers SERVING" {
    try withEchoServer(.{}, struct {
        fn run(env: *EchoEnv) !void {
            // An empty EchoRequest encodes as an empty HealthCheckRequest.
            const cl = try Client.call(env.gpa, env.io, env.addr, "/grpc.health.v1.Health/Check", &.{.{ .message = "" }}, &.{});
            defer cl.deinit();
            try std.testing.expectEqual(@as(?u32, 0), cl.grpc_status);
            // The reply is a HealthCheckResponse: field 1, varint 1 (SERVING).
            try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 2, 0x08, 0x01 }, cl.data.items);
        }
    }.run);
}

test "gRPC: default .mirror compresses the response only for a gzipped request" {
    if (comptime !features.compression) return error.SkipZigTest;
    try withEchoServer(.{}, struct {
        fn run(env: *EchoEnv) !void {
            const gpa = env.gpa;
            const io = env.io;
            const addr = env.addr;
            const a = env.arena;
            // The client accepts gzip, but sent its request plain.
            const plain = try Client.call(gpa, io, addr, "/anole.test.Echo/Unary", &.{.{ .message = "squeeze me" }}, &.{Client.nv("grpc-accept-encoding", "gzip")});
            defer plain.deinit();
            try std.testing.expectEqual(@as(?u32, 0), plain.grpc_status);
            try std.testing.expectEqual(@as(u8, 0), plain.data.items[0]); // compressed flag
            try std.testing.expectEqualStrings("squeeze me", (try plain.responses(a))[0].message);

            const cl = try Client.callCompressed(gpa, io, addr, "/anole.test.Echo/Unary", &.{.{ .message = "squeeze me" }}, &.{
                Client.nv("grpc-encoding", "gzip"), Client.nv("grpc-accept-encoding", "gzip"),
            }, .gzip);
            defer cl.deinit();
            try std.testing.expectEqual(@as(?u32, 0), cl.grpc_status);
            try std.testing.expectEqual(@as(u8, 1), cl.data.items[0]); // compressed flag
            try std.testing.expectEqualStrings("squeeze me", (try cl.responses(a))[0].message);
        }
    }.run);
}

/// The gRPC-Web (binary) trailer frame's text of a unary call to Echo.
fn webTrailers(env: *EchoEnv, message: []const u8) ![]const u8 {
    const r = try http1(env.gpa, env.arena, env.io, env.port, "/anole.test.Echo/Unary", "application/grpc-web+proto", try encodeReq(env.arena, .{ .message = message }));
    try std.testing.expectEqual(@as(u16, 200), r.status);
    var reader: std.Io.Reader = .fixed(r.body);
    _ = (try frame.readMessage(&reader, env.arena, 1024, .identity)).?;
    const rest = reader.buffered();
    try std.testing.expectEqual(@as(u8, 0x80), rest[0]);
    return rest[5..];
}

test "grpc: addBinaryTrailer sends its value as unpadded base64" {
    try withEchoServer(.{}, struct {
        fn run(env: *EchoEnv) !void {
            try std.testing.expectEqualStrings("grpc-status:0\r\nx-raw-bin:AA0K/w\r\nx-echoed:yes\r\n", try webTrailers(env, "bin-trailer"));
        }
    }.run);
}

test "grpc: a trailer added from name and value buffers the handler reuses arrives intact" {
    try withEchoServer(.{}, struct {
        fn run(env: *EchoEnv) !void {
            try std.testing.expectEqualStrings("grpc-status:0\r\nx-formatted:value 7\r\nx-echoed:yes\r\n", try webTrailers(env, "reused-buffer"));
        }
    }.run);
}

/// One request with the core's HTTP/1.1 client; the body and selected headers.
const Http1 = struct {
    status: u16,
    body: []const u8,
    content_type: []const u8,
    trailer_echoed: ?[]const u8,
};

fn http1(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, port: u16, path: []const u8, content_type: []const u8, body: []const u8) !Http1 {
    var client = dusty.Client.init(gpa, io, .{});
    defer client.deinit();
    var headers = try dusty.Headers.init(gpa, 8);
    defer headers.deinit(gpa);
    try headers.put("Content-Type", content_type);
    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}{s}", .{ port, path });
    var resp = try client.fetch(url, .{ .method = .post, .headers = &headers, .body = body });
    defer resp.deinit();
    const h = resp.headers();
    return .{
        .status = @intCast(@backingInt(resp.status())),
        .body = try arena.dupe(u8, (try resp.body()) orelse ""),
        .content_type = try arena.dupe(u8, h.get("Content-Type") orelse ""),
        .trailer_echoed = if (h.get("trailer-x-echoed")) |v| try arena.dupe(u8, v) else null,
    };
}

fn encodeReq(arena: std.mem.Allocator, req: pb.EchoRequest) ![]const u8 {
    var enc: std.Io.Writer.Allocating = .init(arena);
    try req.encode(&enc.writer, arena);
    return frame.encode(arena, enc.written());
}

test "gRPC-Web (binary and text) and Connect (unary JSON, streaming) over HTTP/1.1" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var server = dusty.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer server.deinit();
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
    try server.waitReady(io);
    const port = server.address.ip.getPort();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    {
        // gRPC-Web, binary: a message frame, then the trailers frame.
        const r = try http1(gpa, arena, io, port, "/anole.test.Echo/Unary", "application/grpc-web+proto", try encodeReq(arena, .{ .message = "web" }));
        try std.testing.expectEqual(@as(u16, 200), r.status);
        try std.testing.expectEqualStrings("application/grpc-web+proto", r.content_type);
        var reader: std.Io.Reader = .fixed(r.body);
        const msg = (try frame.readMessage(&reader, arena, 1024, .identity)).?;
        var mr: std.Io.Reader = .fixed(msg.payload);
        try std.testing.expectEqualStrings("web", (try pb.EchoResponse.decode(&mr, arena)).message);
        const rest = reader.buffered();
        try std.testing.expectEqual(@as(u8, 0x80), rest[0]);
        try std.testing.expectEqualStrings("grpc-status:0\r\nx-echoed:yes\r\n", rest[5..]);
    }
    {
        // gRPC-Web text: base64 both ways; three streamed messages.
        const framed = try encodeReq(arena, .{ .message = "t", .repeat = 3 });
        const text = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(framed.len));
        _ = std.base64.standard.Encoder.encode(text, framed);
        const r = try http1(gpa, arena, io, port, "/anole.test.Echo/ServerStream", "application/grpc-web-text", text);
        try std.testing.expectEqual(@as(u16, 200), r.status);
        var reader: std.Io.Reader = .fixed(try decodeChunks(arena, r.body));
        var count: usize = 0;
        while (reader.buffered().len > 0 and reader.buffered()[0] != 0x80) {
            _ = (try frame.readMessage(&reader, arena, 1024, .identity)).?;
            count += 1;
        }
        try std.testing.expectEqual(@as(usize, 3), count);
        try std.testing.expect(std.mem.indexOf(u8, reader.buffered(), "grpc-status:0") != null);
    }
    {
        // Connect unary, JSON.
        const r = try http1(gpa, arena, io, port, "/anole.test.Echo/Unary", "application/json", "{\"message\":\"json!\"}");
        try std.testing.expectEqual(@as(u16, 200), r.status);
        try std.testing.expectEqualStrings("application/json", r.content_type);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "\"message\":\"json!\"") != null);
        try std.testing.expectEqualStrings("yes", r.trailer_echoed.?);
    }
    {
        // Connect unary error: HTTP status and a JSON error.
        const r = try http1(gpa, arena, io, port, "/anole.test.Echo/Unary", "application/json", "{\"message\":\"fail\"}");
        try std.testing.expectEqual(@as(u16, 404), r.status);
        try std.testing.expectEqualStrings("{\"code\":\"not_found\",\"message\":\"no such thing: fail\"}", r.body);
    }
    {
        // Connect streaming: envelopes, then the end-of-stream message.
        const r = try http1(gpa, arena, io, port, "/anole.test.Echo/ServerStream", "application/connect+proto", try encodeReq(arena, .{ .message = "s", .repeat = 2 }));
        try std.testing.expectEqual(@as(u16, 200), r.status);
        var reader: std.Io.Reader = .fixed(r.body);
        _ = (try frame.readMessage(&reader, arena, 1024, .identity)).?;
        _ = (try frame.readMessage(&reader, arena, 1024, .identity)).?;
        const end = reader.buffered();
        try std.testing.expectEqual(@as(u8, 0x02), end[0]);
        try std.testing.expectEqualStrings("{}", end[5..]);
    }
}

test "gRPC: request messages that nest too deeply or claim more than they hold fail the call" {
    const gpa = std.testing.allocator;
    // Stacks as `anole.Server` sizes them by default.
    const rt = try zio.Runtime.init(gpa, .{ .stack_pool = .{ .maximum_size = 1024 * 1024, .committed_size = 256 * 1024 } });
    defer rt.deinit();
    const io = rt.io();
    var server = dusty.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer server.deinit();
    grpc.register(void, &server.router, Echo, .{
        .Unary = unary,
        .ServerStream = serverStream,
        .ClientStream = clientStream,
        .Bidi = bidi,
    });
    var server_future = try startServer(&server, io);
    defer server_future.cancel(io) catch {};
    const port = server.address.ip.getPort();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Unknown start-group tags, nested far deeper than a task's stack
    // could recurse.
    const groups = try arena.alloc(u8, 300_000);
    @memset(groups, 3 << 3 | 3); // field 3: not one of EchoRequest's
    // A string field claiming 2^31 - 1 bytes, with none of them.
    const huge = "\x0a\xff\xff\xff\xff\x07";
    for ([_][]const u8{ groups, huge }) |message| {
        const r = try http1(gpa, arena, io, port, "/anole.test.Echo/Unary", "application/grpc-web+proto", try frame.encode(arena, message));
        try std.testing.expectEqual(@as(u16, 200), r.status);
        try std.testing.expect(std.mem.indexOf(u8, r.body, "grpc-status:13\r\n") != null);
    }
    // Connect JSON nested past the JSON depth limit.
    var deep: std.ArrayList(u8) = .empty;
    try deep.appendSlice(arena, "{\"x\":");
    try deep.appendNTimes(arena, '[', 200);
    try deep.appendNTimes(arena, ']', 200);
    try deep.appendSlice(arena, "}");
    const j = try http1(gpa, arena, io, port, "/anole.test.Echo/Unary", "application/json", deep.items);
    try std.testing.expectEqual(@as(u16, 500), j.status);
    // The server still answers.
    const ok = try http1(gpa, arena, io, port, "/anole.test.Echo/Unary", "application/json", "{\"message\":\"still here\"}");
    try std.testing.expectEqual(@as(u16, 200), ok.status);
}

const slowExchange = @import("transcode_test.zig").slowExchange;

/// An HTTP/1.1 gRPC-Web request head for `path` with a body of `len` bytes.
fn webHead(buf: []u8, path: []const u8, len: usize) ![]const u8 {
    return std.fmt.bufPrint(buf, "POST {s} HTTP/1.1\r\nHost: x\r\nContent-Type: application/grpc-web+proto\r\nContent-Length: {d}\r\n\r\n", .{ path, len });
}

const limited_echo: grpc.RegisterOptions = .{ .max_received_bytes = 1000, .read_timeout = .fromMilliseconds(200) };

test "gRPC: max_received_bytes ends a client stream with RESOURCE_EXHAUSTED" {
    try withEchoServer(limited_echo, struct {
        fn run(env: *EchoEnv) !void {
            // A few messages fit the call's 1000 bytes; twenty of 100 do not.
            const few = try Client.call(env.gpa, env.io, env.addr, "/anole.test.Echo/ClientStream", &.{ .{ .message = "a" }, .{ .message = "b" } }, &.{});
            defer few.deinit();
            try std.testing.expectEqual(@as(?u32, 0), few.grpc_status);
            const many: [20]pb.EchoRequest = @splat(.{ .message = &x100 });
            const cl = try Client.call(env.gpa, env.io, env.addr, "/anole.test.Echo/ClientStream", &many, &.{});
            defer cl.deinit();
            try std.testing.expectEqual(@as(?u32, 8), cl.grpc_status);
        }
    }.run);
}

test "gRPC: read_timeout ends a call whose message stops arriving, not a pause between messages" {
    try withEchoServer(limited_echo, struct {
        fn run(env: *EchoEnv) !void {
            const gpa = env.gpa;
            const io = env.io;
            const port = env.port;
            const message = try encodeReq(env.arena, .{ .message = "hi" });
            var head_buf: [256]u8 = undefined;
            {
                // A unary request that declares 100 bytes and sends 2 is cut
                // off after the read timeout, and the connection then closes
                // rather than wait for the rest of the body.
                const head = try webHead(&head_buf, "/anole.test.Echo/Unary", 105);
                const answer = try slowExchange(gpa, io, port, &.{ head, "\x00\x00\x00\x00\x64ab" }, .zero, "(until the server closes)");
                defer gpa.free(answer);
                try std.testing.expect(std.mem.indexOf(u8, answer, "grpc-status:4\r\n") != null);
            }
            {
                // A client stream may pause between messages longer than the
                // read timeout (a correct server never times out here, so a
                // slow machine cannot fail it)...
                const head = try webHead(&head_buf, "/anole.test.Echo/ClientStream", 2 * message.len);
                const answer = try slowExchange(gpa, io, port, &.{ head, message, message }, .fromMilliseconds(400), "grpc-status:");
                defer gpa.free(answer);
                try std.testing.expect(std.mem.indexOf(u8, answer, "grpc-status:0\r\n") != null);
            }
            {
                // ...but not within one: the rest of the second message
                // never comes.
                const head = try webHead(&head_buf, "/anole.test.Echo/ClientStream", 2 * message.len);
                const answer = try slowExchange(gpa, io, port, &.{ head, message, message[0..3] }, .zero, "grpc-status:");
                defer gpa.free(answer);
                try std.testing.expect(std.mem.indexOf(u8, answer, "grpc-status:4\r\n") != null);
            }
        }
    }.run);
}

fn decodeChunks(arena: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i + 4 <= text.len) : (i += 4) {
        var bytes: [3]u8 = undefined;
        const len = try std.base64.standard.Decoder.calcSizeForSlice(text[i..][0..4]);
        try std.base64.standard.Decoder.decode(bytes[0..len], text[i..][0..4]);
        try out.appendSlice(arena, bytes[0..len]);
    }
    return out.items;
}

test "gRPC-Web over HTTP/1.1: a deadline that cancels the handler is answered DEADLINE_EXCEEDED, its cancel consumed" {
    // HTTP/1.1, where the request's timer cancels the handler at the call's
    // deadline (an AutoCancel) and the connection's task then writes the
    // answer: a cancel swallowed there parks it on that write, which zio's
    // debug_cancel reports and the test runner fails (SAFETY.md C3). The
    // deadline's own cancel is claimed instead (Request._claimTimeoutCancel).
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var server = dusty.Server(void).init(gpa, io, .{
        .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }},
    }, {});
    defer server.deinit();
    grpc.register(void, &server.router, Echo, .{
        .Unary = unary,
        .ServerStream = serverStream,
        .ClientStream = clientStream,
        .Bidi = bidi,
    });
    var server_future = try io.concurrent(struct {
        fn run(srv: *dusty.Server(void)) !void {
            try srv.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};
    try server.waitReady(io);

    // One message, EchoRequest{ message: "slow" }: the handler runs until
    // the deadline cancels it.
    const request = "POST /anole.test.Echo/Unary HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/grpc-web+proto\r\n" ++
        "Grpc-Timeout: 100m\r\nContent-Length: 11\r\n\r\n" ++ "\x00\x00\x00\x00\x06\x0a\x04slow";
    // Until the trailer frame (gRPC-Web carries the status in the body).
    const got = try slowExchange(gpa, io, server.address.ip.getPort(), &.{request}, .zero, "grpc-status:");
    defer gpa.free(got);
    try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 200"));
    try std.testing.expect(std.mem.indexOf(u8, got, "grpc-status:4") != null);
}

test "gRPC client: every call mode, an error status, a client deadline and metadata" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var server = dusty.Server(void).init(gpa, io, .{
        .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } }, .http2_prior_knowledge = true }},
    }, {});
    defer server.deinit();
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
    try server.waitReady(io);

    const h2 = @import("anole_h2_client");
    const conn = try h2.ClientConnection.connect(gpa, io, .{ .host = "127.0.0.1", .port = server.address.ip.getPort() });
    defer conn.close();
    var channel: grpc.Channel = .{ .conn = conn, .authority = "localhost" };
    const client: grpc.Client(Echo) = .{ .channel = &channel };
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const r = try client.unary("Unary", arena, .{ .message = "via client" }, .{});
    try std.testing.expectEqual(grpc.Code.ok, r.status.code);
    try std.testing.expectEqualStrings("via client", r.message.?.message);
    var echoed = false;
    for (r.trailers) |t| if (std.mem.eql(u8, t.name, "x-echoed")) {
        echoed = true;
    };
    try std.testing.expect(echoed);

    const failed = try client.unary("Unary", arena, .{ .message = "fail" }, .{});
    try std.testing.expectEqual(grpc.Code.not_found, failed.status.code);
    try std.testing.expectEqualStrings("no such thing: fail", failed.status.message);

    const late = try client.unary("Unary", arena, .{ .message = "slow" }, .{ .timeout = .fromMilliseconds(100) });
    try std.testing.expectEqual(grpc.Code.deadline_exceeded, late.status.code);

    {
        var s = try client.stream("ServerStream", arena, .{});
        defer s.deinit();
        try s.send(.{ .message = "n", .repeat = 4 });
        try s.closeSend();
        var n: usize = 0;
        while (try s.receive()) |m| : (n += 1) try std.testing.expectEqual(@as(i32, @intCast(n)), m.index);
        try std.testing.expectEqual(@as(usize, 4), n);
        try std.testing.expectEqual(grpc.Code.ok, s.status.?.code);
    }
    {
        var s = try client.stream("ClientStream", arena, .{ .compression = if (features.compression) .gzip else .identity });
        defer s.deinit();
        for ([_][]const u8{ "x", "y", "z" }) |m| try s.send(.{ .message = m });
        try s.closeSend();
        const reply = (try s.receive()).?;
        try std.testing.expectEqualStrings("xyz", reply.message);
        try std.testing.expect(try s.receive() == null);
        try std.testing.expectEqual(grpc.Code.ok, s.status.?.code);
    }
    {
        // Bidi in lock step: each reply before the next request.
        var s = try client.stream("Bidi", arena, .{ .metadata = &.{.{ .name = "x-trace", .value = "1" }} });
        defer s.deinit();
        for ([_][]const u8{ "ping", "pong", "again" }, 0..) |m, i| {
            try s.send(.{ .message = m });
            const reply = (try s.receive()).?;
            try std.testing.expectEqualStrings(m, reply.message);
            try std.testing.expectEqual(@as(i32, @intCast(i)), reply.index);
        }
        try s.closeSend();
        try std.testing.expect(try s.receive() == null);
        try std.testing.expectEqual(grpc.Code.ok, s.status.?.code);
    }
}

test "gRPC client: max_received_bytes ends a server stream with RESOURCE_EXHAUSTED" {
    try withEchoServer(.{}, struct {
        fn run(env: *EchoEnv) !void {
            const h2 = @import("anole_h2_client");
            const conn = try h2.ClientConnection.connect(env.gpa, env.io, .{ .host = "127.0.0.1", .port = env.port });
            defer conn.close();
            var channel: grpc.Channel = .{ .conn = conn, .authority = "localhost" };
            const client: grpc.Client(Echo) = .{ .channel = &channel };
            // A call takes at most `max_received_bytes` of responses in all
            // (each counted at its size plus 64): 40 messages of about 70
            // bytes do not fit 1000.
            var s = try client.stream("ServerStream", env.arena, .{ .max_received_bytes = 1000 });
            defer s.deinit();
            try s.send(.{ .message = "n", .repeat = 40 });
            try s.closeSend();
            var n: usize = 0;
            while (try s.receive()) |_| n += 1;
            try std.testing.expect(n > 0 and n < 40);
            try std.testing.expectEqual(grpc.Code.resource_exhausted, s.status.?.code);
        }
    }.run);
}

fn http1Get(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, port: u16, target: []const u8) !Http1 {
    var client = dusty.Client.init(gpa, io, .{});
    defer client.deinit();
    var url_buf: [512]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}{s}", .{ port, target });
    var resp = try client.fetch(url, .{ .method = .get });
    defer resp.deinit();
    const h = resp.headers();
    return .{
        .status = @intCast(@backingInt(resp.status())),
        .body = try arena.dupe(u8, (try resp.body()) orelse ""),
        .content_type = try arena.dupe(u8, h.get("Content-Type") orelse ""),
        .trailer_echoed = null,
    };
}

fn startServer(server: *dusty.Server(void), io: std.Io) !std.Io.Future(anyerror!void) {
    var future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) anyerror!void {
            try s.run();
        }
    }.run, .{server});
    // A failed start must not leave the run task behind.
    errdefer future.cancel(io) catch {};
    try server.waitReady(io);
    return future;
}

/// A message over the 64-byte limit of the Lookup registration.
const x100: [100]u8 = @splat('x');

test "gRPC: .accepted compresses whenever the client accepts gzip" {
    if (comptime !features.compression) return error.SkipZigTest;
    try withEchoServer(.{}, struct {
        fn run(env: *EchoEnv) !void {
            // Lookup's registration is `.accepted`; the request is plain.
            const cl = try Client.call(env.gpa, env.io, env.addr, "/anole.test.Lookup/Find", &.{.{ .message = "squeeze me" }}, &.{Client.nv("grpc-accept-encoding", "gzip")});
            defer cl.deinit();
            try std.testing.expectEqual(@as(?u32, 0), cl.grpc_status);
            try std.testing.expectEqual(@as(u8, 1), cl.data.items[0]); // compressed flag
            try std.testing.expectEqualStrings("squeeze me", (try cl.responses(env.arena))[0].message);
        }
    }.run);
}

test "gRPC: a handler's own error is UNKNOWN \"Application error processing RPC\"" {
    try withEchoServer(.{}, struct {
        fn run(env: *EchoEnv) !void {
            // Nothing of the error's name reaches the client. (The server's
            // warning about it is expected; kept out of the output.)
            const level = std.testing.log_level;
            std.testing.log_level = .err;
            defer std.testing.log_level = level;
            const cl = try Client.call(env.gpa, env.io, env.addr, "/anole.test.Echo/Unary", &.{.{ .message = "boom" }}, &.{});
            defer cl.deinit();
            try std.testing.expectEqual(@as(?u32, 2), cl.grpc_status);
            try std.testing.expectEqualStrings("Application error processing RPC", cl.message());
        }
    }.run);
}

test "gRPC: initial metadata after the response head is refused with HeadersSent" {
    try withEchoServer(.{}, struct {
        fn run(env: *EchoEnv) !void {
            // In before the first message, refused after.
            const cl = try Client.call(env.gpa, env.io, env.addr, "/anole.test.Echo/ServerStream", &.{.{ .message = "headers" }}, &.{});
            defer cl.deinit();
            try std.testing.expectEqual(@as(?u32, 0), cl.grpc_status);
            try std.testing.expect(cl.early_header);
            try std.testing.expect(!cl.late_header);
            const rs = try cl.responses(env.arena);
            try std.testing.expectEqual(@as(usize, 2), rs.len);
            try std.testing.expectEqualStrings("HeadersSent", rs[1].message);
        }
    }.run);
}

test "gRPC: max_message_size is per registration" {
    try withEchoServer(.{}, struct {
        fn run(env: *EchoEnv) !void {
            const gpa = env.gpa;
            const io = env.io;
            const addr = env.addr;
            // Lookup's registration takes messages of up to 64 bytes.
            const small = try Client.call(gpa, io, addr, "/anole.test.Lookup/Store", &.{.{ .message = "fits" }}, &.{});
            defer small.deinit();
            try std.testing.expectEqual(@as(?u32, 0), small.grpc_status);
            const big = try Client.call(gpa, io, addr, "/anole.test.Lookup/Store", &.{.{ .message = &x100 }}, &.{});
            defer big.deinit();
            try std.testing.expectEqual(@as(?u32, 8), big.grpc_status);
            // Echo's keeps the default.
            const echo = try Client.call(gpa, io, addr, "/anole.test.Echo/Unary", &.{.{ .message = &x100 }}, &.{});
            defer echo.deinit();
            try std.testing.expectEqual(@as(?u32, 0), echo.grpc_status);
        }
    }.run);
}

test "gRPC: Connect GET: encodings, base64, gzip, empty message, refusals (405/415/400/501/429)" {
    try withEchoServer(.{}, struct {
        fn run(env: *EchoEnv) !void {
            const gpa = env.gpa;
            const io = env.io;
            const port = env.port;
            const arena = env.arena;
            // Connect GET, for Find only (NO_SIDE_EFFECTS).
            {
                // JSON, percent-encoded.
                const r = try http1Get(gpa, arena, io, port, "/anole.test.Lookup/Find?encoding=json&message=%7B%22message%22%3A%22got%20it%22%7D&connect=v1");
                try std.testing.expectEqual(@as(u16, 200), r.status);
                try std.testing.expectEqualStrings("application/json", r.content_type);
                try std.testing.expect(std.mem.indexOf(u8, r.body, "\"message\":\"got it\"") != null);
            }
            {
                // Protobuf, URL-safe base64 (unpadded), parameters in any order.
                var enc: std.Io.Writer.Allocating = .init(arena);
                try (pb.EchoRequest{ .message = "binary?>" }).encode(&enc.writer, arena);
                const b64 = try arena.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(enc.written().len));
                _ = std.base64.url_safe_no_pad.Encoder.encode(b64, enc.written());
                const r = try http1Get(gpa, arena, io, port, try std.fmt.allocPrint(arena, "/anole.test.Lookup/Find?message={s}&base64=1&encoding=proto&utm=x", .{b64}));
                try std.testing.expectEqual(@as(u16, 200), r.status);
                try std.testing.expectEqualStrings("application/proto", r.content_type);
                var reader: std.Io.Reader = .fixed(r.body);
                const reply = try pb.EchoResponse.decode(&reader, arena);
                try std.testing.expectEqualStrings("binary?>", reply.message);
                try std.testing.expectEqual(@as(i32, 7), reply.index);
            }
            if (features.compression) {
                // gzip, then base64.
                var enc: std.Io.Writer.Allocating = .init(arena);
                try (pb.EchoRequest{ .message = "squeezed" }).encode(&enc.writer, arena);
                const framed = try frame.encodeWithCompression(arena, enc.written(), .gzip);
                const gz = framed[frame.header_size..];
                const b64 = try arena.alloc(u8, std.base64.url_safe.Encoder.calcSize(gz.len));
                _ = std.base64.url_safe.Encoder.encode(b64, gz);
                // Padding, if any, percent-encoded.
                var padded: std.ArrayList(u8) = .empty;
                for (b64) |ch| if (ch == '=') try padded.appendSlice(arena, "%3D") else try padded.append(arena, ch);
                const r = try http1Get(gpa, arena, io, port, try std.fmt.allocPrint(arena, "/anole.test.Lookup/Find?encoding=proto&base64=1&compression=gzip&message={s}", .{padded.items}));
                try std.testing.expectEqual(@as(u16, 200), r.status);
                var reader: std.Io.Reader = .fixed(r.body);
                try std.testing.expectEqualStrings("squeezed", (try pb.EchoResponse.decode(&reader, arena)).message);
            }
            {
                // No message at all is the empty message (in protobuf's encoding).
                const r = try http1Get(gpa, arena, io, port, "/anole.test.Lookup/Find?encoding=proto");
                try std.testing.expectEqual(@as(u16, 200), r.status);
                var reader: std.Io.Reader = .fixed(r.body);
                try std.testing.expectEqual(@as(i32, 7), (try pb.EchoResponse.decode(&reader, arena)).index);
            }
            {
                // Store has side effects: no GET route.
                const r = try http1Get(gpa, arena, io, port, "/anole.test.Lookup/Store?encoding=json&message=%7B%7D");
                try std.testing.expectEqual(@as(u16, 405), r.status);
            }
            {
                const r = try http1Get(gpa, arena, io, port, "/anole.test.Lookup/Find?encoding=xml&message=x");
                try std.testing.expectEqual(@as(u16, 415), r.status);
            }
            {
                const r = try http1Get(gpa, arena, io, port, "/anole.test.Lookup/Find?encoding=json&connect=v2&message=%7B%7D");
                try std.testing.expectEqual(@as(u16, 400), r.status);
                try std.testing.expect(std.mem.indexOf(u8, r.body, "\"code\":\"invalid_argument\"") != null);
            }
            {
                const r = try http1Get(gpa, arena, io, port, "/anole.test.Lookup/Find?encoding=json&compression=br&message=%7B%7D");
                try std.testing.expectEqual(@as(u16, 501), r.status);
            }
            {
                // The registration's limit holds for GET too.
                const r = try http1Get(gpa, arena, io, port, "/anole.test.Lookup/Find?encoding=json&message=%7B%22message%22%3A%22" ++ x100 ++ "%22%7D");
                try std.testing.expectEqual(@as(u16, 429), r.status);
            }
        }
    }.run);
}

test "gRPC: two health registries in one process" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    const listeners: []const dusty.Listener = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } }, .http2_prior_knowledge = true }};
    var a = dusty.Server(void).init(gpa, io, .{ .listeners = listeners }, {});
    defer a.deinit();
    var b = dusty.Server(void).init(gpa, io, .{ .listeners = listeners }, {});
    defer b.deinit();
    var health_a: grpc.Health = .init(gpa, io);
    defer health_a.deinit();
    var health_b: grpc.Health = .init(gpa, io);
    defer health_b.deinit();
    health_a.registerOn(void, &a.router);
    health_b.registerOn(void, &b.router);
    try health_a.set("only.on.A", .SERVING);
    var future_a = try startServer(&a, io);
    defer future_a.cancel(io) catch {};
    var future_b = try startServer(&b, io);
    defer future_b.cancel(io) catch {};

    // HealthCheckRequest{service = "only.on.A"} has the wire form of an
    // EchoRequest with that message.
    const on_a = try Client.call(gpa, io, a.address.ip, "/grpc.health.v1.Health/Check", &.{.{ .message = "only.on.A" }}, &.{});
    defer on_a.deinit();
    try std.testing.expectEqual(@as(?u32, 0), on_a.grpc_status);
    const on_b = try Client.call(gpa, io, b.address.ip, "/grpc.health.v1.Health/Check", &.{.{ .message = "only.on.A" }}, &.{});
    defer on_b.deinit();
    try std.testing.expectEqual(@as(?u32, 5), on_b.grpc_status);
}

test "gRPC: the client's RST_STREAM cancels the handler" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var server = dusty.Server(void).init(gpa, io, .{
        .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } }, .http2_prior_knowledge = true }},
    }, {});
    defer server.deinit();
    grpc.register(void, &server.router, Echo, .{
        .Unary = unary,
        .ServerStream = serverStream,
        .ClientStream = clientStream,
        .Bidi = bidi,
    });
    var server_future = try startServer(&server, io);
    defer server_future.cancel(io) catch {};

    const h2 = @import("anole_h2_client");
    const conn = try h2.ClientConnection.connect(gpa, io, .{ .host = "127.0.0.1", .port = server.address.ip.getPort() });
    defer conn.close();
    var channel: grpc.Channel = .{ .conn = conn, .authority = "localhost" };
    const client: grpc.Client(Echo) = .{ .channel = &channel };
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    Sleeper.started.store(false, .release);
    Sleeper.canceled.store(false, .release);
    Sleeper.done.store(false, .release);
    {
        var s = try client.stream("Unary", arena, .{});
        defer s.deinit();
        try s.send(.{ .message = "sleep" });
        try s.closeSend();
        try wait.waitFlag(io, "the sleeping handler started", &Sleeper.started);
        const reset_at: std.Io.Clock.Timestamp = .now(io, .awake);
        s.cancel();
        // A 10 s sleep, ended by the cancel (and under test-timing, well
        // inside a second).
        try wait.waitFlag(io, "the canceled handler returned", &Sleeper.done);
        if (wait.timing()) try std.testing.expect(reset_at.durationTo(.now(io, .awake)).raw.toMilliseconds() < 1000);
        try std.testing.expect(Sleeper.canceled.load(.acquire));
    }
    // The connection serves on.
    const r = try client.unary("Unary", arena, .{ .message = "after" }, .{});
    try std.testing.expectEqual(grpc.Code.ok, r.status.code);
}

/// An h2c server whose calls sleep until canceled ("sleep" for Unary and
/// ServerStream, any ClientStream call), and a channel to it.
const SleepEnv = struct {
    io: std.Io,
    channel: *grpc.Channel,

    fn run(comptime body: fn (*SleepEnv) anyerror!void) !void {
        const gpa = std.testing.allocator;
        const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
        defer rt.deinit();
        const io = rt.io();
        var server = dusty.Server(void).init(gpa, io, .{
            .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } }, .http2_prior_knowledge = true }},
        }, {});
        defer server.deinit();
        grpc.register(void, &server.router, Echo, .{
            .Unary = unary,
            .ServerStream = serverStream,
            .ClientStream = clientStreamUnread,
            .Bidi = bidi,
        });
        var server_future = try startServer(&server, io);
        defer server_future.cancel(io) catch {};

        const h2 = @import("anole_h2_client");
        const conn = try h2.ClientConnection.connect(gpa, io, .{ .host = "127.0.0.1", .port = server.address.ip.getPort() });
        defer conn.close();
        var channel: grpc.Channel = .{ .conn = conn, .authority = "localhost" };
        Sleeper.started.store(false, .release);
        Sleeper.canceled.store(false, .release);
        Sleeper.done.store(false, .release);
        var env: SleepEnv = .{ .io = io, .channel = &channel };
        try body(&env);
    }

    /// The call was reset: the server's handler ended canceled.
    fn expectHandlerCanceled(env: *SleepEnv) !void {
        try wait.waitFlag(env.io, "the canceled handler returned", &Sleeper.done);
        try std.testing.expect(Sleeper.canceled.load(.acquire));
    }
};

/// What a calling task shares with the test, which joins it before the
/// test returns.
const CallerState = struct {
    io: std.Io,
    channel: *grpc.Channel,
    /// ServerStream: the first message came.
    got_first: std.atomic.Value(bool) = .init(false),
    /// ClientStream: the call's HTTP/2 stream, and whether a `send` is
    /// under way.
    stream: std.atomic.Value(?*@import("anole_h2_client").Stream) = .init(null),
    in_send: std.atomic.Value(bool) = .init(false),

    /// A `send` waits for room: its bytes are queued behind a full window.
    fn blockedInSend(st: *CallerState) bool {
        if (!st.in_send.load(.acquire)) return false;
        const s = st.stream.load(.acquire) orelse return false;
        const q = &s.out.type_erased;
        q.mutex.lockUncancelable(st.io);
        defer q.mutex.unlock(st.io);
        return q.putters.first != null;
    }
};

/// A failed wait still joins the calling task before the test returns.
fn joinAfter(env: *SleepEnv, f: *std.Io.Future(anyerror!void), err: anyerror) anyerror {
    f.cancel(env.io) catch {};
    return err;
}

test "gRPC client: a caller canceled while it waits for the response head gets Canceled" {
    try SleepEnv.run(struct {
        fn caller(st: *CallerState) anyerror!void {
            var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena_state.deinit();
            const client: grpc.Client(Echo) = .{ .channel = st.channel };
            var s = try client.stream("Unary", arena_state.allocator(), .{});
            defer s.deinit();
            try s.send(.{ .message = "sleep" });
            try s.closeSend();
            _ = try s.receive();
        }
        fn body(env: *SleepEnv) anyerror!void {
            var st: CallerState = .{ .io = env.io, .channel = env.channel };
            var f = try env.io.concurrent(caller, .{&st});
            wait.waitFlag(env.io, "the sleeping handler started", &Sleeper.started) catch |err| return joinAfter(env, &f, err);
            try std.testing.expectError(error.Canceled, f.cancel(env.io));
            try env.expectHandlerCanceled();
        }
    }.body);
}

test "gRPC client: a caller canceled while it reads the next message gets Canceled" {
    try SleepEnv.run(struct {
        fn caller(st: *CallerState) anyerror!void {
            var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena_state.deinit();
            const client: grpc.Client(Echo) = .{ .channel = st.channel };
            var s = try client.stream("ServerStream", arena_state.allocator(), .{});
            defer s.deinit();
            try s.send(.{ .message = "sleep" });
            try s.closeSend();
            _ = (try s.receive()) orelse return error.NoFirstMessage;
            st.got_first.store(true, .release);
            _ = try s.receive();
        }
        fn body(env: *SleepEnv) anyerror!void {
            var st: CallerState = .{ .io = env.io, .channel = env.channel };
            var f = try env.io.concurrent(caller, .{&st});
            wait.waitFlag(env.io, "the caller received the first message", &st.got_first) catch |err| return joinAfter(env, &f, err);
            try std.testing.expectError(error.Canceled, f.cancel(env.io));
            try env.expectHandlerCanceled();
        }
    }.body);
}

test "gRPC client: a caller canceled while a send waits for flow control gets Canceled" {
    try SleepEnv.run(struct {
        const big: [16 * 1024]u8 = @splat('x');
        fn caller(st: *CallerState) anyerror!void {
            var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena_state.deinit();
            const client: grpc.Client(Echo) = .{ .channel = st.channel };
            var s = try client.stream("ClientStream", arena_state.allocator(), .{});
            defer s.deinit();
            st.stream.store(s.stream.h2, .release);
            // The server never reads: one of these sends ends up waiting.
            while (true) {
                st.in_send.store(true, .release);
                try s.send(.{ .message = &big });
                st.in_send.store(false, .release);
            }
        }
        fn body(env: *SleepEnv) anyerror!void {
            var st: CallerState = .{ .io = env.io, .channel = env.channel };
            var f = try env.io.concurrent(caller, .{&st});
            wait.waitUntil(env.io, "a send waiting for flow control", &st, CallerState.blockedInSend) catch |err| return joinAfter(env, &f, err);
            try std.testing.expectError(error.Canceled, f.cancel(env.io));
            try env.expectHandlerCanceled();
        }
    }.body);
}

test "gRPC client: cancel() ends the call CANCELLED without a task cancel" {
    try SleepEnv.run(struct {
        fn body(env: *SleepEnv) anyerror!void {
            var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena_state.deinit();
            const client: grpc.Client(Echo) = .{ .channel = env.channel };
            var s = try client.stream("Unary", arena_state.allocator(), .{});
            defer s.deinit();
            try s.send(.{ .message = "sleep" });
            try s.closeSend();
            try wait.waitFlag(env.io, "the sleeping handler started", &Sleeper.started);
            s.cancel();
            try std.testing.expect(try s.receive() == null);
            try std.testing.expectEqual(grpc.Code.cancelled, s.status.?.code);
        }
    }.body);
}

test "gRPC: grpc-status survives concurrent unary calls on several executors" {
    // The status trailer once pointed at the finishing function's stack.
    // HTTP/2 sends trailers from its writer task, after that frame has
    // returned, so under load another stream's task could reuse the stack
    // first and the client read a garbled grpc-status (2% of calls in a
    // 4-core benchmark).
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(4) });
    defer rt.deinit();
    const io = rt.io();
    var server = dusty.Server(void).init(gpa, io, .{
        .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } }, .http2_prior_knowledge = true }},
    }, {});
    defer server.deinit();
    grpc.register(void, &server.router, Echo, .{
        .Unary = unary,
        .ServerStream = serverStream,
        .ClientStream = clientStream,
        .Bidi = bidi,
    });
    var server_future = try startServer(&server, io);
    defer server_future.cancel(io) catch {};

    const h2 = @import("anole_h2_client");
    const Caller = struct {
        /// Counts every call that failed or did not end with OK.
        /// A cancel of the group ends the caller (SAFETY.md C3).
        fn run(channel: *grpc.Channel, calls: usize, bad: *std.atomic.Value(usize)) std.Io.Cancelable!void {
            const client: grpc.Client(Echo) = .{ .channel = channel };
            for (0..calls) |_| {
                var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
                defer arena_state.deinit();
                const r = client.unary("Unary", arena_state.allocator(), .{ .message = "x" }, .{}) catch |err| {
                    if (@as(anyerror, err) == error.Canceled) return error.Canceled;
                    _ = bad.fetchAdd(1, .monotonic);
                    continue;
                };
                if (r.status.code != .ok) _ = bad.fetchAdd(1, .monotonic);
            }
        }
    };
    var conns: [4]*h2.ClientConnection = undefined;
    var channels: [conns.len]grpc.Channel = undefined;
    for (&conns, &channels) |*conn, *channel| {
        conn.* = try h2.ClientConnection.connect(gpa, io, .{ .host = "127.0.0.1", .port = server.address.ip.getPort() });
        channel.* = .{ .conn = conn.*, .authority = "localhost" };
    }
    defer for (conns) |conn| conn.close();
    var bad: std.atomic.Value(usize) = .init(0);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (0..32) |i| try group.concurrent(io, Caller.run, .{ &channels[i % channels.len], 100, &bad });
    try group.await(io);
    try std.testing.expectEqual(@as(usize, 0), bad.load(.monotonic));
}

// ---------------------------------------------------------------------------
// The channel's retries, pushback and breaker. The server answers from a
// script; every assertion counts what it saw.

const Script = struct {
    var hits: std.atomic.Value(u32) = .init(0);
    var prev_attempts_max: std.atomic.Value(u32) = .init(0);
    /// The first `fail_first` calls end with `code` (and `pushback`).
    var fail_first: u32 = 0;
    var code: grpc.Code = .unavailable;
    var pushback: ?[]const u8 = null;
    /// A first attempt (no grpc-previous-rpc-attempts) waits until
    /// canceled before answering; a retry answers at once.
    var slow_first_attempt: bool = false;

    fn reset(first: u32, c_: grpc.Code, pb_: ?[]const u8) void {
        slow_first_attempt = false;
        hits.store(0, .monotonic);
        prev_attempts_max.store(0, .monotonic);
        fail_first = first;
        code = c_;
        pushback = pb_;
    }

    fn scripted(call: *grpc.Call, req: pb.EchoRequest) anyerror!pb.EchoResponse {
        const n = hits.fetchAdd(1, .monotonic);
        const previous = call.metadata("grpc-previous-rpc-attempts");
        if (previous) |v| {
            const prev = std.fmt.parseInt(u32, v, 10) catch 0;
            _ = prev_attempts_max.fetchMax(prev, .monotonic);
        }
        if (slow_first_attempt and previous == null) try call.io.sleep(.fromSeconds(30), .awake);
        if (n < fail_first) {
            if (pushback) |p| try call.addTrailer("grpc-retry-pushback-ms", p);
            return call.fail(code, "scripted");
        }
        return .{ .message = req.message, .index = 0 };
    }
};

fn withScriptedServer(comptime body: fn (std.mem.Allocator, std.Io, u16) anyerror!void) !void {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var server = dusty.Server(void).init(gpa, io, .{
        .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } }, .http2_prior_knowledge = true }},
    }, {});
    defer server.deinit();
    grpc.register(void, &server.router, Echo, .{
        .Unary = Script.scripted,
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
    try server.waitReady(io);
    try body(gpa, io, server.address.ip.getPort());
}

const fast_grpc_retry: @import("resilience_core").Retry = .{
    .attempts = 4,
    .backoff = .{ .base = .fromMilliseconds(1), .max = .fromMilliseconds(1), .jitter = .none },
    .throttle = null,
};

test "grpc channel: UNAVAILABLE twice then OK is OK, and the server saw grpc-previous-rpc-attempts 2" {
    Script.reset(2, .unavailable, null);
    try withScriptedServer(struct {
        fn run(gpa: std.mem.Allocator, io: std.Io, port: u16) !void {
            const channel = try grpc.Channel.connect(gpa, io, .{ .host = "127.0.0.1", .port = port }, .{ .retry = fast_grpc_retry });
            defer channel.close();
            const client: grpc.Client(Echo) = .{ .channel = channel };
            var arena_state: std.heap.ArenaAllocator = .init(gpa);
            defer arena_state.deinit();
            const r = try client.unary("Unary", arena_state.allocator(), .{ .message = "x" }, .{});
            try std.testing.expectEqual(grpc.Code.ok, r.status.code);
            try std.testing.expectEqual(@as(u32, 3), Script.hits.load(.monotonic));
            try std.testing.expectEqual(@as(u32, 2), Script.prev_attempts_max.load(.monotonic));
        }
    }.run);
}

test "grpc channel: INVALID_ARGUMENT is not retried" {
    Script.reset(100, .invalid_argument, null);
    try withScriptedServer(struct {
        fn run(gpa: std.mem.Allocator, io: std.Io, port: u16) !void {
            const channel = try grpc.Channel.connect(gpa, io, .{ .host = "127.0.0.1", .port = port }, .{ .retry = fast_grpc_retry });
            defer channel.close();
            const client: grpc.Client(Echo) = .{ .channel = channel };
            var arena_state: std.heap.ArenaAllocator = .init(gpa);
            defer arena_state.deinit();
            const r = try client.unary("Unary", arena_state.allocator(), .{ .message = "x" }, .{});
            try std.testing.expectEqual(grpc.Code.invalid_argument, r.status.code);
            try std.testing.expectEqual(@as(u32, 1), Script.hits.load(.monotonic));
        }
    }.run);
}

test "grpc channel: pushback -1 stops the retries; pushback 0 retries at once" {
    try withScriptedServer(struct {
        fn run(gpa: std.mem.Allocator, io: std.Io, port: u16) !void {
            const channel = try grpc.Channel.connect(gpa, io, .{ .host = "127.0.0.1", .port = port }, .{ .retry = fast_grpc_retry });
            defer channel.close();
            const client: grpc.Client(Echo) = .{ .channel = channel };
            var arena_state: std.heap.ArenaAllocator = .init(gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();

            Script.reset(100, .unavailable, "-1");
            const stopped = try client.unary("Unary", arena, .{ .message = "x" }, .{});
            try std.testing.expectEqual(grpc.Code.unavailable, stopped.status.code);
            try std.testing.expectEqual(@as(u32, 1), Script.hits.load(.monotonic));

            Script.reset(2, .unavailable, "0");
            const ok = try client.unary("Unary", arena, .{ .message = "x" }, .{});
            try std.testing.expectEqual(grpc.Code.ok, ok.status.code);
            try std.testing.expectEqual(@as(u32, 3), Script.hits.load(.monotonic));
        }
    }.run);
}

test "grpc channel: a pushback past max_retry_after returns that answer at once" {
    Script.reset(100, .unavailable, "3600000");
    try withScriptedServer(struct {
        fn run(gpa: std.mem.Allocator, io: std.Io, port: u16) !void {
            var policy = fast_grpc_retry;
            policy.max_retry_after = .fromSeconds(2);
            const channel = try grpc.Channel.connect(gpa, io, .{ .host = "127.0.0.1", .port = port }, .{ .retry = policy });
            defer channel.close();
            const client: grpc.Client(Echo) = .{ .channel = channel };
            var arena_state: std.heap.ArenaAllocator = .init(gpa);
            defer arena_state.deinit();
            const r = try client.unary("Unary", arena_state.allocator(), .{ .message = "x" }, .{});
            try std.testing.expectEqual(grpc.Code.unavailable, r.status.code);
            try std.testing.expectEqual(@as(u32, 1), Script.hits.load(.monotonic));
        }
    }.run);
}

test "grpc channel breaker: open answers UNAVAILABLE \"circuit open\" and opens no stream" {
    Script.reset(1000, .unavailable, null);
    try withScriptedServer(struct {
        fn run(gpa: std.mem.Allocator, io: std.Io, port: u16) !void {
            const channel = try grpc.Channel.connect(gpa, io, .{ .host = "127.0.0.1", .port = port }, .{
                .breaker = .{ .consecutive_failures = 2, .failure_ratio = 0 },
            });
            defer channel.close();
            const client: grpc.Client(Echo) = .{ .channel = channel };
            var arena_state: std.heap.ArenaAllocator = .init(gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            for (0..2) |_| {
                const r = try client.unary("Unary", arena, .{ .message = "x" }, .{});
                try std.testing.expectEqual(grpc.Code.unavailable, r.status.code);
            }
            const seen = Script.hits.load(.monotonic);
            try std.testing.expectEqual(@as(u32, 2), seen);
            const open = try client.unary("Unary", arena, .{ .message = "x" }, .{});
            try std.testing.expectEqual(grpc.Code.unavailable, open.status.code);
            try std.testing.expectEqualStrings("circuit open", open.status.message);
            try std.testing.expectEqual(seen, Script.hits.load(.monotonic));
        }
    }.run);
}

test "grpc channel: Retry.attempt_timeout cuts a stuck attempt and the call is retried within its own timeout" {
    try withScriptedServer(struct {
        fn run(gpa: std.mem.Allocator, io: std.Io, port: u16) !void {
            var policy = fast_grpc_retry;
            policy.attempt_timeout = .fromMilliseconds(100);
            const channel = try grpc.Channel.connect(gpa, io, .{ .host = "127.0.0.1", .port = port }, .{
                .retry = policy,
                .retry_codes = &.{.deadline_exceeded},
            });
            defer channel.close();
            const client: grpc.Client(Echo) = .{ .channel = channel };
            var arena_state: std.heap.ArenaAllocator = .init(gpa);
            defer arena_state.deinit();
            // The first attempt never answers; a retry does. Which attempt
            // the server sees first does not matter: the request says.
            Script.reset(0, .ok, null);
            Script.slow_first_attempt = true;
            const r = try client.unary("Unary", arena_state.allocator(), .{ .message = "x" }, .{ .timeout = .fromSeconds(30) });
            try std.testing.expectEqual(grpc.Code.ok, r.status.code);
            try std.testing.expect(Script.prev_attempts_max.load(.monotonic) >= 1);
        }
    }.run);
}

/// The client ports the calls of `withCountingServer` came from: one per
/// connection the server accepted.
const Connections = struct {
    var ports: [16]std.atomic.Value(u16) = @splat(.init(0));

    fn reset() void {
        for (&ports) |*p| p.store(0, .monotonic);
    }

    fn unary(call: *grpc.Call, req: pb.EchoRequest) anyerror!pb.EchoResponse {
        const port = call.req.remote_address.getPort();
        for (&ports) |*p| {
            const seen = p.cmpxchgStrong(0, port, .acq_rel, .acquire) orelse break;
            if (seen == port) break;
        }
        return .{ .message = req.message, .index = 0 };
    }

    fn count() usize {
        var n: usize = 0;
        for (&ports) |*p| {
            if (p.load(.acquire) != 0) n += 1;
        }
        return n;
    }
};

/// An Echo server whose unary calls note their connection (`Connections`),
/// on a runtime of `executors`.
fn withCountingServer(executors: u8, comptime body: fn (std.mem.Allocator, std.Io, u16) anyerror!void) !void {
    Connections.reset();
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(executors) });
    defer rt.deinit();
    const io = rt.io();
    var server = dusty.Server(void).init(gpa, io, .{
        .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } }, .http2_prior_knowledge = true }},
    }, {});
    defer server.deinit();
    grpc.register(void, &server.router, Echo, .{
        .Unary = Connections.unary,
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
    try server.waitReady(io);
    try body(gpa, io, server.address.ip.getPort());
}

/// One unary call on `channel`; a failure is counted in `failed`.
fn countedCall(channel: *grpc.Channel, gpa: std.mem.Allocator, failed: *std.atomic.Value(u32)) void {
    const client: grpc.Client(Echo) = .{ .channel = channel };
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const r = client.unary("Unary", arena_state.allocator(), .{ .message = "x" }, .{}) catch {
        _ = failed.fetchAdd(1, .monotonic);
        return;
    };
    if (r.status.code != .ok) _ = failed.fetchAdd(1, .monotonic);
}

/// Shuts the channel's connection down under it and waits until the
/// channel sees it closed.
fn loseConnection(channel: *grpc.Channel, io: std.Io) !void {
    const conn = channel.conn.?;
    conn.socket.shutdown(io, .both) catch {};
    try wait.waitUntil(io, "the channel's connection closed", conn, struct {
        fn closed(c_: *@TypeOf(conn.*)) bool {
            return !c_.isOpen();
        }
    }.closed);
}

test "grpc channel: calls after the connection closed share one redial" {
    try withCountingServer(2, struct {
        fn run(gpa: std.mem.Allocator, io: std.Io, port: u16) !void {
            const channel = try grpc.Channel.connect(gpa, io, .{ .host = "127.0.0.1", .port = port }, .{});
            defer channel.close();
            var failed: std.atomic.Value(u32) = .init(0);
            countedCall(channel, gpa, &failed);
            try loseConnection(channel, io);
            var group: std.Io.Group = .init;
            defer group.cancel(io);
            for (0..16) |_| try group.concurrent(io, countedCall, .{ channel, gpa, &failed });
            try group.await(io);
            try std.testing.expectEqual(@as(u32, 0), failed.load(.monotonic));
            try std.testing.expectEqual(@as(usize, 2), Connections.count());
        }
    }.run);
}
