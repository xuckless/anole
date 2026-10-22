//! Observability: request IDs, an access log, Prometheus metrics,
//! OpenTelemetry traces and health checks on one server.
//!
//!   zig build run-observe                     # http://127.0.0.1:8085, JSON access log
//!   zig build run-observe -- 9000 text        # another port, text access log
//!
//! Spans go to the OTLP/HTTP collector named by OTEL_EXPORTER_OTLP_ENDPOINT
//! (http://127.0.0.1:4318 when unset). Without a collector there the server
//! runs the same; the exporter counts the spans it could not send as dropped.
//!
//! The app's routes are on the public listener (the port given); the
//! operator's are on an "admin" listener, the next port, bound to loopback
//! only, so neither the scraper's view nor the maintenance switch is
//! reachable from outside. Behind a load balancer, bind it to a private
//! interface instead.
//!
//!   GET /users/:id        "user <id>", with the request's trace ID
//!   GET /chain/:id        calls /users/:id on this server, passing the trace on
//!
//! On the admin port (8086):
//!
//!   POST /maintenance     fail the readiness check
//!   DELETE /maintenance   pass it again
//!   GET /metrics          Prometheus text format
//!   GET /healthz          200 while the process answers
//!   GET /readyz           200, or 503 in maintenance or while draining
const std = @import("std");
const anole = @import("anole");
const observe = anole.observe;
const metrics = observe.metrics;

/// Keeps the runtime's per-thread lines and the connection loops' debug
/// lines out of a Debug build; info (startup lines, access log) stays.
pub const std_options = anole.std_options;
// A panic is logged (message and stack trace) before the process aborts.
pub const panic = anole.panic;

/// What every handler shares, passed as the handler's first argument.
const App = struct {
    port: u16,
    maintenance: std.atomic.Value(bool) = .init(false),
    /// Custom metrics, beside the HTTP ones.
    lookups: *metrics.Family(metrics.Counter),
    maintenance_gauge: *metrics.Family(metrics.Gauge),
};

fn handleUser(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const id = req.params.get("id").?;
    // Labelled by how the lookup arrived; keep label values to a small set.
    const via = if (req.headers.get("traceparent") != null) "traced" else "direct";
    app.lookups.with(&.{via}).inc();
    try res.print(.text, "user {s} trace {s}\n", .{ id, req.trace_id });
}

/// An outgoing call inside this request's span: the callee continues the
/// same trace, with this span as its parent.
fn handleChain(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const id = std.fmt.parseInt(u32, req.params.get("id").?, 10) catch return error.NotFound;
    const url = try std.fmt.allocPrint(req.arena, "http://127.0.0.1:{d}/users/{d}", .{ app.port, id });
    var tp_buf: [55]u8 = undefined;
    const traceparent = observe.trace.outgoing(req, &tp_buf);
    // The server's own client, its connections pooled across requests.
    var response = try anole.client(req).fetch(url, .{
        .headers = if (traceparent) |tp| &.{.{ "traceparent", tp }} else &.{},
    });
    defer response.deinit();
    const body = try req.arena.dupe(u8, try response.body());
    try res.print(.text, "downstream said: {s}", .{body});
}

fn handleMaintenanceOn(app: *App, _: *anole.Request, res: *anole.Response) !void {
    app.maintenance.store(true, .release);
    app.maintenance_gauge.with(&.{}).set(1);
    try res.print(.text, "maintenance on\n", .{});
}

fn handleMaintenanceOff(app: *App, _: *anole.Request, res: *anole.Response) !void {
    app.maintenance.store(false, .release);
    app.maintenance_gauge.with(&.{}).set(0);
    try res.print(.text, "maintenance off\n", .{});
}

/// A readiness check: false makes /readyz answer 503 "not ready: maintenance".
fn notInMaintenance(ctx: ?*anyopaque) bool {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    return !app.maintenance.load(.acquire);
}

pub fn main(init: std.process.Init) !void {
    var port: u16 = 8085;
    var log_format: observe.access_log.Format = .json;
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    if (args.next()) |p| port = try std.fmt.parseInt(u16, p, 10);
    if (args.next()) |f| log_format = std.meta.stringToEnum(observe.access_log.Format, f) orelse return error.UnknownLogFormat;
    const otlp_endpoint = init.environ_map.get("OTEL_EXPORTER_OTLP_ENDPOINT") orelse "http://127.0.0.1:4318";

    var app: App = .{ .port = port, .lookups = undefined, .maintenance_gauge = undefined };
    var server = try anole.Server(App).init(init.gpa, .{ .listeners = &.{
        .{ .name = "public", .address = "127.0.0.1", .port = port },
        // Operators only: loopback (or a private interface), never public.
        .{ .name = "admin", .address = "127.0.0.1", .port = port + 1 },
    } }, &app);
    defer server.deinit();

    // Order matters only for what runs first: the IDs are set before the
    // handler runs, and the access log writes its line after it. `tracing`
    // and `metrics` add middleware too, so they come with the `use` calls.
    server.use(anole.middleware.RequestId.init(.{}));
    // Traces: a batching task sends finished spans to the collector; the
    // server sends what is left when it is freed.
    const exporter = try server.tracing(.{ .endpoint = otlp_endpoint, .service_name = "anole-observe-example" });
    server.use(observe.AccessLog.init(.{ .format = log_format, .exclude = &observe.probe_paths }));
    // Metrics: the HTTP series come from a middleware, the rest from the
    // application, on the registry the server serves at /metrics.
    const registry = server.metrics(.{ .listener = "admin" });
    app.lookups = try registry.counter("example_user_lookups_total", "User lookups, by how they arrived.", &.{"via"});
    app.maintenance_gauge = try registry.gauge("example_maintenance", "1 while in maintenance mode.", &.{});
    app.maintenance_gauge.with(&.{}).set(0);
    // /healthz and /readyz, with a readiness check of our own.
    try server.health(.{ .listener = "admin" }).addCheck("maintenance", notInMaintenance, &app);

    server.get("/users/:id", handleUser);
    server.get("/chain/:id", handleChain);
    // The maintenance switch changes what the load balancer sees: only on
    // the admin listener (404 on the public one).
    const admin = server.group("/maintenance", .{anole.onlyOn("admin")});
    admin.post("", handleMaintenanceOn);
    admin.delete("", handleMaintenanceOff);

    std.log.info("sending spans to {s}/v1/traces", .{otlp_endpoint});
    try server.run();
    // `deinit` sends what is still queued.
    std.log.info("stopped; spans exported {d}, dropped {d} so far", .{
        exporter.exported.load(.monotonic), exporter.dropped.load(.monotonic),
    });
}
