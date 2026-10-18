//! The session middleware end to end, in both modes.
const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");
const session = @import("root.zig");

fn setUser(req: *dusty.Request, res: *dusty.Response) !void {
    try req.session.set("user", "42");
    res.body = "set";
}

fn getUser(req: *dusty.Request, res: *dusty.Response) !void {
    res.body = req.session.get("user") orelse "none";
}

fn logout(req: *dusty.Request, res: *dusty.Response) !void {
    req.session.clear();
    res.body = "bye";
}

/// The response to `request` on a fresh connection.
fn exchange(io: std.Io, port: u16, request: []const u8, out: []u8) ![]const u8 {
    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var wbuf: [1024]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.writeAll(request);
    try w.interface.flush();
    var rbuf: [4096]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    var fw: std.Io.Writer = .fixed(out);
    _ = r.interface.streamRemaining(&fw) catch {};
    return fw.buffered();
}

/// The session cookie's value from a response, if set.
fn cookieOf(resp: []const u8, buf: []u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, resp, "Set-Cookie: anole_session=") orelse return null;
    const start = at + "Set-Cookie: anole_session=".len;
    const end = std.mem.indexOfAnyPos(u8, resp, start, ";\r") orelse return null;
    const v = resp[start..end];
    @memcpy(buf[0..v.len], v);
    return buf[0..v.len];
}

fn run(store: ?session.Store) !void {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var server = dusty.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer server.deinit();
    var mw = session.Middleware.init(.{ .store = store, .key = @splat(3) });
    server.router.use(dusty.Middleware(void).init(&mw));
    server.router.get("/set", setUser);
    server.router.get("/get", getUser);
    server.router.get("/logout", logout);
    var future = try io.concurrent(struct {
        fn r(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.r, .{&server});
    defer future.cancel(io) catch {};
    try server.ready.wait(io);
    const port = server.address.ip.getPort();

    var out: [4096]u8 = undefined;
    var cookie_buf: [512]u8 = undefined;
    const set = try exchange(io, port, "GET /set HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
    const cookie = cookieOf(set, &cookie_buf).?;
    try std.testing.expect(std.mem.indexOf(u8, set, "HttpOnly") != null);

    var req_buf: [1024]u8 = undefined;
    const get_req = try std.fmt.bufPrint(&req_buf, "GET /get HTTP/1.1\r\nHost: x\r\nCookie: anole_session={s}\r\nConnection: close\r\n\r\n", .{cookie});
    var out2: [4096]u8 = undefined;
    try std.testing.expect(std.mem.endsWith(u8, try exchange(io, port, get_req, &out2), "42"));

    // A tampered cookie is no session.
    var bad_buf: [512]u8 = undefined;
    @memcpy(bad_buf[0..cookie.len], cookie);
    bad_buf[cookie.len / 2] = if (bad_buf[cookie.len / 2] == 'A') 'B' else 'A';
    var bad_req_buf: [1024]u8 = undefined;
    const bad_req = try std.fmt.bufPrint(&bad_req_buf, "GET /get HTTP/1.1\r\nHost: x\r\nCookie: anole_session={s}\r\nConnection: close\r\n\r\n", .{bad_buf[0..cookie.len]});
    var out3: [4096]u8 = undefined;
    try std.testing.expect(std.mem.endsWith(u8, try exchange(io, port, bad_req, &out3), "none"));

    // Logging out clears the cookie (and the stored session).
    var lo_buf: [1024]u8 = undefined;
    const lo_req = try std.fmt.bufPrint(&lo_buf, "GET /logout HTTP/1.1\r\nHost: x\r\nCookie: anole_session={s}\r\nConnection: close\r\n\r\n", .{cookie});
    var out4: [4096]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, try exchange(io, port, lo_req, &out4), "Max-Age=0") != null);
    if (store != null) {
        var out5: [4096]u8 = undefined;
        try std.testing.expect(std.mem.endsWith(u8, try exchange(io, port, get_req, &out5), "none"));
    }
}

test "session: encrypted cookie" {
    try run(null);
}

test "session: memory store" {
    var mem = session.MemoryStore.init(std.testing.allocator, std.testing.io);
    defer mem.deinit();
    try run(mem.store());
}
