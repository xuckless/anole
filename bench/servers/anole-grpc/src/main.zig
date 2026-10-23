//! grpc.testing.TestService/UnaryCall on three listeners of one server, for
//! comparing transports with the same handler:
//!
//!   GRPC_UNIX (/sock/grpc.sock)  cleartext HTTP/2 on a Unix socket
//!   GRPC_H2C_PORT (50051)        h2c on 127.0.0.1
//!   GRPC_TLS_PORT (50052)        TLS (h2) on 127.0.0.1, CERT_FILE / KEY_FILE
//!
//! WORKERS executors (1). The handler answers `response_size` zero bytes.
const std = @import("std");
const anole = @import("anole");
const pb = @import("testing_pb");

pub const zio_options = anole.zio_options;
pub const std_options: std.Options = .{ .logFn = anole.logFn, .log_level = .info };

const Call = anole.grpc.Call;

fn unaryCall(call: *Call, req: pb.SimpleRequest) anyerror!pb.SimpleResponse {
    if (req.response_size < 0) return call.fail(.invalid_argument, "negative size");
    const body = try call.arena.alloc(u8, @intCast(req.response_size));
    @memset(body, 0);
    return .{ .payload = .{ .type = .COMPRESSABLE, .body = body } };
}

fn emptyCall(_: *Call, _: pb.Empty) anyerror!pb.Empty {
    return .{};
}

// The service's other methods, which the bench does not call.
fn unimplemented(call: *Call, _: pb.Empty) anyerror!pb.Empty {
    return call.fail(.unimplemented, "not in the bench server");
}
fn streamingOutputCall(call: *Call, _: pb.StreamingOutputCallRequest, _: *std.Io.Queue(pb.StreamingOutputCallResponse)) anyerror!void {
    return call.fail(.unimplemented, "not in the bench server");
}
fn streamingInputCall(call: *Call, _: *std.Io.Queue(pb.StreamingInputCallRequest)) anyerror!pb.StreamingInputCallResponse {
    return call.fail(.unimplemented, "not in the bench server");
}
fn duplexCall(call: *Call, _: *std.Io.Queue(pb.StreamingOutputCallRequest), _: *std.Io.Queue(pb.StreamingOutputCallResponse)) anyerror!void {
    return call.fail(.unimplemented, "not in the bench server");
}

fn env(name: [:0]const u8, default: []const u8) []const u8 {
    return std.mem.span(std.c.getenv(name) orelse return default);
}

fn envInt(comptime T: type, name: [:0]const u8, default: T) T {
    return std.fmt.parseInt(T, env(name, ""), 10) catch default;
}

pub fn main(init: std.process.Init) !void {
    const cert: anole.Cert = .fromFiles(env("CERT_FILE", "/certs/cert.pem"), env("KEY_FILE", "/certs/key.pem"));
    var app = try anole.Server(void).init(init.gpa, .{
        .executors = .exact(envInt(u8, "WORKERS", 1)),
        .listeners = &.{
            .{ .name = "unix", .unix = env("GRPC_UNIX", "/sock/grpc.sock") },
            .{ .name = "h2c", .address = "127.0.0.1", .port = envInt(u16, "GRPC_H2C_PORT", 50051), .http1 = false },
            .{ .name = "tls", .address = "127.0.0.1", .port = envInt(u16, "GRPC_TLS_PORT", 50052), .tls = .{ .cert = cert }, .http1 = false },
        },
    }, {});
    defer app.deinit();
    app.grpc(pb.TestService, .{
        .EmptyCall = emptyCall,
        .UnaryCall = unaryCall,
        .CacheableUnaryCall = unaryCall,
        .StreamingOutputCall = streamingOutputCall,
        .StreamingInputCall = streamingInputCall,
        .FullDuplexCall = duplexCall,
        .HalfDuplexCall = duplexCall,
        .UnimplementedCall = unimplemented,
    });
    try app.run();
}
