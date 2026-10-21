# WebTransport

Anole serves WebTransport over HTTP/3: sessions on the same router as
everything else, each with streams in both directions and datagrams.
`app.webtransport` registers an endpoint in one line;
`anole.webtransport.accept` does the same from an ordinary route handler.
WebSockets over HTTP/3 (RFC 9220) are in [websocket.md](websocket.md).

## What is supported

WebTransport is not an RFC yet (draft-ietf-webtrans-http3-16 is in working
group last call). Anole speaks **draft-02**, the version Chrome, Edge and
Firefox use by default:

- The SETTINGS a browser looks for: `SETTINGS_ENABLE_WEBTRANSPORT`
  (0x2b603742), extended CONNECT (0x08), HTTP datagrams (0x33, RFC 9297) and
  the `max_datagram_frame_size` transport parameter. Safari's
  `SETTINGS_WT_MAX_SESSIONS` (0x14e9cd29) is sent too, but Safari has not
  been tried.
- A session is an extended CONNECT with `:protocol webtransport` (or
  `webtransport-h3`, the later drafts' name), answered with 200.
- Streams opened by either side, unidirectional and bidirectional, each
  carrying its session's ID.
- Datagrams, with the quarter stream ID of RFC 9297.
- Closing with an application code and a message
  (CLOSE_WEBTRANSPORT_SESSION), and DRAIN_WEBTRANSPORT_SESSION when the
  server shuts down.
- Stream resets and STOP_SENDING with 32-bit application codes, mapped onto
  HTTP/3's error codes as the draft says.

Not supported: the later drafts' handshake (13 and on, which need QUIC's
RESET_STREAM_AT and the WT_* flow-control capsules; webtransport-go and
ngtcp2's WebTransport branch speak only those), WebTransport over HTTP/2,
and sessions opened in 0-RTT (a CONNECT that arrives in early data waits for
the handshake).

How it was checked:

- Anole's own tests run sessions between Anole's server and Anole's HTTP/3
  client (`src/h3/webtransport_test.zig`): streams both ways, a 1 MiB echo,
  30 streams at once, 130 unidirectional streams in a row (more than the
  peer's initial limit), datagrams, closes from either side, resets with
  their codes, the drain and a lost connection.
- `tests/h3/run.sh` runs aioquic 1.7.0's client against Anole's server and
  Anole's client against aioquic's server.
- The interop runner's WebTransport mode (`tests/interop/webtransport/run.sh`)
  passes all seven cases against flupke's client. The Chrome and Firefox
  images are x86_64 only and have not been run against Anole yet; CI runs
  them without gating on them.

## Build flags

WebTransport is part of HTTP/3: it needs `-Dhttp3` (on in the `full`
profile), and with it TLS. With `-Dhttp3=false`, `anole.webtransport` is an
empty struct and `app.webtransport` does not compile.

## An endpoint in one line

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

`app.webtransport(path, handler)` registers a `GET` route (extended CONNECTs
reach the router as GETs, as WebSockets do), turns WebTransport on for the
HTTP/3 listener, and calls `handler` with the open session. When the handler
returns, the session is closed with code 0; if it returned an error, with
code 0 and the message `"server error"`, and the error is logged. A request
on that path that is no WebTransport session gets 400.

The handler takes `(session)`, `(session, req)`, or on a `Server(App)`
`(app, session, req)`. `app.webtransportWith(path, handler, options)` takes
the [accept options](#accept-options); groups have `webtransport` and
`webtransportWith` too.

A browser opens it with:

```js
const transport = new WebTransport("https://example.com/echo");
await transport.ready;
```

## Accepting a session

To decide in a handler, turn WebTransport on in the options and call
`accept`. It returns null when the request is not a WebTransport session:

```zig
var app = try anole.App.init(gpa, .{
    .https = .{ .port = 443, .cert = .dev_self_signed },
    .http3 = .{ .webtransport = true },
});

fn game(req: *anole.Request, res: *anole.Response) !void {
    if (req.headers.get("origin")) |origin| {
        if (!std.mem.eql(u8, origin, "https://example.com")) return res.fail(.forbidden, "");
    }
    const session = (try anole.webtransport.accept(req, res, .{})) orelse
        return res.fail(.bad_request, "WebTransport only");
    defer session.deinit();
    // ...
}
```

Headers set on `res` before `accept` go out with its 200, which is how a
handler answers `wt-available-protocols` with `wt-protocol`. A browser
sends `Origin`; check it before accepting, as above, when only your own
pages may connect.

The session lives in the request's arena: `defer session.deinit()`, which
closes it (code 0) if it is still open and lets go of every stream.

### Accept options

`anole.webtransport.AcceptOptions`:

| Field | Default | Meaning |
| --- | --- | --- |
| `timeout` | `.none` | Replaces the request timeout once the session is open. |
| `close_on_drain` | true | Close the session (code 0) when the server starts to drain, right after DRAIN_WEBTRANSPORT_SESSION. |
| `drain_reason` | `"server shutting down"` | The message of that close. |

## Streams

- `session.acceptStream()` waits for the next bidirectional stream the peer
  opens, and `acceptUniStream()` for the next unidirectional one (read
  only).
- `session.openStream()` and `openUniStream()` (write only) open one,
  waiting while the peer's stream limit is reached.

A `*anole.webtransport.Stream` is read with `stream.reader()` and written
with `stream.writer()`, both `std.Io` interfaces. `writer().flush()` sends
what is buffered; `closeSend()` sends it and ends the stream.
`reset(code)` abandons sending, and `stopSending(code)` asks the peer to
stop. A read that ends early fails with `error.ReadFailed`, and
`readError()` says why (`error.StreamReset` with `resetCode()`,
`error.SessionClosed`, ...); `writeError()` and `stopCode()` do the same for
writes.

`release()` when you are done with a stream. A sending side not ended with
`closeSend` is reset then, and a receiving side not read to its end is
stopped. One task may read a stream while another writes it.

## Datagrams

```zig
var buf: [1500]u8 = undefined;
const d = try session.receiveDatagram(&buf);
try session.sendDatagram(d);
```

`receiveDatagram` copies the next datagram into `buf` (`error.NoSpaceLeft`,
and the datagram stays, if it does not fit). `sendDatagram` sends one, and
`maxDatagramSize()` is the largest it takes now (what fits in one packet on
the current path: about 1150 bytes, more once path MTU discovery finds a
larger packet size); a larger one fails with `error.DatagramTooLarge`. Datagrams may be lost,
and nothing says whether one arrived. Up to 256 incoming datagrams (and 1
MiB) wait for a session's handler, and past that new ones are dropped;
`sendDatagram` waits while 256 are queued to go out.

## Closing

`session.close(code, reason)` sends CLOSE_WEBTRANSPORT_SESSION with a 32-bit
application code and a message of at most 1024 bytes, then ends the CONNECT
stream; every stream of the session is reset. When the peer closes, or the
CONNECT stream or the connection goes, every wait on the session fails with
`error.SessionClosed` (or `error.ConnectionClosed`), and
`session.closeInfo()` says how it ended: the code, the message, and `by`
(`.local`, `.peer` or `.connection`). What the CONNECT stream received
before the connection went is read first, so a peer that closes its session
and then its connection right away counts as `.peer`, with its code.

A handler usually loops on `acceptStream` or `receiveDatagram` and returns
when they fail.

## Shutdown

When the server drains, each open session gets DRAIN_WEBTRANSPORT_SESSION
and is then closed with code 0 and `drain_reason`. Its waits fail, and the
handler returns. With `.close_on_drain = false` the session stays open:
`session.draining()` turns true, and the handler finishes up and closes it
itself, before `timeout.shutdown` (30 s) cuts it. `draining()` is also true
when the peer sent DRAIN_WEBTRANSPORT_SESSION.

## Limits

Per connection, the peer may open 100 unidirectional WebTransport streams at
once (beside HTTP/3's own three); its bidirectional streams share
`http3.max_streams_bidi` (100) with requests. Credit comes back as streams
close. Streams that arrive before their session is accepted are held, up to
32 per connection, and refused past that.

## The client

`anole.h3.ClientConnection` opens sessions too, for tests and for programs
that talk to WebTransport servers:

```zig
const conn = try anole.h3.ClientConnection.connect(gpa, io, .{
    .host = "example.com",
    .address = address,
    .port = 443,
    .webtransport = true,
});
defer conn.close();
const session = try conn.openWebTransport(.{ .authority = "example.com", .path = "/echo" });
defer session.deinit();
const stream = try session.openStream();
defer stream.release();
try stream.writer().writeAll("hello");
try stream.closeSend();
const reply = try stream.reader().allocRemaining(gpa, .unlimited);
```

`openWebTransport` fails with `error.WebTransportRefused` when the server
answers anything but 200, and with `error.ExtendedConnectRefused` when its
SETTINGS do not allow extended CONNECT.
