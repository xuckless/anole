//! WebTransport (draft-02) and WebSocket over HTTP/3 (RFC 9220), end to
//! end: Anole's HTTP/3 server with `anole.webtransport` and
//! `anole.websocket` handlers, against Anole's HTTP/3 client
//! (`openWebTransport`, and an extended CONNECT speaking masked frames
//! through websocket-zig's client codec).
const std = @import("std");
const wait = @import("anole_test_wait");
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
/// The code of the last STOP_SENDING that failed an echoed stream's write.
var last_stop_code: std.atomic.Value(u32) = .init(std.math.maxInt(u32));

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
    noteClose(session);
}

/// Notes how `session` ended in `last_close`.
fn noteClose(session: *wt.Session) void {
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

/// Echoes a stream back on itself, each piece as it arrives.
fn echoStream(stream: *wt.Stream) std.Io.Cancelable!void {
    defer stream.release();
    while (true) {
        _ = stream.reader().stream(stream.writer(), .unlimited) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return noteStreamError(stream),
        };
        stream.writer().flush() catch return noteStreamError(stream);
    }
    stream.closeSend() catch {};
}

/// The codes a peer's reset or STOP_SENDING carried, for the tests.
fn noteStreamError(stream: *wt.Stream) void {
    if (stream.readError()) |e| if (e == error.StreamReset) if (stream.resetCode()) |code| last_reset_code.store(code, .release);
    if (stream.writeError()) |e| if (e == error.StreamStopped) if (stream.stopCode()) |code| last_stop_code.store(code, .release);
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

/// Opens a one-way stream at once, says something on it and ends it,
/// then waits for the client to close: the stream can arrive whole before
/// the client has the 200 (its session established).
fn pushSession(session: *wt.Session) !void {
    const uni = try session.openUniStream();
    try uni.writer().writeAll("pushed at once");
    try uni.closeSend();
    uni.release();
    while (true) {
        const s = session.acceptStream() catch return;
        s.release();
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
        return startWith(gpa, io, 4 << 20);
    }

    /// With the connection's send budget set to `budget`.
    fn startWith(gpa: std.mem.Allocator, io: std.Io, budget: usize) !Fixture {
        var pem = try anole_tls.selfSigned(gpa, .{});
        errdefer pem.deinit(gpa);
        const http = try gpa.create(dusty.Server(void));
        errdefer gpa.destroy(http);
        http.* = .init(gpa, io, .{ .listeners = &.{} }, {});
        errdefer http.deinit();
        http.router.get("/wt", webtransport.route(void, echoSession, .{}));
        http.router.get("/ignore", webtransport.route(void, ignoreStreams, .{}));
        http.router.get("/push", webtransport.route(void, pushSession, .{}));
        http.router.get("/bulk", webtransport.route(void, bulkSession, .{}));
        http.router.get("/herd", webtransport.route(void, herdSession, .{}));
        http.router.get("/prio", webtransport.route(void, prioSession, .{}));
        http.router.get("/budget", webtransport.route(void, budgetSession, .{}));
        http.router.get("/inline", webtransport.route(void, inlineSession, .{}));
        if (features.websocket) http.router.get("/ws", websocket.route(void, wsEcho, .{}));
        const ep = try Endpoint.init(gpa, io, http, .{
            .address = .{ .ip4 = .loopback(0) },
            .cert_pem = pem.cert,
            .key_pem = pem.key,
            .max_streams_bidi = 8,
            .webtransport = true,
            .send_budget = budget,
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
    try wait.waitAtLeast(io, "the session handlers returned", &handlers_done, want);
}

test "WebTransport: the server's SETTINGS offer it, and a bidirectional stream is echoed" {
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
    const session = try conn.openWebTransport(.{ .authority = "localhost", .path = "/wt", .origin = "https://localhost" });
    defer session.deinit();

    const s = try session.openStream();
    defer s.release();
    try s.writer().writeAll("hello over webtransport");
    try s.closeSend();
    const back = try s.reader().allocRemaining(gpa, .unlimited);
    defer gpa.free(back);
    try std.testing.expectEqualStrings("hello over webtransport", back);
}

test "WebTransport: a unidirectional stream is answered on one of the server's" {
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

    {
        const s = try session.openUniStream();
        defer s.release();
        try s.writer().writeAll("one way");
        try s.closeSend();
    }
    const in = try session.acceptUniStream();
    defer in.release();
    const back = try in.reader().allocRemaining(gpa, .unlimited);
    defer gpa.free(back);
    try std.testing.expectEqualStrings("one way", back);
}

test "WebTransport: datagrams are echoed, and one past a size limit fails" {
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

    // Datagrams, echoed (they may be lost, though not on loopback).
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

test "WebTransport: the server opens streams both ways" {
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

    try session.sendDatagram("open");
    {
        const s = try session.acceptStream();
        defer s.release();
        const got = try s.reader().allocRemaining(gpa, .unlimited);
        defer gpa.free(got);
        try std.testing.expectEqualStrings("from the server", got);
        try s.writer().writeAll("thanks");
        try s.closeSend();
    }
    const u = try session.acceptUniStream();
    defer u.release();
    const one_way = try u.reader().allocRemaining(gpa, .unlimited);
    defer gpa.free(one_way);
    try std.testing.expectEqualStrings("from the server, one waythanks", one_way);
}

test "WebTransport: a close is seen by the server with its code and reason" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    const conn = try f.connect(gpa, io);
    defer conn.close();
    const done_before = handlers_done.load(.acquire);
    const session = try conn.openWebTransport(.{ .authority = "localhost", .path = "/wt", .origin = "https://localhost" });
    defer session.deinit();

    try session.close(42, "bye now");
    try std.testing.expectEqual(@as(u32, 42), session.closeInfo().?.code);
    try std.testing.expectError(error.SessionClosed, session.openStream());
    try waitHandlers(io, done_before + 1);
    try std.testing.expectEqual(@as(u32, 42), last_close.code);
    try std.testing.expectEqualStrings("bye now", last_close.reason[0..last_close.reason_len]);
    try std.testing.expectEqual(.peer, last_close.by.?);
}

test "WebTransport: a one-way stream that arrives whole before its session is established is kept for it" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    const conn = try f.connect(gpa, io);
    defer conn.close();
    // Several sessions: in some the server's stream comes with its end
    // before the client has the 200; it was dropped then.
    for (0..8) |_| {
        const session = try conn.openWebTransport(.{ .authority = "localhost", .path = "/push" });
        defer session.deinit();
        const u = try session.acceptUniStream();
        defer u.release();
        const got = try u.reader().allocRemaining(gpa, .unlimited);
        defer gpa.free(got);
        try std.testing.expectEqualStrings("pushed at once", got);
        try session.close(0, "");
    }
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
    const Open = struct {
        session: *wt.Session,
        i: usize,
        id: *i64,
        /// Opens the raw stream; false while the server's credit is not
        /// back yet.
        fn opened(o: @This()) !bool {
            o.id.* = wt.Session.Driver.testOpenRaw(o.session, if (o.i % 2 == 0) .uni_out else .bidi, if (o.i % 2 == 0) "\x40\x54" else "\x40\x41") catch |err| {
                if (err == error.StreamIdBlocked) return false;
                return err;
            };
            return true;
        }
    };
    for (0..120) |i| {
        var id: i64 = -1;
        try wait.waitUntil(io, "stream credit to open the next raw stream", Open{ .session = session, .i = i, .id = &id }, Open.opened);
        // Time for the type to go out before the reset (a sensitivity
        // sleep: either order must free the stream).
        try io.sleep(.fromMilliseconds(2), .awake);
        wt.Session.Driver.testReset(session, id);
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

/// How long the last "go" write on /bulk took, in ms (max when not yet done).
var bulk_write_ms: std.atomic.Value(u64) = .init(std.math.maxInt(u64));
/// Set when /bulk has its "go"; it writes once the test sets `bulk_gate`.
var bulk_got_go: std.atomic.Value(bool) = .init(false);
var bulk_gate: std.Io.Event = .unset;

/// On "go" (and `bulk_gate`): writes 300 KiB in one `writeAll` and `flush`
/// on a stream the client does not read yet, and notes how long that took.
fn bulkSession(session: *wt.Session, req: *dusty.Request) !void {
    var buf: [64]u8 = undefined;
    while (true) {
        const d = session.receiveDatagram(&buf) catch return;
        if (std.mem.eql(u8, d, "close")) return session.close(0, "") catch {};
        if (!std.mem.eql(u8, d, "go")) continue;
        bulk_got_go.store(true, .release);
        try bulk_gate.wait(req.io);
        const out = try session.openUniStream();
        defer out.release();
        const data = try req.arena.alloc(u8, 300 * 1024);
        @memset(data, 'x');
        const t0 = std.Io.Timestamp.now(req.io, .awake);
        try out.writer().writeAll(data);
        try out.writer().flush();
        const ms: u64 = @intCast(t0.durationTo(std.Io.Timestamp.now(req.io, .awake)).toMilliseconds());
        bulk_write_ms.store(ms, .release);
        try out.closeSend();
    }
}

/// The wake-ups of the second stream's reader, when the first one ended.
var herd_wakes: std.atomic.Value(u32) = .init(std.math.maxInt(u32));
/// Set once the second stream's reader has taken its one byte.
var herd_b_read: std.atomic.Value(bool) = .init(false);

fn herdReadB(b: *wt.Stream) std.Io.Cancelable!void {
    // One byte, then blocked until the stream ends.
    _ = b.reader().takeByte() catch return;
    herd_b_read.store(true, .release);
    _ = b.reader().takeByte() catch return;
}

/// Reads stream B (blocked in a task) while stream A carries traffic, and
/// notes how often B's reader woke by the time A ended.
fn herdSession(session: *wt.Session, req: *dusty.Request) !void {
    var group: std.Io.Group = .init;
    defer group.cancel(req.io);
    const b = try session.acceptStream();
    defer b.release();
    try placement.concurrent(&group, req.io, .local, herdReadB, .{b});
    const a = try session.acceptStream();
    defer a.release();
    var sink: [4096]u8 = undefined;
    while (true) {
        const n = a.reader().readSliceShort(&sink) catch break;
        if (n < sink.len) break;
    }
    herd_wakes.store(b.rx.returns.load(.monotonic), .release);
    // Hold the session until the client closes.
    while (true) _ = session.acceptStream() catch return;
}

/// On "go": a backlog of 512 KiB on one stream, then 100 bytes on a stream
/// with urgency 1.
fn prioSession(session: *wt.Session, req: *dusty.Request) !void {
    var buf: [64]u8 = undefined;
    while (true) {
        const d = session.receiveDatagram(&buf) catch return;
        if (std.mem.eql(u8, d, "close")) return session.close(0, "") catch {};
        if (!std.mem.eql(u8, d, "go")) continue;
        const video = try session.openUniStream();
        defer video.release();
        const big = try req.arena.alloc(u8, 512 * 1024);
        @memset(big, 'v');
        big[0] = 'V';
        try video.writer().writeAll(big);
        try video.writer().flush();
        const audio = try session.openUniStream();
        defer audio.release();
        audio.setPriority(1);
        var small: [100]u8 = @splat('a');
        small[0] = 'A';
        try audio.writer().writeAll(&small);
        try audio.closeSend();
        try video.closeSend();
        // Their ends reach the peer before the session goes.
        while (true) _ = session.receiveDatagram(&buf) catch return;
    }
}

var budget_done: std.atomic.Value(u32) = .init(0);

fn budgetWrite(session: *wt.Session) std.Io.Cancelable!void {
    const out = session.openUniStream() catch return;
    defer out.release();
    var chunk: [4096]u8 = @splat('b');
    for (0..50) |_| out.writer().writeAll(&chunk) catch return;
    out.closeSend() catch return;
    _ = budget_done.fetchAdd(1, .release);
    // The stream's end must reach the peer before it is released: it is
    // held until the session's handler ends and cancels this task, which
    // the test asks for only once it has read all three streams (the
    // wait helper's deadline is a hang guard).
    session.core.io.sleep(wait.deadline(), .awake) catch return;
}

/// On "go": three streams of 200 KiB each, against a connection budget that
/// holds only a little more than one.
fn budgetSession(session: *wt.Session, req: *dusty.Request) !void {
    var group: std.Io.Group = .init;
    defer group.cancel(req.io);
    var buf: [64]u8 = undefined;
    while (true) {
        const d = session.receiveDatagram(&buf) catch return;
        if (std.mem.eql(u8, d, "close")) return session.close(0, "") catch {};
        if (!std.mem.eql(u8, d, "go")) continue;
        for (0..3) |_| try placement.concurrent(&group, req.io, .local, budgetWrite, .{session});
    }
}

/// Whether the last /inline session parsed its capsules in place.
var inline_seen: std.atomic.Value(u32) = .init(0);

fn inlineSession(session: *wt.Session) !void {
    defer _ = handlers_done.fetchAdd(1, .release);
    inline_seen.store(if (session.inline_capsules) 1 else 2, .release);
    while (true) _ = session.acceptStream() catch break;
    noteClose(session);
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
    // A failed wait must not leave the opener on the session.
    defer task.cancel(io) catch {};
    // The server's limit (100 unidirectional streams), not all 400: well
    // into it, and then no further.
    try wait.waitAtLeast(io, "50 streams opened", &opened, 50);
    try wait.expectStays(io, "the opener stays within the server's stream limit", &opened, struct {
        fn within(v: *const std.atomic.Value(usize)) bool {
            return v.load(.monotonic) <= 110;
        }
    }.within, .fromMilliseconds(500));
    task.cancel(io) catch {};
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
    try std.testing.expect(waited >= 90);
    if (wait.timing()) try std.testing.expect(waited < 1100);
    try waitHandlers(io, done_before + 1);
    try std.testing.expectEqual(.peer, last_close.by.?);
    try std.testing.expectEqual(@as(u32, 4242), last_close.code);
}

test "WebTransport: a 1 MiB stream is echoed both ways" {
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
    defer sender.cancel(io) catch {};
    const back = try s.reader().allocRemaining(gpa, .unlimited);
    defer gpa.free(back);
    try sender.await(io);
    try std.testing.expect(std.mem.eql(u8, big, back));
}

test "WebTransport: 30 streams at once wait for credit past a limit of 8" {
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

    // Thirty streams at once on a connection that allows 8 (the CONNECT
    // stream among them): openStream waits for credit.
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    var ok: std.atomic.Value(usize) = .init(0);
    for (0..30) |i| try group.concurrent(io, struct {
        fn one(sess: *wt.Session, a: std.mem.Allocator, n: usize, count: *std.atomic.Value(usize)) std.Io.Cancelable!void {
            var msg: [32]u8 = undefined;
            const text = std.fmt.bufPrint(&msg, "stream {d}", .{n}) catch return;
            // Not counted on any other error: the wait below says so.
            const s = sess.openStream() catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return,
            };
            defer s.release();
            s.writer().writeAll(text) catch return;
            s.closeSend() catch return;
            const back = s.reader().allocRemaining(a, .unlimited) catch return;
            defer a.free(back);
            if (std.mem.eql(u8, back, text)) _ = count.fetchAdd(1, .monotonic);
        }
    }.one, .{ session, gpa, i, &ok });
    // Bounded: a stream credit that never comes back would hold the group.
    try wait.waitAtLeast(io, "30 streams echoed", &ok, 30);
    try group.await(io);
    try std.testing.expectEqual(@as(usize, 30), ok.load(.monotonic));
}

test "WebTransport: 130 one-way streams in a row get credit back as they close" {
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

    // More unidirectional streams one after another than either side
    // allows at first (100): credit comes back as they close.
    for (0..130) |i| {
        var msg: [16]u8 = undefined;
        const text = try std.fmt.bufPrint(&msg, "uni {d}", .{i});
        {
            const s = try session.openUniStream();
            defer s.release();
            try s.writer().writeAll(text);
            try s.closeSend();
        }
        const in = try session.acceptUniStream();
        defer in.release();
        const back = try in.reader().allocRemaining(gpa, .unlimited);
        defer gpa.free(back);
        try std.testing.expectEqualStrings(text, back);
    }
}

test "WebTransport: the server closes a session with a code and a reason" {
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

    try session.sendDatagram("close");
    // The server's close arrives: waits end, with its code.
    try std.testing.expectError(error.SessionClosed, session.acceptStream());
    const info = session.closeInfo().?;
    try std.testing.expectEqual(@as(u32, 7), info.code);
    try std.testing.expectEqualStrings("asked to", info.reason);
    try std.testing.expectEqual(.peer, info.by);
}

test "WebTransport: a stream reset reaches the peer with its code" {
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

    last_reset_code.store(std.math.maxInt(u32), .release);
    // A stream reset by this side reaches the server's echo as a failed
    // read; one the server resets would reach us the same way.
    const s = try session.openStream();
    defer s.release();
    try s.writer().writeAll("part");
    try s.writer().flush();
    // Once the server has the stream's first bytes (their echo is back): a
    // reset before them would reach a server that cannot tell the stream
    // is WebTransport's (draft-02 has no RESET_STREAM_AT).
    var echoed: [4]u8 = undefined;
    try s.reader().readSliceAll(&echoed);
    s.reset(5);
    try wait.waitEqual(io, "the server's echo saw the reset's code", &last_reset_code, 5);
}

test "WebTransport: the server's drain closes the session and resets its open stream" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    const conn = try f.connect(gpa, io);
    defer conn.close();
    const done_before = handlers_done.load(.acquire);
    const session = try conn.openWebTransport(.{ .authority = "localhost", .path = "/wt" });
    defer session.deinit();
    const s = try session.openStream();
    defer s.release();
    // The server starts to drain: DRAIN_WEBTRANSPORT_SESSION, then the
    // close, both seen here; the open stream is reset.
    f.http.draining.set(io);
    defer f.http.draining.reset();
    f.http.drain_hooks.fire(io);
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

test "WebTransport: a plain GET on a WebTransport route gets 400, and the connection carries on" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    const conn = try f.connect(gpa, io);
    defer conn.close();

    {
        const s = try conn.request(&.{
            .{ .name = ":method", .value = "GET" },   .{ .name = ":path", .value = "/wt" },
            .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
        }, .{});
        defer s.release();
        try s.waitHead();
        try std.testing.expectEqual(@as(u16, 400), s.status);
    }
    // The connection carries on: a session opens on it.
    const session = try conn.openWebTransport(.{ .authority = "localhost", .path = "/wt" });
    defer session.deinit();
    try session.close(0, "");
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

test "WebTransport: stopSending stops only the peer's writes, which fail with its code; one's own writes go on" {
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
    const s = try session.openStream();
    defer s.release();
    last_stop_code.store(std.math.maxInt(u32), .release);
    try s.writer().writeAll("hello");
    try s.writer().flush();
    var echoed: [5]u8 = undefined;
    try s.reader().readSliceAll(&echoed);
    try std.testing.expectEqualStrings("hello", &echoed);
    // We stop reading and keep writing, our side open. Our own writes go
    // on (our STOP_SENDING once failed our own sending side); the server's
    // echo of them fails with our code once our STOP_SENDING arrives (the
    // peer's STOP_SENDING once never reached the server's stream). Having
    // failed, the server lets go and stops our side in turn (code 0): a
    // write may fail then, only after the server saw our code.
    s.stopSending(9);
    try wait.waitUntil(io, "the server's echo failed with our code", s, struct {
        fn stopped(st: *wt.Stream) !bool {
            if (last_stop_code.load(.acquire) == 9) return true;
            st.writer().writeAll("more") catch {};
            st.writer().flush() catch {};
            if (st.writeError()) |e| {
                if (last_stop_code.load(.acquire) == 9) return true;
                return e;
            }
            return false;
        }
    }.stopped);
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

test "WebTransport: a 300 KiB message write returns before the peer acknowledges it" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    bulk_write_ms.store(std.math.maxInt(u64), .release);
    bulk_got_go.store(false, .release);
    bulk_gate = .unset;
    // On every exit, before the fixture stops: the handler goes on.
    defer bulk_gate.set(io);
    // Through a relay that can hold the client's datagrams, its ACKs with
    // them.
    const relay = try Relay.start(gpa, io, f.ep.address());
    defer relay.stop();
    const conn = try client.ClientConnection.connect(gpa, io, .{
        .host = "localhost",
        .address = relay.front.socket.address,
        .port = f.ep.address().getPort(),
        .tls = .{ .ca = .{ .pem = f.pem.cert } },
        .webtransport = true,
    });
    defer conn.close();
    const session = try conn.openWebTransport(.{ .authority = "localhost", .path = "/bulk" });
    defer session.deinit();
    try session.sendDatagram("go");
    try wait.waitFlag(io, "the server got the go", &bulk_got_go);
    // From now on the server hears nothing from the client, no ACK either,
    // and only then does it write.
    relay.holdUp();
    defer relay.releaseUp();
    bulk_gate.set(io);
    // The write is queued under the stream's 1 MiB cap: it returns with
    // no acknowledgement of any of it. A write that waited for them would
    // never return here, and the wait fails.
    try wait.waitUntil(io, "the server's bulk write returned with no ACK from the client", {}, struct {
        fn cond(_: void) bool {
            return bulk_write_ms.load(.acquire) != std.math.maxInt(u64);
        }
    }.cond);
    if (wait.timing()) try std.testing.expect(bulk_write_ms.load(.acquire) < 1000);
    relay.releaseUp();
    const in = try session.acceptUniStream();
    defer in.release();
    const got = try in.reader().allocRemaining(gpa, .unlimited);
    defer gpa.free(got);
    try std.testing.expectEqual(@as(usize, 300 * 1024), got.len);
    try session.sendDatagram("close");
}

test "WebTransport: a stream's reader is not woken by another stream's traffic" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    const conn = try f.connect(gpa, io);
    defer conn.close();
    const session = try conn.openWebTransport(.{ .authority = "localhost", .path = "/herd" });
    defer session.deinit();
    herd_wakes.store(std.math.maxInt(u32), .release);
    herd_b_read.store(false, .release);
    // Stream B: one byte, then silence, its reader blocked for more.
    const b = try session.openStream();
    defer b.release();
    try b.writer().writeAll("b");
    try b.writer().flush();
    try wait.waitFlag(io, "the server's reader of stream B took its byte", &herd_b_read);
    // Stream A: 200 messages.
    const a = try session.openStream();
    defer a.release();
    var msg: [100]u8 = @splat('a');
    for (0..200) |_| {
        try a.writer().writeAll(&msg);
        try a.writer().flush();
    }
    try a.closeSend();
    try wait.waitUntil(io, "the herd test's reader reported its wakes", {}, struct {
        fn cond(_: void) bool {
            return herd_wakes.load(.acquire) != std.math.maxInt(u32);
        }
    }.cond);
    try std.testing.expect(herd_wakes.load(.acquire) <= 2);
}

test "WebTransport: streams hold no send or receive blocks once their data is acked and read" {
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
    f.ep.sampleStats();
    const baseline = f.ep.stats.blocks_live.load(.monotonic);
    {
        const s = try session.openStream();
        defer s.release();
        const msg: [20000]u8 = @splat('e');
        try s.writer().writeAll(&msg);
        try s.closeSend();
        const back = try s.reader().allocRemaining(gpa, .unlimited);
        defer gpa.free(back);
        try std.testing.expectEqual(msg.len, back.len);
    }
    const Blocks = struct {
        ep: *Endpoint,
        baseline: u64,
        fn back(c: @This()) bool {
            c.ep.sampleStats();
            return c.ep.stats.blocks_live.load(.monotonic) == c.baseline;
        }
    };
    try wait.waitUntil(io, "the streams' blocks are back to the baseline", Blocks{ .ep = f.ep, .baseline = baseline }, Blocks.back);
}

test "WebTransport: an urgent stream's bytes arrive while a backlogged stream is still unread" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    const conn = try f.connect(gpa, io);
    defer conn.close();
    const session = try conn.openWebTransport(.{ .authority = "localhost", .path = "/prio" });
    defer session.deinit();
    try session.sendDatagram("go");
    const first = try session.acceptUniStream();
    defer first.release();
    const second = try session.acceptUniStream();
    defer second.release();
    // Whichever came first, A (tag 'A', 100 bytes) is read whole before V
    // (tag 'V', 512 KiB) is touched.
    const tag_first = try first.reader().takeByte();
    const audio = if (tag_first == 'A') first else second;
    const video = if (tag_first == 'A') second else first;
    if (tag_first != 'A') try std.testing.expectEqual(@as(u8, 'A'), try audio.reader().takeByte());
    const rest = try audio.reader().allocRemaining(gpa, .unlimited);
    defer gpa.free(rest);
    try std.testing.expectEqual(@as(usize, 99), rest.len);
    if (tag_first == 'A') try std.testing.expectEqual(@as(u8, 'V'), try video.reader().takeByte());
    const v = try video.reader().allocRemaining(gpa, .unlimited);
    defer gpa.free(v);
    try std.testing.expectEqual(@as(usize, 512 * 1024 - 1), v.len);
    try session.sendDatagram("close");
}

test "WebTransport: writers wait on the connection budget and resume as acks free it" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.startWith(gpa, io, 256 * 1024);
    defer f.stop(gpa, io);
    const conn = try f.connect(gpa, io);
    defer conn.close();
    const session = try conn.openWebTransport(.{ .authority = "localhost", .path = "/budget" });
    defer session.deinit();
    budget_done.store(0, .release);
    try session.sendDatagram("go");
    for (0..3) |_| {
        const in = try session.acceptUniStream();
        defer in.release();
        const got = try in.reader().allocRemaining(gpa, .unlimited);
        defer gpa.free(got);
        try std.testing.expectEqual(@as(usize, 50 * 4096), got.len);
    }
    try wait.waitAtLeast(io, "the three budget streams written", &budget_done, 3);
    try session.sendDatagram("close");
}

test "WebTransport: the session ends on the peer's close capsule with no capsule task" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    const conn = try f.connect(gpa, io);
    defer conn.close();
    inline_seen.store(0, .release);
    const done_before = handlers_done.load(.acquire);
    const session = try conn.openWebTransport(.{ .authority = "localhost", .path = "/inline" });
    defer session.deinit();
    try wait.waitAtLeast(io, "the inline handler saw the session", &inline_seen, 1);
    // Precondition: the server parses the CONNECT stream's capsules where
    // they arrive, with no task of their own.
    try std.testing.expectEqual(@as(u32, 1), inline_seen.load(.acquire));
    try session.close(9, "done");
    // The peer's close capsule ends the server's session, with its code.
    try waitHandlers(io, done_before + 1);
    try std.testing.expectEqual(@as(u32, 9), last_close.code);
    try std.testing.expectEqualStrings("done", last_close.reason[0..last_close.reason_len]);
    try std.testing.expectEqual(.peer, last_close.by.?);
}
