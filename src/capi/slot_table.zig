//! The chunked, generation-checked slot table every C ABI object kind
//! (connections, sockets, subscribers, transfers, transactions, WebTransport
//! sessions and streams) keeps per executor: grown a chunk at a time, a
//! slot never moved or freed until the engine goes, so a stale or made-up
//! handle always lands on a slot whose generation says it is gone.
//!
//! A slot type has `word: std.atomic.Value(u64)` (generation in the high
//! half), `exec`, `index`, and `next_free`. The free list is plain
//! (executor-local) unless `locked`, which puts a spin lock around `alloc`
//! and `free` (tables whose slots are also taken from consumer threads).
//! `nchunks` is atomic: `forEach`, `maxGen` and `deinit` read it from
//! another thread at the stop.
const std = @import("std");
const engine = @import("engine.zig");

const Exec = engine.Exec;
const gpa = engine.gpa;

pub fn spin(l: *std.atomic.Mutex) void {
    while (!l.tryLock()) std.atomic.spinLoopHint();
}

pub const Options = struct {
    chunk_len: u32,
    max_chunks: u32,
    /// What `alloc` returns when the table is full.
    full: anyerror,
    locked: bool = false,
    /// The `Handle` kind of this table's slots.
    kind: engine.Handle.Kind,
    /// The area's `open` state as stored in the low half of the slot word.
    open: u32,
};

/// `free_word(gen)` is the slot word of a free slot of that generation.
pub fn SlotTable(comptime T: type, comptime opts: Options, comptime free_word: fn (u32) u64) type {
    return struct {
        const Self = @This();
        const chunk_len = opts.chunk_len;
        const max_chunks = opts.max_chunks;
        const Chunk = [chunk_len]T;
        comptime {
            std.debug.assert(chunk_len * max_chunks <= engine.max_slots);
        }

        chunks: [max_chunks]std.atomic.Value(?*Chunk) = @splat(.init(null)),
        nchunks: std.atomic.Value(u32) = .init(0),
        free_head: u32 = engine.no_slot,
        lock: if (opts.locked) std.atomic.Mutex else void = if (opts.locked) .unlocked else {},

        pub fn gen(s: *const T) u32 {
            return @intCast(s.word.load(.acquire) >> 32);
        }

        pub fn live(s: *const T, g: u32) bool {
            return s.word.load(.acquire) == (@as(u64, g) << 32 | opts.open);
        }

        pub fn handle(s: *const T, g: u32) u64 {
            return engine.Handle.encode(.{ .gen = @intCast(g), .kind = opts.kind, .slot = @intCast(s.index), .exec = s.exec.index });
        }

        pub fn slot(t: *Self, i: u32) ?*T {
            // `i` may come from a made-up handle: past the table is nothing.
            if (i / chunk_len >= max_chunks) return null;
            const c = t.chunks[i / chunk_len].load(.acquire) orelse return null;
            return &c[i % chunk_len];
        }

        pub fn alloc(t: *Self, x: *Exec) anyerror!*T {
            if (opts.locked) spin(&t.lock);
            defer if (opts.locked) t.lock.unlock();
            if (t.free_head == engine.no_slot) {
                const n = t.nchunks.load(.monotonic);
                if (n == max_chunks) return opts.full;
                const c = try gpa.create(Chunk);
                const base = n * chunk_len;
                for (c, 0..) |*s, j| s.* = .{
                    .word = .init(free_word(x.engine.first_gen)),
                    .exec = x,
                    .index = @intCast(base + j),
                    .next_free = if (j + 1 < chunk_len) @intCast(base + j + 1) else engine.no_slot,
                };
                t.chunks[n].store(c, .release);
                t.nchunks.store(n + 1, .release);
                t.free_head = base;
            }
            const s = t.slot(t.free_head).?;
            t.free_head = s.next_free;
            return s;
        }

        /// Puts the slot on the free list (the caller has already bumped
        /// its generation).
        pub fn free(t: *Self, s: *T) void {
            if (opts.locked) spin(&t.lock);
            defer if (opts.locked) t.lock.unlock();
            s.next_free = t.free_head;
            t.free_head = s.index;
        }

        /// Any thread.
        pub fn forEach(t: *const Self, comptime f: fn (*T) void) void {
            for (t.chunks[0..t.nchunks.load(.acquire)]) |*cv| {
                for (cv.load(.acquire).?) |*s| f(s);
            }
        }

        /// The highest generation of any slot (`Engine.destroy`).
        pub fn maxGen(t: *const Self) u32 {
            var max: u32 = 0;
            for (t.chunks[0..t.nchunks.load(.acquire)]) |*cv| {
                for (cv.load(.acquire).?) |*s| max = @max(max, @as(u32, @intCast(s.word.load(.acquire) >> 32)));
            }
            return max;
        }

        /// Frees the chunks, `cleanup` first on each slot.
        pub fn deinit(t: *Self, comptime cleanup: ?fn (*T) void) void {
            for (t.chunks[0..t.nchunks.load(.acquire)]) |*cv| {
                const c = cv.load(.acquire).?;
                if (cleanup) |f| for (c) |*s| f(s);
                gpa.destroy(c);
            }
            t.nchunks.store(0, .release);
        }
    };
}

test "accessors: live, stale generation, wrapped generation, handle kind and bytes, per table" {
    const Slot = struct {
        word: std.atomic.Value(u64),
        exec: *Exec,
        index: u32,
        next_free: u32,
    };
    const Free = struct {
        fn word(g: u32) u64 {
            return @as(u64, g) << 32;
        }
    };
    const kinds = [_]engine.Handle.Kind{ .websocket, .wt_session, .wt_stream, .net_conn, .sse, .transfer, .db_tx };
    var x: Exec = undefined;
    x.index = 2;
    inline for (kinds) |kind| {
        const Table = SlotTable(Slot, .{ .chunk_len = 4, .max_chunks = 1, .full = error.Full, .kind = kind, .open = 1 }, Free.word);
        var s: Slot = .{ .word = .init(Free.word(7)), .exec = &x, .index = 3, .next_free = engine.no_slot };
        try std.testing.expectEqual(@as(u32, 7), Table.gen(&s));
        try std.testing.expect(!Table.live(&s, 7));
        s.word.store(@as(u64, 7) << 32 | 1, .release);
        try std.testing.expect(Table.live(&s, 7));
        try std.testing.expect(!Table.live(&s, 6));
        s.word.store(@as(u64, std.math.maxInt(u32)) << 32 | 1, .release);
        try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), Table.gen(&s));
        try std.testing.expect(Table.live(&s, std.math.maxInt(u32)));
        try std.testing.expect(!Table.live(&s, 1));
        const h = engine.Handle.decode(Table.handle(&s, 5));
        try std.testing.expectEqual(kind, h.kind);
        try std.testing.expectEqual(@as(u28, 5), h.gen);
        try std.testing.expectEqual(@as(u23, 3), h.slot);
        try std.testing.expectEqual(@as(u8, 2), h.exec);
    }
    const T = SlotTable(Slot, .{ .chunk_len = 4, .max_chunks = 1, .full = error.Full, .kind = .wt_session, .open = 1 }, Free.word);
    var s: Slot = .{ .word = .init(0), .exec = &x, .index = 3, .next_free = engine.no_slot };
    try std.testing.expectEqual(@as(u64, 5 | 4 << 28 | 3 << 33 | 2 << 56), T.handle(&s, 5));
}

test "slot sizes unchanged since 1e5e86c7 (64-bit)" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    const features = @import("../root.zig").features;
    // ws and wt exist only with their features (engine.ws/engine.wt are empty otherwise).
    const sizes = (if (features.websocket) .{.{ engine.ws.WsSlot, 200 }} else .{}) ++
        (if (features.http3) .{ .{ engine.wt.SessionSlot, 192 }, .{ engine.wt.StreamSlot, 184 } } else .{}) ++ .{
        .{ @import("net.zig").NetSlot, 56 },
        .{ @import("sse.zig").SseSlot, 88 },
        .{ @import("s3.zig").TSlot, 72 },
        .{ @import("db.zig").TxSlot, 128 },
    };
    inline for (sizes) |row| try std.testing.expectEqual(@as(usize, row[1]), @sizeOf(row[0]));
}
