//! Prometheus series of an HTTP/3 listener, copied from its endpoints'
//! `Stats` on every scrape (`Registry.addCollector`): the endpoints keep
//! plain atomics on their hot paths, and a scrape reads them.
//!
//! Per endpoint (`{endpoint}`, its socket's index in the group):
//! `anole_h3_packets_total`, `anole_h3_forwarded_in_total`,
//! `anole_h3_forwarded_out_total`, `anole_h3_dropped_total`,
//! `anole_h3_datagrams_out_total`, `anole_h3_tx_flushes_total`,
//! `anole_h3_requests_total`, `anole_h3_served_inline_total` and
//! `anole_h3_connections_open`, and the socket buffers the system granted,
//! `anole_h3_socket_rcvbuf_bytes` and `anole_h3_socket_sndbuf_bytes`. Per listener: `anole_h3_steering` (1 when
//! the kernel steers datagrams to their connection's endpoint).
const std = @import("std");
const metrics = @import("../observe/metrics.zig");
const Stats = @import("server.zig").Stats;

const Series = struct {
    name: []const u8,
    help: []const u8,
    field: []const u8,
};

const counters = [_]Series{
    .{ .name = "anole_h3_packets_total", .help = "QUIC packets an HTTP/3 endpoint handled, its own and those passed on to it.", .field = "packets" },
    .{ .name = "anole_h3_forwarded_in_total", .help = "Packets another endpoint's socket received for this endpoint's connections.", .field = "forwarded_in" },
    .{ .name = "anole_h3_forwarded_out_total", .help = "Packets this endpoint's socket received for another endpoint's connection (0 while steering works).", .field = "forwarded_out" },
    .{ .name = "anole_h3_dropped_total", .help = "Packets for another endpoint dropped: its inbox was full, or it had stopped.", .field = "dropped" },
    .{ .name = "anole_h3_datagrams_out_total", .help = "Datagrams an HTTP/3 endpoint sent.", .field = "datagrams_out" },
    .{ .name = "anole_h3_tx_flushes_total", .help = "Outbox sends those datagrams went out in.", .field = "tx_flushes" },
    .{ .name = "anole_h3_requests_total", .help = "HTTP/3 requests started.", .field = "requests" },
    .{ .name = "anole_h3_served_inline_total", .help = "HTTP/3 requests for no_wait routes run inline, without a task.", .field = "served_inline" },
};

/// Copies `endpoints`' stats (each with `.index`, `.stats` and `.udp`) into
/// `registry`; `steering` and `listener` name the listener.
pub fn refresh(registry: *metrics.Registry, endpoints: anytype, steering: bool, listener: []const u8) void {
    var families: [counters.len]*metrics.Family(metrics.Counter) = undefined;
    inline for (counters, 0..) |s, i| families[i] = registry.counter(s.name, s.help, &.{"endpoint"}) catch return;
    const open = registry.gauge("anole_h3_connections_open", "HTTP/3 connections open on an endpoint.", &.{"endpoint"}) catch return;
    const rcvbuf = registry.gauge("anole_h3_socket_rcvbuf_bytes", "An HTTP/3 endpoint's UDP receive buffer, as the system reports it (Linux: twice what it granted).", &.{"endpoint"}) catch return;
    const sndbuf = registry.gauge("anole_h3_socket_sndbuf_bytes", "An HTTP/3 endpoint's UDP send buffer, as the system reports it (Linux: twice what it granted).", &.{"endpoint"}) catch return;
    var buf: [4]u8 = undefined;
    for (endpoints) |ep| {
        const id = std.fmt.bufPrint(&buf, "{d}", .{ep.index}) catch continue;
        const st: *const Stats = &ep.stats;
        inline for (counters, 0..) |s, i| families[i].with(&.{id}).set(@field(st, s.field).load(.monotonic));
        open.with(&.{id}).set(@intCast(st.connections_open.load(.monotonic)));
        rcvbuf.with(&.{id}).set(ep.udp.rcvbuf);
        sndbuf.with(&.{id}).set(ep.udp.sndbuf);
    }
    const steer = registry.gauge("anole_h3_steering", "1 when the kernel steers an HTTP/3 listener's datagrams to their connection's endpoint (classic BPF on SO_REUSEPORT).", &.{"listener"}) catch return;
    steer.with(&.{listener}).set(@intFromBool(steering));
}

test "h3 metrics: a scrape shows each endpoint's counts and the steering gauge" {
    const gpa = std.testing.allocator;
    var r = metrics.Registry.init(gpa, std.testing.io);
    defer r.deinit();
    const Ep = struct { index: u8, stats: Stats = .{}, udp: struct { rcvbuf: u32 = 425984, sndbuf: u32 = 0 } = .{} };
    var eps = [_]Ep{ .{ .index = 0 }, .{ .index = 1 } };
    eps[0].stats.requests.store(3, .monotonic);
    eps[1].stats.requests.store(4, .monotonic);
    eps[1].stats.forwarded_out.store(2, .monotonic);
    eps[1].stats.connections_open.store(1, .monotonic);
    const ptrs = [_]*const Ep{ &eps[0], &eps[1] };
    refresh(&r, &ptrs, true, "https");
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try r.render(&out.writer);
    const text = out.written();
    for ([_][]const u8{
        "anole_h3_requests_total{endpoint=\"0\"} 3\n",
        "anole_h3_requests_total{endpoint=\"1\"} 4\n",
        "anole_h3_forwarded_out_total{endpoint=\"1\"} 2\n",
        "anole_h3_forwarded_out_total{endpoint=\"0\"} 0\n",
        "anole_h3_connections_open{endpoint=\"1\"} 1\n",
        "anole_h3_steering{listener=\"https\"} 1\n",
        "anole_h3_socket_rcvbuf_bytes{endpoint=\"0\"} 425984\n",
    }) |line| {
        if (std.mem.indexOf(u8, text, line) == null) {
            std.debug.print("missing {s} in:\n{s}\n", .{ line, text });
            return error.TestUnexpectedResult;
        }
    }
}
