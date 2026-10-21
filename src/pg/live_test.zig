//! anole.pg against a live PostgreSQL: `-Dpostgres-test-url=postgres://...`
//! (tests/postgres/run.sh starts one in Docker and runs these plain and
//! over TLS). Without it they skip.
const std = @import("std");
const features = @import("build_options");
const zio = @import("zio");
const dusty = @import("dusty");
const http = @import("../http/root.zig");
const db = @import("../db/root.zig");
const pg = @import("root.zig");
const server_mod = @import("../server.zig");
const client_mod = @import("../client.zig");

const testing = std.testing;
const gpa = testing.allocator;

fn testUrl() ![]const u8 {
    return features.postgres_test_url orelse error.SkipZigTest;
}

/// A database on `io` for the test URL, unaffected by the environment.
fn open(io: std.Io, opts: pg.Options) !*pg.Db {
    var o = opts;
    if (o.url == null) o.url = try testUrl();
    o.environ = .empty;
    return pg.Db.init(gpa, io, o);
}

/// Quiets the warnings that failing calls log (5xx classes), for tests
/// that fail calls on purpose; returns the level to put back.
fn quiet() std.log.Level {
    const level = testing.log_level;
    testing.log_level = .err;
    return level;
}

const Kind = enum { note, link };
const Meta = struct { lang: []const u8, words: u32 = 0 };

const Post = struct {
    id: i64,
    user_id: u32,
    body: []const u8,
    tags: []const []const u8,
    meta: ?Meta,
    score: f64,
    score_text: []const u8,
    created_at: db.Time,
    published: ?db.Time,
    kind: Kind,
    uid: []const u8,
    /// Not selected: keeps its default.
    extra: u8 = 7,
};

const schema =
    \\DROP TABLE IF EXISTS anole_pg_posts, anole_pg_users, anole_pg_accounts;
    \\DROP TYPE IF EXISTS anole_pg_kind;
    \\CREATE TYPE anole_pg_kind AS ENUM ('note', 'link');
    \\CREATE TABLE anole_pg_users (id serial PRIMARY KEY, email text UNIQUE NOT NULL);
    \\CREATE TABLE anole_pg_posts (
    \\  id bigserial PRIMARY KEY,
    \\  user_id int NOT NULL REFERENCES anole_pg_users (id),
    \\  body text NOT NULL,
    \\  tags text[] NOT NULL DEFAULT '{}',
    \\  meta jsonb,
    \\  score numeric(10, 2) NOT NULL DEFAULT 0,
    \\  created_at timestamptz NOT NULL DEFAULT now(),
    \\  published date,
    \\  kind anole_pg_kind NOT NULL DEFAULT 'note',
    \\  uid uuid NOT NULL DEFAULT gen_random_uuid()
    \\);
    \\CREATE TABLE anole_pg_accounts (id int PRIMARY KEY, cents bigint NOT NULL);
    \\INSERT INTO anole_pg_accounts VALUES (1, 100), (2, 0);
;

test "pg: live verbs, rows into structs, and errors as statuses" {
    _ = try testUrl();
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const d = try open(io, .{ .max_connections = 1 });
    defer d.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };

    // Several statements in one call (no arguments).
    _ = try d.exec(&c, schema, .{});

    const user = try d.one(i32, &c, "INSERT INTO anole_pg_users (email) VALUES ($1) RETURNING id", .{"ada@example.com"});
    const when = db.Time.fromSeconds(1_790_000_000);
    try testing.expectEqual(@as(u64, 1), try d.exec(&c,
        \\INSERT INTO anole_pg_posts (user_id, body, tags, meta, score, created_at, published, kind)
        \\VALUES ($1, $2, $3, $4::jsonb, $5, $6, '2026-10-21', 'link')
    , .{ user, "first", &[_][]const u8{ "a", "b" }, "{\"lang\":\"en\",\"words\":3}", 12.5, when }));
    try testing.expectEqual(@as(u64, 2), try d.exec(&c, "INSERT INTO anole_pg_posts (user_id, body) VALUES ($1, 'second'), ($1, 'third')", .{user}));

    const select = "SELECT id, user_id, body, tags, meta, score, score AS score_text, created_at, published, kind, uid FROM anole_pg_posts ORDER BY id";
    const posts = try d.all(Post, &c, select, .{});
    try testing.expectEqual(@as(usize, 3), posts.len);
    const first = posts[0];
    try testing.expectEqualStrings("first", first.body);
    try testing.expectEqual(@as(u32, @intCast(user)), first.user_id);
    try testing.expectEqual(@as(usize, 2), first.tags.len);
    try testing.expectEqualStrings("b", first.tags[1]);
    try testing.expectEqualStrings("en", first.meta.?.lang);
    try testing.expectEqual(@as(u32, 3), first.meta.?.words);
    try testing.expectEqual(@as(f64, 12.5), first.score);
    try testing.expectEqualStrings("12.50", first.score_text);
    try testing.expectEqual(when.us, first.created_at.us);
    try testing.expectEqual(try db.Time.parse("2026-10-21"), first.published.?);
    try testing.expectEqual(Kind.link, first.kind);
    try testing.expectEqual(@as(usize, 36), first.uid.len);
    try testing.expectEqual(@as(u8, 7), first.extra);
    try testing.expect(posts[1].meta == null and posts[1].published == null and posts[1].kind == .note);

    // One value; none; maybe.
    try testing.expectEqual(@as(i64, 3), try d.one(i64, &c, "SELECT count(*) FROM anole_pg_posts", .{}));
    try testing.expectError(error.NotFound, d.one(Post, &c, select ++ " LIMIT 0", .{}));
    try testing.expect((try d.optional(i64, &c, "SELECT id FROM anole_pg_posts WHERE id = $1", .{@as(i64, -1)})) == null);
    try testing.expectEqualStrings("third", (try d.optional(Post, &c, "SELECT *, score AS score_text FROM anole_pg_posts WHERE body = $1", .{"third"})).?.body);
    // SQL built at run time, seldom repeated: not prepared.
    try testing.expectEqual(@as(i64, 2), try d.with(.{ .prepare = false }).one(i64, &c, "SELECT count(*) FROM anole_pg_posts WHERE id > $1", .{posts[0].id}));

    const level = quiet();
    defer testing.log_level = level;

    // A column the struct needs and the result lacks.
    try testing.expectError(error.MissingColumn, d.one(Post, &c, "SELECT id FROM anole_pg_posts LIMIT 1", .{}));
    try testing.expect(std.mem.indexOf(u8, db.lastError(&c).?.message, "no column \"user_id\"") != null);
    // NULL into a field that cannot hold it.
    try testing.expectError(error.Database, d.one(i64, &c, "SELECT NULL::int8", .{}));
    try testing.expect(std.mem.indexOf(u8, db.lastError(&c).?.message, "make the field optional") != null);

    // Constraints: unique is a 409, the constraint's name kept; a foreign
    // key a 500, unless the map says otherwise.
    try testing.expectError(error.Conflict, d.exec(&c, "INSERT INTO anole_pg_users (email) VALUES ($1)", .{"ada@example.com"}));
    const dup = db.lastError(&c).?;
    try testing.expectEqualStrings("23505", dup.code);
    try testing.expectEqualStrings("anole_pg_users_email_key", dup.constraint.?);
    try testing.expectEqualStrings("anole_pg_users", dup.table.?);
    try testing.expectError(error.Database, d.exec(&c, "INSERT INTO anole_pg_posts (user_id, body) VALUES ($1, 'x')", .{@as(i32, 999_999)}));
    try testing.expectEqual(db.Class.foreign_key, db.lastError(&c).?.class);
    d.errors.foreign_key = .unprocessable_entity;
    try testing.expectError(error.UnprocessableEntity, d.exec(&c, "INSERT INTO anole_pg_posts (user_id, body) VALUES ($1, 'x')", .{@as(i32, 999_999)}));
    d.errors = .{};
    // A syntax error, and an error in the middle of the rows: 500s, and
    // the connection carries on.
    try testing.expectError(error.Database, d.exec(&c, "SELEKT 1", .{}));
    try testing.expectEqualStrings("42601", db.lastError(&c).?.code);
    try testing.expectError(error.Database, d.all(i32, &c, "SELECT 10 / (x - 2) FROM generate_series(1, 3) x", .{}));
    try testing.expectEqualStrings("22012", db.lastError(&c).?.code);
    try testing.expectEqual(@as(i64, 3), try d.one(i64, &c, "SELECT count(*) FROM anole_pg_posts", .{}));

    // Rows one at a time, given up early: the connection is reusable.
    {
        var rows = try d.iterate(Post, &c, select, .{});
        defer rows.deinit();
        try testing.expectEqualStrings("first", (try rows.next()).?.body);
    }
    {
        var rows = try d.iterate(i64, &c, "SELECT id FROM anole_pg_posts ORDER BY id", .{});
        defer rows.deinit();
        var n: usize = 0;
        while (try rows.next()) |_| n += 1;
        try testing.expectEqual(@as(usize, 3), n);
    }
    // The one connection served everything, the repeated statements from
    // its cache (one round trip each).
    const conn = try d.acquire(&c);
    defer conn.release();
    try testing.expect(conn.raw.statementCacheStats().hits >= 2);
    try testing.expectEqual(@as(usize, 1), d.pools.pools[0].pool.stats().in_use);
}

test "pg: live transactions: commit, roll back, retry a serialization failure" {
    _ = try testUrl();
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const d = try open(io, .{});
    defer d.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };
    _ = try d.exec(&c, schema, .{});
    const balance = "SELECT cents FROM anole_pg_accounts WHERE id = $1";

    {
        var tx = try d.begin(&c, .{ .isolation = .repeatable_read });
        defer tx.deinit();
        _ = try tx.exec(&c, "UPDATE anole_pg_accounts SET cents = cents - 10 WHERE id = 1", .{});
        try testing.expectEqual(@as(i64, 90), try tx.one(i64, &c, balance, .{@as(i32, 1)}));
        try tx.commit();
    }
    try testing.expectEqual(@as(i64, 90), try d.one(i64, &c, balance, .{@as(i32, 1)}));
    {
        // Not committed: rolled back by deinit.
        var tx = try d.begin(&c, .{});
        defer tx.deinit();
        _ = try tx.exec(&c, "UPDATE anole_pg_accounts SET cents = 0 WHERE id = 1", .{});
    }
    try testing.expectEqual(@as(i64, 90), try d.one(i64, &c, balance, .{@as(i32, 1)}));

    const level = quiet();
    defer testing.log_level = level;
    {
        // A statement failed: commit refuses, and nothing is kept.
        var tx = try d.begin(&c, .{});
        defer tx.deinit();
        _ = try tx.exec(&c, "UPDATE anole_pg_accounts SET cents = 1 WHERE id = 2", .{});
        try testing.expectError(error.Database, tx.exec(&c, "SELEKT", .{}));
        try testing.expectError(error.Database, tx.commit());
        try testing.expect(std.mem.indexOf(u8, db.lastError(&c).?.message, "rolled back") != null);
    }
    try testing.expectEqual(@as(i64, 0), try d.one(i64, &c, balance, .{@as(i32, 2)}));

    // `transaction`: the first attempt loses a serialization race (raised
    // here), the second commits.
    const Transfer = struct {
        fn run(tx: *pg.Tx, ctx: *db.Ctx, attempts: *u32, cents: i64) !void {
            attempts.* += 1;
            _ = try tx.exec(ctx, "UPDATE anole_pg_accounts SET cents = cents - $1 WHERE id = 1", .{cents});
            if (attempts.* == 1) _ = try tx.exec(ctx, "DO $$ BEGIN RAISE EXCEPTION 'lost' USING ERRCODE = '40001'; END $$", .{});
            _ = try tx.exec(ctx, "UPDATE anole_pg_accounts SET cents = cents + $1 WHERE id = 2", .{cents});
        }
    };
    var attempts: u32 = 0;
    try d.transaction(&c, .{ .isolation = .serializable, .retries = 2 }, Transfer.run, .{ &c, &attempts, @as(i64, 40) });
    try testing.expectEqual(@as(u32, 2), attempts);
    try testing.expectEqual(@as(i64, 50), try d.one(i64, &c, balance, .{@as(i32, 1)}));
    try testing.expectEqual(@as(i64, 40), try d.one(i64, &c, balance, .{@as(i32, 2)}));
    // Without retries the conflict is the answer (a 409), rolled back.
    attempts = 0;
    try testing.expectError(error.Conflict, d.transaction(&c, .{}, Transfer.run, .{ &c, &attempts, @as(i64, 40) }));
    try testing.expectEqual(@as(i64, 50), try d.one(i64, &c, balance, .{@as(i32, 1)}));
    // The pool got every connection back.
    try testing.expectEqual(@as(usize, 0), d.pools.pools[0].pool.stats().in_use);
}

/// Statements of `app` running `pg_sleep` on the server.
fn sleeping(d: *pg.Db, c: *db.Ctx, app: []const u8) !i64 {
    return d.one(i64, c, "SELECT count(*) FROM pg_stat_activity WHERE application_name = $1 AND state = 'active' AND query LIKE '%pg_sleep%' AND pid <> pg_backend_pid()", .{app});
}

/// Waits up to 3 s for `app`'s sleeping statements to stop.
fn expectStopped(io: std.Io, d: *pg.Db, c: *db.Ctx, app: []const u8) !void {
    for (0..60) |_| {
        if (try sleeping(d, c, app) == 0) return;
        try io.sleep(.fromMilliseconds(50), .awake);
    }
    return error.StatementStillRunning;
}

test "pg: live a timeout or a cancel stops the statement on the server" {
    _ = try testUrl();
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    const app_name = "anole-pg-cancel-test";
    const d = try open(io, .{ .application_name = app_name });
    defer d.deinit();
    const watcher = try open(io, .{});
    defer watcher.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };
    const level = quiet();
    defer testing.log_level = level;

    // `QueryOptions.timeout`: a 504, quickly, and the server stops.
    const started: std.Io.Clock.Timestamp = .now(io, .awake);
    try testing.expectError(error.GatewayTimeout, d.with(.{ .timeout = .fromMilliseconds(200) }).exec(&c, "SELECT pg_sleep(30)", .{}));
    try testing.expect(started.durationTo(.now(io, .awake)).raw.toMilliseconds() < 3000);
    try testing.expectEqual(db.Class.timeout, db.lastError(&c).?.class);
    try expectStopped(io, watcher, &c, app_name);

    // The task canceled (a request's deadline, an HTTP/2 reset).
    const Sleeper = struct {
        fn run(db_: *pg.Db, io_: std.Io) !void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            var ctx: db.Ctx = .{ .io = io_, .arena = arena.allocator() };
            _ = try db_.exec(&ctx, "SELECT pg_sleep(30)", .{});
        }
    };
    var task = try io.concurrent(Sleeper.run, .{ d, io });
    for (0..80) |_| {
        if (try sleeping(watcher, &c, app_name) == 1) break;
        try io.sleep(.fromMilliseconds(25), .awake);
    }
    try testing.expectError(error.Canceled, task.cancel(io));
    try expectStopped(io, watcher, &c, app_name);

    // The server's own statement_timeout: 57014, a 504 too.
    {
        var tx = try d.begin(&c, .{});
        defer tx.deinit();
        _ = try tx.exec(&c, "SET LOCAL statement_timeout = 100", .{});
        try testing.expectError(error.GatewayTimeout, tx.exec(&c, "SELECT pg_sleep(5)", .{}));
        try testing.expectEqualStrings("57014", db.lastError(&c).?.code);
    }
    // A transaction's timeout covers all of it.
    try testing.expectError(error.GatewayTimeout, d.transaction(&c, .{ .timeout = .fromMilliseconds(200) }, struct {
        fn run(tx: *pg.Tx, ctx: *db.Ctx) !void {
            _ = try tx.exec(ctx, "SELECT pg_sleep(30)", .{});
        }
    }.run, .{&c}));
    try expectStopped(io, watcher, &c, app_name);
    // And the database is there for the next call.
    try testing.expectEqual(@as(i64, 1), try d.one(i64, &c, "SELECT 1::int8", .{}));
}

test "pg: live a pool per executor" {
    _ = try testUrl();
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(4) });
    defer rt.deinit();
    const io = rt.io();
    const d = try open(io, .{ .max_connections = 4 });
    defer d.deinit();
    for (d.pools.pools) |*s| try testing.expectEqual(@as(usize, 1), s.pool._conns.len);

    const Worker = struct {
        fn run(db_: *pg.Db, io_: std.Io, pids: *[4]std.atomic.Value(i64), wrong: *std.atomic.Value(u32)) void {
            queries(db_, io_, pids, wrong) catch {
                _ = wrong.fetchAdd(1, .monotonic);
            };
        }

        fn queries(db_: *pg.Db, io_: std.Io, pids: *[4]std.atomic.Value(i64), wrong: *std.atomic.Value(u32)) !void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            var ctx: db.Ctx = .{ .io = io_, .arena = arena.allocator() };
            const here = db.executorIndex(io_).?;
            for (0..10) |_| {
                const pid = try db_.one(i64, &ctx, "SELECT pg_backend_pid()::int8", .{});
                // Each executor keeps to its one connection.
                if (pids[here].cmpxchgStrong(0, pid, .monotonic, .monotonic)) |seen| {
                    if (seen != pid) _ = wrong.fetchAdd(1, .monotonic);
                }
            }
        }
    };
    var pids: [4]std.atomic.Value(i64) = @splat(.init(0));
    var wrong: std.atomic.Value(u32) = .init(0);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (0..16) |i| try dusty.placement.concurrent(&group, io, .{ .executor = i % 4 }, Worker.run, .{ d, io, &pids, &wrong });
    try group.await(io);
    try testing.expectEqual(@as(u32, 0), wrong.load(.monotonic));
    for (&pids, 0..) |*p, i| {
        try testing.expect(p.load(.monotonic) != 0);
        for (pids[i + 1 ..]) |*q| try testing.expect(p.load(.monotonic) != q.load(.monotonic));
    }
}

test "pg: live coalesced and cached reads, a canceled caller, invalidation" {
    _ = try testUrl();
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(4) });
    defer rt.deinit();
    const io = rt.io();
    const app_name = "anole-pg-share-test";
    const d = try open(io, .{ .max_connections = 8, .application_name = app_name });
    defer d.deinit();
    const watcher = try open(io, .{});
    defer watcher.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };
    _ = try d.exec(&c, "DROP SEQUENCE IF EXISTS anole_pg_seq; CREATE SEQUENCE anole_pg_seq", .{});

    // Each run of the statement takes the next number: callers that share
    // one get the same number.
    const next = "SELECT nextval('anole_pg_seq') AS n FROM pg_sleep($1::float8)";
    const Got = struct { n: i64 };
    const Worker = struct {
        fn run(db_: *pg.Db, io_: std.Io, opts: db.QueryOptions, delay: f64, seen: *[4]std.atomic.Value(i64), wrong: *std.atomic.Value(u32)) void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            var ctx: db.Ctx = .{ .io = io_, .arena = arena.allocator() };
            const got = db_.with(opts).one(Got, &ctx, next, .{delay}) catch {
                _ = wrong.fetchAdd(1, .monotonic);
                return;
            };
            const here = db.executorIndex(io_).?;
            if (seen[here].cmpxchgStrong(0, got.n, .monotonic, .monotonic)) |prev| {
                if (prev != got.n) _ = wrong.fetchAdd(1, .monotonic);
            }
        }
    };

    // 32 callers over 4 executors: one statement per executor.
    var seen: [4]std.atomic.Value(i64) = @splat(.init(0));
    var wrong: std.atomic.Value(u32) = .init(0);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (0..32) |i| try dusty.placement.concurrent(&group, io, .{ .executor = i % 4 }, Worker.run, .{ d, io, .{ .coalesce = true }, 0.2, &seen, &wrong });
    try group.await(io);
    try testing.expectEqual(@as(u32, 0), wrong.load(.monotonic));
    try testing.expectEqual(@as(i64, 4), try d.one(i64, &c, "SELECT last_value FROM anole_pg_seq", .{}));
    try testing.expectEqual(@as(u64, 28), d.cache.stats().coalesced);

    // The first caller canceled: the others still get the row, from the
    // one statement.
    var first: std.Io.Group = .init;
    seen = @splat(.init(0));
    try dusty.placement.concurrent(&first, io, .{ .executor = 1 }, Worker.run, .{ d, io, .{ .coalesce = true }, 0.3, &seen, &wrong });
    try io.sleep(.fromMilliseconds(50), .awake);
    for (0..3) |_| try dusty.placement.concurrent(&group, io, .{ .executor = 1 }, Worker.run, .{ d, io, .{ .coalesce = true }, 0.3, &seen, &wrong });
    try io.sleep(.fromMilliseconds(20), .awake);
    first.cancel(io);
    try group.await(io);
    try testing.expectEqual(@as(u32, 1), wrong.load(.monotonic));
    try testing.expectEqual(@as(i64, 5), seen[1].load(.monotonic));
    try testing.expectEqual(@as(i64, 5), try d.one(i64, &c, "SELECT last_value FROM anole_pg_seq", .{}));

    // Every caller gone: the statement is stopped on the server.
    var gone: std.Io.Group = .init;
    for (0..3) |_| try dusty.placement.concurrent(&gone, io, .{ .executor = 2 }, Worker.run, .{ d, io, .{ .coalesce = true }, 30.0, &seen, &wrong });
    for (0..40) |_| {
        if (try sleeping(watcher, &c, app_name) == 1) break;
        try io.sleep(.fromMilliseconds(50), .awake);
    }
    gone.cancel(io);
    const level = quiet();
    defer testing.log_level = level;
    try expectStopped(io, watcher, &c, app_name);

    // Cached: the same number until the ttl, or an invalidation.
    const cached: db.QueryOptions = .{ .cache = .{ .ttl = .fromSeconds(30), .tag = "seq" } };
    const a = try d.with(cached).one(Got, &c, next, .{0.0});
    try testing.expectEqual(a.n, (try d.with(cached).one(Got, &c, next, .{0.0})).n);
    // An identical call on another executor fills its own.
    seen = @splat(.init(0));
    try dusty.placement.concurrent(&group, io, .{ .executor = 3 }, Worker.run, .{ d, io, cached, 0.0, &seen, &wrong });
    try group.await(io);
    try testing.expect(seen[3].load(.monotonic) > a.n);
    d.cache.invalidate(.{ .tag = "seq" });
    const b = try d.with(cached).one(Got, &c, next, .{0.0});
    try testing.expect(b.n > a.n);
    try testing.expectEqual(b.n, (try d.with(cached).one(Got, &c, next, .{0.0})).n);
    d.cache.invalidateQuery(next, .{0.0});
    try testing.expect((try d.with(cached).one(Got, &c, next, .{0.0})).n > b.n);
    try testing.expect(d.cache.stats().hits >= 2);
}

test "pg: live TLS as the URL asks, and a refused login" {
    _ = try testUrl();
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const d = try open(io, .{});
    defer d.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var c: db.Ctx = .{ .io = io, .arena = arena };

    const encrypted = try d.one(bool, &c, "SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()", .{});
    const s = d.settings;
    switch (s.sslmode) {
        .require, .verify_ca, .verify_full => try testing.expect(encrypted),
        .disable => try testing.expect(!encrypted),
        // Whatever the server offers.
        .allow, .prefer => {},
    }

    // The same server, as a user that does not exist.
    const mode = switch (s.sslmode) {
        .disable => "disable",
        .allow, .prefer => "prefer",
        .require => "require",
        .verify_ca => "verify-ca",
        .verify_full => "verify-full",
    };
    const bad_url = try std.fmt.allocPrint(arena, "postgres://anole_nobody:wrong@{s}:{d}/{s}?sslmode={s}{s}{s}", .{
        s.host, s.port, s.database, mode, if (s.sslrootcert != null) "&sslrootcert=" else "", s.sslrootcert orelse "",
    });
    const level = quiet();
    defer testing.log_level = level;
    const refused = try pg.Db.init(gpa, io, .{ .url = bad_url, .environ = .empty });
    defer refused.deinit();
    try testing.expectError(error.ServiceUnavailable, refused.exec(&c, "SELECT 1", .{}));
    const detail = db.lastError(&c).?;
    try testing.expectEqual(db.Class.unavailable, detail.class);
    try testing.expectStringStartsWith(detail.code, "28");
}

const AppState = struct {
    db: *pg.Db,
};

const AppRoutes = struct {
    fn count(app: *AppState, req: *http.Request, res: *http.Response) !void {
        try res.json(.{ .users = try app.db.one(i64, req, "SELECT count(*) FROM anole_pg_users", .{}) });
    }

    fn user(app: *AppState, req: *http.Request, res: *http.Response) !void {
        const id = req.params.getInt(i32, "id") orelse return error.NotFound;
        const User = struct { id: i32, email: []const u8 };
        try res.json(try app.db.one(User, req, "SELECT id, email FROM anole_pg_users WHERE id = $1", .{id}));
    }

    fn create(app: *AppState, req: *http.Request, res: *http.Response) !void {
        const email = req.query.get("email") orelse return error.BadRequest;
        const id = try app.db.one(i32, req, "INSERT INTO anole_pg_users (email) VALUES ($1) RETURNING id", .{email});
        res.status = .created;
        try res.json(.{ .id = id });
    }
};

test "pg: live app.postgres: handlers, statuses, /readyz and /metrics" {
    const url = try testUrl();
    var state: AppState = undefined;
    var app = try server_mod.Server(AppState).init(gpa, .{ .executors = .exact(2) }, &state);
    defer app.deinit();
    // Before `metrics` and `health`: it reaches them when serving starts.
    state.db = try app.postgres(.{ .url = url, .environ = .empty });
    _ = app.metrics(.{});
    _ = app.health(.{});
    app.get("/users/count", AppRoutes.count);
    app.get("/users/:id", AppRoutes.user);
    app.post("/users", AppRoutes.create);
    {
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        var c: db.Ctx = .{ .io = app.io(), .arena = arena_state.allocator() };
        _ = try state.db.exec(&c, schema, .{});
    }

    const Check = struct {
        fn fetch(io: std.Io, arena: std.mem.Allocator, method: http.Method, target: []const u8) !struct { http.Status, []const u8 } {
            var resp = try client_mod.client(io).fetch(target, .{ .method = method });
            defer resp.deinit();
            return .{ resp.status(), try arena.dupe(u8, try resp.body()) };
        }

        fn run(a: *server_mod.Server(AppState)) !void {
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

            const created = try fetch(io, arena, .post, try at(arena, port, "/users?email=grace@example.com"));
            try testing.expectEqual(http.Status.created, created[0]);
            try testing.expectEqualStrings("{\"id\":1}", created[1]);
            const level = quiet();
            defer testing.log_level = level;
            try testing.expectEqual(http.Status.conflict, (try fetch(io, arena, .post, try at(arena, port, "/users?email=grace@example.com")))[0]);
            try testing.expectEqualStrings("{\"users\":1}", (try fetch(io, arena, .get, try at(arena, port, "/users/count")))[1]);
            try testing.expectEqualStrings("{\"id\":1,\"email\":\"grace@example.com\"}", (try fetch(io, arena, .get, try at(arena, port, "/users/1")))[1]);
            try testing.expectEqual(http.Status.not_found, (try fetch(io, arena, .get, try at(arena, port, "/users/2")))[0]);
            try testing.expectEqual(http.Status.ok, (try fetch(io, arena, .get, try at(arena, port, "/readyz")))[0]);

            const scraped = (try fetch(io, arena, .get, try at(arena, port, "/metrics")))[1];
            const expect = [_][]const u8{
                "anole_db_query_duration_seconds_count{system=\"postgresql\",db=\"postgres\"} 5",
                "anole_db_errors_total{system=\"postgresql\",db=\"postgres\",error=\"Conflict\"} 1",
                "anole_db_errors_total{system=\"postgresql\",db=\"postgres\",error=\"NotFound\"} 1",
                "anole_db_pool_connections{system=\"postgresql\",db=\"postgres\",state=\"in_use\"} 0",
            };
            for (expect) |line| {
                if (std.mem.indexOf(u8, scraped, line) == null) {
                    std.debug.print("not in /metrics: {s}\n{s}\n", .{ line, scraped });
                    return error.TestUnexpectedResult;
                }
            }
        }
    };
    var checking = try app.io().concurrent(Check.run, .{&app});
    try app.listen("127.0.0.1:0");
    try checking.await(app.io());
}
