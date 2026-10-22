# HTTP/3 A/B: main (5ff99a4) vs quic-interop-fixes (#75, e8fdf17)

#75 changes Linux per-core HTTP/3 steering: it places a client's first
long-header packets by connection ID. This checks that the change costs no
throughput.

Setup:
- bench/suite.sh, raw scenario, h3 mode, at 1 and 4 CPU, on io_uring (`SUT_URING=1`).
- Load: h2load `-t 4 -c 64 -m 10 -D 15 --alpn-list=h3`, on /plaintext and /json.
- Images built from each commit's tree with bench/servers/anole/Dockerfile.

Protocol:
- 3 rounds, with the order alternating: main→#75, #75→main, main→#75.
- 70 s idle before every invocation, with one server per invocation (ab.sh).
- 2026-10-22 05:52–06:06.

Medians of the 3 rounds. The latency is h2load's mean, since it reports no
percentiles. Memory is cgroup memory.current at the end.

| tier | endpoint | main req/s (per round) | #75 req/s (per round) | Δ | mean lat main / #75 | mem main / #75 |
|---|---|---|---|---|---|---|
| 1 CPU | /plaintext | **396,226** (396,226 / 397,859 / 387,781) | **398,129** (397,904 / 398,325 / 398,129) | +0.5% | 1.62 / 1.61 ms | 58.1 / 57.1 MB |
| 1 CPU | /json | **380,848** (380,848 / 384,793 / 375,953) | **381,989** (384,835 / 381,989 / 381,693) | +0.3% | 1.68 / 1.68 ms | 76.5 / 75.5 MB |
| 4 CPU | /plaintext | **1,413,823** (1,420,721 / 1,413,823 / 1,409,787) | **1,426,824** (1,406,521 / 1,434,313 / 1,426,824) | +0.9% | 0.432 / 0.424 ms | 43.7 / 43.9 MB |
| 4 CPU | /json | **1,311,813** (1,295,410 / 1,311,813 / 1,322,325) | **1,315,442** (1,318,516 / 1,315,442 / 1,266,751) | +0.3% | 0.488 / 0.487 ms | 53.6 / 52.8 MB |

There were no errors in any run.

**Verdict.** Every difference is within the round-to-round spread (up to about 4%), so #75's
steering change is throughput-neutral on HTTP/3 at both tiers.
