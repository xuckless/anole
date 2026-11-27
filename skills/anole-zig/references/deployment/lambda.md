# AWS Lambda

Up: [deployment](index.md), [SKILL.md](../../SKILL.md). Related: [addApp](../config-cli.md#build-side-addapp), [deployment modes](../config-cli.md#environment-and-deployment), [tracing](../observability.md#tracing-opentelemetry).

Full docs: docs/lambda.md, docs/config.md (lambda rows). Example: examples/lambda/main.zig. Source: src/lambda/root.zig, `ServerOptions.lambda` (src/server.zig).

The same `main` runs as a server and as a Lambda function. Do not write a Runtime API polling loop or an API Gateway event parser: `deployment = .lambda` makes `run`, `listen` and `listenTls` serve invocations through the router.

## Build and deploy

Use: `AppOptions.lambda` (`LambdaBuild`: `.arch` arm64 and x86_64, `.include`, `.optimize` ReleaseSafe, `.libc` glibc or musl) (build.zig).

```zig
pub fn build(b: *std.Build) void {
    _ = @import("anole").addApp(b, .{
        .name = "api",
        .root_source_file = b.path("src/main.zig"),
        .lambda = .{},
    });
}
```

```
zig build lambda          # zig-out/lambda/api-arm64.zip and api-x86_64.zip (bootstrap inside)
aws lambda create-function --function-name api --runtime provided.al2023 \
  --architectures arm64 --handler bootstrap \
  --zip-file fileb://zig-out/lambda/api-arm64.zip --role <role-arn>
```

A `zig build lambda` binary defaults to `deployment = lambda`; elsewhere set `ANOLE_DEPLOYMENT=lambda`. Steps: `lambda`, `lambda-arm64`, `lambda-x86_64`; `-Dlambda-arch`, `-Dlambda-optimize`.

## The app

```zig
// examples/lambda/main.zig
fn onQueue(req: *anole.Request, res: *anole.Response) !void {
    const batch = try req.bind(Batch);
    for (batch.Records) |r| std.log.info("message {s}: {d} bytes", .{ r.messageId, r.body.len });
    try res.json(.{ .batchItemFailures = &[_]Failure{} });
}

pub fn main(init: std.process.Init) !void {
    var app = try anole.App.init(init.gpa, .{});
    defer app.deinit();
    app.get("/", hello);
    app.post(anole.lambda.default_event_path, onQueue);
    // Under deployment lambda no listener opens: invocations come from
    // the Lambda Runtime API instead, and a startup line says so.
    try app.listen(":3000");
}
```

Use: `anole.lambda.default_event_path` ("/_lambda/event"), `anole.lambda.context(req)` returning `?*const anole.lambda.Context` (`request_id`, `invocation_id`, `deadline_ms`, `function_arn`, `trace_id`, `source`, `stage`, `request_context`, `event`, `client_context`, `cognito_identity`), `anole.lambda.Options` (= `ServerOptions.lambda`) (src/lambda/root.zig).

- HTTP events (API Gateway REST and HTTP APIs, Function URLs, ALB, VPC Lattice) become requests with your middleware and errors.
- Other events (SQS, SNS, S3, EventBridge, schedules, API Gateway WebSocket) are POSTed to `lambda.event_path` as JSON. A 2xx body is the result; any other status fails the invocation.
- `req.id` is Lambda's request ID; handlers also get `x-amzn-request-context` and `x-amzn-lambda-context` headers (`context_headers`).

## Options

`ServerOptions.lambda`: `runtime_api` (null: `AWS_LAMBDA_RUNTIME_API`), `invoke_mode` (`.buffered` or `.response_stream`; `ANOLE_LAMBDA_INVOKE_MODE`), `concurrency` (`AWS_LAMBDA_MAX_CONCURRENCY`, else 1), `event_path`, `base_path`, `keep_stage`, `context_headers` (true), `deadline_margin` (100 ms), `idle_reset` (300 s), `sigterm` (true), `shutdown_timeout` (400 ms), `flush_timeout` (500 ms).

Traps:
- Every named listener is set aside under `lambda` (the one mode that overrides explicit options); one startup line says which.
- The request timeout is the smaller of `timeouts.request` and the deadline minus `deadline_margin`; past it the handler is canceled and the client gets 504.
- The process is frozen between invocations: job workers, cron, broker subscriptions and database watches do not run (`app.jobs` only enqueues); trigger scheduled work with EventBridge Scheduler on the event path.
- WebSocket, WebTransport, HTTP/3, native gRPC and raw TCP/UDP do not fit Lambda; gRPC-Web, Connect and JSON transcoding work.
- Idle pooled connections are closed after `idle_reset` (NAT gateways drop idle TCP silently). For PostgreSQL at scale put RDS Proxy in front.
- Everything before `run()` is Lambda's INIT phase.
- Without `-Dlambda` (on in every profile), `lambda` is refused with `LambdaNotBuilt`; with no Runtime API address, `LambdaRuntimeApiMissing`. SnapStart is refused (`SnapStartUnsupported`).
- `AWS_LAMBDA_*` variables are read from the real environment only, never from `.env`.

## Running locally

`zig build run` serves the same routes as a server. To exercise the Lambda path, run the zip under the Runtime Interface Emulator (docs/lambda.md):

```
zig build lambda -Dlambda-arch=x86_64      # arm64 on an arm64 machine
mkdir -p zig-out/lambda/api && unzip -o zig-out/lambda/api-x86_64.zip -d zig-out/lambda/api
docker run -p 9000:8080 -v $PWD/zig-out/lambda/api:/var/task \
  public.ecr.aws/lambda/provided:al2023 bootstrap
```

Web Functions: with `AWS_LAMBDA_HTTP_ENDPOINT` set, `deployment = lambda` opens one HTTP/1.1 listener there instead, and `anole.lambda.context(req)` is null.
