# #85 A/B/C, video-call relay over WebSocket (run notes)

> **Screen, not medians (user, relayed by the lead, 2026-10-28 ~23:55).** The
> run was switched from the full medians protocol to a screen. Round 1 (one
> ramp per side and backend) is **single-run data**. Rounds 2-3, the 600-user
> fixed holds and the C profile were dropped. What follows round 1:
> - epoll CPU profiles (flame graph and memcpy share) of A and B at 950 users;
> - fairness holds for A/B/D/E/F on both backends, one run each;
> - a confirmation only for a variant that looks like a win over A: A vs that
>   variant, 2 rested interleaved pairs per backend.
> The fast-start and phase sections below describe what was planned before
> this change. The fast start applies to the fairness holds, the profiles and
> any confirmation ramps.
>
> **Stopped after F's epoll fairness hold (user, relayed by the lead,
> 2026-10-29 ~00:47).** The io_uring fairness holds and the confirmation
> ramps were dropped. The reason: the user decides on the epoll screen (B is
> likely to ship for its overload behaviour; the knee goes to S2). The driver
> was stopped during the first io_uring hold's 70 s rest, before any server
> started. The first A profile run (00:18) is void: vcload's own collapse rule
> ended it before the hold. All holds and profiles were rerun with
> `-collapse 24h`.

Anole only. 1 CPU (cpu 2) / 2 GB, MEDIA_DEFLATE=off (pure relay), epoll and
io_uring. Driver: `bench/repro/ws85.sh`; summaries: `bench/repro/ws85-summary.py`.

- A = 32417f9 (s1/integration before #85)
- B = 90610de (s1/integration tip, #85)
- C = 4477eaf (B with a 32 KiB + 512 read block)

Images: the unchanged `bench/videocall/servers/anole` app, re-pinned with
`ANOLE_REF=<full commit>` (ReleaseSafe, `-Dcpu=baseline`). A short hash makes
the Dockerfile's fetch loop fall back silently to v0.1.3, so each binary was
checked for 0.3+ strings. All three pass `vcload -smoke -transport ws -deflate=false`;
the backends were checked from inside the container (eventpoll / io_uring fd).

Protocol: every measured invocation rests 70 s first; the rounds rotate the
order ABC, BCA, CAB. Phases:
1. Ramps: 10 users every 5 s. Good users are counted as `videocall/report.py`
   counts them (≥ 99% video shown, ≥ 99% audio on time, video p95 ≤ 200 ms).
2. Fixed load: 600 users (20 every 5 s), held 90 s and measured as one step.
3. Profile: epoll, one per side, inside a 600-user hold: perf stat on the
   syscalls for 20 s, then perf record -g for 15 s.

## Protocol change: ramp cutoff at 40% displayed video

At first a ramp ended only on vcload's own rule: under 10% of video frames
shown for 30 s, a crash, or the 3000-user cap. B and C never fall under 10%
past their knee (about a third of the calls keep being served while the rest
queue without bound), so their ramps ran to the 3000-user cap.

From **round 1, io_uring, side a** (the 4th ramp, about 23:33 on 2026-10-28)
onward, every ramp also ends once displayed video is under 40% for 2
consecutive steps (`vcload -stop-below 0.4`, built into the run's vcload
binary as its default). The rule is the same for every side and both backends.
The lead relayed this change on the user's behalf.

The good-user count and the knee lie well before that line, so the main
figure doesn't change; only the tail past it is dropped. The three epoll ramps
of round 1 ran under the old rule:
- A collapsed at 940 users.
- B ran to 3000 users (33% shown, RSS 1.76 GB).
- C ran to its own end under the old rule.

The round-1 B and C ramps stay as the record of the unbounded tail. For fixed
loads and profiles the rule never triggers: video is ~100% at 600 users.

## Protocol change: fast start near the knees (from round 2)

From **round 2** onward (both backends, every side), a ramp no longer starts
from 0:
1. Users join 50 every 5 s up to 700, below every knee seen in round 1 (A 860,
   B 790, C 790).
2. The users settle for 30 s (that settle is one step row).
3. The normal 10 users every 5 s follow, until the 40% cutoff. A side that
   passes 1000 just keeps climbing.

There's no ramp-down, because the recovery point after overload (hysteresis)
wouldn't compare with an up-ramp. The reason is time: a round-2/3 ramp takes
about 4.5 min instead of about 8.

In vcload it's `-fast-to 700 -fast-batch 50 -settle 30s`, built into the run's
binary as defaults. It's active only when the target is at most `-max-users`,
so the 600-user fixed holds and the profiles keep their 20-every-5 s join. The
binary was swapped in after the last round-1 io_uring ramp. The lead relayed
this change on the user's behalf, like the cutoff.

**Check:** round 1 ran from 0, so its knees are compared per side and backend
with rounds 2-3. Any difference larger than the run spread is flagged in the
results.

Fairness holds and the A/D/E ramps-only set use the same fast start: straight
to 950 for the holds (50 every 5 s), settle 30 s, then hold 60 s.

## Extra runs (after the protocol)

- **Fairness holds:** 950 users held 60 s, A, B and D (56a16b6, A plus only the
  TLS batching; E if pushed in time), epoll and io_uring. These use
  `vcload-fair`, which has the per-user counters (`per_user.jsonl`) and no cutoff.
- **Build note:** the vcload-fair and cutoff builds ran on cpu 19 (the aux set)
  during the round-1 C ramp; no measured core was used.
