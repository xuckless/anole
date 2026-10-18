#!/bin/sh
# Anole's HTTP/3 server against aioquic (an independent QUIC and HTTP/3
# stack): downloads, uploads with checksums, echoes, many streams at once,
# and a drain that lets a download in flight finish.
#   tests/h3/run.sh [path-to-h3-test-server]
# Needs python3; aioquic is installed into a throwaway venv.
set -eu
server=${1:-zig-out/bin/h3-test-server}
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
pid=""
trap '[ -n "$pid" ] && kill -9 $pid 2>/dev/null; rm -rf "$work"' EXIT
python3 -m venv "$work/venv"
"$work/venv/bin/pip" install -q aioquic==1.7.0
py="$work/venv/bin/python -I $here/client.py"
port=18543
url=https://127.0.0.1:$port

start() { "$server" $port "$@" >"$work/server.log" 2>&1 & pid=$!; sleep 1; }
fail() { echo "FAIL $1"; tail -20 "$work/server.log"; exit 1; }

start
for n in 0 1000 70000 1000000 10000000; do
  out=$($py "$url/download?n=$n" --quiet) || fail "download $n"
  [ "$out" = "status 200 bytes $n
1 responses" ] || fail "download $n: $out"
  echo "PASS download $n"
done
for n in 1 50000 1000000 5000000; do
  head -c $n /dev/urandom >"$work/body"
  want=$(python3 -I -c "import sys; d=open(sys.argv[1],'rb').read(); print(len(d), sum(d) & 0xffffffff)" "$work/body")
  got=$($py "$url/upload" --method POST --data-file "$work/body" | sed -n 's/^body ([0-9]* bytes): //p')
  [ "$got" = "$want" ] || fail "upload $n: got '$got', want '$want'"
  echo "PASS upload $n"
  out=$($py "$url/echo" --method POST --data-file "$work/body" --quiet | head -1)
  [ "$out" = "status 200 bytes $n" ] || fail "echo $n: $out"
  echo "PASS echo $n"
done
out=$($py "$url/download?n=100000" --parallel 50 --repeat 2 --quiet | grep -c "status 200 bytes 100000")
[ "$out" = 100 ] || fail "parallel: $out of 100"
echo "PASS 100 streams on one connection"
out=$($py "$url/nothing-here" --quiet | head -1)
[ "$out" = "status 404 bytes 14" ] || fail "404: $out"
echo "PASS 404"

# A drain lets a download in flight finish.
$py "$url/download?n=3000000" --quiet >"$work/mid" 2>&1 &
client=$!
sleep 0.5
kill -TERM $pid
wait $client || true
grep -q "status 200 bytes 3000000" "$work/mid" || fail "drain: $(cat "$work/mid")"
for i in $(seq 1 200); do kill -0 $pid 2>/dev/null || break; sleep 0.05; done
kill -0 $pid 2>/dev/null && fail "server still running after the drain"
grep -qiE "leaked|panic" "$work/server.log" && fail "leak or panic in the server log"
pid=""
echo "PASS drain"
# Address validation: a Retry round trip, then the request.
start retry
out=$($py "$url/download?n=70000" --quiet | head -1)
[ "$out" = "status 200 bytes 70000" ] || fail "retry: $out"
kill -TERM $pid
for i in $(seq 1 200); do kill -0 $pid 2>/dev/null || break; sleep 0.05; done
grep -qiE "leaked|panic" "$work/server.log" && fail "leak or panic with retry"
pid=""
echo "PASS address validation (Retry)"
echo "all HTTP/3 checks passed"
