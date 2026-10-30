// Adapted from vkiryakov/zefir src/nats/engine/Inbox.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! The inbox of the client's requests. One subscription, `_INBOX.<token>.*`,
//! receives the replies to every request: a request publishes with the
//! reply subject `_INBOX.<token>.<id>` and waits under its id in the
//! pending map, and the reader hands each reply to the request its subject
//! names. The token is 22 random base62 characters, so other clients cannot
//! guess the subject.
//!
//! The first request makes the subscription: its SUB goes into the outbound
//! queue before that request's PUB, and requests that come meanwhile wait
//! until it is in, so no PUB overtakes it. The server handles one
//! connection in order, so the SUB applies before any reply can come.
//!
//! A request waits for its reply on an event of its own. The reply goes
//! into the request's slot and the request leaves the pending map under the
//! same mutex: whichever comes first, the reply or the end of the wait
//! (deadline, cancel), decides, and a reply that comes after counts as late.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Client = @import("../Client.zig");
const Message = @import("../Message.zig");
const Responses = @import("../Responses.zig");
const MessageQueue = @import("MessageQueue.zig");
const Outbound = @import("Outbound.zig");
const Registry = @import("Registry.zig");
const Broadcast = @import("Broadcast.zig");
const encoder = @import("../protocol/encoder.zig");
const server_error = @import("../protocol/server_error.zig");
const time = @import("time.zig");
const Inbox = @This();

/// Random base62 characters in the inbox subject.
pub const token_len = 22;
const head = "_INBOX.";
/// The length of `_INBOX.<token>.`, the start of every reply subject.
pub const prefix_len = head.len + token_len + 1;
/// The longest reply subject: the prefix and a 64-bit id in decimal.
pub const max_reply_len = prefix_len + 20;

/// Guards everything below but `sid`.
// SAFETY: NATS engine lock, outside the ranked wrappers until a single-owner
// connection replaces the nesting (research/s15/retrofit-9-rest.md Q1): order
// Outbound.mutex -> {Inbox.mutex, Registry.mutex} -> MessageQueue.mutex, never
// the other way; held across no suspension but an inner lock's wait and its
// own condition's wait.
mutex: Io.Mutex = .init,
/// The SID of the inbox subscription; 0 until a request makes it. The
/// reader reads it without the mutex: `prefix` is written before it.
sid: std.atomic.Value(u64) = .init(0),
/// `_INBOX.<token>.`, once the inbox has a SID.
prefix: [prefix_len]u8 = undefined,
subscription: SubscriptionState = .none,
/// Woken when `subscription` or `ended` changes: requests wait on it while
/// another one queues the SUB.
changed: Broadcast = .{},
/// The requests waiting for replies, by id. An array hash map: a removal
/// leaves no mark behind, so lookups stay as cheap after a burst of
/// requests as before it.
pending: std.AutoArrayHashMapUnmanaged(u64, Entry) = .empty,
/// Every stream of a requestMany until its `deinit()`, ended or not: the
/// client owns them, and frees in its own `deinit()` those left.
streams: std.DoublyLinkedList = .{},
/// The id of the next request; ids are never reused.
next_id: u64 = 1,
/// Requests in `await` now.
awaiting: u32 = 0,
/// Replies that came for no waiting request.
late: u64 = 0,
/// Streams of requestMany ended by "no responders".
no_responders: u64 = 0,
/// Why the inbox takes no more requests.
ended: ?End = null,

const SubscriptionState = enum {
    /// No SUB is queued.
    none,
    /// A request is queuing the SUB.
    subscribing,
    /// The SUB is in the outbound queue, or sent.
    subscribed,
};

/// Why the inbox ended.
pub const End = enum {
    /// The connection was lost: requests fail with Disconnected.
    disconnected,
    /// The server refused the inbox subscription: requests fail with
    /// PermissionDenied.
    permission_denied,
    /// The client closed: requests fail with ConnectionClosed.
    closed,

    pub fn err(how: End) error{ Disconnected, PermissionDenied, ConnectionClosed } {
        return switch (how) {
            .disconnected => error.Disconnected,
            .permission_denied => error.PermissionDenied,
            .closed => error.ConnectionClosed,
        };
    }
};

/// A request waiting for its one reply; it lives on the requesting task's
/// stack, and only the inbox's mutex guards it.
pub const Waiter = struct {
    /// Set when the reply came, the connection was lost or the inbox ended.
    done: Io.Event = .unset,
    reply: ?Message = null,
    /// Why the request ends without a reply.
    failure: ?End = null,
    /// In the pending map.
    listed: bool = false,
    /// The connection its frame went to, once queued (Outbound.Ticket).
    generation: ?u64 = null,
};

/// A request in the pending map.
pub const Entry = union(enum) {
    /// `request`: one reply.
    single: *Waiter,
    /// `requestMany`: every reply until its stream ends.
    many: *Responses,
};

pub const SubscribeError = error{ Timeout, Canceled, Disconnected, PermissionDenied, ConnectionClosed, OutOfMemory, ProtocolError } || Io.RandomSecureError;

/// Makes sure the inbox subscription is queued before the caller queues
/// its request. The first caller queues the SUB; the others wait until it
/// is in, at most until `deadline`.
pub fn subscribe(inbox: *Inbox, io: Io, registry: *Registry, outbound: *Outbound, deadline: ?Io.Clock.Timestamp) SubscribeError!void {
    {
        inbox.mutex.lockUncancelable(io);
        defer inbox.mutex.unlock(io);
        while (true) {
            if (inbox.ended) |how| return how.err();
            switch (inbox.subscription) {
                .subscribed => return,
                .none => break,
                .subscribing => {
                    if (deadline) |d| if (time.expired(io, d)) return error.Timeout;
                    try inbox.changed.wait(io, &inbox.mutex, deadline);
                },
            }
        }
        inbox.subscription = .subscribing;
    }
    // This request queues the SUB. Whatever comes of it, the requests at
    // the gate look again: they go on, or one of them tries.
    var queued = false;
    defer {
        inbox.mutex.lockUncancelable(io);
        inbox.subscription = if (queued) .subscribed else .none;
        inbox.changed.wake(io);
        inbox.mutex.unlock(io);
    }
    const sid = try inbox.identity(io, registry);
    var subject: [prefix_len + 1]u8 = undefined;
    @memcpy(subject[0..prefix_len], &inbox.prefix);
    subject[prefix_len] = '*';
    outbound.putUntil(io, deadline, .service, encoder.subLen(&subject, null, sid), encoder.writeSub, .{ @as([]const u8, &subject), @as(?[]const u8, null), sid }) catch |err| switch (err) {
        error.Closed => return inbox.closedError(io),
        // Never for a SUB: without a connection the next one subscribes
        // the inbox, and a drain refuses only publishes and requests.
        error.Disconnected, error.BufferFull, error.ConnectionDraining => {},
        else => |e| return e,
    };
    queued = true;
}

/// The token and the SID of the inbox, made by the first request that
/// subscribes and kept for the life of the client. Only the request
/// queuing the SUB calls it.
fn identity(inbox: *Inbox, io: Io, registry: *Registry) (Io.RandomSecureError || error{ConnectionClosed})!u64 {
    const known = inbox.sid.load(.acquire);
    if (known != 0) return known;
    var token: [token_len]u8 = undefined;
    try randomToken(io, &token);
    const sid = try registry.reserveSid(io);
    @memcpy(inbox.prefix[0..head.len], head);
    @memcpy(inbox.prefix[head.len..][0..token_len], &token);
    inbox.prefix[prefix_len - 1] = '.';
    // The reader routes by the SID, then reads the prefix.
    inbox.sid.store(sid, .release);
    return sid;
}

/// The outbound queue closed: the reason is the inbox's, which ends first.
pub fn closedError(inbox: *Inbox, io: Io) error{ Disconnected, PermissionDenied, ConnectionClosed } {
    inbox.mutex.lockUncancelable(io);
    defer inbox.mutex.unlock(io);
    const how = inbox.ended orelse return error.ConnectionClosed;
    return how.err();
}

pub const AddError = error{ TooManyPendingRequests, OutOfMemory, Disconnected, PermissionDenied, ConnectionClosed };

/// Puts a request in the pending map, before its PUB is queued, and gives
/// its id. At most `max` requests wait at once.
pub fn add(inbox: *Inbox, io: Io, gpa: Allocator, entry: Entry, max: u32) AddError!u64 {
    inbox.mutex.lockUncancelable(io);
    defer inbox.mutex.unlock(io);
    if (inbox.ended) |how| return how.err();
    if (inbox.pending.count() >= max) return error.TooManyPendingRequests;
    try inbox.pending.ensureUnusedCapacity(gpa, 1);
    const id = inbox.next_id;
    inbox.next_id += 1;
    inbox.pending.putAssumeCapacityNoClobber(id, entry);
    switch (entry) {
        .single => |waiter| waiter.listed = true,
        .many => |responses| {
            responses.listed = true;
            inbox.streams.append(&responses.node);
        },
    }
    return id;
}

/// Takes request `id` out of the pending map, unless it is out already:
/// a request looks itself up once.
fn unlist(inbox: *Inbox, id: u64, listed: *bool) void {
    if (!listed.*) return;
    _ = inbox.pending.swapRemove(id);
    listed.* = false;
}

/// Messages on `sid` are replies to requests.
pub fn owns(inbox: *const Inbox, sid: u64) bool {
    return sid != 0 and sid == inbox.sid.load(.acquire);
}

/// The reply subject of request `id`, in `buffer`.
pub fn replySubject(inbox: *const Inbox, buffer: *[max_reply_len]u8, id: u64) []const u8 {
    @memcpy(buffer[0..prefix_len], &inbox.prefix);
    return buffer[0 .. prefix_len + std.fmt.printInt(buffer[prefix_len..], id, 10, .lower, .{})];
}

/// The id of the request a reply subject names; null for any subject but
/// `_INBOX.<token>.<id>` of this inbox.
pub fn requestId(inbox: *const Inbox, subject: []const u8) ?u64 {
    if (subject.len <= prefix_len or !std.mem.eql(u8, subject[0..prefix_len], &inbox.prefix)) return null;
    const digits = subject[prefix_len..];
    // Ids are written without leading zeros, and start at 1.
    if (digits[0] == '0') return null;
    var id: u64 = 0;
    for (digits) |c| {
        if (c < '0' or c > '9') return null;
        id = std.math.mul(u64, id, 10) catch return null;
        id = std.math.add(u64, id, c - '0') catch return null;
    }
    return id;
}

pub const AwaitError = error{ Timeout, Canceled, NoResponders, Disconnected, PermissionDenied, ConnectionClosed };

/// Waits for the reply of request `id` until `deadline`, a cancel or the
/// end of the inbox, and takes the request out of the pending map. A reply
/// that came first is the result, unless the task was canceled; "no
/// responders" is NoResponders.
pub fn await(inbox: *Inbox, io: Io, id: u64, waiter: *Waiter, deadline: Io.Clock.Timestamp) AwaitError!Message {
    {
        inbox.mutex.lockUncancelable(io);
        defer inbox.mutex.unlock(io);
        inbox.awaiting += 1;
    }
    var canceled = false;
    while (!waiter.done.isSet()) {
        waiter.done.waitTimeout(io, .{ .deadline = deadline }) catch |err| switch (err) {
            // The deadline, or a spurious wakeup.
            error.Timeout => if (time.expired(io, deadline)) break,
            error.Canceled => {
                canceled = true;
                break;
            },
        };
    }
    inbox.mutex.lockUncancelable(io);
    defer inbox.mutex.unlock(io);
    inbox.awaiting -= 1;
    inbox.unlist(id, &waiter.listed);
    if (waiter.reply) |reply| {
        waiter.reply = null;
        if (canceled) {
            release(reply);
            inbox.late += 1;
            return error.Canceled;
        }
        if (isNoResponders(reply)) {
            release(reply);
            return error.NoResponders;
        }
        return reply;
    }
    if (canceled) return error.Canceled;
    // Without a reply, only a lost connection or the end of the inbox sets
    // the event.
    if (waiter.done.isSet()) {
        if (waiter.failure) |how| return how.err();
    }
    return error.Timeout;
}

/// Takes request `id` out of the pending map if it is still there; a reply
/// left in its slot is freed and counts as late. Every request calls it on
/// its way out.
pub fn drop(inbox: *Inbox, io: Io, id: u64, waiter: *Waiter) void {
    inbox.mutex.lockUncancelable(io);
    defer inbox.mutex.unlock(io);
    inbox.unlist(id, &waiter.listed);
    if (waiter.reply) |reply| {
        waiter.reply = null;
        release(reply);
        inbox.late += 1;
    }
}

/// How many bytes the request `id` takes in a reply; null when no request
/// waits under it, and its reply is late.
pub fn accepts(inbox: *Inbox, io: Io, id: u64) ?usize {
    inbox.mutex.lockUncancelable(io);
    defer inbox.mutex.unlock(io);
    const entry = inbox.pending.get(id) orelse return null;
    return switch (entry) {
        .single => std.math.maxInt(usize),
        .many => |responses| takes(io, responses),
    };
}

/// Takes the stream of a requestMany out of the pending map, if it is
/// still there: replies to it count as late from now on. The inbox still
/// holds the stream until `forget`.
pub fn remove(inbox: *Inbox, io: Io, responses: *Responses) void {
    inbox.mutex.lockUncancelable(io);
    defer inbox.mutex.unlock(io);
    inbox.unlist(responses.id, &responses.listed);
}

/// Lets go of a stream that `add` took: out of the pending map and out of
/// the inbox's streams, for its owner to free.
pub fn forget(inbox: *Inbox, io: Io, responses: *Responses) void {
    inbox.mutex.lockUncancelable(io);
    defer inbox.mutex.unlock(io);
    inbox.unlist(responses.id, &responses.listed);
    inbox.streams.remove(&responses.node);
}

/// What became of a reply.
pub const Delivery = enum {
    /// Its request has it.
    taken,
    /// No request waits for it: it counts as late.
    late,
    /// It came, but could not be kept.
    dropped,
};

/// Hands a reply to request `id`: `message`, or null for one that came but
/// could not be kept. The message is the request's, or freed.
pub fn deliver(inbox: *Inbox, io: Io, id: u64, message: ?Message) Delivery {
    inbox.mutex.lockUncancelable(io);
    defer inbox.mutex.unlock(io);
    const entry = inbox.pending.get(id) orelse {
        if (message) |m| release(m);
        inbox.late += 1;
        return .late;
    };
    switch (entry) {
        .single => |waiter| {
            // The request waits on, until its deadline.
            const m = message orelse return .dropped;
            // The first reply is the request's; a later one finds no entry.
            inbox.unlist(id, &waiter.listed);
            waiter.reply = m;
            waiter.done.set(io);
            return .taken;
        },
        .many => |responses| {
            // After its deadline, `max_responses` or `cancel()`, the stream
            // takes nothing more.
            if (takes(io, responses) == null) {
                if (message) |m| release(m);
                inbox.late += 1;
                return .late;
            }
            // A "no responders" first ends the stream.
            if (message) |m| if (isNoResponders(m) and responses.messages.stats(io).received == 0) {
                release(m);
                _ = responses.messages.end(io, .no_responders, false);
                inbox.no_responders += 1;
                inbox.unlist(id, &responses.listed);
                return .taken;
            };
            const pushed = responses.messages.push(io, message);
            // Ended by its last response: no place among the pending.
            if (pushed.ended != null) inbox.unlist(id, &responses.listed);
            return if (pushed.dropped > 0) .dropped else .taken;
        },
    }
}

/// The server refused a subscription: when it is the inbox's, by its SID
/// or by its subject, no reply can come, and every request fails with
/// PermissionDenied, those waiting and those to come. True when it was.
pub fn deny(inbox: *Inbox, io: Io, permission: server_error.Permission) bool {
    if (permission.operation != .subscribe) return false;
    const sid = inbox.sid.load(.acquire);
    if (sid == 0) return false;
    const named = if (permission.sid) |denied| denied == sid else named: {
        var subject: [prefix_len + 1]u8 = undefined;
        @memcpy(subject[0..prefix_len], &inbox.prefix);
        subject[prefix_len] = '*';
        break :named permission.queue == null and server_error.quotedEql(permission.subject, &subject);
    };
    if (!named) return false;
    inbox.end(io, .permission_denied);
    return true;
}

/// Counts a reply that came for no waiting request.
pub fn noteLate(inbox: *Inbox, io: Io) void {
    inbox.mutex.lockUncancelable(io);
    defer inbox.mutex.unlock(io);
    inbox.late += 1;
}

/// The connection is gone, or the client closed: no new requests, and
/// every waiting one ends with the error of `how` at once. `.closed`
/// replaces `.disconnected`.
pub fn end(inbox: *Inbox, io: Io, how: End) void {
    inbox.mutex.lockUncancelable(io);
    defer inbox.mutex.unlock(io);
    if (inbox.ended == .closed or (inbox.ended != null and how != .closed)) return;
    inbox.ended = how;
    for (inbox.pending.values()) |entry| switch (entry) {
        .single => |waiter| {
            waiter.failure = how;
            waiter.done.set(io);
        },
        .many => {},
    };
    // Every stream, those that ended too: after close() their next() is
    // ConnectionClosed, as for subscriptions. Otherwise what came still
    // comes out first.
    const stream_end: MessageQueue.End = switch (how) {
        .disconnected => .disconnected,
        .permission_denied => .permission_denied,
        .closed => .closed,
    };
    var node = inbox.streams.first;
    while (node) |n| : (node = n.next) {
        const responses: *Responses = @alignCast(@fieldParentPtr("node", n));
        _ = responses.messages.end(io, lostEnd(io, responses, stream_end), how == .closed);
    }
    inbox.changed.wake(io);
}

/// How a stream ends when the connection is lost or the inbox refused:
/// with `how`, but one past its deadline had ended already, and its owner
/// gets what came, then null. A close ends every stream.
fn lostEnd(io: Io, responses: *Responses, how: MessageQueue.End) MessageQueue.End {
    if (how == .closed) return how;
    return if (time.expired(io, responses.deadline)) .finished else how;
}

/// The client drained and closes: no new requests, and every request
/// waiting fails with ConnectionClosed, but a stream of requestMany keeps
/// the responses it received for its owner, then ends with null. A drain
/// waits for every request that still takes replies, so the streams here
/// took all they take.
pub fn endDrained(inbox: *Inbox, io: Io) void {
    inbox.mutex.lockUncancelable(io);
    defer inbox.mutex.unlock(io);
    if (inbox.ended == .closed) return;
    inbox.ended = .closed;
    for (inbox.pending.values()) |entry| switch (entry) {
        .single => |waiter| {
            waiter.failure = .closed;
            waiter.done.set(io);
        },
        .many => {},
    };
    var node = inbox.streams.first;
    while (node) |n| : (node = n.next) {
        const responses: *Responses = @alignCast(@fieldParentPtr("node", n));
        _ = responses.messages.end(io, .finished, false);
    }
    inbox.changed.wake(io);
}

/// The connection is lost and the client reconnects; `next` is the
/// connection to come. Every request whose frame went to the lost one, or
/// has not been queued yet, fails with Disconnected at once: a stream
/// hands out what came and then says Disconnected. They leave the pending
/// map, so replies that still come are late, and a frame not queued yet
/// never will be. Requests whose frames wait for `next` go on. The inbox
/// goes on too; the next connection subscribes it again, with the same
/// subject and SID.
pub fn disconnect(inbox: *Inbox, io: Io, next: u64) void {
    inbox.mutex.lockUncancelable(io);
    defer inbox.mutex.unlock(io);
    if (inbox.ended != null) return;
    // From the end: a removal moves the last entry, seen already.
    var index = inbox.pending.count();
    while (index > 0) {
        index -= 1;
        switch (inbox.pending.values()[index]) {
            .single => |waiter| {
                if (waiter.generation == next) continue;
                waiter.listed = false;
                waiter.failure = .disconnected;
                waiter.done.set(io);
            },
            .many => |responses| {
                if (responses.generation == next) continue;
                responses.listed = false;
                _ = responses.messages.end(io, lostEnd(io, responses, .disconnected), false);
            },
        }
        inbox.pending.swapRemoveAt(index);
    }
}

/// The frame of request `id`, which waited for a new connection, is more
/// than the new server takes: the request fails with Disconnected at once,
/// a stream after what came, and replies that still come are late.
pub fn refuse(inbox: *Inbox, io: Io, id: u64) void {
    inbox.mutex.lockUncancelable(io);
    defer inbox.mutex.unlock(io);
    const entry = inbox.pending.get(id) orelse return;
    switch (entry) {
        .single => |waiter| {
            waiter.listed = false;
            waiter.failure = .disconnected;
            waiter.done.set(io);
        },
        .many => |responses| {
            responses.listed = false;
            _ = responses.messages.end(io, .disconnected, false);
        },
    }
    _ = inbox.pending.swapRemove(id);
}

/// The ticket of request `id`'s frame: the frame goes in only while the
/// request waits, and the request learns which connection it went to.
pub fn ticket(inbox: *Inbox, id: u64) Outbound.Ticket {
    return .{ .id = id, .context = inbox, .admit = admitFrame };
}

fn admitFrame(context: *anyopaque, io: Io, id: u64, generation: u64) bool {
    const inbox: *Inbox = @ptrCast(@alignCast(context));
    inbox.mutex.lockUncancelable(io);
    defer inbox.mutex.unlock(io);
    const entry = inbox.pending.get(id) orelse return false;
    switch (entry) {
        .single => |waiter| {
            if (waiter.failure != null) return false;
            waiter.generation = generation;
        },
        .many => |responses| {
            // Ended meanwhile, as by a refused inbox: nothing is sent.
            if (takes(io, responses) == null) return false;
            responses.generation = generation;
        },
    }
    return true;
}

/// Why a request failed before its frame could be queued: the end of the
/// inbox, a refused inbox, or the connection lost.
pub fn failureOf(inbox: *Inbox, io: Io, waiter: *const Waiter) error{ Disconnected, PermissionDenied, ConnectionClosed } {
    inbox.mutex.lockUncancelable(io);
    defer inbox.mutex.unlock(io);
    const how = waiter.failure orelse inbox.ended orelse return error.Disconnected;
    return how.err();
}

/// Request `id` still waits for its reply: its frame is worth sending.
pub fn awaitsReply(inbox: *Inbox, io: Io, id: u64) bool {
    inbox.mutex.lockUncancelable(io);
    defer inbox.mutex.unlock(io);
    const entry = inbox.pending.get(id) orelse return false;
    return switch (entry) {
        .single => |waiter| waiter.failure == null,
        .many => |responses| takes(io, responses) != null,
    };
}

/// What a new connection must subscribe to for the inbox: its subject,
/// written into `subject`, and the SID it returns; null when no request
/// made the inbox yet, or it ended for good.
pub fn restoreSub(inbox: *Inbox, io: Io, subject: *[prefix_len + 1]u8) ?u64 {
    inbox.mutex.lockUncancelable(io);
    defer inbox.mutex.unlock(io);
    if (inbox.ended != null) return null;
    const sid = inbox.sid.load(.acquire);
    if (sid == 0) return null;
    @memcpy(subject[0..prefix_len], &inbox.prefix);
    subject[prefix_len] = '*';
    return sid;
}

/// Frees what the inbox holds, the streams of requestMany not freed yet
/// included, ended or not: the client goes away. No request waits any
/// more.
pub fn deinit(inbox: *Inbox, gpa: Allocator) void {
    while (inbox.streams.popFirst()) |node| {
        const responses: *Responses = @alignCast(@fieldParentPtr("node", node));
        destroyResponses(gpa, responses);
    }
    inbox.pending.deinit(gpa);
    inbox.* = undefined;
}

/// The stream of a requestMany of `client` that ends at `deadline`, with
/// room for `limits` and ending after `limits.messages` responses; it gets
/// its id when it joins the inbox.
pub fn createResponses(gpa: Allocator, client: *Client, deadline: Io.Clock.Timestamp, limits: MessageQueue.Limits) Allocator.Error!*Responses {
    const responses = try gpa.create(Responses);
    responses.* = .{
        .client = client,
        .id = 0,
        .deadline = deadline,
        .messages = .init(gpa, limits, .drop_newest, limits.messages),
    };
    return responses;
}

/// Frees `responses` and what it holds; the inbox must not hold it: `add`
/// failed, or `forget` let it go.
pub fn destroyResponses(gpa: Allocator, responses: *Responses) void {
    responses.messages.deinit();
    gpa.destroy(responses);
}

/// How many bytes a response may take; null when the stream takes no
/// more: after its deadline, `max_responses` or `cancel()`.
fn takes(io: Io, responses: *Responses) ?usize {
    if (time.expired(io, responses.deadline) or !responses.messages.isOpen(io)) return null;
    return responses.messages.limits.bytes;
}

/// Requests waiting for a reply; tests use it.
pub fn pendingCount(inbox: *Inbox, io: Io) usize {
    inbox.mutex.lockUncancelable(io);
    defer inbox.mutex.unlock(io);
    return inbox.pending.count();
}

/// Requests that still wait for replies: a stream of requestMany past its
/// deadline, or ended, does not, though its owner has not taken it out of
/// the pending map yet.
pub fn activeCount(inbox: *Inbox, io: Io) usize {
    inbox.mutex.lockUncancelable(io);
    defer inbox.mutex.unlock(io);
    var active: usize = 0;
    for (inbox.pending.values()) |entry| switch (entry) {
        .single => active += 1,
        .many => |responses| if (takes(io, responses) != null) {
            active += 1;
        },
    };
    return active;
}

/// Requests inside `await` now; tests use it to know that one waits.
pub fn awaitingCount(inbox: *Inbox, io: Io) u32 {
    inbox.mutex.lockUncancelable(io);
    defer inbox.mutex.unlock(io);
    return inbox.awaiting;
}

/// Streams of requestMany that ended with "no responders".
pub fn noRespondersCount(inbox: *Inbox, io: Io) u64 {
    inbox.mutex.lockUncancelable(io);
    defer inbox.mutex.unlock(io);
    return inbox.no_responders;
}

/// Replies that came for no waiting request; tests use it.
pub fn lateResponses(inbox: *Inbox, io: Io) u64 {
    inbox.mutex.lockUncancelable(io);
    defer inbox.mutex.unlock(io);
    return inbox.late;
}

const alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

/// Fills `token` with random base62 characters from `io.randomSecure`.
fn randomToken(io: Io, token: *[token_len]u8) Io.RandomSecureError!void {
    var filled: usize = 0;
    var bytes: [64]u8 = undefined;
    while (filled < token.len) {
        try io.randomSecure(&bytes);
        for (bytes) |byte| {
            // Below 248, four times 62, every character is equally likely.
            if (byte >= 248) continue;
            token[filled] = alphabet[byte % alphabet.len];
            filled += 1;
            if (filled == token.len) break;
        }
    }
}

/// A reply that says no one subscribes to the subject of the request.
fn isNoResponders(message: Message) bool {
    return message.status == 503 and message.payload.len == 0;
}

fn release(message: Message) void {
    var m = message;
    m.deinit();
}

const testing = std.testing;

test "a token is 22 base62 characters, and two are not the same" {
    var a: [token_len]u8 = undefined;
    var b: [token_len]u8 = undefined;
    try randomToken(testing.io, &a);
    try randomToken(testing.io, &b);
    for (a ++ b) |c| try testing.expect(std.mem.findScalar(u8, alphabet, c) != null);
    try testing.expect(!std.mem.eql(u8, &a, &b));
}

/// An inbox with a known token, as if a request had made its subscription.
fn testInbox() Inbox {
    var inbox: Inbox = .{};
    @memcpy(&inbox.prefix, head ++ "tokentokentokentoken42.");
    return inbox;
}

test "a reply subject names its request, and only this inbox's subjects name one" {
    var inbox = testInbox();
    defer inbox.deinit(testing.allocator);
    var buffer: [max_reply_len]u8 = undefined;
    for ([_]u64{ 1, 42, std.math.maxInt(u64) }) |id| {
        const subject = inbox.replySubject(&buffer, id);
        try testing.expect(std.mem.startsWith(u8, subject, "_INBOX.tokentokentokentoken42."));
        try testing.expectEqual(id, inbox.requestId(subject).?);
    }
    try testing.expectEqualStrings("_INBOX.tokentokentokentoken42.7", inbox.replySubject(&buffer, 7));
    for ([_][]const u8{
        "",
        "_INBOX.tokentokentokentoken42.",
        "_INBOX.tokentokentokentoken42.0",
        "_INBOX.tokentokentokentoken42.01",
        "_INBOX.tokentokentokentoken42.1a",
        "_INBOX.tokentokentokentoken42.1_0",
        "_INBOX.tokentokentokentoken42.+1",
        "_INBOX.tokentokentokentoken42.18446744073709551616",
        "_INBOX.othertokenothertoken42.1",
        "foo.1",
    }) |subject| {
        try testing.expect(inbox.requestId(subject) == null);
    }
}

/// A message to `subject` with `payload`, and the status line of `status`
/// when it has one, as the reader would assemble it.
fn testReply(subject: []const u8, status: ?u16, payload: []const u8) !Message {
    const buffer = try testing.allocator.alloc(u8, subject.len + payload.len);
    @memcpy(buffer[0..subject.len], subject);
    @memcpy(buffer[subject.len..], payload);
    return .{
        .subject = buffer[0..subject.len],
        .reply_to = null,
        .headers = .empty,
        .payload = buffer[subject.len..],
        .status = status,
        .description = "",
        .buffer = buffer,
        .gpa = testing.allocator,
    };
}

const soon_ms = 5000;

fn soon(io: Io) Io.Clock.Timestamp {
    return time.after(io, .fromMilliseconds(soon_ms));
}

test "a reply reaches its own request only, and the request takes it" {
    const io = testing.io;
    var inbox = testInbox();
    defer inbox.deinit(testing.allocator);
    var first: Waiter = .{};
    var second: Waiter = .{};
    const one = try inbox.add(io, testing.allocator, .{ .single = &first }, 10);
    defer inbox.drop(io, one, &first);
    const two = try inbox.add(io, testing.allocator, .{ .single = &second }, 10);
    defer inbox.drop(io, two, &second);
    try testing.expect(one != two);
    try testing.expectEqual(maxBytes(), inbox.accepts(io, two).?);

    try testing.expectEqual(.taken, inbox.deliver(io, two, try testReply("r", null, "for two")));
    try testing.expect(second.done.isSet());
    try testing.expect(!first.done.isSet());
    var reply = try inbox.await(io, two, &second, soon(io));
    defer reply.deinit();
    try testing.expectEqualStrings("for two", reply.payload);
    try testing.expectEqual(1, inbox.pendingCount(io));
    try testing.expectEqual(0, inbox.lateResponses(io));
}

fn maxBytes() usize {
    return std.math.maxInt(usize);
}

test "replies for no waiting request are late: unknown ids and a second reply" {
    const io = testing.io;
    var inbox = testInbox();
    defer inbox.deinit(testing.allocator);
    try testing.expectEqual(.late, inbox.deliver(io, 99, try testReply("r", null, "x")));
    var waiter: Waiter = .{};
    const id = try inbox.add(io, testing.allocator, .{ .single = &waiter }, 10);
    defer inbox.drop(io, id, &waiter);
    try testing.expectEqual(.taken, inbox.deliver(io, id, try testReply("r", null, "first")));
    // The first reply took the request out of the map.
    try testing.expect(inbox.accepts(io, id) == null);
    try testing.expectEqual(.late, inbox.deliver(io, id, try testReply("r", null, "second")));
    inbox.noteLate(io);
    try testing.expectEqual(3, inbox.lateResponses(io));
    var reply = try inbox.await(io, id, &waiter, soon(io));
    defer reply.deinit();
    try testing.expectEqualStrings("first", reply.payload);
    try testing.expectEqual(0, inbox.pendingCount(io));
}

test "a reply that could not be kept leaves the request waiting" {
    const io = testing.io;
    var inbox = testInbox();
    defer inbox.deinit(testing.allocator);
    var waiter: Waiter = .{};
    const id = try inbox.add(io, testing.allocator, .{ .single = &waiter }, 10);
    defer inbox.drop(io, id, &waiter);
    try testing.expectEqual(.dropped, inbox.deliver(io, id, null));
    try testing.expect(!waiter.done.isSet());
    try testing.expectError(error.Timeout, inbox.await(io, id, &waiter, time.after(io, .fromMilliseconds(10))));
}

test "no more pending requests than the limit" {
    const io = testing.io;
    var inbox = testInbox();
    defer inbox.deinit(testing.allocator);
    var waiters: [3]Waiter = @splat(.{});
    const a = try inbox.add(io, testing.allocator, .{ .single = &waiters[0] }, 2);
    const b = try inbox.add(io, testing.allocator, .{ .single = &waiters[1] }, 2);
    try testing.expectError(error.TooManyPendingRequests, inbox.add(io, testing.allocator, .{ .single = &waiters[2] }, 2));
    inbox.drop(io, a, &waiters[0]);
    const c = try inbox.add(io, testing.allocator, .{ .single = &waiters[2] }, 2);
    inbox.drop(io, b, &waiters[1]);
    inbox.drop(io, c, &waiters[2]);
    try testing.expectEqual(0, inbox.pendingCount(io));
}

test "the deadline ends the wait with Timeout, and the reply after it is late" {
    const io = testing.io;
    var inbox = testInbox();
    defer inbox.deinit(testing.allocator);
    var waiter: Waiter = .{};
    const id = try inbox.add(io, testing.allocator, .{ .single = &waiter }, 10);
    defer inbox.drop(io, id, &waiter);
    const deadline = time.after(io, .fromMilliseconds(20));
    try testing.expectError(error.Timeout, inbox.await(io, id, &waiter, deadline));
    try testing.expect(time.expired(io, deadline));
    try testing.expectEqual(.late, inbox.deliver(io, id, try testReply("r", null, "too late")));
    try testing.expectEqual(1, inbox.lateResponses(io));
    try testing.expectEqual(0, inbox.pendingCount(io));
}

test "a reply that came before the deadline is the result, even when the deadline has passed" {
    const io = testing.io;
    var inbox = testInbox();
    defer inbox.deinit(testing.allocator);
    var waiter: Waiter = .{};
    const id = try inbox.add(io, testing.allocator, .{ .single = &waiter }, 10);
    defer inbox.drop(io, id, &waiter);
    try testing.expectEqual(.taken, inbox.deliver(io, id, try testReply("r", null, "in time")));
    var reply = try inbox.await(io, id, &waiter, time.after(io, .zero));
    defer reply.deinit();
    try testing.expectEqualStrings("in time", reply.payload);
}

test "no responders: a 503 without a body; with a body it is a reply" {
    const io = testing.io;
    var inbox = testInbox();
    defer inbox.deinit(testing.allocator);
    var empty: Waiter = .{};
    const a = try inbox.add(io, testing.allocator, .{ .single = &empty }, 10);
    defer inbox.drop(io, a, &empty);
    _ = inbox.deliver(io, a, try testReply("r", 503, ""));
    try testing.expectError(error.NoResponders, inbox.await(io, a, &empty, soon(io)));

    var with_body: Waiter = .{};
    const b = try inbox.add(io, testing.allocator, .{ .single = &with_body }, 10);
    defer inbox.drop(io, b, &with_body);
    _ = inbox.deliver(io, b, try testReply("r", 503, "busy"));
    var reply = try inbox.await(io, b, &with_body, soon(io));
    defer reply.deinit();
    try testing.expectEqual(503, reply.status.?);
}

/// Adds a request and waits for its reply, as `request` does.
fn addAndAwait(inbox: *Inbox, io: Io, deadline: Io.Clock.Timestamp) AwaitError!Message {
    var waiter: Waiter = .{};
    const id = inbox.add(io, testing.allocator, .{ .single = &waiter }, 100) catch |err| switch (err) {
        error.Disconnected, error.PermissionDenied, error.ConnectionClosed => |e| return e,
        error.TooManyPendingRequests, error.OutOfMemory => return error.Timeout,
    };
    defer inbox.drop(io, id, &waiter);
    return inbox.await(io, id, &waiter, deadline);
}

/// Waits until `count` requests wait in `await`, for 5 s at most.
fn awaitAwaiting(inbox: *Inbox, io: Io, count: u32) !void {
    const give_up = time.after(io, .fromSeconds(5 * @as(i64, @import("anole_test_wait").timeoutFactor())));
    while (inbox.awaitingCount(io) < count) {
        if (time.expired(io, give_up)) return error.TestNeverWaited;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

/// The result of a future is `expected`; a reply instead fails the test,
/// and the future's deferred cancel frees it.
fn expectNoReply(result: AwaitError!Message, expected: AwaitError) !void {
    if (result) |_| return error.TestUnexpectedReply else |err| try testing.expectEqual(expected, err);
}

test "end wakes every waiting request with its reason; closed replaces disconnected" {
    const io = testing.io;
    var inbox = testInbox();
    defer inbox.deinit(testing.allocator);
    var a = try io.concurrent(addAndAwait, .{ &inbox, io, soon(io) });
    defer if (a.cancel(io)) |m| release(m) else |_| {};
    var b = try io.concurrent(addAndAwait, .{ &inbox, io, soon(io) });
    defer if (b.cancel(io)) |m| release(m) else |_| {};
    try awaitAwaiting(&inbox, io, 2);
    inbox.end(io, .disconnected);
    try expectNoReply(a.await(io), error.Disconnected);
    try expectNoReply(b.await(io), error.Disconnected);
    try testing.expectEqual(0, inbox.pendingCount(io));
    var waiter: Waiter = .{};
    try testing.expectError(error.Disconnected, inbox.add(io, testing.allocator, .{ .single = &waiter }, 10));
    inbox.end(io, .closed);
    try testing.expectError(error.ConnectionClosed, inbox.add(io, testing.allocator, .{ .single = &waiter }, 10));
    inbox.end(io, .disconnected);
    try testing.expectError(error.ConnectionClosed, inbox.add(io, testing.allocator, .{ .single = &waiter }, 10));
}

test "a canceled request returns Canceled and leaves the map" {
    const io = testing.io;
    var inbox = testInbox();
    defer inbox.deinit(testing.allocator);
    var request = try io.concurrent(addAndAwait, .{ &inbox, io, soon(io) });
    defer if (request.cancel(io)) |m| release(m) else |_| {};
    try awaitAwaiting(&inbox, io, 1);
    try expectNoReply(request.cancel(io), error.Canceled);
    try testing.expectEqual(0, inbox.pendingCount(io));
}

test "a reply left behind by a request that gave up is freed and counts as late" {
    const io = testing.io;
    var inbox = testInbox();
    defer inbox.deinit(testing.allocator);
    var waiter: Waiter = .{};
    const id = try inbox.add(io, testing.allocator, .{ .single = &waiter }, 10);
    // The request gives up before it waits, for one; its reply came anyway.
    _ = inbox.deliver(io, id, try testReply("r", null, "orphan"));
    inbox.drop(io, id, &waiter);
    try testing.expectEqual(1, inbox.lateResponses(io));
    try testing.expectEqual(0, inbox.pendingCount(io));
}

fn exercise(gpa: Allocator) !void {
    const io = testing.io;
    var inbox = testInbox();
    defer inbox.deinit(gpa);
    var waiters: [20]Waiter = @splat(.{});
    var ids: [20]u64 = undefined;
    for (&waiters, &ids) |*waiter, *id| id.* = try inbox.add(io, gpa, .{ .single = waiter }, 100);
    for (&waiters, ids) |*waiter, id| inbox.drop(io, id, waiter);
}

test "nothing leaks when an allocation fails" {
    try testing.checkAllAllocationFailures(@import("../../../testing/no_resize.zig").allocator, exercise, .{});
}

/// A request's side of the gate.
fn subscribeUntil(inbox: *Inbox, io: Io, registry: *Registry, outbound: *Outbound, deadline: Io.Clock.Timestamp) SubscribeError!void {
    return inbox.subscribe(io, registry, outbound, deadline);
}

/// Waits until `count` requests wait at the gate, for 5 s at most.
fn awaitGate(inbox: *Inbox, io: Io, count: u32) !void {
    const give_up = time.after(io, .fromSeconds(5 * @as(i64, @import("anole_test_wait").timeoutFactor())));
    while (true) {
        inbox.mutex.lockUncancelable(io);
        const waiting = inbox.changed.waiters;
        inbox.mutex.unlock(io);
        if (waiting >= count) return;
        if (time.expired(io, give_up)) return error.TestNeverWaited;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn awaitRoomWaiters(outbound: *Outbound, io: Io, count: u32) !void {
    const give_up = time.after(io, .fromSeconds(5 * @as(i64, @import("anole_test_wait").timeoutFactor())));
    while (outbound.roomWaiters(io) < count) {
        if (time.expired(io, give_up)) return error.TestNeverWaited;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn writeFiller(w: *std.Io.Writer) std.Io.Writer.Error!void {
    return encoder.writePub(w, "filler", null, "0123456789");
}

/// Takes everything queued, as the writer would, and appends it to `out`.
fn drain(outbound: *Outbound, io: Io, out: *std.ArrayList(u8)) !void {
    var slices: [16][]const u8 = undefined;
    const batch = (try outbound.take(io, &slices)) orelse return error.TestClosed;
    for (batch.slices) |slice| try out.appendSlice(testing.allocator, slice);
    outbound.written(io, batch.len);
}

test "the first request queues the SUB, and the others wait until it is in" {
    const io = testing.io;
    var registry: Registry = .{};
    defer registry.deinit(testing.allocator);
    var outbound: Outbound = .init(testing.allocator, 16);
    defer outbound.deinit();
    var inbox: Inbox = .{};
    defer inbox.deinit(testing.allocator);
    // The queue is full: the SUB has to wait for room.
    try outbound.put(io, .publish, encoder.pubLen("filler", null, 10), writeFiller, .{});
    var first = try io.concurrent(subscribeUntil, .{ &inbox, io, &registry, &outbound, soon(io) });
    defer first.cancel(io) catch {};
    try awaitRoomWaiters(&outbound, io, 1);
    var second = try io.concurrent(subscribeUntil, .{ &inbox, io, &registry, &outbound, soon(io) });
    defer second.cancel(io) catch {};
    // The second waits at the gate, not in the outbound queue.
    try awaitGate(&inbox, io, 1);
    try testing.expectEqual(1, outbound.roomWaiters(io));

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try drain(&outbound, io, &out);
    try first.await(io);
    try second.await(io);
    // Later requests pass at once.
    try inbox.subscribe(io, &registry, &outbound, soon(io));
    try drain(&outbound, io, &out);
    var expected: [128]u8 = undefined;
    const sub_line = try std.fmt.bufPrint(&expected, "SUB {s}* 1\r\n", .{&inbox.prefix});
    try testing.expectEqualStrings("PUB filler 10\r\n0123456789\r\n", out.items[0..27]);
    try testing.expectEqualStrings(sub_line, out.items[27..]);
    try testing.expectEqual(1, inbox.sid.load(.acquire));
    try testing.expect(std.mem.startsWith(u8, &inbox.prefix, "_INBOX."));
}

test "a request that gives up while it queues the SUB lets the next one queue it" {
    const io = testing.io;
    var registry: Registry = .{};
    defer registry.deinit(testing.allocator);
    var outbound: Outbound = .init(testing.allocator, 16);
    defer outbound.deinit();
    var inbox: Inbox = .{};
    defer inbox.deinit(testing.allocator);
    try outbound.put(io, .publish, encoder.pubLen("filler", null, 10), writeFiller, .{});
    var first = try io.concurrent(subscribeUntil, .{ &inbox, io, &registry, &outbound, soon(io) });
    defer first.cancel(io) catch {};
    try awaitRoomWaiters(&outbound, io, 1);
    var second = try io.concurrent(subscribeUntil, .{ &inbox, io, &registry, &outbound, soon(io) });
    defer second.cancel(io) catch {};
    try awaitGate(&inbox, io, 1);
    try testing.expectError(error.Canceled, first.cancel(io));
    // The second queues the SUB now; it waits for room in its turn.
    try awaitRoomWaiters(&outbound, io, 1);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try drain(&outbound, io, &out);
    try second.await(io);
    try drain(&outbound, io, &out);
    try testing.expectEqual(1, std.mem.count(u8, out.items, "SUB "));
}

test "a request waiting at the gate gives up at its deadline, and the end of the inbox wakes it" {
    const io = testing.io;
    var registry: Registry = .{};
    defer registry.deinit(testing.allocator);
    var outbound: Outbound = .init(testing.allocator, 16);
    defer outbound.deinit();
    var inbox: Inbox = .{};
    defer inbox.deinit(testing.allocator);
    try outbound.put(io, .publish, encoder.pubLen("filler", null, 10), writeFiller, .{});
    var first = try io.concurrent(subscribeUntil, .{ &inbox, io, &registry, &outbound, soon(io) });
    defer first.cancel(io) catch {};
    try awaitRoomWaiters(&outbound, io, 1);
    const deadline = time.after(io, .fromMilliseconds(20));
    try testing.expectError(error.Timeout, inbox.subscribe(io, &registry, &outbound, deadline));
    try testing.expect(time.expired(io, deadline));

    var second = try io.concurrent(subscribeUntil, .{ &inbox, io, &registry, &outbound, soon(io) });
    defer second.cancel(io) catch {};
    try awaitGate(&inbox, io, 1);
    inbox.end(io, .disconnected);
    try testing.expectError(error.Disconnected, second.await(io));
    // The first one learns why the queue closed.
    outbound.close(io);
    try testing.expectError(error.Disconnected, first.await(io));
}

/// A requestMany's stream in `inbox`, as `Client.requestMany` makes it;
/// these tests use only its queue and deadline.
fn addStream(inbox: *Inbox, io: Io, deadline: Io.Clock.Timestamp, limits: MessageQueue.Limits) !*Responses {
    const responses = try createResponses(testing.allocator, undefined, deadline, limits);
    errdefer destroyResponses(testing.allocator, responses);
    responses.id = try inbox.add(io, testing.allocator, .{ .many = responses }, 10);
    return responses;
}

fn expectQueued(responses: *Responses, payload: []const u8) !void {
    var m = (try responses.messages.next(testing.io, .none)) orelse return error.TestNoMessage;
    defer m.deinit();
    try testing.expectEqualStrings(payload, m.payload);
}

test "the replies of a requestMany queue up until max_responses, then they are late" {
    const io = testing.io;
    var inbox = testInbox();
    defer inbox.deinit(testing.allocator);
    const responses = try addStream(&inbox, io, soon(io), .{ .messages = 2, .bytes = 1024 });
    try testing.expectEqual(1024, inbox.accepts(io, responses.id).?);
    try testing.expectEqual(.taken, inbox.deliver(io, responses.id, try testReply("r", null, "one")));
    try testing.expectEqual(.taken, inbox.deliver(io, responses.id, try testReply("r", null, "two")));
    try testing.expect(inbox.accepts(io, responses.id) == null);
    try testing.expectEqual(.late, inbox.deliver(io, responses.id, try testReply("r", null, "three")));
    try expectQueued(responses, "one");
    try expectQueued(responses, "two");
    try testing.expect(try responses.messages.next(io, .none) == null);
    try testing.expectEqual(1, inbox.lateResponses(io));
    // Still in the map until its owner takes it out.
    inbox.forget(io, responses);
    destroyResponses(testing.allocator, responses);
}

test "after the deadline of a requestMany its replies are late" {
    const io = testing.io;
    var inbox = testInbox();
    defer inbox.deinit(testing.allocator);
    const responses = try addStream(&inbox, io, soon(io), .{ .messages = 4, .bytes = 1024 });
    defer destroyResponses(testing.allocator, responses);
    defer inbox.forget(io, responses);
    try testing.expectEqual(.taken, inbox.deliver(io, responses.id, try testReply("r", null, "in time")));
    // The deadline passes, without a race against a short real one.
    responses.deadline = time.after(io, .zero);
    try testing.expectEqual(.late, inbox.deliver(io, responses.id, try testReply("r", null, "after")));
    try expectQueued(responses, "in time");
}

test "a first reply of no responders ends a requestMany; later it is a reply like any other" {
    const io = testing.io;
    var inbox = testInbox();
    defer inbox.deinit(testing.allocator);
    const nobody = try addStream(&inbox, io, soon(io), .{ .messages = 4, .bytes = 1024 });
    _ = inbox.deliver(io, nobody.id, try testReply("r", 503, ""));
    try testing.expectError(error.NoResponders, nobody.messages.next(io, .none));
    inbox.forget(io, nobody);
    destroyResponses(testing.allocator, nobody);

    const some = try addStream(&inbox, io, soon(io), .{ .messages = 4, .bytes = 1024 });
    _ = inbox.deliver(io, some.id, try testReply("r", null, "one"));
    _ = inbox.deliver(io, some.id, try testReply("r", 503, ""));
    try expectQueued(some, "one");
    var status = (try some.messages.next(io, .none)).?;
    defer status.deinit();
    try testing.expectEqual(503, status.status.?);
    inbox.forget(io, some);
    destroyResponses(testing.allocator, some);
}

test "end: a requestMany hands out what came, then Disconnected; close drops it at once" {
    const io = testing.io;
    var inbox = testInbox();
    defer inbox.deinit(testing.allocator);
    const responses = try addStream(&inbox, io, soon(io), .{ .messages = 4, .bytes = 1024 });
    _ = inbox.deliver(io, responses.id, try testReply("r", null, "came"));
    inbox.end(io, .disconnected);
    try expectQueued(responses, "came");
    try testing.expectError(error.Disconnected, responses.messages.next(io, .none));
    inbox.end(io, .closed);
    try testing.expectError(error.ConnectionClosed, responses.messages.next(io, .none));
    // The inbox frees what its owner did not.
}

/// Takes `rounds` requests through the pending map one at a time, in and
/// out, as requests do.
fn churnRequests(inbox: *Inbox, io: Io, rounds: usize) !void {
    for (0..rounds) |_| {
        var waiter: Waiter = .{};
        const id = try inbox.add(io, testing.allocator, .{ .single = &waiter }, 1_000_000);
        inbox.drop(io, id, &waiter);
    }
}

/// The time `count` lookups of ids no request waits under take, as the
/// reader's lookups of late replies: the fastest of three tries.
fn timeMissingLookups(inbox: *Inbox, io: Io, count: u64) !i96 {
    var fastest: i96 = std.math.maxInt(i96);
    for (0..3) |_| {
        const start = Io.Clock.awake.now(io);
        for (0..count) |i| {
            if (inbox.accepts(io, std.math.maxInt(u64) - i) != null) return error.TestFound;
        }
        fastest = @min(fastest, start.durationTo(Io.Clock.awake.now(io)).nanoseconds);
    }
    return fastest;
}

test "a burst of pending requests and long churn after it leave lookups as cheap as they were [timing]" {
    try @import("anole_test_wait").requireTiming();
    const io = testing.io;
    var inbox = testInbox();
    defer inbox.deinit(testing.allocator);
    // A few stay pending all along.
    var kept: [4]Waiter = @splat(.{});
    var kept_ids: [4]u64 = undefined;
    for (&kept, &kept_ids) |*waiter, *id| id.* = try inbox.add(io, testing.allocator, .{ .single = waiter }, 1_000_000);
    defer for (&kept, kept_ids) |*waiter, id| inbox.drop(io, id, waiter);

    // A burst grows the map; then every one of them leaves.
    const burst = 10_000;
    const waiters = try testing.allocator.alloc(Waiter, burst);
    defer testing.allocator.free(waiters);
    const ids = try testing.allocator.alloc(u64, burst);
    defer testing.allocator.free(ids);
    for (waiters, ids) |*waiter, *id| {
        waiter.* = .{};
        id.* = try inbox.add(io, testing.allocator, .{ .single = waiter }, 1_000_000);
    }
    for (waiters, ids) |*waiter, id| inbox.drop(io, id, waiter);
    const after_burst = try timeMissingLookups(&inbox, io, 20_000);

    // A map that leaves a mark for each removal fills with marks under
    // churn, and then every lookup of a missing id walks all of them.
    try churnRequests(&inbox, io, 150_000);
    const after_churn = try timeMissingLookups(&inbox, io, 20_000);
    // The same work: within four times, plus 2 ms for noise.
    try testing.expect(after_churn <= after_burst * 4 + 2 * std.time.ns_per_ms);
}

test "a refusal of the inbox's subscription fails every request with PermissionDenied" {
    const io = testing.io;
    var inbox = testInbox();
    defer inbox.deinit(testing.allocator);
    inbox.sid.store(7, .release);
    // Another subscription's refusal is not the inbox's.
    try testing.expect(!inbox.deny(io, .{ .operation = .subscribe, .subject = "orders.*" }));
    try testing.expect(!inbox.deny(io, .{ .operation = .subscribe, .subject = "_INBOX.tokentokentokentoken42.*", .queue = "q" }));
    try testing.expect(!inbox.deny(io, .{ .operation = .subscribe, .subject = "x", .sid = 8 }));
    try testing.expect(!inbox.deny(io, .{ .operation = .publish, .subject = "_INBOX.tokentokentokentoken42.*" }));

    var waiting = try io.concurrent(addAndAwait, .{ &inbox, io, soon(io) });
    defer if (waiting.cancel(io)) |m| release(m) else |_| {};
    const stream = try addStream(&inbox, io, soon(io), .{ .messages = 4, .bytes = 1024 });
    try awaitAwaiting(&inbox, io, 1);
    try testing.expect(inbox.deny(io, .{ .operation = .subscribe, .subject = "_INBOX.tokentokentokentoken42.*" }));
    try expectNoReply(waiting.await(io), error.PermissionDenied);
    try testing.expectError(error.PermissionDenied, stream.messages.next(io, .none));
    var waiter: Waiter = .{};
    try testing.expectError(error.PermissionDenied, inbox.add(io, testing.allocator, .{ .single = &waiter }, 10));
    // A close afterwards is ConnectionClosed, as always.
    inbox.end(io, .closed);
    try testing.expectError(error.ConnectionClosed, inbox.add(io, testing.allocator, .{ .single = &waiter }, 10));
}

test "a refusal names the inbox by its SID too" {
    const io = testing.io;
    var inbox = testInbox();
    defer inbox.deinit(testing.allocator);
    // Not subscribed yet: nothing to refuse.
    try testing.expect(!inbox.deny(io, .{ .operation = .subscribe, .subject = "_INBOX.tokentokentokentoken42.*" }));
    inbox.sid.store(7, .release);
    try testing.expect(inbox.deny(io, .{ .operation = .subscribe, .subject = "anything", .sid = 7 }));
    var waiter: Waiter = .{};
    try testing.expectError(error.PermissionDenied, inbox.add(io, testing.allocator, .{ .single = &waiter }, 10));
}

test "a lost connection fails the waiting requests at once, and the inbox goes on" {
    const io = testing.io;
    var inbox = testInbox();
    defer inbox.deinit(testing.allocator);
    inbox.sid.store(7, .release);
    var a = try io.concurrent(addAndAwait, .{ &inbox, io, soon(io) });
    defer if (a.cancel(io)) |m| release(m) else |_| {};
    try awaitAwaiting(&inbox, io, 1);
    const responses = try addStream(&inbox, io, soon(io), .{ .messages = 4, .bytes = 1024 });
    _ = inbox.deliver(io, responses.id, try testReply("r", null, "came"));

    inbox.disconnect(io, 1);
    try expectNoReply(a.await(io), error.Disconnected);
    try expectQueued(responses, "came");
    try testing.expectError(error.Disconnected, responses.messages.next(io, .none));
    try testing.expectEqual(0, inbox.pendingCount(io));
    // A reply to a request of the lost connection is late.
    try testing.expectEqual(.late, inbox.deliver(io, responses.id, try testReply("r", null, "late")));

    // New requests wait as before, and the next connection subscribes the
    // inbox again under its SID.
    var b = try io.concurrent(addAndAwait, .{ &inbox, io, soon(io) });
    defer if (b.cancel(io)) |m| release(m) else |_| {};
    try awaitAwaiting(&inbox, io, 1);
    var subject: [prefix_len + 1]u8 = undefined;
    try testing.expectEqual(7, inbox.restoreSub(io, &subject).?);
    try testing.expectEqualStrings("_INBOX.tokentokentokentoken42.*", &subject);
    inbox.end(io, .closed);
    try expectNoReply(b.await(io), error.ConnectionClosed);
    try testing.expect(inbox.restoreSub(io, &subject) == null);
}

test "an inbox no request made has nothing to restore" {
    var inbox = testInbox();
    defer inbox.deinit(testing.allocator);
    var subject: [prefix_len + 1]u8 = undefined;
    try testing.expect(inbox.restoreSub(testing.io, &subject) == null);
}

test "a request that failed before its frame was queued says why" {
    const io = testing.io;
    var inbox = testInbox();
    defer inbox.deinit(testing.allocator);
    var waiter: Waiter = .{};
    const id = try inbox.add(io, testing.allocator, .{ .single = &waiter }, 10);
    defer inbox.drop(io, id, &waiter);
    inbox.end(io, .permission_denied);
    // Its frame is refused: the request failed meanwhile.
    try testing.expect(!admitFrame(&inbox, io, id, 0));
    try testing.expectEqual(error.PermissionDenied, inbox.failureOf(io, &waiter));
}

test "a requestMany past its deadline ends with null when the connection drops or the inbox is refused, not with an error" {
    const io = testing.io;
    for ([_]enum { lost, end_lost, refused }{ .lost, .end_lost, .refused }) |how| {
        var inbox = testInbox();
        defer inbox.deinit(testing.allocator);
        const responses = try addStream(&inbox, io, soon(io), .{ .messages = 4, .bytes = 1024 });
        defer destroyResponses(testing.allocator, responses);
        defer inbox.forget(io, responses);
        try testing.expectEqual(.taken, inbox.deliver(io, responses.id, try testReply("r", null, "came")));
        // Its owner reads later; the deadline passes first.
        responses.deadline = time.after(io, .zero);
        switch (how) {
            .lost => inbox.disconnect(io, 1),
            .end_lost => inbox.end(io, .disconnected),
            .refused => inbox.end(io, .permission_denied),
        }
        try expectQueued(responses, "came");
        try testing.expect(try responses.messages.next(io, .none) == null);
    }
}

test "after the inbox is refused, a requestMany's frame is refused too" {
    const io = testing.io;
    var inbox = testInbox();
    defer inbox.deinit(testing.allocator);
    inbox.sid.store(5, .release);
    const responses = try addStream(&inbox, io, soon(io), .{ .messages = 4, .bytes = 1024 });
    defer destroyResponses(testing.allocator, responses);
    defer inbox.forget(io, responses);
    try testing.expect(inbox.deny(io, .{ .operation = .subscribe, .subject = "x", .sid = 5 }));
    const frame_ticket = inbox.ticket(responses.id);
    try testing.expect(!frame_ticket.admit(frame_ticket.context, io, frame_ticket.id, 0));
}

test "a requestMany that ended by max_responses no longer holds a place among the pending requests" {
    const io = testing.io;
    var inbox = testInbox();
    defer inbox.deinit(testing.allocator);
    const responses = try createResponses(testing.allocator, undefined, soon(io), .{ .messages = 1, .bytes = 1024 });
    defer destroyResponses(testing.allocator, responses);
    responses.id = try inbox.add(io, testing.allocator, .{ .many = responses }, 1);
    defer inbox.forget(io, responses);
    try testing.expectEqual(.taken, inbox.deliver(io, responses.id, try testReply("r", null, "only")));
    var waiter: Waiter = .{};
    const id = try inbox.add(io, testing.allocator, .{ .single = &waiter }, 1);
    inbox.drop(io, id, &waiter);
    try expectQueued(responses, "only");
}
