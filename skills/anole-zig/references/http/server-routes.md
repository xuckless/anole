# Server and routes

Up: [index](index.md). Full docs: docs/server.md, docs/routing.md, docs/getting-started.md. Examples: examples/hello, examples/rest, templates/minimal, templates/rest-postgres.
Related: [request-response.md](request-response.md), [typed-validation.md](typed-validation.md), [middleware](../middleware-auth/middleware.md).

## A server without state

Use for a service whose handlers need nothing shared. Do not hand-roll a listener, router or signal handling: `listen` serves until SIGINT/SIGTERM, then drains.

Use: `anole.App`, `anole.App.init`, `anole.App.listen`, `anole.App.deinit` (src/server.zig); `anole.ServerOptions` (src/server.zig `Options`).

```zig
const std = @import("std");
const anole = @import("anole");

fn hello(_: *anole.Request, res: *anole.Response) !void {
    res.body = "Hello, World!";
}

fn user(req: *anole.Request, res: *anole.Response) !void {
    const id = req.params.getInt(u64, "id") orelse return error.NotFound;
    try res.json(.{ .id = id });
}

pub fn main(init: std.process.Init) !void {
    var app = try anole.App.init(init.gpa, .{});
    defer app.deinit();
    app.get("/", hello);
    app.get("/users/:id", user);
    try app.listen(":3000");
}
```

Optional root declarations used by every template: `pub const std_options = anole.std_options;` and `pub const panic = anole.panic;`.

Traps:
- `use` comes before any route: the router panics on a `use` after a route.
- One `Server` per thread: `init` on a thread that already has one fails with `error.ServerAlreadyOnThread`.
- `listen(":3000")` is every interface; `"127.0.0.1:3000"` is this machine only. A port in use is `error.AddressInUse`.

## A server with shared state

Use when handlers share a store, pools or connectors. The state is a struct you own; the handler takes `*Ctx` first. Handlers that do not need it may stay `(req, res)`.

Use: `anole.Server(Ctx)`, `anole.Server(Ctx).init`, `anole.Server(Ctx).run`, `anole.Server(Ctx).io` (src/server.zig).

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

Traps:
- The state must outlive the server.
- Handlers run at the same time on every executor: shared state needs atomics or a lock. Use `std.Io.Mutex` / `std.Io.RwLock` (`try store.mutex.lock(req.io)`), not `std.Thread.Mutex`, which blocks the executor thread. See [never block an executor](../runtime.md#never-block-an-executor).
- Strings from a request die with it; copy into the store's `gpa` before keeping them (examples/rest `Store.put`). See [request arena and lifetimes](../runtime.md#request-arena-and-lifetimes).
- Prefer `orelse return error.NotFound` to `.?`: a panic ends the whole process.
- Keep `routes(app)` apart from `main` so tests serve the same routes (every template does this; see [testing.md](../testing.md)).

## Routes and path parameters

Use: `get`, `head`, `post`, `put`, `patch`, `delete`, `options`, `query` (the HTTP QUERY method), `any` (every method), `addRoute` (path known only at run time; `null` method is every method), on `anole.App` / `anole.Server(Ctx)` and on groups (src/server.zig).

```zig
app.get("/users/:id", getUser);
app.post("/users", createUser);
app.delete("/users/:id", deleteUser);
app.get("/files/*path", getFile);
app.any("/legacy/*path", legacy); // every method
app.addRoute(.get, cfg.health_path, health);
```

- `:name` matches one segment, `*name` the rest of the path. Literals beat `:params`, which beat wildcards; `/users/new` and `/users/:id` coexist.
- HEAD without its own route is served by GET. A path with routes but not this method gets 405 with `Allow`.

Traps:
- Paths are checked at compile time (wildcard last, no `?`/`#`, each param name once). Query strings are never part of a route.
- Duplicate or conflicting routes panic at registration; in test builds `run`/`listen`/`anole.testing.client` fail with `error.RouteConflict` and `app.routeConflict()` has the message.
- Path params are raw (percent-escapes kept). `req.paramDecoded("name")` decodes; see [request-response.md](request-response.md).

## Groups and `with`

Use for a prefix plus middleware on some routes only. Groups nest; a nested group adds its middleware after its parent's. `with` is a group without a prefix.

Use: `anole.App.group`, `anole.App.with`, `anole.App.Group` (src/server.zig), `anole.onlyOn` (src/server.zig).

```zig
const admin = app.group("/admin", .{RequireToken{ .token = "Bearer secret" }});
admin.get("/stats", adminStats); // GET /admin/stats
const reports = admin.group("/reports", .{});
reports.get("/:year", report); // GET /admin/reports/:year

app.with(.{requireAdmin}).delete("/users/:id", deleteUser);
app.get("/users/:id", getUser); // not behind requireAdmin
```

`anole.onlyOn(name)` serves a group's routes on one named listener and 404s on the others:

```zig
app.group("/admin", .{anole.onlyOn("admin")})
```

Traps:
- Middleware values in the tuple are copied: one value listed in two groups is two copies (two rate-limit counters, two caches). Share one with a handle; see [middleware.md](../middleware-auth/middleware.md#sharing-one-middleware-value).

## Handlers that never wait: `anole.noWait`

Use only for handlers that answer from the request, memory or state with no I/O, sleep or contended lock (plaintext, cached JSON). HTTP/2 and HTTP/3 then run them without a task of their own.

Use: `anole.noWait` (src/handlers.zig).

```zig
app.get("/plaintext", anole.noWait(plaintext));
app.get("/json", anole.noWait(json));
```

Traps:
- Never on a handler that queries a database, cache or another service: it holds up every other request on its connection and gets no request timeout.
- Every middleware in front of the route must declare it never waits, or registration is a startup error naming both. How a middleware says so: [middleware.md](../middleware-auth/middleware.md#middleware-that-never-waits).
