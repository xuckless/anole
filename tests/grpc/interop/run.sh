#!/bin/sh
# Runs grpc-go's interop client (pinned) against tests/grpc/interop/server.zig,
# one test case at a time; fails on any failing case. Over cleartext HTTP/2,
# or with --tls over TLS (a certificate made for the run by cert.sh, which
# the client trusts as its CA).
#   tests/grpc/interop/run.sh [--tls] [path-to-grpc-interop-server] [path-to-grpc-go-interop-client]
# Without a client path, it is built with `go install` (grpc-go v1.84.0).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../../lib/wait.sh"
tls=false
if [ "${1:-}" = "--tls" ]; then
  tls=true
  shift
fi
server=${1:-zig-out/bin/grpc-interop-server}
client=${2:-}
work=$(mktemp -d)
if [ -z "$client" ]; then
  GOBIN=$work go install google.golang.org/grpc/interop/client@v1.84.0
  client=$work/client
fi
if $tls; then
  "$here/cert.sh" "$work"
  port=10073
  set -- "$work/cert.pem" "$work/key.pem"
  client_tls="--use_tls=true --use_test_ca=true --ca_file=$work/cert.pem --server_host_override=localhost"
  mode=tls
else
  port=10071
  set --
  client_tls="--use_tls=false"
  mode=h2c
fi
logs=${TMPDIR:-/tmp}/anole-grpc-interop-$mode
mkdir -p "$logs"
"$server" $port "$@" >"$logs/server.log" 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null || true; rm -rf "$work"' EXIT
wait_until 30 "the interop server to listen" port_open 127.0.0.1 "$port" || { tail -20 "$logs/server.log"; exit 1; }
cases="empty_unary large_unary client_streaming server_streaming ping_pong empty_stream
timeout_on_sleeping_server cancel_after_begin cancel_after_first_response
status_code_and_message special_status_message custom_metadata
unimplemented_method unimplemented_service"
# grpc-go's client has no client_/server_compressed_* cases.
failed=0
for c in $cases; do
  # shellcheck disable=SC2086
  if "$client" --server_host=127.0.0.1 --server_port=$port $client_tls --test_case="$c" >"$logs/$c.log" 2>&1; then
    echo "PASS $c ($mode)"
  else
    echo "FAIL $c ($mode): $(tail -2 "$logs/$c.log" | tr '\n' ' ' | cut -c1-300)"
    failed=$((failed + 1))
  fi
done
echo "$failed failed"
[ "$failed" -eq 0 ]
