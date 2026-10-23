//! The pure decision behind `/full-restart` (design 8.3), used by the CLI and
//! the in-process console.
const std = @import("std");

pub const Supervisor = enum { none, systemd, container, pm2, supervisord, launchd };

pub const Situation = struct {
    /// hello.allow.full_restart
    allowed: bool,
    in_process: bool,
    /// `/full-restart --kill`
    force_kill: bool,
    /// The connection is open and the app answered recently.
    responsive: bool,
    pid_alive: bool,
    supervisor: Supervisor,
    /// launch_info was fetched at attach.
    have_launch_info: bool,
    /// false on Windows.
    exec_supported: bool,
};

pub const Refusal = enum { not_allowed, in_process_kill, no_launch_info, unsupported_platform };

pub const KillThen = enum { wait_for_supervisor, relaunch };

pub const Plan = union(enum) {
    /// Ask the app to re-exec itself (a).
    exec_in_place,
    /// SIGKILL (when the pid is alive), then wait for the supervisor or relaunch (b).
    kill: struct { send_kill: bool, then: KillThen },
    refuse: Refusal,
};

pub fn plan(s: Situation) Plan {
    if (!s.allowed) return .{ .refuse = .not_allowed };
    if (s.in_process) {
        if (s.force_kill) return .{ .refuse = .in_process_kill };
        return if (s.exec_supported) .exec_in_place else .{ .refuse = .unsupported_platform };
    }
    if (s.responsive and !s.force_kill) {
        return if (s.exec_supported) .exec_in_place else .{ .refuse = .unsupported_platform };
    }
    const then: KillThen = if (s.supervisor != .none) .wait_for_supervisor else if (s.have_launch_info) .relaunch else return .{ .refuse = .no_launch_info };
    return .{ .kill = .{ .send_kill = s.pid_alive, .then = then } };
}

/// Nothing heard from the app for `timeout_ms` (pings answered count).
pub fn wedged(now_ms: i64, last_heard_ms: i64, timeout_ms: u32) bool {
    return now_ms - last_heard_ms >= timeout_ms;
}

pub fn refusalText(r: Refusal) []const u8 {
    return switch (r) {
        .not_allowed => "this app does not allow /full-restart (console.allow_restart is off)",
        .in_process_kill => "--kill can't be used from the in-process console: it would kill the console itself; attach from another terminal with `anole console`",
        .no_launch_info => "the app does not answer and has no supervisor, and its launch command was not fetched when attaching; start it again by hand",
        .unsupported_platform => "restarting in place is not available on this operating system",
    };
}

const base: Situation = .{
    .allowed = true,
    .in_process = false,
    .force_kill = false,
    .responsive = true,
    .pid_alive = true,
    .supervisor = .none,
    .have_launch_info = true,
    .exec_supported = true,
};

fn with(comptime f: anytype) Situation {
    var s = base;
    inline for (@typeInfo(@TypeOf(f)).@"struct".field_names) |n| @field(s, n) = @field(f, n);
    return s;
}

test "restart_plan: table of situations" {
    const T = std.testing;
    try T.expectEqualDeep(Plan{ .refuse = .not_allowed }, plan(with(.{ .allowed = false })));
    try T.expectEqualDeep(Plan{ .refuse = .not_allowed }, plan(with(.{ .allowed = false, .in_process = true })));
    // In process.
    try T.expectEqualDeep(Plan.exec_in_place, plan(with(.{ .in_process = true })));
    try T.expectEqualDeep(Plan{ .refuse = .in_process_kill }, plan(with(.{ .in_process = true, .force_kill = true })));
    try T.expectEqualDeep(Plan{ .refuse = .unsupported_platform }, plan(with(.{ .in_process = true, .exec_supported = false })));
    // Attached and answering.
    try T.expectEqualDeep(Plan.exec_in_place, plan(with(.{})));
    try T.expectEqualDeep(Plan{ .refuse = .unsupported_platform }, plan(with(.{ .exec_supported = false })));
    // --kill or wedged, supervised.
    try T.expectEqualDeep(Plan{ .kill = .{ .send_kill = true, .then = .wait_for_supervisor } }, plan(with(.{ .force_kill = true, .supervisor = .systemd })));
    try T.expectEqualDeep(Plan{ .kill = .{ .send_kill = false, .then = .wait_for_supervisor } }, plan(with(.{ .responsive = false, .pid_alive = false, .supervisor = .container })));
    // Unsupervised: relaunch from the launch info, else refuse.
    try T.expectEqualDeep(Plan{ .kill = .{ .send_kill = true, .then = .relaunch } }, plan(with(.{ .responsive = false })));
    try T.expectEqualDeep(Plan{ .refuse = .no_launch_info }, plan(with(.{ .responsive = false, .have_launch_info = false })));
    // A supervisor wins over missing launch info.
    try T.expectEqualDeep(Plan{ .kill = .{ .send_kill = true, .then = .wait_for_supervisor } }, plan(with(.{ .force_kill = true, .supervisor = .pm2, .have_launch_info = false })));
}

test "restart_plan: wedged with an injected clock" {
    try std.testing.expect(!wedged(5_999, 1_000, 5_000)); // 4,999 ms
    try std.testing.expect(wedged(6_000, 1_000, 5_000)); // 5,000 ms
}
