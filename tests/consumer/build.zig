//! A project that depends on Anole the way a user's would: an HTTP route
//! and a gRPC service whose code `zig build` generates from
//! proto/greeter.proto (`anole.addApp` with `protos`).
//!
//!   zig build             # the server, its protobuf code included
//!   zig build run         # and run it
//!   zig build gen-proto   # the same code into src/gen, for those who commit it
//!   zig build lambda      # AWS Lambda zips in zig-out/lambda (addApp's `.lambda`)
const std = @import("std");
const anole_build = @import("anole");

pub fn build(b: *std.Build) void {
    const app = anole_build.addApp(b, .{
        .name = "consumer",
        .root_source_file = b.path("src/main.zig"),
        .profile = .full,
        .protos = &.{.{ .name = "greeter_pb", .file = b.path("proto/greeter.proto") }},
        .lambda = .{ .include = &.{"proto"} },
    });

    anole_build.addProtoGen(b.step("gen-proto", "Generate Zig from the .proto files into src/gen"), app.anole, .{
        .source_files = &.{b.path("proto/greeter.proto")},
        .include_directories = &.{b.path("proto")},
        .destination_directory = b.path("src/gen"),
    });
}
