//! The sealable push list (push_list.zig) under real threads (SAFETY.md L7:
//! each hand-off wrapper has a multi-thread stress test). Producers and the
//! consumer are plain OS threads (SAFETY.md §6a); nothing waits on time:
//! the consumer takes until it has seen every node, and every outcome is
//! checked node by node. Seeds are fixed (TESTING.md D4) and printed on a
//! failure.
//!
//! - FIFO: every node is taken exactly once, in push order per producer.
//! - Seal race: a node whose push succeeded was taken (by `takeAll` or by
//!   the seal); one whose push failed (`Closed`) was not. None is lost.
//!
//! The unit suite runs small seeded rounds (W1); `zig build test-stress`
//! runs the full ones ("[stress]", W3).
const std = @import("std");
const dusty = @import("dusty");
const wait = @import("anole_test_wait");
const push_list = dusty.push_list;
const Node = push_list.Node;
const PushList = push_list.PushList;

const alloc = std.testing.allocator;

const Item = struct {
    node: Node = .{},
    producer: u32,
    seq: u32,
    /// Its push returned success (set by the producer after it).
    pushed: std.atomic.Value(bool) = .init(false),
    /// Taken by the consumer (`takeAll` or the seal).
    taken: std.atomic.Value(u32) = .init(0),

    fn of(n: *Node) *Item {
        return @fieldParentPtr("node", n);
    }
};

const Round = struct {
    list: PushList = .{},
    items: []Item,
    producers: u32,
    per: u32,

    fn init(producers: u32, per: u32) !Round {
        const items = try alloc.alloc(Item, @as(usize, producers) * per);
        for (items, 0..) |*it, i| it.* = .{ .producer = @intCast(i / per), .seq = @intCast(i % per) };
        return .{ .items = items, .producers = producers, .per = per };
    }

    fn deinit(r: *Round) void {
        alloc.free(r.items);
    }

    fn total(r: *const Round) usize {
        return r.items.len;
    }

    /// One producer: pushes its items in order, until the list is sealed.
    fn produce(r: *Round, p: u32) void {
        for (r.items[@as(usize, p) * r.per ..][0..r.per]) |*it| {
            _ = r.list.push(&it.node) catch return;
            it.pushed.store(true, .release);
        }
    }

    /// Takes a chain (oldest first), checking FIFO per producer.
    fn consume(r: *Round, chain: ?*Node, next_seq: []u32, bad: *usize) usize {
        var n = chain;
        var got: usize = 0;
        while (n) |node| {
            n = node.next;
            const it = Item.of(node);
            if (it.taken.fetchAdd(1, .acq_rel) != 0) bad.* += 1;
            if (it.seq != next_seq[it.producer]) bad.* += 1;
            next_seq[it.producer] = it.seq + 1;
            got += 1;
        }
        _ = r;
        return got;
    }

    fn startProducers(r: *Round, threads: []std.Thread) !void {
        for (threads, 0..) |*t, p| t.* = try std.Thread.spawn(.{}, produce, .{ r, @as(u32, @intCast(p)) });
    }
};

/// Every node taken once, FIFO per producer.
fn fifo(producers: u32, per: u32) !void {
    var r = try Round.init(producers, per);
    defer r.deinit();
    const next_seq = try alloc.alloc(u32, producers);
    defer alloc.free(next_seq);
    @memset(next_seq, 0);
    const threads = try alloc.alloc(std.Thread, producers);
    defer alloc.free(threads);
    try r.startProducers(threads);
    var bad: usize = 0;
    var got: usize = 0;
    while (got < r.total()) {
        const chain = r.list.takeAll();
        if (chain == null) {
            std.Thread.yield() catch {};
            continue;
        }
        got += r.consume(chain, next_seq, &bad);
    }
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(usize, 0), bad);
    try std.testing.expectEqual(r.total(), got);
    try std.testing.expect(r.list.isEmpty());
    for (r.items) |*it| try std.testing.expectEqual(@as(u32, 1), it.taken.load(.acquire));
}

/// The consumer seals after `seal_after` nodes: every successful push was
/// taken exactly once, every refused one was not.
fn sealRace(seed: u64, producers: u32, per: u32) !void {
    var r = try Round.init(producers, per);
    defer r.deinit();
    var prng: std.Random.DefaultPrng = .init(seed);
    const seal_after = prng.random().uintLessThan(usize, r.total());
    const next_seq = try alloc.alloc(u32, producers);
    defer alloc.free(next_seq);
    @memset(next_seq, 0);
    const threads = try alloc.alloc(std.Thread, producers);
    defer alloc.free(threads);
    try r.startProducers(threads);
    var bad: usize = 0;
    var got: usize = 0;
    while (got < seal_after) {
        const chain = r.list.takeAll();
        if (chain == null) {
            std.Thread.yield() catch {};
            continue;
        }
        got += r.consume(chain, next_seq, &bad);
    }
    got += r.consume(r.list.seal(), next_seq, &bad);
    for (threads) |t| t.join();
    var pushed: usize = 0;
    for (r.items) |*it| {
        const ok = it.pushed.load(.acquire);
        const taken = it.taken.load(.acquire);
        if (ok) pushed += 1;
        if (taken != @intFromBool(ok)) {
            std.debug.print("push_list seal race, seed {d}: producer {d} item {d}: pushed {}, taken {d} times\n", .{ seed, it.producer, it.seq, ok, taken });
            bad += 1;
        }
    }
    if (bad != 0) std.debug.print("push_list seal race, seed {d}: {d} bad\n", .{ seed, bad });
    try std.testing.expectEqual(@as(usize, 0), bad);
    try std.testing.expectEqual(pushed, got);
    try std.testing.expectError(error.Closed, r.list.push(&r.items[0].node));
}

test "push_list: from four threads every node is taken once, in order per producer" {
    try fifo(4, 2_000);
}

test "push_list: a push racing the seal is either taken or refused, never lost" {
    for (0..8) |seed| try sealRace(seed, 4, 500);
}

test "push_list: [stress] eight producers of 100k nodes each, taken once and in order" {
    try wait.requireStress();
    try fifo(8, 100_000);
}

test "push_list: [stress] pushes racing the seal, 200 seeded rounds, none lost" {
    try wait.requireStress();
    for (0..200) |seed| try sealRace(0x5eed_0000 + seed, 8, 5_000);
}
