// Adapted from vkiryakov/zefir src/nats/engine/Broadcast.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! Wakes every task that waits on it, however many there are: a condition
//! for "something changed, look again", where every waiter must look, such
//! as the flushes waiting for PONG. `Io.Condition` keeps its count of
//! waiters in 16 bits and asserts it stays below 65,535; the waiters here
//! can be more. Where only one waiter can go on, wake one instead, as the
//! outbound queue's line of puts does.
//!
//! Both calls need the caller's mutex held; `wait` releases it while
//! asleep. A wait may end for no reason, or a little before its deadline,
//! so the caller checks its condition and its deadline in a loop.

const std = @import("std");
const Io = std.Io;
const time = @import("time.zig");
const Broadcast = @This();

/// Changes on every wake; a sleeper waits for it to change.
epoch: std.atomic.Value(u32) = .init(0),
/// Tasks in `wait`; a wake without any costs nothing.
waiters: u32 = 0,

/// Releases `mutex`, sleeps until `wake`, the deadline or a spurious
/// wakeup, and takes `mutex` back, also when canceled.
pub fn wait(b: *Broadcast, io: Io, mutex: *Io.Mutex, deadline: ?Io.Clock.Timestamp) Io.Cancelable!void {
    // Read under the mutex: a wake after the caller's last look changes it.
    const epoch = b.epoch.load(.monotonic);
    b.waiters += 1;
    mutex.unlock(io);
    defer {
        mutex.lockUncancelable(io);
        b.waiters -= 1;
    }
    try io.futexWaitTimeout(u32, &b.epoch.raw, epoch, time.until(deadline));
}

/// Wakes every task in `wait`; call it after changing what they wait for.
pub fn wake(b: *Broadcast, io: Io) void {
    if (b.waiters == 0) return;
    _ = b.epoch.fetchAdd(1, .release);
    io.futexWake(u32, &b.epoch.raw, std.math.maxInt(u32));
}

const testing = std.testing;

/// A flag behind a mutex, and tasks that wait for it.
const Gate = struct {
    mutex: Io.Mutex = .init,
    changed: Broadcast = .{},
    open: bool = false,
    passed: u32 = 0,

    fn pass(gate: *Gate, io: Io) Io.Cancelable!void {
        try gate.mutex.lock(io);
        defer gate.mutex.unlock(io);
        while (!gate.open) try gate.changed.wait(io, &gate.mutex, null);
        gate.passed += 1;
    }

    fn openUp(gate: *Gate, io: Io) void {
        gate.mutex.lockUncancelable(io);
        defer gate.mutex.unlock(io);
        gate.open = true;
        gate.changed.wake(io);
    }

    fn waiting(gate: *Gate, io: Io) u32 {
        gate.mutex.lockUncancelable(io);
        defer gate.mutex.unlock(io);
        return gate.changed.waiters;
    }
};

/// Waits until `count` tasks wait at `gate`, for 5 s at most.
fn awaitWaiters(io: Io, gate: *Gate, count: u32) !void {
    const give_up = time.after(io, .fromSeconds(5));
    while (gate.waiting(io) < count) {
        if (time.expired(io, give_up)) return error.TestWaitersNeverCame;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "one wake reaches every waiter" {
    const io = testing.io;
    var gate: Gate = .{};
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (0..8) |_| try group.concurrent(io, Gate.pass, .{ &gate, io });
    try awaitWaiters(io, &gate, 8);
    gate.openUp(io);
    try group.await(io);
    try testing.expectEqual(8, gate.passed);
    try testing.expectEqual(0, gate.waiting(io));
}

test "a wait ends by its deadline" {
    const io = testing.io;
    var mutex: Io.Mutex = .init;
    var changed: Broadcast = .{};
    const start = Io.Clock.awake.now(io);
    const deadline = time.after(io, .fromMilliseconds(20));
    try mutex.lock(io);
    defer mutex.unlock(io);
    // Nothing wakes it: the loop ends at the deadline.
    while (!time.expired(io, deadline)) try changed.wait(io, &mutex, deadline);
    try testing.expect(start.durationTo(Io.Clock.awake.now(io)).toMilliseconds() >= 20);
    try testing.expectEqual(0, changed.waiters);
}

test "a canceled waiter returns Canceled and holds the mutex again" {
    const io = testing.io;
    var gate: Gate = .{};
    var waiter = try io.concurrent(Gate.pass, .{ &gate, io });
    defer waiter.cancel(io) catch {};
    try awaitWaiters(io, &gate, 1);
    try testing.expectError(error.Canceled, waiter.cancel(io));
    // Gate.pass unlocked the mutex on its way out: it is free now.
    try testing.expect(gate.mutex.tryLock());
    gate.mutex.unlock(io);
    try testing.expectEqual(0, gate.waiting(io));
}
