// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

//! The memory requests are served with -- the buffer a head is read into,
//! the arena everything else comes from, and the buffer a response is
//! written through -- in sets that requests hand on to the next. Under zio
//! each executor keeps the sets given back on it and takes from them
//! first, with no lock: a connection stays on its executor, so the set it
//! gives back is the one it takes for its next request. Elsewhere the free
//! sets are sharded, so that connections opening and closing at once
//! mostly take different locks.
//!
//! A set is laid out so that an ordinary request touches one page of it:
//! the header, the arena's first chunk and the start of the read buffer,
//! where the head lands, share the set's first page, and the write buffer
//! is not in the set at all. A request takes one from a pool of their own
//! at its first write (`RequestBuffers.writeBuffer`) and gives it back once
//! its response is out, so a request that waits before it answers (a
//! handler sleeping on a timer, a database) holds none.
//!
//! A free list keeps what a burst left it only for a while: `trimLocal`
//! and `trimShards`, run on a timer, give back the sets (and free the write
//! buffers) that no request took from it since the last trim, past a few
//! kept for the next arrivals. So the memory a burst of connections needed
//! at once goes back once the burst is over, not when the server stops: a
//! set's pages to the OS, the set itself to the slab it came from
//! (`RequestBuffersPool.Slabs`).

const std = @import("std");
const builtin = @import("builtin");
const placement = @import("../placement.zig");
const safety = @import("anole_safety");

/// A set is aligned to this, so that its first page is the first 4 KiB of
/// it (or more of it, with bigger pages).
const set_alignment: std.mem.Alignment = .fromByteUnits(4096);

/// About how much one slab of sets is (`RequestBuffersPool.Slabs`).
const slab_target_len = 256 * 1024;

/// The arena's chunks inside a set are aligned to this, which is as much as
/// `std.heap.ArenaAllocator` asks of its nodes.
const chunk_alignment: std.mem.Alignment = .@"16";

/// The arena's first chunk, on the set's first page: what an ordinary
/// request takes from its arena (the request's and the response's header
/// tables, its parameters) with room to spare, and little enough that a
/// head of a kilobyte or more still starts on the same page. A request that
/// needs more goes on to a second chunk past the read buffer
/// (`RequestBuffersPool.arena_reserve`).
pub const first_chunk_len = 2 * 1024;

/// Headroom for `std.heap.ArenaAllocator`'s node header, which its reset
/// counts outside the capacity it keeps.
const arena_node_headroom = 64;

/// A request's read buffer and arena, in one allocation with this header,
/// and the write buffer it took (`writeBuffer`):
///
///     | header | arena's first chunk | read buffer ...   | arena's second chunk |
///     |<----------- first page ----------->|
pub const RequestBuffers = struct {
    /// Its chunks are `first_chunk` and `second_chunk` while they last,
    /// then `pool.allocator` (`chunkAllocator`).
    arena: std.heap.ArenaAllocator,
    read_buffer: []u8,
    first_chunk: []u8,
    second_chunk: []u8,
    first_taken: bool = false,
    second_taken: bool = false,
    /// The arena's frees give their pages back to the OS first: the set is
    /// being freed (`RequestBuffersPool.destroyAll`).
    releasing: bool = false,
    pool: *RequestBuffersPool,
    node: std.SinglyLinkedList.Node = .{},
    /// The shard it was taken from, and goes back to.
    shard: u8 = 0,

    /// Empties the arena for the next request, keeping only its first
    /// chunk: the second goes back to the set, and what the arena took
    /// beyond it to `pool.allocator`, so a big request does not leave the
    /// set bigger for the ordinary ones after it. In Debug and test builds
    /// the first chunk goes back too, poisoned (`safety.resetArena`), so a
    /// slice kept past its request reads 0xDD rather than its old bytes
    /// (SAFETY.md M4, M6).
    pub fn resetArena(self: *RequestBuffers) void {
        _ = safety.resetArena(&self.arena, self.retainMode());
    }

    /// `resetArena` as release builds do it, keeping the first chunk.
    fn resetArenaRetaining(self: *RequestBuffers) void {
        _ = self.arena.reset(self.retainMode());
    }

    fn retainMode(self: *const RequestBuffers) std.heap.ArenaAllocator.ResetMode {
        return if (self.first_chunk.len > arena_node_headroom)
            .{ .retain_with_limit = self.first_chunk.len - arena_node_headroom }
        else
            .retain_capacity;
    }

    /// The arena's allocator: the set's two chunks first, as the arena's
    /// first nodes ask for them, then `pool.allocator`. A chunk the arena
    /// frees goes back to the set; the pages of anything else it frees go
    /// back to the OS first while the set itself is being freed (an
    /// allocator keeps freed memory resident for its next allocations).
    fn chunkAllocator(self: *RequestBuffers) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    /// The set's chunk `memory` is, if it is one.
    fn chunkOf(self: *RequestBuffers, memory: []u8) ?[]u8 {
        if (self.first_chunk.len > 0 and memory.ptr == self.first_chunk.ptr) return self.first_chunk;
        if (self.second_chunk.len > 0 and memory.ptr == self.second_chunk.ptr) return self.second_chunk;
        return null;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *RequestBuffers = @ptrCast(@alignCast(ctx));
        if (alignment.compare(.lte, chunk_alignment)) {
            if (!self.first_taken and len <= self.first_chunk.len) {
                self.first_taken = true;
                return self.first_chunk.ptr;
            }
            if (!self.second_taken and len <= self.second_chunk.len) {
                self.second_taken = true;
                return self.second_chunk.ptr;
            }
        }
        return self.pool.allocator.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *RequestBuffers = @ptrCast(@alignCast(ctx));
        if (self.chunkOf(memory)) |chunk| return new_len <= chunk.len;
        return self.pool.allocator.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *RequestBuffers = @ptrCast(@alignCast(ctx));
        if (self.chunkOf(memory)) |chunk| return if (new_len <= chunk.len) memory.ptr else null;
        return self.pool.allocator.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *RequestBuffers = @ptrCast(@alignCast(ctx));
        if (self.chunkOf(memory)) |chunk| {
            if (chunk.ptr == self.first_chunk.ptr) self.first_taken = false else self.second_taken = false;
            safety.poison(chunk);
            return;
        }
        if (self.releasing) releasePages(memory);
        self.pool.allocator.rawFree(memory, alignment, ret_addr);
    }
};

/// A response's write buffer, the bytes behind this header.
pub const WriteBuffer = struct {
    node: std.SinglyLinkedList.Node = .{},
    /// The shard it was taken from, and goes back to.
    shard: u8 = 0,
};

/// glibc's `malloc_trim`, where the allocator may be glibc's malloc.
const have_malloc_trim = builtin.os.tag == .linux and builtin.abi.isGnu() and builtin.link_libc;
extern "c" fn malloc_trim(pad: usize) c_int;

/// Gives the OS back the whole pages inside `memory`, about to be freed:
/// only where they would stay resident otherwise (Linux), and clear of
/// what an allocator writes into freed memory at either end.
fn releasePages(memory: []u8) void {
    if (comptime builtin.os.tag != .linux) return;
    if (memory.len < 128) return;
    const page = std.heap.pageSize();
    const start = std.mem.alignForward(usize, @intFromPtr(memory.ptr) + 64, page);
    const end = std.mem.alignBackward(usize, @intFromPtr(memory.ptr) + memory.len - 64, page);
    if (end > start) _ = std.os.linux.madvise(@ptrFromInt(start), end - start, std.os.linux.MADV.DONTNEED);
}

/// Free items of type `T` (a set or a write buffer, by their `node`), and
/// the fewest there were since the last trim: that many sat unused all the
/// while.
fn FreeList(comptime T: type) type {
    return struct {
        list: std.SinglyLinkedList = .{},
        len: usize = 0,
        low: usize = 0,

        const Self = @This();

        fn push(self: *Self, item: *T) void {
            self.list.prepend(&item.node);
            self.len += 1;
        }

        fn pop(self: *Self) ?*T {
            const node = self.list.popFirst() orelse return null;
            self.len -= 1;
            self.low = @min(self.low, self.len);
            return @fieldParentPtr("node", node);
        }

        /// Takes off the items unused since the last call, past
        /// `trim_keep`: the ones at the end, given back longest ago.
        fn takeIdle(self: *Self) std.SinglyLinkedList {
            const n = self.low -| RequestBuffersPool.trim_keep;
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
}

pub const RequestBuffersPool = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    read_buffer_len: usize,
    write_buffer_len: usize,
    /// The arena's second chunk, past the read buffer: with the first,
    /// `first_chunk_len` on the first page, how much of the arena lives in
    /// the set, so that a request is served without the arena allocating
    /// unless it needs more than both. As big as a node the arena asks for
    /// when the first is full needs to be: half as much again as the first
    /// and what did not fit in it.
    arena_reserve: usize,
    shards: [shard_count]Shard = @splat(.{}),
    /// One free list per executor, by index (zio has at most 64). Only the
    /// executor's own thread touches its list, and nothing between taking
    /// a set off and putting one on can suspend, so it needs no lock.
    locals: [max_executors]Local = @splat(.{}),
    slabs: Slabs = .{},

    const shard_count = 16;
    const max_executors = 64;
    /// `RequestBuffers.shard` for a set from an executor's list.
    const local_shard = shard_count;

    /// Sets a free list keeps through a trim however long they sat
    /// unused.
    pub const trim_keep = 4;

    const Local = struct {
        free: FreeList(RequestBuffers) = .{},
        writes: FreeList(WriteBuffer) = .{},
        _: void align(std.atomic.cache_line) = {},
    };

    const Shard = struct {
        mutex: std.Io.Mutex = .init,
        free: FreeList(RequestBuffers) = .{},
        writes: FreeList(WriteBuffer) = .{},
        // Each shard's lock on its own cache line.
        _: void align(std.atomic.cache_line) = {},
    };

    /// Where sets come from: slabs of them, each one block from the
    /// allocator, page-aligned, so that a set is page-aligned and nothing
    /// of the allocator's sits on its pages (a block's header before it,
    /// the next block's after it), which would cost a page or two more per
    /// set. A slab is never freed before the pool: a set a trim frees has
    /// its pages given back to the OS (`cold`) and is the next one taken.
    const Slabs = struct {
        mutex: std.Io.Mutex = .init,
        /// What is left of the newest slab.
        rest: []u8 = &.{},
        /// Every slab, for `deinit`.
        list: std.SinglyLinkedList = .{},
        /// Sets a trim freed, their pages given back.
        cold: std.ArrayList(*RequestBuffers) = .empty,
    };

    const Slab = struct {
        node: std.SinglyLinkedList.Node = .{},
        memory: []align(set_alignment.toByteUnits()) u8,
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

    /// Only once every set and write buffer is back.
    pub fn deinit(self: *RequestBuffersPool) void {
        for (&self.shards) |*shard| {
            while (shard.free.pop()) |buffers| buffers.arena.deinit();
            while (shard.writes.pop()) |w| self.destroyWrite(w);
        }
        for (&self.locals) |*list| {
            while (list.free.pop()) |buffers| buffers.arena.deinit();
            while (list.writes.pop()) |w| self.destroyWrite(w);
        }
        self.slabs.cold.deinit(self.allocator);
        while (self.slabs.list.popFirst()) |node| {
            const slab: *Slab = @fieldParentPtr("node", node);
            self.allocator.free(slab.memory);
            self.allocator.destroy(slab);
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
        buffers.resetArena();
        safety.poison(buffers.read_buffer);
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

    /// A free write buffer, as `acquire` takes a set: for a response that
    /// is about to write (`Connection.prepareWrite`), until it is out.
    pub fn takeWriteBuffer(self: *RequestBuffersPool, key: usize) std.mem.Allocator.Error!*WriteBuffer {
        if (self.local()) |list| {
            const w = list.writes.pop() orelse try self.createWrite();
            w.shard = local_shard;
            return w;
        }
        const index: u8 = @intCast(std.hash.int(key) % shard_count);
        const shard = &self.shards[index];
        const free = blk: {
            shard.mutex.lockUncancelable(self.io);
            defer shard.mutex.unlock(self.io);
            break :blk shard.writes.pop();
        };
        const w = free orelse try self.createWrite();
        w.shard = index;
        return w;
    }

    /// As `release` gives back a set.
    pub fn giveWriteBuffer(self: *RequestBuffersPool, w: *WriteBuffer) void {
        safety.poison(self.writeBytes(w));
        if (self.local()) |list| {
            list.writes.push(w);
            return;
        }
        if (w.shard == local_shard) w.shard = @intCast(std.hash.int(@intFromPtr(w)) % shard_count);
        const shard = &self.shards[w.shard];
        shard.mutex.lockUncancelable(self.io);
        defer shard.mutex.unlock(self.io);
        shard.writes.push(w);
    }

    /// The bytes of write buffer `w`, which follow its header.
    pub fn writeBytes(self: *const RequestBuffersPool, w: *WriteBuffer) []u8 {
        return @as([*]u8, @ptrCast(w))[@sizeOf(WriteBuffer)..][0..self.write_buffer_len];
    }

    /// Frees the sets and write buffers no request took from the calling
    /// executor's lists (under zio) since the last call, past `trim_keep`.
    /// Each executor calls it now and then (`Server`'s trim task), on
    /// itself.
    pub fn trimLocal(self: *RequestBuffersPool) void {
        const list = self.local() orelse return;
        self.destroyAll(list.free.takeIdle(), list.writes.takeIdle());
    }

    /// `trimLocal` for the shards, which `release` fills off zio's
    /// executors: from one task, so that each shard's interval is that
    /// task's.
    pub fn trimShards(self: *RequestBuffersPool) void {
        for (&self.shards) |*shard| {
            const sets, const writes = blk: {
                shard.mutex.lockUncancelable(self.io);
                defer shard.mutex.unlock(self.io);
                break :blk .{ shard.free.takeIdle(), shard.writes.takeIdle() };
            };
            self.destroyAll(sets, writes);
        }
    }

    fn destroyAll(self: *RequestBuffersPool, sets: std.SinglyLinkedList, writes: std.SinglyLinkedList) void {
        if (sets.first == null and writes.first == null) return;
        // glibc's malloc also keeps the page under each freed chunk's
        // header resident; it gives those back too.
        defer if (comptime have_malloc_trim) {
            _ = malloc_trim(0);
        };
        var it = sets.first;
        while (it) |node| {
            it = node.next;
            const buffers: *RequestBuffers = @fieldParentPtr("node", node);
            self.cool(buffers);
        }
        it = writes.first;
        while (it) |node| {
            it = node.next;
            const w: *WriteBuffer = @fieldParentPtr("node", node);
            releasePages(self.writeBytes(w));
            self.destroyWrite(w);
        }
    }

    /// The calling executor's free lists, under zio.
    fn local(self: *RequestBuffersPool) ?*Local {
        const i = placement.currentExecutor(self.io) orelse return null;
        if (i >= max_executors) return null;
        return &self.locals[i];
    }

    /// Gives a set's pages back to the OS, and the set to the slabs, to
    /// be taken again before any more is carved: what the arena took
    /// beyond the set first, as it frees it (`chunkAllocator`), not only
    /// to the allocator. Without the memory to note it, the set is not
    /// taken again; its slab frees it with the pool all the same.
    fn cool(self: *RequestBuffersPool, buffers: *RequestBuffers) void {
        buffers.releasing = true;
        buffers.arena.deinit();
        const memory: []align(set_alignment.toByteUnits()) u8 = @as([*]align(set_alignment.toByteUnits()) u8, @ptrCast(@alignCast(buffers)))[0..self.setLen()];
        if (comptime builtin.os.tag == .linux) _ = std.os.linux.madvise(memory.ptr, memory.len, std.os.linux.MADV.DONTNEED);
        self.slabs.mutex.lockUncancelable(self.io);
        defer self.slabs.mutex.unlock(self.io);
        self.slabs.cold.append(self.allocator, buffers) catch {};
    }

    /// Where the parts of a set are, from its start.
    const Layout = struct {
        first: usize,
        first_len: usize,
        read: usize,
        second: usize,
        second_len: usize,
        len: usize,
    };

    fn layout(self: *const RequestBuffersPool) Layout {
        const first = chunk_alignment.forward(@sizeOf(RequestBuffers));
        const first_len = @min(first_chunk_len, self.arena_reserve);
        const read = first + first_len;
        const second = chunk_alignment.forward(read +| self.read_buffer_len);
        const second_len = self.arena_reserve;
        return .{
            .first = first,
            .first_len = first_len,
            .read = read,
            .second = second,
            .second_len = second_len,
            .len = second +| second_len,
        };
    }

    /// A set's length, to the next page: where the next one in a slab
    /// starts.
    fn setLen(self: *const RequestBuffersPool) usize {
        return set_alignment.forward(self.layout().len);
    }

    fn create(self: *RequestBuffersPool) std.mem.Allocator.Error!*RequestBuffers {
        const l = self.layout();
        const memory = try self.carve();
        const buffers: *RequestBuffers = @ptrCast(@alignCast(memory.ptr));
        buffers.* = .{
            .arena = undefined,
            .read_buffer = memory[l.read..][0..self.read_buffer_len],
            .first_chunk = memory[l.first..][0..l.first_len],
            .second_chunk = memory[l.second..][0..l.second_len],
            .pool = self,
        };
        buffers.arena = .init(buffers.chunkAllocator());
        // The arena's first node is the first chunk, all of it, from the
        // start: it is the node the arena keeps (`resetArena`). Asked for
        // as an allocation the arena makes a node of that size for (half as
        // much again as it needs). Nothing else can fail, so the set goes
        // back to the slabs if this does.
        _ = buffers.arena.allocator().alloc(u8, @max(1, (l.first_len * 2 / 3) -| arena_node_headroom)) catch |err| {
            self.cool(buffers);
            return err;
        };
        buffers.resetArenaRetaining();
        return buffers;
    }

    /// The memory for a new set: one a trim gave back, or the next in the
    /// newest slab, or the first in a new one.
    fn carve(self: *RequestBuffersPool) std.mem.Allocator.Error![]u8 {
        const len = self.setLen();
        if (len >= std.math.maxInt(usize) / 2) return error.OutOfMemory;
        self.slabs.mutex.lockUncancelable(self.io);
        defer self.slabs.mutex.unlock(self.io);
        if (self.slabs.cold.pop()) |buffers| return @as([*]u8, @ptrCast(buffers))[0..len];
        if (self.slabs.rest.len < len) {
            const count = @max(1, slab_target_len / len);
            const slab = try self.allocator.create(Slab);
            errdefer self.allocator.destroy(slab);
            slab.* = .{ .memory = try self.allocator.alignedAlloc(u8, set_alignment, count * len) };
            self.slabs.list.prepend(&slab.node);
            self.slabs.rest = slab.memory;
        }
        const memory = self.slabs.rest[0..len];
        self.slabs.rest = self.slabs.rest[len..];
        return memory;
    }

    fn createWrite(self: *RequestBuffersPool) std.mem.Allocator.Error!*WriteBuffer {
        const size = std.math.add(usize, @sizeOf(WriteBuffer), self.write_buffer_len) catch return error.OutOfMemory;
        const memory = try self.allocator.alignedAlloc(u8, .of(WriteBuffer), size);
        const w: *WriteBuffer = @ptrCast(memory.ptr);
        w.* = .{};
        return w;
    }

    fn destroyWrite(self: *RequestBuffersPool, w: *WriteBuffer) void {
        const base: [*]align(@alignOf(WriteBuffer)) u8 = @ptrCast(w);
        self.allocator.free(base[0 .. @sizeOf(WriteBuffer) + self.write_buffer_len]);
    }
};

test "RequestBuffersPool: a set given back is the next one taken with the same key" {
    var pool: RequestBuffersPool = .init(std.testing.allocator, std.testing.io, 128, 64, 256);
    defer pool.deinit();

    const a = try pool.acquire(1);
    const b = try pool.acquire(1);
    try std.testing.expect(a != b);
    try std.testing.expectEqual(128, a.read_buffer.len);

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

test "RequestBuffersPool: the header, the arena's first chunk and the head share the first page" {
    var pool: RequestBuffersPool = .init(std.testing.allocator, std.testing.io, 16 * 1024 + 1024, 16 * 1024, 8 * 1024);
    defer pool.deinit();
    const b = try pool.acquire(1);
    defer pool.release(b);

    const base = @intFromPtr(b);
    try std.testing.expect(std.mem.isAligned(base, 4096));
    try std.testing.expect(@intFromPtr(b.first_chunk.ptr) - base < 512);
    try std.testing.expectEqual(@intFromPtr(b.first_chunk.ptr) + first_chunk_len, @intFromPtr(b.read_buffer.ptr));
    try std.testing.expect(@intFromPtr(b.read_buffer.ptr) - base + 1024 <= 4096);
    try std.testing.expectEqual(8 * 1024, b.second_chunk.len);

    // An ordinary request's allocations come from the first chunk.
    const arena = b.arena.allocator();
    const small = try arena.alloc(u8, 1500);
    try std.testing.expect(@intFromPtr(small.ptr) >= @intFromPtr(b.first_chunk.ptr) and
        @intFromPtr(small.ptr) + small.len <= @intFromPtr(b.first_chunk.ptr) + b.first_chunk.len);
    // A bigger one goes on to the second chunk, then to the allocator.
    const more = try arena.alloc(u8, 2000);
    try std.testing.expect(@intFromPtr(more.ptr) >= @intFromPtr(b.second_chunk.ptr) and
        @intFromPtr(more.ptr) + more.len <= @intFromPtr(b.second_chunk.ptr) + b.second_chunk.len);
    const big = try arena.alloc(u8, 64 * 1024);
    try std.testing.expect(@intFromPtr(big.ptr) + big.len <= base or @intFromPtr(big.ptr) >= base + pool.setLen());

    // Reset as release builds do, the arena is back to its first chunk
    // alone, and the next request's allocations land there again.
    b.resetArenaRetaining();
    try std.testing.expect(b.first_taken and !b.second_taken);
    const again = try arena.alloc(u8, 1500);
    try std.testing.expectEqual(small.ptr, again.ptr);
}

test "RequestBuffers: what a request kept of its arena reads poison after the reset (test builds)" {
    var pool: RequestBuffersPool = .init(std.testing.allocator, std.testing.io, 128, 64, 256);
    defer pool.deinit();
    const b = try pool.acquire(1);
    defer pool.release(b);
    const kept = try b.arena.allocator().dupe(u8, "a request's bytes");
    b.resetArena();
    try std.testing.expect(std.mem.allEqual(u8, kept, safety.poison_byte));
}

test "RequestBuffersPool: a write buffer given back is the next one taken" {
    var pool: RequestBuffersPool = .init(std.testing.allocator, std.testing.io, 128, 64, 256);
    defer pool.deinit();

    const a = try pool.takeWriteBuffer(1);
    const b = try pool.takeWriteBuffer(1);
    try std.testing.expect(a != b);
    try std.testing.expectEqual(64, pool.writeBytes(a).len);
    pool.giveWriteBuffer(a);
    try std.testing.expectEqual(a, try pool.takeWriteBuffer(1));
    pool.giveWriteBuffer(a);
    pool.giveWriteBuffer(b);
}

test "RequestBuffersPool: a set a trim gave back is the next one made" {
    var pool: RequestBuffersPool = .init(std.testing.allocator, std.testing.io, 128, 64, 256);
    defer pool.deinit();
    const shard = &pool.shards[std.hash.int(@as(usize, 1)) % RequestBuffersPool.shard_count];

    var burst: [6]*RequestBuffers = undefined;
    for (&burst) |*b| b.* = try pool.acquire(1);
    for (burst) |b| pool.release(b);
    // Two trims: the sets sat idle through the second, and all but the
    // four kept go back to the slabs.
    pool.trimShards();
    pool.trimShards();
    try std.testing.expectEqual(@as(usize, 4), shard.free.len);
    try std.testing.expectEqual(@as(usize, 2), pool.slabs.cold.items.len);

    // The four kept come first, then the two given back, as new sets.
    var again: [6]*RequestBuffers = undefined;
    for (&again) |*b| b.* = try pool.acquire(1);
    try std.testing.expectEqual(@as(usize, 0), pool.slabs.cold.items.len);
    for (again) |b| {
        try std.testing.expect(std.mem.indexOfScalar(*RequestBuffers, &burst, b) != null);
        // Whole again: its arena serves from its first chunk.
        const x = try b.arena.allocator().alloc(u8, 8);
        try std.testing.expect(@intFromPtr(x.ptr) >= @intFromPtr(b.first_chunk.ptr) and
            @intFromPtr(x.ptr) < @intFromPtr(b.first_chunk.ptr) + b.first_chunk.len);
    }
    for (again) |b| pool.release(b);
}
