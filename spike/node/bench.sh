#!/bin/sh
# Throwaway: the addon under Node and Bun vs Bun.serve and node:http, with
# wrk (-t4 -c256, median of three). A Markdown table on stdout.
#   spike/node/bench.sh [duration-seconds]
set -eu
here=$(cd "$(dirname "$0")" && pwd)
dur=${1:-8}
median() { sort -n | sed -n 2p; }
run() { # url
  wrk -t4 -c256 -d2s "$1" >/dev/null
  for i in 1 2 3; do
    wrk -t4 -c256 -d"${dur}s" --latency "$1" | awk '
      /Requests\/sec/ {rps=$2}
      $1=="99%" {v=$2; if (v ~ /us$/) {sub(/us/,"",v); v/=1000} else if (v ~ /ms$/) {sub(/ms/,"",v)} else if (v ~ /s$/) {sub(/s/,"",v); v*=1000}; p=v}
      END {printf "%d %.2f\n", rps, p}'
  done | median
}
serve() { # name port cmd...
  name=$1; port=$2; shift 2
  "$@" 2>"$here/build/$name.log" &
  pid=$!; sleep 1.5
}
finish() { kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; tail -1 "$here/build/$name.log" | grep -q batches && sed 's/^/    /' "$here/build/$name.log" | tail -1 >&2 || true; }
echo "| server | executors | route | req/s | p99 ms |"
echo "|---|---|---|---|---|"
port=18600
for rt in node bun; do
  for ex in 1 4; do
    port=$((port + 1))
    serve "$rt-$ex" $port $rt "$here/server.js" $ex $port
    for r in /native /hello /users/7; do
      set -- $(run "http://127.0.0.1:$port$r"); echo "| anole-node spike ($rt) | $ex | $r | $1 | $2 |"
    done
    finish
  done
done
port=$((port + 1)); serve bun-serve $port bun "$here/bun-serve.js" $port
for r in /native /hello /users/7; do set -- $(run "http://127.0.0.1:$port$r"); echo "| Bun.serve | 1 (JS thread) | $r | $1 | $2 |"; done
finish
port=$((port + 1)); serve node-http $port node "$here/node-http.js" $port
for r in /hello /users/7; do set -- $(run "http://127.0.0.1:$port$r"); echo "| node:http | 1 (JS thread) | $r | $1 | $2 |"; done
finish
