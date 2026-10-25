//! The drain against runs that have finished: what a job's handler did is
//! saved, whatever the drain's cancel reaches (#108).
const std = @import("std");
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

fn waitFor(io: std.Io, comptime cond: anytype, args: anytype) error{TimedOut}!void {
    for (0..5000) |_| {
        if (@call(.auto, cond, args)) return;
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    return error.TimedOut;
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
    var runs: std.atomic.Value(u32) = .init(0);

    fn run(_: ?*anyopaque, job: *root.Job) anyerror!void {
        _ = runs.fetchAdd(1, .acq_rel);
        // The work is done. Now the drain, past its deadline.
        drain_task = try io.concurrent(drainNow, .{ client, io });
        for (0..5000) |_| {
            if (job.interrupted_flag.?.load(.acquire)) break;
            io.sleep(.fromMilliseconds(1), .awake) catch {};
        } else return error.NeverInterrupted;
    }
};

fn lateDrainCheck(io: std.Io) !void {
    const client = try root.Client.init(gpa, io, .{ .store = .memory });
    defer client.deinit();
    LateDrain.io = io;
    LateDrain.client = client;
    LateDrain.drain_task = null;
    LateDrain.runs.store(0, .release);
    try client.addHandler(kind, null, LateDrain.run);
    try client.start(null, null, null);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var ctx: anole.db.Ctx = .{ .io = io, .arena = arena.allocator() };
    const e = try client.enqueueRaw(&ctx, kind.name, "{}", .{});
    for (0..5000) |_| {
        if (LateDrain.drain_task != null) break;
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    } else return error.NeverRan;
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
