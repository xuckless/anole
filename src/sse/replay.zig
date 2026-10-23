//! The replay buffer of `anole.sse.Topics`: per topic a ring of the newest
//! events, all rings together capped, and the event IDs.
//!
//! An ID is `<epoch>-<seq>`: `epoch` is 8 lower-case hex digits chosen at
//! random for each `Topics`, `seq` a decimal number counted across every
//! topic of it. A subscriber of several topics has one `Last-Event-ID`;
//! the one ordered ID space lets it position them all (the epoch plus
//! offset idea of Centrifugo's recovery). Everything here runs under the
//! hub's mutex.

const std = @import("std");

/// One event as queued for subscribers, shared by every queue it is in
/// and by the replay ring: one allocation, the bytes right behind the
/// header.
pub const Payload = struct {
    refs: std.atomic.Value(u32),
    /// 0: not a topic event.
    seq: u64,
    kind: Kind,
    id_len: u8,
    id_buf: [40]u8,
    len: usize,

    pub const Kind = enum(u8) { event, heartbeat, end, gap, retry };

    pub fn create(gpa: std.mem.Allocator, kind: Kind, bytes: []const u8) std.mem.Allocator.Error!*Payload {
        const block = try gpa.alignedAlloc(u8, .of(Payload), @sizeOf(Payload) + bytes.len);
        const p: *Payload = @ptrCast(block.ptr);
        p.* = .{ .refs = .init(1), .seq = 0, .kind = kind, .id_len = 0, .id_buf = undefined, .len = bytes.len };
        @memcpy(block[@sizeOf(Payload)..], bytes);
        return p;
    }

    /// Room for the body to be filled by the caller.
    pub fn createUninit(gpa: std.mem.Allocator, kind: Kind, len: usize) std.mem.Allocator.Error!*Payload {
        const block = try gpa.alignedAlloc(u8, .of(Payload), @sizeOf(Payload) + len);
        const p: *Payload = @ptrCast(block.ptr);
        p.* = .{ .refs = .init(1), .seq = 0, .kind = kind, .id_len = 0, .id_buf = undefined, .len = len };
        return p;
    }

    pub fn bodyMut(p: *Payload) []u8 {
        const base: [*]u8 = @ptrCast(p);
        return base[@sizeOf(Payload)..][0..p.len];
    }

    pub fn body(p: *const Payload) []const u8 {
        const base: [*]const u8 = @ptrCast(p);
        return base[@sizeOf(Payload)..][0..p.len];
    }

    /// The `id: ...\n` line, empty when the payload has none.
    pub fn idLine(p: *const Payload) []const u8 {
        return p.id_buf[0..p.id_len];
    }

    /// What it counts against a subscriber's queue and the replay budget.
    pub fn cost(p: *const Payload) usize {
        return p.len + p.id_len + 64;
    }

    pub fn retain(p: *Payload) void {
        _ = p.refs.fetchAdd(1, .monotonic);
    }

    pub fn release(p: *Payload, gpa: std.mem.Allocator) void {
        if (p.refs.fetchSub(1, .acq_rel) != 1) return;
        const base: [*]align(@alignOf(Payload)) u8 = @ptrCast(p);
        gpa.free(base[0 .. @sizeOf(Payload) + p.len]);
    }

    /// Sets the ID line to `id: <epoch>-<seq>\n`.
    pub fn setId(p: *Payload, epoch: u32, seq: u64) void {
        p.seq = seq;
        const line = std.fmt.bufPrint(&p.id_buf, "id: {x:0>8}-{d}\n", .{ epoch, seq }) catch unreachable;
        p.id_len = @intCast(line.len);
    }
};

/// One topic's replay ring.
pub const Ring = struct {
    /// Entries, oldest first (`Entry.topic_node`).
    list: std.DoublyLinkedList = .{},
    len: u32 = 0,
    bytes: usize = 0,
    /// Every event of the topic with a seq above this is in the ring.
    complete_after: u64 = 0,
};

/// One replayed event.
pub const Entry = struct {
    payload: *Payload,
    ring: *Ring,
    /// Awake clock, milliseconds.
    at_ms: i64,
    topic_node: std.DoublyLinkedList.Node = .{},
    all_node: std.DoublyLinkedList.Node = .{},

    pub fn fromTopicNode(n: *std.DoublyLinkedList.Node) *Entry {
        return @fieldParentPtr("topic_node", n);
    }
    pub fn fromAllNode(n: *std.DoublyLinkedList.Node) *Entry {
        return @fieldParentPtr("all_node", n);
    }
};

pub const Limits = struct {
    events: u32,
    bytes: usize,
    total_bytes: usize,
    max_age_ms: i64,
};

/// Every ring of one hub: the global list, oldest first, and its bytes.
pub const Store = struct {
    all: std.DoublyLinkedList = .{},
    bytes: usize = 0,

    /// Records `p` in `ring` and evicts what the limits no longer allow.
    /// Memory failure leaves the ring incomplete up to `p`: its
    /// `complete_after` moves to `p.seq`.
    pub fn add(self: *Store, gpa: std.mem.Allocator, ring: *Ring, p: *Payload, now_ms: i64, limits: Limits) void {
        const entry = gpa.create(Entry) catch {
            ring.complete_after = p.seq;
            return;
        };
        entry.* = .{ .payload = p, .ring = ring, .at_ms = now_ms };
        p.retain();
        ring.list.append(&entry.topic_node);
        self.all.append(&entry.all_node);
        ring.len += 1;
        ring.bytes += p.cost();
        self.bytes += p.cost();
        // The topic's own caps.
        while (ring.len > limits.events or ring.bytes > limits.bytes) {
            const first = ring.list.first orelse break;
            self.evict(gpa, Entry.fromTopicNode(first));
        }
        // The hub's: the globally oldest first.
        while (self.bytes > limits.total_bytes) {
            const first = self.all.first orelse break;
            self.evict(gpa, Entry.fromAllNode(first));
        }
    }

    pub fn evict(self: *Store, gpa: std.mem.Allocator, e: *Entry) void {
        e.ring.list.remove(&e.topic_node);
        self.all.remove(&e.all_node);
        e.ring.len -= 1;
        e.ring.bytes -= e.payload.cost();
        self.bytes -= e.payload.cost();
        if (e.payload.seq > e.ring.complete_after) e.ring.complete_after = e.payload.seq;
        e.payload.release(gpa);
        gpa.destroy(e);
    }

    /// Evicts the entries older than the age limit.
    pub fn sweep(self: *Store, gpa: std.mem.Allocator, now_ms: i64, max_age_ms: i64) void {
        while (self.all.first) |n| {
            const e = Entry.fromAllNode(n);
            if (now_ms - e.at_ms < max_age_ms) break;
            self.evict(gpa, e);
        }
    }

    /// Frees every entry (the rings die with their topics).
    pub fn clear(self: *Store, gpa: std.mem.Allocator) void {
        while (self.all.first) |n| self.evict(gpa, Entry.fromAllNode(n));
    }
};

/// A parsed `Last-Event-ID`.
pub const LastId = struct { epoch: u32, seq: u64 };

/// `^[0-9a-f]{8}-[0-9]{1,20}$`; null for anything else.
pub fn parseLastEventId(text: []const u8) ?LastId {
    if (text.len < 10 or text.len > 29) return null;
    if (text[8] != '-') return null;
    for (text[0..8]) |ch| switch (ch) {
        '0'...'9', 'a'...'f' => {},
        else => return null,
    };
    const digits = text[9..];
    for (digits) |ch| if (ch < '0' or ch > '9') return null;
    const epoch = std.fmt.parseInt(u32, text[0..8], 16) catch return null;
    const seq = std.fmt.parseInt(u64, digits, 10) catch return null;
    return .{ .epoch = epoch, .seq = seq };
}

test "parseLastEventId accepts exactly the id format" {
    const ok = parseLastEventId("0a1b2c3d-42").?;
    try std.testing.expectEqual(@as(u32, 0x0a1b2c3d), ok.epoch);
    try std.testing.expectEqual(@as(u64, 42), ok.seq);
    try std.testing.expect(parseLastEventId("0A1B2C3D-42") == null);
    try std.testing.expect(parseLastEventId("0a1b2c3d-") == null);
    try std.testing.expect(parseLastEventId("0a1b2c3d42") == null);
    try std.testing.expect(parseLastEventId("0a1b2c-42") == null);
    try std.testing.expect(parseLastEventId("0a1b2c3d-4x") == null);
    try std.testing.expect(parseLastEventId("0a1b2c3d-99999999999999999999999") == null);
    try std.testing.expect(parseLastEventId("") == null);
    try std.testing.expect(parseLastEventId("0a1b2c3d--1") == null);
}

test "Store: caps evict the oldest and move complete_after" {
    const gpa = std.testing.allocator;
    var store: Store = .{};
    defer store.clear(gpa);
    var ring: Ring = .{};
    const limits: Limits = .{ .events = 3, .bytes = 1 << 20, .total_bytes = 1 << 20, .max_age_ms = 1000 };
    var seq: u64 = 0;
    for (0..5) |_| {
        seq += 1;
        const p = try Payload.create(gpa, .event, "x");
        p.setId(1, seq);
        store.add(gpa, &ring, p, 0, limits);
        p.release(gpa);
    }
    try std.testing.expectEqual(@as(u32, 3), ring.len);
    try std.testing.expectEqual(@as(u64, 2), ring.complete_after);
    // Age.
    store.sweep(gpa, 5000, 1000);
    try std.testing.expectEqual(@as(u32, 0), ring.len);
    try std.testing.expectEqual(@as(u64, 5), ring.complete_after);
}

test "Store: the total cap evicts the globally oldest across rings" {
    const gpa = std.testing.allocator;
    var store: Store = .{};
    defer store.clear(gpa);
    var a: Ring = .{};
    var b: Ring = .{};
    const limits: Limits = .{ .events = 100, .bytes = 1 << 20, .total_bytes = 3 * (64 + 40 + 1), .max_age_ms = 1000 };
    var seq: u64 = 0;
    const rings = [_]*Ring{ &a, &b, &a, &b };
    for (rings) |ring| {
        seq += 1;
        const p = try Payload.create(gpa, .event, "x");
        p.setId(1, seq);
        store.add(gpa, ring, p, 0, limits);
        p.release(gpa);
    }
    // Four added, room for three of this size: seq 1 (ring a) went.
    try std.testing.expect(a.complete_after >= 1);
    try std.testing.expectEqual(@as(u64, 0), b.complete_after);
}
