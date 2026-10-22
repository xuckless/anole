# Getting started

From an empty directory to a running JSON API, then a WebSocket, static
files, TLS and gRPC, and how to deploy it. Each step is the shortest program
that does the job; the other guides go further. Coming from Go's Fiber,
[from-fiber.md](from-fiber.md) maps what you know onto Anole.

## A project

You need Zig 0.17 (`zig version` prints `0.17.0`) on macOS or Linux, and
nothing else: Anole's build fetches and compiles its C libraries (BoringSSL,
nghttp2 and the rest) itself.

```sh
mkdir api && cd api
zig init
rm src/root.zig
zig fetch --save git+https://github.com/xuckless/anole#v0.1.2
```

(`#v0.1.2` is the latest release; a later tag or a commit works the same way.)

Replace the `build.zig` that `zig init` wrote with this one:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = @import("anole").addApp(b, .{
        .name = "api",
        .root_source_file = b.path("src/main.zig"),
    });
}
```

`addApp` makes the executable, gives it the `anole` module, installs it and
adds `zig build run`. `-Doptimize` and `-Dtarget` work as usual, and
`.profile = .web` leaves out HTTP/3, gRPC, MongoDB and Redis (the
[build flags](../README.md#build-flags)).

And `src/main.zig`:

```zig
const std = @import("std");
const anole = @import("anole");

fn hello(_: *anole.Request, res: *anole.Response) !void {
    res.body = "Hello, World!";
}

pub fn main(init: std.process.Init) !void {
    var app = try anole.App.init(init.gpa, .{});
    defer app.deinit();
    app.get("/", hello);
    try app.listen(":3000");
}
```

```sh
zig build run
curl localhost:3000/   # Hello, World!
```

The first build compiles the C libraries, which takes a minute or two; later
builds reuse them. The server logs
`listening on http://[::]:3000 (HTTP/1.1, HTTP/2 cleartext; IPv6 and IPv4)`
(`http://0.0.0.0:3000` where the system has no IPv6) and serves
until Ctrl-C or SIGTERM, then lets the requests in flight finish and
returns. A Debug build also logs a line for each runtime thread it starts
and stops; `pub const std_options = anole.std_options;` in `main.zig` keeps
those out.

## A JSON API

A to-do list in memory, behind an API key:

```zig
const std = @import("std");
const anole = @import("anole");

pub const std_options = anole.std_options;
pub const panic = anole.panic;

const Todo = struct { id: usize, title: []const u8, done: bool = false };
const NewTodo = struct { title: []const u8 };

const App = struct {
    gpa: std.mem.Allocator,
    /// SHA-256 of the API key; the key itself is not kept.
    api_key_digest: [32]u8,
    mutex: std.Io.Mutex = .init,
    todos: std.ArrayList(Todo) = .empty,

    fn deinit(app: *App) void {
        for (app.todos.items) |todo| app.gpa.free(todo.title);
        app.todos.deinit(app.gpa);
    }
};

fn list(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const limit = req.query.getInt(usize, "limit") orelse 50;
    try app.mutex.lock(req.io);
    defer app.mutex.unlock(req.io);
    try res.json(app.todos.items[0..@min(limit, app.todos.items.len)]);
}

fn get(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const id = req.params.getInt(usize, "id") orelse return error.NotFound;
    try app.mutex.lock(req.io);
    defer app.mutex.unlock(req.io);
    if (id == 0 or id > app.todos.items.len) return error.NotFound;
    try res.json(app.todos.items[id - 1]);
}

fn create(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const in = try req.bind(NewTodo);
    if (in.title.len == 0) return res.fail(.unprocessable_entity, "the title is empty");
    try app.mutex.lock(req.io);
    defer app.mutex.unlock(req.io);
    const title = try app.gpa.dupe(u8, in.title);
    errdefer app.gpa.free(title);
    const todo: Todo = .{ .id = app.todos.items.len + 1, .title = title };
    try app.todos.append(app.gpa, todo);
    res.status = .created;
    try res.json(todo);
}

fn sha256(text: []const u8) [32]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &d, .{});
    return d;
}

fn requireKey(app: *App, req: *anole.Request, _: *anole.Response, next: anole.Next) !void {
    const key = req.headers.get("X-Api-Key") orelse return error.Unauthorized;
    // Constant time: how long the check takes says nothing about the key.
    if (!std.crypto.timing_safe.eql([32]u8, sha256(key), app.api_key_digest)) return error.Forbidden;
    return next.call();
}

pub fn main(init: std.process.Init) !void {
    const api_key = init.environ_map.get("API_KEY") orelse return error.NoApiKey;
    var state: App = .{ .gpa = init.gpa, .api_key_digest = sha256(api_key) };
    defer state.deinit();
    var app = try anole.Server(App).init(init.gpa, .{ .errors = .json }, &state);
    defer app.deinit();

    app.use(anole.middleware.RequestId.init(.{}));
    app.use(anole.observe.AccessLog.init(.{}));
    app.use(anole.middleware.Cors.init(.{}));

    const api = app.group("/api", .{requireKey});
    api.get("/todos", list);
    api.get("/todos/:id", get);
    api.post("/todos", create);
    try app.listen(":3000");
}
```

```sh
export API_KEY=$(openssl rand -base64 32)   # zig build run reads it
curl -H "X-Api-Key: $API_KEY" -d '{"title":"write docs"}' localhost:3000/api/todos
# {"id":1,"title":"write docs","done":false}
curl -H "X-Api-Key: $API_KEY" 'localhost:3000/api/todos?limit=10'
# [{"id":1,"title":"write docs","done":false}]
curl localhost:3000/api/todos/1
# {"error":"Unauthorized"}
```

What each piece does:

- **State.** `anole.Server(App)` hands every handler a `*App`, the pointer
  given to `init`. `anole.App` is the same server without state, as in the
  first program. A handler that does not need the state can leave it out.
- **Concurrency.** Handlers run at the same time on every core, so shared
  state needs a lock. `std.Io.Mutex` lets other requests run while one
  waits for it; `std.Thread.Mutex` would block the whole thread.
- **Input.** `req.params` and `req.query` have `get` (a string) and
  `getInt`/`getFloat`, which return null when the value is missing or does
  not parse. `req.bind(T)` parses a JSON body into a `T`, ignoring fields
  `T` does not have; no body, or one that does not fit, is answered 400.
  `req.headers.get` reads a header.
- **Memory.** What `bind` returns lives in the request's arena, freed once
  the response is sent, so `create` copies the title into the state's
  allocator. Allocate anything for this request alone from `req.arena`.
- **Output.** `res.json(value)` writes JSON with its content type, and
  `res.status` sets the status. `res.print(.text, "{d} left", .{n})` formats
  a text body; `res.body` takes a slice that outlives the handler (a
  literal, or `res.arena`).
- **Errors.** Return an error named after a status and the client gets that
  status: `error.NotFound` is a 404, `error.Unauthorized` 401,
  `error.Forbidden` 403, `error.Conflict` 409. `res.fail(status, message)`
  answers with a message of your own. Any other error is logged and
  answered 500. `.errors = .json` makes every such answer
  `{"error":"..."}`; by default a request that sent or accepts JSON gets JSON
  and others get text.
- **Middleware.** A function that takes `next` and calls `next.call()` to
  go on, or returns an error or a `res.fail` answer to stop. Like a
  handler, it may take the state first. Secrets such as the API key come
  from the environment or a secret store, never from source, and are
  compared in constant time (`std.crypto.timing_safe.eql`);
  `anole.auth.apikey` issues and checks per-user keys
  ([auth.md](auth.md#api-keys)). `app.use` adds
  middleware for every request (before the routes), and `app.group(prefix,
  .{...})` for the routes under a prefix. `app.with(.{...})` does the same
  without a prefix, for single routes.

`examples/rest` is the same API with update and delete
(`zig build run-rest` in Anole's repository), and
[routing.md](routing.md) covers the router, requests and responses in full.

**Panics.** Zig has no `recover`. A panic in a handler, such as `.?` on a
missing value or an index out of bounds, ends the whole process, and in a
`ReleaseFast` build it is undefined behaviour instead. Use `orelse return
error.NotFound` rather than `.?`, and build servers with
`-Doptimize=ReleaseSafe`.

## A WebSocket

```zig
fn echo(ws: *anole.websocket.Socket, _: *anole.Request) !void {
    while (try ws.next()) |msg| try ws.send(msg.type, msg.data);
}

app.ws("/echo", echo);
```

`ws.next()` returns each text or binary message and null once the client
closes; pings and the close handshake are answered for you, and the socket
is closed when the handler returns. The same endpoint serves WebSockets
over HTTP/1.1 and HTTP/2. To try it from a browser's console:

```js
const ws = new WebSocket("ws://localhost:3000/echo");
ws.onmessage = (e) => console.log(e.data);
ws.onopen = () => ws.send("hi");
```

Broadcast to groups of sockets, limits and timeouts are in
[websocket.md](websocket.md).

## Static files

```zig
try app.staticDir("/", "public", .{});
```

This serves the files under `./public` (relative to the working directory)
at `/`: `index.html` for a directory, `ETag` and `Last-Modified` with 304s,
ranges, and no dotfiles. Routes registered beside it, like `/api/...`,
still win. [routing.md](routing.md#static-files) has the options
(precompressed files, `Cache-Control`) and `embedded` for files compiled
into the binary.

## TLS

```zig
try app.listenTls(":443", .fromFiles("fullchain.pem", "privkey.pem"));
```

`listenTls` serves HTTPS with HTTP/2 and HTTP/1.1, and HTTP/3 over UDP on
the same port number in the default `full` profile. For local work,
`.dev_self_signed` makes a certificate for localhost in memory, which
clients accept with `curl -k`:

```zig
try app.listenTls("localhost:8443", .dev_self_signed);
```

To serve plain HTTP and HTTPS from one process, name both listeners in the
options and call `run`:

```zig
var app = try anole.App.init(init.gpa, .{
    .http = .{ .address = "", .port = 80 }, // "": every interface, IPv6 and IPv4
    .https = .{ .address = "", .port = 443, .cert = .fromFiles("fullchain.pem", "privkey.pem") },
});
defer app.deinit();
app.get("/", hello);
try app.run();
```

Ports below 1024 need root or `CAP_NET_BIND_SERVICE`. SIGHUP reloads the
certificate files without a restart, which is what a renewal hook needs;
[server.md](server.md#tls) has that, mutual TLS and the HTTP/3 settings.

## gRPC

A service is a `.proto` file, `proto/greeter.proto`:

```proto
syntax = "proto3";

package greeter;

service Greeter {
  rpc SayHello(HelloRequest) returns (HelloReply);
}

message HelloRequest {
  string name = 1;
}

message HelloReply {
  string message = 1;
}
```

Name it in `build.zig`, and `zig build` generates its Zig code into the
cache whenever the file changes. Nothing is installed and nothing generated
is committed:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = @import("anole").addApp(b, .{
        .name = "api",
        .root_source_file = b.path("src/main.zig"),
        .protos = &.{.{ .name = "greeter_pb", .file = b.path("proto/greeter.proto") }},
    });
}
```

The program imports it by that name and gives `app.grpc` a handler for each
method:

```zig
const std = @import("std");
const anole = @import("anole");
const pb = @import("greeter_pb");

fn sayHello(call: *anole.grpc.Call, req: pb.HelloRequest) anyerror!pb.HelloReply {
    if (req.name.len == 0) return call.fail(.invalid_argument, "name is empty");
    return .{ .message = try std.fmt.allocPrint(call.arena, "hello, {s}", .{req.name}) };
}

pub fn main(init: std.process.Init) !void {
    var app = try anole.App.init(init.gpa, .{});
    defer app.deinit();
    app.grpc(pb.Greeter, .{ .SayHello = sayHello });
    try app.listen(":3000");
}
```

gRPC runs over HTTP/2, which `listen` serves in cleartext (h2c) beside
HTTP/1.1, and `listenTls` over TLS. The same route also answers gRPC-Web
and Buf's Connect protocol, so plain curl can call it:

```sh
grpcurl -plaintext -proto proto/greeter.proto -d '{"name":"Ada"}' localhost:3000 greeter.Greeter/SayHello
curl -H 'Content-Type: application/json' -d '{"name":"Ada"}' localhost:3000/greeter.Greeter/SayHello
# {"message":"hello, Ada"}
```

[grpc.md](grpc.md) covers streaming calls, deadlines, metadata, REST routes
from `google.api.http` annotations, the health service and the client.

## Deploying

**Build** with `zig build -Doptimize=ReleaseSafe`, which keeps Zig's safety
checks: a bug panics with a stack trace rather than corrupting memory, as
it could under `ReleaseFast`. The binary is `zig-out/bin/api`, with every C
library linked in; it needs only the system's libc.

**Address.** `listen(":3000")` takes connections on every interface, as a
container or a server needs; `listen("127.0.0.1:3000")` only from this
machine. A listener named in the options without an `address` binds
`127.0.0.1`. To choose at deploy time, read the environment:

```zig
pub fn main(init: std.process.Init) !void {
    var app = try anole.App.init(init.gpa, .{});
    defer app.deinit();
    app.get("/", hello);
    try app.listen(init.environ_map.get("ADDR") orelse ":3000");
}
```

**Stopping.** SIGTERM (or SIGINT) starts a drain: the listeners close,
requests in flight finish, HTTP/2 and HTTP/3 clients get a GOAWAY and
WebSockets a close, for up to 30 seconds (`.server = .{ .timeout = .{
.shutdown = ... } }` in the options). Give the process manager at least
that long before it kills.

**Behind a proxy** such as nginx or a cloud load balancer, set
`.server = .{ .trusted_proxy_hops = 1 }` so `req.remote_address` is the
client's address from `X-Forwarded-For` rather than the proxy's
([server.md](server.md#behind-a-proxy)). Anole serves TLS, HTTP/2 and
HTTP/3 itself, so a proxy is optional.

**systemd.** A minimal unit:

```ini
# /etc/systemd/system/api.service
[Unit]
Description=api
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/api
DynamicUser=yes
Restart=on-failure
# Longer than the drain (30 s by default).
TimeoutStopSec=40
# For ports below 1024:
# AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
```

With `.process = init.minimal` in the options, Anole also takes sockets
from systemd's socket activation, reports readiness (`Type=notify`) and
restarts with no downtime on SIGUSR2 (`systemctl reload`), at the cost of
one TCP listening socket per port rather than one per core (HTTP/3 keeps
one per core);
[server.md](server.md#zero-downtime-restart-and-socket-activation) has the
units.

**Docker.** Build for Linux on any machine, then copy the binary into a
small image with glibc:

```sh
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-gnu   # or aarch64-linux-gnu
```

```dockerfile
FROM gcr.io/distroless/cc-debian12
COPY zig-out/bin/api /api
EXPOSE 3000
ENTRYPOINT ["/api"]
```

Listen on `":3000"`, not `127.0.0.1`, which inside a container is
unreachable from outside it. `docker stop` waits 10 seconds before it kills,
less than the drain: use `docker stop -t 40` (or `stop_grace_period` in
Compose), or shorten `timeout.shutdown`. An image without CA certificates
(`distroless/cc` has them; `debian:*-slim` needs the `ca-certificates`
package) cannot make outbound HTTPS calls.

## Next

- [routing.md](routing.md): routes, middleware, requests, responses,
  errors, limits.
- [server.md](server.md): listeners, TLS, HTTP/2 and HTTP/3, draining,
  restarts.
- [websocket.md](websocket.md), [webtransport.md](webtransport.md), [grpc.md](grpc.md),
  [clients.md](clients.md) (outbound HTTP from a handler with
  `anole.client(req)`), [database.md](database.md) (PostgreSQL, SQLite,
  MongoDB, Redis), [auth.md](auth.md) (JWT, sessions, CSRF, API keys,
  rate limits), [observability.md](observability.md) (metrics, tracing,
  health checks).
- [from-fiber.md](from-fiber.md): Fiber's API next to Anole's.
