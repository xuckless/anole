// Written for Anole, not adapted from dusty (MIT, see LICENSE).

//! The process's open-file limit (RLIMIT_NOFILE), and the connection cap
//! (`ServerConfig.max_connections`) worked out from it. Every connection
//! is a file descriptor, so past the soft limit `accept` fails with EMFILE
//! whatever the cap says; a cap a little below it keeps descriptors free
//! for everything else a server opens.
const std = @import("std");
const builtin = @import("builtin");

const has_rlimit = builtin.os.tag != .windows and builtin.os.tag != .wasi;

/// The cap where there is no open-file limit to work from (Windows).
pub const fallback_max_connections: u32 = 10_000;

pub const Raised = struct { from: u64, to: u64 };

/// The soft open-file limit, or null where there is none (Windows).
pub fn softLimit() ?u64 {
    if (comptime !has_rlimit) return null;
    const lim = std.posix.getrlimit(.NOFILE) catch return null;
    return @intCast(lim.cur);
}

/// Raises the soft open-file limit to the hard one, as Go does at startup
/// since 1.19: the soft limit is often 1024 (256 on macOS), a default kept
/// for programs that use select(2), while the hard limit, which any process
/// may raise its soft limit to, is far higher (524,288 under systemd,
/// 1,048,576 in Docker). On macOS the soft limit goes no higher than
/// `kern.maxfilesperproc`, which setrlimit would refuse. Returns what
/// changed, or null when nothing did (already there, refused, or no such
/// limit). Processes started from here inherit the raised limit.
pub fn raiseSoftLimit() ?Raised {
    if (comptime !has_rlimit) return null;
    var lim = std.posix.getrlimit(.NOFILE) catch return null;
    if (lim.cur >= lim.max) return null;
    const from: u64 = @intCast(lim.cur);
    lim.cur = lim.max;
    if (comptime builtin.os.tag.isDarwin()) {
        var per_process: c_int = 0;
        var len: usize = @sizeOf(c_int);
        if (std.c.sysctlbyname("kern.maxfilesperproc", &per_process, &len, null, 0) == 0 and per_process > 0) {
            lim.cur = @min(lim.cur, @as(@TypeOf(lim.cur), @intCast(per_process)));
        }
        if (lim.cur <= from) return null;
    }
    std.posix.setrlimit(.NOFILE, lim) catch return null;
    return .{ .from = from, .to = @intCast(lim.cur) };
}

/// The connection cap a soft open-file limit of `soft` leaves room for, on
/// `executors` executors with `listener_sockets` listening sockets open.
/// What it keeps back:
///
///   - 64 for the process at large: stdin, stdout and stderr, log files,
///     the DNS resolver's sockets, a few files opened at startup;
///   - 8 per executor: its event loop (an epoll, kqueue or io_uring
///     descriptor and its wake-up eventfd or pipe), and an HTTP/3 UDP
///     socket where there is one per executor;
///   - every listening socket (one per accept loop on Linux, where each
///     has its own SO_REUSEPORT socket);
///   - an eighth of the limit, for what grows with the traffic beside the
///     connections themselves: files a static handler has open while it
///     sends them, the outbound client's connections, database pools.
///     One connection in eight holding one more descriptor at a time.
///
/// Never less than half the limit, so a small one still serves, and at
/// least 1.
pub fn maxConnections(soft: u64, executors: usize, listener_sockets: usize) u32 {
    const kept: u64 = 64 + 8 * @as(u64, executors) + listener_sockets + soft / 8;
    const cap = soft - @min(kept, soft / 2);
    return @intCast(@max(1, @min(cap, std.math.maxInt(u32) - 1)));
}

test "maxConnections: the limit less what is kept back, at least half of it" {
    // Docker's 1,048,576, 16 executors, 4 listeners with a socket per
    // executor each: 1,048,576 - (64 + 128 + 64 + 131,072).
    try std.testing.expectEqual(@as(u32, 917_248), maxConnections(1 << 20, 16, 64));
    // A soft limit that could not be raised from 1024, 4 executors, 2
    // listeners: 1024 - (64 + 32 + 2 + 128).
    try std.testing.expectEqual(@as(u32, 798), maxConnections(1024, 4, 2));
    // macOS's usual kern.maxfilesperproc.
    try std.testing.expectEqual(@as(u32, 8_814), maxConnections(10_240, 10, 2));
    // Too small for the full reserve: half is kept.
    try std.testing.expectEqual(@as(u32, 128), maxConnections(256, 64, 64));
    try std.testing.expectEqual(@as(u32, 1), maxConnections(1, 1, 1));
    try std.testing.expectEqual(@as(u32, 1), maxConnections(0, 1, 1));
    // An effectively unlimited one stays below the "work it out" marker.
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32) - 1), maxConnections(1 << 62, 8, 8));
}

test "raiseSoftLimit: the soft limit ends at the hard one (or macOS's per-process cap)" {
    if (comptime !has_rlimit) return error.SkipZigTest;
    const before = try std.posix.getrlimit(.NOFILE);
    defer std.posix.setrlimit(.NOFILE, before) catch {};
    // Lowered first, so there is something to raise.
    var low = before;
    low.cur = @min(before.max, 256);
    try std.posix.setrlimit(.NOFILE, low);
    const raised = raiseSoftLimit();
    const after = try std.posix.getrlimit(.NOFILE);
    if (before.max > 256) {
        try std.testing.expect(raised != null);
        try std.testing.expectEqual(@as(u64, 256), raised.?.from);
        try std.testing.expectEqual(@as(u64, @intCast(after.cur)), raised.?.to);
        try std.testing.expect(after.cur > 256);
        if (comptime !builtin.os.tag.isDarwin()) try std.testing.expectEqual(before.max, after.cur);
    }
    try std.testing.expectEqual(@as(?u64, @intCast(after.cur)), softLimit());
    // Already at the top: nothing to do.
    if (after.cur == after.max) try std.testing.expect(raiseSoftLimit() == null);
}
