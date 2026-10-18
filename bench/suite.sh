#!/bin/sh
# The cross-framework benchmark: builds the images it needs, records the
# environment, and runs benchctl (bench/tools) in the load-generator
# container, pinned to LOAD_CPUS (bench/lib/cpus.sh).
#
#   bench/suite.sh                                   # quick profile, everything
#   bench/suite.sh -profile full                     # the overnight run
#   bench/suite.sh -only raw -servers anole,fiber -tiers 1
#   NO_BUILD=1 bench/suite.sh ...                    # reuse the images as built
#   RESULTS=<id> bench/suite.sh -only grpc ...       # add cases to an earlier run
#
# Results go to bench/results/<UTC date>-<commit>[-<RUN_TAG>]/: cases.jsonl
# (one line per case), env.json and report.md.
set -eu
bench=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$bench")
. "$bench/lib/cpus.sh"

servers=anole,fiber,gohttp,axum,express,fastify,fastapi,nginx,gohttp-wt,axum-wt,fastify-wt,fastapi-wt
prev=
for a in "$@"; do
  case "$prev" in -servers|--servers) servers=$a ;; esac
  prev=$a
done

"$bench/lib/certs.sh"
# Postgres is needed by the $12 scenario (in every run without -only).
case " $* " in
*twelve*) "$bench/postgres/run.sh" start ;;
*" -only "*) ;;
*) "$bench/postgres/run.sh" start ;;
esac
mkdir -p "$bench/.data/media" "$bench/results"

if [ -z "${NO_BUILD:-}" ]; then
  for s in $(echo "$servers" | tr , ' '); do
    case "$s" in *@*) continue ;; esac # a tagged image (name@tag) is used as built
    echo "building anole-bench/$s" >&2
    docker build -q -f "$bench/servers/$s/Dockerfile" -t "anole-bench/$s" "$root" >/dev/null
  done
  echo "building anole-bench/loadgen" >&2
  docker build -q -f "$bench/loadgen/Dockerfile" -t anole-bench/loadgen "$root" >/dev/null
fi

sha=$(git -C "$root" rev-parse --short HEAD)
dirty=$(git -C "$root" status --porcelain -- src build.zig build.zig.zon bench/servers | head -1)
id=${RESULTS:-$(date -u +%Y%m%d-%H%M)-$sha${dirty:+-dirty}${RUN_TAG:+-$RUN_TAG}}
out=$bench/results/$id
mkdir -p "$out"

# The environment, for the report (an earlier run's, when adding to it).
[ -f "$out/env.json" ] || {
  printf '{\n'
  printf '  "commit": "%s%s",\n' "$(git -C "$root" rev-parse HEAD)" "${dirty:+ (dirty)}"
  printf '  "date": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '  "cpu": "%s",\n' "$(sed -n 's/^model name\t*: //p' /proc/cpuinfo | head -1)"
  printf '  "kernel": "%s",\n' "$(uname -r)"
  printf '  "governor": "%s",\n' "$(cat /sys/devices/system/cpu/cpu2/cpufreq/scaling_governor 2>/dev/null || echo unknown)"
  printf '  "docker": "%s",\n' "$(docker version --format '{{.Server.Version}}')"
  printf '  "cpusets": {"sut_1cpu": "%s", "sut_4cpu": "%s", "postgres": "%s", "loadgen": "%s"},\n' \
    "$SUT_CPUS_1" "$SUT_CPUS_4" "$PG_CPUS" "$LOAD_CPUS"
  printf '  "images": {'
  sep=
  for s in $(echo "$servers" | tr , ' ') loadgen; do
    printf '%s"%s": "%s"' "$sep" "$s" "$(docker image inspect -f '{{.Id}}' "anole-bench/$(echo "$s" | tr @ :)" 2>/dev/null | cut -c8-19)"
    sep=', '
  done
  printf '}\n}\n'
} >"$out/env.json"

echo "results: $out" >&2
docker rm -f anole-bench-loadgen >/dev/null 2>&1 || true
exec docker run --rm --name anole-bench-loadgen --network host \
  --cpuset-cpus "$LOAD_CPUS" --ulimit nofile=1048576:1048576 \
  --security-opt label=disable \
  -u "$(id -u):$(id -g)" --group-add "$(stat -c %g /var/run/docker.sock)" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /sys/fs/cgroup:/host/cgroup:ro \
  -v "$bench:/bench" \
  -e BENCH_HOST_DIR="$bench" -e HOST_CGROUP=/host/cgroup \
  -e SUT_CPUS_1="$SUT_CPUS_1" -e SUT_CPUS_4="$SUT_CPUS_4" -e LOAD_CPUS="$LOAD_CPUS" \
  -e PG_CPUS="$PG_CPUS" -e PG_CPUS_TWELVE="$PG_CPUS_TWELVE" \
  anole-bench/loadgen suite "$@" -out "/bench/results/$id"
