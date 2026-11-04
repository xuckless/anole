//! The WebSocket admission gate (#129): a Server-wide count of open
//! WebSockets, with an optional exact cap (`ServerConfig.max_websockets`),
//! and a limit that freezes the count while any executor is overloaded.
//!
//! Each executor measures its utilization, 1 - (time asleep in its event
//! poll) / wall time, over 1 s windows (Node's event loop utilization,
//! libuv's `uv_metrics_idle_time`, tokio's per-worker busy duration),
//! from a probe in the server's per-executor trim task. An executor is
//! *hot* after `sustain` windows at `util_enter` or more (or a window whose
//! every timer tick was `lag_enter` late: CPU taken by a quota), and cools
//! after a window under `util_exit`, no sooner than `min_shed` after it
//! went hot. While any executor is hot, the Server freezes its WebSocket
//! population at the larger of (open + closed in the last window) and the
//! most that were open since the episode began: every close readmits one,
//! and a client that reconnects after a pause still fits (the board's
//! echo-ws cells). An upgrade over the limit gets 503 with a jittered
//! `Retry-After` before any WebSocket state exists (Envoy's overload
//! manager, nginx `limit_conn`, @fastify/under-pressure).
//!
//! Where the idle time comes from, per executor thread (executors are not
//! pinned to CPUs, so never per CPU):
//! - epoll and kqueue: zio's bracket around the waiting syscall
//!   (`Loop.idle_ns`, the libuv bracket).
//! - io_uring: the thread's perf task clock (`TaskClock`), read once per
//!   window: idle = wall - task clock. Opened only while the gate is
//!   enabled, and only once the server has admitted a WebSocket. The waiting `io_uring_enter` also
//!   submits, runs task_work and the softirq they raise, so its wall time
//!   is not idle time; the task clock advances whenever the thread is
//!   scheduled in, softirq included, and stops while it sleeps (perf's
//!   `task_clock_event_read`; Seastar's stall detector opens the same
//!   counter per reactor thread). Thread CPU time
//!   (`CLOCK_THREAD_CPUTIME_ID`, schedstat's `sum_exec_runtime`) leaves the
//!   softirq out under IRQ_TIME_ACCOUNTING, which caps it near 80% of a
//!   saturated core. Measured (research/s2/2a/gate129.md): under loopback
//!   traffic the task clock read 1.000 of wall time where thread CPU time
//!   read 0.803.
//! - Neither (perf denied, as under Docker's default seccomp profile or
//!   `kernel.perf_event_paranoid` above 2; another backend; not zio): no
//!   signal, so the gate never freezes. The exact cap still applies.
const std = @import("std");
const builtin = @import("builtin");
const safety = @import("anole_safety");

/// `ServerConfig.admission`.
pub const Config = struct {
    /// Freeze the WebSocket count while an executor is overloaded.
    /// `ServerConfig.max_websockets` applies either way, and epoll and
    /// kqueue executors are measured either way (`/metrics`); io_uring ones
    /// only while this is on (their task clock has a cost, `TaskClock`).
    enabled: bool = true,
    /// A window at this utilization or more counts toward going hot. 0.85
    /// fired at 91-95% of the relay's knee on both Linux backends (step 0b,
    /// bench/results/20261104-s2-measure); `util_enter_fallback` is the
    /// value to try if that turns out too early.
    util_enter: f32 = 0.85,
    /// A hot executor cools after a window under this.
    util_exit: f32 = 0.80,
    /// The backstop for an executor starved of CPU (a quota): a window
    /// whose least late timer tick was this late counts as over the line.
    lag_enter: std.Io.Duration = .fromMilliseconds(25),
    /// The measurement window.
    window: std.Io.Duration = .fromSeconds(1),
    /// Consecutive windows over the line before an executor goes hot, so a
    /// connect storm doesn't trip it.
    sustain: u8 = 3,
    /// The least time an executor stays hot; within this long after it
    /// cooled, one window over the line makes it hot again.
    min_shed: std.Io.Duration = .fromSeconds(5),
    /// A refused upgrade's `Retry-After`, in seconds, drawn uniformly from
    /// this range (full jitter).
    retry_after_s: [2]u16 = .{ 5, 15 },
};

/// The `util_enter` to fall back on if 0.85 freezes too early (the A/B's
/// rule (b)). Documentation only: not read anywhere.
pub const util_enter_fallback: f32 = 0.88;

/// The limit while nothing is frozen.
pub const no_limit = std.math.maxInt(u32);

/// Why an upgrade was refused.
pub const Refusal = enum { load, cap };

/// Where an executor's idle time comes from.
pub const Source = enum(u8) { none, poll_wall, task_clock };

/// One executor's last closed window, for `/metrics` and the console.
/// Written by its probe only.
pub const Row = struct {
    util_permille: std.atomic.Value(u32) align(64) = .init(0),
    lag_min_ns: std.atomic.Value(u64) = .init(0),
    lag_max_ns: std.atomic.Value(u64) = .init(0),
    hot: std.atomic.Value(bool) = .init(false),
    source: std.atomic.Value(Source) = .init(.none),
    /// Windows closed so far.
    windows: std.atomic.Value(u32) = .init(0),
};

/// For tests: the probe acts as if perf_event_open were denied.
pub var test_deny_task_clock: if (builtin.is_test) bool else void = if (builtin.is_test) false else {};

/// A Server's WebSocket count and limit. Lives in the Server; requests
/// reach it through `ServerConfig.Request._admission`.
pub const State = struct {
    cfg: Config = .{},
    /// `ServerConfig.max_websockets`.
    max_websockets: ?u32 = null,
    /// One per executor, while the server has run (`Server.prepareStatic`).
    rows: []Row = &.{},

    /// Open WebSockets admitted through `reserve`.
    live: std.atomic.Value(u32) = .init(0),
    /// Set by the first `reserve` that took a unit: the server has
    /// WebSockets, so an io_uring executor opens its task clock now
    /// (`TaskClock`), not at startup.
    armed: std.atomic.Value(bool) = .init(false),
    /// The most `live` has been since the current shed episode began.
    peak: std.atomic.Value(u32) = .init(0),
    /// Open WebSockets closed so far (`release`; not `unreserve`).
    closed: std.atomic.Value(u64) = .init(0),
    /// The limit while frozen, `no_limit` otherwise.
    frozen: std.atomic.Value(u32) = .init(no_limit),
    refused_load: std.atomic.Value(u64) = .init(0),
    refused_cap: std.atomic.Value(u64) = .init(0),

    /// Taken only on a row's hot/cool transitions, at most twice a window
    /// per executor: a few stores, nothing allocated, no wait.
    lock: safety.SpinLock(.leaf) = .init,
    /// Hot rows (under `lock`).
    hot_rows: u32 = 0,
    /// When the limit was last lifted, in awake-clock nanoseconds (under
    /// `lock`); null before the first freeze.
    unfrozen_at: ?u64 = null,
    /// `refused_load` when the limit froze (under `lock`), for the log line
    /// that lifts it.
    refused_at_freeze: u64 = 0,

    /// Takes one unit for an upgrade, or says why not (and counts it). Run
    /// once per upgrade, before any WebSocket state exists; `release` gives
    /// the unit back.
    pub fn reserve(s: *State) ?Refusal {
        const cap = s.max_websockets orelse no_limit;
        var live = s.live.load(.monotonic);
        while (true) {
            const frozen = s.frozen.load(.monotonic);
            if (live >= @min(cap, frozen)) {
                const why: Refusal = if (cap <= frozen) .cap else .load;
                _ = (if (why == .cap) &s.refused_cap else &s.refused_load).fetchAdd(1, .monotonic);
                return why;
            }
            live = s.live.cmpxchgWeak(live, live + 1, .monotonic, .monotonic) orelse {
                if (live + 1 > s.peak.load(.monotonic)) _ = s.peak.fetchMax(live + 1, .monotonic);
                if (!s.armed.load(.monotonic)) s.armed.store(true, .monotonic);
                return null;
            };
        }
    }

    /// Gives back the unit of a WebSocket that opened, as it closes: a
    /// close, which the freeze counts as slack.
    pub fn release(s: *State) void {
        s.unreserve();
        _ = s.closed.fetchAdd(1, .monotonic);
    }

    /// Gives back a unit `reserve` took for an upgrade that never opened
    /// (declined, failed, refused later): not a close, so the freeze's
    /// slack doesn't grow with it.
    pub fn unreserve(s: *State) void {
        const before = s.live.fetchSub(1, .monotonic);
        std.debug.assert(before > 0);
    }

    /// A row went hot at `now_ns`, with `closed_last_window` closes in its
    /// last window. Returns the limit when this froze the population.
    pub fn rowHot(s: *State, now_ns: u64, closed_last_window: u64) ?u32 {
        s.lock.lock();
        defer s.lock.unlock();
        s.hot_rows += 1;
        if (s.hot_rows != 1) return null;
        const live = s.live.load(.monotonic);
        // A fresh episode, unless this is a quick re-entry: then the
        // reconnects of those who left in the dip still fit.
        const reentry = if (s.unfrozen_at) |t| now_ns -| t < nanos(s.cfg.min_shed) else false;
        if (!reentry) s.peak.store(live, .monotonic);
        const slack = std.math.cast(u32, closed_last_window) orelse no_limit;
        const limit = @min(@max(live +| slack, s.peak.load(.monotonic)), no_limit - 1);
        s.frozen.store(limit, .monotonic);
        s.refused_at_freeze = s.refused_load.load(.monotonic);
        return limit;
    }

    /// A row cooled at `now_ns`. Returns the upgrades refused for load
    /// while frozen when this lifted the limit.
    pub fn rowCool(s: *State, now_ns: u64) ?u64 {
        s.lock.lock();
        defer s.lock.unlock();
        std.debug.assert(s.hot_rows > 0);
        s.hot_rows -= 1;
        if (s.hot_rows != 0) return null;
        s.frozen.store(no_limit, .monotonic);
        s.unfrozen_at = now_ns;
        return s.refused_load.load(.monotonic) - s.refused_at_freeze;
    }

    /// Back to unfrozen, for a server starting to serve (again). The
    /// count stays: sockets of an earlier run release into it.
    pub fn reset(s: *State) void {
        s.lock.lock();
        defer s.lock.unlock();
        s.hot_rows = 0;
        s.unfrozen_at = null;
        s.frozen.store(no_limit, .monotonic);
        s.peak.store(s.live.load(.monotonic), .monotonic);
        for (s.rows) |*r| r.hot.store(false, .monotonic);
    }

    /// For tests: freezes the population at `limit` as a hot row would,
    /// until `reset` (a probe never cools it).
    pub fn freezeForTest(s: *State, limit: u32) void {
        s.lock.lock();
        defer s.lock.unlock();
        s.hot_rows += 1;
        s.frozen.store(limit, .monotonic);
    }

    /// The limit in force: the frozen one, or null when nothing is frozen.
    pub fn frozenLimit(s: *const State) ?u32 {
        const f = s.frozen.load(.monotonic);
        return if (f == no_limit) null else f;
    }

    /// A `Retry-After` in seconds, uniform in `cfg.retry_after_s`.
    pub fn retryAfter(s: *const State, io: std.Io) u16 {
        const lo = @min(s.cfg.retry_after_s[0], s.cfg.retry_after_s[1]);
        const hi = @max(s.cfg.retry_after_s[0], s.cfg.retry_after_s[1]);
        var b: [2]u8 = undefined;
        io.random(&b);
        return lo + @as(u16, @intCast(std.mem.readInt(u16, &b, .little) % (@as(u32, hi - lo) + 1)));
    }
};

fn nanos(d: std.Io.Duration) u64 {
    return std.math.cast(u64, d.nanoseconds) orelse 0;
}

/// Whether a task that last did something at `last_ns` should do it again
/// at `now_ns`, every `every`.
pub fn due(now_ns: u64, last_ns: u64, every: std.Io.Duration) bool {
    return now_ns -| last_ns >= nanos(every);
}

/// One executor's measurement, a pure state machine (no clock, no I/O):
/// the trim task feeds it each tick's lateness, and at each window's end
/// the idle time and the close count.
pub const Probe = struct {
    cfg: Config,
    window_start: u64 = 0,
    idle_start: u64 = 0,
    closed_start: u64 = 0,
    lag_min: u64 = std.math.maxInt(u64),
    lag_max: u64 = 0,
    ticks: u32 = 0,
    /// Consecutive windows over the line.
    over: u8 = 0,
    hot: bool = false,
    hot_since: u64 = 0,
    cooled_at: ?u64 = null,

    pub const Transition = enum { none, hot, cool };

    /// What a closed window did.
    pub const Step = struct {
        transition: Transition = .none,
        util_permille: u32 = 0,
        /// The window's closes, which a freeze adds as slack.
        closed: u64 = 0,
        /// Whether the lag backstop, not utilization, put it over.
        lagged: bool = false,
    };

    /// Starts a window at `now`.
    pub fn begin(p: *Probe, now: u64, idle: u64, closed: u64) void {
        p.window_start = now;
        p.idle_start = idle;
        p.closed_start = closed;
        p.lag_min = std.math.maxInt(u64);
        p.lag_max = 0;
        p.ticks = 0;
    }

    /// One timer tick, `lateness` ns after its deadline.
    pub fn tick(p: *Probe, lateness: u64) void {
        p.lag_min = @min(p.lag_min, lateness);
        p.lag_max = @max(p.lag_max, lateness);
        p.ticks += 1;
    }

    /// Whether the window is over at `now`.
    pub fn due(p: *const Probe, now: u64) bool {
        return now -| p.window_start >= nanos(p.cfg.window);
    }

    /// Closes the window at `now`, with the loop's idle time so far (null
    /// without a source) and the State's closes so far; publishes it on
    /// `row` and starts the next one. The caller applies the transition to
    /// the State (`rowHot`, `rowCool`).
    pub fn close(p: *Probe, row: *Row, now: u64, idle: ?u64, closed: u64) Step {
        const wall = now -| p.window_start;
        defer p.begin(now, idle orelse 0, closed);
        // Nothing measured (no tick, no time): publish nothing, keep `over`.
        if (wall == 0 or p.ticks == 0) return .{};
        _ = row.windows.fetchAdd(1, .monotonic);
        row.lag_min_ns.store(p.lag_min, .monotonic);
        row.lag_max_ns.store(p.lag_max, .monotonic);
        const idle_now = idle orelse {
            // No signal (any more): the gate is off here.
            p.over = 0;
            if (!p.hot) return .{};
            p.goCool(row, now);
            return .{ .transition = .cool };
        };
        // Saturating: on io_uring the idle time is wall minus the task
        // clock, two clocks that drift apart by ppm, so a window with no
        // sleep in it can read a few ns of negative idle. That is a busy
        // window, not an idle one.
        const idle_ns = @min(idle_now -| p.idle_start, wall);
        const util_permille: u32 = @intCast(1000 - idle_ns * 1000 / wall);
        row.util_permille.store(util_permille, .monotonic);
        var step: Step = .{ .util_permille = util_permille, .closed = closed -| p.closed_start };
        if (!p.cfg.enabled) return step;

        const util = @as(f32, @floatFromInt(util_permille)) / 1000;
        const lagged = p.lag_min >= nanos(p.cfg.lag_enter);
        const over_line = util >= p.cfg.util_enter or lagged;
        p.over = if (over_line) p.over +| 1 else 0;
        if (!p.hot) {
            const reentry = if (p.cooled_at) |t| now -| t < nanos(p.cfg.min_shed) else false;
            const need: u8 = if (reentry) 1 else @max(p.cfg.sustain, 1);
            if (p.over >= need) {
                p.hot = true;
                p.hot_since = now;
                row.hot.store(true, .monotonic);
                step.transition = .hot;
                step.lagged = lagged and util < p.cfg.util_enter;
            }
        } else if (util < p.cfg.util_exit and !lagged and now -| p.hot_since >= nanos(p.cfg.min_shed)) {
            p.goCool(row, now);
            step.transition = .cool;
        }
        return step;
    }

    /// Discards the window so far (the probe ran off its executor), and
    /// starts the next one at `now`.
    pub fn discard(p: *Probe, now: u64, idle: u64, closed: u64) void {
        p.begin(now, idle, closed);
    }

    fn goCool(p: *Probe, row: *Row, now: u64) void {
        p.hot = false;
        p.over = 0;
        p.cooled_at = now;
        row.hot.store(false, .monotonic);
    }
};

/// The calling thread's perf task clock (`PERF_COUNT_SW_TASK_CLOCK`):
/// nanoseconds the thread has been scheduled in, softirq that runs while
/// it is included, sleep excluded. Opened on the thread it measures (pid
/// 0, any CPU). `exclude_kernel` lets it open at
/// `kernel.perf_event_paranoid` 2 and doesn't change what a software clock
/// counts. Close-on-exec, so a SIGUSR2 hand-off's exec doesn't inherit it.
///
/// Not free: a per-task event puts the thread's perf context on its
/// context-switch path (`perf_event_task_sched_out`/`_in`, which stop and
/// restart the clock), so an io_uring executor pays a little kernel time
/// at every park and wake, not only at the once-a-window read. Hence it
/// opens only when the gate can act (`Config.enabled`, a WebSocket
/// admitted: `State.armed`).
pub const TaskClock = struct {
    fd: i32,

    pub const OpenError = error{ AccessDenied, PermissionDenied, Unsupported, SystemResources };

    pub fn open() OpenError!TaskClock {
        if (comptime builtin.os.tag != .linux) return error.Unsupported;
        const linux = std.os.linux;
        var attr: linux.perf_event_attr = .{
            .type = .SOFTWARE,
            .config = @backingInt(linux.PERF.COUNT.SW.TASK_CLOCK),
            .flags = .{ .exclude_kernel = true, .exclude_hv = true },
        };
        const rc = linux.perf_event_open(&attr, 0, -1, -1, linux.PERF.FLAG.FD_CLOEXEC);
        return switch (linux.errno(rc)) {
            .SUCCESS => .{ .fd = @intCast(rc) },
            .ACCES => error.AccessDenied,
            .PERM => error.PermissionDenied,
            .MFILE, .NFILE, .NOMEM, .BUSY => error.SystemResources,
            else => error.Unsupported,
        };
    }

    /// The count so far, in nanoseconds.
    pub fn read(c: TaskClock) error{Unexpected}!u64 {
        if (comptime builtin.os.tag != .linux) unreachable;
        var v: u64 = 0;
        const rc = std.os.linux.read(c.fd, std.mem.asBytes(&v).ptr, @sizeOf(u64));
        if (std.os.linux.errno(rc) != .SUCCESS or rc != @sizeOf(u64)) return error.Unexpected;
        return v;
    }

    pub fn close(c: TaskClock) void {
        if (comptime builtin.os.tag != .linux) unreachable;
        _ = std.os.linux.close(c.fd);
    }
};

// ---- Tests: all with synthetic clocks and counts ----

const testing = std.testing;
const ms: u64 = std.time.ns_per_ms;
const s_ns: u64 = std.time.ns_per_s;

/// Drives a probe through whole windows at a given utilization.
const Rig = struct {
    probe: Probe,
    row: Row = .{},
    now: u64 = 0,
    idle: u64 = 0,
    closed: u64 = 0,

    fn init(cfg: Config) Rig {
        var r: Rig = .{ .probe = .{ .cfg = cfg } };
        r.probe.begin(0, 0, 0);
        return r;
    }

    /// One 1 s window of ten ticks `lateness` late, at `util`.
    fn window(r: *Rig, util: f64, lateness: u64) Probe.Step {
        for (0..10) |_| r.probe.tick(lateness);
        r.now += s_ns;
        r.idle += @intFromFloat(@round((1 - util) * @as(f64, @floatFromInt(s_ns))));
        return r.probe.close(&r.row, r.now, r.idle, r.closed);
    }
};

test "Probe: a connect storm (two windows at 1.0, then 0.5) stays cool" {
    var r: Rig = .init(.{});
    try testing.expectEqual(Probe.Transition.none, r.window(1.0, 0).transition);
    try testing.expectEqual(Probe.Transition.none, r.window(1.0, 0).transition);
    try testing.expectEqual(Probe.Transition.none, r.window(0.5, 0).transition);
    try testing.expect(!r.probe.hot);
    try testing.expectEqual(@as(u32, 500), r.row.util_permille.load(.monotonic));
}

test "Probe: three windows at 0.87 go hot, and publish util and lag" {
    var r: Rig = .init(.{});
    try testing.expectEqual(Probe.Transition.none, r.window(0.87, ms).transition);
    try testing.expectEqual(Probe.Transition.none, r.window(0.87, ms).transition);
    const step = r.window(0.87, 2 * ms);
    try testing.expectEqual(Probe.Transition.hot, step.transition);
    try testing.expect(!step.lagged);
    try testing.expectEqual(@as(u32, 870), r.row.util_permille.load(.monotonic));
    try testing.expectEqual(2 * ms, r.row.lag_min_ns.load(.monotonic));
    try testing.expect(r.row.hot.load(.monotonic));
}

test "Probe: min_shed holds a hot row, the band keeps the state, and a low window after it cools" {
    var r: Rig = .init(.{});
    for (0..3) |_| _ = r.window(0.9, 0);
    try testing.expect(r.probe.hot);
    // Hot for 1..4 s: under util_exit, but inside min_shed.
    for (0..4) |_| try testing.expectEqual(Probe.Transition.none, r.window(0.7, 0).transition);
    try testing.expect(r.probe.hot);
    // The 0.80-0.85 band keeps it hot after min_shed too.
    try testing.expectEqual(Probe.Transition.none, r.window(0.82, 0).transition);
    try testing.expect(r.probe.hot);
    try testing.expectEqual(Probe.Transition.cool, r.window(0.7, 0).transition);
    try testing.expect(!r.probe.hot);
    try testing.expect(!r.row.hot.load(.monotonic));
    // And the band keeps a cool row cool.
    for (0..5) |_| try testing.expectEqual(Probe.Transition.none, r.window(0.84, 0).transition);
}

test "Probe: quick re-entry inside min_shed after a cool-down, not after it" {
    var r: Rig = .init(.{});
    for (0..3) |_| _ = r.window(0.9, 0);
    for (0..5) |_| _ = r.window(0.5, 0);
    try testing.expect(!r.probe.hot);
    // One window over the line within 5 s of cooling: hot again.
    try testing.expectEqual(Probe.Transition.hot, r.window(0.86, 0).transition);

    var q: Rig = .init(.{});
    for (0..3) |_| _ = q.window(0.9, 0);
    for (0..5) |_| _ = q.window(0.5, 0);
    for (0..5) |_| _ = q.window(0.5, 0); // 5 s after the cool-down
    try testing.expectEqual(Probe.Transition.none, q.window(0.86, 0).transition);
    try testing.expectEqual(Probe.Transition.none, q.window(0.86, 0).transition);
    try testing.expectEqual(Probe.Transition.hot, q.window(0.86, 0).transition);
}

test "Probe: the lag backstop goes hot on a starved executor; one late tick doesn't count" {
    var r: Rig = .init(.{});
    for (0..2) |_| _ = r.window(0.1, 30 * ms);
    const step = r.window(0.1, 30 * ms);
    try testing.expectEqual(Probe.Transition.hot, step.transition);
    try testing.expect(step.lagged);

    var q: Rig = .init(.{});
    for (0..5) |_| {
        for (0..9) |_| q.probe.tick(ms);
        q.probe.tick(200 * ms);
        q.now += s_ns;
        q.idle += s_ns / 2;
        try testing.expectEqual(Probe.Transition.none, q.probe.close(&q.row, q.now, q.idle, 0).transition);
    }
    try testing.expectEqual(200 * ms, q.row.lag_max_ns.load(.monotonic));
}

test "Probe: an empty window publishes nothing and keeps the count of windows over" {
    var r: Rig = .init(.{});
    _ = r.window(0.9, 0);
    _ = r.window(0.9, 0);
    // No tick in it.
    r.now += s_ns;
    try testing.expectEqual(Probe.Transition.none, r.probe.close(&r.row, r.now, r.idle, 0).transition);
    try testing.expectEqual(@as(u32, 900), r.row.util_permille.load(.monotonic));
    try testing.expectEqual(@as(u8, 2), r.probe.over);
    try testing.expectEqual(Probe.Transition.hot, r.window(0.9, 0).transition);
}

test "Probe: idle past the wall time clamps to 0, and closes per window are reported" {
    var r: Rig = .init(.{});
    for (0..10) |_| r.probe.tick(0);
    r.now += s_ns;
    r.idle += 3 * s_ns;
    r.closed += 40;
    const step = r.probe.close(&r.row, r.now, r.idle, r.closed);
    try testing.expectEqual(@as(u32, 0), step.util_permille);
    try testing.expectEqual(@as(u64, 40), step.closed);
}

test "Probe: idle that went backwards reads as a busy window, not an idle one" {
    var r: Rig = .init(.{});
    r.idle = 10 * s_ns;
    r.probe.begin(0, r.idle, 0);
    for (0..3) |i| {
        for (0..10) |_| r.probe.tick(0);
        r.now += s_ns;
        r.idle -= 1;
        const step = r.probe.close(&r.row, r.now, r.idle, 0);
        try testing.expectEqual(@as(u32, 1000), step.util_permille);
        try testing.expectEqual(@as(u8, @intCast(i + 1)), r.probe.over);
    }
    try testing.expect(r.probe.hot);
}

test "Probe: losing the source cools a hot row and stops transitions" {
    var r: Rig = .init(.{});
    for (0..3) |_| _ = r.window(0.95, 0);
    try testing.expect(r.probe.hot);
    for (0..10) |_| r.probe.tick(30 * ms);
    r.now += s_ns;
    try testing.expectEqual(Probe.Transition.cool, r.probe.close(&r.row, r.now, null, 0).transition);
    for (0..5) |_| {
        for (0..10) |_| r.probe.tick(30 * ms);
        r.now += s_ns;
        try testing.expectEqual(Probe.Transition.none, r.probe.close(&r.row, r.now, null, 0).transition);
    }
}

test "Probe: disabled, it measures but never goes hot" {
    var r: Rig = .init(.{ .enabled = false });
    for (0..5) |_| try testing.expectEqual(Probe.Transition.none, r.window(1.0, 30 * ms).transition);
    try testing.expectEqual(@as(u32, 1000), r.row.util_permille.load(.monotonic));
}

test "due: by elapsed time, not by ticks" {
    try testing.expect(!due(4 * s_ns, 0, .fromSeconds(5)));
    try testing.expect(due(5 * s_ns, 0, .fromSeconds(5)));
    try testing.expect(due(13 * s_ns, 7 * s_ns + 1, .fromSeconds(5)));
    try testing.expect(!due(3, 5, .fromSeconds(5)));
}

fn reserveN(s: *State, n: usize) !void {
    for (0..n) |_| try testing.expectEqual(@as(?Refusal, null), s.reserve());
}

test "State: a freeze holds the count, every close readmits one, and it lifts" {
    var s: State = .{};
    try reserveN(&s, 100);
    try testing.expectEqual(@as(?u32, 100), s.rowHot(0, 0));
    try testing.expectEqual(@as(?Refusal, .load), s.reserve());
    try testing.expectEqual(@as(u64, 1), s.refused_load.load(.monotonic));
    s.release();
    try testing.expectEqual(@as(?Refusal, null), s.reserve());
    try testing.expectEqual(@as(?Refusal, .load), s.reserve());
    try testing.expectEqual(@as(?u32, 100), s.frozenLimit());
    try testing.expectEqual(@as(?u64, 2), s.rowCool(6 * s_ns));
    try testing.expectEqual(@as(?u32, null), s.frozenLimit());
    try testing.expectEqual(@as(?Refusal, null), s.reserve());
}

test "State: the closes of the last window are slack" {
    var s: State = .{};
    try reserveN(&s, 100);
    try testing.expectEqual(@as(?u32, 140), s.rowHot(0, 40));
    try reserveN(&s, 40);
    try testing.expectEqual(@as(?Refusal, .load), s.reserve());
}

test "State: two hot rows; the limit lifts only when both cool, in any order" {
    var s: State = .{};
    try reserveN(&s, 10);
    try testing.expectEqual(@as(?u32, 10), s.rowHot(0, 0));
    s.release();
    try testing.expectEqual(@as(?u32, null), s.rowHot(s_ns, 50)); // already frozen: unchanged
    try testing.expectEqual(@as(?u32, 10), s.frozenLimit());
    try testing.expectEqual(@as(?u64, null), s.rowCool(6 * s_ns));
    try testing.expectEqual(@as(?u32, 10), s.frozenLimit());
    try testing.expectEqual(@as(?u32, null), s.rowHot(7 * s_ns, 0));
    try testing.expectEqual(@as(?u64, null), s.rowCool(8 * s_ns));
    try testing.expectEqual(@as(?u64, 0), s.rowCool(9 * s_ns));
    try testing.expectEqual(@as(?u32, null), s.frozenLimit());
}

test "State: the exact cap refuses as .cap, below a frozen limit too" {
    var s: State = .{ .max_websockets = 50 };
    try reserveN(&s, 50);
    try testing.expectEqual(@as(?Refusal, .cap), s.reserve());
    _ = s.rowHot(0, 30); // limit 80, above the cap
    try testing.expectEqual(@as(?Refusal, .cap), s.reserve());
    try testing.expectEqual(@as(u64, 2), s.refused_cap.load(.monotonic));
    try testing.expectEqual(@as(u64, 0), s.refused_load.load(.monotonic));

    var t: State = .{ .max_websockets = 50 };
    try reserveN(&t, 20);
    _ = t.rowHot(0, 0); // limit 20, below the cap
    try testing.expectEqual(@as(?Refusal, .load), t.reserve());
}

test "State: replay of the board's iteration gap (Step 0b): reconnects after an idle gap fit" {
    // Iteration 2: 512 sockets, 80,000 closes in the window that froze.
    var s: State = .{};
    try reserveN(&s, 512);
    try testing.expectEqual(@as(?u32, 512 + 80_000), s.rowHot(0, 80_000));
    // The gap: everyone leaves, nothing closes in the next window.
    for (0..512) |_| s.release();
    // It cools after min_shed, then iteration 3 reconnects and it goes hot
    // again on one window with 0 closes: a quick re-entry.
    try testing.expect(s.rowCool(5 * s_ns) != null);
    try reserveN(&s, 511);
    try testing.expectEqual(@as(?u32, 512), s.rowHot(7 * s_ns, 0));
    try testing.expectEqual(@as(?Refusal, null), s.reserve());
    try testing.expectEqual(@as(?Refusal, .load), s.reserve());

    // With no cool-down in between, the old limit holds.
    var t: State = .{};
    try reserveN(&t, 512);
    _ = t.rowHot(0, 80_000);
    for (0..512) |_| t.release();
    try reserveN(&t, 4096);
    try testing.expectEqual(@as(?u32, 512 + 80_000), t.frozenLimit());
}

test "State: a fresh episode after min_shed starts its peak from the live count" {
    var s: State = .{};
    try reserveN(&s, 512);
    _ = s.rowHot(0, 0);
    for (0..512) |_| s.release();
    _ = s.rowCool(5 * s_ns);
    try reserveN(&s, 100);
    // 5 s after the cool-down: a new episode.
    try testing.expectEqual(@as(?u32, 100), s.rowHot(10 * s_ns, 0));
    try testing.expectEqual(@as(?Refusal, .load), s.reserve());
}

test "State: the board's reconnect pattern under a freeze is never refused" {
    // -c 512, each socket replaced as it retires; frozen with one window's
    // closes as slack. A replacement may reserve before the socket it
    // replaces releases, for up to `slack` sockets at once.
    const c = 512;
    const slack = 64;
    var s: State = .{};
    try reserveN(&s, c);
    _ = s.rowHot(0, slack);
    var prng: std.Random.DefaultPrng = .init(129);
    const rand = prng.random();
    var pending: u32 = 0; // replacements reserved ahead of their release
    for (0..100_000) |_| {
        if (pending < slack and rand.boolean()) {
            try testing.expectEqual(@as(?Refusal, null), s.reserve());
            pending += 1;
        } else if (pending > 0) {
            s.release();
            pending -= 1;
        } else {
            s.release();
            try testing.expectEqual(@as(?Refusal, null), s.reserve());
        }
    }
    try testing.expectEqual(@as(u64, 0), s.refused_load.load(.monotonic));
}

test "State: the first reservation arms the server, a refusal doesn't" {
    var s: State = .{ .max_websockets = 0 };
    try testing.expectEqual(@as(?Refusal, .cap), s.reserve());
    try testing.expect(!s.armed.load(.monotonic));
    s.max_websockets = null;
    try reserveN(&s, 1);
    try testing.expect(s.armed.load(.monotonic));
}

test "State: a reservation given back before its socket opened is not a close" {
    var s: State = .{};
    try reserveN(&s, 2);
    s.unreserve();
    try testing.expectEqual(@as(u64, 0), s.closed.load(.monotonic));
    s.release();
    try testing.expectEqual(@as(u64, 1), s.closed.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), s.live.load(.monotonic));
}

test "State: reset unfreezes and keeps the count" {
    var s: State = .{};
    try reserveN(&s, 3);
    s.freezeForTest(3);
    try testing.expectEqual(@as(?Refusal, .load), s.reserve());
    s.reset();
    try testing.expectEqual(@as(?u32, null), s.frozenLimit());
    try testing.expectEqual(@as(u32, 3), s.live.load(.monotonic));
    try testing.expectEqual(@as(?Refusal, null), s.reserve());
}

test "State: Retry-After stays in its range" {
    var s: State = .{};
    for (0..200) |_| {
        const v = s.retryAfter(testing.io);
        try testing.expect(v >= 5 and v <= 15);
    }
    s.cfg.retry_after_s = .{ 7, 7 };
    try testing.expectEqual(@as(u16, 7), s.retryAfter(testing.io));
}

test "TaskClock: opens (or is denied), and grows across a busy loop" {
    const c = TaskClock.open() catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied, error.Unsupported => return error.SkipZigTest,
        else => return err,
    };
    defer c.close();
    const a = try c.read();
    var x: u64 = 0;
    // Until the clock moves: a software clock reads in whole nanoseconds,
    // so a few iterations are enough; no timing assumption.
    while (true) {
        for (0..10_000) |i| x +%= i *% 2654435761;
        std.mem.doNotOptimizeAway(x);
        if (try c.read() > a) break;
    }
}
