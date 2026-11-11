// Translated from nghttp2 (MIT, Copyright (c) 2012, 2014, 2015, 2016
// Tatsuhiro Tsujikawa; Copyright (c) 2012, 2014, 2015, 2016 nghttp2
// contributors), v1.70.0 via Anole's fork xuckless/nghttp2 0f8bc1c,
// lib/nghttp2_hd_huffman.c. See LICENSE.nghttp2 and THIRD_PARTY_NOTICES.

//! The HPACK Huffman code (RFC 7541 §5.2, Appendix B): pure functions over
//! caller buffers, no allocation. The decoder is nghttp2's 4-bit FSM
//! (Pajarola, "Fast Prefix Code Processing",
//! https://ics.uci.edu/~dan/pubs/Prefix.pdf), one-shot because HPACK gets a
//! whole header block, with an explicit output bound in the shape of Go's
//! `huffmanDecode` maxLen (x/net/http2/hpack).

const std = @import("std");
const table = @import("huffman_table.zig");

/// The encoded length of `src` in bytes, padding included
/// (nghttp2_hd_huff_encode_count). HPACK sends a string coded only when
/// this is shorter than `src.len` (nghttp2's emit_string).
pub fn encodedLen(src: []const u8) usize {
    var nbits: usize = 0;
    for (src) |c| nbits += table.sym_table[c].nbits;
    return (nbits + 7) / 8;
}

/// Encodes `src` into `dst` and returns the written prefix, padded with
/// the EOS prefix (all ones). `encodedLen(src)` bytes always suffice;
/// a shorter `dst` gives `error.NoSpaceLeft` without writing past it.
pub fn encode(dst: []u8, src: []const u8) error{NoSpaceLeft}![]u8 {
    // MSB-aligned bit accumulator; `nbits` < 32 at the top of the loop.
    var code: u64 = 0;
    var nbits: u32 = 0;
    var i: usize = 0;
    for (src) |c| {
        const sym = table.sym_table[c];
        code |= @as(u64, sym.code) << @intCast(32 - nbits);
        nbits += sym.nbits;
        if (nbits < 32) continue;
        if (dst.len - i >= 4) {
            std.mem.writeInt(u32, dst[i..][0..4], @truncate(code >> 32), .big);
            i += 4;
            code <<= 32;
            nbits -= 32;
            continue;
        }
        while (nbits >= 8) {
            if (i == dst.len) return error.NoSpaceLeft;
            dst[i] = @truncate(code >> 56);
            i += 1;
            code <<= 8;
            nbits -= 8;
        }
    }
    while (nbits >= 8) {
        if (i == dst.len) return error.NoSpaceLeft;
        dst[i] = @truncate(code >> 56);
        i += 1;
        code <<= 8;
        nbits -= 8;
    }
    if (nbits > 0) {
        if (i == dst.len) return error.NoSpaceLeft;
        const head: u8 = @truncate(code >> 56);
        dst[i] = head | (@as(u8, 0xFF) >> @intCast(nbits));
        i += 1;
    }
    return dst[0..i];
}

/// An upper bound on the decoded length of `encoded_len` coded bytes: the
/// shortest code is 5 bits (nghttp2_huff_estimate_decode_length). A `dst`
/// this long never gives `error.NoSpaceLeft`.
pub fn maxDecodedLen(encoded_len: usize) usize {
    return encoded_len * 8 / 5;
}

/// Decodes the whole coded string `src` into `dst` and returns the written
/// prefix (nghttp2_hd_huff_decode with `final` set). Never writes past
/// `dst`: one more symbol than fits gives `error.NoSpaceLeft`. Padding
/// over 7 bits, padding that is not an EOS prefix, a truncated code and
/// EOS inside the string give `error.InvalidHuffman` (RFC 7541 §5.2): the
/// table sends all of them to the sticky state `fail_state`, which is not
/// accepted and never emits. Input that is both invalid and too long for
/// `dst` may report either error; both are connection errors to HPACK.
pub fn decode(dst: []u8, src: []const u8) error{ InvalidHuffman, NoSpaceLeft }![]u8 {
    var t: table.Entry = .{ .fstate = 0, .flags = table.accepted, .sym = 0 };
    var n: usize = 0;
    for (src) |c| {
        t = table.decode_table[t.fstate][c >> 4];
        if (t.flags & table.emits != 0) {
            if (n == dst.len) return error.NoSpaceLeft;
            dst[n] = t.sym;
            n += 1;
        }
        t = table.decode_table[t.fstate][c & 0xF];
        if (t.flags & table.emits != 0) {
            if (n == dst.len) return error.NoSpaceLeft;
            dst[n] = t.sym;
            n += 1;
        }
    }
    if (t.flags & table.accepted == 0) return error.InvalidHuffman;
    return dst[0..n];
}

const testing = std.testing;

/// Encodes `plain`, checks it is `coded` and `encodedLen`, decodes it back.
fn expectVector(plain: []const u8, coded: []const u8) !void {
    var enc: [128]u8 = undefined;
    var dec: [128]u8 = undefined;
    try testing.expectEqual(coded.len, encodedLen(plain));
    try testing.expectEqualSlices(u8, coded, try encode(&enc, plain));
    try testing.expectEqualSlices(u8, plain, try decode(&dec, coded));
}

fn expectRoundTrip(plain: []const u8) !void {
    var enc: [1024]u8 = undefined;
    var dec: [1024]u8 = undefined;
    const coded = try encode(&enc, plain);
    try testing.expectEqual(encodedLen(plain), coded.len);
    const back = try decode(&dec, coded);
    try testing.expectEqualSlices(u8, plain, back);
    try testing.expect(back.len <= maxDecodedLen(coded.len));
}

// Hex copied from RFC 7541 Appendix C.4 (the string literals inside each
// request's hex dump).
test "h2 huffman: RFC 7541 C.4 request strings" {
    try expectVector("www.example.com", &.{ 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff });
    try expectVector("no-cache", &.{ 0xa8, 0xeb, 0x10, 0x64, 0x9c, 0xbf });
    try expectVector("custom-key", &.{ 0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xa9, 0x7d, 0x7f });
    try expectVector("custom-value", &.{ 0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xb8, 0xe8, 0xb4, 0xbf });
}

// Hex copied from RFC 7541 Appendix C.6.
test "h2 huffman: RFC 7541 C.6 response strings" {
    try expectVector("302", &.{ 0x64, 0x02 });
    try expectVector("private", &.{ 0xae, 0xc3, 0x77, 0x1a, 0x4b });
    try expectVector("Mon, 21 Oct 2013 20:13:21 GMT", &.{
        0xd0, 0x7a, 0xbe, 0x94, 0x10, 0x54, 0xd4, 0x44, 0xa8, 0x20, 0x05,
        0x95, 0x04, 0x0b, 0x81, 0x66, 0xe0, 0x82, 0xa6, 0x2d, 0x1b, 0xff,
    });
    try expectVector("https://www.example.com", &.{
        0x9d, 0x29, 0xad, 0x17, 0x18, 0x63, 0xc7, 0x8f, 0x0b,
        0x97, 0xc8, 0xe9, 0xae, 0x82, 0xae, 0x43, 0xd3,
    });
    try expectVector("307", &.{ 0x64, 0x0e, 0xff });
    try expectVector("Mon, 21 Oct 2013 20:13:22 GMT", &.{
        0xd0, 0x7a, 0xbe, 0x94, 0x10, 0x54, 0xd4, 0x44, 0xa8, 0x20, 0x05,
        0x95, 0x04, 0x0b, 0x81, 0x66, 0xe0, 0x84, 0xa6, 0x2d, 0x1b, 0xff,
    });
    try expectVector("gzip", &.{ 0x9b, 0xd9, 0xab });
    try expectVector("foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1", &.{
        0x94, 0xe7, 0x82, 0x1d, 0xd7, 0xf2, 0xe6, 0xc7, 0xb3, 0x35, 0xdf, 0xdf, 0xcd, 0x5b, 0x39,
        0x60, 0xd5, 0xaf, 0x27, 0x08, 0x7f, 0x36, 0x72, 0xc1, 0xab, 0x27, 0x0f, 0xb5, 0x29, 0x1f,
        0x95, 0x87, 0x31, 0x60, 0x65, 0xc0, 0x03, 0xed, 0x4e, 0xe5, 0xb1, 0x06, 0x3d, 0x50, 0x07,
    });
}

// tests/nghttp2_hd_test.c test_nghttp2_hd_huff_encode.
test "h2 huffman: nghttp2 huff_encode round trip (bytes 22..0)" {
    const t1 = [_]u8{ 22, 21, 20, 19, 18, 17, 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0 };
    try expectRoundTrip(&t1);
}

// tests/nghttp2_hd_test.c test_nghttp2_hd_huff_decode. Its "fully decoding
// EOS" case passes 2 bytes (11 one-bits of padding); EOS is the 5-byte case.
test "h2 huffman: nghttp2 huff_decode cases" {
    const e = [_]u8{ 0x1F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("a", try decode(&buf, e[0..1]));
    try testing.expectError(error.InvalidHuffman, decode(&buf, e[0..2]));
    try testing.expectError(error.InvalidHuffman, decode(&buf, e[0..5]));
    try testing.expectError(error.InvalidHuffman, decode(&buf, &e));
}

// tests/nghttp2_hd_test.c test_nghttp2_hd_inflate_zero_length_huffman.
test "h2 huffman: empty input decodes to empty" {
    var buf: [1]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), (try decode(buf[0..0], "")).len);
    try testing.expectEqual(@as(usize, 0), encodedLen(""));
    try testing.expectEqual(@as(usize, 0), (try encode(buf[0..0], "")).len);
}

// The choice rule of nghttp2's emit_string (enclen < len), as
// inflate_indname_noinc and inflate_newname_noinc rely on it.
test "h2 huffman: encodedLen picks Huffman as nghttp2's emit_string would" {
    try testing.expectEqual(@as(usize, 1), encodedLen("x"));
    for ([_][]const u8{ "nghttp2", "user-agent", "my-long-content-length" }) |s| {
        try testing.expect(encodedLen(s) < s.len);
    }
}

test "h2 huffman: every byte value round-trips" {
    var all: [256]u8 = undefined;
    for (&all, 0..) |*b, i| {
        b.* = @intCast(i);
        try expectRoundTrip(all[i .. i + 1]);
    }
    try expectRoundTrip(&all);
}

test "h2 huffman: seeded random strings round-trip" {
    var prng: std.Random.DefaultPrng = .init(0x68756666);
    const r = prng.random();
    var plain: [300]u8 = undefined;
    for (0..2000) |_| {
        const len = r.uintAtMost(usize, plain.len);
        r.bytes(plain[0..len]);
        try expectRoundTrip(plain[0..len]);
    }
}

/// Decodes `y`; if valid, the only encoding of the result must be `y`
/// (padding is unique: the shortest EOS prefix filling the last byte).
fn expectCanonical(y: []const u8) !void {
    var dec: [256]u8 = undefined;
    var enc: [256]u8 = undefined;
    const plain = decode(&dec, y) catch |err| switch (err) {
        error.InvalidHuffman => return,
        error.NoSpaceLeft => return error.TestUnexpectedResult,
    };
    try testing.expectEqualSlices(u8, y, try encode(&enc, plain));
}

test "h2 huffman: valid codes are canonical" {
    var y: [64]u8 = undefined;
    for (0..256) |a| {
        y[0] = @intCast(a);
        try expectCanonical(y[0..1]);
        for (0..256) |b| {
            y[1] = @intCast(b);
            try expectCanonical(y[0..2]);
        }
    }
    var prng: std.Random.DefaultPrng = .init(0x63616e6f);
    const r = prng.random();
    for (0..2000) |_| {
        const len = 3 + r.uintAtMost(usize, y.len - 3);
        r.bytes(y[0..len]);
        try expectCanonical(y[0..len]);
    }
}

test "h2 huffman: invalid padding is rejected" {
    var buf: [64]u8 = undefined;
    // 'a' (00011) padded with 000: not an EOS prefix.
    try testing.expectError(error.InvalidHuffman, decode(&buf, &.{0x18}));
    // A valid string plus a whole 0xFF: padding over 7 bits.
    var coded: [32]u8 = undefined;
    const www = try encode(&coded, "www.example.com");
    coded[www.len] = 0xFF;
    try testing.expectError(error.InvalidHuffman, decode(&buf, coded[0 .. www.len + 1]));
    // The first byte of '!' (10 bits, 11111110 00): a truncated code.
    try testing.expectEqual(@as(u8, 10), table.sym_table['!'].nbits);
    try testing.expectError(error.InvalidHuffman, decode(&buf, &.{0xFE}));
    // 32 one-bits (EOS is 30) and then 'a': EOS inside the string.
    try testing.expectError(error.InvalidHuffman, decode(&buf, &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0x1F }));
}

test "h2 huffman: decode never writes past dst" {
    const plain = "Mon, 21 Oct 2013 20:13:21 GMT";
    var coded_buf: [64]u8 = undefined;
    const coded = try encode(&coded_buf, plain);
    var buf: [64]u8 = undefined;
    for (0..plain.len) |len| {
        @memset(&buf, 0xAA);
        try testing.expectError(error.NoSpaceLeft, decode(buf[0..len], coded));
        for (buf[len..]) |b| try testing.expectEqual(@as(u8, 0xAA), b);
    }
    try testing.expectEqualStrings(plain, try decode(buf[0..plain.len], coded));
    try testing.expect(maxDecodedLen(coded.len) >= plain.len);
    // The bound is reached by the 5-bit codes: 8 x '0' is 40 bits, 5 bytes.
    try testing.expectEqual(@as(usize, 5), encodedLen("00000000"));
    try testing.expectEqual(@as(usize, 8), maxDecodedLen(5));
}

test "h2 huffman: encode never writes past dst" {
    const plain = "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1";
    const need = encodedLen(plain);
    var want_buf: [64]u8 = undefined;
    const want = try encode(&want_buf, plain);
    var buf: [64]u8 = undefined;
    for (0..need) |len| {
        @memset(&buf, 0xAA);
        try testing.expectError(error.NoSpaceLeft, encode(buf[0..len], plain));
        for (buf[len..]) |b| try testing.expectEqual(@as(u8, 0xAA), b);
        // Whatever was written is the right prefix.
        try testing.expectEqualSlices(u8, want[0..len], buf[0..len]);
    }
    try testing.expectEqualSlices(u8, want, try encode(buf[0..need], plain));
}

test "h2 huffman: the table matches the generator's invariants" {
    for (table.decode_table[table.fail_state]) |e| {
        try testing.expectEqual(table.fail_state, e.fstate);
        try testing.expectEqual(@as(u8, 0), e.flags);
    }
    try testing.expectEqual(@as(usize, 4), @sizeOf(table.Entry));
    try testing.expectEqual(table.Sym{ .nbits = 5, .code = 0 }, table.sym_table['0']);
    try testing.expectEqual(table.Sym{ .nbits = 5, .code = 0x18000000 }, table.sym_table['a']);
}
