"""One HTTP/3 connection across a SIGUSR2 restart, on aioquic: a request
before it ("before 200"), then, once the file argv[3] exists, waits for the
old process to close the connection and prints how ("closed 0x100" for
H3_NO_ERROR). Exits non-zero if the connection is still open 5 s later.

    python3 tests/restart/across.py 127.0.0.1 8443 /path/to/go-file
"""
import asyncio
import os
import ssl
import sys

from aioquic.asyncio.client import connect
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import HeadersReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import ConnectionTerminated


def deadline():
    """The hang guard every wait here uses, as src/testing/wait.zig's: 10 s
    times ANOLE_TEST_TIMEOUT_FACTOR (a whole number, default 1)."""
    try:
        factor = max(int(os.environ.get("ANOLE_TEST_TIMEOUT_FACTOR", "1")), 1)
    except ValueError:
        factor = 1
    return 10 * factor


class Client(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.http = H3Connection(self._quic)
        self.waiters = {}
        self.terminated = asyncio.get_running_loop().create_future()

    def quic_event_received(self, event):
        if isinstance(event, ConnectionTerminated):
            if not self.terminated.done():
                self.terminated.set_result(event)
            return
        for ev in self.http.handle_event(event):
            if isinstance(ev, HeadersReceived) and ev.stream_id in self.waiters:
                self.waiters.pop(ev.stream_id).set_result(dict(ev.headers).get(b":status", b"?").decode())

    async def get(self, authority):
        stream_id = self._quic.get_next_available_stream_id()
        self.http.send_headers(stream_id, [
            (b":method", b"GET"), (b":scheme", b"https"),
            (b":authority", authority.encode()), (b":path", b"/"),
        ], end_stream=True)
        fut = asyncio.get_running_loop().create_future()
        self.waiters[stream_id] = fut
        self.transmit()
        return await asyncio.wait_for(fut, deadline())


async def main():
    host, port, go = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    config = QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN, idle_timeout=60)
    config.verify_mode = ssl.CERT_NONE
    async with connect(host, port, configuration=config, create_protocol=Client, wait_connected=True) as client:
        print("before", await client.get(f"{host}:{port}"), flush=True)
        # run.sh creates `go` once the successor is ready.
        loop = asyncio.get_running_loop()
        until = loop.time() + 6 * deadline()
        while not os.path.exists(go):
            if loop.time() > until:
                print("no go from run.sh", flush=True)
                sys.exit(1)
            await asyncio.sleep(0.02)
        # Closed by the old process (well before the 60 s idle timeout).
        try:
            ev = await asyncio.wait_for(asyncio.shield(client.terminated), deadline())
        except asyncio.TimeoutError:
            print("still open", flush=True)
            sys.exit(1)
        print(f"closed {ev.error_code:#x}", flush=True)


asyncio.run(main())
