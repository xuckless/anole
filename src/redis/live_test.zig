//! anole.redis against a live Redis or Valkey: `-Dredis-test-url=redis://...`
//! (or `-Dredis-test-port=6379` for one on 127.0.0.1 without a password).
//! tests/redis/run.sh starts both servers in Docker and runs these plain
//! and over TLS. Without either option they skip.
const std = @import("std");
const features = @import("build_options");
const zio = @import("zio");
const dusty = @import("dusty");
const http = @import("../http/root.zig");
const db = @import("../db/root.zig");
const internal = @import("../db/internal.zig");
const redis = @import("root.zig");
const server_mod = @import("../server.zig");
const client_mod = @import("../client.zig");

const testing = std.testing;
const gpa = testing.allocator;

/// The server the live tests use, or null: they skip.
pub const url: ?[]const u8 = if (features.redis_test_url) |u|
    u
else if (features.redis_test_port) |p|
    std.fmt.comptimePrint("redis://127.0.0.1:{d}", .{p})
else
    null;

fn testUrl() ![]const u8 {
    return url orelse error.SkipZigTest;
}

/// A client on `io` for the test URL, unaffected by the environment.
pub fn open(io: std.Io, opts: redis.Options) !*redis.Client {
    var o = opts;
    if (o.url == null) o.url = try testUrl();
    o.environ = .empty;
    return redis.Client.init(gpa, io, o);
}

/// Quiets the warnings that failing calls log (5xx classes), for tests
/// that fail calls on purpose; returns the level to put back.
fn quiet() std.log.Level {
    const level = testing.log_level;
    testing.log_level = .err;
    return level;
}

const Plan = enum { free, pro };
const Profile = struct { name: []const u8, visits: u32, plan: Plan = .free, bio: ?[]const u8 = null };

test "redis: live calls, helpers and replies into types" {
    _ = try testUrl();
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const r = try open(io, .{});
    defer r.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };

    _ = try r.del(&c, .{ "anole:test:k", "anole:test:n", "anole:test:h", "anole:test:l", "anole:test:s", "anole:test:z", "anole:test:lock" });
    // Strings, binary safe.
    try testing.expect(try r.set(&c, "anole:test:k", "v\x00binary", .{}));
    try testing.expectEqualStrings("v\x00binary", (try r.get(&c, "anole:test:k")).?);
    try testing.expect(try r.get(&c, "anole:test:none") == null);
    try testing.expectError(error.NotFound, r.one([]const u8, &c, .{ "GET", "anole:test:none" }));
    // NX, and a TTL in seconds or milliseconds.
    try testing.expect(try r.set(&c, "anole:test:lock", "a", .{ .nx = true, .ttl = .fromSeconds(30) }));
    try testing.expect(!try r.set(&c, "anole:test:lock", "b", .{ .nx = true, .ttl = .fromSeconds(30) }));
    const ttl = try r.one(i64, &c, .{ "TTL", "anole:test:lock" });
    try testing.expect(ttl > 0 and ttl <= 30);
    try testing.expect(try r.expire(&c, "anole:test:lock", .fromMilliseconds(1500)));
    const pttl = try r.one(i64, &c, .{ "PTTL", "anole:test:lock" });
    try testing.expect(pttl > 0 and pttl <= 1500);
    try testing.expect(!try r.expire(&c, "anole:test:none", .fromSeconds(5)));
    // Counters.
    try testing.expectEqual(@as(i64, 1), try r.incr(&c, "anole:test:n"));
    try testing.expectEqual(@as(i64, 11), try r.incrBy(&c, "anole:test:n", 10));
    try testing.expectEqual(@as(u32, 11), try r.one(u32, &c, .{ "GET", "anole:test:n" }));
    // A hash from a struct and back.
    try testing.expectEqual(@as(u64, 2), try r.hset(&c, "anole:test:h", .{ .name = "Ada", .visits = 1 }));
    try testing.expectEqual(@as(i64, 2), try r.hincrBy(&c, "anole:test:h", "visits", 1));
    const p = try r.hgetAll(Profile, &c, "anole:test:h");
    try testing.expectEqualStrings("Ada", p.name);
    try testing.expectEqual(@as(u32, 2), p.visits);
    try testing.expectEqual(Plan.free, p.plan);
    try testing.expectEqualStrings("Ada", (try r.hget(&c, "anole:test:h", "name")).?);
    try testing.expectError(error.NotFound, r.hgetAll(Profile, &c, "anole:test:none"));
    try testing.expect(try r.optional(Profile, &c, .{ "HGETALL", "anole:test:none" }) == null);
    try testing.expectEqual(@as(u64, 1), try r.hdel(&c, "anole:test:h", .{"visits"}));
    // Lists, sets, sorted sets.
    try testing.expectEqual(@as(u64, 3), try r.rpush(&c, "anole:test:l", .{ "a", "b", "c" }));
    try testing.expectEqual(@as(u64, 4), try r.lpush(&c, "anole:test:l", "z"));
    const list = try r.lrange(&c, "anole:test:l", 0, -1);
    try testing.expectEqual(@as(usize, 4), list.len);
    try testing.expectEqualStrings("z", list[0]);
    const members: []const []const u8 = &.{ "x", "y" };
    try testing.expectEqual(@as(u64, 2), try r.sadd(&c, "anole:test:s", members));
    try testing.expect(try r.sismember(&c, "anole:test:s", "x"));
    try testing.expectEqual(@as(u64, 1), try r.srem(&c, "anole:test:s", "x"));
    try testing.expectEqual(@as(usize, 1), (try r.smembers(&c, "anole:test:s")).len);
    try testing.expect(try r.zadd(&c, "anole:test:z", 10, "ann"));
    try testing.expect(try r.zadd(&c, "anole:test:z", 20, "bob"));
    try testing.expect(!try r.zadd(&c, "anole:test:z", 5, "ann"));
    try testing.expectEqual(@as(f64, 30), try r.zincrBy(&c, "anole:test:z", 25, "ann"));
    try testing.expectEqual(@as(?f64, 20), try r.zscore(&c, "anole:test:z", "bob"));
    try testing.expect(try r.zscore(&c, "anole:test:z", "nobody") == null);
    const top = try r.zrangeWithScores(&c, "anole:test:z", 0, 9, .{ .rev = true });
    try testing.expectEqualStrings("ann", top[0].member);
    try testing.expectEqual(@as(f64, 30), top[0].score);
    try testing.expectEqualStrings("bob", (try r.zrange(&c, "anole:test:z", 0, 0, .{}))[0]);
    try testing.expectEqual(@as(u64, 1), try r.zrem(&c, "anole:test:z", "bob"));
    // Several keys at once, missing ones as null.
    const got = try r.all(?[]const u8, &c, .{ "MGET", "anole:test:k", "anole:test:none" });
    try testing.expect(got[0] != null and got[1] == null);
    try testing.expectEqual(@as(u64, 0), try r.publish(&c, "anole:test:nobody-listens", "hi"));

    // A server error: a 500 with the message kept; the connection serves on.
    const level = quiet();
    defer testing.log_level = level;
    try testing.expectError(error.Database, r.lpush(&c, "anole:test:k", "x"));
    const detail = db.lastError(&c).?;
    try testing.expectEqualStrings("WRONGTYPE", detail.code);
    try testing.expectEqual(db.System.redis, detail.system);
    try testing.expectError(error.Database, r.command(&c, .{"NOSUCHCOMMAND"}));
    // A reply that does not fit the type asked for.
    try testing.expectError(error.Database, r.one(i64, &c, .{ "GET", "anole:test:k" }));
    try testing.expectEqualStrings("v\x00binary", (try r.get(&c, "anole:test:k")).?);
    // `Options.errors` moves a class.
    const strict = try open(io, .{ .errors = .{ .other = .bad_request } });
    defer strict.deinit();
    try testing.expectError(error.BadRequest, strict.lpush(&c, "anole:test:k", "x"));
}

test "redis: live pipelines, MULTI/EXEC, and WATCH on an acquired connection" {
    _ = try testUrl();
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const r = try open(io, .{ .max_connections = 2 });
    defer r.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };
    const pool = &r.pools.pools[0];

    _ = try r.del(&c, .{ "anole:test:p", "anole:test:stock" });
    const replies = try r.pipeline(&c, .{ .{ "INCR", "anole:test:p" }, .{ "EXPIRE", "anole:test:p", 60 }, .{ "GET", "anole:test:p" } });
    try testing.expectEqual(@as(i64, 1), replies[0].int);
    try testing.expectEqual(@as(i64, 1), replies[1].int);
    try testing.expectEqualStrings("1", replies[2].string);
    // MULTI ... EXEC in one round trip; the connection goes back clean.
    const tx = try r.pipeline(&c, .{ .{"MULTI"}, .{ "INCR", "anole:test:p" }, .{ "INCR", "anole:test:p" }, .{"EXEC"} });
    try testing.expectEqual(@as(i64, 3), tx[3].array[1].int);
    try testing.expectEqual(@as(usize, 1), pool.open);
    // A slice of commands works as well.
    const cmds: []const []const []const u8 = &.{ &.{ "GET", "anole:test:p" }, &.{"PING"} };
    try testing.expectEqualStrings("PONG", (try r.pipeline(&c, cmds))[1].status);

    // WATCH: optimistic locking across round trips on one connection.
    _ = try r.set(&c, "anole:test:stock", 5, .{});
    {
        var conn = try r.acquire(&c);
        defer conn.release();
        const id = try conn.one(i64, &c, .{ "CLIENT", "ID" });
        _ = try conn.command(&c, .{ "WATCH", "anole:test:stock" });
        const stock = try conn.one(i64, &c, .{ "GET", "anole:test:stock" });
        // Another connection changes the key in between.
        _ = try r.set(&c, "anole:test:stock", 100, .{});
        const r1 = try conn.pipeline(&c, .{ .{"MULTI"}, .{ "SET", "anole:test:stock", stock - 1 }, .{"EXEC"} });
        try testing.expect(r1[2] == .nil);
        try testing.expectEqual(id, try conn.one(i64, &c, .{ "CLIENT", "ID" }));
    }
    try testing.expectEqual(@as(i64, 100), try r.one(i64, &c, .{ "GET", "anole:test:stock" }));
    try testing.expectEqual(@as(usize, 2), pool.idle_len);

    // A connection moved to another database is closed on release, not
    // handed to the next call.
    {
        var conn = try r.acquire(&c);
        defer conn.release();
        _ = try conn.command(&c, .{ "SELECT", 9 });
    }
    try testing.expectEqual(@as(usize, 1), pool.open);
    try testing.expectEqual(@as(i64, 100), try r.one(i64, &c, .{ "GET", "anole:test:stock" }));
}

test "redis: live pub/sub on a connection of its own" {
    _ = try testUrl();
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const r = try open(io, .{});
    defer r.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };

    const sub = try r.subscribe(&c, .{ "anole:test:chat", "anole:test:news" });
    defer sub.close();
    // Confirmed when `subscribe` returns: the first message reaches it.
    try testing.expectEqual(@as(u64, 1), try r.publish(&c, "anole:test:chat", "hello"));
    var msg = (try sub.next(&c)).?;
    try testing.expectEqualStrings("anole:test:chat", msg.channel);
    try testing.expectEqualStrings("hello", msg.payload);
    try testing.expect(msg.pattern == null);

    try sub.psubscribe(&c, "anole:test:room:*");
    // Its confirmation comes first; `next` skips it.
    for (0..50) |_| {
        if (try r.publish(&c, "anole:test:room:1", "pattern") == 1) break;
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    msg = (try sub.next(&c)).?;
    try testing.expectEqualStrings("anole:test:room:*", msg.pattern.?);
    try testing.expectEqualStrings("anole:test:room:1", msg.channel);
    try testing.expectEqualStrings("pattern", msg.payload);

    // Waiting in another task; a publish wakes it.
    const Waiter = struct {
        fn run(s: *redis.Subscriber, io_: std.Io) ![]const u8 {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            var ctx: db.Ctx = .{ .io = io_, .arena = arena.allocator() };
            const m = (try s.next(&ctx)).?;
            return if (std.mem.eql(u8, m.payload, "late")) "late" else "other";
        }
    };
    var waiting = try io.concurrent(Waiter.run, .{ sub, io });
    try io.sleep(.fromMilliseconds(20), .awake);
    _ = try r.publish(&c, "anole:test:news", "late");
    try testing.expectEqualStrings("late", try waiting.await(io));

    // Nothing left subscribed: null.
    try sub.unsubscribe(&c, .{});
    try sub.punsubscribe(&c, .{});
    try testing.expect(try sub.next(&c) == null);

    // `stop` from another task ends a `next` that waits.
    const other = try r.psubscribe(&c, "anole:test:quiet:*");
    defer other.close();
    const Stopper = struct {
        fn run(s: *redis.Subscriber, io_: std.Io) std.Io.Cancelable!void {
            try io_.sleep(.fromMilliseconds(50), .awake);
            s.stop();
        }
    };
    var stopping = try io.concurrent(Stopper.run, .{ other, io });
    try testing.expect(try other.next(&c) == null);
    try stopping.await(io);
}

test "redis: live a timeout or a cancel closes the connection, and the next call gets another" {
    _ = try testUrl();
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const r = try open(io, .{ .max_connections = 1 });
    defer r.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };
    const level = quiet();
    defer testing.log_level = level;

    const first = try r.one(i64, &c, .{ "CLIENT", "ID" });
    const started: std.Io.Clock.Timestamp = .now(io, .awake);
    try testing.expectError(error.GatewayTimeout, r.with(.{ .timeout = .fromMilliseconds(100) }).command(&c, .{ "BLPOP", "anole:test:empty", 10 }));
    try testing.expect(started.durationTo(.now(io, .awake)).raw.toMilliseconds() < 3000);
    try testing.expectEqual(db.Class.timeout, db.lastError(&c).?.class);
    const second = try r.one(i64, &c, .{ "CLIENT", "ID" });
    try testing.expect(second != first);

    // The task canceled (a request's deadline, an HTTP/2 reset).
    const Blocker = struct {
        fn run(cl: *redis.Client, io_: std.Io) !void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            var ctx: db.Ctx = .{ .io = io_, .arena = arena.allocator() };
            _ = try cl.command(&ctx, .{ "BLPOP", "anole:test:empty", 10 });
        }
    };
    var task = try io.concurrent(Blocker.run, .{ r, io });
    try io.sleep(.fromMilliseconds(100), .awake);
    try testing.expectError(error.Canceled, task.cancel(io));
    try testing.expect(try r.one(i64, &c, .{ "CLIENT", "ID" }) != second);
    try testing.expectEqual(@as(usize, 1), r.pools.pools[0].open);
}

test "redis: live a pool per executor" {
    _ = try testUrl();
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(4) });
    defer rt.deinit();
    const io = rt.io();
    const r = try open(io, .{ .max_connections = 4 });
    defer r.deinit();

    const Worker = struct {
        fn run(cl: *redis.Client, io_: std.Io, ids: *[4]std.atomic.Value(i64), wrong: *std.atomic.Value(u32)) void {
            calls(cl, io_, ids, wrong) catch {
                _ = wrong.fetchAdd(1, .monotonic);
            };
        }

        fn calls(cl: *redis.Client, io_: std.Io, ids: *[4]std.atomic.Value(i64), wrong: *std.atomic.Value(u32)) !void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            var ctx: db.Ctx = .{ .io = io_, .arena = arena.allocator() };
            const here = internal.executorIndex(io_).?;
            for (0..10) |_| {
                const id = try cl.one(i64, &ctx, .{ "CLIENT", "ID" });
                // Each executor keeps to its one connection.
                if (ids[here].cmpxchgStrong(0, id, .monotonic, .monotonic)) |seen| {
                    if (seen != id) _ = wrong.fetchAdd(1, .monotonic);
                }
            }
        }
    };
    var ids: [4]std.atomic.Value(i64) = @splat(.init(0));
    var wrong: std.atomic.Value(u32) = .init(0);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (0..16) |i| try dusty.placement.concurrent(&group, io, .{ .executor = i % 4 }, Worker.run, .{ r, io, &ids, &wrong });
    try group.await(io);
    try testing.expectEqual(@as(u32, 0), wrong.load(.monotonic));
    for (&ids, 0..) |*p, i| {
        try testing.expect(p.load(.monotonic) != 0);
        for (ids[i + 1 ..]) |*q| try testing.expect(p.load(.monotonic) != q.load(.monotonic));
    }
}

test "redis: live TLS as the URL asks, and a refused login" {
    const base = try testUrl();
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var c: db.Ctx = .{ .io = io, .arena = arena };

    const r = try open(io, .{ .max_connections = 1 });
    defer r.deinit();
    try testing.expectEqualStrings("PONG", (try r.command(&c, .{"PING"})).status);
    const conn = r.pools.pools[0].idle[0];
    try testing.expectEqual(r.settings.tls, conn.stream.isTls());
    // The URL's database, selected at login.
    const info = try r.one([]const u8, &c, .{ "CLIENT", "INFO" });
    var db_field_buf: [16]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, info, try std.fmt.bufPrint(&db_field_buf, " db={d} ", .{r.settings.database})) != null);

    // A wrong password: a 503, the server's reason kept.
    const s = r.settings;
    if (s.password == null) return;
    const parsed = try db.Url.parse(arena, base);
    const bad_url = try std.mem.replaceOwned(u8, arena, base, try std.fmt.allocPrint(arena, ":{s}@", .{parsed.password.?}), ":not-the-password@");
    const level = quiet();
    defer testing.log_level = level;
    const refused = try redis.Client.init(gpa, io, .{ .url = bad_url, .environ = .empty });
    defer refused.deinit();
    try testing.expectError(error.ServiceUnavailable, refused.get(&c, "anole:test:k"));
    const detail = db.lastError(&c).?;
    try testing.expectEqual(db.Class.unavailable, detail.class);
    try testing.expect(std.mem.eql(u8, detail.code, "WRONGPASS") or std.mem.eql(u8, detail.code, "ERR"));
    try testing.expect(!refused.readiness.ping(refused, io));
}

const AppState = struct {
    redis: *redis.Client,
};

const AppRoutes = struct {
    fn hits(app: *AppState, req: *http.Request, res: *http.Response) !void {
        try res.json(.{ .hits = try app.redis.incr(req, "anole:test:hits") });
    }

    fn profile(app: *AppState, req: *http.Request, res: *http.Response) !void {
        const id = req.params.get("id") orelse return error.NotFound;
        const key = try std.fmt.allocPrint(req.arena, "anole:test:profile:{s}", .{id});
        try res.json(try app.redis.hgetAll(Profile, req, key));
    }

    /// Messages as Server-Sent Events, until the drain ends the
    /// subscription.
    fn events(app: *AppState, req: *http.Request, res: *http.Response) !void {
        req.setTimeout(.none);
        const sub = try app.redis.subscribe(req, "anole:test:events");
        defer sub.close();
        var buf: [256]u8 = undefined;
        var stream = try res.startEventStream(&buf);
        while (try sub.next(req)) |msg| try stream.send(msg.payload, .{});
        try stream.body.end();
    }
};

test "redis: live app.redis: handlers, statuses, /readyz and /metrics" {
    const test_url = try testUrl();
    var state: AppState = undefined;
    var app = try server_mod.Server(AppState).init(gpa, .{ .executors = .exact(2) }, &state);
    defer app.deinit();
    // Before `metrics` and `health`: it reaches them when serving starts.
    state.redis = try app.redis(.{ .url = test_url, .environ = .empty });
    _ = app.metrics(.{});
    _ = app.health(.{});
    app.get("/hits", AppRoutes.hits);
    app.get("/profiles/:id", AppRoutes.profile);
    app.get("/events", AppRoutes.events);
    {
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        var c: db.Ctx = .{ .io = app.io(), .arena = arena_state.allocator() };
        _ = try state.redis.del(&c, .{ "anole:test:hits", "anole:test:profile:1" });
        _ = try state.redis.hset(&c, "anole:test:profile:1", .{ .name = "Ada", .visits = 7 });
    }

    const Check = struct {
        fn fetch(io: std.Io, arena: std.mem.Allocator, method: http.Method, target: []const u8) !struct { http.Status, []const u8 } {
            var resp = try client_mod.client(io).fetch(target, .{ .method = method });
            defer resp.deinit();
            return .{ resp.status(), try arena.dupe(u8, try resp.body()) };
        }

        fn run(a: *server_mod.Server(AppState), cache: *redis.Client) !void {
            defer a.stop();
            const io = a.io();
            try a.waitReady();
            var arena_state: std.heap.ArenaAllocator = .init(gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const port = a.addresses()[0].ip.getPort();
            const at = struct {
                fn f(ar: std.mem.Allocator, p: u16, path: []const u8) ![]const u8 {
                    return std.fmt.allocPrint(ar, "http://127.0.0.1:{d}{s}", .{ p, path });
                }
            }.f;

            try testing.expectEqualStrings("{\"hits\":1}", (try fetch(io, arena, .get, try at(arena, port, "/hits")))[1]);
            try testing.expectEqualStrings("{\"hits\":2}", (try fetch(io, arena, .get, try at(arena, port, "/hits")))[1]);
            try testing.expectEqualStrings("{\"name\":\"Ada\",\"visits\":7,\"plan\":\"free\",\"bio\":null}", (try fetch(io, arena, .get, try at(arena, port, "/profiles/1")))[1]);
            const level = quiet();
            defer testing.log_level = level;
            try testing.expectEqual(http.Status.not_found, (try fetch(io, arena, .get, try at(arena, port, "/profiles/2")))[0]);
            try testing.expectEqual(http.Status.ok, (try fetch(io, arena, .get, try at(arena, port, "/readyz")))[0]);

            const scraped = (try fetch(io, arena, .get, try at(arena, port, "/metrics")))[1];
            const expect = [_][]const u8{
                "anole_db_query_duration_seconds_count{system=\"redis\",db=\"redis\"} 4",
                "anole_db_errors_total{system=\"redis\",db=\"redis\",error=\"NotFound\"} 1",
                "anole_db_pool_connections{system=\"redis\",db=\"redis\",state=\"in_use\"} 0",
            };
            for (expect) |line| {
                if (std.mem.indexOf(u8, scraped, line) == null) {
                    std.debug.print("not in /metrics: {s}\n{s}\n", .{ line, scraped });
                    return error.TestUnexpectedResult;
                }
            }

            // An event stream fed by a subscription ends when the server
            // drains, well before the drain's 30 s deadline.
            var streaming = try io.concurrent(fetch, .{ io, arena, http.Method.get, try at(arena, port, "/events") });
            var c: db.Ctx = .{ .io = io, .arena = arena };
            for (0..200) |_| {
                if (try cache.publish(&c, "anole:test:events", "hi") == 1) break;
                try io.sleep(.fromMilliseconds(10), .awake);
            } else return error.TestUnexpectedResult;
            const stopping: std.Io.Clock.Timestamp = .now(io, .awake);
            a.stop();
            const got = try streaming.await(io);
            try testing.expect(stopping.durationTo(.now(io, .awake)).raw.toMilliseconds() < 5000);
            try testing.expectEqualStrings("data: hi\n\n", got[1]);
        }
    };
    var checking = try app.io().concurrent(Check.run, .{ &app, state.redis });
    try app.listen("127.0.0.1:0");
    try checking.await(app.io());
}
