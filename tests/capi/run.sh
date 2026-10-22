#!/bin/sh
# Builds libanole (zig build capi) and the C consumer, then runs the
# consumer's correctness suite.
#   tests/capi/run.sh [--asan] [-Doptimize=...]
# --asan builds the consumer with -fsanitize=address,undefined (libanole's C
# dependencies are not instrumented; Zig code keeps its own safety checks
# in Debug/ReleaseSafe).
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
zig=${ZIG:-zig}
cflags="-O2 -g"
if [ "${1:-}" = "--asan" ]; then
  cflags="-O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=undefined"
  shift
fi
(cd "$root" && $zig build capi "$@")
out=${CAPI_OUT:-$root/zig-out/capi-test}
mkdir -p "$out"
cxx_lib=-lc++
[ "$(uname -s)" = Linux ] && cxx_lib="-lstdc++ -lpthread"
# shellcheck disable=SC2086
cc $cflags -std=c11 -Wall -Wextra -I"$root/zig-out/include" "$root/tests/capi/consumer.c" \
  "$root/zig-out/lib/libanole.a" $cxx_lib -o "$out/consumer"
"$out/consumer" test
