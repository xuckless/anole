//! What the database connectors share (`anole.pg`, `anole.sqlite`,
//! `anole.mongodb`, `anole.redis`): the calling convention, a pool per
//! executor, the error set and its HTTP statuses, timestamps, connection
//! URLs, and the health, metrics and tracing hooks.
//!
//! A connector is a handle in the App state; every call takes the request
//! first and returns rows allocated in the request's arena:
//!
//!     const posts = try app.db.all(Post, req, "SELECT id, body FROM posts LIMIT $1", .{limit});
//!     const post = try app.db.one(Post, req, "SELECT id, body FROM posts WHERE id = $1", .{id}); // none: 404
//!
//! # The contract every connector keeps
//!
//! The first argument after the handle, `c`, is the request (`*anole.Request`)
//! or, outside a handler, a `*Ctx`: both carry `io` (a wait suspends the
//! calling coroutine) and `arena` (what the call returns lives as long as
//! it does; nothing to free). Connectors take it as `anytype`.
//!
//! SQL connectors have these verbs, with these meanings (MongoDB keeps the
//! ones that apply, under its own command names):
//!
//!     exec(c, sql, args) !u64                      rows affected
//!     one(T, c, sql, args) !T                      the first row; none: error.NotFound
//!     optional(T, c, sql, args) !?T                the first row, or null
//!     all(T, c, sql, args) ![]T                    every row
//!     iterate(T, c, sql, args) !Rows(T)            rows one at a time (`next() !?T`,
//!                                                  `deinit()` gives the connection back)
//!     begin(c, TxOptions) !Tx                      `Tx` has the verbs above, `commit`,
//!                                                  `rollback`, and `deinit` (rolls back
//!                                                  unless committed)
//!     transaction(c, TxOptions, func, args)        `func(*Tx, args...)` in a transaction,
//!                                                  committed when it returns, retried
//!                                                  `TxOptions.retries` times while
//!                                                  `retryable` says so
//!     acquire(c) !Conn                             a connection of the driver's own,
//!                                                  given back with `release`
//!     with(QueryOptions) Query                     the same verbs, with options:
//!                                                  `app.db.with(.{ .timeout = .fromSeconds(2) }).all(...)`
//!
//! `args` is a tuple of parameters (`.{ id, name }`). `T` is a struct whose
//! fields take the columns by name: optionals for NULL, `[]const u8` copied
//! into the arena, `Time` for timestamps; a field the result lacks keeps
//! its default, or is `error.MissingColumn`.
//!
//! Errors: a server error goes through `fail`, which keeps its detail for
//! `lastError(c)` and returns one of `Error`, which the server turns into a
//! status (`NotFound` 404, `Conflict` 409, `ServiceUnavailable` 503,
//! `GatewayTimeout` 504, `Database` 500; `ErrorMap` moves the classes
//! around). The detail never reaches the client.
//!
//! Cancellation: a request's deadline or an HTTP/2 RST_STREAM cancels the
//! handler's task, so a waiting call returns `error.Canceled`; the
//! connector then leaves nothing behind (the connection closed or reset,
//! the server told to stop). `QueryOptions.timeout` does the same through
//! `bounded`.
//!
//! Pools: `PerExecutor(Pool)` keeps one per executor, so a call never
//! waits on another executor's connections.
//!
//! Sharing, opt-in per call: `QueryOptions.coalesce` and
//! `QueryOptions.cache`, built once in `QueryCache`, which a connector's
//! `one`, `optional` and `all` go through. A call without them is the
//! plain call.
//!
//! Observability: each handle keeps an `Observer` (metrics when the app
//! has a registry, a client span per call in a traced request) and calls
//! `start`/`end` around every round trip, and its pools report through
//! it; `Readiness` puts a cached ping behind `/readyz`.
const std = @import("std");
const dusty = @import("dusty");
const placement = dusty.placement;

/// A point in time, microseconds since the Unix epoch in UTC: what the
/// connectors read timestamp columns into and bind as parameters. In JSON
/// it is an RFC 3339 string.
pub const Time = @import("time.zig").Time;
/// A connection URL taken apart (`postgres://`, `mongodb://`,
/// `redis://`): `Url.parse(arena, text)`.
pub const Url = @import("url.zig").Url;
/// A connection URL for logs, with its password replaced by `***`:
/// `log.info("connecting to {f}", .{anole.db.redacted(url)})`.
pub const redacted = @import("url.zig").redacted;
/// An environment variable's value (`DATABASE_URL` and the like), or null.
pub const env = @import("url.zig").env;
/// A cached ping behind `/readyz`, which a connector registers with
/// `app.health`.
pub const Readiness = @import("observe.zig").Readiness;
/// A connector's Prometheus metrics (calls, durations, errors, pool use).
pub const Metrics = @import("observe.zig").Metrics;
/// What a connector reports each call to: its `Metrics`, and a client span
/// when the request is traced.
pub const Observer = @import("observe.zig").Observer;
/// One call in progress, from `Observer.start` to `Call.end`.
pub const Call = @import("observe.zig").Call;

const log = std.log.scoped(.anole);

/// The database a connector talks to, as OpenTelemetry names it
/// (`db.system.name`).
pub const System = enum {
    postgresql,
    sqlite,
    mongodb,
    redis,
};

/// A call's context outside a handler (startup, a background task, a
/// test): what a request otherwise supplies.
///
///     var arena: std.heap.ArenaAllocator = .init(gpa);
///     defer arena.deinit();
///     var c: anole.db.Ctx = .{ .io = io, .arena = arena.allocator() };
///     try app.db.exec(&c, "CREATE TABLE IF NOT EXISTS posts (...)", .{});
pub const Ctx = struct {
    io: std.Io,
    /// Where results go.
    arena: std.mem.Allocator,
    /// See `lastError`.
    last_error: ?ErrorDetail = null,
};

/// Per call (`with`). The defaults are the plain path: no extra bound, a
/// prepared statement, nothing cached.
pub const QueryOptions = struct {
    /// A bound of the call's own, on top of the request's deadline: past
    /// it the call is canceled and fails with `error.GatewayTimeout`. For
    /// work outside a request, which has no deadline otherwise.
    timeout: ?std.Io.Duration = null,
    /// SQL connectors: prepare the statement and keep it for the next call
    /// (per connection). Off for SQL that is built at run time and seldom
    /// repeats.
    prepare: bool = true,
    /// SQLite: run on the writer connection, for a write that does not
    /// look like one (a `SELECT` with side effects, `WITH ... RETURNING`).
    write: bool = false,
    /// Reads (`one`, `optional`, `all`): identical ones in flight at once
    /// on one executor (same statement, arguments, verb and row type)
    /// share one round trip, each caller getting its own copy of the rows.
    /// A caller canceled or out of time leaves alone; the others still get
    /// the rows. See `QueryCache`.
    coalesce: bool = false,
    /// Reads: the result kept per executor for `ttl` and served from
    /// memory meanwhile, a miss coalescing with any identical one in
    /// flight. Errors are not kept. Drop results early with the
    /// connector's `cache.invalidate`. See `QueryCache`.
    cache: ?Cache = null,

    /// `QueryOptions.cache`: how long a result is kept, and a tag to drop
    /// it by.
    pub const Cache = struct {
        /// How long a result is served from memory.
        ttl: std.Io.Duration,
        /// A name to drop the result by: `cache.invalidate(.{ .tag = "posts" })`.
        tag: ?[]const u8 = null,
    };
};

/// A connector's coalescing and result cache (`app.db.cache`), behind
/// `QueryOptions.coalesce` and `QueryOptions.cache`.
pub const QueryCache = @import("cache.zig").Cache;
/// Its bounds (each connector's `Options.cache`).
pub const CacheOptions = @import("cache.zig").Options;

/// How `begin` and `transaction` open a transaction.
pub const TxOptions = struct {
    /// Null: the database's default.
    isolation: ?Isolation = null,
    /// `READ ONLY` (PostgreSQL), or a reader connection (SQLite).
    read_only: bool = false,
    /// `transaction` only: runs again after a serialization failure or a
    /// deadlock (`retryable`), up to this many more times.
    retries: u8 = 0,
    /// As `QueryOptions.timeout`, for the whole transaction.
    timeout: ?std.Io.Duration = null,
};

/// SQL isolation levels (`TxOptions.isolation`).
pub const Isolation = enum { read_uncommitted, read_committed, repeatable_read, serializable };

// ---------------------------------------------------------------------------
// Errors

/// What every connector's calls fail with, besides `error.Canceled` and
/// `error.OutOfMemory`. The names are the statuses the server answers
/// with (`anole.errorStatus`); `Database` and `MissingColumn` are 500s.
pub const Error = error{
    /// `one` found no row (no document).
    NotFound,
    /// A unique or exclusion constraint, or a transaction that lost a
    /// serialization race or a deadlock (after its retries).
    Conflict,
    /// The database could not be reached or had no connection to give in
    /// time: pool exhausted, connect refused, no primary, SQLite busy.
    ServiceUnavailable,
    /// The database gave up on a statement, or the call ran past its
    /// `timeout`.
    GatewayTimeout,
    /// Any other server error: foreign key, not-null and check violations,
    /// syntax, permissions. The detail is in `lastError`.
    Database,
    /// A row lacks a column the struct has no default for.
    MissingColumn,
    /// Only through an `ErrorMap` that asks for them.
    BadRequest,
    /// Only through an `ErrorMap` that asks for it.
    UnprocessableEntity,
};

/// What `Error` a call returns for a server error of each class, which
/// moves a class to another status: `.{ .foreign_key = .unprocessable_entity }`
/// for an app that validates input through its constraints.
pub const ErrorMap = struct {
    unique: Answer = .conflict,
    exclusion: Answer = .conflict,
    foreign_key: Answer = .internal_server_error,
    not_null: Answer = .internal_server_error,
    check: Answer = .internal_server_error,
    serialization: Answer = .conflict,
    deadlock: Answer = .conflict,
    unavailable: Answer = .service_unavailable,
    timeout: Answer = .gateway_timeout,
    other: Answer = .internal_server_error,

    /// The status a class answers with; each one is an `Error`.
    pub const Answer = enum {
        bad_request,
        not_found,
        conflict,
        unprocessable_entity,
        internal_server_error,
        service_unavailable,
        gateway_timeout,

        /// The `Error` for this status: `.internal_server_error` is
        /// `error.Database`.
        pub fn err(self: Answer) Error {
            return switch (self) {
                .bad_request => error.BadRequest,
                .not_found => error.NotFound,
                .conflict => error.Conflict,
                .unprocessable_entity => error.UnprocessableEntity,
                .internal_server_error => error.Database,
                .service_unavailable => error.ServiceUnavailable,
                .gateway_timeout => error.GatewayTimeout,
            };
        }
    };

    /// The `Error` this map gives `class`.
    pub fn errorFor(self: ErrorMap, class: Class) Error {
        return switch (class) {
            inline else => |tag| @field(self, @tagName(tag)).err(),
        };
    }
};

/// What kind of failure a server error is, as the connector reads it from
/// the server's code.
pub const Class = enum {
    /// PostgreSQL 23505; SQLite CONSTRAINT_UNIQUE, CONSTRAINT_PRIMARYKEY;
    /// MongoDB 11000.
    unique,
    /// PostgreSQL 23P01.
    exclusion,
    /// PostgreSQL 23503; SQLite CONSTRAINT_FOREIGNKEY.
    foreign_key,
    /// PostgreSQL 23502; SQLite CONSTRAINT_NOTNULL.
    not_null,
    /// PostgreSQL 23514; SQLite CONSTRAINT_CHECK; MongoDB 121 (document
    /// validation).
    check,
    /// PostgreSQL 40001; SQLite BUSY_SNAPSHOT. `transaction` retries it.
    serialization,
    /// PostgreSQL 40P01. `transaction` retries it.
    deadlock,
    /// No connection to be had: refused, pool exhausted, no primary,
    /// SQLite BUSY past its timeout.
    unavailable,
    /// PostgreSQL 57014 (statement_timeout, or our cancel); MongoDB 50
    /// (MaxTimeMSExpired); a call past its `timeout`.
    timeout,
    /// Everything else.
    other,
};

/// A failed call's detail, for logs: what `lastError` returns.
pub const ErrorDetail = struct {
    system: System,
    class: Class,
    /// The server's code as text: a SQLSTATE ("23505") for PostgreSQL, the
    /// extended result code ("2067") for SQLite, the error code ("11000")
    /// for MongoDB. Empty when the failure was ours (a pool, a timeout).
    code: []const u8 = "",
    message: []const u8 = "",
    constraint: ?[]const u8 = null,
    /// The table, or the collection.
    table: ?[]const u8 = null,

    /// Writes it for a log line with `{f}`: `postgresql 23505 (unique):
    /// duplicate key ... [constraint posts_slug_key] [table posts]`.
    pub fn format(self: ErrorDetail, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{t}", .{self.system});
        if (self.code.len > 0) try w.print(" {s}", .{self.code});
        try w.print(" ({t}): {s}", .{ self.class, self.message });
        if (self.constraint) |v| try w.print(" [constraint {s}]", .{v});
        if (self.table) |v| try w.print(" [table {s}]", .{v});
    }

    fn dupe(self: ErrorDetail, arena: std.mem.Allocator) !ErrorDetail {
        var out = self;
        out.code = try arena.dupe(u8, self.code);
        out.message = try arena.dupe(u8, self.message);
        if (self.constraint) |v| out.constraint = try arena.dupe(u8, v);
        if (self.table) |v| out.table = try arena.dupe(u8, v);
        return out;
    }
};

/// Where a request keeps its last error.
const last_error_key = "anole.db.last_error";

/// Records `detail` as `c`'s last error (copied into its arena), logs it,
/// and returns the `Error` that `map` gives its class: what a connector
/// returns for any server error.
///
///     return anole.db.fail(req, self.error_map, .{ .system = .postgresql, .class = .unique,
///         .code = "23505", .message = msg, .constraint = name });
///
/// 5xx classes are logged at warn, the rest at debug: a 404 or a 409 is
/// the client's doing.
pub fn fail(c: anytype, map: ErrorMap, detail: ErrorDetail) Error {
    const err = map.errorFor(detail.class);
    record(c, detail, err);
    return err;
}

fn record(c: anytype, detail: ErrorDetail, err: Error) void {
    keepError(c, detail);
    const kept = lastError(c).?;
    const id = if (comptime @hasField(Pointee(@TypeOf(c)), "id")) c.id else "";
    switch (err) {
        error.Database, error.ServiceUnavailable, error.GatewayTimeout => log.warn("{s}{s}database error: {f}", .{ id, if (id.len > 0) " " else "", kept }),
        else => log.debug("{s}{s}database error: {f}", .{ id, if (id.len > 0) " " else "", kept }),
    }
}

/// Records `detail` as `c`'s last error (copied into its arena) without
/// logging it: for a failure that was logged where it happened, such as
/// a shared call's (`QueryOptions.coalesce`) for each caller.
pub fn keepError(c: anytype, detail: ErrorDetail) void {
    comptime checkContext(@TypeOf(c));
    const kept = detail.dupe(c.arena) catch ErrorDetail{ .system = detail.system, .class = detail.class, .message = "(detail lost: out of memory)" };
    if (comptime hasLocals(@TypeOf(c))) {
        c.locals.put(c.arena, last_error_key, kept) catch {};
    } else {
        c.last_error = kept;
    }
}

/// The detail of the last failed call made with `c` (a request or a
/// `Ctx`), for logs and for handlers that inspect a constraint name; null
/// when none failed. Never send it to the client.
pub fn lastError(c: anytype) ?ErrorDetail {
    comptime checkContext(@TypeOf(c));
    if (comptime hasLocals(@TypeOf(c))) return c.locals.get(ErrorDetail, last_error_key);
    return c.last_error;
}

/// Whether `transaction` should run again after `err`: a `Conflict` from
/// a serialization failure or a deadlock.
pub fn retryable(c: anytype, err: anyerror) bool {
    if (err != error.Conflict) return false;
    const detail = lastError(c) orelse return false;
    return detail.class == .serialization or detail.class == .deadlock;
}

fn Pointee(comptime C: type) type {
    return switch (@typeInfo(C)) {
        .pointer => |p| p.child,
        else => C,
    };
}

fn hasLocals(comptime C: type) bool {
    return @hasField(Pointee(C), "locals");
}

fn checkContext(comptime C: type) void {
    const T = Pointee(C);
    if (@typeInfo(C) != .pointer or @typeInfo(T) != .@"struct" or !@hasField(T, "io") or !@hasField(T, "arena") or
        !(@hasField(T, "locals") or @hasField(T, "last_error")))
        @compileError("anole.db: a call takes the request (*anole.Request) or a *anole.db.Ctx, not " ++ @typeName(C));
}

/// The request behind `c`, for its trace context; null for a `Ctx`.
pub fn requestOf(c: anytype) ?*const dusty.Request {
    if (comptime Pointee(@TypeOf(c)) == dusty.Request) return c;
    return null;
}

// ---------------------------------------------------------------------------
// Timeouts

/// What `bounded(c, ..., func, args)` returns: `func`'s result, with the
/// timeout's errors added.
pub fn Bounded(comptime func: anytype) type {
    const R = dusty.Deadline.Result(func);
    const eu = @typeInfo(R).error_union;
    return (eu.error_set || error{GatewayTimeout})!eu.payload;
}

/// Runs `func(args...)` under `timeout` (a call's `QueryOptions.timeout`);
/// null runs it as it is. Past it, the call is canceled where it waits,
/// which `func` handles as any cancel (leaving the connection reset or
/// closed), and `bounded` fails with `error.GatewayTimeout`, recorded for
/// `lastError` with class `timeout`.
pub fn bounded(c: anytype, system: System, timeout: ?std.Io.Duration, func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) Bounded(func) {
    const d = timeout orelse return @call(.auto, func, args);
    const deadline: dusty.Deadline = .init(c.io, .{ .duration = .{ .raw = d, .clock = .awake } });
    return deadline.run(func, args) catch |err| switch (err) {
        error.Timeout => {
            record(c, .{ .system = system, .class = .timeout, .message = "the call ran past its timeout" }, error.GatewayTimeout);
            return error.GatewayTimeout;
        },
        else => |e| return e,
    };
}

// ---------------------------------------------------------------------------
// Pools

/// The index of the calling task's executor, or null off zio's executors
/// (`std.Io.Threaded`, a thread of zio's blocking pool).
pub fn executorIndex(io: std.Io) ?usize {
    return placement.currentExecutor(io);
}

/// How many executors `io`'s runtime has; 1 off zio.
pub fn executorCount(io: std.Io) usize {
    return placement.executorCount(io) orelse 1;
}

/// Part `index` of `total` connections split over `parts` pools: the
/// parts add up to `total`, and differ by one at most. Each pool gets at
/// least one, so with fewer connections than pools the total becomes the
/// number of pools.
pub fn split(total: usize, parts: usize, index: usize) usize {
    std.debug.assert(parts > 0 and index < parts);
    if (total <= parts) return 1;
    return total / parts + @intFromBool(index < total % parts);
}

/// One `Pool` per executor of the runtime, so a task only ever takes
/// connections from its own executor's pool: no lock is contended across
/// threads, and a connection stays with the executor its tasks run on.
/// The connection limit is split between them (`share`); a busy executor
/// does not borrow from an idle one.
///
///     var pools = try anole.db.PerExecutor(Pool).init(gpa, io);
///     for (pools.pools, 0..) |*p, i| p.* = Pool.init(.{ .max = pools.share(opts.max_connections, i) });
///     ...
///     const pool = pools.get(req.io);
///
/// `Pool` must still be safe to use from any task (`std.Io.Mutex`, not
/// thread-unsafe state): calls from outside the executors (a blocking-pool
/// thread, `std.Io.Threaded`) all use pool 0.
pub fn PerExecutor(comptime Pool: type) type {
    return struct {
        const Self = @This();

        /// By executor index; undefined until the connector sets each.
        pools: []Pool,

        /// One slot per executor of `io`'s runtime (one off zio).
        pub fn init(gpa: std.mem.Allocator, io: std.Io) error{OutOfMemory}!Self {
            return .{ .pools = try gpa.alloc(Pool, executorCount(io)) };
        }

        /// Frees the slots; the connector closes each pool first.
        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            gpa.free(self.pools);
            self.* = undefined;
        }

        /// Pool `index`'s part of `total` connections (`split`).
        pub fn share(self: *const Self, total: usize, index: usize) usize {
            return split(total, self.pools.len, index);
        }

        /// The pool of the executor the calling task runs on.
        pub fn get(self: *const Self, io: std.Io) *Pool {
            const index = executorIndex(io) orelse 0;
            return &self.pools[index % self.pools.len];
        }
    };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test {
    _ = @import("copy.zig");
    _ = @import("cache.zig");
    _ = @import("../cache/store.zig");
    _ = @import("time.zig");
    _ = @import("url.zig");
    _ = @import("observe.zig");
}

test "errors: each one's status, and what ErrorMap changes" {
    const errorStatus = dusty.errorStatus;
    const Case = struct { Error, ?dusty.Status };
    for ([_]Case{
        .{ error.NotFound, .not_found },
        .{ error.Conflict, .conflict },
        .{ error.ServiceUnavailable, .service_unavailable },
        .{ error.GatewayTimeout, .gateway_timeout },
        .{ error.BadRequest, .bad_request },
        .{ error.UnprocessableEntity, .unprocessable_entity },
        // 500s.
        .{ error.Database, null },
        .{ error.MissingColumn, null },
    }) |case| try testing.expectEqual(case[1], errorStatus(case[0]));

    const defaults: ErrorMap = .{};
    const ClassCase = struct { Class, Error };
    for ([_]ClassCase{
        .{ .unique, error.Conflict },
        .{ .exclusion, error.Conflict },
        .{ .serialization, error.Conflict },
        .{ .deadlock, error.Conflict },
        .{ .unavailable, error.ServiceUnavailable },
        .{ .timeout, error.GatewayTimeout },
        .{ .foreign_key, error.Database },
        .{ .not_null, error.Database },
        .{ .check, error.Database },
        .{ .other, error.Database },
    }) |case| try testing.expectEqual(case[1], defaults.errorFor(case[0]));

    const validating: ErrorMap = .{ .foreign_key = .unprocessable_entity, .check = .bad_request };
    try testing.expectEqual(error.UnprocessableEntity, validating.errorFor(.foreign_key));
    try testing.expectEqual(error.BadRequest, validating.errorFor(.check));
    try testing.expectEqual(error.Conflict, validating.errorFor(.unique));
}

test "fail and lastError: on a Ctx and on a request, copied into the arena" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ctx: Ctx = .{ .io = testing.io, .arena = arena };
    try testing.expect(lastError(&ctx) == null);
    var message = "duplicate key value violates unique constraint \"users_email_key\"".*;
    const err = fail(&ctx, .{}, .{ .system = .postgresql, .class = .unique, .code = "23505", .message = &message, .constraint = "users_email_key" });
    try testing.expectEqual(error.Conflict, err);
    // The connector's buffer may be reused at once.
    @memset(&message, 'x');
    const detail = lastError(&ctx).?;
    try testing.expectEqualStrings("23505", detail.code);
    try testing.expectStringStartsWith(detail.message, "duplicate key");
    try testing.expectEqualStrings("users_email_key", detail.constraint.?);
    try testing.expect(!retryable(&ctx, err));

    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "postgresql 23505 (unique): duplicate key value violates unique constraint \"users_email_key\" [constraint users_email_key]",
        try std.fmt.bufPrint(&buf, "{f}", .{detail}),
    );

    var req: dusty.Request = .{ .arena = arena, .io = testing.io, .parser = undefined, .transport = undefined };
    try testing.expect(lastError(&req) == null);
    const lost = fail(&req, .{}, .{ .system = .postgresql, .class = .serialization, .code = "40001", .message = "could not serialize access" });
    try testing.expectEqual(error.Conflict, lost);
    try testing.expectEqual(Class.serialization, lastError(&req).?.class);
    try testing.expect(retryable(&req, lost));
    try testing.expect(!retryable(&req, error.Database));
    try testing.expect(requestOf(&req) == &req);
    try testing.expect(requestOf(&ctx) == null);
}

test "bounded: past its timeout a call is canceled and fails with GatewayTimeout" {
    const zio = @import("zio");
    const rt = try zio.Runtime.init(testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var ctx: Ctx = .{ .io = io, .arena = arena_state.allocator() };

    const Slow = struct {
        fn wait(_io: std.Io, ms: i64) error{Gone}!u8 {
            _io.sleep(.fromMilliseconds(ms), .awake) catch return error.Gone;
            return 7;
        }
    };
    try testing.expectEqual(@as(u8, 7), try bounded(&ctx, .postgresql, null, Slow.wait, .{ io, 1 }));
    try testing.expectEqual(@as(u8, 7), try bounded(&ctx, .postgresql, .fromSeconds(5), Slow.wait, .{ io, 1 }));
    // It logs a warning, as a 5xx does; not in the test's output.
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    try testing.expectError(error.GatewayTimeout, bounded(&ctx, .postgresql, .fromMilliseconds(20), Slow.wait, .{ io, 10_000 }));
    try testing.expectEqual(Class.timeout, lastError(&ctx).?.class);
}

test "split: the parts add up, differ by one at most, and none is empty" {
    for ([_]usize{ 1, 2, 3, 4, 7, 16 }) |parts| {
        for ([_]usize{ 0, 1, 3, 4, 10, 17, 100 }) |total| {
            var sum: usize = 0;
            var lo: usize = std.math.maxInt(usize);
            var hi: usize = 0;
            for (0..parts) |i| {
                const n = split(total, parts, i);
                sum += n;
                lo = @min(lo, n);
                hi = @max(hi, n);
            }
            try testing.expect(lo >= 1 and hi - lo <= 1);
            try testing.expectEqual(@max(total, parts), sum);
        }
    }
}

test "PerExecutor: on 4 pinned executors each task gets its own executor's pool" {
    const zio = @import("zio");
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(4) });
    defer rt.deinit();
    const io = rt.io();

    // A pool that records which executors used it.
    const Pool = struct {
        index: usize,
        limit: usize,
        users: std.atomic.Value(u64) = .init(0),
    };
    var pools = try PerExecutor(Pool).init(gpa, io);
    defer pools.deinit(gpa);
    try testing.expectEqual(@as(usize, 4), pools.pools.len);
    for (pools.pools, 0..) |*p, i| p.* = .{ .index = i, .limit = pools.share(10, i) };
    try testing.expectEqual(@as(usize, 3), pools.pools[0].limit);
    try testing.expectEqual(@as(usize, 2), pools.pools[3].limit);

    const Worker = struct {
        fn run(p: *const PerExecutor(Pool), _io: std.Io, rounds: usize, wrong: *std.atomic.Value(u32)) std.Io.Cancelable!void {
            for (0..rounds) |_| {
                const here = executorIndex(_io) orelse 99;
                const pool = p.get(_io);
                if (here != pool.index) _ = wrong.fetchAdd(1, .monotonic);
                _ = pool.users.fetchOr(@as(u64, 1) << @intCast(pool.index), .monotonic);
                try _io.sleep(.fromMicroseconds(100), .awake);
            }
        }
    };
    var wrong: std.atomic.Value(u32) = .init(0);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (0..16) |i| try placement.concurrent(&group, io, .{ .executor = i % 4 }, Worker.run, .{ &pools, io, 20, &wrong });
    try group.await(io);
    try testing.expectEqual(@as(u32, 0), wrong.load(.monotonic));
    // Every pool was used, each by its own executor alone.
    for (pools.pools, 0..) |*p, i| try testing.expectEqual(@as(u64, 1) << @intCast(i), p.users.load(.monotonic));

    // Off the executors (a thread of the blocking pool): pool 0.
    const off = try rt.blockingIo().concurrent(struct {
        fn run(p: *const PerExecutor(Pool), _io: std.Io) usize {
            return p.get(_io).index;
        }
    }.run, .{ &pools, rt.blockingIo() });
    var f = off;
    try testing.expectEqual(@as(usize, 0), f.await(io));
}

test "PerExecutor: one pool off zio" {
    var pools = try PerExecutor(u32).init(testing.allocator, testing.io);
    defer pools.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), pools.pools.len);
    try testing.expectEqual(@as(usize, 25), pools.share(25, 0));
    try testing.expect(pools.get(testing.io) == &pools.pools[0]);
}
