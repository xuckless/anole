//! `anole.nats` (Anole's layer over the core client) against a fake NATS
//! server on loopback: handlers and `Msg`, the micro error answer, handler
//! concurrency, the publish cap, and one core connection per executor. The
//! fake plays the server's side; every assertion is on what it saw or on
//! the counters of the handlers, never on elapsed time.
const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");
const nats = @import("root.zig");
const db = @import("../db/root.zig");
const FakeServer = @import("core/testing/FakeServer.zig");
const golden = @import("core/protocol/golden.zig");

const Io = std.Io;
const net = Io.net;
const testing = std.testing;

fn handshake(peer: *FakeServer.Peer) !void {
    try peer.send(golden.info_default);
    const connect_line = try peer.readLine();
    if (!std.mem.startsWith(u8, connect_line, "CONNECT {")) return error.TestNotConnect;
    try peer.expectLine("PING");
    try peer.send(golden.pong);
}

/// One MSG the fake delivers once the client has subscribed.
const Delivery = struct {
    subject: []const u8,
    reply: ?[]const u8 = null,
    payload: []const u8 = "",
};

const Script = struct {
    /// Sent when the client's first SUB arrives.
    deliveries: []const Delivery = &.{},
    /// The server ends (hanging up) after this many publishes from the client.
    expect_pubs: usize = 0,
    /// What the client published: each line, then its body.
    transcript: *std.ArrayList(u8),
    /// The sid of the first SUB.
    sid: u32 = 0,
    /// After the handshake read nothing (until canceled): the client's
    /// writes back up in the sockets.
    stall: bool = false,
};

fn serveScript(io: Io, listener: *net.Server, script: *Script) anyerror!void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try handshake(&peer);
    var pubs: usize = 0;
    var subscribed = false;
    if (script.stall) {
        var never: Io.Event = .unset;
        never.wait(io) catch {};
        return;
    }
    if (script.expect_pubs == 0 and script.deliveries.len == 0) return;
    while (try peer.nextLine()) |line| {
        if (std.mem.eql(u8, line, "PING")) {
            try peer.send(golden.pong);
        } else if (std.mem.startsWith(u8, line, "SUB ") and !subscribed) {
            subscribed = true;
            const sid = std.mem.lastIndexOfScalar(u8, line, ' ').?;
            script.sid = try std.fmt.parseInt(u32, line[sid + 1 ..], 10);
            for (script.deliveries) |d| {
                var buf: [512]u8 = undefined;
                const head = if (d.reply) |r|
                    try std.fmt.bufPrint(&buf, "MSG {s} {d} {s} {d}\r\n{s}\r\n", .{ d.subject, script.sid, r, d.payload.len, d.payload })
                else
                    try std.fmt.bufPrint(&buf, "MSG {s} {d} {d}\r\n{s}\r\n", .{ d.subject, script.sid, d.payload.len, d.payload });
                try peer.send(head);
            }
        } else if (std.mem.startsWith(u8, line, "PUB ") or std.mem.startsWith(u8, line, "HPUB ")) {
            const size = try std.fmt.parseInt(usize, line[std.mem.lastIndexOfScalar(u8, line, ' ').? + 1 ..], 10);
            const body = try testing.allocator.alloc(u8, size + 2);
            defer testing.allocator.free(body);
            try peer.readExact(body);
            try script.transcript.appendSlice(testing.allocator, line);
            try script.transcript.appendSlice(testing.allocator, "\r\n");
            try script.transcript.appendSlice(testing.allocator, body);
            pubs += 1;
            if (script.expect_pubs != 0 and pubs >= script.expect_pubs) return;
        }
    }
}

/// A zio runtime with two executors, a fake server and a Client for it.
const Rig = struct {
    rt: *zio.Runtime,
    listener: net.Server,
    transcript: std.ArrayList(u8) = .empty,
    script: Script,
    server: Io.Future(anyerror!void),
    url_buf: [64]u8 = undefined,
    client: *nats.Client,

    fn start(r: *Rig, deliveries: []const Delivery, expect_pubs: usize, options: nats.Options) !void {
        return r.startWith(.{ .deliveries = deliveries, .expect_pubs = expect_pubs, .transcript = undefined }, options);
    }

    fn startWith(r: *Rig, script: Script, options: nats.Options) !void {
        r.rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(2) });
        errdefer r.rt.deinit();
        const io = r.rt.io();
        r.listener = try FakeServer.listen(io);
        errdefer r.listener.deinit(io);
        r.transcript = .empty;
        r.script = script;
        r.script.transcript = &r.transcript;
        r.server = try io.concurrent(serveScript, .{ io, &r.listener, &r.script });
        errdefer r.server.cancel(io) catch {};
        var o = options;
        o.url = try FakeServer.url(&r.listener, &r.url_buf);
        o.environ = .empty;
        o.connect_at_start = true;
        r.client = try nats.Client.init(testing.allocator, io, o);
    }

    fn deinit(r: *Rig) void {
        const io = r.rt.io();
        r.client.deinit();
        r.server.cancel(io) catch {};
        r.listener.deinit(io);
        r.transcript.deinit(testing.allocator);
        r.rt.deinit();
    }
};

/// What the handlers of the tests below count.
const Seen = struct {
    var handled: std.atomic.Value(u32) = .init(0);
    var running: std.atomic.Value(u32) = .init(0);
    var max_running: std.atomic.Value(u32) = .init(0);
    var overlaps: std.atomic.Value(u32) = .init(0);

    fn reset() void {
        handled.store(0, .monotonic);
        running.store(0, .monotonic);
        max_running.store(0, .monotonic);
        overlaps.store(0, .monotonic);
    }
};

fn echoHandler(m: *nats.Msg) !void {
    _ = Seen.handled.fetchAdd(1, .monotonic);
    const upper = try m.arena.dupe(u8, m.payload);
    for (upper) |*ch| ch.* = std.ascii.toUpper(ch.*);
    try m.respond(upper);
}

fn notFoundHandler(_: *nats.Msg) !void {
    _ = Seen.handled.fetchAdd(1, .monotonic);
    return error.NotFound;
}

fn serialHandler(m: *nats.Msg) !void {
    const now = Seen.running.fetchAdd(1, .acq_rel) + 1;
    if (now > 1) _ = Seen.overlaps.fetchAdd(1, .monotonic);
    _ = Seen.max_running.fetchMax(now, .monotonic);
    // Yield a few times so a second message could overlap if it were let in.
    for (0..5) |_| m.io.sleep(.fromMilliseconds(1), .awake) catch {};
    _ = Seen.running.fetchSub(1, .acq_rel);
    _ = Seen.handled.fetchAdd(1, .monotonic);
    try m.respond("done");
}

fn waitServer(r: *Rig) !void {
    // The fake returns after the publishes it was told to expect.
    try r.server.await(r.rt.io());
}

test "handle: a message reaches the handler as a Msg and respond publishes to its reply subject" {
    Seen.reset();
    var r: Rig = undefined;
    try r.start(&.{.{ .subject = "svc.echo", .reply = "_INBOX.r1", .payload = "hello" }}, 1, .{});
    defer r.deinit();
    try r.client.handle({}, "svc.echo", .{}, echoHandler);
    try r.client.start(null, null, null);
    try waitServer(&r);
    try testing.expectEqual(@as(u32, 1), Seen.handled.load(.monotonic));
    try testing.expectEqualStrings("PUB _INBOX.r1 5\r\nHELLO\r\n", r.transcript.items);
}

test "handle: an error answers a request with the micro error headers, 404 for error.NotFound" {
    Seen.reset();
    var r: Rig = undefined;
    try r.start(&.{.{ .subject = "svc.find", .reply = "_INBOX.r2", .payload = "k" }}, 1, .{});
    defer r.deinit();
    try r.client.handle({}, "svc.find", .{}, notFoundHandler);
    try r.client.start(null, null, null);
    try waitServer(&r);
    try testing.expect(std.mem.startsWith(u8, r.transcript.items, "HPUB _INBOX.r2 "));
    try testing.expect(std.mem.indexOf(u8, r.transcript.items, "Nats-Service-Error: Not Found") != null);
    try testing.expect(std.mem.indexOf(u8, r.transcript.items, "Nats-Service-Error-Code: 404") != null);
}

test "handle: concurrency 1 runs messages one at a time" {
    Seen.reset();
    var r: Rig = undefined;
    const msgs: []const Delivery = &.{
        .{ .subject = "svc.serial", .reply = "_INBOX.a", .payload = "1" },
        .{ .subject = "svc.serial", .reply = "_INBOX.b", .payload = "2" },
        .{ .subject = "svc.serial", .reply = "_INBOX.c", .payload = "3" },
        .{ .subject = "svc.serial", .reply = "_INBOX.d", .payload = "4" },
    };
    try r.start(msgs, msgs.len, .{});
    defer r.deinit();
    try r.client.handle({}, "svc.serial", .{ .concurrency = 1 }, serialHandler);
    try r.client.start(null, null, null);
    try waitServer(&r);
    try testing.expectEqual(@as(u32, msgs.len), Seen.handled.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), Seen.overlaps.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), Seen.max_running.load(.monotonic));
}

test "msg: a Msg is a context for connector calls and error recording" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var dummy: nats.Client = undefined;
    dummy.errors = .{};
    var msg: nats.Msg = .{
        .io = testing.io,
        .arena = arena_state.allocator(),
        .id = "nats-0",
        .subject = "s",
        .reply_to = null,
        .headers = &.{},
        .payload = "",
        .client = &dummy,
    };
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    // No reply subject: respond is a BadRequest, as the doc says.
    try testing.expectError(error.BadRequest, msg.respond("x"));
    // A failure is recorded on the message, where lastError reads it.
    try testing.expectEqual(error.ServiceUnavailable, dummy.mapError(&msg, error.NoResponders));
    try testing.expectEqualStrings("no_responders", db.lastError(&msg).?.code);
}

test "publish: from a request that passes an unsampled caller on, traceparent stays -00" {
    var r: Rig = undefined;
    try r.start(&.{}, 1, .{});
    defer r.deinit();
    try r.client.start(null, null, null);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    // As the tracing middleware leaves a request it does not record
    // (`sample_all` off, caller unsampled): the caller's IDs, as they came.
    var keys: [1][]const u8 = undefined;
    var values: [1][]const u8 = undefined;
    var hashes: [1]u8 = undefined;
    var req: dusty.Request = .{ .arena = arena_state.allocator(), .io = r.rt.io(), ._parser = undefined, ._transport = undefined };
    req.headers = .{ .keys = &keys, .values = &values, .hashes = &hashes };
    const caller = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-00";
    try req.headers.add("traceparent", caller);
    req.trace_id = "0af7651916cd43dd8448eb211c80319c";
    req.span_id = "b7ad6b7169203331";
    try r.client.publish(&req, "audit", "x");
    try waitServer(&r);
    try testing.expect(std.mem.startsWith(u8, r.transcript.items, "HPUB audit "));
    try testing.expect(std.mem.indexOf(u8, r.transcript.items, "traceparent: " ++ caller ++ "\r\n") != null);
}

test "publish cap: past outbound_bytes a publish is ServiceUnavailable (outbound_full) at once and writable is false" {
    var r: Rig = undefined;
    try r.startWith(.{ .stall = true, .transcript = undefined }, .{ .limits = .{ .outbound_bytes = 1 } });
    defer r.deinit();
    try r.client.start(null, null, null);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var ctx: db.Ctx = .{ .io = r.rt.io(), .arena = arena_state.allocator() };
    const payload = try testing.allocator.alloc(u8, 1024 * 1024);
    defer testing.allocator.free(payload);
    @memset(payload, 'x');
    // The fake reads nothing: the sockets fill, then the queue. The wait
    // ends at the first refusal; no timing is asserted.
    const Fill = struct {
        r: *Rig,
        ctx: *db.Ctx,
        payload: []const u8,
        fn refused(f: @This()) !bool {
            if (f.r.client.publish(f.ctx, "capped", f.payload)) |_| return false else |err| {
                try testing.expectEqual(error.ServiceUnavailable, err);
                return true;
            }
        }
    };
    try @import("anole_test_wait").waitUntil(r.rt.io(), "a publish refused past outbound_bytes", Fill{ .r = &r, .ctx = &ctx, .payload = payload }, Fill.refused);
    try testing.expectEqualStrings("outbound_full", db.lastError(&ctx).?.code);
    try testing.expect(!r.client.writable(&ctx));
}

fn pickOn(c: *nats.Client, out: *?*nats.core.Client) void {
    out.* = c.pick();
}

test "per_executor: one core connection per executor, and pick gives the caller's executor its own" {
    var r: Rig = undefined;
    try r.start(&.{}, 0, .{ .connections = .per_executor });
    defer r.deinit();
    try testing.expectEqual(@as(usize, 2), r.client.cores.len);
    for (r.client.cores, 0..) |*k, i| try testing.expectEqual(i, k.executor);
    const io = r.rt.io();
    var group: Io.Group = .init;
    var picked: [2]?*nats.core.Client = .{ null, null };
    for (0..2) |i| try dusty.placement.concurrent(&group, io, .{ .executor = i }, pickOn, .{ r.client, &picked[i] });
    try group.await(io);
    for (0..2) |i| try testing.expectEqual(&r.client.cores[i], picked[i].?);
}

test "one: a single core connection whichever executor picks" {
    var r: Rig = undefined;
    try r.start(&.{}, 0, .{});
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.client.cores.len);
    const io = r.rt.io();
    var group: Io.Group = .init;
    var picked: [2]?*nats.core.Client = .{ null, null };
    for (0..2) |i| try dusty.placement.concurrent(&group, io, .{ .executor = i }, pickOn, .{ r.client, &picked[i] });
    try group.await(io);
    for (picked) |p| try testing.expectEqual(&r.client.cores[0], p.?);
}
