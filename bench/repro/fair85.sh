#!/bin/bash
# Fairness holds for #85 (bench/results/<id>/NOTES.md): each side joins 950
# users fast (50 every 5 s), settles 30 s at 950, then holds 60 s. vcload
# writes per_user.jsonl (each receiver's video received/shown, audio, worst
# latency over the hold). perf stat counts the syscalls for 20 s inside the
# settle (same users, same load), so the tracepoints don't touch the hold.
# vcload's collapse rule is off (-collapse 24h): a side whose calls all fail
# at 950 users is held and measured like the others.
# One run per side and backend, rested REST s first, order rotated per backend.
# PROF=1 (profile runs, results under prof-<backend>) also records the CPU
# (perf record -g, 15 s from 10 s into the hold) for flame graphs; the
# per-user counts of such a run are disturbed by the sampling.
# BACKENDS="epoll uring" picks the backends.
#
#   VCLOAD=<vcload-fair> bench/repro/fair85.sh <results-id> a=<image> b=<image> ...
set -u
bench=$(cd "$(dirname "$0")/.." && pwd)
. "$bench/lib/cpus.sh"
id=$1; shift
declare -A image; names=()
for kv in "$@"; do image[${kv%%=*}]=${kv#*=}; names+=("${kv%%=*}"); done
out=$bench/results/$id
mkdir -p "$out"
USERS=${USERS:-950} HOLD=${HOLD:-60s} PROF=${PROF:-0} BACKENDS=${BACKENDS:-"epoll uring"}
: "${VCLOAD:?set VCLOAD to vcload-fair}"
log() { echo "$(date +%H:%M:%S) $*" | tee -a "$out/run.log"; }
for s in "${names[@]}"; do docker tag "${image[$s]}" "anole-bench/vc-$s"; done

k=0
for be in $BACKENDS; do
  n=${#names[@]}
  for ((i = 0; i < n; i++)); do
    s=${names[$(((i + k) % n))]}
    u=0; [ $be = uring ] && u=1
    tag=fair-$be; [ "$PROF" = 1 ] && tag=prof-$be
    SERVERS=$s TRANSPORTS=ws QUALITY=0 MEDIA_DEFLATE=off URING=$u VCLOAD=$VCLOAD \
      EXTRA="-batch 10 -fast-to $USERS -fast-batch 50 -settle 30s -max-users $USERS -hold $HOLD -stop-below 0 -collapse 24h" \
      "$bench/videocall/run.sh" "$id/$tag" >/dev/null 2>&1 &
    runner=$!
    d=$out/$tag/videocall/$s-ws
    until grep -q '^settling' "$d/vcload.log" 2>/dev/null; do sleep 1; kill -0 $runner 2>/dev/null || break; done
    if kill -0 $runner 2>/dev/null; then
      sleep 5
      pid=$(docker inspect -f '{{.State.Pid}}' vc-sut)
      date +%s%N > "$d/stat-start-ns"
      docker run --rm --privileged --pid=host --cpuset-cpus 16-19 -v "$d:/out" anole-bench/perf perf stat -p "$pid" \
        -e task-clock,syscalls:sys_enter_read,syscalls:sys_enter_readv,syscalls:sys_enter_recvfrom,syscalls:sys_enter_recvmsg \
        -e syscalls:sys_enter_write,syscalls:sys_enter_writev,syscalls:sys_enter_sendto,syscalls:sys_enter_sendmsg \
        -e syscalls:sys_enter_epoll_wait,syscalls:sys_enter_epoll_pwait,syscalls:sys_enter_epoll_pwait2,syscalls:sys_enter_ppoll,syscalls:sys_enter_io_uring_enter \
        -o /out/perf-stat.txt -- sleep 20
      date +%s%N > "$d/stat-end-ns"
      if [ "$PROF" = 1 ]; then
        until grep -q '^holding' "$d/vcload.log" 2>/dev/null; do sleep 1; kill -0 $runner 2>/dev/null || break; done
        sleep 10
        docker run --rm --privileged --pid=host --cpuset-cpus 16-19 -v "$d:/out" anole-bench/perf sh -c \
          "cd /tmp && perf record -F 999 -g -p $pid -o perf.data -- sleep 15 2>/out/perf-record.log; \
           perf script -i perf.data 2>/dev/null | gzip > /out/perf-script.txt.gz; \
           perf report -i perf.data --no-children --stdio --percent-limit 0.3 2>/dev/null > /out/report-self.txt; \
           perf report -i perf.data --no-children --stdio --sort sym --percent-limit 0.1 -g none 2>/dev/null > /out/report-sym.txt"
      fi
    fi
    wait $runner
    log "$tag $s: $(python3 "$bench/repro/ws85-summary.py" fair "$d")"
    [ "$PROF" = 1 ] && log "$tag $s: $(python3 "$bench/repro/ws85-summary.py" flame "$d")"
  done
  k=$((k + 1))
done
for s in "${names[@]}"; do docker rmi "anole-bench/vc-$s" >/dev/null 2>&1; done
log done
