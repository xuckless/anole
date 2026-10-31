//! The built-in middlewares' refusals (JWT, API key, RBAC, CSRF, rate
//! limit) are answered by the server like any handler's error: in its
//! error format, through `error_handler`, with the middleware's protocol
//! headers kept (issue #33).
const std = @import("std");
const anole = @import("../root.zig");
const dusty = @import("dusty");

const hs256_keys = [_]anole.auth.jws.Key{.{ .alg = .HS256, .material = .{ .hmac = "0123456789abcdef0123456789abcdef" } }};
const policy: anole.auth.rbac.Policy = .{ .roles = &.{.{ .name = "reader", .grants = &.{"notes:read"} }} };

fn noRoles(_: ?*anyopaque, _: *dusty.Request) anyerror![]const []const u8 {
    return &.{};
}

fn ok(_: *dusty.Request, res: *dusty.Response) !void {
    res.body = "ok";
}

/// One route behind each middleware, on `app`. `limiter` must outlive it.
fn routes(app: *anole.App, limiter: *anole.ratelimit.MemoryLimiter) void {
    app.with(.{anole.auth.RequireJwt.init(.{ .static = &hs256_keys }, .{}, .{})}).get("/jwt", ok);
    app.with(.{anole.auth.apikey.Middleware.init(.{ .ptr = null, .lookup = struct {
        fn f(_: ?*anyopaque, _: std.mem.Allocator, _: anole.auth.apikey.Digest) anyerror!?[]const u8 {
            return null;
        }
    }.f })}).get("/key", ok);
    app.with(.{anole.auth.rbac.Require.init(&policy, "notes:write", .{ .roles = noRoles })}).get("/rbac", ok);
    app.with(.{anole.auth.csrf.Middleware.init(.{})}).post("/csrf", ok);
    app.with(.{anole.ratelimit.Middleware.init(limiter.limiter(), .{ .limit = 1 })}).get("/limited", ok);
}

test "auth, CSRF and rate-limit refusals answer in the server's error format, headers kept" {
    var app = try anole.App.init(std.testing.allocator, .{ .executors = .exact(1), .errors = .json });
    defer app.deinit();
    var limiter = anole.ratelimit.MemoryLimiter.init(std.testing.allocator, std.testing.io, .{});
    defer limiter.deinit();
    routes(&app, &limiter);
    var t = try anole.testing.client(&app);
    defer t.deinit();

    var jwt = try t.get("/jwt", .{});
    defer jwt.deinit();
    try jwt.expectStatus(.unauthorized);
    try jwt.expectHeader("www-authenticate", "Bearer");
    try jwt.expectBody("{\"error\":\"Unauthorized\"}");

    var key = try t.get("/key", .{});
    defer key.deinit();
    try key.expectStatus(.unauthorized);
    try key.expectHeader("www-authenticate", "Bearer");
    try key.expectBody("{\"error\":\"Unauthorized\"}");

    var rbac = try t.get("/rbac", .{});
    defer rbac.deinit();
    try rbac.expectStatus(.forbidden);
    try rbac.expectBody("{\"error\":\"Forbidden\"}");

    var csrf = try t.post("/csrf", .{});
    defer csrf.deinit();
    try csrf.expectStatus(.forbidden);
    try csrf.expectBody("{\"error\":\"Forbidden\"}");

    var first = try t.get("/limited", .{});
    first.deinit();
    var limited = try t.get("/limited", .{});
    defer limited.deinit();
    try limited.expectStatus(.too_many_requests);
    try std.testing.expect(limited.header("retry-after") != null);
    try limited.expectHeader("ratelimit-remaining", "0");
    try limited.expectBody("{\"error\":\"Too Many Requests\"}");
}

fn onError(req: *dusty.Request, res: *dusty.Response, err: anyerror) void {
    switch (err) {
        error.Unauthorized => res.fail(.unauthorized, "sign in first"),
        error.TooManyRequests => res.fail(.too_many_requests, "slow down"),
        else => anole.defaultError(req, res, err),
    }
}

test "auth and rate-limit refusals reach the server's error_handler" {
    var app = try anole.App.init(std.testing.allocator, .{ .executors = .exact(1), .error_handler = onError });
    defer app.deinit();
    var limiter = anole.ratelimit.MemoryLimiter.init(std.testing.allocator, std.testing.io, .{});
    defer limiter.deinit();
    routes(&app, &limiter);
    var t = try anole.testing.client(&app);
    defer t.deinit();

    var jwt = try t.get("/jwt", .{});
    defer jwt.deinit();
    try jwt.expectStatus(.unauthorized);
    try jwt.expectHeader("www-authenticate", "Bearer");
    try jwt.expectBody("sign in first");

    var first = try t.get("/limited", .{});
    first.deinit();
    var limited = try t.get("/limited", .{});
    defer limited.deinit();
    try limited.expectStatus(.too_many_requests);
    try std.testing.expect(limited.header("retry-after") != null);
    try limited.expectBody("slow down");
}
