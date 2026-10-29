// Adapted from karlseguin/smtp_client.zig (MIT, Copyright (c) 2024 Karl Seguin),
// commit 538d0ddc064248b6c1431bfd68df2481f431c0fd. See LICENSE.smtp_client and
// THIRD_PARTY_NOTICES.

//! A server's reply: one or more lines `NNN-text` ending in `NNN text`
//! (RFC 5321 section 4.2), read from a `std.Io.Reader`.
const std = @import("std");

/// One line of a reply.
pub const Line = struct {
    code: u16,
    /// The line has a continuation after it (`NNN-`).
    more: bool,
    /// What follows the code and the separator.
    text: []const u8,
};

pub const ParseError = error{MalformedReply};

/// Reads the code and the text of one reply line (without its line end).
pub fn parseLine(raw: []const u8) ParseError!Line {
    if (raw.len < 3) return error.MalformedReply;
    var code: u16 = 0;
    for (raw[0..3]) |c| {
        if (c < '0' or c > '9') return error.MalformedReply;
        code = code * 10 + (c - '0');
    }
    if (code < 200 or code > 599) return error.MalformedReply;
    if (raw.len == 3) return .{ .code = code, .more = false, .text = "" };
    switch (raw[3]) {
        ' ' => return .{ .code = code, .more = false, .text = raw[4..] },
        '-' => return .{ .code = code, .more = true, .text = raw[4..] },
        else => return error.MalformedReply,
    }
}

/// A whole reply: the code and its lines' texts, in `arena`.
pub const Reply = struct {
    code: u16,
    lines: []const []const u8,

    /// The first line's text.
    pub fn first(self: Reply) []const u8 {
        return if (self.lines.len > 0) self.lines[0] else "";
    }

    /// Whether the code is 2xx.
    pub fn positive(self: Reply) bool {
        return self.code >= 200 and self.code < 300;
    }

    /// The enhanced status code (RFC 3463, "5.7.1") the first line starts
    /// with, if it does.
    pub fn enhanced(self: Reply) ?[]const u8 {
        return enhancedOf(self.first());
    }

    /// The reply as one line for a message: the lines joined by a space.
    pub fn joined(self: Reply, arena: std.mem.Allocator) ![]const u8 {
        return std.mem.join(arena, " ", self.lines);
    }
};

/// The leading `class.subject.detail` of a reply text, when it has one.
pub fn enhancedOf(text: []const u8) ?[]const u8 {
    const end = std.mem.indexOfScalar(u8, text, ' ') orelse text.len;
    const word = text[0..end];
    if (word.len < 5 or (word[0] != '2' and word[0] != '4' and word[0] != '5')) return null;
    var dots: u8 = 0;
    for (word, 0..) |c, i| {
        if (c == '.') {
            dots += 1;
            if (i == 0 or i + 1 == word.len or word[i - 1] == '.') return null;
        } else if (c < '0' or c > '9') return null;
    }
    return if (dots == 2) word else null;
}

pub const max_lines = 64;
pub const max_line_bytes = 4096;

/// Reads one whole reply. The texts are copied into `arena`.
pub fn read(r: *std.Io.Reader, arena: std.mem.Allocator) (ParseError || error{ EndOfStream, ReadFailed, OutOfMemory })!Reply {
    var lines: std.ArrayList([]const u8) = .empty;
    var code: u16 = 0;
    while (true) {
        const raw = (r.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => return error.MalformedReply,
            error.ReadFailed => return error.ReadFailed,
        }) orelse return error.EndOfStream;
        const line = try parseLine(std.mem.trimEnd(u8, raw, "\r"));
        if (lines.items.len == 0) code = line.code else if (line.code != code) return error.MalformedReply;
        if (lines.items.len >= max_lines) return error.MalformedReply;
        try lines.append(arena, try arena.dupe(u8, line.text[0..@min(line.text.len, max_line_bytes)]));
        if (!line.more) return .{ .code = code, .lines = lines.items };
    }
}

const testing = std.testing;

fn expectReadError(expected: anyerror, bytes: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var r: std.Io.Reader = .fixed(bytes);
    try testing.expectError(expected, read(&r, arena.allocator()));
}

test "parseLine: codes, separators and malformed lines" {
    const a = try parseLine("250 OK");
    try testing.expectEqual(@as(u16, 250), a.code);
    try testing.expect(!a.more);
    try testing.expectEqualStrings("OK", a.text);
    const b = try parseLine("250-PIPELINING");
    try testing.expect(b.more);
    try testing.expectEqualStrings("PIPELINING", b.text);
    const c = try parseLine("354");
    try testing.expectEqual(@as(u16, 354), c.code);
    try testing.expectError(error.MalformedReply, parseLine("25"));
    try testing.expectError(error.MalformedReply, parseLine("abc ok"));
    try testing.expectError(error.MalformedReply, parseLine("250x"));
    try testing.expectError(error.MalformedReply, parseLine("999 no"));
    try testing.expectError(error.MalformedReply, parseLine("100 no"));
}

test "read: a single line, and a multi-line reply across fragments" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // The bytes arrive in fragments cut inside lines and inside the CRLF, at most 3
    // bytes per fill, so the multi-line reply spans many fills.
    var buf: [64]u8 = undefined;
    var fr: std.testing.Reader = .init(&buf, &.{
        .{ .buffer = "220 mail.exam" },
        .{ .buffer = "ple.com ESMTP\r" },
        .{ .buffer = "\n250-mail.example.com\r\n250-PIPE" },
        .{ .buffer = "LINING\r\n250 SIZE 35882577\r\n" },
    });
    fr.artificial_limit = .limited(3);
    const r = &fr.interface;
    const greeting = try read(r, arena.allocator());
    try testing.expectEqual(@as(u16, 220), greeting.code);
    try testing.expectEqualStrings("mail.example.com ESMTP", greeting.first());
    const ehlo = try read(r, arena.allocator());
    try testing.expectEqual(@as(u16, 250), ehlo.code);
    try testing.expectEqual(@as(usize, 3), ehlo.lines.len);
    try testing.expectEqualStrings("SIZE 35882577", ehlo.lines[2]);
    try testing.expectError(error.EndOfStream, read(r, arena.allocator()));
}

test "read: a code that changes inside a reply, and a reply cut short, are errors" {
    try expectReadError(error.MalformedReply, "250-a\r\n251 b\r\n");
    try expectReadError(error.EndOfStream, "250-a\r\n");
}

test "reply: an enhanced status code is class.subject.detail at the start of the text (class 2, 4 or 5), else none" {
    try testing.expectEqualStrings("5.7.1", enhancedOf("5.7.1 Relaying denied").?);
    try testing.expectEqualStrings("2.0.0", enhancedOf("2.0.0").?);
    try testing.expect(enhancedOf("Relaying denied") == null);
    try testing.expect(enhancedOf("5.7 nope") == null);
    try testing.expect(enhancedOf("5..1 nope") == null);
    try testing.expect(enhancedOf("3.1.1 x") == null);
}
