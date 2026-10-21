#!/bin/bash
# CPU-split sweep for the gateway profiles on this box: the stack gets CPUs
# 0-13 (7 physical cores, siblings adjacent), the load generator 14-27.
S=/tmp/claude-1000/-home-xuckl-Dev-anole/c1c2be6d-f2fa-4d37-a045-8c474b8f1549/scratchpad
OUT=$S/gw-sweep; mkdir -p $OUT
cd /home/xuckl/Dev/HttpArena
run() { # $1 profile $2 label
  SKIP_TUNE=true LOADGEN_DOCKER=true scripts/benchmark-local.sh anole $1 > $OUT/$1-$2.log 2>&1
  echo "$1 $2: $(grep -h -E '^=== (anole /|Best)' $OUT/$1-$2.log | paste - - | sed -E 's/=== anole \/ [a-z0-9-]+ \/ ([0-9]+c).*Best: ([0-9]+) req\/s \(CPU: ([^,]*), Mem: ([0-9]+MiB)\).*/\1=\2 (\3)/' | tr '\n' ' ')" | tee -a $OUT/summary.txt
}
# gateway-64: proxy 1..5 cores
for p in 1 2 3 4 5; do
  export PROXY_CPUSET=0-$((2*p-1)) SERVER_CPUSET=$((2*p))-13
  run gateway-64 proxy${p}c
done
# gateway-h3: nginx vs Caddy at 2, 3, 4 proxy cores
for edge in nginx caddy; do
  rm -rf frameworks/anole/proxy-h3 && cp -r frameworks/anole/proxy-h3-$edge frameworks/anole/proxy-h3
  for p in 2 3 4; do
    export PROXY_CPUSET=0-$((2*p-1)) SERVER_CPUSET=$((2*p))-13
    run gateway-h3 $edge-proxy${p}c
  done
done
rm -rf frameworks/anole/proxy-h3 && cp -r frameworks/anole/proxy-h3-nginx frameworks/anole/proxy-h3
# production-stack: edge / cache / authsvc / server, in cores
for split in 3:1:1:2 2:1:2:2 3:1:2:1 2:1:1:3 4:1:1:1; do
  IFS=: read e c a s <<< "$split"
  export EDGE_CPUSET=0-$((2*e-1)) CACHE_CPUSET=$((2*e))-$((2*(e+c)-1)) \
         AUTHSVC_CPUSET=$((2*(e+c)))-$((2*(e+c+a)-1)) SERVER_CPUSET=$((2*(e+c+a)))-13
  run production-stack e${e}c${c}a${a}s${s}
done
