//! The CLI's side of `/full-restart` when the app does not answer (design
//! 8.3 b): wait for SIGKILL to take effect, wait for a supervisor to bring
//! the app back, or start it again from the `launch_info` fetched at attach.
//! The environment is held in memory only, never drawn, logged or written.
const std = @import("std");
const sys = @import("sys.zig");
const discover = @import("discover.zig");

pub const LaunchInfo = struct {
    exe: []const u8,
    argv: []const []const u8,
    cwd: []const u8,
    env: []const []const u8,

    /// From the `data` of a `launch_info` reply, copied into `arena`.
    pub fn fromData(arena: std.mem.Allocator, data: ?std.json.Value) !LaunchInfo {
        const v = data orelse return error.InvalidFrame;
        if (v != .object) return error.InvalidFrame;
        const exe = try str(arena, v.object.get("exe"));
        const cwd = try str(arena, v.object.get("cwd"));
        return .{ .exe = exe, .cwd = cwd, .argv = try strList(arena, v.object.get("argv")), .env = try strList(arena, v.object.get("env")) };
    }
};

fn str(a: std.mem.Allocator, v: ?std.json.Value) ![]const u8 {
    const x = v orelse return error.InvalidFrame;
    if (x != .string) return error.InvalidFrame;
    return a.dupe(u8, x.string);
}

fn strList(a: std.mem.Allocator, v: ?std.json.Value) ![]const []const u8 {
    const x = v orelse return &.{};
    if (x != .array) return error.InvalidFrame;
    var out: std.ArrayList([]const u8) = .empty;
    for (x.array.items) |e| {
        if (e != .string) return error.InvalidFrame;
        try out.append(a, try a.dupe(u8, e.string));
    }
    return out.toOwnedSlice(a);
}

pub const KillError = error{ NotDead, SignalFailed };

pub const Hooks = struct {
    clock: *const fn () i64 = sys.monotonicMs,
    /// Sleeps this many milliseconds.
    sleep: *const fn (ms: u32) void = defaultSleep,
};

fn defaultSleep(ms: u32) void {
    var p = [1]sys.PollFd{.{ .fd = -1, .events = 0, .revents = 0 }};
    _ = sys.poll(&p, @intCast(ms));
}

/// SIGKILL, then wait (50 ms steps, up to `timeout_ms`) until the pid is gone.
pub fn killAndWait(pid: i32, timeout_ms: u32, hooks: Hooks) KillError!void {
    if (!sys.kill(pid, sys.Sig.kill)) {
        if (!sys.pidAlive(pid)) return; // already gone
        return error.SignalFailed;
    }
    const deadline = hooks.clock() + timeout_ms;
    while (true) {
        _ = sys.reap(pid); // only matters when it is our own child
        if (!sys.pidAlive(pid)) return;
        if (hooks.clock() >= deadline) return error.NotDead;
        hooks.sleep(50);
    }
}

/// Waits for a socket named `name` with a pid other than `old_pid`. Null on
/// timeout.
pub fn waitForSocket(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8, name: []const u8, old_pid: i32, timeout_ms: u32, hooks: Hooks) !?[]u8 {
    const deadline = hooks.clock() + timeout_ms;
    while (true) {
        const entries = try discover.list(gpa, io, dir_path, .{ .alive = alive });
        defer discover.freeEntries(gpa, entries);
        for (entries) |e| {
            if (e.pid != old_pid and std.mem.eql(u8, e.name, name)) return try gpa.dupe(u8, e.path);
        }
        if (hooks.clock() >= deadline) return null;
        hooks.sleep(200);
    }
}

fn alive(_: ?*anyopaque, pid: i32) bool {
    return sys.pidAlive(pid);
}

/// Starts the app again, detached: new session, stdin /dev/null, stdout and
/// stderr appended to `out_path` (0600), in the recorded directory. Returns
/// the new pid.
pub fn relaunch(gpa: std.mem.Allocator, info: LaunchInfo, out_path: []const u8) !i32 {
    if (!sys.supported) return error.Unsupported;
    var arena_s = std.heap.ArenaAllocator.init(gpa);
    defer arena_s.deinit();
    const a = arena_s.allocator();
    const exe = try a.dupeSentinel(u8, info.exe, 0);
    const cwd = try a.dupeSentinel(u8, info.cwd, 0);
    const outz = try a.dupeSentinel(u8, out_path, 0);
    const argv = try a.allocSentinel(?[*:0]const u8, @max(info.argv.len, 1), null);
    if (info.argv.len == 0) {
        argv[0] = exe.ptr;
    } else for (info.argv, 0..) |s, i| argv[i] = (try a.dupeSentinel(u8, s, 0)).ptr;
    const envp = try a.allocSentinel(?[*:0]const u8, info.env.len, null);
    for (info.env, 0..) |s, i| envp[i] = (try a.dupeSentinel(u8, s, 0)).ptr;

    const out_fd = sys.openAppend(outz) orelse return error.OutputNotWritable;
    defer sys.close(out_fd);
    const null_fd = sys.openRead("/dev/null") orelse return error.Io;
    defer sys.close(null_fd);
    return sys.spawnDetached(exe.ptr, argv.ptr, envp.ptr, cwd.ptr, out_fd, null_fd);
}

test "relaunch: starts a program detached, output appended, then killAndWait" {
    if (!sys.supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [512]u8 = undefined;
    const n = try tmp.dir.realPath(io, &dir_buf);
    const dir = dir_buf[0..n];
    const out = try std.fmt.allocPrint(gpa, "{s}/app.out", .{dir});
    defer gpa.free(out);

    const info: LaunchInfo = .{
        .exe = "/bin/sh",
        .argv = &.{ "/bin/sh", "-c", "echo started in $PWD with $ANOLE_T; sleep 30" },
        .cwd = dir,
        .env = &.{ "ANOLE_T=yes", "PATH=/usr/bin:/bin" },
    };
    const wait = @import("anole_test_wait");
    const pid = try relaunch(gpa, info, out);
    try std.testing.expect(pid > 1);
    const hooks: Hooks = .{};
    // The child sleeps 30 s so that there is something to kill; it must
    // not outlive a failed check.
    errdefer killAndWait(pid, wait.deadlineMs(), hooks) catch {};
    // Wait for the line to appear.
    const Out = struct {
        dir: std.Io.Dir,
        io: std.Io,
        gpa: std.mem.Allocator,
        fn seen(c: @This()) bool {
            const text = c.dir.readFileAlloc(c.io, "app.out", c.gpa, .limited(4096)) catch return false;
            defer c.gpa.free(text);
            return std.mem.indexOf(u8, text, "with yes") != null;
        }
    };
    try wait.waitUntil(io, "the relaunched program wrote its line", Out{ .dir = tmp.dir, .io = io, .gpa = gpa }, Out.seen);
    try killAndWait(pid, wait.deadlineMs(), hooks);
    try std.testing.expect(!sys.pidAlive(pid));
}

/// A clock that only the fake sleep moves, so timeouts cost no wall time.
const FakeTime = struct {
    var now_ms: i64 = 0;
    fn clock() i64 {
        return now_ms;
    }
    fn sleep(ms: u32) void {
        now_ms += ms;
    }
    const hooks: Hooks = .{ .clock = clock, .sleep = sleep };
};

test "relaunch: waitForSocket finds a newer pid and times out otherwise" {
    // The console's terminal side is not on Windows yet (design D15): no pipes, no clock.
    if (!sys.supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var dir_buf: [512]u8 = undefined;
    const n = try tmp.dir.realPath(io, &dir_buf);
    const dir = dir_buf[0..n];
    // Our own pid is alive, so a socket file with it counts.
    var name_buf: [64]u8 = undefined;
    const fname = try std.fmt.bufPrint(&name_buf, "api.{d}.sock", .{sys.getpid()});
    var f = try tmp.dir.createFile(io, fname, .{});
    f.close(io);
    FakeTime.now_ms = 0;
    const found = try waitForSocket(gpa, io, dir, "api", 1, 500, FakeTime.hooks);
    defer if (found) |p| gpa.free(p);
    try std.testing.expect(found != null);
    try std.testing.expect(std.mem.endsWith(u8, found.?, fname));
    // The old pid is excluded: nothing else appears.
    FakeTime.now_ms = 0;
    const none = try waitForSocket(gpa, io, dir, "api", sys.getpid(), 300, FakeTime.hooks);
    try std.testing.expect(none == null);
    // It gave up only once its 300 ms had passed on its clock.
    try std.testing.expect(FakeTime.now_ms >= 300);
}

test "relaunch: launch_info data parses" {
    var arena_s = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_s.deinit();
    const a = arena_s.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"exe\":\"/usr/bin/app\",\"argv\":[\"app\",\"--x\"],\"cwd\":\"/srv\",\"env\":[\"A=1\"]}", .{});
    const info = try LaunchInfo.fromData(a, v);
    try std.testing.expectEqualStrings("/usr/bin/app", info.exe);
    try std.testing.expectEqual(@as(usize, 2), info.argv.len);
    try std.testing.expectEqualStrings("A=1", info.env[0]);
    try std.testing.expectError(error.InvalidFrame, LaunchInfo.fromData(a, null));
}
