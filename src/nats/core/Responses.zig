// Adapted from vkiryakov/zefir src/nats/Responses.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! The responses to one `requestMany`, in the order they came: scatter and
//! gather. The stream ends at the request's deadline or after
//! `max_responses` responses, whichever comes first; to stop earlier, on a
//! condition of your own, break out of the loop. The client owns it;
//! `deinit()` ends it and frees it, and comes before the client's own
//! `deinit()`.
//!
//! ```zig
//! const responses = try client.requestMany("inventory.count", "sku-42", .{ .max_responses = 8 });
//! defer responses.deinit();
//! while (true) {
//!     var msg = (try responses.next(.{})) orelse break;
//!     defer msg.deinit();
//!     total += try std.fmt.parseInt(u32, msg.payload, 10);
//! }
//! ```
//!
//! One task at a time waits in `next()`; any task may `cancel()`. The
//! fields are internal: use the methods.

const std = @import("std");
const Io = std.Io;
const Client = @import("Client.zig");
const Message = @import("Message.zig");
const Subscription = @import("Subscription.zig");
const MessageQueue = @import("engine/MessageQueue.zig");
const Inbox = @import("engine/Inbox.zig");
const time = @import("engine/time.zig");
const Responses = @This();

client: *Client,
/// Its id in the client's inbox.
id: u64,
/// In the inbox's pending map; the inbox's mutex guards it.
listed: bool = false,
/// In the inbox's list of streams, until `deinit()`.
node: std.DoublyLinkedList.Node = .{},
/// The connection its request frame went to, once queued.
generation: ?u64 = null,
/// The stream ends here, whatever came.
deadline: Io.Clock.Timestamp,
/// The responses that wait to be taken: the client's reader fills it.
/// Tests may ask it `isReceiving()` and `stats()`.
messages: MessageQueue,

pub const NextError = error{
    /// No response came within `options.timeout`; the stream goes on.
    Timeout,
    /// The task was canceled through `std.Io`.
    Canceled,
    /// Another task waits for the next response already.
    ConcurrentReceive,
    /// No one subscribes to the subject of the request.
    NoResponders,
    /// The connection was lost; the responses that came before it come
    /// out first.
    Disconnected,
    /// The server refused the subscription of the client's inbox: no
    /// response can come.
    PermissionDenied,
    /// The client is closed.
    ConnectionClosed,
};

/// The next response, oldest first; free it with its `deinit()`. Waits for
/// one until `options.timeout`, never past the deadline of the request.
/// Null once the stream has ended: at the deadline, after `max_responses`
/// responses, or after `cancel()`; the responses that came before come out
/// first. One task at a time may wait.
pub fn next(r: *Responses, options: Subscription.ReceiveOptions) NextError!?Message {
    const io = r.client.io;
    const wanted = time.deadline(io, options.timeout);
    const until = if (wanted) |w| if (w.raw.nanoseconds < r.deadline.raw.nanoseconds) w else r.deadline else r.deadline;
    while (true) {
        const response = r.messages.next(io, time.until(until)) catch |err| switch (err) {
            error.Timeout => {
                if (!time.expired(io, r.deadline)) return error.Timeout;
                // The deadline: what came comes out, then null.
                r.stop();
                continue;
            },
            error.Canceled, error.ConcurrentReceive => |e| return e,
            // Over: the request no longer waits.
            error.NoResponders, error.Disconnected, error.PermissionDenied, error.ConnectionClosed => |e| {
                r.leave();
                return e;
            },
            // A stream drops the newest when full.
            error.SlowConsumer => {
                r.leave();
                return error.ConnectionClosed;
            },
        };
        // Over: responses that still come are late.
        if (response == null) r.leave();
        return response;
    }
}

/// Ends the stream now, from any task, however it ended before: what
/// waits is dropped, `next()` returns null (ConnectionClosed once the
/// client is closed), and responses that still come count as late.
pub fn cancel(r: *Responses) void {
    const io = r.client.io;
    r.leave();
    r.messages.cancel(io);
}

/// The deadline: the stream leaves the inbox and ends, and what came
/// still comes out.
fn stop(r: *Responses) void {
    const io = r.client.io;
    r.leave();
    _ = r.messages.end(io, .finished, false);
}

/// The request is over: responses that still come are late, and its frame,
/// if it still waits for the next connection, is not sent.
fn leave(r: *Responses) void {
    const io = r.client.io;
    r.client.inbox.remove(io, r);
    r.client.outbound.forgetRequest(io, r.id);
}

/// Ends the stream and frees it, with the responses it still holds. No
/// task may wait in `next()` meanwhile.
pub fn deinit(r: *Responses) void {
    r.client.inbox.forget(r.client.io, r);
    r.client.outbound.forgetRequest(r.client.io, r.id);
    Inbox.destroyResponses(r.client.gpa, r);
}
