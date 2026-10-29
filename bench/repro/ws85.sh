#!/bin/bash
# #85 A/B/C on the video-call relay (bench/videocall), WebSocket only, Anole
# only, MEDIA_DEFLATE=off (pure relay), 1 CPU / 2 GB, epoll and io_uring.
#
#   1. ramp: one more batch of 10 users every 5 s until calls collapse;
#      "good" users as report.py counts them.
#   2. fixed: 600 users (batches of 20 every 5 s), then held HOLD and
#      measured as one step: server CPU per relayed message, latency, memory.
#   3. profile (epoll, after the measured runs, one per side): during a
#      fixed-load hold, perf stat on the read/write syscalls for 20 s, then
#      perf record -g for 15 s (folded stacks for flame graphs).
#
# Every measured invocation rests REST s first (run.sh does it); rounds rotate
# the order ABC, BCA, CAB.
#
#   VCLOAD=<vcload with -hold> bench/repro/ws85.sh <results-id> a=<image> b=<image> c=<image>
set -u
bench=$(cd "$(dirname "$0")/.." && pwd)
. "$bench/lib/cpus.sh"
id=$1; shift
declare -A image; names=()
for kv in "$@"; do image[${kv%%=*}]=${kv#*=}; names+=("${kv%%=*}"); done
out=$bench/results/$id
mkdir -p "$out"
RUNS=${RUNS:-3} HOLD=${HOLD:-90s} USERS=${USERS:-600}
PHASES=${PHASES:-"ramp fixed profile"}
: "${VCLOAD:?set VCLOAD to a vcload binary with -hold}"
log() { echo "$(date +%H:%M:%S) $*" | tee -a "$out/run.log"; }

# run.sh runs anole-bench/vc-<app>: tag each side's image under its side name.
for s in "${names[@]}"; do docker tag "${image[$s]}" "anole-bench/vc-$s"; done

one() { # <phase> <backend> <round> <side> [extra vcload args]
  local phase=$1 be=$2 r=$3 s=$4; shift 4
  local u=0; [ "$be" = uring ] && u=1
  SERVERS=$s TRANSPORTS=ws QUALITY=0 MEDIA_DEFLATE=off URING=$u VCLOAD=$VCLOAD EXTRA="$*" \
    "$bench/videocall/run.sh" "$id/$phase-$be-r$r" >/dev/null 2>&1
  local d=$out/$phase-$be-r$r/videocall/$s-ws
  log "$phase $be r$r $s: $(python3 "$bench/repro/ws85-summary.py" one "$d")"
}

order() { # <round>: the sides rotated by round
  local r=$1 n=${#names[@]} i
  for ((i = 0; i < n; i++)); do echo "${names[$(((i + r - 1) % n))]}"; done
}

for phase in ramp fixed; do
  case " $PHASES " in *" $phase "*) ;; *) continue ;; esac
  for r in $(seq "$RUNS"); do
    for be in epoll uring; do
      for s in $(order "$r"); do
        if [ $phase = ramp ]; then one ramp $be $r "$s" -batch 10
        else one fixed $be $r "$s" -batch 20 -max-users "$USERS" -hold "$HOLD"; fi
      done
    done
  done
done

case " $PHASES " in *" profile "*)
  for s in "${names[@]}"; do
    d=$out/profile/$s; mkdir -p "$d"
    SERVERS=$s TRANSPORTS=ws QUALITY=0 MEDIA_DEFLATE=off URING=0 VCLOAD=$VCLOAD EXTRA="-batch 20 -max-users $USERS -hold 60s" \
      "$bench/videocall/run.sh" "$id/profile-run/$s" >/dev/null 2>&1 &
    runner=$!
    vl=$out/profile-run/$s/videocall/$s-ws/vcload.log
    until grep -q '^holding' "$vl" 2>/dev/null; do sleep 1; kill -0 $runner 2>/dev/null || break; done
    sleep 5
    pid=$(docker inspect -f '{{.State.Pid}}' vc-sut)
    date +%s%N > "$d/stat-start-ns"
    docker run --rm --privileged --pid=host --cpuset-cpus 16-19 -v "$d:/out" anole-bench/perf perf stat -p "$pid" \
      -e task-clock,syscalls:sys_enter_read,syscalls:sys_enter_readv,syscalls:sys_enter_recvfrom,syscalls:sys_enter_recvmsg \
      -e syscalls:sys_enter_write,syscalls:sys_enter_writev,syscalls:sys_enter_sendto,syscalls:sys_enter_sendmsg \
      -e syscalls:sys_enter_epoll_wait,syscalls:sys_enter_epoll_pwait,syscalls:sys_enter_epoll_pwait2,syscalls:sys_enter_ppoll,syscalls:sys_enter_io_uring_enter \
      -o /out/perf-stat.txt -- sleep 20
    date +%s%N > "$d/stat-end-ns"
    docker run --rm --privileged --pid=host --cpuset-cpus 16-19 -v "$d:/out" anole-bench/perf sh -c \
      "cd /tmp && perf record -F 999 -g -p $pid -o perf.data -- sleep 15 2>/out/perf-record.log; \
       perf script -i perf.data 2>/dev/null | gzip > /out/perf-script.txt.gz; \
       perf report -i perf.data --no-children --stdio --percent-limit 0.5 2>/dev/null | head -150 > /out/report-self.txt"
    wait $runner
    log "profile $s: $(python3 "$bench/repro/ws85-summary.py" profile "$d" "$out/profile-run/$s/videocall/$s-ws")"
  done ;;
esac
for s in "${names[@]}"; do docker rmi "anole-bench/vc-$s" >/dev/null 2>&1; done
log done
