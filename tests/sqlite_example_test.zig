//! examples/sqlite over a real socket, on `:memory:`: each route and the
//! statuses database errors become.
const std = @import("std");
const anole = @import("anole");
const example = @import("sqlite_example");

const alloc = std.testing.allocator;
const Server = anole.Server(example.App);

const Reply = struct { status: anole.http.Status, body: []const u8 };

fn call(io: std.Io, arena: std.mem.Allocator, method: anole.http.Method, url: []const u8, body: ?[]const u8) !Reply {
    var r = try anole.client(io).fetch(url, .{
        .method = method,
        .headers = &.{.{ "Content-Type", "application/json" }},
        .body = body,
    });
    defer r.deinit();
    return .{ .status = r.status(), .body = try arena.dupe(u8, try r.body()) };
}

test "examples/sqlite: create, list, get, done, delete; 409 on a duplicate title, 404 on none" {
    var state: example.App = .{};
    var app = try Server.init(alloc, .{ .errors = .json, .executors = .exact(2) }, &state);
    defer app.deinit();
    state.db = try app.sqlite(":memory:");
    try state.db.execScript(example.schema);
    example.routes(&app);

    const Check = struct {
        fn run(a: *Server) !void {
            defer a.stop();
            try a.waitReady();
            const io = a.io();
            var arena_state: std.heap.ArenaAllocator = .init(alloc);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const base = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/todos", .{a.addresses()[0].ip.getPort()});
            const one = try std.fmt.allocPrint(arena, "{s}/1", .{base});

            const made = try call(io, arena, .post, base, "{\"title\":\"Buy milk\"}");
            try std.testing.expectEqual(anole.http.Status.created, made.status);
            try std.testing.expectStringStartsWith(made.body, "{\"id\":1,\"title\":\"Buy milk\",\"done\":false,\"created_at\":\"20");
            try std.testing.expectEqual(anole.http.Status.conflict, (try call(io, arena, .post, base, "{\"title\":\"Buy milk\"}")).status);
            _ = try call(io, arena, .post, base, "{\"title\":\"Walk\"}");

            const listed = try call(io, arena, .get, try std.fmt.allocPrint(arena, "{s}?limit=1", .{base}), null);
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, listed.body, "\"id\""));
            try std.testing.expectEqual(anole.http.Status.no_content, (try call(io, arena, .post, try std.fmt.allocPrint(arena, "{s}/done", .{one}), null)).status);
            try std.testing.expect(std.mem.indexOf(u8, (try call(io, arena, .get, one, null)).body, "\"done\":true") != null);
            try std.testing.expectEqual(anole.http.Status.no_content, (try call(io, arena, .delete, one, null)).status);
            try std.testing.expectEqual(anole.http.Status.not_found, (try call(io, arena, .get, one, null)).status);
            try std.testing.expectEqual(anole.http.Status.not_found, (try call(io, arena, .delete, one, null)).status);
            try std.testing.expectEqual(anole.http.Status.bad_request, (try call(io, arena, .post, base, "not json")).status);
        }
    };
    // The 409 logs its detail; not in the test's output.
    const level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = level;
    var checking = try app.io().concurrent(Check.run, .{&app});
    try app.listen("127.0.0.1:0");
    try checking.await(app.io());
}
