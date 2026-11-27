# WebSocket Rooms

Up: [index](index.md). Related: [websocket](websocket.md) (sockets, handlers), [watch](watch.md) (feed a room from database changes), [sse](sse.md) (the same fan-out for browsers that only listen).

`anole.websocket.Rooms` is Anole's pub/sub for WebSockets: named groups of sockets, broadcast from anywhere (any task, thread, HTTP version). Do not build a `StringHashMap` of socket lists with your own mutex.

Use:
- `anole.websocket.Rooms`: `init`, `deinit`, `join`, `leave`, `broadcast`, `count` (src/websocket/root.zig)
- `anole.websocket.Rooms.Options`: `max_queued_bytes`, `on_full` (`anole.websocket.Rooms.OnFull`: `.close`, `.drop`), `close_after_ms`, `leave_grace_ms` (src/websocket/root.zig)
- `anole.Server(App).io` (src/server.zig)

## Setup (examples/websocket/main.zig, templates/realtime/src/main.zig)

```zig
const App = struct {
    rooms: anole.websocket.Rooms,
};

pub fn main(init: std.process.Init) !void {
    var state: App = .{ .rooms = undefined };
    var app = try anole.Server(App).init(init.gpa, .{}, &state);
    defer {
        app.deinit();
        state.rooms.deinit();
    }
    // The rooms take the runtime's io (`app.io()`, not `init.io`).
    state.rooms = .init(init.gpa, app.io(), .{});
    app.ws("/chat/:room", chat);
    try app.listen(":8082");
}
```

## Join and broadcast (examples/websocket/main.zig)

```zig
fn chat(app: *App, ws: *anole.websocket.Socket, req: *anole.Request) !void {
    const room = req.params.get("room") orelse "lobby";
    try app.rooms.join(room, ws);
    defer app.rooms.leave(room, ws);
    while (try ws.next()) |msg| _ = app.rooms.broadcast(room, msg.type, msg.data, null);
}
```

- `join(room, socket)`: a room is created on the first join and removed when its last member leaves; joining twice does nothing.
- `leave(room, socket)`: only needed to leave before the socket ends (switching rooms). Released sockets leave every room by themselves (`Socket.deinit`, which `app.ws` and `app.wsCallbacks` run for you).
- `broadcast(room, msg_type, data, except)`: pass `ws` to skip the sender, null for everyone. Returns for how many members it was queued.
- `count(room)`: members now.

## Back-pressure on a room

A broadcast copies the message once and queues it per member; each member with something queued has its own sender task on the socket's executor. A slow client fills only its own queue and holds up nobody, not even the broadcaster. Defaults (`Rooms.Options`):

| Field | Default | Meaning |
| --- | --- | --- |
| `max_queued_bytes` | 1 MiB | Broadcast bytes waiting for one member (each message counts 64 more). A message is always taken when nothing waits. |
| `on_full` | `.close` | `.close`: messages that do not fit are skipped, and a member stuck for `close_after_ms` has its connection ended (its `receive` ends, its `close` callback runs). `.drop`: skip and keep the member. |
| `close_after_ms` | 1000 | How long a full member's send must be stuck before it is closed. |
| `leave_grace_ms` | 1000 | How long `leave` lets a send under way finish before canceling it. |

Traps:
- Free the `Rooms` after `app.deinit()`, never before: jobs, watches and sockets may still use it until then. Use the `defer { app.deinit(); state.rooms.deinit(); }` block above (docs/websocket.md "Rooms", examples/websocket/main.zig, templates/realtime and templates/full do exactly this).
- `Rooms.init` takes `app.io()`, the runtime's `std.Io`, not `init.io`: the sockets run on the runtime. So initialise it after `Server(App).init` (start with `.rooms = undefined`) and before `listen`/`run`. General rule: [use the server's io](../runtime.md#use-the-servers-io).
- The `Rooms` must outlive every socket that joined it.
- `broadcast` never waits for a member and never fails: a skipped member (queue full) is not counted in its return value, and it returns 0 when the copy cannot be allocated. Use the return value (or `count`) if you need to know who got it; a member that cannot keep up is closed, not waited for.
- Members that join while a broadcast runs do not get it. A socket that has left or been released is never sent to.
- Broadcasting from a job, a watch or another task is fine; Rooms are safe from any task or thread of the runtime.
