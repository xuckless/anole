//! The wire protocol: OP_MSG (specifications: message/OP_MSG.md), the
//! only opcode the client sends or takes. A message is a 16-byte header,
//! flag bits, a kind-0 section (the command document) and any number of
//! kind-1 sections (document sequences: `documents` of an insert,
//! `updates`, `deletes`), with an optional CRC-32C checksum at the end.
//!
//! Messages are built in place in a `bson.Builder`'s buffer, so a command
//! and its documents are encoded once, straight into what is sent.
const std = @import("std");
const bson = @import("bson");

pub const op_msg: i32 = 2013;
pub const op_compressed: i32 = 2012;
pub const header_len = 16;

/// The flag bits the client reads or sets.
pub const flag_checksum_present: u32 = 1 << 0;
pub const flag_more_to_come: u32 = 1 << 1;
pub const flag_exhaust_allowed: u32 = 1 << 16;
/// Bits 0-15 are required: an unknown one set means a message we cannot read.
const required_mask: u32 = 0xffff;

pub const Header = struct {
    length: u32,
    request_id: i32,
    response_to: i32,
    op_code: i32,

    pub fn parse(bytes: *const [header_len]u8) Header {
        return .{
            .length = @bitCast(std.mem.readInt(i32, bytes[0..4], .little)),
            .request_id = std.mem.readInt(i32, bytes[4..8], .little),
            .response_to = std.mem.readInt(i32, bytes[8..12], .little),
            .op_code = std.mem.readInt(i32, bytes[12..16], .little),
        };
    }
};

pub const Error = bson.Builder.Error || error{ MessageTooLarge, InvalidMessage, ChecksumMismatch, UnexpectedOpCode };

/// An OP_MSG being written into `b` (which it empties first): the body
/// document is open after `begin`, for the caller's fields.
///
///     var m = try Message.begin(&b);
///     try b.append("ping", .{ .int32 = 1 });
///     try b.append("$db", .{ .string = "admin" });
///     try m.endBody();
///     const bytes = m.finish(request_id);
pub const Message = struct {
    b: *bson.Builder,
    /// Where the open document sequence's size goes.
    sequence_at: ?usize = null,

    pub fn begin(b: *bson.Builder) Error!Message {
        b.reset();
        // Header and flag bits, filled by `finish`; then section kind 0.
        try b.buf.appendNTimes(b.gpa, 0, header_len + 4);
        try b.buf.append(b.gpa, 0);
        try b.begin();
        return .{ .b = b };
    }

    pub fn endBody(m: *Message) Error!void {
        try m.b.end();
    }

    /// Opens a kind-1 section named `identifier` ("documents").
    pub fn beginSequence(m: *Message, identifier: []const u8) Error!void {
        std.debug.assert(m.sequence_at == null);
        const b = m.b;
        try b.buf.append(b.gpa, 1);
        m.sequence_at = b.buf.items.len;
        try b.buf.appendNTimes(b.gpa, 0, 4);
        try b.buf.appendSlice(b.gpa, identifier);
        try b.buf.append(b.gpa, 0);
    }

    /// One document of the open sequence, from a Zig value (a struct, an
    /// anonymous literal, a `bson.Document`). Returns its encoded bytes.
    pub fn sequenceDocument(m: *Message, doc: anytype) (Error || bson.EncodeError)![]const u8 {
        const b = m.b;
        const start = b.buf.items.len;
        try b.begin();
        try bson.appendFields(b, doc, .{});
        try b.end();
        return b.buf.items[start..];
    }

    pub fn endSequence(m: *Message) Error!void {
        const at = m.sequence_at.?;
        const b = m.b;
        const size = b.buf.items.len - at;
        if (size > std.math.maxInt(i32)) return error.MessageTooLarge;
        std.mem.writeInt(i32, b.buf.items[at..][0..4], @intCast(size), .little);
        m.sequence_at = null;
    }

    /// Writes the header (and `flags`) and returns the whole message.
    pub fn finishFlags(m: *Message, request_id: i32, flags: u32) Error![]const u8 {
        std.debug.assert(m.sequence_at == null);
        const bytes = m.b.buf.items;
        if (bytes.len > std.math.maxInt(i32)) return error.MessageTooLarge;
        std.mem.writeInt(i32, bytes[0..4], @intCast(bytes.len), .little);
        std.mem.writeInt(i32, bytes[4..8], request_id, .little);
        std.mem.writeInt(i32, bytes[8..12], 0, .little);
        std.mem.writeInt(i32, bytes[12..16], op_msg, .little);
        std.mem.writeInt(u32, bytes[16..20], flags, .little);
        return bytes;
    }

    pub fn finish(m: *Message, request_id: i32) Error![]const u8 {
        return m.finishFlags(request_id, 0);
    }

    /// The body document written so far (after `endBody`).
    pub fn body(m: *const Message) bson.Document {
        const bytes = m.b.buf.items[header_len + 5 ..];
        const len: usize = @intCast(std.mem.readInt(i32, bytes[0..4], .little));
        return .{ .bytes = bytes[0..len] };
    }
};

/// A message read off the wire, its documents validated and pointing into
/// the bytes it was parsed from.
pub const Reply = struct {
    header: Header,
    flags: u32,
    body: bson.Document,
    /// Kind-1 sections, which servers send only with exhaust cursors;
    /// kept for the tests' fake server, which reads what clients send.
    sequences: []const u8 = &.{},

    pub fn moreToCome(r: Reply) bool {
        return r.flags & flag_more_to_come != 0;
    }

    /// The documents of the kind-1 section `identifier`.
    pub fn sequence(r: Reply, identifier: []const u8) SequenceIterator {
        var rest = r.sequences;
        while (rest.len > 5) {
            const size: usize = @intCast(std.mem.readInt(i32, rest[1..5], .little));
            const section = rest[1 .. 1 + size];
            const name_end = std.mem.indexOfScalarPos(u8, section, 4, 0).?;
            if (std.mem.eql(u8, section[4..name_end], identifier)) return .{ .rest = section[name_end + 1 ..] };
            rest = rest[1 + size ..];
        }
        return .{ .rest = &.{} };
    }
};

pub const SequenceIterator = struct {
    rest: []const u8,

    pub fn next(it: *SequenceIterator) ?bson.Document {
        if (it.rest.len == 0) return null;
        const doc = bson.Document.fromPrefix(it.rest) catch unreachable;
        it.rest = it.rest[doc.bytes.len..];
        return doc;
    }
};

/// Parses a whole OP_MSG (`bytes` from its header on). Checks the
/// checksum when there is one, every section's lengths, and every
/// document.
pub fn parse(bytes: []const u8) (Error || bson.DecodeError)!Reply {
    if (bytes.len < header_len + 5) return error.InvalidMessage;
    const header = Header.parse(bytes[0..header_len]);
    if (header.length != bytes.len) return error.InvalidMessage;
    if (header.op_code != op_msg) return error.UnexpectedOpCode;
    const flags = std.mem.readInt(u32, bytes[16..20], .little);
    if (flags & required_mask & ~(flag_checksum_present | flag_more_to_come) != 0) return error.InvalidMessage;
    var end = bytes.len;
    if (flags & flag_checksum_present != 0) {
        if (end < header_len + 9) return error.InvalidMessage;
        end -= 4;
        const want = std.mem.readInt(u32, bytes[end..][0..4], .little);
        if (std.hash.crc.@"CRC-32/ISCSI".hash(bytes[0..end]) != want) return error.ChecksumMismatch;
    }
    var body: ?bson.Document = null;
    var pos: usize = header_len + 4;
    const sequences_start = blk: {
        // Kind 0 comes first in what servers send; accept it anywhere.
        var seq_start: ?usize = null;
        while (pos < end) {
            const kind = bytes[pos];
            pos += 1;
            switch (kind) {
                0 => {
                    if (body != null) return error.InvalidMessage;
                    const doc = try bson.Document.fromPrefix(bytes[pos..end]);
                    body = doc;
                    pos += doc.bytes.len;
                },
                1 => {
                    if (seq_start == null) seq_start = pos - 1;
                    if (end - pos < 4) return error.InvalidMessage;
                    const size = std.mem.readInt(i32, bytes[pos..][0..4], .little);
                    if (size < 5 or size > end - pos) return error.InvalidMessage;
                    const section = bytes[pos..][0..@intCast(size)];
                    const name_end = std.mem.indexOfScalarPos(u8, section, 4, 0) orelse return error.InvalidMessage;
                    var docs = section[name_end + 1 ..];
                    while (docs.len > 0) {
                        const doc = try bson.Document.fromPrefix(docs);
                        docs = docs[doc.bytes.len..];
                    }
                    pos += section.len;
                },
                else => return error.InvalidMessage,
            }
        }
        break :blk seq_start;
    };
    return .{
        .header = header,
        .flags = flags,
        .body = body orelse return error.InvalidMessage,
        .sequences = if (sequences_start) |s| bytes[s..end] else &.{},
    };
}

/// Reads one message from `reader` into `buf` (grown up to `max_len`
/// bytes) and returns it, header included.
pub fn read(reader: *std.Io.Reader, gpa: std.mem.Allocator, buf: *std.ArrayList(u8), max_len: usize) ![]const u8 {
    var head: [header_len]u8 = undefined;
    try reader.readSliceAll(&head);
    const header = Header.parse(&head);
    if (header.length < header_len + 5) return error.InvalidMessage;
    if (header.length > max_len) return error.MessageTooLarge;
    buf.clearRetainingCapacity();
    try buf.ensureTotalCapacity(gpa, header.length);
    buf.appendSliceAssumeCapacity(&head);
    const rest = buf.unusedCapacitySlice()[0 .. header.length - header_len];
    try reader.readSliceAll(rest);
    buf.items.len = header.length;
    return buf.items;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "Message: a body and a document sequence, parsed back" {
    var b: bson.Builder = .init(testing.allocator);
    defer b.deinit();
    var m = try Message.begin(&b);
    try b.append("insert", .{ .string = "users" });
    try b.append("$db", .{ .string = "app" });
    try m.endBody();
    try m.beginSequence("documents");
    _ = try m.sequenceDocument(.{ .name = "Ada" });
    _ = try m.sequenceDocument(.{ .name = "Grace", .age = 85 });
    try m.endSequence();
    try testing.expectEqualStrings("users", m.body().get("insert").?.string);
    const bytes = try m.finish(42);

    const reply = try parse(bytes);
    try testing.expectEqual(@as(i32, 42), reply.header.request_id);
    try testing.expectEqual(@as(u32, @intCast(bytes.len)), reply.header.length);
    try testing.expectEqualStrings("app", reply.body.get("$db").?.string);
    var docs = reply.sequence("documents");
    try testing.expectEqualStrings("Ada", docs.next().?.get("name").?.string);
    try testing.expectEqual(@as(i32, 85), docs.next().?.get("age").?.int32);
    try testing.expect(docs.next() == null);
    var none = reply.sequence("updates");
    try testing.expect(none.next() == null);
}

test "parse: checksums, flags and lengths" {
    var b: bson.Builder = .init(testing.allocator);
    defer b.deinit();
    var m = try Message.begin(&b);
    try b.append("ok", .{ .double = 1 });
    try m.endBody();
    // With a checksum: four more bytes, the CRC-32C of everything before.
    try b.buf.appendNTimes(b.gpa, 0, 4);
    const bytes = try m.finishFlags(7, flag_checksum_present);
    const crc = std.hash.crc.@"CRC-32/ISCSI".hash(bytes[0 .. bytes.len - 4]);
    std.mem.writeInt(u32, b.buf.items[bytes.len - 4 ..][0..4], crc, .little);
    const reply = try parse(bytes);
    try testing.expectEqual(@as(f64, 1), reply.body.get("ok").?.double);

    const copy = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(copy);
    copy[copy.len - 6] ^= 1;
    try testing.expectError(error.ChecksumMismatch, parse(copy));
    try testing.expectError(error.InvalidMessage, parse(bytes[0 .. bytes.len - 1]));
    // An unknown required flag bit.
    @memcpy(copy, bytes);
    copy[17] = 0x80;
    try testing.expectError(error.InvalidMessage, parse(copy));
    // Another opcode.
    @memcpy(copy, bytes);
    copy[12] = 1;
    try testing.expectError(error.UnexpectedOpCode, parse(copy));
}

test "read: one message off a stream, header first" {
    var b: bson.Builder = .init(testing.allocator);
    defer b.deinit();
    var m = try Message.begin(&b);
    try b.append("hello", .{ .int32 = 1 });
    try m.endBody();
    const bytes = try m.finish(1);
    var two: [256]u8 = undefined;
    @memcpy(two[0..bytes.len], bytes);
    @memcpy(two[bytes.len..][0..bytes.len], bytes);
    var reader: std.Io.Reader = .fixed(two[0 .. bytes.len * 2]);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    for (0..2) |_| {
        const got = try read(&reader, testing.allocator, &buf, 1 << 20);
        try testing.expectEqualSlices(u8, bytes, got);
    }
    try testing.expectError(error.EndOfStream, read(&reader, testing.allocator, &buf, 1 << 20));
    reader = .fixed(bytes);
    try testing.expectError(error.MessageTooLarge, read(&reader, testing.allocator, &buf, 16));
}

test "fuzz: parse never fails but with an error" {
    try @import("../fuzz.zig").bytes(struct {
        fn check(input: []const u8) anyerror!void {
            if (input.len < header_len) return;
            var copy: [4096]u8 = undefined;
            const n = @min(input.len, copy.len);
            @memcpy(copy[0..n], input[0..n]);
            // Make the stated length right, so the parser goes past it.
            std.mem.writeInt(i32, copy[0..4], @intCast(n), .little);
            std.mem.writeInt(i32, copy[12..16], op_msg, .little);
            const reply = parse(copy[0..n]) catch return;
            var it = reply.body.iterator();
            while (it.next()) |_| {}
        }
    }.check, &.{
        "\x15\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\xdd\x07\x00\x00\x00\x00\x00\x00\x00\x05\x00\x00\x00\x00",
    });
}
