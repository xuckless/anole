//! systemd's service notification protocol (sd_notify(3)), spoken directly:
//! one datagram of `KEY=VALUE` lines to the AF_UNIX socket named in
//! `NOTIFY_SOCKET` (a path, or with a leading '@' a name in Linux's
//! abstract namespace). No libsystemd. Without `NOTIFY_SOCKET`, as outside
//! a `Type=notify` service, every call does nothing.
//!
//! What `anole.Server` sends (with `Options.process` set):
//!
//!   READY=1                          once the listeners are bound;
//!   RELOADING=1, MONOTONIC_USEC=...  on SIGUSR2, before starting the
//!                                    successor (systemd 253's
//!                                    `Type=notify-reload` needs the clock);
//!   MAINPID=<pid>, READY=1           from the successor once it serves, so
//!                                    systemd follows the main process to it
//!                                    (needs `NotifyAccess=all`: the sender
//!                                    is not yet the main process);
//!   READY=1                          from the old process, if the successor
//!                                    did not come up and it carries on;
//!   STOPPING=1                       when a drain to exit starts (SIGINT,
//!                                    SIGTERM, `stop`), never when handing
//!                                    over: under `NotifyAccess=all` it would
//!                                    stop the whole service.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

const log = std.log.scoped(.anole);

/// Sends `state` to the socket in `NOTIFY_SOCKET`, if there is one. Best
/// effort: a failure is logged, never returned, as with `sd_notify`.
pub fn notify(environ: std.process.Environ, state: []const u8) void {
    const path = environ.getPosix("NOTIFY_SOCKET") orelse return;
    send(path, state) catch |err| log.warn("sd_notify to {s}: {t}", .{ path, err });
}

pub const SendError = error{ InvalidNotifySocket, Unsupported, SocketFailed, SendFailed };

/// One datagram holding `state` to the AF_UNIX datagram socket at `path`
/// ('@' first: Linux's abstract namespace).
pub fn send(path: []const u8, state: []const u8) SendError!void {
    var addr: c.sockaddr.un = std.mem.zeroes(c.sockaddr.un);
    addr.family = c.AF.UNIX;
    const abstract = path.len > 0 and path[0] == '@';
    if (abstract and builtin.os.tag != .linux) return error.Unsupported;
    // A path needs its terminating zero to fit; an abstract name has none.
    if (path.len < 2 or path.len + @intFromBool(!abstract) > addr.path.len or (path[0] != '/' and !abstract))
        return error.InvalidNotifySocket;
    @memcpy(addr.path[0..path.len], path);
    if (abstract) addr.path[0] = 0;
    const len: c.socklen_t = @intCast(@offsetOf(c.sockaddr.un, "path") + path.len + @intFromBool(!abstract));
    if (@hasField(c.sockaddr.un, "len")) addr.len = @intCast(len);

    const fd = c.socket(c.AF.UNIX, c.SOCK.DGRAM, 0);
    if (fd < 0) return error.SocketFailed;
    defer _ = c.close(fd);
    _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
    const n = c.sendto(fd, state.ptr, state.len, 0, @ptrCast(&addr), len);
    if (n != @as(isize, @intCast(state.len))) return error.SendFailed;
}

/// "MAINPID=<pid>\nREADY=1" for a successor, else "READY=1".
pub fn formatReady(buf: []u8, main_pid: ?i64) []const u8 {
    const pid = main_pid orelse return "READY=1";
    return std.fmt.bufPrint(buf, "MAINPID={d}\nREADY=1", .{pid}) catch unreachable;
}

/// "RELOADING=1\nMONOTONIC_USEC=<usec>": the clock is CLOCK_MONOTONIC, the
/// one systemd compares against.
pub fn formatReloading(buf: []u8, monotonic_usec: u64) []const u8 {
    return std.fmt.bufPrint(buf, "RELOADING=1\nMONOTONIC_USEC={d}", .{monotonic_usec}) catch unreachable;
}

/// Room for any message above.
pub const max_message_len = 64;

/// CLOCK_MONOTONIC in microseconds.
pub fn monotonicUsec() u64 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.us_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_us;
}

pub fn ready(environ: std.process.Environ, main_pid: ?i64) void {
    var buf: [max_message_len]u8 = undefined;
    notify(environ, formatReady(&buf, main_pid));
}

pub fn reloading(environ: std.process.Environ) void {
    var buf: [max_message_len]u8 = undefined;
    notify(environ, formatReloading(&buf, monotonicUsec()));
}

pub fn stopping(environ: std.process.Environ) void {
    notify(environ, "STOPPING=1");
}

test "sd_notify: messages" {
    var buf: [max_message_len]u8 = undefined;
    try std.testing.expectEqualStrings("READY=1", formatReady(&buf, null));
    try std.testing.expectEqualStrings("MAINPID=4242\nREADY=1", formatReady(&buf, 4242));
    try std.testing.expectEqualStrings("RELOADING=1\nMONOTONIC_USEC=18446744073709551615", formatReloading(&buf, std.math.maxInt(u64)));
    try std.testing.expect(monotonicUsec() > 0);
}

/// A datagram socket bound at `path` (or an abstract name), as systemd
/// listens, and what arrives on it.
const Listener = struct {
    fd: c.fd_t,

    fn bind(path: []const u8) !Listener {
        var addr: c.sockaddr.un = std.mem.zeroes(c.sockaddr.un);
        addr.family = c.AF.UNIX;
        @memcpy(addr.path[0..path.len], path);
        const abstract = path[0] == '@';
        if (abstract) addr.path[0] = 0;
        const len: c.socklen_t = @intCast(@offsetOf(c.sockaddr.un, "path") + path.len + @intFromBool(!abstract));
        const fd = c.socket(c.AF.UNIX, c.SOCK.DGRAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = c.close(fd);
        if (c.bind(fd, @ptrCast(&addr), len) != 0) return error.BindFailed;
        return .{ .fd = fd };
    }

    fn receive(self: Listener, buf: []u8) ![]u8 {
        var pfd = [_]c.pollfd{.{ .fd = self.fd, .events = c.POLL.IN, .revents = 0 }};
        if (c.poll(&pfd, 1, 2000) != 1) return error.Timeout;
        const n = c.recv(self.fd, buf.ptr, buf.len, 0);
        if (n < 0) return error.ReceiveFailed;
        return buf[0..@intCast(n)];
    }

    fn close(self: Listener) void {
        _ = c.close(self.fd);
    }
};

test "sd_notify: a datagram to NOTIFY_SOCKET, by path and (Linux) by abstract name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // The test's temporary directory is under the working directory.
    var cwd_buf: [256]u8 = undefined;
    if (c.getcwd(&cwd_buf, cwd_buf.len) == null) return error.SkipZigTest;
    const cwd = std.mem.sliceTo(&cwd_buf, 0);
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/.zig-cache/tmp/{s}/notify", .{ cwd, tmp.sub_path });
    // sun_path holds 104 bytes on macOS, 108 on Linux.
    if (path.len >= 104) return error.SkipZigTest;
    const listener = try Listener.bind(path);
    defer listener.close();

    var entry_buf: [128]u8 = undefined;
    const entry = try std.fmt.bufPrintSentinel(&entry_buf, "NOTIFY_SOCKET={s}", .{path}, 0);
    const entries = [_:null]?[*:0]const u8{ "OTHER=1", entry.ptr };
    const environ: std.process.Environ = .{ .block = .{ .slice = &entries } };

    var buf: [256]u8 = undefined;
    ready(environ, 77);
    try std.testing.expectEqualStrings("MAINPID=77\nREADY=1", try listener.receive(&buf));
    stopping(environ);
    try std.testing.expectEqualStrings("STOPPING=1", try listener.receive(&buf));
    reloading(environ);
    try std.testing.expect(std.mem.startsWith(u8, try listener.receive(&buf), "RELOADING=1\nMONOTONIC_USEC="));

    // Nothing set, nothing sent; a bad address is an error, not a crash.
    ready(.{ .block = .{ .slice = &[_:null]?[*:0]const u8{"OTHER=1"} } }, null);
    try std.testing.expectError(error.InvalidNotifySocket, send("x", "READY=1"));
    try std.testing.expectError(error.InvalidNotifySocket, send("relative/path", "READY=1"));

    if (builtin.os.tag == .linux) {
        var name_buf: [48]u8 = undefined;
        var rand: [8]u8 = undefined;
        std.testing.io.random(&rand);
        const name = try std.fmt.bufPrint(&name_buf, "@anole-test-{x}", .{rand});
        const abstract = try Listener.bind(name);
        defer abstract.close();
        try send(name, "READY=1");
        try std.testing.expectEqualStrings("READY=1", try abstract.receive(&buf));
    } else {
        try std.testing.expectError(error.Unsupported, send("@anole", "READY=1"));
    }
}
