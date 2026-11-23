//! Tests for blocks.zig against a real `Out` (its totals set directly) and a
//! stream queue of bare nodes; the roles' own paths are server_test.zig's
//! and src/h2/client_test.zig's.

const std = @import("std");
const blocks = @import("blocks.zig");
const Out = @import("out.zig").Out;
const Lend = blocks.Lend;
const Pair = blocks.Pair;
const Retire = blocks.Retire;

const testing = std.testing;

test "h2 blocks: Pair.roomFree, every state x observation and the queued-count rule" {
    const Row = struct { name: []const u8, cur: u1 = 0, lends: [2]Lend, queued: usize = 0, queued_total: u64 = 10, sent_total: u64 = 0, want: bool, after: [2]Lend, lent: bool };
    const rows = [_]Row{
        .{ .name = "never submitted", .lends = .{ .free, .free }, .want = true, .after = .{ .free, .free }, .lent = false },
        .{ .name = "other lent, cur never", .lends = .{ .free, .submitted }, .queued = 1, .want = true, .after = .{ .free, .submitted }, .lent = true },
        .{ .name = "submitted, still queued", .lends = .{ .submitted, .free }, .queued = 1, .want = false, .after = .{ .submitted, .free }, .lent = true },
        .{ .name = "submitted, queue empty, all written", .lends = .{ .submitted, .free }, .sent_total = 10, .want = true, .after = .{ .free, .free }, .lent = false },
        .{ .name = "submitted, queue empty, bytes unsent", .lends = .{ .submitted, .free }, .sent_total = 4, .want = false, .after = .{ .{ .framed = 10 }, .free }, .lent = true },
        .{ .name = "framed, short of the mark (not retaken)", .lends = .{ .{ .framed = 10 }, .free }, .queued_total = 20, .sent_total = 9, .want = false, .after = .{ .{ .framed = 10 }, .free }, .lent = true },
        .{ .name = "framed, past the mark", .lends = .{ .{ .framed = 10 }, .free }, .queued_total = 20, .sent_total = 10, .want = true, .after = .{ .free, .free }, .lent = false },
        .{ .name = "two lent, both queued", .lends = .{ .submitted, .submitted }, .queued = 2, .sent_total = 10, .want = false, .after = .{ .submitted, .submitted }, .lent = true },
        .{ .name = "two lent, only the other queued", .lends = .{ .submitted, .submitted }, .queued = 1, .sent_total = 10, .want = true, .after = .{ .free, .submitted }, .lent = true },
        .{ .name = "other lent but written still counts", .lends = .{ .submitted, .{ .framed = 5 } }, .queued = 1, .sent_total = 10, .want = true, .after = .{ .free, .{ .framed = 5 } }, .lent = true },
        .{ .name = "other lent but written, two queued", .lends = .{ .submitted, .{ .framed = 5 } }, .queued = 2, .sent_total = 10, .want = false, .after = .{ .submitted, .{ .framed = 5 } }, .lent = true },
        .{ .name = "cur is 1", .cur = 1, .lends = .{ .free, .submitted }, .sent_total = 10, .want = true, .after = .{ .free, .free }, .lent = false },
        .{ .name = "cur is 1, still queued", .cur = 1, .lends = .{ .free, .submitted }, .queued = 1, .want = false, .after = .{ .free, .submitted }, .lent = true },
    };
    var nodes: [2]std.DoublyLinkedList.Node = .{ .{}, .{} };
    for (rows) |row| {
        errdefer std.debug.print("row: {s}\n", .{row.name});
        var out: Out = .init(testing.allocator);
        defer out.deinit();
        out.queued_total = row.queued_total;
        out.sent_total = row.sent_total;
        var pending: std.DoublyLinkedList = .{};
        for (nodes[0..row.queued]) |*n| pending.append(n);
        var p: Pair = .{ .cur = row.cur, .blocks = .{ .{ .lend = row.lends[0] }, .{ .lend = row.lends[1] } } };
        try testing.expectEqual(row.want, p.roomFree(&pending, &out));
        try testing.expectEqual(row.after, [2]Lend{ p.blocks[0].lend, p.blocks[1].lend });
        try testing.expectEqual(row.cur, p.cur);
        try testing.expectEqual(row.lent, p.lent());
    }
    // lend flips: the block the writer filled is lent, the writer moves on.
    var p: Pair = .{};
    p.lend();
    try testing.expectEqual(@as(u1, 1), p.cur);
    try testing.expectEqual([2]Lend{ .submitted, .free }, [2]Lend{ p.blocks[0].lend, p.blocks[1].lend });
    p.lend();
    try testing.expectEqual(@as(u1, 0), p.cur);
    try testing.expect(p.blocks[1].lend == .submitted);
}

test "h2 blocks: Retire parks only what out still borrows, and pops in order once written" {
    var out: Out = .init(testing.allocator);
    defer out.deinit();
    var list: std.DoublyLinkedList = .{};
    var a: Retire = .{};
    var b: Retire = .{};

    // Nothing unsent: not parked.
    out.queued_total = 10;
    out.sent_total = 10;
    try testing.expect(!a.park(&list, &out));
    try testing.expect(list.first == null and a.mark == null);
    // Bytes unsent: parked at the mark.
    out.sent_total = 4;
    try testing.expect(a.park(&list, &out));
    try testing.expectEqual(@as(?u64, 10), a.mark);
    out.queued_total = 20;
    try testing.expect(b.park(&list, &out));
    // Before the mark: nobody leaves.
    try testing.expect(Retire.popPassed(&list, 9) == null);
    try testing.expectEqual(@as(?u64, 10), a.mark);
    // At the mark: the first leaves, the second waits for its own.
    try testing.expectEqual(&a, Retire.popPassed(&list, 10).?);
    try testing.expect(a.mark == null and list.first == &b.node);
    try testing.expect(Retire.popPassed(&list, 19) == null);
    // FIFO: a later owner whose mark passed waits behind an earlier one
    // (a smaller later mark only by setting the total back here).
    out.queued_total = 15;
    try testing.expect(a.park(&list, &out));
    try testing.expect(Retire.popPassed(&list, 17) == null);
    // The connection is gone: maxInt takes every one, in order.
    try testing.expectEqual(&b, Retire.popPassed(&list, std.math.maxInt(u64)).?);
    try testing.expectEqual(&a, Retire.popPassed(&list, std.math.maxInt(u64)).?);
    try testing.expect(list.first == null and a.mark == null and b.mark == null);
}
