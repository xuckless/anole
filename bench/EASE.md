# Ease of use

The same server (`SPEC.md`) in each stack: the routes, the $12 API,
WebSockets, static files, and every protocol the stack can serve. Line
counts are code lines without blanks or comments, from each server's
`NOTES.md`; "what it took" is what had to be written or configured beyond
the stack's hello world.

## Capability matrix

N = in the framework itself; L = a library most people in that language use;
P = only behind a proxy (nginx); - = nothing idiomatic.

| | Anole | Fiber | Go net/http | Axum | Express | Fastify | FastAPI |
| --- | --- | --- | --- | --- | --- | --- | --- |
| HTTP/1.1 | N | N | N | N | N | N | N (uvicorn) |
| HTTPS (ALPN h2) | N | N, http/1.1 only | N | L (axum-server) | N (node:https), http/1.1 only | N | N (uvicorn), http/1.1 only, no ALPN |
| h2c | N (same port as h1) | - | N (Go 1.24 `Protocols`) | N (same port) | - | N (`http2: true`, separate server) | L (Hypercorn) |
| HTTP/3 | N (one option) | P | L (quic-go) | L (h3 + h3-quinn, 71 lines of glue) | P | P | L (Hypercorn + aioquic; broken with `--workers`) |
| WebSocket (h1) | N | L (gofiber/contrib) | L (coder/websocket) | N (feature `ws`) | L (ws, outside the router) | L (@fastify/websocket) | N |
| WebSocket over h2 (RFC 8441) | N, no code | - | - | N (`any()` routes; one line for TLS) | - | - | L (Hypercorn) |
| WebSocket over h3 (RFC 9220) | N, no code | - | - | - | - | - | - |
| WebTransport (draft-02) | N (`app.webtransport`, one line) | - | L (webtransport-go v0.10, separate server; later releases dropped draft-02) | L (wtransport, its own endpoint: no axum routes beside it) | - | L (@fails-components/webtransport, no Fastify integration) | L (raw aioquic events; no ASGI server has it) |
| gRPC | N (codegen in `zig build`) | - | L (grpc-go + protoc) | L (tonic + build.rs + protoc) | - | L (grpc-js, separate server) | L (grpcio, separate process) |
| Static + Range | N (sendfile) | N (`ByteRange: true` opt-in) | N | L (tower-http) | N | L (@fastify/static) | N |
| Postgres client | **none** | L (pgx) | L (pgx) | L (sqlx) | L (pg) | L (pg) | L (asyncpg) |
| JWT | N (anole.auth) | L | L | L | L | L | L |

## Size of the same server

| | Code lines | Of which: $12 | Direct deps | Image |
| --- | ---: | ---: | ---: | ---: |
| Anole | 593 (366 without its Postgres client) | 156 + 227 (client) | 1 | 212 MB |
| Fiber | 540 | 206 | 4 | 29 MB |
| Go net/http | 671 (+ 3 986 generated) | 228 | 6 | 34 MB |
| Axum | 645 | 192 | 19 | 62 MB |
| Express | 234 | 86 | 4 | 338 MB |
| Fastify | 308 | 111 | 7 | 377 MB |
| FastAPI | 289 (+ 35 for the HTTP/3 workaround) | ~100 | 9 | 311 MB |

Express is the shortest because it serves the least (HTTP/1.1 and TLS
only); Anole serves every row of the matrix from one dependency, and its
line count is dominated by the database client it had to bring itself.

## What each one made hard

**Anole**
- No Postgres (or any SQL) client: 227 lines of wire protocol and pooling.
- Defaults a real service has to lift: the 30 s whole-request timeout
  cuts long streams and sockets, the 10 000 connection cap, a 1 MiB body
  limit, 60 s keep-alive.
- Names to learn: `anole.Cert` (not `anole.tls.Cert`),
  `.executors = .exact(n)`, `anole.http.Status` vs `std.http.Status`,
  `ContentType.unknown` for octet-stream.
- Two root declarations (`std_options`, `zio_options`) in every program.

**WebTransport, everyone**
- Anole: `app.webtransport("/wt/echo", handler)` beside every other route,
  on the same HTTP/3 listener; the handler is 30 lines with datagrams.
- Go: webtransport-go's current releases speak only the newer drafts
  browsers don't use yet, so it is pinned to v0.10.0 (quic-go v0.59.0,
  three releases old); a separate server with its own Origin check.
- Rust: wtransport owns the QUIC endpoint and rejects anything that is not
  a WebTransport CONNECT, so no `/plaintext` (or axum Router) beside it;
  paths are matched by hand.
- Node: a native addon wrapping Chromium's QUICHE; it needs glibc 2.38,
  ignores the client unless it sends `SETTINGS_ENABLE_WEBTRANSPORT`, and
  its idle timeout can't be set from JS.
- Python: no ASGI server serves it; aioquic gives connection events
  (headers, stream data, datagrams) and the session bookkeeping is yours.

**Fiber**
- No HTTP/2, HTTP/3 or gRPC at all (fasthttp); Go's own net/http is the
  answer, i.e. a second framework.
- TLS without ALPN unless a `TLSConfigFunc` sets it; Range opt-in; static
  404s with an empty body; fasthttp's reused buffers.

**Go net/http**
- quic-go's 30 s idle timeout means writing out what
  `http3.ListenAndServeTLS` does; gRPC needs protoc with `M` mappings;
  coder/websocket's Origin check and 32 KiB read limit; `http.FileServer`
  404s can't be customized.

**Axum**
- HTTP/3 is do-it-yourself (h3 0.0.x, 71 lines adapting to tower,
  buffered request bodies, no WebSockets over h3).
- rustls crypto-provider conflicts panic at runtime unless exactly one
  provider is compiled in; feature flags for h2c and WebSockets; protoc at
  build time for tonic.

**Express**
- No HTTP/2, HTTP/3 or gRPC; WebSockets live outside the router (hand-written
  404s on raw sockets); `express.raw` silently ignores bodies without a
  Content-Type; Node's 5 s keep-alive default.

**Fastify**
- An empty body sent as `application/json` is a 400 by default, and the
  challenge's own load script sends one for every like: the JSON parser had
  to be replaced in the $12 scope.
- Auth must move to `onRequest` because the body is parsed before
  `preHandler`; @fastify/jwt's errors do not match a typical API's; error
  and 404 handlers must be registered before plugins; the HTTP/2 server's
  http/1.1 fallback ignores `keepAliveTimeout`.

**FastAPI**
- Two servers for one app (uvicorn has no HTTP/2 without an extra
  package; Hypercorn for h2c and HTTP/3); Hypercorn's `--workers` breaks
  QUIC (needs a 35-line launcher); grpcio's package name shadows generated
  `grpc.testing` modules; `fastapi run` has no flags for TLS or keep-alive.
