// lint-path: src/example/t1_thread.zig
const std = @import("std");

fn detached() !void {
    (try std.Thread.spawn(.{}, work, .{})).detach(); // expect: T1
}

fn kept() !std.Thread {
    return std.Thread.spawn(.{}, work, .{}); // expect: T1
}

fn work() void {}
