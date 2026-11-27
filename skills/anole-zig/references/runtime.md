# Runtime rules

Up: [SKILL.md](../SKILL.md). Zig-side background: [zig-0.17.md](zig-0.17.md).
Full docs: docs/server.md (Blocking work, Response buffering), docs/routing.md
(Async work in handlers). Example: examples/io/main.zig.

Anole runs every handler as a coroutine on zio executors, one OS thread per
core (src/root.zig, `anole.zio`). These rules apply to every area of the
skill; other files link here instead of repeating them.

## Use the server's io

Every handler gets the server's `std.Io` as `req.io`; outside a handler use
`app.io()` (`anole.App.io`, src/server.zig), and only after `App.init` /
`Server(Ctx).init`. A wait through it (socket, file, timer, outbound request)
suspends that request only.

```zig
fn slow(req: *anole.Request, res: *anole.Response) !void {
    try req.io.sleep(.fromMilliseconds(200), .awake);
    try res.print(.text, "done", .{});
}
```

Traps:
- `init.io` from `std.process.Init` is not the server's runtime. Anything
  sockets touch (Rooms, Topics, clients you make) takes `app.io()`, never
  `init.io` (docs/migrating.md, examples/websocket/main.zig).
- Shared state needs atomics or `std.Io.Mutex` / `std.Io.RwLock`: a task
  waiting on those yields instead of blocking its executor (docs/server.md,
  "The server value").
- A root file that sets `zio_options` must keep pinned scheduling:
  `pub const zio_options = anole.zio_options;` (src/root.zig).

## Never block an executor

A long computation or a C library that blocks in its own system calls holds
its executor's thread, and every connection on that executor waits. Run it
on the blocking pool with `anole.blocking.run` (src/blocking.zig):

```zig
var app = try anole.Server(App).init(gpa, .{ .blocking = .{} }, &state); // .{ .threads = 4 }

fn report(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const total = try anole.blocking.run(req.io, crunch, .{ app.data });
    try res.print(.text, "{d}\n", .{total});
}
```

Traps:
- The result adds `error.Canceled` and `error.ServiceUnavailable` (503 when
  more than `max_waiting` callers queue) to `crunch`'s errors.
- A job is never interrupted; a canceled caller still waits for it, then
  gets `error.Canceled` (src/blocking.zig header).
- Password hashing already uses the pool: call `anole.auth.password.verify`,
  don't wrap it again (src/auth/password.zig).
- Never `std.Thread.sleep` or a busy loop in a handler; use `req.io.sleep`.

## Re-raise error.Canceled

When a client resets its stream or the connection is lost, the handler's
next wait on `req.io` returns `error.Canceled` (docs/server.md). Let it
propagate. Code that catches it to return something else must put the
cancelation back with `io.recancel()` (`std.Io.recancel`), as Anole's own
code does (src/auth/password.zig):

```zig
return blocking.run(io, verifyHere, .{ gpa, io, stored, password }) catch |err| switch (err) {
    error.Canceled => {
        io.recancel();
        return false;
    },
    error.ServiceUnavailable => |e| return e,
};
```

Traps:
- `catch {}` or `catch |_| return default` on a wait swallows the cancel;
  a job handler that does this and returns success counts as done
  (docs/jobs.md).

## Writes return once buffered

A handler's write returns once its bytes are queued, and waits only while
the response already holds as much as its cap allows (docs/server.md,
"Response buffering"). A WebSocket broadcast queues per member and never
waits for a member to be sent to (docs/websocket.md, Rooms). Back-pressure
is signalled (a bounded queue, a 503, a close), never hidden in a write:
don't add your own send queues or sleeps to "wait for the peer".

## Request arena and lifetimes

- `req.arena` is freed after the response. Use it for anything that lives
  only for this request (`std.fmt.allocPrint(req.arena, ...)`).
- `res.body` must outlive the handler: a literal or memory from the arena
  (docs/routing.md, Response).
- The arena is not thread-safe. A call the handler awaits may use it; a
  task from `req.io.concurrent` or a thread needs memory of its own
  (docs/routing.md, examples/io/main.zig `handleFanout`).
- Long-lived values (clients, Rooms, Topics, caches) live in the
  `Server(Ctx)` state and are made with the gpa, not the arena.
- Pooled database connections have their own ordering rule; see
  [databases](databases/index.md).
