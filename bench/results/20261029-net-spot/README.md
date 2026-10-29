# S1.5 retrofit step 2: spot check of 5966dfc (epoll TCP 16 KiB × 256)

One cell, by the method of [20261029-net-round2](../20261029-net-round2/README.md): `bench/repro/net-ab.sh`, one executor on 1 CPU, a fresh server rested 70 s before every run, A/B alternating, medians of 5.

| side | commit |
|---|---|
| A | main 20a0895 (`20a089509bef037d7bf7e5b2634af5a5cd96de75`) |
| B | s15/net 5966dfc (`5966dfcbbadeee1e9ec66f3b93bda7196834276e`): a624b97 plus the third review's fixes (paused connections, close, the spare chunk for C ABI sends, release waiting for writers), all off the echo path |

| | msg/s | p99 ms | µs/msg | ins:u/msg | faults/msg | brk/msg |
|---|---|---|---|---|---|---|
| A | 135,630 | 2.294 | 5.15 | 5,492 | 0.150 | 0.007 |
| B | 136,114 | 2.228 | 5.13 | 5,116 | 0 | 0 |
| B vs A | +0.4% | −2.9% | | −6.8% | | |

- **Pass:** within 2% of A or better.
- **Run spread:** A 125.8k–138.1k, B 135.6k–139.8k.
  - A's run 3 (125.8k) is the low one. Its intrusion figures are normal, and without it A's median would be about 135.8k, still a pass.
- **No change from a624b97:** B matches round 2's a624b97 figures (135,133 msg/s, 5,112 ins/msg, no page faults), so the fixes since didn't touch the echo path.
- **Other load:** the SUT's core showed none in any run. cpu2 beyond the server was 28–31%, cpu3 was 0%, and 2–3 rsync/ssh processes were present throughout.

Image: `anole-bench/anole:net-b4`.
