# h2count

A counting TCP proxy for HTTP/2, written to calibrate the flood budgets of
Anole's HTTP/2 engine against real clients (PLAN section 5.4, TODO.md 3a D15
point 5). Go standard library only; the frame header is parsed by hand
(RFC 9113 section 4.1), nothing is copied.

It accepts TLS with ALPN `h2` (a self-signed certificate made at start) and
h2c with prior knowledge, forwards every byte unchanged to an upstream h2c
server, and counts the client-to-server frames per connection with a 1 s
sliding peak (ten 100 ms buckets, so a window is 0.9 to 1.0 s). The
server-to-client direction is parsed only to know which streams are open
(peak concurrent streams, and whether a client RST_STREAM hit a stream the
server had not finished answering). There is no HPACK decoder: header blocks
are reported as encoded bytes.

Counted per connection: PING and PING ACK, SETTINGS frames, entries, entries
per frame and the setting ids seen, SETTINGS ACK, RST_STREAM (all, and for
streams not yet answered), empty DATA / HEADERS / CONTINUATION frames
without END_STREAM, unknown frame types (by id), CONTINUATIONs per header
block, header-block bytes, WINDOW_UPDATE, PRIORITY, GOAWAY, requests, peak
concurrent streams, largest frame. A rollup per scenario takes, for each
counter, the largest peak over its connections (every budget applies to one
connection).

```
go build -o h2count .
./h2count -listen tls@:9443=127.0.0.1:8080 -listen h2c@:9080=127.0.0.1:8080 \
          -out h2count.json -cert-out cert.pem
curl 127.0.0.1:9990/scenario?name=my-client   # start a new bucket (the label of later connections)
curl 127.0.0.1:9990/dump                      # write the report now; SIGINT writes it and exits
```

`-listen kind@addr=upstream` repeats; `kind` is `tls` or `h2c`. A TLS client
that does not negotiate `h2` is counted as `not_h2` and closed. The upstream
is always h2c, so a TLS client sees the proxy's certificate (`-cert-out`,
or `curl -k`), and the server sees the client's frames as sent. The proxy
sets TCP_NODELAY on both legs but is still a hop: protocol-level counts are
exact, rates can differ a little from an unproxied connection.

`go test ./...` covers the parser (byte-at-a-time and randomly chunked input
give identical counts, garbage desyncs without a panic), the sliding window
(with an injected clock) and the proxy (bytes pass verbatim in both modes).

## Test site and scenarios

`site/main.zig` is the upstream (`zig build h2count-site`, or
`zig build run-h2count-site -- 8080`): `/` a page with 100 subresources,
`/r/:n` a small body, `/download` 64 MiB generated, `POST /upload` a sink,
`/sse` an event every 100 ms for 20 s, `/slow` 2 s, and `/drive?s=<name>`, a
page whose script makes a browser reload, cancel, stream and upload.
gRPC comes from `examples/grpc` (`zig build grpc`).

```
SITE_BIN=zig-out/bin/h2count-site GRPC_BIN=zig-out/bin/grpc \
  tools/h2count/scenarios/run.sh /tmp/h2out [curl node chromium firefox grpc envoy h2load]
```

`scenarios/run.sh` starts everything, drives one scenario per client (each
under a minute), and writes `h2count.json`, the proxy log and a run log into
the output directory. Browsers run with a temporary profile; Envoy and h2load
run in Docker containers started by name and removed by name. The results
and their reading are in `bench/results/*-h2-limits-calibration/`.
