//! HPACK unit, limit and fuzz tests: RFC 7541 Appendix C, the cases of
//! nghttp2's tests/nghttp2_hd_test.c, the errors, the field lifetime and
//! the header-list limits (PLAN §5.4, D15 point 4).

const std = @import("std");
const hpack = @import("hpack.zig");
const huffman = @import("huffman.zig");
const vectors = @import("hpack_vectors.zig");
const testing = std.testing;
const Field = hpack.Field;
const Buf = vectors.Buf;

const scratch_len = 256 * 1024;
const no_limit: u32 = scratch_len;

/// Decodes one block and returns copies of its fields (they are valid
/// only until the next call otherwise).
fn decodeList(a: std.mem.Allocator, d: *hpack.Decoder, input: []const u8) ![]Field {
    const scratch = try a.alloc(u8, scratch_len);
    var b = d.block(input, scratch, no_limit);
    var list: std.ArrayList(Field) = .empty;
    while (try b.next()) |f| try list.append(a, .{
        .name = try a.dupe(u8, f.name),
        .value = try a.dupe(u8, f.value),
        .never_index = f.never_index,
    });
    return list.items;
}

fn expectDecodeError(d: *hpack.Decoder, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.CompressionError, decodeList(arena.allocator(), d, input));
    // Poisoned, as nghttp2's ctx.bad: even a valid block fails now.
    try testing.expectError(error.CompressionError, decodeList(arena.allocator(), d, &.{0x82}));
}

fn expectError(input: []const u8) !void {
    var d: hpack.Decoder = .init(.{});
    try expectDecodeError(&d, input);
}

fn expectFields(want: []const Field, got: []const Field) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try testing.expectEqualStrings(w.name, g.name);
        try testing.expectEqualStrings(w.value, g.value);
        try testing.expectEqual(w.never_index, g.never_index);
    }
}

/// The dynamic table, newest first, and its RFC size, plus the invariant
/// that the size is the entries' sizes.
fn expectTable(d: *const hpack.Decoder, want: []const Field, size: u32) !void {
    var buf: [hpack.table_capacity]u8 = undefined;
    try testing.expectEqual(want.len, d.tableLen());
    for (want, 0..) |w, i| {
        const e = d.tableEntry(i, &buf);
        try testing.expectEqualStrings(w.name, e.name);
        try testing.expectEqualStrings(w.value, e.value);
    }
    try testing.expectEqual(size, d.size);
}

test "h2 hpack: RFC 7541 C.1 integers" {
    var p: usize = 0;
    // C.1.1: 10 with a 5-bit prefix, the top three bits are the
    // representation's.
    try testing.expectEqual(10, try hpack.decodeInt(&.{0xea}, &p, 5));
    try testing.expectEqual(1, p);
    p = 0;
    // C.1.2: 1337 with a 5-bit prefix.
    try testing.expectEqual(1337, try hpack.decodeInt(&.{ 0x1f, 0x9a, 0x0a }, &p, 5));
    try testing.expectEqual(3, p);
    p = 0;
    // C.1.3: 42 at an octet boundary.
    try testing.expectEqual(42, try hpack.decodeInt(&.{0x2a}, &p, 8));
}

test "h2 hpack: RFC 7541 C.2-C.6 vectors, the table after each block" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for (vectors.rfc_groups) |g| {
        var d: hpack.Decoder = .init(.{ .max_table_size = g.max_table_size });
        for (g.vectors) |v| {
            const bytes = try arena.allocator().alloc(u8, v.hex.len / 2);
            _ = try std.fmt.hexToBytes(bytes, v.hex);
            try expectFields(v.fields, try decodeList(arena.allocator(), &d, bytes));
            try expectTable(&d, v.table, v.table_size);
        }
    }
}

test "h2 hpack: nghttp2 inflate_indexed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d: hpack.Decoder = .init(.{});
    try expectFields(&.{.{ .name = ":path", .value = "/" }}, try decodeList(arena.allocator(), &d, &.{0x84}));
    // Index 0 is an error.
    try expectDecodeError(&d, &.{0x80});
}

test "h2 hpack: nghttp2 inflate_indname_noinc and _inc" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b: Buf = .init(a);
    var d: hpack.Decoder = .init(.{});
    for ([_][]const u8{ "nghttp2", "x" }) |v| {
        try b.literal(.without, 58, "", v);
        try expectFields(&.{.{ .name = "user-agent", .value = v }}, try decodeList(a, &d, try b.take()));
        try testing.expectEqual(0, d.tableLen());
    }
    try b.literal(.with, 58, "", "nghttp2");
    try expectFields(&.{.{ .name = "user-agent", .value = "nghttp2" }}, try decodeList(a, &d, try b.take()));
    try expectTable(&d, &.{.{ .name = "user-agent", .value = "nghttp2" }}, 10 + 7 + 32);
}

test "h2 hpack: nghttp2 inflate_indname_inc_eviction" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var b: Buf = .init(arena.allocator());
    var d: hpack.Decoder = .init(.{});
    const got = try decodeList(arena.allocator(), &d, try vectors.indnameIncEviction(&b));
    try testing.expectEqual(4, got.len);
    try testing.expectEqualStrings("accept-charset", got[0].name);
    try testing.expectEqual(1024, got[0].value.len);
    try testing.expectEqual(3, d.tableLen());
}

test "h2 hpack: nghttp2 inflate_newname_noinc and _inc" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b: Buf = .init(a);
    var d: hpack.Decoder = .init(.{});
    for (vectors.newname_noinc) |f| {
        try b.literal(.without, 0, f.name, f.value);
        try expectFields(&.{f}, try decodeList(a, &d, try b.take()));
        try testing.expectEqual(0, d.tableLen());
    }
    try b.literal(.with, 0, "x-rel", "nghttp2");
    try expectFields(&.{.{ .name = "x-rel", .value = "nghttp2" }}, try decodeList(a, &d, try b.take()));
    try expectTable(&d, &.{.{ .name = "x-rel", .value = "nghttp2" }}, 5 + 7 + 32);
}

test "h2 hpack: nghttp2 inflate_clearall_inc (4097 empties the table, 4096 fits)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b: Buf = .init(a);
    var d: hpack.Decoder = .init(.{});
    const big = try vectors.clearallInc(&b, 4060);
    for (0..2) |_| {
        const got = try decodeList(a, &d, big);
        try testing.expectEqual(1, got.len);
        try testing.expectEqual(4060, got[0].value.len);
        try testing.expectEqual(0, d.tableLen());
        try testing.expectEqual(0, d.size);
    }
    const got = try decodeList(a, &d, try vectors.clearallInc(&b, 4059));
    try testing.expectEqual(4059, got[0].value.len);
    try testing.expectEqual(1, d.tableLen());
    try testing.expectEqual(4096, d.size);
}

test "h2 hpack: nghttp2 inflate_zero_length_huffman" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d: hpack.Decoder = .init(.{});
    try expectFields(&.{.{ .name = "x", .value = "" }}, try decodeList(arena.allocator(), &d, &vectors.zero_length_huffman));
}

test "h2 hpack: nghttp2 inflate_unexpected_table_size_update" {
    try expectError(&vectors.unexpected_table_size_update);
}

test "h2 hpack: nghttp2 change_table_size, inflater side" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var b: Buf = .init(arena.allocator());
    const blocks = try vectors.changeTableSize(&b);
    var d: hpack.Decoder = .init(.{});
    const ab: Field = .{ .name = "alpha", .value = "bravo" };
    try expectFields(&.{ab}, try decodeList(arena.allocator(), &d, blocks[0]));
    try testing.expectEqual(0, d.max_size);
    try testing.expectEqual(0, d.tableLen());
    try expectFields(&.{ ab, ab }, try decodeList(arena.allocator(), &d, blocks[1]));
    try testing.expectEqual(4096, d.max_size);
    try expectTable(&d, &.{ab}, 5 + 5 + 32);
    try expectDecodeError(&d, blocks[2]);
}

test "h2 hpack: several size updates at the block start, and an empty block" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d: hpack.Decoder = .init(.{});
    // The table filled, then 0 (evicts all) then 100.
    _ = try decodeList(arena.allocator(), &d, vectors.hex("400a637573746f6d2d6b65790d637573746f6d2d686561646572"));
    try testing.expectEqual(1, d.tableLen());
    try testing.expectEqual(0, (try decodeList(arena.allocator(), &d, &.{ 0x20, 0x3f, 0x45 })).len);
    try testing.expectEqual(0, d.tableLen());
    try testing.expectEqual(100, d.max_size);
    try testing.expectEqual(0, (try decodeList(arena.allocator(), &d, "")).len);
}

test "h2 hpack: nghttp2 decode_length" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var b: Buf = .init(arena.allocator());
    try b.int(0, 7, std.math.maxInt(u32));
    const max = try b.take();
    var p: usize = 0;
    try testing.expectEqual(std.math.maxInt(u32), try hpack.decodeInt(max, &p, 7));
    try testing.expectEqual(max.len, p);
    // Truncated anywhere: an error (a complete block can't continue it).
    for (0..max.len) |n| {
        p = 0;
        try testing.expectError(error.CompressionError, hpack.decodeInt(max[0..n], &p, 7));
    }
    try b.int(0, 7, 1 << 32);
    p = 0;
    try testing.expectError(error.CompressionError, hpack.decodeInt(try b.take(), &p, 7));
    // The shift past 32 bits, with zero continuations.
    p = 0;
    try testing.expectError(error.CompressionError, hpack.decodeInt(&.{ 255, 128, 128, 128, 128, 128, 1 }, &p, 8));
}

test "h2 hpack: nghttp2 no_index (the flag kept on decode)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fields = [_]Field{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":method", .value = "POST", .never_index = true },
        .{ .name = ":path", .value = "/foo", .never_index = true },
        .{ .name = "version", .value = "HTTP/1.1", .never_index = true },
        .{ .name = ":method", .value = "GET", .never_index = true },
    };
    var e: hpack.Encoder = .{};
    var out: [256]u8 = undefined;
    const n = try e.encode(&out, &fields);
    var d: hpack.Decoder = .init(.{});
    try expectFields(&fields, try decodeList(arena.allocator(), &d, out[0..n]));
}

// The errors: each a CompressionError that poisons the decoder.

test "h2 hpack: an integer overflow and the shift cap are errors" {
    // A never-indexed literal's 4-bit index, continued past 32 bits.
    try expectError(&.{ 0x1f, 0xff, 0xff, 0xff, 0xff, 0xff });
    // An index whose sixth continuation byte would shift by 35.
    try expectError(&.{ 0xff, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01 });
    // A string length one past u32.
    try expectError(&.{ 0x40, 0x7f, 0x81, 0xff, 0xff, 0xff, 0x0f });
}

test "h2 hpack: a size update above SETTINGS_HEADER_TABLE_SIZE is an error" {
    // 4097 = 31 + 4066.
    try expectError(&.{ 0x3f, 0xe2, 0x1f });
    var d: hpack.Decoder = .init(.{ .max_table_size = 256 });
    try expectDecodeError(&d, &.{ 0x3f, 0xe2, 0x01 }); // 257
}

test "h2 hpack: a size update after a field is an error" {
    try expectError(&.{ 0x82, 0x20 });
    try expectError(&.{ 0x20, 0x82, 0x3f, 0x01 });
}

test "h2 hpack: index 0 and an index past the table are errors" {
    try expectError(&.{0x80});
    try expectError(&.{0xbe}); // 62 on an empty table
    try expectError(&.{ 0x7e, 0x01, 'x' }); // an indexed name 62
    try expectError(&.{ 0x0f, 0x2f, 0x01, 'x' }); // 62, without indexing
}

test "h2 hpack: truncated blocks are errors" {
    try expectError(&.{0xff}); // an index whose continuation is missing
    try expectError(&.{0x40}); // a new name, no length
    try expectError(&.{ 0x40, 0x05, 'a', 'b' }); // a name past the block
    try expectError(&.{ 0x40, 0x01, 'x' }); // no value
    try expectError(&.{ 0x40, 0x01, 'x', 0x83, 0x9c }); // inside a Huffman value
    try expectError(&.{ 0x44, 0x7f }); // a value length cut short
}

test "h2 hpack: invalid Huffman is an error" {
    // EOS (30 ones) inside the string.
    try expectError(&.{ 0x40, 0x01, 'x', 0x84, 0xff, 0xff, 0xff, 0xff });
    // 'a' (00011) and 11 bits of padding.
    try expectError(&.{ 0x40, 0x01, 'x', 0x82, 0x1f, 0xff });
    // 'a' and padding that is not all ones.
    try expectError(&.{ 0x40, 0x01, 'x', 0x81, 0x18 });
}

test "h2 hpack: a string longer than 65536 bytes is an error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var b: Buf = .init(arena.allocator());
    const long = try arena.allocator().alloc(u8, hpack.max_string_len + 1);
    @memset(long, 'a');
    try b.literal(.without, 0, "x", long);
    // Raw, not Huffman: Buf would pick Huffman for 'a's.
    var raw: Buf = .init(arena.allocator());
    try raw.bytes(&.{ 0x00, 0x01, 'x' });
    try raw.str(long, false);
    try expectError(try raw.take());
    // 65536 itself is fine.
    try raw.bytes(&.{ 0x00, 0x01, 'x' });
    try raw.str(long[0..hpack.max_string_len], false);
    var d: hpack.Decoder = .init(.{});
    const got = try decodeList(arena.allocator(), &d, try raw.take());
    try testing.expectEqual(hpack.max_string_len, got[0].value.len);
}

/// Fills `d` so that the oldest entry is `x-big: <2000 'b'>` at ring
/// offset 1001, the newest (index 62) is `h: <980 bytes>` wrapping past
/// the ring's end, and the head sits at 892, just before x-big.
fn fillForWrap(a: std.mem.Allocator, d: *hpack.Decoder) ![]u8 {
    var b: Buf = .init(a);
    const f: [1000]u8 = @splat('f');
    const big: [2000]u8 = @splat('b');
    var h: [980]u8 = undefined;
    for (&h, 0..) |*c, i| c.* = @intCast(i % 251);
    try b.literal(.with, 0, "f", &f);
    try b.literal(.with, 0, "x-big", &big);
    try b.literal(.with, 0, "g", &f);
    try b.literal(.with, 0, "h", &h);
    _ = try decodeList(a, d, try b.take());
    try testing.expectEqual(3, d.tableLen());
    try testing.expectEqual(892, d.head);
    return a.dupe(u8, &h);
}

test "h2 hpack: an entry straddling the ring end is emitted whole" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d: hpack.Decoder = .init(.{});
    const h = try fillForWrap(arena.allocator(), &d);
    try expectFields(&.{.{ .name = "h", .value = h }}, try decodeList(arena.allocator(), &d, &.{0xbe}));
    // As the name of a literal too.
    try expectFields(&.{.{ .name = "h", .value = "v" }}, try decodeList(arena.allocator(), &d, &.{ 0x0f, 0x2f, 0x01, 'v' }));
}

test "h2 hpack: an indexed-name literal that evicts its own name entry" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: hpack.Decoder = .init(.{});
    _ = try fillForWrap(a, &d);
    // Index 64 is x-big. A 2500-byte value with indexing evicts x-big and
    // g, and the new entry's bytes, written from 892, cover x-big's old
    // name at 1001: a name read from the ring after the insertion would
    // be "vvvvv".
    var b: Buf = .init(a);
    const v: [2500]u8 = @splat('v');
    try b.int(0x40, 6, 64);
    try b.str(&v, false);
    try b.indexed(62);
    const got = try decodeList(a, &d, try b.take());
    try testing.expectEqual(2, got.len);
    try testing.expectEqualStrings("x-big", got[0].name);
    try testing.expectEqualStrings(&v, got[0].value);
    try testing.expectEqualStrings("x-big", got[1].name);
    try testing.expectEqualStrings(&v, got[1].value);
    try testing.expectEqual(2, d.tableLen());
    try testing.expectEqual(5 + 2500 + 32 + 1 + 980 + 32, d.size);
}

test "h2 limits: HPACK bomb (dynamic-table references past max_header_list_size)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b: Buf = .init(a);
    // One 4000-byte entry (4032 with its overhead), then 1000 one-byte
    // references to it: about 4 MB of header list from 5 KB.
    const z: [3999]u8 = @splat('z');
    try b.literal(.with, 0, "b", &z);
    for (0..1000) |_| try b.indexed(62);
    const limit: u32 = 64 * 1024;
    const scratch = try a.alloc(u8, limit);
    var d: hpack.Decoder = .init(.{});
    var blk = d.block(try b.take(), scratch, limit);
    var fields: usize = 0;
    var bytes: usize = 0;
    const err = while (true) {
        const f = blk.next() catch |err| break err;
        const field = f orelse return error.TestUnexpectedResult;
        fields += 1;
        bytes += field.name.len + field.value.len + 32;
    };
    try testing.expectEqual(error.HeaderListTooLarge, err);
    try testing.expectEqual(16, fields);
    try testing.expect(bytes <= limit);
    try testing.expect(blk.list_size <= limit);
    // The rest only matters for the table: references cost nothing to
    // skip, and the connection goes on.
    try blk.skipRest();
    try testing.expectEqual(1, d.tableLen());
    try expectFields(&.{.{ .name = "b", .value = &z }}, try decodeList(a, &d, &.{0xbe}));
}

test "h2 limits: HPACK copy amplification (skipRest stops at twice the limit)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b: Buf = .init(a);
    // A 4000-byte name, then literals with indexing on it with empty
    // values: each copies the name and inserts it again.
    const n: [4000]u8 = @splat('n');
    try b.int(0x40, 6, 0);
    try b.str(&n, false);
    try b.str("", false);
    for (0..9) |_| try b.bytes(&.{ 0x7e, 0x00 });
    const limit: u32 = 8192;
    const scratch = try a.alloc(u8, limit);
    var d: hpack.Decoder = .init(.{});
    var blk = d.block(try b.take(), scratch, limit);
    try testing.expect((try blk.next()) != null);
    try testing.expect((try blk.next()) != null);
    try testing.expectError(error.HeaderListTooLarge, blk.next());
    try testing.expectError(error.HeaderBlockTooCostly, blk.skipRest());
    try testing.expect(blk.list_size <= 2 * limit);
    // A connection error: the decoder is done.
    try testing.expectError(error.CompressionError, decodeList(a, &d, &.{0x82}));
}

test "h2 hpack: a Huffman string past the list budget is refused, then skipped" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b: Buf = .init(a);
    const v: [6000]u8 = @splat('0');
    try b.literal(.with, 0, "x", &v); // Huffman: 5 bits per '0'
    try b.indexed(2);
    const limit: u32 = 4096;
    const scratch = try a.alloc(u8, 8192);
    var d: hpack.Decoder = .init(.{});
    var blk = d.block(try b.take(), scratch, limit);
    try testing.expectError(error.HeaderListTooLarge, blk.next());
    try blk.skipRest();
    // Too big for the table: it empties it.
    try testing.expectEqual(0, d.tableLen());
    try testing.expectEqual(0, (try decodeList(a, &d, "")).len);
}

test "h2 hpack: a block started before the last one finished poisons the decoder" {
    var d: hpack.Decoder = .init(.{});
    var scratch: [hpack.table_capacity]u8 = undefined;
    var blk = d.block(&.{ 0x82, 0x84 }, &scratch, 4096);
    _ = try blk.next();
    var blk2 = d.block(&.{0x82}, &scratch, 4096);
    try testing.expectError(error.CompressionError, blk2.next());
}

// The encoder.

fn encodeOne(e: *hpack.Encoder, buf: []u8, f: Field) ![]u8 {
    const n = try e.encode(buf, &.{f});
    return buf[0..n];
}

test "h2 hpack: encoder static matches, literals and the first size update" {
    var e: hpack.Encoder = .{};
    var buf: [128]u8 = undefined;
    // The connection's first block starts with a size update to 0.
    try testing.expectEqualSlices(u8, &.{ 0x20, 0x82 }, try encodeOne(&e, &buf, .{ .name = ":method", .value = "GET" }));
    try testing.expectEqualSlices(u8, &.{0x82}, try encodeOne(&e, &buf, .{ .name = ":method", .value = "GET" }));
    try testing.expectEqualSlices(u8, &.{0x88}, try encodeOne(&e, &buf, .{ .name = ":status", .value = "200" }));
    try testing.expectEqualSlices(u8, &.{0x8e}, try encodeOne(&e, &buf, .{ .name = ":status", .value = "500" }));
    // A static name, without indexing; raw "x" (Huffman isn't shorter).
    try testing.expectEqualSlices(u8, &.{ 0x08, 0x01, 'x' }, try encodeOne(&e, &buf, .{ .name = ":status", .value = "x" }));
    try testing.expectEqualSlices(u8, &.{ 0x0f, 0x2b, 0x01, 'x' }, try encodeOne(&e, &buf, .{ .name = "user-agent", .value = "x" }));
    // A new name.
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x01, 'q', 0x01, 'x' }, try encodeOne(&e, &buf, .{ .name = "q", .value = "x" }));
    // Huffman when shorter: "nghttp2" codes in 5 bytes.
    const ng = try encodeOne(&e, &buf, .{ .name = "q", .value = "nghttp2" });
    try testing.expectEqual(0x80 | 5, ng[3]);
    try testing.expectEqual(4 + 5, ng.len);
}

test "h2 hpack: encoder keeps the first size update across a NoSpaceLeft" {
    var e: hpack.Encoder = .{};
    var buf: [128]u8 = undefined;
    const f: Field = .{ .name = "x-custom", .value = "value" };
    // The size update fits, the field doesn't: the retry must still send it.
    try testing.expectError(error.NoSpaceLeft, e.encode(buf[0..3], &.{f}));
    try testing.expect(e.size_update_pending);
    const n = try e.encode(&buf, &.{f});
    try testing.expectEqual(0x20, buf[0]);
    try testing.expect(!e.size_update_pending);
    try testing.expectEqual(0x00, (try encodeOne(&e, &buf, f))[0]);
    try testing.expect(n > 1);
}

test "h2 hpack: encoder never indexes authorization, short cookies and flagged fields" {
    var e: hpack.Encoder = .{ .size_update_pending = false };
    var buf: [128]u8 = undefined;
    try testing.expectEqualSlices(u8, &.{ 0x1f, 0x08, 0x01, 'x' }, try encodeOne(&e, &buf, .{ .name = "authorization", .value = "x" }));
    try testing.expectEqualSlices(u8, &.{ 0x1f, 0x11, 0x01, 'x' }, try encodeOne(&e, &buf, .{ .name = "cookie", .value = "x" }));
    const twenty: [20]u8 = @splat('a');
    const c20 = try encodeOne(&e, &buf, .{ .name = "cookie", .value = &twenty });
    try testing.expectEqualSlices(u8, &.{ 0x0f, 0x11 }, c20[0..2]);
    // Name-only search: no indexed match when never indexed.
    try testing.expectEqualSlices(u8, &.{ 0x12, 0x03, 'G', 'E', 'T' }, try encodeOne(&e, &buf, .{ .name = ":method", .value = "GET", .never_index = true }));
}

test "h2 hpack: encoder output round-trips through the decoder within bound()" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(0x68706163);
    const r = prng.random();
    var e: hpack.Encoder = .{};
    var d: hpack.Decoder = .init(.{});
    // The RFC lists first, then random ones.
    for (vectors.rfc_groups) |g| for (g.vectors) |v| {
        const out = try a.alloc(u8, hpack.Encoder.bound(v.fields));
        const n = try e.encode(out, v.fields);
        try expectFields(v.fields, try decodeList(a, &d, out[0..n]));
    };
    const names = [_][]const u8{ ":method", ":path", "cookie", "authorization", "content-type", "x-custom", "" };
    for (0..500) |_| {
        var fields: [8]Field = undefined;
        const count = r.uintAtMost(usize, fields.len);
        for (fields[0..count]) |*f| {
            const name = if (r.boolean()) names[r.uintLessThan(usize, names.len)] else try randomBytes(a, r, 12);
            f.* = .{ .name = name, .value = try randomBytes(a, r, 40), .never_index = r.uintLessThan(u8, 8) == 0 };
            if (r.uintLessThan(u8, 4) == 0) f.* = hpack.static_table[r.uintLessThan(usize, hpack.static_table.len)];
        }
        const bound = hpack.Encoder.bound(fields[0..count]);
        const out = try a.alloc(u8, bound);
        const n = try e.encode(out, fields[0..count]);
        try testing.expect(n <= bound);
        const got = try decodeList(a, &d, out[0..n]);
        try testing.expectEqual(count, got.len);
        for (fields[0..count], got) |w, g| {
            try testing.expectEqualStrings(w.name, g.name);
            try testing.expectEqualStrings(w.value, g.value);
        }
        // One byte short never writes past the buffer.
        if (n > 0) {
            var e2: hpack.Encoder = .{ .size_update_pending = false };
            try testing.expectError(error.NoSpaceLeft, e2.encode(out[0 .. n - 1], fields[0..count]));
        }
    }
    try testing.expectEqual(0, d.tableLen());
}

// The memo: `encode` must give `encodeUncached`'s bytes, hit or miss.

/// Encodes `fields` both ways from the same state and checks the bytes.
fn expectSameAsUncached(a: std.mem.Allocator, e: *hpack.Encoder, fields: []const Field) ![]u8 {
    const want = try a.alloc(u8, hpack.Encoder.bound(fields));
    var ref = e.*;
    const wn = try ref.encodeUncached(want, fields);
    const got = try a.alloc(u8, hpack.Encoder.bound(fields));
    const n = try e.encode(got, fields);
    try testing.expectEqualSlices(u8, want[0..wn], got[0..n]);
    try testing.expectEqual(ref.size_update_pending, e.size_update_pending);
    return got[0..n];
}

test "h2 hpack: memoized blocks equal uncached ones, first pass and all-hit second" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(0x6d656d6f);
    const r = prng.random();
    var lists: std.ArrayList([]const Field) = .empty;
    for (vectors.rfc_groups) |g| for (g.vectors) |v| try lists.append(a, v.fields);
    const names = [_][]const u8{ ":status", "content-type", "date", "cookie", "authorization", "grpc-status", "x-custom", "" };
    for (0..300) |_| {
        const fields = try a.alloc(Field, r.uintAtMost(usize, 8));
        for (fields) |*f| {
            const name = if (r.boolean()) names[r.uintLessThan(usize, names.len)] else try randomBytes(a, r, 30);
            f.* = .{ .name = name, .value = try randomBytes(a, r, 120), .never_index = r.uintLessThan(u8, 8) == 0 };
            if (r.uintLessThan(u8, 4) == 0) f.* = hpack.static_table[r.uintLessThan(usize, hpack.static_table.len)];
        }
        try lists.append(a, fields);
    }
    hpack.memoReset();
    var e: hpack.Encoder = .{};
    for (0..2) |_| for (lists.items) |fields| {
        _ = try expectSameAsUncached(a, &e, fields);
    };
    try testing.expect(hpack.memoStats().hits > 0);
}

test "h2 hpack: a memo hit needs the same name, value and never flag" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    hpack.memoReset();
    var e: hpack.Encoder = .{ .size_update_pending = false };
    const f: Field = .{ .name = "x-custom", .value = "nghttp2" };
    _ = try expectSameAsUncached(a, &e, &.{f});
    _ = try expectSameAsUncached(a, &e, &.{f});
    try testing.expectEqual(1, hpack.memoStats().hits);
    // Another value, another name: misses with their own bytes.
    _ = try expectSameAsUncached(a, &e, &.{.{ .name = "x-custom", .value = "nghttp3" }});
    _ = try expectSameAsUncached(a, &e, &.{.{ .name = "x-customs", .value = "nghttp2" }});
    try testing.expectEqual(1, hpack.memoStats().hits);
    try testing.expectEqual(3, hpack.memoStats().misses);
    // Never indexed: the 0x10 representation, never from or into the memo.
    const nv = try expectSameAsUncached(a, &e, &.{.{ .name = "x-custom", .value = "nghttp2", .never_index = true }});
    try testing.expectEqual(0x10, nv[0]);
    try testing.expectEqual(1, hpack.memoStats().hits);
    try testing.expectEqual(3, hpack.memoStats().stores);
}

test "h2 hpack: secrets and fields over the cap are never memoized" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    hpack.memoReset();
    var e: hpack.Encoder = .{ .size_update_pending = false };
    const long: [97 - 4]u8 = @splat('v');
    const fields = [_]Field{
        .{ .name = "authorization", .value = "Bearer x" },
        .{ .name = "cookie", .value = "short" },
        .{ .name = "x-a", .value = "flagged", .never_index = true },
        // name + value = 97 bytes, one past the cap.
        .{ .name = "x-ab", .value = &long },
    };
    for (0..2) |_| _ = try expectSameAsUncached(a, &e, &fields);
    const st = hpack.memoStats();
    try testing.expectEqual(0, st.hits + st.misses + st.stores);
    // Exactly at the cap it is kept.
    const at = [_]Field{.{ .name = "x-ab", .value = long[1..] }};
    for (0..2) |_| _ = try expectSameAsUncached(a, &e, &at);
    try testing.expectEqual(1, hpack.memoStats().hits);
}

test "h2 hpack: colliding memo slots return each field's own bytes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    hpack.memoReset();
    var e: hpack.Encoder = .{ .size_update_pending = false };
    // 40 keys into 32 slots, in turn, three rounds.
    var fields: [40]Field = undefined;
    for (&fields, 0..) |*f, i| f.* = .{ .name = "x-key", .value = try std.fmt.allocPrint(a, "value-{d}", .{i}) };
    for (0..3) |_| for (fields) |f| {
        _ = try expectSameAsUncached(a, &e, &.{f});
    };
    const st = hpack.memoStats();
    try testing.expectEqual(120, st.hits + st.misses);
    try testing.expect(st.misses >= 40);
}

test "h2 hpack: a memo hit that doesn't fit is NoSpaceLeft, and keeps the size update" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    hpack.memoReset();
    const f: Field = .{ .name = "content-type", .value = "application/grpc" };
    // Into the memo from another connection's encoder.
    var other: hpack.Encoder = .{};
    _ = try expectSameAsUncached(a, &other, &.{f});
    var e: hpack.Encoder = .{};
    var buf: [64]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, e.encode(buf[0..4], &.{f}));
    try testing.expectError(error.NoSpaceLeft, e.encodeUncached(buf[0..4], &.{f}));
    try testing.expect(e.size_update_pending);
    // The first block through a hit starts with the size update, the
    // second doesn't.
    const first = try expectSameAsUncached(a, &e, &.{f});
    try testing.expectEqual(0x20, first[0]);
    const second = try expectSameAsUncached(a, &e, &.{f});
    try testing.expectEqualSlices(u8, first[1..], second);
    try testing.expectEqual(3, hpack.memoStats().hits);
}

test "h2 hpack: encodeStatus writes what encode writes for :status" {
    for ([_]u16{ 100, 103, 200, 201, 204, 206, 304, 400, 404, 421, 500, 503, 999 }) |code| {
        var digits: [3]u8 = undefined;
        _ = try std.fmt.bufPrint(&digits, "{d}", .{code});
        const f = [_]Field{.{ .name = ":status", .value = &digits }};
        for ([_]bool{ true, false }) |pending| {
            var e1: hpack.Encoder = .{ .size_update_pending = pending };
            var e2 = e1;
            var b1: [32]u8 = undefined;
            var b2: [32]u8 = undefined;
            const n1 = try e1.encodeUncached(&b1, &f);
            const n2 = try e2.encodeStatus(&b2, code);
            try testing.expectEqualSlices(u8, b1[0..n1], b2[0..n2]);
            try testing.expect(!e2.size_update_pending);
            try testing.expect(n2 <= hpack.Encoder.bound(&f));
        }
    }
}

test "h2 hpack: nghttp2 deflate_bound" {
    const fields = [_]Field{ .{ .name = ":method", .value = "GET" }, .{ .name = "alpha", .value = "bravo" } };
    try testing.expectEqual(12 + 6 * 2 * 2 + 7 + 3 + 5 + 5, hpack.Encoder.bound(&fields));
}

fn randomBytes(a: std.mem.Allocator, r: std.Random, max: usize) ![]u8 {
    const s = try a.alloc(u8, r.uintAtMost(usize, max));
    if (r.boolean()) {
        for (s) |*c| c.* = "abcdefghij-/0123456789"[r.uintLessThan(usize, 22)];
    } else r.bytes(s);
    return s;
}

/// Decodes the input as several blocks on one decoder (the first byte,
/// if nonzero, is the length of each block) and checks the invariants:
/// never a crash, the table's size is its entries' and within its
/// maximum, every field points into the input, the scratch or the ring,
/// and the emitted list stays within the limit.
fn fuzzDecode(input: []const u8) !void {
    if (input.len == 0) return;
    const chunk: usize = if (input[0] == 0) input.len else input[0];
    var rest = input[1..];
    var d: hpack.Decoder = .init(.{});
    var scratch: [2 * hpack.table_capacity]u8 = undefined;
    const limit: u32 = hpack.table_capacity;
    while (true) {
        const blk_bytes = rest[0..@min(chunk, rest.len)];
        rest = rest[blk_bytes.len..];
        var blk = d.block(blk_bytes, &scratch, limit);
        var emitted: u64 = 0;
        const ok = while (true) {
            const f = (blk.next() catch |err| switch (err) {
                error.HeaderListTooLarge => break if (blk.skipRest()) |_| true else |_| false,
                else => break false,
            }) orelse break true;
            emitted += f.name.len + f.value.len + 32;
            try testing.expect(emitted <= limit);
            for ([_][]const u8{ f.name, f.value }) |s| try testing.expect(within(s, blk_bytes) or within(s, &scratch) or within(s, &d.bytes) or isStatic(s));
        };
        try testing.expect(d.size <= d.max_size);
        var sum: u64 = 0;
        var buf: [hpack.table_capacity]u8 = undefined;
        for (0..d.tableLen()) |i| {
            const e = d.tableEntry(i, &buf);
            sum += e.name.len + e.value.len + 32;
        }
        try testing.expectEqual(d.size, sum);
        if (!ok) {
            var after = d.block("", &scratch, limit);
            try testing.expectError(error.CompressionError, after.next());
            return;
        }
        if (rest.len == 0) return;
    }
}

fn within(s: []const u8, region: []const u8) bool {
    const p = @intFromPtr(s.ptr);
    const r = @intFromPtr(region.ptr);
    return s.len == 0 or (p >= r and p + s.len <= r + region.len);
}

fn isStatic(s: []const u8) bool {
    for (hpack.static_table) |f| if (s.ptr == f.name.ptr or s.ptr == f.value.ptr) return true;
    return false;
}

test "fuzz: h2 hpack decode" {
    var seeds: [vectors.rfc_vectors.len + 4][]const u8 = undefined;
    var bufs: [vectors.rfc_vectors.len][512]u8 = undefined;
    for (vectors.rfc_vectors, &bufs, 0..) |v, *buf, i| {
        buf[0] = 0;
        const b = try std.fmt.hexToBytes(buf[1..], v.hex);
        seeds[i] = buf[0 .. 1 + b.len];
    }
    const n = vectors.rfc_vectors.len;
    seeds[n] = &([_]u8{0} ++ vectors.zero_length_huffman);
    seeds[n + 1] = &([_]u8{0} ++ vectors.unexpected_table_size_update);
    seeds[n + 2] = &.{ 1, 0x20, 0x82, 0x84, 0xbe, 0x3f, 0x45 };
    seeds[n + 3] = vectors.hex("1a" ++ "400a637573746f6d2d6b65790d637573746f6d2d686561646572" ++ "be7e0161");
    try @import("../fuzz.zig").bytes(fuzzDecode, &seeds);
}
