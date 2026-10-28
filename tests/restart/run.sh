#!/bin/sh
# A zero-downtime restart (SIGUSR2) of examples/full with four named
# listeners (HTTP/1.1 + h2c; TLS with HTTP/2, HTTP/1.1 and HTTP/3; TLS with
# HTTP/1.1 alone; h2c alone), under a stand-in for systemd's notification
# socket:
#   - READY=1 once serving; RELOADING=1, then MAINPID=<new> READY=1 from the
#     successor on SIGUSR2; no STOPPING=1 from the process handing over;
#     STOPPING=1 on SIGTERM;
#   - the UDP socket goes to the successor: an HTTP/3 connection open
#     across the restart is closed by the old process (CONNECTION_CLOSE,
#     H3_NO_ERROR) at once, and new ones reach the successor;
#   - TCP and HTTP/3 serve throughout, each listener's socket reaching the
#     successor under its own name (LISTEN_FDNAMES), so each port still
#     speaks what it did; a second restart works too;
#   - a raw TCP echo and a UDP echo listener (anole.net) are handed over by
#     name as well, and answer throughout;
#   - SIGHUP reloads the certificate (RELOADING=1, then READY=1) and the
#     process goes on serving.
#   tests/restart/run.sh [path-to-full]
# Needs python3 and curl; aioquic is installed into a throwaway venv.
set -eu
server_bin=${1:-zig-out/bin/full}
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../lib/wait.sh"
work=$(mktemp -d)
pids=""
trap 'for p in $pids; do kill -9 $p 2>/dev/null || true; done; rm -rf "$work"' EXIT
python3 -m venv "$work/venv"
"$work/venv/bin/pip" install -q --require-hashes -r "$here/../h3/requirements.txt"
py="$work/venv/bin/python -I"
port=18580
tls_port=18581
h1_tls_port=18582
h2c_port=18583
raw_tcp_port=18584
raw_udp_port=18585

fail() { echo "FAIL $1"; ps -o pid,ppid,stat,command -ax | grep "[f]ull $port" || true; echo "--- notify:"; cat "$work/notify.log"; echo "--- server:"; tail -30 "$work/server.log"; exit 1; }
# Waits for a line matching $1 in the notification log, after its first $2
# lines.
notified() { tail -n +$((${2:-0} + 1)) "$work/notify.log" | grep -qE "$1"; }
await_notify() {
  wait_until 30 "the notification '$1'" notified "$1" "${2:-0}" || fail "no '$1' notification"
}
check_all() {
  out=$(curl -s "http://127.0.0.1:$port/") || fail "http ($1)"
  [ "$out" = hello ] || fail "http ($1): $out"
  out=$(curl -sk "https://127.0.0.1:$tls_port/") || fail "https ($1)"
  [ "$out" = hello ] || fail "https ($1): $out"
  out=$($py "$here/../h3/client.py" "https://127.0.0.1:$tls_port/" --quiet --repeat 3) || fail "h3 ($1)"
  [ "$(echo "$out" | tail -1)" = "3 responses" ] || fail "h3 ($1): $out"
  # TLS, HTTP/1.1 alone: a client offering h2 gets HTTP/1.1.
  out=$(curl -sk --http2 -w ' %{http_version}' "https://127.0.0.1:$h1_tls_port/") || fail "https-h1 ($1)"
  [ "$out" = "hello 1.1" ] || fail "https-h1 ($1): $out"
  # h2c alone: HTTP/2 with prior knowledge, and HTTP/1.1 closed unanswered.
  out=$(curl -s --http2-prior-knowledge -w ' %{http_version}' "http://127.0.0.1:$h2c_port/") || fail "h2c ($1)"
  [ "$out" = "hello 2" ] || fail "h2c ($1): $out"
  if curl -s --http1.1 "http://127.0.0.1:$h2c_port/" >/dev/null; then fail "h2c ($1): served HTTP/1.1"; fi
  # Raw TCP and UDP echo: the sockets reach the successor under their names.
  out=$($py - "$raw_tcp_port" "$raw_udp_port" "$1" <<'PY'
import socket, sys
tcp, udp, tag = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
s = socket.create_connection(("127.0.0.1", tcp), timeout=5)
s.sendall(b"tcp " + tag.encode())
got = s.recv(100)
assert got == b"tcp " + tag.encode(), got
s.close()
u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
u.settimeout(5)
u.sendto(b"udp " + tag.encode(), ("127.0.0.1", udp))
got = u.recvfrom(100)[0]
assert got == b"udp " + tag.encode(), got
print("raw ok")
PY
  ) || fail "raw TCP/UDP echo ($1): $out"
  [ "$out" = "raw ok" ] || fail "raw TCP/UDP echo ($1): $out"
}

: >"$work/notify.log"
$py "$here/notify.py" "$work/notify" "$work/notify.log" &
pids="$!"
wait_until 30 "the notification socket" test -S "$work/notify" || fail "notify.py did not bind its socket"
NOTIFY_SOCKET="$work/notify" "$server_bin" $port $tls_port $h1_tls_port $h2c_port $raw_tcp_port $raw_udp_port >"$work/server.log" 2>&1 &
first=$!
pids="$pids $first"
await_notify "^READY=1$"
check_all "first process"
echo "PASS READY=1, then HTTP/1.1, HTTPS, HTTP/3, TLS HTTP/1.1 only and h2c only"

lines=$(wc -l <"$work/notify.log")
kill -HUP $first
await_notify "^RELOADING=1 MONOTONIC_USEC=[0-9]+$" $lines
await_notify "^READY=1$" $lines
grep -q "certificates reloaded" "$work/server.log" || fail "no reload logged after SIGHUP"
check_all "after SIGHUP"
echo "PASS SIGHUP: RELOADING=1, certificates reloaded, READY=1, still serving"

restart() {
  old=$1
  rm -f "$work/go"
  $py "$here/across.py" 127.0.0.1 $tls_port "$work/go" >"$work/across" 2>&1 &
  across=$!
  pids="$pids $across"
  wait_until 30 "the HTTP/3 connection to be open" log_has "$work/across" "before 200" || fail "across: $(cat "$work/across")"
  lines=$(wc -l <"$work/notify.log")
  kill -USR2 $old
  await_notify "^RELOADING=1 MONOTONIC_USEC=[0-9]+$" $lines
  await_notify "^MAINPID=[0-9]+ READY=1$" $lines
  new=$(tail -n +$((lines + 1)) "$work/notify.log" | sed -n 's/^MAINPID=\([0-9]*\) READY=1$/\1/p' | tail -1)
  [ -n "$new" ] && [ "$new" != "$old" ] || fail "no new MAINPID after restarting $old"
  pids="$pids $new"
  touch "$work/go"
  wait $across || fail "the HTTP/3 connection across the restart: $(cat "$work/across")"
  grep -q "closed 0x100" "$work/across" || fail "across: $(cat "$work/across")"
  wait_until 30 "process $old to exit" gone $old || fail "process $old still running after handing over"
  tail -n +$((lines + 1)) "$work/notify.log" | grep -q STOPPING && fail "STOPPING=1 from a hand-over"
  check_all "after restarting $old"
  echo "PASS restart $old -> $new: RELOADING=1, MAINPID=$new READY=1, HTTP/3 closed (H3_NO_ERROR) and served by $new"
}
restart $first
second=$new
restart $second
third=$new

lines=$(wc -l <"$work/notify.log")
kill -TERM $third
await_notify "^STOPPING=1$" $lines
wait_until 30 "the last process to exit" gone $third || fail "still running after SIGTERM"
grep -qiE "leaked|panic" "$work/server.log" && fail "leak or panic in the server log"
echo "PASS STOPPING=1 and a clean exit on SIGTERM"
echo "all restart checks passed"
exit 0
