# Node WebTransport (@fails-components/webtransport) — ease-of-use notes

@fails-components/webtransport 1.6.8 with @fails-components/webtransport-transport-http3-quiche
1.6.8 (a native addon around Chromium's QUICHE, prebuilt for linux-x64 and shipped in the
npm tarball), Node 24.22.0. One file, `server.mjs`, about 60 lines with comments. Not
Fastify: Fastify has neither HTTP/3 nor WebTransport, and this is the only maintained
WebTransport server for Node (about 525 000 downloads a month; libp2p uses it).

| Feature | What it took | Dependencies |
|---|---|---|
| `/wt/echo` | `new Http3Server({port, host, secret, cert, privKey})`, `startServer()`, then a reader on `sessionStream('/wt/echo')`; per session `await ready`, `datagrams.readable.pipeTo(datagrams.createWritable())`, and a reader on `incomingBidirectionalStreams` with `stream.readable.pipeTo(stream.writable)` (pipeTo closes our side when theirs ends) | @fails-components/webtransport 1.6.8 (+ the quiche transport) |
| `/plaintext` over h3 | **Not possible.** The native layer answers every non-WebTransport request itself with 404 `file not found` (`Http3ServerStream::SendNotFoundResponse`). Readiness probe: `wtload -mode sessions -n 1` (or accept any HTTP/3 status) | - |
| WORKERS > 1 | `node:cluster`; each worker passes `quicheNodeSocketOptions: {reusePort: true}` so it binds its own socket in one SO_REUSEPORT group (two sockets on the port with WORKERS=2, checked with `ss -ulnp`) | - |

## Why it is draft-02

QUICHE negotiates the WebTransport version from both sides' SETTINGS; the addon's server
session returns `kDefaultSupportedWebTransportVersions` (QUICHE's draft-02 and draft-07,
what Chrome speaks) and `HttpDatagramSupport::kRfcAndDraft04`. With wtload it negotiates
draft-02 (wtload sends 0x2b603742 only).

## Friction

- **The client must announce WebTransport.** QUICHE only treats an extended CONNECT as a
  session when the client's SETTINGS carry `SETTINGS_ENABLE_WEBTRANSPORT` = 1 (draft-02
  says both endpoints send it, and Chrome does). No draft-02 release of webtransport-go's
  client sends it, so it got 404; wtload carries a one-line patch (see
  `bench/tools/wtload/third_party/webtransport-go/PATCH.txt`).
- **glibc 2.38.** The prebuilt addon fails to load on bookworm (`GLIBC_2.38' not found`),
  so this image is `node:24.22.0-trixie-slim`, unlike the other Node images.
- **Idle timeout is not configurable** from JS (the options cover stream limits and flow
  control windows only). QUICHE's default kept sessions through 80 s of silence
  (`wtload -mode idle -d 80s`: 2 of 2 alive).
- `datagrams.writable` logs "deprecated" on every session; `createWritable()` doesn't.
- The library's own echo example awaits each stream's `pipeTo` before accepting the next,
  which serializes streams; here each pipe runs on its own.
- Throughput is per connection and modest: about 10 MB/s of 16 KiB echoes per session
  whether 1 or 16 streams are in flight (small echoes take 0.2 ms), so the cost is in the
  addon's data path, not in the echo code.
