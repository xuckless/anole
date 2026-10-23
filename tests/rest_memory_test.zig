//! examples/rest through anole.testing: the same scenario as rest_test.zig,
//! with no socket (and so no port, no timing).
const std = @import("std");
const anole = @import("anole");
const rest = @import("rest");

const alloc = std.testing.allocator;
const key = "test-api-key-not-a-secret";

const auth = [_][2][]const u8{.{ "X-Api-Key", key }};

test "examples/rest in memory: create, list, get, update, delete, the API key and the 422" {
    var store: rest.Store = .{ .gpa = alloc, .api_key_digest = rest.keyDigest(key) };
    defer store.deinit();
    var app = try anole.Server(rest.Store).init(alloc, .{ .errors = .json, .executors = .exact(1) }, &store);
    defer app.deinit();
    rest.routes(&app);
    var t = try anole.testing.client(&app);
    defer t.deinit();

    // The key: none is a 401, a wrong one a 403, both as JSON.
    var none = try t.get("/api/users", .{});
    defer none.deinit();
    try none.expectStatus(.unauthorized);
    try none.expectBody("{\"error\":\"Unauthorized\"}");
    var wrong = try t.get("/api/users", .{ .headers = &.{.{ "X-Api-Key", "nope" }} });
    defer wrong.deinit();
    try wrong.expectStatus(.forbidden);

    // A field NewUser lacks is ignored.
    var created = try t.post("/api/users", .{ .headers = &auth, .json = .{ .name = "Ada", .email = "ada@example.com", .extra = 1 } });
    defer created.deinit();
    try created.expectStatus(.created);
    try created.expectBody("{\"id\":1,\"name\":\"Ada\",\"email\":\"ada@example.com\"}");

    var listed = try t.get("/api/users?limit=5", .{ .headers = &auth });
    defer listed.deinit();
    try listed.expectJson(.{.{ .id = 1, .name = "Ada", .email = "ada@example.com" }});

    var updated = try t.put("/api/users/1", .{ .headers = &auth, .json = .{ .name = "Ada L.", .email = "ada@example.com" } });
    defer updated.deinit();
    try updated.expectStatus(.ok);

    // Bodies that do not fit are 422 with every field named.
    var bad = try t.post("/api/users", .{ .headers = &auth, .json = .{ .name = "  ", .email = "x" } });
    defer bad.deinit();
    try bad.expectStatus(.unprocessable_entity);
    try bad.expectViolation("name", "validation.not_blank");
    try bad.expectViolation("email", "validation.email");
    var typed = try t.post("/api/users", .{ .headers = &auth, .json = .{ .name = 1 } });
    defer typed.deinit();
    try typed.expectViolation("name", "http.invalid_type");
    try typed.expectViolation("email", "http.missing_field");
    var empty = try t.post("/api/users", .{ .headers = &auth });
    defer empty.deinit();
    try empty.expectStatus(.bad_request);

    var gone = try t.delete("/api/users/1", .{ .headers = &auth });
    defer gone.deinit();
    try gone.expectStatus(.no_content);
    var missing = try t.get("/api/users/1", .{ .headers = &auth });
    defer missing.deinit();
    try missing.expectStatus(.not_found);
}
