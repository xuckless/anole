# Anole: ease-of-use notes

Anole at this commit, Zig 0.17.0, `-Doptimize=ReleaseFast -Dcpu=baseline`,
built as an application that depends on Anole (`build.zig` uses
`anole.addApp`, as `tests/consumer` does). Runtime image: `debian:trixie-slim`
plus two static-ish binaries (`anole-bench`, `grpc-interop-server`).

## Source size

| File | Code lines (no blanks/comments) | What |
|---|---:|---|
| `src/main.zig` | 202 | modes, options, raw routes, GC routes, static, WebSockets (echo, feed ticker, trade) |
| `src/twelve.zig` | 156 | the $12 routes: JWT, five handlers |
| `src/pg.zig` | 227 | a Postgres wire-protocol client with pools (Anole has none) |
| `build.zig` | 8 | `anole.addApp` |
| **Total** | **593** | 366 without the Postgres client |

## Per protocol

| Mode / feature | What it took | Dependencies |
|---|---|---|
| h1 (+ h2c on the same port) | `.http = .{ .address = "0.0.0.0", .port = p }` | anole |
| tls (h2 + http/1.1) | `.https = .{ .port = p, .cert = .fromFiles(cert, key) }` | anole (BoringSSL built in) |
| h3 | `.http3 = .{}` beside `.https` | anole (ngtcp2 + nghttp3 built in) |
| gRPC | the interop server; a service of your own is `addApp(.protos = ...)` plus `app.grpc(...)`, code generated in `zig build` | anole (zig-protobuf, protoc pinned) |
| WebSockets | `app.ws(path, handler)`; echo 2 lines, feed (Rooms + ticker task) 25, trade 30. Also over HTTP/2 (RFC 8441) with no extra code | anole |
| Static + Range | `try app.staticDir("/static", dir, .{})`, 1 line; sendfile on cleartext | anole |
| JSON | `res.json(value)` (std.json), key order from the struct | anole |
| $12 | `anole.auth.verify` for HS256, `req.bind`/`std.json` for bodies, and a hand-written Postgres client | anole |

Every protocol in the matrix is one option in `anole.Server`'s init. No other
stack here serves h1, h2c, h2, h3, WebSockets over h1 and h2, and gRPC from
one dependency and one listener configuration.

## Friction (things that cost time writing this server)

- **No Postgres client.** The $12 routes needed `src/pg.zig`, about 230
  lines: startup, extended query protocol, prepared statements, a pool per
  executor. Every other stack used a mature driver in one line. This is the
  biggest ease-of-use gap the benchmark found.
- **Defaults that the benchmark had to lift:**
  - `timeout.request` (30 s) covers the whole response, so a long video
    stream or a long-lived WebSocket is cut at 30 s unless it is set to null
    (or the handler calls `req.setTimeout`).
  - `max_connections` defaults to 10 000; the connection tests and the $12
    challenge (15 000+ users) go past it.
  - `timeout.keepalive` 60 s (the challenge wants 65 s or more).
  - `request.max_body_size` 1 MiB (the others: Fiber 4 MiB, Axum 2 MiB,
    Express 100 KB for JSON).
- **Type names to find:** the certificate type is `anole.Cert`
  (`anole.tls.Cert` does not exist); executor counts are
  `.executors = .exact(n)`, a function on zio's enum, not `.{ .exact = n }`;
  a status for a helper's parameter is `anole.http.Status`, not
  `std.http.Status`, though the two look alike in errors ("expected type
  'http.Status', found 'http.Status'").
- **`ContentType` has no `binary`/`octet_stream` member**; `.unknown` maps
  to `application/octet-stream`.
- **A drift-free ticker** needs `std.Io.Timeout{ .deadline = ... }.sleep`;
  `io.sleep(10 ms)` in a loop drifts to ~915 ticks/s.
- `pub const std_options = anole.std_options;` and
  `pub const zio_options = anole.zio_options;` both have to be declared in
  the root file.
