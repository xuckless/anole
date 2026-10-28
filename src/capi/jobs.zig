//! `anole_jobs_*` and `anole_job_*`: durable jobs enqueued and worked by a
//! consumer (p3/jobs, design-jobs.md §10). Handle kinds 12 (`anole_job_worker`)
//! and 13 (`anole_job`); events 104-108.
//!
//! A language worker is a handler of the Zig queue (`anole.jobs.Client`) that
//! hands the job to the consumer and waits for `anole_job_finish`: leases,
//! heartbeats, timeouts, retries and the drain are the queue's own, the same
//! as for Zig handlers. No executor ever calls into the language: a job is an
//! `ANOLE_EV_JOB` record on the consumer's ring, its handle owed one finish.
//!
//! Enqueue is a command for an executor, whose task calls the store and
//! queues `ANOLE_EV_JOB_ENQUEUED`. With a transaction (`opts.tx`) the inserts
//! are calls on that transaction and are answered as its `ANOLE_EV_DB_RESULT`
//! (a table of `id` and `inserted`), see `txOp`.
const std = @import("std");
const anole = @import("../root.zig");
const dusty = @import("dusty");
const engine = @import("engine.zig");
const abi = @import("abi.zig");
const config_mod = @import("config.zig");
const nats_cap = @import("nats.zig");
const db = @import("db.zig");

const features = anole.features;
const placement = dusty.placement;
const gpa = engine.gpa;
const Engine = engine.Engine;
const Exec = engine.Exec;
const Consumer = engine.Consumer;
const Command = engine.Command;
const Handle = engine.Handle;
const AnswerError = engine.AnswerError;
const Table = nats_cap.Table;
const log = std.log.scoped(.anole);

const J = if (features.jobs) anole.jobs else struct {
    pub const Client = opaque {};
    pub const Job = opaque {};
    pub const EnqueueOptions = struct {};
};

/// An administrative operation of another area ("webhooks.*"), set by that
/// area's `open`: writes the JSON answer, returns the HTTP status.
pub const AdminFn = fn (e: *Engine, ctx: *anole.db.Ctx, op: []const u8, request: std.json.Value, w: *std.Io.Writer) anyerror!u16;

/// Engine-wide state (`Engine.jobs_state`).
pub const State = struct {
    /// The queue behind `"jobs"` in the configuration, once `open` ran
    /// (the webhooks lane reads it); null when there is none.
    client: if (features.jobs) ?*J.Client else ?*anyopaque = null,
    workers: Table(*Worker) = .{},
    jobs: Table(*JobSlot) = .{},
    /// Every worker made, freed at `destroy`.
    made: std.ArrayList(*Worker) = .empty,
    made_lock: std.atomic.Mutex = .unlocked,
    /// `"webhooks.*"` operations of `anole_jobs_admin`.
    webhooks_admin: ?*const AdminFn = null,

    pub fn init(s: *State, first_gen: u32) void {
        s.workers.first_gen = first_gen;
        s.jobs.first_gen = first_gen;
    }

    /// The highest generation handed out (`Engine.destroy`).
    pub fn maxGen(s: *State) u32 {
        return @max(s.workers.maxGen(), s.jobs.maxGen());
    }

    pub fn deinit(s: *State) void {
        s.workers.deinit();
        s.jobs.deinit();
        s.made.deinit(gpa);
    }
};

/// Per executor (`Exec.jobs`): the tasks it runs are canceled at the stop.
pub const ExecState = struct {
    work: std.Io.Group = .init,

    pub fn cancel(st: *ExecState, io: std.Io) void {
        st.work.cancel(io);
    }

    /// The highest generation handed out (`Engine.destroy`).
    pub fn maxGen(st: *const ExecState) u32 {
        _ = st;
        return 0;
    }

    pub fn deinit(st: *ExecState) void {
        _ = st;
    }
};

/// The state `txOp` and the handlers reach without an engine argument (one
/// server per process).
var active: ?*Engine = null;

// ---------------------------------------------------------------------------
// Opening

fn invalid(comptime fmt: []const u8, args: anytype) error{InvalidOptions} {
    log.err("jobs: " ++ fmt, args);
    return error.InvalidOptions;
}

/// The server's main thread, before the listeners open (after `db.open`,
/// `nats.open` and `kafka.open`).
pub fn open(e: *Engine, app: *anole.App) !void {
    const jc = e.config.jobs orelse return;
    if (comptime !features.jobs) {
        return invalid("jobs are not built in (-Djobs)", .{});
    } else try openJobs(e, app, jc);
}

fn openJobs(e: *Engine, app: *anole.App, jc: config_mod.Config.Jobs) !void {
    const ms = std.Io.Duration.fromMilliseconds;
    for (jc.queues, 0..) |q, i| {
        for (jc.queues[0..i]) |p| if (std.mem.eql(u8, p.name, q.name)) return invalid("queue \"{s}\" is listed twice", .{q.name});
    }
    const arena = app.arena.allocator();
    var queues = try arena.alloc(J.QueueOptions, jc.queues.len);
    for (jc.queues, queues[0..]) |q, *d| d.* = .{ .name = q.name, .concurrency = q.concurrency };
    var kinds = try arena.alloc(J.Kind, jc.kinds.len);
    for (jc.kinds, kinds[0..], 0..) |k, *d, i| {
        if (std.mem.startsWith(u8, k.name, "anole.")) return invalid("kinds[{d}]: names starting with \"anole.\" are reserved", .{i});
        for (jc.kinds[0..i]) |p| if (std.mem.eql(u8, p.name, k.name)) return invalid("kind \"{s}\" is listed twice", .{k.name});
        d.* = .{
            .name = k.name,
            .queue = k.queue,
            .priority = std.meta.stringToEnum(J.Priority, k.priority) orelse return invalid("kinds[{d}].priority: critical, high, normal or low", .{i}),
            .attempts = k.attempts,
            .timeout = if (k.timeout_ms == 0) .max else ms(@intCast(k.timeout_ms)),
        };
    }
    var store: J.Store = .memory;
    if (!std.mem.eql(u8, jc.store, "memory")) {
        const d = db.find(e, jc.store) orelse return invalid("store \"{s}\": no such database", .{jc.store});
        switch (d.client) {
            .postgres => |c| if (comptime features.postgres) {
                store = .{ .postgres = c };
            } else unreachable,
            .sqlite => |c| if (comptime features.sqlite) {
                store = .{ .sqlite = c };
            } else unreachable,
            .redis => |c| if (comptime features.redis) {
                store = .{ .redis = c };
            } else unreachable,
            else => return invalid("store \"{s}\": MongoDB cannot hold jobs", .{jc.store}),
        }
    }
    const client = try app.jobs(.{
        .store = store,
        .queues = queues,
        .run = .auto,
        .lease = ms(jc.lease_ms),
        .poll_interval = ms(jc.poll_ms),
        .migrate = jc.migrate,
        .notify = jc.notify,
        .table_prefix = jc.table_prefix,
        .key_prefix = jc.key_prefix,
        .kinds = kinds,
        .drain_timeout = ms(jc.drain_ms),
        .gate = .{ .context = e, .is_open = running },
        .keep = .{ .completed = ms(@intCast(jc.keep.completed_ms)), .dead = ms(@intCast(jc.keep.dead_ms)), .cancelled = ms(@intCast(jc.keep.cancelled_ms)) },
        .leader = .{
            .method = std.meta.stringToEnum(J.Options.Leader.Method, jc.leader.method) orelse return invalid("leader.method: auto, advisory_lock or lease_row", .{}),
            .ttl = ms(jc.leader.ttl_ms),
            .renew = ms(jc.leader.renew_ms),
        },
    });
    e.jobs_state.client = client;
    active = e;

    var sql_kind = false;
    for (jc.cron) |c| {
        if ((c.kind == null) == (c.sql == null)) return invalid("cron \"{s}\": exactly one of kind and sql", .{c.name});
        const missed = std.meta.stringToEnum(J.CronOptions.Missed, c.missed) orelse return invalid("cron \"{s}\".missed: once, skip or all", .{c.name});
        var args_json: []const u8 = "{}";
        var kind: []const u8 = undefined;
        if (c.sql) |q| {
            if (db.find(e, q.database) == null) return invalid("cron \"{s}\".sql.database \"{s}\": no such database", .{ c.name, q.database });
            sql_kind = true;
            kind = "anole.sql";
            args_json = try std.json.Stringify.valueAlloc(arena, .{ .database = q.database, .statement = q.statement }, .{});
        } else {
            kind = c.kind.?;
            if (c.args) |v| args_json = try std.json.Stringify.valueAlloc(arena, v, .{});
        }
        client.cronRaw(c.name, c.schedule, kind, args_json, .{
            .tz = c.tz,
            .missed = missed,
            .catch_up = ms(c.catch_up_ms),
        }) catch return error.InvalidOptions;
    }
    if (sql_kind) client.addHandler(.{ .name = "anole.sql", .attempts = 5, .timeout = ms(60_000) }, e, sqlHandler) catch return error.InvalidOptions;
}

/// The gate of the queue's workers: they claim once the server runs.
fn running(ctx: ?*anyopaque) bool {
    const e: *Engine = @ptrCast(@alignCast(ctx.?));
    return switch (e.phase.load(.acquire)) {
        .running, .draining => true,
        else => false,
    };
}

/// The native cron action: one statement on a configured database.
fn sqlHandler(ctx: ?*anyopaque, job: *J.Job) anyerror!void {
    const e: *Engine = @ptrCast(@alignCast(ctx.?));
    const Args = struct { database: []const u8, statement: []const u8 };
    const args = try job.args(Args);
    const d = db.find(e, args.database) orelse {
        job.discard("the database is not in the configuration");
        return;
    };
    var c: anole.db.Ctx = .{ .io = job.io, .arena = job.arena };
    switch (d.client) {
        .sqlite => |cl| if (comptime features.sqlite) {
            _ = try cl.with(.{ .timeout = .fromSeconds(30) }).exec(&c, args.statement, .{});
        } else unreachable,
        .postgres => |cl| if (comptime features.postgres) {
            _ = try cl.with(.{ .timeout = .fromSeconds(30) }).exec(&c, args.statement, .{});
        } else unreachable,
        else => {
            job.discard("only SQLite and PostgreSQL run statements");
        },
    }
}

/// The drain started (`anole_server_drain`, once): workers take no more
/// jobs; each ends when its last job is over.
pub fn draining(e: *Engine) void {
    const t = &e.jobs_state.workers;
    t.acquire();
    var list: std.ArrayList(*Worker) = .empty;
    defer list.deinit(gpa);
    for (t.entries.items) |en| {
        if (en.live) list.append(gpa, en.value) catch {};
    }
    t.release();
    for (list.items) |w| {
        w.end_reason.store(abi.JOB_WORKER_DRAINED, .release);
        w.stopped.store(true, .release);
        maybeEnd(w);
    }
}

/// The server stops: nothing new starts from here.
pub fn close(e: *Engine) void {
    _ = e;
}

/// `anole_server_destroy`: frees what a stopped server still holds.
pub fn destroy(e: *Engine) void {
    const s = &e.jobs_state;
    for (s.made.items) |w| {
        for (w.kinds) |k| gpa.free(k);
        gpa.free(w.kinds);
        gpa.free(w.queue);
        gpa.destroy(w);
    }
    s.made.clearRetainingCapacity();
    active = null;
}

// ---------------------------------------------------------------------------
// Records

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

fn enqueuedRecord(user_data: u64, status: i32, http: u16, class: u8, entries: []const abi.JobEnqueuedEntry, message: []const u8) ![]align(8) u8 {
    const Ev = abi.JobEnqueuedEvent;
    const entries_off = @sizeOf(Ev);
    const bytes_off = entries_off + entries.len * @sizeOf(abi.JobEnqueuedEntry);
    const rec = try engine.newRecord(bytes_off + message.len, .job_enqueued, 0);
    const ev: *Ev = @ptrCast(rec.ptr);
    var w: Writer = .{ .rec = rec, .at = bytes_off };
    ev.user_data = user_data;
    ev.status = status;
    ev.http_status = http;
    ev.error_class = class;
    ev.entries_off = @intCast(entries_off);
    ev.nentries = @intCast(entries.len);
    if (entries.len > 0) @memcpy(rec[entries_off..][0 .. entries.len * @sizeOf(abi.JobEnqueuedEntry)], std.mem.sliceAsBytes(entries));
    ev.@"error" = w.put(message);
    return rec;
}

fn resultRecord(user_data: u64, status: i32, http: u16, json: []const u8, message: []const u8) ![]align(8) u8 {
    const Ev = abi.JobsResultEvent;
    const rec = try engine.newRecord(@sizeOf(Ev) + json.len + message.len, .jobs_result, 0);
    const ev: *Ev = @ptrCast(rec.ptr);
    var w: Writer = .{ .rec = rec, .at = @sizeOf(Ev) };
    ev.user_data = user_data;
    ev.status = status;
    ev.http_status = http;
    ev.json = w.put(json);
    ev.@"error" = w.put(message);
    return rec;
}

fn cancelRecord(handle: u64, user_data: u64, id: i64, reason: u32) ![]align(8) u8 {
    const Ev = abi.JobCancelEvent;
    const rec = try engine.newRecord(@sizeOf(Ev), .job_cancel, handle);
    const ev: *Ev = @ptrCast(rec.ptr);
    ev.user_data = user_data;
    ev.id = id;
    ev.reason = reason;
    return rec;
}

fn workerEndRecord(w: *Worker, reason: u32, message: []const u8) ![]align(8) u8 {
    const Ev = abi.JobWorkerEndEvent;
    const rec = try engine.newRecord(@sizeOf(Ev) + message.len, .job_worker_end, w.handle);
    const ev: *Ev = @ptrCast(rec.ptr);
    var wr: Writer = .{ .rec = rec, .at = @sizeOf(Ev) };
    ev.user_data = w.user_data;
    ev.reason = reason;
    ev.@"error" = wr.put(message);
    return rec;
}

fn jobRecord(w: *Worker, handle: u64, job: *J.Job) ![]align(8) u8 {
    const Ev = abi.JobEvent;
    const a = job.arena;
    const errors_json = try std.json.Stringify.valueAlloc(a, job.errors, .{});
    const tp = job.traceparent() orelse "";
    const cron = job.cronName() orelse "";
    const total = job.kind.len + job.queue.len + job.args_json.len + job.meta_json.len + errors_json.len + cron.len + tp.len;
    const rec = try engine.newRecord(@sizeOf(Ev) + total, .job, handle);
    const ev: *Ev = @ptrCast(rec.ptr);
    var wr: Writer = .{ .rec = rec, .at = @sizeOf(Ev) };
    ev.user_data = w.user_data;
    ev.worker = w.handle;
    ev.id = job.id;
    ev.kind = wr.put(job.kind);
    ev.queue = wr.put(job.queue);
    ev.args = wr.put(job.args_json);
    ev.meta = wr.put(job.meta_json);
    ev.errors = wr.put(errors_json);
    ev.run_at_ms = @divFloor(job.run_at.us, 1000);
    ev.created_at_ms = @divFloor(job.created_at.us, 1000);
    ev.timeout_us = if (job.timeout_ms) |t| @as(i64, t) * 1000 else -1;
    ev.attempt = job.attempt;
    ev.max_attempts = job.max_attempts;
    ev.priority = @backingInt(job.priority) + 1;
    ev.cron = wr.put(cron);
    ev.traceparent = wr.put(tp);
    return rec;
}

// ---------------------------------------------------------------------------
// Workers

pub const Worker = struct {
    engine: *Engine,
    consumer: *Consumer,
    x: *Exec,
    user_data: u64,
    queue: []const u8,
    slots: std.Io.Semaphore,
    handle: u64 = 0,
    index: u32 = 0,
    out: std.atomic.Value(u32) = .init(0),
    stopped: std.atomic.Value(bool) = .init(false),
    ended: std.atomic.Value(bool) = .init(false),
    end_reason: std.atomic.Value(u32) = .init(abi.JOB_WORKER_STOPPED),
    /// The kinds it runs (owned), or every kind of its queue.
    kinds: []const []const u8 = &.{},
    all_kinds: bool = false,
};

pub const JobSlot = struct {
    worker: *Worker,
    id: i64,
    attempt: u16,
    user_data: u64,
    index: u32 = 0,
    handle: u64 = 0,
    event: std.Io.Event = .unset,
    /// Under the jobs table's lock.
    finished: bool = false,
    outcome: u32 = 0,
    delay_ms: u32 = 0,
    text: []u8 = &.{},
    job: *J.Job,
};

pub const CallError = error{ Invalid, State, OutOfMemory, Unsupported, Gone };

/// `anole_jobs_work`: after `anole_server_open`, before the server starts.
pub fn work(e: *Engine, c: *Consumer, o: abi.JobsWorkOptions, user_data: u64) CallError!u64 {
    if (comptime !features.jobs) return error.Unsupported;
    const jc = e.config.jobs orelse return error.Unsupported;
    if (c.engine != e) return error.Invalid;
    switch (e.phase.load(.acquire)) {
        .open => {},
        else => return error.State,
    }
    const queue: []const u8 = if (o.queue.len == 0) "default" else o.queue.slice();
    var concurrency: u32 = 0;
    for (jc.queues) |q| if (std.mem.eql(u8, q.name, queue)) {
        concurrency = q.concurrency;
    };
    if (concurrency == 0) return error.Invalid;
    if (o.concurrency != 0) concurrency = o.concurrency;
    if (c.execs.items.len == 0) return error.State;
    const x = c.execs.items[c.next_db.fetchAdd(1, .monotonic) % c.execs.items.len];
    const s = &e.jobs_state;

    const w = gpa.create(Worker) catch return error.OutOfMemory;
    errdefer gpa.destroy(w);
    const qcopy = gpa.dupe(u8, queue) catch return error.OutOfMemory;
    errdefer gpa.free(qcopy);
    w.* = .{ .engine = e, .consumer = c, .x = x, .user_data = user_data, .queue = qcopy, .slots = .{ .permits = concurrency } };
    w.all_kinds = o.nkinds == 0;
    var kinds: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (kinds.items) |k| gpa.free(k);
        kinds.deinit(gpa);
    }

    while (!s.made_lock.tryLock()) std.atomic.spinLoopHint();
    defer s.made_lock.unlock();
    // No two workers run one kind, or all of a queue.
    for (s.made.items) |other| {
        if (!std.mem.eql(u8, other.queue, queue)) continue;
        if (other.all_kinds and w.all_kinds) return error.Invalid;
    }
    if (!w.all_kinds) {
        const given = (o.kinds orelse return error.Invalid)[0..o.nkinds];
        for (given) |k| {
            if (k.len == 0 or k.len > 128) return error.Invalid;
            for (s.made.items) |other| for (other.kinds) |ok| if (std.mem.eql(u8, ok, k.slice())) return error.Invalid;
            kinds.append(gpa, gpa.dupe(u8, k.slice()) catch return error.OutOfMemory) catch return error.OutOfMemory;
        }
    }
    const client = e.jobs_state.client orelse return error.Unsupported;
    if (w.all_kinds) {
        client.addCatchAll(queue, w, abiRun) catch return error.Invalid;
    } else {
        for (kinds.items) |k| if (client.hasHandler(k)) return error.Invalid;
        for (kinds.items) |k| {
            var def = client.kindDefaultsPublic(k);
            def.queue = qcopy;
            client.addHandler(def, w, abiRun) catch return error.Invalid;
        }
    }
    w.kinds = kinds.toOwnedSlice(gpa) catch return error.OutOfMemory;

    const t = &s.workers;
    t.acquire();
    const slot = t.alloc(w) catch {
        t.release();
        return error.OutOfMemory;
    };
    t.release();
    w.index = slot.index;
    w.handle = Handle.encode(.{ .gen = @intCast(slot.gen), .kind = .job_worker, .slot = @intCast(slot.index), .exec = x.index });
    s.made.append(gpa, w) catch return error.OutOfMemory;
    return w.handle;
}

fn workerOf(e: *Engine, hv: u64) ?*Worker {
    const t = &e.jobs_state.workers;
    t.acquire();
    defer t.release();
    const en = t.get(Handle.decode(hv)) orelse return null;
    return en.value;
}

/// `anole_jobs_stop`.
pub fn stop(e: *Engine, hv: u64) void {
    const w = workerOf(e, hv) orelse return;
    w.end_reason.store(abi.JOB_WORKER_STOPPED, .release);
    w.stopped.store(true, .release);
    maybeEnd(w);
}

fn maybeEnd(w: *Worker) void {
    if (!w.stopped.load(.acquire) or w.out.load(.acquire) != 0) return;
    if (w.ended.swap(true, .acq_rel)) return;
    const rec = workerEndRecord(w, w.end_reason.load(.acquire), "") catch return;
    w.x.postRecord(rec, false);
    const t = &w.engine.jobs_state.workers;
    t.acquire();
    defer t.release();
    if (t.get(Handle.decode(w.handle)) != null) t.drop(w.index);
}

/// The queue's handler for a language worker: hands the job to the consumer
/// and waits for its answer. A cancel (timeout, lost lease, admin, drain)
/// ends the wait; the consumer is told with `ANOLE_EV_JOB_CANCEL`.
fn abiRun(ctx: ?*anyopaque, job: *J.Job) anyerror!void {
    const w: *Worker = @ptrCast(@alignCast(ctx.?));
    const e = w.engine;
    const io = e.io;
    if (w.stopped.load(.acquire)) {
        job.snooze(.fromSeconds(1));
        return;
    }
    try w.slots.wait(io);
    defer w.slots.post(io);

    const slot = gpa.create(JobSlot) catch return error.OutOfMemory;
    slot.* = .{ .worker = w, .id = job.id, .attempt = job.attempt, .user_data = w.user_data, .job = job };
    const t = &e.jobs_state.jobs;
    t.acquire();
    const a = t.alloc(slot) catch {
        t.release();
        gpa.destroy(slot);
        return error.OutOfMemory;
    };
    t.release();
    slot.index = a.index;
    slot.handle = Handle.encode(.{ .gen = @intCast(a.gen), .kind = .job, .slot = @intCast(a.index), .exec = w.x.index });
    defer freeSlot(e, slot);

    _ = w.out.fetchAdd(1, .acq_rel);
    defer {
        _ = w.out.fetchSub(1, .acq_rel);
        maybeEnd(w);
    }
    const rec = jobRecord(w, slot.handle, job) catch return error.OutOfMemory;
    w.x.postRecord(rec, false);

    slot.event.wait(io) catch {
        // Canceled by the queue. A finish that got in first wins.
        t.acquire();
        const already = slot.finished;
        slot.finished = true;
        t.release();
        if (!already) {
            const reason: u32 = if (job.interrupted_flag != null and job.interrupted_flag.?.load(.acquire))
                abi.JOB_CANCEL_DRAIN
            else if (job.lost_flag != null and job.lost_flag.?.load(.acquire))
                (if (job.admin_cancelled.load(.acquire)) abi.JOB_CANCEL_ADMIN else abi.JOB_CANCEL_LEASE_LOST)
            else
                abi.JOB_CANCEL_TIMEOUT;
            if (cancelRecord(slot.handle, w.user_data, job.id, reason)) |r| w.x.postRecord(r, false) else |_| {}
            return error.Canceled;
        }
    };
    switch (slot.outcome) {
        abi.JOB_DONE => {},
        abi.JOB_RETRY => {
            if (slot.delay_ms > 0) job.retryIn(.fromMilliseconds(slot.delay_ms));
            job.explain("{s}", .{slot.text});
            return error.Application;
        },
        abi.JOB_SNOOZE => job.snooze(.fromMilliseconds(slot.delay_ms)),
        // The reason outlives the slot: it is stored after this handler returns.
        else => job.discard(job.arena.dupe(u8, slot.text) catch ""),
    }
}

fn freeSlot(e: *Engine, slot: *JobSlot) void {
    const t = &e.jobs_state.jobs;
    t.acquire();
    if (t.get(Handle.decode(slot.handle)) != null) t.drop(slot.index);
    t.release();
    gpa.free(slot.text);
    gpa.destroy(slot);
}

/// `anole_job_finish`.
pub fn finish(e: *Engine, hv: u64, outcome: u32, delay_ms: u32, text: []const u8) CallError!void {
    if (outcome > abi.JOB_DISCARD) return error.Invalid;
    const copy = gpa.dupe(u8, text) catch return error.OutOfMemory;
    const t = &e.jobs_state.jobs;
    t.acquire();
    const en = t.get(Handle.decode(hv)) orelse {
        t.release();
        gpa.free(copy);
        return error.Gone;
    };
    const slot = en.value;
    if (slot.finished) {
        t.release();
        gpa.free(copy);
        return error.Gone;
    }
    slot.finished = true;
    slot.outcome = outcome;
    slot.delay_ms = delay_ms;
    slot.text = copy;
    t.release();
    e.setEvent(&slot.event);
}

/// `anole_handle_release` for the kinds `job_worker` and `job` (a cleanup call: a handle that is
/// over answers `error.Over`, which is `ANOLE_OK`).
pub fn release(e: *Engine, hv: u64) AnswerError!void {
    switch (Handle.decode(hv).kind) {
        .job => finish(e, hv, abi.JOB_RETRY, 0, "released by the application") catch return error.Over,
        else => {
            stop(e, hv);
            return error.Over;
        },
    }
}

// ---------------------------------------------------------------------------
// Enqueue

/// One job as it crosses to the executor (and, for a transaction, as JSON).
const Wire = struct {
    kind: []const u8,
    args_json: []const u8 = "{}",
    queue: ?[]const u8 = null,
    meta_json: ?[]const u8 = null,
    run_at_ms: i64 = 0,
    delay_ms: u32 = 0,
    attempts: u16 = 0,
    /// 0: the kind's; 1..4 critical..low.
    priority: u8 = 0,
    timeout_ms: u32 = 0,
    unique: bool = false,
    unique_key: ?[]const u8 = null,
    unique_period_ms: u32 = 0,
    unique_scope: u8 = 0,
};

fn optionsOf(wi: Wire) J.EnqueueOptions {
    if (comptime !features.jobs) return .{};
    var o: J.EnqueueOptions = .{ .queue = wi.queue, .meta = wi.meta_json };
    if (wi.run_at_ms > 0) o.run_at = anole.db.Time.fromMillis(wi.run_at_ms);
    if (wi.delay_ms > 0) o.delay = .fromMilliseconds(wi.delay_ms);
    if (wi.attempts > 0) o.attempts = wi.attempts;
    if (wi.priority != 0) o.priority = @fromBackingInt(@intCast(wi.priority - 1));
    if (wi.timeout_ms == abi.DB_TIMEOUT_NONE) {
        o.timeout = .max;
    } else if (wi.timeout_ms > 0) o.timeout = .fromMilliseconds(wi.timeout_ms);
    if (wi.unique) o.unique = .{
        .key = wi.unique_key,
        .period = if (wi.unique_period_ms > 0) .fromMilliseconds(wi.unique_period_ms) else null,
        .scope = switch (wi.unique_scope) {
            abi.JOB_UNIQUE_PENDING => .pending,
            abi.JOB_UNIQUE_ANY => .any,
            else => .unfinished,
        },
    };
    return o;
}

/// The call's jobs copied into `a`, checked.
fn wireOf(a: std.mem.Allocator, outs: []const abi.JobOut) CallError![]Wire {
    if (outs.len == 0 or outs.len > 1000) return error.Invalid;
    const items = try a.alloc(Wire, outs.len);
    for (outs, items) |o, *d| {
        if (o.size != @sizeOf(abi.JobOut) or o.reserved != 0) return error.Invalid;
        if (o.kind.len == 0 or o.kind.len > 128) return error.Invalid;
        if (o.flags & ~abi.JOB_F_UNIQUE != 0) return error.Invalid;
        if (o.priority > abi.JOB_PRIORITY_LOW or o.unique_scope > abi.JOB_UNIQUE_ANY) return error.Invalid;
        if (o.run_at_ms != 0 and o.delay_ms != 0) return error.Invalid;
        const unique = o.flags & abi.JOB_F_UNIQUE != 0;
        if (!unique and (o.unique_key.len != 0 or o.unique_period_ms != 0 or o.unique_scope != 0)) return error.Invalid;
        d.* = .{
            .kind = try a.dupe(u8, o.kind.slice()),
            .args_json = if (o.args_json.len == 0) "{}" else try a.dupe(u8, o.args_json.slice()),
            .queue = if (o.queue.len == 0) null else try a.dupe(u8, o.queue.slice()),
            .meta_json = if (o.meta_json.len == 0) null else try a.dupe(u8, o.meta_json.slice()),
            .run_at_ms = o.run_at_ms,
            .delay_ms = o.delay_ms,
            .attempts = o.attempts,
            .priority = o.priority,
            .timeout_ms = o.timeout_ms,
            .unique = unique,
            .unique_key = if (o.unique_key.len == 0) null else try a.dupe(u8, o.unique_key.slice()),
            .unique_period_ms = o.unique_period_ms,
            .unique_scope = o.unique_scope,
        };
    }
    return items;
}

const EnqReq = struct {
    cmd: Command = .{ .run = start },
    e: *Engine,
    user_data: u64,
    items: []Wire,
    arena: std.heap.ArenaAllocator,

    fn free(q: *EnqReq) void {
        var arena = q.arena;
        arena.deinit();
    }

    fn start(cmd: *Command, x: *Exec) void {
        const q: *EnqReq = @fieldParentPtr("cmd", cmd);
        if (x.engine.phase.load(.acquire) == .stopped) return q.free();
        placement.concurrent(&x.jobs.work, x.engine.io, .local, task, .{ x, q }) catch {
            const rec = enqueuedRecord(q.user_data, abi.E_NOMEM, 500, 0, &.{}, "could not start the enqueue task") catch return q.free();
            x.postRecord(rec, false);
            q.free();
        };
    }

    fn task(x: *Exec, q: *EnqReq) std.Io.Cancelable!void {
        defer q.free();
        if (comptime !features.jobs) return;
        const client = x.engine.jobs_state.client orelse return;
        const a = q.arena.allocator();
        var ctx: anole.db.Ctx = .{ .io = x.engine.io, .arena = a };
        const entries = a.alloc(abi.JobEnqueuedEntry, q.items.len) catch return;
        var status: i32 = abi.OK;
        var http: u16 = 200;
        var class: u8 = 0;
        var message: []const u8 = "";
        var n: usize = 0;
        for (q.items) |wi| {
            const r = client.enqueueRaw(&ctx, wi.kind, wi.args_json, optionsOf(wi)) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                status = if (err == error.InvalidJob) abi.E_INVALID else abi.E_DB;
                http = switch (err) {
                    error.InvalidJob => 400,
                    error.ServiceUnavailable => 503,
                    error.GatewayTimeout => 504,
                    error.Conflict => 409,
                    else => 500,
                };
                if (err == error.GatewayTimeout) status = abi.E_TIMEOUT;
                class = @backingInt(@as(abi.DbErrorClass, switch (err) {
                    error.ServiceUnavailable => .unavailable,
                    error.GatewayTimeout => .timeout,
                    error.Conflict => .unique,
                    error.InvalidJob => .invalid,
                    else => .other,
                }));
                message = @errorName(err);
                if (anole.db.lastError(&ctx)) |d| message = d.message;
                break;
            };
            entries[n] = .{ .id = r.id, .inserted = @intFromBool(r.inserted), .reserved = 0 };
            n += 1;
        }
        const rec = enqueuedRecord(q.user_data, status, http, class, if (status == abi.OK) entries[0..n] else &.{}, message) catch return;
        x.postRecord(rec, false);
    }
};

/// `anole_jobs_enqueue`.
pub fn enqueue(e: *Engine, c: ?*Consumer, outs: []const abi.JobOut, opts: abi.JobsEnqueueOptions, user_data: u64) CallError!void {
    if (comptime !features.jobs) return error.Unsupported;
    if (e.jobs_state.client == null) return error.Unsupported;
    switch (e.phase.load(.acquire)) {
        .open, .starting, .running, .draining => {},
        else => return error.State,
    }
    if (c) |cc| if (cc.engine != e) return error.Invalid;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const items = try wireOf(a, outs);
    if (opts.tx != 0) {
        if (Handle.decode(opts.tx).kind != .db_tx or opts.req != 0) return error.Invalid;
        const payload = std.json.Stringify.valueAlloc(a, .{ .jobs = items }, .{ .emit_null_optional_fields = false }) catch return error.OutOfMemory;
        db.txSubmit(e, opts.tx, .job_enqueue, payload, &.{}, .{ .size = @sizeOf(abi.DbOptions), .timeout_ms = opts.timeout_ms }, user_data) catch |err| return switch (err) {
            error.Invalid => error.Invalid,
            error.State => error.State,
            error.OutOfMemory => error.OutOfMemory,
            error.Unsupported => error.Unsupported,
            error.Gone => error.Gone,
        };
        arena.deinit();
        return;
    }
    const x: *Exec = blk: {
        if (opts.req != 0) break :blk db.resolveReq(e, opts.req, c) catch |err| return switch (err) {
            error.Gone => error.Gone,
            error.State => error.State,
            else => error.Invalid,
        };
        const cc = c orelse return error.Invalid;
        if (cc.execs.items.len == 0) return error.State;
        break :blk cc.execs.items[cc.next_db.fetchAdd(1, .monotonic) % cc.execs.items.len];
    };
    const q = a.create(EnqReq) catch return error.OutOfMemory;
    q.* = .{ .e = e, .user_data = user_data, .items = items, .arena = arena };
    x.post(&q.cmd);
}

/// `anole_job_complete_in`.
pub fn completeIn(e: *Engine, hv: u64, tx: u64, user_data: u64) CallError!void {
    if (comptime !features.jobs) return error.Unsupported;
    if (Handle.decode(tx).kind != .db_tx) return error.Invalid;
    const t = &e.jobs_state.jobs;
    t.acquire();
    const en = t.get(Handle.decode(hv)) orelse {
        t.release();
        return error.Gone;
    };
    const slot = en.value;
    if (slot.finished) {
        t.release();
        return error.Gone;
    }
    const id = slot.id;
    const attempt = slot.attempt;
    t.release();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const payload = std.fmt.allocPrint(arena.allocator(), "{{\"id\":{d},\"attempt\":{d},\"job\":{d}}}", .{ id, attempt, hv }) catch return error.OutOfMemory;
    db.txSubmit(e, tx, .job_complete, payload, &.{}, .{ .size = @sizeOf(abi.DbOptions) }, user_data) catch |err| return switch (err) {
        error.Invalid => error.Invalid,
        error.State => error.State,
        error.OutOfMemory => error.OutOfMemory,
        error.Unsupported => error.Unsupported,
        error.Gone => error.Gone,
    };
    arena.deinit();
}

/// A ``job_enqueue`` or `job_complete` call queued on an open transaction (`db.TxWhat`), run in
/// order on the transaction's connection.
pub fn txOp(any: *db.AnyTx, ctx: *anole.db.Ctx, op: *const db.TxOp, answer: *db.Answer) anyerror!void {
    if (comptime !features.jobs) return error.Unsupported;
    const e = active orelse return error.Unsupported;
    const client = e.jobs_state.client orelse return error.Unsupported;
    const Erased = struct { kind: J.store.TxKind, ptr: *anyopaque, owner: ?*anyopaque };
    const er: Erased = switch (any.*) {
        .sqlite => |*tx| if (comptime features.sqlite) .{ .kind = .sqlite, .ptr = @ptrCast(tx), .owner = @ptrCast(tx.db) } else return error.Unsupported,
        .postgres => |*tx| if (comptime features.postgres) .{ .kind = .postgres, .ptr = @ptrCast(tx), .owner = @ptrCast(tx.db) } else return error.Unsupported,
    };
    const a = ctx.arena;
    switch (op.what) {
        .job_enqueue => {
            const Payload = struct { jobs: []const Wire };
            const p = try std.json.parseFromSliceLeaky(Payload, a, op.sql, .{ .ignore_unknown_fields = true });
            const rows = try a.alloc([]const anole.db.Value, p.jobs.len);
            for (p.jobs, rows) |wi, *row| {
                const r = try client.enqueueRawInto(er.kind, er.ptr, er.owner, ctx, wi.kind, wi.args_json, optionsOf(wi));
                const cells = try a.alloc(anole.db.Value, 2);
                cells[0] = .{ .int = r.id };
                cells[1] = .{ .int = @intFromBool(r.inserted) };
                row.* = cells;
            }
            answer.table = .{ .columns = &.{ "id", "inserted" }, .rows = rows };
        },
        .job_complete => {
            const Payload = struct { id: i64, attempt: u16, job: u64 };
            const p = try std.json.parseFromSliceLeaky(Payload, a, op.sql, .{});
            var ok = false;
            defer endSlot(e, p.job, ok);
            ok = try client.completeInto(er.kind, er.ptr, er.owner, ctx, p.id, p.attempt);
            answer.changes = .{ .changes = @intFromBool(ok) };
        },
        else => return error.Unsupported,
    }
}

/// The job's run ends now: it completed in its transaction (`ok`), or the
/// completion failed.
fn endSlot(e: *Engine, hv: u64, ok: bool) void {
    const t = &e.jobs_state.jobs;
    t.acquire();
    const en = t.get(Handle.decode(hv)) orelse {
        t.release();
        return;
    };
    const slot = en.value;
    if (slot.finished) {
        t.release();
        return;
    }
    slot.finished = true;
    slot.outcome = abi.JOB_DONE;
    if (ok) slot.job.completed_in = true;
    t.release();
    e.setEvent(&slot.event);
}

// ---------------------------------------------------------------------------
// Admin

const AdminReq = struct {
    cmd: Command = .{ .run = start },
    e: *Engine,
    user_data: u64,
    request: []const u8,
    arena: std.heap.ArenaAllocator,

    fn free(q: *AdminReq) void {
        var arena = q.arena;
        arena.deinit();
    }

    fn start(cmd: *Command, x: *Exec) void {
        const q: *AdminReq = @fieldParentPtr("cmd", cmd);
        if (x.engine.phase.load(.acquire) == .stopped) return q.free();
        placement.concurrent(&x.jobs.work, x.engine.io, .local, task, .{ x, q }) catch {
            const rec = resultRecord(q.user_data, abi.E_NOMEM, 500, "", "could not start the admin task") catch return q.free();
            x.postRecord(rec, false);
            q.free();
        };
    }

    fn task(x: *Exec, q: *AdminReq) std.Io.Cancelable!void {
        defer q.free();
        if (comptime !features.jobs) return;
        const a = q.arena.allocator();
        var ctx: anole.db.Ctx = .{ .io = x.engine.io, .arena = a };
        var out: std.Io.Writer.Allocating = .init(a);
        var status: i32 = abi.OK;
        var message: []const u8 = "";
        const http = run(x.engine, &ctx, q.request, &out.writer) catch |err| blk: {
            if (err == error.Canceled) return error.Canceled;
            status = switch (err) {
                error.InvalidRequest => abi.E_INVALID,
                else => abi.E_DB,
            };
            message = @errorName(err);
            if (anole.db.lastError(&ctx)) |d| message = d.message;
            break :blk @as(u16, if (err == error.InvalidRequest) 400 else 500);
        };
        if (status == abi.OK and http >= 400) status = if (http == 404 or http == 409) abi.OK else abi.E_INVALID;
        const rec = resultRecord(q.user_data, status, http, out.written(), message) catch return;
        x.postRecord(rec, false);
    }
};

/// `anole_jobs_admin`.
pub fn admin(e: *Engine, c: ?*Consumer, request: []const u8, user_data: u64) CallError!void {
    if (comptime !features.jobs) return error.Unsupported;
    if (e.jobs_state.client == null) return error.Unsupported;
    switch (e.phase.load(.acquire)) {
        .open, .starting, .running, .draining => {},
        else => return error.State,
    }
    const cc = c orelse return error.Invalid;
    if (cc.engine != e or request.len > 64 * 1024) return error.Invalid;
    if (cc.execs.items.len == 0) return error.State;
    const x = cc.execs.items[cc.next_db.fetchAdd(1, .monotonic) % cc.execs.items.len];
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const q = arena.allocator().create(AdminReq) catch return error.OutOfMemory;
    q.* = .{ .e = e, .user_data = user_data, .request = try arena.allocator().dupe(u8, request), .arena = arena };
    x.post(&q.cmd);
}

const NotFound = struct { @"error": []const u8 };

fn intField(v: std.json.Value, name: []const u8) ?i64 {
    const f = v.object.get(name) orelse return null;
    return switch (f) {
        .integer => |i| i,
        else => null,
    };
}

fn strField(v: std.json.Value, name: []const u8) ?[]const u8 {
    const f = v.object.get(name) orelse return null;
    return if (f == .string) f.string else null;
}

/// One operation: the JSON answer is written to `w`, the HTTP status
/// returned (what the admin routes would answer).
fn run(e: *Engine, ctx: *anole.db.Ctx, text: []const u8, w: *std.Io.Writer) !u16 {
    if (comptime !features.jobs) return error.Unsupported;
    const client = e.jobs_state.client orelse return error.Unsupported;
    const root = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, text, .{}) catch return error.InvalidRequest;
    if (root != .object) return error.InvalidRequest;
    const op = strField(root, "op") orelse return error.InvalidRequest;
    const eql = std.mem.eql;
    var jw: std.json.Stringify = .{ .writer = w, .options = .{} };
    if (std.mem.startsWith(u8, op, "webhooks.")) {
        const f = e.jobs_state.webhooks_admin orelse {
            try jw.write(NotFound{ .@"error" = "the configuration has no webhooks" });
            return 404;
        };
        return f(e, ctx, op, root, w);
    }
    if (eql(u8, op, "jobs.get")) {
        const id = intField(root, "id") orelse return error.InvalidRequest;
        const j = try client.get(ctx, id);
        if (j) |info| {
            try jw.write(info);
            return 200;
        }
        try jw.write(NotFound{ .@"error" = "no such job" });
        return 404;
    } else if (eql(u8, op, "jobs.list")) {
        var f: J.Filter = .{};
        if (strField(root, "state")) |s| f.state = std.meta.stringToEnum(J.State, s) orelse return error.InvalidRequest;
        f.queue = strField(root, "queue");
        f.kind = strField(root, "kind");
        if (intField(root, "limit")) |l| f.limit = @intCast(std.math.clamp(l, 1, 500));
        f.before = intField(root, "before");
        const jobs = try client.list(ctx, f);
        const next: ?i64 = if (jobs.len == f.limit and jobs.len > 0) jobs[jobs.len - 1].id else null;
        try jw.write(.{ .jobs = jobs, .next = next });
        return 200;
    } else if (eql(u8, op, "jobs.counts")) {
        try jw.write(.{ .counts = try client.counts(ctx) });
        return 200;
    } else if (eql(u8, op, "jobs.retry") or eql(u8, op, "jobs.cancel") or eql(u8, op, "jobs.delete")) {
        const id = intField(root, "id") orelse return error.InvalidRequest;
        const ok = if (eql(u8, op, "jobs.retry")) try client.retry(ctx, id) else if (eql(u8, op, "jobs.cancel")) try client.cancel(ctx, id) else try client.delete(ctx, id);
        if (!ok) {
            try jw.write(NotFound{ .@"error" = "the job is not in a state that allows it" });
            return 409;
        }
        try jw.write(.{ .ok = true });
        return 200;
    } else if (eql(u8, op, "cron.list")) {
        try jw.write(.{ .cron = try client.cronList(ctx) });
        return 200;
    } else if (eql(u8, op, "cron.trigger")) {
        const name = strField(root, "name") orelse return error.InvalidRequest;
        const r = client.cronTrigger(ctx, name) catch |err| switch (err) {
            error.NotFound => {
                try jw.write(NotFound{ .@"error" = "no such schedule" });
                return 404;
            },
            else => return err,
        };
        try jw.write(r);
        return 200;
    }
    return error.InvalidRequest;
}
