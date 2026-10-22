
### async-db, 1024 connections


p99 ms

| version | median | per round (median of 3 runs) | Δ vs reset on |
|---|---|---|---|
| v0.1.1, reset on (default) | 62.60 | 58.10 / 62.60 / 67.40 |  |
| v0.1.1, ANOLE_PG_RESET=0 | 59.70 | 64.20 / 57.50 / 59.70 | -4.6% |
| #76 pg-reset-auto (5098bb5) | 62.70 | 59.60 / 62.70 / 78.90 | +0.2% |

req/s

| version | median | per round (median of 3 runs) | Δ vs reset on |
|---|---|---|---|
| v0.1.1, reset on (default) | 98,940 | 99,940 / 96,820 / 98,940 |  |
| v0.1.1, ANOLE_PG_RESET=0 | 123,340 | 123,310 / 123,570 / 123,340 | +24.7% |
| #76 pg-reset-auto (5098bb5) | 123,540 | 123,190 / 123,540 / 123,930 | +24.9% |

### production-stack, 256 connections


reads req/s

| version | median | per round (median of 3 runs) | Δ vs reset on |
|---|---|---|---|
| v0.1.1, reset on (default) | 126,789 | 126,789 / 125,700 / 128,164 |  |
| v0.1.1, ANOLE_PG_RESET=0 | 127,664 | 128,457 / 127,522 / 127,664 | +0.7% |
| #76 pg-reset-auto (5098bb5) | 128,390 | 128,058 / 128,487 / 128,390 | +1.3% |

reads mean ms

| version | median | per round (median of 3 runs) | Δ vs reset on |
|---|---|---|---|
| v0.1.1, reset on (default) | 32.01 | 32.01 / 32.28 / 31.67 |  |
| v0.1.1, ANOLE_PG_RESET=0 | 31.80 | 31.59 / 31.80 / 31.80 | -0.7% |
| #76 pg-reset-auto (5098bb5) | 31.60 | 31.68 / 31.56 / 31.60 | -1.3% |

writes req/s

| version | median | per round (median of 3 runs) | Δ vs reset on |
|---|---|---|---|
| v0.1.1, reset on (default) | 5,009 | 5,081 / 4,664 / 5,009 |  |
| v0.1.1, ANOLE_PG_RESET=0 | 5,164 | 5,056 / 5,337 / 5,164 | +3.1% |
| #76 pg-reset-auto (5098bb5) | 5,255 | 5,103 / 5,275 / 5,255 | +4.9% |

writes mean ms

| version | median | per round (median of 3 runs) | Δ vs reset on |
|---|---|---|---|
| v0.1.1, reset on (default) | 50.80 | 50.02 / 54.43 / 50.80 |  |
| v0.1.1, ANOLE_PG_RESET=0 | 49.26 | 50.23 / 47.68 / 49.26 | -3.0% |
| #76 pg-reset-auto (5098bb5) | 48.38 | 49.79 / 48.21 / 48.38 | -4.8% |

total req/s

| version | median | per round (median of 3 runs) | Δ vs reset on |
|---|---|---|---|
| v0.1.1, reset on (default) | 131,607 | 131,607 / 130,283 / 133,173 |  |
| v0.1.1, ANOLE_PG_RESET=0 | 133,310 | 133,647 / 132,786 / 133,310 | +1.3% |
| #76 pg-reset-auto (5098bb5) | 133,182 | 133,182 / 133,878 / 132,602 | +1.2% |

### production-stack, 1024 connections


reads req/s

| version | median | per round (median of 3 runs) | Δ vs reset on |
|---|---|---|---|
| v0.1.1, reset on (default) | 110,002 | 110,002 / 109,958 / 110,026 |  |
| v0.1.1, ANOLE_PG_RESET=0 | 110,465 | 110,465 / 110,595 / 110,339 | +0.4% |
| #76 pg-reset-auto (5098bb5) | 110,442 | 110,442 / 110,783 / 110,054 | +0.4% |

reads mean ms

| version | median | per round (median of 3 runs) | Δ vs reset on |
|---|---|---|---|
| v0.1.1, reset on (default) | 143.03 | 143.24 / 142.53 / 143.03 |  |
| v0.1.1, ANOLE_PG_RESET=0 | 142.31 | 142.42 / 141.85 / 142.31 | -0.5% |
| #76 pg-reset-auto (5098bb5) | 142.52 | 142.52 / 141.99 / 143.21 | -0.4% |

writes req/s

| version | median | per round (median of 3 runs) | Δ vs reset on |
|---|---|---|---|
| v0.1.1, reset on (default) | 4,999 | 5,013 / 4,999 / 4,955 |  |
| v0.1.1, ANOLE_PG_RESET=0 | 4,884 | 4,655 / 4,884 / 4,978 | -2.3% |
| #76 pg-reset-auto (5098bb5) | 4,898 | 4,863 / 4,898 / 4,899 | -2.0% |

writes mean ms

| version | median | per round (median of 3 runs) | Δ vs reset on |
|---|---|---|---|
| v0.1.1, reset on (default) | 200.34 | 200.34 / 200.28 / 202.15 |  |
| v0.1.1, ANOLE_PG_RESET=0 | 204.51 | 214.68 / 204.51 / 201.36 | +2.1% |
| #76 pg-reset-auto (5098bb5) | 204.67 | 206.44 / 204.67 / 204.19 | +2.2% |

total req/s

| version | median | per round (median of 3 runs) | Δ vs reset on |
|---|---|---|---|
| v0.1.1, reset on (default) | 115,015 | 115,015 / 114,957 / 115,030 |  |
| v0.1.1, ANOLE_PG_RESET=0 | 115,318 | 115,246 / 115,479 / 115,318 | +0.3% |
| #76 pg-reset-auto (5098bb5) | 114,886 | 114,886 / 115,318 / 114,374 | -0.1% |
