const std = @import("std");
const anole = @import("anole");
const app_main = @import("app");

const alloc = std.testing.allocator;

/// The 422s need no database; the rest run against DATABASE_URL and skip
/// without it.
fn start(ctx: *app_main.Ctx, with_db: bool) !anole.Server(app_main.Ctx) {
    var app = try anole.Server(app_main.Ctx).init(alloc, .{ .executors = .exact(1) }, ctx);
    errdefer app.deinit();
    if (with_db) {
        const url = anole.env.get("DATABASE_URL") orelse return error.SkipZigTest;
        ctx.db = try app.postgres(.{ .url = url });
        var arena: std.heap.ArenaAllocator = .init(alloc);
        defer arena.deinit();
        var c: anole.db.Ctx = .{ .io = app.io(), .arena = arena.allocator() };
        _ = try ctx.db.exec(&c, "DROP TABLE IF EXISTS todos", .{});
        _ = try ctx.db.exec(&c, app_main.schema, .{});
    } else {
        ctx.db = try app.postgres(.{ .url = "postgres://postgres:postgres@127.0.0.1:1/none" });
    }
    app_main.routes(&app);
    return app;
}

test "a blank title is a 422 that names the field" {
    var ctx: app_main.Ctx = undefined;
    var app = try start(&ctx, false);
    defer app.deinit();
    var t = try anole.testing.client(&app);
    defer t.deinit();

    var res = try t.post("/todos", .{ .json = .{ .title = "   " } });
    defer res.deinit();
    try res.expectStatus(.unprocessable_entity);
    try res.expectViolation("title", "validation.not_blank");
}

test "create, get, list, update, conflict and delete" {
    var ctx: app_main.Ctx = undefined;
    var app = try start(&ctx, true);
    defer app.deinit();
    var t = try anole.testing.client(&app);
    defer t.deinit();

    var created = try t.post("/todos", .{ .json = .{ .title = "write tests" } });
    defer created.deinit();
    try created.expectStatus(.created);
    try created.expectHeader("Location", "/todos/1");
    try created.expectJson(.{ .id = 1, .title = "write tests", .done = false });

    var got = try t.get("/todos/1", .{});
    defer got.deinit();
    try got.expectJson(.{ .id = 1, .title = "write tests", .done = false });

    var listed = try t.get("/todos?limit=10", .{});
    defer listed.deinit();
    try listed.expectJson(.{.{ .id = 1, .title = "write tests", .done = false }});

    var updated = try t.put("/todos/1", .{ .json = .{ .title = "write tests", .done = true } });
    defer updated.deinit();
    try updated.expectJson(.{ .id = 1, .title = "write tests", .done = true });

    // The same title again violates the UNIQUE constraint: a 409.
    var again = try t.post("/todos", .{ .json = .{ .title = "write tests" } });
    defer again.deinit();
    try again.expectStatus(.conflict);

    var missing = try t.get("/todos/99", .{});
    defer missing.deinit();
    try missing.expectStatus(.not_found);

    var gone = try t.delete("/todos/1", .{});
    defer gone.deinit();
    try gone.expectStatus(.no_content);
}
