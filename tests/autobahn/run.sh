#!/bin/sh
# Runs the Autobahn fuzzing client (Docker) against tests/autobahn/echo.zig
# and fails on any case that is not OK, NON-STRICT or INFORMATIONAL.
#   tests/autobahn/run.sh [path-to-echo-binary]
set -eu
here=$(cd "$(dirname "$0")" && pwd)
bin=${1:-zig-out/bin/autobahn-echo}
image=crossbario/autobahn-testsuite@sha256:519915fb568b04c9383f70a1c405ae3ff44ab9e35835b085239c258b6fac3074
reports=$(mktemp -d)
"$bin" 9001 >"$reports/server.log" 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null || true' EXIT
sleep 1
docker run --rm --add-host=host.docker.internal:host-gateway \
  -v "$here/fuzzingclient.json:/config/fuzzingclient.json:ro" \
  -v "$reports:/reports" \
  "$image" wstest -m fuzzingclient -s /config/fuzzingclient.json >"$reports/wstest.log" 2>&1
python3 -I "$here/check.py" "$reports/index.json"
