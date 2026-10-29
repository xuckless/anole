// lint-path: src/http/core/placement.zig
const std = @import("std");

pub fn concurrent(io: std.Io, group: *std.Io.Group, comptime f: anytype, args: anytype) !void {
    try group.concurrent(io, f, args);
}

fn spawn(rt: anytype) void {
    rt.spawnInto(work, .{});
}

fn work() void {}
