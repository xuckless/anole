//! WebTransport (draft-02) and WebSocket over HTTP/3 (RFC 9220), end to
//! end: Anole's HTTP/3 server with `anole.webtransport` and
//! `anole.websocket` handlers, against Anole's HTTP/3 client
//! (`openWebTransport`, and an extended CONNECT speaking masked frames
//! through websocket-zig's client codec).
const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");
const features = @import("build_options");
const anole_tls = @import("../tls/root.zig");
const client = @import("client.zig");
const Endpoint = @import("server.zig").Endpoint(void);
const wt = @import("webtransport.zig");
const webtransport = @import("../webtransport.zig");
const websocket = if (features.websocket) @import("../websocket/root.zig") else struct {};
const wsc = if (features.websocket) @import("anole_websocket_codec").client else struct {};
const placement = dusty.placement;
const Relay = @import("client_test.zig").Relay;

/// What the last session's handler saw when it ended.
var last_close: struct {
    mutex: std.atomic.Mutex = .unlocked,
    code: u32 = 0,
    reason: [64]u8 = undefined,
    reason_len: usize = 0,
    by: ?@FieldType(wt.CloseInfo, "by") = null,
    draining: bool = false,
} = .{};
var handlers_done: std.atomic.Value(u32) = .init(0);
/// The code of the last reset an echoed stream's read saw.
var last_reset_code: std.atomic.Value(u32) = .init(std.math.maxInt(u32));

/// Echoes: each bidirectional stream back on itself, each unidirectional
/// stream back on one of its own, each datagram back. A datagram "open"
/// makes the server open a bidirectional and a unidirectional stream that
/// say "from the server"; "close" makes it close the session (code 7).
fn echoSession(session: *wt.Session, req: *dusty.Request) !void {
    defer _ = handlers_done.fetchAdd(1, .release);
    var group: std.Io.Group = .init;
    defer group.cancel(req.io);
    try placement.concurrent(&group, req.io, .local, echoBidi, .{ session, req.io });
    try placement.concurrent(&group, req.io, .local, echoUni, .{ session, req.io });
    try placement.concurrent(&group, req.io, .local, echoDatagrams, .{session});
    group.await(req.io) catch {};
    const info = session.closeInfo().?;
    while (!last_close.mutex.tryLock()) std.atomic.spinLoopHint();
    defer last_close.mutex.unlock();
    last_close.code = info.code;
    last_close.reason_len = @min(info.reason.len, last_close.reason.len);
    @memcpy(last_close.reason[0..last_close.reason_len], info.reason[0..last_close.reason_len]);
    last_close.by = info.by;
    last_close.draining = session.draining();
}

fn echoBidi(session: *wt.Session, io: std.Io) std.Io.Cancelable!void {
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    while (true) {
        const stream = session.acceptStream() catch return;
        placement.concurrent(&group, io, .local, echoStream, .{stream}) catch stream.release();
    }
}

fn echoStream(stream: *wt.Stream) std.Io.Cancelable!void {
    defer stream.release();
    _ = stream.reader().streamRemaining(stream.writer()) catch {
        if (stream.readError()) |e| if (e == error.StreamReset) if (stream.resetCode()) |code| last_reset_code.store(code, .release);
        return;
    };
    stream.closeSend() catch {};
}

fn echoUni(session: *wt.Session, io: std.Io) std.Io.Cancelable!void {
    _ = io;
    while (true) {
        const in = session.acceptUniStream() catch return;
        defer in.release();
        const out = session.openUniStream() catch return;
        defer out.release();
        _ = in.reader().streamRemaining(out.writer()) catch return;
        out.closeSend() catch return;
    }
}

fn echoDatagrams(session: *wt.Session) std.Io.Cancelable!void {
    var buf: [2048]u8 = undefined;
    while (true) {
        const d = session.receiveDatagram(&buf) catch return;
        if (std.mem.eql(u8, d, "open")) {
            const bidi = session.openStream() catch return;
            bidi.writer().writeAll("from the server") catch {};
            bidi.closeSend() catch {};
            // Its answer comes back on the same stream.
            var answer: [64]u8 = undefined;
            const n = bidi.reader().readSliceShort(&answer) catch 0;
            bidi.release();
            const uni = session.openUniStream() catch return;
            uni.writer().writeAll("from the server, one way") catch {};
            uni.writer().writeAll(answer[0..n]) catch {};
            uni.closeSend() catch {};
            uni.release();
            continue;
        }
        if (std.mem.eql(u8, d, "close")) {
            session.close(7, "asked to") catch {};
            return;
        }
        session.sendDatagram(d) catch return;
    }
}

/// RFC 9220: frames echoed until a close.
fn wsEcho(ws: *websocket.Socket) !void {
    while (try ws.next()) |msg| try ws.send(msg.type, msg.data);
}

const Fixture = struct {
    pem: anole_tls.Pem,
    http: *dusty.Server(void),
    ep: *Endpoint,
    future: std.Io.Future(anyerror!void),

    fn start(gpa: std.mem.Allocator, io: std.Io) !Fixture {
        var pem = try anole_tls.selfSigned(gpa, .{});
        errdefer pem.deinit(gpa);
        const http = try gpa.create(dusty.Server(void));
        errdefer gpa.destroy(http);
        http.* = .init(gpa, io, .{ .listeners = &.{} }, {});
        errdefer http.deinit();
        http.router.get("/wt", webtransport.route(void, echoSession, .{}));
        http.router.get("/ignore", webtransport.route(void, ignoreStreams, .{}));
        if (features.websocket) http.router.get("/ws", websocket.route(void, wsEcho, .{}));
        const ep = try Endpoint.init(gpa, io, http, .{
            .address = .{ .ip4 = .loopback(0) },
            .cert_pem = pem.cert,
            .key_pem = pem.key,
            .max_streams_bidi = 8,
            .webtransport = true,
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
            .webtransport = true,
        });
    }
};

fn waitHandlers(io: std.Io, want: u32) !void {
    var tries: usize = 0;
    while (handlers_done.load(.acquire) < want) : (tries += 1) {
        if (tries > 200) return error.Timeout;
        try io.sleep(.fromMilliseconds(10), .awake);
    }
}

test "WebTransport: streams both ways, datagrams, and a close the server sees" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    const conn = try f.connect(gpa, io);
    defer conn.close();

    const settings = try conn.waitSettings();
    try std.testing.expect(settings.connect_protocol and settings.h3_datagram);

    const done_before = handlers_done.load(.acquire);
    const session = try conn.openWebTransport(.{ .authority = "localhost", .path = "/wt", .origin = "https://localhost" });
    defer session.deinit();

    // A bidirectional stream, echoed.
    {
        const s = try session.openStream();
        defer s.release();
        try s.writer().writeAll("hello over webtransport");
        try s.closeSend();
        const back = try s.reader().allocRemaining(gpa, .unlimited);
        defer gpa.free(back);
        try std.testing.expectEqualStrings("hello over webtransport", back);
    }
    // A unidirectional stream, answered on one of the server's.
    {
        const s = try session.openUniStream();
        try s.writer().writeAll("one way");
        try s.closeSend();
        s.release();
        const in = try session.acceptUniStream();
        defer in.release();
        const back = try in.reader().allocRemaining(gpa, .unlimited);
        defer gpa.free(back);
        try std.testing.expectEqualStrings("one way", back);
    }
    // Datagrams, echoed (they may be lost, though not on loopback).
    {
        try std.testing.expect(session.maxDatagramSize() >= 1000);
        try std.testing.expectError(error.DatagramTooLarge, session.sendDatagram(&(@as([70000]u8, @splat(0)))));
        try session.sendDatagram("ping");
        var buf: [1024]u8 = undefined;
        try std.testing.expectEqualStrings("ping", try session.receiveDatagram(&buf));
        const big: [1000]u8 = @splat('d');
        try session.sendDatagram(&big);
        try std.testing.expectError(error.NoSpaceLeft, session.receiveDatagram(buf[0..10]));
        try std.testing.expectEqualSlices(u8, &big, try session.receiveDatagram(&buf));
    }
    // Streams the server opens.
    {
        try session.sendDatagram("open");
        const s = try session.acceptStream();
        const got = try s.reader().allocRemaining(gpa, .unlimited);
        defer gpa.free(got);
        try std.testing.expectEqualStrings("from the server", got);
        try s.writer().writeAll("thanks");
        try s.closeSend();
        s.release();
        const u = try session.acceptUniStream();
        defer u.release();
        const one_way = try u.reader().allocRemaining(gpa, .unlimited);
        defer gpa.free(one_way);
        try std.testing.expectEqualStrings("from the server, one waythanks", one_way);
    }

    try session.close(42, "bye now");
    try std.testing.expectEqual(@as(u32, 42), session.closeInfo().?.code);
    try std.testing.expectError(error.SessionClosed, session.openStream());
    try waitHandlers(io, done_before + 1);
    try std.testing.expectEqual(@as(u32, 42), last_close.code);
    try std.testing.expectEqualStrings("bye now", last_close.reason[0..last_close.reason_len]);
    try std.testing.expectEqual(.peer, last_close.by.?);
}

test "WebTransport: a peer stream reset before its session prefix completes is freed" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    const conn = try f.connect(gpa, io);
    defer conn.close();
    const session = try conn.openWebTransport(.{ .authority = "localhost", .path = "/wt", .origin = "https://localhost" });
    defer session.deinit();

    // Unidirectional (type 0x54) and bidirectional (signal 0x41) streams
    // that say their type and nothing more, then reset; more of them than
    // the server's stream limits, so its credit must come back.
    for (0..120) |i| {
        var tries: usize = 0;
        const id = while (true) : (tries += 1) {
            break session.testOpenRaw(if (i % 2 == 0) .uni_out else .bidi, if (i % 2 == 0) "\x40\x54" else "\x40\x41") catch |err| {
                if (err != error.StreamIdBlocked or tries > 200) return err;
                try io.sleep(.fromMilliseconds(10), .awake);
                continue;
            };
        };
        try io.sleep(.fromMilliseconds(2), .awake);
        session.testReset(id);
    }
    // The connection still works.
    const s = try session.openStream();
    defer s.release();
    try s.writer().writeAll("still here");
    try s.closeSend();
    const back = try s.reader().allocRemaining(gpa, .unlimited);
    defer gpa.free(back);
    try std.testing.expectEqualStrings("still here", back);
    // Leaks show at the end, under the testing allocator.
}

/// Holds a session open without accepting any stream, until "close".
fn ignoreStreams(session: *wt.Session, req: *dusty.Request) !void {
    _ = req;
    var buf: [64]u8 = undefined;
    while (true) {
        const d = session.receiveDatagram(&buf) catch return;
        if (std.mem.eql(u8, d, "close")) return session.close(0, "") catch {};
    }
}

test "WebTransport: streams a handler never accepts hold the peer's stream credit" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    const conn = try f.connect(gpa, io);
    defer conn.close();
    const session = try conn.openWebTransport(.{ .authority = "localhost", .path = "/ignore", .origin = "https://localhost" });
    defer session.deinit();

    // Whole streams, ended: before, each one's credit came back as soon as
    // QUIC was done with it, and they piled up unaccepted.
    const Opener = struct {
        fn run(sess: *wt.Session, count: *std.atomic.Value(usize)) std.Io.Cancelable!void {
            const payload: [1024]u8 = @splat('p');
            for (0..400) |_| {
                const s = sess.openUniStream() catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => return,
                };
                s.writer().writeAll(&payload) catch {};
                s.closeSend() catch {};
                s.release();
                _ = count.fetchAdd(1, .monotonic);
            }
        }
    };
    var opened: std.atomic.Value(usize) = .init(0);
    var task = try io.concurrent(Opener.run, .{ session, &opened });
    try io.sleep(.fromMilliseconds(1500), .awake);
    task.cancel(io) catch {};
    // The server's limit (100 unidirectional streams), not all 400.
    const n = opened.load(.monotonic);
    try std.testing.expect(n >= 50);
    try std.testing.expect(n <= 110);
    try session.sendDatagram("close");
}

test "WebTransport: a client that closes its session and then its connection at once still delivers the close" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    // The close has to reach the server before the connection's end, on
    // every try: neither the session's release (which used to reset the
    // CONNECT stream) nor the connection's close may cut it off.
    for (0..40) |_| {
        const done_before = handlers_done.load(.acquire);
        {
            const conn = try f.connect(gpa, io);
            defer conn.close();
            const session = try conn.openWebTransport(.{ .authority = "localhost", .path = "/wt" });
            defer session.deinit();
            try session.close(4242, "client done");
        }
        try waitHandlers(io, done_before + 1);
        try std.testing.expectEqual(.peer, last_close.by.?);
        try std.testing.expectEqual(@as(u32, 4242), last_close.code);
        try std.testing.expectEqualStrings("client done", last_close.reason[0..last_close.reason_len]);
    }
}

test "WebTransport: a client's close waits a bounded time for a server slow to answer, and the close still arrives" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    const relay = try Relay.start(gpa, io, f.ep.address());
    defer relay.stop();
    const done_before = handlers_done.load(.acquire);
    const conn = try client.ClientConnection.connect(gpa, io, .{
        .host = "localhost",
        .address = relay.front.socket.address,
        .port = f.ep.address().getPort(),
        .tls = .{ .ca = .{ .pem = f.pem.cert } },
        .webtransport = true,
    });
    const session = conn.openWebTransport(.{ .authority = "localhost", .path = "/wt" }) catch |err| {
        conn.close();
        return err;
    };
    // The close waits at the relay past the client's patience (about three
    // PTOs, here 100 ms), so `close` gives up waiting for the server's end
    // and sends CONNECTION_CLOSE behind the capsule.
    relay.holdNext(400);
    session.close(4242, "client done") catch |err| {
        session.deinit();
        conn.close();
        return err;
    };
    const started = std.Io.Clock.awake.now(io);
    session.deinit();
    conn.close();
    const waited = started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
    try std.testing.expect(waited >= 90 and waited < 1100);
    try waitHandlers(io, done_before + 1);
    try std.testing.expectEqual(.peer, last_close.by.?);
    try std.testing.expectEqual(@as(u32, 4242), last_close.code);
}

test "WebTransport: a megabyte each way on many streams at once, past the stream limit" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    const conn = try f.connect(gpa, io);
    defer conn.close();
    const session = try conn.openWebTransport(.{ .authority = "localhost", .path = "/wt" });
    defer session.deinit();

    // 1 MiB up and back: many windows and rings' worth.
    {
        const big = try gpa.alloc(u8, 1 << 20);
        defer gpa.free(big);
        for (big, 0..) |*b, i| b.* = @truncate(i *% 7);
        const s = try session.openStream();
        defer s.release();
        var sender = try io.concurrent(struct {
            fn send(st: *wt.Stream, data: []const u8) !void {
                try st.writer().writeAll(data);
                try st.closeSend();
            }
        }.send, .{ s, big });
        const back = try s.reader().allocRemaining(gpa, .unlimited);
        defer gpa.free(back);
        try sender.await(io);
        try std.testing.expect(std.mem.eql(u8, big, back));
    }
    // Thirty streams at once on a connection that allows 8 (the CONNECT
    // stream among them): openStream waits for credit.
    {
        var group: std.Io.Group = .init;
        defer group.cancel(io);
        var ok: std.atomic.Value(usize) = .init(0);
        for (0..30) |i| try group.concurrent(io, struct {
            fn one(sess: *wt.Session, a: std.mem.Allocator, n: usize, count: *std.atomic.Value(usize)) std.Io.Cancelable!void {
                var msg: [32]u8 = undefined;
                const text = std.fmt.bufPrint(&msg, "stream {d}", .{n}) catch return;
                const s = sess.openStream() catch return;
                defer s.release();
                s.writer().writeAll(text) catch return;
                s.closeSend() catch return;
                const back = s.reader().allocRemaining(a, .unlimited) catch return;
                defer a.free(back);
                if (std.mem.eql(u8, back, text)) _ = count.fetchAdd(1, .monotonic);
            }
        }.one, .{ session, gpa, i, &ok });
        try group.await(io);
        try std.testing.expectEqual(@as(usize, 30), ok.load(.monotonic));
    }
    // More unidirectional streams one after another than either side
    // allows at first (100): credit comes back as they close.
    for (0..130) |i| {
        var msg: [16]u8 = undefined;
        const text = try std.fmt.bufPrint(&msg, "uni {d}", .{i});
        const s = try session.openUniStream();
        try s.writer().writeAll(text);
        try s.closeSend();
        s.release();
        const in = try session.acceptUniStream();
        defer in.release();
        const back = try in.reader().allocRemaining(gpa, .unlimited);
        defer gpa.free(back);
        try std.testing.expectEqualStrings(text, back);
    }
}

test "WebTransport: the server closes with a code; a reset carries its code; the drain closes the session" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    const conn = try f.connect(gpa, io);
    defer conn.close();

    {
        const session = try conn.openWebTransport(.{ .authority = "localhost", .path = "/wt" });
        defer session.deinit();
        // A stream reset by this side reaches the server's echo as a
        // failed read; one the server resets would reach us the same way.
        const s = try session.openStream();
        try s.writer().writeAll("part");
        try s.writer().flush();
        // Once the stream's first bytes are out: a reset before them would
        // reach a server that cannot tell the stream is WebTransport's
        // (draft-02 has no RESET_STREAM_AT).
        try io.sleep(.fromMilliseconds(100), .awake);
        s.reset(5);
        s.release();
        var tries: usize = 0;
        while (last_reset_code.load(.acquire) != 5) : (tries += 1) {
            if (tries > 200) return error.Timeout;
            try io.sleep(.fromMilliseconds(10), .awake);
        }
        try session.sendDatagram("close");
        // The server's close arrives: waits end, with its code.
        try std.testing.expectError(error.SessionClosed, session.acceptStream());
        const info = session.closeInfo().?;
        try std.testing.expectEqual(@as(u32, 7), info.code);
        try std.testing.expectEqualStrings("asked to", info.reason);
        try std.testing.expectEqual(.peer, info.by);
    }
    {
        const done_before = handlers_done.load(.acquire);
        const session = try conn.openWebTransport(.{ .authority = "localhost", .path = "/wt" });
        defer session.deinit();
        const s = try session.openStream();
        defer s.release();
        // The server starts to drain: DRAIN_WEBTRANSPORT_SESSION, then the
        // close, both seen here; the open stream is reset.
        f.http.draining.set(io);
        defer f.http.draining.reset();
        try std.testing.expectError(error.SessionClosed, session.acceptUniStream());
        try std.testing.expect(session.draining());
        const info = session.closeInfo().?;
        try std.testing.expectEqual(@as(u32, 0), info.code);
        try std.testing.expectEqualStrings("server shutting down", info.reason);
        try std.testing.expectError(error.WriteFailed, struct {
            fn send(st: *wt.Stream) !void {
                try st.writer().writeAll("too late");
                try st.writer().flush();
            }
        }.send(s));
        try std.testing.expectEqual(@as(?wt.Error, error.SessionClosed), s.writeError());
        try waitHandlers(io, done_before + 1);
        try std.testing.expect(last_close.draining);
    }
    // Not a WebTransport request: 400, and the connection carries on.
    {
        const s = try conn.request(&.{
            .{ .name = ":method", .value = "GET" },   .{ .name = ":path", .value = "/wt" },
            .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
        }, .{});
        defer s.release();
        try s.waitHead();
        try std.testing.expectEqual(@as(u16, 400), s.status);
    }
}

test "WebTransport: the connection going ends the session and its streams on both sides" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    var stopped = false;
    defer if (!stopped) f.stop(gpa, io);
    const conn = try f.connect(gpa, io);
    defer conn.close();
    const session = try conn.openWebTransport(.{ .authority = "localhost", .path = "/wt" });
    defer session.deinit();
    const s = try session.openStream();
    defer s.release();
    try s.writer().writeAll("half a message");
    try s.writer().flush();
    const u = try session.openUniStream();
    defer u.release();
    try u.writer().writeAll("unfinished");
    try u.writer().flush();
    // The endpoint stops: its drain closes the session, then the
    // connection; whatever the handler held is freed (the testing
    // allocator checks).
    f.stop(gpa, io);
    stopped = true;
    try std.testing.expectError(error.SessionClosed, session.acceptStream());
    try std.testing.expectError(error.ReadFailed, s.reader().allocRemaining(gpa, .unlimited));
}

test "WebSocket over HTTP/3 (RFC 9220): echo, ping, close" {
    if (!features.websocket) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    const conn = try f.connect(gpa, io);
    defer conn.close();
    try std.testing.expect((try conn.waitSettings()).connect_protocol);

    const s = try conn.request(&.{
        .{ .name = ":method", .value = "CONNECT" },      .{ .name = ":protocol", .value = "websocket" },
        .{ .name = ":scheme", .value = "https" },        .{ .name = ":path", .value = "/ws" },
        .{ .name = ":authority", .value = "localhost" }, .{ .name = "sec-websocket-version", .value = "13" },
    }, .{ .body = true, .timeout = .none });
    defer s.release();
    try s.waitHead();
    try std.testing.expectEqual(@as(u16, 200), s.status);

    var frames: Frames = .{ .stream = s };
    try frames.send(.text, "hello over h3");
    var op: wsc.Opcode = undefined;
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("hello over h3", try frames.next(&op, &buf));
    try std.testing.expectEqual(wsc.Opcode.text, op);
    try frames.send(.ping, "are you there");
    try std.testing.expectEqualStrings("are you there", try frames.next(&op, &buf));
    try std.testing.expectEqual(wsc.Opcode.pong, op);
    try frames.send(.binary, &.{ 0, 1, 2, 255 });
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 255 }, try frames.next(&op, &buf));
    try frames.send(.close, &.{ 0x03, 0xe8 });
    const payload = try frames.next(&op, &buf);
    try std.testing.expectEqual(wsc.Opcode.close, op);
    try std.testing.expectEqual(@as(u16, 1000), std.mem.readInt(u16, payload[0..2], .big));
    try s.closeSend();
    // The server's side of the stream ends after its close.
    try std.testing.expectEqual(@as(usize, 0), (try s.reader().allocRemaining(gpa, .unlimited)).len);
}

test "WebSocket over HTTP/3: the drain closes an open socket with 1001" {
    if (!features.websocket) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    const conn = try f.connect(gpa, io);
    defer conn.close();
    const s = try conn.request(&.{
        .{ .name = ":method", .value = "CONNECT" },      .{ .name = ":protocol", .value = "websocket" },
        .{ .name = ":scheme", .value = "https" },        .{ .name = ":path", .value = "/ws" },
        .{ .name = ":authority", .value = "localhost" }, .{ .name = "sec-websocket-version", .value = "13" },
    }, .{ .body = true, .timeout = .none });
    defer s.release();
    try s.waitHead();
    try std.testing.expectEqual(@as(u16, 200), s.status);
    var frames: Frames = .{ .stream = s };
    // What the server's drain does: the signal, then the hooks a socket
    // registered to hear about it.
    f.http.draining.set(io);
    defer f.http.draining.reset();
    f.http.drain_hooks.fire(io);
    var op: wsc.Opcode = undefined;
    var buf: [256]u8 = undefined;
    const payload = try frames.next(&op, &buf);
    try std.testing.expectEqual(wsc.Opcode.close, op);
    try std.testing.expectEqual(@as(u16, 1001), std.mem.readInt(u16, payload[0..2], .big));
    try frames.send(.close, &.{ 0x03, 0xe9 });
    try s.closeSend();
    try std.testing.expectEqual(@as(usize, 0), (try s.reader().allocRemaining(gpa, .unlimited)).len);
}

/// Masked frames out, server frames in, on an HTTP/3 request stream.
const Frames = struct {
    stream: *client.Stream,
    in: [4096]u8 = undefined,
    in_len: usize = 0,

    fn send(self: *Frames, opcode: wsc.Opcode, payload: []const u8) !void {
        var out: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&out);
        var copy: [256]u8 = undefined;
        @memcpy(copy[0..payload.len], payload);
        try wsc.writeFrame(&w, copy[0..payload.len], .{ .opcode = opcode });
        try self.stream.writer().writeAll(w.buffered());
        try self.stream.writer().flush();
    }

    /// Reads until a whole frame is in; returns its payload.
    fn next(self: *Frames, opcode: *wsc.Opcode, out: []u8) ![]u8 {
        while (true) {
            var parser: wsc.Parser = .init(.{});
            var len: usize = 0;
            var used: usize = 0;
            const input = self.in[0..self.in_len];
            parse: while (true) {
                const res = try parser.feed(input[used..]);
                used += res.consumed;
                switch (res.event) {
                    .frame_header => |hd| opcode.* = hd.opcode,
                    .payload => |p| {
                        @memcpy(out[len..][0..p.len], p);
                        len += p.len;
                    },
                    .frame_end => {
                        std.mem.copyForwards(u8, self.in[0 .. self.in_len - used], self.in[used..self.in_len]);
                        self.in_len -= used;
                        return out[0..len];
                    },
                    .need_more => break :parse,
                }
            }
            // What has arrived, however little.
            const r = self.stream.reader();
            const got = try r.peekGreedy(1);
            const n = @min(got.len, self.in.len - self.in_len);
            @memcpy(self.in[self.in_len..][0..n], got[0..n]);
            r.toss(n);
            self.in_len += n;
        }
    }
};

test "WebTransport: a session from a page of another origin is refused" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    const conn = try f.connect(gpa, io);
    defer conn.close();
    try std.testing.expectError(error.WebTransportRefused, conn.openWebTransport(.{ .authority = "localhost", .path = "/wt", .origin = "https://evil.example" }));
    // The connection serves the next one, from the same origin.
    const session = try conn.openWebTransport(.{ .authority = "localhost", .path = "/wt", .origin = "https://localhost" });
    defer session.deinit();
    try session.close(0, "");
}
