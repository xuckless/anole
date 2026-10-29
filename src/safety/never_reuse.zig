//! E1: a page allocator that never hands out an address twice, the backing
//! allocator of the test allocator (`std.heap.SafeAllocator`, which then
//! never reuses memory either). Freed pages are replaced by a fresh
//! inaccessible mapping (`mmap(MAP_FIXED, PROT_NONE)`: one call that gives
//! the pages back to the kernel and leaves the addresses reserved), so a
//! use after free faults at once instead of reading whatever reused the
//! memory, the way it did only under CI load.
//!
//! One large range of address space is reserved up front (inaccessible,
//! nothing committed) and handed out upwards. Linux and macOS; elsewhere
//! (Windows: `VirtualAlloc(MEM_RESERVE)` + `VirtualFree(MEM_DECOMMIT)`
//! would do it, TODO), and when the range is used up, this is
//! `std.heap.page_allocator`.
const std = @import("std");
const builtin = @import("builtin");
const Alignment = std.mem.Alignment;

const supported = (builtin.os.tag == .linux or builtin.os.tag == .macos) and builtin.link_libc;

/// The flags of the reservation and of each freed range's new mapping:
/// private, anonymous, nothing committed. Linux needs `NORESERVE` so the
/// reservation isn't charged against overcommit; Darwin's `PROT_NONE`
/// mappings commit nothing anyway.
const reserve_flags: std.c.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = builtin.os.tag == .linux };

// SAFETY: the vtable never reads its context pointer.
pub const allocator: std.mem.Allocator = if (supported) .{ .ptr = undefined, .vtable = &vtable } else std.heap.page_allocator;

const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

/// The reserved range, set on first use.
var base: usize = 0;
var limit: usize = 0;
var next: std.atomic.Value(usize) = .init(0);
var reserve_once: std.atomic.Mutex = .unlocked;
var reserved: std.atomic.Value(bool) = .init(false);

fn reserve() void {
    if (reserved.load(.acquire)) return;
    while (!reserve_once.tryLock()) std.atomic.spinLoopHint();
    defer reserve_once.unlock();
    if (reserved.load(.acquire)) return;
    // 1 TiB, then smaller where address space is limited.
    for ([_]usize{ 1 << 40, 1 << 36, 1 << 32 }) |size| {
        const r = std.posix.mmap(null, size, .{}, reserve_flags, -1, 0) catch continue;
        base = @intFromPtr(r.ptr);
        limit = base + r.len;
        next.store(base, .release);
        break;
    }
    reserved.store(true, .release);
}

fn inRange(addr: usize) bool {
    return base != 0 and addr >= base and addr < limit;
}

fn pageLen(len: usize) usize {
    return std.mem.alignForward(usize, len, std.heap.pageSize());
}

fn alloc(_: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    reserve();
    if (base == 0) return std.heap.page_allocator.rawAlloc(len, alignment, ret_addr);
    const size = pageLen(len);
    const a = @max(alignment.toByteUnits(), std.heap.pageSize());
    var cur = next.load(.monotonic);
    const start = while (true) {
        const s = std.mem.alignForward(usize, cur, a);
        if (s + size > limit) return std.heap.page_allocator.rawAlloc(len, alignment, ret_addr);
        cur = next.cmpxchgWeak(cur, s + size, .acq_rel, .monotonic) orelse break s;
    };
    // SAFETY: start is page-aligned and inside the range reserved above.
    const p: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(start);
    if (std.c.mprotect(p, size, .{ .READ = true, .WRITE = true }) != 0) return null;
    return p;
}

fn resize(_: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    if (!inRange(@intFromPtr(memory.ptr))) return std.heap.page_allocator.rawResize(memory, alignment, new_len, ret_addr);
    // In place within the pages it already has; never growing into the next
    // allocation's addresses.
    return new_len <= pageLen(memory.len);
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    if (!inRange(@intFromPtr(memory.ptr))) return std.heap.page_allocator.rawRemap(memory, alignment, new_len, ret_addr);
    return if (resize(ctx, memory, alignment, new_len, ret_addr)) memory.ptr else null;
}

fn free(_: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    if (!inRange(@intFromPtr(memory.ptr))) return std.heap.page_allocator.rawFree(memory, alignment, ret_addr);
    const size = pageLen(memory.len);
    // SAFETY: the memory came from alloc above: page-aligned, in the range.
    const p: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(memory.ptr));
    // A new inaccessible mapping over the range: the pages go back to the
    // kernel and the addresses stay reserved. It fails only past the
    // kernel's mapping limit (Linux's vm.max_map_count; freed ranges merge
    // with their neighbours, so it is live allocations that count), and
    // then loudly: memory that silently stayed readable would hide the use
    // after free this allocator is for.
    var fixed = reserve_flags;
    fixed.FIXED = true;
    if (std.c.mmap(p, size, .{}, fixed, -1, 0) == std.c.MAP_FAILED)
        std.debug.panic("never_reuse: remapping a freed range PROT_NONE failed (errno {d}); on Linux raise vm.max_map_count", .{std.c._errno().*});
}

test "never_reuse: a freed range is not handed out again" {
    if (!supported) return error.SkipZigTest;
    const a = try allocator.alloc(u8, 100);
    const first = @intFromPtr(a.ptr);
    allocator.free(a);
    const b = try allocator.alloc(u8, 100);
    defer allocator.free(b);
    try std.testing.expect(@intFromPtr(b.ptr) != first);
}

test "never_reuse: aligned allocations, resize in place" {
    if (!supported) return error.SkipZigTest;
    const a = try allocator.alignedAlloc(u8, .fromByteUnits(1 << 16), 10);
    defer allocator.free(a);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(a.ptr) % (1 << 16));
    try std.testing.expect(allocator.resize(a, 100));
}
