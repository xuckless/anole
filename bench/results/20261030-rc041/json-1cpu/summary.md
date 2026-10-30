Medians per side; h2c and h3 percentiles from h2load's per-request log, wsecho from its RTT samples.

| backend | case | side | req/s | vs v0.3.1 | p50 ms | p99 ms | µs CPU/req | mem MB | runs |
|---|---|---|---|---|---|---|---|---|---|
| uring | json | v0.3.1 | 235,780 | 1.000 | 1.08 | 1.21 | 2.382 | 9 | 237.1k / 234.0k / 235.8k / 231.8k / 237.7k |
| uring | json | 0.4.1-rc | 234,672 | 0.995 | 1.09 | 1.22 | 2.349 | 9 | 231.8k / 240.3k / 232.7k / 234.7k / 238.7k |
