# Soak: ReleaseSafe

| phase | CPU (charged) | RSS start → end (MB) | RSS max | slope, after the first 10 min | anon slope | requests ok | errors |
|---|---|---|---|---|---|---|---|
| 1 | 0.49 | 17.3 → 15.8 | 19.8 | -16.0 KB/min (-0.94 MB/h) | +6.2 KB/min (+0.36 MB/h) | 75,434,399 | 0 |

Idle RSS (the last sample of each idle stretch): before 9.9 MB, after phase 1 12.0 MB

| phase | minutes | RSS mean (MB) | RSS max (MB) | anon mean (MB) |
|---|---|---|---|---|
| 1 | 0–10 | 18.0 | 19.3 | 11.5 |
| 1 | 10–20 | 18.6 | 19.4 | 12.0 |
| 1 | 20–30 | 18.5 | 19.5 | 12.2 |
| 1 | 30–40 | 18.7 | 19.6 | 12.3 |
| 1 | 40–50 | 18.8 | 19.6 | 12.2 |
| 1 | 50–60 | 18.6 | 19.5 | 12.3 |
| 1 | 60–70 | 18.6 | 19.5 | 12.3 |
| 1 | 70–80 | 18.8 | 19.8 | 12.4 |
| 1 | 80–90 | 18.8 | 19.8 | 12.5 |
| 1 | 90–100 | 17.9 | 18.8 | 12.5 |
| 1 | 100–110 | 17.5 | 18.4 | 12.6 |
| 1 | 110–120 | 16.5 | 17.4 | 12.8 |

| stream | phase | ok/s | p50 ms | p99 ms | errors |
|---|---|---|---|---|---|
| h1ka | 1 | 4099 | 0.08 | 0.48 | 0 |
| h1close | 1 | 678 | 0.14 | 0.82 | 0 |
| tlsclose | 1 | 340 | 0.57 | 1.30 | 0 |
| h2big | 1 | 4910 | 0.33 | 0.83 | 0 |
| h2cecho | 1 | 239 | 0.50 | 1.24 | 0 |
| h3 | 1 | 211 | 0.13 | 0.82 | 0 |

Exit after SIGTERM: code 0, logged "server stopped cleanly"; allocator leak lines: 0.
