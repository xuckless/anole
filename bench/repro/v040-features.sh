#!/bin/bash
# 0.4.0's new features on one Anole image, epoll and io_uring, rested REST s
# before each measured run, sides rotating, RUNS rounds:
#   fanin  /fanin on a 1-CPU front fetching /json from an upstream bench
#          server (2 CPUs) per request: h2 (UPSTREAM_H2C=1, the shared HTTP/2
#          client) against h1 (the HTTP/1.1 pool); wrk c256, upstream
#          connections counted mid-run
#   grpc   TestService/UnaryCall, one server on a Unix socket, h2c and TLS at
#          once (bench/servers/anole-grpc), grpcload 4 connections x 64 calls
#   sse    SSE_N subscribers (50 000) on a 1-CPU server: memory and CPU over
#          60 s idle, then 20 events and their fan-out delay to everyone
#   bench/repro/v040-features.sh <results-id> <bench image> <grpc image>
# TOOLS: the directory with grpcload and sseload. FEATURES: which to run.
set -u
bench=$(cd "$(dirname "$0")/.." && pwd)
. "$bench/lib/cpus.sh"
id=$1 IMG=$2 GIMG=$3
out=$bench/results/$id/features
REST=${REST:-70} RUNS=${RUNS:-2} DUR=${DUR:-30}
FEATURES=${FEATURES:-"fanin grpc sse"}
SSE_N=${SSE_N:-50000}
TOOLS=${TOOLS:?set TOOLS to the directory with grpcload and sseload}
log() { echo "$(date +%H:%M:%S) $*" | tee -a "$out/run.log"; }
mkdir -p "$out"

be_args() { [ "$1" = uring ] && echo "--security-opt seccomp=unconfined --ulimit memlock=-1:-1"; }
cg() { echo "/sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' "$1").scope"; }
usage() { awk '$1=="usage_usec"{print $2}' "$(cg "$1")/cpu.stat"; }
wait_http() { for _ in $(seq 60); do curl -s -o /dev/null "$1" && return 0; sleep 0.5; done; return 1; }

fanin_one() { # <backend> <side h2|h1> <run>
  local be=$1 side=$2 r=$3 d=$out/fanin/$1/$2-r$3; mkdir -p "$d"
  docker rm -f fan-up fan-sut >/dev/null 2>&1
  docker run -d --name fan-up --network host --cpuset-cpus 4,6 --cpus 2 --ulimit nofile=1048576:1048576 $(be_args $be) \
    -e MODE=h1 -e WORKERS=2 -e TICK_HZ=0 -e HTTP_PORT=8081 "$IMG" >/dev/null
  docker run -d --name fan-sut --network host --cpuset-cpus "$SUT_CPUS_1" --cpus 1 --ulimit nofile=1048576:1048576 $(be_args $be) \
    -e MODE=h1 -e WORKERS=1 -e TICK_HZ=0 -e UPSTREAM=http://127.0.0.1:8081/json -e UPSTREAM_H2C=$([ $side = h2 ] && echo 1 || echo 0) "$IMG" >/dev/null
  wait_http http://127.0.0.1:8081/json; wait_http http://127.0.0.1:8080/fanin
  sleep "$REST"
  local u0; u0=$(usage fan-sut)
  docker run -d --name fan-load --network host --cpuset-cpus "$LOAD_CPUS" --ulimit nofile=1048576:1048576 --entrypoint wrk \
    anole-bench/loadgen -t8 -c256 -d${DUR}s --timeout 10s --latency http://127.0.0.1:8080/fanin >/dev/null
  sleep $((DUR / 2))
  ss -Htn state established '( dport = :8081 )' | wc -l > "$d/upstream-conns"
  docker wait fan-load >/dev/null; docker logs fan-load > "$d/load.txt" 2>&1; docker rm fan-load >/dev/null
  echo $(( $(usage fan-sut) - u0 )) > "$d/cpu-usec"
  docker logs fan-sut > "$d/server.log" 2>&1
  docker rm -f fan-up fan-sut >/dev/null
  log "fanin $be $side r$r: $(grep -E 'Requests/sec' "$d/load.txt" | awk '{print $2}') req/s, p99 $(grep -E '^ +99%' "$d/load.txt" | awk '{print $2}'), upstream conns $(cat "$d/upstream-conns"), errors $(grep -oE 'Non-2xx or 3xx responses: [0-9]+|Socket errors.*' "$d/load.txt" | tr '\n' ' ')"
}

grpc_one() { # <backend> <side unix|h2c|tls> <run>
  local be=$1 side=$2 r=$3 d=$out/grpc/$1/$2-r$3; mkdir -p "$d" "$bench/.data/grpc-sock"
  docker rm -f grpc-sut >/dev/null 2>&1
  docker run -d --name grpc-sut --network host --cpuset-cpus "$SUT_CPUS_1" --cpus 1 --ulimit nofile=1048576:1048576 $(be_args $be) \
    -v "$bench/.data/grpc-sock:/sock:z" -v "$bench/.data/certs:/certs:ro,z" -e WORKERS=1 "$GIMG" >/dev/null
  sleep 2
  sleep "$REST"
  local t; case $side in unix) t="-target unix:/sock/grpc.sock";; h2c) t="-target 127.0.0.1:50051";; tls) t="-target 127.0.0.1:50052 -tls";; esac
  local u0; u0=$(usage grpc-sut)
  docker run --rm --network host --cpuset-cpus "$LOAD_CPUS" -v "$bench/.data/grpc-sock:/sock:z" -v "$TOOLS:/b:ro" --entrypoint /b/grpcload \
    anole-bench/loadgen $t -conns 4 -c 64 -d ${DUR}s > "$d/load.json" 2>&1
  echo $(( $(usage grpc-sut) - u0 )) > "$d/cpu-usec"
  docker logs grpc-sut > "$d/server.log" 2>&1
  docker rm -f grpc-sut >/dev/null
  log "grpc $be $side r$r: $(cat "$d/load.json")"
}

sse_one() { # <backend> <run>
  local be=$1 r=$2 d=$out/sse/$1/r$2; mkdir -p "$d"
  docker rm -f sse-sut sse-load >/dev/null 2>&1
  docker run -d --name sse-sut --network host --cpuset-cpus "$SUT_CPUS_1" --cpus 1 --memory 4g --memory-swap 4g \
    --ulimit nofile=1048576:1048576 $(be_args $be) -e MODE=h1 -e WORKERS=1 -e TICK_HZ=0 -e SSE=1 -e METRICS=1 "$IMG" >/dev/null
  wait_http http://127.0.0.1:8080/json
  local c; c=$(cg sse-sut); local pid; pid=$(docker inspect -f '{{.State.Pid}}' sse-sut)
  sleep "$REST"
  echo "idle-empty current $(cat $c/memory.current) rss_kb $(awk '/^VmRSS/{print $2}' /proc/$pid/status)" > "$d/memory.txt"
  docker run -d --name sse-load --network host --cpuset-cpus "$LOAD_CPUS" --ulimit nofile=1048576:1048576 -v "$TOOLS:/b:ro" \
    --entrypoint /b/sseload anole-bench/loadgen -n "$SSE_N" -ips 127.0.0.2,127.0.0.3,127.0.0.4,127.0.0.5 -rate 5000 \
    -idle 60s -events 20 -every 2s -settle 1500ms >/dev/null
  until docker logs sse-load 2>&1 | grep -q '^connected'; do sleep 1; done
  sleep 5
  local u0 t0; u0=$(usage sse-sut); t0=$(date +%s.%N)
  sleep 50
  local u1 t1; u1=$(usage sse-sut); t1=$(date +%s.%N)
  echo "idle-subscribed current $(cat $c/memory.current) rss_kb $(awk '/^VmRSS/{print $2}' /proc/$pid/status)" >> "$d/memory.txt"
  grep -E '^(anon|file|sock|kernel|kernel_stack|slab) ' $c/memory.stat > "$d/memory.stat"
  echo "idle cpu cores $(echo "($u1 - $u0) / 1000000 / ($t1 - $t0)" | bc -l)" >> "$d/memory.txt"
  curl -s localhost:8080/metrics | grep -E '^anole_sse_' > "$d/metrics-idle.txt"
  docker wait sse-load >/dev/null
  docker logs sse-load > "$d/load.out" 2>&1; docker rm sse-load >/dev/null
  echo "after-publish current $(cat $c/memory.current) rss_kb $(awk '/^VmRSS/{print $2}' /proc/$pid/status)" >> "$d/memory.txt"
  docker rm -f sse-sut >/dev/null
  log "sse $be r$r: $(tr '\n' ';' < "$d/memory.txt") $(grep -v '^connected\|^publishing' "$d/load.out" | python3 -c 'import json,sys; j=json.load(sys.stdin); print("connected", j["connected"], "errors", j["connect_errors"], "fan-out p50", round(j["p50_ms"],1), "p99", round(j["p99_ms"],1), "all median", round(j["all_ms_median"],1), "all max", round(j["all_ms_max"],1), "received", [e["received"] for e in j["events"]][:3], "ended", j["streams_ended"])' 2>&1)"
}

for be in epoll uring; do
  for r in $(seq "$RUNS"); do
    case " $FEATURES " in *" fanin "*)
      if [ $((r % 2)) = 1 ]; then fanin_one $be h2 $r; fanin_one $be h1 $r; else fanin_one $be h1 $r; fanin_one $be h2 $r; fi ;; esac
    case " $FEATURES " in *" grpc "*)
      case $((r % 3)) in 1) o="unix h2c tls";; 2) o="h2c tls unix";; 0) o="tls unix h2c";; esac
      for s in $o; do grpc_one $be $s $r; done ;; esac
    case " $FEATURES " in *" sse "*) sse_one $be $r ;; esac
  done
done
log done
