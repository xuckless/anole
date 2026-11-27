# WebTransport

Up: [index](index.md). Related: [websocket](websocket.md) (WebSocket over HTTP/3 is RFC 9220 there), [rooms](rooms.md).

Sessions over HTTP/3 on the same router as everything else, each with streams both ways and datagrams. Anole speaks draft-02, what Chrome, Edge and Firefox use by default. Needs `-Dhttp3` (on in the `full` profile) and with it TLS; without it `anole.webtransport` is an empty struct and `app.webtransport` is a compile error.

Use:
- `anole.App.webtransport`, `anole.App.webtransportWith` (src/server.zig; also on `Server(App)` and groups)
- `anole.webtransport.accept`, `anole.webtransport.AcceptOptions` (`allowed_origins`, `timeout`, `close_on_drain`, `drain_reason`) (src/webtransport.zig)
- `anole.webtransport.Session`: `acceptStream`, `acceptUniStream`, `openStream`, `openUniStream`, `receiveDatagram`, `sendDatagram`, `maxDatagramSize`, `nextDatagram`, `takeDatagram`, `freeDatagram`, `sendDatagramOwned`, `trySendDatagramOwned`, `allocator`, `close`, `closeInfo`, `draining`, `isOpen`, `deinit` (src/h3/webtransport.zig)
- `anole.webtransport.Stream`: `reader`, `writer`, `closeSend`, `reset`, `stopSending`, `release`, `readError`, `writeError`, `resetCode`, `stopCode`, `setPriority` (src/h3/webtransport.zig)
- `anole.webtransport.CloseInfo`, `anole.webtransport.Error` (src/webtransport.zig)

## An endpoint in one line (docs/webtransport.md)

```zig
fn echo(session: *anole.webtransport.Session) !void {
    while (true) {
        const stream = session.acceptStream() catch return;
        defer stream.release();
        _ = try stream.reader().streamRemaining(stream.writer());
        try stream.closeSend();
    }
}

app.webtransport("/echo", echo);
```

`app.webtransport` registers a `GET` route, turns WebTransport on for the HTTP/3 listener, and calls the handler with the open session. Handler shapes: `(session)`, `(session, req)`, or on a `Server(App)` `(app, session, req)`. On return the session is closed with code 0 (on error: code 0, `"server error"`, logged). A non-WebTransport request on that path gets 400.

## Deciding in a handler

```zig
var app = try anole.App.init(gpa, .{
    .https = .{ .port = 443, .cert = .dev_self_signed },
    .http3 = .{ .webtransport = true },
});

fn game(req: *anole.Request, res: *anole.Response) !void {
    const session = (try anole.webtransport.accept(req, res, .{})) orelse
        return res.fail(.bad_request, "WebTransport only");
    defer session.deinit();
    // ...
}
```

Headers set on `res` before `accept` go out with its 200 (answer `wt-available-protocols` with `wt-protocol` this way).

## Datagrams

```zig
var buf: [1500]u8 = undefined;
const d = try session.receiveDatagram(&buf);
try session.sendDatagram(d);
```

Without copies, to relay between sessions of the same server:

```zig
const d = try a.nextDatagram();
errdefer a.freeDatagram(d);
try b.sendDatagramOwned(d);
```

Traps:
- `accept` without `app.webtransport` needs `.http3 = .{ .webtransport = true }` in the server options.
- `webtransportWith` takes `AcceptOptions` at comptime (src/server.zig:2537), unlike `wsWith`, whose `UpgradeOptions` are run time.
- The session lives in the request's arena: `defer session.deinit()` (closes it with code 0 if open and lets go of every stream). Call `release()` on every stream you accept or open; an unreleased peer stream keeps holding the peer's stream credit even after it ended, and the peer cannot open more.
- Origins are checked like WebSockets (`allowed_origins`, `.same_origin` default; a CONNECT from another origin gets 403).
- A stream write returns once buffered: up to 1 MiB unacknowledged per stream and 4 MiB per connection; only past that does it wait. Do not hold one lock across writes to several streams of a user, or one slow stream stalls the others: lock per stream. See [writes return once buffered](../runtime.md#writes-return-once-buffered).
- A read that ends early fails with `error.ReadFailed`; `readError()` says why (`error.StreamReset` with `resetCode()`, `error.SessionClosed`, ...). `writeError()` and `stopCode()` do the same for writes.
- Datagrams may be lost and nothing reports it. `sendDatagram` fails with `error.DatagramTooLarge` past `maxDatagramSize()` (about 1150 bytes until path MTU discovery finds more). `receiveDatagram` fails with `error.NoSpaceLeft` (the datagram stays) if `buf` is too small. Past 256 queued (or 1 MiB) incoming datagrams new ones are dropped; `sendDatagram` waits while 256 are queued to go out.
- A buffer moved with `sendDatagramOwned` must be a whole buffer from the session's `allocator()` (or from `nextDatagram`/`takeDatagram`), never a slice. On success the queue owns it; on any error (`Canceled` too) the caller still does. Between a client's and a server's session, copy with `b.allocator().dupe(u8, d)`.
- `setPriority(urgency)`: 0 most urgent to 7, default 3. A busy stream at 0 starves the rest: mark audio or control 2, not 0.
- When the session ends, every wait fails with `error.SessionClosed` (or `error.ConnectionClosed`); `closeInfo()` gives the code, message and `by` (`.local`, `.peer`, `.connection`). A handler loops on `acceptStream` or `receiveDatagram` and returns when they fail.
- On drain the session gets DRAIN_WEBTRANSPORT_SESSION and is closed with `drain_reason`; with `.close_on_drain = false` watch `session.draining()` and close it yourself before `timeouts.shutdown` (10 s).
- Not supported: drafts 13 and later (webtransport-go and ngtcp2's branch speak only those), WebTransport over HTTP/2, sessions opened in 0-RTT.

Client for tests: `anole.h3.ClientConnection.connect(gpa, io, .{ ..., .webtransport = true })` then `conn.openWebTransport(.{ .authority = ..., .path = ... })` (docs/webtransport.md "The client"); see [testing](../testing.md).
