//! `anole_jobs_*` and `anole_job_*`: durable jobs enqueued and worked by a
//! consumer (p3/jobs, design-jobs.md). Handle kinds 12 (`anole_job_worker`)
//! and 13 (`anole_job`); events 104-108.
//!
//! A skeleton for now: the hooks `engine.zig` calls, in their final
//! names and signatures (research/p3-pass/PLAN.md R42).
const std = @import("std");
const anole = @import("../root.zig");
const engine = @import("engine.zig");
const abi = @import("abi.zig");

const Engine = engine.Engine;
const AnswerError = engine.AnswerError;
const db = @import("db.zig");
const db_cap = db;
const gpa = engine.gpa;
const log = std.log.scoped(.anole);

/// Engine-wide state (`Engine.jobs_state`).
pub const State = struct {
    /// The queue behind `"jobs"` in the configuration, once `open` ran
    /// (the webhooks lane reads it); null when there is none.
    client: if (anole.features.jobs) ?*anole.jobs.Client else ?*anyopaque = null,

    pub fn init(s: *State, first_gen: u32) void {
        _ = s;
        _ = first_gen;
    }

    /// The highest generation handed out (`Engine.destroy`).
    pub fn maxGen(s: *State) u32 {
        _ = s;
        return 0;
    }

    pub fn deinit(s: *State) void {
        _ = s;
    }
};

/// Per executor (`Exec.jobs`): the tasks it runs are canceled at the stop.
pub const ExecState = struct {
    pub fn cancel(st: *ExecState, io: std.Io) void {
        _ = st;
        _ = io;
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

/// The server's main thread, before the listeners open (after `db.open`,
/// `nats.open` and `kafka.open`).
pub fn open(e: *Engine, app: *anole.App) !void {
    const jc = e.config.jobs orelse return;
    if (comptime !anole.features.jobs) {
        log.err("jobs: jobs are not built in (-Djobs)", .{});
        return error.InvalidOptions;
    } else openJobs(e, app, jc) catch |err| return err;
}

fn openJobs(e: *Engine, app: *anole.App, jc: @import("config.zig").Config.Jobs) !void {
    var queues = try gpa.alloc(anole.jobs.QueueOptions, jc.queues.len);
    for (jc.queues, queues[0..]) |q, *d| d.* = .{ .name = q.name, .concurrency = q.concurrency };
    var kinds = try gpa.alloc(anole.jobs.Kind, jc.kinds.len);
    for (jc.kinds, kinds[0..]) |k, *d| d.* = .{
        .name = k.name,
        .queue = k.queue,
        .priority = std.meta.stringToEnum(anole.jobs.Priority, k.priority) orelse .normal,
        .attempts = k.attempts,
        .timeout = .fromMilliseconds(@intCast(k.timeout_ms)),
    };
    const ms = std.Io.Duration.fromMilliseconds;
    var store: anole.jobs.Store = .memory;
    if (!std.mem.eql(u8, jc.store, "memory")) {
        const d = db_cap.find(e, jc.store) orelse {
            log.err("jobs.store \"{s}\": no such database", .{jc.store});
            return error.InvalidOptions;
        };
        switch (d.client) {
            .postgres => |c| if (comptime anole.features.postgres) {
                store = .{ .postgres = c };
            } else unreachable,
            .sqlite => |c| if (comptime anole.features.sqlite) {
                store = .{ .sqlite = c };
            } else unreachable,
            .redis => |c| if (comptime anole.features.redis) {
                store = .{ .redis = c };
            } else unreachable,
            else => {
                log.err("jobs.store \"{s}\": MongoDB cannot hold jobs", .{jc.store});
                return error.InvalidOptions;
            },
        }
    }
    e.jobs_state.client = try app.jobs(.{
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
        .keep = .{ .completed = ms(@intCast(jc.keep.completed_ms)), .dead = ms(@intCast(jc.keep.dead_ms)), .cancelled = ms(@intCast(jc.keep.cancelled_ms)) },
        .leader = .{
            .method = std.meta.stringToEnum(anole.jobs.Options.Leader.Method, jc.leader.method) orelse .auto,
            .ttl = ms(jc.leader.ttl_ms),
            .renew = ms(jc.leader.renew_ms),
        },
    });
}

/// The drain started (`anole_server_drain`, once).
pub fn draining(e: *Engine) void {
    _ = e;
}

/// The server stops: nothing new starts from here.
pub fn close(e: *Engine) void {
    _ = e;
}

/// `anole_server_destroy`: frees what a stopped server still holds.
pub fn destroy(e: *Engine) void {
    _ = e;
}

/// `anole_handle_release` for the kinds `job_worker` and `job` (a cleanup call: a handle that is
/// over answers `error.Over`, which is `ANOLE_OK`).
pub fn release(e: *Engine, hv: u64) AnswerError!void {
    _ = e;
    _ = hv;
    return error.Over;
}

/// A ``job_enqueue` or `job_complete`` call queued on an open transaction (`db.TxWhat`), run in
/// order on the transaction's connection.
pub fn txOp(any: *db.AnyTx, ctx: *anole.db.Ctx, op: *const db.TxOp, answer: *db.Answer) anyerror!void {
    _ = any;
    _ = ctx;
    _ = op;
    _ = answer;
    return error.Unsupported;
}
