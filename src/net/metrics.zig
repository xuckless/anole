//! Prometheus series of the raw TCP and UDP listeners (design-net.md §5):
//! one label set per listener, made once when serving starts and kept in
//! pointers, so the hot paths only add to atomics.
const std = @import("std");
const observe = @import("../observe/root.zig");

const metrics = observe.metrics;

/// `close reason`, as the label value.
const reasons = [_][]const u8{ "peer", "local", "reset", "failed", "idle", "write_timeout", "lifetime", "frame", "drain", "server" };

/// The series of one TCP listener.
pub const TcpSeries = struct {
    total: *metrics.Counter,
    open: *metrics.Gauge,
    bytes_in: *metrics.Counter,
    bytes_out: *metrics.Counter,
    queue_full: *metrics.Counter,
    closes: [reasons.len]*metrics.Counter,

    pub fn init(registry: *metrics.Registry, gpa: std.mem.Allocator, listener: []const u8) !*TcpSeries {
        const s = try gpa.create(TcpSeries);
        errdefer gpa.destroy(s);
        const l = &[_][]const u8{listener};
        s.total = (try registry.counter("anole_net_connections_total", "Raw TCP connections accepted.", &.{"listener"})).with(l);
        s.open = (try registry.gauge("anole_net_connections_open", "Raw TCP connections open now.", &.{"listener"})).with(l);
        s.bytes_in = (try registry.counter("anole_net_bytes_received_total", "Bytes read from raw TCP connections.", &.{"listener"})).with(l);
        s.bytes_out = (try registry.counter("anole_net_bytes_sent_total", "Bytes written to raw TCP connections.", &.{"listener"})).with(l);
        s.queue_full = (try registry.counter("anole_net_send_queue_full_total", "Sends refused: the connection's outbox was full.", &.{"listener"})).with(l);
        const closes = try registry.counter("anole_net_closes_total", "Raw TCP connections closed, by reason.", &.{ "listener", "reason" });
        for (reasons, &s.closes) |r, *c| c.* = closes.with(&.{ listener, r });
        return s;
    }
};

/// UDP drop reasons, as label values.
pub const DropReason = enum { kernel, truncated, queue_full, send_failed, sessions_full };

/// The series of one UDP listener.
pub const UdpSeries = struct {
    received: *metrics.Counter,
    sent: *metrics.Counter,
    dropped: [@typeInfo(DropReason).@"enum".field_names.len]*metrics.Counter,
    sessions: *metrics.Gauge,

    pub fn init(registry: *metrics.Registry, gpa: std.mem.Allocator, listener: []const u8) !*UdpSeries {
        const s = try gpa.create(UdpSeries);
        errdefer gpa.destroy(s);
        const l = &[_][]const u8{listener};
        s.received = (try registry.counter("anole_net_datagrams_received_total", "UDP datagrams received.", &.{"listener"})).with(l);
        s.sent = (try registry.counter("anole_net_datagrams_sent_total", "UDP datagrams sent.", &.{"listener"})).with(l);
        const dropped = try registry.counter("anole_net_datagrams_dropped_total", "UDP datagrams dropped, by reason.", &.{ "listener", "reason" });
        inline for (@typeInfo(DropReason).@"enum".field_names, 0..) |n, i| s.dropped[i] = dropped.with(&.{ listener, n });
        s.sessions = (try registry.gauge("anole_net_udp_sessions_open", "UDP sessions open now.", &.{"listener"})).with(l);
        return s;
    }

    pub fn drop(s: *UdpSeries, why: DropReason, n: u64) void {
        s.dropped[@backingInt(why)].add(n);
    }
};
