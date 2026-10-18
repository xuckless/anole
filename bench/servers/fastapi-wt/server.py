"""The Python WebTransport bench server: /wt/echo (bench/SPEC.md,
"WebTransport") on aioquic's H3Connection with enable_webtransport, which
speaks draft-02 (SETTINGS_ENABLE_WEBTRANSPORT, :protocol webtransport,
RFC 9297 datagrams), plus GET /plaintext over the same HTTP/3 endpoint for
the readiness probe.

MODE=h3: WebTransport and HTTP/3 on UDP HTTPS_PORT (default 8443).

No ASGI server serves WebTransport (Hypercorn, which serves this bench's
FastAPI app over HTTP/3, has no WebTransport), so this is aioquic itself,
the way aioquic's own examples/http3_server.py does it. WORKERS > 1 runs
one process per worker, each on its own socket in a SO_REUSEPORT group, as
h3_workers.py does for Hypercorn.
"""

import asyncio
import os
import socket
import sys

import uvloop
from aioquic.asyncio import QuicConnectionProtocol
from aioquic.asyncio.server import QuicServer
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DatagramReceived, H3Event, HeadersReceived, WebTransportStreamDataReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import ProtocolNegotiated, QuicEvent

NOT_FOUND = b'{"error":"not found"}'


class EchoProtocol(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self._http: H3Connection | None = None
        self._sessions: set[int] = set()

    def quic_event_received(self, event: QuicEvent) -> None:
        if isinstance(event, ProtocolNegotiated) and event.alpn_protocol in H3_ALPN:
            self._http = H3Connection(self._quic, enable_webtransport=True)
        if self._http is not None:
            for h3_event in self._http.handle_event(event):
                self._h3_event(h3_event)
            self.transmit()

    def _h3_event(self, event: H3Event) -> None:
        if isinstance(event, HeadersReceived):
            headers = dict(event.headers)
            method, path = headers.get(b":method"), headers.get(b":path")
            if method == b"CONNECT" and headers.get(b":protocol") == b"webtransport":
                if path == b"/wt/echo":
                    self._sessions.add(event.stream_id)
                    self._http.send_headers(event.stream_id, [(b":status", b"200")])
                else:
                    self._http.send_headers(event.stream_id, [(b":status", b"404")], end_stream=True)
            elif method == b"GET" and path == b"/plaintext":
                self._respond(event.stream_id, b"200", b"text/plain", b"Hello, World!")
            else:
                self._respond(event.stream_id, b"404", b"application/json", NOT_FOUND)
        elif isinstance(event, WebTransportStreamDataReceived):
            # Bidirectional streams only (client-initiated: id % 4 == 0): every
            # byte back on the same stream, ending ours when theirs ends.
            if event.stream_id % 4 == 0 and event.session_id in self._sessions:
                self._quic.send_stream_data(event.stream_id, event.data, end_stream=event.stream_ended)
        elif isinstance(event, DatagramReceived):
            if event.stream_id in self._sessions:
                self._http.send_datagram(event.stream_id, event.data)

    def _respond(self, stream_id: int, status: bytes, content_type: bytes, body: bytes) -> None:
        self._http.send_headers(
            stream_id,
            [(b":status", status), (b"content-type", content_type), (b"content-length", str(len(body)).encode())],
        )
        self._http.send_data(stream_id, body, end_stream=True)


async def serve(configuration: QuicConfiguration, port: int) -> None:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    sock.bind(("0.0.0.0", port))
    loop = asyncio.get_running_loop()
    await loop.create_datagram_endpoint(
        lambda: QuicServer(configuration=configuration, create_protocol=EchoProtocol), sock=sock
    )
    await asyncio.Future()


def main() -> None:
    if os.environ.get("MODE", "h1") != "h3":
        print(f"unsupported MODE {os.environ.get('MODE', 'h1')!r}: this server only does h3 (WebTransport)", file=sys.stderr)
        sys.exit(3)
    port = int(os.environ.get("HTTPS_PORT", "8443"))
    workers = int(os.environ.get("WORKERS", "1"))
    configuration = QuicConfiguration(
        is_client=False,
        alpn_protocols=H3_ALPN,
        max_datagram_frame_size=65536,
        idle_timeout=120.0,  # aioquic's default is 60 s; the spec wants 75 s or more
    )
    configuration.load_cert_chain(
        os.environ.get("CERT_FILE", "/certs/cert.pem"), os.environ.get("KEY_FILE", "/certs/key.pem")
    )
    children = []
    for _ in range(workers - 1):
        pid = os.fork()
        if pid == 0:
            children = []
            break
        children.append(pid)
    try:
        uvloop.run(serve(configuration, port))
    except KeyboardInterrupt:
        pass
    finally:
        for pid in children:
            os.kill(pid, 15)


if __name__ == "__main__":
    main()
