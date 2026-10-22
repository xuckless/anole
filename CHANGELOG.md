# Changelog

All notable changes to Anole. Before 1.0 there is no API stability promise;
breaking changes are listed anyway.

## Unreleased

### Security

- HTTP/2: a stream refused before it reached a handler (a header list past
  `max_header_list_size`, or one nghttp2 rejects) is freed when it closes;
  it used to be kept until the connection ended, so one connection could
  hold memory without bound. A peer whose streams keep being refused is
  sent GOAWAY(ENHANCE_YOUR_CALM) past `http2.refused_stream_burst` (100,
  refilled at `refused_stream_rate`, 10 a second).
- HTTP/2: a response whose handler has returned must be sent within
  `timeout.request` (or `timeout.keepalive` when that is off); a peer that
  gives it no flow-control window gets the stream reset, and a connection
  whose peer stops reading is closed after one write blocks that long.
  Such streams used to be held, and graceful drains to wait, indefinitely.
- PROXY protocol v2: a header whose TLV length is near 65535 is refused
  instead of crashing the process (or, in ReleaseFast, reading past a
  buffer). Only listeners with `proxy_protocol = true` were affected.
- PROXY protocol listeners take `proxy_protocol_from`, a list of networks
  in CIDR notation allowed to send the header; connections from other
  peers are closed. Optional; recommended when the port is reachable by
  more than the load balancer.
- `trusted_proxy_hops`: only the selected `X-Forwarded-For` entry is parsed,
  so a malformed entry the client added no longer makes the proxy's address
  the client's; a selected entry that is not an address reports `0.0.0.0`.
- **Breaking:** `X-Forwarded-Host` is honoured only with the new
  `server.trust_forwarded_host = true`. `X-Forwarded-Proto` stays on with
  `trusted_proxy_hops` and can be turned off with
  `trust_forwarded_proto = false`. Make sure the proxy overwrites both.
- HTTP/2: a request's repeated header fields are all kept (they used to
  replace each other), and cookie fields sent separately are joined with
  "; ", so no cookie is lost. `:authority` is the request's host; a `host`
  field that names another host gets 400.
- HTTP/1.1 requests without a `Host` field, and requests with two, get 400
  (RFC 9112). `server.request.require_host = false` accepts them again.
- Static files: a file modified after the year 9999 no longer crashes the
  server while formatting `Last-Modified`; the date is capped at 9999.
- A streamed response with a `Content-Length` no longer writes past that
  length: the write fails with `ContentLengthMismatch` (now part of
  `StreamingBodyWriter.Error`) and the connection is closed after the
  response. **Breaking:** `res.header`/`res.addHeader` refuse
  `Transfer-Encoding` and `Connection` (`error.InvalidHeaderName`); use
  `res.keepalive = false` to close the connection. A second
  `Content-Length` from `addHeader` replaces the first.
- A request body with broken framing (chunked) or a corrupt gzip/deflate
  coding is answered 400 and logged at `debug`, instead of 500 at `err`.
  Reading it fails with the new `error.MalformedBody` (was the parser's
  `InvalidChunkSize`/`ParseFailed`/... or zlib's `CorruptInput`).

### C ABI (ABI 0.1)

- `libanole`, Anole as a C library for the language bindings
  ([docs/c-abi.md](docs/c-abi.md)): `include/anole.h`, `zig build capi`
  (`libanole.a`, one object with every bundled C library and only `anole_*`
  exported, packed with Zig alone; `libanole.{so,dylib}`; `anole.dll` on
  Windows). A JSON configuration (`include/anole.schema.json`) sets
  listeners, limits, native routes (fixed answers, static files, the
  response cache, health and metrics) and middleware (request ID, access
  log, compression, CORS, JWT, rate limiting); consumer routes hand requests
  to a consumer thread that polls batches of events and answers by
  generation-checked handle: whole responses (copied or borrowed), files,
  streams with trailers, request bodies read without blocking, WebSockets
  with topics. Deadlines, aborts and lost wakes are Anole's to handle.
- Detached responses in the HTTP core: an HTTP/2 or HTTP/3 request that
  arrived whole is answered later with no task waiting
  (`Response.detach`); middleware opts in with `detach_safe` (every
  built-in one that runs before the handler does). The request and response
  stay on the reader's stack unless the handler detaches. On h2c a consumer
  route serves 2.0x the requests per second at one executor and 1.48x at
  four (M2 Pro, local).

### Server

- Listeners on every interface without a family are dual-stack (#57):
  `listen(":3000")`, `listenTls(":443", ...)` and `address = ""` in the
  options bind one socket on `::` with `IPV6_V6ONLY` off, taking IPv6 and
  IPv4 clients alike, and their HTTP/3 endpoint follows (a QUIC client that
  resolves `localhost` to `::1` without falling back now connects). So do
  the per-core `SO_REUSEPORT` sockets, the per-core HTTP/3 sockets and their
  connection-ID steering, and the sockets a SIGUSR2 restart opens. Where the
  system has no IPv6 (or on Windows) they bind `0.0.0.0`. An explicit
  `"0.0.0.0"` stays IPv4 only and `"::"` keeps the system's default.
  Breaking: `":3000"` meant `0.0.0.0` before.
- IPv4-mapped client addresses (`::ffff:127.0.0.1`) are reported as plain
  IPv4 in `req.remote_address`, from the socket, `X-Forwarded-For` and the
  PROXY protocol alike, so logs and rate-limit keys see one client one way.
  `anole.http.unmapIpv4` does the same for other addresses.
- `http.Listener.ipv6_only` and `anole.http.listenIp` set `IPV6_V6ONLY` on
  a listener of your own; `checkAddressFree` takes it as a second argument.

### Databases

- `.cache = .{ .ttl, .keep_empty = false }` serves an empty result without
  keeping it (#58): `optional`'s null (a Redis nil) and `all`'s zero rows,
  so cache-aside sees the value as soon as the store is filled, with no
  `invalidateQuery` per miss. The default (`true`) keeps them as before.
- `anole.db.lastSource(req)` says where the last `.cache` or `.coalesce`
  call made with the request got its answer: `.cache`, `.coalesced` or
  `.database` (for an `X-Cache: HIT|MISS` header). A `*anole.db.Ctx` keeps
  it in `last_source`.

### Windows, as a development target

- `zig build -Dtarget=x86_64-windows` builds the library, the examples and
  the tests with every feature, and a `windows` CI job runs `zig build test`
  on Windows, and examples/hello and examples/full serve requests there
  (HTTP/1.1, h2c, HTTPS with HTTP/2). The `cross` job also
  builds every preset and edge flag combination for x86_64-windows.
- BoringSSL builds without its assembly there (NASM syntax), nghttp2,
  ngtcp2, nghttp3, zlib-ng, zstd, Brotli and hiredis get their Windows
  settings, and ngtcp2 uses its own socket address types
  (`NGTCP2_USE_GENERIC_SOCKADDR`), since mingw's `sockaddr_in6` does not
  translate.
- Compiled out on Windows: per-core `SO_REUSEPORT` sockets, HTTP/3
  connection-ID steering, UDP batching and control messages (ECN,
  `IP_PKTINFO`), listener hand-off and SIGUSR2, SIGHUP reloads,
  `LISTEN_FDS`, `sd_notify` and idle parking. Ctrl-C drains the server.
  Tests of those parts are skipped there with the reason. See
  [docs/server.md](docs/server.md#windows).
- Listeners on Windows bind without `SO_REUSEADDR`, which there would let
  another socket take a port in use.
- The examples read their arguments with `args.iterateAllocator`, which
  works on Windows too.

## 0.1.0 (2026-10-21)

The first release: one server core for REST, WebSockets, gRPC and
WebTransport over HTTP/1.1, HTTP/2 and HTTP/3, with TLS, auth, database
connectors and observability, on Zig 0.17 for macOS and Linux.

### The HTTP core is Anole code

- The HTTP/1.1 server, router, middleware, client, WebSocket and HTTP/2
  engine, which came from lalinsky/dusty through Anole's fork, now live in
  `src/http/core` (MIT, attributed in every file and in THIRD_PARTY_NOTICES).
  Anole no longer fetches a `dusty` package. `anole.http` is the core, and
  `anole.http.core` the whole core module for what it does not re-export.
- Its tests run in `zig build test` (`zig build dusty-test` is gone; `zig
  build core-test` runs them alone), on a certificate made at build time
  instead of a committed key, and its fuzz targets run with Anole's under
  `zig build test --fuzz`.
- The fork's vendored nghttp2 1.69.0 copy is dropped (Anole always built its
  own nghttp2), and llhttp is compiled once instead of once per feature
  combination.

### Server

- Memory per connection: each task's stack reserves 1 MiB by default
  (`Options.max_stack_size`, was zio's 8 MiB), about 2 KiB of page tables
  per open connection instead of 4. An idle TLS connection holds no
  ciphertext buffer (a 1 KiB stash, blocks borrowed from a per-thread pool
  while records are in flight) and BoringSSL sheds its handshake
  configuration: about 20 KB per idle TLS connection instead of 29 on Linux.
  The request-buffer pool gives back, every 5 s, the sets a burst of
  connections left unused, and a WebSocket's reply batching shares one
  backstop task per executor instead of one per socket: a busy pipelining
  WebSocket holds about 34 KB instead of 43.
- Idle connections park: an HTTP/1.1 connection that has had nothing to
  read for `timeout.idle_park` (1 s, null turns it off) ends its coroutine
  and waits as a heap object whose socket its executor watches (a readiness
  poll in a zio `CompletionQueue` that one driver task per executor owns);
  its next request starts a coroutine on the same executor. Keep-alive deadlines, the drain and the stop cover parked
  connections. `app.wsCallbacks(path, Callbacks)` serves a WebSocket
  through `open`/`message`/`close` callbacks, and over HTTP/1.1 such a
  socket parks the same way between messages (`Response.adopt` in the
  HTTP core hands the connection over to it after the handshake).
- A request waiting in its handler holds about 6 KB instead of 14: its
  head, its arena's first chunk and the set's header share one page (sets
  are carved page-aligned from slabs; a trimmed one gives its pages back
  and is reused), the request's and the response's header tables start at
  16 entries and grow to their limits, a buffered body's first segment is
  taken when the body is written, and the write buffer comes from a pool of
  its own at the response's first write and goes back once it is out. What
  a request takes from its arena beyond the set's 10 KB goes back when it
  ends rather than staying with the set. `res.addHeader` adds a header
  that may repeat (`Vary`); adding to `res.headers` directly is limited to
  its current room.
- A WebSocket holds less (cgroup per socket, 10k sockets, Linux): an
  upgraded HTTP/1.1 connection keeps one page of its request (the head the
  handler can still read, beside the arena's first chunk) and reads frames
  into the rest of that page; its writer borrows a pooled buffer only
  while it has frames waiting (a small frame sent at once is built on the
  stack), so a quiet or echoing socket holds none. A callback socket gives
  its request buffers back right after the handshake instead of when it
  first parks. A `ws.next()` socket 32 to 22 KB idle or busy (TLS 37 to
  27); a callback socket 36 to 18.5 KB during a connect burst, 22 to 15 KB
  busy, 7.8 to 3.9 KB parked. Over HTTP/2 and HTTP/3 a socket's two frame
  buffers are 4 KB each instead of 16.
- `anole.App` (`Server(void)` with `init(gpa, options)`) and `app.listen(":3000")`
  / `app.listenTls(":443", .fromFiles("cert.pem", "key.pem"))` in Go's address
  notation (`":3000"` is every interface). `listenTls` adds HTTP/3 with
  `Alt-Svc` when it is built in (`Options.listen_tls_http3`). Without
  `http`/`https` in the options, the listeners are set up by `listen`,
  `listenTls` or `run`, hand-off, `sd_notify` and `waitReady` included.
  `anole.Cert.fromFiles` / `fromPem`.
- Several listeners: `Options.listeners`, beside `http` and `https`, each
  with its own address or unix socket, TLS certificate (listeners naming the
  same one share it), protocols (`http1`, `http2`: ALPN over TLS, h2c on
  cleartext; `http3` on one TLS listener) and name. One process can serve
  e.g. HTTP/1.1 + h2c, TLS HTTP/1.1 only, h2c only and TLS h2 + HTTP/3 on
  four ports. Names go into `LISTEN_FDNAMES` for socket activation and
  SIGUSR2 restarts, and to handlers as `req.listener.name`;
  `anole.onlyOn(name)` keeps a group's routes to one listener (an admin
  port). Certificate reloads cover every TLS listener, all or none.
  `Alt-Svc` now goes out only on the TLS listener HTTP/3 serves the port of
  (no longer on cleartext responses, where browsers ignore it). The HTTP
  core's `Listener` gains `http1` (off: HTTP/2 only) and `name`.
- The open-file limit: `init` raises the soft RLIMIT_NOFILE to the hard one
  (as Go does; `Options.raise_fd_limit`), and `max_connections` defaults to
  what that limit allows less a reserve for other descriptors (64, 8 per
  executor, the listening sockets, and an eighth of the limit), instead of
  10,000. An explicit `max_connections` still wins; 10,000 on Windows.
  `anole.http.fd_limit`.
- One line per subsystem, owned by the server: `app.grpc(pb.Service,
  handlers)` (a struct literal, a namespace, or methods on a value; gRPC,
  gRPC-Web, Connect and transcoded routes), `grpcHealth()` (NOT_SERVING on
  drain), `metrics(.{})`, `health(.{})`, `tracing(.{})`,
  `staticDir(prefix, path, .{})` and `ws(path, handler)`.
- Plain `(req, res)` handlers on a `Server(App)`; function middleware
  (`fn (req, res, next: anole.Next) !void`, or `anole.func(f)`) in `use`,
  `group` and the new `with` (middleware for some routes, no prefix).
- `anole.noWait(handler)` marks a handler (and its route's middleware) as
  never waiting: on HTTP/2 its whole requests run on the connection's reader
  without a task, the responses to one read in one write; on HTTP/3 on the
  endpoint task, right after the packet that completes them. gRPC takes it per
  registration: `app.grpcWith(Service, impl, .{ .no_wait = true })` for
  unary methods.
- `anole.client(req)` / `app.client()`: the server's pooled outbound HTTP
  client, with inline headers and `response.json(T, allocator)`.
- `anole.Server(Ctx)`: one call sets up the zio runtime (one pinned executor
  per core, connections never leave the core that accepted them), the
  listeners, SIGINT/SIGTERM handling and a graceful drain with a hard
  deadline.
- HTTP/1.1 on the HTTP core: a segment-trie router with path parameters
  and wildcards, nested groups, middleware, keep-alive and pipelining,
  per-phase timeouts and body limits, static files with ranges, ETags and
  precompressed variants, and no allocation per request on a warm
  connection.
- HTTP/2 on nghttp2 1.70.0 (with an RFC 9113 strictness patch), over TLS
  through ALPN and over cleartext with prior knowledge, on the same router;
  streaming bodies, trailers, two-phase GOAWAY on drain. A client's
  RST_STREAM, or a lost connection, cancels the stream's handler. h2spec
  passes every case in strict mode, over h2c and TLS.
- HTTP/3 on ngtcp2 1.25.0 (from Anole's fork xuckless/ngtcp2, see the
  migration entry) and nghttp3 1.18.0 (from Anole's fork xuckless/nghttp3,
  which can send the SETTINGS WebTransport needs): the same handlers over QUIC,
  `Alt-Svc`, Retry, stateless reset, QUIC v2, ECN, PKTINFO, GSO and GRO on
  Linux, per-request timeouts, a GOAWAY drain and mutual TLS. The QUIC interop runner
  passes every server case it was given against ngtcp2's and quic-go's
  clients. Breaking: `http3.idle_timeout_ms` is `http3.idle_timeout`, a
  `std.Io.Duration` (30 s by default), as the HTTP/3 client's is.
- HTTP/3 0-RTT, opt-in (`http3.early_data`), after RFC 8470: GET, HEAD and
  OPTIONS from early data run at once, marked `Early-Data: 1`; other methods
  wait for the handshake, which a replay never completes.
  `anole.early_data.TooEarly` answers 425 on routes that want no early data
  at all, and with HTTP/3 on every route answers 425 to unsafe requests a
  proxy marked `Early-Data` (`anole.early_data.Guard`). Session resumption works without
  it. The interop runner's `resumption` and `zerortt` cases pass.
- HTTP/3 connection migration: clients may move to a new address or port;
  the server validates the path, answers on it (closing included), hands
  out a new token when the IP address changed, and reports the new address
  to handlers. The ngtcp2 fork fixes a migration right after a NAT
  rebinding, which stock 1.25.0 closed with CONNECTION_ID_LIMIT_ERROR.
- HTTP/3 handshakes under loss: a server PTO retransmits both Initial
  packets of a ServerHello that needs two (a post-quantum key share), so a
  client that lost the second is not sent the first again and again (an
  ngtcp2 fork patch).
- HTTP/3 on every core on Linux: one SO_REUSEPORT UDP socket and endpoint
  per executor (`http3.sockets`, one per executor by default; macOS keeps
  one). The server's connection IDs name their endpoint in one byte, and a
  classic BPF program on the socket group (Linux 4.5+) steers each datagram
  to its connection's socket, across migrations too; a datagram that lands
  on another endpoint's socket all the same is passed on to its owner and
  handled there. Endpoints share one TLS context (tickets and 0-RTT work on
  any core), the token and stateless-reset key, and the drain. The UDP port
  is probed before the group binds, as TCP's is, and a SIGUSR2 restart hands
  every socket over in order.
- WebTransport over HTTP/3, draft-02 (what Chrome, Edge and Firefox speak):
  `app.webtransport(path, handler)` or `anole.webtransport.accept` give a
  session with streams both ways in either direction, datagrams (RFC 9297),
  `close(code, reason)` and a drain (DRAIN_WEBTRANSPORT_SESSION, then a
  close). The HTTP/3 client opens sessions too (`openWebTransport`).
  Checked against aioquic both ways, and in the interop runner's
  WebTransport mode against flupke (all seven cases); the browser images
  have not been run yet. A session ends only through its CONNECT stream's
  reader, so a peer that closes its session and then its connection at
  once counts as `.peer`, with its code, in `closeInfo()`.
- TLS through BoringSSL, built from source by Zig: TLS 1.3 and 1.2, ALPN,
  mutual TLS (with the acceptable CAs named in the request, and the client's
  certificate for handlers through `req.peerCertificate()` on HTTP/1.1,
  HTTP/2 and HTTP/3), stateless session tickets, close_notify on graceful closes, and a development
  certificate generated in memory (`.dev_self_signed`).
- Certificate reload without a restart: `Server.reloadCertificates()`, also
  on SIGHUP, and `Server.setCertificate(cert)` for new PEM or files. The
  HTTPS listener and HTTP/3 switch together; connections already open keep
  their certificate, session tickets from before still resume, and a reload
  that fails changes nothing.
- Response compression with zstd or gzip (zlib-ng) by the client's q-values,
  and compressed request bodies.
- Brotli responses (`Content-Encoding: br`, google/brotli 1.2.0) with
  `-Dbrotli`, on in `web` and `full`: the Compress middleware and
  `res.compress` pick `br` by the client's q-values, after zstd and before
  gzip on a tie (`Accept-Encoding: gzip, br` gets `br`). Buffered and
  streamed bodies, flushes included. Quality 5 by default
  (`ServerConfig.response.brotli_quality`, `res.brotli_quality`): 10-15%
  smaller than gzip on JSON of a few KB. The encoder's large blocks, and
  zlib-ng's deflate state for a buffered gzip body, are cached per executor
  (at most 4 MiB, trimmed when idle) instead of mapped and unmapped per
  response or kept in each connection's arena. Precompressed `.br` files
  are served as before.
- The PROXY protocol (v1 and v2) and `X-Forwarded-*` from trusted proxies.
- Zero-downtime restart on SIGUSR2 (the new process inherits the listening
  sockets, HTTP/3's UDP sockets included; HTTP/3 connections are closed and
  reconnect), systemd socket activation, and systemd's readiness protocol
  (`READY=1`, `RELOADING=1`, `MAINPID=`, `STOPPING=1`) without libsystemd.
- `anole.Server` conveniences: `static`, `embedded` and `query` routes;
  `group(prefix, .{ ... })` and `use` copy their middleware and the server
  calls its `deinit`; `middleware(value)` for one copy shared by several
  groups. `Options.http` defaults to none when `https` is set (HTTP on
  127.0.0.1:8080 only when neither is). Anole's zio defaults to pinned
  scheduling, so `zio_options` is optional, and declaring work stealing is a
  compile error. A second `Server` on a thread that has one fails with
  `error.ServerAlreadyOnThread` instead of an assertion in zio.
  `Server.waitReady` returns `run`'s error when the server stops before it
  is listening (a certificate that will not load, a port in use) instead of
  waiting for good; a restarted process tells its predecessor it is serving
  only once it really is.
- A response can carry 64 headers (`response.max_header_count`), no longer
  capped by the request's `max_header_count` (32).
- An opt-in blocking pool (`Options.blocking`, `anole.blocking.run`):
  CPU-heavy or blocking calls run on zio's thread pool, capped at a set
  number at once, while the request's executor goes on serving.

### Handlers, errors, JSON and CORS

- Errors that carry a status: a handler or middleware returns
  `error.Unauthorized` for a 401, `error.TooManyRequests` for a 429,
  `error.ServiceUnavailable` for a 503; any standard 4xx or 5xx counts, by
  its `std.http.Status` tag in PascalCase or its RFC 9110 phrase.
  `anole.errorStatus(err)` says which.
- `res.fail(status, message)`: the status and a body in place of anything
  written before, `{"error":"..."}` for a request that takes JSON and text
  otherwise. `Options.errors` (`.auto`, `.json`, `.text`) sets that for the
  whole server, the server's own 404, 405 and error answers included.
- `Options.error_handler`, a plain function that answers handler errors
  without a `Ctx`, and `anole.defaultError(req, res, err)`, the default
  answer, for it or an `uncaughtError` to fall back on.
- `req.param(name)` and `req.queryParam(name)`: a path parameter and a
  query-string value by name (short for `req.params.get` and
  `req.query.get`).
- `req.bind(T)`: the JSON body as a `T` in the request's arena, unknown
  fields ignored, 400 when it is missing (`error.MissingBody`) or does not
  fit (`error.InvalidJsonBody`); `req.bindWith(T, options)` takes
  `std.json`'s options. `res.json(value)`; `res.jsonWith(value, options)`.
  `anole.json.readBody` keeps the same contract on yyjson.
- Request locals: `req.setLocal(key, value)` and `req.local(T, key)`, typed
  values a middleware hands to the handler. `anole.auth.claims(req)`,
  `anole.auth.subject(req)` and `anole.auth.apikey.owner(req)` read what
  `RequireJwt` and the API key middleware verified.
- `anole.middleware.Cors.init(.{})` works out of the box: any origin, the
  common methods, the request headers the browser asks for, a 600 s max
  age. Origin lists (echoed with `Vary: Origin`), `credentials` (refused
  with every origin allowed), `expose`. A `Cors` inside a group answers the
  preflights for the group's routes: an `OPTIONS` to a path whose routes are
  for other methods runs the middleware of the route it asks about.
- A port another process already listens on is `error.AddressInUse`, logged
  with the address, rather than shared through `SO_REUSEPORT`; connections
  in `TIME_WAIT` do not count, and inherited sockets are not checked.
- Startup and logs: one line per listener as it starts, with its scheme and
  protocols (`listening on https://127.0.0.1:8443 (HTTP/2, HTTP/1.1,
  HTTP/3)`); the HTTP core logs under `anole`, `access` and `anole_h2`
  itself, so `anole.logFn` is no longer needed; no per-request debug line;
  `anole.std_options` quiets zio's thread lines and Anole's debug lines; a
  TLS file that cannot be read is logged with its path. `zio_options` is
  gone from the quick start (it was already optional).
- Breaking:
  - `std.json`'s error names (`SyntaxError`, `UnknownField`, `MissingField`
    and the rest) are no longer answered 400: JSON that fails to parse
    anywhere but the request body is a 500. The body helpers (`bind`,
    `json`, `jsonValue`, `anole.json.readBody`) fail with
    `error.InvalidJsonBody` instead, and `bind` and `readBody` with
    `error.MissingBody` for no body. An `uncaughtError` that matched the old
    names should match these.
  - `req.json(T)` ignores unknown fields, as `bind` does.
  - `res.json(value, options)` is `res.jsonWith(value, options)`;
    `res.json(value)` takes no options.
  - `Cors.init` no longer returns an error union (drop the `try`), `origin`
    is optional, and `max_age` is a number of seconds (`?u32`, 600 by
    default) instead of a string.
  - An `OPTIONS` request to a path with routes for other methods runs that
    route's group middleware before the 405.
  - The HTTP core's log scopes are `anole` (was `dusty`), `access` (was
    `dusty_access`) and `anole_h2` (was `dusty_h2`); a `log_scope_levels`
    entry naming `.dusty` should name `.anole`.
- A response cache: `anole.cached(.{ .ttl }, handler)` for one route, or
  `app.responseCache(.{})` (`anole.middleware.ResponseCache`) for several
  through `with`, `group` or `use`. Answers to `GET` (and `HEAD` from a
  kept `GET`) with a cacheable status and a body in memory are kept per
  executor and served without running the handler; never one that sets a
  cookie or says `no-store`, `no-cache` or `private`, and not for requests
  that carry credentials unless `.authenticated`. `Cache-Control`'s
  `s-maxage` or `max-age` sets how long, `Vary` is honoured, and
  `invalidate(.all)` or `.{ .path }` reaches every executor at once.

### WebSockets

- RFC 6455 over HTTP/1.1, RFC 8441 over HTTP/2 and RFC 9220 over HTTP/3
  behind one `anole.websocket.upgrade`, permessage-deflate, and a rooms
  helper for broadcast. Autobahn passes every case; RFC 9220 is checked
  against aioquic's client.
- A receive that fails on the client's account sends the matching close
  code first (1009, 1007 or 1002) on every HTTP version.
- A drain closes open sockets with 1001 (going away) and ends them as soon
  as their clients answer, rather than at `timeout.shutdown`;
  `Socket.draining()` tells handlers why, `close_on_drain = false` leaves it
  to them, and `req.drain` lets any long-lived handler watch for the drain.
- `Rooms.broadcast` sends outside the lock: a slow member holds up only the
  broadcasts that include it.
- RFC 8441 and RFC 9220 sockets are logged, measured and traced as 101,
  like HTTP/1.1 upgrades.
- `app.ws(path, handler)` with `Socket.next()` (text and binary messages,
  null on close): an echo endpoint is one loop; a plain request gets 426.
- Breaking: `Rooms.init(allocator)` takes no `Io` (it comes from the first
  socket to join), so the rooms can be made before the server.

### gRPC

- Server and client over HTTP/2: all four call modes, deadlines, metadata,
  status in trailers, gzip, and handlers canceled when the client resets the
  call. grpc-go's interop client passes 14/14 cases against Anole and Anole's
  client 11/11 against grpc-go, each over h2c and TLS; grpc's
  `tools/http2_interop` server checks run too.
- Responses are gzipped only when the request was (grpc-go's rule);
  `RegisterOptions.response_compression` = `.accepted` gzips whenever the
  client accepts it, `.never` never.
- `registerWith` options per registration: the request message limit
  (`default_max_message_size`, 4 MiB, by default) and data for the handlers.
  A handler's own error reaches the client as UNKNOWN "Application error
  processing RPC" and is logged on the server, rather than sent by name.
  `Call.addHeader` returns `error.HeadersSent` once the response has started.
  `Call.requestCompression()`, `protocol()` and `codec()` say how a call
  came in; the server's own state is in `call.impl`, not part of the API.
  `anole.grpc.Status` and `Code` are the one place for statuses.
- gRPC-Web and Buf's Connect protocol on the same routes, including Connect's
  GET form for methods marked `NO_SIDE_EFFECTS`, and the `grpc.health.v1`
  service (`anole.grpc.Health`, one registry per instance).
- JSON transcoding from `google.api.http` annotations: the same
  registration adds REST routes (`get`/`put`/`post`/`delete`/`patch`,
  `custom`, `additional_bindings`), with the full path template syntax
  (`{field=a/*/b}`, `**`, nested fields, `:verb`), `body` (`*` or a field)
  with the rest from query parameters, `response_body`, errors as
  google.rpc.Status JSON under the matching HTTP status, and a server
  stream as one JSON array sent element by element. JSON through
  zig-protobuf's generated proto3 mapping. `RegisterOptions.transcode =
  false` leaves the routes out.
- Connect's JSON writes a oneof's member as a field of the message, as
  protojson does; it was nested under the oneof's name.
- The tasks of a streaming call run on the stream's own executor.
- `addProtoGen` for an application's build.zig: protoc and the Zig generator
  are pinned and built by `zig build`, nothing to install;
  `google/api/annotations.proto` and `http.proto` come with Anole.
- `addApp(b, .{ .name, .root_source_file, .protos })` makes an application's
  build.zig one call, and `addProtoModule` generates a `.proto`'s module in
  the cache as part of `zig build` (no separate step, nothing committed).

### Clients

- Outbound HTTP/1.1 and HTTPS (the HTTP core's client on BoringSSL), an
  HTTP/2 client and an HTTP/3 client, usable from handlers through `req.io`.
  The HTTP core's client speaks HTTP/2 too when a server picks it
  (`ClientConfig.http2 = true`).
- One set of TLS options for all three: the system trust store by default
  (loaded once), a CA file, directory or PEM in memory, client certificates
  for mutual TLS from files or memory, and
  `insecure_skip_verify` for tests.
- The HTTP/2 and HTTP/3 clients share their names (`ClientConnection`,
  `Stream`, `Header`, `ConnectOptions`, `RequestOptions`, `StreamError`,
  `version()`), a `connect_timeout` and a per-request `timeout` that ends in
  `error.Timeout`, and options of one name and type where they mean the
  same (`stream_window` and `max_data`, both `u31`; the stream window's
  default is 64 KiB over HTTP/2, which allocates it per stream, and 256 KiB
  over HTTP/3). Options only one protocol has say so: HTTP/2's optional
  `tls` (h2c without it) and `body_bytes`, HTTP/3's `idle_timeout` (a
  `std.Io.Duration`), `session_cache`, `early_data`, `webtransport` and
  `early`. `Stream.readError()` and `writeError()` say what a `ReadFailed`
  or `WriteFailed` was.
- Breaking: their `tls.root_ca` bundle is now `tls.ca` (an
  `anole.http.TlsCa`, the system store by default, where it trusted nothing
  before); `tls.certificate = .{ .cert_pem, .key_pem }` is
  `tls.client_certificate`, the HTTP core's shape (`.pem = .{ .cert, .key }` or
  `cert_path`/`key_path`); the HTTP/3 client's `handshake_timeout_ms` is
  `connect_timeout`.
- The HTTP/3 client resumes sessions from an `anole.h3.SessionCache`, sends
  0-RTT when asked (`early_data`), and sends again what a server refused in
  early data; `rebind` moves a connection to a new socket (a migration).

### Auth, state and limits

- JWS/JWT verification with one pinned algorithm per key (an HMAC secret
  shorter than its hash verifies nothing, `error.WeakKey`) and JWKS
  keyrings that fetch outside their lock, one fetch at a time; a bearer-token
  middleware (`anole.auth.RequireJwt`) with RFC 6750 errors, scopes and
  required claims (`required_claims`, `sub` by default), the verified token
  handed to the handler through the request's locals (`claims`, `subject`),
  never through the session; OIDC sign-in as a relying party (PKCE, Google
  and Apple presets); CSRF tokens; Argon2id passwords, hashed on the
  blocking pool when there is one; API keys from `X-API-Key` or
  `Authorization: Bearer ak_...` (the prefix tells them from JWTs), their
  owner in the locals (`apikey.owner`); RBAC with roles from the
  application's state.
- The clients these use are the server's: `Keyring.init(gpa, io, client,
  url)`, `oidc.Provider.discover(gpa, client, issuer)`,
  `RelyingParty.finish(arena, io, client, ...)` and
  `observe.trace.Exporter.init(gpa, io, client, options)` take the
  `anole.Client` that `app.client()` and `anole.client(req)` return.
- Sessions in memory or Redis/Valkey, and sealed cookie sessions
  (`anole.session.Middleware`, the one session middleware;
  `anole.middleware` has none); `anole.session.regenerate` issues a new
  session ID at sign-in. A cookie session needs a key: `Middleware.init`
  returns `error.SessionKeyMissing` for none or all zeros, there is no
  default. `anole.session.keyFromBase64` reads one from configuration, and
  `devKey(io)` makes a random one for development, with a warning. The
  HTTP core's signed-cookie session (`anole.http.middleware.Session`)
  refuses keys shorter than 32 bytes (`error.WeakSessionKey`).
- Rate limiting with token buckets in memory or Redis and a 429 middleware:
  `ratelimit.Middleware.init(limiter, .{ .limit, .window_ms, .burst, .key,
  .on_error })`, counting by client address unless `.key` says otherwise,
  and letting requests through (`.allow`, the default) or answering 503
  (`.deny`) when the limiter's store fails.
- `RedisStore` and `RedisLimiter` run on the Redis connector's pools
  (`app.redis`), with their options as before.
- JSON on yyjson.

### Databases

- One shape for every connector (`anole.db`, docs/database.md): the
  handle is each connector's `Client` (`anole.pg.Client`,
  `anole.sqlite.Client`, `anole.mongodb.Client`, `anole.redis.Client`) and
  lives in the App state, every call takes the request first (an
  `anole.db.Ctx` outside a handler), rows come back as your structs in the
  request's arena, nothing to free, and calls fail with the connector's
  `Error`. The verbs are shared, and a verb means the same thing in every
  connector: `exec` (rows changed), `one`, `optional`, `all`, `iterate`,
  `begin` (a `Tx` whose `commit(req)` and `rollback(req)` take the request
  like every other call), `transaction`, `acquire`, and
  `with(.{ .timeout, .prepare, .coalesce, .cache })` for options per call;
  each connector has the ones its database can do. A pool per
  executor, the connection limit split between them, so no lock is shared
  between threads. A request's deadline, a client gone or an HTTP/2 reset
  cancels its query (PostgreSQL is sent a CancelRequest, SQLite's statement
  is interrupted, a MongoDB or Redis connection is closed).
- Errors are statuses: `NotFound` 404, `Conflict` 409 (unique and
  exclusion violations, serialization failures and deadlocks),
  `ServiceUnavailable` 503, `GatewayTimeout` 504, anything else `Database`
  500. What the database said stays in the log and in
  `anole.db.lastError(req)`, never in the response; `.errors`
  (`anole.db.ErrorMap`) moves a class to another status, such as foreign
  keys to 422.
- Each connector reports to what the app has, in any order: `anole_db_*`
  metrics labelled `system` and `db` (`app.metrics`), a client span per
  call with OpenTelemetry's `db.*` attributes (`app.tracing`), and a check
  behind `/readyz` (`app.health`). The server closes it after the drain.
  `anole.db.Time` is a timestamp that reads and writes RFC 3339 in JSON.
- PostgreSQL (`-Dpostgres`, on in `web` and `full`; `anole.pg`,
  `app.postgres(.{})`): on Anole's fork of pg.zig, with TLS on BoringSSL
  (libpq's `sslmode`s, `sslnegotiation=direct`, client certificates). The
  connection comes from `.url`, `DATABASE_URL` or libpq's `PG*` variables.
  Statements are prepared once per connection and kept; a canceled call
  sends a CancelRequest; `transaction` runs again after a serialization
  failure or a deadlock; `listener()` opens a connection for
  `LISTEN`/`NOTIFY`. Checked against postgres:17 with scram-sha-256, in
  plain text and with `sslmode=verify-full`.
- SQLite (`-Dsqlite`, on in `web` and `full`; `anole.sqlite`,
  `app.sqlite("app.db")`): the 3.54.1 amalgamation compiled in, through
  Anole's fork of zig-sqlite. One writer thread per database owns the
  read-write connection; reads run on the blocking pool over read-only
  connections in WAL mode, and a read that turns out to write moves to the
  writer. `:memory:` is one database for the whole app. A cancel or a
  timeout interrupts the running statement, and `transaction` retries past
  `SQLITE_BUSY`. `app.sqlite` starts the blocking pool when the app has
  none.
- MongoDB (`-Dmongodb`, on in `full`; `anole.mongodb`, `app.mongodb(.{})`):
  Anole's own client on `std.Io`, written to MongoDB's driver
  specifications: OP_MSG, SCRAM-SHA-256 and SCRAM-SHA-1 (PLAIN and X.509
  too), the connection string (`MONGODB_URI`), server discovery and
  monitoring with primary selection, pools per executor, implicit
  sessions, retryable reads and writes, and TLS on BoringSSL. The calls
  are the official drivers', with the request first (`find`, `findOne`,
  `insertOne`, `updateMany`, `findOneAndUpdate`, `aggregate`, cursors,
  counts, `distinct`, indexes, `runCommand`), with filters, updates and
  pipelines as Zig literals; `one`, `optional` and `all` are `findOne`,
  `findOptional` and `find` under the shared names, and `with` takes the
  shared options on the client, a database or a collection. MongoDB 4.2 and later. CI runs 7.0 on
  ubuntu-latest, and 8.0 and 9.0 on ubuntu-22.04 only: they do not run on
  Linux kernels from 6.19 to 7.0.13 (SERVER-121912, SERVER-125742).
- BSON (`anole.bson`, with `-Dmongodb`): documents checked once and then
  read in place, a builder, struct mapping at compile time, Decimal128,
  ObjectId and Extended JSON v2. The BSON corpus of
  mongodb/specifications passes with no case skipped.
- Redis and Valkey (`-Dredis`, on in `full`; `anole.redis`,
  `app.redis(.{})`) on the same shape: `command`, `one`/`optional`/`all`
  into your types, `pipeline`, `acquire` for WATCH and MULTI,
  `subscribe`/`psubscribe` on a connection of their own that ends on the
  drain, and helpers for strings, hashes (into and from structs), lists,
  sets, sorted sets and `publish`. The URL as go-redis and redis-py read
  it (`REDIS_URL`): `redis://`, `rediss://` (TLS on BoringSSL), `unix://`,
  ACL users, the database to SELECT. hiredis only parses the replies.
- Opt-in caches for reads, off unless a call asks, so a plain call costs
  nothing extra: `with(.{ .coalesce = true })` makes identical reads in
  flight on one executor share one round trip, each caller with its own
  deadline and its own copy of the rows; `with(.{ .cache = .{ .ttl, .tag
  } })` keeps a result per executor for `ttl`. `cache.invalidate(.all)`,
  `.invalidate(.{ .tag })` and `.invalidateQuery(sql, args)` reach every
  executor at once, a statement still running included. Bounded per
  connector (`Options.cache`), with `anole_cache_*` metrics.
- `anole.net.ClientStream`: the plain or TLS client socket the connectors
  share (TCP or a Unix socket, `startTls` for PostgreSQL's SSLRequest).
- `anole.blocking.runWith(io, .{ .on_cancel = ... }, func, args)`: a hook
  called when the waiting caller is canceled while its job runs (SQLite
  interrupts the statement there); a job whose caller was canceled before
  it started no longer starts.

### Observability

- Prometheus `/metrics`, OpenTelemetry traces (W3C `traceparent`, OTLP/HTTP
  export), JSON or text access logs with request and trace IDs, `/healthz`
  and `/readyz`, and one consistent log output under Anole's own scopes.
- `Registry` and `Health` are values the application owns, each serving its
  own server, so one process can run several servers.
- An `exclude` list on the access log, HTTP metrics and tracing middleware
  keeps paths such as `anole.observe.probe_paths` (`/healthz`, `/readyz`,
  `/metrics`) out.
- Histogram sums are exact floats (seconds for durations, from
  nanoseconds), and bucket bounds are checked. `/readyz` answers 503 to
  anything still routed during a drain. `Exporter.deinit` returns without
  waiting out `interval_ms`.
- A metric registered twice under one name is one metric: `Registry`'s
  `counter`, `gauge` and `histogram` return the family already there.
- Breaking: `HttpMetrics.init` takes options, and `statusOf` the request.

### Build

- Every bundled library sits behind a build flag (`-Dtls`, `-Dhttp2`,
  `-Dhttp3`, `-Dgrpc`, `-Dwebsocket`, `-Dauth`, `-Dcompression`, `-Dbrotli`,
  `-Djson`, `-Dredis`, `-Dpostgres`, `-Dsqlite`, `-Dmongodb`) and presets
  (`-Dprofile=minimal|web|full`); what is off is neither downloaded nor
  compiled. `web` has PostgreSQL and SQLite; `full` adds MongoDB and
  Redis.
- Release binaries of examples/full on x86_64 Linux (loaded sections,
  `tools/binary_size.py`): 6.1 MB with everything, 1.3 MB minimal. Brotli adds about 0.8 MB (its encoder and the
  122 KB dictionary with its lookup tables), so `-Dbrotli=false` is the
  first flag to drop for a smaller binary that still compresses.
- The public surface (what Zig's autodoc shows from `anole`) is the API
  alone: the raw C bindings (nghttp2, ngtcp2, nghttp3, BoringSSL), the TLS
  module the HTTP core runs on, test helpers, gRPC's wire modules
  (`frame`, `status`, `metadata`, `deadline`) and the WebSocket layer over
  HTTP/2 and HTTP/3 streams stay inside. `anole.compression` keeps its
  zlib-ng, zstd and Brotli bindings, which are what it is for.
  `anole.h2.version()`, `anole.h3.version()` and `anole.tls.version()` say
  what a build links.

### Docs and examples

- docs/getting-started.md: from `zig init` and `zig fetch --save` to a
  running JSON API, then a WebSocket, static files, TLS, gRPC (with
  `addApp` and a `.proto`) and deploying (addresses, systemd, Docker).
- docs/from-fiber.md: Go Fiber v3's API next to Anole's, and what differs
  in Zig (arenas, error unions, no `recover`).
- Guides for the server, routing, WebSockets, WebTransport, gRPC, clients,
  databases, auth and observability, with every Zig snippet compiled
  against the API.
- A docs site, https://xuckless.github.io/anole/, built from docs/ with an
  API reference at /api/ (`zig build docs`, Zig's autodoc of the `anole`
  module, from doc comments on the public API), and a GitHub wiki kept in
  sync with docs/.
- SECURITY.md (private reports through GitHub's advisories) and issue
  templates.
- Examples, each with `zig build run-<name>`: `hello` (the smallest
  server), `rest` (a JSON CRUD API behind an API-key middleware, checked
  by tests/rest_test.zig), `websocket`, `grpc`, `auth`, `clients`,
  `observe`, `io`, `postgres` (a posts API with a transaction), `sqlite`
  (a to-do API), `mongodb` (a users API), `redis` (a counter, a cache, a
  leaderboard and pub/sub as Server-Sent Events), and `full` (every
  listener and option spelled out; the server that h2spec and the restart
  test drive).

### Quality

- CI on Linux and macOS: unit tests for every flag combination, the HTTP
  core's own test suite on Anole's TLS and C libraries, h2spec, Autobahn, gRPC interop,
  HTTP/3 (WebTransport and RFC 9220 included) against aioquic, the QUIC
  interop runner and its WebTransport mode, fuzzing of the parsers
  and shim boundaries (HTTP/1.1 requests whole and in pieces, a whole
  connection over HTTP/1.1 and HTTP/2, the PROXY protocol, WebSocket over
  HTTP/2 and permessage-deflate, gRPC frames, metadata and timeouts,
  Connect GET messages, JSON, session cookies, traceparent, JWS and JWK
  Sets, OIDC discovery, token responses and ID token claims,
  `LISTEN_FDS`, BSON and MongoDB's wire messages), a clean-consumer
  build, and a weekly check of the C libraries' pins (SQLite's included)
  against known advisories.
- The database connectors against real servers in Docker: postgres:17
  (plain and `verify-full` TLS), MongoDB 7.0, 8.0 and 9.0 as a replica set
  (SCRAM-SHA-256, SCRAM-SHA-1 and TLS, retries through `failCommand`; 8.0
  and 9.0 on ubuntu-22.04),
  redis:7 and valkey:8 (plain, and TLS with an ACL user). MongoDB's
  connection-string, URI-options and server discovery spec tests and the
  BSON corpus run in `zig build test`.

### Not yet

- HTTP/3: keeping ticket keys (so 0-RTT) across restarts.
- WebTransport's later drafts (13 and on, which need QUIC's RESET_STREAM_AT
  and per-session flow control), and checks against real browsers.
- gRPC over HTTP/3; JSON transcoding of client and bidirectional streaming
  methods.
- MongoDB: transactions, change streams, `mongodb+srv://`, read
  preferences other than `primary`, `loadBalanced`, compression, and the
  request's own deadline sent as `maxTimeMS`. Redis Cluster and Sentinel.
- Windows (#47): until it is a development target, use WSL2 or Docker.
- Independent benchmark results: Anole's HttpArena entry follows this
  release.

Known limitations and planned work are tracked in GitHub Issues:
https://github.com/xuckless/anole/issues
