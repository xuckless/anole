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
//! Each connector's handle is its `Client` (`anole.pg.Client`,
//! `anole.sqlite.Client`, `anole.mongodb.Client`, `anole.redis.Client`),
//! which `app.postgres`, `app.sqlite`, `app.mongodb` and `app.redis`
//! return; its calls fail with its `Error` (`anole.db.Error`, a cancel, or
//! memory), and its `Options.errors` (an `ErrorMap`) moves error classes
//! to other statuses.
//!
//! The first argument after the handle, `c`, is the request (`*anole.Request`)
//! or, outside a handler, a `*Ctx`: both carry `io` (a wait suspends the
//! calling coroutine) and `arena` (what the call returns lives as long as
//! it does; nothing to free). Connectors take it as `anytype`.
//!
//! The verbs, with these meanings wherever they exist (the SQL
//! connectors have them all; MongoDB and Redis keep those that apply, a
//! filter or a command in place of `sql`, and call the rest by their
//! database's names):
//!
//!     exec(c, sql, args) !u64                      rows affected
//!     one(T, c, sql, args) !T                      the first row; none: error.NotFound
//!     optional(T, c, sql, args) !?T                the first row, or null
//!     all(T, c, sql, args) ![]T                    every row
//!     iterate(T, c, sql, args) !Rows(T)            rows one at a time (`next() !?T`,
//!                                                  `deinit()` gives the connection back)
//!     begin(c, TxOptions) !Tx                      `Tx` has the verbs above,
//!                                                  `commit(c)`, `rollback(c)`, and
//!                                                  `deinit` (rolls back unless committed)
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
//! Errors: a server error's detail is kept for `lastError(c)`, and the
//! call returns one of `Error`, which the server turns into a status
//! (`NotFound` 404, `Conflict` 409, `ServiceUnavailable` 503,
//! `GatewayTimeout` 504, `Database` 500; `ErrorMap` moves the classes
//! around). The detail never reaches the client.
//!
//! Cancellation: a request's deadline or an HTTP/2 RST_STREAM cancels the
//! handler's task, so a waiting call returns `error.Canceled`; the
//! connector then leaves nothing behind (the connection closed or reset,
//! the server told to stop). `QueryOptions.timeout` does the same, and
//! the call fails with `error.GatewayTimeout`.
//!
//! Pools: one per executor, so a call never waits on another executor's
//! connections; the connection limit is split between them.
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
const internal = @import("internal.zig");

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
///     _ = try app.db.exec(&c, "CREATE TABLE IF NOT EXISTS posts (...)", .{});
pub const Ctx = struct {
    io: std.Io,
    /// Where results go.
    arena: std.mem.Allocator,
    /// See `lastError`.
    last_error: ?ErrorDetail = null,
    /// See `lastSource`.
    last_source: ?Source = null,
};

/// A value whose type is known only at run time: a parameter of a SQL
/// connector's `table` and `run` (`anole.pg`, `anole.sqlite`), or a cell of
/// a `Table`. What the C ABI (`anole_db_*`) and the language bindings pass.
pub const Value = union(enum) {
    null,
    int: i64,
    float: f64,
    bool: bool,
    /// UTF-8 text; in a row, copied into the arena.
    text: []const u8,
    /// Bytes; in a row, copied into the arena.
    blob: []const u8,
};

/// Rows whose columns are known only at run time: the result's column
/// names, each column's type as the database names it (PostgreSQL's type
/// OIDs; empty for SQLite, whose types are per value), and each row's
/// cells in column order.
pub const Table = struct {
    columns: []const []const u8,
    types: []const u32 = &.{},
    rows: []const []const Value,
};

/// What a write did (`run`): the rows it changed, and for SQLite the rowid
/// of the last row inserted on the connection (0 for PostgreSQL: use
/// `RETURNING` with `table`).
pub const Changes = struct {
    changes: u64,
    last_insert_rowid: i64 = 0,
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
    /// flight. Errors are not kept, and empty results only while
    /// `keep_empty`. Drop results early with the connector's
    /// `cache.invalidate`; `lastSource` says whether a call was answered
    /// from memory. See `QueryCache`.
    cache: ?Cache = null,

    /// `QueryOptions.cache`: how long a result is kept, a tag to drop it
    /// by, and whether an empty one is kept.
    pub const Cache = struct {
        /// How long a result is served from memory.
        ttl: std.Io.Duration,
        /// A name to drop the result by: `cache.invalidate(.{ .tag = "posts" })`.
        tag: ?[]const u8 = null,
        /// Keep empty results as well: `optional`'s null (Redis nil,
        /// MongoDB `findOptional` with no match) and `all`'s zero rows
        /// (MongoDB `find`, `aggregate` and `distinct` with none, an empty
        /// Redis list or set). False serves them but keeps nothing, so the
        /// next call asks again: for cache-aside, where a miss is followed
        /// by filling the store, and "not there yet" must not be served
        /// for `ttl` after the value exists. `one` and counts never return
        /// empty (none is `error.NotFound`, never kept).
        keep_empty: bool = true,
    };
};

/// Where a call's answer came from (`lastSource`).
pub const Source = enum {
    /// This executor's result cache (`QueryOptions.cache`): no round trip.
    cache,
    /// An identical call already in flight on this executor, joined
    /// (`QueryOptions.coalesce`, or a cache miss): its round trip, shared.
    coalesced,
    /// A round trip of the call's own to the database.
    database,
};

/// Where the last call made with `c` through `.cache` or `.coalesce`
/// (`with(...)`) got its answer, failed calls included; null when `c` made
/// none. Plain calls leave it as it was. For an `X-Cache` header:
///
///     const top = try app.db.with(.{ .cache = .{ .ttl = .fromSeconds(5) } }).all(Post, req, sql, .{});
///     try res.header("X-Cache", if (anole.db.lastSource(req) == .cache) "HIT" else "MISS");
pub fn lastSource(c: anytype) ?Source {
    return internal.lastSource(c);
}

/// A connector's coalescing and result cache (`app.db.cache`), behind
/// `QueryOptions.coalesce` and `QueryOptions.cache`.
pub const QueryCache = @import("cache.zig").Cache;
/// Its bounds (each connector's `Options.cache`).
pub const CacheOptions = @import("cache.zig").Options;
/// What a connector's read returns (`one`, `optional`, `all`), which tells
/// the cache what an empty result is: each runner a connector passes to
/// `QueryCache.read` names its own as `pub const shape`.
pub const ReadShape = @import("cache.zig").Shape;

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
};

/// The detail of the last failed call made with `c` (a request or a
/// `Ctx`), for logs and for handlers that inspect a constraint name; null
/// when none failed. Never send it to the client.
pub fn lastError(c: anytype) ?ErrorDetail {
    return internal.lastError(c);
}

/// Whether `transaction` should run again after `err`: a `Conflict` from
/// a serialization failure or a deadlock.
pub fn retryable(c: anytype, err: anyerror) bool {
    if (err != error.Conflict) return false;
    const detail = lastError(c) orelse return false;
    return detail.class == .serialization or detail.class == .deadlock;
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
    _ = @import("internal.zig");
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
