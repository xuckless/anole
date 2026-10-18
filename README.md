# Anole

Anole is a Zig library for building backends: one server core that will serve
REST, WebSockets and gRPC (over HTTP/1.1, HTTP/2 and HTTP/3), with TLS and auth
built in. It is assembled from proven libraries rather than written from
scratch: [zio](https://github.com/lalinsky/zio) for async I/O,
[dusty](https://github.com/lalinsky/dusty) (through a fork) for HTTP, and nghttp2,
BoringSSL, ngtcp2 and nghttp3 for HTTP/2, TLS and HTTP/3. Zig compiles every C
dependency, so users install nothing besides Zig, and each one sits behind a
build flag, so whatever you turn off is neither downloaded nor compiled.

## Status

Pre-alpha. The dependency layer builds and passes its tests on macOS (arm64)
and Linux (x86_64), and cross-compiles for aarch64 Linux:

- `anole.Server`: one call sets up the runtime (one pinned executor per core),
  the listeners, SIGINT/SIGTERM and a graceful drain;
- an HTTP/1.1 server and router (dusty on zio): path parameters, nested groups,
  middleware (request IDs, access log, compression, CORS, sessions), 405 with
  `Allow`, static files with ranges, ETags and precompressed variants, per-phase
  timeouts and body limits, keep-alive and pipelining, and no allocation per
  request on a warm connection;
- response compression with zstd or gzip (zlib-ng), chosen by the client's
  q-values, and decoding of compressed request bodies;
- the PROXY protocol (v1 and v2) and `X-Forwarded-*` from trusted proxies;
- HTTPS through BoringSSL: TLS 1.3 and 1.2, ALPN, certificate verification,
  mutual TLS, for both the server and dusty's HTTP client;
- HTTP/2 on nghttp2, over TLS (ALPN "h2") and cleartext (prior knowledge), on
  the same router and handlers, with streaming bodies, flow control and
  trailers; h2spec 2.6.0 passes every case in strict mode, over h2c and TLS;
  a drain sends every connection a two-phase GOAWAY;
- ngtcp2 and nghttp3 bindings, with a smoke test.

There is no HTTP/3 endpoint, gRPC or auth code yet. Nothing is
stable before 1.0.

## Requirements

- Zig **0.17.x** (tested on 0.17.0). The build stops with an error on any
  other minor version and on 0.17 dev builds.
- macOS or Linux. Windows is not supported.

## Quick start

```zig
const std = @import("std");
const anole = @import("anole");

pub const zio_options = anole.zio_options;

fn getUser(req: *anole.Request, res: *anole.Response) !void {
    try res.print(.text, "user {s}", .{req.params.get("id").?});
}

pub fn main(init: std.process.Init) !void {
    var app = try anole.Server(void).init(init.gpa, .{
        .http = .{ .port = 8080 }, // HTTP/1.1, plus HTTP/2 for clients that start with it
        .https = .{ .port = 8443, .cert = .dev_self_signed }, // or .pem / .files
    }, {});
    defer app.deinit();
    app.use(anole.middleware.RequestId.init(.{}));
    app.get("/users/:id", getUser);
    try app.run(); // until SIGINT/SIGTERM, then drains
}
```

Handlers make async calls (outbound HTTP, files, timers, anything on `std.Io`)
through `req.io`; a call that waits suspends that request only.
`examples/io` shows this, and `anole.http` exposes all of dusty for anything
`Server` does not wrap.

## Build and test

```sh
zig build test          # unit tests plus smoke tests for the enabled features
zig build test-flags    # the tests for every preset and edge flag combination
zig build run-hello     # hello world on http://127.0.0.1:8080 and https://127.0.0.1:8443
zig build run-io        # handlers waiting on timers, files and outbound requests (port 8081)
```

Both ports speak HTTP/1.1 and HTTP/2 (`curl --http2-prior-knowledge` on 8080,
`curl -k --http2` on 8443). `POST /echo` streams the request body back.

With the hello world running, `curl localhost:8080/` returns `hello` and
`curl localhost:8080/users/42` returns `user 42`. The HTTPS listener uses a
self-signed certificate generated at startup and kept in memory, so use
`curl -k https://localhost:8443/`. Pass other ports with
`zig build run-hello -- 9000 9443`.

## Build flags

`-Dprofile` sets every feature at once. Individual flags override the profile.

| Flag | minimal | web | full (default) | Adds |
| --- | --- | --- | --- | --- |
| `-Dtls=boringssl\|none` | none | boringssl | boringssl | BoringSSL |
| `-Dhttp2=bool` | false | true | true | nghttp2 |
| `-Dhttp3=bool` | false | false | true | ngtcp2, nghttp3 |
| `-Dcompression=bool` | false | true | true | zlib-ng, zstd |
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
licences (MIT, Apache-2.0, Zlib, BSD) are listed in
[THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES).
