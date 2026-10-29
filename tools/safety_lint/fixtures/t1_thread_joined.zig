// lint-path: src/example/t1_thread_joined.zig
const std = @import("std");

const Owner = struct {
    thread: ?std.Thread = null,

    fn start(o: *Owner) !void {
        o.thread = try std.Thread.spawn(.{}, work, .{});
    }

    fn deinit(o: *Owner) void {
        if (o.thread) |t| t.join();
    }
};

fn work() void {}
