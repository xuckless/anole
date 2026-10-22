# The server

`anole.Server(Ctx)` is the entry point, and `anole.App` the same server
without state. `init` creates the async runtime and the router; `listen` or
`listenTls` (or the `http`/`https` options and `run`) set up the listeners
(HTTP/1.1 with cleartext HTTP/2, HTTPS with HTTP/2, HTTP/3) and serve until
the process is told to stop, then drain. Routes, middleware, requests and
responses are in [routing.md](routing.md).

## A complete program

```zig
const std = @import("std");
const anole = @import("anole");

fn hello(_: *anole.Request, res: *anole.Response) !void {
    try res.print(.text, "hello", .{});
}

pub fn main(init: std.process.Init) !void {
    var app = try anole.App.init(init.gpa, .{});
    defer app.deinit();

    app.use(anole.middleware.RequestId.init(.{}));
    app.get("/", hello);
    try app.listen(":8080"); // every interface; "127.0.0.1:8080" for this machine only
}
```

It logs one line per listener as it starts, with what each one speaks:

```
info(anole): listening on http://[::]:8080 (HTTP/1.1, HTTP/2 cleartext; IPv6 and IPv4)
```

A port that another process already listens on is an error,
`error.AddressInUse`, logged with the address, rather than a second server
quietly taking a share of the connections (see [Ports in use](#ports-in-use)).

The same with every listener spelled out in the options, which is how to
serve cleartext and TLS from one process:

```zig
var app = try anole.Server(void).init(init.gpa, .{
    .http = .{ .port = 8080 },
    .https = .{ .port = 8443, .cert = .dev_self_signed },
}, {});
defer app.deinit();
app.get("/", hello);
try app.run();
```

```
info(anole): listening on http://127.0.0.1:8080 (HTTP/1.1, HTTP/2 cleartext)
info(anole): listening on https://127.0.0.1:8443 (HTTP/2, HTTP/1.1)
```

Add middleware with `use` before any route: the router panics on a `use`
after a route. Call `run` from the thread that called `init`. One `Server`
can be alive on a thread at a time: its runtime makes the thread one of its
executors, so `init` on a thread that already has one fails with
`error.ServerAlreadyOnThread`. Start a second server on a thread of its own,
or after the first's `deinit`.

## Root declarations

Both are optional. `zio_options` in your executable's root file sets zio's
configuration:

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

Anole logs under its own scopes, `anole`, `access`, `anole_h2` and
`anole_h3`, through std's default log. A Debug build logs at `debug` too,
which includes a line from zio per worker thread started and stopped;
`anole.std_options` keeps those and Anole's own debug lines out, and leaves
info (the startup lines, the access log), warnings and errors:

```zig
pub const std_options = anole.std_options;
```

To set more, write your own and list the same scopes:

```zig
pub const std_options: std.Options = .{
    .log_level = .info,
    .log_scope_levels = &.{.{ .scope = .zio, .level = .warn }},
};
```

`anole.logFn` is still there for programs that set it; it only renames the
scopes older builds used.

Do not set `std_options_debug_io = zio.debug_io`, as zio's own examples do.
std.debug unwinds stack traces through that `Io`, and Debug builds capture
traces inside allocator and task-pool locks, so a coroutine can be suspended
while holding one: a livelock or a recursive-lock abort.

## listen and listenTls

`listen(address)` serves HTTP/1.1, and HTTP/2 for clients that open with its
preface (h2c), on `address` in Go's notation, until SIGINT, SIGTERM or
`stop`, as `run` does:

| Address | Binds |
| --- | --- |
| `":3000"` | every interface, IPv6 and IPv4 alike, as a container or a server needs (see [IPv6 and IPv4](#ipv6-and-ipv4)) |
| `"0.0.0.0:3000"` | every IPv4 interface only |
| `"127.0.0.1:3000"`, `"localhost:3000"` | this machine only |
| `"[::]:3000"` | every IPv6 interface (and IPv4 too where the system maps it) |
| `"[::1]:3000"` | IPv6 loopback |

`listenTls(address, cert)` serves HTTPS instead: HTTP/2 and HTTP/1.1 by
ALPN, and, when Anole is built with HTTP/3 (the default `full` profile),
HTTP/3 on the same port number over UDP, advertised to browsers with
`Alt-Svc`. A browser that cannot reach the UDP port stays on HTTP/2.
`listen_tls_http3 = false` in the options leaves HTTP/3 out, and `http3`
in the options tunes it.

```zig
try app.listenTls(":443", .fromFiles("fullchain.pem", "privkey.pem"));
try app.listenTls("localhost:8443", .dev_self_signed);
```

Both are for a server whose `init` options name no listener (neither `http`
nor `https`); otherwise they fail with `error.ListenersAlreadySet` and the
listeners from the options are served with `run`. To serve both cleartext
and TLS, name both in the options. A port in use, a certificate that does
not load or an address that does not parse is returned by `listen`, and by
`waitReady` to any task waiting for the server.

## Options

`init(gpa, options, ctx)` (`App.init(gpa, options)`) takes an
`anole.ServerOptions`:

| Field | Default | Meaning |
| --- | --- | --- |
| `http` | `null` | The cleartext listener. With neither it nor `https` set, 127.0.0.1:8080. |
| `https` | `null` | The TLS listener. Needs `-Dtls=boringssl`. |
| `http3` | `null` | HTTP/3 over QUIC. Needs `-Dhttp3` and `https` (or a listener in `listeners` with `http3 = true`, which it then tunes). |
| `listeners` | none | More listeners, each with its own address or unix socket, TLS and protocols; see [Several listeners](#several-listeners). |
| `http2` | 250 streams | HTTP/2 settings, for h2c and h2 over TLS. |
| `executors` | `.auto` | One per CPU (cgroup-aware), or `.exact(n)`. |
| `process` | `null` | `init.minimal` enables socket activation, SIGUSR2 restarts and `sd_notify`. |
| `restart_timeout_ms` | 10 000 | How long a restart waits for the new process. |
| `listen_tls_http3` | true | Whether `listenTls` adds HTTP/3 (when built in). |
| `raise_fd_limit` | true | Raise the soft open-file limit to the hard one at `init`; see [Many connections](#many-connections). |
| `blocking` | `null` | A blocking pool for CPU-heavy or blocking calls; see [Blocking work](#blocking-work). |
| `errors` | `.auto` | Error answers as text or `{"error":"..."}`: by the request's `Accept` (`.auto`), or always `.json` or `.text`. See [routing.md](routing.md#error-handling). |
| `error_handler` | `null` | A function that answers handler errors, with `anole.defaultError` to fall back on. |
| `server` | `.{}` | The rest of the HTTP core's `ServerConfig`: timeouts, limits, proxies. |

You get the listeners you name. `.{}` alone leaves them to `listen` or
`listenTls`, and `run` then serves cleartext HTTP on 127.0.0.1:8080;
`.{ .https = ... }` serves HTTPS only, and a server that wants both names
both. Listeners named in the options bind to `127.0.0.1` unless given an
`address`; use `""` (every interface, IPv6 and IPv4 alike, as
`listen(":3000")` binds), `"0.0.0.0"` (IPv4 only) or `"::"` to accept
connections from other machines.

```zig
var app = try anole.Server(void).init(init.gpa, .{
    .http = .{ .address = "", .port = 80 },
    .https = .{
        .address = "",
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

`http` has `address`, `port`, `h2c`, `proxy_protocol` and
`proxy_protocol_from`. `https` has `address`, `port`, `cert`,
`alpn_protocols`, `client_auth`, `proxy_protocol` and `proxy_protocol_from`. `cert` is one of:

- `.{ .pem = .{ .cert = ..., .key = ... } }`: PEM text in memory, copied by
  `init`, for keys from a secret store or the environment.
- `.{ .files = .{ .cert_path = ..., .key_path = ... } }`: PEM files (chain
  leaf first), read by `init` and by every reload, relative to the working
  directory. One that cannot be read is logged with its path
  (`cannot read the TLS certificate "cert.pem": FileNotFound`).
- `.dev_self_signed`: a fresh P-256 key and certificate for `localhost`,
  `127.0.0.1` and `::1`, held only in memory. For development; clients need
  `curl -k`.

`anole.Cert.fromFiles(cert_path, key_path)` and `.fromPem(cert, key)` build
the first two: `.cert = .fromFiles("cert.pem", "key.pem")`.

`server` goes to the HTTP core as is, except that `listeners` and `http2` are
replaced by the fields above. Its timeouts and limits are covered in
[routing.md](routing.md#timeouts-and-limits); `trusted_proxy_hops` below;
`max_connections` caps open connections, by default at what the open-file
limit allows (see [Many connections](#many-connections)).

## Several listeners

`http` and `https` cover one cleartext and one TLS port. For more, or for
ports that each speak something different, list them in `listeners`, beside
or instead of those two. Each has:

| Field | Default | Meaning |
| --- | --- | --- |
| `name` | made up | What the listener is called: `LISTEN_FDNAMES` for socket activation and restarts, and `req.listener.name` for handlers. Unique, at most 255 bytes, no `:`. Without one: `http-<port>`, `https-<port>` or `unix-<path>`. |
| `address`, `port` | `127.0.0.1`, 8080 | Where it listens. |
| `unix` | `null` | A unix domain socket at this path instead. |
| `tls` | `null` | `.{ .cert = ... }` for TLS, with optional `alpn_protocols` and `client_auth`. Listeners that name the same certificate (the same files, the same PEM) share one copy of it. |
| `http1` | true | HTTP/1.1 (and 1.0). |
| `http2` | true | HTTP/2: by ALPN over TLS, by prior knowledge (h2c) on cleartext. |
| `http3` | false | HTTP/3 on the same port number over UDP, with `Options.http3`'s settings. TLS only, one listener per server. |
| `proxy_protocol` | false | Every connection starts with a PROXY protocol header. |
| `proxy_protocol_from` | `&.{}` | With `proxy_protocol`: the peers allowed to send it, in CIDR notation; others are closed unread. Empty allows any peer. |

A TLS listener offers by ALPN the protocols it speaks: `h2` and `http/1.1`,
or one of them. One with `http2 = false` gives a client that offers `h2`
HTTP/1.1; one with `http1 = false` closes a connection whose ALPN did not
agree on `h2`, and a cleartext one with `http1 = false` closes a connection
that does not open with the HTTP/2 preface. `http`'s and `https`'s
listeners are named `http` and `https`, and come first in `addresses()`.

One process serving four ports, each with its own mix:

```zig
const cert: anole.Cert = .fromFiles("/certs/server.crt", "/certs/server.key");
var app = try anole.App.init(init.gpa, .{
    .listeners = &.{
        // HTTP/1.1, and h2c for clients that open with the preface (gRPC too).
        .{ .name = "http", .address = "", .port = 8080 },
        // TLS, HTTP/1.1 only: h2 is not offered.
        .{ .name = "https-h1", .address = "", .port = 8081, .tls = .{ .cert = cert }, .http2 = false },
        // h2c only.
        .{ .name = "h2c", .address = "", .port = 8082, .http1 = false },
        // TLS with HTTP/2 and HTTP/1.1, and HTTP/3 on UDP 8443.
        .{ .name = "https", .address = "", .port = 8443, .tls = .{ .cert = cert }, .http3 = true },
    },
    .process = init.minimal,
});
```

Every listener serves the same routes. To keep some of them to one listener,
such as metrics on an internal port, put them in a group behind
`anole.onlyOn(name)`, which answers 404 on the others:

```zig
var app = try anole.App.init(init.gpa, .{
    .https = .{ .address = "", .port = 443, .cert = cert },
    .listeners = &.{
        .{ .name = "admin", .port = 9090 }, // 127.0.0.1 only
        .{ .name = "proxy", .unix = "/run/myapp/http.sock" },
    },
});
const admin = app.group("/admin", .{anole.onlyOn("admin")});
admin.get("/stats", stats);
```

A unix socket file that a stopped server left behind is replaced when
nothing listens on it; one that something answers on is `AddressInUse`.
Anole never removes the file itself, since a restarted server may still be
serving it.

`listeners` alone, without `http` or `https`, is set up by `run` (or by
`listen` and `listenTls`, which add theirs in front), not by `init`; with
either of those, by `init`. Each listener gets the per-core accept sockets,
the address check, its startup line and its share of the drain, as `http`
and `https` do, and each TLS listener's certificate reloads with the rest.
HTTP/3 serves one port per server; a second `http3 = true` fails with
`error.SeveralHttp3Listeners`.

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

A handler that does not need the state can leave it out: `(req, res)`
handlers work on a `Server(App)` too.

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
| `listen(address)`, `listenTls(address, cert)` | Set up the listener and serve; see [above](#listen-and-listentls). |
| `use(middleware)` | Adds a global middleware (copied, owned by the server; a function works too), before any route. |
| `get`, `head`, `post`, `put`, `patch`, `delete`, `options`, `query`, `any` | Register a route (`query` is the HTTP QUERY method). |
| `ws(path, handler)` | A WebSocket endpoint; see [websocket.md](websocket.md#an-endpoint-in-one-line). |
| `webtransport(path, handler)` | A WebTransport endpoint (HTTP/3); see [webtransport.md](webtransport.md#an-endpoint-in-one-line). |
| `static(prefix, dir, options)`, `staticDir(prefix, path, options)`, `embedded(path, data, options)` | Serve a directory (one you opened, or one the server opens), or one file compiled in. |
| `group(prefix, .{ middleware, ... })`, `with(.{ middleware, ... })` | A route group, or middleware for some routes; see [routing.md](routing.md#groups). |
| `grpc(pb.Service, handlers)`, `grpcHealth()` | A gRPC service, and the health service; see [grpc.md](grpc.md#serve-a-service). |
| `metrics(.{})`, `health(.{})`, `tracing(.{})` | `/metrics`, `/healthz` and `/readyz`, OpenTelemetry traces; see [observability.md](observability.md#wiring). |
| `client()` | The server's outbound HTTP client (also `anole.client(req)`); see [clients.md](clients.md#the-servers-client). |
| `middleware(value)` | A server-owned copy of a middleware, as a handle to share between groups. |
| `reloadCertificates()`, `setCertificate(cert)` | Swap the TLS certificate while serving; see [TLS](#tls). |
| `router`, `server` | The HTTP core's router and server. |
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
the executor that accepted it. HTTP/3 does the same with one UDP socket per
executor (see [Cores](#cores)). On macOS the accept loops share one socket,
and HTTP/3 has one.

`run` handles SIGINT and SIGTERM (and SIGUSR2 when `process` is set), and
SIGHUP when there is a TLS listener, which reloads the certificates
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
   answers (see [Shutdown](websocket.md#shutdown)). Open WebTransport
   sessions get DRAIN_WEBTRANSPORT_SESSION and a close (see
   [Shutdown](webtransport.md#shutdown)).
6. `run` returns once every connection is closed, or when
   `server.timeout.shutdown` (30 s) runs out.

Handlers that run for long can learn of the drain: `req.drain` is an
`std.Io.Event` set when it starts, to wait on or test with `isSet()`. An
event stream that does neither never closes on its own, so with
`timeout.shutdown = null` it holds the drain open forever.

### Ports in use

`SO_REUSEPORT` lets several sockets listen on one port, which is how the
per-core accept loops and a restart's hand-over work. It would also let a
second copy of the server, or a stale one, join the same port without an
error and take a share of the connections. So before binding a listener,
Anole checks the address with a probe socket that sets `SO_REUSEADDR` but
not `SO_REUSEPORT`. The probe conflicts with any socket already listening
there, and the listener fails with `error.AddressInUse` and a log line
naming the address. Connections a stopped server left in `TIME_WAIT` do not
trip it, so a quick restart works. Port 0 is not checked, and neither are
sockets inherited from systemd or a SIGUSR2 predecessor. HTTP/3's UDP
sockets get the same check, with a probe that sets no option at all (UDP has
no `TIME_WAIT`), before the first of them binds. A dual-stack listener's
probe is dual-stack too, so it also finds an IPv4 socket on the port. On macOS, as on other BSDs, a listener on a specific address beside one on the wildcard
address of the same port (`127.0.0.1:8080` beside `0.0.0.0:8080`) is still
allowed: the kernel treats those as different addresses.

### IPv6 and IPv4

A listener on every interface without a family (`listen(":3000")`,
`listenTls(":443", ...)`, or `address = ""` in the options) is dual-stack:
one socket on `::` with `IPV6_V6ONLY` off, which takes IPv6 clients and
IPv4 ones alike. Its HTTP/3 endpoint follows it, so a client that resolves
`localhost` to `::1` and does not fall back to `127.0.0.1` (h2load's
HTTP/3 mode, many QUIC clients) connects as well as one that uses IPv4. The
startup line names it `http://[::]:3000 (...; IPv6 and IPv4)`. On Linux
the per-core `SO_REUSEPORT` sockets, the per-core HTTP/3 sockets with their
connection-ID steering, and the sockets a SIGUSR2 restart hands over are all
dual-stack the same way.

Where the system has no IPv6 (turned off at boot, `EAFNOSUPPORT`, or a
container without it), the same listener binds `0.0.0.0` instead, IPv4
only; so does Windows, a development target. An explicit address is bound
as it is: `"0.0.0.0"` stays IPv4 only, and `"::"` keeps the system's
default (IPv6 only on macOS; on Linux both, unless `net.ipv6.bindv6only`
says otherwise).

An IPv4 client of a dual-stack socket arrives as an IPv4-mapped address
(`::ffff:127.0.0.1`). Anole reports it as plain IPv4 (`127.0.0.1`) in
`req.remote_address`, so access logs, rate-limit keys and anything keyed by
the client address see one client one way whichever socket it came in on;
so are mapped addresses in `X-Forwarded-For` and PROXY protocol headers
(`anole.http.unmapIpv4` does it for addresses of your own). HTTP/3 keeps
the mapped address inside QUIC, where address validation tokens and Retry
are bound to it, and unmaps it only for the request.

### Many connections

Every connection is a file descriptor, and the process's soft open-file
limit is often 1024 (256 on macOS), kept low for old programs that use
`select`. So `init` raises the soft limit to the hard one, as Go does at
startup: 524,288 under systemd by default, 1,048,576 in Docker, and on macOS
`kern.maxfilesperproc` at most. (`raise_fd_limit = false` leaves it alone;
processes the server starts inherit the raised limit.)

`server.max_connections` follows the limit by default. When serving starts
it is the soft limit less what other descriptors need:

- 64 for the process at large (standard streams, log files, the DNS
  resolver, files opened at startup);
- 8 per executor (its event loop's descriptors, an HTTP/3 UDP socket);
- every listening socket (one per executor and listener on Linux);
- an eighth of the limit, for what grows with traffic beside the
  connections: files the static handler is sending, the outbound client's
  connections, database pools.

With Docker's 1,048,576 and 16 executors that is about 917,000 connections;
with a limit that stays at 1024, about 800. Past the cap the server stops
accepting and new connections wait in the kernel's accept queue, rather than
`accept` failing for want of a descriptor. 10,000 on Windows. Set
`.server = .{ .max_connections = 50_000 }` to cap it lower, as memory
suggests: an idle connection costs a few kilobytes, about 20 KB with TLS on
Linux, and a request in progress its buffers on top (see
`ServerConfig.max_connections`); `null` lifts the cap. The startup
debug log names the cap it worked out.

To allow more, raise the hard limit where the process starts:
`LimitNOFILE=1048576` in a systemd unit, `--ulimit nofile=1048576:1048576`
for `docker run`, `ulimit -Hn` in a shell (as root).

An HTTP/1.1 connection that has waited `timeout.idle_park` (1 s) for its
next request, with nothing buffered, ends its coroutine and parks: it is
then a small heap object whose socket the executor watches, and the next
request starts a coroutine for it again on the same executor; a
connection that had been parked that long or longer parks again as soon
as it has answered, so waking thousands of idle connections at once costs
coroutines only for those being served at that moment. Keep-alive
and first-request timeouts still apply to parked connections, to about a
second, and the drain and the stop close them. A WebSocket served through
callbacks ([`app.wsCallbacks`](websocket.md#callbacks)) parks the same
way between messages. HTTP/2 connections, and WebSockets served by a
handler that loops on `ws.next()`, keep their coroutines. Set
`server.timeout.idle_park` to null to keep every connection's coroutine
(parking needs zio's pinned executors, which `run` uses).

Each connection with a coroutine has a stack, which is two memory mappings.
Linux caps mappings per process with `vm.max_map_count`,
which is 65,530 by default on Debian, RHEL and their derivatives (Ubuntu
22.10 and later default to 1,048,576), so a server there stops taking new
connections at about 30,000 busy at once, whatever the cap. Raise it on
hosts that hold more:

```sh
sysctl -w vm.max_map_count=1048576   # or a file in /etc/sysctl.d/
```

## HTTP/2

HTTP/2 (`-Dhttp2`, on in `web` and `full`) reaches the same router and
handlers as HTTP/1.1.

- Over TLS, clients choose it through ALPN (`h2`, then `http/1.1`).
- On the cleartext port, a client that opens with the HTTP/2 preface gets
  HTTP/2 ("prior knowledge", `curl --http2-prior-knowledge`); others get
  HTTP/1.1 on the same port. `.http = .{ .h2c = false }` turns this off,
  and a listener in `listeners` with `http1 = false` speaks h2c alone. The
  old `Upgrade: h2c` handshake is not supported.
- When the client resets a stream (RST_STREAM) before its response is
  complete, or the connection is lost, the stream's handler is canceled: its
  next wait on `req.io` returns `error.Canceled`. A connection that ends
  cleanly may be a half-close, so handlers with their whole request keep
  running while the server checks with a PING every 500 ms; once a write
  fails, they are canceled too. `res.peerGone()` tells the same without a
  wait.

`Options.http2` sets `max_concurrent_streams` (250), `stream_window`
(64 KiB, also each stream's body buffer), `stream_window_reading` (1 MiB:
the window and buffer from the handler's first read of the body),
`connection_window` (16 MiB),
`max_header_list_size` (64 KiB), `stream_reset_burst` and
`stream_reset_rate` (rapid-reset protection), `max_continuations` (8) and
`enable_connect_protocol` (on, for RFC 8441 WebSockets).

## HTTP/3

HTTP/3 needs `-Dhttp3` (on in `full`) and an `https` listener, whose
certificate it shares. With `.http3 = .{}`, QUIC listens on UDP at the HTTPS
address and port, and every response of the HTTPS listener that did not come
over HTTP/3 carries `Alt-Svc: h3=":443"; ma=86400`, so browsers switch to
it. Handlers see `req.version_major == 3`, and `req.listener` is the HTTPS
listener's. With `listeners`, `http3 = true` on one TLS listener does the
same for it, and `http3` holds the settings; one HTTP/3 port per server.

`http3` fields: `address` and `port` (the TLS listener's when null), `alt_svc`
(true), `max_streams_bidi` (100 concurrent requests per connection),
`idle_timeout` (30 s, a `std.Io.Duration`), `validate_address` (false), `early_data`
(false), `sockets` (null: one per executor on Linux, see
[Cores](#cores)), `enable_connect_protocol` (true: extended CONNECT, for RFC 9220
WebSockets) and `webtransport` (false; `app.webtransport` turns it on). With `validate_address`, every new client must prove its address
with a Retry first, which costs a round trip and resists floods from
spoofed sources. `hq_interop_root` is for the QUIC interop runner only.

Supported: QUIC v1 and v2, Retry, stateless reset, ECN, session resumption,
0-RTT (opt-in, below), connection migration and NAT rebinding, key update,
GSO/GRO on Linux, a GOAWAY drain, mutual TLS (the `https` listener's
`client_auth`, see [TLS](#tls)), certificate reloads (the same) and SIGUSR2
restarts (see
[below](#zero-downtime-restart-and-socket-activation)), WebSockets (RFC 9220,
see [websocket.md](websocket.md)) and WebTransport (draft-02, see
[webtransport.md](webtransport.md)). Not yet: gRPC over HTTP/3.

### 0-RTT

A client that resumes a session can send its first requests with the
handshake, in 0-RTT, and save a round trip. `.http3 = .{ .early_data = true }`
takes them. Anyone who records that first flight can send it again, and TLS
does not stop the copy, so Anole does what RFC 8470 asks of a server:

- GET, HEAD and OPTIONS that arrive in 0-RTT run at once. Their headers
  carry `Early-Data: 1`, as a proxy would mark them, and
  `anole.early_data.isEarly(req)` says so.
- Every other method waits until the handshake completes. A replay never
  completes it (it lacks the client's keys), so a replayed POST never
  reaches its handler; the real client's POST runs one round trip later and
  is not marked.
- A route whose GET has effects that must not repeat takes the
  `anole.early_data.TooEarly` middleware, which answers 425 Too Early to any
  marked request; the client sends it again after its handshake:

  ```zig
  const pay = app.group("/pay", .{anole.early_data.TooEarly{}});
  ```

- Behind a proxy that takes early data itself (nginx's `ssl_early_data`),
  requests arrive marked `Early-Data: 1` on any HTTP version. With HTTP/3
  on (`http3`, or `listenTls`, which turns it on by default), the server
  answers 425 to the unsafe ones on every route
  (`anole.early_data.Guard`, RFC 8470 §5.1), since waiting cannot make them
  safe. Without it, add the guard yourself: `app.use(anole.early_data.Guard{})`.

Tickets are sealed with the same keys as every other ticket (see
[TLS](#tls)): they rotate every two days and carry over a certificate
reload, so 0-RTT goes on across one. A ticket is tied to the server's limits
and HTTP/3 settings, so after a change (such as a new `max_streams_bidi`)
old tickets still resume but without 0-RTT. Keys are not kept across a
restart or shared between machines: the first connection after either is a
full handshake.

### Connection migration

Packets reach their connection by connection ID, whatever address they come
from, so a client may move: a NAT rebinding, or a phone switching networks.
The server validates the new path, sends from then on to where the client is
now, gives it a fresh address-validation token when its IP address changed,
and requests see the new address in `req.remote_address`. The server
advertises no preferred address of its own. The QUIC interop runner's
`connectionmigration` case, which is about a preferred address, is therefore
left out of CI; with one advertised it would still fail on ngtcp2's servers,
because the runner wants a PATH_CHALLENGE as the first packet on the new path
and ngtcp2 sends the PATH_RESPONSE first, as RFC 9000 allows
(quic-interop-runner issues #424 and #500).

### Cores

On Linux HTTP/3 runs on every executor, as TCP does: one UDP socket per
executor (`sockets`, at most 255), all bound to the HTTP/3 port with
`SO_REUSEPORT`, each read by an endpoint of its own on its own executor. A
connection lives on the endpoint that accepted it, with all its tasks, and
never touches another executor. The kernel's 4-tuple hash, which spreads
TCP connections, would not keep it there: a client that moves to a new port or address would land on another socket.
So each of the server's connection IDs carries its endpoint's number in its
second byte, and a classic BPF program on the socket group
(`SO_ATTACH_REUSEPORT_CBPF`, Linux 4.5 or later) reads that byte from every
datagram's destination connection ID and picks the socket by it. A client's
first Initial carries a connection ID of its own choosing, so the kernel's
hash places it, and the endpoint that takes it hands out IDs with its own
number from then on.

What lands on another endpoint's socket all the same is passed on to the
owner's queue and handled there, never where it landed: another
connection's datagrams in a GRO batch (the kernel delivers a batch whole, to
the socket of its first), a socket group without the program (a kernel older
than 4.5: logged as a warning, and everything still works, one hop slower),
and sockets inherited in another order than they were bound in. Each
endpoint counts what it handled, passed on and accepted
(`anole.h3.EndpointStats`).

The endpoints share one TLS context, so a session ticket from one resumes,
with 0-RTT, on any other, and a certificate reload switches them all; one
key for address-validation tokens and stateless resets; and the drain,
which waits for every endpoint's connections. The endpoint number is one
plain byte of an ID that is otherwise random, so an observer who sees a
connection's IDs before and after a migration learns that both belong to
the same core, one of a few; QUIC-LB's plaintext mode makes the same trade.

On macOS `SO_REUSEPORT` does not spread datagrams over a group's sockets,
so HTTP/3 keeps one socket and one endpoint there, whatever `sockets` says.

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

**Certificate reload.** `app.reloadCertificates()` loads every TLS
listener's certificate and key again (from their files, for `.files`) and
the `client_auth` CAs (from theirs), and switches the TLS listeners and
HTTP/3 to them without a restart: all of them, or, if one fails, none. SIGHUP does the same while `run` serves, so a renewal hook can run
`kill -HUP <pid>` (or `systemctl kill -s HUP myapp`). With `process` set,
systemd hears `RELOADING=1` and then `READY=1`.

- New connections get the new certificate. Connections already open,
  handshakes in progress included, keep the one they started with, which is
  freed when the last of them closes.
- Session tickets issued before still resume: the ticket keys carry over.
- A reload that fails (a file missing, a key that does not match the
  certificate) returns the error, or logs it on SIGHUP, and the server goes
  on with the certificate it had.
- `app.setCertificate(cert)` switches every TLS listener to a different
  source the same way:
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
fn whoami(req: *anole.Request, res: *anole.Response) !void {
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
`LISTEN_FDNAMES` (each listener's name: `http`, `https`, those in
`listeners`; and `h3` for HTTP/3's UDP sockets), or by position (the
listeners in order, then every one left for HTTP/3) when they have no
names. A restart passes every listener's socket under its name, so a new
build whose `listeners` changed order still gets each port right. A listener with no inherited socket opens its own, and one named `h3`
must be a datagram socket. Several `h3` sockets are one `SO_REUSEPORT` group,
one endpoint each, in the order they were bound in: the steering program
picks a socket by its place in the group, which is the order of the `bind`
calls and changes when one of them closes. In another order they still work,
through the endpoints passing datagrams on to each other.

**Restart on SIGUSR2.** `kill -USR2 <pid>` starts the binary at the same
path with the same arguments and environment. The new process inherits the
listening sockets, HTTP/3's included (in the `LISTEN_FDS` format; every
per-core UDP socket, in the group's order, so the steering stays right),
binds nothing of its own, and reports through a pipe once it serves; only then does
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
its unit. A port alone binds `[::]` dual-stack, as Anole does on its own
(systemd's `BindIPv6Only=default`); write `0.0.0.0:80` for IPv4 only:

```ini
# anole-http.socket
[Socket]
ListenStream=80
FileDescriptorName=http
Service=anole.service

# anole-https.socket
[Socket]
ListenStream=443
FileDescriptorName=https
Service=anole.service

# anole-h3.socket
[Socket]
ListenDatagram=443
FileDescriptorName=h3
Service=anole.service
```

Without the socket units, drop `Requires=` and `Sockets=`: Anole binds the
ports itself and still hands them over on a reload. `anole-h3.socket` gives
HTTP/3 one socket, so one core; on Linux, leave it out (and out of
`Requires=` and `Sockets=`) and Anole binds a UDP socket per executor itself,
and hands them all over on a reload. On systemd 253 or later,
`Type=notify-reload` with `ReloadSignal=SIGUSR2` can replace `Type=notify` and
`ExecReload=`: systemd then sends the signal itself and waits for
`RELOADING=1` and `READY=1`. Both setups were checked on systemd 257: two
reloads in a row move `MainPID` to each new process, and a stop after them
drains.

Limits:

- Each TCP listener is one socket in this mode, so Linux loses the per-core
  `SO_REUSEPORT` accept sockets. HTTP/3 keeps its per-core UDP sockets.
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
Name the load balancers with `proxy_protocol_from`
(`.proxy_protocol_from = &.{ "10.0.0.0/8", "2001:db8::/32" }`) and a
connection from any other peer is closed before anything is read, so a
client that reaches the port directly cannot claim another address.

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

## Windows

Windows (x86_64) is a development target: Anole builds there with every
feature, runs, and passes its tests on CI, so an app can be written and
tested on a Windows machine. Serve production from Linux. What Windows
lacks, and does instead:

- **One listening socket per listener**, shared by the accept loops, as on
  macOS: no per-core `SO_REUSEPORT` sockets. Listeners bind without
  `SO_REUSEADDR`, which on Windows would let another socket take the same
  port; the bind itself fails with `error.AddressInUse` on a port in use.
- **IPv4 for `":port"`**: a listener without a host binds `0.0.0.0`, not a
  dual-stack `::`. Name `"[::]:port"` or `"[::1]:port"` for IPv6.
- **HTTP/3 on one UDP socket**, without connection-ID steering, UDP batching
  (GSO/GRO) or control messages: no ECN, and replies from a listener on a
  wildcard address leave from the address Windows picks rather than the one
  the client wrote to (no `IP_PKTINFO`).
- **Ctrl-C drains** the server as SIGINT does, and closing the console window
  as SIGTERM does. There is no SIGUSR2 restart and no SIGHUP: reload
  certificates with `reloadCertificates()` or `setCertificate()`.
- **No listener hand-off, socket activation or `sd_notify`**: with `process`
  set, the server still reads its environment from it, and nothing else
  changes.
- **No idle parking**: an idle connection keeps its task and stack, so idle
  connections cost more memory than on Linux and macOS.
- **No open-file limit** to raise: `server.max_connections` defaults to
  10,000.
- **BoringSSL without its assembly** (written for NASM, which Zig does not
  assemble), so TLS is slower.
- Variables such as `DATABASE_URL` and `OTEL_SERVICE_NAME` are read from the
  C library's environment.

To serve from a Windows machine, run the Linux build in WSL2 or Docker.

## Full control with `anole.http`

`app.router` and `app.server` are the HTTP core's router and server
(src/http/core, adapted from dusty), and `anole.http` is that core, with TLS
already on BoringSSL (`anole.http.core` has whatever it does not
re-export). You can skip `Server` and drive the core yourself:

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
