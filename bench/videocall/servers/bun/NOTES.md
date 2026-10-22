# Bun video-call server: notes

Bun 1.4.3 (`oven/bun:1.4.3-slim`, Debian trixie), TypeScript run directly by Bun.

| file | what |
|---|---|
| `server.ts` | `Bun.serve` with `tls` (HTTPS + WebSocket on TCP `PORT`), `routes` for the HTTP API, Bun's built-in `websocket` handler (`perMessageDeflate: false`) |
| `app.ts` | users, tokens, lobby, calls, chat, history and the media relay (transport-independent) |
| `webtransport.ts` | WebTransport on UDP `PORT` |

## Libraries

- HTTP, TLS, WebSocket: Bun's built-ins, default settings (no `maxPayloadLength`,
  `backpressureLimit` or idle timeout changes).
- Deflate: `node:zlib` `deflateRawSync(payload)` at the default level, one call per
  relayed message, inline in the message handler.
- Tokens: `node:crypto` `randomBytes(16).toString('hex')`.
- WebTransport: `@fails-components/webtransport` 1.6.8 with
  `@fails-components/webtransport-transport-http3-quiche` 1.6.8 (Chromium's QUICHE in a
  napi addon; draft-02, the version browsers speak). **It loads and works under Bun
  1.4.3**: the vcload smoke passes over `-transport wt` (see the caveat below).

## WebTransport under Bun: what it took

- The addon's `install` script (`prebuild-install`, fetching the prebuilt linux-x64
  `webtransport.node`) is a lifecycle script, which Bun blocks by default ("Blocked 1
  postinstall"); without it the package has no binary. `trustedDependencies` in
  package.json lets it run. Bun's `node` shim runs the script; no Node install needed.
- The slim Bun image is trixie (glibc 2.41), so the addon's glibc 2.38 requirement is met.
- Token checks before the session is accepted use `server.setRequestCallback`: it
  returns `status: 401` (unknown token), `409` (already connected) or `404` (other
  paths), and on success rewrites `:path` to `/wt` and passes the user as `userData`.
- Writes go through each stream's WHATWG writer without awaiting (the writer's queue
  is the library's default buffering). The per-kind server uni stream is opened lazily
  with `createUnidirectionalStream()`; messages that arrive while it opens are queued
  and written in order.
- The fails-components *client* could not be used for testing: with
  `serverCertificateHashes` its handshake fails ("Opening handshake failed.") on the
  bench certificate, which is valid for 10 years (QUICHE's fingerprint verifier accepts
  only certificates valid for at most 14 days, as browsers do). Testing used vcload.

## Choices where the spec is silent

- "Over 1 MiB" is taken as the whole media message (header + payload) longer than
  1 048 576 bytes. WebSocket: `ws.close(1009)` in the handler (Bun's default
  `maxPayloadLength` is 16 MiB). WebTransport: as soon as a frame's length prefix
  says more than 1 MiB, `session.close()`; text frames on the control stream have
  the same limit.
- `leave` while not in a call answers `{"type":"error","error":"not in a call"}`.
- A chat with an invalid `text` is answered `invalid chat` before the in-call check.
  `text` length is counted in Unicode code points (1–500).
- Media of any `kind` is relayed (on WT, one server stream per kind seen).
- Refused upgrades get a JSON body: `{"error":"unauthorized"}` (401),
  `{"error":"already connected"}` (409). Unknown routes get 404 `{"error":"not found"}`.
- Bidirectional streams after the control stream are cancelled.
- Logging: one `console.warn` line at startup; nothing per request.

## Caveat for clients (WebTransport)

The server learns of the control stream only when the client's first bytes on it
arrive (a QUIC stream is invisible until a STREAM frame is sent; webtransport-go
writes its stream header lazily on the first `Write`). A client that opens the
control stream and waits for `hello` without writing will wait until it first
sends something. No server can work around this; the client has to write on the stream
(webtransport-go: `ctl.Write(nil)` right after `OpenStreamSync` sends the header).
