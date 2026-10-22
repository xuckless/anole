#!/bin/sh
# Builds the throwaway addon against libanole.a (zig build capi first).
# Static link; the addon exports only its Node-API entry points (plus the
# anole_* the archive carries), checked below.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
node_inc=${NODE_INCLUDE:-$(dirname "$(dirname "$(command -v node)")")/include/node}
mkdir -p "$here/build"
case "$(uname -s)" in
Darwin)
  printf '_napi_register_module_v1\n_node_api_module_get_api_version_v1\n' > "$here/build/exports.txt"
  cc -O2 -std=c11 -bundle -undefined dynamic_lookup -I"$node_inc" -I"$root/zig-out/include" \
    "$here/addon.c" "$root/zig-out/lib/libanole.a" -lc++ \
    -Wl,-exported_symbols_list,"$here/build/exports.txt" -Wl,-dead_strip -o "$here/build/anole.node"
  echo "exported:"; nm -gU "$here/build/anole.node"
  ;;
Linux)
  printf '{ global: napi_register_module_v1; node_api_module_get_api_version_v1; local: *; };\n' > "$here/build/exports.map"
  cc -O2 -std=c11 -shared -fPIC -I"$node_inc" -I"$root/zig-out/include" \
    "$here/addon.c" "$root/zig-out/lib/libanole.a" -lstdc++ -lpthread \
    -Wl,--version-script,"$here/build/exports.map" -Wl,--gc-sections -o "$here/build/anole.node"
  echo "exported:"; nm -D --defined-only "$here/build/anole.node"
  ;;
esac
