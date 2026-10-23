//! Lets a test say that it provokes `err` logs on purpose. The test runner
//! fails a test that logs at `err`; code that logs a failure the caller
//! also gets as an error asks `swallow()` first. Only inside a guard are
//! those logs dropped (and counted); everywhere else they still fail the
//! test. Production builds never swallow.
const std = @import("std");
const builtin = @import("builtin");

var depth: std.atomic.Value(u32) = .init(0);
var swallowed: std.atomic.Value(u32) = .init(0);

pub const Guard = struct {
    /// How many `err` logs the guard (and any before it) dropped.
    pub fn count(_: Guard) u32 {
        return swallowed.load(.monotonic);
    }
    pub fn deinit(_: Guard) void {
        _ = depth.fetchSub(1, .monotonic);
    }
};

/// `defer` the guard's `deinit` around the call that is meant to log.
pub fn expect() Guard {
    _ = depth.fetchAdd(1, .monotonic);
    return .{};
}

/// Whether this `err` log is one a test expected.
pub fn swallow() bool {
    if (!builtin.is_test) return false;
    if (depth.load(.monotonic) == 0) return false;
    _ = swallowed.fetchAdd(1, .monotonic);
    return true;
}
