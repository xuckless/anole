#!/bin/bash
# 0.4.0 item 1b: live checks of the raw net listeners on p3/all (anole-bench/anole:p3).
OUT=/home/xuckl/Dev/anole/bench/results/20261023-v040/net-checks
S=/tmp/claude-1000/-home-xuckl-Dev-anole/c1c2be6d-f2fa-4d37-a045-8c474b8f1549/scratchpad
mkdir -p $OUT
IMG=anole-bench/anole:p3
start() { # start <name> <cpus> <workers> [extra docker args...]
  local n=$1 c=$2 w=$3; shift 3
  docker rm -f $n >/dev/null 2>&1
  docker run -d --name $n --network host --cpuset-cpus $c --cpus $(echo $c | tr ',' '\n' | wc -l) --memory 2g \
    --ulimit nofile=1048576:1048576 -e MODE=h1 -e TICK_HZ=0 -e WORKERS=$w -e METRICS=1 "$@" $IMG >/dev/null
  for i in $(seq 40); do curl -s -o /dev/null localhost:8080/json && break; sleep 0.25; done
}
metric() { curl -s localhost:8080/metrics | grep -E "^$1" ; }
threads_cpu() { # per-thread utime+stime (ticks) of PID
  for t in /proc/$1/task/*; do echo "$(basename $t) $(cat $t/comm) $(awk '{print $14+$15}' $t/stat)"; done
}

for be in epoll uring; do
  extra=(); [ $be = uring ] && extra=(--security-opt seccomp=unconfined --ulimit memlock=-1:-1)
  d=$OUT/$be; mkdir -p $d

  # Per-core UDP groups: 4 executors on 4 CPUs, 256 client sockets.
  start net-sut 0,2,4,6 4 -e NET_UDP_PORT=7001 "${extra[@]}"
  docker logs net-sut 2>&1 | grep -o 'listening on udp[^"]*' > $d/udp4-listen.txt
  PID=$(docker inspect -f '{{.State.Pid}}' net-sut)
  ss -uanp 2>/dev/null | grep ':7001 ' | wc -l > $d/udp4-sockets.txt
  sleep 20
  threads_cpu $PID > $d/udp4-threads-before.txt
  docker run --rm --network host --cpuset-cpus 8-15,20-27 -v $S/bin:/b:ro --entrypoint /b/udpload anole-bench/loadgen \
    -addr 127.0.0.1:7001 -sockets 256 -window 32 -d 15s > $d/udp4-load.json
  threads_cpu $PID > $d/udp4-threads-after.txt
  metric anole_net_datagrams > $d/udp4-metrics.txt
  docker rm -f net-sut >/dev/null
  # The same load on 1 executor, 1 CPU.
  start net-sut 2 1 -e NET_UDP_PORT=7001 "${extra[@]}"
  sleep 20
  docker run --rm --network host --cpuset-cpus 8-15,20-27 -v $S/bin:/b:ro --entrypoint /b/udpload anole-bench/loadgen \
    -addr 127.0.0.1:7001 -sockets 256 -window 32 -d 15s > $d/udp1-load.json
  # recvmmsg batching: syscalls against datagrams, 5 s inside a paced load.
  PID=$(docker inspect -f '{{.State.Pid}}' net-sut)
  docker run -d --name udp-load --network host --cpuset-cpus 8-15,20-27 -v $S/bin:/b:ro --entrypoint /b/udpload anole-bench/loadgen \
    -addr 127.0.0.1:7001 -sockets 256 -window 32 -d 15s >/dev/null
  sleep 5
  metric anole_net_datagrams > $d/batch-metrics-before.txt
  docker run --rm --privileged --pid=host --cpuset-cpus 16-19 -v $d:/out anole-bench/perf perf stat -p $PID \
    -e syscalls:sys_enter_recvmmsg,syscalls:sys_enter_recvmsg,syscalls:sys_enter_recvfrom,syscalls:sys_enter_sendmmsg,syscalls:sys_enter_sendmsg,syscalls:sys_enter_sendto,syscalls:sys_enter_io_uring_enter,syscalls:sys_enter_epoll_wait,syscalls:sys_enter_epoll_pwait \
    -o /out/batch-perf-stat.txt -- sleep 5
  metric anole_net_datagrams > $d/batch-metrics-after.txt
  docker wait udp-load >/dev/null; docker rm udp-load >/dev/null
  # SO_RXQ_OVFL: an unpaced flood on 1 CPU; Anole's kernel drops against the kernel's own count.
  sleep 5
  grep '^Udp:' /proc/net/snmp > $d/ovfl-snmp-before.txt
  metric anole_net_datagrams > $d/ovfl-metrics-before.txt
  docker run --rm --network host --cpuset-cpus 8-15,20-27 -v $S/bin:/b:ro --entrypoint /b/udpload anole-bench/loadgen \
    -addr 127.0.0.1:7001 -sockets 64 -window 0 -d 10s > $d/ovfl-load.json
  sleep 1
  grep '^Udp:' /proc/net/snmp > $d/ovfl-snmp-after.txt
  metric anole_net_datagrams > $d/ovfl-metrics-after.txt
  docker rm -f net-sut >/dev/null

  # Drain with open raw TCP connections: time from docker stop to exit.
  for spec in "0 polite" "100 rude" "100 polite" "1000 rude" "1000 polite"; do
    set -- $spec; n=$1 mode=$2
    start net-sut 2 1 -e NET_TCP_PORT=7000 "${extra[@]}"
    hp=""
    if [ $n -gt 0 ]; then
      python3 $S/holdconns.py 7000 $n $mode > $d/hold.out 2>&1 &
      hp=$!
      for i in $(seq 100); do grep -q held $d/hold.out 2>/dev/null && break; sleep 0.1; done
    fi
    sleep 1
    t0=$(date +%s.%N)
    docker stop -t 120 net-sut >/dev/null
    t1=$(date +%s.%N)
    echo "$n $mode stop_s $(echo "$t1 - $t0" | bc) exit $(docker inspect -f '{{.State.ExitCode}}' net-sut)" | tee -a $d/drain.txt
    docker logs net-sut 2>&1 | grep -iE "drain|shutdown|timed out|clos" | cut -c1-300 > $d/drain-$n-$mode.log
    [ -n "$hp" ] && kill $hp 2>/dev/null; wait $hp 2>/dev/null
    docker rm -f net-sut >/dev/null
  done
done
echo done
