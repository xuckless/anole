Medians per side; h2c and h3 percentiles from h2load's per-request log, wsecho from its RTT samples.

| backend | case | side | req/s | vs v0.3.1 | p50 ms | p99 ms | µs CPU/req | mem MB | runs |
|---|---|---|---|---|---|---|---|---|---|
| uring | h2c64 | v0.3.1 | 1,758,236 | 1.000 | 8.23 | 21.31 | 2.410 | 110 | 1757.1k / 1758.2k / 1679.5k / 1779.0k / 1779.3k |
| uring | h2c64 | 0.4.1-rc | 1,806,776 | 1.028 | 7.84 | 20.53 | 2.333 | 107 | 1722.2k / 1754.4k / 1806.8k / 1814.9k / 1833.7k |
