#!/usr/bin/env bash
# Runs h2spec (strict mode, all cases) against examples/full over cleartext HTTP/2 (prior knowledge)
# on the port shared with HTTP/1.1 and on an h2c-only listener, and over TLS (BoringSSL, ALPN h2),
# then checks the results against
# known-failures.txt. Usage: tests/h2spec/run.sh <h2spec binary> <examples/full binary>
set -euo pipefail
h2spec=$1
server_bin=$2
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../lib/wait.sh"
out=$(mktemp -d)

"$server_bin" 18080 18443 18081 18082 >"$out/server.log" 2>&1 &
server=$!
trap 'kill -INT "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true' EXIT
# Every listener is bound by the time one accepts.
wait_until 30 "examples/full to listen" port_open 127.0.0.1 18443 || { tail -n 40 "$out/server.log"; exit 1; }
# h2spec's own per-case timeout (seconds), scaled as the waits are.
case_timeout=$((3 * $(wait_factor)))

status=0
"$h2spec" -S -h 127.0.0.1 -p 18080 -o "$case_timeout" -j "$out/h2c.xml" >"$out/h2c.txt" 2>&1 || true
"$h2spec" -S -h 127.0.0.1 -p 18082 -o "$case_timeout" -j "$out/h2c-only.xml" >"$out/h2c-only.txt" 2>&1 || true
"$h2spec" -S -h 127.0.0.1 -p 18443 -t -k -o "$case_timeout" -j "$out/tls.xml" >"$out/tls.txt" 2>&1 || true
tail -n 1 "$out/h2c.txt" "$out/h2c-only.txt" "$out/tls.txt"
python3 "$here/check.py" "$here/known-failures.txt" "$out/h2c.xml" "$out/h2c-only.xml" "$out/tls.xml" || status=1
if ! kill -0 "$server" 2>/dev/null; then
  echo "the server died during h2spec:"
  tail -n 40 "$out/server.log"
  status=1
fi
exit $status
