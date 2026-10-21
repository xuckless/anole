#!/bin/bash
# x86 profiles of /ws/echo vs /ws/echo-cb on anole-bench/anole:b (req-mem 2f4ef07),
# 1 CPU, epoll, gcannon wspipe 16 in flight. Output: $OUT/<case>/...
set -u
OUT=${OUT:?}
IMG=anole-bench/anole:b
EVENTS=task-clock,page-faults,context-switches,raw_syscalls:sys_enter,syscalls:sys_enter_ppoll,syscalls:sys_enter_epoll_ctl,syscalls:sys_enter_mprotect,syscalls:sys_enter_munmap,syscalls:sys_enter_madvise,syscalls:sys_enter_recvfrom,syscalls:sys_enter_sendto,syscalls:sys_enter_recvmsg

start_sut() {
  docker rm -f prof-sut >/dev/null 2>&1
  docker run -d --name prof-sut --network host --cpuset-cpus 2 --cpus 1 \
    --memory 2048m --memory-swap 2048m --ulimit nofile=1048576:1048576 \
    -e MODE=h1 -e WORKERS=1 -e TICK_HZ=0 $IMG >/dev/null
  for i in $(seq 50); do curl -sf -o /dev/null http://127.0.0.1:8080/plaintext && break; sleep 0.2; done
  CID=$(docker inspect -f '{{.Id}}' prof-sut)
  CG=/sys/fs/cgroup/system.slice/docker-$CID.scope
  PID=$(pgrep -n -x anole-bench)
}

memsnap() { # $1 file
  { date +%T.%N; grep -E '^(anon|kernel|sock|kernel_stack|pagetables) ' $CG/memory.stat; echo "current $(cat $CG/memory.current)"; echo "peak $(cat $CG/memory.peak)"; } > "$1"
}

gcannon() { # $1 path $2 conns $3 outfile
  docker run --rm --network host --cpuset-cpus 8-15,20-27 --security-opt seccomp=unconfined \
    --ulimit memlock=-1:-1 --ulimit nofile=1048576:1048576 --entrypoint gcannon anole-bench/loadgen \
    http://127.0.0.1:8080$1 --ws --json -c $2 -t 16 -p 16 -d 15s > "$3" 2>&1
}

perfctr() { # privileged throwaway perf container on the E-cores
  docker run --rm --privileged --pid=host --cpuset-cpus 16-19 -v "$OUT":/out anole-bench/perf "$@"
}

for path in /ws/echo /ws/echo-cb; do
  name=${path##*/}
  d=$OUT/c16384-$name; mkdir -p $d

  # (1) perf stat + (3) memory.stat, fresh server; frames/s from the server's wchar (7-byte frames)
  start_sut; echo "$name stat pid=$PID" >&2
  gcannon $path 16384 $d/gcannon-stat.json &
  sleep 8
  memsnap $d/memory.stat.t8
  perfctr sh -c "grep -E 'rchar|wchar' /proc/$PID/io > /out/c16384-$name/io.before; \
    perf stat -p $PID -e $EVENTS -o /out/c16384-$name/perf-stat.txt -- sleep 4; \
    grep -E 'rchar|wchar' /proc/$PID/io > /out/c16384-$name/io.after"
  memsnap $d/memory.stat.t12
  wait
  memsnap $d/memory.stat.end
  docker rm -f prof-sut >/dev/null

  # (2) perf record, fresh server; report while the binary is still there
  start_sut; echo "$name record pid=$PID" >&2
  gcannon $path 16384 $d/gcannon-record.json &
  sleep 8
  perfctr sh -c "cd /tmp && perf record -F 2999 -g -p $PID -o perf.data -- sleep 4 2>/out/c16384-$name/perf-record.log; \
    perf report -i perf.data --no-children --sort sym --stdio -g none 2>/dev/null | head -60 > /out/c16384-$name/report-self.txt; \
    perf report -i perf.data --children --sort sym --stdio -g none 2>/dev/null | head -80 > /out/c16384-$name/report-children.txt; \
    perf report -i perf.data --no-children --sort dso --stdio -g none 2>/dev/null | head -30 > /out/c16384-$name/report-dso.txt"
  wait
  docker rm -f prof-sut >/dev/null

  # c=512 on a fresh server, memory only, sampled every second
  d5=$OUT/c512-$name; mkdir -p $d5
  start_sut; echo "$name c512 pid=$PID" >&2
  memsnap $d5/memory.stat.idle
  gcannon $path 512 $d5/gcannon.json &
  for s in $(seq 15); do sleep 1; memsnap $d5/memory.stat.t$s; done
  wait
  memsnap $d5/memory.stat.end
  docker rm -f prof-sut >/dev/null
done
echo done >&2
