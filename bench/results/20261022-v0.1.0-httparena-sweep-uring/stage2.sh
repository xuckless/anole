#!/bin/bash
# Stage 2: (1) 1-CPU epoll single-wake recheck, A = 5aa0517 (anole:a5) vs
# B = v0.1.0 (anole:v010), park suite A,B,A,B,A,B; (2) the full HttpArena sweep
# on the entry (v0.1.0): every meta.json profile on io_uring, then the
# non-gateway ones on epoll (the gateway compose files must set
# seccomp=unconfined, so Anole is on io_uring there either way).
S=/tmp/claude-1000/-home-xuckl-Dev-anole/c1c2be6d-f2fa-4d37-a045-8c474b8f1549/scratchpad
cd /home/xuckl/Dev/anole
dir=""
for i in 1 2 3; do for v in a5 v010; do
  if [ -n "$dir" ]; then
    RESULTS=$dir NO_BUILD=1 bench/suite.sh -only park -tiers 1 -modes h1 -servers anole@$v >> $S/wake-recheck.log 2>&1
  else
    NO_BUILD=1 RUN_TAG=wake-recheck-epoll bench/suite.sh -only park -tiers 1 -modes h1 -servers anole@$v >> $S/wake-recheck.log 2>&1
    dir=$(ls bench/results | grep wake-recheck-epoll | tail -1)
  fi
  echo "recheck $i $v exit $? -> $dir"
done; done

cd /home/xuckl/Dev/HttpArena
export PROXY_CPUSET=0-5 SERVER_CPUSET=6-13 EDGE_CPUSET=0-5 CACHE_CPUSET=6-9 AUTHSVC_CPUSET=10-11
mkdir -p $S/sweep
for be in uring epoll; do
  script=scripts/benchmark-local.sh; [ $be = epoll ] && script=scripts/benchmark-local-epoll.sh
  for p in $(cat $S/arena-tests.txt); do
    case "$be:$p" in epoll:gateway-64|epoll:gateway-h3|epoll:production-stack) continue;; esac
    # production-stack's server gets the last core pair
    [ $p = production-stack ] && export SERVER_CPUSET=12-13 || export SERVER_CPUSET=6-13
    SKIP_TUNE=true LOADGEN_DOCKER=true $script anole $p > $S/sweep/$be-$p.log 2>&1
    echo "sweep $be $p exit $?"
  done
done
