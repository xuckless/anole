# #85 screen: WebSocket relay read path over TLS (video-call relay)

Anole only. The video-call app is a pure relay (`MEDIA_DEFLATE=off`), on 1 CPU and 2 GB. It's a screen: one run per cell, and round 1 is single-run data. [NOTES.md](NOTES.md) has the method, the protocol changes and when each took effect.

| side | commit | what it is |
|---|---|---|
| A | 32417f9 | s1/integration before #85 |
| B | 90610de | #85: TLS returns every whole buffered record, and the reader window widens while busy |
| C | 4477eaf | B with a 32 KiB + 512 read block |
| D | 56a16b6 | A + only the TLS batching commit |
| E | 73f7e60 | B + a per-turn budget (yield after 32 units) |
| F | 6d67d79 | B, but relays to other sockets leave at once |

## Ramps (round 1, single runs): users at good quality

Good quality means at least 99% of video shown, at least 99% of audio on time, and video p95 at most 200 ms (as `videocall/report.py` counts it).

| | A | B | C |
|---|---|---|---|
| epoll | **860** | 790 (−8.1%) | 790 (−8.1%) |
| io_uring | **830** | 810 (−2.4%) | 780 (−6.0%) |

How each epoll ramp ended:
- **A** collapsed at 940 users: under 10% of video shown, for everyone at once.
- **B and C** never fell under 10%. They ran to the 3000-user cap with about a third of the calls served, latency reaching minutes, and RSS over 1.7 GB.

From the io_uring ramps on, a 40% cutoff ended each ramp.

## Fairness holds (epoll, 950 users past every knee, held 60 s, one run each)

Each receiver's video received is given as a share of the 30 fps its peer sent. "Served" means at least 90% of frames shown on time; "starved" means under 10%. Syscalls were counted for 20 s in the 30 s settle at the same load, never in the hold.

| side | served | starved | recv min / p10 / med / max | worst latency med / max ms | audio p50 / p99 ms | µs CPU/msg | RSS MB | reads / inbound msg | writes / relayed msg |
|---|---|---|---|---|---|---|---|---|---|
| A | 0% | 100% | 0.91 / 0.95 / 0.98 / 1.04 | 6909 / 10364 | 7474 / 15253 | 11.26 | 606 | 0.37 | 1.01 |
| B | 29% | 63% | 0.67 / 0.90 / 1.00 / 1.25 | 11191 / 26971 | 6270 / 34269 | 10.90 | 531 | 1.22 | 0.86 |
| D | 0% | 100% | 0.91 / 0.94 / 0.97 / 1.03 | 7156 / 9904 | 7684 / 16629 | 11.49 | 614 | 0.37 | 1.01 |
| E | 32% | 57% | 0.75 / 0.89 / 1.00 / 1.18 | 10237 / 24095 | 4840 / 29474 | 11.02 | 537 | 1.17 | 0.81 |
| F | 0% | 100% | 0.90 / 0.93 / 0.96 / 1.06 | 8243 / 11668 | 10395 / 20096 | 11.67 | 620 | 0.39 | 1.01 |

- **A, D and F fail evenly.** Every receiver gets almost all its frames, all of them seconds late.
- **B and E split.** About a third of the calls are served, and the rest starve for tens of seconds.
- **Where the split comes from:**
  - The TLS batching alone (D) changes nothing.
  - The turn budget (E) doesn't remove the split.
  - Sending relays at once (F) removes it and brings back A's even collapse.
  - So the split comes from relays held in the sender's batch.
- **Per-message cost:** B and E are about 3% cheaper per message, with less RSS.

## Profiles (epoll, 950 users held, perf record -g 15 s, one run each)

| | samples | memcpy/memmove self | top self |
|---|---|---|---|
| A | 14,981 | 11.9% | memcpyFast 10.9%, nft_do_chain 5.2%, _copy_to_iter 4.9%, fastMemset 3.4%, aes_gcm_enc 3.1% |
| B | 14,986 | 11.0% | memcpyFast 10.4%, nft_do_chain 5.6%, _copy_to_iter 4.2%, fastMemset 3.4%, aes_gcm_enc 3.2% |

Flame graphs: [A](prof-epoll/videocall/a-ws/flame.svg), [B](prof-epoll/videocall/b-ws/flame.svg); the folded stacks are beside them. The two profiles hardly differ, so the change is in scheduling, not in the cost per message. `nft_do_chain` is the host's firewall on loopback, the same for every side.

## Not measured

The io_uring fairness holds, the confirmation ramps, rounds 2-3 and the fixed 600-user holds were all dropped when the run became a screen and then stopped (NOTES.md). The time from an audio packet's arrival to its relay write would need instrumentation inside Anole; the client-side audio latency above stands in for it.
