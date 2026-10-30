//! Raw UDP servers over loopback (design-net.md §8.4). Deterministic: waits
//! are on datagrams arriving or counters; nothing asserts a latency.
const std = @import("std");
const wait = @import("anole_test_wait");
const safety = @import("anole_safety");
const builtin = @import("builtin");
const server_mod = @import("../server.zig");
const net = @import("root.zig");
const udp_service = @import("udp_service.zig");

const App = server_mod.App;
/// The App's allocator panics at an allocation under a spin lock (SAFETY.md
/// L5, E1): std's test allocator can't be intercepted, so it is wrapped.
var checked: safety.SpinCheckedAllocator = .init(std.testing.allocator);
const alloc = checked.allocator();

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
    defer checking.cancel(app.io()) catch {};
    try app.run();
    try checking.await(app.io());
}

const Pong = struct {
    pub fn datagram(d: *net.Datagram) !void {
        try d.reply(d.data);
    }
};

test "net udp: twenty datagrams are each echoed and counted in and out" {
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
            // A batch's replies are counted once their send returns, which
            // can be after they arrived here: wait for the count (10 s at
            // most), don't read it once.
            try wait.waitUntil(io, "the twenty replies counted", a, struct {
                fn counted(server: *App) bool {
                    return server.netStats().datagrams_out >= 20;
                }
            }.counted);
            const st = a.netStats();
            try std.testing.expectEqual(@as(u64, 20), st.datagrams_in);
            try std.testing.expectEqual(@as(u64, 20), st.datagrams_out);
        }
    }.run);
}

test "net udp: a UDP-only app binds no TCP listener" {
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    try app.udp("127.0.0.1:0", Pong, .{});
    try serveWith(&app, struct {
        fn run(a: *App) !void {
            // The core's 127.0.0.1:8080 default used to be bound beside it.
            try std.testing.expectEqual(@as(usize, 0), a.addresses().len);
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
            try wait.waitAtLeast(io, "the small datagram was handled", &Counting.seen, 1);
            // The small one was handled; the big one, sent before it, never
            // was (one socket reads in order: it was dropped first).
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
            try wait.waitAtLeast(io, "the idle session ended", &Game.closed, 1);
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

test "net udp: a send racing the stop is refused, not accepted and lost" {
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    try app.udp("127.0.0.1:0", Pong, .{});
    var hold: udp_service.TestHold = .{};
    // 0: not returned yet; 1: accepted; 2: Closed; 3: another error.
    var result: std.atomic.Value(u8) = .init(0);
    var thread: ?std.Thread = null;
    defer if (thread) |t| {
        hold.release.store(true, .release);
        t.join();
    };
    const Sender = struct {
        fn run(s: *net.UdpSocket, out: *std.atomic.Value(u8)) void {
            const to: std.Io.net.IpAddress = .{ .ip4 = .loopback(9) };
            if (s.send(to, null, "late")) |_| out.store(1, .release) else |err| out.store(if (err == error.Closed) 2 else 3, .release);
        }
    };
    const Ctl = struct {
        fn run(a: *App, h: *udp_service.TestHold, th: *?std.Thread, out: *std.atomic.Value(u8)) !void {
            defer a.stop();
            try a.waitReady();
            udp_service.test_send_hold.store(h, .release);
            th.* = try std.Thread.spawn(.{}, Sender.run, .{ a.udpSocket("udp-0").?, out });
            try wait.waitFlag(a.io(), "the send is held where the stop can race it", &h.held);
        }
    };
    var ctl = try app.io().concurrent(Ctl.run, .{ &app, &hold, &thread, &result });
    defer ctl.cancel(app.io()) catch {};
    // Returns once the stop has ended the readers and senders.
    try app.run();
    try ctl.await(app.io());
    hold.release.store(true, .release);
    thread.?.join();
    thread = null;
    try std.testing.expectEqual(@as(u8, 2), result.load(.acquire));
}

test "net udp: TLS, a Unix socket or PROXY protocol on a UDP listener make run() fail with a named error" {
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
        var handled: std.atomic.Value(u32) = .init(0);
        pub fn datagram(d: *net.Datagram) !void {
            defer _ = handled.fetchAdd(1, .release);
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
            try wait.waitAtLeast(io, "every datagram handled", &Probe.handled, 80);
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

/// `[stress]`: application threads sending while the server stops.
const StopStorm = struct {
    const threads = 8;
    var ok: std.atomic.Value(u64) = .init(0);
    var full: std.atomic.Value(u64) = .init(0);
    var closed: std.atomic.Value(u64) = .init(0);
    var other: std.atomic.Value(u64) = .init(0);

    fn reset() void {
        ok.store(0, .monotonic);
        full.store(0, .monotonic);
        closed.store(0, .monotonic);
        other.store(0, .monotonic);
    }

    /// Sends until the socket answers Closed (the stop).
    fn sender(s: *net.UdpSocket, to: std.Io.net.IpAddress, seed: u64) void {
        var prng: std.Random.DefaultPrng = .init(seed);
        const payload: [1200]u8 = @splat('u');
        while (true) {
            const n = 1 + prng.random().uintLessThan(usize, payload.len);
            if (s.send(to, null, payload[0..n])) |_| {
                _ = ok.fetchAdd(1, .monotonic);
            } else |err| switch (err) {
                error.QueueFull => _ = full.fetchAdd(1, .monotonic),
                error.Closed => {
                    _ = closed.fetchAdd(1, .monotonic);
                    return;
                },
                else => {
                    _ = other.fetchAdd(1, .monotonic);
                    return;
                },
            }
        }
    }

    const Ctl = struct {
        fn run(a: *App, seed: u64, th: *[threads]std.Thread, started: *usize, to: std.Io.net.IpAddress) !void {
            defer a.stop();
            try a.waitReady();
            const sock = a.udpSocket("udp-0").?;
            for (th, 0..) |*t, k| {
                t.* = try std.Thread.spawn(.{}, sender, .{ sock, to, seed +% k });
                started.* += 1;
            }
            // Under way: the stop lands among the sends.
            try wait.waitAtLeast(a.io(), "sends taken", &ok, 2_000);
        }
    };
};

test "net udp: [stress] sends from eight threads racing the stop" {
    try wait.requireStress();
    for (0..20) |round| {
        StopStorm.reset();
        var app = try App.init(alloc, .{ .executors = .exact(2) });
        defer app.deinit();
        try app.udp("127.0.0.1:0", Counting, .{ .send_queue = 64 * 1024 });
        const io = app.io();
        const c = try client(io);
        defer c.close(io);
        var th: [StopStorm.threads]std.Thread = undefined;
        var started: usize = 0;
        defer for (th[0..started]) |t| t.join();
        var ctl = try io.concurrent(StopStorm.Ctl.run, .{ &app, 0x0d90_0000 + round * 16, &th, &started, c.address });
        defer ctl.cancel(io) catch {};
        try app.run();
        try ctl.await(io);
        for (th[0..started]) |t| t.join();
        started = 0;
        // Every send was either taken and sent (counted out), refused as
        // full (counted dropped) or refused as Closed; none taken and lost.
        const st = app.netStats();
        try std.testing.expectEqual(@as(u64, 0), StopStorm.other.load(.acquire));
        try std.testing.expectEqual(@as(u64, StopStorm.threads), StopStorm.closed.load(.acquire));
        try std.testing.expectEqual(StopStorm.ok.load(.acquire), st.datagrams_out);
        try std.testing.expectEqual(StopStorm.full.load(.acquire), st.datagrams_dropped);
    }
}

/// A send from a thread finds the queue full (another send's bytes are
/// reserved there); before it asks for WRITABLE (held) that other send goes
/// out and the queue drains. It must not be left waiting for a WRITABLE
/// nothing will send. Through a table of its own: WRITABLE is the C ABI's
/// callback.
const FullRace = struct {
    var writables: std.atomic.Value(u32) = .init(0);
    fn datagram(_: ?*anyopaque, _: *net.Datagram) anyerror!void {}
    fn writable(_: ?*anyopaque, _: *net.UdpSocket) void {
        _ = writables.fetchAdd(1, .release);
    }
    const table: net.UdpTable = .{ .datagram = datagram, .writable = writable };
    const cap = 4096;

    // 0: not returned yet; 1: taken; 2: QueueFull; 3: another error.
    fn send(s: *net.UdpSocket, to: std.Io.net.IpAddress, len: usize, out: *std.atomic.Value(u8)) void {
        const bytes: [cap]u8 = @splat('u');
        if (s.send(to, null, bytes[0..len])) |_| out.store(1, .release) else |err| out.store(if (err == error.QueueFull) 2 else 3, .release);
    }
};

test "net udp: a send refused as full while the queue drains gets WRITABLE or is taken" {
    FullRace.writables.store(0, .monotonic);
    var app = try App.init(alloc, .{ .executors = .exact(1), .listeners = &.{.{
        .address = "127.0.0.1",
        .port = 0,
        .udp = .{ .table = &FullRace.table, .options = .{ .send_queue = FullRace.cap }, .ctx_type = "void" },
    }} });
    defer app.deinit();
    var first: udp_service.TestHold = .{};
    var full: udp_service.TestHold = .{};
    var r1: std.atomic.Value(u8) = .init(0);
    var r2: std.atomic.Value(u8) = .init(0);
    var threads: [2]?std.Thread = .{ null, null };
    defer {
        first.release.store(true, .release);
        full.release.store(true, .release);
        for (threads) |t| if (t) |th| th.join();
        udp_service.test_send_hold.store(null, .release);
        udp_service.test_full_hold.store(null, .release);
    }
    const Ctl = struct {
        fn run(a: *App, h1: *udp_service.TestHold, h2: *udp_service.TestHold, out1: *std.atomic.Value(u8), out2: *std.atomic.Value(u8), th: *[2]?std.Thread) !void {
            defer a.stop();
            try a.waitReady();
            const sock = &a.net_udp.items[0].sockets[0];
            const peer = try client(a.io());
            defer peer.close(a.io());
            const to = peer.address;
            // Half the queue, reserved and held before it is pushed.
            udp_service.test_send_hold.store(h1, .release);
            th[0] = try std.Thread.spawn(.{}, FullRace.send, .{ sock, to, FullRace.cap / 2, out1 });
            try wait.waitFlag(a.io(), "the first send is held with its bytes reserved", &h1.held);
            // More than the rest: full, held before it asks for WRITABLE.
            udp_service.test_full_hold.store(h2, .release);
            th[1] = try std.Thread.spawn(.{}, FullRace.send, .{ sock, to, FullRace.cap / 2 + 1000, out2 });
            try wait.waitFlag(a.io(), "the second send is held at the full queue", &h2.held);
            // The first goes out: the queue drains to empty.
            h1.release.store(true, .release);
            th[0].?.join();
            th[0] = null;
            try std.testing.expectEqual(@as(u8, 1), out1.load(.acquire));
            try wait.waitUntil(a.io(), "the queue is empty", sock, struct {
                fn empty(x: *net.UdpSocket) bool {
                    return x.queue_bytes.load(.acquire) == 0;
                }
            }.empty);
            const before = FullRace.writables.load(.acquire);
            h2.release.store(true, .release);
            th[1].?.join();
            th[1] = null;
            switch (out2.load(.acquire)) {
                1 => {},
                2 => try wait.waitAtLeast(a.io(), "WRITABLE after the refused send", &FullRace.writables, before + 1),
                else => return error.TestUnexpectedResult,
            }
        }
    };
    var ctl = try app.io().concurrent(Ctl.run, .{ &app, &first, &full, &r1, &r2, &threads });
    defer ctl.cancel(app.io()) catch {};
    try app.run();
    try ctl.await(app.io());
}

test "net udp: datagrams over send_queue together answer TooLarge, not QueueFull" {
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    try app.udp("127.0.0.1:0", Pong, .{ .send_queue = 4096 });
    try serveWith(&app, struct {
        fn run(a: *App) !void {
            const sock = a.udpSocket("udp-0").?;
            const peer = try client(a.io());
            defer peer.close(a.io());
            const bytes: [3000]u8 = @splat('t');
            const two: [2]net.UdpSocket.Outgoing = .{ .{ .to = peer.address, .from = null, .bytes = &bytes }, .{ .to = peer.address, .from = null, .bytes = &bytes } };
            try std.testing.expectError(error.TooLarge, sock.sendMany(&two));
            const one: [5000]u8 = @splat('t');
            try std.testing.expectError(error.TooLarge, sock.send(peer.address, null, &one));
            // One that fits is taken.
            try sock.sendMany(two[0..1]);
        }
    }.run);
}
