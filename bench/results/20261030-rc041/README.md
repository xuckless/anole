# v0.4.1 release check against v0.3.1

These are the two cells that moved by more than 3% in the 0.4.0 round ([20261023-v040](../20261023-v040/)), rerun against the 0.4.1 release candidate. The candidate became v0.4.1: tag v0.4.1 (c36cca0) differs from the measured commit 4465bb3 only in `.github/workflows/ci.yml`, so the numbers are v0.4.1's. The run directories and logs still call it `0.4.1-rc`.

| side | commit |
|---|---|
| v0.3.1 | tag v0.3.1, 1ddc2f7 |
| 0.4.1-rc (= v0.4.1's code) | 4465bb3 (v0.4.1 = c36cca0, CI config only on top) |

**Method:** `bench/repro/gate.sh`, with the same app and load settings as the 0.4.0 round.
- Both images were rebuilt with this branch's bench app (`git archive` of each commit, ReleaseFast, `-Dcpu=baseline`): `anole-bench/anole:v031-now` and `:rc041`.
- Each side gets 5 runs. Every run starts a fresh server and rests 70 s before its 30 s load. The side order alternates each round; run.log has the order and times.
- Gate: more than 3% worse on the median is a regression.

| cell | side | req/s | vs v0.3.1 | p50 ms | p99 ms | µs CPU/req | mem MB | runs |
|---|---|---|---|---|---|---|---|---|
| 1 CPU, io_uring, json (wrk c256) | v0.3.1 | 235,780 | 1.000 | 1.08 | 1.21 | 2.382 | 9 | 237.1k / 234.0k / 235.8k / 231.8k / 237.7k |
| | 0.4.1-rc | 234,672 | 0.995 | 1.09 | 1.22 | 2.349 | 9 | 231.8k / 240.3k / 232.7k / 234.7k / 238.7k |
| 4 CPUs, io_uring, h2c m64 (h2load c256) | v0.3.1 | 1,758,236 | 1.000 | 8.23 | 21.31 | 2.410 | 110 | 1757.1k / 1758.2k / 1679.5k / 1779.0k / 1779.3k |
| | 0.4.1-rc | 1,806,776 | 1.028 | 7.84 | 20.53 | 2.333 | 107 | 1722.2k / 1754.4k / 1806.8k / 1814.9k / 1833.7k |

**No regression.**
- **json, 1 CPU:** −0.5% req/s. The runs overlap fully, and CPU per request is 1.4% lower. The 0.4.0 round's −4.1% (2 runs, noisy) doesn't reproduce.
- **h2c m64, 4 CPUs:** +2.8% req/s, p99 −3.7%, CPU per request −3.2%. The 0.4.0 round's −3.1% doesn't reproduce.
- **Absolute p99 differs between rounds:** this round's h2c m64 p99 is about 21 ms on both sides, against 13.8 and 18.2 ms in the 0.4.0 round. The comparison holds within a round, not across rounds.

**False start (discarded):** the first attempt set `CASES=""`, which gate.sh treats as unset. It ran one epoll plaintext run and started its Postgres container before I stopped it. Both were removed, and the measured runs began at 02:35.
