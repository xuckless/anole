# 0.4.0 features on p3/all (fea6123)

The image is `anole-bench/anole:p3`, the bench server on p3/all fea6123. Driver: `bench/repro/v040-features.sh`.
- Every run gets a fresh server and rests 70 s first.
- There are 2 rounds, with the sides rotating.
- Each run is 30 s, unless noted. Every run is in run.log.

## Fan-in (1-CPU front, 2-CPU upstream, wrk c256 on /fanin)

| backend | client | req/s (r1 / r2) | p99 ms | upstream conns |
|---|---|---|---|---|
| epoll | h1 pool | 94,767 / 91,898 | 3.01 / 3.07 | 256 |
| epoll | shared h2 | 20,657 / 20,653 | 2.01 / 2.09 | 1 |
| io_uring | h1 pool | 100,572 / 102,942 | 2.81 / 2.75 | 256 |
| io_uring | shared h2 | 20,654 / 20,665 | 1.93 / 1.86 | 1 |

- **The shared HTTP/2 client holds a fixed cap of about 20.66k req/s.** All four runs, on both backends, land within 12 req/s of each other. That is 4.5–4.9× below the h1 pool. The front used 0.09–0.10 of a core in the h2 runs, against 0.63–0.65 with the h1 pool, so it is waiting, not busy. 1 / 20,660 s is 48.4 µs, about one loopback round trip. The hypothesis, not checked in code: the shared client has only one request in flight on the connection at a time.
- **A wedge, seen once (after the runs, not reproduced):**
  - Setup: a fresh server pair, then a concurrency sweep through the shared h2 client, 8 s per step.
  - The steps gave c1 44,208 req/s, c4 32,877, then 0 from c16 on.
  - Afterwards, a single `/fanin` request answered 500 after 30 s, and the front logged 340 `Timeout` errors.
  - The upstream itself (`/json`) kept answering, so the shared client's connection stayed wedged.
  - Not checked: whether it reproduces, whether it has the same cause as the 20.66k cap, and whether it still happens on later commits.

## gRPC (TestService/UnaryCall, one server, grpcload 4 connections × 64 calls)

| backend | target | calls/s (r1 / r2) | p99 ms |
|---|---|---|---|
| epoll | Unix socket | 373,490 / 377,619 | 0.36 / 0.35 |
| epoll | h2c | 305,458 / 299,641 | 0.41 / 0.41 |
| epoll | TLS | 288,302 / 286,309 | 0.43 / 0.42 |
| io_uring | Unix socket | 362,285 / 360,724 | 0.37 / 0.37 |
| io_uring | h2c | 311,698 / 314,488 | 0.41 / 0.40 |
| io_uring | TLS | 296,085 / 291,548 | 0.44 / 0.45 |

The Unix socket is about 23% above h2c, and TLS costs about 5% against h2c. No errors.

## SSE topics (50,000 subscribers, 1 CPU, 4 GB)

| backend | run | RSS idle empty | RSS 50k subscribed | idle CPU | fan-out to all: median / max ms | per-subscriber p50 / p99 ms | RSS after 20 events |
|---|---|---|---|---|---|---|---|
| epoll | r1 | 6.9 MB | 95.3 MB | 0.08% | 360 / 467 | 185 / 416 | 497 MB |
| epoll | r2 | 6.9 MB | 94.0 MB | 0.08% | 386 / 469 | 191 / 409 | 539 MB |
| io_uring | r1 | 6.3 MB | 92.6 MB | 0.09% | 351 / 437 | 179 / 408 | 517 MB |
| io_uring | r2 | 6.5 MB | 89.6 MB | 0.08% | 352 / 424 | 175 / 380 | 564 MB |

- Every subscriber got every event: 50,000 of 50,000, no connect errors, no streams ended.
- **RSS grows about 5× after publishing:** from about 95 MB to 0.5–0.56 GB (cgroup 0.89–0.98 GB), and it stays there after the load ends. The source is likely the per-subscriber write buffers, which don't shrink after the burst. This is not diagnosed.
