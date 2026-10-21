#!/bin/bash
# close-check: fd count, CPU and memory 15 s and 60 s after a 16384-connection
# wspipe client exits; fresh server per route; epoll and io_uring.
OUT=${OUT:?}; IMG=${IMG:-anole-bench/anole:fix}; mkdir -p $OUT
snap() { # $1 label
  local u0 u1 fds socks
  u0=$(awk '$1=="usage_usec"{print $2}' $CG/cpu.stat); sleep 2; u1=$(awk '$1=="usage_usec"{print $2}' $CG/cpu.stat)
  read fds socks < <(docker run --rm --privileged --pid=host anole-bench/perf sh -c "echo \$(ls /proc/$PID/fd | wc -l) \$(ls -l /proc/$PID/fd | grep -c socket:)")
  echo "$1: fds=$fds sockets=$socks cpu=$(( (u1-u0)/20000 ))% current=$(( $(cat $CG/memory.current)/1048576 ))MB anon=$(awk '$1=="anon"{print int($2/1048576)}' $CG/memory.stat)MB"
}
for be in epoll uring; do
  extra=(); [ $be = uring ] && extra=(--security-opt seccomp=unconfined --ulimit memlock=-1:-1)
  for path in /ws/echo-cb /ws/echo; do
    n=${path##*/}; name=cc-$be-$n
    docker run -d --rm --name $name --network host --cpuset-cpus 2 --cpus 1 --memory 2048m --memory-swap 2048m \
      --ulimit nofile=1048576:1048576 "${extra[@]}" -e MODE=h1 -e WORKERS=1 -e TICK_HZ=0 $IMG >/dev/null
    for i in $(seq 50); do curl -sf -o /dev/null http://127.0.0.1:8080/plaintext && break; sleep 0.2; done
    CG=/sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' $name).scope; PID=$(pgrep -n -x anole-bench)
    backend=$(docker run --rm --privileged --pid=host anole-bench/perf sh -c "ls -l /proc/$PID/fd | grep -o 'anon_inode:\[\(eventpoll\|io_uring\)\]' | sort -u | tr '\n' ' '")
    docker run --rm --network host --cpuset-cpus 8-15,20-27 --security-opt seccomp=unconfined --ulimit memlock=-1:-1 \
      --ulimit nofile=1048576:1048576 --entrypoint gcannon anole-bench/loadgen \
      http://127.0.0.1:8080$path --ws --json -c 16384 -t 16 -p 16 -d 15s > $OUT/$be-$n-gcannon.json 2>&1
    r=$(python3 -c "import json;s=open('$OUT/$be-$n-gcannon.json').read();g=json.loads(s[s.index('{'):]);print(round(g['ws_frames']/g['elapsed_sec']/1e6,3),'M frames/s', g['errors'])")
    { echo "== $be $path ($backend) run: $r"
      sleep 13; snap "+15s"
      sleep 43; snap "+60s"; } | tee -a $OUT/summary.txt
    docker stop $name >/dev/null
  done
done
