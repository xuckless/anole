//! examples/rest over a real socket: each route, the API key check and the
//! JSON error answers.
const std = @import("std");
const anole = @import("anole");
const rest = @import("rest");

const alloc = std.testing.allocator;
const Server = anole.Server(rest.Store);

const Reply = struct { status: anole.http.Status, body: []const u8 };

/// `method url` with the API key (when given) and a JSON body (when given).
fn call(io: std.Io, arena: std.mem.Allocator, method: anole.http.Method, url: []const u8, key: ?[]const u8, body: ?[]const u8) !Reply {
    const headers = [_][2][]const u8{ .{ "Content-Type", "application/json" }, .{ "X-Api-Key", key orelse "" } };
    var r = try anole.client(io).fetch(url, .{
        .method = method,
        .headers = if (key != null) &headers else headers[0..1],
        .body = body,
    });
    defer r.deinit();
    return .{ .status = r.status(), .body = try arena.dupe(u8, try r.body()) };
}

fn expectReply(want_status: anole.http.Status, want_body: []const u8, got: Reply) !void {
    try std.testing.expectEqual(want_status, got.status);
    try std.testing.expectEqualStrings(want_body, got.body);
}

test "examples/rest: create, list, get, update, delete, the API key and JSON errors" {
    var store: rest.Store = .{ .gpa = alloc, .api_key_digest = rest.keyDigest("test-api-key-not-a-secret") };
    defer store.deinit();
    var app = try Server.init(alloc, .{ .errors = .json, .executors = .exact(2) }, &store);
    defer app.deinit();
    rest.routes(&app);

    const Check = struct {
        fn run(a: *Server) !void {
            defer a.stop();
            try a.waitReady();
            const io = a.io();
            var arena_state: std.heap.ArenaAllocator = .init(alloc);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const base = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/api/users", .{a.addresses()[0].ip.getPort()});
            const one = try std.fmt.allocPrint(arena, "{s}/1", .{base});
            const key = "test-api-key-not-a-secret";

            // The key: none is a 401, a wrong one a 403, both as JSON.
            try expectReply(.unauthorized, "{\"error\":\"Unauthorized\"}", try call(io, arena, .get, base, null, null));
            try expectReply(.forbidden, "{\"error\":\"wrong API key\"}", try call(io, arena, .get, base, "nope", null));

            // A field NewUser lacks is ignored.
            try expectReply(.created, "{\"id\":1,\"name\":\"Ada\",\"email\":\"ada@example.com\"}", try call(io, arena, .post, base, key, "{\"name\":\"Ada\",\"email\":\"ada@example.com\",\"extra\":1}"));
            _ = try call(io, arena, .post, base, key, "{\"name\":\"Grace\",\"email\":\"grace@example.com\"}");

            try expectReply(.ok, "[{\"id\":1,\"name\":\"Ada\",\"email\":\"ada@example.com\"},{\"id\":2,\"name\":\"Grace\",\"email\":\"grace@example.com\"}]", try call(io, arena, .get, base, key, null));
            const limited = try std.fmt.allocPrint(arena, "{s}?limit=1", .{base});
            try expectReply(.ok, "[{\"id\":1,\"name\":\"Ada\",\"email\":\"ada@example.com\"}]", try call(io, arena, .get, limited, key, null));
            try expectReply(.ok, "{\"id\":1,\"name\":\"Ada\",\"email\":\"ada@example.com\"}", try call(io, arena, .get, one, key, null));

            try expectReply(.ok, "{\"id\":1,\"name\":\"Ada L.\",\"email\":\"ada@example.com\"}", try call(io, arena, .put, one, key, "{\"name\":\"Ada L.\",\"email\":\"ada@example.com\"}"));
            try expectReply(.ok, "{\"id\":1,\"name\":\"Ada L.\",\"email\":\"ada@example.com\"}", try call(io, arena, .get, one, key, null));

            // Bodies that do not fit (422 problem+json naming every field),
            // none at all (400), and rules (name not blank, email an address).
            const wrong_type = try call(io, arena, .post, base, key, "{\"name\":1}");
            try std.testing.expectEqual(anole.http.Status.unprocessable_entity, wrong_type.status);
            try std.testing.expect(std.mem.indexOf(u8, wrong_type.body, "{\"in\":\"body\",\"field\":\"name\",\"code\":\"http.invalid_type\",\"message\":\"must be a string\"}") != null);
            try std.testing.expect(std.mem.indexOf(u8, wrong_type.body, "\"field\":\"email\",\"code\":\"http.missing_field\"") != null);
            try expectReply(.bad_request, "{\"error\":\"Bad Request\"}", try call(io, arena, .post, base, key, null));
            const rules = try call(io, arena, .post, base, key, "{\"name\":\"  \",\"email\":\"x\"}");
            try std.testing.expectEqual(anole.http.Status.unprocessable_entity, rules.status);
            try std.testing.expect(std.mem.indexOf(u8, rules.body, "\"field\":\"name\",\"code\":\"validation.not_blank\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, rules.body, "\"field\":\"email\",\"code\":\"validation.email\"") != null);
            const missing = try std.fmt.allocPrint(arena, "{s}/99", .{base});
            // The body is checked first: a valid one for the 404, a broken
            // rule on a user that exists is 422.
            try expectReply(.not_found, "{\"error\":\"Not Found\"}", try call(io, arena, .put, missing, key, "{\"name\":\"X\",\"email\":\"x@example.com\"}"));
            const bad_put = try call(io, arena, .put, one, key, "{\"name\":\"X\",\"email\":\"x\"}");
            try std.testing.expectEqual(anole.http.Status.unprocessable_entity, bad_put.status);
            try std.testing.expect(std.mem.indexOf(u8, bad_put.body, "\"field\":\"email\",\"code\":\"validation.email\"") != null);
            const not_a_number = try std.fmt.allocPrint(arena, "{s}/abc", .{base});
            try expectReply(.not_found, "{\"error\":\"Not Found\"}", try call(io, arena, .get, not_a_number, key, null));

            try expectReply(.no_content, "", try call(io, arena, .delete, one, key, null));
            try expectReply(.not_found, "{\"error\":\"Not Found\"}", try call(io, arena, .get, one, key, null));
            try expectReply(.not_found, "{\"error\":\"Not Found\"}", try call(io, arena, .delete, one, key, null));
        }
    };
    var checking = try app.io().concurrent(Check.run, .{&app});
    try app.listen("127.0.0.1:0");
    try checking.await(app.io());
    try std.testing.expectEqual(1, store.users.count());
}
