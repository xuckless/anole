# Anole Performance Audit

*Scope: networking and request-serving hot paths (HTTP/1.1, HTTP/2, gRPC, HTTP/3, TLS, static files, compression, runtime). Report only, no code changed.*
*Sources: HttpArena PR [MDA2AV/HttpArena#1608](https://github.com/MDA2AV/HttpArena/pull/1608) and its saved results (`site/data/results/anole.json`); anole at `480fd09` (0.3.0); the zio fork at `88f6d69`; the source of the HttpArena leaders (zix, aegon, agensio, cnetmod, h2o, vanilla, minima-sync, zeemo, dusty, bun/uWS); and local measurements of the real HttpArena entry built from anole HEAD.*

---

## 0. Read this first

### 0.1 The leaderboard numbers come from an old anole
HttpArena's `frameworks/anole/build.zig.zon` pins **anole v0.1.2** (`b0f2eb0`), and that in turn pins zio `683612b`.

So I didn't trust the old numbers alone. I built the **same arena entry (`frameworks/anole/src/main.zig`) against anole HEAD** and measured it locally. Every killer below was **reproduced on HEAD** unless marked otherwise. The fixes since 0.1.2 (h3 per-stream signals, WebSocket batching and so on) did not touch the main killers.

### 0.2 How I measured
- **Box:** a 4-core / 15 GB cloud VM, with the load generator (wrk, h2load) on the same box.
  - Absolute rps are therefore meaningless. **Ratios, CPU per request and I/O ops per request are what count.** Those don't depend on core count.
- **CPU per request:** `utime+stime` of the server process divided by completed requests.
- **I/O ops per request:** the server runs on **io_uring** (verified). Syscall counts hide the real work, so I read the rings' `SqTail` counters in `/proc/<pid>/fdinfo` before and after each run.
  - **SQE/req** = io_uring operations submitted per request.
- **mmap/munmap per request:** `strace -f -c`. Allocation sites came from `strace -k` stack traces.
- **Build:** the arena flags (`-Dtarget=x86_64-linux-musl -Doptimize=ReleaseFast`). I used the "full" feature preset minus pg/redis/sqlite/mongodb/nats/kafka/auth/openapi, and dropped the DB routes from `main.zig`.
- **Not measurable here:**
  - HTTP/3: Ubuntu's h2load falls back to TCP.
  - Anything that only shows up with 64 cores contending: mmap_lock, global atomics, accept imbalance.
  - Those parts come from code reading and are labelled **(hypothesis)**.

### 0.3 Evidence labels
Each finding carries one of these:
- **[Measured]**: reproduced locally on HEAD.
- **[Code]**: verified by reading the code, with file:line.
- **[Hypothesis]**: consistent with the arena data, but needs a 64-core run or a profile to confirm.

### 0.4 The arena results that matter (anole vs the leader in each profile)

| Profile | anole | Leader | Gap | Tell-tale |
|---|---|---|---|---|
| pipelined (16x) | 4.17M | zix 58.8M | **14x** | ≈ baseline, i.e. no batching |
| baseline h1 | 3.12M | zix 4.44M | 1.4x | CPU-bound |
| json-comp | 80K @ **1789% CPU** | vanilla 2.86M / aegon 962K (same tier) | **12x** | idle CPU + 51 ms average latency |
| unary-grpc | 76K @ **291% CPU** | cnetmod 7.6M | **100x** | idle CPU + 343 ms average latency |
| baseline-h3 | 64K @ **360% CPU** | zix 9.1M | **140x** | idle CPU + 52 ms average latency |
| static-h3 | 27K | cnetmod 871K | 32x | idle CPU |
| json-h2c | 740K @ 2016% CPU | zix 6.8M | 9x | idle CPU, p99 0.7–5 s |
| static-h2 | 225–325K | zix 1.65M | 5–7x | |
| static-tls | 421K | fib 1.23M | 3x | CPU-bound (6578%) |
| baseline-h2 | 7.8M | h2o 16.1M | 2x | 7.6 µs/req vs aegon 4.5 (aegon also uses nghttp2) |
| async (/delay/10) | 1.8M | edixoi 2.83M | 1.6x | 30.6 µs/req vs 22 |
| latency-1m (CPU/req) | 24.9 µs | aegon 14.9 / tokio 18.7 | 1.3–1.7x | |
| gateway-h3 | **#1** | | | your h3 *client* side is fine |

**The pattern:** the profiles where anole is CPU-bound show modest gaps (1.3–3x). The catastrophic ones (gRPC, h3, json-comp, json-h2c) all run with **most cores idle and huge latency**. That isn't "slow code". That is **waiting**: on the kernel (mmap_lock, TLB shootdowns), on timers, on ACKs, or on an unbalanced executor.

---

## 1. Ranked summary

| # | Killer | Profiles hit | Evidence | Expected effect | Effort |
|---|---|---|---|---|---|
| **K1** | Per-stream body buffers on HTTP/2: 64 KiB queue on the first DATA frame, then a 1 MiB "reading" raise; both in the stream arena, so `mmap`/`munmap` on every stream | unary-grpc(-tls), any h2 POST | **Measured: 0.71 mmap + 0.71 munmap per gRPC call**, 1.58 MB maps; 55–109 µs/req vs 3.9 µs for h2c GET | Largest single win: gRPC from 76K toward millions | S–M |
| **K2** | The allocator: `init.gpa` → Zig's libc `malloc` → `SmpAllocator`, which `mmap`s **every allocation over 32 KiB**; arenas grow by 1.5x, so any arena past ~20 KiB crosses that line | h2 JSON, static-h2, gRPC, TLS big blocks, compression scratch | **Measured** (json-h2c 0.03 mmap/req from `BodyBuffer.nextSegment`) + **[Code]** | Removes the idle-CPU collapse under 64 cores | M |
| **K3** | HTTP/1.1 flushes once per response (no corking) and hands the write buffer back per request | pipelined, all h1 | **Measured: 1.06 SQE/req pipelined** (ideal 0.125) | pipelined 4M → 30–50M; baseline +5–10% | S |
| **K4** | json-comp: `gzip, br` → Brotli q5, a new encoder per response; JSON via `std.json.fmt` | json-comp | **Measured: 188 µs/req (br) vs 88 (gzip) vs 34.6 (identity)**; JSON alone ≈ 26 µs for 50 items | 2–5x on json-comp (mind the ratio² scoring) | S |
| **K5** | Connection imbalance across pinned executors under churn (`fast_accept` budgets that grow with load, one shared listen socket) | json-comp (`-r 25`), limited-conn, json-tls p99 | **[Hypothesis]**: 4096 vs 16384 connections give the same 80K; the latency math says ~18 of 64 executors carry the load | Up to 3x on churny profiles | S (config) |
| **K6** | HTTP/2 engine shape: reader task + writer task + task per stream + mutex + broadcast wake-ups + 3–4 copies of every DATA byte; gRPC unary forced into streaming mode | all h2/gRPC | **Measured**: gRPC 18 µs/req at `-m 1` vs 55 µs at `-m 100`; **[Code]** | baseline-h2 ~2x; gRPC/json-h2c several x | L |
| **K7** | Static files: `open`/`stat`/`open .br`/`stat`/read/`close` on every request, each one an io_uring round trip | static-tls, static-h2, static-h3, gateway | **Measured: 13 SQE/req (h1 TLS), 8.1 (h2)**; 61–80 µs/req vs 16 µs for JSON over TLS | 2–4x on static profiles | M |
| **K8** | Runtime: every I/O op parks the task, even one completed inline; one loop tick per send; no multishot recv; 2 `io_uring_enter` per request at low load | baseline, latency-1m/10k/500k, async | **[Code]** (zio audit) + measured 2.0 SQE/req | 10–30% CPU/req; big for latency profiles | M (zio fork) |
| **K9** | Process-wide atomics per request (`busy` counter + `futexWake` through zio's global bucket mutex), adjacent per-executor gauges (false sharing) | all, worse at 64 cores | **[Code]** | 5–15% at 3M+ rps | S |
| **K10** | Timer churn: 2–3 `AutoCancel` arm/clear per request, each a locked pairing-heap operation | baseline, async, latency-* | **[Code]**, measured +6 µs/req on `/delay` | 5–20% CPU/req | M |
| **K11** | HTTP/3: ACK and stream-credit coupling (ngtcp2 defaults), a 1 ms hold for tasked routes, every packet padded, 12 KB GSO batches, 4 KiB static sink | baseline-h3, static-h3 | **[Code]**, cause of the 50 ms waits not yet confirmed | 10–100x (it's a stall) | M |
| **K12** | Memory-first defaults everywhere (1 KiB idle read buffer, buffers released per request, 1 KiB TLS stash, `MADV_DONTNEED` trims) | all | **[Code]** | 3–8% CPU/req | S |
| **K13** | Response head cost: 112 B vs 61 B (Date + `text/plain; charset=UTF-8`), many linear `headers.get` scans per response | baseline, pipelined | **Measured** (bytes) + **[Code]** | 3–5% | S |

S = hours to a day, M = days, L = a week or more.

---

## 2. The killers in detail

### K1: HTTP/2 request bodies cost an `mmap` + `munmap` per stream (gRPC collapse)

**Symptom.** unary-grpc ran at 76K rps on **291% CPU** with a 343 ms average. Little's law: 256 connections × 100 streams ÷ 76K/s ≈ 337 ms. Every stream sits in a queue behind something slow and serialized.

**Measured (HEAD, h2load `-c16 -m100`, the arena's gRPC request):**

| | rps (4 cores) | CPU/req | mmap/req | munmap/req | avg latency |
|---|---|---|---|---|---|
| h2c GET `/baseline2` | 634K | **3.9 µs** | 0.0001 | 0.0001 | |
| gRPC GetSum `-m 100` | 32.5K | **55 µs** | **0.71** | **0.71** | **48.6 ms** |
| gRPC GetSum `-m 1` | 103K | 18 µs | – | – | 0.12 ms |

**Root cause.** Two layers, both confirmed with `strace -k` stack traces.

1. **The 64 KiB body queue on the first DATA frame.** `onDataChunk` allocates the stream's body queue at full `stream_window` (64 KiB, `src/http/core/config.zig:317`) in the stream's arena, no matter how small the body is (the gRPC body is 9 bytes).
   - `std.heap.ArenaAllocator` sizes a new node as `1.5 × (prev + n + header)` (Zig `lib/std/heap/ArenaAllocator.zig:517`), so it asks for **~100 KB**.
   - That is above SmpAllocator's 32 KiB ceiling (see K2), so it becomes an `mmap`.
   - `Stream.release` → `arena.reset(.retain_with_limit = 128 KiB)` / `deinit` (`h2.zig:620-660`) gives it back with `munmap`.
   - Stack: `ArenaAllocator.alloc ← Engine.onDataChunk ← nghttp2_session_mem_recv2` (604 × 102,400-byte maps in a 2 s run).
2. **The 1 MiB raise on the handler's first body read.** When the handler reads before the stream's END_STREAM has been processed, `raiseWindow` (`h2.zig:550-588`) allocates `stream_window_reading` = **1 MiB** (`config.zig:323`) in the same arena. The node becomes **1,581,056 bytes**, plus `munmap` later.
   - Stack: `ArenaAllocator.alloc ← BodyReader.streamFn ← … ← grpc.frame.readMessage ← grpc.server.readPayload`.
   - The budget (`reading_window_budget` 16 MiB) allows 16 of these per connection at a time.
   - **Experiment:** setting `stream_window_reading = 64 KiB` removed the 1.58 MB maps. The rate stayed at 0.72 mmap/req because of layer 1. Both layers have to go.
3. Only 9 of the 64 KiB (and 1 MiB) are ever written, so the cost is the **syscalls and VMA churn**, not page faults.
   - On 64 cores each `mmap`/`munmap` takes the process-wide `mmap_lock` for write.
   - Each `munmap` sends TLB-shootdown IPIs to every CPU running a thread of the process.
   - That is what turns "slower" into **291% CPU + a 343 ms queue**: threads sleep on `mmap_lock`.

**Leaders.**
- cnetmod: 7.6M at 1179% CPU. Reserves per-connection buffers up front and sends **one connection-level WINDOW_UPDATE per batch** (`session.cpp:815-818`).
- vanilla: precomputed HPACK blocks, replenishes windows eagerly.
- zix: decodes the 9-byte message straight out of the read buffer.
- None of them allocates per stream.

**Fixes.**
1. **Size the queue to the need.** If the DATA frame carries END_STREAM, or `content-length` is known and ≤ some small cap (say 16 KiB), allocate exactly that. Better still, don't queue at all: copy the payload into a small arena slice and mark `body_done`.
   - For unary gRPC (9 bytes) this removes the queue entirely.
2. **Never raise a stream whose body is complete or small.** Raise only when `content-length` is unknown or > `stream_window` **and** the handler is actually starved (the queue was full when it read).
   - `raiseWindow` already checks `body_done`, but the handler runs before the trailing END_STREAM is seen. Check the declared `content-length` too.
3. **Take big buffers out of the stream arena.** Get 64 KiB / 1 MiB buffers from a per-executor free list (like `block_cache`, which already exists for compression) and return them on stream close, so steady state makes no syscalls.
4. **Grow the window in steps** (64 KiB → 256 KiB → 1 MiB) when the queue keeps filling, instead of one 1 MiB jump.

**Expected:** gRPC per-request CPU from ~55 µs toward the ~4 µs of h2c GET, and the stall disappears. Combined with K6, cnetmod/zix territory (millions) is realistic. Even a rate equal to anole's own baseline-h2 (7.8M) would be a 100x gain on this profile.

---

### K2: The allocator. Anything over 32 KiB is an `mmap`, and arenas cross that line easily

**[Code] chain:**
- **`init.gpa` is `c_allocator`.** Zig 0.17 `lib/std/start.zig:794-801`: in ReleaseFast with `link_libc`, `gpa = std.heap.c_allocator`. anole links libc (`build.zig:595`), and the arena entry passes `init.gpa` to `Server.init`.
- **Zig provides that `malloc` itself, on SmpAllocator.** On the musl target, Zig 0.17 supplies the libc `malloc` (`lib/c/malloc.zig:46`): a wrapper around **`std.heap.SmpAllocator`**.
- **Everything over 32 KiB goes to `mmap`.** SmpAllocator's size classes end at 32 KiB. Anything larger goes straight to `PageAllocator.map` (`SmpAllocator.zig:51,124`), and `free` is a `munmap`. There is **no caching** of large blocks.
- **The C libraries use the same malloc.** BoringSSL, nghttp2, ngtcp2 and nghttp3 call `malloc`, and so does anole's `std.heap.c_allocator` use in `src/tls/dusty_tls.zig`.
- **Arenas cross the line quickly.** ArenaAllocator node growth is 1.5x, so an arena that has handed out ~20 KiB asks for a > 32 KiB node next.

**Where it bites (measured or traced):**
- **h2 JSON responses:** `response.BodyBuffer.nextSegment` doubles segments (512 → 1K → … → 64 KiB, `response.zig:230-231,330`) inside the stream arena. Measured **0.029 mmap/req** on json-h2c, plus `mremap` from the writer's spill list.
- **h2 response machinery per stream:** 32 KiB `out_queue_len` + 16 KiB `body_writer_len` (`h2.zig:91-95`). One streamed response puts the arena over the line.
- **gRPC:** see K1.
- **Compression:** `block_cache` caches only blocks ≥ **64 KiB** (`block_cache.zig:28`). Brotli/zlib scratch allocations between 32 and 64 KiB go to `std.c.malloc`, which means `mmap`.
  - zlib's window and prev arrays at `window_bits` 15 are 32 KiB each, plus a 16-byte header, which lands just over the line.
- **TLS:** `Buf.grow` past `big_len` (64.5 KiB) and pool overflow (`dusty_tls.zig:1554-1615`) use `c_allocator`, so they `mmap` too.

**Why it explains "idle CPU":** a page-allocator call per request is cheap on 4 cores, but on 64 threads every one serializes on `mm->mmap_lock` and triggers cross-CPU TLB shootdowns. Threads block in the kernel, so the cgroup shows idle CPU while latency explodes. This is the classic signature in the json-h2c / json-comp / gRPC / static-h2 rows. **[Hypothesis for the 64-core magnitude; the per-request maps are measured.]**

**Fixes (any one helps; 1 + 2 is the robust combination):**
1. **Per-executor large-block cache for everything.** Generalize `block_cache` (thread-local, size-classed in powers of two from 32 KiB to 2 MiB, bounded) and use it as the **backing allocator of every per-request/per-stream arena**, for h2/h3 queues and TLS blocks.
2. **Replace the process allocator.** Link **mimalloc** (or rpmalloc/snmalloc), export it as `malloc` for the C libraries, and wrap it as `gpa`. cnetmod and agensio use mimalloc. mimalloc keeps large blocks in thread-local segments and returns memory lazily.
   - At minimum, in the Zig layer pass anole's own allocator instead of `init.gpa` when the server owns the heap.
3. **Right-size arena first chunks** so a typical h2 stream never grows a node. For example, give the stream arena a 32 KiB first chunk from the per-executor cache, and make `BodyBuffer` grow from a pooled 16 KiB segment instead of 512 B doubling.
4. Add a `/metrics` counter for `mmap` calls (wrap `PageAllocator`) so this never regresses silently.

---

### K3: HTTP/1.1 sends one write per response. No corking, so pipelining is free performance left on the table

**Measured (HEAD):**

| | SQE/req | rps (4 cores) |
|---|---|---|
| baseline (1 request/round trip) | 2.00 (recv + send) | 210K |
| pipelined ×16 | **1.06** | 462K |
| ideal pipelined (1 recv + 1 send per 16) | 0.125 | – |

**[Code]:**
- `Response.finish` → `w.flush()` for every HTTP/1.x response (`src/http/core/response.zig:977-979`).
- `handleRequests` releases the write buffer after every request (`server.zig:3017`).
- So 16 pipelined requests become 16 `send` SQEs and 16 park/resume cycles (each send waits a full loop tick, see K8).
- This came from dusty (`dusty/src/response.zig:1175`), which explains why dusty's pipelined number (4.38M) is the same.

**Leaders, all the same pattern:**
- zix: `dispatch()` loops over the buffer, handlers append to `send_buf`, one `submitSend` (`zix/src/tcp/http1/dispatch/uring.zig:993-1175`).
- minima-sync: `DrainAndSend`.
- zeemo: "submit one send for the whole batch".
- aegon: `resp_batch`.
- uWebSockets/Bun: `cork()` before parsing and `uncork()` after the last pipelined request (`HttpContext.h:142,287`), with a 16 KiB per-loop cork buffer.
- Your own WebSocket path already batches (echo-ws-pipeline 55.7M vs dusty 5.1M). The HTTP path just doesn't.

**Fix:**
1. In `Response.finish` (HTTP/1.x only), when the connection's reader **still holds bytes** (`reader.bufferedLen() > 0`) and the response is complete and buffered, **don't flush**. Leave the bytes in the write buffer and keep that buffer across the pipelined requests (skip `releaseWriteBuffer` while input is buffered).
2. Flush when any of these happens:
   - the buffered input runs out (before `waitForRequest` / `fillMore`);
   - the write buffer is full (`drain` handles it);
   - a handler is about to block (not a `noWait` route), so earlier responses aren't held hostage;
   - `Connection: close` / an upgrade.
3. A clean place for this is a "flush owed" flag on `Connection` checked in `handleRequests` right before it waits for input.

**Expected:** pipelined should reach the 30–50M class (aegon does 27.6M with coroutines). Baseline also gains a little, because the same change removes the per-request buffer give-back/take.

---

### K4: json-comp: Brotli q5 on every request, a new encoder each time, and slow JSON

**Measured (HEAD, `GET /json/50?m=6`, server CPU µs/req):**

| Accept-Encoding | rps (4 cores) | **CPU/req** | with 1-in-25 `Connection: close` (like `-r 25`) |
|---|---|---|---|
| `identity` | 79K | **34.6 µs** | 37.7 µs |
| `gzip` | 39K | **88 µs** | 105 µs |
| `gzip, br` (the arena's) | 19.4K | **188 µs** | 184 µs |

Baseline is 8.9 µs, so **JSON serialization alone is ~26 µs** for 50 items, **gzip adds ~53 µs** and **Brotli q5 adds ~154 µs**. The arena run spent ~223 µs/req (1789% / 80K), which agrees.

**[Code]:**
- The q-value tie between `gzip` and `br` picks Brotli (`response.zig:1694`), at quality 5 (`response.zig:838`). Your `docs/routing.md` even says "most HTTP benchmarks … get `br`".
- `BrotliEncoderCreateInstance` runs per response (`brotli_io.zig:75`); for q5 that means initializing ~600 KiB of hasher tables.
- gzip uses `zlib.Compress.init` per response at level `.default` = 6 (`response.zig:1629,1781-1798`).
- JSON goes through `std.json.fmt` (`response.zig:1207-1222`), byte by byte through the `std.Io.Writer` vtable. Your own doc comment says `json.encode` is "considerably faster".
- The arena entry's comment says "gzip or zstd" (`frameworks/anole/src/main.zig:90`), but the client offers `gzip, br`, not zstd.

**Leaders:**
- aegon (same tier): 962K, **libdeflate level 1**, thread-local compressor reused (`Aegon/src/http/middleware/Compress.h`).
- cnetmod: thread-local zlib stream `deflateReset`, or one-shot Brotli **q2**.
- zix: custom fixed-Huffman gzip.
- vanilla (engine tier): caches the gzipped bodies.
- dusty, your ancestor: 397K with zlib-6 per response and *full* CPU use.

**Scoring caveat:** json-comp is scored `rps × (minBytes/myBytes)²`. anole's Brotli output (1238 B) is the **smallest on the board**, so a codec change must be judged on rps × ratio².
- Example: aegon's libdeflate-1 output is 1434 B, so at equal rps anole would keep only (1238/1434)² ≈ 0.745 of the score.
- Brotli q5 is still the wrong trade: it's ~2x gzip's CPU for a 13% size win, which is worth 1.32x in score.

**Fixes (pick by measured score):**
1. **Make the dynamic-response codec choice CPU-aware.** On a tie, prefer gzip (or zstd) for dynamic bodies and keep Brotli for precompressed files. Or run dynamic Brotli at **q1–q3**: q2 is several times cheaper than q5 and still beats gzip-1 on size for JSON.
2. **Reuse encoders per executor.**
   - gzip: keep a thread-local `z_stream` and `deflateReset`, or switch to **libdeflate** (one-shot, no state, about 2–3x faster than zlib-ng at level 1–4 on small bodies).
   - Brotli has no reset, but `BrotliEncoderCompress` (one-shot) at low quality allocates far less.
   - zstd: keep a `ZSTD_CCtx` per executor (`ZSTD_compress2` with reset).
3. **Faster JSON:** route `res.json` for comptime-known types to the yyjson / `json.encode` path, or write a comptime-specialized serializer straight into the body segment. 26 µs for 50 items should be ~3–5 µs.
4. Choose the levels by sweeping {gzip-1/4, libdeflate-1/6, br-1/2/3/4, zstd-1/3} and computing rps × (1238/size)² locally.
5. Also see **K5**: the arena run used only ~18 of 64 cores, which is a second, independent 3x.

---

### K5: Connections pile up on a few executors under churn **[Hypothesis]**

**Arena data:**
- json-comp gives **the same 80K at 4096 and at 16384 connections**, while using 1789% of 6400%.
- With 4096 connections over 64 executors (64 each) at ~223 µs/req, one round per executor should take ~14 ms. The measured average is **51 ms**, so the busiest executors carry roughly **3–4x their share**.
- Only churny profiles look like this. json-comp reconnects every 25 requests (gcannon `-r 25`) and limited-conn every 10. json-tls has a p99 of 1.88 s.

**[Code] (from the zio audit):**
- Every executor runs an accept loop on **one shared listening socket**: `socket_per_acceptor = false` by default (`src/http/core/config.zig:147`).
- zio's `fast_accept` (on, `src/server.zig:144`) does a direct `accept()` and takes up to `max(128, tasks that ran last round)` connections per pass. **The budget grows with how busy the executor is.**
- With pinned scheduling a connection never moves. An executor already full of slow (compressing) connections can therefore grab whole bursts of new ones, which is a rich-get-richer loop.
- Locally (4 executors) load stayed balanced, so this needs a 64-core check.

**How to verify:** the per-executor `anole_runtime_tasks` / `anole_connections` gauges you already export (0.3.0). Scrape `/metrics` during a json-comp run, or `Runtime.executorStats`.

**Fixes:**
1. Turn on **`socket_per_acceptor = true`** (SO_REUSEPORT per executor). The kernel then spreads connections by 4-tuple hash, independent of how busy an executor is. Optionally attach a CBPF/eBPF program that picks the socket by CPU.
2. Cap `fast_accept` bursts at about `backlog / executors`, or make the budget **shrink** when the executor is busy (invert the current feedback).
3. Longer term: a cheap migration path, so a newly accepted connection can be handed to the least-loaded executor before its first read.

---

### K6: The HTTP/2 engine is shaped against the hardware

**[Code]** (`src/http/core/server/h2.zig:5-29`):
- **Tasks:** one reader task, one writer task, and one task per stream for any route that is not `noWait`, or whose body arrives over more than one read.
- **One `std.Io.Mutex` around every nghttp2 call.**
- **`kickWriter` wakes everyone.** It does `futexWake(maxInt)` on `write_gen` (`h2.zig:333-336`), so every stream task waiting for its body wakes on every frame anyone queues: O(streams²) wake-ups per batch.
- **Every DATA byte is copied 3–4 times:** handler → per-stream `out` ring (32 KiB) or backlog → nghttp2's buffer (`provideData` `@memcpy`, `h2.zig:2384-2450`) → `nghttp2_session_mem_send2` result copied into the write buffer (`h2.zig:999-1010`) → encrypted by TLS.
- **The writer arms and clears a write timer per flush** (`h2.zig:1018-1026`).
- **gRPC unary is pushed into streaming mode.** `grpc.server.serve` gives every call a 16 KiB `out_buf` (`src/grpc/server.zig:439-440`), so `writeBytesWith` calls `res.stream()` (`grpc/server.zig:1331`).
  - The unary response then goes headers-alone → body → flush → trailers through the streaming sink, with `armWrite`/`disarmWrite` timers.
  - It does not go as one `complete()` (HEADERS + DATA + trailers) submission.

**Measured:**
- gRPC is **18 µs/req with 1 stream per connection, but 55 µs/req with 100** (the K1 maps make up most of the difference).
- baseline-h2 over TLS runs at 4.5 µs/req locally. The arena's 7.6 µs/req compares with **aegon's 4.5 µs on the same nghttp2**, so the library is not the limit.

**Leaders:**
- aegon (nghttp2): `mem_recv` over the whole buffer, run *all* handlers synchronously, `submit_response` for each, then **one** `mem_send` loop into one buffer and one write (`Http2Connection.cpp:582-700`). No per-stream coroutine and no writer task.
- h2o: one gathered write per loop pass, using a zero-delay timer.
- agensio: TLS DATA frames sized so that frame + header = exactly one 16 KiB record, with 64 KB write cycles.
- cnetmod: flush at 64 KiB or 32 responses / 250 µs, plus double-buffered writes.

**Fixes (from cheapest):**
1. **Fast path for unary gRPC.** When the method is unary and the request message is complete in the DATA already received, decode in place, run the handler inline, and answer with `complete()`: HEADERS + DATA + trailers in one `nghttp2_submit_response2` with a provider that has everything.
   - Never call `res.stream()` for unary. Use the collected `impl.buffer` path that already exists.
   - Precompute the HPACK for `:status 200` / `content-type: application/grpc` / `grpc-status: 0`, as vanilla does.
2. **Targeted wake-ups.** Signal one waiter per stream (h3 already moved to per-stream signals in 0.2.1); the writer gets its own futex word.
3. **Writer inline by default.** After `runInline`, the reader itself runs the `mem_send` loop and writes. Spawn or wake the writer task only when the write would block (`EAGAIN` / partial). This removes the cross-task hop per batch in the common case.
4. **Zero-copy DATA:** `NGHTTP2_DATA_FLAG_NO_COPY` plus `send_data_callback`, writing frame headers and payload slices with `writev` (or straight into TLS records) instead of copying them twice through nghttp2's buffer.
5. **Record-aware TLS framing:** size DATA frames so that frame + payload fills a 16 KiB record (agensio) and cycle at 64 KiB on TLS.
6. **Batched WINDOW_UPDATE:** one connection-level update per read batch rather than per-stream `consume` calls.
7. Long term: a custom HPACK/frame layer for the server hot path (cnetmod, agensio and zix all wrote one). Not needed before 1–6.

---

### K7: Static files are re-opened, re-stat'ed and re-read on every request

**Measured (HEAD, `/static/app.js`, `.br` variant 47 KB):**

| | SQE/req | CPU/req |
|---|---|---|
| JSON over TLS (h1), for comparison | 2.0 | 16.4 µs |
| static over TLS (h1) | **13.0** | **61 µs** |
| static over h2/TLS (20-file rotation) | **8.1** | **80 µs** |

**[Code]:** `Static.serve` (`src/http/core/server/static.zig:100-160`) works like this:
1. `sendFile(plain)`: `openat` + `fstat`;
2. for each precompressed candidate, `sendFile(path.br)`: another `openat` + `fstat`, then close the first;
3. `sendFileBody` reads the file through the `Io` in `file_piece` chunks (`response.zig:2033-2065`);
4. close.

Every one of those is an io_uring operation with a park/resume and a loop tick (K8). The ETag string is formatted per request too.
- **Over TLS the bytes are then copied** from file → write buffer → `SSL_write` → BIO pending → socket.
- **h3:** the sink buffer is capped at 4 KiB, so a 47 KB file takes 12 read round trips (h3 audit, `h3/server.zig:2941`).

**Leaders:** fib, agensio, ioxide, cnetmod and vanilla all serve **precompressed bytes from memory**.
- vanilla snapshots files and re-checks them every 100 ms, and uses kTLS + `sendfile` for bodies ≥ 16 KiB with the header sent `MSG_MORE`.
- zix prewarms its static cache at startup.

**Fixes:**
1. **Static cache** inside `staticDir`. Map path → `{bytes per encoding, content type, ETag, Last-Modified, length}`, bounded by total size.
   - Revalidate by `statx` at most every N ms, or with inotify.
   - The response body becomes a borrowed slice, so one write and zero file syscalls per hit.
   - Serve from memory for files ≤ X MB, and keep `sendfile` for large plain-TCP files.
2. Pre-render the response head per (file, encoding), and pre-format the ETag.
3. Over TLS, pass the cached slice straight to `SSL_write` in 16 KiB chunks. kTLS is a later option: BoringSSL doesn't do kTLS natively, but the traffic secrets can be exported.
4. h3: lift the 4 KiB sink cap for static bodies, or hand nghttp3 the cached slice directly with a no-copy data reader.

---

### K8: Runtime overheads per I/O operation (zio)

**[Code]** (full zio audit; the line numbers are in the fork at `88f6d69`):
- **Every op parks, even when it completed synchronously.** `waitForIoImpl` (`zio/src/common.zig:620-690`) uses no completion callback. The wake goes through the loop's `dispatched` queue, so an op that completed inline still costs a switch out, a loop pass, a drain and a switch back.
- **A send costs a tick round trip on io_uring.** The SQE is submitted at the next `poll()`, so the task can't continue until a tick has submitted and reaped it. A request is therefore **2 tick round trips** (send, then recv). At low load that is **2 `io_uring_enter` + 4 coroutine switches per request**, which is the latency-1m/10k standing cost.
- **No multishot recv, no provided-buffer ring, no registered files, no registered ring fd.** Every recv is a fresh SQE plus an async-poll arm.
- **`io_uring_enter` on every tick with ready tasks,** even when there is nothing to submit (`hasInflight()` is always true while recvs are parked).
- **Idle-trim list touched on every park and resume** (`runtime.zig:734-740,1279`): up to 2 extra cold cache lines per wake.
- **Stacks:** 1 MB reserved and 256 KiB committed per connection, on 4 KiB pages (`NOHUGEPAGE`), and every stack top sits at the same page offset. With 32K connections (async) that means cold cache lines and TLB misses on every resume.
- **Silent epoll fallback:** if io_uring setup fails (kernel < 6.1 rejects `DEFER_TASKRUN`, or `io_uring_disabled`), zio quietly uses epoll. That path has a **process-wide `inflight_io` atomic** with 2 RMWs per op, and shared unpadded sockreg shards. HttpArena does run `seccomp=unconfined`, but **nothing logs which engine was picked**.

**Leaders:**
- zix: adaptive `submitAndWaitTimeout(wait_nr = count/2, ≤32, 20 µs)`, SO_BUSY_POLL 50 µs, an inline state machine and half-duplex connections.
- aegon: plain `submit_and_wait(1)`, but with **no coroutine hop per op on completion of a send**.

**Fixes (in the zio fork):**
1. **Send fast path:** try a direct non-blocking `send()` first and use an SQE only on `EAGAIN` or a partial write. That saves a tick, an enter and 2 switches per response.
2. **Don't park when `loopAdd` completed the op inline** (check `has_result` and return).
3. **Multishot recv + a provided buffer ring** for idle keep-alive connections. They already sit in a 1 KiB stack buffer, so a shared ring is nearly free.
   - zix found it slower at pipeline depth 16 because of the extra memcpy. Use it for the waiting state only.
4. Skip the zero-timeout enter when `to_submit == 0` and there is no taskrun flag (`IORING_SETUP_TASKRUN_FLAG`).
5. **Adaptive wait batching** (min_complete > 1 with a ~20 µs timeout) under load, which amortizes enters for latency-1m.
6. **Log `selectedEngine()` and the setup errno at startup**, and put it on `/metrics`.
7. Lazy idle-trim bookkeeping. Optionally stagger stack tops, and consider smaller committed stacks.

---

### K9: Process-wide atomics on every request

**[Code]:**
- **The `busy` counter.** `Server.busy` is one atomic for the whole process. Every keep-alive request does `fetchAdd` on arrival (`server.zig:2057`) and `fetchSub` when it next waits (`server.zig:2016`).
  - When the count reaches 0, which at low load happens on nearly every request, it calls `io.futexWake`.
  - zio's `Futex.wake` **always locks a global hash-bucket mutex**, even with no waiters (`zio/src/sync/Futex.zig:217-248`).
- **The draining flag:** every request also reads `busy.load(.acquire).draining` (`server.zig:2980`), a line the other 63 cores keep writing.
- **Gauges:** the per-executor gauges (0.3.0) are adjacent atomics, so 8 executors share a cache line (`gauges.zig:12-21`).
- **Connection counts:** `active_connections` is a global `fetchAdd`/`fetchSub` per connection (matters for churny profiles).

At 3M rps that is roughly 6M contended RMWs per second on one cache line, plus a mutex at low load. That alone can explain part of the baseline ceiling (61 of 64 cores, 1.4x behind) and part of the latency-10k standing cost. **[Hypothesis for the magnitude.]**

**Fixes:**
- Per-executor `busy` counters (cache-line padded). The drain sums them, or each executor reports "my count hit 0" only while a drain is pending.
- Keep `draining` in its own read-mostly line.
- Pad the gauges.
- Add a "no waiters" fast path to zio `Futex.wake` (check the bucket's waiter count before locking).

---

### K10: Timer churn on every request

**[Code]:**
- **A keep-alive request arms and clears 2–3 `AutoCancel` timers** (`deadline.zig:104-130`; `server.zig` `armTimer`/`armDeadline` around 2678-2850):
  1. the keep-alive or park wait;
  2. a clear when the request arrives;
  3. the request deadline (`timeout.request` 30 s by default);
  4. a clear at the end.
- **Each `setClock` is two heap operations.** It does a clear (timer mutex, `tryDisarm` CAS, heap remove) followed by a set (mutex, `clock_gettime`, heap insert).
- **The heap itself is costly.** zio's timer is a **pairing heap per clock under a per-loop mutex** (`zio/src/ev/loop.zig:249-276`), and its nodes live on other tasks' stacks (pointer chasing).
- **The h2 writer adds one per flush:** it arms and clears a write timer on every flush (`h2.zig:1018-1026`).
- **Measured:** `/delay/10` costs **17.1 µs/req vs 11.1** for baseline at the same 1000 connections. Arena: 30.6 µs/req vs 22 µs for the leaders.

**Fixes:**
1. **Lazy deadlines.** Store a deadline timestamp in the connection and let one per-executor **coarse sweep** (you already have the park "shelf" sweeper running every 1 s) cancel overdue connections. Arm a real timer only when the remaining budget is shorter than the sweep period.
   - 30 s request and 75 s keep-alive deadlines don't need nanosecond timers on every request.
2. In zio: a **hashed timer wheel** per executor (O(1), no pointer chasing). Skip `timer_mutex` when the caller is the owning thread, which is always the case under pinned scheduling.
3. Re-arm only when the deadline moves earlier than the armed one, or by more than a slack.

---

### K11: HTTP/3 stalls **[Code + Hypothesis, not reproduced locally]**

**Symptom.** baseline-h3 ran at 64K rps on 360% CPU with a 52 ms average latency, even though the transport design is right:
- per-core REUSEPORT sockets with CBPF steering by connection-ID byte;
- recvmmsg + GRO;
- sendmmsg + GSO.

anole is #1 on gateway-h3, which uses anole's h3 client.

h2load times an h3 request until the **stream closes**, and that needs **the server's ACK of the request**. It opens the next request only when the previous one closes.

**Suspects (from the h3 audit, ranked):**
1. **ACK and stream-credit coupling.**
   - ngtcp2 delays ACKs for `min(max_ack_delay, srtt/8)` or until `ack_thresh = 2` (verified in ngtcp2 1.25 source). When 64 requests arrive in one packet, the response leaves **without** the ACK.
   - MAX_STREAMS credit (`extend_max_streams_bidi(1)`, `h3/server.zig:2346-2358`) only returns after ngtcp2 closes the stream, which needs the client's ACK of the response FIN.
   - With `max_streams_bidi = 100` and `-m 64`, credit runs dry once more than 36 answered streams are waiting for an ACK.
   - A 25 ms `max_ack_delay` plus PTO fits the ~50 ms average and the 167 ms p99.
2. **A 1 ms "hold" before flush for tasked (non-`noWait`) routes** (`h3/server.zig:77-80,2153-2171`). It applies to static-h3: file I/O never releases the hold, so every batch waits the full 1 ms.
3. **Every packet padded** (`NGTCP2_WRITE_STREAM_FLAG_PADDING`, `h3/bridge.zig:110`). It costs bytes and AEAD work.
4. **Small GSO batches:** `tx_round` = 10 × 1200 = 12 KB (`h3/server.zig:73-76`).
5. **No SO_RCVBUF/SO_SNDBUF tuning,** so bursts can be lost under load, which turns into PTOs. The `Stats.dropped`/`forwarded_out` counters aren't exported (`h3/server.zig:294-328`).
6. **On HEAD's zio, each sendmmsg costs a loop round trip on io_uring.** v0.1.2 made the call directly; CHANGELOG 0.2.1 already notes "HTTP/3 on io_uring slightly behind".
7. **A task per request** for non-`noWait` routes, and a stream pool of 64 per endpoint (it was 256), so pools churn.

**Fixes to try first (cheap):**
- `settings.ack_thresh = 1`, so the ACK rides on the response;
- advertise a smaller `max_ack_delay` (e.g. 5 ms);
- `max_streams_bidi` 256–1000, extending credit when the FIN is *sent*;
- no hold when nothing is pending, or hold only for routes that answer in under 1 ms;
- pad only Initial / PMTU probes;
- 64 KB GSO rounds;
- 4–8 MB socket buffers;
- export the drop counters.

**Then confirm** by running `h2load --alpn-list=h3 -c1 -m64 --qlog-file-base=…` against a server built with qlog on. Look for late ACKs, MAX_STREAMS timing, PTOs and cwnd.

---

### K12: Memory-first defaults that cost CPU on every request

Each of these is a deliberate, well-documented memory win, but together they put several extra steps on every request:

| Default | Where | Per-request cost |
|---|---|---|
| `request.keep_buffers_between_requests = false` | `config.zig:487` | Gives the pooled request set back and takes it again on every keep-alive request; copies the head from the 1 KiB stack `idle_read_buffer` into the pooled buffer (`server.zig:374,2618,2675-2683`) |
| The write buffer goes back after every response | `server.zig:3017` | Pool push and pop, and cold buffer lines on every response |
| TLS reads into a **1 KiB stash** | `dusty_tls.zig:57` | More `recv`s for anything bigger than a small request |
| `MADV_DONTNEED` on trimmed sets/buffers, 5 s trim | `request_buffers.zig` | Page-fault storms after bursts (latency-500k) |
| 256 KiB committed stack per connection | `src/server.zig:286,1023` | Cache and TLB pressure at 32K connections |

**Fix:** add a performance profile (`deployment`/`environment` already exist) that keeps buffers attached to busy connections, uses 16 KiB reads, and trims lazily. Or apply those automatically while a connection is busy, by request count or a recent-activity bit. That gives you memory frugality when idle and speed when loaded.

---

### K13: Response heads cost more than they should

**Measured:** the baseline response is 112 B. zix's is 61 B, and minima-sync and dusty send no Date header at all.

```
HTTP/1.1 200 OK
Date: Fri, 23 Oct 2026 18:35:43 GMT
Content-Type: text/plain; charset=UTF-8
Content-Length: 2
```

**[Code]:** `sendHeader` (`response.zig:1848-1905`) and `write()` (`response.zig:1911-1975`) between them do linear `headers.get` scans for:
- `Date`, `Content-Type` (twice), `Content-Length` (twice);
- `Content-Encoding`, `Content-Range`, `Vary`, `ETag`.

Then the header table is iterated, with every key and value written separately through the writer vtable.
- On h2 every header name is lower-cased into a new arena allocation (`h2.zig` `head`/`lowerName`).
- On gRPC the trailers are built per call.

**Fixes:**
- Keep a small bitset of "headers the handler set" so most `get` scans vanish.
- Use a prebuilt head template per (status, content type), with Content-Length patched in (minima, zix).
- Keep Date (RFC 9110 wants it), but it's already cached per second, so put the whole `Date: …\r\n` line in the template.
- On h2, cache HPACK blocks for the common header triples (zix's `respHeaderBlock`).
- Make `.text` emit `text/plain` without the charset, as the leaders do (optional).

---

## 3. Things that are fine (so you don't chase them)

- **llhttp parsing.** Not a factor at these sizes.
- **The router.** It never showed up.
- **BoringSSL record handling:** JSON over TLS on h1 is **16.4 µs/req** locally, which is reasonable. The arena's json-tls p99 (1.88 s) looks like K5 (imbalance after the handshake ramp), not crypto.
- **The h3 transport skeleton** (REUSEPORT + CBPF, GRO, GSO, sendmmsg). It matches agensio and cnetmod; the problems are protocol timing and per-request costs (K11).
- **WebSocket.** It's 5–15% behind the leaders and already batches. Some of K8, K9 and K10 apply there too.
- **The "standard"-tier peers on json-comp:** aegon and dusty both compress per request, so per-request compression isn't the problem. Brotli q5, encoder setup and K5 are.

---

## 4. A suggested order of attack

1. **Day 1–2 (huge wins, small diffs):**
   - **K1**: size h2 body queues to need; no raise for complete or small bodies; big buffers from a per-executor pool.
   - **K3**: cork HTTP/1.1.
   - **K4**: CPU-aware codec choice on a tie, reused gzip/zstd contexts.
   - **K5**: run the arena entry with `socket_per_acceptor` on, if standard-mode rules allow it (see Q1), and check per-executor gauges.
2. **Week 1:**
   - **K2**: per-executor large-block cache as the backing for all arenas, or mimalloc.
   - **K6.1**: unary gRPC fast path.
   - **K7**: static cache.
   - **K9**: shard the `busy` counter.
   - **K11** quick knobs, plus a qlog session.
3. **Week 2+:**
   - **K6** engine restructure (inline writer, no-copy DATA, targeted wakes).
   - **K8** zio fast paths (send-first, no-park-on-inline, multishot recv, adaptive waits).
   - **K10** lazy deadlines / timer wheel.
   - **K12** performance profile.
   - **K13** templates.
4. **Re-pin the arena entry** to the new tag; it's still on v0.1.2.

**Tooling worth adding (cheap, permanent):**
- `/metrics` counters for `mmap` calls, io_uring SQEs per tick, the engine in use, and per-executor connection counts.
- A CI micro-bench that asserts **SQE/req** and **mmap/req** budgets per profile (for example pipelined ≤ 0.2, grpc mmap ≤ 0.001). Those are box-independent, so they catch regressions without a 64-core machine.

---

## 5. Questions for you (design decisions that change the fixes)

1. **Standard-mode rules.** HttpArena's anole entry promises "documented APIs and default settings".
   - Do fixes have to land as **defaults**? That affects K4 (codec on a tie), K5 (`socket_per_acceptor`) and K12.
   - Or may the entry set documented options (`.response.brotli_quality`, `.http2.stream_window`, listener options)?
2. **Memory vs throughput.** Most of K1, K2 and K12 come from deliberate memory-frugality choices (pooled-on-demand buffers, trims, small stashes).
   - Is low idle memory per connection a hard product goal?
   - Would you accept a load-adaptive design (keep buffers while busy, shed when idle), or an explicit performance profile?
3. **Allocator.** Are you open to bundling **mimalloc** (or similar) as the process `malloc`, given the "Zig compiles every C dependency, install nothing" promise? Or would you rather keep SmpAllocator and build per-executor caches around it?
4. **The zio fork.** How far are you willing to diverge from upstream lalinsky/zio (send fast path, no-park-on-inline, multishot recv, a timer wheel, a `Futex.wake` fast path)? Should those go upstream first?
5. **The HTTP/2 engine.** Is the "a handler may block, so every stream gets a task" model sacred?
   - An aegon-style engine (inline by default, a task only when a handler actually blocks) changes semantics for non-`noWait` routes.
   - Is replacing nghttp2 on the server hot path an option at all, long term?
6. **gRPC.** Is it acceptable for unary gRPC to bypass the general `Response` streaming machinery (a dedicated fast path)?
7. **Caching.** In-memory static caching (K7) is standard practice and allowed for every tier. Would caching JSON responses via the response-cache middleware be acceptable to you and to the arena rules? (vanilla does it as an engine-tier entry.)
8. **Benchmark access.** Can you get a run on the 64-core box (or any 32+ core machine) with `perf record -g`, `perf sched` / off-CPU profiles, and `/metrics` scrapes? That would settle K2 (the mmap_lock magnitude), K5 (imbalance) and K9 in an hour.
9. **Priorities.** Which profiles matter most to you: the composite score, gRPC/h3 credibility, or latency/efficiency (latency-1m/10k)? The order in §4 assumes the composite score.

---

## Appendix A: Local measurement log (anole HEAD, 4-core VM, loader on the same box)

| Test | Tool | rps | **CPU/req** | **SQE/req** | mmap/req | Notes |
|---|---|---|---|---|---|---|
| h1 baseline, 64 conns | wrk | 210K | 8.9 µs | 2.00 | ~0 | |
| h1 baseline, 1000 conns | wrk | 195K | 11.1 µs | 2.00 | | |
| h1 pipelined ×16 | wrk + lua | 462K | – | **1.06** | ~0 | ideal 0.125 |
| `/json/50`, identity | wrk | 79K | 34.6 µs | 2.00 | 0 | |
| `/json/50`, gzip | wrk | 39K | 88 µs | 2.00 | 0.001 | |
| `/json/50`, gzip, br | wrk | 19.4K | 188 µs | 2.00 | 0.0015 | Brotli q5 |
| same, 1 in 25 `Connection: close` | wrk + lua | 18.4K | 184 µs | 2.07 | | |
| `/delay/10`, 1000 conns | wrk | 85K | 17.1 µs | 2.01 | | avg 11.5 ms |
| h2c baseline `-m100` | h2load | 634K | 3.9 µs | 0.02 | 0.0001 | |
| h2 TLS baseline `-m100` | h2load | 540K | 4.5 µs | 0.03 | | |
| h2c JSON rotation `-m32` | h2load | 112K | 21.9 µs | 0.125 | **0.029** | `BodyBuffer.nextSegment` |
| gRPC GetSum `-m100` | h2load | 32.5K | **55 µs** | 0.04 | **0.71** | avg **48.6 ms** |
| gRPC GetSum `-m1` | h2load | 103K | 18 µs | 2.0 | | avg 0.12 ms |
| gRPC `-m100`, `stream_window_reading` = 64 KiB | h2load | 32K | 57 µs | 0.04 | **0.72** | 100 KB maps from `onDataChunk` remain |
| static `app.js` (br) over h1 TLS | wrk | 36.8K | **61 µs** | **13.0** | | |
| static rotation over h2 TLS `-m32` | h2load | 35.9K | **80 µs** | **8.1** | 0.04 | |
| `/json/10` over h1 TLS | wrk | 126K | 16.4 µs | 2.0 | | |

Stack traces of the `mmap` sites (`strace -k`):
- gRPC: `ArenaAllocator.alloc ← Engine.onDataChunk ← nghttp2_session_mem_recv2` (102,400-byte maps), and `ArenaAllocator.alloc ← BodyReader.streamFn ← grpc.frame.readMessage` (1,581,056-byte maps).
- json-h2c: `ArenaAllocator.alloc ← response.BodyBuffer.nextSegment ← BodyWriter.drain`.

## Appendix B: Leader techniques reference

| Technique | Who | Where |
|---|---|---|
| Parse the whole buffer → one send per read (h1) | zix, minima-sync, zeemo, aegon, vanilla, uWS (cork/uncork) | `zix/.../dispatch/uring.zig:993-1175`, `minima-sync/Program.cs:235-259`, `uWebSockets HttpContext.h:142,287` |
| Inline h2 handlers + one gathered write | aegon (nghttp2), cnetmod, h2o, vanilla, zix | `Aegon/.../Http2Connection.cpp:582-700`, `h2o/lib/http2/connection.c:461-467,1579-1594` |
| TLS-record-sized h2 DATA, 64 KB cycles | agensio | `agensio/src/http2/writer.hpp:52-62` |
| Thread-local reused compressor, cheap level | aegon (libdeflate-1), cnetmod (zlib reset / br q2), zix (fixed Huffman) | `Aegon/.../Compress.h`, `cnetmod/.../http_compress.cpp:264-340` |
| Precompressed static files in memory, kTLS + sendfile | fib, agensio, vanilla, ioxide, zix-h2 | `vanilla/.../tls_conn_linux.c.v:12-22` |
| Precomputed HPACK for gRPC headers/trailers | vanilla, zix | `vanilla-epoll/main.v:1568-1580` |
| One WINDOW_UPDATE per batch | cnetmod, vanilla | `cnetmod/.../session.cpp:815-818` |
| Per-core REUSEPORT + pinned threads, multishot accept | zix, aegon, zeemo, cardigan, h2o | |
| Adaptive CQE wait batching, SO_BUSY_POLL | zix | `zix/.../uring.zig:1465-1493,766-767` |
| mimalloc | cnetmod, agensio | `cnetmod/CMakeLists.txt:42` |
| Custom QUIC with GSO/GRO + CID steering | zix, agensio, cnetmod (anole already has the transport side) | `agensio/src/quic/udp.hpp` |
