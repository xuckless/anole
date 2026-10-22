# vc-axum: notes

Rust 1.99.1, edition 2024. `src/main.rs` (setup, HTTP API), `src/state.rs` (users,
lobby, calls, chat, media relay), `src/ws.rs` (WebSocket), `src/wt.rs` (WebTransport).

| crate | version | use |
|---|---|---|
| axum | 0.8.9 (`ws`) | router, HTTP API, WebSocket (tokio-tungstenite 0.29.0) |
| axum-server | 0.8.0 (`tls-rustls`) | HTTPS + WSS on TCP PORT (rustls 0.23.46, aws-lc-rs) |
| wtransport | 0.7.2 | WebTransport draft-02 on UDP PORT (quinn 0.11.12, ring) |
| tokio | 1.53.3 | `#[tokio::main]`, default multi-thread runtime |
| flate2 | 1.1.10 (default backend, miniz_oxide) | raw DEFLATE, `DeflateEncoder` + `Compression::default()` |
| serde / serde_json | 1.0.229 / 1.0.154 | JSON (structs, so keys go out in declaration order) |
| getrandom | 0.3.4 | 16-byte tokens from the OS CSPRNG |
| rustls | 0.23.46 | only to install aws-lc-rs as the process default provider |
| bytes, futures-util | 1.12.1, 0.3.34 | media buffers, splitting the WebSocket |

## Design

- One `std::sync::Mutex` around all state; nothing awaits while holding it.
- Each connection gets an **unbounded** tokio mpsc channel to its own writer task
  (WebSocket sink, or the WebTransport control stream plus lazily opened uni
  streams). Unbounded so the app itself never drops or blocks; backpressure is
  whatever the socket/QUIC stream gives the writer.
- Media is compressed inline in the reading task: header copied into a `Vec`, bit 1
  of `flags` set, then a fresh `DeflateEncoder` over that `Vec`, `finish()`. The
  peer's sender is looked up under the lock first; compression runs outside it.
- WebTransport: one task per session, select over the control-stream reader, the
  uni-stream acceptor (one task per incoming uni stream) and `closed()`; any of
  them ending is a disconnect.
- Defaults everywhere: axum's WebSocket limits (64 MiB message; the 1 MiB media
  limit is checked by the app, close 1009), quinn's transport config (30 s idle
  timeout), axum-server's ALPN (h2, http/1.1).
- Both rustls providers end up compiled in (axum-server pulls aws-lc-rs,
  wtransport ring), so `main` installs aws-lc-rs as the process default before
  axum-server builds its config. wtransport passes ring explicitly.

## Deviations

- **WebTransport refusal codes.** wtransport 0.7.2's `SessionRequest` can only
  answer 200 (`accept`), 403 (`forbidden`), 404 (`not_found`) or 429
  (`too_many_requests`); there is no public way to send another status. A
  missing/unknown token gets **403** instead of 401, and a second connection
  **429** instead of 409. WebSocket returns 401/409 as specified. `vcload -smoke
  -transport wt` fails exactly those two checks.
- An oversized WebTransport frame closes the session with code 0, reason
  "message too big". Text frames on the control stream share the 1 MiB cap.
