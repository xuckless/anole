# Changelog

All notable changes to Anole. Before 1.0 there is no API stability promise;
breaking changes are listed anyway.

## 0.1.0 (unreleased, draft)

The first release: one server core for REST, WebSockets and gRPC over
HTTP/1.1, HTTP/2 and HTTP/3, with TLS, auth and observability, on Zig 0.17.0
for macOS and Linux.

### Server

- `anole.Server(Ctx)`: one call sets up the zio runtime (one pinned executor
  per core, connections never leave the core that accepted them), the
  listeners, SIGINT/SIGTERM handling and a graceful drain with a hard
  deadline.
- HTTP/1.1 through a fork of dusty: a segment-trie router with path parameters
  and wildcards, nested groups, middleware, keep-alive and pipelining,
  per-phase timeouts and body limits, static files with ranges, ETags and
  precompressed variants, and no allocation per request on a warm
  connection.
- HTTP/2 on nghttp2 1.70.0 (with an RFC 9113 strictness patch), over TLS
  through ALPN and over cleartext with prior knowledge, on the same router;
  streaming bodies, trailers, two-phase GOAWAY on drain. h2spec passes every
  case in strict mode, over h2c and TLS.
- HTTP/3 on ngtcp2 1.25.0 and nghttp3 1.18.0: the same handlers over QUIC,
  `Alt-Svc`, Retry, stateless reset, QUIC v2, ECN, PKTINFO, GSO and GRO on
  Linux, per-request timeouts and a GOAWAY drain. The QUIC interop runner
  passes every server case it was given against ngtcp2's and quic-go's
  clients.
- TLS through BoringSSL, built from source by Zig: TLS 1.3 and 1.2, ALPN,
  mutual TLS (with the acceptable CAs named in the request), stateless
  session tickets, close_notify on graceful closes, and a development
  certificate generated in memory (`.dev_self_signed`).
- Response compression with zstd or gzip (zlib-ng) by the client's q-values,
  and compressed request bodies.
- The PROXY protocol (v1 and v2) and `X-Forwarded-*` from trusted proxies.
- Zero-downtime restart on SIGUSR2 (the new process inherits the listening
  sockets) and systemd socket activation.
- An opt-in blocking pool (`Options.blocking`, `anole.blocking.run`):
  CPU-heavy or blocking calls run on zio's thread pool, capped at a set
  number at once, while the request's executor goes on serving.

### WebSockets

- RFC 6455 over HTTP/1.1 and RFC 8441 over HTTP/2 behind one
  `anole.websocket.upgrade`, permessage-deflate, and a rooms helper for
  broadcast. Autobahn passes every case.
- A receive that fails on the client's account sends the matching close
  code first (1009, 1007 or 1002) on both HTTP versions.
- A drain closes open sockets with 1001 (going away) and ends them as soon
  as their clients answer, rather than at `timeout.shutdown`;
  `Socket.draining()` tells handlers why, `close_on_drain = false` leaves it
  to them, and `req.drain` lets any long-lived handler watch for the drain.
- `Rooms.broadcast` sends outside the lock: a slow member holds up only the
  broadcasts that include it.
- RFC 8441 sockets are logged, measured and traced as 101, like HTTP/1.1
  upgrades.

### gRPC

- Server and client over HTTP/2: all four call modes, deadlines, metadata,
  status in trailers, gzip. grpc-go's interop client passes 14/14 cases
  against Anole and Anole's client 11/11 against grpc-go.
- gRPC-Web and Buf's Connect protocol on the same routes, and the
  `grpc.health.v1` service.
- `addProtoGen` for an application's build.zig: protoc and the Zig generator
  are pinned and built by `zig build`, nothing to install.

### Clients

- Outbound HTTP/1.1 and HTTPS (dusty's client on BoringSSL, the system trust
  store or your own CAs), an HTTP/2 client and an HTTP/3 client, usable from
  handlers through `req.io`.

### Auth, state and limits

- JWS/JWT verification with one pinned algorithm per key and JWKS keyrings
  that fetch outside their lock, one fetch at a time; a bearer-token
  middleware (`anole.auth.RequireJwt`) with RFC 6750 errors, scopes and
  claims handed to the handler; OIDC sign-in as a relying party (PKCE,
  Google and Apple presets); CSRF tokens; Argon2id passwords, hashed on the
  blocking pool when there is one; API keys; RBAC with roles from the
  application's state.
- Sessions in memory or Redis/Valkey, and sealed cookie sessions;
  `anole.session.regenerate` issues a new session ID at sign-in.
- Rate limiting with token buckets in memory or Redis and a 429 middleware.
- JSON on yyjson and a Redis/Valkey client on hiredis.

### Observability

- Prometheus `/metrics`, OpenTelemetry traces (W3C `traceparent`, OTLP/HTTP
  export), JSON or text access logs with request and trace IDs, `/healthz`
  and `/readyz`, and `anole.logFn` for one consistent log output.
- `Registry` and `Health` are values the application owns, each serving its
  own server, so one process can run several servers.
- An `exclude` list on the access log, HTTP metrics and tracing middleware
  keeps paths such as `anole.observe.probe_paths` (`/healthz`, `/readyz`,
  `/metrics`) out.
- Histogram sums are exact floats (seconds for durations, from
  nanoseconds), and bucket bounds are checked. `/readyz` answers 503 to
  anything still routed during a drain. `Exporter.deinit` returns without
  waiting out `interval_ms`.
- Breaking: `HttpMetrics.init` takes options, and `statusOf` the request.

### Build

- Every bundled library sits behind a build flag (`-Dtls`, `-Dhttp2`,
  `-Dhttp3`, `-Dgrpc`, `-Dwebsocket`, `-Dauth`, `-Dcompression`, `-Djson`,
  `-Dredis`) and presets (`-Dprofile=minimal|web|full`); what is off is
  neither downloaded nor compiled.
- Release binaries of examples/hello on x86_64 Linux: 5.0 MB with
  everything, 1.1 MB minimal.

### Quality

- CI on Linux and macOS: unit tests for every flag combination, dusty's own
  test suite on Anole's TLS and C libraries, h2spec, Autobahn, gRPC interop,
  HTTP/3 against aioquic, the QUIC interop runner, fuzzing of the parsers,
  a clean-consumer build, and a weekly check of the C libraries' pins
  against known advisories.

### Not yet

- HTTP/3: 0-RTT, connection migration and WebTransport.
- gRPC: JSON transcoding (`google.api.http`) and gRPC over HTTP/3.
- Hot certificate reload without a restart.
- Benchmarks on a dedicated Linux machine (the first results, on a Mac, are
  in the README).
