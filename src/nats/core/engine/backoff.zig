// Adapted from vkiryakov/zefir src/nats/engine/backoff.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! How long the client waits before its next attempt to reconnect, after
//! `failures` failed attempts and short connections in a row (the manager
//! counts them): none at first, then the wait doubles from `min_delay` up
//! to `max_delay`, and with `jitter` each wait is cut by up to a fifth, so
//! that clients do not reconnect in step. Any attempt, the ten-thousandth
//! too, waits `max_delay` at most: the arithmetic saturates instead of
//! overflowing.

const std = @import("std");
const Io = std.Io;
const ReconnectOptions = @import("../Options.zig").ReconnectOptions;

/// The wait before the next attempt after `failures` failed ones in a row;
/// `random` is any random number, used for the jitter.
pub fn delay(options: ReconnectOptions, failures: u32, random: u64) Io.Duration {
    if (failures == 0) return .zero;
    const max = options.max_delay.nanoseconds;
    var base = options.min_delay.nanoseconds;
    var doubled: u32 = 1;
    // At most 96 doublings take any positive i96 to its maximum.
    while (doubled < failures and base < max) : (doubled += 1) base *|= 2;
    base = @min(base, max);
    if (!options.jitter) return .{ .nanoseconds = base };
    // Downward only: `max_delay` stays the longest wait, and clients at the
    // cap do not wait in step.
    const spread = @divTrunc(base, 5);
    if (spread <= 0) return .{ .nanoseconds = base };
    const range: u96 = @intCast(spread + 1);
    const cut: i96 = @intCast(@as(u96, random) % range);
    return .{ .nanoseconds = base - cut };
}

const testing = std.testing;

test "the first attempt is immediate, then the wait doubles up to max_delay" {
    const options: ReconnectOptions = .{ .jitter = false };
    try testing.expectEqual(0, delay(options, 0, 0).nanoseconds);
    const expected = [_]i64{ 500, 1000, 2000, 4000, 8000, 10_000, 10_000 };
    for (expected, 1..) |milliseconds, failures| {
        try testing.expectEqual(milliseconds, delay(options, @intCast(failures), 0).toMilliseconds());
    }
}

test "on any attempt, the ten-thousandth too, the wait is at most max_delay, and at least four fifths of it" {
    const options: ReconnectOptions = .{};
    const max = options.max_delay.nanoseconds;
    var failures: u32 = 1;
    while (failures <= 10_000) : (failures += 1) {
        for ([_]u64{ 0, 1, 12345, std.math.maxInt(u64) }) |random| {
            const wait = delay(options, failures, random).nanoseconds;
            try testing.expect(wait >= @divTrunc(options.min_delay.nanoseconds * 4, 5));
            try testing.expect(wait <= max);
            if (failures >= 6) try testing.expect(wait >= max - @divTrunc(max, 5));
        }
    }
    try testing.expectEqual(max, delay(.{ .jitter = false }, 10_000, 0).nanoseconds);
    try testing.expectEqual(max, delay(.{ .jitter = false }, std.math.maxInt(u32), 0).nanoseconds);
}

test "the jitter cuts the wait by up to a fifth, never lengthens it" {
    const options: ReconnectOptions = .{ .min_delay = .fromSeconds(1), .max_delay = .fromSeconds(1) };
    const spread: u64 = @divTrunc(1_000_000_000, 5);
    try testing.expectEqual(1000, delay(options, 3, 0).toMilliseconds());
    try testing.expectEqual(800, delay(options, 3, spread).toMilliseconds());
    try testing.expectEqual(900, delay(options, 3, spread / 2).toMilliseconds());
    // The range wraps: any random number gives a wait in it.
    try testing.expectEqual(1000, delay(options, 3, spread + 1).toMilliseconds());
}

test "the longest delays do not overflow" {
    const huge: ReconnectOptions = .{ .min_delay = .fromNanoseconds(1), .max_delay = .max };
    for ([_]u32{ 1, 64, 95, 96, 97, 200, std.math.maxInt(u32) }) |failures| {
        for ([_]u64{ 0, std.math.maxInt(u64) }) |random| {
            try testing.expect(delay(huge, failures, random).nanoseconds > 0);
        }
    }
    const at_max: ReconnectOptions = .{ .min_delay = .max, .max_delay = .max };
    try testing.expect(delay(at_max, 1, std.math.maxInt(u64)).nanoseconds > 0);
    try testing.expect(delay(at_max, 1, 0).nanoseconds > 0);
}
