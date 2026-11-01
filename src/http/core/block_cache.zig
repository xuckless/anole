// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES. Anole's.

//! Memory for compressors whose state is too large for the request's arena:
//! Brotli's encoder (about 25 allocations: hash tables of up to 256 KiB,
//! buffers sized to the body, 100 KiB for 8 KiB, small ones), and the
//! per-executor buffered-body encoders (`encoders`: zlib-ng's deflate state,
//! one block of 140 KiB and more, zstd's context, libdeflate's compressor
//! and its scratch). An arena would keep that much for as long as it is
//! reused (an HTTP/1.1 connection keeps its arena's capacity), or give it
//! back and map it again on the next response (HTTP/2 and HTTP/3 keep up
//! about 8 KiB of a stream's arena). Fresh from malloc it would be
//! mapped and unmapped for every response too: musl's malloc maps anything
//! past its largest size class (`malloc_max`), glibc's past its threshold
//! until that adapts, and each page then faults in again.
//!
//! So allocations past what malloc serves from its slabs (`malloc_max`)
//! come from a per-thread cache of blocks in a few size classes (64, 128
//! and 256 KiB, 1 and 2 MiB), one free list each, which keeps their pages
//! mapped from one response to the next: under zio a thread is an executor,
//! and a buffered body is compressed without yielding, so one set of blocks
//! serves every buffered response an executor compresses. Smaller
//! allocations go to malloc, which serves them from its heap; larger ones
//! are mapped and unmapped each time. The cache holds at most `max_cached`
//! bytes, a class at most `classMax`, and `trimLocal` (the server's trim
//! task, on each executor) unmaps the blocks of each class that nothing
//! took since the last trim, past `trim_keep`.
//!
//! Callers that know their size (the HTTP/2 engine's request body queues)
//! use `take` and `give`, which hand out a class's block as it is, with no
//! header in front: a 64 KiB queue is a 64 KiB block. `alloc` and `free`
//! (malloc's contract, for the compressors) need a 16-byte header in front
//! of what they hand out, and the compressors' large allocations are powers
//! of two (Brotli's two 256 KiB hash tables at quality 5): a header inside
//! the class would push each into the next class up. So every block is
//! mapped one page longer than its class, and `alloc` puts its header at
//! the end of that first page and hands out the class from the page after
//! it; `take` hands out the class from the block's start, and the last page
//! stays untouched (never faulted in).
//!
//! A block given back on a thread that never trims (a blocking-pool thread)
//! stays in that thread's cache, which the same bounds cap. The classes
//! follow goose-http's per-ring record classes (MIT,
//! github.com/kaitk/goose-http 6b566a7, shim/uring.c); no code is copied.
const std = @import("std");

/// The block sizes the cache holds, smallest first.
pub const classes = [_]usize{ 64 * 1024, 128 * 1024, 256 * 1024, 1024 * 1024, 2 * 1024 * 1024 };
/// The largest allocation (header included) `alloc` leaves to malloc:
/// Zig's malloc (SmpAllocator, musl's and glibc's replacement in Zig
/// builds) serves up to 32 KiB, its own 16-byte header included, from its
/// slabs and maps anything larger; the rest is headroom for other mallocs'
/// headers.
pub const malloc_max = 32 * 1024 - 64;
/// Most bytes one thread's cache holds; blocks given back past it are
/// unmapped. Reached only right after that much was in use at once on the
/// executor, and trimmed within two trim intervals.
pub const max_cached = 8 * 1024 * 1024;
/// Most bytes a class holds, so one size cannot crowd out the others: the
/// 64 KiB class (an HTTP/2 body of unknown length, one per stream) holds a
/// burst of 128 streams, a connection's most spare streams; the others 2
/// MiB each.
pub fn classMax(index: usize) usize {
    return if (index == 0) 128 * classes[0] else 2 * 1024 * 1024;
}
/// Blocks of each class up to 256 KiB a trim keeps however long they sat
/// unused: one buffered encoder's large blocks (Brotli's two hash tables).
/// The 1 and 2 MiB classes (raised HTTP/2 body windows) keep none.
pub const trim_keep = 2;

fn keepOf(index: usize) usize {
    return if (classes[index] <= 256 * 1024) trim_keep else 0;
}

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
};

const List = struct {
    first: ?*Free = null,
    count: usize = 0,
    /// The fewest blocks held since the last trim: that many sat
    /// unused all the while.
    low: usize = 0,
};

const Cache = struct {
    lists: [classes.len]List = @splat(.{}),
    bytes: usize = 0,
};

threadlocal var cache: Cache = .{};

const page_allocator = std.heap.page_allocator;
const page_align: std.mem.Alignment = .fromByteUnits(std.heap.page_size_min);

/// What a block of `class` bytes maps: one page more (see the top).
fn mapLen(class: usize) usize {
    return class + std.heap.pageSize();
}

fn unmap(start: [*]align(16) u8, class: usize) void {
    page_allocator.rawFree(start[0..mapLen(class)], page_align, @returnAddress());
}

/// The index of the smallest class that holds `size` bytes, or null past
/// the largest.
pub fn classIndex(size: usize) ?usize {
    inline for (classes, 0..) |class, i| {
        if (size <= class) return i;
    }
    return null;
}

/// The smallest class that holds `size` bytes, or null past the largest.
pub fn classFor(size: usize) ?usize {
    return classes[classIndex(size) orelse return null];
}

fn exactIndex(len: usize) ?usize {
    const i = classIndex(len) orelse return null;
    return if (classes[i] == len) i else null;
}

/// A block of exactly `class_size` bytes (one of `classes`), from the
/// calling thread's cache or freshly mapped; null when out of memory.
/// Give it back with `give`.
pub fn take(class_size: usize) ?[]align(16) u8 {
    const i = exactIndex(class_size) orelse unreachable; // not a class
    const list = &cache.lists[i];
    if (list.first) |f| {
        list.first = f.next;
        list.count -= 1;
        list.low = @min(list.low, list.count);
        cache.bytes -= class_size;
        // SAFETY: a free block starts with its `Free` header (`give`).
        const block: [*]align(16) u8 = @ptrCast(f);
        return block[0..class_size];
    }
    const fresh = page_allocator.rawAlloc(mapLen(class_size), page_align, @returnAddress()) orelse return null;
    // SAFETY: mapped at page alignment, past 16.
    return @alignCast(fresh[0..class_size]);
}

/// Gives back a block from `take` (its whole length), to the calling
/// thread's cache, or unmaps it past the bounds.
pub fn give(block: []u8) void {
    const i = exactIndex(block.len) orelse unreachable; // not from `take`
    const list = &cache.lists[i];
    if (cache.bytes + block.len > max_cached or (list.count + 1) * block.len > classMax(i)) {
        // SAFETY: from `take`, a page-aligned mapping.
        unmap(@alignCast(block.ptr), block.len);
        return;
    }
    const f: *Free = @ptrCast(@alignCast(block.ptr));
    f.* = .{ .next = list.first };
    list.first = f;
    list.count += 1;
    cache.bytes += block.len;
}

/// malloc's contract: 16-byte aligned, null when out of memory.
pub fn alloc(size: usize) ?*anyopaque {
    const total = std.math.add(usize, size, header_len) catch return null;
    if (total <= malloc_max) {
        const raw: [*]align(16) u8 = @ptrCast(@alignCast(std.c.malloc(total) orelse return null));
        @as(*Header, @ptrCast(raw)).* = .{ .len = total, .tag = small_tag };
        return raw + header_len;
    }
    // The class holds `size` itself: the header goes in the page in front.
    const page = std.heap.pageSize();
    const start: [*]align(16) u8, const len = if (classFor(size)) |class|
        .{ (take(class) orelse return null).ptr, class }
    else blk: {
        // Past the largest class: mapped for this allocation alone, its
        // length (never a class's) in the header.
        const need = std.mem.alignForward(usize, size, page);
        const fresh = page_allocator.rawAlloc(mapLen(need), page_align, @returnAddress()) orelse return null;
        // SAFETY: mapped at page alignment, past 16.
        break :blk .{ @alignCast(fresh), need };
    };
    // SAFETY: a page past a page-aligned mapping.
    const p: [*]align(16) u8 = @alignCast(start + page);
    @as(*Header, @ptrCast(p - header_len)).* = .{ .len = len, .tag = big_tag };
    return p;
}

pub fn free(address: ?*anyopaque) void {
    const p: [*]align(16) u8 = @ptrCast(@alignCast(address orelse return));
    const raw = p - header_len;
    const h: *Header = @ptrCast(raw);
    switch (h.tag) {
        small_tag => std.c.free(raw),
        big_tag => {
            // SAFETY: `alloc` handed out the page after the mapping's first.
            const start: [*]align(16) u8 = @alignCast(p - std.heap.pageSize());
            if (exactIndex(h.len) != null) give(start[0..h.len]) else unmap(start, h.len);
        },
        else => unreachable, // not ours
    }
}

/// Unmaps, in each class, the calling thread's cached blocks that nothing
/// took since the last call, past `trim_keep`: those given back longest
/// ago.
pub fn trimLocal() void {
    for (&cache.lists, 0..) |*list, i| {
        const n = list.low -| keepOf(i);
        defer list.low = list.count;
        if (n == 0) continue;
        var keep = list.count - n;
        var tail: ?*Free = list.first;
        if (keep == 0) {
            list.first = null;
        } else {
            var last = list.first.?;
            while (keep > 1) : (keep -= 1) last = last.next.?;
            tail = last.next;
            last.next = null;
        }
        while (tail) |f| {
            tail = f.next;
            list.count -= 1;
            cache.bytes -= classes[i];
            unmap(@ptrCast(f), classes[i]);
        }
    }
}

/// Blocks the calling thread's cache holds of the class at `index`.
pub fn cachedIn(index: usize) usize {
    return cache.lists[index].count;
}

/// Blocks and bytes the calling thread's cache holds.
pub fn cached() struct { count: usize, bytes: usize } {
    var count: usize = 0;
    for (cache.lists) |list| count += list.count;
    return .{ .count = count, .bytes = cache.bytes };
}

/// Tests only: unmaps every block the calling thread's cache holds, so a
/// test starts from an empty cache whatever ran before it on the thread.
pub fn drainLocalForTest() void {
    if (!@import("builtin").is_test) @compileError("drainLocalForTest is for tests");
    for (&cache.lists, 0..) |*list, i| {
        while (list.first) |f| {
            list.first = f.next;
            unmap(@ptrCast(f), classes[i]);
        }
    }
    cache = .{};
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
    // Other tests on this thread may have left blocks (up to `max_cached`).
    drainLocalForTest();
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

test "block_cache: each class keeps its own blocks, and take hands out a class whole" {
    drainLocalForTest();
    defer drainLocalForTest();
    // `take` gives exactly the class, with no header in front.
    const a = take(64 * 1024).?;
    try std.testing.expectEqual(@as(usize, 64 * 1024), a.len);
    @memset(a, 0x11);
    give(a);
    try std.testing.expectEqual(@as(usize, 1), cachedIn(0));
    const b = take(64 * 1024).?;
    try std.testing.expectEqual(a.ptr, b.ptr);
    try std.testing.expectEqual(@as(usize, 0), cachedIn(0));
    // A block of another class is not taken for it.
    const big = take(256 * 1024).?;
    give(big);
    const c = take(128 * 1024).?;
    try std.testing.expect(c.ptr != big.ptr);
    try std.testing.expectEqual(@as(usize, 1), cachedIn(2));
    give(c);
    give(b);

    // 40 KiB is past malloc's slabs: `alloc` serves it from the 64 KiB
    // class, the block `b` just went back as, a page in.
    const mid = alloc(40 * 1024).?;
    try std.testing.expectEqual(@intFromPtr(b.ptr) + std.heap.pageSize(), @intFromPtr(mid));
    free(mid);
    try std.testing.expectEqual(@as(usize, 1), cachedIn(0));
    // Under `malloc_max` it is malloc's.
    const small = alloc(16 * 1024).?;
    free(small);
    try std.testing.expectEqual(@as(usize, 1), cachedIn(0));
    // Past the largest class: mapped and unmapped, never cached.
    const before = cached();
    const huge = alloc(3 * 1024 * 1024).?;
    free(huge);
    try std.testing.expectEqual(before.count, cached().count);
}

test "block_cache: a class holds at most classMax, the cache max_cached" {
    drainLocalForTest();
    defer drainLocalForTest();
    var blocks: [40][]align(16) u8 = undefined;
    for (&blocks) |*b| b.* = take(64 * 1024).?;
    for (blocks) |b| give(b);
    try std.testing.expectEqual(@as(usize, 40), cachedIn(0));
    // A class stops at its cap.
    var bigs: [3][]align(16) u8 = undefined;
    for (&bigs) |*b| b.* = take(1024 * 1024).?;
    for (bigs) |b| give(b);
    try std.testing.expectEqual(classMax(3) / (1024 * 1024), cachedIn(3));
    // A 2 MiB block still fits the total (2.5 + 2 + 2 MiB); the next one
    // stops at the class cap, and a 256 KiB block past 8 MiB at the total.
    const twos: [2][]align(16) u8 = .{ take(2 * 1024 * 1024).?, take(2 * 1024 * 1024).? };
    for (twos) |b| give(b);
    try std.testing.expectEqual(@as(usize, 1), cachedIn(4));
    var quarters: [8][]align(16) u8 = undefined;
    for (&quarters) |*b| b.* = take(256 * 1024).?;
    for (quarters) |b| give(b);
    try std.testing.expectEqual(@as(usize, 6), cachedIn(2));
    try std.testing.expectEqual(max_cached, cached().bytes);
}

test "block_cache: a burst of 128 bodies of 64 KiB comes back to the cache whole" {
    drainLocalForTest();
    defer drainLocalForTest();
    var blocks: [129][]align(16) u8 = undefined;
    for (&blocks) |*b| b.* = take(64 * 1024).?;
    for (blocks) |b| give(b);
    try std.testing.expectEqual(@as(usize, 128), cachedIn(0));
}

test "block_cache: alloc picks the class by the caller's size, so a power of two fits its class" {
    drainLocalForTest();
    defer drainLocalForTest();
    // Brotli's hash tables at quality 5 are 256 KiB each.
    const a = alloc(256 * 1024).?;
    const b = alloc(256 * 1024).?;
    @memset(@as([*]u8, @ptrCast(a))[0 .. 256 * 1024], 0x5a);
    @memset(@as([*]u8, @ptrCast(b))[0 .. 256 * 1024], 0xa5);
    free(a);
    free(b);
    try std.testing.expectEqual(@as(usize, 2), cachedIn(2));
    try std.testing.expectEqual(@as(usize, 0), cachedIn(3));
    // 64 KiB exactly is the 64 KiB class.
    const c = alloc(64 * 1024).?;
    free(c);
    try std.testing.expectEqual(@as(usize, 1), cachedIn(0));
    // The blocks `alloc` used serve `take` as well.
    const t = take(256 * 1024).?;
    give(t);
    try std.testing.expectEqual(@as(usize, 2), cachedIn(2));
}

test "block_cache: a trim unmaps per class what sat unused, past trim_keep" {
    drainLocalForTest();
    defer drainLocalForTest();
    var small: [5][]align(16) u8 = undefined;
    for (&small) |*b| b.* = take(64 * 1024).?;
    for (small) |b| give(b);
    give(take(1024 * 1024).?);
    trimLocal(); // ends the interval in which they were taken
    // One 64 KiB block taken and given back in the next interval: four
    // sat unused all along, of which `trim_keep` stay. The 1 MiB class
    // keeps none.
    give(take(64 * 1024).?);
    trimLocal();
    try std.testing.expectEqual(@as(usize, 1 + trim_keep), cachedIn(0));
    try std.testing.expectEqual(@as(usize, 0), cachedIn(3));
}
