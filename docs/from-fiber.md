# From Fiber

Anole's API is shaped like Go's [Fiber](https://gofiber.io): an app, routes
with `:params`, groups, middleware that calls the next one, and errors that
carry a status. This page puts Fiber v3's calls next to Anole's, then lists
what is different because this is Zig. [getting-started.md](getting-started.md)
builds a whole API step by step.

## Side by side

| Fiber v3 | Anole |
| --- | --- |
| `app := fiber.New()` | `var app = try anole.App.init(init.gpa, .{});` and `defer app.deinit();` |
| `fiber.New(fiber.Config{...})` | `anole.App.init(gpa, .{ ... })`, an `anole.ServerOptions` |
| `app.Listen(":3000")` | `try app.listen(":3000");` (every interface, as in Go) |
| `app.Listen(":443", fiber.ListenConfig{CertFile: "cert.pem", CertKeyFile: "key.pem"})` | `try app.listenTls(":443", .fromFiles("cert.pem", "key.pem"));` |
| `app.Shutdown()` | `app.stop();` (SIGINT and SIGTERM do it too) |
| `app.Get("/users/:id", h)` | `app.get("/users/:id", h);` |
| `app.All("/x", h)` | `app.any("/x", h);` |
| `app.Get("/files/*", h)` | `app.get("/files/*path", h);` (a wildcard has a name) |
| `func(c fiber.Ctx) error` | `fn (req: *anole.Request, res: *anole.Response) !void` |
| `c.Params("id")` | `req.params.get("id")`, a `?[]const u8` |
| `fiber.Params[int](c, "id")` | `req.params.getInt(u64, "id")`, null when missing or not a number |
| `c.Query("q", "all")` | `req.query.get("q") orelse "all"` |
| `fiber.Query[int](c, "limit", 20)` | `req.query.getInt(usize, "limit") orelse 20` |
| `c.Get("X-Api-Key")` | `req.headers.get("X-Api-Key")` |
| `c.Cookies("sid")` | `req.cookies().get("sid")` |
| `c.IP()` | `req.remote_address` (behind a proxy, with `trusted_proxy_hops` set) |
| `c.Body()` | `try req.body()`, a `?[]const u8` |
| `c.Bind().Body(&in)` | `const in = try req.bind(NewUser);` |
| `c.SendString("hi")` | `res.body = "hi";` or `try res.print(.text, "hi {s}", .{name});` |
| `c.JSON(v)` | `try res.json(v);` |
| `c.Status(201).JSON(v)` | `res.status = .created;` then `try res.json(v);` |
| `c.SendStatus(204)` | `res.status = .no_content;` |
| `c.Set("X-Foo", "bar")` | `try res.header("X-Foo", "bar");` |
| `c.Cookie(&fiber.Cookie{...})` | `try res.setCookie("sid", value, .{ .http_only = true, .secure = true });` |
| `c.Redirect().To("/login")` | `res.status = .found;` then `try res.header("Location", "/login");` |
| `c.SendFile("./report.pdf")` | `_ = try res.sendFile(std.Io.Dir.cwd(), "report.pdf", .{});` |
| `c.Locals("user", u)` | `try req.setLocal("user", u);` |
| `c.Locals("user")` | `req.local(User, "user")`, null when unset or of another type |
| `app.Use(mw)` | `app.use(mw);`, before the routes |
| `api := app.Group("/api", mw)` | `const api = app.group("/api", .{mw});` |
| `app.Get("/x", mw, h)` | `app.with(.{mw}).get("/x", h);` |
| `return c.Next()` | `return next.call();` |
| `return fiber.ErrNotFound` | `return error.NotFound;` |
| `return fiber.NewError(409, "taken")` | `return res.fail(.conflict, "taken");` |
| `fiber.Config{ErrorHandler: h}` | `.error_handler = h` in the options |
| `app.Get("/*", static.New("./public"))` | `try app.staticDir("/", "public", .{});` |
| `websocket.New(func(c *websocket.Conn) {...})` | `app.ws("/ws", handler);` ([below](#websocket)) |
| `cors.New()` | `app.use(anole.middleware.Cors.init(.{}));` |
| `logger.New()` | `app.use(anole.observe.AccessLog.init(.{}));` |
| `requestid.New()` | `app.use(anole.middleware.RequestId.init(.{}));` |
| `compress.New()` | `app.use(anole.middleware.Compress.init(.{}));` |
| `recover.New()` | nothing to add, and nothing like it ([below](#what-is-different)) |
| `limiter.New(limiter.Config{Max: 100, Expiration: time.Minute})` | `anole.ratelimit.Middleware.init(limiter.limiter(), .{ .limit = 100, .window_ms = 60_000 })` ([below](#rate-limits-sessions-and-jwt)) |
| `session.New()` and `session.FromContext(c)` | `try anole.session.Middleware.init(.{ .key = key })` and `req.session` |
| `jwtware.New(jwtware.Config{...})` (contrib/jwt) | `anole.auth.RequireJwt.init(keys, policy, .{})` and `anole.auth.claims(req)` |
| `healthcheck.New()` | `_ = app.health(.{});` (`/healthz`, `/readyz`) |
| `client.Get(url)` | `anole.client(req).fetch(url, .{})` |
| `app.Test(req)` | `app.listen("127.0.0.1:0")` with the checks in a task on `app.io()` (`tests/rest_test.zig`) |
| `Prefork: true` | the default: an accept loop on every core (one `SO_REUSEPORT` socket each on Linux) |

What Fiber cannot do and Anole does: HTTP/2 and HTTP/3 without a proxy in
front, and gRPC (`app.grpc(pb.Greeter, .{ .SayHello = sayHello })`, see
[grpc.md](grpc.md)).

## A handler

```go
app.Post("/users", func(c fiber.Ctx) error {
    var in NewUser
    if err := c.Bind().Body(&in); err != nil {
        return err
    }
    if in.Name == "" {
        return fiber.NewError(fiber.StatusUnprocessableEntity, "name is empty")
    }
    u := store.Add(in)
    return c.Status(fiber.StatusCreated).JSON(u)
})
```

```zig
fn createUser(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const in = try req.bind(NewUser);
    if (in.name.len == 0) return res.fail(.unprocessable_entity, "name is empty");
    const user = try app.store.add(in);
    res.status = .created;
    try res.json(user);
}

app.post("/users", createUser);
```

Fiber's one `c` is two values here, the request and the response, and the
handler is a named function: Zig has no closures. Shared state (`store`
above) comes in as the first parameter on an `anole.Server(App)`, from the
pointer given to `init`, rather than captured.

## Middleware

```go
func requireKey(c fiber.Ctx) error {
    if c.Get("X-Api-Key") == "" {
        return fiber.ErrUnauthorized
    }
    return c.Next()
}

api := app.Group("/api", requireKey)
```

```zig
fn requireKey(req: *anole.Request, _: *anole.Response, next: anole.Next) !void {
    if (req.headers.get("X-Api-Key") == null) return error.Unauthorized;
    return next.call();
}

const api = app.group("/api", .{requireKey});
```

Code after `next.call()` runs once the handler is done, as code after
`c.Next()` does. A middleware with settings is a struct with an `execute`
method ([routing.md](routing.md#middleware)). One difference in order:
Fiber runs `app.Use` in the order of the calls, mixed with routes; Anole
wants every `app.use` before the first route, and panics at startup
otherwise.

## Errors

```go
app := fiber.New(fiber.Config{
    ErrorHandler: func(c fiber.Ctx, err error) error {
        code := fiber.StatusInternalServerError
        var e *fiber.Error
        if errors.As(err, &e) {
            code = e.Code
        }
        return c.Status(code).JSON(fiber.Map{"error": err.Error()})
    },
})
```

```zig
var app = try anole.App.init(init.gpa, .{ .errors = .json });
```

That one option gives much the same answers. An error named after a status
(`error.NotFound`, `error.Unauthorized`, `error.Conflict`,
`error.TooManyRequests`, any standard 4xx or 5xx) is answered with that
status; a JSON body that does not parse is a 400; anything else is logged
and answered 500 without its name, so internal details stay internal. The
body is `{"error":"Not Found"}`, or the message given to `res.fail`. To
handle some errors yourself:

```zig
fn onError(req: *anole.Request, res: *anole.Response, err: anyerror) void {
    switch (err) {
        error.OutOfStock => res.fail(.conflict, "out of stock"),
        else => anole.defaultError(req, res, err),
    }
}

var app = try anole.App.init(init.gpa, .{ .error_handler = onError });
```

A Zig error is a name and nothing else: it cannot carry a message or a
value, as a Go `error` can. `res.fail(status, message)` is the way to send
a message, and `req.setLocal` the way to pass details along.

## WebSocket

```go
app.Get("/ws", websocket.New(func(c *websocket.Conn) {
    for {
        mt, msg, err := c.ReadMessage()
        if err != nil {
            break
        }
        c.WriteMessage(mt, msg)
    }
}))
```

```zig
fn echo(ws: *anole.websocket.Socket, _: *anole.Request) !void {
    while (try ws.next()) |msg| try ws.send(msg.type, msg.data);
}

app.ws("/ws", echo);
```

No upgrade-check middleware is needed: a request that is not a WebSocket
handshake gets 426. The same route serves WebSockets over HTTP/2 (RFC
8441). `anole.websocket.Rooms` broadcasts to groups of sockets
([websocket.md](websocket.md)).

## Rate limits, sessions and JWT

These hold state, so they are values that live in `main` beside the app,
rather than calls that return a handler:

```zig
// limiter.New(): 100 requests a minute per client address (`.key` to count
// by something else, `.on_error = .deny` to refuse when the limiter fails).
var limiter = anole.ratelimit.MemoryLimiter.init(init.gpa, app.io(), .{});
defer limiter.deinit();
app.use(anole.ratelimit.Middleware.init(limiter.limiter(), .{ .limit = 100, .window_ms = 60_000 }));

// session.New(): an encrypted cookie; 32 random bytes from your secret store
// (anole.session.keyFromBase64 reads one). No key is an error, not a default.
const session_key = try anole.session.keyFromBase64(init.environ_map.get("SESSION_KEY") orelse return error.NoSessionKey);
app.use(try anole.session.Middleware.init(.{ .key = session_key }));

// contrib/jwt: Authorization: Bearer <token>, HS256 with one shared secret.
const keys = [_]anole.auth.Key{.{ .alg = .HS256, .material = .{ .hmac = jwt_secret } }};
const api = app.group("/api", .{anole.auth.RequireJwt.init(.{ .static = &keys }, .{ .audience = "api" }, .{})});
```

In a handler, `req.session.get("user")` and `try req.session.set("user",
name)` read and write the session, and `anole.auth.subject(req)` and
`anole.auth.claims(req)` give the verified token's `sub` and claims (Fiber's
`c.Locals("user")`). `limiter`, `keys` and the secrets must outlive the
server, which locals of `main` do. Redis-backed limits and sessions, JWKS
key sets, OIDC sign-in, CSRF and API keys are in [auth.md](auth.md).

## What is different

**Memory.** Go collects garbage; Zig does not. Each request has an arena,
`req.arena`, freed when its response has been sent. Everything Anole parses
for you lives there: path and query values, headers, the result of
`req.bind`. That is Fiber's rule that values from `c` are valid only inside
the handler (its zero-allocation design), made explicit. To keep a value
longer, copy it into an allocator that outlives the request, such as the
`gpa` from `main`, and free it yourself. A slice given to `res.body` must
outlive the handler: a literal, or memory from `res.arena`; `res.print` and
`res.json` copy for you.

**Errors.** Handlers return `!void`, an error union. `try` passes an error
on, as `if err != nil { return err }` does. Unhandled errors become answers
as described [above](#errors).

**Panics and recover.** Zig panics cannot be caught. Fiber's `recover`
middleware turns a panic into a 500 and keeps serving; in Zig a panic, such
as `.?` on a missing value or an index out of bounds, ends the whole
process, every connection with it. In a `ReleaseFast` build those checks are
off and the same bug is undefined behaviour. So:

- write `req.params.get("id") orelse return error.NotFound`, not `.?`;
- build servers with `-Doptimize=ReleaseSafe`, which keeps the checks;
- run under a supervisor that restarts on exit (systemd's
  `Restart=on-failure`, a container restart policy).

**Concurrency.** Handlers run concurrently on every core, as goroutines do,
but on coroutines that never leave their thread. Shared state needs a lock,
and `std.Io.Mutex` is the one to use: a request waiting for it yields to
others, where `std.Thread.Mutex` would block its whole thread. Any `std.Io`
call through `req.io` (sockets, files, timers, `anole.client(req)`)
suspends only that request. A C library that blocks, or long computation,
holds the thread; `anole.blocking.run` moves it to a thread pool
([server.md](server.md#blocking-work)).

**Startup.** Fiber's `app.Listen` binds and serves. Anole's `listen` does
both too and returns when the server has stopped, after its drain. Routes,
middleware and options are all set before it, and a mistake there (a route
registered twice, `use` after a route) panics at startup, not on the first
request.

**Build.** There is no `go get` at run time: `zig fetch --save` pins Anole
by hash in `build.zig.zon`, and `zig build` compiles it and its C libraries
into one binary. Features you don't use can be left out at build time
(`.profile = .web`, or flags such as `-Dhttp3=false`), which Go's linker
does not offer for a framework.
