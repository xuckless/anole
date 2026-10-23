// Adapted from vkiryakov/zefir src/nats/engine/time.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! Deadlines that cannot overflow. A timeout may be as long as
//! `Duration.max`: every wait is cut to `max_wait`, which ends far beyond
//! any real deadline and keeps the time arithmetic of every `std.Io`
//! implementation in range. Every wait of the client takes its deadline
//! from here, on the awake clock.

const std = @import("std");
const Io = std.Io;

/// The longest single wait, about 146 years.
pub const max_wait: Io.Duration = .fromNanoseconds(1 << 62);

/// When `timeout` ends, as a deadline on the awake clock; null when it
/// never does.
pub fn deadline(io: Io, timeout: Io.Timeout) ?Io.Clock.Timestamp {
    const remaining: i96 = switch (timeout) {
        .none => return null,
        .duration => |d| d.raw.nanoseconds,
        .deadline => |d| d.raw.nanoseconds -| d.clock.now(io).nanoseconds,
    };
    const now = Io.Clock.awake.now(io).nanoseconds;
    return .{
        .raw = .{ .nanoseconds = now +| std.math.clamp(remaining, 0, max_wait.nanoseconds) },
        .clock = .awake,
    };
}

/// `duration` from now.
pub fn after(io: Io, duration: Io.Duration) Io.Clock.Timestamp {
    return deadline(io, .{ .duration = .{ .raw = duration, .clock = .awake } }).?;
}

/// The timeout to pass to a wait that ends at `at`: `.none` for never.
pub fn until(at: ?Io.Clock.Timestamp) Io.Timeout {
    return if (at) |d| .{ .deadline = d } else .none;
}

/// `at` has passed.
pub fn expired(io: Io, at: Io.Clock.Timestamp) bool {
    return Io.Clock.awake.now(io).nanoseconds >= at.raw.nanoseconds;
}

const testing = std.testing;

fn forever() Io.Timeout {
    return .{ .duration = .{ .raw = .max, .clock = .awake } };
}

test "a duration becomes a deadline that far from now" {
    const io = testing.io;
    const before = Io.Clock.awake.now(io);
    const at = after(io, .fromMilliseconds(250));
    const later = Io.Clock.awake.now(io);
    try testing.expectEqual(.awake, at.clock);
    try testing.expect(at.raw.nanoseconds >= before.nanoseconds + 250 * std.time.ns_per_ms);
    try testing.expect(at.raw.nanoseconds <= later.nanoseconds + 250 * std.time.ns_per_ms);
    try testing.expect(!expired(io, at));
    try testing.expect(expired(io, after(io, .zero)));
    try testing.expect(expired(io, after(io, .fromSeconds(-1))));
    try testing.expectEqual(Io.Timeout.none, until(null));
    try testing.expectEqual(Io.Timeout{ .deadline = at }, until(at));
}

test "the longest and shortest timeouts do not overflow" {
    const io = testing.io;
    try testing.expect(deadline(io, .none) == null);

    const before = Io.Clock.awake.now(io);
    const longest = deadline(io, forever()).?;
    try testing.expect(longest.raw.nanoseconds - before.nanoseconds >= max_wait.nanoseconds);
    try testing.expect(!expired(io, longest));

    // Absolute deadlines at both ends of the range, on any clock.
    const far = deadline(io, .{ .deadline = .{ .raw = .{ .nanoseconds = std.math.maxInt(i96) }, .clock = .real } }).?;
    try testing.expectEqual(.awake, far.clock);
    try testing.expect(!expired(io, far));
    const past = deadline(io, .{ .deadline = .{ .raw = .{ .nanoseconds = std.math.minInt(i96) }, .clock = .awake } }).?;
    try testing.expect(expired(io, past));
}

fn sleepUntil(io: Io, at: Io.Clock.Timestamp) Io.Cancelable!void {
    return at.wait(io);
}

test "sleeping until the latest deadline is safe" {
    // Io.Threaded turns a deadline into a timespec; the longest one fits.
    const io = testing.io;
    var sleeper = try io.concurrent(sleepUntil, .{ io, deadline(io, forever()).? });
    try io.sleep(.fromMilliseconds(10), .awake);
    try testing.expectError(error.Canceled, sleeper.cancel(io));
}
