#!/bin/sh
# Runs Anole's gRPC interop client (tests/grpc/interop/client.zig) against
# grpc-go's interop server (pinned), one test case at a time. Over cleartext
# HTTP/2, or with --tls over TLS (a certificate made for the run by cert.sh,
# which Anole's client trusts as its CA).
#   tests/grpc/interop/run-client.sh [--tls] [path-to-grpc-interop-client] [path-to-grpc-go-interop-server]
set -eu
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../../lib/wait.sh"
tls=false
if [ "${1:-}" = "--tls" ]; then
  tls=true
  shift
fi
client=${1:-zig-out/bin/grpc-interop-client}
server=${2:-}
work=$(mktemp -d)
if [ -z "$server" ]; then
  GOBIN=$work go install google.golang.org/grpc/interop/server@v1.84.0
  server=$work/server
fi
if $tls; then
  "$here/cert.sh" "$work"
  port=10074
  server_tls="--use_tls=true --tls_cert_file=$work/cert.pem --tls_key_file=$work/key.pem"
  set -- "$work/cert.pem"
  mode=tls
else
  port=10072
  server_tls="--use_tls=false"
  set --
  mode=h2c
fi
logs=${TMPDIR:-/tmp}/anole-grpc-client-$mode
mkdir -p "$logs"
# shellcheck disable=SC2086
"$server" --port=$port $server_tls >"$logs/server.log" 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null || true; rm -rf "$work"' EXIT
wait_until 30 "the interop server to listen" port_open 127.0.0.1 "$port" || { tail -20 "$logs/server.log"; exit 1; }
cases="empty_unary large_unary client_streaming server_streaming ping_pong empty_stream
status_code_and_message special_status_message custom_metadata
timeout_on_sleeping_server unimplemented_method"
failed=0
for c in $cases; do
  if "$client" $port "$c" "$@" >"$logs/$c.log" 2>&1; then
    echo "PASS $c ($mode)"
  else
    echo "FAIL $c ($mode): $(tail -3 "$logs/$c.log" | tr '\n' ' ' | cut -c1-300)"
    failed=$((failed + 1))
  fi
done
echo "$failed failed"
[ "$failed" -eq 0 ]
