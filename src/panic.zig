//! A panic handler that leaves a record where the logs go. Zig's default
//! handler prints the message and stack trace to standard error and aborts;
//! a server whose log function sends its lines elsewhere (a JSON collector,
//! journald, the C ABI's log callback into Node or Python) would lose the
//! one line that says why it stopped. This one writes the message and the
//! stack trace as one error line through the root's log function (scope
//! `anole`), then aborts.
//!
//! In the executable's root file (the examples do; remove the line to keep
//! Zig's default):
//!
//!     pub const panic = anole.panic;
const std = @import("std");

var trace_buf: [32 * 1024]u8 = undefined;
var taken: std.atomic.Value(bool) = .init(false);

/// Called first, before anything is written: the live console sets it while
/// it owns the terminal, so the message reaches the real screen. Must be
/// async-signal-safe.
pub var before_panic: ?*const fn () void = null;

/// The handler `panic` wraps.
pub fn handler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    log(msg, first_trace_addr orelse @returnAddress());
    std.process.abort();
}

/// Logs the panic once. Another thread panicking meanwhile, or a panic
/// inside the logging itself, takes Zig's own path (standard error).
pub fn log(msg: []const u8, first_address: usize) void {
    @branchHint(.cold);
    if (before_panic) |f| f();
    if (taken.swap(true, .acq_rel)) std.debug.defaultPanic(msg, first_address);
    var w: std.Io.Writer = .fixed(&trace_buf);
    write(&w, msg, first_address);
    std.log.scoped(.anole).err("{s}", .{w.buffered()});
}

/// "panic: <msg>", then the error return trace if there is one, then the
/// stack trace; cut short where the buffer ends.
fn write(w: *std.Io.Writer, msg: []const u8, first_address: usize) void {
    const t: std.Io.Terminal = .{ .writer = w, .mode = .no_color };
    w.print("panic: {s}\n", .{msg}) catch return;
    if (@errorReturnTrace()) |et| if (et.index > 0) {
        w.writeAll("error return context:\n") catch return;
        std.debug.writeErrorReturnTrace(et, t) catch return;
        w.writeAll("\nstack trace:\n") catch return;
    };
    std.debug.writeCurrentStackTrace(.{ .first_address = first_address, .allow_unsafe_unwind = true }, t) catch return;
}

/// `pub const panic = anole.panic;` in the root file.
pub const panic = std.debug.FullPanic(handler);

test "panic: the record holds the message and a stack trace" {
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    write(&w, "index out of bounds", @returnAddress());
    const text = w.buffered();
    try std.testing.expect(std.mem.startsWith(u8, text, "panic: index out of bounds\n"));
    try std.testing.expect(text.len > "panic: index out of bounds\n".len);
}
