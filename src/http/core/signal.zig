// Moved here from src/h3/bridge.zig (Anole's HTTP/3 bridge, 0.2.1), so the
// HTTP/2 engine and HTTP/3 share one.

//! A wait point with a sleeper count, so a notify nobody waits for costs one
//! atomic add and one load (no futex bucket lock). The waiter reads `epoch`
//! before it checks the state the signal guards, and waits with that epoch:
//! a notify in between moves the epoch, and the wait returns at once.
//! `gen` is bumped before `sleepers` is read, and a sleeper counts itself
//! before its futex wait checks `gen` (both seq_cst), so a notify either
//! sees the sleeper or the sleeper sees the new `gen` (Dekker).
const std = @import("std");
const builtin = @import("builtin");

pub const Signal = struct {
    gen: std.atomic.Value(u32) = .init(0),
    sleepers: std.atomic.Value(u32) = .init(0),
    /// Test builds: how many waits returned.
    returns: std.atomic.Value(u32) = .init(0),
    /// Test builds: futex wake calls made.
    wakes: std.atomic.Value(u32) = .init(0),

    /// Read this BEFORE checking the state it guards.
    pub fn epoch(s: *const Signal) u32 {
        return s.gen.load(.acquire);
    }

    /// Sleeps until `notify` after `seen`.
    pub fn wait(s: *Signal, io: std.Io, seen: u32) std.Io.Cancelable!void {
        _ = s.sleepers.fetchAdd(1, .seq_cst);
        defer {
            _ = s.sleepers.fetchSub(1, .seq_cst);
            if (builtin.is_test) _ = s.returns.fetchAdd(1, .monotonic);
        }
        try io.futexWait(u32, &s.gen.raw, seen);
    }

    /// `wait`, giving up at `timeout` (returns normally then too).
    pub fn waitTimeout(s: *Signal, io: std.Io, seen: u32, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        _ = s.sleepers.fetchAdd(1, .seq_cst);
        defer {
            _ = s.sleepers.fetchSub(1, .seq_cst);
            if (builtin.is_test) _ = s.returns.fetchAdd(1, .monotonic);
        }
        try io.futexWaitTimeout(u32, &s.gen.raw, seen, timeout);
    }

    pub fn notify(s: *Signal, io: std.Io) void {
        _ = s.gen.fetchAdd(1, .seq_cst);
        if (s.sleepers.load(.seq_cst) > 0) {
            if (builtin.is_test) _ = s.wakes.fetchAdd(1, .monotonic);
            io.futexWake(u32, &s.gen.raw, std.math.maxInt(u32));
        }
    }
};

test "signal: a notify between epoch and wait makes wait return at once; no sleepers, no futex call" {
    var s: Signal = .{};
    const seen = s.epoch();
    // Nobody sleeps, so notify makes no wake call: an undefined Io would
    // crash on one.
    var no_io: std.Io = undefined;
    _ = &no_io;
    s.notify(no_io);
    try std.testing.expect(s.epoch() != seen);
    // The epoch moved, so wait returns without sleeping (it would block
    // here forever otherwise: nothing else notifies).
    try s.wait(std.testing.io, seen);
}
