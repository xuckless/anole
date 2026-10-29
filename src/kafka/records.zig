//! Record batch format v2 (magic 2): encoding a producer's batch and
//! decoding a fetch response's. CRC-32C over everything after the CRC field,
//! varint-coded records, headers, and the batch-level compression codecs.
const std = @import("std");
const protocol = @import("protocol.zig");
const compress = @import("compress.zig");

const Enc = protocol.Enc;
const Dec = protocol.Dec;
pub const Codec = compress.Codec;

pub const Header = struct { key: []const u8, value: ?[]const u8 = null };

/// A record to encode.
pub const Rec = struct {
    key: ?[]const u8 = null,
    value: ?[]const u8 = null,
    headers: []const Header = &.{},
    timestamp_ms: i64,
};

/// A decoded record; slices point into the decoded data.
pub const Record = struct {
    offset: i64,
    timestamp_ms: i64,
    key: ?[]const u8,
    value: ?[]const u8,
    headers: []const Header,
};

pub const EncodeOptions = struct {
    codec: Codec = .none,
    producer_id: i64 = -1,
    producer_epoch: i16 = -1,
    base_sequence: i32 = -1,
};

/// The fixed part of a batch before the records: baseOffset (8), length
/// (4), leader epoch (4), magic (1), crc (4), attributes (2), last offset
/// delta (4), timestamps (16), producer id (8), epoch (2), base sequence
/// (4), record count (4).
pub const header_len = 61;
const crc_at = 17;
const attributes_at = 21;

fn crc32c(data: []const u8) u32 {
    return std.hash.crc.@"CRC-32/ISCSI".hash(data);
}

/// One batch holding `recs` (at least one), owned by the caller.
pub fn encodeBatch(gpa: std.mem.Allocator, recs: []const Rec, opts: EncodeOptions) ![]u8 {
    std.debug.assert(recs.len > 0);
    var body: Enc = .init(gpa);
    defer body.deinit();
    var rec: Enc = .init(gpa);
    defer rec.deinit();
    const first_ts = recs[0].timestamp_ms;
    var max_ts = first_ts;
    for (recs, 0..) |r, i| {
        rec.buf.clearRetainingCapacity();
        try rec.i8_(0);
        try rec.varlong(r.timestamp_ms - first_ts);
        try rec.varint(@intCast(i));
        if (r.key) |k| {
            try rec.varint(@intCast(k.len));
            try rec.raw(k);
        } else try rec.varint(-1);
        if (r.value) |v| {
            try rec.varint(@intCast(v.len));
            try rec.raw(v);
        } else try rec.varint(-1);
        try rec.varint(@intCast(r.headers.len));
        for (r.headers) |h| {
            try rec.varint(@intCast(h.key.len));
            try rec.raw(h.key);
            if (h.value) |v| {
                try rec.varint(@intCast(v.len));
                try rec.raw(v);
            } else try rec.varint(-1);
        }
        try body.varint(@intCast(rec.buf.items.len));
        try body.raw(rec.buf.items);
        max_ts = @max(max_ts, r.timestamp_ms);
    }
    var payload: []const u8 = body.bytesWritten();
    var compressed: ?[]u8 = null;
    defer if (compressed) |c| gpa.free(c);
    if (opts.codec != .none) {
        compressed = try compress.compress(gpa, opts.codec, payload);
        payload = compressed.?;
    }

    var e: Enc = .init(gpa);
    errdefer e.deinit();
    try e.i64_(0);
    const len_at = try e.reserveLen();
    try e.i32_(-1);
    try e.i8_(2);
    try e.u32_(0);
    try e.i16_(@backingInt(opts.codec));
    try e.i32_(@intCast(recs.len - 1));
    try e.i64_(first_ts);
    try e.i64_(max_ts);
    try e.i64_(opts.producer_id);
    try e.i16_(opts.producer_epoch);
    try e.i32_(opts.base_sequence);
    try e.i32_(@intCast(recs.len));
    try e.raw(payload);
    e.patchLen(len_at);
    const crc = crc32c(e.buf.items[attributes_at..]);
    std.mem.writeInt(u32, e.buf.items[crc_at..][0..4], crc, .big);
    return e.buf.toOwnedSlice(gpa);
}

pub const DecodeError = error{ Corrupt, UnsupportedMagic, TooLarge } || std.mem.Allocator.Error;

pub const Decoded = struct {
    records: []Record,
    /// The offset after the last complete batch (to fetch next), or null
    /// when `data` held no complete batch.
    next_offset: ?i64,
};

/// Decodes the complete batches of `data` (a fetch response's records; a
/// partial batch at the end is left), dropping records before `min_offset`
/// and control batches. Everything is allocated in `arena`; keys and values
/// point into `data` or into the arena. `max_batch` bounds a batch's
/// decompressed size.
pub fn decode(arena: std.mem.Allocator, data: []const u8, min_offset: i64, max_batch: usize) DecodeError!Decoded {
    var out: std.ArrayList(Record) = .empty;
    var next: ?i64 = null;
    var pos: usize = 0;
    while (data.len - pos >= 12) {
        const base_offset = std.mem.readInt(i64, data[pos..][0..8], .big);
        const batch_len = std.mem.readInt(i32, data[pos + 8 ..][0..4], .big);
        if (batch_len < header_len - 12) return error.Corrupt;
        const total = 12 + @as(usize, @intCast(batch_len));
        if (data.len - pos < total) break; // a partial batch at the end
        const batch = data[pos..][0..total];
        pos += total;
        if (batch[16] != 2) return error.UnsupportedMagic;
        const crc = std.mem.readInt(u32, batch[crc_at..][0..4], .big);
        if (crc != crc32c(batch[attributes_at..])) return error.Corrupt;
        const attributes = std.mem.readInt(i16, batch[attributes_at..][0..2], .big);
        const last_delta = std.mem.readInt(i32, batch[23..][0..4], .big);
        const first_ts = std.mem.readInt(i64, batch[27..][0..8], .big);
        const count = std.mem.readInt(i32, batch[57..][0..4], .big);
        next = base_offset + last_delta + 1;
        if (attributes & 0x20 != 0) continue; // a control batch
        if (count < 0) return error.Corrupt;
        const codec = std.enums.fromInt(Codec, attributes & 7) orelse return error.Corrupt;
        var payload: []const u8 = batch[header_len..];
        if (codec != .none) {
            payload = compress.decompress(arena, codec, payload, max_batch) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.TooLarge => return error.TooLarge,
                else => return error.Corrupt,
            };
        }
        var d: Dec = .init(payload);
        const n: usize = @intCast(count);
        try out.ensureUnusedCapacity(arena, n);
        for (0..n) |_| {
            const r = decodeRecord(arena, &d, base_offset, first_ts) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.Corrupt,
            };
            if (r.offset >= min_offset) out.appendAssumeCapacity(r);
        }
    }
    return .{ .records = out.items, .next_offset = next };
}

fn decodeRecord(arena: std.mem.Allocator, d: *Dec, base_offset: i64, first_ts: i64) protocol.Error!Record {
    const len = try d.varint();
    if (len < 0 or @as(usize, @intCast(len)) > d.remaining()) return error.Invalid;
    _ = try d.i8_();
    const ts_delta = try d.varlong();
    const off_delta = try d.varint();
    const key = try optBytes(d);
    const value = try optBytes(d);
    const nh = try d.varint();
    if (nh < 0 or @as(usize, @intCast(nh)) > d.remaining()) return error.Invalid;
    const headers = try arena.alloc(Header, @intCast(nh));
    for (headers) |*h| {
        const k = (try optBytes(d)) orelse return error.Invalid;
        h.* = .{ .key = k, .value = try optBytes(d) };
    }
    return .{ .offset = base_offset + off_delta, .timestamp_ms = first_ts + ts_delta, .key = key, .value = value, .headers = headers };
}

fn optBytes(d: *Dec) protocol.Error!?[]const u8 {
    const n = try d.varint();
    if (n < 0) return null;
    const start = d.pos;
    try d.skip(@intCast(n));
    return d.buf[start..][0..@intCast(n)];
}

const testing = std.testing;

test "batch round trip with every codec, headers, nulls" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var big: [500]u8 = undefined;
    @memset(&big, 'x');
    const recs = [_]Rec{
        .{ .key = "k1", .value = "hello", .headers = &.{ .{ .key = "h", .value = "v" }, .{ .key = "n" } }, .timestamp_ms = 1_700_000_000_000 },
        .{ .key = null, .value = null, .timestamp_ms = 1_700_000_000_005 },
        .{ .key = "k3", .value = &big, .timestamp_ms = 1_700_000_000_010 },
    };
    for ([_]Codec{ .none, .gzip, .zstd, .lz4 }) |codec| {
        const batch = try encodeBatch(testing.allocator, &recs, .{ .codec = codec, .producer_id = 7, .producer_epoch = 1, .base_sequence = 0 });
        defer testing.allocator.free(batch);
        // Two batches back to back, then a truncated third.
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(testing.allocator);
        try wire.appendSlice(testing.allocator, batch);
        try wire.appendSlice(testing.allocator, batch);
        try wire.appendSlice(testing.allocator, batch[0 .. batch.len / 2]);
        const got = try decode(arena, wire.items, 0, 1 << 20);
        try testing.expectEqual(@as(usize, 6), got.records.len);
        try testing.expectEqual(@as(?i64, 3), got.next_offset);
        try testing.expectEqualStrings("hello", got.records[0].value.?);
        try testing.expectEqualStrings("v", got.records[0].headers[0].value.?);
        try testing.expect(got.records[0].headers[1].value == null);
        try testing.expect(got.records[1].key == null and got.records[1].value == null);
        try testing.expectEqual(@as(i64, 1_700_000_000_010), got.records[2].timestamp_ms);
        try testing.expectEqual(@as(usize, 500), got.records[2].value.?.len);
        try testing.expectEqual(@as(i64, 2), got.records[2].offset);
        // min_offset drops earlier records.
        const later = try decode(arena, batch, 2, 1 << 20);
        try testing.expectEqual(@as(usize, 1), later.records.len);
    }
}

test "a flipped bit is a CRC failure" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const batch = try encodeBatch(testing.allocator, &.{.{ .value = "v", .timestamp_ms = 1 }}, .{});
    defer testing.allocator.free(batch);
    batch[batch.len - 2] ^= 1;
    try testing.expectError(error.Corrupt, decode(arena_state.allocator(), batch, 0, 1 << 20));
}
