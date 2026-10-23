const std = @import("std");
const anole = @import("anole");
const app_main = @import("app");

fn start() !anole.App {
    var app = try anole.App.init(std.testing.allocator, .{ .executors = .exact(1) });
    errdefer app.deinit();
    try app_main.routes(&app);
    return app;
}

test "SayHello over REST (JSON transcoding)" {
    var app = try start();
    defer app.deinit();
    var t = try anole.testing.client(&app);
    defer t.deinit();

    var get = try t.get("/v1/hello/Ada", .{});
    defer get.deinit();
    try get.expectStatus(.ok);
    try get.expectJson(.{ .message = "hello, Ada" });

    var post = try t.post("/v1/hello", .{ .json = .{ .name = "Grace" } });
    defer post.deinit();
    try post.expectJson(.{ .message = "hello, Grace" });
}

test "SayHello over Connect, and its error" {
    var app = try start();
    defer app.deinit();
    var t = try anole.testing.client(&app);
    defer t.deinit();

    var ok = try t.post("/greeter.Greeter/SayHello", .{ .json = .{ .name = "Ada" } });
    defer ok.deinit();
    try ok.expectJson(.{ .message = "hello, Ada" });

    // call.fail(.invalid_argument, ...) is a Connect error with a 400.
    var bad = try t.post("/greeter.Greeter/SayHello", .{ .json = .{ .name = "" } });
    defer bad.deinit();
    try bad.expectStatus(.bad_request);
}

test "Lookup is also a Connect GET" {
    var app = try start();
    defer app.deinit();
    var t = try anole.testing.client(&app);
    defer t.deinit();

    var res = try t.get("/greeter.Greeter/Lookup?encoding=json&message=%7B%22name%22%3A%22Ada%22%7D", .{});
    defer res.deinit();
    try res.expectJson(.{ .message = "hi again, Ada" });
}
