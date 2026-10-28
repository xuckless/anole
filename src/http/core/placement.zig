// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

//! Where the server's tasks run.
//!
//! On zio with several executors, `std.Io`'s `concurrent` places each new
//! task on the next executor round-robin, so a connection's helper tasks (the
//! HTTP/2 writer and stream tasks) would run on other OS threads than the
//! connection itself. With these, accept loops spread one per executor, and a
//! connection and everything it spawns stay on the executor that accepted it:
//! nothing of one connection crosses threads, and its locks are uncontended.
//!
//! Elsewhere -- the core's zio stub, a zio without placement, `std.Io.Threaded`,
//! or zio's work-stealing scheduling, where pinning a task is invalid -- this
//! is plain `concurrent`.
//!
//! It also lets one task cancel another single task of a group (`Task`),
//! which `std.Io` has no call for: groups are canceled as a whole.
const std = @import("std");
const test_wait = @import("anole_test_wait");
const zio = @import("zio");

/// The core's own tests build against a stub of zio.
pub const is_stub = @hasDecl(zio, "is_stub");

// Anole always builds against xuckless/zio, branch `anole`. A zio without the
// fork's declarations would silently lose placement, parking, task cancel and
// per-executor pools, so it is a compile error.
comptime {
    if (!is_stub) {
        const why = " (Anole needs xuckless/zio branch `anole`, pinned in build.zig.zon; see MAINTAINING.md)";
        for (.{ "Placement", "Group", "AutoCancel", "currentTask", "Event", "Runtime" }) |name|
            if (!@hasDecl(zio, name)) @compileError("this zio has no `zio." ++ name ++ "`" ++ why);
        if (!@hasDecl(zio.Runtime, "fromIo")) @compileError("this zio has no `zio.Runtime.fromIo`" ++ why);
        if (!@hasDecl(zio.Runtime, "currentExecutor")) @compileError("this zio has no `zio.Runtime.currentExecutor`" ++ why);
        if (!@hasField(zio.Runtime, "executors")) @compileError("this zio's Runtime has no `executors`" ++ why);
        if (!@hasDecl(zio.Group, "spawnInto")) @compileError("this zio has no `zio.Group.spawnInto`" ++ why);
        if (!@hasField(zio.AutoCancel, "task")) @compileError("this zio's AutoCancel has no `task`" ++ why);
        if (@import("builtin").os.tag != .windows) {
            if (!@hasDecl(zio, "CompletionQueue")) @compileError("this zio has no `zio.CompletionQueue`" ++ why);
            if (!@hasDecl(zio, "ev") or !@hasDecl(zio.ev, "NetPoll") or !@hasDecl(zio.ev, "Async"))
                @compileError("this zio has no `zio.ev.NetPoll`/`Async`" ++ why);
        }
    }
}

/// A zio with the placement API.
const have_zio = !is_stub;

pub const Where = union(enum) {
    /// The executor of the calling task.
    local,
    /// The executor with this index, modulo the executor count.
    executor: usize,
};

/// `group.concurrent(io, func, args)`, placed as `where` says when the `Io`
/// is zio's and placement applies.
pub fn concurrent(
    group: *std.Io.Group,
    io: std.Io,
    where: Where,
    func: anytype,
    args: std.meta.ArgsTuple(@TypeOf(func)),
) std.Io.ConcurrentError!void {
    if (comptime have_zio) {
        if (zio.Runtime.fromIo(io)) |rt| {
            const placement: zio.Placement = switch (where) {
                .local => .local,
                .executor => |i| .{ .executor = @intCast(i % rt.executors.items.len) },
            };
            if (zio.Group.fromStd(group).spawnInto(placement, func, args)) |_| {
                return;
            } else |err| switch (err) {
                // Work-stealing scheduling: tasks migrate, so let it pick.
                error.InvalidPlacement => {},
                else => return error.ConcurrencyUnavailable,
            }
        }
    }
    // Spawning is not a cancelation point, yet under std.Io.Threaded it can
    // swallow a cancel: a Debug allocator captures a stack trace for the new
    // task, and Zig 0.17's unwinder takes a cancelable lock
    // (`std.debug.SelfInfo`'s module mutex, through `std.Options.debug_io`).
    // Threaded keeps cancel state per OS thread, whichever instance asks, so
    // when that lock is contended it acknowledges the cancel pending on the
    // spawning task and the unwinder drops the error. Every later syscall of
    // that task then runs uncancelable, and its next blocking wait (an
    // accept, an event) blocks the shutdown for good. Blocked here, the
    // cancel stays pending for that wait.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    return group.concurrent(io, func, args);
}

/// The index of the executor the calling task runs on, the one `.executor`
/// takes: for work started elsewhere (a drain, say) that belongs on a
/// connection's executor, or for state kept per executor (`anole.db`'s
/// pools). Null off zio, or off an executor of `io`'s runtime (a thread of
/// its blocking pool, say).
pub fn currentExecutor(io: std.Io) ?usize {
    if (comptime !have_zio) return null;
    const rt = zio.Runtime.fromIo(io) orelse return null;
    return rt.currentExecutor() orelse null;
}

/// How many executors accept loops can be spread over, or null when
/// placement does not apply (not zio).
pub fn executorCount(io: std.Io) ?usize {
    if (comptime !have_zio) return null;
    const rt = zio.Runtime.fromIo(io) orelse return null;
    return rt.executors.items.len;
}

/// zio can cancel one task: the type behind the task an `AutoCancel` arms
/// against has a non-blocking `cancel`.
const have_task_cancel = !is_stub;

/// A running task that another task can cancel by itself, without its
/// group. Void where that is not possible (not zio): `currentTask` returns
/// null.
pub const Task = if (have_task_cancel) @typeInfo(@FieldType(zio.AutoCancel, "task")).optional.child else void;

/// The calling task, or null when it cannot be canceled alone. The handle
/// is valid while the task runs: whoever cancels it must know it has not
/// returned yet (in practice, under a lock the task takes before it ends).
pub fn currentTask(io: std.Io) ?Task {
    if (comptime !have_task_cancel) return null;
    if (zio.Runtime.fromIo(io) == null) return null;
    return zio.currentTask();
}

/// Asks `task` to stop: its next cancelable wait (or the one it is in)
/// returns `error.Canceled`. Does not wait for it; safe from any thread.
pub fn cancelTask(task: Task) void {
    if (comptime have_task_cancel) task.cancel();
}

/// zio's executors record the task each one runs.
const have_current_task = !is_stub;

/// A number that tells the calling task from any other task running at the
/// same time, never 0: who is asking, when a WebSocket decides whether a
/// send comes from the task that reads it. On zio, the running task; off
/// it (`std.Io.Threaded`, a thread of zio's blocking pool), the OS thread,
/// which is the task there.
pub fn taskId(io: std.Io) usize {
    if (comptime have_current_task) {
        if (zio.Runtime.fromIo(io)) |rt| {
            if (rt.currentExecutor()) |id| {
                if (rt.executors.items[id].current_task) |task| return @intFromPtr(task);
            }
        }
    }
    // Thread IDs are small numbers on both Linux and macOS, and task
    // addresses are not; the top bit keeps the two apart regardless.
    return @as(usize, @intCast(std.Thread.getCurrentId())) | (@as(usize, 1) << (@bitSizeOf(usize) - 1));
}

test "taskId: the same task gets the same answer, another task another" {
    const io = std.testing.io;
    const mine = taskId(io);
    try std.testing.expect(mine != 0);
    try std.testing.expectEqual(mine, taskId(io));
    var other = try io.concurrent(struct {
        fn run(i: std.Io) usize {
            return taskId(i);
        }
    }.run, .{io});
    try std.testing.expect(other.await(io) != mine);
}

const have_zio_event = !is_stub;

/// A flag one task waits on and others set, like `std.Io.Event`. On zio it
/// is zio's own event, which keeps its waiter inline: `std.Io.Event`'s
/// futex goes through zio's shared wait table, and a task woken once per
/// batch of WebSocket messages makes the difference show.
pub const Signal = struct {
    std_event: std.Io.Event = .unset,
    zio_event: if (have_zio_event) zio.Event else void = if (have_zio_event) .init else {},

    pub fn set(self: *Signal, io: std.Io) void {
        if (comptime have_zio_event) if (zio.Runtime.fromIo(io) != null) return self.zio_event.set();
        self.std_event.set(io);
    }

    /// Only by the waiting task, after its wait returned.
    pub fn reset(self: *Signal, io: std.Io) void {
        if (comptime have_zio_event) if (zio.Runtime.fromIo(io) != null) return self.zio_event.reset();
        self.std_event.reset();
    }

    pub fn wait(self: *Signal, io: std.Io) std.Io.Cancelable!void {
        if (comptime have_zio_event) if (zio.Runtime.fromIo(io) != null) return self.zio_event.wait() catch |err| switch (err) {
            error.Canceled => error.Canceled,
        };
        return self.std_event.wait(io);
    }
};

test "Signal: a set wakes the waiter, and a reset makes it wait again" {
    const io = std.testing.io;
    var signal: Signal = .{};
    var woke: std.atomic.Value(u32) = .init(0);
    var waiter = try io.concurrent(struct {
        fn run(s: *Signal, i: std.Io, n: *std.atomic.Value(u32)) std.Io.Cancelable!void {
            while (true) {
                try s.wait(i);
                s.reset(i);
                _ = n.fetchAdd(1, .release);
            }
        }
    }.run, .{ &signal, io, &woke });
    signal.set(io);
    try test_wait.waitAtLeast(io, "the waiter woke once", &woke, 1);
    signal.set(io);
    try test_wait.waitAtLeast(io, "the waiter woke again", &woke, 2);
    try std.testing.expectError(error.Canceled, waiter.cancel(io));
}
