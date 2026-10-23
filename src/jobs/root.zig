//! Durable background jobs (`-Djobs`): enqueue, workers, retries with
//! backoff, delays and unique jobs, stored in memory, SQLite, PostgreSQL or
//! Redis so they survive restarts (p3/jobs, design-jobs.md).
//!
//!     const SendWelcome = struct {
//!         user_id: i64,
//!         pub const job: anole.jobs.Kind = .{ .name = "email.welcome", .queue = "mail" };
//!     };
//!     state.jobs = try app.jobs(.{ .store = .{ .postgres = state.db } });
//!     try state.jobs.handle(&app, SendWelcome, .{}, sendWelcome);
//!     _ = try state.jobs.enqueue(req, SendWelcome{ .user_id = 7 }, .{});
//!
//! Jobs run at least once: a handler must be safe to run again. See
//! docs/jobs.md.
const std = @import("std");
const anole = @import("../root.zig");
const dusty = @import("dusty");
const resilience = @import("../resilience/root.zig");
const observe = @import("../observe/root.zig");

pub const Duration = std.Io.Duration;
pub const Time = anole.db.Time;
pub const Id = i64;

/// Where jobs live.
pub const Store = union(enum) {
    postgres: *anole.pg.Client,
    sqlite: *anole.sqlite.Client,
    redis: if (anole.features.redis) *anole.redis.Client else *anyopaque,
    /// In this process only: lost on restart. Tests and single-process apps.
    memory,
};

pub const Priority = enum(u8) { critical = 0, high = 1, normal = 2, low = 3 };

/// A job kind's defaults, declared on its args type:
///     pub const job: anole.jobs.Kind = .{ .name = "email.welcome", .queue = "mail" };
pub const Kind = struct {
    /// 1-128 bytes of [A-Za-z0-9_.:-]; "anole." is reserved.
    name: []const u8,
    queue: []const u8 = "default",
    priority: Priority = .normal,
    /// Every try, the first included; 1 = no retry. 1..1000.
    attempts: u16 = 20,
    backoff: resilience.Backoff = default_backoff,
    /// A bound on each run; `.max`: none.
    timeout: Duration = .fromSeconds(900),
};
pub const default_backoff: resilience.Backoff = .{ .base = .fromSeconds(15), .multiplier = 2, .max = .fromSeconds(21600), .jitter = .equal };

pub const QueueOptions = struct {
    /// 1-64 bytes of [a-z0-9_.-].
    name: []const u8,
    /// Jobs of this queue run at once in this process (over all executors). 1..10_000.
    concurrency: u32 = 10,
};

pub const Options = struct {
    store: Store,
    /// The queues this process works (when it has handlers for their kinds).
    queues: []const QueueOptions = &.{.{ .name = "default" }},
    run: Run = .auto,
    /// How long a claimed job is held without a heartbeat; heartbeats every lease/3. >= 3 s.
    lease: Duration = .fromSeconds(30),
    /// Staging, idle claims, rescue checks. 100 ms .. 60 s.
    poll_interval: Duration = .fromSeconds(1),
    keep: Keep = .{},
    /// PostgreSQL/SQLite table name prefix: [a-z_][a-z0-9_]{0,31}.
    table_prefix: []const u8 = "anole_",
    /// Redis key prefix ("anole:" -> "anole:jobs:...").
    key_prefix: []const u8 = "anole:",
    /// Create the tables at start (see `sql`).
    migrate: bool = true,
    /// LISTEN/NOTIFY (PostgreSQL), pub/sub (Redis); off behind PgBouncer transaction pooling.
    notify: bool = true,
    leader: Leader = .{},
    /// Null: the real clock. Tests: `anole.jobs.testing.FakeClock`.
    clock: ?Clock = null,
    /// This process's name in `worker` columns and logs; null: "<hostname>:<pid>".
    name: ?[]const u8 = null,
    /// Kinds known by name only (`enqueueRaw`, the ABI): their defaults.
    kinds: []const Kind = &.{},
    /// Hook for every job that becomes dead (after its last attempt or a discard).
    on_dead: ?DeadHook = null,

    pub const Run = enum {
        /// Workers for registered handlers, leader and maintenance; in lambda mode, none.
        auto,
        /// Enqueue and admin only: no fetchers, no leader, no maintenance.
        enqueue_only,
        /// Nothing in the background: tests drive it with `step`.
        manual,
    };
    pub const Keep = struct {
        completed: Duration = .fromSeconds(86400),
        dead: Duration = .fromSeconds(2592000),
        cancelled: Duration = .fromSeconds(604800),
    };
    pub const Leader = struct {
        /// auto: advisory_lock on PostgreSQL, lease row on SQLite, SET NX on Redis.
        method: Method = .auto,
        /// A leader that cannot renew within this loses it. >= 3 * renew.
        ttl: Duration = .fromSeconds(15),
        renew: Duration = .fromSeconds(5),
        pub const Method = enum { auto, advisory_lock, lease_row };
    };
    pub const DeadHook = struct { context: ?*anyopaque = null, call: *const fn (context: ?*anyopaque, info: *const JobInfo) void };
};

pub const Error = anole.db.Error || error{ Canceled, OutOfMemory, InvalidJob };

pub const Unique = struct {
    /// Null: the args' JSON (as serialized) decides.
    key: ?[]const u8 = null,
    /// Unique within each window of this length (the window index joins the key).
    period: ?Duration = null,
    scope: Scope = .unfinished,
    pub const Scope = enum(u8) {
        /// While scheduled, available or retrying: one waiting at most (debounce).
        pending = 1,
        /// ... or running.
        unfinished = 2,
        /// In any state, until pruned (idempotency keys).
        any = 3,
    };
};

pub const EnqueueOptions = struct {
    /// Null: the kind's.
    queue: ?[]const u8 = null,
    priority: ?Priority = null,
    /// When it may run; null: now. Not both `run_at` and `delay` (InvalidJob).
    run_at: ?Time = null,
    delay: ?Duration = null,
    attempts: ?u16 = null,
    timeout: ?Duration = null,
    unique: ?Unique = null,
    /// A JSON object kept with the job (`job.meta`); Anole adds `traceparent`, `cron`, `tick`.
    meta: ?[]const u8 = null,
};

pub const Enqueued = struct {
    id: Id,
    /// False: a unique job like it existed; `id` is that job's.
    inserted: bool,
};

pub const CronOptions = struct {
    /// IANA name, "UTC" or an offset; null: UTC.
    tz: ?[]const u8 = null,
    missed: Missed = .once,
    /// `.all` looks back this far at most.
    catch_up: Duration = .fromSeconds(86400),
    /// Job options for each tick (queue/priority/attempts/timeout; `unique` and `run_at` are set by the runner).
    job: EnqueueOptions = .{},
    pub const Missed = enum { skip, once, all };
};

pub const State = enum { scheduled, available, running, retrying, completed, dead, cancelled };

pub const Filter = struct {
    state: ?State = null,
    queue: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    /// 1..500.
    limit: u16 = 50,
    /// Newest first; jobs with a smaller id than this (paging).
    before: ?Id = null,
};
pub const Count = struct { queue: []const u8, state: State, n: u64 };

pub const ErrorEntry = struct { attempt: u16, at: Time, @"error": []const u8, message: []const u8 = "" };

/// A stored job, as the admin API returns it (also JSON).
pub const JobInfo = struct {
    id: Id,
    queue: []const u8,
    kind: []const u8,
    state: State,
    priority: Priority,
    attempt: u16,
    max_attempts: u16,
    args: std.json.Value,
    meta: std.json.Value,
    run_at: Time,
    created_at: Time,
    attempted_at: ?Time,
    finished_at: ?Time,
    worker: ?[]const u8,
    errors: []const ErrorEntry,
    timeout_ms: ?u32,
};
pub const CronInfo = struct {
    name: []const u8,
    spec: []const u8,
    tz: []const u8,
    kind: []const u8,
    last_tick: ?Time,
    next_tick: ?Time,
    /// False for a row in the store that no running code registers.
    registered: bool,
};

pub const StepReport = struct { ran: u32 = 0, completed: u32 = 0, retried: u32 = 0, dead: u32 = 0, snoozed: u32 = 0, cron_enqueued: u32 = 0, rescued: u32 = 0, pruned: u32 = 0 };

/// Wall-clock time for every store write (J15).
pub const Clock = struct {
    context: ?*anyopaque = null,
    now: *const fn (context: ?*anyopaque) Time,
};

pub const HandleOptions = struct {};

/// One job run, a context like a request (`io`, `arena`, `locals`): connectors take it.
pub const Job = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    locals: dusty.Locals = .{},
    /// For logs: "job-<id>".
    id_text: []const u8,
    id: Id,
    kind: []const u8,
    queue: []const u8,
    /// The args as stored (JSON).
    args_json: []const u8,
    meta_json: []const u8,
    /// 1 on the first run.
    attempt: u16,
    max_attempts: u16,
    priority: Priority,
    run_at: Time,
    created_at: Time,
    /// Earlier attempts' errors, oldest first (at most 10).
    errors: []const ErrorEntry,
    client: *Client,
    /// What the handler asked for (`snooze`, `discard`, `retryIn`, `explain`).
    outcome: Outcome = .{},

    pub const Outcome = struct {
        kind: enum { none, snooze, discard, retry_in } = .none,
        delay: Duration = .fromSeconds(0),
        reason: []const u8 = "",
        explanation: []const u8 = "",
    };

    /// The args parsed as JSON into the arena.
    pub fn args(self: *Job, comptime T: type) !T {
        return std.json.parseFromSliceLeaky(T, self.arena, self.args_json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    }
    /// The args as a `T` checked by its `field_rules`; a violation discards the
    /// job (it can never pass) with `error.ValidationFailed`.
    pub fn bind(self: *Job, comptime T: type) !T {
        const result = try dusty.bindJson(T, self.arena, self.args_json, .{});
        switch (result) {
            .ok => |value| return value,
            else => {
                self.discard("the job's arguments are invalid");
                return error.ValidationFailed;
            },
        }
    }
    /// The handler then returns normally (`return job.snooze(.fromSeconds(300));`):
    /// run again later, the attempt not counted.
    pub fn snooze(self: *Job, delay: Duration) void {
        self.outcome = .{ .kind = .snooze, .delay = delay };
    }
    /// Dead now, `reason` in its errors.
    pub fn discard(self: *Job, reason: []const u8) void {
        self.outcome = .{ .kind = .discard, .reason = reason };
    }
    /// Counts as a failed attempt, retried after this delay.
    pub fn retryIn(self: *Job, delay: Duration) void {
        self.outcome = .{ .kind = .retry_in, .delay = delay };
    }
    /// A message stored with the error if the handler then fails.
    pub fn explain(self: *Job, comptime fmt: []const u8, a: anytype) void {
        self.outcome.explanation = std.fmt.allocPrint(self.arena, fmt, a) catch "";
    }
    /// The cron schedule that made it, or null.
    pub fn cronName(self: *const Job) ?[]const u8 {
        _ = self;
        return null;
    }
};

pub const Client = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    options: Options,

    /// `app.jobs(options)` calls it; outside an app, `init`, `start`, `drain`, `deinit`.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, options: Options) !*Client {
        const self = try gpa.create(Client);
        self.* = .{ .gpa = gpa, .io = io, .options = options };
        return self;
    }
    pub fn deinit(self: *Client) void {
        self.gpa.destroy(self);
    }
    /// Migrates, loads cron state, starts fetchers, heartbeat, wakes, leader (per `run`).
    pub fn start(self: *Client, registry: ?*observe.metrics.Registry, tracer: ?*observe.trace.Exporter, health: ?*observe.Health) !void {
        _ = self;
        _ = registry;
        _ = tracer;
        _ = health;
    }
    /// Stops claiming; running jobs finish by `deadline`, then are put back (J14).
    pub fn drain(self: *Client, deadline: std.Io.Clock.Timestamp) void {
        _ = self;
        _ = deadline;
    }

    // ---- enqueue (every call takes the request, a Ctx, a *Job or a broker Msg first)
    /// `args`' type declares `pub const job: Kind`; serialized with std.json.
    pub fn enqueue(self: *Client, c: anytype, args: anytype, opts: EnqueueOptions) Error!Enqueued {
        _ = .{ self, c, args, opts };
        return error.InvalidJob;
    }
    /// By kind name and a JSON value (an object, usually). The kind's defaults
    /// come from `Options.kinds`, else `Kind{ .name }`'s.
    pub fn enqueueRaw(self: *Client, c: anytype, kind: []const u8, args_json: []const u8, opts: EnqueueOptions) Error!Enqueued {
        _ = .{ self, c, kind, args_json, opts };
        return error.InvalidJob;
    }
    /// Inside the app's transaction (`*anole.pg.Tx` or `*anole.sqlite.Tx` on
    /// this store's database); committed with it.
    pub fn enqueueIn(self: *Client, tx: anytype, c: anytype, args: anytype, opts: EnqueueOptions) Error!Enqueued {
        _ = .{ self, tx, c, args, opts };
        return error.InvalidJob;
    }
    pub fn enqueueRawIn(self: *Client, tx: anytype, c: anytype, kind: []const u8, args_json: []const u8, opts: EnqueueOptions) Error!Enqueued {
        _ = .{ self, tx, c, kind, args_json, opts };
        return error.InvalidJob;
    }
    /// Up to 1000 jobs in one round trip.
    pub fn enqueueMany(self: *Client, c: anytype, items: []const Item) Error![]Enqueued {
        _ = .{ self, c, items };
        return error.InvalidJob;
    }
    pub const Item = struct { kind: []const u8, args_json: []const u8, opts: EnqueueOptions = .{} };

    // ---- workers
    /// Runs `handler` for every job of `Args`' kind once serving starts.
    /// `handler` is `fn (*Job, Args) !void` or `fn (*App, *Job, Args) !void`
    /// (`server` is the `*anole.Server(App)`). Register before `run`/`start`.
    pub fn handle(self: *Client, server: anytype, comptime Args: type, opts: HandleOptions, comptime handler: anytype) !void {
        _ = .{ self, server, opts, handler };
        if (@TypeOf(Args.job) != Kind) @compileError(@typeName(Args) ++ " needs `pub const job: anole.jobs.Kind = .{ .name = \"...\" }`");
        return error.InvalidOptions;
    }
    /// The same by name, args as JSON text: `fn (*Job) !void` / `fn (*App, *Job) !void`.
    pub fn handleRaw(self: *Client, server: anytype, kind: Kind, opts: HandleOptions, comptime handler: anytype) !void {
        _ = .{ self, server, kind, opts, handler };
        return error.InvalidOptions;
    }

    /// Marks `job` completed inside `tx` (PostgreSQL/SQLite): exactly once
    /// with the handler's own writes.
    pub fn completeIn(self: *Client, tx: anytype, job: *Job) Error!void {
        _ = .{ self, tx, job };
        return error.InvalidJob;
    }

    // ---- cron
    pub fn cron(self: *Client, name: []const u8, spec: []const u8, args: anytype, opts: CronOptions) !void {
        _ = .{ self, name, spec, args, opts };
        return error.InvalidOptions;
    }
    pub fn cronRaw(self: *Client, name: []const u8, spec: []const u8, kind: []const u8, args_json: []const u8, opts: CronOptions) !void {
        _ = .{ self, name, spec, kind, args_json, opts };
        return error.InvalidOptions;
    }

    // ---- admin
    pub fn get(self: *Client, c: anytype, id: Id) Error!?JobInfo {
        _ = .{ self, c, id };
        return error.InvalidJob;
    }
    pub fn list(self: *Client, c: anytype, filter: Filter) Error![]JobInfo {
        _ = .{ self, c, filter };
        return error.InvalidJob;
    }
    pub fn counts(self: *Client, c: anytype) Error![]Count {
        _ = .{ self, c };
        return error.InvalidJob;
    }
    /// dead, cancelled, retrying or scheduled -> available now; an exhausted
    /// job gets one more attempt. False: not in such a state.
    pub fn retry(self: *Client, c: anytype, id: Id) Error!bool {
        _ = .{ self, c, id };
        return error.InvalidJob;
    }
    /// scheduled/available/retrying -> cancelled; running -> cancelled, and
    /// its run is canceled. False: finished already.
    pub fn cancel(self: *Client, c: anytype, id: Id) Error!bool {
        _ = .{ self, c, id };
        return error.InvalidJob;
    }
    /// Finished jobs only (completed, dead, cancelled).
    pub fn delete(self: *Client, c: anytype, id: Id) Error!bool {
        _ = .{ self, c, id };
        return error.InvalidJob;
    }
    pub fn cronList(self: *Client, c: anytype) Error![]CronInfo {
        _ = .{ self, c };
        return error.InvalidJob;
    }
    /// Enqueues the schedule's job now (unique key `cron:<name>:manual:<now ms>`).
    pub fn cronTrigger(self: *Client, c: anytype, name: []const u8) Error!Enqueued {
        _ = .{ self, c, name };
        return error.InvalidJob;
    }
    /// GET <prefix>/jobs, /jobs/:id, /counts, /cron; POST /jobs/:id/retry,
    /// /jobs/:id/cancel, /cron/:name/trigger; DELETE /jobs/:id. JSON only.
    /// Mount it behind your own authentication.
    pub fn adminRoutes(self: *Client, group: anytype) void {
        _ = .{ self, group };
    }

    // ---- tests (run = .manual)
    /// One round: leader, cron, stage, rescue, prune, then claims and runs
    /// every due job of every handled kind, until none is due at the clock's now.
    pub fn step(self: *Client, c: anytype) Error!StepReport {
        _ = .{ self, c };
        return error.InvalidJob;
    }
};

/// The DDL for apps that migrate themselves (`migrate = false`).
pub fn sql(comptime dialect: enum { postgresql, sqlite }, table_prefix: []const u8, arena: std.mem.Allocator) ![]const u8 {
    _ = .{ dialect, table_prefix, arena };
    return error.Unsupported;
}

pub const testing = struct {
    /// A clock tests move by hand. `clock()` gives the `Clock` for `Options.clock`.
    pub const FakeClock = struct {
        ms: std.atomic.Value(i64),
        pub fn init(start: Time) FakeClock {
            return .{ .ms = .init(@divFloor(start.us, 1000)) };
        }
        fn read(context: ?*anyopaque) Time {
            const self: *FakeClock = @ptrCast(@alignCast(context.?));
            return Time.fromMillis(self.ms.load(.acquire));
        }
        pub fn clock(self: *FakeClock) Clock {
            return .{ .context = self, .now = read };
        }
        pub fn advance(self: *FakeClock, d: Duration) void {
            _ = self.ms.fetchAdd(@divFloor(d.nanoseconds, std.time.ns_per_ms), .acq_rel);
        }
        pub fn set(self: *FakeClock, t: Time) void {
            self.ms.store(@divFloor(t.us, 1000), .release);
        }
    };
};
