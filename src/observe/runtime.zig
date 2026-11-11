//! Runtime gauges for `/metrics`, refreshed on every scrape:
//! `anole_runtime_tasks{executor}` (tasks alive), `anole_runtime_run_queue{executor}`,
//! `anole_runtime_stack_committed_bytes`, `anole_connections{executor}` and
//! `anole_streams{executor,protocol}`, plus `anole_io_engine{engine}`. The `anole_runtime_*` series need zio's
//! `diagnostics` option (`anole.zio_options` sets it); the connection and
//! stream counts do not.
//!
//! `refreshAdmission` adds the WebSocket admission gate's series (#129):
//! `anole_executor_utilization_permille{executor}` (the last 1 s window),
//! `anole_executor_lag_microseconds{executor,stat="min"|"max"}` (timer
//! lateness over it), `anole_executor_hot{executor}`,
//! `anole_admission_signal{executor,source}` (1 for where utilization comes
//! from: "poll_wall", "task_clock" or "none"), `anole_websockets_admitted`,
//! `anole_websockets_limit` (the frozen limit, -1 while nothing is frozen)
//! and `anole_ws_upgrades_refused_total{reason="load"|"cap"}`; and the
//! per-executor budgets' (#131): `anole_buffer_budget_held_bytes` (bytes
//! bodies and WebSocket messages hold, over every executor) and
//! `anole_requests_shed_total{reason="memory"|"tasks"}`. Integer gauges,
//! hence permille and microseconds.
const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");
const dusty = @import("dusty");
const metrics = @import("metrics.zig");
const os = @import("../console/os.zig");

/// The I/O engine `rt` runs on: "io_uring" or "epoll" on Linux (zio picks
/// io_uring and falls back to epoll when the kernel refuses a ring), else the
/// build's ("kqueue", "iocp", "poll"). Reads zio's choice from executor 0's
/// loop, which `Runtime.init` has set up before it returns.
pub fn ioEngine(rt: *zio.Runtime) []const u8 {
    if (comptime @hasDecl(zio.ev.Backend, "selectedEngine")) {
        if (rt.executors.items.len == 0) return "unknown";
        return @tagName(rt.executors.items[0].loop.backend.selectedEngine());
    }
    // zio's Linux backend picks io_uring or epoll at run time; a zio that
    // does not say which would otherwise name it "linux".
    if (comptime zio.ev.backend == .linux) return "unknown";
    return @tagName(zio.ev.backend);
}

/// Why io_uring is probably off when zio fell back to epoll. zio drops the
/// real error of `io_uring_setup`, so this is a guess from what Anole can
/// read; `refused` is what is left (a seccomp profile, a security module or a
/// kernel built without io_uring).
pub const FallbackCause = enum { disabled, group_only, kernel_too_old, refused };

pub const Kernel = struct { major: u32, minor: u32 };

/// `io_uring_disabled` is `kernel.io_uring_disabled` (null: no such sysctl,
/// before Linux 6.6); `kernel` is null when its release could not be read.
/// zio asks for DEFER_TASKRUN, so a kernel before 6.1 refuses its ring.
pub fn fallbackCause(io_uring_disabled: ?u8, kernel: ?Kernel) FallbackCause {
    if (io_uring_disabled) |d| switch (d) {
        2 => return .disabled,
        1 => return .group_only,
        else => {},
    };
    if (kernel) |k| if (k.major < 6 or (k.major == 6 and k.minor < 1)) return .kernel_too_old;
    return .refused;
}

/// The cause as a log/`/config` phrase, worded as likely.
pub fn causeText(cause: FallbackCause) []const u8 {
    return switch (cause) {
        .disabled => "likely kernel.io_uring_disabled=2",
        .group_only => "likely kernel.io_uring_disabled=1 and this process is not in kernel.io_uring_group",
        .kernel_too_old => "likely a kernel older than 6.1, which Anole's runtime needs for io_uring",
        .refused => "likely io_uring_setup was refused by a seccomp profile (Docker's default blocks io_uring) or a security module",
    };
}

/// "5.15.0-91-generic" -> 5.15.
pub fn parseKernel(release: []const u8) ?Kernel {
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, release, " \n"), '.');
    const major = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const rest = it.next() orelse return null;
    var end: usize = 0;
    while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
    const minor = std.fmt.parseInt(u32, rest[0..end], 10) catch return null;
    return .{ .major = major, .minor = minor };
}

/// The likely cause when `rt` wanted io_uring and runs on epoll (Linux, zio's
/// automatic choice); null when it runs on io_uring or never chose. Reads
/// procfs: startup only.
pub fn ioUringFallback(rt: *zio.Runtime) ?FallbackCause {
    if (comptime builtin.os.tag != .linux or zio.ev.backend != .linux) return null;
    if (!std.mem.eql(u8, ioEngine(rt), "epoll")) return null;
    var buf: [128]u8 = undefined;
    const disabled: ?u8 = if (os.readSmall("/proc/sys/kernel/io_uring_disabled", &buf)) |t|
        std.fmt.parseInt(u8, std.mem.trim(u8, t, " \n"), 10) catch null
    else
        null;
    const kernel = if (os.readSmall("/proc/sys/kernel/osrelease", &buf)) |t| parseKernel(t) else null;
    return fallbackCause(disabled, kernel);
}

/// `/config` lines for the runtime: the engine, and on a fallback the likely
/// cause.
pub fn writeConfigLines(w: *std.Io.Writer, rt: *zio.Runtime) std.Io.Writer.Error!void {
    try w.print("io_engine = {s}\n", .{ioEngine(rt)});
    if (ioUringFallback(rt)) |cause| try w.print("io_uring_unavailable = \"{s}\"\n", .{causeText(cause)});
}

/// Updates the runtime gauges in `registry` from the zio runtime behind its
/// `io` and the HTTP engines' counters. Called by `Registry.render`.
pub fn refresh(registry: *metrics.Registry) void {
    const rt = zio.Runtime.fromIo(registry.io) orelse return;
    const n = @min(rt.executorCount(), dusty.gauges.max_executors);
    var buf: [8]u8 = undefined;

    const conns = registry.gauge("anole_connections", "Open connections per executor.", &.{"executor"}) catch return;
    const streams = registry.gauge("anole_streams", "Open HTTP/2 and HTTP/3 request streams per executor.", &.{ "executor", "protocol" }) catch return;
    for (0..n) |i| {
        const id = std.fmt.bufPrint(&buf, "{d}", .{i}) catch continue;
        conns.with(&.{id}).set(dusty.gauges.get(.connections, i));
        streams.with(&.{ id, "h2" }).set(dusty.gauges.get(.h2_streams, i));
        streams.with(&.{ id, "h3" }).set(dusty.gauges.get(.h3_streams, i));
    }

    const engine = registry.gauge("anole_io_engine", "1 for the I/O engine the runtime runs on (io_uring, epoll, kqueue, iocp, poll).", &.{"engine"}) catch return;
    engine.with(&.{ioEngine(rt)}).set(1);

    if (n == 0 or rt.executorStats(0) == null) return;
    const tasks = registry.gauge("anole_runtime_tasks", "Tasks alive per executor (spawned minus finished).", &.{"executor"}) catch return;
    const queue = registry.gauge("anole_runtime_run_queue", "Tasks waiting in each executor's run queue.", &.{"executor"}) catch return;
    for (0..n) |i| {
        const st = rt.executorStats(i) orelse continue;
        const id = std.fmt.bufPrint(&buf, "{d}", .{i}) catch continue;
        tasks.with(&.{id}).set(@as(i64, @bitCast(st.spawned -% st.finished)));
        queue.with(&.{id}).set(@intCast(st.run_queue));
    }
    const stacks = registry.gauge("anole_runtime_stack_committed_bytes", "Memory held by coroutine stacks in use (a lower bound: initial committed size times stacks).", &.{}) catch return;
    stacks.with(&.{}).set(@intCast(rt.stackStats().committed_bytes));
}

/// The admission gate's series for one server's `state`.
pub fn refreshAdmission(registry: *metrics.Registry, state: *const dusty.admission.State) void {
    var buf: [8]u8 = undefined;
    const util = registry.gauge("anole_executor_utilization_permille", "Executor utilization over the last 1 s window, in thousandths: 1 - time asleep in the event poll / wall time.", &.{"executor"}) catch return;
    const lag = registry.gauge("anole_executor_lag_microseconds", "How late the executor's 100 ms probe timer fired, least and most over the last window.", &.{ "executor", "stat" }) catch return;
    const hot = registry.gauge("anole_executor_hot", "1 while the executor is over the admission gate's line.", &.{"executor"}) catch return;
    const signal = registry.gauge("anole_admission_signal", "1 for the source of the executor's utilization (poll_wall, task_clock, none).", &.{ "executor", "source" }) catch return;
    for (state.rows, 0..) |*row, i| {
        const id = std.fmt.bufPrint(&buf, "{d}", .{i}) catch continue;
        util.with(&.{id}).set(row.util_permille.load(.monotonic));
        lag.with(&.{ id, "min" }).set(@intCast(row.lag_min_ns.load(.monotonic) / std.time.ns_per_us));
        lag.with(&.{ id, "max" }).set(@intCast(row.lag_max_ns.load(.monotonic) / std.time.ns_per_us));
        hot.with(&.{id}).set(@intFromBool(row.hot.load(.monotonic)));
        const source = row.source.load(.monotonic);
        inline for (@typeInfo(dusty.admission.Source).@"enum".field_names) |name|
            signal.with(&.{ id, name }).set(@intFromBool(std.mem.eql(u8, @tagName(source), name)));
    }
    const admitted = registry.gauge("anole_websockets_admitted", "Open WebSockets counted by the admission gate.", &.{}) catch return;
    admitted.with(&.{}).set(state.live.load(.monotonic));
    const limit = registry.gauge("anole_websockets_limit", "The WebSocket count frozen under load; -1 while nothing is frozen.", &.{}) catch return;
    limit.with(&.{}).set(if (state.frozenLimit()) |l| l else -1);
    const refused = registry.counter("anole_ws_upgrades_refused_total", "WebSocket upgrades answered 503 by the admission gate.", &.{"reason"}) catch return;
    refused.with(&.{"load"}).set(state.refused_load.load(.monotonic));
    refused.with(&.{"cap"}).set(state.refused_cap.load(.monotonic));
    const held = registry.gauge("anole_buffer_budget_held_bytes", "Bytes request bodies and WebSocket messages hold of the buffer budget, over every executor.", &.{}) catch return;
    held.with(&.{}).set(@intCast(@min(state.heldBytes(), std.math.maxInt(i64))));
    const shed = registry.counter("anole_requests_shed_total", "Requests, streams and WebSocket messages refused for a per-executor budget: memory (503, close 1013) or tasks (a stream refused, an accept held).", &.{"reason"}) catch return;
    shed.with(&.{"memory"}).set(state.refused_memory.load(.monotonic));
    shed.with(&.{"tasks"}).set(state.refused_tasks.load(.monotonic));
}
