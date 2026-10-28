//! `anole_db_*`: the configuration's databases (SQLite, PostgreSQL, Redis and MongoDB), queried
//! without blocking the caller. A call copies the statement and its
//! parameters into a command for one of the consumer's executors; the
//! executor's capi task starts a task for it there, which runs the
//! statement through the connector (`anole.sqlite`: readers on the blocking
//! pool, writes on the database's writer thread; `anole.pg`: the executor's
//! own pool), with coalescing and the result cache as the options ask, and
//! queues the answer as one `ANOLE_EV_DB_RESULT` record on the ring that
//! feeds the consumer.
const std = @import("std");
const anole = @import("../root.zig");
const dusty = @import("dusty");
const engine = @import("engine.zig");
const abi = @import("abi.zig");
const config_mod = @import("config.zig");
const jobs = @import("jobs.zig");
const webhooks = @import("webhooks.zig");

const features = anole.features;
const placement = dusty.placement;
const gpa = engine.gpa;
const Engine = engine.Engine;
const Exec = engine.Exec;
const Consumer = engine.Consumer;
const Command = engine.Command;
const Handle = engine.Handle;
const db = anole.db;
const sqlite = if (features.sqlite) anole.sqlite else struct {
    pub const Client = void;
    pub const Tx = void;
};
const pg = if (features.postgres) anole.pg else struct {
    pub const Client = void;
    pub const Tx = void;
};
const redis = if (features.redis) anole.redis else struct {
    pub const Client = void;
    pub const Reply = void;
};
const mongodb = if (features.mongodb) anole.mongodb else struct {
    pub const Client = void;
    pub const dynamic = struct {
        pub const Result = void;
    };
};
const bson = anole.bson;

const log = std.log.scoped(.anole);

/// One configured database (`anole_db *` in C).
pub const Db = struct {
    engine: *Engine,
    config: config_mod.Config.Database,
    /// The connector, set when the server starts.
    client: Client = .none,
    /// Whether queries may be queued: from the start until the stop.
    open: std.atomic.Value(bool) = .init(false),
};

const Client = union(enum) {
    none,
    sqlite: *sqlite.Client,
    postgres: *pg.Client,
    redis: *redis.Client,
    mongodb: *mongodb.Client,
};

/// Per executor: the tasks of the queries and transactions it runs, canceled
/// at the stop.
pub const ExecState = struct {
    work: std.Io.Group = .init,
    txs: TxTable = .{},

    /// The stop: open transactions are rolled back and answer nothing.
    pub fn cancel(st: *ExecState, io: std.Io) void {
        st.txs.markStopped();
        st.work.cancel(io);
    }

    /// The highest generation of any transaction slot (`Engine.destroy`).
    pub fn maxGen(st: *const ExecState) u32 {
        return st.txs.maxGen();
    }

    pub fn deinit(st: *ExecState) void {
        st.txs.deinit();
    }
};

/// What a query or a transaction keeps in its request's slot, so that the
/// request's end can cut it.
pub const Tied = struct {
    next: ?*Tied = null,
    linked: bool = false,
    cut: *const fn (*Tied) void,
};

pub fn linkTied(x: *Exec, i: u32, t: *Tied) void {
    t.next = x.slots[i].db_tied;
    x.slots[i].db_tied = t;
    t.linked = true;
}

pub fn unlinkTied(x: *Exec, i: u32, t: *Tied) void {
    if (!t.linked) return;
    t.linked = false;
    var link = &x.slots[i].db_tied;
    while (link.*) |cur| {
        if (cur == t) {
            link.* = t.next;
            t.next = null;
            return;
        }
        link = &cur.next;
    }
}

/// Slot `i` is being released (on its executor): what is tied to it is
/// unlinked, and cut when the request ended without being answered (aborted,
/// or past its deadline).
pub fn endTied(x: *Exec, i: u32, cut: bool) void {
    const s = &x.slots[i];
    var t = s.db_tied;
    s.db_tied = null;
    while (t) |tied| {
        const next = tied.next;
        tied.next = null;
        tied.linked = false;
        if (cut) tied.cut(tied);
        t = next;
    }
}

/// Whether the request or call `h` is still there to serve.
pub fn slotLive(x: *Exec, h: Handle) bool {
    if (h.slot >= x.slots.len) return false;
    const sl = &x.slots[h.slot];
    if (sl.kind.load(.acquire) != @backingInt(h.kind)) return false;
    const w = sl.word.load(.acquire);
    if (engine.genOf(w) != h.gen) return false;
    return switch (engine.stateOf(w)) {
        .free, .expired => false,
        else => true,
    };
}

/// The executor of the request or gRPC call `hv`, which must be live; `c`,
/// when given, must be its consumer.
pub fn resolveReq(e: *Engine, hv: u64, c: ?*Consumer) QueryError!*Exec {
    const h = Handle.decode(hv);
    if (h.gen == 0 or (h.kind != .request and h.kind != .grpc_call)) return error.Invalid;
    if (h.exec >= e.execs.len) return error.Gone;
    const x = &e.execs[h.exec];
    if (!slotLive(x, h)) return error.Gone;
    const xc = x.consumer orelse return error.State;
    if (c) |cc| if (cc != xc) return error.Invalid;
    return x;
}

/// Opens every configured database on `app` (from the server's main
/// thread, before the listeners open) and runs its `init` script.
pub fn open(e: *Engine, app: *anole.App) !void {
    for (e.dbs) |*d| {
        if (d.config.postgres) |p| {
            if (comptime features.postgres) try openPostgres(d, app, p) else unreachable;
        } else if (d.config.redis) |r| {
            if (comptime features.redis) try openRedis(d, app, r) else unreachable;
        } else if (d.config.mongodb) |m| {
            if (comptime features.mongodb) try openMongodb(d, app, m) else unreachable;
        } else {
            if (comptime features.sqlite) try openSqlite(d, app, d.config.sqlite.?) else unreachable;
        }
        d.open.store(true, .release);
    }
}

const ms = std.Io.Duration.fromMilliseconds;

/// Zero is none.
fn optMs(n: u32) ?std.Io.Duration {
    return if (n > 0) ms(n) else null;
}

/// The connector's bound on a call without its own: `databases[].timeout_ms`.
fn callBound(d: *Db) ?std.Io.Duration {
    return optMs(d.config.timeout_ms);
}

/// `anole.db.Tls` from a connector's TLS keys.
fn tlsOf(c: anytype) db.Tls {
    return .{
        .ca = if (c.ca_file) |f| .{ .file = f } else if (c.ca_pem) |pem| .{ .pem = pem } else null,
        .client_certificate = if (c.client_cert_file) |f|
            dusty.Cert.fromFiles(f, c.client_key_file.?)
        else if (c.client_cert_pem) |pem|
            dusty.Cert.fromPem(pem, c.client_key_pem.?)
        else
            null,
        .insecure_skip_verify = c.insecure_skip_verify,
    };
}

fn openSqlite(d: *Db, app: *anole.App, sq: config_mod.Config.Sqlite) !void {
    {
        const client = try app.sqlite(anole.sqlite.Options{
            .path = sq.path,
            .name = d.config.name,
            .uri = sq.uri,
            .readers = sq.readers,
            .busy_timeout = ms(sq.busy_timeout_ms),
            .statement_cache_size = sq.statement_cache_size,
            .ping_timeout = ms(sq.ping_timeout_ms),
            .timeout = callBound(d),
            .errors = d.config.errors,
            .pragmas = sq.pragmas,
            .cache = .{
                .max_entries = d.config.cache.max_entries,
                .max_bytes = std.math.cast(usize, d.config.cache.max_bytes) orelse std.math.maxInt(usize),
            },
        });
        var script_arena: std.heap.ArenaAllocator = .init(gpa);
        defer script_arena.deinit();
        var script_ctx: db.Ctx = .{ .io = app.io(), .arena = script_arena.allocator() };
        if (sq.init) |script| client.execScript(&script_ctx, script) catch |err| {
            log.err("databases \"{s}\": init failed: {t}", .{ d.config.name, err });
            return err;
        };
        d.client = .{ .sqlite = client };
    }
}

fn breakerOf(d: *const Db) ?anole.resilience.Breaker.Options {
    const b = d.config.breaker orelse return null;
    return .{
        .consecutive_failures = b.consecutive_failures,
        .failure_ratio = b.failure_ratio,
        .min_calls = b.min_calls,
        .window = ms(b.window_ms),
        .open_for = ms(b.open_ms),
        .max_open_for = ms(b.max_open_ms),
        .half_open_calls = b.half_open_calls,
    };
}

fn retryOf(d: *const Db) anole.resilience.Retry {
    const r = d.config.retry;
    return .{
        .attempts = r.attempts,
        .backoff = .{ .base = ms(r.base_ms), .max = ms(r.max_ms), .multiplier = r.multiplier },
        .attempt_timeout = if (r.attempt_timeout_ms > 0) ms(r.attempt_timeout_ms) else null,
        .max_retry_after = ms(r.max_retry_after_ms),
    };
}

fn openPostgres(d: *Db, app: *anole.App, p: config_mod.Config.Postgres) !void {
    const client = try app.postgres(anole.pg.Options{
        .url = p.url,
        .name = d.config.name,
        .max_connections = p.max_connections,
        .acquire_timeout = ms(p.acquire_timeout_ms),
        .connect_timeout = if (p.connect_timeout_ms > 0) ms(p.connect_timeout_ms) else null,
        .statement_cache_size = p.statement_cache_size,
        .max_lifetime = if (p.max_lifetime_ms > 0) ms(p.max_lifetime_ms) else null,
        .idle_timeout = if (p.idle_timeout_ms > 0) ms(p.idle_timeout_ms) else null,
        .sslmode = if (p.sslmode) |m| switch (config_mod.sslMode(m).?) {
            inline else => |t| @field(anole.pg.SslMode, @tagName(t)),
        } else null,
        .tls = tlsOf(p),
        .ping_timeout = ms(p.ping_timeout_ms),
        .timeout = callBound(d),
        .breaker = breakerOf(d),
        .retry = retryOf(d),
        .errors = d.config.errors,
        .connect_at_start = p.connect_at_start,
        .application_name = p.application_name,
        .reset_session = switch (p.reset_session) {
            inline else => |t| @field(anole.pg.Options.ResetSession, @tagName(t)),
        },
        .cache = .{
            .max_entries = d.config.cache.max_entries,
            .max_bytes = std.math.cast(usize, d.config.cache.max_bytes) orelse std.math.maxInt(usize),
        },
    });
    d.client = .{ .postgres = client };
    const script = p.init orelse return;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var ctx: db.Ctx = .{ .io = app.io(), .arena = arena.allocator() };
    client.execScript(&ctx, script) catch |err| {
        if (db.lastError(&ctx)) |detail| {
            log.err("databases \"{s}\": init failed: {f}", .{ d.config.name, detail });
        } else log.err("databases \"{s}\": init failed: {t}", .{ d.config.name, err });
        return err;
    };
}

fn openRedis(d: *Db, app: *anole.App, r: config_mod.Config.Redis) !void {
    const client = try app.redis(anole.redis.Options{
        .url = r.url,
        .name = d.config.name,
        .max_connections = r.max_connections,
        .acquire_timeout = ms(r.acquire_timeout_ms),
        .connect_timeout = if (r.connect_timeout_ms > 0) ms(r.connect_timeout_ms) else null,
        .idle_timeout = if (r.idle_timeout_ms > 0) ms(r.idle_timeout_ms) else null,
        .tls = tlsOf(r),
        .ping_timeout = ms(r.ping_timeout_ms),
        .timeout = callBound(d),
        .breaker = breakerOf(d),
        .retry = retryOf(d),
        .errors = d.config.errors,
        .connect_at_start = r.connect_at_start,
        .cache = .{
            .max_entries = d.config.cache.max_entries,
            .max_bytes = std.math.cast(usize, d.config.cache.max_bytes) orelse std.math.maxInt(usize),
        },
    });
    d.client = .{ .redis = client };
}

fn openMongodb(d: *Db, app: *anole.App, m: config_mod.Config.Mongodb) !void {
    const client = try app.mongodb(anole.mongodb.Options{
        .url = m.url,
        .database = m.database,
        .name = d.config.name,
        .tls = tlsOf(m),
        .max_connections = m.max_connections,
        .acquire_timeout = ms(m.acquire_timeout_ms),
        .server_selection_timeout = ms(m.server_selection_timeout_ms),
        .connect_timeout = optMs(m.connect_timeout_ms),
        .idle_timeout = optMs(m.idle_timeout_ms),
        .heartbeat = ms(m.heartbeat_ms),
        .retry_reads = m.retry_reads,
        .retry_writes = m.retry_writes,
        .connect_at_start = m.connect_at_start,
        .ping_timeout = ms(m.ping_timeout_ms),
        .timeout = callBound(d),
        .breaker = breakerOf(d),
        .retry = retryOf(d),
        .errors = d.config.errors,
        .cache = .{
            .max_entries = d.config.cache.max_entries,
            .max_bytes = std.math.cast(usize, d.config.cache.max_bytes) orelse std.math.maxInt(usize),
        },
    });
    d.client = .{ .mongodb = client };
}

/// The databases are closed with the server: no new query from now on.
pub fn close(e: *Engine) void {
    for (e.dbs) |*d| d.open.store(false, .release);
}

pub fn find(e: *Engine, name: []const u8) ?*Db {
    for (e.dbs) |*d| if (std.mem.eql(u8, d.config.name, name)) return d;
    return null;
}

pub const Verb = enum { query, exec };

pub const QueryError = error{ Invalid, State, OutOfMemory, Unsupported, Gone };

/// A query in flight: one allocation holding the command, the copied SQL,
/// parameters and cache tag.
const Query = struct {
    cmd: Command = .{ .run = run },
    d: *Db,
    verb: Verb,
    user_data: u64,
    flags: u32,
    timeout_ms: u32,
    cache_ttl_ms: u32,
    sql: []const u8,
    tag: ?[]const u8,
    params: []const db.Value,
    /// The request or call this query serves (`anole_db_options.req`), or 0.
    req: u64 = 0,
    tied: Tied = .{ .cut = cut },
    /// Set by the task as it starts.
    task: ?placement.Task = null,
    /// Why the query was cut, if it was.
    end: enum { none, request } = .none,
    /// Everything above points into this.
    arena: std.heap.ArenaAllocator,

    fn free(q: *Query) void {
        var arena = q.arena;
        arena.deinit();
    }

    /// The request ended unanswered (on its executor).
    fn cut(t: *Tied) void {
        const q: *Query = @fieldParentPtr("tied", t);
        q.end = .request;
        if (q.task) |tk| placement.cancelTask(tk);
    }

    fn run(cmd: *Command, x: *Exec) void {
        const q: *Query = @fieldParentPtr("cmd", cmd);
        if (x.engine.phase.load(.acquire) == .stopped) return q.free();
        if (q.req != 0) {
            const h = Handle.decode(q.req);
            if (!slotLive(x, h)) {
                postGone(x, q.user_data, 0, "the request it served ended first");
                return q.free();
            }
            linkTied(x, h.slot, &q.tied);
        }
        placement.concurrent(&x.db.work, x.engine.io, .local, task, .{ x, q }) catch {
            if (q.req != 0) unlinkTied(x, Handle.decode(q.req).slot, &q.tied);
            q.free();
        };
    }
};

/// An `ANOLE_E_GONE` answer: what a query or transaction call gets when the
/// request or transaction it served ended first.
fn postGone(x: *Exec, user_data: u64, handle: u64, message: []const u8) void {
    const a: Answer = .{ .user_data = user_data, .status = abi.E_GONE, .message = message };
    const rec = a.record(std.math.maxInt(u32), handle) catch return;
    x.postRecord(rec, false);
}

/// Queues `sql` for `c` (`anole_db_query`, `anole_db_exec`).
pub fn submit(d: *Db, c: ?*Consumer, verb: Verb, sql: []const u8, params: []const abi.DbValue, opts: abi.DbOptions, user_data: u64) QueryError!void {
    if (comptime !features.sqlite and !features.postgres and !features.redis and !features.mongodb) return error.Unsupported;
    const e = d.engine;
    if (c) |cc| if (cc.engine != e) return error.Invalid;
    switch (e.phase.load(.acquire)) {
        .open, .starting, .running, .draining => {},
        else => return error.State,
    }
    if (!d.open.load(.acquire)) return error.State;
    for (params) |p| if (p.type > abi.DB_TYPE_BOOL or p.reserved != 0) return error.Invalid;
    // With a request, the executor that serves it; else the next of the
    // consumer's, in turn.
    const x: *Exec = if (opts.req != 0) try resolveReq(e, opts.req, c) else blk: {
        const cc = c orelse return error.Invalid;
        if (cc.execs.items.len == 0) return error.State;
        const i = cc.next_db.fetchAdd(1, .monotonic) % cc.execs.items.len;
        break :blk cc.execs.items[i];
    };

    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const values = try a.alloc(db.Value, params.len);
    for (params, values) |p, *v| v.* = switch (p.type) {
        abi.DB_TYPE_NULL => .null,
        abi.DB_TYPE_INT => .{ .int = p.v.i },
        abi.DB_TYPE_FLOAT => .{ .float = p.v.f },
        abi.DB_TYPE_TEXT => .{ .text = try a.dupe(u8, p.v.s.slice()) },
        abi.DB_TYPE_BLOB => .{ .blob = try a.dupe(u8, p.v.s.slice()) },
        abi.DB_TYPE_BOOL => .{ .bool = p.v.i != 0 },
        else => unreachable,
    };
    const q = try a.create(Query);
    q.* = .{
        .d = d,
        .verb = verb,
        .user_data = user_data,
        .flags = opts.flags,
        .timeout_ms = opts.timeout_ms,
        .cache_ttl_ms = opts.cache_ttl_ms,
        .req = opts.req,
        .sql = try a.dupe(u8, sql),
        .tag = if (opts.cache_tag.len > 0) try a.dupe(u8, opts.cache_tag.slice()) else null,
        .params = values,
        .arena = undefined,
    };
    q.arena = arena;
    // Spread over the executors that feed `c`: each keeps its own cache.
    x.post(&q.cmd);
}

pub fn invalidate(d: *Db, tag: []const u8) error{State}!void {
    if (!d.open.load(.acquire)) return error.State;
    const cache = switch (d.client) {
        .none => return error.State,
        .sqlite => |client| if (comptime features.sqlite) &client.cache else unreachable,
        .postgres => |client| if (comptime features.postgres) &client.cache else unreachable,
        .redis => |client| if (comptime features.redis) &client.cache else unreachable,
        .mongodb => |client| if (comptime features.mongodb) &client.cache else unreachable,
    };
    if (tag.len == 0) cache.invalidate(.all) else cache.invalidate(.{ .tag = tag });
}

/// On the executor: runs the statement and queues the answer.
fn task(x: *Exec, q: *Query) std.Io.Cancelable!void {
    defer {
        if (q.req != 0) unlinkTied(x, Handle.decode(q.req).slot, &q.tied);
        q.free();
    }
    const e = x.engine;
    q.task = placement.currentTask(e.io);
    if (q.end == .request) return postGone(x, q.user_data, 0, "the request it served ended (aborted or past its deadline)");
    if (!q.d.open.load(.acquire)) return;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var ctx: db.Ctx = .{ .io = e.io, .arena = arena.allocator() };
    var options: db.QueryOptions = .{
        .write = q.flags & abi.DB_F_WRITE != 0,
        .prepare = q.flags & abi.DB_F_NO_PREPARE == 0,
        .coalesce = q.flags & abi.DB_F_COALESCE != 0,
        .retry = q.flags & abi.DB_F_RETRY != 0,
    };
    // Zero takes the database's bound (`databases[].timeout_ms`).
    if (q.timeout_ms == abi.DB_TIMEOUT_NONE) options.timeout = .max else if (q.timeout_ms > 0) options.timeout = .fromMilliseconds(q.timeout_ms);
    if (q.cache_ttl_ms > 0) options.cache = .{
        .ttl = .fromMilliseconds(q.cache_ttl_ms),
        .tag = q.tag,
        .keep_empty = q.flags & abi.DB_F_DROP_EMPTY == 0,
    };
    var answer: Answer = .{ .user_data = q.user_data };
    switch (q.d.client) {
        .none => return,
        inline .sqlite, .postgres => |client, kind| if (comptime @field(features, @tagName(kind))) {
            const with = client.with(options);
            switch (q.verb) {
                .query => if (with.table(&ctx, q.sql, q.params)) |t| {
                    answer.table = t;
                } else |err| answer.failed(&ctx, err),
                .exec => if (with.execValues(&ctx, q.sql, q.params)) |ch| {
                    answer.changes = ch;
                } else |err| answer.failed(&ctx, err),
            }
        } else unreachable,
        .redis => |client| if (comptime features.redis) {
            const with = client.with(options);
            if (redisArgs(ctx.arena, q.sql, q.params)) |args| {
                if (with.reply(&ctx, args)) |reply| switch (q.verb) {
                    .query => answer.reply = reply,
                    // The reply's count, when it is one (DEL, INCR...).
                    .exec => answer.changes = .{ .changes = switch (reply) {
                        .int => |n| @intCast(@max(n, 0)),
                        else => 0,
                    } },
                } else |err| answer.failed(&ctx, err);
            } else |err| answer.failed(&ctx, err);
        } else unreachable,
        .mongodb => |client| if (comptime features.mongodb) {
            if (mongoCall(client.with(options), &ctx, q.sql, q.params)) |result| switch (q.verb) {
                .query => answer.mongo = result,
                .exec => answer.changes = .{ .changes = switch (result) {
                    .documents => |docs| docs.len,
                    .count => |n| n,
                    .write => |w| w.changes,
                } },
            } else |err| answer.failed(&ctx, err);
        } else unreachable,
    }
    if (db.lastSource(&ctx)) |src| answer.source = switch (src) {
        .database => abi.DB_FROM_DATABASE,
        .coalesced => abi.DB_FROM_COALESCED,
        .cache => abi.DB_FROM_CACHE,
    };
    // Cut with its request: the answer is GONE. Canceled at the stop, it
    // answers nothing: the consumer's last event is ANOLE_EV_STOPPED.
    if (answer.canceled) {
        if (q.end == .request) return postGone(x, q.user_data, 0, "the request it served ended (aborted or past its deadline)");
        return error.Canceled;
    }
    postAnswer(x, &answer, 0);
}

/// Queues `a` as a record (`handle` the transaction it concerns, or 0),
/// waiting for room in the ring: an answer must arrive.
fn postAnswer(x: *Exec, a: *const Answer, handle: u64) void {
    const rec = a.record(x.engine.config.limits.db_result_max, handle) catch |err| switch (err) {
        error.TooBig => (Answer{ .user_data = a.user_data, .status = abi.E_TOOBIG, .http_status = 500, .error_class = .other, .message = "the answer is larger than limits.db_result_max" }).record(std.math.maxInt(u32), handle) catch return,
        error.OutOfMemory => (Answer{ .user_data = a.user_data, .status = abi.E_NOMEM, .http_status = 500, .error_class = .other }).record(std.math.maxInt(u32), handle) catch return,
    };
    x.postRecord(rec, true);
}

/// What goes into the record.
pub const Answer = struct {
    user_data: u64,
    status: i32 = abi.OK,
    http_status: u16 = 0,
    error_class: abi.DbErrorClass = .none,
    source: u8 = abi.DB_FROM_DATABASE,
    table: ?db.Table = null,
    changes: ?db.Changes = null,
    reply: ?redis.Reply = null,
    mongo: ?mongodb.dynamic.Result = null,
    message: []const u8 = "",
    code: []const u8 = "",
    constraint: []const u8 = "",
    table_name: []const u8 = "",
    canceled: bool = false,

    fn failed(a: *Answer, ctx: *db.Ctx, err: anyerror) void {
        if (err == error.Canceled) {
            a.canceled = true;
            return;
        }
        a.status = abi.E_DB;
        a.http_status = switch (err) {
            error.NotFound => 404,
            error.Conflict => 409,
            error.ServiceUnavailable => 503,
            error.GatewayTimeout => 504,
            error.BadRequest => 400,
            error.UnprocessableEntity => 422,
            else => 500,
        };
        if (db.lastError(ctx)) |detail| {
            a.error_class = std.meta.stringToEnum(abi.DbErrorClass, @tagName(detail.class)) orelse .other;
            a.message = detail.message;
            a.code = detail.code;
            a.constraint = detail.constraint orelse "";
            a.table_name = detail.table orelse "";
        } else {
            a.error_class = if (err == error.GatewayTimeout) .timeout else .other;
            a.message = @errorName(err);
        }
        if (err == error.OutOfMemory) a.status = abi.E_NOMEM;
        if (err == error.GatewayTimeout and a.error_class == .timeout) a.status = abi.E_TIMEOUT;
    }

    /// The record: header, column names, cells, then the bytes.
    fn record(a: *const Answer, max: u32, handle: u64) error{ TooBig, OutOfMemory }![]align(8) u8 {
        const Ev = abi.DbResultEvent;
        var ncol: usize = 0;
        var nrows: usize = 0;
        var bytes: usize = a.message.len + a.code.len + a.constraint.len + a.table_name.len;
        if (a.table) |t| {
            ncol = t.columns.len;
            nrows = t.rows.len;
            for (t.columns) |n| bytes += n.len;
            for (t.rows) |row| for (row) |v| switch (v) {
                .text, .blob => |s| bytes += s.len,
                else => {},
            };
        }
        if (comptime features.redis) if (a.reply) |r| {
            nrows = replyCells(r, &bytes);
        };
        // MongoDB: one column, a BSON document (or the count) per row.
        if (comptime features.mongodb) if (a.mongo) |m| {
            ncol = 1;
            bytes += mongo_column.len;
            switch (m) {
                .documents => |docs| {
                    nrows = docs.len;
                    for (docs) |doc| bytes += doc.bytes.len;
                },
                .count => nrows = 1,
                .write => |w| {
                    nrows = 1;
                    bytes += w.summary.bytes.len;
                },
            }
        };
        const cols_off = @sizeOf(Ev);
        const cells_off = cols_off + ncol * @sizeOf(abi.Span);
        // A Redis reply has no columns: its cells are a tree in preorder.
        const ncells = if (a.reply != null) nrows else std.math.mul(usize, ncol, nrows) catch return error.TooBig;
        const bytes_off = cells_off + ncells * @sizeOf(abi.DbCell);
        const total = bytes_off + bytes;
        if (total > max) return error.TooBig;
        const rec = engine.newRecord(total, .db_result, handle) catch return error.OutOfMemory;
        const ev: *Ev = @ptrCast(rec.ptr);
        var w: Writer = .{ .rec = rec, .at = bytes_off };
        ev.user_data = a.user_data;
        ev.status = a.status;
        ev.http_status = a.http_status;
        ev.error_class = @backingInt(a.error_class);
        ev.source = a.source;
        ev.ncolumns = @intCast(ncol);
        ev.nrows = @intCast(nrows);
        if (a.changes) |ch| {
            ev.changes = ch.changes;
            ev.last_insert_rowid = ch.last_insert_rowid;
        }
        ev.columns = .{ .off = @intCast(cols_off), .len = @intCast(ncol * @sizeOf(abi.Span)) };
        ev.cells = .{ .off = @intCast(cells_off), .len = @intCast(ncells * @sizeOf(abi.DbCell)) };
        ev.@"error" = w.put(a.message);
        ev.error_code = w.put(a.code);
        ev.constraint = w.put(a.constraint);
        ev.table = w.put(a.table_name);
        if (comptime features.redis) if (a.reply) |r| {
            const cells: [*]abi.DbCell = @ptrCast(@alignCast(rec.ptr + cells_off));
            var k: usize = 0;
            putReply(r, cells, &k, &w);
        };
        if (comptime features.mongodb) if (a.mongo) |m| {
            const names: [*]abi.Span = @ptrCast(@alignCast(rec.ptr + cols_off));
            names[0] = w.put(mongo_column);
            const cells: [*]abi.DbCell = @ptrCast(@alignCast(rec.ptr + cells_off));
            switch (m) {
                .documents => |docs| for (docs, 0..) |doc, i| {
                    cells[i] = .{ .type = abi.DB_TYPE_BSON, .v = .{ .s = w.put(doc.bytes) } };
                },
                .count => |n| cells[0] = .{ .type = abi.DB_TYPE_INT, .v = .{ .i = @intCast(@min(n, std.math.maxInt(i64))) } },
                .write => |wr| cells[0] = .{ .type = abi.DB_TYPE_BSON, .v = .{ .s = w.put(wr.summary.bytes) } },
            }
        };
        if (a.table) |t| {
            const names: [*]abi.Span = @ptrCast(@alignCast(rec.ptr + cols_off));
            for (t.columns, 0..) |n, i| names[i] = w.put(n);
            const cells: [*]abi.DbCell = @ptrCast(@alignCast(rec.ptr + cells_off));
            var k: usize = 0;
            for (t.rows) |row| for (row, 0..) |v, col| {
                cells[k] = switch (v) {
                    .null => .{ .type = abi.DB_TYPE_NULL, .v = .{ .i = 0 } },
                    .int => |n| .{ .type = abi.DB_TYPE_INT, .v = .{ .i = n } },
                    .float => |f| .{ .type = abi.DB_TYPE_FLOAT, .v = .{ .f = f } },
                    .bool => |b| .{ .type = abi.DB_TYPE_BOOL, .v = .{ .i = @intFromBool(b) } },
                    .text => |s| .{ .type = abi.DB_TYPE_TEXT, .v = .{ .s = w.put(s) } },
                    .blob => |s| .{ .type = abi.DB_TYPE_BLOB, .v = .{ .s = w.put(s) } },
                };
                if (col < t.types.len) cells[k].db_type = t.types[col];
                k += 1;
            };
        }
        return rec;
    }
};

/// The cells `r` takes (itself and every item under it), adding the bytes
/// of its strings to `bytes`.
fn replyCells(r: redis.Reply, bytes: *usize) usize {
    switch (r) {
        .status, .err, .string => |str| bytes.* += str.len,
        .array, .map => |items| {
            var n: usize = 1;
            for (items) |item| n += replyCells(item, bytes);
            return n;
        },
        else => {},
    }
    return 1;
}

/// `r` and its items in preorder from `cells[k.*]`.
fn putReply(r: redis.Reply, cells: [*]abi.DbCell, k: *usize, w: *Writer) void {
    const at = k.*;
    k.* += 1;
    cells[at] = switch (r) {
        .nil => .{ .type = abi.DB_TYPE_NULL, .v = .{ .i = 0 } },
        .int => |n| .{ .type = abi.DB_TYPE_INT, .v = .{ .i = n } },
        .double => |f| .{ .type = abi.DB_TYPE_FLOAT, .v = .{ .f = f } },
        .boolean => |b| .{ .type = abi.DB_TYPE_BOOL, .v = .{ .i = @intFromBool(b) } },
        .status => |str| .{ .type = abi.DB_TYPE_TEXT, .v = .{ .s = w.put(str) } },
        .string => |str| .{ .type = abi.DB_TYPE_BLOB, .v = .{ .s = w.put(str) } },
        .err => |str| .{ .type = abi.DB_TYPE_ERROR, .v = .{ .s = w.put(str) } },
        .array => |items| .{ .type = abi.DB_TYPE_ARRAY, .v = .{ .i = @intCast(items.len) } },
        // RESP3 maps hold key, value, key, value...
        .map => |items| .{ .type = abi.DB_TYPE_MAP, .v = .{ .i = @intCast(items.len / 2) } },
    };
    switch (r) {
        .array, .map => |items| for (items) |item| putReply(item, cells, k, w),
        else => {},
    }
}

/// The name of a MongoDB answer's one column.
const mongo_column = "document";

/// A MongoDB call from `anole_db_*`: `sql` names the operation, the
/// collection and, optionally, another database than the default
/// ("find users", "aggregate events analytics"; `runCommand` takes only
/// the database, optionally); each parameter is a BSON document (a blob).
fn mongoCall(q: anole.mongodb.Query, ctx: *db.Ctx, sql: []const u8, params: []const db.Value) anole.mongodb.Error!anole.mongodb.dynamic.Result {
    const dyn = anole.mongodb.dynamic;
    var words = std.mem.tokenizeAny(u8, sql, " \t\r\n");
    const name = words.next() orelse return mongoBad(ctx, "an empty operation: \"find <collection>\", \"insertOne <collection>\"...", .{});
    const op = std.meta.stringToEnum(dyn.Op, name) orelse return mongoBad(ctx, "unknown operation \"{s}\": find, findOne, aggregate, countDocuments, insertOne, insertMany, updateOne, updateMany, replaceOne, deleteOne, deleteMany, runCommand", .{name});
    var collection_name: []const u8 = "";
    if (op != .runCommand) collection_name = words.next() orelse return mongoBad(ctx, "{s}: name the collection (\"{s} <collection>\")", .{ name, name });
    const database_name = words.next();
    if (words.next() != null) return mongoBad(ctx, "\"{s}\": an operation, a collection and a database at most", .{sql});
    const docs = try ctx.arena.alloc(bson.Document, params.len);
    for (params, docs, 1..) |p, *doc, i| {
        const bytes = switch (p) {
            .blob => |b| b,
            else => return mongoBad(ctx, "{s}: parameter {d} is not a BSON document (ANOLE_DB_BLOB)", .{ name, i }),
        };
        doc.* = bson.Document.init(bytes) catch |err| return mongoBad(ctx, "{s}: parameter {d} is not a valid BSON document ({t})", .{ name, i, err });
    }
    const database = if (database_name) |n| q.db(n) else q.db(q.client.default_database);
    return dyn.run(database.collection(collection_name), database, ctx, op, docs);
}

fn mongoBad(ctx: *db.Ctx, comptime fmt: []const u8, args: anytype) anole.mongodb.Error {
    return anole.mongodb.dynamic.badRequest(ctx, fmt, args);
}

/// A Redis command from a call: the words of `sql` (the command's name
/// and any fixed words), then each parameter as bytes: text and blobs as
/// they are, numbers in decimal, a bool as 1 or 0, null left out.
fn redisArgs(a: std.mem.Allocator, sql: []const u8, params: []const db.Value) error{ OutOfMemory, BadRequest }![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    var words = std.mem.tokenizeAny(u8, sql, " \t\r\n");
    while (words.next()) |word| try args.append(a, word);
    if (args.items.len == 0) return error.BadRequest;
    for (params) |p| try args.append(a, switch (p) {
        .null => continue,
        .text, .blob => |b| b,
        .int => |n| try std.fmt.allocPrint(a, "{d}", .{n}),
        .float => |f| try std.fmt.allocPrint(a, "{d}", .{f}),
        .bool => |b| if (b) "1" else "0",
    });
    return args.items;
}

const Writer = struct {
    rec: []u8,
    at: usize,

    fn put(w: *Writer, bytes: []const u8) abi.Span {
        if (bytes.len == 0) return .{};
        @memcpy(w.rec[w.at..][0..bytes.len], bytes);
        defer w.at += bytes.len;
        return .{ .off = @intCast(w.at), .len = @intCast(bytes.len) };
    }
};

// ---------------------------------------------------------------------------
// Transactions (`anole_db_begin` and `anole_db_tx_*`)
//
// One task per open transaction, on the executor that began it, owns the
// connection (`sqlite.Tx` or `pg.Tx`). What the consumer sends (statements,
// the commit) waits in the slot's queue, in the order made, and the task
// runs it one at a time; each answer is an ANOLE_EV_DB_RESULT whose
// ev.handle is the transaction.

const TxEnd = enum(u8) { none, released, request, timeout, stopped };
const TxState = enum(u32) { free, open, closing };

fn packTx(gen: u32, state: TxState) u64 {
    return (@as(u64, gen) << 32) | @backingInt(state);
}

const tx_chunk_len = 64;
const tx_max_chunks = 1024;
comptime {
    std.debug.assert(tx_chunk_len * tx_max_chunks <= engine.max_slots);
}

pub const TxWhat = enum {
    query,
    exec,
    commit,
    rollback,
    /// `anole_jobs_enqueue` with a transaction (jobs.zig).
    job_enqueue,
    /// `anole_job_complete_in` with a transaction (jobs.zig).
    job_complete,
    /// `anole_webhooks_publish` with a transaction (webhooks.zig).
    webhook_publish,
};

/// A call on an open transaction, from the consumer.
pub const TxOp = struct {
    cmd: Command = .{ .run = run },
    next: ?*TxOp = null,
    slot: u32,
    gen: u32,
    what: TxWhat,
    user_data: u64,
    sql: []const u8 = "",
    params: []const db.Value = &.{},
    prepare: bool = true,
    timeout_ms: u32 = 0,
    /// Everything above points into this.
    arena: std.heap.ArenaAllocator,

    fn free(op: *TxOp) void {
        var arena = op.arena;
        arena.deinit();
    }

    /// On the transaction's executor: onto its queue.
    fn run(cmd: *Command, x: *Exec) void {
        const op: *TxOp = @fieldParentPtr("cmd", cmd);
        if (x.engine.phase.load(.acquire) == .stopped) return op.free();
        const t = x.db.txs.slot(op.slot) orelse {
            postGone(x, op.user_data, 0, "the transaction is over");
            return op.free();
        };
        const w = t.word.load(.acquire);
        if (@as(u32, @intCast(w >> 32)) != op.gen or t.done) {
            postGone(x, op.user_data, 0, "the transaction is over");
            return op.free();
        }
        if (t.tail) |tail| tail.next = op else t.head = op;
        t.tail = op;
        x.setEvent(&t.event);
    }
};

pub const TxSlot = struct {
    /// Generation and state; read by any thread.
    word: std.atomic.Value(u64) = .init(packTx(1, .free)),
    /// Why it ends (`TxEnd`): the first to say wins.
    end: std.atomic.Value(u8) = .init(0),
    exec: *Exec = undefined,
    index: u32 = 0,
    next_free: u32 = engine.no_slot,

    // Executor-local from here.
    d: *Db = undefined,
    head: ?*TxOp = null,
    tail: ?*TxOp = null,
    /// Set when an op arrives, or the transaction is to end.
    event: std.Io.Event = .unset,
    task: ?placement.Task = null,
    /// The task is past its last op: later ones are answered GONE.
    done: bool = false,
    /// Awake-clock nanoseconds, or none.
    deadline: ?i96 = null,
    tied: Tied = .{ .cut = cutTx },
    req_slot: u32 = 0,
    has_req: bool = false,

    fn gen(t: *const TxSlot) u32 {
        return @intCast(t.word.load(.acquire) >> 32);
    }

    fn handle(t: *const TxSlot, g: u32) u64 {
        return Handle.encode(.{ .gen = @intCast(g), .kind = .db_tx, .slot = @intCast(t.index), .exec = t.exec.index });
    }

    fn setEnd(t: *TxSlot, how: TxEnd) void {
        _ = t.end.cmpxchgStrong(0, @backingInt(how), .acq_rel, .acquire);
    }

    fn endNow(t: *const TxSlot) TxEnd {
        return @fromBackingInt(t.end.load(.acquire));
    }

    /// On the executor: wakes the task out of whatever it waits in.
    fn wake(t: *TxSlot) void {
        t.exec.setEvent(&t.event);
        if (t.task) |tk| placement.cancelTask(tk);
    }
};

fn cutTx(tied: *Tied) void {
    const t: *TxSlot = @alignCast(@fieldParentPtr("tied", tied));
    if (t.done) return;
    t.setEnd(.request);
    t.wake();
}

const TxChunk = [tx_chunk_len]TxSlot;

pub const TxTable = struct {
    chunks: [tx_max_chunks]std.atomic.Value(?*TxChunk) = @splat(.init(null)),
    nchunks: std.atomic.Value(u32) = .init(0),
    free_head: u32 = engine.no_slot,

    fn slot(t: *TxTable, i: u32) ?*TxSlot {
        // `i` may come from a made-up handle.
        if (i / tx_chunk_len >= tx_max_chunks) return null;
        const c = t.chunks[i / tx_chunk_len].load(.acquire) orelse return null;
        return &c[i % tx_chunk_len];
    }

    fn alloc(t: *TxTable, x: *Exec) !*TxSlot {
        if (t.free_head == engine.no_slot) {
            const n = t.nchunks.load(.monotonic);
            if (n == tx_max_chunks) return error.TooManyTransactions;
            const c = try gpa.create(TxChunk);
            const base = n * tx_chunk_len;
            for (c, 0..) |*s, j| s.* = .{
                .word = .init(packTx(x.engine.first_gen, .free)),
                .exec = x,
                .index = @intCast(base + j),
                .next_free = if (j + 1 < tx_chunk_len) @intCast(base + j + 1) else engine.no_slot,
            };
            t.chunks[n].store(c, .release);
            t.nchunks.store(n + 1, .release);
            t.free_head = base;
        }
        const s = t.slot(t.free_head).?;
        t.free_head = s.next_free;
        return s;
    }

    /// Any thread, at the stop: every open transaction ends without
    /// answering.
    fn markStopped(t: *TxTable) void {
        for (t.chunks[0..t.nchunks.load(.acquire)]) |*cv| {
            for (cv.load(.acquire).?) |*s| {
                if (@as(TxState, @fromBackingInt(@intCast(s.word.load(.acquire) & 0xFFFFFFFF))) != .free) s.setEnd(.stopped);
            }
        }
    }

    fn maxGen(t: *const TxTable) u32 {
        var max: u32 = 0;
        for (t.chunks[0..t.nchunks.load(.acquire)]) |*cv| {
            for (cv.load(.acquire).?) |*s| max = @max(max, s.gen());
        }
        return max;
    }

    fn deinit(t: *TxTable) void {
        for (t.chunks[0..t.nchunks.load(.acquire)]) |*cv| gpa.destroy(cv.load(.acquire).?);
        t.nchunks.store(0, .release);
    }
};

/// The two SQL connectors' transactions behind one type.
pub const AnyTx = union(enum) {
    sqlite: sqlite.Tx,
    postgres: pg.Tx,

    fn table(a: *AnyTx, ctx: *db.Ctx, sql: []const u8, values: []const db.Value, opts: db.QueryOptions) anyerror!db.Table {
        switch (a.*) {
            inline else => |*tx, tag| if (comptime @field(features, @tagName(tag))) {
                return tx.with(opts).table(ctx, sql, values);
            } else unreachable,
        }
    }

    fn run(a: *AnyTx, ctx: *db.Ctx, sql: []const u8, values: []const db.Value, opts: db.QueryOptions) anyerror!db.Changes {
        switch (a.*) {
            inline else => |*tx, tag| if (comptime @field(features, @tagName(tag))) {
                return tx.with(opts).execValues(ctx, sql, values);
            } else unreachable,
        }
    }

    fn commit(a: *AnyTx, ctx: *db.Ctx) anyerror!void {
        switch (a.*) {
            inline else => |*tx, tag| if (comptime @field(features, @tagName(tag))) {
                return tx.commit(ctx);
            } else unreachable,
        }
    }

    fn rollback(a: *AnyTx, ctx: *db.Ctx) anyerror!void {
        switch (a.*) {
            inline else => |*tx, tag| if (comptime @field(features, @tagName(tag))) {
                return tx.rollback(ctx);
            } else unreachable,
        }
    }

    /// Rolls back unless committed, and gives the connection back.
    fn deinit(a: *AnyTx) void {
        switch (a.*) {
            inline else => |*tx, tag| if (comptime @field(features, @tagName(tag))) {
                tx.deinit();
            } else unreachable,
        }
    }
};

const TxStart = struct {
    user_data: u64,
    flags: u32,
    isolation: u32,
    timeout_ms: u32,
};

/// `anole_db_begin` (any thread).
pub fn begin(d: *Db, c: ?*Consumer, opts: abi.DbTxOptions, user_data: u64) QueryError!void {
    if (comptime !features.sqlite and !features.postgres) return error.Unsupported;
    if (d.config.sqlite == null and d.config.postgres == null) return error.Unsupported;
    const e = d.engine;
    if (c) |cc| if (cc.engine != e) return error.Invalid;
    if (opts.flags & ~abi.DB_TX_READ_ONLY != 0 or opts.isolation > abi.DB_ISOLATION_SERIALIZABLE or opts.reserved != 0) return error.Invalid;
    switch (e.phase.load(.acquire)) {
        .open, .starting, .running, .draining => {},
        else => return error.State,
    }
    if (!d.open.load(.acquire)) return error.State;
    const x: *Exec = if (opts.req != 0) try resolveReq(e, opts.req, c) else blk: {
        const cc = c orelse return error.Invalid;
        if (cc.execs.items.len == 0) return error.State;
        const i = cc.next_db.fetchAdd(1, .monotonic) % cc.execs.items.len;
        break :blk cc.execs.items[i];
    };
    const b = try gpa.create(BeginCmd);
    b.* = .{ .d = d, .start = .{ .user_data = user_data, .flags = opts.flags, .isolation = opts.isolation, .timeout_ms = opts.timeout_ms }, .req = opts.req };
    x.post(&b.cmd);
}

const BeginCmd = struct {
    cmd: Command = .{ .run = run },
    d: *Db,
    start: TxStart,
    req: u64,

    fn run(cmd: *Command, x: *Exec) void {
        const b: *BeginCmd = @fieldParentPtr("cmd", cmd);
        defer gpa.destroy(b);
        if (x.engine.phase.load(.acquire) == .stopped) return;
        var req_slot: u32 = 0;
        if (b.req != 0) {
            const h = Handle.decode(b.req);
            if (!slotLive(x, h)) return postGone(x, b.start.user_data, 0, "the request it served ended first");
            req_slot = h.slot;
        }
        const t = x.db.txs.alloc(x) catch {
            const a: Answer = .{ .user_data = b.start.user_data, .status = abi.E_NOMEM, .http_status = 500, .error_class = .other, .message = "too many open transactions" };
            return postAnswerNoWait(x, &a);
        };
        const g = t.gen();
        t.d = b.d;
        t.head = null;
        t.tail = null;
        t.event = .unset;
        t.task = null;
        t.done = false;
        t.deadline = null;
        t.end.store(0, .release);
        t.has_req = b.req != 0;
        t.req_slot = req_slot;
        t.tied = .{ .cut = cutTx };
        if (t.has_req) linkTied(x, req_slot, &t.tied);
        t.word.store(packTx(g, .open), .release);
        placement.concurrent(&x.db.work, x.engine.io, .local, txTask, .{ x, t, b.start }) catch {
            if (t.has_req) unlinkTied(x, req_slot, &t.tied);
            freeTx(x, t, g);
            const a: Answer = .{ .user_data = b.start.user_data, .status = abi.E_NOMEM, .http_status = 500, .error_class = .other, .message = "could not start the transaction's task" };
            postAnswerNoWait(x, &a);
        };
    }
};

fn postAnswerNoWait(x: *Exec, a: *const Answer) void {
    const rec = a.record(std.math.maxInt(u32), 0) catch return;
    x.postRecord(rec, false);
}

/// The slot goes back to the free list under a new generation.
fn freeTx(x: *Exec, t: *TxSlot, g: u32) void {
    t.task = null;
    t.word.store(packTx(engine.nextGen(g), .free), .release);
    t.next_free = x.db.txs.free_head;
    x.db.txs.free_head = t.index;
}

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

/// `func(args...)` within what is left of the transaction's time.
fn inTime(t: *TxSlot, io: std.Io, comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) dusty.Deadline.Result(func) {
    const dl = t.deadline orelse return @call(.auto, func, args);
    const left = dl - nowNs(io);
    if (left <= 0) return error.Timeout;
    const d: dusty.Deadline = .init(io, .{ .duration = .{ .raw = .{ .nanoseconds = left }, .clock = .awake } });
    return d.run(func, args);
}

fn beginTx(d: *Db, ctx: *db.Ctx, st: TxStart) anyerror!AnyTx {
    const iso: ?db.Isolation = switch (st.isolation) {
        abi.DB_ISOLATION_READ_UNCOMMITTED => .read_uncommitted,
        abi.DB_ISOLATION_READ_COMMITTED => .read_committed,
        abi.DB_ISOLATION_REPEATABLE_READ => .repeatable_read,
        abi.DB_ISOLATION_SERIALIZABLE => .serializable,
        else => null,
    };
    // The transaction's own time is the task's; the connector adds none.
    const opts: db.TxOptions = .{ .isolation = iso, .read_only = st.flags & abi.DB_TX_READ_ONLY != 0, .timeout = .max };
    switch (d.client) {
        .sqlite => |client| if (comptime features.sqlite) return .{ .sqlite = try client.begin(ctx, opts) } else unreachable,
        .postgres => |client| if (comptime features.postgres) return .{ .postgres = try client.begin(ctx, opts) } else unreachable,
        else => return error.Unsupported,
    }
}

fn runOp(any: *AnyTx, ctx: *db.Ctx, op: *const TxOp, answer: *Answer) anyerror!void {
    var o: db.QueryOptions = .{ .prepare = op.prepare };
    if (op.timeout_ms == abi.DB_TIMEOUT_NONE) o.timeout = .max else if (op.timeout_ms > 0) o.timeout = .fromMilliseconds(op.timeout_ms);
    switch (op.what) {
        .query => answer.table = try any.table(ctx, op.sql, op.params, o),
        .exec => answer.changes = try any.run(ctx, op.sql, op.params, o),
        .commit => try any.commit(ctx),
        .rollback => try any.rollback(ctx),
        .job_enqueue, .job_complete => try jobs.txOp(any, ctx, op, answer),
        .webhook_publish => try webhooks.txOp(any, ctx, op, answer),
    }
}

/// What the transaction's ending says to a call that never ran.
fn endAnswer(t: *const TxSlot, user_data: u64) ?Answer {
    return switch (t.endNow()) {
        .stopped => null,
        .timeout => .{ .user_data = user_data, .status = abi.E_TIMEOUT, .http_status = 504, .error_class = .timeout, .message = "the transaction ran past its timeout and was rolled back" },
        .request => .{ .user_data = user_data, .status = abi.E_GONE, .message = "the request it served ended (aborted or past its deadline); the transaction was rolled back" },
        .released, .none => .{ .user_data = user_data, .status = abi.E_GONE, .message = "the transaction was released or is over" },
    };
}

/// On the transaction's executor, for its whole life.
fn txTask(x: *Exec, t: *TxSlot, st: TxStart) std.Io.Cancelable!void {
    const io = x.engine.io;
    const g = t.gen();
    const handle = t.handle(g);
    t.task = placement.currentTask(io);
    var begin_arena: std.heap.ArenaAllocator = .init(gpa);
    defer begin_arena.deinit();
    var bctx: db.Ctx = .{ .io = io, .arena = begin_arena.allocator() };

    const bound_ms: u32 = if (st.timeout_ms == abi.DB_TIMEOUT_NONE) 0 else if (st.timeout_ms > 0) st.timeout_ms else t.d.config.timeout_ms;
    if (bound_ms > 0) t.deadline = nowNs(io) + @as(i96, bound_ms) * std.time.ns_per_ms;

    var any: ?AnyTx = null;
    if (t.endNow() == .none and t.d.open.load(.acquire)) {
        var a: Answer = .{ .user_data = st.user_data };
        if (inTime(t, io, beginTx, .{ t.d, &bctx, st })) |tx| {
            any = tx;
        } else |err| switch (err) {
            error.Timeout => {
                t.setEnd(.timeout);
                a = .{ .user_data = st.user_data, .status = abi.E_TIMEOUT, .http_status = 504, .error_class = .timeout, .message = "the transaction could not begin within its timeout" };
            },
            else => a.failed(&bctx, err),
        }
        if (any != null) {
            postAnswer(x, &a, handle);
        } else if (a.canceled) {
            if (endAnswer(t, st.user_data)) |ga| postAnswer(x, &ga, 0);
        } else {
            postAnswer(x, &a, 0);
        }
    } else if (endAnswer(t, st.user_data)) |ga| postAnswer(x, &ga, 0);

    // The statements, in the order made, until the commit or rollback.
    if (any) |*tx| {
        loop: while (t.endNow() == .none) {
            const op = t.head orelse {
                t.event.reset();
                const timeout: std.Io.Timeout = if (t.deadline) |dl|
                    .{ .duration = .{ .raw = .{ .nanoseconds = @max(dl - nowNs(io), 0) }, .clock = .awake } }
                else
                    .none;
                t.event.waitTimeout(io, timeout) catch |err| switch (err) {
                    error.Timeout => t.setEnd(.timeout),
                    error.Canceled => {},
                };
                continue :loop;
            };
            t.head = op.next;
            if (t.head == null) t.tail = null;
            defer op.free();
            var op_arena: std.heap.ArenaAllocator = .init(gpa);
            defer op_arena.deinit();
            var ctx: db.Ctx = .{ .io = io, .arena = op_arena.allocator() };
            var a: Answer = .{ .user_data = op.user_data };
            inTime(t, io, runOp, .{ tx, &ctx, op, &a }) catch |err| switch (err) {
                error.Timeout => t.setEnd(.timeout),
                else => a.failed(&ctx, err),
            };
            if (t.endNow() != .none or a.canceled) {
                // Cut short: this call is answered by how the transaction ended.
                if (endAnswer(t, op.user_data)) |ga| postAnswer(x, &ga, handle);
                break :loop;
            }
            postAnswer(x, &a, handle);
            if (op.what == .commit or op.what == .rollback) break :loop;
        }
    }

    // Over: later calls are answered GONE, the ones queued by the ending.
    t.done = true;
    while (t.head) |op| {
        t.head = op.next;
        if (endAnswer(t, op.user_data)) |ga| postAnswer(x, &ga, handle);
        op.free();
    }
    t.tail = null;
    if (any) |*tx| tx.deinit();
    if (t.has_req) unlinkTied(x, t.req_slot, &t.tied);
    freeTx(x, t, g);
}

fn txSlotOf(e: *Engine, h: Handle) ?*TxSlot {
    if (h.exec >= e.execs.len) return null;
    return e.execs[h.exec].db.txs.slot(h.slot);
}

/// A call on the open transaction `hv`: `anole_db_tx_query` and `_exec`.
pub fn txSubmit(e: *Engine, hv: u64, what: TxWhat, sql: []const u8, params: []const abi.DbValue, opts: abi.DbOptions, user_data: u64) QueryError!void {
    const h = Handle.decode(hv);
    for (params) |p| if (p.type > abi.DB_TYPE_BOOL or p.reserved != 0) return error.Invalid;
    if (opts.cache_ttl_ms != 0 or opts.cache_tag.len != 0 or opts.req != 0 or opts.flags & ~abi.DB_F_NO_PREPARE != 0) return error.Invalid;
    const t = txSlotOf(e, h) orelse return error.Gone;
    const w = t.word.load(.acquire);
    if (@as(u32, @intCast(w >> 32)) != h.gen or @as(TxState, @fromBackingInt(@intCast(w & 0xFFFFFFFF))) != .open) return error.Gone;
    if (e.phase.load(.acquire) == .stopped) return error.Gone;

    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const values = try a.alloc(db.Value, params.len);
    for (params, values) |p, *v| v.* = switch (p.type) {
        abi.DB_TYPE_NULL => .null,
        abi.DB_TYPE_INT => .{ .int = p.v.i },
        abi.DB_TYPE_FLOAT => .{ .float = p.v.f },
        abi.DB_TYPE_TEXT => .{ .text = try a.dupe(u8, p.v.s.slice()) },
        abi.DB_TYPE_BLOB => .{ .blob = try a.dupe(u8, p.v.s.slice()) },
        abi.DB_TYPE_BOOL => .{ .bool = p.v.i != 0 },
        else => unreachable,
    };
    const op = try a.create(TxOp);
    op.* = .{
        .slot = h.slot,
        .gen = h.gen,
        .what = what,
        .user_data = user_data,
        .sql = try a.dupe(u8, sql),
        .params = values,
        .prepare = opts.flags & abi.DB_F_NO_PREPARE == 0,
        .timeout_ms = opts.timeout_ms,
        .arena = undefined,
    };
    op.arena = arena;
    t.exec.post(&op.cmd);
}

/// `anole_db_tx_commit` and `_rollback`: from here the handle takes no more
/// calls.
pub fn txFinish(e: *Engine, hv: u64, what: TxWhat, user_data: u64) QueryError!void {
    const h = Handle.decode(hv);
    const t = txSlotOf(e, h) orelse return error.Gone;
    var w = t.word.load(.acquire);
    while (true) {
        if (@as(u32, @intCast(w >> 32)) != h.gen or @as(TxState, @fromBackingInt(@intCast(w & 0xFFFFFFFF))) != .open) return error.Gone;
        w = t.word.cmpxchgWeak(w, packTx(h.gen, .closing), .acq_rel, .acquire) orelse break;
    }
    if (e.phase.load(.acquire) == .stopped) return error.Gone;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const op = try arena.allocator().create(TxOp);
    op.* = .{ .slot = h.slot, .gen = h.gen, .what = what, .user_data = user_data, .arena = arena };
    t.exec.post(&op.cmd);
}

const ReleaseCmd = struct {
    cmd: Command = .{ .run = run },
    slot: u32,
    gen: u32,

    fn run(cmd: *Command, x: *Exec) void {
        const r: *ReleaseCmd = @fieldParentPtr("cmd", cmd);
        defer gpa.destroy(r);
        if (x.engine.phase.load(.acquire) == .stopped) return;
        const t = x.db.txs.slot(r.slot) orelse return;
        if (@as(u32, @intCast(t.word.load(.acquire) >> 32)) != r.gen or t.done) return;
        t.setEnd(.released);
        t.wake();
    }
};

/// `anole_db_tx_release` (and `anole_handle_release` on a transaction): rolls
/// an open one back now. A cleanup call: nothing to say when it is over.
pub fn txRelease(e: *Engine, hv: u64) void {
    const h = Handle.decode(hv);
    const t = txSlotOf(e, h) orelse return;
    var w = t.word.load(.acquire);
    while (true) {
        const state: TxState = @fromBackingInt(@intCast(w & 0xFFFFFFFF));
        if (@as(u32, @intCast(w >> 32)) != h.gen or state == .free) return;
        if (state == .closing) break;
        w = t.word.cmpxchgWeak(w, packTx(h.gen, .closing), .acq_rel, .acquire) orelse break;
    }
    const r = gpa.create(ReleaseCmd) catch return;
    r.* = .{ .slot = h.slot, .gen = h.gen };
    t.exec.post(&r.cmd);
}
