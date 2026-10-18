//! Auth and request protection: a password login that starts a sealed
//! cookie session, CSRF tokens, roles, JWT bearer tokens, API keys and a
//! rate limit on the login.
//!
//!   zig build run-auth                  # http://localhost:8084
//!   zig build run-auth -- 9000          # another port
//!
//!   GET  /login         a login form; its CSRF token also in X-CSRF-Token
//!   POST /login         user + password + _csrf; 5 tries a minute per address
//!   GET  /me            who the session belongs to, and a fresh CSRF token
//!   POST /notes         needs the session, its CSRF token and "notes:write"
//!   POST /logout        ends the session (CSRF-protected too)
//!   GET  /api/me        needs `Authorization: Bearer <JWT>` (HS256)
//!   GET  /service/stats needs `X-API-Key: ak_...`
//!
//! Users: alice (editor) and bob (reader), both with the password
//! "demo-password". Every secret here (the session key, the JWT key, the
//! API key, the password hashes) is made at startup and printed or kept in
//! memory only, so nothing survives a restart. docs/auth.md walks through
//! the routes with curl.
const std = @import("std");
const anole = @import("anole");
const http = anole.http;
const auth = anole.auth;

/// Keeps the runtime's per-thread lines and the connection loops' debug
/// lines out of a Debug build; info (startup lines, access log) stays.
pub const std_options = anole.std_options;

const issuer = "anole-auth-example";
const demo_password = "demo-password";

const User = struct {
    name: []const u8,
    role: []const u8,
    hash: []const u8 = "",
};

const App = struct {
    gpa: std.mem.Allocator,
    users: [2]User = .{
        .{ .name = "alice", .role = "editor" },
        .{ .name = "bob", .role = "reader" },
    },
    /// Checked when the user is unknown, so a wrong name takes as long as
    /// a wrong password and does not reveal which names exist.
    dummy_hash: []const u8 = "",
    api_key_digest: auth.apikey.Digest = undefined,

    fn find(app: *App, name: []const u8) ?*const User {
        for (&app.users) |*u| if (std.mem.eql(u8, u.name, name)) return u;
        return null;
    }
};

/// Roles grant permissions; an editor also has everything a reader has.
const policy: auth.rbac.Policy = .{ .roles = &.{
    .{ .name = "reader", .grants = &.{"notes:read"} },
    .{ .name = "editor", .grants = &.{"notes:*"}, .includes = &.{"reader"} },
} };

/// The request's roles: the session's one role. (`Roles.ptr` could carry
/// the app, to look roles up in its state instead.)
fn rolesOf(_: ?*anyopaque, req: *http.Request) anyerror![]const []const u8 {
    const role = req.session.get("role") orelse return &.{};
    const roles = try req.arena.alloc([]const u8, 1);
    roles[0] = role;
    return roles;
}

const form_html =
    \\<!doctype html><title>Sign in</title>
    \\<form method="post" action="/login">
    \\<input type="hidden" name="_csrf" value="{s}">
    \\<input name="user" placeholder="alice"> <input name="password" type="password">
    \\<button>Sign in</button></form>
;

fn loginForm(_: *App, req: *http.Request, res: *http.Response) !void {
    const token = try auth.csrf.token(req);
    try res.header(auth.csrf.header_name, token);
    try res.print(.html, form_html, .{token});
}

fn login(app: *App, req: *http.Request, res: *http.Response) !void {
    // The CSRF middleware has parsed the form already; this is its copy.
    const form = try req.formData();
    const user = app.find(form.get("user") orelse "");
    const stored = if (user) |u| u.hash else app.dummy_hash;
    const ok = auth.password.verify(app.gpa, req.io, stored, form.get("password") orelse "");
    if (!ok or user == null) return res.fail(.unauthorized, "wrong user or password");
    try req.session.set("user", user.?.name);
    try req.session.set("role", user.?.role);
    // A new session at sign-in (against session fixation: with a store, a
    // new id; this sealed cookie is sealed afresh), and a new CSRF token,
    // which /me hands out.
    try anole.session.regenerate(req);
    req.session.remove(auth.csrf.session_key);
    try res.print(.text, "signed in as {s}\n", .{user.?.name});
}

fn me(_: *App, req: *http.Request, res: *http.Response) !void {
    const user = req.session.get("user") orelse return res.fail(.unauthorized, "not signed in");
    try res.print(.text, "user: {s}\nrole: {s}\ncsrf: {s}\n", .{ user, req.session.get("role").?, try auth.csrf.token(req) });
}

fn addNote(_: *App, req: *http.Request, res: *http.Response) !void {
    // Only a signed-in editor gets here: RBAC ran first, and without a
    // session there is no role.
    res.status = .created;
    try res.print(.text, "note saved by {s}\n", .{req.session.get("user").?});
}

fn logout(_: *App, req: *http.Request, res: *http.Response) !void {
    req.session.clear(); // the middleware expires the cookie
    try res.print(.text, "signed out\n", .{});
}

fn apiMe(_: *App, req: *http.Request, res: *http.Response) !void {
    // The token RequireJwt verified, from the request's locals.
    const token = auth.claims(req) orelse return error.Unauthorized;
    try res.print(.text, "token subject: {s}, role: {s}\n", .{ auth.subject(req) orelse "-", token.string("role") orelse "-" });
}

fn serviceStats(_: *App, req: *http.Request, res: *http.Response) !void {
    const owner = auth.apikey.owner(req) orelse return error.Unauthorized;
    try res.print(.text, "stats for {s}: 42 requests\n", .{owner});
}

/// API key owners by key digest; a real app looks the digest up in its
/// database.
fn lookupKey(ptr: ?*anyopaque, _: std.mem.Allocator, digest: auth.apikey.Digest) anyerror!?[]const u8 {
    const app: *App = @ptrCast(@alignCast(ptr.?));
    return if (std.mem.eql(u8, &digest, &app.api_key_digest)) "reporting-service" else null;
}

pub fn main(init: std.process.Init) !void {
    var port: u16 = 8084;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    if (args.next()) |p| port = try std.fmt.parseInt(u16, p, 10);
    const arena = init.arena.allocator();

    var app: App = .{ .gpa = init.gpa };
    // A blocking pool: password hashes run beside the executors, which
    // go on serving other requests meanwhile.
    var server = try anole.Server(App).init(init.gpa, .{ .http = .{ .port = port }, .blocking = .{} }, &app);
    defer server.deinit();
    const io = server.io();

    // Argon2id hashes (PHC strings); a real app stores these.
    for (&app.users) |*u| u.hash = try auth.password.hash(init.gpa, io, demo_password, try arena.alloc(u8, 128));
    app.dummy_hash = try auth.password.hash(init.gpa, io, "no such user", try arena.alloc(u8, 128));

    // One API key, shown once; only its SHA-256 is kept.
    const api_key = try auth.apikey.generate(arena, io);
    app.api_key_digest = api_key.digest;

    // A demo HS256 key, pinned to that algorithm, and a token signed with it.
    var jwt_secret: [32]u8 = undefined;
    io.random(&jwt_secret);
    const jwt_keys = [_]auth.Key{.{ .kid = "demo", .alg = .HS256, .material = .{ .hmac = &jwt_secret } }};
    const now = std.Io.Clock.real.now(io).toSeconds();
    var signer = auth.jwt.SigningMethodHS256.init(arena);
    const token = try signer.signWithHeader(.{ .typ = "JWT", .alg = "HS256", .kid = "demo" }, .{
        .iss = issuer,
        .aud = "api",
        .sub = "alice",
        .role = "editor",
        .iat = now,
        .exp = now + 3600,
    }, &jwt_secret);

    // Sessions sealed in the cookie (XChaCha20-Poly1305), with a key made
    // here; give every node the same key from your secret store instead.
    var session_key: [anole.session.key_length]u8 = undefined;
    io.random(&session_key);
    var sessions = anole.session.Middleware.init(.{ .key = session_key });
    var csrf = auth.csrf.Middleware.init(.{});
    var limiter = anole.ratelimit.MemoryLimiter.init(init.gpa, io, .{});
    defer limiter.deinit();
    var login_limit = anole.ratelimit.Middleware.init(limiter.limiter(), .{ .limit = 5, .window_ms = 60_000 });
    var can_write = auth.rbac.Require.init(&policy, "notes:write", .{ .roles = rolesOf });
    // Bearer tokens: the handler reads the verified token with
    // `auth.claims(req)` and `auth.subject(req)`.
    var bearer = auth.RequireJwt.init(.{ .static = &jwt_keys }, .{ .issuer = issuer, .audience = "api" }, .{});
    var api_keys = auth.apikey.Middleware.init(.{ .ptr = &app, .lookup = lookupKey });

    const M = http.Middleware(App);
    const web = [_]M{ .init(&sessions), .init(&csrf) };
    const limited = [_]M{ .init(&login_limit), .init(&sessions), .init(&csrf) };
    const writers = [_]M{ .init(&sessions), .init(&csrf), .init(&can_write) };
    const jwt_only = [_]M{.init(&bearer)};
    const key_only = [_]M{.init(&api_keys)};

    server.use(http.middleware.RequestId.init(.{}));
    server.use(http.middleware.Logger.init());
    server.group("", &web).get("/login", loginForm);
    server.group("", &limited).post("/login", login);
    server.group("", &web).get("/me", me);
    server.group("", &writers).post("/notes", addNote);
    server.group("", &web).post("/logout", logout);
    server.group("/api", &jwt_only).get("/me", apiMe);
    server.group("/service", &key_only).get("/stats", serviceStats);

    std.log.info("users alice (editor) and bob (reader), password \"{s}\"", .{demo_password});
    std.log.info("demo JWT for alice, valid 1 h:\n{s}", .{token});
    std.log.info("demo API key:\n{s}", .{api_key.key});
    try server.run();
}
