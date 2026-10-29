#!/usr/bin/env bash
# Runs anole.nats's live tests (`zig build test-nats -Dnats-test-url=...`) against
# a throwaway nats-server in Docker with JetStream on.
#
#   tests/nats/run.sh                         # nats:2.11 on port 54222
#   NATS_IMAGE=nats:2.10 NATS_PORT=54223 tests/nats/run.sh
#   tests/nats/run.sh -Doptimize=ReleaseSafe  # extra zig build arguments
#
# ANOLE_KEEP_CONTAINERS=1 leaves the containers when the script ends (CI
# collects their logs and states after a failure, then removes them).
set -euo pipefail

cd "$(dirname "$0")/../.."
. tests/lib/wait.sh
ZIG=${ZIG:-zig}
IMAGE=${NATS_IMAGE:-nats:2.11}
PORT=${NATS_PORT:-54222}
NAME=anole-nats-test-$$
trap '[ -n "${ANOLE_KEEP_CONTAINERS:-}" ] || docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT

docker run -d --name "$NAME" -p "127.0.0.1:$PORT:4222" "$IMAGE" -js >/dev/null
wait_until 60 "nats-server to listen" port_open 127.0.0.1 "$PORT" || { docker logs "$NAME" 2>&1 | tail -30 >&2; exit 1; }
"$ZIG" build test-nats -Dnats-test-url="nats://127.0.0.1:$PORT" "$@"
