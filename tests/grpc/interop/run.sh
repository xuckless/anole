#!/bin/sh
# Runs grpc-go's interop client (pinned) against tests/grpc/interop/server.zig
# over cleartext HTTP/2, one test case at a time; fails on any failing case.
#   tests/grpc/interop/run.sh [path-to-grpc-interop-server] [path-to-grpc-go-interop-client]
# Without a client path, it is built with `go install` (grpc-go v1.84.0).
set -eu
server=${1:-zig-out/bin/grpc-interop-server}
client=${2:-}
if [ -z "$client" ]; then
  gobin=$(mktemp -d)
  GOBIN=$gobin go install google.golang.org/grpc/interop/client@v1.84.0
  client=$gobin/client
fi
port=10071
"$server" $port >/tmp/anole-grpc-interop-server.log 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null || true' EXIT
sleep 1
cases="empty_unary large_unary client_streaming server_streaming ping_pong empty_stream
timeout_on_sleeping_server cancel_after_begin cancel_after_first_response
status_code_and_message special_status_message custom_metadata
unimplemented_method unimplemented_service"
# grpc-go's client has no client_/server_compressed_* cases.
failed=0
for c in $cases; do
  if "$client" --server_host=127.0.0.1 --server_port=$port --use_tls=false --test_case="$c" >/tmp/anole-grpc-interop-$c.log 2>&1; then
    echo "PASS $c"
  else
    echo "FAIL $c: $(tail -2 /tmp/anole-grpc-interop-$c.log | tr '\n' ' ' | cut -c1-300)"
    failed=$((failed + 1))
  fi
done
echo "$failed failed"
[ "$failed" -eq 0 ]
