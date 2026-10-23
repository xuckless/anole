//! A gRPC server for the transport comparison: TestService/UnaryCall on a
//! Unix socket, h2c and TLS at once (bench/servers/anole-grpc/src/main.zig).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const app = @import("anole").addApp(b, .{
        .name = "anole-grpc",
        .root_source_file = b.path("src/main.zig"),
        .protos = &.{.{
            .name = "testing_pb",
            .file = b.path("../../grpc/proto/grpc/testing/test.proto"),
            .package = "grpc.testing",
            .include_directories = &.{b.path("../../grpc/proto")},
        }},
    });
    app.exe.root_module.link_libc = true;
}
