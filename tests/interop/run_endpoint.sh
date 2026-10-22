#!/bin/bash
# The interop runner's endpoint contract: ROLE and TESTCASE in the
# environment, certificates in /certs, files in /www, logs in /logs; exit
# 127 for anything unsupported.
set -e
/setup.sh

if [ "$ROLE" != server ]; then
  exit 127
fi
case "$TESTCASE" in
  handshake | transfer | longrtt | chacha20 | multiplexing | retry | http3 | \
    amplificationlimit | blackhole | keyupdate | handshakeloss | transferloss | \
    handshakecorruption | transfercorruption | ecn | rebind-port | rebind-addr | \
    v2 | multiconnect | goodput | crosstraffic | resumption | zerortt) ;;
  # The server advertises no preferred address, which this case is about;
  # it runs only by hand (it fails: docs/server.md, HTTP/3).
  connectionmigration) ;;
  # ipv6: the UDP socket is IPv4 or IPv6, not dual-stack.
  *) exit 127 ;;
esac

args=()
case "$TESTCASE" in
  retry) args+=(retry) ;;
  # Only this case wants QUIC v2; the others check for v1 even when the
  # client offers v2 too (aioquic does in every case).
  v2) args+=(v2) ;;
esac
exec /usr/local/bin/h3-interop-server /certs/cert.pem /certs/priv.key /www 443 "${args[@]}" >/logs/server.log 2>&1
