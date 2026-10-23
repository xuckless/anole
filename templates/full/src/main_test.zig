//! One test per area, in memory (`anole.testing`), except the WebSocket
//! chat, which needs a socket.
const std = @import("std");
const anole = @import("anole");
const app_main = @import("app");

const alloc = std.testing.allocator;
const Server = anole.Server(app_main.App);
const secret = "test-secret-0123456789abcdef0123456789";
const api_key_text = "ak_test_key_not_a_secret";

/// A server on an in-memory database with the app's routes.
fn start(state: *app_main.App) !Server {
    state.* = .{
        .db = undefined,
        .rooms = .init(alloc, .{}),
        .jwt_keys = .{.{ .kid = "demo", .alg = .HS256, .material = .{ .hmac = secret } }},
        .api_key_digest = undefined,
        .session_key = @splat(7),
        .upstream_url = "http://127.0.0.1:1/never",
    };
    std.crypto.hash.sha2.Sha256.hash(api_key_text, &state.api_key_digest, .{});
    var app = try Server.init(alloc, .{ .executors = .exact(2) }, state);
    errdefer app.deinit();
    state.db = try app.sqlite(":memory:");
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var c: anole.db.Ctx = .{ .io = app.io(), .arena = arena.allocator() };
    try state.db.execScript(&c, app_main.schema);
    try app_main.routes(&app, state);
    return app;
}

fn bearer(arena: std.mem.Allocator, io: std.Io, role: []const u8) ![]const u8 {
    const token = try app_main.demoToken(arena, io, secret, "alice", role);
    return std.fmt.allocPrint(arena, "Bearer {s}", .{token});
}

test "todos: typed routes, a 422 with the rules, a 409 and a 404" {
    var state: app_main.App = undefined;
    var app = try start(&state);
    defer state.rooms.deinit();
    defer app.deinit();
    var t = try anole.testing.client(&app);
    defer t.deinit();

    var created = try t.post("/todos", .{ .json = .{ .title = "write tests" } });
    defer created.deinit();
    try created.expectStatus(.created);
    try created.expectHeader("Location", "/todos/1");
    try created.expectJson(.{ .id = 1, .title = "write tests", .done = false });

    var blank = try t.post("/todos", .{ .json = .{ .title = "  " } });
    defer blank.deinit();
    try blank.expectStatus(.unprocessable_entity);
    try blank.expectViolation("title", "validation.not_blank");

    var again = try t.post("/todos", .{ .json = .{ .title = "write tests" } });
    defer again.deinit();
    try again.expectStatus(.conflict);

    var listed = try t.get("/todos", .{});
    defer listed.deinit();
    try listed.expectJson(.{.{ .id = 1, .title = "write tests", .done = false }});

    var missing = try t.get("/todos/9", .{});
    defer missing.deinit();
    try missing.expectStatus(.not_found);
}

test "server-sent events" {
    var state: app_main.App = undefined;
    var app = try start(&state);
    defer state.rooms.deinit();
    defer app.deinit();
    var t = try anole.testing.client(&app);
    defer t.deinit();

    const stream = try t.open(.get, "/events?count=2&interval_ms=0", .{});
    defer stream.deinit();
    const first = (try stream.nextEvent()).?;
    try std.testing.expectEqualStrings("tick", first.event.?);
    try std.testing.expectEqualStrings("0", first.data);
}

test "sessions: a POST without the CSRF token is refused" {
    var state: app_main.App = undefined;
    var app = try start(&state);
    defer state.rooms.deinit();
    defer app.deinit();
    var t = try anole.testing.client(&app);
    defer t.deinit();

    var info = try t.get("/session", .{});
    defer info.deinit();
    try info.expectStatus(.ok);

    var refused = try t.post("/session", .{ .json = .{ .name = "alice" } });
    defer refused.deinit();
    try refused.expectStatus(.forbidden);
}

test "bearer tokens: 401 without, 200 with; roles decide notes" {
    var state: app_main.App = undefined;
    var app = try start(&state);
    defer state.rooms.deinit();
    defer app.deinit();
    var t = try anole.testing.client(&app);
    defer t.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var none = try t.get("/api/me", .{});
    defer none.deinit();
    try none.expectStatus(.unauthorized);

    const editor = try bearer(arena, app.io(), "editor");
    var ok = try t.get("/api/me", .{ .headers = &.{.{ "Authorization", editor }} });
    defer ok.deinit();
    try ok.expectJson(.{ .subject = "alice" });

    var saved = try t.post("/api/notes", .{ .headers = &.{.{ "Authorization", editor }}, .body = "{}" });
    defer saved.deinit();
    try saved.expectStatus(.created);

    const reader = try bearer(arena, app.io(), "reader");
    var refused = try t.post("/api/notes", .{ .headers = &.{.{ "Authorization", reader }}, .body = "{}" });
    defer refused.deinit();
    try refused.expectStatus(.forbidden);
}

test "API keys" {
    var state: app_main.App = undefined;
    var app = try start(&state);
    defer state.rooms.deinit();
    defer app.deinit();
    var t = try anole.testing.client(&app);
    defer t.deinit();

    var none = try t.get("/service/stats", .{});
    defer none.deinit();
    try none.expectStatus(.unauthorized);
}

test "gRPC service as REST and Connect" {
    var state: app_main.App = undefined;
    var app = try start(&state);
    defer state.rooms.deinit();
    defer app.deinit();
    var t = try anole.testing.client(&app);
    defer t.deinit();

    var rest = try t.get("/v1/hello/Ada", .{});
    defer rest.deinit();
    try rest.expectJson(.{ .message = "hello, Ada" });

    var connect = try t.post("/greeter.Greeter/SayHello", .{ .json = .{ .name = "Ada" } });
    defer connect.deinit();
    try connect.expectJson(.{ .message = "hello, Ada" });
}

test "health and the OpenAPI document" {
    var state: app_main.App = undefined;
    var app = try start(&state);
    defer state.rooms.deinit();
    defer app.deinit();
    var t = try anole.testing.client(&app);
    defer t.deinit();

    var health = try t.get("/healthz", .{});
    defer health.deinit();
    try health.expectStatus(.ok);

    const doc = try app.openapiDocument(alloc);
    defer alloc.free(doc);
    try std.testing.expect(std.mem.indexOf(u8, doc, "\"/todos/{id}\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "\"bearerAuth\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "\"/v1/hello/{name}\"") != null);
}

test "the chat: a message reaches both clients" {
    var state: app_main.App = undefined;
    var app = try start(&state);
    defer state.rooms.deinit();
    defer app.deinit();

    const Check = struct {
        fn run(a: *Server) !void {
            defer a.stop();
            try a.waitReady();
            var url_buf: [64]u8 = undefined;
            const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}/ws", .{a.addresses()[0].ip.getPort()});
            var client = anole.client(a.io()).http;
            var first = try client.connectWebSocket(url, .{});
            defer first.deinit();
            var second = try client.connectWebSocket(url, .{});
            defer second.deinit();
            // Both are in the room once a message round trip works for both.
            try first.send(.text, "hello");
            try std.testing.expectEqualStrings("hello", (try first.receive()).data);
            try std.testing.expectEqualStrings("hello", (try second.receive()).data);
            try first.close(.normal, "");
            try second.close(.normal, "");
        }
    };
    var checking = try app.io().concurrent(Check.run, .{&app});
    try app.listen("127.0.0.1:0");
    try checking.await(app.io());
}
