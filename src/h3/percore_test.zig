//! Per-core UDP sockets (Linux): connections spread over the endpoints, and
//! each is handled on its endpoint's executor alone, whether the kernel
//! steers its datagrams (the classic BPF program) or the endpoints pass
//! them on to each other (no program; a client that moved); the port is
//! probed before the group binds; a successor adopts the whole group.
//! Elsewhere one socket, whatever is asked.
const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");
const dusty = @import("dusty");
const anole_tls = @import("../tls/root.zig");
const client = @import("client.zig");
const server = @import("server.zig");
const Endpoint = server.Endpoint(void);
const steer = @import("steer.zig");

const executors = 4;

/// "<listener address> <thread id>": which endpoint served the request,
/// and on which thread.
fn where(req: *dusty.Request, res: *dusty.Response) !void {
    try res.print(.text, "{d} {d}", .{ @intFromPtr(req.listener), std.Thread.getCurrentId() });
}

const Fixture = struct {
    pem: anole_tls.Pem,
    http: *dusty.Server(void),
    ep: *Endpoint,
    future: std.Io.Future(anyerror!void),

    fn start(gpa: std.mem.Allocator, io: std.Io, fds: []const std.posix.fd_t, secret: ?[32]u8, pem_in: ?anole_tls.Pem) !Fixture {
        return startWith(gpa, io, fds, secret, pem_in, false);
    }

    fn startWith(gpa: std.mem.Allocator, io: std.Io, fds: []const std.posix.fd_t, secret: ?[32]u8, pem_in: ?anole_tls.Pem, early_data: bool) !Fixture {
        var pem = pem_in orelse try anole_tls.selfSigned(gpa, .{});
        errdefer pem.deinit(gpa);
        const http = try gpa.create(dusty.Server(void));
        errdefer gpa.destroy(http);
        http.* = .init(gpa, io, .{ .listeners = &.{} }, {});
        errdefer http.deinit();
        http.router.get("/where", where);
        const ep = try Endpoint.init(gpa, io, http, .{
            .address = .{ .ip4 = .loopback(0) },
            .cert_pem = pem.cert,
            .key_pem = pem.key,
            .sockets = executors,
            .fds = fds,
            .secret = secret,
            .early_data = early_data,
        });
        errdefer ep.deinit();
        const future = try io.concurrent(runEndpoint, .{ep});
        return .{ .pem = pem, .http = http, .ep = ep, .future = future };
    }

    fn runEndpoint(ep: *Endpoint) anyerror!void {
        try ep.run();
    }

    fn stop(f: *Fixture, gpa: std.mem.Allocator, io: std.Io) void {
        f.future.cancel(io) catch {};
        f.ep.deinit();
        f.http.deinit();
        gpa.destroy(f.http);
        f.pem.deinit(gpa);
    }

    fn connect(f: *Fixture, gpa: std.mem.Allocator, io: std.Io) !*client.ClientConnection {
        return client.ClientConnection.connect(gpa, io, .{
            .host = "localhost",
            .address = f.ep.address(),
            .port = f.ep.address().getPort(),
            .tls = .{ .ca = .{ .pem = f.pem.cert } },
        });
    }

    fn connectResuming(f: *Fixture, gpa: std.mem.Allocator, io: std.Io, cache: *client.SessionCache) !*client.ClientConnection {
        return client.ClientConnection.connect(gpa, io, .{
            .host = "localhost",
            .address = f.ep.address(),
            .port = f.ep.address().getPort(),
            .tls = .{ .ca = .{ .pem = f.pem.cert } },
            .session_cache = cache,
            .early_data = true,
        });
    }

    /// The endpoint that served GET /where on `conn`, checking that the
    /// request ran on that endpoint's thread.
    fn served(f: *Fixture, conn: *client.ClientConnection, gpa: std.mem.Allocator) !usize {
        const s = try conn.request(&.{
            .{ .name = ":method", .value = "GET" },   .{ .name = ":path", .value = "/where" },
            .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
        }, .{});
        defer s.release();
        try s.waitHead();
        try std.testing.expectEqual(@as(u16, 200), s.status);
        const body = try s.reader().allocRemaining(gpa, .unlimited);
        defer gpa.free(body);
        var parts = std.mem.splitScalar(u8, body, ' ');
        const listener = try std.fmt.parseInt(usize, parts.next().?, 10);
        const thread = try std.fmt.parseInt(u64, parts.next().?, 10);
        for (f.ep.endpoints(), 0..) |e, i| if (@intFromPtr(&e.listener) == listener) {
            try std.testing.expectEqual(@as(u64, @intCast(e.thread.?)), thread);
            return i;
        };
        return error.UnknownEndpoint;
    }

    fn sum(f: *Fixture, comptime field: []const u8) u64 {
        var n: u64 = 0;
        for (f.ep.endpoints()) |e| n += @field(e.stats, field).load(.monotonic);
        return n;
    }

    fn expectNoForeign(f: *Fixture) !void {
        try std.testing.expectEqual(@as(u64, 0), f.sum("foreign"));
    }
};

test "h3 per-core: connections spread over the endpoints and stay on their executors, steered by connection ID" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(executors) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io, &.{}, null, null);
    defer f.stop(gpa, io);
    try std.testing.expectEqual(@as(usize, executors), f.ep.endpoints().len);
    for (f.ep.endpoints(), 0..) |e, i| {
        try std.testing.expectEqual(@as(u8, @intCast(i)), e.index);
        try std.testing.expectEqual(f.ep.address().getPort(), e.address().getPort());
    }

    // Each its own client port, so the kernel's hash spreads first
    // Initials over the sockets; and then, by the program, every later
    // packet reaches the socket of the endpoint that took the connection.
    var conns: [24]*client.ClientConnection = undefined;
    var open: usize = 0;
    defer for (conns[0..open]) |conn| conn.close();
    var per_endpoint: [executors]usize = @splat(0);
    for (&conns) |*conn| {
        conn.* = try f.connect(gpa, io);
        open += 1;
        const first = try f.served(conn.*, gpa);
        per_endpoint[first] += 1;
        // The same endpoint each time.
        for (0..3) |_| try std.testing.expectEqual(first, try f.served(conn.*, gpa));
    }
    var used: usize = 0;
    for (per_endpoint) |n| used += @intFromBool(n > 0);
    try std.testing.expect(used >= 2);
    try std.testing.expectEqual(@as(u64, conns.len), f.sum("accepted"));
    for (f.ep.endpoints(), per_endpoint) |e, n| try std.testing.expectEqual(@as(u64, n), e.stats.accepted.load(.monotonic));
    // Steered by the kernel: nothing landed on the wrong socket.
    try std.testing.expectEqual(@as(u64, 0), f.sum("forwarded_out"));
    try std.testing.expectEqual(@as(u64, 0), f.sum("dropped"));
    try f.expectNoForeign();

    // Clients that move to new ports: the program reads the connection ID,
    // not the 4-tuple, so their packets still reach their endpoint.
    for (conns[0..8], 0..) |conn, k| {
        const before = try f.served(conn, gpa);
        try conn.rebind(if (k % 2 == 0) .migrate else .nat);
        try std.testing.expectEqual(before, try f.served(conn, gpa));
    }
    try std.testing.expectEqual(@as(u64, 0), f.sum("forwarded_out"));
    try f.expectNoForeign();
}

test "h3 per-core: WebTransport turned on after init reaches every endpoint; one 0-RTT context; 0-RTT on any endpoint" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(executors) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.startWith(gpa, io, &.{}, null, null, true);
    defer f.stop(gpa, io);
    // As `app.webtransport` does, after the listener is set up.
    f.ep.enableWebTransport();
    // Every endpoint speaks it, and ties tickets to the same context: a
    // client resumes on whichever endpoint the kernel picks.
    var first_buf: [server.early_context_max]u8 = undefined;
    const first = try server.earlyDataContextOf(&f.ep.endpoints()[0].options, &first_buf);
    for (f.ep.endpoints()) |e| {
        try std.testing.expect(e.options.webtransport);
        var buf: [server.early_context_max]u8 = undefined;
        try std.testing.expectEqualSlices(u8, first, try server.earlyDataContextOf(&e.options, &buf));
    }

    var cache: client.SessionCache = .init(gpa, io);
    defer cache.deinit();
    // A full handshake and a ticket from one endpoint...
    const issuer = blk: {
        const conn = try f.connectResuming(gpa, io, &cache);
        defer conn.close();
        const e = try f.served(conn, gpa);
        try waitTicket(io, &cache);
        break :blk e;
    };
    // ...and 0-RTT, each time with the newest ticket, on new client ports
    // until one lands on another endpoint.
    var elsewhere = false;
    for (0..32) |_| {
        const conn = try f.connectResuming(gpa, io, &cache);
        defer conn.close();
        const e = try f.served(conn, gpa);
        try std.testing.expect(conn.resumed());
        try std.testing.expectEqual(client.EarlyData.accepted, conn.earlyData());
        try waitTicket(io, &cache);
        if (e != issuer) {
            elsewhere = true;
            break;
        }
    }
    try std.testing.expect(elsewhere);
}

fn waitTicket(io: std.Io, cache: *client.SessionCache) !void {
    for (0..200) |_| {
        if (cache.count() > 0) return;
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.NoTicket;
}

test "h3 per-core: without the program, packets that land on another endpoint's socket are passed on to it" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(executors) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io, &.{}, null, null);
    defer f.stop(gpa, io);
    // The kernel's 4-tuple hash from now on: a client that moves lands on
    // some socket by chance.
    try steer.detach(f.ep.endpoints()[0].udp.socket.handle);

    var conns: [8]*client.ClientConnection = undefined;
    var open: usize = 0;
    defer for (conns[0..open]) |conn| conn.close();
    for (&conns) |*conn| {
        conn.* = try f.connect(gpa, io);
        open += 1;
    }
    // Moves until some packet landed on another socket than its
    // connection's (each move does with probability 3/4).
    var moves: usize = 0;
    while (f.sum("forwarded_out") == 0) : (moves += 1) {
        if (moves == 64) return error.NeverMisdelivered;
        const conn = conns[moves % conns.len];
        const before = try f.served(conn, gpa);
        try conn.rebind(if (moves % 2 == 0) .nat else .migrate);
        try std.testing.expectEqual(before, try f.served(conn, gpa));
    }
    // And every connection still answers, from its own endpoint's thread.
    for (conns) |conn| _ = try f.served(conn, gpa);
    try std.testing.expectEqual(f.sum("forwarded_out"), f.sum("forwarded_in"));
    try std.testing.expectEqual(@as(u64, 0), f.sum("dropped"));
    try f.expectNoForeign();
}

test "h3 per-core: the port is probed before the group binds, and a successor adopts the whole group" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(executors) });
    defer rt.deinit();
    const io = rt.io();
    var old = try Fixture.start(gpa, io, &.{}, null, null);
    var old_stopped = false;
    defer if (!old_stopped) old.stop(gpa, io);

    // A second server on the port: refused, not silently in the group.
    {
        var pem = try anole_tls.selfSigned(gpa, .{});
        defer pem.deinit(gpa);
        try std.testing.expectError(error.AddressInUse, Endpoint.init(gpa, io, old.http, .{
            .address = old.ep.address(),
            .cert_pem = pem.cert,
            .key_pem = pem.key,
            .sockets = executors,
        }));
    }

    const conn = try old.connect(gpa, io);
    defer conn.close();
    _ = try old.served(conn, gpa);

    // The successor: every socket (duplicates, as a new process inherits
    // them), in order, with the secret and the certificate.
    var fds: [executors]std.posix.fd_t = undefined;
    for (old.ep.endpoints(), &fds) |e, *fd| {
        fd.* = std.c.dup(e.udp.socket.handle);
        try std.testing.expect(fd.* >= 0);
    }
    const pem_copy: anole_tls.Pem = .{ .cert = try gpa.dupe(u8, old.pem.cert), .key = try gpa.dupe(u8, old.pem.key) };
    var new = try Fixture.start(gpa, io, &fds, old.ep.secret, pem_copy);
    defer new.stop(gpa, io);
    try std.testing.expectEqual(@as(usize, executors), new.ep.endpoints().len);
    try std.testing.expectEqual(old.ep.address().getPort(), new.ep.address().getPort());

    old.ep.handOver();
    old.stop(gpa, io);
    old_stopped = true;
    // The group is the successor's alone now, steered as before.
    var per_endpoint: [executors]usize = @splat(0);
    for (0..16) |_| {
        const c2 = try new.connect(gpa, io);
        defer c2.close();
        const first = try new.served(c2, gpa);
        per_endpoint[first] += 1;
        try std.testing.expectEqual(first, try new.served(c2, gpa));
    }
    var used: usize = 0;
    for (per_endpoint) |n| used += @intFromBool(n > 0);
    try std.testing.expect(used >= 2);
    try std.testing.expectEqual(@as(u64, 0), new.sum("forwarded_out"));
    try new.expectNoForeign();
}

test "h3 per-core: one socket where SO_REUSEPORT does not spread datagrams (not Linux)" {
    if (builtin.os.tag == .linux) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io, &.{}, null, null);
    defer f.stop(gpa, io);
    try std.testing.expectEqual(@as(usize, 1), f.ep.endpoints().len);
    const conn = try f.connect(gpa, io);
    defer conn.close();
    try std.testing.expectEqual(@as(usize, 0), try f.served(conn, gpa));
    try f.expectNoForeign();
}
