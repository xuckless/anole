"""Stands in for systemd's notification socket: binds an AF_UNIX datagram
socket at argv[1] and appends each message to argv[2], one line each (the
message's own newlines become spaces).

    python3 tests/restart/notify.py /path/to/notify.sock /path/to/notify.log
"""
import socket
import sys

s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
s.bind(sys.argv[1])
with open(sys.argv[2], "a", buffering=1) as out:
    while True:
        out.write(s.recv(4096).decode(errors="replace").replace("\n", " ") + "\n")
