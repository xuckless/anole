// Copied from vkiryakov/zefir src/log/escape.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! Escaping of record strings, shared by the JSON and text formats.
//!
//! `"`, `\`, control characters (C0, DEL and C1), the line and paragraph
//! separators U+2028 and U+2029, and the bidi controls that reorder text
//! become escape sequences; other valid UTF-8 passes through, and every byte
//! that does not start a valid UTF-8 sequence becomes U+FFFD. The output is
//! valid UTF-8 without line breaks, so one record stays one line, also in a
//! terminal.

const std = @import("std");
const testing = std.testing;

const replacement = "\u{FFFD}";

const Kind = enum { verbatim, short_escape, unicode_escape, invalid };

/// One character of the input: what it becomes, and how many input bytes
/// it takes.
const Unit = struct {
    kind: Kind,
    len: u3,
    /// The code point a `.unicode_escape` writes.
    cp: u21 = 0,

    fn outLen(unit: Unit) usize {
        return switch (unit.kind) {
            .verbatim => unit.len,
            .short_escape => 2,
            .unicode_escape => 6,
            .invalid => replacement.len,
        };
    }
};

fn unitAt(s: []const u8, i: usize) Unit {
    const c = s[i];
    if (c < 0x80) return switch (c) {
        '"', '\\', '\n', '\r', '\t' => .{ .kind = .short_escape, .len = 1 },
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => .{ .kind = .unicode_escape, .len = 1, .cp = c },
        else => .{ .kind = .verbatim, .len = 1 },
    };
    const bad: Unit = .{ .kind = .invalid, .len = 1 };
    const n = std.unicode.utf8ByteSequenceLength(c) catch return bad;
    if (n > s.len - i) return bad;
    const cp = std.unicode.utf8Decode(s[i..][0..n]) catch return bad;
    if (isHidden(cp)) return .{ .kind = .unicode_escape, .len = n, .cp = cp };
    return .{ .kind = .verbatim, .len = n };
}

/// Valid code points that would still break a line or fool a reader: C1
/// controls (U+0085 ends a line for some readers, U+009B starts a terminal
/// escape), the line and paragraph separators, and the bidi controls that
/// make a terminal show text in another order.
fn isHidden(cp: u21) bool {
    return switch (cp) {
        0x80...0x9f, 0x2028, 0x2029, 0x202a...0x202e, 0x2066...0x2069 => true,
        else => false,
    };
}

/// Writes `s` escaped, without quotes.
pub fn write(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    var start: usize = 0; // the first byte not written yet
    var i: usize = 0;
    while (i < s.len) {
        const unit = unitAt(s, i);
        if (unit.kind != .verbatim) {
            try w.writeAll(s[start..i]);
            try writeEscape(w, s[i], unit);
            start = i + unit.len;
        }
        i += unit.len;
    }
    try w.writeAll(s[start..]);
}

fn writeEscape(w: *std.Io.Writer, c: u8, unit: Unit) std.Io.Writer.Error!void {
    const hex = "0123456789abcdef";
    switch (unit.kind) {
        .verbatim => unreachable,
        .short_escape => try w.writeAll(&[2]u8{
            '\\',
            switch (c) {
                '\n' => 'n',
                '\r' => 'r',
                '\t' => 't',
                else => c, // '"' and '\\'
            },
        }),
        .unicode_escape => try w.writeAll(&[6]u8{
            '\\',
            'u',
            hex[unit.cp >> 12 & 0xf],
            hex[unit.cp >> 8 & 0xf],
            hex[unit.cp >> 4 & 0xf],
            hex[unit.cp & 0xf],
        }),
        .invalid => try w.writeAll(replacement),
    }
}

/// The length of `s` once escaped.
pub fn escapedLen(s: []const u8) usize {
    var total: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const unit = unitAt(s, i);
        total += unit.outLen();
        i += unit.len;
    }
    return total;
}

/// The length of the longest prefix of `s` whose escaped form fits in
/// `budget` bytes. The cut falls between characters, never inside a UTF-8
/// sequence or an escape.
pub fn fittingPrefix(s: []const u8, budget: usize) usize {
    var used: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const unit = unitAt(s, i);
        used += unit.outLen();
        if (used > budget) break;
        i += unit.len;
    }
    return i;
}

/// A writer that escapes what it is given into `out`, as `write` does: the
/// output of `format` methods and of std.log messages goes through it. A
/// UTF-8 sequence split between two writes is held back until it is whole;
/// `finish` writes out what is left. Use it in place: `init` points its
/// writer at its own buffer.
pub const Escaper = struct {
    out: *std.Io.Writer,
    writer: std.Io.Writer,
    /// Escaped bytes written to `out` so far.
    count: usize = 0,
    /// When set, stop at this many escaped bytes, between characters, and
    /// drop the rest; `cut` tells whether that happened.
    budget: ?usize = null,
    cut: bool = false,
    /// With a budget: `safe_count` is the last count, at a character
    /// boundary, that leaves `reserve` bytes of the budget free, so a cut
    /// text can end there and still take a "…".
    reserve: usize = 0,
    safe_count: usize = 0,
    /// Nothing so far needs quotes in the text format: no escape, no space
    /// or '=', and, when `strict`, none of ",[]{}" either.
    plain: bool = true,
    strict: bool = false,
    /// The start of a UTF-8 sequence that the last write cut short.
    pending: [4]u8 = undefined,
    pending_len: u8 = 0,
    buffer: [256]u8 = undefined,

    const vtable: std.Io.Writer.VTable = .{ .drain = drain, .flush = flush };

    pub fn init(e: *Escaper, out: *std.Io.Writer) void {
        e.* = .{ .out = out, .writer = .{ .buffer = &e.buffer, .vtable = &vtable } };
    }

    /// Writes out what is held back; an unfinished sequence becomes U+FFFD.
    pub fn finish(e: *Escaper) std.Io.Writer.Error!void {
        try e.writer.flush();
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const e: *Escaper = @alignCast(@fieldParentPtr("writer", w));
        try e.feed(w.buffer[0..w.end]);
        w.end = 0;
        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try e.feed(bytes);
            consumed += bytes.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| try e.feed(pattern);
        return consumed + pattern.len * splat;
    }

    fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const e: *Escaper = @alignCast(@fieldParentPtr("writer", w));
        try e.feed(w.buffer[0..w.end]);
        w.end = 0;
        const held = e.pending_len;
        e.pending_len = 0;
        try e.emit(e.pending[0..held]);
    }

    fn feed(e: *Escaper, bytes: []const u8) std.Io.Writer.Error!void {
        var rest = bytes;
        if (e.pending_len > 0) {
            const need = std.unicode.utf8ByteSequenceLength(e.pending[0]) catch unreachable;
            while (e.pending_len < need and rest.len > 0 and rest[0] & 0xc0 == 0x80) {
                e.pending[e.pending_len] = rest[0];
                e.pending_len += 1;
                rest = rest[1..];
            }
            if (e.pending_len < need and rest.len == 0) return; // still unfinished
            const held = e.pending_len;
            e.pending_len = 0;
            try e.emit(e.pending[0..held]);
        }
        const keep = unfinishedTail(rest);
        try e.emit(rest[0 .. rest.len - keep]);
        @memcpy(e.pending[0..keep], rest[rest.len - keep ..]);
        e.pending_len = @intCast(keep);
    }

    fn emit(e: *Escaper, s: []const u8) std.Io.Writer.Error!void {
        if (e.cut or s.len == 0) return;
        var part = s;
        if (e.budget) |budget| {
            const n = fittingPrefix(s, budget - e.count);
            if (n < s.len) {
                e.cut = true;
                part = s[0..n];
            }
            const limit = budget -| e.reserve;
            if (e.count < limit) e.safe_count = e.count + escapedLen(part[0..fittingPrefix(part, limit - e.count)]);
        }
        const len = escapedLen(part);
        const special: []const u8 = if (e.strict) " =,[]{}" else " =";
        if (len != part.len or std.mem.findAny(u8, part, special) != null) e.plain = false;
        try write(e.out, part);
        e.count += len;
    }
};

/// How many bytes at the end of `s` start a UTF-8 sequence that `s` cuts
/// short.
fn unfinishedTail(s: []const u8) usize {
    var back: usize = 1;
    while (back <= 3 and back <= s.len) : (back += 1) {
        const c = s[s.len - back];
        if (c & 0xc0 == 0x80) continue; // a continuation byte: look further back
        const n = std.unicode.utf8ByteSequenceLength(c) catch return 0;
        return if (n > back) back else 0;
    }
    return 0;
}

/// Whether the text format may write `s` without quotes: it is not empty
/// and has no spaces, no `=`, nothing that needs escaping and no invalid
/// UTF-8.
pub fn isBare(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = 0;
    while (i < s.len) {
        const unit = unitAt(s, i);
        if (unit.kind != .verbatim or s[i] == ' ' or s[i] == '=') return false;
        i += unit.len;
    }
    return true;
}

fn expectEscaped(expected: []const u8, input: []const u8) !void {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write(&w, input);
    try testing.expectEqualStrings(expected, w.buffered());
    try testing.expectEqual(expected.len, escapedLen(input));
}

test "quotes, backslashes, control characters and DEL become escapes" {
    try expectEscaped("a\\\"b\\\\c", "a\"b\\c");
    try expectEscaped("\\n\\r\\t", "\n\r\t");
    try expectEscaped("\\u0000\\u0001\\u001b\\u007f", "\x00\x01\x1b\x7f");
}

test "C1 controls, line and paragraph separators and bidi controls become escapes" {
    try expectEscaped("nel\\u0085x", "nel\u{85}x");
    try expectEscaped("\\u0080\\u009b31m", "\u{80}\u{9b}31m");
    try expectEscaped("a\\u2028b\\u2029c", "a\u{2028}b\u{2029}c");
    try expectEscaped("\\u202a\\u202e\\u2066\\u2069", "\u{202a}\u{202e}\u{2066}\u{2069}");
    try expectEscaped("\u{a0}\u{2027}\u{202f}\u{2065}\u{206a}", "\u{a0}\u{2027}\u{202f}\u{2065}\u{206a}"); // their neighbours pass
    try testing.expect(!isBare("x\u{2028}y"));
    try testing.expect(!isBare("\u{9b}31mred"));
    try testing.expectEqual(@as(usize, 1), fittingPrefix("a\u{85}", 6)); // "\\u0085" takes 6
    try testing.expectEqual(@as(usize, 3), fittingPrefix("a\u{85}", 7));
}

test "valid UTF-8 passes through" {
    try expectEscaped("é € 😀", "é € 😀");
}

test "every invalid byte becomes U+FFFD" {
    try expectEscaped("\u{FFFD}", "\xff");
    try expectEscaped("a\u{FFFD}", "a\xc3"); // a sequence cut short
    try expectEscaped("\u{FFFD}\u{FFFD}", "\xc0\x80"); // overlong
    try expectEscaped("\u{FFFD}\u{FFFD}\u{FFFD}", "\xed\xa0\x80"); // a surrogate
    try expectEscaped("\u{FFFD}x", "\x80x"); // a stray continuation byte
}

test "no pair of bytes can break the line or the encoding" {
    for (0..256) |a| {
        for (0..256) |b| {
            const input = [2]u8{ @intCast(a), @intCast(b) };
            var buf: [16]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            try write(&w, &input);
            try testing.expect(std.unicode.utf8ValidateSlice(w.buffered()));
            try testing.expect(std.mem.findScalar(u8, w.buffered(), '\n') == null);
            try testing.expect(std.mem.findScalar(u8, w.buffered(), '\r') == null);
        }
    }
}

test "fittingPrefix cuts between characters, never inside one" {
    try testing.expectEqual(@as(usize, 2), fittingPrefix("ab😀", 5)); // the 4-byte emoji does not fit
    try testing.expectEqual(@as(usize, 6), fittingPrefix("ab😀", 6));
    try testing.expectEqual(@as(usize, 1), fittingPrefix("a\nb", 2)); // "\\n" takes 2 bytes
    try testing.expectEqual(@as(usize, 0), fittingPrefix("\x01", 5)); // "\\u0001" takes 6
    try testing.expectEqual(@as(usize, 1), fittingPrefix("\xffz", 3)); // U+FFFD takes 3
    try testing.expectEqual(@as(usize, 0), fittingPrefix("", 0));
}

/// Writes `parts` through an escaper, one write each, and finishes it.
fn escapeParts(out: *std.Io.Writer, e: *Escaper, parts: []const []const u8) !void {
    e.init(out);
    for (parts) |part| try e.writer.writeAll(part);
    try e.finish();
}

test "an escaper escapes a stream; a UTF-8 sequence split between writes stays whole" {
    var buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var e: Escaper = undefined;
    try escapeParts(&out, &e, &.{ "a\"b ", "\xe2\x82", "\xac", "\n!" });
    try testing.expectEqualStrings("a\\\"b €\\n!", out.buffered());
    try testing.expectEqual(out.buffered().len, e.count);
    try testing.expect(!e.plain);
}

test "an escaper ends an unfinished sequence with U+FFFD" {
    var buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var e: Escaper = undefined;
    try escapeParts(&out, &e, &.{ "x\xe2", "\x82" });
    try testing.expectEqualStrings("x\u{FFFD}\u{FFFD}", out.buffered());
    out = .fixed(&buf);
    try escapeParts(&out, &e, &.{ "\xe2\x82", "y" }); // broken by a byte that does not continue it
    try testing.expectEqualStrings("\u{FFFD}\u{FFFD}y", out.buffered());
}

test "an escaper takes long writes and prints" {
    var buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var e: Escaper = undefined;
    e.init(&out);
    const long = &@as([1000]u8, @splat('z'));
    try e.writer.writeAll(long);
    try e.writer.print(" {d} {s}", .{ 42, "q\"" });
    try e.finish();
    try testing.expectEqualStrings(long ++ " 42 q\\\"", out.buffered());
}

test "an escaper tells whether the text needs quotes" {
    var buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var e: Escaper = undefined;
    try escapeParts(&out, &e, &.{ "abc", "-def/é" });
    try testing.expect(e.plain);
    out = .fixed(&buf);
    try escapeParts(&out, &e, &.{"a=b"});
    try testing.expect(!e.plain);
    out = .fixed(&buf);
    e.init(&out);
    e.strict = true;
    try e.writer.writeAll("a,b");
    try e.finish();
    try testing.expect(!e.plain);
}

test "an escaper with a budget stops between characters and drops the rest" {
    var buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var e: Escaper = undefined;
    e.init(&out);
    e.budget = 6;
    try e.writer.writeAll("ab€");
    try e.writer.writeAll("\ncd");
    try e.finish();
    try testing.expectEqualStrings("ab€", out.buffered()); // "\\n" would take 2 bytes more than the budget allows
    try testing.expect(e.cut);
    try testing.expectEqual(@as(usize, 5), e.count);
}

test "an escaper remembers where a cut text can end and still take a reserve" {
    var buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var e: Escaper = undefined;
    e.init(&out);
    e.budget = 8;
    e.reserve = 3;
    try e.writer.writeAll("abcd€fgh");
    try e.finish();
    try testing.expectEqualStrings("abcd€f", out.buffered());
    try testing.expect(e.cut);
    try testing.expectEqual(@as(usize, 4), e.safe_count); // "abcd": the € would leave less than 3 bytes
}

test "isBare: which text values may go without quotes" {
    try testing.expect(isBare("admin"));
    try testing.expect(isBare("café"));
    try testing.expect(isBare("a/b:c"));
    try testing.expect(!isBare(""));
    try testing.expect(!isBare("a b"));
    try testing.expect(!isBare("a=b"));
    try testing.expect(!isBare("a\"b"));
    try testing.expect(!isBare("a\\b"));
    try testing.expect(!isBare("a\nb"));
    try testing.expect(!isBare("\xff"));
}
