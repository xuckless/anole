//! Copied from fanyang89/grpc-lite (MIT, Copyright (c) 2026 grpc-lite contributors),
//! src/frame.zig at commit db3c400bf70419742ebcb42fe316ba8b754b4975; see THIRD_PARTY_NOTICES.
//! Changed for Anole: gzip goes through zlib-ng (`anole_zlib`) instead of
//! std.compress.flate, and messages can also be read off a `std.Io.Reader`.
const std = @import("std");
const Compression = @import("compression.zig").Compression;
const features = @import("build_options");
const zlib = if (features.compression) @import("anole_zlib") else struct {};

/// The message prefix: a compressed flag and a 4-byte big-endian length.
pub const header_size = 5;

/// `payload` with its prefix, uncompressed, allocated with `allocator`.
pub fn encode(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    return encodeWithCompression(allocator, payload, .identity);
}

/// `payload` with its prefix, gzipped first when `compression` says so
/// (`error.CompressionUnsupported` without `-Dcompression`).
pub fn encodeWithCompression(
    allocator: std.mem.Allocator,
    payload: []const u8,
    compression: Compression,
) ![]u8 {
    if (compression == .identity) return encodePayload(allocator, payload, false);

    if (comptime !features.compression) return error.CompressionUnsupported;
    var output = try std.Io.Writer.Allocating.initCapacity(allocator, 64);
    defer output.deinit();
    var compressor = try zlib.Compress.init(allocator, &output.writer, &.{}, .gzip, deflateOptions(payload.len));
    defer compressor.deinit();
    compressor.writer.writeAll(payload) catch return error.OutOfMemory;
    compressor.finish() catch return error.OutOfMemory;
    return encodePayload(allocator, output.written(), true);
}

/// Deflate sized to one message: a window no larger than the message
/// (a match cannot reach further back than its start anyway, so the output
/// is as small) and a memory level whose symbol buffer holds the whole
/// message, so it stays one deflate block as at the defaults. zlib's defaults allocate about
/// 320 KiB and zero 192 KiB of it per message; for a 1 KiB message this
/// takes 130 KiB and zeroes the 128 KiB hash table alone (fixed in zlib-ng).
fn deflateOptions(len: usize) zlib.Options {
    const bits: u4 = if (len <= 1 << 9) 9 else if (len >= 1 << 15) 15 else @intCast(std.math.log2_int_ceil(usize, len));
    return .{ .window_bits = bits, .mem_level = @min(8, bits - 6) };
}

fn encodePayload(allocator: std.mem.Allocator, payload: []const u8, compressed: bool) ![]u8 {
    if (payload.len > std.math.maxInt(u32)) return error.MessageTooLarge;

    const frame = try allocator.alloc(u8, header_size + payload.len);
    frame[0] = @intFromBool(compressed);
    const length: u32 = @intCast(payload.len);
    frame[1] = @truncate(length >> 24);
    frame[2] = @truncate(length >> 16);
    frame[3] = @truncate(length >> 8);
    frame[4] = @truncate(length);
    @memcpy(frame[header_size..], payload);
    return frame;
}

/// Splits a byte stream into messages: `feed` it bytes as they come, take
/// messages with `next`, and `finish` at the end to catch a truncated one.
pub const Decoder = struct {
    /// One message and what it took on the wire.
    pub const DecodedMessage = struct {
        /// Allocated by the decoder allocator and owned by the caller.
        payload: []u8,
        /// Complete wire size, including the five-byte message header.
        consumed_bytes: usize,
        compressed: bool,
    };

    allocator: std.mem.Allocator,
    max_message_size: usize,
    compression: Compression,
    buffer: std.ArrayList(u8) = .empty,
    offset: usize = 0,

    /// A decoder for uncompressed messages of at most `max_message_size`.
    pub fn init(allocator: std.mem.Allocator, max_message_size: usize) Decoder {
        return initWithCompression(allocator, max_message_size, .identity);
    }

    /// A decoder that inflates messages flagged compressed with
    /// `compression`.
    pub fn initWithCompression(
        allocator: std.mem.Allocator,
        max_message_size: usize,
        compression: Compression,
    ) Decoder {
        return .{
            .allocator = allocator,
            .max_message_size = max_message_size,
            .compression = compression,
        };
    }

    /// Frees the buffered bytes (not the messages handed out).
    pub fn deinit(self: *Decoder) void {
        self.buffer.deinit(self.allocator);
        self.* = undefined;
    }

    /// Buffers `bytes`.
    pub fn feed(self: *Decoder, bytes: []const u8) !void {
        return self.feedBounded(bytes, std.math.maxInt(usize));
    }

    /// Appends bytes only when the total unconsumed wire data remains within limit.
    pub fn feedBounded(self: *Decoder, bytes: []const u8, max_buffered_bytes: usize) !void {
        const buffered = self.bufferedBytes();
        if (buffered > max_buffered_bytes or bytes.len > max_buffered_bytes - buffered) {
            return error.BufferLimitExceeded;
        }

        if (self.offset == self.buffer.items.len) {
            self.buffer.clearRetainingCapacity();
            self.offset = 0;
        } else if (self.offset > 0 and self.offset >= self.buffer.items.len / 2) {
            const remaining = self.buffer.items[self.offset..];
            std.mem.copyForwards(u8, self.buffer.items[0..remaining.len], remaining);
            self.buffer.shrinkRetainingCapacity(remaining.len);
            self.offset = 0;
        }
        try self.buffer.appendSlice(self.allocator, bytes);
    }

    /// Returns the exact number of unconsumed wire bytes held by the decoder.
    pub fn bufferedBytes(self: *const Decoder) usize {
        return self.buffer.items.len - self.offset;
    }

    /// The next whole message, or null until more bytes arrive. Fails with
    /// `error.MessageTooLarge` past the limit, and with
    /// `error.CompressionMismatch` for a compressed message the decoder
    /// was not told how to inflate.
    pub fn nextMessage(self: *Decoder) !?DecodedMessage {
        const available = self.buffer.items[self.offset..];
        if (available.len < header_size) return null;
        if (available[0] > 1) return error.InvalidCompressedFlag;
        const compressed = available[0] == 1;
        if (compressed and self.compression != .gzip) return error.CompressionMismatch;

        const length = (@as(u32, available[1]) << 24) |
            (@as(u32, available[2]) << 16) |
            (@as(u32, available[3]) << 8) |
            @as(u32, available[4]);
        if (!compressed and length > self.max_message_size) return error.MessageTooLarge;

        const end = header_size + @as(usize, length);
        if (available.len < end) return null;

        const payload = if (compressed)
            try decompressGzip(
                self.allocator,
                available[header_size..end],
                self.max_message_size,
            )
        else
            try self.allocator.dupe(u8, available[header_size..end]);
        self.offset += end;
        return .{
            .payload = payload,
            .consumed_bytes = end,
            .compressed = compressed,
        };
    }

    /// `nextMessage`'s payload alone, owned by the caller.
    pub fn next(self: *Decoder) !?[]u8 {
        const message = try self.nextMessage() orelse return null;
        return message.payload;
    }

    /// Fails with `error.TruncatedFrame` when bytes of an unfinished
    /// message are left.
    pub fn finish(self: *const Decoder) !void {
        if (self.bufferedBytes() != 0) return error.TruncatedFrame;
    }
};

/// The one message in `bytes`, which must hold exactly one.
pub fn decodeUnary(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    max_message_size: usize,
) ![]u8 {
    return decodeUnaryWithCompression(allocator, bytes, max_message_size, .identity);
}

/// `decodeUnary`, inflating with `compression`.
pub fn decodeUnaryWithCompression(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    max_message_size: usize,
    compression: Compression,
) ![]u8 {
    var decoder = Decoder.initWithCompression(allocator, max_message_size, compression);
    defer decoder.deinit();

    try decoder.feed(bytes);
    const payload = try decoder.next() orelse return error.TruncatedFrame;
    errdefer allocator.free(payload);
    if (try decoder.next()) |extra| {
        allocator.free(extra);
        return error.ExpectedUnaryMessage;
    }
    try decoder.finish();
    return payload;
}

/// One message off `reader` (the request or response body): null at a clean
/// end between messages. A compressed message is inflated with `compression`.
pub fn readMessage(
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,
    max_message_size: usize,
    compression: Compression,
) !?Decoder.DecodedMessage {
    var header: [header_size]u8 = undefined;
    const n = try reader.readSliceShort(&header);
    if (n == 0) return null;
    if (n < header_size) return error.TruncatedFrame;
    if (header[0] > 1) return error.InvalidCompressedFlag;
    const compressed = header[0] == 1;
    if (compressed and compression != .gzip) return error.CompressionMismatch;
    const length = std.mem.readInt(u32, header[1..5], .big);
    if (!compressed and length > max_message_size) return error.MessageTooLarge;
    // A compressed message may only be larger once inflated; its wire form
    // is still held to a bound.
    if (compressed and length > max_message_size *| 2 +| 1024) return error.MessageTooLarge;
    const wire = readPayload(reader, allocator, length) catch |err| return switch (err) {
        error.EndOfStream => error.TruncatedFrame,
        else => |e| e,
    };
    const payload = if (compressed) blk: {
        defer allocator.free(wire);
        break :blk try decompressGzip(allocator, wire, max_message_size);
    } else wire;
    return .{ .payload = payload, .consumed_bytes = header_size + length, .compressed = compressed };
}

/// Bytes a message's buffer may run ahead of the bytes that arrived.
const read_chunk = 64 * 1024;

/// The next `len` bytes of `reader`, allocated with `allocator`. The
/// buffer grows with the bytes that arrive rather than with the length a
/// frame header declares, so a peer that announces a large message and
/// sends little of it holds little memory.
fn readPayload(reader: *std.Io.Reader, allocator: std.mem.Allocator, len: usize) (std.Io.Reader.Error || std.mem.Allocator.Error)![]u8 {
    if (len <= reader.bufferedLen()) {
        const out = try allocator.alloc(u8, len);
        reader.readSliceAll(out) catch unreachable; // already buffered
        return out;
    }
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    while (list.items.len < len) {
        const n = @min(len - list.items.len, @max(reader.bufferedLen(), read_chunk));
        try list.ensureUnusedCapacity(allocator, n);
        try reader.readSliceAll(list.unusedCapacitySlice()[0..n]);
        list.items.len += n;
    }
    return list.toOwnedSlice(allocator);
}

/// Inflates one gzip message, refusing it once it passes
/// `max_message_size`. The result is allocated with `allocator`.
pub fn decompressGzip(
    allocator: std.mem.Allocator,
    payload: []const u8,
    max_message_size: usize,
) ![]u8 {
    if (comptime !features.compression) return error.CompressionUnsupported;
    // No gzip stream is empty, and the inflater asserts it has input: a
    // peer could crash a safe build with an empty compressed message.
    if (payload.len == 0) return error.MalformedCompressedMessage;
    var input: std.Io.Reader = .fixed(payload);
    var decompressor = try zlib.Decompress.init(allocator, &input, &.{}, .gzip, .{});
    defer decompressor.deinit();
    const limit: std.Io.Limit = if (max_message_size == std.math.maxInt(usize))
        .unlimited
    else
        .limited(max_message_size + 1);
    const decompressed = decompressor.reader.allocRemaining(allocator, limit) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.MessageTooLarge,
        else => return error.MalformedCompressedMessage,
    };
    errdefer allocator.free(decompressed);
    if (decompressed.len > max_message_size) return error.MessageTooLarge;
    if (input.seek != input.end) return error.MalformedCompressedMessage;
    return decompressed;
}

/// Fails every single allocation larger than `max`.
const CappedAllocator = struct {
    child: std.mem.Allocator = std.testing.allocator,
    max: usize,

    fn allocator(self: *CappedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CappedAllocator = @ptrCast(@alignCast(ctx));
        if (len > self.max) return null;
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CappedAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > self.max) return false;
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CappedAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > self.max) return null;
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CappedAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

test "readMessage: a declared length is not allocated before its bytes arrive" {
    var capped: CappedAllocator = .{ .max = 256 * 1024 };
    // 4 MiB declared, 3 bytes sent.
    var reader: std.Io.Reader = .fixed("\x00\x00\x40\x00\x00abc");
    try std.testing.expectError(error.TruncatedFrame, readMessage(&reader, capped.allocator(), 4 * 1024 * 1024, .identity));

    // A whole message larger than the reader's buffer still arrives.
    const gpa = std.testing.allocator;
    const payload = try gpa.alloc(u8, 300_000);
    defer gpa.free(payload);
    for (payload, 0..) |*b, i| b.* = @truncate(i);
    const framed = try encode(gpa, payload);
    defer gpa.free(framed);
    var buffer: [64]u8 = undefined;
    var stream: std.testing.Reader = .init(&buffer, &.{.{ .buffer = framed }});
    stream.artificial_limit = .limited(1000);
    const msg = (try readMessage(&stream.interface, gpa, 1 << 20, .identity)).?;
    defer gpa.free(msg.payload);
    try std.testing.expectEqualSlices(u8, payload, msg.payload);
}

test "fuzz: gRPC message frames read off a stream" {
    try @import("../fuzz.zig").bytes(struct {
        fn check(input: []const u8) !void {
            if (input.len == 0) return;
            // The first byte picks the limit, the compression and how many
            // bytes the stream hands over at a time.
            const max: usize = if (input[0] & 1 != 0) 64 else 4096;
            const compression: Compression = if (input[0] & 2 != 0 and features.compression) .gzip else .identity;
            var buffer: [32]u8 = undefined;
            var stream: std.testing.Reader = .init(&buffer, &.{.{ .buffer = input[1..] }});
            stream.artificial_limit = .limited(@as(usize, input[0] >> 2) + 1);
            // Nothing larger than the input, or than a chunk ahead of it.
            var capped: CappedAllocator = .{ .max = @max(read_chunk, max) + 64 * 1024 };
            const gpa = capped.allocator();
            while (true) {
                const msg = readMessage(&stream.interface, gpa, max, compression) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => return,
                } orelse return;
                defer gpa.free(msg.payload);
                if (msg.payload.len > max) return error.OverLimit;
            }
        }
    }.check, &.{
        "\x00\x00\x00\x00\x00\x03abc\x00\x00\x00\x00\x00",
        "\x04\x00\x00\x40\x00\x00abc",
        "\xff\x00\x00\x00\x00\x02hi",
        "\x02\x01\x00\x00\x00\x05\x1f\x8b\x08\x00\x00",
        "\x00\x02\x00\x00\x00\x00",
    });
}

test "frame round trips empty and binary payloads" {
    for ([_][]const u8{ "", "abc\x00xyz" }) |payload| {
        const encoded = try encode(std.testing.allocator, payload);
        defer std.testing.allocator.free(encoded);
        const decoded = try decodeUnary(std.testing.allocator, encoded, 1024);
        defer std.testing.allocator.free(decoded);
        try std.testing.expectEqualSlices(u8, payload, decoded);
    }
}

test "frame round trips a multi-byte payload length" {
    const payload = try std.testing.allocator.alloc(u8, 70_000);
    defer std.testing.allocator.free(payload);
    @memset(payload, 0x5a);

    const encoded = try encode(std.testing.allocator, payload);
    defer std.testing.allocator.free(encoded);
    const decoded = try decodeUnary(std.testing.allocator, encoded, payload.len);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, payload, decoded);
}

test "gzip frame round trips and marks compressed payload" {
    if (comptime !features.compression) return error.SkipZigTest;
    const encoded = try encodeWithCompression(std.testing.allocator, "compress me compress me", .gzip);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqual(@as(u8, 1), encoded[0]);

    const decoded = try decodeUnaryWithCompression(std.testing.allocator, encoded, 1024, .gzip);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("compress me compress me", decoded);
}

test "gzip with the window sized to the message: round trips, and compresses as well as the defaults" {
    if (comptime !features.compression) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();
    for ([_]usize{ 0, 1, 100, 511, 512, 513, 1024, 1500, 4096, 20_000, 32_768, 40_000, 100_000 }) |len| {
        for ([_]bool{ false, true }) |noisy| {
            const payload = try gpa.alloc(u8, len);
            defer gpa.free(payload);
            // Text-like, so there is something to match; or bytes.
            for (payload, 0..) |*b, i| b.* = if (noisy) random.int(u8) else "abcdefgh ijk lmnop"[(i * 7 + i / 64) % 18];
            const encoded = try encodeWithCompression(gpa, payload, .gzip);
            defer gpa.free(encoded);
            const decoded = try decodeUnaryWithCompression(gpa, encoded, 1 << 20, .gzip);
            defer gpa.free(decoded);
            try std.testing.expectEqualSlices(u8, payload, decoded);

            var reference = try std.Io.Writer.Allocating.initCapacity(gpa, 64);
            defer reference.deinit();
            var compressor = try zlib.Compress.init(gpa, &reference.writer, &.{}, .gzip, .{});
            defer compressor.deinit();
            try compressor.writer.writeAll(payload);
            try compressor.finish();
            try std.testing.expect(encoded.len - header_size <= reference.written().len + 8);
        }
    }
}

test "gzip decoding rejects malformed data and compression mismatches" {
    if (comptime !features.compression) return error.SkipZigTest;
    try std.testing.expectError(
        error.MalformedCompressedMessage,
        decodeUnaryWithCompression(
            std.testing.allocator,
            &.{ 1, 0, 0, 0, 3, 1, 2, 3 },
            1024,
            .gzip,
        ),
    );
    try std.testing.expectError(
        error.CompressionMismatch,
        decodeUnaryWithCompression(std.testing.allocator, &.{ 1, 0, 0, 0, 0 }, 1024, .identity),
    );
    const uncompressed = try decodeUnaryWithCompression(
        std.testing.allocator,
        &.{ 0, 0, 0, 0, 0 },
        1024,
        .gzip,
    );
    defer std.testing.allocator.free(uncompressed);
    try std.testing.expectEqual(@as(usize, 0), uncompressed.len);
}

test "gzip decoding enforces decompressed message size" {
    if (comptime !features.compression) return error.SkipZigTest;
    const encoded = try encodeWithCompression(std.testing.allocator, "123456789", .gzip);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectError(
        error.MessageTooLarge,
        decodeUnaryWithCompression(std.testing.allocator, encoded, 8, .gzip),
    );
}

test "decoder accepts fragmented input and multiple messages" {
    const first = try encode(std.testing.allocator, "first");
    defer std.testing.allocator.free(first);
    const second = try encode(std.testing.allocator, "second");
    defer std.testing.allocator.free(second);

    var decoder = Decoder.init(std.testing.allocator, 1024);
    defer decoder.deinit();
    try decoder.feed(first[0..2]);
    try std.testing.expectEqual(@as(?[]u8, null), try decoder.next());
    try decoder.feed(first[2..]);
    try decoder.feed(second);

    const first_payload = (try decoder.next()).?;
    defer std.testing.allocator.free(first_payload);
    const second_payload = (try decoder.next()).?;
    defer std.testing.allocator.free(second_payload);
    try std.testing.expectEqualStrings("first", first_payload);
    try std.testing.expectEqualStrings("second", second_payload);
    try decoder.finish();
}

test "streaming decoder reports wire consumption and compression" {
    if (comptime !features.compression) return error.SkipZigTest;
    const identity = try encode(std.testing.allocator, "first");
    defer std.testing.allocator.free(identity);
    const gzip = try encodeWithCompression(std.testing.allocator, "second second second", .gzip);
    defer std.testing.allocator.free(gzip);
    const empty = try encode(std.testing.allocator, "");
    defer std.testing.allocator.free(empty);

    var decoder = Decoder.initWithCompression(std.testing.allocator, 1024, .gzip);
    defer decoder.deinit();

    try decoder.feed(identity[0..2]);
    try std.testing.expectEqual(@as(usize, 2), decoder.bufferedBytes());
    try std.testing.expectEqual(@as(?Decoder.DecodedMessage, null), try decoder.nextMessage());
    try decoder.feed(identity[2..6]);
    try std.testing.expectEqual(@as(?Decoder.DecodedMessage, null), try decoder.nextMessage());
    try decoder.feed(identity[6..]);
    try decoder.feed(gzip[0..header_size]);
    try decoder.feed(gzip[header_size .. gzip.len - 1]);

    const first = (try decoder.nextMessage()).?;
    defer std.testing.allocator.free(first.payload);
    try std.testing.expectEqualStrings("first", first.payload);
    try std.testing.expectEqual(identity.len, first.consumed_bytes);
    try std.testing.expect(!first.compressed);
    try std.testing.expectEqual(gzip.len - 1, decoder.bufferedBytes());
    try std.testing.expectEqual(@as(?Decoder.DecodedMessage, null), try decoder.nextMessage());

    try decoder.feed(gzip[gzip.len - 1 ..]);
    try decoder.feed(empty);
    const second = (try decoder.nextMessage()).?;
    defer std.testing.allocator.free(second.payload);
    try std.testing.expectEqualStrings("second second second", second.payload);
    try std.testing.expectEqual(gzip.len, second.consumed_bytes);
    try std.testing.expect(second.compressed);

    const third = (try decoder.nextMessage()).?;
    defer std.testing.allocator.free(third.payload);
    try std.testing.expectEqual(@as(usize, 0), third.payload.len);
    try std.testing.expectEqual(header_size, third.consumed_bytes);
    try std.testing.expect(!third.compressed);
    try std.testing.expectEqual(@as(usize, 0), decoder.bufferedBytes());
    try decoder.finish();
}

test "decoder enforces buffered byte admission atomically" {
    var decoder = Decoder.init(std.testing.allocator, 1024);
    defer decoder.deinit();

    try decoder.feedBounded(&.{ 0, 0, 0 }, header_size);
    try std.testing.expectEqual(@as(usize, 3), decoder.bufferedBytes());
    try std.testing.expectError(error.BufferLimitExceeded, decoder.feedBounded(&.{ 0, 0, 0 }, header_size));
    try std.testing.expectEqual(@as(usize, 3), decoder.bufferedBytes());
    try decoder.feedBounded(&.{ 0, 0 }, header_size);

    const first = (try decoder.nextMessage()).?;
    defer std.testing.allocator.free(first.payload);
    try std.testing.expectEqual(@as(usize, 0), decoder.bufferedBytes());

    try decoder.feedBounded(&.{ 0, 0, 0, 0, 0 }, header_size);
    const second = (try decoder.nextMessage()).?;
    defer std.testing.allocator.free(second.payload);
    try std.testing.expectEqual(@as(usize, 0), decoder.bufferedBytes());
    try decoder.finish();
}

test "decoder reports malformed frames" {
    var decoder = Decoder.init(std.testing.allocator, 3);
    defer decoder.deinit();

    try decoder.feed(&.{ 1, 0, 0, 0, 0 });
    try std.testing.expectError(error.CompressionMismatch, decoder.next());

    decoder.buffer.clearRetainingCapacity();
    decoder.offset = 0;
    try decoder.feed(&.{ 0, 0, 0, 0, 4 });
    try std.testing.expectError(error.MessageTooLarge, decoder.next());

    decoder.buffer.clearRetainingCapacity();
    decoder.offset = 0;
    try decoder.feed(&.{ 2, 0, 0, 0, 0 });
    try std.testing.expectError(error.InvalidCompressedFlag, decoder.next());
}

test "decoder enforces decompressed size limits" {
    if (comptime !features.compression) return error.SkipZigTest;
    const payload = try std.testing.allocator.alloc(u8, 4096);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'a');
    const encoded = try encodeWithCompression(std.testing.allocator, payload, .gzip);
    defer std.testing.allocator.free(encoded);
    const compressed_length = encoded.len - header_size;
    try std.testing.expect(compressed_length < payload.len);

    var decompressed_decoder = Decoder.initWithCompression(std.testing.allocator, compressed_length, .gzip);
    defer decompressed_decoder.deinit();
    try decompressed_decoder.feed(encoded);
    try std.testing.expectError(error.MessageTooLarge, decompressed_decoder.nextMessage());
}

test "decoder finish rejects fragmented header and payload" {
    var header_decoder = Decoder.init(std.testing.allocator, 1024);
    defer header_decoder.deinit();
    try header_decoder.feed(&.{ 0, 0, 0, 0 });
    try std.testing.expectError(error.TruncatedFrame, header_decoder.finish());

    var payload_decoder = Decoder.init(std.testing.allocator, 1024);
    defer payload_decoder.deinit();
    try payload_decoder.feed(&.{ 0, 0, 0, 0, 2, 'a' });
    try std.testing.expectEqual(@as(?Decoder.DecodedMessage, null), try payload_decoder.nextMessage());
    try std.testing.expectError(error.TruncatedFrame, payload_decoder.finish());
}

test "unary decoding rejects truncated and repeated messages" {
    try std.testing.expectError(
        error.TruncatedFrame,
        decodeUnary(std.testing.allocator, &.{ 0, 0, 0, 0, 1 }, 1024),
    );

    const first = try encode(std.testing.allocator, "one");
    defer std.testing.allocator.free(first);
    const second = try encode(std.testing.allocator, "two");
    defer std.testing.allocator.free(second);
    const combined = try std.mem.concat(std.testing.allocator, u8, &.{ first, second });
    defer std.testing.allocator.free(combined);
    try std.testing.expectError(
        error.ExpectedUnaryMessage,
        decodeUnary(std.testing.allocator, combined, 1024),
    );
}

test "readMessage: messages off a reader, null at a clean end" {
    const gpa = std.testing.allocator;
    const a = try encode(gpa, "first");
    defer gpa.free(a);
    const b = try encode(gpa, "");
    defer gpa.free(b);
    const both = try std.mem.concat(gpa, u8, &.{ a, b });
    defer gpa.free(both);
    var reader: std.Io.Reader = .fixed(both);
    const one = (try readMessage(&reader, gpa, 1024, .identity)).?;
    defer gpa.free(one.payload);
    try std.testing.expectEqualStrings("first", one.payload);
    const two = (try readMessage(&reader, gpa, 1024, .identity)).?;
    defer gpa.free(two.payload);
    try std.testing.expectEqualStrings("", two.payload);
    try std.testing.expect(try readMessage(&reader, gpa, 1024, .identity) == null);

    var cut: std.Io.Reader = .fixed(a[0 .. a.len - 1]);
    try std.testing.expectError(error.TruncatedFrame, readMessage(&cut, gpa, 1024, .identity));
}

test "fuzz: gRPC message frames, plain and gzip, fed in pieces" {
    try @import("../fuzz.zig").bytes(struct {
        const max = 1024;
        fn check(input: []const u8) !void {
            if (input.len == 0) return;
            // The first byte picks the compression and the piece size.
            const compression: Compression = if (input[0] & 1 == 1) .gzip else .identity;
            const step: usize = (input[0] >> 1) + 1;
            const wire = input[1..];
            const gpa = std.testing.allocator;

            var decoder = Decoder.initWithCompression(gpa, max, compression);
            defer decoder.deinit();
            var i: usize = 0;
            feeding: while (i < wire.len) : (i += step) {
                decoder.feed(wire[i..@min(i + step, wire.len)]) catch break;
                while (true) {
                    const m = decoder.nextMessage() catch break :feeding orelse break;
                    defer gpa.free(m.payload);
                    try std.testing.expect(m.payload.len <= max);
                }
            }

            var reader: std.Io.Reader = .fixed(wire);
            while (true) {
                const m = readMessage(&reader, gpa, max, compression) catch break orelse break;
                defer gpa.free(m.payload);
                try std.testing.expect(m.payload.len <= max);
            }
        }
    }.check, &.{
        "\x00\x00\x00\x00\x05hello\x00\x00\x00\x00\x00",
        "\x01\x01\x00\x00\x00\x1c\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xcb\x48\xcd\xc9\xc9\x57\xc8\x40\x27\x01\xe3\x51\x3d\x8d\x17\x00\x00\x00",
        // 5000 bytes once inflated: over the limit.
        "\x03\x01\x00\x00\x00\x29\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xed\xc1\x31\x01\x00\x00\x00\xc2\xa0\xac\xeb\x5f\xc2\x14\x7e\x40\x01\x00\x00\x00\x00\x6f\x03\x76\x59\xf4\x4c\x88\x13\x00\x00",
        "\x00\x00\xff\xff\xff\xff",
        // Found by this target: an empty compressed message.
        "\x01\x01\x00\x00\x00\x00",
    });
}
