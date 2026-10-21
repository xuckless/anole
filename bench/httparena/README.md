# HttpArena entry

`anole/` is Anole's entry for [HttpArena](https://github.com/MDA2AV/HttpArena)
(`frameworks/anole/` there), kept here until it is submitted after the 0.1.0
tag. It is developed on the `anole-entry` branch of a local HttpArena clone
(MDA2AV/HttpArena 3717e256e, 2026-10-20).

- Standard mode: documented APIs and default settings only. The one
  non-default setting, `max_connections = null`, is there because the async
  and WebSocket profiles hold 32,000 and 16,384 connections and the default
  cap is 10,000.
- Two server processes (`entrypoint.sh`): HttpArena wants four ports with
  different protocols (8080 HTTP/1.1 + h2c, 8081 TLS HTTP/1.1 only, 8082
  h2c, 8443 TLS h2 + HTTP/3), and an Anole server has one cleartext and one
  TLS listener.
- Pinned to Anole main 026a09e; `/ws` uses `wsCallbacks` once the pinned
  commit has it (checked at comptime), the `ws.next()` loop until then.
- `scripts/validate.sh anole`: 113 passed, 0 failed (2026-10-21).

To run it locally: copy `anole/` to `frameworks/anole/` in an HttpArena
clone, then `scripts/validate.sh anole`. Its `scripts/benchmark.sh` prunes
every unused Docker volume and dangling image on the host at start and exit,
and with tuning on it sets the CPU governor, sysctls and restarts Docker:
run a copy without the `docker volume prune`/`docker image prune` lines, with
`SKIP_TUNE=true LOADGEN_DOCKER=true`.
