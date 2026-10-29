//! SAFETY.md L7's hand-off pattern: an intrusive, sealable MPSC push list.
//! Any thread pushes; one documented owner takes (`takeAll`) and, at the
//! end of the owner's life, seals it (`seal`): from then on a push fails
//! with `error.Closed`, so nothing is accepted and then lost.
//!
//! The list is one word: 0 empty, 1 sealed, else the newest node (each
//! node links to the one pushed before it). A push is one compare-and-swap,
//! a take one compare-and-swap that empties it, a seal one swap; the taker
//! reverses what it took, so it sees the nodes oldest first.
//!
//! Orderings: the push's CAS is `.seq_cst` and so is `isEmpty`'s load, so
//! a producer that pushes and then sets a "scheduled" word (`.seq_cst`), and
//! an owner that clears that word and then asks `isEmpty`, form the
//! store-buffering pair: either the producer sees the word clear (and wakes
//! the owner) or the owner sees the node (src/net/tcp.zig's outbox hand-back
//! depends on it). `takeAll` and `seal` take with `.acq_rel`, which orders
//! every node's contents (written before its push) before the taker reads
//! them.
//!
//! Stress test: push_list_test.zig (W1 seeds, and `[stress]` in
//! `zig build test-stress`).
const std = @import("std");

/// One element's link. Embed it in the element and get back to the element
/// with `@fieldParentPtr`. While a node is on a list, the list owns `next`.
pub const Node = struct {
    next: ?*Node = null,
};

/// An intrusive multi-producer, single-consumer list. owner (the taking
/// side): named by the struct that embeds it; producers: any thread.
pub const PushList = struct {
    /// 0: empty; 1: sealed; else the newest `*Node`.
    head: std.atomic.Value(usize) = .init(empty),

    const empty: usize = 0;
    const sealed: usize = 1;

    fn nodeOf(word: usize) ?*Node {
        if (word == empty or word == sealed) return null;
        // SAFETY: every other value of `head` is a `*Node` that `push` stored.
        return @ptrFromInt(word);
    }

    fn wordOf(n: *Node) usize {
        // SAFETY: a `*Node`'s address, never 0 or 1 (nodes are pointer-aligned).
        return @intFromPtr(n);
    }

    /// Any thread. Pushes `n` (whose `next` the list now owns). True when
    /// the list was empty before it: the owner may be idle, wake it.
    /// `error.Closed`: the list is sealed and `n` was not taken; it is still
    /// the caller's.
    pub fn push(l: *PushList, n: *Node) error{Closed}!bool {
        var cur = l.head.load(.monotonic);
        while (true) {
            if (cur == sealed) return error.Closed;
            n.next = nodeOf(cur);
            cur = l.head.cmpxchgWeak(cur, wordOf(n), .seq_cst, .monotonic) orelse return cur == empty;
        }
    }

    /// Owner only. Takes every node pushed so far, oldest first (linked by
    /// `next`), or null when there is none. A sealed list stays sealed.
    pub fn takeAll(l: *PushList) ?*Node {
        var cur = l.head.load(.monotonic);
        while (true) {
            if (cur == empty or cur == sealed) return null;
            cur = l.head.cmpxchgWeak(cur, empty, .acq_rel, .monotonic) orelse return reverse(nodeOf(cur));
        }
    }

    /// Owner only, once, at the end of its service: takes what is left,
    /// oldest first, and every later `push` fails with `error.Closed`.
    pub fn seal(l: *PushList) ?*Node {
        return reverse(nodeOf(l.head.swap(sealed, .acq_rel)));
    }

    /// Nothing waits on the list (it is empty or sealed). Any thread; see
    /// the orderings above.
    pub fn isEmpty(l: *const PushList) bool {
        const cur = l.head.load(.seq_cst);
        return cur == empty or cur == sealed;
    }

    pub fn isSealed(l: *const PushList) bool {
        return l.head.load(.acquire) == sealed;
    }

    fn reverse(newest: ?*Node) ?*Node {
        var rest = newest;
        var out: ?*Node = null;
        while (rest) |n| {
            rest = n.next;
            n.next = out;
            out = n;
        }
        return out;
    }
};

test "push_list: one thread pushes and takes in order; the first push reports empty" {
    var l: PushList = .{};
    var nodes: [4]Node = @splat(.{});
    try std.testing.expect(l.isEmpty());
    try std.testing.expect(try l.push(&nodes[0]));
    try std.testing.expect(!(try l.push(&nodes[1])));
    try std.testing.expect(!l.isEmpty());
    var it = l.takeAll();
    try std.testing.expectEqual(@as(?*Node, &nodes[0]), it);
    it = it.?.next;
    try std.testing.expectEqual(@as(?*Node, &nodes[1]), it);
    try std.testing.expectEqual(@as(?*Node, null), it.?.next);
    try std.testing.expectEqual(@as(?*Node, null), l.takeAll());
    try std.testing.expect(try l.push(&nodes[2]));
    // The seal hands over what is left, and refuses what comes after.
    try std.testing.expectEqual(@as(?*Node, &nodes[2]), l.seal());
    try std.testing.expectError(error.Closed, l.push(&nodes[3]));
    try std.testing.expect(l.isEmpty());
    try std.testing.expect(l.isSealed());
    try std.testing.expectEqual(@as(?*Node, null), l.takeAll());
    try std.testing.expect(l.isSealed());
}
