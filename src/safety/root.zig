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

/// For a buffer every byte of which is written before it is read (a
/// socket read, a copy): skips std's `undefined` fill, 0xAA over the
/// whole allocation in ReleaseSafe (Allocator.zig `allocBytesAligned`).
/// Poisoned instead in Debug and test builds (M6), so a read of a byte
/// never written still shows. Freed as usual (`free`, an arena's reset).
pub fn allocUninit(a: std.mem.Allocator, n: usize) error{OutOfMemory}![]u8 {
    if (n == 0) return &.{};
    const p = a.rawAlloc(n, .@"1", @returnAddress()) orelse return error.OutOfMemory;
    poison(p[0..n]);
    return p[0..n];
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

/// `std.testing.allocator`, but what `alloc` returns is filled with
/// `fill`, so a test can tell which bytes a caller wrote.
const FillingAllocator = struct {
    const fill: u8 = 0x5C;

    fn allocator() std.mem.Allocator {
        return .{ .ptr = undefined, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const p = std.testing.allocator.rawAlloc(len, alignment, ret) orelse return null;
        @memset(p[0..len], fill);
        return p;
    }

    fn resize(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) bool {
        return std.testing.allocator.rawResize(memory, alignment, new_len, ret);
    }

    fn remap(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) ?[*]u8 {
        return std.testing.allocator.rawRemap(memory, alignment, new_len, ret);
    }

    fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        std.testing.allocator.rawFree(memory, alignment, ret);
    }
};

test "allocUninit: no undefined fill, poisoned in Debug and test builds" {
    const a = FillingAllocator.allocator();
    const bytes = try allocUninit(a, 64);
    defer a.free(bytes);
    try std.testing.expectEqual(64, bytes.len);
    const want: u8 = if (enabled) poison_byte else FillingAllocator.fill;
    for (bytes) |b| try std.testing.expectEqual(want, b);

    // `alloc` over the same allocator fills with `undefined` (0xAA) in the
    // safe modes: the difference is the helper's. Test builds always have
    // `enabled`, so the ReleaseSafe branch (no store at all) is read from
    // the code and the flame graph, not tested.
    const filled = try a.alloc(u8, 64);
    defer a.free(filled);
    if (builtin.mode == .debug or builtin.mode == .safe) {
        for (filled) |b| try std.testing.expectEqual(0xAA, b);
    }
}

test "allocUninit: zero bytes, out of memory, and an arena's rollback" {
    const empty = try allocUninit(std.testing.allocator, 0);
    try std.testing.expectEqual(0, empty.len);
    std.testing.allocator.free(empty);

    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, allocUninit(failing.allocator(), 16));

    // Alignment 1, as `free` of a `[]u8` passes: freeing the last slice
    // rolls the arena back, so the next one starts at the same place.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const first = try allocUninit(arena.allocator(), 1000);
    const capacity = arena.queryCapacity();
    arena.allocator().free(first);
    const second = try allocUninit(arena.allocator(), 1000);
    try std.testing.expectEqual(first.ptr, second.ptr);
    try std.testing.expectEqual(capacity, arena.queryCapacity());
}

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
