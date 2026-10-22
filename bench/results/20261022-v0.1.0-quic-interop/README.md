# QUIC interop matrix, Anole v0.1.0 server

tests/interop/run.sh from v0.1.0 (runner ab039a4), Anole's h3-interop-server
(ReleaseSafe) against all 15 client implementations of the pinned runner,
every test case. One client per invocation with 70 s idle before each. The
runner ran on Python 3.12 (pyshark fails on 3.14). xquic, lsquic, quinn,
s2n-quic and go-x-net were rerun after the first pass hit a full disk.

matrix.md: ✓ passed, ✕ failed, ? unsupported (by the client, or by both).
failures/<client>/<test>/: the runner's output and Anole's server log for
each failure; packet captures and qlogs were not kept.

Failures, by cause (my reading of the logs):

- QUIC v2 chosen when the client did not ask for it (aioquic, every test
  but v2): Anole upgrades to v2 through compatible version negotiation
  whenever the client lists it (src/h3/server.zig `preferred_versions`); the
  runner expects v1 outside the v2 case ("Wrong version. Expected 0x1, got
  0x6b3343cf").
- v2 case (quinn, msquic): "Wrong version in server Initial. Expected
  0x6b3343cf, got 0x1" (quinn).
- Path validation on rebinding (picoquic BP/BA, s2n-quic BP/BA, quinn BA,
  msquic BA): "PATH_CHALLENGE without a PATH_RESPONSE"; downloads complete.
  kwik BP: the 10 MB download arrives empty.
- msquic H, LR, C20, U, R: "Missing files" with all containers exiting 0;
  its multi-file cases pass.
- neqo Z: "Client sent too much data in 1-RTT packets" (0-RTT not fully
  accepted). neqo C1: 52 handshakes counted instead of 50.
- Client-side: mvfst L1/C1/Z (no key log written; one connection reused for
  all requests); quiche M (client panics with "Too many open files", possibly
  provoked by a high concurrent-stream limit).
