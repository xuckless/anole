//! WebSocket over HTTP/2 (RFC 8441), end to end: dusty's HTTP/2 engine with
//! an `anole.websocket` echo handler, and a minimal nghttp2 client that opens
//! an extended CONNECT and speaks masked frames through websocket-zig's
//! client codec. Autobahn has no RFC 8441 mode, so this is the HTTP/2 path's
//! conformance check alongside the codec's own tests.
const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");
const c = @import("anole_nghttp2_c");
const wsc = @import("anole_websocket_codec").client;
const websocket = @import("root.zig");

fn echo(req: *dusty.Request, res: *dusty.Response) !void {
    var ws = (try websocket.upgrade(req, res, .{})) orelse {
        res.status = .bad_request;
        return;
    };
    defer ws.deinit();
    try std.testing.expect(ws == .h2);
    while (true) {
        const msg = ws.receive() catch |err| switch (err) {
            error.ConnectionClosed => return,
            else => |e| return e,
        };
        switch (msg.type) {
            .text, .binary => try ws.send(msg.type, msg.data),
            .close => return,
            else => {},
        }
    }
}

/// One HTTP/2 connection with one extended-CONNECT stream.
const Client = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,
    read_buf: [16 * 1024]u8 = undefined,
    write_buf: [16 * 1024]u8 = undefined,
    session: ?*c.nghttp2_session = null,
    stream_id: i32 = -1,
    status: u16 = 0,
    closed: bool = false,
    close_code: u32 = 0,
    /// WebSocket bytes to send, and what has gone.
    outgoing: [4096]u8 = undefined,
    out_len: usize = 0,
    out_sent: usize = 0,
    /// End the stream once what is queued has gone.
    finished: bool = false,
    /// WebSocket bytes received.
    incoming: [8192]u8 = undefined,
    in_len: usize = 0,

    fn init(self: *Client, io: std.Io, addr: std.Io.net.IpAddress) !void {
        self.* = .{ .io = io, .stream = try addr.connect(io, .{ .mode = .stream }), .reader = undefined, .writer = undefined };
        self.reader = self.stream.reader(io, &self.read_buf);
        self.writer = self.stream.writer(io, &self.write_buf);
        var cbs: ?*c.nghttp2_session_callbacks = null;
        _ = c.nghttp2_session_callbacks_new(&cbs);
        defer c.nghttp2_session_callbacks_del(cbs);
        c.nghttp2_session_callbacks_set_on_header_callback(cbs, onHeader);
        c.nghttp2_session_callbacks_set_on_data_chunk_recv_callback(cbs, onData);
        c.nghttp2_session_callbacks_set_on_stream_close_callback(cbs, onClose);
        if (c.nghttp2_session_client_new(&self.session, cbs, self) != 0) return error.Http2Init;
        if (c.nghttp2_submit_settings(self.session, c.NGHTTP2_FLAG_NONE, null, 0) != 0) return error.Http2Init;
    }

    fn deinit(self: *Client) void {
        c.nghttp2_session_del(self.session);
        self.stream.close(self.io);
    }

    fn flushSession(self: *Client) !void {
        while (true) {
            var data: [*c]const u8 = undefined;
            const n = c.nghttp2_session_mem_send2(self.session, &data);
            if (n < 0) return error.Http2Send;
            if (n == 0) break;
            try self.writer.interface.writeAll(data[0..@intCast(n)]);
        }
        try self.writer.interface.flush();
    }

    /// Sends what is pending, then reads until `done` holds.
    fn pumpUntil(self: *Client, done: *const fn (*Client) bool) !void {
        while (true) {
            try self.flushSession();
            if (done(self)) return;
            const r = &self.reader.interface;
            const bytes = try r.peekGreedy(1);
            const rv = c.nghttp2_session_mem_recv2(self.session, bytes.ptr, bytes.len);
            if (rv < 0) return error.Http2Recv;
            r.toss(@intCast(rv));
        }
    }

    fn open(self: *Client) !void {
        // nghttp2 lets :protocol out only once the server's SETTINGS allow it.
        try self.pumpUntil(struct {
            fn f(cl: *Client) bool {
                return c.nghttp2_session_get_remote_settings(cl.session, c.NGHTTP2_SETTINGS_ENABLE_CONNECT_PROTOCOL) == 1;
            }
        }.f);
        const nva = [_]c.nghttp2_nv{
            nv(":method", "CONNECT"),
            nv(":protocol", "websocket"),
            nv(":scheme", "http"),
            nv(":path", "/chat"),
            nv(":authority", "localhost"),
            nv("sec-websocket-version", "13"),
        };
        var provider: c.nghttp2_data_provider2 = .{ .source = .{ .ptr = self }, .read_callback = provide };
        self.stream_id = c.nghttp2_submit_request2(self.session, null, &nva, nva.len, &provider, self);
        if (self.stream_id < 0) return error.Http2Submit;
        try self.pumpUntil(struct {
            fn f(cl: *Client) bool {
                return cl.status != 0 or cl.closed;
            }
        }.f);
        if (self.status == 0) {
            std.debug.print("stream closed before a response, error code {d}\n", .{self.close_code});
            return error.StreamClosed;
        }
    }

    /// Queues one masked frame on the stream.
    fn sendFrame(self: *Client, opcode: wsc.Opcode, payload: []const u8) !void {
        var w: std.Io.Writer = .fixed(self.outgoing[self.out_len..]);
        var copy: [256]u8 = undefined;
        @memcpy(copy[0..payload.len], payload);
        try wsc.writeFrame(&w, copy[0..payload.len], .{ .opcode = opcode });
        self.out_len += w.buffered().len;
        _ = c.nghttp2_session_resume_data(self.session, self.stream_id);
    }

    /// Reads until a whole server frame is in, and returns its payload.
    fn nextFrame(self: *Client, opcode: *wsc.Opcode, out: []u8) ![]u8 {
        while (true) {
            var parser: wsc.Parser = .init(.{});
            var len: usize = 0;
            var used: usize = 0;
            const input = self.incoming[0..self.in_len];
            parse: while (true) {
                const res = try parser.feed(input[used..]);
                used += res.consumed;
                switch (res.event) {
                    .frame_header => |h| opcode.* = h.opcode,
                    .payload => |p| {
                        @memcpy(out[len..][0..p.len], p);
                        len += p.len;
                    },
                    .frame_end => {
                        std.mem.copyForwards(u8, self.incoming[0 .. self.in_len - used], self.incoming[used..self.in_len]);
                        self.in_len -= used;
                        return out[0..len];
                    },
                    .need_more => break :parse,
                }
            }
            // Not whole yet: read more, then parse from the start again.
            if (self.closed) return error.StreamClosed;
            grow_mark = self.in_len;
            try self.pumpUntil(struct {
                fn f(cl: *Client) bool {
                    return cl.in_len > grow_mark or cl.closed;
                }
            }.f);
        }
    }

    var grow_mark: usize = 0;

    fn nv(name: []const u8, value: []const u8) c.nghttp2_nv {
        return .{ .name = @constCast(name.ptr), .namelen = name.len, .value = @constCast(value.ptr), .valuelen = value.len, .flags = c.NGHTTP2_NV_FLAG_NONE };
    }

    fn onHeader(_: ?*c.nghttp2_session, _: [*c]const c.nghttp2_frame, name: [*c]const u8, namelen: usize, value: [*c]const u8, valuelen: usize, _: u8, user: ?*anyopaque) callconv(.c) c_int {
        const self: *Client = @ptrCast(@alignCast(user.?));
        if (std.mem.eql(u8, name[0..namelen], ":status")) self.status = std.fmt.parseInt(u16, value[0..valuelen], 10) catch 0;
        return 0;
    }

    fn onData(_: ?*c.nghttp2_session, _: u8, _: i32, data: [*c]const u8, len: usize, user: ?*anyopaque) callconv(.c) c_int {
        const self: *Client = @ptrCast(@alignCast(user.?));
        @memcpy(self.incoming[self.in_len..][0..len], data[0..len]);
        self.in_len += len;
        return 0;
    }

    fn onClose(_: ?*c.nghttp2_session, _: i32, code: u32, user: ?*anyopaque) callconv(.c) c_int {
        const self: *Client = @ptrCast(@alignCast(user.?));
        self.closed = true;
        self.close_code = code;
        return 0;
    }

    fn provide(_: ?*c.nghttp2_session, _: i32, buf: [*c]u8, length: usize, flags: [*c]u32, source: [*c]c.nghttp2_data_source, _: ?*anyopaque) callconv(.c) c.nghttp2_ssize {
        const self: *Client = @ptrCast(@alignCast(source.*.ptr.?));
        const rest = self.outgoing[self.out_sent..self.out_len];
        if (rest.len == 0) {
            if (!self.finished) return c.NGHTTP2_ERR_DEFERRED;
            flags.* |= c.NGHTTP2_DATA_FLAG_EOF;
            return 0;
        }
        const n = @min(rest.len, length);
        @memcpy(buf[0..n], rest[0..n]);
        self.out_sent += n;
        return @intCast(n);
    }
};

test "WebSocket over HTTP/2 (RFC 8441): echo, ping, close" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();

    var server = dusty.Server(void).init(gpa, io, .{
        .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } }, .http2_prior_knowledge = true }},
    }, {});
    defer server.deinit();
    server.router.get("/chat", echo);
    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};
    try server.ready.wait(io);

    var client: Client = undefined;
    try client.init(io, server.address.ip);
    defer client.deinit();
    try client.open();
    try std.testing.expectEqual(@as(u16, 200), client.status);

    var op: wsc.Opcode = undefined;
    var buf: [256]u8 = undefined;
    try client.sendFrame(.text, "hello over h2");
    try std.testing.expectEqualStrings("hello over h2", try client.nextFrame(&op, &buf));
    try std.testing.expectEqual(wsc.Opcode.text, op);

    try client.sendFrame(.ping, "are you there");
    try std.testing.expectEqualStrings("are you there", try client.nextFrame(&op, &buf));
    try std.testing.expectEqual(wsc.Opcode.pong, op);

    try client.sendFrame(.binary, &.{ 0, 1, 2, 255 });
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 255 }, try client.nextFrame(&op, &buf));
    try std.testing.expectEqual(wsc.Opcode.binary, op);

    // Close 1000: echoed, then the server ends the stream.
    try client.sendFrame(.close, &.{ 0x03, 0xe8 });
    const closing = try client.nextFrame(&op, &buf);
    try std.testing.expectEqual(wsc.Opcode.close, op);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0xe8 }, closing);
    // The closing handshake is done: end our side of the stream (RFC 8441
    // §5 maps the end of the connection to END_STREAM).
    client.finished = true;
    _ = c.nghttp2_session_resume_data(client.session, client.stream_id);
    try client.pumpUntil(struct {
        fn f(cl: *Client) bool {
            return cl.closed;
        }
    }.f);
}
