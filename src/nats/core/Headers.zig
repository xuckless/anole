// Adapted from vkiryakov/zefir src/nats/Headers.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! Message headers: the `NATS/1.0` block of HPUB and HMSG.
//!
//! A received message's headers are a view of its header block. Lookups
//! scan the block and copy nothing; the order, duplicates and case of the
//! wire are kept. Names are case-sensitive, as in ADR-4: `get("X-Id")`
//! does not find `x-id`.
//!
//! ```zig
//! const request_id = msg.headers.get("X-Request-Id") orelse "none";
//! var tags = msg.headers.getAll("X-Tag");
//! while (tags.next()) |tag| ...
//! ```
//!
//! The server forwards a publisher's block without checking it, so reading
//! never fails: a line without a colon is skipped, a block without the
//! `NATS/1.0` line is read from its first line, and a status is read only
//! from a well-formed `NATS/1.0 <code>` line. Headers to send are checked
//! strictly by `validate`: a name is printable ASCII without `:`, a value
//! has no CR or LF.

const std = @import("std");
const Headers = @This();

/// One header to send, borrowed for the duration of the call.
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// The block as received: from `NATS/1.0` through the blank line; empty
/// when the message has no headers.
block: []const u8,

pub const empty: Headers = .{ .block = "" };

const version_line = "NATS/1.0";

/// The status code on the first line, such as 503 for "no responders";
/// null when there is none.
pub fn status(h: Headers) ?u16 {
    const rest = h.afterVersion() orelse return null;
    if (rest.len < 3) return null;
    var code: u16 = 0;
    for (rest[0..3]) |c| {
        if (!std.ascii.isDigit(c)) return null;
        code = code * 10 + (c - '0');
    }
    if (rest.len > 3 and rest[3] != ' ' and rest[3] != '\t') return null;
    return code;
}

/// The text after the status code, such as "No Messages"; empty when
/// there is no status or no text.
pub fn description(h: Headers) []const u8 {
    if (h.status() == null) return "";
    return std.mem.trim(u8, h.afterVersion().?[3..], " \t");
}

/// The first value of `name`, or null; the name is case-sensitive.
pub fn get(h: Headers, name: []const u8) ?[]const u8 {
    var values = h.getAll(name);
    return values.next();
}

/// Every value of `name` in wire order; the name is case-sensitive.
pub fn getAll(h: Headers, name: []const u8) ValueIterator {
    return .{ .fields = h.iterator(), .name = name };
}

/// Every field in wire order.
pub fn iterator(h: Headers) Iterator {
    var lines = std.mem.splitSequence(u8, h.block, "\r\n");
    // A block without the version line is read from its first line.
    if (std.mem.startsWith(u8, h.block, version_line)) _ = lines.next();
    return .{ .lines = lines };
}

pub const Iterator = struct {
    lines: std.mem.SplitIterator(u8, .sequence),

    pub fn next(it: *Iterator) ?Header {
        while (it.lines.next()) |line| {
            if (line.len == 0) return null; // the blank line ends the block
            const colon = std.mem.findScalar(u8, line, ':') orelse continue;
            if (colon == 0) continue;
            return .{ .name = line[0..colon], .value = std.mem.trim(u8, line[colon + 1 ..], " \t") };
        }
        return null;
    }
};

pub const ValueIterator = struct {
    fields: Iterator,
    name: []const u8,

    pub fn next(it: *ValueIterator) ?[]const u8 {
        while (it.fields.next()) |field| {
            if (std.mem.eql(u8, field.name, it.name)) return field.value;
        }
        return null;
    }
};

/// The first line after `NATS/1.0` and its separating whitespace; null
/// when the block does not start with a version line.
fn afterVersion(h: Headers) ?[]const u8 {
    const line_end = std.mem.find(u8, h.block, "\r\n") orelse h.block.len;
    const line = h.block[0..line_end];
    if (!std.mem.startsWith(u8, line, version_line)) return null;
    const rest = line[version_line.len..];
    if (rest.len > 0 and rest[0] != ' ' and rest[0] != '\t') return null;
    return std.mem.trimStart(u8, rest, " \t");
}

pub const ValidateError = error{InvalidHeader};

/// Checks headers to send: a name is printable ASCII (33..126) without
/// `:`, a value has no CR or LF.
pub fn validate(headers: []const Header) ValidateError!void {
    for (headers) |header| {
        if (header.name.len == 0) return error.InvalidHeader;
        for (header.name) |c| {
            if (c < 33 or c > 126 or c == ':') return error.InvalidHeader;
        }
        if (std.mem.findAny(u8, header.value, "\r\n") != null) return error.InvalidHeader;
    }
}

const testing = std.testing;

test "multi-value headers keep order, duplicates and case" {
    const h: Headers = .{ .block = "NATS/1.0\r\nX-Multi: one\r\nX-Multi: two\r\nX-Single: v\r\n\r\n" };
    try testing.expectEqualStrings("one", h.get("X-Multi").?);
    try testing.expect(h.get("x-multi") == null);
    try testing.expectEqualStrings("v", h.get("X-Single").?);
    var values = h.getAll("X-Multi");
    try testing.expectEqualStrings("one", values.next().?);
    try testing.expectEqualStrings("two", values.next().?);
    try testing.expect(values.next() == null);
    var fields = h.iterator();
    try testing.expectEqualStrings("X-Multi", fields.next().?.name);
    try testing.expectEqualStrings("X-Multi", fields.next().?.name);
    try testing.expectEqualStrings("X-Single", fields.next().?.name);
    try testing.expect(fields.next() == null);
    try testing.expect(h.status() == null);
}

test "inline status and description" {
    const no_responders: Headers = .{ .block = "NATS/1.0 503\r\nNats-Subject: nobody.listens\r\n\r\n" };
    try testing.expectEqual(503, no_responders.status().?);
    try testing.expectEqualStrings("", no_responders.description());
    try testing.expectEqualStrings("nobody.listens", no_responders.get("Nats-Subject").?);

    const not_found: Headers = .{ .block = "NATS/1.0  404   No Messages\r\n\r\n" };
    try testing.expectEqual(404, not_found.status().?);
    try testing.expectEqualStrings("No Messages", not_found.description());

    for ([_][]const u8{ "NATS/1.0 5\r\n\r\n", "NATS/1.0 50x\r\n\r\n", "NATS/1.00\r\n\r\n", "NATS/1.0 5030\r\n\r\n", "HTTP/1.1 503\r\n\r\n" }) |block| {
        const h: Headers = .{ .block = block };
        try testing.expect(h.status() == null);
        try testing.expectEqualStrings("", h.description());
    }
    try testing.expect(Headers.empty.status() == null);
    try testing.expect(Headers.empty.get("X") == null);
}

test "a malformed block from a foreign publisher is read leniently" {
    const h: Headers = .{ .block = "NATS/1.0\r\nno colon here\r\n: no name\r\nGood:  yes \r\n\r\n" };
    try testing.expectEqualStrings("yes", h.get("Good").?);
    var fields = h.iterator();
    try testing.expectEqualStrings("Good", fields.next().?.name);
    try testing.expect(fields.next() == null);

    const garbage: Headers = .{ .block = "garbage without line ends" };
    try testing.expect(garbage.status() == null);
    try testing.expect(garbage.get("garbage without line ends") == null);
}

test "a block without the version line keeps its first header" {
    const h: Headers = .{ .block = "X-Id: 1\r\nY: 2\r\n\r\n" };
    try testing.expectEqualStrings("1", h.get("X-Id") orelse "");
    try testing.expectEqualStrings("2", h.get("Y") orelse "");
    try testing.expect(h.status() == null);
}

test "validate headers to send" {
    try validate(&.{ .{ .name = "X-Id", .value = "1" }, .{ .name = "Empty", .value = "" }, .{ .name = "Utf8", .value = "значение" } });
    for ([_]Header{
        .{ .name = "", .value = "v" },
        .{ .name = "Two Words", .value = "v" },
        .{ .name = "Colon:", .value = "v" },
        .{ .name = "Del\x7f", .value = "v" },
        .{ .name = "Ünï", .value = "v" },
        .{ .name = "X", .value = "line\r\nInjected: yes" },
        .{ .name = "X", .value = "lf\n" },
        .{ .name = "X", .value = "cr\r" },
    }) |header| {
        try testing.expectError(error.InvalidHeader, validate(&.{header}));
    }
}
