"""spike/python/proactor_doorbell.py - THROWAWAY prototype of anole-py's
Windows wake path, run here on any asyncio loop through ctypes:

  python proactor_doorbell.py [executors] [port]

The wake callback is C (wake_socket.c): Anole's executor sends one byte on
a socketpair; `await loop.sock_recv(rsock)` wakes the loop (overlapped
WSARecv under the Proactor, a selector read elsewhere); the loop drains
with anole_poll and answers with anole_respond. ctypes makes every call
slow; the point is the path, not the speed.
"""
import asyncio, ctypes, os, signal, socket, struct, sys

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.abspath(os.path.join(here, "..", ".."))
ext = ".dll" if sys.platform == "win32" else ".dylib" if sys.platform == "darwin" else ".so"
lib = ctypes.CDLL(os.path.join(root, "zig-out", "lib", "libanole" + ext))
wake = ctypes.CDLL(os.path.join(here, "build", "wake_socket" + ext))


class Str(ctypes.Structure):
    _fields_ = [("ptr", ctypes.c_char_p), ("len", ctypes.c_size_t)]


class ServerOptions(ctypes.Structure):
    _fields_ = [("size", ctypes.c_size_t), ("config_json", Str), ("flags", ctypes.c_uint32)]


class ConsumerOptions(ctypes.Structure):
    _fields_ = [("size", ctypes.c_size_t), ("wake", ctypes.c_void_p), ("wake_ud", ctypes.c_void_p), ("flags", ctypes.c_uint32)]


class Header(ctypes.Structure):
    _fields_ = [("name", Str), ("value", Str)]


lib.anole_poll.restype = ctypes.c_int64
lib.anole_poll.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32]
lib.anole_respond.argtypes = [ctypes.c_uint64, ctypes.c_uint16, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_uint32]
lib.anole_last_error.restype = Str

executors = int(sys.argv[1]) if len(sys.argv) > 1 else 1
port = int(sys.argv[2]) if len(sys.argv) > 2 else 18800
config = ('{"listeners":[{"port":%d}],"executors":%d,"routes":['
          '{"method":"GET","path":"/native","respond":{"body":"Hello, World!"}},'
          '{"method":"GET","path":"/hello","handler":1}]}' % (port, executors)).encode()

server = ctypes.c_void_p()
assert lib.anole_server_create(ctypes.byref(ServerOptions(ctypes.sizeof(ServerOptions), Str(config, len(config)), 0)), ctypes.byref(server)) == 0
rsock, wsock = socket.socketpair()
rsock.setblocking(False)
wsock.setblocking(False)
consumer = ctypes.c_void_p()
wake_fn = ctypes.cast(wake.anole_py_wake_socket, ctypes.c_void_p)
assert lib.anole_consumer_attach(server, ctypes.byref(ConsumerOptions(ctypes.sizeof(ConsumerOptions), wake_fn, wsock.fileno(), 0)), ctypes.byref(consumer)) == 0
assert lib.anole_server_start(server) == 0, lib.anole_last_error().ptr

buf = ctypes.create_string_buffer(1 << 20)
view = memoryview(buf).cast("B")
ct = (Header * 1)(Header(Str(b"content-type", 12), Str(b"text/plain", 10)))
body = b"Hello, World!"
served = 0


def drain():
    global served
    while True:
        n = lib.anole_poll(consumer, buf, len(buf), 0)
        if n <= 0:
            return n == 0
        off = 0
        while off < n:
            typ, ln, handle = struct.unpack_from("<IIQ", view, off)
            if typ == 1:
                lib.anole_respond(handle, 200, ct, 1, body, len(body), 0)
                served += 1
            elif typ == 11:
                return False
            off += ln


async def main():
    loop = asyncio.get_running_loop()
    print(f"{type(loop).__name__} serving /hello on 127.0.0.1:{port}", file=sys.stderr, flush=True)
    while True:
        await loop.sock_recv(rsock, 4096)  # the doorbell
        if not drain():
            break


def _stop(*_):
    raise KeyboardInterrupt


signal.signal(signal.SIGTERM, _stop)  # Anole installs no handlers; the binding owns signals
try:
    asyncio.run(main())
except KeyboardInterrupt:
    pass
finally:
    lib.anole_server_drain(server)
    while drain():
        pass
    lib.anole_server_wait(server)
    lib.anole_server_destroy(server)
    print(f"served {served}", file=sys.stderr)
