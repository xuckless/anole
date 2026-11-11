//! The buffer budget (#131) for WebSocket messages over HTTP/1.1: a
//! message being reassembled holds its bytes of the executor's
//! `buffer_budget` until it is whole, and one that would pass it is closed
//! with 1013 (Try Again Later). The budget's arithmetic is tested in
//! src/http/core/admission.zig, bodies in src/http/core/budget_test.zig.
const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");
const websocket = @import("root.zig");
const wait = @import("anole_test_wait");

const Server = dusty.Server(void);
const loopback: dusty.Address = .{ .ip = .{ .ip4 = .loopback(0) } };

fn echo(ws: *websocket.Socket) !void {
    while (try ws.next()) |msg| try ws.send(msg.type, msg.data);
}

/// A raw client: the handshake, then frames as written here.
const Raw = struct {
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,
    rbuf: [1024]u8 = undefined,
    wbuf: [1024]u8 = undefined,

    fn open(self: *Raw, io: std.Io, addr: std.Io.net.IpAddress) !void {
        self.stream = try addr.connect(io, .{ .mode = .stream });
        errdefer self.stream.close(io);
        self.reader = self.stream.reader(io, &self.rbuf);
        self.writer = self.stream.writer(io, &self.wbuf);
        try self.writer.interface.writeAll("GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n");
        try self.writer.interface.flush();
        const status = try self.reader.interface.takeDelimiterInclusive('\n');
        if (!std.mem.startsWith(u8, status, "HTTP/1.1 101")) return error.NotUpgraded;
        while (true) {
            const line = try self.reader.interface.takeDelimiterInclusive('\n');
            if (std.mem.eql(u8, line, "\r\n")) break;
        }
    }

    fn close(self: *Raw, io: std.Io) void {
        self.stream.close(io);
    }

    /// A masked frame (zero key) of `len` bytes of 'x', short of its
    /// payload by `short` bytes.
    fn frame(self: *Raw, first: u8, len: usize, short: usize) !void {
        const w = &self.writer.interface;
        if (len < 126) {
            try w.writeAll(&.{ first, 0x80 | @as(u8, @intCast(len)) });
        } else if (len <= 0xffff) {
            try w.writeAll(&.{ first, 0x80 | 126 });
            try w.writeInt(u16, @intCast(len), .big);
        } else {
            try w.writeAll(&.{ first, 0x80 | 127 });
            try w.writeInt(u64, len, .big);
        }
        try w.writeAll(&.{ 0, 0, 0, 0 });
        try w.splatByteAll('x', len - short);
        try w.flush();
    }

    /// The next frame's opcode and payload length; the payload is skipped,
    /// a close's code kept.
    fn next(self: *Raw) !struct { opcode: u8, len: u64, code: u16 } {
        const r = &self.reader.interface;
        const h = try r.takeArray(2);
        const opcode = h[0] & 0x0f;
        var len: u64 = h[1] & 0x7f;
        if (len == 126) len = try r.takeInt(u16, .big) else if (len == 127) len = try r.takeInt(u64, .big);
        var code: u16 = 0;
        if (opcode == 0x8 and len >= 2) {
            code = try r.takeInt(u16, .big);
            try r.discardAll(len - 2);
        } else try r.discardAll(len);
        return .{ .opcode = opcode, .len = len, .code = code };
    }
};

fn heldIs(server: *Server, n: usize) bool {
    return server.admission.rows[0].held_bytes.load(.monotonic) == n;
}

fn waitHeld(io: std.Io, server: *Server, n: usize) !void {
    const S = struct { s: *Server, n: usize };
    try wait.waitUntil(io, "the bytes held of the buffer budget", S{ .s = server, .n = n }, struct {
        fn f(x: S) bool {
            return heldIs(x.s, x.n);
        }
    }.f);
}

test "budget: WebSocket messages in pieces hold their bytes until whole; one past the budget is closed 1013" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    var server = Server.init(gpa, io, .{ .listeners = &.{.{ .address = loopback }}, .buffer_budget = 250 }, {});
    defer server.deinit();
    server.router.get("/ws", websocket.route(void, echo, .{}));
    var future = try io.concurrent(struct {
        fn run(s: *Server) anyerror!void {
            try s.run();
        }
    }.run, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);

    // Two sockets each hold a first piece of 100 bytes (binary, no FIN).
    var a: Raw = undefined;
    try a.open(io, server.address.ip);
    defer a.close(io);
    try a.frame(0x02, 100, 0);
    try waitHeld(io, &server, 100);
    var b: Raw = undefined;
    try b.open(io, server.address.ip);
    var b_open = true;
    defer if (b_open) b.close(io);
    try b.frame(0x02, 100, 0);
    try waitHeld(io, &server, 200);

    // A third's would pass 250: closed with 1013, nothing more held.
    var c: Raw = undefined;
    try c.open(io, server.address.ip);
    defer c.close(io);
    try c.frame(0x02, 100, 0);
    const refused = try c.next();
    try std.testing.expectEqual(@as(u8, 0x8), refused.opcode);
    try std.testing.expectEqual(@as(u16, 1013), refused.code);
    try std.testing.expectEqual(@as(u64, 1), server.admission.refused_memory.load(.monotonic));
    try std.testing.expect(heldIs(&server, 200));

    // Finished, a message is delivered whole and gives its bytes back.
    try a.frame(0x80, 10, 0);
    const whole = try a.next();
    try std.testing.expectEqual(@as(u8, 0x2), whole.opcode);
    try std.testing.expectEqual(@as(u64, 110), whole.len);
    try waitHeld(io, &server, 100);

    // A socket that goes mid-message gives its bytes back.
    b.close(io);
    b_open = false;
    try waitHeld(io, &server, 0);

    // A frame bigger than the read buffer is held whole at its header, so
    // one that can't be is refused before its payload arrives.
    try a.frame(0x02, 100, 0);
    try waitHeld(io, &server, 100);
    var d: Raw = undefined;
    try d.open(io, server.address.ip);
    defer d.close(io);
    try d.frame(0x82, 64 * 1024, 64 * 1024);
    const at_header = try d.next();
    try std.testing.expectEqual(@as(u16, 1013), at_header.code);
    try std.testing.expectEqual(@as(u64, 2), server.admission.refused_memory.load(.monotonic));
    try a.frame(0x80, 1, 0);
    _ = try a.next();
    try waitHeld(io, &server, 0);
}
