"""An HTTP/3 client on aioquic, an independent QUIC and HTTP/3 stack, for
checking Anole's HTTP/3 server. Prints the status, the headers and the body
of each response; exits non-zero if a request fails.

    python3 tests/h3/client.py https://127.0.0.1:8443/ [more URLs...]
        [--method POST] [--data TEXT | --data-file PATH] [--repeat N] [--parallel N]
"""
import argparse
import asyncio
import ssl
import sys
from urllib.parse import urlparse

from aioquic.asyncio.client import connect
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration


class Client(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.http = H3Connection(self._quic)
        self.waiters = {}
        self.responses = {}

    def quic_event_received(self, event):
        for ev in self.http.handle_event(event):
            if isinstance(ev, HeadersReceived):
                r = self.responses.setdefault(ev.stream_id, {"headers": [], "body": b"", "trailers": []})
                if "status" in r:
                    r["trailers"] = ev.headers
                else:
                    r["headers"] = ev.headers
                    r["status"] = dict(ev.headers).get(b":status", b"?").decode()
            elif isinstance(ev, DataReceived):
                self.responses.setdefault(ev.stream_id, {"headers": [], "body": b"", "trailers": []})["body"] += ev.data
            if getattr(ev, "stream_ended", False) and ev.stream_id in self.waiters:
                self.waiters.pop(ev.stream_id).set_result(self.responses.pop(ev.stream_id))

    async def request(self, method, url, data=None):
        u = urlparse(url)
        stream_id = self._quic.get_next_available_stream_id()
        headers = [
            (b":method", method.encode()),
            (b":scheme", b"https"),
            (b":authority", u.netloc.encode()),
            (b":path", (u.path or "/").encode() + (b"?" + u.query.encode() if u.query else b"")),
            (b"user-agent", b"anole-h3-test"),
        ]
        if data is not None:
            headers.append((b"content-length", str(len(data)).encode()))
        self.http.send_headers(stream_id, headers, end_stream=data is None)
        if data is not None:
            self.http.send_data(stream_id, data, end_stream=True)
        fut = asyncio.get_running_loop().create_future()
        self.waiters[stream_id] = fut
        self.transmit()
        return await asyncio.wait_for(fut, 10)


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("urls", nargs="+")
    ap.add_argument("--method", default="GET")
    ap.add_argument("--data")
    ap.add_argument("--data-file")
    ap.add_argument("--repeat", type=int, default=1)
    ap.add_argument("--parallel", type=int, default=1)
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()
    config = QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN)
    config.verify_mode = ssl.CERT_NONE
    u = urlparse(args.urls[0])
    data = args.data.encode() if args.data is not None else None
    if args.data_file:
        with open(args.data_file, "rb") as f:
            data = f.read()
    async with connect(u.hostname, u.port or 443, configuration=config, create_protocol=Client) as client:
        ok = 0
        for _ in range(args.repeat):
            jobs = [client.request(args.method, url, data) for url in args.urls for _ in range(args.parallel)]
            for r in await asyncio.gather(*jobs):
                if args.quiet:
                    print("status", r["status"], "bytes", len(r["body"]))
                else:
                    print("status", r["status"])
                    for k, v in r["headers"]:
                        if not k.startswith(b":"):
                            print(f"{k.decode()}: {v.decode()}")
                    for k, v in r["trailers"]:
                        print(f"trailer {k.decode()}: {v.decode()}")
                    body = r["body"]
                    print(f"body ({len(body)} bytes):", body[:200].decode(errors="replace").encode("ascii", "replace").decode())
                ok += 1
        print(f"{ok} responses")


asyncio.run(main())
