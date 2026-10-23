Medians of 3 runs per side. h2c and h3 (h2load): percentiles from h2load's per-request log.

| backend | case | side | req/s | p50 ms | p99 ms | timeouts | Recv-Q peak | mem MB | wake p50 / p99 / max ms (timeouts) |
|---|---|---|---|---|---|---|---|---|---|
| epoll | h3 | A | 418,755 | 1.61 | 2.18 | 0 | 0 | 52 |  |
| epoll | h3 | B | 391,389 | 1.74 | 2.31 | 0 | 0 | 34 |  |
| uring | h3 | A | 376,214 | 1.59 | 5.11 | 0 | 0 | 48 |  |
| uring | h3 | B | 350,651 | 1.70 | 5.57 | 0 | 0 | 32 |  |
