#!/bin/bash
# A/B of the raw TCP/UDP echo listeners (anole.net) between two bench images,
# the unchanged bench app (NET_TCP_PORT/NET_UDP_PORT, TcpEcho/UdpEcho in
# bench/servers/anole/src/features.zig). One executor on the 1-CPU SUT.
#
# Cells: protocol x message size x connections (UDP: client sockets) x
# backend. UDP's large size is 2048 B, the default max_datagram of
# anole.net.udp (larger datagrams are dropped as truncated). Each connection keeps one message outstanding (tcpload; udpload
# -window 1). Every run starts a fresh server, rests REST s, then loads it
# (3 s warm-up, DUR s counted). RUNS runs per side and cell, A and B
# alternating (A B, B A, ...). perf stat counts the server's user-space
# instructions and cycles over the counted part (whole-run counts divided by
# the messages echoed, not the D19 fixed-count method). A rerun with the same
# results id skips the runs that already have a result.
#
#   TOOLS=<dir with tcpload, udpload> bench/repro/net-ab.sh <results-id> a=<image> b=<image>
set -u
bench=$(cd "$(dirname "$0")/.." && pwd)
. "$bench/lib/cpus.sh"
id=$1; shift
declare -A image; names=()
for kv in "$@"; do image[${kv%%=*}]=${kv#*=}; names+=("${kv%%=*}"); done
out=$bench/results/$id
REST=${REST:-70} RUNS=${RUNS:-5} DUR=${DUR:-15} WARM=3
BACKENDS=${BACKENDS:-"epoll uring"} PROTOS=${PROTOS:-"tcp udp"}
SIZES=${SIZES:-"64 16384"} UDP_SIZES=${UDP_SIZES:-"64 2048"} CONNS=${CONNS:-"256 4096"}
TOOLS=${TOOLS:?set TOOLS to the directory with tcpload and udpload}
mkdir -p "$out"
log() { echo "$(date +%H:%M:%S) $*" | tee -a "$out/run.log"; }
cg() { echo "/sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' "$1").scope"; }
usage() { awk '$1=="usage_usec"{print $2}' "$(cg "$1")/cpu.stat"; }

one() { # <backend> <proto> <size> <conns> <side> <run>
  local be=$1 p=$2 sz=$3 n=$4 s=$5 r=$6
  local d=$out/$be/$p-$sz-c$n/$s-r$r
  grep -qE 'msgs_per_s|received_per_s' "$d/load.json" 2>/dev/null && return  # done before a pause
  mkdir -p "$d"
  local ex=(); [ $be = uring ] && ex=(--security-opt seccomp=unconfined --ulimit memlock=-1:-1)
  docker rm -f net-sut >/dev/null 2>&1
  docker run -d --name net-sut --network host --cpuset-cpus "$SUT_CPUS_1" --cpus 1 --memory 2g --memory-swap 2g \
    --ulimit nofile=1048576:1048576 "${ex[@]}" -e MODE=h1 -e WORKERS=1 -e TICK_HZ=0 \
    -e NET_TCP_PORT=7000 -e NET_UDP_PORT=7001 "${image[$s]}" >/dev/null
  for _ in $(seq 60); do curl -s -o /dev/null localhost:8080/json && break; sleep 0.5; done
  local pid; pid=$(docker inspect -f '{{.State.Pid}}' net-sut)
  docker exec net-sut ls -l /proc/1/fd 2>/dev/null | grep -oE 'eventpoll|io_uring' | sort -u | tr '\n' ' ' > "$d/backend"
  sleep "$REST"
  local tool args
  if [ $p = tcp ]; then tool=tcpload args="-addr 127.0.0.1:7000 -conns $n"
  else tool=udpload args="-addr 127.0.0.1:7001 -sockets $n -window 1"; fi
  docker run -d --name net-load --network host --cpuset-cpus "$LOAD_CPUS" --ulimit nofile=1048576:1048576 \
    -v "$TOOLS:/b:ro" --entrypoint /b/$tool anole-bench/loadgen $args -size $sz -warmup ${WARM}s -d ${DUR}s >/dev/null
  sleep "$WARM"
  local u0; u0=$(usage net-sut)
  docker run --rm --privileged --pid=host --cpuset-cpus 16-19 -v "$d:/out" anole-bench/perf perf stat -x, \
    -e instructions:u,cycles:u,task-clock -p "$pid" -o /out/perf-stat.csv -- sleep "$DUR"
  echo $(( $(usage net-sut) - u0 )) > "$d/cpu-usec"; echo "$DUR" > "$d/dur"
  docker wait net-load >/dev/null; docker logs net-load > "$d/load.json" 2>&1; docker rm net-load >/dev/null
  docker logs net-sut > "$d/server.log" 2>&1
  docker rm -f net-sut >/dev/null
  log "$be $p $sz c$n $s r$r: $(python3 "$bench/repro/net-ab-summary.py" one "$d")"
}

log "start: ${names[*]} = $(for s in "${names[@]}"; do echo -n "${image[$s]}@$(docker inspect -f '{{.Id}}' "${image[$s]}" | cut -c8-19) "; done)REST=$REST RUNS=$RUNS DUR=$DUR"
for be in $BACKENDS; do
  for p in $PROTOS; do
    sizes=$SIZES; [ $p = udp ] && sizes=$UDP_SIZES
    for sz in $sizes; do
      for n in $CONNS; do
        for r in $(seq "$RUNS"); do
          if [ $((r % 2)) = 1 ]; then o="${names[*]}"; else o=$(printf '%s\n' "${names[@]}" | tac | tr '\n' ' '); fi
          for s in $o; do one $be $p $sz $n $s $r; done
        done
        log "cell $be $p $sz c$n: $(python3 "$bench/repro/net-ab-summary.py" cell "$out/$be/$p-$sz-c$n")"
      done
    done
  done
done
log done
