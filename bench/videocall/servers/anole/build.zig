//! The video-call app on Anole (bench/videocall/SPEC.md), set up as
//! docs/getting-started.md does: Anole from `zig fetch`, built by `addApp`.
//!
//!   zig build -Doptimize=ReleaseSafe   # zig-out/bin/videocall
const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = @import("anole").addApp(b, .{
        .name = "videocall",
        .root_source_file = b.path("src/main.zig"),
    });
}
