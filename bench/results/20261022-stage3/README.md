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

## Raw throughput (in progress)

HTTP/1.1 uses wrk with 256 connections. h2c, h2 over TLS and HTTP/3 use
h2load with 64 connections × 10 streams. So compare servers within a column,
not one column against another. "–" means the stack lacks that protocol, or
it hasn't run yet.

1cpu, GET /json, req/s (median of 3 × 30 s):

| server | h1 | h1-tls | h2c | h2-tls | h3 |
|---|---:|---:|---:|---:|---:|
| anole | 239k | 193k | 681k | 643k | 371k |
| fiber | 220k | 196k | – | – | – |
| axum | 219k | 192k | 267k | 251k | 118k |
| express | 78k | 63k | – | – | – |
| fastify | 120k | 94k | 67k | 62k | – |

4cpu, GET /json, req/s (median of 3 × 30 s):

| server | h1 | h1-tls | h2c | h2-tls | h3 |
|---|---:|---:|---:|---:|---:|
| anole | 590k | 515k | 2.00M | 1.92M | 1.33M |
| fiber | 447k | 400k | – | – | – |
| axum | 452k | 393k | 563k | 522k | 285k |
| express | 243k | 195k | – | – | – |
| fastify | 336k | 267k | 223k | 206k | – |

Notes so far:
- Every protocol Anole serves leads here, at both tiers. On HTTP/1.1, Anole
  leads Fiber and Axum by about 9% at 1 CPU and by about 31% at 4 CPU.
- On h2 and HTTP/3, Anole is 2.5–4.7× Axum, which is the only other stack
  with both. Fastify's h2 is below its own HTTP/1.1.
- Errors: none so far.
