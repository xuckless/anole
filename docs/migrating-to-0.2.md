# Migrating from 0.1 to 0.2

0.2 batches the breaking changes of the API review. Each area has its section
below; the changelog lists the rest. Before 1.0 there is no stability promise,
but every change here is a rename or a move, not a redesign, and the compiler
names each one.

## Server options, TLS and errors

### ServerOptions

| 0.1 | 0.2 |
| --- | --- |
| `.server = .{ .timeout = .{ .request = d } }` | `.timeouts = .{ .request = d }` |
| `.server.timeout.read_header` | `.timeouts.read_header` |
| (none) | `.timeouts.write` (30 s, new) |
| `.server.timeout.keepalive` | `.timeouts.keepalive` |
| `.server.timeout.idle_park` | `.timeouts.idle_park` |
| `.server.timeout.shutdown` (30 s) | `.timeouts.shutdown` (10 s) |
| `.server.timeout.request_count` | `.limits.max_requests_per_connection` |
| `.server.request.max_body_size` | `.limits.body_max` |
| `.server.request.max_content_length` | `.limits.body_max` (one limit for both) |
| `.server.request.buffer_size` | `.limits.max_head_size` |
| `.server.request.max_header_count` | `.limits.max_header_count` |
| `.server.request.max_param_count` / `max_query_count` / `max_form_count` / `max_multiform_count` | `.limits.<same>` |
| `.server.request.require_host` | `.request.require_host` |
| `.server.request.decompress` | `.request.decompress` |
| `.server.request.keep_buffers_between_requests` | `.request.keep_buffers` |
| `.server.response.*` | `.response.*` (same names) |
| `.server.max_connections` (null: no cap) | `.limits.max_connections` (0: the open-file limit; no "no cap") |
| `.server.trusted_proxy_hops` | `.proxy.trusted_hops` |
| `.server.trust_forwarded_proto` / `trust_forwarded_host` | `.proxy.trust_forwarded_proto` / `trust_forwarded_host` |
| `.server.errors`, `.server.error_handler`, `.server.http2`, `.server.listeners` (ignored before) | `.errors`, `.error_handler`, `.http2`, `.listeners` |
| `.restart_timeout_ms = 10_000` | `.restart_timeout = .fromSeconds(10)` |
| `.client = http.ClientConfig{...}` | `.client = anole.ClientOptions{...}` (same fields; `tls` is `TlsOptions`) |
| `.https.alpn_protocols`, `Listener.Tls.alpn_protocols` | `.alpn` |
| `.client_auth = .{ .ca = .{ .file = .{ .path = "ca.pem" } } }` | `.client_auth = .{ .ca = .fromFile("ca.pem") }` |
| `anole.http.ServerConfig.Tls.ClientAuth` | `anole.ClientAuth` |
| `anole.http.TlsCa` | `anole.Ca` (`.file`/`.dir` take a path string; no `dir` handle) |
| `TlsConfig.ClientCertificate{ .cert_path, .key_path }` | `anole.Cert.fromFiles(cert, key)` (or `.fromPem`) |
| `http.ClientConfig`, `http.TlsConfig` | `anole.ClientOptions`, `http.TlsOptions` |

A file-based CA or certificate used to be resolved against a `dir` handle;
paths are now relative to the working directory, so a test that wrote its
certificates into a temporary directory passes the path of the files there.
A `.dev_self_signed` client certificate is not supported by the client types
(`error.DevCertificateUnavailable`): make one with `anole.tls.selfSigned` and
pass it with `.fromPem`.

### Requests and responses

| 0.1 | 0.2 |
| --- | --- |
| `req.setTimeout(.{ .duration = .{ .raw = .fromSeconds(60), .clock = .awake } })` | `req.setTimeout(.fromSeconds(60))` |
| `req.setTimeout(.none)` | `req.setTimeout(null)` (rarely needed: streams lift the deadline themselves) |
| `req.setTimeout(.{ .deadline = t })` | `req.setDeadline(.{ .deadline = t })` |
| `res.writer()` | `try res.writer()` |
| `res.headers_written` | `res.headersSent()` |
| `res.conn`, `req.parser`, `req.transport`, ... | internal (`_`-prefixed); not for handlers |
| `Response.init`, `Request.reset` | `Response._init`, `Request._reset` (engines only) |
| chunked `req.reader()` unbounded | bounded by `limits.body_max`; `req.readerLimited(buf, n)` for more |

### Middleware and helpers

| 0.1 | 0.2 |
| --- | --- |
| `fn execute(self, req, res, executor: anytype) !void { return executor.next(); }` | `fn execute(self, req, res, next: anytype) !void { return next.call(); }` |
| `Compress.init()` | `Compress.init(.{})` |
| `Logger.init()`, `Logger.initWith(.{ ... })` | `Logger.init(.{ ... })` |
| `Cors.Config`, `RequestId.Config`, `Logger.Config`, `session.Config`, `csrf.Config` | `...Options` |
| `session.ConfigError` | `session.OptionsError` |
| `MemoryStore.init(gpa, io)`, `initOptions(gpa, io, o)` | `MemoryStore.init(gpa, io, .{ ... })` |
| session `ttl_seconds` | `ttl` (Duration) |
| ratelimit `window_ms`, `idle_ms` | `window`, `idle` |
| auth `*_seconds` (`leeway_seconds`, `ttl_seconds`, `max_age_seconds`, ...) | same names without `_seconds` (Duration) |
| `Cors` `max_age = 600` | `max_age = .fromSeconds(600)` |
| `TracingOptions.interval_ms` | `interval` |
| `tls.SelfSignedOptions.valid_for_seconds` | `valid_for` |
| MemoryLimiter + `ratelimit.Middleware.init(...)` | still works; or `app.rateLimit(.{ .limit = 100 })` |

### Errors

| 0.1 | 0.2 |
| --- | --- |
| `init`/`listen`/`run` return inferred `anyerror` sets | `anole.ServerError` (named; switch on it) |
| `reloadCertificates`/`setCertificate` | `anole.TlsLoadError` |
| out-of-order request/response use: undefined behaviour in ReleaseFast | `anole.http.MisuseError`, answered 500 |

### Behaviour you may notice

- The drain waits 10 s (was 30 s). Docker's default stop grace is also 10 s:
  give containers `stop_grace_period: 15s`.
- Event streams, streamed responses and downloads are no longer cut at 30 s;
  a client that stops reading is cut after `timeouts.write` (30 s).
- WebSocket messages over 1 MiB are refused by default (was 16 MiB).
- `listen("3000")` works (every interface).
- Setting one `http2` field keeps 250 streams.
- `app.tracing()` honours `OTEL_*` without `.process`.
- Outbound requests say `User-Agent: anole/<version>`.

### C ABI JSON config (ABI 0.7)

| 0.6 | 0.7 |
| --- | --- |
| `trusted_proxy_hops` | `proxy.trusted_hops` |
| `trust_forwarded_proto`, `trust_forwarded_host` | `proxy.trust_forwarded_proto`, `proxy.trust_forwarded_host` |
| `timeouts.*_ms`: integers | integers or `null` (none) |
| `middleware[].jwt.leeway_s` | `leeway_ms` |
| `middleware[].cors.max_age` | `max_age_ms` |
| (none) | `timeouts.read_header_ms`, `write_ms`, `idle_park_ms`; `limits.max_head_size`, `max_header_count`, `max_param_count`, `max_query_count`, `max_form_count`, `max_multiform_count`, `max_requests_per_connection`; `proxy`, `request`, `response`, `http2`, `errors`; `http3.address`, `port`, `validate_address`, `prefer_v2`, `sockets`, `enable_connect_protocol`, `inline_no_wait`; `tls.client_ca_dir`, `client_ca_system` |

## The C ABI (0.6 to 0.7)

The C ABI moves to version 0.7. Before 1.0 every minor may break, so a library
serves only code built against the same version: check
`ANOLE_ABI_COMPATIBLE(anole_abi_version())` at load, and replace any
`major ==` / `minor >=` comparison with it.

Rename the calls and constants (a search and replace is enough for most):

| 0.6 | 0.7 |
| --- | --- |
| `anole_respond(r, ...)` | `anole_req_respond(r, ...)` |
| `anole_respond_fd(r, ..., int fd, ...)` | `anole_req_respond_fd(r, ..., intptr_t fd, ...)` |
| `anole_stream_start/write/write_wait/end` | `anole_req_stream_start/write/write_wait/end` |
| `anole_release(r)` | `anole_req_fail(r, 0, (anole_str){0})` (500) or `anole_handle_release(r)` (finalizers) |
| (none) | `anole_req_abort(r)` |
| `anole_wt_stream_release(s)` | `anole_handle_release(s)` |
| `anole_server_port(s, i, &port)` | `anole_server_listener(s, i, &info)`; `info.port`, `info.udp_port` |
| `anole_server_reload_certificates(s)` | `anole_server_reload_tls(s, 0, (anole_str){0}, (anole_str){0})` |
| `anole_server_reload_tls(s, f, c, cl, k, kl)` | `anole_server_reload_tls(s, f, (anole_str){c, cl}, (anole_str){k, kl})` |
| `anole_wt_send_datagram(w, d, n)` | `anole_wt_send_datagram(w, d, n, 0)` |
| `ANOLE_EV_WS_DRAIN` | `ANOLE_EV_WRITABLE` (`ev.handle` the socket) |
| `ANOLE_EV_ABORT` read as `anole_event` | `anole_abort_event` (`reason`, `status`) |
| `anole_request_spans(r)` = `r + 1` | the same helper, now reading `r->spans_off` |
| `anole_request_peer_cert(r)` | `anole_event_str(r, r->peer_cert)` |
| gRPC metadata at `c + 1` | `anole_grpc_metadata(c)` (`c->metadata_off`) |
| `ANOLE_DB_INT`... | `ANOLE_DB_TYPE_INT`...; `ANOLE_DB_WRITE`... are `ANOLE_DB_F_*` |
| `ANOLE_GRPC_OK`... | `ANOLE_GRPC_STATUS_OK`...; `ANOLE_GRPC_UNARY`... are `ANOLE_GRPC_KIND_*`; `ANOLE_GRPC_SEND_FINISH` is `ANOLE_GRPC_F_FINISH` |
| `ANOLE_WT_UNI`, `ANOLE_WT_FIN` | `ANOLE_WT_F_UNI`, `ANOLE_WT_F_FIN` (values kept) |
| `ANOLE_TLS_PEM`, `ANOLE_SERVER_SIGNALS`, `ANOLE_CONSUMER_SHARED`, `ANOLE_POLL_NOARM` | `ANOLE_TLS_F_PEM`, `ANOLE_SERVER_F_SIGNALS`, `ANOLE_CONSUMER_F_SHARED`, `ANOLE_POLL_F_NOARM` |
| enum-valued parameters as `int` (`anole_ws_send`'s type, the log callback's level) | `uint32_t`; `anole_consumer_fd` returns `intptr_t`; `anole_has_feature` returns `int32_t` |

Behaviour that changes with the rename:

- **Cleanup calls are idempotent.** `anole_handle_release`, `anole_req_abort`,
  `anole_ws_close`, `anole_ws_unsubscribe`, `anole_wt_close`,
  `anole_wt_stream_reset` and `anole_wt_stream_stop` answer `ANOLE_OK` on an
  object that is already over, set no error and are not counted in
  `anole_stats.gone`. Code that treated `ANOLE_E_GONE` from a close or release
  as harmless keeps working (it now gets OK). Answer and data calls still
  answer `ANOLE_E_GONE`.
- **A handle of the wrong kind, or 0, is `ANOLE_E_INVALID`** (token
  `WrongHandleKind`), not `ANOLE_E_GONE`. Code that relied on GONE to detect
  a wrong-kind handle must check `ANOLE_E_INVALID`.
- **Options structs and flags are checked.** An options struct larger than the
  library knows is refused unless the extra bytes are 0; unknown flag bits
  (`anole_db_options.flags` included) and non-zero reserved fields
  (`anole_db_value.reserved`, `anole_db_options.reserved`) are
  `ANOLE_E_INVALID`.
- **`ANOLE_E_TOOBIG` from a poll** writes an `ANOLE_EV_NONE` header with the
  needed `len`; allocate that once instead of doubling.
- **Records**: read the header spans through `spans_off` and the gRPC metadata
  through `metadata_off`, never `sizeof`; the client certificate is a span
  (`peer_cert`), no longer a length-prefixed blob.
- **`anole_ws_publish`** on a server that is not running is `ANOLE_E_STATE`
  (was `ANOLE_E_GONE`); a failed `dup` in `anole_req_respond_fd` is
  `ANOLE_E_SYSTEM` (was `ANOLE_E_INVALID`).
- **Generate, do not hand-write**: `include/anole.abi.json` (and
  `include/anole.schema.json` for the configuration) describe every record,
  constant, event and handle kind; generate your parsers from them, pinned to
  the Anole tag.

New in 0.7 (see docs/c-abi.md): `anole_server_open`, `anole_server_set_ready`,
`anole_server_listener(_count)`, `anole_last_error_name`, `anole_last_errno`,
`anole_consumer_set_wake`, the allocation table, abort reasons, and a destroy
that does not wait for answers only its caller could give.

## Databases and gRPC

### Options (every connector)

- **Every call is bounded by 30 s.** `Options.timeout` exists on all four
  connectors (it was MongoDB's alone, and off) and defaults to 30 s;
  `TxOptions.timeout = null` now means the connector's too. A call that
  must run longer (a migration, a background job) passes
  `.with(.{ .timeout = .max })`, or set `timeout = null` on the connector.
  C ABI: `anole_db_options.timeout_ms = 0` now means the database's
  `timeout_ms` (30000), not "none"; use `ANOLE_DB_TIMEOUT_NONE`.
- **One vocabulary, renamed fields:**

| 0.1 | 0.2 |
| --- | --- |
| `sqlite.Options.busy_timeout_ms = 5000` | `busy_timeout = .fromSeconds(5)` |
| `sqlite.Options.statement_cache = 64` | `statement_cache_size = 64` (`u16`) |
| `sqlite.Options.readers: ?usize` | `?u32` |
| `mongodb.Options.max_idle` | `idle_timeout` |
| `mongodb.Options.max_connections: usize = 100` (0: no limit) | `?u32`, null for 100; 0 is refused |
| `mongodb.Options.connect_timeout: Duration` | `?Duration` (null: none) |
| `mongodb.Options.tls: ?net.ConnectOptions.Tls` | `tls: anole.db.Tls` (`ca`, `client_certificate`, `insecure_skip_verify`) |
| `pg.Options.tls`, `redis.Options.tls` | the same `anole.db.Tls` (old paths still compile) |
| `.tls = .{ .ca = .{ .file = .{ .path = "ca.pem" } } }` | `.tls = .{ .ca = .{ .file = "ca.pem" } }` (`anole.Ca`) |
| `name: []const u8 = "postgres"` | `name: ?[]const u8 = null` (the same default label) |
| `sqlite.Client.execScript(sql)` | `execScript(&ctx, sql)`; `pg.Client.execScript(&ctx, sql)` is new (both unbounded) |
| `pg`/`sqlite` `Query.run(req, sql, values)`, `Tx.run` | `execValues` (`table` keeps its name) |
| `anole.mongodb.dynamic.run(collection, database, ctx, op, docs)` | still there; `app.mongodb.with(opts).dynamic(ctx, op, "users", docs)` takes the context first |
| `max_connections = 0` | refused at init with `error.InvalidOptions` on PostgreSQL, Redis and MongoDB |

  New fields: `connect_at_start` and `ping_timeout` on MongoDB,
  `ping_timeout` on SQLite. `Conn.release` takes `*const Conn` on every
  connector (so `const conn = try app.redis.acquire(req); defer
  conn.release();` compiles).
- **Leaving a transaction open is caught on more paths.** `iterate` that
  leaves one, and a connection from `acquire` given back inside one, are
  rolled back and logged, as plain calls already were.
  `Tx.table`, `Tx.execValues` and `Tx.with(options)` exist on both SQL
  connectors; a finished SQLite `Tx` fails with `error.Database` instead of
  asserting.
- **Role switches inside functions under `.auto`.** PostgreSQL does not
  report `role`, so `reset_session = .auto` does not catch `SET ROLE` made
  inside a function; use `.always` for apps that switch roles for row-level
  security, or `SET LOCAL ROLE` inside a transaction.

### C ABI: databases

- `anole_db_options` is 48 bytes (`req` at the end) and
  `anole_db_result_event` 104 (`table` span at the end); read both through
  `size`/`len` as before.
- New: `anole_db_begin`, `anole_db_tx_query`, `_exec`, `_commit`,
  `_rollback`, `_release` (handle kind `db_tx`), `ANOLE_DB_TIMEOUT_NONE`,
  `ANOLE_DB_TX_READ_ONLY`, `ANOLE_DB_ISOLATION_*`; `anole_db_query` and
  `anole_db_exec` accept a NULL consumer with `anole_db_options.req`.
- JSON config: `databases[].timeout_ms` (30000), `errors`, client
  certificates (`client_cert_file`, `client_key_file`, `client_cert_pem`,
  `client_key_pem`), `insecure_skip_verify` and `ping_timeout_ms` for
  PostgreSQL, Redis and MongoDB; MongoDB `idle_timeout_ms`, `heartbeat_ms`,
  `retry_reads`, `retry_writes`, `connect_at_start`; SQLite `uri`,
  `ping_timeout_ms`. `sqlite.statement_cache` is `statement_cache_size`, and
  `mongodb.max_connections` 0 is refused.
- A libanole built with Redis or MongoDB but neither SQLite nor PostgreSQL
  answers `anole_db_query` (it used to refuse every call).

### gRPC

- `Call.addHeader` and `Call.addTrailer` refuse the protocols' own keys
  (`grpc-*` but `grpc-status-details-bin` in trailers, `connect-*`,
  `trailer-*`, `content-type`, `te`...): a handler could send a second
  `grpc-status`. `addHeader` adds a value instead of replacing one. The C ABI
  also refuses `grpc-status-details-bin` as initial metadata.
- `Call.fail`, `addTrailer` and `addHeader` copy their strings;
  `Call.failFmt(code, fmt, args)` is new.
- `Group.grpc` and `Group.grpcWith` register a service behind a group's
  middleware, for its gRPC calls and its transcoded routes alike (before, a
  transcoded `/v1/...` route skipped a `/v1` group's auth middleware). C ABI:
  `grpc.services[].middleware`.
