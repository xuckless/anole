#!/bin/bash
# The flame-graph atlas (TODO.md S2 "Flame-graph atlas before S2"): per cell
# and backend, one fresh server (one executor on $SUT_CPUS_1) and, in order:
#   count   D19: exactly N requests from h2load at saturation, perf stat on
#           the server container's cgroup on its CPU (instructions:u/k,
#           cycles:u, page faults, context switches); its rate is the cell's max
#   cpu     perf record -g (frame pointers) on that cgroup for 15 s at a fixed
#           load, FRAC of the max
#   offcpu  bcc offcputime (user + kernel stacks, every thread) for 10 s, same load
#   mem     bpftrace uprobes for 10 s at a low fixed load (MEMFRAC of the max,
#           at most MEMMAX req/s): bytes allocated per stack (libc malloc,
#           calloc, realloc; the request arena; block_cache; the page
#           allocator; mmap), malloc bytes still held at the window's end, and
#           pool acquisitions (counts)
#   rss     memory.current and VmRSS every second for the server's whole life
# The count rests REST s first (the box throttles after a minute of boost).
# Cells without h2load: net-tcp (tcpload, saturating; counted over a time
# window) and sse-* (C subscribers held open; memory and RSS only).
#   ID=<results-id> TOOLS=<dir with tcpload> bench/atlas/atlas.sh [cell...]
# Env: IMAGE (anole-bench/anole:atlas) BACKENDS ("epoll uring") REST (70)
# FRAC (0.6) MEMFRAC (0.05) MEMMAX (20000) ARENA (~/Dev/HttpArena)
# ANOLE_REF and DEVIATION go into the key file; NFORCE overrides N (smoke tests).
set -u
bench=$(cd "$(dirname "$0")/.." && pwd)
. "$bench/lib/cpus.sh"
. "$bench/lib/key.sh"
ID=${ID:?set ID} TOOLS=${TOOLS:?set TOOLS to the directory with tcpload}
IMAGE=${IMAGE:-anole-bench/anole:atlas} TI=${TI:-anole-bench/atlas-tools}
BACKENDS=${BACKENDS:-"epoll uring"} REST=${REST:-70}
FRAC=${FRAC:-0.6} MEMFRAC=${MEMFRAC:-0.05} MEMMAX=${MEMMAX:-20000}
ARENA=${ARENA:-$HOME/Dev/HttpArena}
ALL="h1-plain h1-json h1-json-noconsole h1-jsoncomp-gzip h1-jsoncomp-br h1-jsoncomp-zstd tls-h1-json
  h2c-json-m10 h2c-json-m64 h2-static h3-json h3-static h3-post grpc-unary sse-h1 sse-h2c net-tcp"
CELLS=${*:-$ALL}
out=$bench/results/$ID/atlas
mkdir -p "$out"
log() { echo "$(date +%H:%M:%S) $*" | tee -a "$out/run.log"; }
SUT=$SUT_CPUS_1
EV=cpu_core/instructions/u,cpu_core/cycles/u,cpu_core/instructions/k,page-faults,context-switches

# The request files the loads share: HttpArena's static URI list on our
# ports, its gRPC body (as the interop server's UnaryCall reads it:
# SimpleRequest{response_type 1, response_size 2}), and a 16 KiB POST body.
req=$out/req; mkdir -p "$req"
sed 's#https://localhost:8443#https://127.0.0.1:8443#' "$ARENA/requests/static-h2-uris.txt" >"$req/static-uris.txt"
cp "$ARENA/requests/grpc-sum.bin" "$req/grpc.bin"
head -c 16384 /dev/zero | tr '\0' x >"$req/post16k.bin"

# def <cell>: the server mode and extra env, the load's arguments (h2load
# without -n/-D, or tcpload's), the connection count (for --rps per client),
# N for the count, and the kind.
def() {
  kind=http mode=h1 senv=() C=256 N=3000000
  local u=http://127.0.0.1:8080 s=https://127.0.0.1:8443 g=http://127.0.0.1:50051
  case $1 in
    h1-plain) args="--h1 -c256 -m1 -t8 $u/plaintext" ;;
    h1-json) args="--h1 -c256 -m1 -t8 $u/json" ;;
    h1-json-noconsole) args="--h1 -c256 -m1 -t8 $u/json"; senv=(-e ANOLE_CONSOLE=0) ;;
    h1-jsoncomp-*) args="--h1 -c256 -m1 -t8 -H Accept-Encoding:${1#h1-jsoncomp-} $u/json/50?m=6"; N=600000 ;;
    tls-h1-json) mode=tls args="--h1 -c256 -m1 -t8 $s/json"; N=1500000 ;;
    h2c-json-m10) args="-c256 -m10 -t8 $u/json"; N=4000000 ;;
    h2c-json-m64) args="-c256 -m64 -t8 $u/json"; N=6000000 ;;
    h2-static) mode=tls C=64 args="-c64 -m32 -t8 -H Accept-Encoding:br;q=1,gzip;q=0.8 -i /req/static-uris.txt"; N=600000 ;;
    h3-json) mode=h3 C=64 args="--alpn-list=h3 -c64 -m10 -t8 $s/json"; N=600000 ;;
    h3-static) mode=h3 C=64 args="--alpn-list=h3 -c64 -m64 -t8 -H Accept-Encoding:br;q=1,gzip;q=0.8 -i /req/static-uris.txt"; N=200000 ;;
    h3-post) mode=h3 C=64 args="--alpn-list=h3 -c64 -m10 -t8 -d /req/post16k.bin $s/echo"; N=200000 ;;
    grpc-unary) mode=grpc args="-c256 -m100 -t8 -d /req/grpc.bin -H content-type:application/grpc -H te:trailers $g/grpc.testing.TestService/UnaryCall"; N=3000000 ;;
    sse-h1) kind=sse senv=(-e SSE=1) C=4000 args="--h1 -c4000 -m1 -t8 $u/sse" ;;
    sse-h2c) kind=sse senv=(-e SSE=1) C=4000 args="-c4000 -m1 -t8 $u/sse" ;;
    net-tcp) kind=tcp senv=(-e NET_TCP_PORT=7000) C=256 args="-addr 127.0.0.1:7000 -conns 256 -size 64" ;;
    *) echo "unknown cell $1" >&2; return 1 ;;
  esac
}

ready() {
  local i
  for i in $(seq 120); do
    case $mode in
      h1) curl -s -o /dev/null http://127.0.0.1:8080/json && return 0 ;;
      tls|h3) curl -sk -o /dev/null https://127.0.0.1:8443/json && return 0 ;;
      grpc) (exec 3<>/dev/tcp/127.0.0.1/50051) 2>/dev/null && return 0 ;;
    esac
    sleep 0.5
  done
  return 1
}

tools() { # tools <dir> <docker args...>: the tools image, privileged, on the load CPUs
  local d=$1; shift
  docker run --rm --privileged --pid=host --cgroupns=host --network host --cpuset-cpus "$LOAD_CPUS" \
    --ulimit nofile=1048576:1048576 -v /lib/modules:/lib/modules:ro -v /usr/src:/usr/src:ro \
    -v /sys/kernel/debug:/sys/kernel/debug -v /sys/kernel/tracing:/sys/kernel/tracing \
    -v "$d:/out" -v "$req:/req:ro" -v "$TOOLS:/b:ro" "$@"
}

load_bg() { # load_bg <dir> <name> <entrypoint> <args...>: the load in the background, output to <name>.txt
  local d=$1 n=$2 e=$3; shift 3
  docker rm -f atlas-load >/dev/null 2>&1
  docker run -d --name atlas-load --network host --cpuset-cpus "$LOAD_CPUS" --ulimit nofile=1048576:1048576 \
    -v "$req:/req:ro" -v "$TOOLS:/b:ro" --entrypoint "$e" "$TI" "$@" >/dev/null
  echo "$n" >"$d/.bg"
}
bg_wait() { # bg_wait <dir>: waits for the background load and keeps its output
  local d=$1 n; n=$(cat "$d/.bg")
  docker wait atlas-load >/dev/null; docker logs atlas-load >"$d/$n.txt" 2>&1; docker rm atlas-load >/dev/null
  rm -f "$d/.bg"
}

rss_loop() { # rss_loop <cid> <pid> <file>: epoch memory.current VmRSS(kB) threads, every second
  local cg=/sys/fs/cgroup/system.slice/docker-$1.scope
  while [ -e "$cg/memory.current" ]; do
    echo "$(date +%s.%N) $(cat "$cg/memory.current" 2>/dev/null) $(awk '/^VmRSS/{print $2}' "/proc/$2/status" 2>/dev/null) $(awk '/^Threads/{print $2}' "/proc/$2/status" 2>/dev/null)" >>"$3"
    sleep 1
  done
}

memprobe() { # memprobe <pid> <seconds>: the bpftrace script; Anole's own probes where the binary has them
  local p=$1 s=$2 b=/proc/$1/root$exe l=/proc/$1/root$libc syms f
  syms=$(docker run --rm --privileged --pid=host --entrypoint nm "$TI" "$b" | awk '{print $3}')
  local st="ustack(perf, 48)"
  # The live-allocation maps outgrow bpftrace's default 4,096 keys at gRPC and h2c rates.
  echo "config = { max_map_keys = 4194304 }"
  echo "uprobe:$l:malloc /pid == $p/ { @a_malloc[$st] = sum(arg0); @c_malloc[$st] = count(); @sz[tid] = arg0; }"
  echo "uretprobe:$l:malloc /pid == $p && @sz[tid]/ { @live[retval] = @sz[tid]; @lst[retval] = $st; delete(@sz, tid); }"
  echo "uprobe:$l:free /pid == $p && @live[arg0]/ { delete(@live, arg0); delete(@lst, arg0); }"
  echo "uprobe:$l:calloc /pid == $p/ { @a_calloc[$st] = sum(arg0 * arg1); @c_calloc[$st] = count(); }"
  echo "uprobe:$l:realloc /pid == $p/ { @a_realloc[$st] = sum(arg1); @c_realloc[$st] = count(); }"
  echo "tracepoint:syscalls:sys_enter_mmap /pid == $p/ { @a_mmap[$st] = sum(args.len); @c_mmap[$st] = count(); }"
  echo "tracepoint:syscalls:sys_enter_brk /pid == $p/ { @c_brk[$st] = count(); }"
  # Zig's allocator vtable functions take (ctx, len, alignment, ret_addr): arg1 is the length.
  for f in heap.ArenaAllocator.alloc:arena block_cache.vtableAlloc:block heap.PageAllocator.alloc:page; do
    grep -qxF "${f%%:*}" <<<"$syms" &&
      echo "uprobe:$b:\"${f%%:*}\" { @a_${f##*:}[$st] = sum(arg1); @c_${f##*:}[$st] = count(); }"
  done
  for f in task.TaskPool.alloc:taskpool server.request_buffers.RequestBuffersPool.acquire:reqbufs coro.stack_pool.StackPool.acquire:stackpool; do
    grep -qxF "${f%%:*}" <<<"$syms" && echo "uprobe:$b:\"${f%%:*}\" { @c_${f##*:}[$st] = count(); }"
  done
  echo "interval:s:$s { clear(@sz); exit(); }"
}

one() { # one <backend> <cell>
  local be=$1 cell=$2 extra=() cid pid cg exe libc max rps rl cgs
  def "$cell" || return
  [ -n "${NFORCE:-}" ] && N=$NFORCE
  local d=$out/$be/$cell; mkdir -p "$d"
  [ "$be" = uring ] && extra+=(--security-opt seccomp=unconfined --ulimit memlock=-1:-1)
  docker rm -f atlas-sut >/dev/null 2>&1
  cid=$(docker run -d --name atlas-sut --network host --cpuset-cpus "$SUT" --cpus 1 --memory 2g --memory-swap 2g \
    --ulimit nofile=1048576:1048576 "${extra[@]}" -v "$bench/.data/certs:/certs:ro,z" -v "$ARENA/data:/arena:ro,z" \
    -e MODE=$mode -e WORKERS=1 -e TICK_HZ=0 -e ARENA_DATA=/arena "${senv[@]}" "$IMAGE")
  pid=$(docker inspect -f '{{.State.Pid}}' atlas-sut); cg=system.slice/docker-$cid.scope
  rss_loop "$cid" "$pid" "$d/rss.tsv" & rl=$!
  if ! ready; then
    log "$be $cell: server not ready"; docker logs atlas-sut >"$d/server.log" 2>&1
    docker rm -f atlas-sut >/dev/null; wait $rl; return
  fi
  exe=$(docker exec atlas-sut readlink /proc/1/exe)
  libc=$(docker exec atlas-sut sh -c 'for f in /lib/x86_64-linux-gnu/libc.so.6 /usr/lib64/libc.so.6; do [ -e $f ] && echo $f && break; done')
  docker exec atlas-sut ls -l /proc/1/fd 2>/dev/null | grep -o 'anon_inode:\[[a-z_]*\]' | sort | uniq -c >"$d/backend"
  cgs=$(printf "$cg,%.0s" 1 2 3 4 5); cgs=${cgs%,}

  if [ $kind = sse ]; then
    # Memory only: the probes attach, then C subscribers open and stay.
    sleep "$REST"
    memprobe "$pid" 25 >"$d/mem.bt"
    tools "$d" --name atlas-bt -d --entrypoint sh "$TI" -c "bpftrace /out/mem.bt >/out/mem.txt 2>/out/mem.err" >/dev/null
    sleep 4
    load_bg "$d" load-sse h2load $args -D 30 --warm-up-time 1
    sleep 22
    # /publish answers how many subscribers it reached: the per-subscriber divisor.
    curl -s -X POST --data tick http://127.0.0.1:8080/publish >"$d/subscribers"
    tools "$d" --entrypoint offcputime "$TI" -f -p "$pid" 5 >"$d/offcpu.folded" 2>"$d/offcpu.err"
    docker wait atlas-bt >/dev/null 2>&1; bg_wait "$d"
  else
    # Warm-up (not counted), rest, then the count.
    if [ $kind = tcp ]; then
      tools "$d" --entrypoint /b/tcpload "$TI" $args -warmup 0s -d 5s >"$d/warm.txt" 2>&1
      sleep "$REST"
      tools "$d" --entrypoint perf "$TI" stat -x, --no-big-num -a -C "$SUT" -e "$EV" -G "$cgs" \
        -o /out/count.perf.csv -- /b/tcpload $args -warmup 0s -d 10s >"$d/count.txt" 2>&1
      max=$(python3 -c "import json; print(json.load(open('$d/count.txt'))['msgs_per_s'])" 2>/dev/null)
    else
      tools "$d" --entrypoint h2load "$TI" $args -n $((N / 10)) >"$d/warm.txt" 2>&1
      sleep "$REST"
      tools "$d" --entrypoint perf "$TI" stat -x, --no-big-num -a -C "$SUT" -e "$EV" -G "$cgs" \
        -o /out/count.perf.csv -- h2load $args -n "$N" >"$d/count.txt" 2>&1
      max=$(awk '/^finished in/ {gsub(",", "", $4); print $4}' "$d/count.txt")
    fi
    max=${max%.*}; max=${max:-0}
    echo "$max" >"$d/max-rps"
    # CPU and off-CPU at FRAC of the max (tcp: saturating, tcpload has no rate).
    if [ $kind = tcp ]; then
      load_bg "$d" load-cpu /b/tcpload $args -warmup 2s -d 30s
    else
      rps=$(python3 -c "print(max(1, round($max * $FRAC / $C)))")
      load_bg "$d" load-cpu h2load $args --rps "$rps" -D 32 --warm-up-time 2
    fi
    sleep 3
    tools "$d" --entrypoint sh "$TI" -c "cd /tmp && perf record -F 999 -g -a -C $SUT -e cpu_core/cycles/ -G $cg -o perf.data -- sleep 15 2>/out/perf-record.log; \
      perf script -i perf.data 2>/dev/null | gzip >/out/perf-script.txt.gz"
    tools "$d" --entrypoint offcputime "$TI" -f -p "$pid" 10 >"$d/offcpu.folded" 2>"$d/offcpu.err"
    bg_wait "$d"
    # Memory at a low fixed load.
    memprobe "$pid" 10 >"$d/mem.bt"
    if [ $kind = tcp ]; then
      echo "saturating, 16 connections" >"$d/mem-rps"
      load_bg "$d" load-mem /b/tcpload -addr 127.0.0.1:7000 -conns 16 -size 64 -warmup 1s -d 18s
    else
      rps=$(python3 -c "print(max(1, round(min($max * $MEMFRAC, $MEMMAX) / $C)))")
      echo "$((rps * C))" >"$d/mem-rps"
      load_bg "$d" load-mem h2load $args --rps "$rps" -D 18 --warm-up-time 1
    fi
    sleep 2
    tools "$d" --entrypoint bpftrace "$TI" /out/mem.bt >"$d/mem.txt" 2>"$d/mem.err"
    bg_wait "$d"
  fi
  docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}}' atlas-sut >"$d/state"
  cat "/sys/fs/cgroup/$cg/memory.peak" >"$d/memory.peak" 2>/dev/null
  docker logs atlas-sut >"$d/server.log" 2>&1
  docker rm -f atlas-sut >/dev/null; wait $rl
  log "$be $cell: $(python3 "$bench/atlas/atlas-summary.py" one "$d" 2>&1 | tail -1)"
}

KEY_SCRIPT="bench/atlas/atlas.sh REST=$REST FRAC=$FRAC MEMFRAC=$MEMFRAC MEMMAX=$MEMMAX BACKENDS=$BACKENDS CELLS=$(echo $CELLS)" \
  write_key "$out/key.txt" "$TI" "atlas=$IMAGE,ARENA_DATA=/arena"
{
  echo "anole_ref=${ANOLE_REF:-unknown}"
  echo "side.atlas.grpc_binary_sha256=$(docker run --rm --entrypoint sha256sum "$IMAGE" /usr/local/bin/grpc-interop-server | cut -d' ' -f1)"
  echo "events=$EV"
  echo "deviation=${DEVIATION:-none}"
} >>"$out/key.txt"
log "start: cells $(echo $CELLS), backends $BACKENDS, image $IMAGE"
for cell in $CELLS; do for be in $BACKENDS; do one "$be" "$cell"; done; done
log done
