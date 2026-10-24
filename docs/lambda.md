# AWS Lambda

The same app, as a Lambda function. With `deployment = .lambda` (or
`ANOLE_DEPLOYMENT=lambda`, or a build made by `zig build lambda`, whose
default it is) `app.run()`, `listen` and `listenTls` serve invocations from
the Lambda Runtime API instead of opening listeners. Each HTTP event becomes
a request on the router, with the middleware, JSON errors and logs you
already have, and the answer goes back in the shape its front door expects.
Every difference from a server is printed in the first log lines.

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
    try app.listen(":3000"); // locally: a server. Under zig build lambda: invocations.
}
```

In `build.zig`, ask `addApp` for the Lambda step:

```zig
pub fn build(b: *std.Build) void {
    _ = @import("anole").addApp(b, .{
        .name = "api",
        .root_source_file = b.path("src/main.zig"),
        .lambda = .{},
    });
}
```

`.lambda` takes `arch` (both `.arm64` and `.x86_64` by default),
`include` (files and directories put beside `bootstrap`, such as static files
and templates; Lambda runs the program in that directory), `optimize`
(`ReleaseSafe`) and `libc` (`.glibc`, 2.34 as on Amazon Linux 2023, or
`.musl` for a static binary). Then:

```
zig build lambda
aws lambda create-function --function-name api --runtime provided.al2023 \
  --architectures arm64 --handler bootstrap \
  --zip-file fileb://zig-out/lambda/api-arm64.zip --role <role-arn>
aws lambda create-function-url-config --function-name api --auth-type NONE
curl https://<url-id>.lambda-url.<region>.on.aws/hello
```

The steps are `lambda` (both zips), `lambda-arm64` and `lambda-x86_64`;
`-Dlambda-arch` picks one architecture and `-Dlambda-optimize` overrides the
optimize mode. The zips are `zig-out/lambda/<name>-arm64.zip` and
`<name>-x86_64.zip`, each holding `bootstrap` (mode 0755) and the `include`
files. arm64 is built for Graviton2 (`neoverse_n1`), x86_64 for
`x86_64_v2+avx2`. A Zig-only writer makes them with a fixed timestamp, so
the same build gives the same bytes and a rebuild does not trigger a
redeploy.

With AWS SAM:

```yaml
Resources:
  Api:
    Type: AWS::Serverless::Function
    Properties:
      Runtime: provided.al2023
      Handler: bootstrap
      Architectures: [arm64]
      CodeUri: zig-out/lambda/api-arm64.zip
      FunctionUrlConfig: { AuthType: NONE }
```

A container image works too: `FROM public.ecr.aws/lambda/provided:al2023`,
then `COPY bootstrap ${LAMBDA_RUNTIME_DIR}` (build with `libc = .musl` or
glibc).

## What reaches your routes

| Front door | Method and path | Query | Headers | Client |
|---|---|---|---|---|
| API Gateway REST (payload 1.0) | `httpMethod`, `path` (API Gateway decodes it; Anole encodes it again) | `multiValueQueryStringParameters`, encoded | `multiValueHeaders`, one field per value | `requestContext.identity.sourceIp` |
| API Gateway HTTP API (2.0) | `requestContext.http.method`, `rawPath` as sent | `rawQueryString` as sent | `headers`; `cookies` joined into one `cookie` | `requestContext.http.sourceIp` |
| Function URL (2.0) | as HTTP API | as HTTP API | as HTTP API | as HTTP API |
| Application Load Balancer | `httpMethod`, `path` as sent | as sent (ALB does not decode) | `multiValueHeaders` or `headers` | last `X-Forwarded-For` entry |
| VPC Lattice (v2) | `method`, `path` (with its query) | as sent | `headers`, one field per value | last `X-Forwarded-For` entry |

Everything else (SQS, SNS, S3, EventBridge, schedules, DynamoDB streams, API
Gateway WebSocket events) is not an HTTP request; see
[Events that are not HTTP](#events-that-are-not-http).

Detection goes by which fields are present, in this order:
`requestContext.elb` (ALB), `requestContext.serviceArn` (Lattice), version
`2.0` with `requestContext.http` (HTTP API, or a Function URL when the
domain contains `.lambda-url.`), `httpMethod` with a `requestContext` and no
`eventType` (REST). A REST event behind a custom domain that also carries
`rawPath` stays REST.

- **Stage.** A named stage at the front of an HTTP API path (`/prod/users`)
  is removed, so the app sees `/users` as it does locally;
  `lambda.keep_stage = true` keeps it. `$default` is no prefix.
- **Base path.** `lambda.base_path` (the base path of an API Gateway custom
  domain mapping, such as `/v1`) is taken off the front of every path, on a
  segment boundary only: `/v1` strips `/v1/users` and `/v1`, not `/v1x`.
- **Host.** An event without a `host` header gets the API's domain name.
- **Body.** Base64 bodies are decoded before the handler sees them.
- **Secure.** `req.secure` is true for every front door but ALB, which
  reports it in `X-Forwarded-Proto`.
- **Spoofing.** A client's own `x-amzn-request-context`,
  `x-amzn-lambda-context` and `Expect` headers are removed.
- **Client address.** What the front door computed. With `proxy.trusted`
  set (CloudFront in front of API Gateway, say), the forwarded-for walk
  starts from it.
- **Methods.** A method the server does not know is answered 501.

An event that is not JSON, an HTTP event without its method or path, a path
that does not start with `/` or a base64 body that does not decode fails the
invocation as `Runtime.InvalidEvent`; the log line names the event's keys,
never its values.

## Answers

Each front door wants a different JSON shape, and Anole writes it:

- REST answers carry `multiValueHeaders` only, so repeated `Set-Cookie`
  headers stay repeated.
- HTTP API and Function URL answers carry `headers` (repeats joined with
  `, `) and `cookies`.
- ALB answers carry `statusDescription` (`404 Not Found`) and
  `multiValueHeaders` when the event had them, else `headers`.
- VPC Lattice answers carry `headers`.

**Cookies on single-value front doors.** ALB takes one value per header
unless the target group attribute `lambda.multi_value_headers.enabled` is
on, and Lattice always does. With several `Set-Cookie` headers there, only
the first is sent, and one warning per process says so: `lambda: a response
set <n> cookies, but this ALB target group takes one value per header, so
only the first was sent; for ALB, turn on the target group attribute
lambda.multi_value_headers.enabled`.

Header names are lowercase. `Connection`, `Keep-Alive`, `Transfer-Encoding`,
`Upgrade`, `TE`, `Trailer`, `Proxy-Connection` and `Content-Length` are
dropped; each front door computes the length itself. A HEAD answer, a 204
and a 304 have an empty body. Trailers are not carried: Lambda's answers
have none.

**Text or base64.** The body is sent as JSON text when it has no content
coding, its type is textual (none, `text/*`, `application/json`,
`application/javascript`, `application/xml`, `application/yaml`,
`application/x-www-form-urlencoded`, or a `+json`, `+xml` or `+yaml` suffix)
and it is valid UTF-8. Everything else (a gzip answer from `Compress`, an
image) is base64. For a REST API, set `binaryMediaTypes` to `*/*` so API
Gateway decodes it.

**Limits.** A buffered answer may be 6,291,556 bytes encoded, 1 MiB for ALB.
Past that, Lambda would fail the invocation and API Gateway would answer a
bare 502; Anole answers **500** with `response too large for Lambda (N bytes;
the limit is M)` instead, and logs the route. Use streaming for larger
bodies.

## Streaming

`lambda.invoke_mode = .response_stream` (or
`ANOLE_LAMBDA_INVOKE_MODE=response_stream`) answers Function URLs set to
`RESPONSE_STREAM`, and REST integrations with
`responseTransferMode=STREAM`, over Lambda's streaming protocol: a JSON
prelude (with `content-type` `application/octet-stream` when the response
names none), eight NUL bytes, then the body as the handler writes it. The
Runtime API does not say how a function was invoked, so this is
configuration. ALB, HTTP API and Lattice events are always answered
buffered.

Server-sent events work here: one stream per invocation, up to the
15-minute limit (topics and fan-out across invocations are pointless, since
each invocation has one subscriber). Lambda caps a streamed answer at
200 MB, and limits its bandwidth after the first 6 MB.

A failure after the head went out ends the stream with Lambda's error
trailers: `Function.StreamFailed`, or `Function.Timeout` when the deadline
passed.

```yaml
      FunctionUrlConfig: { AuthType: NONE, InvokeMode: RESPONSE_STREAM }
      Environment:
        Variables: { ANOLE_LAMBDA_INVOKE_MODE: response_stream }
```

## Events that are not HTTP

An SQS batch, an EventBridge schedule, an S3 notification and the like are
POSTed through the router to `lambda.event_path` (default `/_lambda/event`,
`anole.lambda.default_event_path`) with the event JSON as the body and
`content-type: application/json`. A 2xx answer's body is the invocation's
result (empty becomes `null`); any other status fails the invocation as
`Function.Status<code>`, with the first 1 KiB of the body as the message (a
missing route is `Function.Status404`).

```zig
app.post(anole.lambda.default_event_path, onQueue);

fn onQueue(req: *anole.Request, res: *anole.Response) !void {
    const Batch = struct { Records: []const struct { messageId: []const u8, body: []const u8 } };
    const batch = try req.json(Batch);
    const Failure = struct { itemIdentifier: []const u8 };
    var failed: std.ArrayList(Failure) = .empty;
    for (batch.Records) |m| {
        handle(m.body) catch try failed.append(req.arena, .{ .itemIdentifier = m.messageId });
    }
    // Partial batch failure: only these messages go back to the queue
    // (turn on ReportBatchItemFailures in the event source mapping).
    try res.json(.{ .batchItemFailures = failed.items });
}
```

Schedules come from EventBridge Scheduler targeting the function; tell
them apart by the event's own fields (`source`, `detail-type`). API Gateway
WebSocket events (`$connect`, `$disconnect`, messages) arrive here as
events too.

The path is reserved: an HTTP request for it gets 404 and never reaches the
route, so nobody can forge a queue message through a Function URL. With
`event_path = null`, such events fail with `Runtime.UnsupportedEvent`.

## The invocation

`anole.lambda.context(req)` returns a typed `*const Context`, or null outside
a Runtime API invocation (on a server, and on a web function):

| Field | What |
|---|---|
| `request_id` | `Lambda-Runtime-Aws-Request-Id` (also `req.id`) |
| `invocation_id` | `Lambda-Runtime-Invocation-Id`, empty when Lambda sent none |
| `deadline_ms` | the deadline, Unix milliseconds |
| `function_arn` | the invoked function's ARN |
| `trace_id` | X-Ray's `Root=...;Parent=...;Sampled=1`, empty when none |
| `source` | `.rest_api`, `.http_api`, `.function_url`, `.alb`, `.vpc_lattice` or `.event` |
| `stage` | API Gateway's stage, null for other sources |
| `request_context` | the event's `requestContext` (authorizer claims, identity), parsed |
| `event` | the whole event as Lambda sent it |
| `client_context`, `cognito_identity` | from the mobile SDKs, empty when absent |

`req.id` is Lambda's request ID: the `RequestId` middleware keeps an ID the
engine set already, so logs and the answer's request ID header carry the ID
the Lambda console shows.

Handlers in other languages (and Zig code that prefers headers) get the same
data as two request headers, unless `lambda.context_headers = false`:
`x-amzn-request-context` (the event's `requestContext` as JSON) and
`x-amzn-lambda-context` (`request_id`, `deadline`, `invoked_function_arn`,
`xray_trace_id`, `client_context`, `identity`, and `env_config` with
`function_name`, `memory`, `version`, `log_stream`, `log_group`). The names
and shapes are the AWS Lambda Web Adapter's, so code written for it (Hono's
and Express's helpers) works unchanged.

When the request has no `traceparent`, one is made from the X-Ray trace ID
(`Root=1-5759e988-bd862e3fe1be46a994272793;Parent=53995c3f42cd8ad8;Sampled=1`
becomes `00-5759e988bd862e3fe1be46a994272793-53995c3f42cd8ad8-01`), so the
span tracer joins X-Ray's trace. Anole never sets `_X_AMZN_TRACE_ID`: it does
not change the process environment.

## Deadlines

A request's timeout is the smaller of `timeouts.request` and the
invocation's deadline minus `lambda.deadline_margin` (100 ms). When it
fires, the handler is canceled and the client gets 504 through the error
mapping (JSON or text, as `errors` says), before Lambda's own timeout kills
the environment and loses the answer. An invocation that arrives with less
than the margin left is answered 504 without running the handler.
`req.setTimeout` can move the timer within that ceiling, never past it. A
streamed answer whose deadline passes after its head ends with the
`Function.Timeout` trailer, and a non-HTTP event past its deadline fails as
`Function.Timeout`.

## Connections and the freeze

Lambda freezes the process between invocations. Nothing is started to run in
the gap. After each answer, and before asking for the next invocation, the
trace exporter is flushed (`Exporter.flush`, bounded by
`lambda.flush_timeout`, 500 ms), so spans are not stranded in a frozen
queue; the client already has its answer by then.

When an invocation arrives more than `lambda.idle_reset` (300 s) after the
last one ended, the idle connections of the outbound client
(`client.closeIdle()`) and of every connector that has a `closeIdle`
(PostgreSQL, Redis, MongoDB, S3, SMTP) are closed before it runs: a NAT
gateway forgets an idle TCP connection after 350 s without telling either
end, and a query on such a socket would hang until its timeout. SQLite
needs none. `idle_reset = null` turns it off.

Every environment holds its own pools, and Lambda may start many
environments. Pools are lazy and capped per executor (with one executor,
the usual case, a handful of connections each), but a burst still
multiplies them: for PostgreSQL, put RDS Proxy in front. Everything before
`run()` is Lambda's INIT phase, so `connect_at_start = true` opens the first
connection there instead of in the first invocation. See
[database.md](database.md#on-aws-lambda).

## Shutdown

Without any extension, Lambda kills the process with no warning when it
retires an environment. With `lambda.sigterm = true` (the default) Anole
registers a no-op internal extension (`anole-sigterm`, subscribed to no
events) before its first invocation, so Lambda sends SIGTERM and allows
500 ms. On SIGTERM (or SIGINT, or `app.stop()`), Anole stops asking for
invocations, lets one in progress finish, flushes the spans, and returns
from `run` within `lambda.shutdown_timeout` (400 ms); your `defer
app.deinit()` then closes the connectors. SIGHUP and SIGUSR2 are not watched.
On Lambda Managed Instances the extension is not used. If registering it
fails, one warning says shutdown will be a kill, and serving carries on.

## Logs and tracing

A release build is production: logs are JSON Lines, which CloudWatch Logs
reads as JSON, and every request record carries `request_id`, Lambda's
request ID. For OTLP traces, add the AWS Distro for OpenTelemetry collector
layer and point `OTEL_EXPORTER_OTLP_ENDPOINT` at it
(`http://127.0.0.1:4318`); the spans join X-Ray's trace through the
`traceparent` above and are flushed between invocations.

The first lines say what the mode does:

```
deployment lambda (lambda build): invocations from the Lambda Runtime API at 127.0.0.1:9001, 1 at a time on 1 executor; buffered answers; other events to POST /_lambda/event; SIGTERM through a no-op extension; ready in 3.4 ms
deployment lambda: no listener opens here, so listen(":3000") is set aside; requests come from Lambda
```

The source in parentheses is `options`, `ANOLE_DEPLOYMENT`,
`ANOLE_DEPLOYMENT in .env` or `lambda build`. In streaming mode the line says
`streamed answers for Function URLs and REST APIs`; with `event_path = null`,
`other events fail (event_path is null)`; with `sigterm` off,
`no SIGTERM (sigterm off)`. `ready in` is measured from `App.init`.

Every listener the options name (`http`, `https`, `listeners`, `http3`,
`listen`, `listenTls`, raw TCP and UDP listeners) is set aside, and the
second line names them: Lambda accepts no inbound connections, and the
point of the mode is that the same `main` runs in both places.

A server in the standalone default that sees Lambda's variables says so:

```
AWS_LAMBDA_RUNTIME_API is set: to serve Lambda invocations, set ANOLE_DEPLOYMENT=lambda or build with zig build lambda (behind the Lambda Web Adapter, leave it as is)
AWS_LAMBDA_HTTP_ENDPOINT is set: set ANOLE_DEPLOYMENT=lambda to listen there
```

Anole never switches to Lambda on its own: the Lambda Web Adapter runs apps
with `AWS_LAMBDA_RUNTIME_API` set too, and the two would compete for
invocations.

**Errors.** A failure in `run` before the first invocation (a route conflict,
a connector that cannot start, an invalid option) is sent to Lambda's init
error endpoint as `Function.<ErrorName>` (`Function.RouteConflict`,
`Function.DatabaseUnavailable`) with the same text the log line has, so the
Lambda console shows it, and then `run` returns the error. `stackTrace` is
always empty. The errors of the mode itself:

| Error | When |
|---|---|
| `LambdaRuntimeApiMissing` | `can't start in deployment "lambda": AWS_LAMBDA_RUNTIME_API is not set; Lambda sets it, and so does the Runtime Interface Emulator (docs/lambda.md, "Running locally")` |
| `LambdaNotBuilt` | `can't start in deployment "lambda": this build leaves the Lambda adapter out (-Dlambda)` |
| `LambdaRuntimeApiFailed` | the Runtime API answered 500, or asking it for the next invocation failed three times in a row: `can't go on with the Lambda Runtime API at <api>: <what>; exiting so Lambda starts a new environment` |
| `SnapStartUnsupported` | see [SnapStart](#snapstart) |
| `InvalidEnvironmentVariable` | `AWS_LAMBDA_RUNTIME_API` or `AWS_LAMBDA_HTTP_ENDPOINT` that is not `host:port` (`AWS_LAMBDA_RUNTIME_API="localhost": use host:port`), `ANOLE_LAMBDA_INVOKE_MODE` that is not `buffered` or `response_stream`, `AWS_LAMBDA_MAX_CONCURRENCY` outside 1 to 4096 |

## Options

`ServerOptions.lambda` (also `anole.lambda.Options`), all optional:

| Option | Default | What |
|---|---|---|
| `runtime_api` | `AWS_LAMBDA_RUNTIME_API` | the Runtime API, `host:port`; set, it also wins over `AWS_LAMBDA_HTTP_ENDPOINT` |
| `invoke_mode` | `ANOLE_LAMBDA_INVOKE_MODE`, else `.buffered` | `.buffered` or `.response_stream` |
| `concurrency` | `AWS_LAMBDA_MAX_CONCURRENCY`, else 1 | invocations served at once (1 to 4096) |
| `event_path` | `"/_lambda/event"` | where non-HTTP events go; null: they fail |
| `base_path` | null | taken off the front of every HTTP event's path |
| `keep_stage` | false | keep a named stage at the front of an HTTP API path |
| `context_headers` | true | add `x-amzn-request-context` and `x-amzn-lambda-context` |
| `deadline_margin` | 100 ms | how long before the deadline a request is canceled |
| `idle_reset` | 300 s | close idle connections after a gap this long; null: never |
| `sigterm` | true | register the no-op extension so Lambda sends SIGTERM |
| `shutdown_timeout` | 400 ms | the most the shutdown after SIGTERM may take |
| `flush_timeout` | 500 ms | the most flushing spans may hold up the next invocation |

The platform's variables (`AWS_LAMBDA_*`) are read from the real environment
only, never from `.env`: a `.env` line must not make a development run poll
a Runtime API. `ANOLE_LAMBDA_INVOKE_MODE` may come from `.env`. The rest of
the deployment table is in [config.md](config.md#6-deployment).

## What does not fit Lambda

- **WebSocket, WebTransport, HTTP/3**: Lambda accepts no inbound connections,
  so these routes are never reached. API Gateway WebSocket events arrive as
  [events](#events-that-are-not-http).
- **Native gRPC** needs HTTP/2 trailers, which Lambda's front doors do not
  pass. gRPC-Web, Connect and JSON transcoding work.
- **Raw TCP and UDP listeners** are set aside like the HTTP ones.
- **Job workers and cron** do not run here: the process is frozen between
  invocations. `app.jobs` only enqueues under `lambda` (one startup line says
  so), so a job enqueued here runs where workers run; trigger scheduled work
  with EventBridge Scheduler on the event path. Webhook deliveries are jobs
  too.
- **Broker subscriptions** (NATS subscriptions, JetStream consumers, Kafka
  groups) do not start; publishing works. Use Lambda's event source
  mappings to consume.
- **Database watches** do not run between invocations.
- **`anole.blocking`** works, one invocation at a time.
- **The live console** is off.

## Lambda Managed Instances

On Lambda Managed Instances one environment serves several invocations at
once and is not frozen between them. Lambda sets
`AWS_LAMBDA_MAX_CONCURRENCY`; Anole then starts that many invocation loops
(`lambda.concurrency` overrides it), worker *i* on executor *i* mod the
executor count, and `executors = .auto` stays the CPU count. Under classic
Lambda (concurrency 1), `.auto` becomes one executor: one thread, the least
memory and the fastest init. The SIGTERM extension is not used there.

## Web Functions

Lambda Web Functions run a server that listens on the address in
`AWS_LAMBDA_HTTP_ENDPOINT`. When that variable is set and
`lambda.runtime_api` is not, the same `deployment = lambda` opens one
HTTP/1.1 listener there (no h2c, no HTTP/3) and sets every other listener
aside. `X-Forwarded-For` and `X-Forwarded-Proto` are read from Lambda's local
proxy (`proxy.trusted` defaults to `loopback`, `private`), `req.id` comes
from `lambda-web-request-id`, and SIGTERM drains within the smaller of
`timeouts.shutdown` and 900 ms (Lambda allows 1 s). There is no invocation,
so `anole.lambda.context(req)` is null. AWS offers Web Functions on Node.js
24 only today, so this is how anole-node apps run as Web Functions.

```
deployment lambda (ANOLE_DEPLOYMENT): a Lambda web function: HTTP/1.1 on 127.0.0.1:9002 from AWS_LAMBDA_HTTP_ENDPOINT; X-Forwarded-For and X-Forwarded-Proto from 127.0.0.0/8, ::1/128, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, fc00::/7 (proxy.trusted); drain at most 900 ms
```

## Running locally

The same `main` runs as a server with `zig build run`. To exercise the
Lambda path, use the Runtime Interface Emulator, which sets
`AWS_LAMBDA_RUNTIME_API` for the program it runs:

```
zig build lambda -Dlambda-arch=x86_64      # arm64 on an arm64 machine
mkdir -p zig-out/lambda/api && unzip -o zig-out/lambda/api-x86_64.zip -d zig-out/lambda/api
docker run -p 9000:8080 -v $PWD/zig-out/lambda/api:/var/task \
  public.ecr.aws/lambda/provided:al2023 bootstrap
curl -d '{"version":"2.0","rawPath":"/hello","rawQueryString":"","headers":{},"requestContext":{"http":{"method":"GET","sourceIp":"127.0.0.1"},"domainName":"localhost"}}' \
  http://localhost:9000/2015-03-31/functions/function/invocations
```

`sam local start-api` runs it behind a local API Gateway too.

## Size and cold start

The profile decides what is compiled in: `-Dprofile=minimal` (no TLS, no
HTTP/2) or `web` give the smallest bootstraps and the fastest init, and the
adapter itself is pure Zig with no C library (`-Dlambda`, on in every
profile). arm64 (Graviton) costs less per millisecond than x86_64. glibc is
the default because musl's allocator is slow for the bundled C libraries;
`libc = .musl` gives a static binary for container images. Measured
cold-start numbers will be added here once they are taken on AWS.

## Node and Python apps

Apps on anole-node or anole-py run the native way, with no extra layer: the
binding's process is Lambda's runtime, with `ANOLE_DEPLOYMENT=lambda` in its
environment, so libanole polls the Runtime API and the language's handlers
get requests as usual. On the managed Node.js or Python runtime, an exec
wrapper (`AWS_LAMBDA_EXEC_WRAPPER`) sets the variable and starts the app's
entry file in place of AWS's runtime client; on `provided.al2023`, the same
script is `bootstrap`. On SIGTERM the binding calls `anole_server_drain`.
The C ABI's `lambda` group has the options above, in milliseconds
([c-abi.md](c-abi.md)).

The AWS Lambda Web Adapter is the zero-setup alternative: any Anole app
(Zig or a binding) with `deployment = standalone` or `behind_proxy` runs
behind it, at the cost of an extra hop and process and with no native event
mapping.

## SnapStart

SnapStart is not supported yet. Restored copies of one snapshot would share
every user-space random generator (BoringSSL's per-thread state, the QUIC
secret, ticket keys, session and request IDs), so duplicate secrets would
appear across clones. With `AWS_LAMBDA_INITIALIZATION_TYPE=snap-start` the
adapter fails init with `Function.SnapStartUnsupported`: "lambda: SnapStart
is not supported yet (restored copies would share random-number state)".
Publish the function without SnapStart.
