#!/usr/bin/env bash
# Runs h2spec (strict mode, all cases) against examples/hello over cleartext HTTP/2 (prior knowledge)
# and over TLS (BoringSSL, ALPN h2), then checks the results against
# known-failures.txt. Usage: tests/h2spec/run.sh <h2spec binary> <hello binary>
set -euo pipefail
h2spec=$1
hello=$2
here=$(cd "$(dirname "$0")" && pwd)
out=$(mktemp -d)

"$hello" 18080 18443 >"$out/server.log" 2>&1 &
server=$!
trap 'kill -INT "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true' EXIT
for _ in $(seq 50); do
  (exec 3<>/dev/tcp/127.0.0.1/18443) 2>/dev/null && break
  sleep 0.1
done

status=0
"$h2spec" -S -h 127.0.0.1 -p 18080 -o 3 -j "$out/h2c.xml" >"$out/h2c.txt" 2>&1 || true
"$h2spec" -S -h 127.0.0.1 -p 18443 -t -k -o 3 -j "$out/tls.xml" >"$out/tls.txt" 2>&1 || true
tail -n 1 "$out/h2c.txt" "$out/tls.txt"
python3 "$here/check.py" "$here/known-failures.txt" "$out/h2c.xml" "$out/tls.xml" || status=1
if ! kill -0 "$server" 2>/dev/null; then
  echo "the server died during h2spec:"
  tail -n 40 "$out/server.log"
  status=1
fi
exit $status
