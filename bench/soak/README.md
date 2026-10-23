# Soak and leak test

Runs examples/full, as it ships, under mixed traffic. Two questions:

- Does memory grow while the server works?
- Does the allocator report leaks when it stops?

`run.sh` does it in three steps:

1. **Capacity probe.** A fresh server, after a rest of at least 70 s, gets
   every stream of `load.sh` flat out for 20 s.
2. **Soak.** Another fresh server gets each stream at half the rate it reached
   in the probe, for `PHASES` rounds of `PHASE` with 2 min idle between. RSS,
   cgroup memory (current, anon) and CPU are sampled every 5 s.
3. **SIGTERM.** At the end the server gets SIGTERM. Zig's
   `std.process.Init.gpa` is the SafeAllocator in Debug and ReleaseSafe. When
   `main` returns it logs `error(SafeAllocator): leaked …` for every
   allocation still live, with its stack trace in Debug, and `analyze.py`
   counts those lines.

The server gets 1 CPU and 2 GB (`SUT_CPUS_1`), and `load.sh` runs on
`LOAD_CPUS`.

Streams (oha 1.16, each its own process):

| stream | traffic |
|---|---|
| `h1ka` | HTTP/1.1 keep-alive, GET `/users/<random>`, 32 connections |
| `h1close` | HTTP/1.1, a new connection per request, GET `/` |
| `tlsclose` | TLS HTTP/1.1, a new connection and handshake per request |
| `h2big` | TLS HTTP/2, 4 connections × 16 streams, GET `/big` gzipped |
| `h2cecho` | h2c POST `/echo` with a 64 KiB body, streamed back |
| `h3` | HTTP/3, GET `/users/<random>` |

## Run it

```sh
# examples/full from the commit under test, built in both modes
git archive <commit> | (mkdir -p /tmp/anole-src && tar -x -C /tmp/anole-src)
for o in ReleaseSafe Debug; do
  docker build -f bench/soak/Dockerfile --build-arg OPTIMIZE=$o -t anole-bench/soak-full:$o /tmp/anole-src
done
bench/soak/run.sh <results-id>                                    # ReleaseSafe, 2 x 10 min
OPT=Debug PHASES=1 PHASE=5m bench/soak/run.sh <results-id>        # Debug, 5 min, leak report
```

Results land in `bench/results/<id>/soak/<OPT>/`:
- `report.md` and `summary.json`;
- `samples.csv` (every 5 s) and `events.csv` (phase marks);
- per-stream oha JSON for each phase, and `rates.txt`;
- `server.log`, the log without the access lines, which ends with the leak
  report.
