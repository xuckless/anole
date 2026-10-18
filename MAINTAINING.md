# Maintaining Anole

How the pinned dependencies, the forks and the Zig version are kept up to
date, and how a release is cut. Anole bundles its C libraries, so their
security fixes ship only when Anole bumps a pin: the checks below exist so
that happens promptly.

## What is pinned where

| Component | Pinned in | Form |
| --- | --- | --- |
| zio | build.zig.zon | commit of the xuckless/zio fork, branch `anole` |
| dusty | build.zig.zon | commit of the xuckless/dusty fork, branch `anole` |
| nghttp2 1.70.0 | build.zig.zon | commit of the xuckless/nghttp2 fork, branch `anole` (tarball) |
| BoringSSL | build.zig.zon | upstream commit tarball, compiled by `build/boringssl.zig` |
| ngtcp2 1.25.0 | build.zig.zon | commit of the xuckless/ngtcp2 fork, branch `anole` (tarball) |
| nghttp3 1.18.0 | build.zig.zon | commit of the xuckless/nghttp3 fork, branch `anole` (tarball) |
| zlib-ng, zstd, yyjson, hiredis | build.zig.zon | upstream release tag tarballs |
| zig-protobuf | build.zig.zon | upstream commit; it pins protoc per platform |
| websocket-zig, zig-jwt | build.zig.zon | commits of the xuckless forks, branch `anole` |
| translate-c | build.zig.zon | commit on its `zig-0.17.x` branch |

`tools/advisories.py` holds a second copy of the C libraries' versions, so it
can check them against the upstreams' advisories. Moving a pin without
updating that table makes the script exit 2.

## Advisories

`.github/workflows/advisories.yml` runs `tools/advisories.py` every Monday and
whenever build.zig.zon changes. It checks nghttp2, ngtcp2, nghttp3, zlib-ng,
zstd, yyjson and hiredis against their GitHub security advisories and the
BoringSSL commit against OSV. A failure means a pinned version is affected:
bump that library (below) and release.

Run it by hand with `GH_TOKEN=$(gh auth token) tools/advisories.py`.

## Bumping a C library

1. Change the URL in build.zig.zon and let `zig build` report the new hash.
   Do not pre-fetch tarballs with `zig fetch <url>`: Zig 0.17.0 writes a
   broken archive to the global cache that way, and a later build fails with
   "hash mismatch". Check the final hashes from an empty cache
   (`ZIG_GLOBAL_CACHE_DIR=$(mktemp -d) zig build test`).
2. Update the version in `tools/advisories.py` and the "Pinned:" line in
   THIRD_PARTY_NOTICES. Re-read the "Includes:" lines there (sfparse in
   nghttp2 and nghttp3, PCG in ngtcp2, fiat in BoringSSL), and re-copy
   BoringSSL's licence text into part E if it changed.
3. Library-specific steps:
   - **BoringSSL and ngtcp2 move together.** ngtcp2's BoringSSL helper is
     tested against one BoringSSL commit; pin BoringSSL at or after it.
     `build/boringssl.zig` reads the file lists from the tarball's
     `gen/sources.json`, so check that it still builds every platform.
   - **nghttp2** comes from the fork, which carries an RFC 9113 strictness
     patch. Rebase the patch onto the new tag on a new branch, run nghttp2's
     unit tests and h2spec in strict mode (147/147 over h2c and TLS), merge
     into `anole`, and pin the merge commit.
   - **ngtcp2** comes from the fork too: the tag, the release's generated
     `lib/includes/ngtcp2/version.h`, and a patch that keeps a server's
     fallback connection ID across a migration right after a NAT rebinding
     (`conn_stop_pv_keep`, with `test_ngtcp2_conn_server_migration_after_nat_rebinding`).
     On a new tag: drop the patch if upstream fixed the bug (run that test
     against the new tag), otherwise rebase it on a new branch, run ngtcp2's
     unit tests, commit the new `version.h`, merge into `anole`, and pin the
     merge commit. Then run Anole's migration test ("a client that moves to
     a new port"), `tests/h3/run.sh` and the interop runner.
   - **nghttp3** comes from the fork as well: the tag, the release's
     generated `lib/includes/nghttp3/version.h` and its bundled
     `lib/sfparse` (a submodule in the repository, plain files in the fork,
     so the GitHub archive is complete), and
     `nghttp3_conn_add_extra_setting`, which lets Anole send SETTINGS
     nghttp3 does not know (WebTransport's), with
     `test_nghttp3_conn_add_extra_setting`. On a new tag: drop the patch if
     upstream can send such settings itself (its WebTransport PR #442, or
     issue #501), otherwise rebase it on a new branch, copy the new
     tarball's `version.h` and `lib/sfparse`, run nghttp3's unit tests,
     merge into `anole`, and pin the merge commit. Then run
     `tests/h3/run.sh` (WebTransport and RFC 9220 included) and
     `tests/interop/webtransport/run.sh`.
   - **nghttp2 and nghttp3 both ship sfparse** with the same exported
     symbols, and the linker keeps one copy. `build/nghttp3.zig`
     (`checkSharedSfparse`) stops the build when the two copies differ; then
     rename one copy's symbols with `-D` macros or build one shared sfparse.
4. Run everything CI runs: `zig build test`, `zig build test-flags`,
   `zig build dusty-test`, the profile builds, h2spec, Autobahn, the gRPC
   interop, `tests/h3/run.sh`, `tests/interop/run.sh` and
   `tests/interop/webtransport/run.sh`.

## The forks

The forks live under github.com/xuckless, each on a branch named `anole`, and
are pinned by commit. Work happens on a topic branch, is merged into `anole`
with `--no-ff`, pushed, and then pinned here with
`zig fetch --save=<name> git+https://github.com/xuckless/<repo>#<commit>`.
Commits are authored as `xuckless <xuckless@users.noreply.github.com>`.
Nothing goes upstream unless an upstream asks for it; the PRs already open
against lalinsky/dusty (#263-#270) are left as they are.

- **dusty**: after a change, run its own suite under Zig 0.17 and 0.16
  (`zig build test` in the fork), and Anole's `zig build dusty-test`, which
  runs that suite on Anole's TLS, nghttp2, zlib-ng and zstd. Its fuzz
  targets ("fuzz:" tests, src/fuzz.zig as in Anole) run through
  `zig build fuzz -Duse_http2=true --fuzz=200K` in the fork, since its own
  test runner has no fuzzer; CI's `fuzz` job runs them from the pinned
  package. C compiled into the dusty module breaks Zig 0.17's fuzzer, so
  C goes in a static library the module links (as llhttp and nghttp2 do).
- **zio**: after a change, run its suite in both scheduling modes
  (`./check.sh` and `./check.sh --scheduling pinned` in the fork; Anole
  runs pinned). Its changes: the pinned mode's run queue (`pinned-fifo`), and
  accepting on a busy executor (`accept-now`: a direct accept with its own
  budget, and spawn backpressure every 64 spawns instead of on every one).
  `bench/` measures both (`conns`, `raw`).
- **nghttp2**, **ngtcp2**, **nghttp3**: see above.
- **websocket-zig**, **zig-jwt**: ports to Zig 0.17 with small fixes; rebase
  when upstream moves and the fixes are still needed.

## The Zig version

Anole targets one Zig minor version at a time. `build.zig` accepts any 0.17.x
release and rejects other versions and dev builds at compile time, and
build.zig.zon's `minimum_zig_version` says the same (it is only advisory).

Moving to the next minor version (0.18):

1. Move every Zig dependency to a commit that supports it: zio, the dusty fork
   (keep its 0.17 support while users need it), zig-protobuf, the
   websocket-zig and zig-jwt forks, and translate-c's matching branch.
2. Change the version check in `build.zig`, `minimum_zig_version`, the
   README's requirements, and the CI workflows' `version:`.
3. Re-run the `@bitCast`, `@cImport`/translate-c and `std.Io` audits the 0.17
   move needed (see the release notes of the new version).

## Cadence

- Security fixes in a bundled library: bump and release within days of the
  advisory (the weekly check is the backstop, not the alarm).
- Other library releases: bump before each Anole release, not one by one.
- Zig: move when the next minor version is released and every Zig dependency
  supports it.

## Cutting a release

1. Update CHANGELOG.md: turn "Unreleased" into the version and date.
2. Make sure CI is green on the commit, including the `consumer` job, which
   builds a fresh project that adds Anole with `zig fetch --save`.
3. Tag it `vX.Y.Z` and push the tag. Users then add it with

       zig fetch --save git+https://github.com/xuckless/anole#vX.Y.Z

   (the `git+https` form, not a tarball URL, because of the Zig 0.17.0 fetch
   bug above).
4. Before 1.0 there is no API stability promise; say what changed in the
   changelog anyway.
