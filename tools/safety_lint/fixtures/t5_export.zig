// lint-path: src/example/t5_export.zig
// A file with an `export fn` is called from foreign threads: T5 applies.
const std = @import("std");

export fn example_wake(x: *anyopaque) void {
    _ = x;
}

fn wake(ev: *std.Io.Event, io: std.Io) void {
    ev.set(io); // expect: T5
}
