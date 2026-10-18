# Routing, requests and responses

What happens to a request once a listener has it: the router, middleware,
the request and response APIs, static files, compression, limits and errors.
Setting up the server is in [server.md](server.md). Every protocol reaches
the same router, so a handler answers HTTP/1.1, HTTP/2 and HTTP/3 alike.

## Routes

Register routes after any `use`:

```zig
app.get("/users/:id", getUser);
app.post("/users", createUser);
app.delete("/users/:id", deleteUser);
app.get("/files/*path", getFile);
app.any("/legacy/*path", legacy); // every method
```

The server has `get`, `head`, `post`, `put`, `patch`, `delete`, `options`,
`query` (the HTTP QUERY method: a GET with a body) and `any`, plus `static`
and `embedded` ([below](#static-files)).

- A literal segment matches itself, `:name` one segment, and `*name` the
  rest of the path (one or more segments).
- Literals win over `:params`, and `:params` over wildcards. The router
  backtracks, so `/users/new` and `/users/:id` can coexist.
- Empty segments are ignored: `/users/42/` matches `/users/:id`.
- HEAD with no route of its own is served by the GET route, without a body.
- A path with routes, but none for the method, gets 405 with `Allow`; a path
  with none at all gets 404.

Conflicts panic at registration, not on a request: the same route twice, two
`:params` with different names at one position, or an `any` route that
overlaps a method route without either being more specific.

## Path parameters and the query string

```zig
fn getUser(req: *anole.Request, res: *anole.Response) !void {
    const id = req.params.getInt(u64, "id") orelse return error.NotFound;
    const fields = req.query.get("fields") orelse "all";
    try res.print(.text, "user {d} ({s})", .{ id, fields });
}
```

`params` and `query` have `get`, `getInt`, `getFloat`, `count` and
`iterator`; `getInt` and `getFloat` return null for a missing or malformed
value. Path parameters are the raw bytes of the path, with percent-escapes
left as they are. Query values are decoded (`%XX` and `+`).

## Groups

A group adds a prefix and middleware to the routes registered through it.
Groups nest, and a nested group adds its middleware after its parent's.

```zig
const admin = app.group("/admin", .{RequireToken{ .token = "Bearer secret" }});
admin.get("/stats", adminStats); // GET /admin/stats
const reports = admin.group("/reports", .{});
reports.get("/:year", report); // GET /admin/reports/:year
```

As with `use`, the middleware values in the tuple are copied: the server owns
the copies and calls their `deinit`, if they have one, in its own. A value
listed in two groups is two copies. To share one, take a handle with
`app.middleware(value)` (one copy, owned by the server) and list the handle:

```zig
const sessions = app.middleware(anole.session.Middleware.init(.{ .key = key }));
app.group("", .{sessions}).get("/me", me);
app.group("", .{ sessions, anole.auth.csrf.Middleware.init(.{}) }).post("/notes", addNote);
```

A handle you make yourself, `anole.Middleware(Ctx).init(&value)`, points at a
value you keep alive and free; a slice of such handles works in place of the
tuple. With a context, use `anole.Middleware(App)`.

## Middleware

The chain runs global middleware (`use`, in the order added), then each
enclosing group's, then the handler. Global middleware also runs for 404s and
405s.

A middleware is a struct with an `execute` method of exactly this shape.
`executor.next()` runs the rest of the chain, and an error from the handler
comes back out of it; return that error so the server can answer it. Code
after `next()` runs once the handler is done. Return without calling it to
answer the request yourself.

```zig
const RequireToken = struct {
    token: []const u8,

    pub fn execute(self: *const RequireToken, req: *anole.Request, res: *anole.Response, executor: anytype) !void {
        if (!std.mem.eql(u8, req.headers.get("Authorization") orelse "", self.token)) {
            res.status = .unauthorized;
            res.body = "401 Unauthorized\n";
            return;
        }
        return executor.next();
    }
};

const Timing = struct {
    pub fn execute(_: *const Timing, req: *anole.Request, res: *anole.Response, executor: anytype) !void {
        const start: std.Io.Clock.Timestamp = .now(req.io, .awake);
        try executor.next();
        const us = start.durationTo(.now(req.io, .awake)).raw.toMicroseconds();
        const value = try std.fmt.allocPrint(req.arena, "app;dur={d}", .{@divTrunc(us, 1000)});
        // A handler that streamed has sent its headers already.
        res.header("Server-Timing", value) catch |err| switch (err) {
            error.HeadersAlreadySent => {},
            else => |e| return e,
        };
    }
};

app.use(Timing{});
```

### Built-in middleware

`anole.middleware` holds dusty's:

| Middleware | What it does |
| --- | --- |
| `RequestId.init(.{})` | Sets `req.id` (128 random bits, hex) and sends it as `X-Request-Id`. `.header` renames it; `.trust_incoming = true` keeps a valid incoming one (only behind a proxy that sets or strips it). |
| `Logger.init()` | One access-log line per request at `info`, scope `access` under `anole.logFn`: method, path, status or error, time, client, request ID. |
| `Compress.init()` | Sets `res.compress` on every response; see [Compression](#compression). |
| `Cors.init(.{ .origin = ... })` | `Access-Control-Allow-Origin` on every response; answers preflights with 204. Returns an error union. |
| `Session.init(.{ .secret_key = ... })` | `req.session` in a signed, not encrypted, cookie. Returns an error union. |

```zig
app.use(anole.middleware.RequestId.init(.{})); // first, so the rest see req.id
app.use(anole.middleware.Logger.init());
app.use(anole.middleware.Compress.init());
app.use(try anole.middleware.Cors.init(.{
    .origin = "https://app.example.com",
    .methods = "GET, POST, PUT, DELETE",
    .headers = "Content-Type, Authorization",
    .max_age = "600",
}));
```

Elsewhere in Anole: encrypted-cookie and server-side sessions, CSRF, API
keys, roles and rate limiting ([auth.md](auth.md)); a JSON or text access
log, metrics and tracing ([observability.md](observability.md)).

## The request

| Field or method | What it holds |
| --- | --- |
| `method`, `url` | The method, and the target with its query string. |
| `version_major` | 1, 2 or 3. |
| `params`, `query` | Path parameters and query values. |
| `headers.get(name)` | A header, case-insensitive. `:authority` fills `Host`. |
| `host()` | `X-Forwarded-Host` from a trusted proxy, else `Host`. |
| `remote_address`, `secure` | The client and whether its connection is TLS, after the PROXY protocol and trusted proxies. |
| `cookies().get(name)` | A cookie. |
| `content_type`, `content_length`, `content_encoding` | The body's metadata as it arrived. |
| `id`, `trace_id`, `span_id` | Set by the request ID and tracing middleware. |
| `route` | The matched route; `route.?.path` is its pattern. |
| `arena` | An allocator freed after the response. |
| `io` | The server's `std.Io`; see [Async work](#async-work-in-handlers). |

The body is read once, whole or as a stream:

- `body()` returns `?[]const u8` (null when empty), read into the arena up to
  `request.max_body_size` (1 MiB). Beyond that it fails with `BodyTooBig`,
  answered 413.
- `json(T)`, `jsonValue()` and `jsonObject()` parse with `std.json`; a body
  that does not parse or fit `T` is answered 400. `anole.json.readBody(T, req)`
  and `anole.json.respond(res, value)` do the same on the faster yyjson
  (`-Djson`), with the same 400s.
- `formData()` parses `application/x-www-form-urlencoded` and
  `multiFormData()` `multipart/form-data` (entries have `value` and
  `filename`); both return a map with `get`.
- `reader(buffer)` streams the body. It is not bounded by `max_body_size`;
  set `request.max_content_length` to refuse long bodies up front.

```zig
const NewUser = struct { name: []const u8, email: []const u8 };

fn createUser(req: *anole.Request, res: *anole.Response) !void {
    // An empty body: the std.json name for it, answered 400 like the rest.
    const user = try req.json(NewUser) orelse return error.UnexpectedEndOfInput;
    res.status = .created;
    try res.json(.{ .name = user.name }, .{});
}

fn echo(req: *anole.Request, res: *anole.Response) !void {
    var in_buf: [16 * 1024]u8 = undefined;
    var body = try req.reader(&in_buf);
    var out_buf: [16 * 1024]u8 = undefined;
    var out = try res.stream(&out_buf);
    _ = body.interface.streamRemaining(&out.interface) catch |err| switch (err) {
        error.ReadFailed => return body.err orelse error.Unexpected,
        error.WriteFailed => return out.err orelse error.Unexpected,
    };
    try out.end();
}
```

Compressed request bodies (gzip, deflate, zstd) are decoded before you read
them, and their `Content-Encoding` and `Content-Length` headers removed. A
coding Anole cannot undo is answered 415. `server.request.decompress = false`
turns this off.

## The response

Set fields or call a body helper. Nothing is sent before the handler returns
unless you stream.

```zig
res.status = .created;
res.content_type = .json; // .text, .html, .css, .js, .csv, .pdf, ...
try res.header("Location", "/users/42"); // replaces one of the same name
res.body = "{\"id\":42}"; // must outlive the handler: a literal or res.arena
```

| Method | Use |
| --- | --- |
| `print(content_type, fmt, args)` | A formatted body. |
| `json(value, options)` | A `std.json` body with its content type. |
| `encode(content_type, encodeFn, value)` | A body from a serializer's write-to-writer function. |
| `render(content_type, template, args)` | A body from a template function or type. |
| `writer()` | A buffered body writer; `end()` it before returning. |
| `stream(buffer)` | Sends the headers now and streams the body; `end()` it. |
| `startEventStream(buffer)` | Server-Sent Events: `send(data, .{ .event = ... })`. |
| `sendFile(dir, path, options)` | A file as the body. |
| `setCookie(name, value, options)` | Adds a `Set-Cookie`. |
| `trailer(name, value)` | A trailer field after the body. |
| `headers.add(name, value)` | Appends a repeated header. |

A buffered body leaves the headers open until the handler returns, so
middleware can still change them. After `stream`, `res.header` fails with
`HeadersAlreadySent`. A stream that outlives `timeout.request` should call
`req.setTimeout(.none)` first.

Trailers go out over HTTP/2 and HTTP/3, after a buffered or a streamed
body; HTTP/1.1 drops them.

```zig
try res.print(.text, "payload", .{});
try res.trailer("x-checksum", "abc123");
```

`sendFile` opens the file at once, so a missing one can still become a 404,
and sends it after the handler returns. It is never compressed and does no
ranges or conditional requests; static routes do.

```zig
fn download(_: *anole.Request, res: *anole.Response) !void {
    _ = res.sendFile(std.Io.Dir.cwd(), "reports/latest.pdf", .{ .resolve_beneath = true }) catch |err| switch (err) {
        error.FileNotFound => return error.NotFound,
        else => |e| return e,
    };
    res.content_type = .pdf;
}
```

WebSockets are in [websocket.md](websocket.md).

## Static files

`static` serves a directory, which must stay open while the server runs:

```zig
var public = try std.Io.Dir.cwd().openDir(io, "public", .{});
defer public.close(io);
app.static("/assets", public, .{
    .precompressed = &.{ .br, .zstd, .gzip },
    .cache_control = "public, max-age=3600",
});
```

- `ETag` and `Last-Modified`, with 304 for `If-None-Match` and
  `If-Modified-Since`; `Range` and `If-Range`, with 206 or 416.
- A directory serves its `index` (`index.html`; `null` makes it a 404), and
  a directory URL without its trailing slash is redirected (301).
- `..` out of the directory is a 404, and so are dotfiles such as `/.env`
  unless `.hide_dotfiles = false` (serve `/.well-known/` with its own route).
  Symlinks are followed unless `.resolve_beneath = true`, whose strength
  depends on the platform.
- `precompressed`: `style.css.br`, `.zst` or `.gz` is served for
  `style.css` to a client that accepts that coding, by its q-values and then
  your order, with `Vary: Accept-Encoding`. The plain file must exist too.
  This is the only way to serve Brotli; there is no runtime Brotli encoder.
- `cache_control` goes out with 200, 206 and 304.

`embedded` serves one file compiled into the binary, with the same
conditional and range handling and an `ETag` hashed from the content. Its
options are `content_type`, precompressed `br`, `zstd` and `gzip` copies,
`version` (a request whose `?v=` matches is cached for good) and
`cache_control`.

```zig
app.embedded("/favicon.ico", @embedFile("favicon.ico"), .{ .cache_control = "public, max-age=86400" });
```

## Compression

With `-Dcompression` (on in `web` and `full`), a response is compressed when
the handler sets `res.compress = true`, or always through `Compress`.

- zstd or gzip (zlib-ng) by the client's `Accept-Encoding` q-values, zstd on
  a tie. Streamed bodies are compressed as they are written.
- Only compressible types: text, JSON, JavaScript, XML, SVG, `+json` and
  `+xml` types and the like. Not images, video, fonts or archives.
- Buffered bodies under 128 bytes, or that do not shrink, go out as they are.
- `Vary: Accept-Encoding` is added; a strong `ETag` is weakened and
  `Accept-Ranges` dropped.
- Skipped when the handler set `Content-Encoding`, `Content-Length` or
  `Content-Range`, for 206 responses and for `sendFile` bodies.

## Timeouts and limits

These live in `ServerOptions.server`, for example
`.server = .{ .timeout = .{ .request = .fromSeconds(10) }, .request = .{ .max_body_size = 8 << 20 } }`.
Null disables a timeout.

| Field | Default | Covers |
| --- | --- | --- |
| `timeout.request` | 30 s | A whole request: reading it, the handler, writing the response; also the TLS handshake. |
| `timeout.read_header` | 10 s | The request head on HTTP/1.x (against Slowloris). |
| `timeout.keepalive` | 60 s | An idle connection between requests. |
| `timeout.request_count` | none | Requests per keep-alive connection. |
| `timeout.shutdown` | 30 s | The graceful drain. |

There are no separate read-body and write timeouts; both fall under
`timeout.request`. A handler can replace its own deadline:

```zig
req.setTimeout(.{ .duration = .{ .raw = .fromSeconds(300), .clock = .awake } });
req.setTimeout(.none); // a WebSocket or event stream
```

| `request` field | Default | Over the limit |
| --- | --- | --- |
| `max_body_size` | 1 MiB | `body()`, `json()` and forms fail: 413. Counted after decoding. |
| `max_content_length` | none | A larger declared `Content-Length` is a 413 before the handler runs. Bounds streams too. |
| `buffer_size` | 16 KiB | The request line and headers must fit: 431. |
| `max_header_count` | 32 | Request headers: 431. |
| `max_param_count`, `max_query_count` | 8, 32 | Path parameters and query values: 400. |
| `max_form_count`, `max_multiform_count` | 32, 32 | Form fields. |

`response.max_header_count` (64) caps the headers a response can carry,
those the server adds included; past it `res.header` fails with
`TooManyHeaders`. HTTP/2's limits are in `ServerOptions.http2`
([server.md](server.md#http2)).

## Error handling

A handler returns an error to give up:

- `error.NotFound` answers as if no route matched: 404.
- Request faults get a 4xx: `BodyTooBig` 413, `UnsupportedContentEncoding`
  415, a body that is not valid gzip, zstd or `std.json` 400.
- Anything else is logged at `err` and answered 500, and what the handler
  wrote is discarded.
- If the handler had started streaming, no 500 can be sent, so the
  connection is closed instead. If the client went away, nothing is logged.

Zig panics cannot be recovered: a panic in a handler (an unwrapped null, an
index out of bounds) ends the process. Return errors instead.

To answer errors, 404s and 405s yourself, declare any of these on `Ctx`:

```zig
const App = struct {
    pub fn notFound(_: *App, req: *anole.Request, res: *anole.Response) !void {
        res.status = .not_found;
        try res.json(.{ .@"error" = "not found", .path = req.url }, .{});
    }

    pub fn uncaughtError(_: *App, req: *anole.Request, res: *anole.Response, err: anyerror) void {
        std.log.err("{s} {s}: {t}", .{ req.id, req.url, err });
        res.status = switch (err) {
            error.SyntaxError, error.UnexpectedEndOfInput => .bad_request,
            error.BodyTooBig => .payload_too_large,
            else => .internal_server_error,
        };
        res.content_type = .json;
        res.body = "{\"error\":\"request failed\"}";
    }
};
```

`methodNotAllowed` has the same signature as `notFound`, and finds `Allow`
already set. `uncaughtError` replaces the built-in mapping, 4xx answers
included. A `Ctx` can also declare `dispatch(self, action, req, res)` to wrap
every handler call.

## Async work in handlers

Every handler gets the server's `std.Io` as `req.io`. A call through it that
has to wait (a socket, a file, a timer, an outbound request) suspends only
that request, and the executor serves others meanwhile. The code still reads
top to bottom.

```zig
fn slow(req: *anole.Request, res: *anole.Response) !void {
    try req.io.sleep(.fromMilliseconds(200), .awake);
    try res.print(.text, "done", .{});
}
```

Anything written against `std.Io` works this way: `std.Io.Dir` and
`std.Io.File`, `std.Io.net`, dusty's HTTP client (`anole.http.Client`; see
[clients.md](clients.md)) and database drivers built on them. A C library
that blocks in its own system calls holds the executor's thread until it
returns.

For several calls at once, use `req.io.concurrent` and await each future, or
cancel it on the way out after an error. Those tasks may run on other
executors and the request's arena is not thread-safe, so give each one memory
of its own. [examples/io](../examples/io/main.zig) makes two outbound
requests in parallel this way and reads files through the `Io`
(`zig build run-io`).
