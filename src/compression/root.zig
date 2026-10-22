//! Compression: zlib-ng 2.3.3 in zlib-compat mode (gzip, zlib and raw
//! deflate; built by build/zlib_ng.zig with runtime SIMD dispatch) behind
//! lalinsky/zlib.zig's `std.Io` wrapper, and zstd 1.5.7 (build/zstd.zig) as
//! translated C bindings. With -Dbrotli, Brotli 1.2.0 (build/brotli.zig) the
//! same way.
//!
//! Responses are compressed by `anole.middleware.Compress` (or
//! `res.compress = true`), and request bodies inflated by the server, with
//! nothing from here. This namespace is for compressing or inflating data
//! of your own.
const std = @import("std");
const features = @import("build_options");

/// `Compress` (a `std.Io.Writer` that deflates) and `Decompress` (a
/// `std.Io.Reader` that inflates) over zlib-ng; the same module the core uses.
pub const zlib = @import("anole_zlib");

/// zstd.h.
pub const zstd = @import("anole_zstd_c");

/// brotli/encode.h and brotli/decode.h (-Dbrotli).
pub const brotli = if (features.brotli) @import("anole_brotli_c") else struct {};

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

// zstd and gzip through dusty, over loopback: a response marked compress is
// sent zstd when the client accepts it (preferred over gzip), and a zstd
// request body is decoded before the handler sees it.

const dusty = @import("dusty");
const zio = @import("zio");

fn bigHandler(_: *dusty.Request, res: *dusty.Response) !void {
    res.compress = true;
    var w = try res.writer();
    for (0..300) |i| try w.interface.print("row {d}: compressible compressible compressible\n", .{i});
    try w.end();
}

fn echoHandler(req: *dusty.Request, res: *dusty.Response) !void {
    res.body = (try req.body()) orelse "";
}

fn exchange(io: std.Io, addr: std.Io.net.IpAddress, request: []const u8, out: []u8) ![]const u8 {
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var wbuf: [512]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.writeAll(request);
    try w.interface.flush();
    var rbuf: [4096]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    var fw: std.Io.Writer = .fixed(out);
    _ = r.interface.streamRemaining(&fw) catch |err| switch (err) {
        error.WriteFailed => return error.ResponseTooLarge,
        else => |e| return e,
    };
    return fw.buffered();
}

test "dusty on zstd: zstd responses (preferred over gzip) and zstd request bodies" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();

    const loopback: dusty.Address = .{ .ip = .{ .ip4 = .loopback(0) } };
    var server = dusty.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = loopback }} }, {});
    defer server.deinit();
    server.router.get("/big", bigHandler);
    server.router.post("/echo", echoHandler);
    var future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);
    const addr = server.address.ip;

    var out: [64 * 1024]u8 = undefined;
    const resp = try exchange(io, addr, "GET /big HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip, zstd\r\nConnection: close\r\n\r\n", &out);
    const split = std.mem.indexOf(u8, resp, "\r\n\r\n").?;
    const head = resp[0..split];
    try std.testing.expect(std.mem.indexOf(u8, head, "Content-Encoding: zstd") != null);
    try std.testing.expect(std.mem.indexOf(u8, head, "Vary: Accept-Encoding") != null);
    const body = resp[split + 4 ..];
    var plain: [32 * 1024]u8 = undefined;
    const n = zstd.ZSTD_decompress(&plain, plain.len, body.ptr, body.len);
    try std.testing.expectEqual(@as(c_uint, 0), zstd.ZSTD_isError(n));
    try std.testing.expect(std.mem.startsWith(u8, plain[0..n], "row 0: compressible"));
    try std.testing.expect(body.len < n / 5);

    // A zstd request body, decoded for the handler.
    const text = "a zstd request body for the echo handler";
    var frame: [256]u8 = undefined;
    const fn_len = zstd.ZSTD_compress(&frame, frame.len, text.ptr, text.len, 3);
    try std.testing.expectEqual(@as(c_uint, 0), zstd.ZSTD_isError(fn_len));
    var req_buf: [512]u8 = undefined;
    var rw: std.Io.Writer = .fixed(&req_buf);
    try rw.print("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Encoding: zstd\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{fn_len});
    try rw.writeAll(frame[0..fn_len]);
    const echoed = try exchange(io, addr, rw.buffered(), &out);
    try std.testing.expect(std.mem.endsWith(u8, echoed, text));
}

test "dusty on Brotli: br when the client takes gzip and br, as browsers and HttpArena send" {
    if (!features.brotli) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();

    const loopback: dusty.Address = .{ .ip = .{ .ip4 = .loopback(0) } };
    var server = dusty.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = loopback }} }, {});
    defer server.deinit();
    server.router.get("/big", bigHandler);
    var future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);
    const addr = server.address.ip;

    var out: [64 * 1024]u8 = undefined;
    const resp = try exchange(io, addr, "GET /big HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip, br\r\nConnection: close\r\n\r\n", &out);
    const split = std.mem.indexOf(u8, resp, "\r\n\r\n").?;
    const head = resp[0..split];
    try std.testing.expect(std.mem.indexOf(u8, head, "Content-Encoding: br") != null);
    try std.testing.expect(std.mem.indexOf(u8, head, "Vary: Accept-Encoding") != null);
    const body = resp[split + 4 ..];
    var plain: [32 * 1024]u8 = undefined;
    var n: usize = plain.len;
    try std.testing.expect(brotli.BrotliDecoderDecompress(body.len, body.ptr, &n, &plain) == brotli.BROTLI_DECODER_RESULT_SUCCESS);
    try std.testing.expect(std.mem.startsWith(u8, plain[0..n], "row 0: compressible"));
    try std.testing.expect(std.mem.endsWith(u8, plain[0..n], "row 299: compressible compressible compressible\n"));
    try std.testing.expect(body.len < n / 5);
}
