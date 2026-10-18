#!/bin/sh
# A self-signed ECDSA P-256 certificate for localhost and 127.0.0.1, shared by
# every server: bench/.data/certs/{cert,key}.pem (mounted at /certs).
set -eu
dir=$(cd "$(dirname "$0")/.." && pwd)/.data/certs
[ -f "$dir/cert.pem" ] && exit 0
mkdir -p "$dir"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
  -subj /CN=localhost -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
  -keyout "$dir/key.pem" -out "$dir/cert.pem" 2>/dev/null
chmod 644 "$dir/key.pem"
echo "wrote $dir/cert.pem"
