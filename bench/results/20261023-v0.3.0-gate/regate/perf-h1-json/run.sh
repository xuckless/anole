#!/bin/bash
# h1 /json c256: perf stat with hardware counters only (no tracepoints), 10 s in the middle of a 25 s wrk run.
# Rested 70 s; 3 rounds, order rotating.
OUT=/home/xuckl/Dev/anole/bench/results/20261023-v0.3.0-gate/regate/perf-h1-json
EVENTS=task-clock,context-switches,cpu-migrations,cycles,instructions,branch-misses,L1-icache-load-misses,iTLB-load-misses,dTLB-load-misses
for r in 1; do
order="a b0 b"
for s in $order; do
  d=$OUT/r$r/$s; mkdir -p $d
  case $s in a) img=anole-bench/anole:v021; env=();; b0) img=anole-bench/anole:dx3; env=(-e ANOLE_CONSOLE=0);; b) img=anole-bench/anole:dx3; env=();; esac
  docker rm -f prof-sut >/dev/null 2>&1
  docker run -d --name prof-sut --network host --cpuset-cpus 2 --cpus 1 --memory 2g --memory-swap 2g \
    --ulimit nofile=1048576:1048576 -e MODE=h1 -e WORKERS=1 -e TICK_HZ=0 "${env[@]}" $img >/dev/null
  for i in $(seq 60); do curl -s -o /dev/null http://127.0.0.1:8080/json && break; sleep 0.5; done
  PID=$(docker inspect -f '{{.State.Pid}}' prof-sut)
  sleep 70
  docker run --rm --network host --cpuset-cpus 8-15,20-27 --ulimit nofile=1048576:1048576 --entrypoint wrk anole-bench/loadgen \
    -t8 -c256 -d25s --timeout 10s --latency http://127.0.0.1:8080/json > $d/wrk.txt 2>&1 &
  sleep 8
  docker run --rm --privileged --pid=host --cpuset-cpus 16-19 -v $d:/out anole-bench/perf \
    perf stat -p $PID -e $EVENTS -o /out/perf-stat.txt -- sleep 10
  wait
  docker rm -f prof-sut >/dev/null
  echo "$(date +%T) r$r $s: $(grep Requests/sec $d/wrk.txt)"
done
done
echo done
