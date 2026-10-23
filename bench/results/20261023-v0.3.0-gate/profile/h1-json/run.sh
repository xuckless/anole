#!/bin/bash
# h1 /json c256 (wrk), A (v0.2.1), B (dx-pass 5d25576, ANOLE_CONSOLE=0), Bslim (5d25576 -Dslim=true): perf stat 5 s, then perf record 5 s,
# in the middle of a 30 s run; rested 70 s; one round each, A first.
OUT=/home/xuckl/Dev/anole/bench/results/20261023-v0.3.0-gate/profile/h1-json
EVENTS=task-clock,cycles,instructions,branch-misses,L1-icache-load-misses,iTLB-load-misses,dTLB-load-misses,context-switches,page-faults,raw_syscalls:sys_enter,syscalls:sys_enter_read,syscalls:sys_enter_recvfrom,syscalls:sys_enter_write,syscalls:sys_enter_writev,syscalls:sys_enter_sendto,syscalls:sys_enter_sendmsg,syscalls:sys_enter_epoll_wait,syscalls:sys_enter_epoll_pwait,syscalls:sys_enter_epoll_ctl,syscalls:sys_enter_futex,syscalls:sys_enter_clock_gettime,syscalls:sys_enter_io_uring_enter
for s in a b bslim; do
  d=$OUT/$s; mkdir -p $d
  case $s in a) img=anole-bench/anole:v021; env=();; b) img=anole-bench/anole:dx2; env=(-e ANOLE_CONSOLE=0);; bslim) img=anole-bench/anole:dx2slim; env=();; esac
  c=$(docker create $img); docker cp -q $c:/usr/local/bin/anole-bench /tmp/claude-1000/-home-xuckl-Dev-anole/c1c2be6d-f2fa-4d37-a045-8c474b8f1549/scratchpad/bin-$s; docker rm $c >/dev/null
  size -A /tmp/claude-1000/-home-xuckl-Dev-anole/c1c2be6d-f2fa-4d37-a045-8c474b8f1549/scratchpad/bin-$s | grep -E '^\.(text|rodata|data|bss) |Total' > $d/binary-size.txt; ls -l /tmp/claude-1000/-home-xuckl-Dev-anole/c1c2be6d-f2fa-4d37-a045-8c474b8f1549/scratchpad/bin-$s | awk '{print "file", $5}' >> $d/binary-size.txt; rm -f /tmp/claude-1000/-home-xuckl-Dev-anole/c1c2be6d-f2fa-4d37-a045-8c474b8f1549/scratchpad/bin-$s
  docker rm -f prof-sut >/dev/null 2>&1
  docker run -d --name prof-sut --network host --cpuset-cpus 2 --cpus 1 --memory 2g --memory-swap 2g \
    --ulimit nofile=1048576:1048576 -e MODE=h1 -e WORKERS=1 -e TICK_HZ=0 "${env[@]}" $img >/dev/null
  for i in $(seq 60); do curl -s -o /dev/null http://127.0.0.1:8080/json && break; sleep 0.5; done
  PID=$(docker inspect -f '{{.State.Pid}}' prof-sut)
  sleep 70
  docker run --rm --network host --cpuset-cpus 8-15,20-27 --ulimit nofile=1048576:1048576 --entrypoint wrk anole-bench/loadgen \
    -t8 -c256 -d30s --timeout 10s --latency http://127.0.0.1:8080/json > $d/wrk.txt 2>&1 &
  sleep 12
  docker run --rm --privileged --pid=host --cpuset-cpus 16-19 -v $d:/out anole-bench/perf sh -c "cd /tmp; \
    perf stat -p $PID -e $EVENTS -o /out/perf-stat.txt -- sleep 5; \
    perf record -F 2999 -g -p $PID -o perf.data -- sleep 5 2>/out/perf-record.log; \
    perf report -i perf.data --no-children --sort sym --stdio -g none --percent-limit 0.05 2>/dev/null > /out/report-self.txt; \
    perf report -i perf.data --children --sort sym --stdio -g none --percent-limit 0.5 2>/dev/null > /out/report-children.txt; \
    perf report -i perf.data --no-children --sort dso --stdio -g none 2>/dev/null > /out/report-dso.txt; \
    perf report -i perf.data --no-children --sort sym --stdio -g caller,0.5,callee --percent-limit 1.5 2>/dev/null | head -600 > /out/report-callers.txt"
  wait
  docker rm -f prof-sut >/dev/null
  echo "$(date +%T) $s: $(grep Requests/sec $d/wrk.txt)"
done
echo done
