//! The debug-build checks behind SAFETY.md (E1). Each check compiles away
//! outside Debug and test builds: in ReleaseFast the types here are
//! zero-sized and their functions empty.
//!
//! - `Teardown`: the alive -> closing -> dead state of M5.
//! - `Owner`: the executor an object belongs to (T3).
//! - `Mutex`, `SpinLock`, `Condition`: locks that count themselves for L2
//!   (zio panics when a task suspends holding one) and check the global
//!   order of L4.
//! - `toCtx`, `fromCtx`: the callback-context casts of U3, type-checked.
//! - `never_reuse_allocator`: the backing allocator of the test allocator,
//!   which never hands out an address twice, so a use after free faults.
const std = @import("std");
const builtin = @import("builtin");

/// Whether the checks are compiled in: Debug builds and test builds.
pub const enabled = builtin.mode == .debug or builtin.is_test;

pub const Teardown = @import("teardown.zig").Teardown;
pub const Owner = @import("owner.zig").Owner;
const lock = @import("lock.zig");
pub const Rank = lock.Rank;
pub const Mutex = lock.Mutex;
pub const SpinLock = lock.SpinLock;
pub const Condition = lock.Condition;
pub const heldLocks = lock.heldLocks;
const ctx = @import("ctx.zig");
pub const toCtx = ctx.toCtx;
pub const fromCtx = ctx.fromCtx;
pub const never_reuse_allocator = @import("never_reuse.zig").allocator;

test {
    std.testing.refAllDecls(@This());
    _ = @import("teardown.zig");
    _ = @import("owner.zig");
    _ = @import("lock.zig");
    _ = @import("ctx.zig");
    _ = @import("never_reuse.zig");
}
