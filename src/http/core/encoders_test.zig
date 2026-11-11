//! The per-thread encoders (src/http/core/encoders.zig) on the real zio
//! runtime: they are shared by every task on an executor, so a task that
//! suspends while it holds one panics in debug builds (SAFETY.md M3,
//! executor buffers). Part of anole's suite (the core's own tests run on
//! its stub zio, which counts no held locks).
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const zio = @import("zio");
const dusty = @import("dusty");
const safety = @import("anole_safety");
const encoders = dusty._encoders;

/// Yields while holding this thread's gzip encoder on `io`'s runtime, at
/// the lines it returns (the take, then the suspension); `io` null only
/// computes them.
fn yieldWithEncoder(io: ?std.Io) [2]u32 {
    const take_line = @src().line + 5;
    const yield_line = take_line + 1;
    if (io) |i| if (comptime build_options.compression) {
        var buf: [64]u8 = undefined;
        var out: std.Io.Writer.Discarding = .init(&buf);
        _ = encoders.gzip(&out.writer) catch @panic("no memory for the encoder");
        i.sleep(.fromMilliseconds(1), .awake) catch {};
        encoders.release();
    };
    return .{ take_line, yield_line };
}

test "encoders: a task that suspends while holding the thread's encoder panics, naming where it took it" {
    if (!build_options.compression or !safety.enabled or !zio.held_locks.enabled) return error.SkipZigTest;
    const key = "a task that suspends while holding the thread's encoder panics";
    if (safety.child.isChild(key)) {
        // The child panics; nothing is cleaned up.
        const rt = try zio.Runtime.init(std.heap.page_allocator, .{ .executors = .exact(1) });
        _ = yieldWithEncoder(rt.io());
        return;
    }
    const out = try safety.child.runPanicking(std.testing.allocator, key);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "SAFETY.md L2: a task suspended while holding 1 lock(s)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "a read section, begun at:") != null);
    // Debug only: an optimized binary inlines the call, and the site is
    // then the nearest frame left out of line (as in qsbr_test.zig).
    if (builtin.mode == .debug) {
        const lines = yieldWithEncoder(null);
        for (lines) |line| {
            var buf: [32]u8 = undefined;
            const needle = try std.fmt.bufPrint(&buf, "encoders_test.zig:{d}:", .{line});
            if (std.mem.indexOf(u8, out, needle) == null) {
                std.debug.print("expected {s} in the child's stderr:\n{s}\n", .{ needle, out });
                return error.SiteNotNamed;
            }
        }
    }
}
