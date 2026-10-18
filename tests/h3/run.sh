#!/bin/sh
# Anole's HTTP/3 server against aioquic's client (an independent QUIC and
# HTTP/3 stack): downloads, uploads with checksums, echoes, many streams at
# once, a drain that lets a download in flight finish, and Retry. Then
# anole.h3's client against aioquic's server.
#   tests/h3/run.sh [path-to-h3-test-server] [path-to-h3-test-client]
# Needs python3; aioquic is installed into a throwaway venv.
set -eu
server=${1:-zig-out/bin/h3-test-server}
client=${2:-zig-out/bin/h3-test-client}
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
pid=""
trap '[ -n "$pid" ] && kill -9 $pid 2>/dev/null; [ -n "$peer" ] && kill -9 $peer 2>/dev/null; rm -rf "$work"' EXIT
peer=""
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
downloader=$!
sleep 0.5
kill -TERM $pid
wait $downloader || true
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
# Bound to every interface: replies must leave from the address each client
# wrote to (PKTINFO). On Linux all of 127/8 is local, so 127.0.0.2 is a
# second address to write to.
start 0.0.0.0
hosts=127.0.0.1
[ "$(uname)" = Linux ] && hosts="127.0.0.1 127.0.0.2"
for host in $hosts; do
  out=$($py "https://$host:$port/download?n=1000000" --quiet | head -1)
  [ "$out" = "status 200 bytes 1000000" ] || fail "wildcard via $host: $out"
  echo "PASS wildcard bind, via $host"
done
kill -9 $pid
pid=""
# anole.h3's client against aioquic's server.
"$client" cert "$work"
"$work/venv/bin/python" -I "$here/peer_server.py" $port "$work/cert.pem" "$work/key.pem" >"$work/peer.log" 2>&1 &
peer=$!
sleep 1
ca="$work/cert.pem"
pfail() { echo "FAIL $1"; tail -20 "$work/peer.log"; exit 1; }
for n in 0 1000 1000000 10000000; do
  want=$(python3 -I -c "import sys; n=int(sys.argv[1]); p=bytes(range(251)); print(sum((p*(n//251+1))[:n]) & 0xffffffff)" $n)
  out=$("$client" get $port "$ca" "/download?n=$n") || pfail "client download $n"
  [ "$out" = "status 200 bytes $n sum $want" ] || pfail "client download $n: $out"
  echo "PASS client download $n"
done
for n in 1 50000 5000000; do
  head -c $n /dev/urandom >"$work/body"
  want=$(python3 -I -c "import sys; d=open(sys.argv[1],'rb').read(); print(len(d), sum(d) & 0xffffffff)" "$work/body")
  out=$("$client" post $port "$ca" /echo "$work/body") || pfail "client echo $n"
  [ "$out" = "status 200 bytes $(echo $want | sed "s/ / sum /")" ] || pfail "client echo $n: $out, want $want"
  echo "PASS client echo $n"
done
out=$("$client" get $port "$ca" /trailers)
[ "$out" = "status 200 bytes 4 sum 430
trailer x-checksum abc" ] || pfail "client trailers: $out"
echo "PASS client trailers"
out=$("$client" many $port "$ca" "/download?n=100000" 200)
[ "$out" = "ok 200" ] || pfail "client streams: $out"
echo "PASS client 200 streams on one connection"
kill $peer
peer=""

echo "all HTTP/3 checks passed"
