# TCP and UDP servers

Not every backend speaks HTTP. A game server, a line protocol, a custom RPC,
a DNS-style responder or a telemetry collector wants raw TCP or UDP, and
wants what Anole's HTTP listeners already have: one accept loop per core,
TLS with hot reload, the PROXY protocol, connection limits, a graceful
drain, socket activation, zero-downtime restarts and metrics. `anole.net`
serves your protocol on those same listeners, in the same process, beside
HTTP:

```zig
const std = @import("std");
const anole = @import("anole");

const Echo = struct {
    pub fn data(conn: *anole.net.Conn, bytes: []const u8) !void {
        _ = try conn.send(bytes);
    }
};

const Pong = struct {
    pub fn datagram(d: *anole.net.Datagram) !void {
        try d.reply(d.data);
    }
};

pub fn main(init: std.process.Init) !void {
    var app = try anole.App.init(init.gpa, .{});
    defer app.deinit();
    try app.tcp(":7000", Echo, .{}); // a line protocol, a game, a custom RPC
    try app.udp(":7001", Pong, .{}); // datagrams, batched both ways
    try app.listen(":3000"); // HTTP beside them, one process
}
```

Raw listeners are behind `-Dnet` (on in the `web` and `full` profiles, off in
`minimal`); there is no C library behind them. A server that names only raw
listeners opens no HTTP listener: `app.tcp(...)` and `app.run()` serve the
raw listener alone. A raw listener always needs a port of its own (0 for a
free one) or a unix socket path; it never takes `$PORT` or the 8080 default.

From Node, `anole-node` gives these listeners `node:net`'s and `node:dgram`'s
shapes, and from Python an asyncio `Protocol` and `DatagramProtocol`; see
[c-abi.md](c-abi.md) for the events they are built on.

## 1. A TCP server in ten lines

A handler is a type with callbacks. Only the one that takes input is needed:
`data(conn, bytes)` without a framing, `message(conn, frame)` with one.

```zig
const Chat = struct {
    // Optional: one per connection, `.{}`-initialized; `conn.contextAs(State)`.
    pub const State = struct { name: [32]u8 = undefined, name_len: u8 = 0 };

    pub fn open(conn: *anole.net.Conn) !void { ... }                         // optional
    pub fn message(conn: *anole.net.Conn, line: []const u8) !void { ... }
    pub fn end(conn: *anole.net.Conn) !void { ... }                          // optional: the peer's FIN (half_open)
    pub fn writable(conn: *anole.net.Conn) !void { ... }                     // optional: after a busy send
    pub fn drain(conn: *anole.net.Conn) !void { ... }                        // optional: the server is draining
    pub fn close(conn: *anole.net.Conn, reason: anole.net.CloseReason) void { ... } // optional, once
};
```

A `*Conn` stays valid until its `close` callback returns, wherever you keep
it: drop it from your own tables in `close` (taking the lock senders take
before they use it), and no send can reach a connection that is gone.

Callbacks may take the server's `*Ctx` first, as route handlers do. They run
one at a time on a task on the connection's executor, and may wait (a
database); input that arrives meanwhile waits in the kernel. A callback that
fails closes the connection (reason `.failed`, logged at warn). While a
connection waits for its peer it holds no task, only a small heap object, so
100,000 mostly idle connections cost memory, not threads. Bytes and frames
are valid for the call; copy what you keep.

When a protocol reads best as a state machine in a loop, give a function
instead. It runs on a task of its own for the connection's whole life:

```zig
fn session(conn: *anole.net.Conn) !void {
    while (try conn.readFrame()) |line| {
        if (std.mem.eql(u8, line, "QUIT")) return; // returning closes
        try conn.writeFrame(line);
    }
}
try app.tcp(":7000", session, .{ .framing = .{ .lines = .{} } });
```

`conn.reader()` and `conn.writer()` give the buffered `std.Io` interfaces
(`reader` is for reading a frame bigger than you want in memory;
`writer().print(...)`). The task form never parks. Use callbacks for
many mostly idle connections, the task form for a few busy ones.

## 2. Framing

`framing` cuts input into messages, and `sendFrame` frames the way out.

| Framing | On the wire | Options |
|---|---|---|
| `.none` (default) | bytes as they arrive | |
| `.lines` | text ending in `\n` | `max` (64 KiB), `strip_cr` (true), `crlf` (output ends `\r\n`) |
| `.length` | a length, then the frame | `bytes` (1, 2 or 4), `endian`, `includes_header` (the length counts itself), `max` (1 MiB) |
| `.varint` | a LEB128 length (protobuf's delimited streams) | `max` (1 MiB) |

A frame over its `max`, or a malformed length, closes the connection with
reason `.frame`. A frame may arrive in pieces over many reads; the decoder
keeps the start of it on the heap, so the connection can still park.

## 3. Sending and back-pressure

`conn.send(bytes)` copies the bytes into the connection's outbox and returns.
It never waits for the peer, and may be called from any task or thread, at
any time. Bytes leave in the order sends were made.

- It answers `.ok`, or `.busy` once more than `write_high_water` (256 KiB)
  bytes are queued: the bytes were taken, but stop sending until `writable`
  is called, or call `conn.waitWritable()` from a task of your own.
- Past `write_max` (8 MiB) it takes nothing and returns `error.QueueFull`;
  `writable` follows once the outbox drains under half the high-water mark.
- `error.Closed` and `error.Ended` say the connection is over, or that this
  side was ended.

A peer that stops reading does not hold anything up: past `write_timeout`
(30 s) of no progress the connection closes (reason `.write_timeout`).

Only the task form's `write`, `writeFrame` and `flush` wait, and only on the
connection's own task; they wait while the outbox is past its high-water mark.

Many connections answered in one go are written in one round: a driver task
per executor writes every outbox that was kicked since its last round, with
one non-blocking `sendmsg` per plain TCP connection, and a TLS connection
gets a task that writes its records.

`conn.end()` ends this side once what is queued is out (TLS close_notify,
then FIN) and reading goes on. `conn.close()` also ends this side, then reads
and drops input until the peer ends too (at most 2 s), so a reset does not
destroy the last bytes. `conn.reset()` closes now with a reset.

## 4. Reading control and timeouts

`pauseReading()` and `resumeReading()` stop and restart reading; Anole leaves
the input in the kernel, and TCP flow control slows the peer. Timeouts, all
in `Tcp.Options`:

| Option | Default | Closes with |
|---|---|---|
| `handshake_timeout` | 10 s | the PROXY header and the TLS handshake, together |
| `idle_timeout` | none | `.idle` after no input for that long (`conn.setIdleTimeout` per connection) |
| `lifetime` | none | `.lifetime` after the connection has been open that long |
| `write_timeout` | 30 s | `.write_timeout` |
| `keepalive` | 60 s | TCP keep-alive probes find a vanished peer within about two minutes |

`half_open` keeps the connection open for writing after the peer's FIN until
your handler ends it (`end` is called, then `conn.end()` or `close()`); the
default ends this side for you once what is queued is out.

## 5. TLS, PROXY protocol, unix sockets

`app.tcpOn(.{ .address = "", .port = 7443, .tls = .{ .cert = .fromFiles("c.pem", "k.pem") } }, Handler, .{})`
puts a whole listener in your hands: a name, TLS with `alpn` and mutual TLS,
`proxy_protocol` / `proxy_protocol_from`, or `.unix = "/run/app.sock"`.
The certificate reloads on SIGHUP and `reloadCertificates()` like HTTP's.
Handlers see `conn.serverName()` (SNI), `conn.alpn()`, `conn.peerCertificate()`
(mutual TLS, DER), `conn.secure()`, `conn.remote()` (the PROXY header's
source when proxied), `conn.direct()` (the socket's peer) and `conn.local()`.

The PROXY protocol (v1 and v2) is read before TLS, only from peers allowed by
`proxy_protocol_from`, or else `proxy.trusted`. Under `deployment = anole_lb`
it is on for raw TCP listeners as it is for HTTP ones.

## 6. Connection limits, drain and restarts

`Tcp.Options.max_connections` caps one listener (the server's
`limits.max_connections` still bounds them all); what is over waits in the
kernel's backlog.

Raw connections count for the drain until they close. At drain start each
handler's `drain(conn)` runs (and `conn.draining()` is true) so it can say
goodbye and close; at `timeouts.shutdown` Anole closes the rest with reason
`.drain`. A task-form handler waits on `conn.drainEvent()` beside its reads.

With `ServerOptions.process`, raw TCP listeners are inherited and handed over
by name like HTTP ones: a systemd unit can use `ListenStream=` and
`ListenDatagram=` with `FileDescriptorName=`, and SIGUSR2 re-executes the
program with the sockets (`tests/restart/run.sh` checks a TCP and a UDP
listener). A UDP listener stops reading at once when it is handed over; its
successor reads the same sockets. A hand-over holds up to 64 TCP listeners and
1024 UDP sockets.

## 7. UDP

```zig
const Game = struct {
    pub const State = struct { player: u32 = 0, seq: u32 = 0 }; // per peer

    pub fn open(s: *anole.net.Session) !void { ... }                      // optional
    pub fn datagram(s: *anole.net.Session, d: *anole.net.Datagram) !void { ... }
    pub fn close(s: *anole.net.Session) void { ... }                      // optional
};
try app.udp(":7001", Game, .{ .sessions = .{ .idle_timeout = .fromSeconds(30) } });
```

- On Linux a UDP listener binds one `SO_REUSEPORT` socket per executor
  (`sockets`); the kernel hashes source and destination, so a peer's
  datagrams always reach the same socket, in order, and per-peer state needs
  no lock. Elsewhere there is one socket.
- Datagrams arrive in batches (`recvmmsg`, `batch` of them) and the handler
  runs inline on the socket's task, like a `noWait` route: it must not wait.
  Work that waits goes to `d.socket.go(func, args)`, a task on the same
  executor.
- `d.reply(bytes)` sends from the address the peer wrote to, together with
  the batch's other replies in one `sendmmsg`. From any other task or thread,
  `socket.send(to, from, bytes)` queues for the socket's sender; neither waits
  on anything but the local queue. Past `send_queue` they return
  `error.QueueFull`.
- `max_datagram` (2048) bounds what is taken; a larger one is dropped and
  counted.
- With `sessions`, `open`/`datagram`/`close` run per peer, with a `State`;
  a peer silent for `idle_timeout` ends (`session.endReason()` is `.idle`),
  and a new peer past `max` is refused rather than evicting an old one
  (evicting would let a flood of spoofed sources push real sessions out).
- A session is not authentication. A UDP source address can be forged, so until
  a peer has proved it owns its address (a cookie it echoes), keep replies no
  larger than the request, as DNS and QUIC do.

UDP listeners take no TLS, no unix socket and no PROXY header (see section 10).

## 8. Metrics and logs

With `app.metrics(...)`: `anole_net_connections_total`,
`anole_net_connections_open`, `anole_net_closes_total{reason}`,
`anole_net_bytes_received_total`, `anole_net_bytes_sent_total`,
`anole_net_send_queue_full_total`, `anole_net_datagrams_received_total`,
`anole_net_datagrams_sent_total`, `anole_net_datagrams_dropped_total{reason}`
and `anole_net_udp_sessions_open`, each labelled by listener. `app.netStats()`
returns the totals. `log_connections = true` writes one line per closed
connection to the `access` log with the listener, remote, duration, bytes in
and out and reason.

## 9. Recipes

A length-prefixed RPC: `.framing = .{ .length = .{ .bytes = 4 } }` and a
`message` that decodes the frame (protobuf, say) and answers with
`conn.sendFrame(reply)`.

A game state server over UDP: sessions with a `State` per player, a fixed-rate
task that calls `session.send` for every player, and the handler dropping
datagrams whose sequence number is old.

## 10. Limits of 0.4

- No DTLS, no PROXY protocol over UDP, and no steering of UDP by an
  application connection ID.
- No topic fan-out for raw connections yet (publishing one message to many
  connections still means calling `send` for each one).
- The C ABI has no outbound raw client: Node and Python have their own.
