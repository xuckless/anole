# S1.5 retrofit step 2, fix round 1: raw TCP (`anole.net`), A/B

This round follows [20261029-net-retrofit](../20261029-net-retrofit/README.md) and uses the same method: `bench/repro/net-ab.sh`, the unchanged bench app, one executor on 1 CPU, a fresh server rested 70 s before every run, A/B alternating, medians of 5. Each run now also counts page faults and `brk` calls per message.

| side | commit | what it is |
|---|---|---|
| A | 20a0895 | main (`20a089509bef037d7bf7e5b2634af5a5cd96de75`) |
| B | 35068f3 | s15/net (`35068f3c71662fff113a408f4e12d546c302e771`): b2f1fbb plus a per-connection spare send chunk (standard chunks are 16 KiB including the header), plus fixes from the code review |

**Order (the lead's):** the epoll TCP cells first, then io_uring TCP, then UDP. `STOP_ON_FAIL=1` ends the run at the first cell that fails the gate (messages/s and p99 within 2% of A, or better). It stopped at the third cell.

## Results (epoll TCP)

| size | conns | A msg/s | B msg/s | Δ msg/s | A p99 ms | B p99 ms | Δ p99 | A µs/msg | B µs/msg | A ins/msg | B ins/msg | A faults/msg | B faults/msg | A brk/msg | B brk/msg | gate |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 64 | 256 | 228,068 | 236,655 | +3.8% | 1.278 | 1.212 | −5.1% | 2.48 | 2.35 | 2528 | 2045 | 0.247 | 0.000 | 0.034 | 0.000 | pass |
| 64 | 4096 | 152,763 | 155,606 | +1.9% | 29.360 | 28.312 | −3.6% | 4.34 | 4.22 | 2496 | 2084 | 0.010 | 0.000 | 0.001 | 0.000 | pass |
| 16384 | 256 | 132,334 | 98,888 | −25.3% | 2.359 | 3.080 | +30.6% | 5.34 | 7.83 | 5535 | 5602 | 0.361 | 3.732 | 0.018 | 0.116 | **fail** |

**64 B messages:** the spare chunk removes the heap churn completely. B takes no page faults and no `brk` calls, and runs 17–19% fewer user instructions per message than main.

**16 KiB messages:** the churn is back, and worse.
- The standard chunk holds `16 KiB − header − framing`, so a 16,384-byte message never fits it.
- Every such send allocates an exact-size chunk (`OutChunk.fresh(gpa, total)`).
- That chunk isn't standard, so it's freed instead of being kept as the spare.
- Per message, B takes 3.73 page faults and 0.116 `brk` calls, against A's 0.36 and 0.018.

## Profile (epoll TCP 16 KiB × 256)

[`prof-epoll-tcp-16384-c256/`](prof-epoll-tcp-16384-c256/) was made with `bench/repro/net-prof.sh`: one rested run per side, B first, perf stat for 15 s, then `perf record -g` for 15 s. Flame graphs: [A](prof-epoll-tcp-16384-c256/a/flame.svg), [B](prof-epoll-tcp-16384-c256/b/flame.svg).

| per message | A | B |
|---|---|---|
| msg/s in this pair | 124,552 | 101,949 |
| page faults | 0.86 | 3.79 |
| `brk` | 0.030 | 0.117 |
| cycles:u | 7,985 | 8,848 |
| instructions:u | 5,725 | 5,669 |
| locked loads (user + kernel) | 101 | 148 |
| all loads (user + kernel) | 11,034 | 14,739 |

- In the flame graphs, 8.0% of A's samples sit under page faults and 1.6% under `brk`; B's are 21.6% and 3.8%.
- The extra locked loads are mostly the kernel's fault handling.
- The lead's next round sizes the standard chunk as 16 KiB of payload plus the header, keeps the spare by capacity, and tests messages from 16 B to 32 KiB. That commit gets the full matrix: 16 KiB cells first, then 64 B, then UDP, as the user asked.

## Files

- `run.log`: every run, with order and times, and the stop.
- `epoll/<proto>-<size>-c<conns>/<side>-r<n>/` holds, per run: `load.json`, `perf-stat.csv` (instructions, cycles, task-clock, page faults, `brk`), `cpu-usec`, `backend`, `server.log`.
- Images: `anole-bench/anole:net-a` (main) and `:net-b2` (35068f3). Both are the bench app overlaid on a `git archive` of the commit, built ReleaseFast with `-Dcpu=baseline`.
