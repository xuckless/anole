//! `/full-restart`'s server side (design 8.3 a): what the process records at
//! start, the exec built from it, and the exec itself. Same PID, argv, cwd
//! and environment, so systemd, Docker, Kubernetes and pm2 see the same
//! process.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("anole_console_ui");
const os = @import("os.zig");

pub const LaunchInfo = struct {
    exe: []const u8,
    argv: []const []const u8,
    cwd: []const u8,
    /// "K=V" pairs, as at start.
    env: []const []const u8,
    socket_activated: bool = false,
    listen_fds: []const i32 = &.{},
};

pub const Plan = struct {
    exe: [:0]const u8,
    argv: [:null]const ?[*:0]const u8,
    envp: [:null]const ?[*:0]const u8,
    cwd: [:0]const u8,
    keep_fds: []const i32,
};

const deleted_suffix = " (deleted)";

fn stripDeleted(exe: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, exe, deleted_suffix)) exe[0 .. exe.len - deleted_suffix.len] else exe;
}

/// Socket activation's variables: kept when the process was socket-activated
/// (same PID, the same descriptors kept open), dropped otherwise.
fn isActivationVar(kv: []const u8) bool {
    return std.mem.startsWith(u8, kv, "LISTEN_");
}

/// A SIGUSR2 hand-off's pipes, which a plain restart never carries over.
fn isHandoffVar(kv: []const u8) bool {
    return std.mem.startsWith(u8, kv, "ANOLE_READY_FD=") or
        std.mem.startsWith(u8, kv, "ANOLE_H3_SECRET_FD=");
}

/// Pure: the exec from what the process recorded. Everything is allocated
/// from `a` (an arena).
pub fn build(a: std.mem.Allocator, info: *const LaunchInfo) !Plan {
    const exe = try a.dupeSentinel(u8, stripDeleted(info.exe), 0);
    const cwd = try a.dupeSentinel(u8, info.cwd, 0);
    const argv = try a.allocSentinel(?[*:0]const u8, @max(info.argv.len, 1), null);
    if (info.argv.len == 0) {
        argv[0] = exe.ptr;
    } else for (info.argv, 0..) |s, i| argv[i] = (try a.dupeSentinel(u8, s, 0)).ptr;
    // A rebuilt binary is the one that starts: argv[0] stays as typed.
    var env: std.ArrayList(?[*:0]const u8) = .empty;
    for (info.env) |kv| {
        if (isHandoffVar(kv)) continue;
        if (isActivationVar(kv) and !info.socket_activated) continue;
        try env.append(a, (try a.dupeSentinel(u8, kv, 0)).ptr);
    }
    try env.append(a, null);
    const envp: [:null]const ?[*:0]const u8 = env.items[0 .. env.items.len - 1 :null];
    return .{
        .exe = exe,
        .argv = argv,
        .envp = envp,
        .cwd = cwd,
        .keep_fds = if (info.socket_activated) try a.dupe(i32, info.listen_fds) else &.{},
    };
}

const posix = struct {
    extern "c" fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
    extern "c" fn chdir(path: [*:0]const u8) c_int;
    extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
    extern "c" fn _NSGetArgv() *[*:null]?[*:0]u8;
    extern "c" fn readlink(path: [*:0]const u8, buf: [*]u8, n: usize) isize;
};

/// Never returns on success. On failure only close-on-exec flags and the
/// signal mask changed.
pub fn execNow(p: *const Plan) error{ExecFailed} {
    if (comptime !os.supported) return error.ExecFailed;
    _ = posix.chdir(p.cwd.ptr);
    // Every descriptor from 3 up is closed by the exec, except the ones a
    // socket-activated process keeps.
    var closed = false;
    if (comptime builtin.os.tag == .linux) {
        const rc = std.os.linux.close_range(3, std.math.maxInt(i32), .{ .UNSHARE = false, .CLOEXEC = true });
        closed = std.os.linux.errno(rc) == .SUCCESS;
    }
    if (!closed) {
        const lim: usize = if (std.posix.getrlimit(.NOFILE)) |l| @intCast(@min(l.cur, 1 << 20)) else |_| 1024;
        var fd: usize = 3;
        while (fd < lim) : (fd += 1) _ = posix.fcntl(@intCast(fd), 2, @as(c_int, 1));
    }
    for (p.keep_fds) |fd| _ = posix.fcntl(fd, 2, @as(c_int, 0)); // F_SETFD, no FD_CLOEXEC
    // zio's signal waits block signals; a blocked SIGINT would survive the exec.
    const empty = std.posix.sigemptyset();
    var old: std.c.sigset_t = undefined;
    _ = std.c.pthread_sigmask(std.c.SIG.SETMASK, &empty, &old);
    ui.sys.defaultSignal(13); // SIGPIPE
    _ = posix.execve(p.exe.ptr, p.argv.ptr, p.envp.ptr);
    return error.ExecFailed;
}

/// What the process knows of how it was started, taken at `Console.start`.
/// Everything is allocated from `a` (an arena kept for the server's life).
pub fn record(a: std.mem.Allocator, io: std.Io) !LaunchInfo {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe: []const u8 = blk: {
        if (comptime builtin.os.tag == .linux) {
            var pb: [std.fs.max_path_bytes:0]u8 = undefined;
            @memcpy(pb[0.."/proc/self/exe".len], "/proc/self/exe");
            pb["/proc/self/exe".len] = 0;
            const n = posix.readlink(&pb, &exe_buf, exe_buf.len);
            if (n > 0) break :blk try a.dupe(u8, stripDeleted(exe_buf[0..@intCast(n)]));
        }
        const n = std.process.executablePath(io, &exe_buf) catch break :blk "";
        break :blk try a.dupe(u8, stripDeleted(exe_buf[0..n]));
    };

    var argv: std.ArrayList([]const u8) = .empty;
    if (comptime builtin.os.tag == .linux) {
        const text = try readAll(a, "/proc/self/cmdline");
        var it = std.mem.splitScalar(u8, text, 0);
        while (it.next()) |part| {
            if (part.len == 0 and it.peek() == null) break;
            try argv.append(a, part);
        }
    } else if (comptime builtin.os.tag.isDarwin()) {
        const av = posix._NSGetArgv().*;
        var i: usize = 0;
        while (av[i]) |s| : (i += 1) try argv.append(a, try a.dupe(u8, std.mem.span(s)));
    }

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try a.dupe(u8, os.getcwd(&cwd_buf) orelse "/");

    var env: std.ArrayList([]const u8) = .empty;
    if (comptime os.supported) {
        var e: usize = 0;
        while (std.c.environ[e]) |s| : (e += 1) try env.append(a, try a.dupe(u8, std.mem.span(s)));
    }

    var activated = false;
    var fds: std.ArrayList(i32) = .empty;
    const lp = ui.sys.getenv("LISTEN_PID");
    const lf = ui.sys.getenv("LISTEN_FDS");
    if (lp != null and lf != null) {
        const pid = std.fmt.parseInt(i32, lp.?, 10) catch -1;
        const n = std.fmt.parseInt(i32, lf.?, 10) catch 0;
        if (pid == ui.sys.getpid() and n > 0) {
            activated = true;
            var k: i32 = 0;
            while (k < n) : (k += 1) try fds.append(a, 3 + k);
        }
    }
    return .{
        .exe = exe,
        .argv = try argv.toOwnedSlice(a),
        .cwd = cwd,
        .env = try env.toOwnedSlice(a),
        .socket_activated = activated,
        .listen_fds = try fds.toOwnedSlice(a),
    };
}

fn readAll(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    var buf: [16 * 1024]u8 = undefined;
    const got = os.readSmall(path, &buf) orelse return "";
    return a.dupe(u8, got);
}

test "reexec: build strips the deleted suffix, drops LISTEN_* unless socket-activated" {
    var arena_s = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_s.deinit();
    const a = arena_s.allocator();
    const argv = [_][]const u8{ "./api", "--port", "3000" };
    const env = [_][]const u8{ "HOME=/h", "LISTEN_FDS=1", "LISTEN_PID=5", "ANOLE_READY_FD=9", "PATH=/bin" };
    var info: LaunchInfo = .{ .exe = "/srv/api (deleted)", .argv = &argv, .cwd = "/srv", .env = &env };
    const p = try build(a, &info);
    try std.testing.expectEqualStrings("/srv/api", p.exe);
    try std.testing.expectEqual(@as(usize, 3), p.argv.len);
    try std.testing.expectEqualStrings("--port", std.mem.span(p.argv[1].?));
    try std.testing.expectEqual(@as(usize, 2), p.envp.len);
    try std.testing.expectEqual(@as(usize, 0), p.keep_fds.len);

    const fds = [_]i32{ 3, 4 };
    info.socket_activated = true;
    info.listen_fds = &fds;
    const q = try build(a, &info);
    try std.testing.expectEqual(@as(usize, 4), q.envp.len);
    try std.testing.expectEqualSlices(i32, &fds, q.keep_fds);
}

test "reexec: record finds this test's executable and working directory" {
    if (!os.supported) return error.SkipZigTest;
    var arena_s = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_s.deinit();
    const info = try record(arena_s.allocator(), std.testing.io);
    try std.testing.expect(info.exe.len > 0);
    try std.testing.expect(info.cwd.len > 0);
    try std.testing.expect(info.env.len > 0);
}
