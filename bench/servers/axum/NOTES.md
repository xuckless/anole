# Axum — ease-of-use notes

Axum 0.8.9 on tokio 1.53.3 + hyper 1.12.0, built with Rust 1.99.1
(`rust:1.99.1-slim-trixie`), `cargo build --release --locked` with the default release
profile (opt-level 3, no LTO, 16 codegen units, no PGO, no `target-cpu`). The runtime image
is `gcr.io/distroless/cc-debian13:nonroot` (62 MB, of which the binary is 14 MB).

Source: 645 non-blank, non-comment lines (`main.rs` 67, `routes.rs` 128, `ws.rs` 144,
`twelve.rs` 192, `http3.rs` 71, `grpc.rs` 33, `build.rs` 10). The gRPC code is generated
at build time by `build.rs` (tonic-prost-build), so nothing generated is committed. 19
direct dependencies and 262 crates in the resolved graph (`Cargo.lock`).

| Mode / feature | What it took | Dependencies |
|---|---|---|
| h1 | `TcpListener::bind` + `axum::serve(listener, app)`, 2 lines | axum (features `http2`, `ws`), tokio |
| h2c | Nothing beyond h1: with axum's `http2` feature, `axum::serve` uses hyper-util's auto builder, which detects the h2 preface on the same port | same |
| tls | `RustlsConfig::from_pem_file` + `axum_server::bind_rustls(..).serve(app.into_make_service())`, 3 lines. axum-server sets ALPN h2 + http/1.1 itself. One more line enables RFC 8441 (see below) | axum-server 0.8.0 (`tls-rustls`, which brings rustls with aws-lc-rs) |
| h3 | 71 lines of glue: rustls config (ALPN `h3`), quinn endpoint, h3 connection loop, then per request: collect the body, `Router::oneshot`, send the head, stream the body frames, `finish()` | h3 0.0.8, h3-quinn 0.0.10, quinn 0.11.12 (`runtime-tokio`, `rustls-aws-lc-rs`), rustls, http-body-util, bytes, tower (`util`) |
| gRPC | 33 lines (service struct, `unary_call`, `Server::builder().add_service().serve()`), plus a 10-line `build.rs` and `protoc` in the build image | tonic 0.14.6, tonic-prost 0.14.6, prost 0.14.4; build: tonic-prost-build 0.14.6 + Debian's protobuf-compiler |
| WebSockets | `WebSocketUpgrade` extractor + `on_upgrade`; echo 15 lines, feed (broadcast channel + interval ticker + `select!` per socket) about 45, trade (serde structs + `Mutex<HashMap>`) about 50 | built into axum (`ws` feature, tokio-tungstenite) |
| Static + Range | `nest_service("/static", ServeDir::new(dir))`, 1 line. Range/206 is built in | tower-http 0.7.1 (`fs`) |
| JSON | `axum::Json(struct)` with `#[derive(Serialize)]`; key order follows the struct fields | serde, serde_json |
| $12 | sqlx `query_as` into tuples, jsonwebtoken `decode` with `Validation::new(HS256)`, a small `ApiError` type implementing `IntoResponse` | sqlx 0.9.0 (`runtime-tokio`, `postgres`, no default features), jsonwebtoken 11.1.0 (`aws_lc_rs`) |

## Friction

- **HTTP/3 is not plug-and-play.** There is no `axum::serve` for QUIC. The h3 crate
  (still 0.0.x) gives you request heads and a byte stream, and you write the adapter to the
  tower `Service` yourself. Request bodies are buffered before the Router sees them (fine for
  this benchmark's 8 MiB cap; a streaming adapter would need a custom `Body`). WebSockets
  don't work over h3 (no RFC 9220). quinn's idle timeout defaults to 30 s and the spec wants
  75 s or more, so the transport config sets 120 s (3 lines).
- **Crypto-provider choice.** rustls 0.23 picks a process-wide provider only when exactly
  one is compiled in. axum-server's `tls-rustls` brings aws-lc-rs, while quinn's default
  features bring ring, so quinn is built with `default-features = false` and
  `rustls-aws-lc-rs`. Otherwise `ServerConfig::builder()` panics at runtime.
  jsonwebtoken 10+ also makes you choose a backend (`aws_lc_rs` or `rust_crypto`).
- **Feature flags matter.** axum's default features have no `http2` (so no h2c) and no
  `ws`. axum's default body limit is 2 MiB, so `/echo` gets
  `DefaultBodyLimit::max(8 MiB)` on its route.
- **WebSockets over HTTP/2 (RFC 8441).** axum 0.8 supports it when the route uses `any(..)`
  instead of `get(..)`. `axum::serve` enables the extended CONNECT setting itself;
  axum-server doesn't, so TLS mode adds
  `server.http_builder().http2().enable_connect_protocol()`. Tested with a Node http2
  client on h2c and on TLS h2 (`ws_h2: true`).
- **Socket defaults differ between the two servers.** axum-server sets `TCP_NODELAY` on
  accepted sockets. `axum::serve` leaves it off (the docs show `ListenerExt::tap_io` to
  set it). The spec forbids hand-tuned socket options, so both run with their defaults.
- **gRPC code generation** needs `protoc` at build time (apt `protobuf-compiler` in the
  build stage). tonic 0.14 moved prost support into `tonic-prost` / `tonic-prost-build`.
  `generate_default_stubs(true)` keeps unimplemented RPCs out of the source (they answer
  `UNIMPLEMENTED`).
- **$12 details.** The token claims are deserialized as `serde_json::Value` with
  `#[serde(default)]`. With typed `String` fields, a missing `username` would fail inside
  `decode` and come out as `invalid or expired token` instead of `invalid token payload`.
  `Result<Json<Value>, JsonRejection>` as the extractor lets the handler check auth before
  reporting malformed JSON. jsonwebtoken's default 60 s `exp` leeway is kept. sqlx
  prepares and caches statements (its default).
- **404s.** `Router::fallback` gives the JSON 404. `ServeDir::not_found_service` reuses
  the same handler, so `/static/<missing>` is the JSON 404 too.
- **Workers.** A manual `tokio::runtime::Builder::new_multi_thread().worker_threads(WORKERS)`
  (`#[tokio::main]` can't read an env var). One process, so the sqlx pool gets
  `PG_POOL` connections in total, shared by all workers.
- **Static files** stream from `tokio::fs` in 64 KiB chunks. No sendfile.
- **Logging.** No tracing subscriber is installed, so there is no access log. Errors go to
  stderr with `eprintln!`.

## Build

`docker build -f bench/servers/axum/Dockerfile -t anole-bench/axum .` from the repository
root. BuildKit cache mounts hold the cargo registry and `target/`: a cold build takes
about 30 s on a 28-thread machine, and a rebuild after a source change about 5 s.
