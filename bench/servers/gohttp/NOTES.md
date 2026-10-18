# Go net/http — ease-of-use notes

Go 1.27.2 standard library `net/http` with Go 1.22 `ServeMux` patterns, plus
quic-go v0.64.0 (HTTP/3) and grpc-go v1.84.0. Source: 671 hand-written lines
(`main.go` 222, `ws.go` 190, `twelve.go` 228, `grpc.go` 31) and 3,986 generated lines
in `testpb/` (protoc 31.1, protoc-gen-go v1.36.12, protoc-gen-go-grpc v1.6.2; the
command is in `testpb/doc.go`).

| Mode / feature | What it took | Dependencies |
|---|---|---|
| h1 | `(&http.Server{Addr, Handler}).ListenAndServe()`, 2 lines | stdlib |
| h2c | `http.Protocols` with `SetHTTP1(true)` + `SetUnencryptedHTTP2(true)` (Go 1.24+), 4 lines. No `x/net/http2/h2c` needed any more | stdlib |
| tls | `ListenAndServeTLS(cert, key)`, 2 lines. h2 + http/1.1 ALPN are automatic | stdlib |
| h3 | `http3.Server{QUICConfig: MaxIdleTimeout 120 s}.ListenAndServeTLS` plus the TCP HTTPS server with `SetQUICHeaders` for Alt-Svc, 9 lines | quic-go v0.64.0 (+ quic-go/qpack) |
| gRPC | 31 lines (service struct, `UnaryCall`, listen, register) plus code generation with protoc and two plugins | grpc-go v1.84.0, protobuf v1.36.12 |
| WebSockets | `websocket.Accept(w, r, opts)` per handler; echo is 15 lines, feed (hub + reader goroutine) about 65, trade about 25 | coder/websocket v1.8.15 |
| Static + Range | `http.StripPrefix("/static", http.FileServer(http.Dir(dir)))`, 1 line. Range/206 is built in | stdlib |
| $12 | `pgxpool` + `golang-jwt` + `json.NewDecoder`; auth is a small handler wrapper | pgx/v5 v5.11.0, golang-jwt/v5 v5.3.1 |

## Friction

- **h3's idle timeout.** quic-go closes idle connections after 30 s by default, and the
  spec wants 75 s or more. The one-call `http3.ListenAndServeTLS` takes no config, so
  the code spells out what it does (UDP server + TCP server adding Alt-Svc) with
  `quic.Config{MaxIdleTimeout: 120 * time.Second}`.
- **gRPC needs code generation.** The protos have no `go_package`, so `protoc` needs
  `M` mappings for all three files. The generated code is committed, the usual Go
  practice, so the Docker build doesn't need protoc.
- **coder/websocket defaults.** It rejects cross-origin handshakes (gorilla and
  fasthttp/websocket don't check Origin), so it is given `OriginPatterns: ["*"]`. Its
  read limit is 32 KiB, raised to 8 MiB to match `/echo`. `CloseRead` closes the
  connection when the client sends a data message, and the spec says those are ignored,
  so the feed runs its own read-and-discard goroutine.
- **JSON 404.** `ServeMux`'s own 404 is plain text, so a catch-all `"/"` pattern
  returns `{"error":"not found"}`. `http.FileServer` has no hook for missing files:
  `/static/<missing>` is still a 404, but with the text body `404 page not found`.
- **`json.NewEncoder(w).Encode` adds a trailing newline**, so responses use
  `json.Marshal` + `Write` through a 10-line `writeJSON` helper. `encoding/json`
  escapes `<`, `>` and `&` (allowed by the $12 spec).
- h2c mode also accepts HTTP/1.1 on the same port (`SetHTTP1(true)`), so the WebSocket
  routes, which upgrade over HTTP/1.1, still work there.
- One process with `GOMAXPROCS = WORKERS`, so the pgx pool is `PG_POOL` connections in
  total.
