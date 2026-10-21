#!/bin/bash
# Run-order test: fresh server, then a sequence of wspipe runs (16 in flight) on one route.
OUT=${OUT:?}; mkdir -p $OUT
for path in /ws/echo /ws/echo-cb; do
  n=${path##*/}
  for seq in "16384" "4096 16384" "512 4096 16384"; do
    docker rm -f prof-sut >/dev/null 2>&1
    docker run -d --name prof-sut --network host --cpuset-cpus 2 --cpus 1 --memory 2048m --memory-swap 2048m \
      --ulimit nofile=1048576:1048576 -e MODE=h1 -e WORKERS=1 -e TICK_HZ=0 anole-bench/anole:b >/dev/null
    for i in $(seq 50); do curl -sf -o /dev/null http://127.0.0.1:8080/plaintext && break; sleep 0.2; done
    CG=/sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' prof-sut).scope
    line="$n [$seq]:"
    for c in $seq; do
      f=$OUT/$n-${seq// /_}-c$c.json
      docker run --rm --network host --cpuset-cpus 8-15,20-27 --security-opt seccomp=unconfined --ulimit memlock=-1:-1 \
        --ulimit nofile=1048576:1048576 --entrypoint gcannon anole-bench/loadgen \
        http://127.0.0.1:8080$path --ws --json -c $c -t 16 -p 16 -d 15s > $f 2>&1 &
      sleep 10
      a=$(awk '$1=="anon"{print int($2/1048576)}' $CG/memory.stat)
      cur=$(( $(cat $CG/memory.current) / 1048576 ))
      wait; sleep 3
      r=$(python3 -c "import json;s=open('$f').read();g=json.loads(s[s.index('{'):]);print(round(g['ws_frames']/g['elapsed_sec']/1e6,3))")
      line="$line c=$c ${r}M anon@10s=${a}MB current=${cur}MB;"
    done
    echo "$line" | tee -a $OUT/summary.txt
  done
done
docker rm -f prof-sut >/dev/null
