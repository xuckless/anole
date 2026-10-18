# Python WebTransport (aioquic) — ease-of-use notes

aioquic 1.7.0 (the release the `fastapi` server's Hypercorn uses) with uvloop 0.23.0,
Python 3.13.16. One file, `server.py`, about 100 lines with comments. Not FastAPI: no ASGI
server serves WebTransport (Hypercorn has HTTP/3 but no WebTransport, uvicorn has no
HTTP/3), so this is aioquic's own HTTP/3 layer, written the way aioquic's
`examples/http3_server.py` does it.

| Feature | What it took | Dependencies |
|---|---|---|
| `/wt/echo` | A `QuicConnectionProtocol` subclass that makes an `H3Connection(quic, enable_webtransport=True)` on ALPN h3 and dispatches its events: `HeadersReceived` with `:protocol webtransport` gets a 200, `WebTransportStreamDataReceived` on a bidirectional stream is written back with `send_stream_data(..., end_stream=stream_ended)`, `DatagramReceived` goes back with `send_datagram`, then `transmit()`; about 50 lines | aioquic 1.7.0 |
| `/plaintext` over h3 | 5 lines in the same dispatcher (`send_headers` + `send_data`); other paths get the JSON 404 | same |
| WORKERS > 1 | `os.fork()` per extra worker, each binding its own `SO_REUSEPORT` UDP socket and handing it to `create_datagram_endpoint(sock=...)` with aioquic's `QuicServer` (`serve()` takes no socket options), as `fastapi/h3_workers.py` does for Hypercorn | stdlib |

## Why it is draft-02

aioquic's `H3Connection` with `enable_webtransport=True` sends H3_DATAGRAM (0x33) and
`ENABLE_WEBTRANSPORT` (0x2b603742), takes `:protocol webtransport`, and parses the 0x41/0x54
stream signals. Anole's `tests/h3/run.sh` runs Anole's WebTransport client against
aioquic's server (`tests/h3/peer_server.py`).

## Friction

- **Event level only.** aioquic has no session or stream objects for WebTransport: the
  application tracks session IDs, tells bidirectional from unidirectional streams by
  stream ID, and calls `transmit()` itself.
- **`max_datagram_frame_size` must be set** in `QuicConfiguration`: `enable_webtransport`
  advertises H3_DATAGRAM either way, and without the QUIC transport parameter behind it
  clients close the connection (quic-go: "missing QUIC Datagram support").
- **Idle timeout.** aioquic's default is 60 s; `idle_timeout=120.0`.
- **Pure Python data path.** About 5 MB/s of 16 KiB echoes per process: one session does
  300 echoes/s at 3.3 ms, four sessions share the same 300/s at 13.7 ms.

## Also considered

`pywebtransport` 0.20.1 is a newer, Rust-backed WebTransport stack with its own
`ServerApp`, but it is niche (about 440 downloads a month against aioquic's 2.5 million),
so aioquic is the option most Python developers would reach for.
