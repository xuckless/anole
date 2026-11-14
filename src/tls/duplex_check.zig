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

/// The client sends several small records in one flight, then nothing
/// until the server has read: the server's first read, with room for all
/// of them, returns all of their plaintext in that one call, and returns
/// rather than wait for more.
pub fn batched(gpa: std.mem.Allocator, io: std.Io) !void {
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

    // Six records of 100 bytes: with no buffer in the writer, each slice
    // is an SSL_write of its own, and the one flush at the end of the
    // drain sends them in one socket write. Their ciphertext (under 1 KiB)
    // is one segment on loopback, so it arrives whole.
    const count = 6;
    const len = 100;
    var plain: [count * len]u8 = undefined;
    for (&plain, 0..) |*b, i| b.* = expectedByte(client_side.id, i);
    var slices: [count][]const u8 = undefined;
    for (&slices, 0..) |*s, i| s.* = plain[i * len ..][0..len];
    var w = client_side.conn.writer(&.{});
    try w.interface.writeVecAll(&slices);

    var got: [count * len + 1000]u8 = undefined;
    var r = server_side.conn.reader(&.{});
    var vec = [_][]u8{&got};
    // One underlying read (`readVec` on a reader with no buffer).
    const n = try r.interface.readVec(&vec);
    try std.testing.expectEqual(plain.len, n);
    try std.testing.expectEqualSlices(u8, &plain, got[0..n]);
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

// ---------------------------------------------------------------------------
// Borrowed ciphertext: a response's last record sent from BoringSSL's own
// buffer (dusty_tls `Connection.writeAll`).

const hooks = tls.test_hooks;

/// A connected, handshaken pair over loopback.
const Pair = struct {
    pem: @import("root.zig").Pem,
    auth: tls.config.CertKeyPair,
    listener: std.Io.net.Server,
    server: Side,
    client: Side,
    /// The client's socket was closed by the test.
    client_closed: bool = false,

    fn open(p: *Pair, gpa: std.mem.Allocator, io: std.Io) !void {
        p.pem = try selfSigned(gpa, .{});
        errdefer p.pem.deinit(gpa);
        p.auth = try tls.config.CertKeyPair.fromSlice(gpa, io, p.pem.cert, p.pem.key);
        errdefer p.auth.deinit(gpa);
        const listen_addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        p.listener = try listen_addr.listen(io, .{ .reuse_address = true });
        errdefer p.listener.deinit(io);
        p.client_closed = false;
        var accept_future = try io.concurrent(acceptAndHandshake, .{ io, &p.listener, &p.server, &p.auth });
        defer _ = accept_future.cancel(io) catch {};
        try connectAndHandshake(io, p.listener.socket.address, &p.client);
        accept_future.await(io) catch |err| {
            p.client.conn.deinit();
            p.client.stream.close(io);
            return err;
        };
    }

    fn close(p: *Pair, gpa: std.mem.Allocator, io: std.Io) void {
        p.client.conn.deinit();
        if (!p.client_closed) p.client.stream.close(io);
        p.server.conn.deinit();
        p.server.stream.close(io);
        p.listener.deinit(io);
        p.auth.deinit(gpa);
        p.pem.deinit(gpa);
    }
};

/// The counters of `hooks`, at one moment.
const Counts = struct {
    ssl_writes: usize,
    seals: usize,
    borrows: usize,
    buf_grows: usize,

    fn now() Counts {
        return .{
            .ssl_writes = hooks.ssl_writes.load(.monotonic),
            .seals = hooks.seals.load(.monotonic),
            .borrows = hooks.borrows.load(.monotonic),
            .buf_grows = hooks.buf_grows.load(.monotonic),
        };
    }

    fn since(after: Counts, before: Counts) Counts {
        return .{
            .ssl_writes = after.ssl_writes - before.ssl_writes,
            .seals = after.seals - before.seals,
            .borrows = after.borrows - before.borrows,
            .buf_grows = after.buf_grows - before.buf_grows,
        };
    }
};

/// Holds the writing side at `hooks.borrow_out`, with the borrowed record
/// not yet sent, until `release` is set.
const Hold = struct {
    // SAFETY: `arm` sets it before the hook can run.
    var io: std.Io = undefined;
    var parked: std.Io.Event = .unset;
    var release: std.Io.Event = .unset;
    /// `hooks.seals` when the writer went on.
    var seals: usize = 0;

    fn arm(io_: std.Io) void {
        io = io_;
        parked = .unset;
        release = .unset;
        hooks.borrow_out = hook;
    }

    fn disarm() void {
        hooks.borrow_out = null;
    }

    fn hook() void {
        parked.set(io);
        release.wait(io) catch io.recancel(); // the send after this reports it
        seals = hooks.seals.load(.monotonic);
    }
};

/// One message of `len` bytes, from `start` in `side`'s stream, written
/// at once through a 16 KiB plaintext buffer, then flushed (a response):
/// one drain. Returns the connection's own error.
fn sendMessage(side: *Side, start: usize, len: usize) !void {
    const payload = try std.testing.allocator.alloc(u8, len);
    defer std.testing.allocator.free(payload);
    for (payload, 0..) |*b, i| b.* = expectedByte(side.id, start + i);
    var plain_buf: [16 * 1024]u8 = undefined;
    var w = side.conn.writer(&plain_buf);
    w.interface.writeAll(payload) catch return w.err.?;
    w.interface.flush() catch return w.err.?;
}

fn sendMessageTo(side: *Side, start: usize, len: usize, result: *anyerror!void) void {
    result.* = sendMessage(side, start, len);
}

/// Reads `len` bytes of the peer's stream from `start` and checks each.
fn readRange(side: *Side, start: usize, len: usize) !void {
    const peer: u8 = if (side.id == 1) 2 else 1;
    var r = side.conn.reader(&.{});
    var buf: [5000]u8 = undefined;
    var got: usize = 0;
    while (got < len) {
        var vec = [_][]u8{buf[0..@min(buf.len, len - got)]};
        const n = r.interface.readVec(&vec) catch |err| return r.err orelse err;
        for (buf[0..n], 0..) |b, i| {
            if (b != expectedByte(peer, start + got + i)) return error.CorruptStream;
        }
        got += n;
    }
}

fn readRangeTo(side: *Side, start: usize, len: usize, result: *anyerror!void) void {
    result.* = readRange(side, start, len);
}

/// `from` sends `len` bytes at `start` of its stream, `to` reads them.
fn exchange(io: std.Io, from: *Side, to: *Side, start: usize, len: usize) !void {
    var results: [2]anyerror!void = @splat({});
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, sendMessageTo, .{ from, start, len, &results[0] });
    try group.concurrent(io, readRangeTo, .{ to, start, len, &results[1] });
    try group.await(io);
    for (results) |r| try r;
}

/// Responses of every size arrive intact; those that are one record of
/// more than 1,984 bytes (the small buffer's room) go out from
/// BoringSSL's buffer: one record, two SSL_writes (the borrowing one and
/// its retry), no `pending` growth under the lock. Smaller ones and the
/// first records of bigger ones are copied, into a buffer taken outside
/// the lock.
pub fn borrowSizes(gpa: std.mem.Allocator, io: std.Io) !void {
    // SAFETY: `open` sets every field.
    var p: Pair = undefined;
    try p.open(gpa, io);
    defer p.close(gpa, io);

    // The first response also carries the session tickets.
    var start: usize = 0;
    try exchange(io, &p.server, &p.client, start, 100);
    start += 100;

    const Case = struct { len: usize, borrows: usize, one_record: bool };
    const cases = [_]Case{
        .{ .len = 1, .borrows = 0, .one_record = true },
        .{ .len = 195, .borrows = 0, .one_record = true },
        .{ .len = 1984, .borrows = 0, .one_record = true },
        .{ .len = 1985, .borrows = 1, .one_record = true },
        .{ .len = 2 * 1024 + 1, .borrows = 1, .one_record = true },
        .{ .len = 8600, .borrows = 1, .one_record = true },
        .{ .len = 16 * 1024, .borrows = 1, .one_record = true },
        // Its first record is queued ahead of the last one.
        .{ .len = 16 * 1024 + 1, .borrows = 0, .one_record = false },
        // The first six records leave at the gather sends, so nothing is
        // queued ahead of the last one (4 KiB).
        .{ .len = 100 * 1024, .borrows = 1, .one_record = false },
    };
    for (cases) |case| {
        const before: Counts = .now();
        try exchange(io, &p.server, &p.client, start, case.len);
        start += case.len;
        const d = Counts.now().since(before);
        errdefer std.log.err("{d} bytes: {any}", .{ case.len, d });
        try std.testing.expectEqual(case.borrows, d.borrows);
        try std.testing.expectEqual(0, d.buf_grows);
        if (case.one_record) {
            try std.testing.expectEqual(1, d.seals);
            try std.testing.expectEqual(1 + case.borrows, d.ssl_writes);
        }
    }
}

/// The client asks for a KeyUpdate while the server's borrowed record is
/// out and the server's reading side handles it then. The server's
/// application sends nothing more, yet its flush after that response
/// sends the reply (one more record), behind the borrowed one; the client
/// reads the response, then more data under the new keys.
pub fn borrowKeyUpdate(gpa: std.mem.Allocator, io: std.Io) !void {
    // SAFETY: `open` sets every field.
    var p: Pair = undefined;
    try p.open(gpa, io);
    defer p.close(gpa, io);
    try exchange(io, &p.server, &p.client, 0, 100);

    Hold.arm(io);
    defer Hold.disarm();
    var results: [3]anyerror!void = @splat({});
    {
        var group: std.Io.Group = .init;
        defer group.cancel(io);
        try group.concurrent(io, sendMessageTo, .{ &p.server, 100, 8 * 1024, &results[0] });
        try group.concurrent(io, readThenRelease, .{ &p.server, 4, &results[1] });
        try group.concurrent(io, readRangeTo, .{ &p.client, 100, 8 * 1024, &results[2] });
        try Hold.parked.wait(io);
        try hooks.keyUpdate(&p.client.conn);
        try sendMessage(&p.client, 0, 4);
        try group.await(io);
    }
    for (results) |r| try r;
    Hold.disarm();
    // The server's flush wrote the KeyUpdate reply; nothing else wrote.
    try std.testing.expectEqual(1, hooks.seals.load(.monotonic) - Hold.seals);
    try exchange(io, &p.server, &p.client, 100 + 8 * 1024, 1);
    try exchange(io, &p.client, &p.server, 4, 1);
}

/// Reads `len` bytes of the peer's stream from its start, then lets the
/// held writer go on.
fn readThenRelease(side: *Side, len: usize, result: *anyerror!void) void {
    result.* = readRange(side, 0, len);
    Hold.release.set(Hold.io);
}

/// The client sends a corrupt record while the server's borrowed record
/// is out: the server's reading side fails on it (and
/// BoringSSL defers its alert), the record still goes out whole, then the
/// write fails and the alert is lost: the client reads the response, then
/// the end of the stream without close_notify.
pub fn borrowAlert(gpa: std.mem.Allocator, io: std.Io) !void {
    // SAFETY: `open` sets every field.
    var p: Pair = undefined;
    try p.open(gpa, io);
    defer p.close(gpa, io);
    try exchange(io, &p.server, &p.client, 0, 100);

    Hold.arm(io);
    defer Hold.disarm();
    var results: [3]anyerror!void = @splat({});
    {
        var group: std.Io.Group = .init;
        defer group.cancel(io);
        try group.concurrent(io, sendThenShutdown, .{ io, &p.server, 100, 8 * 1024, &results[0] });
        try group.concurrent(io, failThenRelease, .{ &p.server, &results[1] });
        try group.concurrent(io, readRangeTo, .{ &p.client, 100, 8 * 1024, &results[2] });
        try Hold.parked.wait(io);
        // An application data record of 32 bytes no key opens.
        const garbage = [_]u8{ 0x17, 0x03, 0x03, 0x00, 0x20 } ++ @as([32]u8, @splat(0xa5));
        try p.client.tcp_writer.interface.writeAll(&garbage);
        try p.client.tcp_writer.interface.flush();
        try group.await(io);
    }
    try std.testing.expectError(error.TlsFailure, results[0]);
    try results[1];
    try results[2];
    var r = p.client.conn.reader(&.{});
    var buf: [16]u8 = undefined;
    var vec = [_][]u8{&buf};
    try std.testing.expectError(error.EndOfStream, r.interface.readVec(&vec));
    try std.testing.expect(p.client.conn.endedWithoutCloseNotify());
}

fn sendThenShutdown(io: std.Io, side: *Side, start: usize, len: usize, result: *anyerror!void) void {
    result.* = sendMessage(side, start, len);
    side.stream.shutdown(io, .send) catch {};
}

fn failThenRelease(side: *Side, result: *anyerror!void) void {
    defer Hold.release.set(Hold.io);
    var r = side.conn.reader(&.{});
    var buf: [16]u8 = undefined;
    var vec = [_][]u8{&buf};
    _ = r.interface.readVec(&vec) catch {
        const err = r.err orelse {
            result.* = error.UnexpectedEndOfStream;
            return;
        };
        // The AEAD's own error comes first in the queue, so a record no key
        // opens reads as TlsFailure rather than TlsBadRecordMac.
        if (err != error.TlsBadRecordMac and err != error.TlsFailure) result.* = err;
        return;
    };
    result.* = error.UnexpectedData;
}

/// The client resets the connection while the server's borrowed record is
/// out: the send fails, the record stays out, and closing the connection
/// afterwards copies nothing into the queue.
pub fn borrowReset(gpa: std.mem.Allocator, io: std.Io) !void {
    // SO_LINGER through std.posix doesn't compile for Windows (not required).
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    // SAFETY: `open` sets every field.
    var p: Pair = undefined;
    try p.open(gpa, io);
    defer p.close(gpa, io);
    try exchange(io, &p.server, &p.client, 0, 100);

    Hold.arm(io);
    defer Hold.disarm();
    var results: [2]anyerror!void = @splat({});
    {
        var group: std.Io.Group = .init;
        defer group.cancel(io);
        try group.concurrent(io, sendMessageTo, .{ &p.server, 100, 8 * 1024, &results[0] });
        try group.concurrent(io, endThenRelease, .{ &p.server, &results[1] });
        try Hold.parked.wait(io);
        const linger = extern struct { onoff: c_int, seconds: c_int }{ .onoff = 1, .seconds = 0 };
        try std.posix.setsockopt(p.client.stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.LINGER, std.mem.asBytes(&linger));
        p.client.stream.close(io);
        p.client_closed = true;
        try group.await(io);
    }
    try std.testing.expectError(error.WriteFailed, results[0]);
    try results[1];
    try std.testing.expect(hooks.borrowOut(&p.server.conn));
    const grows = hooks.buf_grows.load(.monotonic);
    p.server.conn.close();
    try std.testing.expectEqual(grows, hooks.buf_grows.load(.monotonic));
    try std.testing.expectEqual(0, p.server.conn.heldCiphertext());
}

/// Reads until the stream ends or fails (the peer's reset), then lets the
/// held writer go on.
fn endThenRelease(side: *Side, result: *anyerror!void) void {
    defer Hold.release.set(Hold.io);
    var r = side.conn.reader(&.{});
    var buf: [16]u8 = undefined;
    var vec = [_][]u8{&buf};
    while (true) _ = r.interface.readVec(&vec) catch break;
    result.* = {};
}

/// The writing task is canceled while its borrowed record is out: the
/// send reports the cancel as a failed write, and freeing the connection
/// frees BoringSSL's buffer with the record in it.
pub fn borrowCancel(gpa: std.mem.Allocator, io: std.Io) !void {
    // SAFETY: `open` sets every field.
    var p: Pair = undefined;
    try p.open(gpa, io);
    defer p.close(gpa, io);
    try exchange(io, &p.server, &p.client, 0, 100);

    Hold.arm(io);
    defer Hold.disarm();
    var future = try io.concurrent(sendMessage, .{ &p.server, 100, 8 * 1024 });
    try Hold.parked.wait(io);
    try std.testing.expectError(error.WriteFailed, future.cancel(io));
    try std.testing.expect(hooks.borrowOut(&p.server.conn));
}

// ---------------------------------------------------------------------------
// Records cut by size, not at slice boundaries (dusty_tls `Writer.drain`).

/// One message of `prefix` bytes written into a 16 KiB plaintext buffer,
/// then slices of `sizes` as one vector, then a flush: one drain, as the
/// HTTP/2 flusher writes a round of frames. From `start` in `side`'s
/// stream.
fn sendSlices(side: *Side, start: usize, prefix: usize, sizes: []const usize) !void {
    var total = prefix;
    for (sizes) |s| total += s;
    const payload = try std.testing.allocator.alloc(u8, total);
    defer std.testing.allocator.free(payload);
    for (payload, 0..) |*b, i| b.* = expectedByte(side.id, start + i);
    var vecs: [64][]const u8 = undefined;
    var off = prefix;
    for (sizes, 0..) |s, i| {
        vecs[i] = payload[off..][0..s];
        off += s;
    }
    var plain_buf: [16 * 1024]u8 = undefined;
    var w = side.conn.writer(&plain_buf);
    w.interface.writeAll(payload[0..prefix]) catch return w.err.?;
    w.interface.writeVecAll(vecs[0..sizes.len]) catch return w.err.?;
    w.interface.flush() catch return w.err.?;
}

fn sendSlicesTo(side: *Side, start: usize, prefix: usize, sizes: []const usize, result: *anyerror!void) void {
    result.* = sendSlices(side, start, prefix, sizes);
}

/// Small slices (frame headers, HEADERS blocks) are gathered into records
/// of 16 KiB, slices of a record or more pass through uncopied when
/// nothing is staged (and are copied when something is, as HTTP/2 DATA
/// behind its frame header always is), and every byte arrives in order.
pub fn gathered(gpa: std.mem.Allocator, io: std.Io) !void {
    // SAFETY: `open` sets every field.
    var p: Pair = undefined;
    try p.open(gpa, io);
    defer p.close(gpa, io);

    // The first response also carries the session tickets.
    var start: usize = 0;
    try exchange(io, &p.server, &p.client, start, 100);
    start += 100;

    const record = 16 * 1024;
    // 40 slices of 9 to 200 bytes and an 8 KiB body: less than a buffer.
    var small: [41]usize = undefined;
    for (small[0..40], 0..) |*s, i| s.* = 9 + (i * 37) % 192;
    small[40] = 8 * 1024;
    // Five frames of header, HEADERS block, header and 8 KiB DATA: 41,800
    // bytes, all slices under a record.
    var frames: [20]usize = undefined;
    for (&frames, 0..) |*s, i| s.* = ([_]usize{ 9, 150, 9, 8 * 1024 })[i % 4];

    // Four DATA frames of 16 KiB, each header and payload a slice.
    var h2_data: [8]usize = undefined;
    for (&h2_data, 0..) |*s, i| s.* = if (i % 2 == 0) 9 else record;

    const Case = struct { prefix: usize, sizes: []const usize, records: usize, staged: usize };
    const cases = [_]Case{
        // Fits the buffer: std's writeSplat copies it, the flush seals it.
        .{ .prefix = 0, .sizes = &small, .records = 1, .staged = 0 },
        .{ .prefix = 0, .sizes = &frames, .records = 3, .staged = 41_800 },
        // A head ahead of a big body: the first record is topped up, the
        // rest passes through.
        .{ .prefix = 100, .sizes = &.{32 * 1024}, .records = 3, .staged = record - 100 },
        // Slices of a record or more into an empty stage copy nothing.
        .{ .prefix = 0, .sizes = &.{ 32 * 1024, 20 * 1024 }, .records = 4, .staged = 0 },
        // The HTTP/2 shape: each 16 KiB DATA behind its 9-byte header finds
        // the stage non-empty and is copied: 5 records, not 8, and every
        // byte staged but the final 36, which leave from the last slice.
        .{ .prefix = 0, .sizes = &h2_data, .records = 5, .staged = 4 * (9 + record) - 36 },
        // An HTTP/1 head of small writes, then a chunk size and a body.
        .{ .prefix = 300, .sizes = &.{ 2048, 9, 14 * 1024 }, .records = 2, .staged = record - 300 },
    };
    for (cases) |case| {
        var len = case.prefix;
        for (case.sizes) |s| len += s;
        const before: Counts = .now();
        const staged_before = hooks.staged_bytes.load(.monotonic);
        var results: [2]anyerror!void = @splat({});
        {
            var group: std.Io.Group = .init;
            defer group.cancel(io);
            try group.concurrent(io, sendSlicesTo, .{ &p.server, start, case.prefix, case.sizes, &results[0] });
            try group.concurrent(io, readRangeTo, .{ &p.client, start, len, &results[1] });
            try group.await(io);
        }
        for (results) |r| try r;
        start += len;
        const d = Counts.now().since(before);
        const staged = hooks.staged_bytes.load(.monotonic) - staged_before;
        errdefer std.log.err("{d} bytes: {any}, staged {d}", .{ len, d, staged });
        try std.testing.expectEqual(case.records, d.seals);
        try std.testing.expectEqual(case.records + d.borrows, d.ssl_writes);
        try std.testing.expectEqual(case.staged, staged);
    }
}
