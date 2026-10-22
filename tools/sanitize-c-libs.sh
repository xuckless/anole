#!/usr/bin/env bash
# The bundled C libraries' own test suites, built from the exact tarballs
# build.zig.zon pins, with clang's AddressSanitizer and
# UndefinedBehaviorSanitizer. Zig 0.17 has no ASan, so this is where memory
# errors in the C code would show. (Zig's Debug builds already run all the C
# with UBSan; nghttp2's suite runs under ASan in the xuckless/nghttp2 fork's
# CI, since its tests need a git submodule the tarball lacks. BoringSSL tests
# itself under sanitizers upstream at every commit.)
#
#   tools/sanitize-c-libs.sh [ngtcp2 nghttp3 zlib-ng yyjson zstd brotli]
#
# Needs clang, make, cmake, curl, tar and git (ngtcp2 and nghttp3 come from
# the xuckless forks, whose archives lack the tests' munit submodule, so
# each is cloned at the pinned commit with its submodules and built with
# CMake). DETECT_LEAKS=1 turns on
# LeakSanitizer where it exists (Linux).
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=${SANITIZE_WORK:-$(mktemp -d)}
mkdir -p "$work"
libs=("$@")
[ ${#libs[@]} -gt 0 ] || libs=(ngtcp2 nghttp3 zlib-ng yyjson zstd brotli)
jobs=$(nproc 2>/dev/null || sysctl -n hw.ncpu)

export CC=${CC:-clang}
san="-fsanitize=address,undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer -g -O1"
export ASAN_OPTIONS=detect_leaks=${DETECT_LEAKS:-0}:abort_on_error=1
export UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=1

# The URL build.zig.zon pins for a library (matched on a fragment of it).
url_of() {
  grep -o "\"https://[^\"]*$1[^\"]*\"" "$root/build.zig.zon" | head -1 | tr -d '"'
}

# The SHA-256 of every file this script downloads, by URL. build.zig.zon
# pins the unpacked tree by Zig's own hash, which this script does not
# compute, so a pin bump adds the new tarball's line here (MAINTAINING.md).
# The git checkouts below are pinned by commit and need none.
sha256_of() {
  case $1 in
    https://github.com/zlib-ng/zlib-ng/archive/refs/tags/2.3.3.tar.gz) echo f9c65aa9c852eb8255b636fd9f07ce1c406f061ec19a2e7d508b318ca0c907d1 ;;
    https://github.com/ibireme/yyjson/archive/refs/tags/0.13.0.tar.gz) echo 34e0f62a2bc11ab20d601e8ca1cc2b2079503aa45119a19133d89d19b94a0fae ;;
    https://github.com/facebook/zstd/archive/refs/tags/v1.5.7.tar.gz) echo 37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3 ;;
    https://github.com/google/brotli/archive/refs/tags/v1.2.0.tar.gz) echo 816c96e8e8f193b40151dad7e8ff37b1221d019dbcb9c35cd3fadbfe6477dfec ;;
    https://github.com/google/brotli/releases/download/v1.2.0/testdata.txz) echo e8624d888f13067e7635353397cf42956bf4ca1382da67f9cec8d43e800deecb ;;
    *) echo "" ;;
  esac
}

# Downloads $1 to the file $2 and checks it against `sha256_of`.
download() {
  local url=$1 out=$2 want got
  want=$(sha256_of "$url")
  [ -n "$want" ] || { echo "no SHA-256 for $url: add it to sha256_of in $0" >&2; exit 1; }
  curl -fsSL "$url" -o "$out"
  if command -v sha256sum >/dev/null; then got=$(sha256sum "$out" | cut -d' ' -f1); else got=$(shasum -a 256 "$out" | cut -d' ' -f1); fi
  [ "$got" = "$want" ] || { echo "SHA-256 mismatch for $url: got $got, want $want" >&2; exit 1; }
}

fetch() {
  local name=$1 url
  url=$(url_of "$2")
  [ -n "$url" ] || { echo "no pinned URL matching $2" >&2; exit 1; }
  echo "== $name: $url"
  rm -rf "$work/$name" && mkdir -p "$work/$name"
  download "$url" "$work/$name.tar"
  tar -x -f "$work/$name.tar" -C "$work/$name" --strip-components=1 $( [[ $url == *.xz ]] && echo -J || echo -z )
  rm -f "$work/$name.tar"
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
        -DENABLE_OPENSSL=OFF -DENABLE_GNUTLS=OFF -DENABLE_BORINGSSL=OFF -DENABLE_PICOTLS=OFF -DENABLE_WOLFSSL=OFF \
        -DCMAKE_C_FLAGS="$san" -DCMAKE_EXE_LINKER_FLAGS="-fsanitize=address,undefined" >/dev/null
      cmake --build build -j"$jobs" --target main >/dev/null
      build/tests/main | tail -1
      ;;
    nghttp3)
      url=$(url_of "xuckless/nghttp3/archive")
      [ -n "$url" ] || { echo "no pinned URL matching xuckless/nghttp3/archive" >&2; exit 1; }
      commit=${url##*/}
      commit=${commit%.tar.gz}
      echo "== nghttp3: xuckless/nghttp3 at $commit"
      rm -rf "$work/nghttp3" && git init -q "$work/nghttp3" && cd "$work/nghttp3"
      git fetch -q --depth 1 https://github.com/xuckless/nghttp3 "$commit"
      git -c advice.detachedHead=false checkout -q FETCH_HEAD
      git submodule update -q --init --depth 1
      cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug -DENABLE_LIB_ONLY=ON -DBUILD_TESTING=ON \
        -DCMAKE_C_FLAGS="$san" -DCMAKE_EXE_LINKER_FLAGS="-fsanitize=address,undefined" >/dev/null
      cmake --build build -j"$jobs" --target main >/dev/null
      build/tests/main | tail -1
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
    brotli)
      fetch brotli "google/brotli/archive"
      # Its CTest suite: the CLI round-trips files at qualities 1, 6, 9 and
      # 11 and decodes the reference streams in tests/testdata. The corpus
      # is a release asset of the same tag (the tag archive has a few files).
      tag=$(url_of "google/brotli/archive")
      tag=${tag##*/tags/}
      tag=${tag%.tar.gz}
      download "https://github.com/google/brotli/releases/download/$tag/testdata.txz" "$work/brotli-testdata.txz"
      tar -xJ -f "$work/brotli-testdata.txz"
      rm -f "$work/brotli-testdata.txz"
      cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug \
        -DCMAKE_C_FLAGS="$san" -DCMAKE_EXE_LINKER_FLAGS="-fsanitize=address,undefined" >/dev/null
      cmake --build build -j"$jobs" >/dev/null
      (cd build && ctest --output-on-failure -j"$jobs" | tail -3)
      ;;
    *)
      echo "unknown library: $lib" >&2
      exit 1
      ;;
  esac
done
echo "sanitized test suites passed: ${libs[*]}"
