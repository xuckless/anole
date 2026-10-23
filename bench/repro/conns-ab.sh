#!/bin/bash
# Connection-count A/B repro for Anole: two server images, 1 CPU, epoll and
# io_uring, fresh server per invocation, rested REST s first, sides
# alternating per round.
#   bench/repro/conns-ab.sh <results-id> <image-a> <image-b>
# Cases (bench server, HTTP/1.1 + h2c on :8080):
#   c4096 c10000 c25000  wrk h1 /json, 30 s, --timeout 10s
#   park                 2,000 idle keep-alive connections woken at once
#                        behind wrk c=20000 (bench/tools/cmd/parkwake)
#   c256                 wrk h1 /json (regression)
#   h2c                  h2load c=256 m=10 /json (regression)
# The listener's Recv-Q (accept backlog) is sampled every 0.2 s; its peak is kept.
set -u
bench=$(cd "$(dirname "$0")/.." && pwd)
. "$bench/lib/cpus.sh"
id=$1 A=$2 B=$3
out=$bench/results/$id/conns-ab
mkdir -p "$out"
REST=${REST:-70}
RUNS=${RUNS:-2}
BACKENDS=${BACKENDS:-"epoll uring"}
CASES=${CASES:-"c4096 c10000 c25000 park c256 h2c"}
PARKWAKE=${PARKWAKE:?build bench/tools/cmd/parkwake and set PARKWAKE to the binary}
log() { echo "$(date +%H:%M:%S) $*" | tee -a "$out/run.log"; }

load_cmd() {
  local u=http://127.0.0.1:8080/json
  case $1 in
    c256) echo "wrk -t8 -c256 -d${DUR:-30}s --timeout 10s --latency $u" ;;
    c*) echo "wrk -t16 -c${1#c} -d${DUR:-30}s --timeout 10s --latency $u" ;;
    h2c) echo "h2load -t8 -c256 -m10 -D${DUR:-30} --warm-up-time=5 $u" ;;
    park) echo "/pw/parkwake -idle 2000 -hold ${HOLD:-15}s >/out/park.json 2>/out/park.err & \
until grep -q parked /out/park.err 2>/dev/null; do sleep 0.1; done; \
wrk -t16 -c20000 -d${DUR:-30}s --timeout 10s --latency $u; wait" ;;
  esac
}

one() { # one <backend> <side> <image> <case> <run>
  local dir=$out/$1/$4/$2-r$5
  mkdir -p "$dir"
  local extra=()
  [ "$1" = uring ] && extra=(--security-opt seccomp=unconfined --ulimit memlock=-1:-1)
  docker rm -f repro-sut >/dev/null 2>&1
  local cid
  cid=$(docker run -d --name repro-sut --network host --cpuset-cpus "$SUT_CPUS_1" --cpus 1 \
    --memory 2g --memory-swap 2g --ulimit nofile=1048576:1048576 "${extra[@]}" \
    -e MODE=h1 -e WORKERS=1 "$3")
  for _ in $(seq 60); do curl -s -o /dev/null http://127.0.0.1:8080/json && break; sleep 0.5; done
  sleep "$REST"
  (peak=0; while :; do q=$(ss -Hltn 'sport = :8080' | awk '{print $2; exit}'); [ "${q:-0}" -gt "$peak" ] && { peak=$q; echo "$peak" >"$dir/recvq-peak"; }; sleep 0.2; done) &
  local sampler=$!
  echo 0 >"$dir/recvq-peak"
  docker run --rm --name repro-load --network host --cpuset-cpus "$LOAD_CPUS" \
    --ulimit nofile=1048576:1048576 -v "$dir:/out" -v "$(dirname "$PARKWAKE"):/pw:ro" \
    --entrypoint sh anole-bench/loadgen -c "$(load_cmd "$4")" >"$dir/load.txt" 2>&1
  kill "$sampler" 2>/dev/null; wait "$sampler" 2>/dev/null
  local cg=/sys/fs/cgroup/system.slice/docker-$cid.scope
  cat "$cg/memory.peak" >"$dir/mem-peak" 2>/dev/null
  docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}}' repro-sut >"$dir/state"
  docker logs repro-sut >"$dir/server.log" 2>&1
  docker rm -f repro-sut >/dev/null
  log "$1 $4 $2 r$5: $(python3 "$bench/repro/conns-summary.py" one "$dir")"
}

for backend in $BACKENDS; do
  for r in $(seq "$RUNS"); do
    for c in $CASES; do
      if [ $((r % 2)) = 1 ]; then one "$backend" a "$A" "$c" "$r"; one "$backend" b "$B" "$c" "$r"
      else one "$backend" b "$B" "$c" "$r"; one "$backend" a "$A" "$c" "$r"; fi
    done
  done
done
python3 "$bench/repro/conns-summary.py" table "$out" | tee "$out/summary.md"
