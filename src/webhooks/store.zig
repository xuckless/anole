//! Where webhook endpoints, messages and the delivery log live: the jobs
//! store's own database (PostgreSQL, SQLite, Redis) or memory. The store
//! keeps rows as JSON text (`body`) next to the few columns it queries by;
//! `root.zig` turns them into `Endpoint`, `Message` and `Attempt`.
//!
//! Every call takes `c` (a request, a `*Job` or an `anole.db.Ctx`): it
//! carries `io` and the `arena` that results live in.
const std = @import("std");
const anole = @import("../root.zig");
const dedup_mod = @import("dedup.zig");

const log = std.log.scoped(.anole_webhooks);

pub const Error = anole.db.Error || error{ Canceled, OutOfMemory };

/// A stored delivery attempt: its id (for paging) and the JSON text.
pub const AttRow = struct { id: i64, body: []const u8 };

pub const AttFilter = struct {
    endpoint: ?[]const u8 = null,
    message: ?[]const u8 = null,
    before: ?i64 = null,
    limit: u16 = 50,
};

/// A database left out of the build (-Dpostgres=false, -Dsqlite=false): the
/// store's calls on it compile and are never reached.
const NoDb = struct {
    pub fn exec(self: *NoDb, c: anytype, sql: []const u8, args: anytype) error{OutOfMemory}!usize {
        _ = .{ self, c, sql, args };
        unreachable;
    }
    pub fn one(self: *NoDb, comptime T: type, c: anytype, sql: []const u8, args: anytype) error{OutOfMemory}!T {
        _ = .{ self, c, sql, args };
        unreachable;
    }
    pub fn optional(self: *NoDb, comptime T: type, c: anytype, sql: []const u8, args: anytype) error{OutOfMemory}!?T {
        _ = .{ self, c, sql, args };
        unreachable;
    }
    pub fn all(self: *NoDb, comptime T: type, c: anytype, sql: []const u8, args: anytype) error{OutOfMemory}![]T {
        _ = .{ self, c, sql, args };
        unreachable;
    }
};
pub const PgClient = if (anole.features.postgres) anole.pg.Client else NoDb;
pub const SqliteClient = if (anole.features.sqlite) anole.sqlite.Client else NoDb;

pub const Backend = union(enum) {
    memory: *Memory,
    postgres: *PgClient,
    sqlite: *SqliteClient,
    redis: *dedup_mod.RedisClient,
};

pub const Store = struct {
    backend: Backend,
    sql: Sql = .{},
    memory: ?*Memory = null,

    /// Statements, built once for the table prefix and dialect.
    pub const Sql = struct {
        ep_put: []const u8 = "",
        ep_get: []const u8 = "",
        ep_list: []const u8 = "",
        ep_del: []const u8 = "",
        ep_count: []const u8 = "",
        msg_put: []const u8 = "",
        msg_get: []const u8 = "",
        msg_idem: []const u8 = "",
        /// One owner's messages, and every owner's (two statements, so
        /// the one-owner listing can use the (owner, id DESC) index).
        msg_list: []const u8 = "",
        msg_list_all: []const u8 = "",
        att_add: []const u8 = "",
        att_list: []const u8 = "",
        prune_msgs: []const u8 = "",
        prune_atts: []const u8 = "",
        ddl: []const []const u8 = &.{},
        /// PostgreSQL: per table, a query counting its id columns whose
        /// collation is not "C", and the ALTER that moves them to it.
        collation_check: []const []const u8 = &.{},
        collation_fix: []const []const u8 = &.{},
        /// PostgreSQL: the migration's advisory lock.
        migrate_key: i64 = 0,
    };

    pub fn init(gpa: std.mem.Allocator, io: std.Io, jobs_store: anole.jobs.Store, table_prefix: []const u8, redis_prefix: []const u8) !*Store {
        const self = try gpa.create(Store);
        errdefer gpa.destroy(self);
        self.* = .{ .backend = undefined };
        switch (jobs_store) {
            .memory => {
                const m = try gpa.create(Memory);
                m.* = .{ .gpa = gpa, .io = io };
                self.memory = m;
                self.backend = .{ .memory = m };
            },
            .postgres => |p| if (comptime anole.features.postgres) {
                self.backend = .{ .postgres = p };
                self.sql = try buildSql(gpa, .postgres, table_prefix);
            } else unreachable,
            .sqlite => |s| if (comptime anole.features.sqlite) {
                self.backend = .{ .sqlite = s };
                self.sql = try buildSql(gpa, .sqlite, table_prefix);
            } else unreachable,
            .redis => |r| if (comptime anole.features.redis) {
                self.backend = .{ .redis = r };
                self.sql.ep_put = try gpa.dupe(u8, redis_prefix);
            } else unreachable,
        }
        return self;
    }

    pub fn deinit(self: *Store, gpa: std.mem.Allocator) void {
        if (self.memory) |m| {
            m.deinit();
            gpa.destroy(m);
        }
        switch (self.backend) {
            .redis => gpa.free(self.sql.ep_put),
            .postgres, .sqlite => freeSql(gpa, self.sql),
            .memory => {},
        }
        gpa.destroy(self);
    }

    /// Creates the tables (SQL backends). Idempotent.
    ///
    /// PostgreSQL: the paged and indexed ids are `COLLATE "C"`, so they
    /// order by bytes as on SQLite and in memory, whatever the database's
    /// collation. Tables made before 0.4.1 took the database's default; the
    /// first start finds that in the catalog and ALTERs the columns once
    /// (their indexes are rebuilt under an ACCESS EXCLUSIVE lock), unless
    /// that default is libc "C" or "POSIX", which already orders by bytes.
    /// It runs before the DDL so the indexes created there are built once,
    /// on the new collation.
    ///
    /// It all runs in one transaction holding an advisory lock of its own
    /// (as the jobs store's migration does), so instances starting together
    /// take turns, with no bound on its length (an index build on a large
    /// table takes as long as it takes). Each lock it waits for (not the
    /// advisory lock) is bounded by `lock_timeout`: past it the start fails
    /// with a log line saying what to do, instead of queueing every publish
    /// behind a lock it cannot get.
    pub fn migrate(self: *Store, c: anytype) Error!void {
        switch (self.backend) {
            .postgres => |p| if (comptime anole.features.postgres) {
                p.transaction(c, .{ .timeout = .max }, migratePg, .{ c, @as(*const Sql, &self.sql) }) catch |err| {
                    if (anole.db.lastError(c)) |d| if (std.mem.eql(u8, d.code, "55P03")) logLockTimeout(d.message);
                    return switch (err) {
                        // Only a bound on the transaction ends in it, and it has none.
                        error.Timeout => error.GatewayTimeout,
                        else => |e| e,
                    };
                };
            } else unreachable,
            .sqlite => |s| for (self.sql.ddl) |stmt| {
                _ = try s.exec(c, stmt, .{});
            },
            else => {},
        }
    }

    /// How long the PostgreSQL migration waits for each table lock.
    pub const lock_timeout = "10s";

    fn migratePg(tx: *anole.pg.Tx, c: anytype, sql: *const Sql) Error!void {
        _ = try tx.table(c, "SELECT pg_advisory_xact_lock($1::bigint)", &.{.{ .int = sql.migrate_key }});
        // After the advisory lock: an instance waiting its turn waits for
        // the other's whole migration, which is not a stuck lock.
        _ = try tx.exec(c, "SET LOCAL lock_timeout = '" ++ lock_timeout ++ "'", .{});
        for (sql.collation_check, sql.collation_fix) |check, fix| {
            if ((try tx.one(CountRow, c, check, .{})).n == 0) continue;
            log.info("webhooks: moving ids to the C collation, once: {s}", .{fix});
            _ = try tx.exec(c, fix, .{});
        }
        for (sql.ddl) |stmt| _ = try tx.exec(c, stmt, .{});
    }

    fn logLockTimeout(message: []const u8) void {
        if (@import("dusty").expect_log.swallow()) return;
        log.err("webhooks: can't migrate the webhook tables: a lock on one of them was held by another session for " ++ lock_timeout ++ " ({s})." ++
            "\n  End that session's transaction (pg_stat_activity shows it) and start again, or run the statements in docs/webhooks.md (\"Storage\") yourself first.", .{message});
    }

    // ---- endpoints

    pub fn epPut(self: *Store, c: anytype, id: []const u8, owner: []const u8, body: []const u8) Error!void {
        switch (self.backend) {
            .memory => |m| try m.epPut(id, owner, body),
            .postgres => |p| _ = try p.exec(c, self.sql.ep_put, .{ id, owner, body }),
            .sqlite => |s| _ = try s.exec(c, self.sql.ep_put, .{ id, owner, body }),
            .redis => |r| {
                const k = try self.key(c, "ep:", id);
                _ = try r.command(c, .{ "SET", k, body });
                const ok = try self.key(c, "owner:", owner);
                _ = try r.command(c, .{ "SADD", ok, id });
                // The owner is kept next to the body so a delete can find the set.
                const ek = try self.key(c, "epowner:", id);
                _ = try r.command(c, .{ "SET", ek, owner });
            },
        }
    }

    pub fn epGet(self: *Store, c: anytype, id: []const u8) Error!?[]const u8 {
        switch (self.backend) {
            .memory => |m| return m.epGet(c.arena, id),
            .postgres => |p| return rowBody(try p.optional(BodyRow, c, self.sql.ep_get, .{id})),
            .sqlite => |s| return rowBody(try s.optional(BodyRow, c, self.sql.ep_get, .{id})),
            .redis => |r| {
                const k = try self.key(c, "ep:", id);
                const rep = try r.command(c, .{ "GET", k });
                return rep.text();
            },
        }
    }

    pub fn epList(self: *Store, c: anytype, owner: []const u8) Error![]const []const u8 {
        switch (self.backend) {
            .memory => |m| return m.epList(c.arena, owner),
            .postgres => |p| return bodies(c.arena, try p.all(BodyRow, c, self.sql.ep_list, .{owner})),
            .sqlite => |s| return bodies(c.arena, try s.all(BodyRow, c, self.sql.ep_list, .{owner})),
            .redis => |r| {
                const ok = try self.key(c, "owner:", owner);
                const ids = try r.command(c, .{ "SMEMBERS", ok });
                var out: std.ArrayList([]const u8) = .empty;
                if (ids != .array) return out.items;
                for (ids.array) |idr| {
                    const id = idr.text() orelse continue;
                    if (try self.epGet(c, id)) |b| try out.append(c.arena, b);
                }
                return out.items;
            },
        }
    }

    pub fn epDel(self: *Store, c: anytype, id: []const u8) Error!bool {
        switch (self.backend) {
            .memory => |m| return m.epDel(id),
            .postgres => |p| return (try p.exec(c, self.sql.ep_del, .{id})) > 0,
            .sqlite => |s| return (try s.exec(c, self.sql.ep_del, .{id})) > 0,
            .redis => |r| {
                const ek = try self.key(c, "epowner:", id);
                const owner = (try r.command(c, .{ "GET", ek })).text() orelse "";
                const ok = try self.key(c, "owner:", owner);
                _ = try r.command(c, .{ "SREM", ok, id });
                _ = try r.command(c, .{ "DEL", ek });
                const k = try self.key(c, "ep:", id);
                const n = try r.command(c, .{ "DEL", k });
                return n == .int and n.int > 0;
            },
        }
    }

    pub fn epCount(self: *Store, c: anytype, owner: []const u8) Error!u32 {
        switch (self.backend) {
            .memory => |m| return m.epCount(owner),
            .postgres => |p| return @intCast((try p.one(CountRow, c, self.sql.ep_count, .{owner})).n),
            .sqlite => |s| return @intCast((try s.one(CountRow, c, self.sql.ep_count, .{owner})).n),
            .redis => |r| {
                const ok = try self.key(c, "owner:", owner);
                const n = try r.command(c, .{ "SCARD", ok });
                return if (n == .int) @intCast(@max(n.int, 0)) else 0;
            },
        }
    }

    // ---- messages

    /// Stores the message. When one with the same (owner, idempotency)
    /// exists, nothing is stored and its body comes back.
    pub fn msgPut(self: *Store, c: anytype, id: []const u8, owner: []const u8, idem: ?[]const u8, created_ms: i64, body: []const u8) Error!?[]const u8 {
        const ik = idem orelse "";
        switch (self.backend) {
            .memory => |m| return m.msgPut(c.arena, id, owner, ik, created_ms, body),
            .postgres => |p| {
                const n = try p.exec(c, self.sql.msg_put, .{ id, owner, ik, created_ms, body });
                if (n > 0) return null;
                return rowBody(try p.optional(BodyRow, c, self.sql.msg_idem, .{ owner, ik, id }));
            },
            .sqlite => |s| {
                const n = try s.exec(c, self.sql.msg_put, .{ id, owner, ik, created_ms, body });
                if (n > 0) return null;
                return rowBody(try s.optional(BodyRow, c, self.sql.msg_idem, .{ owner, ik, id }));
            },
            .redis => |r| {
                if (ik.len > 0) {
                    const idk = try self.key2(c, "idem:", owner, ik);
                    const got = try r.command(c, .{ "SET", idk, id, "NX" });
                    if (got == .nil) {
                        const old_id = (try r.command(c, .{ "GET", idk })).text() orelse return null;
                        return try self.msgGet(c, old_id);
                    }
                }
                const k = try self.key(c, "msg:", id);
                _ = try r.command(c, .{ "SET", k, body });
                const zk = try self.key(c, "msgs:", owner);
                _ = try r.command(c, .{ "ZADD", zk, "0", id });
                return null;
            },
        }
    }

    pub fn msgGet(self: *Store, c: anytype, id: []const u8) Error!?[]const u8 {
        switch (self.backend) {
            .memory => |m| return m.msgGet(c.arena, id),
            .postgres => |p| return rowBody(try p.optional(BodyRow, c, self.sql.msg_get, .{id})),
            .sqlite => |s| return rowBody(try s.optional(BodyRow, c, self.sql.msg_get, .{id})),
            .redis => |r| {
                const k = try self.key(c, "msg:", id);
                return (try r.command(c, .{ "GET", k })).text();
            },
        }
    }

    /// Newest first, ids below `before`.
    pub fn msgList(self: *Store, c: anytype, owner: ?[]const u8, before: ?[]const u8, limit: u16) Error![]const []const u8 {
        const o = owner orelse "";
        const all_owners = owner == null;
        // No `before`: every id (SQL: '' turns the bound off; "\xff" is not
        // valid UTF-8 for PostgreSQL's text).
        const b = before orelse "";
        const lim64: i64 = limit;
        switch (self.backend) {
            .memory => |m| return m.msgList(c.arena, o, all_owners, before orelse "\xff", limit),
            .postgres => |p| return bodies(c.arena, try if (all_owners)
                p.all(BodyRow, c, self.sql.msg_list_all, .{ b, lim64 })
            else
                p.all(BodyRow, c, self.sql.msg_list, .{ o, b, lim64 })),
            .sqlite => |s| return bodies(c.arena, try if (all_owners)
                s.all(BodyRow, c, self.sql.msg_list_all, .{ b, lim64 })
            else
                s.all(BodyRow, c, self.sql.msg_list, .{ o, b, lim64 })),
            .redis => |r| {
                const zk = try self.key(c, "msgs:", o);
                var lim_buf: [8]u8 = undefined;
                const lim = std.fmt.bufPrint(&lim_buf, "{d}", .{limit}) catch unreachable;
                const max = if (before) |bf| try std.fmt.allocPrint(c.arena, "({s}", .{bf}) else "+";
                const ids = try r.command(c, .{ "ZREVRANGEBYLEX", zk, max, "-", "LIMIT", "0", lim });
                var out: std.ArrayList([]const u8) = .empty;
                if (ids != .array) return out.items;
                for (ids.array) |idr| {
                    const id = idr.text() orelse continue;
                    if (try self.msgGet(c, id)) |body| try out.append(c.arena, body);
                }
                return out.items;
            },
        }
    }

    // ---- attempts

    pub fn attAdd(self: *Store, c: anytype, message_id: []const u8, endpoint_id: []const u8, at_ms: i64, body: []const u8) Error!void {
        switch (self.backend) {
            .memory => |m| try m.attAdd(message_id, endpoint_id, at_ms, body),
            .postgres => |p| _ = try p.exec(c, self.sql.att_add, .{ message_id, endpoint_id, at_ms, body }),
            .sqlite => |s| _ = try s.exec(c, self.sql.att_add, .{ message_id, endpoint_id, at_ms, body }),
            .redis => |r| {
                const seq = try self.key(c, "attseq", "");
                const n = try r.command(c, .{ "INCR", seq });
                const id: i64 = if (n == .int) n.int else 0;
                const entry = try std.fmt.allocPrint(c.arena, "{d}\n{s}", .{ id, body });
                const ek = try self.key(c, "att:ep:", endpoint_id);
                const mk = try self.key(c, "att:msg:", message_id);
                for ([_][]const u8{ ek, mk }) |k| {
                    _ = try r.command(c, .{ "LPUSH", k, entry });
                    _ = try r.command(c, .{ "LTRIM", k, "0", "999" });
                }
            },
        }
    }

    pub fn attList(self: *Store, c: anytype, f: AttFilter) Error![]const AttRow {
        const ep = f.endpoint orelse "";
        const msg = f.message orelse "";
        const before = f.before orelse 0;
        switch (self.backend) {
            .memory => |m| return m.attList(c.arena, ep, msg, before, f.limit),
            .postgres => |p| return attRows(c.arena, try p.all(AttSqlRow, c, self.sql.att_list, .{ ep, msg, before, @as(i64, f.limit) })),
            .sqlite => |s| return attRows(c.arena, try s.all(AttSqlRow, c, self.sql.att_list, .{ ep, msg, before, @as(i64, f.limit) })),
            .redis => |r| {
                const k = if (ep.len > 0) try self.key(c, "att:ep:", ep) else try self.key(c, "att:msg:", msg);
                const list = try r.command(c, .{ "LRANGE", k, "0", "999" });
                var out: std.ArrayList(AttRow) = .empty;
                if (list != .array) return out.items;
                for (list.array) |e| {
                    const text = e.text() orelse continue;
                    const nl = std.mem.indexOfScalar(u8, text, '\n') orelse continue;
                    const id = std.fmt.parseInt(i64, text[0..nl], 10) catch continue;
                    if (before != 0 and id >= before) continue;
                    if (out.items.len >= f.limit) break;
                    try out.append(c.arena, .{ .id = id, .body = text[nl + 1 ..] });
                }
                return out.items;
            },
        }
    }

    /// Drops messages and attempts older than the cut-offs (SQL and memory;
    /// Redis keys expire by themselves).
    pub fn prune(self: *Store, c: anytype, msgs_before_ms: i64, atts_before_ms: i64) Error!void {
        switch (self.backend) {
            .memory => |m| m.prune(msgs_before_ms, atts_before_ms),
            .postgres => |p| {
                _ = try p.exec(c, self.sql.prune_msgs, .{msgs_before_ms});
                _ = try p.exec(c, self.sql.prune_atts, .{atts_before_ms});
            },
            .sqlite => |s| {
                _ = try s.exec(c, self.sql.prune_msgs, .{msgs_before_ms});
                _ = try s.exec(c, self.sql.prune_atts, .{atts_before_ms});
            },
            .redis => {},
        }
    }

    // ---- redis keys

    fn key(self: *Store, c: anytype, kind: []const u8, id: []const u8) std.mem.Allocator.Error![]const u8 {
        return std.fmt.allocPrint(c.arena, "{s}webhooks:{s}{s}", .{ self.sql.ep_put, kind, id });
    }
    fn key2(self: *Store, c: anytype, kind: []const u8, a: []const u8, b: []const u8) std.mem.Allocator.Error![]const u8 {
        return std.fmt.allocPrint(c.arena, "{s}webhooks:{s}{s}:{s}", .{ self.sql.ep_put, kind, a, b });
    }
};

const BodyRow = struct { body: []const u8 };
const CountRow = struct { n: i64 };
const AttSqlRow = struct { id: i64, body: []const u8 };

fn rowBody(r: ?BodyRow) ?[]const u8 {
    return if (r) |x| x.body else null;
}

fn bodies(arena: std.mem.Allocator, rows: []BodyRow) std.mem.Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, rows.len);
    for (rows, out) |r, *o| o.* = r.body;
    return out;
}

fn attRows(arena: std.mem.Allocator, rows: []AttSqlRow) std.mem.Allocator.Error![]const AttRow {
    const out = try arena.alloc(AttRow, rows.len);
    for (rows, out) |r, *o| o.* = .{ .id = r.id, .body = r.body };
    return out;
}

const Dialect = enum { postgres, sqlite };

fn freeSql(gpa: std.mem.Allocator, s: Store.Sql) void {
    for ([_][]const u8{ s.ep_put, s.ep_get, s.ep_list, s.ep_del, s.ep_count, s.msg_put, s.msg_get, s.msg_idem, s.msg_list, s.msg_list_all, s.att_add, s.att_list, s.prune_msgs, s.prune_atts }) |v| {
        if (v.len > 0) gpa.free(v);
    }
    for ([_][]const []const u8{ s.ddl, s.collation_check, s.collation_fix }) |list| {
        for (list) |d| gpa.free(d);
        if (list.len > 0) gpa.free(list);
    }
}

/// `$n` placeholders become `?n` for SQLite.
fn fmt(gpa: std.mem.Allocator, d: Dialect, prefix: []const u8, comptime tmpl: []const u8) ![]const u8 {
    const text = try std.fmt.allocPrint(gpa, tmpl, .{prefix});
    if (d == .postgres) return text;
    for (text) |*ch| if (ch.* == '$') {
        ch.* = '?';
    };
    return text;
}

fn buildSql(gpa: std.mem.Allocator, d: Dialect, p: []const u8) !Store.Sql {
    var s: Store.Sql = .{};
    errdefer freeSql(gpa, s);
    s.ep_put = try fmt(gpa, d, p, "INSERT INTO {0s}webhook_endpoints (id, owner, body) VALUES ($1, $2, $3) ON CONFLICT (id) DO UPDATE SET owner = excluded.owner, body = excluded.body");
    s.ep_get = try fmt(gpa, d, p, "SELECT body FROM {0s}webhook_endpoints WHERE id = $1");
    s.ep_list = try fmt(gpa, d, p, "SELECT body FROM {0s}webhook_endpoints WHERE owner = $1 ORDER BY id");
    s.ep_del = try fmt(gpa, d, p, "DELETE FROM {0s}webhook_endpoints WHERE id = $1");
    s.ep_count = try fmt(gpa, d, p, "SELECT count(*) AS n FROM {0s}webhook_endpoints WHERE owner = $1");
    s.msg_put = try fmt(gpa, d, p, "INSERT INTO {0s}webhook_messages (id, owner, idempotency, created_ms, body) VALUES ($1, $2, $3, $4, $5) ON CONFLICT DO NOTHING");
    s.msg_get = try fmt(gpa, d, p, "SELECT body FROM {0s}webhook_messages WHERE id = $1");
    s.msg_idem = try fmt(gpa, d, p, "SELECT body FROM {0s}webhook_messages WHERE (owner = $1 AND idempotency = $2 AND $2 <> '') OR id = $3 LIMIT 1");
    s.msg_list = try fmt(gpa, d, p, "SELECT body FROM {0s}webhook_messages WHERE owner = $1 AND ($2 = '' OR id < $2) ORDER BY id DESC LIMIT $3");
    s.msg_list_all = try fmt(gpa, d, p, "SELECT body FROM {0s}webhook_messages WHERE ($1 = '' OR id < $1) ORDER BY id DESC LIMIT $2");
    s.att_add = try fmt(gpa, d, p, "INSERT INTO {0s}webhook_attempts (message_id, endpoint_id, at_ms, body) VALUES ($1, $2, $3, $4)");
    s.att_list = try fmt(gpa, d, p, "SELECT id, body FROM {0s}webhook_attempts WHERE ($1 = '' OR endpoint_id = $1) AND ($2 = '' OR message_id = $2) AND ($3 = 0 OR id < $3) ORDER BY id DESC LIMIT $4");
    s.prune_msgs = try fmt(gpa, d, p, "DELETE FROM {0s}webhook_messages WHERE created_ms < $1");
    s.prune_atts = try fmt(gpa, d, p, "DELETE FROM {0s}webhook_attempts WHERE at_ms < $1");
    const id_col = switch (d) {
        .postgres => "bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY",
        .sqlite => "INTEGER PRIMARY KEY AUTOINCREMENT",
    };
    // Ids compare by bytes (SQLite's default BINARY collation already does).
    const c_text = switch (d) {
        .postgres => "text COLLATE \"C\"",
        .sqlite => "text",
    };
    var ddl: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (ddl.items) |x| gpa.free(x);
        ddl.deinit(gpa);
    }
    try ddl.append(gpa, try fmt(gpa, d, p, "CREATE TABLE IF NOT EXISTS {0s}webhook_endpoints (id text PRIMARY KEY, owner text NOT NULL, body text NOT NULL)"));
    try ddl.append(gpa, try fmt(gpa, d, p, "CREATE INDEX IF NOT EXISTS {0s}webhook_endpoints_owner ON {0s}webhook_endpoints (owner)"));
    try ddl.append(gpa, try std.fmt.allocPrint(gpa, "CREATE TABLE IF NOT EXISTS {s}webhook_messages (id {s} PRIMARY KEY, owner text NOT NULL, idempotency text NOT NULL DEFAULT '', created_ms bigint NOT NULL, body text NOT NULL)", .{ p, c_text }));
    try ddl.append(gpa, try fmt(gpa, d, p, "CREATE UNIQUE INDEX IF NOT EXISTS {0s}webhook_messages_idem ON {0s}webhook_messages (owner, idempotency) WHERE idempotency <> ''"));
    try ddl.append(gpa, try fmt(gpa, d, p, "CREATE INDEX IF NOT EXISTS {0s}webhook_messages_created ON {0s}webhook_messages (created_ms)"));
    // One owner's page (Svix's ix_message_per_app).
    try ddl.append(gpa, try fmt(gpa, d, p, "CREATE INDEX IF NOT EXISTS {0s}webhook_messages_owner ON {0s}webhook_messages (owner, id DESC)"));
    const att = try std.fmt.allocPrint(gpa, "CREATE TABLE IF NOT EXISTS {0s}webhook_attempts (id {1s}, message_id {2s} NOT NULL, endpoint_id {2s} NOT NULL, at_ms bigint NOT NULL, body text NOT NULL)", .{ p, id_col, c_text });
    try ddl.append(gpa, att);
    try ddl.append(gpa, try fmt(gpa, d, p, "CREATE INDEX IF NOT EXISTS {0s}webhook_attempts_endpoint ON {0s}webhook_attempts (endpoint_id, id)"));
    try ddl.append(gpa, try fmt(gpa, d, p, "CREATE INDEX IF NOT EXISTS {0s}webhook_attempts_message ON {0s}webhook_attempts (message_id, id)"));
    s.ddl = try ddl.toOwnedSlice(gpa);
    if (d == .postgres) {
        // Tables made before 0.4.1 (see `Store.migrate`). A table that does
        // not exist yet counts none (to_regclass is null). A column on the
        // database's default collation is fine when that is libc "C" or
        // "POSIX" (datlocprovider is read through to_jsonb because it only
        // exists from PostgreSQL 15 on; before, every database is libc).
        const not_c =
            \\SELECT count(*) AS n FROM pg_attribute WHERE attrelid = to_regclass('{0s}{1s}') AND attname IN ({2s})
            \\  AND attcollation <> (SELECT oid FROM pg_collation WHERE collname = 'C' AND collnamespace = 'pg_catalog'::regnamespace)
            \\  AND NOT (attcollation = (SELECT oid FROM pg_collation WHERE collname = 'default' AND collnamespace = 'pg_catalog'::regnamespace)
            \\    AND EXISTS (SELECT 1 FROM pg_database d WHERE d.datname = current_database()
            \\      AND coalesce(to_jsonb(d) ->> 'datlocprovider', 'c') = 'c' AND d.datcollate IN ('C', 'POSIX')))
        ;
        const tables = [_]struct { []const u8, []const u8, []const u8 }{
            .{ "webhook_messages", "'id'", "ALTER COLUMN id TYPE text COLLATE \"C\"" },
            .{ "webhook_attempts", "'message_id', 'endpoint_id'", "ALTER COLUMN message_id TYPE text COLLATE \"C\", ALTER COLUMN endpoint_id TYPE text COLLATE \"C\"" },
        };
        var checks: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (checks.items) |x| gpa.free(x);
            checks.deinit(gpa);
        }
        var fixes: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (fixes.items) |x| gpa.free(x);
            fixes.deinit(gpa);
        }
        for (tables) |t| {
            try checks.append(gpa, try std.fmt.allocPrint(gpa, not_c, .{ p, t[0], t[1] }));
            try fixes.append(gpa, try std.fmt.allocPrint(gpa, "ALTER TABLE {s}{s} {s}", .{ p, t[0], t[2] }));
        }
        s.collation_check = try checks.toOwnedSlice(gpa);
        s.collation_fix = try fixes.toOwnedSlice(gpa);
        s.migrate_key = advisoryKey("anole.webhooks.migrate:", p);
    }
    return s;
}

/// The i64 of the first 8 bytes of SHA-256(`label ++ prefix`), as the jobs
/// store derives its migration's advisory lock key (src/jobs/store_pg.zig).
fn advisoryKey(label: []const u8, prefix: []const u8) i64 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(label);
    h.update(prefix);
    var d: [32]u8 = undefined;
    h.final(&d);
    return std.mem.readInt(i64, d[0..8], .big);
}

/// In this process only.
pub const Memory = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    eps: std.StringArrayHashMapUnmanaged(Ep) = .empty,
    msgs: std.StringArrayHashMapUnmanaged(Msg) = .empty,
    atts: std.ArrayList(Att) = .empty,
    next_att: i64 = 1,

    const Ep = struct { owner: []u8, body: []u8 };
    const Msg = struct { owner: []u8, idem: []u8, created_ms: i64, body: []u8 };
    const Att = struct { id: i64, message: []u8, endpoint: []u8, at_ms: i64, body: []u8 };

    pub fn deinit(m: *Memory) void {
        for (m.eps.keys(), m.eps.values()) |k, v| {
            m.gpa.free(k);
            m.gpa.free(v.owner);
            m.gpa.free(v.body);
        }
        m.eps.deinit(m.gpa);
        for (m.msgs.keys(), m.msgs.values()) |k, v| {
            m.gpa.free(k);
            m.gpa.free(v.owner);
            m.gpa.free(v.idem);
            m.gpa.free(v.body);
        }
        m.msgs.deinit(m.gpa);
        for (m.atts.items) |a| {
            m.gpa.free(a.message);
            m.gpa.free(a.endpoint);
            m.gpa.free(a.body);
        }
        m.atts.deinit(m.gpa);
    }

    fn lock(m: *Memory) void {
        m.mutex.lockUncancelable(m.io);
    }
    fn unlock(m: *Memory) void {
        m.mutex.unlock(m.io);
    }

    fn epPut(m: *Memory, id: []const u8, owner: []const u8, body: []const u8) Error!void {
        m.lock();
        defer m.unlock();
        const o = try m.gpa.dupe(u8, owner);
        errdefer m.gpa.free(o);
        const b = try m.gpa.dupe(u8, body);
        errdefer m.gpa.free(b);
        if (m.eps.getPtr(id)) |e| {
            m.gpa.free(e.owner);
            m.gpa.free(e.body);
            e.* = .{ .owner = o, .body = b };
            return;
        }
        const k = try m.gpa.dupe(u8, id);
        errdefer m.gpa.free(k);
        try m.eps.put(m.gpa, k, .{ .owner = o, .body = b });
    }

    fn epGet(m: *Memory, arena: std.mem.Allocator, id: []const u8) Error!?[]const u8 {
        m.lock();
        defer m.unlock();
        const e = m.eps.get(id) orelse return null;
        return try arena.dupe(u8, e.body);
    }

    fn epList(m: *Memory, arena: std.mem.Allocator, owner: []const u8) Error![]const []const u8 {
        m.lock();
        defer m.unlock();
        var ids: std.ArrayList([]const u8) = .empty;
        defer ids.deinit(m.gpa);
        for (m.eps.keys(), m.eps.values()) |k, v| if (std.mem.eql(u8, v.owner, owner)) try ids.append(m.gpa, k);
        std.mem.sort([]const u8, ids.items, {}, lessStr);
        const out = try arena.alloc([]const u8, ids.items.len);
        for (ids.items, out) |k, *o| o.* = try arena.dupe(u8, m.eps.get(k).?.body);
        return out;
    }

    fn epDel(m: *Memory, id: []const u8) bool {
        m.lock();
        defer m.unlock();
        const kv = m.eps.fetchSwapRemove(id) orelse return false;
        m.gpa.free(kv.key);
        m.gpa.free(kv.value.owner);
        m.gpa.free(kv.value.body);
        return true;
    }

    fn epCount(m: *Memory, owner: []const u8) u32 {
        m.lock();
        defer m.unlock();
        var n: u32 = 0;
        for (m.eps.values()) |v| if (std.mem.eql(u8, v.owner, owner)) {
            n += 1;
        };
        return n;
    }

    fn msgPut(m: *Memory, arena: std.mem.Allocator, id: []const u8, owner: []const u8, idem: []const u8, created_ms: i64, body: []const u8) Error!?[]const u8 {
        m.lock();
        defer m.unlock();
        if (m.msgs.get(id)) |e| return try arena.dupe(u8, e.body);
        if (idem.len > 0) for (m.msgs.values()) |v| {
            if (std.mem.eql(u8, v.owner, owner) and std.mem.eql(u8, v.idem, idem)) return try arena.dupe(u8, v.body);
        };
        const k = try m.gpa.dupe(u8, id);
        errdefer m.gpa.free(k);
        const o = try m.gpa.dupe(u8, owner);
        errdefer m.gpa.free(o);
        const i = try m.gpa.dupe(u8, idem);
        errdefer m.gpa.free(i);
        const b = try m.gpa.dupe(u8, body);
        errdefer m.gpa.free(b);
        try m.msgs.put(m.gpa, k, .{ .owner = o, .idem = i, .created_ms = created_ms, .body = b });
        return null;
    }

    fn msgGet(m: *Memory, arena: std.mem.Allocator, id: []const u8) Error!?[]const u8 {
        m.lock();
        defer m.unlock();
        const e = m.msgs.get(id) orelse return null;
        return try arena.dupe(u8, e.body);
    }

    fn msgList(m: *Memory, arena: std.mem.Allocator, owner: []const u8, all_owners: bool, before: []const u8, limit: u16) Error![]const []const u8 {
        m.lock();
        defer m.unlock();
        var ids: std.ArrayList([]const u8) = .empty;
        defer ids.deinit(m.gpa);
        for (m.msgs.keys(), m.msgs.values()) |k, v| {
            if (!all_owners and !std.mem.eql(u8, v.owner, owner)) continue;
            if (std.mem.order(u8, k, before) != .lt) continue;
            try ids.append(m.gpa, k);
        }
        std.mem.sort([]const u8, ids.items, {}, greaterStr);
        const n = @min(ids.items.len, limit);
        const out = try arena.alloc([]const u8, n);
        for (ids.items[0..n], out) |k, *o| o.* = try arena.dupe(u8, m.msgs.get(k).?.body);
        return out;
    }

    fn attAdd(m: *Memory, message_id: []const u8, endpoint_id: []const u8, at_ms: i64, body: []const u8) Error!void {
        m.lock();
        defer m.unlock();
        const a = try m.gpa.dupe(u8, message_id);
        errdefer m.gpa.free(a);
        const e = try m.gpa.dupe(u8, endpoint_id);
        errdefer m.gpa.free(e);
        const b = try m.gpa.dupe(u8, body);
        errdefer m.gpa.free(b);
        try m.atts.append(m.gpa, .{ .id = m.next_att, .message = a, .endpoint = e, .at_ms = at_ms, .body = b });
        m.next_att += 1;
    }

    fn attList(m: *Memory, arena: std.mem.Allocator, ep: []const u8, msg: []const u8, before: i64, limit: u16) Error![]const AttRow {
        m.lock();
        defer m.unlock();
        var out: std.ArrayList(AttRow) = .empty;
        var i = m.atts.items.len;
        while (i > 0 and out.items.len < limit) {
            i -= 1;
            const a = m.atts.items[i];
            if (ep.len > 0 and !std.mem.eql(u8, a.endpoint, ep)) continue;
            if (msg.len > 0 and !std.mem.eql(u8, a.message, msg)) continue;
            if (before != 0 and a.id >= before) continue;
            try out.append(arena, .{ .id = a.id, .body = try arena.dupe(u8, a.body) });
        }
        return out.items;
    }

    fn prune(m: *Memory, msgs_before_ms: i64, atts_before_ms: i64) void {
        m.lock();
        defer m.unlock();
        var i: usize = 0;
        while (i < m.atts.items.len) {
            const a = m.atts.items[i];
            if (a.at_ms < atts_before_ms) {
                m.gpa.free(a.message);
                m.gpa.free(a.endpoint);
                m.gpa.free(a.body);
                _ = m.atts.orderedRemove(i);
            } else i += 1;
        }
        i = 0;
        while (i < m.msgs.count()) {
            const v = m.msgs.values()[i];
            if (v.created_ms < msgs_before_ms) {
                const k = m.msgs.keys()[i];
                m.msgs.orderedRemoveAt(i);
                m.gpa.free(k);
                m.gpa.free(v.owner);
                m.gpa.free(v.idem);
                m.gpa.free(v.body);
            } else i += 1;
        }
    }
};

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}
fn greaterStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .gt;
}

test "memory store: endpoints, messages with idempotency, attempts" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: anole.db.Ctx = .{ .io = std.testing.io, .arena = arena_state.allocator() };
    const st = try Store.init(gpa, std.testing.io, .memory, "anole_", "anole:");
    defer st.deinit(gpa);

    try st.epPut(&c, "ep_2", "acme", "{\"b\":1}");
    try st.epPut(&c, "ep_1", "acme", "{\"a\":1}");
    try st.epPut(&c, "ep_3", "other", "{}");
    const list = try st.epList(&c, "acme");
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("{\"a\":1}", list[0]);
    try std.testing.expectEqual(@as(u32, 2), try st.epCount(&c, "acme"));
    try std.testing.expect(try st.epDel(&c, "ep_1"));
    try std.testing.expect(!try st.epDel(&c, "ep_1"));

    try std.testing.expect(try st.msgPut(&c, "msg_A", "acme", "k1", 0, "one") == null);
    const dup = try st.msgPut(&c, "msg_B", "acme", "k1", 0, "two");
    try std.testing.expectEqualStrings("one", dup.?);
    try std.testing.expect(try st.msgPut(&c, "msg_C", "other", "k1", 0, "three") == null);
    const ml = try st.msgList(&c, "acme", null, 10);
    try std.testing.expectEqual(@as(usize, 1), ml.len);

    try st.attAdd(&c, "msg_A", "ep_2", 5, "a1");
    try st.attAdd(&c, "msg_A", "ep_2", 6, "a2");
    const atts = try st.attList(&c, .{ .endpoint = "ep_2" });
    try std.testing.expectEqual(@as(usize, 2), atts.len);
    try std.testing.expectEqualStrings("a2", atts[0].body);
    const page = try st.attList(&c, .{ .endpoint = "ep_2", .before = atts[0].id });
    try std.testing.expectEqual(@as(usize, 1), page.len);
}
