# Testing

Up: [SKILL.md](../SKILL.md). Related: [config-cli.md](config-cli.md), [observability.md](observability.md), [runtime.md](runtime.md), [realtime](realtime/index.md).

Full docs: docs/testing.md. Examples: templates/*/src/main_test.zig, tests/rest_memory_test.zig (in memory) next to tests/rest_test.zig (over a socket). Source: src/testing/root.zig.

Do not start a real listener and an HTTP client to test routes, and do not sleep in tests. `anole.testing` runs requests in memory through the full router, middleware and error answers, with no socket, port or timer.

## Pattern: routes() apart from main

Every template splits route registration out of `main` so the test serves the same routes (templates/minimal/src/main.zig):

```zig
/// Apart from `main` so that src/main_test.zig serves the same routes.
pub fn routes(app: *anole.App) void {
    app.get("/", anole.doc(.{ .summary = "A greeting" }, index));
    app.get("/users/:id", user);
    app.post("/echo", echo);
}

pub fn main(init: std.process.Init) !void {
    var app = try anole.App.init(init.gpa, .{});
    defer app.deinit();
    _ = app.health(.{}); // /healthz and /readyz
    routes(&app);
    try app.listen(":3000");
}
```

With state, `routes(app: *anole.Server(App), state: *App) !void`; templates/full also splits out `services(app, state)` (SSE topics, jobs) so tests get them.

## Test step in build.zig

Use: the `App` that `addApp` returns (`app.exe`, `app.anole`) (build.zig); templates/minimal/build.zig:

```zig
// `zig build test`: src/main_test.zig serves the same routes in memory.
const tests = b.addTest(.{ .root_module = b.createModule(.{
    .root_source_file = b.path("src/main_test.zig"),
    .target = app.exe.root_module.resolved_target,
    .optimize = app.exe.root_module.optimize,
    .imports = &.{
        .{ .name = "anole", .module = app.anole.module("anole") },
        .{ .name = "app", .module = app.exe.root_module },
    },
}) });
b.step("test", "Run the tests").dependOn(&b.addRunArtifact(tests).step);
```

Traps:
- Import the app's root module as `"app"` and reuse `app.anole`; do not call `b.dependency("anole", ...)` again ([addApp](config-cli.md#build-side-addapp)).

## The in-memory client

Use: `anole.testing.client(&app)`, `anole.testing.clientWith(&app, .{ .clock = &clock })` (src/testing/root.zig); methods `get`, `head`, `post`, `put`, `patch`, `delete`, `options`, `query`, `request(method, target, opts)`, `open`; `deinit`.

```zig
// templates/minimal/src/main_test.zig
const std = @import("std");
const anole = @import("anole");
const app_main = @import("app");

fn start() !anole.App {
    var app = try anole.App.init(std.testing.allocator, .{ .executors = .exact(1) });
    app_main.routes(&app);
    return app;
}

test "POST /echo checks its rules" {
    var app = try start();
    defer app.deinit();
    var t = try anole.testing.client(&app);
    defer t.deinit();

    var ok = try t.post("/echo", .{ .json = .{ .message = "  hi  " } });
    defer ok.deinit();
    try ok.expectJson(.{ .message = "hi" });

    var blank = try t.post("/echo", .{ .json = .{ .message = "   " } });
    defer blank.deinit();
    try blank.expectStatus(.unprocessable_entity);
    try blank.expectViolation("message", "validation.not_blank");
}
```

Request options (anything else is a compile error; `.body` with `.json` too): `.headers` (`&.{ .{ "X-Api-Key", "k" } }`), `.body`, `.json`, `.remote_address`, `.secure`, `.listener` (for `anole.onlyOn` routes).

Traps:
- Use `std.testing.allocator` and `.executors = .exact(1)` as the templates do (templates/full uses `.exact(2)` where a test needs a second executor).
- `client()` prepares the server as `run` would before binding: helper routes (`/metrics`, `/healthz`), connectors such as `app.sqlite(":memory:")`, the route-conflict check. A conflict is `error.RouteConflict` here, not a crash.
- Requests run one at a time; a call returns once the handler's task finished. `deinit` every response.

## Response helpers

Use: `anole.testing.Response` fields `status`, `headers`, `body`, `trailers`; `header(name)`, `json(T)`, `expectStatus`, `expectHeader`, `expectBody`, `expectJson(value)`, `expectViolation(field, code)` (src/testing/root.zig).

```zig
// templates/full/src/main_test.zig
var created = try t.post("/todos", .{ .json = .{ .title = "write tests" } });
defer created.deinit();
try created.expectStatus(.created);
try created.expectHeader("Location", "/todos/1");
try created.expectJson(.{ .id = 1, .title = "write tests", .done = false });
```

`expectJson` compares as JSON (key order and spacing do not matter). A failed expectation prints the status and the first 2 KiB of the body.

## Streams and logs

`t.open(.get, "/events", .{})` returns an `anole.testing.Stream` once the head is out; `next()` gives each write, `nextEvent()` parses server-sent events, both null at the end; `close()` cancels the handler and awaits it. `anole.testing.LogCapture.init(gpa)`, `start()`, `lines()`, `expectContains(needle)` capture log records until `deinit`.

Traps:
- `next()`/`nextEvent()` have no timeout: a test waiting for an event that never comes hangs.

## Fake clock

Use: `anole.testing.Clock` (`init`, `now`, `advance`, `set`, `io`), `ServerOptions.clock` (src/testing/root.zig, src/server.zig).

```zig
var clock: anole.testing.Clock = .init(.fromNanoseconds(1_700_000_000 * std.time.ns_per_s));
var app = try anole.App.init(std.testing.allocator, .{ .executors = .exact(1), .clock = &clock });
defer app.deinit();
app.rateLimit(.{ .limit = 2, .window = .fromSeconds(60) });
// ... two 200s, then 429 ...
clock.advance(.fromSeconds(60));
```

Traps:
- It fakes clock reads only; sleeps, timers and socket timeouts stay real. Test builds only (`.clock` outside a test build panics).
- `.clock` on `App.init` reaches `app.io()` and what is built on it (`rateLimit`, `responseCache`, sessions); `clientWith(.{ .clock })` reaches only `req.io` of that client's requests.

## Sockets: WebSocket, TLS, HTTP/2, HTTP/3

The in-memory client returns `error.WebSocketNotSupported` for an upgrade. Use the loopback pattern (templates/realtime/src/main_test.zig): a task that waits for the server, then `app.stop()`:

```zig
const Check = struct {
    fn run(a: *Server, st: *app_main.App) !void {
        defer a.stop();
        try a.waitReady();
        var url_buf: [64]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}/ws?room=lobby", .{a.addresses()[0].ip.getPort()});
        var client = anole.client(a.io()).http;
        var first = try client.connectWebSocket(url, .{});
        defer first.deinit();
        // ... a second client, send, receive ...
        try std.testing.expectEqual(2, st.rooms.count("lobby"));
    }
};
var checking = try app.io().concurrent(Check.run, .{ &app, &state });
try app.listen("127.0.0.1:0");
try checking.await(app.io());
```

Traps:
- Port 0 picks a free port; read it from `addresses()` after `waitReady()`.
- `defer a.stop()` in the task, or a failed check leaves `listen` serving forever.
- Wait on events and `waitReady`, never on sleeps or retries. Cancellation rules: [runtime.md](runtime.md#re-raise-errorcanceled).
