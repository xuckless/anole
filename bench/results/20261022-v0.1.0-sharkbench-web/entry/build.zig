const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = @import("anole").addApp(b, .{
        .name = "benchmark",
        .root_source_file = b.path("src/main.zig"),
    });
}
