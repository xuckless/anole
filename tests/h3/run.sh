#!/bin/sh
# Anole's HTTP/3 server against aioquic's client (an independent QUIC and
# HTTP/3 stack): downloads, uploads with checksums, echoes (also on noWait
# routes, run inline), many streams at once, a drain that lets a download in
# flight finish, Retry, resumption and 0-RTT, WebTransport and WebSocket
# over HTTP/3. Then
# anole.h3's client against aioquic's server.
#   tests/h3/run.sh [path-to-h3-test-server] [path-to-h3-test-client]
# Needs python3; aioquic is installed into a throwaway venv.
set -eu
server=${1:-zig-out/bin/h3-test-server}
client=${2:-zig-out/bin/h3-test-client}
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../lib/wait.sh"
work=$(mktemp -d)
pid=""
trap '[ -n "$pid" ] && kill -9 $pid 2>/dev/null; [ -n "$peer" ] && kill -9 $peer 2>/dev/null; rm -rf "$work"' EXIT
peer=""
python3 -m venv "$work/venv"
"$work/venv/bin/pip" install -q --require-hashes -r "$here/requirements.txt"
py="$work/venv/bin/python -I $here/client.py"
port=${ANOLE_H3_PORT:-18543}
url=https://127.0.0.1:$port

fail() { echo "FAIL $1"; tail -20 "$work/server.log"; exit 1; }
# Starts the server and waits until it says every listener is bound (or it
# exited).
up() { log_has "$work/server.log" "h3 test server ready" || gone $pid; }
start() {
  "$server" $port "$@" >"$work/server.log" 2>&1 &
  pid=$!
  wait_until 30 "the h3 test server to listen" up || fail "the server did not start"
  gone $pid && fail "the server exited at start"
  return 0
}
# Waits for the server to exit (after a TERM).
stopped() { wait_until 30 "the h3 test server to exit" gone $pid || fail "$1"; }

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
for n in 0 1000 1000000; do
  out=$($py "$url/nw/download?n=$n" --quiet) || fail "noWait download $n"
  [ "$out" = "status 200 bytes $n
1 responses" ] || fail "noWait download $n: $out"
  echo "PASS noWait download $n"
done
for n in 1 50000 1000000; do
  head -c $n /dev/urandom >"$work/body"
  out=$($py "$url/nw/echo" --method POST --data-file "$work/body" --quiet | head -1)
  [ "$out" = "status 200 bytes $n" ] || fail "noWait echo $n: $out"
  echo "PASS noWait echo $n"
done
out=$($py "$url/nw/download?n=100000" --parallel 50 --repeat 2 --quiet | grep -c "status 200 bytes 100000")
[ "$out" = 100 ] || fail "noWait parallel: $out of 100"
echo "PASS noWait, 100 streams on one connection"
out=$($py "$url/nothing-here" --quiet | head -1)
[ "$out" = "status 404 bytes 14" ] || fail "404: $out"
echo "PASS 404"

# A drain lets a download in flight finish.
$py "$url/download?n=3000000&announce" --quiet >"$work/mid" 2>&1 &
downloader=$!
wait_until 30 "the download to start" log_has "$work/server.log" "download started" || fail "drain: the download never started"
kill -TERM $pid
wait $downloader || true
grep -q "status 200 bytes 3000000" "$work/mid" || fail "drain: $(cat "$work/mid")"
stopped "server still running after the drain"
grep -qiE "leaked|panic" "$work/server.log" && fail "leak or panic in the server log"
pid=""
echo "PASS drain"
# The drain's hard deadline: a request that never finishes (within any
# wait here) is cut off.
start drain=1000
$py "$url/slow?ms=3600000" --quiet >"$work/slow" 2>&1 &
slowpid=$!
wait_until 30 "the slow request to start" log_has "$work/server.log" "slow request started" || fail "drain deadline: the request never started"
kill -TERM $pid
stopped "server still running long after a 1 s drain"
kill -9 $slowpid 2>/dev/null || true
grep -qiE "leaked|panic" "$work/server.log" && fail "leak or panic after the drain deadline"
pid=""
echo "PASS drain deadline"
# Address validation: a Retry round trip, then the request.
start retry
out=$($py "$url/download?n=70000" --quiet | head -1)
[ "$out" = "status 200 bytes 70000" ] || fail "retry: $out"
kill -TERM $pid
stopped "server still running after a TERM (retry)"
grep -qiE "leaked|panic" "$work/server.log" && fail "leak or panic with retry"
pid=""
echo "PASS address validation (Retry)"
# Resumption and 0-RTT: a ticket from a first connection, then requests in
# 0-RTT on a second. A GET may run before the handshake completes; a POST
# waits for it (so it is never a replay, and says "late").
start early
ticket="$work/ticket"
out=$($py "$url/early" --session-ticket "$ticket" | tail -1)
[ "$out" = "resumed 0 early 0" ] || fail "first connection: $out"
[ -s "$ticket" ] || fail "no session ticket"
out=$($py "$url/early" --session-ticket "$ticket" --zero-rtt)
echo "$out" | grep -q "^status 200" || fail "0-RTT GET: $out"
[ "$(echo "$out" | tail -1)" = "resumed 1 early 1" ] || fail "0-RTT GET: $out"
echo "PASS 0-RTT GET (body: $(echo "$out" | sed -n 's/^body ([0-9]* bytes): //p'))"
out=$($py "$url/early" --method POST --data x --session-ticket "$ticket" --zero-rtt)
echo "$out" | grep -q "^body (4 bytes): late" || fail "0-RTT POST: $out"
[ "$(echo "$out" | tail -1)" = "resumed 1 early 1" ] || fail "0-RTT POST: $out"
echo "PASS 0-RTT POST held until the handshake"
kill -TERM $pid
stopped "server still running after a TERM (0-RTT)"
grep -qiE "leaked|panic" "$work/server.log" && fail "leak or panic with 0-RTT"
pid=""
# WebTransport (draft-02) and WebSocket over HTTP/3 (RFC 9220) on aioquic's
# client: streams both ways, datagrams, a close from either side, and the
# drain (DRAIN_WEBTRANSPORT_SESSION then a close; WebSocket 1001).
start
xc="$work/venv/bin/python -I $here/extended_connect.py"
for mode in wt wt-close ws; do
  $xc $mode $port >"$work/xc" 2>&1 || { cat "$work/xc"; fail "extended CONNECT $mode"; }
  sed 's/^/  /' "$work/xc"
done
$xc wt-hold $port >"$work/wt-hold" 2>&1 &
$xc ws-hold $port >"$work/ws-hold" 2>&1 &
wait_until 30 "the WebTransport session to open" log_has "$work/wt-hold" "^PASS WebTransport session accepted" || fail "WebTransport hold: $(cat "$work/wt-hold")"
wait_until 30 "the WebSocket to open" log_has "$work/ws-hold" "^PASS WebSocket over HTTP/3 accepted" || fail "WebSocket hold: $(cat "$work/ws-hold")"
kill -TERM $pid
stopped "server still running after a TERM (WebTransport)"
wait
grep -qx "capsules 0x78ae 0x2843:00000000'server shutting down'" "$work/wt-hold" || fail "WebTransport drain: $(cat "$work/wt-hold")"
grep -qx "close 1001 server shutting down" "$work/ws-hold" || fail "WebSocket drain: $(cat "$work/ws-hold")"
grep -qiE "leaked|panic" "$work/server.log" && fail "leak or panic with WebTransport"
pid=""
echo "PASS drain: WebTransport DRAIN and CLOSE capsules, WebSocket 1001"
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
ca="$work/cert.pem"
pfail() { echo "FAIL $1"; tail -20 "$work/peer.log"; exit 1; }
peer_up() { log_has "$work/peer.log" "^listening" || gone $peer; }
wait_until 30 "aioquic's server to listen" peer_up || pfail "aioquic's server did not start"
gone $peer && pfail "aioquic's server exited at start"
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
want=$(python3 -I -c "p=bytes(range(251)); print(sum((p*40)[:10000]) & 0xffffffff)")
out=$("$client" zerortt $port "$ca" "/download?n=10000")
[ "$out" = "status 200 bytes 10000 sum $want
resumed 0 early none
status 200 bytes 10000 sum $want
resumed 1 early accepted" ] || pfail "client 0-RTT: $out"
echo "PASS client resumption and 0-RTT"
out=$("$client" wt $port "$ca" /wt) || pfail "client WebTransport: $out"
[ "$out" = "session open
bidirectional ok 300000
unidirectional one way
datagram d1
datagram datagram two
closed by peer 7 asked to
second session closed" ] || pfail "client WebTransport: $out"
wait_until 30 "the server to see the WebTransport close" log_has "$work/peer.log" "^wt closed 4242 client done$" || pfail "client WebTransport close not seen by the server"
echo "PASS client WebTransport: streams, datagrams, a close from either side"
kill $peer
peer=""

echo "all HTTP/3 checks passed"
