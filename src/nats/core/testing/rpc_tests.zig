// Adapted from vkiryakov/zefir src/nats/testing/rpc_tests.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! Requests and replies against a fake server on loopback. The server
//! answers each request by the first token of its subject, and records
//! every line the client sends. Each test starts its own server function in
//! a task and cancels it on the way out; the client's waits are bounded, so
//! a mistake fails a test instead of hanging it.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const testing = std.testing;
const nats = @import("../root.zig");
const Client = nats.Client;
const FakeServer = @import("FakeServer.zig");
const Inbox = @import("../engine/Inbox.zig");
const golden = @import("../protocol/golden.zig");
const time = @import("../engine/time.zig");
const test_wait = @import("anole_test_wait");

const quick: nats.FlushOptions = .{ .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } } };

fn within(milliseconds: i64) nats.RequestOptions {
    return .{ .timeout = .{ .duration = .{ .raw = .fromMilliseconds(milliseconds), .clock = .awake } } };
}

const five_seconds = within(5000);

/// The server's side of the handshake, with headers.
fn handshake(peer: *FakeServer.Peer) !void {
    try peer.send(golden.info_default);
    const connect_line = try peer.readLine();
    if (!std.mem.startsWith(u8, connect_line, "CONNECT {")) return error.TestNotConnect;
    try peer.expectLine("PING");
    try peer.send(golden.pong);
}

/// What the server records, for the test to read once the server is done.
const Record = struct {
    /// Every line the client sent, without payloads.
    lines: std.ArrayList(u8) = .empty,
    /// The SID of the client's inbox subscription.
    inbox_sid: u64 = 0,

    fn deinit(r: *Record) void {
        r.lines.deinit(testing.allocator);
    }

    /// How many lines start with `prefix`.
    fn count(r: *const Record, prefix: []const u8) usize {
        var n: usize = 0;
        var lines = std.mem.splitSequence(u8, r.lines.items, "\r\n");
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, prefix)) n += 1;
        }
        return n;
    }
};

/// A request as the server reads it.
const Request = struct {
    subject: []const u8,
    reply: []const u8,
    /// The header block, empty for PUB.
    headers: []const u8,
    payload: []const u8,
};

/// After the handshake, answers PINGs, notes the inbox SUB, and answers
/// each request by the first token of its subject:
///
///   echo.*      the payload back
///   headers.*   the payload back with the header `X-Reply: yes`
///   nobody.*    503 without a body, as a server does for no responders
///   busy.*      503 with the body "busy"
///   silent.*    nothing
///   slow.<ms>   the payload back after <ms> milliseconds
///   hangup.*    the connection closes
///   many.<n>    n replies: "r1", "r2", ...
///   manyhangup.<n>  n replies, then the connection closes
fn serveRequests(io: Io, listener: *net.Server, record: *Record) anyerror!void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try handshake(&peer);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    while (try peer.nextLine()) |line| {
        try record.lines.appendSlice(testing.allocator, line);
        try record.lines.appendSlice(testing.allocator, "\r\n");
        var args = std.mem.tokenizeScalar(u8, line, ' ');
        const op = args.next() orelse continue;
        if (std.mem.eql(u8, op, "PING")) {
            try peer.send(golden.pong);
        } else if (std.mem.eql(u8, op, "SUB")) {
            const subject = args.next() orelse return error.TestBadSub;
            const sid = try std.fmt.parseInt(u64, args.rest(), 10);
            if (std.mem.startsWith(u8, subject, "_INBOX.")) record.inbox_sid = sid;
        } else if (std.mem.eql(u8, op, "PUB") or std.mem.eql(u8, op, "HPUB")) {
            var fields: [5][]const u8 = undefined;
            var n: usize = 0;
            while (args.next()) |arg| : (n += 1) {
                if (n == fields.len) return error.TestBadPub;
                fields[n] = arg;
            }
            const with_headers = std.mem.eql(u8, op, "HPUB");
            const sizes: usize = if (with_headers) 2 else 1;
            if (n < 1 + sizes) return error.TestBadPub;
            const total = try std.fmt.parseInt(usize, fields[n - 1], 10);
            const header_len = if (with_headers) try std.fmt.parseInt(usize, fields[n - 2], 10) else 0;
            try body.resize(testing.allocator, total + 2);
            try peer.readExact(body.items);
            const request: Request = .{
                .subject = fields[0],
                .reply = if (n == 2 + sizes) fields[1] else "",
                .headers = body.items[0..header_len],
                .payload = body.items[header_len..total],
            };
            if (!try answer(io, &peer, record.inbox_sid, request)) return;
        }
    }
}

/// Answers one request; false when the connection is to close.
fn answer(io: Io, peer: *FakeServer.Peer, sid: u64, request: Request) !bool {
    const kind = request.subject[0 .. std.mem.findScalar(u8, request.subject, '.') orelse request.subject.len];
    var buffer: [512]u8 = undefined;
    if (std.mem.eql(u8, kind, "echo")) {
        try peer.send(try std.fmt.bufPrint(&buffer, "MSG {s} {d} {d}\r\n", .{ request.reply, sid, request.payload.len }));
        try peer.send(request.payload);
        try peer.send("\r\n");
    } else if (std.mem.eql(u8, kind, "headers")) {
        const block = "NATS/1.0\r\nX-Reply: yes\r\n\r\n";
        try peer.send(try std.fmt.bufPrint(&buffer, "HMSG {s} {d} {d} {d}\r\n" ++ block, .{ request.reply, sid, block.len, block.len + request.payload.len }));
        try peer.send(request.payload);
        try peer.send("\r\n");
    } else if (std.mem.eql(u8, kind, "nobody")) {
        // As nats-server 2.15 sends it: 32 bytes and the subject.
        const block_len = 32 + request.subject.len;
        try peer.send(try std.fmt.bufPrint(&buffer, "HMSG {s} {d} {d} {d}\r\nNATS/1.0 503\r\nNats-Subject: {s}\r\n\r\n\r\n", .{ request.reply, sid, block_len, block_len, request.subject }));
    } else if (std.mem.eql(u8, kind, "busy")) {
        const block = "NATS/1.0 503\r\n\r\n";
        try peer.send(try std.fmt.bufPrint(&buffer, "HMSG {s} {d} {d} {d}\r\n" ++ block ++ "busy\r\n", .{ request.reply, sid, block.len, block.len + 4 }));
    } else if (std.mem.eql(u8, kind, "slow")) {
        const ms = try std.fmt.parseInt(i64, request.subject["slow.".len..], 10);
        try io.sleep(.fromMilliseconds(ms), .awake);
        try peer.send(try std.fmt.bufPrint(&buffer, "MSG {s} {d} {d}\r\n", .{ request.reply, sid, request.payload.len }));
        try peer.send(request.payload);
        try peer.send("\r\n");
    } else if (std.mem.eql(u8, kind, "hangup")) {
        return false;
    } else if (std.mem.eql(u8, kind, "many") or std.mem.eql(u8, kind, "manyhangup")) {
        const count = try std.fmt.parseInt(u32, request.subject[kind.len + 1 ..], 10);
        for (1..count + 1) |i| {
            var payload: [16]u8 = undefined;
            const text = try std.fmt.bufPrint(&payload, "r{d}", .{i});
            try peer.send(try std.fmt.bufPrint(&buffer, "MSG {s} {d} {d}\r\n{s}\r\n", .{ request.reply, sid, text.len, text }));
        }
        return std.mem.eql(u8, kind, "many");
    }
    return true;
}

/// A client connected to a request-answering server. Initialize in place.
const Served = struct {
    listener: net.Server,
    server: Io.Future(anyerror!void),
    record: Record = .{},
    url: [64]u8 = undefined,
    client: Client,

    /// Starts the server and connects a client with `options`, whose
    /// servers are replaced by the fake one.
    fn start(s: *Served, options: nats.Options) !void {
        const io = testing.io;
        s.listener = try FakeServer.listen(io);
        errdefer s.listener.deinit(io);
        s.record = .{};
        errdefer s.record.deinit();
        s.server = try io.concurrent(serveRequests, .{ io, &s.listener, &s.record });
        errdefer s.server.cancel(io) catch {};
        var with_server = options;
        with_server.servers = &.{try FakeServer.url(&s.listener, &s.url)};
        s.client = try .init(testing.allocator, io, with_server);
        errdefer s.client.deinit();
        try s.client.connect();
    }

    /// Flushes, closes the client and waits for the server; then `record`
    /// holds every line the client sent.
    fn finish(s: *Served) !void {
        try s.client.flush(quick);
        s.client.close();
        try s.server.await(testing.io);
    }

    fn deinit(s: *Served) void {
        const io = testing.io;
        s.client.deinit();
        s.server.cancel(io) catch {};
        s.listener.deinit(io);
        s.record.deinit();
    }
};

/// Sends a request and checks that the reply carries `expected`.
fn expectReply(client: *Client, subject: []const u8, payload: []const u8, expected: []const u8) !void {
    var reply = try client.request(subject, payload, five_seconds);
    defer reply.deinit();
    try testing.expectEqualStrings(expected, reply.payload);
}

test "a request gets its reply; every request goes out with a reply subject of the one inbox" {
    var s: Served = undefined;
    try s.start(.{ .servers = &.{} });
    defer s.deinit();
    try expectReply(&s.client, "echo.a", "one", "one");
    try expectReply(&s.client, "echo.b", "two", "two");
    try expectReply(&s.client, "echo.c", "", "");
    try testing.expectEqual(0, s.client.inbox.pendingCount(testing.io));
    try s.finish();

    // One SUB, before the first PUB; replies go to _INBOX.<token>.<id>.
    try testing.expectEqual(1, s.record.count("SUB "));
    var lines = std.mem.splitSequence(u8, s.record.lines.items, "\r\n");
    const sub = lines.next().?;
    try testing.expect(std.mem.startsWith(u8, sub, "SUB _INBOX."));
    const prefix = sub["SUB ".len .. "SUB ".len + Inbox.prefix_len];
    try testing.expectEqualStrings(".* 1", sub["SUB ".len + Inbox.prefix_len - 1 ..]);
    for (prefix["_INBOX.".len..][0..Inbox.token_len]) |c| try testing.expect(std.ascii.isAlphanumeric(c));
    var expected: [128]u8 = undefined;
    for ([_][]const u8{ "echo.a", "echo.b", "echo.c" }, [_][]const u8{ "1 3", "2 3", "3 0" }) |subject, rest| {
        try testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "PUB {s} {s}{s}", .{ subject, prefix, rest }), lines.next().?);
    }
}

fn requestEcho(client: *Client, payload: []const u8, ok: *std.atomic.Value(u32)) void {
    var reply = client.request("echo.many", payload, five_seconds) catch return;
    defer reply.deinit();
    if (std.mem.eql(u8, reply.payload, payload)) _ = ok.fetchAdd(1, .monotonic);
}

test "requests at once share the one inbox SUB, and it goes out before any of them" {
    const io = testing.io;
    var s: Served = undefined;
    try s.start(.{ .servers = &.{} });
    defer s.deinit();
    var ok: std.atomic.Value(u32) = .init(0);
    var payloads: [24][8]u8 = undefined;
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (&payloads, 0..) |*payload, i| {
        const text = try std.fmt.bufPrint(payload, "p{d}", .{i});
        try group.concurrent(io, requestEcho, .{ &s.client, text, &ok });
    }
    try group.await(io);
    try testing.expectEqual(payloads.len, ok.load(.monotonic));
    try s.finish();
    try testing.expectEqual(1, s.record.count("SUB "));
    try testing.expect(std.mem.startsWith(u8, s.record.lines.items, "SUB _INBOX."));
    try testing.expectEqual(payloads.len, s.record.count("PUB echo.many _INBOX."));
}

test "requestMessage sends headers, and the headers of the reply come back" {
    var s: Served = undefined;
    try s.start(.{ .servers = &.{} });
    defer s.deinit();
    var reply = try s.client.requestMessage(.{
        .subject = "headers.x",
        .headers = &.{.{ .name = "X-Ask", .value = "1" }},
        .payload = "body",
    }, five_seconds);
    defer reply.deinit();
    try testing.expectEqualStrings("body", reply.payload);
    try testing.expectEqualStrings("yes", reply.headers.get("X-Reply").?);
    try s.finish();
    try testing.expectEqual(1, s.record.count("HPUB headers.x _INBOX."));
}

test "no responders: NoResponders; a 503 with a body is a reply" {
    var s: Served = undefined;
    try s.start(.{ .servers = &.{} });
    defer s.deinit();
    try testing.expectError(error.NoResponders, s.client.request("nobody.home", "?", five_seconds));
    var reply = try s.client.request("busy.now", "?", five_seconds);
    defer reply.deinit();
    try testing.expectEqual(503, reply.status.?);
    try testing.expectEqualStrings("busy", reply.payload);
    try testing.expectEqual(0, s.client.inbox.pendingCount(testing.io));
    try s.finish();
}

test "a request times out at its deadline, and its reply counts as late when it comes" {
    const io = testing.io;
    var s: Served = undefined;
    try s.start(.{ .servers = &.{} });
    defer s.deinit();
    const start = Io.Clock.awake.now(io);
    try testing.expectError(error.Timeout, s.client.request("slow.300", "x", within(50)));
    try testing.expect(start.durationTo(Io.Clock.awake.now(io)).toMilliseconds() >= 50);
    try testing.expectEqual(0, s.client.inbox.pendingCount(io));
    // The server sends the reply before it answers this PING.
    try s.client.flush(quick);
    try testing.expectEqual(1, s.client.inbox.lateResponses(io));
    try s.finish();
}

fn requestSilent(client: *Client, options: nats.RequestOptions) Client.RequestError!nats.Message {
    return client.request("silent.x", "?", options);
}

/// Waits until `count` requests wait for their replies, for 5 s at most.
fn awaitAwaiting(client: *Client, count: u32) !void {
    const io = client.io;
    const give_up = time.after(io, .fromSeconds(5 * @as(i64, test_wait.timeoutFactor())));
    while (client.inbox.awaitingCount(io) < count) {
        if (time.expired(io, give_up)) return error.TestNeverWaited;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn elapsedSince(io: Io, start: Io.Timestamp) Io.Duration {
    return start.durationTo(Io.Clock.awake.now(io));
}

/// The result of a future is `expected`; a reply instead fails the test,
/// and the future's deferred cancel frees it.
fn expectNoReply(result: Client.RequestError!nats.Message, expected: Client.RequestError) !void {
    if (result) |_| return error.TestUnexpectedReply else |err| try testing.expectEqual(expected, err);
}

fn releaseReply(result: Client.RequestError!nats.Message) void {
    if (result) |reply| {
        var m = reply;
        m.deinit();
    } else |_| {}
}

test "a canceled request returns Canceled and leaves nothing behind" {
    const io = testing.io;
    var s: Served = undefined;
    try s.start(.{ .servers = &.{} });
    defer s.deinit();
    var request = try io.concurrent(requestSilent, .{ &s.client, within(30_000) });
    defer releaseReply(request.cancel(io));
    try awaitAwaiting(&s.client, 1);
    try expectNoReply(request.cancel(io), error.Canceled);
    try testing.expectEqual(0, s.client.inbox.pendingCount(io));
    try s.finish();
}

fn requestHangup(client: *Client) Client.RequestError!nats.Message {
    return client.request("hangup.now", "?", within(30_000));
}

test "the connection lost while a request waits: Disconnected at once, then ConnectionClosed" {
    const io = testing.io;
    var s: Served = undefined;
    try s.start(.{ .servers = &.{}, .reconnect = .{ .enabled = false } });
    defer s.deinit();
    var waiting = try io.concurrent(requestSilent, .{ &s.client, within(30_000) });
    defer releaseReply(waiting.cancel(io));
    try awaitAwaiting(&s.client, 1);
    const start = Io.Clock.awake.now(io);
    // The server hangs up on this one.
    try expectNoReply(requestHangup(&s.client), error.Disconnected);
    try expectNoReply(waiting.await(io), error.Disconnected);
    if (test_wait.timing()) try testing.expect(elapsedSince(io, start).toSeconds() < 2);
    try testing.expectEqual(0, s.client.inbox.pendingCount(io));
    // With reconnect off the lost connection closes the client; until it
    // is closed, a new request fails with Disconnected too.
    try awaitState(&s.client, .closed);
    try testing.expectError(error.ConnectionClosed, s.client.request("echo.x", "?", five_seconds));
    try s.server.await(io);
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

test "close() while a request waits: ConnectionClosed at once" {
    const io = testing.io;
    var s: Served = undefined;
    try s.start(.{ .servers = &.{} });
    defer s.deinit();
    var waiting = try io.concurrent(requestSilent, .{ &s.client, within(30_000) });
    defer releaseReply(waiting.cancel(io));
    try awaitAwaiting(&s.client, 1);
    const start = Io.Clock.awake.now(io);
    s.client.close();
    try expectNoReply(waiting.await(io), error.ConnectionClosed);
    if (test_wait.timing()) try testing.expect(elapsedSince(io, start).toSeconds() < 1);
    try testing.expectError(error.ConnectionClosed, s.client.request("echo.x", "?", five_seconds));
    try s.server.await(io);
}

test "no more pending requests than limits.max_pending_requests" {
    const io = testing.io;
    var s: Served = undefined;
    try s.start(.{ .servers = &.{}, .limits = .{ .max_pending_requests = 2 } });
    defer s.deinit();
    var first = try io.concurrent(requestSilent, .{ &s.client, within(30_000) });
    defer releaseReply(first.cancel(io));
    var second = try io.concurrent(requestSilent, .{ &s.client, within(30_000) });
    defer releaseReply(second.cancel(io));
    try awaitAwaiting(&s.client, 2);
    try testing.expectError(error.TooManyPendingRequests, s.client.request("echo.x", "?", five_seconds));
    try expectNoReply(first.cancel(io), error.Canceled);
    try expectReply(&s.client, "echo.x", "room", "room");
    try expectNoReply(second.cancel(io), error.Canceled);
    try s.finish();
}

test "a request checks its arguments first, then the connection" {
    var client: Client = try .init(testing.allocator, testing.io, .{ .servers = &.{"nats://127.0.0.1:4222"} });
    defer client.deinit();
    try testing.expectError(error.InvalidOptions, client.request("echo.x", "?", .{ .timeout = .none }));
    try testing.expectError(error.InvalidOptions, client.requestMessage(.{ .subject = "echo.x", .reply_to = "mine" }, five_seconds));
    try testing.expectError(error.InvalidSubject, client.request("echo.*", "?", five_seconds));
    try testing.expectError(error.InvalidHeader, client.requestMessage(.{ .subject = "echo.x", .headers = &.{.{ .name = "X", .value = "a\r\nb" }} }, five_seconds));
    try testing.expectError(error.Disconnected, client.request("echo.x", "?", five_seconds));
    client.close();
    try testing.expectError(error.ConnectionClosed, client.request("echo.x", "?", five_seconds));
}

test "the line of a request counts its reply subject: 4096 argument bytes pass, one more is InvalidSubject" {
    var s: Served = undefined;
    try s.start(.{ .servers = &.{} });
    defer s.deinit();
    // PUB <subject> _INBOX.<token>.<id> 0: the subject, the reply subject
    // with the id of the request, the size and two spaces.
    const subject: [4096]u8 = @splat('e');
    var name = subject;
    @memcpy(name[0..5], "echo.");
    const reply_len = Inbox.prefix_len + 1;
    const fits = 4096 - reply_len - 3;
    var reply = try s.client.request(name[0..fits], "", five_seconds);
    reply.deinit();
    // The second request has id 2: still one digit.
    try testing.expectError(error.InvalidSubject, s.client.request(name[0 .. fits + 1], "", five_seconds));
    try testing.expectEqual(0, s.client.inbox.pendingCount(testing.io));
    try s.finish();
    try testing.expectEqual(1, s.record.count("PUB echo."));
}

/// A handshake, then nothing is read until `release` is set: the client's
/// writes back up in the socket.
fn serveStalled(io: Io, listener: *net.Server, release: *Io.Event) anyerror!void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try handshake(&peer);
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

/// Publishes `payload` until a publish fails; counts the ones that went in.
fn publishUntilError(client: *Client, payload: []const u8, published: *std.atomic.Value(u32)) Client.PublishError!void {
    while (true) {
        try client.publish("stalled", payload);
        _ = published.fetchAdd(1, .monotonic);
    }
}

/// Waits until a publish is stuck: it waits for room, and none went in for
/// 200 ms. 10 s at most.
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
        } else if (elapsedSince(io, still_since).toMilliseconds() >= 200) {
            return;
        }
        if (time.expired(io, give_up)) return error.TestPublishNeverWaited;
    }
}

test "a request that waits for room in the outbound queue ends at its deadline" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var release: Io.Event = .unset;
    var server = try io.concurrent(serveStalled, .{ io, &listener, &release });
    defer {
        release.set(io);
        server.cancel(io) catch {};
    }
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{
        .servers = &.{try FakeServer.url(&listener, &url)},
        .limits = .{ .outbound_bytes = 1 },
    });
    defer client.deinit();
    try client.connect();
    const payload = try testing.allocator.alloc(u8, 1024 * 1024);
    defer testing.allocator.free(payload);
    @memset(payload, 'b');
    var published: std.atomic.Value(u32) = .init(0);
    var publisher = try io.concurrent(publishUntilError, .{ &client, payload, &published });
    defer publisher.cancel(io) catch {};
    try awaitStuck(&client, &published);

    // The SUB of the inbox and the PUB wait behind the stuck publish.
    const start = Io.Clock.awake.now(io);
    try testing.expectError(error.Timeout, client.request("echo.x", "?", within(100)));
    const took = elapsedSince(io, start).toMilliseconds();
    try testing.expect(took >= 100);
    if (test_wait.timing()) try testing.expect(took < 2000);
    try testing.expectEqual(0, client.inbox.pendingCount(io));
    try testing.expect(client.isConnected());
}

/// After the handshake, waits for the SUB of the client, sends `messages`,
/// and records what the client sends after that, payloads included, until
/// it hangs up; PINGs get PONGs.
fn serveCalls(io: Io, listener: *net.Server, messages: []const u8, transcript: *std.ArrayList(u8)) anyerror!void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try handshake(&peer);
    while (!std.mem.startsWith(u8, try peer.readLine(), "SUB ")) {}
    try peer.send(messages);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    while (try peer.nextLine()) |line| {
        try transcript.appendSlice(testing.allocator, line);
        try transcript.appendSlice(testing.allocator, "\r\n");
        if (std.mem.eql(u8, line, "PING")) {
            try peer.send(golden.pong);
        } else if (std.mem.startsWith(u8, line, "PUB ") or std.mem.startsWith(u8, line, "HPUB ")) {
            const size = try std.fmt.parseInt(usize, line[std.mem.findScalarLast(u8, line, ' ').? + 1 ..], 10);
            try body.resize(testing.allocator, size + 2);
            try peer.readExact(body.items);
            try transcript.appendSlice(testing.allocator, body.items);
        }
    }
}

test "respond and respondMessage publish to the reply subject of the request" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var transcript: std.ArrayList(u8) = .empty;
    defer transcript.deinit(testing.allocator);
    var server = try io.concurrent(serveCalls, .{ io, &listener, "MSG svc 1 reply.one 3\r\nask\r\nMSG svc 1 2\r\nno\r\nMSG svc 1 bad.* 3\r\nodd\r\n", &transcript });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();
    const sub = try client.subscribe("svc", .{});
    defer sub.deinit();
    const within_five_seconds: nats.ReceiveOptions = .{ .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } } };

    var asked = (try sub.next(within_five_seconds)) orelse return error.TestNoMessage;
    defer asked.deinit();
    try client.respond(&asked, "answer");
    try client.respondMessage(&asked, .{ .headers = &.{.{ .name = "X-A", .value = "1" }}, .payload = "p" });
    try client.respondMessage(&asked, .{ .reply_to = "back.here" });

    // A message without a reply subject has no one to answer.
    var told = (try sub.next(within_five_seconds)) orelse return error.TestNoMessage;
    defer told.deinit();
    try testing.expectError(error.NoReplySubject, client.respond(&told, "nobody asked"));
    try testing.expectError(error.NoReplySubject, client.respondMessage(&told, .{}));
    // The server passes on any reply subject; one that cannot be published
    // to is refused.
    var odd = (try sub.next(within_five_seconds)) orelse return error.TestNoMessage;
    defer odd.deinit();
    try testing.expectError(error.InvalidSubject, client.respond(&odd, "x"));

    try client.flush(quick);
    client.close();
    try server.await(io);
    try testing.expectEqualStrings("PUB reply.one 6\r\nanswer\r\n" ++
        "HPUB reply.one 20 21\r\nNATS/1.0\r\nX-A: 1\r\n\r\np\r\n" ++
        "PUB reply.one back.here 0\r\n\r\n" ++
        "PING\r\n", transcript.items);
    try testing.expectError(error.ConnectionClosed, client.respond(&asked, "too late"));
}

fn many(milliseconds: i64, max_responses: u32) nats.RequestManyOptions {
    return .{ .timeout = .{ .duration = .{ .raw = .fromMilliseconds(milliseconds), .clock = .awake } }, .max_responses = max_responses };
}

/// Takes the next response and checks its payload.
fn expectResponse(responses: *nats.Responses, payload: []const u8) !void {
    var msg = (try responses.next(.{})) orelse return error.TestNoResponse;
    defer msg.deinit();
    try testing.expectEqualStrings(payload, msg.payload);
}

test "requestMany: the responses in order, and the stream ends after max_responses" {
    const io = testing.io;
    var s: Served = undefined;
    try s.start(.{ .servers = &.{} });
    defer s.deinit();
    const start = Io.Clock.awake.now(io);
    const responses = try s.client.requestMany("many.5", "?", many(30_000, 3));
    defer responses.deinit();
    try expectResponse(responses, "r1");
    try expectResponse(responses, "r2");
    try expectResponse(responses, "r3");
    try testing.expect(try responses.next(.{}) == null);
    try testing.expect(try responses.next(.{}) == null);
    if (test_wait.timing()) try testing.expect(elapsedSince(io, start).toSeconds() < 5);
    try testing.expectEqual(0, s.client.inbox.pendingCount(io));
    // The two responses after the third are late.
    try s.client.flush(quick);
    try testing.expectEqual(2, s.client.inbox.lateResponses(io));
    try s.finish();
    try testing.expectEqual(1, s.record.count("PUB many.5 _INBOX."));
}

test "requestMany: the stream ends at its deadline, and what came before comes out first" {
    const io = testing.io;
    var s: Served = undefined;
    try s.start(.{ .servers = &.{} });
    defer s.deinit();
    // Ample time for both replies, wherever timers are coarse.
    const responses = try s.client.requestMany("many.2", "?", many(1000, 32));
    defer responses.deinit();
    const deadline = responses.deadline;
    try expectResponse(responses, "r1");
    try expectResponse(responses, "r2");
    try testing.expect(try responses.next(.{}) == null);
    try testing.expect(time.expired(io, deadline));
    try testing.expectEqual(0, s.client.inbox.pendingCount(io));
    try s.finish();
}

test "requestMany: a reply after the deadline is late" {
    const io = testing.io;
    var s: Served = undefined;
    try s.start(.{ .servers = &.{} });
    defer s.deinit();
    const responses = try s.client.requestMany("slow.300", "x", many(50, 32));
    defer responses.deinit();
    try testing.expect(try responses.next(.{}) == null);
    try s.client.flush(quick);
    try testing.expectEqual(1, s.client.inbox.lateResponses(io));
    try s.finish();
}

test "requestMany: no responders first is NoResponders" {
    var s: Served = undefined;
    try s.start(.{ .servers = &.{} });
    defer s.deinit();
    const responses = try s.client.requestMany("nobody.home", "?", many(5000, 32));
    defer responses.deinit();
    try testing.expectError(error.NoResponders, responses.next(.{}));
    try testing.expectError(error.NoResponders, responses.next(.{}));
    // Over: it no longer counts among the pending requests.
    try testing.expectEqual(0, s.client.inbox.pendingCount(testing.io));
    try s.finish();
}

fn nextResponse(responses: *nats.Responses) nats.Responses.NextError!?nats.Message {
    return responses.next(.{});
}

fn releaseResponse(result: nats.Responses.NextError!?nats.Message) void {
    const got = result catch return;
    if (got) |msg| {
        var m = msg;
        m.deinit();
    }
}

/// Waits until a task waits in `responses.next()`, for 5 s at most.
fn awaitReceiving(responses: *nats.Responses) !void {
    const io = testing.io;
    const give_up = time.after(io, .fromSeconds(5 * @as(i64, test_wait.timeoutFactor())));
    while (!responses.messages.isReceiving(io)) {
        if (time.expired(io, give_up)) return error.TestReceiverNeverWaited;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "requestMany: cancel() from another task ends the stream at once" {
    const io = testing.io;
    var s: Served = undefined;
    try s.start(.{ .servers = &.{} });
    defer s.deinit();
    const responses = try s.client.requestMany("silent.x", "?", many(30_000, 32));
    defer responses.deinit();
    // A wait of the caller's own ends with Timeout; the stream goes on.
    try testing.expectError(error.Timeout, responses.next(.{ .timeout = .{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } } }));
    var receiver = try io.concurrent(nextResponse, .{responses});
    defer releaseResponse(receiver.cancel(io));
    try awaitReceiving(responses);
    const start = Io.Clock.awake.now(io);
    responses.cancel();
    try testing.expect(try receiver.await(io) == null);
    if (test_wait.timing()) try testing.expect(elapsedSince(io, start).toSeconds() < 1);
    try testing.expect(try responses.next(.{}) == null);
    try testing.expectEqual(0, s.client.inbox.pendingCount(io));
    try s.finish();
}

/// Waits until `responses` has received `count`, for 5 s at most.
fn awaitResponses(responses: *nats.Responses, count: u64) !void {
    const io = testing.io;
    const give_up = time.after(io, .fromSeconds(5 * @as(i64, test_wait.timeoutFactor())));
    while (responses.messages.stats(io).received < count) {
        if (time.expired(io, give_up)) return error.TestResponsesNeverCame;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "requestMany: the connection lost hands out what came, then Disconnected" {
    var s: Served = undefined;
    try s.start(.{ .servers = &.{} });
    defer s.deinit();
    const responses = try s.client.requestMany("manyhangup.2", "?", many(30_000, 32));
    defer responses.deinit();
    try expectResponse(responses, "r1");
    try expectResponse(responses, "r2");
    try testing.expectError(error.Disconnected, responses.next(.{}));
    try s.server.await(testing.io);
}

test "requestMany: close() ends the stream at once, with ConnectionClosed" {
    const io = testing.io;
    var s: Served = undefined;
    try s.start(.{ .servers = &.{} });
    defer s.deinit();
    const responses = try s.client.requestMany("many.2", "?", many(30_000, 32));
    defer responses.deinit();
    try awaitResponses(responses, 2);
    s.client.close();
    try testing.expectError(error.ConnectionClosed, responses.next(.{}));
    try testing.expectError(error.ConnectionClosed, s.client.requestMany("many.1", "?", many(5000, 32)));
    try s.server.await(io);
}

test "requestMany: responses that do not fit in max_bytes are dropped, and count" {
    var s: Served = undefined;
    try s.start(.{ .servers = &.{} });
    defer s.deinit();
    // Each response takes its reply subject and two bytes: room for two.
    const one = Inbox.prefix_len + 1 + 2;
    var options = many(30_000, 3);
    options.max_bytes = 2 * one + 1;
    const responses = try s.client.requestMany("many.3", "?", options);
    defer responses.deinit();
    // Taking one would make room: all three come first.
    try awaitResponses(responses, 3);
    try expectResponse(responses, "r1");
    try expectResponse(responses, "r2");
    try testing.expect(try responses.next(.{}) == null);
    try testing.expectEqual(nats.SubscriptionStats{ .received = 3, .delivered = 2, .dropped = 1 }, responses.messages.stats(testing.io));
    try s.finish();
}

test "requestMany refuses a timeout of .none, and max_responses or max_bytes of 0" {
    var client: Client = try .init(testing.allocator, testing.io, .{ .servers = &.{"nats://127.0.0.1:4222"} });
    defer client.deinit();
    try testing.expectError(error.InvalidOptions, client.requestMany("x", "?", .{ .timeout = .none }));
    try testing.expectError(error.InvalidOptions, client.requestMany("x", "?", .{ .max_responses = 0 }));
    try testing.expectError(error.InvalidOptions, client.requestMany("x", "?", .{ .max_bytes = 0 }));
    try testing.expectError(error.InvalidSubject, client.requestMany("x.*", "?", .{}));
    try testing.expectError(error.Disconnected, client.requestMany("x", "?", .{}));
}

test "a requestMany not freed by its owner is freed with the client" {
    var s: Served = undefined;
    try s.start(.{ .servers = &.{} });
    defer s.deinit();
    _ = try s.client.requestMany("many.1", "?", many(30_000, 32));
    // testing.allocator reports the stream if the client leaks it.
}

/// After the handshake, answers every request at a moment its payload
/// names, "<awake ns> <shift ns>": the request's own deadline and a shift
/// from it. PINGs get PONGs; `sent` is set before each reply goes out.
fn serveAtMoment(io: Io, listener: *net.Server, sent: ?*std.atomic.Value(u32)) anyerror!void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try handshake(&peer);
    var sid: u64 = 0;
    var body: [128]u8 = undefined;
    while (try peer.nextLine()) |line| {
        var args = std.mem.tokenizeScalar(u8, line, ' ');
        const op = args.next() orelse continue;
        if (std.mem.eql(u8, op, "PING")) {
            try peer.send(golden.pong);
        } else if (std.mem.eql(u8, op, "SUB")) {
            _ = args.next();
            sid = try std.fmt.parseInt(u64, args.rest(), 10);
        } else if (std.mem.eql(u8, op, "PUB")) {
            _ = args.next();
            const reply = args.next() orelse return error.TestBadPub;
            const size = try std.fmt.parseInt(usize, args.rest(), 10);
            if (size + 2 > body.len) return error.TestBadPub;
            try peer.readExact(body[0 .. size + 2]);
            const payload = body[0..size];
            var numbers = std.mem.tokenizeScalar(u8, payload, ' ');
            const moment = try std.fmt.parseInt(i96, numbers.next() orelse return error.TestBadPayload, 10) +
                try std.fmt.parseInt(i96, numbers.next() orelse return error.TestBadPayload, 10);
            const left = moment - Io.Clock.awake.now(io).nanoseconds;
            if (left > 0) try io.sleep(.fromNanoseconds(@intCast(left)), .awake);
            if (sent) |counter| _ = counter.fetchAdd(1, .release);
            var head: [128]u8 = undefined;
            try peer.send(try std.fmt.bufPrint(&head, "MSG {s} {d} {d}\r\n", .{ reply, sid, payload.len }));
            try peer.send(payload);
            try peer.send("\r\n");
        }
    }
}

/// How the requests of a race ended.
const Tally = struct {
    replies: u32 = 0,
    ended: u32 = 0,
};

/// One client and its server: `rounds` requests one after another, each
/// answered at its own deadline shifted by -2 to +1 ms. Every request must
/// end with its reply or with Timeout, and every reply the server sent
/// that a request did not take must count as late. A request already past
/// its deadline when its frame would go in sends nothing.
fn raceTimeouts(rounds: u32, tally: *Tally) !void {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var sent: std.atomic.Value(u32) = .init(0);
    var server = try io.concurrent(serveAtMoment, .{ io, &listener, &sent });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();
    for (0..rounds) |i| {
        const deadline = time.after(io, .fromMilliseconds(4));
        const shift: i96 = (@as(i96, @intCast(i % 13)) - 8) * 250 * std.time.ns_per_us;
        var buffer: [64]u8 = undefined;
        const payload = try std.fmt.bufPrint(&buffer, "{d} {d}", .{ deadline.raw.nanoseconds, shift });
        if (client.request("race", payload, .{ .timeout = .{ .deadline = deadline } })) |reply| {
            var m = reply;
            defer m.deinit();
            try testing.expectEqualStrings(payload, m.payload);
            tally.replies += 1;
        } else |err| switch (err) {
            error.Timeout => tally.ended += 1,
            else => return err,
        }
    }
    // The server answers this PING after every reply: they are all in.
    try client.flush(quick);
    try testing.expectEqual(rounds, tally.replies + tally.ended);
    try testing.expectEqual(@as(u64, sent.load(.acquire) - tally.replies), client.inbox.lateResponses(io));
    try testing.expectEqual(0, client.inbox.pendingCount(io));
    client.close();
    try server.await(io);
}

fn raceTimeoutsTask(rounds: u32, tally: *Tally, failure: *?anyerror) void {
    raceTimeouts(rounds, tally) catch |err| {
        failure.* = err;
    };
}

test "a reply that comes at the moment of the timeout, 1000 times: the reply or Timeout, never both" {
    const io = testing.io;
    const pairs = 10;
    var tallies: [pairs]Tally = @splat(.{});
    var failures: [pairs]?anyerror = @splat(null);
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (&tallies, &failures) |*tally, *failure| try group.concurrent(io, raceTimeoutsTask, .{ 100, tally, failure });
    try group.await(io);
    for (failures) |failure| if (failure) |err| return err;
    var total: Tally = .{};
    for (tallies) |tally| {
        total.replies += tally.replies;
        total.ended += tally.ended;
    }
    try testing.expectEqual(1000, total.replies + total.ended);
}

fn requestRace(client: *Client, payload: []const u8) Client.RequestError!nats.Message {
    return client.request("race", payload, five_seconds);
}

/// One client and its server: `rounds` requests, each canceled from
/// another task as its reply comes: 0 to 300 µs after the server sent it.
/// Every request must end with its reply or with Canceled, and every reply
/// that a request did not take must count as late.
fn raceCancels(rounds: u32, tally: *Tally) !void {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var sent: std.atomic.Value(u32) = .init(0);
    var server = try io.concurrent(serveAtMoment, .{ io, &listener, &sent });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();
    for (0..rounds) |i| {
        // At once: the moment has passed when the server reads it.
        var buffer: [64]u8 = undefined;
        const payload = try std.fmt.bufPrint(&buffer, "0 {d}", .{i});
        var request = try io.concurrent(requestRace, .{ &client, payload });
        const give_up = time.after(io, .fromSeconds(5 * @as(i64, test_wait.timeoutFactor())));
        while (sent.load(.acquire) <= i) {
            if (time.expired(io, give_up)) {
                releaseReply(request.cancel(io));
                return error.TestNeverAnswered;
            }
            std.atomic.spinLoopHint();
        }
        // The reply is on its way through the socket and the reader.
        const cancel_at = time.after(io, .fromMicroseconds(@intCast(i % 16 * 20)));
        while (!time.expired(io, cancel_at)) std.atomic.spinLoopHint();
        if (request.cancel(io)) |reply| {
            var m = reply;
            m.deinit();
            tally.replies += 1;
        } else |err| switch (err) {
            error.Canceled => tally.ended += 1,
            else => return err,
        }
    }
    try client.flush(quick);
    try testing.expectEqual(rounds, tally.replies + tally.ended);
    try testing.expectEqual(@as(u64, tally.ended), client.inbox.lateResponses(io));
    try testing.expectEqual(0, client.inbox.pendingCount(io));
    client.close();
    try server.await(io);
}

test "a cancel that comes with the reply, 200 times: the reply or Canceled, never both" {
    var tally: Tally = .{};
    try raceCancels(200, &tally);
    try testing.expectEqual(200, tally.replies + tally.ended);
}

// The client owns every stream until its deinit(), however the stream
// ended: testing.allocator reports one the client leaks.

test "a requestMany stream that ended with null, not freed by its owner, is freed with the client" {
    var s: Served = undefined;
    try s.start(.{ .servers = &.{} });
    defer s.deinit();
    const responses = try s.client.requestMany("many.1", "?", many(30_000, 1));
    try expectResponse(responses, "r1");
    try testing.expect(try responses.next(.{}) == null);
}

test "a requestMany stream ended by cancel(), not freed by its owner, is freed with the client" {
    var s: Served = undefined;
    try s.start(.{ .servers = &.{} });
    defer s.deinit();
    const responses = try s.client.requestMany("silent.x", "?", many(30_000, 4));
    responses.cancel();
}

test "a requestMany stream ended by NoResponders, not freed by its owner, is freed with the client" {
    var s: Served = undefined;
    try s.start(.{ .servers = &.{} });
    defer s.deinit();
    const responses = try s.client.requestMany("nobody.home", "?", many(30_000, 4));
    try testing.expectError(error.NoResponders, responses.next(.{}));
}

test "a requestMany stream ended by a lost connection, not freed by its owner, is freed with the client" {
    var s: Served = undefined;
    try s.start(.{ .servers = &.{} });
    defer s.deinit();
    const responses = try s.client.requestMany("manyhangup.1", "?", many(30_000, 4));
    try expectResponse(responses, "r1");
    try testing.expectError(error.Disconnected, responses.next(.{}));
}

test "a requestMany stream ended by close(), not freed by its owner, is freed with the client" {
    var s: Served = undefined;
    try s.start(.{ .servers = &.{} });
    defer s.deinit();
    const responses = try s.client.requestMany("silent.x", "?", many(30_000, 4));
    s.client.close();
    try testing.expectError(error.ConnectionClosed, responses.next(.{}));
}

test "close() after a stream ended normally: its next() is ConnectionClosed, as for a subscription" {
    var s: Served = undefined;
    try s.start(.{ .servers = &.{} });
    defer s.deinit();
    const responses = try s.client.requestMany("many.1", "?", many(30_000, 1));
    defer responses.deinit();
    try expectResponse(responses, "r1");
    try testing.expect(try responses.next(.{}) == null);
    s.client.close();
    try testing.expectError(error.ConnectionClosed, responses.next(.{}));
}

test "cancel() after the stream ended drops what waits, and next() is null" {
    var s: Served = undefined;
    try s.start(.{ .servers = &.{} });
    defer s.deinit();
    // Ended by max_responses, both responses waiting.
    const full = try s.client.requestMany("many.2", "?", many(30_000, 2));
    defer full.deinit();
    try awaitResponses(full, 2);
    full.cancel();
    try testing.expect(try full.next(.{}) == null);
    try testing.expectEqual(nats.PendingCounts{ .messages = 0, .bytes = 0 }, full.messages.pending(testing.io));
    // Ended by no responders.
    const nobody = try s.client.requestMany("nobody.home", "?", many(30_000, 2));
    defer nobody.deinit();
    try testing.expectError(error.NoResponders, nobody.next(.{}));
    nobody.cancel();
    try testing.expect(try nobody.next(.{}) == null);
    try s.finish();
}

test "cancel() after a lost connection drops what came, and next() is null; after close() it stays ConnectionClosed" {
    var s: Served = undefined;
    try s.start(.{ .servers = &.{}, .reconnect = .{ .enabled = false } });
    defer s.deinit();
    const lost = try s.client.requestMany("manyhangup.1", "?", many(30_000, 4));
    defer lost.deinit();
    try awaitResponses(lost, 1);
    try awaitState(&s.client, .closed);
    lost.cancel();
    try testing.expect(try lost.next(.{}) == null);
    try s.server.await(testing.io);
    // The client is closed now: a stream it ended stays ConnectionClosed.
    s.client.close();
    lost.cancel();
    try testing.expectError(error.ConnectionClosed, lost.next(.{}));
}

/// After the handshake, refuses the client's inbox subscription as a
/// server does when the account may not subscribe to `_INBOX.>`; answers
/// PINGs and nothing else.
fn serveRefusingInbox(io: Io, listener: *net.Server) anyerror!void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try handshake(&peer);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    while (try peer.nextLine()) |line| {
        var args = std.mem.tokenizeScalar(u8, line, ' ');
        const op = args.next() orelse continue;
        if (std.mem.eql(u8, op, "PING")) {
            try peer.send(golden.pong);
        } else if (std.mem.eql(u8, op, "SUB")) {
            const subject = args.next() orelse return error.TestBadSub;
            var buffer: [256]u8 = undefined;
            if (std.mem.startsWith(u8, subject, "_INBOX.")) {
                try peer.send(try std.fmt.bufPrint(&buffer, "-ERR 'Permissions Violation for Subscription to \"{s}\"'\r\n", .{subject}));
            }
        } else if (std.mem.eql(u8, op, "PUB")) {
            const size = try std.fmt.parseInt(usize, line[std.mem.findScalarLast(u8, line, ' ').? + 1 ..], 10);
            try body.resize(testing.allocator, size + 2);
            try peer.readExact(body.items);
        }
    }
}

test "a server that refuses the inbox: requests fail with PermissionDenied at once, the connection stays" {
    // The client warns about the server's error; this test expects it.
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(serveRefusingInbox, .{ io, &listener });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();
    const start = Io.Clock.awake.now(io);
    try testing.expectError(error.PermissionDenied, client.request("x", "?", within(30_000)));
    if (test_wait.timing()) try testing.expect(elapsedSince(io, start).toSeconds() < 2);
    try testing.expectError(error.PermissionDenied, client.request("x", "?", within(30_000)));
    try testing.expectError(error.PermissionDenied, client.requestMany("x", "?", many(30_000, 4)));
    try testing.expectEqual(0, client.inbox.pendingCount(io));
    try client.publish("x", "still up");
    try client.flush(quick);
    try testing.expect(client.isConnected());
    client.close();
    try server.await(io);
}

test "a reply over max_inbound_frame_bytes is dropped, and the request ends with Timeout" {
    // The client warns about the reply it drops; this test expects it.
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    const io = testing.io;
    var s: Served = undefined;
    try s.start(.{ .servers = &.{}, .limits = .{ .max_inbound_frame_bytes = 1024, .max_header_bytes = 512 } });
    defer s.deinit();
    const big: [2000]u8 = @splat('x');
    const start = Io.Clock.awake.now(io);
    try testing.expectError(error.Timeout, s.client.request("echo.big", &big, within(300)));
    try testing.expect(elapsedSince(io, start).toMilliseconds() >= 300);
    try testing.expectEqual(0, s.client.inbox.pendingCount(io));
    // Dropped, not late: it came while the request waited.
    try testing.expectEqual(0, s.client.inbox.lateResponses(io));
    try expectReply(&s.client, "echo.small", "ok", "ok");
    // Its event names no subscription: the user has none for replies.
    while (true) {
        const event = (try s.client.nextEvent(.{ .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } } })) orelse return error.TestNoEvent;
        if (event != .message_dropped) continue;
        try testing.expectEqual(.too_large, event.message_dropped.reason);
        try testing.expect(event.message_dropped.sid == null);
        break;
    }
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

test "a reply there is no memory for is dropped, and the request ends with Timeout" {
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    var server = try io.concurrent(serveRequests, .{ io, &listener, &record });
    defer server.cancel(io) catch {};
    // The reply to the first request: its subject, _INBOX.<token>.1, and
    // the payload, in one allocation the allocator refuses.
    const payload: [12345]u8 = @splat('m');
    var refuse: RefuseOneSize = .{ .parent = testing.allocator, .size = Inbox.prefix_len + 1 + payload.len };
    var url: [64]u8 = undefined;
    var client: Client = try .init(refuse.allocator(), io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();
    try testing.expectError(error.Timeout, client.request("echo.oom", &payload, within(300)));
    try testing.expectEqual(0, client.inbox.pendingCount(io));
    try expectReply(&client, "echo.small", "ok", "ok");
    try client.flush(quick);
    client.close();
    try server.await(io);
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

test "a response larger than max_bytes on its own is dropped before it is allocated, and counts" {
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var record: Record = .{};
    defer record.deinit();
    var server = try io.concurrent(serveRequests, .{ io, &listener, &record });
    defer server.cancel(io) catch {};
    const big: [100]u8 = @splat('y');
    // The response to the first request: _INBOX.<token>.1 and the payload.
    var counting: CountOneSize = .{ .parent = testing.allocator, .size = Inbox.prefix_len + 1 + big.len };
    var url: [64]u8 = undefined;
    var client: Client = try .init(counting.allocator(), io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();
    var options = many(30_000, 2);
    options.max_bytes = 40;
    const responses = try client.requestMany("echo.x", &big, options);
    defer responses.deinit();
    try awaitResponses(responses, 1);
    try testing.expectEqual(nats.SubscriptionStats{ .received = 1, .delivered = 0, .dropped = 1 }, responses.messages.stats(io));
    try testing.expectEqual(0, counting.count.load(.monotonic));
    try client.flush(quick);
    client.close();
    try server.await(io);
}

/// After the handshake, answers the first request with "no responders",
/// then reads nothing until `release` is set: the client's writes back up.
fn serveOneThenStall(io: Io, listener: *net.Server, release: *Io.Event) anyerror!void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try handshake(&peer);
    var sid: u64 = 0;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    while (try peer.nextLine()) |line| {
        var args = std.mem.tokenizeScalar(u8, line, ' ');
        const op = args.next() orelse continue;
        if (std.mem.eql(u8, op, "SUB")) {
            _ = args.next();
            sid = try std.fmt.parseInt(u64, args.rest(), 10);
        } else if (std.mem.eql(u8, op, "PUB")) {
            const subject = args.next() orelse return error.TestBadPub;
            const reply = args.next() orelse return error.TestBadPub;
            const size = try std.fmt.parseInt(usize, args.rest(), 10);
            try body.resize(testing.allocator, size + 2);
            try peer.readExact(body.items);
            var buffer: [256]u8 = undefined;
            const block_len = 32 + subject.len;
            try peer.send(try std.fmt.bufPrint(&buffer, "HMSG {s} {d} {d} {d}\r\nNATS/1.0 503\r\nNats-Subject: {s}\r\n\r\n\r\n", .{ reply, sid, block_len, block_len, subject }));
            break;
        }
    }
    try awaitEvent(io, release);
    _ = try peer.readToEnd();
}

test "a request whose PUB waits for room in the outbound queue ends at its deadline" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var release: Io.Event = .unset;
    var server = try io.concurrent(serveOneThenStall, .{ io, &listener, &release });
    defer {
        release.set(io);
        server.cancel(io) catch {};
    }
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{
        .servers = &.{try FakeServer.url(&listener, &url)},
        .limits = .{ .outbound_bytes = 1 },
    });
    defer client.deinit();
    try client.connect();
    // The first request makes the inbox subscription; then the server
    // stops reading.
    try testing.expectError(error.NoResponders, client.request("nobody.home", "?", five_seconds));
    const payload = try testing.allocator.alloc(u8, 1024 * 1024);
    defer testing.allocator.free(payload);
    @memset(payload, 'b');
    var published: std.atomic.Value(u32) = .init(0);
    var publisher = try io.concurrent(publishUntilError, .{ &client, payload, &published });
    defer publisher.cancel(io) catch {};
    try awaitStuck(&client, &published);

    // The inbox is in place: this request waits for room with its PUB.
    const start = Io.Clock.awake.now(io);
    try testing.expectError(error.Timeout, client.request("echo.x", "?", within(100)));
    const took = elapsedSince(io, start).toMilliseconds();
    try testing.expect(took >= 100);
    if (test_wait.timing()) try testing.expect(took < 2000);
    try testing.expectEqual(0, client.inbox.pendingCount(io));
    try testing.expect(client.isConnected());
}
