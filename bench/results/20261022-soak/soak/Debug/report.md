# Soak: Debug

| phase | CPU (charged) | RSS start → end (MB) | RSS max | slope, after the first minute | anon slope | requests ok | errors |
|---|---|---|---|---|---|---|---|
| 1 | 0.58 | 24.5 → 36.7 | 38.7 | +4.7 KB/min (+0.28 MB/h) | +6.2 KB/min (+0.37 MB/h) | 834,603 | 0 |

Idle RSS (the last sample of each idle stretch): before 24.5 MB, after phase 1 33.9 MB

| stream | phase | ok/s | p50 ms | p99 ms | errors |
|---|---|---|---|---|---|
| h1ka | 1 | 1122 | 0.24 | 1.09 | 0 |
| h1close | 1 | 186 | 0.57 | 2.11 | 0 |
| tlsclose | 1 | 93 | 1.93 | 3.04 | 0 |
| h2big | 1 | 1256 | 0.46 | 1.58 | 0 |
| h2cecho | 1 | 65 | 0.97 | 3.26 | 0 |
| h3 | 1 | 60 | 0.37 | 1.93 | 0 |

Exit after SIGTERM: code 0, logged "server stopped cleanly"; allocator leak lines: 0.
