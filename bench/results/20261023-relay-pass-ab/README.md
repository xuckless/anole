# relay-pass before/after (PR #88), Anole only (2026-10-23)

| | |
|---|---|
| **A** | main 7e14ecc |
| **B** | relay-pass 57fdfa9, after two fixes found by this run: the h2 tunnel outbox `drain_pos` panic at 99bbdb9, and the late WebSocket-over-h2 messages at cfcc8ff |
| **Machine** | 1 CPU / 2 GB; rested (≥70 s) and interleaved |
| **Video-call app** | unchanged, built with `--build-arg ANOLE_REF=<sha>` (zig fetch --save) |
| **Bun / Fiber / Axum** | not re-run; they're in [20261022-videocall-relay](../20261022-videocall-relay/README.md) |

## Video call, pure relay

The ramp adds +10 users every 5 s, one ramp per side per transport.
- "Good" is the most users with ≥99% of video shown and p95 ≤ 200 ms.
- CPU per message is the CPU charged to the container at 400 users, per
  relayed media message (32,000/s).
- The interactive version is `videocall/index.html`.

| transport | main good users | relay-pass good users | main CPU/msg | relay-pass CPU/msg | main MB/user | relay-pass MB/user |
|---|---|---|---|---|---|---|
| WebSocket (HTTP/1.1) | ~800 | **~880 (+10%)** | 9.9 µs | 9.5 µs (−4%) | 0.23 | **0.33 (+45%)** |
| WebSocket over HTTP/2 | ~570 | ~550 (−4%) | 17.6 µs | **20.1 µs (+14%)** | 1.35 | **0.75 (−45%)** |
| WebTransport | ~400 | **~450 (+12%)** | 22.5 µs | **19.1 µs (−15%)** | 0.64 | **0.31 (−52%)** |

**WebSocket over HTTP/2 against HTTP/1.1, on relay-pass:**

| | over HTTP/2 | over HTTP/1.1 | difference |
|---|---|---|---|
| good users | 550 | 880 | −38% |
| CPU per message | 20.1 µs | 9.5 µs | 2.1× |

Far outside 10%.

For context, from 20261022, the users with good quality:
- **WebSocket:** Bun ~1,270, Fiber ~1,040, Axum ~940.
- **WebTransport:** Axum ~450, Fiber ~350, Bun ~80.

## WebSockets: the suite's ws scenario

Epoll; the mean of 2 alternating rounds.

| case | main | relay-pass | B/A |
|---|---|---|---|
| idle memory per socket (10,000) | 24.3 KB | 24.3 KB | 1.00 |
| echo c=64 | 276.6k msg/s | 277.1k | 1.00 |
| echo c=1024 | 233.0k | 234.6k | 1.01 |
| fan-out 100 × 1,000 Hz (p99) | 3.0 ms | 1.7 ms | |
| **fan-out 1,000 × 1,000 Hz** | 269k msg/s, 144 MB | 646k, 37 MB | **2.40** |
| fan-out 10,000 × 100 Hz | 189k | 193k | 1.02 |
| **trading 2,000 bots, feed** | 234k msg/s, 218 MB | 632k, 77 MB | **2.70** |
| **trading 2,000 bots, order RTT p99** | 11.8 ms | 117.9 ms | **10× worse** |
| trading 500 bots, order RTT p99 | 0.40 / 2.15 ms | 0.41 / 2.40 ms | noisy, same |

## HTTP/3, the #78 workload

h2load `--alpn-list=h3`, c=64 m=10, `/json`, bench server ReleaseFast;
medians of 3.

| backend | main req/s | relay-pass req/s | B/A | main p99 | relay-pass p99 | main mem | relay-pass mem |
|---|---|---|---|---|---|---|---|
| epoll | 418,755 | 391,389 | **0.935** | 2.18 ms | 2.31 ms | 52 MB | 34 MB |
| io_uring | 376,214 | 350,651 | **0.932** | 5.11 ms | 5.57 ms | 48 MB | 32 MB |

## Summary

**Wins:**
- broadcast/fan-out throughput, 2.4–2.7×, with 3–4× less memory;
- WebSocket and WebTransport users per core, +10–12%;
- WebTransport CPU, −15%, and its memory per user, −52%;
- WebSocket-over-h2 memory, −45%;
- HTTP/3 memory, −35%.

**Regressions:**
- **HTTP/3 req/s:** −6.5% on both backends, outside the −3% target.
- **Order round trip:** 10× worse at p99 under saturated fan-out.
- **WebSocket over HTTP/1.1:** +45% memory per user.
- **WebSocket over HTTP/2:** +14% CPU per message.
