#!/usr/bin/env bash
# Runs anole.s3's live tests (`zig build test-s3 -Ds3-test-url=...`) against
# a throwaway MinIO in Docker: once over plain HTTP and once over TLS (a CA
# made here, checked by the client).
#
# MinIO stopped publishing community images on Docker Hub and Quay in 2025;
# Chainguard's build of the same server is pulled by digest instead. The
# certificates and keys are made for this run in a temporary directory
# removed on exit (nothing is committed); the containers are removed on exit.
#
#   tests/s3/run.sh                                  # ports 59000/59001
#   S3_PORT=59100 ZIG=zig tests/s3/run.sh
#   tests/s3/run.sh -Doptimize=ReleaseSafe           # extra zig build arguments
set -euo pipefail

cd "$(dirname "$0")/../.."
ZIG=${ZIG:-zig}
IMAGE=${S3_IMAGE:-cgr.dev/chainguard/minio@sha256:d88920d6a50bd0b088223b688be3b76c63e6205dbe494437f67ba1240ea12880}
PORT=${S3_PORT:-59000}
TLS_PORT=$((PORT + 1))
NAME=anole-s3-test-$$
KEY=anole
SECRET=anole-secret-1
BUCKET=anole-test

CERTS=$(mktemp -d)
# mktemp makes the directory 0700: MinIO runs as an unprivileged user in its
# container, and without access it finds no certificate and serves plain HTTP.
chmod 755 "$CERTS"
cleanup() {
  docker rm -f "$NAME-plain" "$NAME-tls" >/dev/null 2>&1 || true
  rm -rf "$CERTS"
}
trap cleanup EXIT

# A CA and a server certificate for localhost and 127.0.0.1, valid a day.
(
  cd "$CERTS"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
    -subj '/CN=anole test CA' -keyout ca.key -out ca.crt \
    -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign' 2>/dev/null
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -subj '/CN=localhost' -keyout private.key -out server.csr 2>/dev/null
  printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\n' >san.ext
  openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 1 \
    -extfile san.ext -out public.crt 2>/dev/null
  chmod 644 private.key public.crt ca.crt
)

start() { # name port [certs]
  local name=$1 port=$2 certs=${3:-}
  local args=(-d --name "$name" -p "127.0.0.1:$port:9000" -e MINIO_ROOT_USER="$KEY" -e MINIO_ROOT_PASSWORD="$SECRET")
  if [ -n "$certs" ]; then args+=(-v "$certs:/certs:ro"); fi
  docker run "${args[@]}" "$IMAGE" server /data --address :9000 ${certs:+--certs-dir /certs} >/dev/null
}

wait_ready() { # name url [curl args]
  local name=$1 url=$2; shift 2
  for _ in $(seq 1 60); do
    if curl -fsS "$@" "$url/minio/health/live" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  echo "MinIO did not come up at $url" >&2
  docker logs "$name" 2>&1 | tail -5 >&2 || true
  return 1
}

make_bucket() { # url [curl args]
  local url=$1; shift
  curl -fsS "$@" -X PUT --user "$KEY:$SECRET" --aws-sigv4 "aws:amz:us-east-1:s3" "$url/$BUCKET" >/dev/null
}

export ANOLE_S3_TEST_KEY=$KEY ANOLE_S3_TEST_SECRET=$SECRET ANOLE_S3_TEST_BUCKET=$BUCKET

echo "== MinIO over plain HTTP"
start "$NAME-plain" "$PORT"
wait_ready "$NAME-plain" "http://127.0.0.1:$PORT"
make_bucket "http://127.0.0.1:$PORT"
"$ZIG" build test-s3 "-Ds3-test-url=http://127.0.0.1:$PORT" "$@"

echo "== MinIO over TLS"
start "$NAME-tls" "$TLS_PORT" "$CERTS"
wait_ready "$NAME-tls" "https://localhost:$TLS_PORT" --cacert "$CERTS/ca.crt"
make_bucket "https://localhost:$TLS_PORT" --cacert "$CERTS/ca.crt"
ANOLE_S3_TEST_CA="$CERTS/ca.crt" "$ZIG" build test-s3 "-Ds3-test-url=https://localhost:$TLS_PORT" "$@"
