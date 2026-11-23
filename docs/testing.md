# Testing

`anole.testing` runs requests against an app in memory: the full router, the
global and group middleware and the error answers, as over HTTP/1.1, with no
socket, no port and no timers. It is the fast way to test routes, middleware
and validation.

```zig
const std = @import("std");
const anole = @import("anole");

test "a blank title is a 422 that names the field" {
    var app = try anole.App.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer app.deinit();
    app.post("/todos", create);

    var t = try anole.testing.client(&app);
    defer t.deinit();
    var res = try t.post("/todos", .{ .json = .{ .title = "   " } });
    defer res.deinit();
    try res.expectStatus(.unprocessable_entity);
    try res.expectViolation("title", "validation.not_blank");
}
```

`client(&app)` accepts an `anole.App` or an `anole.Server(Ctx)`; it prepares
the server as `run` would before binding (helper routes such as `/metrics`
and `/healthz`, the route-conflict check, database connectors such as
`app.sqlite(":memory:")`) and binds nothing. In a test build a route conflict
is `error.RouteConflict` from `client()` (the message is printed, and
`app.routeConflict()` has it), not a crash.

## Requests

`t.get(target, opts)`, `head`, `post`, `put`, `patch`, `delete`, `options`,
`query`, and `t.request(method, target, opts)`. `opts` is a struct literal
with any of:

| Option | Meaning |
| --- | --- |
| `.headers` | `&.{ .{ "X-Api-Key", "k" } }` |
| `.body` | the raw body |
| `.json` | any value, written with std.json; sets `Content-Type: application/json` unless given |
| `.remote_address` | a `std.Io.net.IpAddress` (default 127.0.0.1:50000) |
| `.secure` | whether the connection counts as TLS |
| `.listener` | a listener name, for `anole.onlyOn` routes |

An unknown option is a compile error; so is `.body` with `.json`. The request
is HTTP/1.1 with `Host: localhost` unless given and `Content-Length` set for a
body. Requests run one at a time on the caller's executor; a call returns
when the handler's task has finished and the response has ended.

## Responses

`Response` has `status`, `headers`, `body`, `trailers` and the helpers
`header(name)`, `json(T)`, `expectStatus`, `expectHeader`, `expectBody`,
`expectJson(value)` (compared as JSON: key order and spacing do not matter)
and `expectViolation(field, code)` for a 422 problem document. A failed
expectation prints what was got (the status and the first 2 KiB of the body)
and returns a test error. Deinit every response.

## Streams

```zig
const stream = try t.open(.get, "/events", .{});
defer stream.deinit();
const first = (try stream.nextEvent()).?;
try std.testing.expectEqualStrings("tick", first.data);
```

`open` returns once the head is out. `next()` gives each piece the server
wrote (one write or flush), `nextEvent()` parses server-sent events (comments
and `retry` lines skipped), both `null` once the response ended. `close()`
makes the client leave: further writes fail as for a reset stream, the
handler's task is canceled, and it is awaited. There is no timeout: a test
that waits for an event that never comes hangs.

## Clock

`anole.testing.Clock` is a thread-safe fake clock for testing expiry rules,
rate limits, sessions and response caches without sleeping:

```zig
test "rate limit refills after its window" {
    var clock = anole.testing.Clock.fromSeconds(1_700_000_000);
    var app = try anole.App.init(std.testing.allocator, .{
        .executors = .exact(1),
        .clock = &clock,
    });
    defer app.deinit();
    app.rateLimit(.{ .limit = 2, .window = .fromSeconds(60) });
    app.get("/hello", hello);

    var t = try anole.testing.client(&app);
    defer t.deinit();
    for (0..2) |_| {
        var ok = try t.get("/hello", .{});
        defer ok.deinit();
        try ok.expectStatus(.ok);
    }
    var denied = try t.get("/hello", .{});
    defer denied.deinit();
    try denied.expectStatus(.too_many_requests);

    clock.advance(.fromSeconds(60));
    var again = try t.get("/hello", .{});
    defer again.deinit();
    try again.expectStatus(.ok);
}
```

Passing `.clock = &clock` to `App.init` / `Server.init` threads the clock
through `app.io()` and every `req.io`, so handlers (`std.Io.Clock.real.now(req.io)`,
`std.Io.Clock.awake.now(req.io)`), `app.rateLimit`, `anole.ratelimit.MemoryLimiter`
created with `app.io()`, `anole.session`, `anole.auth` and `ResponseCache` all
read the same simulated time.

When an app is already built by a helper that does not take options, attach a
clock at the test client instead with `anole.testing.clientWith(&app, .{ .clock = &clock })`;
this overrides `req.io` for handlers, `app.rateLimit`, `anole.auth`,
`anole.session` and `ResponseCache`. For standalone unit tests outside a
server, `var bio = clock.io(std.testing.io); defer bio.deinit();` wraps any
`std.Io` so only its clock reads come from `clock` while all other I/O goes to
the inner `std.Io`.

Methods on `Clock`: `init(timestamp)`, `fromSeconds(seconds)`, `now()`,
`nowSeconds()`, `nowMilliseconds()`, `advance(duration)` (positive advances,
negative rewinds, saturating at `i64` nanoseconds), `set(timestamp)`,
`setSeconds(seconds)` and `io(inner)`.

## Logs

```zig
var capture = anole.testing.LogCapture.init(std.testing.allocator);
defer capture.deinit();
capture.start();
// ... a request ...
try capture.expectContains("\"request_id\":\"abc\"");
```

`LogCapture` takes the log records (in the active format, text by default in
tests) in place of stderr until `deinit`; `lines()` gives them.

## What it does not do

- WebSocket and WebTransport: a request with `Upgrade: websocket` is
  `error.WebSocketNotSupported` (a memory sink cannot be upgraded). Use the
  loopback pattern of `tests/rest_test.zig`: `app.listen("127.0.0.1:0")` on
  the test's runtime, a task that connects with `anole.client` or a
  WebSocket client, `app.stop()`.
- Time: `anole.testing.Clock` simulates clock reads (`std.Io.Clock.*.now` and
  `std.Io.Timestamp.now`), while sleeps and socket timeouts still use real time.
- Sockets, TLS, HTTP/2 and HTTP/3 framing: use the loopback pattern.

The examples: `tests/rest_memory_test.zig` (the REST example through
`anole.testing`) next to `tests/rest_test.zig` (the same over a socket).
