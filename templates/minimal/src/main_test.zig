const std = @import("std");
const anole = @import("anole");
const app_main = @import("app");

fn start() !anole.App {
    var app = try anole.App.init(std.testing.allocator, .{ .executors = .exact(1) });
    app_main.routes(&app);
    return app;
}

test "GET / says hello" {
    var app = try start();
    defer app.deinit();
    var t = try anole.testing.client(&app);
    defer t.deinit();

    var res = try t.get("/", .{});
    defer res.deinit();
    try res.expectStatus(.ok);
    try res.expectJson(.{ .hello = "world" });
}

test "GET /users/:id reads the id as a number" {
    var app = try start();
    defer app.deinit();
    var t = try anole.testing.client(&app);
    defer t.deinit();

    var res = try t.get("/users/7", .{});
    defer res.deinit();
    try res.expectJson(.{ .id = 7, .name = "Ada" });

    // Not a number: no such resource.
    var bad = try t.get("/users/abc", .{});
    defer bad.deinit();
    try bad.expectStatus(.not_found);
}

test "POST /echo checks its rules" {
    var app = try start();
    defer app.deinit();
    var t = try anole.testing.client(&app);
    defer t.deinit();

    var ok = try t.post("/echo", .{ .json = .{ .message = "  hi  " } });
    defer ok.deinit();
    try ok.expectJson(.{ .message = "hi" });

    var blank = try t.post("/echo", .{ .json = .{ .message = "   " } });
    defer blank.deinit();
    try blank.expectStatus(.unprocessable_entity);
    try blank.expectViolation("message", "validation.not_blank");
}
