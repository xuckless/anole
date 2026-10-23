//! The client's Prometheus series:
//! `anole_kafka_produced_total{client,topic}`,
//! `anole_kafka_produce_errors_total{client,error}`,
//! `anole_kafka_buffer_bytes{client}`,
//! `anole_kafka_consumed_total{client,group,topic}`,
//! `anole_kafka_consumer_lag{client,group,topic,partition}`,
//! `anole_kafka_rebalances_total{client,group}` and
//! `anole_kafka_dead_lettered_total{client,group,topic}`.
const std = @import("std");
const observe = @import("../observe/root.zig");

const metrics = observe.metrics;

pub const Telemetry = struct {
    client: []const u8,
    produced: *metrics.Family(metrics.Counter),
    produce_errors: *metrics.Family(metrics.Counter),
    buffer: *metrics.Gauge,
    consumed: *metrics.Family(metrics.Counter),
    lag: *metrics.Family(metrics.Gauge),
    rebalances: *metrics.Family(metrics.Counter),
    dead_lettered: *metrics.Family(metrics.Counter),

    /// `client` must outlive the registry.
    pub fn init(registry: *metrics.Registry, client: []const u8) !Telemetry {
        return .{
            .client = client,
            .produced = try registry.counter("anole_kafka_produced_total", "Records delivered to Kafka.", &.{ "client", "topic" }),
            .produce_errors = try registry.counter("anole_kafka_produce_errors_total", "Records whose delivery failed.", &.{ "client", "error" }),
            .buffer = (try registry.gauge("anole_kafka_buffer_bytes", "Bytes buffered for the producer and not yet acknowledged.", &.{"client"})).with(&.{client}),
            .consumed = try registry.counter("anole_kafka_consumed_total", "Records handed to consumer handlers.", &.{ "client", "group", "topic" }),
            .lag = try registry.gauge("anole_kafka_consumer_lag", "Records between a partition's end and the consumer's position.", &.{ "client", "group", "topic", "partition" }),
            .rebalances = try registry.counter("anole_kafka_rebalances_total", "Consumer group rebalances this member joined.", &.{ "client", "group" }),
            .dead_lettered = try registry.counter("anole_kafka_dead_lettered_total", "Records sent to a dead letter topic.", &.{ "client", "group", "topic" }),
        };
    }

    pub fn deliveredOne(t: *const Telemetry, topic: []const u8) void {
        t.produced.with(&.{ t.client, topic }).inc();
    }
    pub fn failedOne(t: *const Telemetry, code: []const u8) void {
        t.produce_errors.with(&.{ t.client, code }).inc();
    }
    pub fn consumedOne(t: *const Telemetry, group: []const u8, topic: []const u8) void {
        t.consumed.with(&.{ t.client, group, topic }).inc();
    }
    pub fn rebalanced(t: *const Telemetry, group: []const u8) void {
        t.rebalances.with(&.{ t.client, group }).inc();
    }
    pub fn deadLettered(t: *const Telemetry, group: []const u8, topic: []const u8) void {
        t.dead_lettered.with(&.{ t.client, group, topic }).inc();
    }
    pub fn setLag(t: *const Telemetry, group: []const u8, topic: []const u8, partition: i32, lag: i64) void {
        var buf: [16]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{d}", .{partition}) catch return;
        t.lag.with(&.{ t.client, group, topic, p }).set(lag);
    }
};
