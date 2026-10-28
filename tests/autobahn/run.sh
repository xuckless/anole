#!/bin/sh
# Runs the Autobahn fuzzing client (Docker) against tests/autobahn/echo.zig
# and fails on any case that is not OK, NON-STRICT or INFORMATIONAL, or on a
# run that did not cover every case it announced. A run cut short by the
# client failing to connect (Docker Desktop's host.docker.internal path
# drops a connection now and then), or one that wrote no report, is
# retried, twice at most.
#
# A run with no report prints what tells a crash from a stall from a kill:
# both logs (the client's unbuffered, so its last case is the real one),
# the client container's exit code and State (OOMKilled), whether the echo
# peer was still alive and how it exited, the memory samples taken every
# 5 s (echo peer RSS, client container, host), and the kernel log's tail.
#   tests/autobahn/run.sh [path-to-echo-binary [loop|callbacks]]
#
# ANOLE_KEEP_CONTAINERS=1 leaves each attempt's client container when the
# script ends (CI collects their logs and states after a failure, then
# removes them).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../lib/wait.sh"
bin=${1:-zig-out/bin/autobahn-echo}
mode=${2:-loop}
image=crossbario/autobahn-testsuite@sha256:519915fb568b04c9383f70a1c405ae3ff44ab9e35835b085239c258b6fac3074
# The machine, since a failure once followed the runner, not the commit:
# zlib-ng picks its x86 code paths (AVX2, AVX-512, VNNI, VPCLMULQDQ) at run
# time, and PyPy sizes the client's GC nursery from /proc/cpuinfo's "cache
# size" (see the client's PYPY_GC_NURSERY below).
cpu=$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null || echo unknown)
cache=$(awk -F': ' '/^cache size/{print $2; exit}' /proc/cpuinfo 2>/dev/null || echo unknown)
flags=$(grep -m1 -o -w 'avx2\|avx512f\|avx512bw\|avx512vl\|avx512_vnni\|vpclmulqdq' /proc/cpuinfo 2>/dev/null | tr '\n' ' ' || true)
mem=$(awk '/MemTotal/{print $2 " kB"}' /proc/meminfo 2>/dev/null || echo unknown)
echo "machine: $(nproc 2>/dev/null || echo ?) CPUs, $cpu; cache size $cache; $flags; MemTotal $mem"
attempt=1
while :; do
  reports=$(mktemp -d)
  echo "reports: $reports (attempt $attempt)"
  "$bin" 9001 "$mode" >"$reports/server.log" 2>&1 &
  pid=$!
  if ! wait_until 30 "the echo peer to listen on 9001" port_open 127.0.0.1 9001; then
    tail -30 "$reports/server.log" >&2 || true
    exit 1
  fi
  client=anole-autobahn-client-$$-$attempt
  # Memory every 5 s while the client runs.
  (
    while :; do
      rss=$(awk '/VmRSS/{print $2}' "/proc/$pid/status" 2>/dev/null || echo gone)
      ctr=$(docker stats --no-stream --format '{{.MemUsage}}' "$client" 2>/dev/null || echo -)
      avail=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null || echo -)
      echo "$(date +%T) echo_rss_kb=$rss client=$ctr host_avail_kb=$avail"
      sleep 5
    done
  ) >"$reports/mem.log" 2>&1 &
  sampler=$!
  client_exit=0
  # The client is PyPy, whose GC sizes its nursery at half of /proc/cpuinfo's
  # "cache size" when that is over 8 MiB, else 4 MiB. x86 Linux reports L2
  # there on AMD (512 KB-1 MB: 4 MiB nursery) but L3 on Intel (260-480 MB:
  # a 130-240 MB nursery). Nursery objects that own C memory (zlib streams
  # in the 12.x/13.x permessage-deflate cases) then pile up between minor
  # collections and the client grew to 15 GiB and was OOM-killed on Intel
  # Xeon runners, against 3.5-3.8 GiB elsewhere. So pin the nursery to the
  # 4 MiB it gets everywhere else; the server side is untouched. The memory
  # cap makes a runaway client die in its own cgroup (reported below as
  # OOMKilled) instead of taking the runner down with it.
  docker run --name "$client" --add-host=host.docker.internal:host-gateway \
    --memory 8g -e PYPY_GC_NURSERY=4MB \
    -e PYTHONUNBUFFERED=1 \
    -v "$here/fuzzingclient.json:/config/fuzzingclient.json:ro" \
    -v "$reports:/reports" \
    "$image" wstest -m fuzzingclient -s /config/fuzzingclient.json >"$reports/wstest.log" 2>&1 || client_exit=$?
  kill $sampler 2>/dev/null || true
  wait $sampler 2>/dev/null || true
  client_state=$(docker inspect -f '{{json .State}}' "$client" 2>/dev/null || echo unknown)
  [ -n "${ANOLE_KEEP_CONTAINERS:-}" ] || docker rm -f "$client" >/dev/null 2>&1 || true
  if kill -0 $pid 2>/dev/null; then
    echo_state="alive; peak RSS $(awk '/VmHWM/{print $2 " " $3}' "/proc/$pid/status" 2>/dev/null || echo unknown)"
    kill $pid 2>/dev/null || true
  else
    echo_state="already gone"
  fi
  echo_exit=0
  wait $pid 2>/dev/null || echo_exit=$?
  # Every run: a baseline to hold a failing one against.
  echo "client: exit $client_exit; state $client_state"
  echo "echo peer: $echo_state when the client ended; exit status $echo_exit"
  echo "peak client container memory: $(sed -n 's/.*client=\([^ ]*\) .*/\1/p' "$reports/mem.log" | sort -h | tail -1)"
  echo "lowest host MemAvailable: $(sed -n 's/.*host_avail_kb=\([0-9]*\).*/\1/p' "$reports/mem.log" | sort -n | head -1) kB"
  if [ ! -f "$reports/index.json" ]; then
    echo "no report from the fuzzing client"
    echo "--- fuzzing client log (tail)"
    tail -30 "$reports/wstest.log" || true
    echo "--- echo peer log (tail)"
    tail -30 "$reports/server.log" || true
    echo "--- memory samples (tail)"
    tail -40 "$reports/mem.log" || true
    echo "--- kernel log (tail)"
    { sudo -n dmesg 2>/dev/null || dmesg 2>/dev/null || echo "(dmesg not readable)"; } | tail -30
  fi
  if { [ ! -f "$reports/index.json" ] || grep -q "failed (User timeout\|Connection refused" "$reports/wstest.log"; } && [ $attempt -lt 3 ]; then
    echo "client connection failure or no report; retrying"
    attempt=$((attempt + 1))
    continue
  fi
  break
done
python3 -I "$here/check.py" "$reports/index.json" "$reports/wstest.log"
