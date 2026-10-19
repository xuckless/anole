"""MODE=h3 with WORKERS > 1: one Hypercorn process per worker.

`hypercorn --workers N --quic-bind ...` binds a single UDP socket and shares
it across the N worker processes, so each QUIC datagram goes to whichever
worker reads it first, and connections break (Hypercorn 0.18.0). Instead,
each process here gets its own TCP and UDP socket in a SO_REUSEPORT group;
the kernel hashes each client's address to one socket, so a QUIC connection
stays on one process. Hypercorn takes the sockets through its fd:// binds.
"""

import os
import signal
import socket
import subprocess
import sys

port = int(os.environ.get("HTTPS_PORT", "8443"))
workers = int(os.environ.get("WORKERS", "1"))


def bound(kind: int) -> socket.socket:
    sock = socket.socket(socket.AF_INET, kind)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    sock.bind(("0.0.0.0", port))
    return sock


procs = []
for _ in range(workers):
    tcp, udp = bound(socket.SOCK_STREAM), bound(socket.SOCK_DGRAM)
    procs.append(
        subprocess.Popen(
            [
                "hypercorn", "app:app", "--config", "hypercorn.toml",
                "--certfile", os.environ["CERT_FILE"], "--keyfile", os.environ["KEY_FILE"],
                "--bind", f"fd://{tcp.fileno()}", "--quic-bind", f"fd://{udp.fileno()}",
                "--keep-alive", "75", "--log-level", "warning",
            ],
            pass_fds=(tcp.fileno(), udp.fileno()),
        )
    )
    tcp.close()
    udp.close()


def stop(*_):
    for p in procs:
        p.terminate()


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
codes = [p.wait() for p in procs]
sys.exit(max(codes))
