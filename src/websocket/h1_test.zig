//! WebSocket over HTTP/1.1, end to end with a raw client: the close codes a
//! failed receive sends, and the close 1001 a drain sends.
const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");
const websocket = @import("root.zig");

var saw_draining: std.atomic.Value(bool) = .init(false);
/// Closes the echo handler has seen, and whether any of those sockets
/// needed a flusher task of its own (`dusty.WebSocketBatch`).
var closes_seen: std.atomic.Value(usize) = .init(0);
var flusher_started: std.atomic.Value(bool) = .init(false);

fn echo(req: *dusty.Request, res: *dusty.Response) !void {
    var ws = (try websocket.upgrade(req, res, .{ .max_message_size = 8 })) orelse {
        res.status = .bad_request;
        return;
    };
    defer ws.deinit();
    while (true) {
        const msg = ws.receive() catch return;
        switch (msg.type) {
            .text, .binary => {
                // A handler that goes off to wait for something with the
                // peer's next message unread (cut short by the server's
                // shutdown, which closes the socket under it).
                const wait = std.mem.eql(u8, msg.data, "wait");
                if (wait) {
                    ws.send(msg.type, msg.data) catch return;
                    req.io.sleep(.fromSeconds(10), .awake) catch return;
                    return;
                }
                try ws.send(msg.type, msg.data);
            },
            .close => {
                saw_draining.store(ws.draining(), .release);
                if (ws.conn == .h1 and ws.conn.h1.batch.started) flusher_started.store(true, .release);
                _ = closes_seen.fetchAdd(1, .acq_rel);
                return;
            },
            else => {},
        }
    }
}

const Raw = struct {
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,
    rbuf: [1024]u8 = undefined,
    wbuf: [1024]u8 = undefined,

    fn open(self: *Raw, io: std.Io, addr: std.Io.net.IpAddress) !void {
        self.stream = try addr.connect(io, .{ .mode = .stream });
        self.reader = self.stream.reader(io, &self.rbuf);
        self.writer = self.stream.writer(io, &self.wbuf);
        try self.writer.interface.writeAll("GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n");
        try self.writer.interface.flush();
        const head = try self.reader.interface.takeDelimiterInclusive('\n');
        if (!std.mem.startsWith(u8, head, "HTTP/1.1 101")) return error.NotUpgraded;
        while (true) {
            const line = try self.reader.interface.takeDelimiterInclusive('\n');
            if (std.mem.eql(u8, line, "\r\n")) break;
        }
    }

    /// One masked frame (zero key, so the payload goes as it is).
    fn send(self: *Raw, opcode: u8, payload: []const u8) !void {
        try self.queue(opcode, payload);
        try self.writer.interface.flush();
    }

    /// `send` without the flush: frames that leave together.
    fn queue(self: *Raw, opcode: u8, payload: []const u8) !void {
        std.debug.assert(payload.len < 126);
        try self.writer.interface.writeAll(&.{ 0x80 | opcode, 0x80 | @as(u8, @intCast(payload.len)), 0, 0, 0, 0 });
        try self.writer.interface.writeAll(payload);
    }

    /// The next frame's opcode and payload (unmasked, short).
    fn next(self: *Raw, out: []u8) !struct { opcode: u8, payload: []u8 } {
        const head = try self.reader.interface.takeArray(2);
        const len = head[1] & 0x7f;
        std.debug.assert(len < 126);
        try self.reader.interface.readSliceAll(out[0..len]);
        return .{ .opcode = head[0] & 0x0f, .payload = out[0..len] };
    }

    /// The close frame's reason, in `buf`.
    fn expectClose(self: *Raw, code: u16, buf: []u8) ![]u8 {
        const f = try self.next(buf);
        try std.testing.expectEqual(@as(u8, 0x8), f.opcode);
        try std.testing.expect(f.payload.len >= 2);
        try std.testing.expectEqual(code, std.mem.readInt(u16, f.payload[0..2], .big));
        return f.payload[2..];
    }
};

fn startServer(server: *dusty.Server(void), io: std.Io) !std.Io.Future(anyerror!void) {
    server.router.get("/ws", echo);
    const future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) anyerror!void {
            try s.run();
        }
    }.run, .{server});
    try server.waitReady(io);
    return future;
}

test "WebSocket over HTTP/1.1: a message too large gets close 1009, bad UTF-8 1007" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var server = dusty.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer server.deinit();
    var future = try startServer(&server, io);
    defer future.cancel(io) catch {};

    var a: Raw = undefined;
    try a.open(io, server.address.ip);
    defer a.stream.close(io);
    try a.send(0x1, "fits");
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("fits", (try a.next(&buf)).payload);
    try a.send(0x2, "nine bytes");
    _ = try a.expectClose(1009, &buf);

    var b: Raw = undefined;
    try b.open(io, server.address.ip);
    defer b.stream.close(io);
    try b.send(0x1, "\xff");
    _ = try b.expectClose(1007, &buf);
}

test "WebSocket over HTTP/1.1: the drain closes an open socket with 1001 and does not wait out timeout.shutdown" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    saw_draining.store(false, .release);
    var server = dusty.Server(void).init(gpa, io, .{
        .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }},
        .timeout = .{ .shutdown = .fromSeconds(20) },
    }, {});
    defer server.deinit();
    var future = try startServer(&server, io);
    defer future.cancel(io) catch {};

    var c: Raw = undefined;
    try c.open(io, server.address.ip);
    defer c.stream.close(io);
    try c.send(0x1, "hi");
    var buf: [125]u8 = undefined;
    try std.testing.expectEqualStrings("hi", (try c.next(&buf)).payload);

    // The drain blocks until the socket is done, so it runs beside the test.
    const start: std.Io.Clock.Timestamp = .now(io, .awake);
    var drain = try io.concurrent(struct {
        fn run(f: *std.Io.Future(anyerror!void), io_: std.Io) !void {
            try std.testing.expectError(error.Canceled, f.cancel(io_));
        }
    }.run, .{ &future, io });
    try std.testing.expectEqualStrings("server shutting down", try c.expectClose(1001, &buf));
    // The closing handshake: answer, and the server ends the connection.
    try c.send(0x8, &.{ 0x03, 0xe9 });
    try std.testing.expectError(error.EndOfStream, c.reader.interface.fillMore());
    try drain.await(io);
    try std.testing.expect(start.durationTo(.now(io, .awake)).raw.toMilliseconds() < 5000);
    try std.testing.expect(saw_draining.load(.acquire));
}

test "WebSocket over HTTP/1.1: pipelined messages are answered in order, a ping among them in its place" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var server = dusty.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer server.deinit();
    var future = try startServer(&server, io);
    defer future.cancel(io) catch {};

    var a: Raw = undefined;
    try a.open(io, server.address.ip);
    defer a.stream.close(io);
    var name: [8]u8 = undefined;
    // In one write, so the server reads them as one batch.
    for (0..33) |i| {
        if (i == 16) try a.queue(0x9, "p") else try a.queue(0x1, try std.fmt.bufPrint(&name, "m{d}", .{i}));
    }
    try a.writer.interface.flush();
    var buf: [16]u8 = undefined;
    for (0..33) |i| {
        const f = try a.next(&buf);
        if (i == 16) {
            try std.testing.expectEqual(@as(u8, 0xA), f.opcode);
            try std.testing.expectEqualStrings("p", f.payload);
        } else {
            try std.testing.expectEqual(@as(u8, 0x1), f.opcode);
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&name, "m{d}", .{i}), f.payload);
        }
    }
    try a.send(0x8, &.{ 0x03, 0xe8 });
    _ = try a.expectClose(1000, &buf);
}

test "WebSocket over HTTP/1.1: an answer held for a batch goes out while the handler waits on something else" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var server = dusty.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer server.deinit();
    var future = try startServer(&server, io);
    defer future.cancel(io) catch {};

    var a: Raw = undefined;
    try a.open(io, server.address.ip);
    defer a.stream.close(io);
    // "wait" with "x" behind it: the echo of "wait" is held for the batch,
    // and the handler then sleeps with "x" unread.
    try a.queue(0x1, "wait");
    try a.queue(0x1, "x");
    try a.writer.interface.flush();
    const start: std.Io.Clock.Timestamp = .now(io, .awake);
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("wait", (try a.next(&buf)).payload);
    try std.testing.expect(start.durationTo(.now(io, .awake)).raw.toMilliseconds() < 2000);
}

test "WebSocket over HTTP/1.1: sockets share their executor's backstop, and one whose handler waits holds up no other" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var server = dusty.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer server.deinit();
    var future = try startServer(&server, io);
    defer future.cancel(io) catch {};
    var buf: [16]u8 = undefined;

    // One socket at a time: the backstop ends with the last socket on the
    // executor and starts again with the next one's first batch. Their
    // readers flush on their way to the next read, so neither socket needs
    // a flusher task of its own.
    closes_seen.store(0, .release);
    flusher_started.store(false, .release);
    for (0..2) |_| {
        var a: Raw = undefined;
        try a.open(io, server.address.ip);
        defer a.stream.close(io);
        for (0..3) |_| try a.queue(0x1, "m");
        try a.writer.interface.flush();
        for (0..3) |_| try std.testing.expectEqualStrings("m", (try a.next(&buf)).payload);
        try a.send(0x8, &.{ 0x03, 0xe8 });
        _ = try a.expectClose(1000, &buf);
    }
    var polls: usize = 0;
    while (closes_seen.load(.acquire) < 2 and polls < 2000) : (polls += 1) try io.sleep(.fromMilliseconds(1), .awake);
    try std.testing.expectEqual(@as(usize, 2), closes_seen.load(.acquire));
    try std.testing.expect(!flusher_started.load(.acquire));

    // "wait" with "x" behind it: its handler sleeps with the echo held, and
    // the backstop has that socket's flusher send it.
    var w: Raw = undefined;
    try w.open(io, server.address.ip);
    defer w.stream.close(io);
    try w.queue(0x1, "wait");
    try w.queue(0x1, "x");
    try w.writer.interface.flush();
    const start: std.Io.Clock.Timestamp = .now(io, .awake);
    try std.testing.expectEqualStrings("wait", (try w.next(&buf)).payload);

    // Meanwhile the others on the executor are answered as ever.
    var others: [4]Raw = undefined;
    for (&others) |*o| try o.open(io, server.address.ip);
    defer for (&others) |*o| o.stream.close(io);
    for (0..3) |_| {
        for (&others) |*o| {
            for (0..4) |_| try o.queue(0x1, "y");
            try o.writer.interface.flush();
        }
        for (&others) |*o| {
            for (0..4) |_| try std.testing.expectEqualStrings("y", (try o.next(&buf)).payload);
        }
    }
    try std.testing.expect(start.durationTo(.now(io, .awake)).raw.toMilliseconds() < 2000);
}

const features = @import("build_options");

/// Whether the last socket `deflateHandler` opened compresses outside the
/// request's arena.
var deflate_apart: std.atomic.Value(bool) = .init(false);

fn deflateHandler(req: *dusty.Request, res: *dusty.Response) !void {
    var ws = (try websocket.upgrade(req, res, .{})) orelse {
        res.status = .bad_request;
        return;
    };
    defer ws.deinit();
    if (comptime features.compression) if (ws.deflate) |d| deflate_apart.store(d.allocator.ptr != req.arena.ptr, .release);
    ws.close(.normal, "") catch {};
}

/// Sends `head` on a new connection to `addr` and returns the status line.
fn handshake(io: std.Io, addr: std.Io.net.IpAddress, head: []const u8, line: []u8) ![]const u8 {
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var wbuf: [512]u8 = undefined;
    var rbuf: [512]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    var r = stream.reader(io, &rbuf);
    try w.interface.writeAll(head);
    try w.interface.flush();
    const got = try r.interface.takeDelimiterInclusive('\n');
    const n = @min(got.len, line.len);
    @memcpy(line[0..n], got[0..n]);
    return line[0..n];
}

test "WebSocket over HTTP/1.1: permessage-deflate keeps its buffers out of the request's arena" {
    if (comptime !features.compression) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var server = dusty.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer server.deinit();
    server.router.get("/deflate", deflateHandler);
    var future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) anyerror!void {
            try s.run();
        }
    }.run, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);

    var line: [64]u8 = undefined;
    const status = try handshake(io, server.address.ip, "GET /deflate HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Extensions: permessage-deflate\r\n\r\n", &line);
    try std.testing.expect(std.mem.startsWith(u8, status, "HTTP/1.1 101"));
    for (0..1000) |_| {
        if (deflate_apart.load(.acquire)) break;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(deflate_apart.load(.acquire));
}
