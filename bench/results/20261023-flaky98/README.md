# #98: "a client that moves to a new port keeps its connection" under load

dx-pass d25e169, `zig build compile-tests -Dtest-filter="a client that moves to a new port keeps its connection"` (Debug), Zig 0.17.0, Debian trixie container.
8 parallel loops × 38 runs per backend on 4 CPUs (8-11), each run with `timeout 90` (loop.sh).
epoll: Docker's default seccomp profile (zio falls back to epoll); io_uring: seccomp=unconfined. Checked from the process's descriptors (eventpoll vs io_uring).

| Backend | Runs | Stalls | Normal run p50 / p99 / max |
|---|---|---|---|
| epoll | 304 | 3 (1.0%) | 0.39 / 0.53 / 0.59 s |
| io_uring | 304 | 2 (0.7%) | 0.31 / 0.50 / 0.52 s |

Every stall fails after 30.5-30.8 s at client_test.zig:1502 (`finish(d, gpa)`, the rest of the 2 MB
download after `conn.rebind(how)`): readBody → waitFor → error.Timeout → ReadFailed, the client parked
on the stream's futex (bridge.zig:332). The test does not log the iteration, so which step (.migrate or
.nat) stalled is not known. Logs: <backend>/run-<loop>-<run>.log.gz.
