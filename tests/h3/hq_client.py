"""An hq-interop (HTTP/0.9 over QUIC) client on aioquic's QUIC stack, for
checking Anole's hq mode (tests/h3/interop.zig). Raw stream data, so a
request can lack its newline or its FIN.

    python3 tests/h3/hq_client.py HOST PORT REQUEST...

Each REQUEST is a Python-escaped string sent on its own stream, all on one
connection; a "nofin:" prefix leaves the stream open. Prints one line per
request, in order: "bytes N sum S" when the response ended with a FIN, or
"reset" when the server reset the stream.
"""
import asyncio
import codecs
import ssl
import sys

from aioquic.asyncio.client import connect
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h0.connection import H0_ALPN
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import StreamDataReceived, StreamReset


class Client(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.waiters = {}
        self.bodies = {}

    def quic_event_received(self, event):
        if isinstance(event, StreamDataReceived):
            self.bodies.setdefault(event.stream_id, bytearray()).extend(event.data)
            if event.end_stream:
                self.waiters.pop(event.stream_id).set_result(self.bodies.pop(event.stream_id))
        elif isinstance(event, StreamReset) and event.stream_id in self.waiters:
            self.waiters.pop(event.stream_id).set_result(None)

    async def request(self, spec):
        fin = not spec.startswith("nofin:")
        data = codecs.decode(spec.removeprefix("nofin:"), "unicode_escape").encode()
        stream_id = self._quic.get_next_available_stream_id()
        fut = asyncio.get_running_loop().create_future()
        self.waiters[stream_id] = fut
        self._quic.send_stream_data(stream_id, data, end_stream=fin)
        self.transmit()
        return await asyncio.wait_for(fut, 10)


async def main():
    host, port, specs = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
    config = QuicConfiguration(is_client=True, alpn_protocols=H0_ALPN)
    config.verify_mode = ssl.CERT_NONE
    async with connect(host, port, configuration=config, create_protocol=Client) as client:
        for body in await asyncio.gather(*[client.request(s) for s in specs]):
            print("reset" if body is None else f"bytes {len(body)} sum {sum(body) & 0xffffffff}")


asyncio.run(main())
