//! T3: one executor per object. An object with mutable state records the
//! executor it was made on (`Owner.here`) and asserts it where it is used
//! (`check`). Other executors and threads reach it by message or handle.
//!
//! Off zio (std.Io.Threaded, the core's zio stub) there are no executors,
//! and an object made off an executor (a blocking-pool thread, a C ABI
//! consumer thread) has no owner yet: both check nothing.
const std = @import("std");
const zio = @import("zio");
const enabled = @import("root.zig").enabled;

const have_zio = !@hasDecl(zio, "is_stub");

/// The executor the caller runs on, or null off one (or off zio).
pub fn currentExecutor(io: std.Io) ?usize {
    if (comptime !have_zio) return null;
    const rt = zio.Runtime.fromIo(io) orelse return null;
    const id = rt.currentExecutor() orelse return null;
    return @intCast(id);
}

pub const Owner = struct {
    /// The owning executor's index + 1; 0: none recorded.
    exec: if (enabled) u32 else void = if (enabled) 0 else {},

    pub const none: Owner = .{};

    /// The executor the caller runs on.
    pub fn here(io: std.Io) Owner {
        if (!enabled) return .{};
        const e = currentExecutor(io) orelse return .{};
        return .{ .exec = @intCast(e + 1) };
    }

    /// Panics when the caller runs on another executor than the owner's.
    pub fn check(self: Owner, io: std.Io) void {
        if (!enabled or self.exec == 0) return;
        const e = currentExecutor(io) orelse
            std.debug.panic("SAFETY.md T3: an object of executor {d} used off any executor (a thread): send it a message", .{self.exec - 1});
        if (e + 1 != self.exec)
            std.debug.panic("SAFETY.md T3: an object of executor {d} used from executor {d}: send it a message", .{ self.exec - 1, e });
    }
};

test "owner: off zio nothing is recorded or checked" {
    const o: Owner = .here(std.testing.io);
    o.check(std.testing.io);
    if (enabled) try std.testing.expectEqual(@as(u32, 0), o.exec);
}
