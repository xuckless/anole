//! Fuzzing the WebSocket over HTTP/2 message layer (`H2Socket`) without a
//! connection: the stream's body reader hands over the input in pieces of a
//! size the input picks, and the streamed response is a fixed buffer. The
//! frames a client would send go in; what `receive` returns and what the
//! socket writes back must be the same whether the bytes arrive at once or
//! a few at a time.
const std = @import("std");
const builtin = @import("builtin");
const dusty = @import("dusty");
const features = @import("build_options");
const codec = @import("anole_websocket_codec");
const websocket = @import("root.zig");
const H2Socket = @import("h2_socket.zig").H2Socket;
const deflate = if (features.compression) @import("deflate.zig") else struct {};

/// The body reader's source. One check runs at a time, so it is global: the
/// reader's `interface` lives inside the core's `RequestBodyReader`, where a
/// `@fieldParentPtr` back to state of our own is not available.
var source: struct { data: []const u8 = "", pos: usize = 0, step: usize = 1 } = .{};

fn stream(_: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
    if (source.pos == source.data.len) return error.EndOfStream;
    const n = limit.minInt(@min(source.step, source.data.len - source.pos));
    const written = try w.write(source.data[source.pos..][0..n]);
    source.pos += written;
    return written;
}

const max_message_size = 512;

/// What one socket did with the input: every message `receive` returned,
/// the error it ended with, and the bytes it wrote.
const Transcript = struct {
    messages: std.ArrayList(u8) = .empty,
    end: anyerror = error.None,
    out: []const u8 = "",
};

/// A socket reading `input` in pieces of `step` bytes through a read buffer
/// of `buf_len`.
fn recvSocket(arena: std.mem.Allocator, input: []const u8, step: usize, buf_len: usize, compressed: bool, max: usize) !*H2Socket {
    source = .{ .data = input, .step = step };
    const sock = try arena.create(H2Socket);
    const out = try arena.alloc(u8, 64 * 1024);
    sock.* = .{
        .io = std.testing.io,
        .arena = arena,
        .body = .{ .parser = undefined, .transport = undefined, .interface = .{
            .vtable = &.{ .stream = stream },
            .buffer = sock.in_buf[0..buf_len],
            .seek = 0,
            .end = 0,
        } },
        .out = .{ .res = undefined, .interface = .fixed(out) },
        .in_buf = undefined,
        .out_buf = &.{},
        .sink = null,
        .frames = .init(.{ .extension = if (compressed) .{ .permessage_deflate = .init } else null }),
        .max_message_size = max,
    };
    return sock;
}

fn run(arena: std.mem.Allocator, input: []const u8, step: usize, buf_len: usize, compressed: bool) !Transcript {
    const sock = try recvSocket(arena, input, step, buf_len, compressed, max_message_size);
    // A batch's flusher task (`H2Socket.deinit` would also end the
    // response, which has none here).
    defer sock.batch.deinit(std.testing.io);
    defer sock.message.deinit(std.heap.c_allocator);
    var d: if (features.compression) deflate.Deflate else void = if (features.compression) .init(.{}, .{}, arena) else {};
    defer if (features.compression) d.deinit();
    var socket: websocket.Socket = .{
        ._conn = .{ .stream = sock },
        ._allocator = arena,
        .io = std.testing.io,
        .max_message_size = max_message_size,
    };
    if (comptime features.compression) {
        if (compressed) socket._deflate = &d;
    }

    var t: Transcript = .{};
    while (true) {
        const msg = socket.receive() catch |err| {
            t.end = err;
            break;
        };
        try std.testing.expect(msg.data.len <= max_message_size);
        try std.testing.expect(msg.type == .text or msg.type == .binary or msg.type == .close);
        if (msg.type == .text) try std.testing.expect(std.unicode.utf8ValidateSlice(msg.data));
        try t.messages.print(arena, "{t} {d} {?d}:", .{ msg.type, msg.data.len, if (msg.close_code) |c| @backingInt(c) else null });
        try t.messages.appendSlice(arena, msg.data);
        // After a close, the socket sends nothing more.
        if (msg.type == .close) try std.testing.expect(sock.closed);
    }
    t.out = sock.out.interface.buffered();
    return t;
}

/// What the socket wrote is a well-formed run of unmasked server frames:
/// control frames whole, a close the last of them.
fn checkOutput(out: []const u8) !void {
    var handler: codec.client.FrameHandler = .init(.{});
    const copy = try std.testing.allocator.dupe(u8, out);
    defer std.testing.allocator.free(copy);
    var rest: []u8 = copy;
    var closed = false;
    while (true) {
        const r = try handler.feed(rest);
        rest = rest[r.consumed..];
        switch (r.message) {
            .need_more => break,
            .close => closed = true,
            else => try std.testing.expect(!closed),
        }
    }
    try std.testing.expectEqual(@as(usize, 0), rest.len);
}

test "fuzz: WebSocket over HTTP/2, whole and in pieces" {
    try @import("../fuzz.zig").bytes(struct {
        fn check(input: []const u8) !void {
            if (input.len == 0) return;
            var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            // The first byte picks the delivery, the rest are the frames.
            const knobs = input[0];
            const frames = input[1..];
            const compressed = features.compression and knobs & 0x80 != 0;
            const step = 1 + (knobs & 0x1f);
            const buf_len: usize = if (knobs & 0x40 != 0) 300 else H2Socket.buffer_len;

            const whole = try run(arena, frames, frames.len + 1, H2Socket.buffer_len, compressed);
            const pieces = try run(arena, frames, step, buf_len, compressed);
            try std.testing.expectEqualStrings(whole.messages.items, pieces.messages.items);
            try std.testing.expectEqual(whole.end, pieces.end);
            try std.testing.expectEqualStrings(whole.out, pieces.out);
            try checkOutput(whole.out);
        }
    }.check, &.{
        // Masked "Hello" (RFC 6455 §5.7), then a close 1000.
        "\x00\x81\x85\x37\xfa\x21\x3d\x7f\x9f\x4d\x51\x58\x88\x82\x00\x00\x00\x00\x03\xe8",
        // Fragmented "Hel" + "lo" with a ping between, then the stream ends.
        "\x07\x01\x83\x00\x00\x00\x00Hel\x89\x82\x00\x00\x00\x00hi\x80\x82\x00\x00\x00\x00lo",
        // A pong, an empty binary message, a close with a reason.
        "\x41\x8a\x80\x00\x00\x00\x00\x82\x80\x01\x02\x03\x04\x88\x86\x00\x00\x00\x00\x03\xe9bye!",
        // Compressed "Hello" (RFC 7692 §7.2.3.1), RSV1 set.
        "\x80\xc1\x87\x00\x00\x00\x00\xf2\x48\xcd\xc9\xc9\x07\x00",
        // 16-bit length, too large for the limit; invalid UTF-8 text.
        "\x03\x82\xfe\x02\x58\x00\x00\x00\x00" ++ @as([600]u8, @splat('x')),
        "\x02\x81\x82\x00\x00\x00\x00\xc3\x28",
        // A close whose code is not allowed on the wire, one with one byte.
        "\x05\x88\x82\x00\x00\x00\x00\x03\xed",
        "\x05\x88\x81\x00\x00\x00\x00\x03",
    });
}

// A pong held for a batch starts the socket's flusher, a task on
// `std.testing.io`'s threads, which `run` cancels as it ends. std.Io.Threaded
// frees a group's task only after waking whoever cancels the group, so with
// one Io across inputs the task could still be freeing from the test
// allocator as the fuzz runner checks and resets it for the next input: a
// false leak, or a corrupted bucket (#195). The runner gives each input an Io
// of its own and joins its threads first, so an input starts with none.
test "fuzz: a flusher an input started is gone before the next input" {
    try @import("../fuzz.zig").bytes(struct {
        fn check(_: []const u8) !void {
            if (builtin.fuzz) try std.testing.expectEqual(0, std.testing.io_instance.wait_group.state.load(.monotonic));
            var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena_state.deinit();
            // Two masked empty pings: the first one's pong waits for the batch.
            const t = try run(arena_state.allocator(), "\x89\x80\x00\x00\x00\x00\x89\x80\x00\x00\x00\x00", 12, H2Socket.buffer_len, false);
            try std.testing.expectEqualStrings("\x8a\x00\x8a\x00", t.out);
        }
    }.check, &.{""});
}

test "H2Socket: a message, a ping and a close, whole and a byte at a time" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Masked "Hello" (RFC 6455 §5.7), a ping "hi", a close 1000.
    const frames = "\x81\x85\x37\xfa\x21\x3d\x7f\x9f\x4d\x51\x58" ++
        "\x89\x82\x00\x00\x00\x00hi" ++
        "\x88\x82\x00\x00\x00\x00\x03\xe8";
    for ([_]usize{ frames.len, 1 }) |step| {
        const t = try run(arena, frames, step, H2Socket.buffer_len, false);
        try std.testing.expectEqualStrings("text 5 null:Helloclose 0 1000:", t.messages.items);
        try std.testing.expectEqual(error.ConnectionClosed, t.end);
        // The pong, then the close echoed.
        try std.testing.expectEqualStrings("\x8a\x02hi\x88\x02\x03\xe8", t.out);
    }
}

test "H2Socket: RSV1 only on a compressed message's first frame, never on a control frame or a continuation" {
    if (comptime !features.compression) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{
        // A ping with RSV1.
        "\xc9\x80\x00\x00\x00\x00",
        // A text message in pieces, RSV1 on its continuation.
        "\x41\x81\x00\x00\x00\x00a\xc0\x81\x00\x00\x00\x00b",
    }) |frames| {
        const t = try run(arena, frames, frames.len, H2Socket.buffer_len, true);
        try std.testing.expectEqual(error.ReservedRsvBit, t.end);
        // Close 1002.
        try std.testing.expectEqualStrings("\x88\x02\x03\xea", t.out);
    }
}

/// An H2Socket over a fixed output buffer, for the send-side checks.
fn sendSocket(arena: std.mem.Allocator) !*H2Socket {
    const sock = try arena.create(H2Socket);
    const out = try arena.alloc(u8, 1024);
    sock.* = .{
        .io = std.testing.io,
        .arena = arena,
        .body = undefined,
        .out = .{ .res = undefined, .interface = .fixed(out) },
        .in_buf = undefined,
        .out_buf = &.{},
        .sink = null,
        .frames = .init(.{}),
        .max_message_size = max_message_size,
    };
    return sock;
}

test "H2Socket: a ping or pong a handler sends over 125 bytes is refused" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const sock = try sendSocket(arena_state.allocator());
    defer sock.batch.deinit(std.testing.io);
    defer sock.message.deinit(std.heap.c_allocator);
    const big: [126]u8 = @splat('p');
    try std.testing.expectError(error.LargeControlFrame, sock.sendMessage(.ping, &big, false));
    try std.testing.expectError(error.LargeControlFrame, sock.sendMessage(.pong, &big, false));
    try std.testing.expectError(error.LargeControlFrame, sock.ping(&big));
    try std.testing.expectError(error.LargeControlFrame, sock.sendMessage(.ping, "x", true));
}

test "H2Socket: a close goes out once, and a send after it is refused" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const sock = try sendSocket(arena_state.allocator());
    defer sock.batch.deinit(std.testing.io);
    defer sock.message.deinit(std.heap.c_allocator);
    // However often it is asked for.
    try sock.close(.normal, "");
    try sock.close(.going_away, "");
    try std.testing.expectEqualStrings("\x88\x02\x03\xe8", sock.out.interface.buffered());
    try std.testing.expectError(error.ConnectionClosed, sock.sendMessage(.text, "late", false));
}

/// A masked (all-zero key) binary frame, or a continuation, of `len` bytes.
fn frame(arena: std.mem.Allocator, out: *std.ArrayList(u8), first: bool, fin: bool, len: usize) !void {
    const b0: u8 = (if (fin) @as(u8, 0x80) else 0) | (if (first) @as(u8, 0x02) else 0);
    try out.append(arena, b0);
    if (len < 126) {
        try out.append(arena, 0x80 | @as(u8, @intCast(len)));
    } else if (len <= 0xffff) {
        try out.append(arena, 0x80 | 126);
        try out.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(len))));
    } else {
        try out.append(arena, 0x80 | 127);
        try out.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(u64, len)));
    }
    try out.appendSlice(arena, &.{ 0, 0, 0, 0 });
    try out.appendNTimes(arena, 'x', len);
}

/// A message of `frames` frames of `len` bytes each.
fn message(arena: std.mem.Allocator, out: *std.ArrayList(u8), frames: usize, len: usize) !void {
    for (0..frames) |i| try frame(arena, out, i == 0, i == frames - 1, len);
}

const KiB = 1024;

test "H2Socket: messageCapacity sizes once for what is declared, never more than twice what is here" {
    const cap = H2Socket.messageCapacity;
    const big = 16 * 1024 * KiB;
    // It fits.
    try std.testing.expectEqual(null, cap(100, 50, 0, true, 150, big));
    // A whole message in one frame, the first chunk 1 KiB: the rest at once.
    for ([_]usize{ 16, 32, 64 }) |k| try std.testing.expectEqual(k * KiB, cap(0, KiB, k * KiB - KiB, true, 0, big));
    // Declared 1 MiB, 1 KiB here: no more than the 64 KiB kept anyway.
    try std.testing.expectEqual(64 * KiB, cap(0, KiB, KiB * KiB - KiB, true, 0, big));
    // Past it, twice what is held at most, then the exact end.
    try std.testing.expectEqual(128 * KiB, cap(64 * KiB, KiB, KiB * KiB - 65 * KiB, true, 64 * KiB, big));
    try std.testing.expectEqual(100 * KiB, cap(64 * KiB, 4 * KiB, 32 * KiB, true, 64 * KiB, big));
    // A frame before the last grows by half at least (many small frames),
    // to the frame's end when that is further.
    try std.testing.expectEqual(1500, cap(1000, 100, 0, false, 1000, big));
    try std.testing.expectEqual(3000, cap(1000, 100, 1900, false, 1000, big));
    // The last frame's end is the message's: exact, no slack.
    try std.testing.expectEqual(1100, cap(1000, 100, 0, true, 1000, big));
    // Never past the limit, and a declared length near 2^64 saturates.
    try std.testing.expectEqual(512, cap(400, 10, 0, false, 400, 512));
    try std.testing.expectEqual(512, cap(0, 10, std.math.maxInt(u64) - 1, true, 0, 512));
    try std.testing.expectEqual(64 * KiB, cap(10, 10, std.math.maxInt(u64), false, 0, big));
}

test "H2Socket: a 16, 32 or 64 KiB message in 1, 4 or 16 KiB pieces grows its buffer once" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]usize{ 16, 32, 64 }) |k| for ([_]usize{ 1, 4, 16 }) |step| for ([_]usize{ 1, 4 }) |frames| {
        var in: std.ArrayList(u8) = .empty;
        try message(arena, &in, frames, k * KiB / frames);
        const sock = try recvSocket(arena, in.items, step * KiB, 16 * KiB, false, KiB * KiB);
        defer sock.message.deinit(std.heap.c_allocator);
        defer sock.batch.deinit(std.testing.io);
        const msg = try sock.receive();
        try std.testing.expectEqual(k * KiB, msg.data.len);
        // A message in several frames grows once per frame at most.
        try std.testing.expect(sock.message_grows >= 1 and sock.message_grows <= frames);
        if (frames == 1) try std.testing.expectEqual(k * KiB, sock.message.capacity);
    };
}

test "H2Socket: a message of many small frames grows by half each time, not once a frame" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var in: std.ArrayList(u8) = .empty;
    try message(arena, &in, 1000, 100);
    const sock = try recvSocket(arena, in.items, 4 * KiB, 16 * KiB, false, KiB * KiB);
    defer sock.message.deinit(std.heap.c_allocator);
    defer sock.batch.deinit(std.testing.io);
    try std.testing.expectEqual(100_000, (try sock.receive()).data.len);
    // 100, 150, 225, ... past 100 000: 18 grows, where a copy a frame is 1000.
    try std.testing.expect(sock.message_grows <= 20);
}

test "H2Socket: repeated 70-128 KiB messages are charged to the budget while whole and freed after" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sizes = [_]usize{ 70, 100, 128, 65, 128 };
    var in: std.ArrayList(u8) = .empty;
    for (sizes) |k| try message(arena, &in, 1, k * KiB);
    var rows: [1]dusty.admission.Row = .{.{}};
    var budget: dusty.admission.State = .{ .rows = &rows };
    const sock = try recvSocket(arena, in.items, 16 * KiB, 16 * KiB, false, KiB * KiB);
    defer sock.message.deinit(std.heap.c_allocator);
    defer sock.batch.deinit(std.testing.io);
    sock.budget = &budget;
    for (sizes) |k| {
        const before = sock.message_grows;
        const msg = try sock.receive();
        try std.testing.expectEqual(k * KiB, msg.data.len);
        // The 64 KiB kept, then the exact rest: twice, not eight times.
        try std.testing.expectEqual(before + 2, sock.message_grows);
        try std.testing.expectEqual(k * KiB, sock.message.capacity);
        // Given back as `receive` returns.
        try std.testing.expectEqual(0, sock.held.bytes);
        try std.testing.expectEqual(0, rows[0].held_bytes.load(.monotonic));
    }
    // What is past the 64 KiB kept goes before the next message.
    try std.testing.expectError(error.ConnectionClosed, sock.receive());
    try std.testing.expectEqual(0, sock.message.capacity);
    try std.testing.expectEqual(0, budget.refused_memory.load(.monotonic));
}

test "H2Socket: a frame declaring 1 MiB with 1 KiB sent reserves no more than the 64 KiB kept" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var in: std.ArrayList(u8) = .empty;
    try frame(arena, &in, true, true, KiB * KiB);
    in.shrinkRetainingCapacity(14 + KiB);
    const sock = try recvSocket(arena, in.items, in.items.len, H2Socket.buffer_len, false, 2 * KiB * KiB);
    defer sock.message.deinit(std.heap.c_allocator);
    defer sock.batch.deinit(std.testing.io);
    try std.testing.expectError(error.ConnectionClosed, sock.receive());
    try std.testing.expectEqual(1, sock.message_grows);
    try std.testing.expectEqual(64 * KiB, sock.message.capacity);
}

test "H2Socket: a chunk past max_message_size fails before anything is reserved, and pieces never reserve past it" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var in: std.ArrayList(u8) = .empty;
    try frame(arena, &in, true, true, 600);
    for ([_]usize{ in.items.len, 100 }) |step| {
        const sock = try recvSocket(arena, in.items, step, H2Socket.buffer_len, false, 512);
        defer sock.message.deinit(std.heap.c_allocator);
        defer sock.batch.deinit(std.testing.io);
        try std.testing.expectError(error.MessageTooLarge, sock.receive());
        if (step == in.items.len) try std.testing.expectEqual(0, sock.message_grows);
        try std.testing.expect(sock.message.capacity <= 512);
    }
}

test "H2Socket: a message past the 64 KiB kept is refused 1013 before its memory is taken when the budget is full" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var in: std.ArrayList(u8) = .empty;
    try message(arena, &in, 1, 128 * KiB);
    var rows: [1]dusty.admission.Row = .{.{}};
    var budget: dusty.admission.State = .{ .rows = &rows, .buffer_budget = KiB };
    // Others (slow bodies, say) fill the executor's budget.
    rows[0].held_bytes.store(KiB, .monotonic);
    const sock = try recvSocket(arena, in.items, 16 * KiB, H2Socket.buffer_len, false, KiB * KiB);
    defer sock.message.deinit(std.heap.c_allocator);
    defer sock.batch.deinit(std.testing.io);
    sock.budget = &budget;
    try std.testing.expectError(error.TryAgainLater, sock.receive());
    // The 64 KiB kept anyway, and no more.
    try std.testing.expectEqual(1, sock.message_grows);
    try std.testing.expectEqual(64 * KiB, sock.message.capacity);
    try std.testing.expectEqual(0, sock.held.bytes);
    try std.testing.expectEqual(KiB, rows[0].held_bytes.load(.monotonic));
    try std.testing.expectEqual(1, budget.refused_memory.load(.monotonic));
    // Close 1013.
    try std.testing.expectEqualStrings("\x88\x02\x03\xf5", sock.out.interface.buffered());
}

/// The Wire a drain writes to: the H2 socket holds a copy of the writer, so it cannot find its parent.
var current: *Wire = undefined;
const Wire = struct {
    interface: std.Io.Writer,
    buf: [256]u8 = undefined,
    got: [256]u8 = undefined,
    n: usize = 0,

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self = current;
        const parts: [2][]const u8 = .{ w.buffer[0..w.end], data[0] };
        for (parts) |d| {
            @memcpy(self.got[self.n..][0..d.len], d);
            self.n += d.len;
        }
        w.end = 0;
        std.debug.assert(data.len == 1 and splat == 1);
        return data[0].len;
    }
};

test "Socket: send flushes, _sendDeferred holds until _flushOut, RSV1 only on a compressed text over min_length" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]bool{ false, true }) |is_stream| for ([_]bool{ false, true }) |flush| for ([_]struct { len: usize, rsv1: bool }{
        .{ .len = 2, .rsv1 = false },
        .{ .len = 63, .rsv1 = false },
        .{ .len = 64, .rsv1 = true },
    }) |c| {
        var wire: Wire = .{ .interface = .{ .vtable = &.{ .drain = Wire.drain }, .buffer = &.{} } };
        wire.interface.buffer = &wire.buf;
        current = &wire;
        const sock = try sendSocket(arena);
        sock.out.interface = wire.interface;
        defer sock.batch.deinit(std.testing.io);
        defer sock.message.deinit(std.heap.c_allocator);
        var ws = dusty.WebSocket.init(std.testing.io, .{ .writer = &wire.interface, .reader = undefined }, arena, 0);
        defer ws.deinit();
        ws.rsv1_allowed = true;
        var d: if (features.compression) deflate.Deflate else void = if (features.compression) .init(.{}, .{}, arena) else {};
        defer if (features.compression) d.deinit();
        var socket: websocket.Socket = .{
            ._conn = if (is_stream) .{ .stream = sock } else .{ .h1 = &ws },
            ._allocator = arena,
            .io = std.testing.io,
            .max_message_size = max_message_size,
        };
        if (comptime features.compression) socket._deflate = &d;
        const data: [64]u8 = @splat('a');
        if (flush) try socket.send(.text, data[0..c.len]) else try socket._sendDeferred(.text, data[0..c.len]);
        // Held: nothing has left the buffer yet.
        try std.testing.expectEqual(!flush, wire.n == 0);
        try socket._flushOut();
        const rsv1 = features.compression and c.rsv1;
        try std.testing.expectEqual(rsv1, wire.got[0] == 0xc1);
        try std.testing.expect(rsv1 or wire.got[0] == 0x81);
        if (!rsv1) try std.testing.expectEqualStrings(data[0..c.len], wire.got[2..][0..c.len]);
        if (is_stream) {
            // Only `send` takes a ping on a stream: the deferred leaf is text/binary.
            const ping = if (flush) socket.send(.ping, "") else socket._sendDeferred(.ping, "");
            try if (flush) ping else std.testing.expectError(error.InvalidOpcode, ping);
        }
    };
}
