# Anole cross-framework benchmarks

Anole against Go Fiber, Go net/http, Axum, Express, Fastify, FastAPI and
nginx on one Linux box, with every server in a pinned, memory-capped
container. Everything here is reproducible from a clean checkout with Docker
alone; the host needs no toolchains.

```sh
bench/suite.sh                                    # quick profile: every scenario, both tiers (< 2 h)
bench/suite.sh -profile full                      # the overnight run: 3 repetitions, longer runs, 5-minute holds
bench/suite.sh -only raw -servers anole,fiber -tiers 1     # one scenario, some servers
NO_BUILD=1 bench/suite.sh -only ws -servers anole          # reuse the images as they are
```

Results land in `bench/results/<UTC date>-<commit>[-tag]/`: `cases.jsonl`
(one JSON line per measured case), `env.json` (commit, CPU, kernel,
governor, cpusets, image ids) and `report.md` (the tables). `benchctl
report <dir>` rebuilds the report from `cases.jsonl`.

## The servers

`SPEC.md` is the contract every server implements: the same routes,
byte-identical responses, the same environment variables. Each lives in
`servers/<name>/` with its Dockerfile, a `manifest.json` (which protocols it
serves and with which library) and a `NOTES.md` (what each protocol took to
turn on, for the ease-of-use comparison).

| Server | HTTP/1.1 | TLS | h2c | HTTP/3 | WebSocket | gRPC | $12 stack |
| --- | --- | --- | --- | --- | --- | --- | --- |
| anole | Anole | BoringSSL, h2 + http/1.1 | Anole | Anole (ngtcp2) | anole.websocket (also over h2) | Anole | `servers/anole/src/pg.zig` + anole.auth |
| fiber | Fiber v3 (fasthttp) | Fiber, http/1.1 only | - | - | gofiber/contrib/websocket | - | pgxpool + golang-jwt |
| gohttp | net/http | net/http, h2 + http/1.1 | net/http | quic-go | coder/websocket | grpc-go | pgxpool + golang-jwt |
| axum | axum::serve (hyper) | axum-server + rustls | hyper | h3 + h3-quinn | axum ws | tonic | sqlx + jsonwebtoken |
| express | Express 5 | node:https, http/1.1 only | - | - | ws | - | pg + jsonwebtoken |
| fastify | Fastify 5 | `http2: true`, h2 + http/1.1 | Fastify | - | @fastify/websocket | @grpc/grpc-js | pg + @fastify/jwt |
| fastapi | uvicorn[standard] | uvicorn, http/1.1 only | Hypercorn | Hypercorn + aioquic | Starlette | grpcio (aio) | asyncpg + PyJWT |
| nginx | nginx 1.30 | OpenSSL, h2 + http/1.1 | - | nginx QUIC | - | - | - |

Where a framework has no protocol of its own, the row uses what developers
in that language reach for: Go's own net/http and quic-go stand in for Fiber
on HTTP/2, HTTP/3 and gRPC; Hypercorn serves the same FastAPI app for h2c
and HTTP/3; a dash means nothing idiomatic exists, and the report shows N/A.

## Fairness rules

- **Idiomatic setups.** Each server is written the way its framework's own
  docs and quick start do it: release builds, default serializers (Fastify's
  response schemas are included because its docs recommend them), no
  hand-tuned socket options, no custom HTTP parsing, and no caching the
  challenge forbids. Logging is at warn with no access log for everyone.
- **Settings changed for everyone, for the same reason.** Keep-alive is at
  least 75 s (the challenge's requirement; Node and uvicorn default to 5 s,
  QUIC stacks to 30 s idle). Request bodies up to 8 MiB. Anole's 10 000
  connection cap and 30 s whole-request timeout are lifted (the connection
  tests go past one, video streams past the other).
- **Same budget.** Every server gets the same cpuset, CPU count (`WORKERS`:
  `GOMAXPROCS`, tokio worker threads, cluster workers, uvicorn workers,
  Anole executors), memory cap with no swap, file limit and database pool.
- **Compiled code targets baseline x86-64** for Zig, Go and Rust alike
  (Zig's own default would be the build host's CPU).
- **Docker's default seccomp profile** applies to every container, so
  io_uring is unavailable and every server, Anole included, runs on epoll.
- **Correctness first.** Every server passes the challenge's golden tests
  (`twelve/test.sh`, byte for byte) before the $12 load runs.

## The machine

Intel i7-14700F (8 P-cores with two threads each, 12 E-cores), 31 GB,
Fedora 44, Docker 29, cgroup v2. `lib/cpus.sh` fixes the cpusets:

| Role | 1-CPU tier | 4-CPU tier |
| --- | --- | --- |
| Server under test | P-core thread 2 (its sibling 3 left idle) | threads 0, 2, 4, 6 (siblings idle) |
| Postgres | E-cores 16-19 (16-27 during the $12 test) | the same |
| Load generators | P-core threads 8-15, E-cores 20-27 | the same |

Tiers: 1 CPU / 2 GB (the $12 droplet) and 4 CPU / 8 GB, no swap.

What to keep in mind when reading the numbers:

- Server and load generator share one machine and talk over loopback, so
  absolute numbers sit above what a network would allow; the comparison is
  what counts.
- On loopback the kernel's receive work runs as softirq time that no cgroup
  is charged for. The report's "cores busy" comes from `/proc/stat` for the
  server's cpuset and includes it; that is the number that says whether a
  server was saturated. A 1-CPU server at 1.00 was.
- `env.json` records the CPU frequency governor. For the steadiest numbers
  run `sudo cpupower frequency-set -g performance` first, and keep the
  desktop off the benchmark cores:
  `sudo systemctl set-property --runtime user.slice AllowedCPUs=20-27`
  (undo with `AllowedCPUs=` empty).

## Scenarios

| Scenario | What it measures | Tools |
| --- | --- | --- |
| `raw` | Max req/s, closed loop, per protocol (HTTP/1.1, HTTP/1.1 over TLS, h2c, h2 over TLS, HTTP/3) and endpoint, both tiers | wrk (256 connections), h2load (64 × 10 streams, `--alpn-list=h3` for QUIC) |
| `conns` | Concurrent users: req/s, p99 and memory from 64 to 10 000 keep-alive connections | wrk |
| `latency` | Latency per language at fixed rates (1k, 5k, 20k req/s and 50%/75% of each server's own max), open loop, coordinated omission corrected | oha `--latency-correction` |
| `twelve` | The $12 server challenge on Postgres (below) | benchctl's load.js driver, k6 for cross-checks |
| `ws` | Idle sockets and their memory, echo throughput, tick fan-out to 100-10 000 subscribers, the trading-bot simulation | benchctl (coder/websocket) |
| `mem` | Memory per idle keep-alive connection, concurrent 1 MiB uploads, the same load under a 256 MB cap | benchctl, wrk |
| `gc` | 1 000 000 retained objects plus an allocation-heavy route; max req/s, then the tail at a fixed rate and the memory sawtooth | wrk, oha |
| `video` | The 4K clip: unpaced throughput, and paced viewers (progressive MP4 by Range, HLS segments) with stalls, startup time and memory per stream, over HTTP/1.1, TLS, h2 and HTTP/3 | wrk, h2load, benchctl's player |

### The $12 server challenge

From [arjaythedev/twelve-dollar-server-challenge](https://github.com/arjaythedev/twelve-dollar-server-challenge)
(MIT; the spec, golden tests, load script and seed generator are vendored in
`twelve/`). One change: the database is Postgres in its own container
(`postgres/`), not SQLite in-process. The schema is ported as is (timestamps
stay TEXT in wire format, so every server sends identical bytes), each
server runs exactly the statements in `SPEC.md`, and each run starts from a
fresh copy of the seed database (`CREATE DATABASE run TEMPLATE seed`).

The traffic is load.js's: each virtual user holds one keep-alive connection,
reads the feed, thinks 3-7 s, opens a post, thinks 3-8 s, likes it (15%),
writes a post (2%) and idles 5-15 s. k6 needs megabytes per virtual user,
and the search goes to tens of thousands of them, so `tools/internal/twelve`
replays the script in goroutines (users spread over 127.0.0.1-8 so they do
not run out of ports). The quick profile adds users in steps (2 500, 5 000,
10 000, ... 60 000; 20 s ramp, 40 s window) after a 1 000-user warm-up and
stops at the first window that misses p95 < 500 ms, p99 < 1 s or < 1%
errors; the score is the last window that passed. The full profile uses
the challenge's 5-minute holds.

### Deviations worth knowing

- **Anole's Postgres client** (`servers/anole/src/pg.zig`) is bench-local:
  Anole has none yet. It is a small async client on Anole's sockets with a
  pool per executor and prepared statements, as pgx, sqlx and asyncpg do.
- **FastAPI's HTTP/3 with more than one worker** runs one Hypercorn per
  worker on its own `SO_REUSEPORT` sockets (`servers/fastapi/h3_workers.py`):
  Hypercorn's `--workers` shares one UDP socket between processes, which
  breaks QUIC connections.
- **nginx's `/plaintext` and `/json`** are fixed strings; only its static
  and video numbers are like for like. It is there as the ceiling.
- **Per-process state.** Under Node's cluster and uvicorn's workers, the
  ticker, the trading position and the retained heap are per process, as
  they would be in production; the WebSocket and GC scenarios run on the
  1-CPU tier, where there is one process.
