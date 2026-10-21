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

const std = @import("std");
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

    const Local = struct {
        free: std.SinglyLinkedList = .{},
        _: void align(std.atomic.cache_line) = {},
    };

    const Shard = struct {
        mutex: std.Io.Mutex = .init,
        free: std.SinglyLinkedList = .{},
        // Each shard's lock on its own cache line.
        _: void align(std.atomic.cache_line) = {},
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
            while (shard.free.popFirst()) |node| self.destroy(@fieldParentPtr("node", node));
        }
        for (&self.locals) |*list| {
            while (list.free.popFirst()) |node| self.destroy(@fieldParentPtr("node", node));
        }
        self.* = undefined;
    }

    /// A free set from the shard `key` picks, or a new one if it has none.
    /// The caller passes the same key for the same connection, its address
    /// say, so the sets it gives back are the ones it takes again.
    pub fn acquire(self: *RequestBuffersPool, key: usize) std.mem.Allocator.Error!*RequestBuffers {
        if (self.local()) |list| {
            const buffers: *RequestBuffers = if (list.free.popFirst()) |n| @fieldParentPtr("node", n) else try self.create();
            buffers.shard = local_shard;
            return buffers;
        }
        const index: u8 = @intCast(std.hash.int(key) % shard_count);
        const shard = &self.shards[index];
        const node = blk: {
            shard.mutex.lockUncancelable(self.io);
            defer shard.mutex.unlock(self.io);
            break :blk shard.free.popFirst();
        };
        const buffers: *RequestBuffers = if (node) |n| @fieldParentPtr("node", n) else try self.create();
        buffers.shard = index;
        return buffers;
    }

    /// Gives a set back to the shard it was taken from, its arena reset.
    pub fn release(self: *RequestBuffersPool, buffers: *RequestBuffers) void {
        _ = buffers.arena.reset(.retain_capacity);
        if (self.local()) |list| {
            list.free.prepend(&buffers.node);
            return;
        }
        // Taken from an executor's list, given back off one: any shard.
        if (buffers.shard == local_shard) buffers.shard = @intCast(std.hash.int(@intFromPtr(buffers)) % shard_count);
        const shard = &self.shards[buffers.shard];
        shard.mutex.lockUncancelable(self.io);
        defer shard.mutex.unlock(self.io);
        shard.free.prepend(&buffers.node);
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
