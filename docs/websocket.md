# WebSocket

Anole serves WebSockets over HTTP/1.1, HTTP/2 and HTTP/3 with one `Socket`
type for all three. `app.ws` registers an endpoint in one line; `anole.websocket.upgrade`
does the same from an ordinary route handler, for full control. The
runnable example is `examples/websocket/main.zig`:

```sh
zig build run-websocket              # http://127.0.0.1:8082 and https://127.0.0.1:8445
zig build run-websocket -- 9000 9443 # other ports
```

It has an echo endpoint (`/echo`), a chat room (`/chat/:room`) and a small
page on `/` that you can open in two browser tabs.

## What is supported

- RFC 6455 over HTTP/1.1 (the `Upgrade: websocket` handshake), on plain and
  TLS listeners. The Autobahn test suite passes all 517 cases.
- RFC 8441 over HTTP/2 (extended CONNECT), over h2c and over TLS, when you
  turn it on with `.http2 = .{ .enable_connect_protocol = true }` (off by
  default since 0.3.0; see [WebSocket over HTTP/2 is
  opt-in](#websocket-over-http2-is-opt-in)).
- RFC 9220 over HTTP/3 (extended CONNECT again), on the HTTP/3 listener. It
  too advertises `SETTINGS_ENABLE_CONNECT_PROTOCOL` by default. Checked
  against aioquic's client (`tests/h3/run.sh`): text, binary, ping, close
  and the drain's 1001.
- permessage-deflate (RFC 7692), on every HTTP version, when the client
  offers it.
- `anole.websocket.Rooms`, named groups of sockets for broadcast.
- Text messages are checked for valid UTF-8, pings are answered and close
  frames are echoed for you.

## Build flags

WebSocket is on in the `web` and `full` profiles. `-Dwebsocket=false` removes
it, and `anole.websocket` becomes an empty struct. permessage-deflate needs
`-Dcompression` (zlib-ng). RFC 8441 needs `-Dhttp2`, and RFC 9220
`-Dhttp3`.

## An endpoint in one line

```zig
fn echo(ws: *anole.websocket.Socket, _: *anole.Request) !void {
    while (try ws.next()) |msg| try ws.send(msg.type, msg.data);
}

app.ws("/echo", echo);
```

`app.ws(path, handler)` registers a `GET` route that accepts the WebSocket,
on any HTTP version, and calls `handler` with the open socket. When the
handler returns, the socket is closed with 1000 (1011 if it returned an
error, nothing if it is closed already). A plain HTTP request on that path
gets 426 Upgrade Required. The server's drain closes the socket with 1001
(see [Shutdown](#shutdown)).

`ws.next()` returns the next text or binary message, or null once the
socket is done: the client closed it (the close is answered for you) or the
connection ended (`ws.end_error` says how). It fails only for a cancel or no
memory, which the handler should pass on.

The handler takes `(ws, req)`, `(ws)` alone, or on a `Server(App)`
`(app, ws, req)`. `app.wsWith(path, handler, options)` takes the
[upgrade options](#upgrade-options) (at compile time); groups have `ws` and
`wsWith` too.

## Callbacks

A socket that is idle most of the time (chat, notifications, live updates)
can be served through callbacks instead of a handler that loops:

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

`message` is required; `open` and `close` are optional, and each may take
the app state first on a `Server(App)`. `open` runs right after the
handshake; `message` for each text or binary message, its data valid
during the call; `close` once, when the socket is done, whoever ended it
(`ws.close_code` holds the client's close code, `ws.end_error` another
cause). A failing `open` or `message` closes the socket with 1011. Keep
per-socket state behind `ws.context` (`ws.contextAs(T)` reads it back),
set in `open` and freed in `close`.

Over HTTP/1.1 a callback socket holds no coroutine while it waits: when
nothing has arrived for `timeouts.idle_park` (1 s), it gives up its buffers
and parks, a few kilobytes on the heap, and the next message starts a
coroutine for it on the same executor. The callbacks run there one at a
time and may wait (a database call, a lock); messages that arrive meanwhile
wait their turn. Pings are answered and replies batched as with
`ws.next()`. `ws.send` and `ws.close` work from any task at any time; to a
parked socket each frame goes out in one write of its own. Over HTTP/2 and
HTTP/3 the callbacks run on the stream's task as a loop would.

`app.wsCallbacksWith(path, Callbacks, options)` takes the
[upgrade options](#upgrade-options); with `timeout` set the socket is
closed at that deadline, parked or not. Groups have both too.

## Accepting a connection

Register a normal `GET` route and call `upgrade` in the handler. It returns
null when the request is not a WebSocket handshake, so you can answer it as
plain HTTP:

```zig
fn echo(_: *App, req: *anole.Request, res: *anole.Response) !void {
    var ws = (try anole.websocket.upgrade(req, res, .{
        .max_message_size = 1024 * 1024,
    })) orelse return res.fail(.bad_request, "this endpoint speaks WebSocket");
    defer ws.deinit();
    // ...
}
```

The same route serves every version. An RFC 8441 or RFC 9220 request
reaches the router as a `GET` with `req.protocol` set to `"websocket"`. On
the wire the server accepts it with a 200, as both RFCs require, but the
access log, metrics and spans record it as 101, like an HTTP/1.1 upgrade, so
a WebSocket reads the same on all of them. `ws.httpVersion()` tells you
which version you got (`.http1`, `.http2` or `.http3`), and `ws.isClosed()`
whether a close went out or came in or the connection ended.

The socket lives as long as the handler. It is held in the request's arena,
so do not keep a pointer to it after the handler returns. Always
`defer ws.deinit()`; on HTTP/2 and HTTP/3 that also ends the stream.

Always open a socket with `anole.websocket.upgrade` (or `app.ws`,
`app.wsCallbacks`): it covers all three versions, checks `Origin` and
negotiates the extensions.

### WebSocket over HTTP/2 is opt-in

RFC 8441 handshakes are off by default since 0.3.0: the HTTP/2 engine does
not advertise `SETTINGS_ENABLE_CONNECT_PROTOCOL`, so clients open their
WebSockets over HTTP/1.1, on a connection of their own. Measured on an x86
Linux box (a video-call relay, #91), WebSocket over HTTP/2 served 38% fewer
users than over HTTP/1.1, at 2.1 times the CPU per message, and Firefox
uses it whenever a server offers it. To accept it anyway (keep the stream
limit, which this field replaces):

```zig
.http2 = .{ .max_concurrent_streams = 250, .enable_connect_protocol = true },
```

RFC 9220 over HTTP/3 stays on; `.http3 = .{ .enable_connect_protocol =
false }` turns it off. A plain CONNECT, without `:protocol`, gets 501 over
HTTP/3: Anole is no proxy.

### Upgrade options

`anole.websocket.UpgradeOptions`:

| Field | Default | Meaning |
| --- | --- | --- |
| `allowed_origins` | `.same_origin` | The pages that may open the socket (see [Origins](#origins)). |
| `max_message_size` | `limits.ws_max_message` (1 MiB) | The largest message `receive` assembles, measured after inflating. |
| `timeout` | `.none` | Replaces the request timeout once the socket is open. |
| `compression` | on with `-Dcompression` | Accept permessage-deflate when the client offers it. |
| `deflate` | see below | Compressor settings. |
| `close_on_drain` | true | Send close 1001 when the server starts to drain (see [Shutdown](#shutdown)). |
| `drain_reason` | `"server shutting down"` | The reason in that close frame. |
| `subprotocols` | none | The subprotocols you speak, most preferred first (see [Subprotocols and handshake headers](#subprotocols-and-handshake-headers)). |
| `headers` | none | Extra headers on the handshake's answer. |

### Subprotocols and handshake headers

Browsers fail a connection whose answer does not echo the subprotocol they
asked for (graphql-transport-ws, STOMP, MQTT). List yours, most preferred
first; the first one the client offered in `Sec-WebSocket-Protocol` is
selected and echoed, and `ws.subprotocol` says which (null when the client
offered none of them: the socket then opens without one, as RFC 6455
4.2.2 asks). Each must be a token.

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

`headers` go out with the handshake's answer (a cookie, a request ID). The
names the handshake writes itself (`Upgrade`, `Connection`,
`Sec-WebSocket-*`) and the framing headers (`Content-Length`,
`Transfer-Encoding`) are refused with `error.InvalidHeaderName`.

`anole.websocket.isUpgrade(req)` tells a handler whether the request is a
handshake before it decides (authentication, rate limits): answer 401 or
403 yourself instead of calling `upgrade`, as a browser sees them as a
failed connection. `offeredSubprotocols(req)` iterates what the client
offered and `selectSubprotocol(req, preferred)` applies the rule. Route
middleware runs before `app.ws` and `app.wsCallbacks` handlers, so a 401
from middleware refuses those handshakes too.

### Origins

A browser sends the page's cookies with a WebSocket handshake whatever page
opens it, and a WebSocket is not subject to CORS. Without a check, any site
a logged-in user visits could open a socket to your server in that user's
name and read what it receives. So `upgrade` (and `app.ws`,
`app.wsCallbacks`, and WebTransport's `accept`) looks at the handshake's
`Origin` header and by default lets through only pages on the request's
own host and port, as `Host` names it (over HTTP/2 and HTTP/3,
`:authority`; behind a trusted proxy, `X-Forwarded-Host`). The scheme is not
compared, so a proxy that terminates TLS does not get in the way. Anything
else gets 403 Forbidden: `upgrade` fails with `error.Forbidden`, which the
server answers as 403 when the handler returns it.

Clients that send no `Origin` (command-line tools, servers, mobile apps) are
not affected: only browsers send it, and only they add credentials on their
own.

To let pages of other origins connect, list them, as the browser writes
them (scheme, host, and the port unless it is the default):

```zig
var ws = (try anole.websocket.upgrade(req, res, .{
    .allowed_origins = .{ .list = &.{ "https://app.example.com", "http://localhost:5173" } },
})) orelse return res.fail(.bad_request, "");
```

`app.wsWith(path, handler, .{ .allowed_origins = ... })` takes the same
options. `.any` lets every page in; use it only for an endpoint that does
not trust cookies or other credentials the browser adds itself, such as one
that authenticates with a token in its first message. The C ABI's WebSocket
routes take `"origins": ["https://app.example.com"]` (or `["*"]`).

## Receiving and sending

`next` (above) is the short form. `receive` waits for the next text, binary
or close message:

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
invalid UTF-8, a bad frame), `receive` returns an error, and a close frame
with the matching code goes out first: 1009 for a message too large, 1007
for text that is not UTF-8, 1002 for any other protocol error. This holds
on every HTTP version. Return from the handler.

## Timeouts

A WebSocket outlives the server's request timeout (`timeouts.request`, 30 s
by default). `upgrade` replaces it with `UpgradeOptions.timeout`, which is
no limit by default. A duration there is a deadline for the whole socket.

For an idle limit, set the timeout again before each `receive`. The example
closes a chat socket that sends nothing for five minutes:

```zig
const chat_idle: std.Io.Duration = .fromSeconds(300);

while (true) {
    req.setTimeout(chat_idle);
    const msg = ws.receive() catch return;
    // ...
}
```

When a timeout runs out, the connection is cut (over HTTP/2 and HTTP/3,
only the stream) and `receive` fails. No close frame is sent.

### Shutdown

On SIGINT or SIGTERM the server stops accepting and waits for requests in
flight, and an open socket counts as one. When the drain starts, every open
socket, on HTTP/1.1, HTTP/2 or HTTP/3, is sent close 1001 (going away) with the
reason `"server shutting down"`. A handler does not need to do anything:
the client answers the close, `receive` returns that answer as a `.close`
message, and the handler returns as it would for any close. Sending after
that fails. `ws.draining()` tells a handler that the close came from the
drain rather than from the client:

```zig
const msg = ws.receive() catch return;
if (msg.type == .close) {
    if (ws.draining()) std.log.info("closed for shutdown", .{});
    return;
}
```

To say something else first, such as where to reconnect, turn the automatic
close off with `.close_on_drain = false` and watch for the drain yourself.
`ws.draining()` turns true when it starts, and `req.drain` is the event
behind it, which a task of your own can wait on. Then close the socket
yourself with `ws.close(.going_away, ...)` and keep calling `receive` until
the answer arrives.

A client that never answers the close holds its socket open until
`timeouts.shutdown` (10 s by default) runs out; the remaining sockets are then
cut without a further frame. A server with long-lived sockets may want a
shorter wait:

```zig
.timeouts = .{ .shutdown = .fromSeconds(5) },
```

The close is sent by a small task beside each socket's handler, on the same
executor. It ends with `ws.deinit()`, which is one more reason to always
`defer` it.

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
and reach it from your handlers through the server's context type.
`Rooms.init(allocator, .{})` takes an allocator and options (the rooms take
the runtime's `std.Io` from the first socket that joins), so it can be made before the server:

```zig
const App = struct {
    rooms: anole.websocket.Rooms,
};

var state: App = .{ .rooms = .init(init.gpa, .{}) };
defer state.rooms.deinit();
var app = try anole.Server(App).init(init.gpa, .{}, &state);
defer app.deinit();
app.ws("/chat/:room", chat);
try app.listen(":8082");
```

In the handler, join after the upgrade. A socket leaves every room it is in
when it is released (`Socket.deinit`, which `app.ws` and `app.wsCallbacks`
run for you, and which a handler that calls `upgrade` itself defers), so a
broadcast never reaches a socket that is gone:

```zig
fn chat(app: *App, ws: *anole.websocket.Socket, req: *anole.Request) !void {
    const room = req.params.get("room") orelse "lobby";
    try app.rooms.join(room, ws);
    while (try ws.next()) |msg| _ = app.rooms.broadcast(room, msg.type, msg.data, null);
}
```

- `join(room, socket)` adds a member, and `leave(room, socket)` takes it out
  before the socket ends (switching rooms, say). A room is created on the
  first join and removed when its last member leaves. Joining a room the
  socket is already in does nothing. The `Rooms` must outlive the sockets
  that join it.
- `broadcast(room, msg_type, data, except)` queues the message for every
  member except `except` (pass `&ws` to skip the sender, or null for
  everyone) and returns for how many members it was queued. It never waits
  for a member to be sent to.
- `count(room)` returns the number of members.

Rooms work across HTTP versions, tasks and threads: sockets on HTTP/1.1,
HTTP/2 and HTTP/3 can share a room, and anything may broadcast. A broadcast
copies the message once and adds it to each member's queue under a short
lock. Each member with something queued has a task of its own, on the
socket's executor, that sends its queue in order. A slow client therefore
holds up nobody else, not even the broadcaster: it only fills its own queue.

The queue is bounded. `Rooms.init(allocator, .{ ... })` sets
`anole.websocket.Rooms.Options`:

| Field | Default | Meaning |
| --- | --- | --- |
| `max_queued_bytes` | 1 MiB | The most broadcast bytes waiting for one member (each message counts 64 bytes more). A message is always taken when nothing waits. |
| `on_full` | `.close` | `.close`: messages that do not fit are skipped, and a member whose send has been stuck for `close_after_ms` is closed: it gets no more broadcasts, the send under way to it is canceled, and its connection is ended (a TCP shutdown over HTTP/1.1, a stream reset over HTTP/2 and HTTP/3), so its handler's `receive` ends and its `close` callback runs. `.drop`: messages that do not fit are skipped and the member stays. |
| `close_after_ms` | 1000 | With `.close`, how long a full member's send must have been stuck. |
| `leave_grace_ms` | 1000 | How long `leave` lets a send under way to the leaving socket finish before it cancels it. |

A member whose send fails gets nothing more; its own `receive` sees the
connection end. A member closed for not keeping up has its connection ended
for it, as above, and leaves its rooms as its socket is released. Leaving,
by `leave` or by the release, drops what is still queued for the socket and
waits for a send under way, at most `leave_grace_ms`, so a socket is never
sent to once it has left or been released.

## Browsers, HTTP/2 and HTTP/3

Browsers use RFC 8441 only over TLS (h2), never over h2c. As of 2026-10:

- Firefox opens WebSockets over HTTP/2 when the server advertises extended
  CONNECT (Anole does only with `http2.enable_connect_protocol = true`).
- Chrome added it behind a flag; whether it is on by default now is not
  confirmed.
- Safari shows no support and uses HTTP/1.1.

No browser opens WebSockets over HTTP/3 by default yet: Chrome has RFC 9220
behind a flag (`kEnableWebsocketsOverHttp3`, off), and Firefox has no
setting for it. RFC 9220 is there for clients that do, such as aioquic's.

Because `upgrade` handles every version, you do not need to care which one a
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
