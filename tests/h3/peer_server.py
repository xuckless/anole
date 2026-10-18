"""An independent HTTP/3 server (aioquic) for anole.h3's client.

    peer_server.py PORT CERT KEY

It issues session tickets, and takes 0-RTT on them.

/download?n=N  N bytes (i % 251)
/echo          the request body back
/trailers      "body" and the trailer x-checksum: abc
anything else  404
"""
import asyncio
import sys

from aioquic.asyncio import QuicConnectionProtocol, serve
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import ProtocolNegotiated

PATTERN = bytes(range(251))


class Handler(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.h3 = None
        self.requests = {}

    def quic_event_received(self, event):
        if isinstance(event, ProtocolNegotiated):
            self.h3 = H3Connection(self._quic)
        if self.h3 is None:
            return
        for e in self.h3.handle_event(event):
            if isinstance(e, HeadersReceived):
                self.requests[e.stream_id] = (dict(e.headers), bytearray())
                if e.stream_ended:
                    self.respond(e.stream_id)
            elif isinstance(e, DataReceived) and e.stream_id in self.requests:
                self.requests[e.stream_id][1].extend(e.data)
                if e.stream_ended:
                    self.respond(e.stream_id)

    def respond(self, stream_id):
        headers, body = self.requests.pop(stream_id)
        path = headers.get(b":path", b"").decode()
        trailers = None
        status = b"200"
        if path.startswith("/download?n="):
            n = int(path.split("=", 1)[1])
            data = (PATTERN * (n // len(PATTERN) + 1))[:n]
        elif path == "/echo":
            data = bytes(body)
        elif path == "/trailers":
            data = b"body"
            trailers = [(b"x-checksum", b"abc")]
        else:
            status, data = b"404", b"not found"
        self.h3.send_headers(stream_id, [(b":status", status), (b"content-length", str(len(data)).encode())])
        self.h3.send_data(stream_id, data, end_stream=trailers is None)
        if trailers:
            self.h3.send_headers(stream_id, trailers, end_stream=True)
        self.transmit()


async def main():
    port, cert, key = int(sys.argv[1]), sys.argv[2], sys.argv[3]
    config = QuicConfiguration(alpn_protocols=H3_ALPN, is_client=False, max_datagram_frame_size=65536)
    config.load_cert_chain(cert, key)
    tickets = {}
    await serve(
        "127.0.0.1",
        port,
        configuration=config,
        create_protocol=Handler,
        session_ticket_handler=lambda t: tickets.__setitem__(t.ticket, t),
        session_ticket_fetcher=lambda label: tickets.pop(label, None),
    )
    print("listening", flush=True)
    await asyncio.Future()


asyncio.run(main())
