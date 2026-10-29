// Adapted from vkiryakov/zefir src/nats/testing/reliability_tests.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! The pool of servers, reconnect, lame duck, refused credentials, drain,
//! events and statistics against fake servers on loopback. Each test starts
//! its own server function in a task and cancels it on the way out; the
//! client's waits are bounded, so a mistake fails a test instead of hanging
//! it.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const testing = std.testing;
const test_wait = @import("anole_test_wait");
const nats = @import("../root.zig");
const Client = nats.Client;
const FakeServer = @import("FakeServer.zig");
const golden = @import("../protocol/golden.zig");
const time = @import("../engine/time.zig");

const quick: nats.FlushOptions = .{ .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } } };

/// The server's side of the handshake with `info` as its INFO.
fn handshake(peer: *FakeServer.Peer, info: []const u8) !void {
    try peer.send(info);
    const connect_line = try peer.readLine();
    if (!std.mem.startsWith(u8, connect_line, "CONNECT {")) return error.TestNotConnect;
    try peer.expectLine("PING");
    try peer.send(golden.pong);
}

/// Answers every PING until the client hangs up.
fn answerPings(peer: *FakeServer.Peer) !void {
    while (try peer.nextLine()) |line| {
        if (std.mem.eql(u8, line, "PING")) try peer.send(golden.pong);
    }
}

/// Node A of a cluster announces itself and 14235; at the client's next
/// PING, 14235 has left the cluster.
fn serveCluster(io: Io, listener: *net.Server) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try handshake(&peer, "INFO " ++ golden.info_cluster_json ++ " \r\n");
    try peer.expectLine("PING");
    try peer.send("INFO {\"server_id\":\"A\",\"proto\":1,\"headers\":true,\"connect_urls\":[\"127.0.0.1:14234\"]} \r\n" ++ golden.pong);
    try answerPings(&peer);
}

test "the servers a cluster announces join the pool, and leave it when no longer announced" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(serveCluster, .{ io, &listener });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)}, .randomize_servers = false });
    defer client.deinit();
    try client.connect();

    var buffer: [8]nats.ServerAddress = undefined;
    const announced = client.discoveredServers(&buffer);
    try testing.expectEqual(2, announced.len);
    try testing.expectEqual(14234, announced[0].port);
    try testing.expectEqual(14235, announced[1].port);
    // The INFO that drops 14235 comes before the PONG of this flush.
    try client.flush(quick);
    const left = client.discoveredServers(&buffer);
    try testing.expectEqual(1, left.len);
    try testing.expectEqual(14234, left[0].port);
    client.close();
    try server.await(io);
}

test "ignore_discovered_servers keeps the pool to the servers of the options" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(serveCluster, .{ io, &listener });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)}, .ignore_discovered_servers = true });
    defer client.deinit();
    try client.connect();
    try client.flush(quick);
    var buffer: [8]nats.ServerAddress = undefined;
    try testing.expectEqual(0, client.discoveredServers(&buffer).len);
    client.close();
    try server.await(io);
}

/// What a fake server saw of its connections: every line a client sent,
/// a PUB's payload on a line of its own, and `--` between connections.
const Record = struct {
    mutex: Io.Mutex = .init,
    text: std.ArrayList(u8) = .empty,
    /// Connections accepted.
    accepted: std.atomic.Value(u32) = .init(0),
    /// Set by the test when a session that waits for it may go on.
    release: Io.Event = .unset,

    fn note(r: *Record, io: Io, line: []const u8) !void {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        try r.text.appendSlice(testing.allocator, line);
        try r.text.append(testing.allocator, '\n');
    }

    /// What was seen so far; the caller frees it.
    fn seen(r: *Record, io: Io) ![]u8 {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        return testing.allocator.dupe(u8, r.text.items);
    }

    fn deinit(r: *Record) void {
        r.text.deinit(testing.allocator);
    }
};

/// What a fake server does with one connection; the connection closes
/// when it returns.
const Session = *const fn (peer: *FakeServer.Peer, record: *Record) anyerror!void;

/// Plays `sessions` on the connections that come, one each, in turn.
fn serveSessions(io: Io, listener: *net.Server, sessions: []const Session, record: *Record) anyerror!void {
    for (sessions) |session| {
        var peer: FakeServer.Peer = undefined;
        try peer.accept(io, listener);
        defer peer.close();
        _ = record.accepted.fetchAdd(1, .monotonic);
        if (record.accepted.load(.monotonic) > 1) try record.note(io, "--");
        try session(&peer, record);
    }
}

/// The next frame the client sent, noted: a line, and a PUB's or HPUB's
/// payload after it. Null when the client hung up.
fn nextFrame(peer: *FakeServer.Peer, record: *Record) !?[]const u8 {
    const line = (try peer.nextLine()) orelse return null;
    try record.note(peer.io, line);
    if (std.mem.startsWith(u8, line, "PUB ") or std.mem.startsWith(u8, line, "HPUB ")) {
        const size = try std.fmt.parseInt(usize, line[std.mem.findScalarLast(u8, line, ' ').? + 1 ..], 10);
        var body: [256]u8 = undefined;
        if (size + 2 > body.len) return error.TestPayloadTooLong;
        try peer.readExact(body[0 .. size + 2]);
        try record.note(peer.io, body[0..size]);
        return "PUB";
    }
    return line;
}

/// Notes frames until one starts with `prefix`; false when the client hung
/// up first.
fn readUntil(peer: *FakeServer.Peer, record: *Record, prefix: []const u8) !bool {
    while (try nextFrame(peer, record)) |frame| {
        if (std.mem.startsWith(u8, frame, prefix)) return true;
    }
    return false;
}

/// The handshake, then every frame noted and every PING answered until the
/// client hangs up.
fn sessionServe(peer: *FakeServer.Peer, record: *Record) anyerror!void {
    try handshake(peer, golden.info_default);
    while (try nextFrame(peer, record)) |frame| {
        if (std.mem.eql(u8, frame, "PING")) try peer.send(golden.pong);
    }
}

/// Takes the connection and closes it before INFO: a failed attempt.
fn sessionRefuse(peer: *FakeServer.Peer, record: *Record) anyerror!void {
    _ = peer;
    _ = record;
}

/// The handshake, then a hang-up at once.
fn sessionHangUp(peer: *FakeServer.Peer, record: *Record) anyerror!void {
    _ = record;
    try handshake(peer, golden.info_default);
}

/// Two messages for the subscription to `bar`, then a hang-up at the
/// client's next PING.
fn sessionTwoThenHangUp(peer: *FakeServer.Peer, record: *Record) anyerror!void {
    try handshake(peer, golden.info_default);
    if (!try readUntil(peer, record, "SUB bar ")) return error.TestNoSub;
    try peer.send("MSG bar 2 1\r\na\r\nMSG bar 2 1\r\nb\r\n");
    if (!try readUntil(peer, record, "PING")) return error.TestNoPing;
}

/// Waits until the client reaches `expected`, for 5 s at most.
fn awaitState(client: *Client, expected: nats.State) !void {
    const io = client.io;
    const give_up = time.after(io, .fromSeconds(5 * @as(i64, test_wait.timeoutFactor())));
    while (client.state() != expected) {
        if (time.expired(io, give_up)) return error.TestStateNeverReached;
        try io.sleep(.fromMilliseconds(2), .awake);
    }
}

const within_five_seconds: nats.ReceiveOptions = .{ .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } } };

fn expectMessage(sub: *nats.Subscription, payload: []const u8) !void {
    var msg = (try sub.next(within_five_seconds)) orelse return error.TestNoMessage;
    defer msg.deinit();
    try testing.expectEqualStrings(payload, msg.payload);
}

fn requestLong(client: *Client) Client.RequestError!nats.Message {
    return client.request("service.x", "?", .{ .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } } });
}

fn releaseReply(result: Client.RequestError!nats.Message) void {
    var reply = result catch return;
    reply.deinit();
}

/// Waits until `count` requests wait for replies, for 5 s at most.
fn awaitAwaiting(client: *Client, count: u32) !void {
    const io = client.io;
    const give_up = time.after(io, .fromSeconds(5 * @as(i64, test_wait.timeoutFactor())));
    while (client.inbox.awaitingCount(io) < count) {
        if (time.expired(io, give_up)) return error.TestRequestNeverWaited;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "a lost connection: the client reconnects and subscribes again with the same SIDs, the inbox too" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{ sessionTwoThenHangUp, sessionServe };
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();

    const foo = try client.subscribe("foo", .{});
    defer foo.deinit();
    const bar = try client.subscribe("bar", .{ .max_messages = 5 });
    defer bar.deinit();
    var request = try io.concurrent(requestLong, .{&client});
    defer releaseReply(request.cancel(io));
    try awaitAwaiting(&client, 1);
    try expectMessage(bar, "a");
    try expectMessage(bar, "b");
    // The server hangs up at this PING: the flush and the waiting request
    // learn it at once.
    try testing.expectError(error.Disconnected, client.flush(quick));
    if (request.await(io)) |_| return error.TestUnexpectedReply else |err| try testing.expectEqual(error.Disconnected, err);

    try awaitState(&client, .connected);
    try client.publish("after", "x");
    try client.flush(quick);
    client.close();
    try server.await(io);

    const seen = try record.seen(io);
    defer testing.allocator.free(seen);
    const second = seen[std.mem.find(u8, seen, "--\n").? + 3 ..];
    // SUBs with their SIDs, the inbox's, then what max_messages leaves;
    // then the new frames.
    var lines = std.mem.splitScalar(u8, second, '\n');
    try testing.expectEqualStrings("SUB foo 1", lines.next().?);
    try testing.expectEqualStrings("SUB bar 2", lines.next().?);
    const inbox_sub = lines.next().?;
    try testing.expect(std.mem.startsWith(u8, inbox_sub, "SUB _INBOX.") and std.mem.endsWith(u8, inbox_sub, ".* 3"));
    try testing.expectEqualStrings("UNSUB 2 3", lines.next().?);
    try testing.expectEqualStrings("PUB after 1", lines.next().?);
    try testing.expectEqualStrings("x", lines.next().?);
    try testing.expectEqualStrings("PING", lines.next().?);
    // The inbox kept its subject.
    try testing.expect(std.mem.find(u8, seen[0 .. seen.len - second.len], inbox_sub) != null);
}

/// Waits until the client is connected to the server on `port`, for 5 s
/// at most.
fn awaitServer(client: *Client, port: u16) !void {
    const io = client.io;
    const give_up = time.after(io, .fromSeconds(5 * @as(i64, test_wait.timeoutFactor())));
    while (true) {
        if (client.connectedServer()) |server| if (server.port == port) return;
        if (time.expired(io, give_up)) return error.TestNeverMoved;
        try io.sleep(.fromMilliseconds(2), .awake);
    }
}

/// Waits until the server accepted `count` connections, for 5 s at most.
fn awaitAccepted(record: *Record, count: u32) !void {
    const give_up = time.after(testing.io, .fromSeconds(5 * @as(i64, test_wait.timeoutFactor())));
    while (record.accepted.load(.monotonic) < count) {
        if (time.expired(testing.io, give_up)) return error.TestNeverAccepted;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
}

const fast_reconnect: nats.ReconnectOptions = .{ .min_delay = .fromMilliseconds(1), .max_delay = .fromMilliseconds(5) };

test "after max_attempts failed attempts in a row the client gives up and closes" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{ sessionHangUp, sessionRefuse, sessionRefuse, sessionRefuse, sessionServe };
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var reconnect = fast_reconnect;
    reconnect.max_attempts = 3;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)}, .reconnect = reconnect });
    defer client.deinit();
    try client.connect();
    try awaitState(&client, .closed);
    try testing.expectError(error.ConnectionClosed, client.publish("foo", "x"));
    // The connection, then three attempts; the fifth session never comes.
    try testing.expectEqual(4, record.accepted.load(.monotonic));
}

fn sessionEarly(peer: *FakeServer.Peer, record: *Record) anyerror!void {
    try handshake(peer, golden.info_default);
    if (!try readUntil(peer, record, "SUB early 1")) return error.TestNoSub;
    try peer.send("MSG early 1 2\r\nhi\r\n");
    try answerPings(peer);
}

test "retry_initial_connect: connect() returns at once, and the client connects in the background" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{ sessionRefuse, sessionRefuse, sessionEarly };
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{
        .servers = &.{try FakeServer.url(&listener, &url)},
        .retry_initial_connect = true,
        .reconnect = fast_reconnect,
    });
    defer client.deinit();
    try client.connect();
    // A subscription made before the first connection goes out with it.
    const early = try client.subscribe("early", .{});
    defer early.deinit();
    try expectMessage(early, "hi");
    try testing.expectEqual(.connected, client.state());
    try testing.expectEqual(3, record.accepted.load(.monotonic));
    client.close();
    try server.await(io);
}

/// Takes every connection and closes it before INFO, until canceled.
fn serveRefusing(io: Io, listener: *net.Server, record: *Record) anyerror!void {
    while (true) {
        var peer: FakeServer.Peer = undefined;
        try peer.accept(io, listener);
        _ = record.accepted.fetchAdd(1, .monotonic);
        peer.close();
    }
}

test "with retry_initial_connect, close() stops the attempts at once" {
    const io = testing.io;
    // Every attempt fails at once; a closed port would not do: Windows
    // takes seconds to refuse a connection on loopback.
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    var server = try io.concurrent(serveRefusing, .{ io, &listener, &record });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)}, .retry_initial_connect = true });
    defer client.deinit();
    try client.connect();
    try testing.expectEqual(.reconnecting, client.state());
    try testing.expectError(error.Disconnected, client.flush(quick));
    // After a failed attempt the client waits about half a second before
    // the next; close() does not wait for it.
    try awaitAccepted(&record, 1);
    const start = Io.Clock.awake.now(io);
    client.close();
    try testing.expectEqual(.closed, client.state());
    if (test_wait.timing()) try testing.expect(start.durationTo(Io.Clock.awake.now(io)).toMilliseconds() < 300);
    // And no attempt after it (the logical claim; the time bound above
    // holds only on a machine that is not stalled).
    try test_wait.expectStays(io, "no connection attempt after close()", &record, struct {
        fn one(r: *Record) bool {
            return r.accepted.load(.monotonic) == 1;
        }
    }.one, test_wait.short_window);
}

/// Hangs up as soon as the client subscribed to `sub`.
fn sessionHangUpAfterSub(peer: *FakeServer.Peer, record: *Record) anyerror!void {
    try handshake(peer, golden.info_default);
    if (!try readUntil(peer, record, "SUB sub ")) return error.TestNoSub;
}

/// Says nothing until the test releases it, then serves: notes every
/// frame, answers PINGs, and answers each request to `service.x` with
/// "ok" on the inbox the client subscribed.
fn sessionAnswerWhenReleased(peer: *FakeServer.Peer, record: *Record) anyerror!void {
    try record.release.wait(peer.io);
    try handshake(peer, golden.info_default);
    var inbox_sid: [20]u8 = undefined;
    var inbox_sid_len: usize = 0;
    while (try peer.nextLine()) |line| {
        try record.note(peer.io, line);
        if (std.mem.eql(u8, line, "PING")) {
            try peer.send(golden.pong);
        } else if (std.mem.startsWith(u8, line, "SUB _INBOX.")) {
            const sid = line[std.mem.findScalarLast(u8, line, ' ').? + 1 ..];
            @memcpy(inbox_sid[0..sid.len], sid);
            inbox_sid_len = sid.len;
        } else if (std.mem.startsWith(u8, line, "PUB ")) {
            var words = std.mem.splitScalar(u8, line, ' ');
            _ = words.next();
            const subject = words.next().?;
            const third = words.next().?;
            const reply = if (words.next()) |_| third else null;
            const size = try std.fmt.parseInt(usize, line[std.mem.findScalarLast(u8, line, ' ').? + 1 ..], 10);
            var body: [64]u8 = undefined;
            try peer.readExact(body[0 .. size + 2]);
            try record.note(peer.io, body[0..size]);
            if (std.mem.eql(u8, subject, "service.x")) {
                var frame: [128]u8 = undefined;
                try peer.send(try std.fmt.bufPrint(&frame, "MSG {s} {s} 2\r\nok\r\n", .{ reply.?, inbox_sid[0..inbox_sid_len] }));
            }
        }
    }
}

fn requestService(client: *Client) Client.RequestError!nats.Message {
    return client.request("service.x", "?", .{ .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } } });
}

test "while reconnecting, publishes and a request wait in the reconnect buffer and go out after the subscriptions" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{ sessionHangUpAfterSub, sessionAnswerWhenReleased };
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer {
        record.release.set(io);
        server.cancel(io) catch {};
    }
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{
        .servers = &.{try FakeServer.url(&listener, &url)},
        .reconnect = .{ .buffer_bytes = 1024 },
    });
    defer client.deinit();
    try client.connect();
    const sub = try client.subscribe("sub", .{});
    defer sub.deinit();

    // The server hung up; the next one says nothing until released.
    try awaitState(&client, .reconnecting);
    try awaitAccepted(&record, 2);
    try client.publish("buffered", "1");
    try client.publish("buffered", "2");
    const too_big: [2000]u8 = @splat('x');
    try testing.expectError(error.BufferFull, client.publish("buffered", &too_big));
    try testing.expectError(error.Disconnected, client.flush(quick));
    var request = try io.concurrent(requestService, .{&client});
    var awaited = false;
    defer if (!awaited) releaseReply(request.cancel(io));
    try awaitAwaiting(&client, 1);

    record.release.set(io);
    awaited = true;
    var reply = try request.await(io);
    defer reply.deinit();
    try testing.expectEqualStrings("ok", reply.payload);
    try client.flush(quick);
    try testing.expectEqual(.connected, client.state());
    client.close();
    try server.await(io);

    const seen = try record.seen(io);
    defer testing.allocator.free(seen);
    const second = seen[std.mem.find(u8, seen, "--\n").? + 3 ..];
    var lines = std.mem.splitScalar(u8, second, '\n');
    try testing.expectEqualStrings("SUB sub 1", lines.next().?);
    const inbox_sub = lines.next().?;
    try testing.expect(std.mem.startsWith(u8, inbox_sub, "SUB _INBOX.") and std.mem.endsWith(u8, inbox_sub, ".* 2"));
    for ([_][]const u8{ "PUB buffered 1", "1", "PUB buffered 1", "2" }) |expected| try testing.expectEqualStrings(expected, lines.next().?);
    try testing.expect(std.mem.startsWith(u8, lines.next().?, "PUB service.x _INBOX."));
}

test "with reconnect.buffer_bytes 0, publishes and requests fail with Disconnected while reconnecting" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{ sessionHangUpAfterSub, sessionAnswerWhenReleased };
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer {
        record.release.set(io);
        server.cancel(io) catch {};
    }
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{
        .servers = &.{try FakeServer.url(&listener, &url)},
        .reconnect = .{ .buffer_bytes = 0 },
    });
    defer client.deinit();
    try client.connect();
    const sub = try client.subscribe("sub", .{});
    defer sub.deinit();
    try awaitState(&client, .reconnecting);
    try testing.expectError(error.Disconnected, client.publish("buffered", "1"));
    try testing.expectError(error.Disconnected, client.request("service.x", "?", .{}));
    try testing.expectError(error.Disconnected, client.flush(quick));
    // A subscription goes out once connected again, buffer or not.
    const later = try client.subscribe("later", .{});
    defer later.deinit();
    record.release.set(io);
    try awaitState(&client, .connected);
    try client.flush(quick);
    client.close();
    try server.await(io);
    const seen = try record.seen(io);
    defer testing.allocator.free(seen);
    try testing.expect(std.mem.find(u8, seen, "--\nSUB sub 1\nSUB later 2\n") != null);
    try testing.expect(std.mem.find(u8, seen, "PUB buffered") == null);
}

/// A connection the server refuses with `-ERR` and `text`, after INFO and
/// the client's CONNECT and PING.
fn refuseWith(peer: *FakeServer.Peer, comptime text: []const u8) !void {
    try peer.send(golden.info_default);
    _ = try peer.readLine();
    try peer.expectLine("PING");
    try peer.send("-ERR '" ++ text ++ "'\r\n");
}

fn sessionRefuseViolation(peer: *FakeServer.Peer, record: *Record) anyerror!void {
    _ = record;
    try refuseWith(peer, "Authorization Violation");
}

fn sessionRefuseExpired(peer: *FakeServer.Peer, record: *Record) anyerror!void {
    _ = record;
    try refuseWith(peer, "User Authentication Expired");
}

/// The handshake, then, as when the password changes on the server, the
/// credentials no longer pass: `-ERR 'Authorization Violation'` and a
/// hang-up.
fn sessionRevoke(peer: *FakeServer.Peer, record: *Record) anyerror!void {
    _ = record;
    try handshake(peer, golden.info_default);
    try peer.send(golden.err_authorization);
}

fn quietly(comptime body: fn () anyerror!void) anyerror!void {
    // The client logs every -ERR as a warning; these tests expect them.
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    return body();
}

fn twoRefusals() anyerror!void {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{ sessionRevoke, sessionRefuseViolation, sessionServe };
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{
        .servers = &.{try FakeServer.url(&listener, &url)},
        .auth = .{ .user_password = .{ .username = "alice", .password = "old" } },
        .reconnect = fast_reconnect,
    });
    defer client.deinit();
    try client.connect();
    // Refused on the connection, then again by the first attempt: closed.
    try awaitState(&client, .closed);
    try testing.expectEqual(2, record.accepted.load(.monotonic));
}

test "a server that refuses the credentials twice the same way in a row closes the client" {
    try quietly(twoRefusals);
}

fn refusalsGoOn() anyerror!void {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{ sessionRevoke, sessionRefuseViolation, sessionRefuseViolation, sessionServe };
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var reconnect = fast_reconnect;
    reconnect.abort_on_auth_error = false;
    var client: Client = try .init(testing.allocator, io, .{
        .servers = &.{try FakeServer.url(&listener, &url)},
        .auth = .{ .user_password = .{ .username = "alice", .password = "secret" } },
        .reconnect = reconnect,
    });
    defer client.deinit();
    try client.connect();
    try awaitAccepted(&record, 4);
    try awaitState(&client, .connected);
    try client.flush(quick);
}

test "with abort_on_auth_error false, refused attempts go on until one passes" {
    try quietly(refusalsGoOn);
}

fn differentRefusals() anyerror!void {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{ sessionRevoke, sessionRefuseExpired, sessionRefuse, sessionRefuseViolation, sessionServe };
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{
        .servers = &.{try FakeServer.url(&listener, &url)},
        .auth = .{ .user_password = .{ .username = "alice", .password = "secret" } },
        .reconnect = fast_reconnect,
    });
    defer client.deinit();
    try client.connect();
    // Violation, then Expired, then a failure of another kind, then
    // Violation: never the same twice in a row.
    try awaitAccepted(&record, 5);
    try awaitState(&client, .connected);
    try client.flush(quick);
}

test "refusals of another kind, or a failure between them, do not stop the attempts" {
    try quietly(differentRefusals);
}

/// The handshake; once the client subscribed, INFO says the server is
/// about to go away and names the other server; then it waits for the
/// client to leave.
fn serveLameDuck(io: Io, listener: *net.Server, other_port: u16) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try handshake(&peer, golden.info_default);
    var record: Record = .{};
    defer record.deinit();
    if (!try readUntil(&peer, &record, "SUB sub 1")) return error.TestNoSub;
    var info: [256]u8 = undefined;
    try peer.send(try std.fmt.bufPrint(&info, "INFO {{\"server_id\":\"A\",\"proto\":1,\"headers\":true,\"ldm\":true,\"connect_urls\":[\"127.0.0.1:{d}\"]}} \r\n", .{other_port}));
    // The client leaves at once, without waiting for the server to close.
    while (try peer.nextLine()) |_| {}
}

test "lame duck mode: the client moves to another server at once, and subscribes there again" {
    const io = testing.io;
    var going = try FakeServer.listen(io);
    defer going.deinit(io);
    var staying = try FakeServer.listen(io);
    defer staying.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{sessionServe};
    var other = try io.concurrent(serveSessions, .{ io, &staying, &sessions, &record });
    defer other.cancel(io) catch {};
    var first = try io.concurrent(serveLameDuck, .{ io, &going, staying.socket.address.getPort() });
    defer first.cancel(io) catch {};
    var urls: [2][64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{
        .servers = &.{ try FakeServer.url(&going, &urls[0]), try FakeServer.url(&staying, &urls[1]) },
        .randomize_servers = false,
    });
    defer client.deinit();
    try client.connect();
    const sub = try client.subscribe("sub", .{});
    defer sub.deinit();
    try awaitServer(&client, staying.socket.address.getPort());
    // The server going away ends once the client left it.
    try first.await(io);
    try client.flush(quick);
    client.close();
    try other.await(io);
    const seen = try record.seen(io);
    defer testing.allocator.free(seen);
    try testing.expect(std.mem.startsWith(u8, seen, "SUB sub 1\n"));
}

/// What a request to `service.x` asked: the reply subject, and the SID of
/// the inbox it goes to.
const Pending = struct {
    reply: [64]u8 = undefined,
    reply_len: usize = 0,
    inbox_sid: [20]u8 = undefined,
    inbox_sid_len: usize = 0,

    /// Notes the inbox's SID or the request's reply subject from `line`.
    fn note(p: *Pending, line: []const u8) void {
        if (std.mem.startsWith(u8, line, "SUB _INBOX.")) {
            const sid = line[std.mem.findScalarLast(u8, line, ' ').? + 1 ..];
            @memcpy(p.inbox_sid[0..sid.len], sid);
            p.inbox_sid_len = sid.len;
        } else if (std.mem.startsWith(u8, line, "PUB service.x ")) {
            var words = std.mem.splitScalar(u8, line, ' ');
            _ = words.next();
            _ = words.next();
            const reply = words.next().?;
            @memcpy(p.reply[0..reply.len], reply);
            p.reply_len = reply.len;
        }
    }

    fn answer(p: *Pending, peer: *FakeServer.Peer) !void {
        var frame: [128]u8 = undefined;
        try peer.send(try std.fmt.bufPrint(&frame, "MSG {s} {s} 2\r\nok\r\n", .{ p.reply[0..p.reply_len], p.inbox_sid[0..p.inbox_sid_len] }));
    }
};

/// Two messages once the client subscribes to `work`; at the first PING
/// after its UNSUB, a third one that was on its way, and the answer to the
/// request waiting, then the PONG.
fn sessionDrain(peer: *FakeServer.Peer, record: *Record) anyerror!void {
    try handshake(peer, golden.info_default);
    var pending: Pending = .{};
    var unsubscribed = false;
    var late_sent = false;
    while (try peer.nextLine()) |line| {
        try record.note(peer.io, line);
        pending.note(line);
        if (std.mem.startsWith(u8, line, "PUB ")) {
            const size = try std.fmt.parseInt(usize, line[std.mem.findScalarLast(u8, line, ' ').? + 1 ..], 10);
            var body: [64]u8 = undefined;
            try peer.readExact(body[0 .. size + 2]);
            try record.note(peer.io, body[0..size]);
        } else if (std.mem.startsWith(u8, line, "SUB work ")) {
            try peer.send("MSG work 1 1\r\n1\r\nMSG work 1 1\r\n2\r\n");
        } else if (std.mem.eql(u8, line, "UNSUB 1")) {
            unsubscribed = true;
        } else if (std.mem.eql(u8, line, "PING")) {
            if (unsubscribed and !late_sent) {
                try peer.send("MSG work 1 1\r\n3\r\n");
                try pending.answer(peer);
                late_sent = true;
            }
            try peer.send(golden.pong);
        }
    }
}

fn drainClient(client: *Client, timeout: Io.Duration) Client.DrainError!void {
    return client.drain(.{ .timeout = .{ .duration = .{ .raw = timeout, .clock = .awake } } });
}

fn awaitReceived(sub: *nats.Subscription, count: u64) !void {
    const give_up = time.after(testing.io, .fromSeconds(5 * @as(i64, test_wait.timeoutFactor())));
    while (sub.stats().received < count) {
        if (time.expired(testing.io, give_up)) return error.TestNeverReceived;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "drain: subscriptions stop and are read to their end, publishes still go out, then it all flushes and the client closes" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{sessionDrain};
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();
    const work = try client.subscribe("work", .{});
    defer work.deinit();
    var request = try io.concurrent(requestService, .{&client});
    var awaited = false;
    defer if (!awaited) releaseReply(request.cancel(io));
    try awaitAwaiting(&client, 1);
    try awaitReceived(work, 2);

    var drainer = try io.concurrent(drainClient, .{ &client, Io.Duration.fromSeconds(5) });
    defer drainer.cancel(io) catch {};
    try awaitState(&client, .draining);
    // Phase one: no new work, but handlers may still answer.
    try testing.expectError(error.ConnectionDraining, client.subscribe("more", .{}));
    try testing.expectError(error.ConnectionDraining, client.request("service.x", "?", .{}));
    try testing.expectError(error.ConnectionDraining, client.drain(.{}));
    try expectMessage(work, "1");
    try expectMessage(work, "2");
    try client.publish("done", "2");
    // The message on its way when the server took the UNSUB comes too.
    try expectMessage(work, "3");
    try testing.expect(try work.next(within_five_seconds) == null);
    awaited = true;
    var reply = try request.await(io);
    defer reply.deinit();
    try testing.expectEqualStrings("ok", reply.payload);

    try drainer.await(io);
    try testing.expectEqual(.closed, client.state());
    try testing.expectEqual(.drained, client.close_reason.?);
    try testing.expectError(error.ConnectionClosed, client.publish("late", "x"));
    try server.await(io);
    const seen = try record.seen(io);
    defer testing.allocator.free(seen);
    const unsub = std.mem.find(u8, seen, "UNSUB 1\n").?;
    const done = std.mem.find(u8, seen, "PUB done 1\n2\n").?;
    try testing.expect(unsub < done);
    // The last PING flushes what the handlers published.
    try testing.expect(std.mem.endsWith(u8, seen, "PING\n"));
}

fn sessionMessageThenServe(peer: *FakeServer.Peer, record: *Record) anyerror!void {
    try handshake(peer, golden.info_default);
    if (!try readUntil(peer, record, "SUB work ")) return error.TestNoSub;
    try peer.send("MSG work 1 1\r\n1\r\n");
    while (try nextFrame(peer, record)) |frame| {
        if (std.mem.eql(u8, frame, "PING")) try peer.send(golden.pong);
    }
}

test "a drain that runs out of time closes the client anyway, with Timeout" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{sessionMessageThenServe};
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();
    const work = try client.subscribe("work", .{});
    defer work.deinit();
    try awaitReceived(work, 1);
    // Nobody reads the subscription.
    try testing.expectError(error.Timeout, drainClient(&client, .fromMilliseconds(200)));
    try testing.expectEqual(.closed, client.state());
    try testing.expectEqual(.drain_failed, client.close_reason.?);
    try testing.expectError(error.ConnectionClosed, work.next(.{}));
}

/// Hangs up at the drain's PING.
fn sessionHangUpAtDrain(peer: *FakeServer.Peer, record: *Record) anyerror!void {
    try handshake(peer, golden.info_default);
    if (!try readUntil(peer, record, "UNSUB 1")) return error.TestNoUnsub;
    if (!try readUntil(peer, record, "PING")) return error.TestNoPing;
}

test "a connection lost during a drain closes the client, with Disconnected" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{ sessionHangUpAtDrain, sessionServe };
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();
    const work = try client.subscribe("work", .{});
    defer work.deinit();
    try testing.expectError(error.Disconnected, drainClient(&client, .fromSeconds(5)));
    try testing.expectEqual(.closed, client.state());
    try testing.expectEqual(.connection_lost, client.close_reason.?);
    // It did not reconnect.
    try testing.expectEqual(1, record.accepted.load(.monotonic));
}

test "a drain without a connection closes the client, with Disconnected" {
    var client: Client = try .init(testing.allocator, testing.io, .{ .servers = &.{"nats://127.0.0.1:4222"} });
    defer client.deinit();
    try testing.expectError(error.Disconnected, client.drain(.{}));
    try testing.expectEqual(.closed, client.state());
    // Nothing was lost: it never connected.
    try testing.expectEqual(.closed, client.close_reason.?);
    try testing.expectError(error.ConnectionClosed, client.drain(.{}));
}

/// At the first PING after the client's UNSUB of `work`, a message that
/// was on its way, then the PONG; then serves.
fn sessionSubDrain(peer: *FakeServer.Peer, record: *Record) anyerror!void {
    try handshake(peer, golden.info_default);
    if (!try readUntil(peer, record, "UNSUB 1")) return error.TestNoUnsub;
    if (!try readUntil(peer, record, "PING")) return error.TestNoPing;
    try peer.send("MSG work 1 1\r\nx\r\n" ++ golden.pong);
    while (try nextFrame(peer, record)) |frame| {
        if (std.mem.eql(u8, frame, "PING")) try peer.send(golden.pong);
    }
}

fn drainSubscription(sub: *nats.Subscription) nats.Subscription.DrainError!void {
    return sub.drain(.{ .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } } });
}

test "a subscription drains: what is on its way comes, then null, and the client goes on" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{sessionSubDrain};
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();
    const work = try client.subscribe("work", .{});
    defer work.deinit();
    var drainer = try io.concurrent(drainSubscription, .{work});
    defer drainer.cancel(io) catch {};
    try expectMessage(work, "x");
    try testing.expect(try work.next(within_five_seconds) == null);
    try drainer.await(io);
    try testing.expect(client.isConnected());
    // Drained already: again, nothing to do.
    try work.drain(.{});
    try client.flush(quick);
}

/// At every PING after an UNSUB, a message for that SID that was on its
/// way, then the PONG; notes every frame.
fn sessionDrainEach(peer: *FakeServer.Peer, record: *Record) anyerror!void {
    try handshake(peer, golden.info_default);
    var sid: [20]u8 = undefined;
    var sid_len: usize = 0;
    while (try nextFrame(peer, record)) |frame| {
        if (std.mem.startsWith(u8, frame, "UNSUB ")) {
            const unsubscribed = frame["UNSUB ".len..];
            @memcpy(sid[0..unsubscribed.len], unsubscribed);
            sid_len = unsubscribed.len;
        } else if (std.mem.eql(u8, frame, "PING")) {
            if (sid_len > 0) {
                var msg: [64]u8 = undefined;
                try peer.send(try std.fmt.bufPrint(&msg, "MSG work {s} 1\r\nx\r\n", .{sid[0..sid_len]}));
                sid_len = 0;
            }
            try peer.send(golden.pong);
        }
    }
}

/// Reads the subscription to its end, the way its own doc shows: the
/// subscription is freed once next() returns null.
fn readThenFree(sub: *nats.Subscription, got: *u32) nats.Subscription.NextError!void {
    defer sub.deinit();
    while (try sub.next(within_five_seconds)) |message| {
        var msg = message;
        msg.deinit();
        got.* += 1;
    }
}

/// One subscription drained by this task while another reads it and frees
/// it at null.
fn drainWhileReaderFrees(client: *Client) !void {
    const io = client.io;
    const sub = try client.subscribe("work", .{});
    var got: u32 = 0;
    var reader = try io.concurrent(readThenFree, .{ sub, &got });
    defer reader.cancel(io) catch {};
    try drainSubscription(sub);
    try reader.await(io);
    try testing.expectEqual(1, got);
}

test "a reader may free its subscription at null while another task drains it" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{sessionDrainEach};
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();
    // deinit() waits for the drain, which must not touch the subscription
    // once it is freed; the testing allocator finds what is left behind.
    for (0..20) |_| try drainWhileReaderFrees(&client);
    try client.flush(quick);
}

/// Notes `line`: the session reached it.
fn awaitSeen(record: *Record, text: []const u8) !void {
    const give_up = time.after(testing.io, .fromSeconds(5 * @as(i64, test_wait.timeoutFactor())));
    while (true) {
        const seen = try record.seen(testing.io);
        defer testing.allocator.free(seen);
        if (std.mem.find(u8, seen, text) != null) return;
        if (time.expired(testing.io, give_up)) return error.TestNeverSeen;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
}

/// Waits until `count` drain() calls are inside the subscription.
fn awaitDrainers(sub: *nats.Subscription, count: u32) !void {
    const give_up = time.after(testing.io, .fromSeconds(5 * @as(i64, test_wait.timeoutFactor())));
    while (sub.messages.drainers.load(.acquire) < count) {
        if (time.expired(testing.io, give_up)) return error.TestNoDrainer;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
}

/// Holds the PONG of the first PING after `UNSUB 1` until the test releases
/// it; then a message that was on its way, the PONG, and serves.
fn sessionHoldDrainPong(peer: *FakeServer.Peer, record: *Record) anyerror!void {
    try handshake(peer, golden.info_default);
    if (!try readUntil(peer, record, "UNSUB 1")) return error.TestNoUnsub;
    if (!try readUntil(peer, record, "PING")) return error.TestNoPing;
    try record.note(peer.io, "held");
    try record.release.wait(peer.io);
    try peer.send("MSG work 1 1\r\nx\r\n" ++ golden.pong);
    while (try nextFrame(peer, record)) |frame| {
        if (std.mem.eql(u8, frame, "PING")) try peer.send(golden.pong);
    }
}

fn drainClientLong(client: *Client) Client.DrainError!void {
    return drainClient(client, .fromSeconds(5));
}

test "a second drain of a draining subscription waits for the first: what is on its way is kept" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{sessionHoldDrainPong};
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer {
        record.release.set(io);
        server.cancel(io) catch {};
    }
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();
    const work = try client.subscribe("work", .{});
    defer work.deinit();
    var first = try io.concurrent(drainSubscription, .{work});
    defer first.cancel(io) catch {};
    try awaitSeen(&record, "held");
    var second = try io.concurrent(drainSubscription, .{work});
    defer second.cancel(io) catch {};
    try awaitDrainers(work, 2);
    record.release.set(io);
    try expectMessage(work, "x");
    try testing.expect(try work.next(within_five_seconds) == null);
    try first.await(io);
    try second.await(io);
    try testing.expectEqual(nats.SubscriptionStats{ .received = 1, .delivered = 1, .dropped = 0 }, work.stats());
}

test "a subscription drained during the client's drain keeps what is on its way" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{sessionHoldDrainPong};
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer {
        record.release.set(io);
        server.cancel(io) catch {};
    }
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();
    const work = try client.subscribe("work", .{});
    defer work.deinit();
    var whole = try io.concurrent(drainClientLong, .{&client});
    defer whole.cancel(io) catch {};
    try awaitSeen(&record, "held");
    var one = try io.concurrent(drainSubscription, .{work});
    defer one.cancel(io) catch {};
    try awaitDrainers(work, 1);
    record.release.set(io);
    try expectMessage(work, "x");
    try testing.expect(try work.next(within_five_seconds) == null);
    try one.await(io);
    try whole.await(io);
    try testing.expectEqual(.drained, client.close_reason.?);
    try testing.expectEqual(nats.SubscriptionStats{ .received = 1, .delivered = 1, .dropped = 0 }, work.stats());
}

/// Never answers the PING after `UNSUB 1`; reads on until released.
fn sessionNoDrainPong(peer: *FakeServer.Peer, record: *Record) anyerror!void {
    try handshake(peer, golden.info_default);
    if (!try readUntil(peer, record, "UNSUB 1")) return error.TestNoUnsub;
    if (!try readUntil(peer, record, "PING")) return error.TestNoPing;
    try record.note(peer.io, "held");
    try record.release.wait(peer.io);
}

test "a subscription drain that runs out of time returns Timeout, and the subscription has ended" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{sessionNoDrainPong};
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer {
        record.release.set(io);
        server.cancel(io) catch {};
    }
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();
    const work = try client.subscribe("work", .{});
    defer work.deinit();
    try testing.expectError(error.Timeout, work.drain(.{ .timeout = .{ .duration = .{ .raw = .fromMilliseconds(200), .clock = .awake } } }));
    try testing.expect(try work.next(.{}) == null);
    // Ended and read: nothing more to wait for.
    try work.drain(.{});
    try testing.expect(client.isConnected());
}

fn drainSubscriptionResult(sub: *nats.Subscription) nats.Subscription.DrainError!void {
    return drainSubscription(sub);
}

test "close() during a subscription drain: ConnectionClosed; a canceled drain: Canceled, and it has ended" {
    const io = testing.io;
    for ([_]bool{ true, false }) |by_close| {
        var listener = try FakeServer.listen(io);
        defer listener.deinit(io);
        var record: Record = .{};
        defer record.deinit();
        const sessions = [_]Session{sessionNoDrainPong};
        var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
        defer {
            record.release.set(io);
            server.cancel(io) catch {};
        }
        var url: [64]u8 = undefined;
        var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
        defer client.deinit();
        try client.connect();
        const work = try client.subscribe("work", .{});
        defer work.deinit();
        var drainer = try io.concurrent(drainSubscriptionResult, .{work});
        defer drainer.cancel(io) catch {};
        try awaitSeen(&record, "held");
        if (by_close) {
            client.close();
            try testing.expectError(error.ConnectionClosed, drainer.await(io));
        } else {
            try testing.expectError(error.Canceled, drainer.cancel(io));
            try testing.expect(try work.next(.{}) == null);
            try testing.expect(client.isConnected());
        }
    }
}

/// Subscribes `work`, then hangs up.
fn sessionHangUpAfterWork(peer: *FakeServer.Peer, record: *Record) anyerror!void {
    try handshake(peer, golden.info_default);
    if (!try readUntil(peer, record, "SUB work ")) return error.TestNoSub;
}

test "a subscription drained while reconnecting ends at once, and the next connection does not subscribe it" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{ sessionHangUpAfterWork, sessionRecordWhenReleased };
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer {
        record.release.set(io);
        server.cancel(io) catch {};
    }
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{
        .servers = &.{try FakeServer.url(&listener, &url)},
        .reconnect = .{ .min_delay = .fromMilliseconds(1), .max_delay = .fromMilliseconds(5) },
    });
    defer client.deinit();
    try client.connect();
    const work = try client.subscribe("work", .{});
    defer work.deinit();
    const other = try client.subscribe("other", .{});
    defer other.deinit();
    try awaitState(&client, .reconnecting);
    try awaitAccepted(&record, 2);
    try work.drain(.{ .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } } });
    try testing.expect(try work.next(.{}) == null);
    record.release.set(io);
    try awaitState(&client, .connected);
    try client.flush(quick);
    client.close();
    try server.await(io);
    const seen = try record.seen(io);
    defer testing.allocator.free(seen);
    const second = seen[std.mem.find(u8, seen, "--\n").? + 3 ..];
    try testing.expect(std.mem.find(u8, second, "SUB work") == null);
    try testing.expect(std.mem.find(u8, second, "SUB other 2") != null);
}

/// A message with a reply subject once the client subscribes to `work`;
/// holds the PONG of the second PING after `UNSUB 1`, the drain's last
/// barrier, until the test releases it.
fn sessionHoldLastBarrier(peer: *FakeServer.Peer, record: *Record) anyerror!void {
    try handshake(peer, golden.info_default);
    var unsubscribed = false;
    var pings: u32 = 0;
    while (try nextFrame(peer, record)) |frame| {
        if (std.mem.startsWith(u8, frame, "SUB work ")) {
            try peer.send("MSG work 1 reply.me 1\r\n1\r\n");
        } else if (std.mem.eql(u8, frame, "UNSUB 1")) {
            unsubscribed = true;
        } else if (std.mem.eql(u8, frame, "PING")) {
            if (unsubscribed) pings += 1;
            if (pings == 2) {
                try record.note(peer.io, "held");
                try record.release.wait(peer.io);
            }
            try peer.send(golden.pong);
        }
    }
}

test "drain, second phase: publishes and responds fail with ConnectionDraining until the client closes" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{sessionHoldLastBarrier};
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer {
        record.release.set(io);
        server.cancel(io) catch {};
    }
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();
    const work = try client.subscribe("work", .{});
    defer work.deinit();
    var request = (try work.next(within_five_seconds)) orelse return error.TestNoMessage;
    defer request.deinit();
    var drainer = try io.concurrent(drainClientLong, .{&client});
    defer drainer.cancel(io) catch {};
    try awaitState(&client, .draining);
    // First phase: the handler answers what it took.
    try client.respond(&request, "early");
    try testing.expect(try work.next(within_five_seconds) == null);
    // Second phase: the last PING is out, and nothing more goes in.
    try awaitSeen(&record, "held");
    try testing.expectError(error.ConnectionDraining, client.publish("late", "x"));
    try testing.expectError(error.ConnectionDraining, client.publishMessage(.{ .subject = "late", .headers = &.{.{ .name = "X", .value = "1" }}, .payload = "x" }));
    try testing.expectError(error.ConnectionDraining, client.respond(&request, "late"));
    try testing.expectError(error.ConnectionDraining, client.subscribe("more", .{}));
    try testing.expectError(error.ConnectionDraining, client.request("service.x", "?", .{}));
    // The connection is up all the while.
    try testing.expect(client.isConnected());
    try testing.expect(client.connectedServer() != null);
    var info = (try client.serverInfo(testing.allocator)) orelse return error.TestNoInfo;
    info.deinit();
    record.release.set(io);
    try drainer.await(io);
    try testing.expect(!client.isConnected());
    try testing.expectEqual(.drained, client.close_reason.?);
    try server.await(io);
    const seen = try record.seen(io);
    defer testing.allocator.free(seen);
    try testing.expect(std.mem.find(u8, seen, "PUB reply.me 5\nearly\n") != null);
    try testing.expect(std.mem.find(u8, seen, "late") == null);
}

/// What a slow server saw of a drain under load.
const SlowDrain = struct {
    /// The test lets the server read.
    go: std.atomic.Value(bool) = .init(false),
    pings: std.atomic.Value(u32) = .init(0),
    /// PUBs read before the second PING after `go`: the drain's last one.
    before_last: std.atomic.Value(u32) = .init(0),
    total: std.atomic.Value(u32) = .init(0),

    /// Reads nothing until `go`; at the first PING after it, holds its
    /// PONG and then stops reading for a while, so the queue is full when
    /// the drain sends its last PING.
    fn serve(d: *SlowDrain, io: Io, listener: *net.Server) !void {
        var peer: FakeServer.Peer = undefined;
        try peer.accept(io, listener);
        defer peer.close();
        try handshake(&peer, golden.info_default);
        try test_wait.waitFlag(io, "the test to let the server read", &d.go);
        var pubs: u32 = 0;
        while (try peer.nextLine()) |line| {
            if (std.mem.startsWith(u8, line, "PUB ")) {
                const size = try std.fmt.parseInt(usize, line[std.mem.findScalarLast(u8, line, ' ').? + 1 ..], 10);
                try peer.reader.interface.discardAll(size + 2);
                pubs += 1;
            } else if (std.mem.eql(u8, line, "PING")) {
                const n = d.pings.fetchAdd(1, .monotonic) + 1;
                if (n == 2) d.before_last.store(pubs, .monotonic);
                if (n == 1) try io.sleep(.fromMilliseconds(300), .awake);
                try peer.send(golden.pong);
                if (n == 1) try io.sleep(.fromMilliseconds(300), .awake);
            }
        }
        d.total.store(pubs, .monotonic);
    }
};

/// Publishes 32 KiB payloads until one fails; counts those that went in.
fn publishUntilRefused(client: *Client, payload: []const u8, published: *std.atomic.Value(u32)) void {
    while (true) {
        client.publish("load", payload) catch return;
        _ = published.fetchAdd(1, .monotonic);
    }
}

test "drain: a publish that waits for room as publishes stop fails, and every publish that went in is confirmed" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var slow: SlowDrain = .{};
    var server = try io.concurrent(SlowDrain.serve, .{ &slow, io, &listener });
    defer {
        slow.go.store(true, .release);
        server.cancel(io) catch {};
    }
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{
        .servers = &.{try FakeServer.url(&listener, &url)},
        .limits = .{ .outbound_bytes = 64 * 1024 },
    });
    defer client.deinit();
    try client.connect();
    const payload = try testing.allocator.alloc(u8, 32 * 1024);
    defer testing.allocator.free(payload);
    @memset(payload, 'p');
    var published: std.atomic.Value(u32) = .init(0);
    var publisher = try io.concurrent(publishUntilRefused, .{ &client, payload, &published });
    defer publisher.cancel(io);
    try awaitRoomWaitersOf(&client, 1);
    var drainer = try io.concurrent(drainClient, .{ &client, Io.Duration.fromSeconds(10) });
    defer drainer.cancel(io) catch {};
    try awaitState(&client, .draining);
    slow.go.store(true, .release);
    try drainer.await(io);
    publisher.await(io);
    try server.await(io);
    // Whatever publish() accepted came before the last PING, and its PONG
    // confirmed it: nothing uncertain, nothing dropped.
    try testing.expectEqual(published.load(.monotonic), slow.before_last.load(.monotonic));
    try testing.expectEqual(published.load(.monotonic), slow.total.load(.monotonic));
    const stats = client.stats();
    try testing.expectEqual(0, stats.uncertain_outbound_frames);
    try testing.expectEqual(0, stats.dropped_messages);
    try testing.expectEqual(.drained, client.close_reason.?);
}

/// Answers a request to `many.x` with three responses; serves PINGs.
fn sessionThreeResponses(peer: *FakeServer.Peer, record: *Record) anyerror!void {
    try handshake(peer, golden.info_default);
    var inbox_sid: [20]u8 = undefined;
    var inbox_sid_len: usize = 0;
    while (try peer.nextLine()) |line| {
        try record.note(peer.io, line);
        if (std.mem.eql(u8, line, "PING")) {
            try peer.send(golden.pong);
        } else if (std.mem.startsWith(u8, line, "SUB _INBOX.")) {
            const sid = line[std.mem.findScalarLast(u8, line, ' ').? + 1 ..];
            @memcpy(inbox_sid[0..sid.len], sid);
            inbox_sid_len = sid.len;
        } else if (std.mem.startsWith(u8, line, "PUB many.x ")) {
            var words = std.mem.splitScalar(u8, line, ' ');
            _ = words.next();
            _ = words.next();
            const reply = words.next().?;
            try peer.reader.interface.discardAll(1 + 2);
            for ([_][]const u8{ "1", "2", "3" }) |n| {
                var frame: [128]u8 = undefined;
                try peer.send(try std.fmt.bufPrint(&frame, "MSG {s} {s} 1\r\n{s}\r\n", .{ reply, inbox_sid[0..inbox_sid_len], n }));
            }
        }
    }
}

test "a drain keeps what the streams of requestMany received for their owners to read" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{sessionThreeResponses};
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();
    const responses = try client.requestMany("many.x", "?", .{ .max_responses = 3, .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } } });
    defer responses.deinit();
    var first = (try responses.next(.{})) orelse return error.TestNoResponse;
    first.deinit();
    const give_up = time.after(io, .fromSeconds(5 * @as(i64, test_wait.timeoutFactor())));
    while (responses.messages.stats(io).received < 3) {
        if (time.expired(io, give_up)) return error.TestNoResponse;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    // The stream has all it takes: it does not hold the drain.
    try drainClient(&client, .fromSeconds(5));
    try testing.expectEqual(.drained, client.close_reason.?);
    for ([_][]const u8{ "2", "3" }) |payload| {
        var msg = (try responses.next(.{})) orelse return error.TestResponseLost;
        defer msg.deinit();
        try testing.expectEqualStrings(payload, msg.payload);
    }
    try testing.expect(try responses.next(.{}) == null);
    try testing.expectEqual(0, client.stats().dropped_messages);
}

test "a drained close keeps what the streams of requestMany received when the manager ends the inbox first" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{sessionThreeResponses};
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();
    const responses = try client.requestMany("many.x", "?", .{ .max_responses = 3, .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } } });
    defer responses.deinit();
    var first = (try responses.next(.{})) orelse return error.TestNoResponse;
    first.deinit();
    const give_up = time.after(io, .fromSeconds(5 * @as(i64, test_wait.timeoutFactor())));
    while (responses.messages.stats(io).received < 3) {
        if (time.expired(io, give_up)) return error.TestNoResponse;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    {
        // What the close of a finished drain does under the mutex. It wakes
        // the manager, which may take the connection down before that close
        // goes on to end the inbox.
        client.mutex.lockUncancelable(io);
        defer client.mutex.unlock(io);
        client.status = .closed;
        client.close_reason = .drained;
        client.exit = .closed;
        client.changed.wake(io);
    }
    _ = try expectEvent(&client, .connected);
    // The closed event is the manager's last act: the connection is down,
    // and the inbox has ended.
    try testing.expectEqual(.drained, (try expectEvent(&client, .closed)).closed);
    // Only now does that close end the inbox.
    client.inbox.endDrained(io);
    for ([_][]const u8{ "2", "3" }) |payload| {
        var msg = (try responses.next(.{})) orelse return error.TestResponseLost;
        defer msg.deinit();
        try testing.expectEqualStrings(payload, msg.payload);
    }
    try testing.expect(try responses.next(.{}) == null);
}

test "a drain that begins while a lame duck move is decided but not begun finishes on that server" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{sessionServe};
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();
    try client.flush(quick);
    {
        // The reader saw the server's lame duck INFO; the manager has not
        // woken for it yet.
        client.mutex.lockUncancelable(io);
        defer client.mutex.unlock(io);
        client.exit = .lame_duck;
    }
    try drainClient(&client, .fromSeconds(5));
    try testing.expectEqual(.drained, client.close_reason.?);
    try testing.expectEqual(1, record.accepted.load(.monotonic));
}

/// The next event, which must be a `tag` one, within 5 s.
fn expectEvent(client: *Client, tag: std.meta.Tag(nats.Event)) !nats.Event {
    const event = (try client.nextEvent(within_five_seconds)) orelse return error.TestNoEvent;
    if (event != tag) {
        std.debug.print("expected {t}, got {t}\n", .{ tag, event });
        return error.TestUnexpectedEvent;
    }
    return event;
}

test "events: connected, disconnected, reconnecting, reconnected and closed, in order" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{ sessionHangUp, sessionServe };
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();
    const port = listener.socket.address.getPort();
    try testing.expectEqual(port, (try expectEvent(&client, .connected)).connected.port);
    const lost = (try expectEvent(&client, .disconnected)).disconnected;
    try testing.expectEqual(port, lost.server.port);
    try testing.expectEqual(.closed_by_server, lost.reason);
    try testing.expectEqual(1, (try expectEvent(&client, .reconnecting)).reconnecting.attempt);
    try testing.expectEqual(port, (try expectEvent(&client, .reconnected)).reconnected.port);
    client.close();
    try testing.expectEqual(.closed, (try expectEvent(&client, .closed)).closed);
    try testing.expect(try client.nextEvent(.{}) == null);
}

test "events: servers the cluster announces and stops announcing" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(serveCluster, .{ io, &listener });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();
    try client.flush(quick);
    try testing.expectEqual(14234, (try expectEvent(&client, .server_discovered)).server_discovered.port);
    try testing.expectEqual(14235, (try expectEvent(&client, .server_discovered)).server_discovered.port);
    _ = try expectEvent(&client, .connected);
    try testing.expectEqual(14235, (try expectEvent(&client, .server_removed)).server_removed.port);
    client.close();
    try server.await(io);
}

const forty_bytes: [40]u8 = @splat('x');

/// Once the client subscribed to `slow` and `forbidden`: five messages for
/// `slow`, one too large, a refusal of `forbidden` and an error the server
/// keeps the connection after; then serves.
fn sessionTrouble(peer: *FakeServer.Peer, record: *Record) anyerror!void {
    try handshake(peer, golden.info_default);
    if (!try readUntil(peer, record, "SUB forbidden 2")) return error.TestNoSub;
    try peer.send("MSG slow 1 1\r\n1\r\nMSG slow 1 1\r\n2\r\nMSG slow 1 1\r\n3\r\nMSG slow 1 1\r\n4\r\nMSG slow 1 1\r\n5\r\n");
    try peer.send("MSG slow 1 40\r\n" ++ forty_bytes ++ "\r\n");
    try peer.send("-ERR 'Permissions Violation for Subscription to \"forbidden\"'\r\n-ERR 'maximum subscriptions exceeded'\r\n");
    while (try nextFrame(peer, record)) |frame| {
        if (std.mem.eql(u8, frame, "PING")) try peer.send(golden.pong);
    }
}

fn trouble() anyerror!void {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{sessionTrouble};
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{
        .servers = &.{try FakeServer.url(&listener, &url)},
        .limits = .{ .max_inbound_frame_bytes = 32, .max_header_bytes = 32 },
    });
    defer client.deinit();
    try client.connect();
    _ = try expectEvent(&client, .connected);
    const slow = try client.subscribe("slow", .{ .pending = .{ .messages = 2 } });
    defer slow.deinit();
    const forbidden = try client.subscribe("forbidden", .{});
    defer forbidden.deinit();
    // Three dropped in one run: one event.
    try testing.expectEqual(slow.sid, (try expectEvent(&client, .slow_consumer)).slow_consumer);
    const dropped = (try expectEvent(&client, .message_dropped)).message_dropped;
    try testing.expectEqual(.too_large, dropped.reason);
    try testing.expectEqual(slow.sid, dropped.sid.?);
    const denied = (try expectEvent(&client, .permission_denied)).permission_denied;
    try testing.expectEqual(.subscribe, denied.operation);
    try testing.expectEqualStrings("forbidden", denied.subject.slice());
    try testing.expectEqual(forbidden.sid, denied.sid.?);
    try testing.expectEqualStrings("maximum subscriptions exceeded", (try expectEvent(&client, .server_error)).server_error.slice());
    try testing.expect(client.isConnected());
    client.close();
}

test "events: one slow_consumer per run of drops, dropped messages, refusals and server errors" {
    try quietly(trouble);
}

fn nextEventLong(client: *Client) Client.NextEventError!?nats.Event {
    return client.nextEvent(.{});
}

test "close() wakes a task waiting in nextEvent, which gets closed, then null; one task waits at a time" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{sessionServe};
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();
    _ = try expectEvent(&client, .connected);
    var waiter = try io.concurrent(nextEventLong, .{&client});
    defer _ = waiter.cancel(io) catch {};
    const give_up = time.after(io, .fromSeconds(5 * @as(i64, test_wait.timeoutFactor())));
    while (!client.events.isReceiving(io)) {
        if (time.expired(io, give_up)) return error.TestNeverWaited;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.expectError(error.ConcurrentReceive, client.nextEvent(.{}));
    const start = Io.Clock.awake.now(io);
    client.close();
    try testing.expectEqual(.closed, (try waiter.await(io)).?.closed);
    if (test_wait.timing()) try testing.expect(start.durationTo(Io.Clock.awake.now(io)).toSeconds() < 1);
    try testing.expect(try client.nextEvent(.{}) == null);
}

test "events: refused credentials, then closed for auth_failed" {
    try quietly(refusedEvents);
}

fn refusedEvents() anyerror!void {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{ sessionRevoke, sessionRefuseViolation };
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{
        .servers = &.{try FakeServer.url(&listener, &url)},
        .auth = .{ .user_password = .{ .username = "alice", .password = "old" } },
        .reconnect = fast_reconnect,
    });
    defer client.deinit();
    try client.connect();
    _ = try expectEvent(&client, .connected);
    _ = try expectEvent(&client, .auth_error);
    try testing.expectEqual(.server_error, (try expectEvent(&client, .disconnected)).disconnected.reason);
    _ = try expectEvent(&client, .reconnecting);
    _ = try expectEvent(&client, .auth_error);
    try testing.expectEqual(.auth_failed, (try expectEvent(&client, .closed)).closed);
    try testing.expect(try client.nextEvent(.{}) == null);
}

test "events: publishes still waiting when the client closes are dropped, and an event counts them" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{ sessionHangUpAfterSub, sessionAnswerWhenReleased };
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer {
        record.release.set(io);
        server.cancel(io) catch {};
    }
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();
    const sub = try client.subscribe("sub", .{});
    defer sub.deinit();
    try awaitState(&client, .reconnecting);
    for (0..3) |_| try client.publish("buffered", "x");
    client.close();
    _ = try expectEvent(&client, .connected);
    _ = try expectEvent(&client, .disconnected);
    while (true) {
        const event = (try client.nextEvent(within_five_seconds)) orelse return error.TestNoEvent;
        switch (event) {
            .reconnecting => continue,
            .message_dropped => |dropped| {
                try testing.expectEqual(.unsent, dropped.reason);
                try testing.expectEqual(3, dropped.count);
                break;
            },
            else => return error.TestUnexpectedEvent,
        }
    }
    _ = try expectEvent(&client, .closed);
    try testing.expectEqual(3, client.stats().dropped_messages);
}

/// Serves, and answers requests: `service.x` with "ok", `nobody.x` with
/// "no responders", `silent.x` never; and two messages for `s` once the
/// client subscribes to it.
fn sessionStats(peer: *FakeServer.Peer, record: *Record) anyerror!void {
    try handshake(peer, golden.info_default);
    var pending: Pending = .{};
    while (try peer.nextLine()) |line| {
        try record.note(peer.io, line);
        pending.note(line);
        if (std.mem.eql(u8, line, "PING")) {
            try peer.send(golden.pong);
        } else if (std.mem.startsWith(u8, line, "SUB s ")) {
            try peer.send("MSG s 1 3\r\nabc\r\nMSG s 1 3\r\nabc\r\n");
        } else if (std.mem.startsWith(u8, line, "PUB ")) {
            const size = try std.fmt.parseInt(usize, line[std.mem.findScalarLast(u8, line, ' ').? + 1 ..], 10);
            var body: [64]u8 = undefined;
            try peer.readExact(body[0 .. size + 2]);
            if (std.mem.startsWith(u8, line, "PUB service.x ")) try pending.answer(peer);
            if (std.mem.startsWith(u8, line, "PUB nobody.x ")) {
                var words = std.mem.splitScalar(u8, line, ' ');
                _ = words.next();
                _ = words.next();
                var frame: [128]u8 = undefined;
                try peer.send(try std.fmt.bufPrint(&frame, "HMSG {s} {s} 16 16\r\nNATS/1.0 503\r\n\r\n\r\n", .{ words.next().?, pending.inbox_sid[0..pending.inbox_sid_len] }));
            }
        }
    }
}

test "stats: what came and went, requests, round trip and uptime" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{sessionStats};
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    const before = client.stats();
    try testing.expect(before.rtt == null and before.connected_for == null);
    try client.connect();

    const s = try client.subscribe("s", .{});
    defer s.deinit();
    try awaitReceived(s, 2);
    try client.publish("p", "12345");
    var reply = try client.request("service.x", "?", .{});
    reply.deinit();
    try testing.expectError(error.NoResponders, client.request("nobody.x", "?", .{}));
    try testing.expectError(error.Timeout, client.request("silent.x", "?", .{ .timeout = .{ .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake } } }));
    _ = try client.rtt(quick);

    const now = client.stats();
    // Two messages for `s`, the reply and the 503.
    try testing.expectEqual(4, now.messages_in);
    try testing.expectEqual(3 + 3 + 2 + 16, now.bytes_in);
    try testing.expectEqual(4, now.messages_out);
    try testing.expectEqual(5 + 1 + 1 + 1, now.bytes_out);
    try testing.expectEqual(1, now.active_subscriptions);
    try testing.expectEqual(0, now.pending_requests);
    // Each message held as subject and payload: "s" and "abc".
    try testing.expectEqual(2 * 4, now.pending_subscription_bytes);
    try testing.expectEqual(1, now.request_timeouts);
    try testing.expectEqual(1, now.no_responders);
    try testing.expectEqual(0, now.reconnects);
    try testing.expectEqual(0, now.dropped_messages);
    try testing.expect(now.rtt != null);
    try testing.expect(now.connected_for != null);
    try s.unsubscribe();
    try testing.expectEqual(0, client.stats().active_subscriptions);
    try testing.expectEqual(0, client.stats().pending_subscription_bytes);
    client.close();
    try testing.expect(client.stats().connected_for == null);
}

test "stats: reconnects, and late replies" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{ sessionHangUp, sessionServe };
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();
    _ = try expectEvent(&client, .connected);
    _ = try expectEvent(&client, .disconnected);
    _ = try expectEvent(&client, .reconnecting);
    _ = try expectEvent(&client, .reconnected);
    try testing.expectEqual(1, client.stats().reconnects);
    client.inbox.noteLate(io);
    try testing.expectEqual(1, client.stats().late_responses);
}

fn nextMessageLong(sub: *nats.Subscription) nats.Subscription.NextError!?nats.Message {
    return sub.next(.{});
}

fn releaseMessage(result: nats.Subscription.NextError!?nats.Message) void {
    const got = result catch return;
    if (got) |message| {
        var m = message;
        m.deinit();
    }
}

test "close() while reconnecting: a request in the buffer, next() and nextEvent() get ConnectionClosed or closed at once" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{ sessionHangUpAfterSub, sessionAnswerWhenReleased };
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer {
        record.release.set(io);
        server.cancel(io) catch {};
    }
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();
    const sub = try client.subscribe("sub", .{});
    defer sub.deinit();
    try awaitState(&client, .reconnecting);
    var request = try io.concurrent(requestService, .{&client});
    defer releaseReply(request.cancel(io));
    try awaitAwaiting(&client, 1);
    var reader = try io.concurrent(nextMessageLong, .{sub});
    defer releaseMessage(reader.cancel(io));
    try test_wait.waitUntil(io, "the reader to wait in next()", sub, struct {
        fn waiting(s: *nats.Subscription) bool {
            return s.messages.isReceiving(s.client.io);
        }
    }.waiting);
    // The events so far, up to the first attempt to reconnect.
    _ = try awaitEventOf(&client, .reconnecting);
    var watcher = try io.concurrent(nextEventLong, .{&client});
    defer _ = watcher.cancel(io) catch {};
    try test_wait.waitUntil(io, "the watcher to wait for an event", &client, struct {
        fn waiting(c: *Client) bool {
            return c.events.isReceiving(c.io);
        }
    }.waiting);

    const start = Io.Clock.awake.now(io);
    client.close();
    if (request.await(io)) |_| return error.TestUnexpectedReply else |err| try testing.expectEqual(error.ConnectionClosed, err);
    try testing.expectError(error.ConnectionClosed, reader.await(io));
    const last = (try watcher.await(io)).?;
    // The request's PUB never went out.
    try testing.expect(last == .message_dropped or last == .closed);
    if (test_wait.timing()) try testing.expect(start.durationTo(Io.Clock.awake.now(io)).toSeconds() < 1);
}

test "a server down for good: 200 failed attempts in a row, then the client gives up, and nothing leaks" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    var server = try io.concurrent(serveRefusing, .{ io, &listener, &record });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{
        .servers = &.{try FakeServer.url(&listener, &url)},
        .retry_initial_connect = true,
        .reconnect = .{ .min_delay = .fromNanoseconds(1), .max_delay = .fromMilliseconds(1), .max_attempts = 200 },
    });
    defer client.deinit();
    try client.connect();
    // Publishes wait in the buffer meanwhile, within its bounds.
    for (0..10) |_| try client.publish("waiting", "x");
    const give_up = time.after(io, .fromSeconds(30 * @as(i64, test_wait.timeoutFactor())));
    while (client.state() != .closed) {
        if (time.expired(io, give_up)) return error.TestNeverGaveUp;
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    try testing.expectEqual(200, record.accepted.load(.monotonic));
    try testing.expectEqual(.reconnect_failed, client.close_reason.?);
    try testing.expectEqual(10, client.stats().dropped_messages);
    var attempts: u32 = 0;
    while (try client.nextEvent(.{})) |event| switch (event) {
        .reconnecting => |r| {
            attempts += 1;
            try testing.expectEqual(attempts, r.attempt);
        },
        .closed => |reason| try testing.expectEqual(.reconnect_failed, reason),
        .message_dropped => |dropped| try testing.expectEqual(10, dropped.count),
        else => return error.TestUnexpectedEvent,
    };
    try testing.expectEqual(200, attempts);
}

/// Confirms the client's first publish with a PONG, takes two more, and
/// hangs up before the PONG of the next PING.
fn sessionUnconfirmed(peer: *FakeServer.Peer, record: *Record) anyerror!void {
    try handshake(peer, golden.info_default);
    // `nextFrame` names every publish "PUB": they come as a, b, c.
    if (!try readUntil(peer, record, "PUB")) return error.TestNoPub;
    if (!try readUntil(peer, record, "PING")) return error.TestNoPing;
    try peer.send(golden.pong);
    if (!try readUntil(peer, record, "PUB")) return error.TestNoPub;
    if (!try readUntil(peer, record, "PUB")) return error.TestNoPub;
}

test "a lost connection: publishes written after the last confirmed PING count as uncertain, and are not sent again" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{ sessionUnconfirmed, sessionServe };
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();
    try client.publish("a", "1");
    try client.flush(quick);
    try client.publish("b", "2");
    try client.publish("c", "3");
    _ = try awaitEventOf(&client, .reconnected);
    try client.flush(quick);
    const stats = client.stats();
    try testing.expectEqual(2, stats.uncertain_outbound_frames);
    try testing.expectEqual(0, stats.dropped_messages);
    client.close();
    try server.await(io);
    const seen = try record.seen(io);
    defer testing.allocator.free(seen);
    // Nothing was sent again on the second connection.
    const second = seen[std.mem.find(u8, seen, "--\n").? + 3 ..];
    try testing.expect(std.mem.find(u8, second, "PUB") == null);
}

/// Takes events until a `tag` one, for 5 s at most.
fn awaitEventOf(client: *Client, tag: std.meta.Tag(nats.Event)) !nats.Event {
    while (true) {
        const event = (try client.nextEvent(within_five_seconds)) orelse return error.TestNoEvent;
        if (event == tag) return event;
    }
}

/// A handshake whose INFO says the server is going away already; then it
/// waits for the client to leave.
fn serveLameDuckAtOnce(io: Io, listener: *net.Server, other_port: u16) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    var info: [256]u8 = undefined;
    try handshake(&peer, try std.fmt.bufPrint(&info, "INFO {{\"server_id\":\"A\",\"proto\":1,\"headers\":true,\"ldm\":true,\"connect_urls\":[\"127.0.0.1:{d}\"]}} \r\n", .{other_port}));
    while (try peer.nextLine()) |_| {}
}

test "lame duck mode announced in the handshake: the client moves on once connected" {
    const io = testing.io;
    var going = try FakeServer.listen(io);
    defer going.deinit(io);
    var staying = try FakeServer.listen(io);
    defer staying.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{sessionServe};
    var other = try io.concurrent(serveSessions, .{ io, &staying, &sessions, &record });
    defer other.cancel(io) catch {};
    var first = try io.concurrent(serveLameDuckAtOnce, .{ io, &going, staying.socket.address.getPort() });
    defer first.cancel(io) catch {};
    var urls: [2][64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{
        .servers = &.{ try FakeServer.url(&going, &urls[0]), try FakeServer.url(&staying, &urls[1]) },
        .randomize_servers = false,
    });
    defer client.deinit();
    try client.connect();
    try awaitServer(&client, staying.socket.address.getPort());
    try first.await(io);
    _ = try awaitEventOf(&client, .lame_duck);
    client.close();
}

/// The handshake, then nothing read until released; then a hang-up.
fn sessionStallThenHangUp(peer: *FakeServer.Peer, record: *Record) anyerror!void {
    try handshake(peer, golden.info_default);
    try record.release.wait(peer.io);
}

/// The handshake; notes every line, skips payloads of any size, answers
/// PINGs.
fn sessionRecordAny(peer: *FakeServer.Peer, record: *Record) anyerror!void {
    try handshake(peer, golden.info_default);
    while (try peer.nextLine()) |line| {
        try record.note(peer.io, line);
        if (std.mem.eql(u8, line, "PING")) {
            try peer.send(golden.pong);
        } else if (std.mem.startsWith(u8, line, "PUB ") or std.mem.startsWith(u8, line, "HPUB ")) {
            const size = try std.fmt.parseInt(usize, line[std.mem.findScalarLast(u8, line, ' ').? + 1 ..], 10);
            try peer.reader.interface.discardAll(size + 2);
        }
    }
}

fn awaitRoomWaitersOf(client: *Client, count: u32) !void {
    const io = client.io;
    const give_up = time.after(io, .fromSeconds(10 * @as(i64, test_wait.timeoutFactor())));
    while (client.outbound.roomWaiters(io) < count) {
        if (time.expired(io, give_up)) return error.TestPutNeverWaited;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

const megabyte: [1024 * 1024]u8 = @splat('p');

/// Publishes 1 MiB payloads until one fails, counting those that went in;
/// the server reads none of them.
fn publishUntilFull(client: *Client, published: *std.atomic.Value(u32)) void {
    for (0..256) |_| {
        client.publish("fill", &megabyte) catch return;
        _ = published.fetchAdd(1, .monotonic);
    }
}

/// Waits until a publish is stuck: it waits for room, and none went in for
/// 200 ms; how much the sockets take first differs by system.
fn awaitStuck(client: *Client, published: *std.atomic.Value(u32)) !void {
    const io = client.io;
    const give_up = time.after(io, .fromSeconds(10 * @as(i64, test_wait.timeoutFactor())));
    var last = published.load(.monotonic);
    var still_since = Io.Clock.awake.now(io);
    while (true) {
        try io.sleep(.fromMilliseconds(10), .awake);
        const now = published.load(.monotonic);
        if (now != last or client.outbound.roomWaiters(io) == 0) {
            last = now;
            still_since = Io.Clock.awake.now(io);
        } else if (still_since.durationTo(Io.Clock.awake.now(io)).toMilliseconds() >= 200) {
            return;
        }
        if (time.expired(io, give_up)) return error.TestPublishNeverWaited;
    }
}

fn requestTenSeconds(client: *Client) Client.RequestError!nats.Message {
    return client.request("service.x", "?", .{ .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } } });
}

test "a request waiting for room when the connection is lost fails with Disconnected, and is never sent" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{ sessionStallThenHangUp, sessionRecordAny };
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer {
        record.release.set(io);
        server.cancel(io) catch {};
    }
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{
        .servers = &.{try FakeServer.url(&listener, &url)},
        .limits = .{ .outbound_bytes = 1024 },
        .reconnect = .{ .buffer_bytes = 64 * 1024 * 1024, .min_delay = .fromMilliseconds(1), .max_delay = .fromMilliseconds(5) },
    });
    defer client.deinit();
    try client.connect();
    // The first request subscribes the inbox; no reply comes.
    try testing.expectError(error.Timeout, client.request("warmup", "?", .{ .timeout = .{ .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake } } }));
    // The server reads nothing: the socket fills and publishes wait for room.
    var published: std.atomic.Value(u32) = .init(0);
    var publisher = try io.concurrent(publishUntilFull, .{ &client, &published });
    defer publisher.cancel(io);
    try awaitStuck(&client, &published);
    var requester = try io.concurrent(requestTenSeconds, .{&client});
    var awaited = false;
    defer if (!awaited) releaseReply(requester.cancel(io));
    try awaitRoomWaitersOf(&client, 2);

    // The server hangs up: the request fails at once.
    record.release.set(io);
    awaited = true;
    if (requester.await(io)) |reply| {
        releaseReply(reply);
        return error.TestUnexpectedReply;
    } else |err| try testing.expectEqual(error.Disconnected, err);
    publisher.await(io);
    try awaitState(&client, .connected);
    try client.flush(quick);
    const seen = try record.seen(io);
    defer testing.allocator.free(seen);
    try testing.expect(std.mem.find(u8, seen, "PUB service.x") == null);
    try testing.expectEqual(0, client.stats().pending_requests);
}

/// Says nothing until the test releases it; then notes every line and
/// answers PINGs.
fn sessionRecordWhenReleased(peer: *FakeServer.Peer, record: *Record) anyerror!void {
    try record.release.wait(peer.io);
    try sessionRecordAny(peer, record);
}

test "a request that times out while it waits for the next connection is never sent, and frees its room" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{ sessionHangUpAfterSub, sessionRecordWhenReleased };
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer {
        record.release.set(io);
        server.cancel(io) catch {};
    }
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();
    const sub = try client.subscribe("sub", .{});
    defer sub.deinit();
    try awaitState(&client, .reconnecting);
    try awaitAccepted(&record, 2);
    try testing.expectError(error.Timeout, client.request("service.x", "?", .{ .timeout = .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } } }));
    try testing.expectEqual(0, client.stats().pending_outbound_bytes);
    record.release.set(io);
    try awaitState(&client, .connected);
    try client.flush(quick);
    client.close();
    try server.await(io);
    const seen = try record.seen(io);
    defer testing.allocator.free(seen);
    try testing.expect(std.mem.find(u8, seen, "PUB service.x") == null);
}

/// Every connection: the handshake, then a hang-up at once; notes when each
/// came.
const Flapping = struct {
    mutex: Io.Mutex = .init,
    times: [64]Io.Timestamp = undefined,
    count: usize = 0,

    fn serve(f: *Flapping, io: Io, listener: *net.Server) anyerror!void {
        while (true) {
            var peer: FakeServer.Peer = undefined;
            try peer.accept(io, listener);
            defer peer.close();
            {
                f.mutex.lockUncancelable(io);
                defer f.mutex.unlock(io);
                if (f.count < f.times.len) f.times[f.count] = Io.Clock.awake.now(io);
                f.count += 1;
            }
            handshake(&peer, golden.info_default) catch |err| if (peer.canceled(err)) return error.Canceled;
        }
    }

    fn taken(f: *Flapping, io: Io) usize {
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        return f.count;
    }
};

test "a server that drops every connection right after the handshake: the client backs off, never a tight loop" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var flapping: Flapping = .{};
    var server = try io.concurrent(Flapping.serve, .{ &flapping, io, &listener });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{
        .servers = &.{try FakeServer.url(&listener, &url)},
        .reconnect = .{ .min_delay = .fromMilliseconds(50), .max_delay = .fromSeconds(5) },
    });
    defer client.deinit();
    try client.connect();
    try io.sleep(.fromMilliseconds(1000), .awake);
    client.close();
    // Waits of 40-50, 80-100, 160-200, 320-400 ms: five connections in a
    // second at most, where a loop with no wait makes hundreds.
    const count = flapping.taken(io);
    try testing.expect(count >= 3 and count <= 6);
    // Every wait at least the least of its level, a fifth under its delay:
    // they grow. A timer tick that ends a wait late, as Windows' ~15.6 ms
    // ones do, only makes it longer; 10 ms allow for the server noting a
    // connection late.
    var least: i96 = 40 * std.time.ns_per_ms;
    for (1..@min(count, flapping.times.len)) |i| {
        const gap = flapping.times[i - 1].durationTo(flapping.times[i]).nanoseconds;
        try testing.expect(gap >= least - 10 * std.time.ns_per_ms);
        least *= 2;
    }
}

/// A server that announces lame duck mode in every handshake and names
/// another one; counts the connections it takes.
const LameDuckEveryTime = struct {
    accepted: std.atomic.Value(u32) = .init(0),

    fn serve(d: *LameDuckEveryTime, io: Io, listener: *net.Server, other_port: u16) anyerror!void {
        while (true) {
            var peer: FakeServer.Peer = undefined;
            try peer.accept(io, listener);
            defer peer.close();
            _ = d.accepted.fetchAdd(1, .monotonic);
            var info: [256]u8 = undefined;
            handshake(&peer, try std.fmt.bufPrint(&info, "INFO {{\"server_id\":\"A\",\"proto\":1,\"headers\":true,\"ldm\":true,\"connect_urls\":[\"127.0.0.1:{d}\"]}} \r\n", .{other_port})) catch |err| if (peer.canceled(err)) return error.Canceled else continue;
            while (peer.nextLine() catch |err| if (peer.canceled(err)) return error.Canceled else null) |_| {}
        }
    }
};

test "servers that announce lame duck mode at every handshake are not hit in a tight loop" {
    const io = testing.io;
    var a = try FakeServer.listen(io);
    defer a.deinit(io);
    var b = try FakeServer.listen(io);
    defer b.deinit(io);
    var first: LameDuckEveryTime = .{};
    var second: LameDuckEveryTime = .{};
    var server_a = try io.concurrent(LameDuckEveryTime.serve, .{ &first, io, &a, b.socket.address.getPort() });
    defer server_a.cancel(io) catch {};
    var server_b = try io.concurrent(LameDuckEveryTime.serve, .{ &second, io, &b, a.socket.address.getPort() });
    defer server_b.cancel(io) catch {};
    var urls: [2][64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{
        .servers = &.{ try FakeServer.url(&a, &urls[0]), try FakeServer.url(&b, &urls[1]) },
        .randomize_servers = false,
        .reconnect = .{ .min_delay = .fromMilliseconds(50), .max_delay = .fromSeconds(5) },
    });
    defer client.deinit();
    try client.connect();
    try io.sleep(.fromMilliseconds(1000), .awake);
    client.close();
    // Waits of 40-50, 80-100, 160-200, 320-400 ms: five connections in a
    // second at most, where moving at once makes a thousand.
    const count = first.accepted.load(.monotonic) + second.accepted.load(.monotonic);
    try testing.expect(count >= 3 and count <= 6);
}

/// `std.testing.io` whose socket closes each take `delay` first: the
/// client's teardown of a connection takes longer than its `min_delay`, as
/// on a busy runner that prints a stack trace while it tears down.
const SlowClose = struct {
    const delay: Io.Duration = .fromMilliseconds(60);

    const vtable: Io.VTable = vtable: {
        var v = std.testing.io.vtable.*;
        v.netClose = netClose;
        break :vtable v;
    };

    fn io() Io {
        return .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    }

    fn netClose(userdata: ?*anyopaque, sockets: []const net.Socket) void {
        std.testing.io.vtable.sleep(userdata, .{ .duration = .{ .raw = delay, .clock = .awake } }) catch {};
        std.testing.io.vtable.netClose(userdata, sockets);
    }
};

test "lame duck at every handshake, and a teardown slower than min_delay: still not a tight loop" {
    const io = testing.io;
    var a = try FakeServer.listen(io);
    defer a.deinit(io);
    var b = try FakeServer.listen(io);
    defer b.deinit(io);
    var first: LameDuckEveryTime = .{};
    var second: LameDuckEveryTime = .{};
    var server_a = try io.concurrent(LameDuckEveryTime.serve, .{ &first, io, &a, b.socket.address.getPort() });
    defer server_a.cancel(io) catch {};
    var server_b = try io.concurrent(LameDuckEveryTime.serve, .{ &second, io, &b, a.socket.address.getPort() });
    defer server_b.cancel(io) catch {};
    var urls: [2][64]u8 = undefined;
    // Only the client's sockets close slowly.
    var client: Client = try .init(testing.allocator, SlowClose.io(), .{
        .servers = &.{ try FakeServer.url(&a, &urls[0]), try FakeServer.url(&b, &urls[1]) },
        .randomize_servers = false,
        .reconnect = .{ .min_delay = .fromMilliseconds(50), .max_delay = .fromSeconds(5) },
    });
    defer client.deinit();
    try client.connect();
    try io.sleep(.fromMilliseconds(1000), .awake);
    client.close();
    // A connection lasts until its exit is known, not until its teardown
    // ends: each still counts as short, and the waits still grow. Moving
    // at once would make a connection every 60 ms or so.
    const count = first.accepted.load(.monotonic) + second.accepted.load(.monotonic);
    try testing.expect(count >= 3 and count <= 6);
}

/// The handshake, then a hang-up at once; then serves every connection
/// after; counts them.
fn serveHangUpThenServe(io: Io, listener: *net.Server, accepted: *std.atomic.Value(u32)) anyerror!void {
    var first = true;
    while (true) {
        var peer: FakeServer.Peer = undefined;
        try peer.accept(io, listener);
        defer peer.close();
        _ = accepted.fetchAdd(1, .monotonic);
        handshake(&peer, golden.info_default) catch |err| if (peer.canceled(err)) return error.Canceled else continue;
        if (first) {
            first = false;
            continue;
        }
        answerPings(&peer) catch |err| if (peer.canceled(err)) return error.Canceled;
    }
}

/// A client's side of the handshake, by hand: INFO in, CONNECT and PING
/// out, PONG in.
fn rawHandshake(io: Io, address: net.IpAddress) !net.Stream {
    const stream = try address.connect(io, .{ .mode = .stream });
    errdefer stream.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var write_buffer: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    _ = try reader.interface.takeDelimiterInclusive('\n');
    try writer.interface.writeAll("CONNECT {}\r\nPING\r\n");
    try writer.interface.flush();
    const pong = try reader.interface.takeDelimiterInclusive('\n');
    if (!std.mem.startsWith(u8, pong, "PONG")) return error.TestNoPong;
    return stream;
}

test "a fake server canceled while it serves a client ends, and doesn't go back to accept" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var accepted: std.atomic.Value(u32) = .init(0);
    var server = try io.concurrent(serveHangUpThenServe, .{ io, &listener, &accepted });
    // The first connection is hung up after its handshake; the second is
    // served: the server now waits for the client's next line.
    const first = try rawHandshake(io, listener.socket.address);
    first.close(io);
    const second = try rawHandshake(io, listener.socket.address);
    defer second.close(io);
    // The cancel reaches the server's read. When the server took it for
    // the client hanging up, it went back to accept for good, and this
    // cancel never returned.
    try testing.expectError(error.Canceled, server.cancel(io));
}

fn holdSlot(io: Io, release: *Io.Event) void {
    release.waitUncancelable(io);
}

test "an io out of concurrency during a reconnect is one more failed attempt: the client tries again" {
    const tio = testing.io;
    var listener = try FakeServer.listen(tio);
    defer listener.deinit(tio);
    var accepted: std.atomic.Value(u32) = .init(0);
    var server = try tio.concurrent(serveHangUpThenServe, .{ tio, &listener, &accepted });
    defer server.cancel(tio) catch {};
    // The manager, the reader and the writer.
    var threaded: Io.Threaded = .init(testing.allocator, .{ .concurrent_limit = .limited(3) });
    defer threaded.deinit();
    const cio = threaded.io();
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, cio, .{
        .servers = &.{try FakeServer.url(&listener, &url)},
        .reconnect = .{ .min_delay = .fromMilliseconds(300), .max_delay = .fromSeconds(1), .jitter = false },
    });
    defer client.deinit();
    try client.connect();
    try awaitState(&client, .reconnecting);
    // The application takes the slots the reader and writer left, so the
    // next attempt cannot start.
    var release: Io.Event = .unset;
    var slots: [2]?Io.Future(void) = .{ null, null };
    defer {
        release.set(cio);
        for (&slots) |*slot| if (slot.*) |*f| f.await(cio);
    }
    const give_up = time.after(tio, .fromSeconds(5 * @as(i64, test_wait.timeoutFactor())));
    for (&slots) |*slot| {
        while (slot.* == null) {
            slot.* = cio.concurrent(holdSlot, .{ cio, &release }) catch null;
            if (slot.* != null) break;
            if (time.expired(tio, give_up)) return error.TestNoSlot;
            try tio.sleep(.fromMilliseconds(1), .awake);
        }
    }
    // Two waits pass without an attempt; the client stays.
    try tio.sleep(.fromMilliseconds(800), .awake);
    try testing.expectEqual(.reconnecting, client.state());
    try testing.expectEqual(1, accepted.load(.monotonic));
    release.set(cio);
    for (&slots) |*slot| if (slot.*) |*f| {
        f.await(cio);
        slot.* = null;
    };
    // The slots are free again a moment after `await` returns:
    // `Io.Threaded` counts a task's slot until its worker thread has left
    // it. An attempt in that moment finds no room for the reader and
    // writer either, and is one more failed attempt (what this test is
    // about), so the first `.connected` may be dropped at once. What must
    // hold is that the client ends up with a connection that works.
    try awaitWorkingConnection(&client);
}

/// The client is connected and a flush goes through, within 10 s: a
/// connection dropped as it came up (`Disconnected`) is waited out.
fn awaitWorkingConnection(client: *Client) !void {
    const give_up = time.after(client.io, .fromSeconds(10 * @as(i64, test_wait.timeoutFactor())));
    while (true) {
        try awaitState(client, .connected);
        if (client.flush(quick)) |_| return else |err| switch (err) {
            error.Disconnected => if (time.expired(client.io, give_up)) return err,
            else => return err,
        }
    }
}

test "a client closed after a lost connection reports no uptime" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{sessionHangUp};
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)}, .reconnect = .{ .enabled = false } });
    defer client.deinit();
    // The server hangs up at once: connect() may find the client closed.
    client.connect() catch |err| try testing.expectEqual(error.ConnectionClosed, err);
    try awaitState(&client, .closed);
    try testing.expectEqual(.connection_lost, client.close_reason.?);
    try testing.expect(client.stats().connected_for == null);
}

test "a client closed while its first connection fails to start ends what was made meanwhile" {
    var client: Client = try .init(testing.allocator, testing.io, .{ .servers = &.{"nats://127.0.0.1:4222"}, .retry_initial_connect = true });
    defer client.deinit();
    // As connect() leaves it before it starts the manager.
    client.status = .reconnecting;
    const sub = try client.subscribe("early", .{});
    defer sub.deinit();
    try client.publish("early", "x");
    @import("../engine/manager.zig").connectFailed(&client, error.ConcurrencyUnavailable);
    try testing.expectError(error.ConnectionClosed, sub.next(.{ .timeout = .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } } }));
    // The publish that waited for a connection is counted as dropped.
    try testing.expectEqual(1, client.stats().dropped_messages);
}

/// Says nothing until released; then a handshake whose INFO takes at most
/// 100 bytes, and notes every line, skipping payloads, answering PINGs.
fn sessionSmallPayloadWhenReleased(peer: *FakeServer.Peer, record: *Record) anyerror!void {
    try record.release.wait(peer.io);
    try handshake(peer, "INFO {\"server_id\":\"S\",\"proto\":1,\"headers\":true,\"max_payload\":100} \r\n");
    while (try peer.nextLine()) |line| {
        try record.note(peer.io, line);
        if (std.mem.eql(u8, line, "PING")) {
            try peer.send(golden.pong);
        } else if (std.mem.startsWith(u8, line, "PUB ") or std.mem.startsWith(u8, line, "HPUB ")) {
            const size = try std.fmt.parseInt(usize, line[std.mem.findScalarLast(u8, line, ' ').? + 1 ..], 10);
            try peer.reader.interface.discardAll(size + 2);
        }
    }
}

const two_hundred: [200]u8 = @splat('b');

fn requestBig(client: *Client) Client.RequestError!nats.Message {
    return client.request("service.big", &two_hundred, .{ .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } } });
}

test "what waits for the first connection and is more than its server takes is dropped and counted, never sent" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{sessionSmallPayloadWhenReleased};
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer {
        record.release.set(io);
        server.cancel(io) catch {};
    }
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)}, .retry_initial_connect = true });
    defer client.deinit();
    try client.connect();
    // No server yet: no max_payload to check against.
    try client.publish("big", &two_hundred);
    try client.publish("small", "x");
    var request = try io.concurrent(requestBig, .{&client});
    var awaited = false;
    defer if (!awaited) releaseReply(request.cancel(io));
    try awaitAwaiting(&client, 1);
    record.release.set(io);
    try awaitState(&client, .connected);
    awaited = true;
    // The new server would refuse its frame: the request fails at once.
    if (request.await(io)) |reply| {
        releaseReply(reply);
        return error.TestUnexpectedReply;
    } else |err| try testing.expectEqual(error.Disconnected, err);
    try client.flush(quick);
    try testing.expectEqual(1, client.stats().dropped_messages);
    const dropped = try awaitEventOf(&client, .message_dropped);
    try testing.expectEqual(1, dropped.message_dropped.count);
    // Now the limit is known, and checked at once.
    try testing.expectError(error.PayloadTooLarge, client.publish("big", &two_hundred));
    client.close();
    try server.await(io);
    const seen = try record.seen(io);
    defer testing.allocator.free(seen);
    try testing.expect(std.mem.find(u8, seen, "PUB big") == null);
    try testing.expect(std.mem.find(u8, seen, "PUB service.big") == null);
    try testing.expect(std.mem.find(u8, seen, "PUB small 1") != null);
}

test "an unread requestMany past its deadline gives its room in the reconnect buffer to a publish" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{sessionRecordWhenReleased};
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer {
        record.release.set(io);
        server.cancel(io) catch {};
    }
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{
        .servers = &.{try FakeServer.url(&listener, &url)},
        .retry_initial_connect = true,
        .reconnect = .{ .buffer_bytes = 400 },
    });
    defer client.deinit();
    try client.connect();
    const responses = try client.requestMany("many.x", &two_hundred, .{ .timeout = .{ .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake } } });
    defer responses.deinit();
    const deadline = responses.deadline;
    while (!time.expired(io, deadline)) try io.sleep(.fromMilliseconds(5), .awake);
    // Nobody read the stream; its frame will never be sent.
    try client.publish("after", &two_hundred);
    record.release.set(io);
    try awaitState(&client, .connected);
    try client.flush(quick);
    const seen = try record.seen(io);
    defer testing.allocator.free(seen);
    try testing.expect(std.mem.find(u8, seen, "PUB after 200") != null);
    try testing.expect(std.mem.find(u8, seen, "PUB many.x") == null);
}

/// The INFO that comes with the handshake's PONG: this client's own
/// max_payload, lower than the server's, as an account limit gives.
const info_account = "INFO {\"server_id\":\"S\",\"proto\":1,\"headers\":true,\"max_payload\":100} \r\n";

/// A handshake whose PONG comes in one write with the INFO of the
/// client's own limits; then serves PINGs.
fn sessionInfoWithPong(peer: *FakeServer.Peer, record: *Record) anyerror!void {
    _ = record;
    try peer.send(golden.info_default);
    _ = try peer.readLine();
    try peer.expectLine("PING");
    try peer.send(golden.pong ++ info_account);
    try answerPings(peer);
}

const thousand: [1000]u8 = @splat('k');

test "the INFO that comes with the handshake's PONG applies before connect() returns" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{sessionInfoWithPong};
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();
    try testing.expectError(error.PayloadTooLarge, client.publish("big", &thousand));
    var info = (try client.serverInfo(testing.allocator)) orelse return error.TestNoInfo;
    defer info.deinit();
    try testing.expectEqual(100, info.value.max_payload);
}

/// An allocator that fails every allocation of one size: the copy of an
/// INFO of that length.
const FailSize = struct {
    parent: std.mem.Allocator,
    size: std.atomic.Value(usize) = .init(0),

    fn allocator(f: *FailSize) std.mem.Allocator {
        return .{ .ptr = f, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const f: *FailSize = @ptrCast(@alignCast(context));
        if (len == f.size.load(.monotonic)) return null;
        return f.parent.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const f: *FailSize = @ptrCast(@alignCast(context));
        return f.parent.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const f: *FailSize = @ptrCast(@alignCast(context));
        return f.parent.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const f: *FailSize = @ptrCast(@alignCast(context));
        f.parent.rawFree(memory, alignment, ret_addr);
    }
};

/// The INFO of the client's own limits comes at its first PING after the
/// handshake, before the PONG; then serves PINGs.
fn sessionInfoAtFirstPing(peer: *FakeServer.Peer, record: *Record) anyerror!void {
    try handshake(peer, golden.info_default);
    if (!try readUntil(peer, record, "PING")) return error.TestNoPing;
    try peer.send(info_account ++ golden.pong);
    try answerPings(peer);
}

test "a lower max_payload in an INFO applies even when there is no memory to keep that INFO" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{sessionInfoAtFirstPing};
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer server.cancel(io) catch {};
    var fail: FailSize = .{ .parent = testing.allocator };
    var url: [64]u8 = undefined;
    var client: Client = try .init(fail.allocator(), io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();
    // The JSON of the INFO, without "INFO " and the line's end.
    fail.size.store(info_account.len - "INFO ".len - " \r\n".len, .monotonic);
    try client.flush(quick);
    fail.size.store(0, .monotonic);
    try testing.expectError(error.PayloadTooLarge, client.publish("big", &thousand));
}

test "a request whose deadline passed before its frame goes in sends nothing" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{sessionRecordAny};
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();
    // The first request subscribes the inbox; nobody answers.
    try testing.expectError(error.Timeout, client.request("warmup", "?", .{ .timeout = .{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } } }));
    try testing.expectError(error.Timeout, client.request("late.x", "?", .{ .timeout = .{ .duration = .{ .raw = .zero, .clock = .awake } } }));
    try testing.expectError(error.Timeout, client.requestMany("late.many", "?", .{ .timeout = .{ .duration = .{ .raw = .zero, .clock = .awake } } }));
    try client.flush(quick);
    client.close();
    try server.await(io);
    const seen = try record.seen(io);
    defer testing.allocator.free(seen);
    try testing.expect(std.mem.find(u8, seen, "PUB warmup") != null);
    try testing.expect(std.mem.find(u8, seen, "PUB late") == null);
}

test "a requestMany past its deadline that nobody reads does not hold up a drain, nor count as pending" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    const sessions = [_]Session{sessionRecordAny};
    var server = try io.concurrent(serveSessions, .{ io, &listener, &sessions, &record });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();
    const responses = try client.requestMany("nobody.home", "?", .{ .timeout = .{ .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake } } });
    defer responses.deinit();
    try testing.expectEqual(1, client.stats().pending_requests);
    const deadline = responses.deadline;
    while (!time.expired(io, deadline)) try io.sleep(.fromMilliseconds(5), .awake);
    try testing.expectEqual(0, client.stats().pending_requests);
    try client.drain(.{ .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } } });
    try testing.expectEqual(.drained, client.close_reason.?);
}
