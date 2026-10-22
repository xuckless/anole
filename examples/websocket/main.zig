//! Anole WebSocket example: an echo endpoint and a broadcast chat room, over
//! HTTP/1.1 (RFC 6455) and HTTP/2 (RFC 8441), through one handler each.
//!
//!   zig build run-websocket                  # http://127.0.0.1:8082 and https://127.0.0.1:8445
//!   zig build run-websocket -- 9000 9443     # other ports
//!
//!   GET /             -> a small chat page for a browser
//!   GET /echo         -> WebSocket: every text or binary message comes back
//!   GET /chat/:room   -> WebSocket: every message goes to everyone in the room
//!
//! Open http://127.0.0.1:8082/ in two browser tabs and type in either. Over
//! https://127.0.0.1:8445/ (a self-signed certificate made at startup, so
//! accept the browser's warning) Firefox opens the WebSocket over HTTP/2.
//! The log says which HTTP version each socket arrived on.
const std = @import("std");
const anole = @import("anole");
const websocket = anole.websocket;

/// Keeps the runtime's per-thread lines and the connection loops' debug
/// lines out of a Debug build; info (startup lines, access log) stays.
pub const std_options = anole.std_options;

const log = std.log.scoped(.websocket_example);

/// Shared by every handler: `Server(App)` passes a `*App` to each one.
const App = struct {
    rooms: websocket.Rooms,
};

/// A chat socket that sends nothing for this long is closed.
const chat_idle: std.Io.Duration = .fromSeconds(300);

fn versionName(ws: *const websocket.Socket) []const u8 {
    return switch (ws.conn) {
        .h1 => "HTTP/1.1",
        .h2 => "HTTP/2",
    };
}

/// Echoes every text and binary message. `next` answers pings and returns
/// null once the client closes (its close is echoed for it) or goes away;
/// `app.ws` closes the socket when this returns.
fn echo(ws: *websocket.Socket, _: *anole.Request) !void {
    log.info("echo: WebSocket over {s}", .{versionName(ws)});
    while (try ws.next()) |msg| try ws.send(msg.type, msg.data);
}

/// Joins the socket to the room named in the path. Every message a member
/// sends goes to every member, the sender included.
fn chat(app: *App, ws: *websocket.Socket, req: *anole.Request) !void {
    const room = req.params.get("room") orelse "lobby";
    try app.rooms.join(room, ws);
    defer app.rooms.leave(room, ws);
    log.info("chat: WebSocket over {s} joined {s}", .{ versionName(ws), room });

    var buf: [128]u8 = undefined;
    const hello = try std.fmt.bufPrint(&buf, "* joined {s} ({d} here)", .{ room, app.rooms.count(room) });
    _ = app.rooms.broadcast(room, .text, hello, null);

    while (true) {
        // An idle limit: the timer restarts before every wait. When it
        // runs out the connection is closed and `next` returns null.
        req.setTimeout(.{ .duration = .{ .raw = chat_idle, .clock = .awake } });
        const msg = try ws.next() orelse return;
        _ = app.rooms.broadcast(room, msg.type, msg.data, null);
    }
}

fn page(_: *anole.Request, res: *anole.Response) !void {
    try res.print(.html, "{s}", .{chat_page});
}

const chat_page =
    \\<!doctype html>
    \\<meta charset="utf-8">
    \\<title>Anole chat</title>
    \\<style>body{font:16px system-ui;max-width:40em;margin:2em auto}#log{white-space:pre-wrap}</style>
    \\<h1>Room: lobby</h1>
    \\<form id="f"><input id="m" autofocus autocomplete="off"> <button>Send</button></form>
    \\<div id="log"></div>
    \\<script>
    \\const scheme = location.protocol === "https:" ? "wss:" : "ws:";
    \\const ws = new WebSocket(scheme + "//" + location.host + "/chat/lobby");
    \\const log = (line) => document.getElementById("log").append(line + "\n");
    \\ws.onopen = () => log("* connected");
    \\ws.onmessage = (e) => log(e.data);
    \\ws.onclose = (e) => log("* closed (" + e.code + ")");
    \\document.getElementById("f").onsubmit = (e) => {
    \\  e.preventDefault();
    \\  const m = document.getElementById("m");
    \\  if (m.value) ws.send(m.value);
    \\  m.value = "";
    \\};
    \\</script>
    \\
;

pub fn main(init: std.process.Init) !void {
    var port: u16 = 8082;
    var tls_port: u16 = 8445;
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    if (args.next()) |p| port = try std.fmt.parseInt(u16, p, 10);
    if (args.next()) |p| tls_port = try std.fmt.parseInt(u16, p, 10);

    // The rooms take the runtime's Io from the first socket that joins, so
    // they can be made before the server.
    var state: App = .{ .rooms = .init(init.gpa) };
    defer state.rooms.deinit();
    var app = try anole.Server(App).init(init.gpa, .{
        // HTTP/1.1, plus HTTP/2 (h2c) for clients that open with its preface.
        .http = .{ .port = port },
        // HTTPS with ALPN h2 and http/1.1: browsers use HTTP/2 here.
        .https = if (anole.features.tls != .none) .{ .port = tls_port, .cert = .dev_self_signed } else null,
        // Open sockets hold a graceful shutdown until they close or this
        // runs out (30 s by default); then they are cut.
        .server = .{ .timeout = .{ .shutdown = .fromSeconds(5) } },
    }, &state);
    defer app.deinit();

    app.use(anole.middleware.Logger.init());
    app.get("/", page);
    // A plain HTTP request to either gets 426 Upgrade Required. A message
    // bigger than 1 MiB is refused with close code 1009.
    app.wsWith("/echo", echo, .{ .max_message_size = 1024 * 1024 });
    app.ws("/chat/:room", chat);

    // The server logs a "listening on" line per listener as it starts.
    if (anole.features.tls != .none) log.info("the HTTPS certificate is a self-signed development one (curl -k)", .{});
    try app.run();
}
