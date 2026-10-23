Medians per side; h2c and h3 percentiles from h2load's per-request log, wsecho from its RTT samples.

| backend | case | side | req/s | vs a | p50 ms | p99 ms | mem MB | runs |
|---|---|---|---|---|---|---|---|---|
| epoll | plain | a | 235,857 | 1.000 | 1.07 | 1.16 | 9 | 239.7k / 227.5k / 235.9k |
| epoll | plain | b | 226,285 | 0.959 | 1.15 | 1.18 | 9 | 226.3k / 222.7k / 237.7k |
| epoll | plain | b0 | 238,387 | 1.011 | 1.07 | 1.16 | 9 | 239.2k / 238.4k / 230.9k |
| epoll | json | a | 233,056 | 1.000 | 1.07 | 1.17 | 9 | 231.5k / 233.1k / 236.0k |
| epoll | json | b | 221,971 | 0.952 | 1.15 | 1.19 | 9 | 231.9k / 220.2k / 222.0k |
| epoll | json | b0 | 232,179 | 0.996 | 1.09 | 1.18 | 8 | 232.2k / 228.7k / 237.3k |
| uring | h3 | a | 363,080 | 1.000 | 1.65 | 5.34 | 33 | 363.3k / 363.1k / 361.6k |
| uring | h3 | b | 356,914 | 0.983 | 1.68 | 5.43 | 33 | 355.8k / 359.5k / 356.9k |
| uring | h3 | b0 | 362,883 | 0.999 | 1.65 | 5.36 | 33 | 352.8k / 364.9k / 362.9k |
