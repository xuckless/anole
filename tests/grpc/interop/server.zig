//! grpc.testing.TestService for the gRPC interop suite
//! (https://github.com/grpc/grpc/blob/master/doc/interop-test-descriptions.md),
//! on cleartext HTTP/2, or on TLS with a certificate and key given as PEM
//! files. tests/grpc/interop/run.sh drives it with grpc-go's interop client.
//!
//!     grpc-interop-server <port> [<cert.pem> <key.pem>]
const std = @import("std");
const anole = @import("anole");
const pb = @import("anole_interop_pb");

pub const zio_options = anole.zio_options;
pub const std_options: std.Options = .{
    .logFn = anole.logFn,
    .log_level = .info,
    .log_scope_levels = &.{ .{ .scope = .zio, .level = .info }, .{ .scope = .dusty_access, .level = .warn } },
};

const Call = anole.grpc.Call;
const TestService = pb.TestService(Call, anyerror);
const UnimplementedService = pb.UnimplementedService(Call, anyerror);

fn payload(call: *Call, size: i32) !pb.Payload {
    if (size < 0) return call.fail(.invalid_argument, "negative size");
    const body = try call.arena.alloc(u8, @intCast(size));
    @memset(body, 0);
    return .{ .type = .COMPRESSABLE, .body = body };
}

/// Echoes the metadata the interop client asks to have echoed.
fn echoMetadata(call: *Call) !void {
    if (call.metadata("x-grpc-test-echo-initial")) |v| try call.addHeader("x-grpc-test-echo-initial", v);
    if (call.metadata("x-grpc-test-echo-trailing-bin")) |v| try call.addTrailer("x-grpc-test-echo-trailing-bin", v);
}

fn echoStatus(call: *Call, status: ?pb.EchoStatus) !void {
    const s = status orelse return;
    if (s.code == 0) return;
    return call.fail(anole.grpc.Code.fromInt(@intCast(s.code)), s.message);
}

fn emptyCall(call: *Call, _: pb.Empty) anyerror!pb.Empty {
    try echoMetadata(call);
    return .{};
}

fn unaryCall(call: *Call, req: pb.SimpleRequest) anyerror!pb.SimpleResponse {
    try echoMetadata(call);
    if (req.expect_compressed) |e| if (e.value and call.requestCompression() == .identity)
        return call.fail(.invalid_argument, "expected a compressed request");
    try echoStatus(call, req.response_status);
    return .{ .payload = try payload(call, req.response_size) };
}

fn streamingOutputCall(call: *Call, req: pb.StreamingOutputCallRequest, out: *std.Io.Queue(pb.StreamingOutputCallResponse)) anyerror!void {
    try echoMetadata(call);
    for (req.response_parameters.items) |p| {
        if (p.interval_us > 0) try call.io.sleep(.fromMicroseconds(p.interval_us), .awake);
        try out.putOne(call.io, .{ .payload = try payload(call, p.size) });
    }
    try echoStatus(call, req.response_status);
}

fn streamingInputCall(call: *Call, in: *std.Io.Queue(pb.StreamingInputCallRequest)) anyerror!pb.StreamingInputCallResponse {
    try echoMetadata(call);
    var total: i32 = 0;
    while (true) {
        const req = in.getOne(call.io) catch |err| switch (err) {
            error.Closed => break,
            else => |e| return e,
        };
        // The probe of client_compressed_streaming: an uncompressed message
        // that expects compression is refused at once, before the client
        // half-closes (grpc-dotnet waits for the status without closing).
        if (req.expect_compressed) |e| if (e.value and call.requestCompression() == .identity)
            return call.fail(.invalid_argument, "expected a compressed request");
        if (req.payload) |p| total += @intCast(p.body.len);
    }
    return .{ .aggregated_payload_size = total };
}

fn fullDuplexCall(call: *Call, in: *std.Io.Queue(pb.StreamingOutputCallRequest), out: *std.Io.Queue(pb.StreamingOutputCallResponse)) anyerror!void {
    try echoMetadata(call);
    while (true) {
        const req = in.getOne(call.io) catch |err| switch (err) {
            error.Closed => return,
            else => |e| return e,
        };
        try echoStatus(call, req.response_status);
        for (req.response_parameters.items) |p| {
            if (p.interval_us > 0) try call.io.sleep(.fromMicroseconds(p.interval_us), .awake);
            try out.putOne(call.io, .{ .payload = try payload(call, p.size) });
        }
    }
}

fn halfDuplexCall(call: *Call, in: *std.Io.Queue(pb.StreamingOutputCallRequest), out: *std.Io.Queue(pb.StreamingOutputCallResponse)) anyerror!void {
    var all: std.ArrayList(pb.StreamingOutputCallRequest) = .empty;
    while (true) {
        const req = in.getOne(call.io) catch |err| switch (err) {
            error.Closed => break,
            else => |e| return e,
        };
        try all.append(call.arena, req);
    }
    for (all.items) |req| for (req.response_parameters.items) |p| {
        try out.putOne(call.io, .{ .payload = try payload(call, p.size) });
    };
}

fn unimplemented(call: *Call, _: pb.Empty) anyerror!pb.Empty {
    return call.fail(.unimplemented, "not implemented");
}

pub fn main(init: std.process.Init) !void {
    var port: u16 = 10000;
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    if (args.next()) |p| port = try std.fmt.parseInt(u16, p, 10);
    const cert_path = args.next();
    const key_path = args.next();
    var app = try anole.Server(void).init(init.gpa, if (cert_path) |cert| .{
        .http = null,
        .https = .{ .address = "127.0.0.1", .port = port, .cert = .{ .files = .{ .cert_path = cert, .key_path = key_path orelse return error.MissingKey } } },
        // TLS serves HTTP/2 and HTTP/3 on one port number (TCP and UDP).
        .http3 = if (anole.features.http3) .{} else null,
    } else .{
        .http = .{ .address = "127.0.0.1", .port = port, .h2c = true },
    }, {});
    defer app.deinit();
    // The unary handlers here never wait, so they run without a task on
    // HTTP/2 (`no_wait`), and the interop suites cover that path.
    anole.grpc.registerWith(void, app.router, TestService, .{
        .EmptyCall = emptyCall,
        .UnaryCall = unaryCall,
        .CacheableUnaryCall = unaryCall,
        .StreamingOutputCall = streamingOutputCall,
        .StreamingInputCall = streamingInputCall,
        .FullDuplexCall = fullDuplexCall,
        .HalfDuplexCall = halfDuplexCall,
        .UnimplementedCall = unimplemented,
    }, .{ .no_wait = true });
    std.log.info("interop server on 127.0.0.1:{d} ({s})", .{ port, if (cert_path == null) "h2c" else if (anole.features.http3) "TLS + HTTP/3" else "TLS" });
    try app.run();
}
