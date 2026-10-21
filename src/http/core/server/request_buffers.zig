// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

//! The memory requests are served with -- the buffer a head is read into
//! and the arena everything else comes from -- in sets that requests hand
//! on to the next. Under zio each executor keeps the sets given back on it
//! and takes from them first, with no lock: a connection stays on its
//! executor, so the set it gives back is the one it takes for its next
//! request. Elsewhere the free sets are sharded, so that connections
//! opening and closing at once mostly take different locks.
//!
//! A free list keeps what a burst left it only for a while: `trimLocal`
//! and `trimShards`, run on a timer, free the sets that no request took
//! from it since the last trim, past a few kept for the next arrivals. So the sets a burst of
//! connections needed at once go back once the burst is over, not when
//! the server stops.

const std = @import("std");
const builtin = @import("builtin");
const placement = @import("../placement.zig");

/// A request's read and write buffers and arena, in one allocation with
/// this header.
pub const RequestBuffers = struct {
    arena: std.heap.ArenaAllocator,
    read_buffer: []u8,
    write_buffer: []u8,
    node: std.SinglyLinkedList.Node = .{},
    /// The shard it was taken from, and goes back to.
    shard: u8 = 0,
};

pub const RequestBuffersPool = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    read_buffer_len: usize,
    write_buffer_len: usize,
    /// Primed into each arena, so an ordinary request is served without
    /// growing it.
    arena_reserve: usize,
    shards: [shard_count]Shard = @splat(.{}),
    /// One free list per executor, by index (zio has at most 64). Only the
    /// executor's own thread touches its list, and nothing between taking
    /// a set off and putting one on can suspend, so it needs no lock.
    locals: [max_executors]Local = @splat(.{}),

    const shard_count = 16;
    const max_executors = 64;
    /// `RequestBuffers.shard` for a set from an executor's list.
    const local_shard = shard_count;

    /// Sets a free list keeps through a trim however long they sat
    /// unused.
    pub const trim_keep = 4;

    const Local = struct {
        free: FreeList = .{},
        _: void align(std.atomic.cache_line) = {},
    };

    const Shard = struct {
        mutex: std.Io.Mutex = .init,
        free: FreeList = .{},
        // Each shard's lock on its own cache line.
        _: void align(std.atomic.cache_line) = {},
    };

    /// The free sets, and the fewest there were since the last trim:
    /// that many sat unused all the while.
    const FreeList = struct {
        list: std.SinglyLinkedList = .{},
        len: usize = 0,
        low: usize = 0,

        fn push(self: *FreeList, buffers: *RequestBuffers) void {
            self.list.prepend(&buffers.node);
            self.len += 1;
        }

        fn pop(self: *FreeList) ?*RequestBuffers {
            const node = self.list.popFirst() orelse return null;
            self.len -= 1;
            self.low = @min(self.low, self.len);
            return @fieldParentPtr("node", node);
        }

        /// Takes off the sets unused since the last call, past `trim_keep`:
        /// the ones at the end, given back longest ago.
        fn takeIdle(self: *FreeList) std.SinglyLinkedList {
            const n = self.low -| trim_keep;
            self.low = self.len - n;
            if (n == 0) return .{};
            var kept = self.len - n;
            self.len = kept;
            if (kept == 0) {
                const all = self.list;
                self.list = .{};
                return all;
            }
            var last = self.list.first.?;
            while (kept > 1) : (kept -= 1) last = last.next.?;
            const rest: std.SinglyLinkedList = .{ .first = last.next };
            last.next = null;
            return rest;
        }
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, read_buffer_len: usize, write_buffer_len: usize, arena_reserve: usize) RequestBuffersPool {
        return .{
            .allocator = allocator,
            .io = io,
            .read_buffer_len = read_buffer_len,
            .write_buffer_len = write_buffer_len,
            .arena_reserve = arena_reserve,
        };
    }

    /// Only once every set is back.
    pub fn deinit(self: *RequestBuffersPool) void {
        for (&self.shards) |*shard| {
            while (shard.free.pop()) |buffers| self.destroy(buffers);
        }
        for (&self.locals) |*list| {
            while (list.free.pop()) |buffers| self.destroy(buffers);
        }
        self.* = undefined;
    }

    /// A free set from the shard `key` picks, or a new one if it has none.
    /// The caller passes the same key for the same connection, its address
    /// say, so the sets it gives back are the ones it takes again.
    pub fn acquire(self: *RequestBuffersPool, key: usize) std.mem.Allocator.Error!*RequestBuffers {
        if (self.local()) |list| {
            const buffers = list.free.pop() orelse try self.create();
            buffers.shard = local_shard;
            return buffers;
        }
        const index: u8 = @intCast(std.hash.int(key) % shard_count);
        const shard = &self.shards[index];
        const free = blk: {
            shard.mutex.lockUncancelable(self.io);
            defer shard.mutex.unlock(self.io);
            break :blk shard.free.pop();
        };
        const buffers = free orelse try self.create();
        buffers.shard = index;
        return buffers;
    }

    /// Gives a set back to the shard it was taken from, its arena reset.
    pub fn release(self: *RequestBuffersPool, buffers: *RequestBuffers) void {
        _ = buffers.arena.reset(.retain_capacity);
        if (self.local()) |list| {
            list.free.push(buffers);
            return;
        }
        // Taken from an executor's list, given back off one: any shard.
        if (buffers.shard == local_shard) buffers.shard = @intCast(std.hash.int(@intFromPtr(buffers)) % shard_count);
        const shard = &self.shards[buffers.shard];
        shard.mutex.lockUncancelable(self.io);
        defer shard.mutex.unlock(self.io);
        shard.free.push(buffers);
    }

    /// Frees the sets no request took from the calling executor's list
    /// (under zio) since the last call, past `trim_keep`. Each executor
    /// calls it now and then (`Server`'s trim task), on itself.
    pub fn trimLocal(self: *RequestBuffersPool) void {
        if (self.local()) |list| self.destroyAll(list.free.takeIdle());
    }

    /// `trimLocal` for the shards, which `release` fills off zio's
    /// executors: from one task, so that each shard's interval is that
    /// task's.
    pub fn trimShards(self: *RequestBuffersPool) void {
        for (&self.shards) |*shard| {
            const idle = blk: {
                shard.mutex.lockUncancelable(self.io);
                defer shard.mutex.unlock(self.io);
                break :blk shard.free.takeIdle();
            };
            self.destroyAll(idle);
        }
    }

    fn destroyAll(self: *RequestBuffersPool, list: std.SinglyLinkedList) void {
        var it = list.first;
        while (it) |node| {
            it = node.next;
            const buffers: *RequestBuffers = @fieldParentPtr("node", node);
            // The pages go back to the OS too: an allocator that keeps
            // freed memory for its next allocations (a heap, a size class)
            // would keep them resident. Only whole pages inside the
            // buffers, clear of any bookkeeping the allocator writes into
            // freed memory at either end.
            if (comptime builtin.os.tag == .linux) {
                const page = std.heap.pageSize();
                const start = std.mem.alignForward(usize, @intFromPtr(buffers.read_buffer.ptr) + 64, page);
                const end = std.mem.alignBackward(usize, @intFromPtr(buffers.write_buffer.ptr) + buffers.write_buffer.len - 64, page);
                if (end > start) _ = std.os.linux.madvise(@ptrFromInt(start), end - start, std.os.linux.MADV.DONTNEED);
            }
            self.destroy(buffers);
        }
    }

    /// The calling executor's free list, under zio.
    fn local(self: *RequestBuffersPool) ?*Local {
        const i = placement.currentExecutor(self.io) orelse return null;
        if (i >= max_executors) return null;
        return &self.locals[i];
    }

    fn create(self: *RequestBuffersPool) std.mem.Allocator.Error!*RequestBuffers {
        const size = std.math.add(usize, @sizeOf(RequestBuffers), self.buffersLen()) catch return error.OutOfMemory;
        const memory = try self.allocator.alignedAlloc(u8, .of(RequestBuffers), size);
        const buffers: *RequestBuffers = @ptrCast(memory.ptr);
        const read_buffer = memory[@sizeOf(RequestBuffers)..][0..self.read_buffer_len];
        buffers.* = .{
            .arena = .init(self.allocator),
            .read_buffer = read_buffer,
            .write_buffer = memory[@sizeOf(RequestBuffers) + read_buffer.len ..],
        };
        errdefer self.destroy(buffers);
        // Reset keeps the memory, as one node the requests are then carved
        // from.
        _ = try buffers.arena.allocator().alloc(u8, self.arena_reserve);
        _ = buffers.arena.reset(.retain_capacity);
        return buffers;
    }

    fn destroy(self: *RequestBuffersPool, buffers: *RequestBuffers) void {
        buffers.arena.deinit();
        const base: [*]align(@alignOf(RequestBuffers)) u8 = @ptrCast(buffers);
        self.allocator.free(base[0 .. @sizeOf(RequestBuffers) + self.buffersLen()]);
    }

    fn buffersLen(self: *const RequestBuffersPool) usize {
        return self.read_buffer_len +| self.write_buffer_len;
    }
};

test "RequestBuffersPool: a set given back is the next one taken with the same key" {
    var pool: RequestBuffersPool = .init(std.testing.allocator, std.testing.io, 128, 64, 256);
    defer pool.deinit();

    const a = try pool.acquire(1);
    const b = try pool.acquire(1);
    try std.testing.expect(a != b);
    try std.testing.expectEqual(128, a.read_buffer.len);
    try std.testing.expectEqual(64, a.write_buffer.len);

    pool.release(a);
    pool.release(b);
    try std.testing.expectEqual(b, try pool.acquire(1));
    try std.testing.expectEqual(a, try pool.acquire(1));
    // Both are out, so this one is new.
    const c = try pool.acquire(1);
    try std.testing.expect(c != a and c != b);
    pool.release(a);
    pool.release(b);
    pool.release(c);
}

test "RequestBuffersPool: a set goes back to the shard it came from" {
    var pool: RequestBuffersPool = .init(std.testing.allocator, std.testing.io, 128, 64, 256);
    defer pool.deinit();

    // Two keys that land on different shards.
    var other: usize = 2;
    while (std.hash.int(other) % RequestBuffersPool.shard_count == std.hash.int(@as(usize, 1)) % RequestBuffersPool.shard_count) other += 1;

    const a = try pool.acquire(1);
    pool.release(a);
    // Not on the other key's shard: it gets a new set.
    const b = try pool.acquire(other);
    try std.testing.expect(b != a);
    pool.release(b);
    try std.testing.expectEqual(a, try pool.acquire(1));
    pool.release(a);
}

test "RequestBuffersPool: trim frees the sets unused since the last trim, past a few" {
    var pool: RequestBuffersPool = .init(std.testing.allocator, std.testing.io, 128, 64, 256);
    defer pool.deinit();
    const shard = &pool.shards[std.hash.int(@as(usize, 1)) % RequestBuffersPool.shard_count];

    // A burst of ten at once, all given back.
    var burst: [10]*RequestBuffers = undefined;
    for (&burst) |*b| b.* = try pool.acquire(1);
    for (burst) |b| pool.release(b);
    try std.testing.expectEqual(@as(usize, 10), shard.free.len);

    // None of them has sat idle a whole interval yet.
    pool.trimShards();
    try std.testing.expectEqual(@as(usize, 10), shard.free.len);
    // Two are taken and given back in the next one: the other eight sat
    // idle all of it, and go but for the four kept.
    const x = try pool.acquire(1);
    const y = try pool.acquire(1);
    pool.release(y);
    pool.release(x);
    pool.trimShards();
    try std.testing.expectEqual(@as(usize, 6), shard.free.len);
    // The ones given back last are what stays.
    try std.testing.expectEqual(&x.node, shard.free.list.first.?);

    // Idle from here on: down to the four kept, and no further.
    pool.trimShards();
    try std.testing.expectEqual(@as(usize, 4), shard.free.len);
    pool.trimShards();
    try std.testing.expectEqual(@as(usize, 4), shard.free.len);
}
