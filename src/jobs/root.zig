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

/// A duration in microseconds, clamped far below overflow (`Duration.max`).
pub fn micros(d: Duration) i64 {
    return @intCast(@min(@divFloor(d.nanoseconds, 1000), std.math.maxInt(i64) / 4));
}
/// A duration in milliseconds, clamped likewise.
pub fn millis(d: Duration) i64 {
    return @intCast(@min(@divFloor(d.nanoseconds, std.time.ns_per_ms), std.math.maxInt(i64) / 4000));
}

/// Where jobs live.
pub const Store = union(enum) {
    postgres: if (anole.features.postgres) *anole.pg.Client else *opaque {},
    sqlite: if (anole.features.sqlite) *anole.sqlite.Client else *opaque {},
    redis: if (anole.features.redis) *anole.redis.Client else *opaque {},
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
    /// Workers wait for this to open before they claim, and handlers may be
    /// registered until it does (the C ABI: until the server starts).
    gate: ?Gate = null,
    /// How long a server drain lets running jobs finish before they are put back.
    drain_timeout: Duration = .fromSeconds(10),
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

pub const Gate = struct { context: ?*anyopaque = null, is_open: *const fn (context: ?*anyopaque) bool };

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
    cron_name: ?[]const u8 = null,
    /// Set by `completeIn`: the run already completed the job in its own transaction.
    completed_in: bool = false,
    /// Set by the heartbeat when the job was cancelled through the admin API.
    admin_cancelled: std.atomic.Value(bool) = .init(false),
    /// Set while the run is going: the heartbeat lost it, or the drain put it back.
    lost_flag: ?*const std.atomic.Value(bool) = null,
    interrupted_flag: ?*const std.atomic.Value(bool) = null,
    /// The run's time limit in ms, or null.
    timeout_ms: ?u32 = null,

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
            .invalid => |found| {
                const first = found.items[0];
                self.discard("the job's arguments are invalid");
                self.explain("{s}: {s}", .{ first.field orelse "", first.code });
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
    /// The `traceparent` of the request (or job) that enqueued it, or null.
    pub fn traceparent(self: *const Job) ?[]const u8 {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, self.arena, self.meta_json, .{}) catch return null;
        if (parsed != .object) return null;
        const v = parsed.object.get("traceparent") orelse return null;
        return if (v == .string) v.string else null;
    }
    /// The cron schedule that made it, or null.
    pub fn cronName(self: *const Job) ?[]const u8 {
        return self.cron_name;
    }
};

pub const Client = @import("client.zig").Client;
pub const store = @import("store.zig");

/// The DDL for apps that migrate themselves (`migrate = false`).
pub fn sql(comptime dialect: enum { postgresql, sqlite }, table_prefix: []const u8, arena: std.mem.Allocator) ![]const u8 {
    switch (dialect) {
        .sqlite => return @import("store_sqlite.zig").ddlText(arena, table_prefix),
        .postgresql => return @import("store_pg.zig").ddlText(arena, table_prefix),
    }
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
            _ = self.ms.fetchAdd(millis(d), .acq_rel);
        }
        pub fn set(self: *FakeClock, t: Time) void {
            self.ms.store(@divFloor(t.us, 1000), .release);
        }
    };
};

test {
    _ = @import("conformance_test.zig");
    _ = @import("unique.zig");
    _ = @import("../cron/root.zig");
}
