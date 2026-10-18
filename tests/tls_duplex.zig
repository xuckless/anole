//! Multi-threaded full-duplex check of Anole's BoringSSL module: zio pinned
//! scheduling with several executors, so the tasks that read and write one TLS
//! connection run on different OS threads. Part of `zig build test` when TLS
//! is built in; the single-executor variant is a unit test in src/tls/root.zig.
const std = @import("std");
const anole = @import("anole");

pub const zio_options: anole.zio.Options = .{ .scheduling = .pinned };

/// A lost or reordered record shows up as a wrong byte, but a corrupted TLS
/// state can also leave both sides waiting forever; fail instead of hanging.
fn watchdog() void {
    const ts: std.c.timespec = .{ .sec = 60, .nsec = 0 };
    _ = std.c.nanosleep(&ts, null);
    std.debug.print("tls-duplex: no progress after 60s\n", .{});
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const dog = try std.Thread.spawn(.{}, watchdog, .{});
    dog.detach();
    const rt = try anole.zio.Runtime.init(init.gpa, .{ .executors = .exact(4) });
    defer rt.deinit();
    for (0..3) |_| try anole.tls.testing.duplex.run(init.gpa, rt.io(), .{});
}
