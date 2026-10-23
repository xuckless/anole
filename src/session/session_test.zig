//! The session middleware end to end, in both modes.
const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");
const session = @import("root.zig");
const features = @import("build_options");
const RedisStore = if (features.redis) session.RedisStore else void;

fn setUser(req: *dusty.Request, res: *dusty.Response) !void {
    try req.session.set("user", "42");
    res.body = "set";
}

fn getUser(req: *dusty.Request, res: *dusty.Response) !void {
    res.body = req.session.get("user") orelse "none";
}

fn entries(req: *dusty.Request, res: *dusty.Response) !void {
    res.body = try std.fmt.allocPrint(req.arena, "entries={d}", .{req.session.len});
}

fn signIn(req: *dusty.Request, res: *dusty.Response) !void {
    try req.session.set("user", "alice");
    try session.regenerate(req);
    res.body = "signed in";
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

const Kind = enum { cookie, memory, redis };

fn run(kind: Kind) !void {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var mem = session.MemoryStore.init(gpa, io, .{});
    defer mem.deinit();
    var redis_store: RedisStore = undefined;
    var store: ?session.Store = null;
    switch (kind) {
        .cookie => {},
        .memory => store = mem.store(),
        .redis => if (comptime features.redis) {
            const live = @import("../redis/live_test.zig");
            if (live.url == null) return error.SkipZigTest;
            redis_store = .{ .client = try live.open(io, .{}), .gpa = gpa };
            store = redis_store.store();
        } else return error.SkipZigTest,
    }
    defer if (comptime features.redis) if (kind == .redis) redis_store.client.deinit();
    var server = dusty.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer server.deinit();
    var mw = try session.Middleware.init(if (store) |st| .{ .store = st } else .{ .key = @splat(3) });
    server.router.use(dusty.Middleware(void).init(&mw));
    server.router.get("/set", setUser);
    server.router.get("/get", getUser);
    server.router.get("/logout", logout);
    server.router.get("/signin", signIn);
    server.router.get("/entries", entries);
    var future = try io.concurrent(struct {
        fn r(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.r, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);
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

    // Signing in issues a new cookie; with a store, the old id is gone.
    var si_buf: [1024]u8 = undefined;
    const si_req = try std.fmt.bufPrint(&si_buf, "GET /signin HTTP/1.1\r\nHost: x\r\nCookie: anole_session={s}\r\nConnection: close\r\n\r\n", .{cookie});
    var out_si: [4096]u8 = undefined;
    var fresh_buf: [512]u8 = undefined;
    const fresh = cookieOf(try exchange(io, port, si_req, &out_si), &fresh_buf).?;
    try std.testing.expect(!std.mem.eql(u8, fresh, cookie));
    var fresh_req_buf: [1024]u8 = undefined;
    const fresh_req = try std.fmt.bufPrint(&fresh_req_buf, "GET /get HTTP/1.1\r\nHost: x\r\nCookie: anole_session={s}\r\nConnection: close\r\n\r\n", .{fresh});
    var out_fresh: [4096]u8 = undefined;
    const fresh_resp = try exchange(io, port, fresh_req, &out_fresh);
    try std.testing.expect(std.mem.endsWith(u8, fresh_resp, "alice"));
    // The marker is never saved, only "user".
    var entries_buf: [1024]u8 = undefined;
    const entries_req = try std.fmt.bufPrint(&entries_buf, "GET /entries HTTP/1.1\r\nHost: x\r\nCookie: anole_session={s}\r\nConnection: close\r\n\r\n", .{fresh});
    var out_entries: [4096]u8 = undefined;
    try std.testing.expect(std.mem.endsWith(u8, try exchange(io, port, entries_req, &out_entries), "entries=1"));
    var out_old: [4096]u8 = undefined;
    const old_resp = try exchange(io, port, get_req, &out_old);
    // A sealed cookie has no id to destroy: the old copy still opens, with
    // the data from before the sign-in.
    try std.testing.expect(std.mem.endsWith(u8, old_resp, if (store != null) "none" else "42"));

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
    try run(.cookie);
}

test "session: memory store" {
    try run(.memory);
}

test "redis: live session store (RedisStore)" {
    try run(.redis);
}

/// Lets a test hold a request inside its handler, after the session was
/// loaded, while other requests run.
const Gate = struct {
    var entered: std.Io.Event = .unset;
    var release: std.Io.Event = .unset;

    fn reset() void {
        entered = .unset;
        release = .unset;
    }

    /// Reads the session, then waits for the test.
    fn slowRead(req: *dusty.Request, res: *dusty.Response) !void {
        res.body = req.session.get("user") orelse "none";
        entered.set(req.io);
        try release.wait(req.io);
    }

    /// Writes to the session, then waits for the test.
    fn slowWrite(req: *dusty.Request, res: *dusty.Response) !void {
        try req.session.set("seen", "1");
        res.body = "wrote";
        entered.set(req.io);
        try release.wait(req.io);
    }
};

/// A request that loaded the session before another one logged out must not
/// bring the session back when it ends, whether it changed the session or
/// not.
fn runInFlight(slow_path: []const u8) !void {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var mem = session.MemoryStore.init(gpa, io, .{});
    defer mem.deinit();
    var server = dusty.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer server.deinit();
    var mw = try session.Middleware.init(.{ .store = mem.store() });
    server.router.use(dusty.Middleware(void).init(&mw));
    server.router.get("/set", setUser);
    server.router.get("/get", getUser);
    server.router.get("/logout", logout);
    server.router.get("/slow-read", Gate.slowRead);
    server.router.get("/slow-write", Gate.slowWrite);
    var future = try io.concurrent(struct {
        fn r(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.r, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);
    const port = server.address.ip.getPort();
    Gate.reset();

    var out: [4096]u8 = undefined;
    var cookie_buf: [512]u8 = undefined;
    const cookie = cookieOf(try exchange(io, port, "GET /set HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out), &cookie_buf).?;

    var slow_buf: [1024]u8 = undefined;
    const slow_req = try std.fmt.bufPrint(&slow_buf, "GET {s} HTTP/1.1\r\nHost: x\r\nCookie: anole_session={s}\r\nConnection: close\r\n\r\n", .{ slow_path, cookie });
    var slow_out: [4096]u8 = undefined;
    var slow = try io.concurrent(exchange, .{ io, port, slow_req, &slow_out });
    defer _ = slow.cancel(io) catch {};
    try Gate.entered.wait(io);

    // Logged out while the slow request is still in its handler.
    var lo_buf: [1024]u8 = undefined;
    const lo_req = try std.fmt.bufPrint(&lo_buf, "GET /logout HTTP/1.1\r\nHost: x\r\nCookie: anole_session={s}\r\nConnection: close\r\n\r\n", .{cookie});
    var lo_out: [4096]u8 = undefined;
    _ = try exchange(io, port, lo_req, &lo_out);

    Gate.release.set(io);
    const slow_resp = try slow.await(io);
    // It got no cookie for the session it can no longer have.
    var slow_cookie: [512]u8 = undefined;
    try std.testing.expect(cookieOf(slow_resp, &slow_cookie) == null);

    var get_buf: [1024]u8 = undefined;
    const get_req = try std.fmt.bufPrint(&get_buf, "GET /get HTTP/1.1\r\nHost: x\r\nCookie: anole_session={s}\r\nConnection: close\r\n\r\n", .{cookie});
    var get_out: [4096]u8 = undefined;
    try std.testing.expect(std.mem.endsWith(u8, try exchange(io, port, get_req, &get_out), "none"));
}

test "session: a request in flight does not restore a logged-out session (read)" {
    try runInFlight("/slow-read");
}

test "session: a request in flight does not restore a logged-out session (write)" {
    try runInFlight("/slow-write");
}
