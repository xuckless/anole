//! The console's `/ws` snapshot through the collector, from a thread that
//! is not the runtime's (as the console's are): open WebSockets by
//! protocol, rooms with their members, SSE topics with their subscribers.
const std = @import("std");
const wait = @import("anole_test_wait");
const features = @import("build_options");
const server_mod = @import("../server.zig");
const websocket = if (features.websocket) @import("../websocket/root.zig") else struct {};
const sse = @import("../sse/root.zig");
const http = @import("../http/root.zig");

const App = server_mod.App;
const alloc = std.testing.allocator;

var rooms: if (features.websocket) websocket.Rooms else void = undefined;

fn lobby(ws: *websocket.Socket, _: *http.Request) !void {
    try rooms.join("lobby", ws);
    while (try ws.next()) |_| {}
}

/// `snapshot(.ws)` on a thread of its own; `done` once it has returned.
const Asker = struct {
    app: *App,
    out: std.Io.Writer.Allocating,
    err: ?anyerror = null,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *Asker) void {
        self.app.console_collector.snapshot(.ws, &self.out.writer) catch |e| {
            self.err = e;
        };
        self.done.store(true, .release);
    }
};

/// The `/ws` snapshot, parsed. Asked from a thread, waited for without
/// blocking the runtime's executor (the collector runs on the runtime).
fn wsSnapshot(app: *App, arena: std.mem.Allocator) !std.json.Value {
    var asker: Asker = .{ .app = app, .out = .init(arena) };
    const t = try std.Thread.spawn(.{}, Asker.run, .{&asker});
    const answered = wait.waitFlag(app.io(), "the collector answered the snapshot", &asker.done);
    t.join();
    try answered;
    if (asker.err) |e| return e;
    return try std.json.parseFromSliceLeaky(std.json.Value, arena, asker.out.written(), .{});
}

fn countOf(v: std.json.Value, list: []const u8, name: []const u8, field: []const u8) i64 {
    for (v.object.get(list).?.array.items) |row| {
        if (std.mem.eql(u8, row.object.get("name").?.string, name)) return row.object.get(field).?.integer;
    }
    return -1;
}

fn connect(io: std.Io, port: u16, request: []const u8) !std.Io.net.Stream {
    const s = try (try std.Io.net.IpAddress.parse("127.0.0.1", port)).connect(io, .{ .mode = .stream });
    var wbuf: [512]u8 = undefined;
    var w = s.writer(io, &wbuf);
    try w.interface.writeAll(request);
    try w.interface.flush();
    return s;
}

test "console /ws: open sockets by protocol, rooms and their members, SSE topics and their subscribers" {
    if (comptime !features.websocket or !features.console) return error.SkipZigTest;
    // The console has no socket on Windows (docs/console.md).
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &dir_buf);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sock = try std.fmt.bufPrint(&path_buf, "{s}/c.sock", .{dir_buf[0..dir_len]});
    rooms = .init(alloc, .{});
    defer rooms.deinit();
    var app = try App.init(alloc, .{ .executors = .exact(2), .console = .{ .enabled = true, .socket = sock } });
    defer app.deinit();
    const live = try app.sseTopics(.{ .heartbeat = null });
    app.sse("/live", live, .{ .topics = &.{"news"} });
    app.ws("/lobby", lobby);

    const Check = struct {
        fn run(a: *App) !void {
            defer a.stop();
            const io = a.io();
            try a.waitReady();
            const port = a.addresses()[0].ip.getPort();
            var arena: std.heap.ArenaAllocator = .init(alloc);
            defer arena.deinit();
            const ws = try connect(io, port, "GET /lobby HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
                "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n");
            var ws_open = true;
            defer if (ws_open) ws.close(io);
            const ev = try connect(io, port, "GET /live HTTP/1.1\r\nHost: x\r\n\r\n");
            defer ev.close(io);
            // Both are in: one socket over HTTP/1.1 in "lobby", one
            // subscriber of "news".
            const Snap = struct {
                app: *App,
                arena: std.mem.Allocator,
                last: *std.json.Value,
                /// The snapshot, or null when the collector answered busy
                /// (its answer window passed on a slow machine): not yet.
                fn take(c: @This()) !bool {
                    c.last.* = wsSnapshot(c.app, c.arena) catch |e| switch (e) {
                        error.Busy => return false,
                        else => return e,
                    };
                    return true;
                }
                fn bothIn(c: @This()) !bool {
                    if (!try c.take()) return false;
                    const sockets = c.last.object.get("sockets").?.object;
                    return sockets.get("h1").?.integer == 1 and countOf(c.last.*, "rooms", "lobby", "members") == 1 and
                        countOf(c.last.*, "topics", "news", "subscribers") == 1;
                }
                fn wsGone(c: @This()) !bool {
                    if (!try c.take()) return false;
                    return c.last.object.get("sockets").?.object.get("h1").?.integer == 0 and countOf(c.last.*, "rooms", "lobby", "members") == -1;
                }
            };
            var last: std.json.Value = undefined;
            const snap: Snap = .{ .app = a, .arena = arena.allocator(), .last = &last };
            try wait.waitUntil(io, "the snapshot counts the socket, its room and the subscriber", snap, Snap.bothIn);
            try std.testing.expectEqual(@as(i64, 0), last.object.get("sockets").?.object.get("h2").?.integer);
            try std.testing.expectEqual(@as(i64, 0), countOf(last, "rooms", "lobby", "closed_slow"));
            // The WebSocket goes: its count and its room go with it.
            ws.close(io);
            ws_open = false;
            try wait.waitUntil(io, "the snapshot no longer counts the socket or its room", snap, Snap.wsGone);
        }
    };
    var checking = try app.io().concurrent(Check.run, .{&app});
    defer checking.cancel(app.io()) catch {};
    try app.listen("127.0.0.1:0");
    try checking.await(app.io());
}
