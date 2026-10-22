# Targeted QUIC interop rerun, xuckless/anole#75 at 19942bf

These are the cases that failed or regressed on e8fdf17
(../20261022-quic-interop-fixes), plus the rebinding cases the earlier
fixes touched. The server is from #75's new head, 19942bf, rebased on main, with
these changes:
- ngtcp2 patch b70d6d98: a pending PATH_CHALLENGE or PATH_RESPONSE goes out
  before an ACK-only packet when pacing blocks;
- the interop server's stream limit is back to 1000;
- no flush hold for 0-RTT rounds or rounds that complete the handshake.

Setup:
- tests/interop/run.sh, runner ab039a4, h3-interop-server ReleaseSafe.
- 3 runs per client, in run-major order (every client once, then again).
- 70 s idle before every invocation.
- 2026-10-22 06:55–08:02.
- The driver is interop.sh.

Files:
- run`N`/`<client>`.result.json: the runner's raw results.
- failures/run`N`/`<client>`/`<test>`/: the output and server log of every failure.

Captures, key logs and qlogs of every case are kept in my scratchpad and are
not committed.

| client | case | e8fdf17 | run 1 | run 2 | run 3 |
|---|---|---|---|---|---|
| go-x-net | BP rebind-port | ✕ | ✓ | ✓ | ✓ |
| go-x-net | BA rebind-addr | ✓ | ✓ | ✓ | ✓ |
| aioquic | BP rebind-port | ✕ | ✓ | ✓ | ✓ |
| aioquic | BA rebind-addr | ✓ | ✓ | ✓ | ✓ |
| xquic | M multiplexing | ✕ | ✓ | ✓ | ✓ |
| xquic | L1 handshakeloss | ✕ | ✓ | ✓ | ✓ |
| msquic | BP / BA | ✓ / ✓ | ✓ / ✓ | ✓ / ✓ | ✓ / ✓ |
| picoquic | BP / BA | ✓ / ✓ | ✓ / ✓ | ✓ / ✓ | ✓ / ✓ |
| s2n-quic | BP / BA | ✓ / ✓ | ✓ / ✓ | ✓ / ✓ | ✓ / ✓ |
| kwik | BP rebind-port | ✕ | ✕ | ✓ | ✓ |
| quinn | Z zerortt | ✕ | ✓ | ✕ | ✕ |
| neqo | Z zerortt | ✕ | ✕ | ✕ | ✕ |

**Merge gate.** go-x-net BP, aioquic BP and xquic M pass in all 3 runs.

**kwik BP, run 1.**
- The runner reports "First server packet on new path … did not contain a
  PATH_CHALLENGE frame".
- kwik's client started late. Its first Initial came at 0.998 s, against about
  0.65 s for the other clients.
- The simulator's first rebind (to 57607) landed inside the handshake: the
  client's next Initial arrived from 57607 at 1.199 s.
- Anole followed the client to the new port, which is #75's per-core placement
  fix working. Its first packet there was its Initial+Handshake flight.
- A server cannot send PATH_CHALLENGE before the handshake is complete
  (RFC 9000 §9). So this case fails only when the rebind lands in the
  handshake, and runs 2 and 3 passed.
- On e8fdf17, the same run failed differently: the client went silent.

**neqo Z** is unchanged by the flush-hold change:

| run | 0-RTT bytes | 1-RTT bytes |
|---|---|---|
| 1 | 21,900 | 7,682 |
| 2 | 21,900 | 7,690 |
| 3 | 21,750 | 7,711 |

These match v0.1.0 (21,900 and about 7.7 KB), against a limit of 5,000.

**quinn Z** fails in 2 of 3 runs:

| run | 0-RTT bytes | 1-RTT bytes | result |
|---|---|---|---|
| 1 | 9,299 | 3,362 | pass |
| 2 | 11,077 | 12,809 | fail |
| 3 | 9,983 | 12,361 | fail |

It passed in the v0.1.0 matrix. The shape is the same as neqo's: the client
resends its 0-RTT request data in 1-RTT after the handshake completes, which
means the 0-RTT packets were not acknowledged in time. Not analysed further in
this run. The captures and qlogs are kept.
