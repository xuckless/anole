#!/bin/bash
# The video-call benchmark (bench/videocall/SPEC.md): for each transport and
# app, one rested ramp (70 s idle first), one more user every STEP until the
# server crashes or calls collapse; then the probe call's quality pass and
# the chart page.
#
#   bench/videocall/run.sh [results-id]          # all of it
#   SERVERS="anole bun" TRANSPORTS=ws STEP=5s bench/videocall/run.sh test-1
#   MEDIA_DEFLATE=off bench/videocall/run.sh <id>   # a pure relay
#   EXTRA="-batch 10" SKIP="anole-ws" bench/videocall/run.sh <id>   # 10 users a step
#   URING=1 ...       # the servers may use io_uring (Docker's seccomp blocks it)
#   VCLOAD=<binary>   # a vcload build to use in place of the image's
#
# Server: 1 CPU (SUT_CPUS_1) / 2 GB, no swap. Load generator: LOAD_CPUS.
# Images: anole-bench/vc-<app> (each servers/<app>/Dockerfile),
# anole-bench/loadgen (vcload), anole-bench/vc-media (clip and scoring).
set -u
bench=$(cd "$(dirname "$0")/.." && pwd)
. "$bench/lib/cpus.sh"
id=${1:-$(date +%Y%m%d-%H%M)-videocall}
out=$bench/results/$id/videocall
mkdir -p "$out"
SERVERS=${SERVERS:-"anole bun fiber axum"}
TRANSPORTS=${TRANSPORTS:-"ws wt"}
STEP=${STEP:-5s}
REST=${REST:-70}
EXTRA=${EXTRA:-}
# off: the servers relay media as it came, without deflating it.
MEDIA_DEFLATE=${MEDIA_DEFLATE:-on}
# app-transport pairs already measured in this results directory, kept as they are.
SKIP=${SKIP:-}
uring=(); [ "${URING:-0}" = 1 ] && uring=(--security-opt seccomp=unconfined --ulimit memlock=-1:-1)
vcload=(); [ -n "${VCLOAD:-}" ] && vcload=(-v "$VCLOAD:/usr/local/bin/vcload:ro")
media=$bench/.data/media/vc
sh "$bench/lib/certs.sh" >/dev/null
[ -f "$media/video.h264" ] || docker run --rm -v "$media:/out:z" anole-bench/vc-media sh -c "gen.sh /out >/dev/null && chown -R $(id -u):$(id -g) /out"

log() { echo "$(date +%H:%M:%S) $*" | tee -a "$out/run.log"; }

read -ra servers <<<"$SERVERS"
k=0
for transport in $TRANSPORTS; do
  n=${#servers[@]}
  for ((i = 0; i < n; i++)); do
    app=${servers[$(((i + k) % n))]}
    dir=$out/$app-$transport
    case " $SKIP " in *" $app-$transport "*) continue ;; esac
    rm -rf "$dir"
    mkdir -p "$dir"
    sleep "$REST"
    docker rm -f vc-sut >/dev/null 2>&1
    cid=$(docker run -d --name vc-sut --network host \
      --cpuset-cpus "$SUT_CPUS_1" --cpus 1 --memory 2g --memory-swap 2g \
      --ulimit nofile=1048576:1048576 "${uring[@]}" \
      -v "$bench/.data/certs:/certs:ro,z" -e PORT=8443 -e MEDIA_DEFLATE="$MEDIA_DEFLATE" "anole-bench/vc-$app")
    ready=0
    for _ in $(seq 60); do
      curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:8443/health 2>/dev/null | grep -q 200 && { ready=1; break; }
      sleep 0.5
    done
    if [ $ready = 0 ]; then
      log "$app $transport: not ready"; docker logs vc-sut >"$dir/server.log" 2>&1; docker rm -f vc-sut >/dev/null; continue
    fi
    log "$app $transport: ramp"
    docker run --rm --name vc-load --network host --cpuset-cpus "$LOAD_CPUS" \
      --ulimit nofile=1048576:1048576 --security-opt label=disable \
      -u "$(id -u):$(id -g)" -e MEDIA_DEFLATE="$MEDIA_DEFLATE" \
      -v /sys/fs/cgroup:/host/cgroup:ro -v "$media:/data/media/vc:ro" -v "$dir:/out" "${vcload[@]}" \
      --entrypoint vcload anole-bench/loadgen \
      -transport "$transport" -url https://127.0.0.1:8443 -step "$STEP" \
      -cgroup "/host/cgroup/system.slice/docker-$cid.scope" -out /out $EXTRA >"$dir/vcload.log" 2>&1
    state=$(docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}}' vc-sut 2>/dev/null)
    docker logs vc-sut >"$dir/server.log" 2>&1
    docker rm -f vc-sut >/dev/null
    echo "{\"container\":\"$state\"}" >"$dir/container.json"
    log "$app $transport: $(tail -1 "$dir/vcload.log") [$state]"
  done
  k=$((k + 1))
done

# QUALITY=0 leaves the quality pass and the page to a later invocation.
[ "${QUALITY:-1}" = 0 ] && exit 0
log "quality pass"
for d in "$out"/*-*/; do
  [ -f "$d/probe.csv" ] || continue
  docker run --rm --cpuset-cpus "$LOAD_CPUS" -u "$(id -u):$(id -g)" \
    -v "$d:/run" -v "$media:/media:z" anole-bench/vc-media quality.py /run /media 2>&1 | tee -a "$out/run.log"
done
rm -rf "$media/.work"
python3 "$bench/videocall/report.py" "$out" && log "chart: $out/index.html"
