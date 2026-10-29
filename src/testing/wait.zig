//! Waiting in tests for something to happen, or for something never to
//! happen, without assuming the machine is fast (TESTING.md D1, D2, D6).
//!
//! `waitUntil` polls a condition until it holds or a generous deadline
//! passes: 10 s, times `ANOLE_TEST_TIMEOUT_FACTOR` (an integer from the
//! environment, default 1; raise it under sanitizers or on a crowded
//! machine). The deadline is a hang guard, never a latency bound: a test
//! that passes only because something happened quickly is wrong (D6). Such
//! bounds are checked only `if (timing())`, which `zig build test-timing`
//! (local, never CI) turns on by running the same test binaries with
//! `ANOLE_TEST_TIMING=1`; a test whose whole claim is speed calls
//! `requireTiming`.
//!
//! `expectStays` checks that a condition keeps holding for a short window,
//! for claims of the form "X never happens" (gRPC-go's
//! `defaultTestShortTimeout`, 100 ms). Such a check can only miss a bug on
//! a slow machine, never fail a correct program.
//!
//! `waitEvent` waits on a `std.Io.Event` with the same deadline, in place
//! of a bare `event.wait(io)` that hangs the binary when nothing sets it.
//!
//! Prefer an event or a counter of the code under test over polling where
//! one exists; polling is the fallback (Envoy's `waitForCounter`). Prior
//! art: gRPC-go `test/timeouts.go` (10 s default), Envoy
//! `TestUtility::DefaultTimeout` scaled by `TIMEOUT_FACTOR`, Kubernetes
//! `ForeverTestTimeout`.
//!
//! The import is `anole_test_wait` in every test binary (build.zig).

const std = @import("std");
const builtin = @import("builtin");

// At warn, not err: the wait's error already fails the test, and a test
// that expects a timeout must not fail on the log line.
const log = std.log.scoped(.anole_test);

/// `zig build test-timing` (`ANOLE_TEST_TIMING=1` in the environment, read
/// once): tests that measure speed or bound elapsed time run only there
/// (local, never in CI; TESTING.md D6). One test binary serves both runs,
/// so the HTTP core and anole, which share this module, agree.
pub fn timing() bool {
    const cached = timing_cache.load(.monotonic);
    if (cached != 0) return cached == 2;
    const on = parseTiming(readEnv("ANOLE_TEST_TIMING"));
    timing_cache.store(if (on) 2 else 1, .monotonic);
    return on;
}

var timing_cache: std.atomic.Value(u8) = .init(0);

fn parseTiming(text: ?[]const u8) bool {
    const t = std.mem.trim(u8, text orelse return false, " \t\r\n");
    return t.len > 0 and !std.mem.eql(u8, t, "0");
}

/// The default deadline before the factor, as in gRPC-go and Envoy.
pub const default_deadline_s = 10;

/// The default window of `expectStays`, as gRPC-go's short timeout.
pub const short_window: std.Io.Duration = .fromMilliseconds(100);

pub const WaitError = error{WaitTimedOut} || std.Io.Cancelable;
pub const StayError = error{ConditionChanged} || std.Io.Cancelable;

const first_backoff_ns: i96 = std.time.ns_per_ms;
const max_backoff_ns: i96 = 50 * std.time.ns_per_ms;

/// Skips the calling test unless it is built for `zig build test-timing`.
/// Call it first in a test whose whole claim is about speed, and name the
/// test with " [timing]". A test with a logical claim and an elapsed-time
/// bound beside it checks the bound only `if (wait.timing())`.
pub fn requireTiming() error{SkipZigTest}!void {
    if (!timing()) return error.SkipZigTest;
}

/// `zig build test-stress` (`ANOLE_TEST_STRESS=1` in the environment, read
/// once): stress and load tests (TESTING.md W3: never part of the unit
/// suite) run only there. A stress test calls `requireStress` first and
/// is named with " [stress]". Its claim holds on any machine; it is kept
/// out of `zig build test` for its cost, not for timing (K1).
pub fn stress() bool {
    const cached = stress_cache.load(.monotonic);
    if (cached != 0) return cached == 2;
    const on = parseTiming(readEnv("ANOLE_TEST_STRESS"));
    stress_cache.store(if (on) 2 else 1, .monotonic);
    return on;
}

var stress_cache: std.atomic.Value(u8) = .init(0);

/// Skips the calling test unless it is built for `zig build test-stress`.
pub fn requireStress() error{SkipZigTest}!void {
    if (!stress()) return error.SkipZigTest;
}

var factor_cache: std.atomic.Value(u32) = .init(0);

/// `ANOLE_TEST_TIMEOUT_FACTOR` (a whole number >= 1), read once; 1 when
/// unset, malformed or unreadable (no libc).
pub fn timeoutFactor() u32 {
    const cached = factor_cache.load(.monotonic);
    if (cached != 0) return cached;
    const f = parseFactor(readEnv("ANOLE_TEST_TIMEOUT_FACTOR"));
    factor_cache.store(f, .monotonic);
    return f;
}

fn readEnv(comptime name: [:0]const u8) ?[]const u8 {
    if (comptime !builtin.link_libc) return null;
    const v = std.c.getenv(name) orelse return null;
    return std.mem.span(v);
}

fn parseFactor(text: ?[]const u8) u32 {
    const t = text orelse return 1;
    const n = std.fmt.parseInt(u32, std.mem.trim(u8, t, " \t\r\n"), 10) catch return 1;
    return @max(n, 1);
}

/// The deadline every wait uses: 10 s times the factor.
pub fn deadline() std.Io.Duration {
    return .fromSeconds(@as(i64, default_deadline_s) * timeoutFactor());
}

/// `deadline()` in milliseconds, for an API that takes a timeout in them
/// (a stop's wait, a poll).
pub fn deadlineMs() u32 {
    return @intCast(@min(deadline().toMilliseconds(), std.math.maxInt(i32)));
}

/// Waits until `cond(ctx)` holds, polling with a back-off from 1 ms to
/// 50 ms, for `deadline()` at most. On a timeout it logs (at warn) "timed out after
/// Ns waiting for: <what>" and returns `error.WaitTimedOut`. `cond` returns
/// `bool` or an error union of `bool` (an error ends the wait with it).
/// Runs on any `std.Io` (a zio task, `std.testing.io`), yielding while it
/// sleeps.
pub fn waitUntil(io: std.Io, comptime what: []const u8, ctx: anytype, comptime cond: anytype) (WaitError || CondError(@TypeOf(cond)))!void {
    return waitUntilFor(io, what, deadline(), ctx, cond);
}

/// `waitUntil` with an explicit limit (still a hang guard: scale it with
/// `timeoutFactor()` if it is not `deadline()`).
pub fn waitUntilFor(io: std.Io, comptime what: []const u8, limit: std.Io.Duration, ctx: anytype, comptime cond: anytype) (WaitError || CondError(@TypeOf(cond)))!void {
    const start = std.Io.Clock.awake.now(io);
    var backoff: i96 = first_backoff_ns;
    while (true) {
        if (try check(cond, ctx)) return;
        const waited = start.durationTo(std.Io.Clock.awake.now(io));
        if (waited.nanoseconds >= limit.nanoseconds) {
            // One last look: the condition may have come true while the
            // deadline passed (a long stop of this thread).
            if (try check(cond, ctx)) return;
            log.warn("timed out after {d}s waiting for: " ++ what, .{@divTrunc(waited.nanoseconds, std.time.ns_per_s)});
            return error.WaitTimedOut;
        }
        try io.sleep(.fromNanoseconds(backoff), .awake);
        backoff = @min(backoff * 2, max_backoff_ns);
    }
}

/// Checks that `cond(ctx)` holds now and keeps holding for `window`
/// (`short_window` is the usual one), polling as `waitUntil` does. Fails
/// with `error.ConditionChanged` (logging "no longer holds: <what>" at warn) the
/// first time it does not. For "X never happens" claims: a slow machine can
/// only make it miss a bug, never fail a correct program.
pub fn expectStays(io: std.Io, comptime what: []const u8, ctx: anytype, comptime cond: anytype, window: std.Io.Duration) (StayError || CondError(@TypeOf(cond)))!void {
    const start = std.Io.Clock.awake.now(io);
    var backoff: i96 = first_backoff_ns;
    while (true) {
        if (!try check(cond, ctx)) {
            log.warn("no longer holds: " ++ what, .{});
            return error.ConditionChanged;
        }
        const waited = start.durationTo(std.Io.Clock.awake.now(io));
        if (waited.nanoseconds >= window.nanoseconds) return;
        const left = window.nanoseconds - waited.nanoseconds;
        try io.sleep(.fromNanoseconds(@min(backoff, left)), .awake);
        backoff = @min(backoff * 2, max_backoff_ns);
    }
}

/// Waits until the atomic counter `v` reaches at least `n` (Envoy's
/// `waitForCounterGe`).
pub fn waitAtLeast(io: std.Io, comptime what: []const u8, v: anytype, n: @TypeOf(v.raw)) WaitError!void {
    const Ctx = struct {
        v: @TypeOf(v),
        n: @TypeOf(v.raw),
        fn reached(c: @This()) bool {
            return c.v.load(.acquire) >= c.n;
        }
    };
    return waitUntil(io, what, Ctx{ .v = v, .n = n }, Ctx.reached);
}

/// Waits until the atomic `v` holds exactly `value`.
pub fn waitEqual(io: std.Io, comptime what: []const u8, v: anytype, value: @TypeOf(v.raw)) WaitError!void {
    const Ctx = struct {
        v: @TypeOf(v),
        value: @TypeOf(v.raw),
        fn holds(c: @This()) bool {
            return c.v.load(.acquire) == c.value;
        }
    };
    return waitUntil(io, what, Ctx{ .v = v, .value = value }, Ctx.holds);
}

/// Waits until the atomic `v` is not zero, and returns what it holds.
pub fn waitNonZero(io: std.Io, comptime what: []const u8, v: anytype) WaitError!@TypeOf(v.raw) {
    const Ctx = struct {
        v: @TypeOf(v),
        fn set(c: @This()) bool {
            return c.v.load(.acquire) != 0;
        }
    };
    try waitUntil(io, what, Ctx{ .v = v }, Ctx.set);
    return v.load(.acquire);
}

/// Waits until the atomic flag `v` is set.
pub fn waitFlag(io: std.Io, comptime what: []const u8, v: *const std.atomic.Value(bool)) WaitError!void {
    return waitUntil(io, what, v, struct {
        fn set(f: *const std.atomic.Value(bool)) bool {
            return f.load(.acquire);
        }
    }.set);
}

/// Waits until `event` is set, for `deadline()` at most (a hang guard in
/// place of a bare `event.wait(io)`, which hangs the test binary when the
/// event is never set). A real timed wait on the event, no polling: it wakes
/// as soon as the event is set. On a timeout it logs (at warn) "timed out
/// after Ns waiting for: <what>" and returns `error.WaitTimedOut`, as
/// `waitUntil` does. A canceled caller gets `error.Canceled`.
pub fn waitEvent(io: std.Io, comptime what: []const u8, event: *std.Io.Event) WaitError!void {
    return waitEventFor(io, what, deadline(), event);
}

/// `waitEvent` with an explicit limit (still a hang guard: scale it with
/// `timeoutFactor()` if it is not `deadline()`).
pub fn waitEventFor(io: std.Io, comptime what: []const u8, limit: std.Io.Duration, event: *std.Io.Event) WaitError!void {
    const start = std.Io.Clock.awake.now(io);
    const until: std.Io.Clock.Timestamp = .{ .raw = start.addDuration(limit), .clock = .awake };
    while (true) {
        event.waitTimeout(io, .{ .deadline = until }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            // The deadline passed or a spurious wake-up: look again below.
            error.Timeout => {},
        };
        if (event.isSet()) return;
        const waited = start.durationTo(std.Io.Clock.awake.now(io));
        if (waited.nanoseconds >= limit.nanoseconds) {
            log.warn("timed out after {d}s waiting for: " ++ what, .{@divTrunc(waited.nanoseconds, std.time.ns_per_s)});
            return error.WaitTimedOut;
        }
    }
}

fn CondError(comptime F: type) type {
    const R = @typeInfo(F).@"fn".return_type.?;
    return switch (@typeInfo(R)) {
        .error_union => |eu| eu.error_set,
        .bool => error{},
        else => @compileError("a wait condition returns bool or an error union of bool, not " ++ @typeName(R)),
    };
}

inline fn check(comptime cond: anytype, ctx: anytype) CondError(@TypeOf(cond))!bool {
    const R = @typeInfo(@TypeOf(cond)).@"fn".return_type.?;
    return if (@typeInfo(R) == .error_union) try cond(ctx) else cond(ctx);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "wait: waitUntil returns once another thread makes the condition true" {
    const io = testing.io;
    var flag: std.atomic.Value(bool) = .init(false);
    const t = try std.Thread.spawn(.{}, struct {
        fn run(f: *std.atomic.Value(bool)) void {
            f.store(true, .release);
        }
    }.run, .{&flag});
    defer t.join();
    try waitFlag(io, "the other thread set the flag", &flag);
    try testing.expect(flag.load(.acquire));
}

test "wait: waitUntil times out with WaitTimedOut on a condition that never holds" {
    const never = struct {
        fn f(_: void) bool {
            return false;
        }
    }.f;
    try testing.expectError(error.WaitTimedOut, waitUntilFor(testing.io, "nothing (on purpose)", .fromMilliseconds(20), {}, never));
}

test "wait: a condition's error ends the wait with that error" {
    const failing = struct {
        fn f(_: void) error{Broken}!bool {
            return error.Broken;
        }
    }.f;
    try testing.expectError(error.Broken, waitUntil(testing.io, "a broken condition", {}, failing));
}

test "wait: waitAtLeast waits for a counter, not for a fixed time" {
    var n: std.atomic.Value(u32) = .init(0);
    const t = try std.Thread.spawn(.{}, struct {
        fn run(c: *std.atomic.Value(u32)) void {
            for (0..3) |_| _ = c.fetchAdd(1, .release);
        }
    }.run, .{&n});
    defer t.join();
    try waitAtLeast(testing.io, "three increments", &n, 3);
    try testing.expect(n.load(.acquire) >= 3);
}

test "wait: waitEqual and waitNonZero wait for a value another thread stores" {
    var v: std.atomic.Value(u64) = .init(0);
    const t = try std.Thread.spawn(.{}, struct {
        fn run(x: *std.atomic.Value(u64)) void {
            x.store(42, .release);
        }
    }.run, .{&v});
    defer t.join();
    try testing.expectEqual(@as(u64, 42), try waitNonZero(testing.io, "the value stored", &v));
    try waitEqual(testing.io, "the value is 42", &v, 42);
}

test "wait: waitEvent returns once another thread sets the event, and times out on one never set" {
    var event: std.Io.Event = .unset;
    const t = try std.Thread.spawn(.{}, struct {
        fn run(e: *std.Io.Event) void {
            e.set(testing.io);
        }
    }.run, .{&event});
    defer t.join();
    try waitEvent(testing.io, "the other thread set the event", &event);
    try testing.expect(event.isSet());

    var never: std.Io.Event = .unset;
    try testing.expectError(error.WaitTimedOut, waitEventFor(testing.io, "an event nobody sets (on purpose)", .fromMilliseconds(20), &never));
}

test "wait: expectStays passes while the condition holds for the window" {
    var flag: std.atomic.Value(bool) = .init(false);
    const unset = struct {
        fn f(v: *const std.atomic.Value(bool)) bool {
            return !v.load(.acquire);
        }
    }.f;
    try expectStays(testing.io, "the flag stays unset", &flag, unset, .fromMilliseconds(20));
}

test "wait: expectStays fails with ConditionChanged once the condition stops holding" {
    var flag: std.atomic.Value(bool) = .init(true);
    const unset = struct {
        fn f(v: *const std.atomic.Value(bool)) bool {
            return !v.load(.acquire);
        }
    }.f;
    // Already broken: no window has to pass for the failure.
    try testing.expectError(error.ConditionChanged, expectStays(testing.io, "the flag stays unset (on purpose)", &flag, unset, .fromSeconds(60)));
}

test "wait: the timeout factor parses whole numbers and falls back to 1" {
    try testing.expectEqual(@as(u32, 1), parseFactor(null));
    try testing.expectEqual(@as(u32, 3), parseFactor("3"));
    try testing.expectEqual(@as(u32, 4), parseFactor(" 4\n"));
    try testing.expectEqual(@as(u32, 1), parseFactor("0"));
    try testing.expectEqual(@as(u32, 1), parseFactor("fast"));
    try testing.expect(deadline().toSeconds() >= default_deadline_s);
}

test "wait: ANOLE_TEST_TIMING is on when set to anything but empty or 0" {
    try testing.expect(!parseTiming(null));
    try testing.expect(!parseTiming(""));
    try testing.expect(!parseTiming("0"));
    try testing.expect(parseTiming("1"));
    try testing.expect(parseTiming(" yes\n"));
}
