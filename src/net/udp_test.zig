//! Raw UDP servers over loopback (design-net.md §8.4). Deterministic: waits
//! are on datagrams arriving or counters; nothing asserts a latency.
const std = @import("std");
const builtin = @import("builtin");
const server_mod = @import("../server.zig");
const net = @import("root.zig");

const App = server_mod.App;
const alloc = std.testing.allocator;

fn portOf(a: *App) u16 {
    return a.udpSocket("udp-0").?.address().getPort();
}

fn client(io: std.Io) !std.Io.net.Socket {
    const lo: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    return lo.bind(io, .{ .mode = .dgram, .protocol = .udp });
}

fn expectDatagram(io: std.Io, c: std.Io.net.Socket, want: []const u8) !void {
    var buf: [2048]u8 = undefined;
    const msg = try c.receiveTimeout(io, &buf, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
    try std.testing.expectEqualStrings(want, msg.data);
}

fn waitReadyUdp(a: *App) !void {
    try a.waitReady();
}

fn serveWith(app: *App, comptime check: fn (*App) anyerror!void) !void {
    const Run = struct {
        fn run(a: *App) !void {
            defer a.stop();
            try a.waitReady();
            try check(a);
        }
    };
    var checking = try app.io().concurrent(Run.run, .{app});
    try app.run();
    try checking.await(app.io());
}

const Pong = struct {
    pub fn datagram(d: *net.Datagram) !void {
        try d.reply(d.data);
    }
};

test "net udp: echo, the replies of a batch go out together" {
    var app = try App.init(alloc, .{ .executors = .exact(2) });
    defer app.deinit();
    try app.udp("127.0.0.1:0", Pong, .{});
    try serveWith(&app, struct {
        fn run(a: *App) !void {
            const io = a.io();
            const c = try client(io);
            defer c.close(io);
            var to: std.Io.net.IpAddress = .{ .ip4 = .loopback(portOf(a)) };
            to.setPort(portOf(a));
            // Twenty at once.
            for (0..20) |i| {
                var b: [16]u8 = undefined;
                const text = try std.fmt.bufPrint(&b, "ping {d}", .{i});
                try c.send(io, &to, text);
            }
            var seen: [20]bool = @splat(false);
            for (0..20) |_| {
                var buf: [64]u8 = undefined;
                const msg = try c.receiveTimeout(io, &buf, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
                const n = try std.fmt.parseInt(usize, msg.data["ping ".len..], 10);
                seen[n] = true;
            }
            for (seen) |s| try std.testing.expect(s);
            const st = a.netStats();
            try std.testing.expectEqual(@as(u64, 20), st.datagrams_in);
            try std.testing.expectEqual(@as(u64, 20), st.datagrams_out);
        }
    }.run);
}

const Counting = struct {
    var seen: std.atomic.Value(u32) = .init(0);
    pub fn datagram(_: *net.Datagram) !void {
        _ = seen.fetchAdd(1, .release);
    }
};

test "net udp: a datagram over max_datagram is dropped and counted" {
    Counting.seen.store(0, .monotonic);
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    try app.udp("127.0.0.1:0", Counting, .{ .max_datagram = 100 });
    try serveWith(&app, struct {
        fn run(a: *App) !void {
            const io = a.io();
            const c = try client(io);
            defer c.close(io);
            var to: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
            to.setPort(portOf(a));
            const big: [200]u8 = @splat('x');
            try c.send(io, &to, &big);
            try c.send(io, &to, "small");
            while (Counting.seen.load(.acquire) < 1) try io.sleep(.fromMilliseconds(1), .awake);
            // The small one was handled; the big one never was.
            try io.sleep(.fromMilliseconds(20), .awake);
            try std.testing.expectEqual(@as(u32, 1), Counting.seen.load(.acquire));
            try std.testing.expectEqual(@as(u64, 1), a.netStats().datagrams_dropped);
        }
    }.run);
}

const Game = struct {
    pub const State = struct { seq: u32 = 0 };
    var opened: std.atomic.Value(u32) = .init(0);
    var closed: std.atomic.Value(u32) = .init(0);
    var close_reason: std.atomic.Value(u32) = .init(99);

    pub fn open(_: *net.Session) !void {
        _ = opened.fetchAdd(1, .release);
    }
    pub fn datagram(s: *net.Session, d: *net.Datagram) !void {
        const st = s.contextAs(State);
        st.seq += 1;
        var b: [32]u8 = undefined;
        try d.reply(try std.fmt.bufPrint(&b, "{s}#{d}", .{ d.data, st.seq }));
    }
    pub fn close(s: *net.Session) void {
        close_reason.store(@backingInt(s.endReason()), .release);
        _ = closed.fetchAdd(1, .release);
    }
};

test "net udp: sessions open, carry state, and close on idle" {
    Game.opened.store(0, .monotonic);
    Game.closed.store(0, .monotonic);
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    try app.udp("127.0.0.1:0", Game, .{ .sessions = .{ .idle_timeout = .fromMilliseconds(50) } });
    try serveWith(&app, struct {
        fn run(a: *App) !void {
            const io = a.io();
            const c = try client(io);
            defer c.close(io);
            var to: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
            to.setPort(portOf(a));
            try c.send(io, &to, "m");
            try expectDatagram(io, c, "m#1");
            try c.send(io, &to, "m");
            try expectDatagram(io, c, "m#2");
            try std.testing.expectEqual(@as(u32, 1), Game.opened.load(.acquire));
            // Silent: the session ends by idle (waits for the event).
            while (Game.closed.load(.acquire) < 1) try io.sleep(.fromMilliseconds(5), .awake);
            try std.testing.expectEqual(@backingInt(net.Session.EndReason.idle), Game.close_reason.load(.acquire));
            // A new datagram opens a new session, with fresh state.
            try c.send(io, &to, "m");
            try expectDatagram(io, c, "m#1");
            try std.testing.expectEqual(@as(u32, 2), Game.opened.load(.acquire));
        }
    }.run);
}

test "net udp: send from another thread" {
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    try app.udp("127.0.0.1:0", Pong, .{});
    try serveWith(&app, struct {
        fn run(a: *App) !void {
            const io = a.io();
            const c = try client(io);
            defer c.close(io);
            const target = c.address;
            const sock = a.udpSocket("udp-0").?;
            const T = struct {
                fn go(s: *net.UdpSocket, to: std.Io.net.IpAddress) void {
                    s.send(to, null, "from a thread") catch {};
                }
            };
            var th = try std.Thread.spawn(.{}, T.go, .{ sock, target });
            th.join();
            try expectDatagram(io, c, "from a thread");
        }
    }.run);
}

test "net udp: options refused" {
    const expected_log = @import("../errors.zig").expectLog();
    defer expected_log.deinit();
    {
        var app = try App.init(alloc, .{ .executors = .exact(1), .listeners = &.{.{ .port = 0, .tls = .{ .cert = .dev_self_signed }, .udp = net.udp(void, Pong, .{}) }} });
        defer app.deinit();
        try std.testing.expectError(error.UdpWithTls, app.run());
    }
    {
        var app = try App.init(alloc, .{ .executors = .exact(1), .listeners = &.{.{ .unix = "/tmp/anole-udp-test.sock", .udp = net.udp(void, Pong, .{}) }} });
        defer app.deinit();
        try std.testing.expectError(error.UdpOnUnixSocket, app.run());
    }
    {
        var app = try App.init(alloc, .{ .executors = .exact(1), .listeners = &.{.{ .port = 0, .proxy_protocol = true, .udp = net.udp(void, Pong, .{}) }} });
        defer app.deinit();
        try std.testing.expectError(error.UdpWithProxyProtocol, app.run());
    }
}

test "net udp: per-core sockets keep a peer on one socket" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const Probe = struct {
        var by_peer: [8]std.atomic.Value(u32) = @splat(.init(0xff));
        var bad: std.atomic.Value(u32) = .init(0);
        pub fn datagram(d: *net.Datagram) !void {
            const peer: usize = d.data[0] - '0';
            const idx = d.socket.index;
            const prev = by_peer[peer].cmpxchgStrong(0xff, idx, .acq_rel, .acquire);
            if (prev) |p| if (p != idx) {
                _ = bad.fetchAdd(1, .monotonic);
            };
        }
    };
    var app = try App.init(alloc, .{ .executors = .exact(4) });
    defer app.deinit();
    try app.udp("127.0.0.1:0", Probe, .{ .sockets = 4 });
    try serveWith(&app, struct {
        fn run(a: *App) !void {
            const io = a.io();
            var to: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
            to.setPort(portOf(a));
            var clients: [8]std.Io.net.Socket = undefined;
            for (&clients) |*c| c.* = try client(io);
            defer for (clients) |c| c.close(io);
            for (0..10) |_| for (clients, 0..) |c, i| try c.send(io, &to, &.{@as(u8, '0') + @as(u8, @intCast(i))});
            try io.sleep(.fromMilliseconds(100), .awake);
            try std.testing.expectEqual(@as(u32, 0), Probe.bad.load(.acquire));
        }
    }.run);
}

test "net udp: a dual-stack listener answers an IPv4 peer (replies leave in mapped form)" {
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    try app.udp(":0", Pong, .{});
    try serveWith(&app, struct {
        fn run(a: *App) !void {
            const io = a.io();
            const c = try client(io);
            defer c.close(io);
            const to: std.Io.net.IpAddress = .{ .ip4 = .loopback(portOf(a)) };
            try c.send(io, &to, "v4");
            try expectDatagram(io, c, "v4");
            // From another thread too.
            const sock = a.udpSocket("udp-0").?;
            try sock.send(c.address, null, "queued");
            try expectDatagram(io, c, "queued");
        }
    }.run);
}
