# Video-call relay on Fiber v3 + webtransport-go

The contract is in `bench/videocall/SPEC.md`. Go 1.27.2, one process, Go's default GOMAXPROCS.

| Part | Library |
|---|---|
| HTTPS API and WebSockets (TCP `PORT`) | github.com/gofiber/fiber/v3 v3.6.1 (fasthttp v1.75.0), github.com/gofiber/contrib/v3/websocket v1.2.8 (fasthttp/websocket v1.5.12) |
| WebTransport and HTTP/3 (UDP `PORT`) | github.com/quic-go/webtransport-go v0.10.0 (the last draft-02 release) on github.com/quic-go/quic-go v0.59.0 |
| Media compression | `compress/flate`, `flate.DefaultCompression`, raw DEFLATE |

Files: `main.go` (startup, HTTP API), `hub.go` (users, lobby, calls, chat), `media.go`
(relay and deflate), `ws.go`, `wt.go`.

## How it works

- All state sits in one `Hub` behind a `sync.Mutex`. Under it, a handler only changes
  state and collects the outgoing control messages (`call`, `chat`, `peer_left`) as
  recipient + bytes; after unlocking it sends them, each through the recipient
  connection's own write lock. `hello` is sent before the user joins the lobby. Media:
  the peer is looked up under the mutex, then the message is compressed and written
  outside it. A slow socket so only blocks writers to that connection.
- Each connection allows one writer at a time: a mutex per WebSocket connection; on
  WebTransport, a mutex for the control stream and one per lazily opened media stream.
- Deflate: `flate.Writer`s come from a `sync.Pool`; each message gets `Reset` onto a fresh
  buffer, `Write`, `Close`, so every message is an independent raw DEFLATE stream, at
  level 6, inline in the receiving connection's handler. The pool is the usual Go idiom
  here because a `flate.Writer` allocates several hundred KB.
- The 1 MiB limit: `SetReadLimit(1 MiB)` on the WebSocket, so the library closes with 1009;
  on WebTransport, a frame length over 1 MiB closes the session. It applies to text
  messages as well.
- WebSocket compression (permessage-deflate) is off, the contrib default.
- The draft-02 client patch (`bench/tools/wtload/third_party/webtransport-go/PATCH.txt`)
  only changes the client's SETTINGS, so the server uses upstream v0.10.0 unchanged, as
  `bench/servers/gohttp-wt` does.

## Deviations and choices

- `Content-Type` is Fiber's default for `c.JSON`, `application/json; charset=utf-8`.
- quic-go keeps its defaults (30 s idle timeout); the bench client sends keep-alives.
  `CheckOrigin` allows any origin, since the load client sends none.
- A `leave` while not in a call is ignored (the spec doesn't say). A non-upgrade `GET /ws`
  with a valid token gets 426. The 409 body is `{"error":"already connected"}`.
- `sent_us` is decoded as an int64 and written back as one; a non-integer `sent_us` gets
  `bad message`. Chat length is counted in Unicode code points.
- Each user's control messages from one operation keep their order. Two operations on
  different goroutines can deliver theirs to a shared user in either order (e.g.
  `peer_left` from one and `call` from another), since sending happens after unlocking.
- The UDP side also answers `GET /health` over HTTP/3.
