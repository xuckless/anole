#!/bin/bash
# Regression gate for Anole: N sides (an image, plus environment), 1 CPU,
# fresh server per run, rested REST s first, the side order rotating each
# round.
#   bench/repro/gate.sh <results-id> <name>=<image>[,VAR=value...] ...
#   e.g. gate.sh 20261023-gate a=anole-bench/anole:v021 b=anole-bench/anole:dx b0=anole-bench/anole:dx,ANOLE_CONSOLE=0
# Cases (bench server):
#   plain   wrk h1 /plaintext c256          json    wrk h1 /json c256
#   h2c     h2load c256 m10 /json (noWait)  h3      h2load h3 c64 m10 /json on :8443
#   asyncdb wrk h1 c256 /async-db?min=10&max=50&limit=20 on HttpArena's seeded
#           Postgres 18 (cpus 16-19, data/pgdb-seed.sql from $ARENA, pool 20)
#   wsecho  64 sockets echoing 64-byte messages on /ws/echo (bench/tools/cmd/wsecho)
# CASES run on epoll, URING_CASES on io_uring.
set -u
bench=$(cd "$(dirname "$0")/.." && pwd)
. "$bench/lib/cpus.sh"
id=$1; shift
out=$bench/results/$id/gate
mkdir -p "$out"
REST=${REST:-70} RUNS=${RUNS:-3} DUR=${DUR:-30}
CASES=${CASES:-"plain json h2c h3 asyncdb wsecho"}
URING_CASES=${URING_CASES:-"h3"}
TOOLS=${TOOLS:?set TOOLS to the directory with the wsecho binary}
ARENA=${ARENA:-$HOME/Dev/HttpArena}
names=() ; declare -A image envs
for spec in "$@"; do
  n=${spec%%=*}; rest=${spec#*=}
  names+=("$n"); image[$n]=${rest%%,*}
  [ "$rest" = "${rest#*,}" ] && envs[$n]="" || envs[$n]=${rest#*,}
done
log() { echo "$(date +%H:%M:%S) $*" | tee -a "$out/run.log"; }
printf '%s\n' "$@" > "$out/sides.txt"

pg_start() {
  docker rm -f gate-pg >/dev/null 2>&1
  docker run -d --rm --name gate-pg --network host --cpuset-cpus 16-19 --tmpfs /var/lib/postgresql:rw,size=2g \
    -e POSTGRES_USER=bench -e POSTGRES_PASSWORD=bench -e POSTGRES_DB=benchmark \
    -v "$ARENA/data/pgdb-seed.sql:/docker-entrypoint-initdb.d/seed.sql:ro,z" postgres:18 -c max_connections=256 >/dev/null
  for _ in $(seq 90); do
    docker exec gate-pg psql -U bench -d benchmark -tAc 'SELECT 1 FROM items LIMIT 1' 2>/dev/null | grep -q 1 && return 0
    sleep 1
  done
  echo "postgres did not come up" >&2; exit 1
}

load_cmd() {
  local u=http://127.0.0.1:8080
  local pct="cut -f3 /tmp/req.log | sort -n | awk '{a[NR]=\$1} END {printf \"percentiles: p50 %d us p99 %d us n %d\\n\", a[int(NR*0.5)], a[int(NR*0.99)], NR}'"
  case $1 in
    plain) echo "wrk -t8 -c256 -d${DUR}s --timeout 10s --latency $u/plaintext" ;;
    json) echo "wrk -t8 -c256 -d${DUR}s --timeout 10s --latency $u/json" ;;
    asyncdb) echo "wrk -t8 -c256 -d${DUR}s --timeout 10s --latency '$u/async-db?min=10&max=50&limit=20'" ;;
    h2c) echo "h2load -t8 -c256 -m10 -D$DUR --warm-up-time=5 --log-file=/tmp/req.log $u/json; $pct" ;;
    h3) echo "h2load -t8 -c64 -m10 -D$DUR --warm-up-time=5 --alpn-list=h3 --log-file=/tmp/req.log https://127.0.0.1:8443/json; $pct" ;;
    wsecho) echo "/tools/wsecho -url ws://127.0.0.1:8080/ws/echo -c 64 -d ${DUR}s > /out/wsecho.json" ;;
  esac
}

one() { # one <backend> <side> <case> <run>
  local be=$1 side=$2 c=$3 r=$4
  local dir=$out/$be/$c/$side-r$r
  mkdir -p "$dir"
  local extra=() mode=h1 e
  [ "$c" = h3 ] && mode=h3
  [ "$be" = uring ] && extra+=(--security-opt seccomp=unconfined --ulimit memlock=-1:-1)
  [ "$c" = asyncdb ] && extra+=(-e ARENA_DATABASE_URL=postgres://bench:bench@127.0.0.1:5432/benchmark)
  IFS=, read -ra kv <<<"${envs[$side]}"; for e in "${kv[@]}"; do extra+=(-e "$e"); done
  docker rm -f gate-sut >/dev/null 2>&1
  local cid
  cid=$(docker run -d --name gate-sut --network host --cpuset-cpus "$SUT_CPUS_1" --cpus 1 \
    --memory 2g --memory-swap 2g --ulimit nofile=1048576:1048576 "${extra[@]}" \
    -v "$bench/.data/certs:/certs:ro,z" -e MODE=$mode -e WORKERS=1 -e TICK_HZ=0 "${image[$side]}")
  for _ in $(seq 60); do
    if [ $mode = h3 ]; then curl -sk -o /dev/null https://127.0.0.1:8443/json && break
    else curl -s -o /dev/null http://127.0.0.1:8080/json && break; fi
    sleep 0.5
  done
  sleep "$REST"
  local cg=/sys/fs/cgroup/system.slice/docker-$cid.scope
  local u0; u0=$(awk '$1=="usage_usec"{print $2}' "$cg/cpu.stat")
  docker run --rm --name gate-load --network host --cpuset-cpus "$LOAD_CPUS" \
    --ulimit nofile=1048576:1048576 --tmpfs /tmp:size=4g -v "$dir:/out" -v "$TOOLS:/tools:ro" \
    --entrypoint sh anole-bench/loadgen -c "$(load_cmd "$c")" >"$dir/load.txt" 2>&1
  echo "$(( $(awk '$1=="usage_usec"{print $2}' "$cg/cpu.stat") - u0 ))" >"$dir/cpu-usec"
  cat "$cg/memory.peak" >"$dir/mem-peak" 2>/dev/null
  docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}}' gate-sut >"$dir/state"
  docker logs gate-sut >"$dir/server.log" 2>&1
  docker rm -f gate-sut >/dev/null
  log "$be $c $side r$r: $(python3 "$bench/repro/gate-summary.py" one "$dir")"
}

case " $CASES " in *" asyncdb "*) pg_start ;; esac
for r in $(seq "$RUNS"); do
  k=$(( (r - 1) % ${#names[@]} ))
  order=("${names[@]:$k}" "${names[@]:0:$k}")
  for be in epoll uring; do
    [ $be = epoll ] && cs=$CASES || cs=$URING_CASES
    for c in $cs; do
      for s in "${order[@]}"; do one "$be" "$s" "$c" "$r"; done
    done
  done
done
docker rm -f gate-pg >/dev/null 2>&1
python3 "$bench/repro/gate-summary.py" table "$out" | tee "$out/summary.md"
