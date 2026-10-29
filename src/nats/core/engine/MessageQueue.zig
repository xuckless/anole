// Adapted from vkiryakov/zefir src/nats/engine/MessageQueue.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! The messages of one subscription that wait for `next()`: as many as its
//! limits allow, by count and by bytes, and its overflow policy decides
//! about more. Once the queue ends, `next()` hands out what it holds and
//! then says how it ended.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Message = @import("../Message.zig");
const Subscription = @import("../Subscription.zig");
const OverflowPolicy = Subscription.OverflowPolicy;
const PendingCounts = Subscription.PendingCounts;
const Stats = Subscription.Stats;
const time = @import("time.zig");
const MessageQueue = @This();

pub const Limits = struct {
    messages: u32,
    /// The bytes of the messages' allocations.
    bytes: usize,
};

/// How a queue ended.
pub const End = enum {
    /// Unsubscribed, or its last message came: `next()` returns null once
    /// the queue is empty.
    finished,
    /// A message did not fit under `close_subscription`.
    slow_consumer,
    /// The server refused the subscription.
    permission_denied,
    /// The responses of a requestMany: the first said that no one
    /// subscribes to the subject.
    no_responders,
    /// The responses of a requestMany: the connection was lost.
    disconnected,
    /// The client closed: `next()` fails at once, and the messages are
    /// gone.
    closed,
};

/// What `next` fails with: the errors of a subscription and those of a
/// requestMany's responses.
pub const NextError = error{
    Timeout,
    Canceled,
    ConcurrentReceive,
    SlowConsumer,
    PermissionDenied,
    NoResponders,
    Disconnected,
    ConnectionClosed,
};

gpa: Allocator,
limits: Limits,
overflow: OverflowPolicy,
/// The queue finishes once this many messages came; null: never.
last: ?u64,
/// Guards everything below.
// SAFETY: NATS engine lock, outside the ranked wrappers until a single-owner
// connection replaces the nesting (research/s15/retrofit-9-rest.md Q1): order
// Outbound.mutex -> {Inbox.mutex, Registry.mutex} -> MessageQueue.mutex, never
// the other way; held across no suspension but an inner lock's wait and its
// own condition's wait.
mutex: Io.Mutex = .init,
/// Signaled when a message comes or the queue ends.
// SAFETY: the condition of the NATS engine lock above (same order and rule).
not_empty: Io.Condition = .init,
/// The messages, oldest first.
messages: std.Deque(Message) = .empty,
/// The bytes of the messages queued.
bytes: usize = 0,
ended: ?End = null,
/// A task waits in `next`.
receiving: bool = false,
/// Messages that came, kept or dropped: the server counts them so for
/// `max_messages`.
received: u64 = 0,
/// Messages `next` handed out.
delivered: u64 = 0,
/// Messages lost: they did not fit, were too large, or found no memory.
dropped: u64 = 0,
/// The last message that came did not fit: a slow consumer, warned about
/// once per run of drops.
overflowing: bool = false,
/// Its subscription drains: the server was told to stop sending, it takes
/// what still comes until it ends, and a new connection does not subscribe
/// it again.
draining: bool = false,
/// `next` handed out a message, and the owner has not asked for the next
/// one since: it may still be working on it.
in_hand: bool = false,
/// The client's drain queued an UNSUB for it.
client_unsub: bool = false,
/// The client closed it after it had finished and everything in it was
/// taken: a drain of it had nothing left to wait for.
drained_when_closed: bool = false,
/// `drain()` calls of its subscription that are inside now: each still
/// uses the subscription, so its `deinit` waits for them. Atomic, outside
/// the mutex: leaving is the very last thing a drain does with it.
drainers: std.atomic.Value(u32) = .init(0),

pub fn init(gpa: Allocator, limits: Limits, overflow: OverflowPolicy, last: ?u64) MessageQueue {
    return .{ .gpa = gpa, .limits = limits, .overflow = overflow, .last = last };
}

/// Frees the queue and every message in it.
pub fn deinit(q: *MessageQueue) void {
    q.freeAll();
    q.messages.deinit(q.gpa);
    q.* = undefined;
}

/// The queue takes messages: it has not ended.
pub fn isOpen(q: *MessageQueue, io: Io) bool {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    return q.ended == null;
}

/// A task waits in `next`; tests use it to know that one does.
pub fn isReceiving(q: *MessageQueue, io: Io) bool {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    return q.receiving;
}

/// How the queue ended; null while it is open.
pub fn endedHow(q: *MessageQueue, io: Io) ?End {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    return q.ended;
}

/// What a new connection needs to know about a subscription: null when it
/// takes no more messages, so it is not subscribed again; otherwise how many
/// messages it still takes before it finishes (null: no end).
pub const Resume = struct { remaining: ?u64 };

pub fn resumeState(q: *MessageQueue, io: Io) ?Resume {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    if (q.ended != null or q.draining) return null;
    return .{ .remaining = if (q.last) |last| last -| q.received else null };
}

/// A `drain()` of the subscription enters; until it calls `leaveDrain`,
/// `awaitNoDrains` waits for it. True when this call begins the drain, the
/// queue being open and not draining yet: it then tells the server to stop
/// sending, and it alone ends the queue.
pub fn enterDrain(q: *MessageQueue, io: Io) bool {
    _ = q.drainers.fetchAdd(1, .acquire);
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    if (q.ended != null or q.draining) return false;
    q.draining = true;
    return true;
}

/// The `drain()` is done with the queue: the last thing it does with it.
pub fn leaveDrain(q: *MessageQueue) void {
    _ = q.drainers.fetchSub(1, .release);
}

/// Waits until no `drain()` of the subscription is inside, with no
/// cancellation point: the subscription is freed after.
pub fn awaitNoDrains(q: *MessageQueue, io: Io) void {
    if (q.drainers.load(.acquire) == 0) return;
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    while (q.drainers.load(.acquire) > 0) io.sleep(.fromMilliseconds(1), .awake) catch {};
}

/// Its SUB may go out: the queue is open and not draining.
pub fn takesSubscribe(q: *MessageQueue, io: Io) bool {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    return q.ended == null and !q.draining;
}

/// The client drains: true when its UNSUB must go out, once for each queue
/// that has not ended, a queue that a `drain()` of its subscription began
/// included, so that the client's PING barrier always follows an UNSUB of
/// every queue it ends.
pub fn drainForClient(q: *MessageQueue, io: Io) bool {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    if (q.ended != null or q.client_unsub) return false;
    q.draining = true;
    q.client_unsub = true;
    return true;
}

/// Waits until the queue has ended and is settled, polling every 5 ms,
/// until `deadline`; ConnectionClosed once the client closed it.
pub fn awaitDrained(q: *MessageQueue, io: Io, deadline: ?Io.Clock.Timestamp) error{ Timeout, Canceled, ConnectionClosed }!void {
    while (true) {
        {
            q.mutex.lockUncancelable(io);
            defer q.mutex.unlock(io);
            if (q.ended == .closed) return if (q.drained_when_closed) {} else error.ConnectionClosed;
            if (q.ended != null and q.isSettled()) return;
        }
        if (deadline) |d| if (time.expired(io, d)) return error.Timeout;
        try io.sleep(.fromMilliseconds(5), .awake);
    }
}

/// A draining queue ends as finished: what it holds still comes out.
pub fn finishDrain(q: *MessageQueue, io: Io) void {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    if (!q.draining or q.ended != null) return;
    q.ended = .finished;
    q.not_empty.broadcast(io);
}

/// Ends the queue `how`, unless it has ended already; `.closed` replaces
/// any other end. With `discard`, the messages it holds are freed; `.closed`
/// always frees them. True when the queue was open: only one caller ends
/// it.
pub fn end(q: *MessageQueue, io: Io, how: End, discard: bool) bool {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    const was_open = q.ended == null;
    if (!was_open and how != .closed) return false;
    if (how == .closed and q.ended == .finished and q.isSettled()) q.drained_when_closed = true;
    q.ended = how;
    if (discard or how == .closed) {
        q.freeAll();
        // Its owner ended it, or the client closed: no message is worked on.
        q.in_hand = false;
    }
    q.not_empty.broadcast(io);
    return was_open;
}

/// Ends the open queue `how`, freeing what it holds with `discard`, and
/// returns null; a queue that has ended already stays as it is, and how it
/// ended comes back. One lock: once the queue ends, a reader waiting in
/// `next()` may free it at once.
pub fn endOpen(q: *MessageQueue, io: Io, how: End, discard: bool) ?End {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    if (q.ended) |earlier| return earlier;
    q.ended = how;
    if (discard) {
        q.freeAll();
        q.in_hand = false;
    }
    q.not_empty.broadcast(io);
    return null;
}

/// Frees what the queue holds, however it ended: its owner is done with
/// it, so it is settled.
pub fn dropAll(q: *MessageQueue, io: Io) void {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    q.freeAll();
    q.in_hand = false;
    q.not_empty.broadcast(io);
}

/// Ends the queue as finished and frees what it holds, whatever ended it
/// before, unless the client closed it: `next()` returns null from now on
/// (ConnectionClosed after a close). For the stream of a requestMany its
/// owner cancels.
pub fn cancel(q: *MessageQueue, io: Io) void {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    if (q.ended != .closed) q.ended = .finished;
    q.freeAll();
    q.in_hand = false;
    q.not_empty.broadcast(io);
}

/// What a push did.
pub const Pushed = struct {
    /// Messages dropped: the one that came, or older ones.
    dropped: u64 = 0,
    /// A message did not fit after the last one did: the subscription
    /// turned into a slow consumer.
    overflow_began: bool = false,
    /// No memory to queue the message.
    no_memory: bool = false,
    /// The queue ended with this message.
    ended: ?End = null,
};

/// Queues a message that came for the subscription, or counts one that
/// came but could not be kept (null: too large, no memory). A message is
/// never larger than `limits.bytes`: the reader drops such a message
/// before it allocates it. A queue that has ended takes nothing and counts
/// nothing.
pub fn push(q: *MessageQueue, io: Io, message: ?Message) Pushed {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    var pushed: Pushed = .{};
    if (q.ended != null) {
        if (message) |m| release(m);
        return pushed;
    }
    q.received += 1;
    if (message) |m| {
        if (q.fits(m)) {
            q.overflowing = false;
            q.append(io, m, &pushed);
        } else {
            pushed.overflow_began = !q.overflowing;
            q.overflowing = true;
            q.handleOverflow(io, m, &pushed);
        }
    } else {
        pushed.dropped = 1;
    }
    q.dropped += pushed.dropped;
    if (q.last) |last| {
        if (q.ended == null and q.received >= last) {
            q.ended = .finished;
            pushed.ended = .finished;
            q.not_empty.broadcast(io);
        }
    }
    return pushed;
}

/// `m` does not fit: the overflow policy decides.
fn handleOverflow(q: *MessageQueue, io: Io, m: Message, pushed: *Pushed) void {
    switch (q.overflow) {
        .drop_newest => {
            release(m);
            pushed.dropped += 1;
        },
        .drop_oldest => {
            while (!q.fits(m)) {
                // An empty queue fits any message within the byte limit.
                const oldest = q.messages.popFront().?;
                q.bytes -= oldest.buffer.len;
                release(oldest);
                pushed.dropped += 1;
            }
            q.append(io, m, pushed);
        },
        .close_subscription => {
            release(m);
            pushed.dropped += 1;
            q.ended = .slow_consumer;
            pushed.ended = .slow_consumer;
            q.not_empty.broadcast(io);
        },
    }
}

/// There is room for `m` within both limits.
fn fits(q: *const MessageQueue, m: Message) bool {
    return q.messages.len < q.limits.messages and m.buffer.len <= q.limits.bytes - q.bytes;
}

fn append(q: *MessageQueue, io: Io, m: Message, pushed: *Pushed) void {
    q.messages.pushBack(q.gpa, m) catch {
        release(m);
        pushed.dropped += 1;
        pushed.no_memory = true;
        return;
    };
    q.bytes += m.buffer.len;
    q.not_empty.signal(io);
}

/// Takes the oldest message, waiting for one until `timeout`. After the
/// queue ends, the messages it holds come out first, then null or the
/// error of its end; `.closed` fails at once.
pub fn next(q: *MessageQueue, io: Io, timeout: Io.Timeout) NextError!?Message {
    const deadline = time.deadline(io, timeout);
    try q.mutex.lock(io);
    defer q.mutex.unlock(io);
    if (q.receiving) return error.ConcurrentReceive;
    q.receiving = true;
    defer q.receiving = false;
    // The owner is done with the message it took before.
    q.in_hand = false;
    while (true) {
        if (q.ended == .closed) return error.ConnectionClosed;
        if (q.messages.popFront()) |m| {
            q.bytes -= m.buffer.len;
            q.delivered += 1;
            q.in_hand = true;
            return m;
        }
        if (q.ended) |how| return switch (how) {
            .finished => null,
            .slow_consumer => error.SlowConsumer,
            .permission_denied => error.PermissionDenied,
            .no_responders => error.NoResponders,
            .disconnected => error.Disconnected,
            .closed => unreachable,
        };
        try q.not_empty.waitTimeout(io, &q.mutex, time.until(deadline));
    }
}

/// Every message was taken, and its owner came back for the next one, or
/// ended the queue: nothing it received is still being worked on. A reader
/// still inside `next()` when the queue has ended is about to get its end,
/// and is waited for.
pub fn settled(q: *MessageQueue, io: Io) bool {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    return q.isSettled();
}

fn isSettled(q: *const MessageQueue) bool {
    return q.messages.len == 0 and !q.in_hand and !(q.receiving and q.ended != null);
}

/// The messages waiting to be taken, and their bytes.
pub fn pending(q: *MessageQueue, io: Io) PendingCounts {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    return .{ .messages = q.messages.len, .bytes = q.bytes };
}

pub fn stats(q: *MessageQueue, io: Io) Stats {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    return .{ .received = q.received, .delivered = q.delivered, .dropped = q.dropped };
}

fn release(message: Message) void {
    var m = message;
    m.deinit();
}

fn freeAll(q: *MessageQueue) void {
    while (q.messages.popFront()) |m| release(m);
    q.bytes = 0;
}

const testing = std.testing;

test "a queue is open until it ends, and closed wins over any other end" {
    const io = testing.io;
    var q: MessageQueue = .init(testing.allocator, .{ .messages = 4, .bytes = 1024 }, .drop_newest, null);
    defer q.deinit();
    try testing.expect(q.isOpen(io));
    _ = q.end(io, .permission_denied, false);
    try testing.expect(!q.isOpen(io));
    _ = q.end(io, .finished, false);
    try testing.expectEqual(.permission_denied, q.endedHow(io).?);
    _ = q.end(io, .closed, false);
    try testing.expectEqual(.closed, q.endedHow(io).?);
}

/// A message of `size` bytes in all: subject "s" and the rest payload.
fn testMessage(size: usize, tag: u8) !Message {
    const buffer = try testing.allocator.alloc(u8, size);
    @memset(buffer, tag);
    buffer[0] = 's';
    return .{
        .subject = buffer[0..1],
        .reply_to = null,
        .headers = .empty,
        .payload = buffer[1..],
        .status = null,
        .description = "",
        .buffer = buffer,
        .gpa = testing.allocator,
    };
}

/// Takes the next message and checks the tag of its payload.
fn expectNext(q: *MessageQueue, tag: u8) !void {
    var m = (try q.next(testing.io, .none)) orelse return error.TestNoMessage;
    defer m.deinit();
    try testing.expectEqual(tag, m.payload[0]);
}

fn pushTagged(q: *MessageQueue, size: usize, tags: []const u8) !void {
    for (tags) |tag| _ = q.push(testing.io, try testMessage(size, tag));
}

test "drop_newest keeps the first messages, by count and by bytes" {
    var by_count: MessageQueue = .init(testing.allocator, .{ .messages = 2, .bytes = 1024 }, .drop_newest, null);
    defer by_count.deinit();
    try pushTagged(&by_count, 10, "abcd");
    try testing.expectEqual(PendingCounts{ .messages = 2, .bytes = 20 }, by_count.pending(testing.io));
    try expectNext(&by_count, 'a');
    try expectNext(&by_count, 'b');
    try testing.expectEqual(Stats{ .received = 4, .delivered = 2, .dropped = 2 }, by_count.stats(testing.io));

    var by_bytes: MessageQueue = .init(testing.allocator, .{ .messages = 100, .bytes = 25 }, .drop_newest, null);
    defer by_bytes.deinit();
    try pushTagged(&by_bytes, 10, "abc");
    try testing.expectEqual(PendingCounts{ .messages = 2, .bytes = 20 }, by_bytes.pending(testing.io));
    try expectNext(&by_bytes, 'a');
    // Room again: the next one fits.
    try pushTagged(&by_bytes, 10, "d");
    try expectNext(&by_bytes, 'b');
    try expectNext(&by_bytes, 'd');
}

test "drop_oldest keeps the last messages, by count and by bytes" {
    var by_count: MessageQueue = .init(testing.allocator, .{ .messages = 2, .bytes = 1024 }, .drop_oldest, null);
    defer by_count.deinit();
    try pushTagged(&by_count, 10, "abcd");
    try expectNext(&by_count, 'c');
    try expectNext(&by_count, 'd');
    try testing.expectEqual(2, by_count.stats(testing.io).dropped);

    // A large message pushes out as many small ones as it needs.
    var by_bytes: MessageQueue = .init(testing.allocator, .{ .messages = 100, .bytes = 30 }, .drop_oldest, null);
    defer by_bytes.deinit();
    try pushTagged(&by_bytes, 10, "abc");
    try pushTagged(&by_bytes, 25, "D");
    try testing.expectEqual(PendingCounts{ .messages = 1, .bytes = 25 }, by_bytes.pending(testing.io));
    try expectNext(&by_bytes, 'D');
    try testing.expectEqual(3, by_bytes.stats(testing.io).dropped);
}

test "close_subscription hands out what came first, then SlowConsumer" {
    var q: MessageQueue = .init(testing.allocator, .{ .messages = 2, .bytes = 1024 }, .close_subscription, null);
    defer q.deinit();
    _ = q.push(testing.io, try testMessage(10, 'a'));
    _ = q.push(testing.io, try testMessage(10, 'b'));
    const pushed = q.push(testing.io, try testMessage(10, 'c'));
    try testing.expectEqual(.slow_consumer, pushed.ended.?);
    try testing.expect(pushed.overflow_began);
    // Ended: later messages are neither kept nor counted.
    const late = q.push(testing.io, try testMessage(10, 'd'));
    try testing.expectEqual(0, late.dropped);
    try expectNext(&q, 'a');
    try expectNext(&q, 'b');
    try testing.expectError(error.SlowConsumer, q.next(testing.io, .none));
    try testing.expectError(error.SlowConsumer, q.next(testing.io, .none));
    try testing.expectEqual(Stats{ .received = 3, .delivered = 2, .dropped = 1 }, q.stats(testing.io));
}

test "a run of drops begins once, and ends when a message fits again" {
    var q: MessageQueue = .init(testing.allocator, .{ .messages = 1, .bytes = 1024 }, .drop_newest, null);
    defer q.deinit();
    try testing.expect(!q.push(testing.io, try testMessage(10, 'a')).overflow_began);
    try testing.expect(q.push(testing.io, try testMessage(10, 'b')).overflow_began);
    try testing.expect(!q.push(testing.io, try testMessage(10, 'c')).overflow_began);
    try expectNext(&q, 'a');
    try testing.expect(!q.push(testing.io, try testMessage(10, 'd')).overflow_began);
    try testing.expect(q.push(testing.io, try testMessage(10, 'e')).overflow_began);
    try expectNext(&q, 'd');
}

test "how next ends: null, PermissionDenied after what came, ConnectionClosed at once" {
    var finished: MessageQueue = .init(testing.allocator, .{ .messages = 4, .bytes = 1024 }, .drop_newest, null);
    defer finished.deinit();
    try pushTagged(&finished, 10, "a");
    _ = finished.end(testing.io, .finished, false);
    try expectNext(&finished, 'a');
    try testing.expect(try finished.next(testing.io, .none) == null);

    var denied: MessageQueue = .init(testing.allocator, .{ .messages = 4, .bytes = 1024 }, .drop_newest, null);
    defer denied.deinit();
    try pushTagged(&denied, 10, "a");
    _ = denied.end(testing.io, .permission_denied, false);
    try expectNext(&denied, 'a');
    try testing.expectError(error.PermissionDenied, denied.next(testing.io, .none));

    var closed: MessageQueue = .init(testing.allocator, .{ .messages = 4, .bytes = 1024 }, .drop_newest, null);
    defer closed.deinit();
    try pushTagged(&closed, 10, "ab");
    _ = closed.end(testing.io, .closed, false);
    try testing.expectError(error.ConnectionClosed, closed.next(testing.io, .none));
    try testing.expectEqual(PendingCounts{ .messages = 0, .bytes = 0 }, closed.pending(testing.io));
}

test "the ends of a requestMany: NoResponders, and Disconnected after what came" {
    var nobody: MessageQueue = .init(testing.allocator, .{ .messages = 4, .bytes = 1024 }, .drop_newest, 4);
    defer nobody.deinit();
    _ = nobody.end(testing.io, .no_responders, false);
    try testing.expectError(error.NoResponders, nobody.next(testing.io, .none));
    try testing.expectError(error.NoResponders, nobody.next(testing.io, .none));

    var lost: MessageQueue = .init(testing.allocator, .{ .messages = 4, .bytes = 1024 }, .drop_newest, 4);
    defer lost.deinit();
    try pushTagged(&lost, 10, "a");
    _ = lost.end(testing.io, .disconnected, false);
    try expectNext(&lost, 'a');
    try testing.expectError(error.Disconnected, lost.next(testing.io, .none));
    // The client closes after: the error changes, as for any end.
    _ = lost.end(testing.io, .closed, true);
    try testing.expectError(error.ConnectionClosed, lost.next(testing.io, .none));
}

test "cancel ends any end but closed with null, and frees what waits" {
    var lost: MessageQueue = .init(testing.allocator, .{ .messages = 4, .bytes = 1024 }, .drop_newest, 4);
    defer lost.deinit();
    try pushTagged(&lost, 10, "ab");
    _ = lost.end(testing.io, .disconnected, false);
    lost.cancel(testing.io);
    try testing.expectEqual(PendingCounts{ .messages = 0, .bytes = 0 }, lost.pending(testing.io));
    try testing.expect(try lost.next(testing.io, .none) == null);
    // Later messages are not taken.
    _ = lost.push(testing.io, try testMessage(10, 'c'));
    try testing.expect(try lost.next(testing.io, .none) == null);

    var closed: MessageQueue = .init(testing.allocator, .{ .messages = 4, .bytes = 1024 }, .drop_newest, 4);
    defer closed.deinit();
    _ = closed.end(testing.io, .closed, true);
    closed.cancel(testing.io);
    try testing.expectError(error.ConnectionClosed, closed.next(testing.io, .none));
}

test "max_messages: the queue finishes with its last message" {
    var q: MessageQueue = .init(testing.allocator, .{ .messages = 4, .bytes = 1024 }, .drop_newest, 2);
    defer q.deinit();
    _ = q.push(testing.io, try testMessage(10, 'a'));
    const last = q.push(testing.io, null);
    try testing.expectEqual(.finished, last.ended.?);
    try expectNext(&q, 'a');
    try testing.expect(try q.next(testing.io, .none) == null);
    try testing.expectEqual(Stats{ .received = 2, .delivered = 1, .dropped = 1 }, q.stats(testing.io));
}

fn receive(q: *MessageQueue) NextError!?Message {
    return q.next(testing.io, .none);
}

/// Waits until a task waits in `next`, for 5 s at most.
fn awaitReceiver(q: *MessageQueue) !void {
    const io = testing.io;
    const give_up = time.after(io, .fromSeconds(5 * @as(i64, @import("anole_test_wait").timeoutFactor())));
    while (!q.isReceiving(io)) {
        if (time.expired(io, give_up)) return error.TestReceiverNeverWaited;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "one task at a time waits; a timeout, a cancel and an end wake it" {
    const io = testing.io;
    var q: MessageQueue = .init(testing.allocator, .{ .messages = 4, .bytes = 1024 }, .drop_newest, null);
    defer q.deinit();
    try testing.expectError(error.Timeout, q.next(io, .{ .duration = .{ .raw = .fromMilliseconds(10), .clock = .awake } }));

    var receiver = try io.concurrent(receive, .{&q});
    defer if (receiver.cancel(io)) |m| {
        if (m) |message| release(message);
    } else |_| {};
    try awaitReceiver(&q);
    try testing.expectError(error.ConcurrentReceive, q.next(io, .none));
    try testing.expectError(error.Canceled, receiver.cancel(io));

    var waiting = try io.concurrent(receive, .{&q});
    defer if (waiting.cancel(io)) |m| {
        if (m) |message| release(message);
    } else |_| {};
    try awaitReceiver(&q);
    _ = q.end(io, .closed, true);
    try testing.expectError(error.ConnectionClosed, waiting.await(io));
}

test "a queue is settled once its messages were taken and its owner came back for more" {
    const io = testing.io;
    var q: MessageQueue = .init(testing.allocator, .{ .messages = 4, .bytes = 1024 }, .drop_newest, null);
    defer q.deinit();
    try testing.expect(q.settled(io));
    _ = q.push(io, try testMessage(8, 'a'));
    try testing.expect(!q.settled(io));
    var m = (try q.next(io, .none)).?;
    m.deinit();
    // Taken, but its owner may still be working on it.
    try testing.expect(!q.settled(io));
    try testing.expectError(error.Timeout, q.next(io, .{ .duration = .{ .raw = .fromMilliseconds(1), .clock = .awake } }));
    try testing.expect(q.settled(io));

    _ = q.push(io, try testMessage(8, 'b'));
    var n = (try q.next(io, .none)).?;
    n.deinit();
    // Its owner ends it: done with what it took.
    _ = q.end(io, .finished, true);
    try testing.expect(q.settled(io));
}

fn nextLong(q: *MessageQueue, io: Io) NextError!?Message {
    return q.next(io, .none);
}

test "a reader still inside next() when the queue ends is waited for" {
    const io = testing.io;
    var q: MessageQueue = .init(testing.allocator, .{ .messages = 4, .bytes = 1024 }, .drop_newest, null);
    defer q.deinit();
    var reader = try io.concurrent(nextLong, .{ &q, io });
    defer _ = reader.cancel(io) catch null;
    const give_up = time.after(io, .fromSeconds(5 * @as(i64, @import("anole_test_wait").timeoutFactor())));
    while (!q.isReceiving(io)) {
        if (time.expired(io, give_up)) return error.TestNeverWaited;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    // Waiting for a message: nothing is worked on.
    try testing.expect(q.settled(io));
    // Ended under the reader, which has not returned yet.
    q.mutex.lockUncancelable(io);
    q.ended = .finished;
    q.mutex.unlock(io);
    try testing.expect(!q.settled(io));
    q.mutex.lockUncancelable(io);
    q.not_empty.broadcast(io);
    q.mutex.unlock(io);
    try testing.expect(try reader.await(io) == null);
    try testing.expect(q.settled(io));
}

fn waitForDrains(q: *MessageQueue, io: Io, done: *std.atomic.Value(bool)) void {
    q.awaitNoDrains(io);
    done.store(true, .release);
}

test "drains: the first begins it, the client's drain adds its UNSUB once, and the queue's owner waits for every drain to leave" {
    const io = testing.io;
    var q: MessageQueue = .init(testing.allocator, .{ .messages = 4, .bytes = 1024 }, .drop_newest, null);
    defer q.deinit();
    try testing.expect(q.enterDrain(io));
    try testing.expect(!q.enterDrain(io));
    // The client's drain queues its own UNSUB of a queue a drain began.
    try testing.expect(q.drainForClient(io));
    try testing.expect(!q.drainForClient(io));

    var done: std.atomic.Value(bool) = .init(false);
    var waiter = try io.concurrent(waitForDrains, .{ &q, io, &done });
    defer waiter.cancel(io);
    q.leaveDrain();
    // A window for a wrong wake to show (a slow machine only hides one).
    const wait = @import("anole_test_wait");
    try wait.expectStays(io, "awaitNoDrains still waiting after one of two drains left", &done, struct {
        fn waiting(d: *std.atomic.Value(bool)) bool {
            return !d.load(.acquire);
        }
    }.waiting, wait.short_window);
    q.leaveDrain();
    waiter.await(io);
    try testing.expect(done.load(.acquire));

    // Ended: a drain begins nothing, nor does the client's.
    try testing.expectEqual(@as(?End, null), q.endOpen(io, .finished, true));
    try testing.expectEqual(End.finished, q.endOpen(io, .finished, true).?);
    try testing.expect(!q.enterDrain(io));
    q.leaveDrain();
}

test "awaitDrained waits for the end and for the reader, and gives up at its deadline" {
    const io = testing.io;
    var q: MessageQueue = .init(testing.allocator, .{ .messages = 4, .bytes = 1024 }, .drop_newest, null);
    defer q.deinit();
    _ = q.push(io, try testMessage(8, 'a'));
    // Not ended yet.
    try testing.expectError(error.Timeout, q.awaitDrained(io, time.after(io, .fromMilliseconds(10))));
    try testing.expect(q.enterDrain(io));
    q.finishDrain(io);
    q.leaveDrain();
    // Ended, but its message waits.
    try testing.expectError(error.Timeout, q.awaitDrained(io, time.after(io, .fromMilliseconds(10))));
    // Its owner is done with it.
    q.dropAll(io);
    try q.awaitDrained(io, time.after(io, .fromSeconds(5)));
}

test "a drain that sees the client closed after its queue ended and was read reports success" {
    const io = testing.io;
    var drained: MessageQueue = .init(testing.allocator, .{ .messages = 4, .bytes = 1024 }, .drop_newest, null);
    defer drained.deinit();
    _ = drained.push(io, try testMessage(8, 'a'));
    try testing.expect(drained.drainForClient(io));
    drained.finishDrain(io);
    var m = (try drained.next(io, .none)).?;
    m.deinit();
    try testing.expect(try drained.next(io, .none) == null);
    // The client's drain is done and closes before this drain looks.
    _ = drained.end(io, .closed, true);
    try drained.awaitDrained(io, null);

    // Closed with a message nobody took: that drain did not finish.
    var cut: MessageQueue = .init(testing.allocator, .{ .messages = 4, .bytes = 1024 }, .drop_newest, null);
    defer cut.deinit();
    _ = cut.push(io, try testMessage(8, 'b'));
    try testing.expect(cut.drainForClient(io));
    cut.finishDrain(io);
    _ = cut.end(io, .closed, true);
    try testing.expectError(error.ConnectionClosed, cut.awaitDrained(io, null));
}
