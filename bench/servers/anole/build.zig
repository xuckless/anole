//! The Anole bench server (bench/SPEC.md), built the way an application
//! that depends on Anole is (tests/consumer):
//!
//!   zig build -Doptimize=ReleaseFast   # zig-out/bin/anole-bench
//!
//! `-Dslim=true` (Anole 0.3 and later) leaves the console, OpenAPI, NATS
//! and Kafka out of the library, to measure what their code costs a build
//! that does not use them; otherwise it is the same build as `addApp`.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const slim = b.option(bool, "slim", "Anole without console, OpenAPI, NATS and Kafka (0.3+)") orelse false;
    if (!slim) {
        const app = @import("anole").addApp(b, .{
            .name = "anole-bench",
            .root_source_file = b.path("src/main.zig"),
        });
        app.exe.root_module.link_libc = true;
        return;
    }
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const anole_dep = b.dependency("anole", .{
        .target = target,
        .optimize = optimize,
        .console = false,
        .openapi = false,
        .nats = false,
        .kafka = false,
    });
    const exe = b.addExecutable(.{
        .name = "anole-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("anole", anole_dep.module("anole"));
    exe.root_module.link_libc = true;
    b.installArtifact(exe);
}
