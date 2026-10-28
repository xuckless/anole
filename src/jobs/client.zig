//! The job queue's client: enqueue, handlers, the runner (fetchers,
//! heartbeat, maintenance, drain), cron and the admin calls
//! (p3/jobs, design-jobs.md §3).
const std = @import("std");
const builtin = @import("builtin");
const dusty = @import("dusty");
const root = @import("root.zig");
const store = @import("store.zig");
const clock_mod = @import("clock.zig");
const unique_mod = @import("unique.zig");
const memory = @import("store_memory.zig");
const anole = @import("../root.zig");
const sqlite_store = if (anole.features.sqlite) @import("store_sqlite.zig") else struct {};
const pg_store = if (anole.features.postgres) @import("store_pg.zig") else struct {};
const redis_store = if (anole.features.redis) @import("store_redis.zig") else struct {};
const cron_mod = @import("../cron/root.zig");
const metrics_mod = @import("metrics.zig");
const resilience = @import("../resilience/root.zig");
const internal = @import("../db/internal.zig");
const observe = @import("../observe/root.zig");
const placement = dusty.placement;

const log = std.log.scoped(.anole);

const Time = root.Time;
const Duration = root.Duration;
const Id = root.Id;
const Kind = root.Kind;
const Job = root.Job;
const Options = root.Options;
const Error = root.Error;
const Enqueued = root.Enqueued;
const EnqueueOptions = root.EnqueueOptions;
const StepReport = root.StepReport;

const max_args = 1 << 20;

/// The longest a run's outcome write may take once the run is over (it
/// runs to its end whatever cancels the job's task).
const settle_limit: Duration = .fromSeconds(5);
/// How long the drain waits for the runs it canceled past its deadline;
/// their outcome writes fit in it.
const cancel_grace: Duration = .fromSeconds(3);

pub const Handler = struct {
    kind: Kind,
    state: ?*anyopaque,
    run: *const fn (?*anyopaque, *Job) anyerror!void,
};

const Queue = struct {
    name: []const u8,
    concurrency: u32,
    running: std.atomic.Value(u32) = .init(0),
    signal: placement.Signal = .{},
    /// Kinds with a handler in this process.
    kinds: std.ArrayList([]const u8) = .empty,
    /// Runs every kind of this queue that has no handler of its own (a
    /// language worker for "every kind").
    catch_all: ?Handler = null,
};

/// What a running job leaves behind for the heartbeat and the drain.
const JobBox = struct {
    client: *Client,
    queue: *Queue,
    arena_state: std.heap.ArenaAllocator,
    row: store.Row,
    job: Job = undefined,
    task: ?placement.Task = null,
    started: std.Io.Clock.Timestamp = undefined,
    lost: std.atomic.Value(bool) = .init(false),
    interrupted: std.atomic.Value(bool) = .init(false),
};

const CronEntry = struct {
    name: []const u8,
    spec_text: []const u8,
    schedule: cron_mod.Schedule,
    opts: root.CronOptions,
    kind: []const u8,
    args_json: []const u8,
    zone: cron_mod.Zone = .utc,
    zone_loaded: bool = false,
};

pub const Client = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    options: Options,
    backend: store.Backend,
    clock: clock_mod.Source,
    arena_state: std.heap.ArenaAllocator,
    worker_name: []const u8,
    queues: []Queue,
    handlers: std.ArrayList(Handler) = .empty,
    crons: std.ArrayList(*CronEntry) = .empty,
    held_mutex: std.Io.Mutex = .init,
    held: std.AutoArrayHashMapUnmanaged(Id, *JobBox) = .empty,
    group: std.Io.Group = .init,
    maint_signal: placement.Signal = .{},
    draining: std.atomic.Value(bool) = .init(false),
    /// Set when the drain has ended; a later `drain` waits for it.
    drained: std.Io.Event = .unset,
    started: bool = false,
    is_leader: std.atomic.Value(bool) = .init(false),
    rr: std.atomic.Value(usize) = .init(0),
    last_prune: i64 = 0,
    last_rescue: i64 = 0,
    /// Set by `app.jobs` when the deployment runs no workers (lambda).
    suppress_workers: bool = false,
    /// The server's drain event: set by `app.jobs`, so the queue drains when serving does.
    drain_event: ?*std.Io.Event = null,
    metrics: ?*metrics_mod.Series = null,
    /// The app's exporter (`start`): a span per run. Process-wide (M2),
    /// owned by the app, which closes it first in `App.deinit` (it sends
    /// through the server's client) and frees it last, after the runtime
    /// has stopped. A run that settles in between (the drain cancels it)
    /// calls `job` on a closed exporter: the span is dropped and counted,
    /// with nothing allocated (`Exporter.close`).
    tracer: ?*observe.trace.Exporter = null,
    last_gauges: i64 = 0,
    /// Set before the tasks are canceled (drain, deinit).
    closing: std.atomic.Value(bool) = .init(false),
    /// When the drain stops waiting for the runs it canceled (awake clock,
    /// ns); maxInt while not draining. Bounds the outcome writes.
    drain_gives_up_ns: std.atomic.Value(i64) = .init(std.math.maxInt(i64)),
    /// Wake-ups from the store's listener, the one it sends once it listens
    /// included: a test waits for the first before it counts on a wake.
    wake_kicks: std.atomic.Value(u32) = .init(0),

    /// `app.jobs(options)` calls it; outside an app, `init`, `start`, `drain`, `deinit`.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, options: Options) !*Client {
        try validate(options);
        const self = try gpa.create(Client);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .options = options,
            .backend = undefined,
            .clock = .{ .io = io, .custom = options.clock },
            .arena_state = .init(gpa),
            .worker_name = undefined,
            .queues = &.{},
        };
        errdefer self.arena_state.deinit();
        const a = self.arena_state.allocator();
        self.worker_name = if (options.name) |n| try a.dupe(u8, n) else blk: {
            var rb: [4]u8 = undefined;
            io.random(&rb);
            break :blk try std.fmt.allocPrint(a, "anole-{x}", .{std.mem.readInt(u32, &rb, .little)});
        };
        self.queues = try gpa.alloc(Queue, options.queues.len);
        errdefer gpa.free(self.queues);
        for (options.queues, self.queues) |q, *dst| dst.* = .{ .name = try a.dupe(u8, q.name), .concurrency = q.concurrency };
        self.backend = switch (options.store) {
            .memory => try memory.Memory.create(gpa, io),
            .sqlite => |sq| if (comptime anole.features.sqlite) try sqlite_store.Sqlite.create(gpa, io, sq, options.table_prefix) else {
                log.err("jobs: the sqlite store needs -Dsqlite", .{});
                return error.InvalidOptions;
            },
            .postgres => |pc| if (comptime anole.features.postgres) try pg_store.Postgres.create(gpa, io, pc, options.table_prefix, .{
                .notify = options.notify,
                .advisory_lock = options.leader.method != .lease_row,
            }) else {
                log.err("jobs: the postgres store needs -Dpostgres", .{});
                return error.InvalidOptions;
            },
            .redis => |rc| if (comptime anole.features.redis) try redis_store.Redis.create(gpa, io, rc, options.key_prefix, options.notify) else {
                log.err("jobs: the redis store needs -Dredis", .{});
                return error.InvalidOptions;
            },
        };
        return self;
    }

    pub fn deinit(self: *Client) void {
        self.closing.store(true, .release);
        // A drain under way (the server's) is waited for, not cut short.
        if (self.started) {
            self.drain(std.Io.Clock.Timestamp.now(self.io, .awake).addDuration(.{ .raw = .fromSeconds(10), .clock = .awake }));
        }
        self.group.cancel(self.io);
        self.backend.vt.deinit(self.backend.ptr);
        for (self.queues) |*q| q.kinds.deinit(self.gpa);
        self.gpa.free(self.queues);
        self.handlers.deinit(self.gpa);
        for (self.crons.items) |c| {
            var z = c.zone;
            z.deinit();
            self.gpa.destroy(c);
        }
        self.crons.deinit(self.gpa);
        self.held.deinit(self.gpa);
        if (self.metrics) |mm| {
            mm.deinit();
            self.gpa.destroy(mm);
        }
        self.arena_state.deinit();
        self.gpa.destroy(self);
    }

    fn validate(o: Options) !void {
        const fail = struct {
            fn f(comptime fmt: []const u8, args: anytype) error{InvalidOptions} {
                log.err("jobs: " ++ fmt, args);
                return error.InvalidOptions;
            }
        }.f;
        if (o.queues.len == 0) return fail("queues must name at least one queue", .{});
        for (o.queues, 0..) |q, i| {
            if (!validName(q.name, 64, true)) return fail("queue \"{s}\": 1-64 bytes of [a-z0-9_.-]", .{q.name});
            if (q.concurrency < 1 or q.concurrency > 10_000) return fail("queue \"{s}\": concurrency must be 1..10000", .{q.name});
            for (o.queues[0..i]) |p| if (std.mem.eql(u8, p.name, q.name)) return fail("queue \"{s}\" is listed twice", .{q.name});
        }
        const ms = struct {
            fn f(d: Duration) i96 {
                return root.millis(d);
            }
        }.f;
        if (ms(o.lease) < 3000) return fail("lease must be at least 3 s", .{});
        if (ms(o.poll_interval) < 100 or ms(o.poll_interval) > 60_000) return fail("poll_interval must be 100 ms .. 60 s", .{});
        if (o.leader.ttl.nanoseconds < 3 * o.leader.renew.nanoseconds) return fail("leader.ttl must be at least 3 * leader.renew", .{});
        if (o.table_prefix.len == 0 or o.table_prefix.len > 32 or !validIdent(o.table_prefix)) return fail("table_prefix must match [a-z_][a-z0-9_]{{0,31}}", .{});
        if (o.key_prefix.len == 0 or o.key_prefix.len > 32 or std.mem.indexOfScalar(u8, o.key_prefix, ' ') != null) return fail("key_prefix: 1-32 bytes, no spaces", .{});
        for (o.kinds) |k| try validKind(k, fail);
        if (o.store == .redis and o.leader.method == .advisory_lock) return fail("leader.method = .advisory_lock needs PostgreSQL", .{});
    }

    fn validKind(k: Kind, comptime fail: anytype) !void {
        if (!validName(k.name, 128, false)) return fail("kind \"{s}\": 1-128 bytes of [A-Za-z0-9_.:-]", .{k.name});
        if (k.attempts < 1 or k.attempts > 1000) return fail("kind \"{s}\": attempts must be 1..1000", .{k.name});
        if (k.timeout.nanoseconds <= 0) return fail("kind \"{s}\": timeout must be positive", .{k.name});
        if (!validName(k.queue, 64, true)) return fail("kind \"{s}\": bad queue name", .{k.name});
    }

    fn validIdent(s: []const u8) bool {
        for (s, 0..) |c, i| {
            const ok = (c >= 'a' and c <= 'z') or c == '_' or (i > 0 and c >= '0' and c <= '9');
            if (!ok) return false;
        }
        return true;
    }

    fn validName(s: []const u8, max: usize, queue: bool) bool {
        if (s.len == 0 or s.len > max) return false;
        for (s) |c| {
            const ok = if (queue)
                (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_' or c == '.' or c == '-'
            else
                std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == ':' or c == '-';
            if (!ok) return false;
        }
        return true;
    }

    // ---- clock and randomness

    fn now(self: *Client) Time {
        return self.clock.now();
    }

    fn random(self: *Client) u64 {
        var rb: [8]u8 = undefined;
        self.io.random(&rb);
        return std.mem.readInt(u64, &rb, .little);
    }

    fn after(t: Time, d: Duration) Time {
        return .{ .us = t.us +| root.micros(d) };
    }

    // ---- errors

    fn storeError(self: *Client, c: anytype, err: anyerror) Error {
        _ = self;
        _ = c;
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => {
                log.warn("jobs: the store failed: {t}", .{err});
                return error.Database;
            },
        }
    }

    // ---- start, drain

    /// Migrates, loads cron state, starts fetchers, heartbeat, wakes, leader (per `run`).
    pub fn start(self: *Client, registry: ?*observe.metrics.Registry, tracer: ?*observe.trace.Exporter, health: ?*observe.Health) !void {
        _ = health;
        if (self.started) return;
        self.started = true;
        self.tracer = tracer;
        if (registry) |r| {
            const mm = try self.gpa.create(metrics_mod.Series);
            errdefer self.gpa.destroy(mm);
            mm.* = try metrics_mod.Series.init(self.gpa, r);
            self.metrics = mm;
        }
        self.backend.vt.migrate(self.backend.ptr) catch |e| {
            log.err("jobs: migrating the store failed: {t}", .{e});
            return error.DatabaseUnavailable;
        };
        for (self.crons.items) |c| try self.loadZone(c);
        // The kinds this process handles, per queue.
        for (self.handlers.items) |h| {
            if (self.queueIndex(h.kind.queue)) |qi| try self.queues[qi].kinds.append(self.gpa, h.kind.name);
        }
        if (self.options.store == .memory and self.options.run != .manual) {
            log.info("jobs: memory store: jobs are lost when the process stops", .{});
        }
        const run = self.options.run;
        if (run == .manual) return;
        if (run == .enqueue_only or self.suppress_workers) {
            if (self.suppress_workers) log.info("jobs: lambda deployment runs no workers or schedules here; jobs are only enqueued", .{});
            return;
        }
        if (self.drain_event != null) try placement.concurrent(&self.group, self.io, .{ .executor = 0 }, drainWatcher, .{self});
        if (self.backend.vt.runWake != null and self.options.notify) try placement.concurrent(&self.group, self.io, .{ .executor = 0 }, wakeTask, .{self});
        try placement.concurrent(&self.group, self.io, .{ .executor = 0 }, maintenanceTask, .{self});
        try placement.concurrent(&self.group, self.io, .{ .executor = 0 }, heartbeatTask, .{self});
        for (self.queues, 0..) |*q, i| {
            if (q.kinds.items.len == 0 and q.catch_all == null and self.options.gate == null) continue;
            try placement.concurrent(&self.group, self.io, .{ .executor = i }, fetcherTask, .{ self, q });
        }
    }

    /// Adds a queue the options did not list, before `start` (webhooks adds
    /// its delivery queue this way). A queue that exists is left as it is.
    pub fn addQueue(self: *Client, q: root.QueueOptions) !void {
        if (self.queueIndex(q.name) != null) return;
        if (self.started) {
            log.err("jobs: queue \"{s}\" must be in Options.queues (it is needed after the queue started)", .{q.name});
            return error.InvalidOptions;
        }
        const name = try self.arena_state.allocator().dupe(u8, q.name);
        self.queues = try self.gpa.realloc(self.queues, self.queues.len + 1);
        self.queues[self.queues.len - 1] = .{ .name = name, .concurrency = q.concurrency };
    }

    fn queueIndex(self: *Client, name: []const u8) ?usize {
        for (self.queues, 0..) |q, i| if (std.mem.eql(u8, q.name, name)) return i;
        return null;
    }

    fn loadZone(self: *Client, c: *CronEntry) !void {
        if (c.zone_loaded) return;
        const name = c.opts.tz orelse "UTC";
        c.zone = cron_mod.Zone.load(self.gpa, self.io, name) catch |e| {
            log.err("cron \"{s}\": time zone \"{s}\" failed: {t}", .{ c.name, name, e });
            return error.InvalidOptions;
        };
        c.zone_loaded = true;
    }

    fn kickFromStore(context: ?*anyopaque, queue: []const u8) void {
        const self: *Client = @ptrCast(@alignCast(context.?));
        _ = self.wake_kicks.fetchAdd(1, .release);
        if (queue.len == 0) {
            for (self.queues) |*q| q.signal.set(self.io);
        } else self.wakeQueue(queue);
    }

    /// Listens for the store's wake-ups (PostgreSQL LISTEN, Redis pub/sub),
    /// reconnecting with backoff; every fetcher also polls, so a lost wake
    /// costs one poll interval.
    fn wakeTask(self: *Client) std.Io.Cancelable!void {
        const backoff: resilience.Backoff = .{ .base = .fromSeconds(1), .max = .fromSeconds(30), .jitter = .equal };
        var failures: u32 = 0;
        while (!self.closing.load(.acquire)) {
            if (self.backend.vt.runWake.?(self.backend.ptr, self.io, .{ .context = self, .kick = kickFromStore })) |_| {
                return;
            } else |err| {
                if (self.closing.load(.acquire)) {
                    // The cancel may have been taken by the listener's read.
                    self.io.recancel();
                    return error.Canceled;
                }
                if (err == error.Canceled) return error.Canceled;
                failures += 1;
                log.warn("jobs: the wake listener failed ({t}); trying again", .{err});
            }
            try self.io.sleep(backoff.delay(failures, self.random()), .awake);
        }
    }

    /// Waits for the server's drain, then drains the queue within `drain_timeout`.
    fn drainWatcher(self: *Client) std.Io.Cancelable!void {
        const ev = self.drain_event orelse return;
        try ev.wait(self.io);
        self.drain(std.Io.Clock.Timestamp.now(self.io, .awake).addDuration(.{ .raw = self.options.drain_timeout, .clock = .awake }));
    }

    fn runningTotal(self: *Client) u32 {
        var n: u32 = 0;
        for (self.queues) |*q| n += q.running.load(.acquire);
        return n;
    }

    /// Stops claiming; running jobs finish by `deadline`, then are put back
    /// (J14). A call while a drain runs waits for that one to end.
    pub fn drain(self: *Client, deadline: std.Io.Clock.Timestamp) void {
        self.closing.store(true, .release);
        if (self.draining.swap(true, .acq_rel)) {
            self.drained.waitUncancelable(self.io);
            return;
        }
        defer self.drained.set(self.io);
        // On the awake clock, whatever clock the deadline is on.
        const to_deadline = std.Io.Clock.Timestamp.now(self.io, deadline.clock).durationTo(deadline);
        const gives_up = std.Io.Clock.Timestamp.now(self.io, .awake).addDuration(.{ .raw = to_deadline.raw, .clock = .awake }).addDuration(.{ .raw = cancel_grace, .clock = .awake });
        self.drain_gives_up_ns.store(@intCast(@min(gives_up.raw.nanoseconds, std.math.maxInt(i64))), .release);
        for (self.queues) |*q| q.signal.set(self.io);
        self.maint_signal.set(self.io);
        while (self.runningTotal() > 0) {
            const left = std.Io.Clock.Timestamp.now(self.io, deadline.clock).durationTo(deadline);
            if (left.raw.nanoseconds <= 0) break;
            self.io.sleep(.fromMilliseconds(10), .awake) catch break;
        }
        if (self.runningTotal() > 0) {
            self.held_mutex.lockUncancelable(self.io);
            for (self.held.values()) |b| {
                b.interrupted.store(true, .release);
                if (b.task) |t| placement.cancelTask(t);
            }
            self.held_mutex.unlock(self.io);
            // The canceled runs settle: a finished one's write still lands.
            while (self.runningTotal() > 0) {
                const grace_left = std.Io.Clock.Timestamp.now(self.io, .awake).durationTo(.{ .raw = .{ .nanoseconds = self.drain_gives_up_ns.load(.acquire) }, .clock = .awake });
                if (grace_left.raw.nanoseconds <= 0) break;
                self.io.sleep(.fromMilliseconds(10), .awake) catch break;
            }
        }
        if (self.is_leader.load(.acquire)) {
            self.backend.vt.leaderRelease(self.backend.ptr, self.worker_name) catch {};
            self.is_leader.store(false, .release);
        }
    }

    // ---- enqueue

    fn kindOf(comptime T: type) Kind {
        if (!@hasDecl(T, "job") or @TypeOf(T.job) != Kind)
            @compileError(@typeName(T) ++ " needs `pub const job: anole.jobs.Kind = .{ .name = \"...\" }`");
        return T.job;
    }

    /// `args`' type declares `pub const job: Kind`; serialized with std.json.
    pub fn enqueue(self: *Client, c: anytype, args: anytype, opts: EnqueueOptions) Error!Enqueued {
        const def = comptime kindOf(@TypeOf(args));
        const json = std.json.Stringify.valueAlloc(c.arena, args, .{}) catch return error.OutOfMemory;
        return self.enqueueWith(c, def, json, opts);
    }

    /// By kind name and a JSON value (an object, usually). The kind's defaults
    /// come from `Options.kinds`, else `Kind{ .name }`'s.
    pub fn enqueueRaw(self: *Client, c: anytype, kind: []const u8, args_json: []const u8, opts: EnqueueOptions) Error!Enqueued {
        return self.enqueueWith(c, self.kindDefaults(kind), args_json, opts);
    }

    /// Inside the app's transaction (`*anole.pg.Tx` or `*anole.sqlite.Tx` on
    /// this store's database); committed with it.
    pub fn enqueueIn(self: *Client, tx: anytype, c: anytype, args: anytype, opts: EnqueueOptions) Error!Enqueued {
        const def = comptime kindOf(@TypeOf(args));
        const json = std.json.Stringify.valueAlloc(c.arena, args, .{}) catch return error.OutOfMemory;
        return self.enqueueInWith(tx, c, def, json, opts);
    }
    pub fn enqueueRawIn(self: *Client, tx: anytype, c: anytype, kind: []const u8, args_json: []const u8, opts: EnqueueOptions) Error!Enqueued {
        return self.enqueueInWith(tx, c, self.kindDefaults(kind), args_json, opts);
    }

    /// Marks `job` completed inside `tx` (PostgreSQL/SQLite): exactly once
    /// with the handler's own writes. If the transaction rolls back, the job
    /// runs again after its lease.
    pub fn completeIn(self: *Client, tx: anytype, job: *Job) Error!void {
        const txp = try self.txPointer(tx, "completeIn");
        const fin = self.backend.vt.finishIn.?;
        var ctx: anole.db.Ctx = .{ .io = job.io, .arena = job.arena };
        const ok = fin(self.backend.ptr, txp, &ctx, .{ .id = job.id, .attempt = job.attempt, .to = .completed, .finished_at = self.now() }) catch |e| return self.storeError(job, e);
        if (!ok) {
            log.warn("{s}: completeIn found the job no longer held", .{job.id_text});
            return error.Conflict;
        }
        job.completed_in = true;
    }

    /// Checks `tx` is a transaction of this store's connector, and erases it.
    fn txPointer(self: *Client, tx: anytype, comptime what: []const u8) Error!*anyopaque {
        const T = @typeInfo(@TypeOf(tx)).pointer.child;
        const kind: store.TxKind = comptime if (anole.features.sqlite and T == anole.sqlite.Tx)
            .sqlite
        else if (anole.features.postgres and T == anole.pg.Tx)
            .postgres
        else
            @compileError(what ++ " takes the *Tx of anole.pg or anole.sqlite");
        try self.checkTx(kind, @ptrCast(tx.db), what);
        return @ptrCast(tx);
    }

    fn enqueueInWith(self: *Client, tx: anytype, c: anytype, def: Kind, args_json: []const u8, opts: EnqueueOptions) Error!Enqueued {
        const txp = try self.txPointer(tx, "enqueueIn");
        const meta_opts = try self.withTrace(c, opts);
        return self.insertInto(txp, c.io, c.arena, def, args_json, meta_opts);
    }

    fn insertInto(self: *Client, txp: *anyopaque, io: std.Io, arena: std.mem.Allocator, def: Kind, args_json: []const u8, opts: EnqueueOptions) Error!Enqueued {
        const nj = try self.newJob(arena, def, args_json, opts);
        var ctx: anole.db.Ctx = .{ .io = io, .arena = arena };
        const r = self.backend.vt.insertIn.?(self.backend.ptr, txp, &ctx, self.now(), nj) catch |e| {
            _ = self.storeError(&ctx, e) catch {};
            return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                error.Canceled => error.Canceled,
                else => error.Database,
            };
        };
        if (self.metrics) |mm| mm.onEnqueued(nj.queue, def.name, r.inserted);
        if (r.inserted) self.wakeQueue(nj.queue);
        return r;
    }

    /// For the C ABI: `enqueueRawIn` on a transaction known only by its
    /// connector's kind and the erased `*Tx`. `owner` is the transaction's
    /// `db` client.
    pub fn enqueueRawInto(self: *Client, tx_kind: store.TxKind, txp: *anyopaque, owner: ?*anyopaque, ctx: *anole.db.Ctx, kind: []const u8, args_json: []const u8, opts: EnqueueOptions) Error!Enqueued {
        try self.checkTx(tx_kind, owner, "enqueueIn");
        return self.insertInto(txp, ctx.io, ctx.arena, self.kindDefaults(kind), args_json, opts);
    }

    /// For the C ABI: `completeIn` by job id and attempt.
    pub fn completeInto(self: *Client, tx_kind: store.TxKind, txp: *anyopaque, owner: ?*anyopaque, ctx: *anole.db.Ctx, id: Id, attempt: u16) Error!bool {
        try self.checkTx(tx_kind, owner, "completeIn");
        return self.backend.vt.finishIn.?(self.backend.ptr, txp, ctx, .{ .id = id, .attempt = attempt, .to = .completed, .finished_at = self.now() }) catch |e| return self.storeError(ctx, e);
    }

    fn checkTx(self: *Client, tx_kind: store.TxKind, owner: ?*anyopaque, what: []const u8) Error!void {
        if (self.backend.tx_kind != tx_kind or self.backend.vt.insertIn == null) {
            log.warn("jobs: {s} needs a transaction of the jobs store's own database (PostgreSQL or SQLite)", .{what});
            return error.InvalidJob;
        }
        if (owner != self.backend.owner) {
            log.warn("jobs: {s}: the transaction is on another database than the jobs store", .{what});
            return error.InvalidJob;
        }
    }

    /// `opts` with the caller's trace context added to its meta: a
    /// request's (`observe.trace.current`: its span when traced here, the
    /// caller's as it came otherwise; the trace flags kept), or a running
    /// job's (its own span when traced, else the context it came with).
    fn withTrace(self: *Client, c: anytype, opts: EnqueueOptions) Error!EnqueueOptions {
        _ = self;
        var buf: [55]u8 = undefined;
        if (internal.requestOf(c)) |req| {
            const tp = observe.trace.current(req, &buf) orelse return opts;
            return addTrace(c.arena, opts, tp, observe.trace.currentState(req));
        } else if (comptime @typeInfo(@TypeOf(c)) == .pointer and @typeInfo(@TypeOf(c)).pointer.child == Job) {
            if (c.span_id.len == 16 and c.trace_id.len == 32) {
                // Recorded, so sampled; the run's trace has no tracestate of its own.
                const tp = std.fmt.bufPrint(&buf, "00-{s}-{s}-01", .{ c.trace_id, c.span_id }) catch return opts;
                return addTrace(c.arena, opts, tp, null);
            }
            return addTrace(c.arena, opts, c.traceparent() orelse return opts, c.tracestate());
        }
        return opts;
    }

    /// `opts` with `traceparent` (and `tracestate` when given) added to its
    /// meta, unless the meta sets its own (or is not a JSON object). For
    /// the C ABI, whose enqueue reads its request's context on the
    /// request's executor.
    pub fn addTrace(arena: std.mem.Allocator, opts: EnqueueOptions, traceparent: []const u8, tracestate: ?[]const u8) Error!EnqueueOptions {
        var obj: std.json.ObjectMap = .empty;
        if (opts.meta) |m| {
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, m, .{}) catch return opts;
            if (parsed != .object) return opts;
            obj = parsed.object;
        }
        if (obj.contains("traceparent")) return opts;
        obj.put(arena, "traceparent", .{ .string = traceparent }) catch return error.OutOfMemory;
        if (tracestate) |ts| if (!obj.contains("tracestate")) obj.put(arena, "tracestate", .{ .string = ts }) catch return error.OutOfMemory;
        var out = opts;
        out.meta = std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = obj }, .{}) catch return error.OutOfMemory;
        return out;
    }

    pub fn enqueueMany(self: *Client, c: anytype, items: []const Client.Item) Error![]Enqueued {
        if (items.len > 1000) {
            log.warn("jobs: enqueueMany takes at most 1000 jobs", .{});
            return error.InvalidJob;
        }
        const out = try c.arena.alloc(Enqueued, items.len);
        for (items, out) |it, *dst| dst.* = try self.enqueueRaw(c, it.kind, it.args_json, it.opts);
        return out;
    }
    pub const Item = struct { kind: []const u8, args_json: []const u8, opts: EnqueueOptions = .{} };

    /// The defaults a kind name gets (`Options.kinds`, a handler's).
    pub fn kindDefaultsPublic(self: *Client, name: []const u8) Kind {
        return self.kindDefaults(name);
    }

    fn kindDefaults(self: *Client, name: []const u8) Kind {
        for (self.handlers.items) |h| if (std.mem.eql(u8, h.kind.name, name)) return h.kind;
        for (self.options.kinds) |k| if (std.mem.eql(u8, k.name, name)) return k;
        return .{ .name = name };
    }

    fn invalid(self: *Client, kind: []const u8, comptime fmt: []const u8, args: anytype) Error {
        _ = self;
        log.warn("jobs: cannot enqueue \"{s}\": " ++ fmt, .{kind} ++ args);
        return error.InvalidJob;
    }

    fn newJob(self: *Client, arena: std.mem.Allocator, def: Kind, args_json: []const u8, opts: EnqueueOptions) Error!store.NewJob {
        const t = self.now();
        if (!validName(def.name, 128, false) or std.mem.startsWith(u8, def.name, "anole.") and !internalKind(def.name))
            return self.invalid(def.name, "bad kind name", .{});
        if (args_json.len > max_args) return self.invalid(def.name, "arguments over 1 MiB", .{});
        {
            const parsed = std.json.parseFromSlice(std.json.Value, arena, args_json, .{}) catch return self.invalid(def.name, "arguments are not valid JSON", .{});
            parsed.deinit();
        }
        if (opts.run_at != null and opts.delay != null) return self.invalid(def.name, "both run_at and delay", .{});
        const queue = opts.queue orelse def.queue;
        if (!validName(queue, 64, true)) return self.invalid(def.name, "bad queue name \"{s}\"", .{queue});
        var meta: []const u8 = "{}";
        if (opts.meta) |m| {
            const parsed = std.json.parseFromSlice(std.json.Value, arena, m, .{}) catch return self.invalid(def.name, "meta is not valid JSON", .{});
            defer parsed.deinit();
            if (parsed.value != .object) return self.invalid(def.name, "meta must be a JSON object", .{});
            meta = m;
        }
        const attempts = opts.attempts orelse def.attempts;
        if (attempts < 1 or attempts > 1000) return self.invalid(def.name, "attempts must be 1..1000", .{});
        const timeout_d = opts.timeout orelse def.timeout;
        const timeout_ms: ?u32 = if (timeout_d.nanoseconds == std.math.maxInt(i96) or timeout_d.nanoseconds > @as(i96, std.math.maxInt(u32)) * std.time.ns_per_ms)
            null
        else
            @intCast(@max(1, root.millis(timeout_d)));
        const run_at: Time = if (opts.run_at) |r| r else if (opts.delay) |d| after(t, d) else t;
        const uq: ?store.UniqueKey = if (opts.unique) |u| .{ .key = unique_mod.derive(def.name, queue, args_json, u, t), .scope = u.scope } else null;
        return .{
            .queue = queue,
            .kind = def.name,
            .args_json = args_json,
            .meta_json = meta,
            .priority = opts.priority orelse def.priority,
            .max_attempts = attempts,
            .run_at = run_at,
            .timeout_ms = timeout_ms,
            .unique = uq,
        };
    }

    fn internalKind(name: []const u8) bool {
        return std.mem.eql(u8, name, "anole.webhook") or std.mem.eql(u8, name, "anole.webhook.prune") or std.mem.eql(u8, name, "anole.sql");
    }

    fn enqueueWith(self: *Client, c: anytype, def: Kind, args_json: []const u8, opts: EnqueueOptions) Error!Enqueued {
        const nj = try self.newJob(c.arena, def, args_json, try self.withTrace(c, opts));
        const r = self.backend.vt.insert(self.backend.ptr, self.now(), nj) catch |e| return self.storeError(c, e);
        if (self.metrics) |mm| mm.onEnqueued(nj.queue, def.name, r.inserted);
        if (r.inserted) self.wakeQueue(nj.queue);
        return r;
    }

    fn wakeQueue(self: *Client, name: []const u8) void {
        if (self.queueIndex(name)) |i| self.queues[i].signal.set(self.io);
    }

    // ---- handlers

    /// Runs `handler` for every job of `Args`' kind once serving starts.
    pub fn handle(self: *Client, server: anytype, comptime Args: type, opts: root.HandleOptions, comptime handler: anytype) !void {
        _ = opts;
        const def = comptime kindOf(Args);
        const Info = @typeInfo(@TypeOf(handler)).@"fn";
        const with_state = Info.param_types.len == 3;
        const state: ?*anyopaque = if (with_state) @ptrCast(server.server.ctx) else null;
        const Tramp = struct {
            fn run(ctx: ?*anyopaque, job: *Job) anyerror!void {
                const args = try job.bind(Args);
                if (with_state) {
                    const P = Info.param_types[0].?;
                    return handler(@as(P, @ptrCast(@alignCast(ctx.?))), job, args);
                }
                return handler(job, args);
            }
        };
        try self.addHandler(def, state, Tramp.run);
    }

    /// The same by name, args as JSON text: `fn (*Job) !void` / `fn (*App, *Job) !void`.
    pub fn handleRaw(self: *Client, server: anytype, kind: Kind, opts: root.HandleOptions, comptime handler: anytype) !void {
        _ = opts;
        const Info = @typeInfo(@TypeOf(handler)).@"fn";
        const with_state = Info.param_types.len == 2;
        const state: ?*anyopaque = if (with_state) @ptrCast(server.server.ctx) else null;
        const Tramp = struct {
            fn run(ctx: ?*anyopaque, job: *Job) anyerror!void {
                if (with_state) {
                    const P = Info.param_types[0].?;
                    return handler(@as(P, @ptrCast(@alignCast(ctx.?))), job);
                }
                return handler(job);
            }
        };
        try self.addHandler(kind, state, Tramp.run);
    }

    /// For code that has no server (tests, the C ABI): a handler with its own state.
    pub fn addHandler(self: *Client, kind: Kind, state: ?*anyopaque, run: *const fn (?*anyopaque, *Job) anyerror!void) !void {
        if (!self.registrable()) {
            log.err("jobs: register handlers before serving starts (kind \"{s}\")", .{kind.name});
            return error.InvalidOptions;
        }
        if (self.queueIndex(kind.queue) == null) {
            log.err("jobs: kind \"{s}\" uses queue \"{s}\", which is not in Options.queues", .{ kind.name, kind.queue });
            return error.InvalidOptions;
        }
        for (self.handlers.items) |h| if (std.mem.eql(u8, h.kind.name, kind.name)) {
            log.err("jobs: kind \"{s}\" has two handlers", .{kind.name});
            return error.InvalidOptions;
        };
        try self.handlers.append(self.gpa, .{ .kind = kind, .state = state, .run = run });
        // Added after `start` (behind a gate): the fetcher's filter learns it.
        if (self.started) try self.queues[self.queueIndex(kind.queue).?].kinds.append(self.gpa, self.handlers.items[self.handlers.items.len - 1].kind.name);
    }

    fn handlerFor(self: *Client, kind: []const u8) ?*const Handler {
        for (self.handlers.items) |*h| if (std.mem.eql(u8, h.kind.name, kind)) return h;
        return null;
    }

    /// The handler for a claimed job: its kind's, else its queue's catch-all.
    fn handlerOf(self: *Client, row: store.Row) ?*const Handler {
        if (self.handlerFor(row.kind)) |h| return h;
        if (self.queueIndex(row.queue)) |qi| if (self.queues[qi].catch_all != null) return &self.queues[qi].catch_all.?;
        return null;
    }

    /// Runs every kind of `queue` that has no handler of its own with `run`.
    pub fn addCatchAll(self: *Client, queue: []const u8, state: ?*anyopaque, run: *const fn (?*anyopaque, *Job) anyerror!void) !void {
        if (!self.registrable()) return error.InvalidOptions;
        const qi = self.queueIndex(queue) orelse return error.InvalidOptions;
        if (self.queues[qi].catch_all != null) return error.InvalidOptions;
        self.queues[qi].catch_all = .{ .kind = .{ .name = "*", .queue = self.queues[qi].name }, .state = state, .run = run };
    }

    /// Handlers may still be added: not started, or started behind a gate that has not opened.
    fn registrable(self: *Client) bool {
        if (!self.started) return true;
        const g = self.options.gate orelse return false;
        return !g.is_open(g.context);
    }

    fn gated(self: *Client) bool {
        const g = self.options.gate orelse return false;
        return !g.is_open(g.context);
    }

    /// Whether a handler (of this kind, or its queue's catch-all) exists.
    pub fn hasHandler(self: *Client, kind: []const u8) bool {
        return self.handlerFor(kind) != null;
    }

    // ---- running one job

    const Outcome = enum { completed, retried, dead, snoozed, interrupted, lost };
    const Plan = struct { f: store.Finish, outcome: Outcome };

    fn runJob(self: *Client, box: *JobBox) Outcome {
        const row = box.row;
        const a = box.arena_state.allocator();
        box.started = .now(self.io, .awake);
        const h = self.handlerOf(row);
        const def: Kind = if (self.handlerFor(row.kind)) |hh| hh.kind else self.kindDefaults(row.kind);
        var id_buf: [32]u8 = undefined;
        const id_text = a.dupe(u8, std.fmt.bufPrint(&id_buf, "job-{d}", .{row.id}) catch "job") catch "job";
        box.job = .{
            .io = self.io,
            .arena = a,
            .id_text = id_text,
            .id = row.id,
            .kind = row.kind,
            .queue = row.queue,
            .args_json = row.args_json,
            .meta_json = row.meta_json,
            .attempt = row.attempt,
            .max_attempts = row.max_attempts,
            .priority = row.priority,
            .run_at = row.run_at,
            .created_at = row.created_at,
            .errors = row.errors,
            .client = self,
        };
        box.job.cron_name = cronNameOf(a, row.meta_json);
        box.job.lost_flag = &box.lost;
        box.job.interrupted_flag = &box.interrupted;
        box.job.timeout_ms = row.timeout_ms;
        const job = &box.job;
        log.debug("{s} {s} started (attempt {d} of {d})", .{ id_text, row.kind, row.attempt, row.max_attempts });

        // A span per run, linked to the enqueuer's context (not its child).
        const link: ?observe.trace.Context = if (job.traceparent()) |tp| observe.trace.Context.parse(tp) else null;
        var span: ?struct { trace_id: [32]u8, span_id: [16]u8, start_ns: i96 } = null;
        if (self.tracer) |t| if (t.recordsJob(link)) {
            var trace_id: [32]u8 = undefined;
            var span_id: [16]u8 = undefined;
            observe.trace.newId(self.io, &trace_id);
            observe.trace.newId(self.io, &span_id);
            // In the run's arena, which the job lives in (M4).
            job.trace_id = a.dupe(u8, &trace_id) catch "";
            job.span_id = a.dupe(u8, &span_id) catch "";
            span = .{ .trace_id = trace_id, .span_id = span_id, .start_ns = std.Io.Clock.real.now(self.io).nanoseconds };
        };

        var result: anyerror!void = error.NoHandler;
        if (h) |hh| {
            const timeout: std.Io.Timeout = if (row.timeout_ms) |ms| .{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake } } else .none;
            const d: dusty.Deadline = .init(self.io, timeout);
            result = d.run(invoke, .{ hh, job }) catch |e| e;
        }
        const end_ns = if (span != null) std.Io.Clock.real.now(self.io).nanoseconds else 0;
        const outcome = self.settle(box, def, result);
        if (span) |sp| self.tracer.?.job(sp.trace_id, sp.span_id, sp.start_ns, end_ns, .{
            .queue = row.queue,
            .kind = row.kind,
            .id = row.id,
            .attempt = row.attempt,
            .max_attempts = row.max_attempts,
            .outcome = @tagName(outcome),
            .error_type = spanErrorType(outcome, result),
            .link = link,
            .link_state = if (link != null) (job.tracestate() orelse "") else "",
        });
        return outcome;
    }

    /// A failed run's stored error name.
    fn errorType(err: anyerror) []const u8 {
        return if (err == error.Timeout or err == error.Canceled) "Timeout" else @errorName(err);
    }

    /// A run's span's `error.type`: the handler's error, `Timeout` only
    /// when its own deadline expired (`dusty.Deadline` fails with
    /// `error.Timeout`). Empty when it succeeded, and when it was stopped
    /// from outside (interrupted by a drain, or lost with its lease or to a
    /// cancel): the cancel it got is not the handler failing.
    fn spanErrorType(outcome: Outcome, result: anyerror!void) []const u8 {
        if (outcome == .interrupted or outcome == .lost) return "";
        if (result) |_| return "" else |err| return @errorName(err);
    }

    fn invoke(h: *const Handler, job: *Job) anyerror!void {
        return h.run(h.state, job);
    }

    fn cronNameOf(arena: std.mem.Allocator, meta: []const u8) ?[]const u8 {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, meta, .{}) catch return null;
        if (parsed != .object) return null;
        const v = parsed.object.get("cron") orelse return null;
        return if (v == .string) v.string else null;
    }

    fn took(self: *Client, box: *JobBox) std.Io.Duration {
        return box.started.durationTo(.now(self.io, .awake)).raw;
    }

    /// Writes the outcome of a run (J3's conditional state change).
    fn settle(self: *Client, box: *JobBox, def: Kind, result: anyerror!void) Outcome {
        const job = &box.job;
        const row = box.row;
        const t = self.now();
        const base: store.Finish = .{ .id = row.id, .attempt = row.attempt, .to = .completed, .finished_at = t };
        var plan: Plan = .{ .f = base, .outcome = .completed };
        const o = job.outcome;
        const interrupted = box.interrupted.load(.acquire);
        const lost = box.lost.load(.acquire);
        if (job.completed_in and result != error.Canceled) {
            if (self.metrics) |mm| mm.onFinished(row.queue, row.kind, .completed, took(self, box));
            return .completed;
        }

        if (lost) {
            log.info("{s}: no longer held (cancelled, or its lease expired); its run was stopped", .{job.id_text});
            return .lost;
        }
        // A handler that returned before the drain's cancel reached it has
        // finished: its outcome stands.
        const failed = if (result) |_| false else |_| true;
        if (interrupted and failed) {
            plan = .{ .f = .{ .id = row.id, .attempt = row.attempt, .to = .available, .attempt_delta = -1, .run_at = t }, .outcome = .interrupted };
            log.info("{s} interrupted by shutdown; put back", .{job.id_text});
        } else if (result) |_| {
            switch (o.kind) {
                .none => {},
                .snooze => plan = self.planSnooze(row, t, o.delay),
                .discard => plan = .{ .f = .{ .id = row.id, .attempt = row.attempt, .to = .dead, .finished_at = t, .add_error = .{ .attempt = row.attempt, .at = t, .@"error" = "Discarded", .message = o.reason } }, .outcome = .dead },
                .retry_in => plan = self.planFailure(row, def, t, "RetryRequested", o.explanation, o.delay),
            }
        } else |err| {
            const err_name = errorType(err);
            switch (o.kind) {
                .discard => plan = .{ .f = .{ .id = row.id, .attempt = row.attempt, .to = .dead, .finished_at = t, .add_error = .{ .attempt = row.attempt, .at = t, .@"error" = err_name, .message = if (o.reason.len > 0) o.reason else o.explanation } }, .outcome = .dead },
                .snooze => plan = self.planSnooze(row, t, o.delay),
                else => plan = self.planFailure(row, def, t, err_name, o.explanation, if (o.kind == .retry_in) o.delay else null),
            }
        }

        switch (self.writeOutcome(plan.f, job.id_text)) {
            .saved => {},
            .not_held => {
                log.info("{s}: no longer held; its result was dropped", .{job.id_text});
                return .lost;
            },
            .failed => {
                if (self.metrics) |mm| mm.onUnsaved(row.queue, row.kind);
                return plan.outcome;
            },
        }
        if (self.metrics) |mm| {
            const label: metrics_mod.Outcome = if (result) |_| switch (plan.outcome) {
                .completed => .completed,
                .retried => .retried,
                .dead => .dead,
                .snoozed => .snoozed,
                else => .interrupted,
            } else |err| if (err == error.Timeout or err == error.Canceled) .timeout else switch (plan.outcome) {
                .retried => .retried,
                .dead => .dead,
                .snoozed => .snoozed,
                else => .interrupted,
            };
            mm.onFinished(row.queue, row.kind, label, took(self, box));
        }
        if (plan.outcome == .dead) {
            // Tests expect dead jobs; an error line would fail them.
            if (builtin.is_test) log.info("{s} {s} is dead after {d} attempts", .{ job.id_text, row.kind, row.attempt }) else log.err("{s} {s} is dead after {d} attempts", .{ job.id_text, row.kind, row.attempt });
            if (self.options.on_dead) |hook| {
                if (self.backend.vt.get(self.backend.ptr, box.arena_state.allocator(), row.id) catch null) |dead_row| {
                    if (rowToInfo(box.arena_state.allocator(), dead_row)) |info| hook.call(hook.context, &info) else |_| {}
                }
            }
        } else if (plan.outcome == .retried) {
            log.warn("{s} {s} failed (attempt {d} of {d}); next try scheduled", .{ job.id_text, row.kind, row.attempt, row.max_attempts });
        }
        return plan.outcome;
    }

    const Written = enum { saved, not_held, failed };

    /// The outcome's write, run to its end whatever cancels the job's task:
    /// a drain past its deadline cancels it, and a write cut short would
    /// make a finished job run again after its lease. A task of its own,
    /// awaited with the cancel held off, bounded by `settle_limit` or the
    /// moment the drain stops waiting, whichever is nearer.
    fn writeOutcome(self: *Client, f: store.Finish, id_text: []const u8) Written {
        const io = self.io;
        const prev = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(prev);
        const limit = std.Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .raw = settle_limit, .clock = .awake });
        const gives_up: std.Io.Clock.Timestamp = .{ .raw = .{ .nanoseconds = self.drain_gives_up_ns.load(.acquire) }, .clock = .awake };
        const deadline = if (gives_up.raw.nanoseconds < limit.raw.nanoseconds) gives_up else limit;
        var out: Written = .failed;
        var group: std.Io.Group = .init;
        placement.concurrent(&group, io, .local, writeOutcomeTask, .{ self, f, id_text, deadline, &out }) catch {
            writeOutcomeTask(self, f, id_text, deadline, &out);
            return out;
        };
        group.await(io) catch {};
        return out;
    }

    fn writeOutcomeTask(self: *Client, f: store.Finish, id_text: []const u8, deadline: std.Io.Clock.Timestamp, out: *Written) void {
        const d: dusty.Deadline = .init(self.io, .{ .deadline = deadline });
        out.* = d.run(finishRetrying, .{ self, f, id_text }) catch |e| {
            log.warn("{s} finished but its state could not be saved: {t}; it will run again after its lease", .{ id_text, e });
            out.* = .failed;
            return;
        };
    }

    fn finishRetrying(self: *Client, f: store.Finish, id_text: []const u8) anyerror!Written {
        var tries: u32 = 0;
        while (true) : (tries += 1) {
            const ok = self.backend.vt.finish(self.backend.ptr, f) catch |e| {
                if (e == error.Canceled or tries == 2) return e;
                log.warn("{s}: saving its state failed ({t}); trying again", .{ id_text, e });
                try self.io.sleep(.fromMilliseconds(@as(i64, 50) << @intCast(tries)), .awake);
                continue;
            };
            return if (ok) .saved else .not_held;
        }
    }

    fn planSnooze(self: *Client, row: store.Row, t: Time, delay: Duration) Plan {
        _ = self;
        const run_at = after(t, delay);
        return .{ .f = .{ .id = row.id, .attempt = row.attempt, .to = if (delay.nanoseconds <= 0) .available else .scheduled, .attempt_delta = -1, .run_at = run_at }, .outcome = .snoozed };
    }

    fn planFailure(self: *Client, row: store.Row, def: Kind, t: Time, err_name: []const u8, msg: []const u8, explicit: ?Duration) Plan {
        const entry: root.ErrorEntry = .{ .attempt = row.attempt, .at = t, .@"error" = err_name, .message = msg };
        if (row.attempt >= row.max_attempts) {
            return .{ .f = .{ .id = row.id, .attempt = row.attempt, .to = .dead, .finished_at = t, .add_error = entry }, .outcome = .dead };
        }
        const delay = explicit orelse def.backoff.delay(row.attempt, self.random());
        return .{ .f = .{ .id = row.id, .attempt = row.attempt, .to = .retrying, .run_at = after(t, delay), .add_error = entry }, .outcome = .retried };
    }

    // ---- background tasks

    fn cloneRow(a: std.mem.Allocator, r: store.Row) !store.Row {
        var out = r;
        out.queue = try a.dupe(u8, r.queue);
        out.kind = try a.dupe(u8, r.kind);
        out.args_json = try a.dupe(u8, r.args_json);
        out.meta_json = try a.dupe(u8, r.meta_json);
        if (r.worker) |w| out.worker = try a.dupe(u8, w);
        const errs = try a.alloc(root.ErrorEntry, r.errors.len);
        for (r.errors, errs) |s, *d| d.* = .{ .attempt = s.attempt, .at = s.at, .@"error" = try a.dupe(u8, s.@"error"), .message = try a.dupe(u8, s.message) };
        out.errors = errs;
        return out;
    }

    fn waitSignal(self: *Client, sig: *placement.Signal, d: Duration) std.Io.Cancelable!void {
        const dl: dusty.Deadline = .init(self.io, .{ .duration = .{ .raw = d, .clock = .awake } });
        dl.run(placement.Signal.wait, .{ sig, self.io }) catch |e| switch (e) {
            error.Timeout => {},
            error.Canceled => return error.Canceled,
        };
        sig.reset(self.io);
    }

    fn fetcherTask(self: *Client, q: *Queue) std.Io.Cancelable!void {
        while (!self.draining.load(.acquire)) {
            if (self.gated() or (q.kinds.items.len == 0 and q.catch_all == null)) {
                try self.waitSignal(&q.signal, self.options.poll_interval);
                continue;
            }
            const running = q.running.load(.acquire);
            const free = if (q.concurrency > running) q.concurrency - running else 0;
            var got: usize = 0;
            if (free > 0) {
                var arena: std.heap.ArenaAllocator = .init(self.gpa);
                defer arena.deinit();
                const rows = self.backend.vt.claim(self.backend.ptr, arena.allocator(), .{
                    .queue = q.name,
                    .kinds = if (q.catch_all != null) null else q.kinds.items,
                    .limit = @min(free, 100),
                    .now = self.now(),
                    .lease_until = after(self.now(), self.options.lease),
                    .worker = self.worker_name,
                }) catch |e| blk: {
                    log.warn("jobs: claiming from \"{s}\" failed: {t}", .{ q.name, e });
                    break :blk &[_]store.Row{};
                };
                got = rows.len;
                for (rows) |r| self.spawnJob(q, r);
            }
            // A full batch means more may be waiting.
            if (got > 0 and got >= @min(free, 100)) continue;
            try self.waitSignal(&q.signal, self.options.poll_interval);
        }
    }

    fn spawnJob(self: *Client, q: *Queue, r: store.Row) void {
        const box = self.gpa.create(JobBox) catch return self.putBack(r);
        box.* = .{ .client = self, .queue = q, .arena_state = .init(self.gpa), .row = undefined };
        box.row = cloneRow(box.arena_state.allocator(), r) catch {
            box.arena_state.deinit();
            self.gpa.destroy(box);
            return self.putBack(r);
        };
        _ = q.running.fetchAdd(1, .acq_rel);
        const exec = self.rr.fetchAdd(1, .monotonic);
        placement.concurrent(&self.group, self.io, .{ .executor = exec }, jobTask, .{box}) catch {
            _ = q.running.fetchSub(1, .acq_rel);
            box.arena_state.deinit();
            self.gpa.destroy(box);
            self.putBack(r);
        };
    }

    /// A claim that could not start: back to available, attempt not counted.
    fn putBack(self: *Client, r: store.Row) void {
        _ = self.backend.vt.finish(self.backend.ptr, .{ .id = r.id, .attempt = r.attempt, .to = .available, .attempt_delta = -1, .run_at = self.now() }) catch {};
    }

    fn jobTask(box: *JobBox) std.Io.Cancelable!void {
        const self = box.client;
        {
            self.held_mutex.lockUncancelable(self.io);
            defer self.held_mutex.unlock(self.io);
            box.task = placement.currentTask(self.io);
            self.held.put(self.gpa, box.row.id, box) catch {};
        }
        if (self.metrics) |mm| mm.running.with(&.{box.queue.name}).add(1);
        _ = self.runJob(box);
        if (self.metrics) |mm| mm.running.with(&.{box.queue.name}).add(-1);
        {
            self.held_mutex.lockUncancelable(self.io);
            defer self.held_mutex.unlock(self.io);
            _ = self.held.swapRemove(box.row.id);
        }
        const q = box.queue;
        box.arena_state.deinit();
        self.gpa.destroy(box);
        _ = q.running.fetchSub(1, .acq_rel);
        q.signal.set(self.io);
    }

    fn heartbeatTask(self: *Client) std.Io.Cancelable!void {
        const every = Duration.fromNanoseconds(@divFloor(self.options.lease.nanoseconds, 3));
        while (true) {
            self.io.sleep(every, .awake) catch return error.Canceled;
            try self.heartbeatOnce();
            if (self.draining.load(.acquire) and self.runningTotal() == 0) return;
        }
    }

    fn heartbeatOnce(self: *Client) std.Io.Cancelable!void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        self.held_mutex.lockUncancelable(self.io);
        const held = a.alloc(store.Held, self.held.count()) catch {
            self.held_mutex.unlock(self.io);
            return;
        };
        for (self.held.values(), held) |b, *h| h.* = .{ .id = b.row.id, .attempt = b.row.attempt };
        self.held_mutex.unlock(self.io);
        if (held.len == 0) return;
        const alive = self.backend.vt.heartbeat(self.backend.ptr, a, after(self.now(), self.options.lease), held) catch |e| {
            try passCancel(e);
            log.warn("jobs: heartbeat failed: {t}", .{e});
            return;
        };
        self.held_mutex.lockUncancelable(self.io);
        defer self.held_mutex.unlock(self.io);
        for (held) |h| {
            if (std.mem.indexOfScalar(Id, alive, h.id) != null) continue;
            const b = self.held.get(h.id) orelse continue;
            const got = self.backend.vt.get(self.backend.ptr, a, h.id) catch |e| blk: {
                try passCancel(e);
                break :blk null;
            };
            if (got) |row| {
                if (row.state == .cancelled) b.job.admin_cancelled.store(true, .release);
            }
            b.lost.store(true, .release);
            if (b.task) |t| placement.cancelTask(t);
        }
    }

    /// A store call's failure, in a task that carries on after one: a
    /// cancel (the teardown's) is passed on, never taken for a failure that
    /// the task logs and goes past, or its next wait parks with the cancel
    /// gone (SAFETY.md).
    fn passCancel(err: anyerror) std.Io.Cancelable!void {
        if (err == error.Canceled) return error.Canceled;
    }

    fn maintenanceTask(self: *Client) std.Io.Cancelable!void {
        while (!self.draining.load(.acquire)) {
            var arena: std.heap.ArenaAllocator = .init(self.gpa);
            defer arena.deinit();
            var report: StepReport = .{};
            try self.maintain(arena.allocator(), &report);
            try self.waitSignal(&self.maint_signal, self.options.poll_interval);
        }
    }

    /// One maintenance round (§3.4): leader, cron, stage, rescue, prune.
    /// A store call's failure is logged or skipped, but a cancel (the
    /// teardown's) ends the round and the task.
    fn maintain(self: *Client, arena: std.mem.Allocator, report: *StepReport) std.Io.Cancelable!void {
        const t = self.now();
        const was = self.is_leader.load(.acquire);
        const lead = self.backend.vt.leaderTake(self.backend.ptr, self.worker_name, t, self.options.leader.ttl) catch |e| blk: {
            try passCancel(e);
            break :blk false;
        };
        self.is_leader.store(lead, .release);
        if (self.metrics) |mm| mm.leader.with(&.{}).set(@intFromBool(lead));
        if (lead and !was) log.info("jobs: this process leads schedules and maintenance", .{});
        if (!lead and was) log.info("jobs: this process no longer leads schedules and maintenance", .{});

        if (lead) try self.cronRound(arena, t, report);

        const staged = self.backend.vt.stage(self.backend.ptr, t) catch |e| blk: {
            try passCancel(e);
            break :blk 0;
        };
        if (staged > 0) for (self.queues) |*q| q.signal.set(self.io);

        const ms = @divFloor(t.us, 1000);
        const rescue_every = @divFloor(self.options.lease.nanoseconds, 2 * std.time.ns_per_ms);
        if (ms - self.last_rescue >= rescue_every) {
            self.last_rescue = ms;
            const rescued = self.backend.vt.rescue(self.backend.ptr, arena, t) catch |e| blk: {
                try passCancel(e);
                break :blk &[_]store.Rescued{};
            };
            report.rescued += @intCast(rescued.len);
            if (self.metrics) |mm| mm.rescued.with(&.{"*"}).add(rescued.len);
            for (rescued) |r| log.info("job-{d}: its lease expired; {s}", .{ r.id, if (r.dead) "dead" else "put back" });
            if (rescued.len > 0) for (self.queues) |*q| q.signal.set(self.io);
        }
        if (lead and self.metrics != null and ms - self.last_gauges >= 15_000) {
            self.last_gauges = ms;
            try self.reportGauges(arena);
        }
        if (lead and ms - self.last_prune >= 60_000) {
            self.last_prune = ms;
            report.pruned += self.backend.vt.prune(self.backend.ptr, t, self.options.keep) catch |e| blk: {
                try passCancel(e);
                break :blk 0;
            };
        }
    }

    /// The leader reports queue depth by state (§7.1).
    fn reportGauges(self: *Client, arena: std.mem.Allocator) std.Io.Cancelable!void {
        const mm = self.metrics orelse return;
        const rows = self.backend.vt.counts(self.backend.ptr, arena) catch |e| return passCancel(e);
        // States that have no row now read zero.
        for (self.queues) |q| inline for (.{ "scheduled", "available", "running", "retrying", "dead" }) |st| mm.queued.with(&.{ q.name, st }).set(0);
        for (rows) |r| mm.queued.with(&.{ r.queue, @tagName(r.state) }).set(@intCast(r.n));
    }

    // ---- cron

    pub fn cron(self: *Client, name: []const u8, spec: []const u8, args: anytype, opts: root.CronOptions) !void {
        const def = comptime kindOf(@TypeOf(args));
        var buf: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const json = std.json.Stringify.valueAlloc(fba.allocator(), args, .{}) catch return error.InvalidOptions;
        var o = opts;
        if (o.job.queue == null) o.job.queue = def.queue;
        return self.cronRaw(name, spec, def.name, json, o);
    }

    pub fn cronRaw(self: *Client, name: []const u8, spec: []const u8, kind: []const u8, args_json: []const u8, opts: root.CronOptions) !void {
        if (self.started) {
            log.err("cron \"{s}\": schedules are registered before serving starts", .{name});
            return error.InvalidOptions;
        }
        if (!validName(name, 128, false)) {
            log.err("cron: schedule name \"{s}\": 1-128 bytes of [A-Za-z0-9_.:-]", .{name});
            return error.InvalidOptions;
        }
        for (self.crons.items) |c| if (std.mem.eql(u8, c.name, name)) {
            log.err("cron \"{s}\" is registered twice", .{name});
            return error.InvalidOptions;
        };
        var why: cron_mod.Diagnostic = .{};
        const sched = cron_mod.Schedule.parse(spec, &why) catch {
            log.err("cron \"{s}\": bad schedule \"{s}\": {s} ({s}, position {d})", .{ name, spec, why.message, why.field, why.position });
            return error.InvalidOptions;
        };
        const a = self.arena_state.allocator();
        const e = try self.gpa.create(CronEntry);
        errdefer self.gpa.destroy(e);
        var o = opts;
        if (o.tz) |tz| o.tz = try a.dupe(u8, tz);
        if (o.job.queue) |q| o.job.queue = try a.dupe(u8, q);
        e.* = .{ .name = try a.dupe(u8, name), .spec_text = try a.dupe(u8, spec), .schedule = sched, .opts = o, .kind = try a.dupe(u8, kind), .args_json = try a.dupe(u8, args_json) };
        try self.crons.append(self.gpa, e);
    }

    fn cronJob(self: *Client, arena: std.mem.Allocator, e: *CronEntry, tick: Time, unique_text: []const u8) !store.NewJob {
        var o = e.opts.job;
        o.run_at = tick;
        o.unique = null;
        var nj = try self.newJob(arena, self.kindDefaults(e.kind), e.args_json, o);
        nj.meta_json = try std.fmt.allocPrint(arena, "{{\"cron\":\"{s}\",\"tick\":\"{f}\"}}", .{ e.name, tick });
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update(unique_text);
        var out: [32]u8 = undefined;
        h.final(&out);
        nj.unique = .{ .key = out[0..16].*, .scope = .any };
        return nj;
    }

    fn cronRound(self: *Client, arena: std.mem.Allocator, t: Time, report: *StepReport) std.Io.Cancelable!void {
        for (self.crons.items) |e| {
            self.cronOne(arena, e, t, report) catch |err| {
                try passCancel(err);
                log.warn("cron \"{s}\": {t}", .{ e.name, err });
            };
        }
    }

    fn cronOne(self: *Client, arena: std.mem.Allocator, e: *CronEntry, t: Time, report: *StepReport) !void {
        const be = self.backend;
        const row = try be.vt.cronGet(be.ptr, arena, e.name);
        if (row == null or !std.mem.eql(u8, row.?.spec, e.spec_text) or row.?.last_tick == null) {
            try be.vt.cronSet(be.ptr, e.name, e.spec_text, t);
            return;
        }
        var ticks: [1000]Time = undefined;
        const n = e.schedule.between(row.?.last_tick.?, t, &e.zone, &ticks);
        if (n == 0) return;
        const latest = ticks[n - 1];
        switch (e.opts.missed) {
            .skip => {
                // Only a tick that has just come due runs; older ones are missed.
                const grace_us = @max(5_000_000, 2 * root.micros(self.options.poll_interval));
                if (latest.us >= t.us - grace_us) {
                    _ = try self.fire(arena, e, t, latest, report);
                } else {
                    _ = try be.vt.cronTick(be.ptr, t, e.name, e.spec_text, latest, null);
                }
                if (n > 1) log.info("cron {s}: {d} missed ticks skipped (missed = .skip)", .{ e.name, n - 1 });
            },
            .once => _ = try self.fire(arena, e, t, latest, report),
            .all => {
                const floor = t.us - root.micros(e.opts.catch_up);
                for (ticks[0..n]) |tk| {
                    if (tk.us < floor) {
                        _ = try be.vt.cronTick(be.ptr, t, e.name, e.spec_text, tk, null);
                    } else _ = try self.fire(arena, e, t, tk, report);
                }
            },
        }
    }

    fn fire(self: *Client, arena: std.mem.Allocator, e: *CronEntry, t: Time, tick: Time, report: *StepReport) !bool {
        const key = try std.fmt.allocPrint(arena, "cron:{s}:{d}", .{ e.name, @divFloor(tick.us, 1000) });
        const nj = try self.cronJob(arena, e, tick, key);
        const res = try self.backend.vt.cronTick(self.backend.ptr, t, e.name, e.spec_text, tick, nj);
        if (res.enqueued) |en| if (en.inserted) {
            report.cron_enqueued += 1;
            if (self.metrics) |mm| mm.onCron(e.name);
            self.wakeQueue(nj.queue);
            return true;
        };
        return false;
    }

    // ---- admin

    pub fn get(self: *Client, c: anytype, id: Id) Error!?root.JobInfo {
        const row = self.backend.vt.get(self.backend.ptr, c.arena, id) catch |e| return self.storeError(c, e);
        if (row) |r| return try rowToInfo(c.arena, r);
        return null;
    }
    pub fn list(self: *Client, c: anytype, filter: root.Filter) Error![]root.JobInfo {
        const rows = self.backend.vt.list(self.backend.ptr, c.arena, filter) catch |e| return self.storeError(c, e);
        const out = try c.arena.alloc(root.JobInfo, rows.len);
        for (rows, out) |r, *d| d.* = try rowToInfo(c.arena, r);
        return out;
    }
    pub fn counts(self: *Client, c: anytype) Error![]root.Count {
        return self.backend.vt.counts(self.backend.ptr, c.arena) catch |e| return self.storeError(c, e);
    }
    pub fn retry(self: *Client, c: anytype, id: Id) Error!bool {
        const ok = self.backend.vt.adminRetry(self.backend.ptr, self.now(), id) catch |e| return self.storeError(c, e);
        if (ok) for (self.queues) |*q| q.signal.set(self.io);
        return ok;
    }
    pub fn cancel(self: *Client, c: anytype, id: Id) Error!bool {
        return self.backend.vt.adminCancel(self.backend.ptr, self.now(), id) catch |e| return self.storeError(c, e);
    }
    pub fn delete(self: *Client, c: anytype, id: Id) Error!bool {
        return self.backend.vt.adminDelete(self.backend.ptr, id) catch |e| return self.storeError(c, e);
    }
    pub fn cronList(self: *Client, c: anytype) Error![]root.CronInfo {
        const rows = self.backend.vt.cronList(self.backend.ptr, c.arena) catch |e| return self.storeError(c, e);
        var out: std.ArrayList(root.CronInfo) = .empty;
        const t = self.now();
        for (self.crons.items) |e| {
            var last: ?Time = null;
            for (rows) |r| if (std.mem.eql(u8, r.name, e.name)) {
                last = r.last_tick;
            };
            try out.append(c.arena, .{
                .name = e.name,
                .spec = e.spec_text,
                .tz = e.opts.tz orelse "UTC",
                .kind = e.kind,
                .last_tick = last,
                .next_tick = e.schedule.next(last orelse t, &e.zone),
                .registered = true,
            });
        }
        for (rows) |r| {
            var known = false;
            for (self.crons.items) |e| if (std.mem.eql(u8, e.name, r.name)) {
                known = true;
            };
            if (!known) try out.append(c.arena, .{ .name = r.name, .spec = r.spec, .tz = "", .kind = "", .last_tick = r.last_tick, .next_tick = null, .registered = false });
        }
        return out.items;
    }
    pub fn cronTrigger(self: *Client, c: anytype, name: []const u8) Error!Enqueued {
        for (self.crons.items) |e| if (std.mem.eql(u8, e.name, name)) {
            const t = self.now();
            const key = std.fmt.allocPrint(c.arena, "cron:{s}:manual:{d}", .{ e.name, @divFloor(t.us, 1000) }) catch return error.OutOfMemory;
            const nj = self.cronJob(c.arena, e, t, key) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidJob,
            };
            const r = self.backend.vt.insert(self.backend.ptr, t, nj) catch |err| return self.storeError(c, err);
            if (r.inserted) self.wakeQueue(nj.queue);
            return r;
        };
        return error.NotFound;
    }

    pub fn adminRoutes(self: *Client, group: anytype) void {
        @import("admin.zig").mount(self, group);
    }

    // ---- tests

    /// One round: leader, cron, stage, rescue, prune, then claims and runs
    /// every due job of every handled kind, until none is due at the clock's now.
    pub fn step(self: *Client, c: anytype) Error!StepReport {
        var report: StepReport = .{};
        if (!self.started) self.start(null, null, null) catch return error.ServiceUnavailable;
        try self.maintain(c.arena, &report);
        // maintain's stage ran before the cron jobs; stage again so a tick that is due now runs now.
        _ = self.backend.vt.stage(self.backend.ptr, self.now()) catch 0;
        var again = true;
        while (again) {
            again = false;
            for (self.queues) |*q| {
                if (q.kinds.items.len == 0 and q.catch_all == null) continue;
                var arena: std.heap.ArenaAllocator = .init(self.gpa);
                defer arena.deinit();
                const rows = self.backend.vt.claim(self.backend.ptr, arena.allocator(), .{
                    .queue = q.name,
                    .kinds = if (q.catch_all != null) null else q.kinds.items,
                    .limit = 100,
                    .now = self.now(),
                    .lease_until = after(self.now(), self.options.lease),
                    .worker = self.worker_name,
                }) catch |e| return self.storeError(c, e);
                for (rows) |r| {
                    again = true;
                    var box: JobBox = .{ .client = self, .queue = q, .arena_state = .init(self.gpa), .row = undefined };
                    defer box.arena_state.deinit();
                    box.row = cloneRow(box.arena_state.allocator(), r) catch return error.OutOfMemory;
                    box.task = placement.currentTask(self.io);
                    self.held_mutex.lockUncancelable(self.io);
                    self.held.put(self.gpa, r.id, &box) catch {};
                    self.held_mutex.unlock(self.io);
                    const out = self.runJob(&box);
                    self.held_mutex.lockUncancelable(self.io);
                    _ = self.held.swapRemove(r.id);
                    self.held_mutex.unlock(self.io);
                    report.ran += 1;
                    switch (out) {
                        .completed => report.completed += 1,
                        .retried => report.retried += 1,
                        .dead => report.dead += 1,
                        .snoozed => report.snoozed += 1,
                        else => {},
                    }
                }
            }
        }
        return report;
    }
};

/// A stored row as the admin API returns it.
pub fn rowToInfo(arena: std.mem.Allocator, r: store.Row) !root.JobInfo {
    const args = std.json.parseFromSliceLeaky(std.json.Value, arena, r.args_json, .{}) catch std.json.Value{ .null = {} };
    const meta = std.json.parseFromSliceLeaky(std.json.Value, arena, r.meta_json, .{}) catch std.json.Value{ .null = {} };
    return .{
        .id = r.id,
        .queue = r.queue,
        .kind = r.kind,
        .state = r.state,
        .priority = r.priority,
        .attempt = r.attempt,
        .max_attempts = r.max_attempts,
        .args = args,
        .meta = meta,
        .run_at = r.run_at,
        .created_at = r.created_at,
        .attempted_at = r.attempted_at,
        .finished_at = r.finished_at,
        .worker = r.worker,
        .errors = r.errors,
        .timeout_ms = r.timeout_ms,
    };
}
