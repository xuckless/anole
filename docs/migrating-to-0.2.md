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
