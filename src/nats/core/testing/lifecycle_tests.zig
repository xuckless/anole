// Adapted from vkiryakov/zefir src/nats/testing/lifecycle_tests.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! The methods of a zefir.App bean, `start`, `wait` and `shutdown`, against
//! fake servers on loopback. Each test starts its own server function in a
//! task and cancels it on the way out; every wait of a test ends within
//! 5 s, so a mistake fails the test instead of hanging it.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const testing = std.testing;
const test_wait = @import("anole_test_wait");
const nats = @import("../root.zig");
const Client = nats.Client;
const FakeServer = @import("FakeServer.zig");
const probe = @import("probe.zig");
const golden = @import("../protocol/golden.zig");
const time = @import("../engine/time.zig");

/// The server's side of the handshake.
fn handshake(peer: *FakeServer.Peer) !void {
    try peer.send(golden.info_default);
    const connect_line = try peer.readLine();
    if (!std.mem.startsWith(u8, connect_line, "CONNECT {")) return error.TestNotConnect;
    try peer.expectLine("PING");
    try peer.send(golden.pong);
}

/// A handshake, then a PONG for every PING until the client hangs up.
fn serveNormally(io: Io, listener: *net.Server) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try handshake(&peer);
    while (try peer.nextLine()) |line| {
        if (std.mem.eql(u8, line, "PING")) try peer.send(golden.pong);
    }
}

/// A handshake, then nothing answered: the PING of a drain waits forever.
fn serveSilently(io: Io, listener: *net.Server) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try handshake(&peer);
    while (try peer.nextLine()) |_| {}
}

/// A handshake, then a hang-up at once; later connections are taken and
/// closed before INFO, `refusals` of them: failed attempts.
fn serveThenGo(io: Io, listener: *net.Server, refusals: u32) !void {
    {
        var peer: FakeServer.Peer = undefined;
        try peer.accept(io, listener);
        defer peer.close();
        try handshake(&peer);
    }
    for (0..refusals) |_| {
        var peer: FakeServer.Peer = undefined;
        try peer.accept(io, listener);
        peer.close();
    }
}

/// A handshake; the PING of the drain goes unanswered, and 100 ms after it
/// the server hangs up.
fn serveThenDropAtDrain(io: Io, listener: *net.Server) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try handshake(&peer);
    while (try peer.nextLine()) |line| {
        if (std.mem.eql(u8, line, "PING")) break;
    }
    try io.sleep(.fromMilliseconds(100), .awake);
}

/// The deadline `ms` milliseconds from now, as zefir.App passes it.
fn inMs(io: Io, ms: i64) Io.Clock.Timestamp {
    return .fromNow(io, .{ .raw = .fromMilliseconds(ms), .clock = .awake });
}

/// Milliseconds from `deadline` to now; negative before it.
fn msPast(io: Io, deadline: Io.Clock.Timestamp) i64 {
    return deadline.durationTo(Io.Clock.Timestamp.now(io, .awake)).raw.toMilliseconds();
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

/// `client.wait` in a task of its own.
const Waiter = struct {
    client: *Client,
    result: Client.WaitError!void = {},
    done: Io.Event = .unset,
    task: ?Io.Future(void) = null,

    fn run(w: *Waiter) void {
        w.result = w.client.wait(w.client.io);
        w.done.set(w.client.io);
    }

    fn begin(w: *Waiter) !void {
        w.task = try w.client.io.concurrent(run, .{w});
    }

    /// What `wait` returned, within 5 s.
    fn end(w: *Waiter) !Client.WaitError!void {
        const io = w.client.io;
        const give_up = time.after(io, .fromSeconds(5 * @as(i64, test_wait.timeoutFactor())));
        while (!w.done.isSet()) {
            w.done.waitTimeout(io, .{ .deadline = give_up }) catch |err| switch (err) {
                // A spurious wake-up is a Timeout too.
                error.Timeout => if (time.expired(io, give_up)) return error.TestWaitNeverReturned,
                error.Canceled => return err,
            };
        }
        w.task.?.await(io);
        w.task = null;
        return w.result;
    }

    fn deinit(w: *Waiter) void {
        if (w.task) |*task| task.cancel(w.client.io);
    }
};

fn quiet() std.log.Level {
    const level = testing.log_level;
    testing.log_level = .err;
    return level;
}

test "start connects, shutdown drains, wait returns {}" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(serveNormally, .{ io, &listener });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();

    try client.start(io);
    try testing.expectEqual(.connected, client.state());
    var waiter: Waiter = .{ .client = &client };
    defer waiter.deinit();
    try waiter.begin();

    try client.shutdown(io, inMs(io, 5000));
    try testing.expectEqual(.closed, client.state());
    try testing.expectEqual(.drained, client.close_reason.?);
    try (try waiter.end());
    try server.await(io);
}

test "a drain that cannot finish: shutdown returns Timeout and the client is closed" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(serveSilently, .{ io, &listener });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.start(io);

    const deadline = inMs(io, 600);
    try testing.expectError(error.Timeout, client.shutdown(io, deadline));
    // Not before deadline − r (r = 250 ms): the drain gives up at its own
    // deadline, never early; a slow machine only makes it later.
    try testing.expect(msPast(io, deadline) >= -250 - 1);
    // By deadline − r; the close after the drain may take a while on a
    // busy runner. An elapsed-time bound (D6): local timing runs only.
    if (test_wait.timing()) try testing.expect(msPast(io, deadline) <= -250 + 200);
    try testing.expectEqual(.closed, client.state());
    try testing.expectEqual(.drain_failed, client.close_reason.?);
    // A drain that ran out of time is no failure of the client.
    var waiter: Waiter = .{ .client = &client };
    defer waiter.deinit();
    try waiter.begin();
    try (try waiter.end());
}

test "wait returns ConnectionLost when the server goes and reconnect is off" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(serveThenGo, .{ io, &listener, 0 });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)}, .reconnect = .{ .enabled = false } });
    defer client.deinit();
    var waiter: Waiter = .{ .client = &client };
    defer waiter.deinit();
    try client.start(io);
    try waiter.begin();

    // The manager closes the client itself, without close().
    try testing.expectError(error.ConnectionLost, try waiter.end());
    try testing.expectEqual(.closed, client.state());
    try testing.expectEqual(.connection_lost, client.close_reason.?);
}

/// For every client: a handshake, then a hang-up at once; until canceled.
fn serveThenGoForever(io: Io, listener: *net.Server) !void {
    while (true) {
        var peer: FakeServer.Peer = undefined;
        try peer.accept(io, listener);
        defer peer.close();
        handshake(&peer) catch |err| if (peer.canceled(err)) return error.Canceled else continue;
    }
}

test "connect() returns {} when the first connection is made and lost before it looks (reconnect off) [stress]" {
    // Regression test of e30d337: the server hangs up right after the
    // handshake, and the manager may close the client (reconnect off)
    // before connect() looks at the state; connect() then returned
    // ConnectionClosed though the connection was made. A race, so a loop.
    try test_wait.requireStress();
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(serveThenGoForever, .{ io, &listener });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    const servers: []const []const u8 = &.{try FakeServer.url(&listener, &url)};
    for (0..500) |_| {
        var client: Client = try .init(testing.allocator, io, .{ .servers = servers, .reconnect = .{ .enabled = false } });
        defer client.deinit();
        try client.start(io);
    }
}

test "wait returns ReconnectFailed after max_attempts" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(serveThenGo, .{ io, &listener, 2 });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{
        .servers = &.{try FakeServer.url(&listener, &url)},
        .reconnect = .{ .min_delay = .fromMilliseconds(1), .max_delay = .fromMilliseconds(5), .max_attempts = 2 },
    });
    defer client.deinit();
    var waiter: Waiter = .{ .client = &client };
    defer waiter.deinit();
    try client.start(io);
    try waiter.begin();

    try testing.expectError(error.ReconnectFailed, try waiter.end());
    try testing.expectEqual(.reconnect_failed, client.close_reason.?);
}

test "a shutdown while the client reconnects closes it and returns {}" {
    const io = testing.io;
    const level = quiet();
    defer testing.log_level = level;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    // Later attempts get no answer: the client keeps reconnecting.
    var server = try io.concurrent(serveThenGo, .{ io, &listener, 0 });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{
        .servers = &.{try FakeServer.url(&listener, &url)},
        .reconnect = .{ .min_delay = .fromSeconds(1), .max_delay = .fromSeconds(1) },
    });
    defer client.deinit();
    var waiter: Waiter = .{ .client = &client };
    defer waiter.deinit();
    try client.start(io);
    try waiter.begin();
    try awaitState(&client, .reconnecting);

    const deadline = inMs(io, 5000);
    try client.shutdown(io, deadline);
    // At once, not at the deadline: an elapsed-time bound (D6).
    if (test_wait.timing()) try testing.expect(msPast(io, deadline) < -4000);
    try testing.expectEqual(.closed, client.state());
    try testing.expectEqual(.closed, client.close_reason.?);
    try (try waiter.end());
}

test "a shutdown that loses the connection during the drain returns {}" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(serveThenDropAtDrain, .{ io, &listener });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.start(io);

    const deadline = inMs(io, 1000);
    try client.shutdown(io, deadline);
    // Before deadline − r: an elapsed-time bound (D6).
    if (test_wait.timing()) try testing.expect(msPast(io, deadline) <= -250);
    try testing.expectEqual(.closed, client.state());
    try testing.expectEqual(.connection_lost, client.close_reason.?);
}

test "canceling wait leaves the client running" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(serveNormally, .{ io, &listener });
    defer server.cancel(io) catch {};
    var url: [64]u8 = undefined;
    var client: Client = try .init(testing.allocator, io, .{ .servers = &.{try FakeServer.url(&listener, &url)} });
    defer client.deinit();
    try client.start(io);

    var task = try io.concurrent(Client.wait, .{ &client, io });
    // Canceled and awaited on every way out (SAFETY.md T1).
    var task_done = false;
    defer if (!task_done) task.cancel(io) catch {};
    // Once the task waits, its cancelation ends the wait.
    try test_wait.waitUntil(io, "the wait() task waits for a change", &client, probe.stateWaitersAtLeastOne);
    task_done = true;
    try testing.expectError(error.Canceled, task.cancel(io));
    try testing.expectEqual(.connected, client.state());
    try client.flush(.{ .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } } });
    try client.shutdown(io, inMs(io, 5000));
    try server.await(io);
}
