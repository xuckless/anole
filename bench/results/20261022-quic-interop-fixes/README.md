# QUIC interop matrix, xuckless/anole#75 (quic-interop-fixes, e8fdf17)

The same run as the v0.1.0 matrix (../20261022-v0.1.0-quic-interop):
- tests/interop/run.sh from the branch, runner ab039a4;
- the branch's h3-interop-server (ReleaseSafe) against all 15 clients, every
  test case;
- one client per invocation, with 70 s idle before each;
- the runner on Python 3.12.

It ran from 04:00 to 05:41 on 2026-10-22.

Files:
- matrix.md: the matrix.
- `<client>.result.json`: the runner's raw results.
- failures/`<client>`/`<test>`/: the runner output and Anole's server log for every failure.
- interop.sh: the driver.
- delta.py: produces the table below from the two runs' results.

Packet captures, key logs and qlogs of every case stay in my scratchpad and are
not committed (3.1 GB).

## Totals

| | passed | failed | unsupported |
|---|---|---|---|
| v0.1.0 (c6d41b9) | 207 | 38 | 55 |
| #75 (e8fdf17) | **233** | **13** | 54 |

## Delta against v0.1.0

Fixed (30):

| client | cases | v0.1.0 cause |
|---|---|---|
| aioquic | H DC LR C20 M S 3 A B U L1 L2 C1 C2 BA R Z (17) | v2 chosen outside the v2 case |
| msquic | H LR C20 U R V2 | `h3` chosen over `hq-interop` |
| msquic, quinn | BA | PATH_CHALLENGE without PATH_RESPONSE |
| picoquic, s2n-quic | BP BA | PATH_CHALLENGE without PATH_RESPONSE |
| neqo | C1 | Retry raced a retransmitted ClientHello (52 handshakes) |

Newly failing (5):

| client | case | v0.1.0 | now |
|---|---|---|---|
| go-x-net | BP rebind-port | ✓ | ✕ first server packet on the new path has no PATH_CHALLENGE |
| xquic | M multiplexing | ✓ | ✕ Anole closes with STREAM_LIMIT_ERROR |
| xquic | L1 handshakeloss | ✓ | ✕ one of 50 files arrived empty |
| quinn | Z zerortt | ✓ | ✕ "Client sent too much data in 1-RTT packets" (0-RTT 10026 B, 1-RTT 13735 B) |
| mvfst | M multiplexing | ? | ✕ client timed out (the client ran the case this time instead of declaring it unsupported) |

Still failing (8):

| client | case | expected |
|---|---|---|
| neqo | Z | yes, not ours |
| quinn | V2 | yes, client never offers v2 |
| mvfst | L1 C1 Z | yes, client-side |
| quiche | M | **no**: still "Too many open files" with 100 streams |
| kwik | BP | **no**: 9322 of 10485760 bytes |
| aioquic | BP | **no**: the same as go-x-net BP |

## Notes on the unexpected failures

Read from the captures:
- The traces are from the simulator: left is the client's side, right is the server's.
- Key logs are from the clients.
- The tables count each test once.

**aioquic BP, go-x-net BP: an ACK is sent on the new path before the challenge.**
- The simulator moves the client to port 57607 at about 1.0 s.
- Anole's first packet to 57607 is ACK+PADDING with no PATH_CHALLENGE:
  - go-x-net: 1.00702 s, with the PATH_CHALLENGE following at 1.01060 s;
  - aioquic: 1.00198 s, with the PATH_CHALLENGE at 1.00202 s.
- The runner requires the first server packet on a new path to carry
  PATH_CHALLENGE.
- On the second rebind (59022, at 6.0 s), Anole's first packet is a
  PATH_CHALLENGE, so that one is correct.
- go-x-net BP passed on v0.1.0, so this looks introduced by #75. A pending ACK
  is probably flushed to the packet's source address before ngtcp2 has started
  validating the path.

**xquic M: the client exceeds the stream limit.**
- Anole now advertises `initial_max_streams_bidi` = 100. In v0.1.0 it was 1000.
- xquic opens 128 bidi streams anyway: its highest stream id is 508. Its log
  says `exceed max_streams_bidi_can_send:128`, which is its own limit.
- Anole closes with 0x4, STREAM_LIMIT_ERROR, at 0.65 s. That is correct per RFC 9000.
- So the failure is xquic's, and lowering the limit exposed it. A limit of 128 or
  more would keep xquic passing.

**quiche M: lowering to 100 did not fix it.**
- The client still panics with "Too many open files (os error 24)".
- Its log confirms Anole's limit of 100.
- quiche apparently opens a download file per request, not per open stream. So
  the server's stream limit does not bound it.
- This looks client-side. The 1000 → 100 change costs xquic M and gains nothing
  here.

**xquic L1: the server idled out under loss.**
- In the 31st connection (scid 7cbea498…), the 0-RTT request was accepted. Anole
  answered at once (58.877 s) in a flight with its Initial and Handshake
  packets.
- None of the server's flights reached the client until the sixth PTO
  retransmission, at 90.6 s:
  - the retransmissions were at 59.6, 60.6, 62.6, 66.6 and 74.6 s;
  - the retransmissions carry only Initial and Handshake packets, not the 1-RTT
    response.
- The client then completed its handshake (31.7 s) and sent Handshake packets
  until 146 s. Anole never answered them.
- Its connection had apparently hit the idle timeout, about 30 s after the
  client's last packet (59.6 s).
- This is probably a run of unlucky drops rather than a regression. It needs a
  rerun.

**kwik BP: the client went silent, so there is no steering signature.**
- The client sent 11 packets in total, all from port 33379.
- After the simulator rebinds the port, the server's 43 packets to 33379 stop
  reaching the client: only 12 do.
- The client never sends from the new port, so Anole cannot learn the address.
- The v0.1.0 failure looked different: there, the client's packets did arrive
  from the new port mid-handshake.

**quinn Z** has the same shape as neqo Z.
- The 1-RTT resend, 13735 B against the limit of 5000, means the 0-RTT data was
  still unacknowledged when the handshake completed.
- It passed on v0.1.0. Most likely the same ACK timing as neqo Z (ANALYSIS.md §4)
  is now hit by quinn as well.
- Not analysed further.

**mvfst M** is client-side.
- Its log has 946 × "Can not write output to file '/downloads/…' printing to
  stdout instead".
- It runs out of the 60 s budget while printing about 2000 files to stdout.
