# Raw TCP and UDP

Up: [deployment](index.md), [SKILL.md](../../SKILL.md). Related: [listeners-proxy.md](listeners-proxy.md), [lifecycle.md](lifecycle.md), [writes return once buffered](../runtime.md#writes-return-once-buffered).

Full docs: docs/net.md. Example: examples/net/main.zig. Source: src/net/root.zig, src/net/tcp.zig, src/net/udp_service.zig; `app.tcp`, `app.tcpOn`, `app.udp`, `app.udpOn` (src/server.zig).

A line protocol, game server or custom RPC runs on the same listeners, runtime and drain as HTTP, in one process. Do not open `std.Io.net` listeners or spawn accept threads yourself. Needs `-Dnet` (web and full profiles; [flags](../config-cli.md#feature-flags-and-profiles)).

## TCP and UDP beside HTTP

Use: `anole.App.tcp(address, Handler, opts)`, `anole.App.udp(address, Handler, opts)`, `anole.net.Conn`, `anole.net.Datagram` (src/server.zig, src/net/root.zig).

```zig
// docs/net.md
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

Traps:
- Call `tcp`/`udp` before `listen`/`listenTls`/`run`, on a server whose init named no listener; otherwise `error.ListenersAlreadySet`: put them in `.listeners` (`.tcp = anole.net.tcp(...)`, `.udp = anole.net.udp(...)`).
- A raw listener needs its own port (0 for a free one) or a unix path; it never takes `$PORT` or 8080.
- Only raw listeners named: no HTTP listener opens.

## TCP handlers

Callbacks (a type), only the input one required: `data(conn, bytes)` without framing, `message(conn, frame)` with one; optional `open`, `end`, `writable`, `drain`, `close(conn, reason)`, and `pub const State` per connection (`conn.contextAs(State)`). Callbacks may take the server's `*Ctx` first.

Or a task-form function for a protocol that reads as a loop:

```zig
fn session(conn: *anole.net.Conn) !void {
    while (try conn.readFrame()) |line| {
        if (std.mem.eql(u8, line, "QUIT")) return; // returning closes
        try conn.writeFrame(line);
    }
}
try app.tcp(":7000", session, .{ .framing = .{ .lines = .{} } });
```

Framing (`.framing`): `.none` (default), `.lines` (`max` 64 KiB, `strip_cr`, `crlf`), `.length` (`bytes` 1/2/4, `endian`, `includes_header`, `max`), `.varint`.

Traps:
- Bytes and frames are valid for the call only; copy what you keep.
- A `*Conn` is valid until its `close` callback returns: remove it from your tables there, under the lock senders take.
- `conn.send` queues and returns `.ok` or `.busy` (past `write_high_water`, 256 KiB): stop sending until `writable`. Past `write_max` (8 MiB) it is `error.QueueFull`. Never add your own blocking write loop.
- Callbacks run one at a time per connection and may wait (a database); a callback that fails closes the connection. Use callbacks for many idle connections, the task form for a few busy ones.
- On drain, a handler without `drain` gets `conn.close()`; give it a `drain` callback to say goodbye. The task form waits on `conn.drainEvent()`.

## TLS, PROXY protocol, unix sockets

Use: `anole.App.tcpOn(listener, Handler, opts)` with a whole `anole.Listener` (src/server.zig).

```zig
try app.tcpOn(.{ .address = "", .port = 7443, .tls = .{ .cert = .fromFiles("c.pem", "k.pem") } }, Handler, .{});
```

The certificate reloads on SIGHUP and `reloadCertificates()` like HTTP's. Handlers read `conn.serverName()`, `conn.alpn()`, `conn.peerCertificate()`, `conn.secure()`, `conn.remote()`, `conn.direct()`, `conn.local()`.

## UDP

```zig
// docs/net.md
const Game = struct {
    pub const State = struct { player: u32 = 0, seq: u32 = 0 }; // per peer

    pub fn open(s: *anole.net.Session) !void { ... }                      // optional
    pub fn datagram(s: *anole.net.Session, d: *anole.net.Datagram) !void { ... }
    pub fn close(s: *anole.net.Session) void { ... }                      // optional
};
try app.udp(":7001", Game, .{ .sessions = .{ .idle_timeout = .fromSeconds(30) } });
```

Traps:
- UDP handlers run inline on the socket's task and must not wait. Hand waiting work to `d.socket.go(func, args)` (a task on the same executor). See [never block an executor](../runtime.md#never-block-an-executor).
- `d.reply` and `socket.send` never wait; past `send_queue` they return `error.QueueFull`. `max_datagram` (2048) bounds input.
- UDP listeners take no TLS (no DTLS), no unix socket, no PROXY header.
- A source address can be forged: keep replies no larger than the request until the peer proves its address. A session is not authentication.
- With `ServerOptions.process`, raw listeners are handed over on SIGUSR2 like HTTP ones ([restarts](lifecycle.md#zero-downtime-restart-and-systemd)).
