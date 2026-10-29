// lint-path: src/example/t1_spawn.zig
const std = @import("std");
const placement = @import("placement.zig");

const Owner = struct {
    group: std.Io.Group,
    future: ?std.Io.Future(void),

    fn start(self: *Owner, io: std.Io) !void {
        try placement.concurrent(io, &self.group, .local, work, .{});
        self.group.concurrent(io, work, .{}); // expect: T1
        self.future = try io.concurrent(work, .{}); // expect: T1
    }
};

fn awaited(io: std.Io) !void {
    var f = try io.concurrent(work, .{});
    f.await(io);
}

fn canceled(io: std.Io) !void {
    const f = io.async(work, .{});
    defer f.cancel(io);
}

fn leaked(io: std.Io) !void {
    const f = try io.concurrent(work, .{}); // expect: T1
    _ = f;
}

fn localGroup(io: std.Io) !void {
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, work, .{});
}

fn bare(io: std.Io) !void {
    _ = try io.concurrent(work, .{}); // expect: T1
}

fn zio(rt: anytype) void {
    rt.spawnInto(work, .{}); // expect: T1
}

fn work() void {}
