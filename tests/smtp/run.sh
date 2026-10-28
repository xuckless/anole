#!/usr/bin/env bash
# Runs anole.smtp's live tests ("mailpit: ...", src/smtp/live_test.zig)
# against three throwaway Mailpit servers in Docker, and reads what was
# sent back from each one's API:
#
#   plain      smtp://127.0.0.1:$PLAIN_PORT?tls=none
#   STARTTLS   smtp://anole:secret@localhost:$STARTTLS_PORT  (STARTTLS required, any login accepted)
#   implicit   smtps://anole:secret@localhost:$SMTPS_PORT    (TLS on connect, any login accepted)
#
# The two TLS servers share a certificate made here for this run, in a
# temporary directory removed on exit (nothing is committed); the
# containers are removed on exit too. The image is pinned by digest
# (MAINTAINING.md lists the pins).
#
#   tests/smtp/run.sh                                  # axllent/mailpit on ports 51025.. and 58025..
#   MAILPIT_IMAGE=axllent/mailpit@sha256:... ZIG=zig tests/smtp/run.sh
#   tests/smtp/run.sh -Doptimize=ReleaseSafe           # extra zig build arguments
#
# ANOLE_KEEP_CONTAINERS=1 leaves the containers when the script ends (CI
# collects their logs and states after a failure, then removes them).
set -euo pipefail

cd "$(dirname "$0")/../.."
ZIG=${ZIG:-zig}
IMAGE=${MAILPIT_IMAGE:-axllent/mailpit@sha256:0790692be935ea4420d085694f7985b1f692ca6a8771ab0e0bd8ba75ac180498} # v1.32.0
PLAIN_PORT=${SMTP_PLAIN_PORT:-51025}
STARTTLS_PORT=${SMTP_STARTTLS_PORT:-51587}
SMTPS_PORT=${SMTP_SMTPS_PORT:-51465}
PLAIN_API=${SMTP_PLAIN_API:-58025}
STARTTLS_API=${SMTP_STARTTLS_API:-58026}
SMTPS_API=${SMTP_SMTPS_API:-58027}
SUFFIX=$$
NAMES="anole-mailpit-plain-$SUFFIX anole-mailpit-starttls-$SUFFIX anole-mailpit-smtps-$SUFFIX"

CERTS=$(mktemp -d)
cleanup() {
  # shellcheck disable=SC2086
  [ -n "${ANOLE_KEEP_CONTAINERS:-}" ] || docker rm -f $NAMES >/dev/null 2>&1 || true
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
  # The server runs as its own user, whatever owns the files here, and
  # mktemp made the directory 0700.
  chmod 644 server.key server.crt root.crt
)
chmod 755 "$CERTS"

docker run -d --name "anole-mailpit-plain-$SUFFIX" \
  -p "127.0.0.1:$PLAIN_PORT:1025" -p "127.0.0.1:$PLAIN_API:8025" "$IMAGE" >/dev/null

docker run -d --name "anole-mailpit-starttls-$SUFFIX" \
  -p "127.0.0.1:$STARTTLS_PORT:1025" -p "127.0.0.1:$STARTTLS_API:8025" \
  -v "$CERTS:/tls:ro" \
  -e MP_SMTP_TLS_CERT=/tls/server.crt -e MP_SMTP_TLS_KEY=/tls/server.key \
  -e MP_SMTP_REQUIRE_STARTTLS=true -e MP_SMTP_AUTH_ACCEPT_ANY=true "$IMAGE" >/dev/null

docker run -d --name "anole-mailpit-smtps-$SUFFIX" \
  -p "127.0.0.1:$SMTPS_PORT:1025" -p "127.0.0.1:$SMTPS_API:8025" \
  -v "$CERTS:/tls:ro" \
  -e MP_SMTP_TLS_CERT=/tls/server.crt -e MP_SMTP_TLS_KEY=/tls/server.key \
  -e MP_SMTP_REQUIRE_TLS=true -e MP_SMTP_AUTH_ACCEPT_ANY=true "$IMAGE" >/dev/null

for api in "$PLAIN_API" "$STARTTLS_API" "$SMTPS_API"; do
  ok=0
  for _ in $(seq 1 60); do
    if curl -fsS "http://127.0.0.1:$api/api/v1/info" >/dev/null 2>&1; then ok=1; break; fi
    sleep 1
  done
  if [ "$ok" != 1 ]; then
    echo "Mailpit's API on port $api did not answer; the logs:" >&2
    for n in $NAMES; do docker logs "$n" >&2 || true; done
    exit 1
  fi
done

# The test binary reads the TLS servers' addresses from the environment;
# the run number in the URL makes zig run the tests again (its cache keys
# on the options, not on what the servers hold).
export ANOLE_SMTP_TEST_STARTTLS_URL="smtp://anole:secret@localhost:$STARTTLS_PORT"
export ANOLE_MAILPIT_STARTTLS_API="http://127.0.0.1:$STARTTLS_API"
export ANOLE_SMTP_TEST_SMTPS_URL="smtps://anole:secret@localhost:$SMTPS_PORT"
export ANOLE_MAILPIT_SMTPS_API="http://127.0.0.1:$SMTPS_API"
export ANOLE_SMTP_TEST_CA_FILE="$CERTS/root.crt"

echo "== $IMAGE: plain, STARTTLS with AUTH, and implicit TLS"
"$ZIG" build test --summary all -Dtest-filter="mailpit:" \
  -Dsmtp-test-url="smtp://127.0.0.1:$PLAIN_PORT?tls=none&run=$SUFFIX" \
  -Dmailpit-api-url="http://127.0.0.1:$PLAIN_API" "$@"
