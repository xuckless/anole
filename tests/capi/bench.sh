#!/bin/sh
# The C ABI crossing benchmark. One server, from the C consumer
# (tests/capi/consumer.c serve), serves:
#   /native       a fixed response from the JSON config (never leaves the
#                 executors; on HTTP/2 it runs inline on the reader, noWait)
#   /native-task  the same, but on a task of its own (HTTP/2: what a stream
#                 task costs without any crossing)
#   /hello        the same bytes, answered by a C consumer thread via the ABI
#   /users/:id    a consumer answer that reads a route parameter
# at 1 and 4 executors with one consumer thread. Markdown tables on stdout:
#   1. HTTP/1.1, wrk -t4 -c$conns (median of three runs by req/s)
#   2. HTTP/1.1 pipelined 16 deep (wrk + pipeline.lua)
#   3. h2c, h2load -c64 -m16 (if h2load is installed)
#
#   tests/capi/bench.sh [duration-seconds] [connections]   (default 10, 256)
#   CAPI_SPIN_US=50 tests/capi/bench.sh ...   consumer spins 50 us (NOARM
#                                             polls) before it sleeps
# Needs wrk (and h2load for the h2c table). Builds -Doptimize=ReleaseFast.
# Linux: zio uses io_uring where the kernel allows it, else epoll; run it
# once as is and once with io_uring off (sysctl kernel.io_uring_disabled=2,
# or inside Docker's default seccomp profile) to get both.
set -eu
dur=${1:-10}
conns=${2:-256}
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
. "$here/../lib/wait.sh"
zig=${ZIG:-zig}
out=$root/zig-out/capi-bench
mkdir -p "$out"
# The suite's consumer, statically linked against a ReleaseFast libanole.a.
(cd "$root" && $zig build capi-consumer -Doptimize=ReleaseFast)
cp "$root/zig-out/bin/capi-consumer" "$out/consumer"

median() { sort -n | sed -n 2p; }
wrk_case() { # url [wrk args] -> "rps p99ms"
  url=$1; shift
  wrk -t4 -c"$conns" -d3s "$@" "$url" >/dev/null
  for i in 1 2 3; do
    wrk -t4 -c"$conns" -d"${dur}s" --latency "$@" "$url" | awk '
      /Requests\/sec/ {rps=$2}
      $1=="99%" {v=$2; if (v ~ /us$/) {sub(/us/,"",v); v/=1000} else if (v ~ /ms$/) {sub(/ms/,"",v)} else if (v ~ /s$/) {sub(/s/,"",v); v*=1000}; p=v}
      END {printf "%d %.2f\n", rps, p}'
  done | median
}
h2_case() { # url -> rps (median of three)
  h2load -n 200000 -c 64 -m 16 -t 4 "$1" >/dev/null 2>&1
  for i in 1 2 3; do
    h2load -D "$dur" -c 64 -m 16 -t 4 "$1" 2>/dev/null | awk '/^finished in/ {gsub(",","",$4); printf "%d\n", $4}'
  done | median
}

start() { # executors port
  fifo=$out/stdin.$2
  rm -f "$fifo"; mkfifo "$fifo"
  "$out/consumer" serve "$1" "$2" 1 <"$fifo" 2>"$out/serve.$2.log" &
  pid=$!
  exec 3>"$fifo"
  wait_until 30 "the consumer to listen on $2" port_open 127.0.0.1 "$2" || { cat "$out/serve.$2.log" >&2; exit 1; }
}
stop() {
  exec 3>&-
  wait "$pid" || true
  rm -f "$fifo"
  sed 's/^/    /' "$out/serve.$port.log" | grep events >&2 || true
}

port=18300
echo "HTTP/1.1, wrk -t4 -c$conns, ${dur}s ($(uname -sm))"
echo
echo "| executors | route | req/s | p99 ms |"
echo "|---|---|---|---|"
for ex in 1 4; do
  port=$((port + 1)); start "$ex" "$port"
  for route in /native /hello /users/7; do
    set -- $(wrk_case "http://127.0.0.1:$port$route"); echo "| $ex | $route | $1 | $2 |"
  done
  stop
done
echo
echo "HTTP/1.1 pipelined 16 deep, wrk -t4 -c$conns"
echo
echo "| executors | route | req/s |"
echo "|---|---|---|"
for ex in 1 4; do
  port=$((port + 1)); start "$ex" "$port"
  for route in /native /hello; do
    set -- $(wrk_case "http://127.0.0.1:$port$route" -s "$here/pipeline.lua"); echo "| $ex | $route | $1 |"
  done
  stop
done
if command -v h2load >/dev/null; then
  echo
  echo "h2c, h2load -c64 -m16 -t4, ${dur}s"
  echo
  echo "| executors | route | req/s |"
  echo "|---|---|---|"
  for ex in 1 4; do
    port=$((port + 1)); start "$ex" "$port"
    for route in /native /native-task /hello; do
      echo "| $ex | $route | $(h2_case "http://127.0.0.1:$port$route") |"
    done
    stop
  done
fi
