# Changelog

All notable changes to Anole. Before 1.0 there is no API stability promise;
breaking changes are listed anyway.

## Unreleased

### C ABI

- `anole_db_*` with SQLite (additions to ABI 0.1): databases from the
  configuration (opened at start with an `init` script), queried without
  blocking the caller;
  each answer is an `ANOLE_EV_DB_RESULT` record (column names and typed
  cells, or changes and the last rowid) with the caller's `user_data`.
  Per-query timeout, coalescing and the TTL result cache with tags and
  `anole_db_invalidate`; failures carry their class, the status Anole would
  answer and the database's detail. `anole.sqlite`'s `table` and `run`
  are the Zig side: rows and parameters known only at run time
  (`anole.sqlite.Value`).
- `anole_db_*` with PostgreSQL: a `"postgres"` database (`url`, `sslmode`,
  `ca_file`/`ca_pem`, pool bounds and timeouts, `init`), the same calls,
  options, answers and error classes. TLS is checked by default
  (verify-full for a server on another host); a CA given in the
  configuration can't be turned off by the URL. Cells come in PostgreSQL's
  text format but for bool, integers, floats and bytea, each with its
  column's type OID (`anole_db_cell.db_type`, formerly `reserved`) for a
  binding's own type parsers; `ANOLE_DB_BOOL` is a new value and cell type.
  `timeout_ms` cancels the statement on the server.
- `anole.db.Value`, `Table` and `Changes` are shared by the SQL connectors
  (`anole.sqlite`'s are now these); `anole.pg` gains `table` and `run` for
  rows and parameters known only at run time, and `Options.sslmode`.
- `anole_db_*` with Redis and Valkey: a `"redis"` database (`url`,
  `ca_file`/`ca_pem`, pool bounds and timeouts). A command is `sql` (its
  name and fixed words) plus parameters as binary-safe arguments;
  `anole_db_query` answers with the reply as a tree of cells in preorder
  (`ANOLE_DB_ARRAY`, `ANOLE_DB_MAP` and `ANOLE_DB_ERROR` are new cell
  types), `anole_db_exec` with an integer reply as `changes`. Coalescing
  and the result cache apply to read commands.
- `anole.redis`'s `Query.reply` sends a command known only at run time
  (`[]const []const u8`), through the cache for read commands; the result
  caches copy types that hold themselves (a reply tree).

### Fixed

- C ABI: a program linked against `libanole.a` with dead-stripping
  (`-Wl,-dead_strip`, or `zig cc -O1` and Zig's release links) crashed on
  macOS when its first TLS listener started: the packed object lost the
  symbol flags that keep BoringSSL's assembly together, so the linker cut
  it apart. The flags are restored when libanole is packed.
- C ABI: on x86_64 Linux, a program or extension linked against
  `libanole.a` with GNU ld got an executable stack (the packed object had
  no `.note.GNU-stack`); glibc 2.41 refuses to load such an extension.
  The note is added when libanole is packed.

## 0.1.1 (2026-10-22)

### Security

Changes that need action or alter behaviour are also collected under
Breaking below.

#### HTTP/3 and WebTransport

- HTTP/3: long-header packets whose connection ID is longer than QUIC
  allows (20 bytes), and Version Negotiation packets sent to the server,
  are dropped before any lookup. Previously one such datagram could crash
  the process. Every deployment with HTTP/3 on should upgrade; no
  configuration change is needed.
- HTTP/3 server: the request head's size (64 KiB, as advertised in
  SETTINGS) and field count (`request.max_header_count`) are enforced as
  the fields arrive; a larger head is answered 431. Before, the whole head
  was kept in memory however large it was.
- HTTP/3 server: cookie fields sent separately are joined with "; " and
  other repeated request fields are all kept, as over HTTP/1.1. Before,
  only the last of each was kept, which could drop or shadow a session
  cookie.
- WebTransport: a peer's stream that is reset before it names its session
  is now freed. A peer's streams now hold its stream credit until the
  handler releases them (before, credit came back as soon as a stream
  ended, even if it was never accepted), and at most 100 streams each way
  wait to be accepted per session. A peer that opens streams a handler
  does not accept now waits for credit instead of growing server memory.
- HTTP/3 server: a new connection that is given up right after its first
  datagram (for example because that datagram also carried an error) no
  longer frees state that a 0-RTT request started from the same datagram
  still uses. Only servers with `early_data` on were affected.
- HTTP/3 server: a request the client resets now keeps counting against
  `max_streams_bidi` until its handler returns. Before, its stream credit
  came back at once, so handlers of reset requests could pile up past the
  limit (the HTTP/3 form of HTTP/2's "rapid reset").
- HTTP/3: `http3.hq_interop_root` (the QUIC interop runner's HTTP/0.9 file
  server, which bypasses the router and middleware) is refused with
  `error.HqInteropNotAllowed` unless the program's root file declares
  `pub const anole_hq_interop = true;`. Breaking only for programs that
  set it.

#### HTTP/2 and HTTP/1.1

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
- HTTP/2: the raised body windows of one connection's streams share
  `http2.reading_window_budget` (16 MiB), so a connection with many uploads
  at once no longer takes 1 MiB per stream without bound. docs/server.md
  now sizes HTTP/2 memory per stream.
- HTTP/2: a request's repeated header fields are all kept (they used to
  replace each other), and cookie fields sent separately are joined with
  "; ", so no cookie is lost. `:authority` is the request's host; a `host`
  field that names another host gets 400.
- HTTP/1.1 requests without a `Host` field, and requests with two, get 400
  (RFC 9112). `server.request.require_host = false` accepts them again.
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
- HTTP/1.1: the rest of a request body a handler left unread is drained
  only until the request's deadline, and at most `timeout.keepalive` (10 s
  when that is off); a request already past its deadline is not drained
  and its connection closes. A handler that lifted its timeout, or caught
  the timeout's error and returned, let a slow client hold the connection
  indefinitely.
- Static files: a file modified after the year 9999 no longer crashes the
  server while formatting `Last-Modified`; the date is capped at 9999.
- `anole.Server` answers 425 Too Early to unsafe requests marked
  `Early-Data: 1` on every server, not only when HTTP/3 is on, so a proxy
  that accepts TLS early data in front of an HTTP/1.1 or HTTP/2 server no
  longer gets replayable POSTs through. `app.use(anole.early_data.Guard{})`
  is no longer needed (it is harmless).

#### PROXY protocol and forwarding headers

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

#### TLS

- TLS listeners offer only ECDHE key exchange with AES-GCM or
  ChaCha20-Poly1305 over TLS 1.2 (BoringSSL's default also allowed RSA key
  exchange and CBC with SHA-1). TLS 1.2 clients that support none of these
  can no longer connect. Docs now state that revocation (CRL, OCSP) is not
  checked and that `.dev_self_signed` certificates are CAs for development
  only.
- Mutual TLS: a TLS session resumes only under the client-auth settings
  (CAs and mode) it was verified under, on TCP and QUIC listeners, and a
  certificate reload that changes them no longer carries the ticket keys
  over. Removing a client CA and reloading now stops clients whose
  certificates it vouched for from resuming with older sessions.

#### Clients (HTTP, HTTP/2, HTTP/3, gRPC)

- HTTP/2 client: a graceful GOAWAY from the server no longer ends the
  connection at once; the streams it covers finish. A stream released
  after a GOAWAY is reset and freed once the session has closed it, never
  while the session can still reach it.
- HTTP/2 and HTTP/3 clients: a response's header fields are bounded by the
  new `ConnectOptions.max_header_list_size` (64 KiB, advertised to the
  server), and at most five informational (1xx) responses may precede the
  final one. Past either the stream fails with `error.HeadersTooLarge` or
  `error.TooManyInterimResponses` (new members of `StreamError`). The HTTP/2
  client also reads a final response that follows a 1xx correctly now.
- HTTP client: a URL whose path or query holds a space, a control
  character or a byte past 0x7f is refused with `error.InvalidUrl`, for
  `fetch`, redirects, WebSocket upgrades and HTTP/2 alike, instead of being
  written into the request line. Percent-encode such bytes; URLs that
  carried raw UTF-8 now fail (breaking).
- HTTP client redirects: across origins the `Referer` is only the origin
  (browsers' default policy); a 307 or 308 that would carry the body to
  another host is not followed, and its response is returned (breaking for
  callers that relied on it; `ClientConfig.check_redirect` can allow it).
  New: `ClientConfig.check_redirect` (follow, stop or fail each redirect)
  and `ClientConfig.deny_private_addresses` (refuse loopback, private,
  link-local and similar addresses, after DNS, on every hop). Redirects are
  followed in a loop, so the stack no longer grows with `max_redirects`.
- HTTPS client: a response body delimited by the end of the connection
  (no Content-Length, not chunked) now fails with
  `error.TlsConnectionTruncated` when the TLS connection ends without
  close_notify, instead of being returned as complete.
- TLS clients: the cache of trust stores built from CA bundles and the
  HTTP/3 session-ticket cache are keyed by SHA-256 of their contents, so
  two different CA sets or client identities can never share an entry.
- gRPC client: a call takes at most `Channel.max_received_bytes` (64 MiB,
  `CallOptions.max_received_bytes` per call) of response messages in all,
  then is canceled with RESOURCE_EXHAUSTED, so a server streaming without
  end cannot grow the caller's arena without bound. Response frames are read
  and inflated outside the arena and freed once decoded. Behaviour change
  for clients of streams that send more than 64 MiB.

#### JSON, gRPC and transcoding

- `anole.json.parse` / `readBody`: a whole-number float just past the range
  of an integer field (such as `9223372036854775808.0` for an `i64`) is
  refused as `error.Overflow` (400 from `readBody`) instead of stopping the
  process. No configuration change.
- `anole.json.parse`: input nested deeper than the new
  `ParseOptions.max_depth` (128) fails with `error.NestingTooDeep`, which
  only a type that contains itself can reach, and `YYJSON_READ_INSITU` in
  `ParseOptions.flags` is ignored (the input is read-only). `json.Error`
  gains `NestingTooDeep` (breaking for exhaustive switches).
- gRPC, gRPC-Web, Connect and transcoded routes: protobuf decoding is
  hardened (zig-protobuf with Anole's patches): messages and groups nest at
  most 100 levels, string and bytes lengths are checked against the input
  before memory is allocated for them, and Timestamps with an out-of-range
  month, day or time are refused. Connect and gRPC-Web JSON request
  messages nested deeper than 100 levels fail the call. Such requests fail
  with INTERNAL (INVALID_ARGUMENT, 400, on transcoded routes) instead of
  stopping the process or allocating up to 2 GiB. No configuration change.
- JSON transcoding: a query parameter can no longer override a field the
  path template sets when the template names it by its JSON name
  (`{bookId}`) and the query by its proto name (`?book_id=`), or the other
  way around. The path's value stands, as documented. No configuration
  change.
- gRPC: new per-registration limits (`RegisterOptions`). `read_timeout`
  (default 30 s) bounds how long a request message may take to arrive,
  which a call without `grpc-timeout` used not to bound at all;
  `max_received_bytes` (default 64 MiB) bounds what one call receives in
  all, since decoded messages stay in the call's arena; `max_call_duration`
  (default none) caps every call. A message frame's memory now grows with the
  bytes that arrive instead of being allocated in full from its 5-byte
  header, and frames are freed once decoded. Transcoded routes read the body
  under the server's request timeout before the call's deadline applies.
  Behaviour change: a client-streaming call that receives more than 64 MiB
  in all now fails with RESOURCE_EXHAUSTED; raise `max_received_bytes` for
  such services.
- JSON transcoding: a binding with a `body` answers 415 to a non-empty body
  whose `Content-Type` is not `application/json` (or `+json`). Breaking for
  clients that post JSON with another content type.
- gRPC: `Call.addTrailer` refuses names that are not metadata keys and
  values that are not printable ASCII (base64 text under a `-bin` name) with
  `error.InvalidMetadata`, so client data echoed into a trailer cannot add
  trailer lines in gRPC-Web. New `Call.addBinaryTrailer` encodes raw bytes.
  Breaking for handlers that passed raw bytes or upper-case names.

#### WebSocket and Server-Sent Events

- **Breaking:** WebSocket and WebTransport handshakes from a browser page of
  another origin are refused with 403. `UpgradeOptions.allowed_origins` and
  `webtransport.AcceptOptions.allowed_origins` default to `.same_origin`
  (the request's own host and port); list other origins with
  `.{ .list = &.{"https://app.example.com"} }`, or `.any` for endpoints that
  do not rely on cookies. Clients that send no `Origin` are not affected.
  C ABI WebSocket routes take `"origins"`. Apps whose pages connect from
  another origin must list it. See docs/websocket.md#origins.
- WebSocket over HTTP/1.1: the handshake must be a GET with a
  `Sec-WebSocket-Key` of 16 bytes in base64 (RFC 6455 §4.2.1); anything else
  is not upgraded.
- WebSocket over HTTP/1.1: a control frame whose header claims more than
  125 bytes, or that is fragmented, is refused (close 1002) before its
  payload is waited for, on callback sockets too; control-frame payloads no
  longer take memory from the message being assembled. No configuration
  change needed.
- WebSocket over HTTP/2 and HTTP/3: RSV1 on a control frame or a
  continuation is refused (close 1002) when permessage-deflate is in use; a
  ping or pong over 125 bytes from the handler fails with
  `error.LargeControlFrame`; a close goes out once even when two tasks
  close at the same time, and a frame cut short ends sending.
- WebSocket `Rooms`: a broadcast no longer waits for any member. It queues
  the message once for every member, and each member's own task sends its
  queue in order on the socket's executor. A member's queue is bounded
  (`Rooms.Options.max_queued_bytes`, 1 MiB); a member whose send has been
  stuck while its queue is full is closed (`on_full = .close`, the default,
  after `close_after_ms`) or skips messages (`.drop`). `broadcast` now
  returns for how many members the message was queued. New:
  `Rooms.initOptions`. Joining a room twice is one membership, so one
  `leave` always ends it.
- permessage-deflate buffers no longer come from the request's arena, which
  is not thread-safe over HTTP/1.1, so a broadcast compressing for a socket
  from another executor cannot corrupt it. The docs now say that
  `req.arena` and `call.arena` are not thread-safe.
- Server-Sent Events: a bare CR in event data now ends a `data:` line, as
  LF and CRLF already did (in `send` and in `startSend`'s writer, also when
  a CRLF is split across two writes). Before, data relayed from one user
  could add `event`, `id` or `retry` fields to the events other users got.
  No configuration change needed.

#### Sessions, cookies and auth

- `setCookie` refuses a `path` or `domain` containing `;` or a control
  character (`error.InvalidCookiePath`, `error.InvalidCookieDomain`), so a
  value taken from a request cannot add cookie attributes.
- Session cookies: `cookie_opts` of `anole.session.Config` and of
  `anole.http.middleware.Session.Config` is now `SessionCookieOpts`, whose
  every field defaults to the safe value. Setting one field (say
  `.{ .same_site = .none }`) used to reset the others to plain cookie
  defaults: no `HttpOnly`, no `Secure`, no `Path`. Breaking: the type
  changed and has no `max_age` (the middleware sets it); struct literals
  keep compiling.
- `anole.http.middleware.Session` (the HMAC-signed cookie): every cookie
  now carries a signed expiry (`max_age`, else the new `lifetime`, 24 h,
  renewed while the session is in use), and the signature covers the
  cookie's name. Cookies signed before this release are no longer accepted
  (users sign in again); no configuration change needed.
- Server-side sessions: a request that loaded a session before it was
  destroyed (a logout, `regenerate` from another request) no longer writes
  it back when it ends. The middleware now writes a session only when the
  request changed it, and only if it still exists (`Store.update`, Redis
  `SET ... XX`), and renews an unchanged one with `Store.touch` (Redis
  `EXPIRE`). `Store.VTable` has the two new optional entries; a custom store
  without them falls back to `load` + `save`, so implement them.
- `MemoryStore` sweeps expired sessions as new ones are written, and holds
  at most `max_entries` (100,000 by default, `MemoryStore.initOptions`);
  before, sessions created and never seen again (anonymous visitors, CSRF
  tokens on a login form) stayed in memory for good.
- `anole.session.regenerate` also drops the session's CSRF token, so a
  token from before a sign-in is not valid after it. Both session
  middlewares refuse a `__Host-`/`__Secure-` cookie name that their
  `cookie_opts` do not satisfy (`error.CookiePrefixMismatch`); docs/auth.md
  recommends `__Host-anole_session` in production.
- JWT: `Keyring.verify` (and so `RequireJwt` with a keyring) refuses a
  policy without an `audience` (`error.AudienceRequired`, 500 from
  `RequireJwt` with the fix in the log), since a provider's keys also sign
  tokens for its other clients. Action needed if you verify keyring tokens
  without an audience: set `.audience`, or `.allow_any_audience = true` for
  keys that sign for your application alone. New `Policy.typ` (e.g.
  `"at+jwt"`) checks the header's `typ`, and `Policy.require_iat` makes
  `iat` mandatory.
- JWKS `Keyring`: while the provider can't be reached, keys past their TTL
  stay in use for `stale_seconds` (24 h), and failed fetches back off
  (`retry_seconds` 5, doubling up to `max_retry_seconds` 300). Before, an
  outage failed every request with 503 and turned each one into another
  fetch. No configuration change needed.
- OIDC: ID tokens must carry `iat`; `azp`, when present, must be the
  `client_id` (before, it was checked only with several audiences); the
  token request no longer follows redirects (a 307/308 would have carried
  the code and client secret on); `Provider.discover` refuses non-`https`
  issuers and endpoints (`error.InsecureEndpoint`, loopback `http` aside).
  `Identity` gains `issuer`: key accounts on `(issuer, subject)`, as
  docs/auth.md now says.
- Rate limiting: `ratelimit.clientAddress` groups IPv6 clients by their /64
  (`clientAddressPrefix(bits)` for another prefix), so a client with a
  /64 no longer gets a bucket per address. `MemoryLimiter` never evicts a
  throttled bucket to make room for a new key (a full table sends new keys
  to a shared overflow bucket instead), and forgets an idle key only once
  its bucket has refilled; before, a stream of fresh keys, or waiting
  `idle_ms` on a long window, reset a client's limit. docs/auth.md's API key
  example now keys on the verified owner, not the raw header. Rate-limit
  keys of IPv6 clients change; no configuration change needed.
- `auth.apikey.generate` and `session.devKey` take their bytes from the
  operating system (`std.Io.randomSecure`) and fail rather than fall back
  to a weaker source; `apikey.generate` can now return
  `error.EntropyUnavailable`.

#### Response cache, request IDs, logs and metrics

- Response cache: requests with a TLS client certificate bypass it like
  those with `Authorization`/`Cookie`/`X-API-Key`, and the new
  `ResponseCache.Options.cacheable` predicate refuses others per route.
  docs/routing.md now warns up front that an answer depending on anything
  else (an app-specific header, the client's address) must be excluded
  through `credential_headers` or `cacheable`. Check your cached routes.
- `RequestId` with `trust_incoming` keeps an incoming ID only if it is 1 to
  128 of `[A-Za-z0-9._:-]` (before: any visible ASCII), and the JSON access
  log escapes `request_id`, `trace_id` and `span_id`: a client-chosen ID
  could add or override fields in the JSON line.
- Access logs (`observe.AccessLog`, `middleware.Logger`) leave the query
  string out by default (`log_query = true` keeps it), since queries carry
  sign-in codes, reset tokens and API keys. `access_log.format` drops it
  too; `formatLine` takes the option. Log consumers that parsed the query
  out of `path` need `log_query`.
- `app.metrics(.{ .listener = "admin" })`, `app.health(.{ .listener = ... })`
  (and `Registry.serveOnListener`, `Health.Options.listener`) serve
  `/metrics`, `/healthz` and `/readyz` on one named listener only, 404
  elsewhere. Without it they are on every listener, as before;
  docs/observability.md now says how to keep them off the public port,
  since they name routes, errors, databases and failing checks.

#### Databases

- **PostgreSQL connects to a remote server with `verify-full` when no
  `sslmode` is given (breaking).** A server on this machine (loopback, Unix
  socket) still gets `prefer`. Action: a server reached by a name or
  address its certificate does not carry, or signed by a private CA, now
  fails to connect; set `sslrootcert` (or `Options.tls.ca`), or set
  `sslmode` explicitly (`require` encrypts without checking, `disable`
  sends plain text). The log says which.
- **PostgreSQL sends the password in clear text or as MD5 only to a
  verified server or one on this machine (breaking).** Action, only for a
  server that still asks for `password` or `md5` over the network: move
  it to SCRAM-SHA-256, verify it, or allow the method with
  `require_auth=md5`. `require_auth` and `channel_binding` (SCRAM-SHA-256-PLUS,
  used whenever the server offers it over TLS) are new URL parameters.
- PostgreSQL connections are reset when they go back to the pool, so
  session settings, roles, temporary tables and advisory locks from one
  request never reach another (`Options.reset_session`, on; no extra round
  trip). No action needed.
- A CA set in code (`tls.ca` for PostgreSQL and Redis, `Options.tls` for
  MongoDB) can no longer be switched off by the URL or the environment:
  `sslmode=disable|allow|prefer`, `ssl_cert_reqs=none`, `tls=false` and
  `tlsInsecure`/`tlsAllowInvalid*` are refused there, and logged as
  warnings everywhere else.
- The PostgreSQL client checks message lengths and every value of a
  result row before decoding it, refuses `LISTEN` channel names over 63
  bytes, and checks SCRAM's server nonce and iteration count; MongoDB's
  SCRAM caps the iteration count at one million, and Redis refuses replies
  nested deeper than 32 levels. A malformed answer now fails the call and
  closes the connection instead of crashing the process. No action needed.
- A date or time column beyond what `anole.db.Time` holds (PostgreSQL and
  SQLite) fails that read instead of crashing. No action needed.
- SQLite limits expression depth to 1000 again (it was unlimited), and a
  `file:` path is a SQLite URI only with `Options.uri = true` (breaking
  for paths that relied on it; action: set `.uri = true`).
- A database URL whose password holds `/` or `?` no longer shows the
  password in logs, and MongoDB's connection-string errors no longer quote
  parts of the string. No action needed, but percent-encode such
  passwords.
- `exec` with no arguments runs every statement in its SQL (PostgreSQL,
  SQLite); the docs now say so: never build that SQL from input.

#### Process, startup, CI and examples

- With `ServerOptions.process` set, the server keeps systemd's `NOTIFY_SOCKET`
  for itself and takes it out of the environment that programs started by
  handlers inherit (a restart passes it to the new process). Sockets
  inherited through `LISTEN_FDS` are checked to be listening TCP/unix (or,
  for `h3`, UDP) sockets; anything else stops the start with
  `error.InheritedSocketMismatch`. A CPU quota that does not fit 32 bits no
  longer stops the start.
- `anole.panic` (`pub const panic = anole.panic;` in the root file; the
  examples and libanole use it): a panic is written as one error line with
  its stack trace through the log function, then the process aborts. The
  server logs its build mode at start and warns when it is ReleaseFast or
  ReleaseSmall; `addApp` warns at build time for those modes (the build is
  not refused).
- CI: a Release checks workflow runs h2spec, Autobahn, the HTTP/3 checks,
  the QUIC interop runner, gRPC interop and the C ABI suite against
  ReleaseFast builds, and the bundled C libraries under sanitizers, at every
  release tag. Actions are pinned by commit; downloads in the sanitizer
  script and the Python test packages are checked by hash.
- Examples model the safe patterns: `examples/rest` (and the
  getting-started guide) read the API key from `API_KEY`, keep its SHA-256
  and compare in constant time instead of a hard-coded key compared with
  `std.mem.eql`; `examples/observe` serves `/metrics`, the health routes and
  its `/maintenance` switch on a loopback-only admin listener (the next
  port) instead of the public one.

#### C ABI (code new since 0.1.0, listed above under C ABI)

- C ABI: a made-up WebSocket handle, a file length past the end of the file
  (`anole_respond_fd`), and a request body read after the request was
  answered are now refused (`ANOLE_E_GONE` / `ANOLE_E_INVALID`) instead of
  reaching memory they should not. No configuration change needed.
- C ABI: publishes still being fanned out to a topic are bounded (64 per
  executor, and the larger of 16 x `limits.ws_high_water` and
  2 x `limits.ws_max_message` bytes); past that `anole_ws_publish` returns
  `ANOLE_E_AGAIN` and sends nothing. A publish larger than
  `limits.ws_max_message` is refused (`ANOLE_E_INVALID`). Bindings should
  handle `ANOLE_E_AGAIN` from publish. Topics use `Rooms`' per-member
  queues (above), each bounded by `limits.ws_high_water`, so a subscriber
  that stops reading holds up no publish.
- C ABI configuration: `limits.inline_body_max` and `limits.ws_max_message`
  are capped at 1 GiB (larger values are a configuration error).
- C ABI configuration: a `jwt` middleware with `jwks_url` needs `audience`
  (or `allow_any_audience: true` for keys that sign for this application
  alone); without it the configuration is refused.
- C ABI configuration: a fixed (`respond`) route's headers are checked when
  the configuration is read: `Connection` and `Transfer-Encoding` (the
  server's own) and invalid names or values are refused there, instead of
  failing every request to the route.
- C ABI: replies and trailers naming `Connection` or `Transfer-Encoding`
  are refused with `ANOLE_E_INVALID` (the request is still owed), instead
  of those headers being dropped without a word.
- C ABI: WebSocket messages waiting for a consumer are bounded per executor
  in bytes (the larger of 16 x `limits.ws_high_water` and
  2 x `limits.ws_max_message`), not only in count, so clients cannot make a
  slow consumer's queue hold `limits.queue` whole messages.

### Breaking

Each item is described under Security above.

- Server: `res.header`/`res.addHeader` refuse `Transfer-Encoding` and
  `Connection` (use `res.keepalive = false`); HTTP/1.1 requests without
  exactly one `Host` get 400 (`request.require_host = false` restores the
  old behaviour); `X-Forwarded-Host` needs `trust_forwarded_host = true`;
  a malformed request body reads as `error.MalformedBody`.
- `http3.hq_interop_root` needs `pub const anole_hq_interop = true;` in the
  root file.
- TLS 1.2 listeners accept only ECDHE with AES-GCM or ChaCha20-Poly1305.
- HTTP client: URLs with raw spaces, control characters or non-ASCII bytes
  in the path or query fail with `error.InvalidUrl`; a 307/308 that would
  carry the body to another host is not followed. `StreamError` gains
  `HeadersTooLarge` and `TooManyInterimResponses`.
- JSON: `json.Error` gains `NestingTooDeep`.
- gRPC: a call receives at most 64 MiB in all on the server
  (`RegisterOptions.max_received_bytes`) and on the client
  (`Channel.max_received_bytes`); `Call.addTrailer` refuses invalid
  metadata (use `addBinaryTrailer` for raw bytes); transcoded bindings with
  a `body` answer 415 to a non-JSON `Content-Type`.
- WebSocket and WebTransport: handshakes from another origin get 403 unless
  listed in `allowed_origins`; `Rooms.broadcast` returns the number of
  members it queued for.
- Sessions: signed session cookies from 0.1.0 are refused (users sign in
  again); `cookie_opts` is now `SessionCookieOpts`; custom session stores
  should implement `Store.VTable.update` and `touch`.
- Auth: a JWKS `Keyring` policy needs an `audience` (or
  `allow_any_audience = true`); OIDC discovery refuses non-`https`
  endpoints; `apikey.generate` can return `error.EntropyUnavailable`;
  rate-limit keys of IPv6 clients are their /64.
- Logs: access logs leave the query string out unless `log_query = true`;
  incoming request IDs outside `[A-Za-z0-9._:-]` are replaced.
- Databases: PostgreSQL defaults to `sslmode=verify-full` for remote servers
  and sends clear-text or MD5 passwords only to a verified or local server;
  SQLite treats `file:` paths as URIs only with `Options.uri = true`.
- `examples/rest` reads its API key from the `API_KEY` environment variable.

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
