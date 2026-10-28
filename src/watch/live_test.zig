//! `anole.watch` against live servers: PostgreSQL (`-Dpostgres-test-url`),
//! Redis or Valkey (`-Dredis-test-url` / `-Dredis-test-port`) and MongoDB
//! (`-Dmongodb-test-url`, a replica set). Without the option each skips.

const std = @import("std");
const wait = @import("anole_test_wait");
const features = @import("build_options");
const zio = @import("zio");
const db = @import("../db/root.zig");
const root = @import("root.zig");
const pg = @import("../pg/root.zig");
const redis = @import("../redis/root.zig");
const redis_live = @import("../redis/live_test.zig");

const Watch = root.Watch;
const gpa = std.testing.allocator;

/// Everything delivered to it, as "op|channel|data|pattern|position" lines.
const Collector = struct {
    sink: root.Sink,
    lock: std.atomic.Mutex = .unlocked,
    lines: std.ArrayList([]u8) = .empty,
    gaps: std.atomic.Value(u32) = .init(0),
    connects: std.atomic.Value(u32) = .init(0),

    fn init(c: *Collector) void {
        c.* = .{ .sink = .{ .ctx = c, .deliver = deliver, .gap = onGap, .status = onStatus, .ended = onEnded } };
    }

    fn deinit(c: *Collector) void {
        for (c.lines.items) |l| gpa.free(l);
        c.lines.deinit(gpa);
    }

    fn acquire(c: *Collector) void {
        while (!c.lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn deliver(ctx: *anyopaque, ev: *const root.Event) void {
        const c: *Collector = @ptrCast(@alignCast(ctx));
        const line = std.fmt.allocPrint(gpa, "{s}|{s}|{s}|{s}|{s}", .{ ev.op_name, ev.channel, ev.data, ev.pattern orelse "-", ev.position orelse "-" }) catch return;
        c.acquire();
        defer c.lock.unlock();
        c.lines.append(gpa, line) catch gpa.free(line);
    }

    fn onGap(ctx: *anyopaque, _: []const u8) void {
        const c: *Collector = @ptrCast(@alignCast(ctx));
        _ = c.gaps.fetchAdd(1, .monotonic);
    }

    fn onStatus(ctx: *anyopaque, connected: bool, _: []const u8) void {
        const c: *Collector = @ptrCast(@alignCast(ctx));
        if (connected) _ = c.connects.fetchAdd(1, .monotonic);
    }

    fn onEnded(_: *anyopaque, _: bool, _: []const u8) void {}

    /// How many lines hold `needle`.
    fn count(c: *Collector, needle: []const u8) usize {
        c.acquire();
        defer c.lock.unlock();
        var n: usize = 0;
        for (c.lines.items) |l| {
            if (std.mem.indexOf(u8, l, needle) != null) n += 1;
        }
        return n;
    }

    fn total(c: *Collector) usize {
        c.acquire();
        defer c.lock.unlock();
        return c.lines.items.len;
    }

    /// The first line holding `needle`, copied into `buf`.
    fn find(c: *Collector, needle: []const u8, buf: []u8) ?[]const u8 {
        c.acquire();
        defer c.lock.unlock();
        for (c.lines.items) |l| if (std.mem.indexOf(u8, l, needle) != null) {
            const n = @min(l.len, buf.len);
            @memcpy(buf[0..n], l[0..n]);
            return buf[0..n];
        };
        return null;
    }

    /// Waits (a guard against a hang, not a timing claim) until a line holds `needle`.
    fn waitFor(c: *Collector, io: std.Io, needle: []const u8) !void {
        const Has = struct {
            c: *Collector,
            needle: []const u8,
            fn seen(h: @This()) bool {
                return h.c.count(h.needle) > 0;
            }
        };
        wait.waitUntil(io, "a collected line holds the text", Has{ .c = c, .needle = needle }, Has.seen) catch |err| {
            std.debug.print("waiting for \"{s}\" failed\n", .{needle});
            return err;
        };
    }
};

fn waitConnected(w: *Watch, io: std.Io) !void {
    try wait.waitUntil(io, "the watch is connected", w, struct {
        fn connected(wt: *Watch) bool {
            return wt.status() == .connected;
        }
    }.connected);
}

fn waitGaps(c: *Collector, io: std.Io, n: u32) !void {
    try wait.waitAtLeast(io, "the collector saw the gaps", &c.gaps, n);
}

// ---------------------------------------------------------------------------
// PostgreSQL

test "watch live: postgres: two channels share the hub connection; the listener's backend killed: a gap, LISTEN again, a later NOTIFY arrives" {
    if (comptime !features.postgres) return error.SkipZigTest;
    const url = features.postgres_test_url orelse return error.SkipZigTest;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const client = try pg.Client.init(gpa, io, .{ .url = url, .environ = .empty });
    defer client.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };

    const wa = try Watch.init(gpa, io, .{ .postgres = .{ .client = client, .channels = &.{"anole_wa"} } }, .{});
    defer wa.deinit();
    const wb = try Watch.init(gpa, io, .{ .postgres = .{ .client = client, .channels = &.{"anole_wb"} } }, .{});
    defer wb.deinit();
    var ca: Collector = undefined;
    ca.init();
    defer ca.deinit();
    var cb: Collector = undefined;
    cb.init();
    defer cb.deinit();
    wa.addSink(&ca.sink);
    wb.addSink(&cb.sink);
    try wa.start(null, null, null);
    try wb.start(null, null, null);
    defer wa.stop();
    defer wb.stop();
    try waitConnected(wa, io);
    try waitConnected(wb, io);

    // The right watch hears the right channel.
    _ = try client.exec(&c, "NOTIFY anole_wa, 'one'", .{});
    try ca.waitFor(io, "|anole_wa|one|");
    _ = try client.exec(&c, "NOTIFY anole_wb, 'two'", .{});
    try cb.waitFor(io, "|anole_wb|two|");
    try std.testing.expectEqual(@as(usize, 0), ca.count("two"));
    try std.testing.expectEqual(@as(usize, 0), cb.count("one"));

    // The backend that holds the LISTENs is terminated: events may have
    // been lost (a gap), the connection is made again, and a later NOTIFY
    // is delivered.
    _ = try client.all(bool, &c, "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE query ILIKE 'LISTEN %' AND pid <> pg_backend_pid()", .{});
    try waitGaps(&ca, io, 1);
    try waitGaps(&cb, io, 1);
    var sent: u32 = 0;
    while (ca.count("|anole_wa|three|") == 0) {
        // The LISTEN may not be back yet: notify until it is heard.
        _ = try client.exec(&c, "NOTIFY anole_wa, 'three'", .{});
        sent += 1;
        try std.testing.expect(sent < 2000);
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    try waitConnected(wa, io);
}

// ---------------------------------------------------------------------------
// Redis

test "watch live: redis: PSUBSCRIBE room:* reaches the watch with the channel and the pattern" {
    if (comptime !features.redis) return error.SkipZigTest;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const r = try redis_live.open(io, .{});
    defer r.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };

    const w = try Watch.init(gpa, io, .{ .redis = .{ .client = r, .patterns = &.{"anole_room:*"} } }, .{});
    defer w.deinit();
    var col: Collector = undefined;
    col.init();
    defer col.deinit();
    w.addSink(&col.sink);
    try w.start(null, null, null);
    defer w.stop();
    try waitConnected(w, io);
    var sent: u32 = 0;
    while (col.count("|anole_room:7|hello|anole_room:*|") == 0) {
        _ = try r.command(&c, .{ "PUBLISH", "anole_room:7", "hello" });
        sent += 1;
        try std.testing.expect(sent < 2000);
        try io.sleep(.fromMilliseconds(10), .awake);
    }
}

fn killOthers(r: *redis.Client, c: *db.Ctx) !void {
    _ = try r.command(c, .{ "CLIENT", "KILL", "TYPE", "normal", "SKIPME", "yes" });
}

test "watch live: redis: a stream without a group resumes after the last ID when its connection is killed" {
    if (comptime !features.redis) return error.SkipZigTest;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const r = try redis_live.open(io, .{});
    defer r.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };
    _ = try r.command(&c, .{ "DEL", "anole_stream_a" });
    defer _ = r.command(&c, .{ "DEL", "anole_stream_a" }) catch {};

    const w = try Watch.init(gpa, io, .{ .redis_stream = .{ .client = r, .keys = &.{"anole_stream_a"}, .block = .fromMilliseconds(200) } }, .{});
    defer w.deinit();
    var col: Collector = undefined;
    col.init();
    defer col.deinit();
    w.addSink(&col.sink);
    try w.start(null, null, null);
    defer w.stop();
    try waitConnected(w, io);
    _ = try r.command(&c, .{ "XADD", "anole_stream_a", "*", "n", "e1" });
    try col.waitFor(io, "e1");
    // The connections are killed (the watch's included); one more entry.
    try killOthers(r, &c);
    _ = try r.command(&c, .{ "XADD", "anole_stream_a", "*", "n", "e2" });
    try col.waitFor(io, "e2");
    // Each entry once: e1 was not read again.
    try std.testing.expectEqual(@as(usize, 1), col.count("e1"));
    try std.testing.expectEqual(@as(usize, 1), col.count("e2"));
}

test "watch live: redis: a group redelivers its pending entries before new ones, and a manual ack settles one" {
    if (comptime !features.redis) return error.SkipZigTest;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const r = try redis_live.open(io, .{});
    defer r.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };
    _ = try r.command(&c, .{ "DEL", "anole_stream_g" });
    defer _ = r.command(&c, .{ "DEL", "anole_stream_g" }) catch {};

    const source: root.Source = .{ .redis_stream = .{
        .client = r,
        .keys = &.{"anole_stream_g"},
        .block = .fromMilliseconds(200),
        .group = .{ .name = "g1", .consumer = "c1", .ack = .manual },
    } };
    // First run: two entries read, none acked.
    {
        const w = try Watch.init(gpa, io, source, .{});
        defer w.deinit();
        var col: Collector = undefined;
        col.init();
        defer col.deinit();
        w.addSink(&col.sink);
        try w.start(null, null, null);
        defer w.stop();
        try waitConnected(w, io);
        _ = try r.command(&c, .{ "XADD", "anole_stream_g", "*", "n", "p1" });
        _ = try r.command(&c, .{ "XADD", "anole_stream_g", "*", "n", "p2" });
        try col.waitFor(io, "p2");
    }
    // The watch is gone; one more entry arrives while nobody reads.
    _ = try r.command(&c, .{ "XADD", "anole_stream_g", "*", "n", "n3" });
    // Second run: p1 and p2 again (pending), then n3.
    {
        const w = try Watch.init(gpa, io, source, .{});
        defer w.deinit();
        var col: Collector = undefined;
        col.init();
        defer col.deinit();
        w.addSink(&col.sink);
        try w.start(null, null, null);
        defer w.stop();
        try col.waitFor(io, "n3");
        var buf: [256]u8 = undefined;
        try std.testing.expect(col.total() >= 3);
        try std.testing.expect(col.count("p1") == 1 and col.count("p2") == 1 and col.count("n3") == 1);
        // Order: the pending ones come first.
        col.acquire();
        const first = col.lines.items[0];
        const third = col.lines.items[2];
        col.lock.unlock();
        try std.testing.expect(std.mem.indexOf(u8, first, "p1") != null);
        try std.testing.expect(std.mem.indexOf(u8, third, "n3") != null);
        // Manual ack: XACK of p1's position settles it.
        const line = col.find("p1", &buf).?;
        var parts = std.mem.splitScalar(u8, line, '|');
        _ = parts.next();
        _ = parts.next();
        _ = parts.next();
        _ = parts.next();
        const position = parts.next().?;
        try w.ackEntry("anole_stream_g", position);
        // Wait for the XACK to be sent: the pending count falls to 2.
        for (0..4000) |_| {
            const pending = try r.command(&c, .{ "XPENDING", "anole_stream_g", "g1" });
            const n = pendingCount(pending);
            if (n == 2) break;
            try io.sleep(.fromMilliseconds(5), .awake);
        } else return error.TimedOut;
    }
}

fn pendingCount(reply: redis.Reply) i64 {
    return switch (reply) {
        .array => |items| if (items.len > 0) switch (items[0]) {
            .int => |n| n,
            else => -1,
        } else -1,
        else => -1,
    };
}

test "watch live: redis: entries deleted after the position are a gap (Redis 7)" {
    if (comptime !features.redis) return error.SkipZigTest;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const r = try redis_live.open(io, .{});
    defer r.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };
    _ = try r.command(&c, .{ "DEL", "anole_stream_x" });
    defer _ = r.command(&c, .{ "DEL", "anole_stream_x" }) catch {};
    _ = try r.command(&c, .{ "XADD", "anole_stream_x", "1-1", "n", "a" });
    _ = try r.command(&c, .{ "XADD", "anole_stream_x", "2-1", "n", "b" });
    _ = r.command(&c, .{ "XDEL", "anole_stream_x", "2-1" }) catch {};

    const w = try Watch.init(gpa, io, .{ .redis_stream = .{
        .client = r,
        .keys = &.{"anole_stream_x"},
        .start = .{ .after = &.{"1-1"} },
        .block = .fromMilliseconds(200),
    } }, .{});
    defer w.deinit();
    var col: Collector = undefined;
    col.init();
    defer col.deinit();
    w.addSink(&col.sink);
    try w.start(null, null, null);
    defer w.stop();
    // `max-deleted-entry-id` (2-1) is past the position (1-1).
    try waitGaps(&col, io, 1);
}

// ---------------------------------------------------------------------------
// MongoDB

test "watch live: mongodb: insert, update and delete arrive with fullDocument; a dropped collection ends the stream and the watch follows the re-created one" {
    if (comptime !features.mongodb) return error.SkipZigTest;
    const url = features.mongodb_test_url orelse return error.SkipZigTest;
    const mongodb = @import("../mongodb/root.zig");
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    const client = try mongodb.Client.init(gpa, io, .{ .url = url, .database = "anole_test", .server_selection_timeout = .fromSeconds(10) });
    defer client.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };
    var random: [4]u8 = undefined;
    io.random(&random);
    var name_buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "w_{x}", .{std.mem.readInt(u32, &random, .little)});
    const coll = client.collection(name);
    // The collection has to exist for the stream to follow it across a drop.
    _ = try coll.insertOne(&c, .{ .name = "seed", .n = 0 });
    defer coll.drop(&c) catch {};

    const w = try Watch.init(gpa, io, .{ .mongodb = .{
        .client = client,
        .collection = name,
        .full_document = .update_lookup,
        .max_await = .fromMilliseconds(200),
    } }, .{});
    defer w.deinit();
    var col: Collector = undefined;
    col.init();
    defer col.deinit();
    w.addSink(&col.sink);
    try w.start(null, null, null);
    defer w.stop();
    try waitConnected(w, io);

    _ = try coll.insertOne(&c, .{ .name = "ada", .n = 1 });
    try col.waitFor(io, "insert|");
    _ = try coll.updateOne(&c, .{ .name = "ada" }, .{ .@"$set" = .{ .n = 2 } }, .{});
    try col.waitFor(io, "update|");
    var buf: [1024]u8 = undefined;
    // update_lookup: the whole document with the new value.
    try std.testing.expect(std.mem.indexOf(u8, col.find("update|", &buf).?, "\"name\"") != null);
    _ = try coll.deleteOne(&c, .{ .name = "ada" }, .{});
    try col.waitFor(io, "delete|");

    // The collection goes away: drop, then invalidate; the watch reopens
    // after the invalidate and hears the re-created collection.
    try coll.drop(&c);
    try col.waitFor(io, "drop|");
    try col.waitFor(io, "invalidate|");
    var sent: u32 = 0;
    while (col.count("\"name\":\"bob\"") == 0) {
        _ = try coll.insertOne(&c, .{ .name = "bob", .n = 3 });
        sent += 1;
        try std.testing.expect(sent < 400);
        try io.sleep(.fromMilliseconds(50), .awake);
    }
}
