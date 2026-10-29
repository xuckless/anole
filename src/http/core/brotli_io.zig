// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES. Anole's, after zstd_io.zig.

//! Brotli behind `std.Io.Writer`, over the injected `brotli` module
//! (brotli/encode.h bindings): `Compress` brotli-compresses what is written
//! to it into another writer. Only built with `use_brotli`.
//!
//! Unlike zstd_io, the encoder's memory does not come from the request's
//! arena: an encoder takes about 600 KiB at the window used here, which an
//! arena would keep for as long as it is reused (an HTTP/1.1 connection
//! keeps its arena's capacity between requests). It comes from
//! `block_cache` instead, so `deinit` must run, finished or not.
const std = @import("std");
const c = @import("brotli");
const block_cache = @import("block_cache.zig");

const Writer = std.Io.Writer;

pub const Options = struct {
    /// 0 (fastest) to 11 (smallest). 5 is where Brotli starts beating gzip
    /// by a margin on small JSON and HTML; see `ServerConfig.Response`.
    quality: u4 = 5,
    /// log2 of the window, 10 to 24. Past 16 the encoder takes a hash table
    /// of 1.3 MiB instead of 512 KiB and, on JSON, compresses no better.
    lgwin: u5 = max_lgwin,
    /// The input's total length, when known up front: the encoder sizes its
    /// window and buffers to it.
    size_hint: ?usize = null,
};

/// The largest window used for HTTP responses.
pub const max_lgwin = 16;
/// BROTLI_MIN_WINDOW_BITS.
const min_lgwin = 10;

/// The window for a body of `len` bytes: no larger than the body.
pub fn windowFor(len: usize) u5 {
    return @intCast(std.math.clamp(std.math.log2_int_ceil(usize, @max(len, 1)), min_lgwin, max_lgwin));
}

fn brotliAlloc(_: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    return block_cache.alloc(size);
}

fn brotliFree(_: ?*anyopaque, address: ?*anyopaque) callconv(.c) void {
    block_cache.free(address);
}

pub const State = c.BrotliEncoderState;

/// Tests only: the encoders this thread made and has not freed, a leak
/// signal for state that comes from `block_cache` rather than the testing
/// allocator. Signed: an encoder freed on another thread than the one that
/// made it moves both counts, and neither may trap.
threadlocal var live_for_test: isize = 0;

/// Tests only: how many encoders made on this thread are still alive
/// (`init` without `deinit` or `destroy`).
pub fn liveForTest() isize {
    if (!@import("builtin").is_test) @compileError("liveForTest is for tests");
    return live_for_test;
}

/// Frees an encoder whose `Compress` is gone (`Compress.state`).
pub fn destroy(state: *State) void {
    c.BrotliEncoderDestroyInstance(state);
    if (@import("builtin").is_test) live_for_test -= 1;
}

pub const Compress = struct {
    writer: Writer,
    output: *Writer,
    state: ?*c.BrotliEncoderState,
    err: ?Error = null,

    pub const Error = error{ OutOfMemory, CompressFailed };

    /// Writes into `output`, which must have a buffer; `buffer` sits in
    /// front of the compressor and may be empty. Call `finish`, and
    /// `deinit` in any case.
    pub fn init(self: *Compress, output: *Writer, buffer: []u8, options: Options) Error!void {
        std.debug.assert(output.buffer.len > 0);
        self.* = .{
            .writer = .{ .buffer = buffer, .vtable = &.{ .drain = drain, .flush = flushFn } },
            .output = output,
            .state = null,
        };
        const state = c.BrotliEncoderCreateInstance(brotliAlloc, brotliFree, null) orelse return error.OutOfMemory;
        errdefer c.BrotliEncoderDestroyInstance(state);
        // BROTLI_MAX_QUALITY and BROTLI_MAX_WINDOW_BITS.
        const quality: u32 = @min(options.quality, 11);
        const lgwin: u32 = std.math.clamp(options.lgwin, min_lgwin, 24);
        if (c.BrotliEncoderSetParameter(state, c.BROTLI_PARAM_QUALITY, quality) == c.BROTLI_FALSE) return error.CompressFailed;
        if (c.BrotliEncoderSetParameter(state, c.BROTLI_PARAM_LGWIN, lgwin) == c.BROTLI_FALSE) return error.CompressFailed;
        // What goes through here is text: the compressible types are.
        if (c.BrotliEncoderSetParameter(state, c.BROTLI_PARAM_MODE, c.BROTLI_MODE_TEXT) == c.BROTLI_FALSE) return error.CompressFailed;
        if (options.size_hint) |size| {
            const hint: u32 = @intCast(@min(size, 1 << 30));
            if (c.BrotliEncoderSetParameter(state, c.BROTLI_PARAM_SIZE_HINT, hint) == c.BROTLI_FALSE) return error.CompressFailed;
        }
        self.state = state;
        if (@import("builtin").is_test) live_for_test += 1;
    }

    /// Frees the encoder. Safe to call twice, and after a failed `init`.
    pub fn deinit(self: *Compress) void {
        if (self.state) |state| destroy(state);
        self.state = null;
    }

    /// Ends the stream and flushes it to `output`'s buffer (not further).
    pub fn finish(self: *Compress) Writer.Error!void {
        try self.compress(self.writer.buffered(), c.BROTLI_OPERATION_FINISH);
        self.writer.end = 0;
    }

    fn compress(self: *Compress, bytes: []const u8, op: c.BrotliEncoderOperation) Writer.Error!void {
        const state = self.state orelse {
            self.err = error.CompressFailed;
            return error.WriteFailed;
        };
        var available_in: usize = bytes.len;
        var next_in: [*c]const u8 = bytes.ptr;
        while (true) {
            const dest = try self.output.writableSliceGreedy(1);
            var available_out: usize = dest.len;
            var next_out: [*c]u8 = dest.ptr;
            if (c.BrotliEncoderCompressStream(state, op, &available_in, &next_in, &available_out, &next_out, null) == c.BROTLI_FALSE) {
                self.err = error.CompressFailed;
                return error.WriteFailed;
            }
            self.output.advance(dest.len - available_out);
            const more = c.BrotliEncoderHasMoreOutput(state) != c.BROTLI_FALSE;
            const done = switch (op) {
                c.BROTLI_OPERATION_FINISH => c.BrotliEncoderIsFinished(state) != c.BROTLI_FALSE,
                else => available_in == 0 and !more,
            };
            if (done) return;
        }
    }

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const self: *Compress = @alignCast(@fieldParentPtr("writer", w));
        try self.compress(w.buffered(), c.BROTLI_OPERATION_PROCESS);
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.compress(bytes, c.BROTLI_OPERATION_PROCESS);
            n += bytes.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| try self.compress(pattern, c.BROTLI_OPERATION_PROCESS);
        return n + pattern.len * splat;
    }

    /// Makes everything written so far decodable (a meta-block boundary), so
    /// a streamed response can be read as it goes.
    fn flushFn(w: *Writer) Writer.Error!void {
        const self: *Compress = @alignCast(@fieldParentPtr("writer", w));
        try self.compress(w.buffered(), c.BROTLI_OPERATION_FLUSH);
        w.end = 0;
        try self.output.flush();
    }
};

/// Decodes a whole Brotli stream (tests only: Anole sends Brotli, it does not
/// take it).
fn testDecode(allocator: std.mem.Allocator, encoded: []const u8, max: usize) ![]u8 {
    const out = try allocator.alloc(u8, max);
    errdefer allocator.free(out);
    var len: usize = max;
    if (c.BrotliDecoderDecompress(encoded.len, encoded.ptr, &len, out.ptr) != c.BROTLI_DECODER_RESULT_SUCCESS) return error.InvalidBrotli;
    return allocator.realloc(out, len);
}

/// What a streaming decoder makes of `encoded` so far, without the end of
/// the stream.
fn testDecodePrefix(allocator: std.mem.Allocator, encoded: []const u8, max: usize) ![]u8 {
    const state = c.BrotliDecoderCreateInstance(null, null, null) orelse return error.OutOfMemory;
    defer c.BrotliDecoderDestroyInstance(state);
    const out = try allocator.alloc(u8, max);
    errdefer allocator.free(out);
    var available_in = encoded.len;
    var next_in: [*c]const u8 = encoded.ptr;
    var available_out = max;
    var next_out: [*c]u8 = out.ptr;
    const rc = c.BrotliDecoderDecompressStream(state, &available_in, &next_in, &available_out, &next_out, null);
    if (rc == c.BROTLI_DECODER_RESULT_ERROR) return error.InvalidBrotli;
    return allocator.realloc(out, max - available_out);
}

test "brotli_io: a round trip, whole and with flushes that decode as they go" {
    const gpa = std.testing.allocator;
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    for (0..200) |i| try text.writer.print("{{\"id\":{d},\"name\":\"item {d}\",\"active\":true}},", .{ i, i % 7 });
    const input = text.written();

    for ([_]u4{ 0, 1, 4, 5, 9, 11 }) |quality| {
        var encoded: std.Io.Writer.Allocating = try .initCapacity(gpa, 1024);
        defer encoded.deinit();
        var z: Compress = undefined;
        try z.init(&encoded.writer, &.{}, .{ .quality = quality, .lgwin = windowFor(input.len), .size_hint = input.len });
        defer z.deinit();
        try z.writer.writeAll(input);
        try z.finish();
        try std.testing.expect(encoded.written().len < input.len / 4);
        const decoded = try testDecode(gpa, encoded.written(), input.len);
        defer gpa.free(decoded);
        try std.testing.expectEqualStrings(input, decoded);
    }

    // Streamed in pieces with a flush after each: everything written so far
    // decodes before the stream ends.
    var encoded: std.Io.Writer.Allocating = try .initCapacity(gpa, 1024);
    defer encoded.deinit();
    var buffer: [256]u8 = undefined;
    var z: Compress = undefined;
    try z.init(&encoded.writer, &buffer, .{});
    defer z.deinit();
    var sent: usize = 0;
    while (sent < input.len) {
        const piece = input[sent..@min(input.len, sent + 1000)];
        try z.writer.writeAll(piece);
        sent += piece.len;
        try z.writer.flush();
        const prefix = try testDecodePrefix(gpa, encoded.written(), input.len);
        defer gpa.free(prefix);
        try std.testing.expectEqualStrings(input[0..sent], prefix);
    }
    try z.finish();
    const decoded = try testDecode(gpa, encoded.written(), input.len);
    defer gpa.free(decoded);
    try std.testing.expectEqualStrings(input, decoded);
}

test "brotli_io: an encoder's large blocks are reused by the next, and trimmed when idle (block_cache)" {
    const gpa = std.testing.allocator;
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    for (0..400) |i| try text.writer.print("{{\"id\":{d},\"name\":\"item {d}\"}},", .{ i, i % 13 });
    const input = text.written();
    // Other tests on this thread may have left blocks (up to `max_cached`).
    block_cache.drainLocalForTest();

    var after_first: usize = 0;
    for (0..3) |round| {
        var encoded: std.Io.Writer.Allocating = try .initCapacity(gpa, 1024);
        defer encoded.deinit();
        var z: Compress = undefined;
        try z.init(&encoded.writer, &.{}, .{ .lgwin = windowFor(input.len), .size_hint = input.len });
        try z.writer.writeAll(input);
        try z.finish();
        z.deinit();
        const decoded = try testDecode(gpa, encoded.written(), input.len);
        defer gpa.free(decoded);
        try std.testing.expectEqualStrings(input, decoded);
        // The first encoder leaves its large blocks; the next ones take them
        // and give them back, so the cache stops growing.
        if (round == 0) after_first = block_cache.cached().count else try std.testing.expectEqual(after_first, block_cache.cached().count);
    }
    // At least its two hash tables.
    try std.testing.expect(after_first >= 2);

    // Two encoders at once (two streams) need twice the blocks; once idle
    // for a whole trim interval, the cache goes back to `trim_keep`.
    var outs: [2]std.Io.Writer.Allocating = .{ try .initCapacity(gpa, 256), try .initCapacity(gpa, 256) };
    defer for (&outs) |*o| o.deinit();
    var zs: [2]Compress = undefined;
    for (&zs, &outs) |*z, *o| try z.init(&o.writer, &.{}, .{});
    for (&zs) |*z| try z.writer.writeAll(input);
    // Both finish (and hold their blocks) before either gives them back.
    for (&zs) |*z| try z.finish();
    for (&zs) |*z| z.deinit();
    try std.testing.expect(block_cache.cached().count > block_cache.trim_keep);
    block_cache.trimLocal(); // the low mark of the interval that just ended
    block_cache.trimLocal(); // nothing taken since: down to trim_keep
    try std.testing.expectEqual(@as(usize, block_cache.trim_keep), block_cache.cached().count);
    try std.testing.expect(block_cache.cached().bytes <= block_cache.max_cached);
}

test "brotli_io: the window fits the body, up to 64 KiB" {
    try std.testing.expectEqual(@as(u5, 10), windowFor(0));
    try std.testing.expectEqual(@as(u5, 10), windowFor(300));
    try std.testing.expectEqual(@as(u5, 13), windowFor(5000));
    try std.testing.expectEqual(@as(u5, 16), windowFor(65536));
    try std.testing.expectEqual(@as(u5, 16), windowFor(1 << 30));
}

test "fuzz: Brotli round trips through the streaming writer" {
    try @import("fuzz.zig").bytes(struct {
        fn check(input: []const u8) !void {
            if (input.len == 0) return;
            const gpa = std.testing.allocator;
            // The first byte picks the quality (0 to 9; 10 and 11 are too
            // slow to fuzz and share the code paths of 9), the piece size
            // and whether each piece is flushed; the rest is the body.
            const knobs = input[0];
            const body = input[1..];
            const step = 1 + @as(usize, knobs >> 4) * 97;
            var encoded: std.Io.Writer.Allocating = try .initCapacity(gpa, 256);
            defer encoded.deinit();
            var buffer: [64]u8 = undefined;
            var z: Compress = undefined;
            try z.init(&encoded.writer, &buffer, .{ .quality = @intCast(knobs % 10) });
            defer z.deinit();
            var i: usize = 0;
            while (i < body.len) : (i += step) {
                try z.writer.writeAll(body[i..@min(body.len, i + step)]);
                if (knobs & 0x08 != 0) try z.writer.flush();
            }
            try z.finish();
            const decoded = try testDecode(gpa, encoded.written(), body.len);
            defer gpa.free(decoded);
            try std.testing.expectEqualSlices(u8, body, decoded);
        }
    }.check, &.{
        "\x05{\"items\":[{\"id\":1,\"name\":\"Alpha Widget\",\"tags\":[\"sale\",\"popular\"]}],\"count\":1}",
        "\x9c<!doctype html><html><head><title>x</title></head><body><p>hello hello hello</p></body></html>",
        "\x00",
        "\xff" ++ @as([300]u8, @splat('a')),
    });
}
