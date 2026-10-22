// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES. Anole's.

//! Memory for compressors whose state is too large for the request's arena:
//! Brotli's encoder (about 25 allocations: two hash tables of 256 KiB at
//! quality 5, buffers sized to the body, 100 KiB for 8 KiB, small ones) and
//! zlib-ng's deflate state for a buffered gzip body (one block of 140 KiB
//! and more). An arena would keep that much for as long as it is reused (an
//! HTTP/1.1 connection keeps its arena's capacity), or give it back and map
//! it again on the next response (HTTP/2 and HTTP/3 keep up to 128 KiB and
//! 8 KiB of a stream's arena). Fresh from malloc it would be mapped and
//! unmapped for every response too: musl's malloc maps anything past 128
//! KiB, glibc's until its threshold adapts, and each page then faults in
//! again.
//!
//! So allocations of `big_min` and more come from a per-thread cache of
//! blocks, best fit, which keeps their pages mapped from one response to
//! the next: under zio a thread is an executor, and a buffered body is
//! compressed without yielding, so one set of blocks serves every buffered
//! response an executor compresses. Smaller allocations go to malloc, which
//! serves them from its heap. The cache holds at most `max_cached` bytes,
//! and `trimLocal` (the server's trim task, on each executor) unmaps the
//! blocks it kept that nothing took since the last trim, past `trim_keep`.
const std = @import("std");

/// Smallest allocation served from the cache.
pub const big_min = 64 * 1024;
/// Most bytes one thread's cache holds; blocks given back past it are
/// unmapped.
pub const max_cached = 4 * 1024 * 1024;
/// Blocks a trim keeps however long they sat unused: one buffered
/// encoder's large blocks.
pub const trim_keep = 3;

/// In front of every allocation, keeping malloc's 16-byte alignment.
const Header = extern struct {
    /// The block's length (big), or the allocation's (small).
    len: usize,
    tag: usize,
};
const header_len = @sizeOf(Header);
const small_tag: usize = 0x62726f746c690001;
const big_tag: usize = 0x62726f746c690002;

/// A block in the cache, at its start.
const Free = extern struct {
    next: ?*Free align(16),
    len: usize,
};

const Cache = struct {
    first: ?*Free = null,
    count: usize = 0,
    bytes: usize = 0,
    /// The fewest blocks held since the last trim: that many sat
    /// unused all the while.
    low: usize = 0,
};

threadlocal var cache: Cache = .{};

const page_allocator = std.heap.page_allocator;

/// malloc's contract: 16-byte aligned, null when out of memory.
pub fn alloc(size: usize) ?*anyopaque {
    const total = std.math.add(usize, size, header_len) catch return null;
    if (total < big_min) {
        const raw: [*]align(16) u8 = @ptrCast(@alignCast(std.c.malloc(total) orelse return null));
        @as(*Header, @ptrCast(raw)).* = .{ .len = total, .tag = small_tag };
        return raw + header_len;
    }
    const need = std.mem.alignForward(usize, total, std.heap.pageSize());
    // A block from the cache may be larger than asked for.
    const block: []align(16) u8 = take(need) orelse blk: {
        const fresh = page_allocator.rawAlloc(need, .fromByteUnits(std.heap.pageSize()), @returnAddress()) orelse return null;
        break :blk @alignCast(fresh[0..need]);
    };
    @as(*Header, @ptrCast(block.ptr)).* = .{ .len = block.len, .tag = big_tag };
    return block.ptr + header_len;
}

pub fn free(address: ?*anyopaque) void {
    const p: [*]align(16) u8 = @ptrCast(@alignCast(address orelse return));
    const raw = p - header_len;
    const h: *Header = @ptrCast(raw);
    switch (h.tag) {
        small_tag => std.c.free(raw),
        big_tag => give(raw, h.len),
        else => unreachable, // not ours
    }
}

/// The smallest cached block of at least `need` bytes and at most twice
/// that.
fn take(need: usize) ?[]align(16) u8 {
    var best: ?*Free = null;
    var best_prev: ?*Free = null;
    var prev: ?*Free = null;
    var it = cache.first;
    while (it) |f| : (it = f.next) {
        if (f.len >= need and f.len <= 2 * need and (best == null or f.len < best.?.len)) {
            best = f;
            best_prev = prev;
        }
        prev = f;
    }
    const f = best orelse return null;
    if (best_prev) |bp| bp.next = f.next else cache.first = f.next;
    cache.count -= 1;
    cache.bytes -= f.len;
    cache.low = @min(cache.low, cache.count);
    const block: [*]align(16) u8 = @ptrCast(f);
    return block[0..f.len];
}

fn give(block: [*]align(16) u8, len: usize) void {
    if (cache.bytes + len > max_cached) {
        page_allocator.rawFree(block[0..len], .fromByteUnits(std.heap.pageSize()), @returnAddress());
        return;
    }
    const f: *Free = @ptrCast(block);
    f.* = .{ .next = cache.first, .len = len };
    cache.first = f;
    cache.count += 1;
    cache.bytes += len;
}

/// Unmaps the calling thread's cached blocks that no encoder took since
/// the last call, past `trim_keep`: those given back longest ago.
pub fn trimLocal() void {
    const n = cache.low -| trim_keep;
    defer cache.low = cache.count;
    if (n == 0) return;
    var keep = cache.count - n;
    var tail: ?*Free = cache.first;
    if (keep == 0) {
        cache.first = null;
    } else {
        var last = cache.first.?;
        while (keep > 1) : (keep -= 1) last = last.next.?;
        tail = last.next;
        last.next = null;
    }
    while (tail) |f| {
        tail = f.next;
        cache.count -= 1;
        cache.bytes -= f.len;
        const block: [*]align(16) u8 = @ptrCast(f);
        page_allocator.rawFree(block[0..f.len], .fromByteUnits(std.heap.pageSize()), @returnAddress());
    }
}

/// Blocks and bytes the calling thread's cache holds.
pub fn cached() struct { count: usize, bytes: usize } {
    return .{ .count = cache.count, .bytes = cache.bytes };
}

/// `alloc` and `free` as a `std.mem.Allocator`, for alignments up to 16.
pub const allocator: std.mem.Allocator = .{ .ptr = undefined, .vtable = &.{
    .alloc = vtableAlloc,
    .resize = std.mem.Allocator.noResize,
    .remap = std.mem.Allocator.noRemap,
    .free = vtableFree,
} };

fn vtableAlloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    if (alignment.toByteUnits() > 16) return null;
    return @ptrCast(alloc(len) orelse return null);
}

fn vtableFree(_: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
    free(memory.ptr);
}

test "block_cache: large blocks are kept and reused, small ones are malloc's" {
    trimLocal();
    trimLocal();
    const before = cached();
    const small = try allocator.alloc(u8, 100);
    allocator.free(small);
    try std.testing.expectEqual(before.count, cached().count);

    const big = try allocator.alignedAlloc(u8, .@"16", 300 * 1024);
    @memset(big, 0xaa);
    allocator.free(big);
    try std.testing.expectEqual(before.count + 1, cached().count);
    // The next allocation of about that size takes the same block.
    const again = try allocator.alignedAlloc(u8, .@"16", 290 * 1024);
    try std.testing.expectEqual(big.ptr, again.ptr);
    try std.testing.expectEqual(before.count, cached().count);
    allocator.free(again);
    // One twice as small does not.
    const half = try allocator.alloc(u8, 100 * 1024);
    try std.testing.expect(half.ptr != big.ptr);
    allocator.free(half);
}
