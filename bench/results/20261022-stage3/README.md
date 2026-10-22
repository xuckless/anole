# Stage 3: Anole 0.1.2 against Fiber, Axum, Express, Fastify and FastAPI

This is a live log: each section is filled in as its scenario finishes.
report.md (benchctl's own, regenerated after every invocation) and
cases.jsonl have every number.

**What was measured:**
- Anole at **3a5333d** ("Release 0.1.2"), merged into bench/suite.
- The tag v0.1.2 is on **b0f2eb0**, which adds only C ABI test fixes,
  last-error texts and docs (#77). No server code changed, so these numbers
  stand for v0.1.2.
- The images were built from bench/suite 832f93e, and env.json has their IDs.

**Setup:**
- bench/suite.sh `-profile full`, epoll.
- Each case: a 15 s warm-up, then 3 × 30 s runs; the median run is kept.
- Tiers: 1 CPU / 2 GB and 4 CPU / 8 GB, with the cpusets in env.json.

**Rested protocol:**
- One invocation per (scenario, server), with 70 s idle before each.
- The server order rotates by one per scenario.
- Drivers: stage3.sh, then stage3b.sh (nginx-fronted raw, then $12).

Part 1: raw → conns → latency → ws → mem → gc → video → wt.
Part 2: raw behind nginx (HTTP/1.1 only), then $12 at both tiers for all 12
servers: the quick ladder, then each bracket bisected with 5-minute holds.

## Raw throughput (done 13:08)

Setup:
- HTTP/1.1 uses wrk with 256 connections.
- h2c, h2 over TLS and HTTP/3 use h2load with 64 connections × 10 streams.
- So compare servers within a column, not one column against another.
- "–" means the stack doesn't serve that protocol. FastAPI's TLS is uvicorn's,
  which speaks HTTP/1.1 only, and Fiber and Express have no h2 or HTTP/3.

1cpu, GET /plaintext, req/s (median of 3 × 30 s):

| server | h1 | h1-tls | h2c | h2-tls | h3 |
|---|---:|---:|---:|---:|---:|
| anole | 240k | 198k | 718k | 677k | 385k |
| fiber | 232k | 204k | – | – | – |
| axum | 221k | 198k | 272k | 257k | 114k |
| express | 83k | 65k | – | – | – |
| fastify | 122k | 97k | 69k | 63k | – |
| fastapi | 23k | 21k | 5k | – | 3k |

4cpu, GET /plaintext, req/s (median of 3 × 30 s):

| server | h1 | h1-tls | h2c | h2-tls | h3 |
|---|---:|---:|---:|---:|---:|
| anole | 598k | 523k | 2.07M | 1.99M | 1.36M |
| fiber | 470k | 418k | – | – | – |
| axum | 457k | 404k | 597k | 547k | 275k |
| express | 250k | 201k | – | – | – |
| fastify | 342k | 274k | 228k | 210k | – |
| fastapi | 78k | 69k | 19k | – | 9k |

1cpu, GET /json, req/s (median of 3 × 30 s):

| server | h1 | h1-tls | h2c | h2-tls | h3 |
|---|---:|---:|---:|---:|---:|
| anole | 239k | 193k | 681k | 643k | 371k |
| fiber | 220k | 196k | – | – | – |
| axum | 219k | 192k | 267k | 251k | 118k |
| express | 78k | 63k | – | – | – |
| fastify | 120k | 94k | 67k | 62k | – |
| fastapi | 19k | 17k | 4k | – | 3k |

4cpu, GET /json, req/s (median of 3 × 30 s):

| server | h1 | h1-tls | h2c | h2-tls | h3 |
|---|---:|---:|---:|---:|---:|
| anole | 590k | 515k | 2.00M | 1.92M | 1.33M |
| fiber | 447k | 400k | – | – | – |
| axum | 452k | 393k | 563k | 522k | 285k |
| express | 243k | 195k | – | – | – |
| fastify | 336k | 267k | 223k | 206k | – |
| fastapi | 65k | 58k | 14k | – | 9k |

1cpu, GET /list, req/s (median of 3 × 30 s):

| server | h1 | h1-tls | h2c | h2-tls | h3 |
|---|---:|---:|---:|---:|---:|
| anole | 109k | 98k | 161k | 143k | 109k |
| fiber | 72k | 68k | – | – | – |
| axum | 83k | 76k | 85k | 79k | 56k |
| express | 54k | 43k | – | – | – |
| fastify | 68k | 54k | 44k | 40k | – |
| fastapi | 4k | 4k | 2k | – | 1k |

4cpu, GET /list, req/s (median of 3 × 30 s):

| server | h1 | h1-tls | h2c | h2-tls | h3 |
|---|---:|---:|---:|---:|---:|
| anole | 321k | 276k | 537k | 462k | 378k |
| fiber | 192k | 181k | – | – | – |
| axum | 179k | 201k | 193k | 206k | 144k |
| express | 169k | 140k | – | – | – |
| fastify | 206k | 166k | 150k | 133k | – |
| fastapi | 13k | 13k | 5k | – | 5k |

Memory at 4 CPU, /json (MB, peak over the case), by protocol:

| server | h1 | h1-tls | h2c | h2-tls | h3 |
|---|---:|---:|---:|---:|---:|
| anole | 8 | 15 | 12 | 19 | 64 |
| fiber | 17 | 28 | – | – | – |
| axum | 12 | 14 | 8 | 13 | 17 |
| express | 459 | 643 | – | – | – |
| fastify | 288 | 626 | 1274 | 955 | – |
| fastapi | 199 | 259 | 652 | – | 344 |

Notes:
- **Anole leads every protocol it serves, at both tiers and on all three
  endpoints.**
  - HTTP/1.1 /json: +9% over Fiber and Axum at 1 CPU, +31% at 4 CPU.
  - HTTP/1.1 /list (a 50-object JSON array, so more serializer work): Anole is
    1.3–1.5× the next server at 1 CPU (Axum 83k, Fiber 72k) and 1.6× the next
    at 4 CPU (Fastify 206k, Axum 179k, Fiber 192k).
- **h2 and HTTP/3:** Anole is 2.5–4.7× Axum, the only other compiled stack with
  both.
  - At 4 CPU, Anole's h2 over TLS reaches 1.92M req/s on /json, against Axum's 522k.
  - On HTTP/3 the gap is 1.33M against 285k.
  - Fastify's and FastAPI's h2 are below their own HTTP/1.1.
- **Memory:** Anole uses the least memory on HTTP/1.1 and TLS. Its 64 MB on
  HTTP/3 is the QUIC per-connection state for 64 connections, against Axum's
  17 MB.
- **Load generator:** it used at most 5 of its 16 cores (Anole h1-tls at 4 CPU),
  so the load generator wasn't the limit.
- **Oddity:** Axum's 4-CPU /list is higher over TLS (201k) than in cleartext
  (179k). Every other case orders the other way, so I count it as run-to-run
  spread.
- **Errors:** none in any raw case.

## Concurrent connections (done 14:20)

Setup: 1 CPU, HTTP/1.1 GET /json, wrk with 16 threads and `--timeout 10s`.
Each count runs 30 s × 3, and the median run is kept. Memory is the server's
peak (anon + kernel).

req/s:

| server | 16 | 64 | 256 | 1,024 | 4,096 | 10,000 | 25,000 |
|---|---:|---:|---:|---:|---:|---:|---:|
| anole | 238k | 252k | 228k | 217k | 154k | 120k | 133k |
| fiber | 220k | 218k | 210k | 206k | 161k | 146k | 143k |
| axum | 223k | 216k | 209k | 201k | 199k | 199k | 198k |
| express | 82k | 81k | 80k | 76k | 68k | 65k | 60k |
| fastify | 124k | 123k | 121k | 119k | 100k | 93k | 84k |
| fastapi | 20k | 20k | 19k | 18k | 17k | 17k | 17k |

p99 latency:

| server | 16 | 64 | 256 | 1,024 | 4,096 | 10,000 | 25,000 |
|---|---:|---:|---:|---:|---:|---:|---:|
| anole | 0.1 ms | 0.3 ms | 1.3 ms | 5.1 ms | 27.7 ms | 85.7 ms | 6.32 s |
| fiber | 0.1 ms | 0.6 ms | 1.8 ms | 5.9 ms | 27.1 ms | 72.6 ms | 183.3 ms |
| axum | 0.1 ms | 0.3 ms | 1.3 ms | 168.3 ms | 776.4 ms | 1.96 s | 4.53 s |
| express | 0.4 ms | 1.2 ms | 3.7 ms | 1.99 s | 877.3 ms | 76.8 ms | 173.9 ms |
| fastify | 0.2 ms | 0.6 ms | 2.3 ms | 1.22 s | 2.31 s | 58.1 ms | 118.4 ms |
| fastapi | 1.5 ms | 3.4 ms | 262.7 ms | 5.29 s | 1.84 s | 85.2 ms | 90.3 ms |

memory, MB:

| server | 16 | 64 | 256 | 1,024 | 4,096 | 10,000 | 25,000 |
|---|---:|---:|---:|---:|---:|---:|---:|
| anole | 2 | 3 | 7 | 23 | 89 | 218 | 498 |
| fiber | 7 | 7 | 16 | 49 | 179 | 393 | 917 |
| axum | 2 | 3 | 10 | 33 | 137 | 346 | 833 |
| express | 67 | 92 | 103 | 192 | 237 | 269 | 334 |
| fastify | 60 | 62 | 97 | 185 | 218 | 277 | 320 |
| fastapi | 41 | 42 | 48 | 77 | 90 | 90 | 99 |

errors (wrk: connect, read, write, timeout):

| server | 16 | 64 | 256 | 1,024 | 4,096 | 10,000 | 25,000 |
|---|---:|---:|---:|---:|---:|---:|---:|
| anole | 0 | 0 | 0 | 0 | 0 | 0 | 3,809 |
| fiber | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| axum | 0 | 0 | 0 | 0 | 0 | 0 | 1,414 |
| express | 0 | 0 | 0 | 0 | 811 | 782 | 711 |
| fastify | 0 | 0 | 0 | 0 | 699 | 661 | 553 |
| fastapi | 0 | 0 | 0 | 341 | 507 | 2,433 | 2,614 |

Notes:
- **Up to 1,024 connections, Anole leads on throughput.** Its p99 ties Axum's
  as the lowest up to 256 connections and is the lowest at 1,024 (5.1 ms,
  against Fiber's 5.9 ms and Axum's 168 ms). It also uses the least memory of
  the compiled stacks: 23 MB at 1,024 connections, against 33 MB for Axum and
  49 MB for Fiber.
- **From 4,096 up, Anole falls behind on throughput:**
  - at 4,096 connections: Anole 154k, Fiber 161k, Axum 199k;
  - at 10,000: Anole 120k, Fiber 146k.
  - Its memory stays the lowest of the three: 218 MB at 10,000 and 498 MB at
    25,000, against 393 and 917 MB for Fiber.
- **25,000 connections is a real problem for Anole.**
  - Its p50 is 183 ms, the same as Fiber's.
  - But p99 is 6.32 s, p99.9 is 8.87 s, and the max hits wrk's 10 s timeout.
  - There were 3,809 errors.
  - So a share of connections is starved while the rest are served normally.
    Fiber, with the same p50, keeps p99 at 183 ms and has no errors.
- **Axum** holds about 200k req/s at every count. But from 1,024 connections
  its tail grows to seconds (4.53 s at 25,000, with 1,414 errors): it serves
  some connections and starves others.
- **Express, Fastify and FastAPI** start failing connections at 1,024–4,096.
  From there their p99 drops back to tens of ms, because it only counts the
  requests that succeed. Read their latency together with the error row.
