//! Runtime gauges for `/metrics`, refreshed on every scrape:
//! `anole_runtime_tasks{executor}` (tasks alive), `anole_runtime_run_queue{executor}`,
//! `anole_runtime_stack_committed_bytes`, `anole_connections{executor}` and
//! `anole_streams{executor,protocol}`. The `anole_runtime_*` series need zio's
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
//! and `anole_ws_upgrades_refused_total{reason="load"|"cap"}`. Integer
//! gauges, hence permille and microseconds.
//!
//! `refreshStaticCache` adds the static file cache's (K7):
//! `anole_static_cache_{hits,misses,fills,swept}_total`,
//! `anole_static_cache_skipped_total{reason}` and `anole_static_cache_bytes`.
const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");
const metrics = @import("metrics.zig");

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
}

/// The static file cache's series (`http/core/server/static_cache.zig`).
pub fn refreshStaticCache(registry: *metrics.Registry, s: dusty.static_cache.Stats) void {
    const hits = registry.counter("anole_static_cache_hits_total", "Static file requests served from the static file cache.", &.{}) catch return;
    hits.with(&.{}).set(s.hits);
    const misses = registry.counter("anole_static_cache_misses_total", "Requests for a file the static file cache held that went to the file: it changed, or the client took another encoding.", &.{}) catch return;
    misses.with(&.{}).set(s.misses);
    const fills = registry.counter("anole_static_cache_fills_total", "Files read into the static file cache.", &.{}) catch return;
    fills.with(&.{}).set(s.fills);
    const swept = registry.counter("anole_static_cache_swept_total", "Entries the trim loop dropped because their file changed or went away.", &.{}) catch return;
    swept.with(&.{}).set(s.swept);
    const skipped = registry.counter("anole_static_cache_skipped_total", "Files served but not kept, by reason: budget, table, racy (changed in the last 2 s), retire, fs (not a local filesystem), changed (while read).", &.{"reason"}) catch return;
    inline for (@typeInfo(dusty.static_cache.Skip).@"enum".field_names, 0..) |name, i| skipped.with(&.{name}).set(s.skipped[i]);
    const bytes = registry.gauge("anole_static_cache_bytes", "Bytes the static file cache holds, against ServerOptions.static_cache.bytes.", &.{}) catch return;
    bytes.with(&.{}).set(@intCast(s.bytes));
}
