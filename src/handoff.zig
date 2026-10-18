//! Listener hand-off: systemd socket activation (`LISTEN_FDS`), and a
//! zero-downtime restart that reuses it. On SIGUSR2 the server re-executes
//! its own binary with the listening sockets inherited and named in
//! `LISTEN_FDS`/`LISTEN_FDNAMES` (systemd's format, so one code path serves
//! both); the new process tells it through a pipe (`ANOLE_READY_FD`) when it
//! is serving, and only then does the old one stop accepting and drain.
//! Connections never see a closed port: the sockets stay open throughout.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

pub const Fd = std.posix.fd_t;
pub const max_listeners = 8;

/// The listening sockets handed to this process, with their names.
pub const Inherited = struct {
    fds: [max_listeners]Fd = undefined,
    names: [max_listeners][]const u8 = undefined,
    count: usize = 0,

    /// The socket named `name`, or the `index`-th when none is named.
    pub fn find(self: *const Inherited, name: []const u8, index: usize) ?Fd {
        for (self.names[0..self.count], 0..) |n, i| if (std.mem.eql(u8, n, name)) return self.fds[i];
        for (self.names[0..self.count]) |n| if (n.len > 0) return null;
        return if (index < self.count) self.fds[index] else null;
    }
};

/// The sockets passed in by systemd or a predecessor: `LISTEN_PID` must
/// be this process, `LISTEN_FDS` how many, starting at fd 3.
pub fn inherited(environ: std.process.Environ) ?Inherited {
    const pid_text = environ.getPosix("LISTEN_PID") orelse return null;
    const pid = std.fmt.parseInt(c.pid_t, pid_text, 10) catch return null;
    if (pid != c.getpid()) return null;
    const count = std.fmt.parseInt(usize, environ.getPosix("LISTEN_FDS") orelse return null, 10) catch return null;
    if (count == 0 or count > max_listeners) return null;
    var out: Inherited = .{ .count = count };
    var names = std.mem.splitScalar(u8, environ.getPosix("LISTEN_FDNAMES") orelse "", ':');
    for (0..count) |i| {
        out.fds[i] = @intCast(3 + i);
        out.names[i] = names.next() orelse "";
        // Ours now: not passed on to anything this process starts.
        _ = c.fcntl(out.fds[i], c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
    }
    return out;
}

/// Tells the predecessor that this process is serving, if it is waiting.
pub fn notifyReady(environ: std.process.Environ) void {
    const text = environ.getPosix("ANOLE_READY_FD") orelse return;
    const fd = std.fmt.parseInt(Fd, text, 10) catch return;
    _ = c.write(fd, "1", 1);
    _ = c.close(fd);
}

pub const Listener = struct { fd: Fd, name: []const u8 };

pub const Successor = struct {
    pid: c.pid_t,
    ready_fd: Fd,

    /// Waits up to `timeout_ms` for the successor to say it is serving,
    /// without holding the executor's thread.
    pub fn waitReady(self: Successor, io: std.Io, timeout_ms: u32) bool {
        defer _ = c.close(self.ready_fd);
        var waited: u32 = 0;
        while (waited < timeout_ms) : (waited += 50) {
            var pfd = [_]c.pollfd{.{ .fd = self.ready_fd, .events = c.POLL.IN, .revents = 0 }};
            if (c.poll(&pfd, 1, 0) > 0) {
                var byte: [1]u8 = undefined;
                return c.read(self.ready_fd, &byte, 1) == 1;
            }
            io.sleep(.fromMilliseconds(50), .awake) catch return false;
        }
        return false;
    }

    /// Stops a successor that never reported serving, so two servers do
    /// not share the sockets, and reaps it.
    pub fn abandon(self: Successor) void {
        _ = c.kill(self.pid, c.SIG.KILL);
        var status: c_int = 0;
        _ = c.waitpid(self.pid, &status, 0);
    }
};

/// Starts a new copy of this program, with the same arguments and
/// environment, holding `listeners`.
pub fn spawn(gpa: std.mem.Allocator, io: std.Io, process: std.process.Init.Minimal, listeners: []const Listener) !Successor {
    if (listeners.len == 0 or listeners.len > max_listeners) return error.TooManyListeners;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const exe = try std.process.executablePathAlloc(io, arena);
    const argv_src = process.args.vector;
    const argv = try arena.allocSentinel(?[*:0]const u8, argv_src.len, null);
    for (argv_src, 0..) |a, i| argv[i] = a;

    var pipe: [2]Fd = undefined;
    if (c.pipe(&pipe) != 0) return error.PipeFailed;
    _ = c.fcntl(pipe[0], c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
    const ready_target: Fd = @intCast(3 + listeners.len);

    // The environment, made now: after fork only async-signal-safe calls.
    var env: std.ArrayList(?[*:0]const u8) = .empty;
    for (process.environ.block.slice) |entry| {
        const e = std.mem.span(entry.?);
        if (std.mem.startsWith(u8, e, "LISTEN_") or std.mem.startsWith(u8, e, "ANOLE_READY_FD=")) continue;
        try env.append(arena, entry);
    }
    try env.append(arena, try std.fmt.allocPrintSentinel(arena, "LISTEN_FDS={d}", .{listeners.len}, 0));
    var names: std.ArrayList(u8) = .empty;
    for (listeners, 0..) |l, i| {
        if (i > 0) try names.append(arena, ':');
        try names.appendSlice(arena, l.name);
    }
    try env.append(arena, try std.fmt.allocPrintSentinel(arena, "LISTEN_FDNAMES={s}", .{names.items}, 0));
    try env.append(arena, try std.fmt.allocPrintSentinel(arena, "ANOLE_READY_FD={d}", .{ready_target}, 0));
    // Filled in by the child with its own pid.
    const pid_entry = try arena.allocSentinel(u8, "LISTEN_PID=".len + 20, 0);
    @memcpy(pid_entry[0.."LISTEN_PID=".len], "LISTEN_PID=");
    try env.append(arena, pid_entry);
    try env.append(arena, null);
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(env.items.ptr);

    var fds: [max_listeners]Fd = undefined;
    for (listeners, 0..) |l, i| fds[i] = l.fd;

    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(pipe[0]);
        _ = c.close(pipe[1]);
        return error.ForkFailed;
    }
    if (pid == 0) {
        // The child: move everything high first so the dup2s below cannot
        // close a socket still to be moved, then into place from fd 3.
        var high: [max_listeners + 1]Fd = undefined;
        for (fds[0..listeners.len], 0..) |fd, i| high[i] = c.fcntl(fd, c.F.DUPFD, @as(c_int, 100));
        high[listeners.len] = c.fcntl(pipe[1], c.F.DUPFD, @as(c_int, 100));
        for (high[0 .. listeners.len + 1], 0..) |fd, i| _ = c.dup2(fd, @intCast(3 + i));
        // LISTEN_PID=<this process>.
        var n: u64 = @intCast(c.getpid());
        var digits: [20]u8 = undefined;
        var len: usize = 0;
        while (true) {
            digits[len] = @intCast('0' + n % 10);
            len += 1;
            n /= 10;
            if (n == 0) break;
        }
        for (0..len) |i| pid_entry["LISTEN_PID=".len + i] = digits[len - 1 - i];
        pid_entry["LISTEN_PID=".len + len] = 0;
        _ = c.execve(exe.ptr, argv.ptr, envp);
        c._exit(127);
    }
    _ = c.close(pipe[1]);
    return .{ .pid = pid, .ready_fd = pipe[0] };
}

test "Inherited.find: by name, else by position" {
    var named: Inherited = .{ .count = 2 };
    named.fds[0] = 3;
    named.fds[1] = 4;
    named.names[0] = "https";
    named.names[1] = "http";
    try std.testing.expectEqual(@as(?Fd, 4), named.find("http", 0));
    try std.testing.expectEqual(@as(?Fd, 3), named.find("https", 1));
    try std.testing.expectEqual(@as(?Fd, null), named.find("grpc", 2));
    var plain: Inherited = .{ .count = 2 };
    plain.fds[0] = 3;
    plain.fds[1] = 4;
    plain.names[0] = "";
    plain.names[1] = "";
    try std.testing.expectEqual(@as(?Fd, 4), plain.find("https", 1));
}
