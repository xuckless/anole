//! What the test runner (src/safety/test_runner.zig) asks of the code under
//! test, for a test binary with zio: its count of swallowed cancellations
//! (`debug_cancel`; 0 when the option is off or the zio is the core's stub),
//! and a dump of every live task for a hang dump.
const std = @import("std");
const zio = @import("zio");

pub fn swallowedCancels() u64 {
    if (comptime @hasDecl(zio, "swallowedCancels")) return zio.swallowedCancels();
    return 0;
}

/// Every live task of every zio runtime in the process, with the stack of
/// each suspended one (`zio.dumpTasks`, compiled in by the `diagnostics`
/// option in Debug and test builds); a note when this zio has none.
pub fn dumpTasks(w: *std.Io.Writer) void {
    if (comptime @hasDecl(zio, "dumpTasks")) return zio.dumpTasks(w);
    w.writeAll("zio task dump: this zio has none (the core's stub, or a zio before the anole-diag patch)\n") catch {};
}

/// The test allocator's backing allocator (src/safety/never_reuse.zig).
pub const never_reuse = @import("anole_never_reuse");
