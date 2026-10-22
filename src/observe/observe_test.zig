//! Metrics, traces, readiness and access-log lines, end to end.
const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");
const observe = @import("root.zig");

var collected: [16 * 1024]u8 = undefined;
var collected_len: usize = 0;

fn collector(req: *dusty.Request, res: *dusty.Response) !void {
    const body = (try req.body()) orelse "";
    const n = @min(body.len, collected.len - collected_len);
    @memcpy(collected[collected_len..][0..n], body[0..n]);
    collected_len += n;
    res.body = "{}";
}

fn user(req: *dusty.Request, res: *dusty.Response) !void {
    res.body = try std.fmt.allocPrint(res.arena, "user {s} trace {s}", .{ req.params.get("id").?, req.trace_id });
}

var db_ready = true;
fn dbCheck(_: ?*anyopaque) bool {
    return db_ready;
}

fn get(io: std.Io, port: u16, request: []const u8, out: []u8) ![]const u8 {
    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var wbuf: [1024]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.writeAll(request);
    try w.interface.flush();
    var rbuf: [4096]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    var fw: std.Io.Writer = .fixed(out);
    _ = r.interface.streamRemaining(&fw) catch {};
    return fw.buffered();
}

fn serve(s: *dusty.Server(void)) anyerror!void {
    try s.run();
}

test "observe: traces reach the collector, metrics by route, readiness" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();

    var otel = dusty.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer otel.deinit();
    otel.router.post("/v1/traces", collector);
    var otel_future = try io.concurrent(serve, .{&otel});
    defer otel_future.cancel(io) catch {};
    try otel.waitReady(io);

    var client = dusty.Client.init(gpa, io, .{});
    defer client.deinit();
    var endpoint_buf: [64]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buf, "http://127.0.0.1:{d}", .{otel.address.ip.getPort()});
    var exporter = try observe.trace.Exporter.init(gpa, io, .{ .http = &client }, .{ .endpoint = endpoint, .service_name = "test-api", .interval_ms = 50 });
    var exporter_live = true;
    defer if (exporter_live) exporter.deinit();
    try exporter.start();

    var registry = observe.metrics.Registry.init(gpa, io);
    defer registry.deinit();
    var http = try observe.metrics.HttpMetrics.init(&registry, .{});
    var tracing = observe.trace.Middleware.init(&exporter);
    var health = observe.Health.init(.{});
    try health.addCheck("db", dbCheck, null);

    var app = dusty.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer app.deinit();
    app.router.use(dusty.Middleware(void).init(&tracing));
    app.router.use(dusty.Middleware(void).init(&http));
    app.router.get("/users/:id", user);
    registry.serveOn(void, &app.router, "/metrics");
    health.registerOn(void, &app.router, &app);
    var app_future = try io.concurrent(serve, .{&app});
    defer app_future.cancel(io) catch {};
    try app.waitReady(io);
    const port = app.address.ip.getPort();

    var out: [8192]u8 = undefined;
    const resp = try get(io, port, "GET /users/7 HTTP/1.1\r\nHost: x\r\ntraceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.endsWith(u8, resp, "user 7 trace 4bf92f3577b34da6a3ce929d0e0e4736"));

    const metrics = try get(io, port, "GET /metrics HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.indexOf(u8, metrics, "anole_http_requests_total{method=\"GET\",route=\"/users/:id\",status=\"200\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, metrics, "anole_http_request_duration_seconds_count{method=\"GET\",route=\"/users/:id\"} 1") != null);

    var out2: [1024]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, try get(io, port, "GET /readyz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out2), "HTTP/1.1 200"));
    db_ready = false;
    const not_ready = try get(io, port, "GET /readyz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out2);
    try std.testing.expect(std.mem.startsWith(u8, not_ready, "HTTP/1.1 503"));
    try std.testing.expect(std.mem.endsWith(u8, not_ready, "not ready: db\n"));
    try std.testing.expect(std.mem.startsWith(u8, try get(io, port, "GET /healthz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out2), "HTTP/1.1 200"));

    // Flushes the queue: the request's span reaches the collector under the
    // caller's trace, as a child of its span.
    exporter.deinit();
    exporter_live = false;
    const sent = collected[0..collected_len];
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"traceId\":\"4bf92f3577b34da6a3ce929d0e0e4736\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"parentSpanId\":\"00f067aa0ba902b7\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"name\":\"GET /users/:id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"stringValue\":\"test-api\"") != null);
}

test "access log: text and JSON lines" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var req: dusty.Request = .{ .arena = arena_state.allocator(), .parser = undefined, .transport = undefined };
    req.method = .get;
    req.url = "/a\"b";
    req.id = "rid";
    req.trace_id = "4bf92f3577b34da6a3ce929d0e0e4736";
    req.span_id = "00f067aa0ba902b7";
    const json = try observe.access_log.format(arena_state.allocator(), .json, &req, 200, 42, 1700000000000, null);
    try std.testing.expect(std.mem.startsWith(u8, json, "{\"ts\":1700000000000,\"method\":\"GET\",\"path\":\"/a\\\"b\",\"status\":200,\"duration_us\":42,"));
    try std.testing.expect(std.mem.endsWith(u8, json, "\"request_id\":\"rid\",\"trace_id\":\"4bf92f3577b34da6a3ce929d0e0e4736\",\"span_id\":\"00f067aa0ba902b7\"}\n"));
    const text = try observe.access_log.format(arena_state.allocator(), .text, &req, 404, 7, 0, null);
    try std.testing.expect(std.mem.startsWith(u8, text, "GET /a\"b 404 7us "));
}

test "access log: a request ID cannot add JSON fields" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var req: dusty.Request = .{ .arena = arena, .parser = undefined, .transport = undefined };
    req.method = .get;
    req.url = "/x";
    req.id = "x\",\"status\":200,\"y\":\"\\";
    const json = try observe.access_log.format(arena, .json, &req, 403, 1, 0, null);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    try std.testing.expectEqual(@as(i64, 403), parsed.object.get("status").?.integer);
    try std.testing.expectEqualStrings(req.id, parsed.object.get("request_id").?.string);
}

fn relay(req: *dusty.Request, res: *dusty.Response) !void {
    var buf: [55]u8 = undefined;
    res.body = try res.arena.dupe(u8, observe.trace.outgoing(req, &buf) orelse "none");
}

fn tooBig(_: *dusty.Request, _: *dusty.Response) !void {
    return error.BodyTooBig;
}

test "observe: an unsampled caller's context is passed on; error statuses as sent" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();

    var client = dusty.Client.init(gpa, io, .{});
    defer client.deinit();
    // Never started: nothing here is recorded, or sent anywhere.
    var exporter = try observe.trace.Exporter.init(gpa, io, .{ .http = &client }, .{ .endpoint = "http://127.0.0.1:9", .service_name = "t", .sample_all = false });
    defer exporter.deinit();
    var registry = observe.metrics.Registry.init(gpa, io);
    defer registry.deinit();
    var http = try observe.metrics.HttpMetrics.init(&registry, .{});
    var tracing = observe.trace.Middleware.init(&exporter);

    var app = dusty.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer app.deinit();
    app.router.use(dusty.Middleware(void).init(&tracing));
    app.router.use(dusty.Middleware(void).init(&http));
    app.router.get("/relay", relay);
    app.router.get("/big", tooBig);
    registry.serveOn(void, &app.router, "/metrics");
    var app_future = try io.concurrent(serve, .{&app});
    defer app_future.cancel(io) catch {};
    try app.waitReady(io);
    const port = app.address.ip.getPort();

    var out: [8192]u8 = undefined;
    // Not sampled by the caller, so not recorded, but passed on as it came.
    const unsampled = try get(io, port, "GET /relay HTTP/1.1\r\nHost: x\r\ntraceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.endsWith(u8, unsampled, "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00"));
    const sampled = try get(io, port, "GET /relay HTTP/1.1\r\nHost: x\r\ntraceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.indexOf(u8, sampled, "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7") == null);
    try std.testing.expect(std.mem.endsWith(u8, sampled, "-01"));
    try std.testing.expect(std.mem.endsWith(u8, try get(io, port, "GET /relay HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out), "none"));

    try std.testing.expect(std.mem.startsWith(u8, try get(io, port, "GET /big HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out), "HTTP/1.1 413"));
    const metrics = try get(io, port, "GET /metrics HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.indexOf(u8, metrics, "route=\"/big\",status=\"413\"} 1") != null);
}

fn dbDown(_: ?*anyopaque) bool {
    return false;
}

test "observe: two servers in one process each serve their own health and metrics" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();

    var servers: [2]dusty.Server(void) = undefined;
    var registries: [2]observe.metrics.Registry = undefined;
    var healths: [2]observe.Health = undefined;
    var futures: [2]std.Io.Future(anyerror!void) = undefined;
    for (&servers, &registries, &healths, 0..) |*s, *r, *h, i| {
        r.* = .init(gpa, io);
        const c = try r.counter(if (i == 0) "first_total" else "second_total", "Which.", &.{});
        c.with(&.{}).inc();
        h.* = .init(.{ .readyz_path = if (i == 0) "/readyz" else "/ready" });
        if (i == 1) try h.addCheck("db", dbDown, null);
        s.* = .init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
        r.serveOn(void, &s.router, "/metrics");
        h.registerOn(void, &s.router, s);
        futures[i] = try io.concurrent(serve, .{s});
        try s.waitReady(io);
    }
    defer for (&servers, &registries, &futures) |*s, *r, *f| {
        f.cancel(io) catch {};
        s.deinit();
        r.deinit();
    };

    var out: [4096]u8 = undefined;
    const p0 = servers[0].address.ip.getPort();
    const p1 = servers[1].address.ip.getPort();
    const m0 = try get(io, p0, "GET /metrics HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.indexOf(u8, m0, "first_total 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, m0, "second_total") == null);
    const m1 = try get(io, p1, "GET /metrics HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.indexOf(u8, m1, "second_total 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, m1, "first_total") == null);

    try std.testing.expect(std.mem.startsWith(u8, try get(io, p0, "GET /readyz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out), "HTTP/1.1 200"));
    const r1 = try get(io, p1, "GET /ready HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, r1, "HTTP/1.1 503"));
    try std.testing.expect(std.mem.endsWith(u8, r1, "not ready: db\n"));
    try std.testing.expect(std.mem.startsWith(u8, try get(io, p1, "GET /healthz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out), "HTTP/1.1 200"));
}

var held_started: std.Io.Event = .unset;

/// Holds a request marked `?held` until the drain starts, then lets it on
/// to its route: a request routed during the drain, as an HTTP/2 stream
/// opened before the final GOAWAY is.
const HoldUntilDrain = struct {
    pub fn execute(_: *const HoldUntilDrain, req: *dusty.Request, _: *dusty.Response, executor: anytype) !void {
        if (std.mem.endsWith(u8, req.url, "?held")) {
            held_started.set(req.io);
            try req.drain.?.wait(req.io);
        }
        return executor.next();
    }
};

test "observe: /readyz answers 503 to a request routed after the drain started" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    held_started = .unset;

    var health = observe.Health.init(.{});
    var hold: HoldUntilDrain = .{};
    var app = dusty.Server(void).init(gpa, io, .{
        .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }},
        .timeout = .{ .shutdown = .fromSeconds(10) },
    }, {});
    defer app.deinit();
    app.router.use(dusty.Middleware(void).init(&hold));
    health.registerOn(void, &app.router, &app);
    var app_future = try io.concurrent(serve, .{&app});
    defer app_future.cancel(io) catch {};
    try app.waitReady(io);
    const port = app.address.ip.getPort();

    var out: [1024]u8 = undefined;
    try std.testing.expect(std.mem.endsWith(u8, try get(io, port, "GET /readyz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out), "ok\n"));

    var held = try io.concurrent(struct {
        fn run(io_: std.Io, p: u16) !void {
            var buf: [1024]u8 = undefined;
            const resp = try get(io_, p, "GET /readyz?held HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &buf);
            if (!std.mem.startsWith(u8, resp, "HTTP/1.1 503")) return error.NotRefused;
            if (!std.mem.endsWith(u8, resp, "draining\n")) return error.NotDraining;
        }
    }.run, .{ io, port });
    try held_started.wait(io);
    try std.testing.expectError(error.Canceled, app_future.cancel(io));
    try held.await(io);
}

test "observe: the exporter stops at once, not after its interval" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var client = dusty.Client.init(gpa, io, .{});
    defer client.deinit();
    // Nothing listens there: the one span is dropped, then the task pauses
    // for its (long) interval until deinit wakes it.
    var exporter = try observe.trace.Exporter.init(gpa, io, .{ .http = &client }, .{ .endpoint = "http://127.0.0.1:9", .service_name = "t", .interval_ms = 60_000 });
    try exporter.start();
    var span: observe.trace.Span = undefined;
    span.db = null;
    span.name_len = 0;
    span.method_len = 0;
    span.route_len = 0;
    span.parent_span_id = null;
    span.status_code = 200;
    span.start_ns = 0;
    span.end_ns = 0;
    @memset(&span.trace_id, '1');
    @memset(&span.span_id, '1');
    _ = exporter.queue.putUncancelable(io, &.{span}, 1) catch unreachable;
    while (exporter.dropped.load(.monotonic) == 0) try io.sleep(.fromMilliseconds(1), .awake);

    const start: std.Io.Clock.Timestamp = .now(io, .awake);
    exporter.deinit();
    try std.testing.expect(start.durationTo(.now(io, .awake)).raw.toMilliseconds() < 1000);
}

test "observe: exclude keeps probes out of metrics and traces" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();

    var client = dusty.Client.init(gpa, io, .{});
    defer client.deinit();
    var exporter = try observe.trace.Exporter.init(gpa, io, .{ .http = &client }, .{ .endpoint = "http://127.0.0.1:9", .service_name = "t", .exclude = &observe.probe_paths });
    defer exporter.deinit();
    var registry = observe.metrics.Registry.init(gpa, io);
    defer registry.deinit();
    var http = try observe.metrics.HttpMetrics.init(&registry, .{ .exclude = &observe.probe_paths });
    var tracing = observe.trace.Middleware.init(&exporter);
    var health = observe.Health.init(.{});

    var app = dusty.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer app.deinit();
    app.router.use(dusty.Middleware(void).init(&tracing));
    app.router.use(dusty.Middleware(void).init(&http));
    app.router.get("/users/:id", user);
    registry.serveOn(void, &app.router, "/metrics");
    health.registerOn(void, &app.router, &app);
    var app_future = try io.concurrent(serve, .{&app});
    defer app_future.cancel(io) catch {};
    try app.waitReady(io);
    const port = app.address.ip.getPort();

    var out: [8192]u8 = undefined;
    _ = try get(io, port, "GET /healthz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
    _ = try get(io, port, "GET /readyz?full HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
    _ = try get(io, port, "GET /users/1 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
    const metrics = try get(io, port, "GET /metrics HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.indexOf(u8, metrics, "route=\"/users/:id\",status=\"200\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, metrics, "route=\"/healthz\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, metrics, "route=\"/readyz\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, metrics, "route=\"/metrics\"") == null);
    // Only /users/1 was traced (the exporter never started, so its queue
    // holds what was submitted).
    var spans: [8]observe.trace.Span = undefined;
    try std.testing.expectEqual(@as(usize, 1), try exporter.queue.get(io, &spans, 0));
    try std.testing.expectEqualStrings("/users/:id", spans[0].route[0..spans[0].route_len]);
}
