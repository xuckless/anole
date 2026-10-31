//! Test points of the Kafka client (test builds only): where a test stops a
//! task or a thread to force an interleaving the scheduler makes only
//! sometimes (TESTING.md D5, SAFETY.md §8 step 4). Outside test builds
//! `testHold` is empty and `test_hold` is void.
//!
//! The shape of the raw TCP driver's holds (src/net/tcp.zig), kept local to
//! src/kafka/ until both move into one shared helper.
const std = @import("std");
const builtin = @import("builtin");
const dusty = @import("dusty");

const Duration = std.Io.Duration;

pub const TestPoint = enum {
    /// Right after a sender task was spawned: where zio's spawn backpressure
    /// (`registerTask` -> `yieldForRound`) can suspend the spawner.
    sender_spawned,
    /// Right after the producer id was reset for a broker's refusal.
    pid_reset,
    /// A sender, before its Produce round trip.
    send_request,
    /// A sender, between taking the producer id and numbering its batches.
    ids_taken,
    /// A broker connection's round trip, its request written, before the
    /// answer is read.
    request_written,
    /// Right after a consumer member task was spawned (the same yield as
    /// `sender_spawned`).
    member_spawned,
    /// A sender that met a stale leader, its batches handed back, before it
    /// starts the resolver.
    stale_settled,
    /// The same sender, right after that start returned.
    resolver_started,
    /// `Client.drain`, `drained` set, before it waits for the consumer
    /// starts in flight (no lock held).
    drain_waits,
    /// `partitionCountWait` and `partitionCount`, between a refresh and the
    /// look at the cache.
    metadata_refreshed,
};

/// One stop: armed through `test_hold`, taken once by the first caller at
/// `point`, which sets `held` and waits until the test calls `let`. A task
/// waits on the futex (other tasks of its executor run meanwhile); a thread
/// yields. Past `limit` it panics: a hang check, not an ordering.
pub const TestHold = struct {
    point: TestPoint,
    held: std.atomic.Value(bool) = .init(false),
    released: std.atomic.Value(u32) = .init(0),
    limit: Duration = .fromSeconds(30),
    /// The held task first waits cancelably until it is canceled, notes it
    /// in `canceled` and re-arms the cancel (`recancel`), then stays as
    /// usual: a test learns that the cancel is pending.
    until_canceled: bool = false,
    canceled: std.atomic.Value(bool) = .init(false),

    /// Lets the held caller go (any task or thread of the runtime of `io`).
    pub fn let(h: *TestHold, io: std.Io) void {
        h.released.store(1, .release);
        io.futexWake(u32, &h.released.raw, 1);
    }

    /// Arms the hold: the next caller at `point` stops there.
    pub fn arm(h: *TestHold) void {
        if (comptime builtin.is_test) test_hold.store(h, .release);
    }

    fn stay(h: *TestHold, io: std.Io) void {
        h.held.store(true, .release);
        const start = std.Io.Clock.awake.now(io);
        const on_task = dusty.placement.currentExecutor(io) != null;
        if (h.until_canceled and on_task) while (h.released.load(.acquire) == 0) {
            if (start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds > h.limit.nanoseconds) {
                std.debug.panic("kafka test hold at {t}: never canceled", .{h.point});
            }
            io.futexWaitTimeout(u32, &h.released.raw, 0, .{ .duration = .{ .raw = h.limit, .clock = .awake } }) catch |err| switch (err) {
                error.Canceled => {
                    io.recancel();
                    h.canceled.store(true, .release);
                    break;
                },
            };
        };
        // A cancel stays pending until the hold is let go (the held caller
        // goes on as it would have, and meets it at its next wait).
        const prev = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(prev);
        while (h.released.load(.acquire) == 0) {
            if (start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds > h.limit.nanoseconds) {
                std.debug.panic("kafka test hold at {t}: never let go", .{h.point});
            }
            if (on_task) {
                io.futexWaitTimeout(u32, &h.released.raw, 0, .{ .duration = .{ .raw = h.limit, .clock = .awake } }) catch {};
            } else {
                std.Thread.yield() catch {};
            }
        }
    }
};

pub var test_hold: if (builtin.is_test) std.atomic.Value(?*TestHold) else void = if (builtin.is_test) .init(null) else {};

/// Stops the caller at `point` when a test armed a hold there; nothing
/// outside test builds.
pub fn testHold(io: std.Io, comptime point: TestPoint) void {
    if (comptime !builtin.is_test) return;
    const h = test_hold.load(.acquire) orelse return;
    if (h.point != point) return;
    if (test_hold.cmpxchgStrong(h, null, .acq_rel, .monotonic) != null) return;
    h.stay(io);
}
