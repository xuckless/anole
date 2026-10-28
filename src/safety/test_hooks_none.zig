//! `test_hooks.zig` for a test binary without zio: nothing to report.
const std = @import("std");

pub fn swallowedCancels() u64 {
    return 0;
}

/// No zio, so no tasks: says nothing.
pub fn dumpTasks(w: *std.Io.Writer) void {
    _ = w;
}

/// The test allocator's backing allocator (src/safety/never_reuse.zig).
pub const never_reuse = @import("anole_never_reuse");
