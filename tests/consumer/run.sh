#!/usr/bin/env bash
# tests/consumer as a user gets Anole: a copy of the project outside this
# repository, with the path dependency replaced by `zig fetch --save` of a
# git URL, then `zig build gen-proto` and `zig build`.
#
#   tests/consumer/run.sh [URL]
#
# URL defaults to this checkout's HEAD on GitHub, which must be pushed.
# ANOLE_CONSUMER_FRESH_CACHE=1 also starts from an empty global cache, so
# every pinned hash and lazy download is checked as on a new machine.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
url=${1:-git+https://github.com/xuckless/anole#$(git -C "$root" rev-parse HEAD)}
zig=${ZIG:-zig}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/project"
cp -R "$here/build.zig" "$here/build.zig.zon" "$here/proto" "$here/src" "$work/project/"
rm -rf "$work/project/src/gen"
if [ "${ANOLE_CONSUMER_FRESH_CACHE:-}" = 1 ]; then
  export ZIG_GLOBAL_CACHE_DIR="$work/cache"
fi

cd "$work/project"
# The path dependency goes; the fetched one takes its place.
python3 -I - build.zig.zon <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r'\n\s*//[^\n]*\n\s*//[^\n]*\n\s*\.anole = \.\{ \.path = "\.\./\.\." \},', '', s)
assert '.path' not in s, s
open(p, 'w').write(s)
PY
"$zig" fetch --save=anole "$url"
"$zig" build gen-proto
"$zig" build
test -x zig-out/bin/consumer
echo "consumer built against $url"
