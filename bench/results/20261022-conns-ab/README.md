# Connection-count A/B: Anole main vs PR #82 (2026-10-22)

| | |
|---|---|
| **A** | main 2ad0967 (zio 683612b) |
| **B** | PR #82 head 7032492 (`zio-upstream-merge`: zio b497487, an upstream merge plus the run-queue FIFO fix and accept/spawn budgets, fast_accept on) |
| **Server** | the bench server (`bench/servers/anole`, ReleaseFast, `-Dcpu=baseline`), built against each tree |
| **Machine** | 1 CPU / 2 GB, on epoll (Docker's default seccomp) and io_uring (seccomp unconfined) |
| **Method** | fresh server per run, rested 70 s first, sides alternating per round, 2 runs each; medians below |

The runner is `bench/repro/conns-ab.sh`. The parked wake is
`bench/tools/cmd/parkwake`: 2,000 idle keep-alive connections, each proved
with one request, then woken at once ~15 s into wrk c=20000.

| backend | case | side | req/s | p50 ms | p99 ms | timeouts | Recv-Q peak | mem MB | wake p50 / p99 / max ms (timeouts) |
|---|---|---|---|---|---|---|---|---|---|
| epoll | c4096 | A | 142,061 | 28.78 | 32.52 | 0 | 142 | 105 |  |
| epoll | c4096 | B | 143,207 | 28.31 | 32.37 | 0 | 0 | 111 |  |
| epoll | c10000 | A | 119,648 | 83.33 | 88.25 | 0 | 1,846 | 246 |  |
| epoll | c10000 | B | 115,582 | 86.83 | 91.85 | 0 | 0 | 253 |  |
| epoll | c25000 | A | 128,118 | 193.25 | 5,970.00 | 422 | 6,152 | 596 |  |
| epoll | c25000 | B | 127,955 | 193.01 | 215.75 | 0 | 2,503 | 645 |  |
| epoll | park | A | 126,651 | 155.78 | 3,975.00 | 0 | 5,102 | 496 | 1,504.1 / 2,687.5 / 2,687.6 (0) |
| epoll | park | B | 134,543 | 146.91 | 169.91 | 0 | 3,367 | 544 | 245.9 / 253.1 / 253.2 (0) |
| epoll | c256 | A | 222,566 | 1.15 | 1.27 | 0 | 0 | 8 |  |
| epoll | c256 | B | 226,030 | 1.14 | 1.26 | 0 | 0 | 9 |  |
| epoll | h2c | A | 656,502 | 3.91 | – | 0 | 1 | 33 |  |
| epoll | h2c | B | 652,187 | 3.92 | – | 0 | 0 | 33 |  |
| uring | c4096 | A | 159,843 | 25.44 | 27.66 | 0 | 520 | 97 |  |
| uring | c4096 | B | 161,917 | 25.05 | 27.37 | 0 | 698 | 107 |  |
| uring | c10000 | A | 122,377 | 81.25 | 510.08 | 0 | 2,630 | 229 |  |
| uring | c10000 | B | 121,697 | 82.15 | 85.28 | 0 | 520 | 259 |  |
| uring | c25000 | A | 138,367 | 175.75 | 6,265.00 | 2,261 | 8,772 | 559 |  |
| uring | c25000 | B | 143,571 | 171.44 | 195.74 | 0 | 5,836 | 591 |  |
| uring | park | A | 139,344 | 140.68 | 4,670.00 | 0 | 6,804 | 465 | 1,305.5 / 2,384.8 / 2,455.2 (0) |
| uring | park | B | 144,543 | 136.26 | 157.91 | 0 | 6,606 | 527 | 221.5 / 227.5 / 227.6 (0) |
| uring | c256 | A | 242,471 | 1.05 | 1.19 | 0 | 0 | 9 |  |
| uring | c256 | B | 242,400 | 1.05 | 1.18 | 0 | 0 | 9 |  |
| uring | h2c | A | 677,773 | 3.77 | – | 0 | 0 | 33 |  |
| uring | h2c | B | 669,916 | 3.81 | – | 0 | 0 | 33 |  |

## Findings

### 25,000 connections

A reproduces the starvation on both backends:

| | A | B |
|---|---|---|
| epoll p99 | 6.0 s | 216 ms |
| epoll timeouts | 189 and 654 | 0 |
| io_uring p99 | 6.3 s | 196 ms |
| io_uring timeouts | 2,041 and 2,481 | 0 |

Throughput is level on epoll, and B is +4% on io_uring.

### Parked wake

| | A | B |
|---|---|---|
| woken connections, p99 (epoll) | 2.69 s | 253 ms |
| woken connections, p99 (io_uring) | 2.38 s | 228 ms |
| busy load's p99 (epoll) | ~4.0 s | 170 ms |
| busy load's p99 (io_uring) | ~4.7 s | 158 ms |
| busy load's throughput | | +4–6% |

### 10,000 connections

- On io_uring, A already has a ~0.5 s p99 (479 and 541 ms); B stays at
  85 ms.
- On epoll both are fine. B is −3.4% on req/s, within the run spread
  (B's rounds were 117k and 114k; A's were 118k and 122k).

### Regression checks

c=256 h1 and h2c are within ±1.2% on both backends, with the same latency.

### Costs

- **Memory:** B uses 5–13% more at high connection counts (epoll c25000:
  645 against 596 MB; park: 544 against 496 MB).
- **Recv-Q:** on epoll, B keeps the listener backlog at 0 up to 10,000
  connections. On io_uring the backlog is a weaker signal: A's peak is
  lower than B's at c=4096.
