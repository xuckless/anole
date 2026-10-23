#!/usr/bin/env python3
"""holdconns.py <port> <n> <polite|rude>: opens n TCP connections and keeps
them open. polite: closes each as soon as the server closes it (reads EOF);
rude: never reads or closes. Prints 'held <n>' when all are open, then
waits until killed."""
import selectors, socket, sys, time
port, n, mode = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
sel = selectors.DefaultSelector()
socks = []
for i in range(n):
    s = socket.create_connection(("127.0.0.1", port))
    s.setblocking(False)
    socks.append(s)
    if mode == "polite":
        sel.register(s, selectors.EVENT_READ)
print(f"held {n}", flush=True)
while True:
    if mode == "polite" and sel.get_map():
        for key, _ in sel.select(timeout=1):
            try:
                data = key.fileobj.recv(4096)
            except OSError:
                data = b""
            if not data:
                sel.unregister(key.fileobj)
                key.fileobj.close()
    else:
        time.sleep(1)
