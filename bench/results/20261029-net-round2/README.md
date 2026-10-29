# S1.5 retrofit step 2, fix round 2: raw TCP/UDP (`anole.net`), A/B

This round follows [20261029-net-final](../20261029-net-final/README.md) (fix round 1) and [20261029-net-retrofit](../20261029-net-retrofit/README.md) and uses the same method: `bench/repro/net-ab.sh`, the unchanged bench app, one executor on 1 CPU, a fresh server rested 70 s before every run, A/B alternating, medians of 5, page faults and `brk` per message.

| side | commit | what it is |
|---|---|---|
| A | 20a0895 | main (`20a089509bef037d7bf7e5b2634af5a5cd96de75`) |
| B | a624b97 | s15/net (`a624b97a87a58c0f47150f396fcc2f32f9160dc9`): the spare send chunk is kept by capacity, a standard chunk holds 16 KiB of payload plus its header, and the second review's fixes are in |

**Cells (the user's call, via the lead):** the 16 KiB TCP cells that failed in round 1, then one io_uring TCP cell, then one io_uring UDP check.
- Not run: epoll TCP 64 B, which passed in round 1 (+3.8%, +1.9%); the changes since are off the echo path.
- Not run: epoll UDP, which was neutral on b2f1fbb; the changes since only touch refusal and shutdown.
- The matrix was shortened mid-run. The run of io_uring 16 KiB × 4,096 that had just started (no load yet) was discarded; run.log has the times.

## Results

| backend | proto | size | conns | A msg/s | B msg/s | Δ msg/s | A p99 ms | B p99 ms | Δ p99 | A µs/msg | B µs/msg | A ins/msg | B ins/msg | A faults/msg | B faults/msg | A brk/msg | B brk/msg | gate |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| epoll | tcp | 16384 | 256 | 132,209 | 135,133 | +2.2% | 2.425 | 2.294 | −5.4% | 5.30 | 5.12 | 5497 | 5112 | 0.247 | 0.000 | 0.010 | 0.000 | pass |
| epoll | tcp | 16384 | 4096 | 64,989 | 65,438 | +0.7% | 66.060 | 67.109 | +1.6% | 11.24 | 11.17 | 5587 | 5217 | 0.035 | 0.000 | 0.001 | 0.000 | pass |
| io_uring | tcp | 16384 | 256 | 142,437 | 140,978 | −1.0% | 2.425 | 2.425 | +0.0% | 4.77 | 4.82 | 5080 | 4702 | 0.017 | 0.000 | 0.001 | 0.000 | pass |
| io_uring | udp | 64 | 256 | 318,234 | 319,849 | +0.5% | 0.606 | 0.606 | +0.0% | 1.51 | 1.50 | 938 | 941 | 0.000 | 0.000 | 0.000 | 0.000 | pass |

- **Every cell passes the gate.**
- In the TCP cells, B takes no page faults and makes no `brk` calls, and runs about 7% fewer user instructions per message than main.
- With round 1's 64 B cells, every measured TCP cell is now at A or better, within 2%.
- epoll 16 KiB × 4,096: p99 sits one histogram step above A (66.06 → 67.11 ms), inside the gate. The runs overlap (A 64.9k–67.0k, B 65.0k–66.7k).
- io_uring 16 KiB × 256: msg/s is −1.0%, inside the gate, and the runs overlap (A 141.3k–145.7k, B 140.6k–145.1k).
- The UDP kernel loss is about 6k datagrams per run on both sides (A 30,820, B 31,217 over 5 runs). Its cause is in the first round's README.

## Other load on the SUT's core

While this round ran, the lead's builds went to the Mac by rsync/ssh from the box. Each run records, over its counted window (`intrusion` in each run directory):
- cpu2's busy time beyond the server's own cgroup time;
- cpu3's busy share (cpu3 is cpu2's SMT sibling, idle by design);
- the count of rsync/ssh/scp processes.

They held steady in every run:
- cpu2 beyond the server: 28–33% in TCP and 50–52% in UDP. That is mostly the loopback softirqs the server's sends cause, which the cgroup doesn't count.
- cpu3: 0%.

No run shows a blip.

## Files

- `run.log`: every run, with order, times and intrusion figures; the shortening; the UDP pass.
- `<backend>/<proto>-<size>-c<conns>/<side>-r<n>/` holds, per run: `load.json`, `perf-stat.csv`, `cpu-usec`, `intrusion`, `backend`, `server.log`.
- Images: `anole-bench/anole:net-a` (main) and `:net-b3` (a624b97). Both are the bench app overlaid on a `git archive` of the commit, built ReleaseFast with `-Dcpu=baseline`.
