//! The webhook store on a live PostgreSQL whose collation is not "C"
//! (`-Dpostgres-test-url`, run by `zig build test-postgres` and
//! tests/postgres/run.sh; named "pg: ..." for that step's filter). Without
//! the URL they skip.
//!
//! Each test makes its own database with an ICU en-US default collation
//! (PostgreSQL 15+, a role allowed to create databases), so the result does
//! not depend on the server's default. Under en-US, "msg_D" sorts after
//! "msg_c"; by bytes it sorts before.
const std = @import("std");
const build_options = @import("build_options");
const zio = @import("zio");
const anole = @import("../root.zig");
const wh = @import("root.zig");

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

/// A fresh ICU en-US database, dropped again by `deinit`.
const Fixture = struct {
    rt: *zio.Runtime,
    admin: *anole.pg.Client,
    pgc: *anole.pg.Client,
    arena: std.heap.ArenaAllocator,
    c: anole.db.Ctx,

    fn init(f: *Fixture) !void {
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
        try f.admin.execScript(&f.c, "CREATE DATABASE " ++ db_name ++ " TEMPLATE template0 LOCALE_PROVIDER icu ICU_LOCALE 'en-US'");
        f.pgc = try anole.pg.Client.init(gpa, io, .{ .url = try withDatabase(f.c.arena, url, db_name), .environ = .empty });
        errdefer f.pgc.deinit();
        // The precondition: this database orders text as en-US, not by bytes.
        const first = try f.pgc.one([]const u8, &f.c, "SELECT x FROM (VALUES ('msg_D'), ('msg_c')) v(x) ORDER BY x DESC LIMIT 1", .{});
        try testing.expectEqualStrings("msg_D", first);
    }

    fn deinit(f: *Fixture) void {
        f.pgc.deinit();
        f.admin.execScript(&f.c, "DROP DATABASE IF EXISTS " ++ db_name ++ " WITH (FORCE)") catch |e| std.log.err("dropping {s}: {t}", .{ db_name, e });
        f.admin.deinit();
        f.arena.deinit();
        f.rt.deinit();
    }

    fn jobs(f: *Fixture) !*anole.jobs.Client {
        return anole.jobs.Client.init(gpa, f.c.io, .{ .store = .{ .postgres = f.pgc }, .table_prefix = "whtest_" });
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
    try f.init();
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

/// The 0.4.1 DDL, as `migrate` ran it before the ids were `COLLATE "C"`.
const tables_0_4_1 = [_][]const u8{
    "CREATE TABLE whtest_webhook_endpoints (id text PRIMARY KEY, owner text NOT NULL, body text NOT NULL)",
    "CREATE INDEX whtest_webhook_endpoints_owner ON whtest_webhook_endpoints (owner)",
    "CREATE TABLE whtest_webhook_messages (id text PRIMARY KEY, owner text NOT NULL, idempotency text NOT NULL DEFAULT '', created_ms bigint NOT NULL, body text NOT NULL)",
    "CREATE UNIQUE INDEX whtest_webhook_messages_idem ON whtest_webhook_messages (owner, idempotency) WHERE idempotency <> ''",
    "CREATE INDEX whtest_webhook_messages_created ON whtest_webhook_messages (created_ms)",
    "CREATE TABLE whtest_webhook_attempts (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, message_id text NOT NULL, endpoint_id text NOT NULL, at_ms bigint NOT NULL, body text NOT NULL)",
    "CREATE INDEX whtest_webhook_attempts_endpoint ON whtest_webhook_attempts (endpoint_id, id)",
    "CREATE INDEX whtest_webhook_attempts_message ON whtest_webhook_attempts (message_id, id)",
};

test "pg: live webhooks: start moves tables made by 0.4.1 to byte-ordered ids, keeping their messages" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    for (tables_0_4_1) |stmt| _ = try f.pgc.exec(&f.c, stmt, .{});
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

    // A second start finds nothing to move and keeps the messages.
    const again = try f.hooks(jc);
    defer again.deinit();
    try again.start(null, null, null);
    try expectPagesByBytes(again, &f.c, null);
}
