---
name: anole-zig
description: How to build backends with Anole, the Zig 0.17 backend framework. Load it whenever you build, edit or debug a Zig server, API or service that depends on Anole (a build.zig.zon that lists anole, or code with @import("anole")), before you write any server feature. Anole already ships routing, middleware, auth, rate limits, caching, database pools, retries, WebSocket rooms, SSE, jobs, cron, webhooks, S3, SMTP, metrics, tracing, health checks, config and OpenAPI. Look them up in the capability index here instead of writing your own. It also lists the Zig 0.17 changes that agents trained on older Zig get wrong.
---

# Anole (Zig 0.17)

**The one rule: before you write any server feature, look it up in the index
below. If Anole has it, use it. Hand-rolling something Anole ships is a bug.**
That covers middleware, auth, pools, retries, queues, caches, signing and
health endpoints. If a row exists, read its reference before you write code.

Two more rules hold everywhere: [runtime.md](references/runtime.md) (never
block an executor, re-raise `error.Canceled`, the request arena) and
[zig-0.17.md](references/zig-0.17.md) (std.Io, unmanaged containers,
writers). Most Zig you remember is older than 0.17, so check it there.

## Capability index

`App` stands for `anole.App` or `anole.Server(Ctx)`. Both have the same
methods. Paths are relative to `references/`.

| You need | Use | Read |
| --- | --- | --- |
| HTTP server, routes, path params | `anole.App.init`, `App.get/post/put/patch/delete/any`, `App.listen` | [http/server-routes](references/http/server-routes.md) |
| Shared state (DB handles, caches) | `anole.Server(Ctx)` | [http/server-routes](references/http/server-routes.md#a-server-with-shared-state) |
| Route groups, per-group middleware | `App.group`, `App.with` | [http/server-routes](references/http/server-routes.md#groups-and-with) |
| Read params, query, body, headers, cookies, forms | `anole.Request.bind`, `bindQuery`, `body`, `formData`, `cookies` | [http/request-response](references/http/request-response.md) |
| JSON or text response, headers | `anole.Response.json`, `print`, `header` | [http/request-response](references/http/request-response.md#writing-the-response) |
| 404/401/422 answers, problem+json | `error.NotFound`, `Response.fail`, `Response.problem` | [middleware-auth/errors](references/middleware-auth/errors.md) |
| Typed input and output | `anole.In`, `anole.Created`, `anole.Accepted`, `anole.WithStatus` | [http/typed-validation](references/http/typed-validation.md) |
| Input validation | `anole.validate`, `pub const field_rules` | [http/typed-validation](references/http/typed-validation.md#validation-rules-field_rules) |
| Static files, embedded files | `App.staticDir`, `App.static`, `App.embedded`, `Response.sendFile` | [http/static](references/http/static.md) |
| OpenAPI document, /docs page | `App.openapi`, `anole.doc` | [http/openapi](references/http/openapi.md) |
| gRPC, gRPC-Web, Connect | `App.grpc`, `App.grpcWith`, `App.grpcHealth` | [http/grpc](references/http/grpc.md) |
| Handlers that do no I/O | `anole.noWait` | [http/server-routes](references/http/server-routes.md#handlers-that-never-wait-anolenowait) |
| Custom middleware | `anole.func`, `anole.Next`, `App.use` | [middleware-auth/middleware](references/middleware-auth/middleware.md) |
| CORS, compression, request IDs, request log | `anole.middleware.Cors`, `Compress`, `RequestId`, `Logger` | [middleware-auth/middleware](references/middleware-auth/middleware.md#built-in-middleware) |
| Response caching | `anole.cached`, `App.responseCache` | [middleware-auth/caching](references/middleware-auth/caching.md) |
| Rate limiting | `App.rateLimit`, `anole.ratelimit.Middleware` | [middleware-auth/ratelimit](references/middleware-auth/ratelimit.md) |
| Sessions, CSRF | `anole.session.Middleware`, `anole.auth.csrf.Middleware` | [middleware-auth/sessions-csrf](references/middleware-auth/sessions-csrf.md) |
| JWT bearer auth, JWKS | `anole.auth.RequireJwt`, `anole.auth.claims`, `anole.auth.Keyring` | [middleware-auth/jwt-oidc](references/middleware-auth/jwt-oidc.md) |
| OIDC sign-in (Google, Apple, any provider) | `anole.auth.oidc.RelyingParty` | [middleware-auth/jwt-oidc](references/middleware-auth/jwt-oidc.md#oidc-sign-in) |
| Password hashing | `anole.auth.password.hash`, `verify` | [middleware-auth/keys-passwords-roles](references/middleware-auth/keys-passwords-roles.md) |
| API keys, roles | `anole.auth.apikey.Middleware`, `anole.auth.rbac.Require` | [middleware-auth/keys-passwords-roles](references/middleware-auth/keys-passwords-roles.md#api-keys) |
| 0-RTT replay guard | `anole.early_data.TooEarly` | [middleware-auth/middleware](references/middleware-auth/middleware.md#early-data-0-rtt) |
| WebSocket | `App.ws`, `App.wsCallbacks`, `anole.websocket.upgrade` | [realtime/websocket](references/realtime/websocket.md) |
| Chat rooms, broadcast | `anole.websocket.Rooms` | [realtime/rooms](references/realtime/rooms.md) |
| Server-sent events | `App.sseTopics`, `App.sse`, `anole.sse.Topics` | [realtime/sse](references/realtime/sse.md) |
| WebTransport | `App.webtransport`, `anole.webtransport.Session` | [realtime/webtransport](references/realtime/webtransport.md) |
| Push database changes live | `App.watch`, `anole.watch` | [realtime/watch](references/realtime/watch.md) |
| PostgreSQL | `App.postgres`, `anole.pg.Client` | [databases/postgres](references/databases/postgres.md) |
| SQLite | `App.sqlite`, `anole.sqlite.Client` | [databases/sqlite](references/databases/sqlite.md) |
| MongoDB, BSON | `App.mongodb`, `anole.mongodb.Collection`, `anole.bson` | [databases/mongodb](references/databases/mongodb.md) |
| Redis, Valkey, pub/sub | `App.redis`, `anole.redis.Client` | [databases/redis](references/databases/redis.md) |
| DB errors as statuses, `Ctx` outside handlers | `anole.db.Error`, `anole.db.Ctx` | [databases/index](references/databases/index.md) |
| Migrations | `anole.db.migrate`, `anole.db.Migration` | [databases/migrations](references/databases/migrations.md) |
| Query cache, request coalescing | `anole.db.QueryOptions`, `anole.db.QueryCache` | [databases/caching](references/databases/caching.md) |
| Background jobs, queues, retries | `App.jobs`, `anole.jobs.Client` | [messaging/jobs](references/messaging/jobs.md) |
| Cron schedules | `anole.jobs.Client.cron`, `anole.cron.Schedule` | [messaging/cron](references/messaging/cron.md) |
| Webhooks out (signed) and in (verify) | `App.webhooks`, `App.webhookVerify` | [messaging/webhooks](references/messaging/webhooks.md) |
| NATS, JetStream | `App.nats`, `anole.nats.Client` | [messaging/nats](references/messaging/nats.md) |
| Kafka | `App.kafka`, `anole.kafka.Client` | [messaging/kafka](references/messaging/kafka.md) |
| Outbound HTTP calls | `anole.client`, `anole.Client.fetch` | [storage-email-clients/http-client](references/storage-email-clients/http-client.md) |
| Retries, backoff, circuit breakers | `anole.resilience` | [storage-email-clients/resilience](references/storage-email-clients/resilience.md) |
| S3, R2, MinIO, presigned URLs | `App.s3`, `anole.s3.Bucket` | [storage-email-clients/s3](references/storage-email-clients/s3.md) |
| Sending email | `App.smtp`, `anole.smtp.Client` | [storage-email-clients/smtp](references/storage-email-clients/smtp.md) |
| CPU-heavy or blocking calls | `anole.blocking.run` | [runtime](references/runtime.md#never-block-an-executor) |
| Several calls at once | `req.io.concurrent` | [zig-0.17](references/zig-0.17.md#io-goes-through-stdio-passed-in) |
| Typed config, secrets | `anole.config.load`, `anole.Secret` | [config-cli](references/config-cli.md#typed-config) |
| Environment variables, `.env` | `anole.env.get`, `anole.env.environment` | [config-cli](references/config-cli.md#env-files) |
| Metrics (Prometheus) | `App.metrics`, `anole.observe.metrics.Registry` | [observability](references/observability.md#metrics-prometheus) |
| Tracing (OpenTelemetry) | `App.tracing` | [observability](references/observability.md#tracing-opentelemetry) |
| Health and readiness | `App.health`, `anole.observe.Health` | [observability](references/observability.md#health-and-readiness) |
| Access log, structured logs | `anole.observe.AccessLog`, `anole.log`, `Request.log` | [observability](references/observability.md#structured-logging) |
| Live console | `anole console`, `ServerOptions.console` | [observability](references/observability.md#live-console) |
| Tests without sockets | `anole.testing.client` | [testing](references/testing.md) |
| TLS, certificates, mTLS | `App.listenTls`, `anole.Cert`, `anole.ClientAuth` | [deployment/tls-http](references/deployment/tls-http.md) |
| HTTP/2, HTTP/3 | `ServerOptions.http`, `ServerOptions.http3` | [deployment/tls-http](references/deployment/tls-http.md#http3-and-alt-svc) |
| Several listeners, unix sockets, admin port | `ServerOptions.listeners`, `anole.onlyOn` | [deployment/listeners-proxy](references/deployment/listeners-proxy.md) |
| Behind a proxy, timeouts, body limits | `ServerOptions.proxy`, `timeouts`, `limits` | [deployment/listeners-proxy](references/deployment/listeners-proxy.md#behind-a-proxy) |
| Graceful shutdown, restarts, Docker | `App.listen`, `App.run`, `App.stop` | [deployment/lifecycle](references/deployment/lifecycle.md) |
| AWS Lambda | `anole.lambda` | [deployment/lambda](references/deployment/lambda.md) |
| Raw TCP or UDP beside HTTP | `App.tcp`, `App.udp`, `anole.net` | [deployment/net](references/deployment/net.md) |
| Build setup, feature flags, binary size | `addApp` (build.zig), `.profile`, `.features` | [config-cli](references/config-cli.md#feature-flags-and-profiles) |
| New project | `anole new`, `anole init` | [config-cli](references/config-cli.md#the-anole-cli) |

Lower-level pieces have no reference file. Read their doc comments in Anole's
`src/root.zig`: `anole.json` (yyjson), `anole.compression`, the
`anole.h2.ClientConnection` and `anole.h3.ClientConnection` clients,
`anole.http` (the HTTP core) and `anole.tls`. Node and Python bindings use
the C ABI (`include/anole.h`, docs/c-abi.md), which is not for Zig apps.

## Minimal app

This is from Anole's `templates/minimal`. `anole new` writes it, with tests
and `build.zig`:

```zig
const std = @import("std");
const anole = @import("anole");

pub const std_options = anole.std_options; // quiet runtime lines in Debug
pub const panic = anole.panic; // panics go to the log

const User = struct { id: u64, name: []const u8 };

fn user(_: *anole.Request, in: anole.In(.{ .path = struct { id: u64 } })) User {
    return .{ .id = in.path.id, .name = "Ada" };
}

/// Apart from `main` so that tests serve the same routes.
pub fn routes(app: *anole.App) void {
    app.get("/users/:id", user);
}

pub fn main(init: std.process.Init) !void {
    var app = try anole.App.init(init.gpa, .{});
    defer app.deinit();
    _ = app.health(.{}); // /healthz and /readyz
    app.openapi(.{ .info = .{ .title = "api", .version = "0.1.0" } }); // /docs in development
    routes(&app);
    try app.listen(":3000"); // serves until SIGINT/SIGTERM, then drains
}
```

When handlers share clients, use `anole.Server(State).init(init.gpa, .{}, &state)`
and give handlers the signature `fn (s: *State, req, res) !void`. See
[http/server-routes](references/http/server-routes.md#a-server-with-shared-state).

## Where to go next

- **Start a project:** `anole new my-api [--template minimal|rest-postgres|realtime|grpc|full]`,
  or `anole init` in the current directory. See
  [config-cli](references/config-cli.md#the-anole-cli). The `full` template
  wires most features in one app. Copy from it.
- **Anole's source in your project:** after `zig fetch`, the package is at
  `zig-pkg/anole-*/`. It has `src/root.zig` (every public name, with doc
  comments), `examples/` and `templates/`. Search those before guessing an
  API.
- **Full guides:** `docs/` in the Anole repository,
  https://github.com/xuckless/anole/tree/main/docs. Use your release's tag
  instead of `main`. They are not in the fetched package.
- **Area indexes:** [http](references/http/index.md),
  [middleware-auth](references/middleware-auth/index.md),
  [realtime](references/realtime/index.md),
  [databases](references/databases/index.md),
  [messaging](references/messaging/index.md),
  [storage-email-clients](references/storage-email-clients/index.md),
  [deployment](references/deployment/index.md).
