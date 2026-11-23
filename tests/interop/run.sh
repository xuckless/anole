#!/usr/bin/env bash
# Anole's HTTP/3 server in the QUIC interop runner (quic-interop/
# quic-interop-runner, pinned below), against other implementations'
# clients.
#
#   tests/interop/run.sh [CLIENTS] [TESTS]
#
# CLIENTS and TESTS are comma-separated runner names (defaults below). Needs
# Docker with compose v2, tshark, python3 and git; Linux, or anything that
# can run the runner (see the CI job). ANOLE_INTEROP_BIN skips building
# the server (a Linux binary of `zig build h3-interop-server`);
# ANOLE_INTEROP_IMAGE names its image (default anole-interop:latest), so
# two checkouts can keep their own. Exits non-zero when any test fails.
#
# CI-only patches to the pinned runner and simulator, redone on every run
# (the runner checkout is reset first, so a second run on the same work dir
# works; a runner_commit bump that breaks a patch fails the run):
#  - sim-run.sh + docker-compose.override.yml: the simulator waits for its
#    dumpcap processes on SIGTERM, so 1-second cases (handshake, retry) keep
#    both captures (without it: "Expected exactly one version. Got []").
#  - rebind-check.patch: the rebind-port/-addr check passes when every new
#    path has any answered PATH_CHALLENGE, not only its first (a lost first
#    probe is re-sent with new data, RFC 9000 8.2.1).
#  - empty-env.sh: see there.
# Known flakes left: quic-go with handshakeloss/handshakecorruption (L1/C1),
# "Expected 50 handshakes" with "handshake did not complete in time" in the
# client's log (the client gives up at 10 s; no Anole fix, no retries).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
clients=${1:-ngtcp2,quic-go}
tests=${2:-handshake,transfer,longrtt,chacha20,multiplexing,retry,http3,amplificationlimit,blackhole,keyupdate,handshakeloss,transferloss,handshakecorruption,transfercorruption,ecn,rebind-port,rebind-addr,v2,resumption,zerortt}
runner_commit=ab039a4a4b43ae2e21bb5704c9fad1f8fe6257d6
work=${ANOLE_INTEROP_WORK:-$(mktemp -d)}
image=${ANOLE_INTEROP_IMAGE:-anole-interop:latest}
mkdir -p "$work"

# The server, for the Docker host's architecture.
ctx="$work/image"
mkdir -p "$ctx"
if [ -n "${ANOLE_INTEROP_BIN:-}" ]; then
  cp "$ANOLE_INTEROP_BIN" "$ctx/h3-interop-server"
else
  case "$(docker info --format '{{.Architecture}}')" in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    *) echo "unsupported Docker architecture" >&2; exit 1 ;;
  esac
  (cd "$root" && "${ZIG:-zig}" build h3-interop-server -Dtarget=$arch-linux-gnu -Doptimize=ReleaseSafe --prefix "$work/out")
  cp "$work/out/bin/h3-interop-server" "$ctx/"
fi
cp "$here/Dockerfile" "$here/run_endpoint.sh" "$ctx/"
docker build -q -t "$image" "$ctx" >/dev/null

# The runner, with Anole added as a server.
if [ ! -d "$work/runner/.git" ]; then
  git clone -q https://github.com/quic-interop/quic-interop-runner "$work/runner"
fi
git -C "$work/runner" checkout -q "$runner_commit"
python3 -I - "$work/runner/implementations_quic.json" "$image" <<'PY'
import json, sys
p = sys.argv[1]
impls = json.load(open(p))
impls["anole"] = {"image": sys.argv[2], "url": "https://github.com/xuckless/anole", "role": "server"}
json.dump(impls, open(p, "w"), indent=2)
PY
"$here/empty-env.sh" "$work/runner" "$runner_commit"
cp "$here/sim-run.sh" "$here/docker-compose.override.yml" "$work/runner/"
chmod +x "$work/runner/sim-run.sh"
git -C "$work/runner" checkout -q -- testcases_quic.py
git -C "$work/runner" apply "$here/rebind-check.patch"
python3 -m venv "$work/venv"
# The runner's own requirements.txt, pinned with hashes here.
"$work/venv/bin/pip" install -q --require-hashes -r "$here/requirements.txt"

cd "$work/runner"
status=0
"$work/venv/bin/python" run.py -s anole -c "$clients" -t "$tests" -l "$work/logs" -j "$work/result.json" || status=$?
echo "logs: $work/logs"
exit $status
