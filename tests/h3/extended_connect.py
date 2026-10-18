"""WebTransport (draft-02) and WebSocket over HTTP/3 (RFC 9220) on aioquic,
an independent QUIC and HTTP/3 stack, against Anole's HTTP/3 server
(tests/h3/server.zig: /wt and /ws echo).

    extended_connect.py wt PORT        streams both ways, datagrams, close
    extended_connect.py wt-close PORT  the client closes with a code
    extended_connect.py wt-hold PORT   opens a session and prints what ends it
    extended_connect.py ws PORT        text, binary, ping, close
    extended_connect.py ws-hold PORT   opens a socket and prints what ends it

Prints one line per check; exits non-zero on the first that fails.
"""
import asyncio
import os
import ssl
import struct
import sys

from aioquic.asyncio.client import connect
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.buffer import Buffer
from aioquic.h3.connection import H3_ALPN, FrameType, H3Connection, H3Stream
from aioquic.h3.events import DataReceived, DatagramReceived, HeadersReceived, WebTransportStreamDataReceived
from aioquic.quic.configuration import QuicConfiguration

CLOSE_SESSION = 0x2843
DRAIN_SESSION = 0x78AE


def varint(v):
    buf = Buffer(capacity=8)
    buf.push_uint_var(v)
    return buf.data


def capsules(data):
    """(type, payload) for each whole capsule in data."""
    out = []
    buf = Buffer(data=data)
    while not buf.eof():
        t = buf.pull_uint_var()
        n = buf.pull_uint_var()
        out.append((t, buf.pull_bytes(n)))
    return out


class Client(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.h3 = H3Connection(self._quic, enable_webtransport=True)
        self.queues = {}
        self.ended = set()
        self.datagrams = asyncio.Queue()
        self.incoming = asyncio.Queue()

    def queue(self, stream_id):
        return self.queues.setdefault(stream_id, asyncio.Queue())

    def quic_event_received(self, event):
        for ev in self.h3.handle_event(event):
            if isinstance(ev, HeadersReceived):
                self.queue(ev.stream_id).put_nowait(("headers", dict(ev.headers)))
                if ev.stream_ended:
                    self.queue(ev.stream_id).put_nowait(("end", b""))
            elif isinstance(ev, DataReceived):
                self.queue(ev.stream_id).put_nowait(("data", ev.data))
                if ev.stream_ended:
                    self.queue(ev.stream_id).put_nowait(("end", b""))
            elif isinstance(ev, WebTransportStreamDataReceived):
                # A stream the server opened, seen for the first time.
                if ev.stream_id & 1 and ev.stream_id not in self.queues:
                    self.incoming.put_nowait(ev.stream_id)
                self.queue(ev.stream_id).put_nowait(("data", ev.data))
                if ev.stream_ended:
                    self.queue(ev.stream_id).put_nowait(("end", b""))
            elif isinstance(ev, DatagramReceived):
                self.datagrams.put_nowait(ev.data)

    def open_bidi(self, session_id):
        """A bidirectional WebTransport stream. aioquic 1.7.0 recognises
        one only by the signal at the start of what it receives, so on a
        stream it opened itself it would parse the answer as HTTP/3
        frames: mark it as WebTransport's here."""
        s = self.h3.create_webtransport_stream(session_id)
        stream = self.h3._stream.setdefault(s, H3Stream(s))
        stream.frame_type = FrameType.WEBTRANSPORT_STREAM
        stream.session_id = session_id
        return s

    async def read_all(self, stream_id, timeout=5):
        """The stream's data up to its end."""
        data = b""
        while True:
            kind, chunk = await asyncio.wait_for(self.queue(stream_id).get(), timeout)
            if kind == "end":
                return data
            data += chunk

    async def open(self, path, protocol, extra=()):
        sid = self._quic.get_next_available_stream_id()
        self.h3.send_headers(
            sid,
            [
                (b":method", b"CONNECT"),
                (b":scheme", b"https"),
                (b":authority", b"localhost"),
                (b":path", path.encode()),
                (b":protocol", protocol.encode()),
                *extra,
            ],
            end_stream=False,
        )
        self.transmit()
        kind, headers = await asyncio.wait_for(self.queue(sid).get(), 5)
        assert kind == "headers", kind
        return sid, headers


def check(ok, what):
    if not ok:
        print("FAIL", what, flush=True)
        os._exit(1)
    print("PASS", what, flush=True)


async def wt(c, mode):
    sid, headers = await c.open("/wt", "webtransport", [(b"sec-webtransport-http3-draft02", b"1")])
    check(headers.get(b":status") == b"200", f"WebTransport session accepted ({headers.get(b':status')})")
    if mode == "hold":
        data = await c.read_all(sid, timeout=30)
        print("capsules", " ".join(f"{t:#x}:{p[:4].hex()}{p[4:].decode()!r}" if t == CLOSE_SESSION else f"{t:#x}" for t, p in capsules(data)), flush=True)
        return
    # Bidirectional streams, several at once, one large.
    streams = {}
    for i, size in enumerate([1, 1000, 100_000, 1_000_000]):
        s = c.open_bidi(sid)
        body = bytes((i * 7 + j) & 0xFF for j in range(size))
        c._quic.send_stream_data(s, body, end_stream=True)
        streams[s] = body
    c.transmit()
    for s, body in streams.items():
        back = await c.read_all(s, timeout=10)
        check(back == body, f"bidirectional stream echo, {len(body)} bytes")
    # Unidirectional: comes back on a stream the server opens.
    u = c.h3.create_webtransport_stream(sid, is_unidirectional=True)
    c._quic.send_stream_data(u, b"one way", end_stream=True)
    c.transmit()
    back_id = await asyncio.wait_for(c.incoming.get(), 5)
    back = await c.read_all(back_id)
    check(back == b"one way" and back_id & 3 == 3, "unidirectional stream echo, on a server-opened stream")
    # Datagrams.
    for d in [b"d1", b"datagram two", bytes(1000)]:
        c.h3.send_datagram(sid, d)
        c.transmit()
        got = await asyncio.wait_for(c.datagrams.get(), 5)
        check(got == d, f"datagram echo, {len(d)} bytes")
    if mode == "close":
        # The client closes: a capsule and the stream's end; the server
        # ends its side.
        msg = b"client done"
        c.h3.send_data(sid, varint(CLOSE_SESSION) + varint(4 + len(msg)) + struct.pack("!I", 4242) + msg, end_stream=True)
        c.transmit()
        rest = await c.read_all(sid)
        check(all(t != CLOSE_SESSION for t, _ in capsules(rest)), "client close: the server ends the CONNECT stream")
        return
    # The server closes with a code and a message.
    c.h3.send_datagram(sid, b"close")
    c.transmit()
    data = await c.read_all(sid)
    caps = capsules(data)
    check(
        len(caps) == 1 and caps[0][0] == CLOSE_SESSION and caps[0][1] == struct.pack("!I", 7) + b"asked to",
        f"server close: CLOSE_WEBTRANSPORT_SESSION 7 'asked to' then FIN ({caps})",
    )


def ws_frame(opcode, payload):
    mask = os.urandom(4)
    n = len(payload)
    if n < 126:
        head = struct.pack("!BB", 0x80 | opcode, 0x80 | n)
    elif n < 65536:
        head = struct.pack("!BBH", 0x80 | opcode, 0x80 | 126, n)
    else:
        head = struct.pack("!BBQ", 0x80 | opcode, 0x80 | 127, n)
    return head + mask + bytes(b ^ mask[i & 3] for i, b in enumerate(payload))


class Frames:
    def __init__(self, c, sid):
        self.c, self.sid, self.buf = c, sid, b""

    async def next(self, timeout=5):
        while True:
            f = self.parse()
            if f:
                return f
            kind, chunk = await asyncio.wait_for(self.c.queue(self.sid).get(), timeout)
            if kind == "end":
                return None
            self.buf += chunk

    def parse(self):
        b = self.buf
        if len(b) < 2:
            return None
        op, n, i = b[0] & 0x0F, b[1] & 0x7F, 2
        if b[1] & 0x80:
            raise Exception("masked frame from the server")
        if n == 126:
            if len(b) < 4:
                return None
            n, i = struct.unpack("!H", b[2:4])[0], 4
        elif n == 127:
            if len(b) < 10:
                return None
            n, i = struct.unpack("!Q", b[2:10])[0], 10
        if len(b) < i + n:
            return None
        self.buf = b[i + n :]
        return op, b[i : i + n]


async def ws(c, mode):
    sid, headers = await c.open("/ws", "websocket", [(b"sec-websocket-version", b"13")])
    check(headers.get(b":status") == b"200", f"WebSocket over HTTP/3 accepted ({headers.get(b':status')})")
    frames = Frames(c, sid)
    if mode == "hold":
        f = await frames.next(timeout=30)
        code = struct.unpack("!H", f[1][:2])[0] if f and f[0] == 8 else None
        print("close", code, f[1][2:].decode() if f else "", flush=True)
        return
    for op, payload in [(1, b"hello over h3"), (2, bytes(range(256)) * 300)]:
        c.h3.send_data(sid, ws_frame(op, payload), end_stream=False)
        c.transmit()
        f = await frames.next()
        check(f == (op, payload), f"WebSocket echo, opcode {op}, {len(payload)} bytes")
    c.h3.send_data(sid, ws_frame(9, b"ping!"), end_stream=False)
    c.transmit()
    f = await frames.next()
    check(f == (10, b"ping!"), "WebSocket ping answered with a pong")
    c.h3.send_data(sid, ws_frame(8, struct.pack("!H", 1000) + b"bye"), end_stream=False)
    c.transmit()
    f = await frames.next()
    check(f is not None and f[0] == 8 and f[1][:2] == struct.pack("!H", 1000), f"WebSocket close echoed ({f})")
    c.h3.send_data(sid, b"", end_stream=True)
    c.transmit()


async def main():
    mode, port = sys.argv[1], int(sys.argv[2])
    config = QuicConfiguration(alpn_protocols=H3_ALPN, is_client=True, max_datagram_frame_size=65536)
    config.verify_mode = ssl.CERT_NONE
    async with connect("127.0.0.1", port, configuration=config, create_protocol=Client) as c:
        await c.wait_connected()
        kind, _, sub = mode.partition("-")
        await (wt if kind == "wt" else ws)(c, sub)


asyncio.run(main())
