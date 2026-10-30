//! The in-process job store (J2, §4.4): tests and single-process apps that
//! accept losing jobs when the process stops. It is the reference for the
//! other stores' semantics. Scans are linear: it is not meant for millions
//! of jobs.
const std = @import("std");
const safety = @import("anole_safety");
const root = @import("root.zig");
const store = @import("store.zig");

const Time = root.Time;
const Id = root.Id;
const State = root.State;

const MemRow = struct {
    id: Id,
    queue: []u8,
    kind: []u8,
    state: State,
    priority: root.Priority,
    attempt: u16 = 0,
    max_attempts: u16,
    args: []u8,
    meta: []u8,
    run_at: Time,
    created_at: Time,
    attempted_at: ?Time = null,
    finished_at: ?Time = null,
    lease_until: ?Time = null,
    worker: ?[]u8 = null,
    errors: std.ArrayList(root.ErrorEntry) = .empty,
    timeout_ms: ?u32 = null,
    unique: ?store.UniqueKey = null,
};

const Cron = struct { spec: []u8, last_tick: ?Time };

pub const Memory = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Every row, unique key, cron and the leader. A leaf: no store call
    /// is made under another lock, and nothing is taken under it.
    mutex: safety.Mutex(.leaf) = .init,
    rows: std.AutoArrayHashMapUnmanaged(Id, *MemRow) = .empty,
    next_id: Id = 1,
    uniques: std.AutoHashMapUnmanaged([16]u8, Id) = .empty,
    crons: std.StringHashMapUnmanaged(Cron) = .empty,
    leader: ?struct { owner: []u8, until: Time } = null,

    pub fn create(gpa: std.mem.Allocator, io: std.Io) !store.Backend {
        const self = try gpa.create(Memory);
        self.* = .{ .gpa = gpa, .io = io };
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
    };

    fn me(ptr: *anyopaque) *Memory {
        return @ptrCast(@alignCast(ptr));
    }
    fn lock(self: *Memory) void {
        self.mutex.lockUncancelable(self.io);
    }
    fn unlock(self: *Memory) void {
        self.mutex.unlock(self.io);
    }

    fn freeRow(self: *Memory, r: *MemRow) void {
        const g = self.gpa;
        g.free(r.queue);
        g.free(r.kind);
        g.free(r.args);
        g.free(r.meta);
        if (r.worker) |w| g.free(w);
        for (r.errors.items) |e| {
            g.free(e.@"error");
            g.free(e.message);
        }
        r.errors.deinit(g);
        g.destroy(r);
    }

    fn deinit(ptr: *anyopaque) void {
        const self = me(ptr);
        var it = self.rows.iterator();
        while (it.next()) |e| self.freeRow(e.value_ptr.*);
        self.rows.deinit(self.gpa);
        self.uniques.deinit(self.gpa);
        var ci = self.crons.iterator();
        while (ci.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.spec);
        }
        self.crons.deinit(self.gpa);
        if (self.leader) |l| self.gpa.free(l.owner);
        self.gpa.destroy(self);
    }

    fn migrate(ptr: *anyopaque) anyerror!void {
        _ = ptr;
    }

    /// Moves a row to `to`, keeping its unique key only while the scope covers it.
    fn setState(self: *Memory, r: *MemRow, to: State) void {
        r.state = to;
        if (r.unique) |u| {
            if (!store.covers(u.scope, to)) {
                _ = self.uniques.remove(u.key);
                r.unique = null;
            }
        }
    }

    fn insert(ptr: *anyopaque, now: Time, job: store.NewJob) anyerror!root.Enqueued {
        const self = me(ptr);
        self.lock();
        defer self.unlock();
        if (job.unique) |u| {
            if (self.uniques.get(u.key)) |existing| return .{ .id = existing, .inserted = false };
        }
        const g = self.gpa;
        const r = try g.create(MemRow);
        errdefer g.destroy(r);
        const queue = try g.dupe(u8, job.queue);
        errdefer g.free(queue);
        const kind = try g.dupe(u8, job.kind);
        errdefer g.free(kind);
        const args = try g.dupe(u8, job.args_json);
        errdefer g.free(args);
        const meta = try g.dupe(u8, job.meta_json);
        errdefer g.free(meta);
        const id = self.next_id;
        r.* = .{
            .id = id,
            .queue = queue,
            .kind = kind,
            .state = if (job.run_at.us <= now.us) .available else .scheduled,
            .priority = job.priority,
            .max_attempts = job.max_attempts,
            .args = args,
            .meta = meta,
            .run_at = job.run_at,
            .created_at = now,
            .timeout_ms = job.timeout_ms,
            .unique = job.unique,
        };
        try self.rows.put(g, id, r);
        errdefer _ = self.rows.swapRemove(id);
        if (job.unique) |u| try self.uniques.put(g, u.key, id);
        self.next_id += 1;
        return .{ .id = id, .inserted = true };
    }

    fn snapshot(arena: std.mem.Allocator, r: *const MemRow) !store.Row {
        const errs = try arena.alloc(root.ErrorEntry, r.errors.items.len);
        for (r.errors.items, errs) |src, *dst| dst.* = .{ .attempt = src.attempt, .at = src.at, .@"error" = try arena.dupe(u8, src.@"error"), .message = try arena.dupe(u8, src.message) };
        return .{
            .id = r.id,
            .queue = try arena.dupe(u8, r.queue),
            .kind = try arena.dupe(u8, r.kind),
            .state = r.state,
            .priority = r.priority,
            .attempt = r.attempt,
            .max_attempts = r.max_attempts,
            .args_json = try arena.dupe(u8, r.args),
            .meta_json = try arena.dupe(u8, r.meta),
            .run_at = r.run_at,
            .created_at = r.created_at,
            .attempted_at = r.attempted_at,
            .finished_at = r.finished_at,
            .worker = if (r.worker) |w| try arena.dupe(u8, w) else null,
            .errors = errs,
            .timeout_ms = r.timeout_ms,
        };
    }

    fn before(_: void, a: *MemRow, b: *MemRow) bool {
        if (a.priority != b.priority) return @backingInt(a.priority) < @backingInt(b.priority);
        if (a.run_at.us != b.run_at.us) return a.run_at.us < b.run_at.us;
        return a.id < b.id;
    }

    fn claim(ptr: *anyopaque, arena: std.mem.Allocator, req: store.ClaimRequest) anyerror![]store.Row {
        const self = me(ptr);
        self.lock();
        defer self.unlock();
        var cands: std.ArrayList(*MemRow) = .empty;
        defer cands.deinit(self.gpa);
        var it = self.rows.iterator();
        while (it.next()) |e| {
            const r = e.value_ptr.*;
            if (r.state != .available or !std.mem.eql(u8, r.queue, req.queue)) continue;
            if (req.kinds) |ks| {
                var ok = false;
                for (ks) |k| if (std.mem.eql(u8, k, r.kind)) {
                    ok = true;
                    break;
                };
                if (!ok) continue;
            }
            try cands.append(self.gpa, r);
        }
        std.mem.sort(*MemRow, cands.items, {}, before);
        const n = @min(cands.items.len, req.limit);
        const out = try arena.alloc(store.Row, n);
        for (cands.items[0..n], out) |r, *dst| {
            self.setState(r, .running);
            r.attempt += 1;
            r.attempted_at = req.now;
            r.lease_until = req.lease_until;
            if (r.worker) |w| self.gpa.free(w);
            r.worker = try self.gpa.dupe(u8, req.worker);
            dst.* = try snapshot(arena, r);
        }
        return out;
    }

    fn stage(ptr: *anyopaque, now: Time) anyerror!u32 {
        const self = me(ptr);
        self.lock();
        defer self.unlock();
        var n: u32 = 0;
        var it = self.rows.iterator();
        while (it.next()) |e| {
            const r = e.value_ptr.*;
            if ((r.state == .scheduled or r.state == .retrying) and r.run_at.us <= now.us) {
                r.state = .available;
                n += 1;
            }
        }
        return n;
    }

    fn heartbeat(ptr: *anyopaque, arena: std.mem.Allocator, until: Time, held: []const store.Held) anyerror![]store.Held {
        const self = me(ptr);
        self.lock();
        defer self.unlock();
        var out: std.ArrayList(store.Held) = .empty;
        for (held) |h| {
            const r = self.rows.get(h.id) orelse continue;
            if (r.state != .running or r.attempt != h.attempt) continue;
            r.lease_until = until;
            try out.append(arena, h);
        }
        return out.items;
    }

    fn finish(ptr: *anyopaque, f: store.Finish) anyerror!bool {
        const self = me(ptr);
        self.lock();
        defer self.unlock();
        const r = self.rows.get(f.id) orelse return false;
        if (r.state != .running or r.attempt != f.attempt) return false;
        self.setState(r, f.to);
        if (f.attempt_delta < 0) r.attempt -= 1;
        if (f.run_at) |t| r.run_at = t;
        r.finished_at = f.finished_at;
        r.lease_until = null;
        if (f.to == .available or f.to == .scheduled) {
            if (r.worker) |w| self.gpa.free(w);
            r.worker = null;
        }
        if (f.add_error) |e| try self.addError(r, e);
        return true;
    }

    fn addError(self: *Memory, r: *MemRow, e: root.ErrorEntry) !void {
        const g = self.gpa;
        const err = try g.dupe(u8, e.@"error");
        errdefer g.free(err);
        const msg = try g.dupe(u8, e.message);
        errdefer g.free(msg);
        try r.errors.append(g, .{ .attempt = e.attempt, .at = e.at, .@"error" = err, .message = msg });
        while (r.errors.items.len > store.max_errors) {
            const old = r.errors.orderedRemove(0);
            g.free(old.@"error");
            g.free(old.message);
        }
    }

    fn rescue(ptr: *anyopaque, arena: std.mem.Allocator, now: Time) anyerror![]store.Rescued {
        const self = me(ptr);
        self.lock();
        defer self.unlock();
        var out: std.ArrayList(store.Rescued) = .empty;
        var it = self.rows.iterator();
        while (it.next()) |e| {
            const r = e.value_ptr.*;
            if (r.state != .running) continue;
            const lease = r.lease_until orelse continue;
            if (lease.us >= now.us) continue;
            const dead = r.attempt >= r.max_attempts;
            self.setState(r, if (dead) .dead else .available);
            r.finished_at = if (dead) now else null;
            r.lease_until = null;
            if (r.worker) |w| self.gpa.free(w);
            r.worker = null;
            try self.addError(r, .{ .attempt = r.attempt, .at = now, .@"error" = "LeaseExpired", .message = "the worker running it stopped or lost the database" });
            try out.append(arena, .{ .id = r.id, .dead = dead });
        }
        return out.items;
    }

    fn prune(ptr: *anyopaque, now: Time, keep: root.Options.Keep) anyerror!u32 {
        const self = me(ptr);
        self.lock();
        defer self.unlock();
        var doomed: std.ArrayList(Id) = .empty;
        defer doomed.deinit(self.gpa);
        var it = self.rows.iterator();
        while (it.next()) |e| {
            const r = e.value_ptr.*;
            const span = switch (r.state) {
                .completed => keep.completed,
                .dead => keep.dead,
                .cancelled => keep.cancelled,
                else => continue,
            };
            const fin = r.finished_at orelse continue;
            if (fin.us + root.micros(span) < now.us) try doomed.append(self.gpa, r.id);
        }
        for (doomed.items) |id| self.remove(id);
        return @intCast(doomed.items.len);
    }

    fn remove(self: *Memory, id: Id) void {
        if (self.rows.fetchSwapRemove(id)) |kv| {
            const r = kv.value;
            if (r.unique) |u| _ = self.uniques.remove(u.key);
            self.freeRow(r);
        }
    }

    fn get(ptr: *anyopaque, arena: std.mem.Allocator, id: Id) anyerror!?store.Row {
        const self = me(ptr);
        self.lock();
        defer self.unlock();
        const r = self.rows.get(id) orelse return null;
        return try snapshot(arena, r);
    }

    fn newerId(_: void, a: *MemRow, b: *MemRow) bool {
        return a.id > b.id;
    }

    fn list(ptr: *anyopaque, arena: std.mem.Allocator, filter: root.Filter) anyerror![]store.Row {
        const self = me(ptr);
        self.lock();
        defer self.unlock();
        var hits: std.ArrayList(*MemRow) = .empty;
        defer hits.deinit(self.gpa);
        var it = self.rows.iterator();
        while (it.next()) |e| {
            const r = e.value_ptr.*;
            if (filter.state) |s| if (r.state != s) continue;
            if (filter.queue) |q| if (!std.mem.eql(u8, r.queue, q)) continue;
            if (filter.kind) |k| if (!std.mem.eql(u8, r.kind, k)) continue;
            if (filter.before) |b| if (r.id >= b) continue;
            try hits.append(self.gpa, r);
        }
        std.mem.sort(*MemRow, hits.items, {}, newerId);
        const n = @min(hits.items.len, @max(filter.limit, 1));
        const out = try arena.alloc(store.Row, n);
        for (hits.items[0..n], out) |r, *dst| dst.* = try snapshot(arena, r);
        return out;
    }

    fn counts(ptr: *anyopaque, arena: std.mem.Allocator) anyerror![]root.Count {
        const self = me(ptr);
        self.lock();
        defer self.unlock();
        var out: std.ArrayList(root.Count) = .empty;
        var it = self.rows.iterator();
        while (it.next()) |e| {
            const r = e.value_ptr.*;
            switch (r.state) {
                .scheduled, .available, .running, .retrying, .dead => {},
                else => continue,
            }
            var found = false;
            for (out.items) |*c| {
                if (c.state == r.state and std.mem.eql(u8, c.queue, r.queue)) {
                    c.n += 1;
                    found = true;
                    break;
                }
            }
            if (!found) try out.append(arena, .{ .queue = try arena.dupe(u8, r.queue), .state = r.state, .n = 1 });
        }
        return out.items;
    }

    fn adminRetry(ptr: *anyopaque, now: Time, id: Id) anyerror!bool {
        const self = me(ptr);
        self.lock();
        defer self.unlock();
        const r = self.rows.get(id) orelse return false;
        switch (r.state) {
            .dead, .cancelled, .retrying, .scheduled => {},
            else => return false,
        }
        self.setState(r, .available);
        r.run_at = now;
        r.finished_at = null;
        r.max_attempts = @max(r.max_attempts, r.attempt + 1);
        return true;
    }

    fn adminCancel(ptr: *anyopaque, now: Time, id: Id) anyerror!bool {
        const self = me(ptr);
        self.lock();
        defer self.unlock();
        const r = self.rows.get(id) orelse return false;
        switch (r.state) {
            .scheduled, .available, .retrying, .running => {},
            else => return false,
        }
        self.setState(r, .cancelled);
        r.finished_at = now;
        r.lease_until = null;
        return true;
    }

    fn adminDelete(ptr: *anyopaque, id: Id) anyerror!bool {
        const self = me(ptr);
        self.lock();
        defer self.unlock();
        const r = self.rows.get(id) orelse return false;
        switch (r.state) {
            .completed, .dead, .cancelled => {},
            else => return false,
        }
        self.remove(id);
        return true;
    }

    fn cronGet(ptr: *anyopaque, arena: std.mem.Allocator, name: []const u8) anyerror!?store.CronRow {
        const self = me(ptr);
        self.lock();
        defer self.unlock();
        const c = self.crons.get(name) orelse return null;
        return .{ .name = try arena.dupe(u8, name), .spec = try arena.dupe(u8, c.spec), .last_tick = c.last_tick };
    }

    fn cronList(ptr: *anyopaque, arena: std.mem.Allocator) anyerror![]store.CronRow {
        const self = me(ptr);
        self.lock();
        defer self.unlock();
        var out: std.ArrayList(store.CronRow) = .empty;
        var it = self.crons.iterator();
        while (it.next()) |e| try out.append(arena, .{ .name = try arena.dupe(u8, e.key_ptr.*), .spec = try arena.dupe(u8, e.value_ptr.spec), .last_tick = e.value_ptr.last_tick });
        return out.items;
    }

    fn cronPut(self: *Memory, name: []const u8, spec: []const u8, tick: Time) !void {
        const gop = try self.crons.getOrPut(self.gpa, name);
        if (!gop.found_existing) {
            gop.key_ptr.* = self.gpa.dupe(u8, name) catch |e| {
                _ = self.crons.remove(name);
                return e;
            };
            gop.value_ptr.* = .{ .spec = &.{}, .last_tick = null };
        }
        const spec_copy = try self.gpa.dupe(u8, spec);
        self.gpa.free(gop.value_ptr.spec);
        gop.value_ptr.* = .{ .spec = spec_copy, .last_tick = tick };
    }

    fn cronSet(ptr: *anyopaque, name: []const u8, spec: []const u8, last_tick: Time) anyerror!void {
        const self = me(ptr);
        self.lock();
        defer self.unlock();
        try self.cronPut(name, spec, last_tick);
    }

    fn cronTick(ptr: *anyopaque, now: Time, name: []const u8, spec: []const u8, tick: Time, job: ?store.NewJob) anyerror!store.CronTick {
        const self = me(ptr);
        {
            self.lock();
            defer self.unlock();
            if (self.crons.get(name)) |c| {
                if (c.last_tick) |lt| if (lt.us >= tick.us) return .{ .recorded = false };
            }
            try self.cronPut(name, spec, tick);
        }
        if (job) |j| return .{ .recorded = true, .enqueued = try insert(ptr, now, j) };
        return .{ .recorded = true };
    }

    fn leaderTake(ptr: *anyopaque, owner: []const u8, now: Time, ttl: root.Duration) anyerror!bool {
        const self = me(ptr);
        self.lock();
        defer self.unlock();
        if (self.leader) |l| {
            if (!std.mem.eql(u8, l.owner, owner) and l.until.us > now.us) return false;
            self.gpa.free(l.owner);
        }
        self.leader = .{ .owner = try self.gpa.dupe(u8, owner), .until = .{ .us = now.us + root.micros(ttl) } };
        return true;
    }

    fn leaderRelease(ptr: *anyopaque, owner: []const u8) anyerror!void {
        const self = me(ptr);
        self.lock();
        defer self.unlock();
        if (self.leader) |l| if (std.mem.eql(u8, l.owner, owner)) {
            self.gpa.free(l.owner);
            self.leader = null;
        };
    }
};
