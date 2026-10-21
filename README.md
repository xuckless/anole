<p align="center">
  <img src="assets/banner.png" alt="Anole: a Zig backend server" width="720">
</p>

<p align="center">
  <b>One Zig server for your whole backend.</b><br>
  REST, WebSockets, gRPC and WebTransport over HTTP/1.1, HTTP/2 and HTTP/3.
</p>

<p align="center">
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/github/license/xuckless/anole?color=green"></a>
  <a href="https://ziglang.org/download/"><img alt="Zig 0.17" src="https://img.shields.io/badge/Zig-0.17.0-F7A41D?logo=zig&logoColor=white"></a>
  <img alt="Platforms: Linux, macOS" src="https://img.shields.io/badge/platforms-Linux%20%7C%20macOS-lightgrey">
  <img alt="Protocols: HTTP/1.1, HTTP/2, HTTP/3, gRPC, WebSocket" src="https://img.shields.io/badge/protocols-HTTP%2F1.1%20%C2%B7%20h2%20%C2%B7%20h3%20%C2%B7%20gRPC%20%C2%B7%20WS-blue">
  <img alt="WebTransport" src="https://img.shields.io/badge/WebTransport-draft--02-8A4FFF">
  <img alt="Auth: JWT, OIDC, sessions" src="https://img.shields.io/badge/auth-JWT%20%C2%B7%20OIDC%20%C2%B7%20sessions-D8407F">
  <img alt="TLS: BoringSSL" src="https://img.shields.io/badge/TLS-BoringSSL-2E7D32">
  <img alt="Observability: Prometheus, OpenTelemetry" src="https://img.shields.io/badge/observability-Prometheus%20%C2%B7%20OpenTelemetry-E6522C">
  <img alt="Database: SQLite, PostgreSQL, MongoDB, in progress" src="https://img.shields.io/badge/database-SQLite%20%C2%B7%20PostgreSQL%20%C2%B7%20MongoDB%20(in%20progress)-336791">
  <a href="https://github.com/xuckless/anole/stargazers"><img alt="GitHub stars" src="https://img.shields.io/github/stars/xuckless/anole?style=flat&logo=github"></a>
</p>

<p align="center">
  <a href="docs/getting-started.md">Getting started</a> ·
  <a href="docs/from-fiber.md">From Fiber</a> ·
  <a href="docs/">Docs</a> ·
  <a href="CHANGELOG.md">Changelog</a>
</p>

TLS, auth and observability are built in, on one listener and one router.

An anole is a small lizard that changes colour to fit wherever it lands, and
that's the idea: one server core that speaks whatever protocol the client
showed up with. (Zig's mascot is a lizard too.)

Anole doesn't reinvent the hard parts. It stands on libraries that have
already survived the internet:
- [zio](https://github.com/lalinsky/zio) for async I/O;
- [dusty](https://github.com/lalinsky/dusty) for HTTP, adapted into Anole as its HTTP core;
- nghttp2 for HTTP/2;
- BoringSSL for TLS;
- ngtcp2 and nghttp3 for HTTP/3.

Anole wires them together, tunes them hard, and hands you a Fiber-sized API.
Zig compiles every C dependency, so you install nothing but Zig. Each one
sits behind a build flag, and whatever you switch off is never downloaded or
compiled.

## Hello, World

```zig
const std = @import("std");
const anole = @import("anole");

fn hello(_: *anole.Request, res: *anole.Response) !void {
    res.body = "Hello, World!";
}

pub fn main(init: std.process.Init) !void {
    var app = try anole.App.init(init.gpa, .{});
    defer app.deinit();
    app.get("/", hello);
    try app.listen(":3000"); // HTTP/1.1 and HTTP/2; Ctrl-C drains and stops
}
```

That's the whole server. To try it:

1. In a project made with `zig init`, run
   `zig fetch --save git+https://github.com/xuckless/anole#<tag or commit>`.
2. Make `build.zig` one call:
   `@import("anole").addApp(b, .{ .name = "api", .root_source_file = b.path("src/main.zig") })`.
3. `zig build run`, then `curl localhost:3000/`.

The rest is one line each:

```zig
app.ws("/echo", echo);                                    // WebSockets (HTTP/1.1, /2 and /3)
app.grpc(pb.Greeter, .{ .SayHello = sayHello });          // gRPC, gRPC-Web, Connect, JSON transcoding
app.webtransport("/wt", session);                         // WebTransport
try app.staticDir("/", "public", .{});                    // static files, ranges, ETags
app.metrics(.{}); app.health(.{}); app.tracing(.{});      // Prometheus, health checks, OpenTelemetry
try app.listenTls(":443", .fromFiles("cert.pem", "key.pem")); // HTTPS + HTTP/2 + HTTP/3
```

Handlers make async calls through `req.io`: outbound HTTP, files, timers,
anything on `std.Io`. A call that waits suspends that one request, never the
core it runs on. When you want every knob, `anole.Server(App)` takes each
listener and option explicitly ([docs/server.md](docs/server.md)).

Where to go next:
- [docs/getting-started.md](docs/getting-started.md) walks from `zig init`
  to a JSON API, WebSockets, TLS, gRPC and a deployment.
- [docs/from-fiber.md](docs/from-fiber.md) puts Fiber's API next to
  Anole's, for Go developers.
- `zig build run-rest` runs a JSON CRUD API with API-key auth.

## How fast?

Measured on one Linux box (Intel i7-14700F, Fedora 44) against the stacks
people actually deploy. Each server runs in its own container, pinned to
dedicated P-cores, with idle siblings and a memory cap. Load comes from wrk,
h2load and gcannon on other cores. Each server is set up the way its own docs
say to, under the same rules for everyone. Server and load generator share the
box and talk over loopback, so read the comparisons, not the absolute numbers.
The harness, every server's code and the raw results are in `bench/` on the
[`bench/suite`](https://github.com/xuckless/anole/tree/bench/suite/bench) branch.
The tables mix runs, each from the newest result for that row: Anole's HTTP/2,
HTTP/3, TLS, WebSocket and WebTransport numbers are from 2026-10-19 (`nowait`)
and 2026-10-21 (`backstop`), Bun's from 2026-10-19 (`bun`), and the other
servers' from 2026-10-19 (`quick`, `h3`, `wspipe`). Anole's plain HTTP/1.1
row has not been re-run since `quick`. One 15 s run per case after a 5 s
warm-up.

**One CPU, `/plaintext`, requests per second:**

| Protocol | Anole | Bun | Fiber | Axum | Go net/http | Fastify | FastAPI | nginx (ceiling) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| HTTP/1.1 | **243.7k** | 215.5k | 237.5k | 223.5k | 145.3k | 123.3k | 23.2k | 257.9k |
| HTTP/1.1 + TLS | **209.7k** | 195.1k | 200.6k | 199.5k | 137.5k | 94.5k | 20.8k | 186.1k |
| HTTP/2 + TLS | **685.0k** | 544.3k | – | 259.4k | 65.2k | 64.9k | – | 222.3k |
| HTTP/2 cleartext | **722.5k** | 563.6k | – | 276.0k | 65.0k | 69.0k | 5.7k | – |
| HTTP/3 | 328.3k | **394.9k** | – | 112.6k | 84.0k | – | 2.6k | 437.3k |

**Four CPUs:**

| Protocol | Anole | Bun | Fiber | Axum | nginx |
| --- | ---: | ---: | ---: | ---: | ---: |
| HTTP/1.1 | **618.0k** | 545.0k | 477.3k | 457.3k | 609.5k |
| HTTP/1.1 + TLS | **531.9k** | 475.8k | 426.2k | 406.6k | 444.5k |
| HTTP/2 + TLS | **1,899.6k** | 1,501.6k | – | 561.0k | 644.7k |
| HTTP/2 cleartext | **2,023.8k** | 1,581.8k | – | 599.3k | – |
| HTTP/3 | **1,064.7k** | 1,054.9k | – | 273.7k | 1,267.5k |

What we read in these numbers:

- **Anole leads every app framework on HTTP/1.1 and HTTP/2, on one core and
  on four.** HTTP/2 is 1.3× Bun and 2.6–3.4× Axum. The servers ahead of it
  are nginx on cleartext HTTP/1.1 on one core and on HTTP/3, and nginx is
  serving a fixed string from its config. It's the ceiling, not a competitor.
- **HTTP/3 is the exception:** Bun is 20% ahead on one core (395k against
  328k) and the two are level on four. Closing that gap is the next
  performance item.
- **The tail stays short.** HTTP/1.1 p99 on four cores is 0.50 ms for Anole,
  0.85 ms for Bun, 1.06 ms for Axum and 3.87 ms for Fiber.
- **It stays small.** Anole used 12–77 MB here. nginx used 31–150 MB, Bun
  14–80 MB, and the Node stacks hundreds.
- **It got a lot faster since the first runs.** HTTP/2 cleartext went from 409k to
  722k on one core and from 954k to 2.02M on four (requests that arrive whole
  now run without a task of their own). HTTP/3 went from 157k to 328k and
  from 379k to 1.06M, mostly from batching packets per wake and per flush.
- **Not every stack has every protocol.** "–" means the framework has no
  idiomatic way to serve it. Fiber has no HTTP/2 or HTTP/3, and Go's numbers
  use net/http and quic-go.

**WebSockets, one CPU:**

| | Anole | Fiber | Go | Axum | Express | Fastify | FastAPI |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Echo, msgs/s (64 conns) | **281k** | 237k | 188k | 178k | 209k | 195k | 94k |
| Fan-out 1,000 × 1 kHz, lag p99 | **3.7 ms** | 1.37 s | 6.8 ms | 4.19 s | 4.0 ms | 3.8 ms | 5.4 ms |
| Fan-out 10,000 × 100 Hz, lag p99 | 44.0 ms | 14.7 s | 19.2 s | 32.5 s | 48.0 ms¹ | 44.0 ms¹ | 35.9 ms¹ |
| Trading bots (2,000), order p99 | **1.1 ms** | 1.0 s | 10.0 ms | 438 ms | 49.1 ms | 46.9 ms | 124 ms |
| Memory per idle socket | 31.5 KB | 20.6 KB | 27.8 KB | 137.6 KB | 10.2 KB | 14.7 KB | 34.6 KB |

¹ Not all subscribers connected: Express held 9,698 of 10,000, Fastify 8,938
and FastAPI 4,896. Anole held all 10,000.

Under fan-out pressure Anole keeps everyone current, while several stacks
quietly queue up seconds of backlog. Memory per idle socket fell from 54.5 KB
to 31.5 KB, still above Fiber, Go and the Node stacks; more trimming is in
progress.

**WebSocket echo with 16 messages in flight per connection** (HttpArena's
`echo-ws-pipeline` shape, gcannon, 5-byte text frames), echoed frames per
second. Anole and Bun are from 2026-10-21, with Anole on io_uring (epoll is
3.24M, 2.42M and 2.12M on one core), and the rest from 2026-10-19:

| Connections | Anole | Bun | Fiber | Axum | Go | Fastify |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 CPU, 512 | **3.68M** | 3.19M | 2.55M | 1.19M | 0.21M | 0.28M |
| 1 CPU, 4,096 | 2.49M | **2.65M** | 1.98M | 1.01M | 0.21M | 0.27M |
| 1 CPU, 16,384 | 2.16M | **2.58M** | 1.88M | 0.26M² | 0.22M | 0.22M |
| 4 CPUs, 512 | **9.70M** | 8.46M | 5.95M | 3.23M | 0.59M | 0.76M |
| 4 CPUs, 4,096 | 7.45M | **7.46M** | 5.37M | 2.84M | 0.58M | 0.74M |
| 4 CPUs, 16,384 | 5.19M | **7.17M** | 4.85M | 2.28M | 0.58M | 0.73M |

² Axum's server was killed for running out of memory.

Anole is ahead at 512 connections and about level with Bun at 4,096. At
16,384 connections Bun is ahead, 1.2× on one core and 1.4× on four, and it
uses 70–190 MB where Anole uses about 535 MB. That is the same per-connection
memory work as above.

**WebTransport (draft-02), one CPU:**

Anole serves WebTransport from the same HTTP/3 listener as everything else.
Its 16 KiB stream echo reaches 552 MB/s, ahead of Rust's wtransport
(471 MB/s) and Go's webtransport-go (299 MB/s), and 14–80× the Node and Python
libraries. Datagrams echo at 64k/s across 64 sessions with no loss.

**Still cooking:**
- **gRPC:** published once an error count we saw at four cores is explained.
- **The $12 server challenge:** a JWT-authenticated social feed on Postgres,
  scored by the most users held under SLOs. It runs on a 1-CPU / 2 GB box
  and again on 4 CPUs / 8 GB.
- **A TechEmpower entry,** for numbers nobody here produced.

## What's in the box

Everything below builds and passes its tests on macOS (arm64) and Linux
(x86_64), and cross-compiles for aarch64 Linux.

- **HTTP/1.1:** a fast server and router (dusty on zio) with:
  - path parameters, nested groups and middleware: request IDs, access log,
    compression, CORS, sessions;
  - static files with ranges, ETags and precompressed variants;
  - per-phase timeouts and body limits, keep-alive and pipelining;
  - no allocation per request on a warm connection.
- **HTTP/2 on nghttp2:** over TLS and cleartext, with streaming bodies,
  trailers and a two-phase GOAWAY drain. It passes all 147 h2spec cases in
  strict mode.
- **HTTP/3 on ngtcp2 and nghttp3:** with:
  - Retry, stateless reset, QUIC v2, ECN, resumption;
  - replay-safe opt-in 0-RTT and connection migration;
  - one UDP socket per core with connection-ID steering on Linux;
  - a client.

  It passes every QUIC interop runner case it takes, against both ngtcp2's
  and quic-go's clients.
- **TLS on BoringSSL:**
  - TLS 1.3 and 1.2, ALPN, mutual TLS (over HTTP/3 too), session tickets;
  - hot certificate reload on SIGHUP.
- **WebSockets:** over HTTP/1.1, HTTP/2 (RFC 8441) and HTTP/3 (RFC 9220),
  with permessage-deflate and a rooms helper for broadcast. It passes all
  517 Autobahn cases.
- **WebTransport (draft-02):** streams both ways, datagrams, close codes and
  drain, on the same router, plus a client. It's checked against aioquic and
  in the interop runner.
- **gRPC:**
  - server and client, all four call modes;
  - gRPC-Web, Buf's Connect protocol, JSON transcoding from
    `google.api.http`, and `grpc.health.v1`.

  It passes grpc-go's interop suite both ways. `zig build` runs protoc for
  you.
- **Auth:**
  - JWT and JWKS with pinned algorithms;
  - OIDC sign-in with Google and Apple presets;
  - sessions (memory, Redis or sealed cookies), CSRF, Argon2id, API keys,
    RBAC and rate limiting.
- **Observability:** Prometheus `/metrics`, OpenTelemetry traces, structured
  access logs, `/healthz` and `/readyz`.
- **Operations:**
  - graceful drain;
  - zero-downtime restart on SIGUSR2, where the new process inherits every
    socket, QUIC included;
  - systemd socket activation and `Type=notify`;
  - the PROXY protocol and `X-Forwarded-*`.
- **Clients:** HTTP/1.1, HTTP/2 and HTTP/3 clients, plus Redis/Valkey, all
  on the same TLS stack.
- **Databases (in development, milestone 15):** built-in connectors, so a
  handler can query without a third-party driver and without blocking its
  core:
  - PostgreSQL, on a fork of pg.zig moved to `std.Io`, over the same
    BoringSSL stack;
  - SQLite, the amalgamation built by Zig, with one writer thread per
    database and reads on the blocking pool;
  - MongoDB, Anole's own OP_MSG client with a Zig BSON codec;
  - one shared shape: a pool per core, calls take the request first
    (`app.db.all(Post, req, sql, .{args})`), request deadlines cancel
    queries, and rows land in the request's arena;
  - opt-in request coalescing and short-lived result caches, off unless
    asked for;
  - behind `-Dpostgres`, `-Dsqlite` and `-Dmongodb`.

**Status: pre-alpha, heading for 0.1.0** ([CHANGELOG.md](CHANGELOG.md)).
Nothing is stable before 1.0. The Postgres, SQLite and MongoDB connectors
are being built now, then Python (ASGI) and JavaScript bindings.

## Requirements

- Zig **0.17.x** (tested on 0.17.0). The build stops with a clear error on
  any other minor version and on 0.17 dev builds.
- macOS or Linux. Windows is not supported.

## Build and test

```sh
zig build test          # unit tests plus smoke tests for the enabled features
zig build test-flags    # the tests for every preset and edge flag combination
zig build run-hello     # Hello, World! on http://localhost:3000
zig build run-rest      # examples/rest, a JSON API on port 3000
zig build run-full      # every listener: 8080 (HTTP/1.1, h2c), 8443 (HTTPS, HTTP/3)
zig build run-io        # handlers waiting on timers, files and outbound requests (port 8081)
```

`examples/full` speaks HTTP/1.1 and HTTP/2 on both ports and HTTP/3 on 8443
over UDP:
- `curl --http2-prior-knowledge localhost:8080/` and `curl -k --http2 https://localhost:8443/` both return `hello`;
- `curl localhost:8080/users/42` returns `user 42`;
- `POST /echo` streams the request body back.

Its certificate is self-signed, generated at startup and only kept in
memory, so `-k` it. Pass other ports with `zig build run-full -- 9000 9443`.

## Build flags

`-Dprofile` sets everything at once, and individual flags override it.

| Flag | minimal | web | full (default) | Adds |
| --- | --- | --- | --- | --- |
| `-Dtls=boringssl\|none` | none | boringssl | boringssl | BoringSSL |
| `-Dhttp2=bool` | false | true | true | nghttp2 |
| `-Dhttp3=bool` | false | false | true | ngtcp2, nghttp3, WebTransport |
| `-Dcompression=bool` | false | true | true | zlib-ng, zstd |
| `-Dgrpc=bool` | false | false | true | gRPC, zig-protobuf (and protoc for codegen) |
| `-Dwebsocket=bool` | false | true | true | WebSocket |
| `-Dauth=bool` | false | true | true | JWT, OIDC, CSRF, passwords, API keys, RBAC |
| `-Djson=bool` | false | true | true | yyjson |
| `-Dredis=bool` | false | false | true | hiredis (Redis/Valkey client, stores) |

Constraints:
- gRPC needs HTTP/2, so `-Dhttp2=false` turns gRPC off. Asking for both
  `-Dhttp2=false` and `-Dgrpc=true` is an error.
- HTTP/3 needs TLS, so `-Dtls=none` turns HTTP/3 off. Asking for both
  `-Dtls=none` and `-Dhttp3=true` is an error.

In code, the chosen flags are `anole.features`. A minimal build of
Hello, World is about 1.1 MB; everything on is about 5 MB.

## Using Anole as a dependency

```sh
zig fetch --save git+https://github.com/xuckless/anole#<tag or commit>
```

A complete `build.zig`, with gRPC code generated from a `.proto` as part of
`zig build` (no extra step, nothing to commit):

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = @import("anole").addApp(b, .{
        .name = "api",
        .root_source_file = b.path("src/main.zig"),
        .protos = &.{.{ .name = "greeter_pb", .file = b.path("proto/greeter.proto") }}, // optional
    });
}
```

`addApp` also takes `target`, `optimize` and `.profile = .web`. By hand:

```zig
const anole = b.dependency("anole", .{ .target = target, .optimize = optimize, .profile = .web });
exe.root_module.addImport("anole", anole.module("anole"));
```

Use the `git+https` form, because Zig 0.17.0's `zig fetch` mishandles
tarball URLs. `addProtoModule` and `addProtoGen` cover other protobuf setups
([docs/grpc.md](docs/grpc.md)). `tests/consumer` is a complete small project
set up this way, and CI builds it from an empty cache on every push.

## Documentation

- [docs/getting-started.md](docs/getting-started.md): from `zig init` to a
  running API, then WebSockets, static files, TLS, gRPC and deploying.
- [docs/from-fiber.md](docs/from-fiber.md): Fiber's API next to Anole's.
- [docs/server.md](docs/server.md): listeners, TLS, HTTP/2, HTTP/3, draining,
  restarts, socket activation, proxies.
- [docs/routing.md](docs/routing.md): routes, middleware, requests and
  responses, errors, static files, compression, timeouts and limits.
- [docs/websocket.md](docs/websocket.md),
  [docs/webtransport.md](docs/webtransport.md), [docs/grpc.md](docs/grpc.md),
  [docs/clients.md](docs/clients.md), [docs/auth.md](docs/auth.md),
  [docs/observability.md](docs/observability.md).
- Examples, each runnable with `zig build run-<name>`: `hello`, `rest`,
  `websocket`, `grpc`, `auth`, `clients`, `observe`, `io`, and `full`
  (every listener and option spelled out).
- [CHANGELOG.md](CHANGELOG.md) and [MAINTAINING.md](MAINTAINING.md): pins,
  forks, the Zig version policy, releases.

## Licence

MIT; see [LICENSE](LICENSE). Anole fetches and links components under MIT,
Apache-2.0, Zlib and BSD licences, all listed in
[THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES). It owes a lot to their authors.
