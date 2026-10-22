# Postgres session reset A/B: #76 pg-reset-auto vs v0.1.1

Release 0.1.1 resets the session on every pooled Postgres connection by
default (`reset_session = true`), and that cost 21% on HttpArena's async-db
(../20261022-release-0.1.1-ab). xuckless/anole#76 (5098bb5) makes
`reset_session` an enum and defaults it to `.auto`, which resets only a
connection whose session state has changed.

Contenders, all the HttpArena entry with the same source (entry/src) and
Dockerfile:
- **v0.1.1, reset on (default)**: 42bbce7, as released. Variant anole-pr.
- **v0.1.1, ANOLE_PG_RESET=0**: the same build, with
  `ENV ANOLE_PG_RESET=0` in the Dockerfile, which sets
  `reset_session = false`. Variant anole-pn.
- **#76**: 5098bb5, with the default (`.auto`). Variant anole-pa.

The entry's main.zig reads the pool options' type by reflection, so one
source works for both versions (the bool on v0.1.1, the enum on #76). It
appends `sslmode=disable`, because 0.1.1 defaults to verify-full for
non-loopback hosts. The two build.zig.zon files pin the commits.

Profiles:
- **async-db**: GET /async-db, pooled reads, 1024 connections, gcannon. Its p99
  is gcannon's.
- **production-stack**: the gateway stack (edge proxy, cache, auth service,
  server), 256 and 1024 connections, h2load. The reads go mostly through the
  cache. The writes are POST /api/items/{id} → `UPDATE`. This is the only
  HttpArena profile that writes to the database, and it covers UPDATE, not
  INSERT. Its latency is h2load's mean, since h2load reports no percentiles.

Protocol:
- `SKIP_TUNE=true LOADGEN_DOCKER=true scripts/benchmark-local.sh` (HttpArena,
  prune-free copy), with cpusets for 28 CPUs. Each invocation is 3 runs.
- 3 rounds, with the order rotating: pr→pn→pa, pa→pr→pn, pn→pa→pr. 70 s idle
  before every invocation (ab-pg.sh).
- 2026-10-22 06:16–06:55.
- Before the runs, all three variants passed HttpArena's validate.sh for both
  profiles (18/18 each).

The value is the median over the 3 rounds of each invocation's median of 3
runs. The full tables, including the per-round values and the reads/writes
split, are in ab-pg-summary.md, and the raw output is in logs/.

| profile | metric | reset on (default) | reset off | #76 (.auto) |
|---|---|---|---|---|
| async-db 1024c | req/s | 98,940 | 123,340 (+24.7%) | **123,540 (+24.9%)** |
| async-db 1024c | p99 | 62.6 ms | 59.7 ms | 62.7 ms |
| production-stack 256c | total req/s | 131,607 | 133,310 (+1.3%) | **133,182 (+1.2%)** |
| production-stack 256c | writes req/s, mean | 5,009, 50.8 ms | 5,164, 49.3 ms | 5,255, 48.4 ms |
| production-stack 1024c | total req/s | 115,015 | 115,318 (+0.3%) | **114,886 (−0.1%)** |
| production-stack 1024c | writes req/s, mean | 4,999, 200.3 ms | 4,884, 204.5 ms | 4,898, 204.7 ms |

**Async-db.** #76 matches turning the reset off (123.5k vs 123.3k req/s), and both are 25% above the
v0.1.1 default. Every round agrees: #76's rounds are 123.2/123.5/123.9k and
the default's are 99.9/96.8/98.9k. The p99s are within the spread across rounds
(58 to 79 ms).

**Production-stack.** All three are within about 1% on total throughput, and
the writes stay within ±5% of each other at both connection counts. The
reset's cost is invisible here, because the throughput is the cached reads
through the gateway, and the UPDATE rate (about 5k/s) is bound by the stack,
not by the pool.

**Noise.** gcannon reports 60 to 150 read errors per async-db run on every
variant. The release A/B shows the same count, and it comes from closing
connections at the end of each run. production-stack had no failed requests
and no non-2xx responses. As in every async-db run on this machine, the
third run of each invocation is about 35% lower (turbo budget), which is why
the median of 3 is used.
