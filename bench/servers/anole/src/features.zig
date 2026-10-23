//! 0.4's features for the bench, each behind its environment variable and
//! compiled only where the Anole being built has it:
//!
//! - NET_TCP_PORT, NET_UDP_PORT: raw TCP and UDP echo listeners in
//!   `.listeners`, beside `http`/`https` (one SO_REUSEPORT UDP socket per
//!   executor on Linux).
//! - SSE=1: GET /sse subscribes to the topic "ticks"; POST /publish sends the
//!   request body to every subscriber and answers how many it reached.
//! - UPSTREAM=<url>: GET /fanin fetches the URL through the server's shared
//!   client and answers its body; UPSTREAM_H2C=1 lists the upstream's
//!   host:port in `h2c_hosts`, so the requests share one HTTP/2 connection
//!   per executor instead of an HTTP/1.1 pool.
//! - METRICS=1: /metrics.
const std = @import("std");
const anole = @import("anole");
const App = @import("main.zig").App;
const Server = anole.Server(App);

const has_net = @hasDecl(Server, "tcp") and @hasDecl(Server, "udp");
const has_sse = @hasDecl(Server, "sseTopics");

pub const Config = struct {
    tcp_port: u16 = 0,
    udp_port: u16 = 0,
    sse: bool = false,
    upstream: []const u8 = "",
    upstream_h2c: bool = false,
    metrics: bool = false,
};

var topics: if (has_sse) ?*anole.sse.Topics else void = if (has_sse) null else {};
var upstream: []const u8 = "";
var h2c_hosts: [1][]const u8 = undefined;

/// Before `Server.init`: the raw listeners, and the client options the
/// fan-in needs.
pub fn configure(opts: anytype, cfg: Config) void {
    if (comptime has_net) {
        const Listener = @typeInfo(@TypeOf(opts.listeners)).pointer.child;
        const S = struct {
            var buf: [2]Listener = undefined;
        };
        var n: usize = 0;
        if (cfg.tcp_port != 0) {
            S.buf[n] = .{ .name = "echo-tcp", .address = "0.0.0.0", .port = cfg.tcp_port, .tcp = anole.net.tcp(App, TcpEcho, .{}) };
            n += 1;
        }
        if (cfg.udp_port != 0) {
            S.buf[n] = .{ .name = "echo-udp", .address = "0.0.0.0", .port = cfg.udp_port, .udp = anole.net.udp(App, UdpEcho, .{}) };
            n += 1;
        }
        if (n > 0) opts.listeners = S.buf[0..n];
    }
    if (cfg.upstream.len == 0 or !cfg.upstream_h2c) return;
    if (comptime !@hasField(@TypeOf(opts.client), "h2c_hosts")) return;
    const uri = std.Uri.parse(cfg.upstream) catch return;
    const host = (uri.host orelse return).percent_encoded;
    h2c_hosts[0] = std.fmt.allocPrint(std.heap.page_allocator, "{s}:{d}", .{ host, uri.port orelse 80 }) catch return;
    opts.client.h2c_hosts = &h2c_hosts;
}

/// After `Server.init`, with the other routes.
pub fn register(app: *Server, cfg: Config) !void {
    if (comptime !has_net) if (cfg.tcp_port != 0 or cfg.udp_port != 0) return error.NetNotInThisAnole;
    if (comptime has_sse) {
        if (cfg.sse) {
            topics = try app.sseTopics(.{});
            app.sse("/sse", topics.?, .{ .topics = &.{"ticks"} });
            app.post("/publish", publish);
        }
    } else if (cfg.sse) return error.SseNotInThisAnole;
    if (cfg.upstream.len > 0) {
        upstream = cfg.upstream;
        app.get("/fanin", fanin);
    }
}

/// Right after `Server.init`, before any route: `metrics` adds a middleware.
pub fn registerEarly(app: *Server, cfg: Config) void {
    if (cfg.metrics) {
        if (comptime @hasDecl(Server, "metrics")) _ = app.metrics(.{});
    }
}

const TcpEcho = struct {
    pub fn data(conn: *anole.net.Conn, bytes: []const u8) !void {
        _ = try conn.send(bytes);
    }
};

const UdpEcho = struct {
    pub fn datagram(d: *anole.net.Datagram) !void {
        try d.reply(d.data);
    }
};

fn publish(req: *anole.Request, res: *anole.Response) !void {
    const body = (try req.body()) orelse "";
    const n = try topics.?.publish("ticks", .{ .data = body, .replay = false });
    try res.print(.text, "{d}", .{n});
}

fn fanin(req: *anole.Request, res: *anole.Response) !void {
    var r = try anole.client(req).fetch(upstream, .{});
    defer r.deinit();
    if (r.status() != .ok) return error.Upstream;
    try res.print(.json, "{s}", .{try r.body()});
}
