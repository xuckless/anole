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
//! - `poison`, `resetArena`: pool memory taken back and request arenas
//!   reset are poisoned (M6), so memory kept past its owner reads 0xDD or
//!   faults.
//! - `IoLock`: L2's exception, a lock held across I/O (rank `io`).
//! - `SpinCheckedAllocator`: an allocator that panics when the calling
//!   thread holds a `SpinLock` (L5).
//! - `IoGate`: T5's one way to wake runtime tasks from a thread that may
//!   outlive the runtime (moved from the C ABI's engine).
//! - `readSectionEntered`, `readSectionLeft`: the debug side of a QSBR
//!   read section (src/http/core/qsbr.zig, M3).
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
pub const IoLock = lock.IoLock;
pub const heldLocks = lock.heldLocks;
pub const readSectionEntered = lock.readSectionEntered;
pub const readSectionLeft = lock.readSectionLeft;
pub const checkAllocation = lock.checkAllocation;
pub const notePanic = lock.notePanic;
pub const SpinCheckedAllocator = @import("alloc_check.zig").SpinCheckedAllocator;
pub const IoGate = @import("io_gate.zig").IoGate;
/// Tests: runs inside every `IoGate` once it is entered, before the wake
/// (test builds only; a test sets it and clears it after).
pub var io_gate_test_hook: ?*const fn () void = null;
/// Tests whose claim is a panic: they run their own binary again (see
/// child.zig). Test binaries built with src/safety/test_runner.zig only.
pub const child = @import("child.zig");
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
        if (!process_spin_check) return self.state.allocator();
        return .{ .ptr = self, .vtable = &checked_vtable };
    }

    /// The `SafeAllocator`'s calls behind `checkAllocation` (L5), as
    /// `SpinCheckedAllocator` does, without a second object.
    const checked_vtable: std.mem.Allocator.VTable = .{ .alloc = checkedAlloc, .resize = checkedResize, .remap = checkedRemap, .free = checkedFree };

    fn ofPtr(p: *anyopaque) *ProcessAllocator {
        // SAFETY: `allocator()` sets the context to a *ProcessAllocator.
        return @ptrCast(@alignCast(p));
    }

    fn checkedAlloc(self_ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        lock.checkAllocation(ra);
        return ofPtr(self_ptr).state.allocator().rawAlloc(len, alignment, ra);
    }

    fn checkedResize(self_ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        lock.checkAllocation(ra);
        return ofPtr(self_ptr).state.allocator().rawResize(memory, alignment, new_len, ra);
    }

    fn checkedRemap(self_ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        lock.checkAllocation(ra);
        return ofPtr(self_ptr).state.allocator().rawRemap(memory, alignment, new_len, ra);
    }

    fn checkedFree(self_ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        lock.checkAllocation(ra);
        ofPtr(self_ptr).state.allocator().rawFree(memory, alignment, ra);
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

/// Whether `ProcessAllocator` (`process_gpa`, the C ABI engine's
/// allocator) checks for allocations under a spin lock (L5) in Debug and
/// test builds. Off until the S1.5 retrofit's step 6 fixes the one known
/// site: the C ABI's `Pipe` grows its chunk list in `push` and frees a
/// used chunk in `read` under its lock (src/capi/pipe.zig, lock taken at
/// `Pipe.acquire`; research/s15/lock-inventory.md F3, #75). With it on,
/// every C ABI test that streams a body panics there. Step 6 turns it on
/// with its failing-first test.
const process_spin_check = false;

var process_state: ProcessAllocator = .init(0x9e0c55a1);

/// The process-wide `ProcessAllocator`, for process-wide pools whose memory
/// is never all given back at one point (no leak check).
pub const process_gpa: std.mem.Allocator = process_state.allocator();

/// The byte freed pool memory is filled with (MSVC's "dead memory" byte):
/// distinct from SafeAllocator's 0x55 and Zig's `undefined` 0xAA, so a crash
/// says which mechanism freed it.
pub const poison_byte: u8 = 0xDD;

/// SAFETY.md M6: fills memory a pool takes back with `poison_byte`, so a
/// pointer kept past its owner reads 0xDD rather than the old contents.
/// Nothing outside Debug and test builds.
pub inline fn poison(bytes: []u8) void {
    if (enabled) @memset(bytes, poison_byte);
}

/// SAFETY.md M4/M6: resets a request or batch arena. In Debug and test
/// builds every chunk goes back to the arena's child allocator
/// (`.free_all`), which poisons it or makes it inaccessible, so a slice
/// kept past its request reads poison or faults; otherwise `mode` as
/// given (the retained capacity is the point of it in production).
pub inline fn resetArena(arena: *std.heap.ArenaAllocator, mode: std.heap.ArenaAllocator.ResetMode) bool {
    const free_all = enabled and (!builtin.is_test or arena_poisoning.load(.monotonic));
    return arena.reset(if (free_all) .free_all else mode);
}

/// Test builds: whether `resetArena` frees the arena (on by default). A
/// test whose claim is the release behaviour, such as a warm path that
/// allocates nothing, turns it off for its run and back on after: freeing
/// is an allocation per request there. Debug builds always free; release
/// builds never look at it.
pub var arena_poisoning: std.atomic.Value(bool) = .init(true);

test {
    std.testing.refAllDecls(@This());
    _ = @import("teardown.zig");
    _ = @import("owner.zig");
    _ = @import("lock.zig");
    _ = @import("child.zig");
    _ = @import("alloc_check.zig");
    _ = @import("io_gate.zig");
    _ = @import("ctx.zig");
    _ = @import("anole_never_reuse");
}
