//! The few POSIX calls the console's terminal side makes, as direct libc
//! externs (Zig 0.17's std.posix no longer has write, open or close). Std-only
//! apart from libc. On Windows nothing here is analysed: the console is not
//! available there yet (design D15), and every caller checks `supported`.
const std = @import("std");
const builtin = @import("builtin");

pub const supported = builtin.os.tag != .windows;
pub const fd_t = c_int;

const is_linux = builtin.os.tag == .linux;
const is_darwin = builtin.os.tag.isDarwin();

pub const PollFd = extern struct { fd: c_int, events: c_short, revents: c_short };
pub const POLLIN: c_short = 1;
pub const POLLOUT: c_short = 4;
pub const POLLERR: c_short = 8;
pub const POLLHUP: c_short = 0x10;
pub const POLLNVAL: c_short = 0x20;

pub const Winsize = extern struct { row: u16 = 0, col: u16 = 0, xpixel: u16 = 0, ypixel: u16 = 0 };

const c = if (supported) posix else stubs;

/// Windows: nothing is available (D15); every call fails.
const stubs = struct {
    fn write(_: c_int, _: [*]const u8, _: usize) isize {
        return -1;
    }
    fn read(_: c_int, _: [*]u8, _: usize) isize {
        return -1;
    }
    fn close(_: c_int) c_int {
        return -1;
    }
    fn open(_: [*:0]const u8, _: c_int, _: anytype) c_int {
        return -1;
    }
    fn poll(_: [*]PollFd, _: c_ulong, _: c_int) c_int {
        return -1;
    }
    fn ioctl(_: c_int, _: c_ulong, _: anytype) c_int {
        return -1;
    }
    fn isatty(_: c_int) c_int {
        return 0;
    }
    fn fcntl(_: c_int, _: c_int, _: anytype) c_int {
        return -1;
    }
    fn pipe(_: *[2]c_int) c_int {
        return -1;
    }
    fn kill(_: c_int, _: c_int) c_int {
        return -1;
    }
    fn raise(_: c_int) c_int {
        return -1;
    }
    fn getpid() c_int {
        return 0;
    }
    fn geteuid() c_uint {
        return 0;
    }
    fn tcgetattr(_: c_int, _: *std.c.termios) c_int {
        return -1;
    }
    fn tcsetattr(_: c_int, _: c_int, _: *const std.c.termios) c_int {
        return -1;
    }
    fn cfmakeraw(_: *std.c.termios) void {}
    fn clock_gettime(_: c_int, _: *std.c.timespec) c_int {
        return -1;
    }
    fn getenv(_: [*:0]const u8) ?[*:0]const u8 {
        return null;
    }
    fn _exit(_: c_int) noreturn {
        std.process.exit(1);
    }
    fn signal(_: c_int, _: usize) usize {
        return 0;
    }
    fn fork() c_int {
        return -1;
    }
    fn setsid() c_int {
        return -1;
    }
    fn chdir(_: [*:0]const u8) c_int {
        return -1;
    }
    fn dup2(_: c_int, _: c_int) c_int {
        return -1;
    }
    fn execve(_: [*:0]const u8, _: [*:null]const ?[*:0]const u8, _: [*:null]const ?[*:0]const u8) c_int {
        return -1;
    }
    fn waitpid(_: c_int, _: *c_int, _: c_int) c_int {
        return -1;
    }
    fn ttyname_r(_: c_int, _: [*]u8, _: usize) c_int {
        return -1;
    }
    fn tcgetsid(_: c_int) c_int {
        return -1;
    }
    fn select(_: c_int, _: ?*FdSet, _: ?*FdSet, _: ?*FdSet, _: ?*std.c.timeval) c_int {
        return -1;
    }
};

const posix = struct {
    extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
    extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
    extern "c" fn poll(fds: [*]PollFd, n: c_ulong, timeout: c_int) c_int;
    extern "c" fn ioctl(fd: c_int, req: c_ulong, ...) c_int;
    extern "c" fn isatty(fd: c_int) c_int;
    extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
    extern "c" fn pipe(fds: *[2]c_int) c_int;
    extern "c" fn kill(pid: c_int, sig: c_int) c_int;
    extern "c" fn raise(sig: c_int) c_int;
    extern "c" fn getpid() c_int;
    extern "c" fn geteuid() c_uint;
    extern "c" fn tcgetattr(fd: c_int, t: *std.c.termios) c_int;
    extern "c" fn tcsetattr(fd: c_int, action: c_int, t: *const std.c.termios) c_int;
    extern "c" fn cfmakeraw(t: *std.c.termios) void;
    extern "c" fn clock_gettime(clk: c_int, ts: *std.c.timespec) c_int;
    extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
    extern "c" fn _exit(code: c_int) noreturn;
    extern "c" fn signal(sig: c_int, handler: usize) usize;
    extern "c" fn fork() c_int;
    extern "c" fn setsid() c_int;
    extern "c" fn chdir(path: [*:0]const u8) c_int;
    extern "c" fn dup2(a: c_int, b: c_int) c_int;
    extern "c" fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
    extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
    extern "c" fn ttyname_r(fd: c_int, buf: [*]u8, len: usize) c_int;
    extern "c" fn tcgetsid(fd: c_int) c_int;
    extern "c" fn select(n: c_int, r: ?*FdSet, w: ?*FdSet, e: ?*FdSet, timeout: ?*std.c.timeval) c_int;
};

/// select(2)'s descriptor set: FD_SETSIZE (1024) bits on Linux and macOS.
const FdSet = extern struct {
    bits: [fd_setsize / 32]u32 = @splat(0),

    fn set(self: *FdSet, fd: fd_t) void {
        const i: usize = @intCast(fd);
        self.bits[i / 32] |= @as(u32, 1) << @intCast(i % 32);
    }
    fn isSet(self: *const FdSet, fd: fd_t) bool {
        const i: usize = @intCast(fd);
        return self.bits[i / 32] & (@as(u32, 1) << @intCast(i % 32)) != 0;
    }
};
const fd_setsize = 1024;

pub const Error = error{ Io, WouldBlock, Closed };

pub fn write(fd: fd_t, bytes: []const u8) Error!usize {
    while (true) {
        const n = c.write(fd, bytes.ptr, bytes.len);
        if (n >= 0) return @intCast(n);
        switch (errno()) {
            4 => continue, // EINTR
            11, 35 => return error.WouldBlock, // EAGAIN (Linux 11, macOS 35)
            32 => return error.Closed, // EPIPE
            else => return error.Io,
        }
    }
}

/// Writes everything, waiting for the descriptor when it is full.
pub fn writeAll(fd: fd_t, bytes: []const u8) Error!void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = write(fd, rest) catch |err| switch (err) {
            error.WouldBlock => {
                var p = [1]PollFd{.{ .fd = fd, .events = POLLOUT, .revents = 0 }};
                _ = c.poll(&p, 1, 1000);
                continue;
            },
            else => |e| return e,
        };
        rest = rest[n..];
    }
}

/// 0 is end of file.
pub fn read(fd: fd_t, buf: []u8) Error!usize {
    while (true) {
        const n = c.read(fd, buf.ptr, buf.len);
        if (n >= 0) return @intCast(n);
        switch (errno()) {
            4 => continue,
            11, 35 => return error.WouldBlock,
            else => return error.Io,
        }
    }
}

pub fn close(fd: fd_t) void {
    _ = c.close(fd);
}

/// Waits for the descriptors; returns how many are ready (0 on timeout or
/// signal).
pub fn poll(fds: []PollFd, timeout_ms: i32) usize {
    const n = c.poll(fds.ptr, @intCast(fds.len), timeout_ms);
    return if (n < 0) 0 else @intCast(n);
}

/// `poll` for a set that holds a descriptor poll(2) cannot wait on: macOS's
/// poll does not support devices and answers POLLNVAL for /dev/tty, while
/// select works. Reports POLLIN and POLLOUT only (end of file and hang-up
/// show as readable). Falls back to `poll` for a descriptor past FD_SETSIZE.
pub fn pollSelect(fds: []PollFd, timeout_ms: i32) usize {
    var r: FdSet = .{};
    var w: FdSet = .{};
    var max: fd_t = -1;
    for (fds) |*f| {
        f.revents = 0;
        if (f.fd < 0) continue;
        if (f.fd >= fd_setsize) return poll(fds, timeout_ms);
        if (f.events & POLLIN != 0) r.set(f.fd);
        if (f.events & POLLOUT != 0) w.set(f.fd);
        max = @max(max, f.fd);
    }
    var tv: std.c.timeval = .{ .sec = @divTrunc(timeout_ms, 1000), .usec = @intCast(@rem(timeout_ms, 1000) * 1000) };
    const n = c.select(max + 1, &r, &w, null, if (timeout_ms < 0) null else &tv);
    if (n <= 0) return 0;
    var ready: usize = 0;
    for (fds) |*f| {
        if (f.fd < 0) continue;
        if (f.events & POLLIN != 0 and r.isSet(f.fd)) f.revents |= POLLIN;
        if (f.events & POLLOUT != 0 and w.isSet(f.fd)) f.revents |= POLLOUT;
        if (f.revents != 0) ready += 1;
    }
    return ready;
}

/// Can poll(2) wait on `fd`? (Not /dev/tty on macOS: POLLNVAL.)
pub fn pollable(fd: fd_t) bool {
    var p = [1]PollFd{.{ .fd = fd, .events = POLLIN, .revents = 0 }};
    return c.poll(&p, 1, 0) >= 0 and p[0].revents & POLLNVAL == 0;
}

pub fn isatty(fd: fd_t) bool {
    return c.isatty(fd) == 1;
}

pub fn setCloexec(fd: fd_t) void {
    _ = c.fcntl(fd, 2, @as(c_int, 1)); // F_SETFD, FD_CLOEXEC
}

pub fn setNonblock(fd: fd_t) void {
    const o_nonblock: c_int = if (is_linux) 0o4000 else 4;
    const fl = c.fcntl(fd, 3, @as(c_int, 0)); // F_GETFL
    if (fl >= 0) _ = c.fcntl(fd, 4, fl | o_nonblock); // F_SETFL
}

/// A pipe, both ends close-on-exec: .{ read, write }.
pub fn pipe() Error![2]fd_t {
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) return error.Io;
    setCloexec(fds[0]);
    setCloexec(fds[1]);
    return fds;
}

/// Opens the controlling terminal read-write, close-on-exec; null when there
/// is none. macOS's poll(2) answers POLLNVAL for /dev/tty (it does not
/// support devices), which left the console deaf to every key; there the
/// terminal is reopened by its own name (/dev/ttysNNN, which poll does
/// support), taken from stdin, stderr or stdout when that is the same
/// terminal. Without one, /dev/tty stays and the caller waits with
/// `pollSelect` (see `pollable`).
pub fn openTty() ?fd_t {
    const o_rdwr: c_int = 2;
    const fd = c.open("/dev/tty", o_rdwr);
    if (fd < 0) return null;
    setCloexec(fd);
    if (!is_darwin or pollable(fd)) return fd;
    const o_noctty: c_int = 0x20000;
    const sid = c.tcgetsid(fd);
    for ([_]fd_t{ 0, 2, 1 }) |std_fd| {
        if (!isatty(std_fd) or c.tcgetsid(std_fd) != sid) continue;
        var name: [256]u8 = undefined;
        if (c.ttyname_r(std_fd, &name, name.len) != 0) continue;
        const real = c.open(@ptrCast(&name), o_rdwr | o_noctty);
        if (real < 0) continue;
        if (!pollable(real)) {
            close(real);
            continue;
        }
        setCloexec(real);
        close(fd);
        return real;
    }
    return fd;
}

pub fn getpid() i32 {
    return c.getpid();
}

pub fn geteuid() u32 {
    return c.geteuid();
}

pub const Sig = struct {
    pub const int: c_int = 2;
    pub const kill: c_int = 9;
    pub const term: c_int = 15;
    pub const tstp: c_int = if (is_linux) 20 else 18;
};

pub fn kill(pid: i32, sig: c_int) bool {
    return c.kill(pid, sig) == 0;
}

/// Is the process there? (kill(pid, 0): EPERM still means it is.)
pub fn pidAlive(pid: i32) bool {
    if (c.kill(pid, 0) == 0) return true;
    return errno() == 1; // EPERM
}

pub fn raise(sig: c_int) void {
    _ = c.raise(sig);
}

pub fn defaultSignal(sig: c_int) void {
    _ = c.signal(sig, 0); // SIG_DFL
}

pub fn exitNow(code: u8) noreturn {
    c._exit(code);
}

pub fn getenv(name: [:0]const u8) ?[]const u8 {
    const p = c.getenv(name.ptr) orelse return null;
    return std.mem.span(p);
}

pub fn getTermios(fd: fd_t) ?std.c.termios {
    var t: std.c.termios = undefined;
    if (c.tcgetattr(fd, &t) != 0) return null;
    return t;
}

pub fn setTermios(fd: fd_t, t: *const std.c.termios) void {
    _ = c.tcsetattr(fd, 1, t); // TCSADRAIN
}

pub fn makeRaw(t: *std.c.termios) void {
    c.cfmakeraw(t);
}

pub fn windowSize(fd: fd_t) ?Winsize {
    const req: c_ulong = if (is_linux) 0x5413 else 0x40087468;
    var ws: Winsize = .{};
    if (c.ioctl(fd, req, &ws) != 0 or ws.col == 0 or ws.row == 0) return null;
    return ws;
}

/// Milliseconds since the Unix epoch.
pub fn wallMs() i64 {
    if (!supported) return 0;
    var ts: std.c.timespec = undefined;
    if (c.clock_gettime(0, &ts) != 0) return 0;
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

pub fn monotonicMs() i64 {
    if (!supported) return 0;
    var ts: std.c.timespec = undefined;
    const clk: c_int = if (is_linux) 1 else 6;
    if (c.clock_gettime(clk, &ts) != 0) return 0;
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn errno() c_int {
    if (!supported) return 0;
    return std.c._errno().*;
}

/// Opens (creating, appending) a file for the relaunched app's output, 0600.
pub fn openAppend(path: [:0]const u8) ?fd_t {
    const flags: c_int = if (is_linux) (1 | 0o100 | 0o2000) else (1 | 0x200 | 8);
    const fd = c.open(path.ptr, flags, @as(c_uint, 0o600));
    if (fd < 0) return null;
    setCloexec(fd);
    return fd;
}

pub fn openRead(path: [:0]const u8) ?fd_t {
    const fd = c.open(path.ptr, @as(c_int, 0));
    if (fd < 0) return null;
    setCloexec(fd);
    return fd;
}

/// Starts `argv[0]` (a path) detached from this process: new session, stdin
/// from /dev/null, stdout and stderr to `out_fd`, in `cwd`. Everything is
/// prepared by the caller; the child only makes async-signal-safe calls.
/// Returns the child's pid.
pub fn spawnDetached(exe: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8, cwd: [*:0]const u8, out_fd: fd_t, null_fd: fd_t) Error!i32 {
    const pid = c.fork();
    if (pid < 0) return error.Io;
    if (pid == 0) {
        _ = c.setsid();
        _ = c.dup2(null_fd, 0);
        _ = c.dup2(out_fd, 1);
        _ = c.dup2(out_fd, 2);
        _ = c.chdir(cwd);
        _ = c.execve(exe, argv, envp);
        c._exit(127);
    }
    return pid;
}

/// Reaps `pid` if it is our child and has exited. True when it was reaped.
pub fn reap(pid: i32) bool {
    var status: c_int = 0;
    return c.waitpid(pid, &status, 1) == pid; // WNOHANG
}

test "sys: pollSelect waits like poll" {
    if (!supported) return error.SkipZigTest;
    const p = try pipe();
    defer {
        close(p[0]);
        close(p[1]);
    }
    try std.testing.expect(pollable(p[0]));
    var fds = [2]PollFd{
        .{ .fd = p[0], .events = POLLIN, .revents = 0 },
        .{ .fd = p[1], .events = POLLOUT, .revents = 0 },
    };
    try std.testing.expectEqual(@as(usize, 1), pollSelect(&fds, 0));
    try std.testing.expectEqual(@as(c_short, 0), fds[0].revents);
    try std.testing.expectEqual(POLLOUT, fds[1].revents);
    _ = try write(p[1], "x");
    fds[1].events = 0;
    try std.testing.expectEqual(@as(usize, 1), pollSelect(&fds, 1000));
    try std.testing.expectEqual(POLLIN, fds[0].revents);
}
