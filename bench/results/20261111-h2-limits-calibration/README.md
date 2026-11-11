# HTTP/2 flood-budget calibration against real clients (2026-11-11)

Evidence for PLAN section 5.4 / TODO.md 3a D15 point 5: what do real HTTP/2 clients send, per connection and
per second at peak, before M2 freezes the budgets in `src/http/core/h2/limits.zig` and `config.zig`.
This is counting, not benchmarking: no throughput or latency numbers are reported, scenarios are short
(each under a minute), and `limits.zig` / `config.zig` are untouched; the lead applies any change.

## Method

- **Tool:** `tools/h2count` (Go standard library, 9-byte frame header parsed by hand, written from RFC 9113
  section 4.1 and 6; nothing copied). A TLS-terminating (ALPN `h2`, self-signed ECDSA cert) and h2c
  prior-knowledge TCP proxy that forwards every byte unchanged to the upstream h2c server and counts
  client-to-server frames per connection, with a 1 s sliding peak (ten 100 ms buckets, so a window is 0.9
  to 1.0 s and a peak can under-count by at most one bucket). Server-to-client frames are parsed only to
  follow stream state: peak concurrent streams, and "unanswered" RST_STREAM (the stream had not yet seen
  END_STREAM from the server on the wire; the engine's own notion is "END_STREAM queued", so the proxy can
  over-count, which only makes recommendations conservative). No HPACK decoder: header blocks are
  reported as encoded bytes.
- **Upstream:** `tools/h2count/site` (`zig build h2count-site`) on main at 3e6d54a8, i.e. the current nghttp2
  engine, Debug build: `/` with 100 subresources, `/download` (64 MiB generated), `POST /upload`, `/sse`
  (event every 100 ms), `/slow` (2 s), and `/drive?s=...`, a page whose script makes a browser reload, cancel,
  stream and upload. gRPC is `examples/grpc` (h2c) behind a second proxy listener.
- **Driver:** `tools/h2count/scenarios/run.sh` (one scenario per client, label per scenario via the
  proxy's control port). Raw reports: `raw/*/h2count.json` (per connection, every counter with its total, peak
  per second and peak per 100 ms), plus run and proxy logs. `scenarios/summarize.py` builds the tables below.
- **Caveats.** The proxy is a hop (TCP_NODELAY on both legs), so protocol-level counts are exact but rates may
  differ a little from an unproxied connection. Browsers are headless on a temporary profile (never the
  user's), scripted by a page, not by a human; real pages (500 subresources, mobile reconnect storms,
  long-lived tabs) are more intense, which the headroom factors below must cover. Every row is one run.
  Per-connection peaks are rolled up as the maximum over the scenario's connections, because each budget is
  per connection.

## Clients

| client | version | how it was driven |
|---|---|---|
| Chromium | 156.0.8078.79 (Fedora), `--headless=new`, temp profile, `--ignore-certificate-errors` | `/drive` page: load, 30 reloads cut off after 20-120 ms, 8 aborted downloads and 40 aborted `/slow`, 3 SSE, 16 MiB upload, 64 MiB download, navigate away during a download |
| Firefox | 159.0, headless, temp profile; certificate accepted through WebDriver BiDi `acceptInsecureCerts` | the same `/drive` scenarios |
| curl | 8.18.0 (nghttp2 1.68.0) | `-Z` with 100 URLs (TLS and h2c), aborted downloads (`--max-time 1`, also 20 in parallel), 16 MiB upload, SSE, a 30 KB header |
| Node http2 | v22.23.1 | 100 concurrent GETs, 64 MiB download, 20 streams cancelled with RST(CANCEL), 16 MiB upload; 50 `session.ping()` as a labelled tool-driven row |
| grpc-go | v1.85.0 (Go 1.26.7), hand-rolled codec, no protoc | 1000 unary calls from 50 goroutines on one connection, then 20 calls cut off by a 100 ms deadline on `slow` |
| Envoy | v1.34.1, `envoyproxy/envoy@sha256:007da57c2c328a90bd4e6d99b70bd899132f1b4a9426ccafe25437cf84a60c14` | HTTP/1.1 in, h2c cluster out through the proxy; 100 requests, 10 aborted downloads, a 12 s stream; default config and `connection_keepalive` 5 s |
| h2load | nghttp2 1.59.0, image `sha256:707ee08cd492dc4a2ec35c6b9c556ee21a007838aa9a61b8f0f9d16ab00d7b49` (local `h2load:latest`) | `-n 2000 -c 4 -m 100` over TLS; **synthetic** row: a load tool, not used to set any ceiling |
| (hand-built) | `scenarios/rawcont.mjs` | header blocks split over CONTINUATION frames, to see where the server stops (curl and Node refuse to send a header list larger than the server allows) |

Containers were started with `--name h2count-*` and removed by name; nothing was pruned. Skipped: nothing.
(`envoy` and `h2load` were run through Docker with `--network host`.)

## Per-client peaks

Columns are maxima over the scenario's connections: `streams` peak concurrent streams, `req/s` HEADERS opening a
stream, `PING` non-ACK PINGs (per second, and total), `SETT frames` SETTINGS frames (non-ACK) per
connection, `ent/frame` SETTINGS entries in one frame, `RST` client RST_STREAM per second / per 100 ms,
`RST unans.` per connection total for streams not yet answered, `empty *` frames with an empty payload and no
END_STREAM, `unknown` frame types above 9, `CONT/blk` CONTINUATION frames in one header block, `hdr blk B` the
largest HPACK-encoded block, `WU/s` WINDOW_UPDATE, `PRIO` PRIORITY frames (per second / total).
`PING`, `RST` etc. are client to server only.

| scenario | conns | streams | req/s | PING/s | PING tot | SETT frames | ent/frame | RST/s | RST/100ms | RST unans. | empty DATA | empty HDR | empty CONT | unknown | CONT/blk | hdr blk B | WU/s | PRIO/s | PRIO tot |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| chromium-load | 3 | 99 | 202 | 0 | 0 | 1 | 4 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 457 | 1 | 117 | 117 |
| chromium-reload | 3 | 100 | 1515 | 0 | 0 | 1 | 4 | 20 | 20 | 8 | 0 | 0 | 0 | 0 | 0 | 460 | 1 | 956 | 1354 |
| chromium-abort | 2 | 49 | 50 | 0 | 0 | 1 | 4 | 48 | 29 | 48 | 0 | 0 | 0 | 0 | 0 | 444 | 1 | 0 | 0 |
| chromium-sse | 2 | 4 | 5 | 0 | 0 | 1 | 4 | 3 | 3 | 3 | 0 | 0 | 0 | 0 | 0 | 442 | 1 | 0 | 0 |
| chromium-upload | 2 | 1 | 3 | 0 | 0 | 1 | 4 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 445 | 1 | 0 | 0 |
| chromium-download | 2 | 2 | 3 | 0 | 0 | 1 | 4 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 446 | 30 | 0 | 0 |
| chromium-nav | 3 | 2 | 3 | 0 | 0 | 1 | 4 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 459 | 30 | 0 | 0 |
| curl-load-tls | 1 | 100 | 100 | 0 | 0 | 1 | 3 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 38 | 201 | 0 | 0 |
| curl-load-h2c | 1 | 99 | 100 | 0 | 0 | 1 | 3 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 38 | 201 | 0 | 0 |
| curl-abort | 4 | 20 | 20 | 0 | 0 | 1 | 3 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 41 | 163 | 0 | 0 |
| curl-upload | 1 | 1 | 1 | 0 | 0 | 1 | 3 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 72 | 3 | 0 | 0 |
| curl-sse | 1 | 1 | 1 | 0 | 0 | 1 | 3 | 1 | 1 | 1 | 0 | 0 | 0 | 0 | 0 | 35 | 3 | 0 | 0 |
| curl-header-30k | 1 | 1 | 1 | 0 | 0 | 1 | 3 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 24052 | 3 | 0 | 0 |
| curl-header-200k | 1 | 0 | 0 | 0 | 0 | 1 | 3 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 0 | 0 |
| raw-continuation | 7 | 1 | 1 | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 20 | 71705 | 0 | 0 | 0 |
| node-page | 1 | 100 | 100 | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 23 | 0 | 0 | 0 |
| node-download | 1 | 1 | 1 | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 24 | 4096 | 0 | 0 |
| node-cancel | 1 | 20 | 20 | 0 | 0 | 1 | 0 | 20 | 20 | 20 | 0 | 0 | 0 | 0 | 0 | 24 | 158 | 0 | 0 |
| node-upload | 1 | 1 | 1 | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 22 | 0 | 0 | 0 |
| node-ping-tool-driven | 1 | 0 | 0 | 50 | 50 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| grpc-go | 1 | 50 | 1020 | 36 | 36 | 1 | 0 | 19 | 19 | 19 | 0 | 0 | 0 | 0 | 0 | 94 | 36 | 0 | 0 |
| envoy-default | 25 | 8 | 10 | 1 | 2 | 1 | 5 | 1 | 1 | 1 | 0 | 0 | 0 | 0 | 0 | 97 | 2 | 0 | 0 |
| envoy-keepalive | 27 | 12 | 14 | 1 | 2 | 1 | 5 | 1 | 1 | 1 | 0 | 0 | 0 | 0 | 0 | 97 | 2 | 0 | 0 |
| h2load-synthetic | 4 | 100 | 500 | 0 | 0 | 1 | 2 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 37 | 1 | 0 | 0 |
| firefox-load | 2 | 71 | 204 | 0 | 0 | 1 | 4 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 281 | 205 | 0 | 0 |
| firefox-reload | 2 | 59 | 1515 | 0 | 0 | 1 | 4 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 283 | 1515 | 0 | 0 |
| firefox-abort | 2 | 48 | 49 | 0 | 0 | 1 | 4 | 26 | 26 | 26 | 0 | 0 | 0 | 0 | 0 | 282 | 58 | 0 | 0 |
| firefox-sse | 2 | 4 | 5 | 0 | 0 | 1 | 4 | 3 | 3 | 3 | 0 | 0 | 0 | 0 | 0 | 280 | 6 | 0 | 0 |
| firefox-upload | 1 | 1 | 3 | 0 | 0 | 1 | 4 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 283 | 4 | 0 | 0 |
| firefox-download | 1 | 1 | 3 | 0 | 0 | 1 | 4 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 284 | 35 | 0 | 0 |
| firefox-nav | 1 | 2 | 4 | 0 | 0 | 1 | 4 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 281 | 36 | 0 | 0 |

Not evidence of real-client behaviour (excluded from the maxima): `node-ping-tool-driven` (50 pings by API
call), `h2load-synthetic`, `raw-continuation` (hand-built frames) and `curl-header-200k` (curl refused to send
20 x 10 KB header fields against the server's advertised header list size: `000`, no stream).

## Highest legitimate values

| highest legitimate value (synthetic rows excluded) | value | scenario |
|---|---|---|
| PING/s | 36 | grpc-go |
| PING/100ms | 24 | grpc-go |
| SETTINGS frames per connection | 1 | node-upload |
| SETTINGS entries per frame | 5 | envoy-keepalive |
| RST_STREAM/s | 48 | chromium-abort |
| RST_STREAM/100ms | 29 | chromium-abort |
| unanswered RST_STREAM/s | 48 | chromium-abort |
| empty DATA total | 0 | node-upload |
| empty HEADERS total | 0 | node-upload |
| empty CONTINUATION total | 0 | node-upload |
| unknown frames total | 0 | node-upload |
| CONTINUATION per block | 1 | curl-header-30k |
| header block bytes | 24052 | curl-header-30k |
| WINDOW_UPDATE/s | 4096 | node-download |
| PRIORITY/s | 956 | chromium-reload |
| PRIORITY/100ms | 233 | chromium-reload |
| peak concurrent streams | 100 | node-page |
| requests/s | 1515 | firefox-reload |


Other measured facts: no client sent an unknown/extension frame, an empty DATA/HEADERS/CONTINUATION frame, or
more than one SETTINGS frame (plus ACKs) on a connection; nobody sent more than 5 SETTINGS entries (Envoy; the
browsers 4: HEADER_TABLE_SIZE, ENABLE_PUSH, INITIAL_WINDOW_SIZE and MAX_HEADER_LIST_SIZE in Chromium,
MAX_FRAME_SIZE in Firefox's place of the last; curl 3; Envoy's fifth is id 0x8, ENABLE_CONNECT_PROTOCOL). WINDOW_UPDATE per server DATA frame in sustained transfers was 1.0 at most (Firefox 1.00,
Node 1.00); curl sends 2 per tiny response (stream and connection), the highest ratio in the data (3.0 on a
one-DATA response).

## Answers to the eight questions

1. **Empty DATA / HEADERS / CONTINUATION without END_STREAM: none.** All of Chromium, Firefox, curl, Node,
   grpc-go, Envoy and h2load sent zero. `empty_frame_rate` 100/s therefore has unbounded headroom over
   legitimate traffic (Envoy's own default is 1 *consecutive* such frame, `max_consecutive_inbound_frames_with_empty_payload`).
2. **WINDOW_UPDATE:** up to 4096/s on a 64 MiB download (Node; Firefox 35/s, Chromium 30/s on the same download) and 1515/s on
   Firefox page reloads, at 1.0 per server DATA frame at most in sustained transfers (curl: 2 per tiny
   response). A flat per-second cap would need to sit above 40,000/s to keep a 10x margin, which defeats it;
   a ratio bound like Envoy's (10 WINDOW_UPDATE per DATA frame the server sent) has 3x headroom over the
   worst observed (3.0) and 10x over the sustained worst (1.0).
3. **PING:** Chromium and Firefox 0 in these scenarios; Envoy 2 in 12 s with and without a 5 s keepalive
   (default Envoy 1.34.1 also pings; kept as observed, not investigated); grpc-go **36/s, 24 in 100 ms** under a
   1000-call unary burst (BDP probes), the highest legitimate rate. The budget is the number of *queued*
   PING ACKs (1000), not a rate: 36/s fills it only if the write side stalls for 28 s, and the write timeout
   (`timeouts.write`, 30 s) closes a connection that stalled that long first.
4. **RST_STREAM:** highest 48/s (29 in 100 ms), all unanswered, Chromium aborting 40 `/slow` requests and 8
   downloads; Firefox 26/s; Node cancelling 20 streams 20/s; grpc-go deadline cuts 19/s; a 30-page-load reload
   storm only 20 RST (8 unanswered) in Chromium and 0 in Firefox. h2load aborted nothing. Against burst 1000 /
   33 per second this is 20x under the burst; sustained 48/s would exhaust the bucket in 66 s, which these
   short scenarios cannot say is normal or not.
5. **SETTINGS entries per frame:** 5 at most (Envoy), 4 for both browsers, 3 curl, 2 h2load, 0 for Node and
   grpc-go (empty initial SETTINGS); one SETTINGS frame per connection. `max_settings` 32 is 6x over the
   maximum.
6. **Unknown/extension frame types: none.** No GREASE frame and no ALTSVC/ORIGIN/PRIORITY_UPDATE from any client in
   this setup (the settings ids seen are 0x1-0x6 and 0x8 only, so no GREASE setting either). **But** see the PRIORITY
   finding below: this is with the server not advertising SETTINGS_NO_RFC7540_PRIORITIES.
7. **CONTINUATION:** 0 per block for every client except curl at 1 (a 30 KB header, 24,052 encoded bytes).
   Hand-built blocks: 7 and 8 CONTINUATION frames are answered, 9 and 20 get no answer (the engine closes the
   connection; no GOAWAY is observed on the wire), a 48 KiB header value over full frames (3 CONTINUATION) is
   answered, 70 KiB (4 CONTINUATION, 71,705 B) gets GOAWAY with error 9 (COMPRESSION_ERROR) rather than a 431.
8. **Peak concurrent streams: 100** (Node and curl `-Z` with 100 URLs, Chromium page load, h2load `-m 100`), grpc-go 50.
   `max_concurrent_streams` 250 is 2.5x over the largest load generated; clients obey the advertised value,
   so this data cannot show that 250 is high enough for a page with 500 subresources (see below).

## Findings that change something

- **Chromium sends PRIORITY frames, a lot of them: 956/s and 233 per 100 ms at peak, 1354 on one connection
  in the 30-reload scenario (117 on a plain page load).** Firefox, curl, Node, grpc-go and Envoy sent none.
  nghttp2 1.70 charges *every* PRIORITY and PRIORITY_UPDATE frame to its glitch bucket
  (`lib/nghttp2_session.c`, `session_update_glitch_ratelim` in the PRIORITY receive path: "very unpopular ... we
  do not expect it is received so frequently"), 10000 burst / 330 per second. Chromium's 956/s peak is 2.9x the
  refill rate; the 30-reload burst used 14% of the bucket, and a sustained 956/s would empty it in 16 s.
  **Recommendation: M2 must not put PRIORITY (nor PRIORITY_UPDATE) in a rate bucket.** The new engine has no
  priority tree, a PRIORITY frame costs no state and queues no output, so validating it (length 5, no
  self-dependency in the PROTOCOL_ERROR sense) is the whole job; CVE-2019-9513 was about the tree. Charging
  it would turn page reloads in the most used browser into ENHANCE_YOUR_CALM.
- **Pick `empty_frame_rate`, not the nghttp2 glitch bucket.** The data supports the narrow budget: legitimate
  empty frames are 0, so `empty_frame_rate` can stay at 100/s (even 10/s has a margin of infinity over 0; 100
  keeps room for a buggy-but-benign client), while the glitch bucket's 330/s rate is below the measured
  Chromium PRIORITY rate and mixes unrelated events. If the glitch bucket is kept for parity with nghttp2
  (the differential tests match it for free), PRIORITY has to be exempt from it, which makes it equal to
  the narrow budget anyway.
- **D15 point 2 (unknown/extension frames count as empty frames) versus D15 point 3 (send
  SETTINGS_NO_RFC7540_PRIORITIES = 1): they collide.** With the setting, RFC 9218 clients (Chromium and Firefox
  both implement it) switch from PRIORITY to PRIORITY_UPDATE (frame type 0x10), which is an *unknown type*
  for RFC 9113 and would be counted by point 2 at roughly the PRIORITY rate above (up to ~1000/s on reload
  storms). This could not be measured here (the current engine does not send the setting, so no client sent
  type 0x10) and is an inference from RFC 9218 section 2.1 and the PRIORITY numbers: **M2 should exempt
  type 0x10 (and any frame type it parses without cost) from the unknown-frame count, and re-run this
  calibration with `scenarios/run.sh chromium firefox` once the new engine advertises the setting.** Counting
  only types the engine neither parses nor ignores for free keeps the point-2 intent (CVE-2019-9518 class)
  without that trap.
- **`curl` and Node refuse to send a header list above the advertised limit**, so `max_header_list_size`
  enforcement is only reachable by a hostile or hand-built client; no real client was refused or reset by
  the current limits in any scenario.

## Budget by budget

"Legit" is the highest value in the table above (synthetic rows excluded). Rule from the research note:
a per-second rate default >= 10x the legit per-second peak, a burst default >= 4x the legit burst; a *queued*
budget is converted with legit rate x write-stall time. Attack tools send thousands per second, so anything
under about 1000/s separates the two.

| budget (PLAN 5.4 / limits.zig) | highest legit | current default | recommendation | reference values |
|---|---|---|---|---|
| `stream_reset_burst` / `_rate` (unanswered RST, D15 point 1) | 48/s, 29 per 100 ms (Chromium abort) | 1000 burst, 33/s | **keep.** Burst is 20x the peak; the rate (33/s) is below the 48/s peak, so a short abort storm is absorbed by the burst and only a minute-long 48/s stream would hit it. | nghttp2 1000 / 33; Envoy: no equivalent, `max_outbound_frames` 10000 / `max_outbound_control_frames` 1000 (queued) |
| `control_frame_budget` (queued PING ACK + SETTINGS ACK + RST) | PING 36/s (grpc-go), SETTINGS ACK 1 per connection | 1000 queued | **keep 1000.** 36/s needs a 28 s write stall to fill it, shorter than the 30 s write timeout; 10x the rate only matters for a peer that stops reading but keeps sending, which the write timeout handles. | nghttp2 `max_outbound_ack` 1000 (`NGHTTP2_DEFAULT_MAX_OBQ_FLOOD_ITEM`); Envoy 1000 control frames; Go `http2maxQueuedControlFrames` 10000 (h2_bundle.go:4047) |
| `empty_frame_rate` (empty DATA/HEADERS/CONTINUATION, plus unknown frames per D15 point 2) | 0 empty; 0 unknown (but see the PRIORITY_UPDATE finding) | 100/s | **keep 100/s; adopt it instead of the glitch bucket; exempt PRIORITY and PRIORITY_UPDATE.** | nghttp2 glitch bucket 10000 / 330 (also charges PRIORITY); Envoy `max_consecutive_inbound_frames_with_empty_payload` 1 (consecutive, not a rate) |
| `glitch_burst` / `glitch_rate` (nghttp2 parity) | PRIORITY 956/s, 1354 per connection (Chromium) | 10000 / 330 | **do not adopt as is.** Rate 330 < Chromium's PRIORITY peak 956/s. If kept for the differential tests, exempt PRIORITY and PRIORITY_UPDATE. | nghttp2 `NGHTTP2_DEFAULT_GLITCH_BURST/RATE` 10000 / 330 |
| `max_settings` (entries per SETTINGS frame) | 5 (Envoy), 4 (browsers) | 32 | **keep 32** (6x; the cost of an entry is trivial, ENHANCE_YOUR_CALM above). | nghttp2 `NGHTTP2_DEFAULT_MAX_SETTINGS` 32 |
| SETTINGS frames per second | 1 per connection | (counted through the control budget via ACKs) | **no extra rate needed**; every ACK is queued output and bounded by the control budget. | |
| `max_continuations` | 1 (curl, 24 KB block) | 8 | **keep 8.** 8x the legit; verified on the current engine: 8 answered, 9 not. | nghttp2 `NGHTTP2_DEFAULT_MAX_CONTINUATIONS` 8 |
| `max_header_list_size` | 24,052 encoded bytes (30 KB cookie-like value); all clients stayed under the advertised value | 64 KiB | **keep 64 KiB** (2.7x over the largest legit block seen). 48 KiB accepted, 70 KiB closed with COMPRESSION_ERROR. M2 should give the 431 the table promises. | not verified for other servers |
| `max_concurrent_streams` | 100 (curl `-Z`, Node, Chromium page, h2load) | 250 | **keep 250** (2.5x). No client in the set exceeded what it was offered; Go's server default is also 250, Envoy's 1024. Raise only if field data shows pages with more than ~250 parallel subresources. | Go `http2defaultMaxStreams` 250 (h2_bundle.go:4042); Envoy `max_concurrent_streams` 1024 (default in the field docs); nghttp2 unlimited by default (0xFFFFFFFF) |
| `refused_stream_burst` / `_rate` | none seen (no client exceeded the advertised limit) | 100 / 10/s | **keep**; not exercised here (clients obey `max_concurrent_streams`). | |
| WINDOW_UPDATE | 4096/s sustained, 1.0 per DATA (3.0 on tiny responses) | counted in the control budget in PLAN 5.4 | **do not count received WINDOW_UPDATE in the queued control budget** (it queues nothing; counting would trip on a 64 MiB download at 4096/s). If a cap is ever wanted, use Envoy's ratio (10 per server DATA frame), which has >= 3x headroom. | Envoy `max_inbound_window_update_frames_per_data_frame_sent` 10 |
| PRIORITY | 956/s (Chromium) | charged to the glitch bucket in nghttp2 | **ignore after validation, no budget** (see above). | Envoy `max_inbound_priority_frames_per_stream` 100 (per stream); nghttp2 charges the glitch bucket |
| PING rate (as opposed to queued ACKs) | 36/s (grpc-go) | no separate rate | **none**; bounded by the queued ACK budget. | |
| Unknown frames | 0 | counted with `empty_frame_rate` | keep counting, **with PRIORITY_UPDATE (0x10) exempt** | |

References: nghttp2 values read from the fork's `lib/nghttp2_session.h` (`NGHTTP2_DEFAULT_MAX_OBQ_FLOOD_ITEM`
1000, `STREAM_RESET_BURST` 1000 / `RATE` 33, `GLITCH_BURST` 10000 / `RATE` 330, `MAX_CONTINUATIONS` 8) and
`nghttp2_session.c` (every PRIORITY and PRIORITY_UPDATE frame goes through `session_update_glitch_ratelim`).
Go values read from this box's Go 1.26.7 `net/http/h2_bundle.go`. Envoy values are from
`envoy.config.core.v3.Http2ProtocolOptions` in api/envoy/config/core/v3/protocol.proto (fetched 2026-11-11 for
the research note; not re-read for this README): `max_outbound_frames` 10000,
`max_outbound_control_frames` 1000, `max_consecutive_inbound_frames_with_empty_payload` 1,
`max_inbound_priority_frames_per_stream` 100, `max_inbound_window_update_frames_per_data_frame_sent` 10,
`max_concurrent_streams` 1024. h2o: not verified from source, no numbers cited.

## Not covered

- Real users' pages and long-lived sessions: sustained rates above one scenario's length, idle keepalive PINGs
  from browsers (Chromium and Firefox sent none in the 8-20 s runs), mobile reconnect storms.
- The decoded header list size (needs an HPACK decoder; only encoded bytes are reported).
- Server-to-client limits; HTTP/3; Safari and Edge; reverse proxies other than Envoy (nginx, HAProxy, Caddy).
- A server that advertises SETTINGS_NO_RFC7540_PRIORITIES (see the finding above).
