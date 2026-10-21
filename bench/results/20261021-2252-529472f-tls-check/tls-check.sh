#!/bin/bash
# 1-CPU h1-TLS /plaintext, A vs B interleaved (fresh server each), plus a plain h1
# control; epoll and io_uring. wrk as in the suite: 5 s warm-up, 15 s run, -t 8 -c 256.
# PERF=1 adds a 10 s perf record (on cpus 16-19) during an extra run of each.
OUT=${OUT:?}; A=${A:-anole-bench/anole:a5}; B=${B:-anole-bench/anole:b74}; mkdir -p $OUT
wrk() { # $1 url $2 duration $3 outfile
  docker run --rm --network host --cpuset-cpus 8-15,20-27 --ulimit nofile=1048576:1048576 --entrypoint wrk \
    anole-bench/loadgen -t 8 -c 256 -d $2 --timeout 10s --latency $1 > $3 2>&1
}
rps() { awk '/Requests\/sec/{printf "%.1fk", $2/1000}' $1; }
for be in uring epoll; do
  extra=(); [ $be = uring ] && extra=(--security-opt seccomp=unconfined --ulimit memlock=-1:-1)
  runs=(A B A B A B A-h1 B-h1); [ -n "${PERF:-}" ] && runs=(A-perf B-perf)
  for r in "${runs[@]}"; do
    v=${r%%-*}; img=$A; [ $v = B ] && img=$B
    mode=tls; url=https://127.0.0.1:8443/plaintext
    case $r in *-h1) mode=h1; url=http://127.0.0.1:8080/plaintext;; esac
    name=tls-$be-$v
    docker run -d --rm --name $name --network host --cpuset-cpus 2 --cpus 1 --memory 2048m --memory-swap 2048m \
      --ulimit nofile=1048576:1048576 -v /home/xuckl/Dev/anole/bench/.data/certs:/certs:ro,z "${extra[@]}" -e MODE=$mode -e WORKERS=1 $img >/dev/null
    for i in $(seq 50); do curl -skf -o /dev/null $url && break; sleep 0.2; done
    n=$(ls $OUT | grep -c "^$be-$r-") ; f=$OUT/$be-$r-$n.txt
    wrk $url 5s /dev/null
    if [ -n "${PERF:-}" ]; then
      PID=$(pgrep -n -x anole-bench)
      wrk $url 15s $f &
      sleep 3
      docker run --rm --privileged --pid=host --cpuset-cpus 16-19 -v $OUT:/out anole-bench/perf sh -c "cd /tmp; \
        perf record -F 2999 -g -p $PID -o perf.data -- sleep 10 2>/dev/null; \
        perf report -i perf.data --no-children --sort sym --stdio -g none 2>/dev/null | head -70 > /out/$be-$v-perf-self.txt; \
        perf report -i perf.data --children --sort sym --stdio -g none 2>/dev/null | head -90 > /out/$be-$v-perf-children.txt"
      wait
    else
      wrk $url 15s $f
    fi
    echo "$be $r ($mode): $(rps $f)" | tee -a $OUT/summary.txt
    docker stop $name >/dev/null
  done
done
