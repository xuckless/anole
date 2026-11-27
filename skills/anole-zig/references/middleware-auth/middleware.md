# Middleware

Up: [index](index.md). Full docs: docs/routing.md (Middleware, Groups, Request locals), docs/server.md (0-RTT). Examples: examples/rest, examples/auth, templates/full.
Related: [http/server-routes.md](../http/server-routes.md#groups-and-with), [caching.md](caching.md), [errors.md](errors.md).

Order: global middleware (`use`, in the order added), then each enclosing group's, then the handler. Global middleware also runs for 404s and 405s.

## A function middleware: `anole.func` and `anole.Next`

Use for a check or wrapper without settings. `next.call()` runs the rest of the chain; return its error so the server can answer it. Return without calling it to answer yourself.

Use: `anole.App.use` (src/server.zig), `anole.func`, `anole.Next` (src/handlers.zig). `use`, `group` and `with` take the bare function; `anole.func(f)` wraps it explicitly. On `Server(App)` it may take `*App` first.

```zig
fn requireKey(store: *Store, req: *anole.Request, res: *anole.Response, next: anole.Next) !void {
    const key = req.headers.get("X-Api-Key") orelse return error.Unauthorized;
    if (!std.crypto.timing_safe.eql([32]u8, keyDigest(key), store.api_key_digest)) return res.fail(.forbidden, "wrong API key");
    return next.call();
}

const api = app.group("/api", .{requireKey});
```

Traps:
- `use` must come before the first route (panic otherwise).
- Compare secrets in constant time (`std.crypto.timing_safe.eql`), as above. For API keys use [anole.auth.apikey](keys-passwords-roles.md#api-keys) instead of hand-rolling.

## A middleware struct: `execute`

Use when the middleware has settings. Same contract as the function form, with `next: anytype`.

```zig
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

Traps:
- Values passed to `use` / `group` / `with` are copied and owned by the server, which calls their `deinit` if they have one.
- After `next.call()` the handler may have streamed: `res.header` then fails with `HeadersAlreadySent`.

## Middleware that never waits

A middleware with no I/O, sleep or lock another task holds says so, so it can sit in front of [`anole.noWait`](../http/server-routes.md#handlers-that-never-wait-anolenowait) routes:

- a struct: `pub const no_wait = true;` (or `pub fn noWait(self: *const T) bool`, asked once at registration);
- a function: `app.use(anole.noWait(f))`.

The built-ins `Cors`, `Compress`, `RequestId`, `Logger`, the cookie session, `ResponseCache`, CSRF, RBAC and `app.rateLimit` are marked. A Redis limiter or store, a JWKS keyring or a database lookup may wait and is not.

## Sharing one middleware value

Use when one value (a session store, a limiter policy) must be the same in several groups.

Use: `anole.App.middleware` (src/server.zig, server-owned copy), `anole.Middleware` (src/http/core/middleware.zig, a handle to a value you keep alive).

```zig
const sessions = app.middleware(try anole.session.Middleware.init(.{ .key = key }));
app.group("", .{sessions}).get("/me", me);
app.group("", .{ sessions, anole.auth.csrf.Middleware.init(.{}) }).post("/notes", addNote);
```

```zig
const M = anole.Middleware(App);
const web = [_]M{ .init(&sessions), .init(&csrf) };
const limited = [_]M{ .init(&login_limit), .init(&sessions), .init(&csrf) };
server.group("", &web).get("/login", loginForm);
server.group("", &limited).post("/login", login);
```

Traps:
- With `anole.Middleware(Ctx).init(&value)`, the value and the array must stay alive while the server runs (locals in `main` before `run()` are fine).

## Request locals

A middleware hands what it found to the handler: `req.setLocal(key, value)` / `req.local(T, key)` (src/http/core/request.zig), for this request only, in its arena.

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

Traps: keys are not copied (use literals); `local` returns null for a missing key or another type.

## Built-in middleware

Use: `anole.middleware.RequestId`, `anole.middleware.Logger`, `anole.middleware.Compress`, `anole.middleware.Cors` (src/root.zig, src/http/core/middleware/).

```zig
app.use(anole.middleware.RequestId.init(.{})); // first, so the rest see req.id
app.use(anole.middleware.Logger.init(.{}));
app.use(anole.middleware.Compress.init(.{}));
app.use(anole.middleware.Cors.init(.{}));
```

- `RequestId`: sets `req.id`, sends `X-Request-Id`; `.trust_incoming = true` only behind a proxy that sets or strips it.
- `Logger`: one line per request, scope `access`; the query is left out unless `.log_query = true`. The templates use `anole.observe.AccessLog.init(.{})` instead ([observability.md](../observability.md)).
- `Compress`: zstd / Brotli / gzip by `Accept-Encoding`, compressible types only.
- `Cors.init(.{})` allows any origin without credentials. With cookies:

```zig
app.use(anole.middleware.Cors.init(.{
    .origins = &.{ "https://app.example.com", "https://admin.example.com" },
    .credentials = true,
    .expose = "X-Request-Id",
}));
```

Traps:
- `credentials = true` needs `origins`: with any origin, `init` panics.
- Put `Cors` before authentication middleware: a preflight carries no credentials.

## Early data (0-RTT)

Use: `anole.early_data.isEarly`, `anole.early_data.TooEarly`, `anole.early_data.Guard` (src/early_data.zig). With `.http3 = .{ .early_data = true }`, GET/HEAD/OPTIONS may run from 0-RTT and can be replayed. The server already runs `Guard` (425 for unsafe marked requests) on every route. A route whose GET has effects that must not repeat takes `TooEarly`:

```zig
const pay = app.group("/pay", .{anole.early_data.TooEarly{}});
```
