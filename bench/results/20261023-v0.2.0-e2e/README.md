# 0.2.0 end-to-end: soak, leaks, regression A/B (2026-10-23)

0.2.0 is `release-0.2.0` at 91c7378; v0.1.3 is c259b05. The machine is 1 CPU
/ 2 GB.

## Soak, ReleaseSafe, 2 h

- **Setup:** examples/full under bench/soak's six-stream mix, at half of a
  capacity probe: ~10,480 req/s, CPU 0.49.
- **Requests:** 75.4 M, with **0 errors** on every stream.
- **Memory:** RSS sampled every 30 s.

| minutes | RSS mean (MB) | RSS max | anon mean |
|---|---|---|---|
| 0–10 | 18.0 | 19.3 | 11.5 |
| 30–40 | 18.7 | 19.6 | 12.3 |
| 60–70 | 18.6 | 19.5 | 12.3 |
| 90–100 | 17.9 | 18.8 | 12.5 |
| 110–120 | 16.5 | 17.4 | 12.8 |

- **Idle RSS:** 9.9 MB before, 12.0 MB after.
- **Fitted slope after the first 10 min:** RSS −0.94 MB/h; anon
  +0.36 MB/h (1.3 MB over the 2 h).
- **SIGTERM:** exit 0, "server stopped cleanly", **0 SafeAllocator leak
  lines**.

| stream | req/s | p50 ms | p99 ms | errors |
|---|---|---|---|---|
| h1 keep-alive | 4,099 | 0.08 | 0.48 | 0 |
| h1 new connection per request | 678 | 0.14 | 0.82 | 0 |
| TLS h1 handshake churn | 340 | 0.57 | 1.30 | 0 |
| TLS h2 /big gzip | 4,910 | 0.33 | 0.83 | 0 |
| h2c POST /echo 64 KiB | 239 | 0.50 | 1.24 | 0 |
| h3 | 211 | 0.13 | 0.82 | 0 |

## Debug, 10 min

- **Load:** ~2,820 req/s (half of Debug's probe), CPU 0.57; 1.69 M
  requests, 0 errors.
- **RSS:** 24.9 MB idle, 37–38.7 MB under load, 34.6 MB idle after.
- **SIGTERM:** exit 0, clean stop, **0 leaks**.

## Regression A/B: v0.1.3 against 0.2.0

The bench server (`bench/servers/anole`, ReleaseFast) runs on 1 CPU; each
cell is the median of 3 rested, interleaved runs.
- **h1:** wrk `/json` c=256.
- **h2c:** h2load c=256 m=10.
- **h3:** h2load `--alpn-list=h3` c=64 m=10, the #78 workload.

p50 and p99 for h2c and h3 come from h2load's per-request log.

| backend | case | v0.1.3 req/s | 0.2.0 req/s | B/A | v0.1.3 p99 | 0.2.0 p99 | B/A |
|---|---|---|---|---|---|---|---|
| epoll | h1 c256 | 218,592 | 227,536 | 1.041 | 1.23 ms | 1.20 ms | 0.98 |
| epoll | h2c | 647,245 | 636,576 | **0.984** | 4.28 ms | 4.34 ms | 1.01 |
| epoll | h3 | 367,675 | 419,169 | **1.140** | 5.22 ms | 2.19 ms | **0.42** |
| io_uring | h1 c256 | 242,042 | 242,266 | 1.001 | 1.14 ms | 1.14 ms | 1.00 |
| io_uring | h2c | 674,065 | 667,611 | 0.990 | 4.22 ms | 4.28 ms | 1.02 |
| io_uring | h3 | 383,386 | 372,591 | **0.972** | 4.88 ms | 5.15 ms | **1.06** |

- **h3:** +14% on epoll, with the p99 cut by 58%. On io_uring it is −2.8%
  with p99 +6%, the same in all three rounds. Memory is lower there: 46
  against 54 MB.
- **h2c:** slightly lower on both backends: −1.6% on epoll and −1.0% on
  io_uring, consistent across rounds.
- **h1:** +4% on epoll and level on io_uring.

## Harness changes for 0.2.0

There are no changes to Anole's code.
- **examples/full:** built as is.
- **bench/servers/anole:** builds against both versions through comptime
  checks:
  - `server` becomes `timeouts`/`limits`;
  - `Rooms.init` takes options;
  - the JWT `leeway`.
- **bench/soak:** gained IMAGE, SAMPLE and SETTLE.
- **bench/repro/conns-ab.sh:** gained the h3 case, plus percentiles from
  h2load's per-request log.
