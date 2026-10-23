//! Full-duplex check for dusty_tls: one TLS connection over loopback where each
//! side reads and writes at the same time from two tasks, the way the HTTP/2
//! engine uses a connection. Every byte is checked on arrival.
//!
//! The unit tests in root.zig run it on one executor (the two tasks
//! interleave on one thread) and on four pinned executors, so the reading
//! and writing tasks sit on different OS threads.
const std = @import("std");
const tls = @import("anole_dusty_tls");
const selfSigned = @import("root.zig").selfSigned;

pub const Options = struct {
    /// Bytes each side sends (and so receives).
    bytes_per_direction: usize = 8 * 1024 * 1024,
};

/// Deterministic, side-dependent stream content, so a reordered, dropped or
/// duplicated record is caught at the first wrong byte.
fn expectedByte(side: u8, index: usize) u8 {
    return @truncate((index *% 131) +% (index >> 13) +% side);
}

const Side = struct {
    conn: tls.Connection,
    tcp_reader: std.Io.net.Stream.Reader,
    tcp_writer: std.Io.net.Stream.Writer,
    in_buf: [tls.input_buffer_len]u8 = undefined,
    out_buf: [tls.output_buffer_len]u8 = undefined,
    stream: std.Io.net.Stream,
    /// This side's id; the peer sends with the other one.
    id: u8,
};

pub fn run(gpa: std.mem.Allocator, io: std.Io, opt: Options) !void {
    var pem = try selfSigned(gpa, .{});
    defer pem.deinit(gpa);
    var auth = try tls.config.CertKeyPair.fromSlice(gpa, io, pem.cert, pem.key);
    defer auth.deinit(gpa);

    const listen_addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const addr = listener.socket.address;

    var server_side: Side = undefined;
    var client_side: Side = undefined;

    var accept_future = try io.concurrent(acceptAndHandshake, .{ io, &listener, &server_side, &auth });
    defer _ = accept_future.cancel(io) catch {};
    try connectAndHandshake(io, addr, &client_side);
    try accept_future.await(io);
    defer {
        client_side.conn.deinit();
        client_side.stream.close(io);
        server_side.conn.deinit();
        server_side.stream.close(io);
    }

    // Four tasks: each side writes its stream and reads the peer's at once.
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    var results: [4]anyerror!void = @splat({});
    try group.concurrent(io, writeAll, .{ &server_side, opt.bytes_per_direction, &results[0] });
    try group.concurrent(io, readAll, .{ &server_side, opt.bytes_per_direction, &results[1] });
    try group.concurrent(io, writeAll, .{ &client_side, opt.bytes_per_direction, &results[2] });
    try group.concurrent(io, readAll, .{ &client_side, opt.bytes_per_direction, &results[3] });
    try group.await(io);
    for (results) |r| try r;
}

/// Exchanges a few small messages, then a bulk transfer each way, then
/// one more small message each way, and checks after each phase that both
/// ends, waiting for their peer, hold no ciphertext buffer beyond their
/// stash.
pub fn idle(gpa: std.mem.Allocator, io: std.Io) !void {
    var pem = try selfSigned(gpa, .{});
    defer pem.deinit(gpa);
    var auth = try tls.config.CertKeyPair.fromSlice(gpa, io, pem.cert, pem.key);
    defer auth.deinit(gpa);

    const listen_addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var server_side: Side = undefined;
    var client_side: Side = undefined;
    var accept_future = try io.concurrent(acceptAndHandshake, .{ io, &listener, &server_side, &auth });
    defer _ = accept_future.cancel(io) catch {};
    try connectAndHandshake(io, listener.socket.address, &client_side);
    try accept_future.await(io);
    defer {
        client_side.conn.deinit();
        client_side.stream.close(io);
        server_side.conn.deinit();
        server_side.stream.close(io);
    }
    try std.testing.expectEqual(0, server_side.conn.heldCiphertext());
    try std.testing.expectEqual(0, client_side.conn.heldCiphertext());

    for (0..3) |_| try pingPong(io, &client_side, &server_side, 100, true);
    // A bulk reader may keep its block when its last read happened to fill
    // it exactly (it expects more); the small exchanges after give it back.
    try pingPong(io, &client_side, &server_side, 300 * 1024, false);
    try pingPong(io, &server_side, &client_side, 300 * 1024, false);
    try pingPong(io, &client_side, &server_side, 10, true);
    try pingPong(io, &server_side, &client_side, 10, true);
}

/// `from` sends `len` bytes and `to` reads them; then `from`, and if
/// `check_reader` `to` too, must hold no ciphertext buffer.
fn pingPong(io: std.Io, from: *Side, to: *Side, len: usize, check_reader: bool) !void {
    var results: [2]anyerror!void = @splat({});
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, writeAll, .{ from, len, &results[0] });
    try group.concurrent(io, readExactly, .{ to, len, &results[1] });
    try group.await(io);
    for (results) |r| try r;
    try std.testing.expectEqual(0, from.conn.heldCiphertext());
    if (check_reader) try std.testing.expectEqual(0, to.conn.heldCiphertext());
}

fn readExactly(side: *Side, total: usize, result: *anyerror!void) void {
    result.* = readExactlyInner(side, total);
}

fn readExactlyInner(side: *Side, total: usize) !void {
    var plain_buf: [5000]u8 = undefined;
    var r = side.conn.reader(&plain_buf);
    var got: usize = 0;
    while (got < total) {
        const bytes = try r.interface.peekGreedy(1);
        const n = @min(bytes.len, total - got);
        r.interface.toss(n);
        got += n;
    }
    // A reader with its own buffer could have read ahead; this one must not.
    try std.testing.expectEqual(0, r.interface.bufferedLen());
}

fn acceptAndHandshake(io: std.Io, listener: *std.Io.net.Server, side: *Side, auth: *tls.config.CertKeyPair) !void {
    const stream = try listener.accept(io);
    side.* = .{ .conn = undefined, .tcp_reader = undefined, .tcp_writer = undefined, .stream = stream, .id = 1 };
    side.tcp_reader = stream.reader(io, &side.in_buf);
    side.tcp_writer = stream.writer(io, &side.out_buf);
    var rng: std.Random.IoSource = .{ .io = io };
    side.conn = try tls.server(&side.tcp_reader.interface, &side.tcp_writer.interface, .{
        .auth = auth,
        .now = std.Io.Clock.real.now(io),
        .rng = rng.interface(),
    });
}

fn connectAndHandshake(io: std.Io, addr: std.Io.net.IpAddress, side: *Side) !void {
    const stream = try addr.connect(io, .{ .mode = .stream });
    side.* = .{ .conn = undefined, .tcp_reader = undefined, .tcp_writer = undefined, .stream = stream, .id = 2 };
    side.tcp_reader = stream.reader(io, &side.in_buf);
    side.tcp_writer = stream.writer(io, &side.out_buf);
    var rng: std.Random.IoSource = .{ .io = io };
    side.conn = try tls.client(&side.tcp_reader.interface, &side.tcp_writer.interface, .{
        .host = "localhost",
        .root_ca = .empty,
        .insecure_skip_verify = true,
        .now = std.Io.Clock.real.now(io),
        .rng = rng.interface(),
    });
}

fn writeAll(side: *Side, total: usize, result: *anyerror!void) void {
    result.* = writeAllInner(side, total);
}

fn writeAllInner(side: *Side, total: usize) !void {
    var plain_buf: [4096]u8 = undefined;
    var w = side.conn.writer(&plain_buf);
    var chunk: [7001]u8 = undefined; // odd size: records and chunks never line up
    var sent: usize = 0;
    var round: usize = 0;
    while (sent < total) : (round += 1) {
        const n = @min(total - sent, 1 + (round * 977) % chunk.len);
        for (chunk[0..n], 0..) |*b, i| b.* = expectedByte(side.id, sent + i);
        try w.interface.writeAll(chunk[0..n]);
        // Flush now and then, as a response would.
        if (round % 5 == 0) try w.interface.flush();
        sent += n;
    }
    try w.interface.flush();
}

fn readAll(side: *Side, total: usize, result: *anyerror!void) void {
    result.* = readAllInner(side, total);
}

fn readAllInner(side: *Side, total: usize) !void {
    const peer: u8 = if (side.id == 1) 2 else 1;
    var plain_buf: [5000]u8 = undefined;
    var r = side.conn.reader(&plain_buf);
    var got: usize = 0;
    while (got < total) {
        const bytes = try r.interface.peekGreedy(1);
        const n = @min(bytes.len, total - got);
        for (bytes[0..n], 0..) |b, i| {
            if (b != expectedByte(peer, got + i)) {
                std.log.err("side {d}: byte {d} is {d}, expected {d}", .{ side.id, got + i, b, expectedByte(peer, got + i) });
                return error.CorruptStream;
            }
        }
        r.interface.toss(n);
        got += n;
    }
}

/// A small header buffered ahead of big slices (the relay's WebSocket
/// frames): the first record is topped up from the first slice, and every
/// byte still arrives in order. Also the keyframe-sized gather path.
pub fn framed(gpa: std.mem.Allocator, io: std.Io) !void {
    var pem = try selfSigned(gpa, .{});
    defer pem.deinit(gpa);
    var auth = try tls.config.CertKeyPair.fromSlice(gpa, io, pem.cert, pem.key);
    defer auth.deinit(gpa);

    const listen_addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var server_side: Side = undefined;
    var client_side: Side = undefined;
    var accept_future = try io.concurrent(acceptAndHandshake, .{ io, &listener, &server_side, &auth });
    defer _ = accept_future.cancel(io) catch {};
    try connectAndHandshake(io, listener.socket.address, &client_side);
    try accept_future.await(io);
    defer {
        client_side.conn.deinit();
        client_side.stream.close(io);
        server_side.conn.deinit();
        server_side.stream.close(io);
    }

    const sizes = [_]usize{ 20 * 1024, 100 * 1024, 16 * 1024 - 8, 3, 70 * 1024 };
    var total: usize = 0;
    for (sizes) |s| total += 8 + s;

    var results: [2]anyerror!void = @splat({});
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, writeFramed, .{ &server_side, &sizes, &results[0] });
    try group.concurrent(io, readAll, .{ &client_side, total, &results[1] });
    try group.await(io);
    for (results) |r| try r;
}

fn writeFramed(side: *Side, sizes: []const usize, result: *anyerror!void) void {
    result.* = writeFramedInner(side, sizes) catch |err| err;
}

fn writeFramedInner(side: *Side, sizes: []const usize) !void {
    var plain_buf: [16 * 1024]u8 = undefined;
    var w = side.conn.writer(&plain_buf);
    const payload = try std.testing.allocator.alloc(u8, 128 * 1024);
    defer std.testing.allocator.free(payload);
    var sent: usize = 0;
    for (sizes) |s| {
        var header: [8]u8 = undefined;
        for (&header, 0..) |*b, i| b.* = expectedByte(side.id, sent + i);
        for (payload[0..s], 0..) |*b, i| b.* = expectedByte(side.id, sent + 8 + i);
        // Header into the buffer, payload as a slice of its own.
        try w.interface.writeAll(&header);
        var vec = [_][]const u8{payload[0..s]};
        try w.interface.writeVecAll(&vec);
        try w.interface.flush();
        sent += 8 + s;
    }
}
