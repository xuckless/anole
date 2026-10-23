#!/bin/bash
# RSS drift under steady load: one server image on 1 CPU, rested REST s, then
# wrk h1 c256 /json for DUR s while the cgroup's memory (current, anon,
# file, sock, kernel) and the process RSS are sampled every SAMPLE s.
#   bench/repro/rss-soak.sh <results-id> <image> [VAR=value ...]
set -u
bench=$(cd "$(dirname "$0")/.." && pwd)
. "$bench/lib/cpus.sh"
id=$1 img=$2; shift 2
out=$bench/results/$id/soak
mkdir -p "$out"
REST=${REST:-70} DUR=${DUR:-600} SAMPLE=${SAMPLE:-10}
envs=(); for e in "$@"; do envs+=(-e "$e"); done
docker rm -f soak-sut >/dev/null 2>&1
cid=$(docker run -d --name soak-sut --network host --cpuset-cpus "$SUT_CPUS_1" --cpus 1 --memory 2g --memory-swap 2g \
  --ulimit nofile=1048576:1048576 -e MODE=h1 -e WORKERS=1 -e TICK_HZ=0 "${envs[@]}" "$img")
for _ in $(seq 60); do curl -s -o /dev/null http://127.0.0.1:8080/json && break; sleep 0.5; done
pid=$(docker inspect -f '{{.State.Pid}}' soak-sut)
cg=/sys/fs/cgroup/system.slice/docker-$cid.scope
sleep "$REST"
docker rm -f soak-load >/dev/null 2>&1
docker run -d --name soak-load --network host --cpuset-cpus "$LOAD_CPUS" --ulimit nofile=1048576:1048576 \
  --entrypoint wrk anole-bench/loadgen -t8 -c256 -d${DUR}s --timeout 10s --latency http://127.0.0.1:8080/json >/dev/null
t0=$(date +%s)
echo "t_s,current_mb,anon_mb,file_mb,sock_mb,kernel_mb,rss_mb" >"$out/memory.csv"
while [ "$(docker inspect -f {{.State.Running}} soak-load 2>/dev/null)" = true ]; do
  t=$(( $(date +%s) - t0 ))
  st=$(awk '$1~/^(anon|file|sock|kernel)$/{printf "%s=%d ", $1, $2}' "$cg/memory.stat")
  rss=$(awk '/^VmRSS/{print $2}' /proc/$pid/status 2>/dev/null)
  eval "$st"
  printf '%d,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f\n' $t "$(echo "$(cat $cg/memory.current)/1048576" | bc -l)" \
    "$(echo "$anon/1048576" | bc -l)" "$(echo "$file/1048576" | bc -l)" "$(echo "$sock/1048576" | bc -l)" \
    "$(echo "$kernel/1048576" | bc -l)" "$(echo "${rss:-0}/1024" | bc -l)" >>"$out/memory.csv"
  sleep "$SAMPLE"
done
docker logs soak-load >"$out/wrk.txt" 2>&1; docker rm -f soak-load >/dev/null
docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}}' soak-sut >"$out/state"
docker logs soak-sut >"$out/server.log" 2>&1
docker rm -f soak-sut >/dev/null
python3 - "$out" <<'PY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1] + "/memory.csv")))
ts = [float(r["t_s"]) for r in rows]
def slope(k):
    ys = [float(r[k]) for r in rows]
    n = len(ys); mx = sum(ts) / n; my = sum(ys) / n
    return sum((x - mx) * (y - my) for x, y in zip(ts, ys)) / sum((x - mx) ** 2 for x in ts) * 3600
first, last = rows[1], rows[-1]
with open(sys.argv[1] + "/summary.txt", "w") as f:
    for k in ("rss_mb", "anon_mb", "current_mb"):
        line = f"{k}: {float(first[k]):.1f} at {first['t_s']} s -> {float(last[k]):.1f} at {last['t_s']} s; max {max(float(r[k]) for r in rows):.1f}; slope {slope(k):+.2f} MB/h"
        print(line); f.write(line + "\n")
PY
grep -E "Requests/sec|Socket errors|Non-2xx" "$out/wrk.txt" | tee -a "$out/summary.txt"
