//! Live connection and stream counts per executor, for the runtime gauges
//! on `/metrics`. One relaxed atomic add per connection or stream opened
//! and closed; counters are process-wide (one set per process).
const std = @import("std");
const placement = @import("placement.zig");

/// Executors counted; any beyond this share the last slot.
pub const max_executors = 64;

pub const Kind = enum { connections, h2_streams, h3_streams };

var counts: [3][max_executors]std.atomic.Value(i64) = @splat(@splat(.init(0)));

fn slot(io: std.Io) usize {
    return @min(placement.currentExecutor(io) orelse 0, max_executors - 1);
}

/// Adds `delta` (negative to remove) on the calling task's executor.
pub fn add(io: std.Io, kind: Kind, delta: i64) void {
    _ = counts[@intFromEnum(kind)][slot(io)].fetchAdd(delta, .monotonic);
}

/// The count on executor `index`. A connection closed on another executor
/// than it opened on can make one slot negative; sums stay right.
pub fn get(kind: Kind, index: usize) i64 {
    return counts[@intFromEnum(kind)][index].load(.monotonic);
}
