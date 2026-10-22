#!/bin/sh
# Packs libanole for bindings (zig build capi runs it):
#   capi-pack.sh <out-dir> <zig-static-lib> <dependency archives...>
# Output: <out-dir>/libanole.a holding ONE relocatable object in which every
# symbol but anole_* is local, and <out-dir>/libanole.{dylib,so} linked
# from it. So a Node addon or Python extension that links libanole.a
# statically exports nothing but its own entry point and anole_*, and
# nothing in it can bind to the OpenSSL, nghttp2, zstd, brotli, sqlite or
# zlib that Node or CPython carry (or the reverse).
#  - macOS: ld64 `-r -exported_symbols_list` (every other symbol becomes
#    private extern: bound inside the final image, never exported).
#  - Linux: `ld -r` then `objcopy --keep-global-symbol` (binutils).
# Left undefined: libc, and on macOS the C++ runtime (BoringSSL's few C++
# runtime references: operator delete, __cxa_pure_virtual, two libc++
# internals), which the final link takes from the system (-lc++).
set -eu
out=$1; zig_lib=$2; shift 2
mkdir -p "$out"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
uname_s=$(uname -s)
case "$uname_s" in
Darwin)
  printf '_anole_*\n' > "$work/exports"
  arch=$(uname -m)
  sdk=$(xcrun --show-sdk-version 2>/dev/null || sw_vers -productVersion)
  ld -r -arch "$arch" -platform_version macos "$sdk" "$sdk" -o "$work/libanole.o" -exported_symbols_list "$work/exports" \
    -force_load "$zig_lib" "$@"
  rm -f "$out/libanole.a"
  ar rcs "$out/libanole.a" "$work/libanole.o" 2>/dev/null
  cc -dynamiclib -o "$out/libanole.dylib" -install_name @rpath/libanole.dylib \
    "$work/libanole.o" -lc++ -Wl,-exported_symbols_list,"$work/exports"
  ;;
Linux)
  ld -r -o "$work/libanole.o" --whole-archive "$zig_lib" --no-whole-archive \
    --start-group "$@" --end-group
  objcopy --wildcard --keep-global-symbol='anole_*' "$work/libanole.o"
  rm -f "$out/libanole.a"
  ar rcs "$out/libanole.a" "$work/libanole.o"
  printf '{ global: anole_*; local: *; };\n' > "$work/version.map"
  cc -shared -o "$out/libanole.so" "$work/libanole.o" -Wl,--version-script,"$work/version.map" -lpthread
  ;;
*)
  echo "capi-pack: $uname_s is not handled yet (Windows: see research notes)" >&2
  exit 1
  ;;
esac
# The check bindings rely on: nothing global but anole_*.
case "$uname_s" in
Darwin) leaked=$(nm -gU "$out/libanole.a" 2>/dev/null | awk 'NF>=3 {print $3}' | grep -v '^_anole_' || true) ;;
*) leaked=$(nm -g --defined-only "$out/libanole.a" 2>/dev/null | awk 'NF>=3 {print $3}' | grep -v '^anole_' || true) ;;
esac
if [ -n "$leaked" ]; then
  echo "capi-pack: libanole.a exports more than anole_*:" >&2
  echo "$leaked" | head -20 >&2
  exit 1
fi
