#!/usr/bin/env bash
# Runs the client scenarios of the flood-budget calibration against the test
# site through the counting proxy (tools/h2count/README.md). Each scenario
# gets its own label in the proxy's report.
#
#   SITE_BIN=zig-out/bin/h2count-site GRPC_BIN=zig-out/bin/grpc \
#     tools/h2count/scenarios/run.sh <outdir> [group ...]
#
# Groups: curl node gohttp chromium firefox grpc envoy h2load, and direct (curl
# and the Go client straight at the site's own TLS port, no proxy, no counting:
# the engine's secure path) (default: all but direct).
# Needs: go, curl, node >= 22; chromium-browser, firefox and docker for their
# groups (a group whose tool is missing is skipped with a note).
set -u
here=$(cd "$(dirname "$0")" && pwd)
out=${1:?usage: run.sh <outdir> [group ...]}; shift
groups=${*:-curl node gohttp chromium firefox grpc envoy h2load}
mkdir -p "$out"; out=$(cd "$out" && pwd)
SITE_PORT=18080 GRPC_PORT=18083 TLS_PORT=19443 DIRECT_PORT=18443 H2C_PORT=19080 GRPC_PROXY=19083 CTL=19990
CERT=$out/cert.pem
tmp=$(mktemp -d "${TMPDIR:-/tmp}/h2count-run.XXXXXX")
pids=()
cleanup() { for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done; wait; docker rm -f h2count-envoy >/dev/null 2>&1; rm -rf "$tmp"; }
trap cleanup EXIT
note() { echo "[$(date +%T)] $*" | tee -a "$out/run.log" >&2; }
# Browser scenarios report through the site's /done (drive.html); no line is a hang. Lines are only
# counted past the site.log size at the scenario's start.
verdict_since() { # <scenario> <drive name> <log size before>
  local new; new=$(tail -c +"$(($3 + 1))" "$out/site.log" | grep "^done s=$2 ")
  if echo "$new" | grep -q " ok=1" && ! echo "$new" | grep -q " ok=0"; then note "PASS $1"; else note "FAIL $1 (${new:-no /done line})"; fi
}
scn() { curl -s "127.0.0.1:$CTL/scenario?name=$1" >/dev/null; note "scenario $1"; }

( cd "$here/.." && go build -o "$tmp/h2count" . ) || exit 1
site_args=("$SITE_PORT")
case " $groups " in *" direct "*)
  command -v openssl >/dev/null && openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 -subj /CN=localhost \
    -addext subjectAltName=DNS:localhost,IP:127.0.0.1 -keyout "$tmp/direct.key" -out "$tmp/direct.pem" 2>/dev/null &&
    site_args+=("$DIRECT_PORT" "$tmp/direct.pem" "$tmp/direct.key") ;;
esac
"$SITE_BIN" "${site_args[@]}" >"$out/site.log" 2>&1 & pids+=($!)
listens=(-listen "tls@127.0.0.1:$TLS_PORT=127.0.0.1:$SITE_PORT" -listen "h2c@127.0.0.1:$H2C_PORT=127.0.0.1:$SITE_PORT")
if [ -n "${GRPC_BIN:-}" ]; then
  "$GRPC_BIN" "$GRPC_PORT" 18483 >"$out/grpc-server.log" 2>&1 & pids+=($!)
  listens+=(-listen "h2c@127.0.0.1:$GRPC_PROXY=127.0.0.1:$GRPC_PORT")
fi
"$tmp/h2count" "${listens[@]}" -out "$out/h2count.json" -cert-out "$CERT" -ctl "127.0.0.1:$CTL" -label start 2>"$out/h2count.log" & proxy=$!; pids+=($proxy)
for _ in $(seq 50); do curl -s "127.0.0.1:$CTL/scenario?name=start" >/dev/null && break; sleep 0.2; done
kill -0 $proxy 2>/dev/null || { cat "$out/h2count.log" >&2; exit 1; }
TLS="https://localhost:$TLS_PORT"; H2C="http://127.0.0.1:$H2C_PORT"
head -c $((16 << 20)) /dev/zero >"$tmp/up.bin"
big=(); for i in $(seq 20); do big+=(-H "X-Big$i: $(head -c 15000 /dev/urandom | base64 -w0 | tr -d '+/=' | head -c 10000)"); done # 200 KB in 20 fields
for n in 30000; do { printf 'X-Big: '; head -c $((n * 2)) /dev/urandom | base64 -w0 | tr -d '+/=' | head -c $n; } >"$tmp/hdr$((n / 1000))k"; done
has() { command -v "$1" >/dev/null || { note "skipped $2: $1 not found"; return 1; }; }

run_curl() {
  scn curl-load-tls
  curl -s -Z --parallel-max 100 --http2 --cacert "$CERT" -o /dev/null "$TLS/r/[1-100].png"
  scn curl-load-h2c
  curl -s -Z --parallel-max 100 --http2-prior-knowledge -o /dev/null "$H2C/r/[1-100].png"
  scn curl-abort
  for _ in 1 2 3; do curl -s --max-time 1 --http2 --cacert "$CERT" -o /dev/null "$TLS/download"; done
  curl -s -Z --max-time 1 --http2 --cacert "$CERT" -o /dev/null "$TLS/download?[1-20]"
  scn curl-upload
  curl -s --http2 --cacert "$CERT" --data-binary @"$tmp/up.bin" -o /dev/null "$TLS/upload"
  scn curl-sse
  curl -s -N --max-time 3 --http2 --cacert "$CERT" -o /dev/null "$TLS/sse"
  scn curl-header-30k
  curl -s --http2 --cacert "$CERT" -H @"$tmp/hdr30k" -o /dev/null -w "30k header: %{http_code}\n" "$TLS/r/1" | tee -a "$out/run.log"
  scn curl-header-200k
  curl -s --http2 --cacert "$CERT" "${big[@]}" -o /dev/null -w "200k header: %{http_code} (000 = curl refused or the connection ended)\n" "$TLS/r/1" | tee -a "$out/run.log"
  scn raw-continuation
  node "$here/rawcont.mjs" 127.0.0.1 "$H2C_PORT" | tee -a "$out/run.log"
  scn raw-priority   # synthetic: 5000 PRIORITY_UPDATE then 5000 PRIORITY, each in one write
  node "$here/rawprio.mjs" 127.0.0.1 "$H2C_PORT" | tee -a "$out/run.log"
}

run_node() {
  for ph in page download cancel upload ping; do
    [ $ph = ping ] && scn node-ping-tool-driven || scn "node-$ph"
    timeout 60 node "$here/node-h2.mjs" "$TLS" "$CERT" $ph >>"$out/run.log" 2>&1 && note "PASS node-$ph" || note "FAIL node-$ph (exit $?)"
  done
}

browser_scenarios() { # <name> <launcher: function taking url seconds>
  for s in load:10 reload:10 abort:10 sse:8 upload:12 download:20 nav:8; do
    scn "$1-${s%%:*}"
    local before; before=$(stat -c %s "$out/site.log")
    "$2" "$TLS/drive?s=${s%%:*}" "${s##*:}"
    verdict_since "$1-${s%%:*}" "${s%%:*}" "$before"
  done
}
launch_chromium() {
  local prof; prof=$(mktemp -d "$tmp/chromium.XXXXXX")
  timeout -k 3 "$2" chromium-browser --headless=new --user-data-dir="$prof" --ignore-certificate-errors --no-first-run --disable-gpu --disable-background-networking --disable-component-update "$1" >/dev/null 2>&1
  sleep 1; rm -rf "$prof"
}
launch_firefox() {
  local prof; prof=$(mktemp -d "$tmp/firefox.XXXXXX")
  node "$here/bidi.mjs" firefox "$prof" "$1" "$2" >>"$out/run.log" 2>&1
  sleep 1; rm -rf "$prof"
}

run_grpc() {
  [ -n "${GRPC_BIN:-}" ] || { note "skipped grpc: no GRPC_BIN"; return; }
  scn grpc-go
  ( cd "$here/../clients/grpcgo" && go run . -addr "127.0.0.1:$GRPC_PROXY" ) 2>&1 | tee -a "$out/run.log"
  [ "${PIPESTATUS[0]}" = 0 ] && note "PASS grpc-go" || note "FAIL grpc-go"
}

run_gohttp() { # through the proxy: TLS (ALPN h2) and h2c prior knowledge, both counted
  ( cd "$here/../clients/gohttp" && go build -o "$tmp/gohttp" . ) || { note "FAIL gohttp build"; return; }
  scn gohttp-tls
  "$tmp/gohttp" -url "$TLS" -ca "$CERT" 2>&1 | tee -a "$out/run.log"; [ "${PIPESTATUS[0]}" = 0 ] && note "PASS gohttp-tls" || note "FAIL gohttp-tls"
  scn gohttp-h2c
  "$tmp/gohttp" -url "$H2C" -h2c 2>&1 | tee -a "$out/run.log"; [ "${PIPESTATUS[0]}" = 0 ] && note "PASS gohttp-h2c" || note "FAIL gohttp-h2c"
}

run_direct() { # the site's own TLS port: not counted, only success (the proxy would hide the engine's secure path)
  [ -s "$tmp/direct.pem" ] || { note "skipped direct: no openssl"; return; }
  ( cd "$here/../clients/gohttp" && go build -o "$tmp/gohttp" . ) || { note "FAIL direct build"; return; }
  local u="https://localhost:$DIRECT_PORT" c; c=$(curl -s -Z --parallel-max 100 --http2 --cacert "$tmp/direct.pem" -o /dev/null -w "%{http_version} %{http_code}\n" "$u/r/[1-100].png" | sort | uniq -c)
  note "direct curl 100 GETs: $c"; echo "$c" | grep -q " 2 200" && ! echo "$c" | grep -qv " 2 200" || note "FAIL direct-curl-get"
  local n; n=$(curl -s --http2 --cacert "$tmp/direct.pem" --data-binary @"$tmp/up.bin" "$u/upload"); note "direct curl upload echoed $n"; [ "$n" = $((16 << 20)) ] && note "PASS direct-curl" || note "FAIL direct-curl-upload"
  "$tmp/gohttp" -url "$u" -ca "$tmp/direct.pem" 2>&1 | tee -a "$out/run.log"; [ "${PIPESTATUS[0]}" = 0 ] && note "PASS direct-gohttp" || note "FAIL direct-gohttp"
}

run_envoy() {
  has docker envoy || return
  local tag=${ENVOY_TAG:-v1.34.1}
  docker image inspect "envoyproxy/envoy:$tag" >/dev/null 2>&1 || { note "skipped envoy: image envoyproxy/envoy:$tag not pulled"; return; }
  note "envoy digest $(docker image inspect "envoyproxy/envoy:$tag" --format '{{index .RepoDigests 0}}')"
  for variant in default keepalive; do
    local ka=""
    [ $variant = keepalive ] && ka=$'            connection_keepalive: { interval: 5s, timeout: 2s }'
    sed -e "s|__UPSTREAM_PORT__|$H2C_PORT|" "$here/envoy.yaml" | awk -v ka="$ka" '/__KEEPALIVE__/{ if (ka != "") print ka; else print "            {}"; next } {print}' >"$tmp/envoy-$variant.yaml"
    scn "envoy-$variant"   # before the container: its readiness probe opens the first pooled upstream connection
    docker run -d --rm --name h2count-envoy --network host -v "$tmp/envoy-$variant.yaml:/etc/envoy/envoy.yaml:ro" "envoyproxy/envoy:$tag" -c /etc/envoy/envoy.yaml --log-level warning >/dev/null
    for _ in $(seq 50); do curl -s -o /dev/null http://127.0.0.1:10000/r/1 && break; sleep 0.2; done
    curl -s -Z --parallel-max 100 -o /dev/null "http://127.0.0.1:10000/r/[1-100].png"
    curl -s -Z --max-time 1 -o /dev/null "http://127.0.0.1:10000/download?[1-10]"
    curl -s --max-time 12 -o /dev/null http://127.0.0.1:10000/sse   # an idle-ish stream so a 5 s keepalive fires
    docker rm -f h2count-envoy >/dev/null
  done
}

run_h2load() {
  has docker h2load || return
  docker image inspect h2load:latest >/dev/null 2>&1 || { note "skipped h2load: image h2load:latest missing"; return; }
  note "h2load image $(docker image inspect h2load:latest --format '{{.Id}}')"
  scn h2load-synthetic
  docker run --rm --name h2count-h2load --network host h2load:latest -n 2000 -c 4 -m 100 "$TLS/r/1" 2>&1 | grep -E "^(requests|status codes)" | tee -a "$out/run.log"
}

for g in $groups; do
  case $g in
    curl) run_curl ;;
    node) run_node ;;
    chromium) has chromium-browser chromium && browser_scenarios chromium launch_chromium ;;
    firefox) has firefox firefox && browser_scenarios firefox launch_firefox ;;
    gohttp) run_gohttp ;;
    direct) run_direct ;;
    grpc) run_grpc ;;
    envoy) run_envoy ;;
    h2load) run_h2load ;;
    *) note "unknown group $g" ;;
  esac
done
curl -s "127.0.0.1:$CTL/dump" >/dev/null
sleep 0.5
note "report: $out/h2count.json"
