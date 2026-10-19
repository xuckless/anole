//! The dusty bench server: upstream dusty on upstream zio, wired the way
//! dusty's README and its httpbin example do it.
//!
//!   zig build -Doptimize=ReleaseFast   # zig-out/bin/dusty-bench
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Cleartext HTTP/1.1 and WebSockets only: no TLS provider to fetch.
    const dusty = b.dependency("dusty", .{ .target = target, .optimize = optimize, .use_tls = false });
    const zio = b.dependency("zio", .{ .target = target, .optimize = optimize });
    // dusty's README: replace its `zio` stub so timeouts use zio.AutoCancel.
    dusty.module("dusty").addImport("zio", zio.module("zio"));

    const exe = b.addExecutable(.{
        .name = "dusty-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "dusty", .module = dusty.module("dusty") },
                .{ .name = "zio", .module = zio.module("zio") },
            },
        }),
    });
    b.installArtifact(exe);
}
