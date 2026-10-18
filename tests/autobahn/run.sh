#!/bin/sh
# Runs the Autobahn fuzzing client (Docker) against tests/autobahn/echo.zig
# and fails on any case that is not OK, NON-STRICT or INFORMATIONAL, or on a
# run that did not cover every case it announced. A run cut short by the
# client failing to connect (Docker Desktop's host.docker.internal path
# drops a connection now and then), or one that wrote no report, is
# retried, twice at most; a run with no report prints both logs.
#   tests/autobahn/run.sh [path-to-echo-binary]
set -eu
here=$(cd "$(dirname "$0")" && pwd)
bin=${1:-zig-out/bin/autobahn-echo}
image=crossbario/autobahn-testsuite@sha256:519915fb568b04c9383f70a1c405ae3ff44ab9e35835b085239c258b6fac3074
attempt=1
while :; do
  reports=$(mktemp -d)
  echo "reports: $reports (attempt $attempt)"
  "$bin" 9001 >"$reports/server.log" 2>&1 &
  pid=$!
  sleep 1
  docker run --rm --add-host=host.docker.internal:host-gateway \
    -v "$here/fuzzingclient.json:/config/fuzzingclient.json:ro" \
    -v "$reports:/reports" \
    "$image" wstest -m fuzzingclient -s /config/fuzzingclient.json >"$reports/wstest.log" 2>&1 || true
  kill $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true
  if [ ! -f "$reports/index.json" ]; then
    echo "no report from the fuzzing client; its log and the echo peer's:"
    tail -30 "$reports/wstest.log" || true
    tail -30 "$reports/server.log" || true
  fi
  if { [ ! -f "$reports/index.json" ] || grep -q "failed (User timeout\|Connection refused" "$reports/wstest.log"; } && [ $attempt -lt 3 ]; then
    echo "client connection failure or no report; retrying"
    attempt=$((attempt + 1))
    continue
  fi
  break
done
python3 -I "$here/check.py" "$reports/index.json" "$reports/wstest.log"
