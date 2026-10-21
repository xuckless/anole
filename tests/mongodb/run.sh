#!/usr/bin/env bash
# Runs the MongoDB client's live tests (src/mongodb/live_test.zig) against
# MongoDB in Docker: a replica set of one, with authentication (a keyfile
# made in the container), test commands on (failCommand), and TLS on the
# same port (allowTLS) with a CA and server certificate made here, in a
# temporary directory, never committed.
#
#   tests/mongodb/run.sh                 # mongo:8.0
#   tests/mongodb/run.sh mongo:7.0       # another image
#   KEEP=1 tests/mongodb/run.sh          # leave the container running
#
# Each run checks SCRAM-SHA-256 (negotiated), SCRAM-SHA-1 and TLS.
set -euo pipefail

image="${1:-mongo:8.0}"
zig="${ZIG:-zig}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
port="${PORT:-27217}"
name="anole-mongodb-test-$$"
work="$(mktemp -d)"
password="anole-$(head -c 9 /dev/urandom | base64 | tr -d '/+=')"

cleanup() {
    if [ -z "${KEEP:-}" ]; then docker rm -f "$name" >/dev/null 2>&1 || true; fi
    rm -rf "$work"
}
trap cleanup EXIT

# A CA and a certificate for localhost and 127.0.0.1, valid for a day.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=anole test CA" \
    -keyout "$work/ca.key" -out "$work/ca.pem" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj "/CN=localhost" \
    -keyout "$work/server.key" -out "$work/server.csr" 2>/dev/null
printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\n' >"$work/ext.cnf"
openssl x509 -req -in "$work/server.csr" -CA "$work/ca.pem" -CAkey "$work/ca.key" -CAcreateserial \
    -days 1 -extfile "$work/ext.cnf" -out "$work/server.crt" 2>/dev/null
cat "$work/server.crt" "$work/server.key" >"$work/server.pem"
chmod 644 "$work"/*.pem

# The member's name is localhost:$port, the port published as itself, so
# the client reaches what the replica set configuration names.
docker run -d --rm --name "$name" -p "127.0.0.1:$port:$port" \
    -e MONGO_INITDB_ROOT_USERNAME=root -e MONGO_INITDB_ROOT_PASSWORD="$password" \
    -v "$work:/certs:ro" --entrypoint bash "$image" -c "
        head -c 756 /dev/urandom | base64 > /tmp/keyfile && chmod 400 /tmp/keyfile && chown mongodb /tmp/keyfile &&
        exec docker-entrypoint.sh mongod --port $port --bind_ip_all --replSet rs0 --keyFile /tmp/keyfile \
            --setParameter enableTestCommands=1 \
            --tlsMode allowTLS --tlsCertificateKeyFile /certs/server.pem --tlsCAFile /certs/ca.pem \
            --tlsAllowConnectionsWithoutCertificates" >/dev/null

mongosh() { docker exec "$name" mongosh --quiet --port "$port" -u root -p "$password" --authenticationDatabase admin "$@"; }
for _ in $(seq 1 60); do
    if mongosh --eval 'db.adminCommand({ping: 1}).ok' >/dev/null 2>&1; then break; fi
    sleep 1
done
mongosh --eval "rs.initiate({_id: 'rs0', members: [{_id: 0, host: 'localhost:$port'}]})" >/dev/null
for _ in $(seq 1 60); do
    if [ "$(mongosh --eval 'db.hello().isWritablePrimary' 2>/dev/null)" = "true" ]; then break; fi
    sleep 1
done
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
