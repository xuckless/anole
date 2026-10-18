#!/usr/bin/env bash
# The bundled C libraries' own test suites, built from the exact tarballs
# build.zig.zon pins, with clang's AddressSanitizer and
# UndefinedBehaviorSanitizer. Zig 0.17 has no ASan, so this is where memory
# errors in the C code would show. (Zig's Debug builds already run all the C
# with UBSan; nghttp2's suite runs under ASan in the xuckless/nghttp2 fork's
# CI, since its tests need a git submodule the tarball lacks. BoringSSL tests
# itself under sanitizers upstream at every commit.)
#
#   tools/sanitize-c-libs.sh [ngtcp2 nghttp3 zlib-ng yyjson zstd]
#
# Needs clang, make, cmake, curl, tar and git (the nghttp3 release tarball
# ships its configure script; ngtcp2 comes from the xuckless/ngtcp2 fork,
# whose archive lacks the tests' munit submodule, so it is cloned at the
# pinned commit with its submodules and built with CMake). DETECT_LEAKS=1 turns on
# LeakSanitizer where it exists (Linux).
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=${SANITIZE_WORK:-$(mktemp -d)}
mkdir -p "$work"
libs=("$@")
[ ${#libs[@]} -gt 0 ] || libs=(ngtcp2 nghttp3 zlib-ng yyjson zstd)
jobs=$(nproc 2>/dev/null || sysctl -n hw.ncpu)

export CC=${CC:-clang}
san="-fsanitize=address,undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer -g -O1"
export ASAN_OPTIONS=detect_leaks=${DETECT_LEAKS:-0}:abort_on_error=1
export UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=1

# The URL build.zig.zon pins for a library (matched on a fragment of it).
url_of() {
  grep -o "\"https://[^\"]*$1[^\"]*\"" "$root/build.zig.zon" | head -1 | tr -d '"'
}

fetch() {
  local name=$1 url
  url=$(url_of "$2")
  [ -n "$url" ] || { echo "no pinned URL matching $2" >&2; exit 1; }
  echo "== $name: $url"
  rm -rf "$work/$name" && mkdir -p "$work/$name"
  curl -fsSL "$url" | tar -x -C "$work/$name" --strip-components=1 $( [[ $url == *.xz ]] && echo -J || echo -z )
  cd "$work/$name"
}

for lib in "${libs[@]}"; do
  case $lib in
    ngtcp2)
      url=$(url_of "xuckless/ngtcp2/archive")
      [ -n "$url" ] || { echo "no pinned URL matching xuckless/ngtcp2/archive" >&2; exit 1; }
      commit=${url##*/}
      commit=${commit%.tar.gz}
      echo "== ngtcp2: xuckless/ngtcp2 at $commit"
      rm -rf "$work/ngtcp2" && git init -q "$work/ngtcp2" && cd "$work/ngtcp2"
      git fetch -q --depth 1 https://github.com/xuckless/ngtcp2 "$commit"
      git -c advice.detachedHead=false checkout -q FETCH_HEAD
      git submodule update -q --init --depth 1
      cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug -DENABLE_LIB_ONLY=ON -DBUILD_TESTING=ON \
        -DCMAKE_C_FLAGS="$san" -DCMAKE_EXE_LINKER_FLAGS="-fsanitize=address,undefined" >/dev/null
      cmake --build build -j"$jobs" --target main >/dev/null
      build/tests/main | tail -1
      ;;
    nghttp3)
      fetch nghttp3 "nghttp3/releases"
      ./configure --enable-lib-only --disable-dependency-tracking CFLAGS="$san" LDFLAGS="-fsanitize=address,undefined" >/dev/null
      make -j"$jobs" check >/dev/null || { cat tests/test-suite.log; exit 1; }
      grep -E "^# (PASS|FAIL|ERROR)" tests/test-suite.log
      ;;
    zlib-ng)
      fetch zlib-ng "zlib-ng/archive"
      cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug -DWITH_SANITIZER=Address -DZLIB_COMPAT=OFF -DWITH_GTEST=OFF >/dev/null
      cmake --build build -j"$jobs" >/dev/null
      (cd build && ctest --output-on-failure -j"$jobs" | tail -3)
      ;;
    yyjson)
      fetch yyjson "yyjson/archive"
      cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug -DYYJSON_BUILD_TESTS=ON -DYYJSON_ENABLE_SANITIZE=ON >/dev/null 2>&1 ||
        cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug -DYYJSON_BUILD_TESTS=ON -DCMAKE_C_FLAGS="$san" -DCMAKE_EXE_LINKER_FLAGS="-fsanitize=address,undefined" >/dev/null
      cmake --build build -j"$jobs" >/dev/null
      (cd build && ctest --output-on-failure -j"$jobs" | tail -3)
      ;;
    zstd)
      fetch zstd "zstd/archive"
      # The round-trip fuzzer and the decoder/encoder unit tests, for a
      # bounded time; zstd's full `make check` takes far too long under ASan.
      make -C tests -j"$jobs" fuzzer zstreamtest MOREFLAGS="$san" >/dev/null
      ./tests/fuzzer -T60s
      ./tests/zstreamtest -T60s
      ;;
    *)
      echo "unknown library: $lib" >&2
      exit 1
      ;;
  esac
done
echo "sanitized test suites passed: ${libs[*]}"
