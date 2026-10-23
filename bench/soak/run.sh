#!/bin/bash
# Soak/leak test of examples/full (bench/soak/README.md).
#   bench/soak/run.sh <results-id>                       # ReleaseSafe: 2 x 10 min at half capacity
#   OPT=Debug PHASES=1 PHASE=5m bench/soak/run.sh <id>    # Debug: SafeAllocator leak report
# Images: anole-bench/soak-full:<OPT> (bench/soak/Dockerfile), anole-bench/loadgen (oha).
#
# 1. Capacity probe: a fresh server, rested, every stream of load.sh flat out
#    for PROBE. Each stream's rate for the soak is FRAC of what it reached.
# 2. Soak: a fresh server; RSS, cgroup memory and CPU every 5 s from start to
#    exit. REST idle, then PHASES phases of PHASE each with IDLE idle between,
#    then IDLE idle, then SIGTERM; the allocator's leak report is in server.log.
set -u
bench=$(cd "$(dirname "$0")/.." && pwd)
. "$bench/lib/cpus.sh"
OPT=${OPT:-ReleaseSafe}
PHASE=${PHASE:-10m}
PHASES=${PHASES:-2}
IDLE=${IDLE:-120}
FRAC=${FRAC:-0.5}
REST=${REST:-70}
PROBE=${PROBE:-20s}
id=${1:-$(date +%Y%m%d-%H%M)-soak}
out=$bench/results/$id/soak/$OPT
rm -rf "$out"
mkdir -p "$out"
image=anole-bench/soak-full:$OPT
log() { echo "$(date +%H:%M:%S) $*" | tee -a "$out/run.log"; }
event() { echo "$(date +%s.%N),$1" >>"$out/events.csv"; }

start() {
  docker rm -f soak-sut >/dev/null 2>&1
  cid=$(docker run -d --name soak-sut --network host \
    --cpuset-cpus "$SUT_CPUS_1" --cpus 1 --memory 2g --memory-swap 2g \
    --ulimit nofile=1048576:1048576 --log-opt max-size=20m --log-opt max-file=3 \
    "$image" 8080 8443)
  for _ in $(seq 120); do
    curl -s -o /dev/null http://127.0.0.1:8080/ && curl -sk -o /dev/null https://127.0.0.1:8443/ && return 0
    sleep 0.5
  done
  log "server not ready"; docker logs soak-sut 2>&1 | tail -20 >>"$out/run.log"; exit 1
}
load() { # load <duration> <dir> [rates]
  docker run --rm --name soak-load --network host --cpuset-cpus "$LOAD_CPUS" \
    --ulimit nofile=1048576:1048576 -u "$(id -u):$(id -g)" \
    -v "$bench/soak:/soak:ro" -v "$out:/out" --entrypoint sh anole-bench/loadgen \
    /soak/load.sh "$1" "/out/$2" ${3:+/out/$3}
}

log "$image: probe"
start
sleep "$REST"
load "$PROBE" probe
docker rm -f soak-sut >/dev/null
python3 "$bench/soak/analyze.py" rates "$out/probe" "$FRAC" >"$out/rates.txt" || exit 1
log "rates at $FRAC of the probe: $(tr '\n' ' ' <"$out/rates.txt")"

log "$image: soak"
start
pid=$(docker inspect -f '{{.State.Pid}}' soak-sut)
cg=/sys/fs/cgroup/system.slice/docker-$cid.scope
echo "t,rss_kb,hwm_kb,threads,mem_current,anon,cpu_usec" >"$out/samples.csv"
(
  while [ -d "$cg" ] && [ -r "/proc/$pid/status" ]; do
    s=$(awk '/^VmRSS/{r=$2} /^VmHWM/{h=$2} /^Threads/{t=$2} END{print r","h","t}' "/proc/$pid/status" 2>/dev/null) || break
    echo "$(date +%s.%N),$s,$(cat "$cg/memory.current"),$(awk '$1=="anon"{print $2}' "$cg/memory.stat"),$(awk '$1=="usage_usec"{print $2}' "$cg/cpu.stat")" >>"$out/samples.csv"
    sleep 5
  done 2>/dev/null
) &
sampler=$!
event start
sleep "$REST"
for p in $(seq "$PHASES"); do
  log "phase $p ($PHASE)"
  event "phase$p-start"
  load "$PHASE" "phase$p" rates.txt
  event "phase$p-end"
  sleep "$IDLE"
done
log "SIGTERM"
event sigterm
docker kill -s TERM soak-sut >/dev/null
timeout 120 docker wait soak-sut >"$out/exit-code" || log "no exit within 120 s"
event exited
kill "$sampler" 2>/dev/null
# The leak report is the end of the log; the access log before it is rotated away.
docker logs soak-sut 2>&1 | grep -v '^info(access)' | tail -n 5000 >"$out/server.log"
docker logs soak-sut 2>&1 | tail -n 200 >"$out/server-tail.log"
docker rm -f soak-sut >/dev/null
python3 "$bench/soak/analyze.py" report "$out" | tee "$out/report.md"
