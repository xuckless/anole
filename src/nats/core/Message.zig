// Adapted from vkiryakov/zefir src/nats/Message.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! A message from the server. It is the caller's: one allocation holds its
//! subject, reply subject, headers and payload, and `deinit` frees it, so
//! the slices live exactly as long as the message.
//!
//! ```zig
//! var msg = (try sub.next(.{})) orelse return;
//! defer msg.deinit();
//! std.debug.print("{s}: {s}\n", .{ msg.subject, msg.payload });
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const Headers = @import("Headers.zig");
const Message = @This();

/// The subject it was published to: for a wildcard subscription, the
/// subject that matched.
subject: []const u8,
/// Where the publisher wants a reply; null when it expects none.
reply_to: ?[]const u8,
/// The headers; `Headers.empty` when there are none.
headers: Headers,
payload: []const u8,
/// The status on the first line of the headers, such as 503 for "no
/// responders"; null when there is none.
status: ?u16,
/// The text after the status, such as "No Messages"; empty when there is
/// none.
description: []const u8,
/// The allocation behind every slice above.
buffer: []u8,
gpa: Allocator,

/// Frees the message; its slices go with it.
pub fn deinit(msg: *Message) void {
    msg.gpa.free(msg.buffer);
    msg.* = undefined;
}

/// A message to publish. Every field is borrowed for the call only: the
/// client copies what it sends.
pub const PublishMessage = struct {
    subject: []const u8,
    /// Where replies should go.
    reply_to: ?[]const u8 = null,
    /// Sent with HPUB; a server without headers support refuses them.
    headers: []const Headers.Header = &.{},
    payload: []const u8 = "",
};

/// A response to a request, for `Client.respondMessage`: it goes to the
/// request's reply subject. Every field is borrowed for the call only.
pub const ResponseMessage = struct {
    /// Where the requester may answer this response in turn.
    reply_to: ?[]const u8 = null,
    /// Sent with HPUB; a server without headers support refuses them.
    headers: []const Headers.Header = &.{},
    payload: []const u8 = "",
};

const testing = std.testing;
const Parser = @import("protocol/Parser.zig");
const golden = @import("protocol/golden.zig");
const incoming = @import("engine/incoming.zig");

/// Runs the parser over `frame`, one message, and assembles it the way the
/// reader does; the body comes `piece` bytes at a time.
fn assemble(gpa: Allocator, frame: []const u8, piece: usize) !Message {
    var parser: Parser = .init(.{});
    var assembly: ?incoming.Assembly = null;
    errdefer if (assembly) |*a| a.discard();
    var rest = frame;
    var fed: usize = @min(piece, rest.len);
    while (true) {
        const step = try parser.next(rest[0..fed]);
        rest = rest[step.consumed..];
        fed -= step.consumed;
        const got = step.frame orelse {
            if (rest.len == fed) return error.TestIncomplete;
            fed = @min(fed + piece, rest.len);
            continue;
        };
        switch (got) {
            .msg => |msg| assembly = try incoming.Assembly.begin(gpa, msg),
            .body => |bytes| if (assembly) |*a| a.append(bytes) else return error.TestNoMsg,
            .msg_end => {
                const a = if (assembly) |*a| a else return error.TestNoMsg;
                const message = a.finish();
                assembly = null;
                return message;
            },
            else => return error.TestUnexpectedFrame,
        }
    }
}

test "a message from MSG, with and without a reply subject" {
    var plain = try assemble(testing.allocator, golden.msg_plain, golden.msg_plain.len);
    defer plain.deinit();
    try testing.expectEqualStrings("foo", plain.subject);
    try testing.expect(plain.reply_to == null);
    try testing.expectEqualStrings("hello", plain.payload);
    try testing.expectEqualStrings("", plain.headers.block);
    try testing.expect(plain.status == null);
    try testing.expectEqualStrings("", plain.description);

    var reply = try assemble(testing.allocator, golden.msg_reply, golden.msg_reply.len);
    defer reply.deinit();
    try testing.expectEqualStrings("reply.to.me", reply.reply_to.?);
    try testing.expectEqualStrings("world", reply.payload);

    var empty = try assemble(testing.allocator, golden.msg_empty, golden.msg_empty.len);
    defer empty.deinit();
    try testing.expectEqualStrings("foo.bar", empty.subject);
    try testing.expectEqualStrings("", empty.payload);
}

test "a message from HMSG keeps every header, in order" {
    var multi = try assemble(testing.allocator, golden.hmsg_multi, golden.hmsg_multi.len);
    defer multi.deinit();
    try testing.expectEqualStrings("h.test", multi.subject);
    try testing.expectEqualStrings("payload!", multi.payload);
    var values = multi.headers.getAll("X-Multi");
    try testing.expectEqualStrings("one", values.next().?);
    try testing.expectEqualStrings("two", values.next().?);
    try testing.expect(values.next() == null);
    try testing.expectEqualStrings("v", multi.headers.get("X-Single").?);
    try testing.expect(multi.status == null);

    var header_only = try assemble(testing.allocator, golden.hmsg_header_only, golden.hmsg_header_only.len);
    defer header_only.deinit();
    try testing.expectEqualStrings("reply.h", header_only.reply_to.?);
    try testing.expectEqualStrings("yes", header_only.headers.get("X-Only-Header").?);
    try testing.expectEqualStrings("", header_only.payload);
}

test "the status of a no-responders message" {
    var msg = try assemble(testing.allocator, golden.hmsg_no_responders, golden.hmsg_no_responders.len);
    defer msg.deinit();
    try testing.expectEqual(503, msg.status.?);
    try testing.expectEqualStrings("", msg.description);
    try testing.expectEqualStrings("nobody.listens", msg.headers.get("Nats-Subject").?);
    try testing.expectEqualStrings("", msg.payload);

    var described = try assemble(testing.allocator, "HMSG s 1 28 30\r\nNATS/1.0 404 No Messages\r\n\r\nhi\r\n", 64);
    defer described.deinit();
    try testing.expectEqual(404, described.status.?);
    try testing.expectEqualStrings("No Messages", described.description);
    try testing.expectEqualStrings("hi", described.payload);
}

test "the body may come byte by byte" {
    for (1..8) |piece| {
        var msg = try assemble(testing.allocator, golden.hmsg_multi, piece);
        defer msg.deinit();
        try testing.expectEqualStrings("payload!", msg.payload);
        try testing.expectEqualStrings("one", msg.headers.get("X-Multi").?);
    }
}

/// Counts the allocations it passes on.
const Counting = struct {
    parent: Allocator,
    allocations: usize = 0,

    fn allocator(c: *Counting) Allocator {
        return .{ .ptr = c, .vtable = &.{ .alloc = alloc, .resize = Allocator.noResize, .remap = Allocator.noRemap, .free = free } };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(context));
        c.allocations += 1;
        return c.parent.rawAlloc(len, alignment, ret_addr);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const c: *Counting = @ptrCast(@alignCast(context));
        c.parent.rawFree(memory, alignment, ret_addr);
    }
};

test "a message is one allocation, and deinit frees it" {
    var counting: Counting = .{ .parent = testing.allocator };
    var msg = try assemble(counting.allocator(), golden.hmsg_header_only, 5);
    try testing.expectEqual(1, counting.allocations);
    try testing.expectEqual("h.test".len + "reply.h".len + 32, msg.buffer.len);
    msg.deinit();
}

test "a message left unfinished is discarded without a leak" {
    var parser: Parser = .init(.{});
    const step = try parser.next(golden.msg_plain);
    var assembly = try incoming.Assembly.begin(testing.allocator, step.frame.?.msg);
    assembly.append("he");
    assembly.discard();
}

test "PublishMessage has nothing but a subject to give" {
    const message: PublishMessage = .{ .subject = "orders.new" };
    try testing.expect(message.reply_to == null);
    try testing.expectEqual(0, message.headers.len);
    try testing.expectEqualStrings("", message.payload);
}
