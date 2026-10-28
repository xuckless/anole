// Adapted from vkiryakov/zefir src/nats/testing/client_tests.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! The client against a fake server on loopback. Each test starts its own
//! server function in a task and cancels it on the way out; the client's
//! waits are bounded, so a mistake fails a test instead of hanging it.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const testing = std.testing;
const nats = @import("../root.zig");
const Client = nats.Client;
const FakeServer = @import("FakeServer.zig");
const golden = @import("../protocol/golden.zig");
const time = @import("../engine/time.zig");

/// The server's side of the handshake, with headers.
fn handshake(peer: *FakeServer.Peer) !void {
    try peer.send(golden.info_default);
    const connect_line = try peer.readLine();
    if (!std.mem.startsWith(u8, connect_line, "CONNECT {")) return error.TestNotConnect;
    try peer.expectLine("PING");
    // A real server sends a second INFO right after the first PONG.
    try peer.send(golden.pong ++ golden.info_connected);
}

/// A handshake, then a PONG for every PING until the client hangs up.
fn serveNormally(io: Io, listener: *net.Server) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try handshake(&peer);
    while (try peer.nextLine()) |line| {
        if (std.mem.eql(u8, line, "PING")) {
            try peer.send(golden.pong);
        } else if (!std.mem.eql(u8, line, "PONG")) {
            return error.TestUnexpectedLine;
        }
    }
}

const quick: nats.FlushOptions = .{ .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } } };

test "connect, flush, rtt and close" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(serveNormally, .{ io, &listener });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();

    try client.connect();
    try testing.expect(client.isConnected());
    try testing.expectEqual(.connected, client.state());
    const server_address = client.connectedServer() orelse return error.TestNotConnected;
    try testing.expectEqualStrings("127.0.0.1", server_address.host());
    try client.flush(quick);
    const round_trip = try client.rtt(quick);
    try testing.expect(round_trip.nanoseconds >= 0);
    const info = (try client.serverInfo(testing.allocator)) orelse return error.TestNoInfo;
    defer info.deinit();
    try testing.expectEqualStrings("2.15.1", info.value.version);

    // A second connect() changes nothing.
    try client.connect();
    try testing.expect(client.isConnected());

    client.close();
    try testing.expectEqual(.closed, client.state());
    try testing.expect(client.connectedServer() == null);
    try testing.expect(try client.serverInfo(testing.allocator) == null);
    try testing.expectError(error.ConnectionClosed, client.flush(quick));
    try testing.expectError(error.ConnectionClosed, client.connect());
    client.close();
    try server.await(io);
}

/// Waits until the client reaches `expected`, for 5 s at most.
fn awaitState(client: *Client, expected: nats.State) !void {
    const io = client.io;
    const give_up = time.after(io, .fromSeconds(5));
    while (client.state() != expected) {
        if (time.expired(io, give_up)) return error.TestStateNeverReached;
        try io.sleep(.fromMilliseconds(2), .awake);
    }
}

/// Waits until `event` is set, for 5 s at most.
fn awaitEvent(io: Io, event: *Io.Event) !void {
    const give_up = time.after(io, .fromSeconds(5));
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

const second_info = "INFO {\"server_id\":\"second\",\"version\":\"2.15.1\",\"proto\":1,\"headers\":true,\"max_payload\":2048} \r\n";

/// INFO number two right after the first PONG and a PING of its own; then
/// PONGs for the client's PINGs. The client must have answered the PING
/// by the time it hangs up.
fn serveSecondInfo(io: Io, listener: *net.Server, answered: *std.atomic.Value(bool)) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try peer.send(golden.info_default);
    _ = try peer.readLine();
    try peer.expectLine("PING");
    try peer.send(golden.pong ++ second_info ++ golden.ping);
    while (try peer.nextLine()) |line| {
        if (std.mem.eql(u8, line, "PING")) try peer.send(golden.pong);
        if (std.mem.eql(u8, line, "PONG")) answered.store(true, .release);
    }
    if (!answered.load(.acquire)) return error.TestPingNotAnswered;
}

test "a later INFO replaces the first, and a server PING gets its PONG" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var answered: std.atomic.Value(bool) = .init(false);
    var server = try io.concurrent(serveSecondInfo, .{ io, &listener, &answered });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();

    const give_up = time.after(io, .fromSeconds(5));
    while (true) {
        const info = (try client.serverInfo(testing.allocator)) orelse return error.TestNoInfo;
        defer info.deinit();
        if (std.mem.eql(u8, info.value.server_id, "second")) {
            try testing.expectEqual(2048, info.value.max_payload);
            break;
        }
        if (time.expired(io, give_up)) return error.TestInfoNeverReplaced;
        try io.sleep(.fromMilliseconds(2), .awake);
    }
    // The PONG is queued when the reader takes the PING, and close() drops
    // what is still queued: wait until the server read it.
    const answer_by = time.after(io, .fromSeconds(10));
    while (!answered.load(.acquire)) {
        if (time.expired(io, answer_by)) return error.TestPingNotAnswered;
        try io.sleep(.fromMilliseconds(2), .awake);
    }
    client.close();
    try server.await(io);
}

/// A handshake, then silence: PINGs are read and counted, never answered.
fn serveSilently(io: Io, listener: *net.Server, pings: *usize) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try handshake(&peer);
    while (try peer.nextLine()) |line| {
        if (std.mem.eql(u8, line, "PING")) pings.* += 1;
    }
}

test "a server that stops answering is dropped after max_outstanding_pings PINGs" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var pings: usize = 0;
    var server = try io.concurrent(serveSilently, .{ io, &listener, &pings });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{
        .servers = &.{try FakeServer.url(&listener, &url)},
        .ping_interval = .fromMilliseconds(50),
        .max_outstanding_pings = 2,
        .reconnect = .{ .enabled = false },
    });
    defer client.deinit();
    const start = Io.Clock.awake.now(io);
    try client.connect();
    try awaitState(&client, .closed);
    // Two PINGs go out unanswered; the third interval finds them so.
    try testing.expect(elapsedSince(io, start).toMilliseconds() >= 150);
    try testing.expectError(error.ConnectionClosed, client.flush(quick));
    try server.await(io);
    // A slow writer may still hold the second one when the client gives up.
    try testing.expect(pings >= 1 and pings <= 2);
}

/// A handshake, then nothing read until the test is done: the socket fills.
fn serveNotReading(io: Io, listener: *net.Server, done: *Io.Event) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try handshake(&peer);
    try done.wait(io);
}

const megabyte: [1024 * 1024]u8 = @splat('p');

/// Publishes 1 MiB payloads until one fails.
fn publishMegabytes(client: *Client) void {
    while (true) client.publish("fill", &megabyte) catch return;
}

test "a server that stops reading while frames wait is dropped as stale, though no PING reached it" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var done: Io.Event = .unset;
    var server = try io.concurrent(serveNotReading, .{ io, &listener, &done });
    defer {
        done.set(io);
        server.cancel(io) catch {};
    }
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{
        .servers = &.{try FakeServer.url(&listener, &url)},
        .ping_interval = .fromMilliseconds(50),
        .max_outstanding_pings = 2,
        .limits = .{ .outbound_bytes = 1024 * 1024 },
        .reconnect = .{ .enabled = false },
    });
    defer client.deinit();
    try client.connect();
    var publisher = try io.concurrent(publishMegabytes, .{&client});
    defer publisher.cancel(io);
    try awaitState(&client, .closed);
    try testing.expectEqual(.connection_lost, client.close_reason.?);
    publisher.await(io);
}

/// What a slow server saw: the PINGs it answered.
const SlowLink = struct {
    pongs: std.atomic.Value(u32) = .init(0),
    done: Io.Event = .unset,

    /// Reads about 8 MB/s, a 64 KiB piece at a time, and answers every
    /// PING it reads, until the test is done.
    fn serve(link: *SlowLink, io: Io, listener: *net.Server) !void {
        var peer: FakeServer.Peer = undefined;
        try peer.accept(io, listener);
        defer peer.close();
        try handshake(&peer);
        while (!link.done.isSet()) {
            const line = (try peer.nextLine()) orelse return;
            if (std.mem.eql(u8, line, "PING")) {
                try peer.send(golden.pong);
                _ = link.pongs.fetchAdd(1, .monotonic);
            } else if (std.mem.startsWith(u8, line, "PUB ")) {
                var left = try std.fmt.parseInt(usize, line[std.mem.findScalarLast(u8, line, ' ').? + 1 ..], 10) + 2;
                while (left > 0) {
                    const piece = @min(left, 64 * 1024);
                    try peer.reader.interface.discardAll(piece);
                    left -= piece;
                    try io.sleep(.fromMilliseconds(8), .awake);
                }
            }
        }
    }
};

test "a live server behind a long backlog on a slow link is not dropped: PINGs that wait behind it do not count" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var link: SlowLink = .{};
    var server = try io.concurrent(SlowLink.serve, .{ &link, io, &listener });
    defer {
        link.done.set(io);
        server.cancel(io) catch {};
    }
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{
        .servers = &.{try FakeServer.url(&listener, &url)},
        // Two seconds for a PING the socket's buffers hold, a few MiB.
        .ping_interval = .fromSeconds(1),
        .max_outstanding_pings = 2,
        // About twice what the server reads in two PING intervals; one
        // batch of 16 frames takes it two seconds, written a part at a
        // time.
        .limits = .{ .outbound_bytes = 32 * 1024 * 1024 },
        .reconnect = .{ .enabled = false },
    });
    defer client.deinit();
    try client.connect();
    var publisher = try io.concurrent(publishMegabytes, .{&client});
    defer publisher.cancel(io);
    // Three intervals: a PING counted while it waits behind the backlog
    // would drop the connection after two.
    try io.sleep(.fromMilliseconds(3200), .awake);
    try testing.expectEqual(.connected, client.state());
    client.close();
    publisher.await(io);
}

/// For every client: a handshake, then the PONG of its first PING and a
/// hang-up at once.
fn answerThenHangUp(io: Io, listener: *net.Server) !void {
    while (true) {
        var peer: FakeServer.Peer = undefined;
        try peer.accept(io, listener);
        defer peer.close();
        handshake(&peer) catch |err| if (peer.canceled(err)) return error.Canceled else continue;
        const line = (peer.nextLine() catch |err| if (peer.canceled(err)) return error.Canceled else null) orelse continue;
        if (std.mem.eql(u8, line, "PING")) peer.send(golden.pong) catch |err| if (peer.canceled(err)) return error.Canceled;
    }
}

test "a flush whose PONG came succeeds, though the server hangs up right after" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(answerThenHangUp, .{ io, &listener });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    for (0..50) |_| {
        var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)}, .reconnect = .{ .enabled = false } });
        defer client.deinit();
        try client.connect();
        try client.flush(quick);
    }
}

/// A handshake; at the client's first PING the server hangs up instead.
fn serveAndHangUp(io: Io, listener: *net.Server) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try handshake(&peer);
    try peer.expectLine("PING");
}

test "with reconnect off, a server that hangs up closes the client, and a waiting flush learns it" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(serveAndHangUp, .{ io, &listener });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)}, .reconnect = .{ .enabled = false } });
    defer client.deinit();
    try client.connect();
    try testing.expectError(error.ConnectionClosed, client.flush(quick));
    try awaitState(&client, .closed);
    try testing.expect(client.connectedServer() == null);
    try server.await(io);
}

fn serveAndCount(io: Io, listener: *net.Server, first: []const u8, received: *usize) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try peer.send(first);
    received.* = try peer.readToEnd();
}

test "a server that wants TLS: UnsupportedSecurityFeature, and the password never leaves" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var received: usize = std.math.maxInt(usize);
    var server = try io.concurrent(serveAndCount, .{ io, &listener, "INFO " ++ golden.info_tls_json ++ " \r\n", &received });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{
        .servers = &.{try FakeServer.url(&listener, &url)},
        .auth = .{ .user_password = .{ .username = "alice", .password = "secret" } },
    });
    defer client.deinit();
    try testing.expectError(error.UnsupportedSecurityFeature, client.connect());
    try testing.expectEqual(.closed, client.state());
    try server.await(io);
    try testing.expectEqual(0, received);
}

fn serveAuthViolation(io: Io, listener: *net.Server) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try peer.send("INFO " ++ golden.info_auth_json ++ " \r\n");
    _ = try peer.readLine();
    try peer.expectLine("PING");
    try peer.send("-ERR 'Authorization Violation'\r\n");
    _ = try peer.readToEnd();
}

test "a wrong password: AuthenticationFailed" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(serveAuthViolation, .{ io, &listener });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{
        .servers = &.{try FakeServer.url(&listener, &url)},
        .auth = .{ .user_password = .{ .username = "alice", .password = "wrong" } },
    });
    defer client.deinit();
    try testing.expectError(error.AuthenticationFailed, client.connect());
    try testing.expectEqual(.closed, client.state());
    try server.await(io);
}

test "a server that never sends INFO, as with TLS first: Timeout" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var received: usize = std.math.maxInt(usize);
    var server = try io.concurrent(serveAndCount, .{ io, &listener, "", &received });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{
        .servers = &.{try FakeServer.url(&listener, &url)},
        .connect_timeout = .fromMilliseconds(100),
    });
    defer client.deinit();
    const start = Io.Clock.awake.now(io);
    try testing.expectError(error.Timeout, client.connect());
    const waited = elapsedSince(io, start);
    try testing.expect(waited.toMilliseconds() >= 100);
    try testing.expect(waited.toSeconds() < 5);
    try server.await(io);
    try testing.expectEqual(0, received);
}

/// A handshake; then PINGs are noted and never answered.
fn serveDeaf(io: Io, listener: *net.Server, ping_seen: *Io.Event) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try handshake(&peer);
    while (try peer.nextLine()) |line| {
        if (std.mem.eql(u8, line, "PING")) ping_seen.set(io);
    }
}

fn flushLong(client: *Client) Client.FlushError!void {
    return client.flush(.{ .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } } });
}

test "close() while another task waits in flush: ConnectionClosed at once" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var ping_seen: Io.Event = .unset;
    var server = try io.concurrent(serveDeaf, .{ io, &listener, &ping_seen });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.connect();

    var flusher = try io.concurrent(flushLong, .{&client});
    defer flusher.cancel(io) catch {};
    try awaitEvent(io, &ping_seen);
    const start = Io.Clock.awake.now(io);
    client.close();
    try testing.expectError(error.ConnectionClosed, flusher.await(io));
    try testing.expect(elapsedSince(io, start).toSeconds() < 1);
    try server.await(io);
}

/// A handshake; at the client's first PING, a -ERR that ends the
/// connection instead of PONG.
fn serveFatalError(io: Io, listener: *net.Server) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try handshake(&peer);
    try peer.expectLine("PING");
    try peer.send("-ERR 'Stale Connection'\r\n");
    _ = try peer.readToEnd();
}

test "with reconnect off, a -ERR that ends the connection closes the client" {
    // The client logs the server's error as a warning; this test expects it.
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(serveFatalError, .{ io, &listener });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)}, .reconnect = .{ .enabled = false } });
    defer client.deinit();
    try client.connect();
    try testing.expectError(error.ConnectionClosed, client.flush(quick));
    try awaitState(&client, .closed);
    try server.await(io);
}

test "connect tries the servers in order" {
    const io = testing.io;
    // A port nobody listens on comes first.
    var gone = try FakeServer.listen(io);
    var gone_url: [64]u8 = undefined;
    const dead = try FakeServer.url(&gone, &gone_url);
    gone.deinit(io);

    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(serveNormally, .{ io, &listener });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{ dead, try FakeServer.url(&listener, &url) }, .randomize_servers = false });
    defer client.deinit();
    try client.connect();
    const server_address = client.connectedServer() orelse return error.TestNotConnected;
    try testing.expectEqual(listener.socket.address.getPort(), server_address.port);
    client.close();
    try server.await(io);
}

/// Accepts a client, says nothing and notes that it got one.
fn serveMute(io: Io, listener: *net.Server, accepted: *Io.Event) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    accepted.set(io);
    _ = try peer.readToEnd();
}

fn connectLong(client: *Client) Client.ConnectError!void {
    return client.connect();
}

test "close() while another task waits in connect: ConnectionClosed at once" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var accepted: Io.Event = .unset;
    var server = try io.concurrent(serveMute, .{ io, &listener, &accepted });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{
        .servers = &.{try FakeServer.url(&listener, &url)},
        .connect_timeout = .fromSeconds(30),
    });
    defer client.deinit();

    var connector = try io.concurrent(connectLong, .{&client});
    defer connector.cancel(io) catch {};
    try awaitEvent(io, &accepted);
    const start = Io.Clock.awake.now(io);
    client.close();
    try testing.expectError(error.ConnectionClosed, connector.await(io));
    try testing.expect(elapsedSince(io, start).toSeconds() < 1);
    try testing.expectEqual(.closed, client.state());
    try server.await(io);
}

/// A handshake only once `release` is set, then a normal session; or, with
/// `reject`, a refusal of the credentials.
fn serveWhenReleased(io: Io, listener: *net.Server, release: *Io.Event, reject: bool) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try awaitEvent(io, release);
    if (reject) {
        try peer.send("INFO " ++ golden.info_auth_json ++ " \r\n");
        _ = try peer.readLine();
        try peer.expectLine("PING");
        try peer.send("-ERR 'Authorization Violation'\r\n");
        _ = try peer.readToEnd();
        return;
    }
    try handshake(&peer);
    while (try peer.nextLine()) |line| {
        if (std.mem.eql(u8, line, "PING")) try peer.send(golden.pong);
    }
}

/// Connects and notes the state at the moment connect() returned.
fn connectAndNote(client: *Client, noted: *nats.State) Client.ConnectError!void {
    try client.connect();
    noted.* = client.state();
}

fn expectSecondConnectWaits(reject: bool) !void {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var release: Io.Event = .unset;
    var server = try io.concurrent(serveWhenReleased, .{ io, &listener, &release, reject });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{
        .servers = &.{try FakeServer.url(&listener, &url)},
        .auth = if (reject) .{ .user_password = .{ .username = "alice", .password = "wrong" } } else .none,
    });
    defer client.deinit();

    var first_noted: nats.State = .disconnected;
    var first = try io.concurrent(connectAndNote, .{ &client, &first_noted });
    defer first.cancel(io) catch {};
    try awaitState(&client, .connecting);
    var second_noted: nats.State = .disconnected;
    var second = try io.concurrent(connectAndNote, .{ &client, &second_noted });
    defer second.cancel(io) catch {};
    // A second connect() that does not wait has returned by now.
    try io.sleep(.fromMilliseconds(20), .awake);
    release.set(io);
    if (reject) {
        try testing.expectError(error.AuthenticationFailed, first.await(io));
        try testing.expectError(error.AuthenticationFailed, second.await(io));
    } else {
        try first.await(io);
        try second.await(io);
        try testing.expectEqual(.connected, first_noted);
        try testing.expectEqual(.connected, second_noted);
    }
    client.close();
    try server.await(io);
}

test "a second connect() while the first is under way gets the first one's outcome" {
    try expectSecondConnectWaits(false);
    try expectSecondConnectWaits(true);
}

test "canceling the task that waits in connect(): Canceled, and the client closes" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var accepted: Io.Event = .unset;
    var server = try io.concurrent(serveMute, .{ io, &listener, &accepted });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{
        .servers = &.{try FakeServer.url(&listener, &url)},
        .connect_timeout = .fromSeconds(30),
    });
    defer client.deinit();

    var connector = try io.concurrent(connectLong, .{&client});
    defer connector.cancel(io) catch {};
    try awaitEvent(io, &accepted);
    const start = Io.Clock.awake.now(io);
    try testing.expectError(error.Canceled, connector.cancel(io));
    try testing.expect(elapsedSince(io, start).toSeconds() < 1);
    try testing.expectEqual(.closed, client.state());
    try server.await(io);
}
