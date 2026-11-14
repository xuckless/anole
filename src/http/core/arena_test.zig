//! `LocalArena`'s tests (arena.zig): the std arena's own tests, the
//! in-place growth `RequestBuffers` relies on, parity with std's arena and
//! a hand-off between threads.
const std = @import("std");
const LocalArena = @import("arena.zig").LocalArena;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const testing = std.testing;

test "LocalArena: reset with preheating keeps allocations aligned and sized" {
    var arena: LocalArena = .init(testing.allocator);
    defer arena.deinit();
    var prng = std.Random.DefaultPrng.init(testing.random_seed);
    const random = prng.random();
    var rounds: usize = 25;
    while (rounds > 0) : (rounds -= 1) {
        _ = arena.reset(.retain_capacity);
        var alloced: usize = 0;
        const total = random.intRangeAtMost(usize, 256, 16384);
        while (alloced < total) {
            const size = random.intRangeAtMost(usize, 16, 256);
            const alignment: Alignment = .@"32";
            const slice = try arena.allocator().alignedAlloc(u8, alignment, size);
            try testing.expect(alignment.check(@intFromPtr(slice.ptr)));
            try testing.expectEqual(size, slice.len);
            alloced += slice.len;
        }
    }
}

test "LocalArena: reset while retaining a buffer" {
    var arena: LocalArena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try a.alloc(u8, 1);
    try testing.expect(arena.used != null);
    while (arena.used.?.next == null) _ = try a.alloc(u8, 1000);

    try testing.expect(arena.reset(.{ .retain_with_limit = 2 }));
    try testing.expect(arena.used.?.next == null);
    try testing.expectEqual(2, arena.queryCapacity());

    try testing.expect(arena.reset(.free_all));
    try testing.expectEqual(null, arena.used);
}

test "LocalArena: resize and free change only the most recent allocation" {
    var arena: LocalArena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try a.alloc(u8, 16);
    const last = try a.alloc(u8, 16);
    const end = arena.used.?.end_index;

    // Not the last: shrinks in name only, never grows, free does nothing.
    try testing.expect(a.resize(first, 8));
    try testing.expect(!a.resize(first, 32));
    a.free(first);
    try testing.expectEqual(end, arena.used.?.end_index);

    // The last: grows while the node has room, shrinks and frees.
    try testing.expect(a.resize(last, 32));
    try testing.expectEqual(end + 16, arena.used.?.end_index);
    try testing.expect(!a.resize(last.ptr[0..32], arena.used.?.buf().len + 1));
    try testing.expect(a.resize(last.ptr[0..32], 4));
    try testing.expectEqual(end - 12, arena.used.?.end_index);
    a.free(last[0..4]);
    try testing.expectEqual(end - 16, arena.used.?.end_index);
    try testing.expect(arena.used.?.buf().ptr + arena.used.?.end_index == first.ptr + first.len);
}

/// One chunk that a node may grow into, as `RequestBuffers` hands its
/// chunks out, over `testing.allocator` beyond it; counts its calls.
const ChunkChild = struct {
    chunk: []align(16) u8,
    taken: bool = false,
    allocs: usize = 0,
    resizes: usize = 0,

    fn allocator(self: *ChunkChild) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = cAlloc,
            .resize = cResize,
            .remap = Allocator.noRemap,
            .free = cFree,
        } };
    }

    fn cAlloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret: usize) ?[*]u8 {
        const self: *ChunkChild = @ptrCast(@alignCast(ctx));
        self.allocs += 1;
        if (!self.taken and len <= self.chunk.len) {
            self.taken = true;
            return self.chunk.ptr;
        }
        return testing.allocator.rawAlloc(len, alignment, ret);
    }

    fn cResize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret: usize) bool {
        const self: *ChunkChild = @ptrCast(@alignCast(ctx));
        self.resizes += 1;
        if (memory.ptr == self.chunk.ptr) return new_len <= self.chunk.len;
        return testing.allocator.rawResize(memory, alignment, new_len, ret);
    }

    fn cFree(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret: usize) void {
        const self: *ChunkChild = @ptrCast(@alignCast(ctx));
        if (memory.ptr == self.chunk.ptr) {
            self.taken = false;
            return;
        }
        testing.allocator.rawFree(memory, alignment, ret);
    }
};

test "LocalArena: the first node grows in place through its chunk, allocations end to end" {
    var chunk: [2048]u8 align(16) = undefined;
    var child: ChunkChild = .{ .chunk = &chunk };
    var arena: LocalArena = .init(child.allocator());
    defer arena.deinit();
    const a = arena.allocator();

    const first = try a.alloc(u8, 64);
    try testing.expectEqual(1, child.allocs);
    const node_len = arena.used.?.size;
    try testing.expect(node_len < chunk.len);

    // Past the node's end: it grows into the chunk, no new node.
    var prev = first;
    var total: usize = first.len;
    while (total + 100 <= chunk.len - @sizeOf(LocalArena.Node)) : (total += 100) {
        const next = try a.alloc(u8, 100);
        try testing.expect(next.ptr == prev.ptr + prev.len);
        prev = next;
    }
    try testing.expectEqual(1, child.allocs);
    try testing.expect(arena.used.?.next == null);
    try testing.expect(child.resizes > 0);

    // Beyond the chunk: a second node.
    _ = try a.alloc(u8, chunk.len);
    try testing.expectEqual(2, child.allocs);
    try testing.expect(arena.used.?.next != null);

    // Reset to the chunk, as `RequestBuffers` keeps it.
    try testing.expect(arena.reset(.{ .retain_with_limit = chunk.len - 64 }));
    try testing.expect(arena.used.?.next == null);
    try testing.expect(@intFromPtr(arena.used.?) == @intFromPtr(&chunk));
    try testing.expectEqual(chunk.len - 64, arena.queryCapacity());
}

/// The child allocator calls an arena makes, logged, over
/// `testing.allocator`. It never resizes in place: the case where
/// LocalArena and std must agree to the byte (with in-place growth std
/// counts a failed bump twice).
const LoggingChild = struct {
    log: std.ArrayList(Call) = .empty,
    /// Every block it handed out, to log block numbers rather than pointers.
    blocks: std.ArrayList([]u8) = .empty,

    /// A resize's length is not compared: std asks for one allocation more
    /// than LocalArena does (it is refused either way).
    const Call = struct { kind: enum { alloc, resize, free }, len: usize, block: usize };

    fn allocator(self: *LoggingChild) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = lAlloc,
            .resize = lResize,
            .remap = Allocator.noRemap,
            .free = lFree,
        } };
    }

    fn append(self: *LoggingChild, call: Call) void {
        self.log.append(testing.allocator, call) catch @panic("OOM");
    }

    /// The block `bytes` are in, the most recent one, and where in it.
    fn locate(self: *LoggingChild, bytes: []const u8) [2]usize {
        var i = self.blocks.items.len;
        while (i > 0) {
            i -= 1;
            const b = self.blocks.items[i];
            const p = @intFromPtr(bytes.ptr);
            if (p >= @intFromPtr(b.ptr) and p + bytes.len <= @intFromPtr(b.ptr) + b.len)
                return .{ i, p - @intFromPtr(b.ptr) };
        }
        unreachable;
    }

    /// Every block as aligned as the test's largest alignment, so where an
    /// allocation lands in it does not depend on the block's address.
    const block_alignment: Alignment = .@"64";

    fn lAlloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret: usize) ?[*]u8 {
        const self: *LoggingChild = @ptrCast(@alignCast(ctx));
        assert(alignment.compare(.lte, block_alignment));
        const p = testing.allocator.rawAlloc(len, block_alignment, ret) orelse return null;
        self.blocks.append(testing.allocator, p[0..len]) catch @panic("OOM");
        self.append(.{ .kind = .alloc, .len = len, .block = self.blocks.items.len - 1 });
        return p;
    }

    fn lResize(ctx: *anyopaque, memory: []u8, _: Alignment, _: usize, _: usize) bool {
        const self: *LoggingChild = @ptrCast(@alignCast(ctx));
        self.append(.{ .kind = .resize, .len = 0, .block = self.locate(memory)[0] });
        return false;
    }

    fn lFree(ctx: *anyopaque, memory: []u8, _: Alignment, ret: usize) void {
        const self: *LoggingChild = @ptrCast(@alignCast(ctx));
        self.append(.{ .kind = .free, .len = memory.len, .block = self.locate(memory)[0] });
        testing.allocator.rawFree(memory, block_alignment, ret);
    }

    fn deinit(self: *LoggingChild) void {
        self.log.deinit(testing.allocator);
        self.blocks.deinit(testing.allocator);
    }
};

test "LocalArena: the same child calls, offsets and capacities as std's arena" {
    var ours_child: LoggingChild = .{};
    defer ours_child.deinit();
    var std_child: LoggingChild = .{};
    defer std_child.deinit();
    var ours: LocalArena = .init(ours_child.allocator());
    defer ours.deinit();
    var theirs: std.heap.ArenaAllocator = .init(std_child.allocator());
    defer theirs.deinit();

    var prng = std.Random.DefaultPrng.init(0x171);
    const random = prng.random();
    var last_ours: []u8 = &.{};
    var last_theirs: []u8 = &.{};
    for (0..4000) |_| {
        switch (random.uintLessThan(u8, 100)) {
            0...69 => {
                const len = random.intRangeAtMost(usize, 1, if (random.boolean()) 64 else 3000);
                const alignment: Alignment = .fromByteUnits(@as(usize, 1) << random.uintLessThan(u3, 7));
                const o = ours.allocator().rawAlloc(len, alignment, 0).?;
                const t = theirs.allocator().rawAlloc(len, alignment, 0).?;
                try testing.expectEqual(std_child.locate(t[0..len]), ours_child.locate(o[0..len]));
                last_ours = o[0..len];
                last_theirs = t[0..len];
            },
            70...84 => if (last_ours.len > 0) {
                const new_len = random.intRangeAtMost(usize, 1, last_ours.len * 2);
                const ro = ours.allocator().rawResize(last_ours, .@"1", new_len, 0);
                const rt = theirs.allocator().rawResize(last_theirs, .@"1", new_len, 0);
                try testing.expectEqual(rt, ro);
                if (ro) {
                    last_ours = last_ours.ptr[0..new_len];
                    last_theirs = last_theirs.ptr[0..new_len];
                }
            },
            85...94 => if (last_ours.len > 0) {
                ours.allocator().rawFree(last_ours, .@"1", 0);
                theirs.allocator().rawFree(last_theirs, .@"1", 0);
                last_ours = &.{};
                last_theirs = &.{};
            },
            else => {
                const mode: LocalArena.ResetMode = switch (random.uintLessThan(u8, 3)) {
                    0 => .free_all,
                    1 => .retain_capacity,
                    else => .{ .retain_with_limit = random.intRangeAtMost(usize, 0, 8192) },
                };
                try testing.expectEqual(theirs.reset(mode), ours.reset(mode));
                last_ours = &.{};
                last_theirs = &.{};
            },
        }
        try testing.expectEqual(theirs.queryCapacity(), ours.queryCapacity());
        try testing.expectEqual(std_child.log.items.len, ours_child.log.items.len);
    }
    for (std_child.log.items, ours_child.log.items) |t, o| try testing.expectEqual(t, o);
}

test "LocalArena: a hand-off between threads, one at a time" {
    var arena: LocalArena = .init(testing.allocator);
    defer arena.deinit();
    const Job = struct {
        fn run(a: *LocalArena, ok: *bool) void {
            const s = a.allocator().alloc(u8, 100) catch return;
            @memset(s, 0x42);
            ok.* = a.reset(.retain_capacity);
            _ = a.allocator().dupe(u8, "from the other thread") catch return;
        }
    };
    _ = try arena.allocator().alloc(u8, 500);
    var ok = false;
    // As a blocking-pool job: the owner waits for it to end.
    const t = try std.Thread.spawn(.{}, Job.run, .{ &arena, &ok });
    t.join();
    try testing.expect(ok);
    // Back with the owner, after the join.
    const s = try arena.allocator().alloc(u8, 32);
    try testing.expectEqual(32, s.len);
    try testing.expect(arena.queryCapacity() >= 500);
}
