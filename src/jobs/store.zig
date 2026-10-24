//! The storage contract of the job queue (p3/jobs, design-jobs.md §3.3, §4):
//! every state change after a claim is conditional on `(id, attempt,
//! state = running)`, so a worker that lost its lease can never complete,
//! fail or snooze the job. A backend implements `VTable`; `store_memory.zig`
//! is the reference.
const std = @import("std");
const root = @import("root.zig");
const anole = @import("../root.zig");

pub const Time = root.Time;
pub const Id = root.Id;
pub const State = root.State;
pub const Priority = root.Priority;
pub const ErrorEntry = root.ErrorEntry;

/// A job as a store holds it (JSON as text). Strings belong to the arena of
/// the call that returned it.
pub const Row = struct {
    id: Id,
    queue: []const u8,
    kind: []const u8,
    state: State,
    priority: Priority,
    attempt: u16,
    max_attempts: u16,
    args_json: []const u8,
    meta_json: []const u8,
    run_at: Time,
    created_at: Time,
    attempted_at: ?Time = null,
    finished_at: ?Time = null,
    worker: ?[]const u8 = null,
    errors: []const ErrorEntry = &.{},
    timeout_ms: ?u32 = null,
};

pub const UniqueKey = struct {
    key: [16]u8,
    scope: root.Unique.Scope,
};

pub const NewJob = struct {
    queue: []const u8,
    kind: []const u8,
    args_json: []const u8,
    meta_json: []const u8 = "{}",
    priority: Priority = .normal,
    max_attempts: u16,
    run_at: Time,
    timeout_ms: ?u32 = null,
    unique: ?UniqueKey = null,
};

pub const ClaimRequest = struct {
    queue: []const u8,
    /// Null: every kind of the queue.
    kinds: ?[]const []const u8,
    limit: u32,
    now: Time,
    lease_until: Time,
    worker: []const u8,
};

pub const Held = struct { id: Id, attempt: u16 };

/// One conditional state change of a held job.
pub const Finish = struct {
    id: Id,
    attempt: u16,
    to: State,
    /// 0, or -1 for a snooze and an interrupt (the attempt is not counted).
    attempt_delta: i8 = 0,
    run_at: ?Time = null,
    finished_at: ?Time = null,
    /// Appended to the job's errors (the last 10 are kept).
    add_error: ?ErrorEntry = null,
};

pub const CronRow = struct { name: []const u8, spec: []const u8, last_tick: ?Time };

pub const CronTick = struct {
    /// The tick was recorded (nobody was ahead).
    recorded: bool,
    enqueued: ?root.Enqueued = null,
};

pub const Rescued = struct { id: Id, dead: bool };

/// Which states a unique key outlives.
pub fn covers(scope: root.Unique.Scope, state: State) bool {
    return switch (scope) {
        .pending => state == .scheduled or state == .available or state == .retrying,
        .unfinished => state == .scheduled or state == .available or state == .retrying or state == .running,
        .any => true,
    };
}

pub const max_errors = 10;

pub const VTable = struct {
    deinit: *const fn (ptr: *anyopaque) void,
    /// Creates the tables and the like. Idempotent.
    migrate: *const fn (ptr: *anyopaque) anyerror!void,
    insert: *const fn (ptr: *anyopaque, now: Time, job: NewJob) anyerror!root.Enqueued,
    claim: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, req: ClaimRequest) anyerror![]Row,
    /// scheduled/retrying due at `now` -> available; returns how many.
    stage: *const fn (ptr: *anyopaque, now: Time) anyerror!u32,
    /// Extends the lease of every held job still held; returns those ids.
    heartbeat: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, until: Time, held: []const Held) anyerror![]Id,
    finish: *const fn (ptr: *anyopaque, f: Finish) anyerror!bool,
    rescue: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, now: Time) anyerror![]Rescued,
    prune: *const fn (ptr: *anyopaque, now: Time, keep: root.Options.Keep) anyerror!u32,
    get: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, id: Id) anyerror!?Row,
    list: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, filter: root.Filter) anyerror![]Row,
    counts: *const fn (ptr: *anyopaque, arena: std.mem.Allocator) anyerror![]root.Count,
    adminRetry: *const fn (ptr: *anyopaque, now: Time, id: Id) anyerror!bool,
    adminCancel: *const fn (ptr: *anyopaque, now: Time, id: Id) anyerror!bool,
    adminDelete: *const fn (ptr: *anyopaque, id: Id) anyerror!bool,
    cronGet: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, name: []const u8) anyerror!?CronRow,
    cronList: *const fn (ptr: *anyopaque, arena: std.mem.Allocator) anyerror![]CronRow,
    /// Sets `last_tick` and `spec` unconditionally (first sight, changed spec).
    cronSet: *const fn (ptr: *anyopaque, name: []const u8, spec: []const u8, last_tick: Time) anyerror!void,
    /// Records `tick` when `last_tick` is absent or older, and inserts `job`
    /// in the same step (one transaction on a database).
    cronTick: *const fn (ptr: *anyopaque, now: Time, name: []const u8, spec: []const u8, tick: Time, job: ?NewJob) anyerror!CronTick,
    leaderTake: *const fn (ptr: *anyopaque, owner: []const u8, now: Time, ttl: root.Duration) anyerror!bool,
    leaderRelease: *const fn (ptr: *anyopaque, owner: []const u8) anyerror!void,
    /// `Client.enqueueIn`: the insert on the caller's open transaction (`tx`
    /// is the connector's `*Tx`, whose kind `Backend.tx_kind` names). Null
    /// for a store without transactions.
    /// Blocks listening for the store's wake-ups (PostgreSQL LISTEN, Redis
    /// pub/sub) and calls `wake.kick` for each, until it fails or is
    /// canceled. The client runs it in a task and reconnects with backoff.
    /// Null: in-process wakes and polling only.
    runWake: ?*const fn (ptr: *anyopaque, io: std.Io, wake: Wake) anyerror!void = null,
    insertIn: ?*const fn (ptr: *anyopaque, tx: *anyopaque, ctx: *anole.db.Ctx, now: Time, job: NewJob) anyerror!root.Enqueued = null,
    /// `Client.completeIn`: the conditional finish on the caller's transaction.
    finishIn: ?*const fn (ptr: *anyopaque, tx: *anyopaque, ctx: *anole.db.Ctx, f: Finish) anyerror!bool = null,
};

/// Where a store's wake-ups go: `kick` with a queue name wakes that queue's
/// fetcher, with "" every queue's (after a reconnect: notifications may have
/// been missed).
pub const Wake = struct {
    context: ?*anyopaque,
    kick: *const fn (context: ?*anyopaque, queue: []const u8) void,
};

/// Which connector's transaction a store takes in `insertIn`/`finishIn`.
pub const TxKind = enum { none, sqlite, postgres };

pub const Backend = struct {
    ptr: *anyopaque,
    vt: *const VTable,
    /// Whether `enqueueIn`/`completeIn` work (a PostgreSQL or SQLite store).
    transactional: bool = false,
    tx_kind: TxKind = .none,
    /// The connector client behind the store, to check a transaction belongs to it.
    owner: ?*anyopaque = null,
};
