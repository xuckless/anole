// Adapted from vkiryakov/zefir src/nats/testing/messaging_tests.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! Publishing and subscribing against a fake server on loopback. Each test
//! starts its own server function in a task and cancels it on the way out;
//! the client's waits are bounded, so a mistake fails a test instead of
//! hanging it.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const testing = std.testing;
const test_wait = @import("anole_test_wait");
const nats = @import("../root.zig");
const Client = nats.Client;
const FakeServer = @import("FakeServer.zig");
const StallingIo = @import("StallingIo.zig");
const golden = @import("../protocol/golden.zig");
const time = @import("../engine/time.zig");

const quick: nats.FlushOptions = .{ .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } } };

const info_without_headers = "INFO {\"server_id\":\"old\",\"proto\":1,\"max_payload\":1048576} \r\n";
const info_small = "INFO {\"server_id\":\"small\",\"proto\":1,\"headers\":true,\"max_payload\":1024} \r\n";
const info_no_limit = "INFO {\"server_id\":\"no-limit\",\"proto\":1,\"headers\":true} \r\n";
const info_zero_limit = "INFO {\"server_id\":\"zero\",\"proto\":1,\"headers\":true,\"max_payload\":0} \r\n";
const info_huge = "INFO {\"server_id\":\"huge\",\"proto\":1,\"headers\":true,\"max_payload\":67108864} \r\n";

/// The server's side of the handshake, with `info` as its INFO.
fn handshake(peer: *FakeServer.Peer, info: []const u8) !void {
    try peer.send(info);
    const connect_line = try peer.readLine();
    if (!std.mem.startsWith(u8, connect_line, "CONNECT {")) return error.TestNotConnect;
    try peer.expectLine("PING");
    try peer.send(golden.pong);
}

/// After the handshake, writes every frame the client sends to
/// `transcript`, payloads included, and answers each PING, until the
/// client hangs up.
fn serveRecording(io: Io, listener: *net.Server, info: []const u8, transcript: *std.ArrayList(u8)) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try handshake(&peer, info);
    while (try peer.nextLine()) |line| {
        try transcript.appendSlice(testing.allocator, line);
        try transcript.appendSlice(testing.allocator, "\r\n");
        if (std.mem.eql(u8, line, "PING")) {
            try peer.send(golden.pong);
        } else if (std.mem.startsWith(u8, line, "PUB ") or std.mem.startsWith(u8, line, "HPUB ")) {
            const size = try std.fmt.parseInt(usize, line[std.mem.findScalarLast(u8, line, ' ').? + 1 ..], 10);
            const body = try testing.allocator.alloc(u8, size + 2);
            defer testing.allocator.free(body);
            try peer.readExact(body);
            try transcript.appendSlice(testing.allocator, body);
        }
    }
}

/// A client connected to a recording server, and what the server recorded.
const Recorded = struct {
    listener: net.Server,
    server: Io.Future(anyerror!void),
    transcript: std.ArrayList(u8) = .empty,
    url: [64]u8 = undefined,
    client: Client,

    /// Starts the server with `info` and connects a client with `options`
    /// (its servers are replaced by the fake one). Initialize in place.
    fn start(r: *Recorded, info: []const u8, options: nats.Options) !void {
        const io = testing.io;
        r.listener = try FakeServer.listen(io);
        errdefer r.listener.deinit(io);
        r.transcript = .empty;
        errdefer r.transcript.deinit(testing.allocator);
        r.server = try io.concurrent(serveRecordingAny, .{ io, &r.listener, info, &r.transcript });
        errdefer r.server.cancel(io) catch {};
        var with_server = options;
        with_server.servers = &.{try FakeServer.url(&r.listener, &r.url)};
        r.client = try .init(testing.allocator, io, with_server);
        errdefer r.client.deinit();
        try r.client.connect();
    }

    /// Flushes, closes the client and waits for the server; then
    /// `transcript` holds everything the client sent.
    fn finish(r: *Recorded) !void {
        try r.client.flush(quick);
        r.client.close();
        try r.server.await(testing.io);
    }

    fn deinit(r: *Recorded) void {
        const io = testing.io;
        r.client.deinit();
        r.server.cancel(io) catch {};
        r.listener.deinit(io);
        r.transcript.deinit(testing.allocator);
    }
};

fn serveRecordingAny(io: Io, listener: *net.Server, info: []const u8, transcript: *std.ArrayList(u8)) anyerror!void {
    return serveRecording(io, listener, info, transcript);
}

test "publish sends PUB; a reply subject and headers go along" {
    var r: Recorded = undefined;
    try r.start(golden.info_default, .{ .servers = &.{} });
    defer r.deinit();
    try r.client.publish("foo", "hello");
    try r.client.publishMessage(.{ .subject = "foo", .reply_to = "reply.to", .payload = "x" });
    try r.client.publishMessage(.{
        .subject = "h",
        .headers = &.{ .{ .name = "X-A", .value = "1" }, .{ .name = "X-A", .value = "2" } },
        .payload = "p",
    });
    try r.client.publishMessage(.{ .subject = "h.only", .reply_to = "r", .headers = &.{.{ .name = "K", .value = "v" }} });
    // A binary payload, with bytes that look like frames.
    try r.client.publish("bin", "\r\nPING\r\n\x00\xff");
    try r.finish();
    try testing.expectEqualStrings("PUB foo 5\r\nhello\r\n" ++
        "PUB foo reply.to 1\r\nx\r\n" ++
        "HPUB h 28 29\r\nNATS/1.0\r\nX-A: 1\r\nX-A: 2\r\n\r\np\r\n" ++
        "HPUB h.only r 18 18\r\nNATS/1.0\r\nK: v\r\n\r\n\r\n" ++
        "PUB bin 10\r\n\r\nPING\r\n\x00\xff\r\n" ++
        "PING\r\n", r.transcript.items);
}

test "publish refuses bad subjects and headers before anything is queued" {
    var r: Recorded = undefined;
    try r.start(golden.info_default, .{ .servers = &.{} });
    defer r.deinit();
    const c = &r.client;
    for ([_][]const u8{ "", "foo bar", "foo.*", "foo.>", "foo..bar", "foo\r\nPUB x 1" }) |subject| {
        try testing.expectError(error.InvalidSubject, c.publish(subject, "x"));
    }
    try testing.expectError(error.InvalidSubject, c.publishMessage(.{ .subject = "foo", .reply_to = "a b" }));
    try testing.expectError(error.InvalidSubject, c.publishMessage(.{ .subject = "foo", .reply_to = "" }));
    try testing.expectError(error.InvalidHeader, c.publishMessage(.{ .subject = "foo", .headers = &.{.{ .name = "Bad:Name", .value = "v" }} }));
    try testing.expectError(error.InvalidHeader, c.publishMessage(.{ .subject = "foo", .headers = &.{.{ .name = "X", .value = "a\r\nInjected: 1" }} }));
    try r.finish();
    try testing.expectEqualStrings("PING\r\n", r.transcript.items);
}

test "headers need a server that announced them" {
    var r: Recorded = undefined;
    try r.start(info_without_headers, .{ .servers = &.{} });
    defer r.deinit();
    try testing.expectError(error.UnsupportedFeature, r.client.publishMessage(.{ .subject = "foo", .headers = &.{.{ .name = "X", .value = "1" }} }));
    try r.client.publish("foo", "plain");
    try r.finish();
    try testing.expectEqualStrings("PUB foo 5\r\nplain\r\nPING\r\n", r.transcript.items);
}

test "headers and payload up to max_payload pass, a byte more is PayloadTooLarge" {
    var r: Recorded = undefined;
    try r.start(info_small, .{ .servers = &.{} });
    defer r.deinit();
    const payload: [1025]u8 = @splat('x');
    try r.client.publish("big", payload[0..1024]);
    try testing.expectError(error.PayloadTooLarge, r.client.publish("big", &payload));
    // The header block counts too: 18 bytes of it, 1006 of payload.
    const one: []const nats.Header = &.{.{ .name = "A", .value = "b" }};
    try r.client.publishMessage(.{ .subject = "big", .headers = one, .payload = payload[0..1006] });
    try testing.expectError(error.PayloadTooLarge, r.client.publishMessage(.{ .subject = "big", .headers = one, .payload = payload[0..1007] }));
    try r.finish();
    try testing.expectEqualStrings("PUB big 1024\r\n" ++ payload[0..1024] ++ "\r\n" ++
        "HPUB big 18 1024\r\nNATS/1.0\r\nA: b\r\n\r\n" ++ payload[0..1006] ++ "\r\n" ++
        "PING\r\n", r.transcript.items);
}

test "a server that gives no max_payload, or 0, sets no limit" {
    const payload: [4096]u8 = @splat('y');
    for ([_][]const u8{ info_no_limit, info_zero_limit }) |info| {
        var r: Recorded = undefined;
        try r.start(info, .{ .servers = &.{} });
        defer r.deinit();
        try r.client.publish("s", &payload);
        try r.finish();
        try testing.expectEqualStrings("PUB s 4096\r\n" ++ payload ++ "\r\nPING\r\n", r.transcript.items);
    }
}

test "a line of 4096 argument bytes passes, one more is InvalidSubject" {
    var r: Recorded = undefined;
    try r.start(golden.info_default, .{ .servers = &.{} });
    defer r.deinit();
    const subject: [4095]u8 = @splat('s');
    // PUB <subject> 0: the server counts the subject, a space and a digit.
    try r.client.publish(subject[0..4094], "");
    try testing.expectError(error.InvalidSubject, r.client.publish(&subject, ""));
    // HPUB <subject> r 18 18: the reply subject and both sizes count too.
    const one: []const nats.Header = &.{.{ .name = "A", .value = "b" }};
    try r.client.publishMessage(.{ .subject = subject[0..4088], .reply_to = "r", .headers = one });
    try testing.expectError(error.InvalidSubject, r.client.publishMessage(.{ .subject = subject[0..4089], .reply_to = "r", .headers = one }));
    try r.finish();
    try testing.expectEqualStrings("PUB " ++ subject[0..4094] ++ " 0\r\n\r\n" ++
        "HPUB " ++ subject[0..4088] ++ " r 18 18\r\nNATS/1.0\r\nA: b\r\n\r\n\r\n" ++
        "PING\r\n", r.transcript.items);
}

/// A handshake, then nothing is read until `release` is set.
fn serveStalled(io: Io, listener: *net.Server, release: *Io.Event) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try handshake(&peer, info_huge);
    try awaitEvent(io, release);
    _ = try peer.readToEnd();
}

/// Waits until `event` is set, for 5 s at most.
fn awaitEvent(io: Io, event: *Io.Event) !void {
    const give_up = time.after(io, .fromSeconds(5 * @as(i64, test_wait.timeoutFactor())));
    while (!event.isSet()) {
        event.waitTimeout(io, .{ .deadline = give_up }) catch |err| switch (err) {
            // Io.Event reports a spurious wakeup as Timeout too.
            error.Timeout => if (time.expired(io, give_up)) return error.TestEventNeverSet,
            error.Canceled => return err,
        };
    }
}

fn elapsedSince(io: Io, start: Io.Timestamp) Io.Duration {
    return start.durationTo(Io.Clock.awake.now(io));
}

/// Publishes `payload` until a publish fails.
fn publishUntilError(client: *Client, payload: []const u8) Client.PublishError!void {
    while (true) try client.publish("stalled", payload);
}

/// Waits until a publish is stuck: the writer is blocked on its socket
/// write (the stall) and a put waits for room behind it.
fn awaitStuck(client: *Client) !void {
    try test_wait.waitFlag(testing.io, "the client's socket write stalled", StallingIo.blocked());
    try test_wait.waitUntil(testing.io, "a put waits for room", client, struct {
        fn waits(c: *Client) bool {
            return c.outbound.roomWaiters(testing.io) >= 1;
        }
    }.waits);
}

/// A client whose writer blocks on its first socket write after the
/// handshake (StallingIo): with an outbound limit of 1 byte, the frame it
/// writes fills the queue, and the next waits for room.
const Stalled = struct {
    listener: net.Server,
    release: Io.Event = .unset,
    server: Io.Future(anyerror!void),
    url: [64]u8 = undefined,
    client: Client,
    payload: []u8,

    fn start(s: *Stalled) !void {
        const io = testing.io;
        s.listener = try FakeServer.listen(io);
        errdefer s.listener.deinit(io);
        s.release = .unset;
        s.server = try io.concurrent(serveStalledAny, .{ io, &s.listener, &s.release });
        errdefer {
            s.release.set(io);
            s.server.cancel(io) catch {};
        }
        s.client = try .init(testing.allocator, StallingIo.io(), .{
            .servers = &.{try FakeServer.url(&s.listener, &s.url)},
            .limits = .{ .outbound_bytes = 1 },
        });
        errdefer s.client.deinit();
        try s.client.connect();
        s.payload = try testing.allocator.alloc(u8, 64);
        @memset(s.payload, 'b');
        StallingIo.arm();
    }

    /// The writer's socket write goes on, and the server reads again.
    fn unstall(s: *Stalled) void {
        StallingIo.release();
        s.release.set(testing.io);
    }

    fn deinit(s: *Stalled) void {
        const io = testing.io;
        s.unstall();
        s.client.deinit();
        StallingIo.reset();
        s.server.cancel(io) catch {};
        s.listener.deinit(io);
        testing.allocator.free(s.payload);
    }
};

fn serveStalledAny(io: Io, listener: *net.Server, release: *Io.Event) anyerror!void {
    return serveStalled(io, listener, release);
}

test "a publish that waits for room in the outbound queue can be canceled" {
    const io = testing.io;
    var s: Stalled = undefined;
    try s.start();
    defer s.deinit();
    var publisher = try io.concurrent(publishUntilError, .{ &s.client, s.payload });
    defer publisher.cancel(io) catch {};
    try awaitStuck(&s.client);
    try testing.expectError(error.Canceled, publisher.cancel(io));
    try testing.expect(s.client.isConnected());
}

test "close() while a publish waits for room: ConnectionClosed at once" {
    const io = testing.io;
    var s: Stalled = undefined;
    try s.start();
    defer s.deinit();
    var publisher = try io.concurrent(publishUntilError, .{ &s.client, s.payload });
    defer publisher.cancel(io) catch {};
    try awaitStuck(&s.client);
    const start = Io.Clock.awake.now(io);
    s.client.close();
    try testing.expectError(error.ConnectionClosed, publisher.await(io));
    if (test_wait.timing()) try testing.expect(elapsedSince(io, start).toSeconds() < 1);
}

fn waitFor(duration: Io.Duration) Io.Timeout {
    return .{ .duration = .{ .raw = duration, .clock = .awake } };
}

test "publishMessageTimeout gives up waiting for room at its timeout, and the client goes on" {
    const io = testing.io;
    var s: Stalled = undefined;
    try s.start();
    defer s.deinit();
    var publisher = try io.concurrent(publishUntilError, .{ &s.client, s.payload });
    defer publisher.cancel(io) catch {};
    try awaitStuck(&s.client);
    const out = s.client.stats().messages_out;
    const start = Io.Clock.awake.now(io);
    try testing.expectError(error.Timeout, s.client.publishMessageTimeout(.{ .subject = "stalled", .payload = "late" }, waitFor(.fromMilliseconds(100))));
    const took = elapsedSince(io, start);
    try testing.expect(took.toMilliseconds() >= 100);
    if (test_wait.timing()) try testing.expect(took.toSeconds() < 5);
    // Nothing went in, and only the stuck publish waits for room.
    try testing.expectEqual(out, s.client.stats().messages_out);
    try testing.expectEqual(1, s.client.outbound.roomWaiters(io));
    try testing.expect(s.client.isConnected());
}

fn publishWithin(client: *Client, timeout: Io.Timeout) Client.PublishTimeoutError!void {
    return client.publishMessageTimeout(.{ .subject = "stalled", .payload = "x" }, timeout);
}

test "publishMessageTimeout waiting for room can be canceled" {
    const io = testing.io;
    var s: Stalled = undefined;
    try s.start();
    defer s.deinit();
    var publisher = try io.concurrent(publishUntilError, .{ &s.client, s.payload });
    defer publisher.cancel(io) catch {};
    try awaitStuck(&s.client);
    var timed = try io.concurrent(publishWithin, .{ &s.client, waitFor(.fromSeconds(60)) });
    defer timed.cancel(io) catch {};
    try awaitRoomWaiters(&s.client, 2);
    try testing.expectError(error.Canceled, timed.cancel(io));
    try testing.expect(s.client.isConnected());
}

test "publishMessageTimeout sends what publishMessage sends; a timeout already over sends nothing" {
    var r: Recorded = undefined;
    try r.start(golden.info_default, .{ .servers = &.{} });
    defer r.deinit();
    try r.client.publishMessageTimeout(.{ .subject = "foo", .reply_to = "reply.to", .payload = "x" }, waitFor(.fromSeconds(5)));
    try r.client.publishMessageTimeout(.{ .subject = "h", .headers = &.{.{ .name = "K", .value = "v" }}, .payload = "p" }, .none);
    try testing.expectError(error.Timeout, r.client.publishMessageTimeout(.{ .subject = "foo", .payload = "never" }, waitFor(.zero)));
    // The arguments are checked first, as by publishMessage.
    try testing.expectError(error.InvalidSubject, r.client.publishMessageTimeout(.{ .subject = "foo bar" }, waitFor(.zero)));
    try r.finish();
    try testing.expectEqualStrings("PUB foo reply.to 1\r\nx\r\n" ++
        "HPUB h 18 19\r\nNATS/1.0\r\nK: v\r\n\r\np\r\n" ++
        "PING\r\n", r.transcript.items);
}

fn subscribeOnce(client: *Client) Client.SubscribeError!void {
    const sub = try client.subscribe("late.sub", .{});
    sub.deinit();
}

/// Waits until `count` puts wait for room, for 5 s at most.
fn awaitRoomWaiters(client: *Client, count: u32) !void {
    const io = client.io;
    const give_up = time.after(io, .fromSeconds(5 * @as(i64, test_wait.timeoutFactor())));
    while (client.outbound.roomWaiters(io) < count) {
        if (time.expired(io, give_up)) return error.TestNeverWaited;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "a subscribe waiting for room behind a publish: close() ends both, nothing stays registered" {
    const io = testing.io;
    var s: Stalled = undefined;
    try s.start();
    defer s.deinit();
    var publisher = try io.concurrent(publishUntilError, .{ &s.client, s.payload });
    defer publisher.cancel(io) catch {};
    try awaitStuck(&s.client);
    var subscriber = try io.concurrent(subscribeOnce, .{&s.client});
    defer subscriber.cancel(io) catch {};
    try awaitRoomWaiters(&s.client, 2);
    s.client.close();
    try testing.expectError(error.ConnectionClosed, publisher.await(io));
    try testing.expectError(error.ConnectionClosed, subscriber.await(io));
    try testing.expectEqual(0, s.client.subscriptions.count(io));
}

test "a subscribe waiting for room can be canceled, and is not registered" {
    const io = testing.io;
    var s: Stalled = undefined;
    try s.start();
    defer s.deinit();
    var publisher = try io.concurrent(publishUntilError, .{ &s.client, s.payload });
    defer publisher.cancel(io) catch {};
    try awaitStuck(&s.client);
    var subscriber = try io.concurrent(subscribeOnce, .{&s.client});
    defer subscriber.cancel(io) catch {};
    try awaitRoomWaiters(&s.client, 2);
    try testing.expectError(error.Canceled, subscriber.cancel(io));
    try testing.expectEqual(0, s.client.subscriptions.count(io));
    try testing.expect(s.client.isConnected());
}

test "a subscribe with a timeout gives up waiting for room at it, and is not registered" {
    const io = testing.io;
    var s: Stalled = undefined;
    try s.start();
    defer s.deinit();
    var publisher = try io.concurrent(publishUntilError, .{ &s.client, s.payload });
    defer publisher.cancel(io) catch {};
    try awaitStuck(&s.client);
    const start = Io.Clock.awake.now(io);
    try testing.expectError(error.Timeout, s.client.subscribe("late.sub", .{ .timeout = waitFor(.fromMilliseconds(100)) }));
    const took = elapsedSince(io, start);
    try testing.expect(took.toMilliseconds() >= 100);
    if (test_wait.timing()) try testing.expect(took.toSeconds() < 5);
    // Nothing stays, and only the stuck publish waits for room.
    try testing.expectEqual(0, s.client.subscriptions.count(io));
    try testing.expectEqual(1, s.client.outbound.roomWaiters(io));
    try testing.expect(s.client.isConnected());
}

test "subscribe sends SUB; a queue group and max_messages go along" {
    var r: Recorded = undefined;
    try r.start(golden.info_default, .{ .servers = &.{} });
    defer r.deinit();
    const plain = try r.client.subscribe("foo", .{});
    // A timeout changes nothing while there is room.
    const grouped = try r.client.subscribe("q.work", .{ .queue = "workers", .timeout = waitFor(.fromSeconds(5)) });
    defer grouped.deinit();
    const once = try r.client.subscribe("once.*", .{ .max_messages = 3 });
    defer once.deinit();
    try testing.expectEqual(1, plain.sid);
    try testing.expectEqual(2, grouped.sid);
    try testing.expectEqual(3, once.sid);
    try testing.expectEqualStrings("q.work", grouped.subject);
    try testing.expectEqualStrings("workers", grouped.queue_group.?);
    // deinit tells the server.
    plain.deinit();
    try r.finish();
    try testing.expectEqualStrings("SUB foo 1\r\n" ++
        "SUB q.work workers 2\r\n" ++
        "SUB once.* 3\r\nUNSUB 3 3\r\n" ++
        "UNSUB 1\r\n" ++
        "PING\r\n", r.transcript.items);
}

test "SIDs are never reused" {
    var r: Recorded = undefined;
    try r.start(golden.info_default, .{ .servers = &.{} });
    defer r.deinit();
    const first = try r.client.subscribe("a", .{});
    first.deinit();
    const second = try r.client.subscribe("a", .{});
    defer second.deinit();
    try testing.expectEqual(2, second.sid);
    try r.finish();
    try testing.expectEqualStrings("SUB a 1\r\nUNSUB 1\r\nSUB a 2\r\nPING\r\n", r.transcript.items);
}

test "no more subscriptions than limits.max_subscriptions at once" {
    var r: Recorded = undefined;
    try r.start(golden.info_default, .{ .servers = &.{}, .limits = .{ .max_subscriptions = 2 } });
    defer r.deinit();
    const a = try r.client.subscribe("a", .{});
    const b = try r.client.subscribe("b", .{});
    defer b.deinit();
    try testing.expectError(error.TooManySubscriptions, r.client.subscribe("c", .{}));
    a.deinit();
    const c = try r.client.subscribe("c", .{});
    defer c.deinit();
    try r.finish();
    try testing.expectEqualStrings("SUB a 1\r\nSUB b 2\r\nUNSUB 1\r\nSUB c 3\r\nPING\r\n", r.transcript.items);
}

test "subscribe refuses bad subjects and options before anything is queued" {
    var r: Recorded = undefined;
    try r.start(golden.info_default, .{ .servers = &.{} });
    defer r.deinit();
    const c = &r.client;
    for ([_][]const u8{ "", "foo bar", "foo.>.bar", ">.foo", "foo..bar", "foo\r\nPUB x 1" }) |subject| {
        try testing.expectError(error.InvalidSubject, c.subscribe(subject, .{}));
    }
    for ([_]nats.SubscribeOptions{
        .{ .queue = "two words" },
        .{ .queue = "" },
        .{ .max_messages = 0 },
        .{ .max_messages = 1_000_000_000 },
        .{ .pending = .{ .messages = 0 } },
        .{ .pending = .{ .bytes = 0 } },
    }) |options| {
        try testing.expectError(error.InvalidOptions, c.subscribe("foo", options));
    }
    try r.finish();
    try testing.expectEqualStrings("PING\r\n", r.transcript.items);
}

test "a SUB line of 4096 argument bytes passes, one more is InvalidSubject" {
    var r: Recorded = undefined;
    try r.start(golden.info_default, .{ .servers = &.{} });
    defer r.deinit();
    // SUB <subject> 1: the server counts the subject, a space and the SID.
    const subject: [4095]u8 = @splat('s');
    const sub = try r.client.subscribe(subject[0..4094], .{});
    defer sub.deinit();
    try testing.expectError(error.InvalidSubject, r.client.subscribe(&subject, .{}));
    try r.finish();
    try testing.expectEqualStrings("SUB " ++ subject[0..4094] ++ " 1\r\nPING\r\n", r.transcript.items);
}

/// What a scripted server does after the handshake.
const Step = union(enum) {
    /// Waits for this line from the client; PINGs on the way get PONGs.
    expect: []const u8,
    send: []const u8,
    /// Closes the connection at once.
    hang_up,
};

/// After the handshake, plays `steps` in order; then answers PINGs until
/// the client hangs up.
fn serveScript(io: Io, listener: *net.Server, info: []const u8, steps: []const Step) anyerror!void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try handshake(&peer, info);
    for (steps) |step| switch (step) {
        .expect => |expected| while (true) {
            const line = try peer.readLine();
            if (std.mem.eql(u8, line, "PING")) {
                try peer.send(golden.pong);
                continue;
            }
            try testing.expectEqualStrings(expected, line);
            break;
        },
        .send => |bytes| try peer.send(bytes),
        .hang_up => return,
    };
    while (try peer.nextLine()) |line| {
        if (std.mem.eql(u8, line, "PING")) try peer.send(golden.pong);
    }
}

/// A client connected to a scripted server. Initialize in place.
const Scripted = struct {
    listener: net.Server,
    server: Io.Future(anyerror!void),
    url: [64]u8 = undefined,
    client: Client,

    fn start(s: *Scripted, gpa: std.mem.Allocator, options: nats.Options, steps: []const Step) !void {
        const io = testing.io;
        s.listener = try FakeServer.listen(io);
        errdefer s.listener.deinit(io);
        s.server = try io.concurrent(serveScript, .{ io, &s.listener, golden.info_default, steps });
        errdefer s.server.cancel(io) catch {};
        var with_server = options;
        with_server.servers = &.{try FakeServer.url(&s.listener, &s.url)};
        s.client = try .init(gpa, io, with_server);
        errdefer s.client.deinit();
        try s.client.connect();
    }

    /// Closes the client and checks that the server played its script.
    fn finish(s: *Scripted) !void {
        s.client.close();
        try s.server.await(testing.io);
    }

    fn deinit(s: *Scripted) void {
        const io = testing.io;
        s.client.deinit();
        s.server.cancel(io) catch {};
        s.listener.deinit(io);
    }
};

/// An HMSG frame with one header, `X: <value>`: its block takes 17 bytes
/// more than the value.
fn hmsgFrame(comptime subject: []const u8, comptime sid: u64, comptime value: []const u8, comptime payload: []const u8) []const u8 {
    const block = "NATS/1.0\r\nX: " ++ value ++ "\r\n\r\n";
    return std.fmt.comptimePrint("HMSG {s} {d} {d} {d}\r\n", .{ subject, sid, block.len, block.len + payload.len }) ++ block ++ payload ++ "\r\n";
}

const within_five_seconds: nats.ReceiveOptions = .{ .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } } };

/// Takes the next message of `sub` and checks its subject and payload.
fn expectMessage(sub: *nats.Subscription, subject: []const u8, payload: []const u8) !void {
    var msg = (try sub.next(within_five_seconds)) orelse return error.TestNoMessage;
    defer msg.deinit();
    try testing.expectEqualStrings(subject, msg.subject);
    try testing.expectEqualStrings(payload, msg.payload);
}

test "messages reach their subscriptions whole" {
    var s: Scripted = undefined;
    try s.start(testing.allocator, .{ .servers = &.{} }, &.{
        .{ .expect = "SUB foo 1" },
        .{ .expect = "SUB h.* 2" },
        .{ .send = "MSG foo 1 5\r\nhello\r\n" ++
            "HMSG h.test 2 r.1 53 61\r\nNATS/1.0\r\nX-Multi: one\r\nX-Multi: two\r\nX-Single: v\r\n\r\npayload!\r\n" ++
            "MSG foo 1 reply.to.me 15\r\n\r\nMSG x 1 1\r\n\x00\xff\r\n" },
    });
    defer s.deinit();
    const foo = try s.client.subscribe("foo", .{});
    defer foo.deinit();
    const h = try s.client.subscribe("h.*", .{});
    defer h.deinit();

    try expectMessage(foo, "foo", "hello");
    {
        var msg = (try h.next(within_five_seconds)) orelse return error.TestNoMessage;
        defer msg.deinit();
        try testing.expectEqualStrings("h.test", msg.subject);
        try testing.expectEqualStrings("r.1", msg.reply_to.?);
        try testing.expectEqualStrings("payload!", msg.payload);
        var values = msg.headers.getAll("X-Multi");
        try testing.expectEqualStrings("one", values.next().?);
        try testing.expectEqualStrings("two", values.next().?);
        try testing.expectEqualStrings("v", msg.headers.get("X-Single").?);
    }
    {
        // A payload that looks like frames, and binary bytes.
        var msg = (try foo.next(within_five_seconds)) orelse return error.TestNoMessage;
        defer msg.deinit();
        try testing.expectEqualStrings("reply.to.me", msg.reply_to.?);
        try testing.expectEqualStrings("\r\nMSG x 1 1\r\n\x00\xff", msg.payload);
    }
    try s.finish();
}

test "a message for a SID nobody has is dropped, and the next one arrives" {
    var s: Scripted = undefined;
    try s.start(testing.allocator, .{ .servers = &.{} }, &.{
        .{ .expect = "SUB foo 1" },
        .{ .send = "MSG foo 99 3\r\nabc\r\nHMSG foo 98 12 12\r\nNATS/1.0\r\n\r\n\r\nMSG foo 1 2\r\nok\r\n" },
    });
    defer s.deinit();
    const foo = try s.client.subscribe("foo", .{});
    defer foo.deinit();
    try expectMessage(foo, "foo", "ok");
    try s.finish();
}

test "a message at max_inbound_frame_bytes arrives, a byte more is dropped, and the next is whole" {
    // The client warns about the messages it drops; this test expects it.
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    const at_limit: [1024]u8 = @splat('a');
    var s: Scripted = undefined;
    try s.start(testing.allocator, .{ .servers = &.{}, .limits = .{ .max_inbound_frame_bytes = 1024, .max_header_bytes = 512 } }, &.{
        .{ .expect = "SUB big 1" },
        .{ .send = "MSG big 1 1024\r\n" ++ at_limit ++ "\r\n" ++
            "MSG big 1 1025\r\n" ++ at_limit ++ "b\r\n" ++
            comptime hmsgFrame("big", 1, at_limit[0..997], at_limit[0..11]) ++
                "MSG big 1 5\r\nafter\r\n" },
    });
    defer s.deinit();
    const big = try s.client.subscribe("big", .{});
    defer big.deinit();
    try expectMessage(big, "big", &at_limit);
    try expectMessage(big, "big", "after");
    try s.finish();
}

test "a header block over max_header_bytes is dropped, and the next message is whole" {
    // The client warns about the messages it drops; this test expects it.
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    const filler: [600]u8 = @splat('h');
    var s: Scripted = undefined;
    try s.start(testing.allocator, .{ .servers = &.{}, .limits = .{ .max_inbound_frame_bytes = 4096, .max_header_bytes = 512 } }, &.{
        .{ .expect = "SUB h 1" },
        // 512 bytes of headers pass, 513 do not.
        .{ .send = comptime hmsgFrame("h", 1, filler[0..495], "ok") ++ hmsgFrame("h", 1, filler[0..496], "no") ++ "MSG h 1 5\r\nafter\r\n" },
    });
    defer s.deinit();
    const h = try s.client.subscribe("h", .{});
    defer h.deinit();
    try expectMessage(h, "h", "ok");
    try expectMessage(h, "h", "after");
    try s.finish();
}

/// Passes allocations on, except every one of exactly `size` bytes.
const RefuseOneSize = struct {
    parent: std.mem.Allocator,
    size: usize,

    fn allocator(r: *RefuseOneSize) std.mem.Allocator {
        return .{ .ptr = r, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const r: *RefuseOneSize = @ptrCast(@alignCast(context));
        if (len == r.size) return null;
        return r.parent.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const r: *RefuseOneSize = @ptrCast(@alignCast(context));
        return r.parent.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const r: *RefuseOneSize = @ptrCast(@alignCast(context));
        return r.parent.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const r: *RefuseOneSize = @ptrCast(@alignCast(context));
        r.parent.rawFree(memory, alignment, ret_addr);
    }
};

test "a message there is no memory for is dropped, and the next one arrives" {
    // The client warns about the messages it drops; this test expects it.
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    const payload: [12342]u8 = @splat('m');
    // "oom" and this payload: one allocation of 12345 bytes, refused.
    var refuse: RefuseOneSize = .{ .parent = testing.allocator, .size = "oom".len + payload.len };
    var s: Scripted = undefined;
    try s.start(refuse.allocator(), .{ .servers = &.{} }, &.{
        .{ .expect = "SUB oom 1" },
        .{ .send = "MSG oom 1 12342\r\n" ++ payload ++ "\r\nMSG oom 1 2\r\nok\r\n" },
    });
    defer s.deinit();
    const sub = try s.client.subscribe("oom", .{});
    defer sub.deinit();
    try expectMessage(sub, "oom", "ok");
    try s.finish();
}

test "max_messages counts the messages dropped too, then the subscription ends" {
    // The client warns about the messages it drops; this test expects it.
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var s: Scripted = undefined;
    try s.start(testing.allocator, .{ .servers = &.{} }, &.{
        .{ .expect = "SUB once 1" },
        .{ .expect = "UNSUB 1 3" },
        .{ .send = "MSG once 1 1\r\na\r\nMSG once 1 1\r\nb\r\nMSG once 1 1\r\nc\r\n" },
    });
    defer s.deinit();
    // One message fits; the other two are dropped, yet they count.
    const once = try s.client.subscribe("once", .{ .max_messages = 3, .pending = .{ .messages = 1 } });
    defer once.deinit();
    try s.client.flush(quick);
    const give_up = time.after(testing.io, .fromSeconds(5 * @as(i64, test_wait.timeoutFactor())));
    while (once.messages.isOpen(testing.io)) {
        if (time.expired(testing.io, give_up)) return error.TestNeverEnded;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try expectMessage(once, "once", "a");
    try testing.expect(try once.next(within_five_seconds) == null);
    try s.finish();
}

test "a message cut short by the server is freed" {
    var s: Scripted = undefined;
    try s.start(testing.allocator, .{ .servers = &.{}, .reconnect = .{ .enabled = false } }, &.{
        .{ .expect = "SUB foo 1" },
        .{ .send = "MSG foo 1 100\r\nonly a part of it" },
        .hang_up,
    });
    defer s.deinit();
    const foo = try s.client.subscribe("foo", .{});
    defer foo.deinit();
    // With reconnect off the client closes with the connection;
    // testing.allocator reports the message if it leaks.
    try testing.expectError(error.ConnectionClosed, foo.next(within_five_seconds));
    try s.server.await(testing.io);
}

/// Waits until `sub` has received `count` messages, for 5 s at most.
fn awaitReceived(sub: *nats.Subscription, count: u64) !void {
    const io = testing.io;
    const give_up = time.after(io, .fromSeconds(5 * @as(i64, test_wait.timeoutFactor())));
    while (sub.stats().received < count) {
        if (time.expired(io, give_up)) return error.TestMessagesNeverCame;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

const briefly: nats.ReceiveOptions = .{ .timeout = .{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } } };

test "unsubscribe tells the server, drops what waits, and next returns null" {
    var s: Scripted = undefined;
    try s.start(testing.allocator, .{ .servers = &.{} }, &.{
        .{ .expect = "SUB foo 1" },
        .{ .send = "MSG foo 1 1\r\na\r\nMSG foo 1 1\r\nb\r\n" },
        .{ .expect = "UNSUB 1" },
    });
    defer s.deinit();
    const foo = try s.client.subscribe("foo", .{});
    defer foo.deinit();
    try awaitReceived(foo, 2);
    try testing.expectEqual(nats.PendingCounts{ .messages = 2, .bytes = 8 }, foo.pending());
    try foo.unsubscribe();
    try testing.expect(try foo.next(within_five_seconds) == null);
    try testing.expectEqual(nats.PendingCounts{ .messages = 0, .bytes = 0 }, foo.pending());
    try testing.expectEqual(nats.SubscriptionStats{ .received = 2, .delivered = 0, .dropped = 0 }, foo.stats());
    // Again: nothing more is sent.
    try foo.unsubscribe();
    try s.client.flush(quick);
    try s.finish();
}

const five_messages = "MSG slow 1 1\r\n1\r\nMSG slow 1 1\r\n2\r\nMSG slow 1 1\r\n3\r\nMSG slow 1 1\r\n4\r\nMSG slow 1 1\r\n5\r\n";

test "a slow consumer under drop_newest keeps the first messages" {
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var s: Scripted = undefined;
    try s.start(testing.allocator, .{ .servers = &.{} }, &.{ .{ .expect = "SUB slow 1" }, .{ .send = five_messages } });
    defer s.deinit();
    const slow = try s.client.subscribe("slow", .{ .pending = .{ .messages = 2 } });
    defer slow.deinit();
    try awaitReceived(slow, 5);
    try expectMessage(slow, "slow", "1");
    try expectMessage(slow, "slow", "2");
    try testing.expectError(error.Timeout, slow.next(briefly));
    try testing.expectEqual(nats.SubscriptionStats{ .received = 5, .delivered = 2, .dropped = 3 }, slow.stats());
    try s.finish();
}

test "a slow consumer under drop_oldest keeps the last messages" {
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var s: Scripted = undefined;
    try s.start(testing.allocator, .{ .servers = &.{} }, &.{ .{ .expect = "SUB slow 1" }, .{ .send = five_messages } });
    defer s.deinit();
    const slow = try s.client.subscribe("slow", .{ .pending = .{ .messages = 2 }, .overflow = .drop_oldest });
    defer slow.deinit();
    try awaitReceived(slow, 5);
    try expectMessage(slow, "slow", "4");
    try expectMessage(slow, "slow", "5");
    try testing.expectError(error.Timeout, slow.next(briefly));
    try testing.expectEqual(nats.SubscriptionStats{ .received = 5, .delivered = 2, .dropped = 3 }, slow.stats());
    try s.finish();
}

test "a slow consumer under close_subscription: what came first, then SlowConsumer, and the server is told" {
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var s: Scripted = undefined;
    try s.start(testing.allocator, .{ .servers = &.{} }, &.{
        .{ .expect = "SUB slow 1" },
        .{ .send = five_messages },
        .{ .expect = "UNSUB 1" },
    });
    defer s.deinit();
    const slow = try s.client.subscribe("slow", .{ .pending = .{ .messages = 2 }, .overflow = .close_subscription });
    defer slow.deinit();
    try awaitReceived(slow, 3);
    try expectMessage(slow, "slow", "1");
    try expectMessage(slow, "slow", "2");
    try testing.expectError(error.SlowConsumer, slow.next(within_five_seconds));
    try testing.expectEqual(nats.SubscriptionStats{ .received = 3, .delivered = 2, .dropped = 1 }, slow.stats());
    // deinit sends nothing more: the subscription has ended.
    try s.client.flush(quick);
    try s.finish();
}

test "a subscription the server refuses: PermissionDenied, and the others go on" {
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var s: Scripted = undefined;
    try s.start(testing.allocator, .{ .servers = &.{} }, &.{
        .{ .expect = "SUB forbidden 1" },
        .{ .expect = "SUB ok 2" },
        .{ .send = "-ERR 'Permissions Violation for Subscription to \"forbidden\"'\r\nMSG ok 2 2\r\nhi\r\n" },
    });
    defer s.deinit();
    const forbidden = try s.client.subscribe("forbidden", .{});
    defer forbidden.deinit();
    const ok = try s.client.subscribe("ok", .{});
    defer ok.deinit();
    try testing.expectError(error.PermissionDenied, forbidden.next(within_five_seconds));
    try expectMessage(ok, "ok", "hi");
    try s.client.flush(quick);
    try testing.expect(s.client.isConnected());
    try s.finish();
}

test "a refused subscription is known once a flush after it returns" {
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var s: Scripted = undefined;
    try s.start(testing.allocator, .{ .servers = &.{} }, &.{
        .{ .expect = "SUB forbidden 1" },
        .{ .expect = "SUB ok 2" },
        // Before the PONG of the flush that follows.
        .{ .send = "-ERR 'Permissions Violation for Subscription to \"forbidden\"'\r\n" },
    });
    defer s.deinit();
    const forbidden = try s.client.subscribe("forbidden", .{});
    defer forbidden.deinit();
    const ok = try s.client.subscribe("ok", .{});
    defer ok.deinit();
    try s.client.flush(quick);
    try testing.expect(forbidden.isDenied());
    try testing.expect(!ok.isDenied());
    // Nothing is taken from the subscription to tell.
    try testing.expectError(error.PermissionDenied, forbidden.next(within_five_seconds));
    try testing.expect(forbidden.isDenied());
    // Ended otherwise, it was not refused.
    try ok.unsubscribe();
    try testing.expect(!ok.isDenied());
    try s.finish();
}

test "a refusal names the subscription by SID, or by a subject the server escapes" {
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var s: Scripted = undefined;
    try s.start(testing.allocator, .{ .servers = &.{} }, &.{
        .{ .expect = "SUB dup 1" },
        .{ .expect = "SUB dup 2" },
        .{ .expect = "SUB odd.q\"uo\\te.ü 3" },
        .{ .send = "-ERR 'Permissions Violation for Subscription to \"dup\" (sid \"2\")'\r\n" ++
            "-ERR 'Permissions Violation for Subscription to \"odd.q\\\"uo\\\\te.ü\"'\r\n" ++
            "MSG dup 1 2\r\nhi\r\n" },
    });
    defer s.deinit();
    const first = try s.client.subscribe("dup", .{});
    defer first.deinit();
    const second = try s.client.subscribe("dup", .{});
    defer second.deinit();
    const odd = try s.client.subscribe("odd.q\"uo\\te.ü", .{});
    defer odd.deinit();
    try testing.expectError(error.PermissionDenied, second.next(within_five_seconds));
    try testing.expectError(error.PermissionDenied, odd.next(within_five_seconds));
    try expectMessage(first, "dup", "hi");
    try s.finish();
}

test "a publish the server refuses leaves the connection up" {
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var s: Scripted = undefined;
    try s.start(testing.allocator, .{ .servers = &.{} }, &.{
        .{ .expect = "PUB secret.x 1" },
        .{ .send = "-ERR 'Permissions Violation for Publish to \"secret.x\"'\r\n" },
    });
    defer s.deinit();
    try s.client.publish("secret.x", "x");
    try s.client.flush(quick);
    try s.client.flush(quick);
    try testing.expect(s.client.isConnected());
    try s.finish();
}

/// An HMSG frame with `block` as its header block.
fn hmsgWithBlock(comptime subject: []const u8, comptime sid: u64, comptime block: []const u8, comptime payload: []const u8) []const u8 {
    return std.fmt.comptimePrint("HMSG {s} {d} {d} {d}\r\n", .{ subject, sid, block.len, block.len + payload.len }) ++ block ++ payload ++ "\r\n";
}

test "a broken header block from another publisher: the message arrives whole" {
    var s: Scripted = undefined;
    try s.start(testing.allocator, .{ .servers = &.{} }, &.{
        .{ .expect = "SUB g 1" },
        .{ .send = comptime hmsgWithBlock("g", 1, "garbage line\r\n: no name\r\nX-Id: 1\r\nno colon\r\n\r\n", "first") ++
            hmsgWithBlock("g", 1, "NATS/1.0 abc\r\nX: y\r\n\r\n", "second") },
    });
    defer s.deinit();
    const g = try s.client.subscribe("g", .{});
    defer g.deinit();
    {
        var msg = (try g.next(within_five_seconds)) orelse return error.TestNoMessage;
        defer msg.deinit();
        try testing.expectEqualStrings("first", msg.payload);
        try testing.expectEqualStrings("1", msg.headers.get("X-Id").?);
        try testing.expect(msg.status == null);
    }
    {
        var msg = (try g.next(within_five_seconds)) orelse return error.TestNoMessage;
        defer msg.deinit();
        try testing.expectEqualStrings("second", msg.payload);
        try testing.expectEqualStrings("y", msg.headers.get("X").?);
        try testing.expect(msg.status == null);
    }
    try s.client.flush(quick);
    try s.finish();
}

fn nextLong(sub: *nats.Subscription) nats.Subscription.NextError!?nats.Message {
    return sub.next(.{ .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } } });
}

/// Waits until a task waits in `sub.next()`, for 5 s at most.
fn awaitReceiving(sub: *nats.Subscription) !void {
    const io = testing.io;
    const give_up = time.after(io, .fromSeconds(5 * @as(i64, test_wait.timeoutFactor())));
    while (!sub.messages.isReceiving(io)) {
        if (time.expired(io, give_up)) return error.TestReceiverNeverWaited;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "close() while a task waits in next(): ConnectionClosed at once" {
    const io = testing.io;
    var s: Scripted = undefined;
    try s.start(testing.allocator, .{ .servers = &.{} }, &.{.{ .expect = "SUB idle 1" }});
    defer s.deinit();
    const idle = try s.client.subscribe("idle", .{});
    defer idle.deinit();
    // The server has the SUB its script waits for: close() would drop it
    // while still queued.
    try s.client.flush(quick);
    var receiver = try io.concurrent(nextLong, .{idle});
    defer _ = receiver.cancel(io) catch null;
    try awaitReceiving(idle);
    const start = Io.Clock.awake.now(io);
    s.client.close();
    try testing.expectError(error.ConnectionClosed, receiver.await(io));
    if (test_wait.timing()) try testing.expect(elapsedSince(io, start).toSeconds() < 1);
    try testing.expectError(error.ConnectionClosed, idle.next(.{}));
    try testing.expectError(error.ConnectionClosed, idle.unsubscribe());
    try s.server.await(io);
}

/// Passes allocations on and counts those of exactly `size` bytes.
const CountOneSize = struct {
    parent: std.mem.Allocator,
    size: usize,
    count: std.atomic.Value(u32) = .init(0),

    fn allocator(c: *CountOneSize) std.mem.Allocator {
        return .{ .ptr = c, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const c: *CountOneSize = @ptrCast(@alignCast(context));
        if (len == c.size) _ = c.count.fetchAdd(1, .monotonic);
        return c.parent.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const c: *CountOneSize = @ptrCast(@alignCast(context));
        return c.parent.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const c: *CountOneSize = @ptrCast(@alignCast(context));
        return c.parent.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const c: *CountOneSize = @ptrCast(@alignCast(context));
        c.parent.rawFree(memory, alignment, ret_addr);
    }
};

test "a message larger than its subscription holds is dropped unallocated, and the subscription goes on" {
    // The client warns about the message it drops; this test expects it.
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    const payload: [5000]u8 = @splat('p');
    for ([_]nats.OverflowPolicy{ .drop_newest, .drop_oldest, .close_subscription }) |overflow| {
        // "big" and the payload: one allocation of 5003 bytes, over the 100
        // the subscription holds, though far within max_inbound_frame_bytes.
        var counting: CountOneSize = .{ .parent = testing.allocator, .size = "big".len + payload.len };
        var s: Scripted = undefined;
        try s.start(counting.allocator(), .{ .servers = &.{} }, &.{
            .{ .expect = "SUB big 1" },
            .{ .send = "MSG big 1 1\r\na\r\nMSG big 1 5000\r\n" ++ payload ++ "\r\nMSG big 1 2\r\nok\r\n" },
        });
        defer s.deinit();
        const big = try s.client.subscribe("big", .{ .pending = .{ .bytes = 100 }, .overflow = overflow });
        defer big.deinit();
        try expectMessage(big, "big", "a");
        try expectMessage(big, "big", "ok");
        try testing.expectEqual(nats.SubscriptionStats{ .received = 3, .delivered = 2, .dropped = 1 }, big.stats());
        try testing.expectEqual(0, counting.count.load(.monotonic));
        try s.finish();
    }
}

test "unsubscribe() from another task while next() waits: null at once" {
    const io = testing.io;
    var s: Scripted = undefined;
    try s.start(testing.allocator, .{ .servers = &.{} }, &.{ .{ .expect = "SUB idle 1" }, .{ .expect = "UNSUB 1" } });
    defer s.deinit();
    const idle = try s.client.subscribe("idle", .{});
    defer idle.deinit();
    var receiver = try io.concurrent(nextLong, .{idle});
    defer _ = receiver.cancel(io) catch null;
    try awaitReceiving(idle);
    const start = Io.Clock.awake.now(io);
    try idle.unsubscribe();
    try testing.expect(try receiver.await(io) == null);
    if (test_wait.timing()) try testing.expect(elapsedSince(io, start).toSeconds() < 1);
    try s.client.flush(quick);
    try s.finish();
}

// ---------------------------------------------------------------------------
// The publish that never waits (`publishNow`): what Anole's layer uses.

test "publishNow sends what publishMessage sends and says .ok while the queue has room" {
    var r: Recorded = undefined;
    try r.start(golden.info_default, .{ .servers = &.{} });
    defer r.deinit();
    try testing.expectEqual(.ok, try r.client.publishNow(.{ .subject = "foo", .reply_to = "reply.to", .payload = "x" }));
    try testing.expectEqual(.ok, try r.client.publishNow(.{ .subject = "h", .headers = &.{.{ .name = "K", .value = "v" }}, .payload = "p" }));
    // The arguments are checked first, as by publishMessage.
    try testing.expectError(error.InvalidSubject, r.client.publishNow(.{ .subject = "foo bar" }));
    try testing.expect(r.client.writable());
    try r.finish();
    try testing.expectEqualStrings("PUB foo reply.to 1\r\nx\r\n" ++
        "HPUB h 18 19\r\nNATS/1.0\r\nK: v\r\n\r\np\r\n" ++
        "PING\r\n", r.transcript.items);
}

test "publishNow on a closed client is ConnectionClosed" {
    var r: Recorded = undefined;
    try r.start(golden.info_default, .{ .servers = &.{} });
    defer r.deinit();
    try r.finish();
    try testing.expectError(error.ConnectionClosed, r.client.publishNow(.{ .subject = "foo", .payload = "x" }));
}

test "publishNow past the outbound limit is Full at once: nothing queued, nobody waits, the client goes on" {
    const io = testing.io;
    var s: Stalled = undefined;
    try s.start();
    defer s.deinit();
    // The writer takes the first frame and blocks on the socket (the
    // stall): the frame fills the queue's 1 byte until it is written.
    _ = try s.client.publishNow(.{ .subject = "stalled", .payload = s.payload });
    try test_wait.waitFlag(io, "the client's socket write stalled", StallingIo.blocked());
    try testing.expectError(error.Full, s.client.publishNow(.{ .subject = "stalled", .payload = s.payload }));
    try testing.expect(!s.client.writable());
    const out = s.client.stats().messages_out;
    try testing.expectError(error.Full, s.client.publishNow(.{ .subject = "stalled", .payload = "late" }));
    try testing.expectEqual(out, s.client.stats().messages_out);
    try testing.expectEqual(@as(u32, 0), s.client.outbound.roomWaiters(io));
    try testing.expect(s.client.isConnected());

    // The write goes on: room comes back, and the next publish is taken
    // (.busy: one frame is past half of the 1-byte limit, Outbound.tryPut).
    s.unstall();
    try test_wait.waitUntil(io, "room in the outbound queue", &s, struct {
        fn room(st: *Stalled) bool {
            return st.client.writable();
        }
    }.room);
    try testing.expectEqual(.busy, try s.client.publishNow(.{ .subject = "stalled", .payload = "again" }));
}
