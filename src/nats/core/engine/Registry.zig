// Adapted from vkiryakov/zefir src/nats/engine/Registry.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! The client's subscriptions by SID: the reader routes each message
//! through it. `subscribe` registers a subscription, its `deinit` takes it
//! away, and the client's `deinit` frees whatever is left.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Client = @import("../Client.zig");
const Subscription = @import("../Subscription.zig");
const Message = @import("../Message.zig");
const MessageQueue = @import("MessageQueue.zig");
const Outbound = @import("Outbound.zig");
const encoder = @import("../protocol/encoder.zig");
const server_error = @import("../protocol/server_error.zig");
const log = std.log.scoped(.nats);
const Registry = @This();

/// Guards everything below.
mutex: Io.Mutex = .init,
/// An array hash map: a removal leaves no mark behind, so lookups stay as
/// cheap after many subscriptions came and went as before.
subscriptions: std.AutoArrayHashMapUnmanaged(u64, *Subscription) = .empty,
/// The SID of the next subscription. SIDs are never reused, so a message
/// late for an old subscription cannot reach a new one.
next_sid: u64 = 1,
/// The client closed: no new subscriptions.
closed: bool = false,
/// The client drains: no new subscriptions either.
draining: bool = false,
/// The longest arguments of a SUB line the server takes
/// (`limits.max_control_line_bytes`).
max_line: u32 = std.math.maxInt(u32),

pub const RegisterError = error{ TooManySubscriptions, ConnectionClosed, ConnectionDraining, OutOfMemory, InvalidSubject };

/// Gives `sub` the next SID and routes messages for it to it. At most
/// `max` subscriptions are registered at once. A subscription whose SUB
/// line would be longer than `max_line` is InvalidSubject and never
/// registered, so no reconnect sends it either.
pub fn register(r: *Registry, io: Io, gpa: Allocator, sub: *Subscription, max: u32) RegisterError!void {
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    if (r.closed) return error.ConnectionClosed;
    if (r.draining) return error.ConnectionDraining;
    if (r.subscriptions.count() >= max) return error.TooManySubscriptions;
    if (encoder.subArgsLen(sub.subject, sub.queue_group, r.next_sid) > r.max_line) return error.InvalidSubject;
    try r.subscriptions.ensureUnusedCapacity(gpa, 1);
    sub.sid = r.next_sid;
    r.next_sid += 1;
    r.subscriptions.putAssumeCapacityNoClobber(sub.sid, sub);
}

/// A SID for a subscription the registry does not route, such as the inbox
/// of requests. Every SID comes from one counter, so none is used twice.
pub fn reserveSid(r: *Registry, io: Io) error{ConnectionClosed}!u64 {
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    if (r.closed) return error.ConnectionClosed;
    const sid = r.next_sid;
    r.next_sid += 1;
    return sid;
}

/// How many subscriptions are registered; tests use it.
pub fn count(r: *Registry, io: Io) usize {
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    return r.subscriptions.count();
}

/// Stops routing to `sid`; nothing happens if it is not registered.
pub fn unregister(r: *Registry, io: Io, sid: u64) void {
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    _ = r.subscriptions.swapRemove(sid);
}

/// How many bytes subscription `sid` holds, when it exists and takes
/// messages; null otherwise. The reader allocates a message only for such
/// a subscription, and only one that fits in it.
pub fn accepts(r: *Registry, io: Io, sid: u64) ?usize {
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    const sub = r.subscriptions.get(sid) orelse return null;
    if (!sub.messages.isOpen(io)) return null;
    return sub.messages.limits.bytes;
}

/// Hands `message` to subscription `sid`, or tells it that a message came
/// that could not be kept (null). Null when there is no such subscription
/// any more: the message is freed.
pub fn deliver(r: *Registry, io: Io, sid: u64, message: ?Message) ?MessageQueue.Pushed {
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    const sub = r.subscriptions.get(sid) orelse {
        if (message) |m| {
            var dropped = m;
            dropped.deinit();
        }
        return null;
    };
    return sub.messages.push(io, message);
}

/// The server refused a subscription: the one it names ends with
/// `.permission_denied`, and its SID comes back; null when none matches.
/// A text without a SID names a subject and a queue group, and then it is
/// the oldest open subscription with both: the server answers SUBs in
/// order.
pub fn deny(r: *Registry, io: Io, permission: server_error.Permission) ?u64 {
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    var chosen: ?*Subscription = null;
    if (permission.sid) |sid| {
        chosen = r.subscriptions.get(sid);
    } else {
        for (r.subscriptions.values()) |sub| {
            if (chosen) |earlier| if (earlier.sid < sub.sid) continue;
            if (!server_error.quotedEql(permission.subject, sub.subject)) continue;
            if (!sameQueue(permission.queue, sub.queue_group)) continue;
            if (!sub.messages.isOpen(io)) continue;
            chosen = sub;
        }
    }
    const sub = chosen orelse return null;
    if (!sub.messages.end(io, .permission_denied, false)) return null;
    return sub.sid;
}

/// The queue group the server quoted, if any, is `queue`.
fn sameQueue(quoted: ?[]const u8, queue: ?[]const u8) bool {
    const q = quoted orelse return queue == null;
    return queue != null and server_error.quotedEql(q, queue.?);
}

/// The client closed: every subscription ends with `.closed`, and no new
/// one registers.
pub fn closeAll(r: *Registry, io: Io) void {
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    r.closed = true;
    for (r.subscriptions.values()) |sub| _ = sub.messages.end(io, .closed, true);
}

/// A subscription the registry does not route, to subscribe again.
pub const Resubscribe = struct { subject: []const u8, sid: u64 };

/// Writes what subscribes a new connection to what the subscriptions had:
/// the SUB of every subscription that still takes messages, with its own
/// SID, then `extra` (the inbox of requests), then `UNSUB sid n` for each
/// one that ends after `max_messages`, n being the messages it still
/// takes: the server counts afresh on a new connection.
pub fn writeRestore(r: *Registry, io: Io, w: *Io.Writer, extra: ?Resubscribe) Io.Writer.Error!void {
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    for (r.subscriptions.values()) |sub| {
        if (sub.messages.resumeState(io) == null) continue;
        try encoder.writeSub(w, sub.subject, sub.queue_group, sub.sid);
    }
    if (extra) |e| try encoder.writeSub(w, e.subject, null, e.sid);
    for (r.subscriptions.values()) |sub| {
        const state = sub.messages.resumeState(io) orelse continue;
        if (state.remaining) |n| try encoder.writeUnsub(w, sub.sid, n);
    }
}

/// The client drains: every subscription that has not ended stops being
/// subscribed again on a new connection, and its UNSUB is queued, also for
/// one whose own `drain()` sent one already: the client's PING barrier
/// then follows an UNSUB of every subscription `finishDraining` ends. The
/// UNSUBs are queued outside the registry's mutex, a batch at a time, so
/// the outbound queue's mutex is never taken under it.
pub fn drainAll(r: *Registry, io: Io, outbound: *Outbound) void {
    {
        // From now on no subscription registers: each one registered
        // before is drained here.
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        r.draining = true;
    }
    // Each batch resumes where the last one stopped. A subscription freed
    // meanwhile moves the last one into its place, which may lie behind;
    // so passes start over from the first until one, under a single lock,
    // finds nothing left.
    var index: usize = 0;
    var from_first = false;
    var found = false;
    while (true) {
        var batch: [64]u64 = undefined;
        var taken: usize = 0;
        {
            r.mutex.lockUncancelable(io);
            defer r.mutex.unlock(io);
            const values = r.subscriptions.values();
            if (index >= values.len) {
                if (from_first and !found) return;
                index = 0;
                from_first = true;
                found = false;
            }
            while (index < values.len and taken < batch.len) : (index += 1) {
                if (!values[index].messages.drainForClient(io)) continue;
                batch[taken] = values[index].sid;
                taken += 1;
                found = true;
            }
        }
        for (batch[0..taken]) |sid| queueUnsub(outbound, io, sid) catch |err| {
            log.debug("no UNSUB for subscription {d}: {t}", .{ sid, err });
        };
    }
}

/// The server has the UNSUBs of the drain: the draining subscriptions end,
/// and what they hold still comes out.
pub fn finishDraining(r: *Registry, io: Io) void {
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    for (r.subscriptions.values()) |sub| sub.messages.finishDrain(io);
}

/// Subscriptions that take messages now.
pub fn openCount(r: *Registry, io: Io) usize {
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    var open: usize = 0;
    for (r.subscriptions.values()) |sub| {
        if (sub.messages.isOpen(io)) open += 1;
    }
    return open;
}

/// The bytes of the messages waiting to be taken, over every subscription.
pub fn pendingBytes(r: *Registry, io: Io) usize {
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    var total: usize = 0;
    for (r.subscriptions.values()) |sub| total += sub.messages.pending(io).bytes;
    return total;
}

/// Every subscription is settled: its messages were taken, and the last
/// one is no longer worked on. A drain polls it: it looks from `cursor`,
/// where the last call found one that was not settled, and checks the
/// ones before only once it reaches the end, so a poll costs little while
/// the drain waits for one subscription.
pub fn allSettled(r: *Registry, io: Io, cursor: *usize) bool {
    r.mutex.lockUncancelable(io);
    defer r.mutex.unlock(io);
    const values = r.subscriptions.values();
    const from = @min(cursor.*, values.len);
    for (values[from..], from..) |sub, index| {
        if (sub.messages.settled(io)) continue;
        cursor.* = index;
        return false;
    }
    for (values[0..from], 0..) |sub, index| {
        if (sub.messages.settled(io)) continue;
        cursor.* = index;
        return false;
    }
    return true;
}

/// Frees every subscription still registered: the client goes away.
pub fn deinit(r: *Registry, gpa: Allocator) void {
    for (r.subscriptions.values()) |sub| destroy(gpa, sub);
    r.subscriptions.deinit(gpa);
    r.* = undefined;
}

/// A subscription of `client` to `subject`, with its own copies of the
/// subject and the queue group; it gets its SID when registered.
pub fn create(gpa: Allocator, client: *Client, subject: []const u8, options: Subscription.Options, limits: MessageQueue.Limits) Allocator.Error!*Subscription {
    const sub = try gpa.create(Subscription);
    errdefer gpa.destroy(sub);
    const subject_copy = try gpa.dupe(u8, subject);
    errdefer gpa.free(subject_copy);
    const queue_copy = if (options.queue) |queue| try gpa.dupe(u8, queue) else null;
    sub.* = .{
        .client = client,
        .sid = 0,
        .subject = subject_copy,
        .queue_group = queue_copy,
        .messages = .init(gpa, limits, options.overflow, options.max_messages),
    };
    return sub;
}

/// Frees `sub` and the messages it holds; it must not be registered.
pub fn destroy(gpa: Allocator, sub: *Subscription) void {
    sub.messages.deinit();
    if (sub.queue_group) |queue| gpa.free(queue);
    gpa.free(sub.subject);
    gpa.destroy(sub);
}

/// The ticket of `sub`'s SUB: it goes in only while the subscription is
/// open and not draining, so it never follows the UNSUB of a drain that
/// began meanwhile.
pub fn subscribeTicket(sub: *Subscription) Outbound.Ticket {
    return .{ .id = 0, .context = &sub.messages, .admit = admitSubscribe };
}

fn admitSubscribe(context: *anyopaque, io: Io, _: u64, _: u64) bool {
    const queue: *MessageQueue = @ptrCast(@alignCast(context));
    return queue.takesSubscribe(io);
}

/// Queues `UNSUB sid` at once: no wait for room, so the reader and
/// `deinit` can use it. A subscription sends it at most once, which keeps
/// what goes over the outbound limit bounded.
pub fn queueUnsub(outbound: *Outbound, io: Io, sid: u64) Outbound.PutNowError!void {
    return outbound.putNow(io, .service, encoder.unsubLen(sid, null), encoder.writeUnsub, .{ sid, null });
}

const testing = std.testing;

fn newSubscription(gpa: Allocator, subject: []const u8) !*Subscription {
    // The registry never looks at the client.
    return create(gpa, undefined, subject, .{}, .{ .messages = 4, .bytes = 1024 });
}

test "SIDs start at 1, grow, and are never reused" {
    const io = testing.io;
    var r: Registry = .{};
    defer r.deinit(testing.allocator);
    const a = try newSubscription(testing.allocator, "a");
    try r.register(io, testing.allocator, a, 10);
    try testing.expectEqual(1, a.sid);
    const b = try newSubscription(testing.allocator, "b");
    try r.register(io, testing.allocator, b, 10);
    try testing.expectEqual(2, b.sid);
    r.unregister(io, a.sid);
    destroy(testing.allocator, a);
    const c = try newSubscription(testing.allocator, "c");
    try r.register(io, testing.allocator, c, 10);
    try testing.expectEqual(3, c.sid);
}

test "a reserved SID is never given to a subscription, and none is reserved once closed" {
    const io = testing.io;
    var r: Registry = .{};
    defer r.deinit(testing.allocator);
    const a = try newSubscription(testing.allocator, "a");
    try r.register(io, testing.allocator, a, 10);
    try testing.expectEqual(2, try r.reserveSid(io));
    const b = try newSubscription(testing.allocator, "b");
    try r.register(io, testing.allocator, b, 10);
    try testing.expectEqual(3, b.sid);
    // A reserved SID routes nothing.
    try testing.expect(r.accepts(io, 2) == null);
    r.closeAll(io);
    try testing.expectError(error.ConnectionClosed, r.reserveSid(io));
}

test "no more than the limit at once, and none once closed" {
    const io = testing.io;
    var r: Registry = .{};
    defer r.deinit(testing.allocator);
    const a = try newSubscription(testing.allocator, "a");
    try r.register(io, testing.allocator, a, 1);
    const b = try newSubscription(testing.allocator, "b");
    try testing.expectError(error.TooManySubscriptions, r.register(io, testing.allocator, b, 1));
    r.unregister(io, a.sid);
    destroy(testing.allocator, a);
    try r.register(io, testing.allocator, b, 1);

    r.closeAll(io);
    try testing.expectEqual(.closed, b.messages.endedHow(io).?);
    const c = try newSubscription(testing.allocator, "c");
    defer destroy(testing.allocator, c);
    try testing.expectError(error.ConnectionClosed, r.register(io, testing.allocator, c, 10));
}

test "unregistering an unknown SID changes nothing" {
    const io = testing.io;
    var r: Registry = .{};
    defer r.deinit(testing.allocator);
    r.unregister(io, 42);
    const a = try newSubscription(testing.allocator, "a");
    try r.register(io, testing.allocator, a, 10);
    r.unregister(io, 42);
    try testing.expectEqual(1, r.subscriptions.count());
}

fn createAndDestroy(gpa: Allocator) !void {
    const sub = try create(gpa, undefined, "orders.*", .{ .queue = "workers" }, .{ .messages = 4, .bytes = 1024 });
    destroy(gpa, sub);
}

test "nothing leaks when an allocation fails" {
    try testing.checkAllAllocationFailures(@import("../../../testing/no_resize.zig").allocator, createAndDestroy, .{});
}

test "deny ends the oldest open subscription with the subject and queue the server names" {
    const io = testing.io;
    var r: Registry = .{};
    defer r.deinit(testing.allocator);
    const limits: MessageQueue.Limits = .{ .messages = 4, .bytes = 1024 };
    var subs: [4]*Subscription = undefined;
    for (&subs, [_][]const u8{ "forbidden", "forbidden", "forbidden", "x.q\"uo\\te.ü" }, [_]?[]const u8{ null, null, "g", null }) |*sub, subject, queue| {
        sub.* = try create(testing.allocator, undefined, subject, .{ .queue = queue }, limits);
        try r.register(io, testing.allocator, sub.*, 10);
    }
    const forbidden: server_error.Permission = .{ .operation = .subscribe, .subject = "forbidden" };
    try testing.expectEqual(1, r.deny(io, forbidden).?);
    try testing.expectEqual(.permission_denied, subs[0].messages.endedHow(io).?);
    try testing.expectEqual(2, r.deny(io, forbidden).?);
    // The one in a queue group is not named by a text without the group.
    try testing.expect(r.deny(io, forbidden) == null);
    try testing.expectEqual(3, r.deny(io, .{ .operation = .subscribe, .subject = "forbidden", .queue = "g" }).?);
    // The server escapes the subject; the match does not mind.
    try testing.expectEqual(4, r.deny(io, .{ .operation = .subscribe, .subject = "x.q\\\"uo\\\\te.ü" }).?);
}

test "deny takes the SID when the server names it" {
    const io = testing.io;
    var r: Registry = .{};
    defer r.deinit(testing.allocator);
    const a = try newSubscription(testing.allocator, "dup");
    try r.register(io, testing.allocator, a, 10);
    const b = try newSubscription(testing.allocator, "dup");
    try r.register(io, testing.allocator, b, 10);
    try testing.expectEqual(2, r.deny(io, .{ .operation = .subscribe, .subject = "dup", .sid = 2 }).?);
    try testing.expect(a.messages.isOpen(io));
    try testing.expect(!b.messages.isOpen(io));
    try testing.expect(r.deny(io, .{ .operation = .subscribe, .subject = "dup", .sid = 99 }) == null);
}

/// The time `lookups` lookups of SIDs no subscription has take, as the
/// reader's lookups of messages for subscriptions that ended: the fastest
/// of three tries.
fn timeMissingLookups(r: *Registry, io: Io, lookups: u64) !i96 {
    var fastest: i96 = std.math.maxInt(i96);
    for (0..3) |_| {
        const start = Io.Clock.awake.now(io);
        for (0..lookups) |i| {
            if (r.accepts(io, std.math.maxInt(u64) - i) != null) return error.TestFound;
        }
        fastest = @min(fastest, start.durationTo(Io.Clock.awake.now(io)).nanoseconds);
    }
    return fastest;
}

test "a burst of subscriptions and long churn after it leave lookups as cheap as they were [timing]" {
    try @import("anole_test_wait").requireTiming();
    const io = testing.io;
    var r: Registry = .{};
    defer r.deinit(testing.allocator);
    // One object, registered again and again: the registry routes by SID.
    const sub = try newSubscription(testing.allocator, "s");
    defer destroy(testing.allocator, sub);
    // A few stay all along: lookups in an empty map end at once.
    var kept: [4]u64 = undefined;
    for (&kept) |*sid| {
        try r.register(io, testing.allocator, sub, 1_000_000);
        sid.* = sub.sid;
    }
    defer for (kept) |sid| r.unregister(io, sid);
    const burst = 10_000;
    const sids = try testing.allocator.alloc(u64, burst);
    defer testing.allocator.free(sids);
    for (sids) |*sid| {
        try r.register(io, testing.allocator, sub, 1_000_000);
        sid.* = sub.sid;
    }
    for (sids) |sid| r.unregister(io, sid);
    const after_burst = try timeMissingLookups(&r, io, 20_000);

    // A map that leaves a mark for each removal fills with marks under
    // churn, and then every lookup of a missing SID walks all of them.
    for (0..150_000) |_| {
        try r.register(io, testing.allocator, sub, 1_000_000);
        r.unregister(io, sub.sid);
    }
    const after_churn = try timeMissingLookups(&r, io, 20_000);
    // The same work: within four times, plus 2 ms for noise.
    try testing.expect(after_churn <= after_burst * 4 + 2 * std.time.ns_per_ms);
}

test "a new connection subscribes again what still takes messages, with the same SIDs and what max_messages leaves" {
    const io = testing.io;
    const gpa = testing.allocator;
    var r: Registry = .{};
    defer r.deinit(gpa);
    const a = try newSubscription(gpa, "a");
    try r.register(io, gpa, a, 10);
    const b = try create(gpa, undefined, "b.*", .{ .queue = "g", .max_messages = 5 }, .{ .messages = 8, .bytes = 1024 });
    try r.register(io, gpa, b, 10);
    const c = try newSubscription(gpa, "c");
    try r.register(io, gpa, c, 10);
    // Two of b's five came, one of them dropped; c ended.
    _ = r.deliver(io, b.sid, null);
    _ = b.messages.push(io, null);
    _ = c.messages.end(io, .finished, true);

    var w: Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try r.writeRestore(io, &w.writer, .{ .subject = "_INBOX.t.*", .sid = 9 });
    try testing.expectEqualStrings("SUB a 1\r\nSUB b.* g 2\r\nSUB _INBOX.t.* 9\r\nUNSUB 2 3\r\n", w.written());

    // Nothing to subscribe: nothing written.
    var empty: Registry = .{};
    defer empty.deinit(gpa);
    var none: Io.Writer.Allocating = .init(gpa);
    defer none.deinit();
    try empty.writeRestore(io, &none.writer, null);
    try testing.expectEqual(0, none.written().len);
}

test "a subscription whose SUB line is too long is never registered" {
    const io = testing.io;
    var r: Registry = .{ .max_line = 12 };
    defer r.deinit(testing.allocator);
    // "abcdefghi 1" is 11 bytes, "abcdefghijk 1" 13.
    const fits = try newSubscription(testing.allocator, "abcdefghi");
    try r.register(io, testing.allocator, fits, 10);
    const long = try newSubscription(testing.allocator, "abcdefghijk");
    defer destroy(testing.allocator, long);
    try testing.expectError(error.InvalidSubject, r.register(io, testing.allocator, long, 10));
    try testing.expectEqual(1, r.count(io));
}

fn writeSubFrame(w: *Io.Writer, subject: []const u8, sid: u64) Io.Writer.Error!void {
    return encoder.writeSub(w, subject, null, sid);
}

test "a drain takes every subscription registered before it, whose SUB then never follows its UNSUB, and refuses new ones" {
    const io = testing.io;
    const gpa = testing.allocator;
    var r: Registry = .{};
    defer r.deinit(gpa);
    var outbound: Outbound = .init(gpa, 1 << 20);
    defer outbound.deinit();
    // Registered, its SUB not queued yet: the drain comes first.
    const late = try newSubscription(gpa, "late");
    try r.register(io, gpa, late, 10);
    r.drainAll(io, &outbound);
    try testing.expectError(error.Disconnected, outbound.putTicket(io, null, .service, subscribeTicket(late), encoder.subLen("late", null, late.sid), writeSubFrame, .{ "late", late.sid }));
    var frames: [4]Outbound.Frame = undefined;
    const queued = outbound.unsent(io, &frames);
    try testing.expectEqual(1, queued.len);
    try testing.expectEqual(encoder.unsubLen(late.sid, null), queued[0].len);
    const after = try newSubscription(gpa, "after");
    defer destroy(gpa, after);
    try testing.expectError(error.ConnectionDraining, r.register(io, gpa, after, 10));
}

test "a drain queues one UNSUB for each subscription, however many, and polls for settled ones from where it stopped" {
    const io = testing.io;
    const gpa = testing.allocator;
    var r: Registry = .{};
    defer r.deinit(gpa);
    var outbound: Outbound = .init(gpa, 1 << 20);
    defer outbound.deinit();
    var subs: [200]*Subscription = undefined;
    for (&subs) |*sub| {
        sub.* = try newSubscription(gpa, "s");
        try r.register(io, gpa, sub.*, 1000);
    }
    r.drainAll(io, &outbound);
    r.drainAll(io, &outbound);
    var frames: [256]Outbound.Frame = undefined;
    try testing.expectEqual(subs.len, outbound.unsent(io, &frames).len);
    // Two hold messages when the server confirms the UNSUBs.
    _ = subs[20].messages.push(io, try testMessage(gpa));
    _ = subs[150].messages.push(io, try testMessage(gpa));
    r.finishDraining(io);

    // The last poll stopped at 100: this one goes on from there.
    var cursor: usize = 100;
    try testing.expect(!r.allSettled(io, &cursor));
    try testing.expectEqual(150, cursor);
    try testing.expect(!r.allSettled(io, &cursor));
    try testing.expectEqual(150, cursor);
    subs[150].messages.dropAll(io);
    // Past the end, the ones before are looked at again.
    try testing.expect(!r.allSettled(io, &cursor));
    try testing.expectEqual(20, cursor);
    subs[20].messages.dropAll(io);
    try testing.expect(r.allSettled(io, &cursor));
}

fn testMessage(gpa: Allocator) !Message {
    const buffer = try gpa.alloc(u8, 2);
    @memcpy(buffer, "sx");
    return .{ .subject = buffer[0..1], .reply_to = null, .headers = .empty, .payload = buffer[1..], .status = null, .description = "", .buffer = buffer, .gpa = gpa };
}
