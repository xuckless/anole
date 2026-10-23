//! Per-peer state for a UDP socket (design-net.md §4): a hash map keyed by
//! the peer's address and an LRU list ordered by the last datagram, so the
//! least recently heard-from peer is the first to expire. Pure: the caller
//! passes `now`, so the tests need no clock. The idea is QUIC's and ENet's
//! peer table; nothing in Zig's ecosystem offers one.
//!
//! A full table refuses a new peer and keeps the old ones: evicting would
//! let an attacker with spoofed sources churn real sessions out.
const std = @import("std");

/// A peer as a map key. An IPv4 peer of a dual-stack socket (IPv4-mapped
/// IPv6) and the same peer as plain IPv4 are one key.
pub const PeerKey = struct {
    family: u8,
    port: u16,
    addr: [16]u8,

    pub fn of(address: std.Io.net.IpAddress) PeerKey {
        switch (address) {
            .ip4 => |a| {
                var k: PeerKey = .{ .family = 4, .port = a.port, .addr = @splat(0) };
                @memcpy(k.addr[0..4], &a.bytes);
                return k;
            },
            .ip6 => |a| {
                if (std.mem.eql(u8, a.bytes[0..12], &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff })) {
                    var k: PeerKey = .{ .family = 4, .port = a.port, .addr = @splat(0) };
                    @memcpy(k.addr[0..4], a.bytes[12..16]);
                    return k;
                }
                return .{ .family = 6, .port = a.port, .addr = a.bytes };
            },
        }
    }
};

pub fn SessionTable(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Node = struct {
            key: PeerKey,
            /// `now` of the last datagram from the peer.
            last: i96,
            list: std.DoublyLinkedList.Node = .{},
            value: T,
        };

        gpa: std.mem.Allocator,
        map: std.AutoHashMapUnmanaged(PeerKey, *Node) = .empty,
        /// Oldest first.
        lru: std.DoublyLinkedList = .{},
        /// No datagram from a peer for this long ends its session.
        idle_ns: i96,
        /// Sessions at most.
        max: u32,
        /// New peers turned away because the table was full.
        refused: u64 = 0,

        pub fn init(gpa: std.mem.Allocator, idle_ns: i96, max: u32) Self {
            return .{ .gpa = gpa, .idle_ns = idle_ns, .max = max };
        }

        /// Frees the nodes still in the table. Their values are the caller's
        /// to have closed (`popAll`).
        pub fn deinit(t: *Self) void {
            while (t.lru.popFirst()) |n| {
                const node: *Node = @alignCast(@fieldParentPtr("list", n));
                t.gpa.destroy(node);
            }
            t.map.deinit(t.gpa);
        }

        pub fn count(t: *const Self) usize {
            return t.map.count();
        }

        pub fn get(t: *Self, key: PeerKey) ?*Node {
            return t.map.get(key);
        }

        /// A datagram came from `node`'s peer: it is the freshest now.
        pub fn touch(t: *Self, node: *Node, now: i96) void {
            node.last = now;
            t.lru.remove(&node.list);
            t.lru.append(&node.list);
        }

        /// A session for a peer not in the table. `error.Full` when the table
        /// is at its cap (counted in `refused`).
        pub fn open(t: *Self, key: PeerKey, now: i96, value: T) error{ Full, OutOfMemory }!*Node {
            if (t.map.count() >= t.max) {
                t.refused += 1;
                return error.Full;
            }
            const node = try t.gpa.create(Node);
            errdefer t.gpa.destroy(node);
            node.* = .{ .key = key, .last = now, .value = value };
            try t.map.put(t.gpa, key, node);
            t.lru.append(&node.list);
            return node;
        }

        /// Takes `node` out and frees it; its value is gone with it.
        pub fn remove(t: *Self, node: *Node) void {
            _ = t.map.remove(node.key);
            t.lru.remove(&node.list);
            t.gpa.destroy(node);
        }

        /// When the first session expires, or null with none.
        pub fn nextExpiry(t: *const Self) ?i96 {
            const first = t.lru.first orelse return null;
            const node: *const Node = @alignCast(@fieldParentPtr("list", first));
            return node.last + t.idle_ns;
        }

        /// The oldest session if it has been idle for `idle_ns` by `now`,
        /// taken out of the table (the caller closes its value, then
        /// `destroy`s the node); else null.
        pub fn popExpired(t: *Self, now: i96) ?*Node {
            const first = t.lru.first orelse return null;
            const node: *Node = @alignCast(@fieldParentPtr("list", first));
            if (now < node.last + t.idle_ns) return null;
            _ = t.map.remove(node.key);
            t.lru.remove(&node.list);
            return node;
        }

        /// The oldest session whatever its age (the stop), taken out.
        pub fn popOldest(t: *Self) ?*Node {
            const first = t.lru.first orelse return null;
            const node: *Node = @alignCast(@fieldParentPtr("list", first));
            _ = t.map.remove(node.key);
            t.lru.remove(&node.list);
            return node;
        }

        /// Frees a node `popExpired` or `popOldest` returned.
        pub fn destroy(t: *Self, node: *Node) void {
            t.gpa.destroy(node);
        }
    };
}

const testing = std.testing;

fn peer(last: u8, port: u16) std.Io.net.IpAddress {
    return .{ .ip4 = .{ .bytes = .{ 10, 0, 0, last }, .port = port } };
}

test "sessions: open once per peer, in order" {
    var t: SessionTable(u32) = .init(testing.allocator, 1000, 16);
    defer t.deinit();
    const ids = [_]u8{ 1, 2, 3, 1, 2, 1 };
    var opened: usize = 0;
    for (ids, 0..) |id, i| {
        const key = PeerKey.of(peer(id, 4000));
        if (t.get(key)) |n| {
            t.touch(n, @intCast(i));
        } else {
            _ = try t.open(key, @intCast(i), id);
            opened += 1;
        }
    }
    try testing.expectEqual(@as(usize, 3), opened);
    try testing.expectEqual(@as(usize, 3), t.count());
    // Another port is another peer.
    try testing.expect(t.get(PeerKey.of(peer(1, 4001))) == null);
}

test "sessions: idle expiry follows the last datagram, LRU order kept" {
    var t: SessionTable(u32) = .init(testing.allocator, 100, 16);
    defer t.deinit();
    const a = try t.open(PeerKey.of(peer(1, 1)), 0, 1);
    _ = try t.open(PeerKey.of(peer(2, 1)), 10, 2);
    _ = try t.open(PeerKey.of(peer(3, 1)), 20, 3);
    try testing.expectEqual(@as(?i96, 100), t.nextExpiry());
    // `a` is heard from again: peer 2 is now the oldest.
    t.touch(a, 50);
    try testing.expectEqual(@as(?i96, 110), t.nextExpiry());
    try testing.expect(t.popExpired(109) == null);
    const gone = t.popExpired(110).?;
    try testing.expectEqual(@as(u32, 2), gone.value);
    t.destroy(gone);
    const third = t.popExpired(125).?;
    try testing.expectEqual(@as(u32, 3), third.value);
    t.destroy(third);
    try testing.expect(t.popExpired(149) == null);
    const last = t.popExpired(150).?;
    try testing.expectEqual(@as(u32, 1), last.value);
    t.destroy(last);
    try testing.expectEqual(@as(?i96, null), t.nextExpiry());
    try testing.expectEqual(@as(usize, 0), t.count());
}

test "sessions: the cap refuses new peers and keeps the old ones" {
    var t: SessionTable(u32) = .init(testing.allocator, 100, 2);
    defer t.deinit();
    _ = try t.open(PeerKey.of(peer(1, 1)), 0, 1);
    _ = try t.open(PeerKey.of(peer(2, 1)), 0, 2);
    try testing.expectError(error.Full, t.open(PeerKey.of(peer(3, 1)), 0, 3));
    try testing.expectEqual(@as(u64, 1), t.refused);
    try testing.expectEqual(@as(usize, 2), t.count());
    try testing.expect(t.get(PeerKey.of(peer(1, 1))) != null);
    try testing.expect(t.get(PeerKey.of(peer(2, 1))) != null);
    // Room again once one leaves.
    t.remove(t.get(PeerKey.of(peer(1, 1))).?);
    _ = try t.open(PeerKey.of(peer(3, 1)), 0, 3);
}

test "sessions: IPv4 and IPv4-mapped IPv6 are one peer" {
    const v4 = std.Io.net.IpAddress{ .ip4 = .{ .bytes = .{ 192, 0, 2, 7 }, .port = 9 } };
    var mapped_bytes: [16]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 192, 0, 2, 7 };
    const v6 = std.Io.net.IpAddress{ .ip6 = .{ .bytes = mapped_bytes, .port = 9 } };
    try testing.expectEqual(PeerKey.of(v4), PeerKey.of(v6));
    mapped_bytes[15] = 8;
    const other = std.Io.net.IpAddress{ .ip6 = .{ .bytes = mapped_bytes, .port = 9 } };
    try testing.expect(!std.meta.eql(PeerKey.of(v4), PeerKey.of(other)));
    // A real IPv6 address stays IPv6.
    const real = std.Io.net.IpAddress{ .ip6 = .{ .bytes = .{ 0x20, 1, 0xd, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, .port = 9 } };
    try testing.expectEqual(@as(u8, 6), PeerKey.of(real).family);
}
