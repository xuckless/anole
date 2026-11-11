//! Test vectors shared by hpack_test.zig and hpack_diff_test.zig: RFC 7541
//! Appendix C, and the blocks of nghttp2's tests/nghttp2_hd_test.c, built
//! as bytes because nghttp2's emit helpers are internal.

const std = @import("std");
const hpack = @import("hpack.zig");
const huffman = @import("huffman.zig");
const Field = hpack.Field;

pub const RfcVector = struct {
    name: []const u8,
    hex: []const u8,
    fields: []const Field,
    /// The dynamic table after the block, newest first.
    table: []const Field,
    table_size: u32,
};

/// The blocks of one RFC example: decoded in order on one decoder whose
/// table maximum is `max_table_size`.
pub const RfcGroup = struct { max_table_size: u32, vectors: []const RfcVector };

pub const rfc_groups = [_]RfcGroup{
    .{ .max_table_size = 4096, .vectors = rfc_vectors[0..1] },
    .{ .max_table_size = 4096, .vectors = rfc_vectors[1..2] },
    .{ .max_table_size = 4096, .vectors = rfc_vectors[2..3] },
    .{ .max_table_size = 4096, .vectors = rfc_vectors[3..4] },
    .{ .max_table_size = 4096, .vectors = rfc_vectors[4..7] },
    .{ .max_table_size = 4096, .vectors = rfc_vectors[7..10] },
    .{ .max_table_size = 256, .vectors = rfc_vectors[10..13] },
    .{ .max_table_size = 256, .vectors = rfc_vectors[13..16] },
};

pub fn hex(comptime s: []const u8) *const [s.len / 2]u8 {
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        var b: [s.len / 2]u8 = undefined;
        _ = std.fmt.hexToBytes(&b, s) catch unreachable;
        const out = b;
        break :blk &out;
    };
}

/// Copied from RFC 7541 Appendix C.2-C.6 (the hex dumps, header lists and
/// dynamic tables; table entries newest first).
pub const rfc_vectors = [_]RfcVector{
    .{ .name = "C.2.1", .hex = "400a637573746f6d2d6b65790d637573746f6d2d686561646572", .fields = &.{
        .{ .name = "custom-key", .value = "custom-header" },
    }, .table = &.{
        .{ .name = "custom-key", .value = "custom-header" },
    }, .table_size = 55 },
    .{ .name = "C.2.2", .hex = "040c2f73616d706c652f70617468", .fields = &.{
        .{ .name = ":path", .value = "/sample/path" },
    }, .table = &.{}, .table_size = 0 },
    .{ .name = "C.2.3", .hex = "100870617373776f726406736563726574", .fields = &.{
        .{ .name = "password", .value = "secret", .never_index = true },
    }, .table = &.{}, .table_size = 0 },
    .{ .name = "C.2.4", .hex = "82", .fields = &.{
        .{ .name = ":method", .value = "GET" },
    }, .table = &.{}, .table_size = 0 },
    .{ .name = "C.3.1", .hex = "828684410f7777772e6578616d706c652e636f6d", .fields = &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":authority", .value = "www.example.com" },
    }, .table = &.{
        .{ .name = ":authority", .value = "www.example.com" },
    }, .table_size = 57 },
    .{ .name = "C.3.2", .hex = "828684be58086e6f2d6361636865", .fields = &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":authority", .value = "www.example.com" },
        .{ .name = "cache-control", .value = "no-cache" },
    }, .table = &.{
        .{ .name = "cache-control", .value = "no-cache" },
        .{ .name = ":authority", .value = "www.example.com" },
    }, .table_size = 110 },
    .{ .name = "C.3.3", .hex = "828785bf400a637573746f6d2d6b65790c637573746f6d2d76616c7565", .fields = &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/index.html" },
        .{ .name = ":authority", .value = "www.example.com" },
        .{ .name = "custom-key", .value = "custom-value" },
    }, .table = &.{
        .{ .name = "custom-key", .value = "custom-value" },
        .{ .name = "cache-control", .value = "no-cache" },
        .{ .name = ":authority", .value = "www.example.com" },
    }, .table_size = 164 },
    .{ .name = "C.4.1", .hex = "828684418cf1e3c2e5f23a6ba0ab90f4ff", .fields = &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":authority", .value = "www.example.com" },
    }, .table = &.{
        .{ .name = ":authority", .value = "www.example.com" },
    }, .table_size = 57 },
    .{ .name = "C.4.2", .hex = "828684be5886a8eb10649cbf", .fields = &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":authority", .value = "www.example.com" },
        .{ .name = "cache-control", .value = "no-cache" },
    }, .table = &.{
        .{ .name = "cache-control", .value = "no-cache" },
        .{ .name = ":authority", .value = "www.example.com" },
    }, .table_size = 110 },
    .{ .name = "C.4.3", .hex = "828785bf408825a849e95ba97d7f8925a849e95bb8e8b4bf", .fields = &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/index.html" },
        .{ .name = ":authority", .value = "www.example.com" },
        .{ .name = "custom-key", .value = "custom-value" },
    }, .table = &.{
        .{ .name = "custom-key", .value = "custom-value" },
        .{ .name = "cache-control", .value = "no-cache" },
        .{ .name = ":authority", .value = "www.example.com" },
    }, .table_size = 164 },
    .{ .name = "C.5.1", .hex = "4803333032580770726976617465611d4d6f6e2c203231204f637420323031332032303a31333a323120474d546e1768747470733a2f2f7777772e6578616d706c652e636f6d", .fields = &.{
        .{ .name = ":status", .value = "302" },
        .{ .name = "cache-control", .value = "private" },
        .{ .name = "date", .value = "Mon, 21 Oct 2013 20:13:21 GMT" },
        .{ .name = "location", .value = "https://www.example.com" },
    }, .table = &.{
        .{ .name = "location", .value = "https://www.example.com" },
        .{ .name = "date", .value = "Mon, 21 Oct 2013 20:13:21 GMT" },
        .{ .name = "cache-control", .value = "private" },
        .{ .name = ":status", .value = "302" },
    }, .table_size = 222 },
    .{ .name = "C.5.2", .hex = "4803333037c1c0bf", .fields = &.{
        .{ .name = ":status", .value = "307" },
        .{ .name = "cache-control", .value = "private" },
        .{ .name = "date", .value = "Mon, 21 Oct 2013 20:13:21 GMT" },
        .{ .name = "location", .value = "https://www.example.com" },
    }, .table = &.{
        .{ .name = ":status", .value = "307" },
        .{ .name = "location", .value = "https://www.example.com" },
        .{ .name = "date", .value = "Mon, 21 Oct 2013 20:13:21 GMT" },
        .{ .name = "cache-control", .value = "private" },
    }, .table_size = 222 },
    .{ .name = "C.5.3", .hex = "88c1611d4d6f6e2c203231204f637420323031332032303a31333a323220474d54c05a04677a69707738666f6f3d4153444a4b48514b425a584f5157454f50495541585157454f49553b206d61782d6167653d333630303b2076657273696f6e3d31", .fields = &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "cache-control", .value = "private" },
        .{ .name = "date", .value = "Mon, 21 Oct 2013 20:13:22 GMT" },
        .{ .name = "location", .value = "https://www.example.com" },
        .{ .name = "content-encoding", .value = "gzip" },
        .{ .name = "set-cookie", .value = "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1" },
    }, .table = &.{
        .{ .name = "set-cookie", .value = "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1" },
        .{ .name = "content-encoding", .value = "gzip" },
        .{ .name = "date", .value = "Mon, 21 Oct 2013 20:13:22 GMT" },
    }, .table_size = 215 },
    .{ .name = "C.6.1", .hex = "488264025885aec3771a4b6196d07abe941054d444a8200595040b8166e082a62d1bff6e919d29ad171863c78f0b97c8e9ae82ae43d3", .fields = &.{
        .{ .name = ":status", .value = "302" },
        .{ .name = "cache-control", .value = "private" },
        .{ .name = "date", .value = "Mon, 21 Oct 2013 20:13:21 GMT" },
        .{ .name = "location", .value = "https://www.example.com" },
    }, .table = &.{
        .{ .name = "location", .value = "https://www.example.com" },
        .{ .name = "date", .value = "Mon, 21 Oct 2013 20:13:21 GMT" },
        .{ .name = "cache-control", .value = "private" },
        .{ .name = ":status", .value = "302" },
    }, .table_size = 222 },
    .{ .name = "C.6.2", .hex = "4883640effc1c0bf", .fields = &.{
        .{ .name = ":status", .value = "307" },
        .{ .name = "cache-control", .value = "private" },
        .{ .name = "date", .value = "Mon, 21 Oct 2013 20:13:21 GMT" },
        .{ .name = "location", .value = "https://www.example.com" },
    }, .table = &.{
        .{ .name = ":status", .value = "307" },
        .{ .name = "location", .value = "https://www.example.com" },
        .{ .name = "date", .value = "Mon, 21 Oct 2013 20:13:21 GMT" },
        .{ .name = "cache-control", .value = "private" },
    }, .table_size = 222 },
    .{ .name = "C.6.3", .hex = "88c16196d07abe941054d444a8200595040b8166e084a62d1bffc05a839bd9ab77ad94e7821dd7f2e6c7b335dfdfcd5b3960d5af27087f3672c1ab270fb5291f9587316065c003ed4ee5b1063d5007", .fields = &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "cache-control", .value = "private" },
        .{ .name = "date", .value = "Mon, 21 Oct 2013 20:13:22 GMT" },
        .{ .name = "location", .value = "https://www.example.com" },
        .{ .name = "content-encoding", .value = "gzip" },
        .{ .name = "set-cookie", .value = "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1" },
    }, .table = &.{
        .{ .name = "set-cookie", .value = "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1" },
        .{ .name = "content-encoding", .value = "gzip" },
        .{ .name = "date", .value = "Mon, 21 Oct 2013 20:13:22 GMT" },
    }, .table_size = 215 },
};

/// Builds header blocks byte by byte, as nghttp2's emit_* helpers would.
pub const Buf = struct {
    a: std.mem.Allocator,
    list: std.ArrayList(u8) = .empty,

    pub fn init(a: std.mem.Allocator) Buf {
        return .{ .a = a };
    }

    pub fn deinit(b: *Buf) void {
        b.list.deinit(b.a);
    }

    pub fn bytes(b: *Buf, s: []const u8) !void {
        try b.list.appendSlice(b.a, s);
    }

    /// An integer with an N-bit prefix and the representation's bits.
    pub fn int(b: *Buf, first: u8, prefix: u4, v: u64) !void {
        const k = (@as(u64, 1) << prefix) - 1;
        if (v < k) return b.list.append(b.a, first | @as(u8, @intCast(v)));
        try b.list.append(b.a, first | @as(u8, @intCast(k)));
        var r = v - k;
        while (r >= 0x80) : (r >>= 7) try b.list.append(b.a, @as(u8, @truncate(r)) | 0x80);
        try b.list.append(b.a, @intCast(r));
    }

    /// A string literal, Huffman when `huff`, or when shorter if null.
    pub fn str(b: *Buf, s: []const u8, huff: ?bool) !void {
        const n = huffman.encodedLen(s);
        if (huff orelse (n < s.len)) {
            try b.int(0x80, 7, n);
            const at = b.list.items.len;
            try b.list.resize(b.a, at + n);
            _ = huffman.encode(b.list.items[at..], s) catch unreachable;
        } else {
            try b.int(0, 7, s.len);
            try b.bytes(s);
        }
    }

    pub const Mode = enum { with, without, never };

    /// A literal with an indexed name (`idx` ≥ 1) or a new name (0).
    pub fn literal(b: *Buf, mode: Mode, idx: u64, name: []const u8, value: []const u8) !void {
        switch (mode) {
            .with => try b.int(0x40, 6, idx),
            .without => try b.int(0x00, 4, idx),
            .never => try b.int(0x10, 4, idx),
        }
        if (idx == 0) try b.str(name, null);
        try b.str(value, null);
    }

    pub fn indexed(b: *Buf, idx: u64) !void {
        try b.int(0x80, 7, idx);
    }

    pub fn sizeUpdate(b: *Buf, size: u64) !void {
        try b.int(0x20, 5, size);
    }

    /// The block built so far, owned by the caller; the buffer restarts.
    pub fn take(b: *Buf) ![]u8 {
        return b.list.toOwnedSlice(b.a);
    }
};

/// One of nghttp2's inflater tests as blocks on one fresh decoder.
pub const Case = struct { name: []const u8, blocks: []const []const u8 };

/// nghttp2_hd_test.c's inflater blocks (and the deflater cases' lists as
/// our encoder would send them is hpack_test.zig's business). Allocated
/// in `a`, which should be an arena.
pub fn portedCases(a: std.mem.Allocator) ![]Case {
    var cases: std.ArrayList(Case) = .empty;
    var b: Buf = .init(a);
    // inflate_indexed: :path / and index 0.
    try b.indexed(4);
    const indexed = try b.take();
    try b.indexed(0);
    try cases.append(a, .{ .name = "inflate_indexed", .blocks = try a.dupe([]const u8, &.{ indexed, try b.take() }) });
    // inflate_indname_noinc: user-agent (index 58), Huffman and not.
    try b.literal(.without, 58, "", "nghttp2");
    const noinc1 = try b.take();
    try b.literal(.without, 58, "", "x");
    try cases.append(a, .{ .name = "inflate_indname_noinc", .blocks = try a.dupe([]const u8, &.{ noinc1, try b.take() }) });
    try b.literal(.with, 58, "", "nghttp2");
    try cases.append(a, .{ .name = "inflate_indname_inc", .blocks = try a.dupe([]const u8, &.{try b.take()}) });
    try cases.append(a, .{ .name = "inflate_indname_inc_eviction", .blocks = try a.dupe([]const u8, &.{try indnameIncEviction(&b)}) });
    var newname: [4][]const u8 = undefined;
    for (newname_noinc, &newname) |f, *out| {
        try b.literal(.without, 0, f.name, f.value);
        out.* = try b.take();
    }
    try cases.append(a, .{ .name = "inflate_newname_noinc", .blocks = try a.dupe([]const u8, &newname) });
    try b.literal(.with, 0, "x-rel", "nghttp2");
    try cases.append(a, .{ .name = "inflate_newname_inc", .blocks = try a.dupe([]const u8, &.{try b.take()}) });
    const clear_big = try clearallInc(&b, 4060);
    try cases.append(a, .{ .name = "inflate_clearall_inc", .blocks = try a.dupe([]const u8, &.{ clear_big, clear_big, try clearallInc(&b, 4059) }) });
    try cases.append(a, .{ .name = "inflate_zero_length_huffman", .blocks = try a.dupe([]const u8, &.{&zero_length_huffman}) });
    try cases.append(a, .{ .name = "inflate_unexpected_table_size_update", .blocks = try a.dupe([]const u8, &.{&unexpected_table_size_update}) });
    try cases.append(a, .{ .name = "change_table_size", .blocks = try changeTableSize(&b) });
    return cases.toOwnedSlice(a);
}

/// inflate_indname_inc_eviction: four 1024-byte values with indexing on
/// static names 15-18 (nghttp2's 0-based 14-17); the first is evicted.
pub fn indnameIncEviction(b: *Buf) ![]u8 {
    const value: [1024]u8 = @splat('0');
    for (15..19) |i| try b.literal(.with, i, "", &value);
    return b.take();
}

/// inflate_newname_noinc: Huffman for both, neither, the name, the value.
pub const newname_noinc = [_]Field{
    .{ .name = "my-long-content-length", .value = "nghttp2" },
    .{ .name = "x", .value = "y" },
    .{ .name = "my-long-content-length", .value = "y" },
    .{ .name = "x", .value = "nghttp2" },
};

/// inflate_clearall_inc: "alpha" with a value of `n` zeros, with
/// indexing: 4060 needs 4097 bytes and empties the table, 4059 just fits.
pub fn clearallInc(b: *Buf, n: usize) ![]u8 {
    const value: [4060]u8 = @splat('0');
    try b.literal(.with, 0, "alpha", value[0..n]);
    return b.take();
}

/// inflate_zero_length_huffman: a new name "x" with indexing and a
/// zero-length Huffman value.
pub const zero_length_huffman = [_]u8{ 0x40, 0x01, 'x', 0x80 };
/// inflate_unexpected_table_size_update: :method GET, then a size update.
pub const unexpected_table_size_update = [_]u8{ 0x82, 0x20 };

/// change_table_size, inflater side: the table to 0 (an insertion is
/// dropped), back to 4096 (one fits), then 4097 (an error).
pub fn changeTableSize(b: *Buf) ![]const []const u8 {
    try b.sizeUpdate(0);
    try b.literal(.with, 0, "alpha", "bravo");
    const to0 = try b.take();
    try b.sizeUpdate(4096);
    try b.literal(.with, 0, "alpha", "bravo");
    try b.indexed(62);
    const up = try b.take();
    try b.sizeUpdate(4097);
    return b.a.dupe([]const u8, &.{ to0, up, try b.take() });
}
