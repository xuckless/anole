# Observability

Up: [SKILL.md](../SKILL.md). Related: [config-cli.md](config-cli.md), [testing.md](testing.md), [deployment](deployment/index.md), [middleware-auth](middleware-auth/index.md).

Full docs: docs/observability.md, docs/logging.md, docs/console.md. Examples: examples/observe/main.zig, templates/full/src/main.zig.

Do not hand-roll a `/metrics` route, a `/healthz` handler, a request logger or a JSON logger: each is one line on the server. None is on until you add it.

## Wiring (the canonical block)

Use: `anole.App.metrics`, `anole.App.health`, `anole.App.tracing` (src/server.zig, same on `anole.Server(Ctx)`), `anole.middleware.RequestId` (src/root.zig), `anole.observe.AccessLog`, `anole.observe.probe_paths` (src/observe/root.zig).

```zig
// From examples/observe/main.zig (Server(App) with an "admin" listener).
server.use(anole.middleware.RequestId.init(.{}));
const exporter = try server.tracing(.{ .endpoint = otlp_endpoint, .service_name = "anole-observe-example" });
server.use(observe.AccessLog.init(.{ .format = log_format, .exclude = &observe.probe_paths }));
const registry = server.metrics(.{ .listener = "admin" });
try server.health(.{ .listener = "admin" }).addCheck("maintenance", notInMaintenance, &app);
server.get("/users/:id", handleUser); // routes after
```

Traps:
- `metrics` and `tracing` add a middleware: call them with the `use` calls, before any route, or they panic (src/server.zig `metrics`, `tracing`). `health` can go anywhere; its routes are added when serving starts.
- `/metrics` lists route patterns, error names and databases; `/readyz` names the failing check. Serve them on an internal listener (`.listener = "admin"`, a name from `ServerOptions.listeners`) or put auth middleware in front. See [listeners](deployment/listeners-proxy.md).
- The server owns the registry, health and exporter that these return. A hand-made `Registry`/`Health`/`Exporter` must outlive the server, since `use` copies the middleware that points at it.
- Global middleware also sees probes and scrapes: keep `.exclude = &anole.observe.probe_paths` (`/healthz`, `/readyz`, `/metrics`) on the access log. Metrics and tracing already default to it.

## Metrics (Prometheus)

Use: `anole.App.metrics` with `MetricsOptions` `.path` ("/metrics"), `.http` (true), `.exclude`, `.listener`; returns `*anole.observe.metrics.Registry` with `counter`, `gauge`, `histogram`; `anole.observe.metrics.default_buckets` (src/observe/metrics.zig).

```zig
const lookups = try registry.counter("example_user_lookups_total", "User lookups, by how they arrived.", &.{"via"});
lookups.with(&.{"direct"}).inc();

const maint = try registry.gauge("example_maintenance", "1 while in maintenance mode.", &.{});
maint.with(&.{}).set(1);

const work = try registry.histogram("job_seconds", "Job time.", &.{}, &anole.observe.metrics.default_buckets);
work.with(&.{}).observe(0.042);
```

Built in: `anole_http_requests_total{method,route,status}`, `anole_http_request_duration_seconds{method,route}`, `anole_http_requests_in_flight`, plus runtime gauges per executor (`anole_connections`, `anole_runtime_tasks`, `anole_executor_utilization_permille`, ...) and HTTP/3 series. Connectors made with `app.postgres` etc. report into it too.

Traps:
- Store the returned `*Family(...)` in your state (examples/observe keeps `lookups: *metrics.Family(metrics.Counter)`); do not re-register per request.
- Label values must be a small fixed set. The `route` label is the pattern (`/users/:id`), never the raw path; unmatched requests are `route="unmatched"`.
- Histogram buckets must be finite and strictly increasing, else `error.InvalidBuckets`.
- The `anole_runtime_*` series need zio's `diagnostics` option, which `anole.zio_options` turns on; a root file with its own `zio_options` without it loses them ([root declarations](config-cli.md#root-file-declarations)).

## Tracing (OpenTelemetry)

Use: `anole.App.tracing` with `TracingOptions` `.endpoint`, `.service_name`, `.sample_all`, `.exclude`, `.batch_size`, `.interval`, `.queue_len`; returns `*anole.observe.trace.Exporter`. `anole.observe.trace.outgoing`, `anole.observe.trace.current` (src/observe/trace.zig).

Endpoint and service name default to `OTEL_EXPORTER_OTLP_ENDPOINT` and `OTEL_SERVICE_NAME`, else `http://localhost:4318` and `"anole"`. One server span per request, W3C `traceparent` in and out; handlers read `req.trace_id`, `req.span_id`.

```zig
// Passing the trace on to an outgoing call (examples/observe/main.zig).
var tp_buf: [55]u8 = undefined;
const traceparent = observe.trace.outgoing(req, &tp_buf);
var response = try anole.client(req).fetch(url, .{
    .headers = if (traceparent) |tp| &.{.{ "traceparent", tp }} else &.{},
});
defer response.deinit();
```

Traps:
- Clients never add `traceparent` on their own; use `trace.outgoing` per call.
- With no collector the server runs normally and spans are dropped (`exporter.dropped`, `exporter.exported` are atomics).
- The server flushes queued spans when it is freed; on Lambda the adapter calls `exporter.flush(timeout)` after each answer ([lambda](deployment/lambda.md)).

## Health and readiness

Use: `anole.App.health` with `anole.observe.Health.Options` `.healthz_path`, `.readyz_path`, `.listener`; `anole.observe.Health.addCheck` (src/observe/health.zig).

```zig
/// A readiness check: false makes /readyz answer 503 "not ready: maintenance".
fn notInMaintenance(ctx: ?*anyopaque) bool {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    return !app.maintenance.load(.acquire);
}
```

`/healthz` is 200 `ok` while the process answers. `/readyz` is 200 when every check passes, 503 `not ready: <name>` for the first failing one, 503 `draining` once the server drains.

Traps:
- Checks run on every `/readyz` request and are capped at 16 per server: read a flag a background task keeps current, do not query a database per probe.
- Readiness already fails on drain; do not add your own SIGTERM flag. To leave rotation before SIGTERM, fail a check, wait for the balancer, then signal ([lifecycle](deployment/lifecycle.md#graceful-drain)).
- gRPC health is `app.grpcHealth()` (`anole.grpc.Health`), not this.

## Access log

Use: `anole.observe.AccessLog.init(.{ .format, .file, .exclude, .log_query })` (src/observe/access_log.zig); simpler `anole.middleware.Logger` (src/root.zig).

```zig
app.use(anole.observe.AccessLog.init(.{ .format = .json, .exclude = &anole.observe.probe_paths }));
```

Traps:
- `.format` null follows the log format (JSON in production). `.log_query` is off on purpose: queries carry OIDC codes and tokens.
- `request_id`, `trace_id`, `span_id` appear only with `RequestId` and `tracing` installed.

## Structured logging

Use: `anole.log.info/warn/err/debug`, `anole.log.scoped(.name)`, `anole.Request.log` (src/logging/root.zig, src/http/core/request.zig), `ServerOptions.log` (`.format` auto/text/json, `.level`, `.service`), `anole.std_options`, `anole.panic` (src/root.zig).

```zig
pub const std_options = anole.std_options; // std.log lines become records too
pub const panic = anole.panic; // a panic is one error line, then abort

var app = try anole.App.init(gpa, .{ .log = .{ .service = "billing" } });

anole.log.info("todo created", .{ .title = title });
anole.log.scoped(.billing).warn("card declined", .{ .customer = id, .code = 402 });
req.log().info("slow upstream", .{ .ms = 840 }); // adds request_id, trace_id, span_id
```

Traps:
- The message is fixed text; data goes in named fields. A tuple (`.{id}`) or a field named `time`, `level`, `scope`, `message`, `service`, `request_id`, `trace_id`, `span_id`, `truncated` is a compile error.
- Fields ending in a secret word (`password`, `api_key`, `authorization`, `cookie`...) and `anole.Secret` values are written `[REDACTED]`. std.log format arguments are not redacted.
- Without `pub const std_options = anole.std_options;` the server's own std.log lines stay text in a JSON deployment (init warns).
- Plain `std.log` carries no request id; use `req.log()` inside handlers.
- Output is one record per line on stderr. Do not add a log shipper or file writer for Docker/systemd/Kubernetes.

## Live console

Use: `ServerOptions.console` (`anole.console.Options`: `.enabled`, `.name`, `.socket`, `.allow_restart`, `.read_only`, `.keys`, `.log_buffer`, `.errors_kept`, `.max_routes`; src/console/root.zig); the `anole console` CLI ([config-cli.md](config-cli.md#the-anole-cli)).

```
anole console [name|pid|socket path]     # same user, same machine; ssh -t host anole console remotely
anole console --list
anole console api --snapshot routes      # one view as JSON: conns, db, ws, h3, runtime, config, routes, errors
```

In development, `c` + Enter in the app's terminal opens it. Commands: `/logs`, `/requests`, `/errors`, `/conns`, `/db`, `/ws`, `/h3`, `/runtime`, `/config`, `/routes`, `/reload`, `/drain`, `/restart`, `/full-restart`.

Traps:
- On by default in every environment (off in tests, under `deployment = lambda`, on Windows). Off with `.console = .{ .enabled = false }` or `ANOLE_CONSOLE=0`.
- An app that reads stdin itself sets `.console = .{ .keys = false }`.
- `/restart` needs `.process = init.minimal` and `allow_restart` (off in production by default). `.read_only = true` refuses all control commands.
- Containers: `docker exec -it c anole console`; Kubernetes: `kubectl exec -it pod -- anole console`. There is no TCP endpoint.
