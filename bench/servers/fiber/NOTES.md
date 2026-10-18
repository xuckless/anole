# Fiber v3 — ease-of-use notes

Go Fiber v3.6.1 on fasthttp v1.75.0, Go 1.27.2. Source: 540 lines of Go
(`main.go` 166, `ws.go` 168, `twelve.go` 206), no generated code.

| Feature | What it took | Dependencies |
|---|---|---|
| h1 | `app.Listen(addr, fiber.ListenConfig{DisableStartupMessage: true})`, 1 line | fiber/v3 |
| tls | `CertFile` + `CertKeyFile` in `ListenConfig`, plus a 1-line `TLSConfigFunc` to set `NextProtos` (4 lines) | none extra |
| h2c, h2, h3, gRPC | not available: fasthttp speaks HTTP/1.1 only | — |
| WebSockets | `websocket.New(func(*websocket.Conn))` per route; echo is 12 lines, feed (hub + reader goroutine) about 60, trade about 20 | gofiber/contrib/v3/websocket v1.2.8 (fasthttp/websocket v1.5.12) |
| Static + Range | `static.New(dir, static.Config{ByteRange: true, NotFoundHandler: ...})`, 6 lines | none extra |
| $12 | `pgxpool` + `golang-jwt` + `c.Bind().JSON`; auth is a route middleware that puts the user in `Locals` | pgx/v5 v5.11.0, golang-jwt/v5 v5.3.1 |

## Friction

- **No ALPN with `CertFile`/`CertKeyFile`.** Fiber builds the `tls.Config` without
  `NextProtos`, so the handshake carries no ALPN at all. The spec asks for
  `http/1.1`, so `TLSConfigFunc` sets it.
- **Range is opt-in.** The static middleware serves byte ranges only with
  `ByteRange: true`. Without it you get a 200 with the whole file.
- **Static 404s have an empty body** (`PathNotFound` sets only the status).
  `NotFoundHandler` returning `fiber.ErrNotFound` sends them through the app's
  `ErrorHandler`, so they get the JSON 404 like every other unknown path.
- **404 and errors** go through one `ErrorHandler` in `fiber.Config`. That's where the
  `{"error":"not found"}` body comes from (Fiber's default is `Cannot GET /x` as text).
- **Body limit** defaults to 4 MiB, so `BodyLimit: 8 << 20` is needed for `/echo`.
- `c.Body()`/`c.Params()` point into fasthttp's reusable buffers, which are valid only
  during the handler. That's fine here: `c.Send(c.Body())` and string concatenation copy
  before the handler returns.
- WebSocket handlers run on a goroutine that gorilla-style rules restrict to one reader
  and one writer. The feed needs its own reader goroutine to notice the close, plus a
  per-subscriber buffered channel. A subscriber that falls 1024 ticks (1 s) behind is
  dropped. The contrib package has no default read limit; `SetReadLimit(8 MiB)`
  matches `/echo`.
- The default JSON encoder is `encoding/json`, which escapes `<`, `>` and `&` as
  `<` and so on. The $12 spec allows that.
- One process with `GOMAXPROCS = WORKERS` (Prefork is off), so the pgx pool is
  `PG_POOL` connections in total.
