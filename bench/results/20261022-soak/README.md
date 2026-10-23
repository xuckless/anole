# Soak and leak test, examples/full at main (2026-10-22)

The build is examples/full from main 2ad0967, which has the same source as
v0.1.3. It runs on 1 CPU / 2 GB. Method and commands to rerun are in
[bench/soak/README.md](../../soak/README.md).

## ReleaseSafe: 2 × 10 min at half capacity

- **Load:** ~10,450 req/s across six streams; CPU charged 0.49 / 0.48;
  12.5 M requests.
- **Errors:** one per round, both on HTTP/3: "Remote is closing the
  connection", a request racing the server's connection close.
- **Latency:** p99 under 1.5 ms on every stream.

| | RSS |
|---|---|
| idle at start | 10.1 MB |
| round 1 | 17.5 → 19.1 MB max |
| idle after round 1 | 14.5 MB |
| round 2 | 18.4 → 20.3 MB max |
| idle after round 2 | 15.7 MB |

- **Trend.** The fitted slope within each round, after its first minute, is
  +72–80 KB/min (≈ +4 MB/h), and anon is +3–3.5 MB/h. Idle RSS rose 1.2 MB
  from one round to the next.
- **Shape.** The samples show plateaus with occasional steps rather than a
  steady climb. 20 minutes can't tell allocator high-water steps from a slow
  leak; a 1–2 h soak at the same rates would.
- **Leaks.** SIGTERM gave exit 0, "server stopped cleanly", and 0
  SafeAllocator leak lines.

## Debug: 5 min at half of Debug's capacity

- **Load:** ~2,780 req/s; CPU 0.58; 835 k requests; 0 errors.
- **RSS:** 24.5 MB idle, then 36.7–38.7 MB under load, then 33.9 MB idle
  after. The slope within the run is +0.3 MB/h.
- **Leaks.** SIGTERM gave exit 0, "server stopped cleanly", and **0 leaks**
  from the SafeAllocator.
- **Positive control.** A program that leaks 100 bytes on purpose, built with
  the same Zig 0.17.0, prints `error(SafeAllocator): leaked …` at exit in
  both Debug and ReleaseSafe. So the report is on, and a leak would have
  shown.
