//! Injectable test clock (`anole.testing.Clock`) for deterministic tests of
//! expiry, rate limits, sessions, caches and other time-based logic without
//! sleeping.
//!
//! A `Clock` holds a thread-safe atomic nanosecond counter. `clock.io(inner)`
//! binds it to a `std.Io` whose `now` (every `std.Io.Clock.*.now(io)` and
//! `std.Io.Timestamp.now(io, ...)`) reads the clock, while every other
//! operation (sockets, mutexes, events, sleeps, timers, task scheduling) goes
//! straight to `inner`. Sleeps and timeouts therefore still run on real time.
//!
//! Test builds only (`builtin.is_test`): outside them `unwrapIo` is the
//! identity, so placement on zio pays nothing for it, and `Clock.io` does not
//! compile.
const std = @import("std");
const builtin = @import("builtin");

const max_slots = 32;

/// One bound `Io`: its vtable is the inner one with `now` replaced. A
/// binding finds its slot from the vtable's address (`unwrapIo`).
const Slot = struct {
    /// Non-null claims the slot. Released last in `IoBinding.deinit`.
    clock: std.atomic.Value(?*const Clock) = .init(null),
    /// Bumped by the release, so only the binding that claimed the slot (not
    /// a copy of it, nor a later claim's stale copy) releases it.
    gen: std.atomic.Value(u32) = .init(0),
    inner_vtable: std.atomic.Value(?*const std.Io.VTable) = .init(null),
    vtable: std.Io.VTable = undefined,
};

var slots: [max_slots]Slot = @splat(.{});

const NowFn = *const fn (?*anyopaque, std.Io.Clock) std.Io.Timestamp;

/// `now` of each slot: reads that slot's clock (time zero once released).
const slot_now_fns: [max_slots]NowFn = blk: {
    var fns: [max_slots]NowFn = undefined;
    for (0..max_slots) |i| fns[i] = &struct {
        fn now(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
            const c = slots[i].clock.load(.acquire) orelse return .zero;
            return c.now();
        }
    }.now;
    break :blk fns;
};

fn clampNs(ns: i96) i64 {
    return @intCast(std.math.clamp(ns, std.math.minInt(i64), std.math.maxInt(i64)));
}

/// The `std.Io` under `io` when `Clock.io` wrapped it, else `io`. Keeps
/// `zio.Runtime.fromIo` working through a wrapped `Io`; the identity outside
/// test builds.
pub fn unwrapIo(io: std.Io) std.Io {
    if (comptime !builtin.is_test) return io;
    const addr = @intFromPtr(io.vtable);
    const base = @intFromPtr(&slots);
    if (addr < base or addr >= base + @sizeOf(@TypeOf(slots))) return io;
    const slot = &slots[(addr - base) / @sizeOf(Slot)];
    if (io.vtable != &slot.vtable) return io;
    const vt = slot.inner_vtable.load(.acquire) orelse return io;
    return .{ .userdata = io.userdata, .vtable = vt };
}

/// A deterministic, thread-safe fake clock for tests.
///
///     var clock: anole.testing.Clock = .init(.fromNanoseconds(1_700_000_000 * std.time.ns_per_s));
///     var app = try anole.App.init(std.testing.allocator, .{
///         .executors = .exact(1),
///         .clock = &clock,
///     });
///     defer app.deinit();
///     ...
///     clock.advance(.fromSeconds(60));
pub const Clock = struct {
    /// Simulated time in nanoseconds (atomic so tests can advance while
    /// handler tasks read concurrently).
    ns: std.atomic.Value(i64) = .init(0),

    /// A `std.Io` whose `now` reads a `Clock`, every other operation going
    /// to the inner `std.Io`. Call `deinit` when done; the `Io` from `io()`
    /// is not to be used after that (its `now` reads zero, or another
    /// binding's clock once the slot is reused).
    pub const IoBinding = struct {
        slot: ?usize = null,
        gen: u32 = 0,
        wrapped: std.Io,

        /// The `std.Io` handle to pass to code under test.
        pub fn io(self: IoBinding) std.Io {
            return self.wrapped;
        }

        /// Releases the binding's slot. Safe to call more than once, and on
        /// copies: only the first release of a claim frees the slot.
        pub fn deinit(self: *IoBinding) void {
            const idx = self.slot orelse return;
            self.slot = null;
            const s = &slots[idx];
            if (s.gen.cmpxchgStrong(self.gen, self.gen +% 1, .acq_rel, .acquire) != null) return;
            s.inner_vtable.store(null, .release);
            s.clock.store(null, .release);
        }
    };

    /// A clock starting at `start` (clamped to `i64` nanoseconds).
    pub fn init(start: std.Io.Timestamp) Clock {
        return .{ .ns = .init(clampNs(start.nanoseconds)) };
    }

    /// Current simulated time.
    pub fn now(self: *const Clock) std.Io.Timestamp {
        return .fromNanoseconds(self.ns.load(.acquire));
    }

    /// Moves the clock by `delta` (positive advances, negative rewinds, zero
    /// is a no-op; saturates at `i64` nanosecond bounds).
    pub fn advance(self: *Clock, delta: std.Io.Duration) void {
        if (delta.nanoseconds == 0) return;
        var cur = self.ns.load(.acquire);
        while (true) {
            const next = clampNs(@as(i96, cur) +| delta.nanoseconds);
            cur = self.ns.cmpxchgWeak(cur, next, .acq_rel, .acquire) orelse return;
        }
    }

    /// Sets the clock to `timestamp` (clamped to `i64` nanoseconds).
    pub fn set(self: *Clock, timestamp: std.Io.Timestamp) void {
        self.ns.store(clampNs(timestamp.nanoseconds), .release);
    }

    /// Wraps `inner` so its `now` reads this clock, while all other I/O goes
    /// straight to `inner`. `self` must not move while the binding is live;
    /// call `deinit` on it when done.
    pub fn io(self: *const Clock, inner: std.Io) IoBinding {
        if (comptime !builtin.is_test) @compileError("anole.testing.Clock binds an Io in test builds only");
        const base = unwrapIo(inner);
        for (&slots, 0..) |*s, idx| {
            if (s.clock.cmpxchgStrong(null, self, .acq_rel, .acquire) == null) {
                s.vtable = base.vtable.*;
                s.vtable.now = slot_now_fns[idx];
                s.inner_vtable.store(base.vtable, .release);
                return .{
                    .slot = idx,
                    .gen = s.gen.load(.acquire),
                    .wrapped = .{ .userdata = base.userdata, .vtable = &s.vtable },
                };
            }
        }
        std.debug.panic("anole.testing.Clock: at most {d} active Io bindings at once; call deinit() on finished bindings", .{max_slots});
    }
};

// ------------------------------------------------------------------ tests

fn at(seconds: i64) std.Io.Timestamp {
    return .fromNanoseconds(@as(i96, seconds) * std.time.ns_per_s);
}

test "Clock: init, advance, set, zero, negative and saturation" {
    const Case = struct {
        name: []const u8,
        start_s: i64,
        steps: []const union(enum) {
            advance: std.Io.Duration,
            set: std.Io.Timestamp,
        },
        want_ns: i96,
    };
    const cases = [_]Case{
        .{
            .name = "zero start and zero advance",
            .start_s = 0,
            .steps = &.{.{ .advance = .zero }},
            .want_ns = 0,
        },
        .{
            .name = "multiple positive advances",
            .start_s = 1_700_000_000,
            .steps = &.{
                .{ .advance = .fromSeconds(60) },
                .{ .advance = .fromMilliseconds(500) },
                .{ .advance = .fromMicroseconds(250) },
            },
            .want_ns = @as(i96, 1_700_000_060) * std.time.ns_per_s + 500 * std.time.ns_per_ms + 250 * std.time.ns_per_us,
        },
        .{
            .name = "negative advance rewinds",
            .start_s = 100,
            .steps = &.{.{ .advance = .fromSeconds(-30) }},
            .want_ns = @as(i96, 70) * std.time.ns_per_s,
        },
        .{
            .name = "set overrides, twice",
            .start_s = 50,
            .steps = &.{
                .{ .set = .fromNanoseconds(123_456) },
                .{ .advance = .fromNanoseconds(44) },
                .{ .set = at(42) },
            },
            .want_ns = @as(i96, 42) * std.time.ns_per_s,
        },
        .{
            .name = "set past i64 clamps",
            .start_s = 0,
            .steps = &.{.{ .set = .fromNanoseconds(std.math.maxInt(i96)) }},
            .want_ns = std.math.maxInt(i64),
        },
        .{
            .name = "positive overflow saturates at maxInt(i64)",
            .start_s = 10,
            .steps = &.{.{ .advance = .max }},
            .want_ns = std.math.maxInt(i64),
        },
        .{
            .name = "negative start plus Duration.max saturates at maxInt(i64)",
            .start_s = -10,
            .steps = &.{.{ .advance = .max }},
            .want_ns = std.math.maxInt(i64),
        },
        .{
            .name = "negative overflow saturates at minInt(i64)",
            .start_s = -10,
            .steps = &.{.{ .advance = .fromNanoseconds(std.math.minInt(i64)) }},
            .want_ns = std.math.minInt(i64),
        },
    };
    for (cases) |c| {
        var clock: Clock = .init(at(c.start_s));
        for (c.steps) |s| switch (s) {
            .advance => |d| clock.advance(d),
            .set => |ts| clock.set(ts),
        };
        if (clock.now().nanoseconds != c.want_ns) {
            std.debug.print("case \"{s}\": want {d}, got {d}\n", .{ c.name, c.want_ns, clock.now().nanoseconds });
            return error.TestExpectedEqual;
        }
    }
}

test "Clock.io: real and awake read the clock; unwrapIo restores inner; two clocks coexist; copies release once" {
    var c1: Clock = .init(at(1_700_000_000));
    var c2: Clock = .init(at(2_000_000_000));
    var b1 = c1.io(std.testing.io);
    defer b1.deinit();
    var b2 = c2.io(std.testing.io);
    defer b2.deinit();

    const io1 = b1.io();
    const io2 = b2.io();
    try std.testing.expectEqual(std.testing.io.vtable, unwrapIo(io1).vtable);
    try std.testing.expectEqual(std.testing.io.userdata, unwrapIo(io1).userdata);
    try std.testing.expectEqual(std.testing.io.vtable, unwrapIo(std.testing.io).vtable);

    try std.testing.expectEqual(@as(i64, 1_700_000_000), std.Io.Clock.real.now(io1).toSeconds());
    try std.testing.expectEqual(@as(i64, 1_700_000_000), std.Io.Clock.awake.now(io1).toSeconds());
    try std.testing.expectEqual(@as(i64, 2_000_000_000), std.Io.Clock.real.now(io2).toSeconds());

    c1.advance(.fromSeconds(600));
    try std.testing.expectEqual(@as(i64, 1_700_000_600), std.Io.Clock.real.now(io1).toSeconds());
    try std.testing.expectEqual(@as(i64, 1_700_000_600), std.Io.Timestamp.now(io1, .awake).toSeconds());
    // Advancing c1 does not move c2.
    try std.testing.expectEqual(@as(i64, 2_000_000_000), std.Io.Clock.real.now(io2).toSeconds());

    // Double-wrapping unwraps the inner binding first, so releasing b1 leaves b_nested valid.
    var b_nested = c2.io(io1);
    defer b_nested.deinit();
    try std.testing.expectEqual(std.testing.io.vtable, unwrapIo(b_nested.io()).vtable);

    // Real I/O primitives (mutex, event) still work on the wrapped Io.
    var m: std.Io.Mutex = .init;
    m.lockUncancelable(io1);
    m.unlock(io1);
    var ev: std.Io.Event = .unset;
    ev.set(io1);
    try ev.wait(io1);

    // A copy released after the original, once its slot went to another
    // binding, leaves that binding alone.
    var copy = b1;
    b1.deinit();
    b1.deinit();
    var c3: Clock = .init(at(3_000_000_000));
    var b3 = c3.io(std.testing.io);
    defer b3.deinit();
    copy.deinit();
    try std.testing.expectEqual(@as(i64, 3_000_000_000), std.Io.Clock.real.now(b3.io()).toSeconds());
    try std.testing.expectEqual(std.testing.io.vtable, unwrapIo(b3.io()).vtable);

    try std.testing.expectEqual(@as(i64, 2_000_000_000), std.Io.Clock.real.now(b_nested.io()).toSeconds());
    c2.advance(.fromSeconds(15));
    try std.testing.expectEqual(@as(i64, 2_000_000_015), std.Io.Clock.real.now(b_nested.io()).toSeconds());
}

test "Clock: concurrent advances and reads are race-free and exact" {
    var clock: Clock = .{};
    const workers = 4;
    const steps_per_worker = 500;
    const Runner = struct {
        fn run(c: *Clock) void {
            for (0..steps_per_worker) |_| {
                c.advance(.fromMilliseconds(1));
                _ = c.now();
            }
        }
    };
    var threads: [workers]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Runner.run, .{&clock});
    for (&threads) |*t| t.join();
    try std.testing.expectEqual(@as(i64, workers * steps_per_worker), clock.now().toMilliseconds());
}
