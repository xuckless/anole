//! anole.sqlite: files in a temporary directory and `:memory:`, on
//! std.Io.Threaded and on zio (pinned, with a blocking pool), and served by
//! `anole.Server` through `app.sqlite`.
const std = @import("std");
const wait = @import("anole_test_wait");
const zio = @import("zio");
const dusty = @import("dusty");
const anole_db = @import("../db/root.zig");
const internal = @import("../db/internal.zig");
const blocking = @import("../blocking.zig");
const observe = @import("../observe/root.zig");
const server_mod = @import("../server.zig");
const client_mod = @import("../client.zig");
const sqlite = @import("root.zig");

const testing = std.testing;
const gpa = testing.allocator;
const c = sqlite.c;

const Note = struct { id: i64, title: []const u8, done: bool };

const schema =
    \\CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL UNIQUE, done INTEGER NOT NULL DEFAULT 0);
    \\-- A comment between statements.
    \\CREATE INDEX notes_done ON notes (done);
;

/// A temporary directory and a database file in it.
const TmpFile = struct {
    tmp: std.testing.TmpDir,
    buf: [128]u8 = undefined,
    path: []const u8 = "",

    fn init() TmpFile {
        return .{ .tmp = std.testing.tmpDir(.{}) };
    }

    fn file(t: *TmpFile, name: []const u8) []const u8 {
        t.path = std.fmt.bufPrint(&t.buf, ".zig-cache/tmp/{s}/{s}", .{ &t.tmp.sub_path, name }) catch unreachable;
        return t.path;
    }

    fn deinit(t: *TmpFile) void {
        t.tmp.cleanup();
    }
};

/// A zio runtime with `executors` executors and a blocking pool on it.
const Runtime = struct {
    rt: *zio.Runtime,
    pool: blocking.Pool,

    fn init(r: *Runtime, executors: u8, threads: usize) !void {
        r.rt = try zio.Runtime.init(gpa, .{ .executors = .exact(executors) });
        errdefer r.rt.deinit();
        try r.pool.init(r.rt, .{ .threads = threads });
    }

    fn deinit(r: *Runtime) void {
        r.pool.deinit();
        r.rt.deinit();
    }

    fn io(r: *Runtime) std.Io {
        return r.rt.io();
    }
};

/// A context with an arena of its own, for a task.
const Scratch = struct {
    arena: std.heap.ArenaAllocator,
    ctx: anole_db.Ctx,

    fn init(s: *Scratch, io: std.Io) void {
        s.arena = .init(gpa);
        s.ctx = .{ .io = io, .arena = s.arena.allocator() };
    }

    fn deinit(s: *Scratch) void {
        s.arena.deinit();
    }
};

/// Keeps the warnings that failures log out of the test output.
fn quiet() std.log.Level {
    const level = testing.log_level;
    testing.log_level = .err;
    return level;
}

test "sqlite: :memory: on std.Io.Threaded, the verbs" {
    const db = try sqlite.Client.init(gpa, testing.io, .{ .path = "sqlite::memory:" });
    defer db.deinit();
    try testing.expectEqualStrings("memory", db.name);
    var s: Scratch = undefined;
    s.init(testing.io);
    defer s.deinit();
    const ctx = &s.ctx;

    // Several statements with no arguments: a schema.
    _ = try db.exec(ctx, schema, .{});
    try testing.expectEqual(@as(u64, 1), try db.exec(ctx, "INSERT INTO notes (title) VALUES (?)", .{"first"}));
    try testing.expectEqual(@as(u64, 1), try db.exec(ctx, "INSERT INTO notes (title, done) VALUES (?, ?)", .{ "second", true }));
    try testing.expectEqual(@as(u64, 2), try db.exec(ctx, "UPDATE notes SET done = ?", .{false}));
    // Not a change: 0, not the last change's count.
    try testing.expectEqual(@as(u64, 0), try db.exec(ctx, "CREATE TABLE other (x)", .{}));

    const notes = try db.all(Note, ctx, "SELECT id, title, done FROM notes ORDER BY id", .{});
    try testing.expectEqual(@as(usize, 2), notes.len);
    try testing.expectEqualStrings("first", notes[0].title);
    try testing.expectEqualStrings("second", notes[1].title);
    try testing.expect(!notes[1].done);
    try testing.expectEqual(@as(i64, 2), try db.one(i64, ctx, "SELECT count(*) FROM notes", .{}));
    try testing.expectEqualStrings("second", try db.one([]const u8, ctx, "SELECT title FROM notes WHERE id = ?", .{2}));
    try testing.expectError(error.NotFound, db.one(Note, ctx, "SELECT id, title, done FROM notes WHERE id = ?", .{99}));
    try testing.expect(try db.optional(Note, ctx, "SELECT id, title, done FROM notes WHERE id = ?", .{99}) == null);
    try testing.expectEqual(@as(i64, 1), (try db.optional(Note, ctx, "SELECT * FROM notes WHERE title = ?", .{"first"})).?.id);
    // Columns by name, in any order and case; `AS` renames.
    const Renamed = struct { done: bool, name: []const u8, ID: i64 };
    const r = try db.one(Renamed, ctx, "SELECT title AS name, id, done FROM notes WHERE id = 1", .{});
    try testing.expectEqualStrings("first", r.name);
    try testing.expectEqual(@as(i64, 1), r.ID);
    try testing.expectEqual(@as(usize, 0), (try db.all(Note, ctx, "SELECT * FROM notes WHERE id > ?", .{100})).len);

    // An expression nested deeper than SQLite's default limit (1000): an
    // error, not a deep recursion.
    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(gpa);
    try deep.appendSlice(gpa, "SELECT ");
    for (0..200_000) |_| try deep.appendSlice(gpa, "1+");
    try deep.appendSlice(gpa, "1");
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    try testing.expectError(error.Database, db.one(i64, ctx, deep.items, .{}));
}

test "sqlite: a file: URI only with Options.uri" {
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    try testing.expectError(error.InvalidDatabaseUrl, sqlite.Client.init(gpa, testing.io, .{ .path = "file::memory:" }));
    try testing.expectError(error.InvalidDatabaseUrl, sqlite.Client.init(gpa, testing.io, .{ .path = "sqlite:FILE:app.db?mode=ro" }));
    const db = try sqlite.Client.init(gpa, testing.io, .{ .path = "file:anole_uri_test?mode=memory", .uri = true });
    defer db.deinit();
}

test "sqlite: table and execValues take and give values known only at run time" {
    {
        const db = try sqlite.Client.init(gpa, testing.io, .{ .path = ":memory:" });
        defer db.deinit();
        var s: Scratch = undefined;
        s.init(testing.io);
        defer s.deinit();
        const ctx = &s.ctx;
        const q = db.with(.{});
        // Several statements with no parameters.
        const made = try q.execValues(ctx, schema ++ "CREATE TABLE kv (k TEXT, v);", &.{});
        try testing.expectEqual(@as(u64, 0), made.changes);
        const ins = try q.execValues(ctx, "INSERT INTO notes (title, done) VALUES (?, ?)", &.{ .{ .text = "first" }, .{ .int = 1 } });
        try testing.expectEqual(@as(u64, 1), ins.changes);
        try testing.expectEqual(@as(i64, 1), ins.last_insert_rowid);
        _ = try q.execValues(ctx, "INSERT INTO kv VALUES (?, ?), (?, ?), (?, ?), (?, ?)", &.{
            .{ .text = "f" }, .{ .float = 1.5 },
            .{ .text = "b" }, .{ .blob = "\x00\x01" },
            .{ .text = "n" }, .null,
            .{ .text = "i" }, .{ .int = -7 },
        });
        const t = try q.table(ctx, "SELECT k AS key, v FROM kv ORDER BY rowid", &.{});
        try testing.expectEqual(@as(usize, 2), t.columns.len);
        try testing.expectEqualStrings("key", t.columns[0]);
        try testing.expectEqual(@as(usize, 4), t.rows.len);
        try testing.expectEqual(@as(f64, 1.5), t.rows[0][1].float);
        try testing.expectEqualStrings("\x00\x01", t.rows[1][1].blob);
        try testing.expect(t.rows[2][1] == .null);
        try testing.expectEqual(@as(i64, -7), t.rows[3][1].int);
        // No row: the columns still.
        const none = try q.table(ctx, "SELECT id, title FROM notes WHERE id = ?", &.{.{ .int = 99 }});
        try testing.expectEqual(@as(usize, 2), none.columns.len);
        try testing.expectEqual(@as(usize, 0), none.rows.len);
        // A wrong parameter count and a constraint are errors as usual.
        const level = quiet();
        defer testing.log_level = level;
        try testing.expectError(error.Database, q.table(ctx, "SELECT ?", &.{}));
        try testing.expectError(error.Conflict, q.execValues(ctx, "INSERT INTO notes (title) VALUES (?)", &.{.{ .text = "first" }}));
        try testing.expect(anole_db.lastError(ctx) != null);
    }
}

test "sqlite: table results are cached on a pinned runtime with readers until invalidated" {
    var r: Runtime = undefined;
    try r.init(2, 4);
    defer r.deinit();
    const io = r.io();
    var tmp: TmpFile = .init();
    defer tmp.deinit();
    const db = try sqlite.Client.init(gpa, io, .{ .path = tmp.file("table.db") });
    defer db.deinit();
    const Check = struct {
        fn run(d: *sqlite.Client, io_: std.Io) !void {
            var sc: Scratch = undefined;
            sc.init(io_);
            defer sc.deinit();
            const ctx = &sc.ctx;
            _ = try d.with(.{}).execValues(ctx, schema, &.{});
            _ = try d.with(.{}).execValues(ctx, "INSERT INTO notes (title) VALUES (?)", &.{.{ .text = "a" }});
            const cached: anole_db.QueryOptions = .{ .cache = .{ .ttl = .fromSeconds(60), .tag = "notes" } };
            const sql = "SELECT title FROM notes WHERE id > ?";
            const one = try d.with(cached).table(ctx, sql, &.{.{ .int = 0 }});
            try testing.expectEqualStrings("a", one.rows[0][0].text);
            _ = try d.with(.{}).execValues(ctx, "INSERT INTO notes (title) VALUES ('b')", &.{});
            // From the cache: the write does not show until invalidated.
            try testing.expectEqual(@as(usize, 1), (try d.with(cached).table(ctx, sql, &.{.{ .int = 0 }})).rows.len);
            try testing.expectEqual(anole_db.Source.cache, anole_db.lastSource(ctx).?);
            // Other parameters are another entry.
            try testing.expectEqual(@as(usize, 1), (try d.with(cached).table(ctx, sql, &.{.{ .int = 1 }})).rows.len);
            d.cache.invalidate(.{ .tag = "notes" });
            try testing.expectEqual(@as(usize, 2), (try d.with(cached).table(ctx, sql, &.{.{ .int = 0 }})).rows.len);
        }
    };
    var f = try io.concurrent(Check.run, .{ db, io });
    try f.await(io);
}

test "sqlite: values both ways: times, enums, optionals, JSON, blobs, defaults" {
    const db = try sqlite.Client.init(gpa, testing.io, .{ .path = ":memory:" });
    defer db.deinit();
    var s: Scratch = undefined;
    s.init(testing.io);
    defer s.deinit();
    const ctx = &s.ctx;

    _ = try db.exec(ctx, "CREATE TABLE t (id INTEGER PRIMARY KEY, at TEXT, kind TEXT, level INTEGER, note TEXT, meta TEXT, data BLOB, big INTEGER)", .{});
    const Kind = enum { draft, published };
    const Level = enum(u8) { low = 1, high = 9 };
    const Meta = struct { tags: []const []const u8, score: f64 = 0 };
    const at: anole_db.Time = try .parse("2026-10-21T09:30:00.25Z");
    _ = try db.exec(ctx, "INSERT INTO t (at, kind, level, note, meta, data, big) VALUES (?, ?, ?, ?, ?, ?, ?)", .{
        at,                                           Kind.published,                        @backingInt(Level.high), @as(?[]const u8, null),
        Meta{ .tags = &.{ "x", "y" }, .score = 1.5 }, sqlite.Blob{ .data = "\x00\x01\xff" }, @as(u64, 1) << 40,
    });
    // Stored as SQLite writes times: sortable, and its date functions read it.
    try testing.expectEqualStrings("2026-10-21 09:30:00.25", try db.one([]const u8, ctx, "SELECT at FROM t", .{}));
    try testing.expectEqualStrings("2026-10-21", try db.one([]const u8, ctx, "SELECT date(at) FROM t", .{}));

    const Row = struct {
        id: i64,
        at: anole_db.Time,
        kind: Kind,
        level: Level,
        note: ?[]const u8,
        meta: Meta,
        data: sqlite.Blob,
        big: u64,
        // Not in the result: the default, or null.
        extra: u8 = 7,
        missing: ?i64,
    };
    const row = try db.one(Row, ctx, "SELECT id, at, kind, level, note, meta, data, big FROM t", .{});
    try testing.expectEqual(at, row.at);
    try testing.expectEqual(Kind.published, row.kind);
    try testing.expectEqual(Level.high, row.level);
    try testing.expect(row.note == null);
    try testing.expectEqualStrings("y", row.meta.tags[1]);
    try testing.expectEqual(@as(f64, 1.5), row.meta.score);
    try testing.expectEqualSlices(u8, "\x00\x01\xff", row.data.data);
    try testing.expectEqual(@as(u64, 1) << 40, row.big);
    try testing.expectEqual(@as(u8, 7), row.extra);
    try testing.expect(row.missing == null);

    // Times from unixepoch() and julianday() too.
    const Times = struct { a: anole_db.Time, b: anole_db.Time, c: anole_db.Time };
    const times = try db.one(Times, ctx, "SELECT unixepoch('2026-10-21 09:30:00') AS a, julianday('2026-10-21 09:30:00') AS b, CURRENT_TIMESTAMP AS c", .{});
    try testing.expectEqual(anole_db.Time.fromSeconds(at.toSeconds()), times.a);
    try testing.expectEqual(anole_db.Time.fromSeconds(at.toSeconds()), times.b);
    try testing.expect(times.c.us > (try anole_db.Time.parse("2020-01-01")).us);
    // Comparisons in SQL see the bound time as text of the same shape.
    try testing.expectEqual(@as(i64, 1), try db.one(i64, ctx, "SELECT count(*) FROM t WHERE at > ?", .{try anole_db.Time.parse("2026-10-21 09:00:00")}));

    // Parameters by name; a blob in JSON as base64.
    try testing.expectEqual(@as(i64, 7), try db.one(i64, ctx, "SELECT :a + @b", .{ .b = 4, .a = 3 }));
    try testing.expectEqualStrings("\"AAH/\"", try std.fmt.allocPrint(ctx.arena, "{f}", .{std.json.fmt(row.data, .{})}));

    const level = quiet();
    defer testing.log_level = level;
    try testing.expectError(error.Database, db.one(i64, ctx, "SELECT :a + :c", .{ .a = 1, .b = 2 }));
    // A column the struct needs and the result lacks.
    const Strict = struct { id: i64, absent: i64 };
    try testing.expectError(error.MissingColumn, db.one(Strict, ctx, "SELECT id FROM t", .{}));
    // NULL into a field that is not optional; a value that does not fit.
    try testing.expectError(error.Database, db.one(struct { note: []const u8 }, ctx, "SELECT note FROM t", .{}));
    try testing.expectStringStartsWith(anole_db.lastError(ctx).?.message, "column \"note\" is NULL");
    try testing.expectError(error.Database, db.one(u8, ctx, "SELECT big FROM t", .{}));
    try testing.expectError(error.Database, db.one(Kind, ctx, "SELECT 'other'", .{}));
    // The wrong number of parameters; two statements where one is taken.
    try testing.expectError(error.Database, db.one(i64, ctx, "SELECT ?", .{ 1, 2 }));
    try testing.expectStringStartsWith(anole_db.lastError(ctx).?.message, "the statement takes 1 parameters, 2 given");
    try testing.expectError(error.Database, db.exec(ctx, "SELECT 1; SELECT 2", .{1}));
    try testing.expectError(error.Database, db.one(i64, ctx, "SELECT 1; SELECT 2", .{}));
    // A stored number past what anole.db.Time holds: an error for that read,
    // not a crash.
    for ([_][]const u8{ "SELECT 9223372036854775807", "SELECT -9223372036854775807", "SELECT 1e300", "SELECT -1e300", "SELECT 9e18" }) |sql| {
        try testing.expectError(error.Database, db.one(anole_db.Time, ctx, sql, .{}));
        try testing.expect(std.mem.indexOf(u8, anole_db.lastError(ctx).?.message, "is beyond what anole.db.Time holds") != null);
    }
    // SQL that SQLite refuses: the detail stays for lastError.
    try testing.expectError(error.Database, db.exec(ctx, "SELEC 1", .{}));
    try testing.expectEqualStrings("1", anole_db.lastError(ctx).?.code);
    try testing.expectStringStartsWith(anole_db.lastError(ctx).?.message, "near \"SELEC\"");
}

test "sqlite: constraint errors become statuses; ErrorMap moves them" {
    var tmp: TmpFile = .init();
    defer tmp.deinit();
    const db = try sqlite.Client.init(gpa, testing.io, .{ .path = tmp.file("app.db"), .readers = 1 });
    defer db.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    // On a request: what lastError keeps lives in its locals.
    var req: dusty.Request = .{ .arena = arena_state.allocator(), .io = testing.io, ._parser = undefined, ._transport = undefined };

    _ = try db.exec(&req,
        \\CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT NOT NULL UNIQUE, age INTEGER CHECK (age >= 0));
        \\CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users (id));
    , .{});
    _ = try db.exec(&req, "INSERT INTO users (id, email) VALUES (1, 'a@x')", .{});

    const level = quiet();
    defer testing.log_level = level;
    const Case = struct { sql: []const u8, err: anyerror, class: anole_db.Class, code: []const u8, status: ?dusty.Status };
    for ([_]Case{
        .{ .sql = "INSERT INTO users (email) VALUES ('a@x')", .err = error.Conflict, .class = .unique, .code = "2067", .status = .conflict },
        .{ .sql = "INSERT INTO users (id, email) VALUES (1, 'b@x')", .err = error.Conflict, .class = .unique, .code = "1555", .status = .conflict },
        .{ .sql = "INSERT INTO posts (user_id) VALUES (42)", .err = error.Database, .class = .foreign_key, .code = "787", .status = null },
        .{ .sql = "INSERT INTO users (email) VALUES (NULL)", .err = error.Database, .class = .not_null, .code = "1299", .status = null },
        .{ .sql = "INSERT INTO users (email, age) VALUES ('c@x', -1)", .err = error.Database, .class = .check, .code = "275", .status = null },
    }) |case| {
        const got = db.exec(&req, case.sql, .{});
        try testing.expectError(case.err, got);
        const detail = anole_db.lastError(&req).?;
        try testing.expectEqual(anole_db.System.sqlite, detail.system);
        try testing.expectEqual(case.class, detail.class);
        try testing.expectEqualStrings(case.code, detail.code);
        try testing.expectEqual(case.status, dusty.errorStatus(case.err));
    }
    const unique = blk: {
        _ = db.exec(&req, "INSERT INTO users (email) VALUES ('a@x')", .{}) catch {};
        break :blk anole_db.lastError(&req).?;
    };
    try testing.expectEqualStrings("users.email", unique.constraint.?);
    try testing.expectEqualStrings("users", unique.table.?);

    // An app that validates through its constraints.
    const strict = try sqlite.Client.init(gpa, testing.io, .{ .path = tmp.file("app.db"), .readers = 1, .errors = .{ .foreign_key = .unprocessable_entity, .check = .bad_request } });
    defer strict.deinit();
    try testing.expectError(error.UnprocessableEntity, strict.exec(&req, "INSERT INTO posts (user_id) VALUES (42)", .{}));
    try testing.expectError(error.BadRequest, strict.exec(&req, "INSERT INTO users (email, age) VALUES ('d@x', -1)", .{}));
    try testing.expectError(error.Conflict, strict.exec(&req, "INSERT INTO users (email) VALUES ('a@x')", .{}));
}

test "sqlite: a file on 4 pinned executors: reads beside an open write transaction, many writers and no BUSY" {
    var r: Runtime = undefined;
    try r.init(4, 4);
    defer r.deinit();
    const io = r.io();
    var tmp: TmpFile = .init();
    defer tmp.deinit();
    const db = try sqlite.Client.init(gpa, io, .{ .path = tmp.file("app.db") });
    defer db.deinit();
    // The pool gauges say where the connections are at the end.
    var registry = observe.metrics.Registry.init(gpa, io);
    defer registry.deinit();
    var health = observe.Health.init(.{});
    try db.start(&registry, null, &health);
    var s: Scratch = undefined;
    s.init(io);
    defer s.deinit();
    const ctx = &s.ctx;
    _ = try db.exec(ctx, schema, .{});
    try testing.expectEqualStrings("wal", try db.one([]const u8, ctx, "PRAGMA journal_mode", .{}));
    _ = try db.exec(ctx, "INSERT INTO notes (title) VALUES ('seed')", .{});

    // A write transaction holds the writer; readers keep their snapshot and
    // never wait for it.
    {
        var tx = try db.begin(ctx, .{});
        defer tx.deinit();
        _ = try tx.exec(ctx, "INSERT INTO notes (title) VALUES ('in tx')", .{});
        try testing.expectEqual(@as(i64, 2), try tx.one(i64, ctx, "SELECT count(*) FROM notes", .{}));
        // A read that waited for the writer would wait for this task's own
        // commit below: it would never return, not return late.
        try testing.expectEqual(@as(i64, 1), try db.one(i64, ctx, "SELECT count(*) FROM notes", .{}));
        try tx.commit(ctx);
    }
    try testing.expectEqual(@as(i64, 2), try db.one(i64, ctx, "SELECT count(*) FROM notes", .{}));

    // 16 tasks over the 4 executors, each writing 25 rows and reading
    // between writes: every write lands, no SQLITE_BUSY.
    const Worker = struct {
        fn run(d: *sqlite.Client, io_: std.Io, n: usize, failures: *std.atomic.Value(u32)) void {
            var sc: Scratch = undefined;
            sc.init(io_);
            defer sc.deinit();
            for (0..25) |i| {
                var buf: [32]u8 = undefined;
                const title = std.fmt.bufPrint(&buf, "w{d}-{d}", .{ n, i }) catch unreachable;
                _ = d.exec(&sc.ctx, "INSERT INTO notes (title) VALUES (?)", .{title}) catch {
                    _ = failures.fetchAdd(1, .monotonic);
                    continue;
                };
                _ = d.one(i64, &sc.ctx, "SELECT count(*) FROM notes WHERE title LIKE 'w%'", .{}) catch {
                    _ = failures.fetchAdd(1, .monotonic);
                };
                _ = d.all(Note, &sc.ctx, "SELECT id, title, done FROM notes ORDER BY id DESC LIMIT 5", .{}) catch {
                    _ = failures.fetchAdd(1, .monotonic);
                };
            }
        }
    };
    var failures: std.atomic.Value(u32) = .init(0);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (0..16) |n| try dusty.placement.concurrent(&group, io, .{ .executor = n % 4 }, Worker.run, .{ db, io, n, &failures });
    try group.await(io);
    try testing.expectEqual(@as(u32, 0), failures.load(.monotonic));
    try testing.expectEqual(@as(i64, 2 + 16 * 25), try db.one(i64, ctx, "SELECT count(*) FROM notes", .{}));
    // Every connection is back: the writer and a reader per executor idle.
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try registry.render(&out.writer);
    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "anole_db_pool_connections{system=\"sqlite\",db=\"app.db\",state=\"idle\"} 5") != null);
    try testing.expect(std.mem.indexOf(u8, text, "anole_db_pool_connections{system=\"sqlite\",db=\"app.db\",state=\"in_use\"} 0") != null);
}

test "sqlite: coalesced and cached reads on 4 executors; invalidation after a write" {
    var r: Runtime = undefined;
    try r.init(4, 8);
    defer r.deinit();
    const io = r.io();
    var tmp: TmpFile = .init();
    defer tmp.deinit();
    const db = try sqlite.Client.init(gpa, io, .{ .path = tmp.file("shared.db") });
    defer db.deinit();
    var s: Scratch = undefined;
    s.init(io);
    defer s.deinit();
    const ctx = &s.ctx;
    _ = try db.exec(ctx, schema, .{});

    // Every reader held by a read-only transaction: the statement each
    // executor starts waits for one, so all the callers on that executor
    // meet it in flight, however slowly a busy machine runs them.
    const count_to = "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < ?) SELECT count(*) FROM n";
    const Worker = struct {
        fn run(d: *sqlite.Client, io_: std.Io, failures: *std.atomic.Value(u32)) void {
            var sc: Scratch = undefined;
            sc.init(io_);
            defer sc.deinit();
            const n = d.with(.{ .coalesce = true }).one(i64, &sc.ctx, count_to, .{1000}) catch 0;
            if (n != 1000) _ = failures.fetchAdd(1, .monotonic);
        }
    };
    var holds: [4]sqlite.Tx = undefined;
    try testing.expectEqual(holds.len, db.readers.conns.len);
    var held: usize = 0;
    defer for (holds[0..held]) |*h| h.deinit();
    while (held < holds.len) : (held += 1) holds[held] = try db.begin(ctx, .{ .read_only = true });
    var failures: std.atomic.Value(u32) = .init(0);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (0..32) |n| try dusty.placement.concurrent(&group, io, .{ .executor = n % 4 }, Worker.run, .{ db, io, &failures });
    // 7 of the 8 callers on each executor join its statement.
    try wait.waitUntil(io, "7 of the 8 callers on each executor joined its statement", db, struct {
        fn f(d: *sqlite.Client) bool {
            return d.cache.stats().coalesced >= 28;
        }
    }.f);
    for (holds[0..held]) |*h| h.deinit();
    held = 0;
    try group.await(io);
    try testing.expectEqual(@as(u32, 0), failures.load(.monotonic));
    try testing.expectEqual(@as(u64, 28), db.cache.stats().coalesced);

    // Cached until invalidated: a write does not show until then.
    const cached: anole_db.QueryOptions = .{ .cache = .{ .ttl = .fromSeconds(60), .tag = "notes" } };
    const count = "SELECT count(*) FROM notes";
    try testing.expectEqual(@as(i64, 0), try db.with(cached).one(i64, ctx, count, .{}));
    _ = try db.exec(ctx, "INSERT INTO notes (title) VALUES ('new')", .{});
    try testing.expectEqual(@as(i64, 0), try db.with(cached).one(i64, ctx, count, .{}));
    try testing.expectEqual(@as(i64, 1), try db.one(i64, ctx, count, .{}));
    db.cache.invalidate(.{ .tag = "notes" });
    try testing.expectEqual(@as(i64, 1), try db.with(cached).one(i64, ctx, count, .{}));
    // Rows with strings come back whole, in the caller's arena.
    const notes = try db.with(cached).all(Note, ctx, "SELECT id, title, done FROM notes", .{});
    try testing.expectEqualStrings("new", notes[0].title);
    try testing.expectEqualStrings("new", (try db.with(cached).all(Note, ctx, "SELECT id, title, done FROM notes", .{}))[0].title);
    try testing.expectEqual(@as(u64, 2), db.cache.stats().hits);
}

test "sqlite: cache-aside with keep_empty = false, and lastSource for hit or miss" {
    var r: Runtime = undefined;
    try r.init(1, 2);
    defer r.deinit();
    const io = r.io();
    var tmp: TmpFile = .init();
    defer tmp.deinit();
    const db = try sqlite.Client.init(gpa, io, .{ .path = tmp.file("aside.db") });
    defer db.deinit();
    var s: Scratch = undefined;
    s.init(io);
    defer s.deinit();
    const ctx = &s.ctx;
    _ = try db.exec(ctx, schema, .{});
    const by_title = "SELECT id, title, done FROM notes WHERE title = ?";
    const all_by_title = "SELECT id, title, done FROM notes WHERE title LIKE ?";
    try testing.expectEqual(@as(?anole_db.Source, null), anole_db.lastSource(ctx));

    // Not kept while empty: every call asks the database again...
    const aside = db.with(.{ .cache = .{ .ttl = .fromSeconds(60), .keep_empty = false } });
    for (0..2) |_| {
        try testing.expect(try aside.optional(Note, ctx, by_title, .{"k"}) == null);
        try testing.expectEqual(@as(?anole_db.Source, .database), anole_db.lastSource(ctx));
        try testing.expectEqual(@as(usize, 0), (try aside.all(Note, ctx, all_by_title, .{"k%"})).len);
        try testing.expectEqual(@as(?anole_db.Source, .database), anole_db.lastSource(ctx));
    }
    try testing.expectEqual(@as(u64, 0), db.cache.stats().hits);
    // ...so the row a miss filled in is seen at once, then kept.
    _ = try db.exec(ctx, "INSERT INTO notes (title) VALUES ('k')", .{});
    try testing.expectEqualStrings("k", (try aside.optional(Note, ctx, by_title, .{"k"})).?.title);
    try testing.expectEqual(@as(?anole_db.Source, .database), anole_db.lastSource(ctx));
    try testing.expectEqualStrings("k", (try aside.optional(Note, ctx, by_title, .{"k"})).?.title);
    try testing.expectEqual(@as(?anole_db.Source, .cache), anole_db.lastSource(ctx));
    try testing.expectEqual(@as(usize, 1), (try aside.all(Note, ctx, all_by_title, .{"k%"})).len);
    try testing.expectEqual(@as(usize, 1), (try aside.all(Note, ctx, all_by_title, .{"k%"})).len);
    try testing.expectEqual(@as(?anole_db.Source, .cache), anole_db.lastSource(ctx));
    // A plain call leaves the last source alone.
    _ = try db.optional(Note, ctx, by_title, .{"k"});
    try testing.expectEqual(@as(?anole_db.Source, .cache), anole_db.lastSource(ctx));

    // The default keeps "none" like any other result.
    const keeping = db.with(.{ .cache = .{ .ttl = .fromSeconds(60) } });
    try testing.expect(try keeping.optional(Note, ctx, by_title, .{"absent"}) == null);
    try testing.expectEqual(@as(?anole_db.Source, .database), anole_db.lastSource(ctx));
    _ = try db.exec(ctx, "INSERT INTO notes (title) VALUES ('absent')", .{});
    try testing.expect(try keeping.optional(Note, ctx, by_title, .{"absent"}) == null);
    try testing.expectEqual(@as(?anole_db.Source, .cache), anole_db.lastSource(ctx));
}

test "sqlite: :memory: is one database seen from every executor" {
    var r: Runtime = undefined;
    try r.init(4, 2);
    defer r.deinit();
    const io = r.io();
    const db = try sqlite.Client.init(gpa, io, .{ .path = ":memory:" });
    defer db.deinit();
    var s: Scratch = undefined;
    s.init(io);
    defer s.deinit();
    _ = try db.exec(&s.ctx, "CREATE TABLE seen (executor INTEGER)", .{});

    const Worker = struct {
        fn run(d: *sqlite.Client, io_: std.Io, out: *std.atomic.Value(u32)) void {
            var sc: Scratch = undefined;
            sc.init(io_);
            defer sc.deinit();
            const here = internal.executorIndex(io_) orelse 99;
            _ = d.exec(&sc.ctx, "INSERT INTO seen VALUES (?)", .{here}) catch return;
            // Rows other executors wrote are visible here.
            const n = d.one(i64, &sc.ctx, "SELECT count(*) FROM seen", .{}) catch return;
            _ = out.fetchMax(@intCast(n), .monotonic);
        }
    };
    var most: std.atomic.Value(u32) = .init(0);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (0..4) |n| try dusty.placement.concurrent(&group, io, .{ .executor = n }, Worker.run, .{ db, io, &most });
    try group.await(io);
    try testing.expectEqual(@as(i64, 4), try db.one(i64, &s.ctx, "SELECT count(DISTINCT executor) FROM seen", .{}));
    try testing.expectEqual(@as(u32, 4), most.load(.monotonic));
}

/// A query that runs until interrupted.
const forever = "WITH RECURSIVE r(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM r) SELECT count(*) FROM r";

test "sqlite: a timeout or a cancel interrupts a query that never ends, on a reader and on the writer" {
    var r: Runtime = undefined;
    try r.init(2, 2);
    defer r.deinit();
    const io = r.io();
    var tmp: TmpFile = .init();
    defer tmp.deinit();
    // One reader, so the next read reuses the interrupted connection.
    const file_db = try sqlite.Client.init(gpa, io, .{ .path = tmp.file("app.db"), .readers = 1 });
    defer file_db.deinit();
    const memory_db = try sqlite.Client.init(gpa, io, .{ .path = ":memory:" });
    defer memory_db.deinit();
    var s: Scratch = undefined;
    s.init(io);
    defer s.deinit();
    const ctx = &s.ctx;
    const level = quiet();
    defer testing.log_level = level;

    const Case = struct { db: *sqlite.Client, write: bool };
    for ([_]Case{ .{ .db = file_db, .write = false }, .{ .db = file_db, .write = true }, .{ .db = memory_db, .write = false } }) |case| {
        const q = case.db.with(.{ .timeout = .fromMilliseconds(50), .write = case.write });
        // The statement never ends: GatewayTimeout is the timeout's doing.
        try testing.expectError(error.GatewayTimeout, q.one(i64, ctx, forever, .{}));
        try testing.expectEqual(anole_db.Class.timeout, anole_db.lastError(ctx).?.class);
        // The connection serves the next query.
        try testing.expectEqual(@as(i64, 3), try case.db.with(.{ .write = case.write }).one(i64, ctx, "SELECT 1 + 2", .{}));

        // A canceled task (a request's deadline, an RST_STREAM).
        const Long = struct {
            fn run(q_: sqlite.Query, io_: std.Io) sqlite.Error!i64 {
                var sc: Scratch = undefined;
                sc.init(io_);
                defer sc.deinit();
                return q_.one(i64, &sc.ctx, forever, .{});
            }
        };
        var long = try io.concurrent(Long.run, .{ case.db.with(.{ .write = case.write }), io });
        defer _ = long.cancel(io) catch {};
        // Time for the statement to start: a slow machine can only cancel
        // it before it runs, which passes too (and misses the interrupt).
        try io.sleep(.fromMilliseconds(30), .awake);
        // The statement never ends: the cancel returning at all is the
        // interrupt's doing.
        try testing.expectError(error.Canceled, long.cancel(io));
        try testing.expectEqual(@as(i64, 4), try case.db.with(.{ .write = case.write }).one(i64, ctx, "SELECT 2 + 2", .{}));
    }
    // A write canceled while waiting for the writer never runs.
    {
        var tx = try file_db.begin(ctx, .{});
        _ = try tx.exec(ctx, "CREATE TABLE IF NOT EXISTS t (x)", .{});
        const Write = struct {
            fn run(d: *sqlite.Client, io_: std.Io) sqlite.Error!u64 {
                var sc: Scratch = undefined;
                sc.init(io_);
                defer sc.deinit();
                return d.exec(&sc.ctx, "INSERT INTO t VALUES (1)", .{});
            }
        };
        var waiting = try io.concurrent(Write.run, .{ file_db, io });
        defer _ = waiting.cancel(io) catch {};
        // Time to queue for the writer (canceled sooner, it never runs
        // either).
        try io.sleep(.fromMilliseconds(20), .awake);
        try testing.expectError(error.Canceled, waiting.cancel(io));
        try tx.commit(ctx);
        try testing.expectEqual(@as(i64, 0), try file_db.one(i64, ctx, "SELECT count(*) FROM t", .{}));
    }
}

test "sqlite: with one executor, the server keeps running while SQLite works" {
    var r: Runtime = undefined;
    try r.init(1, 2);
    defer r.deinit();
    const io = r.io();
    var tmp: TmpFile = .init();
    defer tmp.deinit();
    const db = try sqlite.Client.init(gpa, io, .{ .path = tmp.file("app.db") });
    defer db.deinit();
    var s: Scratch = undefined;
    s.init(io);
    defer s.deinit();

    const Ticker = struct {
        fn tick(io_: std.Io, ticks: *std.atomic.Value(u32)) std.Io.Cancelable!void {
            while (true) {
                try io_.sleep(.fromMilliseconds(5), .awake);
                _ = ticks.fetchAdd(1, .monotonic);
            }
        }
    };
    var ticks: std.atomic.Value(u32) = .init(0);
    var ticker = try io.concurrent(Ticker.tick, .{ io, &ticks });
    defer ticker.cancel(io) catch {};
    // A read (blocking pool) and a write (the writer thread) that never end
    // on their own: the ticker, on the only executor, ticks on beside each
    // (were the executor held by SQLite, it could not), then the statement
    // is canceled (interrupted). No claim on how long a statement takes.
    const Forever = struct {
        fn run(q: sqlite.Query, io_: std.Io) sqlite.Error!i64 {
            var sc: Scratch = undefined;
            sc.init(io_);
            defer sc.deinit();
            return q.one(i64, &sc.ctx, forever, .{});
        }
    };
    for ([_]bool{ false, true }) |write| {
        var running = try io.concurrent(Forever.run, .{ db.with(.{ .write = write }), io });
        const before = ticks.load(.monotonic);
        wait.waitAtLeast(io, "the ticker ticks beside the statement", &ticks, before + 10) catch |err| {
            _ = running.cancel(io) catch {};
            return err;
        };
        try testing.expectError(error.Canceled, running.cancel(io));
    }
    // The connection serves the next statement.
    try testing.expectEqual(@as(i64, 3), try db.one(i64, &s.ctx, "SELECT 1 + 2", .{}));
}

/// Moves `amount` from account 1 to account 2 (the transactions tests).
const MoveTx = struct {
    fn run(tx: *sqlite.Tx, rq: *dusty.Request, amount: i64, attempts: *u32) !void {
        attempts.* += 1;
        _ = try tx.exec(rq, "UPDATE accounts SET balance = balance - ? WHERE id = 1", .{amount});
        _ = try tx.exec(rq, "UPDATE accounts SET balance = balance + ? WHERE id = 2", .{amount});
    }
};

test "sqlite: transactions: rollback and a deinit without commit both undo the writes" {
    var r: Runtime = undefined;
    try r.init(2, 2);
    defer r.deinit();
    const io = r.io();
    var tmp: TmpFile = .init();
    defer tmp.deinit();
    const path = tmp.file("app.db");
    const db = try sqlite.Client.init(gpa, io, .{ .path = path, .readers = 2, .busy_timeout = .fromMilliseconds(20) });
    defer db.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var req: dusty.Request = .{ .arena = arena_state.allocator(), .io = io, ._parser = undefined, ._transport = undefined };
    _ = try db.exec(&req, "CREATE TABLE accounts (id INTEGER PRIMARY KEY, balance INTEGER NOT NULL CHECK (balance >= 0))", .{});
    _ = try db.exec(&req, "INSERT INTO accounts VALUES (1, 100), (2, 0)", .{});

    {
        var tx = try db.begin(&req, .{});
        defer tx.deinit();
        _ = try tx.exec(&req, "UPDATE accounts SET balance = 0 WHERE id = 1", .{});
        try tx.rollback(&req);
    }
    {
        // Dropped without commit: rolled back.
        var tx = try db.begin(&req, .{});
        defer tx.deinit();
        _ = try tx.exec(&req, "UPDATE accounts SET balance = 0 WHERE id = 1", .{});
    }
    try testing.expectEqual(@as(i64, 100), try db.one(i64, &req, "SELECT balance FROM accounts WHERE id = 1", .{}));
}

test "sqlite: a read-only transaction keeps its snapshot while the writer commits, and refuses writes" {
    var r: Runtime = undefined;
    try r.init(2, 2);
    defer r.deinit();
    const io = r.io();
    var tmp: TmpFile = .init();
    defer tmp.deinit();
    const path = tmp.file("app.db");
    const db = try sqlite.Client.init(gpa, io, .{ .path = path, .readers = 2, .busy_timeout = .fromMilliseconds(20) });
    defer db.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var req: dusty.Request = .{ .arena = arena_state.allocator(), .io = io, ._parser = undefined, ._transport = undefined };
    _ = try db.exec(&req, "CREATE TABLE accounts (id INTEGER PRIMARY KEY, balance INTEGER NOT NULL CHECK (balance >= 0))", .{});
    _ = try db.exec(&req, "INSERT INTO accounts VALUES (1, 100), (2, 0)", .{});

    const level = quiet();
    defer testing.log_level = level;
    var snap = try db.begin(&req, .{ .read_only = true });
    defer snap.deinit();
    try testing.expectEqual(@as(i64, 100), try snap.one(i64, &req, "SELECT balance FROM accounts WHERE id = 1", .{}));
    _ = try db.exec(&req, "UPDATE accounts SET balance = 90 WHERE id = 1", .{});
    try testing.expectEqual(@as(i64, 100), try snap.one(i64, &req, "SELECT balance FROM accounts WHERE id = 1", .{}));
    try testing.expectError(error.Database, snap.exec(&req, "UPDATE accounts SET balance = 1", .{}));
    try snap.commit(&req);
    try testing.expectEqual(@as(i64, 90), try db.one(i64, &req, "SELECT balance FROM accounts WHERE id = 1", .{}));
}

test "sqlite: transaction() commits, and rolls all of it back on a failure inside" {
    var r: Runtime = undefined;
    try r.init(2, 2);
    defer r.deinit();
    const io = r.io();
    var tmp: TmpFile = .init();
    defer tmp.deinit();
    const path = tmp.file("app.db");
    const db = try sqlite.Client.init(gpa, io, .{ .path = path, .readers = 2, .busy_timeout = .fromMilliseconds(20) });
    defer db.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var req: dusty.Request = .{ .arena = arena_state.allocator(), .io = io, ._parser = undefined, ._transport = undefined };
    _ = try db.exec(&req, "CREATE TABLE accounts (id INTEGER PRIMARY KEY, balance INTEGER NOT NULL CHECK (balance >= 0))", .{});
    _ = try db.exec(&req, "INSERT INTO accounts VALUES (1, 100), (2, 0)", .{});

    const level = quiet();
    defer testing.log_level = level;
    var attempts: u32 = 0;
    try db.transaction(&req, .{}, MoveTx.run, .{ &req, 10, &attempts });
    try testing.expectEqual(@as(i64, 10), try db.one(i64, &req, "SELECT balance FROM accounts WHERE id = 2", .{}));
    // A failure inside rolls all of it back, and is not retried.
    try testing.expectError(error.Database, db.transaction(&req, .{ .retries = 3 }, MoveTx.run, .{ &req, 1000, &attempts }));
    try testing.expectEqual(@as(i64, 90), try db.one(i64, &req, "SELECT balance FROM accounts WHERE id = 1", .{}));
    try testing.expectEqual(@as(u32, 2), attempts);
}

test "sqlite: past busy_timeout a call is 503; transaction() retries until the lock is gone" {
    var r: Runtime = undefined;
    try r.init(2, 2);
    defer r.deinit();
    const io = r.io();
    var tmp: TmpFile = .init();
    defer tmp.deinit();
    const path = tmp.file("app.db");
    const db = try sqlite.Client.init(gpa, io, .{ .path = path, .readers = 2, .busy_timeout = .fromMilliseconds(20) });
    defer db.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var req: dusty.Request = .{ .arena = arena_state.allocator(), .io = io, ._parser = undefined, ._transport = undefined };
    _ = try db.exec(&req, "CREATE TABLE accounts (id INTEGER PRIMARY KEY, balance INTEGER NOT NULL CHECK (balance >= 0))", .{});
    _ = try db.exec(&req, "INSERT INTO accounts VALUES (1, 100), (2, 0)", .{});

    const level = quiet();
    defer testing.log_level = level;
    var attempts: u32 = 0;
    // Another process (a raw connection here) holds the write lock: past
    // busy_timeout a call is ServiceUnavailable; transaction() runs
    // again until the lock is gone.
    var other = try sqlite.driver.Db.init(.{ .mode = .{ .File = try arena_state.allocator().dupeSentinel(u8, path, 0) }, .open_flags = .{ .write = true }, .threading_mode = .MultiThread });
    defer other.deinit();
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(other.db, "BEGIN IMMEDIATE", null, null, null));
    try testing.expectError(error.ServiceUnavailable, db.exec(&req, "UPDATE accounts SET balance = 0", .{}));
    try testing.expectEqual(anole_db.Class.unavailable, anole_db.lastError(&req).?.class);
    try testing.expectError(error.ServiceUnavailable, db.transaction(&req, .{}, MoveTx.run, .{ &req, 1, &attempts }));
    // Reads go on meanwhile.
    try testing.expectEqual(@as(i64, 100), try db.one(i64, &req, "SELECT balance FROM accounts WHERE id = 1", .{}));

    const Release = struct {
        fn run(io_: std.Io, conn: *sqlite.driver.Db) !void {
            // Time passing on purpose: retries = 100 x the 20 ms busy_timeout
            // outlast it more than 10 times over.
            try io_.sleep(.fromMilliseconds(150), .awake);
            _ = c.sqlite3_exec(conn.db, "COMMIT", null, null, null);
        }
    };
    var release = try io.concurrent(Release.run, .{ io, &other });
    defer release.cancel(io) catch {};
    attempts = 0;
    try db.transaction(&req, .{ .retries = 100 }, MoveTx.run, .{ &req, 1, &attempts });
    try release.await(io);
    try testing.expectEqual(@as(i64, 99), try db.one(i64, &req, "SELECT balance FROM accounts WHERE id = 1", .{}));
    try testing.expectEqual(@as(u32, 1), attempts);
}

test "sqlite: iterate in batches, on a reader and on :memory:'s writer; RETURNING and WITH ... INSERT go to the writer" {
    var r: Runtime = undefined;
    try r.init(2, 2);
    defer r.deinit();
    const io = r.io();
    var tmp: TmpFile = .init();
    defer tmp.deinit();
    for ([_][]const u8{ tmp.file("app.db"), ":memory:" }) |path| {
        const db = try sqlite.Client.init(gpa, io, .{ .path = path, .readers = 1 });
        defer db.deinit();
        var s: Scratch = undefined;
        s.init(io);
        defer s.deinit();
        const ctx = &s.ctx;
        _ = try db.exec(ctx, schema, .{});
        {
            var tx = try db.begin(ctx, .{});
            defer tx.deinit();
            for (0..300) |i| _ = try tx.exec(ctx, "INSERT INTO notes (title, done) VALUES (?, ?)", .{ try std.fmt.allocPrint(ctx.arena, "n{d}", .{i}), i % 2 == 0 });
            try tx.commit(ctx);
        }
        var rows = try db.iterate(Note, ctx, "SELECT id, title, done FROM notes WHERE id > ? ORDER BY id", .{0});
        var n: usize = 0;
        var done: usize = 0;
        while (try rows.next()) |note| {
            n += 1;
            if (note.done) done += 1;
        }
        rows.deinit();
        try testing.expectEqual(@as(usize, 300), n);
        try testing.expectEqual(@as(usize, 150), done);

        // Ended early: the connection is back for the next call.
        var some = try db.iterate([]const u8, ctx, "SELECT title FROM notes ORDER BY id", .{});
        try testing.expectEqualStrings("n0", (try some.next()).?);
        some.deinit();
        try testing.expectEqual(@as(i64, 300), try db.one(i64, ctx, "SELECT count(*) FROM notes", .{}));

        // Inside a transaction, on its connection.
        {
            var tx = try db.begin(ctx, .{});
            defer tx.deinit();
            var ids = try tx.iterate(i64, ctx, "SELECT id FROM notes WHERE id <= 3 ORDER BY id", .{});
            var sum: i64 = 0;
            while (try ids.next()) |id| sum += id;
            ids.deinit();
            try testing.expectEqual(@as(i64, 6), sum);
            try tx.commit(ctx);
        }

        // Writes that return rows, through `one`.
        const Id = struct { id: i64 };
        const made = try db.one(Id, ctx, "INSERT INTO notes (title) VALUES (?) RETURNING id", .{"returned"});
        try testing.expectEqual(@as(i64, 301), made.id);
        const via_with = try db.one(Id, ctx, "WITH v(t) AS (VALUES ('cte')) INSERT INTO notes (title) SELECT t FROM v RETURNING id", .{});
        try testing.expectEqual(@as(i64, 302), via_with.id);
        const gone = try db.all(Id, ctx, "DELETE FROM notes WHERE id > ? RETURNING id", .{300});
        try testing.expectEqual(@as(usize, 2), gone.len);
        try testing.expectEqual(@as(i64, 300), try db.one(i64, ctx, "SELECT count(*) FROM notes", .{}));
    }
}

test "sqlite: the statement cache keeps the newest; prepare = false keeps none" {
    const db = try sqlite.Client.init(gpa, testing.io, .{ .path = ":memory:", .statement_cache_size = 2 });
    defer db.deinit();
    var s: Scratch = undefined;
    s.init(testing.io);
    defer s.deinit();
    const cache = &db.writer.conn.cache;
    for (0..3) |_| {
        for ([_][]const u8{ "SELECT 1", "SELECT 2", "SELECT 3", "SELECT 4" }) |sql| {
            _ = try db.one(i64, &s.ctx, sql, .{});
            try testing.expect(cache.count() <= 2);
        }
    }
    try testing.expect(cache.contains("SELECT 4") and cache.contains("SELECT 3"));
    _ = try db.with(.{ .prepare = false }).one(i64, &s.ctx, "SELECT 5", .{});
    try testing.expect(!cache.contains("SELECT 5"));
}

test "sqlite: metrics, readiness and the pool gauges, attached after the fact" {
    var r: Runtime = undefined;
    try r.init(2, 2);
    defer r.deinit();
    const io = r.io();
    var tmp: TmpFile = .init();
    defer tmp.deinit();
    const db = try sqlite.Client.init(gpa, io, .{ .path = tmp.file("app.db"), .readers = 2 });
    defer db.deinit();
    var registry = observe.metrics.Registry.init(gpa, io);
    defer registry.deinit();
    var health = observe.Health.init(.{});
    try db.start(&registry, null, &health);
    try testing.expect(health.checks[0].ready(health.checks[0].ctx));
    try testing.expectEqualStrings("app.db", health.checks[0].name);

    var s: Scratch = undefined;
    s.init(io);
    defer s.deinit();
    _ = try db.one(i64, &s.ctx, "SELECT 1", .{});
    const level = quiet();
    defer testing.log_level = level;
    _ = db.exec(&s.ctx, "SELEC", .{}) catch {};

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try registry.render(&out.writer);
    const text = out.written();
    // The readiness ping counts too.
    try testing.expect(std.mem.indexOf(u8, text, "anole_db_query_duration_seconds_count{system=\"sqlite\",db=\"app.db\"} 3") != null);
    try testing.expect(std.mem.indexOf(u8, text, "anole_db_errors_total{system=\"sqlite\",db=\"app.db\",error=\"Database\"} 1") != null);
    try testing.expect(std.mem.indexOf(u8, text, "anole_db_pool_connections{system=\"sqlite\",db=\"app.db\",state=\"idle\"} 3") != null);
    try testing.expect(std.mem.indexOf(u8, text, "anole_db_pool_connections{system=\"sqlite\",db=\"app.db\",state=\"in_use\"} 0") != null);
}

const App = struct {
    db: *sqlite.Client = undefined,

    fn create(app: *App, req: *dusty.Request, res: *dusty.Response) !void {
        const title = req.query.get("title") orelse return error.BadRequest;
        const made = try app.db.one(struct { id: i64 }, req, "INSERT INTO notes (title) VALUES (?) RETURNING id", .{title});
        res.status = .created;
        try res.json(made);
    }

    fn show(app: *App, req: *dusty.Request, res: *dusty.Response) !void {
        const id = req.params.getInt(i64, "id") orelse return error.NotFound;
        try res.json(try app.db.one(Note, req, "SELECT id, title, done FROM notes WHERE id = ?", .{id}));
    }
};

test "sqlite: app.sqlite, served: 201, 409 on a duplicate, 404 on none; metrics and /readyz registered in any order" {
    var state: App = .{};
    var app = try server_mod.Server(App).init(gpa, .{ .executors = .exact(2) }, &state);
    defer app.deinit();
    // Before app.metrics and app.health: they are attached when serving starts.
    state.db = try app.sqlite(":memory:");
    try testing.expect(app.blocking_pool != null);
    _ = app.metrics(.{ .http = false });
    _ = app.health(.{});
    app.post("/notes", App.create);
    app.get("/notes/:id", App.show);
    var s: Scratch = undefined;
    s.init(app.io());
    defer s.deinit();
    _ = try state.db.exec(&s.ctx, schema, .{});

    const Check = struct {
        fn run(a: *server_mod.Server(App)) !void {
            defer a.stop();
            const io_ = a.io();
            try a.waitReady();
            var arena_state: std.heap.ArenaAllocator = .init(gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const port = a.addresses()[0].ip.getPort();
            const Fetched = struct { status: dusty.Status, body: []const u8 };
            const fetch = struct {
                fn f(io__: std.Io, ar: std.mem.Allocator, method: dusty.Method, url: []const u8) !Fetched {
                    var resp = try client_mod.client(io__).fetch(url, .{ .method = method });
                    defer resp.deinit();
                    return .{ .status = resp.status(), .body = try ar.dupe(u8, try resp.body()) };
                }
            }.f;
            const base = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{port});
            const made = try fetch(io_, arena, .post, try std.fmt.allocPrint(arena, "{s}/notes?title=hello", .{base}));
            try testing.expectEqual(dusty.Status.created, made.status);
            try testing.expectEqualStrings("{\"id\":1}", made.body);
            try testing.expectEqual(dusty.Status.conflict, (try fetch(io_, arena, .post, try std.fmt.allocPrint(arena, "{s}/notes?title=hello", .{base}))).status);
            const shown = try fetch(io_, arena, .get, try std.fmt.allocPrint(arena, "{s}/notes/1", .{base}));
            try testing.expectEqualStrings("{\"id\":1,\"title\":\"hello\",\"done\":false}", shown.body);
            try testing.expectEqual(dusty.Status.not_found, (try fetch(io_, arena, .get, try std.fmt.allocPrint(arena, "{s}/notes/2", .{base}))).status);
            try testing.expectEqual(dusty.Status.ok, (try fetch(io_, arena, .get, try std.fmt.allocPrint(arena, "{s}/readyz", .{base}))).status);
            const metrics = try fetch(io_, arena, .get, try std.fmt.allocPrint(arena, "{s}/metrics", .{base}));
            try testing.expect(std.mem.indexOf(u8, metrics.body, "anole_db_errors_total{system=\"sqlite\",db=\"memory\",error=\"Conflict\"} 1") != null);
        }
    };
    const level = quiet();
    defer testing.log_level = level;
    var checking = try app.io().concurrent(Check.run, .{&app});
    defer _ = checking.cancel(app.io()) catch {};
    try app.listen("127.0.0.1:0");
    try checking.await(app.io());
}

test "sqlite: iterate over a bare BEGIN fails left-open and rolls back" {
    const db = try sqlite.Client.init(gpa, testing.io, .{ .path = ":memory:" });
    defer db.deinit();
    var s: Scratch = undefined;
    s.init(testing.io);
    defer s.deinit();
    const ctx = &s.ctx;
    _ = try db.exec(ctx, schema, .{});
    const level = quiet();
    defer testing.log_level = level;
    var rows = try db.with(.{ .write = true }).iterate(struct {}, ctx, "BEGIN", .{});
    defer rows.deinit();
    try testing.expectError(error.Database, rows.next());
    try testing.expect(std.mem.indexOf(u8, anole_db.lastError(ctx).?.message, "left a transaction open") != null);
    // Back in autocommit: a following write commits on its own.
    try testing.expectEqual(@as(u64, 1), try db.exec(ctx, "INSERT INTO notes (title) VALUES ('after')", .{}));
    try testing.expectEqual(@as(i64, 1), try db.one(i64, ctx, "SELECT count(*) FROM notes", .{}));
}

test "sqlite: Rows deinit inside an open transaction rolls back" {
    const expected_log = @import("../errors.zig").expectLog();
    defer expected_log.deinit();
    // A file with a reader: a read sees only what the writer committed.
    var r: Runtime = undefined;
    try r.init(1, 2);
    defer r.deinit();
    const io = r.io();
    var tmp: TmpFile = .init();
    defer tmp.deinit();
    const db = try sqlite.Client.init(gpa, io, .{ .path = tmp.file("app.db"), .readers = 1 });
    defer db.deinit();
    var s: Scratch = undefined;
    s.init(io);
    defer s.deinit();
    const ctx = &s.ctx;
    _ = try db.exec(ctx, schema, .{});
    const level = quiet();
    defer testing.log_level = level;
    var rows = try db.with(.{ .write = true }).iterate(struct {}, ctx, "BEGIN", .{});
    rows.deinit();
    // Rolled back: the next write commits on its own, and a reader sees it.
    try testing.expectEqual(@as(u64, 1), try db.exec(ctx, "INSERT INTO notes (title) VALUES ('x')", .{}));
    try testing.expectEqual(@as(i64, 1), try db.one(i64, ctx, "SELECT count(*) FROM notes", .{}));
}

test "sqlite: acquire released inside a transaction rolls the writer back" {
    const expected_log = @import("../errors.zig").expectLog();
    defer expected_log.deinit();
    // A file with a reader: a read sees only what the writer committed.
    var r: Runtime = undefined;
    try r.init(1, 2);
    defer r.deinit();
    const io = r.io();
    var tmp: TmpFile = .init();
    defer tmp.deinit();
    const db = try sqlite.Client.init(gpa, io, .{ .path = tmp.file("app.db"), .readers = 1 });
    defer db.deinit();
    var s: Scratch = undefined;
    s.init(io);
    defer s.deinit();
    const ctx = &s.ctx;
    _ = try db.exec(ctx, schema, .{});
    const level = quiet();
    defer testing.log_level = level;
    const conn = try db.acquire(ctx);
    const Begin = struct {
        fn run(h: *sqlite.driver.Db) void {
            _ = c.sqlite3_exec(h.db, "BEGIN", null, null, null);
        }
    };
    conn.run(Begin.run, .{}) catch {};
    conn.release();
    // Rolled back: the next write commits on its own, and a reader sees it.
    try testing.expectEqual(@as(u64, 1), try db.exec(ctx, "INSERT INTO notes (title) VALUES ('x')", .{}));
    try testing.expectEqual(@as(i64, 1), try db.one(i64, ctx, "SELECT count(*) FROM notes", .{}));
}

test "sqlite: a writer released twice leaves the next holder's transaction alone" {
    const expected_log = @import("../errors.zig").expectLog();
    defer expected_log.deinit();
    var r: Runtime = undefined;
    try r.init(1, 2);
    defer r.deinit();
    const io = r.io();
    var tmp: TmpFile = .init();
    defer tmp.deinit();
    const db = try sqlite.Client.init(gpa, io, .{ .path = tmp.file("app.db"), .readers = 1 });
    defer db.deinit();
    var s: Scratch = undefined;
    s.init(io);
    defer s.deinit();
    const ctx = &s.ctx;
    _ = try db.exec(ctx, schema, .{});
    const level = quiet();
    defer testing.log_level = level;

    const first = try db.acquire(ctx);
    first.release();
    var tx = try db.begin(ctx, .{});
    defer tx.deinit();
    _ = try tx.exec(ctx, "INSERT INTO notes (title) VALUES ('kept')", .{});
    // The first checkout given back again, while the transaction holds the
    // writer: nothing happens to the transaction.
    first.release();
    try tx.commit(ctx);
    try testing.expectEqual(@as(i64, 1), try db.one(i64, ctx, "SELECT count(*) FROM notes", .{}));
}

/// A writer client on a file with one reader, its schema made, for the
/// tests of a checkout ended twice.
fn twiceSetup(io: std.Io, tmp: *TmpFile, s: *Scratch) !*sqlite.Client {
    s.init(io);
    errdefer s.deinit();
    const db = try sqlite.Client.init(gpa, io, .{ .path = tmp.file("app.db"), .readers = 1 });
    errdefer db.deinit();
    _ = try db.exec(&s.ctx, schema, .{});
    return db;
}

test "sqlite: a transaction ended through a copy leaves the next holder's transaction alone" {
    const expected_log = @import("../errors.zig").expectLog();
    defer expected_log.deinit();
    var r: Runtime = undefined;
    try r.init(1, 2);
    defer r.deinit();
    const io = r.io();
    var tmp: TmpFile = .init();
    defer tmp.deinit();
    var s: Scratch = undefined;
    const db = try twiceSetup(io, &tmp, &s);
    defer db.deinit();
    defer s.deinit();
    const ctx = &s.ctx;
    const level = quiet();
    defer testing.log_level = level;

    var tx = try db.begin(ctx, .{});
    // A copy commits; `tx` itself never learns that it ended.
    var copy = tx;
    try copy.commit(ctx);
    var next = try db.begin(ctx, .{});
    defer next.deinit();
    _ = try next.exec(ctx, "INSERT INTO notes (title) VALUES ('kept')", .{});
    // The first transaction's deinit, while `next` holds the writer:
    // nothing happens to `next`'s transaction.
    tx.deinit();
    try next.commit(ctx);
    try testing.expectEqual(@as(i64, 1), try db.one(i64, ctx, "SELECT count(*) FROM notes", .{}));
}

test "sqlite: rows on the writer ended through a copy leave the next holder's transaction alone" {
    const expected_log = @import("../errors.zig").expectLog();
    defer expected_log.deinit();
    var r: Runtime = undefined;
    try r.init(1, 2);
    defer r.deinit();
    const io = r.io();
    var tmp: TmpFile = .init();
    defer tmp.deinit();
    var s: Scratch = undefined;
    const db = try twiceSetup(io, &tmp, &s);
    defer db.deinit();
    defer s.deinit();
    const ctx = &s.ctx;
    const level = quiet();
    defer testing.log_level = level;

    var rows = try db.with(.{ .write = true }).iterate(Note, ctx, "SELECT id, title, done FROM notes", .{});
    var copy = rows;
    copy.deinit();
    var next = try db.begin(ctx, .{});
    defer next.deinit();
    _ = try next.exec(ctx, "INSERT INTO notes (title) VALUES ('kept')", .{});
    // The first rows' deinit, while `next` holds the writer: nothing
    // happens to `next`'s transaction.
    rows.deinit();
    try next.commit(ctx);
    try testing.expectEqual(@as(i64, 1), try db.one(i64, ctx, "SELECT count(*) FROM notes", .{}));
}

test "sqlite: a read-only transaction ended through a copy leaves the next reader's snapshot alone" {
    const expected_log = @import("../errors.zig").expectLog();
    defer expected_log.deinit();
    var r: Runtime = undefined;
    try r.init(1, 2);
    defer r.deinit();
    const io = r.io();
    var tmp: TmpFile = .init();
    defer tmp.deinit();
    var s: Scratch = undefined;
    const db = try twiceSetup(io, &tmp, &s);
    defer db.deinit();
    defer s.deinit();
    const ctx = &s.ctx;
    const level = quiet();
    defer testing.log_level = level;

    var tx = try db.begin(ctx, .{ .read_only = true });
    // A copy commits; `tx` itself never learns that it ended.
    var copy = tx;
    try copy.commit(ctx);
    // The one reader, now the next holder's; its snapshot starts at its
    // first read.
    var next = try db.begin(ctx, .{ .read_only = true });
    defer next.deinit();
    try testing.expectEqual(@as(i64, 0), try next.one(i64, ctx, "SELECT count(*) FROM notes", .{}));
    _ = try db.exec(ctx, "INSERT INTO notes (title) VALUES ('later')", .{});
    // The first transaction's deinit, while `next` holds the reader: `next`
    // keeps its snapshot.
    tx.deinit();
    try testing.expectEqual(@as(i64, 0), try next.one(i64, ctx, "SELECT count(*) FROM notes", .{}));
    try next.commit(ctx);
}

test "sqlite: rows on a reader ended through a copy leave the next reader's snapshot alone" {
    const expected_log = @import("../errors.zig").expectLog();
    defer expected_log.deinit();
    var r: Runtime = undefined;
    try r.init(1, 2);
    defer r.deinit();
    const io = r.io();
    var tmp: TmpFile = .init();
    defer tmp.deinit();
    var s: Scratch = undefined;
    const db = try twiceSetup(io, &tmp, &s);
    defer db.deinit();
    defer s.deinit();
    const ctx = &s.ctx;
    const level = quiet();
    defer testing.log_level = level;

    var rows = try db.iterate(Note, ctx, "SELECT id, title, done FROM notes", .{});
    var copy = rows;
    copy.deinit();
    var next = try db.begin(ctx, .{ .read_only = true });
    defer next.deinit();
    try testing.expectEqual(@as(i64, 0), try next.one(i64, ctx, "SELECT count(*) FROM notes", .{}));
    _ = try db.exec(ctx, "INSERT INTO notes (title) VALUES ('later')", .{});
    // The first rows' deinit, while `next` holds the reader: `next` keeps
    // its snapshot.
    rows.deinit();
    try testing.expectEqual(@as(i64, 0), try next.one(i64, ctx, "SELECT count(*) FROM notes", .{}));
    try next.commit(ctx);
}

test "sqlite: rows of a transaction a copy ended leave the next holder's statement alone" {
    const expected_log = @import("../errors.zig").expectLog();
    defer expected_log.deinit();
    var r: Runtime = undefined;
    try r.init(1, 2);
    defer r.deinit();
    const io = r.io();
    var tmp: TmpFile = .init();
    defer tmp.deinit();
    var s: Scratch = undefined;
    const db = try twiceSetup(io, &tmp, &s);
    defer db.deinit();
    defer s.deinit();
    const ctx = &s.ctx;
    const level = quiet();
    defer testing.log_level = level;
    // More rows than one batch (64), so the next holder steps its statement
    // again after the stale rows end.
    _ = try db.exec(ctx, "WITH RECURSIVE k(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM k WHERE x < 100) INSERT INTO notes (title) SELECT 'n' || x FROM k", .{});
    const sql = "SELECT id, title, done FROM notes ORDER BY id";

    var tx = try db.begin(ctx, .{ .read_only = true });
    var rows = try tx.iterate(Note, ctx, sql, .{});
    while (try rows.next()) |_| {}
    // A copy commits; `tx` and its rows never learn that it ended.
    var copy = tx;
    try copy.commit(ctx);
    // The same reader and the same cached statement, the next holder's.
    var next = try db.iterate(Note, ctx, sql, .{});
    defer next.deinit();
    try testing.expectEqual(@as(i64, 1), (try next.next()).?.id);
    // The stale rows' deinit, while `next` steps the statement: `next`
    // goes on where it was.
    rows.deinit();
    var last: i64 = 1;
    while (try next.next()) |note| {
        last += 1;
        try testing.expectEqual(last, note.id);
    }
    try testing.expectEqual(@as(i64, 100), last);
    tx.deinit();
}

/// One reader, 100 notes (more than one batch of 64), and the statement
/// cache of `cache_size`.
fn openRowsSetup(io: std.Io, tmp: *TmpFile, s: *Scratch, cache_size: u16) !*sqlite.Client {
    s.init(io);
    errdefer s.deinit();
    const db = try sqlite.Client.init(gpa, io, .{ .path = tmp.file("app.db"), .readers = 1, .statement_cache_size = cache_size });
    errdefer db.deinit();
    _ = try db.exec(&s.ctx, schema, .{});
    _ = try db.exec(&s.ctx, "WITH RECURSIVE k(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM k WHERE x < 100) INSERT INTO notes (title) SELECT 'n' || x FROM k", .{});
    return db;
}

const open_rows_sql = "SELECT id, title, done FROM notes ORDER BY id";

test "sqlite: rows a reader transaction left mid-result when a copy committed it: the next holder's rows of the same SQL start at the first row" {
    const expected_log = @import("../errors.zig").expectLog();
    defer expected_log.deinit();
    var r: Runtime = undefined;
    try r.init(1, 2);
    defer r.deinit();
    const io = r.io();
    var tmp: TmpFile = .init();
    defer tmp.deinit();
    var s: Scratch = undefined;
    const db = try openRowsSetup(io, &tmp, &s, 64);
    defer db.deinit();
    defer s.deinit();
    const ctx = &s.ctx;
    const level = quiet();
    defer testing.log_level = level;

    var tx = try db.begin(ctx, .{ .read_only = true });
    var rows = try tx.iterate(Note, ctx, open_rows_sql, .{});
    // One batch stepped, the statement mid-result.
    try testing.expectEqual(@as(i64, 1), (try rows.next()).?.id);
    var copy = tx;
    try copy.commit(ctx);
    // The same reader and the same cached statement, the next holder's.
    var next = try db.iterate(Note, ctx, open_rows_sql, .{});
    defer next.deinit();
    try testing.expectEqual(@as(i64, 1), (try next.next()).?.id);
    rows.deinit();
    tx.deinit();
}

/// A reader transaction's rows stepped one batch, the transaction
/// committed with the rows still open (their deinit deferred past the
/// commit), then a write: the same reader's next call must see it.
fn laterWriteSeen(cache_size: u16) !void {
    var r: Runtime = undefined;
    try r.init(1, 2);
    defer r.deinit();
    const io = r.io();
    var tmp: TmpFile = .init();
    defer tmp.deinit();
    var s: Scratch = undefined;
    const db = try openRowsSetup(io, &tmp, &s, cache_size);
    defer db.deinit();
    defer s.deinit();
    const ctx = &s.ctx;

    var tx = try db.begin(ctx, .{ .read_only = true });
    defer tx.deinit();
    var rows = try tx.iterate(Note, ctx, open_rows_sql, .{});
    defer rows.deinit();
    try testing.expectEqual(@as(i64, 1), (try rows.next()).?.id);
    try tx.commit(ctx);
    _ = try db.exec(ctx, "INSERT INTO notes (title) VALUES ('later')", .{});
    // One reader: the one the transaction gave back.
    try testing.expectEqual(@as(i64, 101), try db.one(i64, ctx, "SELECT count(*) FROM notes", .{}));
}

test "sqlite: rows a reader transaction left mid-result at its commit keep no snapshot: another statement on that reader sees a later write" {
    try laterWriteSeen(64);
}

test "sqlite: with the statement cache off, rows a reader transaction left mid-result at its commit keep no snapshot: another statement on that reader sees a later write" {
    try laterWriteSeen(0);
}

test "sqlite: rows of a transaction that is over fail at their next batch instead of stepping the connection given back" {
    const expected_log = @import("../errors.zig").expectLog();
    defer expected_log.deinit();
    var r: Runtime = undefined;
    try r.init(1, 2);
    defer r.deinit();
    const io = r.io();
    var tmp: TmpFile = .init();
    defer tmp.deinit();
    var s: Scratch = undefined;
    const db = try openRowsSetup(io, &tmp, &s, 64);
    defer db.deinit();
    defer s.deinit();
    const ctx = &s.ctx;
    const level = quiet();
    defer testing.log_level = level;

    var tx = try db.begin(ctx, .{ .read_only = true });
    defer tx.deinit();
    var rows = try tx.iterate(Note, ctx, open_rows_sql, .{});
    defer rows.deinit();
    // The first batch, read before the commit.
    var id: i64 = 0;
    while (id < 64) : (id += 1) try testing.expectEqual(id + 1, (try rows.next()).?.id);
    try tx.commit(ctx);
    try testing.expectError(error.Database, rows.next());
}

/// The canceled begin's hook, on the writer thread after a job ran: holds the job
/// running until its canceled caller has interrupted it.
const BeginCanceled = struct {
    var armed: std.atomic.Value(bool) = .init(false);
    var ran: std.atomic.Value(bool) = .init(false);

    fn afterJob(io: std.Io, handle: ?*c.sqlite3) void {
        if (!armed.swap(false, .acq_rel)) return;
        ran.store(true, .release);
        // The deadline is a hang guard.
        const until = std.Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .raw = wait.deadline(), .clock = .awake });
        while (c.sqlite3_is_interrupted(handle) == 0) {
            if (until.untilNow(io).raw.nanoseconds >= 0) return;
            std.Thread.yield() catch {};
        }
    }

    fn hasRun(_: void) bool {
        return ran.load(.acquire);
    }

    fn begin(db: *sqlite.Client, io: std.Io, failure: *?anyerror) void {
        var sc: Scratch = undefined;
        sc.init(io);
        defer sc.deinit();
        var tx = db.begin(&sc.ctx, .{}) catch |err| {
            if (err != error.Canceled) failure.* = err;
            return;
        };
        // Not canceled in time (the BEGIN ran and returned first).
        tx.deinit();
        failure.* = error.NotCanceled;
    }
};

test "sqlite: a begin canceled while its BEGIN runs gives the writer back with no transaction open" {
    var r: Runtime = undefined;
    try r.init(1, 2);
    defer r.deinit();
    const io = r.io();
    var tmp: TmpFile = .init();
    defer tmp.deinit();
    const db = try sqlite.Client.init(gpa, io, .{ .path = tmp.file("app.db"), .readers = 1 });
    defer db.deinit();
    var s: Scratch = undefined;
    s.init(io);
    defer s.deinit();
    const ctx = &s.ctx;
    _ = try db.exec(ctx, schema, .{});

    BeginCanceled.ran.store(false, .release);
    BeginCanceled.armed.store(true, .release);
    sqlite.test_after_job = BeginCanceled.afterJob;
    defer sqlite.test_after_job = null;
    defer BeginCanceled.armed.store(false, .release);
    var failure: ?anyerror = null;
    var task = try io.concurrent(BeginCanceled.begin, .{ db, io, &failure });
    // The BEGIN has run on the writer thread; its caller still waits.
    try wait.waitUntil(io, "the BEGIN run", {}, BeginCanceled.hasRun);
    task.cancel(io);
    if (failure) |err| return err;
    // The next holder begins a transaction of its own.
    var tx = try db.begin(ctx, .{});
    defer tx.deinit();
    _ = try tx.exec(ctx, "INSERT INTO notes (title) VALUES ('kept')", .{});
    try tx.commit(ctx);
    try testing.expectEqual(@as(i64, 1), try db.one(i64, ctx, "SELECT count(*) FROM notes", .{}));
}

/// Tasks that hold a connection until `go` is set.
const Holders = struct {
    db: *sqlite.Client,
    io: std.Io,
    go: std.Io.Event = .unset,
    failed: std.atomic.Value(u32) = .init(0),

    fn iterate(h: *Holders) void {
        var sc: Scratch = undefined;
        sc.init(h.io);
        defer sc.deinit();
        var rows = h.db.iterate(Note, &sc.ctx, "SELECT id, title, done FROM notes", .{}) catch {
            _ = h.failed.fetchAdd(1, .monotonic);
            return;
        };
        defer rows.deinit();
        h.go.wait(h.io) catch {};
    }

    fn acquire(h: *Holders) void {
        var sc: Scratch = undefined;
        sc.init(h.io);
        defer sc.deinit();
        const conn = h.db.acquire(&sc.ctx) catch {
            _ = h.failed.fetchAdd(1, .monotonic);
            return;
        };
        defer conn.release();
        h.go.wait(h.io) catch {};
    }

    fn read(h: *Holders) void {
        var sc: Scratch = undefined;
        sc.init(h.io);
        defer sc.deinit();
        _ = h.db.one(i64, &sc.ctx, "SELECT count(*) FROM notes", .{}) catch {
            _ = h.failed.fetchAdd(1, .monotonic);
        };
    }
};

/// Whether the console's `/db` entry of `db` says `want`.
fn consoleSays(db: *sqlite.Client, comptime want: []const u8) bool {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    db.consoleInfo(&w) catch return false;
    return std.mem.indexOf(u8, w.buffered(), want) != null;
}

test "sqlite: the console's in_use and waiting count calls on every executor" {
    var r: Runtime = undefined;
    try r.init(2, 2);
    defer r.deinit();
    const io = r.io();
    var tmp: TmpFile = .init();
    defer tmp.deinit();
    const db = try sqlite.Client.init(gpa, io, .{ .path = tmp.file("app.db"), .readers = 1 });
    defer db.deinit();
    var s: Scratch = undefined;
    s.init(io);
    defer s.deinit();
    _ = try db.exec(&s.ctx, schema, .{});

    var h: Holders = .{ .db = db, .io = io };
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    // The reader held on executor 0, the writer on executor 1, and a read
    // on executor 1 waiting for the reader.
    try dusty.placement.concurrent(&group, io, .{ .executor = 0 }, Holders.iterate, .{&h});
    try wait.waitUntil(io, "the reader held", db, struct {
        fn f(d: *sqlite.Client) bool {
            return consoleSays(d, "\"in_use\":1,");
        }
    }.f);
    try dusty.placement.concurrent(&group, io, .{ .executor = 1 }, Holders.acquire, .{&h});
    try dusty.placement.concurrent(&group, io, .{ .executor = 1 }, Holders.read, .{&h});
    try wait.waitUntil(io, "two connections in use and one call waiting", db, struct {
        fn f(d: *sqlite.Client) bool {
            return consoleSays(d, "\"in_use\":2,\"waiting\":1}");
        }
    }.f);
    h.go.set(io);
    try group.await(io);
    try testing.expectEqual(@as(u32, 0), h.failed.load(.monotonic));
    try testing.expect(consoleSays(db, "\"in_use\":0,\"waiting\":0}"));
}

test "sqlite: Tx.table and Tx.run see the transaction's own writes" {
    const db = try sqlite.Client.init(gpa, testing.io, .{ .path = ":memory:" });
    defer db.deinit();
    var s: Scratch = undefined;
    s.init(testing.io);
    defer s.deinit();
    const ctx = &s.ctx;
    _ = try db.exec(ctx, schema, .{});
    var tx = try db.begin(ctx, .{});
    defer tx.deinit();
    const ch = try tx.execValues(ctx, "INSERT INTO notes (title) VALUES (?)", &.{.{ .text = "inside" }});
    try testing.expectEqual(@as(u64, 1), ch.changes);
    const t = try tx.table(ctx, "SELECT title FROM notes", &.{});
    try testing.expectEqual(@as(usize, 1), t.rows.len);
    try tx.commit(ctx);
}

test "sqlite: Tx.with refuses coalesce and cache" {
    const db = try sqlite.Client.init(gpa, testing.io, .{ .path = ":memory:" });
    defer db.deinit();
    var s: Scratch = undefined;
    s.init(testing.io);
    defer s.deinit();
    const ctx = &s.ctx;
    var tx = try db.begin(ctx, .{});
    defer tx.deinit();
    const level = quiet();
    defer testing.log_level = level;
    try testing.expectError(error.Database, tx.with(.{ .coalesce = true }).one(i64, ctx, "SELECT 1", .{}));
    try testing.expect(std.mem.indexOf(u8, anole_db.lastError(ctx).?.message, "coalesce and cache") != null);
}

test "sqlite: commit after commit is an error, not an assert" {
    const db = try sqlite.Client.init(gpa, testing.io, .{ .path = ":memory:" });
    defer db.deinit();
    var s: Scratch = undefined;
    s.init(testing.io);
    defer s.deinit();
    const ctx = &s.ctx;
    var tx = try db.begin(ctx, .{});
    defer tx.deinit();
    try tx.commit(ctx);
    const level = quiet();
    defer testing.log_level = level;
    try testing.expectError(error.Database, tx.commit(ctx));
    try testing.expectError(error.Database, tx.rollback(ctx));
    try testing.expect(std.mem.indexOf(u8, anole_db.lastError(ctx).?.message, "the transaction is over") != null);
}

test "sqlite: Options.timeout bounds a plain call and .max lifts it" {
    const db = try sqlite.Client.init(gpa, testing.io, .{ .path = ":memory:", .timeout = .fromMilliseconds(50) });
    defer db.deinit();
    var s: Scratch = undefined;
    s.init(testing.io);
    defer s.deinit();
    const ctx = &s.ctx;
    const level = quiet();
    defer testing.log_level = level;
    const endless = "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 1000000000) SELECT count(*) FROM n";
    try testing.expectError(error.GatewayTimeout, db.one(i64, ctx, endless, .{}));
    const small = "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 100000) SELECT count(*) FROM n";
    try testing.expectEqual(@as(i64, 100000), try db.with(.{ .timeout = .max }).one(i64, ctx, small, .{}));
}

/// The stress test's worker: its rounds against the writer checkout.
/// Counts the rows it committed and every failure that is not a cancel the
/// test made.
const WriterStress = struct {
    db: *sqlite.Client,
    io: std.Io,
    committed: std.atomic.Value(u64) = .init(0),
    failures: std.atomic.Value(u32) = .init(0),

    const Op = enum { insert, tx_commit, tx_rollback, acquire, acquire_twice, read };

    fn noop(_: *sqlite.driver.Db) void {}

    /// One operation. A canceled one (`error.Canceled`) is fine for the
    /// operations that commit nothing; the rest must succeed.
    fn one(w: *WriterStress, sc: *Scratch, op: Op, id: u64) error{Canceled}!void {
        var buf: [40]u8 = undefined;
        const title = std.fmt.bufPrint(&buf, "s1-{d}", .{id}) catch unreachable;
        var buf2: [40]u8 = undefined;
        const title2 = std.fmt.bufPrint(&buf2, "s1-{d}b", .{id}) catch unreachable;
        const ctx = &sc.ctx;
        switch (op) {
            .insert => {
                _ = w.db.exec(ctx, "INSERT INTO notes (title) VALUES (?)", .{title}) catch |err| return w.failed(sc, err);
                _ = w.committed.fetchAdd(1, .monotonic);
            },
            .tx_commit, .tx_rollback => {
                var tx = w.db.begin(ctx, .{}) catch |err| return w.failed(sc, err);
                defer tx.deinit();
                _ = tx.exec(ctx, "INSERT INTO notes (title) VALUES (?)", .{title}) catch |err| return w.failed(sc, err);
                _ = tx.exec(ctx, "INSERT INTO notes (title) VALUES (?)", .{title2}) catch |err| return w.failed(sc, err);
                if (op == .tx_rollback) {
                    tx.rollback(ctx) catch |err| return w.failed(sc, err);
                } else {
                    tx.commit(ctx) catch |err| return w.failed(sc, err);
                    _ = w.committed.fetchAdd(2, .monotonic);
                }
            },
            .acquire, .acquire_twice => {
                const conn = w.db.acquire(ctx) catch |err| return w.failed(sc, err);
                defer conn.release();
                conn.run(noop, .{}) catch |err| return w.failed(sc, err);
                // The second release (deferred) does nothing.
                if (op == .acquire_twice) conn.release();
            },
            .read => _ = w.db.one(i64, ctx, "SELECT count(*) FROM notes", .{}) catch |err| return w.failed(sc, err),
        }
    }

    fn failed(w: *WriterStress, sc: *Scratch, err: anyerror) error{Canceled}!void {
        if (err == error.Canceled) return error.Canceled;
        if (anole_db.lastError(&sc.ctx)) |d| std.debug.print("sqlite stress: {t}: {f}\n", .{ err, d }) else std.debug.print("sqlite stress: {t}\n", .{err});
        _ = w.failures.fetchAdd(1, .monotonic);
    }

    /// A task's rounds; ids are `base + round`. A seeded few run as a
    /// child task canceled after a seeded number of yields: those commit
    /// nothing (a rolled-back transaction or a checkout), so the count
    /// stays exact whether the cancel lands while waiting for the writer,
    /// in a statement, or after.
    fn task(w: *WriterStress, seed: u64, base: u64, rounds: u64) void {
        var prng: std.Random.DefaultPrng = .init(seed);
        const random = prng.random();
        var sc: Scratch = undefined;
        sc.init(w.io);
        defer sc.deinit();
        for (0..rounds) |i| {
            _ = sc.arena.reset(.retain_capacity);
            const op = random.enumValue(Op);
            if ((op == .tx_rollback or op == .acquire or op == .acquire_twice) and random.uintLessThan(u8, 3) == 0) {
                var child = w.io.concurrent(cancelable, .{ w, op, base + i }) catch {
                    _ = w.failures.fetchAdd(1, .monotonic);
                    continue;
                };
                for (0..random.uintLessThan(u8, 6)) |_| zio.yield() catch {};
                child.cancel(w.io);
                continue;
            }
            w.one(&sc, op, base + i) catch {};
        }
    }

    fn cancelable(w: *WriterStress, op: Op, id: u64) void {
        var sc: Scratch = undefined;
        sc.init(w.io);
        defer sc.deinit();
        w.one(&sc, op, id) catch {};
    }

    /// The blocking-pool caller: writes and checkouts from an OS thread.
    fn blockingTask(w: *WriterStress, seed: u64, base: u64, rounds: u64) void {
        var prng: std.Random.DefaultPrng = .init(seed);
        const random = prng.random();
        var sc: Scratch = undefined;
        sc.init(w.io);
        defer sc.deinit();
        for (0..rounds) |i| {
            _ = sc.arena.reset(.retain_capacity);
            const op: Op = switch (random.uintLessThan(u8, 4)) {
                0 => .insert,
                1 => .tx_commit,
                2 => .acquire,
                else => .acquire_twice,
            };
            w.one(&sc, op, base + i) catch {};
        }
    }

    fn onBlocking(w: *WriterStress, pool: *blocking.Pool, seed: u64, base: u64, rounds: u64) void {
        pool.run(w.io, blockingTask, .{ w, seed, base, rounds }) catch {
            _ = w.failures.fetchAdd(1, .monotonic);
        };
    }
};

test "sqlite: [stress] writes, transactions and acquire from four executors and a blocking thread, with cancels, keep one writer holder" {
    try wait.requireStress();
    const expected_log = @import("../errors.zig").expectLog();
    defer expected_log.deinit();
    var r: Runtime = undefined;
    try r.init(4, 4);
    defer r.deinit();
    const io = r.io();
    var tmp: TmpFile = .init();
    defer tmp.deinit();
    // The busy timeout is the hang guard: the claim is one writer holder,
    // not how soon a reader gets in on a loaded machine.
    const db = try sqlite.Client.init(gpa, io, .{ .path = tmp.file("app.db"), .readers = 2, .busy_timeout = wait.deadline() });
    defer db.deinit();
    var s: Scratch = undefined;
    s.init(io);
    defer s.deinit();
    _ = try db.exec(&s.ctx, schema, .{});
    const level = quiet();
    defer testing.log_level = level;

    const seed: u64 = 0x51_5ee0;
    errdefer std.debug.print("sqlite stress: seed 0x{x}\n", .{seed});
    var w: WriterStress = .{ .db = db, .io = io };
    const tasks = 16;
    const rounds = 120;
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (0..tasks) |t| try dusty.placement.concurrent(&group, io, .{ .executor = t % 4 }, WriterStress.task, .{ &w, seed +% t, t * 1000, rounds });
    try dusty.placement.concurrent(&group, io, .{ .executor = 0 }, WriterStress.onBlocking, .{ &w, &r.pool, seed +% tasks, tasks * 1000, rounds });
    try group.await(io);

    try testing.expectEqual(@as(u32, 0), w.failures.load(.monotonic));
    try testing.expectEqual(@as(i64, @intCast(w.committed.load(.monotonic))), try db.one(i64, &s.ctx, "SELECT count(*) FROM notes", .{}));
    try testing.expect(consoleSays(db, "\"in_use\":0,\"waiting\":0}"));
}

const migrations = [_]anole_db.Migration{
    .{ .version = 1, .name = "notes", .sql = "CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL);" },
    .{ .version = 2, .name = "tags", .sql =
    \\CREATE TABLE tags (note INTEGER NOT NULL REFERENCES notes (id), tag TEXT NOT NULL);
    \\CREATE INDEX tags_note ON tags (note);
    },
};

fn tableExists(db: *sqlite.Client, ctx: *anole_db.Ctx, name: []const u8) !bool {
    return try db.one(i64, ctx, "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = ?", .{name}) == 1;
}

test "sqlite: migrate runs each migration once and records it, across opens of the file" {
    var tmp: TmpFile = .init();
    defer tmp.deinit();
    const path = tmp.file("app.db");
    var s: Scratch = undefined;
    s.init(testing.io);
    defer s.deinit();
    {
        const db = try sqlite.Client.init(gpa, testing.io, .{ .path = path });
        defer db.deinit();
        try testing.expectEqual(@as(usize, 1), try anole_db.migrate(db, &s.ctx, migrations[0..1]));
        try testing.expectEqual(@as(usize, 1), try anole_db.migrate(db, &s.ctx, &migrations));
        try testing.expectEqual(@as(usize, 0), try anole_db.migrate(db, &s.ctx, &migrations));
    }
    const db = try sqlite.Client.init(gpa, testing.io, .{ .path = path });
    defer db.deinit();
    try testing.expectEqual(@as(usize, 0), try anole_db.migrate(db, &s.ctx, &migrations));
    const Applied = struct { version: i64, name: []const u8, applied_at: i64 };
    const rows = try db.all(Applied, &s.ctx, "SELECT version, name, applied_at FROM schema_migrations ORDER BY version", .{});
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("notes", rows[0].name);
    try testing.expectEqualStrings("tags", rows[1].name);
    try testing.expect(rows[1].applied_at > 0);
    try testing.expect(try tableExists(db, &s.ctx, "tags"));
}

test "sqlite: migrate rolls back a failing migration with its record, and keeps the ones before it" {
    const db = try sqlite.Client.init(gpa, testing.io, .{ .path = "sqlite::memory:" });
    defer db.deinit();
    var s: Scratch = undefined;
    s.init(testing.io);
    defer s.deinit();
    const broken = [_]anole_db.Migration{
        migrations[0],
        .{ .version = 2, .name = "tags", .sql =
        \\CREATE TABLE tags (note INTEGER NOT NULL, tag TEXT NOT NULL);
        \\INSERT INTO missing VALUES (1);
        },
    };
    {
        const level = quiet();
        defer testing.log_level = level;
        try testing.expectError(error.Database, anole_db.migrate(db, &s.ctx, &broken));
    }
    try testing.expectEqual(@as(i64, 1), try db.one(i64, &s.ctx, "SELECT max(version) FROM schema_migrations", .{}));
    try testing.expect(!try tableExists(db, &s.ctx, "tags"));
    // Fixed, it runs.
    try testing.expectEqual(@as(usize, 1), try anole_db.migrate(db, &s.ctx, &migrations));
    try testing.expect(try tableExists(db, &s.ctx, "tags"));
}

test "sqlite: migrate refuses versions that do not increase from 1, before running any" {
    const db = try sqlite.Client.init(gpa, testing.io, .{ .path = "sqlite::memory:" });
    defer db.deinit();
    var s: Scratch = undefined;
    s.init(testing.io);
    defer s.deinit();
    const level = quiet();
    defer testing.log_level = level;
    try testing.expectError(error.MigrationsOutOfOrder, anole_db.migrate(db, &s.ctx, &.{ migrations[1], migrations[0] }));
    try testing.expectError(error.MigrationsOutOfOrder, anole_db.migrate(db, &s.ctx, &.{ migrations[0], migrations[0] }));
    try testing.expectError(error.MigrationsOutOfOrder, anole_db.migrate(db, &s.ctx, &.{.{ .version = 0, .name = "zero", .sql = "SELECT 1;" }}));
    try testing.expect(!try tableExists(db, &s.ctx, "schema_migrations"));
}

test "sqlite: migrate runs a migration below the latest applied when it is not recorded" {
    const db = try sqlite.Client.init(gpa, testing.io, .{ .path = "sqlite::memory:" });
    defer db.deinit();
    var s: Scratch = undefined;
    s.init(testing.io);
    defer s.deinit();
    const later = [_]anole_db.Migration{.{ .version = 5, .name = "users", .sql = "CREATE TABLE users (id INTEGER PRIMARY KEY);" }};
    try testing.expectEqual(@as(usize, 1), try anole_db.migrate(db, &s.ctx, &later));
    const merged = [_]anole_db.Migration{ migrations[0], later[0] };
    try testing.expectEqual(@as(usize, 1), try anole_db.migrate(db, &s.ctx, &merged));
    try testing.expect(try tableExists(db, &s.ctx, "notes"));
}
