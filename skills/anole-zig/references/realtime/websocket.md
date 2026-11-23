# WebSocket

Up: [index](index.md). Related: [rooms](rooms.md) (broadcast), [watch](watch.md) (rooms fed from database changes), [webtransport](webtransport.md).

One `anole.websocket.Socket` type serves RFC 6455 (HTTP/1.1), RFC 8441 (HTTP/2) and RFC 9220 (HTTP/3). Never parse frames or write the handshake yourself. Build flag: on in the `web` and `full` profiles; `-Dwebsocket=false` makes `anole.websocket` an empty struct. permessage-deflate needs `-Dcompression`.

Use:
- `anole.App.ws`, `anole.App.wsWith`, `anole.App.wsCallbacks`, `anole.App.wsCallbacksWith` (src/server.zig; the same on `Server(App)` and on groups)
- `anole.websocket.Socket`: `next`, `receive`, `send`, `ping`, `close`, `httpVersion`, `isClosed`, `draining`, `contextAs`, `deinit`; fields `context`, `close_code`, `end_error`, `subprotocol` (src/websocket/root.zig)
- `anole.websocket.upgrade`, `anole.websocket.isUpgrade`, `anole.websocket.UpgradeOptions`, `anole.websocket.Message`, `anole.websocket.MessageType`, `anole.websocket.CloseCode` (src/websocket/root.zig)

## A handler that loops

```zig
fn echo(ws: *anole.websocket.Socket, _: *anole.Request) !void {
    while (try ws.next()) |msg| try ws.send(msg.type, msg.data);
}

app.ws("/echo", echo);
app.wsWith("/upload", echo, .{ .max_message_size = 4096 });
```

`app.ws` registers a `GET` route on every HTTP version; a plain HTTP request gets 426. Handler shapes: `(ws, req)`, `(ws)`, or on a `Server(App)` `(app, ws, req)`. When it returns the socket is closed with 1000 (1011 on error). `ws.next()` answers pings, echoes the client's close and returns null when the socket is done; it fails only for a cancel or out of memory, so pass that error on with `try`.

## Callbacks for mostly idle sockets

```zig
const Chat = struct {
    pub fn open(ws: *anole.websocket.Socket, req: *anole.Request) !void {
        _ = req; // the request is at hand for the last time here
        try ws.send(.text, "welcome");
    }
    pub fn message(ws: *anole.websocket.Socket, msg: anole.websocket.Message) !void {
        try ws.send(msg.type, msg.data);
    }
    pub fn close(ws: *anole.websocket.Socket) void {
        _ = ws; // free ws.context (the socket leaves its rooms by itself)
    }
};

app.wsCallbacks("/chat", Chat);
```

`message` is required (a compile error otherwise); `open` and `close` are optional and may take the app state first on a `Server(App)`. Over HTTP/1.1 an idle callback socket parks after `timeouts.idle_park` (1 s) and holds no coroutine. Per-socket state goes in `ws.context`, set in `open`, read with `ws.contextAs(T)`, freed in `close`. Prefer callbacks for chat, notifications and live updates with many connections.

## Full control: upgrade in a normal route

```zig
fn chat(app: *App, req: *anole.Request, res: *anole.Response) !void {
    if (!anole.websocket.isUpgrade(req)) return res.fail(.upgrade_required, "");
    const user = (try app.sessions.user(req)) orelse return res.fail(.unauthorized, "");
    var ws = (try anole.websocket.upgrade(req, res, .{
        .subprotocols = &.{"graphql-transport-ws"},
        .headers = &.{.{ .name = "X-User", .value = user.id }},
    })).?;
    defer ws.deinit();
    while (try ws.next()) |msg| try handle(app, &ws, msg);
}
```

`upgrade` returns null when the request is no handshake. Check auth with `isUpgrade` first and answer 401/403 yourself; route middleware also runs before `app.ws` handlers, so a 401 there refuses the handshake.

`UpgradeOptions` fields (all verified): `allowed_origins` (`.same_origin` default, `.{ .list = &.{...} }`, `.any`), `max_message_size` (null: `limits.ws_max_message`, 1 MiB), `timeout`, `compression`, `deflate` (`window_bits`, `mem_level`, `level`, `min_length`), `close_on_drain`, `drain_reason`, `close_timeout` (5 s), `subprotocols`, `headers`.

## Closing from the server

```zig
try ws.close(.going_away, "server restarting");
while (true) {
    const msg = ws.receive() catch break;
    if (msg.type == .close) break;
}
```

## Idle timeout

```zig
const chat_idle: std.Io.Duration = .fromSeconds(300);

while (true) {
    req.setTimeout(chat_idle);
    const msg = ws.receive() catch return;
    // ...
}
```

Traps:
- `msg.data` is valid only until the next `receive`/`next` on that socket (in a callback, only during the call); it may point into the read buffer. Copy it before keeping it or handing it to another task. Debug builds overwrite it with 0xDD.
- The `Socket` lives in the request's arena: never keep a pointer after the handler returns. With `upgrade`, always `defer ws.deinit()` (it also ends the HTTP/2 or HTTP/3 stream and leaves all rooms). See [request arena and lifetimes](../runtime.md#request-arena-and-lifetimes).
- Origins are checked by default: a browser page on another origin gets 403 (`error.Forbidden` from `upgrade`). List extra origins in `allowed_origins`; use `.any` only for an endpoint that does not trust cookies.
- WebSocket over HTTP/2 is off by default (it cost 2.1x CPU per message). Turn it on with `.http2 = .{ .enable_connect_protocol = true }`; HTTP/3 (`.http3.enable_connect_protocol`) is on by default.
- A socket outlives `timeouts.request`: `upgrade` replaces it with `UpgradeOptions.timeout` (none by default). For an idle limit call `req.setTimeout` before each wait. A timeout cuts the connection with no close frame.
- `headers` may not set `Upgrade`, `Connection`, `Sec-WebSocket-*`, `Content-Length` or `Transfer-Encoding` (`error.InvalidHeaderName`); each subprotocol must be a token (`error.InvalidSubprotocol`).
- A text message you send must be valid UTF-8; that is the caller's job. Incoming text is checked (close 1007).
- On drain every socket gets close 1001 and the handler just returns; `ws.draining()` says the close came from the drain. Long-lived sockets hold the drain until `timeouts.shutdown` (10 s; examples/websocket/main.zig:122 says 30 s, which is stale).
- `send` is safe from other tasks beside the handler (a mutex keeps messages whole). To fan out to many sockets use [Rooms](rooms.md), not a loop of `send` calls. See [writes return once buffered](../runtime.md#writes-return-once-buffered).
- A callback may wait (a database call), but messages queue behind it; never block the executor: [never block an executor](../runtime.md#never-block-an-executor).

Outbound client: `anole.http.Client.connectWebSocket(url, .{})` (HTTP/1.1, `ws://` and `wss://`); see [storage, email and clients](../storage-email-clients/index.md).
