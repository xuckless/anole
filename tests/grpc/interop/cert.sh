#!/bin/sh
# Makes a throwaway certificate and key for the TLS interop runs, valid for
# two days for localhost and 127.0.0.1, in <dir>/cert.pem and <dir>/key.pem.
# Each peer's client trusts cert.pem as its CA. Never commit the output.
#   tests/grpc/interop/cert.sh <dir>
set -eu
dir=$1
cat >"$dir/openssl.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = localhost
[ext]
basicConstraints = critical, CA:TRUE
keyUsage = critical, digitalSignature, keyCertSign
extendedKeyUsage = serverAuth
subjectAltName = DNS:localhost, IP:127.0.0.1
CNF
openssl req -x509 -config "$dir/openssl.cnf" -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -nodes -days 2 -keyout "$dir/key.pem" -out "$dir/cert.pem" 2>/dev/null
