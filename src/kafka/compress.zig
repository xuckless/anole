//! Record batch compression: gzip and zstd through `anole.compression`
//! (zlib-ng, zstd), lz4 through the lz4 C library's frame API, and snappy
//! as a decoder only (raw blocks and the xerial framing Java producers
//! write). Snappy producing is not offered (a later item).
const std = @import("std");
const comp = @import("../compression/root.zig");
const lz4 = @import("anole_lz4_c");

pub const Codec = enum(u3) {
    none = 0,
    gzip = 1,
    snappy = 2,
    lz4 = 3,
    zstd = 4,
};

pub const Error = error{ Corrupt, TooLarge, Unsupported } || std.mem.Allocator.Error;

/// A compressed copy of `input`, owned by the caller.
pub fn compress(gpa: std.mem.Allocator, codec: Codec, input: []const u8) Error![]u8 {
    switch (codec) {
        .none => return gpa.dupe(u8, input),
        .gzip => {
            var out: std.Io.Writer.Allocating = try .initCapacity(gpa, @max(64, input.len / 2));
            errdefer out.deinit();
            var gz = comp.zlib.Compress.init(gpa, &out.writer, &.{}, .gzip, .{}) catch return error.OutOfMemory;
            defer gz.deinit();
            gz.writer.writeAll(input) catch return error.OutOfMemory;
            gz.finish() catch return error.OutOfMemory;
            return out.toOwnedSlice();
        },
        .zstd => {
            const zstd = comp.zstd;
            const bound = zstd.ZSTD_compressBound(input.len);
            const buf = try gpa.alloc(u8, bound);
            errdefer gpa.free(buf);
            const n = zstd.ZSTD_compress(buf.ptr, bound, input.ptr, input.len, 3);
            if (zstd.ZSTD_isError(n) != 0) return error.Corrupt;
            return gpa.realloc(buf, n) catch buf[0..n];
        },
        .lz4 => {
            var prefs: lz4.LZ4F_preferences_t = std.mem.zeroes(lz4.LZ4F_preferences_t);
            prefs.frameInfo.blockMode = lz4.LZ4F_blockIndependent;
            prefs.frameInfo.blockSizeID = lz4.LZ4F_max64KB;
            const bound = lz4.LZ4F_compressFrameBound(input.len, &prefs);
            const buf = try gpa.alloc(u8, bound);
            errdefer gpa.free(buf);
            const n = lz4.LZ4F_compressFrame(buf.ptr, bound, input.ptr, input.len, &prefs);
            if (lz4.LZ4F_isError(n) != 0) return error.Corrupt;
            return gpa.realloc(buf, n) catch buf[0..n];
        },
        .snappy => return error.Unsupported,
    }
}

/// The decompressed bytes, owned by the caller; at most `max` of them.
pub fn decompress(gpa: std.mem.Allocator, codec: Codec, input: []const u8, max: usize) Error![]u8 {
    switch (codec) {
        .none => return gpa.dupe(u8, input),
        .gzip => {
            var source: std.Io.Reader = .fixed(input);
            var gz = comp.zlib.Decompress.init(gpa, &source, &.{}, .gzip, .{}) catch return error.Corrupt;
            defer gz.deinit();
            return gz.reader.allocRemaining(gpa, .limited(max)) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.StreamTooLong => error.TooLarge,
                else => error.Corrupt,
            };
        },
        .zstd => return zstdDecode(gpa, input, max),
        .lz4 => return lz4Decode(gpa, input, max),
        .snappy => return snappyDecode(gpa, input, max),
    }
}

fn zstdDecode(gpa: std.mem.Allocator, input: []const u8, max: usize) Error![]u8 {
    const zstd = comp.zstd;
    const dctx = zstd.ZSTD_createDCtx() orelse return error.OutOfMemory;
    defer _ = zstd.ZSTD_freeDCtx(dctx);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var in_buf: zstd.ZSTD_inBuffer = .{ .src = input.ptr, .size = input.len, .pos = 0 };
    while (true) {
        try out.ensureUnusedCapacity(gpa, 64 * 1024);
        var ob: zstd.ZSTD_outBuffer = .{ .dst = out.items.ptr + out.items.len, .size = out.capacity - out.items.len, .pos = 0 };
        const rc = zstd.ZSTD_decompressStream(dctx, &ob, &in_buf);
        if (zstd.ZSTD_isError(rc) != 0) return error.Corrupt;
        out.items.len += ob.pos;
        if (out.items.len > max) return error.TooLarge;
        if (rc == 0) break;
        if (in_buf.pos == in_buf.size and ob.pos == 0) return error.Corrupt;
    }
    return out.toOwnedSlice(gpa);
}

fn lz4Decode(gpa: std.mem.Allocator, input: []const u8, max: usize) Error![]u8 {
    var dctx: ?*lz4.LZ4F_dctx = null;
    if (lz4.LZ4F_isError(lz4.LZ4F_createDecompressionContext(&dctx, lz4.LZ4F_VERSION)) != 0) return error.OutOfMemory;
    defer _ = lz4.LZ4F_freeDecompressionContext(dctx);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var pos: usize = 0;
    while (true) {
        try out.ensureUnusedCapacity(gpa, 64 * 1024);
        var dst_size: usize = out.capacity - out.items.len;
        var src_size: usize = input.len - pos;
        const rc = lz4.LZ4F_decompress(dctx, out.items.ptr + out.items.len, &dst_size, input.ptr + pos, &src_size, null);
        if (lz4.LZ4F_isError(rc) != 0) return error.Corrupt;
        out.items.len += dst_size;
        pos += src_size;
        if (out.items.len > max) return error.TooLarge;
        if (rc == 0) break;
        if (pos == input.len and dst_size == 0 and src_size == 0) return error.Corrupt;
    }
    return out.toOwnedSlice(gpa);
}

const xerial_magic = "\x82SNAPPY\x00";

fn snappyDecode(gpa: std.mem.Allocator, input: []const u8, max: usize) Error![]u8 {
    if (std.mem.startsWith(u8, input, xerial_magic)) {
        // magic (8), version (4), compatible version (4), then blocks of a
        // big-endian length and a raw snappy block.
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var pos: usize = 16;
        if (input.len < pos) return error.Corrupt;
        while (pos < input.len) {
            if (input.len - pos < 4) return error.Corrupt;
            const n = std.mem.readInt(u32, input[pos..][0..4], .big);
            pos += 4;
            if (n > input.len - pos) return error.Corrupt;
            try snappyBlock(gpa, input[pos..][0..n], &out, max);
            pos += n;
        }
        return out.toOwnedSlice(gpa);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try snappyBlock(gpa, input, &out, max);
    return out.toOwnedSlice(gpa);
}

/// Appends one raw snappy block's contents to `out`.
fn snappyBlock(gpa: std.mem.Allocator, block: []const u8, out: *std.ArrayList(u8), max: usize) Error!void {
    var pos: usize = 0;
    var total: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        if (pos >= block.len or shift > 35) return error.Corrupt;
        const b = block[pos];
        pos += 1;
        total |= @as(u64, b & 0x7f) << shift;
        if (b & 0x80 == 0) break;
        shift += 7;
    }
    if (total > max or out.items.len + total > max) return error.TooLarge;
    const start = out.items.len;
    const end = start + @as(usize, @intCast(total));
    try out.ensureTotalCapacity(gpa, end);
    while (pos < block.len) {
        const tag = block[pos];
        pos += 1;
        switch (tag & 3) {
            0 => {
                var len: usize = tag >> 2;
                if (len >= 60) {
                    const extra = len - 59;
                    if (block.len - pos < extra) return error.Corrupt;
                    len = 0;
                    for (0..extra) |i| len |= @as(usize, block[pos + i]) << @intCast(8 * i);
                    pos += extra;
                }
                len += 1;
                if (block.len - pos < len or out.items.len + len > end) return error.Corrupt;
                out.appendSliceAssumeCapacity(block[pos..][0..len]);
                pos += len;
            },
            else => |kind| {
                var len: usize = undefined;
                var offset: usize = undefined;
                switch (kind) {
                    1 => {
                        if (pos >= block.len) return error.Corrupt;
                        len = 4 + ((tag >> 2) & 7);
                        offset = (@as(usize, tag >> 5) << 8) | block[pos];
                        pos += 1;
                    },
                    2 => {
                        if (block.len - pos < 2) return error.Corrupt;
                        len = (tag >> 2) + 1;
                        offset = std.mem.readInt(u16, block[pos..][0..2], .little);
                        pos += 2;
                    },
                    else => {
                        if (block.len - pos < 4) return error.Corrupt;
                        len = (tag >> 2) + 1;
                        offset = std.mem.readInt(u32, block[pos..][0..4], .little);
                        pos += 4;
                    },
                }
                if (offset == 0 or offset > out.items.len - start or out.items.len + len > end) return error.Corrupt;
                // Overlapping copies repeat bytes, so go one at a time.
                for (0..len) |_| out.appendAssumeCapacity(out.items[out.items.len - offset]);
            },
        }
    }
    if (out.items.len != end) return error.Corrupt;
}

const testing = std.testing;

fn sample(buf: []u8) void {
    for (buf, 0..) |*b, i| b.* = @truncate((i * 7) ^ (i >> 5) ^ (i / 300));
}

test "gzip, zstd and lz4 round trip" {
    var input: [20_000]u8 = undefined;
    sample(&input);
    for ([_]Codec{ .none, .gzip, .zstd, .lz4 }) |codec| {
        const c = try compress(testing.allocator, codec, &input);
        defer testing.allocator.free(c);
        const d = try decompress(testing.allocator, codec, c, 1 << 20);
        defer testing.allocator.free(d);
        try testing.expectEqualSlices(u8, &input, d);
        if (codec != .none) try testing.expectError(error.TooLarge, decompress(testing.allocator, codec, c, 100));
    }
}

test "corrupt input is refused" {
    for ([_]Codec{ .gzip, .zstd, .lz4 }) |codec| {
        try testing.expectError(error.Corrupt, decompress(testing.allocator, codec, "not compressed data at all", 1 << 20));
    }
}

test "snappy: a hand-made raw block (literal, copy1 overlapping) and the xerial framing" {
    // "abcabcabcabc": literal "abc", then a copy of length 9, offset 3
    // (copy2 form: len-1 = 8 -> tag 8<<2|2).
    const raw = [_]u8{ 12, (3 - 1) << 2, 'a', 'b', 'c', (9 - 1) << 2 | 2, 3, 0 };
    const out = try decompress(testing.allocator, .snappy, &raw, 100);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("abcabcabcabc", out);

    var framed: std.ArrayList(u8) = .empty;
    defer framed.deinit(testing.allocator);
    try framed.appendSlice(testing.allocator, xerial_magic);
    try framed.appendSlice(testing.allocator, &.{ 0, 0, 0, 1, 0, 0, 0, 1 });
    for (0..2) |_| {
        try framed.appendSlice(testing.allocator, &.{ 0, 0, 0, raw.len });
        try framed.appendSlice(testing.allocator, &raw);
    }
    const out2 = try decompress(testing.allocator, .snappy, framed.items, 100);
    defer testing.allocator.free(out2);
    try testing.expectEqualStrings("abcabcabcabcabcabcabcabc", out2);
}
