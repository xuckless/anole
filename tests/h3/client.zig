//! anole.h3's client from the command line, for checks against an
//! independent HTTP/3 server (tests/h3/peer_server.py, on aioquic).
//!
//!   h3-test-client cert DIR                  write cert.pem and key.pem
//!   h3-test-client get PORT CA PATH          one GET
//!   h3-test-client post PORT CA PATH FILE    one POST with FILE as body
//!   h3-test-client many PORT CA PATH N       N GETs at once, one connection
//!
//! A response prints as "status S bytes N sum X" (X: the byte sum, mod
//! 2^32), then "trailer NAME VALUE" for each trailer.
const std = @import("std");
const anole = @import("anole");

pub const zio_options = anole.zio_options;
pub const std_options: std.Options = .{
    .log_level = .info,
    .log_scope_levels = &.{.{ .scope = .zio, .level = .warn }},
};

const h3 = anole.h3;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const cmd = args.next() orelse return error.Usage;
    const rt = try anole.zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &out_buf);
    const w = &out.interface;
    defer w.flush() catch {};

    if (std.mem.eql(u8, cmd, "cert")) {
        const dir_path = args.next() orelse return error.Usage;
        var pem = try anole.tls.selfSigned(gpa, .{});
        defer pem.deinit(gpa);
        const dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
        defer dir.close(io);
        try dir.writeFile(io, .{ .sub_path = "cert.pem", .data = pem.cert });
        try dir.writeFile(io, .{ .sub_path = "key.pem", .data = pem.key });
        return;
    }

    const port = try std.fmt.parseInt(u16, args.next() orelse return error.Usage, 10);
    const ca_pem = try std.Io.Dir.cwd().readFileAlloc(io, args.next() orelse return error.Usage, gpa, .limited(1 << 20));
    defer gpa.free(ca_pem);
    const path = args.next() orelse return error.Usage;

    const conn = try h3.ClientConnection.connect(gpa, io, .{
        .host = "localhost",
        .address = .{ .ip4 = .loopback(port) },
        .port = port,
        .tls = .{ .ca = .{ .pem = ca_pem } },
    });
    defer conn.close();

    if (std.mem.eql(u8, cmd, "get")) {
        try fetch(gpa, io, conn, "GET", path, null, w);
    } else if (std.mem.eql(u8, cmd, "post")) {
        const body = try std.Io.Dir.cwd().readFileAlloc(io, args.next() orelse return error.Usage, gpa, .unlimited);
        defer gpa.free(body);
        try fetch(gpa, io, conn, "POST", path, body, w);
    } else if (std.mem.eql(u8, cmd, "many")) {
        const n = try std.fmt.parseInt(usize, args.next() orelse return error.Usage, 10);
        var ok: std.atomic.Value(usize) = .init(0);
        var group: std.Io.Group = .init;
        defer group.cancel(io);
        for (0..n) |_| try group.concurrent(io, one, .{ gpa, io, conn, path, &ok });
        try group.await(io);
        try w.print("ok {d}\n", .{ok.load(.monotonic)});
    } else return error.Usage;
}

fn one(gpa: std.mem.Allocator, io: std.Io, conn: *h3.ClientConnection, path: []const u8, ok: *std.atomic.Value(usize)) std.Io.Cancelable!void {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    fetch(gpa, io, conn, "GET", path, null, &w) catch return;
    if (std.mem.startsWith(u8, w.buffered(), "status 200 ")) _ = ok.fetchAdd(1, .monotonic);
}

fn fetch(gpa: std.mem.Allocator, io: std.Io, conn: *h3.ClientConnection, method: []const u8, path: []const u8, body: ?[]const u8, w: *std.Io.Writer) !void {
    const s = try conn.request(&.{
        .{ .name = ":method", .value = method },  .{ .name = ":path", .value = path },
        .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
    }, .{ .body = body != null });
    defer s.release();
    var sender: ?std.Io.Future(anyerror!void) = null;
    if (body) |b| sender = try io.concurrent(send, .{ s, b });
    defer if (sender) |*f| f.cancel(io) catch {};
    try s.waitHead();
    var total: usize = 0;
    var sum: u32 = 0;
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        const n = try s.reader().readSliceShort(&chunk);
        if (n == 0) break;
        total += n;
        for (chunk[0..n]) |b| sum +%= b;
    }
    if (sender) |*f| {
        try f.await(io);
        sender = null;
    }
    try w.print("status {d} bytes {d} sum {d}\n", .{ s.status, total, sum });
    for (s.trailers.items) |t| try w.print("trailer {s} {s}\n", .{ t.name, t.value });
    _ = gpa;
}

fn send(s: *h3.Stream, body: []const u8) anyerror!void {
    try s.writer().writeAll(body);
    try s.closeSend();
}
