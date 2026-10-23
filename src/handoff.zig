//! Listener hand-off: systemd socket activation (`LISTEN_FDS`), and a
//! zero-downtime restart that reuses it. On SIGUSR2 the server re-executes
//! its own binary with the listening sockets inherited and named in
//! `LISTEN_FDS`/`LISTEN_FDNAMES` (systemd's format, so one code path serves
//! both); the new process tells it through a pipe (`ANOLE_READY_FD`) when it
//! is serving, and only then does the old one stop accepting and drain.
//! Connections never see a closed port: the sockets stay open throughout.
//!
//! HTTP/3's UDP socket is passed the same way (named `h3`), with the key
//! for its stateless resets and address validation tokens through a pipe
//! of its own (`ANOLE_H3_SECRET_FD`): see `Server.run` for what happens to
//! the QUIC connections.
//!
//! Unix only: Windows has no fd inheritance by number, fork or SIGUSR2.
//! There `supported` is false, nothing is ever inherited, and `spawn` fails
//! with `error.Unsupported` (the server never calls it there).
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const sd_notify = @import("sd_notify.zig");

/// False on Windows (see above).
pub const supported = builtin.os.tag != .windows;

pub const Fd = std.posix.fd_t;
/// Room for `max_tcp_listeners` TCP listeners and an HTTP/3 socket per
/// core.
pub const max_listeners = max_tcp_listeners + 255;
pub const max_tcp_listeners = 64;

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

    /// Every socket named `name`, in order, into `buf`; when none is
    /// named, the ones from the `index`-th on. Several sockets of one
    /// SO_REUSEPORT group (HTTP/3's, `h3`) come in the order their first
    /// owner bound them in, which the predecessor keeps.
    pub fn findAll(self: *const Inherited, name: []const u8, index: usize, buf: []Fd) []Fd {
        var n: usize = 0;
        for (self.names[0..self.count], self.fds[0..self.count]) |nm, fd| {
            if (!std.mem.eql(u8, nm, name) or n == buf.len) continue;
            buf[n] = fd;
            n += 1;
        }
        if (n > 0) return buf[0..n];
        for (self.names[0..self.count]) |nm| if (nm.len > 0) return buf[0..0];
        for (self.fds[@min(index, self.count)..self.count]) |fd| {
            if (n == buf.len) break;
            buf[n] = fd;
            n += 1;
        }
        return buf[0..n];
    }
};

/// The sockets passed in by systemd or a predecessor: `LISTEN_PID` must
/// be this process, `LISTEN_FDS` how many, starting at fd 3.
pub fn inherited(environ: std.process.Environ) ?Inherited {
    if (comptime !supported) return null;
    const out = parseListenEnv(
        environ.getPosix("LISTEN_PID"),
        environ.getPosix("LISTEN_FDS"),
        environ.getPosix("LISTEN_FDNAMES"),
        c.getpid(),
    ) orelse return null;
    // Ours now: not passed on to anything this process starts.
    for (out.fds[0..out.count]) |fd| _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
    return out;
}

pub const SocketKind = enum {
    /// A listening TCP or unix stream socket.
    listener,
    /// A UDP socket (HTTP/3).
    datagram,
};

/// Checks that an inherited `fd` is what it is to be used as: a socket of
/// `kind` (listening, for a stream), of an IP family when `ip`, else a unix
/// one. A wrong descriptor at 3.. (another unit's socket, a file, a stale
/// `LISTEN_FDS`) is refused at start rather than served on.
pub fn checkInherited(fd: Fd, kind: SocketKind, ip: bool) error{InheritedSocketMismatch}!void {
    if (comptime !supported) return;
    var storage: c.sockaddr.storage = undefined;
    var len: c.socklen_t = @sizeOf(c.sockaddr.storage);
    if (c.getsockname(fd, @ptrCast(&storage), &len) != 0) return error.InheritedSocketMismatch;
    const family = storage.family;
    const family_ok = if (ip) family == c.AF.INET or family == c.AF.INET6 else family == c.AF.UNIX;
    if (!family_ok) return error.InheritedSocketMismatch;
    var typ: c_int = 0;
    var typ_len: c.socklen_t = @sizeOf(c_int);
    if (c.getsockopt(fd, c.SOL.SOCKET, c.SO.TYPE, &typ, &typ_len) != 0) return error.InheritedSocketMismatch;
    switch (kind) {
        .listener => {
            if (typ != c.SOCK.STREAM) return error.InheritedSocketMismatch;
            // Whether it listens: Linux answers SO_ACCEPTCONN; macOS does
            // not (ENOPROTOOPT), so there the type has to do.
            if (comptime builtin.os.tag != .linux) return;
            var listening: c_int = 0;
            var l_len: c.socklen_t = @sizeOf(c_int);
            if (c.getsockopt(fd, c.SOL.SOCKET, c.SO.ACCEPTCONN, &listening, &l_len) != 0 or listening == 0)
                return error.InheritedSocketMismatch;
        },
        .datagram => if (typ != c.SOCK.DGRAM or !ip) return error.InheritedSocketMismatch,
    }
}

/// What `LISTEN_PID`, `LISTEN_FDS` and `LISTEN_FDNAMES` say to the process
/// `self_pid`; the names are slices of `names_text`.
fn parseListenEnv(pid_text: ?[]const u8, fds_text: ?[]const u8, names_text: ?[]const u8, self_pid: c.pid_t) ?Inherited {
    if (comptime !supported) return null;
    const pid = std.fmt.parseInt(c.pid_t, pid_text orelse return null, 10) catch return null;
    if (pid != self_pid) return null;
    const count = std.fmt.parseInt(usize, fds_text orelse return null, 10) catch return null;
    if (count == 0 or count > max_listeners) return null;
    var out: Inherited = .{ .count = count };
    var names = std.mem.splitScalar(u8, names_text orelse "", ':');
    for (0..count) |i| {
        out.fds[i] = @intCast(3 + i);
        out.names[i] = names.next() orelse "";
    }
    return out;
}

/// The HTTP/3 endpoint's secret, if the predecessor passed one: read once,
/// and its pipe closed. Only when the sockets were passed to this process
/// (`inherited` is not null), so a stale variable cannot name some other
/// file.
pub fn inheritedSecret(environ: std.process.Environ) ?[32]u8 {
    if (comptime !supported) return null;
    const text = environ.getPosix("ANOLE_H3_SECRET_FD") orelse return null;
    const fd = std.fmt.parseInt(Fd, text, 10) catch return null;
    defer _ = c.close(fd);
    var secret: [32]u8 = undefined;
    var got: usize = 0;
    while (got < secret.len) {
        const n = c.read(fd, secret[got..].ptr, secret.len - got);
        if (n <= 0) return null;
        got += @intCast(n);
    }
    return secret;
}

/// Whether a predecessor started this process and waits for it to serve.
pub fn isSuccessor(environ: std.process.Environ) bool {
    if (comptime !supported) return false;
    return environ.getPosix("ANOLE_READY_FD") != null;
}

/// Tells the predecessor that this process is serving, if it is waiting.
pub fn notifyReady(environ: std.process.Environ) void {
    if (comptime !supported) return;
    const text = environ.getPosix("ANOLE_READY_FD") orelse return;
    const fd = std.fmt.parseInt(Fd, text, 10) catch return;
    _ = c.write(fd, "1", 1);
    _ = c.close(fd);
}

pub const Listener = struct { fd: Fd, name: []const u8 };

pub const Successor = struct {
    pid: c.pid_t,
    ready_fd: Fd,

    /// Waits up to `timeout` for the successor to say it is serving,
    /// without holding the executor's thread.
    pub fn waitReady(self: Successor, io: std.Io, timeout: std.Io.Duration) bool {
        if (comptime !supported) unreachable; // `spawn` never made one
        defer _ = c.close(self.ready_fd);
        const timeout_ms: u64 = @intCast(@max(timeout.toMilliseconds(), 0));
        var waited: u64 = 0;
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
        if (comptime !supported) unreachable; // `spawn` never made one
        _ = c.kill(self.pid, c.SIG.KILL);
        var status: c_int = 0;
        _ = c.waitpid(self.pid, &status, 0);
    }
};

/// Starts a new copy of this program, with the same arguments and
/// environment, holding `listeners`, and `h3_secret` if given.
pub fn spawn(gpa: std.mem.Allocator, io: std.Io, process: std.process.Init.Minimal, listeners: []const Listener, h3_secret: ?*const [32]u8) !Successor {
    if (comptime !supported) return error.Unsupported;
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
    _ = c.fcntl(pipe[1], c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
    const ready_target: Fd = @intCast(3 + listeners.len);
    // The secret waits in a pipe of its own (32 bytes fit any pipe's
    // buffer), not in the environment, which other processes may read.
    var secret_pipe: [2]Fd = .{ -1, -1 };
    if (h3_secret) |secret| {
        if (c.pipe(&secret_pipe) != 0) {
            _ = c.close(pipe[0]);
            _ = c.close(pipe[1]);
            return error.PipeFailed;
        }
        for (secret_pipe) |fd| _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
        const written = c.write(secret_pipe[1], secret, secret.len);
        _ = c.close(secret_pipe[1]);
        if (written != secret.len) {
            _ = c.close(secret_pipe[0]);
            _ = c.close(pipe[0]);
            _ = c.close(pipe[1]);
            return error.PipeFailed;
        }
    }
    defer if (secret_pipe[0] >= 0) {
        _ = c.close(secret_pipe[0]);
    };
    const passed: usize = listeners.len + 1 + @intFromBool(h3_secret != null);

    // The environment, made now: after fork only async-signal-safe calls.
    var env: std.ArrayList(?[*:0]const u8) = .empty;
    for (process.environ.block.slice) |entry| {
        const e = std.mem.span(entry.?);
        if (std.mem.startsWith(u8, e, "LISTEN_") or std.mem.startsWith(u8, e, "ANOLE_READY_FD=") or
            std.mem.startsWith(u8, e, "ANOLE_H3_SECRET_FD=") or std.mem.eql(u8, e, sd_notify.placeholder)) continue;
        try env.append(arena, entry);
    }
    // systemd's socket, which this process took out of its own environment
    // (`sd_notify.take`): the successor reports to it.
    if (sd_notify.taken()) |path|
        try env.append(arena, try std.fmt.allocPrintSentinel(arena, "NOTIFY_SOCKET={s}", .{path}, 0));
    try env.append(arena, try std.fmt.allocPrintSentinel(arena, "LISTEN_FDS={d}", .{listeners.len}, 0));
    var names: std.ArrayList(u8) = .empty;
    for (listeners, 0..) |l, i| {
        if (i > 0) try names.append(arena, ':');
        try names.appendSlice(arena, l.name);
    }
    try env.append(arena, try std.fmt.allocPrintSentinel(arena, "LISTEN_FDNAMES={s}", .{names.items}, 0));
    try env.append(arena, try std.fmt.allocPrintSentinel(arena, "ANOLE_READY_FD={d}", .{ready_target}, 0));
    if (h3_secret != null)
        try env.append(arena, try std.fmt.allocPrintSentinel(arena, "ANOLE_H3_SECRET_FD={d}", .{ready_target + 1}, 0));
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
        var high: [max_listeners + 2]Fd = undefined;
        for (fds[0..listeners.len], 0..) |fd, i| high[i] = c.fcntl(fd, c.F.DUPFD, @as(c_int, 100));
        high[listeners.len] = c.fcntl(pipe[1], c.F.DUPFD, @as(c_int, 100));
        if (h3_secret != null) high[listeners.len + 1] = c.fcntl(secret_pipe[0], c.F.DUPFD, @as(c_int, 100));
        // dup2 clears close-on-exec on the copies at 3...
        for (high[0..passed], 0..) |fd, i| _ = c.dup2(fd, @intCast(3 + i));
        // ...and the copies at 100.. would otherwise stay open in the new
        // program (F_DUPFD does not copy the flag), holding the sockets.
        for (high[0..passed]) |fd| _ = c.close(fd);
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
    if (comptime !supported) return error.SkipZigTest; // file descriptors by number: Unix only
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

test "Inherited.findAll: every socket of a name in order, else the rest by position" {
    if (comptime !supported) return error.SkipZigTest; // file descriptors by number: Unix only
    var named: Inherited = .{ .count = 5 };
    const names = [_][]const u8{ "http", "h3", "https", "h3", "h3" };
    for (0..5) |i| {
        named.fds[i] = @intCast(3 + i);
        named.names[i] = names[i];
    }
    var buf: [8]Fd = undefined;
    try std.testing.expectEqualSlices(Fd, &.{ 4, 6, 7 }, named.findAll("h3", 2, &buf));
    try std.testing.expectEqualSlices(Fd, &.{5}, named.findAll("https", 1, &buf));
    try std.testing.expectEqualSlices(Fd, &.{}, named.findAll("grpc", 0, &buf));
    var small: [2]Fd = undefined;
    try std.testing.expectEqualSlices(Fd, &.{ 4, 6 }, named.findAll("h3", 2, &small));
    var plain: Inherited = .{ .count = 4 };
    for (0..4) |i| {
        plain.fds[i] = @intCast(3 + i);
        plain.names[i] = "";
    }
    try std.testing.expectEqualSlices(Fd, &.{ 5, 6 }, plain.findAll("h3", 2, &buf));
    try std.testing.expectEqualSlices(Fd, &.{}, plain.findAll("h3", 4, &buf));
}

test "inheritedSecret: 32 bytes from the pipe a predecessor names, once" {
    if (comptime !supported) return error.SkipZigTest; // file descriptors by number: Unix only
    var p: [2]Fd = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&p));
    defer _ = c.close(p[1]);
    var secret: [32]u8 = undefined;
    for (&secret, 0..) |*b, i| b.* = @intCast(i * 7);
    try std.testing.expectEqual(@as(isize, 32), c.write(p[1], &secret, secret.len));

    var entry_buf: [32]u8 = undefined;
    const entry = try std.fmt.bufPrintSentinel(&entry_buf, "ANOLE_H3_SECRET_FD={d}", .{p[0]}, 0);
    const entries = [_:null]?[*:0]const u8{ "ANOLE_READY_FD=9", entry.ptr };
    const environ: std.process.Environ = .{ .block = .{ .slice = &entries } };
    try std.testing.expect(isSuccessor(environ));
    try std.testing.expectEqualSlices(u8, &secret, &(inheritedSecret(environ).?));
    // Its read end is closed now.
    try std.testing.expect(c.fcntl(p[0], c.F.GETFD) < 0);

    const none: std.process.Environ = .{ .block = .{ .slice = &[_:null]?[*:0]const u8{"PATH=/bin"} } };
    try std.testing.expect(inheritedSecret(none) == null);
    try std.testing.expect(!isSuccessor(none));
}

test "checkInherited: only a socket of the kind it is to be used as" {
    if (comptime !supported) return error.SkipZigTest;
    var addr: c.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    const tcp = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    defer _ = c.close(tcp);
    try std.testing.expect(c.bind(tcp, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) == 0);
    // Bound, not yet listening: refused (where the system says).
    if (builtin.os.tag == .linux) try std.testing.expectError(error.InheritedSocketMismatch, checkInherited(tcp, .listener, true));
    try std.testing.expect(c.listen(tcp, 1) == 0);
    try checkInherited(tcp, .listener, true);
    try std.testing.expectError(error.InheritedSocketMismatch, checkInherited(tcp, .listener, false));
    try std.testing.expectError(error.InheritedSocketMismatch, checkInherited(tcp, .datagram, true));

    const udp = c.socket(c.AF.INET, c.SOCK.DGRAM, 0);
    defer _ = c.close(udp);
    try std.testing.expect(c.bind(udp, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) == 0);
    try checkInherited(udp, .datagram, true);
    try std.testing.expectError(error.InheritedSocketMismatch, checkInherited(udp, .listener, true));

    // Not a socket at all, and no descriptor.
    var fds: [2]Fd = undefined;
    try std.testing.expect(c.pipe(&fds) == 0);
    defer for (fds) |fd| {
        _ = c.close(fd);
    };
    try std.testing.expectError(error.InheritedSocketMismatch, checkInherited(fds[0], .listener, true));
    try std.testing.expectError(error.InheritedSocketMismatch, checkInherited(-1, .datagram, true));
}

test "fuzz: LISTEN_PID, LISTEN_FDS and LISTEN_FDNAMES" {
    if (comptime !supported) return error.SkipZigTest; // file descriptors by number: Unix only
    try @import("fuzz.zig").bytes(struct {
        fn check(input: []const u8) !void {
            // The three values, newline-separated; a missing one is unset.
            var parts = std.mem.splitScalar(u8, input, '\n');
            const pid = parts.next();
            const fds = parts.next();
            const names = parts.next();
            const got = parseListenEnv(pid, fds, names, 4242) orelse return;
            try std.testing.expectEqual(@as(c.pid_t, 4242), std.fmt.parseInt(c.pid_t, pid.?, 10) catch unreachable);
            try std.testing.expect(got.count >= 1 and got.count <= max_listeners);
            try std.testing.expectEqual(got.count, std.fmt.parseInt(usize, fds.?, 10) catch unreachable);
            for (got.fds[0..got.count], got.names[0..got.count], 0..) |fd, name, i| {
                try std.testing.expectEqual(@as(Fd, @intCast(3 + i)), fd);
                try std.testing.expect(std.mem.indexOfScalar(u8, name, ':') == null);
                // A name given twice finds the first.
                const first = for (got.names[0..got.count], 0..) |n, j| {
                    if (std.mem.eql(u8, n, name)) break j;
                } else unreachable;
                if (name.len > 0) try std.testing.expectEqual(@as(?Fd, got.fds[first]), got.find(name, 0));
                if (first == i) try std.testing.expectEqual(@as(?Fd, fd), got.find(name, i));
            }
            // By position only when nothing is named.
            const named = for (got.names[0..got.count]) |n| {
                if (n.len > 0) break true;
            } else false;
            try std.testing.expectEqual(if (named) null else @as(?Fd, 3), got.find("\x00none", 0));
        }
    }.check, &.{
        "4242\n2\nhttps:http",
        "4242\n1",
        "4242\n3\nhttp::",
        "4243\n1\nhttp",
        "4242\n9\n",
        "+4242\n0x2\nhttp",
    });
}
