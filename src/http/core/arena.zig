//! An arena for one owner at a time: the request, stream and response
//! arenas (`Request.arena`, #171).
//!
//! Derived from Zig 0.17.0's std.heap.ArenaAllocator
//! (lib/std/heap/ArenaAllocator.zig, MIT, Copyright (c) Zig contributors),
//! with its concurrency machinery taken out. Since Zig 0.16 that arena is
//! lock-free and thread-safe: every allocation pays a `lock xadd`, a
//! `cmpxchg` when it pads for alignment, and resize and free a `cmpxchg`
//! each, 9% of the CPU of an HTTP/2 request on the M3 gate
//! (research/s2/h2-m4/arena.md). A request's arena never needed it: only
//! the request's own task allocates from it (docs/routing.md). What is left
//! is the std algorithm: bump in the first node; if it does not fit, grow
//! that node in place (`rawResize`, which `RequestBuffers`'s chunks answer
//! up to their length); else a new node of 1.5 times the old one plus what
//! is asked; resize and free of the last allocation only; the same reset.
//! Node sizes and the capacities reset keeps are byte-identical to std's,
//! so the pools tuned to std's numbers (request_buffers.zig's first chunk)
//! keep their layout. Changes besides the atomics: no free list (std keeps
//! one for the nodes a thread lost a race with), no `resizing` bit, and a
//! node grown in place puts the allocation at the old end rather than one
//! allocation further on (std counts the failed bump twice there).
//!
//! Its user may change thread between calls, as long as two never overlap:
//! an awaited call or a blocking-pool job may use a request's arena while
//! the request's task waits, a task started with `io.concurrent` may not.
//! Debug and test builds panic when two calls overlap.
//!
//! Re-diff against std's ArenaAllocator on every Zig bump.

const std = @import("std");
const safety = @import("anole_safety");
const assert = std.debug.assert;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const LocalArena = struct {
    child_allocator: Allocator,
    /// The nodes, the one allocations come from first.
    used: ?*Node = null,
    /// Debug and test builds: a call is inside the arena (`enter`).
    inside: if (safety.enabled) std.atomic.Value(bool) else void = if (safety.enabled) .init(false) else {},

    pub const ResetMode = std.heap.ArenaAllocator.ResetMode;

    pub const Node = struct {
        /// Of the whole node, this header included; always even, as std's.
        size: usize,
        end_index: usize,
        next: ?*Node,

        pub fn buf(node: *Node) []u8 {
            // SAFETY: a node is the start of a `size`-byte block from the child.
            return @as([*]u8, @ptrCast(node))[0..node.size][@sizeOf(Node)..];
        }

        fn allocatedSlice(node: *Node) []u8 {
            // SAFETY: as `buf`.
            return @as([*]u8, @ptrCast(node))[0..node.size];
        }
    };

    pub fn init(child_allocator: Allocator) LocalArena {
        return .{ .child_allocator = child_allocator };
    }

    pub fn deinit(arena: LocalArena) void {
        var it = arena.used;
        while (it) |node| {
            // Before the free, which frees `node`.
            it = node.next;
            arena.child_allocator.rawFree(node.allocatedSlice(), .of(Node), @returnAddress());
        }
    }

    pub fn allocator(arena: *LocalArena) Allocator {
        return .{
            .ptr = arena,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    /// The memory the arena holds, not counting its node headers.
    pub fn queryCapacity(arena: LocalArena) usize {
        var capacity: usize = 0;
        var it = arena.used;
        while (it) |node| : (it = node.next) capacity += node.size - @sizeOf(Node);
        return capacity;
    }

    /// std's `reset`: frees every allocation, and with `retain_capacity` or
    /// `retain_with_limit` keeps one node of what the arena held (up to the
    /// limit) for the next ones. False when that node could not be had; the
    /// arena is empty and works then too.
    pub fn reset(arena: *LocalArena, mode: ResetMode) bool {
        arena.enter();
        defer arena.leave();
        const limit: ?usize = switch (mode) {
            .retain_capacity => null,
            .retain_with_limit => |limit| limit,
            .free_all => 0,
        };
        if (limit == 0) {
            arena.deinit();
            arena.used = null;
            return true;
        }
        const used_capacity = arena.queryCapacity();
        const new_capacity = if (limit) |lim| @min(lim, used_capacity) else used_capacity;

        // Free all nodes but the last (the first allocated).
        var it = arena.used;
        const node: *Node = while (it) |node| {
            it = node.next;
            if (it == null) break node;
            arena.child_allocator.rawFree(node.allocatedSlice(), .of(Node), @returnAddress());
        } else return true;
        const allocated_slice = node.allocatedSlice();

        // Backwards, to stay below the limit.
        const new_size = mem.alignBackward(usize, @sizeOf(Node) + new_capacity, 2);
        if (new_size == @sizeOf(Node)) {
            arena.child_allocator.rawFree(allocated_slice, .of(Node), @returnAddress());
            arena.used = null;
            return true;
        }
        node.end_index = 0;
        arena.used = node;
        if (allocated_slice.len == new_size) return true;
        if (arena.child_allocator.rawResize(allocated_slice, .of(Node), new_size, @returnAddress())) {
            node.size = new_size;
            return true;
        }
        // Not preheated (the node is kept as it is) when this fails.
        const new_ptr = arena.child_allocator.rawAlloc(new_size, .of(Node), @returnAddress()) orelse return false;
        arena.child_allocator.rawFree(allocated_slice, .of(Node), @returnAddress());
        // SAFETY: a block the child gave for `.of(Node)`; @alignCast checks it.
        const new_node: *Node = @ptrCast(@alignCast(new_ptr));
        new_node.* = .{ .size = new_size, .end_index = 0, .next = null };
        arena.used = new_node;
        return true;
    }

    /// Debug and test builds: panics when another call is inside the arena,
    /// which only two tasks or threads using it at once can do (an
    /// allocation never suspends its task).
    inline fn enter(arena: *LocalArena) void {
        if (safety.enabled and arena.inside.swap(true, .acquire))
            @panic("a request arena used by two tasks at once: req.arena is not thread-safe (docs/routing.md)");
    }

    inline fn leave(arena: *LocalArena) void {
        if (safety.enabled) arena.inside.store(false, .release);
    }

    fn alignedIndex(buf_ptr: [*]u8, end_index: usize, alignment: Alignment) usize {
        // Wrapping, as std: the largest alignment is the largest usize.
        // SAFETY: addresses only, for the padding; nothing is made a pointer.
        return alignment.forward(@intFromPtr(buf_ptr) +% end_index) -% @intFromPtr(buf_ptr);
    }

    fn alloc(ctx: *anyopaque, n: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        // SAFETY: `allocator()` made `ctx` from a *LocalArena.
        const arena: *LocalArena = @ptrCast(@alignCast(ctx));
        _ = ret_addr;
        assert(n > 0);
        arena.enter();
        defer arena.leave();

        var prev_size: usize = 0;
        if (arena.used) |node| {
            const buf = node.buf();
            const aligned_index = alignedIndex(buf.ptr, node.end_index, alignment);
            if (aligned_index + n <= buf.len) {
                node.end_index = aligned_index + n;
                return buf[aligned_index..][0..n].ptr;
            }
            // Grow the node in place before taking a new one.
            const new_size = mem.alignForward(usize, @sizeOf(Node) + aligned_index + n, 2);
            if (arena.child_allocator.rawResize(node.allocatedSlice(), .of(Node), new_size, @returnAddress())) {
                node.size = new_size;
                node.end_index = aligned_index + n;
                return node.buf()[aligned_index..][0..n].ptr;
            }
            prev_size = buf.len;
        }

        const min_size = @sizeOf(Node) + alignment.toByteUnits() + n;
        const big_enough_size = prev_size + min_size + 16;
        const size = mem.alignForward(usize, big_enough_size + big_enough_size / 2, 2);
        const ptr = arena.child_allocator.rawAlloc(size, .of(Node), @returnAddress()) orelse return null;
        // SAFETY: a block the child gave for `.of(Node)`; @alignCast checks it.
        const new_node: *Node = @ptrCast(@alignCast(ptr));
        // SAFETY: `end_index` is set below, before the node is used.
        new_node.* = .{ .size = size, .end_index = undefined, .next = arena.used };
        const buf = new_node.buf();
        const aligned_index = alignedIndex(buf.ptr, 0, alignment);
        assert(size >= @sizeOf(Node) + aligned_index + n);
        new_node.end_index = aligned_index + n;
        arena.used = new_node;
        return buf[aligned_index..][0..n].ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        // SAFETY: `allocator()` made `ctx` from a *LocalArena.
        const arena: *LocalArena = @ptrCast(@alignCast(ctx));
        _ = alignment;
        _ = ret_addr;
        assert(memory.len > 0);
        assert(new_len > 0);
        arena.enter();
        defer arena.leave();

        const node = arena.used.?;
        const buf = node.buf();
        if (buf.ptr + node.end_index != memory.ptr + memory.len) {
            // Not the most recent allocation: it can shrink, not grow.
            return new_len <= memory.len;
        }
        if (new_len <= memory.len) {
            node.end_index -= memory.len - new_len;
            return true;
        }
        if (buf.len - node.end_index >= new_len - memory.len) {
            node.end_index += new_len - memory.len;
            return true;
        }
        return false;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        return if (resize(ctx, memory, alignment, new_len, ret_addr)) memory.ptr else null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        // SAFETY: `allocator()` made `ctx` from a *LocalArena.
        const arena: *LocalArena = @ptrCast(@alignCast(ctx));
        _ = alignment;
        _ = ret_addr;
        assert(memory.len > 0);
        arena.enter();
        defer arena.leave();

        const node = arena.used.?;
        const buf = node.buf();
        // Only the most recent allocation goes back.
        if (buf.ptr + node.end_index != memory.ptr + memory.len) return;
        node.end_index -= memory.len;
    }
};
