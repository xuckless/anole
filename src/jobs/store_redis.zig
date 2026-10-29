//! The Redis/Valkey job store (J2, §4.3): single-node, every state change
//! one Lua script call (src/jobs/redis.lua, loaded with SCRIPT LOAD and run
//! by EVALSHA, loaded again on NOSCRIPT). Durability is Redis's own: with
//! AOF `appendfsync everysec` a crash can lose the last second of
//! acknowledged enqueues. Transactional enqueue and complete are not
//! available on this store.
const std = @import("std");
const anole = @import("../root.zig");
const root = @import("root.zig");
const store = @import("store.zig");

const redis = anole.redis;
const db = anole.db;
const Reply = redis.Reply;
const Time = root.Time;
const Id = root.Id;
const State = root.State;

const script = @embedFile("redis.lua");

fn ms(t: Time) i64 {
    return @divFloor(t.us, 1000);
}
fn fromMs(v: i64) Time {
    return Time.fromMillis(v);
}

pub const Redis = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    client: *redis.Client,
    /// "anole:" (the key prefix; the script adds "jobs:").
    prefix: []const u8,
    notify: bool,
    sha: [40]u8,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, client: *redis.Client, key_prefix: []const u8, notify: bool) !store.Backend {
        const self = try gpa.create(Redis);
        errdefer gpa.destroy(self);
        var digest: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(script, &digest, .{});
        self.* = .{ .gpa = gpa, .io = io, .client = client, .prefix = try gpa.dupe(u8, key_prefix), .notify = notify, .sha = std.fmt.bytesToHex(digest, .lower) };
        return .{ .ptr = self, .vt = &vtable };
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
    };

    fn me(ptr: *anyopaque) *Redis {
        return @ptrCast(@alignCast(ptr));
    }

    fn deinit(ptr: *anyopaque) void {
        const self = me(ptr);
        self.gpa.free(self.prefix);
        self.gpa.destroy(self);
    }

    const Scratch = struct {
        arena_state: std.heap.ArenaAllocator,
        ctx: db.Ctx,

        fn start(s: *Scratch, self: *Redis) void {
            s.arena_state = .init(self.gpa);
            s.ctx = .{ .io = self.io, .arena = s.arena_state.allocator() };
        }
        fn deinit(s: *Scratch) void {
            s.arena_state.deinit();
        }
    };

    fn q(self: *Redis) redis.Query {
        return self.client.with(.{});
    }

    fn migrate(ptr: *anyopaque) anyerror!void {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        _ = try self.q().reply(&sc.ctx, &.{ "SCRIPT", "LOAD", script });
        // Eviction would drop job keys under memory pressure. Managed
        // services may forbid CONFIG: then there is nothing to check.
        if (self.q().reply(&sc.ctx, &.{ "CONFIG", "GET", "maxmemory-policy" })) |r| {
            const found = items(r);
            if (found.len >= 2) {
                if (found[1].text()) |policy| {
                    if (!std.mem.eql(u8, policy, "noeviction"))
                        std.log.scoped(.anole).warn("jobs: Redis may evict job keys under memory pressure (maxmemory-policy is {s}): set maxmemory-policy noeviction", .{policy});
                }
            }
        } else |_| {}
    }

    // ---- script calls

    /// `EVALSHA` of the script with `op` and `args`; the script is loaded
    /// again once when the server does not know it.
    fn call(self: *Redis, ctx: *db.Ctx, op: []const u8, args: []const []const u8) !Reply {
        const a = ctx.arena;
        var full: std.ArrayList([]const u8) = .empty;
        try full.appendSlice(a, &.{ "EVALSHA", &self.sha, "0", self.prefix, op });
        try full.appendSlice(a, args);
        return self.q().reply(ctx, full.items) catch |first| {
            if (first == error.Canceled or first == error.OutOfMemory) return first;
            _ = try self.q().reply(ctx, &.{ "SCRIPT", "LOAD", script });
            return self.q().reply(ctx, full.items);
        };
    }

    fn num(a: std.mem.Allocator, v: anytype) ![]const u8 {
        return std.fmt.allocPrint(a, "{d}", .{v});
    }

    fn items(r: Reply) []const Reply {
        return switch (r) {
            .array, .map => |x| x,
            else => &.{},
        };
    }
    fn asInt(r: Reply) i64 {
        return switch (r) {
            .int => |i| i,
            .string, .status => |s| std.fmt.parseInt(i64, s, 10) catch 0,
            .double => |d| @intFromFloat(d),
            .boolean => |b| @intFromBool(b),
            else => 0,
        };
    }

    // ---- rows

    const Fields = struct {
        pairs: []const Reply,

        fn get(f: Fields, name: []const u8) ?[]const u8 {
            var i: usize = 0;
            while (i + 1 < f.pairs.len) : (i += 2) {
                if (f.pairs[i].text()) |k| if (std.mem.eql(u8, k, name)) return f.pairs[i + 1].text();
            }
            return null;
        }
        fn int(f: Fields, name: []const u8) i64 {
            return if (f.get(name)) |s| (std.fmt.parseInt(i64, s, 10) catch 0) else 0;
        }
        fn opt(f: Fields, name: []const u8) ?i64 {
            return if (f.get(name)) |s| (std.fmt.parseInt(i64, s, 10) catch null) else null;
        }
    };

    fn rowFrom(arena: std.mem.Allocator, r: Reply) !?store.Row {
        const f: Fields = .{ .pairs = items(r) };
        if (f.pairs.len == 0) return null;
        const errors = std.json.parseFromSliceLeaky([]root.ErrorEntry, arena, f.get("errors") orelse "[]", .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch &[_]root.ErrorEntry{};
        return .{
            .id = f.int("id"),
            .queue = try arena.dupe(u8, f.get("queue") orelse ""),
            .kind = try arena.dupe(u8, f.get("kind") orelse ""),
            .state = std.meta.stringToEnum(State, f.get("state") orelse "") orelse .available,
            .priority = @fromBackingInt(@intCast(@min(3, @max(0, f.int("priority"))))),
            .attempt = @intCast(f.int("attempt")),
            .max_attempts = @intCast(f.int("max_attempts")),
            .args_json = try arena.dupe(u8, f.get("args") orelse "null"),
            .meta_json = try arena.dupe(u8, f.get("meta") orelse "{}"),
            .run_at = fromMs(f.int("run_at")),
            .created_at = fromMs(f.int("created_at")),
            .attempted_at = if (f.opt("attempted_at")) |v| fromMs(v) else null,
            .finished_at = if (f.opt("finished_at")) |v| fromMs(v) else null,
            .worker = if (f.get("worker")) |w| try arena.dupe(u8, w) else null,
            .errors = errors,
            .timeout_ms = if (f.opt("timeout_ms")) |t| @intCast(t) else null,
        };
    }

    fn rowsFrom(arena: std.mem.Allocator, r: Reply) ![]store.Row {
        var out: std.ArrayList(store.Row) = .empty;
        for (items(r)) |one| if (try rowFrom(arena, one)) |row| try out.append(arena, row);
        return out.items;
    }

    // ---- insert

    fn enqueueArgs(a: std.mem.Allocator, args_list: *std.ArrayList([]const u8), now: Time, job: store.NewJob, notify: bool) !void {
        try args_list.append(a, try num(a, ms(now)));
        try args_list.append(a, job.queue);
        try args_list.append(a, job.kind);
        try args_list.append(a, job.args_json);
        try args_list.append(a, job.meta_json);
        try args_list.append(a, try num(a, @backingInt(job.priority)));
        try args_list.append(a, try num(a, job.max_attempts));
        try args_list.append(a, try num(a, ms(job.run_at)));
        try args_list.append(a, if (job.timeout_ms) |t| try num(a, t) else "");
        if (job.unique) |u| {
            const hex = std.fmt.bytesToHex(u.key, .lower);
            try args_list.append(a, try a.dupe(u8, &hex));
            try args_list.append(a, try num(a, @backingInt(u.scope)));
        } else {
            try args_list.append(a, "");
            try args_list.append(a, "");
        }
        try args_list.append(a, if (notify) "1" else "0");
    }

    fn insert(ptr: *anyopaque, now: Time, job: store.NewJob) anyerror!root.Enqueued {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        var args: std.ArrayList([]const u8) = .empty;
        try enqueueArgs(sc.ctx.arena, &args, now, job, self.notify);
        const r = items(try self.call(&sc.ctx, "enqueue", args.items));
        if (r.len < 2) return error.Database;
        return .{ .id = asInt(r[0]), .inserted = asInt(r[1]) == 1 };
    }

    // ---- claim and friends

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
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(a, &.{ try num(a, ms(req.now)), try num(a, ms(req.lease_until)), req.worker, req.queue, try num(a, req.limit) });
        if (req.kinds) |ks| {
            if (ks.len == 0) return &.{};
            try args.appendSlice(a, ks);
        }
        const reply = try self.call(&sc.ctx, "claim", args.items);
        const rows = try rowsFrom(arena, reply);
        std.mem.sort(store.Row, rows, {}, byOrder);
        return rows;
    }

    fn stage(ptr: *anyopaque, now: Time) anyerror!u32 {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        const a = sc.ctx.arena;
        const r = try self.call(&sc.ctx, "stage", &.{ try num(a, ms(now)), "1000", if (self.notify) "1" else "0" });
        return @intCast(@max(0, asInt(r)));
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
            var args: std.ArrayList([]const u8) = .empty;
            try args.append(a, try num(a, ms(until)));
            for (chunk) |h| {
                try args.append(a, try num(a, h.id));
                try args.append(a, try num(a, h.attempt));
            }
            // The renewed runs as id, attempt pairs.
            const got = items(try self.call(&sc.ctx, "heartbeat", args.items));
            if (got.len % 2 != 0) return error.Database;
            var k: usize = 0;
            while (k < got.len) : (k += 2) try out.append(arena, .{ .id = asInt(got[k]), .attempt = @intCast(asInt(got[k + 1])) });
        }
        return out.items;
    }

    fn finish(ptr: *anyopaque, f: store.Finish) anyerror!bool {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        const a = sc.ctx.arena;
        const err_json: []const u8 = if (f.add_error) |e| try std.json.Stringify.valueAlloc(a, e, .{}) else "";
        const r = try self.call(&sc.ctx, "finish", &.{
            try num(a, f.id),
            try num(a, f.attempt),
            @tagName(f.to),
            try num(a, f.attempt_delta),
            if (f.run_at) |t| try num(a, ms(t)) else "",
            if (f.finished_at) |t| try num(a, ms(t)) else "",
            err_json,
            if (self.notify) "1" else "0",
        });
        return asInt(r) == 1;
    }

    fn rescue(ptr: *anyopaque, arena: std.mem.Allocator, now: Time) anyerror![]store.Rescued {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        const a = sc.ctx.arena;
        const at = try std.fmt.allocPrint(a, "{f}", .{now});
        const r = items(try self.call(&sc.ctx, "rescue", &.{ try num(a, ms(now)), "1000", at, if (self.notify) "1" else "0" }));
        const out = try arena.alloc(store.Rescued, r.len / 2);
        for (out, 0..) |*d, i| d.* = .{ .id = asInt(r[2 * i]), .dead = asInt(r[2 * i + 1]) == 1 };
        return out;
    }

    fn prune(ptr: *anyopaque, now: Time, keep: root.Options.Keep) anyerror!u32 {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        const a = sc.ctx.arena;
        var n: u32 = 0;
        const spans = [_]struct { []const u8, root.Duration }{ .{ "completed", keep.completed }, .{ "dead", keep.dead }, .{ "cancelled", keep.cancelled } };
        for (spans) |s| {
            const r = try self.call(&sc.ctx, "prune", &.{ s[0], try num(a, ms(now) - root.millis(s[1])), "1000" });
            n += @intCast(@max(0, asInt(r)));
        }
        return n;
    }

    fn get(ptr: *anyopaque, arena: std.mem.Allocator, id: Id) anyerror!?store.Row {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        const key = try std.fmt.allocPrint(sc.ctx.arena, "{s}jobs:job:{d}", .{ self.prefix, id });
        const r = try self.q().reply(&sc.ctx, &.{ "HGETALL", key });
        return rowFrom(arena, r);
    }

    fn list(ptr: *anyopaque, arena: std.mem.Allocator, filter: root.Filter) anyerror![]store.Row {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        const a = sc.ctx.arena;
        const r = try self.call(&sc.ctx, "list", &.{
            if (filter.state) |s| @tagName(s) else "",
            filter.queue orelse "",
            filter.kind orelse "",
            if (filter.before) |b| try num(a, b) else "",
            try num(a, @max(filter.limit, 1)),
        });
        return rowsFrom(arena, r);
    }

    fn counts(ptr: *anyopaque, arena: std.mem.Allocator) anyerror![]root.Count {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        var out: std.ArrayList(root.Count) = .empty;
        for (items(try self.call(&sc.ctx, "counts", &.{}))) |e| {
            const t = items(e);
            if (t.len < 3) continue;
            try out.append(arena, .{
                .queue = try arena.dupe(u8, t[0].text() orelse ""),
                .state = std.meta.stringToEnum(State, t[1].text() orelse "") orelse .available,
                .n = @intCast(asInt(t[2])),
            });
        }
        return out.items;
    }

    fn adminRetry(ptr: *anyopaque, now: Time, id: Id) anyerror!bool {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        const a = sc.ctx.arena;
        return asInt(try self.call(&sc.ctx, "retry", &.{ try num(a, id), try num(a, ms(now)), if (self.notify) "1" else "0" })) == 1;
    }
    fn adminCancel(ptr: *anyopaque, now: Time, id: Id) anyerror!bool {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        const a = sc.ctx.arena;
        return asInt(try self.call(&sc.ctx, "cancel", &.{ try num(a, id), try num(a, ms(now)) })) == 1;
    }
    fn adminDelete(ptr: *anyopaque, id: Id) anyerror!bool {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        return asInt(try self.call(&sc.ctx, "delete", &.{try num(sc.ctx.arena, id)})) == 1;
    }

    // ---- cron

    fn cronRow(self: *Redis, ctx: *db.Ctx, arena: std.mem.Allocator, name: []const u8) !?store.CronRow {
        const key = try std.fmt.allocPrint(ctx.arena, "{s}jobs:cron:{s}", .{ self.prefix, name });
        const f: Fields = .{ .pairs = items(try self.q().reply(ctx, &.{ "HGETALL", key })) };
        if (f.pairs.len == 0) return null;
        return .{
            .name = try arena.dupe(u8, name),
            .spec = try arena.dupe(u8, f.get("spec") orelse ""),
            .last_tick = if (f.opt("last_tick")) |v| fromMs(v) else null,
        };
    }

    fn cronGet(ptr: *anyopaque, arena: std.mem.Allocator, name: []const u8) anyerror!?store.CronRow {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        return self.cronRow(&sc.ctx, arena, name);
    }

    fn cronList(ptr: *anyopaque, arena: std.mem.Allocator) anyerror![]store.CronRow {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        const key = try std.fmt.allocPrint(sc.ctx.arena, "{s}jobs:crons", .{self.prefix});
        const names = items(try self.q().reply(&sc.ctx, &.{ "SMEMBERS", key }));
        var out: std.ArrayList(store.CronRow) = .empty;
        for (names) |n| {
            if (n.text()) |name| if (try self.cronRow(&sc.ctx, arena, name)) |row| try out.append(arena, row);
        }
        return out.items;
    }

    fn cronSet(ptr: *anyopaque, name: []const u8, spec: []const u8, last_tick: Time) anyerror!void {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        _ = try self.call(&sc.ctx, "cron_set", &.{ name, spec, try num(sc.ctx.arena, ms(last_tick)) });
    }

    fn cronTick(ptr: *anyopaque, now: Time, name: []const u8, spec: []const u8, tick: Time, job: ?store.NewJob) anyerror!store.CronTick {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        const a = sc.ctx.arena;
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(a, &.{ name, spec, try num(a, ms(tick)) });
        if (job) |j| try enqueueArgs(a, &args, now, j, self.notify);
        const r = items(try self.call(&sc.ctx, "cron_tick", args.items));
        if (r.len < 3 or asInt(r[0]) != 1) return .{ .recorded = false };
        if (job != null) return .{ .recorded = true, .enqueued = .{ .id = asInt(r[1]), .inserted = asInt(r[2]) == 1 } };
        return .{ .recorded = true };
    }

    // ---- leader

    fn leaderTake(ptr: *anyopaque, owner: []const u8, now: Time, ttl: root.Duration) anyerror!bool {
        _ = now;
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        return asInt(try self.call(&sc.ctx, "leader_take", &.{ owner, try num(sc.ctx.arena, root.millis(ttl)) })) == 1;
    }

    /// SUBSCRIBE to `<key prefix>jobs:wake` (the scripts PUBLISH the queue name there).
    fn runWake(ptr: *anyopaque, io: std.Io, wake: store.Wake) anyerror!void {
        const self = me(ptr);
        if (!self.notify) return;
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        var ctx: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };
        const channel = try std.fmt.allocPrint(ctx.arena, "{s}jobs:wake", .{self.prefix});
        const sub = try self.client.subscribe(&ctx, .{channel});
        defer sub.close();
        wake.kick(wake.context, "");
        while (try sub.next(&ctx)) |m| wake.kick(wake.context, m.payload);
        return error.SubscriptionClosed;
    }

    fn leaderRelease(ptr: *anyopaque, owner: []const u8) anyerror!void {
        const self = me(ptr);
        var sc: Scratch = undefined;
        sc.start(self);
        defer sc.deinit();
        _ = try self.call(&sc.ctx, "leader_release", &.{owner});
    }
};
