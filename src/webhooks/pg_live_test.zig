//! The webhook store on a live PostgreSQL whose collation is not "C"
//! (`-Dpostgres-test-url`, run by `zig build test-postgres` and
//! tests/postgres/run.sh; named "pg: ..." for that step's filter). Without
//! the URL they skip.
//!
//! Each test makes its own database, with an ICU en-US default collation
//! (PostgreSQL 15+, a role allowed to create databases) or libc "C", so the
//! result does not depend on the server's default. Under en-US, "msg_D"
//! sorts after "msg_c"; by bytes it sorts before.
const std = @import("std");
const build_options = @import("build_options");
const zio = @import("zio");
const anole = @import("../root.zig");
const wh = @import("root.zig");
const wait = @import("anole_test_wait");

const testing = std.testing;
const gpa = testing.allocator;

const db_name = "anole_whtest_icu";

/// Caller-supplied ids whose byte order differs from en-US order.
const ids = [_][]const u8{ "msg_a", "msg_B", "msg_c", "msg_D", "msg_ab", "msg_a-b" };
/// The same ids by bytes, newest (greatest) first.
const by_bytes_desc = [_][]const u8{ "msg_c", "msg_ab", "msg_a-b", "msg_a", "msg_D", "msg_B" };

/// The test URL with its database name replaced by `name`.
fn withDatabase(arena: std.mem.Allocator, url: []const u8, name: []const u8) ![]const u8 {
    const scheme_end = (std.mem.indexOf(u8, url, "://") orelse return error.BadUrl) + 3;
    const query = std.mem.indexOfScalarPos(u8, url, scheme_end, '?') orelse url.len;
    const path = std.mem.indexOfScalarPos(u8, url[0..query], scheme_end, '/') orelse query;
    return std.fmt.allocPrint(arena, "{s}/{s}{s}", .{ url[0..path], name, url[query..] });
}

/// The new database's default collation.
const Locale = enum {
    /// ICU en-US: text does not sort by bytes.
    icu_en_us,
    /// libc "C": text sorts by bytes, with the column's collation left at
    /// the database default.
    libc_c,
};

/// A fresh database, dropped again by `deinit`.
const Fixture = struct {
    rt: *zio.Runtime,
    admin: *anole.pg.Client,
    pgc: *anole.pg.Client,
    arena: std.heap.ArenaAllocator,
    c: anole.db.Ctx,
    /// The test database's URL.
    url: []const u8,

    fn init(f: *Fixture, locale: Locale) !void {
        if (comptime !anole.features.postgres) return error.SkipZigTest;
        const url = build_options.postgres_test_url orelse return error.SkipZigTest;
        f.rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
        errdefer f.rt.deinit();
        const io = f.rt.io();
        f.arena = .init(gpa);
        errdefer f.arena.deinit();
        f.c = .{ .io = io, .arena = f.arena.allocator() };
        f.admin = try anole.pg.Client.init(gpa, io, .{ .url = url, .environ = .empty, .max_connections = 1 });
        errdefer f.admin.deinit();
        // CREATE DATABASE runs outside a transaction: one statement per call.
        try f.admin.execScript(&f.c, "DROP DATABASE IF EXISTS " ++ db_name ++ " WITH (FORCE)");
        try f.admin.execScript(&f.c, switch (locale) {
            .icu_en_us => "CREATE DATABASE " ++ db_name ++ " TEMPLATE template0 LOCALE_PROVIDER icu ICU_LOCALE 'en-US'",
            .libc_c => "CREATE DATABASE " ++ db_name ++ " TEMPLATE template0 LOCALE_PROVIDER libc LOCALE 'C'",
        });
        f.url = try withDatabase(f.c.arena, url, db_name);
        f.pgc = try anole.pg.Client.init(gpa, io, .{ .url = f.url, .environ = .empty });
        errdefer f.pgc.deinit();
        // The precondition: this database orders text as en-US, or by bytes.
        const first = try f.pgc.one([]const u8, &f.c, "SELECT x FROM (VALUES ('msg_D'), ('msg_c')) v(x) ORDER BY x DESC LIMIT 1", .{});
        try testing.expectEqualStrings(switch (locale) {
            .icu_en_us => "msg_D",
            .libc_c => "msg_c",
        }, first);
    }

    fn deinit(f: *Fixture) void {
        f.pgc.deinit();
        f.admin.execScript(&f.c, "DROP DATABASE IF EXISTS " ++ db_name ++ " WITH (FORCE)") catch |e| std.log.err("dropping {s}: {t}", .{ db_name, e });
        f.admin.deinit();
        f.arena.deinit();
        f.rt.deinit();
    }

    fn jobs(f: *Fixture) !*anole.jobs.Client {
        return jobsOn(f, f.pgc);
    }

    fn jobsOn(f: *Fixture, pgc: *anole.pg.Client) !*anole.jobs.Client {
        return anole.jobs.Client.init(gpa, f.c.io, .{ .store = .{ .postgres = pgc }, .table_prefix = "whtest_" });
    }

    /// The tables as 0.4.0 made them (`tables_0_4_0`).
    fn makeOldTables(f: *Fixture) !void {
        for (tables_0_4_0) |stmt| _ = try f.pgc.exec(&f.c, stmt, .{});
    }

    /// The id columns' catalog rows, each with its `xmin`: an `ALTER
    /// COLUMN ... TYPE` writes a new row, so a changed text means one ran.
    fn idColumns(f: *Fixture) ![]const u8 {
        return f.pgc.one([]const u8, &f.c,
            \\SELECT string_agg(a.attrelid::regclass::text || '.' || a.attname || ' ' || a.attcollation::text || ' ' || a.xmin::text, ', ' ORDER BY a.attrelid::regclass::text, a.attname)
            \\FROM pg_attribute a
            \\WHERE a.attrelid IN (to_regclass('whtest_webhook_messages'), to_regclass('whtest_webhook_attempts'))
            \\  AND a.attname IN ('id', 'message_id', 'endpoint_id')
        , .{});
    }

    fn hooks(f: *Fixture, jc: *anole.jobs.Client) !*wh.Client {
        return wh.Client.init(gpa, f.c.io, .{ .jobs = jc, .allow_private_addresses = true, .require_https = false });
    }
};

/// Odd ones to "globex", even ones to "acme", in the order of `ids`.
fn ownerOf(id: []const u8) []const u8 {
    for (ids, 0..) |x, i| if (std.mem.eql(u8, x, id)) return if (i % 2 == 0) "acme" else "globex";
    unreachable;
}

fn publishAll(hooks: *wh.Client, c: *anole.db.Ctx) !void {
    for (ids, 0..) |id, i| {
        const p = try hooks.publish(c, .{ .owner = ownerOf(id), .type = "invoice.paid", .id = id }, .{ .n = i });
        try testing.expectEqualStrings(id, p.message_id);
    }
}

/// Pages through `hooks.messages` two at a time and checks every id comes
/// once, in byte order, newest first.
fn expectPagesByBytes(hooks: *wh.Client, c: *anole.db.Ctx, owner: ?[]const u8) !void {
    var want: std.ArrayList([]const u8) = .empty;
    for (by_bytes_desc) |id| {
        if (owner == null or std.mem.eql(u8, owner.?, ownerOf(id))) try want.append(c.arena, id);
    }
    var got: std.ArrayList([]const u8) = .empty;
    var before: ?[]const u8 = null;
    while (got.items.len <= ids.len) { // more than every id: a page repeated
        const page = try hooks.messages(c, .{ .owner = owner, .before = before, .limit = 2 });
        if (page.len == 0) break;
        for (page) |m| try got.append(c.arena, m.id);
        before = page[page.len - 1].id;
    }
    try testing.expectEqualDeep(want.items, got.items);
}

test "pg: live webhooks: messages page in byte order on a database whose collation is ICU en-US" {
    var f: Fixture = undefined;
    try f.init(.icu_en_us);
    defer f.deinit();
    const jc = try f.jobs();
    defer jc.deinit();
    const hooks = try f.hooks(jc);
    defer hooks.deinit();
    try hooks.start(null, null, null);

    try publishAll(hooks, &f.c);
    try expectPagesByBytes(hooks, &f.c, null);
    try expectPagesByBytes(hooks, &f.c, "acme");
    try expectPagesByBytes(hooks, &f.c, "globex");
}

/// The 0.4.0 DDL, as `migrate` ran it before the ids were `COLLATE "C"`.
const tables_0_4_0 = [_][]const u8{
    "CREATE TABLE whtest_webhook_endpoints (id text PRIMARY KEY, owner text NOT NULL, body text NOT NULL)",
    "CREATE INDEX whtest_webhook_endpoints_owner ON whtest_webhook_endpoints (owner)",
    "CREATE TABLE whtest_webhook_messages (id text PRIMARY KEY, owner text NOT NULL, idempotency text NOT NULL DEFAULT '', created_ms bigint NOT NULL, body text NOT NULL)",
    "CREATE UNIQUE INDEX whtest_webhook_messages_idem ON whtest_webhook_messages (owner, idempotency) WHERE idempotency <> ''",
    "CREATE INDEX whtest_webhook_messages_created ON whtest_webhook_messages (created_ms)",
    "CREATE TABLE whtest_webhook_attempts (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, message_id text NOT NULL, endpoint_id text NOT NULL, at_ms bigint NOT NULL, body text NOT NULL)",
    "CREATE INDEX whtest_webhook_attempts_endpoint ON whtest_webhook_attempts (endpoint_id, id)",
    "CREATE INDEX whtest_webhook_attempts_message ON whtest_webhook_attempts (message_id, id)",
};

test "pg: live webhooks: start moves tables made by 0.4.0 to byte-ordered ids, keeping their messages" {
    var f: Fixture = undefined;
    try f.init(.icu_en_us);
    defer f.deinit();
    try f.makeOldTables();
    const jc = try f.jobs();
    defer jc.deinit();
    {
        // Messages stored before the upgrade (no start: no migration).
        const old = try f.hooks(jc);
        defer old.deinit();
        try publishAll(old, &f.c);
    }
    const hooks = try f.hooks(jc);
    defer hooks.deinit();
    try hooks.start(null, null, null);
    try expectPagesByBytes(hooks, &f.c, null);
    try expectPagesByBytes(hooks, &f.c, "acme");

    // The documented schema: every id column the store pages or joins on is "C".
    const not_c = try f.pgc.all([]const u8, &f.c,
        \\SELECT c.relname || '.' || a.attname FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
        \\WHERE c.relname IN ('whtest_webhook_messages', 'whtest_webhook_attempts')
        \\  AND a.attname IN ('id', 'message_id', 'endpoint_id') AND a.atttypid = 'text'::regtype
        \\  AND a.attcollation <> (SELECT oid FROM pg_collation WHERE collname = 'C' AND collnamespace = 'pg_catalog'::regnamespace)
    , .{});
    try testing.expectEqual(@as(usize, 0), not_c.len);

    // A second start finds nothing to move: it ALTERs nothing and keeps
    // the messages.
    const before = try f.idColumns();
    const again = try f.hooks(jc);
    defer again.deinit();
    try again.start(null, null, null);
    try testing.expectEqualStrings(before, try f.idColumns());
    try expectPagesByBytes(again, &f.c, null);
}

test "pg: live webhooks: start leaves tables made by 0.4.0 alone on a database whose collation is libc C" {
    var f: Fixture = undefined;
    try f.init(.libc_c);
    defer f.deinit();
    try f.makeOldTables();
    const jc = try f.jobs();
    defer jc.deinit();
    {
        const old = try f.hooks(jc);
        defer old.deinit();
        try publishAll(old, &f.c);
    }
    // The columns keep the database's default collation, which already
    // orders by bytes: nothing is ALTERed (no index rebuild).
    const before = try f.idColumns();
    const hooks = try f.hooks(jc);
    defer hooks.deinit();
    try hooks.start(null, null, null);
    try testing.expectEqualStrings(before, try f.idColumns());
    try expectPagesByBytes(hooks, &f.c, null);
    try expectPagesByBytes(hooks, &f.c, "acme");
}

/// `hooks.start` on a task of its own, with its outcome.
const Starting = struct {
    hooks: *wh.Client,
    result: anyerror!void = {},

    fn run(s: *Starting) void {
        s.result = s.hooks.start(null, null, null);
    }
};

test "pg: live webhooks: two instances starting together on populated 0.4.0 tables both start" {
    var f: Fixture = undefined;
    try f.init(.icu_en_us);
    defer f.deinit();
    try f.makeOldTables();
    const jc = try f.jobs();
    defer jc.deinit();
    {
        const old = try f.hooks(jc);
        defer old.deinit();
        try publishAll(old, &f.c);
    }
    // Two instances: a connection pool and a jobs client each.
    const other_pg = try anole.pg.Client.init(gpa, f.c.io, .{ .url = f.url, .environ = .empty });
    defer other_pg.deinit();
    const other_jc = try f.jobsOn(other_pg);
    defer other_jc.deinit();
    const a = try f.hooks(jc);
    defer a.deinit();
    const b = try f.hooks(other_jc);
    defer b.deinit();
    // A third session holds the migration's advisory lock, so both starts
    // queue behind it and are released together (regression test, 9b13c2f).
    const holder_pg = try anole.pg.Client.init(gpa, f.c.io, .{ .url = f.url, .environ = .empty });
    defer holder_pg.deinit();
    var holder = try holder_pg.begin(&f.c, .{ .timeout = .max });
    defer holder.deinit();
    _ = try holder.table(&f.c, "SELECT pg_advisory_xact_lock($1::bigint)", &.{.{ .int = a.store.sql.migrate_key }});
    var sa: Starting = .{ .hooks = a };
    var sb: Starting = .{ .hooks = b };
    var fa = try f.c.io.concurrent(Starting.run, .{&sa});
    defer fa.cancel(f.c.io);
    var fb = try f.c.io.concurrent(Starting.run, .{&sb});
    defer fb.cancel(f.c.io);
    const Waiting = struct {
        admin: *anole.pg.Client,
        c: *anole.db.Ctx,
        fn both(w: @This()) !bool {
            return (try w.admin.one(i64, w.c, "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND NOT granted AND database = (SELECT oid FROM pg_database WHERE datname = '" ++ db_name ++ "')", .{})) == 2;
        }
    };
    try wait.waitUntil(f.c.io, "both starts wait for the migration's advisory lock", Waiting{ .admin = f.admin, .c = &f.c }, Waiting.both);
    try holder.rollback(&f.c);
    fa.await(f.c.io);
    fb.await(f.c.io);
    try sa.result;
    try sb.result;
    try expectPagesByBytes(a, &f.c, "acme");
    try expectPagesByBytes(b, &f.c, "globex");
}

test "pg: live webhooks: a start blocked by a lock on a table fails at the lock timeout" {
    var f: Fixture = undefined;
    try f.init(.icu_en_us);
    defer f.deinit();
    try f.makeOldTables();
    const jc = try f.jobs();
    defer jc.deinit();
    const hooks = try f.hooks(jc);
    defer hooks.deinit();
    // Another session reads the messages table in a long transaction: the
    // ALTER's ACCESS EXCLUSIVE lock waits for it.
    const reader_pg = try anole.pg.Client.init(gpa, f.c.io, .{ .url = f.url, .environ = .empty });
    defer reader_pg.deinit();
    var reader = try reader_pg.begin(&f.c, .{ .timeout = .max });
    defer reader.deinit();
    _ = try reader.exec(&f.c, "LOCK TABLE whtest_webhook_messages IN ACCESS SHARE MODE", .{});

    const logged = @import("../errors.zig").expectLog();
    defer logged.deinit();
    const logged_before = logged.count();
    var c: anole.db.Ctx = .{ .io = f.c.io, .arena = f.c.arena };
    try testing.expectError(error.Database, hooks.store.migrate(&c));
    // PostgreSQL's lock_not_available, and the startup error in the log.
    try testing.expectEqualStrings("55P03", anole.db.lastError(&c).?.code);
    try testing.expectEqual(logged_before + 1, logged.count());
    // Nothing was moved.
    try reader.rollback(&f.c);
    try testing.expectEqual(@as(i64, 1), try f.pgc.one(i64, &f.c, "SELECT count(*) FROM pg_attribute WHERE attrelid = 'whtest_webhook_messages'::regclass AND attname = 'id' AND attcollation <> 'pg_catalog.\"C\"'::regcollation", .{}));
}
