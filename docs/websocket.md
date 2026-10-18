# WebSocket

Anole serves WebSockets from ordinary route handlers. One call,
`anole.websocket.upgrade`, accepts the connection whether it arrived over
HTTP/1.1 or HTTP/2, and gives you one `Socket` type for both. The runnable
example is `examples/websocket/main.zig`:

```sh
zig build run-websocket              # http://127.0.0.1:8082 and https://127.0.0.1:8445
zig build run-websocket -- 9000 9443 # other ports
```

It has an echo endpoint (`/echo`), a chat room (`/chat/:room`) and a small
page on `/` that you can open in two browser tabs.

## What is supported

- RFC 6455 over HTTP/1.1 (the `Upgrade: websocket` handshake), on plain and
  TLS listeners. The Autobahn test suite passes all 517 cases.
- RFC 8441 over HTTP/2 (extended CONNECT), over h2c and over TLS. The HTTP/2
  engine advertises `SETTINGS_ENABLE_CONNECT_PROTOCOL` by default.
- permessage-deflate (RFC 7692), on both HTTP versions, when the client
  offers it.
- `anole.websocket.Rooms`, named groups of sockets for broadcast.
- Text messages are checked for valid UTF-8, pings are answered and close
  frames are echoed for you.

WebSocket over HTTP/3 (RFC 9220) is not supported. A request that arrives
over HTTP/3 is not upgraded.

## Build flags

WebSocket is on in the `web` and `full` profiles. `-Dwebsocket=false` removes
it, and `anole.websocket` becomes an empty struct. permessage-deflate needs
`-Dcompression` (zlib-ng). RFC 8441 needs `-Dhttp2`.

## Accepting a connection

Register a normal `GET` route and call `upgrade` in the handler. It returns
null when the request is not a WebSocket handshake, so you can answer it as
plain HTTP:

```zig
fn echo(_: *App, req: *anole.Request, res: *anole.Response) !void {
    var ws = (try anole.websocket.upgrade(req, res, .{
        .max_message_size = 1024 * 1024,
    })) orelse {
        res.status = .bad_request;
        try res.print(.text, "this endpoint speaks WebSocket\n", .{});
        return;
    };
    defer ws.deinit();
    // ...
}
```

The same route serves both versions. An RFC 8441 request reaches the router
as a `GET` with `req.protocol` set to `"websocket"`, and the access log shows
it with status 200 rather than 101. `ws.conn` tells you which one you got
(`.h1` or `.h2`).

The socket lives as long as the handler. It is held in the request's arena,
so do not keep a pointer to it after the handler returns. Always
`defer ws.deinit()`; on HTTP/2 that also ends the stream.

Over HTTP/2, call `anole.websocket.upgrade`, not dusty's
`res.upgradeWebSocket`. The dusty call handles HTTP/1.1 only and returns null
for an HTTP/2 request. If you must keep code that uses it, turn RFC 8441 off
in the server options (keep the stream limit, which this field replaces):

```zig
.http2 = .{ .max_concurrent_streams = 250, .enable_connect_protocol = false },
```

### Upgrade options

`anole.websocket.UpgradeOptions`:

| Field | Default | Meaning |
| --- | --- | --- |
| `max_message_size` | 16 MiB | The largest message `receive` assembles, measured after inflating. |
| `timeout` | `.none` | Replaces the request timeout once the socket is open. |
| `compression` | on with `-Dcompression` | Accept permessage-deflate when the client offers it. |
| `deflate` | see below | Compressor settings. |

## Receiving and sending

`receive` waits for the next text, binary or close message:

```zig
while (true) {
    const msg = ws.receive() catch return;
    switch (msg.type) {
        .text, .binary => ws.send(msg.type, msg.data) catch return,
        .close => return,
        else => {},
    }
}
```

- `msg.type` is `.text`, `.binary` or `.close`. Pings are answered and pongs
  dropped inside `receive`, so you do not see them.
- `msg.data` is valid until the next `receive` on the same socket. Copy it if
  you need it longer.
- A fragmented message arrives whole. A compressed message arrives inflated.
- `receive` returns an error when the peer goes away or breaks the protocol.
  The usual response is to return from the handler.

`send(msg_type, data)` sends one message, `.text` or `.binary`. It is safe to
call from other tasks while the handler is in `receive`; a mutex keeps
messages whole. This is what lets `Rooms.broadcast` send to sockets that
belong to other handlers.

`ping(data)` sends a ping with up to 125 bytes of payload. The pong is
dropped by `receive`.

## Closing

When the client sends a close frame, `receive` echoes it with the same code
and returns a message with `type == .close`. `msg.close_code` holds the code
(null if the client sent none) and `msg.data` the reason. Return from the
handler after that.

To close from the server side, call `close(code, reason)`, then keep calling
`receive` until the client's answer arrives as a `.close` message (or
`receive` fails):

```zig
try ws.close(.going_away, "server restarting");
while (true) {
    const msg = ws.receive() catch break;
    if (msg.type == .close) break;
}
```

Codes are `anole.websocket.CloseCode`: `.normal` (1000), `.going_away`
(1001), `.policy_violation` (1008), `.too_large` (1009) and so on.

When a client sends something invalid (a message over `max_message_size`,
invalid UTF-8, a bad frame), `receive` returns an error. Over HTTP/2 a close
frame with the matching code (1002, 1007 or 1009) goes out first. Over
HTTP/1.1 the connection ends without a close frame, unless the message was
compressed. Either way, return from the handler.

## Timeouts

A WebSocket outlives the server's request timeout (`timeout.request`, 30 s
by default). `upgrade` replaces it with `UpgradeOptions.timeout`, which is
no limit by default. A duration there is a deadline for the whole socket.

For an idle limit, set the timeout again before each `receive`. The example
closes a chat socket that sends nothing for five minutes:

```zig
const chat_idle: std.Io.Duration = .fromSeconds(300);

while (true) {
    req.setTimeout(.{ .duration = .{ .raw = chat_idle, .clock = .awake } });
    const msg = ws.receive() catch return;
    // ...
}
```

When a timeout runs out, the connection is cut (over HTTP/2, only the
stream) and `receive` fails. No close frame is sent.

### Shutdown

On SIGINT or SIGTERM the server stops accepting and waits for requests in
flight, and an open socket counts as one. HTTP/2 connections get a GOAWAY,
but streams already open, WebSockets included, keep running. After
`timeout.shutdown` (30 s by default) the remaining sockets are cut without a
close frame. A handler is not told that a shutdown has started. A server
with long-lived sockets usually wants a shorter wait:

```zig
.server = .{ .timeout = .{ .shutdown = .fromSeconds(5) } },
```

## Compression

With `-Dcompression`, `upgrade` accepts the first permessage-deflate offer it
can take and answers it in the handshake. Then `send` compresses messages and
`receive` inflates them. Set `.compression = false` to refuse the extension
for one endpoint.

`UpgradeOptions.deflate` sets the compressor:

| Field | Default | Meaning |
| --- | --- | --- |
| `window_bits` | 13 | The server's window when the client leaves it open. |
| `mem_level` | 6 | zlib memory level. |
| `level` | 6 | Compression level. |
| `min_length` | 64 | Shorter messages are sent uncompressed. |

Memory per socket is about 2^(window_bits+2) + 2^(mem_level+9) bytes for the
compressor. The server declines an 8-bit server window.

## Rooms

`anole.websocket.Rooms` keeps named groups of sockets. Create one per server
and reach it from your handlers through the server's context type:

```zig
const App = struct {
    rooms: anole.websocket.Rooms,
};

var state: App = undefined;
var app = try anole.Server(App).init(init.gpa, .{ .http = .{ .port = port } }, &state);
defer app.deinit();
state = .{ .rooms = .init(init.gpa, app.io()) };
defer state.rooms.deinit();
app.get("/chat/:room", chat);
```

In the handler, join after the upgrade and leave before the socket goes
away. Defers run in reverse order, so this order is correct:

```zig
fn chat(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const room = req.params.get("room") orelse "lobby";
    var ws = (try anole.websocket.upgrade(req, res, .{})) orelse {
        res.status = .bad_request;
        return;
    };
    defer ws.deinit();
    try app.rooms.join(room, &ws);
    defer app.rooms.leave(room, &ws);

    while (true) {
        const msg = ws.receive() catch return;
        switch (msg.type) {
            .text, .binary => _ = app.rooms.broadcast(room, msg.type, msg.data, null),
            .close => return,
            else => {},
        }
    }
}
```

- `join(room, socket)` and `leave(room, socket)` add and remove a member. A
  room is created on the first join and removed when its last member leaves.
- `broadcast(room, msg_type, data, except)` sends to every member except
  `except` (pass `&ws` to skip the sender, or null for everyone) and returns
  how many members it reached. A member whose send fails is skipped; its own
  `receive` will see the connection end.
- `count(room)` returns the number of members.

Rooms work across HTTP versions and threads: a socket on HTTP/1.1 and one on
HTTP/2 can share a room. One lock covers every room, and a broadcast holds it
while it sends to each member in turn. A slow client therefore slows every
broadcast. For large rooms or slow clients, queue messages per socket in your
own code instead.

## Browsers and HTTP/2

Browsers use RFC 8441 only over TLS (h2), never over h2c. As of 2026-10:

- Firefox opens WebSockets over HTTP/2 when the server advertises extended
  CONNECT.
- Chrome added it behind a flag; whether it is on by default now is not
  confirmed.
- Safari shows no support and uses HTTP/1.1.

Because `upgrade` handles both versions, you do not need to care which one a
browser picks. Try it with the example on `https://127.0.0.1:8445/` (accept
the self-signed certificate) in Firefox; the log reads
`chat: WebSocket over HTTP/2 joined lobby`.

## Clients

`anole.http.Client` can open WebSockets to other servers over HTTP/1.1, with
`ws://` or `wss://` URLs:

```zig
var client = anole.http.Client.init(gpa, io, .{});
defer client.deinit();
var ws = try client.connectWebSocket("ws://127.0.0.1:8082/echo", .{});
defer ws.deinit();
try ws.send(.text, "hello");
const reply = try ws.receive();
```
