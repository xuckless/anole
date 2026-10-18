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
