//! What the test runner (src/safety/test_runner.zig) asks of the code under
//! test, for a test binary with zio: its count of swallowed cancellations
//! (`debug_cancel`; 0 when the option is off or the zio is the core's stub).
const zio = @import("zio");

pub fn swallowedCancels() u64 {
    if (comptime @hasDecl(zio, "swallowedCancels")) return zio.swallowedCancels();
    return 0;
}

/// The test allocator's backing allocator (src/safety/never_reuse.zig).
pub const never_reuse = @import("anole_never_reuse");
