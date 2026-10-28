#!/usr/bin/env bash
# Every `anole new` template as a user would use it: made into a temporary
# directory with a path dependency on this checkout, then built, tested, and
# its OpenAPI document written, checked and linted.
#
#   tests/templates/run.sh [template ...]     # default: all of them
#
# rest-postgres runs its database tests when DATABASE_URL names a live
# PostgreSQL (CI starts one); without it they skip. `anole init` is checked
# against the first template.
# ZIG picks the compiler; OPENAPI_LINT=0 skips the document lint (it needs
# pip: openapi-spec-validator==0.7.1, installed into a virtual environment).
# ANOLE_TEST_TIMEOUT (e.g. 120s) is passed to each template's `zig build
# test` as --test-timeout, as CI does.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
zig=${ZIG:-zig}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [ "$#" -gt 0 ]; then templates=("$@"); else templates=(minimal rest-postgres realtime grpc full); fi

(cd "$root" && "$zig" build cli -Dprofile=minimal)
cli="$root/zig-out/bin/anole"

lint=
if [ "${OPENAPI_LINT:-1}" = 1 ] && command -v python3 >/dev/null; then
  python3 -m venv "$work/venv"
  "$work/venv/bin/pip" install --quiet openapi-spec-validator==0.7.1
  lint="$work/venv/bin/openapi-spec-validator"
fi

for t in "${templates[@]}"; do
  echo "== template $t"
  dir="$work/$t"
  "$cli" new "$dir" --template "$t" --anole-path "$root"
  test -f "$dir/.env"   # every template writes a ready .env
  (
    cd "$dir"
    "$zig" build
    "$zig" build test ${ANOLE_TEST_TIMEOUT:+--test-timeout "$ANOLE_TEST_TIMEOUT"}
    "$zig" build openapi
    test -s openapi.json
    "$zig" build openapi-check
    if [ -n "$lint" ]; then "$lint" openapi.json; fi
  )
done

# anole init: into an empty directory, and into an existing Zig project.
echo "== anole init"
mkdir "$work/init-empty" && (cd "$work/init-empty" && "$cli" init --template "${templates[0]}" --anole-path "$root" && test -f .env && "$zig" build)
mkdir "$work/init-existing" && (
  cd "$work/init-existing"
  "$zig" init -m >/dev/null
  rm build.zig
  "$cli" init --template "${templates[0]}" --anole-path "$root" --force
  grep -q '\.anole = ' build.zig.zon
  "$zig" build
)
echo "templates ok"
