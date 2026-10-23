# Video call, pure relay (2026-10-22)

[bench/videocall](../../videocall) with `MEDIA_DEFLATE=off`: every server
relays media as it arrives, with no compression.
- **Setup:** 1 CPU / 2 GB, no swap.
- **Ramp:** +10 users every 5 s, rested ≥ 70 s before each run.
- **Order:** WebSocket (bun, fiber, axum), then WebTransport (bun, fiber,
  axum, anole), then Anole over WebSocket, redone last at the same ramp.
- **Page:** `videocall/index.html` is the interactive version. Its slider
  sets the user count for the bar charts, and the line charts span the whole
  ramp.
- **Raw data:** `videocall/<app>-<transport>/` holds per-second and
  per-step data, the quality scores, and the probe call's arrival log
  (gzipped).
- **The interrupted run:** `anole-ws-1perstep-partial/` is the first Anole
  WebSocket run, at one user every 5 s, stopped at 248 users when the plan
  changed. It's kept for detail but isn't on the page.

"Good quality" means ≥ 99% of video frames shown and ≥ 99% of audio on
time, with video p95 ≤ 200 ms. "Collapse" is the first count with under
10% of frames shown.

## WebSocket

| | good quality | what happened at the limit | memory per user | video p99 at 500 users |
|---|---|---|---|---|
| bun | **~1,270** | stopped accepting at 1,275 (TLS handshakes starved); existing calls ran on | 0.17 MB | 1.9 ms |
| fiber | ~1,040 | accepted everyone, collapsed at ~1,110 | 0.13 MB | 16 ms |
| axum | ~940 | accepted everyone, degraded gradually, collapsed at ~1,270 | 0.72 MB | 21 ms (a ~20 ms floor from the first user) |
| anole | ~760 | accepted everyone, then collapsed suddenly between 760 and 790 | 0.23 MB | 7.7 ms |

## WebTransport

| | good quality | collapse | memory per user |
|---|---|---|---|
| axum (wtransport/quinn) | **~450** | ~530 | 0.15 MB |
| anole | ~360 | ~410 | 0.63 MB |
| fiber (webtransport-go/quic-go) | ~350 | ~410 | 0.32 MB |
| bun (@fails-components, QUICHE addon) | ~80 | ~130 | ~0.5 MB |

## Notes

- **CPU:** every run ends with the server's core saturated. The container
  is charged 0.73–0.88 cores, because the kernel's network interrupt work
  on that core (10–25% of it) isn't charged to the container. That's the
  same for every server.
- **WebTransport costs 2–10× more CPU per user** than WebSocket in every
  stack: QUIC runs its crypto and packet handling inside the app, where
  WebSocket's TCP stack is in the kernel. With separate streams, audio
  mostly survives a video collapse (90–95% on time; Anole 66%).
- **Anole:**
  - Its latency is the lowest at light load (p99 < 2.5 ms to 400 users over
    WebSocket).
  - It uses the most CPU per user over WebSocket, which puts it last there.
    Its collapse is a cliff rather than a slope.
  - Over WebTransport it holds the most memory per session after Bun, and
    its audio stream is the least isolated from video's backlog.
  - It runs as ReleaseSafe, as its docs recommend. These are the profiling
    targets.
- **Axum:** WebSocket p99 sits at ~20 ms even at 100 users. That's likely
  Nagle (no TCP_NODELAY in axum-server's default setup), and it's not
  verified.
