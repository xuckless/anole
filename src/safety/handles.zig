//! M2's fourth class: objects shared with, or detached from, their owner
//! (C ABI requests, parked responses, subscribers reached across executors,
//! connections a driver services) live in a per-executor table and are
//! referred to by `Handle`. A stale handle resolves to `error.Gone`, never
//! to a freed pointer (T4).
//!
//! The table belongs to one executor (T3): `insert`, `get` and `remove` run
//! there, and debug builds assert it. Any thread may ask `live(h)`, an
//! atomic read, to skip posting a message for a handle already gone; the
//! owner checks again when it resolves the message. A pointer from `get` is
//! valid until the caller's next suspension point (M3): resolve the handle
//! again after one.
//!
//! The capacity is fixed at init (U4): a full table is `error.Full`.
const std = @import("std");
const Owner = @import("owner.zig").Owner;

pub const Handle = packed struct(u64) {
    index: u32,
    /// The slot's generation when the handle was made: odd while live.
    gen: u32,

    pub const none: Handle = .{ .index = std.math.maxInt(u32), .gen = 0 };

    pub fn toInt(h: Handle) u64 {
        return @bitCast(h);
    }

    pub fn fromInt(v: u64) Handle {
        return @bitCast(v);
    }
};

pub fn HandleTable(comptime T: type) type {
    return struct {
        slots: []Slot,
        free_head: u32,
        count: u32 = 0,
        owner: Owner,
        gpa: std.mem.Allocator,

        const Self = @This();
        const nil = std.math.maxInt(u32);

        const Slot = struct {
            /// Even: free; odd: live. Bumped by insert and by remove.
            gen: std.atomic.Value(u32) = .init(0),
            next_free: u32 = nil,
            value: T = undefined,
        };

        /// A table of `capacity` slots, owned by the calling executor.
        pub fn init(gpa: std.mem.Allocator, io: std.Io, capacity: u32) error{OutOfMemory}!Self {
            const slots = try gpa.alloc(Slot, capacity);
            for (slots, 0..) |*s, i| s.* = .{ .next_free = if (i + 1 < capacity) @intCast(i + 1) else nil };
            return .{ .slots = slots, .free_head = if (capacity > 0) 0 else nil, .owner = .here(io), .gpa = gpa };
        }

        /// Frees the table. Whatever is still in it is the caller's to have
        /// torn down first (`count` says how many).
        pub fn deinit(self: *Self) void {
            self.gpa.free(self.slots);
            self.* = undefined;
        }

        pub fn insert(self: *Self, io: std.Io, value: T) error{Full}!Handle {
            self.owner.check(io);
            const i = self.free_head;
            if (i == nil) return error.Full;
            const s = &self.slots[i];
            self.free_head = s.next_free;
            s.value = value;
            const g = s.gen.load(.monotonic) +% 1;
            s.gen.store(g, .release);
            self.count += 1;
            return .{ .index = i, .gen = g };
        }

        /// The object `h` names, or `error.Gone`. Valid until the caller's
        /// next suspension point.
        pub fn get(self: *Self, io: std.Io, h: Handle) error{Gone}!*T {
            self.owner.check(io);
            const s = self.slotOf(h) orelse return error.Gone;
            return &s.value;
        }

        /// Takes the object out; `h` (and every copy of it) is gone after.
        pub fn remove(self: *Self, io: std.Io, h: Handle) error{Gone}!T {
            self.owner.check(io);
            const s = self.slotOf(h) orelse return error.Gone;
            const v = s.value;
            s.value = undefined;
            s.gen.store(h.gen +% 1, .release);
            s.next_free = self.free_head;
            self.free_head = h.index;
            self.count -= 1;
            return v;
        }

        /// Whether `h` is still live. Any thread; a hint only (it can be
        /// removed right after): the owner checks again.
        pub fn live(self: *const Self, h: Handle) bool {
            if (h.index >= self.slots.len or h.gen & 1 == 0) return false;
            return self.slots[h.index].gen.load(.acquire) == h.gen;
        }

        fn slotOf(self: *Self, h: Handle) ?*Slot {
            if (h.index >= self.slots.len or h.gen & 1 == 0) return null;
            const s = &self.slots[h.index];
            if (s.gen.load(.monotonic) != h.gen) return null;
            return s;
        }
    };
}

test "handles: insert, get, remove; a stale handle is Gone" {
    var t: HandleTable(u32) = try .init(std.testing.allocator, std.testing.io, 2);
    defer t.deinit();
    const io = std.testing.io;
    const a = try t.insert(io, 7);
    const b = try t.insert(io, 8);
    try std.testing.expectError(error.Full, t.insert(io, 9));
    try std.testing.expectEqual(@as(u32, 7), (try t.get(io, a)).*);
    try std.testing.expect(t.live(a));
    try std.testing.expectEqual(@as(u32, 7), try t.remove(io, a));
    try std.testing.expect(!t.live(a));
    try std.testing.expectError(error.Gone, t.get(io, a));
    try std.testing.expectError(error.Gone, t.remove(io, a));
    // The slot is reused under a new generation; the old handle stays gone.
    const c = try t.insert(io, 10);
    try std.testing.expectEqual(a.index, c.index);
    try std.testing.expect(c.gen != a.gen);
    try std.testing.expectError(error.Gone, t.get(io, a));
    try std.testing.expectEqual(@as(u32, 10), (try t.get(io, c)).*);
    try std.testing.expectEqual(@as(u32, 2), t.count);
    _ = try t.remove(io, b);
    _ = try t.remove(io, c);
}

test "handles: none and out-of-range handles are Gone" {
    var t: HandleTable(u8) = try .init(std.testing.allocator, std.testing.io, 1);
    defer t.deinit();
    try std.testing.expectError(error.Gone, t.get(std.testing.io, .none));
    try std.testing.expectError(error.Gone, t.get(std.testing.io, .{ .index = 5, .gen = 1 }));
    try std.testing.expect(!t.live(.none));
}
