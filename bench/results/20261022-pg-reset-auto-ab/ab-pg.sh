#!/bin/bash
# Postgres reset A/B: v0.1.1 default reset (anole-pr) vs v0.1.1 with the
# reset off (anole-pn) vs #76 pg-reset-auto (anole-pa), HttpArena async-db
# (pooled reads) and production-stack (includes POST /api/items/{id}
# UPDATEs), io_uring. Rested: 70 s idle before every invocation, 3 rounds,
# order rotating per round.
S=/tmp/claude-1000/-home-xuckl-Dev-anole/c1c2be6d-f2fa-4d37-a045-8c474b8f1549/scratchpad
OUT=$S/ab-pg; mkdir -p $OUT
cd /home/xuckl/Dev/HttpArena
export SKIP_TUNE=true LOADGEN_DOCKER=true
export PROXY_CPUSET=0-5 SERVER_CPUSET=12-13 EDGE_CPUSET=0-5 CACHE_CPUSET=6-9 AUTHSVC_CPUSET=10-11
for r in 1 2 3; do
  case $r in 1) order="anole-pr anole-pn anole-pa" ;; 2) order="anole-pa anole-pr anole-pn" ;; 3) order="anole-pn anole-pa anole-pr" ;; esac
  for p in async-db production-stack; do
    for fw in $order; do
      sleep 70
      scripts/benchmark-local.sh $fw $p > $OUT/r$r-$p-$fw.log 2>&1
      echo "$(date +%H:%M) round $r $p $fw exit $?"
    done
  done
done
