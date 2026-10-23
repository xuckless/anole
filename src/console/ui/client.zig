//! The console's client side of the protocol over any pair of descriptors (a
//! unix socket, one end of a socketpair, pipes in tests). Poll-friendly: the
//! run loop polls `in_fd` for reading and, while `wantsWrite()`, `out_fd` for
//! writing.
const std = @import("std");
const protocol = @import("protocol.zig");
const sys = @import("sys.zig");

pub const HandshakeError = error{
    /// The server closed or sent nothing in time.
    Closed,
    Timeout,
    /// The server sent an error frame (busy, version); see `refusal`.
    Refused,
    /// Not a hello.
    BadFrame,
    /// The server speaks another protocol version.
    Version,
    OutOfMemory,
};

pub const Conn = struct {
    gpa: std.mem.Allocator,
    in_fd: sys.fd_t,
    out_fd: sys.fd_t,
    reader: protocol.LineReader,
    out: std.ArrayList(u8) = .empty,
    out_off: usize = 0,
    next_id: u32 = 1,
    /// The server's hello, once the handshake is done. Lives in `hello_arena`.
    hello: ?protocol.Hello = null,
    hello_arena: std.heap.ArenaAllocator,
    /// The error text of a refused handshake (code: message), owned.
    refusal: ?[]u8 = null,
    /// monotonic ms of the last byte heard; set by `touch`.
    last_heard_ms: i64 = 0,
    closed: bool = false,

    pub fn init(gpa: std.mem.Allocator, in_fd: sys.fd_t, out_fd: sys.fd_t) Conn {
        return .{
            .gpa = gpa,
            .in_fd = in_fd,
            .out_fd = out_fd,
            .reader = protocol.LineReader.init(protocol.max_server_line),
            .hello_arena = .init(gpa),
        };
    }

    pub fn deinit(self: *Conn) void {
        self.reader.deinit(self.gpa);
        self.out.deinit(self.gpa);
        self.hello_arena.deinit();
        if (self.refusal) |r| self.gpa.free(r);
    }

    /// Closes the descriptors (once; the same descriptor twice is closed once).
    pub fn close(self: *Conn) void {
        if (self.closed) return;
        self.closed = true;
        sys.close(self.in_fd);
        if (self.out_fd != self.in_fd) sys.close(self.out_fd);
    }

    /// Blocking: reads the server's hello (up to `timeout_ms`), checks the
    /// version, answers with the client hello.
    pub fn handshake(self: *Conn, client_name: []const u8, timeout_ms: i32, now: *const fn () i64) HandshakeError!void {
        const deadline = now() + timeout_ms;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        while (true) {
            if (self.reader.next() catch return error.BadFrame) |line| {
                const frame = protocol.decode(arena.allocator(), line) catch return error.BadFrame;
                switch (frame) {
                    .hello => |h| {
                        if (h.proto != protocol.proto) return error.Version;
                        const a = self.hello_arena.allocator();
                        // Keep a copy that lives as long as the connection.
                        const copy = protocol.decode(a, line) catch return error.OutOfMemory;
                        self.hello = copy.hello;
                        break;
                    },
                    .err => |e| {
                        self.refusal = std.fmt.allocPrint(self.gpa, "{s}: {s}", .{ e.code, e.message orelse "" }) catch return error.OutOfMemory;
                        return if (std.mem.eql(u8, e.code, protocol.code_version)) error.Version else error.Refused;
                    },
                    else => return error.BadFrame,
                }
            }
            const left = deadline - now();
            if (left <= 0) return error.Timeout;
            var p = [1]sys.PollFd{.{ .fd = self.in_fd, .events = sys.POLLIN, .revents = 0 }};
            if (sys.poll(&p, @intCast(@min(left, 1000))) == 0) continue;
            _ = self.fill() catch return error.Closed;
        }
        self.last_heard_ms = now();
        self.send(.{ .hello = .{ .client = client_name } }) catch return error.Closed;
        self.flush() catch return error.Closed;
    }

    /// Reads what is available (call when `in_fd` polled readable) into the
    /// line buffer. Returns false at end of file.
    pub fn fill(self: *Conn) !bool {
        var buf: [16 * 1024]u8 = undefined;
        const n = sys.read(self.in_fd, &buf) catch |err| switch (err) {
            error.WouldBlock => return true,
            else => return error.Closed,
        };
        if (n == 0) return false;
        try self.reader.feed(self.gpa, buf[0..n]);
        return true;
    }

    /// The next frame, allocated from `arena`; null when no complete line is
    /// buffered. Garbage lines are skipped.
    pub fn nextFrame(self: *Conn, arena: std.mem.Allocator) !?protocol.Frame {
        while (true) {
            const line = (self.reader.next() catch return error.LineTooLong) orelse return null;
            if (line.len == 0) continue;
            return protocol.decode(arena, line) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidFrame => continue,
            };
        }
    }

    /// Queues a frame for writing.
    pub fn send(self: *Conn, frame: protocol.Frame) !void {
        var aw: std.Io.Writer.Allocating = .fromArrayList(self.gpa, &self.out);
        defer self.out = aw.toArrayList();
        try protocol.encode(frame, &aw.writer);
    }

    pub fn wantsWrite(self: *const Conn) bool {
        return self.out_off < self.out.items.len;
    }

    /// Writes as much as the descriptor takes; WouldBlock is not an error.
    pub fn flush(self: *Conn) !void {
        while (self.out_off < self.out.items.len) {
            const n = sys.write(self.out_fd, self.out.items[self.out_off..]) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return error.Closed,
            };
            self.out_off += n;
        }
        self.out.clearRetainingCapacity();
        self.out_off = 0;
    }

    fn request(self: *Conn, req: protocol.Request) !u32 {
        var r = req;
        r.id = self.next_id;
        self.next_id +%= 1;
        try self.send(.{ .req = r });
        return r.id;
    }

    pub fn ping(self: *Conn) !u32 {
        return self.request(.{ .id = 0, .op = "ping" });
    }

    pub fn snapshot(self: *Conn, view: protocol.View) !u32 {
        return self.request(.{ .id = 0, .op = "snapshot", .what = @tagName(view) });
    }

    pub fn subscribeLogs(self: *Conn, filter: protocol.Filter, backlog: u16) !u32 {
        return self.request(.{ .id = 0, .op = "subscribe", .stream = "logs", .filter = filter, .backlog = backlog });
    }

    pub fn subscribeStats(self: *Conn, interval_ms: u32) !u32 {
        return self.request(.{ .id = 0, .op = "subscribe", .stream = "stats", .interval_ms = interval_ms });
    }

    pub fn subscribeErrors(self: *Conn) !u32 {
        return self.request(.{ .id = 0, .op = "subscribe", .stream = "errors" });
    }

    pub fn unsubscribe(self: *Conn, sub: u32) !u32 {
        return self.request(.{ .id = 0, .op = "unsubscribe", .sub = sub });
    }

    /// reload / drain / restart / full_restart / launch_info; `confirm` is the
    /// op's token for the mutating ones.
    pub fn op(self: *Conn, name: []const u8, confirm: ?[]const u8) !u32 {
        return self.request(.{ .id = 0, .op = name, .confirm = confirm });
    }
};

fn fakeNow() i64 {
    return 0;
}

test "client: handshake, requests and frames over pipes" {
    // The console's terminal side is not on Windows yet (design D15): no pipes, no clock.
    if (!sys.supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const to_client = try sys.pipe();
    const to_server = try sys.pipe();
    var c = Conn.init(gpa, to_client[0], to_server[1]);
    defer {
        c.deinit();
        sys.close(to_client[0]);
        sys.close(to_client[1]);
        sys.close(to_server[0]);
        sys.close(to_server[1]);
    }
    const hello = "{\"t\":\"hello\",\"proto\":1,\"anole\":\"0.3.0\",\"app\":{\"name\":\"api\",\"pid\":7},\"allow\":{\"reload\":true},\"extra\":1}\n";
    try sys.writeAll(to_client[1], hello);
    try c.handshake("anole 0.3.0", 100, fakeNow);
    try std.testing.expectEqualStrings("api", c.hello.?.app.?.name);
    try std.testing.expect(c.hello.?.allow.?.reload);

    _ = try c.ping();
    _ = try c.snapshot(.conns);
    _ = try c.subscribeLogs(.{ .level = "warn" }, 100);
    _ = try c.op("drain", "drain");
    try c.flush();
    try std.testing.expect(!c.wantsWrite());

    var buf: [2048]u8 = undefined;
    const n = try sys.read(to_server[0], &buf);
    var lr = protocol.LineReader.init(4096);
    defer lr.deinit(gpa);
    try lr.feed(gpa, buf[0..n]);
    var arena_s = std.heap.ArenaAllocator.init(gpa);
    defer arena_s.deinit();
    const a = arena_s.allocator();
    const f0 = try protocol.decode(a, (try lr.next()).?);
    try std.testing.expectEqualStrings("anole 0.3.0", f0.hello.client.?);
    const f1 = try protocol.decode(a, (try lr.next()).?);
    try std.testing.expectEqual(@as(u32, 1), f1.req.id);
    try std.testing.expectEqualStrings("ping", f1.req.op);
    const f2 = try protocol.decode(a, (try lr.next()).?);
    try std.testing.expectEqualStrings("conns", f2.req.what.?);
    const f3 = try protocol.decode(a, (try lr.next()).?);
    try std.testing.expectEqualStrings("warn", f3.req.filter.?.level.?);
    const f4 = try protocol.decode(a, (try lr.next()).?);
    try std.testing.expectEqual(@as(u32, 4), f4.req.id);
    try std.testing.expectEqualStrings("drain", f4.req.confirm.?);

    // Frames from the server, garbage skipped.
    try sys.writeAll(to_client[1], "garbage\n{\"t\":\"dropped\",\"sub\":1,\"n\":5}\n{\"t\":\"bye\",\"reason\":\"drain\"}\n");
    try std.testing.expect(try c.fill());
    const d = (try c.nextFrame(a)).?;
    try std.testing.expectEqual(@as(u64, 5), d.dropped.n);
    const b = (try c.nextFrame(a)).?;
    try std.testing.expectEqualStrings("drain", b.bye.reason);
    try std.testing.expect((try c.nextFrame(a)) == null);
}

test "client: handshake refused with busy and with a newer version" {
    // The console's terminal side is not on Windows yet (design D15): no pipes, no clock.
    if (!sys.supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    {
        const to_client = try sys.pipe();
        const to_server = try sys.pipe();
        var c = Conn.init(gpa, to_client[0], to_server[1]);
        defer {
            c.deinit();
            sys.close(to_client[0]);
            sys.close(to_client[1]);
            sys.close(to_server[0]);
            sys.close(to_server[1]);
        }
        try sys.writeAll(to_client[1], "{\"t\":\"error\",\"code\":\"busy\",\"message\":\"4 consoles are attached already\"}\n");
        try std.testing.expectError(error.Refused, c.handshake("x", 100, fakeNow));
        try std.testing.expectEqualStrings("busy: 4 consoles are attached already", c.refusal.?);
    }
    {
        const to_client = try sys.pipe();
        const to_server = try sys.pipe();
        var c = Conn.init(gpa, to_client[0], to_server[1]);
        defer {
            c.deinit();
            sys.close(to_client[0]);
            sys.close(to_client[1]);
            sys.close(to_server[0]);
            sys.close(to_server[1]);
        }
        try sys.writeAll(to_client[1], "{\"t\":\"hello\",\"proto\":2}\n");
        try std.testing.expectError(error.Version, c.handshake("x", 100, fakeNow));
    }
}
