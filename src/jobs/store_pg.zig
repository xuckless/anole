//! The PostgreSQL job store (J2, §4.1): `FOR UPDATE SKIP LOCKED` claims,
//! lease columns, partial unique indexes for unique jobs, and
//! `pg_notify('<prefix>jobs', queue)` after every insert or staging that
//! makes a job available (a listener on that channel wakes fetchers).
//! Times are `timestamptz` columns; statements pass Unix milliseconds and
//! convert in SQL, so the Zig side keeps the same `Time` values as the
//! other stores.
const std = @import("std");
const anole = @import("../root.zig");
const root = @import("root.zig");
const store = @import("store.zig");

const pg = anole.pg;
const db = anole.db;
const V = db.Value;
const Time = root.Time;
const Id = root.Id;
const State = root.State;

fn ms(t: Time) i64 {
    return @divFloor(t.us, 1000);
}
fn fromMs(v: i64) Time {
    return Time.fromMillis(v);
}

/// SQL: a timestamptz column as Unix milliseconds.
fn ems(comptime col: []const u8) []const u8 {
    return "(extract(epoch from " ++ col ++ ") * 1000)::bigint";
}
/// SQL: parameter `$n` (Unix milliseconds) as a timestamptz.
fn ts(comptime n: []const u8) []const u8 {
    return "to_timestamp($" ++ n ++ "::bigint / 1000.0)";
}

fn rowCols(comptime a: []const u8) []const u8 {
    return a ++ "id, " ++ a ++ "queue, " ++ a ++ "kind, " ++ a ++ "state, " ++ a ++ "priority::bigint, " ++ a ++ "attempt::bigint, " ++ a ++ "max_attempts::bigint, " ++
        a ++ "args::text, " ++ a ++ "meta::text, " ++ ems(a ++ "run_at") ++ ", " ++ ems(a ++ "created_at") ++ ", " ++ ems(a ++ "attempted_at") ++ ", " ++ ems(a ++ "finished_at") ++
        ", " ++ a ++ "worker, " ++ a ++ "errors::text, " ++ a ++ "timeout_ms::bigint";
}

/// Whether the unique key survives a move to state `$3` (scope 1 pending, 2 unfinished, 3 any).
const keep_unique_sql = "(unique_scope = 3 OR (unique_scope = 2 AND $3::text IN ('scheduled','available','retrying','running')) OR (unique_scope = 1 AND $3::text IN ('scheduled','available','retrying')))";

pub const Postgres = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    client: *pg.Client,
    prefix: []const u8,
    /// pg_notify after inserts and staging.
    notify: bool,
    /// Leader by a session-level advisory lock on a connection of its own.
    advisory: bool,
    session: ?pg.Session = null,
    holds_lock: bool = false,
    /// Who holds the lock through `session` (one process can have several clients on one store).
    held_owner: ?[]u8 = null,
    /// Serialises the leader's session.
    leader_mutex: std.Io.Mutex = .init,

    pub const Config = struct {
        notify: bool = true,
        advisory_lock: bool = true,
    };

    pub fn create(gpa: std.mem.Allocator, io: std.Io, client: *pg.Client, prefix: []const u8, config: Config) !store.Backend {
        const self = try gpa.create(Postgres);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .client = client, .prefix = try gpa.dupe(u8, prefix), .notify = config.notify, .advisory = config.advisory_lock };
        return .{ .ptr = self, .vt = &vtable, .transactional = true, .tx_kind = .postgres, .owner = client };
    }

    const vtable: store.VTable = .{
        .deinit = deinit,
        .migrate = migrate,
        .insert = insert,
        .claim = claim,
        .stage = stage,
        .heartbeat = heartbeat,
        .finish = finish,
        .rescue = rescue,
        .prune = prune,
        .get = get,
        .list = list,
        .counts = counts,
        .adminRetry = adminRetry,
        .adminCancel = adminCancel,
        .adminDelete = adminDelete,
        .cronGet = cronGet,
        .cronList = cronList,
        .cronSet = cronSet,
        .cronTick = cronTick,
        .leaderTake = leaderTake,
        .leaderRelease = leaderRelease,
        .runWake = runWake,
        .insertIn = insertIn,
        .finishIn = finishInErased,
    };

    fn me(ptr: *anyopaque) *Postgres {
        return @ptrCast(@alignCast(ptr));
    }

    fn deinit(ptr: *anyopaque) void {
        const self = me(ptr);
        if (self.session) |*s| s.close();
        if (self.held_owner) |h| self.gpa.free(h);
        self.gpa.free(self.prefix);
        self.gpa.destroy(self);
    }

    const Scratch = struct {
        arena_state: std.heap.ArenaAllocator,
        ctx: db.Ctx,

        fn start(s: *Scratch, self: *Postgres) void {
            s.arena_state = .init(self.gpa);
            s.ctx = .{ .io = self.io, .arena = s.arena_state.allocator() };
        }
        fn deinit(s: *Scratch) void {
            s.arena_state.deinit();
        }
    };

    /// `fmt` with every `{p}` replaced by the prefix.
    fn text(self: *Postgres, a: std.mem.Allocator, comptime fmt: []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var rest: []const u8 = fmt;
        while (std.mem.indexOf(u8, rest, "{p}")) |i| {
            try out.appendSlice(a, rest[0..i]);
            try out.appendSlice(a, self.prefix);
            rest = rest[i + 3 ..];
        }
        try out.appendSlice(a, rest);
        return out.items;
    }

    fn q(self: *Postgres) pg.Query {
        return self.client.with(.{});
    }

    fn migrate(ptr: *anyopaque) anyerror!void {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        const a = sc.ctx.arena;
        const ddl = try ddlText(a, self.prefix);
        const key = advisoryKey("anole.migrate:", self.prefix);
        try self.client.transaction(&sc.ctx, .{}, migrateTx, .{ &sc.ctx, key, ddl, self.prefix });
    }

    fn migrateTx(tx: *pg.Tx, ctx: *db.Ctx, key: i64, ddl: []const u8, prefix: []const u8) anyerror!void {
        _ = try tx.table(ctx, "SELECT pg_advisory_xact_lock($1::bigint)", &.{V{ .int = key }});
        // Version 1 is the only one so far; a newer one is refused.
        _ = try tx.exec(ctx, ddl, .{});
        const sql = try std.fmt.allocPrint(ctx.arena, "SELECT version::bigint FROM {s}schema WHERE component = 'jobs'", .{prefix});
        const t = try tx.table(ctx, sql, &.{});
        if (t.rows.len > 0) {
            const have = int(t.rows[0][0]);
            if (have > schema_version) {
                std.log.scoped(.anole).err("jobs: {s}jobs schema is version {d}; this Anole knows up to {d}: upgrade Anole", .{ prefix, have, schema_version });
                return error.Database;
            }
        } else {
            const ins = try std.fmt.allocPrint(ctx.arena, "INSERT INTO {s}schema (component, version) VALUES ('jobs', $1::bigint) ON CONFLICT (component) DO NOTHING", .{prefix});
            _ = try tx.execValues(ctx, ins, &.{V{ .int = schema_version }});
        }
    }

    pub const schema_version = 1;

    /// The i64 of the first 8 bytes of SHA-256(`label ++ prefix`).
    fn advisoryKey(label: []const u8, prefix: []const u8) i64 {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update(label);
        h.update(prefix);
        var d: [32]u8 = undefined;
        h.final(&d);
        return std.mem.readInt(i64, d[0..8], .big);
    }

    // ---- values

    fn int(v: V) i64 {
        return switch (v) {
            .int => |i| i,
            .float => |f| @intFromFloat(f),
            .bool => |b| @intFromBool(b),
            .text => |t| std.fmt.parseInt(i64, t, 10) catch 0,
            else => 0,
        };
    }
    fn optInt(v: V) ?i64 {
        return switch (v) {
            .null => null,
            else => int(v),
        };
    }
    fn str(v: V) []const u8 {
        return switch (v) {
            .text => |t| t,
            .blob => |t| t,
            else => "",
        };
    }
    fn optTime(v: V) ?Time {
        return if (optInt(v)) |i| fromMs(i) else null;
    }
    fn optTimeV(t: ?Time) V {
        return if (t) |x| .{ .int = ms(x) } else .null;
    }

    fn rowFrom(a: std.mem.Allocator, r: []const V) !store.Row {
        const errors = std.json.parseFromSliceLeaky([]root.ErrorEntry, a, str(r[14]), .{ .ignore_unknown_fields = true }) catch &[_]root.ErrorEntry{};
        const state = std.meta.stringToEnum(State, str(r[3])) orelse .available;
        return .{
            .id = int(r[0]),
            .queue = str(r[1]),
            .kind = str(r[2]),
            .state = state,
            .priority = @fromBackingInt(@intCast(@as(u8, @intCast(@min(3, @max(0, int(r[4]))))))),
            .attempt = @intCast(int(r[5])),
            .max_attempts = @intCast(int(r[6])),
            .args_json = str(r[7]),
            .meta_json = str(r[8]),
            .run_at = fromMs(int(r[9])),
            .created_at = fromMs(int(r[10])),
            .attempted_at = optTime(r[11]),
            .finished_at = optTime(r[12]),
            .worker = if (r[13] == .null) null else str(r[13]),
            .errors = errors,
            .timeout_ms = if (optInt(r[15])) |t| @intCast(t) else null,
        };
    }

    fn copyRow(arena: std.mem.Allocator, r: store.Row) !store.Row {
        var out = r;
        out.queue = try arena.dupe(u8, r.queue);
        out.kind = try arena.dupe(u8, r.kind);
        out.args_json = try arena.dupe(u8, r.args_json);
        out.meta_json = try arena.dupe(u8, r.meta_json);
        if (r.worker) |x| out.worker = try arena.dupe(u8, x);
        const errs = try arena.alloc(root.ErrorEntry, r.errors.len);
        for (r.errors, errs) |s, *d| d.* = .{ .attempt = s.attempt, .at = s.at, .@"error" = try arena.dupe(u8, s.@"error"), .message = try arena.dupe(u8, s.message) };
        out.errors = errs;
        return out;
    }

    // ---- insert

    const insert_sql =
        "WITH ins AS (" ++
        "INSERT INTO {p}jobs (queue, kind, args, meta, state, priority, max_attempts, run_at, created_at, timeout_ms, unique_key, unique_scope) " ++
        "VALUES ($1::text, $2::text, $3::text::jsonb, $4::text::jsonb, $5::text, $6::bigint, $7::bigint, " ++ ts("8") ++ ", " ++ ts("9") ++ ", $10::bigint, $11::bytea, $12::bigint) " ++
        "ON CONFLICT (unique_key) WHERE unique_key IS NOT NULL DO NOTHING RETURNING id, state), " ++
        "n AS (SELECT pg_notify('{p}jobs', $1::text) FROM ins WHERE ins.state = 'available' AND $13::bool) " ++
        "SELECT id, true AS inserted, (SELECT count(*) FROM n) AS notified FROM ins " ++
        "UNION ALL " ++
        "SELECT id, false, 0::bigint FROM {p}jobs WHERE $11::bytea IS NOT NULL AND unique_key = $11::bytea AND NOT EXISTS (SELECT 1 FROM ins)";

    /// Runs the insert on `runner` (a `Query` or a transaction's). When a
    /// unique key conflicts the existing job's id comes back; if that job
    /// left the covered states in between, it is tried again (3 times).
    pub fn insertOn(self: *Postgres, runner: anytype, ctx: *db.Ctx, now: Time, job: store.NewJob) !root.Enqueued {
        const stmt = try self.text(ctx.arena, insert_sql);
        const available = job.run_at.us <= now.us;
        var tries: u32 = 0;
        while (tries < 3) : (tries += 1) {
            const params = [_]V{
                .{ .text = job.queue },
                .{ .text = job.kind },
                .{ .text = job.args_json },
                .{ .text = job.meta_json },
                .{ .text = if (available) "available" else "scheduled" },
                .{ .int = @backingInt(job.priority) },
                .{ .int = job.max_attempts },
                .{ .int = ms(job.run_at) },
                .{ .int = ms(now) },
                if (job.timeout_ms) |t| V{ .int = t } else V.null,
                if (job.unique) |u| V{ .blob = &u.key } else V.null,
                if (job.unique) |u| V{ .int = @backingInt(u.scope) } else V.null,
                .{ .bool = self.notify },
            };
            const t = try runner.table(ctx, stmt, &params);
            if (t.rows.len > 0) return .{ .id = int(t.rows[0][0]), .inserted = t.rows[0][1] == .bool and t.rows[0][1].bool };
            if (job.unique == null) return error.Database;
        }
        return error.Conflict;
    }

    fn insert(ptr: *anyopaque, now: Time, job: store.NewJob) anyerror!root.Enqueued {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        return self.insertOn(self.q(), &sc.ctx, now, job);
    }

    // ---- claim

    fn byOrder(_: void, a: store.Row, b: store.Row) bool {
        if (a.priority != b.priority) return @backingInt(a.priority) < @backingInt(b.priority);
        if (a.run_at.us != b.run_at.us) return a.run_at.us < b.run_at.us;
        return a.id < b.id;
    }

    fn claim(ptr: *anyopaque, arena: std.mem.Allocator, req: store.ClaimRequest) anyerror![]store.Row {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        const a = sc.ctx.arena;
        var kinds_sql: std.ArrayList(u8) = .empty;
        var params: std.ArrayList(V) = .empty;
        try params.appendSlice(a, &.{ V{ .text = req.queue }, V{ .int = req.limit }, V{ .int = ms(req.now) }, V{ .int = ms(req.lease_until) }, V{ .text = req.worker } });
        if (req.kinds) |ks| {
            if (ks.len == 0) return &.{};
            try kinds_sql.appendSlice(a, " AND kind IN (");
            for (ks, 0..) |k, i| {
                if (i > 0) try kinds_sql.append(a, ',');
                try kinds_sql.print(a, "${d}::text", .{6 + i});
                try params.append(a, .{ .text = k });
            }
            try kinds_sql.append(a, ')');
        }
        const stmt = try std.fmt.allocPrint(
            a,
            "WITH c AS MATERIALIZED (SELECT id FROM {s}jobs WHERE state = 'available' AND queue = $1::text{s} " ++
                "ORDER BY priority, run_at, id LIMIT $2::bigint FOR UPDATE SKIP LOCKED) " ++
                "UPDATE {s}jobs j SET state = 'running', attempt = j.attempt + 1, attempted_at = " ++ ts("3") ++ ", lease_until = " ++ ts("4") ++ ", worker = $5::text, " ++
                "unique_key = CASE WHEN j.unique_scope = 1 THEN NULL ELSE j.unique_key END " ++
                "FROM c WHERE j.id = c.id RETURNING " ++ rowCols("j."),
            .{ self.prefix, kinds_sql.items, self.prefix },
        );
        const t = try self.client.with(.{ .prepare = req.kinds == null }).table(&sc.ctx, stmt, params.items);
        const out = try arena.alloc(store.Row, t.rows.len);
        for (t.rows, out) |r, *d| d.* = try copyRow(arena, try rowFrom(a, r));
        std.mem.sort(store.Row, out, {}, byOrder);
        return out;
    }

    fn stage(ptr: *anyopaque, now: Time) anyerror!u32 {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        const stmt = try self.text(sc.ctx.arena, "WITH due AS (SELECT id FROM {p}jobs WHERE state IN ('scheduled','retrying') AND run_at <= " ++ ts("1") ++
            " ORDER BY run_at LIMIT 1000 FOR UPDATE SKIP LOCKED), " ++
            "up AS (UPDATE {p}jobs j SET state = 'available' FROM due WHERE j.id = due.id RETURNING j.queue), " ++
            "n AS (SELECT pg_notify('{p}jobs', d.q) FROM (SELECT DISTINCT queue AS q FROM up) d WHERE $2::bool) " ++
            "SELECT (SELECT count(*) FROM up), (SELECT count(*) FROM n)");
        const t = try self.q().table(&sc.ctx, stmt, &.{ V{ .int = ms(now) }, V{ .bool = self.notify } });
        if (t.rows.len == 0) return 0;
        return @intCast(int(t.rows[0][0]));
    }

    fn heartbeat(ptr: *anyopaque, arena: std.mem.Allocator, until: Time, held: []const store.Held) anyerror![]store.Held {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        const a = sc.ctx.arena;
        var out: std.ArrayList(store.Held) = .empty;
        var i: usize = 0;
        while (i < held.len) : (i += 1000) {
            const chunk = held[i..@min(held.len, i + 1000)];
            var values: std.ArrayList(u8) = .empty;
            for (chunk, 0..) |h, k| {
                if (k > 0) try values.append(a, ',');
                try values.print(a, "({d}::bigint,{d}::bigint)", .{ h.id, h.attempt });
            }
            const stmt = try std.fmt.allocPrint(
                a,
                "UPDATE {s}jobs j SET lease_until = " ++ ts("1") ++ " FROM (VALUES {s}) AS h(id, attempt) " ++
                    "WHERE j.id = h.id AND j.attempt = h.attempt AND j.state = 'running' RETURNING j.id, j.attempt::bigint",
                .{ self.prefix, values.items },
            );
            const t = try self.client.with(.{ .prepare = false }).table(&sc.ctx, stmt, &.{V{ .int = ms(until) }});
            for (t.rows) |r| try out.append(arena, .{ .id = int(r[0]), .attempt = @intCast(int(r[1])) });
        }
        return out.items;
    }

    const finish_sql =
        "UPDATE {p}jobs SET state = $3::text, attempt = attempt + $4::bigint, run_at = coalesce(" ++ ts("5") ++ ", run_at), finished_at = " ++ ts("6") ++ ", lease_until = NULL, " ++
        "worker = CASE WHEN $3::text IN ('available','scheduled') THEN NULL ELSE worker END, " ++
        "errors = CASE WHEN $7::text IS NULL THEN errors ELSE (SELECT coalesce(jsonb_agg(e ORDER BY i), '[]'::jsonb) FROM " ++
        "(SELECT e, i FROM jsonb_array_elements(errors || jsonb_build_array($7::text::jsonb)) WITH ORDINALITY AS t(e, i) ORDER BY i DESC LIMIT 10) s) END, " ++
        "unique_key = CASE WHEN " ++ keep_unique_sql ++ " THEN unique_key ELSE NULL END " ++
        "WHERE id = $1::bigint AND attempt = $2::bigint AND state = 'running' RETURNING id";

    /// Conditional state change of a held job (one statement).
    pub fn finishOn(self: *Postgres, runner: anytype, ctx: *db.Ctx, f: store.Finish) !bool {
        const a = ctx.arena;
        const stmt = try self.text(a, finish_sql);
        var err_text: V = .null;
        if (f.add_error) |e| err_text = .{ .text = try std.json.Stringify.valueAlloc(a, e, .{}) };
        const t = try runner.table(ctx, stmt, &.{
            V{ .int = f.id },
            V{ .int = f.attempt },
            V{ .text = @tagName(f.to) },
            V{ .int = f.attempt_delta },
            optTimeV(f.run_at),
            optTimeV(f.finished_at),
            err_text,
        });
        return t.rows.len > 0;
    }

    pub fn finishIn(self: *Postgres, tx: anytype, ctx: *db.Ctx, f: store.Finish) !bool {
        return self.finishOn(tx, ctx, f);
    }

    fn insertIn(ptr: *anyopaque, txp: *anyopaque, ctx: *db.Ctx, now: Time, job: store.NewJob) anyerror!root.Enqueued {
        const tx: *pg.Tx = @ptrCast(@alignCast(txp));
        return me(ptr).insertOn(tx, ctx, now, job);
    }

    fn finishInErased(ptr: *anyopaque, txp: *anyopaque, ctx: *db.Ctx, f: store.Finish) anyerror!bool {
        const tx: *pg.Tx = @ptrCast(@alignCast(txp));
        return me(ptr).finishOn(tx, ctx, f);
    }

    fn finish(ptr: *anyopaque, f: store.Finish) anyerror!bool {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        return self.finishOn(self.q(), &sc.ctx, f);
    }

    fn rescue(ptr: *anyopaque, arena: std.mem.Allocator, now: Time) anyerror![]store.Rescued {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        const a = sc.ctx.arena;
        const stmt = try self.text(a,
            \\UPDATE {p}jobs j SET
            \\  state = CASE WHEN j.attempt >= j.max_attempts THEN 'dead' ELSE 'available' END,
            \\  finished_at = CASE WHEN j.attempt >= j.max_attempts THEN to_timestamp($1::bigint / 1000.0) ELSE NULL END,
            \\  lease_until = NULL, worker = NULL,
            \\  unique_key = CASE WHEN j.attempt >= j.max_attempts AND j.unique_scope <> 3 THEN NULL ELSE j.unique_key END,
            \\  errors = j.errors || jsonb_build_array(jsonb_build_object('attempt', j.attempt, 'at', $2::text, 'error', 'LeaseExpired',
            \\           'message', 'the worker running it stopped or lost the database'))
            \\FROM (SELECT id FROM {p}jobs WHERE state = 'running' AND lease_until < to_timestamp($1::bigint / 1000.0) ORDER BY lease_until LIMIT 1000 FOR UPDATE SKIP LOCKED) r
            \\WHERE j.id = r.id RETURNING j.id, j.state
        );
        const at = try std.fmt.allocPrint(a, "{f}", .{now});
        const t = try self.q().table(&sc.ctx, stmt, &.{ V{ .int = ms(now) }, V{ .text = at } });
        const out = try arena.alloc(store.Rescued, t.rows.len);
        for (t.rows, out) |r, *d| d.* = .{ .id = int(r[0]), .dead = std.mem.eql(u8, str(r[1]), "dead") };
        return out;
    }

    fn prune(ptr: *anyopaque, now: Time, keep: root.Options.Keep) anyerror!u32 {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        const stmt = try self.text(sc.ctx.arena, "DELETE FROM {p}jobs WHERE id IN (SELECT id FROM {p}jobs WHERE state = $1::text AND finished_at < " ++ ts("2") ++
            " ORDER BY finished_at LIMIT 1000 FOR UPDATE SKIP LOCKED)");
        var n: u32 = 0;
        const spans = [_]struct { []const u8, root.Duration }{ .{ "completed", keep.completed }, .{ "dead", keep.dead }, .{ "cancelled", keep.cancelled } };
        for (spans) |s| {
            const c = try self.q().execValues(&sc.ctx, stmt, &.{ V{ .text = s[0] }, V{ .int = ms(now) - root.millis(s[1]) } });
            n += @intCast(c.changes);
        }
        return n;
    }

    fn get(ptr: *anyopaque, arena: std.mem.Allocator, id: Id) anyerror!?store.Row {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        const stmt = try self.text(sc.ctx.arena, "SELECT " ++ rowCols("") ++ " FROM {p}jobs WHERE id = $1::bigint");
        const t = try self.q().table(&sc.ctx, stmt, &.{V{ .int = id }});
        if (t.rows.len == 0) return null;
        return try copyRow(arena, try rowFrom(sc.ctx.arena, t.rows[0]));
    }

    fn list(ptr: *anyopaque, arena: std.mem.Allocator, filter: root.Filter) anyerror![]store.Row {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        const a = sc.ctx.arena;
        var params: std.ArrayList(V) = .empty;
        var where: std.ArrayList(u8) = .empty;
        try where.appendSlice(a, "true");
        if (filter.state) |s| {
            try params.append(a, .{ .text = @tagName(s) });
            try where.print(a, " AND state = ${d}::text", .{params.items.len});
        }
        if (filter.queue) |qn| {
            try params.append(a, .{ .text = qn });
            try where.print(a, " AND queue = ${d}::text", .{params.items.len});
        }
        if (filter.kind) |k| {
            try params.append(a, .{ .text = k });
            try where.print(a, " AND kind = ${d}::text", .{params.items.len});
        }
        if (filter.before) |b| {
            try params.append(a, .{ .int = b });
            try where.print(a, " AND id < ${d}::bigint", .{params.items.len});
        }
        try params.append(a, .{ .int = @max(filter.limit, 1) });
        const stmt = try std.fmt.allocPrint(a, "SELECT " ++ rowCols("") ++ " FROM {s}jobs WHERE {s} ORDER BY id DESC LIMIT ${d}::bigint", .{ self.prefix, where.items, params.items.len });
        const t = try self.client.with(.{ .prepare = false }).table(&sc.ctx, stmt, params.items);
        const out = try arena.alloc(store.Row, t.rows.len);
        for (t.rows, out) |r, *d| d.* = try copyRow(arena, try rowFrom(a, r));
        return out;
    }

    fn counts(ptr: *anyopaque, arena: std.mem.Allocator) anyerror![]root.Count {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        const stmt = try self.text(sc.ctx.arena, "SELECT queue, state, count(*) FROM {p}jobs WHERE state IN ('scheduled','available','running','retrying','dead') GROUP BY queue, state");
        const t = try self.q().table(&sc.ctx, stmt, &.{});
        const out = try arena.alloc(root.Count, t.rows.len);
        for (t.rows, out) |r, *d| d.* = .{ .queue = try arena.dupe(u8, str(r[0])), .state = std.meta.stringToEnum(State, str(r[1])) orelse .available, .n = @intCast(int(r[2])) };
        return out;
    }

    fn adminOp(self: *Postgres, comptime fmt: []const u8, params: []const V) !bool {
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        const stmt = try self.text(sc.ctx.arena, fmt);
        const c = try self.q().execValues(&sc.ctx, stmt, params);
        return c.changes > 0;
    }

    fn adminRetry(ptr: *anyopaque, now: Time, id: Id) anyerror!bool {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        const stmt = try self.text(sc.ctx.arena, "WITH r AS (UPDATE {p}jobs SET state = 'available', run_at = " ++ ts("2") ++
            ", finished_at = NULL, max_attempts = greatest(max_attempts, attempt + 1) WHERE id = $1::bigint AND state IN ('dead','cancelled','retrying','scheduled') RETURNING queue), " ++
            "n AS (SELECT pg_notify('{p}jobs', r.queue) FROM r WHERE $3::bool) SELECT (SELECT count(*) FROM r), (SELECT count(*) FROM n)");
        const t = try self.q().table(&sc.ctx, stmt, &.{ V{ .int = id }, V{ .int = ms(now) }, V{ .bool = self.notify } });
        return t.rows.len > 0 and int(t.rows[0][0]) > 0;
    }
    fn adminCancel(ptr: *anyopaque, now: Time, id: Id) anyerror!bool {
        return me(ptr).adminOp("UPDATE {p}jobs SET state = 'cancelled', finished_at = " ++ ts("2") ++ ", lease_until = NULL, unique_key = CASE WHEN unique_scope = 3 THEN unique_key ELSE NULL END " ++
            "WHERE id = $1::bigint AND state IN ('scheduled','available','retrying','running')", &.{ V{ .int = id }, V{ .int = ms(now) } });
    }
    fn adminDelete(ptr: *anyopaque, id: Id) anyerror!bool {
        return me(ptr).adminOp("DELETE FROM {p}jobs WHERE id = $1::bigint AND state IN ('completed','dead','cancelled')", &.{V{ .int = id }});
    }

    // ---- cron

    fn cronGet(ptr: *anyopaque, arena: std.mem.Allocator, name: []const u8) anyerror!?store.CronRow {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        const stmt = try self.text(sc.ctx.arena, "SELECT name, spec, " ++ ems("last_tick") ++ " FROM {p}cron WHERE name = $1::text");
        const t = try self.q().table(&sc.ctx, stmt, &.{V{ .text = name }});
        if (t.rows.len == 0) return null;
        const r = t.rows[0];
        return .{ .name = try arena.dupe(u8, str(r[0])), .spec = try arena.dupe(u8, str(r[1])), .last_tick = optTime(r[2]) };
    }

    fn cronList(ptr: *anyopaque, arena: std.mem.Allocator) anyerror![]store.CronRow {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        const stmt = try self.text(sc.ctx.arena, "SELECT name, spec, " ++ ems("last_tick") ++ " FROM {p}cron");
        const t = try self.q().table(&sc.ctx, stmt, &.{});
        const out = try arena.alloc(store.CronRow, t.rows.len);
        for (t.rows, out) |r, *d| d.* = .{ .name = try arena.dupe(u8, str(r[0])), .spec = try arena.dupe(u8, str(r[1])), .last_tick = optTime(r[2]) };
        return out;
    }

    fn cronSet(ptr: *anyopaque, name: []const u8, spec: []const u8, last_tick: Time) anyerror!void {
        _ = try me(ptr).adminOp("INSERT INTO {p}cron (name, spec, last_tick) VALUES ($1::text, $2::text, " ++ ts("3") ++ ") ON CONFLICT (name) DO UPDATE SET spec = EXCLUDED.spec, last_tick = EXCLUDED.last_tick", &.{ V{ .text = name }, V{ .text = spec }, V{ .int = ms(last_tick) } });
    }

    const TickArgs = struct { self: *Postgres, now: Time, name: []const u8, spec: []const u8, tick: Time, job: ?store.NewJob };

    fn tickTx(tx: *pg.Tx, ctx: *db.Ctx, ta: TickArgs) anyerror!store.CronTick {
        const stmt = try ta.self.text(ctx.arena, "INSERT INTO {p}cron (name, spec, last_tick) VALUES ($1::text, $2::text, " ++ ts("3") ++ ") ON CONFLICT (name) DO UPDATE SET last_tick = EXCLUDED.last_tick, spec = EXCLUDED.spec " ++
            "WHERE {p}cron.last_tick IS NULL OR {p}cron.last_tick < EXCLUDED.last_tick RETURNING name");
        const t = try tx.table(ctx, stmt, &.{ V{ .text = ta.name }, V{ .text = ta.spec }, V{ .int = ms(ta.tick) } });
        if (t.rows.len == 0) return .{ .recorded = false };
        if (ta.job) |j| return .{ .recorded = true, .enqueued = try ta.self.insertOn(tx, ctx, ta.now, j) };
        return .{ .recorded = true };
    }

    fn cronTick(ptr: *anyopaque, now: Time, name: []const u8, spec: []const u8, tick: Time, job: ?store.NewJob) anyerror!store.CronTick {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        return self.client.transaction(&sc.ctx, .{}, tickTx, .{ &sc.ctx, TickArgs{ .self = self, .now = now, .name = name, .spec = spec, .tick = tick, .job = job } });
    }

    // ---- leader

    fn leaderTake(ptr: *anyopaque, owner: []const u8, now: Time, ttl: root.Duration) anyerror!bool {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        if (self.advisory) return self.takeAdvisory(&sc.ctx, owner);
        const stmt = try self.text(sc.ctx.arena, "INSERT INTO {p}leader (name, owner, until) VALUES ('jobs', $1::text, " ++ ts("2") ++ ") ON CONFLICT (name) DO UPDATE SET owner = EXCLUDED.owner, until = EXCLUDED.until " ++
            "WHERE {p}leader.owner = EXCLUDED.owner OR {p}leader.until < " ++ ts("3") ++ " RETURNING owner");
        const t = try self.q().table(&sc.ctx, stmt, &.{ V{ .text = owner }, V{ .int = ms(now) + root.millis(ttl) }, V{ .int = ms(now) } });
        return t.rows.len > 0;
    }

    fn takeAdvisory(self: *Postgres, ctx: *db.Ctx, owner: []const u8) !bool {
        self.leader_mutex.lockUncancelable(self.io);
        defer self.leader_mutex.unlock(self.io);
        if (self.holds_lock) {
            if (self.held_owner) |h| if (!std.mem.eql(u8, h, owner)) return false;
        }
        if (self.session == null) {
            self.session = try self.client.session(ctx);
            self.holds_lock = false;
        }
        const raw = self.session.?.raw;
        const key = advisoryKey("anole.leader:", self.prefix);
        if (self.holds_lock) {
            // Renewal: the lock lives as long as the connection.
            var r = (raw.row("SELECT 1", .{}) catch return self.dropSession()) orelse return self.dropSession();
            r.deinit() catch return self.dropSession();
            return true;
        }
        var r = (raw.row("SELECT pg_try_advisory_lock($1)", .{key}) catch return self.dropSession()) orelse return self.dropSession();
        defer r.deinit() catch {};
        self.holds_lock = r.get(bool, 0) catch false;
        if (self.holds_lock) {
            if (self.held_owner) |h| self.gpa.free(h);
            self.held_owner = try self.gpa.dupe(u8, owner);
        }
        return self.holds_lock;
    }

    fn dropSession(self: *Postgres) bool {
        if (self.session) |*s| s.close();
        self.session = null;
        self.holds_lock = false;
        if (self.held_owner) |h| self.gpa.free(h);
        self.held_owner = null;
        return false;
    }

    /// LISTEN on `<prefix>jobs` (the inserts and the stager NOTIFY it with the queue name).
    fn runWake(ptr: *anyopaque, io: std.Io, wake: store.Wake) anyerror!void {
        _ = io;
        const self = me(ptr);
        if (!self.notify) return;
        var channel_buf: [96]u8 = undefined;
        const channel = try std.fmt.bufPrint(&channel_buf, "{s}jobs", .{self.prefix});
        var l = try self.client.listener();
        defer l.deinit();
        try l.listen(channel, .{});
        // Notifications may have been missed before the LISTEN.
        wake.kick(wake.context, "");
        while (l.next()) |n| wake.kick(wake.context, n.payload);
        return error.ListenerClosed;
    }

    fn leaderRelease(ptr: *anyopaque, owner: []const u8) anyerror!void {
        const self = me(ptr);
        if (self.advisory) {
            self.leader_mutex.lockUncancelable(self.io);
            defer self.leader_mutex.unlock(self.io);
            // Closing the connection releases the lock.
            if (self.held_owner) |h| if (!std.mem.eql(u8, h, owner)) return;
            _ = self.dropSession();
            return;
        }
        _ = try self.adminOp("DELETE FROM {p}leader WHERE name = 'jobs' AND owner = $1::text", &.{V{ .text = owner }});
    }
};

/// The DDL of `sql(.postgresql, ...)`.
pub fn ddlText(arena: std.mem.Allocator, prefix: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\CREATE TABLE IF NOT EXISTS {0s}schema (component text PRIMARY KEY, version integer NOT NULL);
        \\CREATE TABLE IF NOT EXISTS {0s}jobs (
        \\  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        \\  queue         text NOT NULL,
        \\  kind          text NOT NULL,
        \\  args          jsonb NOT NULL,
        \\  meta          jsonb NOT NULL DEFAULT '{{}}',
        \\  state         text NOT NULL CHECK (state IN ('scheduled','available','running','retrying','completed','dead','cancelled')),
        \\  priority      smallint NOT NULL CHECK (priority BETWEEN 0 AND 3),
        \\  attempt       smallint NOT NULL DEFAULT 0,
        \\  max_attempts  smallint NOT NULL CHECK (max_attempts BETWEEN 1 AND 1000),
        \\  run_at        timestamptz NOT NULL,
        \\  created_at    timestamptz NOT NULL,
        \\  attempted_at  timestamptz,
        \\  finished_at   timestamptz,
        \\  lease_until   timestamptz,
        \\  worker        text,
        \\  errors        jsonb NOT NULL DEFAULT '[]',
        \\  timeout_ms    integer,
        \\  unique_key    bytea,
        \\  unique_scope  smallint
        \\);
        \\CREATE INDEX IF NOT EXISTS {0s}jobs_claim ON {0s}jobs (queue, priority, run_at, id) WHERE state = 'available';
        \\CREATE INDEX IF NOT EXISTS {0s}jobs_due ON {0s}jobs (run_at) WHERE state IN ('scheduled','retrying');
        \\CREATE INDEX IF NOT EXISTS {0s}jobs_lease ON {0s}jobs (lease_until) WHERE state = 'running';
        \\CREATE INDEX IF NOT EXISTS {0s}jobs_finished ON {0s}jobs (state, finished_at) WHERE state IN ('completed','dead','cancelled');
        \\CREATE INDEX IF NOT EXISTS {0s}jobs_list ON {0s}jobs (queue, state, id);
        \\CREATE UNIQUE INDEX IF NOT EXISTS {0s}jobs_unique ON {0s}jobs (unique_key) WHERE unique_key IS NOT NULL;
        \\CREATE TABLE IF NOT EXISTS {0s}cron (name text PRIMARY KEY, spec text NOT NULL, last_tick timestamptz);
        \\CREATE TABLE IF NOT EXISTS {0s}leader (name text PRIMARY KEY, owner text NOT NULL, until timestamptz NOT NULL);
    , .{prefix});
}
