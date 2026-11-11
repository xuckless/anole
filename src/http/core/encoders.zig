//! One zstd context and one gzip encoder per thread for buffered bodies,
//! reused from one response to the next instead of made for each.
//!
//! A buffered body is compressed without yielding (`Response.compressBody`),
//! and under zio a thread is an executor, so one set serves every buffered
//! response an executor compresses, with no lock. What reuse saves:
//! - zstd: creating a context and clearing its tables, 14-23% of a zstd
//!   response's CPU on 4-8 KB of JSON. A reused context keeps its tables
//!   between frames (zstd's index continuation) and only resets the session.
//! - gzip: `deflateInit2` and its allocation, about 1%; `deflateReset`
//!   still clears the hash head each time.
//! Streamed bodies keep an encoder of their own: they yield between writes.
//!
//! With `-Dlibdeflate`, buffered gzip goes through one libdeflate
//! compressor per thread instead (`deflater`), which compresses one
//! contiguous input into one output in one call: both live in a per-thread
//! scratch (`scratch`), the input only when the body is in more than one
//! segment.
//!
//! All are made on first use from `block_cache` (not the request's arena,
//! which is reset under them). `trimLocal` frees each one no response took
//! since the last trim, and `freeLocal` all of them; the server's trim task
//! calls both on each executor. Brotli has no reset, so it stays per
//! response (research/s2/k4-compression.md, S1).
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const safety = @import("anole_safety");
const zlib = @import("zlib");
const zstd_io = if (build_options.use_zstd) @import("zstd_io.zig") else struct {};
const libdeflate_io = if (build_options.use_libdeflate) @import("libdeflate_io.zig") else struct {};
const block_cache = @import("block_cache.zig");

/// A zstd context past this after a frame is freed rather than kept: a
/// large body grows its workspace, which would otherwise stay until the
/// trim (or zstd's own 128-frame "wasteful" rule).
pub const max_zstd_context = 1024 * 1024;

/// Largest body gzipped by libdeflate; a larger one is gzipped by zlib-ng
/// as it streams, without a copy (and without a scratch that size).
pub const max_gather = 1024 * 1024;

/// A scratch past this after a response is freed rather than kept (back to
/// `block_cache`, which keeps its pages for the next large body until its
/// own trim): the bodies most responses compress are a few KB.
pub const max_kept_scratch = 64 * 1024;

/// zlib-ng's gzip options for responses, the thread's encoder made with
/// them. Level 1 there codes with the fixed Huffman table only
/// (`deflate_quick`), 4% larger than 2 on JSON of 4-8 KB; 2 is as small as
/// libdeflate's 1 and 11% larger than zlib's default 6, at a fraction of
/// its time (research/s2/k4-compression.md, §2). The window is zlib's
/// largest, whatever the body: a reused encoder keeps the options it was
/// made with.
pub const gzip_options: zlib.Options = .{ .level = @fromBackingInt(@intCast(2)), .window_bits = 15, .mem_level = 8 };

/// libdeflate's level for buffered gzip responses (`-Dlibdeflate`): 1,
/// which unlike zlib-ng's 1 builds dynamic Huffman codes, as small as
/// zlib-ng's 2 on JSON of 4-8 KB.
pub const libdeflate_level: c_int = 1;

pub const Deflater = if (build_options.use_libdeflate) libdeflate_io.Compressor else void;

const Local = struct {
    zstd: if (build_options.use_zstd) ?*zstd_io.Context else void = if (build_options.use_zstd) null else {},
    gzip: if (build_options.use_zlib) ?zlib.Compress else void = if (build_options.use_zlib) null else {},
    deflater: if (build_options.use_libdeflate) ?*Deflater else void = if (build_options.use_libdeflate) null else {},
    /// `scratch`'s memory, from `block_cache`.
    scratch: []u8 = &.{},
    /// Which were taken since the last `trimLocal`.
    used: Used = .{},
    /// Safe builds: an encoder is out (between `zstd`/`gzip` and
    /// `release`). A second taker would share its state.
    in_use: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},
};

const Used = packed struct {
    zstd: bool = false,
    gzip: bool = false,
    /// The libdeflate compressor and the scratch.
    deflater: bool = false,
};

threadlocal var local: Local = .{};

/// Tests only: encoders made on this thread and not freed.
threadlocal var live_for_test: isize = 0;

/// The encoders are shared by every task on the thread, so a taker holds
/// them in a read section until `release` (SAFETY.md M3): a task that
/// suspends first panics in debug builds, naming `site`.
fn take(comptime which: std.meta.FieldEnum(Used), site: usize) void {
    safety.readSectionEntered(site);
    if (std.debug.runtime_safety) {
        std.debug.assert(!local.in_use); // an encoder held across a yield
        local.in_use = true;
    }
    @field(local.used, @tagName(which)) = true;
}

/// This thread's zstd context, set up for a new frame into `output` at
/// `level` (the window from the level, cut down to `len`). Call `release`
/// once the frame is finished or abandoned, before anything yields.
pub fn zstd(z: *zstd_io.Compress, output: *std.Io.Writer, level: c_int, len: usize) zstd_io.Compress.Error!void {
    comptime std.debug.assert(build_options.use_zstd);
    const ctx = local.zstd orelse blk: {
        const ctx = zstd_io.createContext(&block_cache.allocator) orelse return error.OutOfMemory;
        local.zstd = ctx;
        if (builtin.is_test) live_for_test += 1;
        break :blk ctx;
    };
    take(.zstd, @returnAddress());
    errdefer release();
    try z.initWith(ctx, output, &.{}, .{ .level = level, .window_log = null, .pledged_size = len });
}

/// This thread's gzip encoder (`gzip_options`), writing a new stream into
/// `output`. Call `release` once the stream is finished or abandoned,
/// before anything yields.
pub fn gzip(output: *std.Io.Writer) std.mem.Allocator.Error!*zlib.Compress {
    comptime std.debug.assert(build_options.use_zlib);
    if (local.gzip) |*g| {
        take(.gzip, @returnAddress());
        g.reset(output);
        return g;
    }
    local.gzip = try zlib.Compress.init(block_cache.allocator, output, &.{}, .gzip, gzip_options);
    if (builtin.is_test) live_for_test += 1;
    take(.gzip, @returnAddress());
    return &local.gzip.?;
}

/// This thread's libdeflate compressor (`libdeflate_level`), or null when
/// out of memory. Call `release` once done with it and with `scratch`,
/// before anything yields.
pub fn deflater() ?*Deflater {
    comptime std.debug.assert(build_options.use_libdeflate);
    const d = local.deflater orelse blk: {
        const d = libdeflate_io.create(libdeflate_level) orelse return null;
        local.deflater = d;
        if (builtin.is_test) live_for_test += 1;
        break :blk d;
    };
    take(.deflater, @returnAddress());
    return d;
}

/// `input` gzipped into `out` by `d`: the length written, or 0 when it
/// does not fit.
pub fn deflateInto(d: *Deflater, input: []const u8, out: []u8) usize {
    comptime std.debug.assert(build_options.use_libdeflate);
    return libdeflate_io.gzip(d, input, out);
}

pub const Scratch = struct {
    /// For a body gathered into one piece.
    input: []u8,
    /// For libdeflate's output.
    output: []u8,
};

/// This thread's scratch: `input_len` bytes for a gathered body (0 for a
/// contiguous one) and `output_len` for the output, each at most
/// `max_gather`; null when out of memory. Only between `deflater` and
/// `release`, which frees it if it is larger than `max_kept_scratch`.
pub fn scratch(input_len: usize, output_len: usize) ?Scratch {
    std.debug.assert(input_len <= max_gather and output_len <= max_gather);
    const len = input_len + output_len;
    if (local.scratch.len < len) {
        freeScratch();
        // Rounded up, so a body a little longer than the last takes the
        // same scratch.
        const size = std.mem.alignForward(usize, len, 16 * 1024);
        local.scratch = block_cache.allocator.alloc(u8, size) catch return null;
    }
    return .{ .input = local.scratch[0..input_len], .output = local.scratch[input_len..len] };
}

fn freeScratch() void {
    if (local.scratch.len == 0) return;
    block_cache.allocator.free(local.scratch);
    local.scratch = &.{};
}

fn freeDeflater() void {
    if (build_options.use_libdeflate) if (local.deflater) |d| {
        libdeflate_io.destroy(d);
        local.deflater = null;
        if (builtin.is_test) live_for_test -= 1;
    };
}

/// Ends a use of `zstd`, `gzip` or `deflater`. Drops a zstd context that
/// grew past `max_zstd_context` and a scratch past `max_kept_scratch`.
pub fn release() void {
    if (std.debug.runtime_safety) local.in_use = false;
    safety.readSectionLeft(@returnAddress());
    if (build_options.use_zstd) if (local.zstd) |ctx| {
        if (zstd_io.contextSize(ctx) > max_zstd_context) freeZstd();
    };
    if (local.scratch.len > max_kept_scratch) freeScratch();
}

fn freeZstd() void {
    if (build_options.use_zstd) if (local.zstd) |ctx| {
        zstd_io.freeContext(ctx);
        local.zstd = null;
        if (builtin.is_test) live_for_test -= 1;
    };
}

fn freeGzip() void {
    if (build_options.use_zlib) if (local.gzip) |*g| {
        g.deinit();
        local.gzip = null;
        if (builtin.is_test) live_for_test -= 1;
    };
}

/// Frees each of this thread's encoders that no response took since the
/// last call. Their memory goes back to `block_cache`, whose own trim
/// unmaps it.
pub fn trimLocal() void {
    if (std.debug.runtime_safety) std.debug.assert(!local.in_use);
    defer local.used = .{};
    if (!local.used.zstd) freeZstd();
    if (!local.used.gzip) freeGzip();
    if (!local.used.deflater) {
        freeDeflater();
        freeScratch();
    }
}

/// Frees this thread's encoders. Not while one is out.
pub fn freeLocal() void {
    if (std.debug.runtime_safety) std.debug.assert(!local.in_use);
    freeZstd();
    freeGzip();
    freeDeflater();
    freeScratch();
}

/// Tests only: how many encoders this thread made and has not freed.
pub fn liveForTest() isize {
    if (!builtin.is_test) @compileError("liveForTest is for tests");
    return live_for_test;
}

/// Tests only: frees this thread's encoders, so a test starts from none
/// whatever ran before it on the thread.
pub fn drainLocalForTest() void {
    if (!builtin.is_test) @compileError("drainLocalForTest is for tests");
    freeLocal();
    local.used = .{};
}

fn testBody(allocator: std.mem.Allocator, items: usize) ![]u8 {
    var text: std.Io.Writer.Allocating = .init(allocator);
    errdefer text.deinit();
    for (0..items) |i| try text.writer.print("{{\"id\":{d},\"name\":\"Widget {d}\",\"price\":{d}}},", .{ i, i % 97, i * 37 % 5003 });
    return text.toOwnedSlice();
}

fn testGzip(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
    errdefer out.deinit();
    const g = try gzip(&out.writer);
    defer release();
    try g.writer.writeAll(body);
    try g.finish();
    return out.toOwnedSlice();
}

fn testGunzip(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(encoded);
    var d = try zlib.Decompress.init(allocator, &in, &.{}, .gzip, .{});
    defer d.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    _ = try d.reader.streamRemaining(&out.writer);
    return out.toOwnedSlice();
}

fn testZstd(allocator: std.mem.Allocator, body: []const u8, level: c_int) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
    errdefer out.deinit();
    var z: zstd_io.Compress = undefined; // SAFETY: `zstd` sets it up before any use
    try zstd(&z, &out.writer, level, body.len);
    defer release();
    try z.writer.writeAll(body);
    try z.finish();
    return out.toOwnedSlice();
}

fn testUnzstd(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var in: std.Io.Reader = .fixed(encoded);
    var d: zstd_io.Decompress = undefined; // SAFETY: `init` sets it up before any use
    var buf: [4096]u8 = undefined;
    try d.init(arena.allocator(), &in, &buf, 23);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    _ = try d.reader.streamRemaining(&out.writer);
    return out.toOwnedSlice();
}

test "compress: reused gzip encoder gives identical output for the same body twice" {
    if (!build_options.use_zlib) return error.SkipZigTest;
    drainLocalForTest();
    defer drainLocalForTest();
    const a = std.testing.allocator;
    const body = try testBody(a, 120);
    defer a.free(body);
    const first = try testGzip(a, body);
    defer a.free(first);
    const live = liveForTest();
    const second = try testGzip(a, body);
    defer a.free(second);
    // The second took the first's encoder rather than a new one.
    try std.testing.expectEqual(live, liveForTest());
    try std.testing.expectEqualSlices(u8, first, second);
    const decoded = try testGunzip(a, second);
    defer a.free(decoded);
    try std.testing.expectEqualStrings(body, decoded);
}

test "compress: a body after a larger one decodes" {
    if (!build_options.use_zstd) return error.SkipZigTest;
    drainLocalForTest();
    defer drainLocalForTest();
    const a = std.testing.allocator;
    const large = try testBody(a, 4000);
    defer a.free(large);
    const small = try testBody(a, 50);
    defer a.free(small);
    for ([_][]const u8{ small, large, small }) |body| {
        const encoded = try testZstd(a, body, 1);
        defer a.free(encoded);
        const decoded = try testUnzstd(a, encoded);
        defer a.free(decoded);
        try std.testing.expectEqualStrings(body, decoded);
    }
    try std.testing.expectEqual(@as(isize, 1), liveForTest());
}

test "compress: an oversized zstd context is dropped after the response" {
    if (!build_options.use_zstd) return error.SkipZigTest;
    drainLocalForTest();
    defer drainLocalForTest();
    const a = std.testing.allocator;
    // At level 3 a 4 MiB body takes a 2 MiB window.
    const body = try a.alloc(u8, 4 * 1024 * 1024);
    defer a.free(body);
    var prng: std.Random.DefaultPrng = .init(1);
    for (body) |*b| b.* = 'a' + prng.random().uintLessThan(u8, 16);
    const encoded = try testZstd(a, body, 3);
    defer a.free(encoded);
    try std.testing.expectEqual(@as(isize, 0), liveForTest());
    try std.testing.expect(local.zstd == null);
    const decoded = try testUnzstd(a, encoded);
    defer a.free(decoded);
    try std.testing.expectEqualSlices(u8, body, decoded);
}

test "compress: an abandoned compression leaves the encoder usable" {
    if (!(build_options.use_zlib and build_options.use_zstd)) return error.SkipZigTest;
    drainLocalForTest();
    defer drainLocalForTest();
    const a = std.testing.allocator;
    const body = try testBody(a, 2000);
    defer a.free(body);

    // An output that fills up part way, as a response whose arena runs out.
    {
        var small: [64]u8 = undefined;
        var out: std.Io.Writer = .fixed(&small);
        const g = try gzip(&out);
        defer release();
        try std.testing.expectError(error.WriteFailed, blk: {
            g.writer.writeAll(body) catch |err| break :blk err;
            break :blk g.finish();
        });
    }
    {
        var small: [64]u8 = undefined;
        var out: std.Io.Writer = .fixed(&small);
        var z: zstd_io.Compress = undefined;
        try zstd(&z, &out, 1, body.len);
        defer release();
        try std.testing.expectError(error.WriteFailed, blk: {
            z.writer.writeAll(body) catch |err| break :blk err;
            break :blk z.finish();
        });
    }

    const gz = try testGzip(a, body);
    defer a.free(gz);
    const gz_decoded = try testGunzip(a, gz);
    defer a.free(gz_decoded);
    try std.testing.expectEqualStrings(body, gz_decoded);

    const zs = try testZstd(a, body, 1);
    defer a.free(zs);
    const zs_decoded = try testUnzstd(a, zs);
    defer a.free(zs_decoded);
    try std.testing.expectEqualStrings(body, zs_decoded);
}

test "compress: libdeflate gzips a gathered body, reusing its compressor and scratch" {
    if (!(build_options.use_zlib and build_options.use_libdeflate)) return error.SkipZigTest;
    drainLocalForTest();
    defer drainLocalForTest();
    const a = std.testing.allocator;
    const body = try testBody(a, 150);
    defer a.free(body);
    var first_scratch: ?[*]u8 = null;
    for (0..2) |_| {
        const d = deflater().?;
        defer release();
        const s = scratch(body.len, body.len - 1).?;
        const in = s.input;
        if (first_scratch) |p| try std.testing.expectEqual(p, in.ptr) else first_scratch = in.ptr;
        @memcpy(in, body);
        const out = s.output;
        const n = deflateInto(d, in, out);
        try std.testing.expect(n > 0 and n < body.len);
        const decoded = try testGunzip(a, out[0..n]);
        defer a.free(decoded);
        try std.testing.expectEqualStrings(body, decoded);
    }
    try std.testing.expectEqual(@as(isize, 1), liveForTest());
    // Output that cannot shrink does not fit, and says so.
    var noise: [600]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(7);
    prng.random().bytes(&noise);
    var out: [599]u8 = undefined;
    const d = deflater().?;
    defer release();
    try std.testing.expectEqual(@as(usize, 0), deflateInto(d, &noise, &out));
}

test "compress: trim frees idle encoders" {
    if (!(build_options.use_zlib and build_options.use_zstd)) return error.SkipZigTest;
    drainLocalForTest();
    defer drainLocalForTest();
    const a = std.testing.allocator;
    const body = try testBody(a, 50);
    defer a.free(body);
    a.free(try testGzip(a, body));
    a.free(try testZstd(a, body, 1));
    try std.testing.expectEqual(@as(isize, 2), liveForTest());
    // Used since the last trim: kept.
    trimLocal();
    try std.testing.expectEqual(@as(isize, 2), liveForTest());
    // Not used since: freed.
    trimLocal();
    try std.testing.expectEqual(@as(isize, 0), liveForTest());
}

test "compress: trim frees each idle encoder on its own" {
    if (!(build_options.use_zlib and build_options.use_zstd)) return error.SkipZigTest;
    drainLocalForTest();
    defer drainLocalForTest();
    const a = std.testing.allocator;
    const body = try testBody(a, 50);
    defer a.free(body);
    a.free(try testGzip(a, body));
    a.free(try testZstd(a, body, 1));
    trimLocal();
    try std.testing.expectEqual(@as(isize, 2), liveForTest());
    // Only zstd since: gzip's encoder goes, zstd's stays.
    a.free(try testZstd(a, body, 1));
    trimLocal();
    try std.testing.expectEqual(@as(isize, 1), liveForTest());
    try std.testing.expect(local.gzip == null);
    try std.testing.expect(local.zstd != null);
}

test "compress: a scratch past max_kept_scratch is freed after the response" {
    if (!build_options.use_libdeflate) return error.SkipZigTest;
    drainLocalForTest();
    defer drainLocalForTest();
    {
        _ = deflater().?;
        defer release();
        const s = scratch(4096, 4095).?;
        try std.testing.expectEqual(@as(usize, 4096), s.input.len);
        try std.testing.expectEqual(@as(usize, 4095), s.output.len);
    }
    // A small one stays for the next response.
    try std.testing.expect(local.scratch.len > 0);
    {
        _ = deflater().?;
        defer release();
        _ = scratch(0, max_kept_scratch + 1).?;
    }
    try std.testing.expectEqual(@as(usize, 0), local.scratch.len);
}
