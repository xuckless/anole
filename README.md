# Anole

Anole is a Zig library for building backends: one server core that will serve
REST, WebSockets and gRPC (over HTTP/1.1, HTTP/2 and HTTP/3), with TLS and auth
built in. It is assembled from proven libraries rather than written from
scratch: [zio](https://github.com/lalinsky/zio) for async I/O,
[dusty](https://github.com/lalinsky/dusty) for HTTP/1.1, and nghttp2,
BoringSSL, ngtcp2 and nghttp3 for HTTP/2, TLS and HTTP/3. Zig compiles every C
dependency, so users install nothing besides Zig, and each one sits behind a
build flag, so whatever you turn off is neither downloaded nor compiled.

## Status

Pre-alpha, Milestone 1. The dependency layer builds and passes its smoke tests
on macOS (arm64), and cross-compiles and links for Linux (x86_64 and aarch64);
the Linux test runs are pending CI:

- an HTTP/1.1 server and router (dusty on zio), with a runnable hello world;
- BoringSSL, with an in-memory TLS 1.3/1.2 handshake that negotiates ALPN;
- nghttp2, ngtcp2 and nghttp3 bindings, each with a smoke test.

There is no HTTP/2 server, HTTP/3 endpoint, gRPC or auth code yet. Nothing is
stable before 1.0.

## Requirements

- Zig **0.17.x** (tested on 0.17.0). The build stops with an error on any
  other minor version and on 0.17 dev builds.
- macOS or Linux. Windows is not supported.

## Build and test

```sh
zig build test          # unit tests plus smoke tests for the enabled features
zig build test-flags    # the tests for every preset and edge flag combination
zig build run-hello     # HTTP/1.1 hello world on http://127.0.0.1:8080
```

With the hello world running, `curl localhost:8080/` returns `hello` and
`curl localhost:8080/users/42` returns `user 42`. Pass another port with
`zig build run-hello -- 9000`.

## Build flags

`-Dprofile` sets every feature at once. Individual flags override the profile.

| Flag | minimal | web | full (default) | Adds |
| --- | --- | --- | --- | --- |
| `-Dtls=boringssl\|none` | none | boringssl | boringssl | BoringSSL |
| `-Dhttp2=bool` | false | true | true | nghttp2 |
| `-Dhttp3=bool` | false | false | true | ngtcp2, nghttp3 |
| `-Dgrpc=bool` | false | false | true | gRPC (not implemented yet) |
| `-Dwebsocket=bool` | false | true | true | WebSocket |
| `-Dauth=bool` | false | true | true | auth (not implemented yet) |

Constraints:

- gRPC requires HTTP/2. `-Dhttp2=false` also turns gRPC off, unless you
  explicitly pass `-Dgrpc=true`, which is an error.
- HTTP/3 requires TLS. `-Dtls=none` also turns HTTP/3 off, unless you
  explicitly pass `-Dhttp3=true`, which is an error.

In code, the chosen flags are available as `anole.features`.

## Using Anole as a dependency

```sh
zig fetch --save git+https://github.com/xuckless/anole#<commit>
```

```zig
const anole = b.dependency("anole", .{ .target = target, .optimize = optimize, .profile = .web });
exe.root_module.addImport("anole", anole.module("anole"));
```

## Licence

MIT; see [LICENSE](LICENSE). The fetched and linked components and their
licences (MIT, Apache-2.0, Zlib) are listed in
[THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES).
