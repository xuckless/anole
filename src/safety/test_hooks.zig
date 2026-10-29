//! What the test runner (src/safety/test_runner.zig) asks of the code under
//! test, for a test binary with zio: its count of swallowed cancellations
//! (`debug_cancel`; 0 when the option is off or the zio is the core's stub),
//! a dump of every live task for a hang dump, and the binary's zio options.
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

/// The zio configuration of the test binary, which the runner declares as
/// the root's `zio_options` (zio reads it from the root; in a test binary
/// that is the runner): this zio's build defaults (pinned, `fast_accept`,
/// `diagnostics`, from build.zig) with SAFETY.md's zio checks on in every
/// test build, not only Debug ones, as `safety.enabled` is:
/// `debug_held_locks` (L2) and `debug_cancel` (C3). A ReleaseSafe test
/// binary then checks suspensions as well as counting locks.
pub const zio_options: zio.Options = blk: {
    var o: zio.Options = .{};
    o.debug_held_locks = true;
    o.debug_cancel = true;
    break :blk o;
};

/// The test allocator's backing allocator (src/safety/never_reuse.zig).
pub const never_reuse = @import("anole_never_reuse");
