// lint-path: src/example/l2_raw_lock.zig
const std = @import("std");
const Io = std.Io;
const safety = @import("../safety/root.zig");

const Shared = struct {
    mutex: std.Io.Mutex = .init, // expect: L2
    spin: std.atomic.Mutex = .unlocked, // expect: L2
    cond: std.Io.Condition = .init, // expect: L2
    rw: Io.RwLock = .init, // expect: L2
    // SAFETY: a leaf guarding a bounded copy (L4, §6a).
    reasoned: std.atomic.Mutex = .unlocked,
    ranked: safety.Mutex(.table) = .{},
    count: std.atomic.Value(u32) = .init(0),
    event: std.Io.Event = .unset,
};

test "test code may use raw locks" {
    var m: std.Io.Mutex = .init;
    _ = &m;
}
