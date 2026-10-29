//! `RequireJwt` end to end: the RFC 6750 answers, the token in the
//! request's locals (`claims`, `subject`) and nowhere in the session,
//! required claims, scopes.
const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");
const bearer = @import("bearer.zig");
const jws = @import("jws.zig");

const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const b64 = std.base64.url_safe_no_pad;
const secret = "0123456789abcdef0123456789abcdef";

/// An HS256 token with these claims (JSON object members, without braces).
fn token(arena: std.mem.Allocator, claims: []const u8) ![]const u8 {
    const header = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
    const body = try std.fmt.allocPrint(arena, "{{{s}}}", .{claims});
    const h = try arena.alloc(u8, b64.Encoder.calcSize(header.len));
    const c = try arena.alloc(u8, b64.Encoder.calcSize(body.len));
    const input = try std.fmt.allocPrint(arena, "{s}.{s}", .{ b64.Encoder.encode(h, header), b64.Encoder.encode(c, body) });
    var mac: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&mac, input, secret);
    const s = try arena.alloc(u8, b64.Encoder.calcSize(mac.len));
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ input, b64.Encoder.encode(s, &mac) });
}

/// Stands in for a session middleware: the session holds "user" before
/// the bearer middleware runs, and must hold it unchanged after.
const FakeSession = struct {
    after: *[64]u8,
    after_len: *usize,

    pub fn execute(self: *const FakeSession, req: *dusty.Request, _: *dusty.Response, next: anytype) !void {
        try req.session.set("user", "from-session");
        req.session.modified = false;
        try next.call();
        const v = req.session.get("user") orelse "(none)";
        @memcpy(self.after[0..v.len], v);
        self.after_len.* = v.len;
        if (req.session.len != 1 or req.session.modified) self.after_len.* = 0;
    }
};

fn handler(req: *dusty.Request, res: *dusty.Response) !void {
    res.body = try std.fmt.allocPrint(req.arena, "subject={s} alg={t} role={s} user={s} entries={d}", .{
        bearer.subject(req) orelse "-",
        bearer.claims(req).?.alg,
        bearer.claims(req).?.string("role") orelse "-",
        req.session.get("user") orelse "-",
        req.session.len,
    });
}

fn exchange(io: std.Io, port: u16, path: []const u8, auth: ?[]const u8, out: []u8) ![]const u8 {
    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var wbuf: [2048]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.print("GET {s} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n", .{path});
    if (auth) |a| try w.interface.print("Authorization: {s}\r\n", .{a});
    try w.interface.writeAll("\r\n");
    try w.interface.flush();
    var rbuf: [4096]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    var fw: std.Io.Writer = .fixed(out);
    _ = r.interface.streamRemaining(&fw) catch {};
    return fw.buffered();
}

fn has(resp: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, resp, needle) != null;
}

const hs256_keys = [_]jws.Key{.{ .alg = .HS256, .material = .{ .hmac = secret } }};
const M = dusty.Middleware(void);

/// Static: the server keeps the slice past the fixture's `start`.
const loopback_listeners = [_]dusty.Listener{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }};

/// A server with two groups behind `FakeSession` + `RequireJwt`: /plain
/// (realm "example") and /mapped (required claims sub and role, scopes
/// notes:read and notes:write), each serving `handler` at /me.
const Fixture = struct {
    rt: *zio.Runtime,
    plain: bearer.RequireJwt,
    mapped: bearer.RequireJwt,
    after: [64]u8 = undefined,
    after_len: usize = 0,
    fake: FakeSession,
    plain_mw: [2]M,
    mapped_mw: [2]M,
    server: dusty.Server(void),
    future: std.Io.Future(anyerror!void),
    port: u16,
    arena_state: std.heap.ArenaAllocator,
    now: i64,
    out: [4096]u8 = undefined,

    fn runServer(s: *dusty.Server(void)) anyerror!void {
        try s.run();
    }

    fn start(f: *Fixture, gpa: std.mem.Allocator) !void {
        f.rt = try zio.Runtime.init(gpa, .{});
        errdefer f.rt.deinit();
        const io = f.rt.io();
        f.plain = bearer.RequireJwt.init(.{ .static = &hs256_keys }, .{ .issuer = "me", .audience = "api" }, .{ .realm = "example" });
        f.mapped = bearer.RequireJwt.init(.{ .static = &hs256_keys }, .{ .issuer = "me", .audience = "api" }, .{
            .required_claims = &.{ "sub", "role" },
            .scopes = &.{ "notes:read", "notes:write" },
        });
        f.after_len = 0;
        f.fake = .{ .after = &f.after, .after_len = &f.after_len };
        f.server = dusty.Server(void).init(gpa, io, .{ .listeners = &loopback_listeners }, {});
        errdefer f.server.deinit();
        f.plain_mw = .{ .init(&f.fake), .init(&f.plain) };
        f.mapped_mw = .{ .init(&f.fake), .init(&f.mapped) };
        f.server.router.group("/plain", &f.plain_mw).get("/me", handler);
        f.server.router.group("/mapped", &f.mapped_mw).get("/me", handler);
        f.future = try io.concurrent(runServer, .{&f.server});
        errdefer f.future.cancel(io) catch {};
        try f.server.waitReady(io);
        f.port = f.server.address.ip.getPort();
        f.arena_state = .init(gpa);
        f.now = std.Io.Clock.real.now(io).toSeconds();
    }

    fn deinit(f: *Fixture) void {
        const io = f.rt.io();
        f.future.cancel(io) catch {};
        f.server.deinit();
        f.arena_state.deinit();
        f.rt.deinit();
    }

    /// "Bearer <token>" for these claims plus an `exp` this many seconds
    /// from now (600 s margins: no clock edge in reach).
    fn bearerFor(f: *Fixture, claims: []const u8, exp_in: i64) ![]const u8 {
        const arena = f.arena_state.allocator();
        const t = try token(arena, try std.fmt.allocPrint(arena, "{s},\"exp\":{d}", .{ claims, f.now + exp_in }));
        return std.fmt.allocPrint(arena, "Bearer {s}", .{t});
    }

    fn get(f: *Fixture, path: []const u8, auth: ?[]const u8) ![]const u8 {
        return exchange(f.rt.io(), f.port, path, auth, &f.out);
    }
};

const good_claims = "\"iss\":\"me\",\"aud\":\"api\",\"sub\":\"alice\",\"role\":\"editor\",\"scope\":\"notes:write notes:read\"";

test "RequireJwt: no or a malformed Authorization gets 401 with a bare challenge or 400 invalid_request" {
    var f: Fixture = undefined;
    try f.start(std.testing.allocator);
    defer f.deinit();

    // No token: 401 and a challenge without an error code.
    var resp = try f.get("/plain/me", null);
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 401"));
    try std.testing.expect(has(resp, "WWW-Authenticate: Bearer realm=\"example\"\r\n"));
    // Another scheme counts as no token.
    resp = try f.get("/plain/me", "Basic YTpi");
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 401"));
    try std.testing.expect(!has(resp, "error="));
    // A malformed header: 400 invalid_request.
    resp = try f.get("/plain/me", "Bearer a b");
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 400"));
    try std.testing.expect(has(resp, "error=\"invalid_request\""));
}

test "RequireJwt: a bad, expired or wrong-audience token gets 401 invalid_token" {
    var f: Fixture = undefined;
    try f.start(std.testing.allocator);
    defer f.deinit();

    var resp = try f.get("/plain/me", try f.bearerFor("\"iss\":\"me\",\"aud\":\"web\",\"sub\":\"alice\"", 600));
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 401"));
    try std.testing.expect(has(resp, "WWW-Authenticate: Bearer realm=\"example\", error=\"invalid_token\"\r\n"));
    resp = try f.get("/plain/me", try f.bearerFor("\"iss\":\"me\",\"aud\":\"api\",\"sub\":\"alice\"", -600));
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 401"));
    try std.testing.expect(has(resp, "error=\"invalid_token\", error_description=\"The access token expired\""));
    // A tampered signature.
    const arena = f.arena_state.allocator();
    resp = try f.get("/plain/me", try std.fmt.allocPrint(arena, "{s}x", .{try f.bearerFor(good_claims, 600)}));
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 401"));
    try std.testing.expect(has(resp, "error=\"invalid_token\""));
}

test "RequireJwt: verified claims reach the handler through the locals and never touch the session" {
    var f: Fixture = undefined;
    try f.start(std.testing.allocator);
    defer f.deinit();
    const arena = f.arena_state.allocator();

    // The scheme is case-insensitive and takes extra spaces.
    const good = try f.bearerFor(good_claims, 600);
    var resp = try f.get("/plain/me", try std.fmt.allocPrint(arena, "bearer  {s}", .{good["Bearer ".len..]}));
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200"));
    try std.testing.expect(std.mem.endsWith(u8, resp, "subject=alice alg=HS256 role=editor user=from-session entries=1"));
    try std.testing.expectEqualStrings("from-session", f.after[0..f.after_len]);

    resp = try f.get("/mapped/me", good);
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200"));
    try std.testing.expect(std.mem.endsWith(u8, resp, "subject=alice alg=HS256 role=editor user=from-session entries=1"));
    try std.testing.expectEqualStrings("from-session", f.after[0..f.after_len]);
}

test "RequireJwt: a missing required claim is 401 invalid_token, too few scopes 403 insufficient_scope naming them" {
    var f: Fixture = undefined;
    try f.start(std.testing.allocator);
    defer f.deinit();

    // No sub at all.
    var resp = try f.get("/plain/me", try f.bearerFor("\"iss\":\"me\",\"aud\":\"api\"", 600));
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 401"));
    // A claim `required_claims` names (role), missing.
    resp = try f.get("/mapped/me", try f.bearerFor("\"iss\":\"me\",\"aud\":\"api\",\"sub\":\"bob\",\"scope\":\"notes:read\"", 600));
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 401"));
    try std.testing.expect(has(resp, "error=\"invalid_token\""));
    // Too few scopes: 403 insufficient_scope, naming the ones needed.
    resp = try f.get("/mapped/me", try f.bearerFor("\"iss\":\"me\",\"aud\":\"api\",\"sub\":\"bob\",\"role\":\"reader\",\"scope\":\"notes:read\"", 600));
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 403"));
    try std.testing.expect(has(resp, "WWW-Authenticate: Bearer error=\"insufficient_scope\", scope=\"notes:read notes:write\"\r\n"));
}

test "RequireJwt.noWait: static keys yes, a keyring no, a hook no" {
    const keys: []const jws.Key = &.{};
    const static_mw = bearer.RequireJwt.init(.{ .static = keys }, .{}, .{});
    try std.testing.expect(static_mw.noWait());
    var ring: @import("keyring.zig").Keyring = undefined;
    const ring_mw = bearer.RequireJwt.init(.{ .keyring = &ring }, .{}, .{});
    try std.testing.expect(!ring_mw.noWait());
    const Hooks = struct {
        fn check(_: ?*anyopaque, _: *dusty.Request, _: *const jws.Verified) anyerror!void {}
    };
    const hooked = bearer.RequireJwt.init(.{ .static = keys }, .{}, .{ .hook = .{ .func = Hooks.check } });
    try std.testing.expect(!hooked.noWait());
}
