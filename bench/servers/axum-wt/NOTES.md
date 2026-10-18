# Rust WebTransport (wtransport) — ease-of-use notes

wtransport 0.7.2 (wtransport-proto 0.7.2) on quinn 0.11.12 (rustls 0.23.46 with ring,
wtransport's default), tokio 1.53.3, Rust 1.99.1. One file, `src/main.rs`, about 65
lines with comments; 2 direct dependencies, 148 crates in `Cargo.lock`.

| Feature | What it took | Dependencies |
|---|---|---|
| `/wt/echo` | `ServerConfig::builder().with_bind_address().with_identity(Identity::load_pemfiles()).max_idle_timeout()`, `Endpoint::server`, an `accept()` loop, then per session `request.path()` check, `accept()`, and a `select!` over `accept_bi()` (`tokio::io::copy` + `finish()`) and `receive_datagram()`/`send_datagram()`, about 40 lines | wtransport 0.7.2, tokio |
| `/plaintext` over h3 | **Not possible.** wtransport owns the QUIC endpoint and its driver answers any request that is not an extended CONNECT with STOP_SENDING H3_REQUEST_REJECTED before the application sees it (`curl --http3-only` fails with `ngtcp2_conn_writev_stream returned error: ERR_CLOSING`). The axum Router (h3 + h3-quinn in the `axum` server) can't share the port either. Readiness probe: `wtload -mode sessions -n 1` | - |

## Why wtransport 0.7.2 is draft-02

wtransport-proto 0.7.2's `settings.rs` sends `SETTINGS_ENABLE_WEBTRANSPORT` 0x2b603742,
`SETTINGS_WEBTRANSPORT_MAX_SESSIONS` 0xc671706a (the draft-02..05 code point), H3_DATAGRAM
0x33 and ENABLE_CONNECT_PROTOCOL; `session.rs` requires `:protocol` = `webtransport`
exactly; streams use 0x41/0x54 and the 0x2843 close capsule. It is the latest release
(2026-08-11) and targets browsers.

## Friction

- **Idle timeout.** quinn's default is 30 s; `max_idle_timeout(Some(120 s))` (returns a
  `Result`).
- **No HTTP routing.** Paths are checked by hand (`request.path()`, `not_found()`).
- Each session is its own task; streams are spawned per stream so a slow one doesn't
  hold up the others.
