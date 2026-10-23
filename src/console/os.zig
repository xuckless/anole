//! The few POSIX calls the console's server side makes beyond `ui.sys`:
//! a unix listener, the peer's uid, a private directory check, socketpair,
//! dup, getcwd. Windows has none of it (design D15): every call fails with
//! `error.Unsupported` there and nothing below is analysed.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("anole_console_ui");
const sys = ui.sys;

pub const supported = sys.supported;
const is_linux = builtin.os.tag == .linux;

pub const Error = error{ Unsupported, Io, PathTooLong, NotPrivate, Exists };

const posix = struct {
    extern "c" fn socket(domain: c_int, kind: c_int, protocol: c_int) c_int;
    extern "c" fn socketpair(domain: c_int, kind: c_int, protocol: c_int, fds: *[2]c_int) c_int;
    extern "c" fn bind(fd: c_int, addr: *const anyopaque, len: u32) c_int;
    extern "c" fn connect(fd: c_int, addr: *const anyopaque, len: u32) c_int;
    extern "c" fn listen(fd: c_int, backlog: c_int) c_int;
    extern "c" fn accept(fd: c_int, addr: ?*anyopaque, len: ?*u32) c_int;
    extern "c" fn getsockopt(fd: c_int, level: c_int, name: c_int, val: *anyopaque, len: *u32) c_int;
    extern "c" fn getpeereid(fd: c_int, uid: *c_uint, gid: *c_uint) c_int;
    extern "c" fn chmod(path: [*:0]const u8, mode: c_uint) c_int;
    extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
    extern "c" fn unlink(path: [*:0]const u8) c_int;
    extern "c" fn dup(fd: c_int) c_int;
    extern "c" fn dup2(a: c_int, b: c_int) c_int;
    extern "c" fn getcwd(buf: [*]u8, n: usize) ?[*:0]u8;
    extern "c" fn gethostname(buf: [*]u8, n: usize) c_int;
    extern "c" fn shutdown(fd: c_int, how: c_int) c_int;
    extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
};

fn cpath(buf: *[110:0]u8, path: []const u8) Error![*:0]const u8 {
    if (path.len >= buf.len) return error.PathTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0].ptr;
}

fn cpathBig(buf: *[std.fs.max_path_bytes:0]u8, path: []const u8) Error![*:0]const u8 {
    if (path.len >= buf.len) return error.PathTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0].ptr;
}

/// The sockaddr_un bytes for `path`, and their length.
fn sockaddr(out: *[112]u8, path: []const u8) Error!u32 {
    if (path.len > 103) return error.PathTooLong;
    @memset(out, 0);
    if (is_linux) {
        out[0] = 1; // AF_UNIX, u16 little endian (every Linux target here)
        @memcpy(out[2..][0..path.len], path);
        return @intCast(2 + path.len + 1);
    }
    out[0] = @intCast(2 + path.len + 1); // sun_len
    out[1] = 1; // AF_UNIX
    @memcpy(out[2..][0..path.len], path);
    return @intCast(2 + path.len + 1);
}

/// A listening unix stream socket at `path` (close-on-exec), mode 0600.
pub fn listenUnix(path: []const u8, backlog: u32) Error!sys.fd_t {
    if (comptime !supported) return error.Unsupported;
    const fd = posix.socket(1, 1, 0);
    if (fd < 0) return error.Io;
    errdefer sys.close(fd);
    sys.setCloexec(fd);
    var sa: [112]u8 = undefined;
    const len = try sockaddr(&sa, path);
    if (posix.bind(fd, &sa, len) != 0) return error.Io;
    var pb: [110:0]u8 = undefined;
    _ = posix.chmod(try cpath(&pb, path), 0o600);
    if (posix.listen(fd, @intCast(backlog)) != 0) return error.Io;
    return fd;
}

/// Connects to a unix stream socket (tests and the CLI's checks).
pub fn connectUnix(path: []const u8) Error!sys.fd_t {
    if (comptime !supported) return error.Unsupported;
    const fd = posix.socket(1, 1, 0);
    if (fd < 0) return error.Io;
    errdefer sys.close(fd);
    sys.setCloexec(fd);
    var sa: [112]u8 = undefined;
    const len = try sockaddr(&sa, path);
    if (posix.connect(fd, &sa, len) != 0) return error.Io;
    return fd;
}

/// Accepts one connection (the listener is polled first); close-on-exec.
pub fn accept(listener: sys.fd_t) ?sys.fd_t {
    if (comptime !supported) return null;
    const fd = posix.accept(listener, null, null);
    if (fd < 0) return null;
    sys.setCloexec(fd);
    return fd;
}

/// A connected pair of unix stream sockets.
pub fn socketpair() Error![2]sys.fd_t {
    if (comptime !supported) return error.Unsupported;
    var fds: [2]c_int = undefined;
    if (posix.socketpair(1, 1, 0, &fds) != 0) return error.Io;
    sys.setCloexec(fds[0]);
    sys.setCloexec(fds[1]);
    return fds;
}

/// The effective uid of the process on the other end, or null.
pub fn peerUid(fd: sys.fd_t) ?u32 {
    if (comptime !supported) return null;
    if (comptime is_linux) {
        var cred: extern struct { pid: i32, uid: u32, gid: u32 } = undefined;
        var len: u32 = @sizeOf(@TypeOf(cred));
        if (posix.getsockopt(fd, 1, 17, &cred, &len) != 0) return null; // SOL_SOCKET, SO_PEERCRED
        return cred.uid;
    }
    var uid: c_uint = 0;
    var gid: c_uint = 0;
    if (posix.getpeereid(fd, &uid, &gid) != 0) return null;
    return uid;
}

/// Same euid or root may talk to the console (design D4).
pub fn peerAllowed(peer_uid: u32, euid: u32) bool {
    return peer_uid == euid or peer_uid == 0;
}

pub fn shutdownWrite(fd: sys.fd_t) void {
    if (comptime !supported) return;
    _ = posix.shutdown(fd, 1);
}

pub fn dup(fd: sys.fd_t) sys.fd_t {
    if (comptime !supported) return -1;
    return posix.dup(fd);
}

pub fn dup2(from: sys.fd_t, to: sys.fd_t) void {
    if (comptime !supported) return;
    _ = posix.dup2(from, to);
}

pub fn unlink(path: []const u8) void {
    if (comptime !supported) return;
    var pb: [std.fs.max_path_bytes:0]u8 = undefined;
    _ = posix.unlink(cpathBig(&pb, path) catch return);
}

pub fn chmod(path: []const u8, mode: u32) void {
    if (comptime !supported) return;
    var pb: [std.fs.max_path_bytes:0]u8 = undefined;
    _ = posix.chmod(cpathBig(&pb, path) catch return, mode);
}

pub fn getcwd(buf: []u8) ?[]const u8 {
    if (comptime !supported) return null;
    const p = posix.getcwd(buf.ptr, buf.len) orelse return null;
    return std.mem.span(p);
}

pub fn hostname(buf: []u8) []const u8 {
    if (comptime !supported) return "";
    if (posix.gethostname(buf.ptr, buf.len) != 0) return "";
    return std.mem.sliceTo(buf, 0);
}

pub const DirCheck = enum { ok, created, not_a_directory, not_owned, too_open, missing_parent, failed };

pub const FileInfo = struct { is_dir: bool, is_socket: bool, is_symlink: bool, uid: u32, mode: u32 };

pub fn lstat(path: []const u8) ?FileInfo {
    if (comptime !supported) return null;
    var pb: [std.fs.max_path_bytes:0]u8 = undefined;
    const p = cpathBig(&pb, path) catch return null;
    var st: std.c.Stat = undefined;
    if (std.c.fstatat(std.c.AT.FDCWD, p, &st, std.c.AT.SYMLINK_NOFOLLOW) != 0) return null;
    const fmt: u32 = @as(u32, @intCast(st.mode)) & 0o170000;
    return .{
        .is_dir = fmt == 0o040000,
        .is_socket = fmt == 0o140000,
        .is_symlink = fmt == 0o120000,
        .uid = @intCast(st.uid),
        .mode = @as(u32, @intCast(st.mode)) & 0o7777,
    };
}

/// Makes `dir` (one level; the parent must exist) with mode 0700 when it is
/// missing, then checks it is a real directory (not a symlink) owned by
/// `euid` with no group or other access (design 5.1 step 3).
pub fn ensurePrivateDir(dir: []const u8, euid: u32) DirCheck {
    if (comptime !supported) return .failed;
    var pb: [std.fs.max_path_bytes:0]u8 = undefined;
    const p = cpathBig(&pb, dir) catch return .failed;
    var created = false;
    if (lstat(dir) == null) {
        if (posix.mkdir(p, 0o700) != 0) {
            // Another process may have made it meanwhile.
            if (lstat(dir) == null) return .missing_parent;
        } else created = true;
    }
    const info = lstat(dir) orelse return .failed;
    if (info.is_symlink or !info.is_dir) return .not_a_directory;
    if (info.uid != euid) return .not_owned;
    if (info.mode & 0o077 != 0) return .too_open;
    return if (created) .created else .ok;
}

/// Reads up to `buf.len` bytes of a file (procfs style), or null.
pub fn readSmall(path: []const u8, buf: []u8) ?[]const u8 {
    if (comptime !supported) return null;
    var pb: [std.fs.max_path_bytes:0]u8 = undefined;
    const p = cpathBig(&pb, path) catch return null;
    const fd = sys.openRead(p[0..path.len :0]) orelse return null;
    defer sys.close(fd);
    var n: usize = 0;
    while (n < buf.len) {
        const got = sys.read(fd, buf[n..]) catch break;
        if (got == 0) break;
        n += got;
    }
    return buf[0..n];
}

pub fn exists(path: []const u8) bool {
    return lstat(path) != null;
}

test "peerAllowed: same uid and root yes, others no" {
    try std.testing.expect(peerAllowed(1000, 1000));
    try std.testing.expect(peerAllowed(0, 1000));
    try std.testing.expect(!peerAllowed(1001, 1000));
}

test "ensurePrivateDir: created 0700, then ok; a wide one is refused" {
    if (!supported) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "/tmp/anole-os-test-{d}", .{sys.getpid()});
    _ = io;
    defer {
        var pb: [std.fs.max_path_bytes:0]u8 = undefined;
        const p = cpathBig(&pb, base) catch unreachable;
        _ = std.c.rmdir(p);
    }
    const euid = sys.geteuid();
    try std.testing.expectEqual(DirCheck.created, ensurePrivateDir(base, euid));
    try std.testing.expectEqual(DirCheck.ok, ensurePrivateDir(base, euid));
    chmod(base, 0o755);
    try std.testing.expectEqual(DirCheck.too_open, ensurePrivateDir(base, euid));
    try std.testing.expectEqual(DirCheck.not_owned, ensurePrivateDir(base, euid +% 1));
    chmod(base, 0o700);
}
