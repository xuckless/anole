# Security policy

## Reporting a vulnerability

Please report security problems privately, through GitHub:
**[Report a vulnerability](https://github.com/xuckless/anole/security/advisories/new)**
(the repository's Security tab, then "Report a vulnerability"). Only the
maintainers see the report. Please don't open a public issue, pull request
or discussion for it.

A useful report says:

- what is affected: the Anole commit or release, the build flags or profile
  (`-Dprofile=...`, `-Dtls=...`), the operating system, and whether the
  event loop was io_uring, epoll or kqueue;
- what an attacker can do, and what they need first (network access only, a
  valid session, a particular configuration);
- how to reproduce it: a request, a packet capture, a small program or a
  failing test;
- whether you plan to publish, and when.

## What happens next

Anole is maintained by a small team, so these are targets, not guarantees:

- an acknowledgement within 3 days;
- a first assessment (confirmed or not, and how severe) within 7 days;
- a fix, and an advisory published through GitHub's security advisories,
  within 90 days of the report, sooner for anything that is easy to exploit
  remotely. If we need longer we will say why and agree a date with you.

We credit reporters in the advisory and in CHANGELOG.md unless you prefer
not to be named. A CVE is requested through GitHub when the issue warrants
one.

## Supported versions

Anole is before 1.0. Security fixes land on `main` and in the next release;
older releases are not patched. Once 1.0 is out, this section will say
which release lines get fixes.

| Version | Supported |
| --- | --- |
| `main` and the latest 0.x release | yes |
| older 0.x releases | no: upgrade |

## Scope

In scope: everything in this repository that ships in an application built
with Anole. That includes:

- Anole's own code in `src/` and the build scripts in `build.zig` and
  `build/`;
- the HTTP core in `src/http/core` (adapted from lalinsky/dusty) and the
  other modules copied in with attribution (listed in THIRD_PARTY_NOTICES);
- the patches Anole carries on its forks (xuckless/zio, nghttp2, ngtcp2,
  nghttp3, pg.zig, zig-sqlite and the others pinned in `build.zig.zon`).

Bundled C libraries (BoringSSL, nghttp2, ngtcp2, nghttp3, zlib-ng, zstd,
Brotli, yyjson, hiredis, SQLite, llhttp): a flaw in the library itself
belongs with its upstream project, which runs its own disclosure process.
Tell us as well when it affects Anole, so we can bump the pin as soon as a
fix is out. A flaw in how Anole uses one of these libraries is ours, and is
in scope.

Out of scope:

- `bench/`, `tests/` and `tools/`, which are benchmark, test and
  maintenance code and are not built into applications;
- the examples' development certificates: `anole.tls.selfSigned` makes a
  throwaway certificate in memory for local development, and is not meant
  for production;
- options documented as test-only, such as `Http3.hq_interop_root` for the
  QUIC interop runner;
- running out of memory or connections when the limits a deployment sets
  (`max_connections`, body size, header and stream limits, timeouts) allow
  it. A report that the defaults are unsafe, or that a limit is not
  enforced, is in scope.

## How dependencies are watched

- `tools/advisories.py` checks the C libraries pinned in `build.zig.zon`
  at their pinned versions against the upstream's GitHub security advisories, BoringSSL's
  commit against OSV, and SQLite against NVD. The `Advisories` workflow runs
  it every Monday and whenever a pin changes. MAINTAINING.md has the bump
  steps; a security fix in a bundled library is released within days of
  its advisory. llhttp is vendored in `src/http/core`, so its releases are
  followed by hand.
- Dependabot keeps the GitHub Actions in `.github/workflows` up to date and
  raises alerts for the dependency manifests it can read. It cannot read
  Zig's `build.zig.zon`, which is why the advisories check above exists.
- GitHub secret scanning with push protection is on, and no private keys or
  certificates are committed: tests and examples generate theirs when they
  run.
- The bundled C libraries' own test suites run under AddressSanitizer and
  UndefinedBehaviorSanitizer (`Sanitizers` workflow). The parsers have
  fuzz targets that CI runs 200,000 times each, and the protocol
  conformance suites (h2spec, Autobahn, the QUIC interop runner, gRPC
  interop) gate every pull request.
