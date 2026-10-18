#!/bin/bash
# The interop runner's WebTransport endpoint contract (webtransport.md):
# ROLE, TESTCASE, PROTOCOLS and REQUESTS in the environment, certificates
# in /certs, files in /www, downloads to /downloads, logs in /logs; exit 127
# for anything unsupported.
set -e
/setup.sh

if [ "$ROLE" != server ]; then
  exit 127
fi
case "$TESTCASE" in
  handshake | transfer | transfer-unidirectional-send | transfer-bidirectional-send | transfer-datagram-send) ;;
  *) exit 127 ;;
esac
exec /usr/local/bin/wt-interop-server /certs/cert.pem /certs/priv.key /www /downloads 443 \
  "$TESTCASE" "${PROTOCOLS:-}" "${REQUESTS:-}" >/logs/server.log 2>&1
