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
//! - `process_gpa`, `ProcessAllocator`: the checked allocator for code that
//!   can't take `std.testing.allocator` (process-wide pools, the C ABI).
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
pub const never_reuse_allocator = @import("anole_never_reuse").allocator;

/// A thread-safe allocator for memory that lives outside one test's scope,
/// where `std.testing.allocator` can't be used (process-wide pools, the C
/// ABI engine):
/// - test builds: `std.heap.SafeAllocator` over `never_reuse_allocator`, so
///   freed memory is poisoned (0x55) and never handed out again, and a use
///   after free faults at once, as with the test allocator;
/// - Debug builds: `SafeAllocator` over `std.heap.page_allocator`, which
///   reuses addresses: a dev server runs for days, and an unbounded
///   quarantine would only grow (ASan bounds its quarantine for the same
///   reason);
/// - release builds: `std.heap.smp_allocator` (`page_allocator` in a
///   single-threaded build), with nothing checked.
/// Each instance has its own canary, so memory freed through the wrong one
/// panics in Debug and test builds.
pub const ProcessAllocator = struct {
    state: State,

    const State = if (enabled) std.heap.SafeAllocator else void;

    pub fn init(canary: u32) ProcessAllocator {
        if (!enabled) return .{ .state = {} };
        const backing = if (builtin.is_test) never_reuse_allocator else std.heap.page_allocator;
        return .{ .state = .init(backing, options(canary)) };
    }

    fn options(canary: u32) std.heap.SafeAllocator.Options {
        return .{
            .canary = canary,
            .check_write_after_free = true,
            .stack_trace_frames = if (std.debug.sys_can_stack_trace) 8 else 0,
        };
    }

    pub fn allocator(self: *ProcessAllocator) std.mem.Allocator {
        if (!enabled) return if (builtin.single_threaded) std.heap.page_allocator else std.heap.smp_allocator;
        return self.state.allocator();
    }

    /// Debug and test builds: logs each allocation still live, with where it
    /// was made, frees it, and returns how many there were; the allocator
    /// starts over empty. Only when nothing else can be using it. Release
    /// builds: 0, and nothing happens.
    pub fn reset(self: *ProcessAllocator) usize {
        if (!enabled) return 0;
        const leaks = self.state.deinit();
        self.state = .init(self.state.backing, options(self.state.canary));
        return leaks;
    }
};

var process_state: ProcessAllocator = .init(0x9e0c55a1);

/// The process-wide `ProcessAllocator`, for process-wide pools whose memory
/// is never all given back at one point (no leak check).
pub const process_gpa: std.mem.Allocator = process_state.allocator();

test {
    std.testing.refAllDecls(@This());
    _ = @import("teardown.zig");
    _ = @import("owner.zig");
    _ = @import("lock.zig");
    _ = @import("child.zig");
    _ = @import("ctx.zig");
    _ = @import("anole_never_reuse");
}
