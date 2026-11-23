//! Live connection and stream counts per executor, for the runtime gauges
//! on `/metrics`. One relaxed atomic add per connection or stream opened
//! and closed; counters are process-wide (one set per process), one cache
//! line per executor.
const std = @import("std");
const placement = @import("placement.zig");

/// Executors counted; any beyond this share the last slot.
pub const max_executors = 64;

pub const Kind = enum {
    connections,
    h2_streams,
    h3_streams,
    /// Open WebSockets, by the protocol underneath (RFC 6455, 8441, 9220).
    ws_h1,
    ws_h2,
    ws_h3,
    /// Open WebTransport sessions a server accepted.
    wt_sessions,
    /// TCP connections the HTTP/2 engine serves (HTTP/1.x is
    /// `connections - h2_conns`, so its loop counts nothing more).
    h2_conns,
    /// gRPC calls in flight (Zig services and the C ABI's).
    grpc_calls,
};

const kinds = @typeInfo(Kind).@"enum".field_names.len;

/// One executor's counts, on a cache line of their own: executors adding
/// at once never write the same line (#51, #99). HTTP/1.x, HTTP/2 and
/// HTTP/3 all count here.
const Row = struct {
    counts: [kinds]std.atomic.Value(i64) align(64),
};

comptime {
    std.debug.assert(@sizeOf(Row) % 64 == 0);
    std.debug.assert(@alignOf(Row) == 64);
}

var rows: [max_executors]Row = @splat(.{ .counts = @splat(.init(0)) });

fn slot(io: std.Io) usize {
    return @min(placement.currentExecutor(io) orelse 0, max_executors - 1);
}

/// Adds `delta` (negative to remove) on the calling task's executor.
pub fn add(io: std.Io, kind: Kind, delta: i64) void {
    addAt(slot(io), kind, delta);
}

/// Adds `delta` on executor `index` (a C ABI call released on a consumer
/// thread counts on the executor it ran on).
pub fn addAt(index: usize, kind: Kind, delta: i64) void {
    _ = rows[@min(index, max_executors - 1)].counts[@backingInt(kind)].fetchAdd(delta, .monotonic);
}

/// The count on executor `index`. A connection closed on another executor
/// than it opened on can make one slot negative; sums stay right.
pub fn get(kind: Kind, index: usize) i64 {
    return rows[index].counts[@backingInt(kind)].load(.monotonic);
}
