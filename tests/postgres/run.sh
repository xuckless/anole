#!/usr/bin/env bash
# Runs the PostgreSQL tests (`zig build test-postgres`: anole.pg's and the
# webhook store's, which make databases of their own) against a throwaway
# PostgreSQL in Docker: once in plain text and once over TLS with
# sslmode=verify-full, logging in with scram-sha-256 both times; then the C
# ABI's suite (`zig build capi-test`) over TLS.
#
# The server's certificate and its CA are made here for this run, in a
# temporary directory removed on exit (nothing is committed); the
# container is removed on exit too.
#
#   tests/postgres/run.sh                       # postgres:17 on port 55432
#   PG_IMAGE=postgres:18 PG_PORT=55433 ZIG=zig tests/postgres/run.sh
#   tests/postgres/run.sh -Doptimize=ReleaseSafe   # extra zig build arguments
set -euo pipefail

cd "$(dirname "$0")/../.."
ZIG=${ZIG:-zig}
PORT=${PG_PORT:-55432}
IMAGE=${PG_IMAGE:-postgres:17}
NAME=anole-pg-test-$$
PASSWORD=anole-test-pw

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
  chmod 644 server.key
)

docker run -d --rm --name "$NAME" -p "127.0.0.1:$PORT:5432" \
  -e POSTGRES_PASSWORD="$PASSWORD" \
  -e POSTGRES_HOST_AUTH_METHOD=scram-sha-256 \
  -e POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256 \
  -v "$CERTS/server.crt:/etc/pgtls/server.crt:ro" \
  -v "$CERTS/server.key:/etc/pgtls/server.key.host:ro" \
  "$IMAGE" bash -ec '
    # the key must belong to the server user, whatever owns it on the host
    cp /etc/pgtls/server.key.host /etc/pgtls/server.key
    chown postgres:postgres /etc/pgtls/server.key
    chmod 600 /etc/pgtls/server.key
    exec docker-entrypoint.sh postgres -c ssl=on \
      -c ssl_cert_file=/etc/pgtls/server.crt -c ssl_key_file=/etc/pgtls/server.key' >/dev/null

# The entrypoint starts the server once to initialize it, then restarts it.
for _ in $(seq 1 60); do
  if docker exec "$NAME" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then
    sleep 1
    docker exec "$NAME" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1 && break
  fi
  sleep 1
done
docker exec "$NAME" pg_isready -h 127.0.0.1 -U postgres >/dev/null

BASE="postgres://postgres:$PASSWORD@127.0.0.1:$PORT/postgres"
echo "== plain"
"$ZIG" build test-postgres --summary all -Dpostgres-test-url="$BASE?sslmode=disable" "$@"
echo "== TLS (verify-full)"
"$ZIG" build test-postgres --summary all -Dpostgres-test-url="$BASE?sslmode=verify-full&sslrootcert=$CERTS/root.crt" "$@"
# The C ABI's suite (tests/capi/consumer.c), its PostgreSQL part included;
# CAPI=0 skips it.
if [ "${CAPI:-1}" != 0 ]; then
  echo "== C ABI (verify-full)"
  "$ZIG" build capi-test --summary all -Dpostgres-test-url="$BASE?sslmode=verify-full&sslrootcert=$CERTS/root.crt" "$@"
fi
