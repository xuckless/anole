//! {{name}}: a WebSocket chat. Open http://localhost:3000 in two tabs.
//!
//!   zig build run          # http://localhost:3000
//!   zig build test         # two clients over a loopback socket
//!   zig build openapi      # writes openapi.json
const std = @import("std");
const anole = @import("anole");
const websocket = anole.websocket;

/// Keeps the runtime's per-thread lines out of a Debug build.
pub const std_options = anole.std_options;
// A panic is logged (message and stack trace) before the process aborts.
pub const panic = anole.panic;

/// The state every handler gets first: the chat rooms (a room exists while
/// someone is in it).
pub const App = struct {
    rooms: websocket.Rooms,
};

/// The rooms `GET /rooms` reports on.
const known_rooms = [_][]const u8{ "lobby", "random" };

const RoomInfo = struct { name: []const u8, members: usize };

fn listRooms(app: *App, req: *anole.Request) ![]const RoomInfo {
    const out = try req.arena.alloc(RoomInfo, known_rooms.len);
    for (known_rooms, out) |name, *info| info.* = .{ .name = name, .members = app.rooms.count(name) };
    return out;
}

/// One socket per browser tab: joins the room named by `?room=` (default
/// "lobby") and sends every message it gets to everyone there, itself
/// included, as `{"room":"lobby","text":"hello"}`.
fn chat(app: *App, ws: *websocket.Socket, req: *anole.Request) !void {
    const room = req.query.get("room") orelse "lobby";
    try app.rooms.join(room, ws);
    defer app.rooms.leave(room, ws);

    var buf: [8192]u8 = undefined;
    try ws.send(.text, try encode(&buf, room, "welcome"));
    while (try ws.next()) |msg| {
        if (msg.type != .text) continue;
        _ = app.rooms.broadcast(room, .text, try encode(&buf, room, msg.data), null);
    }
}

fn encode(buf: []u8, room: []const u8, text: []const u8) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    try std.json.Stringify.value(.{ .room = room, .text = text }, .{}, &w);
    return w.buffered();
}

/// Apart from `main` so that src/main_test.zig serves the same routes.
pub fn routes(app: *anole.Server(App)) void {
    app.get("/rooms", listRooms);
    // Messages over 4 KiB are refused (close code 1009).
    app.wsWith("/ws", chat, .{ .max_message_size = 4096 });
}

pub fn main(init: std.process.Init) !void {
    var state: App = .{ .rooms = .init(init.gpa, .{}) };
    defer state.rooms.deinit();
    var app = try anole.Server(App).init(init.gpa, .{}, &state);
    defer app.deinit();
    app.use(anole.observe.AccessLog.init(.{}));
    app.openapi(.{ .info = .{ .title = "{{name}}", .version = "0.1.0" } });
    routes(&app);
    // public/index.html, the chat page. (Not in `routes`: the tests don't need it.)
    try app.staticDir("/", "public", .{});
    try app.listen(":3000");
}
