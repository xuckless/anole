# Fastify 5: ease-of-use notes

Fastify 5.12.7 on Node 24.22.0 (`node:24.22.0-bookworm-slim`), ESM, `NODE_ENV=production`,
`logger: false`. Direct dependencies: `fastify`, `@fastify/static`, `@fastify/websocket`,
`@fastify/jwt`, `pg`, `@grpc/grpc-js`, `@grpc/proto-loader` (7 packages, 118 in `node_modules`, 38 MB,
mostly protobufjs and gRPC). Image: 377 MB (the base image is 331 MB).

## Source size

| File | Lines | Code lines (no blanks/comments) | What |
|---|---|---|---|
| `server.mjs` | 49 | 43 | modes, `node:cluster`, Fastify options (http2/https), listen |
| `app.mjs` | 108 | 87 | core routes and response schemas, /echo scope, static, 404 and error handlers |
| `ws.mjs` | 55 | 44 | @fastify/websocket routes: echo, feed ticker, trade |
| `twelve.mjs` | 129 | 111 | the $12 routes: pg Pool, @fastify/jwt, schemas, 5 routes |
| `grpc.mjs` | 28 | 23 | grpc-js TestService/UnaryCall |
| **Total** | **369** | **308** | |

About 40 of those lines are JSON response schemas (`/json`, `/list` and the $12 routes). Fastify's docs
recommend them: with a response schema, Fastify serializes through fast-json-stringify (7.1.1)
instead of `JSON.stringify`. Without them the routes work the same, just slower. The schemas also
fix key order, which the spec requires anyway. Error bodies (status codes with no schema) and
`/gc/*` use the default `JSON.stringify` path. `/gc/alloc` measures the `JSON.stringify` length of
its list, as the spec says.

## Per protocol

- **h1**: `Fastify({ logger: false, keepAliveTimeout: 75_000 })` and `listen`. Fastify's own default
  is 72 s, so it has to be raised to meet the spec's 75 s.
- **h2c**: `http2: true` without `https` gives h2c with prior knowledge only (no h1 Upgrade on the
  same port). It's one option. `http2SessionTimeout: 75_000` is needed because Fastify closes idle
  h2 sessions after 72 s by default.
- **tls (h2 + http/1.1)**: `http2: true, https: { allowHTTP1: true, cert, key }`, which gives ALPN
  `h2, http/1.1`. Friction: Fastify only applies `keepAliveTimeout` to its HTTP/1 servers, so the
  http/1.1 fallback of the HTTP/2 TLS server kept Node's 5 s default (measured: idle connections
  closed at 6 s) until `app.server.keepAliveTimeout = 75_000` was set by hand.
- **h3**: not supported (Node has no stable QUIC). The process exits 3.
- **gRPC**: a separate server, `@grpc/grpc-js` + `@grpc/proto-loader` loading
  `tests/grpc/proto/grpc/testing/test.proto` (copied into the image at build time). About 20 lines,
  and unrelated to Fastify itself. No friction: `bindAsync` works under `node:cluster` too (tested
  with 4 workers). `MODE=grpc` starts only the gRPC server.
- **WebSocket**: `@fastify/websocket` (ws 8.22.0). It's a plugin registration plus
  `{ websocket: true }` on ordinary routes, so hooks, routing and 404s are Fastify's. It runs over
  HTTP/1.1 upgrades only, which covers h1 and the TLS http/1.1 fallback (WSS tested). With h2c
  (prior knowledge only) a WebSocket can't connect, and RFC 8441 isn't supported (`ws_h2: false`).
- **Static**: `@fastify/static` with `{ root, prefix: '/static/' }`. Range/206 via @fastify/send.
- **/echo**: an encapsulated plugin scope with `removeAllContentTypeParsers()`, a catch-all `'*'`
  buffer parser and a route-level `bodyLimit` of 8 MiB, so the rest of the app keeps the JSON parser.
  About 8 lines. Bodies over 8 MiB get 413.
- **$12**: `pg.Pool` (max `ceil(PG_POOL / WORKERS)`) plus `@fastify/jwt` (fast-jwt 6.3.5;
  `verify: { algorithms: ['HS256'] }`, token cache off by default). Friction points:
  - Fastify parses the body before `preHandler`. Auth must run in an `onRequest` hook (as the
    @fastify/jwt README does) to get "auth before body/id".
  - @fastify/jwt's own errors don't match the spec (`Basic abc` gives a 400 "Format is
    Authorization: Bearer [token]"), so the hook checks the `Bearer ` prefix itself and maps any
    `jwtVerify()` failure to 401 `invalid or expired token`.
  - Malformed JSON comes in as `FST_ERR_CTP_INVALID_JSON_BODY` (or `..._EMPTY_JSON_BODY`) through
    `setErrorHandler`.
  - The challenge's load.js likes a post with `Content-Type: application/json` and no body, which
    Fastify's JSON parser rejects with a 400 (`FST_ERR_CTP_EMPTY_JSON_BODY`); the golden tests
    don't send that, so it showed up only under load, as 7% errors and a score of 0. The $12 scope
    replaces the JSON parser with one that takes an empty body as none and hands the rest to
    `getDefaultJsonParser('error', 'error')`. Every other stack here accepts the empty body as is.
  - `setErrorHandler`/`setNotFoundHandler` must be set before `register()`ing the plugins, or the
    encapsulated scopes keep Fastify's defaults.
  - pg `bigint` comes back as strings, so the same global `setTypeParser(INT8, parseInt)` as Express.
    (The `integer` schema would coerce them anyway.)
- **Cluster**: the same `node:cluster` block as Express. The ticker, the trade position and the RETAIN
  list are per worker.
