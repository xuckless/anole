// Adapted from karlseguin/smtp_client.zig (MIT, Copyright (c) 2024 Karl Seguin),
// commit 538d0ddc064248b6c1431bfd68df2481f431c0fd. See LICENSE.smtp_client and
// THIRD_PARTY_NOTICES.

//! How a message's text becomes bytes: header values (RFC 2047 encoded
//! words and quoted phrases), quoted-printable and base64 bodies, the
//! boundary and the Message-ID.
const std = @import("std");

const Writer = std.Io.Writer;

/// A header value or a display name, as the header carries it: plain,
/// quoted (a phrase with specials), or RFC 2047 encoded words.
pub const ValueEncoder = struct {
    value: []const u8,
    encoder: Encoder,

    pub const Encoder = enum { none, base64, quoted };

    /// The raw bytes of one encoded word (45 of them become 60 base64
    /// characters, and with the 12 of overhead the word is 72 long, under
    /// RFC 2047's 75).
    const word_bytes = 45;

    /// `allow_quoted`: a display name may be quoted; an unstructured value
    /// (a subject) is plain or encoded.
    pub fn init(value: []const u8, allow_quoted: bool) ValueEncoder {
        // "=?" in a plain value would read as the start of an encoded word.
        var base64 = std.mem.find(u8, value, "=?") != null;
        var needs_quote = false;
        if (!base64) for (value) |b| {
            switch (b) {
                0...31, 127...255 => {
                    base64 = true;
                    break;
                },
                'a'...'z', 'A'...'Z', '0'...'9', ' ' => {},
                else => {
                    // A subject may hold any printable ASCII.
                    if (allow_quoted) needs_quote = true;
                },
            }
        };
        return .{ .value = value, .encoder = if (base64) .base64 else if (needs_quote) .quoted else .none };
    }

    /// Writes the value with no leading space. Encoded words are separated
    /// by one space each, so a folding writer may break between them.
    pub fn write(self: ValueEncoder, w: *Writer) Writer.Error!void {
        const value = self.value;
        switch (self.encoder) {
            .none => try w.writeAll(value),
            .base64 => {
                var rest = value;
                var first = true;
                while (rest.len > 0) {
                    var n = @min(word_bytes, rest.len);
                    // Not in the middle of a UTF-8 sequence.
                    while (n < rest.len and n > 1 and (rest[n] & 0xC0) == 0x80) n -= 1;
                    if (!first) try w.writeByte(' ');
                    first = false;
                    try w.writeAll("=?UTF-8?B?");
                    try std.base64.standard.Encoder.encodeWriter(w, rest[0..n]);
                    try w.writeAll("?=");
                    rest = rest[n..];
                }
            },
            .quoted => {
                try w.writeByte('"');
                for (value) |b| {
                    if (b == '"' or b == '\\') try w.writeByte('\\');
                    try w.writeByte(b);
                }
                try w.writeByte('"');
            },
        }
    }
};

/// The bytes of `value` for a header after RFC 2231: `UTF-8''` and
/// percent-encoding; for a file name with non-ASCII characters.
pub fn writeExtValue(w: *Writer, value: []const u8) Writer.Error!void {
    try w.writeAll("UTF-8''");
    for (value) |b| {
        switch (b) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '.', '_', '~' => try w.writeByte(b),
            else => try w.print("%{X:0>2}", .{b}),
        }
    }
}

/// `size` random bytes as `2 * size` lowercase hex digits.
pub fn randomHex(comptime size: comptime_int, into: []u8, random: std.Random) void {
    std.debug.assert(into.len == size * 2);
    var buf: [size]u8 = undefined;
    random.bytes(&buf);
    const charset = "0123456789abcdef";
    for (buf, 0..) |b, i| {
        into[i * 2] = charset[b >> 4];
        into[i * 2 + 1] = charset[b & 15];
    }
}

/// `----` and 32 hex digits: the `--` of the delimiter lines is the
/// first two characters, so the parameter is `boundary[2..]`.
pub fn createBoundary(random: std.Random) [36]u8 {
    var boundary: [36]u8 = undefined;
    @memcpy(boundary[0..4], "----");
    randomHex(16, boundary[4..], random);
    return boundary;
}

/// `<32 hex>@host` for a Message-ID (without the angle brackets). `host`
/// is the From address's domain, else "localhost".
pub fn writeMessageId(w: *Writer, host: []const u8, random: std.Random) Writer.Error!void {
    var id: [32]u8 = undefined;
    randomHex(16, &id, random);
    try w.writeAll(&id);
    try w.writeByte('@');
    try w.writeAll(if (host.len == 0) "localhost" else host);
}

/// Whether `text` can go out as 7bit: ASCII without NUL or stray CR,
/// every line within 998 bytes.
pub fn is7bit(text: []const u8) bool {
    var line: usize = 0;
    for (text, 0..) |b, i| {
        if (b > 127 or b == 0) return false;
        if (b == '\r') {
            if (i + 1 >= text.len or text[i + 1] != '\n') return false;
            continue;
        }
        if (b == '\n') {
            line = 0;
            continue;
        }
        line += 1;
        if (line > 998) return false;
    }
    return true;
}

/// `text` with every line break (LF or CRLF) as CRLF, the last line
/// ended too. For text that `is7bit`.
pub fn write7bit(w: *Writer, text: []const u8) Writer.Error!void {
    var i: usize = 0;
    var start: usize = 0;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '\r' => {},
            '\n' => {
                const end = if (i > 0 and text[i - 1] == '\r') i - 1 else i;
                try w.writeAll(text[start..end]);
                try w.writeAll("\r\n");
                start = i + 1;
            },
            else => {},
        }
    }
    if (start < text.len) {
        try w.writeAll(text[start..]);
        try w.writeAll("\r\n");
    }
}

/// Quoted-printable (RFC 2045): line breaks (LF or CRLF) stay hard line
/// breaks, space and tab before one are encoded, no line is over 76
/// characters (a soft break `=` ends the line), and the last line is
/// ended.
pub fn writeQuotedPrintable(w: *Writer, data: []const u8) Writer.Error!void {
    const charset = "0123456789ABCDEF";
    var col: usize = 0;
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        const b = data[i];
        if (b == '\n' or (b == '\r' and i + 1 < data.len and data[i + 1] == '\n')) {
            if (b == '\r') i += 1;
            try w.writeAll("\r\n");
            col = 0;
            continue;
        }
        const at_line_end = i + 1 == data.len or data[i + 1] == '\n' or (data[i + 1] == '\r' and i + 2 < data.len and data[i + 2] == '\n');
        const literal = b != '=' and ((b >= 33 and b <= 126) or ((b == ' ' or b == '\t') and !at_line_end));
        const need: usize = if (literal) 1 else 3;
        if (col + need > 75) {
            try w.writeAll("=\r\n");
            col = 0;
        }
        if (literal) {
            try w.writeByte(b);
        } else {
            try w.writeAll(&.{ '=', charset[b >> 4], charset[b & 15] });
        }
        col += need;
    }
    if (col > 0 or data.len == 0) try w.writeAll("\r\n");
}

/// Writes base64 in lines of 76 characters, each ended with CRLF.
/// `col` is how far into a line the last call stopped (start at 0); feed
/// chunks of a multiple of 3 bytes except the last, then call `finish`.
pub fn writeBase64(w: *Writer, col: *usize, data: []const u8) Writer.Error!void {
    var rest = data;
    var out: [4096]u8 = undefined;
    while (rest.len > 0) {
        const n = @min(rest.len, 3072);
        const encoded = std.base64.standard.Encoder.encode(&out, rest[0..n]);
        var e: []const u8 = encoded;
        while (e.len > 0) {
            const space = 76 - col.*;
            const take = @min(space, e.len);
            try w.writeAll(e[0..take]);
            col.* += take;
            e = e[take..];
            if (col.* == 76) {
                try w.writeAll("\r\n");
                col.* = 0;
            }
        }
        rest = rest[n..];
    }
}

/// Ends the last line of `writeBase64`.
pub fn finishBase64(w: *Writer, col: *usize) Writer.Error!void {
    if (col.* > 0) try w.writeAll("\r\n");
    col.* = 0;
}

/// The size `writeBase64` and `finishBase64` write for `raw` bytes.
pub fn base64Size(raw: u64) u64 {
    if (raw == 0) return 0;
    const encoded = (raw + 2) / 3 * 4;
    return encoded + 2 * ((encoded + 75) / 76);
}

const testing = std.testing;

/// `s` repeated `n` times, at compile time (Zig 0.17 has no `**`).
fn repeat(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    const Storage = struct {
        const data: [s.len * n]u8 = blk: {
            @setEvalBranchQuota(10_000_000);
            var out: [s.len * n]u8 = undefined;
            for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
            break :blk out;
        };
    };
    return &Storage.data;
}

fn writeValue(w: *Writer, e: ValueEncoder) Writer.Error!void {
    try e.write(w);
}

fn render(comptime f: anytype, args: anytype) ![]u8 {
    var aw: Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try @call(.auto, f, .{&aw.writer} ++ args);
    return aw.toOwnedSlice();
}

test "ValueEncoder: plain, quoted and encoded words" {
    const cases = [_]struct { v: []const u8, quoted: bool, out: []const u8 }{
        .{ .v = "Leto", .quoted = true, .out = "Leto" },
        .{ .v = "Mr. Leto", .quoted = true, .out = "\"Mr. Leto\"" },
        .{ .v = "Mr. \"Leto\"", .quoted = true, .out = "\"Mr. \\\"Leto\\\"\"" },
        .{ .v = "✔", .quoted = true, .out = "=?UTF-8?B?4pyU?=" },
        .{ .v = "Hello.You", .quoted = false, .out = "Hello.You" },
        .{ .v = "Mr. 👻", .quoted = true, .out = "=?UTF-8?B?TXIuIPCfkbs=?=" },
    };
    for (cases) |c| {
        const out = try render(writeValue, .{ValueEncoder.init(c.v, c.quoted)});
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.out, out);
    }
}

test "ValueEncoder: a long value is several encoded words, none cut inside a character" {
    const value = repeat("ƒ", 60);
    const out = try render(writeValue, .{ValueEncoder.init(value, false)});
    defer testing.allocator.free(out);
    var words = std.mem.splitScalar(u8, out, ' ');
    var n: usize = 0;
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(testing.allocator);
    while (words.next()) |word| {
        n += 1;
        try testing.expect(word.len <= 75);
        try testing.expect(std.mem.startsWith(u8, word, "=?UTF-8?B?") and std.mem.endsWith(u8, word, "?="));
        const b64 = word["=?UTF-8?B?".len .. word.len - 2];
        const size = try std.base64.standard.Decoder.calcSizeForSlice(b64);
        const buf = try testing.allocator.alloc(u8, size);
        defer testing.allocator.free(buf);
        try std.base64.standard.Decoder.decode(buf, b64);
        try testing.expect(std.unicode.utf8ValidateSlice(buf));
        try decoded.appendSlice(testing.allocator, buf);
    }
    try testing.expect(n > 1);
    try testing.expectEqualStrings(value, decoded.items);
}

test "writeExtValue: RFC 2231 percent encoding" {
    const out = try render(writeExtValue, .{"é a.txt"});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("UTF-8''%C3%A9%20a.txt", out);
}

test "encode: 7bit means ASCII without a bare CR and lines up to 998 bytes; write7bit ends every line with CRLF" {
    try testing.expect(is7bit("hello\nworld"));
    try testing.expect(!is7bit("héllo"));
    try testing.expect(!is7bit("a\rb"));
    try testing.expect(!is7bit(repeat("a", 999)));
    try testing.expect(is7bit(repeat("a", 998)));
    const out = try render(write7bit, .{"one\ntwo\r\nthree"});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("one\r\ntwo\r\nthree\r\n", out);
}

test "quoted-printable: hard breaks kept, specials and trailing space encoded, soft breaks at 76" {
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "Hello", .out = "Hello\r\n" },
        .{ .in = "a=b", .out = "a=3Db\r\n" },
        .{ .in = "line one\nline two \nend", .out = "line one\r\nline two=20\r\nend\r\n" },
        .{ .in = "tab\t\r\nnext", .out = "tab=09\r\nnext\r\n" },
        .{ .in = "caf\xc3\xa9", .out = "caf=C3=A9\r\n" },
        .{ .in = repeat("a", 76), .out = repeat("a", 75) ++ "=\r\na\r\n" },
        .{ .in = repeat("a", 74) ++ "\xc3\xa9", .out = repeat("a", 74) ++ "=\r\n=C3=A9\r\n" },
        .{ .in = "", .out = "\r\n" },
    };
    for (cases) |c| {
        const out = try render(writeQuotedPrintable, .{c.in});
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.out, out);
    }
}

test "base64: 76-column lines across chunks, and the computed size" {
    const sizes = [_]usize{ 0, 1, 2, 3, 56, 57, 58, 114, 1000, 4096 };
    for (sizes) |n| {
        const data = try testing.allocator.alloc(u8, n);
        defer testing.allocator.free(data);
        for (data, 0..) |*b, i| b.* = @truncate(i *% 7);
        var aw: Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        var col: usize = 0;
        // Chunks of 300 (a multiple of 3), the last one short.
        var at: usize = 0;
        while (at < n) {
            const k = @min(300, n - at);
            try writeBase64(&aw.writer, &col, data[at..][0..k]);
            at += k;
        }
        try finishBase64(&aw.writer, &col);
        try testing.expectEqual(base64Size(n), aw.writer.buffered().len);
        var lines = std.mem.splitSequence(u8, aw.writer.buffered(), "\r\n");
        while (lines.next()) |line| try testing.expect(line.len <= 76);
    }
}

test "encode: a boundary starts with ---- and a Message-ID ends with @domain, from the seeded generator" {
    var prng = std.Random.DefaultPrng.init(0);
    const b = createBoundary(prng.random());
    try testing.expectEqualStrings("----", b[0..4]);
    try testing.expectEqual(@as(usize, 36), b.len);
    const out = try render(writeMessageId, .{ "example.org", prng.random() });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.endsWith(u8, out, "@example.org"));
    try testing.expectEqual(@as(usize, 32 + 1 + 11), out.len);
}
