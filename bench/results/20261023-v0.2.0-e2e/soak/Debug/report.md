# Soak: Debug

| phase | CPU (charged) | RSS start → end (MB) | RSS max | slope, after the first 1 min | anon slope | requests ok | errors |
|---|---|---|---|---|---|---|---|
| 1 | 0.57 | 37.1 → 37.6 | 38.7 | +9.0 KB/min (+0.53 MB/h) | +78.9 KB/min (+4.62 MB/h) | 1,690,802 | 0 |

Idle RSS (the last sample of each idle stretch): before 24.9 MB, after phase 1 34.6 MB

| phase | minutes | RSS mean (MB) | RSS max (MB) | anon mean (MB) |
|---|---|---|---|---|
| 1 | 0–10 | 37.6 | 38.7 | 16.1 |

| stream | phase | ok/s | p50 ms | p99 ms | errors |
|---|---|---|---|---|---|
| h1ka | 1 | 1094 | 0.19 | 1.05 | 0 |
| h1close | 1 | 182 | 0.24 | 1.81 | 0 |
| tlsclose | 1 | 90 | 1.84 | 2.86 | 0 |
| h2big | 1 | 1336 | 0.48 | 1.52 | 0 |
| h2cecho | 1 | 63 | 0.88 | 3.09 | 0 |
| h3 | 1 | 53 | 0.34 | 1.91 | 0 |

Exit after SIGTERM: code 0, logged "server stopped cleanly"; allocator leak lines: 0.
