#!/bin/bash
# Downloads over a 50 ms RTT: HTTP/3 and HTTP/2 against HTTP/1.1 over TLS,
# from one
# bench server (MODE=h3: TLS h1/h2 and h3 on :8443, /static from MEDIA).
#
# The server and the client each run in their own network namespace on
# Docker's default bridge (veth, MTU 1500), never --network host. Each gets
# `tc qdisc ... netem delay 25ms` on its own eth0 (the container's end of
# the veth), so a round trip is 50 ms and the host's interfaces are never
# touched. The qdiscs are deleted after each run and go away with the
# containers anyway.
#
# Cells: size x parallel connections; each connection fetches one file at
# a time (h2load -m 1), N files per connection. Every run starts a fresh
# server on the 1-CPU SUT and rests REST s first; the protocols (PROTOS)
# rotate their order each run, RUNS runs each.
#
#   MEDIA=<dir with 1m.bin, 10m.bin> bench/repro/netem.sh <results-id> <image>
#
# To add for the #151 fix A/B (main vs fix): the same cells, plus one plain
# no-delay h3 static cell, to show the fix costs nothing on loopback.
set -u
bench=$(cd "$(dirname "$0")/.." && pwd)
. "$bench/lib/cpus.sh"
id=$1 IMG=$2
out=$bench/results/$id/netem
REST=${REST:-70} RUNS=${RUNS:-5} DELAY=${DELAY:-25ms}
BACKENDS=${BACKENDS:-"epoll uring"} PROTOS=${PROTOS:-"h1 h2 h3"} CELLS=${CELLS:-"1m:1:20 1m:4:10 10m:1:5 10m:4:3"}
MEDIA=${MEDIA:?set MEDIA to the directory with the files}
mkdir -p "$out"
log() { echo "$(date +%H:%M:%S) $*" | tee -a "$out/run.log"; }
netem() { # <container> add|del
  if [ "$2" = add ]; then
    docker run --rm --network container:$1 --cap-add NET_ADMIN anole-bench/tc tc qdisc add dev eth0 root netem delay $DELAY limit 100000
  else
    docker run --rm --network container:$1 --cap-add NET_ADMIN anole-bench/tc tc qdisc del dev eth0 root 2>/dev/null
  fi
}
cleanup() {
  local c; for c in net-cli net-sut; do docker inspect $c >/dev/null 2>&1 && { netem $c del; docker rm -f $c >/dev/null; }; done
}
trap cleanup EXIT

one() { # <backend> <proto h1|h2|h3> <size> <conns> <files per conn> <run>
  local be=$1 p=$2 sz=$3 c=$4 n=$5 r=$6
  local d=$out/$be/$sz-c$c/$p-r$r; mkdir -p "$d"
  local ex=(); [ $be = uring ] && ex=(--security-opt seccomp=unconfined --ulimit memlock=-1:-1)
  cleanup
  docker run -d --name net-sut --cpuset-cpus "$SUT_CPUS_1" --cpus 1 --memory 2g --memory-swap 2g \
    --ulimit nofile=1048576:1048576 "${ex[@]}" -v "$bench/.data/certs:/certs:ro,z" -v "$MEDIA:/media:ro,z" \
    -e MODE=h3 -e WORKERS=1 -e TICK_HZ=0 "$IMG" >/dev/null
  docker run -d --name net-cli --cpuset-cpus "$LOAD_CPUS" --entrypoint sleep anole-bench/loadgen infinity >/dev/null
  local ip; ip=$(docker inspect -f '{{.NetworkSettings.Networks.bridge.IPAddress}}' net-sut)
  for _ in $(seq 60); do docker exec net-cli curl -sk -o /dev/null https://$ip:8443/static/1m.bin && break; sleep 0.5; done
  docker exec net-sut ls -l /proc/1/fd 2>/dev/null | grep -oE 'eventpoll|io_uring' | sort -u | tr '\n' ' ' > "$d/backend"
  netem net-sut add; netem net-cli add
  docker exec net-cli curl -sk -o /dev/null -w 'tcp connect (1 RTT) %{time_connect} s\n' https://$ip:8443/static/1m.bin > "$d/rtt.txt"
  sleep "$REST"
  local alpn; case $p in h1) alpn=http/1.1;; h2) alpn=h2;; h3) alpn=h3;; esac
  local cg=/sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' net-sut).scope
  local u0; u0=$(awk '$1=="usage_usec"{print $2}' $cg/cpu.stat)
  docker exec net-cli h2load -n $((c * n)) -c $c -m 1 --alpn-list=$alpn https://$ip:8443/static/$sz.bin > "$d/load.txt" 2>&1
  echo $(( $(awk '$1=="usage_usec"{print $2}' $cg/cpu.stat) - u0 )) > "$d/cpu-usec"
  docker run --rm --network container:net-cli anole-bench/tc tc qdisc show dev eth0 > "$d/qdisc.txt" 2>/dev/null
  docker logs net-sut > "$d/server.log" 2>&1
  cleanup
  log "$be $sz c$c $p r$r: $(python3 "$bench/repro/netem-summary.py" one "$d")"
}

log "start: $IMG@$(docker inspect -f '{{.Id}}' "$IMG" | cut -c8-19) DELAY=$DELAY each way REST=$REST RUNS=$RUNS"
for be in $BACKENDS; do
  for cell in $CELLS; do
    IFS=: read -r sz c n <<<"$cell"
    for r in $(seq "$RUNS"); do
      read -ra ps <<<"$PROTOS"; k=$(( (r - 1) % ${#ps[@]} ))
      for p in "${ps[@]:$k}" "${ps[@]:0:$k}"; do one $be $p $sz $c $n $r; done
    done
    log "cell $be $sz c$c: $(python3 "$bench/repro/netem-summary.py" cell "$out/$be/$sz-c$c")"
  done
done
log done
