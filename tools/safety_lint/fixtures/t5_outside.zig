// lint-path: src/example/t5_outside.zig
// No C ABI and no `export fn`: runtime wakes are not T5's business.
const std = @import("std");

fn wake(ev: *std.Io.Event, io: std.Io) void {
    ev.set(io);
}
