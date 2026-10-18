#!/bin/sh
# Anole against Fiber v3 on one machine, as a Markdown table on stdout.
#   bench/run.sh [duration-seconds]   (default 15)
# Needs wrk, h2load (nghttp2), ghz and Go. Each case gets a warm-up run and
# then three measured runs; the table shows the median run's req/s and p99.
#  - HTTP/1.1: wrk against both servers (/plaintext, /json, /users/:id).
#  - HTTP/2: h2load against Anole's h2c (Fiber has no HTTP/2).
#  - gRPC unary: ghz against Anole and grpc-go's interop server (Fiber has
#    no gRPC, so grpc-go stands in as the reference).
# Server and load generator share the machine, so absolute numbers are
# lower than on separate boxes; the comparison is what counts.
set -eu
dur=${1:-15}
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
pids=""
trap 'for p in $pids; do kill $p 2>/dev/null || true; done; rm -rf "$work"' EXIT

(cd "$root" && zig build bench-server grpc-interop-server -Doptimize=ReleaseFast)
(cd "$root/bench/fiber" && go build -o "$work/fiber-bench" .)
GOBIN=$work go install google.golang.org/grpc/interop/server@v1.84.0

"$root/zig-out/bin/bench-server" 18080 >"$work/anole.log" 2>&1 & pids="$pids $!"
"$work/fiber-bench" 18090 >"$work/fiber.log" 2>&1 & pids="$pids $!"
"$root/zig-out/bin/grpc-interop-server" 18100 >"$work/anole-grpc.log" 2>&1 & pids="$pids $!"
"$work/server" --port=18110 >"$work/go-grpc.log" 2>&1 & pids="$pids $!"
sleep 2

# median of three "rps p99ms" lines, by rps
median() { sort -n | sed -n 2p; }

wrk_case() { # url -> "rps p99ms"
  wrk -t4 -c256 -d5s "$1" >/dev/null
  for i in 1 2 3; do
    wrk -t4 -c256 -d"${dur}s" --latency "$1" | awk '
      /Requests\/sec/ {rps=$2}
      $1=="99%" {v=$2; if (v ~ /us$/) {sub(/us/,"",v); v/=1000} else if (v ~ /ms$/) {sub(/ms/,"",v)} else if (v ~ /s$/) {sub(/s/,"",v); v*=1000}; p=v}
      END {printf "%d %.2f\n", rps, p}'
  done | median
}

h2_case() { # url -> "rps p99ms"
  h2load -c64 -m10 -t4 -D5 "$1" >/dev/null
  for i in 1 2 3; do
    h2load -c64 -m10 -t4 -D"$dur" "$1" | awk '
      /^finished in/ {gsub(/,/,""); rps=$4}
      /^request *:/ {v=$7; if (v ~ /us$/) {sub(/us/,"",v); v/=1000} else if (v ~ /ms$/) {sub(/ms/,"",v)} else if (v ~ /s$/) {sub(/s/,"",v); v*=1000}; m=v}
      END {printf "%d %.2f\n", rps, m}'
  done | median
}

ghz_case() { # port -> "rps p99ms"
  set -- --insecure --proto "$root/tests/grpc/proto/grpc/testing/test.proto" \
    --import-paths "$root/tests/grpc/proto" --call grpc.testing.TestService/UnaryCall \
    -d '{"response_size":13,"payload":{"body":"SGVsbG8sIFdvcmxkIQ=="}}' -c 64 "127.0.0.1:$1"
  ghz "$@" --duration 5s >/dev/null
  for i in 1 2 3; do
    ghz "$@" --duration "${dur}s" --format json | python3 -I -c '
import json,sys; r=json.load(sys.stdin)
p99=[d["latency"] for d in r["latencyDistribution"] if d["percentage"]==99][0]/1e6
print("%d %.2f" % (r["rps"], p99))'
  done | median
}

row() { # name anole-result other-result
  set -- "$1" $2 $3
  ratio=$(awk -v a="$2" -v b="$4" 'BEGIN { if (b>0) printf "%.2fx", a/b; else print "-" }')
  printf '| %s | %s | %s ms | %s | %s ms | %s |\n' "$1" "$2" "$3" "$4" "$5" "$ratio"
}

echo "| Case | Anole req/s | Anole p99 | Other req/s | Other p99 | Anole/Other |"
echo "| --- | ---: | ---: | ---: | ---: | ---: |"
for path in /plaintext /json /users/42; do
  row "HTTP/1.1 GET $path (vs Fiber)" "$(wrk_case http://127.0.0.1:18080$path)" "$(wrk_case http://127.0.0.1:18090$path)"
done
a=$(h2_case http://127.0.0.1:18080/plaintext)
printf '| HTTP/2 h2c GET /plaintext, 64 conns x 10 streams (Fiber: none) | %s | %s ms | - | - | - |\n' $a
row "gRPC unary (vs grpc-go 1.84)" "$(ghz_case 18100)" "$(ghz_case 18110)"
