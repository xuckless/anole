// Adapted from vkiryakov/zefir src/nats/events.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! What happens to a client between its calls: the connection is lost and
//! comes back, servers come and go, a server refuses something, messages
//! are lost. Read the events with `client.nextEvent(.{})`, one task at a
//! time:
//!
//! ```zig
//! while (try client.nextEvent(.{})) |event| switch (event) {
//!     .disconnected => |lost| log.warn("lost {f}: {t}", .{ lost.server, lost.reason }),
//!     .reconnected => |server| log.info("back on {f}", .{server}),
//!     .closed => |reason| log.info("closed: {t}", .{reason}),
//!     else => {},
//! };
//! ```
//!
//! The client keeps `limits.max_event_queue` events; while that many wait,
//! newer ones are dropped and counted in `stats().dropped_events`, except
//! `closed`, which always comes last. After it `nextEvent` returns null. An
//! event holds no memory of the client: a text in it is cut to fit its own
//! buffer.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ServerAddress = @import("ServerAddress.zig");
const CloseReason = @import("Client.zig").CloseReason;
const time = @import("engine/time.zig");

pub const Event = union(enum) {
    /// The first connection is up.
    connected: ServerAddress,
    /// The connection is lost. The client reconnects, unless `closed`
    /// follows.
    disconnected: Disconnected,
    /// An attempt to connect again begins.
    reconnecting: Reconnecting,
    /// Connected again; the subscriptions are subscribed again.
    reconnected: ServerAddress,
    /// The cluster announced a server, which joins the pool.
    server_discovered: ServerAddress,
    /// The cluster no longer announces a server it did, which leaves the
    /// pool.
    server_removed: ServerAddress,
    /// The server is about to go away: the client moves to another one
    /// when it can.
    lame_duck: ServerAddress,
    /// A subscription could not keep up and dropped messages: once per run
    /// of drops; its SID.
    slow_consumer: u64,
    /// A server refused the credentials.
    auth_error: ServerAddress,
    /// The server broke the protocol, or says this client did.
    protocol_error: ServerAddress,
    /// Messages were lost.
    message_dropped: MessageDropped,
    /// The server refused a subject.
    permission_denied: PermissionDenied,
    /// The server reported an error and keeps the connection.
    server_error: Text,
    /// The client closed: the last event.
    closed: CloseReason,

    pub const Disconnected = struct {
        server: ServerAddress,
        reason: Reason,

        pub const Reason = enum {
            /// The server closed the connection.
            closed_by_server,
            /// The server left PINGs unanswered.
            stale,
            /// The server sent an error after which it closes the connection.
            server_error,
            /// The server broke the protocol.
            protocol_error,
            /// Reading or writing failed.
            io_error,
            /// The server is about to go away, and the client left it.
            lame_duck,
        };
    };

    pub const Reconnecting = struct {
        server: ServerAddress,
        /// 1 for the first attempt since the connection was lost.
        attempt: u32,
    };

    pub const MessageDropped = struct {
        reason: Reason,
        /// How many messages.
        count: u64,
        /// The subscription that lost them; null for publishes and for
        /// replies to requests.
        sid: ?u64 = null,

        pub const Reason = enum {
            /// Publishes never written: no room in the reconnect buffer, or the
            /// client closed.
            unsent,
            /// An incoming message over `max_inbound_frame_bytes`,
            /// `max_header_bytes` or what its subscription holds.
            too_large,
            /// No memory for an incoming message.
            no_memory,
        };
    };

    pub const PermissionDenied = struct {
        operation: Operation,
        /// The subject as the server wrote it: quotes, backslashes and bytes
        /// that do not print are escaped the way Go's %q does.
        subject: Text,
        /// The subscription the server named, when it named one.
        sid: ?u64 = null,

        pub const Operation = enum { publish, subscribe, reply };
    };

    /// A text of up to `capacity` bytes, cut when longer. The texts of
    /// `server_error` and `permission_denied` are the server's bytes as it
    /// sent them: escape them before you print them.
    pub const Text = struct {
        buffer: [capacity]u8 = undefined,
        len: u8 = 0,
        /// The text was longer.
        cut: bool = false,

        pub const capacity = 128;

        /// A copy of `text`, cut to `capacity` bytes.
        pub fn init(text: []const u8) Text {
            var t: Text = .{ .cut = text.len > capacity };
            const n = @min(text.len, capacity);
            @memcpy(t.buffer[0..n], text[0..n]);
            t.len = @intCast(n);
            return t;
        }

        /// The text kept.
        pub fn slice(t: *const Text) []const u8 {
            return t.buffer[0..t.len];
        }
    };
};

/// The events waiting for `nextEvent`, oldest first.
pub const Queue = struct {
    gpa: Allocator,
    /// Events kept at most, `closed` aside.
    limit: u32,
    mutex: Io.Mutex = .init,
    /// One task waits on it at most.
    ready: Io.Condition = .init,
    events: std.Deque(Event) = .empty,
    /// A task waits in `next`.
    receiving: bool = false,
    /// Why the client closed, once it did: the last event, kept apart from
    /// `events` so that no full queue and no lack of memory loses it.
    closed: ?CloseReason = null,
    /// `next` handed out `closed`.
    closed_taken: bool = false,
    /// Events dropped: the queue was full, or there was no memory.
    dropped: u64 = 0,

    pub fn init(gpa: Allocator, limit: u32) Queue {
        return .{ .gpa = gpa, .limit = limit };
    }

    pub fn deinit(q: *Queue) void {
        q.events.deinit(q.gpa);
        q.* = undefined;
    }

    /// Queues `event` without waiting: dropped and counted while the queue
    /// is full, but `closed`, which ends the queue. Nothing comes after
    /// `closed`.
    pub fn push(q: *Queue, io: Io, event: Event) void {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        if (q.closed != null) return;
        switch (event) {
            .closed => |reason| q.closed = reason,
            else => if (q.events.len >= q.limit) {
                q.dropped += 1;
            } else {
                q.events.pushBack(q.gpa, event) catch {
                    q.dropped += 1;
                };
            },
        }
        q.ready.signal(io);
    }

    pub const NextError = error{
        /// No event came in time.
        Timeout,
        /// The task was canceled through `std.Io`.
        Canceled,
        /// Another task waits for the next event already.
        ConcurrentReceive,
    };

    /// The oldest event, waiting for one until `timeout`; null once
    /// `closed` was taken.
    pub fn next(q: *Queue, io: Io, timeout: Io.Timeout) NextError!?Event {
        const deadline = time.deadline(io, timeout);
        try q.mutex.lock(io);
        defer q.mutex.unlock(io);
        if (q.receiving) return error.ConcurrentReceive;
        q.receiving = true;
        defer q.receiving = false;
        while (true) {
            if (q.events.popFront()) |event| return event;
            if (q.closed) |reason| {
                if (q.closed_taken) return null;
                q.closed_taken = true;
                return .{ .closed = reason };
            }
            try q.ready.waitTimeout(io, &q.mutex, time.until(deadline));
        }
    }

    /// Events dropped so far.
    pub fn droppedCount(q: *Queue, io: Io) u64 {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        return q.dropped;
    }

    /// A task waits in `next`; tests use it.
    pub fn isReceiving(q: *Queue, io: Io) bool {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        return q.receiving;
    }
};

const testing = std.testing;

fn server(text: []const u8) ServerAddress {
    return ServerAddress.parse(text) catch unreachable;
}

test "events come out in order, and null after closed" {
    const io = testing.io;
    var q: Queue = .init(testing.allocator, 8);
    defer q.deinit();
    q.push(io, .{ .connected = server("a:1") });
    q.push(io, .{ .slow_consumer = 7 });
    q.push(io, .{ .closed = .closed });
    q.push(io, .{ .slow_consumer = 8 });
    try testing.expectEqual(1, (try q.next(io, .none)).?.connected.port);
    try testing.expectEqual(7, (try q.next(io, .none)).?.slow_consumer);
    try testing.expectEqual(CloseReason.closed, (try q.next(io, .none)).?.closed);
    try testing.expect(try q.next(io, .none) == null);
    try testing.expect(try q.next(io, .none) == null);
}

test "a full queue drops and counts new events, but closed always comes" {
    const io = testing.io;
    var q: Queue = .init(testing.allocator, 2);
    defer q.deinit();
    for (0..5) |i| q.push(io, .{ .slow_consumer = i });
    q.push(io, .{ .closed = .auth_failed });
    try testing.expectEqual(3, q.droppedCount(io));
    try testing.expectEqual(0, (try q.next(io, .none)).?.slow_consumer);
    try testing.expectEqual(1, (try q.next(io, .none)).?.slow_consumer);
    try testing.expectEqual(CloseReason.auth_failed, (try q.next(io, .none)).?.closed);
    try testing.expect(try q.next(io, .none) == null);
}

fn nextLong(q: *Queue, io: Io) Queue.NextError!?Event {
    return q.next(io, .none);
}

test "one task waits at a time, and closed wakes it" {
    const io = testing.io;
    var q: Queue = .init(testing.allocator, 8);
    defer q.deinit();
    var waiter = try io.concurrent(nextLong, .{ &q, io });
    defer _ = waiter.cancel(io) catch {};
    const give_up = time.after(io, .fromSeconds(5 * @as(i64, @import("anole_test_wait").timeoutFactor())));
    while (!q.isReceiving(io)) {
        if (time.expired(io, give_up)) return error.TestNeverWaited;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.expectError(error.ConcurrentReceive, q.next(io, .none));
    q.push(io, .{ .closed = .closed });
    try testing.expectEqual(CloseReason.closed, (try waiter.await(io)).?.closed);

    var empty: Queue = .init(testing.allocator, 1);
    defer empty.deinit();
    try testing.expectError(error.Timeout, empty.next(io, .{ .duration = .{ .raw = .fromMilliseconds(5), .clock = .awake } }));
}

test "a text longer than its buffer is cut" {
    const short: Event.Text = .init("forbidden");
    try testing.expectEqualStrings("forbidden", short.slice());
    try testing.expect(!short.cut);
    const long: [300]u8 = @splat('x');
    const cut: Event.Text = .init(&long);
    try testing.expectEqual(Event.Text.capacity, cut.slice().len);
    try testing.expect(cut.cut);
}

fn failingAllocator() std.mem.Allocator {
    return testing.failing_allocator;
}

test "closed comes even when there is no memory for any event" {
    const io = testing.io;
    var q: Queue = .init(failingAllocator(), 8);
    defer q.deinit();
    q.push(io, .{ .slow_consumer = 1 });
    q.push(io, .{ .closed = .reconnect_failed });
    try testing.expectEqual(1, q.droppedCount(io));
    try testing.expectEqual(CloseReason.reconnect_failed, (try q.next(io, .none)).?.closed);
    try testing.expect(try q.next(io, .none) == null);
}
