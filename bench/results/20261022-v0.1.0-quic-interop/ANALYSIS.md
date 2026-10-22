# Root causes of the v0.1.0 QUIC interop failures

Anole v0.1.0 (c6d41b9) `h3-interop-server` against the pinned runner
(ab039a4). The causes below come from targeted reruns of the failing
pairs on 2026-10-22, with packet captures, key logs and qlogs, decoded
with tshark 4.6.9. Each rerun had 70 s of rest before it. No Anole code
was changed.

The captures are not committed (several MB each). They are kept in the
benchmark session's scratchpad until the fix-branch rerun.

| # | Failure | Cause | Whose |
|---|---|---|---|
| 1 | aioquic: 18 cases | v2 chosen outside the v2 case | ours: interop server config |
| 2 | msquic H, LR, C20, U, R, V2 | `h3` chosen over the offered `hq-interop` | ours: ALPN selection |
| 3 | quinn V2 | client never offers v2 | client |
| 4 | neqo Z | 0-RTT accepted, but its ACK is held about 1 ms | probably ours: ACK timing |
| 5 | neqo C1 | Retry races a retransmitted ClientHello, so one client connection gets two server connections | ours/ngtcp2: race |
| 6 | quiche M | 1000 streams allowed; client runs out of file descriptors | ours: interop server config |
| 7 | kwik BP (intermittent) | rebinding lands inside the handshake | see section 7: the fixer found it ours |
| 8 | mvfst L1, C1, Z | no key log; one connection reused | client |
| 9 | picoquic BP/BA, s2n-quic BP/BA, quinn BA, msquic BA | PATH_CHALLENGE without PATH_RESPONSE | root-caused by the fixer (#75) |

## 1. v2 outside the v2 case (aioquic)

**Evidence.** In the handshake case, aioquic's ClientHello carries
`version_information` (0x11) with chosen version v1 and available versions
v1 and v2. Every server packet after the first is v2 (`0x6b3343cf`). The
runner then reports: `Wrong version. Expected 0x1, got 0x6b3343cf`.

**Cause.** `src/h3/server.zig:83` sets
`preferred_versions = { V2, V1 }`, and line 1327 applies it to every
connection. ngtcp2 therefore upgrades through compatible version
negotiation (RFC 9368) whenever the client lists v2.

**How ngtcp2's own interop server handles it.** Its `run_endpoint.sh`
passes `--preferred-versions v2` only when `TESTCASE=v2`. Otherwise it
stays on v1.

**Fix.**
- Make the preference an `Http3` option, for example
  `preferred_versions` or `prefer_v2: bool`, defaulting to v1.
- In `tests/h3/interop.zig` and `tests/interop/run_endpoint.sh`, turn it
  on for `TESTCASE=v2` only. The interop server would take a `v2`
  argument, the way it takes `retry`.

## 2. msquic "Missing files": wrong ALPN

**Evidence.**
- In the handshake case, msquic offers
  `hq-interop,h3,hq-29,h3-29`, and Anole selects `h3`.
- msquic still sends HTTP/0.9: the STREAM payload on stream 0 is
  `GET /excited-freezing-jaguar\r\n` with FIN.
- About 10 µs later Anole sends CONNECTION_CLOSE (application, frame 0x1d)
  with code 262 = 0x106, `H3_FRAME_ERROR`.
- The v2 case is the same: the version upgrade works (server packets are
  v2), and the ALPN choice is again `h3`.
- In the cases that pass (rebind-addr, multi-file), msquic offers only
  `hq-interop,hq-29`, and Anole selects `hq-interop`.

**Cause.** `selectAlpn` (`src/h3/quic_tls.zig:113`) walks the server's
own list, `h3` then `hq-interop`, and picks the first one the client
offers. So a client that offers both always gets `h3`.

**How ngtcp2's own interop server handles it.** It runs a separate binary
for the http3 case (`wsslserver`) and the hq binary
(`wsslhqserver`) for everything else. Each binary speaks only one ALPN.

**Fix**, either of:
- The interop server accepts only `hq-interop`, except for
  `TESTCASE=http3`, where it accepts only `h3`. This is a new option on
  `quic_tls.ServerOptions`, set from `tests/interop/run_endpoint.sh`.
- With `hq_interop` on, honour the client's order in `selectAlpn`:
  iterate the offer and take the first protocol Anole supports.

## 3. quinn V2: the client never offers v2

**Evidence.** In the v2 case, quinn's Initial is v1, and its transport
parameters carry no `version_information`. The full list is:
max_idle_timeout, max_udp_payload_size, initial_max_data, the stream data
limits, the stream limits, active_connection_id_limit, GREASE,
max_datagram_frame_size, initial_source_connection_id, grease_quic_bit
and min_ack_delay.

Anole answers in v1, and the runner reports: `Wrong version in server
Initial. Expected 0x6b3343cf, got {'0x1'}`.

**Cause.** Without `version_information`, RFC 9368 forbids a server from
upgrading. The image `stammw/quinn-interop` was built on 2024-09-02. It
should exit 127 for the v2 case (unsupported) instead.

**Fix.** None on Anole's side.

## 4. neqo zerortt: "Client sent too much data in 1-RTT packets"

**Evidence**, from the client qlog and the server-side capture of the
second connection:
- Anole accepted 0-RTT. Its EncryptedExtensions carries `early_data`
  (extension 42), and its 1-RTT packets with STREAM responses to the
  0-RTT requests reach the client within one RTT (from 36.95 ms).
- The client sent the 40 requests in 0-RTT twice: neqo resent them on its
  own probe timeouts at 0.68 ms. That makes 0-RTT 21,900 bytes.
- When neqo's handshake completed (35.92 ms), it resent all of the request
  data in 1-RTT packets 24–29, about 7.7 KB. The runner's limit is
  `0.5 × 250 × 40` = 5000 bytes.
- No 0-RTT packet was declared lost.
- Anole's first 1-RTT packet (pn …798, received at 34.96 ms) carries only
  NEW_CONNECTION_ID frames, with no ACK. The first ACK of the 0-RTT
  packets comes in pn …800, at 36.95 ms. That is after neqo's resend.

**Probable cause.** The ACK of the 0-RTT packets waits for Anole's
batching hold (`hold_ns` = 1 ms, `Conn.holding`/`hold_until` in
`src/h3/server.zig`), which lets ACKs leave with responses. neqo
completes its handshake inside that window and retransmits the 0-RTT
data that is still unacknowledged.

**Fix.** Don't hold the ACK while the handshake is not complete, or
whenever 0-RTT packets are pending acknowledgement. When
`!ngtcp2_conn_get_handshake_completed(conn.q)`, flush the
application-space ACK in the same flight as the server's Handshake.

**Check.** Rerun neqo `zerortt`. The 1-RTT bytes should drop below 5000.

## 5. neqo handshakecorruption: 52 handshakes instead of 50

**Evidence.**
- The runner counts distinct SCIDs in server Initial packets, and there
  are 52. neqo wrote 50 qlogs, all of which closed normally.
- In one case (server capture frames 151–161):
  - Frame 151: a client Initial on a new connection (ODCID `e667b5…`, no
    token) carries only the second part of a split ClientHello
    (CRYPTO offset 1213). The first part was corrupted.
  - Frame 152: Anole sends a verified v1 Retry with SCID `140591c5…`.
  - Frames 154 and 156: neqo's retransmitted full ClientHello, still to
    `e667b5…`, was in flight before the Retry arrived. Anole creates
    connection `fe0504…` from it (frames 155–158).
  - Frame 159: neqo acts on the Retry and sends an Initial to
    `140591c5…`. Anole creates a second connection, `840545…`.
- This happened twice in the run.

**Cause.**
- ngtcp2 returns `NGTCP2_ERR_RETRY` from `ngtcp2_conn_read_pkt` when the
  first Initial's CRYPTO data does not start at offset 0 and there is no
  validated token (`ngtcp2_conn.c:10239`). It does this to "buffer
  validated data only".
- Anole sends the Retry (`src/h3/server.zig:1147`) and destroys the
  connection, as ngtcp2 asks. The next tokenless Initial for the same
  ODCID then starts a fresh connection.

**Fix**, optional (the stray connection only idles out):
- After a Retry caused by `NGTCP2_ERR_RETRY`, remember (remote address,
  ODCID) for about 2 × PTO.
- Answer later tokenless Initials for that ODCID with the same Retry
  instead of creating a connection.

## 6. quiche multiplexing: "Too many open files"

**Evidence.**
- The client panics:
  `Error creating file for https://server4/light-extreme-anteater ...:
  Too many open files (os error 24)`.
- Anole's transport parameters advertise
  `initial_max_streams_bidi = 1000`.
- The runner's multiplexing case requests 1999 files.

**Cause.**
- `tests/h3/interop.zig:32` sets `max_streams_bidi = 1000`. Anole's
  library default, and ngtcp2's examples, use 100.
- quiche opens a download file per open stream, so 1000 concurrent
  streams plus its other descriptors pass the usual 1024 limit.

**Fix.** Use the default of 100 in the interop server.

## 7. kwik rebind-port: 0-byte download (intermittent, 1 in 5)

**Evidence**, from the failed run (server-side capture):
- The client's Initial comes from port 57616 at 0.970 s, and Anole replies
  there.
- At 1.025 s the simulator rebinds the client to port 57607. The client's
  Handshake (Finished), its request and its ACKs all arrive from 57607.
- Anole never sends to 57607. It retransmits its Handshake flight to
  57616, which is now dead (frames 51 and 59). The handshake never
  completes, and the client reports `StreamClosedException: Connection
  closed`.
- The four other reruns passed.

**Cause.** ngtcp2 ignores packets from an unknown path while the server is
in `SERVER_INITIAL`/`SERVER_WAIT_HANDSHAKE` (`ngtcp2_conn.c:10428`,
"ignore packet from unknown path during handshake"). RFC 9000 §9 allows
this. The failure happens when the simulator's first rebind (about 1 s)
lands inside a handshake that began late.

**Fix.** None in Anole, on this evidence: it's inherent to ngtcp2 and
allowed by the RFC.

**Later correction.** The fixer for xuckless/anole#75 root-caused this
differently, as Anole's own bug. The mid-handshake rebind hashed the
client's new 4-tuple to another per-core socket. #75 now places a
client's first long-header packets by its connection ID instead. The
capture here shows the symptom both readings predict: no server packets
on the new port. The fix-branch matrix rerun is the check.

## 8. mvfst handshakeloss, handshakecorruption, zerortt

**Evidence.**
- The runner reports `No key log file found` and
  `Expected 50 handshakes. Got: 1`.
- mvfst's client log shows all requests on one connection.

**Cause.** Client-side: no SSLKEYLOGFILE, and it reuses one connection
where the test wants one connection per file.

**Fix.** None on Anole's side.

## 9. PATH_CHALLENGE without a PATH_RESPONSE (rebinding)

Not captured here. Builder's fixer root-caused these cases for
xuckless/anole#75 from the matrix logs, and the fix-branch rerun checks
them.
