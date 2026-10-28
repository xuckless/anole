//! `app.sse` over real sockets on zio: the parked HTTP/1.1 connection (the
//! adopter path) and the parked HTTP/2 stream (the outbox path). Events,
//! heartbeats, the peer going away, the drain, and no task per idle
//! subscriber. Waits are on results; a bounded poll only guards a hang.

const std = @import("std");
const wait = @import("anole_test_wait");
const features = @import("build_options");
const zio = @import("zio");
const server_mod = @import("../server.zig");
const sse = @import("root.zig");
const h2 = if (features.http2) @import("../h2/root.zig") else struct {};

const App = server_mod.App;
const alloc = std.testing.allocator;

/// Waits until `cond(ctx)` holds (anole_test_wait: a hang guard, not a
/// latency bound).
fn eventually(io: std.Io, ctx: anytype, comptime cond: fn (@TypeOf(ctx)) bool) !void {
    try wait.waitUntil(io, "the SSE test's condition (" ++ @typeName(@TypeOf(cond)) ++ ")", ctx, cond);
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    for (0..hay.len - needle.len + 1) |i| if (std.ascii.eqlIgnoreCase(hay[i..][0..needle.len], needle)) return true;
    return false;
}

/// Tasks alive on the runtime (spawned - finished, every executor).
fn liveTasks(io: std.Io) i64 {
    const rt = zio.Runtime.fromIo(io) orelse return -1;
    var n: i64 = 0;
    for (0..rt.executorCount()) |i| {
        const st = rt.executorStats(i) orelse return -1;
        n += @as(i64, @intCast(st.spawned)) - @as(i64, @intCast(st.finished));
    }
    return n;
}

/// Reads from `r` until `needle` is in what was read (or EOF), appending to
/// `acc`.
fn readUntil(r: *std.Io.Reader, acc: *std.ArrayList(u8), needle: []const u8) !void {
    while (std.mem.indexOf(u8, acc.items, needle) == null) {
        r.fillMore() catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            else => return err,
        };
        const b = r.buffered();
        try acc.appendSlice(alloc, b);
        r.toss(b.len);
    }
}

/// Reads from `r` until EOF, appending to `acc`.
fn readToEnd(r: *std.Io.Reader, acc: *std.ArrayList(u8)) !void {
    while (true) {
        r.fillMore() catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        const b = r.buffered();
        try acc.appendSlice(alloc, b);
        r.toss(b.len);
    }
}

const Hub = struct {
    live: *sse.Topics,
    fn noSubscribers(self: *const Hub) bool {
        return self.live.stats().subscribers == 0;
    }
    fn oneSubscriber(self: *const Hub) bool {
        return self.live.stats().subscribers == 1;
    }
};

const TaskWatch = struct {
    io: std.Io,
    want: i64,
    fn back(self: *const TaskWatch) bool {
        return liveTasks(self.io) <= self.want;
    }
};

test "app.sse over HTTP/1.1: the connection parks with no task; events and a heartbeat arrive; the client closing leaves the topic" {
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    const live = try app.sseTopics(.{ .heartbeat = .fromSeconds(10), ._manual_ticks = true });
    app.sse("/live", live, .{ .topics = &.{"news"} });

    const Check = struct {
        fn run(a: *App, hub: *sse.Topics) !void {
            defer a.stop();
            const io = a.io();
            try a.waitReady();
            const port = a.addresses()[0].ip.getPort();
            const h: Hub = .{ .live = hub };
            // A round trip first, so the listener's tasks have settled.
            const baseline = blk: {
                const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
                const s = try addr.connect(io, .{ .mode = .stream });
                var wbuf: [128]u8 = undefined;
                var w = s.writer(io, &wbuf);
                try w.interface.writeAll("GET /nope HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
                try w.interface.flush();
                var rbuf: [512]u8 = undefined;
                var r = s.reader(io, &rbuf);
                var acc: std.ArrayList(u8) = .empty;
                defer acc.deinit(alloc);
                try readToEnd(&r.interface, &acc);
                s.close(io);
                try io.sleep(.fromMilliseconds(20), .awake);
                break :blk liveTasks(io);
            };

            const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
            const s = try addr.connect(io, .{ .mode = .stream });
            var closed = false;
            defer if (!closed) s.close(io);
            var wbuf: [128]u8 = undefined;
            var w = s.writer(io, &wbuf);
            try w.interface.writeAll("GET /live HTTP/1.1\r\nHost: x\r\n\r\n");
            try w.interface.flush();
            var rbuf: [1024]u8 = undefined;
            var r = s.reader(io, &rbuf);
            var acc: std.ArrayList(u8) = .empty;
            defer acc.deinit(alloc);
            // The head and the open line (`id:` of the current position).
            try readUntil(&r.interface, &acc, "\r\n\r\n");
            try std.testing.expect(std.mem.startsWith(u8, acc.items, "HTTP/1.1 200 OK\r\n"));
            try std.testing.expect(containsIgnoreCase(acc.items, "content-type: text/event-stream"));
            try std.testing.expect(containsIgnoreCase(acc.items, "transfer-encoding: chunked"));
            try readUntil(&r.interface, &acc, "id: ");
            try eventually(io, &h, Hub.oneSubscriber);

            // Parked: the connection's task is gone, nothing waits for the
            // subscriber. Where idle connections keep their task (Windows),
            // the rest still holds.
            try std.testing.expect(baseline > 0);
            if (a.server.parksIdle()) {
                const tw: TaskWatch = .{ .io = io, .want = baseline };
                try eventually(io, &tw, TaskWatch.back);
            }

            // A publish reaches the parked connection.
            try std.testing.expectEqual(@as(usize, 1), try hub.publish("news", .{ .data = "hello", .event = "tick" }));
            try readUntil(&r.interface, &acc, "event: tick\ndata: hello\n\n");
            // And again, after the sender went idle.
            _ = try hub.publish("news", .{ .data = "second" });
            try readUntil(&r.interface, &acc, "data: second\n\n");

            // A heartbeat for an idle subscriber.
            _ = hub._tick(0, 1 << 50);
            try readUntil(&r.interface, &acc, ":\n\n");

            // The client goes: the subscriber leaves the topic.
            s.close(io);
            closed = true;
            try eventually(io, &h, Hub.noSubscribers);
            try std.testing.expectEqual(@as(usize, 0), hub.count("news"));
            try std.testing.expectEqual(@as(usize, 0), try hub.publish("news", .{ .data = "nobody" }));
        }
    };
    var checking = try app.io().concurrent(Check.run, .{ &app, live });
    try app.listen("127.0.0.1:0");
    try checking.await(app.io());
}

test "app.sse over HTTP/1.1: the drain gives a parked subscriber a retry, then ends the stream" {
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    const live = try app.sseTopics(.{ .heartbeat = null, ._manual_ticks = true });
    app.sse("/live", live, .{ .topics = &.{"news"} });

    const Check = struct {
        fn run(a: *App, hub: *sse.Topics) !void {
            var stopped = false;
            defer if (!stopped) a.stop();
            const io = a.io();
            try a.waitReady();
            const port = a.addresses()[0].ip.getPort();
            const h: Hub = .{ .live = hub };
            const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
            const s = try addr.connect(io, .{ .mode = .stream });
            defer s.close(io);
            var wbuf: [128]u8 = undefined;
            var w = s.writer(io, &wbuf);
            try w.interface.writeAll("GET /live HTTP/1.1\r\nHost: x\r\n\r\n");
            try w.interface.flush();
            var rbuf: [1024]u8 = undefined;
            var r = s.reader(io, &rbuf);
            var acc: std.ArrayList(u8) = .empty;
            defer acc.deinit(alloc);
            try readUntil(&r.interface, &acc, "id: ");
            try eventually(io, &h, Hub.oneSubscriber);
            _ = try hub.publish("news", .{ .data = "before" });
            try readUntil(&r.interface, &acc, "data: before\n\n");

            a.stop();
            stopped = true;
            // A retry from the spread, then the chunked terminator and EOF.
            try readToEnd(&r.interface, &acc);
            const tail = acc.items[std.mem.indexOf(u8, acc.items, "data: before\n\n").?..];
            try std.testing.expect(std.mem.indexOf(u8, tail, "retry: ") != null);
            try std.testing.expect(std.mem.endsWith(u8, acc.items, "0\r\n\r\n"));
            try eventually(io, &h, Hub.noSubscribers);
        }
    };
    var checking = try app.io().concurrent(Check.run, .{ &app, live });
    try app.listen("127.0.0.1:0");
    try checking.await(app.io());
}

test "app.sse over h2c: events arrive as DATA on the parked stream; a reset leaves the topic and the connection serves on" {
    if (comptime !features.http2) return error.SkipZigTest;
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    const live = try app.sseTopics(.{ .heartbeat = .fromSeconds(10), ._manual_ticks = true });
    app.sse("/rooms/:room/events", live, .{ .topics = &.{"room:{room}"} });
    app.get("/ping", struct {
        fn h(_: *@import("../http/root.zig").Request, res: *@import("../http/root.zig").Response) !void {
            res.body = "pong";
        }
    }.h);

    const Check = struct {
        fn hdrs(path: []const u8) [4]h2.Header {
            return .{
                .{ .name = ":method", .value = "GET" },  .{ .name = ":path", .value = path },
                .{ .name = ":scheme", .value = "http" }, .{ .name = ":authority", .value = "localhost" },
            };
        }

        fn run(a: *App, hub: *sse.Topics) !void {
            defer a.stop();
            const io = a.io();
            try a.waitReady();
            const port = a.addresses()[0].ip.getPort();
            const h: Hub = .{ .live = hub };
            const conn = try h2.ClientConnection.connect(alloc, io, .{ .host = "127.0.0.1", .port = port });
            defer conn.close();

            const st = try conn.request(&hdrs("/rooms/blue/events"), .{});
            var released = false;
            defer if (!released) st.release();
            try st.waitHead();
            try std.testing.expectEqual(@as(u16, 200), st.status);
            var acc: std.ArrayList(u8) = .empty;
            defer acc.deinit(alloc);
            try readUntil(st.reader(), &acc, "id: ");
            try eventually(io, &h, Hub.oneSubscriber);

            try std.testing.expectEqual(@as(usize, 1), try hub.publish("room:blue", .{ .data = "hello" }));
            try std.testing.expectEqual(@as(usize, 0), try hub.publish("room:red", .{ .data = "no" }));
            try readUntil(st.reader(), &acc, "data: hello\n\n");
            _ = hub._tick(0, 1 << 50);
            try readUntil(st.reader(), &acc, ":\n\n");
            try std.testing.expect(std.mem.indexOf(u8, acc.items, "data: no") == null);

            // RST_STREAM: the subscriber leaves.
            st.cancel();
            st.release();
            released = true;
            try eventually(io, &h, Hub.noSubscribers);
            try std.testing.expectEqual(@as(usize, 0), hub.count("room:blue"));

            // The connection is still good.
            const ping = try conn.request(&hdrs("/ping"), .{});
            defer ping.release();
            try ping.waitHead();
            var body: std.ArrayList(u8) = .empty;
            defer body.deinit(alloc);
            try readToEnd(ping.reader(), &body);
            try std.testing.expectEqualStrings("pong", body.items);
        }
    };
    var checking = try app.io().concurrent(Check.run, .{ &app, live });
    try app.listen("127.0.0.1:0");
    try checking.await(app.io());
}

test "app.sse over h2c: the drain ends the parked stream after a retry" {
    if (comptime !features.http2) return error.SkipZigTest;
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    const live = try app.sseTopics(.{ .heartbeat = null, ._manual_ticks = true });
    app.sse("/live", live, .{ .topics = &.{"news"} });

    const Check = struct {
        fn run(a: *App, hub: *sse.Topics) !void {
            var stopped = false;
            defer if (!stopped) a.stop();
            const io = a.io();
            try a.waitReady();
            const port = a.addresses()[0].ip.getPort();
            const h: Hub = .{ .live = hub };
            const conn = try h2.ClientConnection.connect(alloc, io, .{ .host = "127.0.0.1", .port = port });
            defer conn.close();
            const st = try conn.request(&.{
                .{ .name = ":method", .value = "GET" },  .{ .name = ":path", .value = "/live" },
                .{ .name = ":scheme", .value = "http" }, .{ .name = ":authority", .value = "localhost" },
            }, .{});
            defer st.release();
            try st.waitHead();
            var acc: std.ArrayList(u8) = .empty;
            defer acc.deinit(alloc);
            try readUntil(st.reader(), &acc, "id: ");
            try eventually(io, &h, Hub.oneSubscriber);
            a.stop();
            stopped = true;
            try readToEnd(st.reader(), &acc);
            try std.testing.expect(std.mem.indexOf(u8, acc.items, "retry: ") != null);
            try eventually(io, &h, Hub.noSubscribers);
        }
    };
    var checking = try app.io().concurrent(Check.run, .{ &app, live });
    try app.listen("127.0.0.1:0");
    try checking.await(app.io());
}

test "app.sse over HTTP/3: the stream parks with no task; events arrive; a reset leaves the topic; the drain ends a subscriber after a retry" {
    if (comptime !features.http3 or features.tls != .boringssl) return error.SkipZigTest;
    const h3 = @import("../h3/root.zig");
    var app = try App.init(alloc, .{ .executors = .exact(1), .http3 = .{ .alt_svc = false } });
    defer app.deinit();
    const live = try app.sseTopics(.{ .heartbeat = .fromSeconds(10), ._manual_ticks = true });
    app.sse("/live", live, .{ .topics = &.{"news"} });
    app.get("/ping", struct {
        fn h(_: *@import("../http/root.zig").Request, res: *@import("../http/root.zig").Response) !void {
            res.body = "pong";
        }
    }.h);

    const Check = struct {
        fn hdrs(path: []const u8) [4]h3.Header {
            return .{
                .{ .name = ":method", .value = "GET" },   .{ .name = ":path", .value = path },
                .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
            };
        }

        fn ping(conn: *h3.ClientConnection) !void {
            const st = try conn.request(&hdrs("/ping"), .{});
            defer st.release();
            try st.waitHead();
            var body: std.ArrayList(u8) = .empty;
            defer body.deinit(alloc);
            try readToEnd(st.reader(), &body);
            try std.testing.expectEqualStrings("pong", body.items);
        }

        fn run(a: *App, hub: *sse.Topics) !void {
            var stopped = false;
            defer if (!stopped) a.stop();
            const io = a.io();
            try a.waitReady();
            const q = a.http3Address().?;
            const h: Hub = .{ .live = hub };
            const conn = try h3.ClientConnection.connect(alloc, io, .{
                .host = "localhost",
                .address = q,
                .port = q.getPort(),
                .tls = .{ .insecure_skip_verify = true },
                .connect_timeout = .fromSeconds(3),
            });
            defer conn.close();
            // A round trip first, so the endpoint's tasks have settled.
            try ping(conn);
            try io.sleep(.fromMilliseconds(20), .awake);
            const baseline = liveTasks(io);

            const st = try conn.request(&hdrs("/live"), .{});
            var released = false;
            defer if (!released) st.release();
            try st.waitHead();
            try std.testing.expectEqual(@as(u16, 200), st.status);
            var acc: std.ArrayList(u8) = .empty;
            defer acc.deinit(alloc);
            try readUntil(st.reader(), &acc, "id: ");
            try eventually(io, &h, Hub.oneSubscriber);

            // Parked: neither the handler's task nor a sender is left.
            try std.testing.expect(baseline > 0);
            {
                const tw: TaskWatch = .{ .io = io, .want = baseline };
                try eventually(io, &tw, TaskWatch.back);
            }

            try std.testing.expectEqual(@as(usize, 1), try hub.publish("news", .{ .data = "hello", .event = "tick" }));
            try readUntil(st.reader(), &acc, "event: tick\ndata: hello\n\n");
            _ = try hub.publish("news", .{ .data = "second" });
            try readUntil(st.reader(), &acc, "data: second\n\n");
            _ = hub._tick(0, 1 << 50);
            try readUntil(st.reader(), &acc, ":\n\n");

            // The client resets the stream: the subscriber leaves.
            st.cancel();
            st.release();
            released = true;
            try eventually(io, &h, Hub.noSubscribers);
            try std.testing.expectEqual(@as(usize, 0), hub.count("news"));
            try ping(conn);

            // Another subscriber; the drain gives it a retry, then FIN.
            const st2 = try conn.request(&hdrs("/live"), .{});
            defer st2.release();
            try st2.waitHead();
            var acc2: std.ArrayList(u8) = .empty;
            defer acc2.deinit(alloc);
            try readUntil(st2.reader(), &acc2, "id: ");
            try eventually(io, &h, Hub.oneSubscriber);
            a.stop();
            stopped = true;
            try readToEnd(st2.reader(), &acc2);
            try std.testing.expect(std.mem.indexOf(u8, acc2.items, "retry: ") != null);
            try eventually(io, &h, Hub.noSubscribers);
        }
    };
    var checking = try app.io().concurrent(Check.run, .{ &app, live });
    try app.listenTls("127.0.0.1:0", .dev_self_signed);
    try checking.await(app.io());
}
