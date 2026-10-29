//! Raw TCP servers over loopback (design-net.md §8.3). Deterministic: every
//! wait is on bytes arriving, an event or a counter; nothing asserts a
//! latency or a short timing window.
const std = @import("std");
const wait = @import("anole_test_wait");
const safety = @import("anole_safety");
const features = @import("build_options");
const server_mod = @import("../server.zig");
const net = @import("root.zig");
const ClientStream = net.ClientStream;

const App = server_mod.App;
/// The App's allocator panics at an allocation under a spin lock (SAFETY.md
/// L5, E1): std's test allocator can't be intercepted, so it is wrapped.
var checked: safety.SpinCheckedAllocator = .init(std.testing.allocator);
const alloc = checked.allocator();

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
    defer checking.cancel(app.io()) catch {};
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
            // The reader runs on its own task until canceled, so the
            // wait below has a deadline whenever the callback comes.
            const Drain = struct {
                fn run(st: *ClientStream) void {
                    var buf: [16 * 1024]u8 = undefined;
                    while (true) {
                        const n = st.reader().readSliceShort(&buf) catch return;
                        if (n == 0) return;
                    }
                }
            };
            var draining = try a.io().concurrent(Drain.run, .{s});
            defer draining.cancel(a.io());
            try wait.waitAtLeast(a.io(), "writable followed the drain", &Burst.writable_seen, 1);
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

test "net tcp: invalid listener options make run() fail with a named error (tcp+udp, no port, http3, wrong state type, bad framing)" {
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
    defer checking.cancel(app.io()) catch {};
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
    defer checking.cancel(app.io()) catch {};
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
    defer checking.cancel(app.io()) catch {};
    try app.run();
    try checking.await(app.io());
}

/// The `*Conn` contract (docs/net.md §1): application threads use a
/// connection under the application's own lock, and `close` takes it out
/// under that lock.
const LateSend = struct {
    var lock: std.atomic.Mutex = .unlocked;
    var conn: ?*net.Conn = null;
    var io: std.Io = undefined;
    var sends: std.atomic.Value(u32) = .init(0);
    var reset_done: std.atomic.Value(bool) = .init(false);
    var closed_after_reset: std.atomic.Value(u32) = .init(0);
    var ok_after_reset: std.atomic.Value(u32) = .init(0);
    var other: std.atomic.Value(u32) = .init(0);
    var closed: std.atomic.Value(u32) = .init(0);

    fn lockIt() void {
        while (!lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn reset() void {
        conn = null;
        sends.store(0, .monotonic);
        reset_done.store(false, .monotonic);
        closed_after_reset.store(0, .monotonic);
        ok_after_reset.store(0, .monotonic);
        other.store(0, .monotonic);
        closed.store(0, .monotonic);
    }

    pub fn open(c: *net.Conn) !void {
        lockIt();
        defer lock.unlock();
        conn = c;
    }
    pub fn data(c: *net.Conn, _: []const u8) !void {
        // Sends from the thread are under way (taken, queued) ...
        try wait.waitAtLeast(io, "the thread sent", &sends, 1);
        c.reset();
        reset_done.store(true, .release);
        // ... and go on after the reset, while the connection still lives.
        try wait.waitAtLeast(io, "a send after the reset", &closed_after_reset, 1);
    }
    pub fn close(_: *net.Conn, _: net.CloseReason) void {
        lockIt();
        conn = null;
        lock.unlock();
        _ = closed.fetchAdd(1, .release);
    }

    /// Sends until the connection is gone from the table.
    fn thread() void {
        const payload: [4096]u8 = @splat('z');
        while (true) {
            lockIt();
            const c = conn orelse {
                lock.unlock();
                if (closed.load(.acquire) > 0) return;
                std.Thread.yield() catch {};
                continue;
            };
            const after = reset_done.load(.acquire);
            if (c.send(&payload)) |_| {
                if (after) _ = ok_after_reset.fetchAdd(1, .release);
            } else |err| switch (err) {
                error.Closed => if (after) {
                    _ = closed_after_reset.fetchAdd(1, .release);
                },
                error.QueueFull => {},
                else => _ = other.fetchAdd(1, .release),
            }
            lock.unlock();
            _ = sends.fetchAdd(1, .release);
            std.Thread.yield() catch {};
        }
    }
};

test "net tcp: a send from another thread after close answers Closed and leaks nothing" {
    LateSend.reset();
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    LateSend.io = app.io();
    try app.tcp("127.0.0.1:0", LateSend, .{});
    try serveWith(&app, struct {
        fn run(a: *App) !void {
            const s = try connect(a, portOf(a));
            defer s.close();
            const th = try std.Thread.spawn(.{}, LateSend.thread, .{});
            defer th.join();
            try wait.waitUntil(a.io(), "the connection registered", {}, struct {
                fn registered(_: void) bool {
                    LateSend.lockIt();
                    defer LateSend.lock.unlock();
                    return LateSend.conn != null;
                }
            }.registered);
            try s.writer().writeAll("x");
            try s.writer().flush();
            try waitFor(a.io(), &LateSend.closed, 1);
        }
    }.run);
    // Taken before the reset: queued, then dropped and freed by it (the
    // test allocator checks); after it: Closed, never taken.
    try std.testing.expectEqual(@as(u32, 0), LateSend.ok_after_reset.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), LateSend.other.load(.acquire));
    try std.testing.expect(LateSend.closed_after_reset.load(.acquire) >= 1);
}

/// `[stress]`: application threads sending to live connections while the
/// handler ends, closes or resets them and clients vanish.
const Storm = struct {
    const conns = 500;
    const wave = 50;
    const threads = 8;
    const Action = enum { end, close, reset, vanish };

    const Entry = struct {
        conn: ?*net.Conn = null,
        /// Bytes taken by sends (ok or busy).
        accepted: u64 = 0,
        registered: std.atomic.Value(bool) = .init(false),
        closed: std.atomic.Value(bool) = .init(false),
        action: Action = .vanish,
    };

    var lock: std.atomic.Mutex = .unlocked;
    var entries: [conns]Entry = undefined;
    /// Live wave: entries [base, base + wave).
    var base: std.atomic.Value(u32) = .init(0);
    var stop: std.atomic.Value(bool) = .init(false);
    var bad: std.atomic.Value(u32) = .init(0);
    var mismatched: std.atomic.Value(u32) = .init(0);
    var results: [5]std.atomic.Value(u64) = @splat(.init(0));
    var seed: u64 = 0;

    fn lockIt() void {
        while (!lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn init(s: u64) void {
        seed = s;
        var prng: std.Random.DefaultPrng = .init(s);
        for (&entries) |*e| e.* = .{ .action = prng.random().enumValue(Action) };
        base.store(0, .monotonic);
        stop.store(false, .monotonic);
        bad.store(0, .monotonic);
        mismatched.store(0, .monotonic);
        for (&results) |*r| r.store(0, .monotonic);
    }

    pub const State = struct { idx: ?u32 = null };

    pub fn message(conn: *net.Conn, line: []const u8) !void {
        const st = conn.contextAs(State);
        if (std.mem.startsWith(u8, line, "go ")) {
            const i = try std.fmt.parseInt(u32, line[3..], 10);
            st.idx = i;
            lockIt();
            entries[i].conn = conn;
            lock.unlock();
            entries[i].registered.store(true, .release);
            return;
        }
        const i = st.idx orelse return;
        switch (entries[i].action) {
            .end => conn.end(),
            .close => conn.close(),
            .reset => conn.reset(),
            .vanish => {},
        }
    }

    pub fn close(conn: *net.Conn, _: net.CloseReason) void {
        const i = conn.contextAs(State).idx orelse return;
        lockIt();
        entries[i].conn = null;
        lock.unlock();
        entries[i].closed.store(true, .release);
    }

    fn sender(k: u32) void {
        var prng: std.Random.DefaultPrng = .init(seed +% 0x9e37 +% k);
        const r = prng.random();
        const payload: [64 * 1024]u8 = @splat('s');
        while (!stop.load(.acquire)) {
            const i = base.load(.acquire) + r.uintLessThan(u32, wave);
            const n = 1 + r.uintLessThan(usize, payload.len);
            lockIt();
            if (entries[i].conn) |c| {
                if (c.send(payload[0..n])) |sent| {
                    entries[i].accepted += n;
                    _ = results[@intFromBool(sent == .busy)].fetchAdd(1, .monotonic);
                } else |err| switch (err) {
                    error.QueueFull => _ = results[2].fetchAdd(1, .monotonic),
                    error.Closed => _ = results[3].fetchAdd(1, .monotonic),
                    error.Ended => _ = results[4].fetchAdd(1, .monotonic),
                    else => _ = bad.fetchAdd(1, .monotonic),
                }
            }
            lock.unlock();
            std.Thread.yield() catch {};
        }
    }

    /// One client: registers, lets the senders reach it, then acts.
    fn client(a: *App, i: u32) std.Io.Cancelable!void {
        clientRun(a, i) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                std.debug.print("storm seed {d}: client {d}: {t}\n", .{ seed, i, err });
                _ = bad.fetchAdd(1, .monotonic);
            },
        };
    }

    fn clientRun(a: *App, i: u32) !void {
        const s = try connect(a, portOf(a));
        defer s.close();
        var line: [32]u8 = undefined;
        try s.writer().writeAll(try std.fmt.bufPrint(&line, "go {d}\n", .{i}));
        try s.writer().flush();
        try wait.waitFlag(a.io(), "the connection registered", &entries[i].registered);
        try wait.waitUntil(a.io(), "a send reached the connection", i, struct {
            fn reached(idx: u32) bool {
                lockIt();
                defer lock.unlock();
                return entries[idx].accepted > 0 or entries[idx].conn == null;
            }
        }.reached);
        const action = entries[i].action;
        if (action == .vanish) return;
        try s.writer().writeAll("act\n");
        try s.writer().flush();
        var received: u64 = 0;
        var buf: [16 * 1024]u8 = undefined;
        while (true) {
            const n = s.reader().readSliceShort(&buf) catch break;
            if (n == 0) break;
            received += n;
        }
        if (action == .reset) return;
        // This side ends too, so the server's connection ends.
        halfClose(s);
        // Ended or closed: every byte a send took arrived before the EOF.
        try wait.waitFlag(a.io(), "the connection closed", &entries[i].closed);
        lockIt();
        const accepted = entries[i].accepted;
        lock.unlock();
        if (accepted != received) {
            std.debug.print("storm seed {d}: client {d} ({t}): {d} bytes taken, {d} received\n", .{ seed, i, action, accepted, received });
            _ = mismatched.fetchAdd(1, .monotonic);
        }
    }
};

test "net tcp: [stress] sends from eight threads racing close, end and reset" {
    try wait.requireStress();
    Storm.init(0x5707_0001);
    var app = try App.init(alloc, .{ .executors = .exact(2) });
    defer app.deinit();
    try app.tcp("127.0.0.1:0", Storm, .{ .framing = .{ .lines = .{} }, .write_high_water = 16 * 1024, .write_max = 256 * 1024 });
    try serveWith(&app, struct {
        fn run(a: *App) !void {
            var threads: [Storm.threads]std.Thread = undefined;
            var started: usize = 0;
            defer {
                Storm.stop.store(true, .release);
                for (threads[0..started]) |t| t.join();
            }
            for (&threads, 0..) |*t, k| {
                t.* = try std.Thread.spawn(.{}, Storm.sender, .{@as(u32, @intCast(k))});
                started += 1;
            }
            var w: u32 = 0;
            while (w < Storm.conns) : (w += Storm.wave) {
                Storm.base.store(w, .release);
                var clients: std.Io.Group = .init;
                defer clients.cancel(a.io());
                for (w..w + Storm.wave) |i| try clients.concurrent(a.io(), Storm.client, .{ a, @as(u32, @intCast(i)) });
                try clients.await(a.io());
            }
            try wait.waitUntil(a.io(), "every connection closed", a, struct {
                fn none(server: *App) bool {
                    return server.netStats().connections == 0;
                }
            }.none);
            try std.testing.expectEqual(@as(u64, Storm.conns), a.netStats().connections_total);
        }
    }.run);
    try std.testing.expectEqual(@as(u32, 0), Storm.bad.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), Storm.mismatched.load(.acquire));
}

// -- Review regressions (s15/net): each forces its interleaving through a
// test hook in tcp.zig (`tcp.test_hold`) at the point the scheduler or a
// thread can stop, instead of hoping for it.

const tcp = @import("tcp.zig");

fn waitConn(io: std.Io, comptime what: []const u8, v: *std.atomic.Value(?*net.Conn)) !*net.Conn {
    try wait.waitUntil(io, what, v, struct {
        fn set(x: *std.atomic.Value(?*net.Conn)) bool {
            return x.load(.acquire) != null;
        }
    }.set);
    return v.load(.acquire).?;
}

/// Reads at least one byte (the stream must not end).
fn readSome(s: *ClientStream, buf: []u8) !usize {
    const n = try s.reader().readSliceShort(buf);
    if (n == 0) return error.EndOfStream;
    return n;
}

/// The driver writes a send over the high-water mark, and WRITABLE's task
/// starts: zio may suspend the driver in that spawn (spawn backpressure).
/// The hold stops it there while WRITABLE resets the connection and the
/// connection is released; the driver then goes on.
const SpawnYield = struct {
    var io: std.Io = undefined;
    var hold: tcp.TestHold = .{ .point = .spawn_writable };
    var closed: std.atomic.Value(u32) = .init(0);
    const big: [8 * 1024]u8 = @splat('w');

    pub fn data(conn: *net.Conn, _: []const u8) !void {
        tcp.test_hold.store(&hold, .release);
        _ = try conn.send(&big);
    }
    pub fn writable(conn: *net.Conn) !void {
        conn.reset();
    }
    pub fn close(_: *net.Conn, _: net.CloseReason) void {
        _ = closed.fetchAdd(1, .release);
        hold.let(io);
    }
};

test "net tcp: a connection released while the driver is suspended in a spawn is not touched after" {
    SpawnYield.hold = .{ .point = .spawn_writable };
    SpawnYield.closed.store(0, .monotonic);
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    defer tcp.test_hold.store(null, .release);
    SpawnYield.io = app.io();
    try app.tcp("127.0.0.1:0", SpawnYield, .{ .write_high_water = 4096 });
    try serveWith(&app, struct {
        fn run(a: *App) !void {
            const s = try connect(a, portOf(a));
            defer s.close();
            try s.writer().writeAll("x");
            try s.writer().flush();
            try waitFor(a.io(), &SpawnYield.closed, 1);
            // The driver was held in the spawn (the interleaving happened),
            // and the server still serves: a new connection opens and ends.
            try std.testing.expect(SpawnYield.hold.held.load(.acquire));
            const s2 = try connect(a, portOf(a));
            defer s2.close();
            try s2.writer().writeAll("y");
            try s2.writer().flush();
            try waitFor(a.io(), &SpawnYield.closed, 2);
        }
    }.run);
}

/// Echo, for the driver's start: two connections on one executor while
/// the first is stopped in `driverFor` where zio may suspend it.
const TwoStarts = struct {
    var io: std.Io = undefined;
    var hold: tcp.TestHold = .{ .point = .driver_start };
    var opened: std.atomic.Value(u32) = .init(0);

    pub fn open(_: *net.Conn) !void {
        _ = opened.fetchAdd(1, .release);
    }
    pub fn data(conn: *net.Conn, bytes: []const u8) !void {
        _ = try conn.send(bytes);
    }
};

test "net tcp: a second connection while the first starts the driver starts no second driver" {
    TwoStarts.hold = .{ .point = .driver_start };
    TwoStarts.opened.store(0, .monotonic);
    tcp.test_driver_runs.store(0, .monotonic);
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    defer tcp.test_hold.store(null, .release);
    TwoStarts.io = app.io();
    try app.tcp("127.0.0.1:0", TwoStarts, .{});
    tcp.test_hold.store(&TwoStarts.hold, .release);
    try serveWith(&app, struct {
        fn run(a: *App) !void {
            const s1 = try connect(a, portOf(a));
            defer s1.close();
            try wait.waitFlag(a.io(), "the first connection is held starting the driver", &TwoStarts.hold.held);
            const s2 = try connect(a, portOf(a));
            defer s2.close();
            try s2.writer().writeAll("two");
            try s2.writer().flush();
            try expectRead(s2, "two");
            TwoStarts.hold.let(a.io());
            try s1.writer().writeAll("one");
            try s1.writer().flush();
            try expectRead(s1, "one");
            try std.testing.expectEqual(@as(u32, 2), TwoStarts.opened.load(.acquire));
            try wait.expectStays(a.io(), "one driver task for the listener's executor", {}, struct {
                fn one(_: void) bool {
                    return tcp.test_driver_runs.load(.acquire) == 1;
                }
            }.one, wait.short_window);
        }
    }.run);
}

/// A send from a thread finds the queue full; before it asks for WRITABLE
/// (held there) the queue drains completely. It must not be left waiting
/// for a WRITABLE nothing will send. The high-water mark is `write_max`,
/// so no send before it asks for WRITABLE: the drain sends none, and any
/// WRITABLE is the held send's.
const FullRace = struct {
    var conn: std.atomic.Value(?*net.Conn) = .init(null);
    var writables: std.atomic.Value(u32) = .init(0);
    var hold: tcp.TestHold = .{ .point = .queue_full };
    // 0: not returned yet; 1: taken; 2: QueueFull; 3: another error.
    var result: std.atomic.Value(u8) = .init(0);
    const piece: [16 * 1024]u8 = @splat('q');

    pub fn open(c: *net.Conn) !void {
        conn.store(c, .release);
    }
    pub fn data(_: *net.Conn, _: []const u8) !void {}
    pub fn writable(_: *net.Conn) !void {
        _ = writables.fetchAdd(1, .release);
    }
    pub fn close(_: *net.Conn, _: net.CloseReason) void {
        conn.store(null, .release);
    }

    fn sender(c: *net.Conn) void {
        if (c.send(&piece)) |_| result.store(1, .release) else |err| result.store(if (err == error.QueueFull) 2 else 3, .release);
    }

    fn heldOrDone(_: void) bool {
        return hold.held.load(.acquire) or result.load(.acquire) != 0;
    }
};

test "net tcp: a send refused as full while the queue drains gets WRITABLE or is taken" {
    FullRace.conn.store(null, .monotonic);
    FullRace.writables.store(0, .monotonic);
    FullRace.hold = .{ .point = .queue_full };
    FullRace.result.store(0, .monotonic);
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    defer tcp.test_hold.store(null, .release);
    try app.tcp("127.0.0.1:0", FullRace, .{ .write_high_water = 64 * 1024, .write_max = 64 * 1024 });
    try serveWith(&app, struct {
        fn run(a: *App) !void {
            const s = try connect(a, portOf(a));
            defer s.close();
            const c = try waitConn(a.io(), "the connection opened", &FullRace.conn);
            // The client reads nothing: sends from a thread fill the
            // kernel's buffers, then the queue, until one is refused and
            // held where it asks for WRITABLE.
            tcp.test_hold.store(&FullRace.hold, .release);
            var taken: usize = 0;
            var th: ?std.Thread = null;
            defer if (th) |t| {
                FullRace.hold.let(a.io());
                t.join();
            };
            while (true) {
                FullRace.result.store(0, .release);
                th = try std.Thread.spawn(.{}, FullRace.sender, .{c});
                try wait.waitUntil(a.io(), "the thread's send returned or is held at the full queue", {}, FullRace.heldOrDone);
                if (FullRace.hold.held.load(.acquire)) break;
                th.?.join();
                th = null;
                try std.testing.expectEqual(@as(u8, 1), FullRace.result.load(.acquire));
                taken += FullRace.piece.len;
            }
            // Everything queued is read: the queue drains to empty.
            var buf: [16 * 1024]u8 = undefined;
            var got: usize = 0;
            while (got < taken) got += try readSome(s, buf[0..@min(buf.len, taken - got)]);
            try wait.waitUntil(a.io(), "the queue is empty", c, struct {
                fn empty(conn: *net.Conn) bool {
                    return conn.queued() == 0;
                }
            }.empty);
            try std.testing.expectEqual(@as(u32, 0), FullRace.writables.load(.acquire));
            FullRace.hold.let(a.io());
            th.?.join();
            th = null;
            switch (FullRace.result.load(.acquire)) {
                // Taken after all: its bytes arrive.
                1 => {
                    var n: usize = 0;
                    while (n < FullRace.piece.len) n += try readSome(s, buf[0 .. FullRace.piece.len - n]);
                },
                // Refused: a WRITABLE follows.
                2 => try wait.waitAtLeast(a.io(), "WRITABLE after the refused send", &FullRace.writables, 1),
                else => return error.TestUnexpectedResult,
            }
        }
    }.run);
}

/// A paused connection whose task waits for `resumeReading` is reset.
const PausedReset = struct {
    var conn: std.atomic.Value(?*net.Conn) = .init(null);
    var closed: std.atomic.Value(u32) = .init(0);

    pub fn data(c: *net.Conn, _: []const u8) !void {
        c.pauseReading();
        conn.store(c, .release);
    }
    pub fn close(_: *net.Conn, _: net.CloseReason) void {
        _ = closed.fetchAdd(1, .release);
    }
};

test "net tcp: reset of a paused connection ends it" {
    PausedReset.conn.store(null, .monotonic);
    PausedReset.closed.store(0, .monotonic);
    tcp.test_paused_waits.store(0, .monotonic);
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    try app.tcp("127.0.0.1:0", PausedReset, .{});
    try serveWith(&app, struct {
        fn run(a: *App) !void {
            const s = try connect(a, portOf(a));
            defer s.close();
            try s.writer().writeAll("a");
            try s.writer().flush();
            const c = try waitConn(a.io(), "the connection paused", &PausedReset.conn);
            // More input: the connection's task stops to wait for a resume.
            try s.writer().writeAll("b");
            try s.writer().flush();
            try wait.waitAtLeast(a.io(), "the task waits for a resume", &tcp.test_paused_waits, 1);
            c.reset();
            try waitFor(a.io(), &PausedReset.closed, 1);
        }
    }.run);
}

/// Counts the allocations of 16 KiB or more: a send chunk's size (an
/// owner-executor send's chunk has room for 16 KiB; the echo path's other
/// allocations are small).
const ChunkCount = struct {
    child: std.mem.Allocator,
    chunks: std.atomic.Value(u32) = .init(0),

    fn allocator(self: *ChunkCount) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{ .alloc = allocFn, .resize = resizeFn, .remap = remapFn, .free = freeFn };

    fn from(ctx: *anyopaque) *ChunkCount {
        // SAFETY: `allocator()` sets the context to a *ChunkCount.
        return @ptrCast(@alignCast(ctx));
    }

    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self = from(ctx);
        if (len >= 16 * 1024) _ = self.chunks.fetchAdd(1, .monotonic);
        return self.child.rawAlloc(len, alignment, ra);
    }

    fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        return from(ctx).child.rawResize(memory, alignment, new_len, ra);
    }

    fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        return from(ctx).child.rawRemap(memory, alignment, new_len, ra);
    }

    fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        from(ctx).child.rawFree(memory, alignment, ra);
    }
};

test "net tcp: a steady echo on one connection allocates no new send chunk after the first" {
    var counting: ChunkCount = .{ .child = alloc };
    var app = try App.init(counting.allocator(), .{ .executors = .exact(1) });
    defer app.deinit();
    try app.tcp("127.0.0.1:0", Echo, .{});
    const Run = struct {
        var count: *ChunkCount = undefined;
        fn round(s: *ClientStream) !void {
            try s.writer().writeAll("0123456789abcdef");
            try s.writer().flush();
            try expectRead(s, "0123456789abcdef");
        }
        fn run(a: *App) !void {
            const s = try connect(a, portOf(a));
            defer s.close();
            for (0..10) |_| try round(s);
            const warm = count.chunks.load(.acquire);
            try std.testing.expect(warm >= 1);
            for (0..200) |_| try round(s);
            try std.testing.expectEqual(warm, count.chunks.load(.acquire));
        }
    };
    Run.count = &counting;
    try serveWith(&app, Run.run);
}
