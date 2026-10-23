// Adapted from vkiryakov/zefir src/nats/Subscription.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! A subscription: the messages published to its subject reach it in
//! order. The client owns it; `deinit()` ends it and frees it, and comes
//! before the client's own `deinit()`.
//!
//! ```zig
//! const sub = try client.subscribe("orders.*", .{ .queue = "workers" });
//! defer sub.deinit();
//! while (true) {
//!     var msg = (try sub.next(.{})) orelse break;
//!     defer msg.deinit();
//!     handle(msg.subject, msg.payload);
//! }
//! ```
//!
//! One task at a time waits in `next()`; any task may `unsubscribe()` or
//! `drain()`. Read with `next()` until it returns null, or `deinit()` the
//! subscription: a message counts as handled once its reader asks for the
//! next one, and a drain waits for that. The reader may `deinit()` it as
//! soon as `next()` returns null, as above, even while another task's
//! `drain()` returns: `deinit()` waits for that.

const std = @import("std");
const Io = std.Io;
const Client = @import("Client.zig");
const Message = @import("Message.zig");
const MessageQueue = @import("engine/MessageQueue.zig");
const Registry = @import("engine/Registry.zig");
const time = @import("engine/time.zig");
const log = std.log.scoped(.nats);
const Subscription = @This();

client: *Client,
/// Its id on the connection, from 1 up; the client never reuses one.
sid: u64,
/// The subject subscribed to, wildcards included.
subject: []const u8,
/// The queue group it joined, if any.
queue_group: ?[]const u8,
/// The messages that wait to be taken. Internal: the client's reader fills
/// it; take messages with `next()`, look at it with `pending()` and
/// `stats()`. Tests may ask it `isReceiving()`.
messages: MessageQueue,

pub const Options = struct {
    /// Join this queue group: the server gives each message to one member
    /// of the group.
    queue: ?[]const u8 = null,
    /// End the subscription after this many messages, at most 999 999 999;
    /// the server stops sending then.
    max_messages: ?u64 = null,
    /// How much may wait to be taken; more goes by `overflow`.
    pending: Pending = .{},
    overflow: OverflowPolicy = .drop_newest,
    /// How long `subscribe` waits for room in the outbound queue for its
    /// SUB, as when the server stops reading; by default, as long as it
    /// takes. When it runs out, `subscribe` fails with Timeout and nothing
    /// is subscribed, as when it is over before `subscribe` begins.
    timeout: Io.Timeout = .none,

    pub const Pending = struct {
        /// Null: `limits.subscription_messages` of the client's options.
        messages: ?u32 = null,
        /// The bytes of the messages, subject and headers included; null:
        /// `limits.subscription_bytes` of the client's options. A message
        /// larger than this on its own is dropped as it comes, whatever
        /// `overflow` says.
        bytes: ?usize = null,
    };
};

/// What happens to a message that does not fit in the subscription.
pub const OverflowPolicy = enum {
    /// The new message is dropped.
    drop_newest,
    /// The oldest messages are dropped to make room for it.
    drop_oldest,
    /// The subscription ends: what it holds can still be taken, then
    /// SlowConsumer.
    close_subscription,
};

pub const ReceiveOptions = struct {
    /// How long to wait for a message; by default, as long as it takes.
    timeout: Io.Timeout = .none,
};

pub const NextError = error{
    /// No message came in time.
    Timeout,
    /// The task was canceled through `std.Io`.
    Canceled,
    /// Another task waits for the next message already.
    ConcurrentReceive,
    /// Messages did not fit and the policy is `close_subscription`; the
    /// ones before them came out first.
    SlowConsumer,
    /// The server refused the subscription.
    PermissionDenied,
    /// The client is closed.
    ConnectionClosed,
};

/// The next message, oldest first; free it with its `deinit()`. Waits for
/// one until `options.timeout`. Null once the subscription has ended
/// normally, unsubscribed or after `max_messages`, and nothing is left.
/// One task at a time may wait.
pub fn next(sub: *Subscription, options: ReceiveOptions) NextError!?Message {
    return sub.messages.next(sub.client.io, options.timeout) catch |err| switch (err) {
        // Only the responses of a requestMany end so.
        error.NoResponders, error.Disconnected => error.ConnectionClosed,
        else => |e| e,
    };
}

pub const UnsubscribeError = error{
    /// The client is closed.
    ConnectionClosed,
    /// No memory to queue the UNSUB.
    OutOfMemory,
    /// A bug in this client: the frame came out of another length.
    ProtocolError,
};

/// Ends the subscription now: the messages it holds are dropped, `next()`
/// returns null, and the server is told to stop sending. Any task may call
/// it; once the subscription has ended, it does nothing more. The
/// subscription ends even when the UNSUB cannot be queued: the client then
/// drops what the server still sends for it.
pub fn unsubscribe(sub: *Subscription) UnsubscribeError!void {
    const client = sub.client;
    const io = client.io;
    const sid = sub.sid;
    // Once it ends, a reader waiting in next() may free it: nothing below
    // touches it.
    if (sub.messages.endOpen(io, .finished, true)) |how| {
        if (how == .closed) return error.ConnectionClosed;
        return;
    }
    Registry.queueUnsub(&client.outbound, io, sid) catch |err| switch (err) {
        error.Closed => return error.ConnectionClosed,
        // Never for an UNSUB: without a connection the next one simply
        // does not subscribe again.
        error.Disconnected, error.BufferFull => {},
        else => |e| return e,
    };
}

pub const DrainOptions = Client.DrainOptions;

pub const DrainError = error{
    /// The messages that came were not all taken in time.
    Timeout,
    Canceled,
    /// The client is closed.
    ConnectionClosed,
    /// No memory for the PING that tells when the server has the UNSUB.
    OutOfMemory,
};

/// Stops the subscription gently: the server is told to stop sending, the
/// messages that still come before it has that are kept, and `next()`
/// hands out all of them and then null. It returns once they are all
/// taken and the reader came back to `next()`, done with the last one, so
/// another task must be reading `next()`. At `options.timeout`, 30 s by
/// default, it returns Timeout, and the subscription has ended anyway.
/// Without a connection nothing more can come, and it ends at once. A
/// second call while one runs, or one during the client's `drain()`, adds
/// nothing: it waits until that drain ends the subscription and its
/// messages are taken.
pub fn drain(sub: *Subscription, options: DrainOptions) DrainError!void {
    const client = sub.client;
    const io = client.io;
    const sid = sub.sid;
    const queue = &sub.messages;
    const deadline = time.deadline(io, options.timeout);
    // From here until it leaves, deinit() waits for this call.
    const began = queue.enterDrain(io);
    defer queue.leaveDrain();
    if (began) {
        // This call ends the subscription, whatever comes: what the server
        // sent before it had the UNSUB is kept.
        defer queue.finishDrain(io);
        try stopSending(client, sid, deadline);
    }
    return queue.awaitDrained(io, deadline);
}

/// UNSUB, and a PING whose PONG says that the server has it; without a
/// connection nothing more comes, and there is nothing to wait for.
fn stopSending(client: *Client, sid: u64, deadline: ?Io.Clock.Timestamp) DrainError!void {
    const io = client.io;
    Registry.queueUnsub(&client.outbound, io, sid) catch |err| switch (err) {
        error.Closed => return error.ConnectionClosed,
        error.OutOfMemory => return error.OutOfMemory,
        error.Disconnected, error.BufferFull, error.ProtocolError => {},
    };
    const ping = client.outbound.putPing(io, .flush) catch |err| switch (err) {
        error.Closed => return error.ConnectionClosed,
        error.Disconnected => return,
        error.OutOfMemory => return error.OutOfMemory,
    };
    client.outbound.waitPong(io, ping, deadline) catch |err| switch (err) {
        error.Closed => return error.ConnectionClosed,
        error.Disconnected => {},
        error.Timeout => return error.Timeout,
        error.Canceled => return error.Canceled,
    };
}

/// Whether the server refused the subscription, as for an account that
/// may not subscribe to its subject: no message comes, and `next()` fails
/// with PermissionDenied. The server answers a SUB before the PONG of a
/// later PING, so once a `flush()` made after `subscribe` returns, the
/// answer is known.
pub fn isDenied(sub: *Subscription) bool {
    return sub.messages.endedHow(sub.client.io) == .permission_denied;
}

/// What waits to be taken.
pub const PendingCounts = struct {
    messages: usize,
    /// The bytes of the messages, subjects and headers included.
    bytes: usize,
};

/// What waits in the subscription now.
pub fn pending(sub: *Subscription) PendingCounts {
    return sub.messages.pending(sub.client.io);
}

pub const Stats = struct {
    /// Messages the server delivered, the dropped ones included.
    received: u64,
    /// Messages `next()` handed out.
    delivered: u64,
    /// Messages lost: they did not fit, were over the client's limits, or
    /// found no memory.
    dropped: u64,
};

/// What the subscription has seen so far.
pub fn stats(sub: *Subscription) Stats {
    return sub.messages.stats(sub.client.io);
}

/// Ends the subscription and frees it, with the messages it still holds.
/// No task may wait in its `next()` meanwhile. The server is told to stop
/// sending, unless the subscription had ended already. A `drain()` of it
/// that another task runs returns first: `deinit()` waits for it, so call
/// it from the reader once `next()` returned null, not while the drain
/// still waits for the server.
pub fn deinit(sub: *Subscription) void {
    const client = sub.client;
    const io = client.io;
    const sid = sub.sid;
    if (sub.messages.end(io, .finished, true)) {
        Registry.queueUnsub(&client.outbound, io, sid) catch |err| {
            log.debug("no UNSUB for subscription {d}: {t}", .{ sid, err });
        };
    }
    // Done with what it holds: a drain() in another task finds it settled
    // and returns, and only then is it freed.
    sub.messages.dropAll(io);
    client.subscriptions.unregister(io, sid);
    sub.messages.awaitNoDrains(io);
    Registry.destroy(client.gpa, sub);
}
