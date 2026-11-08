//! Tests for limits.zig. The token bucket's are ported from nghttp2's
//! tests/nghttp2_ratelim_test.c (MIT, v1.70.0).

const std = @import("std");
const limits = @import("limits.zig");
const TokenBucket = limits.TokenBucket;

const expectEqual = std.testing.expectEqual;

test "h2 limits: token bucket refills at its rate up to its burst" {
    var b: TokenBucket = .init(1000, 21);
    try expectEqual(1000, b.val);
    try expectEqual(1000, b.burst);
    try expectEqual(21, b.rate);
    try expectEqual(0, b.tstamp);

    b.update(999);
    try expectEqual(1000, b.val);
    try expectEqual(999, b.tstamp);

    try std.testing.expect(b.drain(100));
    try expectEqual(900, b.val);
    b.update(1000);
    try expectEqual(921, b.val);
    b.update(1002);
    try expectEqual(963, b.val);
    b.update(1004);
    try expectEqual(1000, b.val);
    try expectEqual(1004, b.tstamp);
}

test "h2 limits: token bucket counts time going backwards as one second" {
    var b: TokenBucket = .init(1000, 21);
    b.update(1);
    try expectEqual(1000, b.val);
    b.update(0);
    try expectEqual(1000, b.val);
    try expectEqual(0, b.tstamp);

    // Not a free refill either: one second's worth.
    b.update(5);
    try std.testing.expect(b.drain(100));
    b.update(4);
    try expectEqual(921, b.val);
    try expectEqual(4, b.tstamp);
}

test "h2 limits: token bucket overflows to full" {
    // rate * duration
    var b: TokenBucket = .init(1000, 100);
    try std.testing.expect(b.drain(999));
    try expectEqual(1, b.val);
    b.update(std.math.maxInt(u64));
    try expectEqual(1000, b.val);

    // val + rate * duration
    b = .init(std.math.maxInt(u64) - 1, 2);
    b.update(1);
    try expectEqual(std.math.maxInt(u64) - 1, b.val);
}

test "h2 limits: token bucket drain takes all or nothing" {
    var b: TokenBucket = .init(100, 7);
    try std.testing.expect(!b.drain(101));
    try std.testing.expect(b.drain(51));
    try std.testing.expect(b.drain(49));
    try std.testing.expect(!b.drain(1));
    try expectEqual(0, b.val);
}

test "h2 limits: defaults" {
    const l: limits.Limits = .{};
    try expectEqual(1000, l.control_frame_budget);
    try expectEqual(100, l.empty_frame_rate);
    try expectEqual(10000, l.glitch_burst);
    try expectEqual(330, l.glitch_rate);
    try expectEqual(1000, l.stream_reset_burst);
    try expectEqual(33, l.stream_reset_rate);
    try expectEqual(100, l.refused_stream_burst);
    try expectEqual(10, l.refused_stream_rate);
    try expectEqual(8, l.max_continuations);
    try expectEqual(32, l.max_settings);
    // The frame parser's default agrees.
    try expectEqual(@as(u32, l.max_settings), (@import("frame.zig").Options{}).max_settings);
}
