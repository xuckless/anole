#!/bin/bash
# HTTP/3 A/B: main (5ff99a4) vs quic-interop-fixes (#75), bench/suite.sh raw
# scenario, h3 mode, 1- and 4-CPU tiers, on io_uring (SUT_URING=1, as
# HttpArena). Rested: 70 s idle before every invocation, 3 rounds, order
# alternating per round; one server per invocation, all into one results dir.
S=/tmp/claude-1000/-home-xuckl-Dev-anole/c1c2be6d-f2fa-4d37-a045-8c474b8f1549/scratchpad
cd /home/xuckl/Dev/anole
for t in main qfix; do
  docker build -q -f $S/wt-$t/bench/servers/anole/Dockerfile -t anole-bench/anole:$t $S/wt-$t > /dev/null || { echo "build $t failed"; exit 1; }
  echo "$(date +%H:%M) built anole:$t"
done
dir=""
for r in 1 2 3; do
  if [ $r = 2 ]; then order="qfix main"; else order="main qfix"; fi
  for t in $order; do
    sleep 70
    if [ -n "$dir" ]; then
      RESULTS=$dir NO_BUILD=1 SUT_URING=1 bench/suite.sh -only raw -tiers 1,4 -modes h3 -servers anole@$t >> $S/ab-h3.log 2>&1
    else
      NO_BUILD=1 SUT_URING=1 RUN_TAG=h3-steering-ab bench/suite.sh -only raw -tiers 1,4 -modes h3 -servers anole@$t >> $S/ab-h3.log 2>&1
      dir=$(ls bench/results | grep h3-steering-ab | tail -1)
    fi
    echo "$(date +%H:%M) round $r $t exit $? -> $dir"
  done
done
