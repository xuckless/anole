#!/bin/sh
# Runs grpc's HTTP/2 server checks (github.com/grpc/grpc/tools/http2_interop,
# pinned below by version and module checksum) against the interop server
# (tests/grpc/interop/server.zig): the framing cases over h2c and over TLS,
# and the TLS cases. Fails on a failure not in http2-known-failures.txt, or
# on a listed case that passes. Needs Go and openssl.
#   tests/grpc/interop/run-http2.sh [path-to-grpc-interop-server]
set -eu
here=$(cd "$(dirname "$0")" && pwd)
server=${1:-zig-out/bin/grpc-interop-server}
module=github.com/grpc/grpc/tools/http2_interop
version=v0.0.0-20260718051024-8542e01ff47e # grpc 8542e01ff47e
sum=h1:vMscIt60GwX5lCKg3tzIFy+chYjwxd5hX0G842KABlA=

work=$(mktemp -d)
pids=
trap 'for p in $pids; do kill $p 2>/dev/null || true; done; rm -rf "$work"' EXIT

# The module, checked against the Go checksum database by `go mod
# download` and against the pin here.
info=$(cd "$work" && go mod download -json "$module@$version")
got_sum=$(printf '%s' "$info" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Sum"])')
if [ "$got_sum" != "$sum" ]; then
  echo "unexpected checksum for $module@$version: $got_sum"
  exit 1
fi
dir=$(printf '%s' "$info" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Dir"])')
cp -R "$dir" "$work/suite"
chmod -R u+w "$work/suite"

"$here/cert.sh" "$work"
# -use_test_ca reads the CA from this path, relative to the package.
mkdir -p "$work/suite/src/core/tsi/test_creds"
cp "$work/cert.pem" "$work/suite/src/core/tsi/test_creds/ca.pem"

"$server" 10075 >"$work/h2c.log" 2>&1 &
pids="$pids $!"
"$server" 10076 "$work/cert.pem" "$work/key.pem" >"$work/tls.log" 2>&1 &
pids="$pids $!"
sleep 1

run() { # mode port use_tls test_case
  (cd "$work/suite" && go test -count=1 -v . -args -server_host=127.0.0.1 -server_port="$2" \
    -use_tls="$3" -use_test_ca="$3" -server_host_override=localhost -test_case="$4") \
    >"$work/$1.out" 2>&1 || true
  grep '^{"cases"' "$work/$1.out" | sed "s/^/$1 /" >>"$work/reports"
}
run h2c 10075 false framing
run tls-framing 10076 true framing
run tls 10076 true tls

python3 - "$here/http2-known-failures.txt" "$work/reports" <<'PY'
import json, sys
known = set()
for line in open(sys.argv[1]):
    line = line.strip()
    if line and not line.startswith("#"):
        mode, case = line.split()
        known.add((mode, case))
ok, seen = True, set()
for line in open(sys.argv[2]):
    mode, _, report = line.partition(" ")
    for c in json.loads(report)["cases"]:
        if c.get("skipped"):
            continue
        key = (mode, c["name"])
        seen.add(key)
        passed = c.get("passed", False)
        if passed and key in known:
            print(f"FIXED (remove from the list): {mode} {c['name']}"); ok = False
        elif not passed and key not in known:
            print(f"FAIL {mode} {c['name']}"); ok = False
        else:
            print(f"{'PASS' if passed else 'known'} {mode} {c['name']}")
for key in sorted(known - seen):
    print(f"NOT RUN: {key[0]} {key[1]}"); ok = False
sys.exit(0 if ok else 1)
PY
