#!/usr/bin/env bash
# Runs Anole's test binaries over and over, many at once, in a Linux
# container with as many CPUs as CI's ubuntu-latest runner (4). A test that
# assumes another thread is quick (a counter read too early, a snapshot
# taken after the event, a fixed sleep) passes on an idle machine and fails
# on a busy shared runner; this is the busy runner, on demand. Run it before
# pushing a change to concurrent code or to a test that waits on threads.
#
#   tools/stress-tests.sh [-c combos] [-n rounds] [-j parallel] [-o dir]
#
#   -c  test-flags combos, comma-separated (default full,minimal,full-tls-none),
#       or "test" for the binary of `zig build test`
#   -n  rounds of each binary (default 10)
#   -j  binaries running at once (default 8: twice the CPUs)
#   -o  where the logs of failed runs go (default .zig-cache/stress)
#
# Needs Docker. Zig and the dependencies are cached in the Docker volume
# anole-stress-cache; `docker volume rm anole-stress-cache` starts afresh.
set -euo pipefail

combos=full,minimal,full-tls-none
rounds=10
parallel=8
out=.zig-cache/stress
while getopts "c:n:j:o:" opt; do
  case $opt in
    c) combos=$OPTARG ;;
    n) rounds=$OPTARG ;;
    j) parallel=$OPTARG ;;
    o) out=$OPTARG ;;
    *) sed -n '2,19p' "$0" >&2; exit 2 ;;
  esac
done

root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/$out"
out_abs=$(cd "$root/$out" && pwd)
rm -f "$out_abs"/*.log

# Zig 0.17.0 for Linux, by the checksums ziglang.org publishes.
case $(docker info --format '{{.Architecture}}') in
  aarch64 | arm64) zig_arch=aarch64 zig_sha=9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8 ;;
  x86_64 | amd64) zig_arch=x86_64 zig_sha=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026 ;;
  *) echo "unsupported Docker architecture" >&2; exit 1 ;;
esac

docker run --rm --cpus 4 \
  -v "$root:/src:ro" -v anole-stress-cache:/cache -v "$out_abs:/out" \
  -e COMBOS="$combos" -e ROUNDS="$rounds" -e PARALLEL="$parallel" \
  -e ZIG_ARCH="$zig_arch" -e ZIG_SHA="$zig_sha" \
  -w /work ubuntu:24.04 bash -euo pipefail -c '
    # The tree on the container'"'"'s own file system: tests make unix sockets
    # under .zig-cache/tmp, which a file system shared from the host may not
    # support.
    tar -C /src --exclude=./.zig-cache --exclude=./zig-pkg --exclude=./.git -cf - . | tar -C /work -xf -
    zig=/cache/zig-$ZIG_ARCH-linux-0.17.0/zig
    # Fresh containers: the tools, and the CA bundle the dependency fetches
    # need (git and HTTPS).
    if [ ! -x "$zig" ] || [ ! -f /etc/ssl/certs/ca-certificates.crt ]; then
      apt-get update -qq >/dev/null && apt-get install -y -qq curl xz-utils ca-certificates >/dev/null 2>&1
    fi
    if [ ! -x "$zig" ]; then
      curl -sSfL -o /cache/zig.tar.xz "https://ziglang.org/download/0.17.0/zig-$ZIG_ARCH-linux-0.17.0.tar.xz"
      echo "$ZIG_SHA  /cache/zig.tar.xz" | sha256sum -c - >/dev/null
      tar -xJf /cache/zig.tar.xz -C /cache && rm /cache/zig.tar.xz
    fi
    export ZIG_GLOBAL_CACHE_DIR=/cache/global
    cache=(--cache-dir /cache/local)
    # Built (and run once) as CI does; the binaries are then in the cache. A
    # failing test in that first run is not a build failure: its binary is
    # there all the same.
    echo "== building"
    # Every lazy dependency first, as CI does: the configure pass ends early
    # (before the options are declared) while one is missing.
    for i in 1 2 3; do "$zig" build --fetch=all "${cache[@]}" >/tmp/fetch.log 2>&1 && break; sleep 5; done
    if [ "$COMBOS" = test ]; then
      names=(anole-test)
    else
      IFS=, read -ra cs <<< "$COMBOS"
      names=(); for c in "${cs[@]}"; do names+=("anole-test-$c"); done
    fi
    # One combo at a time: three full-featured test binaries compiling at
    # once need more memory than a default Docker VM has.
    if [ "$COMBOS" = test ]; then
      "$zig" build test "${cache[@]}" --summary none >/tmp/build.log 2>&1 || true
    else
      : >/tmp/build.log
      for c in "${cs[@]}"; do
        "$zig" build test-flags -Dflags-combos="$c" "${cache[@]}" --summary none >>/tmp/build.log 2>&1 || true
      done
    fi
    # Failures in the build'"'"'s own run are failures too: keep its log.
    if grep -qE "^error: '"'"'|failed with error|taken for a hang" /tmp/build.log; then
      cp /tmp/build.log /out/build-run.log
      echo "FAIL in the build'"'"'s own test run (log: build-run.log)"
    fi
    jobs=()
    for n in "${names[@]}"; do
      bin=$(ls -t /cache/local/o/*/"$n" 2>/dev/null | head -1 || true)
      if [ -z "$bin" ]; then
        echo "no binary $n: the build failed"; grep -E "error:" /tmp/build.log | head -20; exit 1
      fi
      for r in $(seq 1 "$ROUNDS"); do jobs+=("$n $bin $r"); done
    done
    run() {
      set -- $1
      local log=/tmp/$1-$3.log
      # From the tree, as zig build runs them (golden files are read
      # relative to it); temporary directories have random names.
      # A hang is the runner watchdog (300 s); 600 s is a last resort.
      if timeout 600 "$2" >"$log" 2>&1; then rm -f "$log"; echo "ok $1"; else
        cp "$log" /out/; echo "FAIL $1 round $3 (log: $(basename "$log"))"; fi
    }
    export -f run
    echo "== ${#jobs[@]} runs, $PARALLEL at a time"
    printf "%s\n" "${jobs[@]}" | xargs -P "$PARALLEL" -I{} bash -c "run \"{}\"" | tee /tmp/results
    total=$(wc -l < /tmp/results); failed=$(grep -c "^FAIL" /tmp/results || true)
    echo "== $((total - failed)) of $total runs passed"
    for f in /out/*.log; do
      [ -e "$f" ] || continue
      echo "-- $(basename "$f"):"
      # The test before each FAIL, and any crash.
      grep -B1 "^FAIL" "$f" | grep -E "^[0-9]+/[0-9]+ " | sed -E "s/\.\.\..*//" | head -5
      grep -E "taken for a hang|Segmentation fault|^thread [0-9]+ panic" "$f" | head -3
    done
    [ "$failed" -eq 0 ]
  '
