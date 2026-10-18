#!/usr/bin/env bash
# Anole's WebTransport server in the interop runner's WebTransport mode
# (quic-interop/quic-interop-runner, pinned as in tests/interop/run.sh),
# against browsers' and other implementations' clients.
#
#   tests/interop/webtransport/run.sh [CLIENTS] [TESTS]
#
# CLIENTS and TESTS are comma-separated runner names. Needs what
# tests/interop/run.sh needs. CLIENTS defaults to chrome, firefox and flupke;
# the browser images are x86_64 only (on an arm64 Docker without x86_64
# emulation the runner finds them "not compliant" and skips them, which is
# no pass), so there the default is flupke alone. webtransport-go and
# ngtcp2's webtransport branch speak only the later drafts (they need
# RESET_STREAM_AT) and fail the handshake. ANOLE_INTEROP_BIN skips building
# the server (a Linux binary of `zig build wt-interop-server`). Exits
# non-zero when any test fails.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
case "$(docker info --format '{{.Architecture}}')" in
  x86_64 | amd64) default_clients=chrome,firefox,flupke-webtransport ;;
  *) default_clients=flupke-webtransport ;;
esac
clients=${1:-$default_clients}
tests=${2:-handshake,transfer-unidirectional-receive,transfer-bidirectional-receive,transfer-datagram-receive,transfer-unidirectional-send,transfer-bidirectional-send,transfer-datagram-send}
runner_commit=ab039a4a4b43ae2e21bb5704c9fad1f8fe6257d6
work=${ANOLE_INTEROP_WORK:-$(mktemp -d)}
mkdir -p "$work"

# The server, for the Docker host's architecture.
ctx="$work/image"
mkdir -p "$ctx"
if [ -n "${ANOLE_INTEROP_BIN:-}" ]; then
  cp "$ANOLE_INTEROP_BIN" "$ctx/wt-interop-server"
else
  case "$(docker info --format '{{.Architecture}}')" in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    *) echo "unsupported Docker architecture" >&2; exit 1 ;;
  esac
  (cd "$root" && "${ZIG:-zig}" build wt-interop-server -Dtarget=$arch-linux-gnu -Doptimize=ReleaseSafe --prefix "$work/out")
  cp "$work/out/bin/wt-interop-server" "$ctx/"
fi
cp "$here/Dockerfile" "$here/run_endpoint.sh" "$ctx/"
docker build -q -t anole-wt-interop:latest "$ctx" >/dev/null

# The runner, with Anole added as a server.
if [ ! -d "$work/runner/.git" ]; then
  git clone -q https://github.com/quic-interop/quic-interop-runner "$work/runner"
fi
git -C "$work/runner" checkout -q "$runner_commit"
python3 -I - "$work/runner/implementations_webtransport.json" <<'PY'
import json, sys
p = sys.argv[1]
impls = json.load(open(p))
impls["anole"] = {"image": "anole-wt-interop:latest", "url": "https://github.com/xuckless/anole", "role": "server"}
json.dump(impls, open(p, "w"), indent=2)
PY
python3 -m venv "$work/venv"
"$work/venv/bin/pip" install -q -r "$work/runner/requirements.txt"

cd "$work/runner"
status=0
"$work/venv/bin/python" run.py -p webtransport -s anole -c "$clients" -t "$tests" -l "$work/logs" -j "$work/result.json" || status=$?
echo "logs: $work/logs"
exit $status
