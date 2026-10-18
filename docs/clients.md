# Outbound clients

Anole has four clients for calling other services. All of them run on the same
`std.Io` as the server, so a call that waits suspends one task and never blocks
a thread, and all of them use the same BoringSSL as the server.

| Client | Protocol | Use it for |
| --- | --- | --- |
| `anole.client(req)` | as `anole.http.Client` | The server's own pooled client, from any handler: nothing to set up. |
| `anole.http.Client` | HTTP/1.1, HTTPS, optionally HTTP/2 | Ordinary REST calls: one request at a time per connection, pooled keep-alive connections, redirects, decompression. |
| `anole.h2.ClientConnection` | HTTP/2 (TLS or h2c) | Many concurrent requests over one connection, full-duplex streaming, trailers. |
| `anole.h3.ClientConnection` | HTTP/3 over QUIC | The same as HTTP/2, over UDP. Same API. |
| `anole.grpc.Client(Service)` | gRPC over HTTP/2 | Calling gRPC services from generated code. |

`examples/clients` starts a server in-process and calls it with each client:

```sh
zig build run-clients
```

When in doubt, use `anole.client(req)` in a handler, or `anole.http.Client`
elsewhere. Use the HTTP/2 client when you make
many calls to one host at once, need to stream a body both ways, or need
trailers. Use the HTTP/3 client when the peer serves HTTP/3 and you want QUIC's
behaviour on lossy networks. The HTTP/2 and HTTP/3 clients need `-Dhttp2` and
`-Dhttp3`; TLS on any client needs `-Dtls=boringssl`. All are on by default.

## The server's client

Every `anole.Server` makes one HTTP client with its runtime, and frees it
with itself. A handler reaches it with `anole.client(req)` (or
`anole.client(io)` from any task of the server), on any server, with or
without state; `app.client()` returns the same one:

```zig
const Repo = struct { full_name: []const u8, stargazers_count: u64 };

fn stars(req: *anole.Request, res: *anole.Response) !void {
    var upstream = try anole.client(req).fetch("https://api.github.com/repos/ziglang/zig", .{
        .headers = &.{ .{ "User-Agent", "anole" }, .{ "Accept", "application/json" } },
    });
    defer upstream.deinit();
    if (upstream.status() != .ok) return error.BadGateway;
    const repo = try upstream.json(Repo, req.arena);
    try res.print(.text, "{s}: {d} stars\n", .{ repo.full_name, repo.stargazers_count });
}
```

- `fetch(url, options)` takes `method`, `headers` (inline pairs, up to 32),
  `body`, `timeout`, `max_redirects` and `decompress`.
- The response has `status()`, `header(name)`, `body()` (the whole body,
  `""` when there is none) and `json(T, allocator)`, which parses the body
  into `T`, skipping fields `T` does not have, with memory from `allocator`
  that outlives the response. It does not check the status.
- `deinit` hands the connection back to the pool. `.inner` is dusty's
  response, `.http` (on the client) dusty's client, for the rest of what
  `anole.http.Client` below offers.

It trusts the system's CA store and has the defaults below. A client with
other settings (CAs, a client certificate, HTTP/2) is an
`anole.http.Client` of your own.

## HTTP/1.1 and HTTPS

`anole.http.Client` is dusty's client. Create one, share it, and call `fetch`:

```zig
var client = anole.http.Client.init(gpa, io, .{});
defer client.deinit();

var response = try client.fetch("https://api.example.com/users/42", .{});
defer response.deinit(); // returns the connection to the pool
if (response.status() != .ok) return error.Upstream;
const body = (try response.body()) orelse "";
const content_type = response.headers().get("Content-Type");
```

`fetch` reads the whole body by default, up to `max_response_size` (10 MiB).
It sends `Accept-Encoding: gzip, deflate` and, when built with
`-Dcompression` (on by default), undoes gzip, deflate and zstd. The
response's memory lives until `deinit`. One client is safe to share between tasks; its pool keeps up to
`max_idle_connections` (8) idle connections and reuses them. The `gpa` you
pass must be thread-safe.

A request with headers and a body:

```zig
var headers = try anole.http.Headers.init(arena, 4);
try headers.put("Authorization", token);
try headers.put("Content-Type", "application/json");
var response = try client.fetch(url, .{ .method = .post, .headers = &headers, .body = json });
defer response.deinit();
```

Other `FetchOptions`: `max_redirects`, `timeout`, `decompress`, `stream`, and
`unix_socket_path` (for a server on a Unix socket, such as Docker's).

`ClientConfig.http2 = true` offers HTTP/2 ("h2", then "http/1.1") through
ALPN on HTTPS connections. A server that picks it gets the request over
HTTP/2, through `anole.h2`'s client underneath; `response.version().major`
says which was used. Everything above works the same, but such a connection
still carries one request at a time and goes back to the pool after it, so
it buys the protocol, not concurrency: for many requests at once on one
connection, use `anole.h2` directly. Cleartext (`http://`) requests and
WebSocket upgrades stay on HTTP/1.1. It is off by default.

## HTTP/2

`anole.h2.ClientConnection` is one connection on nghttp2. `connect` opens it
and starts its reader and writer tasks; every request is a stream on it.

```zig
const conn = try anole.h2.ClientConnection.connect(gpa, io, .{
    .host = "api.example.com",
    .port = 443,
    .tls = .{}, // the system trust store
});
defer conn.close();

const s = try conn.request(&.{
    .{ .name = ":method", .value = "GET" },   .{ .name = ":path", .value = "/users/42" },
    .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "api.example.com" },
    .{ .name = "accept", .value = "application/json" },
}, .{});
defer s.release();
try s.waitHead(); // s.status, s.headers, s.header("content-type")
const body = try s.reader().allocRemaining(gpa, .limited(1 << 20));
defer gpa.free(body);
```

- You write the pseudo-headers yourself, first and in lower case. They are
  copied, so they can be temporary.
- With `.tls = null` the connection is cleartext HTTP/2 with prior knowledge
  (h2c), as Anole's cleartext listener accepts it.
- With TLS, the client offers ALPN "h2" only. `connect` fails with
  `error.NoH2` if the server does not pick it, with `error.Timeout` past
  `connect_timeout`, or with the TLS error (such as
  `error.CertificateIssuerNotFound` for a certificate nothing it trusts
  vouches for).
- `host` is used for the TLS name check and SNI; set `address` to connect to a
  specific address without resolving `host`.
- `release` every stream you open, before `close`. Releasing an unfinished
  stream resets it (RST_STREAM CANCEL); `cancel` does that without releasing.
- `waitHead` fails with `error.StreamReset`, `error.ConnectionClosed`,
  `error.Timeout` (see [Timeouts](#timeouts)) or `error.Canceled`. A read or
  write on a stream that ended early fails with `error.ReadFailed` or
  `error.WriteFailed`, the only errors a reader and a writer can return;
  `s.readError()` and `s.writeError()` say which of those four it was.
- A stream's `status`, `headers` and `trailers` live until `release`; copy
  what you keep.

## HTTP/3

`anole.h3.ClientConnection` has the HTTP/2 client's API on ngtcp2 and
nghttp3. Use `":scheme" = "https"`; QUIC is always TLS.

```zig
const conn = try anole.h3.ClientConnection.connect(gpa, io, .{
    .host = "localhost",
    .port = 8443,
    .tls = .{ .ca = .{ .pem = dev_cert_pem } },
});
defer conn.close();
```

Each connection binds its own UDP socket. `connect` returns after the
handshake, and fails with `error.HandshakeFailed` (a certificate it does not
trust among other causes), `error.Timeout` (past `connect_timeout`, 10 s by
default) or `error.NoH3`. `timeout` is each request's budget, as for
HTTP/2. The other `ConnectOptions` are `stream_window` (256 KiB), `max_data`
(16 MiB) and `idle_timeout_ms` (30 s). `anole.h3` exports the names
`anole.h2` does: `ClientConnection`, `Stream` (also as `ClientStream`),
`Header`, `ConnectOptions`, `RequestOptions` and `StreamError`.

The client does not discover HTTP/3 from `Alt-Svc`, retry over TCP, or send
0-RTT data. Connect to it when you know the server speaks it.

## TLS options

The three clients take the same TLS fields (`anole.http.TlsConfig`'s), and
all of them trust the system store unless told otherwise:

| Need | `.tls = ...` |
| --- | --- |
| System trust store | `.ca = .system` (the default) |
| A CA file or directory | `.ca = .{ .file = .{ .path = "ca.pem" } }`, or `.dir` |
| A CA in memory | `.ca = .{ .pem = ca_pem }` (one or more certificates) |
| Skip verification (tests only) | `.insecure_skip_verify = true`, optionally `.ca = .none` |
| Client certificate (mutual TLS) | `.client_certificate = .{ .cert_path = "client.pem", .key_path = "client.key" }`, or `.{ .pem = .{ .cert = cert_pem, .key = key_pem } }` |
| ALPN | `anole.http`: none, or "h2" and "http/1.1" with `.http2 = true`; `anole.h2`, `anole.h3`: "h2" or "h3", fixed |

`ca` is an `anole.http.TlsCa`. `.none` without `insecure_skip_verify` fails
with `error.NoCertificateAuthority`.

When it is read:

- `anole.http.Client` reads its CA and client certificate on its first
  HTTPS request and keeps them for every connection it makes; PEM given in
  memory must stay alive until then. Use a second client for different TLS
  settings.
- `anole.h2` and `anole.h3` load the system store once per process, on the
  first `connect` that needs it, and keep it. A file, directory or PEM CA
  and a client certificate are read on each `connect` (the CA's BoringSSL
  store is cached by its contents), so connect once and share the
  connection. PEM need only live through `connect`.

Paths are relative to the current directory, or to `dir` when you set one
(`.{ .path = "ca.pem", .dir = some_dir }`). A client key must be PKCS#8 or
SEC1 PEM without a passphrase.

To trust a development certificate from `anole.tls.selfSigned`, pass its
`cert` (not the key) as `.ca = .{ .pem = pem.cert }`, as `examples/clients`
does. The certificate is its own CA and names `localhost`, `127.0.0.1` and
`::1`. An IP literal as the host is checked against the IP names, and no
SNI is sent for it.

## Timeouts

`anole.http.Client` has one budget per `fetch`: connecting, the handshake,
sending, every redirect, and reading the body. It is `ClientConfig.timeout`
(30 s by default; null for none), or `FetchOptions.timeout` for one request:

```zig
var response = try client.fetch(url, .{ .timeout = .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } } });
```

Past it, `fetch` fails with `error.Timeout`. With `.stream = true` the budget
ends at the response head; the body is read on your time.

The HTTP/2 and HTTP/3 clients have two, with the same names in both:

- `ConnectOptions.connect_timeout` (10 s): resolving the host, connecting and
  the TLS (or QUIC) handshake. Past it, `connect` fails with
  `error.Timeout`.
- `ConnectOptions.timeout` (30 s): each request's budget, from `request` to
  the end of the response body. `RequestOptions.timeout` replaces it for one
  request: a duration, a deadline, or `.none` for a long-lived stream. Null
  for either means no limit.

Past a request's budget the stream is reset. `waitHead` fails with
`error.Timeout`; a read or write fails with `error.ReadFailed` or
`error.WriteFailed`, and `s.readError()` or `s.writeError()` returns
`error.Timeout`:

```zig
const s = try conn.request(headers, .{ .timeout = .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } } });
defer s.release();
try s.waitHead();
const body = s.reader().allocRemaining(gpa, .limited(1 << 20)) catch |err| switch (err) {
    error.ReadFailed => return s.readError() orelse err, // error.Timeout, error.StreamReset, ...
    else => |e| return e,
};
```

gRPC calls set their stream's budget from `CallOptions.timeout`, and have
none without it. A task canceled from outside (zio's `withTimeout` around a
call, say) sees `error.Canceled` the same way.

## Streaming bodies

With `anole.http.Client`, the request body is one slice. To read a response
as it arrives, ask for the stream and read it through a buffer:

```zig
var response = try client.fetch(url, .{ .stream = true });
defer response.deinit();
var buf: [16 * 1024]u8 = undefined;
var body = try response.reader(&buf);
_ = body.interface.streamRemaining(&file_writer.interface) catch |err| switch (err) {
    error.ReadFailed => return body.err orelse error.Unexpected,
    else => |e| return e,
};
```

A streamed body is not limited by `max_response_size`. A response released
with its body unread is drained in the background (up to 256 KiB) so its
connection can be reused, or else closed.

With HTTP/2 and HTTP/3, both directions stream. Open the request with
`.body = true`, write through `s.writer()` (`flush` sends what is buffered),
and end the body with `s.closeSend()`. Read the response through `s.reader()`.
With HTTP/2, a body you already hold whole can go as `.body_bytes = bytes`
instead: it is copied and sent as the server takes it, while you wait for
the response.
If the server answers while the body is still going out, as an echo does,
write from a second task, or the two sides fill each other's windows and
stop:

```zig
const s = try conn.request(headers, .{ .body = true });
defer s.release();
var sender = try io.concurrent(sendBody, .{ s, payload }); // writeAll, then closeSend
try s.waitHead();
const n = try s.reader().discardRemaining();
try sender.await(io);
```

On an error before `await`, cancel the sender instead. Flow control follows
the reader: the server gets more window only as you take bytes, so a slow
reader slows the server rather than filling memory.

## Trailers

HTTP/2 and HTTP/3 responses can end with trailers. They are in `s.trailers`
once the reader reports the end of the body:

```zig
const body = try s.reader().allocRemaining(gpa, .unlimited);
const checksum = s.trailer("x-checksum"); // null if absent
```

The client sends no request trailers. `anole.http.Client` exposes none either.

## Many requests on one connection

One `anole.h2.ClientConnection` or `anole.h3.ClientConnection` is safe to
share between tasks: each task opens its own streams, and they run at once.
One stream belongs to one task, except that one task may write its body while
another reads its response.

```zig
var group: std.Io.Group = .init;
defer group.cancel(io);
for (ids) |id| try group.concurrent(io, fetchOne, .{ conn, id });
try group.await(io);
```

When the server's concurrent-stream limit is reached, HTTP/3's `request` waits
for a slot, and nghttp2 holds an HTTP/2 request until one frees. After the
server's GOAWAY, or after `close` has begun, `request` fails with
`error.ConnectionClosed`; open a new connection then. Do not call `close` while
other tasks still use the connection.

## Calls from handlers

Handlers get the server's `std.Io` as `req.io`. A client call through it
suspends that request only; the executor serves others meanwhile.

- Use `anole.client(req)`, or keep an `anole.http.Client` of your own in
  your context, created with `server.io()`, as `examples/io` does. Its
  `/fanout` route makes two calls at once with `io.concurrent`.
- Keep HTTP/2 and HTTP/3 connections in your context too, rather than one per
  request: connecting costs a handshake. `examples/clients` opens one per
  request in `GET /relay` only to stay short.
- The request's arena (`req.arena`) is not thread-safe. Give a task you start
  with `io.concurrent` its own buffer or allocator.
- Pass a thread-safe allocator to `connect` and `Client.init`; the
  connection's tasks may run on other executors.

## gRPC

`anole.grpc.Client(Service)` calls a service from the code zig-protobuf
generates, over an `anole.h2.ClientConnection`:

```zig
var channel: anole.grpc.Channel = .{ .conn = conn, .authority = "localhost", .scheme = "https" };
const health: anole.grpc.Client(anole.grpc.health.pb.Health(anole.grpc.Call, anyerror)) = .{ .channel = &channel };
const result = try health.unary("Check", arena, .{ .service = "" }, .{ .timeout = .fromSeconds(2) });
// result.status.code, result.message
```

`unary` covers unary calls; `stream` covers the streaming kinds. `timeout` is
sent as `grpc-timeout` and bounds the stream on the client side too. Many calls can share one connection. See
[gRPC: the client](grpc.md#the-client) for streams, metadata, compression and
status codes.

## Outside a server

In a program with no `anole.Server`, such as a CLI tool or a test, start a
runtime yourself and use its `Io`. Anole's build already gives zio pinned
scheduling, so the root file needs no `zio_options`, as for a server.

```zig
const rt = try anole.zio.Runtime.init(gpa, .{});
defer rt.deinit();
const io = rt.io();
var client = anole.http.Client.init(gpa, io, .{});
defer client.deinit();
```
