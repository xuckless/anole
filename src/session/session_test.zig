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
    // The rest of what came is the answer, however the stream ended; but
    // a cancel of the calling task is passed on, not swallowed.
    _ = r.interface.streamRemaining(&fw) catch |err| switch (err) {
        error.ReadFailed => if (r.err) |e| if (e == error.Canceled) return error.Canceled,
        else => {},
    };
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

/// Static: the server keeps the slice past the fixture's `start`.
const loopback_listeners = [_]dusty.Listener{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }};

const Kind = enum { cookie, memory, redis };

/// A server with the session middleware in `kind`'s mode (a sealed cookie,
/// the memory store, or a live Redis store) and the routes above.
const Fixture = struct {
    kind: Kind,
    rt: *zio.Runtime,
    mem: session.MemoryStore,
    redis_store: RedisStore = undefined,
    mw: session.Middleware,
    server: dusty.Server(void),
    future: std.Io.Future(anyerror!void),
    port: u16,

    fn serve(s: *dusty.Server(void)) anyerror!void {
        try s.run();
    }

    /// `error.SkipZigTest` for `.redis` without a live Redis.
    fn start(f: *Fixture, kind: Kind) !void {
        const gpa = std.testing.allocator;
        f.kind = kind;
        if (kind == .redis) {
            if (comptime !features.redis) return error.SkipZigTest;
            if (@import("../redis/live_test.zig").url == null) return error.SkipZigTest;
        }
        f.rt = try zio.Runtime.init(gpa, .{});
        errdefer f.rt.deinit();
        const io = f.rt.io();
        f.mem = session.MemoryStore.init(gpa, io, .{});
        errdefer f.mem.deinit();
        var store: ?session.Store = null;
        switch (kind) {
            .cookie => {},
            .memory => store = f.mem.store(),
            .redis => if (comptime features.redis) {
                f.redis_store = .{ .client = try @import("../redis/live_test.zig").open(io, .{}), .gpa = gpa };
                store = f.redis_store.store();
            } else unreachable,
        }
        errdefer if (comptime features.redis) if (kind == .redis) f.redis_store.client.deinit();
        f.mw = try session.Middleware.init(if (store) |st| .{ .store = st } else .{ .key = @splat(3) });
        f.server = dusty.Server(void).init(gpa, io, .{ .listeners = &loopback_listeners }, {});
        errdefer f.server.deinit();
        f.server.router.use(dusty.Middleware(void).init(&f.mw));
        f.server.router.get("/set", setUser);
        f.server.router.get("/get", getUser);
        f.server.router.get("/logout", logout);
        f.server.router.get("/signin", signIn);
        f.server.router.get("/entries", entries);
        f.future = try io.concurrent(serve, .{&f.server});
        errdefer f.future.cancel(io) catch {};
        try f.server.waitReady(io);
        f.port = f.server.address.ip.getPort();
    }

    fn deinit(f: *Fixture) void {
        f.future.cancel(f.rt.io()) catch {};
        f.server.deinit();
        if (comptime features.redis) if (f.kind == .redis) f.redis_store.client.deinit();
        f.mem.deinit();
        f.rt.deinit();
    }

    /// The response to a GET of `path`, with the session cookie if given.
    fn get(f: *Fixture, path: []const u8, cookie: ?[]const u8, out: []u8) ![]const u8 {
        var req_buf: [1024]u8 = undefined;
        const req = if (cookie) |c|
            try std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: x\r\nCookie: anole_session={s}\r\nConnection: close\r\n\r\n", .{ path, c })
        else
            try std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", .{path});
        return exchange(f.rt.io(), f.port, req, out);
    }

    /// Sets "user" to 42 in a new session; its cookie, in `buf`.
    fn signedCookie(f: *Fixture, buf: []u8) ![]const u8 {
        var out: [4096]u8 = undefined;
        return cookieOf(try f.get("/set", null, &out), buf) orelse error.NoSessionCookie;
    }
};

fn valueReadInNextRequest(kind: Kind) !void {
    var f: Fixture = undefined;
    try f.start(kind);
    defer f.deinit();
    var out: [4096]u8 = undefined;
    var cookie_buf: [512]u8 = undefined;
    const set = try f.get("/set", null, &out);
    try std.testing.expect(std.mem.indexOf(u8, set, "HttpOnly") != null);
    const cookie = cookieOf(set, &cookie_buf).?;
    var out2: [4096]u8 = undefined;
    try std.testing.expect(std.mem.endsWith(u8, try f.get("/get", cookie, &out2), "42"));
}

fn tamperedCookieOpensNothing(kind: Kind) !void {
    var f: Fixture = undefined;
    try f.start(kind);
    defer f.deinit();
    var cookie_buf: [512]u8 = undefined;
    const cookie = try f.signedCookie(&cookie_buf);
    var bad_buf: [512]u8 = undefined;
    @memcpy(bad_buf[0..cookie.len], cookie);
    bad_buf[cookie.len / 2] = if (bad_buf[cookie.len / 2] == 'A') 'B' else 'A';
    var out: [4096]u8 = undefined;
    try std.testing.expect(std.mem.endsWith(u8, try f.get("/get", bad_buf[0..cookie.len], &out), "none"));
}

fn signInIssuesNewCookie(kind: Kind) !void {
    var f: Fixture = undefined;
    try f.start(kind);
    defer f.deinit();
    var cookie_buf: [512]u8 = undefined;
    const cookie = try f.signedCookie(&cookie_buf);

    var out_si: [4096]u8 = undefined;
    var fresh_buf: [512]u8 = undefined;
    const fresh = cookieOf(try f.get("/signin", cookie, &out_si), &fresh_buf).?;
    try std.testing.expect(!std.mem.eql(u8, fresh, cookie));
    var out_fresh: [4096]u8 = undefined;
    try std.testing.expect(std.mem.endsWith(u8, try f.get("/get", fresh, &out_fresh), "alice"));
    // The regenerate marker is never saved, only "user".
    var out_entries: [4096]u8 = undefined;
    try std.testing.expect(std.mem.endsWith(u8, try f.get("/entries", fresh, &out_entries), "entries=1"));
    // With a store the old id is gone; a sealed cookie has no id to
    // destroy: the old copy still opens, with the data from before.
    var out_old: [4096]u8 = undefined;
    try std.testing.expect(std.mem.endsWith(u8, try f.get("/get", cookie, &out_old), if (kind == .cookie) "42" else "none"));
}

fn logoutClears(kind: Kind) !void {
    var f: Fixture = undefined;
    try f.start(kind);
    defer f.deinit();
    var cookie_buf: [512]u8 = undefined;
    const cookie = try f.signedCookie(&cookie_buf);
    var out: [4096]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, try f.get("/logout", cookie, &out), "Max-Age=0") != null);
    // A store forgets the session; a sealed cookie lives on in the client
    // only (the browser deletes it on Max-Age=0).
    if (kind != .cookie) {
        var out2: [4096]u8 = undefined;
        try std.testing.expect(std.mem.endsWith(u8, try f.get("/get", cookie, &out2), "none"));
    }
}

test "session (encrypted cookie): a value set in one request is read in the next" {
    try valueReadInNextRequest(.cookie);
}
test "session (encrypted cookie): a tampered cookie opens no session" {
    try tamperedCookieOpensNothing(.cookie);
}
test "session (encrypted cookie): signing in issues a new cookie and leaves the sealed copy" {
    try signInIssuesNewCookie(.cookie);
}
test "session (encrypted cookie): logout clears the cookie" {
    try logoutClears(.cookie);
}

test "session (memory store): a value set in one request is read in the next" {
    try valueReadInNextRequest(.memory);
}
test "session (memory store): a tampered cookie opens no session" {
    try tamperedCookieOpensNothing(.memory);
}
test "session (memory store): signing in issues a new cookie and drops the old id" {
    try signInIssuesNewCookie(.memory);
}
test "session (memory store): logout clears the cookie and the stored session" {
    try logoutClears(.memory);
}

test "redis: live session store (RedisStore): a value set in one request is read in the next" {
    try valueReadInNextRequest(.redis);
}
test "redis: live session store (RedisStore): a tampered cookie opens no session" {
    try tamperedCookieOpensNothing(.redis);
}
test "redis: live session store (RedisStore): signing in issues a new cookie and drops the old id" {
    try signInIssuesNewCookie(.redis);
}
test "redis: live session store (RedisStore): logout clears the cookie and the stored session" {
    try logoutClears(.redis);
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
