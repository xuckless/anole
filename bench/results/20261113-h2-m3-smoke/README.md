# HTTP/2 takeover M3: real-client smoke and flood-budget recalibration on the new engine (2026-11-13)

Does the new engine (`src/http/core/h2/server.zig`, the server's HTTP/2 engine since the M3 switch) serve real
clients without closing a connection on its own budgets, and do the flood budgets calibrated against the nghttp2
engine (bench/results/20261111-h2-limits-calibration) still hold now that the engine advertises
`SETTINGS_NO_RFC7540_PRIORITIES`? This is counting, not benchmarking: no throughput or latency figures, and
`limits.zig` is untouched (recommendations at the end are the lead's to apply).

## Method

- **Engine:** branch `h2m3/engine` at the commit that carries the fix below (0.5.4 + M3 core, seams, lifecycle,
  switch), Debug build, as the calibration was. Site: `tools/h2count/site` (`zig build h2count-site`);
  gRPC: `examples/grpc`.
- **Tool:** `tools/h2count` as in the calibration, extended for this item: a PRIORITY_UPDATE (0x10) counter of its own
  (it was folded into `unknown`), the error codes of GOAWAY and RST_STREAM in both directions, the debug data of the
  server's GOAWAYs, the client GOAWAY's last-stream id, and the server's SETTINGS entries (`error_codes`,
  `s2c_goaway_debug`, `server_settings` in the JSON). `frames_test.go` covers them, chunked input included.
  The browser pages (`drive.html`) report their result to the site (`GET /done`, one line in `site.log`), so a hung
  download or a failed upload shows as FAIL instead of a pass; a download must be exactly 64 MiB and an upload echo
  16 MiB. `scenarios/run.sh` prints PASS/FAIL per scenario.
- **Clients** (all on this machine, browsers headless on a temporary profile removed afterwards, never the user's):
  Chromium 156.0.8078.79, Firefox 160.0 (WebDriver BiDi), curl 8.18.0 (nghttp2 1.68.0), Node 22.23.1 `http2`,
  Go 1.26.7 `net/http` (new `tools/h2count/clients/gohttp`: 100 concurrent GETs, a 16 MiB upload, 20 cancelled
  downloads, every response must be `HTTP/2.0`, exit 1 otherwise), grpc-go v1.85.0 (`clients/grpcgo`, now
  exits 1 on a failure: 1000 unary calls, 20 cut by a deadline), Envoy v1.34.1 (Docker, container `h2count-envoy`
  removed by name; no prune). h2load was not run (synthetic, nothing new for this engine).
- **Paths:** curl, Node, Chromium, Firefox, Envoy and the Go client (TLS and h2c) go through the counting proxy,
  which terminates TLS and feeds the engine h2c: the engine's h2c entry. The engine's own TLS path (`secure=true`,
  BoringSSL) gets real clients in the new `direct` group: curl (100 parallel GETs over one connection, a 16 MiB
  upload) and the Go client straight at the site's TLS port (ECDSA cert from `openssl`, ALPN h2), uncounted.
  Chromium and Firefox stay on the proxy path (they would need the certificate trusted).
- **Raw data:** `raw/*/h2count.json` (per connection), `raw/*/run.log`, `site.log`, `h2count.log`, `summary.md` per
  group and a combined `summary.md` (what the tables below quote). One run each; a clean run, not a retry-until-green.

## Results per client

| client | scenarios | result |
|---|---|---|
| curl | load (TLS, h2c), abort, upload 16 MiB, SSE, 30k header | all complete; 30k header answers 200 |
| curl | 200k header (20 fields) | curl refuses to send (000), never reaches the engine; as in the calibration |
| curl (direct TLS) | 100 parallel GETs on one connection, 16 MiB upload | PASS, all `2 200`, upload echoed 16777216 |
| Node `http2` | page, download, cancel, upload | PASS x4 (script exit status) |
| Node `http2` | PING tool-driven | PASS (50 PING/s, driven by the tool, synthetic) |
| Go `net/http` | TLS (ALPN h2) and h2c | PASS: 100 GETs, 16 MiB upload, 20 of 20 cancelled, all HTTP/2.0 |
| Go `net/http` (direct TLS) | same | PASS |
| grpc-go | 1000 unary + 20 cancelled | PASS: ok=1000 failed=0 cancelled=20 of 20 |
| Chromium 156 | load, reload (30 cut-off loads), abort, SSE, upload, download, nav | PASS x7 |
| Firefox 160 | the same seven | PASS x7 |
| Envoy 1.34.1 | default, keepalive (5 s PING), 100 GETs, 10 cancelled, SSE | completed; 1 PING/s |
| raw (rawcont.mjs) | header block over CONTINUATIONs | 8 CONTINUATIONs served, 9 or more: GOAWAY(ENHANCE_YOUR_CALM) "too many CONTINUATION frames"; 70 KiB block: "header block too large". Expected (the budgets working) |
| raw (rawprio.mjs, new) | 5000 PRIORITY_UPDATE, then 5000 PRIORITY, each in one write, then a GET | no GOAWAY, the GET answered both times |

Server-sent GOAWAY and RST_STREAM codes over the whole run: the only GOAWAY with a code other than NO_ERROR is the
`raw-continuation` row above (3, all ENHANCE_YOUR_CALM, all on purpose). No other server GOAWAY, no RST_STREAM
the clients did not cause, `unknown` frames 0, empty-frame counters 0, no desync in either direction. The site logs
(`raw/*/site.log`) show no engine error.

### One engine bug found and fixed

The first grpc-go run passed (1000/20) but the proxy showed one server `GOAWAY(PROTOCOL_ERROR)` per connection,
debug data `GOAWAY: invalid last_stream_id`, answering the client's own closing `GOAWAY(NO_ERROR)`. grpc-go's
client names its highest stream (here 2039, odd) in that GOAWAY, where RFC 9113 6.8 wants a stream the *receiver*
opened (a server opens none). The engine's check was nghttp2's (an id of the peer's own parity is invalid), so the
nghttp2 engine did the same. Harmless in effect (the client is already closing) but a protocol error plus log noise
at the end of every gRPC connection, and a connection terminated instead of drained. Fix: only the rule that the
id never grows is kept (`conn.zig` `onGoaway`, test `conn_test.zig` "a GOAWAY's last_stream_id of the peer's
own parity is accepted", INTENTIONAL.md "The session" 6). After it, the grpc-go run has no server GOAWAY.

## Recalibration: PRIORITY and PRIORITY_UPDATE

The engine advertises these SETTINGS (proxy capture, every connection of every run):

| entry | value |
|---|---|
| 0x3 MAX_CONCURRENT_STREAMS | 250 |
| 0x4 INITIAL_WINDOW_SIZE | 65536 |
| 0x6 MAX_HEADER_LIST_SIZE | 65536 |
| 0x9 NO_RFC7540_PRIORITIES | 1 |

The expected switch did not show in the data:

| client (reload scenario, 30 page loads cut off, about 14 loads/s) | PRIORITY peak 1 s | PRIORITY per connection (max) | PRIORITY_UPDATE |
|---|---|---|---|
| Chromium 156 | 657 (207 per 100 ms) | 1036 for 2526 requests | **0** in every scenario |
| Firefox 160 | 0 | 0 | **0** in every scenario |
| curl, Node, Go, grpc-go, Envoy | 0 | 0 | 0 |

- **Chromium kept sending RFC 7540 PRIORITY frames** (657/s peak, the calibration measured 694/s on the nghttp2 engine
  without the setting) and **sent no PRIORITY_UPDATE** although 0x9=1 reached it in the first SETTINGS. Firefox sent
  neither before and neither now. I did not investigate why Chromium ignores the setting here (a feature gate in a
  headless build is a guess, not a finding).
- **The exemption holds.** PRIORITY, at 657/s, ran above the 330/s glitch rate for a second in Chromium's reload with
  no GOAWAY and no RST from the server; and the synthetic `raw-priority` run (rawprio.mjs: 5000 PRIORITY_UPDATE and
  5000 PRIORITY in a single write, a GET after them) left the connection open and answered. For PRIORITY_UPDATE
  the browsers give no organic rate (0), so the exemption is shown by the synthetic run and the unit tests
  (`conn_limits_test.zig` "PRIORITY_UPDATE is not counted as an unknown frame"), not by a real client's rate.
  If a browser version starts sending PRIORITY_UPDATE, the expected rate is about one per prioritized stream
  (Chromium's per-load PRIORITY count: 117 for a 100-subresource load).

## Headroom of the other budgets (limit / highest legitimate value, synthetic rows excluded)

| budget | limit | highest legitimate | headroom |
|---|---|---|---|
| empty DATA/HEADERS/CONTINUATION per second | 100 | 0 | no observation (nothing sent any) |
| SETTINGS entries per frame | 32 | 5 (Envoy) | 6.4x |
| CONTINUATION frames per block | 8 | 1 (curl, a 30 KB header) | 8.0x |
| peak concurrent streams | 250 | 100 (Node page, curl -Z at its own 100 cap) | 2.5x, the line, as before |
| header block bytes | 65536 | 24067 (curl 30 KB header, deliberately large) | 2.7x |
| unanswered RST_STREAM in 1 s (bucket burst 1000) | 1000 | 80 (Chromium reload) | 12.5x |
| PING | queued control budget 1000 (not a rate) | 22/s (grpc-go) | n/a |
| PRIORITY, PRIORITY_UPDATE | not charged | 657/s, 0 | exempt |

Every row keeps at least 2.5x. Unchanged against the calibration: the stream cap is exactly at the 2.5x line
because the clients' own cap (curl `--parallel-max 100`, a Node page of 100) is what is observed, and the header
block row is a deliberate 30 KB header. The sustained RST_STREAM rate (33/s refill) is still not observable by a
scenario this short: the highest 1 s count is 80 and the bucket's burst is 1000.

## Not covered, and caveats

- Headless, scripted browsers and one run per scenario; real pages with 500 subresources, long-lived tabs and mobile
  reconnects are heavier. The proxy is a hop; it terminates TLS, so Chromium and Firefox never reached the engine's
  `secure=true` path. h2spec TLS (441/441 on the switch) and the direct group are the TLS evidence.
- The `direct` group is not counted (the proxy is not in its path): it proves success only.
- Go clients: ALPN negotiated h2 in every run (`non-h2=0`), so no silent HTTP/1.1 fallback.

## Recommendations to the lead (limits.zig is unchanged)

- No default needs to change: every budget keeps >= 2.5x and no real client was closed by one.
- Keep the PRIORITY / PRIORITY_UPDATE exemption: Chromium's PRIORITY rate alone is 2x the 330/s glitch rate.
- Re-measure if a browser release starts sending PRIORITY_UPDATE (the sensors are in the proxy now: `priority_update`).
- The engine's GOAWAY on a client's odd last_stream_id was the one real finding (fixed in this item).
