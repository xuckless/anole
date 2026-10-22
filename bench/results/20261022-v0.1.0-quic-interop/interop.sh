#!/bin/bash
# QUIC interop matrix: Anole v0.1.0's h3-interop-server against every client
# the pinned runner (ab039a4) has, every test case, via tests/interop/run.sh.
# One client per invocation with 70 s idle before each (rested protocol), so
# timing-sensitive cases (loss, longrtt, blackhole) never run on a throttled CPU.
S=/tmp/claude-1000/-home-xuckl-Dev-anole/c1c2be6d-f2fa-4d37-a045-8c474b8f1549/scratchpad
W=$S/wt-v010
OUT=$S/interop; mkdir -p $OUT
clients="quic-go ngtcp2 mvfst quiche kwik picoquic aioquic neqo msquic chrome xquic lsquic quinn s2n-quic go-x-net"

# The server binary, built once in the Zig container.
[ -x $W/interop-out/bin/h3-interop-server ] || docker run --rm --user $(id -u):$(id -g) -e HOME=/tmp -v $W:/w -w /w zig-dev:0.17 \
  zig build h3-interop-server -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe --prefix /w/interop-out \
  > $OUT/build.log 2>&1 || { echo "build failed"; exit 1; }
bin=$W/interop-out/bin/h3-interop-server

export PATH=$S/py312bin:$PATH  # pyshark needs Python < 3.14
for c in $clients; do
  sleep 70
  ANOLE_INTEROP_BIN=$bin ANOLE_INTEROP_WORK=$OUT/$c \
    bash $W/tests/interop/run.sh $c > $OUT/$c.log 2>&1
  echo "$c exit $?"
done
