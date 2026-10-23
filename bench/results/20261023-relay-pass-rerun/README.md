# relay-pass 780a42f vs main 7e14ecc, targeted rerun

Anole only, 1 CPU (cpu 2), rested ≥ 70 s before each run, sides interleaved.
A = main 7e14ecc, C = relay-pass 780a42f (57fdfa9 + 5b029c1 ws h1 memory fixes + 780a42f h3 fixes).

## Gates

| Gate | Result | |
|---|---|---|
| h3 within 3% of A | epoll +2.9%; io_uring −3.7% | **epoll pass, io_uring miss** |
| ws MB/user near 0.23, users gain kept | 0.33 MB/user (A 0.26); users +9% | **memory miss** |
| fan-out, echo not below 57fdfa9 / A | echo 1.00×, fan-out 2.41× | pass |

## 1. h3 #78 (h2load h3 c64 m10), medians of 3 (conns-ab/)

| Backend | A req/s | C req/s | C/A | p99 A / C | mem A / C |
|---|---|---|---|---|---|
| epoll | 417,420 | 429,492 | 1.029 | 2.15 / 2.13 ms | 54 / 35 MB |
| io_uring | 377,667 | 363,513 | 0.963 | 5.09 / 5.33 ms | 48 / 33 MB |

Every C io_uring round was 3.2–4.4% behind every A round.
perf stat, epoll, one round a side (profile/h3/): cycles/req 14.2k → 14.9k (+5.4%), instructions/req 33.5k → 34.6k (+3.3%); 57fdfa9 was +8%.

## 2. Video call, pure relay (videocall/, index.html)

| | A ws | C ws | A wt | C wt |
|---|---|---|---|---|
| users at good quality | ~800 | ~870 (+9%) | ~400 | ~430 (+8%) |
| CPU/msg at 400 users | 10.1 µs | 9.4 µs | 22.4 µs | 19.0 µs |
| memory | 129 MB at 500 | 164 MB at 500 | 258 MB at 400 | 125 MB at 400 |
| MB/user | 0.26 | 0.33 | 0.65 | 0.31 |

57fdfa9 was 170 MB at 500 users over ws, so 5b029c1 moved ws memory by ~4%.

## 3. ws suite, 2 rounds a side (ws/)

| Case | A r1 / r2 | C r1 / r2 | C/A |
|---|---|---|---|
| echo c64 | 280.5k / 275.5k | 278.7k / 278.1k | 1.00 |
| echo c1024 | 237.5k / 235.9k | 238.8k / 234.0k | 1.00 |
| fan-out 1000×1000 Hz | 268.7k / 269.7k | 647.9k / 648.9k | 2.41 |
| trading 2000, feed | 254.6k / 254.0k | 633.9k / 633.1k | 2.49 |
| trading 2000, order RTT p50 / p99 | 8.6 / 10.4, 8.7 / 10.4 ms | 31.1 / 100.7, 59.3 / 129.2 ms | the send_round trade-off (#92) |
