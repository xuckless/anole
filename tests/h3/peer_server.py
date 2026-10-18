"""An independent HTTP/3 server (aioquic) for anole.h3's client.

    peer_server.py PORT CERT KEY

It issues session tickets, and takes 0-RTT on them.

/download?n=N  N bytes (i % 251)
/echo          the request body back
/trailers      "body" and the trailer x-checksum: abc
/wt            a WebTransport session (draft-02, extended CONNECT) that
               echoes: bidirectional streams on themselves, unidirectional
               ones on a stream of its own, datagrams; a datagram "close"
               closes it (code 7, "asked to"); a close from the client is
               printed ("wt closed CODE REASON")
anything else  404
"""
import asyncio
import sys

from aioquic.asyncio import QuicConnectionProtocol, serve
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.buffer import Buffer
from aioquic.h3.events import DataReceived, DatagramReceived, HeadersReceived, WebTransportStreamDataReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import ProtocolNegotiated

PATTERN = bytes(range(251))
CLOSE_SESSION = 0x2843


def capsule(t, payload):
    buf = Buffer(capacity=16 + len(payload))
    buf.push_uint_var(t)
    buf.push_uint_var(len(payload))
    buf.push_bytes(payload)
    return buf.data


class Handler(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.h3 = None
        self.requests = {}
        self.sessions = {}
        self.uni = {}
        self.closed = set()

    def quic_event_received(self, event):
        if isinstance(event, ProtocolNegotiated):
            self.h3 = H3Connection(self._quic, enable_webtransport=True)
        if self.h3 is None:
            return
        for e in self.h3.handle_event(event):
            if isinstance(e, HeadersReceived) and dict(e.headers).get(b":protocol") == b"webtransport":
                self.sessions[e.stream_id] = bytearray()
                self.h3.send_headers(e.stream_id, [(b":status", b"200"), (b"sec-webtransport-http3-draft", b"draft02")])
                self.transmit()
            elif isinstance(e, DataReceived) and e.stream_id in self.sessions:
                self.sessions[e.stream_id].extend(e.data)
                if e.stream_ended:
                    self.session_ended(e.stream_id)
            elif isinstance(e, WebTransportStreamDataReceived):
                self.wt_data(e)
            elif isinstance(e, DatagramReceived):
                if e.data == b"close":
                    self.closed.add(e.stream_id)
                    self.h3.send_data(e.stream_id, capsule(CLOSE_SESSION, (7).to_bytes(4, "big") + b"asked to"), end_stream=True)
                else:
                    self.h3.send_datagram(e.stream_id, e.data)
                self.transmit()
            elif isinstance(e, HeadersReceived):
                self.requests[e.stream_id] = (dict(e.headers), bytearray())
                if e.stream_ended:
                    self.respond(e.stream_id)
            elif isinstance(e, DataReceived) and e.stream_id in self.requests:
                self.requests[e.stream_id][1].extend(e.data)
                if e.stream_ended:
                    self.respond(e.stream_id)

    def wt_data(self, e):
        if e.stream_id & 2 == 0:
            # Bidirectional: back on itself.
            self._quic.send_stream_data(e.stream_id, e.data, end_stream=e.stream_ended)
        else:
            self.uni.setdefault(e.stream_id, bytearray()).extend(e.data)
            if e.stream_ended:
                out = self.h3.create_webtransport_stream(e.session_id, is_unidirectional=True)
                self._quic.send_stream_data(out, bytes(self.uni.pop(e.stream_id)), end_stream=True)
        self.transmit()

    def session_ended(self, stream_id):
        buf = Buffer(data=bytes(self.sessions.pop(stream_id)))
        while not buf.eof():
            t, n = buf.pull_uint_var(), buf.pull_uint_var()
            payload = buf.pull_bytes(n)
            if t == CLOSE_SESSION:
                print("wt closed", int.from_bytes(payload[:4], "big"), payload[4:].decode(), flush=True)
        if stream_id not in self.closed:
            self.h3.send_data(stream_id, b"", end_stream=True)
            self.transmit()

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
