//! The Anole bench server (bench/SPEC.md), built the way an application
//! that depends on Anole is (tests/consumer):
//!
//!   zig build -Doptimize=ReleaseFast   # zig-out/bin/anole-bench
const std = @import("std");

pub fn build(b: *std.Build) void {
    const app = @import("anole").addApp(b, .{
        .name = "anole-bench",
        .root_source_file = b.path("src/main.zig"),
    });
    app.exe.root_module.link_libc = true;
}
