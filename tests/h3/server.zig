//! A server for checking HTTP/3 with an independent client
//! (tests/h3/client.py on aioquic): downloads, uploads and echoes of any
//! size, beside HTTP/1.1 and HTTP/2 on the same routes.
//!
//!   zig build h3-test-server && zig-out/bin/h3-test-server 8443 [retry]
//!
//! With `retry`, every new client proves its address with a Retry first.
const std = @import("std");
const anole = @import("anole");
const http = anole.http;

pub const zio_options = anole.zio_options;
pub const std_options: std.Options = .{
    .logFn = anole.logFn,
    .log_level = .info,
    .log_scope_levels = &.{.{ .scope = .zio, .level = .warn }},
};

/// GET /download?n=BYTES: that many bytes, streamed.
fn download(req: *http.Request, res: *http.Response) !void {
    const n = std.fmt.parseInt(usize, req.query.get("n") orelse "0", 10) catch 0;
    var w = res.writer();
    var chunk: [16 * 1024]u8 = undefined;
    for (&chunk, 0..) |*b, i| b.* = @truncate(i);
    var left = n;
    while (left > 0) {
        const k = @min(left, chunk.len);
        try w.interface.writeAll(chunk[0..k]);
        left -= k;
    }
    try w.end();
}

/// POST /upload: the body's length and a checksum.
fn upload(req: *http.Request, res: *http.Response) !void {
    var reader_buf: [16 * 1024]u8 = undefined;
    var r = try req.reader(&reader_buf);
    var buf: [16 * 1024]u8 = undefined;
    var total: usize = 0;
    var sum: u32 = 0;
    while (true) {
        const got = r.interface.readSliceShort(&buf) catch return r.err orelse error.ReadFailed;
        if (got == 0) break;
        for (buf[0..got]) |b| sum +%= b;
        total += got;
    }
    try res.print(.text, "{d} {d}", .{ total, sum });
}

/// POST /echo: the body back, as it arrives.
fn echo(req: *http.Request, res: *http.Response) !void {
    var in_buf: [16 * 1024]u8 = undefined;
    var body = try req.reader(&in_buf);
    var out_buf: [16 * 1024]u8 = undefined;
    var out = try res.stream(&out_buf);
    _ = body.interface.streamRemaining(&out.interface) catch |err| switch (err) {
        error.ReadFailed => return body.err orelse error.Unexpected,
        error.WriteFailed => return out.err orelse error.Unexpected,
    };
    try out.end();
}

pub fn main(init: std.process.Init) !void {
    var port: u16 = 8443;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    if (args.next()) |p| port = try std.fmt.parseInt(u16, p, 10);
    const retry = if (args.next()) |a| std.mem.eql(u8, a, "retry") else false;
    var app = try anole.Server(void).init(init.gpa, .{
        .http = null,
        .https = .{ .port = port, .cert = .dev_self_signed },
        .http3 = .{ .validate_address = retry },
    }, {});
    defer app.deinit();
    app.get("/download", download);
    app.post("/upload", upload);
    app.post("/echo", echo);
    std.log.info("h3 test server on https://127.0.0.1:{d} (TCP and UDP)", .{port});
    try app.run();
}
