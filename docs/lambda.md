# AWS Lambda

The same app, as a Lambda function. With `deployment = .lambda` (or
`ANOLE_DEPLOYMENT=lambda`) `app.run()` serves invocations from the Lambda
Runtime API instead of opening listeners: each HTTP event becomes a request
on the router, with the middleware and error mapping you already have, and
the answer goes back in the shape its front door expects. `zig build lambda`
writes the zips.

This page is a draft of what 0.4 ships. The adapter's parts (event mapping,
answers, the Runtime API client, the exchange, `client.upload`,
`client.closeIdle`, `Exporter.flush`) are built and tested; the options on
`ServerOptions`, the deployment mode and `zig build lambda` arrive with the
server wiring and are marked as such.

## When to use it

Lambda suits spiky or low traffic, a webhook receiver, a scheduled job or an
API that is idle most of the day: you pay per invocation and nothing runs
between them. A server is better for WebSockets, long-lived streams and
steady load, where a process that stays up is cheaper and faster. Both run
the same `main`.

## Quick start

```zig
pub fn main(init: std.process.Init) !void {
    var app = try anole.App.init(init.gpa, .{ .process = init.minimal });
    defer app.deinit();
    app.get("/hello", hello);
    try app.listen(":3000"); // locally: a server. On Lambda: invocations.
}
```

In `build.zig` (lands with the server wiring):

```zig
anole.addApp(b, .{ .name = "api", .root = b.path("src/main.zig"), .lambda = .{} });
```

```
zig build lambda
aws lambda create-function --function-name api --runtime provided.al2023 \
  --architectures arm64 --handler bootstrap \
  --zip-file fileb://zig-out/lambda/api-arm64.zip --role <role-arn>
aws lambda create-function-url-config --function-name api --auth-type NONE
```

The zips are `zig-out/lambda/<name>-arm64.zip` and `<name>-x86_64.zip`. Each
holds `bootstrap` (mode 0755) and the files you list in `include`. They are
made by a Zig-only writer with a fixed timestamp, so the same build gives the
same bytes and a rebuild does not trigger a redeploy.

## What reaches your routes

| Front door | Method and path | Query | Headers | Client |
|---|---|---|---|---|
| API Gateway REST (payload 1.0) | `httpMethod`, `path` (API Gateway decodes it; Anole encodes it again) | `multiValueQueryStringParameters`, encoded | `multiValueHeaders`, one field per value | `requestContext.identity.sourceIp` |
| API Gateway HTTP API (2.0) | `requestContext.http.method`, `rawPath` as sent | `rawQueryString` as sent | `headers`; `cookies` joined into one `cookie` | `requestContext.http.sourceIp` |
| Function URL (2.0) | as HTTP API | as HTTP API | as HTTP API | as HTTP API |
| Application Load Balancer | `httpMethod`, `path` as sent | as sent (ALB does not decode) | `multiValueHeaders` or `headers` | last `X-Forwarded-For` entry |
| VPC Lattice (v2) | `method`, `path` | `queryStringParameters`, as sent | `headers` | last `X-Forwarded-For` entry |

Everything else (SQS, SNS, S3, EventBridge, schedules, DynamoDB streams, API
Gateway WebSocket events) is not an HTTP request; see "Events that are not
HTTP".

Detection goes by which fields are present, in this order: `requestContext.elb`
(ALB), `requestContext.serviceArn` (Lattice), version `2.0` with
`requestContext.http` (HTTP API, or a Function URL when the domain contains
`.lambda-url.`), `httpMethod` without an `eventType` (REST). A REST event
behind a custom domain that also carries `rawPath` stays REST.

- **Stage.** A named stage at the front of an HTTP API path (`/prod/users`) is
  removed, so the app sees `/users` as it does locally (`keep_stage` keeps
  it). `$default` is no prefix.
- **Base path.** `base_path` is taken off the front of every path, on a
  segment boundary only (`/v1` strips `/v1/users` and `/v1`, not `/v1x`).
- **Host.** An event without a `host` header gets the API's domain name.
- **Body.** Base64 bodies are decoded before the handler sees them.
- **Secure.** True for every front door but ALB, which reports it in
  `X-Forwarded-Proto`.
- **Spoofing.** A client's own `x-amzn-request-context`,
  `x-amzn-lambda-context` and `Expect` headers are removed.
- **Client address.** What the front door computed. With `proxy.trusted`
  set (CloudFront in front of API Gateway, say), the forwarded-for walk
  starts from it.

## Answers

Each front door wants a different JSON shape, and Anole writes it:

- REST answers carry `multiValueHeaders` only, so repeated `Set-Cookie`
  headers stay repeated.
- HTTP API and Function URL answers carry `headers` (repeats joined with
  `, `) and `cookies`.
- ALB answers carry `statusDescription` and `multiValueHeaders` when the
  event had them, else `headers`. ALB takes one value per header unless the
  target group attribute `lambda.multi_value_headers.enabled` is on; with
  several `Set-Cookie` headers and the attribute off, only the first is sent,
  and one warning says so.
- VPC Lattice answers carry `headers`.

Header names are lowercase. `Connection`, `Keep-Alive`, `Transfer-Encoding`,
`Upgrade`, `TE`, `Trailer`, `Proxy-Connection` and `Content-Length` are
dropped; each front door computes the length itself. Trailers are not carried.

**Text or base64.** The body is sent as JSON text when it has no content
coding, its type is textual (none, `text/*`, `application/json`,
`application/javascript`, `application/xml`, `application/yaml`,
`application/x-www-form-urlencoded`, or a `+json`, `+xml` or `+yaml` suffix)
and it is valid UTF-8. Everything else is base64. For a REST API, set
`binaryMediaTypes` to `*/*` so API Gateway decodes it.

**Limits.** A buffered answer may be 6,291,556 bytes encoded, 1 MiB for ALB.
Past that, Lambda would fail the invocation and API Gateway would answer a
bare 502; Anole answers **500** with `response too large for Lambda (N bytes;
the limit is M)` and logs the route. Use streaming (below) for larger bodies.

## Streaming

`invoke_mode = .response_stream` (or `ANOLE_LAMBDA_INVOKE_MODE=response_stream`)
answers Function URLs set to `RESPONSE_STREAM`, and REST integrations with
`responseTransferMode=STREAM`, over Lambda's streaming protocol: a JSON
prelude, eight NUL bytes, then the body as it is written. The Runtime API does
not say how a function was invoked, so this is configuration. ALB, HTTP API and
Lattice events are always answered buffered. Server-sent events work here: one
stream per invocation, up to the 15-minute limit. A failure after the head went
out ends the stream with error trailers (`Function.StreamFailed` or, past the
deadline, `Function.Timeout`).

## Events that are not HTTP

An SQS batch, an EventBridge schedule, an S3 notification and the like are
POSTed through the router to `lambda.event_path` (default `/_lambda/event`) with
the event JSON as the body. A 2xx answer's body is the invocation's result
(empty becomes `null`); any other status fails the invocation as
`Function.Status<code>`, with the first 1 KiB of the body as the message.

```zig
app.post(anole.lambda.default_event_path, onQueue);

fn onQueue(req: *anole.Request, res: *anole.Response) !void {
    const Batch = struct { Records: []const struct { messageId: []const u8, body: []const u8 } };
    const batch = try req.json(Batch);
    _ = batch;
    // Partial batch failure: list the messages to retry.
    try res.json(.{ .batchItemFailures = &[_]struct { itemIdentifier: []const u8 }{} });
}
```

The path is reserved: an HTTP request for it gets 404 and never reaches the
route, so nobody can forge a queue message through a Function URL. With
`event_path = null`, such events fail with `Runtime.UnsupportedEvent`.

## The invocation

`anole.lambda.context(req)` returns a typed `Context` (request ID, deadline,
function ARN, X-Ray trace ID, source, stage, the parsed `requestContext`, the
raw event), or null outside a Runtime API invocation. `req.id` is Lambda's
request ID, and the `RequestId` middleware keeps it.

Handlers in other languages get the same data as headers:
`x-amzn-request-context` (the event's `requestContext` as JSON) and
`x-amzn-lambda-context` (`request_id`, `deadline`, `invoked_function_arn`,
`xray_trace_id`, `client_context`, `identity`, `env_config`), with the names
and shapes AWS Lambda Web Adapter uses, so code written for it works. When the
request has no `traceparent`, one is made from the X-Ray trace ID so the span
tracer joins X-Ray's trace.

## Deadlines

A request's timeout is the smaller of `timeouts.request` and the invocation's
deadline minus `deadline_margin` (100 ms). When it fires, the handler is
canceled and the client gets 504, before Lambda's own timeout kills the
environment and loses the answer. `Request.setTimeout` can move the timer
within that ceiling, never past it.

## Connections and the freeze

Lambda freezes the process between invocations. Nothing is started to run in
the gap. The trace exporter is flushed (`Exporter.flush`, bounded by
`flush_timeout`) before each next-invocation call, so spans are not stranded in
a frozen queue. When an invocation arrives more than `idle_reset` (300 s) after
the last ended, idle outbound and database connections are closed first
(`Client.closeIdle` and each connector's `closeIdle`), because a NAT gateway
drops an idle TCP connection after 350 s without telling either end.

Postgres on Lambda wants RDS Proxy: every environment holds its own pool, so
many environments multiply connections. Pools are lazy and capped per
executor; with one executor each environment holds at most a handful.

## The client additions

`client.upload(url, options)` starts a request whose body is written as it
goes (chunked, with optional trailers), over HTTP/1.1 only, with no redirects:

```zig
var up = try client.upload(url, .{ .trailer_names = &.{"X-Checksum"} });
try up.writer.writeAll("part one");
try up.writer.flush();            // sends one chunk
var trailers = try anole.Headers.init(gpa, 2);
try trailers.put("X-Checksum", "abc");
var response = try up.finish(&trailers);
defer response.deinit();
```

`up.abort()` closes the connection instead. `client.closeIdle()` closes the
idle pooled connections of every executor. `Exporter.flush(timeout)` sends the
queued spans and waits for the collector.

## Running locally

The same `main` runs as a server with `zig build run`. To exercise the Lambda
path, use the Runtime Interface Emulator:

```
docker run -p 9000:8080 -v $PWD/zig-out/lambda:/var/task \
  public.ecr.aws/lambda/provided:al2023 bootstrap
curl -d '{"httpMethod":"GET","path":"/hello","requestContext":{}}' \
  http://localhost:9000/2015-03-31/functions/function/invocations
```

## What does not fit Lambda

No inbound connections exist, so WebSocket, WebTransport, HTTP/3, raw TCP and
UDP listeners are not served; API Gateway WebSocket events arrive as events.
Native gRPC needs HTTP/2 trailers, which Lambda's front doors do not pass;
gRPC-Web, Connect and JSON transcoding work. Job workers and cron do not run
between invocations; trigger them with EventBridge Scheduler on the event path.
Broker subscriptions belong to event source mappings.

## Planned with the server wiring

These arrive with the rest of the adapter and are described in the design:
the `lambda` options (`runtime_api`, `invoke_mode`, `concurrency`,
`event_path`, `base_path`, `keep_stage`, `context_headers`,
`deadline_margin`, `idle_reset`, `sigterm`, `shutdown_timeout`,
`flush_timeout`), the SIGTERM extension, Lambda Managed Instances
(concurrent invocations), Web Functions (`AWS_LAMBDA_HTTP_ENDPOINT`), the
`zig build lambda` zips (arm64 `neoverse_n1`, x86_64 `x86_64_v2+avx2`,
glibc 2.34), init errors, and Node and Python apps through an exec wrapper.
SnapStart is refused with a clear init error: restored copies would share
random-number state.
