// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

//! zstd behind `std.Io.Writer` and `std.Io.Reader`, over the injected `zstd`
//! module (zstd.h bindings): `Compress` zstd-compresses what is written to it
//! into another writer, `Decompress` decodes what it reads from another
//! reader. Only built with `use_zstd`.
//!
//! zstd's memory comes from the allocator given to `init` (ZSTD_customMem),
//! normally a request's arena: nothing needs freeing when a response is
//! abandoned half way, and a reset arena takes it all back.
const std = @import("std");
const c = @import("zstd");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Reader = std.Io.Reader;

/// zstd's allocation hooks over `allocator`. zstd frees through these, but
/// an arena only takes memory back all at once, so free is a no-op there;
/// with another allocator the size is kept in a header.
fn customMem(allocator: *const Allocator) c.ZSTD_customMem {
    return .{ .customAlloc = zstdAlloc, .customFree = zstdFree, .@"opaque" = @constCast(allocator) };
}

const header = 16; // keeps the 16-byte alignment zstd expects

fn zstdAlloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    const allocator: *const Allocator = @ptrCast(@alignCast(ptr.?));
    const block = allocator.alignedAlloc(u8, .@"16", size + header) catch return null;
    std.mem.writeInt(usize, block[0..@sizeOf(usize)], size + header, .little);
    return block.ptr + header;
}

fn zstdFree(ptr: ?*anyopaque, address: ?*anyopaque) callconv(.c) void {
    const allocator: *const Allocator = @ptrCast(@alignCast(ptr.?));
    const p: [*]align(16) u8 = @alignCast(@as([*]u8, @ptrCast(address orelse return)) - header);
    const len = std.mem.readInt(usize, p[0..@sizeOf(usize)], .little);
    allocator.free(p[0..len]);
}

pub const Options = struct {
    level: c_int = 3,
    /// log2 of the window. Smaller is less memory per stream; RFC 9659 caps
    /// a decoder at 23 (8 MiB) for HTTP. Null leaves it to the level, cut
    /// down to `pledged_size` when that is known.
    window_log: ?c_int = 17,
    /// The input's total length, when known up front: zstd sizes its window
    /// and tables to it, and records it in the frame.
    pledged_size: ?usize = null,
};

pub const Compress = struct {
    writer: Writer,
    output: *Writer,
    ctx: *c.ZSTD_CCtx,
    /// Kept so `customMem` has a stable pointer to it.
    allocator: Allocator,
    err: ?Error = null,

    pub const Error = error{ OutOfMemory, CompressFailed };

    /// Writes into `output`, which must have a buffer; `buffer` sits in
    /// front of the compressor and may be empty. Call `finish`.
    pub fn init(self: *Compress, allocator: Allocator, output: *Writer, buffer: []u8, options: Options) Error!void {
        std.debug.assert(output.buffer.len > 0);
        self.* = .{
            .writer = .{ .buffer = buffer, .vtable = &.{ .drain = drain, .flush = flushFn } },
            .output = output,
            .ctx = undefined,
            .allocator = allocator,
        };
        self.ctx = c.ZSTD_createCCtx_advanced(customMem(&self.allocator)) orelse return error.OutOfMemory;
        if (c.ZSTD_isError(c.ZSTD_CCtx_setParameter(self.ctx, c.ZSTD_c_compressionLevel, options.level)) != 0)
            return error.CompressFailed;
        if (options.window_log) |log| {
            if (c.ZSTD_isError(c.ZSTD_CCtx_setParameter(self.ctx, c.ZSTD_c_windowLog, log)) != 0) return error.CompressFailed;
        }
        if (options.pledged_size) |size| {
            if (c.ZSTD_isError(c.ZSTD_CCtx_setPledgedSrcSize(self.ctx, size)) != 0) return error.CompressFailed;
        }
    }

    /// Ends the frame and flushes it to `output`'s buffer (not further).
    pub fn finish(self: *Compress) Writer.Error!void {
        try self.compress(self.writer.buffered(), c.ZSTD_e_end);
        self.writer.end = 0;
    }

    fn compress(self: *Compress, bytes: []const u8, mode: c.ZSTD_EndDirective) Writer.Error!void {
        var in: c.ZSTD_inBuffer = .{ .src = bytes.ptr, .size = bytes.len, .pos = 0 };
        while (true) {
            const dest = try self.output.writableSliceGreedy(1);
            var out: c.ZSTD_outBuffer = .{ .dst = dest.ptr, .size = dest.len, .pos = 0 };
            const remaining = c.ZSTD_compressStream2(self.ctx, &out, &in, mode);
            if (c.ZSTD_isError(remaining) != 0) {
                self.err = error.CompressFailed;
                return error.WriteFailed;
            }
            self.output.advance(out.pos);
            const done = if (mode == c.ZSTD_e_continue) in.pos == in.size else remaining == 0;
            if (done) return;
        }
    }

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const self: *Compress = @alignCast(@fieldParentPtr("writer", w));
        try self.compress(w.buffered(), c.ZSTD_e_continue);
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.compress(bytes, c.ZSTD_e_continue);
            n += bytes.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| try self.compress(pattern, c.ZSTD_e_continue);
        return n + pattern.len * splat;
    }

    /// Makes everything written so far decodable (a zstd block boundary),
    /// so a streamed response can be read as it goes.
    fn flushFn(w: *Writer) Writer.Error!void {
        const self: *Compress = @alignCast(@fieldParentPtr("writer", w));
        try self.compress(w.buffered(), c.ZSTD_e_flush);
        w.end = 0;
        try self.output.flush();
    }
};

pub const Decompress = struct {
    reader: Reader,
    input: *Reader,
    ctx: *c.ZSTD_DCtx,
    allocator: Allocator,
    err: ?Error = null,
    /// The frame ended; anything after it is not ours.
    done: bool = false,

    pub const Error = error{ OutOfMemory, InvalidZstd, TruncatedInput };

    /// Reads from `input`, which must have a buffer. `window_log_max` caps
    /// the window a frame may ask for (23, 8 MiB, for HTTP per RFC 9659).
    pub fn init(self: *Decompress, allocator: Allocator, input: *Reader, buffer: []u8, window_log_max: c_int) Error!void {
        std.debug.assert(input.buffer.len > 0);
        self.* = .{
            .reader = .{ .buffer = buffer, .seek = 0, .end = 0, .vtable = &.{ .stream = stream } },
            .input = input,
            .ctx = undefined,
            .allocator = allocator,
        };
        self.ctx = c.ZSTD_createDCtx_advanced(customMem(&self.allocator)) orelse return error.OutOfMemory;
        if (c.ZSTD_isError(c.ZSTD_DCtx_setParameter(self.ctx, c.ZSTD_d_windowLogMax, window_log_max)) != 0)
            return error.InvalidZstd;
    }

    fn stream(r: *Reader, w: *Writer, limit: std.Io.Limit) Reader.StreamError!usize {
        const self: *Decompress = @alignCast(@fieldParentPtr("reader", r));
        if (self.done) return error.EndOfStream;
        const dest = limit.slice(try w.writableSliceGreedy(1));
        while (true) {
            const src = self.input.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => {
                    self.err = error.TruncatedInput;
                    return error.ReadFailed;
                },
                error.ReadFailed => return error.ReadFailed,
            };
            var in: c.ZSTD_inBuffer = .{ .src = src.ptr, .size = src.len, .pos = 0 };
            var out: c.ZSTD_outBuffer = .{ .dst = dest.ptr, .size = dest.len, .pos = 0 };
            const rc = c.ZSTD_decompressStream(self.ctx, &out, &in);
            self.input.toss(in.pos);
            if (c.ZSTD_isError(rc) != 0) {
                self.err = error.InvalidZstd;
                return error.ReadFailed;
            }
            if (rc == 0) self.done = true;
            if (out.pos > 0) {
                w.advance(out.pos);
                return out.pos;
            }
            if (self.done) return error.EndOfStream;
        }
    }
};
