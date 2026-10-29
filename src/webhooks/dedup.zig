//! Duplicate-delivery stores for `Verify`: a delivery id is claimed as
//! `pending` before the handler, marked `done` after a 2xx, or released
//! after anything else. A bounded in-memory store (process-wide, sharded)
//! and a Redis/Valkey one.
const std = @import("std");
const anole = @import("../root.zig");

pub const Claim = enum { new, pending, done };
pub const Error = error{StoreFailed};

/// Which store, and its settings.
pub const Config = union(enum) {
    none,
    memory: Memory.Options,
    redis: RedisOptions,
};

/// The Redis client and reply types; placeholders in builds without `-Dredis`.
pub const RedisClient = if (anole.features.redis) anole.redis.Client else struct {
    pub fn command(self: *@This(), c: anytype, args: anytype) error{OutOfMemory}!RedisReply {
        _ = .{ self, c, args };
        unreachable;
    }
};
pub const RedisReply = if (anole.features.redis) anole.redis.Reply else union(enum) {
    nil,
    int: i64,
    string: []const u8,
    status: []const u8,
    array: []RedisReply,
    pub fn text(self: RedisReply) ?[]const u8 {
        _ = self;
        return null;
    }
};

pub const RedisOptions = struct {
    client: *RedisClient,
    ttl: anole.Duration = .fromSeconds(24 * 3600),
    prefix: []const u8 = "anole:webhooks:seen:",
};

const shard_count = 16;

const State = enum(u8) { pending, done };
const Entry = struct { state: State, expires_ms: i64 };

/// In memory, bounded: a shard at its limit drops expired entries, then the
/// oldest ones.
pub const Memory = struct {
    pub const Options = struct {
        ttl: anole.Duration = .fromSeconds(24 * 3600),
        max_entries: u32 = 100_000,
    };

    const Shard = struct {
        mutex: std.Io.Mutex = .init,
        map: std.AutoHashMapUnmanaged(u128, Entry) = .empty,
        order: std.ArrayList(u128) = .empty,
        head: usize = 0,
    };

    gpa: std.mem.Allocator,
    io: std.Io,
    options: Options,
    shards: [shard_count]Shard = @splat(.{}),

    pub fn init(gpa: std.mem.Allocator, io: std.Io, options: Options) Memory {
        return .{ .gpa = gpa, .io = io, .options = options };
    }

    pub fn deinit(self: *Memory) void {
        for (&self.shards) |*s| {
            s.map.deinit(self.gpa);
            s.order.deinit(self.gpa);
        }
    }

    fn shardOf(self: *Memory, key: u128) *Shard {
        return &self.shards[@intCast(key % shard_count)];
    }

    fn limit(self: *const Memory) usize {
        return @max(1, self.options.max_entries / shard_count);
    }

    /// Takes the id when it is free (or its entry expired); else says what holds it.
    pub fn claim(self: *Memory, key: u128, pending_ms: i64, now_ms: i64) Error!Claim {
        const s = self.shardOf(key);
        s.mutex.lockUncancelable(self.io);
        defer s.mutex.unlock(self.io);
        if (s.map.get(key)) |e| {
            if (e.expires_ms > now_ms) return switch (e.state) {
                .pending => .pending,
                .done => .done,
            };
        }
        self.makeRoom(s, now_ms);
        const gop = s.map.getOrPut(self.gpa, key) catch return error.StoreFailed;
        if (!gop.found_existing) s.order.append(self.gpa, key) catch {
            _ = s.map.remove(key);
            return error.StoreFailed;
        };
        gop.value_ptr.* = .{ .state = .pending, .expires_ms = now_ms + pending_ms };
        return .new;
    }

    fn makeRoom(self: *Memory, s: *Shard, now_ms: i64) void {
        if (s.map.count() < self.limit()) return;
        // Expired entries first, then the oldest.
        var it = s.map.iterator();
        var dead: std.ArrayList(u128) = .empty;
        defer dead.deinit(self.gpa);
        while (it.next()) |kv| {
            if (kv.value_ptr.expires_ms <= now_ms) dead.append(self.gpa, kv.key_ptr.*) catch break;
        }
        for (dead.items) |k| _ = s.map.remove(k);
        while (s.map.count() >= self.limit() and s.head < s.order.items.len) {
            _ = s.map.remove(s.order.items[s.head]);
            s.head += 1;
        }
        // Compact the order list once its dead prefix is large.
        if (s.head > 1024 and s.head * 2 > s.order.items.len) {
            const rest = s.order.items.len - s.head;
            std.mem.copyForwards(u128, s.order.items[0..rest], s.order.items[s.head..]);
            s.order.items.len = rest;
            s.head = 0;
        }
    }

    pub fn markDone(self: *Memory, key: u128, now_ms: i64) void {
        const s = self.shardOf(key);
        s.mutex.lockUncancelable(self.io);
        defer s.mutex.unlock(self.io);
        if (s.map.getPtr(key)) |e| e.* = .{ .state = .done, .expires_ms = now_ms + self.options.ttl.toMilliseconds() };
    }

    pub fn release(self: *Memory, key: u128) void {
        const s = self.shardOf(key);
        s.mutex.lockUncancelable(self.io);
        defer s.mutex.unlock(self.io);
        if (s.map.getPtr(key)) |e| if (e.state == .pending) {
            _ = s.map.remove(key);
        };
    }
};

/// The key of an id: preset name and id, hashed to 128 bits.
pub fn keyOf(preset: []const u8, id: []const u8) u128 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(preset);
    h.update(":");
    h.update(id);
    var d: [32]u8 = undefined;
    h.final(&d);
    return std.mem.readInt(u128, d[0..16], .little);
}

/// Redis/Valkey: `SET k pending NX PX`, `GET`, `SET k done PX`, and a Lua
/// compare-and-delete for the release.
pub const Redis = struct {
    options: RedisOptions,

    const release_script = "if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('DEL', KEYS[1]) end return 0";

    fn keyText(self: Redis, buf: []u8, key: u128) []const u8 {
        return std.fmt.bufPrint(buf, "{s}{x:0>32}", .{ self.options.prefix, key }) catch buf[0..0];
    }

    pub fn claim(self: Redis, c: anytype, key: u128, pending_ms: i64) Error!Claim {
        var kb: [160]u8 = undefined;
        const k = self.keyText(&kb, key);
        var pb: [24]u8 = undefined;
        const px = std.fmt.bufPrint(&pb, "{d}", .{pending_ms}) catch unreachable;
        const r = self.options.client.command(c, .{ "SET", k, "pending", "NX", "PX", px }) catch return error.StoreFailed;
        if (r != .nil) return .new;
        const g = self.options.client.command(c, .{ "GET", k }) catch return error.StoreFailed;
        const text = g.text() orelse return .pending; // expired between the two: the sender retries
        return if (std.mem.eql(u8, text, "done")) .done else .pending;
    }

    pub fn markDone(self: Redis, c: anytype, key: u128) void {
        var kb: [160]u8 = undefined;
        const k = self.keyText(&kb, key);
        var pb: [24]u8 = undefined;
        const px = std.fmt.bufPrint(&pb, "{d}", .{self.options.ttl.toMilliseconds()}) catch unreachable;
        _ = self.options.client.command(c, .{ "SET", k, "done", "PX", px }) catch {};
    }

    pub fn release(self: Redis, c: anytype, key: u128) void {
        var kb: [160]u8 = undefined;
        const k = self.keyText(&kb, key);
        _ = self.options.client.command(c, .{ "EVAL", release_script, "1", k, "pending" }) catch {};
    }
};

test "memory: claim, pending, done, release, expiry" {
    var m = Memory.init(std.testing.allocator, std.testing.io, .{});
    defer m.deinit();
    const k = keyOf("standard", "msg_1");
    try std.testing.expectEqual(Claim.new, try m.claim(k, 1000, 0));
    try std.testing.expectEqual(Claim.pending, try m.claim(k, 1000, 10));
    m.release(k);
    try std.testing.expectEqual(Claim.new, try m.claim(k, 1000, 20));
    m.markDone(k, 20);
    try std.testing.expectEqual(Claim.done, try m.claim(k, 1000, 30));
    m.release(k); // a done entry is not released
    try std.testing.expectEqual(Claim.done, try m.claim(k, 1000, 40));
    const after = 20 + m.options.ttl.toMilliseconds() + 1;
    try std.testing.expectEqual(Claim.new, try m.claim(k, 1000, after));
    // A pending entry expires too.
    const k2 = keyOf("stripe", "evt_1");
    try std.testing.expectEqual(Claim.new, try m.claim(k2, 100, 0));
    try std.testing.expectEqual(Claim.new, try m.claim(k2, 100, 101));
}

test "memory: bounded, oldest dropped" {
    var m = Memory.init(std.testing.allocator, std.testing.io, .{ .max_entries = 32 });
    defer m.deinit();
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        var b: [16]u8 = undefined;
        const id = std.fmt.bufPrint(&b, "id{d}", .{i}) catch unreachable;
        _ = try m.claim(keyOf("x", id), 1_000_000, 0);
    }
    // The newest id is still held; the first one was dropped to make room.
    try std.testing.expectEqual(Claim.pending, try m.claim(keyOf("x", "id999"), 1_000_000, 0));
    try std.testing.expectEqual(Claim.new, try m.claim(keyOf("x", "id0"), 1_000_000, 0));
}

test "keys differ by preset" {
    try std.testing.expect(keyOf("github", "1") != keyOf("stripe", "1"));
}
