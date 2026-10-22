#!/bin/sh
# The C ABI crossing benchmark (M17 spike): the same server serves
#   /native  a fixed response from the JSON config (never leaves the executors)
#   /hello   the same bytes, answered by a C consumer thread through the ABI
#   /users/:id  a consumer answer that reads a route parameter
# at 1 and 4 executors (one consumer thread), with wrk; a Markdown table on
# stdout (median of three runs by req/s).
#   tests/capi/bench.sh [duration-seconds] [connections]   (default 10, 256)
# Needs wrk. Builds with -Doptimize=ReleaseFast. On Linux, run it once with
# the default (epoll) and once with ZIO_BACKEND=io_uring if zio takes it.
set -eu
dur=${1:-10}
conns=${2:-256}
root=$(cd "$(dirname "$0")/../.." && pwd)
zig=${ZIG:-zig}
out=$root/zig-out/capi-bench
mkdir -p "$out"
(cd "$root" && $zig build capi -Doptimize=ReleaseFast)
cxx_lib=-lc++
[ "$(uname -s)" = Linux ] && cxx_lib="-lstdc++ -lpthread"
# shellcheck disable=SC2086
cc -O2 -std=c11 -I"$root/zig-out/include" "$root/tests/capi/consumer.c" "$root/zig-out/lib/libanole.a" $cxx_lib -o "$out/consumer"

median() { sort -n | sed -n 2p; }
wrk_case() { # url -> "rps p99ms"
  wrk -t4 -c"$conns" -d3s "$1" >/dev/null
  for i in 1 2 3; do
    wrk -t4 -c"$conns" -d"${dur}s" --latency "$1" | awk '
      /Requests\/sec/ {rps=$2}
      $1=="99%" {v=$2; if (v ~ /us$/) {sub(/us/,"",v); v/=1000} else if (v ~ /ms$/) {sub(/ms/,"",v)} else if (v ~ /s$/) {sub(/s/,"",v); v*=1000}; p=v}
      END {printf "%d %.2f\n", rps, p}'
  done | median
}

port=18300
echo "| executors | route | req/s | p99 ms |"
echo "|---|---|---|---|"
for ex in 1 4; do
  port=$((port + 1))
  fifo=$out/stdin.$ex
  rm -f "$fifo"; mkfifo "$fifo"
  "$out/consumer" serve "$ex" "$port" 1 <"$fifo" 2>"$out/serve.$ex.log" &
  pid=$!
  exec 3>"$fifo"
  sleep 1
  for route in /native /hello /users/7; do
    set -- $(wrk_case "http://127.0.0.1:$port$route")
    echo "| $ex | $route | $1 | $2 |"
  done
  exec 3>&-
  wait $pid || true
  rm -f "$fifo"
  sed 's/^/    /' "$out/serve.$ex.log" | grep events >&2 || true
done
