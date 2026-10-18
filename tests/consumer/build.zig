//! A project that depends on Anole the way a user's would: an HTTP route
//! and a gRPC service whose code `anole.addProtoGen` generates.
//!
//!   zig build gen-proto   # proto/greeter.proto -> src/gen/greeter.pb.zig
//!   zig build             # the server
const std = @import("std");
const anole_build = @import("anole");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const anole_dep = b.dependency("anole", .{ .target = target, .optimize = optimize });

    const gen = b.step("gen-proto", "Generate Zig from the .proto files");
    anole_build.addProtoGen(gen, anole_dep, .{
        .source_files = &.{b.path("proto/greeter.proto")},
        .include_directories = &.{b.path("proto")},
        .destination_directory = b.path("src/gen"),
    });

    const exe = b.addExecutable(.{
        .name = "consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "anole", .module = anole_dep.module("anole") },
                .{ .name = "greeter_pb", .module = b.createModule(.{
                    .root_source_file = b.path("src/gen/greeter.pb.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{.{ .name = "protobuf", .module = anole_dep.module("protobuf") }},
                }) },
            },
        }),
    });
    b.installArtifact(exe);
}
