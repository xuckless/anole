//! Redis tests on a fake server: calls, pools, readiness, stress and the
//! console info. The unit tests on private decls stay in root.zig; the
//! live-server tests are in live_test.zig.

const std = @import("std");
const features = @import("build_options");
const dusty = @import("dusty");
const db = @import("../db/root.zig");
const internal = @import("../db/internal.zig");
const client_stream = @import("../net/client_stream.zig");
const redis = @import("root.zig");

const Client = redis.Client;
const Query = redis.Query;
const ClientStream = client_stream.ClientStream;
const has_tls = features.tls == .boringssl;
const testing = std.testing;
const environ = internal.testEnviron;

/// A fake server: answers each RESP command it reads with a canned reply,
/// and counts the connections it accepted.
/// `depth` arrays, each the only element of the one before, around an
/// integer.
fn nested(comptime depth: usize) []const u8 {
    @setEvalBranchQuota(100_000);
    var out: []const u8 = "";
    for (0..depth) |_| out = out ++ "*1\r\n";
    return out ++ ":1\r\n";
}

const Fake = struct {
    listener: std.Io.net.Server,
    accepted: std.atomic.Value(u32) = .init(0),
    /// Sessions open now (+1 at accept, -1 when one ends), and the most
    /// open at once.
    live: std.atomic.Value(u32) = .init(0),
    most_live: std.atomic.Value(u32) = .init(0),
    /// GETs and INCRs answered; while `shared_gate` is set to an event, a
    /// GET of "shared" waits for it first.
    gets: std.atomic.Value(u32) = .init(0),
    shared_gate: std.atomic.Value(?*std.Io.Event) = .init(null),
    incrs: std.atomic.Value(u32) = .init(0),
    /// "filled" is nil to GET until a SET of it.
    filled: std.atomic.Value(bool) = .init(false),
    /// PINGs read; while `ping_gate` is set to an event, a PING waits for
    /// it before the answer.
    pings: std.atomic.Value(u32) = .init(0),
    ping_gate: std.atomic.Value(?*std.Io.Event) = .init(null),

    fn port(self: *Fake) u16 {
        return self.listener.socket.address.getPort();
    }

    fn serve(self: *Fake, io: std.Io) !void {
        var group: std.Io.Group = .init;
        defer group.cancel(io);
        while (true) {
            const conn = self.listener.accept(io) catch |err| switch (err) {
                // A client that gave up before the accept: the next one is
                // still served.
                error.ConnectionAborted => continue,
                else => return err,
            };
            _ = self.accepted.fetchAdd(1, .monotonic);
            _ = self.most_live.fetchMax(self.live.fetchAdd(1, .acq_rel) + 1, .acq_rel);
            group.concurrent(io, session, .{ self, conn, io }) catch {
                conn.close(io);
                _ = self.live.fetchSub(1, .acq_rel);
            };
        }
    }

    fn session(self: *Fake, conn: std.Io.net.Stream, io: std.Io) void {
        defer _ = self.live.fetchSub(1, .acq_rel);
        defer conn.close(io);
        var rbuf: [4096]u8 = undefined;
        var wbuf: [4096]u8 = undefined;
        var r = conn.reader(io, &rbuf);
        var w = conn.writer(io, &wbuf);
        while (true) {
            // "*<n>\r\n" then n bulk strings.
            const head = r.interface.takeDelimiterInclusive('\n') catch return;
            const n = std.fmt.parseInt(usize, std.mem.trim(u8, head[1..], "\r\n"), 10) catch return;
            var words: [2][32]u8 = undefined;
            var lens: [2]usize = @splat(0);
            for (0..n) |i| {
                const len_line = r.interface.takeDelimiterInclusive('\n') catch return;
                const len = std.fmt.parseInt(usize, std.mem.trim(u8, len_line[1..], "\r\n"), 10) catch return;
                const arg = r.interface.take(len + 2) catch return;
                if (i < words.len) {
                    lens[i] = @min(len, 32);
                    @memcpy(words[i][0..lens[i]], arg[0..lens[i]]);
                }
            }
            const cmd = words[0][0..lens[0]];
            const eql = std.mem.eql;
            if (eql(u8, cmd, "GET")) {
                _ = self.gets.fetchAdd(1, .monotonic);
                if (eql(u8, words[1][0..lens[1]], "shared")) if (self.shared_gate.load(.acquire)) |gate| gate.wait(io) catch return;
            }
            if (eql(u8, cmd, "INCR")) _ = self.incrs.fetchAdd(1, .monotonic);
            if (eql(u8, cmd, "PING")) {
                _ = self.pings.fetchAdd(1, .release);
                if (self.ping_gate.load(.acquire)) |gate| gate.wait(io) catch return;
            }
            const key = words[1][0..lens[1]];
            if (eql(u8, cmd, "SET") and eql(u8, key, "filled")) self.filled.store(true, .monotonic);
            const nil = eql(u8, key, "missing") or (eql(u8, key, "filled") and !self.filled.load(.monotonic));
            const reply: []const u8 = if (eql(u8, cmd, "SET") or eql(u8, cmd, "MULTI"))
                "+OK\r\n"
            else if (eql(u8, cmd, "GET"))
                (if (nil) "$-1\r\n" else "$5\r\nvalue\r\n")
            else if (eql(u8, cmd, "INCR"))
                ":42\r\n"
            else if (eql(u8, cmd, "HGETALL"))
                "*4\r\n$4\r\nname\r\n$3\r\nAda\r\n$6\r\nvisits\r\n$1\r\n3\r\n"
            else if (eql(u8, cmd, "KEYS"))
                "*2\r\n$1\r\na\r\n$1\r\nb\r\n"
            else if (eql(u8, cmd, "LPUSH"))
                "-WRONGTYPE Operation against a key holding the wrong kind of value\r\n"
            else if (eql(u8, cmd, "DEBUG"))
                "-LOADING Redis is loading the dataset in memory\r\n"
            else if (eql(u8, cmd, "PING"))
                "+PONG\r\n"
            else if (eql(u8, cmd, "NESTED"))
                comptime nested(30)
            else if (eql(u8, cmd, "DEEP"))
                comptime nested(1000)
            else if (eql(u8, cmd, "SLOW")) blk: {
                io.sleep(.fromSeconds(5), .awake) catch return;
                break :blk "+late\r\n";
            } else "-ERR unknown command\r\n";
            w.interface.writeAll(reply) catch return;
            w.interface.flush() catch return;
        }
    }
};

test "redis: cache-aside: keep_empty = false asks again after nil; lastSource for X-Cache" {
    const zio = @import("zio");
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var fake: Fake = .{ .listener = try addr.listen(io, .{}) };
    defer fake.listener.deinit(io);
    var serving = try io.concurrent(Fake.serve, .{ &fake, io });
    defer serving.cancel(io) catch {};

    var url_buf: [64]u8 = undefined;
    const client = try Client.init(gpa, io, .{ .url = try std.fmt.bufPrint(&url_buf, "redis://127.0.0.1:{d}", .{fake.port()}), .environ = .empty });
    defer client.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };

    // nil is not kept: each GET goes to the server until the value is
    // there, and then the value is kept.
    const aside = client.with(.{ .cache = .{ .ttl = .fromSeconds(60), .keep_empty = false } });
    try testing.expect(try aside.get(&c, "filled") == null);
    try testing.expectEqual(@as(?db.Source, .database), db.lastSource(&c));
    try testing.expect(try aside.get(&c, "filled") == null);
    try testing.expectEqual(@as(?db.Source, .database), db.lastSource(&c));
    try testing.expectEqual(@as(u32, 2), fake.gets.load(.monotonic));
    // The miss filled in, as cache-aside does: no invalidation needed.
    _ = try client.set(&c, "filled", "value", .{});
    try testing.expectEqualStrings("value", (try aside.get(&c, "filled")).?);
    try testing.expectEqual(@as(?db.Source, .database), db.lastSource(&c));
    try testing.expectEqualStrings("value", (try aside.get(&c, "filled")).?);
    try testing.expectEqual(@as(?db.Source, .cache), db.lastSource(&c));
    try testing.expectEqual(@as(u32, 3), fake.gets.load(.monotonic));

    // By default nil is kept like any reply.
    const keeping = client.with(.{ .cache = .{ .ttl = .fromSeconds(60) } });
    try testing.expect(try keeping.get(&c, "missing") == null);
    try testing.expect(try keeping.get(&c, "missing") == null);
    try testing.expectEqual(@as(?db.Source, .cache), db.lastSource(&c));
    try testing.expectEqual(@as(u32, 4), fake.gets.load(.monotonic));
    // A plain call leaves the last source as it was.
    _ = try client.get(&c, "missing");
    try testing.expectEqual(@as(?db.Source, .cache), db.lastSource(&c));
}

test "redis: calls over a fake server: replies decode into the asked types, all on one connection" {
    const zio = @import("zio");
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();

    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var fake: Fake = .{ .listener = try addr.listen(io, .{}) };
    defer fake.listener.deinit(io);
    var serving = try io.concurrent(Fake.serve, .{ &fake, io });
    defer serving.cancel(io) catch {};

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "redis://127.0.0.1:{d}", .{fake.port()});
    const client = try Client.init(gpa, io, .{ .url = url, .environ = .empty, .max_connections = 1 });
    defer client.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };

    try testing.expectEqualStrings("OK", (try client.command(&c, .{ "SET", "k", "value" })).status);
    try testing.expectEqualStrings("value", (try client.get(&c, "k")).?);
    try testing.expect(try client.get(&c, "missing") == null);
    try testing.expectError(error.NotFound, client.one([]const u8, &c, .{ "GET", "missing" }));
    try testing.expectEqual(@as(i64, 42), try client.incr(&c, "n"));
    try testing.expect(try client.set(&c, "k", 5, .{ .ttl = .fromMilliseconds(1500), .nx = true }));
    const Profile = struct { name: []const u8, visits: u32 };
    try testing.expectEqual(@as(u32, 3), (try client.hgetAll(Profile, &c, "u")).visits);
    const keys = try client.all([]const u8, &c, .{"KEYS"});
    try testing.expectEqualStrings("b", keys[1]);
    const replies = try client.pipeline(&c, .{ .{"KEYS"}, .{ "INCR", "n" } });
    try testing.expectEqual(@as(i64, 42), replies[1].int);
    // All of it on one connection, opened once.
    try testing.expectEqual(@as(u32, 1), fake.accepted.load(.monotonic));
}

test "redis: a server error is a 500 (LOADING a 503) and keeps the connection; a pipeline fails with its first error; a reply of the wrong type is a 500" {
    const zio = @import("zio");
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();

    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var fake: Fake = .{ .listener = try addr.listen(io, .{}) };
    defer fake.listener.deinit(io);
    var serving = try io.concurrent(Fake.serve, .{ &fake, io });
    defer serving.cancel(io) catch {};

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "redis://127.0.0.1:{d}", .{fake.port()});
    const client = try Client.init(gpa, io, .{ .url = url, .environ = .empty, .max_connections = 1 });
    defer client.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    // A server error: a 500, the message for the logs; the connection is fine.
    try testing.expectError(error.Database, client.lpush(&c, "k", "x"));
    try testing.expectEqualStrings("WRONGTYPE", db.lastError(&c).?.code);
    try testing.expectError(error.ServiceUnavailable, client.command(&c, .{"DEBUG"}));
    // A pipeline reads every reply, then fails with the first error.
    try testing.expectError(error.Database, client.pipeline(&c, .{ .{ "LPUSH", "k", "x" }, .{ "INCR", "n" } }));
    try testing.expectEqual(@as(i64, 42), try client.incr(&c, "n"));
    try testing.expectEqual(@as(u32, 1), fake.accepted.load(.monotonic));
    // A reply of the wrong type for what was asked: a 500.
    try testing.expectError(error.Database, client.one(i64, &c, .{"KEYS"}));
}

test "redis: replies nested as deep as Redis's own decode; deeper is a broken connection, refused before recursing" {
    const zio = @import("zio");
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();

    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var fake: Fake = .{ .listener = try addr.listen(io, .{}) };
    defer fake.listener.deinit(io);
    var serving = try io.concurrent(Fake.serve, .{ &fake, io });
    defer serving.cancel(io) catch {};

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "redis://127.0.0.1:{d}", .{fake.port()});
    const client = try Client.init(gpa, io, .{ .url = url, .environ = .empty, .max_connections = 1 });
    defer client.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var r = try client.command(&c, .{"NESTED"});
    for (0..30) |_| r = r.array[0];
    try testing.expectEqual(@as(i64, 1), r.int);
    try testing.expectError(error.ServiceUnavailable, client.command(&c, .{"DEEP"}));
    try testing.expectEqual(@as(i64, 42), try client.incr(&c, "n"));
    try testing.expectEqual(@as(u32, 2), fake.accepted.load(.monotonic));
}

test "redis: a call past its timeout is a 504, and its connection is closed rather than reused" {
    const zio = @import("zio");
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();

    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var fake: Fake = .{ .listener = try addr.listen(io, .{}) };
    defer fake.listener.deinit(io);
    var serving = try io.concurrent(Fake.serve, .{ &fake, io });
    defer serving.cancel(io) catch {};

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "redis://127.0.0.1:{d}", .{fake.port()});
    const client = try Client.init(gpa, io, .{ .url = url, .environ = .empty, .max_connections = 1 });
    defer client.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    try testing.expectEqual(@as(i64, 42), try client.incr(&c, "n"));
    // The reply is still to come when the timeout ends the call.
    try testing.expectError(error.GatewayTimeout, client.with(.{ .timeout = .fromMilliseconds(50) }).command(&c, .{"SLOW"}));
    try testing.expectEqual(db.Class.timeout, db.lastError(&c).?.class);
    try testing.expectEqual(@as(i64, 42), try client.incr(&c, "n"));
    try testing.expectEqual(@as(u32, 2), fake.accepted.load(.monotonic));
}

test "redis: a connection left in MULTI is not reused" {
    const zio = @import("zio");
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();

    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var fake: Fake = .{ .listener = try addr.listen(io, .{}) };
    defer fake.listener.deinit(io);
    var serving = try io.concurrent(Fake.serve, .{ &fake, io });
    defer serving.cancel(io) catch {};

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "redis://127.0.0.1:{d}", .{fake.port()});
    const client = try Client.init(gpa, io, .{ .url = url, .environ = .empty, .max_connections = 1 });
    defer client.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };
    try testing.expectEqual(@as(i64, 42), try client.incr(&c, "n"));
    _ = try client.command(&c, .{"MULTI"});
    _ = try client.incr(&c, "n");
    try testing.expectEqual(@as(u32, 2), fake.accepted.load(.monotonic));
}

test "redis: acquire runs its calls on one connection and gives it back" {
    const zio = @import("zio");
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();

    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var fake: Fake = .{ .listener = try addr.listen(io, .{}) };
    defer fake.listener.deinit(io);
    var serving = try io.concurrent(Fake.serve, .{ &fake, io });
    defer serving.cancel(io) catch {};

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "redis://127.0.0.1:{d}", .{fake.port()});
    const client = try Client.init(gpa, io, .{ .url = url, .environ = .empty, .max_connections = 1 });
    defer client.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };
    var conn = try client.acquire(&c);
    _ = try conn.incr(&c, "n");
    _ = try conn.get(&c, "k");
    conn.release();
    _ = try client.incr(&c, "n");
    try testing.expectEqual(@as(u32, 1), fake.accepted.load(.monotonic));
    try testing.expect(try client.readiness.ping(client, io));
}

test "redis: a connection released twice is never handed to two holders" {
    const zio = @import("zio");
    const gpa = testing.allocator;
    const expected_log = @import("../errors.zig").expectLog();
    defer expected_log.deinit();
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();

    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var fake: Fake = .{ .listener = try addr.listen(io, .{}) };
    defer fake.listener.deinit(io);
    var serving = try io.concurrent(Fake.serve, .{ &fake, io });
    defer serving.cancel(io) catch {};

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "redis://127.0.0.1:{d}", .{fake.port()});
    const client = try Client.init(gpa, io, .{ .url = url, .environ = .empty, .max_connections = 2 });
    defer client.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };

    const first = try client.acquire(&c);
    first.release();
    // A second release of the same checkout gives nothing back.
    first.release();
    // Two holders at once: two connections, the second one dialed.
    var x = try client.acquire(&c);
    var y = try client.acquire(&c);
    try testing.expect(x.conn != y.conn);
    _ = try x.incr(&c, "n");
    _ = try y.incr(&c, "n");
    x.release();
    y.release();
    // Retired while another holder has the other place: a second release
    // touches neither the freed connection nor the pool.
    const pool = &client.pools.pools[0];
    const a = try client.acquire(&c);
    const h = try client.acquire(&c);
    a.conn.broken = true;
    a.release();
    a.release();
    try testing.expectEqual(@as(usize, 1), pool.open);
    try testing.expectEqual(@as(usize, 0), pool.idle_len);
    h.release();
    try testing.expectEqual(@as(usize, 1), pool.idle_len);
}

test "redis: a connection released twice after it broke reads no freed memory" {
    const zio = @import("zio");
    const gpa = testing.allocator;
    const expected_log = @import("../errors.zig").expectLog();
    defer expected_log.deinit();
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();

    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var fake: Fake = .{ .listener = try addr.listen(io, .{}) };
    defer fake.listener.deinit(io);
    var serving = try io.concurrent(Fake.serve, .{ &fake, io });
    defer serving.cancel(io) catch {};

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "redis://127.0.0.1:{d}", .{fake.port()});
    const client = try Client.init(gpa, io, .{ .url = url, .environ = .empty, .max_connections = 1 });
    defer client.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };

    const first = try client.acquire(&c);
    // Out of step with the server: the first release closes it.
    first.conn.broken = true;
    first.release();
    // The second release finds the checkout over and gives nothing back.
    first.release();
    const pool = &client.pools.pools[0];
    try testing.expectEqual(@as(usize, 0), pool.open);
    // The one place is free: the next acquire dials and works.
    var next = try client.acquire(&c);
    _ = try next.incr(&c, "n");
    next.release();
    try testing.expectEqual(@as(usize, 1), pool.open);
    try testing.expectEqual(@as(usize, 1), pool.idle_len);
}

/// A probe of `/readyz` on its own task: the task it runs on, the answer,
/// and whether it ended.
const ReadyProbe = struct {
    task: std.atomic.Value(?dusty.placement.Task) = .init(null),
    answer: ?bool = null,
    ended: std.atomic.Value(bool) = .init(false),

    /// `check`, then (`hold`) a wait an hour long that only a cancel ends.
    fn run(p: *ReadyProbe, io: std.Io, client: *Client, hold: bool) std.Io.Cancelable!void {
        defer p.ended.store(true, .release);
        p.task.store(dusty.placement.currentTask(io), .release);
        p.answer = db.Readiness.check(&client.readiness);
        if (hold) try io.sleep(.fromSeconds(3600), .awake);
    }

    fn hasEnded(p: *ReadyProbe) bool {
        return p.ended.load(.acquire);
    }
};

fn pinged(fake: *Fake) bool {
    return fake.pings.load(.acquire) >= 1;
}

test "redis: a readiness probe canceled mid-ping stays canceled" {
    const zio = @import("zio");
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const wait = @import("anole_test_wait");

    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var fake: Fake = .{ .listener = try addr.listen(io, .{}) };
    defer fake.listener.deinit(io);
    var gate: std.Io.Event = .unset;
    fake.ping_gate.store(&gate, .release);
    var serving = try io.concurrent(Fake.serve, .{ &fake, io });
    defer serving.cancel(io) catch {};
    defer gate.set(io);

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "redis://127.0.0.1:{d}", .{fake.port()});
    const client = try Client.init(gpa, io, .{ .url = url, .environ = .empty, .ping_timeout = .fromSeconds(3600) });
    defer client.deinit();

    var probe: ReadyProbe = .{};
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, ReadyProbe.run, .{ &probe, io, client, true });
    try wait.waitUntil(io, "the probe's PING at the server", &fake, pinged);
    dusty.placement.cancelTask(probe.task.load(.acquire).?);
    // The cancel ends the ping, and the probe's task stays canceled: its
    // wait after the check ends at once.
    try wait.waitUntil(io, "the canceled probe's task ended", &probe, ReadyProbe.hasEnded);
}

test "redis: a readiness probe canceled mid-ping leaves no answer behind" {
    const zio = @import("zio");
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const wait = @import("anole_test_wait");

    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var fake: Fake = .{ .listener = try addr.listen(io, .{}) };
    defer fake.listener.deinit(io);
    var gate: std.Io.Event = .unset;
    fake.ping_gate.store(&gate, .release);
    var serving = try io.concurrent(Fake.serve, .{ &fake, io });
    defer serving.cancel(io) catch {};
    defer gate.set(io);

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "redis://127.0.0.1:{d}", .{fake.port()});
    const client = try Client.init(gpa, io, .{ .url = url, .environ = .empty, .ping_timeout = .fromSeconds(3600) });
    defer client.deinit();
    // An answer, once given, is kept for longer than any run of the test.
    client.readiness.ttl = .fromSeconds(3600);

    var probe: ReadyProbe = .{};
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, ReadyProbe.run, .{ &probe, io, client, false });
    try wait.waitUntil(io, "the probe's PING at the server", &fake, pinged);
    dusty.placement.cancelTask(probe.task.load(.acquire).?);
    try wait.waitUntil(io, "the canceled probe's task ended", &probe, ReadyProbe.hasEnded);
    // The server answers from now on: the next probe pings again and is
    // ready, as nothing was kept from the canceled one.
    gate.set(io);
    try testing.expect(db.Readiness.check(&client.readiness));
    try testing.expectEqual(@as(u32, 2), fake.pings.load(.monotonic));
}

/// One task's rounds of calls and checkouts on a shared client.
const PoolStress = struct {
    client: *Client,
    io: std.Io,
    /// Calls that failed or answered wrong: nothing breaks a connection
    /// here, so any failure, a reply of the wrong type or a broken
    /// connection, comes from two holders on one connection.
    failures: std.atomic.Value(u32) = .init(0),

    fn task(p: *PoolStress, seed: u64, rounds: usize) void {
        var prng: std.Random.DefaultPrng = .init(seed);
        const random = prng.random();
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        var c: db.Ctx = .{ .io = p.io, .arena = arena_state.allocator() };
        for (0..rounds) |_| {
            _ = arena_state.reset(.retain_capacity);
            switch (random.uintLessThan(u8, 3)) {
                0 => if (p.client.incr(&c, "n")) |n| {
                    if (n != 42) p.fail();
                } else |err| p.failed(err),
                1 => if (p.client.get(&c, "k")) |v| {
                    if (v == null or !std.mem.eql(u8, v.?, "value")) p.fail();
                } else |err| p.failed(err),
                else => {
                    var conn = p.client.acquire(&c) catch |err| {
                        p.failed(err);
                        continue;
                    };
                    if (conn.incr(&c, "n")) |n| {
                        if (n != 42) p.fail();
                    } else |err| p.failed(err);
                    if (conn.get(&c, "k")) |v| {
                        if (v == null or !std.mem.eql(u8, v.?, "value")) p.fail();
                    } else |err| p.failed(err);
                    conn.release();
                    // A tenth released twice: the second does nothing.
                    if (random.uintLessThan(u8, 10) == 0) conn.release();
                },
            }
        }
    }

    fn failed(p: *PoolStress, err: anyerror) void {
        std.debug.print("redis stress: {t}\n", .{err});
        p.fail();
    }

    fn fail(p: *PoolStress) void {
        _ = p.failures.fetchAdd(1, .monotonic);
    }

    /// Holds two connections of its executor's pool until `go`.
    fn hold(p: *PoolStress, go: *std.Io.Event, held: *std.atomic.Value(u32)) void {
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        var c: db.Ctx = .{ .io = p.io, .arena = arena_state.allocator() };
        const a = p.client.acquire(&c) catch return p.fail();
        defer a.release();
        const b = p.client.acquire(&c) catch return p.fail();
        defer b.release();
        if (a.conn == b.conn) p.fail();
        _ = held.fetchAdd(2, .acq_rel);
        go.wait(p.io) catch {};
    }
};

test "redis: [stress] calls, acquire and double release from four executors never share a connection" {
    const wait = @import("anole_test_wait");
    try wait.requireStress();
    const zio = @import("zio");
    const gpa = testing.allocator;
    const expected_log = @import("../errors.zig").expectLog();
    defer expected_log.deinit();
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(4) });
    defer rt.deinit();
    const io = rt.io();

    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var fake: Fake = .{ .listener = try addr.listen(io, .{}) };
    defer fake.listener.deinit(io);
    var serving = try io.concurrent(Fake.serve, .{ &fake, io });
    defer serving.cancel(io) catch {};

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "redis://127.0.0.1:{d}", .{fake.port()});
    const client = try Client.init(gpa, io, .{ .url = url, .environ = .empty, .max_connections = 8, .acquire_timeout = wait.deadline() });
    defer client.deinit();
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    const seed: u64 = 0x5_2ed15;
    errdefer std.debug.print("redis stress: seed 0x{x}\n", .{seed});
    var p: PoolStress = .{ .client = client, .io = io };
    {
        var group: std.Io.Group = .init;
        defer group.cancel(io);
        for (0..16) |t| try dusty.placement.concurrent(&group, io, .{ .executor = t % 4 }, PoolStress.task, .{ &p, seed +% t, 400 });
        try group.await(io);
    }
    try testing.expectEqual(@as(u32, 0), p.failures.load(.monotonic));
    // No more sessions at the server than the pools' 8 at any time (none
    // closes here, so a session ends only with the test).
    try testing.expect(fake.most_live.load(.acquire) <= 8);
    // Every connection came back once: each pool holds no more than its
    // share, all of it idle.
    for (client.pools.pools) |*pool| {
        try testing.expect(pool.open <= pool.max);
        try testing.expectEqual(pool.open, pool.idle_len);
    }
    // All 8 held at once, two per executor: none was lost to a count
    // that drifted.
    var go: std.Io.Event = .unset;
    var held: std.atomic.Value(u32) = .init(0);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (0..4) |e| try dusty.placement.concurrent(&group, io, .{ .executor = e }, PoolStress.hold, .{ &p, &go, &held });
    try wait.waitEqual(io, "8 connections held", &held, 8);
    go.set(io);
    try group.await(io);
    try testing.expectEqual(@as(u32, 0), p.failures.load(.monotonic));
}

/// What `test_after_take` does to the next connection handed out, once,
/// when armed: shuts its sending side, so the call's first write fails at
/// once (EPIPE) with nothing sent (live_test.zig's `Break.before`).
const BreakNext = struct {
    var armed: std.atomic.Value(bool) = .init(false);

    fn hook(s: *ClientStream) void {
        if (!armed.swap(false, .acq_rel)) return;
        s.socket.shutdown(s.io, .send) catch {};
    }
};

test "redis: a pooled connection that breaks before sending, while the server is gone, fails the call and is freed once" {
    const zio = @import("zio");
    const wait = @import("anole_test_wait");
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();

    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var fake: Fake = .{ .listener = try addr.listen(io, .{}) };
    var listening = true;
    defer if (listening) fake.listener.deinit(io);
    var serving = try io.concurrent(Fake.serve, .{ &fake, io });
    var served = true;
    defer if (served) serving.cancel(io) catch {};

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "redis://127.0.0.1:{d}", .{fake.port()});
    const client = try Client.init(gpa, io, .{ .url = url, .environ = .empty, .max_connections = 1, .acquire_timeout = wait.deadline() });
    defer client.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };
    // One idle connection in the pool.
    try testing.expectEqual(@as(i64, 42), try client.incr(&c, "n"));

    // The server goes away: its sessions end and new dials are refused.
    served = false;
    serving.cancel(io) catch {};
    listening = false;
    fake.listener.deinit(io);

    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    redis.test_after_take = BreakNext.hook;
    defer redis.test_after_take = null;
    BreakNext.armed.store(true, .release);
    // The idle connection fails before sending, so the call runs once more
    // on a new one, which cannot be dialed: a 503, and the first
    // connection was closed and freed once.
    try testing.expectError(error.ServiceUnavailable, client.incr(&c, "n"));
    try testing.expect(!BreakNext.armed.load(.acquire));
    const pool = &client.pools.pools[0];
    try testing.expectEqual(@as(usize, 0), pool.open);
    // A failed dial gives its place back and wakes the call waiting for it:
    // a 503 for both, never a pool_timeout.
    const Other = struct {
        fn incr(cl: *Client, o_io: std.Io) redis.Error!i64 {
            var o_arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer o_arena.deinit();
            var o_c: db.Ctx = .{ .io = o_io, .arena = o_arena.allocator() };
            return cl.incr(&o_c, "n");
        }
    };
    var other = try io.concurrent(Other.incr, .{ client, io });
    try testing.expectError(error.ServiceUnavailable, client.incr(&c, "n"));
    try testing.expectError(error.ServiceUnavailable, other.await(io));
    try testing.expectEqual(@as(usize, 0), pool.open);
}

test "redis: a server that cannot be reached is a 503, and /readyz says so" {
    const zio = @import("zio");
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    // A port nothing listens on: one just closed.
    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try addr.listen(io, .{});
    const port = listener.socket.address.getPort();
    listener.deinit(io);

    var url_buf: [64]u8 = undefined;
    const client = try Client.init(gpa, io, .{ .url = try std.fmt.bufPrint(&url_buf, "redis://127.0.0.1:{d}", .{port}), .environ = .empty });
    defer client.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    try testing.expectError(error.ServiceUnavailable, client.get(&c, "k"));
    try testing.expectStringStartsWith(db.lastError(&c).?.message, "cannot connect to redis://127.0.0.1:");
    try testing.expect(!try client.readiness.ping(client, io));

    // A URL may not turn off the checks of a CA the code gives.
    if (has_tls) try testing.expectError(error.InvalidDatabaseUrl, Client.init(gpa, io, .{ .url = "rediss://cache.example.com?ssl_cert_reqs=none", .environ = .empty, .tls = .{ .ca = .system } }));
}

test "redis: a pool per executor" {
    const zio = @import("zio");
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(4) });
    defer rt.deinit();
    const io = rt.io();
    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var fake: Fake = .{ .listener = try addr.listen(io, .{}) };
    defer fake.listener.deinit(io);
    var serving = try io.concurrent(Fake.serve, .{ &fake, io });
    defer serving.cancel(io) catch {};

    var url_buf: [64]u8 = undefined;
    const client = try Client.init(gpa, io, .{ .url = try std.fmt.bufPrint(&url_buf, "redis://127.0.0.1:{d}", .{fake.port()}), .environ = .empty, .max_connections = 4 });
    defer client.deinit();

    const Worker = struct {
        fn run(cl: *Client, _io: std.Io, failed: *std.atomic.Value(u32)) void {
            var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena_state.deinit();
            var c: db.Ctx = .{ .io = _io, .arena = arena_state.allocator() };
            for (0..10) |_| _ = cl.incr(&c, "n") catch {
                _ = failed.fetchAdd(1, .monotonic);
            };
        }
    };
    var failed: std.atomic.Value(u32) = .init(0);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (0..8) |i| try dusty.placement.concurrent(&group, io, .{ .executor = i % 4 }, Worker.run, .{ client, io, &failed });
    try group.await(io);
    try testing.expectEqual(@as(u32, 0), failed.load(.monotonic));
    // Each executor's pool has a share of one, and opened it.
    try testing.expectEqual(@as(u32, 4), fake.accepted.load(.monotonic));
}

test "redis: consoleInfo gives the target without the login, one pool per executor, JSON-escaped name" {
    const zio = @import("zio");
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    const rows = [_]struct {
        name: []const u8,
        url: []const u8,
        client_name: ?[]const u8 = null,
        want_name: []const u8 = "redis",
        target: []const u8,
        absent: []const []const u8 = &.{},
    }{
        .{ .name = "tcp and database", .url = "redis://127.0.0.1:6380/2", .target = "127.0.0.1:6380/2" },
        .{ .name = "unix socket", .url = "unix:///run/redis.sock?db=3", .target = "unix:/run/redis.sock/3" },
        .{ .name = "password and user never shown", .url = "redis://bob:hunter2@cache.internal:6379/0", .target = "cache.internal:6379/0", .absent = &.{ "bob", "hunter2" } },
        .{ .name = "custom name with a quote", .url = "redis://127.0.0.1:6379", .client_name = "ca\"che", .want_name = "ca\"che", .target = "127.0.0.1:6379/0" },
    };
    for (rows) |row| {
        const client = try Client.init(gpa, io, .{ .url = row.url, .name = row.client_name, .environ = .empty });
        defer client.deinit();
        var parsed = internal.expectConsoleInfo(client, .{
            .system = "redis",
            .name = row.want_name,
            .target = row.target,
            .pools = 2,
            .absent = row.absent,
        }) catch |err| {
            std.debug.print("row: {s}\n", .{row.name});
            return err;
        };
        parsed.deinit();
    }
}

test "redis: consoleInfo counts follow the pool" {
    const zio = @import("zio");
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var fake: Fake = .{ .listener = try addr.listen(io, .{}) };
    defer fake.listener.deinit(io);
    var serving = try io.concurrent(Fake.serve, .{ &fake, io });
    defer serving.cancel(io) catch {};

    var url_buf: [64]u8 = undefined;
    const client = try Client.init(gpa, io, .{ .url = try std.fmt.bufPrint(&url_buf, "redis://127.0.0.1:{d}", .{fake.port()}), .environ = .empty, .max_connections = 3 });
    defer client.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };

    var target_buf: [32]u8 = undefined;
    // (open, idle, in_use) before and after one call: the connection is
    // dialed, used and left idle.
    const before = [_]i64{ 0, 0, 0 };
    const after = [_]i64{ 1, 1, 0 };
    for ([_][3]i64{ before, after }, 0..) |want, step| {
        if (step == 1) _ = try client.incr(&c, "n");
        var parsed = try internal.expectConsoleInfo(client, .{ .system = "redis", .name = "redis", .target = try std.fmt.bufPrint(&target_buf, "127.0.0.1:{d}/0", .{fake.port()}), .pools = 1 });
        defer parsed.deinit();
        const p = parsed.value.object.get("pools").?.array.items[0].object;
        try testing.expectEqual(@as(i64, 3), p.get("max").?.integer);
        try testing.expectEqual(want[0], p.get("open").?.integer);
        try testing.expectEqual(want[1], p.get("idle").?.integer);
        try testing.expectEqual(want[2], p.get("in_use").?.integer);
    }
}

test "redis: coalesced and cached reads, invalidation" {
    const zio = @import("zio");
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var fake: Fake = .{ .listener = try addr.listen(io, .{}) };
    defer fake.listener.deinit(io);
    var serving = try io.concurrent(Fake.serve, .{ &fake, io });
    defer serving.cancel(io) catch {};

    var url_buf: [64]u8 = undefined;
    const client = try Client.init(gpa, io, .{ .url = try std.fmt.bufPrint(&url_buf, "redis://127.0.0.1:{d}", .{fake.port()}), .environ = .empty });
    defer client.deinit();

    // 8 callers on each of 2 executors: one GET per executor.
    const Worker = struct {
        fn run(q: Query, io_: std.Io, bad: *std.atomic.Value(u32)) void {
            var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena_state.deinit();
            var c: db.Ctx = .{ .io = io_, .arena = arena_state.allocator() };
            const v = q.get(&c, "shared") catch null;
            if (v == null or !std.mem.eql(u8, v.?, "value")) _ = bad.fetchAdd(1, .monotonic);
        }
    };
    var bad: std.atomic.Value(u32) = .init(0);
    {
        // The GETs wait at the gate until the other 14 callers joined them,
        // however slow the machine is.
        var gate: std.Io.Event = .unset;
        defer gate.set(io);
        fake.shared_gate.store(&gate, .release);
        defer fake.shared_gate.store(null, .release);
        var group: std.Io.Group = .init;
        defer group.cancel(io);
        for (0..16) |i| try dusty.placement.concurrent(&group, io, .{ .executor = i % 2 }, Worker.run, .{ client.with(.{ .coalesce = true }), io, &bad });
        const Joined = struct {
            fn f(cl: *Client) bool {
                return cl.cache.stats().coalesced >= 14;
            }
        };
        try @import("anole_test_wait").waitUntil(io, "the 14 identical GETs joined the two in flight", client, Joined.f);
        gate.set(io);
        try group.await(io);
    }
    try testing.expectEqual(@as(u32, 0), bad.load(.monotonic));
    try testing.expectEqual(@as(u32, 2), fake.gets.load(.monotonic));
    try testing.expectEqual(@as(u64, 14), client.cache.stats().coalesced);

    // Cached: one GET per executor until invalidated by its tag.
    const cached = client.with(.{ .cache = .{ .ttl = .fromSeconds(60), .tag = "values" } });
    fake.gets.store(0, .monotonic);
    for (0..2) |_| {
        var group: std.Io.Group = .init;
        defer group.cancel(io);
        for (0..8) |i| try dusty.placement.concurrent(&group, io, .{ .executor = i % 2 }, Worker.run, .{ cached, io, &bad });
        try group.await(io);
    }
    try testing.expectEqual(@as(u32, 0), bad.load(.monotonic));
    try testing.expectEqual(@as(u32, 2), fake.gets.load(.monotonic));

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };
    // The command's name in any case is one key; another key is another.
    _ = try cached.optional([]const u8, &c, .{ "get", "shared" });
    try testing.expectEqual(@as(u32, 2), fake.gets.load(.monotonic));
    _ = try cached.get(&c, "k");
    _ = try cached.get(&c, "k");
    try testing.expectEqual(@as(u32, 3), fake.gets.load(.monotonic));
    // nil is a reply, and kept.
    try testing.expect(try cached.get(&c, "missing") == null);
    try testing.expect(try cached.get(&c, "missing") == null);
    try testing.expectEqual(@as(u32, 4), fake.gets.load(.monotonic));
    // A struct from HGETALL, kept as one.
    const Profile = struct { name: []const u8, visits: u32 };
    _ = try cached.hgetAll(Profile, &c, "u");
    try testing.expectEqualStrings("Ada", (try cached.hgetAll(Profile, &c, "u")).name);

    client.cache.invalidate(.{ .tag = "values" });
    _ = try cached.get(&c, "k");
    try testing.expectEqual(@as(u32, 5), fake.gets.load(.monotonic));
    client.cache.invalidateQuery("GET", .{"k"});
    _ = try cached.get(&c, "k");
    try testing.expectEqual(@as(u32, 6), fake.gets.load(.monotonic));

    // Writes, `command`, pipelines and acquired connections never share.
    for (0..3) |_| _ = try cached.incr(&c, "n");
    try testing.expectEqual(@as(u32, 3), fake.incrs.load(.monotonic));
    _ = try cached.command(&c, .{ "GET", "k" });
    _ = try cached.pipeline(&c, .{.{ "GET", "k" }});
    var conn = try client.acquire(&c);
    _ = try conn.get(&c, "k");
    conn.release();
    _ = try client.get(&c, "k");
    try testing.expectEqual(@as(u32, 10), fake.gets.load(.monotonic));
}
