#!/bin/sh
# Runs Anole's gRPC interop client (tests/grpc/interop/client.zig) against
# grpc-go's interop server (pinned), one test case at a time.
#   tests/grpc/interop/run-client.sh [path-to-grpc-interop-client] [path-to-grpc-go-interop-server]
set -eu
client=${1:-zig-out/bin/grpc-interop-client}
server=${2:-}
if [ -z "$server" ]; then
  gobin=$(mktemp -d)
  GOBIN=$gobin go install google.golang.org/grpc/interop/server@v1.84.0
  server=$gobin/server
fi
port=10072
"$server" --port=$port >/tmp/anole-grpc-go-server.log 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null || true' EXIT
sleep 1
cases="empty_unary large_unary client_streaming server_streaming ping_pong empty_stream
status_code_and_message special_status_message custom_metadata
timeout_on_sleeping_server unimplemented_method"
failed=0
for c in $cases; do
  if "$client" $port "$c" >/tmp/anole-grpc-client-$c.log 2>&1; then
    echo "PASS $c"
  else
    echo "FAIL $c: $(tail -3 /tmp/anole-grpc-client-$c.log | tr '\n' ' ' | cut -c1-300)"
    failed=$((failed + 1))
  fi
done
echo "$failed failed"
[ "$failed" -eq 0 ]
