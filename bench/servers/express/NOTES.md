# Express 5: ease-of-use notes

Express 5.3.0 on Node 24.22.0 (`node:24.22.0-bookworm-slim`), ESM, `NODE_ENV=production`.
Direct dependencies: `express`, `ws`, `pg`, `jsonwebtoken` (4 packages, 94 in `node_modules`, 5.5 MB).
Image: 338 MB (the base image is 331 MB).

## Source size

| File | Lines | Code lines (no blanks/comments) | What |
|---|---|---|---|
| `server.mjs` | 48 | 43 | modes, `node:cluster`, http/https listeners, keep-alive |
| `app.mjs` | 70 | 53 | core routes, static, 404 and error handlers |
| `ws.mjs` | 62 | 52 | `ws` on the HTTP server: echo, feed ticker, trade |
| `twelve.mjs` | 102 | 86 | the $12 routes: pg Pool, JWT middleware, 5 routes |
| **Total** | **282** | **234** | |

## Per protocol

- **h1**: `http.createServer(app)` and `listen` (Express's quick start). The only setting is
  `server.keepAliveTimeout = 75_000`, because Node's default is 5 s. No friction.
- **tls (http/1.1)**: `https.createServer({cert, key}, app)`, about 5 extra lines. Node's https server
  negotiates ALPN `http/1.1`. Express 5 still targets `node:http`'s req/res, so it can't sit on
  `node:http2`, which rules out h2 over TLS and h2c. `curl --http2` falls back to 1.1.
- **h2c, h3, gRPC**: not supported. The process exits 3 for other modes.
- **WebSocket**: Express has no WebSocket support, so it uses the `ws` package: one
  `WebSocketServer({ noServer: true })` plus a `server.on('upgrade')` dispatcher keyed by path (the `ws`
  README pattern for several endpoints on one server), about 50 lines. The friction is that
  WebSockets live entirely outside Express's router and middleware, so unknown upgrade paths need a
  hand-written 404 on the raw socket. WSS works unchanged on the https server. Over h2 it's N/A.
- **Static**: `app.use('/static', express.static(dir))`, one line. Range, 206, ETag and Last-Modified
  come built in through serve-static and send.
- **JSON**: `res.json(obj)`, which calls `JSON.stringify`.
- **/echo**: `express.raw({ type: () => true, limit: '8mb' })` on that one route. `type: '*/*'` only
  matches requests that carry a `Content-Type` header, so a body sent without one came back empty.
  The function form accepts every request. Bodies over 8 MiB get 413.
- **$12**: `pg.Pool` (max `ceil(PG_POOL / WORKERS)`) plus `jsonwebtoken.verify(token, secret,
  { algorithms: ['HS256'] })` in a small auth middleware. Friction points:
  - pg returns `bigint`/`count(*)` as strings by default. One global
    `pg.types.setTypeParser(INT8, parseInt)` fixes that.
  - Auth before id comes naturally from middleware order (`requireAuth`, then `express.json()`,
    then the handler).
  - `express.json()` errors go to the error handler. `err.type === 'entity.parse.failed'` maps to
    `malformed JSON body`, and Express 5 forwards rejected async handlers to it (500
    `internal server error`).
  - `strict: false` so that a valid non-object JSON body (`"x"`) is `body is required`, not
    `malformed JSON body`.
- **Cluster**: about 6 lines of `node:cluster` (fork `WORKERS` times in the primary, workers run the
  app). The `/ws/feed` ticker, the `/ws/trade` position and the RETAIN list are per worker.

## Defaults left on (idiomatic Express)

- `X-Powered-By: Express` and weak `ETag` on every `res.send`/`res.json` body. The ETag hashes the
  body, so `/echo` hashes up to 8 MiB per request. That's Express's default behaviour and was left
  as is.
- No logging middleware; Node's default request, headers and keep-alive limits otherwise.
