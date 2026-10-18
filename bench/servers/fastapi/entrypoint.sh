#!/bin/sh
# MODE picks the server: uvicorn (h1, tls), Hypercorn (h2c, h3) or grpc.aio (grpc).
set -eu
: "${MODE:=h1}" "${WORKERS:=1}" "${HTTP_PORT:=8080}" "${HTTPS_PORT:=8443}"
: "${CERT_FILE:=/certs/cert.pem}" "${KEY_FILE:=/certs/key.pem}"
export WORKERS

case "$MODE" in
h1)
  exec uvicorn app:app --host 0.0.0.0 --port "$HTTP_PORT" --workers "$WORKERS" \
    --timeout-keep-alive 75 --no-access-log --log-level warning ;;
tls)
  exec uvicorn app:app --host 0.0.0.0 --port "$HTTPS_PORT" --workers "$WORKERS" \
    --ssl-certfile "$CERT_FILE" --ssl-keyfile "$KEY_FILE" \
    --timeout-keep-alive 75 --no-access-log --log-level warning ;;
h2c)
  exec hypercorn app:app --bind "0.0.0.0:$HTTP_PORT" --workers "$WORKERS" \
    --keep-alive 75 --log-level warning ;;
h3)
  # Hypercorn's --workers shares one UDP socket across processes, which breaks
  # QUIC connections; with more than one worker, h3_workers.py starts one
  # Hypercorn per worker on its own SO_REUSEPORT sockets instead.
  export HTTPS_PORT CERT_FILE KEY_FILE
  [ "$WORKERS" -gt 1 ] && exec python h3_workers.py
  exec hypercorn app:app --certfile "$CERT_FILE" --keyfile "$KEY_FILE" \
    --bind "0.0.0.0:$HTTPS_PORT" --quic-bind "0.0.0.0:$HTTPS_PORT" \
    --keep-alive 75 --log-level warning ;;
grpc)
  exec python grpc_server.py ;;
*)
  echo "fastapi: unsupported MODE '$MODE' (h1, tls, h2c, h3, grpc)" >&2
  exit 3 ;;
esac
