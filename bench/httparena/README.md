# HttpArena entry

`anole/` is Anole's entry for [HttpArena](https://github.com/MDA2AV/HttpArena)
(`frameworks/anole/` there), kept here until it is submitted after the 0.1.0
tag. It is developed on the `anole-entry` branch of a local HttpArena clone
(MDA2AV/HttpArena 3717e256e, 2026-10-20).

- Standard mode: documented APIs and default settings only. Pinned to the
  `v0.1.0` tag (c6d41b9).
- One process with four listeners (`listeners`, docs/server.md): 8080
  HTTP/1.1 + h2c, 8081 TLS HTTP/1.1 only, 8082 h2c only, 8443 TLS h2 +
  HTTP/1.1 with HTTP/3 on UDP 8443. HTTP/3's UDP sockets bind `::` (both
  families), because the harness's QUIC client tries ::1 for `localhost` and
  does not fall back.
- `/ws` uses WebSocket callbacks (`wsCallbacks`).
- Gateway profiles, one compose file each (exactly the services each allows;
  the chosen CPU split and its measurements are in each file's header):
  - `compose.gateway.yml` (gateway-64): stock nginx (`proxy/`) terminating
    TLS + HTTP/2, serving `/static`, in front of Anole on 127.0.0.1:8085
    (`ANOLE_ROLE=gateway`) over pooled HTTP/1.1.
  - `compose.gateway-h3.yml` (gateway-h3): the same with nginx's HTTP/3
    (`proxy-h3/`); nginx beat Caddy about 3x on the rig, and HAProxy cannot
    serve files from disk.
  - `compose.production-stack.yml`: nginx with `auth_request` to the shared
    authsvc (`proxy-production/`), Redis, authsvc, Anole. `/api/items/{id}`
    and `/api/me` are cache-aside: Anole's per-executor result cache on the
    Redis `GET` (L1), Redis (L2), Postgres; writes drop both tiers.
  - The edges listen on the loopback addresses, not the wildcard: during
    validation the entry's own container is up on the host network with
    wildcard 8080 and 8443, and a loopback address wins the lookup. They
    also answer the harness's readiness probe (`localhost:8080/baseline11`).
- `scripts/validate.sh anole`: 152 passed, 0 failed (2026-10-22), with the
  cpusets overridden for a 28-CPU box (`PROXY_CPUSET`, `SERVER_CPUSET`,
  `EDGE_CPUSET`, `CACHE_CPUSET`, `AUTHSVC_CPUSET`).

To run it locally: copy `anole/` to `frameworks/anole/` in an HttpArena
clone, then `scripts/validate.sh anole`. On a box with fewer than 96 CPUs set
the cpuset variables above. Ports 5432 and 9090 must be free (the harness's
Postgres and the production stack's authsvc). Its `scripts/benchmark.sh`
prunes every unused Docker volume and dangling image on the host at start and
exit, and with tuning on it sets the CPU governor, sysctls and restarts
Docker: run a copy without the `docker volume prune`/`docker image prune`
lines, with `SKIP_TUNE=true LOADGEN_DOCKER=true`.

The CPU-split sweep's logs are in `bench/results/20261022-gateway-split-sweep/`.
