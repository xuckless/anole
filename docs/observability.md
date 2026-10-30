# Observability

Anole ships five pieces you wire into a server yourself: request IDs, an
access log, Prometheus metrics, OpenTelemetry traces and health checks. Each
is a middleware or a pair of routes under `anole.observe` (request IDs are
`anole.middleware.RequestId`). None needs a build flag, and none is on until
you add it.

`examples/observe/main.zig` wires all of them. Run it with:

```sh
zig build run-observe                  # port 8085, JSON access log
zig build run-observe -- 9000 text     # another port, text access log
```

The app's routes are on that port; `/metrics`, `/healthz`, `/readyz` and
the `/maintenance` switch are on an `admin` listener on the next port
(8086), bound to loopback, as [Keep them off the public
port](#keep-them-off-the-public-port) describes.

## Wiring

The server sets each one up in a line, and owns what it makes:

```zig
app.use(anole.middleware.RequestId.init(.{}));
_ = try app.tracing(.{ .service_name = "api" }); // OTLP to OTEL_EXPORTER_OTLP_ENDPOINT or localhost:4318
app.use(anole.observe.AccessLog.init(.{ .format = .json, .exclude = &anole.observe.probe_paths }));
const registry = app.metrics(.{}); // /metrics, and the HTTP metrics middleware
const health = app.health(.{}); // /healthz and /readyz
try health.addCheck("db", dbReady, &pool);
// ... routes ...
```

- `metrics(.{ .path, .http, .exclude, .listener })` returns the registry for
  metrics of your own; `.http = false` leaves out the request metrics.
- `health(.{ .healthz_path, .readyz_path, .listener })` returns the `Health`
  for `addCheck`; readiness fails once the server drains.
- `.listener` serves those routes only on the listener of that name (from
  `Options.listeners`), and answers 404 on the others. Without it they are
  on every listener, the public one included: see
  [Keep them off the public port](#keep-them-off-the-public-port).
- `tracing(.{ .endpoint, .service_name, .sample_all, .exclude, ... })`
  exports through the server's own client. The endpoint and the service
  name default to `OTEL_EXPORTER_OTLP_ENDPOINT` and `OTEL_SERVICE_NAME`
  from the environment (with or without `process`), else
  `http://localhost:4318` and `"anole"`. The server sends the spans still
  queued when it is freed.
- `metrics` and `tracing` add a middleware, so they go before the routes,
  with the `use` calls. The `/metrics`, `/healthz` and `/readyz` routes are
  added when serving starts, so the order of `health` does not matter.
- `exclude` defaults to `anole.observe.probe_paths` for the request metrics
  and the traces.

The same by hand, for a router or a registry of your own:

```zig
var registry = anole.observe.metrics.Registry.init(gpa, app.io());
defer registry.deinit();
const http_metrics = try anole.observe.metrics.HttpMetrics.init(&registry, .{
    .exclude = &anole.observe.probe_paths,
});

var exporter = try anole.observe.trace.Exporter.init(gpa, app.io(), app.client(), .{
    .endpoint = "http://127.0.0.1:4318",
    .service_name = "api",
});
try exporter.start();

app.use(anole.middleware.RequestId.init(.{}));
app.use(anole.observe.trace.Middleware.init(&exporter));
app.use(anole.observe.AccessLog.init(.{ .format = .json, .exclude = &anole.observe.probe_paths }));
app.use(http_metrics);

// ... routes ...
registry.serveOn(void, app.router, "/metrics");

var health = anole.observe.Health.init(.{});
try health.addCheck("db", dbReady, &pool);
health.registerOn(void, app.router, app.server);
```

### Keep them off the public port

`/metrics` lists every route pattern, the error names handlers return and
the databases the app uses, and `/readyz` names the check that fails. That
is for your scraper and load balancer, not for the internet. Serve them on
an internal listener:

```zig
var app = try anole.App.init(gpa, .{ .listeners = &.{
    .{ .name = "public", .address = "0.0.0.0", .port = 8080 },
    .{ .name = "admin", .address = "127.0.0.1", .port = 9090 }, // or a private interface
} });
_ = app.metrics(.{ .listener = "admin" });
_ = app.health(.{ .listener = "admin" });
```

Otherwise keep the whole port private (a firewall, the proxy not routing
those paths), or put an authentication middleware in front with `use`:
global middleware runs before these routes. By hand,
`registry.serveOnListener(Ctx, router, "/metrics", "admin")` and
`Health.init(.{ .listener = "admin" })` do the same.

`app.use` copies each middleware, so the copies must not point at values
that move: keep the exporter, registry and health values alive for as long
as the server runs. Add middleware before any route, as the router requires.

Global middleware runs for every route, `/metrics`, `/healthz` and `/readyz`
included, and for requests that match no route. To keep probes and scrapes
out of the log, the metrics and the traces, give each its `exclude` list:
`AccessLog`'s and `HttpMetrics`' options, and the exporter's options for
tracing. An entry matches a path exactly, query aside, or as a prefix when
it ends in `*` (`"/internal/*"`). `anole.observe.probe_paths` holds
`/healthz`, `/readyz` and `/metrics`.

## Request IDs

`anole.middleware.RequestId` gives each request 128 random bits in hex,
stores them in `req.id` and sends them back in `X-Request-Id`. Set
`.header` to use another header name. Set `.trust_incoming = true` to keep
an ID that arrives with the request; do this only behind a proxy that sets
or strips the header, or clients choose their own IDs. An incoming ID is
kept only if it is 1 to 128 letters, digits, `.`, `_`, `:` or `-`;
anything else gets a fresh ID. The JSON access log escapes IDs either way.

## Access log

`anole.observe.AccessLog` writes one line per request after the handler
returns. Options:

- `.format`: `.text` or `.json`, one object per line. Null by default: it
  follows the log format (`ServerOptions.log.format`; JSON in production).
- `.file`: a `std.Io.File` to write to; stderr when null.
- `.exclude`: paths not logged (see [Wiring](#wiring)).
- `.log_query`: also log the query string (false). Off by default, because
  queries carry OIDC `code` and `state`, password-reset tokens and API keys,
  and logs keep them. `anole.middleware.Logger` has the same switch
  (`Logger.init(.{ .log_query = true })`).

Each line is a single write, so lines from concurrent requests do not
interleave. Without a `.file`, lines go where the logs go (stderr, or the C
ABI's log callback, scope `access`), filtered by the runtime log level;
with a `.file`, straight to the file.

Text, from the example:

```
GET /users/7 200 123us 127.0.0.1:64505 id=c643e5d771c29ce8cc77181de02d0b2a trace=4bf92f3577b34da6a3ce929d0e0e4736
```

JSON, from the example:

```json
{"time":"2026-10-23T09:41:07.415Z","level":"info","scope":"access","message":"GET /users/7 200","request_id":"9045897231062d793bd832ff5459f9e3","trace_id":"4bf92f3577b34da6a3ce929d0e0e4736","span_id":"3d4c9f621d6f31cc","method":"GET","path":"/users/7","route":"/users/:id","status":200,"duration_us":124,"client":"127.0.0.1:64388"}
```

The line is the shared log record ([logging.md](logging.md)): `time`
(RFC 3339 UTC; 0.2's `ts`, Unix milliseconds, is gone), `level`, `scope`
and `message`, then the request's ids. `path` is the raw target's path, the
query left out unless `log_query` is set. `route` appears only when a route matched. `request_id`,
`trace_id` and `span_id` appear only when the RequestId and tracing
middleware are installed. A handler that returns `error.NotFound` is logged
as the 404 it becomes. Any other error adds `error` and reports the status
the server answers it with (`anole.errorStatus`): a status-named error's own,
such as 401 for `error.Unauthorized`, the 4xx for a request-body fault, such
as 413 for a body over `limits.body_max`, and 500 for anything else. Metrics
and spans record the same status. An error raised after the response head went out
(a stream cut short, say) is recorded with the status that was sent. A
WebSocket over HTTP/2 is recorded as 101, like one over HTTP/1.1, though the
stream was accepted with a 200 (RFC 8441). An app's own `uncaughtError` or
`error_handler` can choose a different status, which these records do not
see.

The middleware reads the IDs after the handler returns, so its position
among the other middleware does not change what it logs. Its
`duration_us` covers the middleware that come after it and the handler.

The HTTP core's simpler `anole.middleware.Logger` is also available. It logs
through `std.log` at info level, without trace IDs:

```
info(access): GET /echo 200 3458us 127.0.0.1:64583 id=-
```

## Log scope names

Anole logs under its own scopes, so a server's output reads as one program
with std's default log function: `anole` for the server (the startup lines,
errors), `access` for `anole.middleware.Logger`, and `anole_h2`,
`anole_h3`, `anole_auth` and the like for the protocol engines and
subsystems. Each listener logs one line at info as it starts:

```
info(anole): listening on http://[::]:8080 (HTTP/1.1, HTTP/2 cleartext; IPv6 and IPv4)
info(anole): listening on https://[::]:8443 (HTTP/2, HTTP/1.1, HTTP/3; IPv6 and IPv4)
```

Nothing is logged per request at `debug`. A Debug build still logs zio's
worker threads starting and stopping and a few connection events at `debug`;
`anole.std_options` sets those scopes (`zio`, `anole`, `anole_h2`,
`anole_h3`) to info:

```zig
pub const std_options = anole.std_options;
```

`anole.logFn` is kept for programs that set it. It renames the scopes older
builds of the HTTP core used and is otherwise std's
default.

## Metrics

`Registry` holds counters, gauges and histograms, each with labels.
`serveOn` serves the registry at a path in the Prometheus text format
(version 0.0.4). A registry belongs to whoever creates it, and serves only
its own metrics, so two servers in one process can each serve their own.

`HttpMetrics` is a middleware that keeps three series:

| Metric | Type | Labels |
| --- | --- | --- |
| `anole_http_requests_total` | counter | `method`, `route`, `status` |
| `anole_http_request_duration_seconds` | histogram | `method`, `route` |
| `anole_http_requests_in_flight` | gauge | none |

`route` is the route pattern (`/users/:id`), never the raw path, so the
number of series stays bounded. Requests that match no route get
`route="unmatched"`. The histogram uses Prometheus' default buckets, 5 ms to
10 s. It times the middleware after it and the handler, so add it first to
include the time of the other middleware. Its only option is `.exclude`.

Your own metrics come from the same registry:

```zig
const lookups = try registry.counter("example_user_lookups_total", "User lookups, by how they arrived.", &.{"via"});
lookups.with(&.{"direct"}).inc();

const maint = try registry.gauge("example_maintenance", "1 while in maintenance mode.", &.{});
maint.with(&.{}).set(1);

const work = try registry.histogram("job_seconds", "Job time.", &.{}, &anole.observe.metrics.default_buckets);
work.with(&.{}).observe(0.042);
```

`with` takes one value per label and makes the series on first use. Keep
label values to a small, fixed set. Updates are atomic and safe from any
executor.

A histogram's buckets must be finite and strictly increasing, or
`histogram` returns `error.InvalidBuckets`; `+Inf` is always added after
them. A value equal to a bound counts in that bucket (`le` is "less than or
equal"). The sum is kept as a float, added to atomically, so it is exact to
the float in the values' own unit: seconds for the duration histograms,
where `observeDuration` takes a `std.Io.Duration` and keeps its
nanoseconds. Output from the example, histogram buckets trimmed:

```
# HELP anole_http_requests_total HTTP requests answered.
# TYPE anole_http_requests_total counter
anole_http_requests_total{method="GET",route="/users/:id",status="200"} 3
anole_http_requests_total{method="GET",route="/readyz",status="503"} 1
anole_http_requests_total{method="GET",route="unmatched",status="404"} 1
# HELP example_user_lookups_total User lookups, by how they arrived.
# TYPE example_user_lookups_total counter
example_user_lookups_total{via="direct"} 1
example_user_lookups_total{via="traced"} 2
# HELP anole_http_requests_in_flight HTTP requests being answered.
# TYPE anole_http_requests_in_flight gauge
anole_http_requests_in_flight 1
anole_http_request_duration_seconds_bucket{method="GET",route="/chain/:id",le="0.005"} 1
anole_http_request_duration_seconds_bucket{method="GET",route="/chain/:id",le="+Inf"} 1
anole_http_request_duration_seconds_sum{method="GET",route="/chain/:id"} 0.001288
anole_http_request_duration_seconds_count{method="GET",route="/chain/:id"} 1
```

### Runtime gauges

`app.metrics` also serves gauges per executor, refreshed on every scrape:

| Metric | Labels | Meaning |
| --- | --- | --- |
| `anole_runtime_tasks` | `executor` | Tasks alive (spawned minus finished). |
| `anole_runtime_run_queue` | `executor` | Tasks waiting in the executor's run queue. |
| `anole_runtime_stack_committed_bytes` | none | Memory held by coroutine stacks in use (a lower bound: stacks times their initial committed size). |
| `anole_connections` | `executor` | Open connections. |
| `anole_streams` | `executor`, `protocol` | Open HTTP/2 and HTTP/3 request streams. |

The `anole_runtime_*` series come from zio's `diagnostics` option, which
`anole.zio_options` turns on (one relaxed atomic add per task spawned and
finished). A program that declares its own `zio_options` without it gets
only `anole_connections` and `anole_streams`. A registry of your own gets
them with `registry.runtime_gauges = true`.

## Tracing

`trace.Middleware` makes one server span per request. If the request has a
valid W3C `traceparent` header, the span joins that trace, with the
caller's span as its parent. Otherwise it starts a new trace. Handlers see
the IDs as `req.trace_id` (32 hex characters) and `req.span_id` (16).

`trace.Exporter` batches finished spans and sends them to an OTLP/HTTP
collector as JSON, with `POST {endpoint}/v1/traces`. It sends through the
`anole.http.Client` you pass in. Options:

- `.endpoint`: the collector's base URL, such as `http://127.0.0.1:4318`.
- `.service_name`: the `service.name` resource attribute.
- `.batch_size` (256) and `.interval` (2 s): the most spans per POST,
  and the pause after a POST that did not fill a batch.
- `.queue_len` (4096): spans waiting beyond this are dropped.
- `.sample_all` (true): trace every request. With false, trace only
  requests whose `traceparent` has the sampled flag set. The others are
  not recorded, but a caller's unsampled context is still passed on: the
  request gets the caller's trace and span IDs, and `trace.outgoing` sends
  them on with the flag still unset (`-00`).
- `.exclude`: paths the middleware does not trace (see [Wiring](#wiring)).

Call `start` once the runtime exists. `deinit` sends what is still queued
and stops the batching task; call it after `app.run` returns and before the
client is freed. It wakes the task from its pause between batches, so it
returns as soon as the last POST is done. The atomics
`exporter.exported` and `exporter.dropped` count spans sent and spans lost
(queue full, collector unreachable or answering anything but 200). With no
collector listening the server runs normally, and every span is dropped.

The example reads the endpoint from `OTEL_EXPORTER_OTLP_ENDPOINT`. One span
as a collector receives it:

```json
{"traceId":"4bf92f3577b34da6a3ce929d0e0e4736","spanId":"4927554614a944ac","parentSpanId":"00f067aa0ba902b7","name":"GET /users/:id","kind":2,"startTimeUnixNano":"1792333386657079000","endTimeUnixNano":"1792333386657251000","attributes":[{"key":"http.request.method","value":{"stringValue":"GET"}},{"key":"http.route","value":{"stringValue":"/users/:id"}},{"key":"http.response.status_code","value":{"intValue":"200"}}],"status":{"code":0}}
```

The span name is the method and route pattern. Status code 2 (error) marks
a 5xx response; anything else is left unset (0).

`exporter.flush(timeout)` sends the spans queued so far and waits until the
collector has answered for them, or `timeout` passes (the spans are not lost
then; the batching task keeps going). It is for a process that may be
frozen right after the call: the AWS Lambda adapter calls it after each
answer and before asking for the next invocation, bounded by
`lambda.flush_timeout` (500 ms). Several callers may flush at once; each
waits for the spans queued when it called. A canceled caller returns at once
and stays canceled. It does nothing before `start`, and returns at once
after `close`.

On AWS Lambda, an invocation carries X-Ray's trace ID
(`Root=1-5759e988-bd862e3fe1be46a994272793;Parent=53995c3f42cd8ad8;Sampled=1`).
When the request has no `traceparent`, the adapter adds one made from it:
`00-5759e988bd862e3fe1be46a994272793-53995c3f42cd8ad8-01` (the root's two
hex parts joined, the parent, and the sampled flag), so the span joins
X-Ray's trace. A trace ID that does not parse adds nothing.

### Passing the trace on

For an outgoing call, `anole.observe.trace.outgoing(req, &buf)` returns a
`traceparent` that names the current span as the parent. Add it to the
request's headers:

```zig
var headers = try anole.http.Headers.init(req.arena, 1);
var tp_buf: [55]u8 = undefined;
if (anole.observe.trace.outgoing(req, &tp_buf)) |tp| try headers.put("traceparent", tp);
var response = try client.fetch(url, .{ .headers = &headers });
```

It returns null when the request has no span. The example's `/chain/9`
calls its own `/users/9` this way. The collector then gets three spans in
one trace: the caller's span `b7ad6b7169203331`, the `/chain/:id` span
(`3826a7b7b19383df`) as its child, and the `/users/:id` span as the child of
that. The header carries the sampled flag (`-01`) for a recorded request,
and the caller's unset flag (`-00`) for one passed on unrecorded. Clients
do not add it on their own.

`anole.observe.trace.current(req, &buf)` is the same context for work the
request hands on rather than calls: its span when it is recorded here, else
the caller's `traceparent` as it came, every trace flag kept (W3C Level 2's
random flag too; null when there is neither), and
`trace.currentState(req)` the caller's `tracestate` beside it. A job
enqueued from a request keeps both.

### Jobs

With `app.jobs` beside `app.tracing()`, every run of a job is a CONSUMER
span `process <queue>`, in a trace of its own, **linked** to the context the
job was enqueued from (its stored `traceparent` and `tracestate`) rather
than a child of it. The attributes and the sampling rule are in
[Jobs](jobs.md#metrics-and-traces).

## Health and readiness

`Health.registerOn` serves two routes:

- `GET /healthz`: 200 `ok` while the process can answer at all.
- `GET /readyz`: 200 `ok` when every check passes; 503 with
  `not ready: <name>` naming the first failing check; 503 `draining` once
  the server has started to drain.

`Health.init(.{ .healthz_path = ..., .readyz_path = ... })` serves them
elsewhere. A `Health` belongs to whoever creates it and serves the server it
is registered on, so two servers in one process can each have their own;
it must outlive the server.

A check is a `fn (ctx: ?*anyopaque) bool` plus a context pointer, added with
`addCheck(name, fn, ctx)`; up to 16 per server. Checks run on every
`/readyz` request, so keep them cheap: read a flag that a background task
keeps current rather than querying a database.

From the example, after `POST /maintenance` on its admin port:

```
HTTP/1.1 503 Service Unavailable
Content-Type: text/plain; charset=UTF-8
Content-Length: 23

not ready: maintenance
```

### During a drain

On SIGINT or SIGTERM, `app.run` stops accepting connections and drains the
requests in flight. From that moment the server answers any new request on
an open HTTP/1.1 connection with 503 before routing, and closes keep-alive
connections after their current response. Some requests still reach the
router: an HTTP/2 stream opened before the final GOAWAY, or a request that
was already past that check. `/readyz` answers those 503 `draining` too, so
a load balancer polling it sees 503 or a refused connection as soon as the
drain starts. There is no period in which readiness fails while the server
still takes new work. To take a node out of rotation first, fail a
readiness check (as the example's `POST /maintenance` does), wait for the
balancer to notice, then send SIGTERM.

## gRPC health

For gRPC clients and Kubernetes' gRPC probes, `anole.grpc.Health` serves the
standard `grpc.health.v1.Health` service. See
[The health service](grpc.md#the-health-service) in the gRPC guide.
