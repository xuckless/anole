#!/usr/bin/env bash
# Runs inside the image of run.sh: the four directions, one test case at a
# time. Logs go to /logs.
set -u
. /scripts/wait.sh
work=$(mktemp -d)
sh /scripts/cert.sh "$work"
ca=$work/cert.pem
failed=0
pids=()
cleanup() { for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

# grpc-dotnet's client reads each case's PASS from its exit status. It
# connects to 127.0.0.1, where the servers listen: "localhost" is ::1 first
# here, and QUIC (unlike its TCP) does not fall back to IPv4.
# cancel_after_begin is left out: over HTTP/3 grpc-dotnet's client reports a
# cancel before the response headers as Internal, not Cancelled, against its
# own Kestrel server too (checked 2026-10-23 with v2.84.0 and libmsquic 2.6.3).
dotnet_cases="empty_unary large_unary client_streaming server_streaming ping_pong empty_stream
cancel_after_first_response timeout_on_sleeping_server custom_metadata
status_code_and_message special_status_message unimplemented_service unimplemented_method
client_compressed_unary client_compressed_streaming server_compressed_unary server_compressed_streaming"
anole_cases="empty_unary large_unary client_streaming server_streaming ping_pong empty_stream
status_code_and_message special_status_message custom_metadata timeout_on_sleeping_server
unimplemented_method"

run_dotnet() { # <label> <port>
  for c in $dotnet_cases; do
    if dotnet /opt/client/InteropTestsClient.dll --use_tls true --use_http3 true \
      --server_host 127.0.0.1 --server_port "$2" --client_type httpclient --test_case "$c" >"/logs/$1-$c.log" 2>&1; then
      echo "PASS $c ($1)"
    else
      echo "FAIL $c ($1): $(tail -3 "/logs/$1-$c.log" | tr '\n' ' ' | cut -c1-300)"
      failed=$((failed + 1))
    fi
  done
}

run_anole() { # <label> <port> <extra args...>
  label=$1
  port=$2
  shift 2
  for c in $anole_cases; do
    if /anole/grpc-interop-client "$port" "$c" "$ca" "$@" >"/logs/$label-$c.log" 2>&1; then
      echo "PASS $c ($label)"
    else
      echo "FAIL $c ($label): $(tail -3 "/logs/$label-$c.log" | tr '\n' ' ' | cut -c1-300)"
      failed=$((failed + 1))
    fi
  done
}

# a: grpc-dotnet client -> Anole's interop server, h2 and h3 on one port.
/anole/grpc-interop-server 10081 "$work/cert.pem" "$work/key.pem" >/logs/a-server.log 2>&1 &
pids+=($!)
# b: the same client -> the C ABI's server.
/anole/capi-grpc-interop 10082 "$work/cert.pem" "$work/key.pem" >/logs/b-server.log 2>&1 &
pids+=($!)
# c, d: grpc-dotnet's Kestrel server (its own certificate, for
# *.test.google.fr), HTTP/2 on 10083 and HTTP/3 on 10084.
(cd /opt/server && dotnet InteropTestsWebsite.dll --port 10083 --port_http3 10084 --use_tls true) >/logs/cd-server.log 2>&1 &
pids+=($!)
# Each server's TCP and UDP (HTTP/3) sockets bound, not a fixed time.
for port in 10081 10082 10083; do
  wait_until 60 "a server to listen on TCP $port" port_open 127.0.0.1 $port || exit 1
done
for port in 10081 10082 10084; do
  wait_until 60 "a server to bind UDP $port" udp_bound $port || exit 1
done

run_dotnet a 10081
run_dotnet b 10082
cert=/src/testassets/Certs/InteropTests/ca.pem
ca=$cert
run_anole c 10084 --h3 --host=foo.test.google.fr
run_anole d 10083 --host=foo.test.google.fr

echo "$failed failed"
[ "$failed" -eq 0 ]
