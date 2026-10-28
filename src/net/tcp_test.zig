//! Raw TCP servers over loopback (design-net.md §8.3). Deterministic: every
//! wait is on bytes arriving, an event or a counter; nothing asserts a
//! latency or a short timing window.
const std = @import("std");
const wait = @import("anole_test_wait");
const features = @import("build_options");
const server_mod = @import("../server.zig");
const net = @import("root.zig");
const ClientStream = net.ClientStream;

const App = server_mod.App;
const alloc = std.testing.allocator;

fn connect(a: *App, port_of: u16) !*ClientStream {
    return ClientStream.connect(alloc, a.io(), .{ .host = "127.0.0.1", .port = port_of, .address = .{ .ip4 = .loopback(port_of) } });
}

fn portOf(a: *App) u16 {
    return a.addresses()[0].ip.getPort();
}

/// Reads exactly `want.len` bytes and compares.
fn expectRead(s: *ClientStream, want: []const u8) !void {
    const got = try s.reader().take(want.len);
    try std.testing.expectEqualStrings(want, got);
}

/// Ends the sending side only: the peer reads EOF, this side still reads.
fn halfClose(s: *ClientStream) void {
    s.socket.shutdown(s.io, .send) catch {};
}

/// Reads until the stream ends.
fn expectEnd(s: *ClientStream) !void {
    var buf: [64]u8 = undefined;
    while (true) {
        const n = s.reader().readSliceShort(&buf) catch return;
        if (n == 0) return;
    }
}

/// Runs `check` on a task while the app serves; the app stops when it ends.
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

const Echo = struct {
    var opened: std.atomic.Value(u32) = .init(0);
    var closed: std.atomic.Value(u32) = .init(0);
    var last_reason: std.atomic.Value(u32) = .init(99);

    pub fn open(_: *net.Conn) !void {
        _ = opened.fetchAdd(1, .monotonic);
    }
    pub fn data(conn: *net.Conn, bytes: []const u8) !void {
        _ = try conn.send(bytes);
    }
    pub fn close(_: *net.Conn, reason: net.CloseReason) void {
        last_reason.store(@backingInt(reason), .release);
        _ = closed.fetchAdd(1, .release);
    }
};

/// Waits (yielding to the runtime, which may have one executor) until
/// `counter` reaches `value`.
fn waitFor(io: std.Io, counter: *std.atomic.Value(u32), value: u32) !void {
    try wait.waitAtLeast(io, "the callback counter reached its count", counter, value);
}

test "net tcp: callbacks echo; open, data, close in order, close reason peer" {
    Echo.opened.store(0, .monotonic);
    Echo.closed.store(0, .monotonic);
    var app = try App.init(alloc, .{ .executors = .exact(2) });
    defer app.deinit();
    try app.tcp("127.0.0.1:0", Echo, .{});
    try serveWith(&app, struct {
        fn run(a: *App) !void {
            const s = try connect(a, portOf(a));
            defer s.close();
            try s.writer().writeAll("hello");
            try s.writer().flush();
            try expectRead(s, "hello");
            try s.writer().writeAll(" again");
            try s.writer().flush();
            try expectRead(s, " again");
            halfClose(s);
            try expectEnd(s);
            try waitFor(a.io(), &Echo.closed, 1);
            try std.testing.expectEqual(@as(u32, 1), Echo.opened.load(.acquire));
            try std.testing.expectEqual(@backingInt(net.CloseReason.peer), Echo.last_reason.load(.acquire));
        }
    }.run);
}

const Lines = struct {
    pub const State = struct { count: u32 = 0 };
    var states_dropped: std.atomic.Value(u32) = .init(0);

    pub fn message(conn: *net.Conn, line: []const u8) !void {
        const st = conn.contextAs(State);
        st.count += 1;
        if (std.mem.eql(u8, line, "QUIT")) return conn.close();
        var buf: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{d}:{s}", .{ st.count, line });
        _ = try conn.sendFrame(text);
    }
    pub fn close(_: *net.Conn, _: net.CloseReason) void {
        _ = states_dropped.fetchAdd(1, .release);
    }
};

test "net tcp: lines framing, per-connection State, close() ends with EOF" {
    Lines.states_dropped.store(0, .monotonic);
    var app = try App.init(alloc, .{ .executors = .exact(2) });
    defer app.deinit();
    try app.tcp("127.0.0.1:0", Lines, .{ .framing = .{ .lines = .{} } });
    try serveWith(&app, struct {
        fn run(a: *App) !void {
            const s1 = try connect(a, portOf(a));
            defer s1.close();
            const s2 = try connect(a, portOf(a));
            defer s2.close();
            // Split in the middle of a line, and two lines in one write.
            try s1.writer().writeAll("a\nb");
            try s1.writer().flush();
            try expectRead(s1, "1:a\n");
            try s1.writer().writeAll("\nc\r\n");
            try s1.writer().flush();
            try expectRead(s1, "2:b\n3:c\n");
            // The second connection counts on its own.
            try s2.writer().writeAll("x\n");
            try s2.writer().flush();
            try expectRead(s2, "1:x\n");
            try s1.writer().writeAll("QUIT\n");
            try s1.writer().flush();
            try expectEnd(s1);
            try waitFor(a.io(), &Lines.states_dropped, 1);
        }
    }.run);
}

fn taskEcho(conn: *net.Conn) !void {
    while (try conn.readFrame()) |line| {
        if (std.mem.eql(u8, line, "QUIT")) return;
        try conn.writeFrame(line);
    }
}

test "net tcp: the task form with lines framing; returning closes" {
    var app = try App.init(alloc, .{ .executors = .exact(2) });
    defer app.deinit();
    try app.tcp("127.0.0.1:0", taskEcho, .{ .framing = .{ .lines = .{} } });
    try serveWith(&app, struct {
        fn run(a: *App) !void {
            const s = try connect(a, portOf(a));
            defer s.close();
            try s.writer().writeAll("one\ntwo\n");
            try s.writer().flush();
            try expectRead(s, "one\ntwo\n");
            try s.writer().writeAll("QUIT\n");
            try s.writer().flush();
            try expectEnd(s);
        }
    }.run);
}

const Length = struct {
    pub fn message(conn: *net.Conn, frame: []const u8) !void {
        _ = try conn.sendFrame(frame);
    }
};

test "net tcp: length-prefixed frames come whole and go back framed" {
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    try app.tcp("127.0.0.1:0", Length, .{ .framing = .{ .length = .{ .bytes = 2 } } });
    try serveWith(&app, struct {
        fn run(a: *App) !void {
            const s = try connect(a, portOf(a));
            defer s.close();
            // Two frames, the second cut in the middle.
            try s.writer().writeAll("\x00\x03abc\x00\x04de");
            try s.writer().flush();
            try expectRead(s, "\x00\x03abc");
            try s.writer().writeAll("fg");
            try s.writer().flush();
            try expectRead(s, "\x00\x04defg");
        }
    }.run);
}

const Half = struct {
    pub fn data(_: *net.Conn, _: []const u8) !void {}
    pub fn end(conn: *net.Conn) !void {
        _ = try conn.send("bye");
        conn.end();
    }
};

test "net tcp: half_open lets the handler answer after the peer's FIN" {
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    try app.tcp("127.0.0.1:0", Half, .{ .half_open = true });
    try serveWith(&app, struct {
        fn run(a: *App) !void {
            const s = try connect(a, portOf(a));
            defer s.close();
            halfClose(s);
            try expectRead(s, "bye");
            try expectEnd(s);
        }
    }.run);
}

const Reply = struct {
    pub fn data(conn: *net.Conn, _: []const u8) !void {
        _ = try conn.send("reply");
    }
};

test "net tcp: without half_open the reply still arrives after the request and a shutdown" {
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    try app.tcp("127.0.0.1:0", Reply, .{});
    try serveWith(&app, struct {
        fn run(a: *App) !void {
            const s = try connect(a, portOf(a));
            defer s.close();
            try s.writer().writeAll("req");
            try s.writer().flush();
            halfClose(s);
            try expectRead(s, "reply");
            try expectEnd(s);
        }
    }.run);
}

const Resetter = struct {
    var reason: std.atomic.Value(u32) = .init(99);
    var closed: std.atomic.Value(u32) = .init(0);
    pub fn data(conn: *net.Conn, _: []const u8) !void {
        conn.reset();
    }
    pub fn close(_: *net.Conn, r: net.CloseReason) void {
        reason.store(@backingInt(r), .release);
        _ = closed.fetchAdd(1, .release);
    }
};

test "net tcp: reset() resets the peer; reason local" {
    Resetter.closed.store(0, .monotonic);
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    try app.tcp("127.0.0.1:0", Resetter, .{});
    try serveWith(&app, struct {
        fn run(a: *App) !void {
            const s = try connect(a, portOf(a));
            defer s.close();
            try s.writer().writeAll("x");
            try s.writer().flush();
            var buf: [8]u8 = undefined;
            // A reset or an end: either way no byte comes.
            const n = s.reader().readSliceShort(&buf) catch 0;
            try std.testing.expectEqual(@as(usize, 0), n);
            try waitFor(a.io(), &Resetter.closed, 1);
            try std.testing.expectEqual(@backingInt(net.CloseReason.local), Resetter.reason.load(.acquire));
        }
    }.run);
}

const Burst = struct {
    var busy_seen: std.atomic.Value(u32) = .init(0);
    var writable_seen: std.atomic.Value(u32) = .init(0);
    var full_seen: std.atomic.Value(u32) = .init(0);

    pub fn data(conn: *net.Conn, _: []const u8) !void {
        const chunk: [4096]u8 = @splat('x');
        // Past the high-water mark a send says busy, past the maximum it
        // takes nothing.
        while (true) {
            const r = conn.send(&chunk) catch |err| switch (err) {
                error.QueueFull => {
                    full_seen.store(1, .release);
                    return;
                },
                else => return err,
            };
            if (r == .busy) busy_seen.store(1, .release);
        }
    }
    pub fn writable(_: *net.Conn) !void {
        writable_seen.store(1, .release);
    }
};

test "net tcp: busy past the high-water mark, QueueFull past the maximum, writable follows" {
    Burst.busy_seen.store(0, .monotonic);
    Burst.writable_seen.store(0, .monotonic);
    Burst.full_seen.store(0, .monotonic);
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    try app.tcp("127.0.0.1:0", Burst, .{ .write_high_water = 64 * 1024, .write_max = 256 * 1024 });
    try serveWith(&app, struct {
        fn run(a: *App) !void {
            const s = try connect(a, portOf(a));
            defer s.close();
            try s.writer().writeAll("go");
            try s.writer().flush();
            // Not reading yet: the socket buffers fill, then the outbox.
            try waitFor(a.io(), &Burst.full_seen, 1);
            try std.testing.expectEqual(@as(u32, 1), Burst.busy_seen.load(.acquire));
            // Reading everything lets the outbox drain: writable follows.
            var buf: [16 * 1024]u8 = undefined;
            while (Burst.writable_seen.load(.acquire) == 0) {
                _ = try s.reader().readSliceShort(&buf);
            }
        }
    }.run);
}

const Stats = struct {
    pub fn data(conn: *net.Conn, bytes: []const u8) !void {
        _ = try conn.send(bytes);
    }
};

test "net tcp: netStats counts connections and bytes" {
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    try app.tcp("127.0.0.1:0", Stats, .{ .log_connections = true });
    try serveWith(&app, struct {
        fn run(a: *App) !void {
            const s = try connect(a, portOf(a));
            defer s.close();
            try s.writer().writeAll("abc");
            try s.writer().flush();
            try expectRead(s, "abc");
            try std.testing.expectEqual(@as(u64, 1), a.netStats().connections);
            try std.testing.expectEqual(@as(u64, 1), a.netStats().connections_total);
        }
    }.run);
}

test "net tcp: options refused" {
    const expected_log = @import("../errors.zig").expectLog();
    defer expected_log.deinit();
    // Both kinds on one listener.
    {
        var app = try App.init(alloc, .{ .executors = .exact(1), .listeners = &.{.{
            .port = 0,
            .tcp = net.tcp(void, Echo, .{}),
            .udp = net.udp(void, struct {
                pub fn datagram(_: *net.Datagram) !void {}
            }, .{}),
        }} });
        defer app.deinit();
        try std.testing.expectError(error.TcpAndUdp, app.run());
    }
    // No port.
    {
        var app = try App.init(alloc, .{ .executors = .exact(1), .listeners = &.{.{ .tcp = net.tcp(void, Echo, .{}) }} });
        defer app.deinit();
        try std.testing.expectError(error.NetListenerNeedsPort, app.run());
    }
    // HTTP/3 on a raw listener.
    {
        var app = try App.init(alloc, .{ .executors = .exact(1), .listeners = &.{.{ .port = 0, .http3 = true, .tcp = net.tcp(void, Echo, .{}) }} });
        defer app.deinit();
        try std.testing.expectError(error.NetListenerHttp3, app.run());
    }
    // A service built for another state type.
    {
        var app = try App.init(alloc, .{ .executors = .exact(1), .listeners = &.{.{ .port = 0, .tcp = net.tcp(u32, Echo, .{}) }} });
        defer app.deinit();
        try std.testing.expectError(error.NetHandlerContext, app.run());
    }
    // A framing out of range.
    {
        var app = try App.init(alloc, .{ .executors = .exact(1), .listeners = &.{.{ .port = 0, .tcp = .{
            .table = net.tcp(void, Echo, .{}).table,
            .options = .{ .framing = .{ .length = .{ .bytes = 3 } } },
            .ctx_type = "void",
        } }} });
        defer app.deinit();
        try std.testing.expectError(error.InvalidFraming, app.run());
    }
}

test "net tcp: a raw listener beside HTTP, in one server" {
    var app = try App.init(alloc, .{ .executors = .exact(2) });
    defer app.deinit();
    app.get("/ping", struct {
        fn h(_: *@import("../http/root.zig").Request, res: *@import("../http/root.zig").Response) !void {
            res.body = "pong";
        }
    }.h);
    try app.tcp("127.0.0.1:0", Echo, .{});
    Echo.opened.store(0, .monotonic);
    const Check = struct {
        fn run(a: *App) !void {
            defer a.stop();
            try a.waitReady();
            const addrs = a.addresses();
            try std.testing.expectEqual(@as(usize, 2), addrs.len);
            // The HTTP listener first, then the raw one.
            const tcp_port = addrs[1].ip.getPort();
            const s = try connect(a, tcp_port);
            defer s.close();
            try s.writer().writeAll("hi");
            try s.writer().flush();
            try expectRead(s, "hi");
        }
    };
    var checking = try app.io().concurrent(Check.run, .{&app});
    try app.listen("127.0.0.1:0");
    try checking.await(app.io());
}

const Who = struct {
    pub fn open(conn: *net.Conn) !void {
        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        w.print("tls={} sni={s} alpn={s} secure={}\n", .{ conn.isTls(), conn.serverName() orelse "-", conn.alpn() orelse "-", conn.secure() }) catch {};
        _ = try conn.send(w.buffered());
    }
    pub fn data(_: *net.Conn, _: []const u8) !void {}
};

test "net tcp: TLS with SNI and ALPN" {
    if (comptime features.tls != .boringssl) return error.SkipZigTest;
    var app = try App.init(alloc, .{ .executors = .exact(2) });
    defer app.deinit();
    try app.tcpOn(.{ .address = "127.0.0.1", .port = 0, .tls = .{ .cert = .dev_self_signed, .alpn = &.{"chat/1"} } }, Who, .{});
    try serveWith(&app, struct {
        fn run(a: *App) !void {
            const s = try ClientStream.connect(alloc, a.io(), .{
                .host = "127.0.0.1",
                .port = portOf(a),
                .address = .{ .ip4 = .loopback(portOf(a)) },
                .tls = .{ .insecure_skip_verify = true, .server_name = "chat.local", .alpn = &.{"chat/1"} },
            });
            defer s.close();
            const want = "tls=true sni=chat.local alpn=chat/1 secure=true\n";
            try expectRead(s, want);
        }
    }.run);
}

const Peer = struct {
    pub fn open(conn: *net.Conn) !void {
        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        const r = conn.remote().?;
        const l = conn.local().?;
        const d = conn.direct().?;
        w.print("remote={f} local={f} direct={s}\n", .{ r, l, if (d.getPort() != 0) "socket" else "?" }) catch {};
        _ = try conn.send(w.buffered());
    }
    pub fn data(_: *net.Conn, _: []const u8) !void {}
};

test "net tcp: a PROXY v1 header sets remote and local, direct stays the socket's" {
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    try app.tcpOn(.{ .address = "127.0.0.1", .port = 0, .proxy_protocol = true, .proxy_protocol_from = &.{"127.0.0.1"} }, Peer, .{});
    try serveWith(&app, struct {
        fn run(a: *App) !void {
            const s = try connect(a, portOf(a));
            defer s.close();
            try s.writer().writeAll("PROXY TCP4 198.51.100.7 203.0.113.1 4711 7000\r\n");
            try s.writer().flush();
            try expectRead(s, "remote=198.51.100.7:4711 local=203.0.113.1:7000 direct=socket\n");
        }
    }.run);
}

test "net tcp: the listener's max_connections holds a second connection in the backlog" {
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    try app.tcp("127.0.0.1:0", Stats, .{ .max_connections = 1 });
    try serveWith(&app, struct {
        fn run(a: *App) !void {
            const s1 = try connect(a, portOf(a));
            try s1.writer().writeAll("one");
            try s1.writer().flush();
            try expectRead(s1, "one");
            const s2 = try connect(a, portOf(a));
            defer s2.close();
            try s2.writer().writeAll("two");
            try s2.writer().flush();
            // The second waits in the kernel: only one connection is open.
            try wait.expectStays(a.io(), "only one connection is open", a, struct {
                fn one(ap: *App) bool {
                    return ap.netStats().connections == 1;
                }
            }.one, wait.short_window);
            s1.close();
            try expectRead(s2, "two");
        }
    }.run);
}

const Idle = struct {
    var reason: std.atomic.Value(u32) = .init(99);
    var closed: std.atomic.Value(u32) = .init(0);
    pub fn data(_: *net.Conn, _: []const u8) !void {}
    pub fn close(_: *net.Conn, r: net.CloseReason) void {
        reason.store(@backingInt(r), .release);
        _ = closed.fetchAdd(1, .release);
    }
};

test "net tcp: idle_timeout closes with reason idle" {
    Idle.closed.store(0, .monotonic);
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    try app.tcp("127.0.0.1:0", Idle, .{ .idle_timeout = .fromMilliseconds(50) });
    try serveWith(&app, struct {
        fn run(a: *App) !void {
            const s = try connect(a, portOf(a));
            defer s.close();
            try waitFor(a.io(), &Idle.closed, 1);
            try std.testing.expectEqual(@backingInt(net.CloseReason.idle), Idle.reason.load(.acquire));
            try expectEnd(s);
        }
    }.run);
}

const Parked = struct {
    pub fn data(conn: *net.Conn, bytes: []const u8) !void {
        _ = try conn.send(bytes);
    }
};

test "net tcp: idle callback connections hold no task, and each still echoes" {
    var app = try App.init(alloc, .{ .executors = .exact(1), .timeouts = .{ .idle_park = .fromMilliseconds(5) } });
    defer app.deinit();
    if (!app.server.parksIdle()) return error.SkipZigTest;
    try app.tcp("127.0.0.1:0", Parked, .{});
    try serveWith(&app, struct {
        fn run(a: *App) !void {
            var streams: [20]*ClientStream = undefined;
            var made: usize = 0;
            defer for (streams[0..made]) |s| s.close();
            for (&streams) |*s| {
                s.* = try connect(a, portOf(a));
                made += 1;
                try s.*.writer().writeAll("a");
                try s.*.writer().flush();
                try expectRead(s.*, "a");
            }
            // Parked, with no timing bound asserted: poll until all are.
            const AllParked = struct {
                a: *App,
                n: usize,
                fn all(p: @This()) bool {
                    return p.a.server.parkedConnections() >= p.n;
                }
            };
            try wait.waitUntil(a.io(), "every connection parked", AllParked{ .a = a, .n = streams.len }, AllParked.all);
            for (streams) |s| {
                try s.writer().writeAll("b");
                try s.writer().flush();
                try expectRead(s, "b");
            }
        }
    }.run);
}

const Goodbye = struct {
    var closed: std.atomic.Value(u32) = .init(0);
    var drains: std.atomic.Value(u32) = .init(0);
    var last: std.atomic.Value(u32) = .init(99);
    pub fn data(_: *net.Conn, bytes: []const u8) !void {
        _ = bytes;
    }
    pub fn drain(conn: *net.Conn) !void {
        _ = drains.fetchAdd(1, .release);
        _ = try conn.send("bye");
        // Only the first connection says goodbye; the other is left open.
        if (conn.id() % 2 == 1) conn.close();
    }
    pub fn close(_: *net.Conn, r: net.CloseReason) void {
        last.store(@backingInt(r), .release);
        _ = closed.fetchAdd(1, .release);
    }
};

test "net tcp: drain runs the handler's drain, and the connections left open close at the deadline" {
    Goodbye.closed.store(0, .monotonic);
    Goodbye.drains.store(0, .monotonic);
    var app = try App.init(alloc, .{ .executors = .exact(1), .timeouts = .{ .shutdown = .fromMilliseconds(200) } });
    defer app.deinit();
    try app.tcp("127.0.0.1:0", Goodbye, .{});
    const Run = struct {
        fn run(a: *App) !void {
            try a.waitReady();
            const s1 = try connect(a, portOf(a));
            defer s1.close();
            const s2 = try connect(a, portOf(a));
            defer s2.close();
            try wait.waitUntil(a.io(), "both connections accepted", a, struct {
                fn two(ap: *App) bool {
                    return ap.netStats().connections >= 2;
                }
            }.two);
            a.stop();
            // Both said goodbye (the callback ran for both).
            try expectRead(s1, "bye");
            try expectRead(s2, "bye");
            try waitFor(a.io(), &Goodbye.closed, 2);
        }
    };
    var checking = try app.io().concurrent(Run.run, .{&app});
    try app.run();
    try checking.await(app.io());
    try std.testing.expectEqual(@as(u32, 2), Goodbye.drains.load(.acquire));
}

test "net tcp: metrics count connections and bytes per listener" {
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    const registry = app.metrics(.{});
    try app.tcp("127.0.0.1:0", Stats, .{});
    try serveWith(&app, struct {
        fn run(a: *App) !void {
            const s = try connect(a, portOf(a));
            try s.writer().writeAll("abcde");
            try s.writer().flush();
            try expectRead(s, "abcde");
            s.close();
            try waitUntil(a, "anole_net_closes_total{listener=\"tcp-0\",reason=\"peer\"} 1");
        }

        fn waitUntil(a: *App, needle: []const u8) !void {
            const registry_ = a.extras.metrics.?;
            const Rendered = struct {
                registry: *@import("../observe/root.zig").metrics.Registry,
                needle: []const u8,
                fn has(r: @This()) !bool {
                    var out: std.Io.Writer.Allocating = .init(alloc);
                    defer out.deinit();
                    try r.registry.render(&out.writer);
                    return std.mem.indexOf(u8, out.written(), r.needle) != null;
                }
            };
            try wait.waitUntil(a.io(), "the metrics show the close", Rendered{ .registry = registry_, .needle = needle }, Rendered.has);
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            try registry_.render(&out.writer);
            const text = out.written();
            try std.testing.expect(std.mem.indexOf(u8, text, "anole_net_connections_total{listener=\"tcp-0\"} 1") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "anole_net_bytes_received_total{listener=\"tcp-0\"} 5") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "anole_net_bytes_sent_total{listener=\"tcp-0\"} 5") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "anole_net_connections_open{listener=\"tcp-0\"} 0") != null);
        }
    }.run);
    _ = registry;
}

const Cert = struct {
    pub fn open(conn: *net.Conn) !void {
        var buf: [64]u8 = undefined;
        const text = if (conn.peerCertificate()) |der|
            try std.fmt.bufPrint(&buf, "cert {d} {x}\n", .{ der.len, der[0] })
        else
            try std.fmt.bufPrint(&buf, "no cert\n", .{});
        _ = try conn.send(text);
    }
    pub fn data(_: *net.Conn, _: []const u8) !void {}
};

test "net tcp: mutual TLS gives the handler the peer certificate" {
    if (comptime features.tls != .boringssl) return error.SkipZigTest;
    var pem = try @import("../tls/root.zig").selfSigned(alloc, .{});
    defer pem.deinit(alloc);
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    try app.tcpOn(.{ .address = "127.0.0.1", .port = 0, .tls = .{
        .cert = .fromPem(pem.cert, pem.key),
        .client_auth = .{ .ca = .{ .pem = pem.cert }, .mode = .request },
    } }, Cert, .{});
    const Check = struct {
        fn run(a: *App, p: *const @TypeOf(pem)) !void {
            defer a.stop();
            try a.waitReady();
            // With a certificate: its DER length and first byte (0x30).
            {
                const s = try ClientStream.connect(alloc, a.io(), .{
                    .host = "localhost",
                    .port = portOf(a),
                    .address = .{ .ip4 = .loopback(portOf(a)) },
                    .tls = .{ .ca = .{ .pem = p.cert }, .client_certificate = .{ .pem = .{ .cert = p.cert, .key = p.key } }, .server_name = "localhost" },
                });
                defer s.close();
                const line = try s.reader().takeDelimiterExclusive('\n');
                try std.testing.expect(std.mem.startsWith(u8, line, "cert "));
                try std.testing.expect(std.mem.endsWith(u8, line, " 30"));
            }
            // Without one (mode request): the handshake succeeds, no certificate.
            {
                const s = try ClientStream.connect(alloc, a.io(), .{
                    .host = "localhost",
                    .port = portOf(a),
                    .address = .{ .ip4 = .loopback(portOf(a)) },
                    .tls = .{ .ca = .{ .pem = p.cert }, .server_name = "localhost" },
                });
                defer s.close();
                const line = try s.reader().takeDelimiterExclusive('\n');
                try std.testing.expectEqualStrings("no cert", line);
            }
        }
    };
    var checking = try app.io().concurrent(Check.run, .{ &app, &pem });
    try app.run();
    try checking.await(app.io());
}
