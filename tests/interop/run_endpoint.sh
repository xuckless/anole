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
    v2 | multiconnect | goodput | crosstraffic) ;;
  # resumption, zerortt, connectionmigration: not built (see TODO M7).
  # ipv6: the UDP socket is IPv4 or IPv6, not dual-stack.
  *) exit 127 ;;
esac

args=()
if [ "$TESTCASE" = retry ]; then
  args+=(retry)
fi
exec /usr/local/bin/h3-interop-server /certs/cert.pem /certs/priv.key /www 443 "${args[@]}" >/logs/server.log 2>&1
