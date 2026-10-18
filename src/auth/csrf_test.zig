//! CSRF and API keys end to end, with the session middleware ahead of them.
const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");
const session = @import("../session/root.zig");
const csrf = @import("csrf.zig");
const apikey = @import("apikey.zig");

fn form(req: *dusty.Request, res: *dusty.Response) !void {
    res.body = try csrf.token(req);
}

fn submit(_: *dusty.Request, res: *dusty.Response) !void {
    res.body = "accepted";
}

fn send(io: std.Io, port: u16, request: []const u8, out: []u8) ![]const u8 {
    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var wbuf: [2048]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.writeAll(request);
    try w.interface.flush();
    var rbuf: [4096]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    var fw: std.Io.Writer = .fixed(out);
    _ = r.interface.streamRemaining(&fw) catch {};
    return fw.buffered();
}

test "CSRF: a token from the session, required on POST" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var server = dusty.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer server.deinit();
    var sessions = session.Middleware.init(.{ .key = @splat(9) });
    var protect = csrf.Middleware.init(.{});
    server.router.use(dusty.Middleware(void).init(&sessions));
    server.router.use(dusty.Middleware(void).init(&protect));
    server.router.get("/form", form);
    server.router.post("/submit", submit);
    var future = try io.concurrent(struct {
        fn r(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.r, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);
    const port = server.address.ip.getPort();

    var out: [4096]u8 = undefined;
    const page = try send(io, port, "GET /form HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
    const c_at = std.mem.indexOf(u8, page, "Set-Cookie: anole_session=").? + "Set-Cookie: anole_session=".len;
    var cookie_buf: [512]u8 = undefined;
    const c_end = std.mem.indexOfScalarPos(u8, page, c_at, ';').?;
    const cookie = cookie_buf[0 .. c_end - c_at];
    @memcpy(cookie, page[c_at..c_end]);
    var token_buf: [64]u8 = undefined;
    const body = page[std.mem.indexOf(u8, page, "\r\n\r\n").? + 4 ..];
    const token = token_buf[0..body.len];
    @memcpy(token, body);

    var req_buf: [2048]u8 = undefined;
    var out2: [4096]u8 = undefined;
    // No token: refused.
    const no_token = try std.fmt.bufPrint(&req_buf, "POST /submit HTTP/1.1\r\nHost: x\r\nCookie: anole_session={s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{cookie});
    try std.testing.expect(std.mem.startsWith(u8, try send(io, port, no_token, &out2), "HTTP/1.1 403"));
    // A wrong token: refused.
    const wrong = try std.fmt.bufPrint(&req_buf, "POST /submit HTTP/1.1\r\nHost: x\r\nCookie: anole_session={s}\r\nX-CSRF-Token: {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{ cookie, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" });
    try std.testing.expect(std.mem.startsWith(u8, try send(io, port, wrong, &out2), "HTTP/1.1 403"));
    // The token in the header: accepted.
    const header = try std.fmt.bufPrint(&req_buf, "POST /submit HTTP/1.1\r\nHost: x\r\nCookie: anole_session={s}\r\nX-CSRF-Token: {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{ cookie, token });
    try std.testing.expect(std.mem.endsWith(u8, try send(io, port, header, &out2), "accepted"));
    // The token as a form field: accepted.
    var form_body: [128]u8 = undefined;
    const fb = try std.fmt.bufPrint(&form_body, "name=x&_csrf={s}", .{token});
    const field = try std.fmt.bufPrint(&req_buf, "POST /submit HTTP/1.1\r\nHost: x\r\nCookie: anole_session={s}\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ cookie, fb.len, fb });
    try std.testing.expect(std.mem.endsWith(u8, try send(io, port, field, &out2), "accepted"));
}

fn owner(req: *dusty.Request, res: *dusty.Response) !void {
    res.body = req.session.get("api_key_owner") orelse "none";
}

test "API key: the owner reaches the handler but never a session cookie" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var server = dusty.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer server.deinit();
    const Keys = struct {
        fn lookup(_: ?*anyopaque, _: std.mem.Allocator, d: apikey.Digest) anyerror!?[]const u8 {
            return if (std.mem.eql(u8, &d, &apikey.digest("k1"))) "svc-a" else null;
        }
    };
    var sessions = session.Middleware.init(.{ .key = @splat(9) });
    var keys = apikey.Middleware.init(.{ .ptr = null, .lookup = Keys.lookup });
    server.router.use(dusty.Middleware(void).init(&sessions));
    server.router.use(dusty.Middleware(void).init(&keys));
    server.router.get("/owner", owner);
    var future = try io.concurrent(struct {
        fn r(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.r, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);
    const port = server.address.ip.getPort();

    var out: [4096]u8 = undefined;
    const ok = try send(io, port, "GET /owner HTTP/1.1\r\nHost: x\r\nX-API-Key: k1\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, ok, "HTTP/1.1 200"));
    try std.testing.expect(std.mem.endsWith(u8, ok, "svc-a"));
    try std.testing.expect(std.mem.indexOf(u8, ok, "Set-Cookie") == null);
    const refused = try send(io, port, "GET /owner HTTP/1.1\r\nHost: x\r\nX-API-Key: nope\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, refused, "HTTP/1.1 401"));
}
