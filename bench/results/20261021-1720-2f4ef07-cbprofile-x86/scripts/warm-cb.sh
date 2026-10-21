#!/bin/bash
OUT=${OUT:?}
g() { docker run --rm --network host --cpuset-cpus 8-15,20-27 --security-opt seccomp=unconfined --ulimit memlock=-1:-1 \
  --ulimit nofile=1048576:1048576 --entrypoint gcannon anole-bench/loadgen http://127.0.0.1:8080$1 --ws --json -c $2 -t 16 -p 16 -d $3 > $4 2>&1; }
rate() { python3 -c "import json;s=open('$1').read();g=json.loads(s[s.index('{'):]);print(round(g['ws_frames']/g['elapsed_sec']/1e6,3), g['errors'], g.get('reconnects'))"; }
for c in 16384 4096; do for gap in 0 5; do for path in /ws/echo /ws/echo-cb; do
  n=${path##*/}
  docker rm -f prof-sut >/dev/null 2>&1
  docker run -d --name prof-sut --network host --cpuset-cpus 2 --cpus 1 --memory 2048m --memory-swap 2048m \
    --ulimit nofile=1048576:1048576 -e MODE=h1 -e WORKERS=1 -e TICK_HZ=0 anole-bench/anole:b >/dev/null
  for i in $(seq 50); do curl -sf -o /dev/null http://127.0.0.1:8080/plaintext && break; sleep 0.2; done
  CG=/sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' prof-sut).scope
  g $path $c 5s $OUT/$n-c$c-gap$gap-warm.json
  sleep $gap
  a0=$(awk '$1=="anon"{print int($2/1048576)}' $CG/memory.stat)
  g $path $c 15s $OUT/$n-c$c-gap$gap-run.json &
  sleep 10; a=$(awk '$1=="anon"{print int($2/1048576)}' $CG/memory.stat); cur=$(( $(cat $CG/memory.current) / 1048576 )); wait
  echo "$n c=$c gap=${gap}s: warm $(rate $OUT/$n-c$c-gap$gap-warm.json) | run $(rate $OUT/$n-c$c-gap$gap-run.json) | anon before run ${a0}MB, @10s ${a}MB, current ${cur}MB" | tee -a $OUT/summary.txt
done; done; done
docker rm -f prof-sut >/dev/null
