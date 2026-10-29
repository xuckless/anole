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

/// Sends `sql` (a NOTIFY) until `col` holds `needle`: the hub reports
/// connected before the server has answered its LISTEN, so one NOTIFY
/// right after `waitConnected` can arrive before anyone listens.
fn notifyUntilHeard(io: std.Io, client: *pg.Client, c: *db.Ctx, col: *Collector, sql: []const u8, needle: []const u8) !void {
    const Notify = struct {
        col: *Collector,
        client: *pg.Client,
        c: *db.Ctx,
        sql: []const u8,
        needle: []const u8,
        fn heard(n: @This()) !bool {
            if (n.col.count(n.needle) != 0) return true;
            _ = try n.client.exec(n.c, n.sql, .{});
            return false;
        }
    };
    wait.waitUntil(io, "a NOTIFY heard once the LISTEN is in place", Notify{ .col = col, .client = client, .c = c, .sql = sql, .needle = needle }, Notify.heard) catch |err| {
        std.debug.print("waiting for \"{s}\" failed\n", .{needle});
        return err;
    };
}

test "watch live: postgres: two watches on one hub hear only their own channels" {
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

    try notifyUntilHeard(io, client, &c, &ca, "NOTIFY anole_wa, 'one'", "|anole_wa|one|");
    try notifyUntilHeard(io, client, &c, &cb, "NOTIFY anole_wb, 'two'", "|anole_wb|two|");
    try std.testing.expectEqual(@as(usize, 0), ca.count("two"));
    try std.testing.expectEqual(@as(usize, 0), cb.count("one"));
}

test "watch live: postgres: a killed LISTEN backend gives a gap and the watch hears later NOTIFYs" {
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

    const w = try Watch.init(gpa, io, .{ .postgres = .{ .client = client, .channels = &.{"anole_wk"} } }, .{});
    defer w.deinit();
    var col: Collector = undefined;
    col.init();
    defer col.deinit();
    w.addSink(&col.sink);
    try w.start(null, null, null);
    defer w.stop();
    try waitConnected(w, io);
    // The LISTEN is in place (and its backend's last query is the LISTEN).
    try notifyUntilHeard(io, client, &c, &col, "NOTIFY anole_wk, 'before'", "|anole_wk|before|");

    _ = try client.all(bool, &c, "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE query ILIKE 'LISTEN %' AND pid <> pg_backend_pid()", .{});
    try waitGaps(&col, io, 1);
    // The LISTEN may not be back yet: notify until it is heard.
    try notifyUntilHeard(io, client, &c, &col, "NOTIFY anole_wk, 'after'", "|anole_wk|after|");
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
    const Publish = struct {
        col: *Collector,
        r: *redis.Client,
        c: *db.Ctx,
        fn heard(p: @This()) !bool {
            if (p.col.count("|anole_room:7|hello|anole_room:*|") != 0) return true;
            _ = try p.r.command(p.c, .{ "PUBLISH", "anole_room:7", "hello" });
            return false;
        }
    };
    try wait.waitUntil(io, "a PUBLISH heard by the pattern watch", Publish{ .col = &col, .r = r, .c = &c }, Publish.heard);
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

test "watch live: redis: a group redelivers its pending entries before new ones" {
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
        try std.testing.expect(col.total() >= 3);
        try std.testing.expect(col.count("p1") == 1 and col.count("p2") == 1 and col.count("n3") == 1);
        // Order: the pending ones come first.
        col.acquire();
        const first = col.lines.items[0];
        const third = col.lines.items[2];
        col.lock.unlock();
        try std.testing.expect(std.mem.indexOf(u8, first, "p1") != null);
        try std.testing.expect(std.mem.indexOf(u8, third, "n3") != null);
    }
}

test "watch live: redis: a manual ack settles one entry" {
    if (comptime !features.redis) return error.SkipZigTest;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const r = try redis_live.open(io, .{});
    defer r.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };
    _ = try r.command(&c, .{ "DEL", "anole_stream_m" });
    defer _ = r.command(&c, .{ "DEL", "anole_stream_m" }) catch {};

    const w = try Watch.init(gpa, io, .{ .redis_stream = .{
        .client = r,
        .keys = &.{"anole_stream_m"},
        .block = .fromMilliseconds(200),
        .group = .{ .name = "g1", .consumer = "c1", .ack = .manual },
    } }, .{});
    defer w.deinit();
    var col: Collector = undefined;
    col.init();
    defer col.deinit();
    w.addSink(&col.sink);
    try w.start(null, null, null);
    defer w.stop();
    try waitConnected(w, io);
    _ = try r.command(&c, .{ "XADD", "anole_stream_m", "*", "n", "p1" });
    _ = try r.command(&c, .{ "XADD", "anole_stream_m", "*", "n", "p2" });
    try col.waitFor(io, "p2");
    // Both read, neither acked: XACK of p1's position settles it alone.
    var buf: [256]u8 = undefined;
    const line = col.find("p1", &buf).?;
    var parts = std.mem.splitScalar(u8, line, '|');
    _ = parts.next();
    _ = parts.next();
    _ = parts.next();
    _ = parts.next();
    const position = parts.next().?;
    try w.ackEntry("anole_stream_m", position);
    // Wait for the XACK to be sent: the pending count falls to 1.
    const Pending = struct {
        r: *redis.Client,
        c: *db.Ctx,
        fn one(p: @This()) !bool {
            return pendingCount(try p.r.command(p.c, .{ "XPENDING", "anole_stream_m", "g1" })) == 1;
        }
    };
    try wait.waitUntil(io, "the XACK settled p1 (one pending)", Pending{ .r = r, .c = &c }, Pending.one);
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
    // CI's servers (redis:7, valkey:8) all keep max-deleted-entry-id: no version skip.
    _ = try r.command(&c, .{ "XDEL", "anole_stream_x", "2-1" });

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

const mongodb = @import("../mongodb/root.zig");

/// A live MongoDB client, a fresh collection (seeded, so it exists for the
/// stream to follow across a drop) and a started watch on it.
const MongoFx = struct {
    rt: *zio.Runtime,
    client: *mongodb.Client,
    arena_state: std.heap.ArenaAllocator,
    c: db.Ctx,
    name_buf: [32]u8,
    name: []const u8,
    w: *Watch,
    col: Collector,

    fn setup(fx: *MongoFx, url: []const u8) !void {
        fx.rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
        errdefer fx.rt.deinit();
        const io = fx.rt.io();
        fx.client = try mongodb.Client.init(gpa, io, .{ .url = url, .database = "anole_test", .server_selection_timeout = .fromSeconds(10) });
        errdefer fx.client.deinit();
        fx.arena_state = .init(gpa);
        errdefer fx.arena_state.deinit();
        fx.c = .{ .io = io, .arena = fx.arena_state.allocator() };
        var random: [4]u8 = undefined;
        io.random(&random);
        fx.name = try std.fmt.bufPrint(&fx.name_buf, "w_{x}", .{std.mem.readInt(u32, &random, .little)});
        const coll = fx.client.collection(fx.name);
        _ = try coll.insertOne(&fx.c, .{ .name = "seed", .n = 0 });
        errdefer coll.drop(&fx.c) catch {};
        fx.w = try Watch.init(gpa, io, .{ .mongodb = .{
            .client = fx.client,
            .collection = fx.name,
            .full_document = .update_lookup,
            .max_await = .fromMilliseconds(200),
        } }, .{});
        errdefer fx.w.deinit();
        fx.col.init();
        errdefer fx.col.deinit();
        fx.w.addSink(&fx.col.sink);
        try fx.w.start(null, null, null);
        errdefer fx.w.stop();
        try waitConnected(fx.w, io);
    }

    fn deinit(fx: *MongoFx) void {
        fx.w.stop();
        fx.client.collection(fx.name).drop(&fx.c) catch {};
        fx.w.deinit();
        fx.col.deinit();
        fx.arena_state.deinit();
        fx.client.deinit();
        fx.rt.deinit();
    }
};

test "watch live: mongodb: insert, update and delete arrive with fullDocument" {
    if (comptime !features.mongodb) return error.SkipZigTest;
    const url = features.mongodb_test_url orelse return error.SkipZigTest;
    var fx: MongoFx = undefined;
    try fx.setup(url);
    defer fx.deinit();
    const io = fx.rt.io();
    const coll = fx.client.collection(fx.name);

    _ = try coll.insertOne(&fx.c, .{ .name = "ada", .n = 1 });
    try fx.col.waitFor(io, "insert|");
    _ = try coll.updateOne(&fx.c, .{ .name = "ada" }, .{ .@"$set" = .{ .n = 2 } }, .{});
    try fx.col.waitFor(io, "update|");
    var buf: [1024]u8 = undefined;
    // update_lookup: the whole document with the new value.
    try std.testing.expect(std.mem.indexOf(u8, fx.col.find("update|", &buf).?, "\"name\"") != null);
    _ = try coll.deleteOne(&fx.c, .{ .name = "ada" }, .{});
    try fx.col.waitFor(io, "delete|");
}

test "watch live: mongodb: a dropped collection ends the stream and the watch follows the re-created one" {
    if (comptime !features.mongodb) return error.SkipZigTest;
    const url = features.mongodb_test_url orelse return error.SkipZigTest;
    var fx: MongoFx = undefined;
    try fx.setup(url);
    defer fx.deinit();
    const io = fx.rt.io();
    const coll = fx.client.collection(fx.name);

    // The collection goes away: drop, then invalidate; the watch reopens
    // after the invalidate and hears the re-created collection.
    try coll.drop(&fx.c);
    try fx.col.waitFor(io, "drop|");
    try fx.col.waitFor(io, "invalidate|");
    // The stream may not be open again yet: insert until it is heard.
    const Insert = struct {
        col: *Collector,
        coll: *const @TypeOf(coll),
        c: *db.Ctx,
        fn heard(i: @This()) !bool {
            if (i.col.count("\"name\":\"bob\"") != 0) return true;
            _ = try i.coll.insertOne(i.c, .{ .name = "bob", .n = 3 });
            return false;
        }
    };
    try wait.waitUntil(io, "an insert heard once the stream reopened", Insert{ .col = &fx.col, .coll = &coll, .c = &fx.c }, Insert.heard);
}
