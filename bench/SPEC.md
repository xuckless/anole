# Bench server contract

Every server in `bench/servers/<name>/` implements this contract, so the load
tools can drive any of them the same way. Write each one the way that
framework's own docs and quick start do it: idiomatic code, the framework's
standard modules, its default JSON serializer, no custom HTTP parsing, no
hand-tuned socket options, and no caching that the spec forbids. When the
framework lacks a protocol, use the library that most developers in that
language would reach for (the table in `bench/README.md`).

## Servers

| Directory | Serves | Modes |
|---|---|---|
| `anole` | Anole | h1 (with h2c on the same port), h2c, tls (h2 + http/1.1), h3, grpc |
| `fiber` | Go Fiber v3 (fasthttp) | h1, tls (http/1.1) |
| `gohttp` | Go net/http (stdlib): the Go row for h2c, h2 over TLS and h3 (quic-go), and for gRPC (grpc-go) | h1, h2c, tls, h3, grpc |
| `axum` | Axum on hyper; HTTPS through axum-server + rustls; h3 through h3 + h3-quinn serving the same Router; gRPC through tonic | h1, h2c, tls, h3, grpc |
| `express` | Express 5 on node:http / node:https | h1, tls (http/1.1) |
| `fastify` | Fastify 5 (`http2: true` for h2c and TLS h2); gRPC through @grpc/grpc-js | h1, h2c, tls, grpc |
| `fastapi` | FastAPI under uvicorn[standard] (h1, tls) and the same app under Hypercorn (h2c, h3); gRPC through grpcio | h1, h2c, tls, h3, grpc |
| `nginx` | nginx: the static-file and video baseline, and the reverse proxy in front of the others | h1, tls, h3 |

## Container

- Built from the repository root: `docker build -f bench/servers/<name>/Dockerfile -t anole-bench/<name> .`
- It runs in the foreground with `--network host`, and logs only warnings and errors, to stderr. There's no access log.
- Versions are pinned (base image tags, lockfiles, `go.sum`, `Cargo.lock`, `package-lock.json`, `requirements.txt` with `==`).
- Release builds: `-Doptimize=ReleaseFast`, `cargo build --release`, `go build`, `NODE_ENV=production`.
- `bench/servers/<name>/manifest.json` declares what the image can do:

```json
{
  "name": "fiber",
  "label": "Go Fiber v3.6.1",
  "modes": {
    "h1":  "fiber v3.6.1 (fasthttp)",
    "tls": "fiber v3.6.1 (fasthttp, crypto/tls)",
    "h2c": "net/http + x/net/http2/h2c",
    "h3":  "quic-go v0.64.0 http3"
  },
  "tls_alpn": ["http/1.1"],
  "ws": "gofiber/contrib/websocket",
  "ws_h2": false,
  "grpc": "grpc-go v1.84.0",
  "twelve": "pgx/v5 pgxpool + golang-jwt/v5",
  "static": "fiber static middleware"
}
```

  A mode that is missing is not supported (the report shows N/A). `label`
  values name the library that actually serves that mode.

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `HTTP_PORT`, `HTTPS_PORT`, `GRPC_PORT` | `8080`, `8443`, `50051` | The ports below, overridable so that several servers can be developed side by side. The suite uses the defaults. |
| `MODE` | `h1` | `h1`: HTTP/1.1 cleartext on TCP `:8080`. `h2c`: HTTP/2 prior knowledge, cleartext, on `:8080`. `tls`: HTTPS on TCP `:8443` with ALPN (`h2` and `http/1.1` when the stack does h2 over TLS, else `http/1.1`). `h3`: HTTP/3 on UDP `:8443` (also serving TLS on TCP `:8443` is fine). `grpc`: gRPC (h2c) on `:50051`. An unsupported mode exits with status 3 and a message. |
| `WORKERS` | `1` | CPUs in the tier. Go: `GOMAXPROCS`. Tokio: `worker_threads`. Node: `node:cluster` workers when > 1, else a single process. Uvicorn/Hypercorn: `--workers`. Anole: `.executors = .exact(n)`. |
| `CERT_FILE`, `KEY_FILE` | `/certs/cert.pem`, `/certs/key.pem` | PEM files, mounted read-only (ECDSA P-256, CN/SAN `localhost` and `127.0.0.1`). |
| `MEDIA_DIR` | `/media` | Directory served under `/static/`. |
| `DATABASE_URL` | unset | e.g. `postgres://bench@127.0.0.1:5432/run`. When set, the $12 routes are enabled. |
| `PG_POOL` | `20` | Total Postgres connections across all workers: each worker opens `ceil(PG_POOL / WORKERS)`. |
| `JWT_SECRET` | `twelve-dollar-challenge` | HS256 secret. |
| `RETAIN` | `0` | Number of retained objects built at startup (GC test). |
| `TICK_HZ` | `1000` | Ticks per second broadcast on `/ws/feed`. |

Listen on `0.0.0.0`. Keep idle keep-alive connections open for at least 75 s.

## Routes (every mode except `grpc`)

All JSON is compact. Key order is exactly as written. Integers only (no floats).

| Route | Response |
|---|---|
| `GET /plaintext` | 200 `text/plain`, `Hello, World!` |
| `GET /json` | 200 `application/json`, `{"message":"Hello, World!"}`, serialized per request with the framework's JSON (not a constant string) |
| `GET /users/:id` | 200 `text/plain`, `user <id>` |
| `GET /list` | 200 JSON, `{"items":[...50 items]}`, item `i` = 1..50: `{"id":i,"name":"item-<i>","active":<i%2==0>,"score":<i*7>}`, built as objects and serialized per request |
| `POST /echo` | 200 `application/octet-stream`, the request body back. Bodies up to 8 MiB are accepted. |
| `GET /gc/alloc?n=2000` | Builds a list of `n` (default 2000) objects `{"id":i,"name":"node-<i>","tags":["a<i%7>","b<i%11>","c<i%13>"],"active":<i%2==0>}` for i = 0..n-1, as real objects/structs with freshly allocated strings, and serializes them to a JSON string. Responds 200 `{"n":<n>,"bytes":<byte length of that JSON>}`. For n=2000 the bytes value must equal what the reference servers return. |
| `GET /gc/stats` | `{"retained":<RETAIN>}`. At startup the server builds `RETAIN` objects `{"id":i,"name":"retained-<i>","tags":["x<i%7>","y<i%11>","z<i%13>"]}` and keeps them reachable for its whole life, as a global list. |
| `GET /static/*` | The framework's standard static-file serving of `MEDIA_DIR`, with `Range`/206 support (the video test needs it). If the framework's static module has no Range support, use the most common add-on that does. |
| `GET /ws/echo` | WebSocket: every text or binary message is sent back unchanged. |
| `GET /ws/feed` | WebSocket: subscribes to the tick stream. One global ticker (one per process) sends `TICK_HZ` ticks per second to every subscriber as text messages `{"seq":<n>,"ts":<unix microseconds at send>,"sym":"BTCUSD","px":<100000 + n%1000>,"qty":<1 + n%10>}`. It wakes on a fixed 10 ms grid (a drift-free interval: `setInterval`, `tokio::time::interval`, `time.Ticker`, or an asyncio loop that sleeps until the next deadline — not a plain `sleep(10ms)` loop, which drifts to ~900/s) and sends `TICK_HZ/100` ticks, each with a fresh `ts`. Check it delivers TICK_HZ ±2% over a few seconds. `seq` starts at 1 per process. Messages from the client are ignored. |
| `GET /ws/trade` | WebSocket, request–response. The client sends `{"id":<int>,"sym":"BTCUSD","side":"buy"\|"sell","px":<int>,"qty":<int>,"t":<int>}`. The server parses it, applies it to a shared in-memory position (a per-symbol net quantity: + for buy, − for sell, behind whatever synchronization the framework needs), and answers `{"id":<id>,"status":"filled","px":<px>,"qty":<qty>,"pos":<net position after this fill>,"t":<t echoed>}`. |
| anything else | 404 `application/json`, `{"error":"not found"}` |

## The $12 routes (when `DATABASE_URL` is set)

These follow the challenge's `SPEC.md` (`bench/twelve/SPEC.md`) exactly: status codes, error messages, auth before id, and trimming. `bench/twelve/test.sh` must pass byte for byte against a fresh database. Postgres replaces SQLite. Use the driver's idiomatic parameterized query API with its default settings (whether it prepares statements is left to the driver), and use **exactly** these statements:

```sql
-- GET /health
SELECT 1
-- GET /feed
SELECT p.id, p.body, p.created_at, u.username,
       (SELECT count(*) FROM likes l WHERE l.post_id = p.id) AS like_count
  FROM posts p JOIN users u ON u.id = p.user_id
 ORDER BY p.created_at DESC, p.id DESC LIMIT 20
-- GET /posts/:id
SELECT p.id, p.body, p.created_at, u.username,
       (SELECT count(*) FROM likes l WHERE l.post_id = p.id) AS like_count
  FROM posts p JOIN users u ON u.id = p.user_id
 WHERE p.id = $1
-- POST /posts   ($1 = user id from the token's sub, $2 = trimmed body)
INSERT INTO posts (user_id, body) VALUES ($1, $2) RETURNING id, created_at
-- POST /posts/:id/like   ($1 = user id, $2 = post id)
WITH p AS (SELECT id FROM posts WHERE id = $2),
     ins AS (INSERT INTO likes (user_id, post_id) SELECT $1, id FROM p
             ON CONFLICT (user_id, post_id) DO NOTHING RETURNING 1)
SELECT (SELECT count(*) FROM p) AS found, (SELECT count(*) FROM ins) AS inserted
```

- Column types: `id`, `user_id`, `post_id` are `bigint`. `body`, `username` and `created_at` are `text`, with `created_at` already in wire format. `count(*)` is `bigint`. `found = 0` means a 404 `post not found`, `inserted = 1` means a 201 with `already_liked:false`, otherwise a 200 with `already_liked:true`.
- The Post object is `{"id","body","created_at","author","like_count"}`. `author` for a new post is the token's `username`.
- Health: `{"status":"ok","db":"ok","uptime_s":<int>}`, or 503 `{"status":"degraded","db":"unreachable","error":"<msg>"}`.
- JWT: the language's most common JWT library. HS256 only, signature and `exp` checked on every request, no caching. A `sub` that isn't a positive-integer string, or a `username` that isn't a string, gets `invalid token payload`.
- A malformed `:id` (`0`, `-1`, `abc`, `1.5`) is a 400 `invalid post id`.

## gRPC (`MODE=grpc`, `:50051`)

`grpc.testing.TestService/UnaryCall` from `tests/grpc/proto/grpc/testing/test.proto`: answer with a payload of `response_size` zero bytes (the interop semantics). The language's standard gRPC library: grpc-go, tonic, @grpc/grpc-js, grpcio (`grpc.aio`). Anole uses its interop server.

## WebTransport (`MODE=h3`)

WebTransport over HTTP/3, **draft-02** (draft-ietf-webtrans-http3-02), the
version Chrome, Edge and Firefox speak: extended CONNECT with `:protocol
webtransport`, `SETTINGS_ENABLE_WEBTRANSPORT` (0x2b603742), HTTP datagrams
(RFC 9297, quarter stream ID) and the `max_datagram_frame_size` transport
parameter. A server that serves it does so in `MODE=h3`, on UDP
`HTTPS_PORT`, at `/wt/echo`:

- Each bidirectional stream the client opens gets every byte echoed back on
  the same stream, and the server ends its send side (FIN) once the
  client's send side has ended.
- Each datagram is sent back unchanged on the same session.
- The QUIC idle timeout is at least 75 s (`wtload -mode idle -d 80s` checks it).
- A CONNECT to any other path gets 404. Unidirectional streams are not used.

The load client is `bench/tools/wtload` (its own Go module: it pins the
last draft-02 webtransport-go). Stacks without WebTransport in their own
HTTP/3 have a `<name>-wt` server beside the main one: `gohttp-wt`
(webtransport-go), `axum-wt` (wtransport), `fastify-wt`
(@fails-components/webtransport) and `fastapi-wt` (aioquic). These serve
`/wt/echo` and, where the library allows it, `GET /plaintext` over the same
HTTP/3 endpoint; `axum-wt` and `fastify-wt` cannot (their libraries answer
only WebTransport CONNECTs), so `wtload -mode sessions -n 1`, which exits
non-zero when no session opens, is their readiness probe.

## Smoke check

`bench/suite.sh --only smoke --servers <name>` checks each route, each declared mode and the $12 golden tests. A server is benchmarked only after it passes.
