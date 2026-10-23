// Anole code, written for the HTTP core after it left lalinsky/dusty; see
// LICENSE.dusty and THIRD_PARTY_NOTICES for the rest of src/http/core.

//! Parked streamed responses over HTTP/1.1 (the adopter path): the wire,
//! the peer going away, and writeEvent against EventStream.

const std = @import("std");
const dusty = @import("root.zig");
const loopback_addr: dusty.Address = .{ .ip = .{ .ip4 = .loopback(0) } };
const loopback: []const dusty.Listener = &.{.{ .address = loopback_addr }};

const Probe = struct {
    parked: ?*dusty.Parked = null,
    opened: std.Io.Event = .unset,
    gone: std.Io.Event = .unset,
    gone_calls: std.atomic.Value(u32) = .init(0),

    fn onGone(ctx: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ctx));
        _ = self.gone_calls.fetchAdd(1, .monotonic);
        self.gone.set(std.testing.io);
    }
};

var probe: Probe = .{};

fn parkHandler(req: *dusty.Request, res: *dusty.Response) !void {
    try res.header("Content-Type", "text/event-stream");
    probe.parked = try res._park(req, .{ .gone = Probe.onGone, .ctx = &probe });
    probe.opened.set(std.testing.io);
}

fn readUntil(r: *std.Io.Reader, buf: []u8, needle: []const u8) ![]const u8 {
    var len: usize = 0;
    while (std.mem.indexOf(u8, buf[0..len], needle) == null) {
        r.fillMore() catch break;
        const b = r.buffered();
        if (b.len == 0) break;
        const n = @min(b.len, buf.len - len);
        @memcpy(buf[len..][0..n], b[0..n]);
        r.toss(n);
        len += n;
    }
    return buf[0..len];
}

test "parked h1: head, two bursts, end: one chunk per burst and the terminator" {
    const io = std.testing.io;
    probe = .{};
    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback }, {});
    defer server.deinit();
    server.router.get("/live", parkHandler);
    var fut = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer fut.cancel(io) catch {};
    try server.waitReady(io);

    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var wbuf: [256]u8 = undefined;
    var writer = stream.writer(io, &wbuf);
    var rbuf: [512]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    try writer.interface.writeAll("GET /live HTTP/1.1\r\nHost: x\r\n\r\n");
    try writer.interface.flush();
    try probe.opened.wait(io);
    const p = probe.parked.?;

    var got: [1024]u8 = undefined;
    // First burst.
    try std.testing.expect(p.begin());
    try p.write(&.{ "id: 1\n", "data: a\n\n" });
    p.endBurst();
    var seen = try readUntil(&reader.interface, &got, "data: a\n\n\r\n");
    try std.testing.expect(std.mem.indexOf(u8, seen, "Content-Type: text/event-stream") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen, "Transfer-Encoding: chunked") != null);
    // One chunk: the length of both parts.
    try std.testing.expect(std.mem.indexOf(u8, seen, "\r\nf\r\nid: 1\ndata: a\n\n\r\n") != null);
    // Second burst, then the end.
    try std.testing.expect(p.begin());
    try p.write(&.{"data: b\n\n"});
    p.end();
    seen = try readUntil(&reader.interface, &got, "0\r\n\r\n");
    try std.testing.expect(std.mem.indexOf(u8, seen, "data: b\n\n\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, seen, "0\r\n\r\n"));
    // After the end no burst begins; the owner releases once.
    try std.testing.expect(!p.begin());
    p.release();
}

test "parked h1: the client closes: gone once, then release frees the connection" {
    const io = std.testing.io;
    probe = .{};
    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback }, {});
    defer server.deinit();
    server.router.get("/live", parkHandler);
    var fut = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer fut.cancel(io) catch {};
    try server.waitReady(io);

    {
        const stream = try server.address.ip.connect(io, .{ .mode = .stream });
        var wbuf: [256]u8 = undefined;
        var writer = stream.writer(io, &wbuf);
        try writer.interface.writeAll("GET /live HTTP/1.1\r\nHost: x\r\n\r\n");
        try writer.interface.flush();
        try probe.opened.wait(io);
        stream.close(io);
    }
    try probe.gone.wait(io);
    try std.testing.expectEqual(@as(u32, 1), probe.gone_calls.load(.monotonic));
    // The owner is done with it: the connection can be freed.
    probe.parked.?.release();
}

test "writeEvent and EventStream produce identical bytes for CR, LF and CRLF data" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "one", "a\nb", "a\rb", "a\r\nb", "a\n\nb\r", "" }) |data| {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try dusty.writeEvent(&aw.writer, data, .{ .event = "e", .id = "7" });
        // The reference: the per-line rule EventStream applies.
        var want: std.Io.Writer.Allocating = .init(gpa);
        defer want.deinit();
        try want.writer.writeAll("event: e\nid: 7\n");
        var rest = data;
        while (std.mem.indexOfAny(u8, rest, "\r\n")) |i| {
            try want.writer.print("data: {s}\n", .{rest[0..i]});
            var next = i + 1;
            if (rest[i] == '\r' and next < rest.len and rest[next] == '\n') next += 1;
            rest = rest[next..];
        }
        try want.writer.print("data: {s}\n\n", .{rest});
        try std.testing.expectEqualStrings(want.written(), aw.written());
    }
}
