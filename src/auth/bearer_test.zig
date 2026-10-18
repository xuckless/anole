//! `RequireJwt` end to end: the RFC 6750 answers, claims into the session
//! for the handler only, scopes.
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

    pub fn execute(self: *const FakeSession, req: *dusty.Request, _: *dusty.Response, executor: anytype) !void {
        try req.session.set("user", "from-session");
        req.session.modified = false;
        try executor.next();
        const v = req.session.get("user") orelse "(none)";
        @memcpy(self.after[0..v.len], v);
        self.after_len.* = v.len;
        if (req.session.get("jwt_sub") != null or req.session.modified) self.after_len.* = 0;
    }
};

fn handler(req: *dusty.Request, res: *dusty.Response) !void {
    res.body = try std.fmt.allocPrint(req.arena, "sub={s} user={s} role={s}", .{
        req.session.get("jwt_sub") orelse "-",
        req.session.get("user") orelse "-",
        req.session.get("role") orelse "-",
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

test "RequireJwt: RFC 6750 answers, claims for the handler only, scopes" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();

    const keys = [_]jws.Key{.{ .alg = .HS256, .material = .{ .hmac = secret } }};
    var plain = bearer.RequireJwt.init(.{ .static = &keys }, .{ .issuer = "me", .audience = "api" }, .{ .realm = "example" });
    var mapped = bearer.RequireJwt.init(.{ .static = &keys }, .{ .issuer = "me", .audience = "api" }, .{
        .claims = &.{ .{ .claim = "sub", .key = "user", .required = true }, .{ .claim = "role", .key = "role" } },
        .scopes = &.{ "notes:read", "notes:write" },
    });
    var after: [64]u8 = undefined;
    var after_len: usize = 0;
    var fake: FakeSession = .{ .after = &after, .after_len = &after_len };

    var server = dusty.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer server.deinit();
    const M = dusty.Middleware(void);
    const plain_mw = [_]M{ .init(&fake), .init(&plain) };
    const mapped_mw = [_]M{ .init(&fake), .init(&mapped) };
    server.router.group("/plain", &plain_mw).get("/me", handler);
    server.router.group("/mapped", &mapped_mw).get("/me", handler);
    var future = try io.concurrent(struct {
        fn r(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.r, .{&server});
    defer future.cancel(io) catch {};
    try server.ready.wait(io);
    const port = server.address.ip.getPort();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const now = std.Io.Clock.real.now(io).toSeconds();
    const good = try token(arena, try std.fmt.allocPrint(arena, "\"iss\":\"me\",\"aud\":\"api\",\"sub\":\"alice\",\"role\":\"editor\",\"scope\":\"notes:write notes:read\",\"exp\":{d}", .{now + 600}));
    const expired = try token(arena, try std.fmt.allocPrint(arena, "\"iss\":\"me\",\"aud\":\"api\",\"sub\":\"alice\",\"exp\":{d}", .{now - 600}));
    const other_aud = try token(arena, try std.fmt.allocPrint(arena, "\"iss\":\"me\",\"aud\":\"web\",\"sub\":\"alice\",\"exp\":{d}", .{now + 600}));
    const narrow = try token(arena, try std.fmt.allocPrint(arena, "\"iss\":\"me\",\"aud\":\"api\",\"sub\":\"bob\",\"scope\":\"notes:read\",\"exp\":{d}", .{now + 600}));
    const no_sub = try token(arena, try std.fmt.allocPrint(arena, "\"iss\":\"me\",\"aud\":\"api\",\"exp\":{d}", .{now + 600}));

    var out: [4096]u8 = undefined;
    // No token: 401 and a challenge without an error code.
    var resp = try exchange(io, port, "/plain/me", null, &out);
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 401"));
    try std.testing.expect(has(resp, "WWW-Authenticate: Bearer realm=\"example\"\r\n"));
    resp = try exchange(io, port, "/plain/me", "Basic YTpi", &out);
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 401"));
    // A malformed header: 400 invalid_request.
    resp = try exchange(io, port, "/plain/me", "Bearer a b", &out);
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 400"));
    try std.testing.expect(has(resp, "error=\"invalid_request\""));
    // Bad tokens: 401 invalid_token.
    resp = try exchange(io, port, "/plain/me", try std.fmt.allocPrint(arena, "Bearer {s}", .{other_aud}), &out);
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 401"));
    try std.testing.expect(has(resp, "WWW-Authenticate: Bearer realm=\"example\", error=\"invalid_token\"\r\n"));
    resp = try exchange(io, port, "/plain/me", try std.fmt.allocPrint(arena, "Bearer {s}", .{expired}), &out);
    try std.testing.expect(has(resp, "error=\"invalid_token\", error_description=\"The access token expired\""));
    resp = try exchange(io, port, "/plain/me", try std.fmt.allocPrint(arena, "Bearer {s}x", .{good}), &out);
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 401"));
    // A required claim missing.
    resp = try exchange(io, port, "/plain/me", try std.fmt.allocPrint(arena, "Bearer {s}", .{no_sub}), &out);
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 401"));

    // A good token: the default mapping puts `sub` in "jwt_sub"; the
    // session's own "user" is untouched, before and after.
    resp = try exchange(io, port, "/plain/me", try std.fmt.allocPrint(arena, "bearer  {s}", .{good}), &out);
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200"));
    try std.testing.expect(std.mem.endsWith(u8, resp, "sub=alice user=from-session role=-"));
    try std.testing.expectEqualStrings("from-session", after[0..after_len]);

    // A mapping over the session's own key: the handler sees the token's,
    // the session gets its own back.
    resp = try exchange(io, port, "/mapped/me", try std.fmt.allocPrint(arena, "Bearer {s}", .{good}), &out);
    try std.testing.expect(std.mem.endsWith(u8, resp, "sub=- user=alice role=editor"));
    try std.testing.expectEqualStrings("from-session", after[0..after_len]);
    // Too few scopes: 403 insufficient_scope, naming the ones needed.
    resp = try exchange(io, port, "/mapped/me", try std.fmt.allocPrint(arena, "Bearer {s}", .{narrow}), &out);
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 403"));
    try std.testing.expect(has(resp, "WWW-Authenticate: Bearer error=\"insufficient_scope\", scope=\"notes:read notes:write\"\r\n"));
}
