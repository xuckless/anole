# Flame-graph atlas, S2 scenarios: the "before" picture (v0.4.1)

This is the atlas TODO.md asks for before S2 ("Flame-graph atlas before S2"), limited by the user to the scenarios S2 work will touch.
- For each scenario and backend there are three flame graphs (CPU, off-CPU, memory), a fixed-count instructions per request column (D19), and RSS over time.
- The S2 "after" runs reuse `bench/atlas/atlas.sh` with the same app and cells, and compare against these numbers.

| | |
|---|---|
| Anole | v0.4.1, c36cca0 (`c36cca065f4784c00f3c4fc6f6979a51fad6fd16`) |
| Image | `anole-bench/anole:atlas`: the bench app overlaid on a `git archive` of c36cca0, built ReleaseFast with `-Dcpu=baseline` |
| Binary SHA-256 | `bfb5d541…e988b1` (anole-bench), `4de5fc88…cf268` (grpc-interop-server) |
| Key file | [atlas/key.txt](atlas/key.txt): kernel 7.2.9, i7-14700F (microcode 0x133), governor performance, nmi_watchdog 1, tool versions |
| Tables | [atlas/summary.md](atlas/summary.md) (every column), [atlas/index.json](atlas/index.json) |
| Page | https://claude.ai/artifact/WLyqU3bQqgeYL6PuUiGqdL (every flame graph by scenario, with its top-5 symbols; built by `bench/atlas/atlas-page.py` into [atlas/index.html](atlas/index.html)) |

**Deviation from "bench apps unchanged"** (also in key.txt): the bench app gains `src/arena.zig`, copied from our HttpArena entry.
- It adds `/json/:count` with `res.compress` and a precompressed `/static`, enabled by `ARENA_DATA`.
- No existing route compresses, so #101 and #102 could not be profiled without them.
- Existing routes are unchanged. The lead approved it, and it stays in the app for the "after" runs.

## Method

`bench/atlas/atlas.sh`. One fresh server per cell and backend, with one executor on cpu 2 (sibling idle), `--cpus 1`, 2 GB. The load runs on cpus 8-15,20-27. Each cell goes through these phases in order:

1. **Warm-up:** N/10 requests, not counted. Then a 70 s rest.
2. **Count (D19):** `perf stat -a -C 2 -G <the server's cgroup>` for the whole of an `h2load -n N` at saturation.
   - Events: `cpu_core` instructions:u, cycles:u, instructions:k, page faults, context switches.
   - Every event reported 100.00% run time (no multiplexing) in every cell, and every request returned 2xx.
   - This count's rate is the cell's **max req/s**: a single rested pass, so it is a rate figure, not an A/B.
3. **CPU:** at 60% of that max, `perf record -F 999 -g` (frame pointers) on the cgroup for 15 s, then `offcputime -f` (bcc, all threads) for 10 s.
4. **Memory:** at a low fixed rate (5% of the max, at most 20k req/s), bpftrace for 10 s, with ustacks on:
   - the libc allocators (`malloc`, `calloc`, `realloc`);
   - Anole's request arena (`heap.ArenaAllocator.alloc`), `block_cache`, the page allocator and `mmap`/`brk`;
   - acquisitions from the task, stack and request-buffer pools (counted, not sized);
   - malloc bytes still live at the window's end.

   Per-request bytes divide by the window's requests (rate × 10 s); the SSE cells divide by subscribers.
5. **RSS:** `memory.current` and VmRSS every second for the server's life.

Cells (HttpArena's request shapes where it has one):

| cell | S2 item | load |
|---|---|---|
| h1-plain, h1-json | baseline, #103 | h2load `--h1` c256 |
| h1-json-noconsole | #103 | as h1-json, `ANOLE_CONSOLE=0` |
| h1-jsoncomp-{gzip,br,zstd} | #101, K4 | `--h1` c256, `/json/50?m=6`, one Accept-Encoding each (keep-alive; HttpArena also reconnects every 25 requests) |
| tls-h1-json | #130 | TLS `--h1` c256 |
| h2c-json-m10, -m64 | HTTP/2 takeover | c256, m10 / m64 |
| h2-static | #102, K7 | TLS h2 c64 m32, HttpArena's 20 static URIs, `Accept-Encoding: br, gzip` |
| h3-json, h3-static, h3-post | #100, #151, H3-A | c64; m10 / m64 static / m10 POST of 16 KiB to `/echo` |
| grpc-unary | #99 | the interop server's `UnaryCall` over h2c, HttpArena's 9-byte body, c256 m100 |
| sse-h1, sse-h2c | #97 | 4,000 `/sse` subscribers held open (memory only) |
| net-tcp | #147 | tcpload 64 B × 256 (saturating; counted over a 10 s window) |

## Results (epoll / io_uring)

| cell | max req/s | ins:u/req | ins:k/req | peak RSS MB | biggest cost |
|---|---:|---:|---:|---:|---|
| h1-plain | 220k / 241k | 8,346 / 8,209 | 31k | 11 | kernel: netfilter 35-37%, net 20% |
| h1-json | 222k / 239k | 9,243 / 9,100 | 31k | 11 | the same |
| h1-json-noconsole | 222k / 239k | 9,242 / 9,102 | 31k | 10 | the same |
| h1-jsoncomp-gzip | 25.1k / 25.4k | 741,742 / 741,638 | 32k | 19 | zlib-ng 50%, JSON encode 23% |
| h1-jsoncomp-br | 12.7k / 12.7k | 1,369,642 / 1,369,774 | 33k | 22 | Brotli 71% (`CreateBackwardReferencesNH40` 48%) |
| h1-jsoncomp-zstd | 23.1k / 23.7k | 524,378 / 524,285 | 32k | 80 | memset 27/18% (`ZSTD_reset_matchState`), zstd 28-33% |
| tls-h1-json | 193k / 209k | 16,251 / 16,055 | 31k | 17 | netfilter 31-34%, BoringSSL 8% |
| h2c-json-m10 | 543k / 664k | 16,867 / 16,893 | 3.2k | 39 | nghttp2 18-19%, h2 glue 14-16%, arena 11-12% |
| h2c-json-m64 | 557k / 578k | 19,287 / 19,413 | 1.0k | 96 | nghttp2 22%, h2 glue 16-17%, arena 13-14% |
| h2-static | 35.0k / 47.4k | 81,540 / 78,463 | 105k / 38k | 208 | memcpy 8/14%; epoll: blocking-pool file reads, 11 context switches/req |
| h3-json | 347k / 361k | 30,174 / 29,570 | 5.0k | 43 | nghttp3 21%, h3 glue 15%, ngtcp2 13% |
| h3-static | 27.6k / 40.3k | 157,432 / 155,573 | 183k / 71k | 200 | spread out; epoll: blocking-pool file reads, 19 context switches/req |
| h3-post | 40.2k / 40.0k | 230,381 / 231,496 | 53k | 47 | ngtcp2 20-21%, BoringSSL 13%, memcpy 8% |
| grpc-unary | 318k / 322k | 34,761 / 34,820 | 1.2k | 839 / 952 | nghttp2 21%, h2 glue 15-16%, arena 10-11% |
| sse-h1 | (4,000 subs) | | | 93 / 83 (settles at 25 / 26) | ≈ 4.7-5.0 KB settled RSS per subscriber |
| sse-h2c | (4,000 subs) | | | 211 / 200 (settles at 206 / 194) | ≈ 48-51 KB settled RSS per subscriber |
| net-tcp | 264k / 244k msg/s | 2,099 / 1,664 | 31k | 11 | kernel: netfilter 39-43% |

## Findings by S2 item

These are leads from one pass. The S2 work on each item verifies them (profile, then A/B, per AGENTS.md).

### #101 json-comp, K4: the encoder is rebuilt per response, at high levels

| codec | per request | CPU | what to change |
|---|---|---|---|
| gzip | 296 KB from `block_cache` (`deflateInit2` → `zalloc`) | `longest_match_avx2` 17%, `insert_string` 9% | the deflate level suggests 6 or more; a low level and a reused `z_stream` per executor |
| br | 109 KB malloc (`BrotliAllocate` under `BrotliStoreMetaBlock`, `EncodeData`, `BuildMetaBlockGreedy`) | `CreateBackwardReferencesNH40` 48% | quality around 5-9 by its hasher; quality 1-4 for dynamic bodies, encoder reuse |
| zstd | 480 KB malloc + 290 KB arena (`ZSTD_resetCCtx_internal`); `ZSTD_createCCtx_advanced` from `zstd_io.Compress.init` on every `Response.write` | memset 20% under `ZSTD_reset_matchState` | one `ZSTD_CCtx` per executor |

- Every codec also takes 24 KB malloc per request in `response.BodyBuffer.nextSegment` and 12 KB malloc in `handlers.adapt` (the JSON body).
- JSON encoding (`json.Stringify.encodeJsonString`) is 9-11% of CPU.

### #99 gRPC unary: about 110 KB allocated per call, and RSS near 1 GB

- **Per call** (9-byte request, 2-byte reply): 48 KB arena + 44 KB malloc in `nghttp2_session_mem_recv2 → h2.Engine.onDataChunk`, and 12 KB arena in `grpc.server.writeBytes`. The body buffer looks sized by a window or frame limit rather than by the message.
- **Held:** each stream's arena is kept at its high-water mark after `Stream.release → ArenaAllocator.reset`. At least 205-230 MB was held (a lower bound, see Limits), and RSS reached 839 MB (epoll) and 952 MB (io_uring) at 25,600 streams in flight.
- **CPU:** nghttp2 21% (`nghttp2_hd_huff_decode` 3.4%: Huffman-coded request headers on every call), h2 glue 15%, arena 10-11%.
- **Cross-thread wakes:** `sync.Futex.wake` is 2.9% on io_uring, from `h2.Engine.onFrameRecv`, `Stream.release`, `StreamSink.end` and `flushFn`.
- **Rate:** 318k calls/s on one executor, above #99's 76k on about 3 cores. HttpArena's rate is not reproduced here: different service, client and core count.

### HTTP/2 takeover (M0-M6): the baseline the 25% gate measures against

- **h2c json, user instructions per request:** 16,867 at m10 and 19,287 at m64. h1 json is 9,243.
- **Where the CPU goes:** nghttp2 18-22%, Anole's h2 glue 14-17%, the arena allocator 11-14%.
  - Arena callers (h2c m10, io_uring): `h2.Engine.onHeader` 3.4%, `serveStream` 2.3%, `Response.completeSink` 1.1%, `StreamSink.head` 0.9%, and an `allocPrint` in `StreamSink.head` 0.9%.
  - Arena bytes are small (2.7 KB/req); the cost is the call count, about 16 calls per request.
- **m64 does more work than m10:** about 2.4k more user instructions per request, and 578k against 664k req/s on io_uring.
- **h2 static (#102):** the body is copied at least three times.
  1. `StreamSink.put → Io.TypeErasedQueue.putLocked` (4.2%)
  2. `provideData → Queue.getUncancelable` (3.0%)
  3. `dusty_tls.bioWrite` under `BIO_write_ex` (3.0%)

  The response also takes 41 KB arena per request in `Response.write`, plus 10.5 KB malloc from BoringSSL's `tls_write_app_data`.
- **#97 (idle HTTP/2 tasks):** an h2c SSE subscriber costs 4 task-pool slots and 3 coroutine stacks, against 2 and 2 over h1.
  - That is about 2.6 MB of stack mmap, against 1.6 MB over h1.
  - Settled RSS, after the connection ramp, is 48-51 KB per subscriber over h2c against 4.7-5.0 KB over h1, about 10 times more.
  - Over h1 the ramp's memory comes back within about 10 s (93 MB falls to 25 MB). Over h2c it stays (206 MB).
  - An earlier draft of this note said 20 KB for h1: that was the ramp's peak, not the held figure.
  - The extra stacks come from `h2.Engine.startStream` (1.4 MB of mmap per subscriber) and the connection's `serve` writer.

### #100 / H3: nghttp3 crosses its takeover trigger

- **The nghttp3 trigger** (≥15% CPU): it is 20.5-21.2% of h3-json. nghttp3's own leaf symbols alone are 19.1-19.7%.
- **The memcpy trigger** (≥8%): it is 8.0-8.2% of h3-post, all callers combined:
  - `h3.bridge.RecvQueue.take` and `RecvQueue.append`;
  - `SendQueue.write`;
  - `ngtcp2_cpymem` in `ngtcp2_pkt_encode_stream_frame`.
- AGENTS.md makes these the triggers for an nghttp3 takeover. The lead decides.
- **Packet path:** the server already batches with `sendmmsg` and GSO (`__x64_sys_sendmmsg`, `udp_send_skb` in every h3 stack). The packet path is not the h3-static gap.
- **h3-static:**
  - 156k user instructions per request with a flat profile: ngtcp2 10-14%, BoringSSL 6-8%, nghttp3 6-8%, memcpy 3-6%.
  - On epoll, file reads go to the blocking pool (59% of off-CPU time is its futex wait, 19 context switches per request), so kernel instructions are 183k per request against 71k on io_uring.
- **Per-stream malloc in h3-json:** 6.7 KB per request in `Endpoint.onStreamClose → Stream.free`, plus 4.6 KB in `StreamSink.body`.
- **About 4.5-6.8% unresolved samples ('?')** in h3 sit directly under the thread, with no frames. They are likely C code that reached perf without a frame-pointer chain.

### #102 / K7 static: file I/O per request

- On epoll, both static cells hand file opens and reads to the blocking pool (`ev.thread_pool.ThreadPool.submit`): 11 (h2) and 19 (h3) context switches per request. io_uring avoids most of it: 0.2-0.3 context switches and 35-46% more requests per second.
- A file cache (K7) would remove both the reads and the per-request arena copies.

### #130 TLS h1

- TLS h1 json runs at 87% of cleartext's rate on one core (193k against 222k on epoll; 209k against 239k on io_uring), adding about 7k user instructions per request.
- BoringSSL is 8% of CPU. On this workload TLS h1 is not the problem #130's numbers from the video-call relay suggested.
- The one allocation: `dusty_tls.bioWrite` / `ssl_write_buffer_flush` mallocs per write, 1.2 KB per request on epoll and 4.9 KB on io_uring. A pooled BIO buffer would remove it.

### #103 console

- With the console on against off: 9,243 against 9,242 user instructions per request on epoll, 9,100 against 9,102 on io_uring, and the same rate.
- So on this binary the console adds nothing measurable per request on h1, below D19's 0.3% threshold.
- The idle console's own thread (the `poll` wait in the off-CPU graphs) does not show in the CPU profile. #103's HTTP/3 claim was not re-checked here.

### #147 / raw TCP

- 1.7-2.1k user instructions per 64-byte message, no allocation, no page faults: user space is lean.
- Netfilter is 39-43% of the server's CPU, the largest single cost in every h1 and TCP cell. That is the dilution D19 warned about: loopback numbers understate user-space wins.
- The second `recvfrom` per message (#147) is not visible in a sampled profile. It needs a syscall count (`perf trace -s`) in its own A/B.

## Limits

- **One pass per cell.** Max req/s is a single rested run, not a comparison.
- **D19 omissions:** the count has no idle-term calibration and no repeatability proof (D19 §5). It is the reference for the "after" runs, which should prove repeatability once before comparing.
- **Memory window:** at 5% load with uprobes on every malloc and arena allocation, those probes slow the server. Bytes and calls per request are exact for the window; timing there is not.
- **"Held" figures are lower bounds** in the cells marked ≥ in summary.md (the h2c, gRPC, h3-json and SSE cells): bpftrace's live map filled at 4,096 entries. The allocated-bytes maps did not overflow. `atlas.sh` now raises the limit for the "after" runs.
- **gRPC uses the interop server,** not HttpArena's `GetSum` service: the same h2 and gRPC core, a different binary. Its thread is named `grpc-interop-se`.
- **json-comp keeps connections alive.** HttpArena's json-comp also reconnects every 25 requests (#101's 14k reconnects), which this cell does not exercise.

## Files

- `atlas/<backend>/<cell>/` holds:
  - flame graphs: `cpu.svg`, `offcpu.svg`, `mem-alloc.svg`, `mem-held.svg`;
  - `summary.json`, `count.perf.csv` + `count.txt` (D19), `perf-script.txt.gz` (raw) + `cpu.folded.gz`, `offcpu.folded`;
  - `mem.txt.gz` (bpftrace maps), `mem.bt`, `rss.tsv` (epoch, memory.current, VmRSS kB, threads);
  - the load outputs, `server.log`, `state`, `backend`.
- `atlas/run.log`: every cell, with times.
- Tooling: `bench/atlas/atlas.sh`, `bench/atlas/atlas-summary.py`, `bench/atlas/Dockerfile.tools` (`anole-bench/atlas-tools`: Fedora 44 perf, bpftrace, bcc, h2load), `bench/lib/key.sh`.
