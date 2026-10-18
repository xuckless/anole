//! Compression: zlib-ng 2.3.3 in zlib-compat mode (gzip, zlib and raw
//! deflate; built by build/zlib_ng.zig with runtime SIMD dispatch) behind
//! lalinsky/zlib.zig's `std.Io` wrapper, and zstd 1.5.7 (build/zstd.zig) as
//! translated C bindings.
const std = @import("std");

/// `Compress` (a `std.Io.Writer` that deflates) and `Decompress` (a
/// `std.Io.Reader` that inflates) over zlib-ng; the same module dusty uses.
pub const zlib = @import("anole_zlib");

/// zstd.h.
pub const zstd = @import("anole_zstd_c");

/// zlib-ng's version string, `1.3.1.zlib-ng`.
pub fn zlibVersion() []const u8 {
    return std.mem.span(zlib_c.zlibVersion());
}

/// zlib.h of zlib-ng, for what zlib.zig does not wrap.
pub const zlib_c = @import("anole_zlib_c");

test "zlib-ng: gzip round trip through zlib.zig's std.Io wrapper" {
    try std.testing.expect(std.mem.endsWith(u8, zlibVersion(), "zlib-ng"));
    const gpa = std.testing.allocator;

    var input: [64 * 1024]u8 = undefined;
    for (&input, 0..) |*b, i| b.* = @truncate((i * 7) ^ (i >> 5));

    var compressed: std.Io.Writer.Allocating = try .initCapacity(gpa, 16 * 1024);
    defer compressed.deinit();
    {
        var gz = try zlib.Compress.init(gpa, &compressed.writer, &.{}, .gzip, .{});
        defer gz.deinit();
        try gz.writer.writeAll(&input);
        try gz.finish();
    }
    try std.testing.expect(compressed.written().len < input.len);
    try std.testing.expectEqual(@as(u8, 0x1f), compressed.written()[0]); // gzip magic

    var source: std.Io.Reader = .fixed(compressed.written());
    var gunzip = try zlib.Decompress.init(gpa, &source, &.{}, .gzip, .{});
    defer gunzip.deinit();
    const out = try gunzip.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(out);
    try std.testing.expectEqualSlices(u8, &input, out);
}

test "zlib-ng: raw deflate round trip (permessage-deflate's framing)" {
    const gpa = std.testing.allocator;
    var text_buf: [60 * 20]u8 = undefined;
    for (0..20) |i| @memcpy(text_buf[i * 60 ..][0..60], "a message, a message, a message, and the same message again!");
    const text: []const u8 = &text_buf;
    var compressed: std.Io.Writer.Allocating = try .initCapacity(gpa, 16 * 1024);
    defer compressed.deinit();
    {
        var d = try zlib.Compress.init(gpa, &compressed.writer, &.{}, .raw, .{});
        defer d.deinit();
        try d.writer.writeAll(text);
        try d.finish();
    }
    var source: std.Io.Reader = .fixed(compressed.written());
    var inflate = try zlib.Decompress.init(gpa, &source, &.{}, .raw, .{});
    defer inflate.deinit();
    const out = try inflate.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(out);
    try std.testing.expectEqualStrings(text, out);
}

test "zstd: streaming round trip with an 8 MiB window cap" {
    const gpa = std.testing.allocator;
    const input = try gpa.alloc(u8, 1024 * 1024);
    defer gpa.free(input);
    for (input, 0..) |*b, i| b.* = @truncate(i / 1000);

    const bound = zstd.ZSTD_compressBound(input.len);
    const compressed = try gpa.alloc(u8, bound);
    defer gpa.free(compressed);
    const n = zstd.ZSTD_compress(compressed.ptr, bound, input.ptr, input.len, 3);
    try std.testing.expectEqual(@as(c_uint, 0), zstd.ZSTD_isError(n));
    try std.testing.expect(n < input.len / 10);

    // Streaming decode, as an HTTP body decoder does, capped at the 8 MiB
    // window RFC 9659 allows for Content-Encoding: zstd.
    const dctx = zstd.ZSTD_createDCtx() orelse return error.OutOfMemory;
    defer _ = zstd.ZSTD_freeDCtx(dctx);
    try std.testing.expectEqual(@as(c_uint, 0), zstd.ZSTD_isError(zstd.ZSTD_DCtx_setParameter(dctx, zstd.ZSTD_d_windowLogMax, 23)));
    const out = try gpa.alloc(u8, input.len);
    defer gpa.free(out);
    var in_buf: zstd.ZSTD_inBuffer = .{ .src = compressed.ptr, .size = n, .pos = 0 };
    var out_buf: zstd.ZSTD_outBuffer = .{ .dst = out.ptr, .size = out.len, .pos = 0 };
    while (in_buf.pos < in_buf.size) {
        const rc = zstd.ZSTD_decompressStream(dctx, &out_buf, &in_buf);
        try std.testing.expectEqual(@as(c_uint, 0), zstd.ZSTD_isError(rc));
    }
    try std.testing.expectEqual(input.len, out_buf.pos);
    try std.testing.expectEqualSlices(u8, input, out);
}
