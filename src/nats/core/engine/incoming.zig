// Adapted from vkiryakov/zefir src/nats/engine/incoming.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! A message as the reader receives it: the parser hands over its control
//! line, then its bytes in pieces. The control line announces every size,
//! so the message gets its one allocation at once and the pieces are
//! copied into it; nothing points into the read buffer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Message = @import("../Message.zig");
const Parser = @import("../protocol/Parser.zig");

/// A message whose bytes are still coming.
pub const Assembly = struct {
    /// Complete but for `status` and `description`, which need the headers.
    message: Message,
    /// Where the header block starts in the buffer.
    body_start: usize,
    /// Bytes of the header block and payload copied so far.
    filled: usize = 0,

    /// The bytes of the one allocation of the message `msg` announces: its
    /// subject, reply subject, headers and payload.
    pub fn size(msg: Parser.Msg) usize {
        const reply_len = if (msg.reply_to) |reply| reply.len else 0;
        return msg.subject.len +| reply_len +| msg.total_len;
    }

    /// Allocates the message the control line `msg` announces and copies
    /// its subject and reply subject.
    pub fn begin(gpa: Allocator, msg: Parser.Msg) Allocator.Error!Assembly {
        const reply_len = if (msg.reply_to) |reply| reply.len else 0;
        const body_start = msg.subject.len + reply_len;
        const buffer = try gpa.alloc(u8, size(msg));
        @memcpy(buffer[0..msg.subject.len], msg.subject);
        if (msg.reply_to) |reply| @memcpy(buffer[msg.subject.len..body_start], reply);
        const body = buffer[body_start..];
        return .{
            .message = .{
                .subject = buffer[0..msg.subject.len],
                .reply_to = if (msg.reply_to != null) buffer[msg.subject.len..body_start] else null,
                .headers = .{ .block = body[0..msg.header_len] },
                .payload = body[msg.header_len..],
                .status = null,
                .description = "",
                .buffer = buffer,
                .gpa = gpa,
            },
            .body_start = body_start,
        };
    }

    /// The next bytes of the message, as the parser hands them over: never
    /// more than it announced.
    pub fn append(a: *Assembly, bytes: []const u8) void {
        @memcpy(a.message.buffer[a.body_start + a.filled ..][0..bytes.len], bytes);
        a.filled += bytes.len;
    }

    /// The message, once the parser reports its end; it is the caller's.
    pub fn finish(a: *Assembly) Message {
        var message = a.message;
        message.status = message.headers.status();
        message.description = message.headers.description();
        a.* = undefined;
        return message;
    }

    /// Frees a message that will not be finished.
    pub fn discard(a: *Assembly) void {
        a.message.gpa.free(a.message.buffer);
        a.* = undefined;
    }
};
