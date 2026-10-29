//! The SQLite job store (J2, §4.2): the tables of §4.1 with SQLite types
//! (times as Unix milliseconds). Every statement that writes runs on the
//! database's writer, so claims need no `SKIP LOCKED` (Solid Queue's
//! approach). Wakes are in-process only; other processes on the same file
//! see work at their next poll.
const std = @import("std");
const anole = @import("../root.zig");
const root = @import("root.zig");
const store = @import("store.zig");

const sqlite = anole.sqlite;
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

pub const Sqlite = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    client: *sqlite.Client,
    prefix: []const u8,
    /// Statement text, built once: `p` replaced by the table prefix.
    sql_buf: std.heap.ArenaAllocator,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, client: *sqlite.Client, prefix: []const u8) !store.Backend {
        const self = try gpa.create(Sqlite);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .client = client, .prefix = try gpa.dupe(u8, prefix), .sql_buf = .init(gpa) };
        return .{ .ptr = self, .vt = &vtable, .transactional = true, .tx_kind = .sqlite, .owner = client };
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
        .insertIn = insertIn,
        .finishIn = finishInErased,
    };

    fn me(ptr: *anyopaque) *Sqlite {
        return @ptrCast(@alignCast(ptr));
    }

    fn deinit(ptr: *anyopaque) void {
        const self = me(ptr);
        self.sql_buf.deinit();
        self.gpa.free(self.prefix);
        self.gpa.destroy(self);
    }

    /// A scratch context for one store call.
    const Scratch = struct {
        arena_state: std.heap.ArenaAllocator,
        ctx: db.Ctx,

        fn start(s: *Scratch, self: *Sqlite) void {
            s.arena_state = .init(self.gpa);
            s.ctx = .{ .io = self.io, .arena = s.arena_state.allocator() };
        }
        fn deinit(s: *Scratch) void {
            s.arena_state.deinit();
        }
    };

    fn sqlf(self: *Sqlite, a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]const u8 {
        _ = self;
        return std.fmt.allocPrint(a, fmt, args);
    }

    /// `fmt` with every `{p}` replaced by the prefix.
    fn text(self: *Sqlite, a: std.mem.Allocator, comptime fmt: []const u8) ![]const u8 {
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

    fn w(self: *Sqlite) sqlite.Query {
        return self.client.with(.{ .write = true });
    }

    fn migrate(ptr: *anyopaque) anyerror!void {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        const ddl = try ddlText(sc.ctx.arena, self.prefix);
        try self.client.execScript(&sc.ctx, ddl);
    }

    // ---- values

    fn int(v: V) i64 {
        return switch (v) {
            .int => |i| i,
            .float => |f| @intFromFloat(f),
            .bool => |b| @intFromBool(b),
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

    const row_cols = "id, queue, kind, state, priority, attempt, max_attempts, args, meta, run_at_ms, created_at_ms, attempted_at_ms, finished_at_ms, worker, errors, timeout_ms";

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
        // `table` rows live in the scratch arena of the call; the caller's arena outlives it.
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
        "INSERT INTO {p}jobs (queue, kind, args, meta, state, priority, max_attempts, run_at_ms, created_at_ms, timeout_ms, unique_key, unique_scope) " ++
        "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12) " ++
        "ON CONFLICT (unique_key) WHERE unique_key IS NOT NULL DO NOTHING RETURNING id";

    /// Runs the insert on `runner` (a `Query` or a transaction's), looking up
    /// the existing job when a unique key matched.
    pub fn insertOn(self: *Sqlite, runner: anytype, ctx: *db.Ctx, now: Time, job: store.NewJob) !root.Enqueued {
        const a = ctx.arena;
        const stmt = try self.text(a, insert_sql);
        const lookup = try self.text(a, "SELECT id FROM {p}jobs WHERE unique_key = ?1");
        var tries: u32 = 0;
        while (tries < 3) : (tries += 1) {
            const params = [_]V{
                .{ .text = job.queue },
                .{ .text = job.kind },
                .{ .text = job.args_json },
                .{ .text = job.meta_json },
                .{ .text = if (job.run_at.us <= now.us) "available" else "scheduled" },
                .{ .int = @backingInt(job.priority) },
                .{ .int = job.max_attempts },
                .{ .int = ms(job.run_at) },
                .{ .int = ms(now) },
                if (job.timeout_ms) |t| V{ .int = t } else V.null,
                if (job.unique) |u| V{ .blob = &u.key } else V.null,
                if (job.unique) |u| V{ .int = @backingInt(u.scope) } else V.null,
            };
            const t = try runner.table(ctx, stmt, &params);
            if (t.rows.len > 0) return .{ .id = int(t.rows[0][0]), .inserted = true };
            const u = job.unique orelse return error.Database;
            const found = try runner.table(ctx, lookup, &.{V{ .blob = &u.key }});
            if (found.rows.len > 0) return .{ .id = int(found.rows[0][0]), .inserted = false };
        }
        return error.Conflict;
    }

    fn insert(ptr: *anyopaque, now: Time, job: store.NewJob) anyerror!root.Enqueued {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        return self.insertOn(self.w(), &sc.ctx, now, job);
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
                try kinds_sql.print(a, "?{d}", .{6 + i});
                try params.append(a, .{ .text = k });
            }
            try kinds_sql.append(a, ')');
        }
        const stmt = try std.fmt.allocPrint(
            a,
            "UPDATE {s}jobs SET state = 'running', attempt = attempt + 1, attempted_at_ms = ?3, lease_until_ms = ?4, worker = ?5, " ++
                "unique_key = CASE WHEN unique_scope = 1 THEN NULL ELSE unique_key END " ++
                "WHERE id IN (SELECT id FROM {s}jobs WHERE state = 'available' AND queue = ?1{s} ORDER BY priority, run_at_ms, id LIMIT ?2) " ++
                "RETURNING " ++ row_cols,
            .{ self.prefix, self.prefix, kinds_sql.items },
        );
        const t = try self.w().table(&sc.ctx, stmt, params.items);
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
        const stmt = try self.text(sc.ctx.arena, "UPDATE {p}jobs SET state = 'available' WHERE state IN ('scheduled','retrying') AND run_at_ms <= ?1");
        const c = try self.w().execValues(&sc.ctx, stmt, &.{V{ .int = ms(now) }});
        return @intCast(c.changes);
    }

    fn heartbeat(ptr: *anyopaque, arena: std.mem.Allocator, until: Time, held: []const store.Held) anyerror![]store.Held {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        const stmt = try self.text(sc.ctx.arena, "UPDATE {p}jobs SET lease_until_ms = ?1 WHERE id = ?2 AND attempt = ?3 AND state = 'running'");
        var out: std.ArrayList(store.Held) = .empty;
        for (held) |h| {
            const c = try self.w().execValues(&sc.ctx, stmt, &.{ V{ .int = ms(until) }, V{ .int = h.id }, V{ .int = h.attempt } });
            if (c.changes > 0) try out.append(arena, h);
        }
        return out.items;
    }

    /// Conditional state change of a held job; `extra_errors` text is the
    /// already merged error list (`null`: unchanged).
    fn finishOn(self: *Sqlite, runner: anytype, ctx: *db.Ctx, f: store.Finish) !bool {
        const a = ctx.arena;
        const sel = try self.text(a, "SELECT errors, unique_scope FROM {p}jobs WHERE id = ?1 AND attempt = ?2 AND state = 'running'");
        const cur = try runner.table(ctx, sel, &.{ V{ .int = f.id }, V{ .int = f.attempt } });
        if (cur.rows.len == 0) return false;
        var errors_text: V = .null;
        if (f.add_error) |e| {
            var errs: std.ArrayList(root.ErrorEntry) = .empty;
            const old = std.json.parseFromSliceLeaky([]root.ErrorEntry, a, str(cur.rows[0][0]), .{ .ignore_unknown_fields = true }) catch &[_]root.ErrorEntry{};
            try errs.appendSlice(a, old);
            try errs.append(a, e);
            const start = if (errs.items.len > store.max_errors) errs.items.len - store.max_errors else 0;
            errors_text = .{ .text = try std.json.Stringify.valueAlloc(a, errs.items[start..], .{}) };
        }
        const keep = if (optInt(cur.rows[0][1])) |sc| store.covers(@fromBackingInt(@intCast(sc)), f.to) else false;
        const stmt = try self.text(a, "UPDATE {p}jobs SET state = ?3, attempt = attempt + ?4, run_at_ms = coalesce(?5, run_at_ms), finished_at_ms = ?6, lease_until_ms = NULL, " ++
            "worker = CASE WHEN ?3 IN ('available','scheduled') THEN NULL ELSE worker END, errors = coalesce(?7, errors), " ++
            "unique_key = CASE WHEN ?8 THEN unique_key ELSE NULL END WHERE id = ?1 AND attempt = ?2 AND state = 'running'");
        const c = try runner.execValues(ctx, stmt, &.{
            V{ .int = f.id },
            V{ .int = f.attempt },
            V{ .text = @tagName(f.to) },
            V{ .int = f.attempt_delta },
            optTimeV(f.run_at),
            optTimeV(f.finished_at),
            errors_text,
            V{ .bool = keep },
        });
        return c.changes > 0;
    }

    pub fn finishIn(self: *Sqlite, tx: anytype, ctx: *db.Ctx, f: store.Finish) !bool {
        return self.finishOn(tx, ctx, f);
    }

    fn insertIn(ptr: *anyopaque, txp: *anyopaque, ctx: *db.Ctx, now: Time, job: store.NewJob) anyerror!root.Enqueued {
        const tx: *sqlite.Tx = @ptrCast(@alignCast(txp));
        return me(ptr).insertOn(tx, ctx, now, job);
    }

    fn finishInErased(ptr: *anyopaque, txp: *anyopaque, ctx: *db.Ctx, f: store.Finish) anyerror!bool {
        const tx: *sqlite.Tx = @ptrCast(@alignCast(txp));
        return me(ptr).finishOn(tx, ctx, f);
    }

    fn finish(ptr: *anyopaque, f: store.Finish) anyerror!bool {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        return self.finishOn(self.w(), &sc.ctx, f);
    }

    fn rescue(ptr: *anyopaque, arena: std.mem.Allocator, now: Time) anyerror![]store.Rescued {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        const sel = try self.text(sc.ctx.arena, "SELECT id, attempt, max_attempts FROM {p}jobs WHERE state = 'running' AND lease_until_ms < ?1 ORDER BY lease_until_ms LIMIT 1000");
        const t = try self.w().table(&sc.ctx, sel, &.{V{ .int = ms(now) }});
        var out: std.ArrayList(store.Rescued) = .empty;
        for (t.rows) |r| {
            const attempt: u16 = @intCast(int(r[1]));
            const dead = attempt >= int(r[2]);
            const ok = try self.finishOn(self.w(), &sc.ctx, .{
                .id = int(r[0]),
                .attempt = attempt,
                .to = if (dead) .dead else .available,
                .finished_at = if (dead) now else null,
                .add_error = .{ .attempt = attempt, .at = now, .@"error" = "LeaseExpired", .message = "the worker running it stopped or lost the database" },
            });
            if (ok) try out.append(arena, .{ .id = int(r[0]), .dead = dead });
        }
        return out.items;
    }

    fn prune(ptr: *anyopaque, now: Time, keep: root.Options.Keep) anyerror!u32 {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        const stmt = try self.text(sc.ctx.arena, "DELETE FROM {p}jobs WHERE id IN (SELECT id FROM {p}jobs WHERE state = ?1 AND finished_at_ms < ?2 LIMIT 1000)");
        var n: u32 = 0;
        const spans = [_]struct { []const u8, root.Duration }{ .{ "completed", keep.completed }, .{ "dead", keep.dead }, .{ "cancelled", keep.cancelled } };
        for (spans) |s| {
            const c = try self.w().execValues(&sc.ctx, stmt, &.{ V{ .text = s[0] }, V{ .int = ms(now) - root.millis(s[1]) } });
            n += @intCast(c.changes);
        }
        return n;
    }

    fn get(ptr: *anyopaque, arena: std.mem.Allocator, id: Id) anyerror!?store.Row {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        const stmt = try self.text(sc.ctx.arena, "SELECT " ++ row_cols ++ " FROM {p}jobs WHERE id = ?1");
        const t = try self.client.with(.{}).table(&sc.ctx, stmt, &.{V{ .int = id }});
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
        try where.appendSlice(a, "1 = 1");
        if (filter.state) |s| {
            try params.append(a, .{ .text = @tagName(s) });
            try where.print(a, " AND state = ?{d}", .{params.items.len});
        }
        if (filter.queue) |q| {
            try params.append(a, .{ .text = q });
            try where.print(a, " AND queue = ?{d}", .{params.items.len});
        }
        if (filter.kind) |k| {
            try params.append(a, .{ .text = k });
            try where.print(a, " AND kind = ?{d}", .{params.items.len});
        }
        if (filter.before) |b| {
            try params.append(a, .{ .int = b });
            try where.print(a, " AND id < ?{d}", .{params.items.len});
        }
        try params.append(a, .{ .int = @max(filter.limit, 1) });
        const stmt = try std.fmt.allocPrint(a, "SELECT " ++ row_cols ++ " FROM {s}jobs WHERE {s} ORDER BY id DESC LIMIT ?{d}", .{ self.prefix, where.items, params.items.len });
        const t = try self.client.with(.{}).table(&sc.ctx, stmt, params.items);
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
        const t = try self.client.with(.{}).table(&sc.ctx, stmt, &.{});
        const out = try arena.alloc(root.Count, t.rows.len);
        for (t.rows, out) |r, *d| d.* = .{ .queue = try arena.dupe(u8, str(r[0])), .state = std.meta.stringToEnum(State, str(r[1])) orelse .available, .n = @intCast(int(r[2])) };
        return out;
    }

    fn adminOp(self: *Sqlite, comptime fmt: []const u8, params: []const V) !bool {
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        const stmt = try self.text(sc.ctx.arena, fmt);
        const c = try self.w().execValues(&sc.ctx, stmt, params);
        return c.changes > 0;
    }

    fn adminRetry(ptr: *anyopaque, now: Time, id: Id) anyerror!bool {
        return me(ptr).adminOp("UPDATE {p}jobs SET state = 'available', run_at_ms = ?2, finished_at_ms = NULL, max_attempts = max(max_attempts, attempt + 1) WHERE id = ?1 AND state IN ('dead','cancelled','retrying','scheduled')", &.{ V{ .int = id }, V{ .int = ms(now) } });
    }
    fn adminCancel(ptr: *anyopaque, now: Time, id: Id) anyerror!bool {
        return me(ptr).adminOp("UPDATE {p}jobs SET state = 'cancelled', finished_at_ms = ?2, lease_until_ms = NULL, unique_key = CASE WHEN unique_scope = 3 THEN unique_key ELSE NULL END WHERE id = ?1 AND state IN ('scheduled','available','retrying','running')", &.{ V{ .int = id }, V{ .int = ms(now) } });
    }
    fn adminDelete(ptr: *anyopaque, id: Id) anyerror!bool {
        return me(ptr).adminOp("DELETE FROM {p}jobs WHERE id = ?1 AND state IN ('completed','dead','cancelled')", &.{V{ .int = id }});
    }

    // ---- cron

    fn cronGet(ptr: *anyopaque, arena: std.mem.Allocator, name: []const u8) anyerror!?store.CronRow {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        const stmt = try self.text(sc.ctx.arena, "SELECT name, spec, last_tick_ms FROM {p}cron WHERE name = ?1");
        const t = try self.client.with(.{}).table(&sc.ctx, stmt, &.{V{ .text = name }});
        if (t.rows.len == 0) return null;
        const r = t.rows[0];
        return .{ .name = try arena.dupe(u8, str(r[0])), .spec = try arena.dupe(u8, str(r[1])), .last_tick = optTime(r[2]) };
    }

    fn cronList(ptr: *anyopaque, arena: std.mem.Allocator) anyerror![]store.CronRow {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        const stmt = try self.text(sc.ctx.arena, "SELECT name, spec, last_tick_ms FROM {p}cron");
        const t = try self.client.with(.{}).table(&sc.ctx, stmt, &.{});
        const out = try arena.alloc(store.CronRow, t.rows.len);
        for (t.rows, out) |r, *d| d.* = .{ .name = try arena.dupe(u8, str(r[0])), .spec = try arena.dupe(u8, str(r[1])), .last_tick = optTime(r[2]) };
        return out;
    }

    fn cronSet(ptr: *anyopaque, name: []const u8, spec: []const u8, last_tick: Time) anyerror!void {
        _ = try me(ptr).adminOp("INSERT INTO {p}cron (name, spec, last_tick_ms) VALUES (?1, ?2, ?3) ON CONFLICT (name) DO UPDATE SET spec = excluded.spec, last_tick_ms = excluded.last_tick_ms", &.{ V{ .text = name }, V{ .text = spec }, V{ .int = ms(last_tick) } });
    }

    const TickArgs = struct { self: *Sqlite, now: Time, name: []const u8, spec: []const u8, tick: Time, job: ?store.NewJob };

    fn tickTx(tx: *sqlite.Tx, ctx: *db.Ctx, ta: TickArgs) anyerror!store.CronTick {
        const a = ctx.arena;
        const stmt = try ta.self.text(a, "INSERT INTO {p}cron (name, spec, last_tick_ms) VALUES (?1, ?2, ?3) ON CONFLICT (name) DO UPDATE SET last_tick_ms = excluded.last_tick_ms, spec = excluded.spec " ++
            "WHERE {p}cron.last_tick_ms IS NULL OR {p}cron.last_tick_ms < excluded.last_tick_ms RETURNING name");
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
        const stmt = try self.text(sc.ctx.arena, "INSERT INTO {p}leader (name, owner, until_ms) VALUES ('jobs', ?1, ?2) ON CONFLICT (name) DO UPDATE SET owner = excluded.owner, until_ms = excluded.until_ms " ++
            "WHERE {p}leader.owner = excluded.owner OR {p}leader.until_ms < ?3 RETURNING owner");
        const t = try self.w().table(&sc.ctx, stmt, &.{ V{ .text = owner }, V{ .int = ms(now) + root.millis(ttl) }, V{ .int = ms(now) } });
        return t.rows.len > 0;
    }

    fn leaderRelease(ptr: *anyopaque, owner: []const u8) anyerror!void {
        _ = try me(ptr).adminOp("DELETE FROM {p}leader WHERE name = 'jobs' AND owner = ?1", &.{V{ .text = owner }});
    }
};

/// The DDL of `sql(.sqlite, ...)`.
pub fn ddlText(arena: std.mem.Allocator, prefix: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\CREATE TABLE IF NOT EXISTS {0s}schema (component TEXT PRIMARY KEY, version INTEGER NOT NULL);
        \\CREATE TABLE IF NOT EXISTS {0s}jobs (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  queue TEXT NOT NULL,
        \\  kind TEXT NOT NULL,
        \\  args TEXT NOT NULL,
        \\  meta TEXT NOT NULL DEFAULT '{{}}',
        \\  state TEXT NOT NULL CHECK (state IN ('scheduled','available','running','retrying','completed','dead','cancelled')),
        \\  priority INTEGER NOT NULL CHECK (priority BETWEEN 0 AND 3),
        \\  attempt INTEGER NOT NULL DEFAULT 0,
        \\  max_attempts INTEGER NOT NULL CHECK (max_attempts BETWEEN 1 AND 1000),
        \\  run_at_ms INTEGER NOT NULL,
        \\  created_at_ms INTEGER NOT NULL,
        \\  attempted_at_ms INTEGER,
        \\  finished_at_ms INTEGER,
        \\  lease_until_ms INTEGER,
        \\  worker TEXT,
        \\  errors TEXT NOT NULL DEFAULT '[]',
        \\  timeout_ms INTEGER,
        \\  unique_key BLOB,
        \\  unique_scope INTEGER
        \\);
        \\CREATE INDEX IF NOT EXISTS {0s}jobs_claim ON {0s}jobs (queue, priority, run_at_ms, id) WHERE state = 'available';
        \\CREATE INDEX IF NOT EXISTS {0s}jobs_due ON {0s}jobs (run_at_ms) WHERE state IN ('scheduled','retrying');
        \\CREATE INDEX IF NOT EXISTS {0s}jobs_lease ON {0s}jobs (lease_until_ms) WHERE state = 'running';
        \\CREATE INDEX IF NOT EXISTS {0s}jobs_finished ON {0s}jobs (state, finished_at_ms) WHERE state IN ('completed','dead','cancelled');
        \\CREATE INDEX IF NOT EXISTS {0s}jobs_list ON {0s}jobs (queue, state, id);
        \\CREATE UNIQUE INDEX IF NOT EXISTS {0s}jobs_unique ON {0s}jobs (unique_key) WHERE unique_key IS NOT NULL;
        \\CREATE TABLE IF NOT EXISTS {0s}cron (name TEXT PRIMARY KEY, spec TEXT NOT NULL, last_tick_ms INTEGER);
        \\CREATE TABLE IF NOT EXISTS {0s}leader (name TEXT PRIMARY KEY, owner TEXT NOT NULL, until_ms INTEGER NOT NULL);
        \\INSERT OR IGNORE INTO {0s}schema (component, version) VALUES ('jobs', 1);
    , .{prefix});
}
