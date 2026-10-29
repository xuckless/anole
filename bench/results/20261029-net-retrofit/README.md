# S1.5 retrofit step 2: raw TCP/UDP drivers (`anole.net`), A/B

Anole only. The bench app is unchanged on both sides (`bench/servers/anole`, `NET_TCP_PORT`/`NET_UDP_PORT`): `TcpEcho` answers with `conn.send` from the handler, and `UdpEcho` answers with `d.reply`. One executor on 1 CPU (cpu 2), 2 GB.

| side | commit | what it is |
|---|---|---|
| A | 20a0895 | main (`20a089509bef037d7bf7e5b2634af5a5cd96de75`) |
| B | b2f1fbb | s15/net (`b2f1fbba172e80bb4413ed9d8033ef6bc9c90862`): TCP sends from the owner executor go through `TcpConn.queueLocal` / `reserve` / `claimDriver`, with atomic flags and a CAS reservation instead of a spin lock around the out queue |

Gate: messages/s and p99 within 2% of A, or better.

## Method

- **Driver:** `bench/repro/net-ab.sh`, summaries by `bench/repro/net-ab-summary.py`.
- **Server:** every run starts a fresh server and rests 70 s before the load.
- **Load:** 3 s warm-up, then 15 s counted.
- **Repeats:** 5 runs per side and cell, alternating A B, B A, … Medians are shown.
- **Load generators:**
  - `bench/tools/cmd/tcpload` (new) keeps one message outstanding per connection.
  - `udpload -window 1` does the same per client socket. Its round trip is new.
- **CPU and instructions:**
  - µs/msg is the server cgroup's CPU over the counted window, divided by the messages echoed.
  - ins/msg is `perf stat` `instructions:u` over the same window, divided the same way.
  - This is not the D19 fixed-count method (research/s15/instructions-column.md).
- **UDP's large size is 2048 B, not 16 KiB.** `anole.net.udp` defaults to `max_datagram = 2048` on both sides, and it drops larger datagrams as truncated. The app stays unchanged; the lead accepted this.
- **Kernel loss at 4,096 UDP peers:**
  - 4,096 outstanding datagrams overflow the default 212 KB receive buffer.
  - Both sides lose about 294k–304k datagrams per run.
  - A peer whose datagram is lost waits out udpload's 200 ms read timeout.
  - So those rates come from the peers that keep going; the effect is equal on A and B.
  - At 256 peers the loss is about 6k (64 B) or 16k (2048 B) per run, also equal.
- **io_uring was not run.** At the lead's request, the run stopped after the epoll cells: the TCP result was conclusive. The fix round's commit gets the io_uring half (run.log).

## Results (epoll)

| proto | size | conns | A msg/s | B msg/s | Δ msg/s | A p99 ms | B p99 ms | Δ p99 | A µs/msg | B µs/msg | A ins/msg | B ins/msg | gate |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| tcp | 64 | 256 | 234,632 | 197,786 | −15.7% | 1.245 | 1.442 | +15.8% | 2.39 | 3.15 | 2480 | 2517 | **fail** |
| tcp | 64 | 4096 | 164,097 | 138,135 | −15.8% | 26.739 | 32.506 | +21.6% | 3.92 | 5.10 | 2491 | 2570 | **fail** |
| tcp | 16384 | 256 | 134,886 | 102,218 | −24.2% | 2.294 | 2.949 | +28.6% | 5.18 | 7.50 | 5527 | 5597 | **fail** |
| tcp | 16384 | 4096 | 66,548 | 55,550 | −16.5% | 65.012 | 77.595 | +19.4% | 10.96 | 13.93 | 5588 | 5690 | **fail** |
| udp | 64 | 256 | 315,428 | 315,956 | +0.2% | 0.606 | 0.606 | +0.0% | 1.56 | 1.55 | 938 | 939 | pass |
| udp | 64 | 4096 | 304,982 | 309,590 | +1.5% | 0.705 | 0.688 | −2.3% | 1.64 | 1.59 | 941 | 943 | pass |
| udp | 2048 | 256 | 287,063 | 286,628 | −0.2% | 0.168 | 0.168 | +0.0% | 1.83 | 1.83 | 1312 | 1314 | pass |
| udp | 2048 | 4096 | 284,327 | 282,579 | −0.6% | 0.213 | 0.213 | +0.0% | 1.86 | 1.87 | 1317 | 1318 | pass |

- Run spreads are small: every run of each side is in run.log, and the sides don't overlap in any TCP cell.
- TCP fails in every cell by 16–24%. UDP, whose path this step didn't change, is neutral.

## Why B loses on TCP (profiles, epoll TCP 64 B × 256)

`bench/repro/net-prof.sh` ran one rested run per side.

[`prof-epoll-tcp-64-c256/`](prof-epoll-tcp-64-c256/) has one load per side: perf stat for 15 s, then `perf record -g` (frame pointers) for 15 s. Flame graphs: [A](prof-epoll-tcp-64-c256/a/flame.svg), [B](prof-epoll-tcp-64-c256/b/flame.svg).

| per message | A | B |
|---|---|---|
| msg/s in this pair | 224,214 | 206,511 |
| cycles:u | 3,037 | 3,377 |
| instructions:u | 2,547 | 2,556 |
| locked loads (user + kernel) | 79.5 | 90.4 |
| all loads (user + kernel) | 8,424 | 9,501 |
| L1d load misses (user + kernel) | 372 | 383 |

Flame graph shares (A → B):

| | A | B |
|---|---|---|
| page faults | 1.9% | 10.5% |
| `brk` | 1.0% | 2.9% |
| `nft_do_chain` (the host's loopback firewall) | 14.1% | 12.0% |
| `recvfrom` | 7.2% | 6.8% |

[`prof-epoll-tcp-64-c256-syscalls/`](prof-epoll-tcp-64-c256-syscalls/) has syscall and fault counts over 15 s of load:

| per message | A | B |
|---|---|---|
| page faults | 0.317 | 0.968 |
| `brk` | 0.042 | 0.111 |
| `sendmsg` | 0.975 | 0.972 |
| `recvfrom` | 1.950 | 1.943 |
| `epoll_pwait2` | 0.016 | 0.015 |
| context switches, futex, mmap, munmap, madvise | 0 | 0 |

**Reading:**
- B does the same work as A: the instructions and the I/O syscalls match.
- B's extra locked loads (+11 per message) and user cycles (+340) are small. User space is about 3k of the roughly 20k cycles a message costs.
- The loss is glibc's heap trimming and regrowing (`brk`), with fresh pages faulted in: 3× the faults and 2.6× the `brk` calls per message.
- Every message allocates a fresh out chunk on both sides, because the previous one was freed after its write:
  - A allocates exactly 16 KiB.
  - B allocates `header + 16 KiB` in one aligned block (`OutChunk.fresh`) and frees it in `OutChunk.destroy`.
- glibc has no frame pointers, so the profile can't name the exact caller of the faults.
- The fix round adds a per-connection spare chunk on the owner path, so a steady echo allocates nothing. It gets the confirmation matrix.

Side note, the same on A and B: about 2 `recvfrom` per message (one with the data, then presumably EAGAIN before the task parks).

## Files

- `run.log`: every run, with order and times; the pause for the profiles; the stop.
- `epoll/<proto>-<size>-c<conns>/<side>-r<n>/` holds, per run:
  - `load.json` (tcpload/udpload output);
  - `perf-stat.csv`;
  - `cpu-usec`;
  - `backend`, empty in these runs: the check read `/proc/<pid>/fd` of a root container, which isn't readable from the host user. Epoll is the default, and the driver now checks through `docker exec`;
  - `server.log`.
- `prof-*/`: the profiles above. Each side has:
  - `perf-stat.csv`;
  - `perf-script.txt.gz`, `stacks.folded`, `flame.svg`, `flame.json`;
  - `report-sym.txt`.
- Images: `anole-bench/anole:net-a` and `:net-b`, built by the scratch `build-anole.sh` (`git archive` of each commit, overlaid with this branch's `bench/servers/anole`, ReleaseFast, `-Dcpu=baseline`).
