// lint-path: src/safety/lock.zig
// The ranked wrappers are built on the raw locks.
const std = @import("std");

pub const Mutex = struct {
    inner: std.Io.Mutex = .init,
};
pub const SpinLock = struct {
    inner: std.atomic.Mutex = .unlocked,
};
