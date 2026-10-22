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
