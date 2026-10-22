#!/bin/bash
# Targeted QUIC interop rerun on #75's head 19942bf: the cases that failed or
# regressed on e8fdf17, plus the rebinding cases the earlier fixes touched.
# 3 runs per client, 70 s idle before each invocation, run-major order (every
# client once, then again), all logs and captures kept.
S=/tmp/claude-1000/-home-xuckl-Dev-anole/c1c2be6d-f2fa-4d37-a045-8c474b8f1549/scratchpad
W=$S/wt-qfix2
OUT=$S/interop-qfix2; mkdir -p $OUT
cases="go-x-net:rebind-port,rebind-addr aioquic:rebind-port,rebind-addr xquic:multiplexing,handshakeloss
msquic:rebind-port,rebind-addr picoquic:rebind-port,rebind-addr s2n-quic:rebind-port,rebind-addr
kwik:rebind-port quinn:zerortt neqo:zerortt"

docker run --rm --user $(id -u):$(id -g) -e HOME=/tmp -v $W:/w -w /w zig-dev:0.17 \
  zig build h3-interop-server -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe --prefix /w/interop-out \
  > $OUT/build.log 2>&1 || { echo "build failed"; exit 1; }
bin=$W/interop-out/bin/h3-interop-server

export PATH=$S/py312bin:$PATH  # pyshark needs Python < 3.14
for n in 1 2 3; do
  for ct in $cases; do
    c=${ct%%:*}; t=${ct#*:}
    sleep 70
    ANOLE_INTEROP_BIN=$bin ANOLE_INTEROP_WORK=$OUT/run$n/$c \
      bash $W/tests/interop/run.sh $c $t > $OUT/run$n-$c.log 2>&1
    echo "$(date +%H:%M) run $n $c exit $?"
    rm -rf $OUT/run$n/$c/venv $OUT/run$n/$c/runner/.git
  done
done
