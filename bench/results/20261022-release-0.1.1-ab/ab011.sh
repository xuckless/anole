#!/bin/bash
# A/B: main 938f258 (anole-ma) vs release-0.1.1 18bbe33 (anole-rc), HttpArena
# entry on io_uring (seccomp=unconfined, as HttpArena runs it). Rested
# protocol: 70 s idle before every invocation, 3 rounds, order alternating
# per round (A,B / B,A / A,B). async-db adds release-0.1.1 with
# reset_session = false (anole-rn). Each invocation = the harness's 3 runs
# per connection count.
S=/tmp/claude-1000/-home-xuckl-Dev-anole/c1c2be6d-f2fa-4d37-a045-8c474b8f1549/scratchpad
OUT=$S/ab011; mkdir -p $OUT
cd /home/xuckl/Dev/HttpArena
export SKIP_TUNE=true LOADGEN_DOCKER=true
profiles="baseline-h2c json-h2c baseline-h2 unary-grpc unary-grpc-tls async-db baseline echo-ws"
for r in 1 2 3; do
  for p in $profiles; do
    if [ $r = 2 ]; then order="anole-rc anole-ma"; else order="anole-ma anole-rc"; fi
    [ $p = async-db ] && order="$order anole-rn"
    for fw in $order; do
      sleep 70
      scripts/benchmark-local.sh $fw $p > $OUT/r$r-$p-$fw.log 2>&1
      echo "$(date +%H:%M) round $r $p $fw exit $?"
    done
  done
done
