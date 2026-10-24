//! The clock every store write reads (J15): the real one, or a test's.
const std = @import("std");
const root = @import("root.zig");

pub const Clock = root.Clock;
pub const Time = root.Time;

/// Wraps `Options.clock`, or the real clock when null.
pub const Source = struct {
    io: std.Io,
    custom: ?Clock,

    pub fn now(self: Source) Time {
        if (self.custom) |c| return c.now(c.context);
        return Time.now(self.io);
    }
};
