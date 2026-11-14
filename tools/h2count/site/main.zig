//! The upstream test site for tools/h2count (the flood-budget calibration):
//! a page with 100 subresources, a 64 MiB download, an upload sink, a slow
//! SSE stream and a 2 s endpoint to cancel. Bodies are generated, nothing
//! is read from disk. h2c with prior knowledge and HTTP/1.1 on one port.
//!
//!   zig build run-h2count-site -- 8080
//!
//!   zig build run-h2count-site -- 8080 8443 cert.pem key.pem   (also TLS, for clients that go straight at it)
//!
//!   GET  /done?s=X&ok=0|1&err=  logs "done s=X ok=1" (the result channel of /drive, read by scenarios/run.sh)
//!   GET  /drive?s=X  a page that makes a browser reload, cancel, stream and upload (scenarios/run.sh)
//!   GET  /           HTML with 60 images, 20 scripts and 20 stylesheets
//!   GET  /r/:n       a few hundred bytes (the subresources)
//!   GET  /download   64 MiB of a fixed pattern
//!   POST /upload     reads and discards the body, answers with its size
//!   GET  /sse        an event every 100 ms for 20 s
//!   GET  /slow       answers after 2 s (a cancellation target)
const std = @import("std");
const anole = @import("anole");

pub const std_options = anole.std_options;
pub const panic = anole.panic;

fn page(_: *anole.Request, res: *anole.Response) !void {
    res.content_type = .html;
    var w = try res.writer();
    try w.interface.writeAll("<!doctype html><html><head><title>h2count</title>\n");
    for (0..20) |i| try w.interface.print("<link rel=stylesheet href=\"/r/{d}.css\">\n", .{i});
    try w.interface.writeAll("</head><body>\n");
    for (0..60) |i| try w.interface.print("<img src=\"/r/{d}.png\" width=8 height=8>\n", .{20 + i});
    for (0..20) |i| try w.interface.print("<script src=\"/r/{d}.js\"></script>\n", .{80 + i});
    try w.interface.writeAll("</body></html>\n");
    try w.end();
}

const drive_html = @embedFile("drive.html");

fn drive(_: *anole.Request, res: *anole.Response) !void {
    res.body = drive_html;
    res.content_type = .html;
}

fn done(req: *anole.Request, res: *anole.Response) !void {
    const q = req.query;
    std.debug.print("done s={s} ok={s} err={s}\n", .{ q.get("s") orelse "?", q.get("ok") orelse "?", q.get("err") orelse "" });
    res.status = .no_content;
}

fn small(req: *anole.Request, res: *anole.Response) !void {
    const n = req.params.get("n") orelse "0";
    try res.print(.text, "resource {s}: the quick brown fox jumps over the lazy dog, again and again and again and again and again and again and again and again and again.\n", .{n});
}

const download_size: usize = 64 << 20;

fn download(_: *anole.Request, res: *anole.Response) !void {
    var out_buf: [16 * 1024]u8 = undefined;
    var out = try res.stream(&out_buf);
    const chunk: [16 * 1024]u8 = @splat('x');
    var left: usize = download_size;
    while (left > 0) {
        const n = @min(left, chunk.len);
        try out.interface.writeAll(chunk[0..n]);
        left -= n;
    }
    try out.end();
}

fn upload(req: *anole.Request, res: *anole.Response) !void {
    var in_buf: [16 * 1024]u8 = undefined;
    var body = try req.reader(&in_buf);
    const n = body.interface.discardRemaining() catch |err| switch (err) {
        error.ReadFailed => return body.err orelse error.Unexpected,
    };
    try res.print(.text, "{d}\n", .{n});
}

fn sse(req: *anole.Request, res: *anole.Response) !void {
    req.setTimeout(null); // a stream, not a request with a deadline
    var buf: [1024]u8 = undefined;
    var stream = try res.startEventStream(&buf);
    for (0..200) |i| {
        var line: [32]u8 = undefined;
        try stream.send(try std.fmt.bufPrint(&line, "tick {d}", .{i}), .{ .event = "tick" });
        try req.io.sleep(.fromMilliseconds(100), .awake);
    }
    try stream.body.end();
}

fn slow(req: *anole.Request, res: *anole.Response) !void {
    try req.io.sleep(.fromSeconds(2), .awake);
    try res.print(.text, "done\n", .{});
}

pub fn main(init: std.process.Init) !void {
    var port: u16 = 8080;
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    if (args.next()) |p| port = try std.fmt.parseInt(u16, p, 10);
    const tls_port = if (args.next()) |p| try std.fmt.parseInt(u16, p, 10) else null;
    const cert = args.next();
    const key = args.next();

    var app = try anole.Server(void).init(init.gpa, .{
        .http = .{ .port = port, .h2c = true },
        .https = if (tls_port) |p| .{ .address = "127.0.0.1", .port = p, .cert = .{ .files = .{ .cert_path = cert orelse return error.MissingCert, .key_path = key orelse return error.MissingKey } } } else null,
        // The upload sink streams its body, so allow a big one.
        .limits = .{ .body_max = 256 << 20 },
        .process = init.minimal,
    }, {});
    defer app.deinit();
    app.get("/", page);
    app.get("/drive", drive);
    app.get("/done", done);
    app.get("/r/:n", small);
    app.get("/download", download);
    app.post("/upload", upload);
    app.get("/sse", sse);
    app.get("/slow", slow);
    try app.run();
}
