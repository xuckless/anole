//! `anole console [<name>|<pid>|<socket>] [--list] [--snapshot <view>]
//! [--wedge-timeout <seconds>]`: attaches to a running Anole app's control
//! socket (docs/console.md). Std-only plus the console's own module.
//!
//! Exit codes: 5 no app found; 6 attach refused (busy, version, permission);
//! 7 not a terminal (use --snapshot); 8 not available on this OS (Windows).
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("anole_console_ui");

const Io = std.Io;
const sys = ui.sys;

pub const exit_no_app = 5;
pub const exit_refused = 6;
pub const exit_not_tty = 7;
pub const exit_unsupported = 8;

pub const help_text =
    \\usage: anole console [<name>|<pid>|<socket path>] [options]
    \\
    \\Attaches to a running Anole app: logs, requests per route, recent 5xx,
    \\connections, databases, WebSockets, HTTP/3, runtime, config, routes.
    \\Ctrl-C leaves the console; the app keeps running.
    \\
    \\options:
    \\  --list                    list the apps with a console and exit
    \\  --snapshot <view>         print one view as JSON and exit (conns, db, ws,
    \\                            h3, runtime, config, routes, errors); needs no terminal
    \\  --wedge-timeout <secs>    seconds without an answer before the app counts as
    \\                            stuck (default 5)
    \\
    \\exit codes: 0 ok; 5 no app found; 6 refused (busy, version, permission);
    \\7 not a terminal; 8 not available on this OS.
    \\
;

pub const Args = struct {
    target: ?[]const u8 = null,
    list: bool = false,
    snapshot: ?[]const u8 = null,
    wedge_s: u32 = 5,
};

pub const ArgError = error{ UnknownOption, MissingValue, BadValue };

pub fn parseArgs(args: anytype) ArgError!Args {
    var out: Args = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--list")) {
            out.list = true;
        } else if (std.mem.eql(u8, a, "--snapshot")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            out.snapshot = args[i];
        } else if (std.mem.eql(u8, a, "--wedge-timeout")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            out.wedge_s = std.fmt.parseInt(u32, args[i], 10) catch return error.BadValue;
        } else if (std.mem.startsWith(u8, a, "--")) {
            return error.UnknownOption;
        } else out.target = a;
    }
    return out;
}

pub const Env = struct {
    ctx: ?*const anyopaque = null,
    get: *const fn (ctx: ?*const anyopaque, name: []const u8) ?[]const u8,
};

fn alive(_: ?*anyopaque, pid: i32) bool {
    return sys.pidAlive(pid);
}

fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = sys.write(1, text) catch {};
}

fn warn(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = sys.write(2, text) catch {};
}

fn socketDir(buf: []u8, env: Env) ![]const u8 {
    const vars: ui.discover.Vars = .{
        .xdg_runtime_dir = env.get(env.ctx, "XDG_RUNTIME_DIR"),
        .tmpdir = env.get(env.ctx, "TMPDIR"),
        .uid = sys.geteuid(),
        .linux = builtin.os.tag == .linux,
        .macos = builtin.os.tag.isDarwin(),
    };
    return ui.discover.defaultDir(buf, vars) catch ui.discover.fallbackDir(buf, vars.uid);
}

pub fn command(gpa: std.mem.Allocator, io: Io, args: []const [:0]const u8, env: Env) !u8 {
    if (!sys.supported) {
        warn("anole console: not available on Windows yet; use WSL2 or Docker\n", .{});
        return exit_unsupported;
    }
    const a = parseArgs(args) catch |err| {
        warn("anole console: {s}\n\n{s}", .{ switch (err) {
            error.UnknownOption => "unknown option",
            error.MissingValue => "an option needs a value (--snapshot <view>, --wedge-timeout <secs>)",
            error.BadValue => "--wedge-timeout takes a whole number of seconds",
        }, help_text });
        return 1;
    };
    var dir_buf: [256]u8 = undefined;
    const dir = socketDir(&dir_buf, env) catch "/tmp";
    const target = ui.discover.parseTarget(a.target);

    // The socket to use.
    var path_owned: ?[]u8 = null;
    defer if (path_owned) |p| gpa.free(p);
    var name_owned: ?[]u8 = null;
    defer if (name_owned) |p| gpa.free(p);
    const entries = try ui.discover.list(gpa, io, dir, .{ .alive = alive });
    defer ui.discover.freeEntries(gpa, entries);

    if (a.list) {
        if (entries.len == 0) {
            say("no Anole app with a console is running for this user (looked in {s})\n", .{dir});
            return exit_no_app;
        }
        say("{s:<24} {s:>8} {s:>10}  {s}\n", .{ "NAME", "PID", "UP", "SOCKET" });
        const now_ms = sys.wallMs();
        for (entries) |e| {
            const up_s: i64 = @max(0, @divTrunc(now_ms - @as(i64, @intCast(@divTrunc(e.mtime_ns, std.time.ns_per_ms))), 1000));
            say("{s:<24} {d:>8} {d:>9}s  {s}\n", .{ e.name, @as(u64, @intCast(@max(0, e.pid))), @as(u64, @intCast(up_s)), e.path });
        }
        return 0;
    }

    var chosen: ?ui.discover.Entry = null;
    switch (target) {
        .path => |p| path_owned = try gpa.dupe(u8, p),
        else => {
            const picked = try ui.discover.select(gpa, entries, target);
            defer gpa.free(picked);
            if (picked.len == 0) {
                warn("anole console: no Anole app with a console is running for this user (looked in {s})\n", .{dir});
                return exit_no_app;
            }
            if (picked.len == 1) {
                chosen = picked[0];
            } else {
                warn("several apps have a console:\n", .{});
                for (picked, 1..) |e, n| warn("  {d}) {s} (pid {d})\n", .{ n, e.name, e.pid });
                if (!sys.isatty(0) or !sys.isatty(2)) {
                    warn("name one (anole console <name>|<pid>)\n", .{});
                    return exit_no_app;
                }
                warn("number: ", .{});
                var line: [32]u8 = undefined;
                const n = sys.read(0, &line) catch 0;
                const choice = std.fmt.parseInt(usize, std.mem.trim(u8, line[0..n], " \r\n"), 10) catch 0;
                if (choice == 0 or choice > picked.len) return exit_no_app;
                chosen = picked[choice - 1];
            }
            path_owned = try gpa.dupe(u8, chosen.?.path);
            name_owned = try gpa.dupe(u8, chosen.?.name);
        },
    }

    if (a.snapshot) |view_name| return snapshot(gpa, io, path_owned.?, view_name);

    // Interactive.
    var term = ui.term.Terminal.open() catch |err| switch (err) {
        error.NotATerminal, error.DumbTerminal => {
            warn("anole console: needs a terminal (TERM is dumb or there is none); use --snapshot <view> for scripts\n", .{});
            return exit_not_tty;
        },
        else => {
            warn("anole console: cannot open the terminal: {t}\n", .{err});
            return exit_not_tty;
        },
    };
    defer term.close();
    installSignalHandlers();

    var path: []u8 = try gpa.dupe(u8, path_owned.?);
    defer gpa.free(path);
    var name: ?[]u8 = if (name_owned) |n| try gpa.dupe(u8, n) else null;
    defer if (name) |n| gpa.free(n);

    while (true) {
        var conn = connect(gpa, io, path) catch |err| {
            warn("anole console: cannot attach to {s}: {t}\n", .{ path, err });
            return if (err == error.Refused or err == error.Version) exit_refused else exit_no_app;
        };
        defer conn.deinit();
        const hello = conn.hello.?;
        if (name == null) name = try gpa.dupe(u8, hello.app.?.name);
        const pid = hello.app.?.pid;

        var have_launch = false;
        var launch: ?ui.relaunch.LaunchInfo = null;
        var launch_arena = std.heap.ArenaAllocator.init(gpa);
        defer launch_arena.deinit();
        if (hello.allow != null and hello.allow.?.full_restart) {
            if (fetchLaunchInfo(&conn, launch_arena.allocator())) |li| {
                launch = li;
                have_launch = true;
            }
        }

        var kill: ui.run.KillRequest = undefined;
        var kill_set: ?ui.run.KillRequest = null;
        _ = &kill;
        const exit = ui.run.run(gpa, .{
            .mode = .attach,
            .term = &term,
            .conn = &conn,
            .wedge_timeout_ms = a.wedge_s * 1000,
            .have_launch_info = have_launch,
            .kill = &kill,
        }) catch |err| {
            term.leave();
            warn("anole console: {t}\n", .{err});
            return 1;
        };
        _ = &kill_set;
        switch (exit) {
            .quit, .back_to_logs, .interrupt, .server_gone => {
                conn.close();
                return 0;
            },
            .restarted => {
                // A hand-off or exec: the successor's socket shows up with
                // another pid (hand-off) or the same path again (exec); a
                // kill restart: wait for the supervisor or relaunch.
                const sup_kind = hello.supervisor.?.kind;
                conn.close();
                if (launch != null and kill.send_kill) {
                    ui.relaunch.killAndWait(pid, 10_000, .{}) catch {};
                    if (!std.mem.eql(u8, sup_kind, "none") or kill.then == .wait_for_supervisor) {
                        // supervised: wait for it to bring the app back
                    } else {
                        var out_path_buf: [300]u8 = undefined;
                        const out_path = std.fmt.bufPrint(&out_path_buf, "{s}/{s}.out", .{ dir, name.? }) catch "/dev/null";
                        _ = ui.relaunch.relaunch(gpa, launch.?, out_path) catch {};
                    }
                }
                const wait_ms: u32 = if (kill.send_kill) 60_000 else 20_000;
                const found = ui.relaunch.waitForSocket(gpa, io, dir, name.?, if (kill.send_kill) pid else pid, wait_ms, .{}) catch null;
                if (found) |p| {
                    gpa.free(path);
                    path = p;
                    continue;
                }
                // An exec restart keeps the pid: the same path comes back.
                if (sys.pidAlive(pid)) continue;
                warn("anole console: the app did not come back\n", .{});
                return exit_no_app;
            },
        }
    }
}

fn connect(gpa: std.mem.Allocator, io: Io, path: []const u8) !ui.client.Conn {
    const addr = try Io.net.UnixAddress.init(path);
    const stream = addr.connect(io) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.Refused,
        else => return err,
    };
    const fd: sys.fd_t = @intCast(stream.socket.handle);
    var conn = ui.client.Conn.init(gpa, fd, fd);
    errdefer conn.deinit();
    conn.handshake("anole " ++ @import("cli_options").version, 5000, sys.monotonicMs) catch |err| {
        if (conn.refusal) |r| warn("anole console: {s}\n", .{r});
        conn.close();
        return switch (err) {
            error.Version => error.Version,
            error.Refused => error.Refused,
            else => err,
        };
    };
    return conn;
}

/// Sends a request and waits (up to 5 s) for its answer; the data is
/// allocated from `arena`.
fn ask(conn: *ui.client.Conn, arena: std.mem.Allocator, id: u32) ?ui.protocol.Response {
    const deadline = sys.monotonicMs() + 5000;
    conn.flush() catch return null;
    while (sys.monotonicMs() < deadline) {
        while (conn.nextFrame(arena) catch return null) |f| {
            switch (f) {
                .res => |r| if (r.id == id) return r,
                .bye => return null,
                else => {},
            }
        }
        var p = [1]sys.PollFd{.{ .fd = conn.in_fd, .events = sys.POLLIN, .revents = 0 }};
        if (sys.poll(&p, 200) > 0) {
            if (!(conn.fill() catch return null)) return null;
        }
    }
    return null;
}

fn fetchLaunchInfo(conn: *ui.client.Conn, arena: std.mem.Allocator) ?ui.relaunch.LaunchInfo {
    const id = conn.op("launch_info", null) catch return null;
    const r = ask(conn, arena, id) orelse return null;
    if (!r.ok) return null;
    return ui.relaunch.LaunchInfo.fromData(arena, r.data) catch null;
}

fn snapshot(gpa: std.mem.Allocator, io: Io, path: []const u8, view_name: []const u8) !u8 {
    const view = std.meta.stringToEnum(ui.protocol.View, view_name) orelse {
        warn("anole console: unknown view \"{s}\" (conns, db, ws, h3, runtime, config, routes, errors)\n", .{view_name});
        return 1;
    };
    var conn = connect(gpa, io, path) catch |err| {
        warn("anole console: cannot attach to {s}: {t}\n", .{ path, err });
        return if (err == error.Refused or err == error.Version) exit_refused else exit_no_app;
    };
    defer {
        conn.close();
        conn.deinit();
    }
    var arena_s = std.heap.ArenaAllocator.init(gpa);
    defer arena_s.deinit();
    const a = arena_s.allocator();
    const id = try conn.snapshot(view);
    const r = ask(&conn, a, id) orelse {
        warn("anole console: no answer\n", .{});
        return exit_no_app;
    };
    if (!r.ok) {
        warn("anole console: {s}: {s}\n", .{ r.code orelse "failed", r.message orelse "" });
        return 1;
    }
    var aw: Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(r.data orelse .null, .{ .whitespace = .indent_2 }, &aw.writer);
    try aw.writer.writeByte('\n');
    _ = sys.write(1, aw.written()) catch {};
    return 0;
}

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    ui.term.restoreNow();
    sys.exitNow(130);
}

fn installSignalHandlers() void {
    if (comptime builtin.os.tag == .windows) return;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.TERM, &act, null);
    std.posix.sigaction(.HUP, &act, null);
    // Raw mode turns Ctrl-C into a key (handled by the TUI); a SIGINT sent
    // from elsewhere still restores the terminal on its way out.
    std.posix.sigaction(.INT, &act, null);
}

test "console args" {
    const a = try parseArgs(&.{ "api", "--snapshot", "conns", "--wedge-timeout", "9" });
    try std.testing.expectEqualStrings("api", a.target.?);
    try std.testing.expectEqualStrings("conns", a.snapshot.?);
    try std.testing.expectEqual(@as(u32, 9), a.wedge_s);
    try std.testing.expect((try parseArgs(&.{"--list"})).list);
    try std.testing.expectError(error.UnknownOption, parseArgs(&.{"--nope"}));
    try std.testing.expectError(error.MissingValue, parseArgs(&.{"--snapshot"}));
}
