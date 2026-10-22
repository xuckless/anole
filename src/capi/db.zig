//! `anole_db_*`: the configuration's databases (SQLite, PostgreSQL), queried
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

const features = anole.features;
const placement = dusty.placement;
const gpa = engine.gpa;
const Engine = engine.Engine;
const Exec = engine.Exec;
const Consumer = engine.Consumer;
const Command = engine.Command;
const db = anole.db;
const sqlite = if (features.sqlite) anole.sqlite else struct {
    pub const Client = void;
};
const pg = if (features.postgres) anole.pg else struct {
    pub const Client = void;
};
const redis = if (features.redis) anole.redis else struct {
    pub const Client = void;
    pub const Reply = void;
};

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
};

/// Per executor: the tasks of the queries it runs, canceled at the stop.
pub const ExecState = struct {
    work: std.Io.Group = .init,

    pub fn cancel(st: *ExecState, io: std.Io) void {
        st.work.cancel(io);
    }
};

/// Opens every configured database on `app` (from the server's main
/// thread, before the listeners open) and runs its `init` script.
pub fn open(e: *Engine, app: *anole.App) !void {
    for (e.dbs) |*d| {
        if (d.config.postgres) |p| {
            if (comptime features.postgres) try openPostgres(d, app, p) else unreachable;
        } else if (d.config.redis) |r| {
            if (comptime features.redis) try openRedis(d, app, r) else unreachable;
        } else {
            if (comptime features.sqlite) try openSqlite(d, app, d.config.sqlite.?) else unreachable;
        }
        d.open.store(true, .release);
    }
}

fn openSqlite(d: *Db, app: *anole.App, sq: config_mod.Config.Sqlite) !void {
    {
        const client = try app.sqlite(anole.sqlite.Options{
            .path = sq.path,
            .name = d.config.name,
            .readers = if (sq.readers) |n| n else null,
            .busy_timeout_ms = sq.busy_timeout_ms,
            .statement_cache = sq.statement_cache,
            .pragmas = sq.pragmas,
            .cache = .{
                .max_entries = d.config.cache.max_entries,
                .max_bytes = std.math.cast(usize, d.config.cache.max_bytes) orelse std.math.maxInt(usize),
            },
        });
        if (sq.init) |script| client.execScript(script) catch |err| {
            log.err("databases \"{s}\": init failed: {t}", .{ d.config.name, err });
            return err;
        };
        d.client = .{ .sqlite = client };
    }
}

fn openPostgres(d: *Db, app: *anole.App, p: config_mod.Config.Postgres) !void {
    const ms = std.Io.Duration.fromMilliseconds;
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
        .tls = .{ .ca = if (p.ca_file) |f| .{ .file = .{ .path = f } } else if (p.ca_pem) |pem| .{ .pem = pem } else null },
        .connect_at_start = p.connect_at_start,
        .application_name = p.application_name,
        .reset_session = p.reset_session,
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
    _ = client.exec(&ctx, script, .{}) catch |err| {
        if (db.lastError(&ctx)) |detail| {
            log.err("databases \"{s}\": init failed: {f}", .{ d.config.name, detail });
        } else log.err("databases \"{s}\": init failed: {t}", .{ d.config.name, err });
        return err;
    };
}

fn openRedis(d: *Db, app: *anole.App, r: config_mod.Config.Redis) !void {
    const ms = std.Io.Duration.fromMilliseconds;
    const client = try app.redis(anole.redis.Options{
        .url = r.url,
        .name = d.config.name,
        .max_connections = r.max_connections,
        .acquire_timeout = ms(r.acquire_timeout_ms),
        .connect_timeout = if (r.connect_timeout_ms > 0) ms(r.connect_timeout_ms) else null,
        .idle_timeout = if (r.idle_timeout_ms > 0) ms(r.idle_timeout_ms) else null,
        .tls = .{ .ca = if (r.ca_file) |f| .{ .file = .{ .path = f } } else if (r.ca_pem) |pem| .{ .pem = pem } else null },
        .connect_at_start = r.connect_at_start,
        .cache = .{
            .max_entries = d.config.cache.max_entries,
            .max_bytes = std.math.cast(usize, d.config.cache.max_bytes) orelse std.math.maxInt(usize),
        },
    });
    d.client = .{ .redis = client };
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

pub const QueryError = error{ Invalid, State, OutOfMemory, Unsupported };

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
    /// Everything above points into this.
    arena: std.heap.ArenaAllocator,

    fn free(q: *Query) void {
        var arena = q.arena;
        arena.deinit();
    }

    fn run(cmd: *Command, x: *Exec) void {
        const q: *Query = @fieldParentPtr("cmd", cmd);
        if (x.engine.phase.load(.acquire) == .stopped) return q.free();
        placement.concurrent(&x.db.work, x.engine.io, .local, task, .{ x, q }) catch q.free();
    }
};

/// Queues `sql` for `c` (`anole_db_query`, `anole_db_exec`).
pub fn submit(d: *Db, c: *Consumer, verb: Verb, sql: []const u8, params: []const abi.DbValue, opts: abi.DbOptions, user_data: u64) QueryError!void {
    if (comptime !features.sqlite and !features.postgres) return error.Unsupported;
    const e = d.engine;
    if (c.engine != e) return error.Invalid;
    switch (e.phase.load(.acquire)) {
        .running, .draining => {},
        else => return error.State,
    }
    if (!d.open.load(.acquire)) return error.State;
    if (c.execs.items.len == 0) return error.State;
    for (params) |p| if (p.type > abi.DB_BOOL) return error.Invalid;

    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const values = try a.alloc(db.Value, params.len);
    for (params, values) |p, *v| v.* = switch (p.type) {
        abi.DB_NULL => .null,
        abi.DB_INT => .{ .int = p.v.i },
        abi.DB_FLOAT => .{ .float = p.v.f },
        abi.DB_TEXT => .{ .text = try a.dupe(u8, p.v.s.slice()) },
        abi.DB_BLOB => .{ .blob = try a.dupe(u8, p.v.s.slice()) },
        abi.DB_BOOL => .{ .bool = p.v.i != 0 },
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
        .sql = try a.dupe(u8, sql),
        .tag = if (opts.cache_tag.len > 0) try a.dupe(u8, opts.cache_tag.slice()) else null,
        .params = values,
        .arena = undefined,
    };
    q.arena = arena;
    // Spread over the executors that feed `c`: each keeps its own cache.
    const i = c.next_db.fetchAdd(1, .monotonic) % c.execs.items.len;
    c.execs.items[i].post(&q.cmd);
}

pub fn invalidate(d: *Db, tag: []const u8) error{State}!void {
    if (!d.open.load(.acquire)) return error.State;
    const cache = switch (d.client) {
        .none => return error.State,
        .sqlite => |client| if (comptime features.sqlite) &client.cache else unreachable,
        .postgres => |client| if (comptime features.postgres) &client.cache else unreachable,
        .redis => |client| if (comptime features.redis) &client.cache else unreachable,
    };
    if (tag.len == 0) cache.invalidate(.all) else cache.invalidate(.{ .tag = tag });
}

/// On the executor: runs the statement and queues the answer.
fn task(x: *Exec, q: *Query) std.Io.Cancelable!void {
    defer q.free();
    const e = x.engine;
    if (!q.d.open.load(.acquire)) return;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var ctx: db.Ctx = .{ .io = e.io, .arena = arena.allocator() };
    var options: db.QueryOptions = .{
        .write = q.flags & abi.DB_WRITE != 0,
        .prepare = q.flags & abi.DB_NO_PREPARE == 0,
        .coalesce = q.flags & abi.DB_COALESCE != 0,
    };
    if (q.timeout_ms > 0) options.timeout = .fromMilliseconds(q.timeout_ms);
    if (q.cache_ttl_ms > 0) options.cache = .{
        .ttl = .fromMilliseconds(q.cache_ttl_ms),
        .tag = q.tag,
        .keep_empty = q.flags & abi.DB_DROP_EMPTY == 0,
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
                .exec => if (with.run(&ctx, q.sql, q.params)) |ch| {
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
    }
    if (db.lastSource(&ctx)) |src| answer.source = switch (src) {
        .database => abi.DB_FROM_DATABASE,
        .coalesced => abi.DB_FROM_COALESCED,
        .cache => abi.DB_FROM_CACHE,
    };
    // A query canceled at the stop answers nothing: the consumer's last
    // event is ANOLE_EV_STOPPED.
    if (answer.canceled) return error.Canceled;
    const rec = answer.record(e.config.limits.db_result_max) catch |err| switch (err) {
        error.TooBig => (Answer{ .user_data = q.user_data, .status = abi.E_TOOBIG, .http_status = 500, .error_class = .other, .message = "the answer is larger than limits.db_result_max" }).record(std.math.maxInt(u32)) catch return,
        error.OutOfMemory => (Answer{ .user_data = q.user_data, .status = abi.E_NOMEM, .http_status = 500, .error_class = .other }).record(std.math.maxInt(u32)) catch return,
    };
    // An answer must arrive: wait for room in the ring.
    x.postRecord(rec, true);
}

/// What goes into the record.
const Answer = struct {
    user_data: u64,
    status: i32 = abi.OK,
    http_status: u16 = 0,
    error_class: abi.DbErrorClass = .none,
    source: u8 = abi.DB_FROM_DATABASE,
    table: ?db.Table = null,
    changes: ?db.Changes = null,
    reply: ?redis.Reply = null,
    message: []const u8 = "",
    code: []const u8 = "",
    constraint: []const u8 = "",
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
        } else {
            a.error_class = if (err == error.GatewayTimeout) .timeout else .other;
            a.message = @errorName(err);
        }
        if (err == error.OutOfMemory) a.status = abi.E_NOMEM;
        if (err == error.GatewayTimeout and a.error_class == .timeout) a.status = abi.E_TIMEOUT;
    }

    /// The record: header, column names, cells, then the bytes.
    fn record(a: *const Answer, max: u32) error{ TooBig, OutOfMemory }![]align(8) u8 {
        const Ev = abi.DbResultEvent;
        var ncol: usize = 0;
        var nrows: usize = 0;
        var bytes: usize = a.message.len + a.code.len + a.constraint.len;
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
        const cols_off = @sizeOf(Ev);
        const cells_off = cols_off + ncol * @sizeOf(abi.Span);
        // A Redis reply has no columns: its cells are a tree in preorder.
        const ncells = if (a.reply != null) nrows else std.math.mul(usize, ncol, nrows) catch return error.TooBig;
        const bytes_off = cells_off + ncells * @sizeOf(abi.DbCell);
        const total = bytes_off + bytes;
        if (total > max) return error.TooBig;
        const rec = engine.newRecord(total, .db_result, 0) catch return error.OutOfMemory;
        const ev: *Ev = @ptrCast(rec.ptr);
        var w: Writer = .{ .rec = rec, .at = bytes_off };
        ev.user_data = a.user_data;
        ev.status = a.status;
        ev.http_status = a.http_status;
        ev.error_class = @intFromEnum(a.error_class);
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
        if (comptime features.redis) if (a.reply) |r| {
            const cells: [*]abi.DbCell = @ptrCast(@alignCast(rec.ptr + cells_off));
            var k: usize = 0;
            putReply(r, cells, &k, &w);
        };
        if (a.table) |t| {
            const names: [*]abi.Span = @ptrCast(@alignCast(rec.ptr + cols_off));
            for (t.columns, 0..) |n, i| names[i] = w.put(n);
            const cells: [*]abi.DbCell = @ptrCast(@alignCast(rec.ptr + cells_off));
            var k: usize = 0;
            for (t.rows) |row| for (row, 0..) |v, col| {
                cells[k] = switch (v) {
                    .null => .{ .type = abi.DB_NULL, .v = .{ .i = 0 } },
                    .int => |n| .{ .type = abi.DB_INT, .v = .{ .i = n } },
                    .float => |f| .{ .type = abi.DB_FLOAT, .v = .{ .f = f } },
                    .bool => |b| .{ .type = abi.DB_BOOL, .v = .{ .i = @intFromBool(b) } },
                    .text => |s| .{ .type = abi.DB_TEXT, .v = .{ .s = w.put(s) } },
                    .blob => |s| .{ .type = abi.DB_BLOB, .v = .{ .s = w.put(s) } },
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
        .nil => .{ .type = abi.DB_NULL, .v = .{ .i = 0 } },
        .int => |n| .{ .type = abi.DB_INT, .v = .{ .i = n } },
        .double => |f| .{ .type = abi.DB_FLOAT, .v = .{ .f = f } },
        .boolean => |b| .{ .type = abi.DB_BOOL, .v = .{ .i = @intFromBool(b) } },
        .status => |str| .{ .type = abi.DB_TEXT, .v = .{ .s = w.put(str) } },
        .string => |str| .{ .type = abi.DB_BLOB, .v = .{ .s = w.put(str) } },
        .err => |str| .{ .type = abi.DB_ERROR, .v = .{ .s = w.put(str) } },
        .array => |items| .{ .type = abi.DB_ARRAY, .v = .{ .i = @intCast(items.len) } },
        // RESP3 maps hold key, value, key, value...
        .map => |items| .{ .type = abi.DB_MAP, .v = .{ .i = @intCast(items.len / 2) } },
    };
    switch (r) {
        .array, .map => |items| for (items) |item| putReply(item, cells, k, w),
        else => {},
    }
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
