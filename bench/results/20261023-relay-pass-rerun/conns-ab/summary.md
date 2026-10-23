Medians of 3 runs per side. h2c and h3 (h2load): percentiles from h2load's per-request log.

| backend | case | side | req/s | p50 ms | p99 ms | timeouts | Recv-Q peak | mem MB | wake p50 / p99 / max ms (timeouts) |
|---|---|---|---|---|---|---|---|---|---|
| epoll | h3 | A | 417,420 | 1.61 | 2.15 | 0 | 0 | 54 |  |
| epoll | h3 | B | 429,492 | 1.63 | 2.13 | 0 | 0 | 35 |  |
| uring | h3 | A | 377,667 | 1.59 | 5.09 | 0 | 0 | 48 |  |
| uring | h3 | B | 363,513 | 1.65 | 5.33 | 0 | 0 | 33 |  |
