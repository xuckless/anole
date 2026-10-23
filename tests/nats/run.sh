#!/usr/bin/env bash
# Runs anole.nats's live tests (`zig build test -Dnats-test-url=...`) against
# a throwaway nats-server in Docker with JetStream on.
#
#   tests/nats/run.sh                         # nats:2.11 on port 54222
#   NATS_IMAGE=nats:2.10 NATS_PORT=54223 tests/nats/run.sh
#   tests/nats/run.sh -Doptimize=ReleaseSafe  # extra zig build arguments
set -euo pipefail

cd "$(dirname "$0")/../.."
ZIG=${ZIG:-zig}
IMAGE=${NATS_IMAGE:-nats:2.11}
PORT=${NATS_PORT:-54222}
NAME=anole-nats-test-$$
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT

docker run -d --rm --name "$NAME" -p "127.0.0.1:$PORT:4222" "$IMAGE" -js >/dev/null
for _ in $(seq 1 50); do
  if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then break; fi
  sleep 0.2
done
"$ZIG" build test -Dnats-test-url="nats://127.0.0.1:$PORT" "$@"
