Medians of 3 runs per side. h2c and h3 (h2load): percentiles from h2load's per-request log.

| backend | case | side | req/s | p50 ms | p99 ms | timeouts | Recv-Q peak | mem MB | wake p50 / p99 / max ms (timeouts) |
|---|---|---|---|---|---|---|---|---|---|
| epoll | c256 | A | 218,592 | 1.17 | 1.23 | 0 | 0 | 9 |  |
| epoll | c256 | B | 227,536 | 1.14 | 1.20 | 0 | 0 | 9 |  |
| epoll | h2c | A | 647,245 | 3.92 | 4.28 | 0 | 0 | 33 |  |
| epoll | h2c | B | 636,576 | 3.99 | 4.34 | 0 | 0 | 33 |  |
| epoll | h3 | A | 367,675 | 1.64 | 5.22 | 0 | 0 | 51 |  |
| epoll | h3 | B | 419,169 | 1.62 | 2.19 | 0 | 0 | 52 |  |
| uring | c256 | A | 242,042 | 1.05 | 1.14 | 0 | 32 | 9 |  |
| uring | c256 | B | 242,266 | 1.05 | 1.14 | 0 | 0 | 9 |  |
| uring | h2c | A | 674,065 | 3.74 | 4.22 | 0 | 0 | 33 |  |
| uring | h2c | B | 667,611 | 3.78 | 4.28 | 0 | 0 | 33 |  |
| uring | h3 | A | 383,386 | 1.56 | 4.88 | 0 | 0 | 54 |  |
| uring | h3 | B | 372,591 | 1.61 | 5.15 | 0 | 0 | 46 |  |
