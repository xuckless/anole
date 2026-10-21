#!/bin/bash
OUT=${OUT:?}
EVENTS=task-clock,page-faults,context-switches,raw_syscalls:sys_enter,syscalls:sys_enter_epoll_ctl,syscalls:sys_enter_mprotect,syscalls:sys_enter_munmap,syscalls:sys_enter_madvise,syscalls:sys_enter_recvfrom,syscalls:sys_enter_sendto,syscalls:sys_enter_recvmsg
g() { docker run --rm --network host --cpuset-cpus 8-15,20-27 --security-opt seccomp=unconfined --ulimit memlock=-1:-1 \
  --ulimit nofile=1048576:1048576 --entrypoint gcannon anole-bench/loadgen http://127.0.0.1:8080$1 --ws --json -c $2 -t 16 -p 16 -d $3 > $4 2>&1; }
ms() { { date +%T; grep -E '^(anon|kernel|sock|kernel_stack|pagetables) ' $CG/memory.stat; echo "current $(cat $CG/memory.current)"; } > $1; }
for path in /ws/echo-cb /ws/echo; do
  n=${path##*/}; d=$OUT/$n; mkdir -p $d
  docker rm -f prof-sut >/dev/null 2>&1
  docker run -d --name prof-sut --network host --cpuset-cpus 2 --cpus 1 --memory 2048m --memory-swap 2048m \
    --ulimit nofile=1048576:1048576 -e MODE=h1 -e WORKERS=1 -e TICK_HZ=0 anole-bench/anole:b >/dev/null
  for i in $(seq 50); do curl -sf -o /dev/null http://127.0.0.1:8080/plaintext && break; sleep 0.2; done
  CG=/sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' prof-sut).scope; PID=$(pgrep -n -x anole-bench)
  g $path 16384 5s $d/gcannon-warm.json
  ms $d/memory.after-warm
  g $path 16384 15s $d/gcannon-run.json &
  sleep 8; ms $d/memory.t8
  docker run --rm --privileged --pid=host --cpuset-cpus 16-19 -v $d:/out anole-bench/perf sh -c "cd /tmp; \
    perf stat -p $PID -e $EVENTS -o /out/perf-stat.txt -- sleep 2; \
    perf record -F 2999 -g -p $PID -o perf.data -- sleep 3 2>/out/perf-record.log; \
    perf report -i perf.data --no-children --sort sym --stdio -g none 2>/dev/null | head -60 > /out/report-self.txt; \
    perf report -i perf.data --children --sort sym --stdio -g none 2>/dev/null | head -80 > /out/report-children.txt"
  wait
  for t in 0 10 30 60; do sleep $((t==0?0:(t==10?10:(t==30?20:30)))); ms $d/memory.idle-$t; done
  docker rm -f prof-sut >/dev/null
done
