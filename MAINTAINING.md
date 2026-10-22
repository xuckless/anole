# Maintaining Anole

How the pinned dependencies, the forks and the Zig version are kept up to
date, and how a release is cut. Anole bundles its C libraries, so their
security fixes ship only when Anole bumps a pin: the checks below exist so
that happens promptly.

## What is pinned where

| Component | Pinned in | Form |
| --- | --- | --- |
| zio | build.zig.zon | commit of the xuckless/zio fork, branch `anole` |
| HTTP core (from dusty) | src/http/core | Anole code since 2026-10-20; see "The HTTP core" below |
| nghttp2 1.70.0 | build.zig.zon | commit of the xuckless/nghttp2 fork, branch `anole` (tarball) |
| BoringSSL | build.zig.zon | upstream commit tarball, compiled by `build/boringssl.zig` |
| ngtcp2 1.25.0 | build.zig.zon | commit of the xuckless/ngtcp2 fork, branch `anole` (tarball) |
| nghttp3 1.18.0 | build.zig.zon | commit of the xuckless/nghttp3 fork, branch `anole` (tarball) |
| zlib-ng, zstd, Brotli, yyjson, hiredis | build.zig.zon | upstream release tag tarballs |
| zig-protobuf | build.zig.zon | commit of the xuckless/zig-protobuf fork, branch `anole`; it pins protoc per platform |
| websocket-zig, zig-jwt, zig-sqlite | build.zig.zon | commits of the xuckless forks, branch `anole` |
| pg.zig | build.zig.zon | commit of the xuckless/pg.zig fork, branch `anole` (git URL) |
| SQLite 3.54.1 | build.zig.zon | sqlite.org amalgamation zip, compiled by `build/sqlite.zig` |
| translate-c | build.zig.zon | commit on its `zig-0.17.x` branch |

`tools/advisories.py` holds a second copy of the C libraries' versions, so it
can check them against the upstreams' advisories. Moving a pin without
updating that table makes the script exit 2.

CI's GitHub Actions are pinned by commit SHA, the tag in a comment beside it;
bump them by resolving the new tag's commit (`git ls-remote --tags`). The
Python packages the protocol checks install are pinned with hashes in
`tests/h3/requirements.txt` (aioquic) and `tests/interop/requirements.txt`
(the QUIC interop runner's, which follow its pinned commit): regenerate them
with every file's SHA-256 from PyPI when either moves.

## Advisories

`.github/workflows/advisories.yml` runs `tools/advisories.py` every Monday and
whenever build.zig.zon changes. It checks nghttp2, ngtcp2, nghttp3, zlib-ng,
zstd, Brotli, yyjson and hiredis against their GitHub security advisories, the
BoringSSL commit against OSV, and SQLite against NVD's CVE list (SQLite
publishes no GitHub advisories; `NVD_IGNORE` lists CVEs NVD matches to every
SQLite version only because SQLite is the platform of the vulnerable product). A failure means a pinned version is affected:
bump that library (below) and release.

Run it by hand with `GH_TOKEN=$(gh auth token) tools/advisories.py`.

## Bumping a C library

1. Change the URL in build.zig.zon and let `zig build` report the new hash.
   Do not pre-fetch tarballs with `zig fetch <url>`: Zig 0.17.0 writes a
   broken archive to the global cache that way, and a later build fails with
   "hash mismatch". Check the final hashes from an empty cache
   (`ZIG_GLOBAL_CACHE_DIR=$(mktemp -d) zig build test`).
2. Update the version in `tools/advisories.py` and the "Pinned:" line in
   THIRD_PARTY_NOTICES. For zlib-ng, zstd, Brotli and yyjson, add the new
   tarball's SHA-256 (and Brotli's `testdata.txz`'s) to `sha256_of` in
   `tools/sanitize-c-libs.sh`, which refuses a download it has no hash for. Re-read the "Includes:" lines there (sfparse in
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
     (`conn_stop_pv_keep`, with `test_ngtcp2_conn_server_migration_after_nat_rebinding`),
     and one that makes a server PTO in the Initial space reclaim two
     packets as the client's does (`conn_write_pkt`, with
     `test_ngtcp2_conn_server_initial_pto_reclaim`; without it a ServerHello
     split over two packets stalls quic-go's lossy handshakes).
     On a new tag: drop a patch if upstream fixed its bug (run its test
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
   - **Brotli** (`-Dbrotli`): `build/brotli.zig` lists the `.c` files of
     the tarball's `c/common`, `c/enc` and `c/dec` (what upstream's
     CMakeLists.txt globs); compare the lists with the new tarball, and
     keep `c/enc/static_init_lazy.cc` out (C++, only for
     `BROTLI_STATIC_INIT_LAZY`). Then run `tools/sanitize-c-libs.sh brotli`
     and the Brotli tests (`zig build test`: the round trips and the
     "fuzz: Brotli" target in `src/http/core/brotli_io.zig`).
   - **SQLite** is the amalgamation zip from sqlite.org (the URL carries
     the year and the version as `3XXYYZZ`); check the zip's SHA3-256
     against the download page. Its compile-time options are
     `build/sqlite.zig`'s `config` header, which the zig-sqlite fork's
     bindings read too; the build test (`sqlite-build-test`, part of
     `zig build test`) checks the version number and that the options
     reached the library. Bump the version it expects, and the zig-sqlite
     fork's own lazy amalgamation (used only when it builds alone) with it.
     Then run `zig build test` with `-Dsqlite` on Linux and macOS.
   - **nghttp2 and nghttp3 both ship sfparse** with the same exported
     symbols, and the linker keeps one copy. `build/nghttp3.zig`
     (`checkSharedSfparse`) stops the build when the two copies differ; then
     rename one copy's symbols with `-D` macros or build one shared sfparse.
4. Run everything CI runs: `zig build test`, `zig build test-flags`,
   the profile builds, h2spec, Autobahn, the gRPC
   interop, `tests/h3/run.sh`, `tests/interop/run.sh` and
   `tests/interop/webtransport/run.sh`.

## The forks

The forks live under github.com/xuckless, each on a branch named `anole`, and
are pinned by commit. Work happens on a topic branch, is merged into `anole`
with `--no-ff`, pushed, and then pinned here with
`zig fetch --save=<name> git+https://github.com/xuckless/<repo>#<commit>`.
Commits are authored as `xuckless <xuckless@users.noreply.github.com>`.
Nothing goes upstream unless an upstream asks for it (zio is the exception:
lalinsky invited the scheduler PRs, lalinsky/zio #836-#838).

- **zio**: after a change, run its suite in both scheduling modes
  (`./check.sh` and `./check.sh --scheduling pinned` in the fork; Anole
  runs pinned). Its changes: the pinned mode's run queue (`pinned-fifo`), and
  accepting on a busy executor (`accept-now`: a direct accept with its own
  budget, and spawn backpressure every 64 spawns instead of on every one).
  The bench suite's `conns` and `raw` scenarios measure both.
- **nghttp2**, **ngtcp2**, **nghttp3**: see above.
- **websocket-zig**, **zig-jwt**: ports to Zig 0.17 with small fixes; rebase
  when upstream moves and the fixes are still needed. websocket-zig also
  carries a security patch (RSV1 refused on control frames and
  continuations); keep it on every rebase.
- **zig-protobuf**: upstream e9e18c7 plus security patches in the decoder
  (nesting depth bound, length-delimited fields checked against the input
  before allocating, Timestamp validation). On an upstream move: merge it
  into `anole`, run the fork's tests and conformance suite, re-pin, and
  run Anole's gRPC tests and fuzz targets.
- **pg.zig** (PostgreSQL, `-Dpostgres`): upstream master 4d63344 plus a
  read timeout, `Conn.cancel()` (CancelRequest), the automatic statement
  cache, pool `max_lifetime`/`idle_timeout`, `Pool.acquireOpts` keeping a
  refused connect's error, and TLS through an injected `tls` module
  instead of OpenSSL (Anole's is `src/pg/tls.zig`), plus security patches
  (server messages checked before they are read, LISTEN channel names
  bounded, SCRAM nonce and iteration count checks, `require_auth` and
  SCRAM channel binding, the pool's optional session reset, on every
  release or only when the SQL may have changed the session:
  `Pool.Reset.auto`, `session.zig`), and for the C ABI parameters as a
  slice of tagged unions and `QueryOpts.text_results`
  (branch `capi-dynamic`, generic, not offered upstream yet). The first four are
  also on branches based on upstream master (`upstream-read-timeout`,
  `upstream-cancel-request`, `upstream-statement-cache`,
  `upstream-pool-lifetimes`), open upstream as karlseguin/pg.zig
  #150-#153; generic fixes may go upstream (user, 2026-10-18), the TLS
  swap stays in the fork. On an upstream move: merge master into `anole`,
  run the fork's `tests/run.sh` (a throwaway postgres:17, on std's
  Threaded Io and on zio, with and without TLS), re-pin, and run Anole's
  `tests/postgres/run.sh` (plain and verify-full TLS).
- **zig-sqlite**: upstream's open Zig 0.17 port (vrischmann/zig-sqlite PR
  #215) plus the fork's build changes: bindings through the translate-c
  package, `sqlite3_initialize` in `Db.init` (Anole builds SQLite with
  `SQLITE_OMIT_AUTOINIT`), SQLite and its options header taken from the
  caller (`sqlite_include`, `sqlite_config`), the bundled SQLite lazy, the
  loadable-extension path dropped. Upstream PRs are allowed for this one
  (generic fixes only); the translate-c and build changes are offered into
  #215's branch as Greebling/zig-sqlite#1. When #215 merges upstream, rebase
  `anole` onto it. Run its tests (`zig build test` in the fork) after a
  change. Anole uses it to open connections and for `Conn.run`; statements,
  binding and rows are Anole's own (src/sqlite/root.zig).

## The HTTP core

`src/http/core` is the HTTP/1.1 server, router, middleware, client,
WebSocket and HTTP/2 engine. It started as lalinsky/dusty (MIT, base d3cb485)
and Anole's fork of it (xuckless/dusty, last at 86d152f), and has been
Anole code since 2026-10-20: changes land here directly. Keep the
attribution header on every file and THIRD_PARTY_NOTICES part B current.

- Its own tests run in `zig build test` (and alone as `zig build core-test`)
  with its test runner and its zio stub, on Anole's TLS, nghttp2, zlib-ng,
  zstd and Brotli. Their certificate is made at build time by
  `tests/test_cert.zig`; no key is committed.
- Its "fuzz:" targets run a second time under Zig's own test runner, so
  `zig build test --fuzz` fuzzes them with Anole's.
- C compiled into the core's module breaks Zig 0.17's fuzzer, so C goes in a
  static library the module links, as llhttp does (`LlHttp` in build.zig).
- Upstream watch: look through lalinsky/dusty's commits since d3cb485 before
  each release and port the fixes that apply. The PRs open there from the
  fork (#263-#270) are left as they are.

## The docs site

https://xuckless.github.io/anole/ is `site/`, an Astro + Starlight project
that `.github/workflows/pages.yml` builds and deploys on every push to main
that touches docs/, src/, site/, assets/ or the build files (pull requests
build it without deploying). Node is needed only there: `site/` is not in
build.zig.zon's `.paths`, so it never ships in the Zig package, and
`zig build` never runs Node.

- Content: the guides are docs/*.md, the same files GitHub shows; nothing is
  committed twice. `site/scripts/sync-docs.mjs` (run by `npm run dev` and
  `npm run build`) copies them into `site/src/content/docs/` (gitignored),
  turns each H1 into the page title, rewrites guide links (`server.md#tls`)
  to site routes and other relative links (`../README.md`) to GitHub, and
  fails on a relative link to a missing file. Only the landing page,
  `site/src/content/docs/index.mdx`, lives in site/.
- API reference: `zig build docs` writes Zig's autodoc of the `anole` module
  (default full profile) to zig-out/docs; the sync copies it to /api/ when
  it exists.
- Broken internal links and anchors fail the build (starlight-links-validator).
- Preview locally: `zig build docs` (optional, for the API reference), then
  `cd site && npm ci && npm run dev` (the dev server shows the API
  reference only as /anole/api/index.html). `npm run build && npm run
  preview` serves the production build.
- A new guide: add `docs/<name>.md` (an H1 title, then the text) and its
  `<name>` to the sidebar list in `site/astro.config.mjs`, and to the
  README's documentation list.
- Versions are pinned exactly in `site/package.json` with a committed
  `package-lock.json`. Bump them together (`npm install --save-exact
  astro@x @astrojs/starlight@y starlight-links-validator@z`), then build and
  preview before merging.

## The Zig version

Anole targets one Zig minor version at a time. `build.zig` accepts any 0.17.x
release and rejects other versions and dev builds at compile time, and
build.zig.zon's `minimum_zig_version` says the same (it is only advisory).

Moving to the next minor version (0.18):

1. Move every Zig dependency to a commit that supports it: zio, the zig-protobuf,
   websocket-zig, zig-jwt and zig-sqlite forks, and translate-c's matching branch.
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

## The wiki

The GitHub wiki is a copy of `docs/`. The `Wiki` workflow runs
`tools/docs2wiki.py` on every push to main that touches `docs/` and pushes the
pages: links between guides become wiki links, other repository links point
at the commit, and `Home`, `_Sidebar` and `_Footer` are generated. Edit
`docs/`, never the wiki. A new guide needs an entry in the script's `PAGES`;
a renamed or removed guide leaves its old page behind, to delete in the wiki
by hand.

## Cutting a release

1. Update CHANGELOG.md: turn "Unreleased" into the version and date. Set
   the same version in build.zig.zon's `.version` and in the MongoDB
   client's handshake metadata (`driver_version` in
   src/mongodb/connection.zig), and point the install snippets (README.md,
   docs/getting-started.md) at the new tag.
2. Make sure CI is green on the commit, including the `consumer` job, which
   builds a fresh project that adds Anole with `zig fetch --save`.
3. Tag it `vX.Y.Z` and push the tag. Users then add it with

       zig fetch --save git+https://github.com/xuckless/anole#vX.Y.Z

   (the `git+https` form, not a tarball URL, because of the Zig 0.17.0 fetch
   bug above).
4. Before 1.0 there is no API stability promise; say what changed in the
   changelog anyway.
