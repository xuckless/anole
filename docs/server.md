# The server

`anole.Server(Ctx)` is the entry point. One `init` call creates the async
runtime, the listeners (HTTP/1.1 with cleartext HTTP/2, HTTPS with HTTP/2,
optionally HTTP/3) and the router. `run()` serves until the process is told
to stop, then drains. Routes, middleware, requests and responses are in
[routing.md](routing.md).

## A complete program

```zig
const std = @import("std");
const anole = @import("anole");

pub const zio_options = anole.zio_options;
pub const std_options: std.Options = .{ .logFn = anole.logFn };

fn hello(_: *anole.Request, res: *anole.Response) !void {
    try res.print(.text, "hello", .{});
}

pub fn main(init: std.process.Init) !void {
    var app = try anole.Server(void).init(init.gpa, .{
        .http = .{ .port = 8080 },
        .https = .{ .port = 8443, .cert = .dev_self_signed },
    }, {});
    defer app.deinit();

    app.use(anole.middleware.RequestId.init(.{}));
    app.get("/", hello);
    try app.run();
}
```

Add middleware with `use` before any route: the router panics on a `use`
after a route. Call `run` from the thread that called `init`. Create one
`Server` per process; two alive at once on one thread trip an assertion in
zio when the first is freed.

## Root declarations

`zio_options` is required in your executable's root file:

```zig
pub const zio_options = anole.zio_options; // .{ .scheduling = .pinned }
```

zio reads it at compile time, as std reads `std_options`. Pinned scheduling
runs many executors (OS threads), and a task never leaves the executor that
started it. Anole relies on that: a connection and every task it spawns stay
on one thread, so nghttp2 sessions, BoringSSL's per-thread error queue and
zig-protobuf's thread-locals need no locking. Without the declaration zio
falls back to work stealing, where tasks move between threads, and nothing
checks this at compile time. To set other zio options, keep `.pinned`:

```zig
pub const zio_options: anole.zio.Options = .{ .scheduling = .pinned, .debug_cancel = true };
```

`std_options` is optional. `anole.logFn` renames the scopes of the libraries
underneath (`dusty` becomes `anole`, `dusty_access` becomes `access`):

```zig
pub const std_options: std.Options = .{
    .logFn = anole.logFn,
    .log_scope_levels = &.{.{ .scope = .zio, .level = .info }}, // hide zio's startup lines
};
```

Do not set `std_options_debug_io = zio.debug_io`, as zio's own examples do.
std.debug unwinds stack traces through that `Io`, and Debug builds capture
traces inside allocator and task-pool locks, so a coroutine can be suspended
while holding one: a livelock or a recursive-lock abort.

## Options

`init(gpa, options, ctx)` takes an `anole.ServerOptions`:

| Field | Default | Meaning |
| --- | --- | --- |
| `http` | `.{}`, 127.0.0.1:8080 | The cleartext listener; `null` for none. |
| `https` | `null` | The TLS listener. Needs `-Dtls=boringssl`. |
| `http3` | `null` | HTTP/3 over QUIC. Needs `-Dhttp3` and `https`. |
| `http2` | 250 streams | HTTP/2 settings, for h2c and h2 over TLS. |
| `executors` | `.auto` | One per CPU (cgroup-aware), or `.exact(n)`. |
| `process` | `null` | `init.minimal` enables socket activation and SIGUSR2 restarts. |
| `restart_timeout_ms` | 10 000 | How long a restart waits for the new process. |
| `blocking` | `null` | A blocking pool for CPU-heavy or blocking calls; see [Blocking work](#blocking-work). |
| `server` | `.{}` | The rest of dusty's `ServerConfig`: timeouts, limits, proxies. |

`http` is on by default, so a TLS-only server must say `.http = null`. Both
listeners bind to `127.0.0.1` unless given an `address`; use `"0.0.0.0"` or
`"::"` to accept connections from other machines.

```zig
var app = try anole.Server(void).init(init.gpa, .{
    .http = .{ .address = "0.0.0.0", .port = 80 },
    .https = .{
        .address = "0.0.0.0",
        .port = 443,
        .cert = .{ .files = .{
            .cert_path = "/etc/anole/fullchain.pem",
            .key_path = "/etc/anole/privkey.pem",
        } },
    },
    .http3 = .{}, // UDP 443, advertised with Alt-Svc
    .server = .{
        .timeout = .{ .request = .fromSeconds(60), .shutdown = .fromSeconds(10) },
        .request = .{ .max_body_size = 8 << 20 },
    },
}, {});
```

`http` has `address`, `port`, `h2c` and `proxy_protocol`. `https` has
`address`, `port`, `cert`, `alpn_protocols`, `client_auth` and
`proxy_protocol`. `cert` is one of:

- `.{ .pem = .{ .cert = ..., .key = ... } }`: PEM text in memory, copied by
  `init`, for keys from a secret store or the environment.
- `.{ .files = .{ .cert_path = ..., .key_path = ... } }`: PEM files (chain
  leaf first), read when the server starts, relative to the working directory.
- `.dev_self_signed`: a fresh P-256 key and certificate for `localhost`,
  `127.0.0.1` and `::1`, held only in memory. For development; clients need
  `curl -k`.

`server` goes to dusty as is, except that `listeners` and `http2` are
replaced by the fields above. Its timeouts and limits are covered in
[routing.md](routing.md#timeouts-and-limits); `trusted_proxy_hops` below;
`max_connections` (10 000) caps open connections.

## App state and handlers

`Server(void)` handlers take the request and the response.
`Server(Ctx)` handlers also take a pointer to your state, which `init` takes
too and which must outlive the server:

```zig
const App = struct {
    greeting: []const u8,
    hits: std.atomic.Value(u64) = .init(0),
};

fn greet(app: *App, req: *anole.Request, res: *anole.Response) !void {
    _ = app.hits.fetchAdd(1, .monotonic);
    try res.print(.text, "{s}, {s}", .{ app.greeting, req.params.get("name").? });
}

pub fn main(init: std.process.Init) !void {
    var state: App = .{ .greeting = "hello" };
    var app = try anole.Server(App).init(init.gpa, .{ .http = .{ .port = 8080 } }, &state);
    defer app.deinit();
    app.get("/hello/:name", greet);
    try app.run();
}
```

Handlers run at the same time on every executor, so shared state needs
atomics or a lock. Prefer `std.Io.Mutex` or `std.Io.RwLock` to
`std.Thread.Mutex`: a task waiting on them yields to other requests instead
of blocking its executor's thread. `Ctx` can also declare `notFound`,
`methodNotAllowed`, `uncaughtError` and `dispatch`; see
[routing.md](routing.md#error-handling).

## Blocking work

A handler that computes for a long time, or calls a C library that blocks,
holds its executor's thread, and every other connection on that executor
waits. Password hashing is the usual case: an Argon2id hash takes about
150 ms in a Debug build, and less in ReleaseFast.

Set `blocking` and such work runs beside the executors instead:

```zig
var app = try anole.Server(App).init(gpa, .{ .blocking = .{} }, &state); // .{ .threads = 4 }

fn report(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const total = try anole.blocking.run(req.io, crunch, .{ app.data });
    try res.print(.text, "{d}\n", .{total});
}
```

`anole.blocking.run(io, func, args)` calls `func(args...)` on a pool thread.
The request's task waits without holding its executor, which goes on
serving. The result is `func`'s, with `error.Canceled` added. The pool
lets `threads` jobs run at once, by default half the CPUs and at least 2;
more wait their turn. Without a pool, `run` calls `func` directly, so
library code can use it whether or not the application set one up.
`anole.auth.password` does.

The threads are zio's own thread pool, the one it runs file I/O and DNS
on, so the pool adds no threads of its own and the cap keeps heavy jobs
from crowding out that work. A job runs outside any coroutine, so it may
block. A `std.Io` call in it blocks only its own thread.

A job is never interrupted. When a request is canceled while its job runs,
for example because the client reset its HTTP/2 stream, the task still
waits for the job to finish, because the job may use the task's memory,
and then gets `error.Canceled`. `deinit` waits for running jobs too.

With a zio runtime of your own, start a pool on it with
`var pool: anole.blocking.Pool = undefined; try pool.init(rt, .{});` and
`defer pool.deinit();`.

## The server value

| Member | What it does |
| --- | --- |
| `use(middleware)` | Adds a global middleware (copied), before any route. |
| `get`, `head`, `post`, `put`, `patch`, `delete`, `options`, `any` | Register a route. |
| `group(prefix, middlewares)` | A route group. |
| `router`, `server` | dusty's router (for `static`, `embedded`, `query`) and server. |
| `io()` | The runtime's `std.Io`, for work beside the server. |
| `run()` | Serves until a signal or `stop`, then drains. |
| `stop()` | Ends `run` as a signal would; safe from any task or thread of the runtime. |
| `waitReady()` | Waits until the listeners are bound. |
| `addresses()` | Each listener's bound address (`http` first), once serving. |
| `http3Address()` | The HTTP/3 UDP address, or null. |
| `deinit()` | Frees everything, the runtime included. |

A listener given port 0 gets a free port, which `addresses()` reports after
`waitReady()`. A test can start a task with `app.io().concurrent`, wait for
the server there, send its requests, call `app.stop()`, and let `run` return.

## What `run` owns

`init` creates the zio runtime, one pinned executor per CPU. On Linux each
executor runs its own accept loop on its own `SO_REUSEPORT` socket, so the
kernel spreads new connections over the cores and a connection never leaves
the executor that accepted it. On macOS the accept loops share one socket.

`run` handles SIGINT and SIGTERM (and SIGUSR2 when `process` is set). The
first of these, or `stop()`, starts a graceful drain:

1. The listeners stop accepting.
2. HTTP/1.1 connections finish the request in flight.
3. Every HTTP/2 connection gets a two-phase GOAWAY: a notice with a PING,
   then the final GOAWAY on the PING's answer or after one second. Open
   streams finish.
4. HTTP/3 connections get a GOAWAY and finish their open requests.
5. `run` returns once every connection is closed, or when
   `server.timeout.shutdown` (30 s) runs out.

With `timeout.shutdown = null` the drain waits however long it takes. A
WebSocket or event stream never closes on its own, so it then holds the
drain open forever.

## HTTP/2

HTTP/2 (`-Dhttp2`, on in `web` and `full`) reaches the same router and
handlers as HTTP/1.1.

- Over TLS, clients choose it through ALPN (`h2`, then `http/1.1`).
- On the cleartext port, a client that opens with the HTTP/2 preface gets
  HTTP/2 ("prior knowledge", `curl --http2-prior-knowledge`); others get
  HTTP/1.1 on the same port. `.http = .{ .h2c = false }` turns this off. The
  old `Upgrade: h2c` handshake is not supported.

`Options.http2` sets `max_concurrent_streams` (250), `stream_window`
(64 KiB, also each stream's body buffer), `connection_window` (1 MiB),
`max_header_list_size` (64 KiB), `stream_reset_burst` and
`stream_reset_rate` (rapid-reset protection), `max_continuations` (8) and
`enable_connect_protocol` (on, for RFC 8441 WebSockets).

## HTTP/3

HTTP/3 needs `-Dhttp3` (on in `full`) and an `https` listener, whose
certificate it shares. With `.http3 = .{}`, QUIC listens on UDP at the HTTPS
address and port, and every response that did not come over HTTP/3 carries
`Alt-Svc: h3=":443"; ma=86400`, so browsers switch to it. Handlers see
`req.version_major == 3`.

`http3` fields: `address` and `port` (`https`'s when null), `alt_svc`
(true), `max_streams_bidi` (100 concurrent requests per connection),
`idle_timeout_ms` (30 000), and `validate_address` (false). With
`validate_address`, every new client must prove its address with a Retry
first, which costs a round trip and resists floods from spoofed sources.
`hq_interop_root` is for the QUIC interop runner only.

Supported: QUIC v1 and v2, Retry, stateless reset, ECN, NAT rebinding, key
update, GSO/GRO on Linux and a GOAWAY drain. Not yet:

- 0-RTT (early data);
- connection migration to an address the client chooses (no preferred
  address is advertised);
- WebTransport, and gRPC over HTTP/3;
- mutual TLS: the QUIC endpoint does not ask for client certificates yet,
  so `init` refuses `https.client_auth` together with `http3`
  (`error.Http3WithClientAuth`) rather than let HTTP/3 bypass it;
- SIGUSR2 restarts: the UDP socket is not handed over, the new process fails
  to bind it, and the old one carries on.

The endpoint runs on one executor for now, so HTTP/3 uses one core.

## TLS

TLS is BoringSSL, built into your binary (`-Dtls=boringssl`, the default
outside `minimal`).

- TLS 1.2 and 1.3; nothing older.
- ALPN: the server picks by its own order (`alpn_protocols`). A client whose
  offer shares nothing with it gets no ALPN answer and HTTP/1.1, rather than
  a refusal.
- Resumption uses stateless session tickets only, with no server-side cache.
  The ticket keys live in the process, so tickets do not survive a restart or
  carry over to another machine.
- A handshake has the same deadline as a request (`timeout.request`). Failed
  handshakes are logged at `info`, since any client can cause them.
- No hot certificate reload; a SIGUSR2 restart picks up new files.

Mutual TLS verifies client certificates against the CAs you give:

```zig
.https = .{
    .port = 8443,
    .cert = .{ .pem = .{ .cert = cert_pem, .key = key_pem } },
    .client_auth = .{
        .ca = .{ .file = .{ .path = "clients-ca.pem" } }, // or .dir, .system
        .mode = .require, // .request also accepts a client that sends none
    },
},
```

A client without a valid certificate fails the handshake. Handlers cannot
read the client certificate yet, so mTLS only gates access.

## Zero-downtime restart and socket activation

Pass the process to enable both: `.process = init.minimal`.

**Socket activation.** When `LISTEN_PID` is this process, Anole serves the
`LISTEN_FDS` sockets from fd 3 on, as systemd passes them. It matches them by
`LISTEN_FDNAMES` (`http`, `https`), or by position (`http` first) when they
have no names. A listener with no inherited socket opens its own.

```ini
# anole.socket
[Socket]
ListenStream=0.0.0.0:80
FileDescriptorName=http

[Install]
WantedBy=sockets.target
```

**Restart on SIGUSR2.** `kill -USR2 <pid>` starts the binary at the same
path with the same arguments and environment. The new process inherits the
listening sockets (in the `LISTEN_FDS` format) and reports through a pipe once
it serves; only then does the old one stop accepting and drain. Clients never
see a closed port. If the new process does not report within
`restart_timeout_ms`, the old one kills it and keeps serving. To deploy,
replace the binary on disk and send SIGUSR2.

Limits:

- Each listener is one socket in this mode, so Linux loses the per-core
  `SO_REUSEPORT` sockets.
- HTTP/3 breaks the restart (see above).
- The restart changes the main PID without telling systemd, so with the
  default `KillMode` systemd stops the new process when the old one exits.
  Under systemd, use `systemctl restart` with a socket unit: the socket stays
  open and connections queue while the service restarts.

## Behind a proxy

Anole runs on its own, but a load balancer or proxy can sit in front. Two
mechanisms carry the client address.

**The PROXY protocol** (v1 and v2, as HAProxy, nginx, AWS NLB and Envoy send
it), per listener: `.http = .{ .port = 8080, .proxy_protocol = true }`. Each
connection must open with a valid header, read before TLS and within
`timeout.read_header`, or it is closed. The header's address becomes
`req.remote_address`, and v2's SSL field sets `req.secure`.

**`X-Forwarded-*`**, with `.server = .{ .trusted_proxy_hops = 1 }`. With `n`
hops, `req.remote_address` is the `n`-th address from the right of
`X-Forwarded-For` (with port 0), the nearest proxy's `X-Forwarded-Proto` sets
`req.secure`, and its `X-Forwarded-Host` is what `req.host()` returns. The
`Forwarded` header (RFC 7239) is not read.

Enable either only on a listener that nothing but the proxy can reach;
otherwise clients write the header themselves and choose the address your
handlers see. The two combine: the PROXY header sets the peer, and
`trusted_proxy_hops` applies on top.

## Build flags

Each bundled library sits behind a flag. `-Dprofile=minimal|web|full`
(default `full`) sets them all, and single flags such as `-Dtls=none` or
`-Dhttp3=false` override it; the README has the
[table](../README.md#build-flags). Choose the profile where you add the
dependency:

```zig
const anole = b.dependency("anole", .{ .target = target, .optimize = optimize, .profile = .web });
```

`anole.features` holds the result at compile time. Asking `init` for a
listener that is not built fails with `error.TlsNotBuilt` or
`error.Http3NotBuilt`, so guard optional ones:

```zig
.https = if (anole.features.tls != .none) .{ .port = 8443, .cert = .dev_self_signed } else null,
```

## Full control with `anole.http`

`app.router` and `app.server` are dusty's router and server, and
`anole.http` is the dusty module, with TLS already on BoringSSL
(`anole.http.dusty_module` has whatever it does not re-export). You can skip
`Server` and drive dusty yourself:

```zig
const rt = try anole.zio.Runtime.init(init.gpa, .{ .executors = .auto });
defer rt.deinit();

var server = anole.http.Server(void).init(init.gpa, rt.io(), .{
    .listeners = &.{.{
        .address = .{ .ip = try .parse("127.0.0.1", 8080) },
        .http2_prior_knowledge = true,
    }},
}, {});
defer server.deinit();
server.router.get("/", hello);
try server.run();
```

You then own what `Server` did: signals, the drain, ALPN lists, per-core
sockets (`Listener.socket_per_acceptor`), HTTP/3 and restarts.
