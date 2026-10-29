//! The drain against runs that have finished: what a job's handler did is
//! saved, whatever the drain's cancel reaches (#108).
const std = @import("std");
const wait = @import("anole_test_wait");
const zio = @import("zio");
const anole = @import("../root.zig");
const root = @import("root.zig");
const store = @import("store.zig");

const gpa = std.testing.allocator;
const kind: root.Kind = .{ .name = "t.drain", .attempts = 3, .timeout = .max };

/// A drain whose deadline has passed: it cancels whatever still runs.
fn drainNow(client: *root.Client, io: std.Io) void {
    client.drain(std.Io.Clock.Timestamp.now(io, .awake));
}

/// Whether the drain has marked a held run interrupted (and canceled its
/// task: both happen under the lock this takes).
fn interruptedRun(client: *root.Client, io: std.Io) bool {
    client.held_mutex.lockUncancelable(io);
    defer client.held_mutex.unlock(io);
    for (client.held.values()) |b| if (b.interrupted.load(.acquire)) return true;
    return false;
}

fn waitFor(io: std.Io, comptime cond: anytype, args: anytype) !void {
    const C = struct {
        fn holds(a: @TypeOf(args)) bool {
            return @call(.auto, cond, a);
        }
    };
    try wait.waitUntil(io, "the drain test's condition (" ++ @typeName(@TypeOf(cond)) ++ ")", args, C.holds);
}

/// The store's `finish`, held for the first completion until the test lets
/// it go (a cancelable wait, as a store's network round trip is).
const HeldFinish = struct {
    var io: std.Io = undefined;
    var orig: *const store.VTable = undefined;
    var vt: store.VTable = undefined;
    var in_finish: std.atomic.Value(bool) = .init(false);
    var release: std.Io.Event = .unset;
    var runs: std.atomic.Value(u32) = .init(0);

    fn install(client: *root.Client, rio: std.Io) void {
        io = rio;
        in_finish.store(false, .release);
        release = .unset;
        runs.store(0, .release);
        orig = client.backend.vt;
        vt = orig.*;
        vt.finish = finish;
        client.backend.vt = &vt;
    }

    fn finish(ptr: *anyopaque, f: store.Finish) anyerror!bool {
        if (f.to == .completed and !in_finish.swap(true, .acq_rel)) try release.wait(io);
        return orig.finish(ptr, f);
    }

    fn run(_: ?*anyopaque, _: *root.Job) anyerror!void {
        _ = runs.fetchAdd(1, .acq_rel);
    }

    fn isIn() bool {
        return in_finish.load(.acquire);
    }
};

fn writeCanceledCheck(io: std.Io) !void {
    const client = try root.Client.init(gpa, io, .{ .store = .memory });
    defer client.deinit();
    HeldFinish.install(client, io);
    try client.addHandler(kind, null, HeldFinish.run);
    try client.start(null, null, null);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var ctx: anole.db.Ctx = .{ .io = io, .arena = arena.allocator() };
    const e = try client.enqueueRaw(&ctx, kind.name, "{}", .{});
    // The handler returned; its outcome's write is under way.
    try waitFor(io, HeldFinish.isIn, .{});
    var d = try io.concurrent(drainNow, .{ client, io });
    // A failed wait lets the held write go and waits for the drain before
    // the client goes; after the await below this does nothing.
    defer {
        HeldFinish.release.set(io);
        d.await(io);
    }
    try waitFor(io, interruptedRun, .{ client, io });
    // The drain's cancel has been sent; the write goes on.
    HeldFinish.release.set(io);
    d.await(io);
    const info = (try client.get(&ctx, e.id)).?;
    try std.testing.expectEqual(root.State.completed, info.state);
    try std.testing.expectEqual(@as(u32, 1), HeldFinish.runs.load(.acquire));
}

test "jobs: a finished run whose outcome write the drain's cancel reaches is saved (not run again)" {
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try io.concurrent(writeCanceledCheck, .{io});
    try f.await(io);
}

/// A handler that does its work, then sees the drain arrive before it
/// returns (its task canceled, the run marked interrupted).
const LateDrain = struct {
    var io: std.Io = undefined;
    var client: *root.Client = undefined;
    var drain_task: ?std.Io.Future(void) = null;
    /// Set once `drain_task` is: the test waits on this, not on the optional.
    var started_drain: bool = false;
    var runs: std.atomic.Value(u32) = .init(0);

    fn run(_: ?*anyopaque, job: *root.Job) anyerror!void {
        _ = runs.fetchAdd(1, .acq_rel);
        // The work is done. Now the drain, past its deadline.
        drain_task = try io.concurrent(drainNow, .{ client, io });
        @atomicStore(bool, &started_drain, true, .release);
        // The drain cancels this task: the wait runs with cancel
        // protection, so it ends on the flag, not on the cancel (which is
        // delivered at the next cancellation point after it).
        const prev = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(prev);
        wait.waitFlag(io, "the run was interrupted", job.interrupted_flag.?) catch return error.NeverInterrupted;
    }
};

fn lateDrainCheck(io: std.Io) !void {
    const client = try root.Client.init(gpa, io, .{ .store = .memory });
    defer client.deinit();
    LateDrain.io = io;
    LateDrain.client = client;
    LateDrain.drain_task = null;
    LateDrain.started_drain = false;
    LateDrain.runs.store(0, .release);
    try client.addHandler(kind, null, LateDrain.run);
    try client.start(null, null, null);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var ctx: anole.db.Ctx = .{ .io = io, .arena = arena.allocator() };
    const e = try client.enqueueRaw(&ctx, kind.name, "{}", .{});
    wait.waitUntil(io, "the job ran and started the drain", {}, struct {
        fn f(_: void) bool {
            return @atomicLoad(bool, &LateDrain.started_drain, .acquire);
        }
    }.f) catch return error.NeverRan;
    LateDrain.drain_task.?.await(io);
    const info = (try client.get(&ctx, e.id)).?;
    // Completed, not put back to run again.
    try std.testing.expectEqual(root.State.completed, info.state);
    try std.testing.expectEqual(@as(u32, 1), LateDrain.runs.load(.acquire));
}

test "jobs: a run that returned before the drain marked it interrupted keeps its outcome" {
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try io.concurrent(lateDrainCheck, .{io});
    try f.await(io);
}

/// A job that runs until canceled, in an App whose HTTP side has nothing
/// to drain: `run` returns at once, and the queue's own drain must still
/// give the job its `drain_timeout`.
const UntilCanceled = struct {
    var io: std.Io = undefined;
    var started: std.atomic.Value(bool) = .init(false);
    var stopped_at: std.atomic.Value(i64) = .init(0);
    var canceled_after_ns: std.atomic.Value(i64) = .init(-1);
    var never: std.Io.Event = .unset;

    fn run(job: *root.Job) anyerror!void {
        _ = job;
        started.store(true, .release);
        never.wait(io) catch |err| {
            const now: i64 = @intCast(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds);
            canceled_after_ns.store(now - stopped_at.load(.acquire), .release);
            return err;
        };
    }

    fn check(a: *anole.App) !void {
        defer {
            stopped_at.store(@intCast(std.Io.Clock.Timestamp.now(a.io(), .awake).raw.nanoseconds), .release);
            a.stop();
        }
        try a.waitReady();
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        var ctx: anole.db.Ctx = .{ .io = a.io(), .arena = arena.allocator() };
        _ = try jc.enqueueRaw(&ctx, kind.name, "{}", .{});
        try waitFor(a.io(), isStarted, .{});
    }

    fn isStarted() bool {
        return started.load(.acquire);
    }

    var jc: *root.Client = undefined;
};

test "jobs: with no connection to drain, a running job still gets the queue's drain_timeout" {
    // Regression guard for 1751ae8: the drain under way is waited for, not cut short.
    {
        var app = try anole.App.init(gpa, .{ .executors = .exact(2), .listen_tls_http3 = false });
        defer app.deinit();
        UntilCanceled.io = app.io();
        UntilCanceled.started.store(false, .release);
        UntilCanceled.canceled_after_ns.store(-1, .release);
        UntilCanceled.never = .unset;
        UntilCanceled.jc = try app.jobs(.{ .store = .memory, .drain_timeout = .fromMilliseconds(200) });
        try UntilCanceled.jc.handleRaw(&app, kind, .{}, UntilCanceled.run);
        var checking = try app.io().concurrent(UntilCanceled.check, .{&app});
        defer checking.cancel(app.io()) catch {};
        try app.listen("127.0.0.1:0");
        try checking.await(app.io());
    }
    const after = UntilCanceled.canceled_after_ns.load(.acquire);
    // Canceled, and not before the drain_timeout ran out (a lower bound only:
    // stopped_at is taken before the stop, so it holds on any machine).
    try std.testing.expect(after >= 0);
    try std.testing.expect(after >= 180 * std.time.ns_per_ms);
}

/// The store's `finish` always fails.
const FailingFinish = struct {
    var orig: *const store.VTable = undefined;
    var vt: store.VTable = undefined;
    var runs: std.atomic.Value(u32) = .init(0);

    fn install(client: *root.Client) void {
        runs.store(0, .release);
        orig = client.backend.vt;
        vt = orig.*;
        vt.finish = finish;
        client.backend.vt = &vt;
    }

    fn finish(_: *anyopaque, _: store.Finish) anyerror!bool {
        return error.ConnectionRefused;
    }

    fn run(_: ?*anyopaque, _: *root.Job) anyerror!void {
        _ = runs.fetchAdd(1, .acq_rel);
    }
};

fn unsavedCount(registry: *anole.observe.metrics.Registry) u64 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    registry.render(&out.writer) catch return 0;
    const needle = "anole_jobs_outcome_unsaved_total{queue=\"default\",kind=\"t.drain\"} ";
    const at = std.mem.indexOf(u8, out.written(), needle) orelse return 0;
    const rest = out.written()[at + needle.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
    return std.fmt.parseInt(u64, rest[0..end], 10) catch 0;
}

fn unsavedCheck(io: std.Io) !void {
    var registry: anole.observe.metrics.Registry = .init(gpa, io);
    defer registry.deinit();
    const client = try root.Client.init(gpa, io, .{ .store = .memory });
    defer client.deinit();
    FailingFinish.install(client);
    try client.addHandler(kind, null, FailingFinish.run);
    try client.start(&registry, null, null);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var ctx: anole.db.Ctx = .{ .io = io, .arena = arena.allocator() };
    _ = try client.enqueueRaw(&ctx, kind.name, "{}", .{});
    // Three tries, 50 + 100 ms apart, then the run counts as unsaved.
    wait.waitUntil(io, "the unsaved outcome counted", &registry, struct {
        fn f(r: *anole.observe.metrics.Registry) bool {
            return unsavedCount(r) >= 1;
        }
    }.f) catch return error.NeverCounted;
    try std.testing.expectEqual(@as(u64, 1), unsavedCount(&registry));
}

test "jobs: a run whose outcome could not be saved is counted in anole_jobs_outcome_unsaved_total" {
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try io.concurrent(unsavedCheck, .{io});
    try f.await(io);
}

/// The store's `rescue`, held in a cancelable wait (as a store's round trip
/// is) until the client's teardown cancels the maintenance task in it; its
/// `prune`, the round's next call, waits on the network too (briefly).
const HeldRescue = struct {
    var io: std.Io = undefined;
    var vt: store.VTable = undefined;
    var entered: std.atomic.Value(bool) = .init(false);

    fn install(client: *root.Client, rio: std.Io) void {
        io = rio;
        entered.store(false, .release);
        vt = client.backend.vt.*;
        vt.rescue = rescue;
        vt.prune = prune;
        client.backend.vt = &vt;
    }

    fn prune(_: *anyopaque, _: root.Time, _: root.Options.Keep) anyerror!u32 {
        try io.sleep(.fromMilliseconds(1), .awake);
        return 0;
    }

    fn rescue(_: *anyopaque, _: std.mem.Allocator, _: root.Time) anyerror![]store.Rescued {
        entered.store(true, .release);
        // Far past any test: only the cancel ends it.
        try io.sleep(.fromSeconds(600), .awake);
        return &.{};
    }
};

fn maintenanceCancelCheck(io: std.Io) !void {
    const client = try root.Client.init(gpa, io, .{ .store = .memory });
    HeldRescue.install(client, io);
    try client.start(null, null, null);
    try wait.waitFlag(io, "the maintenance round is in the store's rescue", &HeldRescue.entered);
    // The teardown cancels the maintenance task inside the store call. The
    // cancel must end the task, not be taken for a failed rescue: a round
    // that carries on goes back to the store with its cancel gone, and
    // waits there (zio's debug_cancel fails the test: SwallowedCancel).
    client.deinit();
}

test "jobs: the teardown's cancel inside a maintenance store call ends the maintenance task" {
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try io.concurrent(maintenanceCancelCheck, .{io});
    try f.await(io);
}
