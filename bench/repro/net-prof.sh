#!/bin/bash
# Profiles of one net-ab.sh cell, per side: a fresh server rested REST s,
# then the cell's load (3 s warm-up, then 33 s). Inside it: perf stat with
# the stall counters (cycles, instructions, cache and L1d misses, locked
# loads) for 15 s, then perf record -g (frame pointers) for 15 s, folded
# into a flame graph. Sides alternate in the order given. EV replaces the
# perf stat events, RECORD=0 skips the flame graph, TAG names the directory
# (prof-<backend>-<proto>-<size>-c<conns><TAG>).
#
#   TOOLS=<dir> bench/repro/net-prof.sh <results-id> <backend> <proto> <size> <conns> a=<image> b=<image>
set -u
bench=$(cd "$(dirname "$0")/.." && pwd)
. "$bench/lib/cpus.sh"
id=$1 be=$2 p=$3 sz=$4 n=$5; shift 5
declare -A image; names=()
for kv in "$@"; do image[${kv%%=*}]=${kv#*=}; names+=("${kv%%=*}"); done
out=$bench/results/$id/prof-$be-$p-$sz-c$n${TAG:-}
REST=${REST:-70} TOOLS=${TOOLS:?set TOOLS}
mkdir -p "$out"
log() { echo "$(date +%H:%M:%S) $*" | tee -a "$out/run.log"; }
ev=${EV:-cpu_core/cycles/u,cpu_core/instructions/u,cpu_core/cache-misses/,cpu_core/L1-dcache-load-misses/,cpu_core/mem_inst_retired.lock_loads/,cpu_core/mem_inst_retired.all_loads/}
RECORD=${RECORD:-1}
for s in "${names[@]}"; do
  d=$out/$s; mkdir -p "$d"
  ex=(); [ $be = uring ] && ex=(--security-opt seccomp=unconfined --ulimit memlock=-1:-1)
  docker rm -f net-sut >/dev/null 2>&1
  docker run -d --name net-sut --network host --cpuset-cpus "$SUT_CPUS_1" --cpus 1 --memory 2g --memory-swap 2g \
    --ulimit nofile=1048576:1048576 "${ex[@]}" -e MODE=h1 -e WORKERS=1 -e TICK_HZ=0 \
    -e NET_TCP_PORT=7000 -e NET_UDP_PORT=7001 "${image[$s]}" >/dev/null
  for _ in $(seq 60); do curl -s -o /dev/null localhost:8080/json && break; sleep 0.5; done
  pid=$(docker inspect -f '{{.State.Pid}}' net-sut)
  sleep "$REST"
  if [ $p = tcp ]; then tool=tcpload args="-addr 127.0.0.1:7000 -conns $n"
  else tool=udpload args="-addr 127.0.0.1:7001 -sockets $n -window 1"; fi
  docker run -d --name net-load --network host --cpuset-cpus "$LOAD_CPUS" --ulimit nofile=1048576:1048576 \
    -v "$TOOLS:/b:ro" --entrypoint /b/$tool anole-bench/loadgen $args -size $sz -warmup 3s -d 33s >/dev/null
  sleep 3
  docker run --rm --privileged --pid=host --cpuset-cpus 16-19 -v "$d:/out" anole-bench/perf perf stat -x, \
    -e "$ev" -p "$pid" -o /out/perf-stat.csv -- sleep 15
  echo 15 > "$d/stat-seconds"
  [ "$RECORD" = 1 ] && docker run --rm --privileged --pid=host --cpuset-cpus 16-19 -v "$d:/out" anole-bench/perf sh -c \
    "cd /tmp && perf record -F 999 -g -p $pid -o perf.data -- sleep 15 2>/out/perf-record.log; \
     perf script -i perf.data 2>/dev/null | gzip > /out/perf-script.txt.gz; \
     perf report -i perf.data --no-children --stdio --sort sym --percent-limit 0.3 -g none 2>/dev/null > /out/report-sym.txt"
  docker wait net-load >/dev/null; docker logs net-load > "$d/load.json" 2>&1; docker rm net-load >/dev/null
  docker rm -f net-sut >/dev/null
  log "$s counters: $(python3 "$bench/repro/net-ab-summary.py" counters "$d")"
  [ "$RECORD" = 1 ] && log "$s flame: $(python3 "$bench/repro/net-ab-summary.py" flame "$d" "$s: anole.net $p echo, $sz B x $n, $be, 1 CPU")"
done
log done
