//! Tests for streams.zig. The closed-stream scenarios follow the fork patch's
//! session tests (xuckless/nghttp2 0f8bc1c, tests/nghttp2_session_test.c
//! around :4900, :9912 and :12304) at the structure level; conn.zig's tests
//! cover them frame by frame.

const std = @import("std");
const streams = @import("streams.zig");
const Stream = streams.Stream;
const Slab = streams.Slab;
const StreamTable = streams.StreamTable;
const ClosedRing = streams.ClosedRing;
const OpenedBitmap = streams.OpenedBitmap;
const Fate = streams.Fate;

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;

/// Every entry sits psl-1 slots after its home slot.
fn checkPsl(t: *const StreamTable) !void {
    const mask = t.slots() - 1;
    var n: usize = 0;
    for (0..t.slots()) |i| {
        if (t.psl[i] == 0) continue;
        n += 1;
        try expectEqual(t.vals[i].id, t.keys[i]);
        try expectEqual(t.psl[i] - 1, (i -% t.index(t.keys[i])) & mask);
    }
    try expectEqual(t.size, n);
}

test "h2 streams: table insert, find, remove at load with collisions and wrap" {
    var slab: Slab = .init(testing.allocator);
    defer slab.deinit();
    var t: StreamTable = .init(testing.allocator, 100, 0);
    defer t.deinit();

    // A first insert sizes the table to 16 slots, so homes can be computed.
    const probe = try slab.create(1, 0, 0);
    try t.insert(probe);
    try expectEqual(16, t.slots());
    try expect(t.remove(1));

    // Five odd IDs whose home is the last slot (so their probes wrap to slot
    // 0) and three whose home is slot 0: 8 entries, the most 16 slots hold.
    var keys: [8]u31 = undefined;
    var n_last: usize = 0;
    var n_first: usize = 0;
    var id: u31 = 3;
    while (n_last < 5 or n_first < 3) : (id += 2) {
        const home = t.index(id);
        if (home == 15 and n_last < 5) {
            keys[n_last] = id;
            n_last += 1;
        } else if (home == 0 and n_first < 3) {
            keys[5 + n_first] = id;
            n_first += 1;
        }
    }
    for (keys) |k| try t.insert(try slab.create(k, 0, 0));
    try expectEqual(16, t.slots());
    try expectEqual(8, t.size);
    try checkPsl(&t);
    for (keys) |k| try expectEqual(k, t.get(k).?.id);
    // The chain runs 15, 0, 1, ...: something wrapped.
    try expect(t.psl[0] != 0 and t.psl[15] != 0);

    // Remove from the middle of the chain: the rest shift back and stay
    // findable, with no tombstones.
    try expect(t.remove(keys[2]));
    try expect(t.remove(keys[6]));
    try expect(!t.remove(keys[2]));
    try expect(t.get(keys[2]) == null);
    try expect(t.get(keys[6]) == null);
    try checkPsl(&t);
    for (keys, 0..) |k, i| {
        if (i == 2 or i == 6) continue;
        try expectEqual(k, t.get(k).?.id);
    }
    // The last entry of the run moved back, leaving its old slot empty.
    var empty: usize = 0;
    for (0..t.slots()) |i| empty += @intFromBool(t.psl[i] == 0);
    try expectEqual(10, empty);

    // A never-seen key that shares the home is a miss, found or removed.
    while (t.index(id) != 15) id += 2;
    try expect(t.get(id) == null);
    try expect(!t.remove(id));
    try checkPsl(&t);
}

fn randomOps(seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rand = prng.random();

    var slab: Slab = .init(testing.allocator);
    defer slab.deinit();
    var t: StreamTable = .init(testing.allocator, 1000, seed);
    defer t.deinit();
    var oracle: std.AutoHashMap(u31, *Stream) = .init(testing.allocator);
    defer oracle.deinit();
    var live: std.ArrayList(u31) = .empty;
    defer live.deinit(testing.allocator);
    var removed: std.ArrayList(u31) = .empty;
    defer removed.deinit(testing.allocator);

    var next_id: u31 = 1;
    for (0..100_000) |op| {
        // Bursts to 1000 live streams cover growth; the rest stays at 256.
        const cap: usize = if (op % 10_000 < 2_000) 1000 else 256;
        const r = rand.uintLessThan(u32, 100);
        if (r < 40 and live.items.len < cap) {
            next_id += 2 * rand.uintLessThan(u31, 3) + 2;
            const s = try slab.create(next_id, 0, 0);
            try t.insert(s);
            try oracle.put(next_id, s);
            try live.append(testing.allocator, next_id);
            try expectEqual(s, t.get(next_id).?);
        } else if (r < 75 and live.items.len > 0) {
            const k = live.swapRemove(rand.uintLessThan(usize, live.items.len));
            const s = oracle.get(k).?;
            try expect(t.remove(k));
            try expect(oracle.remove(k));
            slab.destroy(s);
            try expect(t.get(k) == null);
            if (removed.items.len < 4096) try removed.append(testing.allocator, k);
        } else {
            const k: u31 = switch (rand.uintLessThan(u32, 3)) {
                0 => if (live.items.len > 0) live.items[rand.uintLessThan(usize, live.items.len)] else 2,
                1 => if (removed.items.len > 0) removed.items[rand.uintLessThan(usize, removed.items.len)] else 4,
                else => if (rand.boolean()) next_id + 2 else 2 * rand.uintLessThan(u31, 1 << 29),
            };
            try expectEqual(oracle.get(k), t.get(k));
        }
        try expectEqual(oracle.count(), t.size);
    }

    try checkPsl(&t);
    var seen: usize = 0;
    var i: usize = 0;
    while (t.next(&i)) |s| {
        try expectEqual(s, oracle.get(s.id).?);
        seen += 1;
    }
    try expectEqual(oracle.count(), seen);
}

test "h2 streams: table matches std.AutoHashMap under random ops" {
    for ([_]u64{ 0, 0x5eed, 0xdead_beef_cafe }) |seed| try randomOps(seed);
}

test "h2 streams: table grows by doubling and never shrinks" {
    var slab: Slab = .init(testing.allocator);
    defer slab.deinit();
    var counting: testing.FailingAllocator = .init(testing.allocator, .{});
    var t: StreamTable = .init(counting.allocator(), 250, 0x1234);
    defer t.deinit();

    try expectEqual(0, t.slots());
    try expectEqual(0, counting.allocations);
    var ptrs: [250]*Stream = undefined;
    var sizes: [8]usize = undefined;
    var n_sizes: usize = 0;
    for (&ptrs, 0..) |*p, i| {
        p.* = try slab.create(@intCast(2 * i + 1), 0, 0);
        try t.insert(p.*);
        if (n_sizes == 0 or sizes[n_sizes - 1] != t.slots()) {
            sizes[n_sizes] = t.slots();
            n_sizes += 1;
        }
    }
    try expectEqualSlices(&.{ 16, 32, 64, 128, 256, 512 }, sizes[0..n_sizes]);
    try expectEqual(6, counting.allocations);

    for (ptrs) |p| try expect(t.remove(p.id));
    try expectEqual(0, t.size);
    try expectEqual(512, t.slots());
    // A refill with new IDs reuses the table: no allocation.
    for (ptrs, 0..) |p, i| {
        p.id = @intCast(1001 + 2 * i);
        try t.insert(p);
    }
    try expectEqual(6, counting.allocations);
    try expectEqual(512, t.slots());
    try checkPsl(&t);
}

fn expectEqualSlices(expected: []const usize, actual: []const usize) !void {
    try testing.expectEqualSlices(usize, expected, actual);
}

test "h2 streams: slab reuses streams without leaks" {
    var counting: testing.FailingAllocator = .init(testing.allocator, .{});
    var slab: Slab = .init(counting.allocator());
    defer slab.deinit();

    var ptrs: [100]*Stream = undefined;
    for (&ptrs, 0..) |*p, i| p.* = try slab.create(@intCast(2 * i + 1), 65535, 65535);
    try expectEqual(4, counting.allocations); // ceil(100 / 32)
    // Pointers stay put as chunks are added.
    for (ptrs, 0..) |p, i| {
        try expectEqual(2 * i + 1, p.id);
        try expectEqual(.idle, p.state);
        try expectEqual(-1, p.content_left);
    }

    for (ptrs) |p| slab.destroy(p);
    if (std.debug.runtime_safety) try expectEqual(0, ptrs[0].id);
    for (&ptrs, 0..) |*p, i| p.* = try slab.create(@intCast(1001 + 2 * i), 0, 0);
    try expectEqual(4, counting.allocations);

    // LIFO: the last destroyed is the first created.
    const a = ptrs[42];
    slab.destroy(a);
    const b = try slab.create(7777, 1, 2);
    try expectEqual(a, b);
    try expectEqual(7777, b.id);
    try expectEqual(1, b.send_window);
    try expectEqual(2, b.recv_window);
    try expectEqual(0, b.recv_unacked);
    try expectEqual(streams.Flags{}, b.flags);
    try expectEqual(4, counting.allocations);
}

test "h2 streams: stream window updates" {
    const update = streams.updateInitialWindow;
    const max = std.math.maxInt(i32);
    const min = std.math.minInt(i32);

    var w: i32 = 100;
    try update(&w, 0, 65535); // the peer lowers the initial window
    try expectEqual(100 - 65535, w);
    try update(&w, 65535, 0);
    try expectEqual(100, w);

    w = max - 10;
    try testing.expectError(error.FlowControl, update(&w, 20, 0));
    try expectEqual(max - 10, w); // untouched
    try update(&w, 10, 0);
    try expectEqual(max, w);

    w = min + 10;
    try update(&w, 0, 10);
    try expectEqual(min, w);
    try testing.expectError(error.FlowControl, update(&w, 0, 1));
    try expectEqual(min, w);
}

test "h2 streams: content-length checks" {
    var s: Stream = .{ .id = 1, .send_window = 0, .recv_window = 0 };
    // None declared: anything goes.
    try s.onDataChunk(1 << 40);
    try s.onRemoteEnd();

    s.content_left = 10;
    try s.onDataChunk(4);
    try testing.expectError(error.Malformed, s.onRemoteEnd()); // short
    try s.onDataChunk(6);
    try s.onRemoteEnd(); // exact
    try testing.expectError(error.Malformed, s.onDataChunk(1)); // over

    s.content_left = 3;
    try testing.expectError(error.Malformed, s.onDataChunk(4));

    s.content_left = 0; // content-length: 0
    try s.onDataChunk(0);
    try s.onRemoteEnd();
    try testing.expectError(error.Malformed, s.onDataChunk(1));
}

test "h2 streams: stream states" {
    var s: Stream = .{ .id = 1, .send_window = 0, .recv_window = 0, .state = .open };
    try expect(s.canRecv() and s.canSend());
    s.recvEnd();
    try expectEqual(.half_closed_remote, s.state);
    try expect(!s.canRecv() and s.canSend());
    s.sendEnd();
    try expectEqual(.closed, s.state);

    s.state = .open;
    s.sendEnd();
    try expectEqual(.half_closed_local, s.state);
    try expect(s.canRecv() and !s.canSend());
    s.recvEnd();
    try expectEqual(.closed, s.state);
    try expect(!s.canRecv() and !s.canSend());
}

test "h2 streams: closed ring evicts the oldest and answers how" {
    var r: ClosedRing = .{};
    const fates = [_]Fate{ .rst_received, .end_stream, .rst_sent };
    for (0..300) |i| r.record(@intCast(2 * i + 1), fates[i % 3]);
    for (0..300) |i| {
        const want: Fate = if (i < 44) .unknown else fates[i % 3];
        try expectEqual(want, r.lookup(@intCast(2 * i + 1)));
    }
    try expectEqual(.unknown, r.lookup(1001)); // never recorded

    // The highest ID survives the u30 packing; its neighbour doesn't alias.
    const top: u31 = std.math.maxInt(u31);
    r.record(top, .rst_sent);
    try expectEqual(.rst_sent, r.lookup(top));
    try expectEqual(.unknown, r.lookup(top - 2));
}

test "h2 streams: opened bitmap slides its window" {
    var b: OpenedBitmap = .{};
    b.markOpened(0, 1);
    b.markOpened(1, 3);
    b.markOpened(3, 7); // 5 skipped
    try expect(b.neverOpened(7, 5));
    try expect(!b.neverOpened(7, 3));
    try expect(!b.neverOpened(7, 1));
    try expect(!b.neverOpened(7, 7)); // last_recv itself
    try expect(!b.neverOpened(7, 9)); // above last_recv: idle, not this question

    // A gap of 2047 skipped IDs (one short of the window) clears them one by
    // one; 7 is now out of the window and so unknown, not never opened.
    var a = b;
    a.markOpened(7, 4103);
    try expect(a.neverOpened(4103, 9));
    try expect(a.neverOpened(4103, 4101));
    try expect(!a.neverOpened(4103, 7));
    try expect(!a.neverOpened(4103, 5));

    // A gap of 2048 wipes the map; every ID in the window was skipped.
    a = b;
    a.markOpened(7, 4105);
    try expect(!a.neverOpened(4105, 9)); // just out of the window
    try expect(a.neverOpened(4105, 11));
    try expect(a.neverOpened(4105, 4103));

    // Opened streams inside the window stay opened as it slides.
    b.markOpened(7, 9);
    b.markOpened(9, 11);
    try expect(!b.neverOpened(11, 9));
    try expect(b.neverOpened(11, 5));

    // The client of a server-role connection starts at 1; at 3 means 1 was
    // skipped.
    var c: OpenedBitmap = .{};
    c.markOpened(0, 3);
    try expect(c.neverOpened(3, 1));
}

test "h2 streams: peerFate follows the patch" {
    var r: ClosedRing = .{};
    var b: OpenedBitmap = .{};
    var last: u31 = 0;
    for ([_]u31{ 1, 5 }) |id| {
        b.markOpened(last, id);
        last = id;
    }
    // HEADERS on 3, below the highest opened and never opened itself:
    // connection error PROTOCOL_ERROR in conn.zig (anole_strict_frames).
    try expectEqual(.never_opened, streams.peerFate(&r, &b, last, 3));
    // 1 closed and forgotten (not in the ring): ignored.
    try expectEqual(.unknown, streams.peerFate(&r, &b, last, 1));
    // Above last_recv: never never_opened.
    try expectEqual(.unknown, streams.peerFate(&r, &b, last, 7));

    // The ring wins over the bitmap.
    r.record(1, .rst_received); // DATA after the peer's RST: STREAM_CLOSED
    try expectEqual(.rst_received, streams.peerFate(&r, &b, last, 1));
    r.record(3, .rst_sent);
    try expectEqual(.rst_sent, streams.peerFate(&r, &b, last, 3));
    // Closed by END_STREAM: a connection error STREAM_CLOSED in conn.zig.
    r.record(5, .end_stream);
    try expectEqual(.end_stream, streams.peerFate(&r, &b, last, 5));
}

test "h2 streams: sizes" {
    try expect(@sizeOf(Stream) <= 64);
    try expectEqual(1028, @sizeOf(ClosedRing));
    try expectEqual(256, @sizeOf(OpenedBitmap));
    // The closed-stream memory per connection, against the patch's 2313 B.
    try expectEqual(1284, @sizeOf(ClosedRing) + @sizeOf(OpenedBitmap));
    try expect(@sizeOf(Slab.Chunk) <= 32 * 64 + 8);
}
