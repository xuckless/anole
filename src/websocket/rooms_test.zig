//! Rooms over real sockets: two HTTP/1.1 clients in one room, one message
//! reaching both.
const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");
const websocket = @import("root.zig");

var rooms: websocket.Rooms = undefined;

fn chat(req: *dusty.Request, res: *dusty.Response) !void {
    var ws = (try websocket.upgrade(req, res, .{})) orelse {
        res.status = .bad_request;
        return;
    };
    defer ws.deinit();
    try rooms.join("lobby", &ws);
    defer rooms.leave("lobby", &ws);
    try ws.send(.text, "joined");
    while (true) {
        const msg = ws.receive() catch return;
        switch (msg.type) {
            .text, .binary => _ = rooms.broadcast("lobby", msg.type, msg.data, null),
            .close => return,
            else => {},
        }
    }
}

test "Rooms: a message to the room reaches every member" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    rooms = .init(gpa, io);
    defer rooms.deinit();

    var server = dusty.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer server.deinit();
    server.router.get("/chat", chat);
    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};
    try server.ready.wait(io);

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}/chat", .{server.address.ip.getPort()});
    var client = dusty.Client.init(gpa, io, .{});
    defer client.deinit();
    var a = try client.connectWebSocket(url, .{});
    defer a.deinit();
    try std.testing.expectEqualStrings("joined", (try a.receive()).data);
    var b = try client.connectWebSocket(url, .{});
    defer b.deinit();
    try std.testing.expectEqualStrings("joined", (try b.receive()).data);
    try std.testing.expectEqual(@as(usize, 2), rooms.count("lobby"));

    try a.send(.text, "hello, room");
    try std.testing.expectEqualStrings("hello, room", (try b.receive()).data);
    try std.testing.expectEqualStrings("hello, room", (try a.receive()).data);

    try a.close(.normal, "");
    _ = try a.receive(); // the close echo
    // b alone now: the room keeps working.
    try b.send(.text, "still here");
    try std.testing.expectEqualStrings("still here", (try b.receive()).data);
    try b.close(.normal, "");
}

/// A socket whose sends block until `release` is set: a member whose
/// client has stopped reading.
const Stalled = struct {
    interface: std.Io.Writer,
    io: std.Io,
    release: std.Io.Event = .unset,
    /// A send has reached the transport.
    entered: std.Io.Event = .unset,
    reader: std.Io.Reader = .fixed(""),
    ws: dusty.WebSocket = undefined,
    socket: websocket.Socket = undefined,

    fn init(self: *Stalled, gpa: std.mem.Allocator, io: std.Io) void {
        self.* = .{ .interface = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} }, .io = io };
        self.ws = dusty.WebSocket.init(io, .{ .writer = &self.interface, .reader = &self.reader }, gpa, 0);
        self.socket = .{ .conn = .{ .h1 = &self.ws }, .allocator = gpa, .io = io, .max_message_size = 1024 };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Stalled = @alignCast(@fieldParentPtr("interface", w));
        self.entered.set(self.io);
        self.release.waitUncancelable(self.io);
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| n += bytes.len;
        return n + data[data.len - 1].len * splat;
    }
};

test "Rooms: a stalled member holds up neither other rooms nor joins, and leaves once its send ends" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var r: websocket.Rooms = .init(gpa, io);
    defer r.deinit();

    var stalled: Stalled = undefined;
    stalled.init(gpa, io);
    defer stalled.ws.deinit();
    var other: Stalled = undefined;
    other.init(gpa, io);
    defer other.ws.deinit();
    other.release.set(io); // never stalls

    try r.join("slow", &stalled.socket);
    try r.join("fast", &other.socket);

    // A broadcast stuck sending to the stalled member.
    var stuck = try io.concurrent(struct {
        fn run(rooms_: *websocket.Rooms) usize {
            return rooms_.broadcast("slow", .text, "hello", null);
        }
    }.run, .{&r});
    try stalled.entered.wait(io);

    // Another room, and joins and counts, go on meanwhile.
    try std.testing.expectEqual(@as(usize, 1), r.broadcast("fast", .text, "hi", null));
    try r.join("slow", &other.socket);
    try std.testing.expectEqual(@as(usize, 2), r.count("slow"));
    r.leave("slow", &other.socket);

    // Leaving waits for the send under way to the leaver.
    var left: std.atomic.Value(bool) = .init(false);
    var leaving = try io.concurrent(struct {
        fn run(rooms_: *websocket.Rooms, s: *websocket.Socket, done: *std.atomic.Value(bool)) void {
            rooms_.leave("slow", s);
            done.store(true, .release);
        }
    }.run, .{ &r, &stalled.socket, &left });
    while (r.count("slow") != 0) try io.sleep(.fromMilliseconds(1), .awake);
    try io.sleep(.fromMilliseconds(20), .awake);
    try std.testing.expect(!left.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), r.broadcast("fast", .text, "still", null));

    stalled.release.set(io);
    leaving.await(io);
    try std.testing.expect(left.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), stuck.await(io));
    try std.testing.expectEqual(@as(usize, 0), r.broadcast("slow", .text, "gone", null));
    r.leave("fast", &other.socket);
}
