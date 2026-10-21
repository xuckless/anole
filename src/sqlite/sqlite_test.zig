//! anole.sqlite: files in a temporary directory and `:memory:`, on
//! std.Io.Threaded and on zio (pinned, with a blocking pool), and served by
//! `anole.Server` through `app.sqlite`.
const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");
const anole_db = @import("../db/root.zig");
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
    const db = try sqlite.Db.init(gpa, testing.io, .{ .path = "sqlite::memory:" });
    defer db.deinit();
    try testing.expectEqualStrings("memory", db.name);
    try testing.expectEqual(@as(usize, 0), db.readers.conns.len);
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
}

test "sqlite: values both ways: times, enums, optionals, JSON, blobs, defaults" {
    const db = try sqlite.Db.init(gpa, testing.io, .{ .path = ":memory:" });
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
    // SQL that SQLite refuses: the detail stays for lastError.
    try testing.expectError(error.Database, db.exec(ctx, "SELEC 1", .{}));
    try testing.expectEqualStrings("1", anole_db.lastError(ctx).?.code);
    try testing.expectStringStartsWith(anole_db.lastError(ctx).?.message, "near \"SELEC\"");
}

test "sqlite: constraint errors become statuses; ErrorMap moves them" {
    var tmp: TmpFile = .init();
    defer tmp.deinit();
    const db = try sqlite.Db.init(gpa, testing.io, .{ .path = tmp.file("app.db"), .readers = 1 });
    defer db.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    // On a request: what lastError keeps lives in its locals.
    var req: dusty.Request = .{ .arena = arena_state.allocator(), .io = testing.io, .parser = undefined, .transport = undefined };

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
    const strict = try sqlite.Db.init(gpa, testing.io, .{ .path = tmp.file("app.db"), .readers = 1, .errors = .{ .foreign_key = .unprocessable_entity, .check = .bad_request } });
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
    const db = try sqlite.Db.init(gpa, io, .{ .path = tmp.file("app.db") });
    defer db.deinit();
    try testing.expectEqual(@as(usize, 4), db.readers.conns.len);
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
        const started: std.Io.Clock.Timestamp = .now(io, .awake);
        try testing.expectEqual(@as(i64, 1), try db.one(i64, ctx, "SELECT count(*) FROM notes", .{}));
        try testing.expect(started.durationTo(.now(io, .awake)).raw.toMilliseconds() < 1000);
        try tx.commit(ctx);
    }
    try testing.expectEqual(@as(i64, 2), try db.one(i64, ctx, "SELECT count(*) FROM notes", .{}));

    // 16 tasks over the 4 executors, each writing 25 rows and reading
    // between writes: every write lands, no SQLITE_BUSY.
    const Worker = struct {
        fn run(d: *sqlite.Db, io_: std.Io, n: usize, failures: *std.atomic.Value(u32)) void {
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
    // Every connection is back.
    try testing.expectEqual(@as(usize, 4), db.readers.free_len);
    try testing.expectEqual(@as(i64, 0), db.in_use.load(.monotonic));
}

test "sqlite: coalesced and cached reads on 4 executors; invalidation after a write" {
    var r: Runtime = undefined;
    try r.init(4, 8);
    defer r.deinit();
    const io = r.io();
    var tmp: TmpFile = .init();
    defer tmp.deinit();
    const db = try sqlite.Db.init(gpa, io, .{ .path = tmp.file("shared.db") });
    defer db.deinit();
    var s: Scratch = undefined;
    s.init(io);
    defer s.deinit();
    const ctx = &s.ctx;
    _ = try db.exec(ctx, schema, .{});

    // A read slow enough that the callers on each executor meet in flight.
    const slow = "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < ?) SELECT count(*) FROM n";
    const Worker = struct {
        fn run(d: *sqlite.Db, io_: std.Io, failures: *std.atomic.Value(u32)) void {
            var sc: Scratch = undefined;
            sc.init(io_);
            defer sc.deinit();
            const n = d.with(.{ .coalesce = true }).one(i64, &sc.ctx, slow, .{1_000_000}) catch 0;
            if (n != 1_000_000) _ = failures.fetchAdd(1, .monotonic);
        }
    };
    var failures: std.atomic.Value(u32) = .init(0);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (0..32) |n| try dusty.placement.concurrent(&group, io, .{ .executor = n % 4 }, Worker.run, .{ db, io, &failures });
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

test "sqlite: :memory: is one database seen from every executor" {
    var r: Runtime = undefined;
    try r.init(4, 2);
    defer r.deinit();
    const io = r.io();
    const db = try sqlite.Db.init(gpa, io, .{ .path = ":memory:" });
    defer db.deinit();
    var s: Scratch = undefined;
    s.init(io);
    defer s.deinit();
    _ = try db.exec(&s.ctx, "CREATE TABLE seen (executor INTEGER)", .{});

    const Worker = struct {
        fn run(d: *sqlite.Db, io_: std.Io, out: *std.atomic.Value(u32)) void {
            var sc: Scratch = undefined;
            sc.init(io_);
            defer sc.deinit();
            const here = anole_db.executorIndex(io_) orelse 99;
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

test "sqlite: a timeout or a cancel interrupts a long query within milliseconds, on a reader and on the writer" {
    var r: Runtime = undefined;
    try r.init(2, 2);
    defer r.deinit();
    const io = r.io();
    var tmp: TmpFile = .init();
    defer tmp.deinit();
    // One reader, so the next read reuses the interrupted connection.
    const file_db = try sqlite.Db.init(gpa, io, .{ .path = tmp.file("app.db"), .readers = 1 });
    defer file_db.deinit();
    const memory_db = try sqlite.Db.init(gpa, io, .{ .path = ":memory:" });
    defer memory_db.deinit();
    var s: Scratch = undefined;
    s.init(io);
    defer s.deinit();
    const ctx = &s.ctx;
    const level = quiet();
    defer testing.log_level = level;

    const Case = struct { db: *sqlite.Db, write: bool };
    for ([_]Case{ .{ .db = file_db, .write = false }, .{ .db = file_db, .write = true }, .{ .db = memory_db, .write = false } }) |case| {
        const q = case.db.with(.{ .timeout = .fromMilliseconds(50), .write = case.write });
        const started: std.Io.Clock.Timestamp = .now(io, .awake);
        try testing.expectError(error.GatewayTimeout, q.one(i64, ctx, forever, .{}));
        try testing.expect(started.durationTo(.now(io, .awake)).raw.toMilliseconds() < 1000);
        try testing.expectEqual(anole_db.Class.timeout, anole_db.lastError(ctx).?.class);
        // The connection serves the next query.
        try testing.expectEqual(@as(i64, 3), try case.db.with(.{ .write = case.write }).one(i64, ctx, "SELECT 1 + 2", .{}));

        // A canceled task (a request's deadline, an RST_STREAM).
        const Long = struct {
            fn run(q_: sqlite.Query, io_: std.Io) sqlite.CallError!i64 {
                var sc: Scratch = undefined;
                sc.init(io_);
                defer sc.deinit();
                return q_.one(i64, &sc.ctx, forever, .{});
            }
        };
        var long = try io.concurrent(Long.run, .{ case.db.with(.{ .write = case.write }), io });
        try io.sleep(.fromMilliseconds(30), .awake);
        const cancel_at: std.Io.Clock.Timestamp = .now(io, .awake);
        try testing.expectError(error.Canceled, long.cancel(io));
        try testing.expect(cancel_at.durationTo(.now(io, .awake)).raw.toMilliseconds() < 1000);
        try testing.expectEqual(@as(i64, 4), try case.db.with(.{ .write = case.write }).one(i64, ctx, "SELECT 2 + 2", .{}));
    }
    // A write canceled while waiting for the writer never runs.
    {
        var tx = try file_db.begin(ctx, .{});
        _ = try tx.exec(ctx, "CREATE TABLE IF NOT EXISTS t (x)", .{});
        const Write = struct {
            fn run(d: *sqlite.Db, io_: std.Io) sqlite.CallError!u64 {
                var sc: Scratch = undefined;
                sc.init(io_);
                defer sc.deinit();
                return d.exec(&sc.ctx, "INSERT INTO t VALUES (1)", .{});
            }
        };
        var waiting = try io.concurrent(Write.run, .{ file_db, io });
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
    const db = try sqlite.Db.init(gpa, io, .{ .path = tmp.file("app.db") });
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
    // A read (blocking pool) and a write (the writer thread), each long
    // enough for the ticker to run beside them.
    const count = "WITH RECURSIVE r(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM r WHERE i < 300000) SELECT count(*) FROM r";
    try testing.expectEqual(@as(i64, 300000), try db.one(i64, &s.ctx, count, .{}));
    const after_read = ticks.load(.monotonic);
    try testing.expect(after_read >= 3);
    try testing.expectEqual(@as(i64, 300000), try db.with(.{ .write = true }).one(i64, &s.ctx, count, .{}));
    try testing.expect(ticks.load(.monotonic) - after_read >= 3);
}

test "sqlite: transactions: commit, rollback, deinit, and transaction() retried past SQLITE_BUSY" {
    var r: Runtime = undefined;
    try r.init(2, 2);
    defer r.deinit();
    const io = r.io();
    var tmp: TmpFile = .init();
    defer tmp.deinit();
    const path = tmp.file("app.db");
    const db = try sqlite.Db.init(gpa, io, .{ .path = path, .readers = 2, .busy_timeout_ms = 20 });
    defer db.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var req: dusty.Request = .{ .arena = arena_state.allocator(), .io = io, .parser = undefined, .transport = undefined };
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
    const level = quiet();
    defer testing.log_level = level;
    {
        // A read-only transaction: a snapshot on a reader, while the
        // writer commits.
        var snap = try db.begin(&req, .{ .read_only = true });
        defer snap.deinit();
        try testing.expectEqual(@as(i64, 100), try snap.one(i64, &req, "SELECT balance FROM accounts WHERE id = 1", .{}));
        _ = try db.exec(&req, "UPDATE accounts SET balance = 90 WHERE id = 1", .{});
        try testing.expectEqual(@as(i64, 100), try snap.one(i64, &req, "SELECT balance FROM accounts WHERE id = 1", .{}));
        try testing.expectError(error.Database, snap.exec(&req, "UPDATE accounts SET balance = 1", .{}));
        try snap.commit(&req);
        try testing.expectEqual(@as(i64, 90), try db.one(i64, &req, "SELECT balance FROM accounts WHERE id = 1", .{}));
    }

    const Move = struct {
        fn run(tx: *sqlite.Tx, rq: *dusty.Request, amount: i64, attempts: *u32) !void {
            attempts.* += 1;
            _ = try tx.exec(rq, "UPDATE accounts SET balance = balance - ? WHERE id = 1", .{amount});
            _ = try tx.exec(rq, "UPDATE accounts SET balance = balance + ? WHERE id = 2", .{amount});
        }
    };
    var attempts: u32 = 0;
    try db.transaction(&req, .{}, Move.run, .{ &req, 10, &attempts });
    try testing.expectEqual(@as(i64, 10), try db.one(i64, &req, "SELECT balance FROM accounts WHERE id = 2", .{}));
    // A failure inside rolls all of it back.
    try testing.expectError(error.Database, db.transaction(&req, .{ .retries = 3 }, Move.run, .{ &req, 1000, &attempts }));
    try testing.expectEqual(@as(i64, 80), try db.one(i64, &req, "SELECT balance FROM accounts WHERE id = 1", .{}));
    try testing.expectEqual(@as(u32, 2), attempts);

    // Another process (a raw connection here) holds the write lock: past
    // busy_timeout_ms a call is ServiceUnavailable; transaction() runs
    // again until the lock is gone.
    var other = try sqlite.driver.Db.init(.{ .mode = .{ .File = try arena_state.allocator().dupeSentinel(u8, path, 0) }, .open_flags = .{ .write = true }, .threading_mode = .MultiThread });
    defer other.deinit();
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(other.db, "BEGIN IMMEDIATE", null, null, null));
    try testing.expectError(error.ServiceUnavailable, db.exec(&req, "UPDATE accounts SET balance = 0", .{}));
    try testing.expectEqual(anole_db.Class.unavailable, anole_db.lastError(&req).?.class);
    try testing.expectError(error.ServiceUnavailable, db.transaction(&req, .{}, Move.run, .{ &req, 1, &attempts }));
    // Reads go on meanwhile.
    try testing.expectEqual(@as(i64, 80), try db.one(i64, &req, "SELECT balance FROM accounts WHERE id = 1", .{}));

    const Release = struct {
        fn run(io_: std.Io, conn: *sqlite.driver.Db) !void {
            try io_.sleep(.fromMilliseconds(150), .awake);
            _ = c.sqlite3_exec(conn.db, "COMMIT", null, null, null);
        }
    };
    var release = try io.concurrent(Release.run, .{ io, &other });
    attempts = 0;
    try db.transaction(&req, .{ .retries = 100 }, Move.run, .{ &req, 1, &attempts });
    try release.await(io);
    try testing.expectEqual(@as(i64, 79), try db.one(i64, &req, "SELECT balance FROM accounts WHERE id = 1", .{}));
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
        const db = try sqlite.Db.init(gpa, io, .{ .path = path, .readers = 1 });
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
    const db = try sqlite.Db.init(gpa, testing.io, .{ .path = ":memory:", .statement_cache = 2 });
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
    const db = try sqlite.Db.init(gpa, io, .{ .path = tmp.file("app.db"), .readers = 2 });
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
    db: *sqlite.Db = undefined,

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
    try app.listen("127.0.0.1:0");
    try checking.await(app.io());
}
