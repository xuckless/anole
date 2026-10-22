//! The client side of the C suite's WebTransport test (tests/capi/consumer.c
//! runs it against its own server, written in C on anole.h):
//!
//!   capi-wt-client PORT
//!
//! Opens a session at /wt and checks what the C server does: a one-way
//! stream of its own, an echo, a datagram for a one-way stream, a datagram
//! echo, a stream both ways the server opens; then closes the session (code
//! 7, "done"). Exits 0 when every check passed.
const std = @import("std");
const anole = @import("anole");

pub const zio_options = anole.zio_options;
pub const std_options: std.Options = .{
    .log_level = .warn,
    .log_scope_levels = &.{.{ .scope = .zio, .level = .warn }},
};

const h3 = anole.h3;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    const port = try std.fmt.parseInt(u16, args.next() orelse return error.Usage, 10);
    const rt = try anole.zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var f = try io.concurrent(run, .{ gpa, io, port });
    f.await(io) catch |err| {
        std.debug.print("capi-wt-client: {t}\n", .{err});
        std.process.exit(1);
    };
}

fn expectText(want: []const u8, got: []const u8, what: []const u8) !void {
    if (std.mem.eql(u8, want, got)) return;
    std.debug.print("capi-wt-client: {s}: want \"{s}\", got \"{s}\"\n", .{ what, want, got });
    return error.Mismatch;
}

fn run(gpa: std.mem.Allocator, io: std.Io, port: u16) !void {
    const conn = try h3.ClientConnection.connect(gpa, io, .{
        .host = "localhost",
        .address = try .parseIp4("127.0.0.1", port),
        .port = port,
        .tls = .{ .insecure_skip_verify = true },
        .connect_timeout = .fromSeconds(5),
        .webtransport = true,
    });
    defer conn.close();
    const session = try conn.openWebTransport(.{ .authority = "localhost", .path = "/wt" });
    defer session.deinit();

    // The server's one-way stream.
    {
        const u = try session.acceptUniStream();
        defer u.release();
        const got = try u.reader().allocRemaining(gpa, .unlimited);
        defer gpa.free(got);
        try expectText("hello from C", got, "the server's stream");
    }
    // An echo.
    {
        const s = try session.openStream();
        defer s.release();
        try s.writer().writeAll("ping");
        try s.closeSend();
        const back = try s.reader().allocRemaining(gpa, .unlimited);
        defer gpa.free(back);
        try expectText("ping", back, "the echo");
    }
    var buf: [2048]u8 = undefined;
    // A one-way stream, answered with a datagram.
    {
        const s = try session.openUniStream();
        try s.writer().writeAll("uni-data");
        try s.closeSend();
        s.release();
        try expectText("uni:8", try session.receiveDatagram(&buf), "the one-way stream's datagram");
    }
    // Datagrams.
    try session.sendDatagram("dg1");
    try expectText("echo:dg1", try session.receiveDatagram(&buf), "the datagram echo");
    // A stream both ways that the server opens.
    {
        try session.sendDatagram("open");
        _ = try session.receiveDatagram(&buf);
        const s = try session.acceptStream();
        defer s.release();
        const got = try s.reader().allocRemaining(gpa, .unlimited);
        defer gpa.free(got);
        try expectText("from C", got, "the server's stream both ways");
        try s.writer().writeAll("thanks");
        try s.closeSend();
        // The server answers on the session once it has "thanks".
        try expectText("thanked", try session.receiveDatagram(&buf), "the thanks");
    }
    try session.close(7, "done");
}
