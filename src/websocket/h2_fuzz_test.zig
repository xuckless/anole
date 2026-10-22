//! Fuzzing the WebSocket over HTTP/2 message layer (`H2Socket`) without a
//! connection: the stream's body reader hands over the input in pieces of a
//! size the input picks, and the streamed response is a fixed buffer. The
//! frames a client would send go in; what `receive` returns and what the
//! socket writes back must be the same whether the bytes arrive at once or
//! a few at a time.
const std = @import("std");
const dusty = @import("dusty");
const features = @import("build_options");
const codec = @import("anole_websocket_codec");
const websocket = @import("root.zig");
const H2Socket = @import("h2_socket.zig").H2Socket;
const deflate = if (features.compression) @import("deflate.zig") else struct {};

/// The body reader's source. One check runs at a time, so it is global: the
/// reader's `interface` lives inside dusty's `RequestBodyReader`, where a
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

fn run(arena: std.mem.Allocator, input: []const u8, step: usize, buf_len: usize, compressed: bool) !Transcript {
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
        .out_buf = undefined,
        .frames = .init(.{ .extension = if (compressed) .{ .permessage_deflate = .init } else null }),
        .max_message_size = max_message_size,
    };
    // A batch's flusher task (`H2Socket.deinit` would also end the
    // response, which has none here).
    defer sock.batch.deinit(std.testing.io);
    var d: if (features.compression) deflate.Deflate else void = if (features.compression) .init(.{}, .{}, arena) else {};
    defer if (features.compression) d.deinit();
    var socket: websocket.Socket = .{
        .conn = .{ .h2 = sock },
        .allocator = arena,
        .io = std.testing.io,
        .max_message_size = max_message_size,
    };
    if (comptime features.compression) {
        if (compressed) socket.deflate = &d;
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
