// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

//! HTTP/2 engine tests: a dusty server with cleartext HTTP/2 (prior
//! knowledge) on loopback, driven by a minimal nghttp2 client.
const std = @import("std");
const dusty = @import("../root.zig");
const c = @import("nghttp2");
const build_options = @import("build_options");
const tls = @import("tls");
const h2 = @import("h2.zig");

const loopback_addr: dusty.Address = .{ .ip = .{ .ip4 = .loopback(0) } };

/// A blocking HTTP/2 client over one connection, for tests: submit
/// requests, then `run` until every stream is closed.
const TestClient = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    read_buf: [16 * 1024 + 1024]u8 = undefined,
    write_buf: [16 * 1024 + 1024]u8 = undefined,
    reader: std.Io.net.Stream.Reader = undefined,
    writer: std.Io.net.Stream.Writer = undefined,
    /// The connection as the session sees it: the socket, or TLS over it.
    r: *std.Io.Reader = undefined,
    w: *std.Io.Writer = undefined,
    tls_conn: if (build_options.use_tls) ?tls.Connection else void = if (build_options.use_tls) null else {},
    tls_reader: if (build_options.use_tls) tls.Connection.Reader else void = undefined,
    tls_writer: if (build_options.use_tls) tls.Connection.Writer else void = undefined,
    plain_read: [4096]u8 = undefined,
    plain_write: [4096]u8 = undefined,
    session: ?*c.nghttp2_session = null,
    responses: std.AutoHashMapUnmanaged(i32, *Resp) = .empty,
    /// The last-stream-ID of each GOAWAY received, in order.
    goaways: [4]i32 = undefined,
    goaway_count: usize = 0,
    /// DATA frames received with no payload and END_STREAM: an end that
    /// could have gone on the frame before it.
    empty_ends: usize = 0,
    closes: usize = 0,
    /// WINDOW_UPDATE frames received for a stream (not the connection).
    stream_window_updates: usize = 0,

    const Resp = struct {
        status: u16 = 0,
        content_length: ?[]u8 = null,
        has_date: bool = false,
        body: std.ArrayList(u8) = .empty,
        trailer: ?[]u8 = null,
        closed: bool = false,
        /// When it closed: 1 for the first stream of the client to close.
        close_seq: usize = 0,
        error_code: u32 = 0,
        /// The request body to send, if any.
        send: []const u8 = "",
        sent: usize = 0,
        /// Never end the request side (a tunnel the peer keeps open).
        keep_open: bool = false,
    };

    fn init(self: *TestClient, gpa: std.mem.Allocator, io: std.Io, addr: std.Io.net.IpAddress) !void {
        self.* = .{ .gpa = gpa, .io = io, .stream = try addr.connect(io, .{ .mode = .stream }) };
        self.reader = self.stream.reader(io, &self.read_buf);
        self.writer = self.stream.writer(io, &self.write_buf);
        self.r = &self.reader.interface;
        self.w = &self.writer.interface;
        try self.initSession();
    }

    /// Over TLS, offering only "h2" through ALPN.
    fn initTls(self: *TestClient, gpa: std.mem.Allocator, io: std.Io, addr: std.Io.net.IpAddress, ca: *std.crypto.Certificate.Bundle) !void {
        return self.initTlsAfter(gpa, io, addr, ca, "");
    }

    /// `initTls`, with `preamble` (a PROXY protocol header) sent in the
    /// clear before the handshake.
    fn initTlsAfter(self: *TestClient, gpa: std.mem.Allocator, io: std.Io, addr: std.Io.net.IpAddress, ca: *std.crypto.Certificate.Bundle, preamble: []const u8) !void {
        self.* = .{ .gpa = gpa, .io = io, .stream = try addr.connect(io, .{ .mode = .stream }) };
        self.reader = self.stream.reader(io, &self.read_buf);
        self.writer = self.stream.writer(io, &self.write_buf);
        if (preamble.len > 0) {
            try self.writer.interface.writeAll(preamble);
            try self.writer.interface.flush();
        }
        var rng: std.Random.IoSource = .{ .io = io };
        self.tls_conn = try tls.client(&self.reader.interface, &self.writer.interface, .{
            .host = "localhost",
            .root_ca = ca.*,
            .now = std.Io.Clock.real.now(io),
            .rng = rng.interface(),
            .alpn_protocols = &.{"h2"},
        });
        if (!std.mem.eql(u8, self.tls_conn.?.alpn_protocol orelse "", "h2")) return error.NoH2;
        self.tls_reader = self.tls_conn.?.reader(&self.plain_read);
        self.tls_writer = self.tls_conn.?.writer(&self.plain_write);
        self.r = &self.tls_reader.interface;
        self.w = &self.tls_writer.interface;
        try self.initSession();
    }

    fn initSession(self: *TestClient) !void {
        var callbacks: ?*c.nghttp2_session_callbacks = null;
        _ = c.nghttp2_session_callbacks_new(&callbacks);
        defer c.nghttp2_session_callbacks_del(callbacks);
        c.nghttp2_session_callbacks_set_on_header_callback(callbacks, onHeader);
        c.nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, onData);
        c.nghttp2_session_callbacks_set_on_stream_close_callback(callbacks, onClose);
        c.nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks, onFrame);
        if (c.nghttp2_session_client_new(&self.session, callbacks, self) != 0) return error.Http2Init;
        if (c.nghttp2_submit_settings(self.session, c.NGHTTP2_FLAG_NONE, null, 0) != 0) return error.Http2Init;
    }

    fn deinit(self: *TestClient) void {
        var it = self.responses.valueIterator();
        while (it.next()) |r| {
            r.*.body.deinit(self.gpa);
            if (r.*.content_length) |v| self.gpa.free(v);
            if (r.*.trailer) |v| self.gpa.free(v);
            self.gpa.destroy(r.*);
        }
        self.responses.deinit(self.gpa);
        c.nghttp2_session_del(self.session);
        self.stream.close(self.io);
    }

    fn request(self: *TestClient, method: []const u8, path: []const u8, body: ?[]const u8) !i32 {
        return self.requestProtocol(method, path, null, body);
    }

    /// `request`, with a `:protocol` for an extended CONNECT (RFC 8441).
    fn requestProtocol(self: *TestClient, method: []const u8, path: []const u8, protocol: ?[]const u8, body: ?[]const u8) !i32 {
        const all = [_]c.nghttp2_nv{
            nv(":method", method),
            nv(":path", path),
            nv(":scheme", "http"),
            nv(":authority", "localhost"),
            nv(":protocol", protocol orelse ""),
        };
        const nva = if (protocol != null) all[0..] else all[0..4];
        const resp = try self.gpa.create(Resp);
        resp.* = .{ .send = body orelse "" };
        var provider: c.nghttp2_data_provider2 = .{ .source = .{ .ptr = resp }, .read_callback = provide };
        const id = c.nghttp2_submit_request2(self.session, null, nva.ptr, nva.len, if (body != null) &provider else null, resp);
        if (id < 0) return error.Http2Submit;
        try self.responses.put(self.gpa, id, resp);
        return id;
    }

    /// A GET with `extra` fields after the pseudo-headers, and no
    /// `:authority` when `authority` is null.
    fn requestWith(self: *TestClient, path: []const u8, authority: ?[]const u8, extra: []const c.nghttp2_nv) !i32 {
        var nva: [16]c.nghttp2_nv = undefined;
        nva[0] = nv(":method", "GET");
        nva[1] = nv(":path", path);
        nva[2] = nv(":scheme", "http");
        var n: usize = 3;
        if (authority) |a| {
            nva[n] = nv(":authority", a);
            n += 1;
        }
        for (extra) |f| {
            nva[n] = f;
            n += 1;
        }
        const resp = try self.gpa.create(Resp);
        resp.* = .{};
        const id = c.nghttp2_submit_request2(self.session, null, &nva, n, null, resp);
        if (id < 0) return error.Http2Submit;
        try self.responses.put(self.gpa, id, resp);
        return id;
    }

    fn get(self: *TestClient, id: i32) *Resp {
        return self.responses.get(id).?;
    }

    /// Sends what the session has, without waiting for anything.
    fn sendPending(self: *TestClient) !void {
        while (true) {
            var data: [*c]const u8 = undefined;
            const n = c.nghttp2_session_mem_send2(self.session, &data);
            if (n < 0) return error.Http2Send;
            if (n == 0) break;
            try self.w.writeAll(data[0..@intCast(n)]);
        }
        try self.w.flush();
    }

    /// Sends and receives until every submitted stream is closed.
    fn run(self: *TestClient) !void {
        while (true) {
            while (true) {
                var data: [*c]const u8 = undefined;
                const n = c.nghttp2_session_mem_send2(self.session, &data);
                if (n < 0) return error.Http2Send;
                if (n == 0) break;
                try self.w.writeAll(data[0..@intCast(n)]);
            }
            try self.w.flush();

            var all_closed = true;
            var it = self.responses.valueIterator();
            while (it.next()) |r| if (!r.*.closed) {
                all_closed = false;
            };
            if (all_closed) return;

            const bytes = try self.r.peekGreedy(1);
            const rv = c.nghttp2_session_mem_recv2(self.session, bytes.ptr, bytes.len);
            if (rv < 0) return error.Http2Recv;
            self.r.toss(@intCast(rv));
        }
    }

    fn nv(name: []const u8, value: []const u8) c.nghttp2_nv {
        return .{ .name = @constCast(name.ptr), .namelen = name.len, .value = @constCast(value.ptr), .valuelen = value.len, .flags = c.NGHTTP2_NV_FLAG_NONE };
    }

    fn respFor(session: ?*c.nghttp2_session, id: i32) ?*Resp {
        const ptr = c.nghttp2_session_get_stream_user_data(session, id) orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn onHeader(session: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, name: [*c]const u8, namelen: usize, value: [*c]const u8, valuelen: usize, _: u8, user_data: ?*anyopaque) callconv(.c) c_int {
        const self: *TestClient = @ptrCast(@alignCast(user_data.?));
        const resp = respFor(session, frame.*.hd.stream_id) orelse return 0;
        const n = name[0..namelen];
        const v = value[0..valuelen];
        if (frame.*.headers.cat == c.NGHTTP2_HCAT_HEADERS) {
            // Trailers: the second header block.
            if (std.mem.eql(u8, n, "x-done")) resp.trailer = self.gpa.dupe(u8, v) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
            return 0;
        }
        if (std.mem.eql(u8, n, ":status")) resp.status = std.fmt.parseInt(u16, v, 10) catch 0;
        if (std.mem.eql(u8, n, "content-length")) resp.content_length = self.gpa.dupe(u8, v) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
        if (std.mem.eql(u8, n, "date")) resp.has_date = true;
        return 0;
    }

    fn onData(session: ?*c.nghttp2_session, _: u8, id: i32, data: [*c]const u8, len: usize, user_data: ?*anyopaque) callconv(.c) c_int {
        const self: *TestClient = @ptrCast(@alignCast(user_data.?));
        const resp = respFor(session, id) orelse return 0;
        resp.body.appendSlice(self.gpa, data[0..len]) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
        return 0;
    }

    fn onFrame(_: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, user_data: ?*anyopaque) callconv(.c) c_int {
        const self: *TestClient = @ptrCast(@alignCast(user_data.?));
        if (frame.*.hd.type == c.NGHTTP2_DATA and frame.*.hd.length == 0 and frame.*.hd.flags & c.NGHTTP2_FLAG_END_STREAM != 0) self.empty_ends += 1;
        if (frame.*.hd.type == c.NGHTTP2_WINDOW_UPDATE and frame.*.hd.stream_id != 0) self.stream_window_updates += 1;
        if (frame.*.hd.type == c.NGHTTP2_GOAWAY and self.goaway_count < self.goaways.len) {
            self.goaways[self.goaway_count] = frame.*.goaway.last_stream_id;
            self.goaway_count += 1;
        }
        return 0;
    }

    /// Receives, sending nothing (the SETTINGS ACK the session owes stays
    /// queued), until a WINDOW_UPDATE for a stream has come.
    fn recvUntilStreamWindowUpdate(self: *TestClient) !void {
        while (self.stream_window_updates == 0) {
            const bytes = try self.r.peekGreedy(1);
            const rv = c.nghttp2_session_mem_recv2(self.session, bytes.ptr, bytes.len);
            if (rv < 0) return error.Http2Recv;
            self.r.toss(@intCast(rv));
        }
    }

    /// Keeps the connection going (answering PINGs and SETTINGS) until the
    /// server closes it.
    fn runUntilClosed(self: *TestClient) !void {
        while (true) {
            while (true) {
                var data: [*c]const u8 = undefined;
                const n = c.nghttp2_session_mem_send2(self.session, &data);
                if (n < 0) return error.Http2Send;
                if (n == 0) break;
                try self.w.writeAll(data[0..@intCast(n)]);
            }
            try self.w.flush();
            const bytes = self.r.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => return,
                else => |e| return e,
            };
            const rv = c.nghttp2_session_mem_recv2(self.session, bytes.ptr, bytes.len);
            if (rv < 0) return error.Http2Recv;
            self.r.toss(@intCast(rv));
        }
    }

    fn onClose(session: ?*c.nghttp2_session, id: i32, error_code: u32, user_data: ?*anyopaque) callconv(.c) c_int {
        const self: *TestClient = @ptrCast(@alignCast(user_data.?));
        const resp = respFor(session, id) orelse return 0;
        self.closes += 1;
        resp.close_seq = self.closes;
        resp.closed = true;
        resp.error_code = error_code;
        return 0;
    }

    fn provide(_: ?*c.nghttp2_session, _: i32, buf: [*c]u8, length: usize, flags: [*c]u32, source: [*c]c.nghttp2_data_source, _: ?*anyopaque) callconv(.c) c.nghttp2_ssize {
        const resp: *Resp = @ptrCast(@alignCast(source.*.ptr.?));
        const rest = resp.send[resp.sent..];
        const n = @min(rest.len, length);
        @memcpy(buf[0..n], rest[0..n]);
        resp.sent += n;
        if (resp.sent == resp.send.len) {
            if (resp.keep_open) {
                if (n == 0) return c.NGHTTP2_ERR_DEFERRED;
            } else flags.* |= c.NGHTTP2_DATA_FLAG_EOF;
        }
        return @intCast(n);
    }
};

const Handlers = struct {
    /// The cookie header, how many `accept` fields came, and the host.
    fn fields(req: *dusty.Request, res: *dusty.Response) !void {
        var accepts: usize = 0;
        var it = req.headers.iterator();
        while (it.next()) |e| {
            if (std.ascii.eqlIgnoreCase(e.key, "accept")) accepts += 1;
        }
        try res.print(.text, "cookie={s} accepts={d} host={s}", .{ req.headers.get("cookie") orelse "-", accepts, req.host() orelse "-" });
    }
    fn hello(_: *dusty.Request, res: *dusty.Response) !void {
        try res.print(.text, "hello", .{});
    }
    fn user(req: *dusty.Request, res: *dusty.Response) !void {
        try std.testing.expectEqual(@as(u8, 2), req.version_major);
        try res.print(.text, "user {s}", .{req.params.get("id").?});
    }
    fn echo(req: *dusty.Request, res: *dusty.Response) !void {
        var in_buf: [4096]u8 = undefined;
        var body = try req.reader(&in_buf);
        var out_buf: [4096]u8 = undefined;
        var out = try res.stream(&out_buf);
        _ = body.interface.streamRemaining(&out.interface) catch |err| switch (err) {
            error.ReadFailed => return body.err orelse error.Unexpected,
            error.WriteFailed => return out.err orelse error.Unexpected,
        };
        try out.end();
    }
    fn trailers(_: *dusty.Request, res: *dusty.Response) !void {
        res.body = "with trailers";
        try res.trailer("x-done", "yes");
    }
    fn ignoreBody(_: *dusty.Request, res: *dusty.Response) !void {
        res.body = "not reading that";
    }
    fn who(req: *dusty.Request, res: *dusty.Response) !void {
        try res.print(.text, "{f} secure={}", .{ req.remote_address, req.secure });
    }
    fn slow(req: *dusty.Request, res: *dusty.Response) !void {
        try req.io.sleep(.fromMilliseconds(300), .awake);
        res.body = "slow but whole";
    }
    fn slower(req: *dusty.Request, res: *dusty.Response) !void {
        try req.io.sleep(.fromMilliseconds(900), .awake);
        res.body = "slower but whole";
    }
    /// A streamed body far past the client's 64 KiB stream window.
    fn big(_: *dusty.Request, res: *dusty.Response) !void {
        var buf: [4096]u8 = undefined;
        var out = try res.stream(&buf);
        for (0..big_len / 1000) |i| try out.interface.print("{d:0>999}\n", .{i});
        try out.end();
    }
    const big_len = 1000 * 1000;
    /// Reads the body only after a full window of it has queued up, and
    /// answers with its length and a checksum.
    fn late(req: *dusty.Request, res: *dusty.Response) !void {
        try req.io.sleep(.fromMilliseconds(100), .awake);
        return sum(req, res);
    }
    /// `sum`, as a handler starved of CPU at the worst moment: it reads
    /// exactly `stall_credit` bytes, half the window its first read raised
    /// it to, which returns credit for all of them, then stops while the
    /// peer fills the whole window again, then reads the rest.
    fn stall(req: *dusty.Request, res: *dusty.Response) !void {
        const raw = req.body_source.?.reader;
        var hash: std.hash.Wyhash = .init(0);
        var n: usize = 0;
        while (n < stall_credit) n += try takeBody(raw, &hash, stall_credit - n);
        try req.io.sleep(.fromMilliseconds(300), .awake);
        while (true) n += takeBody(raw, &hash, 4096) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        try res.print(.text, "{d} {x}", .{ n, hash.final() });
    }
    const stall_credit = 512 * 1024;
    /// At most `limit` body bytes, straight from the stream: each read is
    /// what the engine credits back.
    fn takeBody(raw: *std.Io.Reader, hash: *std.hash.Wyhash, limit: usize) !usize {
        var scratch: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&scratch);
        const n = try raw.stream(&w, .limited(@min(limit, scratch.len)));
        hash.update(scratch[0..n]);
        return n;
    }
    /// The body's length and checksum.
    fn sum(req: *dusty.Request, res: *dusty.Response) !void {
        var in_buf: [4096]u8 = undefined;
        var body = try req.reader(&in_buf);
        var hash: std.hash.Wyhash = .init(0);
        var n: usize = 0;
        while (true) {
            const chunk = body.interface.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => return body.err orelse error.Unexpected,
            };
            hash.update(chunk);
            n += chunk.len;
            body.interface.toss(chunk.len);
        }
        try res.print(.text, "{d} {x}", .{ n, hash.final() });
    }
};

const Fixture = struct {
    server: dusty.Server(void),
    future: std.Io.Future(anyerror!void) = undefined,

    fn start(self: *Fixture, io: std.Io) !void {
        self.server = dusty.Server(void).init(std.testing.allocator, io, .{
            .listeners = &.{.{ .address = loopback_addr, .http2_prior_knowledge = true }},
        }, {});
        self.server.router.get("/hello", Handlers.hello);
        self.server.router.get("/fields", Handlers.fields);
        self.server.router.get("/users/:id", Handlers.user);
        self.server.router.post("/echo", Handlers.echo);
        self.server.router.get("/trailers", Handlers.trailers);
        self.server.router.post("/ignore", Handlers.ignoreBody);
        self.server.router.get("/slow", Handlers.slow);
        self.server.router.get("/slower", Handlers.slower);
        self.server.router.post("/late", Handlers.late);
        self.server.router.post("/stall", Handlers.stall);
        // The same handlers on routes that promise not to wait, which run
        // on the connection's reader when their request comes whole.
        self.server.router.addRouteWith(.get, "/nw/hello", Handlers.hello, .{ .no_wait = true });
        self.server.router.addRouteWith(.get, "/nw/users/:id", Handlers.user, .{ .no_wait = true });
        self.server.router.addRouteWith(.get, "/nw/trailers", Handlers.trailers, .{ .no_wait = true });
        self.server.router.addRouteWith(.get, "/nw/big", Handlers.big, .{ .no_wait = true });
        self.server.router.addRouteWith(.post, "/nw/echo", Handlers.echo, .{ .no_wait = true });
        self.server.router.addRouteWith(.get, "/nw/slow", Handlers.slow, .{ .no_wait = true });
        self.server.router.addRouteWith(.post, "/nw/sum", Handlers.sum, .{ .no_wait = true });
        self.future = try io.concurrent(run, .{&self.server});
        try self.server.waitReady(io);
    }

    fn run(s: *dusty.Server(void)) anyerror!void {
        try s.run();
    }

    fn stop(self: *Fixture, io: std.Io) void {
        self.future.cancel(io) catch {};
        self.server.deinit();
    }
};

test "HTTP/2: GET over prior-knowledge h2c reaches the router" {
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    const ok = try client.request("GET", "/hello", null);
    const head = try client.request("HEAD", "/hello", null);
    const missing = try client.request("GET", "/nope", null);
    try client.run();

    try std.testing.expectEqual(@as(u16, 200), client.get(ok).status);
    try std.testing.expectEqualStrings("hello", client.get(ok).body.items);
    try std.testing.expect(client.get(ok).has_date);
    try std.testing.expectEqual(@as(u16, 200), client.get(head).status);
    try std.testing.expectEqualStrings("5", client.get(head).content_length.?);
    try std.testing.expectEqualStrings("", client.get(head).body.items);
    try std.testing.expectEqual(@as(u16, 404), client.get(missing).status);
}

test "HTTP/2: a whole body ends on its DATA frame, an empty one on HEADERS" {
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    const ok = try client.request("GET", "/hello", null);
    const head = try client.request("HEAD", "/hello", null);
    const inline_ok = try client.request("GET", "/nw/hello", null);
    try client.run();
    try std.testing.expectEqualStrings("hello", client.get(ok).body.items);
    try std.testing.expectEqualStrings("hello", client.get(inline_ok).body.items);
    try std.testing.expectEqual(@as(u16, 200), client.get(head).status);
    try std.testing.expectEqual(@as(usize, 0), client.empty_ends);
}

test "HTTP/2: no_wait routes answer from the reader, beside tasks, past the window" {
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);
    try std.testing.expect(fx.server.router.has_no_wait);

    const body = try std.testing.allocator.alloc(u8, 300 * 1024 + 7);
    defer std.testing.allocator.free(body);
    for (body, 0..) |*b, i| b.* = @truncate(i *% 13);

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    var ids: [16]i32 = undefined;
    var paths: [16][16]u8 = undefined;
    for (&ids, 0..) |*id, i| {
        const path = try std.fmt.bufPrint(&paths[i], "/nw/users/{d}", .{i});
        id.* = try client.request("GET", path, null);
    }
    const task = try client.request("GET", "/users/x", null);
    const trailers = try client.request("GET", "/nw/trailers", null);
    // Streamed from the reader far past the client's stream window: the
    // reader must not wait for the writer, which waits for WINDOW_UPDATEs
    // only the reader takes in.
    const big = try client.request("GET", "/nw/big", null);
    // With a body: not whole on its HEADERS, so it gets a task.
    const echoed = try client.request("POST", "/nw/echo", body);
    const head = try client.request("HEAD", "/nw/hello", null);
    const query = try client.request("GET", "/nw/hello?x=1", null);
    try client.run();

    for (ids, 0..) |id, i| {
        var expect: [16]u8 = undefined;
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expect, "user {d}", .{i}), client.get(id).body.items);
    }
    try std.testing.expectEqualStrings("user x", client.get(task).body.items);
    try std.testing.expectEqualStrings("with trailers", client.get(trailers).body.items);
    try std.testing.expectEqualStrings("yes", client.get(trailers).trailer.?);
    try std.testing.expectEqual(@as(usize, Handlers.big_len), client.get(big).body.items.len);
    try std.testing.expect(std.mem.endsWith(u8, client.get(big).body.items, "999\n"));
    try std.testing.expect(std.mem.eql(u8, body, client.get(echoed).body.items));
    try std.testing.expectEqualStrings("5", client.get(head).content_length.?);
    try std.testing.expectEqualStrings("", client.get(head).body.items);
    try std.testing.expectEqualStrings("hello", client.get(query).body.items);
}

test "HTTP/2: a no_wait request with a body runs inline when it came whole, else on a task" {
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);

    const body = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024 + 5);
    defer std.testing.allocator.free(body);
    for (body, 0..) |*b, i| b.* = @truncate(i *% 77 +% (i >> 13));

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    var ids: [8]i32 = undefined;
    for (&ids, 0..) |*id, i| id.* = try client.request("POST", "/nw/sum", body[0 .. i * 100]);
    // Past the stream window: it cannot come whole before someone reads.
    const big = try client.request("POST", "/nw/sum", body);
    try client.run();
    var expect: [64]u8 = undefined;
    for (ids, 0..) |id, i| {
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expect, "{d} {x}", .{ i * 100, std.hash.Wyhash.hash(0, body[0 .. i * 100]) }), client.get(id).body.items);
    }
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expect, "{d} {x}", .{ body.len, std.hash.Wyhash.hash(0, body) }), client.get(big).body.items);

    // Reset with its body half sent: let go, and the connection carries on.
    const cut = try client.request("POST", "/nw/sum", body[0..1000]);
    client.get(cut).keep_open = true;
    try client.sendPending();
    try io.sleep(.fromMilliseconds(50), .awake);
    _ = c.nghttp2_submit_rst_stream(client.session, c.NGHTTP2_FLAG_NONE, cut, c.NGHTTP2_CANCEL);
    const after = try client.request("POST", "/nw/sum", body[0..10]);
    try client.run();
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expect, "{d} {x}", .{ 10, std.hash.Wyhash.hash(0, body[0..10]) }), client.get(after).body.items);
}

test "HTTP/2: a body window raised before the client acknowledged SETTINGS never outgrows its buffer" {
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);

    const body = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024 + 5);
    defer std.testing.allocator.free(body);
    for (body, 0..) |*b, i| b.* = @truncate(i *% 31 +% (i >> 11));

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    const id = try client.request("POST", "/stall", body);
    // The preface, SETTINGS, the head and a default window of the body,
    // then nothing until the handler's first read has raised the stream's
    // window: the client's ACK of the server's SETTINGS (whose initial
    // window differs from the default) arrives after the raise.
    try client.sendPending();
    try client.recvUntilStreamWindowUpdate();
    try client.run();
    var expect: [64]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expect, "{d} {x}", .{ body.len, std.hash.Wyhash.hash(0, body) }), client.get(id).body.items);
}

test "HTTP/2: a no_wait handler that waits anyway still answers, holding up its connection" {
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    const slow = try client.request("GET", "/nw/slow", null);
    const hello = try client.request("GET", "/nw/hello", null);
    try client.run();
    try std.testing.expectEqualStrings("slow but whole", client.get(slow).body.items);
    try std.testing.expectEqualStrings("hello", client.get(hello).body.items);
    // Run in turn on the reader, so the quick one waited for the slow one.
    try std.testing.expect(client.get(slow).close_seq < client.get(hello).close_seq);

    // On tasks, the quick one does not wait.
    const slow_task = try client.request("GET", "/slow", null);
    const hello_task = try client.request("GET", "/hello", null);
    try client.run();
    try std.testing.expect(client.get(hello_task).close_seq < client.get(slow_task).close_seq);
}

test "HTTP/2: many streams multiplexed on one connection" {
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    var ids: [32]i32 = undefined;
    var paths: [32][16]u8 = undefined;
    for (&ids, 0..) |*id, i| {
        const path = try std.fmt.bufPrint(&paths[i], "/users/{d}", .{i});
        id.* = try client.request("GET", path, null);
    }
    try client.run();
    for (ids, 0..) |id, i| {
        var expect: [16]u8 = undefined;
        try std.testing.expectEqual(@as(u16, 200), client.get(id).status);
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expect, "user {d}", .{i}), client.get(id).body.items);
    }
}

test "HTTP/2: a request body larger than the windows is echoed back whole" {
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);

    const body = try std.testing.allocator.alloc(u8, 1024 * 1024 + 123);
    defer std.testing.allocator.free(body);
    for (body, 0..) |*b, i| b.* = @truncate(i *% 31 +% (i >> 11));

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    const id = try client.request("POST", "/echo", body);
    try client.run();
    try std.testing.expectEqual(@as(u16, 200), client.get(id).status);
    try std.testing.expectEqual(body.len, client.get(id).body.items.len);
    try std.testing.expect(std.mem.eql(u8, body, client.get(id).body.items));
}

test "HTTP/2: a body read late moves to the bigger window whole and in order" {
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);

    // A stream window's worth queues before the handler reads; the rest
    // comes through the window the first read raises.
    const body = try std.testing.allocator.alloc(u8, 3 * 1024 * 1024 + 17);
    defer std.testing.allocator.free(body);
    for (body, 0..) |*b, i| b.* = @truncate(i *% 131 +% (i >> 9));

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    const a = try client.request("POST", "/late", body);
    const b = try client.request("POST", "/late", body[0 .. 70 * 1024]);
    try client.run();
    var expect: [64]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expect, "{d} {x}", .{ body.len, std.hash.Wyhash.hash(0, body) }), client.get(a).body.items);
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expect, "{d} {x}", .{ 70 * 1024, std.hash.Wyhash.hash(0, body[0 .. 70 * 1024]) }), client.get(b).body.items);
}

test "HTTP/2: trailers follow the body" {
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    const id = try client.request("GET", "/trailers", null);
    try client.run();
    try std.testing.expectEqualStrings("with trailers", client.get(id).body.items);
    try std.testing.expectEqualStrings("yes", client.get(id).trailer.?);
}

test "HTTP/2: a small unread request body is read and dropped, and the stream ends cleanly" {
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);

    const body = try std.testing.allocator.alloc(u8, 20 * 1024);
    defer std.testing.allocator.free(body);
    @memset(body, 'y');

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    const id = try client.request("POST", "/ignore", body);
    try client.run();
    try std.testing.expectEqual(@as(u16, 200), client.get(id).status);
    try std.testing.expectEqualStrings("not reading that", client.get(id).body.items);
    try std.testing.expectEqual(@as(u32, c.NGHTTP2_NO_ERROR), client.get(id).error_code);
}

test "HTTP/2: an unread request body gets the whole response, then RST_STREAM(NO_ERROR)" {
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);

    const body = try std.testing.allocator.alloc(u8, 300 * 1024);
    defer std.testing.allocator.free(body);
    @memset(body, 'x');

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    const id = try client.request("POST", "/ignore", body);
    try client.run();
    try std.testing.expectEqual(@as(u16, 200), client.get(id).status);
    try std.testing.expectEqualStrings("not reading that", client.get(id).body.items);
    try std.testing.expectEqual(@as(u32, c.NGHTTP2_NO_ERROR), client.get(id).error_code);
}

test "HTTP/2: HTTP/1.1 still works on a prior-knowledge listener" {
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);

    var client = dusty.Client.init(std.testing.allocator, io, .{});
    defer client.deinit();
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/hello", .{fx.server.address.ip.getPort()});
    var response = try client.fetch(url, .{});
    defer response.deinit();
    try std.testing.expectEqual(.ok, response.status());
    try std.testing.expectEqualStrings("hello", (try response.body()).?);
}

test "HTTP/2: over TLS, chosen through ALPN" {
    if (!build_options.use_tls) return error.SkipZigTest;
    const io = std.testing.io;
    // The self-signed test certificate made at build time, as in client_test.zig.
    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .listeners = &.{.{ .address = loopback_addr, .tls = .{
            .cert_path = "certs/cert.pem",
            .key_path = "certs/key.pem",
            .alpn_protocols = &.{ "h2", "http/1.1" },
        } }},
    }, {});
    defer server.deinit();
    server.router.get("/hello", Handlers.hello);
    server.router.post("/echo", Handlers.echo);
    var future = try io.concurrent(Fixture.run, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);

    const ca: dusty.TlsCa = .{ .file = .{ .path = "certs/cert.pem" } };
    var bundle = try ca.load(std.testing.allocator, io);
    defer bundle.deinit(std.testing.allocator);

    const body = try std.testing.allocator.alloc(u8, 200 * 1024);
    defer std.testing.allocator.free(body);
    for (body, 0..) |*b, i| b.* = @truncate(i *% 7);

    var client: TestClient = undefined;
    try client.initTls(std.testing.allocator, io, server.address.ip, &bundle);
    defer client.deinit();
    const hello = try client.request("GET", "/hello", null);
    const echoed = try client.request("POST", "/echo", body);
    try client.run();
    try std.testing.expectEqualStrings("hello", client.get(hello).body.items);
    try std.testing.expect(std.mem.eql(u8, body, client.get(echoed).body.items));
}

/// Counts allocations through it, for the hot-path test below.
const CountingAllocator = struct {
    inner: std.mem.Allocator,
    count: std.atomic.Value(usize) = .init(0),

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        _ = self.count.fetchAdd(1, .monotonic);
        return self.inner.rawAlloc(len, alignment, ra);
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.inner.rawResize(memory, alignment, new_len, ra);
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        _ = self.count.fetchAdd(1, .monotonic);
        return self.inner.rawRemap(memory, alignment, new_len, ra);
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.inner.rawFree(memory, alignment, ra);
    }
};

test "HTTP/2: a warm connection serves requests without allocating" {
    const io = std.testing.io;
    var counting: CountingAllocator = .{ .inner = std.testing.allocator };
    var server = dusty.Server(void).init(counting.allocator(), io, .{
        .listeners = &.{.{ .address = loopback_addr, .http2_prior_knowledge = true }},
    }, {});
    defer server.deinit();
    server.router.get("/users/:id", Handlers.user);
    var future = try io.concurrent(Fixture.run, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, server.address.ip);
    defer client.deinit();
    // Warm up: the stream pool, arenas and maps grow to what a request needs.
    for (0..5) |_| {
        _ = try client.request("GET", "/users/1", null);
        try client.run();
        try awaitStreamsFreed(&server, io);
    }
    const before = counting.count.load(.monotonic);
    for (0..20) |_| {
        const id = try client.request("GET", "/users/2", null);
        try client.run();
        try std.testing.expectEqualStrings("user 2", client.get(id).body.items);
        try awaitStreamsFreed(&server, io);
    }
    try std.testing.expectEqual(before, counting.count.load(.monotonic));
}

/// Waits until the server has freed every stream. The response can reach
/// the client before its handler's task has let go of the stream (each
/// task is a thread of its own under std.testing.io), and a request sent
/// meanwhile rightly takes a second stream, which the pool then keeps:
/// one request at a time is what the warm-path test measures.
fn awaitStreamsFreed(server: *dusty.Server(void), io: std.Io) !void {
    for (0..5000) |_| {
        if (server.busy.load(.acquire).count == 0) return;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.Timeout;
}

fn stopFixture(f: *Fixture, io: std.Io) void {
    f.future.cancel(io) catch {};
}

test "HTTP/2: a drain closes an idle connection with GOAWAY at once" {
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.server.deinit();

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    const id = try client.request("GET", "/hello", null);
    try client.run();
    try std.testing.expectEqual(@as(u16, 200), client.get(id).status);

    const started: std.Io.Clock.Timestamp = .now(io, .awake);
    var stopper = try io.concurrent(stopFixture, .{ &fx, io });
    defer stopper.await(io);

    // An nghttp2 client with nothing open takes the GOAWAY notice as the
    // end and closes; the server's side ends with it, well before the
    // notice's one-second fallback.
    try client.runUntilClosed();
    try std.testing.expect(client.goaway_count >= 1);
    try std.testing.expectEqual(@as(i32, std.math.maxInt(i32)), client.goaways[0]);
    try std.testing.expect(started.durationTo(.now(io, .awake)).raw.toMilliseconds() < 900);
}

test "HTTP/2: a drain with a stream in flight sends a two-phase GOAWAY and finishes the stream" {
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.server.deinit();

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    const warm = try client.request("GET", "/hello", null);
    try client.run();
    try std.testing.expectEqual(@as(u16, 200), client.get(warm).status);

    // Start the slow request, then shut down while it runs.
    const id = try client.request("GET", "/slow", null);
    while (true) {
        var data: [*c]const u8 = undefined;
        const n = c.nghttp2_session_mem_send2(client.session, &data);
        if (n <= 0) break;
        try client.w.writeAll(data[0..@intCast(n)]);
    }
    try client.w.flush();
    try io.sleep(.fromMilliseconds(100), .awake);
    var stopper = try io.concurrent(stopFixture, .{ &fx, io });
    defer stopper.await(io);

    try client.runUntilClosed();
    // The notice (the largest stream ID), answered with the PING ack,
    // then the final GOAWAY naming the slow stream as the last one taken.
    try std.testing.expectEqual(@as(usize, 2), client.goaway_count);
    try std.testing.expectEqual(@as(i32, std.math.maxInt(i32)), client.goaways[0]);
    try std.testing.expectEqual(id, client.goaways[1]);
    const resp = client.get(id);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("slow but whole", resp.body.items);
}

/// Holds every write of the HTTP/2 writer for 200 ms (`h2.test_before_flush`).
fn holdFlush(io: std.Io) std.Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(200), .awake);
}

test "HTTP/2: a drain waits for a response that is taken from the session but not yet written" {
    // nghttp2 closes a stream when the writer takes its last frame, before
    // the write. The stream's count in the in-flight requests must last
    // until that write is done, or the drain sees zero and cancels the
    // connection with the response still in the writer's buffer. Every
    // write is held 200 ms, which makes that window 200 ms wide; the drain's
    // two GOAWAYs are out by about 500 ms, the response comes at 900.
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.server.deinit();

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    const warm = try client.request("GET", "/hello", null);
    try client.run();
    try std.testing.expectEqual(@as(u16, 200), client.get(warm).status);

    h2.test_before_flush = holdFlush;
    defer h2.test_before_flush = null;
    const id = try client.request("GET", "/slower", null);
    try client.sendPending();
    try io.sleep(.fromMilliseconds(100), .awake);
    var stopper = try io.concurrent(stopFixture, .{ &fx, io });
    defer stopper.await(io);

    try client.runUntilClosed();
    const resp = client.get(id);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("slower but whole", resp.body.items);
}

test "HTTP/2: a PROXY protocol header ahead of TLS names the client of an h2 stream" {
    if (!build_options.use_tls) return error.SkipZigTest;
    const io = std.testing.io;
    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .listeners = &.{.{ .address = loopback_addr, .proxy_protocol = true, .tls = .{
            .cert_path = "certs/cert.pem",
            .key_path = "certs/key.pem",
            .alpn_protocols = &.{ "h2", "http/1.1" },
        } }},
    }, {});
    defer server.deinit();
    server.router.get("/who", Handlers.who);
    var future = try io.concurrent(Fixture.run, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);

    const ca: dusty.TlsCa = .{ .file = .{ .path = "certs/cert.pem" } };
    var bundle = try ca.load(std.testing.allocator, io);
    defer bundle.deinit(std.testing.allocator);

    // The header is read to its last byte and no further: the ClientHello
    // right behind it still reaches the handshake whole.
    var client: TestClient = undefined;
    try client.initTlsAfter(std.testing.allocator, io, server.address.ip, &bundle, "PROXY TCP4 192.0.2.44 198.51.100.2 40000 443\r\n");
    defer client.deinit();
    const id = try client.request("GET", "/who", null);
    try client.run();
    try std.testing.expectEqualStrings("192.0.2.44:40000 secure=true", client.get(id).body.items);
}

test "HTTP/2: an extended CONNECT (RFC 8441) reaches a GET route with Request.protocol set" {
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);
    fx.server.router.get("/tunnel", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            try std.testing.expectEqualStrings("websocket", req.protocol.?);
            res.compress = true; // never applies to a tunnel
            try Handlers.echo(req, res);
        }
    }.handle);

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    // The server's SETTINGS (with ENABLE_CONNECT_PROTOCOL) must be in before
    // nghttp2 lets a client send :protocol.
    const warm = try client.request("GET", "/hello", null);
    try client.run();
    try std.testing.expectEqual(@as(u16, 200), client.get(warm).status);
    try std.testing.expectEqual(@as(u32, 1), c.nghttp2_session_get_remote_settings(client.session, c.NGHTTP2_SETTINGS_ENABLE_CONNECT_PROTOCOL));

    const id = try client.requestProtocol("CONNECT", "/tunnel", "websocket", "tunnelled bytes");
    try client.run();
    try std.testing.expectEqual(@as(u16, 200), client.get(id).status);
    try std.testing.expectEqualStrings("tunnelled bytes", client.get(id).body.items);
}

test "HTTP/2: a client that half-closes still gets the responses in flight" {
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    const id = try client.request("GET", "/slow", null);
    while (true) {
        var data: [*c]const u8 = undefined;
        const n = c.nghttp2_session_mem_send2(client.session, &data);
        if (n <= 0) break;
        try client.w.writeAll(data[0..@intCast(n)]);
    }
    try client.w.flush();
    // Done sending: the server reads EOF while /slow is still sleeping.
    try client.stream.shutdown(io, .send);
    // Nothing more goes out from here; read until the response is in.
    while (!client.get(id).closed) {
        const bytes = try client.r.peekGreedy(1);
        const rv = c.nghttp2_session_mem_recv2(client.session, bytes.ptr, bytes.len);
        if (rv < 0) return error.Http2Recv;
        client.r.toss(@intCast(rv));
    }
    try std.testing.expectEqual(@as(u16, 200), client.get(id).status);
    try std.testing.expectEqualStrings("slow but whole", client.get(id).body.items);
}

test "HTTP/2: a finished tunnel is reset even when the peer keeps its side open" {
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);
    fx.server.router.get("/brief", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            res.body = "done";
        }
    }.handle);

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    const warm = try client.request("GET", "/hello", null);
    try client.run();
    try std.testing.expectEqual(@as(u16, 200), client.get(warm).status);
    const id = try client.requestProtocol("CONNECT", "/brief", "websocket", "x");
    client.get(id).keep_open = true;
    // Returns once the stream closes: the response ends it from the
    // server's side, and an RST_STREAM(NO_ERROR) from the client's.
    try client.run();
    try std.testing.expectEqualStrings("done", client.get(id).body.items);
    try std.testing.expectEqual(@as(u32, c.NGHTTP2_NO_ERROR), client.get(id).error_code);
}

/// A handler that waits up to 10 s for its client to leave. On zio the
/// wait itself is canceled; elsewhere `peerGone` tells.
const Waiter = struct {
    var done: std.atomic.Value(bool) = .init(false);

    fn handle(req: *dusty.Request, res: *dusty.Response) !void {
        defer done.store(true, .release);
        for (0..200) |_| {
            try req.io.sleep(.fromMilliseconds(50), .awake);
            if (res.peerGone()) return;
        }
        res.body = "nobody asked";
    }

    /// Sends what the client has queued (the request) and waits until the
    /// handler is surely running.
    fn start(client: *TestClient, io: std.Io) !void {
        done.store(false, .release);
        while (true) {
            var data: [*c]const u8 = undefined;
            const n = c.nghttp2_session_mem_send2(client.session, &data);
            if (n <= 0) break;
            try client.w.writeAll(data[0..@intCast(n)]);
        }
        try client.w.flush();
        try io.sleep(.fromMilliseconds(100), .awake);
        try std.testing.expect(!done.load(.acquire));
    }

    fn expectDoneWithin(io: std.Io, since: std.Io.Clock.Timestamp, ms: i64) !void {
        while (!done.load(.acquire)) {
            try std.testing.expect(since.durationTo(.now(io, .awake)).raw.toMilliseconds() < ms);
            try io.sleep(.fromMilliseconds(10), .awake);
        }
    }
};

test "HTTP/2: a handler is let go when the client resets its stream, and the connection carries on" {
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);
    fx.server.router.get("/wait", Waiter.handle);

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    const id = try client.request("GET", "/wait", null);
    try Waiter.start(&client, io);

    const reset_at: std.Io.Clock.Timestamp = .now(io, .awake);
    _ = c.nghttp2_submit_rst_stream(client.session, c.NGHTTP2_FLAG_NONE, id, c.NGHTTP2_CANCEL);
    try client.run();
    try std.testing.expectEqual(@as(u32, c.NGHTTP2_CANCEL), client.get(id).error_code);
    try Waiter.expectDoneWithin(io, reset_at, 2000);

    // The same connection still serves.
    const next = try client.request("GET", "/hello", null);
    try client.run();
    try std.testing.expectEqualStrings("hello", client.get(next).body.items);
}

test "HTTP/2: Response.abort resets the stream, and the connection carries on" {
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);
    fx.server.router.get("/abort", struct {
        fn handle(_: *dusty.Request, res: *dusty.Response) !void {
            var buf: [64]u8 = undefined;
            var w = try res.stream(&buf);
            try w.interface.writeAll("[1,");
            try w.interface.flush();
            return res.abort();
        }
    }.handle);

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    const id = try client.request("GET", "/abort", null);
    try client.run();
    try std.testing.expectEqual(@as(u32, c.NGHTTP2_CANCEL), client.get(id).error_code);

    const next = try client.request("GET", "/hello", null);
    try client.run();
    try std.testing.expectEqualStrings("hello", client.get(next).body.items);
}

test "HTTP/2: a handler is let go when the client closes the connection" {
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);
    fx.server.router.get("/wait", Waiter.handle);

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    _ = try client.request("GET", "/wait", null);
    try Waiter.start(&client, io);
    // The request is whole, so the end of the connection could be a
    // half-close: the server learns otherwise from its probe's failure.
    const closed_at: std.Io.Clock.Timestamp = .now(io, .awake);
    client.deinit();
    try Waiter.expectDoneWithin(io, closed_at, 3000);
}

test "HTTP/2: cookie crumbs are joined with \"; \" and other repeated fields kept" {
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    const id = try client.requestWith("/fields", "localhost", &.{
        TestClient.nv("cookie", "a=1"),
        TestClient.nv("accept", "text/html"),
        TestClient.nv("cookie", "anole_session=x"),
        TestClient.nv("accept", "application/json"),
        TestClient.nv("cookie", "c=3"),
    });
    try client.run();
    try std.testing.expectEqual(@as(u16, 200), client.get(id).status);
    try std.testing.expectEqualStrings("cookie=a=1; anole_session=x; c=3 accepts=2 host=localhost", client.get(id).body.items);
}

test "HTTP/2: :authority is the host; a host field that differs from it is refused" {
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    const same = try client.requestWith("/fields", "example.com", &.{TestClient.nv("host", "example.com")});
    const differs = try client.requestWith("/fields", "example.com", &.{TestClient.nv("host", "evil.example")});
    const host_only = try client.requestWith("/fields", null, &.{TestClient.nv("host", "example.org")});
    const two_hosts = try client.requestWith("/fields", null, &.{ TestClient.nv("host", "example.org"), TestClient.nv("host", "evil.example") });
    try client.run();
    try std.testing.expectEqual(@as(u16, 200), client.get(same).status);
    try std.testing.expectEqualStrings("cookie=- accepts=0 host=example.com", client.get(same).body.items);
    try std.testing.expectEqual(@as(u16, 400), client.get(differs).status);
    try std.testing.expectEqual(@as(u16, 200), client.get(host_only).status);
    try std.testing.expectEqualStrings("cookie=- accepts=0 host=example.org", client.get(host_only).body.items);
    // Two host fields: nghttp2 refuses the stream itself.
    try std.testing.expectEqual(@as(u16, 0), client.get(two_hosts).status);
    try std.testing.expectEqual(@as(u32, c.NGHTTP2_PROTOCOL_ERROR), client.get(two_hosts).error_code);
}
