//! The two pieces of the old src/safety every module may need and that
//! depend on std alone: `allocUninit` and a spin lock. A module of their
//! own (`anole_mem`), so the HTTP core and anole share one copy.
const std = @import("std");

/// For a buffer every byte of which is written before it is read (a
/// socket read, a copy): skips std's `undefined` fill, 0xAA over the
/// whole allocation in ReleaseSafe (Allocator.zig `allocBytesAligned`).
/// Freed as usual (`free`, an arena's reset).
pub fn allocUninit(a: std.mem.Allocator, n: usize) error{OutOfMemory}![]u8 {
    if (n == 0) return &.{};
    const p = a.rawAlloc(n, .@"1", @returnAddress()) orelse return error.OutOfMemory;
    return p[0..n];
}

/// A lock whose waiters spin (`std.atomic.Mutex`), for short bounded
/// sections that never allocate, wait or call blocking code.
pub const SpinLock = struct {
    inner: std.atomic.Mutex = .unlocked,

    pub const init: SpinLock = .{};

    pub fn lock(self: *SpinLock) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn tryLock(self: *SpinLock) bool {
        return self.inner.tryLock();
    }

    pub fn unlock(self: *SpinLock) void {
        self.inner.unlock();
    }
};

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

test "allocUninit: no fill of its own, where alloc fills with undefined" {
    const a = FillingAllocator.allocator();
    const bytes = try allocUninit(a, 64);
    defer a.free(bytes);
    try std.testing.expectEqual(64, bytes.len);
    for (bytes) |b| try std.testing.expectEqual(FillingAllocator.fill, b);

    // `alloc` over the same allocator fills with `undefined` (0xAA) in the
    // safe modes: the difference is the helper's.
    const filled = try a.alloc(u8, 64);
    defer a.free(filled);
    if (@import("builtin").mode == .debug or @import("builtin").mode == .safe) {
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

test "SpinLock: tryLock is true when free, false when held, true after unlock" {
    var l: SpinLock = .init;
    try std.testing.expect(l.tryLock());
    try std.testing.expect(!l.tryLock());
    l.unlock();
    try std.testing.expect(l.tryLock());
    l.unlock();
    l.lock();
    l.unlock();
}

test "SpinLock: four threads incrementing one counter lose none" {
    const n = 20_000;
    const Shared = struct {
        lock: SpinLock = .init,
        count: u64 = 0,
        fn run(s: *@This()) void {
            for (0..n) |_| {
                s.lock.lock();
                defer s.lock.unlock();
                s.count += 1;
            }
        }
    };
    var s: Shared = .{};
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Shared.run, .{&s});
    for (threads) |t| t.join();
    try std.testing.expectEqual(4 * n, s.count);
}
