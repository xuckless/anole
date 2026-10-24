//! `test_hooks.zig` for a test binary without zio: nothing to report.
pub fn swallowedCancels() u64 {
    return 0;
}

/// The test allocator's backing allocator (src/safety/never_reuse.zig).
pub const never_reuse = @import("anole_never_reuse");
