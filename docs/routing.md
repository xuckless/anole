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
`query` (the HTTP QUERY method: a GET with a body) and `any`, plus `static`,
`staticDir` and `embedded` ([below](#static-files)) and `ws` for WebSockets
([websocket.md](websocket.md)).

A handler takes the request and the response. On a `Server(App)` it may take
a `*App` first as well; one that does not need the state leaves it out:

```zig
fn health(_: *anole.Request, res: *anole.Response) !void { res.body = "ok"; }
fn count(app: *App, _: *anole.Request, res: *anole.Response) !void { ... }

app.get("/health", health); // (req, res) on a Server(App) too
app.get("/count", count);
```

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
overlaps a method route without either being more specific. In a test build
the router records the first conflict instead of panicking: `run`, `listen`
and `anole.testing.client` fail with `error.RouteConflict` and
`app.routeConflict()` has the message.

### Paths are checked when you compile

The route methods (`get`, `post`, ..., `any`, `ws`, `webtransport`, and the
same on groups) take their `path` at compile time and refuse a malformed
pattern with a compile error that names the route:

```
error: anole: route GET /a/*x/b: a wildcard (*x) must be the last segment
```

The rules: the path starts with `/`; a `:` or `*` is followed by a name that
holds neither; a wildcard is the last segment; a parameter name appears once
in a path; no `?` or `#` (a route matches the path only: read the query with
`req.query`, `req.bindQuery` or `anole.In`). For a path known only at run
time (read from configuration), use `app.addRoute(method, path, handler)`
(`null` is every method), which checks the same way when it registers: a
panic, or a recorded conflict in test builds. Static prefixes, group
prefixes and the C ABI's routes get the same check at startup
(`ANOLE_E_CONFIG` naming the route).

## Typed handlers

A handler can name what it reads and what it returns, and Anole does the
binding and the answer:

```zig
fn update(req: *anole.Request, in: anole.In(.{ .path = struct { id: u64 }, .body = UpdateUser })) !User {
    return store.update(req, in.path.id, in.body);
}
app.put("/users/:id", update); // 200 with the User as JSON
```

The shape is `fn ([ctx: *Ctx,] req: *anole.Request, [res: *anole.Response,]
[in: anole.In(...)]) [E!]Out`. A handler that is exactly `(req, res)` or
`(ctx, req, res)` returning `void` is *plain*: it answers itself, as always.
Any other handler of this shape is typed:

- **Inputs.** `anole.In(.{ .path, .query, .headers, .body })` is bound before
  the handler runs: the path first (a mismatch is a 404), then query, headers
  and body, whose violations come back together as one 422
  ([validation.md](validation.md)). Compile-time checks: the spec's keys and
  types, a path field that is not a parameter of the route, `.body` on a
  GET or HEAD.
- **Output.** A result other than `void` is written with `res.json`, with
  status 200 or the type's own: `anole.Created(T)` (201, with an optional
  `Location`: `return .{ .value = todo, .location = "/todos/7" }`),
  `anole.Accepted(T)` (202) and `anole.WithStatus(.status, T)` for any 2xx. A
  handler that takes `res` and changed `res.status` keeps its status. With
  `T = void` (`anole.WithStatus(.no_content, void)`, `anole.Created(void)`,
  `anole.Accepted(void)`) only the status (and `Location`) is sent, no body.
- **Void.** A typed handler that takes `res` answers itself; one that does
  not, answers 204.
- **Errors.** Returned errors map as for any handler (`error.NotFound`, a
  status-named error, `error.ValidationFailed` for a 422).

`anole.routeInfo(handler)` reads a handler's signature (inputs, output,
declared errors, `takes_res`, `typed`, `no_wait`, `cached`), also through
`anole.noWait` and `anole.cached`; tools that describe routes (the OpenAPI
document, [openapi.md](openapi.md)) use it. `anole.cached` is only for GET and HEAD routes: on another method it is a
compile error.

## Path parameters and the query string

```zig
fn getUser(req: *anole.Request, res: *anole.Response) !void {
    const id = req.params.getInt(u64, "id") orelse return error.NotFound;
    const fields = req.query.get("fields") orelse "all";
    try res.print(.text, "user {d} ({s})", .{ id, fields });
}
```

`req.param("id")` and `req.queryParam("fields")` are the short forms of
`req.params.get` and `req.query.get`. `params` and `query` have `get`,
`getInt`, `getFloat`, `count` and `iterator`; `getInt` and `getFloat` return null for a missing or malformed
value. Path parameters are the raw bytes of the path, with percent-escapes
left as they are: matching runs on the raw path, so an encoded `/` (`%2F`)
never splits a segment. `req.paramDecoded("name")` gives the decoded text
(into the request's arena; `+` stays `+`), and `error.BadRequest` (400) for
a `%` not followed by two hex digits. Query values are decoded (`%XX` and
`+`).

```zig
// GET /users/J%C3%BCrgen
const name = (try req.paramDecoded("name")).?; // "Jürgen"; req.params keeps "J%C3%BCrgen"
```

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
const sessions = app.middleware(try anole.session.Middleware.init(.{ .key = key }));
app.group("", .{sessions}).get("/me", me);
app.group("", .{ sessions, anole.auth.csrf.Middleware.init(.{}) }).post("/notes", addNote);
```

A handle you make yourself, `anole.Middleware(Ctx).init(&value)`, points at a
value you keep alive and free; a slice of such handles works in place of the
tuple. With a context, use `anole.Middleware(App)`.

`with` is a group without a prefix: middleware for the routes registered
through it, and no others.

```zig
app.with(.{requireAdmin}).delete("/users/:id", deleteUser);
app.get("/users/:id", getUser); // not behind requireAdmin
```

## Middleware

The chain runs global middleware (`use`, in the order added), then each
enclosing group's, then the handler. Global middleware also runs for 404s and
405s. An `OPTIONS` to a path whose routes are for other methods (a CORS
preflight) runs the middleware of the route it asks about, group middleware
included, so a group's `Cors` can answer it.

The short form is a function that takes the request, the response and an
`anole.Next`. `next.call()` runs the rest of the chain, and an error from
the handler comes back out of it; return that error so the server can answer
it. Code after it runs once the handler is done. Return without calling it to
answer the request yourself. `use`, `group` and `with` take the function as
it is (or wrapped, `anole.func(requireKey)`); on a `Server(App)` it may take
the `*App` first.

```zig
fn requireKey(req: *anole.Request, res: *anole.Response, next: anole.Next) !void {
    if (req.headers.get("X-Api-Key") == null) return res.fail(.unauthorized, "missing API key");
    return next.call();
}

app.use(requireKey);
```

A middleware with settings of its own is a struct with an `execute` method
of the same shape, taking the chain as `next` and calling `next.call()`
exactly as a function middleware does:

```zig
const RequireToken = struct {
    token: []const u8,

    pub fn execute(self: *const RequireToken, req: *anole.Request, res: *anole.Response, next: anytype) !void {
        if (!std.mem.eql(u8, req.headers.get("Authorization") orelse "", self.token))
            return res.fail(.unauthorized, "");
        return next.call();
    }
};

const Timing = struct {
    pub fn execute(_: *const Timing, req: *anole.Request, res: *anole.Response, next: anytype) !void {
        const start: std.Io.Clock.Timestamp = .now(req.io, .awake);
        try next.call();
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

A middleware that never waits (no I/O, no sleep, no lock or event another
task releases) says so with `pub const no_wait = true;`, or with
`pub fn noWait(self: *const T) bool` when that depends on how the value was
set up (asked once, at registration); a function middleware says it by being
wrapped, `app.use(anole.noWait(f))`. Routes marked `noWait` take only such
middleware (see below).

### Built-in middleware

`anole.middleware` holds the HTTP core's, and `ResponseCache`. Sessions,
CSRF, auth and rate limits have their own namespaces (`anole.session`,
`anole.auth`, `anole.ratelimit`); see [auth.md](auth.md).

| Middleware | What it does |
| --- | --- |
| `RequestId.init(.{})` | Sets `req.id` (128 random bits, hex) and sends it as `X-Request-Id`. `.header` renames it; `.trust_incoming = true` keeps a valid incoming one (only behind a proxy that sets or strips it). |
| `Logger.init(.{})` | One access-log line per request at `info`, scope `access`: method, path (no query; `Logger.init(.{ .log_query = true })` logs it), status or error, time, client, request ID. |
| `Compress.init(.{})` | Sets `res.compress` on every response; see [Compression](#compression). |
| `Cors.init(.{})` | CORS for browsers: any origin by default, preflights answered with 204; see [CORS](#cors). |
| `ResponseCache` | Whole responses kept per executor and answered from memory; see [Response cache](#response-cache). |

```zig
app.use(anole.middleware.RequestId.init(.{})); // first, so the rest see req.id
app.use(anole.middleware.Logger.init(.{}));
app.use(anole.middleware.Compress.init(.{}));
app.use(anole.middleware.Cors.init(.{}));
```

### CORS

`Cors.init(.{})` lets a page on any origin call the API without
credentials, as Fiber's `cors.New()` does: `Access-Control-Allow-Origin: *`
on every response, and a preflight (an `OPTIONS` with `Origin` and
`Access-Control-Request-Method`) answered 204 with
`Access-Control-Allow-Methods` (GET, HEAD, POST, PUT, PATCH, DELETE), the
`Access-Control-Allow-Headers` the browser asked for, and
`Access-Control-Max-Age: 600`. A preflight never reaches a route.

| Field | Default | Meaning |
| --- | --- | --- |
| `origins` | any | Allowed origins as the browser sends them (`"https://app.example"`). A listed origin is echoed back with `Vary: Origin`; any other gets no CORS headers, and a preflight from it a bare 204. |
| `origin` | none | One origin, or `"*"`: the older single-origin form, still accepted. |
| `methods` | `GET, HEAD, POST, PUT, PATCH, DELETE` | `Access-Control-Allow-Methods`. |
| `headers` | what the preflight asks for | `Access-Control-Allow-Headers`. |
| `expose` | none | `Access-Control-Expose-Headers`, response headers a page's script may read. |
| `credentials` | false | Cookies and HTTP authentication across origins (`Access-Control-Allow-Credentials`). Needs `origins`: with any origin, `init` panics. |
| `max_age` | 10 minutes | How long a browser may reuse a preflight answer (an `anole.Duration`, sent in whole seconds); null sends none. |

```zig
app.use(anole.middleware.Cors.init(.{
    .origins = &.{ "https://app.example.com", "https://admin.example.com" },
    .credentials = true,
    .expose = "X-Request-Id",
}));
```

`Cors` works in a group too: for an `OPTIONS` to a path whose routes are all
for other methods, the router runs the middleware of the route the preflight
asks about, so the group's `Cors` answers it. Put `Cors` ahead of
middleware that refuses requests (authentication): a preflight carries no
credentials.

### Response cache

A route can have its answers kept and served from memory, without running
its handler, for a while:

```zig
app.get("/feed", anole.cached(.{ .ttl = .fromSeconds(5) }, feed));
```

> **A cached answer is served to everyone who asks for the same URL.** The
> cache skips requests with `Authorization`, `Cookie`, `X-API-Key` or a TLS
> client certificate, but it can't know every way your app tells users
> apart. If a route's answer depends on a header of your own, the client's
> address, or anything set by middleware before the cache, add that header
> to `credential_headers`, or refuse those requests with `cacheable`;
> otherwise one user's page goes to the next. Authentication that runs
> after the cache is skipped on a hit, so put it before the cache.

```zig
// A session token in a header of the app's own.
app.get("/me", anole.cached(.{ .ttl = .fromSeconds(5), .credential_headers = &.{ "Authorization", "Cookie", "X-API-Key", "X-Session-Token" } }, me));
// Any per-request rule.
fn anonymousOnly(req: *const anole.Request) bool {
    return req.headers.get("X-Tenant") == null;
}
app.get("/news", anole.cached(.{ .ttl = .fromSeconds(5), .cacheable = anonymousOnly }, news));
```

One cache for several routes is `app.responseCache`, used through `with`,
`group` or `use`, and invalidated when what it serves changes:

```zig
const App = struct { db: *anole.pg.Client, pages: *anole.middleware.ResponseCache };

state.pages = app.responseCache(.{ .ttl = .fromSeconds(60), .name = "pages" });
app.with(.{state.pages}).get("/posts/:id", showPost);
app.put("/posts/:id", editPost);

fn editPost(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const id = req.params.get("id").?;
    // ... the update ...
    app.pages.invalidate(.{ .path = try std.fmt.allocPrint(req.arena, "/posts/{s}", .{id}) });
    res.status = .no_content;
}
```

What is kept:

- Answers to `GET`. A `HEAD` is answered from a kept `GET`; other methods
  pass through.
- Statuses a cache may keep without being told: 200, 203, 204, 300, 301,
  308, 404 and 410. Not errors, not 304.
- Bodies held in memory: not `sendFile`, a stream, an event stream, a
  WebSocket upgrade, or a response with trailers. At most
  `max_entry_bytes` (1 MiB).
- The headers the route set (and middleware after the cache), replayed on
  a hit. Middleware before the cache runs on every request as usual, so its
  headers (`X-Request-Id`, CORS for the caller's origin) are fresh.

What is not:

- A response that sets a cookie, or whose `Cache-Control` says `no-store`,
  `no-cache` or `private`. Its `s-maxage`, else `max-age`, is how long it is
  kept (0: not at all); with neither, the cache's `ttl` (10 s by default).
- Requests that carry credentials (`Authorization`, `Cookie`, `X-API-Key`;
  `credential_headers`), or a TLS client certificate: they neither read the
  cache nor fill it. Nor do requests `cacheable` returns false for.
  `.authenticated = true` lets them, for routes whose answer does not depend
  on who asks: the credentials are not part of the key.
- `Vary: *`. Other `Vary` headers are honoured: each combination of the
  named request headers is kept apart.

The key is the scheme, the `Host` header and the target, query included as
sent. Each executor keeps its own entries (no lock between threads), so two
executors may answer from responses up to `ttl` apart; `invalidate(.all)`
and `invalidate(.{ .path = "/posts/7" })` (every query and `Vary` variant
of that path) reach every executor at once. The bounds (`max_entries`,
1024; `max_bytes`, 16 MiB) are split between the executors, least recently
used first out. With `app.metrics`, each cache reports
`anole_cache_hits_total`, `anole_cache_misses_total`,
`anole_cache_stores_total`, `anole_cache_evictions_total`,
`anole_cache_entries` and `anole_cache_bytes`, labelled `kind="http"` and
its name (the route's path for `anole.cached`); `cache.stats()` has the
same numbers.

The body is kept as the handler wrote it, so with `Compress` each hit is
compressed again for its client.

When not to use it:

- Pages that differ by who asks, unless the difference is in the URL or a
  `Vary` header: a session read from a cookie makes the request bypass the
  cache, but a user identified some other way (a header not in
  `credential_headers`, the client's address) would get another user's page.
  Add such headers to `credential_headers`, refuse those requests in
  `cacheable`, or keep the cache off the route.
- Anything that must show a write at once, unless the write invalidates it.
- Routes behind authorization middleware that runs after the cache (a
  route's own `with`, in a group whose cache comes first): a hit skips it.
  Put authentication before the cache, or the cache on public routes only.
- Large downloads and files: `staticDir` already serves files with ETags
  and ranges.

For rows rather than responses, see [Caching](database.md#caching).

Elsewhere in Anole: encrypted-cookie and server-side sessions, CSRF, API
keys, roles and rate limiting ([auth.md](auth.md)); a JSON or text access
log, metrics and tracing ([observability.md](observability.md)).

## The request

Fields starting with `_` (`req._parser`, `res._conn`, ...) and
`X.internal` / `X.Driver` declarations are Anole's: the engines use them, and
they change without notice. Ask `res.headersSent()` rather than reading
`res._headers_written`; `ws.httpVersion()` and `ws.isClosed()` rather than a
socket's internals.

| Field or method | What it holds |
| --- | --- |
| `method`, `url` | The method, and the target with its query string. |
| `version_major` | 1, 2 or 3. |
| `params`, `query` | Path parameters (raw, percent-encoded; `paramDecoded(name)` decodes) and query values (decoded). |
| `headers.get(name)` | A header, case-insensitive. `:authority` fills `Host`. |
| `host()` | `X-Forwarded-Host` from a trusted proxy, else `Host`. |
| `remote_address`, `secure` | The client and whether its connection is TLS, after the PROXY protocol and trusted proxies. |
| `cookies().get(name)` | A cookie. |
| `content_type`, `content_length`, `content_encoding` | The body's metadata as it arrived. |
| `id`, `trace_id`, `span_id` | Set by the request ID and tracing middleware. |
| `setLocal(key, value)`, `local(T, key)` | Values a middleware hands to the handler for this request; see [Request locals](#request-locals). |
| `route` | The matched route; `route.?.path` is its pattern. |
| `arena` | An allocator freed after the response. Not thread-safe: only the handler's task may use it. |
| `io` | The server's `std.Io`; see [Async work](#async-work-in-handlers). |

The body is read once, whole or as a stream:

- `body()` returns `?[]const u8` (null when empty), read into the arena up to
  `limits.body_max` (1 MiB). Beyond that it fails with `BodyTooBig`,
  answered 413.
- `bind(T)` parses the body as JSON into a `T` (`std.json`, in the
  request's arena). Fields `T` does not have are ignored; a missing body
  fails with `error.MissingBody` and one that does not parse or fit `T` with
  `error.InvalidJsonBody`, both answered 400. `bindWith(T, options)` takes
  `std.json`'s parse options as they are (their default refuses unknown
  fields). `json(T)` is `bind` with null for an empty body;
  `jsonValue()` and `jsonObject()` parse into `std.json.Value`.
  `anole.json.readBody(T, req)` and `anole.json.respond(res, value)` keep
  the same contract on yyjson (`-Djson`), which pays off for large
  documents.
- `formData()` parses `application/x-www-form-urlencoded` and
  `multiFormData()` `multipart/form-data` (entries have `value` and
  `filename`); both return a map with `get`.
- `reader(buffer)` streams the body and stops at `limits.body_max` too, for
  chunked bodies as well (`error.BodyTooBig`, answered 413). A handler that
  takes larger uploads (to a file, say) uses `readerLimited(buffer, limit)`,
  where a null limit means any amount. A second `reader`, or `body()` after
  `reader`, is `error.BodyReaderTaken` (answered 500).

```zig
const NewUser = struct { name: []const u8, email: []const u8 };

fn createUser(req: *anole.Request, res: *anole.Response) !void {
    const user = try req.bind(NewUser); // 400 when missing or malformed
    res.status = .created;
    try res.json(.{ .name = user.name });
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
| `json(value)` | A `std.json` body with its content type; `jsonWith(value, options)` takes `std.json`'s options. |
| `fail(status, message)` | An error answer: the status, and `message` as text or `{"error":"..."}`; see [Error handling](#error-handling). |
| `encode(content_type, encodeFn, value)` | A body from a serializer's write-to-writer function. |
| `render(content_type, template, args)` | A body from a template function or type. |
| `writer()` | A buffered body writer; `end()` it before returning. |
| `stream(buffer)` | Sends the headers now and streams the body; `end()` it. |
| `startEventStream(buffer)` | Server-Sent Events: `send(data, .{ .event = ... })`. Every CR, LF or CRLF in `data` starts a new `data:` line, so data cannot add fields of its own; `event` and `id` with a CR or LF are refused. |
| `sendFile(dir, path, options)` | A file as the body. |
| `setCookie(name, value, options)` | Adds a `Set-Cookie`. |
| `trailer(name, value)` | A trailer field after the body. |
| `headers.add(name, value)` | Appends a repeated header. |

A buffered body leaves the headers open until the handler returns, so
middleware can still change them. After `stream`, `res.header` fails with
`HeadersAlreadySent`. The request deadline (`timeouts.request`) ends once a
stream's head is out: from then on each write the peer does not take within
`timeouts.write` ends the stream. A deadline the handler set before the
stream started (`req.setTimeout`) is kept. Event streams take heartbeats
(`events.comment("keep-alive")`), tell when the server is draining
(`events.draining()`) and end with `events.end()`.

Using a request or response out of order (a second `req.reader()`,
`res.stream` after `res.body` was set, writing after the head went out)
returns a named error from `anole.http.MisuseError`, answered 500, rather
than undefined behaviour; `res.writer()` can fail for that reason, so write
`try res.writer()`.

Trailers go out over HTTP/2 and HTTP/3, after a buffered or a streamed
body; HTTP/1.1 drops them.

```zig
try res.print(.text, "payload", .{});
try res.trailer("x-checksum", "abc123");
```

`sendFile` opens the file at once, so a missing one can still become a 404,
and sends it after the handler returns. It is never compressed and does no
ranges or conditional requests; static routes do.

The path stays inside the directory you pass: an absolute path or a `..`
segment fails with `error.BadPathName` (a 404 if the handler returns it), so
a name taken from the request (`req.params.get("name")`, a query parameter)
cannot reach a file elsewhere. Symlinks inside the directory are still
followed unless `.resolve_beneath = true`. To send a file your program names
outside the directory, open the directory it is in and pass the name
relative to that.

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

`staticDir` serves the directory at a path (relative to the working
directory), which the server opens at once and closes with itself:

```zig
try app.staticDir("/", "public", .{});
```

`static` takes a directory you opened, which must stay open while the server
runs:

```zig
var public = try std.Io.Dir.cwd().openDir(io, "public", .{});
defer public.close(io);
app.static("/assets", public, .{
    .precompressed = &.{ .br, .zstd, .gzip },
    .cache_control = "public, max-age=3600",
});
```

Both take the same options:

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

- zstd, Brotli (`br`, with `-Dbrotli`, on in `web` and `full`) or gzip
  (zlib-ng) by the client's `Accept-Encoding` q-values; on a tie zstd, then
  `br`, then gzip. So browsers that offer zstd get zstd, and a client that
  offers `gzip, br` (Safari, most HTTP benchmarks) gets `br`. `identity`
  and `*` count as RFC 9110 says: `*` stands for every coding not named,
  and `br;q=0` refuses one. Streamed bodies are compressed as they are
  written, and each `flush` sends what was written so far in a form the
  client can already decode.
- Brotli runs at quality 5 by default
  (`.response = .{ .brotli_quality = 5 }`, 0 to 11), or per
  response with `res.brotli_quality`. On JSON bodies of 1.5 to 12 KB,
  quality 5 is 10-15% smaller than gzip and zstd and 8-13% smaller than
  quality 4, at about twice gzip's CPU time; quality 6 gains under 1% more,
  and 11 is for precompressed files (`precompressed = &.{.br}`), not for
  responses. Its window is at most 64 KiB, so each Brotli response in
  flight takes about 600 KiB. Its large blocks, and gzip's for a buffered
  body, come from a cache per executor, reused from one response to the
  next (no `mmap` or page faults per response, with glibc or musl),
  holding at most 4 MiB and trimmed back to one encoder's worth when idle.
- Only compressible types: text, JSON, JavaScript, XML, SVG, `+json` and
  `+xml` types and the like. Not images, video, fonts or archives.
- Buffered bodies under 128 bytes, or that do not shrink, go out as they are.
- `Vary: Accept-Encoding` is added; a strong `ETag` is weakened and
  `Accept-Ranges` dropped.
- Skipped when the handler set `Content-Encoding`, `Content-Length` or
  `Content-Range`, for 206 responses and for `sendFile` bodies.

## Timeouts and limits

These live in `ServerOptions`, in the groups `timeouts` and `limits`, with the
same names in the C ABI's JSON configuration:
`.timeouts = .{ .request = .fromSeconds(10) }, .limits = .{ .body_max = 8 << 20 }`.
A duration is an `anole.Duration`; null disables a timeout.

| `timeouts` | Default | Covers |
| --- | --- | --- |
| `request` | 30 s | A whole request: reading it, the handler, writing the response; also the TLS handshake. It ends when a stream or a file body starts; `write` takes over. Over HTTP/2, a response still going out after its handler returned gets this long again (or `keepalive` when this is off) before the stream is reset. |
| `read_header` | 10 s | The request head on HTTP/1.x (against Slowloris). |
| `write` | 30 s | One write the peer does not take: it ends the response (HTTP/1.1: the connection; HTTP/2 and HTTP/3: the stream). Counted once a stream or file body has started, and on every HTTP/2 connection write. |
| `keepalive` | 60 s | An idle connection between requests. |
| `idle_park` | 1 s | An idle HTTP/1.1 connection gives up its coroutine. |
| `shutdown` | 10 s | The graceful drain. |

A handler can replace its own deadline, for one request:

```zig
req.setTimeout(.fromSeconds(300));   // 300 s from now
req.setTimeout(null);                // none
req.setDeadline(.{ .deadline = t }); // an absolute std.Io.Timeout
```

| `limits` field | Default | Over the limit |
| --- | --- | --- |
| `body_max` | 1 MiB | `body()`, `bind()`, `json()`, forms and `reader()` fail: 413. Counted after decoding. A larger declared `Content-Length` is a 413 before the handler runs. |
| `max_head_size` | 16 KiB | The request line and headers must fit: 431. |
| `max_header_count` | 32 | Request headers: 431. |
| `max_param_count`, `max_query_count` | 8, 32 | Path parameters and query values: 400. |
| `max_form_count`, `max_multiform_count` | 32, 32 | Form fields. |
| `max_requests_per_connection` | none | Requests per keep-alive connection. |

`request.require_host` (true): an HTTP/1.1 request with no `Host`, or any with
two, is a 400 (RFC 9112).

`response.max_header_count` (64) caps the headers a response can carry,
those the server adds included; past it `res.header` fails with
`TooManyHeaders`. `res.addHeader` adds one that may repeat (`Vary`,
`Link`). Both tables start with room for 16 and grow to their limits, so
add response headers through `res.header` and `res.addHeader` rather than
to `res.headers` directly, which only has the room it has grown to. HTTP/2's limits are in `ServerOptions.http2`
([server.md](server.md#http2)).

## Error handling

A handler or middleware returns an error to give up, and the error says what
the client gets:

- An error named after a status answers with it: `error.Unauthorized` is a
  401, `error.Forbidden` 403, `error.NotFound` 404, `error.Conflict` 409,
  `error.UnprocessableEntity` (or `UnprocessableContent`) 422,
  `error.TooManyRequests` 429, `error.ServiceUnavailable` 503. Any standard
  4xx or 5xx counts, by its `std.http.Status` tag in PascalCase or its RFC
  9110 reason phrase. `anole.errorStatus(err)` says which status an error
  stands for.
- Request-body faults get a 4xx: `BodyTooBig` 413,
  `UnsupportedContentEncoding` 415, and 400 for `InvalidJsonBody` and
  `MissingBody` (from `bind` and `json`), `IncompleteBody` (a body cut
  short) and `MalformedBody` (broken chunked framing, or a body that is not
  valid gzip or zstd). `BadPathName`, a path `sendFile` refuses because it
  would leave its directory, is a 404. They are logged at `debug`, not
  `err`.
- Anything else is logged at `err` and answered 500, and what the handler
  wrote is discarded. That includes `std.json`'s `SyntaxError` when the JSON
  was not the request's own (a config file, an upstream response).
- If the handler had started streaming, no error answer can be sent, so the
  connection is closed instead. If the client went away, nothing is logged.

To answer with a message of your own, `res.fail(status, message)` sets the
status and replaces whatever was written:

```zig
fn requireKey(req: *anole.Request, res: *anole.Response, next: anole.Next) !void {
    if (req.headers.get("X-Api-Key") == null) return res.fail(.unauthorized, "missing API key");
    return next.call();
}
```

The body of `fail`, and of the server's own error answers, is
`{"error":"..."}` for a request that takes JSON (its `Accept` names JSON, or
it sent a JSON body) and text otherwise. `ServerOptions.errors` settles it
for every request: `.json` for an API, `.text` for neither. An empty message
stands for the status line (`"404 Not Found\n"`, `{"error":"Not Found"}`).

Zig panics cannot be recovered: a panic in a handler (an unwrapped null, an
index out of bounds) ends the process, and in `ReleaseFast` an unwrapped
null is undefined behaviour. Prefer `orelse return error.NotFound` to `.?`,
and build servers `ReleaseSafe`.

To answer errors yourself, set `ServerOptions.error_handler`, a plain
function, and fall back on the default mapping for the rest:

```zig
fn onError(req: *anole.Request, res: *anole.Response, err: anyerror) void {
    switch (err) {
        error.OutOfStock => res.fail(.conflict, "out of stock"),
        else => anole.defaultError(req, res, err),
    }
}

var app = try anole.Server(void).init(gpa, .{ .error_handler = onError }, {});
```

With a context, these declarations on `Ctx` answer errors, 404s and 405s:

```zig
const App = struct {
    pub fn notFound(_: *App, req: *anole.Request, res: *anole.Response) !void {
        res.status = .not_found;
        try res.json(.{ .@"error" = "not found", .path = req.url });
    }

    pub fn uncaughtError(_: *App, req: *anole.Request, res: *anole.Response, err: anyerror) void {
        std.log.err("{s} {s}: {t}", .{ req.id, req.url, err });
        anole.defaultError(req, res, err);
    }
};
```

`methodNotAllowed` has the same signature as `notFound`, and finds `Allow`
already set. `uncaughtError` comes before `error_handler`; either replaces
the built-in mapping unless it calls `anole.defaultError`. An error answered
with a 4xx is logged at `debug`, one answered with a 5xx at `err`.

The built-in middlewares refuse a request the same way: `auth.RequireJwt`,
`auth.apikey.Middleware`, `auth.rbac.Require`, `auth.csrf.Middleware` and
`ratelimit.Middleware` set their protocol headers (`WWW-Authenticate`,
`Retry-After`, `RateLimit-*`) and return a status-named error
(`error.Unauthorized`, `error.Forbidden`, `error.BadRequest`,
`error.TooManyRequests`), so their answers follow `ServerOptions.errors` and
reach `uncaughtError` and `error_handler` with those headers kept. Their 503s
and 500s (a key store or limiter that failed) are logged by the middleware
and answered with `res.fail`, in the same format. A `Ctx`
can also declare `dispatch(self, action, req, res)` to wrap every handler
call.

## Request locals

A middleware hands what it found to the handler through the request's
locals: typed values by name, for this request only, in its arena.

```zig
const Tenant = struct {
    pub fn execute(_: *const Tenant, req: *anole.Request, _: *anole.Response, next: anytype) !void {
        const id = req.headers.get("X-Tenant") orelse return error.BadRequest;
        try req.setLocal("tenant", id);
        return next.call();
    }
};

fn handler(req: *anole.Request, res: *anole.Response) !void {
    const tenant = req.local([]const u8, "tenant") orelse return error.Unauthorized;
    try res.print(.text, "tenant {s}", .{tenant});
}
```

`local` returns null when nothing is stored under the key or it was stored
as another type. Keys are not copied (use literals). Anole's auth
middleware keep what they verified here: `anole.auth.claims(req)` and
`anole.auth.apikey.owner(req)` ([auth.md](auth.md)).

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
`std.Io.File`, `std.Io.net`, the server's HTTP client (`anole.client(req)`; see
[clients.md](clients.md)) and database drivers built on them. A C library
that blocks in its own system calls holds the executor's thread until it
returns.

For several calls at once, use `req.io.concurrent` and await each future, or
cancel it on the way out after an error. Those tasks may run on other
executors and the request's arena is not thread-safe, so give each one memory
of its own. [examples/io](../examples/io/main.zig) makes two outbound
requests in parallel this way and reads files through the `Io`
(`zig build run-io`).

### Handlers that never wait

On HTTP/2 and HTTP/3 each request normally runs on a task of its own, so a
handler that waits holds up nothing else. A handler that never waits (it answers
from the request and its body, the server's state or memory: no I/O, no
sleep, no lock another task holds across a wait) can say so:

```zig
app.get("/plaintext", anole.noWait(plaintext));
app.get("/json", anole.noWait(json));
```

Its HTTP/2 requests that arrive whole (a body included) in one read then
run right where the connection reads them, without a task, and the
responses to one read go out in one write: about 1.7x the requests per core
for small responses. Over HTTP/3 the same goes for a request that arrives
whole in one packet: it runs where the endpoint reads the packet, and its
response leaves with the rest of the batch. The promise covers every
middleware that runs for the route too, and it is checked: registering a
`noWait` route (`anole.noWait(h)`, `RouteOptions.no_wait`, a gRPC service
registered `no_wait`) behind middleware that does not say it never waits is
a startup error naming both:

```
route GET /ping is marked noWait, but middleware anole.session.Middleware may wait (I/O, a lock, a sleep): drop noWait from the route, or mark the middleware if it never waits (pub const no_wait = true; anole.noWait(f) for a function middleware)
```

Either remove `noWait` from the route, or mark a middleware of yours that
truly never waits. The built-in middleware that never waits is marked:
`Cors`, `Compress`, `RequestId`, `Logger`, the cookie `Session`,
`ResponseCache`, `AltSvc`, CSRF, RBAC, the access log, metrics, tracing,
`app.rateLimit`, and (by how they are set up) `ratelimit.Middleware` on a
memory limiter, `auth.RequireJwt` on static keys and no hook,
`auth.apikey.Middleware` on an in-memory lookup (`Lookup.never_waits`) and
`session.Middleware` on cookies or a memory store; a Redis limiter or
store, a JWKS keyring or a database lookup may wait and are not. A handler marked this way that
waits anyway still works, but holds up every other request on its
connection (on HTTP/3, every connection of its endpoint) meanwhile and gets
no request timeout, so leave the mark off anything that queries a database,
a cache or another service. On HTTP/1.1 the mark changes nothing.
