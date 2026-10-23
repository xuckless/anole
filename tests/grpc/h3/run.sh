#!/usr/bin/env bash
# gRPC over HTTP/3 against grpc-dotnet's interop client and server
# (v2.84.0, in Docker with libmsquic), in both directions, and against the
# C ABI's gRPC server:
#
#   a  grpc-dotnet client -> Anole's interop server (h2 + h3 on one port)
#   b  grpc-dotnet client -> the C consumer (tests/capi/grpc_interop.c)
#   c  Anole's client (--h3) -> grpc-dotnet's Kestrel server over HTTP/3
#   d  Anole's client -> the same Kestrel server over HTTP/2 (a sanity check)
#
#   tests/grpc/h3/run.sh
#
# Needs Docker and Zig. Everything runs inside one container on its
# loopback, so UDP behaves the same on CI (x86_64) and on a Mac (aarch64
# Docker). ANOLE_GRPC_H3_WORK sets the work directory (logs in logs/).
# Exits non-zero when any case fails.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
work=${ANOLE_GRPC_H3_WORK:-$(mktemp -d)}
mkdir -p "$work/logs"

case "$(docker info --format '{{.Architecture}}')" in
  x86_64 | amd64) arch=x86_64 ;;
  aarch64 | arm64) arch=aarch64 ;;
  *) echo "unsupported Docker architecture" >&2; exit 1 ;;
esac

tag="anole-grpc-dotnet-interop:v2.84.0-$(shasum "$here/Dockerfile" | cut -c1-12)"
if ! docker image inspect "$tag" >/dev/null 2>&1; then
  docker build -t "$tag" "$here"
fi

(cd "$root" && "${ZIG:-zig}" build grpc-interop-server grpc-interop-client capi-grpc \
  -Dtarget=$arch-linux-gnu -Doptimize=ReleaseSafe --prefix "$work/out")

docker run --rm \
  -v "$work/out/bin:/anole:ro" \
  -v "$root/tests/grpc/interop/cert.sh:/scripts/cert.sh:ro" \
  -v "$here/inside.sh:/scripts/inside.sh:ro" \
  -v "$work/logs:/logs" \
  "$tag" bash /scripts/inside.sh
