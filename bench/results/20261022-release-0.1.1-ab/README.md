# release-0.1.1 vs main, on HttpArena's profiles

- **A:** main at 938f258.
- **B:** release-0.1.1 at 18bbe33. Its code is the same as 2c716ae: only a
  test requirements file changed. The v0.1.1 tag (42bbce7) adds a test fix
  and an h2 arena trim on top of this.

**Setup.**
- The same HttpArena entry builds both versions. Only the pinned commit
  differs: `entry/build.zig.zon.*`.
- For both versions the entry appends `sslmode=disable` to `DATABASE_URL`.
  release-0.1.1 defaults to `verify-full` for non-loopback hosts.
- The `B reset_session=false` row is B with `ANOLE_PG_RESET=0`, which sets
  `Options.reset_session = false`.
- Both versions pass HttpArena's validator: 57/57 on these profiles,
  including WebSocket and gRPC.

**Method.**
- HttpArena `scripts/benchmark-local.sh` on io_uring, with
  SKIP_TUNE=true and LOADGEN_DOCKER=true.
- The box is an i7-14700F with 28 CPUs. The load generator runs on CPUs
  14–27.
- **Rested protocol:**
  - 70 s idle before every invocation.
  - 3 rounds, with the order alternating A,B / B,A / A,B.
  - In each round, each version's number is the median of the harness's 3
    runs. The table gives the median over rounds, with each round's value.
- **Latency:** p99 from gcannon (baseline, echo-ws, async-db). h2load
  reports no percentiles, so the h2, h2c and gRPC rows give its mean
  request time.

## Summary

**async-db (Postgres pooled reads) is the only result outside noise.**

| Version | Req/s | p99 | vs A |
|---|---|---|---|
| A, main | 124,590 | 55.3 ms | |
| B, release-0.1.1 | 98,450 | 71.7 ms | **−21.0%** |
| B with `reset_session = false` | 123,270 | 62.5 ms | −1.1% |

- B is slower in all 3 rounds: 95–100k against main's 117–126k.
- With the reset off, B is back level with main. So the per-release
  session reset (`reset_session = true`, the new default) costs about 21%
  of this profile's throughput, plus about 16 ms at p99.

**Everything else is within ±3%:**
- h2c baseline and json; h2 over TLS at 256 and 1024 connections. The
  largest difference is −1.9% for h2 over TLS at 256 connections; the
  1024-connection case is +2.7%.
- gRPC unary, plain and TLS.
- HTTP/1.1 baseline.
- WebSocket echo at 512, 4096 and 16384 connections.

The new per-flush write timer and the gRPC changes show no measurable
cost.

## Tables

### async-db, 1024 connections

| version | median req/s | per round (median of 3 runs) | p99 | Δ vs A |
|---|---|---|---|---|
| A main 938f258 | 124,590 | 117,080 / 124,590 / 126,370 | 55.30 ms |  |
| B release-0.1.1 18bbe33 | 98,450 | 95,480 / 100,460 / 98,450 | 71.70 ms | -21.0% |
| B reset_session=false | 123,270 | 119,120 / 124,680 / 123,270 | 62.50 ms | -1.1% |

### baseline, 4096 connections

| version | median req/s | per round (median of 3 runs) | p99 | Δ vs A |
|---|---|---|---|---|
| A main 938f258 | 1,450,000 | 1,450,000 / 1,450,000 / 1,450,000 | 19.20 ms |  |
| B release-0.1.1 18bbe33 | 1,440,000 | 1,450,000 / 1,400,000 / 1,440,000 | 18.10 ms | -0.7% |

### baseline-h2, 256 connections

| version | median req/s | per round (median of 3 runs) | mean lat | Δ vs A |
|---|---|---|---|---|
| A main 938f258 | 4,340,400 | 4,340,400 / 4,315,560 / 4,355,840 | 5.79 ms |  |
| B release-0.1.1 18bbe33 | 4,256,160 | 4,254,140 / 4,303,220 / 4,256,160 | 5.85 ms | -1.9% |

### baseline-h2, 1024 connections

| version | median req/s | per round (median of 3 runs) | mean lat | Δ vs A |
|---|---|---|---|---|
| A main 938f258 | 3,610,080 | 3,407,420 / 3,782,860 / 3,610,080 | 25.49 ms |  |
| B release-0.1.1 18bbe33 | 3,707,300 | 3,430,920 / 3,707,300 / 3,754,160 | 26.09 ms | +2.7% |

### baseline-h2c, 256 connections

| version | median req/s | per round (median of 3 runs) | mean lat | Δ vs A |
|---|---|---|---|---|
| A main 938f258 | 4,561,364 | 4,498,062 / 4,561,364 / 4,595,190 | 5.49 ms |  |
| B release-0.1.1 18bbe33 | 4,580,846 | 4,547,787 / 4,580,846 / 4,629,478 | 5.44 ms | +0.4% |

### baseline-h2c, 1024 connections

| version | median req/s | per round (median of 3 runs) | mean lat | Δ vs A |
|---|---|---|---|---|
| A main 938f258 | 3,950,338 | 3,709,858 / 3,950,338 / 3,966,737 | 24.00 ms |  |
| B release-0.1.1 18bbe33 | 3,924,273 | 3,486,707 / 3,985,234 / 3,924,273 | 24.13 ms | -0.7% |

### baseline-h2c, 4096 connections

| version | median req/s | per round (median of 3 runs) | mean lat | Δ vs A |
|---|---|---|---|---|
| A main 938f258 | 3,206,061 | 3,045,634 / 3,233,719 / 3,206,061 | 107.73 ms |  |
| B release-0.1.1 18bbe33 | 3,211,798 | 3,086,989 / 3,211,798 / 3,220,798 | 110.40 ms | +0.2% |

### echo-ws, 512 connections

| version | median req/s | per round (median of 3 runs) | p99 | Δ vs A |
|---|---|---|---|---|
| A main 938f258 | 1,760,000 | 1,740,000 / 1,780,000 / 1,760,000 | 8.38 ms |  |
| B release-0.1.1 18bbe33 | 1,760,000 | 1,760,000 / 1,770,000 / 1,730,000 | 8.46 ms | +0.0% |

### echo-ws, 4096 connections

| version | median req/s | per round (median of 3 runs) | p99 | Δ vs A |
|---|---|---|---|---|
| A main 938f258 | 1,390,000 | 1,270,000 / 1,420,000 / 1,390,000 | 18.30 ms |  |
| B release-0.1.1 18bbe33 | 1,380,000 | 1,380,000 / 1,380,000 / 1,410,000 | 18.60 ms | -0.7% |

### echo-ws, 16384 connections

| version | median req/s | per round (median of 3 runs) | p99 | Δ vs A |
|---|---|---|---|---|
| A main 938f258 | 1,070,000 | 1,080,000 / 1,050,000 / 1,070,000 | 43.60 ms |  |
| B release-0.1.1 18bbe33 | 1,050,000 | 1,050,000 / 1,050,000 / 1,050,000 | 43.20 ms | -1.9% |

### json-h2c, 1024 connections

| version | median req/s | per round (median of 3 runs) | mean lat | Δ vs A |
|---|---|---|---|---|
| A main 938f258 | 1,063,101 | 1,059,575 / 1,063,101 / 1,063,889 | 31.18 ms |  |
| B release-0.1.1 18bbe33 | 1,064,059 | 1,053,843 / 1,064,059 / 1,064,763 | 31.09 ms | +0.1% |

### json-h2c, 4096 connections

| version | median req/s | per round (median of 3 runs) | mean lat | Δ vs A |
|---|---|---|---|---|
| A main 938f258 | 934,086 | 844,201 / 951,391 / 934,086 | 150.54 ms |  |
| B release-0.1.1 18bbe33 | 924,643 | 876,768 / 956,114 / 924,643 | 152.68 ms | -1.0% |

### unary-grpc, 256 connections

| version | median req/s | per round (median of 3 runs) | mean lat | Δ vs A |
|---|---|---|---|---|
| A main 938f258 | 157,533 | 155,347 / 157,533 / 157,996 | 160.07 ms |  |
| B release-0.1.1 18bbe33 | 157,174 | 156,954 / 157,376 / 157,174 | 160.40 ms | -0.2% |

### unary-grpc, 1024 connections

| version | median req/s | per round (median of 3 runs) | mean lat | Δ vs A |
|---|---|---|---|---|
| A main 938f258 | 141,927 | 140,627 / 143,275 / 141,927 | 668.80 ms |  |
| B release-0.1.1 18bbe33 | 140,606 | 138,602 / 140,606 / 141,350 | 674.15 ms | -0.9% |

### unary-grpc-tls, 256 connections

| version | median req/s | per round (median of 3 runs) | mean lat | Δ vs A |
|---|---|---|---|---|
| A main 938f258 | 118,579 | 118,579 / 116,834 / 120,677 | 194.63 ms |  |
| B release-0.1.1 18bbe33 | 120,511 | 120,511 / 119,618 / 120,643 | 191.33 ms | +1.6% |

### unary-grpc-tls, 1024 connections

| version | median req/s | per round (median of 3 runs) | mean lat | Δ vs A |
|---|---|---|---|---|
| A main 938f258 | 114,645 | 112,471 / 114,645 / 115,442 | 507.34 ms |  |
| B release-0.1.1 18bbe33 | 113,926 | 112,695 / 114,461 / 113,926 | 513.86 ms | -0.6% |
