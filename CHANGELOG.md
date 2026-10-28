# Changelog

All notable changes to Anole. Before 1.0 there is no API stability promise;
breaking changes are listed anyway.

## 0.4.1 (unreleased)

### Fixed

- C ABI: a crash when a binding thread answered, sent or polled while the
  server stopped. The call wakes an executor through the runtime, and the
  stop could free the runtime while that wake was still under way. The stop
  now waits for wakes under way before it frees the runtime, and a wake
  after that is skipped.
- Console: log records from bindings (`anole_console_log`) carry their
  request's id and route; the `req` argument was ignored.
- Console: `/ws` shows the open WebSockets by protocol, accepted WebTransport
  sessions, the rooms (members, queued bytes, members closed as slow) and
  the SSE topics; `/db` shows PostgreSQL's target and every executor's pool.
  Both are collected by a task on the runtime, under the runtime's locks,
  which the console's own threads must not take.
- Console: text in most scripts lines up. Character widths come from a table
  generated from Unicode 16.0.0 (`tools/gen-width-table.py`); the
  hand-picked subset missed the combining marks of Bengali, Tamil and other
  scripts.
- Console: a table wider than the terminal scrolls sideways with Left/Right,
  a column at a time, keeping its first column; ‹ and › mark hidden
  columns. `/h3` showed 8 of its 15 columns at 100 columns wide, with no
  sign that more existed (#119).
- Jobs: a job that finished while the server drained could run a second
  time. A drain past its deadline cancels the runs still going, and the
  cancel could land on a finished run's state write (logged as "finished
  but its state could not be saved: Canceled"), or mark a run interrupted
  after its handler had returned, which put it back. The write now runs to
  its end (at most 5 s, or until the drain stops waiting for canceled runs,
  3 s past its deadline), and a handler that returned keeps its outcome.
- Jobs: in an app, running jobs lost their `drain_timeout` when the HTTP
  side finished draining first (with no connection open, at once): the
  app's teardown canceled the queue's drain. A drain under way is now
  waited for.
- Jobs: `anole_jobs_outcome_unsaved_total{queue,kind}` counts runs that
  finished but whose state could not be saved (they run again after their
  lease). docs/jobs.md gives the longest stop to plan the service manager's
  stop timeout around.
- Webhooks: on PostgreSQL, `hooks.messages` paged in the database's
  collation order (en_US, ICU) instead of by bytes, so caller-supplied ids
  such as `msg_D` and `msg_c` came back in a different order than on SQLite
  and in memory. The message id and the attempts' `message_id` and
  `endpoint_id` columns are now `COLLATE "C"`. Tables made by 0.4.0 are
  changed once at the first start (an `ALTER TABLE` that rebuilds their
  indexes under an exclusive lock), unless the database's default collation
  is libc `C` or `POSIX`. One owner's listing has its own `(owner, id DESC)`
  index, which that start builds with a plain `CREATE INDEX` (writes to the
  messages table wait for it); to choose the moment, run the `ALTER TABLE`
  statements and `CREATE INDEX CONCURRENTLY IF NOT EXISTS
  anole_webhook_messages_owner ON anole_webhook_messages (owner, id DESC)`
  before upgrading (see [webhooks](docs/webhooks.md#storage)). The
  migration runs in one transaction under an advisory lock, so instances
  starting together take turns; it has no time limit, and each table lock it
  waits for is bounded by a 10 s `lock_timeout`, past which the start fails
  with a log line saying what to do (#109).

## 0.4.0 (2026-10-25)

### Breaking

- `anole.db.Class` has three new cases, `not_found`, `precondition` and
  `invalid` (and `anole.db.ErrorMap` the matching fields, answering 404,
  409 and 400): an exhaustive `switch` on `Class` needs them. The object
  storage and mail connectors use them; no database does.
- `anole.ServerError.DeploymentUnavailable` is gone: `deployment = .lambda`
  works now. `ServerError` gains `LambdaRuntimeApiMissing`, `LambdaNotBuilt`,
  `LambdaRuntimeApiFailed` and `SnapStartUnsupported`, and for the raw
  listeners `NetNotBuilt`, `NetListenerNeedsPort`, `NetListenerHttp3`,
  `TcpAndUdp`, `UdpWithTls`, `UdpOnUnixSocket`, `UdpWithProxyProtocol`,
  `InvalidFraming` and `NetHandlerContext`; an exhaustive `switch` on it
  needs them.
- `anole.db.System` and `anole.resilience.Kind` gain `s3` and `smtp`; an
  exhaustive `switch` on either needs them.
- C ABI 0.10 (see Changed): a binding built against 0.9 rebuilds against the
  new `anole.h`.

### Added

- Raw TCP and UDP servers on Anole's runtime and listeners: `app.tcp(":7000", Handler, .{})`
  (callbacks that park idle connections, or a task per connection) and
  `app.udp(...)` (batched receive and send, one socket per core on Linux,
  optional per-peer sessions); TLS with SNI, ALPN, mutual TLS and hot reload,
  the PROXY protocol, per-listener connection caps, a drain callback, socket
  activation and SIGUSR2 restarts, counters in `app.netStats()`. `tcp` and
  `udp` on `.listeners`. `-Dnet` (on in `web` and `full`). See docs/net.md.
- Framing for TCP: lines, length prefixes (1, 2 or 4 bytes) and varints, with
  `conn.sendFrame` for the way out.
- C ABI: the `"tcp"` and `"udp"` listener keys, `anole_net_write`,
  `anole_net_close`, `anole_net_pause`, `anole_net_resume`,
  `anole_net_set_idle_timeout`, `anole_net_udp_send`, `anole_net_udp_find`,
  `anole_net_addr_format` and `anole_net_addr_parse`; events
  `ANOLE_EV_NET_OPEN` (96) to `ANOLE_EV_NET_DATAGRAMS` (100); handle kinds
  `anole_net_conn` and `anole_net_udp`; `anole_stats` net fields; listener
  flags `ANOLE_LISTENER_F_TCP` and `_UDP`.
- `anole.jobs` (`-Djobs`, on in the web and full profiles): background jobs
  with retries and backoff, delays, priorities, unique jobs, leases with
  heartbeats, an admin API and JSON routes, on the memory, SQLite, PostgreSQL
  (LISTEN/NOTIFY wake-ups) and Redis (pub/sub wake-ups) stores. Job kinds are types
  (`pub const job: anole.jobs.Kind`), `app.jobs(...)` owns the queue.
- `anole.cron`: cron expressions (5 or 6 fields, `L`, `5L`, `MON#2`,
  nicknames, `@every`), time zones from the system's tzdata with the DST
  rules written down in docs/cron.md, and `jobs.cron(...)`, which enqueues
  one job per tick across instances.
- `anole.pg.Client.session`: a connection of its own outside the pools.
- `jobs.enqueueIn`, `enqueueRawIn` and `completeIn` on SQLite and PostgreSQL transactions,
  jobs metrics, `traceparent` carried in job meta, and the queue draining when
  the server does.
- `jobs.Client.addQueue`: adds a queue the options did not list, before
  `start` (a queue that exists is left as it is). `webhooks.register` adds
  its delivery queue this way; an app's own module can too.
- C ABI: `"jobs"` in the configuration (with native `sql` cron actions),
  `anole_jobs_get`, `anole_jobs_enqueue` (optionally inside an
  `anole_db_tx`), `anole_jobs_work` and `anole_jobs_stop`, `anole_job_finish`,
  `anole_job_complete_in` and `anole_jobs_admin`; events 104-108, handle kinds
  12 and 13.
- Webhooks (`-Dwebhooks`, on in the web and full profiles; needs `-Djobs`):
  `app.webhooks(.{ .jobs = jobs })` keeps endpoints, messages and a delivery
  log in the jobs store, and `publish` sends an event to the owner's matching
  endpoints as Standard Webhooks (`webhook-id`, `webhook-timestamp`,
  `webhook-signature`). Each delivery is a job: retried with backoff for about
  three days, refused for private addresses in production, behind a circuit
  breaker per origin, with the attempts recorded. Endpoints get a `whsec_`
  secret, rotation keeps the old one signing for a while, an endpoint failing
  for five days is disabled, and `replay` and `recover` re-send. Secrets are
  encrypted at rest when `ANOLE_WEBHOOKS_KEY` is set.
- `app.webhookVerify(.{ .preset = .stripe, .secrets = &.{secret} })` checks
  incoming webhooks (Standard Webhooks, Stripe, GitHub, Slack, or any HMAC
  header) and drops duplicate deliveries (in memory, or in Redis).
  `anole.webhooks.standard` has the signing and verifying functions.
- C ABI: `anole_webhooks_publish` and `anole_webhooks_watch`, events 109 and
  110, the `"webhooks"` configuration and the `webhook_verify` middleware.
- `anole.s3` (`-Ds3`, in the `web` and `full` profiles): an S3-compatible
  object storage client for AWS S3, Cloudflare R2, MinIO, Backblaze B2 and
  Supabase Storage, in pure Zig on Anole's HTTP client with its own SigV4
  signer. Streaming uploads (a pull form from a reader, a file or the
  request, and a push form whose writes never wait for the network) and
  downloads, multipart uploads with bounded memory, `serve` for answering a
  request from an object, presigned URLs, listing, copying, and the AWS
  credential chain (environment, shared file, web identity, ECS/EKS, EC2).
  Retries are on by default (every call is idempotent). `app.s3(.{})`,
  `anole.s3.testing.FakeServer` (verifies signatures), docs/storage.md.
- C ABI: `"storage"` in the configuration and `anole_s3_*` (events 124 and
  125, handle kind 16 for uploads and downloads, `ANOLE_E_SERVICE`, error
  classes `NOT_FOUND`, `PRECONDITION` and `INVALID`). `serve` and `put_body`
  move an object to and from a request without it entering the language.
- `anole.smtp` (`-Dsmtp`): sending mail over SMTP with STARTTLS or TLS from
  the first byte, AUTH PLAIN and LOGIN, MIME with HTML, attachments and
  inline images, pooled connections per executor, and `sendRaw` for messages
  composed elsewhere. `app.smtp(.{})` reads `SMTP_URL` and falls back to
  Mailpit's port outside production; retries are opt-in, because a retry
  after the final "." could send an email twice. `anole.smtp.testing.FakeServer`
  is an SMTP server for tests. Pieces adapted from smtp_client.zig (MIT).
  See docs/email.md.
- C ABI: `"mail"` in the configuration, `anole_smtp_find`, `anole_smtp_index`,
  `anole_smtp_send` and `anole_smtp_send_raw`, and `ANOLE_EV_SMTP_RESULT` (126).
- gRPC over HTTP/3, server and client (gRFC G2). Services answer native gRPC
  on the HTTP/3 listener with no change, the C ABI's too. The client takes
  `Channel{ .h3 = conn }`, or `Channel.connect` with `.http = .h3` (prior
  knowledge) or `.auto` (switches on Alt-Svc, falls back to HTTP/2).
  Interop-tested against grpc-dotnet v2.84.0 in both directions.
- `anole.h3.RequestOptions.send_buffer`; `anole.h2.Stream.resetCode()` and
  `anole.h3.Stream.resetCode()`; `anole.h3.parseAltSvc`; `anole.h3`
  `ClientConnection.isOpen()`.
- gRPC between processes on one host over a Unix domain socket: a `unix`
  listener serves h2c with gRPC; the client and `Channel` dial `unix:/path`,
  `unix:///path` and (Linux) `unix-abstract:name`, with no TLS. The socket
  file is created `0660`; `Listener.unix_mode` changes it. A leftover socket
  file is replaced.
- AWS Lambda: with `deployment = .lambda` (or `ANOLE_DEPLOYMENT=lambda`) the
  same app serves Lambda invocations: API Gateway REST and HTTP APIs,
  Function URLs (buffered or streamed), ALB and VPC Lattice through the
  router and middleware, other events (SQS, EventBridge, ...) on
  `POST /_lambda/event`. `zig build lambda` (addApp) writes
  `provided.al2023` zips for arm64 and x86_64. Also Lambda Managed
  Instances (concurrent invocations) and Web Functions. The C ABI's
  `lambda` config group does the same for Node and Python apps. See
  docs/lambda.md.
- `anole.lambda.context(req)` and the `x-amzn-request-context` /
  `x-amzn-lambda-context` request headers.
- `client.upload`: requests whose body is written as it goes (chunked, with
  trailers), over HTTP/1.1; `client.closeIdle()` closes the idle pooled
  connections.
- `Exporter.flush(timeout)`: sends the queued spans and waits for the
  collector.
- `-Dlambda` build flag (on in every profile), and `-Ddefault-deployment`
  (the deployment a build falls back on; `zig build lambda` builds with
  `lambda`).
- `addApp`'s `AppOptions.features`: single features on or off over the
  preset (`.features = .{ .postgres = false }`), forwarded to Anole's
  dependency like its own `-D<feature>` flags, the Lambda zips included.
- `anole.h3.Stats.connections_open`: the connections an HTTP/3 endpoint
  holds now (a gauge; the live console's `/h3` view shows it).
- SSE topics (`anole.sse.Topics`, `app.sse`): publish once to every subscriber over HTTP/1.1, HTTP/2 and HTTP/3, with no task per idle subscriber; `Last-Event-ID` resume from a replay buffer, heartbeats, a slow-subscriber policy and a reconnect spread at drain.
- `app.watch`: PostgreSQL LISTEN/NOTIFY, Redis pub/sub and streams, and MongoDB change streams, straight into SSE and WebSocket topics, into handlers, or read from handlers.
- MongoDB change streams: `Collection.watch`, `Database.watch`, `Client.watch`, with automatic resume.
- C ABI: `"sse"` routes and config, `anole_sse_publish`, `anole_sse_gap`, `anole_sse_accept`/`_subscribe`/`_unsubscribe`/`_send`/`_close`; `"watches"` and `anole_watch_find`/`_listen`/`_unlisten`/`_ack`; events 112, 113, 116-118; handle kinds 14 and 15.

### Changed

- A new startup banner: the word "anole" drawn large in green with a yellow
  O, replacing the lizard. Terminals of 110 columns or more get one of two
  full-size drawings at random, narrower ones (55 or more) a half-height
  version, narrower still only the version line. 24-bit colour when
  `COLORTERM` says so, else the nearest 256 colours; uncoloured under
  `NO_COLOR`. The rules for when it shows are unchanged. `anole version` and
  `anole new` print it at a terminal, and the live console shows the small
  version until the first log line.
- A server that names only raw TCP/UDP listeners opens no HTTP listener.
- `handoff.max_listeners` is 64 TCP listeners and 1024 UDP sockets.
- `anole.http.Client`: `ClientOptions.http2` is on by default. Requests to a
  host whose server picks h2 share one connection per executor as
  concurrent streams (one dial per origin, others wait for it; 1 MiB per
  stream and 16 MiB per connection windows; a stream's buffer is sized by
  the response's `Content-Length`), and a request the server provably did
  not process is sent again on a new connection. `h2c_hosts` lists hosts
  that speak cleartext HTTP/2 with prior knowledge. `http2 = false` restores
  HTTP/1.1 over TLS.
- HTTP/3: a client's RESET_STREAM (or STOP_SENDING with an error) cancels the
  handler's task, as on HTTP/2.
- HTTP/3: while a request is open, QUIC PINGs keep the connection alive.
  Long-lived responses (gRPC streams, SSE, WebSocket and WebTransport over
  HTTP/3) no longer end at the 30 s idle timeout; idle connections still do.
  On the client this builds on 0.3.1's `ConnectOptions.keep_alive` (one
  mechanism): the PING comes after `keep_alive` or half the idle timeout,
  whichever is shorter.
- HTTP/3: gRPC and Connect streaming responses may hold 1 MiB unacknowledged
  per stream (was 64 KiB).
- `anole.grpc` client: a stream reset maps to the status gRPC specifies for
  its code (INTERNAL for most, UNAVAILABLE only for a refused stream,
  CANCELLED, RESOURCE_EXHAUSTED, PERMISSION_DENIED); it was always
  UNAVAILABLE. `Channel.retry` therefore no longer repeats a call the server
  reset with INTERNAL_ERROR.
- `Response.abort` in a gRPC handler resets the stream (the client reads
  CANCELLED) instead of answering UNKNOWN.
- `anole.grpc.Channel.conn` is optional (`h3` is the other connection); code
  that only sets it is unchanged, code that reads `channel.conn` unwraps it.
- The `RequestId` middleware keeps an ID the engine set already (Lambda's
  request ID) instead of generating another.
- C ABI 0.10: the C ABI is now 0.10 (`ANOLE_ABI_VERSION`, `x-anole-abi`;
  before 1.0 a binding needs the exact version). A handle's kind takes five
  bits (28-32), so Kafka groups and batches are kinds of their own (17 and
  18): a NATS handle given to a Kafka call is now `ANOLE_E_INVALID`
  (`WrongHandleKind`). Handles stay opaque. New status `ANOLE_E_SERVICE`
  (-13); events 96-126 and handle kinds 10-16 as listed above
  (docs/c-abi.md, "From ABI 0.9").

### Fixed

- Live console on macOS: no key reached it, Ctrl-C included, so the only way
  out was killing the terminal. macOS's poll(2) does not support devices and
  answers POLLNVAL for /dev/tty, which the console waited on; the run loop
  ignored that and spun. The console now opens the terminal by its own name
  (/dev/ttysNNN) when stdin, stderr or stdout is that terminal, and waits
  with select(2) otherwise; a terminal that cannot be read ends the console
  instead of spinning. Both `anole console` and `c` + Enter in a development
  app are affected. `anole console` also restores the terminal on SIGINT
  and on a panic. A pseudo-terminal test (tests/console/pty_test.py) runs in
  CI on Linux and macOS.
- Live console (since 0.3.0): use after free at shutdown. The console
  stopped before the drain and freed its log rings and request counters at
  once, while the drain's executors could still write a warning into the
  rings or count a 504 into the counters, and the C ABI's
  `anole_console_report` could still reach the freed service. The console
  now stops at the same point but is freed only after the runtime is gone.
  It showed as a rare crash at shutdown with the console on (the default in
  production).

## 0.3.1 (2026-10-23)

### Fixed

- HTTP/3 client: a download could stall after a NAT rebinding moved the
  client's port while it had nothing left to acknowledge (the server kept
  sending to the old port and never heard from the new one) until the
  request timed out (#98). A new `ConnectOptions.keep_alive` (5 s, null for
  none) sends a PING after that long without traffic while a stream is
  open, so the server sees the new address and follows it.
- Windows (development target): the CI job is green again. The console's
  terminal-side tests are skipped on Windows (the console comes to Windows
  later; one of them spun forever on the stub clock), its golden files keep
  LF line endings on Windows checkouts, and an HTTP/2 stream-reset test waits
  for its handler to start instead of sleeping 100 ms.

## 0.3.0 (2026-10-23)

Developer experience: settings, `.env` files and deployment modes, retries
and circuit breakers, the NATS and Kafka clients, validation and typed
handlers, JSON Lines logs, OpenAPI documents, project templates and the
`anole` command line, and a live console.

### Breaking

- A JSON body that is valid JSON but whose values do not fit the type is now
  422 with the violations, not 400. `req.bindWith` keeps the old behaviour.
- Route methods (`get`, `post`, `ws`, `webtransport`... and the same on
  groups) take `path` at compile time; `app.addRoute(method, path, handler)`
  for a run-time path. Malformed patterns are refused. `anole.cached` on a
  method other than GET or HEAD is a compile error.
- The access log's JSON lines are the shared log record: `time` (RFC 3339)
  replaces `ts`, and `level`, `scope` and `message` are added;
  `AccessLog.Options.format` is null by default and follows the log format.
  Without a `.file`, access lines go through the log sink (stderr, or the C
  ABI's callback).
- In test builds a route conflict is `error.RouteConflict` instead of a
  panic.
- `ServerOptions.listen_tls_http3`, `http.address`, `http.port`,
  `http.proxy_protocol`, `https.address`, `https.proxy_protocol`,
  `Listener.address`, `Listener.port` and `Listener.proxy_protocol` are
  optional; null means the deployment's default (0.2's values when
  standalone). Code that only sets them is unchanged; code that reads them
  unwraps. JSON: `listeners[].address`, `port` and `proxy_protocol` default
  to null.
- `timeouts.keepalive` (`keepalive_ms`) defaults to 75 s, up from 60 s, so it
  sits above the idle timeout of nginx and AWS load balancers.
- `anole.db.System` has `nats` and `kafka`; an exhaustive `switch` on it
  needs the two new cases.
- WebSocket over HTTP/2 (RFC 8441) is off by default:
  `http2.enable_connect_protocol` (Zig and the C ABI) defaults to false, so
  the HTTP/2 engine no longer advertises extended CONNECT and clients open
  WebSockets over HTTP/1.1. Measured on the x86 box, WebSocket over HTTP/2
  served 38% fewer video-call users than HTTP/1.1 at 2.1x the CPU per
  message (#91), and Firefox used it whenever it was offered. Set
  `http2.enable_connect_protocol = true` to accept it again. RFC 9220 over
  HTTP/3 (`http3.enable_connect_protocol`) stays on.

### Config and modes

- `anole.config.load(T, init, .{})`: typed settings from defaults,
  per-environment defaults, a JSON or INI file, `.env` files and the
  environment, every problem reported at once; `anole.Secret` never prints;
  durations as `"30s"`. Adapted from zefir's confy.
- `.env` files in development (`.env.development.local`, `.env.local`,
  `.env.development`, `.env`), read once and used by every environment read
  in Anole (`DATABASE_URL`, `REDIS_URL`, `OTEL_*`...); never in production or
  tests unless named (`env_files`).
- `environment` (`development` or `production`, `ANOLE_ENV`) and `deployment`
  (`standalone`, `behind_proxy`, `anole_lb`, `platform`; `lambda` from 0.4;
  `ANOLE_DEPLOYMENT`) options in Zig and the JSON config: defaults only,
  every change printed at startup.
- `proxy.trusted` (`ANOLE_PROXY_TRUSTED`): trusted proxies by address,
  network or name; the client is the rightmost untrusted X-Forwarded-For
  address; one warning for the first request that bypasses the proxy.
- `error_detail`: 500 answers name the error in development.
- Changed: X-Forwarded-For entries with a port give the address instead of
  0.0.0.0.
- Changed: with `proxy_protocol` on and no `proxy_protocol_from`, only
  `proxy.trusted` peers may connect when `proxy.trusted` is set (any peer
  otherwise, as before).

### Validation and typed handlers

- `anole.validate`: field rules on structs (`pub const field_rules`), about
  190 rules, transforms and `v.rename`; the whole of zefir's validator.
  `req.bind` checks them and answers 422 `application/problem+json` naming
  every invalid field; `req.bindQuery`, `req.bindPath`, `req.bindHeaders`,
  `req.invalid`, `res.problem`, and `anole.bindJson` for bytes without a
  request ([validation.md](docs/validation.md)).
- `anole.In(.{ .path, .query, .headers, .body })`: typed handler inputs, bound
  before the handler runs and checked at compile time; typed outputs (a
  result written as JSON, `anole.Created`, `anole.Accepted`,
  `anole.WithStatus`) and `anole.routeInfo` for tools
  ([routing.md](docs/routing.md#typed-handlers)).
- Route paths are checked at compile time (a wildcard that is not last, a
  parameter named twice, an empty name, `?` or `#`); `app.addRoute` for a
  path known at run time.

### Logging

- JSON Lines logs (`ServerOptions.log`, `anole.log`, `req.log()`), JSON by
  default in production; redaction by field name and by `anole_sensitive`
  ([logging.md](docs/logging.md)).
- Startup errors are two readable lines (what could not be done, why, the
  way out), also in the C ABI's `anole_last_error`; the startup banner (the
  anole, version, address) when a person is looking, off with
  `ServerOptions.banner = false` or `ANOLE_NO_BANNER=1`; `anole new` shows it
  too.

### Testing

- `anole.testing`: an in-memory client for routes and middleware, with
  server-sent event streams and log capture
  ([testing.md](docs/testing.md)).

### Resilience

- `anole.resilience`: retries with backoff and jitter, retry throttling and
  circuit breakers, used by the HTTP client (`ClientOptions.retry`,
  `.breaker`; `FetchOptions.retry`, `.idempotent`), gRPC channels
  (`Channel.retry`, `.breaker`, `Channel.connect` with redial) and the
  database connectors (`Options.breaker`, `Options.retry`,
  `with(.{ .retry = true })`).
- HTTP/2 and HTTP/3 client `Stream.unprocessed()`.
- Changed: PostgreSQL, Redis and MongoDB calls fail fast with 503
  (`lastError` code `circuit_open`) after 5 connection failures in a row,
  for 5 s and then while probes fail (up to 60 s). Set `breaker = null`
  (`"breaker": null`) for the old behaviour.

### Messaging: NATS

- `anole.nats` (`-Dnats`, on in `full`): NATS publish (never waits),
  request/reply, handlers with queue groups, TLS, token, NKey and `.creds`
  logins, and JetStream publish with ack and pull consumers. The client is
  adapted from zefir (MIT). `app.nats(.{})`.
- `Msg.bind(T)`: a message's JSON body bound and validated like `req.bind`.

### Messaging: Kafka

- `anole.kafka` (`-Dkafka`, on in `full`; needs `-Dcompression`): Anole's own
  Kafka client on std.Io, no librdkafka. Produce (acks 0, 1 or all,
  idempotent by default, batching, gzip/zstd/lz4, Java's partitioner),
  consumer groups with offset commits and a dead letter topic, TLS and SASL
  PLAIN/SCRAM. `send` queues and never waits; `produce` waits for the
  acknowledgement. `app.kafka(.{})` reads `KAFKA_BOOTSTRAP_SERVERS`.
- A record for a topic the cluster does not list yet (auto-create in
  progress, Kafka 4.x answers UNKNOWN_TOPIC_OR_PARTITION meanwhile) waits for
  it up to `producer.metadata_wait` (5 s, capped by the call's timeout; ABI
  `metadata_wait_ms`) before failing with `UNKNOWN_TOPIC_OR_PARTITION`.

### OpenAPI and CLI

- OpenAPI 3.1 (`-Dopenapi`, on in `web` and `full`): `app.openapi(.{})`
  serves /openapi.json and a Scalar page at /docs in development, built from
  typed handlers, the validator's rules, middleware (JWT, API keys, RBAC, rate
  limits, CSRF) and gRPC services (Connect forms and JSON transcoding);
  `anole.doc(.{ .summary = ... }, handler)` gives a route texts and, for a
  plain handler, types; `zig build openapi` writes openapi.json and `zig
  build openapi-check` checks it (`addApp`). Adapted from zefir.
- `error.OpenApiNameClash`, `OpenApiOutOfDate` and `OpenApiNotBuilt`.
- `google/api/field_behavior.proto` is bundled (`REQUIRED`, `OUTPUT_ONLY`
  show in the document).
- Generated protobuf code carries the `.proto` comments as `_doc`
  declarations (zig-protobuf pinned to xuckless/zig-protobuf e6de363).
- The `anole` command line (`zig build cli`; binaries for five targets with
  SHA256SUMS on each release): `anole new <dir>` and `anole init` make a
  project from one of five templates (`minimal`, `rest-postgres`, `realtime`,
  `grpc`, `full`), each with tests, an OpenAPI page and a ready `.env`;
  `anole templates`, `anole version` ([templates.md](docs/templates.md)).
- `zig build test -Dtest-filter=<text>` runs only the unit tests whose name
  contains the text.
- Fixed: `env.environment()` did not compile in a Debug build (`.Debug`).

### Console

- A live console: `anole console` attaches to a running app over a local
  socket (logs with filters, per-route req/s and p50/p99, recent 5xx,
  connections, databases, HTTP/3, runtime, resolved config, routes; `/reload`,
  `/drain`, `/restart`, `/full-restart`). In development, `c` + Enter opens
  it in the terminal the app runs in. `ServerOptions.console`, `-Dconsole`
  ([console.md](docs/console.md)).
- C ABI: `anole_console_open`, `anole_console_close`, `anole_console_attached`,
  `anole_console_report`, `anole_console_log`, event 132
  `ANOLE_EV_CONSOLE_CLOSED`, the `console` configuration group.
- `anole console` in the CLI (`--list`, `--snapshot <view>`).
- `RouteInfo` gains `index`; `anole_log.Context` gains `route`.

### Runtime gauges

- `/metrics` gains `anole_runtime_tasks`, `anole_runtime_run_queue`, `anole_runtime_stack_committed_bytes`, `anole_connections` and `anole_streams`, per executor, from zio's new `diagnostics` option.

### C ABI

- C ABI 0.9: the C ABI is now 0.9 (`ANOLE_ABI_VERSION`; before 1.0 a
  binding needs the exact version). It adds the `environment` and
  `deployment` keys and `anole_dotenv_read`; the brokers, NATS (events 64-69)
  and Kafka (events 80-85), with handle kinds 8 and 9 and `ANOLE_E_BROKER`;
  `ANOLE_DB_F_RETRY` and `"breaker"`/`"retry"` on databases; the `"log"`
  callback format keys; `"banner"`; and the console calls with event 132.
- `anole_dotenv_read`; JSON keys `environment`, `deployment`,
  `error_detail` and `proxy.trusted`.
- `"log": {"format", "service"}` and `"banner"` in the configuration;
  `"access_log"`'s `"format"` gains `"auto"` (the default). With
  `log.format` `"json"` (the default when `environment` is production) the
  log callback's `msg` is the whole JSON record; access lines reach the
  callback with scope `access`. A malformed route pattern is
  `ANOLE_E_CONFIG` naming the route.
- `"brokers"` in the configuration, `anole_nats_*`, events
  `ANOLE_EV_NATS_MSG`, `_REPLY`, `_JS_MSG`, `_SUB_END`, `_STATUS` and
  `_WRITABLE` (64-69), handle kinds for subscriptions and messages,
  `ANOLE_E_BROKER`, `ANOLE_DB_F_RETRY`, `"breaker"` and `"retry"` on
  databases. A NATS request or JetStream publish tied to an HTTP request
  (`req`) answers `ANOLE_E_GONE` when that request ends first (aborted or
  past its deadline); subscriptions end with `ANOLE_EV_NATS_SUB_END` when
  the server stops.
- Kafka: `"brokers"` entries with `"kafka"`, `anole_kafka_*` (produce,
  flush, group subscribe with batches, assign/revoke, find/index), events
  `ANOLE_EV_KAFKA_RECORDS`, `_DELIVERY`, `_ASSIGN`, `_REVOKE`, `_WRITABLE`
  and `_GROUP_END` (80-85).

## 0.2.1 (2026-10-23)

The relay pass: cross-task WebSocket sends, fan-out, TLS and HTTP/2
WebSocket overhead, and HTTP/3 and WebTransport memory and wake-ups. The C
ABI is now 0.8.

Measured on the x86 box against 0.2.0 (bench/results/20261023-relay-pass-rerun):
WebSocket video-call relay +9% users at less CPU per message, WebTransport +8%
users at about half the memory per user (audio now holds through a video
collapse), room fan-out 2.4x the messages at a quarter of the memory, HTTP/3
memory -35%. Known trade-offs, tracked as issues: under fan-out past
saturation a handler's reply waits behind the larger send rounds (#92);
WebSocket over HTTP/2 costs more CPU per message (#91); WebSocket over
HTTP/1.1 memory per user and HTTP/3 on io_uring are slightly behind 0.2.0
(#93, #94).

### Added

- `http2.tunnel_window` (Zig option and the C ABI JSON key, default 128 KiB):
  the one fixed window and buffer of a WebSocket over HTTP/2, in place of
  the 1 MiB window a stream gets once it reads its body. About 1 MB less
  memory per HTTP/2 WebSocket; raise it for bulk uploads over long round
  trips.
- WebTransport stream urgency: `Stream.setPriority(urgency)`, 0 (most urgent)
  to 7, RFC 9218 classes with round-robin inside each; the default stays 3
  for every stream. C ABI 0.8: `anole_wt_stream_set_priority`.

### Changed

- A WebSocket send to another socket from a task that is in the middle of
  its own batch of buffered messages now waits for the receiver's batch
  instead of costing a TLS record and a `send` each. Sends outside a batch
  are unchanged.
- A batch now continues across a message bigger than the reader window when
  the TLS layer already holds bytes of it.
- A room member's sender and the C ABI's per-socket sender write everything
  queued for a socket and flush once; `anole_ws_send` keeps a burst's bytes
  in one buffer per socket and `anole_ws_publish` makes one copy of the
  message, not three.
- TLS: a connection that receives big messages keeps its 16.5 KiB read
  block while it stays busy (one `recv` per message), `SSL_read` calls that
  could only say "want read" are skipped, the error queue is cleared only
  when it holds something, a large message's records leave together (a
  keyframe in two socket writes, not eight) and a frame header no longer
  becomes a TLS record of its own.
- HTTP/2 WebSocket: a stream's response bytes go straight into a growable
  per-stream queue (freed when idle, a send waits only past 1 MiB queued)
  instead of a fixed 32 KiB ring, the connection's writer is woken for a
  body read only when nghttp2 queued a WINDOW_UPDATE, and the socket reads
  16 KiB at a time.
- The message buffers a WebSocket keeps between messages are capped at
  64 KiB on HTTP/1.1 and HTTP/2, so a socket that once received a keyframe
  does not hold it.
- HTTP/3 receive windows no longer auto-tune past the initial ones
  (`max_window` = `max_data`, `max_stream_window` = `max_stream_data`, was
  six times each): a peer can no longer park up to 6 MiB of unread data per
  stream when the app falls behind. One stream's upload now tops out near
  `max_stream_data` per round trip (about 80 Mbit/s at 100 ms); raise
  `max_stream_data` for more.

### Fixed

- HTTP/3 and WebTransport memory: send and receive queues are shared 4 KiB
  blocks held only while data is unacknowledged or unread (a stream used to
  keep a 64 KiB ring for its whole life, plus 8 KiB reader and writer
  buffers); the request-stream pool keeps 64 streams of 4 KiB (was 256 of 8
  KiB plus rings). A connection's streams hold at most 4 MiB unacknowledged.
- WebTransport writes no longer wait for the peer's acknowledgments below
  1 MiB per stream: a 1080p keyframe larger than the old 64 KiB ring blocked
  mid-write, and audio behind the same lock waited with it.
- Every waiter of an HTTP/3 connection no longer wakes on every packet: a
  stream's reader and writer, and a session's `acceptStream`, `openStream`
  and datagram calls, each wait on their own signal.
- A WebTransport session on the server runs no tasks of its own: capsules are
  parsed as they arrive and the drain is a hook (it was two tasks).
- The WebSocket-over-HTTP/3 and WebTransport CONNECT streams hold up to 1 MiB
  unacknowledged (ordinary responses keep 64 KiB).

## 0.2.0 (2026-10-23)

The API review before the Node and Python bindings: every breaking change
of 0.2 is listed below, and [docs/migrating.md](docs/migrating.md)
has the old -> new table for each area. The C ABI is now 0.7.

### Breaking

- `ServerOptions.server` is gone. Its settings are now flat groups with the
  same names as the C ABI's JSON config: `timeouts`, `limits`, `proxy`,
  `request`, `response` (see the migration table). `errors`, `error_handler`,
  `http2` and `listeners` set inside `.server` used to be ignored without a
  word; there is no such place to put them any more.
- Durations in options are `anole.Duration` (`.fromSeconds(10)`) and lose
  their unit suffix: `restart_timeout_ms` is `restart_timeout`; `window`,
  `idle`, `ttl`, `leeway`, `max_age`, `interval`, `valid_for`, `lifetime`,
  `min_refresh`, `stale`, `retry` and `max_retry` replace the `_ms` and
  `_seconds` fields of the rate limiter, sessions, JWT verification, OIDC,
  the keyring, CORS, tracing and `tls.selfSigned`.
- TLS settings have one shape everywhere: `anole.Cert` (`.fromFiles`,
  `.fromPem`, `.dev_self_signed`) for listener and client certificates,
  `anole.Ca` (`.system`, `.fromFile(path)`, `.dir`, `.fromPem`) for trusted
  CAs, `anole.ClientAuth` for mutual TLS. `alpn_protocols` is `alpn`. The
  `dir` fields are gone (paths are relative to the working directory).
  `http.ClientConfig` is `anole.ClientOptions`, `http.TlsConfig` is
  `http.TlsOptions`. A listener that serves `.dev_self_signed` on anything
  but loopback logs a warning.
- `init`, `listen`, `listenTls`, `run` and `waitReady` return
  `anole.ServerError`, and the certificate reloads `anole.TlsLoadError`:
  named, documented sets you can switch on (`error.AddressInUse`,
  `error.KeyMismatch`, ...). `app.failedListener()` names the listener whose
  port could not be bound.
- `req.setTimeout` takes `?anole.Duration` (`req.setTimeout(.fromSeconds(60))`,
  `null` for none); the old form is `req.setDeadline(std.Io.Timeout)`.
- Every middleware is built with `init(.{ ... })` and takes `Options`
  (`Cors.Options`, `Logger.init(.{})`, `Compress.init(.{})`,
  `MemoryStore.init(gpa, io, .{})`). Struct middleware gets the chain as
  `next` and calls `next.call()`, as function middleware does (was
  `executor.next()`).
- Using a request or response out of order (a second `req.reader()`,
  `res.stream` after `res.body` was set, writing after the head went out)
  returns a named error (`anole.http.MisuseError`, answered 500) instead of
  undefined behaviour in ReleaseFast. `res.writer()` can now fail: add `try`.
- Engine fields of `Request` and `Response` are marked internal with a
  leading `_` (`res.conn`, `req.parser`, `res.headers_written`, ...). Use
  `res.headersSent()`.
- A route marked `anole.noWait` (or `RouteOptions.no_wait`, or a gRPC service
  registered `no_wait`) behind middleware that may wait is now refused at
  startup with a message naming both. Until now it registered and, under
  load, a waiting middleware (a Redis rate limiter, a session store, a JWKS
  fetch) stalled the whole HTTP/2 connection or every HTTP/3 connection on
  the core. Your own struct middleware needs `pub const no_wait = true;` to
  sit in front of `noWait` routes, and a function middleware
  `app.use(anole.noWait(f))`.
- `websocket.Socket`'s internals are `_`-prefixed (`ws.conn`, `ws.closed`,
  ...): use `ws.httpVersion()` and `ws.isClosed()`. WebTransport's
  non-waiting driver calls moved to `Session.Driver` and `Stream.Driver`.
  `Rooms.init(allocator, options)` is the one constructor (`initOptions` is
  gone).
- The graceful drain now waits 10 s by default (was 30 s in Zig; the C ABI
  already used 10 s), the same as Docker's stop grace. Set
  `timeouts.shutdown` for longer.
- WebSocket messages are limited to 1 MiB by default (was 16 MiB; the C ABI
  already used 1 MiB): set `limits.ws_max_message` or the route's
  `max_message_size`. `req.reader()` now stops at `limits.body_max` for
  chunked bodies too (`error.BodyTooBig`, 413); `req.readerLimited(buf, n)`
  takes larger ones.
- C ABI 0.7 configuration: `trusted_proxy_hops`, `trust_forwarded_proto` and
  `trust_forwarded_host` move into a `proxy` group (`proxy.trusted_hops`).
  Timeouts take `null` for none. New keys: `timeouts.read_header_ms`,
  `write_ms`, `idle_park_ms`; request head limits in `limits`; `proxy`,
  `request`, `response`, `http2` and `errors` groups; `http3.address`,
  `port`, `validate_address`, `prefer_v2`, `sockets`,
  `enable_connect_protocol`, `inline_no_wait`; `tls.client_ca_dir` and
  `client_ca_system`. `jwt.leeway_s` is `leeway_ms`, `cors.max_age` is
  `max_age_ms`. Every Zig server option now has a JSON key with the same name
  or is listed in docs/c-abi.md with the reason it has none.
- Outbound requests say `User-Agent: anole/<version>` (was `dusty/0.4.0`);
  `anole.version` is the version.
- Database calls are bounded by 30 s by default: `Options.timeout` on all
  four connectors (it was MongoDB's alone, and off), and the C ABI's
  `databases[].timeout_ms`. A call without a bound used to wait as long as the
  database did, which a stuck database turned into an exhausted pool. Set
  `timeout = null` (`"timeout_ms": 0`) for the old behaviour, or
  `.with(.{ .timeout = .max })` (`ANOLE_DB_TIMEOUT_NONE`) for one call.
  `TxOptions.timeout = null` is the connector's bound, not none.
- Databases: the run-time pair is `table` and `execValues` (was `run`) on
  both SQL connectors, and MongoDB's `with(options).dynamic(ctx, op,
  collection, docs)` takes the context first.
- Databases, one vocabulary: `anole.sqlite.Options`: `busy_timeout_ms` is
  `busy_timeout` (a Duration), `statement_cache` is `statement_cache_size`
  (`u16`), `readers` is `?u32`; `sqlite.Client.execScript` takes a context
  (`execScript(&ctx, sql)`, and `pg.Client.execScript` is new).
  `anole.mongodb.Options`: `max_idle` is `idle_timeout`; `max_connections`
  is `?u32`, null for 100, and 0 (no limit) is refused; `connect_timeout` is
  optional; `tls` is `anole.db.Tls`. Every connector: `name` is optional;
  `max_connections = 0` is refused at init; `tls` is `anole.db.Tls`
  (`ca: ?anole.Ca`, `client_certificate: ?anole.Cert`,
  `insecure_skip_verify`); `Conn.release` takes `*const Conn`. C ABI config:
  `databases[].sqlite.statement_cache` is `statement_cache_size`;
  `databases[].mongodb.max_connections` 0 is refused.
- C ABI: `anole_db_options.timeout_ms = 0` now means the database's
  `timeout_ms`, not "none"; `anole_db_options` grows to 48 bytes and
  `anole_db_result_event` to 104.
- gRPC: `Call.addHeader` and `Call.addTrailer` refuse the protocols' own keys
  (`grpc-*` but `grpc-status-details-bin` in trailers, `connect-*`,
  `trailer-*`, `content-type`, `te`...), as the C ABI did: a handler could
  send a second `grpc-status`. `addHeader` now adds a value instead of
  replacing one, so a repeated key keeps every value. The C ABI refuses
  `grpc-status-details-bin` as initial metadata (it was sent as a header,
  which no client reads).

The migration table is in [docs/migrating.md](docs/migrating.md)
and docs/c-abi.md ("From ABI 0.6").

- Before 1.0 a library serves only code built against the same ABI version,
  major and minor: compare with `ANOLE_ABI_COMPATIBLE(anole_abi_version())`.
  The header used to say a newer minor was enough, which was never true
  under 0.x. Options structs larger than the library knows are refused
  unless the extra bytes are 0, unknown flag bits are refused on every call
  (`anole_db_options.flags` was not checked), and reserved fields in
  `anole_db_value` and `anole_db_options` must be 0.
- Cleanup calls (`anole_handle_release`, `anole_req_abort`, `anole_ws_close`,
  `anole_ws_unsubscribe`, `anole_wt_close`, `anole_wt_stream_reset`,
  `anole_wt_stream_stop`) now return `ANOLE_OK` on a handle whose object is
  already over, closed or released, set no error and are not counted in
  `anole_stats.gone`, so finalizers and `finally` blocks can call them
  blindly. Answer and data calls keep `ANOLE_E_GONE`. A handle of the wrong
  kind, or 0, is now `ANOLE_E_INVALID` on every call (was `ANOLE_E_GONE`).
  New `anole_handle_release(h)` ends any handle the way the application
  giving up would; it replaces `anole_wt_stream_release`.
- Request calls share the `anole_req_` prefix every other family already had:
  `anole_respond` -> `anole_req_respond`, `anole_respond_fd` ->
  `anole_req_respond_fd` (the fd is an `intptr_t`), `anole_stream_start/write/
  write_wait/end` -> `anole_req_stream_*`. `anole_release` is gone:
  `anole_req_fail(r, status, message)` answers an error in the server's
  configured error format (status 0 for 500), `anole_req_abort(r)` drops the
  request without an answer (Zig's `res.abort()`), and `anole_handle_release(h)`
  is the generic cleanup. Constants are grouped by family (`ANOLE_DB_TYPE_*`,
  `ANOLE_DB_F_*`, `ANOLE_GRPC_STATUS_*`, `ANOLE_GRPC_KIND_*`,
  `ANOLE_GRPC_F_FINISH`, `ANOLE_WT_F_*`, `ANOLE_TLS_F_PEM`,
  `ANOLE_SERVER_F_SIGNALS`, `ANOLE_CONSUMER_F_SHARED`, `ANOLE_POLL_F_NOARM`).
  `anole_server_port`'s "one past the last is the HTTP/3 port" is replaced by
  `anole_server_listener(s, i, &info)`, which also gives the address, the UDP
  port, the protocols and, when start failed, which listener and why.
  `anole_server_reload_tls` takes `anole_str` and, with both empty, does what
  `anole_server_reload_certificates` did (removed). WebSockets signal room
  with `ANOLE_EV_WRITABLE`, as every other handle does; `ANOLE_EV_WS_DRAIN`
  (9) is gone. `anole_wt_send_datagram` takes `flags`. Enum-valued parameters
  are `uint32_t`.
- Request records are 128 bytes: `spans_off` says where the header spans
  start (`anole_request_spans` reads it), `peer_cert` is a plain span
  (`anole_request_peer_cert` is gone: `anole_event_str(r, r->peer_cert)`),
  and `timeout_us` and `subprotocol` are new. gRPC call records are 104
  bytes with `metadata_off` (`anole_grpc_metadata(c)`) and `peer_cert`. A
  record's fixed part may now grow at its end; arrays are reached through
  offsets, never `sizeof`.
- `ANOLE_EV_ABORT` now carries an `anole_abort_event`: why
  (`ANOLE_ABORT_CLIENT`, `_DEADLINE`, `_BODY`, `_DRAIN`, `_SERVER`) and what
  the client was sent.
- Event types and handle kinds have one frozen allocation table (docs/c-abi.md,
  `anole.abi.json`): consumers skip types they do not know, obligations come
  only when the configuration asks, numbers are never reused. 40
  `ANOLE_EV_WS_UPGRADE` and 41 `ANOLE_EV_DRAINING` are allocated; handle kind
  6 is a database transaction.

### Added

- `app.listen("3000")` (a bare port) listens on every interface, like
  `":3000"`. A listen address Anole cannot read is now logged with examples.
- `app.rateLimit(.{ .limit = 100 })`, a one-line in-memory rate limiter.
- `anole.websocket.UpgradeOptions.subprotocols` and `.headers`: an endpoint
  that speaks graphql-ws, STOMP or MQTT now echoes the subprotocol the browser
  asked for (browsers fail the connection without it), and the handshake can
  carry a cookie or other headers. `Socket.subprotocol` says which was
  selected. `anole.websocket.isUpgrade(req)` tells a handler it has a
  handshake before it decides.
- `req.paramDecoded(name)`: a route parameter percent-decoded
  (`/users/J%C3%BCrgen` -> `Jürgen`). `req.params` stays raw, as before, and
  now says so.
- `ws.httpVersion()` and `ws.isClosed()`.
- `req.readerLimited`, `req.setDeadline`, `res.headersSent()`.
- `EventStream.comment` (heartbeats), `end` and `draining`.
- `timeouts.write` (30 s) bounds each write once a stream or file body has
  started.
- `anole.Duration`, `anole.Ca`, `anole.ClientAuth`, `anole.ClientOptions`,
  `anole.ServerError`, `anole.TlsLoadError`, `anole.errors`.
- `Compress.Options.brotli_quality`, a per-middleware Brotli quality.
- Databases: `connect_at_start` and `ping_timeout` on MongoDB, `ping_timeout`
  on SQLite, `anole.db.Tls`; `Tx.table`, `Tx.run` and `Tx.with(options)` on
  both SQL connectors; `call.failFmt(code, fmt, args)` in gRPC.
- `Group.grpc` and `Group.grpcWith` register a gRPC service behind a group's
  middleware, for its gRPC calls and its transcoded routes alike; until now a
  transcoded `/v1/...` route skipped a `/v1` group's auth middleware.

- WebSocket handshakes can be decided by the application: `"accept":
  "consumer"` on a websocket route sends each handshake as
  `ANOLE_EV_WS_UPGRADE`, answered with `anole_ws_accept` (a subprotocol,
  extra headers) or refused like any request (401, 403, a body). A route may
  take `handler` and such a `websocket` together, so one app sees every
  request on a path. Auto routes take `"subprotocols"`, and
  `ANOLE_EV_WS_OPEN` says which was selected in the request record's new
  `subprotocol` span. This is what ASGI's `websocket.accept` and
  `websocket.close`, Bun's `server.upgrade()` and graphql-ws clients need.
- Publishes to one topic arrive in the order they were made.

- `include/anole.abi.json`, generated from `src/capi/abi.zig`
  (`zig build capi-abi-json`; checked by `capi-test`): every record with
  offsets, every constant by family, events, handle kinds and error tokens,
  for generated parsers in anole-node and anole-py. `include/anole.schema.json`
  carries `x-anole-abi` and a per-release `$id`.
- `anole_last_error_name()` gives a stable token for the last error
  (`AddressInUse`, `KeyMismatch`, `UnknownKey`...; the full list is in
  docs/c-abi.md and `anole.abi.json`) and `anole_last_errno()` the OS error
  behind it, so bindings can raise `EADDRINUSE` or `OSError(errno)` without
  parsing text. `anole_ws_publish` on a server that is not running answers
  `ANOLE_E_STATE` (was `E_GONE`); a failed `dup` in `anole_req_respond_fd` is
  `ANOLE_E_SYSTEM` (was `E_INVALID`).
- `ANOLE_E_TOOBIG` from `anole_poll` and `anole_poll_wait` now writes an
  `ANOLE_EV_NONE` header whose `len` is the size the next record needs, so a
  binding allocates once instead of doubling.
- `anole_server_open` starts Anole's threads and opens the databases without
  listening, for startup work before traffic (`anole_server_start` still
  opens by itself). `observe.health.checks` declares readiness checks that
  keep `/readyz` at 503 until `anole_server_set_ready` marks them ready;
  `observe.health.listener` serves the health routes on one listener only.
  `anole_server_destroy` on a server that was not drained no longer waits
  for answers only its caller could give: it answers what consumers still owe
  with 503 at once, so it can run on a consumer's thread (Node cleanup hooks,
  Python `atexit`). The log callback belongs to its server and is cleared by
  `anole_server_destroy`.
- In embedded mode Anole's threads block asynchronous signals, so a host's
  SIGCHLD or SIGINT handler never runs on them. A forked child no longer
  inherits a usable server: calls on the parent's server answer
  `ANOLE_E_STATE`, and the child may create its own. `anole_server_start`
  refuses a configuration with more consumers than executors (one would
  never get an event). `anole_consumer_set_wake` lets a restarted worker or a
  new event loop take over a consumer.

- Database transactions: `anole_db_begin` answers with an `anole_db_tx`
  handle; `anole_db_tx_query`/`_exec` run on its connection in order,
  `anole_db_tx_commit`/`_rollback` end it, `anole_db_tx_release` (or
  `anole_handle_release`) rolls back from a finalizer. A transaction is
  bounded as a whole by `timeout_ms` (the database's, 30 s, by default) and
  can be tied to a request. SQLite and PostgreSQL.
- `anole_db_options.req` ties a query to the request or gRPC call it serves:
  it runs on that request's executor, and is canceled (answering
  `ANOLE_E_GONE`) when the request is aborted or passes its deadline.
- `databases[]` takes `timeout_ms` and `errors` (a class to status map, as
  `anole.db.ErrorMap`), and client certificates and `insecure_skip_verify`
  for PostgreSQL, Redis and MongoDB, with the options MongoDB lacked
  (`idle_timeout_ms`, `heartbeat_ms`, `retry_reads`, `retry_writes`,
  `connect_at_start`, `ping_timeout_ms`) and SQLite's `uri` and
  `ping_timeout_ms`; `anole_db_result_event.table` names the table or
  collection of an error.
- `grpc.services[].middleware`: native middleware per gRPC service.

### Fixed

- C ABI: two `anole_ws_publish` calls to the same topic could reach a
  subscriber in the opposite order (they fanned out on different executors).
  Publishes to one topic now arrive in the order they were made.
- C ABI: a fixed-response route behind a JWKS `jwt` middleware ran inline on
  the HTTP/2 reader, where the JWKS fetch could stall the connection; it now
  keeps a task.
- Event streams, streamed responses and file downloads are no longer cut at
  the request timeout (30 s in Zig, `request_ms` + 5 s through the C ABI over
  HTTP/1.1 and tasked HTTP/2 and HTTP/3 streams). Once the head is out, the
  request deadline ends and `timeouts.write` bounds each write the client does
  not take.
- Setting any `http2` option no longer drops the concurrent-stream limit from
  250 to 100.
- `app.tracing()` reads `OTEL_EXPORTER_OTLP_ENDPOINT` and `OTEL_SERVICE_NAME`
  from the environment; it used to need `.process`.
- `iterate` that leaves a transaction open, and a connection from `acquire`
  given back inside one, are now rolled back (and logged) as plain calls
  already were in 0.1.3. A finished SQLite `Tx` fails with `error.Database`
  instead of asserting (undefined behaviour in release builds).
- `Call.fail`, `Call.addTrailer` and `Call.addHeader` copy their strings: a
  message formatted into a stack buffer used to be read after the handler
  returned.
- The C ABI's schema advertised `mongodb+srv://`, which is refused at start;
  it now says so, with the way around it.
- docs/database.md no longer says `.auto` catches a role change made inside a
  function: PostgreSQL does not report `role`; use `.always` for apps that
  switch roles.

- C ABI: `ANOLE_EV_SENT` follows every borrowing call that returned `>= 0`,
  exactly once, zero-length writes included, and is never lost to a full
  queue or a failed allocation (the record is allocated by the call, which
  answers `ANOLE_E_NOMEM` and takes nothing if it cannot). Borrowing calls
  that fail never produce one. On HTTP/2 and HTTP/3 a borrowed whole-response
  body is copied (documented).
- C ABI: a libanole built with Redis or MongoDB but neither SQLite nor
  PostgreSQL refused every `anole_db_query` and `anole_db_exec` with
  `ANOLE_E_UNSUPPORTED`.
- C ABI executors no longer spin a core at 100% while a consumer's queue is
  full: they sleep until the consumer polls. Events (`ANOLE_EV_ABORT`,
  `_WRITABLE`, `_BODY`, `_SENT`) are no longer dropped when the queue is full.

- A server busy with many thousands of connections on one executor let new
  ones in slowly: its accept loop took 128 connections per pass over the
  busy ones (64 once spawn backpressure applied), and a pass takes about
  200 ms at 25,000 connections. The clients still in the backlog waited
  10 s or more for their first answer while those already in were served
  every pass (HTTP/1.1 at 25,000 connections on one CPU: p99 6.3 s, about
  3,800 timeouts). Idle connections waking from parking queued behind the
  same limit (p50 1.6 s). zio's accept and spawn budgets now grow to the
  number of tasks that ran during the last trip to the back of the run
  queue (zio `fast_accept`, which Anole turns on).

- zio: since upstream lalinsky/zio#841, with pinned scheduling a task in the
  overflow queue (one woken by a timer or I/O included) could wait forever
  once more than 256 tasks on one executor kept yielding: the fork keeps the
  ring and its overflow one FIFO queue again. zio is now upstream main
  035d245 merged into the fork, plus that fix.

## 0.1.3 (2026-10-22)

### Security

- `res.sendFile(dir, path, ...)` no longer opens a path outside `dir`. An
  absolute path or a `..` segment (on Windows also a `\`-separated one, or
  a `:`) now fails with `error.BadPathName`, which the server answers with
  404, as static routes already did. Until now a handler that passed request
  input to it, such as `res.sendFile(dir, req.params.get("name").?, .{})`
  or a query parameter, let a client read any file the server process
  could open (`GET /files/../../etc/passwd`). To send a file your program
  names outside the directory, open the directory it is in and pass the
  name relative to that.
- A WebSocket in `anole.websocket.Rooms` now leaves every room it is in
  when it is released (`Socket.deinit`, which `app.ws`, `app.wsCallbacks`
  and the C ABI's sockets run). Until now `Rooms` kept a pointer to the
  socket until the handler called `leave`, so a handler that returned
  without leaving (an early `return` or error before its `defer`, a `close`
  callback that missed a room) left a freed socket in the room, and the
  next broadcast wrote into freed memory: a crash, or memory corruption
  that a client could trigger by joining and disconnecting. `leave` still
  works for leaving earlier.
- A room member closed for not keeping up (`on_full = .close`) now has its
  connection ended (a TCP shutdown over HTTP/1.1, a stream reset over
  HTTP/2 and HTTP/3), so its handler's `receive` ends and its `close`
  callback runs. Until now it stayed open with nothing served to it, for
  ever with the default `timeout`, holding its task and memory.
- C ABI: handle generations started at 1 again for every server, so after
  `anole_server_destroy` and a new `anole_server_create` in the same
  process, a handle kept from the first server (a late answer, a WebSocket
  send, a WebTransport write) was valid against whatever the second server
  held in the same slot: it could answer another client's request with a
  response meant for someone else. The slots of each new server now start
  past every generation an earlier server handed out, so such a handle is
  `ANOLE_E_GONE`.
- Databases (`anole_db_*` in the C ABI, and plain calls on `anole.sqlite`
  and `anole.pg`): a call that left a transaction open, such as a bare
  `BEGIN` or a script that failed before its `COMMIT`, was taken as
  done. On SQLite the shared writer connection stayed inside that
  transaction, so every later write from any request joined it, unseen by
  readers and lost by a later `ROLLBACK` from anyone. On PostgreSQL the
  connection was closed on its way back to the pool and the statements
  meant for the transaction each committed on their own. Such a call is
  now rolled back and fails (class `other`, a 500 by default) with a
  message pointing to `begin`/`transaction`; a whole transaction in one
  call without parameters still works. A transaction API for the C ABI
  comes later.

### Breaking

- C ABI 0.6: bit 0 of every send-type call's flags is `ANOLE_BODY_BORROW`,
  and a call's own flags start at bit 1. `ANOLE_WT_FIN` was 1, the same
  bit as `ANOLE_BODY_BORROW`, so a borrowing `anole_wt_stream_write` (a
  binding's usual "borrow above 64 KiB" helper) silently ended the
  WebTransport stream after its bytes. `ANOLE_WT_FIN` is now 2, in
  `anole_wt_stream_write`'s flags and in `ANOLE_EV_WT_DATA`'s; a borrowed
  write is copied as before and gets its `ANOLE_EV_SENT`; unknown flag
  bits are `ANOLE_E_INVALID`. Action: rebuild against the new `anole.h`
  (a binding built against ABI 0.5 that passes 1 to end a stream now
  borrows instead, and its streams do not end).

### Fixed

- C ABI: `anole_server_drain`, `anole_server_reload_certificates` and
  `anole_server_reload_tls` called from another thread while the server
  stopped could reach the server after its run thread had freed it (the
  server lived on that thread's stack), a use-after-free in the host
  process. The header promises these calls from any thread; they now
  either act on a server that is still serving or answer as documented
  (`ANOLE_OK` for a drain once the server is stopping, `ANOLE_E_STATE`
  for a reload), and a stop waits for a reload under way before it frees
  the server. `anole.h` states the rule: any thread, between
  `anole_server_create` and `anole_server_destroy`.
- C ABI: two routes of the configuration that the router cannot tell
  apart (the same method and path twice, two parameter names at one
  position, a method route less specific than an any-method one, or a
  route on a path Anole serves itself, such as the metrics path) made
  `anole_server_start` panic, which aborted the host process (Node,
  Python). `anole_server_start` now answers `ANOLE_E_CONFIG`, and
  `anole_last_error` names the routes. Zig's `app.get` and friends still
  panic on a conflict, at registration.

## 0.1.2 (2026-10-22)

### Breaking

- `anole.pg.Options.reset_session` is now an enum, `.auto` by default:
  a connection going back to the pool is reset only when what it ran may
  have changed its session (`SET`, `set_config(..., false)`, `SET ROLE`,
  temporary tables, advisory locks, `LISTEN`, cursors `WITH HOLD`,
  `lastval()` after an `INSERT`, `DO`/`CALL`, or a setting the server
  reports changed), with just the statements that undo it; `PREPARE`,
  `DEALLOCATE`, `DISCARD ALL` and `LOAD` close the connection. 0.1.1 reset
  every connection on every release, which cost about a fifth of the
  requests per second on pooled reads. Action: `true` becomes `.always`
  (or keep the default), `false` becomes `.off`; in the C ABI's
  configuration, `"reset_session"` takes `"auto"`, `"always"` or `"off"`.
  Use `.always` if server-side functions change session state, since
  `.auto` judges from the SQL text (docs/database.md, Session state).

### C ABI

- `anole_db_*` with SQLite (additions to ABI 0.1): databases from the
  configuration (opened at start with an `init` script), queried without
  blocking the caller;
  each answer is an `ANOLE_EV_DB_RESULT` record (column names and typed
  cells, or changes and the last rowid) with the caller's `user_data`.
  Per-query timeout, coalescing and the TTL result cache with tags and
  `anole_db_invalidate`; failures carry their class, the status Anole would
  answer and the database's detail. `anole.sqlite`'s `table` and `run`
  are the Zig side: rows and parameters known only at run time
  (`anole.sqlite.Value`).
- `anole_db_*` with PostgreSQL: a `"postgres"` database (`url`, `sslmode`,
  `ca_file`/`ca_pem`, pool bounds and timeouts, `init`), the same calls,
  options, answers and error classes. TLS is checked by default
  (verify-full for a server on another host); a CA given in the
  configuration can't be turned off by the URL. Cells come in PostgreSQL's
  text format but for bool, integers, floats and bytea, each with its
  column's type OID (`anole_db_cell.db_type`, formerly `reserved`) for a
  binding's own type parsers; `ANOLE_DB_BOOL` is a new value and cell type.
  `timeout_ms` cancels the statement on the server.
- `anole.db.Value`, `Table` and `Changes` are shared by the SQL connectors
  (`anole.sqlite`'s are now these); `anole.pg` gains `table` and `run` for
  rows and parameters known only at run time, and `Options.sslmode`.
- `anole_db_*` with Redis and Valkey: a `"redis"` database (`url`,
  `ca_file`/`ca_pem`, pool bounds and timeouts). A command is `sql` (its
  name and fixed words) plus parameters as binary-safe arguments;
  `anole_db_query` answers with the reply as a tree of cells in preorder
  (`ANOLE_DB_ARRAY`, `ANOLE_DB_MAP` and `ANOLE_DB_ERROR` are new cell
  types), `anole_db_exec` with an integer reply as `changes`. Coalescing
  and the result cache apply to read commands.
- `anole.redis`'s `Query.reply` sends a command known only at run time
  (`[]const []const u8`), through the cache for read commands; the result
  caches copy types that hold themselves (a reply tree).
- C ABI 0.3: `anole_db_*` with MongoDB: a `"mongodb"` database (`url`, `database`,
  `ca_file`/`ca_pem`, pool and selection timeouts). `sql` names the
  operation and the collection (`"find orders"`): find, findOne,
  aggregate, countDocuments, insertOne, insertMany, updateOne, updateMany,
  replaceOne, deleteOne, deleteMany, and runCommand; parameters are BSON
  documents in the drivers' order, options under the command's names.
  Answers are rows of `ANOLE_DB_BSON` documents (a new cell type), a count,
  or the driver's write result; `anole_db_exec` gives the count changed.
- `anole.mongodb.dynamic`: those operations named at run time with BSON
  arguments; `aggregate` caches a `bson.Array` pipeline that only reads.
- C ABI 0.2: a gRPC server whose methods are implemented by the consumer
  (Node, Python, C). A `"grpc"` configuration section names the services
  (with their descriptors, a `FileDescriptorSet`, or a method list); Anole
  serves gRPC over HTTP/2, gRPC-Web, Connect (GET too) and JSON
  transcoding, with framing, gzip, deadlines, per-call limits and
  `grpc.health.v1`, and the consumer gets `ANOLE_EV_GRPC_CALL`,
  `ANOLE_EV_GRPC_MESSAGE` and `ANOLE_EV_GRPC_HALF_CLOSE` with messages as
  protobuf bytes and answers with `anole_grpc_send_headers`,
  `anole_grpc_send`, `anole_grpc_send_wait`, `anole_grpc_finish` and
  `anole_grpc_read` (credit for request messages);
  `anole_grpc_health_set` sets health statuses. Unary and server-streaming
  calls that arrive whole over HTTP/2 are answered with no task, as
  `no_wait` routes are. JSON goes through upb (protobuf's C runtime,
  BSD-3-Clause, built from the protobuf 36.2 release), linked with
  `-Dgrpc`. grpc-go's interop client passes its 14 cases against a C
  implementation of the test service (`tests/capi/grpc_interop.c`). See
  docs/c-abi.md#grpc.
- C ABI 0.4: WebTransport, a `"webtransport"` route (HTTP/3) that hands
  sessions to a consumer. Events `ANOLE_EV_WT_OPEN` (the CONNECT request),
  `_WT_STREAM`, `_WT_DATA`, `_WT_STREAM_RESET`, `_WT_STREAM_STOP`,
  `_WT_DATAGRAM`, `_WT_DRAIN`, `_WT_CLOSE` (20-27); handles `anole_wt` and
  `anole_wt_stream`; calls `anole_wt_open_stream`, `anole_wt_stream_write`
  (`ANOLE_BUSY`, then `ANOLE_EV_WRITABLE`), `anole_wt_stream_reset`,
  `anole_wt_stream_stop`, `anole_wt_stream_release`,
  `anole_wt_send_datagram` (a bounded queue that drops the oldest),
  `anole_wt_max_datagram`, `anole_wt_close`; `anole_stats` gains
  `wt_sessions` and `wt_datagrams_dropped`; `anole_has_feature("webtransport")`.
- C ABI 0.5: TLS extras, mutual TLS per listener (`tls.client_auth`
  `"none"`/`"request"`/`"require"` with `client_ca_file` or
  `client_ca_pem`, HTTP/3 included); the client's certificate (DER) in
  request records (`ANOLE_REQ_PEER_CERT`, `peer_cert`, which replaces the
  reserved word, and `anole_request_peer_cert`), also on WebSocket and
  WebTransport opens; `anole_server_reload_tls` swaps in new certificate
  files or PEM (`ANOLE_TLS_PEM`) for every TLS listener and HTTP/3, and
  SIGHUP reloads with `ANOLE_SERVER_SIGNALS`; the configuration gains
  `trust_forwarded_proto`, `trust_forwarded_host` and a listener's
  `proxy_protocol_from`. `anole_server_reload_certificates` answers
  `ANOLE_E_STATE` (was `ANOLE_E_SYSTEM`) when no listener has TLS.
- `anole.webtransport.Session` and `Stream` gain calls that never wait
  (`tryAccept`, `tryOpen`, `takeDatagram`, `trySendDatagram`, `tryRead`,
  `tryWrite`, `sendError`, with `generation`/`waitChange`), for code that
  runs a session from one task.

### Fixed

- C ABI: a program linked against `libanole.a` with dead-stripping
  (`-Wl,-dead_strip`, or `zig cc -O1` and Zig's release links) crashed on
  macOS when its first TLS listener started: the packed object lost the
  symbol flags that keep BoringSSL's assembly together, so the linker cut
  it apart. The flags are restored when libanole is packed.
- C ABI: on x86_64 Linux, a program or extension linked against
  `libanole.a` with GNU ld got an executable stack (the packed object had
  no `.note.GNU-stack`); glibc 2.41 refuses to load such an extension.
  The note is added when libanole is packed.
- C ABI: a publish (`anole_ws_publish`) could overtake an
  `anole_ws_subscribe` made before it, since the subscription is applied
  on the socket's executor and the publish fans out from another, so a
  socket that had just subscribed could miss it. A publish now waits for
  the subscriptions taken before it.
- C ABI: after an error answer, `anole_last_error` could still show the
  text an earlier call left (an `ANOLE_E_GONE` read as "invalid
  argument"). Every negative answer now sets its own text.
- WebTransport: a one-way stream that arrived whole (its data and its end)
  before its session was established on the receiving side was dropped,
  so a server that opened a stream right after accepting the session could
  lose it; such a stream is now kept for the session.

### Clients

- The server's client (`anole.client(req)`, `app.client()`) no longer
  closes and redials connections when many handlers call one upstream at
  once. Its pool kept 8 idle connections in all, so with 32 requests in
  flight to one host every round closed the rest and dialed them again;
  the connections' buffers churning through the allocator grew a server's
  memory without end (Sharkbench's web workload: 19 to 39 MB in a few
  minutes, at a steady 33k req/s). Now:
  - Each executor has a pool of its own, as the database connectors do,
    so a connection stays on the executor whose requests use it.
  - `ClientConfig.max_idle_per_host` (256) bounds the idle connections to
    one host and `max_idle_connections` (1024, was 8 and a `u8`) those in
    all, per executor's pool. A pool never holds more than were in flight
    at once.
  - `ClientConfig.idle_timeout` (90 s, as Go and hyper) closes connections
    that sat idle that long, from a task per pool that runs only while
    connections are idle; a shorter `Keep-Alive: timeout` still wins.
  - A pooled connection's arena keeps at most 32 KiB of its last response
    (it kept all of it, however big).
  - `ServerOptions.client` sets the server's client's `ClientConfig` (the
    pool, timeout, CAs, HTTP/2); it had only the defaults.
  - `Client.dials` counts the connections a client opened. Breaking:
    `client.pool` is now `client.pool()` (the calling executor's pool).

### HTTP/3

Fixes from the QUIC interop runner's matrix (Anole's server against all
15 client implementations).

- Path validation after a NAT rebinding or a migration: both
  PATH_CHALLENGE probes of a round now carry the same data (xuckless/ngtcp2
  patch). Clients that answer only the latest challenge on a path (quinn,
  picoquic, s2n-quic) answered the second probe only; validation still
  succeeded, but observers that check the first challenge (the interop
  runner's rebind-port and rebind-addr cases) did not see it answered.
- The flush no longer holds (up to 1 ms, for the answers of the requests
  a batch started) when the batch carried 0-RTT requests or completed the
  handshake: the server's handshake flight, the ACK of the client's 0-RTT
  packets and HANDSHAKE_DONE go out at once.
- After a NAT rebinding, the first packet to the client's new address is
  now always the PATH_CHALLENGE (xuckless/ngtcp2 patch): while pacing held
  data back, an ACK the client's packets called for went out to the new
  address first.
- A NAT rebinding during the handshake: the server now follows the
  client to its new address once a packet from there authenticates and is
  new (xuckless/ngtcp2 patch), instead of sending to the old address while
  ignoring the new one until the handshake timed out. On Linux, with one
  UDP socket per core, a client's Initial and 0-RTT packets are now
  steered by the first byte of the connection ID the client chose, not by
  its address and port, so its packets from a new port reach the
  endpoint that holds its connection rather than starting a second one.
- A client whose first Initial reached the server without the start of
  its ClientHello got a Retry, and if it resent its whole ClientHello
  before that Retry arrived, the resent copy started a second connection
  beside the one the Retry led to. Such an Initial now gets a Retry again
  (the endpoint remembers its last 64 Retries for 10 s).
  `h3.Stats.retries` counts the Retries sent.
- `Http3.prefer_v2` (default true, as before): false keeps clients that
  offer QUIC v2 beside v1 on v1. The interop server now moves clients to
  v2 only in the runner's v2 case.
- The h3 client: `ConnectOptions.quic_v2` offers QUIC v2 beside v1, and
  `ClientConnection.quicVersion()` reports the version in use.
- Interop runner endpoint only (`hq_interop_root`): the server takes
  "hq-interop" or "h3" in the order the client lists them (msquic offers
  hq-interop first and speaks HTTP/0.9).

## 0.1.1 (2026-10-22)

### Security

Changes that need action or alter behaviour are also collected under
Breaking below.

#### HTTP/3 and WebTransport

- HTTP/3: long-header packets whose connection ID is longer than QUIC
  allows (20 bytes), and Version Negotiation packets sent to the server,
  are dropped before any lookup. Previously one such datagram could crash
  the process. Every deployment with HTTP/3 on should upgrade; no
  configuration change is needed.
- HTTP/3 server: the request head's size (64 KiB, as advertised in
  SETTINGS) and field count (`request.max_header_count`) are enforced as
  the fields arrive; a larger head is answered 431. Before, the whole head
  was kept in memory however large it was.
- HTTP/3 server: cookie fields sent separately are joined with "; " and
  other repeated request fields are all kept, as over HTTP/1.1. Before,
  only the last of each was kept, which could drop or shadow a session
  cookie.
- WebTransport: a peer's stream that is reset before it names its session
  is now freed. A peer's streams now hold its stream credit until the
  handler releases them (before, credit came back as soon as a stream
  ended, even if it was never accepted), and at most 100 streams each way
  wait to be accepted per session. A peer that opens streams a handler
  does not accept now waits for credit instead of growing server memory.
- HTTP/3 server: a new connection that is given up right after its first
  datagram (for example because that datagram also carried an error) no
  longer frees state that a 0-RTT request started from the same datagram
  still uses. Only servers with `early_data` on were affected.
- HTTP/3 server: a request the client resets now keeps counting against
  `max_streams_bidi` until its handler returns. Before, its stream credit
  came back at once, so handlers of reset requests could pile up past the
  limit (the HTTP/3 form of HTTP/2's "rapid reset").
- HTTP/3: `http3.hq_interop_root` (the QUIC interop runner's HTTP/0.9 file
  server, which bypasses the router and middleware) is refused with
  `error.HqInteropNotAllowed` unless the program's root file declares
  `pub const anole_hq_interop = true;`. Breaking only for programs that
  set it.

#### HTTP/2 and HTTP/1.1

- HTTP/2: a stream refused before it reached a handler (a header list past
  `max_header_list_size`, or one nghttp2 rejects) is freed when it closes;
  it used to be kept until the connection ended, so one connection could
  hold memory without bound. A peer whose streams keep being refused is
  sent GOAWAY(ENHANCE_YOUR_CALM) past `http2.refused_stream_burst` (100,
  refilled at `refused_stream_rate`, 10 a second).
- HTTP/2: a response whose handler has returned must be sent within
  `timeout.request` (or `timeout.keepalive` when that is off); a peer that
  gives it no flow-control window gets the stream reset, and a connection
  whose peer stops reading is closed after one write blocks that long.
  Such streams used to be held, and graceful drains to wait, indefinitely.
- HTTP/2: the raised body windows of one connection's streams share
  `http2.reading_window_budget` (16 MiB), so a connection with many uploads
  at once no longer takes 1 MiB per stream without bound. docs/server.md
  now sizes HTTP/2 memory per stream.
- HTTP/2: a request's repeated header fields are all kept (they used to
  replace each other), and cookie fields sent separately are joined with
  "; ", so no cookie is lost. `:authority` is the request's host; a `host`
  field that names another host gets 400.
- HTTP/1.1 requests without a `Host` field, and requests with two, get 400
  (RFC 9112). `server.request.require_host = false` accepts them again.
- A streamed response with a `Content-Length` no longer writes past that
  length: the write fails with `ContentLengthMismatch` (now part of
  `StreamingBodyWriter.Error`) and the connection is closed after the
  response. **Breaking:** `res.header`/`res.addHeader` refuse
  `Transfer-Encoding` and `Connection` (`error.InvalidHeaderName`); use
  `res.keepalive = false` to close the connection. A second
  `Content-Length` from `addHeader` replaces the first.
- A request body with broken framing (chunked) or a corrupt gzip/deflate
  coding is answered 400 and logged at `debug`, instead of 500 at `err`.
  Reading it fails with the new `error.MalformedBody` (was the parser's
  `InvalidChunkSize`/`ParseFailed`/... or zlib's `CorruptInput`).
- HTTP/1.1: the rest of a request body a handler left unread is drained
  only until the request's deadline, and at most `timeout.keepalive` (10 s
  when that is off); a request already past its deadline is not drained
  and its connection closes. A handler that lifted its timeout, or caught
  the timeout's error and returned, let a slow client hold the connection
  indefinitely.
- Static files: a file modified after the year 9999 no longer crashes the
  server while formatting `Last-Modified`; the date is capped at 9999.
- `anole.Server` answers 425 Too Early to unsafe requests marked
  `Early-Data: 1` on every server, not only when HTTP/3 is on, so a proxy
  that accepts TLS early data in front of an HTTP/1.1 or HTTP/2 server no
  longer gets replayable POSTs through. `app.use(anole.early_data.Guard{})`
  is no longer needed (it is harmless).

#### PROXY protocol and forwarding headers

- PROXY protocol v2: a header whose TLV length is near 65535 is refused
  instead of crashing the process (or, in ReleaseFast, reading past a
  buffer). Only listeners with `proxy_protocol = true` were affected.
- PROXY protocol listeners take `proxy_protocol_from`, a list of networks
  in CIDR notation allowed to send the header; connections from other
  peers are closed. Optional; recommended when the port is reachable by
  more than the load balancer.
- `trusted_proxy_hops`: only the selected `X-Forwarded-For` entry is parsed,
  so a malformed entry the client added no longer makes the proxy's address
  the client's; a selected entry that is not an address reports `0.0.0.0`.
- **Breaking:** `X-Forwarded-Host` is honoured only with the new
  `server.trust_forwarded_host = true`. `X-Forwarded-Proto` stays on with
  `trusted_proxy_hops` and can be turned off with
  `trust_forwarded_proto = false`. Make sure the proxy overwrites both.

#### TLS

- TLS listeners offer only ECDHE key exchange with AES-GCM or
  ChaCha20-Poly1305 over TLS 1.2 (BoringSSL's default also allowed RSA key
  exchange and CBC with SHA-1). TLS 1.2 clients that support none of these
  can no longer connect. Docs now state that revocation (CRL, OCSP) is not
  checked and that `.dev_self_signed` certificates are CAs for development
  only.
- Mutual TLS: a TLS session resumes only under the client-auth settings
  (CAs and mode) it was verified under, on TCP and QUIC listeners, and a
  certificate reload that changes them no longer carries the ticket keys
  over. Removing a client CA and reloading now stops clients whose
  certificates it vouched for from resuming with older sessions.

#### Clients (HTTP, HTTP/2, HTTP/3, gRPC)

- HTTP/2 client: a graceful GOAWAY from the server no longer ends the
  connection at once; the streams it covers finish. A stream released
  after a GOAWAY is reset and freed once the session has closed it, never
  while the session can still reach it.
- HTTP/2 and HTTP/3 clients: a response's header fields are bounded by the
  new `ConnectOptions.max_header_list_size` (64 KiB, advertised to the
  server), and at most five informational (1xx) responses may precede the
  final one. Past either the stream fails with `error.HeadersTooLarge` or
  `error.TooManyInterimResponses` (new members of `StreamError`). The HTTP/2
  client also reads a final response that follows a 1xx correctly now.
- HTTP client: a URL whose path or query holds a space, a control
  character or a byte past 0x7f is refused with `error.InvalidUrl`, for
  `fetch`, redirects, WebSocket upgrades and HTTP/2 alike, instead of being
  written into the request line. Percent-encode such bytes; URLs that
  carried raw UTF-8 now fail (breaking).
- HTTP client redirects: across origins the `Referer` is only the origin
  (browsers' default policy); a 307 or 308 that would carry the body to
  another host is not followed, and its response is returned (breaking for
  callers that relied on it; `ClientConfig.check_redirect` can allow it).
  New: `ClientConfig.check_redirect` (follow, stop or fail each redirect)
  and `ClientConfig.deny_private_addresses` (refuse loopback, private,
  link-local and similar addresses, after DNS, on every hop). Redirects are
  followed in a loop, so the stack no longer grows with `max_redirects`.
- HTTPS client: a response body delimited by the end of the connection
  (no Content-Length, not chunked) now fails with
  `error.TlsConnectionTruncated` when the TLS connection ends without
  close_notify, instead of being returned as complete.
- TLS clients: the cache of trust stores built from CA bundles and the
  HTTP/3 session-ticket cache are keyed by SHA-256 of their contents, so
  two different CA sets or client identities can never share an entry.
- gRPC client: a call takes at most `Channel.max_received_bytes` (64 MiB,
  `CallOptions.max_received_bytes` per call) of response messages in all,
  then is canceled with RESOURCE_EXHAUSTED, so a server streaming without
  end cannot grow the caller's arena without bound. Response frames are read
  and inflated outside the arena and freed once decoded. Behaviour change
  for clients of streams that send more than 64 MiB.

#### JSON, gRPC and transcoding

- `anole.json.parse` / `readBody`: a whole-number float just past the range
  of an integer field (such as `9223372036854775808.0` for an `i64`) is
  refused as `error.Overflow` (400 from `readBody`) instead of stopping the
  process. No configuration change.
- `anole.json.parse`: input nested deeper than the new
  `ParseOptions.max_depth` (128) fails with `error.NestingTooDeep`, which
  only a type that contains itself can reach, and `YYJSON_READ_INSITU` in
  `ParseOptions.flags` is ignored (the input is read-only). `json.Error`
  gains `NestingTooDeep` (breaking for exhaustive switches).
- gRPC, gRPC-Web, Connect and transcoded routes: protobuf decoding is
  hardened (zig-protobuf with Anole's patches): messages and groups nest at
  most 100 levels, string and bytes lengths are checked against the input
  before memory is allocated for them, and Timestamps with an out-of-range
  month, day or time are refused. Connect and gRPC-Web JSON request
  messages nested deeper than 100 levels fail the call. Such requests fail
  with INTERNAL (INVALID_ARGUMENT, 400, on transcoded routes) instead of
  stopping the process or allocating up to 2 GiB. No configuration change.
- JSON transcoding: a query parameter can no longer override a field the
  path template sets when the template names it by its JSON name
  (`{bookId}`) and the query by its proto name (`?book_id=`), or the other
  way around. The path's value stands, as documented. No configuration
  change.
- gRPC: new per-registration limits (`RegisterOptions`). `read_timeout`
  (default 30 s) bounds how long a request message may take to arrive,
  which a call without `grpc-timeout` used not to bound at all;
  `max_received_bytes` (default 64 MiB) bounds what one call receives in
  all, since decoded messages stay in the call's arena; `max_call_duration`
  (default none) caps every call. A message frame's memory now grows with the
  bytes that arrive instead of being allocated in full from its 5-byte
  header, and frames are freed once decoded. Transcoded routes read the body
  under the server's request timeout before the call's deadline applies.
  Behaviour change: a client-streaming call that receives more than 64 MiB
  in all now fails with RESOURCE_EXHAUSTED; raise `max_received_bytes` for
  such services.
- JSON transcoding: a binding with a `body` answers 415 to a non-empty body
  whose `Content-Type` is not `application/json` (or `+json`). Breaking for
  clients that post JSON with another content type.
- gRPC: `Call.addTrailer` refuses names that are not metadata keys and
  values that are not printable ASCII (base64 text under a `-bin` name) with
  `error.InvalidMetadata`, so client data echoed into a trailer cannot add
  trailer lines in gRPC-Web. New `Call.addBinaryTrailer` encodes raw bytes.
  Breaking for handlers that passed raw bytes or upper-case names.

#### WebSocket and Server-Sent Events

- **Breaking:** WebSocket and WebTransport handshakes from a browser page of
  another origin are refused with 403. `UpgradeOptions.allowed_origins` and
  `webtransport.AcceptOptions.allowed_origins` default to `.same_origin`
  (the request's own host and port); list other origins with
  `.{ .list = &.{"https://app.example.com"} }`, or `.any` for endpoints that
  do not rely on cookies. Clients that send no `Origin` are not affected.
  C ABI WebSocket routes take `"origins"`. Apps whose pages connect from
  another origin must list it. See docs/websocket.md#origins.
- WebSocket over HTTP/1.1: the handshake must be a GET with a
  `Sec-WebSocket-Key` of 16 bytes in base64 (RFC 6455 §4.2.1); anything else
  is not upgraded.
- WebSocket over HTTP/1.1: a control frame whose header claims more than
  125 bytes, or that is fragmented, is refused (close 1002) before its
  payload is waited for, on callback sockets too; control-frame payloads no
  longer take memory from the message being assembled. No configuration
  change needed.
- WebSocket over HTTP/2 and HTTP/3: RSV1 on a control frame or a
  continuation is refused (close 1002) when permessage-deflate is in use; a
  ping or pong over 125 bytes from the handler fails with
  `error.LargeControlFrame`; a close goes out once even when two tasks
  close at the same time, and a frame cut short ends sending.
- WebSocket `Rooms`: a broadcast no longer waits for any member. It queues
  the message once for every member, and each member's own task sends its
  queue in order on the socket's executor. A member's queue is bounded
  (`Rooms.Options.max_queued_bytes`, 1 MiB); a member whose send has been
  stuck while its queue is full is closed (`on_full = .close`, the default,
  after `close_after_ms`) or skips messages (`.drop`). `broadcast` now
  returns for how many members the message was queued. New:
  `Rooms.initOptions`. Joining a room twice is one membership, so one
  `leave` always ends it.
- permessage-deflate buffers no longer come from the request's arena, which
  is not thread-safe over HTTP/1.1, so a broadcast compressing for a socket
  from another executor cannot corrupt it. The docs now say that
  `req.arena` and `call.arena` are not thread-safe.
- Server-Sent Events: a bare CR in event data now ends a `data:` line, as
  LF and CRLF already did (in `send` and in `startSend`'s writer, also when
  a CRLF is split across two writes). Before, data relayed from one user
  could add `event`, `id` or `retry` fields to the events other users got.
  No configuration change needed.

#### Sessions, cookies and auth

- `setCookie` refuses a `path` or `domain` containing `;` or a control
  character (`error.InvalidCookiePath`, `error.InvalidCookieDomain`), so a
  value taken from a request cannot add cookie attributes.
- Session cookies: `cookie_opts` of `anole.session.Config` and of
  `anole.http.middleware.Session.Config` is now `SessionCookieOpts`, whose
  every field defaults to the safe value. Setting one field (say
  `.{ .same_site = .none }`) used to reset the others to plain cookie
  defaults: no `HttpOnly`, no `Secure`, no `Path`. Breaking: the type
  changed and has no `max_age` (the middleware sets it); struct literals
  keep compiling.
- `anole.http.middleware.Session` (the HMAC-signed cookie): every cookie
  now carries a signed expiry (`max_age`, else the new `lifetime`, 24 h,
  renewed while the session is in use), and the signature covers the
  cookie's name. Cookies signed before this release are no longer accepted
  (users sign in again); no configuration change needed.
- Server-side sessions: a request that loaded a session before it was
  destroyed (a logout, `regenerate` from another request) no longer writes
  it back when it ends. The middleware now writes a session only when the
  request changed it, and only if it still exists (`Store.update`, Redis
  `SET ... XX`), and renews an unchanged one with `Store.touch` (Redis
  `EXPIRE`). `Store.VTable` has the two new optional entries; a custom store
  without them falls back to `load` + `save`, so implement them.
- `MemoryStore` sweeps expired sessions as new ones are written, and holds
  at most `max_entries` (100,000 by default, `MemoryStore.initOptions`);
  before, sessions created and never seen again (anonymous visitors, CSRF
  tokens on a login form) stayed in memory for good.
- `anole.session.regenerate` also drops the session's CSRF token, so a
  token from before a sign-in is not valid after it. Both session
  middlewares refuse a `__Host-`/`__Secure-` cookie name that their
  `cookie_opts` do not satisfy (`error.CookiePrefixMismatch`); docs/auth.md
  recommends `__Host-anole_session` in production.
- JWT: `Keyring.verify` (and so `RequireJwt` with a keyring) refuses a
  policy without an `audience` (`error.AudienceRequired`, 500 from
  `RequireJwt` with the fix in the log), since a provider's keys also sign
  tokens for its other clients. Action needed if you verify keyring tokens
  without an audience: set `.audience`, or `.allow_any_audience = true` for
  keys that sign for your application alone. New `Policy.typ` (e.g.
  `"at+jwt"`) checks the header's `typ`, and `Policy.require_iat` makes
  `iat` mandatory.
- JWKS `Keyring`: while the provider can't be reached, keys past their TTL
  stay in use for `stale_seconds` (24 h), and failed fetches back off
  (`retry_seconds` 5, doubling up to `max_retry_seconds` 300). Before, an
  outage failed every request with 503 and turned each one into another
  fetch. No configuration change needed.
- OIDC: ID tokens must carry `iat`; `azp`, when present, must be the
  `client_id` (before, it was checked only with several audiences); the
  token request no longer follows redirects (a 307/308 would have carried
  the code and client secret on); `Provider.discover` refuses non-`https`
  issuers and endpoints (`error.InsecureEndpoint`, loopback `http` aside).
  `Identity` gains `issuer`: key accounts on `(issuer, subject)`, as
  docs/auth.md now says.
- Rate limiting: `ratelimit.clientAddress` groups IPv6 clients by their /64
  (`clientAddressPrefix(bits)` for another prefix), so a client with a
  /64 no longer gets a bucket per address. `MemoryLimiter` never evicts a
  throttled bucket to make room for a new key (a full table sends new keys
  to a shared overflow bucket instead), and forgets an idle key only once
  its bucket has refilled; before, a stream of fresh keys, or waiting
  `idle_ms` on a long window, reset a client's limit. docs/auth.md's API key
  example now keys on the verified owner, not the raw header. Rate-limit
  keys of IPv6 clients change; no configuration change needed.
- `auth.apikey.generate` and `session.devKey` take their bytes from the
  operating system (`std.Io.randomSecure`) and fail rather than fall back
  to a weaker source; `apikey.generate` can now return
  `error.EntropyUnavailable`.

#### Response cache, request IDs, logs and metrics

- Response cache: requests with a TLS client certificate bypass it like
  those with `Authorization`/`Cookie`/`X-API-Key`, and the new
  `ResponseCache.Options.cacheable` predicate refuses others per route.
  docs/routing.md now warns up front that an answer depending on anything
  else (an app-specific header, the client's address) must be excluded
  through `credential_headers` or `cacheable`. Check your cached routes.
- `RequestId` with `trust_incoming` keeps an incoming ID only if it is 1 to
  128 of `[A-Za-z0-9._:-]` (before: any visible ASCII), and the JSON access
  log escapes `request_id`, `trace_id` and `span_id`: a client-chosen ID
  could add or override fields in the JSON line.
- Access logs (`observe.AccessLog`, `middleware.Logger`) leave the query
  string out by default (`log_query = true` keeps it), since queries carry
  sign-in codes, reset tokens and API keys. `access_log.format` drops it
  too; `formatLine` takes the option. Log consumers that parsed the query
  out of `path` need `log_query`.
- `app.metrics(.{ .listener = "admin" })`, `app.health(.{ .listener = ... })`
  (and `Registry.serveOnListener`, `Health.Options.listener`) serve
  `/metrics`, `/healthz` and `/readyz` on one named listener only, 404
  elsewhere. Without it they are on every listener, as before;
  docs/observability.md now says how to keep them off the public port,
  since they name routes, errors, databases and failing checks.

#### Databases

- **PostgreSQL connects to a remote server with `verify-full` when no
  `sslmode` is given (breaking).** A server on this machine (loopback, Unix
  socket) still gets `prefer`. Action: a server reached by a name or
  address its certificate does not carry, or signed by a private CA, now
  fails to connect; set `sslrootcert` (or `Options.tls.ca`), or set
  `sslmode` explicitly (`require` encrypts without checking, `disable`
  sends plain text). The log says which.
- **PostgreSQL sends the password in clear text or as MD5 only to a
  verified server or one on this machine (breaking).** Action, only for a
  server that still asks for `password` or `md5` over the network: move
  it to SCRAM-SHA-256, verify it, or allow the method with
  `require_auth=md5`. `require_auth` and `channel_binding` (SCRAM-SHA-256-PLUS,
  used whenever the server offers it over TLS) are new URL parameters.
- PostgreSQL connections are reset when they go back to the pool, so
  session settings, roles, temporary tables and advisory locks from one
  request never reach another (`Options.reset_session`, on; no extra round
  trip). No action needed.
- A CA set in code (`tls.ca` for PostgreSQL and Redis, `Options.tls` for
  MongoDB) can no longer be switched off by the URL or the environment:
  `sslmode=disable|allow|prefer`, `ssl_cert_reqs=none`, `tls=false` and
  `tlsInsecure`/`tlsAllowInvalid*` are refused there, and logged as
  warnings everywhere else.
- The PostgreSQL client checks message lengths and every value of a
  result row before decoding it, refuses `LISTEN` channel names over 63
  bytes, and checks SCRAM's server nonce and iteration count; MongoDB's
  SCRAM caps the iteration count at one million, and Redis refuses replies
  nested deeper than 32 levels. A malformed answer now fails the call and
  closes the connection instead of crashing the process. No action needed.
- A date or time column beyond what `anole.db.Time` holds (PostgreSQL and
  SQLite) fails that read instead of crashing. No action needed.
- SQLite limits expression depth to 1000 again (it was unlimited), and a
  `file:` path is a SQLite URI only with `Options.uri = true` (breaking
  for paths that relied on it; action: set `.uri = true`).
- A database URL whose password holds `/` or `?` no longer shows the
  password in logs, and MongoDB's connection-string errors no longer quote
  parts of the string. No action needed, but percent-encode such
  passwords.
- `exec` with no arguments runs every statement in its SQL (PostgreSQL,
  SQLite); the docs now say so: never build that SQL from input.

#### Process, startup, CI and examples

- With `ServerOptions.process` set, the server keeps systemd's `NOTIFY_SOCKET`
  for itself and takes it out of the environment that programs started by
  handlers inherit (a restart passes it to the new process). Sockets
  inherited through `LISTEN_FDS` are checked to be listening TCP/unix (or,
  for `h3`, UDP) sockets; anything else stops the start with
  `error.InheritedSocketMismatch`. A CPU quota that does not fit 32 bits no
  longer stops the start.
- `anole.panic` (`pub const panic = anole.panic;` in the root file; the
  examples and libanole use it): a panic is written as one error line with
  its stack trace through the log function, then the process aborts. The
  server logs its build mode at start and warns when it is ReleaseFast or
  ReleaseSmall; `addApp` warns at build time for those modes (the build is
  not refused).
- CI: a Release checks workflow runs h2spec, Autobahn, the HTTP/3 checks,
  the QUIC interop runner, gRPC interop and the C ABI suite against
  ReleaseFast builds, and the bundled C libraries under sanitizers, at every
  release tag. Actions are pinned by commit; downloads in the sanitizer
  script and the Python test packages are checked by hash.
- Examples model the safe patterns: `examples/rest` (and the
  getting-started guide) read the API key from `API_KEY`, keep its SHA-256
  and compare in constant time instead of a hard-coded key compared with
  `std.mem.eql`; `examples/observe` serves `/metrics`, the health routes and
  its `/maintenance` switch on a loopback-only admin listener (the next
  port) instead of the public one.

#### C ABI (code new since 0.1.0, listed above under C ABI)

- C ABI: a made-up WebSocket handle, a file length past the end of the file
  (`anole_respond_fd`), and a request body read after the request was
  answered are now refused (`ANOLE_E_GONE` / `ANOLE_E_INVALID`) instead of
  reaching memory they should not. No configuration change needed.
- C ABI: publishes still being fanned out to a topic are bounded (64 per
  executor, and the larger of 16 x `limits.ws_high_water` and
  2 x `limits.ws_max_message` bytes); past that `anole_ws_publish` returns
  `ANOLE_E_AGAIN` and sends nothing. A publish larger than
  `limits.ws_max_message` is refused (`ANOLE_E_INVALID`). Bindings should
  handle `ANOLE_E_AGAIN` from publish. Topics use `Rooms`' per-member
  queues (above), each bounded by `limits.ws_high_water`, so a subscriber
  that stops reading holds up no publish.
- C ABI configuration: `limits.inline_body_max` and `limits.ws_max_message`
  are capped at 1 GiB (larger values are a configuration error).
- C ABI configuration: a `jwt` middleware with `jwks_url` needs `audience`
  (or `allow_any_audience: true` for keys that sign for this application
  alone); without it the configuration is refused.
- C ABI configuration: a fixed (`respond`) route's headers are checked when
  the configuration is read: `Connection` and `Transfer-Encoding` (the
  server's own) and invalid names or values are refused there, instead of
  failing every request to the route.
- C ABI: replies and trailers naming `Connection` or `Transfer-Encoding`
  are refused with `ANOLE_E_INVALID` (the request is still owed), instead
  of those headers being dropped without a word.
- C ABI: WebSocket messages waiting for a consumer are bounded per executor
  in bytes (the larger of 16 x `limits.ws_high_water` and
  2 x `limits.ws_max_message`), not only in count, so clients cannot make a
  slow consumer's queue hold `limits.queue` whole messages.

### Breaking

Each item is described under Security above.

- Server: `res.header`/`res.addHeader` refuse `Transfer-Encoding` and
  `Connection` (use `res.keepalive = false`); HTTP/1.1 requests without
  exactly one `Host` get 400 (`request.require_host = false` restores the
  old behaviour); `X-Forwarded-Host` needs `trust_forwarded_host = true`;
  a malformed request body reads as `error.MalformedBody`.
- `http3.hq_interop_root` needs `pub const anole_hq_interop = true;` in the
  root file.
- TLS 1.2 listeners accept only ECDHE with AES-GCM or ChaCha20-Poly1305.
- HTTP client: URLs with raw spaces, control characters or non-ASCII bytes
  in the path or query fail with `error.InvalidUrl`; a 307/308 that would
  carry the body to another host is not followed. `StreamError` gains
  `HeadersTooLarge` and `TooManyInterimResponses`.
- JSON: `json.Error` gains `NestingTooDeep`.
- gRPC: a call receives at most 64 MiB in all on the server
  (`RegisterOptions.max_received_bytes`) and on the client
  (`Channel.max_received_bytes`); `Call.addTrailer` refuses invalid
  metadata (use `addBinaryTrailer` for raw bytes); transcoded bindings with
  a `body` answer 415 to a non-JSON `Content-Type`.
- WebSocket and WebTransport: handshakes from another origin get 403 unless
  listed in `allowed_origins`; `Rooms.broadcast` returns the number of
  members it queued for.
- Sessions: signed session cookies from 0.1.0 are refused (users sign in
  again); `cookie_opts` is now `SessionCookieOpts`; custom session stores
  should implement `Store.VTable.update` and `touch`.
- Auth: a JWKS `Keyring` policy needs an `audience` (or
  `allow_any_audience = true`); OIDC discovery refuses non-`https`
  endpoints; `apikey.generate` can return `error.EntropyUnavailable`;
  rate-limit keys of IPv6 clients are their /64.
- Logs: access logs leave the query string out unless `log_query = true`;
  incoming request IDs outside `[A-Za-z0-9._:-]` are replaced.
- Databases: PostgreSQL defaults to `sslmode=verify-full` for remote servers
  and sends clear-text or MD5 passwords only to a verified or local server;
  SQLite treats `file:` paths as URIs only with `Options.uri = true`.
- `examples/rest` reads its API key from the `API_KEY` environment variable.

### C ABI (ABI 0.1)

- `libanole`, Anole as a C library for the language bindings
  ([docs/c-abi.md](docs/c-abi.md)): `include/anole.h`, `zig build capi`
  (`libanole.a`, one object with every bundled C library and only `anole_*`
  exported, packed with Zig alone; `libanole.{so,dylib}`; `anole.dll` on
  Windows). A JSON configuration (`include/anole.schema.json`) sets
  listeners, limits, native routes (fixed answers, static files, the
  response cache, health and metrics) and middleware (request ID, access
  log, compression, CORS, JWT, rate limiting); consumer routes hand requests
  to a consumer thread that polls batches of events and answers by
  generation-checked handle: whole responses (copied or borrowed), files,
  streams with trailers, request bodies read without blocking, WebSockets
  with topics. Deadlines, aborts and lost wakes are Anole's to handle.
- Detached responses in the HTTP core: an HTTP/2 or HTTP/3 request that
  arrived whole is answered later with no task waiting
  (`Response.detach`); middleware opts in with `detach_safe` (every
  built-in one that runs before the handler does). The request and response
  stay on the reader's stack unless the handler detaches. On h2c a consumer
  route serves 2.0x the requests per second at one executor and 1.48x at
  four (M2 Pro, local).

### Server

- Listeners on every interface without a family are dual-stack (#57):
  `listen(":3000")`, `listenTls(":443", ...)` and `address = ""` in the
  options bind one socket on `::` with `IPV6_V6ONLY` off, taking IPv6 and
  IPv4 clients alike, and their HTTP/3 endpoint follows (a QUIC client that
  resolves `localhost` to `::1` without falling back now connects). So do
  the per-core `SO_REUSEPORT` sockets, the per-core HTTP/3 sockets and their
  connection-ID steering, and the sockets a SIGUSR2 restart opens. Where the
  system has no IPv6 (or on Windows) they bind `0.0.0.0`. An explicit
  `"0.0.0.0"` stays IPv4 only and `"::"` keeps the system's default.
  Breaking: `":3000"` meant `0.0.0.0` before.
- IPv4-mapped client addresses (`::ffff:127.0.0.1`) are reported as plain
  IPv4 in `req.remote_address`, from the socket, `X-Forwarded-For` and the
  PROXY protocol alike, so logs and rate-limit keys see one client one way.
  `anole.http.unmapIpv4` does the same for other addresses.
- `http.Listener.ipv6_only` and `anole.http.listenIp` set `IPV6_V6ONLY` on
  a listener of your own; `checkAddressFree` takes it as a second argument.

### Databases

- `.cache = .{ .ttl, .keep_empty = false }` serves an empty result without
  keeping it (#58): `optional`'s null (a Redis nil) and `all`'s zero rows,
  so cache-aside sees the value as soon as the store is filled, with no
  `invalidateQuery` per miss. The default (`true`) keeps them as before.
- `anole.db.lastSource(req)` says where the last `.cache` or `.coalesce`
  call made with the request got its answer: `.cache`, `.coalesced` or
  `.database` (for an `X-Cache: HIT|MISS` header). A `*anole.db.Ctx` keeps
  it in `last_source`.

### Windows, as a development target

- `zig build -Dtarget=x86_64-windows` builds the library, the examples and
  the tests with every feature, and a `windows` CI job runs `zig build test`
  on Windows, and examples/hello and examples/full serve requests there
  (HTTP/1.1, h2c, HTTPS with HTTP/2). The `cross` job also
  builds every preset and edge flag combination for x86_64-windows.
- BoringSSL builds without its assembly there (NASM syntax), nghttp2,
  ngtcp2, nghttp3, zlib-ng, zstd, Brotli and hiredis get their Windows
  settings, and ngtcp2 uses its own socket address types
  (`NGTCP2_USE_GENERIC_SOCKADDR`), since mingw's `sockaddr_in6` does not
  translate.
- Compiled out on Windows: per-core `SO_REUSEPORT` sockets, HTTP/3
  connection-ID steering, UDP batching and control messages (ECN,
  `IP_PKTINFO`), listener hand-off and SIGUSR2, SIGHUP reloads,
  `LISTEN_FDS`, `sd_notify` and idle parking. Ctrl-C drains the server.
  Tests of those parts are skipped there with the reason. See
  [docs/server.md](docs/server.md#windows).
- Listeners on Windows bind without `SO_REUSEADDR`, which there would let
  another socket take a port in use.
- The examples read their arguments with `args.iterateAllocator`, which
  works on Windows too.

## 0.1.0 (2026-10-21)

The first release: one server core for REST, WebSockets, gRPC and
WebTransport over HTTP/1.1, HTTP/2 and HTTP/3, with TLS, auth, database
connectors and observability, on Zig 0.17 for macOS and Linux.

### The HTTP core is Anole code

- The HTTP/1.1 server, router, middleware, client, WebSocket and HTTP/2
  engine, which came from lalinsky/dusty through Anole's fork, now live in
  `src/http/core` (MIT, attributed in every file and in THIRD_PARTY_NOTICES).
  Anole no longer fetches a `dusty` package. `anole.http` is the core, and
  `anole.http.core` the whole core module for what it does not re-export.
- Its tests run in `zig build test` (`zig build dusty-test` is gone; `zig
  build core-test` runs them alone), on a certificate made at build time
  instead of a committed key, and its fuzz targets run with Anole's under
  `zig build test --fuzz`.
- The fork's vendored nghttp2 1.69.0 copy is dropped (Anole always built its
  own nghttp2), and llhttp is compiled once instead of once per feature
  combination.

### Server

- Memory per connection: each task's stack reserves 1 MiB by default
  (`Options.max_stack_size`, was zio's 8 MiB), about 2 KiB of page tables
  per open connection instead of 4. An idle TLS connection holds no
  ciphertext buffer (a 1 KiB stash, blocks borrowed from a per-thread pool
  while records are in flight) and BoringSSL sheds its handshake
  configuration: about 20 KB per idle TLS connection instead of 29 on Linux.
  The request-buffer pool gives back, every 5 s, the sets a burst of
  connections left unused, and a WebSocket's reply batching shares one
  backstop task per executor instead of one per socket: a busy pipelining
  WebSocket holds about 34 KB instead of 43.
- Idle connections park: an HTTP/1.1 connection that has had nothing to
  read for `timeout.idle_park` (1 s, null turns it off) ends its coroutine
  and waits as a heap object whose socket its executor watches (a readiness
  poll in a zio `CompletionQueue` that one driver task per executor owns);
  its next request starts a coroutine on the same executor. Keep-alive deadlines, the drain and the stop cover parked
  connections. `app.wsCallbacks(path, Callbacks)` serves a WebSocket
  through `open`/`message`/`close` callbacks, and over HTTP/1.1 such a
  socket parks the same way between messages (`Response.adopt` in the
  HTTP core hands the connection over to it after the handshake).
- A request waiting in its handler holds about 6 KB instead of 14: its
  head, its arena's first chunk and the set's header share one page (sets
  are carved page-aligned from slabs; a trimmed one gives its pages back
  and is reused), the request's and the response's header tables start at
  16 entries and grow to their limits, a buffered body's first segment is
  taken when the body is written, and the write buffer comes from a pool of
  its own at the response's first write and goes back once it is out. What
  a request takes from its arena beyond the set's 10 KB goes back when it
  ends rather than staying with the set. `res.addHeader` adds a header
  that may repeat (`Vary`); adding to `res.headers` directly is limited to
  its current room.
- A WebSocket holds less (cgroup per socket, 10k sockets, Linux): an
  upgraded HTTP/1.1 connection keeps one page of its request (the head the
  handler can still read, beside the arena's first chunk) and reads frames
  into the rest of that page; its writer borrows a pooled buffer only
  while it has frames waiting (a small frame sent at once is built on the
  stack), so a quiet or echoing socket holds none. A callback socket gives
  its request buffers back right after the handshake instead of when it
  first parks. A `ws.next()` socket 32 to 22 KB idle or busy (TLS 37 to
  27); a callback socket 36 to 18.5 KB during a connect burst, 22 to 15 KB
  busy, 7.8 to 3.9 KB parked. Over HTTP/2 and HTTP/3 a socket's two frame
  buffers are 4 KB each instead of 16.
- `anole.App` (`Server(void)` with `init(gpa, options)`) and `app.listen(":3000")`
  / `app.listenTls(":443", .fromFiles("cert.pem", "key.pem"))` in Go's address
  notation (`":3000"` is every interface). `listenTls` adds HTTP/3 with
  `Alt-Svc` when it is built in (`Options.listen_tls_http3`). Without
  `http`/`https` in the options, the listeners are set up by `listen`,
  `listenTls` or `run`, hand-off, `sd_notify` and `waitReady` included.
  `anole.Cert.fromFiles` / `fromPem`.
- Several listeners: `Options.listeners`, beside `http` and `https`, each
  with its own address or unix socket, TLS certificate (listeners naming the
  same one share it), protocols (`http1`, `http2`: ALPN over TLS, h2c on
  cleartext; `http3` on one TLS listener) and name. One process can serve
  e.g. HTTP/1.1 + h2c, TLS HTTP/1.1 only, h2c only and TLS h2 + HTTP/3 on
  four ports. Names go into `LISTEN_FDNAMES` for socket activation and
  SIGUSR2 restarts, and to handlers as `req.listener.name`;
  `anole.onlyOn(name)` keeps a group's routes to one listener (an admin
  port). Certificate reloads cover every TLS listener, all or none.
  `Alt-Svc` now goes out only on the TLS listener HTTP/3 serves the port of
  (no longer on cleartext responses, where browsers ignore it). The HTTP
  core's `Listener` gains `http1` (off: HTTP/2 only) and `name`.
- The open-file limit: `init` raises the soft RLIMIT_NOFILE to the hard one
  (as Go does; `Options.raise_fd_limit`), and `max_connections` defaults to
  what that limit allows less a reserve for other descriptors (64, 8 per
  executor, the listening sockets, and an eighth of the limit), instead of
  10,000. An explicit `max_connections` still wins; 10,000 on Windows.
  `anole.http.fd_limit`.
- One line per subsystem, owned by the server: `app.grpc(pb.Service,
  handlers)` (a struct literal, a namespace, or methods on a value; gRPC,
  gRPC-Web, Connect and transcoded routes), `grpcHealth()` (NOT_SERVING on
  drain), `metrics(.{})`, `health(.{})`, `tracing(.{})`,
  `staticDir(prefix, path, .{})` and `ws(path, handler)`.
- Plain `(req, res)` handlers on a `Server(App)`; function middleware
  (`fn (req, res, next: anole.Next) !void`, or `anole.func(f)`) in `use`,
  `group` and the new `with` (middleware for some routes, no prefix).
- `anole.noWait(handler)` marks a handler (and its route's middleware) as
  never waiting: on HTTP/2 its whole requests run on the connection's reader
  without a task, the responses to one read in one write; on HTTP/3 on the
  endpoint task, right after the packet that completes them. gRPC takes it per
  registration: `app.grpcWith(Service, impl, .{ .no_wait = true })` for
  unary methods.
- `anole.client(req)` / `app.client()`: the server's pooled outbound HTTP
  client, with inline headers and `response.json(T, allocator)`.
- `anole.Server(Ctx)`: one call sets up the zio runtime (one pinned executor
  per core, connections never leave the core that accepted them), the
  listeners, SIGINT/SIGTERM handling and a graceful drain with a hard
  deadline.
- HTTP/1.1 on the HTTP core: a segment-trie router with path parameters
  and wildcards, nested groups, middleware, keep-alive and pipelining,
  per-phase timeouts and body limits, static files with ranges, ETags and
  precompressed variants, and no allocation per request on a warm
  connection.
- HTTP/2 on nghttp2 1.70.0 (with an RFC 9113 strictness patch), over TLS
  through ALPN and over cleartext with prior knowledge, on the same router;
  streaming bodies, trailers, two-phase GOAWAY on drain. A client's
  RST_STREAM, or a lost connection, cancels the stream's handler. h2spec
  passes every case in strict mode, over h2c and TLS.
- HTTP/3 on ngtcp2 1.25.0 (from Anole's fork xuckless/ngtcp2, see the
  migration entry) and nghttp3 1.18.0 (from Anole's fork xuckless/nghttp3,
  which can send the SETTINGS WebTransport needs): the same handlers over QUIC,
  `Alt-Svc`, Retry, stateless reset, QUIC v2, ECN, PKTINFO, GSO and GRO on
  Linux, per-request timeouts, a GOAWAY drain and mutual TLS. The QUIC interop runner
  passes every server case it was given against ngtcp2's and quic-go's
  clients. Breaking: `http3.idle_timeout_ms` is `http3.idle_timeout`, a
  `std.Io.Duration` (30 s by default), as the HTTP/3 client's is.
- HTTP/3 0-RTT, opt-in (`http3.early_data`), after RFC 8470: GET, HEAD and
  OPTIONS from early data run at once, marked `Early-Data: 1`; other methods
  wait for the handshake, which a replay never completes.
  `anole.early_data.TooEarly` answers 425 on routes that want no early data
  at all, and with HTTP/3 on every route answers 425 to unsafe requests a
  proxy marked `Early-Data` (`anole.early_data.Guard`). Session resumption works without
  it. The interop runner's `resumption` and `zerortt` cases pass.
- HTTP/3 connection migration: clients may move to a new address or port;
  the server validates the path, answers on it (closing included), hands
  out a new token when the IP address changed, and reports the new address
  to handlers. The ngtcp2 fork fixes a migration right after a NAT
  rebinding, which stock 1.25.0 closed with CONNECTION_ID_LIMIT_ERROR.
- HTTP/3 handshakes under loss: a server PTO retransmits both Initial
  packets of a ServerHello that needs two (a post-quantum key share), so a
  client that lost the second is not sent the first again and again (an
  ngtcp2 fork patch).
- HTTP/3 on every core on Linux: one SO_REUSEPORT UDP socket and endpoint
  per executor (`http3.sockets`, one per executor by default; macOS keeps
  one). The server's connection IDs name their endpoint in one byte, and a
  classic BPF program on the socket group (Linux 4.5+) steers each datagram
  to its connection's socket, across migrations too; a datagram that lands
  on another endpoint's socket all the same is passed on to its owner and
  handled there. Endpoints share one TLS context (tickets and 0-RTT work on
  any core), the token and stateless-reset key, and the drain. The UDP port
  is probed before the group binds, as TCP's is, and a SIGUSR2 restart hands
  every socket over in order.
- WebTransport over HTTP/3, draft-02 (what Chrome, Edge and Firefox speak):
  `app.webtransport(path, handler)` or `anole.webtransport.accept` give a
  session with streams both ways in either direction, datagrams (RFC 9297),
  `close(code, reason)` and a drain (DRAIN_WEBTRANSPORT_SESSION, then a
  close). The HTTP/3 client opens sessions too (`openWebTransport`).
  Checked against aioquic both ways, and in the interop runner's
  WebTransport mode against flupke (all seven cases); the browser images
  have not been run yet. A session ends only through its CONNECT stream's
  reader, so a peer that closes its session and then its connection at
  once counts as `.peer`, with its code, in `closeInfo()`.
- TLS through BoringSSL, built from source by Zig: TLS 1.3 and 1.2, ALPN,
  mutual TLS (with the acceptable CAs named in the request, and the client's
  certificate for handlers through `req.peerCertificate()` on HTTP/1.1,
  HTTP/2 and HTTP/3), stateless session tickets, close_notify on graceful closes, and a development
  certificate generated in memory (`.dev_self_signed`).
- Certificate reload without a restart: `Server.reloadCertificates()`, also
  on SIGHUP, and `Server.setCertificate(cert)` for new PEM or files. The
  HTTPS listener and HTTP/3 switch together; connections already open keep
  their certificate, session tickets from before still resume, and a reload
  that fails changes nothing.
- Response compression with zstd or gzip (zlib-ng) by the client's q-values,
  and compressed request bodies.
- Brotli responses (`Content-Encoding: br`, google/brotli 1.2.0) with
  `-Dbrotli`, on in `web` and `full`: the Compress middleware and
  `res.compress` pick `br` by the client's q-values, after zstd and before
  gzip on a tie (`Accept-Encoding: gzip, br` gets `br`). Buffered and
  streamed bodies, flushes included. Quality 5 by default
  (`ServerConfig.response.brotli_quality`, `res.brotli_quality`): 10-15%
  smaller than gzip on JSON of a few KB. The encoder's large blocks, and
  zlib-ng's deflate state for a buffered gzip body, are cached per executor
  (at most 4 MiB, trimmed when idle) instead of mapped and unmapped per
  response or kept in each connection's arena. Precompressed `.br` files
  are served as before.
- The PROXY protocol (v1 and v2) and `X-Forwarded-*` from trusted proxies.
- Zero-downtime restart on SIGUSR2 (the new process inherits the listening
  sockets, HTTP/3's UDP sockets included; HTTP/3 connections are closed and
  reconnect), systemd socket activation, and systemd's readiness protocol
  (`READY=1`, `RELOADING=1`, `MAINPID=`, `STOPPING=1`) without libsystemd.
- `anole.Server` conveniences: `static`, `embedded` and `query` routes;
  `group(prefix, .{ ... })` and `use` copy their middleware and the server
  calls its `deinit`; `middleware(value)` for one copy shared by several
  groups. `Options.http` defaults to none when `https` is set (HTTP on
  127.0.0.1:8080 only when neither is). Anole's zio defaults to pinned
  scheduling, so `zio_options` is optional, and declaring work stealing is a
  compile error. A second `Server` on a thread that has one fails with
  `error.ServerAlreadyOnThread` instead of an assertion in zio.
  `Server.waitReady` returns `run`'s error when the server stops before it
  is listening (a certificate that will not load, a port in use) instead of
  waiting for good; a restarted process tells its predecessor it is serving
  only once it really is.
- A response can carry 64 headers (`response.max_header_count`), no longer
  capped by the request's `max_header_count` (32).
- An opt-in blocking pool (`Options.blocking`, `anole.blocking.run`):
  CPU-heavy or blocking calls run on zio's thread pool, capped at a set
  number at once, while the request's executor goes on serving.

### Handlers, errors, JSON and CORS

- Errors that carry a status: a handler or middleware returns
  `error.Unauthorized` for a 401, `error.TooManyRequests` for a 429,
  `error.ServiceUnavailable` for a 503; any standard 4xx or 5xx counts, by
  its `std.http.Status` tag in PascalCase or its RFC 9110 phrase.
  `anole.errorStatus(err)` says which.
- `res.fail(status, message)`: the status and a body in place of anything
  written before, `{"error":"..."}` for a request that takes JSON and text
  otherwise. `Options.errors` (`.auto`, `.json`, `.text`) sets that for the
  whole server, the server's own 404, 405 and error answers included.
- `Options.error_handler`, a plain function that answers handler errors
  without a `Ctx`, and `anole.defaultError(req, res, err)`, the default
  answer, for it or an `uncaughtError` to fall back on.
- `req.param(name)` and `req.queryParam(name)`: a path parameter and a
  query-string value by name (short for `req.params.get` and
  `req.query.get`).
- `req.bind(T)`: the JSON body as a `T` in the request's arena, unknown
  fields ignored, 400 when it is missing (`error.MissingBody`) or does not
  fit (`error.InvalidJsonBody`); `req.bindWith(T, options)` takes
  `std.json`'s options. `res.json(value)`; `res.jsonWith(value, options)`.
  `anole.json.readBody` keeps the same contract on yyjson.
- Request locals: `req.setLocal(key, value)` and `req.local(T, key)`, typed
  values a middleware hands to the handler. `anole.auth.claims(req)`,
  `anole.auth.subject(req)` and `anole.auth.apikey.owner(req)` read what
  `RequireJwt` and the API key middleware verified.
- `anole.middleware.Cors.init(.{})` works out of the box: any origin, the
  common methods, the request headers the browser asks for, a 600 s max
  age. Origin lists (echoed with `Vary: Origin`), `credentials` (refused
  with every origin allowed), `expose`. A `Cors` inside a group answers the
  preflights for the group's routes: an `OPTIONS` to a path whose routes are
  for other methods runs the middleware of the route it asks about.
- A port another process already listens on is `error.AddressInUse`, logged
  with the address, rather than shared through `SO_REUSEPORT`; connections
  in `TIME_WAIT` do not count, and inherited sockets are not checked.
- Startup and logs: one line per listener as it starts, with its scheme and
  protocols (`listening on https://127.0.0.1:8443 (HTTP/2, HTTP/1.1,
  HTTP/3)`); the HTTP core logs under `anole`, `access` and `anole_h2`
  itself, so `anole.logFn` is no longer needed; no per-request debug line;
  `anole.std_options` quiets zio's thread lines and Anole's debug lines; a
  TLS file that cannot be read is logged with its path. `zio_options` is
  gone from the quick start (it was already optional).
- Breaking:
  - `std.json`'s error names (`SyntaxError`, `UnknownField`, `MissingField`
    and the rest) are no longer answered 400: JSON that fails to parse
    anywhere but the request body is a 500. The body helpers (`bind`,
    `json`, `jsonValue`, `anole.json.readBody`) fail with
    `error.InvalidJsonBody` instead, and `bind` and `readBody` with
    `error.MissingBody` for no body. An `uncaughtError` that matched the old
    names should match these.
  - `req.json(T)` ignores unknown fields, as `bind` does.
  - `res.json(value, options)` is `res.jsonWith(value, options)`;
    `res.json(value)` takes no options.
  - `Cors.init` no longer returns an error union (drop the `try`), `origin`
    is optional, and `max_age` is a number of seconds (`?u32`, 600 by
    default) instead of a string.
  - An `OPTIONS` request to a path with routes for other methods runs that
    route's group middleware before the 405.
  - The HTTP core's log scopes are `anole` (was `dusty`), `access` (was
    `dusty_access`) and `anole_h2` (was `dusty_h2`); a `log_scope_levels`
    entry naming `.dusty` should name `.anole`.
- A response cache: `anole.cached(.{ .ttl }, handler)` for one route, or
  `app.responseCache(.{})` (`anole.middleware.ResponseCache`) for several
  through `with`, `group` or `use`. Answers to `GET` (and `HEAD` from a
  kept `GET`) with a cacheable status and a body in memory are kept per
  executor and served without running the handler; never one that sets a
  cookie or says `no-store`, `no-cache` or `private`, and not for requests
  that carry credentials unless `.authenticated`. `Cache-Control`'s
  `s-maxage` or `max-age` sets how long, `Vary` is honoured, and
  `invalidate(.all)` or `.{ .path }` reaches every executor at once.

### WebSockets

- RFC 6455 over HTTP/1.1, RFC 8441 over HTTP/2 and RFC 9220 over HTTP/3
  behind one `anole.websocket.upgrade`, permessage-deflate, and a rooms
  helper for broadcast. Autobahn passes every case; RFC 9220 is checked
  against aioquic's client.
- A receive that fails on the client's account sends the matching close
  code first (1009, 1007 or 1002) on every HTTP version.
- A drain closes open sockets with 1001 (going away) and ends them as soon
  as their clients answer, rather than at `timeout.shutdown`;
  `Socket.draining()` tells handlers why, `close_on_drain = false` leaves it
  to them, and `req.drain` lets any long-lived handler watch for the drain.
- `Rooms.broadcast` sends outside the lock: a slow member holds up only the
  broadcasts that include it.
- RFC 8441 and RFC 9220 sockets are logged, measured and traced as 101,
  like HTTP/1.1 upgrades.
- `app.ws(path, handler)` with `Socket.next()` (text and binary messages,
  null on close): an echo endpoint is one loop; a plain request gets 426.
- Breaking: `Rooms.init(allocator)` takes no `Io` (it comes from the first
  socket to join), so the rooms can be made before the server.

### gRPC

- Server and client over HTTP/2: all four call modes, deadlines, metadata,
  status in trailers, gzip, and handlers canceled when the client resets the
  call. grpc-go's interop client passes 14/14 cases against Anole and Anole's
  client 11/11 against grpc-go, each over h2c and TLS; grpc's
  `tools/http2_interop` server checks run too.
- Responses are gzipped only when the request was (grpc-go's rule);
  `RegisterOptions.response_compression` = `.accepted` gzips whenever the
  client accepts it, `.never` never.
- `registerWith` options per registration: the request message limit
  (`default_max_message_size`, 4 MiB, by default) and data for the handlers.
  A handler's own error reaches the client as UNKNOWN "Application error
  processing RPC" and is logged on the server, rather than sent by name.
  `Call.addHeader` returns `error.HeadersSent` once the response has started.
  `Call.requestCompression()`, `protocol()` and `codec()` say how a call
  came in; the server's own state is in `call.impl`, not part of the API.
  `anole.grpc.Status` and `Code` are the one place for statuses.
- gRPC-Web and Buf's Connect protocol on the same routes, including Connect's
  GET form for methods marked `NO_SIDE_EFFECTS`, and the `grpc.health.v1`
  service (`anole.grpc.Health`, one registry per instance).
- JSON transcoding from `google.api.http` annotations: the same
  registration adds REST routes (`get`/`put`/`post`/`delete`/`patch`,
  `custom`, `additional_bindings`), with the full path template syntax
  (`{field=a/*/b}`, `**`, nested fields, `:verb`), `body` (`*` or a field)
  with the rest from query parameters, `response_body`, errors as
  google.rpc.Status JSON under the matching HTTP status, and a server
  stream as one JSON array sent element by element. JSON through
  zig-protobuf's generated proto3 mapping. `RegisterOptions.transcode =
  false` leaves the routes out.
- Connect's JSON writes a oneof's member as a field of the message, as
  protojson does; it was nested under the oneof's name.
- The tasks of a streaming call run on the stream's own executor.
- `addProtoGen` for an application's build.zig: protoc and the Zig generator
  are pinned and built by `zig build`, nothing to install;
  `google/api/annotations.proto` and `http.proto` come with Anole.
- `addApp(b, .{ .name, .root_source_file, .protos })` makes an application's
  build.zig one call, and `addProtoModule` generates a `.proto`'s module in
  the cache as part of `zig build` (no separate step, nothing committed).

### Clients

- Outbound HTTP/1.1 and HTTPS (the HTTP core's client on BoringSSL), an
  HTTP/2 client and an HTTP/3 client, usable from handlers through `req.io`.
  The HTTP core's client speaks HTTP/2 too when a server picks it
  (`ClientConfig.http2 = true`).
- One set of TLS options for all three: the system trust store by default
  (loaded once), a CA file, directory or PEM in memory, client certificates
  for mutual TLS from files or memory, and
  `insecure_skip_verify` for tests.
- The HTTP/2 and HTTP/3 clients share their names (`ClientConnection`,
  `Stream`, `Header`, `ConnectOptions`, `RequestOptions`, `StreamError`,
  `version()`), a `connect_timeout` and a per-request `timeout` that ends in
  `error.Timeout`, and options of one name and type where they mean the
  same (`stream_window` and `max_data`, both `u31`; the stream window's
  default is 64 KiB over HTTP/2, which allocates it per stream, and 256 KiB
  over HTTP/3). Options only one protocol has say so: HTTP/2's optional
  `tls` (h2c without it) and `body_bytes`, HTTP/3's `idle_timeout` (a
  `std.Io.Duration`), `session_cache`, `early_data`, `webtransport` and
  `early`. `Stream.readError()` and `writeError()` say what a `ReadFailed`
  or `WriteFailed` was.
- Breaking: their `tls.root_ca` bundle is now `tls.ca` (an
  `anole.http.TlsCa`, the system store by default, where it trusted nothing
  before); `tls.certificate = .{ .cert_pem, .key_pem }` is
  `tls.client_certificate`, the HTTP core's shape (`.pem = .{ .cert, .key }` or
  `cert_path`/`key_path`); the HTTP/3 client's `handshake_timeout_ms` is
  `connect_timeout`.
- The HTTP/3 client resumes sessions from an `anole.h3.SessionCache`, sends
  0-RTT when asked (`early_data`), and sends again what a server refused in
  early data; `rebind` moves a connection to a new socket (a migration).

### Auth, state and limits

- JWS/JWT verification with one pinned algorithm per key (an HMAC secret
  shorter than its hash verifies nothing, `error.WeakKey`) and JWKS
  keyrings that fetch outside their lock, one fetch at a time; a bearer-token
  middleware (`anole.auth.RequireJwt`) with RFC 6750 errors, scopes and
  required claims (`required_claims`, `sub` by default), the verified token
  handed to the handler through the request's locals (`claims`, `subject`),
  never through the session; OIDC sign-in as a relying party (PKCE, Google
  and Apple presets); CSRF tokens; Argon2id passwords, hashed on the
  blocking pool when there is one; API keys from `X-API-Key` or
  `Authorization: Bearer ak_...` (the prefix tells them from JWTs), their
  owner in the locals (`apikey.owner`); RBAC with roles from the
  application's state.
- The clients these use are the server's: `Keyring.init(gpa, io, client,
  url)`, `oidc.Provider.discover(gpa, client, issuer)`,
  `RelyingParty.finish(arena, io, client, ...)` and
  `observe.trace.Exporter.init(gpa, io, client, options)` take the
  `anole.Client` that `app.client()` and `anole.client(req)` return.
- Sessions in memory or Redis/Valkey, and sealed cookie sessions
  (`anole.session.Middleware`, the one session middleware;
  `anole.middleware` has none); `anole.session.regenerate` issues a new
  session ID at sign-in. A cookie session needs a key: `Middleware.init`
  returns `error.SessionKeyMissing` for none or all zeros, there is no
  default. `anole.session.keyFromBase64` reads one from configuration, and
  `devKey(io)` makes a random one for development, with a warning. The
  HTTP core's signed-cookie session (`anole.http.middleware.Session`)
  refuses keys shorter than 32 bytes (`error.WeakSessionKey`).
- Rate limiting with token buckets in memory or Redis and a 429 middleware:
  `ratelimit.Middleware.init(limiter, .{ .limit, .window_ms, .burst, .key,
  .on_error })`, counting by client address unless `.key` says otherwise,
  and letting requests through (`.allow`, the default) or answering 503
  (`.deny`) when the limiter's store fails.
- `RedisStore` and `RedisLimiter` run on the Redis connector's pools
  (`app.redis`), with their options as before.
- JSON on yyjson.

### Databases

- One shape for every connector (`anole.db`, docs/database.md): the
  handle is each connector's `Client` (`anole.pg.Client`,
  `anole.sqlite.Client`, `anole.mongodb.Client`, `anole.redis.Client`) and
  lives in the App state, every call takes the request first (an
  `anole.db.Ctx` outside a handler), rows come back as your structs in the
  request's arena, nothing to free, and calls fail with the connector's
  `Error`. The verbs are shared, and a verb means the same thing in every
  connector: `exec` (rows changed), `one`, `optional`, `all`, `iterate`,
  `begin` (a `Tx` whose `commit(req)` and `rollback(req)` take the request
  like every other call), `transaction`, `acquire`, and
  `with(.{ .timeout, .prepare, .coalesce, .cache })` for options per call;
  each connector has the ones its database can do. A pool per
  executor, the connection limit split between them, so no lock is shared
  between threads. A request's deadline, a client gone or an HTTP/2 reset
  cancels its query (PostgreSQL is sent a CancelRequest, SQLite's statement
  is interrupted, a MongoDB or Redis connection is closed).
- Errors are statuses: `NotFound` 404, `Conflict` 409 (unique and
  exclusion violations, serialization failures and deadlocks),
  `ServiceUnavailable` 503, `GatewayTimeout` 504, anything else `Database`
  500. What the database said stays in the log and in
  `anole.db.lastError(req)`, never in the response; `.errors`
  (`anole.db.ErrorMap`) moves a class to another status, such as foreign
  keys to 422.
- Each connector reports to what the app has, in any order: `anole_db_*`
  metrics labelled `system` and `db` (`app.metrics`), a client span per
  call with OpenTelemetry's `db.*` attributes (`app.tracing`), and a check
  behind `/readyz` (`app.health`). The server closes it after the drain.
  `anole.db.Time` is a timestamp that reads and writes RFC 3339 in JSON.
- PostgreSQL (`-Dpostgres`, on in `web` and `full`; `anole.pg`,
  `app.postgres(.{})`): on Anole's fork of pg.zig, with TLS on BoringSSL
  (libpq's `sslmode`s, `sslnegotiation=direct`, client certificates). The
  connection comes from `.url`, `DATABASE_URL` or libpq's `PG*` variables.
  Statements are prepared once per connection and kept; a canceled call
  sends a CancelRequest; `transaction` runs again after a serialization
  failure or a deadlock; `listener()` opens a connection for
  `LISTEN`/`NOTIFY`. Checked against postgres:17 with scram-sha-256, in
  plain text and with `sslmode=verify-full`.
- SQLite (`-Dsqlite`, on in `web` and `full`; `anole.sqlite`,
  `app.sqlite("app.db")`): the 3.54.1 amalgamation compiled in, through
  Anole's fork of zig-sqlite. One writer thread per database owns the
  read-write connection; reads run on the blocking pool over read-only
  connections in WAL mode, and a read that turns out to write moves to the
  writer. `:memory:` is one database for the whole app. A cancel or a
  timeout interrupts the running statement, and `transaction` retries past
  `SQLITE_BUSY`. `app.sqlite` starts the blocking pool when the app has
  none.
- MongoDB (`-Dmongodb`, on in `full`; `anole.mongodb`, `app.mongodb(.{})`):
  Anole's own client on `std.Io`, written to MongoDB's driver
  specifications: OP_MSG, SCRAM-SHA-256 and SCRAM-SHA-1 (PLAIN and X.509
  too), the connection string (`MONGODB_URI`), server discovery and
  monitoring with primary selection, pools per executor, implicit
  sessions, retryable reads and writes, and TLS on BoringSSL. The calls
  are the official drivers', with the request first (`find`, `findOne`,
  `insertOne`, `updateMany`, `findOneAndUpdate`, `aggregate`, cursors,
  counts, `distinct`, indexes, `runCommand`), with filters, updates and
  pipelines as Zig literals; `one`, `optional` and `all` are `findOne`,
  `findOptional` and `find` under the shared names, and `with` takes the
  shared options on the client, a database or a collection. MongoDB 4.2 and later. CI runs 7.0 on
  ubuntu-latest, and 8.0 and 9.0 on ubuntu-22.04 only: they do not run on
  Linux kernels from 6.19 to 7.0.13 (SERVER-121912, SERVER-125742).
- BSON (`anole.bson`, with `-Dmongodb`): documents checked once and then
  read in place, a builder, struct mapping at compile time, Decimal128,
  ObjectId and Extended JSON v2. The BSON corpus of
  mongodb/specifications passes with no case skipped.
- Redis and Valkey (`-Dredis`, on in `full`; `anole.redis`,
  `app.redis(.{})`) on the same shape: `command`, `one`/`optional`/`all`
  into your types, `pipeline`, `acquire` for WATCH and MULTI,
  `subscribe`/`psubscribe` on a connection of their own that ends on the
  drain, and helpers for strings, hashes (into and from structs), lists,
  sets, sorted sets and `publish`. The URL as go-redis and redis-py read
  it (`REDIS_URL`): `redis://`, `rediss://` (TLS on BoringSSL), `unix://`,
  ACL users, the database to SELECT. hiredis only parses the replies.
- Opt-in caches for reads, off unless a call asks, so a plain call costs
  nothing extra: `with(.{ .coalesce = true })` makes identical reads in
  flight on one executor share one round trip, each caller with its own
  deadline and its own copy of the rows; `with(.{ .cache = .{ .ttl, .tag
  } })` keeps a result per executor for `ttl`. `cache.invalidate(.all)`,
  `.invalidate(.{ .tag })` and `.invalidateQuery(sql, args)` reach every
  executor at once, a statement still running included. Bounded per
  connector (`Options.cache`), with `anole_cache_*` metrics.
- `anole.net.ClientStream`: the plain or TLS client socket the connectors
  share (TCP or a Unix socket, `startTls` for PostgreSQL's SSLRequest).
- `anole.blocking.runWith(io, .{ .on_cancel = ... }, func, args)`: a hook
  called when the waiting caller is canceled while its job runs (SQLite
  interrupts the statement there); a job whose caller was canceled before
  it started no longer starts.

### Observability

- Prometheus `/metrics`, OpenTelemetry traces (W3C `traceparent`, OTLP/HTTP
  export), JSON or text access logs with request and trace IDs, `/healthz`
  and `/readyz`, and one consistent log output under Anole's own scopes.
- `Registry` and `Health` are values the application owns, each serving its
  own server, so one process can run several servers.
- An `exclude` list on the access log, HTTP metrics and tracing middleware
  keeps paths such as `anole.observe.probe_paths` (`/healthz`, `/readyz`,
  `/metrics`) out.
- Histogram sums are exact floats (seconds for durations, from
  nanoseconds), and bucket bounds are checked. `/readyz` answers 503 to
  anything still routed during a drain. `Exporter.deinit` returns without
  waiting out `interval_ms`.
- A metric registered twice under one name is one metric: `Registry`'s
  `counter`, `gauge` and `histogram` return the family already there.
- Breaking: `HttpMetrics.init` takes options, and `statusOf` the request.

### Build

- Every bundled library sits behind a build flag (`-Dtls`, `-Dhttp2`,
  `-Dhttp3`, `-Dgrpc`, `-Dwebsocket`, `-Dauth`, `-Dcompression`, `-Dbrotli`,
  `-Djson`, `-Dredis`, `-Dpostgres`, `-Dsqlite`, `-Dmongodb`) and presets
  (`-Dprofile=minimal|web|full`); what is off is neither downloaded nor
  compiled. `web` has PostgreSQL and SQLite; `full` adds MongoDB and
  Redis.
- Release binaries of examples/full on x86_64 Linux (loaded sections,
  `tools/binary_size.py`): 6.1 MB with everything, 1.3 MB minimal. Brotli adds about 0.8 MB (its encoder and the
  122 KB dictionary with its lookup tables), so `-Dbrotli=false` is the
  first flag to drop for a smaller binary that still compresses.
- The public surface (what Zig's autodoc shows from `anole`) is the API
  alone: the raw C bindings (nghttp2, ngtcp2, nghttp3, BoringSSL), the TLS
  module the HTTP core runs on, test helpers, gRPC's wire modules
  (`frame`, `status`, `metadata`, `deadline`) and the WebSocket layer over
  HTTP/2 and HTTP/3 streams stay inside. `anole.compression` keeps its
  zlib-ng, zstd and Brotli bindings, which are what it is for.
  `anole.h2.version()`, `anole.h3.version()` and `anole.tls.version()` say
  what a build links.

### Docs and examples

- docs/getting-started.md: from `zig init` and `zig fetch --save` to a
  running JSON API, then a WebSocket, static files, TLS, gRPC (with
  `addApp` and a `.proto`) and deploying (addresses, systemd, Docker).
- docs/from-fiber.md: Go Fiber v3's API next to Anole's, and what differs
  in Zig (arenas, error unions, no `recover`).
- Guides for the server, routing, WebSockets, WebTransport, gRPC, clients,
  databases, auth and observability, with every Zig snippet compiled
  against the API.
- A docs site, https://xuckless.github.io/anole/, built from docs/ with an
  API reference at /api/ (`zig build docs`, Zig's autodoc of the `anole`
  module, from doc comments on the public API), and a GitHub wiki kept in
  sync with docs/.
- SECURITY.md (private reports through GitHub's advisories) and issue
  templates.
- Examples, each with `zig build run-<name>`: `hello` (the smallest
  server), `rest` (a JSON CRUD API behind an API-key middleware, checked
  by tests/rest_test.zig), `websocket`, `grpc`, `auth`, `clients`,
  `observe`, `io`, `postgres` (a posts API with a transaction), `sqlite`
  (a to-do API), `mongodb` (a users API), `redis` (a counter, a cache, a
  leaderboard and pub/sub as Server-Sent Events), and `full` (every
  listener and option spelled out; the server that h2spec and the restart
  test drive).

### Quality

- CI on Linux and macOS: unit tests for every flag combination, the HTTP
  core's own test suite on Anole's TLS and C libraries, h2spec, Autobahn, gRPC interop,
  HTTP/3 (WebTransport and RFC 9220 included) against aioquic, the QUIC
  interop runner and its WebTransport mode, fuzzing of the parsers
  and shim boundaries (HTTP/1.1 requests whole and in pieces, a whole
  connection over HTTP/1.1 and HTTP/2, the PROXY protocol, WebSocket over
  HTTP/2 and permessage-deflate, gRPC frames, metadata and timeouts,
  Connect GET messages, JSON, session cookies, traceparent, JWS and JWK
  Sets, OIDC discovery, token responses and ID token claims,
  `LISTEN_FDS`, BSON and MongoDB's wire messages), a clean-consumer
  build, and a weekly check of the C libraries' pins (SQLite's included)
  against known advisories.
- The database connectors against real servers in Docker: postgres:17
  (plain and `verify-full` TLS), MongoDB 7.0, 8.0 and 9.0 as a replica set
  (SCRAM-SHA-256, SCRAM-SHA-1 and TLS, retries through `failCommand`; 8.0
  and 9.0 on ubuntu-22.04),
  redis:7 and valkey:8 (plain, and TLS with an ACL user). MongoDB's
  connection-string, URI-options and server discovery spec tests and the
  BSON corpus run in `zig build test`.

### Not yet

- HTTP/3: keeping ticket keys (so 0-RTT) across restarts.
- WebTransport's later drafts (13 and on, which need QUIC's RESET_STREAM_AT
  and per-session flow control), and checks against real browsers.
- gRPC over HTTP/3; JSON transcoding of client and bidirectional streaming
  methods.
- MongoDB: transactions, change streams, `mongodb+srv://`, read
  preferences other than `primary`, `loadBalanced`, compression, and the
  request's own deadline sent as `maxTimeMS`. Redis Cluster and Sentinel.
- Windows (#47): until it is a development target, use WSL2 or Docker.
- Independent benchmark results: Anole's HttpArena entry follows this
  release.

Known limitations and planned work are tracked in GitHub Issues:
https://github.com/xuckless/anole/issues
