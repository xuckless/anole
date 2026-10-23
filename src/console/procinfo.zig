//! Process numbers for `/runtime` (design 6.5): resident memory, CPU time,
//! threads and open descriptors. Linux reads /proc; macOS asks
//! proc_pidinfo. Anything unavailable is 0.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("anole_console_ui");
const os = @import("os.zig");

pub const Info = struct {
    rss_bytes: u64 = 0,
    cpu_ms: u64 = 0,
    threads: u64 = 0,
    fds: u64 = 0,
    fd_limit: u64 = 0,
};

const mac = struct {
    const TaskInfo = extern struct {
        virtual_size: u64,
        resident_size: u64,
        total_user: u64,
        total_system: u64,
        threads_user: u64,
        threads_system: u64,
        policy: i32,
        faults: i32,
        pageins: i32,
        cow_faults: i32,
        messages_sent: i32,
        messages_received: i32,
        syscalls_mach: i32,
        syscalls_unix: i32,
        csw: i32,
        threadnum: i32,
        numrunning: i32,
        priority: i32,
    };
    extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, size: c_int) c_int;
};

pub fn read() Info {
    var info: Info = .{};
    if (comptime !os.supported) return info;
    if (std.posix.getrlimit(.NOFILE)) |l| info.fd_limit = @intCast(l.cur) else |_| {}
    info.cpu_ms = cpuMs();
    if (comptime builtin.os.tag == .linux) {
        var buf: [4096]u8 = undefined;
        if (os.readSmall("/proc/self/statm", &buf)) |text| {
            var it = std.mem.tokenizeScalar(u8, text, ' ');
            _ = it.next();
            if (it.next()) |rss| info.rss_bytes = (std.fmt.parseInt(u64, std.mem.trim(u8, rss, "\n "), 10) catch 0) * 4096;
        }
        if (os.readSmall("/proc/self/status", &buf)) |text| {
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "Threads:")) {
                    info.threads = std.fmt.parseInt(u64, std.mem.trim(u8, line["Threads:".len..], " \t"), 10) catch 0;
                }
            }
        }
        info.fds = countFds();
    } else if (comptime builtin.os.tag.isDarwin()) {
        var ti: mac.TaskInfo = undefined;
        const pid = ui.sys.getpid();
        if (mac.proc_pidinfo(pid, 4, 0, &ti, @sizeOf(mac.TaskInfo)) == @sizeOf(mac.TaskInfo)) {
            info.rss_bytes = ti.resident_size;
            info.threads = @intCast(@max(ti.threadnum, 0));
        }
        const bytes = mac.proc_pidinfo(pid, 1, 0, null, 0);
        if (bytes > 0) info.fds = @divTrunc(@as(u64, @intCast(bytes)), 8);
    }
    return info;
}

fn cpuMs() u64 {
    var ru: std.c.rusage = undefined;
    if (std.c.getrusage(0, &ru) != 0) return 0;
    const user = @as(u64, @intCast(ru.utime.sec)) * 1000 + @as(u64, @intCast(ru.utime.usec)) / 1000;
    const sys_ = @as(u64, @intCast(ru.stime.sec)) * 1000 + @as(u64, @intCast(ru.stime.usec)) / 1000;
    return user + sys_;
}

fn countFds() u64 {
    const io = std.Options.debug_io;
    var dir = std.Io.Dir.cwd().openDir(io, "/proc/self/fd", .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var n: u64 = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |_| n += 1;
    // The descriptor the iteration itself holds.
    return if (n > 0) n - 1 else 0;
}

test "procinfo: this process has memory, threads and descriptors" {
    if (!os.supported) return error.SkipZigTest;
    const i = read();
    try std.testing.expect(i.rss_bytes > 0);
    try std.testing.expect(i.threads > 0);
    try std.testing.expect(i.fds > 2);
    try std.testing.expect(i.fd_limit > 0);
}
