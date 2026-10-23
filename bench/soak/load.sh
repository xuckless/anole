#!/bin/sh
# The soak's mixed traffic, one oha per stream, run inside anole-bench/loadgen.
#   load.sh <duration> <out-dir> [rates-file]
# Without a rates file every stream runs flat out (the capacity probe); with
# one, each stream is held at the rate it names ("name rate" per line).
# Streams against examples/full (8080: HTTP/1.1 + h2c, 8443: TLS h2/h1.1 + h3):
#   h1ka      HTTP/1.1 keep-alive GET /users/:id
#   h1close   HTTP/1.1, a new connection per request, GET /
#   tlsclose  TLS HTTP/1.1, a new connection (and handshake) per request
#   h2big     TLS HTTP/2, 16 streams a connection, GET /big gzipped
#   h2cecho   h2c POST /echo with a 64 KiB body, streamed back
#   h3        HTTP/3 GET /users/:id
set -u
dur=$1 out=$2 rates=${3:-}
mkdir -p "$out"
head -c 65536 /dev/urandom >/tmp/body64k
rate() { [ -n "$rates" ] && awk -v n="$1" '$1 == n { printf "-q %d", $2 }' "$rates"; }
run() {
  name=$1; shift
  # shellcheck disable=SC2046
  oha --no-tui --output-format json -z "$dur" -t 10s $(rate "$name") "$@" >"$out/$name.json" 2>"$out/$name.err" &
}
run h1ka -c 32 --rand-regex-url 'http://127.0.0.1:8080/users/[0-9]{1,6}'
run h1close -c 8 --disable-keepalive http://127.0.0.1:8080/
run tlsclose -c 8 --disable-keepalive --insecure --http-version 1.1 --rand-regex-url 'https://127.0.0.1:8443/users/[0-9]{1,4}'
run h2big -c 4 -p 16 --http2 --insecure -H 'Accept-Encoding: gzip' https://127.0.0.1:8443/big
run h2cecho -c 4 -p 8 --http2 -m POST -D /tmp/body64k http://127.0.0.1:8080/echo
run h3 -c 8 --http-version 3 --insecure --rand-regex-url 'https://127.0.0.1:8443/users/[0-9]{1,4}'
wait
