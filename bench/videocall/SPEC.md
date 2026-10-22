# Video-call app: the spec every server implements

A small 1:1 video-call service, written the way a real app would be: the
framework's usual idioms, its standard packages, default settings, no
hand-tuning. Users sign up, open one realtime connection, wait in a lobby,
get paired into a call, then stream 1080p H.264 video and Opus audio to their
peer and chat with them. The server relays the media and **compresses every
relayed media packet itself**, and the receiving client decompresses it.

The same logical protocol runs over two transports:

- **WebSocket** (`wss://`, TLS over TCP, HTTP/1.1 upgrade)
- **WebTransport** (HTTP/3 over QUIC, draft-02, the version browsers speak)

Each server image serves both transports at once: TCP 8443 for HTTPS and
WebSockets, UDP 8443 for HTTP/3 and WebTransport. A run uses one transport.

## Process and environment

| variable | default | meaning |
|---|---|---|
| `PORT` | `8443` | TCP and UDP port |
| `CERT`, `KEY` | `/certs/cert.pem`, `/certs/key.pem` | the shared self-signed ECDSA P-256 certificate (mounted read-only) |

- One process. Whatever the runtime does by default for its thread count:
  Go's GOMAXPROCS, tokio's default multi-thread runtime, Anole's default
  executors, and Bun's single thread. The container gets 1 CPU and 2 GB, with
  no swap.
- Logging is off, or warn and above.
- Ready means `GET https://127.0.0.1:8443/health` answers 200.
- All state is in memory: users, tokens, the lobby, calls and chat history.
  There is no database.

## HTTP API (TLS, TCP 8443)

- `GET /health` returns `200 {"status":"ok"}`.
- `POST /api/users` takes the body `{"name":"u17"}`.
  - `name` is 1–32 characters of `[A-Za-z0-9_-]`; otherwise
    `400 {"error":"invalid name"}`. Malformed JSON gets
    `400 {"error":"malformed JSON body"}`.
  - On success it returns `201 {"id":<n>,"name":"u17","token":"<32 lowercase hex>"}`.
  - Ids count up from 1. The token is 16 random bytes from a CSPRNG, in hex.
  - Names don't have to be unique.
- `GET /api/calls/:id/messages` needs `Authorization: Bearer <token>`. It
  returns `200 {"call_id":<n>,"messages":[<chat>...]}`, the call's history
  oldest first: at most the last 100 chat messages, each exactly as it was
  broadcast (see `chat` below).
  - A missing or unknown token gets `401 {"error":"unauthorized"}`.
  - A call that doesn't exist (or a non-numeric id) gets
    `404 {"error":"call not found"}`.
  - A caller who isn't one of the call's two users gets
    `403 {"error":"forbidden"}`.
  - Ended calls stay readable.
- Every JSON response has `Content-Type: application/json`.

## Realtime connection

- **WebSocket:** `GET /ws?token=<token>`, upgraded over HTTP/1.1 on TLS.
- **WebTransport:** an extended CONNECT to `/wt?token=<token>` (`:protocol`
  webtransport) on HTTP/3.

A missing or unknown token is refused before the upgrade with 401. A user
may hold one realtime connection at a time. A second one, while the first
is open, is refused with 409.

### Logical messages

The same messages are used on both transports. The framing for each
transport comes after.

**Text messages** are UTF-8 JSON objects, with no trailing newline.

| direction | message | when / effect |
|---|---|---|
| S→C | `{"type":"hello","user":{"id":7,"name":"u7"}}` | First message, as soon as the connection is open. The user then joins the lobby. |
| S→C | `{"type":"call","call_id":3,"peer":{"id":8,"name":"u8"}}` | Sent to both users when the lobby pairs them. |
| C→S | `{"type":"chat","text":"…","sent_us":1730000000000000}` | Chat with the peer. |
| S→C | `{"type":"chat","call_id":3,"id":12,"from":"u7","text":"…","sent_us":1730000000000000}` | Broadcast to **both** users of the call; the sender's copy is its ack. |
| C→S | `{"type":"leave"}` | Ends the current call. |
| S→C | `{"type":"peer_left","call_id":3}` | Sent to the remaining user when the call ends because the other left or disconnected. |
| S→C | `{"type":"error","error":"…"}` | On a bad client message. The connection stays open. |

How each message is handled:

- **Lobby:** first in, first out. Whenever two users are waiting, the two
  oldest are paired into a new call. Call ids count up from 1.
- **chat:**
  - The server copies `text` and `sent_us` unchanged.
  - `id` counts from 1 per call.
  - `from` is the sender's name.
  - The broadcast message is appended to the call's history, which keeps the
    last 100 messages.
  - The keys go out in the order shown.
  - `text` must be a string of 1–500 characters, otherwise
    `{"type":"error","error":"invalid chat"}`.
  - When the sender isn't in a call, the reply is
    `{"type":"error","error":"not in a call"}`.
- **leave, or a disconnect:** the call ends. The remaining user (if still
  connected) gets `peer_left` and goes back into the lobby. The user who sent
  `leave` also goes back into the lobby. A disconnected user leaves the lobby.
- Malformed JSON or an unknown `type` gets
  `{"type":"error","error":"bad message"}`.

**Binary media messages** have a 24-byte header, little-endian, followed by
the payload:

| offset | size | field |
|---|---|---|
| 0 | 1 | `kind`: 1 = video (one H.264 access unit, Annex B), 2 = audio (one 20 ms Opus packet) |
| 1 | 1 | `flags`: bit 0 = keyframe, bit 1 = **compressed** (set by the server only) |
| 2 | 2 | reserved, 0 |
| 4 | 4 | `seq`: per sender and kind, counting from 0 |
| 8 | 8 | `sent_us`: the sender's send time (Unix µs) |
| 16 | 4 | `crc32` (IEEE) of the original, uncompressed payload |
| 20 | 4 | `orig_len`: length of the original payload |
| 24 | … | payload |

How the server relays a media message:

- It applies to a message from a user who is in a call.
  1. Copy the 24-byte header, and set bit 1 of `flags`.
  2. Compress the payload as **raw DEFLATE** (RFC 1951: no zlib or gzip
     wrapper). Use the platform's standard deflate library at its **default
     level** (6 in all four stacks), with each message compressed on its own:
     a fresh stream ended with finish. Compress inline in the handler that
     received the message.
     - Anole: `anole.compression.zlib`.
     - Bun: `node:zlib` `deflateRawSync`, or `Bun.deflateSync`.
     - Go: `compress/flate`.
     - Rust: `flate2`.
  3. Send header + compressed payload to the peer.
- The server must not change `kind`, `seq`, `sent_us`, `crc32` or `orig_len`.
  It doesn't verify the CRC.
- Media from a user who isn't in a call is dropped silently.
- A client message with bit 1 already set is dropped.
- A media message over 1 MiB closes the connection: WebSocket close 1009, or
  WebTransport session close.
- Messages shorter than 24 bytes are dropped.
- The server drops nothing for flow control on its own initiative. It uses
  its library's default send behaviour (buffering or backpressure). It
  doesn't check whether frames are late.

### WebSocket framing

- Text messages are WebSocket text messages.
- Media messages are WebSocket binary messages, one media message each.
- permessage-deflate is **not** negotiated: the server answers with no
  extension. The compression is the app's own, as above.

### WebTransport framing

- **Control stream:** the client opens the first bidirectional stream right
  after the session is ready. All text messages, in both directions, go on
  it, each framed as `u32 LE length` + JSON. The server sends `hello` on it.
- **Client media:** the client opens two unidirectional streams, one for
  video and one for audio. Each carries media messages framed as
  `u32 LE length` + (header + payload). The server treats every incoming uni
  stream the same way: `kind` is read from each header.
- **Server media:** the server opens at most one unidirectional stream per
  `kind` to each user, lazily on the first media message of that kind for
  that user. It keeps the stream open for the rest of the session, across
  calls. The framing is the same as the client's.
- Datagrams aren't used.
- When the session ends (closed, the connection lost, or the CONNECT stream
  ends), it's treated as a disconnect.

## Quick check

`vcload -smoke` (bench/tools/vcload) runs the protocol end to end against
`https://127.0.0.1:8443`, with `-transport ws` or `-transport wt`, and prints
each check. A server passes when every check passes on the transports it
implements.

## Implementations

`bench/videocall/servers/<stack>/`, each with a Dockerfile built from the
repository root, giving the image `anole-bench/vc-<stack>`:

| stack | HTTP + WebSocket | WebTransport | deflate |
|---|---|---|---|
| anole | Anole v0.1.3 via `zig fetch` (default `full` profile: BoringSSL, HTTP/3), ReleaseSafe | Anole native | `anole.compression.zlib` (zlib-ng) |
| bun | `Bun.serve` (TLS, websocket) | @fails-components/webtransport, if it runs under Bun; otherwise N/A | node:zlib |
| fiber | Fiber v3 + gofiber/contrib websocket | webtransport-go v0.10.0 (draft-02) on quic-go | compress/flate |
| axum | axum 0.8 + axum-server (rustls) | wtransport 0.7 (refuses with 403/429: the crate has no 401/409) | flate2 (miniz_oxide) |
