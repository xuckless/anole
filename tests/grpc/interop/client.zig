//! The gRPC interop client cases
//! (https://github.com/grpc/grpc/blob/master/doc/interop-test-descriptions.md)
//! on anole.grpc's client, against any interop server (grpc-go's, in
//! tests/grpc/interop/run-client.sh).
//!
//!   grpc-interop-client <port> <test_case> [<ca.pem>]
//!
//! With a CA certificate, over TLS to "localhost"; else cleartext HTTP/2.
const std = @import("std");
const anole = @import("anole");
const pb = @import("anole_interop_pb");

pub const zio_options = anole.zio_options;

const grpc = anole.grpc;
const TestService = pb.TestService(grpc.Call, anyerror);
const Client = grpc.Client(TestService);

fn zeros(arena: std.mem.Allocator, n: usize) !pb.Payload {
    const body = try arena.alloc(u8, n);
    @memset(body, 0);
    return .{ .type = .COMPRESSABLE, .body = body };
}

fn expect(ok: bool, what: []const u8) !void {
    if (!ok) {
        std.log.err("check failed: {s}", .{what});
        return error.InteropCheckFailed;
    }
}

fn expectOk(status: grpc.Status) !void {
    if (status.code != .ok) {
        std.log.err("status {t}: {s}", .{ status.code, status.message });
        return error.InteropCheckFailed;
    }
}

fn emptyUnary(client: Client, arena: std.mem.Allocator) !void {
    const r = try client.unary("EmptyCall", arena, .{}, .{});
    try expectOk(r.status);
}

fn largeUnary(client: Client, arena: std.mem.Allocator) !void {
    const r = try client.unary("UnaryCall", arena, .{ .response_size = 314159, .payload = try zeros(arena, 271828) }, .{});
    try expectOk(r.status);
    try expect(r.message.?.payload.?.body.len == 314159, "response payload size");
}

fn clientStreaming(client: Client, arena: std.mem.Allocator) !void {
    var s = try client.stream("StreamingInputCall", arena, .{});
    defer s.deinit();
    for ([_]usize{ 27182, 8, 1828, 45904 }) |n| try s.send(.{ .payload = try zeros(arena, n) });
    try s.closeSend();
    const reply = try s.receive();
    try expect(reply != null, "a response");
    try expect(reply.?.aggregated_payload_size == 74922, "aggregated size");
    try expect(try s.receive() == null, "one response");
    try expectOk(s.status.?);
}

fn serverStreaming(client: Client, arena: std.mem.Allocator) !void {
    var s = try client.stream("StreamingOutputCall", arena, .{});
    defer s.deinit();
    const sizes = [_]i32{ 31415, 9, 2653, 58979 };
    var req: pb.StreamingOutputCallRequest = .{};
    for (sizes) |n| try req.response_parameters.append(arena, .{ .size = n });
    try s.send(req);
    try s.closeSend();
    var i: usize = 0;
    while (try s.receive()) |m| : (i += 1) {
        try expect(i < sizes.len and m.payload.?.body.len == @as(usize, @intCast(sizes[i])), "response size");
    }
    try expect(i == sizes.len, "response count");
    try expectOk(s.status.?);
}

fn pingPong(client: Client, arena: std.mem.Allocator) !void {
    var s = try client.stream("FullDuplexCall", arena, .{});
    defer s.deinit();
    const pairs = [_][2]i32{ .{ 31415, 27182 }, .{ 9, 8 }, .{ 2653, 1828 }, .{ 58979, 45904 } };
    for (pairs) |p| {
        var req: pb.StreamingOutputCallRequest = .{ .payload = try zeros(arena, @intCast(p[1])) };
        try req.response_parameters.append(arena, .{ .size = p[0] });
        try s.send(req);
        const reply = try s.receive();
        try expect(reply != null and reply.?.payload.?.body.len == @as(usize, @intCast(p[0])), "ping-pong response");
    }
    try s.closeSend();
    try expect(try s.receive() == null, "end of stream");
    try expectOk(s.status.?);
}

fn emptyStream(client: Client, arena: std.mem.Allocator) !void {
    var s = try client.stream("FullDuplexCall", arena, .{});
    defer s.deinit();
    try s.closeSend();
    try expect(try s.receive() == null, "no responses");
    try expectOk(s.status.?);
}

fn statusCodeAndMessage(client: Client, arena: std.mem.Allocator, message: []const u8) !void {
    const r = try client.unary("UnaryCall", arena, .{ .response_status = .{ .code = 2, .message = message } }, .{});
    try expect(r.status.code == .unknown, "unary status code");
    try expect(std.mem.eql(u8, r.status.message, message), "unary status message");
    var s = try client.stream("FullDuplexCall", arena, .{});
    defer s.deinit();
    try s.send(.{ .response_status = .{ .code = 2, .message = message } });
    try s.closeSend();
    while (try s.receive()) |_| {}
    try expect(s.status.?.code == .unknown, "streaming status code");
    try expect(std.mem.eql(u8, s.status.?.message, message), "streaming status message");
}

fn customMetadata(client: Client, arena: std.mem.Allocator) !void {
    const initial = "test_initial_metadata_value";
    const trailing = "q6ur"; // base64 of ab ab ab
    const metadata = [_]anole.h2.Header{
        .{ .name = "x-grpc-test-echo-initial", .value = initial },
        .{ .name = "x-grpc-test-echo-trailing-bin", .value = trailing },
    };
    const r = try client.unary("UnaryCall", arena, .{ .response_size = 314159, .payload = try zeros(arena, 271828) }, .{ .metadata = &metadata });
    try expectOk(r.status);
    try expect(find(r.headers, "x-grpc-test-echo-initial", initial), "initial metadata echoed");
    try expect(find(r.trailers, "x-grpc-test-echo-trailing-bin", trailing), "trailing metadata echoed");
}

fn find(fields: []const anole.h2.Header, name: []const u8, value: []const u8) bool {
    for (fields) |f| if (std.mem.eql(u8, f.name, name)) return std.mem.eql(u8, std.mem.trimEnd(u8, f.value, "="), std.mem.trimEnd(u8, value, "="));
    return false;
}

fn timeoutOnSleepingServer(client: Client, arena: std.mem.Allocator) !void {
    var s = try client.stream("FullDuplexCall", arena, .{ .timeout = .fromMilliseconds(1) });
    defer s.deinit();
    s.send(.{ .payload = try zeros(arena, 27182) }) catch {};
    while (try s.receive()) |_| {}
    try expect(s.status.?.code == .deadline_exceeded, "DEADLINE_EXCEEDED");
}

fn unimplementedMethod(client: Client, arena: std.mem.Allocator) !void {
    const r = try client.unary("UnimplementedCall", arena, .{}, .{});
    try expect(r.status.code == .unimplemented, "UNIMPLEMENTED");
}

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    const port = try std.fmt.parseInt(u16, args.next() orelse "10000", 10);
    const case = args.next() orelse return error.MissingTestCase;
    // TLS, trusting this CA certificate (PEM), for the server's name
    // "localhost"; cleartext HTTP/2 without it.
    const ca_path = args.next();

    const rt = try anole.zio.Runtime.init(init.gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    const conn = try anole.h2.ClientConnection.connect(init.gpa, io, .{
        .host = if (ca_path != null) "localhost" else "127.0.0.1",
        .address = .{ .ip4 = .loopback(port) },
        .port = port,
        .tls = if (ca_path) |path| .{ .ca = .{ .file = .{ .path = path } } } else null,
    });
    defer conn.close();
    var channel: grpc.Channel = .{ .conn = conn, .authority = "localhost", .scheme = if (ca_path != null) "https" else "http" };
    const client: Client = .{ .channel = &channel };
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const eq = std.mem.eql;
    if (eq(u8, case, "empty_unary")) try emptyUnary(client, arena) else if (eq(u8, case, "large_unary")) try largeUnary(client, arena) else if (eq(u8, case, "client_streaming")) try clientStreaming(client, arena) else if (eq(u8, case, "server_streaming")) try serverStreaming(client, arena) else if (eq(u8, case, "ping_pong")) try pingPong(client, arena) else if (eq(u8, case, "empty_stream")) try emptyStream(client, arena) else if (eq(u8, case, "status_code_and_message")) try statusCodeAndMessage(client, arena, "test status message") else if (eq(u8, case, "special_status_message")) try statusCodeAndMessage(client, arena, "\t\ntest with whitespace\r\nand Unicode BMP \u{263A} and non-BMP \u{1F608}\t\n") else if (eq(u8, case, "custom_metadata")) try customMetadata(client, arena) else if (eq(u8, case, "timeout_on_sleeping_server")) try timeoutOnSleepingServer(client, arena) else if (eq(u8, case, "unimplemented_method")) try unimplementedMethod(client, arena) else return error.UnknownTestCase;
}
