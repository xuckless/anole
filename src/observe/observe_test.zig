//! Metrics, traces, readiness and access-log lines, end to end.
const std = @import("std");
const wait = @import("anole_test_wait");
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
    // The rest of what came is the answer, however the stream ended; but
    // a cancel of the calling task is passed on, not swallowed.
    _ = r.interface.streamRemaining(&fw) catch |err| switch (err) {
        error.ReadFailed => if (r.err) |e| if (e == error.Canceled) return error.Canceled,
        else => {},
    };
    return fw.buffered();
}

fn serve(s: *dusty.Server(void)) anyerror!void {
    try s.run();
}

test "tracing: a request's span reaches the OTLP collector as a child of the caller's span" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    collected_len = 0;

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
    var exporter = try observe.trace.Exporter.init(gpa, io, .{ .http = &client }, .{ .endpoint = endpoint, .service_name = "test-api", .interval = .fromMilliseconds(50) });
    var exporter_live = true;
    defer if (exporter_live) exporter.deinit();
    try exporter.start();
    var tracing = observe.trace.Middleware.init(&exporter);

    var app = dusty.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer app.deinit();
    app.router.use(dusty.Middleware(void).init(&tracing));
    app.router.get("/users/:id", user);
    var app_future = try io.concurrent(serve, .{&app});
    defer app_future.cancel(io) catch {};
    try app.waitReady(io);

    var out: [8192]u8 = undefined;
    const resp = try get(io, app.address.ip.getPort(), "GET /users/7 HTTP/1.1\r\nHost: x\r\ntraceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.endsWith(u8, resp, "user 7 trace 4bf92f3577b34da6a3ce929d0e0e4736"));

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

test "metrics: requests are counted by route template and status" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();

    var registry = observe.metrics.Registry.init(gpa, io);
    defer registry.deinit();
    var http = try observe.metrics.HttpMetrics.init(&registry, .{});

    var app = dusty.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer app.deinit();
    app.router.use(dusty.Middleware(void).init(&http));
    app.router.get("/users/:id", user);
    registry.serveOn(void, &app.router, "/metrics");
    var app_future = try io.concurrent(serve, .{&app});
    defer app_future.cancel(io) catch {};
    try app.waitReady(io);
    const port = app.address.ip.getPort();

    var out: [8192]u8 = undefined;
    _ = try get(io, port, "GET /users/7 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
    const metrics = try get(io, port, "GET /metrics HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.indexOf(u8, metrics, "anole_http_requests_total{method=\"GET\",route=\"/users/:id\",status=\"200\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, metrics, "anole_http_request_duration_seconds_count{method=\"GET\",route=\"/users/:id\"} 1") != null);
}

test "health: /readyz turns 503 naming the failed check when it starts failing, /healthz stays 200" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    db_ready = true;
    defer db_ready = true;

    var health = observe.Health.init(.{});
    try health.addCheck("db", dbCheck, null);
    var app = dusty.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer app.deinit();
    health.registerOn(void, &app.router, &app);
    var app_future = try io.concurrent(serve, .{&app});
    defer app_future.cancel(io) catch {};
    try app.waitReady(io);
    const port = app.address.ip.getPort();

    var out: [1024]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, try get(io, port, "GET /readyz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out), "HTTP/1.1 200"));
    db_ready = false;
    const not_ready = try get(io, port, "GET /readyz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, not_ready, "HTTP/1.1 503"));
    try std.testing.expect(std.mem.endsWith(u8, not_ready, "not ready: db\n"));
    try std.testing.expect(std.mem.startsWith(u8, try get(io, port, "GET /healthz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out), "HTTP/1.1 200"));
}

test "access log: text and JSON lines" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var req: dusty.Request = .{ .arena = arena_state.allocator(), ._parser = undefined, ._transport = undefined };
    req.method = .get;
    req.url = "/a\"b";
    req.id = "rid";
    req.trace_id = "4bf92f3577b34da6a3ce929d0e0e4736";
    req.span_id = "00f067aa0ba902b7";
    const json = try observe.access_log.format(arena_state.allocator(), .json, &req, 200, 42, 1700000000000, null);
    // The shared record: time, level, scope, message, the ids, then the request.
    try std.testing.expect(std.mem.startsWith(u8, json, "{\"time\":\"2023-11-14T22:13:20.000Z\",\"level\":\"info\",\"scope\":\"access\",\"message\":\"GET /a\\\"b 200\","));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"request_id\":\"rid\",\"trace_id\":\"4bf92f3577b34da6a3ce929d0e0e4736\",\"span_id\":\"00f067aa0ba902b7\",\"method\":\"GET\",\"path\":\"/a\\\"b\",\"status\":200,\"duration_us\":42,") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ts\"") == null);
    try std.testing.expect(std.mem.endsWith(u8, json, "}\n"));
    const text = try observe.access_log.format(arena_state.allocator(), .text, &req, 404, 7, 0, null);
    try std.testing.expect(std.mem.startsWith(u8, text, "GET /a\"b 404 7us "));
}

test "access log: a request ID cannot add JSON fields" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var req: dusty.Request = .{ .arena = arena, ._parser = undefined, ._transport = undefined };
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
    pub fn execute(_: *const HoldUntilDrain, req: *dusty.Request, _: *dusty.Response, next: anytype) !void {
        if (std.mem.endsWith(u8, req.url, "?held")) {
            held_started.set(req.io);
            try req.drain.?.wait(req.io);
        }
        return next.call();
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
    defer held.cancel(io) catch {};
    try wait.waitEvent(io, "the held /readyz request reached the handler", &held_started);
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
    var exporter = try observe.trace.Exporter.init(gpa, io, .{ .http = &client }, .{ .endpoint = "http://127.0.0.1:9", .service_name = "t", .interval = .fromSeconds(60) });
    try exporter.start();
    var span: observe.trace.Span = undefined;
    span.db = null;
    span.job = null;
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
    _ = try wait.waitNonZero(io, "the exporter dropped a span", &exporter.dropped);

    // deinit on a task of its own: it must end within the wait deadline
    // (10 s), far inside the 60 s interval it would otherwise wait out.
    const start: std.Io.Clock.Timestamp = .now(io, .awake);
    var stopped: std.atomic.Value(bool) = .init(false);
    var stopper = try io.concurrent(struct {
        fn run(e: *observe.trace.Exporter, done: *std.atomic.Value(bool)) void {
            e.deinit();
            done.store(true, .release);
        }
    }.run, .{ &exporter, &stopped });
    defer stopper.await(io);
    try wait.waitFlag(io, "the exporter's deinit returned", &stopped);
    if (wait.timing()) try std.testing.expect(start.durationTo(.now(io, .awake)).raw.toMilliseconds() < 1000);
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
    var taken = try exporter.takeQueued(&spans);
    defer taken.deinit();
    try std.testing.expectEqual(@as(usize, 1), taken.spans.len);
    try std.testing.expectEqualStrings("/users/:id", taken.spans[0].route[0..taken.spans[0].route_len]);
}

test "access log: the query is left out unless log_query" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var req: dusty.Request = .{ .arena = arena, ._parser = undefined, ._transport = undefined };
    req.method = .get;
    req.url = "/callback?code=secret-code&state=s";
    const json = try observe.access_log.format(arena, .json, &req, 200, 1, 0, null);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    try std.testing.expectEqualStrings("/callback", parsed.object.get("path").?.string);
    try std.testing.expect(std.mem.indexOf(u8, json, "secret-code") == null);
    const text = try observe.access_log.format(arena, .text, &req, 200, 1, 0, null);
    try std.testing.expect(std.mem.indexOf(u8, text, "secret-code") == null);
    const kept = try observe.access_log.formatLine(arena, .{ .format = .text, .log_query = true }, &req, 200, 1, 0, null);
    try std.testing.expect(std.mem.startsWith(u8, kept, "GET /callback?code=secret-code&state=s 200 "));
}

test "tracing: OTEL_SERVICE_NAME from the process environment without .process" {
    const anole = @import("../root.zig");
    // The C library's environment: what the server reads without
    // `.process` (`std.c.getenv` on Windows too, db/url.zig realEnv).
    const libc = if (@import("builtin").os.tag == .windows) struct {
        extern "c" fn _putenv_s(name: [*:0]const u8, value: [*:0]const u8) c_int;
        fn set(name: [*:0]const u8, value: [*:0]const u8) void {
            _ = _putenv_s(name, value);
        }
        fn unset(name: [*:0]const u8) void {
            _ = _putenv_s(name, "");
        }
    } else struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern "c" fn unsetenv(name: [*:0]const u8) c_int;
        fn set(name: [*:0]const u8, value: [*:0]const u8) void {
            _ = setenv(name, value, 1);
        }
        fn unset(name: [*:0]const u8) void {
            _ = unsetenv(name);
        }
    };
    libc.set("OTEL_SERVICE_NAME", "from-the-environment");
    defer libc.unset("OTEL_SERVICE_NAME");
    var app = try anole.App.init(std.testing.allocator, .{ .http = .{ .port = 0 }, .executors = .exact(1) });
    defer app.deinit();
    const exporter = try app.tracing(.{ .endpoint = "http://127.0.0.1:9", .interval = .fromSeconds(60) });
    try std.testing.expectEqualStrings("from-the-environment", exporter.options.service_name);
}

test "observe: runtime gauges appear on /metrics" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();

    var registry = observe.metrics.Registry.init(gpa, io);
    defer registry.deinit();
    registry.runtime_gauges = true;

    var app = dusty.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer app.deinit();
    registry.serveOn(void, &app.router, "/metrics");
    var app_future = try io.concurrent(serve, .{&app});
    defer app_future.cancel(io) catch {};
    try app.waitReady(io);

    var out: [16384]u8 = undefined;
    const metrics = try get(io, app.address.ip.getPort(), "GET /metrics HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.indexOf(u8, metrics, "anole_connections{executor=\"0\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, metrics, "anole_streams{executor=\"0\",protocol=\"h2\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, metrics, "anole_runtime_tasks{executor=\"0\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, metrics, "anole_runtime_run_queue{executor=\"0\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, metrics, "anole_runtime_stack_committed_bytes ") != null);
}

test "access log json: an error is named in error, and a request without an id has no request_id" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var req: dusty.Request = .{ .arena = arena, ._parser = undefined, ._transport = undefined };
    req.method = .get;
    req.url = "/users/42";
    const json = try observe.access_log.format(arena, .json, &req, 500, 9, 0, error.Boom);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    try std.testing.expectEqualStrings("access", parsed.object.get("scope").?.string);
    try std.testing.expectEqualStrings("GET /users/42 500", parsed.object.get("message").?.string);
    try std.testing.expectEqualStrings("Boom", parsed.object.get("error").?.string);
    try std.testing.expect(parsed.object.get("request_id") == null);
}

test "trace: flush sends queued spans before it returns" {
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
    // A long interval: only `flush` can make the span leave in time.
    var exporter = try observe.trace.Exporter.init(gpa, io, .{ .http = &client }, .{ .endpoint = endpoint, .service_name = "flush-api", .interval = .fromSeconds(600) });
    defer exporter.deinit();
    try exporter.start();

    collected_len = 0;
    var span: observe.trace.Span = undefined;
    span.db = null;
    span.job = null;
    span.name_len = 0;
    span.method_len = 0;
    span.route_len = 0;
    span.parent_span_id = null;
    span.status_code = 200;
    span.start_ns = 0;
    span.end_ns = 0;
    @memset(&span.trace_id, 'a');
    @memset(&span.span_id, 'b');
    exporter.submit(span);
    exporter.flush(.fromSeconds(30));
    try std.testing.expect(std.mem.indexOf(u8, collected[0..collected_len], "\"traceId\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"") != null);
    try std.testing.expectEqual(@as(u64, 1), exporter.exported.load(.monotonic));
    // Nothing queued: returns at once.
    exporter.flush(.fromSeconds(30));
}

/// The collector of the flush-cancel test: tells the test a batch came,
/// then answers only when the test lets it.
const HeldCollector = struct {
    var arrived: std.Io.Event = .unset;
    var release: std.Io.Event = .unset;

    fn handle(req: *dusty.Request, res: *dusty.Response) !void {
        _ = try req.body();
        arrived.set(req.io);
        release.waitUncancelable(req.io);
        res.body = "{}";
    }
};

/// A span of the trace tests, its IDs all `id`.
fn testSpan(id: u8) observe.trace.Span {
    // SAFETY: every field the encoder reads for a server span is set below.
    var span: observe.trace.Span = undefined;
    span.db = null;
    span.job = null;
    span.name_len = 0;
    span.method_len = 0;
    span.route_len = 0;
    span.parent_span_id = null;
    span.status_code = 200;
    span.start_ns = 0;
    span.end_ns = 0;
    @memset(&span.trace_id, id);
    @memset(&span.span_id, id);
    return span;
}

test "trace: a flush whose caller is canceled stays canceled" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    HeldCollector.arrived = .unset;
    HeldCollector.release = .unset;

    var otel = dusty.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer otel.deinit();
    otel.router.post("/v1/traces", HeldCollector.handle);
    var otel_future = try io.concurrent(serve, .{&otel});
    defer otel_future.cancel(io) catch {};
    try otel.waitReady(io);

    var client = dusty.Client.init(gpa, io, .{});
    defer client.deinit();
    var endpoint_buf: [64]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buf, "http://127.0.0.1:{d}", .{otel.address.ip.getPort()});
    var exporter = try observe.trace.Exporter.init(gpa, io, .{ .http = &client }, .{ .endpoint = endpoint, .service_name = "cancel", .interval = .fromSeconds(600) });
    defer exporter.deinit();
    // Before the exporter's close waits for its task, which waits for the
    // collector's answer.
    defer HeldCollector.release.set(io);
    try exporter.start();
    exporter.submit(testSpan('c'));
    try wait.waitEvent(io, "the collector got the batch", &HeldCollector.arrived);

    // The batch is unanswered: the flush waits until its caller is
    // canceled, and the caller must still see the cancel after it.
    var flusher = try io.concurrent(struct {
        fn run(e: *observe.trace.Exporter, io_: std.Io) error{ Canceled, CancelLost }!void {
            e.flush(.fromSeconds(3600));
            try io_.checkCancel();
            return error.CancelLost;
        }
    }.run, .{ &exporter, io });
    defer flusher.cancel(io) catch {};
    try std.testing.expectError(error.Canceled, flusher.cancel(io));
}

/// A task that flushes and notes when the flush returned.
const Flusher = struct {
    exporter: *observe.trace.Exporter,
    done: std.atomic.Value(bool) = .init(false),

    fn run(f: *Flusher) void {
        f.exporter.flush(.fromSeconds(3600));
        f.done.store(true, .release);
    }
};

/// An OTLP collector that holds its first two batches, each until the
/// test lets it go.
const StepCollector = struct {
    var arrivals: std.atomic.Value(u32) = .init(0);
    var arrived: [2]std.Io.Event = @splat(.unset);
    var release: [2]std.Io.Event = @splat(.unset);

    fn reset() void {
        arrivals = .init(0);
        arrived = @splat(.unset);
        release = @splat(.unset);
    }

    fn letAllGo(io: std.Io) void {
        for (&release) |*r| r.set(io);
    }

    fn handle(req: *dusty.Request, res: *dusty.Response) !void {
        _ = try req.body();
        const i = arrivals.fetchAdd(1, .acq_rel);
        if (i < 2) {
            arrived[i].set(req.io);
            release[i].waitUncancelable(req.io);
        }
        res.body = "{}";
    }
};

test "trace: a flush that a close overtakes returns before the last batch is answered" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    HeldCollector.arrived = .unset;
    HeldCollector.release = .unset;

    var otel = dusty.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer otel.deinit();
    otel.router.post("/v1/traces", HeldCollector.handle);
    var otel_future = try io.concurrent(serve, .{&otel});
    defer otel_future.cancel(io) catch {};
    try otel.waitReady(io);

    var client = dusty.Client.init(gpa, io, .{});
    defer client.deinit();
    var endpoint_buf: [64]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buf, "http://127.0.0.1:{d}", .{otel.address.ip.getPort()});
    var exporter = try observe.trace.Exporter.init(gpa, io, .{ .http = &client }, .{ .endpoint = endpoint, .service_name = "overtaken", .interval = .fromSeconds(600) });
    defer exporter.deinit();
    defer HeldCollector.release.set(io);
    try exporter.start();
    exporter.submit(testSpan('d'));
    try wait.waitEvent(io, "the collector got the batch", &HeldCollector.arrived);

    // A flusher waits for the unanswered batch; then the close comes, and
    // waits for the task, which waits for the collector.
    var flusher: Flusher = .{ .exporter = &exporter };
    var flushing = try io.concurrent(Flusher.run, .{&flusher});
    defer flushing.cancel(io);
    try wait.waitAtLeast(io, "the flusher waits", &exporter.test_flush_waits, 1);
    var closing = try io.concurrent(observe.trace.Exporter.close, .{&exporter});
    defer closing.cancel(io);
    // On a failure: before the close is waited for.
    defer HeldCollector.release.set(io);
    try wait.waitFlag(io, "the overtaken flush returned while the batch is unanswered", &flusher.done);
    HeldCollector.release.set(io);
    closing.await(io);
    try std.testing.expectEqual(exporter.queued.load(.acquire), exporter.finished.load(.acquire));
}

test "trace: flushes from several tasks each return once their own spans are answered" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    StepCollector.reset();

    var otel = dusty.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer otel.deinit();
    otel.router.post("/v1/traces", StepCollector.handle);
    var otel_future = try io.concurrent(serve, .{&otel});
    defer otel_future.cancel(io) catch {};
    try otel.waitReady(io);

    var client = dusty.Client.init(gpa, io, .{});
    defer client.deinit();
    var endpoint_buf: [64]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buf, "http://127.0.0.1:{d}", .{otel.address.ip.getPort()});
    var exporter = try observe.trace.Exporter.init(gpa, io, .{ .http = &client }, .{ .endpoint = endpoint, .service_name = "flushers", .interval = .fromSeconds(600) });
    defer exporter.deinit();
    defer StepCollector.letAllGo(io);
    try exporter.start();

    // The first flusher waits for span 'e' (the first batch, held), the
    // second for 'e' and 'f' ('f' goes in the second batch).
    exporter.submit(testSpan('e'));
    try wait.waitEvent(io, "the collector got the first batch", &StepCollector.arrived[0]);
    var first: Flusher = .{ .exporter = &exporter };
    var first_future = try io.concurrent(Flusher.run, .{&first});
    defer first_future.cancel(io);
    try wait.waitAtLeast(io, "the first flusher waits", &exporter.test_flush_waits, 1);
    exporter.submit(testSpan('f'));
    var second: Flusher = .{ .exporter = &exporter };
    var second_future = try io.concurrent(Flusher.run, .{&second});
    defer second_future.cancel(io);

    StepCollector.release[0].set(io);
    try wait.waitFlag(io, "the first flusher returned once the first batch was answered", &first.done);
    try wait.waitEvent(io, "the collector got the second batch", &StepCollector.arrived[1]);
    // Its 'f' is unanswered: the second flusher still waits.
    try std.testing.expect(!second.done.load(.acquire));
    StepCollector.release[1].set(io);
    try wait.waitFlag(io, "the second flusher returned once the second batch was answered", &second.done);
    try std.testing.expectEqual(@as(u64, 2), exporter.exported.load(.acquire));
}

test "trace: spans close finds unsent are counted finished and dropped" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var client = dusty.Client.init(gpa, io, .{});
    defer client.deinit();
    // Never started: nothing sends what is queued.
    var exporter = try observe.trace.Exporter.init(gpa, io, .{ .http = &client }, .{ .endpoint = "http://127.0.0.1:9", .service_name = "unsent" });
    defer exporter.deinit();
    for ("ghi") |id| exporter.submit(testSpan(id));
    exporter.close();
    try std.testing.expectEqual(@as(u64, 3), exporter.queued.load(.acquire));
    try std.testing.expectEqual(@as(u64, 3), exporter.finished.load(.acquire));
    try std.testing.expectEqual(@as(u64, 3), exporter.dropped.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), exporter.exported.load(.acquire));
}

// ------------------------------------------------------------ stress (W3)

/// An OTLP collector that takes every batch.
fn takingCollector(req: *dusty.Request, res: *dusty.Response) !void {
    _ = try req.body();
    res.body = "{}";
}

/// The tasks of the trace stress test.
const TraceStress = struct {
    exporter: *observe.trace.Exporter,
    io: std.Io,
    submitted: std.atomic.Value(u64) = .init(0),
    /// `close` returned.
    closed: std.atomic.Value(bool) = .init(false),
    close_after: u64,

    fn flusher(t: *TraceStress) void {
        // Flushes until the close; each returns once its spans are
        // answered, on its timeout, or at once after the close.
        for (0..200) |_| {
            if (t.closed.load(.acquire)) return;
            t.exporter.flush(.fromMilliseconds(50));
        }
    }

    fn submitter(t: *TraceStress, n: usize, id: u8) void {
        for (0..n) |_| {
            t.exporter.submit(testSpan(id));
            _ = t.submitted.fetchAdd(1, .release);
        }
    }

    fn closer(t: *TraceStress) std.Io.Cancelable!void {
        wait.waitAtLeast(t.io, "the submitters reached the close point", &t.submitted, t.close_after) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.WaitTimedOut => {},
        };
        t.exporter.close();
        t.closed.store(true, .release);
    }
};

test "trace: [stress] flushes racing submits and close all return, and every span is exported or dropped" {
    try wait.requireStress();
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(4) });
    defer rt.deinit();
    const io = rt.io();

    var otel = dusty.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer otel.deinit();
    otel.router.post("/v1/traces", takingCollector);
    var otel_future = try io.concurrent(serve, .{&otel});
    defer otel_future.cancel(io) catch {};
    try otel.waitReady(io);
    var client = dusty.Client.init(gpa, io, .{});
    defer client.deinit();
    var endpoint_buf: [64]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buf, "http://127.0.0.1:{d}", .{otel.address.ip.getPort()});

    const seed: u64 = 0x5eed_0118;
    var prng: std.Random.DefaultPrng = .init(seed);
    for (0..4) |round| {
        var exporter = try observe.trace.Exporter.init(gpa, io, .{ .http = &client }, .{ .endpoint = endpoint, .service_name = "stress", .interval = .fromMilliseconds(5), .batch_size = 64 });
        defer exporter.deinit();
        try exporter.start();
        var t: TraceStress = .{ .exporter = &exporter, .io = io, .close_after = prng.random().uintLessThan(u64, 20_000) };
        var group: std.Io.Group = .init;
        defer group.cancel(io);
        for (0..8) |i| try dusty.placement.concurrent(&group, io, .{ .executor = i }, TraceStress.flusher, .{&t});
        for (0..4) |i| try dusty.placement.concurrent(&group, io, .{ .executor = i }, TraceStress.submitter, .{ &t, 5000, @as(u8, 'a') + @as(u8, @intCast(i)) });
        try dusty.placement.concurrent(&group, io, .{ .executor = round }, TraceStress.closer, .{&t});
        group.await(io) catch |err| {
            std.debug.print("trace stress: seed 0x{x}, round {d}\n", .{ seed, round });
            return err;
        };
        const queued = exporter.queued.load(.acquire);
        try std.testing.expectEqual(queued, exporter.finished.load(.acquire));
        try std.testing.expectEqual(t.submitted.load(.acquire), exporter.exported.load(.acquire) + exporter.dropped.load(.acquire));
    }
}

/// The tasks of the metrics stress test: each worker registers families of
/// its own and labels series in them; the scraper renders as they go.
const MetricsStress = struct {
    registry: *observe.metrics.Registry,
    io: std.Io,
    ops: std.atomic.Value(u64) = .init(0),
    workers_done: std.atomic.Value(u32) = .init(0),
    failures: std.atomic.Value(u32) = .init(0),

    const workers = 4;
    const ops_each = 4000;
    const labels = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h" };

    /// `names` (the worker's own arena) keeps the family names past the
    /// registry.
    fn worker(m: *MetricsStress, id: usize, names: std.mem.Allocator) void {
        defer _ = m.workers_done.fetchAdd(1, .release);
        var families: [ops_each / 100]*observe.metrics.Family(observe.metrics.Counter) = undefined;
        var n: usize = 0;
        for (0..ops_each) |i| {
            if (i % 100 == 0) {
                const name = std.fmt.allocPrint(names, "w{d}_f{d}_total", .{ id, i / 100 }) catch return m.fail();
                families[n] = m.registry.counter(name, "Stress.", &.{"l"}) catch return m.fail();
                n += 1;
            }
            families[i % n].with(&.{labels[i % labels.len]}).inc();
            _ = m.ops.fetchAdd(1, .release);
        }
    }

    fn fail(m: *MetricsStress) void {
        _ = m.failures.fetchAdd(1, .monotonic);
    }

    const Next = struct {
        m: *MetricsStress,
        target: u64,

        fn reached(x: Next) bool {
            return x.m.workers_done.load(.acquire) == workers or x.m.ops.load(.acquire) >= x.target;
        }
    };

    /// Renders after every 1000 operations, until the workers are done:
    /// each render reads as the text format, and no family it saw goes.
    fn scraper(m: *MetricsStress) std.Io.Cancelable!void {
        var seen_families: usize = 0;
        var target: u64 = 1000;
        while (true) {
            const done = m.workers_done.load(.acquire) == workers;
            var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer out.deinit();
            m.registry.render(&out.writer) catch return m.fail();
            var families: usize = 0;
            var lines = std.mem.splitScalar(u8, out.written(), '\n');
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                if (std.mem.startsWith(u8, line, "# TYPE ")) {
                    families += 1;
                } else if (!std.mem.startsWith(u8, line, "# HELP ")) {
                    // `name{labels} value` or `name value`.
                    const space = std.mem.lastIndexOfScalar(u8, line, ' ') orelse return m.fail();
                    _ = std.fmt.parseFloat(f64, line[space + 1 ..]) catch return m.fail();
                }
            }
            if (families < seen_families) return m.fail();
            seen_families = families;
            if (done) return;
            wait.waitUntil(m.io, "the workers did 1000 more operations, or ended", Next{ .m = m, .target = target }, Next.reached) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.WaitTimedOut => return m.fail(),
            };
            target += 1000;
        }
    }
};

test "metrics: [stress] scrapes racing registration and new series read as the text format, and families never vanish" {
    try wait.requireStress();
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(4) });
    defer rt.deinit();
    const io = rt.io();
    // One arena per worker for the family names, which must outlive the
    // registry: they go after it.
    var names: [MetricsStress.workers]std.heap.ArenaAllocator = @splat(.init(gpa));
    defer for (&names) |*a| a.deinit();
    var registry = observe.metrics.Registry.init(gpa, io);
    defer registry.deinit();
    var m: MetricsStress = .{ .registry = &registry, .io = io };
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (0..MetricsStress.workers) |i| try dusty.placement.concurrent(&group, io, .{ .executor = i }, MetricsStress.worker, .{ &m, i, names[i].allocator() });
    try dusty.placement.concurrent(&group, io, .{ .executor = 0 }, MetricsStress.scraper, .{&m});
    try group.await(io);
    try std.testing.expectEqual(@as(u32, 0), m.failures.load(.monotonic));
}
