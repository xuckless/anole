#!/usr/bin/env bash
# Runs anole.redis's tests (`zig build test-redis`: the client, the session
# store and the rate limiter) against a throwaway Redis or Valkey in
# Docker: once in plain text as the default user, and once over TLS
# (rediss://, the CA checked) as an ACL user with a password, on
# database 1.
#
# The server's certificate and its CA are made here for this run, in a
# temporary directory removed on exit (nothing is committed); the
# container is removed on exit too.
#
#   tests/redis/run.sh                                  # redis:7 on ports 56379/56380
#   REDIS_IMAGE=valkey/valkey:8 REDIS_PORT=56381 ZIG=zig tests/redis/run.sh
#   tests/redis/run.sh -Doptimize=ReleaseSafe           # extra zig build arguments
set -euo pipefail

cd "$(dirname "$0")/../.."
ZIG=${ZIG:-zig}
IMAGE=${REDIS_IMAGE:-redis:7}
PORT=${REDIS_PORT:-56379}
TLS_PORT=$((PORT + 1))
NAME=anole-redis-test-$$
PASSWORD=anole-test-pw
case "$IMAGE" in
  *valkey*) SERVER=valkey-server ;;
  *) SERVER=redis-server ;;
esac

CERTS=$(mktemp -d)
cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  rm -rf "$CERTS"
}
trap cleanup EXIT

# A CA and a server certificate for localhost and 127.0.0.1, valid a day.
(
  cd "$CERTS"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
    -subj '/CN=anole test CA' -keyout ca.key -out root.crt \
    -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign 2>/dev/null
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -subj '/CN=localhost' -keyout server.key -out server.csr 2>/dev/null
  printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n' > server.ext
  openssl x509 -req -in server.csr -CA root.crt -CAkey ca.key -CAcreateserial -days 1 \
    -extfile server.ext -out server.crt 2>/dev/null
  rm -f server.csr server.ext ca.key root.srl
  # The server runs as its own user, whatever owns the files here.
  chmod 644 server.key server.crt root.crt
)

docker run -d --rm --name "$NAME" -p "127.0.0.1:$PORT:6379" -p "127.0.0.1:$TLS_PORT:6380" \
  -v "$CERTS:/tls:ro" "$IMAGE" "$SERVER" \
  --port 6379 --tls-port 6380 \
  --tls-cert-file /tls/server.crt --tls-key-file /tls/server.key \
  --tls-ca-cert-file /tls/root.crt --tls-auth-clients no \
  --user anole on ">$PASSWORD" '~*' '&*' '+@all' >/dev/null

for _ in $(seq 1 60); do
  if docker exec "$NAME" "${SERVER%-server}-cli" ping 2>/dev/null | grep -q PONG; then break; fi
  sleep 1
done
docker exec "$NAME" "${SERVER%-server}-cli" ping | grep -q PONG

echo "== $IMAGE, plain"
"$ZIG" build test-redis --summary all -Dredis-test-url="redis://127.0.0.1:$PORT" "$@"
echo "== $IMAGE, TLS (rediss://, an ACL user, database 1)"
"$ZIG" build test-redis --summary all -Dredis-test-url="rediss://anole:$PASSWORD@localhost:$TLS_PORT/1?ssl_ca_certs=$CERTS/root.crt" "$@"
