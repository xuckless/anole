//! `PerExecutor` (src/http/core/exec_counter.zig) on the real zio, with
//! tasks on every executor and threads that are not executors adding at
//! once: part of anole's suite (the core's own tests run on its stub zio).
const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");
const wait = @import("anole_test_wait");
const Counter = dusty.exec_counter.PerExecutor(i64);
const placement = dusty.placement;

const Load = struct {
    executors: u6,
    tasks_per_executor: u32,
    threads: u32,
    /// Each task and thread adds 1 this many times and takes 1 away
    /// `takes` times.
    adds: u32,
    takes: u32,
};

const Run = struct {
    counter: Counter = .init,
    io: std.Io,
    load: Load,
    /// Sums read while the adds run that fall below 0 or above all that can
    /// have been added.
    bad_sums: std.atomic.Value(u32) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),

    fn task(r: *Run) std.Io.Cancelable!void {
        for (0..r.load.adds) |i| {
            r.counter.add(r.io, 1);
            if (i < r.load.takes) r.counter.add(r.io, -1);
            if (i % 64 == 63) try zio.yield();
        }
    }

    fn thread(r: *Run) void {
        for (0..r.load.adds) |i| {
            r.counter.add(r.io, 1);
            if (i < r.load.takes) r.counter.add(r.io, -1);
        }
    }

    /// A reader of the sum while everything adds, as `/metrics` is.
    fn reader(r: *Run) void {
        const most: i64 = @as(i64, r.load.adds) * (@as(i64, r.load.executors) * r.load.tasks_per_executor + r.load.threads);
        while (!r.stop.load(.acquire)) {
            const s = r.counter.sum();
            if (s > most or s < 0) _ = r.bad_sums.fetchAdd(1, .monotonic);
            std.atomic.spinLoopHint();
        }
    }
};

fn addEverywhere(load: Load) !void {
    const rt = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(load.executors) });
    defer rt.deinit();
    const io = rt.io();
    var r: Run = .{ .io = io, .load = load };
    {
        var threads: [8]std.Thread = undefined;
        var started: usize = 0;
        const sum_reader = try std.Thread.spawn(.{}, Run.reader, .{&r});
        defer {
            for (threads[0..started]) |t| t.join();
            r.stop.store(true, .release);
            sum_reader.join();
        }
        for (threads[0..load.threads]) |*t| {
            t.* = try std.Thread.spawn(.{}, Run.thread, .{&r});
            started += 1;
        }
        var group: std.Io.Group = .init;
        defer group.cancel(io);
        for (0..load.executors) |e| {
            for (0..load.tasks_per_executor) |_| try placement.concurrent(&group, io, .{ .executor = e }, Run.task, .{&r});
        }
        try group.await(io);
    }
    const each: i64 = @as(i64, load.adds) - load.takes;
    // Each executor's adds landed in its own slot, the threads' in the
    // foreign one, and the sum is exact once they are all done.
    for (0..load.executors) |e| try std.testing.expectEqual(each * load.tasks_per_executor, r.counter.get(e));
    try std.testing.expectEqual(each * load.threads, r.counter.getForeign());
    try std.testing.expectEqual(each * (@as(i64, load.executors) * load.tasks_per_executor + load.threads), r.counter.sum());
    try std.testing.expectEqual(@as(u32, 0), r.bad_sums.load(.acquire));
}

test "PerExecutor: adds from every executor and from other threads at once all count, each in its own slot" {
    try addEverywhere(.{ .executors = 4, .tasks_per_executor = 4, .threads = 2, .adds = 1000, .takes = 300 });
}

test "PerExecutor: adds from every executor and from other threads at once all count, each in its own slot [stress]" {
    try wait.requireStress();
    try addEverywhere(.{ .executors = 8, .tasks_per_executor = 64, .threads = 8, .adds = 100_000, .takes = 40_000 });
}
