//! Runtime gauges for `/metrics`, refreshed on every scrape:
//! `anole_runtime_tasks{executor}` (tasks alive), `anole_runtime_run_queue{executor}`,
//! `anole_runtime_stack_committed_bytes`, `anole_connections{executor}` and
//! `anole_streams{executor,protocol}`. The `anole_runtime_*` series need zio's
//! `diagnostics` option (`anole.zio_options` sets it); the connection and
//! stream counts do not.
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
