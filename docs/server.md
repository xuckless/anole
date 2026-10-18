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
after a route. Call `run` from the thread that called `init`. One `Server`
can be alive on a thread at a time: its runtime makes the thread one of its
executors, so `init` on a thread that already has one fails with
`error.ServerAlreadyOnThread`. Start a second server on a thread of its own,
or after the first's `deinit`.

## Root declarations

`zio_options` in your executable's root file sets zio's configuration:

```zig
pub const zio_options = anole.zio_options; // .{ .scheduling = .pinned }
```

zio reads it at compile time, as std reads `std_options`. Pinned scheduling
runs many executors (OS threads), and a task never leaves the executor that
started it. Anole relies on that: a connection and every task it spawns stay
on one thread, so nghttp2 sessions, BoringSSL's per-thread error queue and
zig-protobuf's thread-locals need no locking. Anole builds zio with pinned
scheduling as the default, so the declaration can be left out; a root file
that declares work stealing fails to compile, with a message that says what
to write instead. To set other zio options, keep `.pinned`:

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
| `http` | `null` | The cleartext listener. With neither it nor `https` set, 127.0.0.1:8080. |
| `https` | `null` | The TLS listener. Needs `-Dtls=boringssl`. |
| `http3` | `null` | HTTP/3 over QUIC. Needs `-Dhttp3` and `https`. |
| `http2` | 250 streams | HTTP/2 settings, for h2c and h2 over TLS. |
| `executors` | `.auto` | One per CPU (cgroup-aware), or `.exact(n)`. |
| `process` | `null` | `init.minimal` enables socket activation, SIGUSR2 restarts and `sd_notify`. |
| `restart_timeout_ms` | 10 000 | How long a restart waits for the new process. |
| `blocking` | `null` | A blocking pool for CPU-heavy or blocking calls; see [Blocking work](#blocking-work). |
| `server` | `.{}` | The rest of dusty's `ServerConfig`: timeouts, limits, proxies. |

You get the listeners you name. `.{}` alone serves cleartext HTTP on
127.0.0.1:8080, `.{ .https = ... }` serves HTTPS only, and a server that
wants both names both. Both listeners bind to `127.0.0.1` unless given an
`address`; use `"0.0.0.0"` or `"::"` to accept connections from other
machines.

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
  leaf first), read by `init` and by every reload, relative to the working
  directory.
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
| `use(middleware)` | Adds a global middleware (copied, owned by the server), before any route. |
| `get`, `head`, `post`, `put`, `patch`, `delete`, `options`, `query`, `any` | Register a route (`query` is the HTTP QUERY method). |
| `static(prefix, dir, options)`, `embedded(path, data, options)` | Serve a directory, or one file compiled in. |
| `group(prefix, .{ middleware, ... })` | A route group; see [routing.md](routing.md#groups). |
| `middleware(value)` | A server-owned copy of a middleware, as a handle to share between groups. |
| `reloadCertificates()`, `setCertificate(cert)` | Swap the TLS certificate while serving; see [TLS](#tls). |
| `router`, `server` | dusty's router and server. |
| `io()` | The runtime's `std.Io`, for work beside the server. |
| `run()` | Serves until a signal or `stop`, then drains. |
| `stop()` | Ends `run` as a signal would; safe from any task or thread of the runtime. |
| `waitReady()` | Waits until the listeners are bound. |
| `addresses()` | Each listener's bound address (`http` first), once serving. |
| `http3Address()` | The HTTP/3 UDP address, or null. |
| `deinit()` | Frees everything, the runtime included, and calls `deinit` on the middleware it copied. |

A listener given port 0 gets a free port, which `addresses()` reports after
`waitReady()`. A test can start a task with `app.io().concurrent`, wait for
the server there, send its requests, call `app.stop()`, and let `run` return.

## What `run` owns

`init` creates the zio runtime, one pinned executor per CPU. On Linux each
executor runs its own accept loop on its own `SO_REUSEPORT` socket, so the
kernel spreads new connections over the cores and a connection never leaves
the executor that accepted it. On macOS the accept loops share one socket.

`run` handles SIGINT and SIGTERM (and SIGUSR2 when `process` is set), and
SIGHUP when there is an `https` listener, which reloads its certificate
(see [TLS](#tls)) and goes on serving. The first of SIGINT, SIGTERM and
SIGUSR2, or `stop()`, starts a graceful drain:

1. The listeners stop accepting.
2. HTTP/1.1 connections finish the request in flight.
3. Every HTTP/2 connection gets a two-phase GOAWAY: a notice with a PING,
   then the final GOAWAY on the PING's answer or after one second. Open
   streams finish.
4. HTTP/3 connections get a GOAWAY and finish their open requests (except
   when a SIGUSR2 restart hands the socket over: then they close at once,
   see [below](#zero-downtime-restart-and-socket-activation)).
5. Open WebSockets get close 1001 (going away); each ends when its client
   answers (see [Shutdown](websocket.md#shutdown)).
6. `run` returns once every connection is closed, or when
   `server.timeout.shutdown` (30 s) runs out.

Handlers that run for long can learn of the drain: `req.drain` is an
`std.Io.Event` set when it starts, to wait on or test with `isSet()`. An
event stream that does neither never closes on its own, so with
`timeout.shutdown = null` it holds the drain open forever.

## HTTP/2

HTTP/2 (`-Dhttp2`, on in `web` and `full`) reaches the same router and
handlers as HTTP/1.1.

- Over TLS, clients choose it through ALPN (`h2`, then `http/1.1`).
- On the cleartext port, a client that opens with the HTTP/2 preface gets
  HTTP/2 ("prior knowledge", `curl --http2-prior-knowledge`); others get
  HTTP/1.1 on the same port. `.http = .{ .h2c = false }` turns this off. The
  old `Upgrade: h2c` handshake is not supported.
- When the client resets a stream (RST_STREAM) before its response is
  complete, or the connection is lost, the stream's handler is canceled: its
  next wait on `req.io` returns `error.Canceled`. A connection that ends
  cleanly may be a half-close, so handlers with their whole request keep
  running while the server checks with a PING every 500 ms; once a write
  fails, they are canceled too. `res.peerGone()` tells the same without a
  wait.

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
update, GSO/GRO on Linux, a GOAWAY drain, mutual TLS (the `https` listener's
`client_auth`, see [TLS](#tls)), certificate reloads (the same) and SIGUSR2
restarts (see
[below](#zero-downtime-restart-and-socket-activation)). Not yet:

- 0-RTT (early data);
- connection migration to an address the client chooses (no preferred
  address is advertised);
- WebTransport, and gRPC over HTTP/3.

The endpoint runs on one executor for now, so HTTP/3 uses one core.

## TLS

TLS is BoringSSL, built into your binary (`-Dtls=boringssl`, the default
outside `minimal`).

- TLS 1.2 and 1.3; nothing older.
- ALPN: the server picks by its own order (`alpn_protocols`). A client whose
  offer shares nothing with it gets no ALPN answer and HTTP/1.1, rather than
  a refusal.
- Resumption uses stateless session tickets only, with no server-side cache.
  The ticket keys live in the process and rotate every two days, as
  BoringSSL's own do; tickets survive a certificate reload, but not a
  restart, and do not carry over to another machine.
- A handshake has the same deadline as a request (`timeout.request`). Failed
  handshakes are logged at `info`, since any client can cause them.

**Certificate reload.** `app.reloadCertificates()` loads the certificate and
key again (from their files, for `.files`) and the `client_auth` CAs (from
theirs), and switches the HTTPS listener and HTTP/3 to them without a
restart. SIGHUP does the same while `run` serves, so a renewal hook can run
`kill -HUP <pid>` (or `systemctl kill -s HUP myapp`). With `process` set,
systemd hears `RELOADING=1` and then `READY=1`.

- New connections get the new certificate. Connections already open,
  handshakes in progress included, keep the one they started with, which is
  freed when the last of them closes.
- Session tickets issued before still resume: the ticket keys carry over.
- A reload that fails (a file missing, a key that does not match the
  certificate) returns the error, or logs it on SIGHUP, and the server goes
  on with the certificate it had.
- `app.setCertificate(cert)` switches to a different source the same way:
  new PEM from a secret store (`.{ .pem = ... }`), other files, or a fresh
  `.dev_self_signed`. Later reloads read that source.

Call either from a task of the server's runtime, such as a handler or a task
started with `app.io().concurrent`. One reload runs at a time.

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

The same CAs and mode apply to HTTP/3 when it is on. A client without a
valid certificate fails the handshake, on TCP and on QUIC alike; in
`.request` mode a client that sends none is served, but one that sends a
certificate that does not verify is still refused.

Handlers read the client's certificate with `req.peerCertificate()`: the
leaf certificate, DER-encoded and already verified, or `null` when the
connection is not this server's TLS, `client_auth` is off, or the client
sent none. It reads the same over HTTP/1.1, HTTP/2 and HTTP/3, and the slice
is valid for the request. Parse it with `std.crypto.Certificate` to get the
subject or a SAN:

```zig
fn whoami(req: *anole.http.Request, res: *anole.http.Response) !void {
    const der = req.peerCertificate() orelse return res.print(.text, "anonymous", .{});
    const cert: std.crypto.Certificate = .{ .buffer = der, .index = 0 };
    const parsed = try cert.parse();
    try res.print(.text, "CN={s}", .{parsed.commonName()});
}
```

Behind a TLS-terminating proxy there is no certificate here: the proxy saw
it, not Anole.

## Zero-downtime restart and socket activation

Pass the process to enable all of this: `.process = init.minimal`.

**Socket activation.** When `LISTEN_PID` is this process, Anole serves the
`LISTEN_FDS` sockets from fd 3 on, as systemd passes them. It matches them by
`LISTEN_FDNAMES` (`http`, `https`, and `h3` for HTTP/3's UDP socket), or by
position (`http`, `https`, `h3`) when they have no names. A listener with no
inherited socket opens its own, and one named `h3` must be a datagram socket.

**Restart on SIGUSR2.** `kill -USR2 <pid>` starts the binary at the same
path with the same arguments and environment. The new process inherits the
listening sockets, HTTP/3's included (in the `LISTEN_FDS` format), binds
nothing of its own, and reports through a pipe once it serves; only then does
the old one stop accepting and drain. TCP clients never see a closed port. If
the new process does not report within `restart_timeout_ms`, the old one kills
it and keeps serving. To deploy, replace the binary on disk and send SIGUSR2.

**HTTP/3 across a restart.** A UDP socket has no queue of new connections to
share: both processes would read the same socket, and each datagram reaches
only one of them. So once the new process serves, the old one sends every
QUIC connection a final GOAWAY and a CONNECTION_CLOSE (`H3_NO_ERROR`) and
stops reading, and every datagram from then on goes to the new process.
HTTP/3 requests in flight are cut, and their clients reconnect: browsers
retry idempotent requests, or fall back to TCP, which drains as usual.

The new process also gets the old one's key for stateless resets and address
validation tokens, through a pipe of its own. A packet for an old connection
that reaches the new process (in the moment both are reading, or from a client
that missed the CONNECTION_CLOSE) is answered with a stateless reset that the
client accepts, so it reconnects at once rather than at its idle timeout.

**systemd.** When `NOTIFY_SOCKET` is set, Anole speaks systemd's notification
protocol itself (no libsystemd): `READY=1` once the listeners are bound,
`RELOADING=1` when SIGUSR2 starts a new process, `MAINPID=<pid>` and
`READY=1` from the new process once it serves, so systemd follows the main
process to it, `READY=1` from the old one if the new one fails, and
`STOPPING=1` when a drain to exit starts. The process that hands over never
sends `STOPPING=1`, which would stop the service. A path starting with `@` is
in Linux's abstract namespace.

A service with every listener passed in, restarted with `systemctl reload`:

```ini
# anole.service
[Unit]
Description=My Anole service
Requires=anole-http.socket anole-https.socket anole-h3.socket
After=network.target

[Service]
# READY=1 says when it serves; a reload is RELOADING=1 ... READY=1.
Type=notify
# The new process sends MAINPID= and READY=1 before it is the main process.
NotifyAccess=all
ExecStart=/usr/local/bin/myapp
ExecReload=/bin/kill -USR2 $MAINPID
# Stop by SIGTERM and wait out the drain. After a reload the main process is
# not systemd's child, and systemd would follow its own SIGTERM with SIGKILL
# at once instead of waiting.
ExecStop=/bin/sh -c 'kill -TERM $MAINPID; while kill -0 $MAINPID 2>/dev/null; do sleep 0.1; done'
# The default: a stop signals every process of the service, an old one
# still draining after a restart too.
KillMode=control-group
# Longer than the drain (timeout.shutdown, 30 s).
TimeoutStopSec=40
Sockets=anole-http.socket anole-https.socket anole-h3.socket

[Install]
WantedBy=multi-user.target
```

One socket unit per name, since `FileDescriptorName` names every socket of
its unit:

```ini
# anole-http.socket
[Socket]
ListenStream=0.0.0.0:80
FileDescriptorName=http
Service=anole.service

# anole-https.socket
[Socket]
ListenStream=0.0.0.0:443
FileDescriptorName=https
Service=anole.service

# anole-h3.socket
[Socket]
ListenDatagram=0.0.0.0:443
FileDescriptorName=h3
Service=anole.service
```

Without the socket units, drop `Requires=` and `Sockets=`: Anole binds the
ports itself and still hands them over on a reload. On systemd 253 or later,
`Type=notify-reload` with `ReloadSignal=SIGUSR2` can replace `Type=notify` and
`ExecReload=`: systemd then sends the signal itself and waits for
`RELOADING=1` and `READY=1`. Both setups were checked on systemd 257: two
reloads in a row move `MainPID` to each new process, and a stop after them
drains.

Limits:

- Each listener is one socket in this mode, so Linux loses the per-core
  `SO_REUSEPORT` sockets.
- HTTP/3 requests in flight at a restart are cut (see above).
- `systemctl restart` stops and starts the service: with socket units the
  sockets stay open and TCP connections queue meanwhile, but in-flight work
  is drained, not handed over. Use `reload` for zero downtime.

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
