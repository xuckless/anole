# Soak: ReleaseSafe

| phase | CPU (charged) | RSS start → end (MB) | RSS max | slope, after the first minute | anon slope | requests ok | errors |
|---|---|---|---|---|---|---|---|
| 1 | 0.49 | 10.1 → 15.4 | 19.1 | +79.8 KB/min (+4.68 MB/h) | +53.8 KB/min (+3.15 MB/h) | 6,272,399 | 1 |
| 2 | 0.48 | 18.6 → 16.6 | 20.3 | +71.6 KB/min (+4.20 MB/h) | +60.7 KB/min (+3.56 MB/h) | 6,272,393 | 1 |

Idle RSS (the last sample of each idle stretch): before 10.1 MB, after phase 1 14.5 MB, after phase 2 15.7 MB

| stream | phase | ok/s | p50 ms | p99 ms | errors |
|---|---|---|---|---|---|
| h1ka | 1 | 4235 | 0.07 | 0.52 | 0 |
| h1close | 1 | 698 | 0.16 | 0.82 | 0 |
| tlsclose | 1 | 351 | 0.59 | 1.40 | 0 |
| h2big | 1 | 4695 | 0.32 | 0.82 | 0 |
| h2cecho | 1 | 246 | 0.46 | 1.23 | 0 |
| h3 | 1 | 229 | 0.16 | 0.83 | 1 (HTTP3 Stream: Remote is closing the connection: 1) |
| h1ka | 2 | 4235 | 0.07 | 0.51 | 0 |
| h1close | 2 | 698 | 0.15 | 0.75 | 0 |
| tlsclose | 2 | 351 | 0.57 | 1.25 | 0 |
| h2big | 2 | 4695 | 0.32 | 0.76 | 0 |
| h2cecho | 2 | 246 | 0.44 | 1.15 | 0 |
| h3 | 2 | 229 | 0.15 | 0.75 | 1 (HTTP3 Stream: Remote is closing the connection: 1) |

Exit after SIGTERM: code 0, logged "server stopped cleanly"; allocator leak lines: 0.
