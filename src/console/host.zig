//! What the console asks of a `Server(Ctx)` (the `service.Host` the server
//! hands over): certificate reload, stop, the hand-off, routes, listeners,
//! databases, HTTP/3 and the runtime numbers. Generic over the server type
//! so the console itself stays type-erased.
const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");
const dusty = @import("dusty");
const features = @import("build_options");
const service = @import("service.zig");
const collector = @import("collector.zig");
const websocket = if (features.websocket) @import("../websocket/root.zig") else struct {};
const sse = @import("../sse/root.zig");

fn jsonStr(w: *std.Io.Writer, s: []const u8) !void {
    try w.print("{f}", .{std.json.fmt(s, .{})});
}

pub fn Of(comptime S: type) type {
    return struct {
        pub fn make(s: *S, executors: u32) service.Host {
            return .{
                .ctx = s,
                .executors = executors,
                .reload = reload,
                .stop = stop,
                .restart = if (s.consoleRestartable()) restart else null,
                .route_meta = routeMeta,
                .listeners = listeners,
                .databases = databases,
                .ws = ws,
                .h3 = if (features.http3) h3 else null,
                .routes = routes,
                .config = config,
                .task_stats = taskStats,
                .stack_committed = stackCommitted,
                .before_exec = beforeExec,
            };
        }

        fn of(ctx: *anyopaque) *S {
            return @ptrCast(@alignCast(ctx));
        }

        fn reload(ctx: *anyopaque, buf: []u8) service.ReloadResult {
            const s = of(ctx);
            if (s.certs.len == 0) return .{ .unavailable = "no TLS listener" };
            s.reloadCertificates() catch |err| {
                var w: std.Io.Writer = .fixed(buf);
                w.print("certificate reload failed, keeping the current one: {t}", .{err}) catch {};
                return .{ .failed = w.buffered() };
            };
            return .{ .ok = @intCast(s.certs.len) };
        }

        fn stop(ctx: *anyopaque) void {
            of(ctx).stop();
        }

        fn restart(ctx: *anyopaque) void {
            of(ctx).consoleRequestRestart();
        }

        fn routeMeta(ctx: *anyopaque, index: u32) ?service.RouteMeta {
            const s = of(ctx);
            if (index == 0 or index > s.router.routes.items.len) return null;
            const r = s.router.routes.items[index - 1];
            return .{ .method = if (r.method) |m| m.name() else "ANY", .pattern = r.info.path };
        }

        fn routes(ctx: *anyopaque, w: *std.Io.Writer) anyerror!void {
            const s = of(ctx);
            try w.writeByte('[');
            for (s.router.routes.items, 0..) |r, i| {
                if (i > 0) try w.writeByte(',');
                try w.print("{{\"i\":{d},\"method\":", .{r.info.index});
                try jsonStr(w, if (r.method) |m| m.name() else "ANY");
                try w.writeAll(",\"pattern\":");
                try jsonStr(w, r.info.path);
                try w.print(",\"no_wait\":{},\"cached\":false,\"kind\":\"http\",\"middleware\":{d}}}", .{ r.no_wait, r.middlewares.len });
            }
            try w.writeByte(']');
        }

        fn listeners(ctx: *anyopaque, w: *std.Io.Writer) anyerror!void {
            const s = of(ctx);
            const cfg = s.server.config.listeners;
            try w.writeByte('[');
            for (cfg, 0..) |l, i| {
                if (i > 0) try w.writeByte(',');
                try w.writeAll("{\"name\":");
                try jsonStr(w, if (l.name.len > 0) l.name else if (l.tls != null) "https" else "http");
                try w.writeAll(",\"url\":\"");
                const scheme = if (l.tls != null) "https" else "http";
                const addr: dusty.Address = if (i < s.server.addresses.len) s.server.addresses[i] else l.address;
                switch (addr) {
                    .ip => |ip| try w.print("{s}://{f}", .{ scheme, ip }),
                    .unix => |u| try w.print("unix:{s}", .{u.path}),
                }
                try w.writeAll("\",\"protocols\":[");
                var first = true;
                const protos = [_]struct { name: []const u8, on: bool }{
                    .{ .name = "h1", .on = l.http1 },
                    .{ .name = "h2", .on = features.http2 and l.tls != null and hasAlpnH2(l) },
                    .{ .name = "h2c", .on = features.http2 and l.tls == null and l.http2_prior_knowledge },
                    .{ .name = "h3", .on = features.http3 and l.tls != null and s.consoleHasH3() },
                };
                for (protos) |p| {
                    if (!p.on) continue;
                    if (!first) try w.writeByte(',');
                    first = false;
                    try jsonStr(w, p.name);
                }
                try w.writeAll("]}");
            }
            try w.writeByte(']');
        }

        fn hasAlpnH2(l: dusty.Listener) bool {
            const t = l.tls orelse return false;
            for (t.alpn_protocols) |p| if (std.mem.eql(u8, p, "h2")) return true;
            return false;
        }

        /// On the console's thread: the collector makes it on the runtime
        /// (a connector's pool numbers are under the runtime's locks).
        fn databases(ctx: *anyopaque, w: *std.Io.Writer) anyerror!void {
            return of(ctx).console_collector.snapshot(.db, w);
        }

        /// On the console's thread: the collector makes it on the runtime
        /// (rooms and topics are under the runtime's locks).
        fn ws(ctx: *anyopaque, w: *std.Io.Writer) anyerror!void {
            return of(ctx).console_collector.snapshot(.ws, w);
        }

        /// The collector's snapshots, on its task of the runtime.
        pub fn collect(ctx: *anyopaque, what: collector.What, w: *std.Io.Writer) anyerror!void {
            switch (what) {
                .db => try collectDatabases(of(ctx), w),
                .ws => try collectWs(w),
            }
        }

        fn gaugeSum(kind: dusty.gauges.Kind) u64 {
            var n: i64 = 0;
            for (0..dusty.gauges.max_executors) |i| n += dusty.gauges.get(kind, i);
            return @intCast(@max(n, 0));
        }

        fn collectWs(w: *std.Io.Writer) !void {
            try w.print("{{\"sockets\":{{\"h1\":{d},\"h2\":{d},\"h3\":{d}}},\"webtransport\":{d},\"rooms\":[", .{
                gaugeSum(.ws_h1), gaugeSum(.ws_h2), gaugeSum(.ws_h3), gaugeSum(.wt_sessions),
            });
            var first = true;
            if (comptime features.websocket) try websocket.Rooms._consoleRows(w, &first);
            try w.writeAll("],\"topics\":[");
            first = true;
            try sse.Topics._consoleRows(w, &first);
            try w.writeAll("]}");
        }

        fn collectDatabases(s: *S, w: *std.Io.Writer) !void {
            try w.writeByte('[');
            for (s.extras.connectors.items, 0..) |c, i| {
                if (i > 0) try w.writeByte(',');
                try w.print("{{\"i\":{d},", .{i});
                try c.describe(c.context, c.name, w);
                try w.writeByte('}');
            }
            try w.writeByte(']');
        }

        fn h3(ctx: *anyopaque, w: *std.Io.Writer) anyerror!void {
            const s = of(ctx);
            if (comptime !features.http3) return;
            const ep = s.h3 orelse {
                try w.writeAll("{\"enabled\":false,\"endpoints\":[]}");
                return;
            };
            try w.writeAll("{\"enabled\":true,\"endpoints\":[");
            for (ep.endpoints(), 0..) |e, i| {
                if (i > 0) try w.writeByte(',');
                e.sampleStats();
                const st = &e.stats;
                try w.print("{{\"index\":{d}", .{i});
                inline for (@typeInfo(@TypeOf(st.*)).@"struct".field_names) |name| {
                    try w.print(",\"{s}\":{d}", .{ name, @field(st, name).load(.monotonic) });
                }
                try w.writeByte('}');
            }
            try w.writeAll("]}");
        }

        fn config(ctx: *anyopaque, w: *std.Io.Writer) anyerror!void {
            try w.writeAll(of(ctx).console_config_text);
        }

        fn taskStats(ctx: *anyopaque, i: usize) ?service.TaskStats {
            const s = of(ctx);
            const st = s.rt.executorStats(i) orelse return null;
            return .{ .tasks = st.spawned -% st.finished, .run_queue = st.run_queue };
        }

        fn stackCommitted(ctx: *anyopaque) u64 {
            return of(ctx).rt.stackStats().committed_bytes;
        }

        fn beforeExec(ctx: *anyopaque) void {
            _ = ctx;
            @import("inprocess.zig").close();
        }
    };
}
