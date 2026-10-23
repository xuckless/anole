//! The few POSIX calls the console's terminal side makes, as direct libc
//! externs (Zig 0.17's std.posix no longer has write, open or close). Std-only
//! apart from libc. On Windows nothing here is analysed: the console is not
//! available there yet (design D15), and every caller checks `supported`.
const std = @import("std");
const builtin = @import("builtin");

pub const supported = builtin.os.tag != .windows;
pub const fd_t = c_int;

const is_linux = builtin.os.tag == .linux;

pub const PollFd = extern struct { fd: c_int, events: c_short, revents: c_short };
pub const POLLIN: c_short = 1;
pub const POLLOUT: c_short = 4;
pub const POLLERR: c_short = 8;
pub const POLLHUP: c_short = 0x10;

pub const Winsize = extern struct { row: u16 = 0, col: u16 = 0, xpixel: u16 = 0, ypixel: u16 = 0 };

const c = struct {
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
};

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
    const n = c.poll(fds.ptr, fds.len, timeout_ms);
    return if (n < 0) 0 else @intCast(n);
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

/// Opens /dev/tty read-write, close-on-exec; null when there is none.
pub fn openTty() ?fd_t {
    const o_rdwr: c_int = 2;
    const fd = c.open("/dev/tty", o_rdwr);
    if (fd < 0) return null;
    setCloexec(fd);
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

pub fn monotonicMs() i64 {
    var ts: std.c.timespec = undefined;
    const clk: c_int = if (is_linux) 1 else 6;
    if (c.clock_gettime(clk, &ts) != 0) return 0;
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn errno() c_int {
    return std.c._errno().*;
}
