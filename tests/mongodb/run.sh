#!/usr/bin/env bash
# Runs the MongoDB client's live tests (src/mongodb/live_test.zig) against
# MongoDB in Docker: a replica set of one, with authentication (a keyfile
# made in the container), test commands on (failCommand), and TLS on the
# same port (allowTLS) with a CA and server certificate made here, in a
# temporary directory, never committed. On a failure the server's log is
# printed before the container goes.
#
#   tests/mongodb/run.sh                 # mongo:8.0
#   tests/mongodb/run.sh mongo:7.0       # another image
#   KEEP=1 tests/mongodb/run.sh          # leave the container running
#
# Each run checks SCRAM-SHA-256 (negotiated), SCRAM-SHA-1 and TLS, then the
# C ABI's suite over TLS.
set -euo pipefail

image="${1:-mongo:8.0}"
zig="${ZIG:-zig}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
port="${PORT:-27217}"
name="anole-mongodb-test-$$"
work="$(mktemp -d)"
password="anole-$(head -c 9 /dev/urandom | base64 | tr -d '/+=')"

cleanup() {
    status=$?
    if [ "$status" -ne 0 ] && docker inspect "$name" >/dev/null 2>&1; then
        echo "-- $image log (last 60 lines) --" >&2
        docker logs --tail 60 "$name" >&2 2>&1 || true
    fi
    if [ -z "${KEEP:-}" ]; then docker rm -f "$name" >/dev/null 2>&1 || true; fi
    rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT

# A CA and a certificate for localhost and 127.0.0.1, valid for a day.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=anole test CA" \
    -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign \
    -keyout "$work/ca.key" -out "$work/ca.pem" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj "/CN=localhost" \
    -keyout "$work/server.key" -out "$work/server.csr" 2>/dev/null
printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n' >"$work/ext.cnf"
openssl x509 -req -in "$work/server.csr" -CA "$work/ca.pem" -CAkey "$work/ca.key" -CAcreateserial \
    -days 1 -extfile "$work/ext.cnf" -out "$work/server.crt" 2>/dev/null
cat "$work/server.crt" "$work/server.key" >"$work/server.pem"
rm -f "$work/server.crt" "$work/server.key" "$work/server.csr" "$work/ext.cnf"

# The member's name is localhost:$port, the port published as itself, so
# the client reaches what the replica set configuration names.
#
# mongod runs as the image's mongodb user, which cannot read the mounted
# directory on a Linux host (mktemp's 0700, the runner's uid), so root
# copies the files into the container and hands them over first, as
# tests/postgres/run.sh does with its key.
docker run -d --name "$name" -p "127.0.0.1:$port:$port" \
    -e MONGO_INITDB_ROOT_USERNAME=root -e MONGO_INITDB_ROOT_PASSWORD="$password" \
    -v "$work:/certs.host:ro" --entrypoint bash "$image" -ec "
        mkdir -p /etc/anole-tls && cp /certs.host/server.pem /certs.host/ca.pem /etc/anole-tls/
        chown -R mongodb:mongodb /etc/anole-tls && chmod 600 /etc/anole-tls/server.pem && chmod 644 /etc/anole-tls/ca.pem
        head -c 756 /dev/urandom | base64 > /etc/anole-tls/keyfile
        chown mongodb:mongodb /etc/anole-tls/keyfile && chmod 400 /etc/anole-tls/keyfile
        exec docker-entrypoint.sh mongod --port $port --bind_ip_all --replSet rs0 --keyFile /etc/anole-tls/keyfile \
            --setParameter enableTestCommands=1 \
            --tlsMode allowTLS --tlsCertificateKeyFile /etc/anole-tls/server.pem --tlsCAFile /etc/anole-tls/ca.pem \
            --tlsAllowConnectionsWithoutCertificates" >/dev/null

running() { [ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" = "true" ]; }
mongosh() { docker exec "$name" mongosh --quiet --port "$port" -u root -p "$password" --authenticationDatabase admin "$@"; }
# The entrypoint starts mongod once to create the user, then again for good.
ready=""
for _ in $(seq 1 90); do
    if ! running; then
        if docker logs "$name" 2>&1 | grep SERVER-121912 >/dev/null; then
            echo "$image refuses to start on this host's Linux kernel ($(uname -r)): MongoDB 8.0.21+ and 9.x" >&2
            echo "exit at startup on kernels 6.19 to 7.0.13 (TCMalloc and rseq; https://jira.mongodb.org/browse/SERVER-125742)." >&2
            echo "Use a host with a kernel before 6.19 or from 7.0.14, or mongo:7.0." >&2
        else
            echo "mongod exited during startup" >&2
        fi
        exit 1
    fi
    if mongosh --eval 'db.adminCommand({ping: 1}).ok' >/dev/null 2>&1; then ready=1; break; fi
    sleep 1
done
[ -n "$ready" ] || { echo "mongod did not answer within 90 s" >&2; exit 1; }
mongosh --eval "rs.initiate({_id: 'rs0', members: [{_id: 0, host: 'localhost:$port'}]})" >/dev/null
ready=""
for _ in $(seq 1 60); do
    if [ "$(mongosh --eval 'db.hello().isWritablePrimary' 2>/dev/null)" = "true" ]; then ready=1; break; fi
    sleep 1
done
[ -n "$ready" ] || { echo "the replica set has no primary after 60 s" >&2; exit 1; }
mongosh --eval "db.getSiblingDB('admin').createUser({user: 'sha1', pwd: '$password', roles: ['root'], mechanisms: ['SCRAM-SHA-1']})" >/dev/null
echo "$image ready on localhost:$port (replica set rs0)"

base="mongodb://root:$password@localhost:$port/?replicaSet=rs0&authSource=admin"
cd "$root"
for target in \
    "$base" \
    "mongodb://sha1:$password@localhost:$port/?replicaSet=rs0&authSource=admin&authMechanism=SCRAM-SHA-1" \
    "$base&tls=true&tlsCAFile=$work/ca.pem"; do
    echo "== $(echo "$target" | sed -E 's#//([^:]+):[^@]+@#//\1:***@#')"
    "$zig" build test-mongodb --summary line "-Dmongodb-test-url=$target"
done
# The C ABI's suite (tests/capi/consumer.c), its MongoDB part included,
# over TLS; CAPI=0 skips it.
if [ "${CAPI:-1}" != 0 ]; then
    echo "== the C ABI (TLS)"
    "$zig" build capi-test --summary line "-Dmongodb-test-url=$base&tls=true&tlsCAFile=$work/ca.pem"
    # A library built with MongoDB and neither SQLite nor PostgreSQL still
    # answers anole_db_query.
    echo "== the C ABI in a MongoDB-only build (-Dprofile=minimal -Dmongodb=true)"
    "$zig" build capi-test --summary line -Dprofile=minimal -Dmongodb=true "-Dmongodb-test-url=$base"
fi
