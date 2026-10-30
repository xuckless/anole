//! SAFETY.md T5: a thread that may outlive the runtime (a C ABI consumer,
//! an application thread) wakes runtime tasks only through an `IoGate`.
//!
//! Guards the runtime's wakes made from threads that are not the runtime's
//! (a consumer's answer, a send, a poll): the side that ends the runtime
//! (or the task the wakes are for) closes it before it frees what the wakes
//! touch and waits for the wakes under way, and a wake after that is
//! skipped (the runtime's tasks are canceled as it ends, so nothing waits
//! for it). The `ctl` scheme, for the hot path: one word, on the line the
//! guarded object already shares with its foreign callers. Moved from
//! src/capi/engine.zig (S1.5 retrofit, research/s15/retrofit-1-s3.md §4.0)
//! so the raw TCP/UDP drivers use the same gate.
const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");

pub const IoGate = struct {
    word: std.atomic.Value(u32) = .init(0),

    const closed: u32 = 1 << 31;

    /// A compare-and-swap that never counts a wake once the gate is
    /// closed (libuv's `uv_async_send` has the same shape), so a stream of
    /// late wakes can't keep `close` waiting.
    pub fn enter(g: *IoGate) bool {
        var cur = g.word.load(.monotonic);
        while (true) {
            if (cur & closed != 0) return false;
            cur = g.word.cmpxchgWeak(cur, cur + 1, .acquire, .monotonic) orelse break;
        }
        if (comptime builtin.is_test) if (root.io_gate_test_hook) |f| f();
        return true;
    }

    pub fn leave(g: *IoGate) void {
        _ = g.word.fetchSub(1, .release);
    }

    /// Before what the wakes touch goes: no wake enters from now on, and
    /// those inside have left when this returns. What runs inside never
    /// waits: mostly a wake, a few instructions; at most a short call that
    /// may allocate (the C ABI's UDP send queues a batch inside its
    /// listener's gate, `capi/net.zig` `UdpState`).
    pub fn close(g: *IoGate) void {
        _ = g.word.fetchOr(closed, .acq_rel);
        // Spin first, then yield, as libuv's `uv__async_spin` does: a wake
        // in flight is done within a few hundred cycles unless its thread
        // was preempted (or allocating, past the spins: then it yields).
        var spins: u32 = 0;
        while (g.word.load(.acquire) & ~closed != 0) {
            if (spins < 1000) {
                spins += 1;
                std.atomic.spinLoopHint();
            } else std.Thread.yield() catch {};
        }
    }

    /// Closed: no wake gets in any more.
    pub fn isClosed(g: *const IoGate) bool {
        return g.word.load(.acquire) & closed != 0;
    }

    pub fn setEvent(g: *IoGate, io: std.Io, ev: *std.Io.Event) void {
        if (!g.enter()) return;
        defer g.leave();
        ev.set(io);
    }

    pub fn wakeFutex(g: *IoGate, io: std.Io, word: *const std.atomic.Value(u32)) void {
        if (!g.enter()) return;
        defer g.leave();
        io.futexWake(u32, &word.raw, std.math.maxInt(u32));
    }
};

test "io_gate: a closed gate lets no wake in, and close waits for the one inside" {
    var g: IoGate = .{};
    try std.testing.expect(g.enter());
    const Closer = struct {
        fn run(gate: *IoGate, done: *std.atomic.Value(bool)) void {
            gate.close();
            done.store(true, .release);
        }
    };
    var done: std.atomic.Value(bool) = .init(false);
    const t = try std.Thread.spawn(.{}, Closer.run, .{ &g, &done });
    // Closing: new wakes are refused while the one inside holds it open.
    while (!g.isClosed()) std.Thread.yield() catch {};
    try std.testing.expect(!g.enter());
    try std.testing.expect(!done.load(.acquire));
    g.leave();
    t.join();
    try std.testing.expect(done.load(.acquire));
    try std.testing.expect(!g.enter());
}
