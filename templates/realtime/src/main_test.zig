const std = @import("std");
const anole = @import("anole");
const app_main = @import("app");

const alloc = std.testing.allocator;
const Server = anole.Server(app_main.App);

test "a message reaches every client in the room" {
    var state: app_main.App = .{ .rooms = .init(alloc, .{}) };
    defer state.rooms.deinit();
    var app = try Server.init(alloc, .{ .executors = .exact(2) }, &state);
    defer app.deinit();
    app_main.routes(&app);

    const Check = struct {
        fn run(a: *Server, st: *app_main.App) !void {
            defer a.stop();
            try a.waitReady();
            const io = a.io();
            var url_buf: [64]u8 = undefined;
            const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}/ws?room=lobby", .{a.addresses()[0].ip.getPort()});
            var client = anole.client(io).http;

            var first = try client.connectWebSocket(url, .{});
            defer first.deinit();
            try std.testing.expectEqualStrings("{\"room\":\"lobby\",\"text\":\"welcome\"}", (try first.receive()).data);
            // The welcome comes after the join, so both are in the room now.
            var second = try client.connectWebSocket(url, .{});
            defer second.deinit();
            _ = try second.receive();

            try first.send(.text, "hello");
            try std.testing.expectEqualStrings("{\"room\":\"lobby\",\"text\":\"hello\"}", (try second.receive()).data);
            try std.testing.expectEqualStrings("{\"room\":\"lobby\",\"text\":\"hello\"}", (try first.receive()).data);
            try std.testing.expectEqual(2, st.rooms.count("lobby"));

            try first.close(.normal, "");
            try second.close(.normal, "");
        }
    };
    var checking = try app.io().concurrent(Check.run, .{ &app, &state });
    try app.listen("127.0.0.1:0");
    try checking.await(app.io());
}

test "GET /rooms lists the rooms and who is in them" {
    var state: app_main.App = .{ .rooms = .init(alloc, .{}) };
    defer state.rooms.deinit();
    var app = try Server.init(alloc, .{ .executors = .exact(1) }, &state);
    defer app.deinit();
    app_main.routes(&app);
    var t = try anole.testing.client(&app);
    defer t.deinit();

    var res = try t.get("/rooms", .{});
    defer res.deinit();
    try res.expectJson(.{ .{ .name = "lobby", .members = 0 }, .{ .name = "random", .members = 0 } });
}
