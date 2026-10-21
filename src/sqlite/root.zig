//! SQLite, built in (`-Dsqlite`, on in the `web` and `full` profiles): the
//! amalgamation (public domain) compiled by Anole (build/sqlite.zig), opened
//! through xuckless/zig-sqlite (MIT). Nothing to install, no server to run.
//!
//!     const App = struct { notes: *anole.sqlite.Db };
//!     state.notes = try app.sqlite("notes.db"); // or ":memory:"
//!
//!     fn list(app: *App, req: *anole.Request, res: *anole.Response) !void {
//!         const Note = struct { id: i64, title: []const u8, done: bool };
//!         try res.json(try app.notes.all(Note, req, "SELECT id, title, done FROM notes ORDER BY id LIMIT ?", .{50}));
//!     }
//!
//! The calls are `anole.db`'s (see src/db/root.zig): `exec`, `one`,
//! `optional`, `all`, `iterate`, `begin`, `transaction`, `acquire`, `with`;
//! each takes the request (or a `*anole.db.Ctx`) first and leaves its rows
//! in the request's arena.
//!
//! # Where the work runs
//!
//! SQLite has no asynchronous API: a statement reads and writes the file on
//! the thread that steps it. So no statement runs on an executor:
//!
//! - **Writes** go to the database's own writer thread, which owns the one
//!   read-write connection: `exec`, a statement that changes something
//!   (`INSERT ... RETURNING` through `one` too), `.with(.{ .write = true })`,
//!   and transactions. Callers take turns in arrival order, so Anole's own
//!   writers never meet `SQLITE_BUSY`; the coroutine waits, its executor
//!   serves the rest.
//! - **Reads** (`SELECT`, `WITH`, `VALUES`, `PRAGMA`, `EXPLAIN`) run on
//!   `anole.blocking`'s threads over a pool of read-only connections (one
//!   per executor, at most 8), beside the writer: the database is in WAL
//!   mode, so readers never wait for it. A statement that turns out to
//!   write (`WITH ... INSERT`) moves to the writer.
//! - **`:memory:`** is one database for the whole app: everything runs on
//!   the writer's connection, since each in-memory connection would be a
//!   database of its own.
//!
//! `app.sqlite` makes sure the server has a blocking pool; a `Db` opened
//! outside `anole.Server` on a runtime without one reads on the caller's
//! thread.
//!
//! # Cancellation, errors, rows
//!
//! A canceled request (its deadline, an HTTP/2 RST_STREAM, `with(.{
//! .timeout })`) interrupts the statement it is running
//! (`sqlite3_interrupt`), which stops within milliseconds; the call
//! returns `error.Canceled` (`error.GatewayTimeout` for a timeout).
//!
//! A unique or primary-key violation is `error.Conflict` (409), `SQLITE_BUSY`
//! past `busy_timeout_ms` (another process holding the write lock) is
//! `error.ServiceUnavailable` (503), and the rest `error.Database` (500);
//! `lastError(req)` has SQLite's extended code and message.
//!
//! Rows fill a struct by column name (case-insensitive; `AS` renames):
//! integers, floats, `bool`, `[]const u8` (copied into the arena), enums
//! (from their name, or their value), optionals for NULL, `anole.db.Time`
//! (text as SQLite writes it, `unixepoch()` integers, `julianday()` reals),
//! `Blob`, and any other struct or slice from JSON text. A type that is not
//! a struct (`i64`, `[]const u8`) takes the first column:
//! `one(i64, req, "SELECT count(*) FROM notes", .{})`. Parameters are a
//! tuple for `?` (or `?NNN`) in order, of the same types; a `Time` is
//! stored as text in SQLite's own format (`2026-10-21 09:30:00.25`, UTC).
const std = @import("std");
const sqlite = @import("anole_sqlite");
const db = @import("../db/root.zig");
const blocking = @import("../blocking.zig");
const observe = @import("../observe/root.zig");

/// SQLite's C API (sqlite3.h, as built), for what Anole's calls leave out.
pub const c = sqlite.c;
/// xuckless/zig-sqlite, the driver under `Conn.run`: user functions,
/// blobs, backups, virtual tables.
pub const driver = sqlite;

const log = std.log.scoped(.anole);

/// `app.sqlite(options)` and `Db.init`: the file, its connections and
/// statement cache. `app.sqlite("app.db")` is `.{ .path = "app.db" }`.
pub const Options = struct {
    /// A file (created when missing), `":memory:"` for one in-memory
    /// database shared by the whole app, or a `sqlite:` URL of either
    /// (`sqlite:data/app.db`, `sqlite::memory:`).
    path: []const u8,
    /// The `db` label of its metrics and spans. Null: the file's name
    /// (`app.db`), or `memory`.
    name: ?[]const u8 = null,
    /// Read-only connections for reads, used at once from the blocking
    /// pool. Null: one per executor, at most 8. Zero: everything on the
    /// writer. None for `:memory:`.
    readers: ?usize = null,
    /// How long a statement waits for a lock another process holds (a
    /// migration tool, the old process during a restart) before
    /// `error.ServiceUnavailable`.
    busy_timeout_ms: u32 = 5000,
    /// Prepared statements kept per connection, by SQL text.
    statement_cache: usize = 64,
    /// Statements run on every connection as it opens, after Anole's own
    /// (`journal_mode=WAL`, `synchronous=NORMAL`, `busy_timeout`,
    /// `foreign_keys=ON`): `"PRAGMA cache_size = -20000"`.
    pragmas: []const []const u8 = &.{},
    /// What error each class of SQLite error becomes (`anole.db.ErrorMap`).
    errors: db.ErrorMap = .{},
    /// The bounds of the results kept for calls with `.cache`
    /// (`anole.db.QueryOptions`).
    cache: db.CacheOptions = .{},
};

/// A BLOB parameter or column: bytes that are not text.
pub const Blob = struct {
    /// The bytes; in a row, copied into the arena.
    data: []const u8,

    /// For `std.json`: the bytes as a base64 string.
    pub fn jsonStringify(self: Blob, jw: anytype) !void {
        try jw.print("\"{b64}\"", .{self.data});
    }
};

/// What every call fails with: `anole.db.Error`, a cancel, or memory.
pub const CallError = db.Error || error{ Canceled, OutOfMemory };

/// One SQLite database: a writer thread with the read-write connection, and
/// read-only connections for reads. Safe to use from any task.
pub const Db = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    path: [:0]const u8,
    memory: bool,
    error_map: db.ErrorMap,
    cache_size: usize,
    writer: Writer,
    readers: Readers,
    /// Metrics and spans; `start` fills them in.
    observer: db.Observer,
    /// `/readyz`'s check, once `start` has a `Health` for it.
    readiness: db.Readiness,
    /// Connections in use (readers taken, the writer held), for the gauges.
    in_use: std.atomic.Value(i64) = .init(0),
    /// Calls with `.coalesce` or `.cache` (`with`), and `invalidate` for
    /// cached results: `app.notes.cache.invalidate(.{ .tag = "notes" })`.
    cache: db.QueryCache,

    /// Opens the database (the file is created when missing) and its
    /// connections, and starts the writer thread. `io` is the runtime the
    /// calls will come from. Close it with `deinit`.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, options: Options) !*Db {
        const path = stripScheme(options.path);
        const memory = std.mem.eql(u8, path, ":memory:");
        const self = try gpa.create(Db);
        errdefer gpa.destroy(self);
        const path_z = try gpa.dupeSentinel(u8, path, 0);
        errdefer gpa.free(path_z);
        const name = try gpa.dupe(u8, options.name orelse if (memory) "memory" else std.fs.path.basename(path));
        errdefer gpa.free(name);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .name = name,
            .path = path_z,
            .memory = memory,
            .error_map = options.errors,
            .cache_size = options.statement_cache,
            .writer = .{ .conn = undefined, .thread = undefined },
            .readers = .{},
            .observer = .{ .system = .sqlite, .name = name },
            .readiness = .{ .io = io, .context = self, .ping = ping },
            .cache = try .init(gpa, io, .sqlite, name, options.cache),
        };
        errdefer self.cache.deinit();

        // The writer first: it creates the file and turns WAL on, which
        // the read-only connections cannot.
        self.writer.conn = try Connection.open(self, true, options);
        errdefer self.writer.conn.close(gpa);
        const count = if (memory) 0 else options.readers orelse @min(db.executorCount(io), 8);
        self.readers.conns = try gpa.alloc(Connection, count);
        errdefer gpa.free(self.readers.conns);
        self.readers.free = try gpa.alloc(*Connection, count);
        errdefer gpa.free(self.readers.free);
        errdefer for (self.readers.free[0..self.readers.free_len]) |conn| conn.close(gpa);
        for (self.readers.conns) |*conn| {
            conn.* = try Connection.open(self, false, options);
            self.readers.free[self.readers.free_len] = conn;
            self.readers.free_len += 1;
        }
        self.writer.thread = try std.Thread.spawn(.{}, Writer.loop, .{ &self.writer, io });
        return self;
    }

    /// Stops the writer thread and closes every connection. Nothing may be
    /// using the database (no call in flight, no `Tx`, `Rows` or `Conn`).
    pub fn deinit(self: *Db) void {
        // First: a statement still running for the cache holds a connection.
        self.cache.deinit();
        const w = &self.writer;
        w.mutex.lockUncancelable(self.io);
        w.closing = true;
        w.ready.signal(self.io);
        w.mutex.unlock(self.io);
        w.thread.join();
        for (self.readers.conns) |*conn| conn.close(self.gpa);
        self.gpa.free(self.readers.conns);
        self.gpa.free(self.readers.free);
        w.conn.close(self.gpa);
        self.gpa.free(self.name);
        self.gpa.free(self.path);
        self.gpa.destroy(self);
    }

    /// Hooks the database to the app's metrics (`registry`), traces
    /// (`tracer`) and `/readyz` (`health`), each when there is one. Call it
    /// once, before serving (`app.sqlite` does when `run` starts, so the
    /// order of `app.metrics`, `app.tracing` and `app.sqlite` does not
    /// matter).
    pub fn start(self: *Db, registry: ?*observe.metrics.Registry, tracer: ?*observe.trace.Exporter, health: ?*observe.Health) !void {
        if (registry) |r| {
            const m = try db.Metrics.init(r, .sqlite, self.name);
            const total: i64 = @intCast(self.readers.conns.len + 1);
            const in_use = self.in_use.load(.monotonic);
            m.idle.add(total - in_use);
            m.in_use.add(in_use);
            self.observer.metrics = m;
        }
        if (tracer) |t| self.observer.tracer = t;
        if (health) |h| try self.readiness.register(h, self.name);
        try self.cache.observe(registry);
    }

    /// Runs `sql`, one or more statements with no parameters, on the
    /// writer, outside any request: a schema at startup.
    ///
    ///     try db.execScript(
    ///         \\CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL);
    ///         \\CREATE INDEX IF NOT EXISTS notes_title ON notes (title);
    ///     );
    pub fn execScript(self: *Db, sql: []const u8) CallError!void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        var ctx: db.Ctx = .{ .io = self.io, .arena = arena.allocator() };
        _ = try self.exec(&ctx, sql, .{});
    }

    /// The calls below, with `options` (a timeout, `.write`, `.prepare`).
    pub fn with(self: *Db, options: db.QueryOptions) Query {
        return .{ .db = self, .options = options };
    }

    /// Runs `sql` (on the writer) and returns the rows it changed. With no
    /// `args`, `sql` may hold several statements, run in order (a schema).
    pub fn exec(self: *Db, cx: anytype, sql: []const u8, args: anytype) CallError!u64 {
        return self.with(.{}).exec(cx, sql, args);
    }

    /// The first row; none: `error.NotFound` (404).
    pub fn one(self: *Db, comptime T: type, cx: anytype, sql: []const u8, args: anytype) CallError!T {
        return self.with(.{}).one(T, cx, sql, args);
    }

    /// The first row, or null.
    pub fn optional(self: *Db, comptime T: type, cx: anytype, sql: []const u8, args: anytype) CallError!?T {
        return self.with(.{}).optional(T, cx, sql, args);
    }

    /// Every row.
    pub fn all(self: *Db, comptime T: type, cx: anytype, sql: []const u8, args: anytype) CallError![]T {
        return self.with(.{}).all(T, cx, sql, args);
    }

    /// The rows a batch at a time (`next`), holding a connection until
    /// `deinit`.
    pub fn iterate(self: *Db, comptime T: type, cx: anytype, sql: []const u8, args: anytype) CallError!Rows(T) {
        return self.with(.{}).iterate(T, cx, sql, args);
    }

    /// Starts a transaction: on the writer (`BEGIN IMMEDIATE`, so it never
    /// fails halfway for a lock), holding it until `commit`, `rollback` or
    /// `deinit`; with `.read_only`, on a reader, a snapshot that writes do
    /// not disturb. SQLite's transactions are serializable, whatever
    /// `isolation` asks. Inside, use the `Tx`, not the `Db`: a write on the
    /// `Db` would wait for the transaction's own writer.
    ///
    ///     var tx = try app.notes.begin(req, .{});
    ///     defer tx.deinit();
    ///     _ = try tx.exec(req, "UPDATE accounts SET balance = balance - ? WHERE id = ?", .{ amount, from });
    ///     _ = try tx.exec(req, "UPDATE accounts SET balance = balance + ? WHERE id = ?", .{ amount, to });
    ///     try tx.commit(req);
    pub fn begin(self: *Db, cx: anytype, options: db.TxOptions) CallError!Tx {
        const reader = options.read_only and self.readers.conns.len > 0;
        const conn: *Connection = if (reader) try self.acquireReader(cx.io) else blk: {
            try self.lockWriter(cx.io);
            break :blk &self.writer.conn;
        };
        var tx: Tx = .{ .db = self, .io = cx.io, .conn = conn, .on_writer = !reader };
        errdefer tx.release();
        _ = try tx.run(cx, .exec, void, if (reader) "BEGIN" else "BEGIN IMMEDIATE", .{}, .{ .prepare = false });
        return tx;
    }

    /// Runs `func(tx, args...)` in a transaction (see `begin`) and commits
    /// it, or rolls it back if `func` fails. When `func` or the commit
    /// fails with `SQLITE_BUSY` (another process held the database past
    /// `busy_timeout_ms`, or a snapshot went stale), the whole of it runs
    /// again, up to `options.retries` more times. `options.timeout` bounds
    /// all of it.
    ///
    ///     fn move(tx: *anole.sqlite.Tx, req: *anole.Request, from: i64, to: i64) !void { ... }
    ///     try app.notes.transaction(req, .{ .retries = 3 }, move, .{ req, from, to });
    pub fn transaction(self: *Db, cx: anytype, options: db.TxOptions, comptime func: anytype, args: anytype) TxResult(func) {
        const Run = struct {
            fn run(d: *Db, c_: @TypeOf(cx), o: db.TxOptions, a: @TypeOf(args)) TxResult(func) {
                var attempt: u8 = 0;
                while (true) : (attempt += 1) {
                    var tx = d.begin(c_, o) catch |err| {
                        if (attempt < o.retries and retryable(c_, err)) continue;
                        return err;
                    };
                    defer tx.deinit();
                    const result = @call(.auto, func, .{&tx} ++ a) catch |err| {
                        if (attempt < o.retries and retryable(c_, err)) continue;
                        return err;
                    };
                    tx.commit(c_) catch |err| {
                        if (attempt < o.retries and retryable(c_, err)) continue;
                        return err;
                    };
                    return result;
                }
            }
        };
        return unbound(TxResult(func), db.bounded(cx, .sqlite, options.timeout, Run.run, .{ self, cx, options, args }));
    }

    /// The writer connection for the driver's own calls (`Conn.run`), held
    /// until `release`.
    pub fn acquire(self: *Db, cx: anytype) CallError!Conn {
        try self.lockWriter(cx.io);
        return .{ .db = self, .io = cx.io };
    }

    // -----------------------------------------------------------------------
    // Connections

    fn acquireReader(self: *Db, io: std.Io) error{Canceled}!*Connection {
        const r = &self.readers;
        const started: std.Io.Clock.Timestamp = .now(io, .awake);
        try r.mutex.lock(io);
        defer r.mutex.unlock(io);
        if (r.free_len == 0) {
            self.observer.waiting(1);
            defer self.observer.waiting(-1);
            while (r.free_len == 0) try r.changed.wait(io, &r.mutex);
        }
        r.free_len -= 1;
        self.taken(started.durationTo(.now(io, .awake)).raw);
        return r.free[r.free_len];
    }

    fn releaseReader(self: *Db, io: std.Io, conn: *Connection) void {
        const r = &self.readers;
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        r.free[r.free_len] = conn;
        r.free_len += 1;
        r.changed.signal(io);
        self.given();
    }

    /// Takes the writer: one call, transaction or `acquire` at a time.
    fn lockWriter(self: *Db, io: std.Io) error{Canceled}!void {
        const started: std.Io.Clock.Timestamp = .now(io, .awake);
        if (!self.writer.lock.tryLock()) {
            self.observer.waiting(1);
            defer self.observer.waiting(-1);
            try self.writer.lock.lock(io);
        }
        self.taken(started.durationTo(.now(io, .awake)).raw);
    }

    fn unlockWriter(self: *Db, io: std.Io) void {
        self.writer.lock.unlock(io);
        self.given();
    }

    fn taken(self: *Db, waited: std.Io.Duration) void {
        _ = self.in_use.fetchAdd(1, .monotonic);
        self.observer.connections(-1, 1);
        self.observer.acquired(waited);
    }

    fn given(self: *Db) void {
        _ = self.in_use.fetchSub(1, .monotonic);
        self.observer.connections(1, -1);
    }

    /// Runs `func(args...)` on a reader's thread (the blocking pool); a
    /// cancel interrupts the statement `conn` runs.
    fn onReader(io: std.Io, conn: *Connection, comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) blocking.Result(@TypeOf(func)) {
        return blocking.runWith(io, .{ .on_cancel = .{ .context = conn, .call = Connection.interrupt } }, func, args);
    }

    /// Runs `func(args...)` on the writer thread, which the caller holds
    /// (`lockWriter`); a cancel takes the job back before it starts, or
    /// interrupts its statement.
    fn onWriter(self: *Db, io: std.Io, comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) blocking.Result(@TypeOf(func)) {
        const R = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
        const Typed = struct {
            job: Job = .{ .run = run },
            args: @TypeOf(args),
            result: R = undefined,

            fn run(j: *Job) void {
                const t: *@This() = @fieldParentPtr("job", j);
                t.result = @call(.auto, func, t.args);
            }
        };
        var t: Typed = .{ .args = args };
        const w = &self.writer;
        w.mutex.lockUncancelable(io);
        std.debug.assert(w.next == null);
        w.next = &t.job;
        w.ready.signal(io);
        w.mutex.unlock(io);
        t.job.done.wait(io) catch |err| {
            w.mutex.lockUncancelable(io);
            if (w.next == &t.job) {
                // Not started: it never will.
                w.next = null;
                w.mutex.unlock(io);
                return err;
            }
            // Under the lock, so the interrupt cannot reach the next job.
            if (w.running == &t.job) c.sqlite3_interrupt(w.conn.handle.db);
            w.mutex.unlock(io);
            t.job.done.waitUncancelable(io);
            return err;
        };
        return t.result;
    }

    /// The readiness check: a `SELECT 1` within a second.
    fn ping(context: *anyopaque, io: std.Io) bool {
        const self: *Db = @ptrCast(@alignCast(context));
        var buf: [1024]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        var ctx: db.Ctx = .{ .io = io, .arena = fba.allocator() };
        const v = self.with(.{ .timeout = .fromSeconds(1) }).one(i64, &ctx, "SELECT 1", .{}) catch return false;
        return v == 1;
    }
};

/// `bounded`'s result without the deadline's `Timeout`, which it turns
/// into `GatewayTimeout`.
fn unbound(comptime R: type, result: anytype) R {
    return result catch |err| switch (err) {
        error.Timeout => unreachable,
        else => |e| e,
    };
}

/// What `transaction(cx, options, func, args)` returns: `func`'s result,
/// with the calls' errors added.
pub fn TxResult(comptime func: anytype) type {
    const R = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
    return switch (@typeInfo(R)) {
        .error_union => |eu| (eu.error_set || CallError)!eu.payload,
        else => CallError!R,
    };
}

/// Whether `transaction` runs again after `err`: a serialization failure
/// (`SQLITE_BUSY_SNAPSHOT`), or `SQLITE_BUSY` past the busy timeout.
fn retryable(cx: anytype, err: anyerror) bool {
    if (db.retryable(cx, err)) return true;
    if (err != error.ServiceUnavailable) return false;
    const detail = db.lastError(cx) orelse return false;
    const code = std.fmt.parseInt(c_int, detail.code, 10) catch return false;
    return code & 0xff == c.SQLITE_BUSY;
}

/// The calls with options (`Db.with`).
pub const Query = struct {
    db: *Db,
    options: db.QueryOptions,

    /// `Db.exec`, with the options.
    pub fn exec(q: Query, cx: anytype, sql: []const u8, args: anytype) CallError!u64 {
        return q.call(.exec, void, cx, sql, args);
    }

    // The reads go through the cache, which shares them when the options
    // ask (`coalesce`, `cache`) and makes the plain call otherwise.

    /// `Db.one`, with the options (`coalesce` and `cache` apply).
    pub fn one(q: Query, comptime T: type, cx: anytype, sql: []const u8, args: anytype) CallError!T {
        return q.db.cache.read(T, cx, q.options, sql, args, Read(.one, T){ .q = q });
    }

    /// `Db.optional`, with the options (`coalesce` and `cache` apply).
    pub fn optional(q: Query, comptime T: type, cx: anytype, sql: []const u8, args: anytype) CallError!?T {
        return q.db.cache.read(?T, cx, q.options, sql, args, Read(.optional, T){ .q = q });
    }

    /// `Db.all`, with the options (`coalesce` and `cache` apply).
    pub fn all(q: Query, comptime T: type, cx: anytype, sql: []const u8, args: anytype) CallError![]T {
        return q.db.cache.read([]T, cx, q.options, sql, args, Read(.all, T){ .q = q });
    }

    /// A read as `anole.db.QueryCache` makes it: the plain call, with the
    /// caller's context or a shared call's own.
    fn Read(comptime op: Op, comptime T: type) type {
        return struct {
            q: Query,

            pub fn run(r: @This(), cx: anytype, sql: []const u8, args: anytype) CallError!Out(op, T) {
                return r.q.call(op, T, cx, sql, args);
            }
        };
    }

    /// `Db.iterate`. `options.timeout` bounds starting it, not each `next`.
    pub fn iterate(q: Query, comptime T: type, cx: anytype, sql: []const u8, args: anytype) CallError!Rows(T) {
        const Run = struct {
            fn run(q_: Query, c_: @TypeOf(cx), s: []const u8, a: @TypeOf(args)) CallError!Rows(T) {
                return Rows(T).start(q_, c_, s, a);
            }
        };
        const call_ = q.db.observer.start(cx);
        const result = unbound(CallError!Rows(T), db.bounded(cx, .sqlite, q.options.timeout, Run.run, .{ q, cx, sql, args }));
        const kw = operation(sql);
        call_.end(cx, kw.text(), null, if (result) |_| null else |e| e);
        return result;
    }

    fn call(q: Query, comptime op: Op, comptime T: type, cx: anytype, sql: []const u8, args: anytype) CallError!Out(op, T) {
        const Run = struct {
            fn run(q_: Query, c_: @TypeOf(cx), s: []const u8, a: @TypeOf(args)) CallError!Out(op, T) {
                return q_.dispatch(op, T, c_, s, a);
            }
        };
        const call_ = q.db.observer.start(cx);
        const result = unbound(CallError!Out(op, T), db.bounded(cx, .sqlite, q.options.timeout, Run.run, .{ q, cx, sql, args }));
        const kw = operation(sql);
        call_.end(cx, kw.text(), null, if (result) |_| null else |e| e);
        return result;
    }

    /// A reader when the statement reads, else (or when a reader finds it
    /// writes) the writer.
    fn dispatch(q: Query, comptime op: Op, comptime T: type, cx: anytype, sql: []const u8, args: anytype) CallError!Out(op, T) {
        const self = q.db;
        const flags: Flags = .{ .prepare = q.options.prepare };
        if (op != .exec and !q.options.write and self.readers.conns.len > 0 and operation(sql).reads()) {
            const conn = try self.acquireReader(cx.io);
            var failure: Failure = .{};
            var probe = flags;
            probe.reader = true;
            const read = Db.onReader(cx.io, conn, statement(op, T, @TypeOf(args)), .{ self, conn, cx.arena, sql, args, probe, &failure });
            // Back before waiting for the writer, which may be waiting for
            // a reader.
            self.releaseReader(cx.io, conn);
            if (read) |v| {
                return v;
            } else |err| switch (err) {
                error.NeedsWriter => {},
                error.Failed => return failed(self, cx, &failure),
                else => |e| return e,
            }
        }
        try self.lockWriter(cx.io);
        defer self.unlockWriter(cx.io);
        return runOnWriter(self, cx, op, T, sql, args, flags);
    }
};

fn runOnWriter(self: *Db, cx: anytype, comptime op: Op, comptime T: type, sql: []const u8, args: anytype, flags: Flags) CallError!Out(op, T) {
    var failure: Failure = .{};
    return self.onWriter(cx.io, statement(op, T, @TypeOf(args)), .{ self, &self.writer.conn, cx.arena, sql, args, flags, &failure }) catch |err| switch (err) {
        error.NeedsWriter => unreachable,
        error.Failed => failed(self, cx, &failure),
        else => |e| e,
    };
}

fn runOnReader(self: *Db, cx: anytype, conn: *Connection, comptime op: Op, comptime T: type, sql: []const u8, args: anytype, flags: Flags) CallError!Out(op, T) {
    var failure: Failure = .{};
    return Db.onReader(cx.io, conn, statement(op, T, @TypeOf(args)), .{ self, conn, cx.arena, sql, args, flags, &failure }) catch |err| switch (err) {
        error.NeedsWriter => unreachable,
        error.Failed => failed(self, cx, &failure),
        else => |e| e,
    };
}

/// A transaction (`Db.begin`): the calls of `Db`, on its connection.
pub const Tx = struct {
    db: *Db,
    io: std.Io,
    conn: *Connection,
    on_writer: bool,
    /// Committed or rolled back.
    finished: bool = false,

    /// `Db.exec` inside the transaction.
    pub fn exec(tx: *Tx, cx: anytype, sql: []const u8, args: anytype) CallError!u64 {
        return tx.run(cx, .exec, void, sql, args, .{});
    }

    /// `Db.one` inside the transaction.
    pub fn one(tx: *Tx, comptime T: type, cx: anytype, sql: []const u8, args: anytype) CallError!T {
        return tx.run(cx, .one, T, sql, args, .{});
    }

    /// `Db.optional` inside the transaction.
    pub fn optional(tx: *Tx, comptime T: type, cx: anytype, sql: []const u8, args: anytype) CallError!?T {
        return tx.run(cx, .optional, T, sql, args, .{});
    }

    /// `Db.all` inside the transaction.
    pub fn all(tx: *Tx, comptime T: type, cx: anytype, sql: []const u8, args: anytype) CallError![]T {
        return tx.run(cx, .all, T, sql, args, .{});
    }

    /// `Db.iterate` inside the transaction; `deinit` the rows before the
    /// next call on `tx`.
    pub fn iterate(tx: *Tx, comptime T: type, cx: anytype, sql: []const u8, args: anytype) CallError!Rows(T) {
        // Not probed (`owns` is false): never NeedsWriter.
        return Rows(T).startOn(tx.db, cx, tx.conn, tx.on_writer, false, sql, args) catch |err| switch (err) {
            error.NeedsWriter => unreachable,
            else => |e| e,
        };
    }

    /// Commits and gives the connection back; `deinit` after it does
    /// nothing. When it fails, `deinit` rolls back.
    pub fn commit(tx: *Tx, cx: anytype) CallError!void {
        std.debug.assert(!tx.finished);
        _ = try tx.run(cx, .exec, void, "COMMIT", .{}, .{ .prepare = false });
        tx.release();
    }

    /// Rolls back and gives the connection back, failed or not. `deinit`
    /// does it too when neither this nor `commit` ran.
    pub fn rollback(tx: *Tx, cx: anytype) CallError!void {
        std.debug.assert(!tx.finished);
        defer tx.release();
        _ = try tx.run(cx, .exec, void, "ROLLBACK", .{}, .{ .prepare = false });
    }

    /// Rolls back unless committed, and gives the connection back. Not
    /// canceled by the request's cancel.
    pub fn deinit(tx: *Tx) void {
        if (tx.finished) return;
        const was = tx.io.swapCancelProtection(.blocked);
        defer _ = tx.io.swapCancelProtection(was);
        var buf: [512]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        var ctx: db.Ctx = .{ .io = tx.io, .arena = fba.allocator() };
        // Fails when SQLite already rolled back (an interrupted write).
        _ = tx.run(&ctx, .exec, void, "ROLLBACK", .{}, .{ .prepare = false, .quiet = true }) catch {};
        tx.release();
    }

    fn release(tx: *Tx) void {
        tx.finished = true;
        if (tx.on_writer) tx.db.unlockWriter(tx.io) else tx.db.releaseReader(tx.io, tx.conn);
    }

    fn run(tx: *Tx, cx: anytype, comptime op: Op, comptime T: type, sql: []const u8, args: anytype, flags: Flags) CallError!Out(op, T) {
        std.debug.assert(!tx.finished);
        const call_ = tx.db.observer.start(cx);
        const result = if (tx.on_writer)
            runOnWriter(tx.db, cx, op, T, sql, args, flags)
        else
            runOnReader(tx.db, cx, tx.conn, op, T, sql, args, flags);
        const kw = operation(sql);
        call_.end(cx, kw.text(), null, if (result) |_| null else |e| e);
        return result;
    }
};

/// The writer connection, held (`Db.acquire`) for the driver's own calls.
pub const Conn = struct {
    db: *Db,
    io: std.Io,

    /// Runs `func(driver_db, args...)` on the writer thread, with
    /// `driver_db` zig-sqlite's `*Db` on the writer connection: what may
    /// take time must run there, not on the executor.
    pub fn run(self: Conn, comptime func: anytype, args: anytype) blocking.Result(@TypeOf(func)) {
        const Wrap = struct {
            fn call(d: *Db, a: @TypeOf(args)) @typeInfo(@TypeOf(func)).@"fn".return_type.? {
                return @call(.auto, func, .{&d.writer.conn.handle} ++ a);
            }
        };
        return self.db.onWriter(self.io, Wrap.call, .{ self.db, args });
    }

    /// Gives the writer back, for the next call or transaction.
    pub fn release(self: Conn) void {
        self.db.unlockWriter(self.io);
    }
};

/// Rows one batch at a time (`Db.iterate`): `next` until null, then
/// `deinit`, which gives the connection back (the writer, for a write or
/// `:memory:`, which waits for it meanwhile).
pub fn Rows(comptime T: type) type {
    return struct {
        const Self = @This();
        const batch_len = 64;

        db: *Db,
        conn: *Connection,
        io: std.Io,
        arena: std.mem.Allocator,
        on_writer: bool,
        /// Gives the connection back on `deinit` (not inside a `Tx`).
        owns: bool,
        stmt: Stmt,
        columns: Columns(T),
        /// Records a failure on the caller's request.
        fail_ctx: *anyopaque,
        fail_fn: *const fn (*anyopaque, *Db, *const Failure) db.Error,
        batch: []T = &.{},
        pos: usize = 0,
        done: bool = false,
        finished: bool = false,
        columns_ready: bool = false,

        fn start(q: Query, cx: anytype, sql: []const u8, args: anytype) CallError!Self {
            const d = q.db;
            if (!q.options.write and d.readers.conns.len > 0 and operation(sql).reads()) {
                const conn = try d.acquireReader(cx.io);
                if (startOn(d, cx, conn, false, true, sql, args)) |rows| {
                    return rows;
                } else |err| {
                    d.releaseReader(cx.io, conn);
                    if (err != error.NeedsWriter) return @errorCast(err);
                }
            }
            try d.lockWriter(cx.io);
            errdefer d.unlockWriter(cx.io);
            return startOn(d, cx, &d.writer.conn, true, true, sql, args) catch |err| switch (err) {
                error.NeedsWriter => unreachable,
                else => |e| e,
            };
        }

        fn startOn(d: *Db, cx: anytype, conn: *Connection, on_writer: bool, owns: bool, sql: []const u8, args: anytype) (CallError || error{NeedsWriter})!Self {
            const C = @TypeOf(cx);
            const Thunk = struct {
                fn fail(p: *anyopaque, d_: *Db, f: *const Failure) db.Error {
                    return failed(d_, @as(C, @ptrCast(@alignCast(p))), f);
                }
                fn open(rows: *Self, s: []const u8, a: @TypeOf(args), probe: bool, f: *Failure) JobError!void {
                    rows.stmt = rows.conn.prepare(rows.db, s, true, f) catch |err| switch (err) {
                        error.MultipleStatements => return f.ours(.other, "one statement per call (the SQL holds more)", .{}),
                        else => |e| return e,
                    };
                    errdefer rows.stmt.done();
                    if (probe and c.sqlite3_stmt_readonly(rows.stmt.handle) == 0) return error.NeedsWriter;
                    // The rows outlive this call's arguments: SQLite copies them.
                    try bindAll(rows.stmt.handle, rows.arena, a, .transient, f);
                    try rows.fetch(f);
                }
            };
            var rows: Self = .{
                .db = d,
                .conn = conn,
                .io = cx.io,
                .arena = cx.arena,
                .on_writer = on_writer,
                .owns = owns,
                .stmt = undefined,
                .columns = undefined,
                .fail_ctx = @ptrCast(@constCast(cx)),
                .fail_fn = Thunk.fail,
            };
            var failure: Failure = .{};
            const probe = !on_writer and owns;
            const opened = if (on_writer)
                d.onWriter(cx.io, Thunk.open, .{ &rows, sql, args, probe, &failure })
            else
                Db.onReader(cx.io, conn, Thunk.open, .{ &rows, sql, args, probe, &failure });
            opened catch |err| switch (err) {
                error.Failed => return failed(d, cx, &failure),
                else => |e| return e,
            };
            return rows;
        }

        /// The next row; null after the last.
        pub fn next(self: *Self) CallError!?T {
            std.debug.assert(!self.finished);
            if (self.pos == self.batch.len) {
                if (self.done) return null;
                var failure: Failure = .{};
                const fetched = if (self.on_writer)
                    self.db.onWriter(self.io, fetchJob, .{ self, &failure })
                else
                    Db.onReader(self.io, self.conn, fetchJob, .{ self, &failure });
                fetched catch |err| switch (err) {
                    error.Failed => return self.fail_fn(self.fail_ctx, self.db, &failure),
                    error.NeedsWriter => unreachable,
                    else => |e| return e,
                };
                if (self.batch.len == 0) return null;
            }
            defer self.pos += 1;
            return self.batch[self.pos];
        }

        /// Ends the statement and gives the connection back.
        pub fn deinit(self: *Self) void {
            if (self.finished) return;
            self.finished = true;
            // Resetting ends the read; no I/O to speak of.
            self.stmt.done();
            if (!self.owns) return;
            if (self.on_writer) self.db.unlockWriter(self.io) else self.db.releaseReader(self.io, self.conn);
        }

        fn fetchJob(self: *Self, f: *Failure) JobError!void {
            return self.fetch(f);
        }

        /// Steps up to a batch of rows into the arena.
        fn fetch(self: *Self, f: *Failure) JobError!void {
            const out = try self.arena.alloc(T, batch_len);
            var n: usize = 0;
            while (n < batch_len) {
                const rc = c.sqlite3_step(self.stmt.handle);
                if (rc == c.SQLITE_DONE) {
                    self.done = true;
                    break;
                }
                if (rc != c.SQLITE_ROW) return f.fromStep(self.conn, rc);
                if (!self.columns_ready) {
                    self.columns = try Columns(T).init(self.stmt.handle);
                    self.columns_ready = true;
                }
                out[n] = try decodeRow(T, self.stmt.handle, &self.columns, self.arena, f);
                n += 1;
            }
            self.batch = out[0..n];
            self.pos = 0;
        }
    };
}

// ---------------------------------------------------------------------------
// The writer thread

const Job = struct {
    run: *const fn (*Job) void,
    done: std.Io.Event = .unset,
};

const Writer = struct {
    conn: Connection,
    thread: std.Thread,
    /// Held by a writing call, a transaction or an `acquire`, in arrival
    /// order; the holder alone hands the thread jobs.
    lock: std.Io.Mutex = .init,
    /// Guards the fields below.
    mutex: std.Io.Mutex = .init,
    ready: std.Io.Condition = .init,
    /// The job handed over and not yet started.
    next: ?*Job = null,
    /// The job running: a cancel may interrupt it.
    running: ?*Job = null,
    closing: bool = false,

    /// The thread: runs each job handed over, until `Db.deinit`.
    fn loop(w: *Writer, io: std.Io) void {
        while (true) {
            w.mutex.lockUncancelable(io);
            while (w.next == null and !w.closing) w.ready.waitUncancelable(io, &w.mutex);
            const job = w.next orelse {
                w.mutex.unlock(io);
                return;
            };
            w.next = null;
            w.running = job;
            w.mutex.unlock(io);
            job.run(job);
            w.mutex.lockUncancelable(io);
            w.running = null;
            w.mutex.unlock(io);
            job.done.set(io);
        }
    }
};

const Readers = struct {
    conns: []Connection = &.{},
    /// The connections not taken, `free[0..free_len]`.
    free: []*Connection = &.{},
    free_len: usize = 0,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
};

// ---------------------------------------------------------------------------
// Connections and statements

/// One SQLite connection and its prepared statements. Used by one thread at
/// a time: the writer thread, or whichever pool thread runs a reader's job.
const Connection = struct {
    handle: sqlite.Db,
    cache: std.StringHashMapUnmanaged(Cached) = .empty,
    tick: u64 = 0,

    const Cached = struct { stmt: *c.sqlite3_stmt, used: u64 };

    fn open(d: *Db, writer: bool, options: Options) !Connection {
        var diags: sqlite.Diagnostics = .{};
        var handle = sqlite.Db.init(.{
            .mode = if (d.memory) @as(sqlite.Db.Mode, .Memory) else .{ .File = d.path },
            .open_flags = if (writer) .{ .write = true, .create = true } else .{},
            .threading_mode = .MultiThread,
            .diags = &diags,
        }) catch |err| {
            log.err("sqlite: cannot open \"{s}\"{s}: {t} {s}", .{ d.path, if (writer) "" else " to read", err, if (diags.err) |e| e.message else "" });
            return err;
        };
        errdefer handle.deinit();
        var conn: Connection = .{ .handle = handle };
        var buf: [64]u8 = undefined;
        const busy = std.mem.printSentinel(&buf, "PRAGMA busy_timeout = {d}", .{options.busy_timeout_ms}, 0) catch unreachable;
        try conn.setup(busy);
        if (!d.memory) {
            // Persistent in the file: the writer sets it once.
            if (writer) try conn.setup("PRAGMA journal_mode = WAL");
            try conn.setup("PRAGMA synchronous = NORMAL");
        }
        try conn.setup("PRAGMA foreign_keys = ON");
        for (options.pragmas) |p| {
            const z = try d.gpa.dupeSentinel(u8, p, 0);
            defer d.gpa.free(z);
            try conn.setup(z);
        }
        return conn;
    }

    fn setup(conn: *Connection, sql: [:0]const u8) !void {
        const rc = c.sqlite3_exec(conn.handle.db, sql.ptr, null, null, null);
        if (rc != c.SQLITE_OK) {
            log.err("sqlite: \"{s}\" failed: {s}", .{ sql, std.mem.span(c.sqlite3_errmsg(conn.handle.db)) });
            return error.SqliteSetupFailed;
        }
    }

    fn close(conn: *Connection, gpa: std.mem.Allocator) void {
        var it = conn.cache.iterator();
        while (it.next()) |e| {
            _ = c.sqlite3_finalize(e.value_ptr.stmt);
            gpa.free(e.key_ptr.*);
        }
        conn.cache.deinit(gpa);
        _ = c.sqlite3_close_v2(conn.handle.db);
    }

    /// `blocking.OnCancel`: stops the statement running on the connection.
    fn interrupt(context: ?*anyopaque) void {
        const conn: *Connection = @ptrCast(@alignCast(context.?));
        c.sqlite3_interrupt(conn.handle.db);
    }

    /// `sql` prepared, from the cache when `cache` (and kept there).
    fn prepare(conn: *Connection, d: *Db, sql: []const u8, cache: bool, f: *Failure) PrepareError!Stmt {
        const keep = cache and d.cache_size > 0;
        if (keep) if (conn.cache.getPtr(sql)) |e| {
            conn.tick += 1;
            e.used = conn.tick;
            return .{ .handle = e.stmt, .cached = true };
        };
        var stmt: ?*c.sqlite3_stmt = null;
        var tail: [*c]const u8 = null;
        const flags: c_uint = if (keep) c.SQLITE_PREPARE_PERSISTENT else 0;
        const rc = c.sqlite3_prepare_v3(conn.handle.db, sql.ptr, @intCast(sql.len), flags, &stmt, &tail);
        if (rc != c.SQLITE_OK) return f.fromStep(conn, rc);
        const handle = stmt orelse return f.ours(.other, "the SQL holds no statement", .{});
        errdefer _ = c.sqlite3_finalize(handle);
        const rest = sql[@intFromPtr(tail) - @intFromPtr(sql.ptr) ..];
        if (skipBlank(rest, 0) < rest.len) return error.MultipleStatements;
        if (keep) {
            if (conn.cache.count() >= d.cache_size) conn.evict(d.gpa);
            const key = try d.gpa.dupe(u8, sql);
            errdefer d.gpa.free(key);
            conn.tick += 1;
            try conn.cache.put(d.gpa, key, .{ .stmt = handle, .used = conn.tick });
        }
        return .{ .handle = handle, .cached = keep };
    }

    /// Drops the statement used longest ago.
    fn evict(conn: *Connection, gpa: std.mem.Allocator) void {
        var oldest: ?std.StringHashMapUnmanaged(Cached).Entry = null;
        var it = conn.cache.iterator();
        while (it.next()) |e| {
            if (oldest == null or e.value_ptr.used < oldest.?.value_ptr.used) oldest = e;
        }
        const e = oldest orelse return;
        const key = e.key_ptr.*;
        _ = c.sqlite3_finalize(e.value_ptr.stmt);
        conn.cache.removeByPtr(e.key_ptr);
        gpa.free(key);
    }
};

const Stmt = struct {
    handle: *c.sqlite3_stmt,
    cached: bool,

    /// Done with it: reset for the next use, or finalized.
    fn done(self: Stmt) void {
        if (self.cached) {
            _ = c.sqlite3_reset(self.handle);
            _ = c.sqlite3_clear_bindings(self.handle);
        } else {
            _ = c.sqlite3_finalize(self.handle);
        }
    }
};

// ---------------------------------------------------------------------------
// Jobs: what runs on the writer thread or a reader's pool thread

const Op = enum { exec, one, optional, all };

fn Out(comptime op: Op, comptime T: type) type {
    return switch (op) {
        .exec => u64,
        .one => T,
        .optional => ?T,
        .all => []T,
    };
}

const Flags = struct {
    /// Keep the prepared statement (`QueryOptions.prepare`).
    prepare: bool = true,
    /// On a reader: give up with `NeedsWriter` if the statement writes.
    reader: bool = false,
    /// A failure is not logged (a rollback that finds nothing to roll back).
    quiet: bool = false,
};

/// What a job fails with. `Failed` carries a `Failure`, which the caller
/// turns into `anole.db`'s error on its own task.
const JobError = error{ Failed, NeedsWriter, NotFound, MissingColumn, Canceled, OutOfMemory };

/// What preparing fails with: `MultipleStatements` when the SQL holds more
/// than one, which only `exec` takes.
const PrepareError = error{ Failed, MultipleStatements, Canceled, OutOfMemory };

/// The job for one statement: prepare, bind, step, decode into `arena`.
fn statement(comptime op: Op, comptime T: type, comptime Args: type) fn (*Db, *Connection, std.mem.Allocator, []const u8, Args, Flags, *Failure) JobError!Out(op, T) {
    return struct {
        fn run(d: *Db, conn: *Connection, arena: std.mem.Allocator, sql: []const u8, args: Args, flags: Flags, f: *Failure) JobError!Out(op, T) {
            f.quiet = flags.quiet;
            const stmt = conn.prepare(d, sql, flags.prepare, f) catch |err| switch (err) {
                error.MultipleStatements => {
                    if (comptime op == .exec and @typeInfo(Args).@"struct".field_names.len == 0) return runScript(conn, sql, f);
                    return f.ours(.other, "one statement per call (the SQL holds more); exec runs several when given no arguments", .{});
                },
                else => |e| return e,
            };
            defer stmt.done();
            const h = stmt.handle;
            if (flags.reader and c.sqlite3_stmt_readonly(h) == 0) return error.NeedsWriter;
            try bindAll(h, arena, args, .static, f);
            switch (op) {
                .exec => {
                    const before = c.sqlite3_total_changes64(conn.handle.db);
                    while (true) {
                        const rc = c.sqlite3_step(h);
                        if (rc == c.SQLITE_DONE) break;
                        if (rc != c.SQLITE_ROW) return f.fromStep(conn, rc);
                    }
                    if (c.sqlite3_total_changes64(conn.handle.db) == before) return 0;
                    return @intCast(c.sqlite3_changes64(conn.handle.db));
                },
                .one, .optional => {
                    const rc = c.sqlite3_step(h);
                    if (rc == c.SQLITE_DONE) return if (op == .one) error.NotFound else null;
                    if (rc != c.SQLITE_ROW) return f.fromStep(conn, rc);
                    var columns: Columns(T) = try .init(h);
                    const row = try decodeRow(T, h, &columns, arena, f);
                    // A write with RETURNING completes on its last step.
                    while (true) {
                        const more = c.sqlite3_step(h);
                        if (more == c.SQLITE_DONE) break;
                        if (more != c.SQLITE_ROW) return f.fromStep(conn, more);
                        if (c.sqlite3_stmt_readonly(h) != 0) break;
                    }
                    return row;
                },
                .all => {
                    var rows: std.ArrayList(T) = .empty;
                    var columns: Columns(T) = undefined;
                    while (true) {
                        const rc = c.sqlite3_step(h);
                        if (rc == c.SQLITE_DONE) break;
                        if (rc != c.SQLITE_ROW) return f.fromStep(conn, rc);
                        if (rows.items.len == 0) columns = try .init(h);
                        try rows.append(arena, try decodeRow(T, h, &columns, arena, f));
                    }
                    return rows.toOwnedSlice(arena);
                },
            }
        }
    }.run;
}

/// Several statements with no parameters, in order (a schema): `exec`.
fn runScript(conn: *Connection, sql: []const u8, f: *Failure) JobError!u64 {
    var rest = sql;
    var changed: u64 = 0;
    while (rest.len > 0) {
        var stmt: ?*c.sqlite3_stmt = null;
        var tail: [*c]const u8 = null;
        const rc = c.sqlite3_prepare_v2(conn.handle.db, rest.ptr, @intCast(rest.len), &stmt, &tail);
        if (rc != c.SQLITE_OK) return f.fromStep(conn, rc);
        rest = rest[@intFromPtr(tail) - @intFromPtr(rest.ptr) ..];
        const h = stmt orelse break;
        defer _ = c.sqlite3_finalize(h);
        const before = c.sqlite3_total_changes64(conn.handle.db);
        while (true) {
            const step = c.sqlite3_step(h);
            if (step == c.SQLITE_DONE) break;
            if (step != c.SQLITE_ROW) return f.fromStep(conn, step);
        }
        if (c.sqlite3_total_changes64(conn.handle.db) != before) changed += @intCast(c.sqlite3_changes64(conn.handle.db));
    }
    return changed;
}

// ---------------------------------------------------------------------------
// Errors

/// A failure inside a job, copied out of the connection there: SQLite's
/// message belongs to the connection, which the next call reuses.
const Failure = struct {
    /// SQLite's extended result code; 0 for a failure of Anole's own.
    code: c_int = 0,
    class: db.Class = .other,
    buf: [512]u8 = undefined,
    len: usize = 0,
    quiet: bool = false,

    fn fromStep(f: *Failure, conn: *Connection, rc: c_int) error{ Failed, Canceled } {
        if (rc == c.SQLITE_INTERRUPT) return error.Canceled;
        f.code = c.sqlite3_extended_errcode(conn.handle.db);
        if (f.code == c.SQLITE_OK) f.code = rc;
        f.class = classify(f.code);
        const msg = std.mem.span(c.sqlite3_errmsg(conn.handle.db));
        f.len = @min(msg.len, f.buf.len);
        @memcpy(f.buf[0..f.len], msg[0..f.len]);
        return error.Failed;
    }

    fn ours(f: *Failure, class: db.Class, comptime fmt: []const u8, args: anytype) error{Failed} {
        f.code = 0;
        f.class = class;
        f.len = (std.fmt.bufPrint(&f.buf, fmt, args) catch @as([]u8, &f.buf)).len;
        return error.Failed;
    }

    fn message(f: *const Failure) []const u8 {
        return f.buf[0..f.len];
    }
};

/// SQLite's extended result code, as `anole.db` classes it.
fn classify(code: c_int) db.Class {
    return switch (code) {
        c.SQLITE_CONSTRAINT_UNIQUE, c.SQLITE_CONSTRAINT_PRIMARYKEY, c.SQLITE_CONSTRAINT_ROWID => .unique,
        c.SQLITE_CONSTRAINT_FOREIGNKEY => .foreign_key,
        c.SQLITE_CONSTRAINT_NOTNULL => .not_null,
        c.SQLITE_CONSTRAINT_CHECK => .check,
        c.SQLITE_BUSY_SNAPSHOT => .serialization,
        else => switch (code & 0xff) {
            c.SQLITE_BUSY, c.SQLITE_LOCKED => .unavailable,
            else => .other,
        },
    };
}

/// Records `f` on the caller's request and returns its error.
fn failed(d: *Db, cx: anytype, f: *const Failure) db.Error {
    var code_buf: [16]u8 = undefined;
    const code = if (f.code != 0) std.fmt.bufPrint(&code_buf, "{d}", .{f.code}) catch "" else "";
    var detail: db.ErrorDetail = .{ .system = .sqlite, .class = f.class, .code = code, .message = f.message() };
    // "UNIQUE constraint failed: users.email", "CHECK constraint failed: positive".
    if (std.mem.indexOf(u8, detail.message, "constraint failed: ")) |at| {
        const what = detail.message[at + "constraint failed: ".len ..];
        detail.constraint = what;
        if (f.class == .unique or f.class == .not_null) {
            if (std.mem.indexOfScalar(u8, what, '.')) |dot| detail.table = what[0..dot];
        }
    }
    if (f.quiet) return d.error_map.errorFor(f.class);
    return db.fail(cx, d.error_map, detail);
}

// ---------------------------------------------------------------------------
// Parameters

const Lifetime = enum {
    /// The value outlives the statement's use: no copy.
    static,
    /// SQLite copies it.
    transient,
};

/// Binds a tuple in order, or a struct by name (`:name`, `@name` or
/// `$name` in the SQL).
fn bindAll(stmt: *c.sqlite3_stmt, arena: std.mem.Allocator, args: anytype, lifetime: Lifetime, f: *Failure) JobError!void {
    const info = @typeInfo(@TypeOf(args)).@"struct";
    const want = c.sqlite3_bind_parameter_count(stmt);
    if (want != info.field_names.len) return f.ours(.other, "the statement takes {d} parameters, {d} given", .{ want, info.field_names.len });
    inline for (info.field_names, 0..) |name, i| {
        const index: c_int = if (info.is_tuple) @intCast(i + 1) else blk: {
            inline for (.{ ":", "@", "$" }) |prefix| {
                const at = c.sqlite3_bind_parameter_index(stmt, prefix ++ name);
                if (at > 0) break :blk at;
            }
            return f.ours(.other, "the statement has no parameter :" ++ name, .{});
        };
        try bind(stmt, index, @field(args, name), arena, lifetime, f);
    }
}

fn bind(stmt: *c.sqlite3_stmt, index: c_int, value: anytype, arena: std.mem.Allocator, lifetime: Lifetime, f: *Failure) JobError!void {
    const V = @TypeOf(value);
    const destructor = if (lifetime == .static) c.SQLITE_STATIC else c.sqliteTransientAsDestructor();
    const rc: c_int = switch (@typeInfo(V)) {
        .null => c.sqlite3_bind_null(stmt, index),
        .optional => if (value) |v| return bind(stmt, index, v, arena, lifetime, f) else c.sqlite3_bind_null(stmt, index),
        .comptime_int => c.sqlite3_bind_int64(stmt, index, @as(i64, value)),
        .int => c.sqlite3_bind_int64(stmt, index, std.math.cast(i64, value) orelse
            return f.ours(.other, "parameter {d}: {d} does not fit SQLite's 64-bit integer", .{ index, value })),
        .comptime_float => c.sqlite3_bind_double(stmt, index, @as(f64, value)),
        .float => c.sqlite3_bind_double(stmt, index, @floatCast(value)),
        .bool => c.sqlite3_bind_int64(stmt, index, @intFromBool(value)),
        .enum_literal, .@"enum" => c.sqlite3_bind_text(stmt, index, @tagName(value).ptr, @intCast(@tagName(value).len), c.SQLITE_STATIC),
        else => blk: {
            if (V == db.Time) {
                const text = try formatTime(arena, value);
                break :blk c.sqlite3_bind_text(stmt, index, text.ptr, @intCast(text.len), destructor);
            }
            if (V == Blob) break :blk c.sqlite3_bind_blob64(stmt, index, value.data.ptr, value.data.len, destructor);
            if (comptime isString(V)) {
                const s: []const u8 = value;
                break :blk c.sqlite3_bind_text64(stmt, index, s.ptr, s.len, destructor, c.SQLITE_UTF8);
            }
            // Anything else as JSON text.
            const text = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(value, .{})});
            break :blk c.sqlite3_bind_text64(stmt, index, text.ptr, text.len, destructor, c.SQLITE_UTF8);
        },
    };
    if (rc != c.SQLITE_OK) return f.ours(.other, "parameter {d}: {s}", .{ index, std.mem.span(c.sqlite3_errstr(rc)) });
}

/// Whether `V` coerces to `[]const u8`: slices of bytes, and pointers to
/// arrays of them (string literals).
fn isString(comptime V: type) bool {
    return switch (@typeInfo(V)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| a.child == u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

/// SQLite's own timestamp text, in UTC: `2026-10-21 09:30:00`, with the
/// fraction when there is one (`.25`); it sorts as time does and SQLite's
/// date functions read it.
fn formatTime(arena: std.mem.Allocator, t: db.Time) error{OutOfMemory}![]const u8 {
    var buf: [40]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{f}", .{t}) catch unreachable;
    // RFC 3339 `...T...Z`, to SQLite's `... ...`.
    const out = try arena.dupe(u8, text[0 .. text.len - 1]);
    if (std.mem.indexOfScalar(u8, out, 'T')) |at| out[at] = ' ';
    return out;
}

// ---------------------------------------------------------------------------
// Rows

/// Whether `T` is a row filled by column name, or one value from the first
/// column.
fn isRow(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| !s.is_tuple and T != db.Time and T != Blob,
        else => false,
    };
}

/// Each field's column (for a row struct), worked out from the statement's
/// column names once per call.
fn Columns(comptime T: type) type {
    const n = if (isRow(T)) @typeInfo(T).@"struct".field_names.len else 0;
    return struct {
        index: [n]c_int,

        fn init(stmt: *c.sqlite3_stmt) error{MissingColumn}!@This() {
            var self: @This() = .{ .index = @splat(-1) };
            if (comptime !isRow(T)) return self;
            const count = c.sqlite3_column_count(stmt);
            const info = @typeInfo(T).@"struct";
            inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, F, attrs, i| {
                var col: c_int = 0;
                while (col < count) : (col += 1) {
                    const col_name = c.sqlite3_column_name(stmt, col);
                    if (col_name != null and std.ascii.eqlIgnoreCase(std.mem.span(col_name), name)) {
                        self.index[i] = col;
                        break;
                    }
                }
                if (self.index[i] < 0 and attrs.defaultValue(F) == null and @typeInfo(F) != .optional) {
                    log.warn("sqlite: the result has no column \"{s}\" for {s}.{s}, which has no default", .{ name, @typeName(T), name });
                    return error.MissingColumn;
                }
            }
            return self;
        }
    };
}

fn decodeRow(comptime T: type, stmt: *c.sqlite3_stmt, columns: *const Columns(T), arena: std.mem.Allocator, f: *Failure) JobError!T {
    if (comptime !isRow(T)) {
        if (c.sqlite3_column_count(stmt) < 1) return f.ours(.other, "the statement returns no column", .{});
        return decodeValue(T, stmt, 0, arena, "(first column)", f);
    }
    var out: T = undefined;
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, F, attrs, i| {
        const col = columns.index[i];
        if (col < 0) {
            // `Columns.init` refused a field with neither.
            if (comptime attrs.defaultValue(F)) |d| {
                @field(out, name) = d;
            } else if (@typeInfo(F) == .optional) {
                @field(out, name) = null;
            } else unreachable;
        } else {
            @field(out, name) = try decodeValue(F, stmt, col, arena, name, f);
        }
    }
    return out;
}

fn decodeValue(comptime F: type, stmt: *c.sqlite3_stmt, col: c_int, arena: std.mem.Allocator, field: []const u8, f: *Failure) JobError!F {
    const kind = c.sqlite3_column_type(stmt, col);
    if (@typeInfo(F) == .optional) {
        if (kind == c.SQLITE_NULL) return null;
        return try decodeValue(@typeInfo(F).optional.child, stmt, col, arena, field, f);
    }
    if (kind == c.SQLITE_NULL) return f.ours(.other, "column \"{s}\" is NULL, but {s} is not optional", .{ field, @typeName(F) });
    switch (@typeInfo(F)) {
        .int => {
            const v = c.sqlite3_column_int64(stmt, col);
            return std.math.cast(F, v) orelse return f.ours(.other, "column \"{s}\": {d} does not fit {s}", .{ field, v, @typeName(F) });
        },
        .float => return @floatCast(c.sqlite3_column_double(stmt, col)),
        .bool => return c.sqlite3_column_int64(stmt, col) != 0,
        .@"enum" => {
            if (kind == c.SQLITE_INTEGER) {
                const v = c.sqlite3_column_int64(stmt, col);
                return std.enums.fromInt(F, v) orelse return f.ours(.other, "column \"{s}\": {d} is no {s}", .{ field, v, @typeName(F) });
            }
            const text = columnBytes(stmt, col, kind);
            return std.meta.stringToEnum(F, text) orelse return f.ours(.other, "column \"{s}\": \"{s}\" is no {s}", .{ field, text, @typeName(F) });
        },
        else => {},
    }
    if (F == db.Time) {
        switch (kind) {
            c.SQLITE_INTEGER => return db.Time.fromSeconds(c.sqlite3_column_int64(stmt, col)),
            // A Julian day number (`julianday()`), to the millisecond as
            // SQLite keeps it.
            c.SQLITE_FLOAT => return db.Time.fromMillis(@intFromFloat(@round((c.sqlite3_column_double(stmt, col) - 2440587.5) * 86400e3))),
            else => {
                const text = columnBytes(stmt, col, kind);
                return db.Time.parse(text) catch return f.ours(.other, "column \"{s}\": \"{s}\" is not a time", .{ field, text });
            },
        }
    }
    if (F == Blob) return .{ .data = try arena.dupe(u8, columnBytes(stmt, col, kind)) };
    if (F == []const u8 or F == []u8) return try arena.dupe(u8, columnBytes(stmt, col, kind));
    if (F == [:0]const u8 or F == [:0]u8) return try arena.dupeSentinel(u8, columnBytes(stmt, col, kind), 0);
    switch (@typeInfo(F)) {
        .@"struct", .pointer, .array, .@"union" => {
            // JSON text (`json_object(...)`, a column of JSON).
            const text = columnBytes(stmt, col, kind);
            return std.json.parseFromSliceLeaky(F, arena, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return f.ours(.other, "column \"{s}\": not JSON for {s} ({t})", .{ field, @typeName(F), err });
            };
        },
        else => @compileError("anole.sqlite: cannot read a column into " ++ @typeName(F)),
    }
}

/// The column's bytes: text, or a blob's. Valid until the next step.
fn columnBytes(stmt: *c.sqlite3_stmt, col: c_int, kind: c_int) []const u8 {
    const ptr: ?[*]const u8 = if (kind == c.SQLITE_BLOB)
        @ptrCast(c.sqlite3_column_blob(stmt, col))
    else
        @ptrCast(c.sqlite3_column_text(stmt, col));
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
    return if (ptr) |p| p[0..len] else "";
}

// ---------------------------------------------------------------------------
// SQL text

/// A statement's first keyword: its span name, and where it runs.
const Keyword = struct {
    buf: [16]u8 = undefined,
    len: usize = 0,

    fn text(self: *const Keyword) []const u8 {
        return self.buf[0..self.len];
    }

    /// A read: a reader may run it (and moves it to the writer if it
    /// writes after all).
    fn reads(self: Keyword) bool {
        const word = self.buf[0..self.len];
        for ([_][]const u8{ "SELECT", "WITH", "VALUES", "PRAGMA", "EXPLAIN" }) |k| {
            if (std.mem.eql(u8, word, k)) return true;
        }
        return false;
    }
};

/// The first keyword of `sql`, upper-cased, past blanks and comments.
fn operation(sql: []const u8) Keyword {
    var i = skipBlank(sql, 0);
    while (i < sql.len and sql[i] == '(') i = skipBlank(sql, i + 1);
    var k: Keyword = .{};
    while (i < sql.len and k.len < k.buf.len and std.ascii.isAlphabetic(sql[i])) : (i += 1) {
        k.buf[k.len] = std.ascii.toUpper(sql[i]);
        k.len += 1;
    }
    return k;
}

/// Where the next token of `sql` from `i` starts, past blanks, comments and
/// semicolons; `sql.len` when there is none.
fn skipBlank(sql: []const u8, start: usize) usize {
    var i = start;
    while (i < sql.len) {
        if (std.ascii.isWhitespace(sql[i]) or sql[i] == ';') {
            i += 1;
        } else if (std.mem.startsWith(u8, sql[i..], "--")) {
            i = std.mem.indexOfScalarPos(u8, sql, i, '\n') orelse sql.len;
        } else if (std.mem.startsWith(u8, sql[i..], "/*")) {
            i = if (std.mem.indexOfPos(u8, sql, i + 2, "*/")) |end| end + 2 else sql.len;
        } else break;
    }
    return i;
}

/// `path` without a `sqlite:` or `sqlite://` scheme.
fn stripScheme(path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, "sqlite://")) return path["sqlite://".len..];
    if (std.mem.startsWith(u8, path, "sqlite:")) return path["sqlite:".len..];
    return path;
}

test {
    _ = @import("sqlite_test.zig");
}
