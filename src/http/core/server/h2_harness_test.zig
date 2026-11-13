// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

//! Shared pieces of the HTTP/2 engine tests: the nghttp2 test client, the
//! handlers, the fixture, and the list of engines the behaviour tests run on.
const std = @import("std");
const dusty = @import("../root.zig");
const c = @import("nghttp2");
const build_options = @import("build_options");
const tls = @import("tls");
const wait = @import("anole_test_wait");
const test_socket = @import("test_socket.zig");

pub const loopback_addr: dusty.Address = .{ .ip = .{ .ip4 = .loopback(0) } };

/// RFC 9113 section 3.4: what a prior-knowledge client sends first.
pub const preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

/// The engines the behaviour tests (h2_test.zig) run on; one place to add
/// the next one.
pub const Engine = enum { anole, nghttp2 };

pub const engines = [_]Engine{ .anole, .nghttp2 };

/// What a behaviour test may know about an engine: the server type with
/// that engine, its module for the optional test probes (read under
/// `@hasDecl`; a test whose probe is missing skips visibly), and which
/// policy checks hold for it.
pub fn Desc(comptime e: Engine) type {
    return switch (e) {
        // The engine that serves (h2/server.zig).
        .anole => struct {
            pub const mod = @import("../h2/server.zig");
            pub fn Server(comptime Ctx: type) type {
                return dusty.Server(Ctx);
            }
            /// The server's registry of this engine's connections.
            pub const registry = "h2_conns";
            /// Picks this engine for the server's next connections.
            pub fn select(s: anytype) void {
                if (@TypeOf(s.test_h2_engine) != void) s.test_h2_engine = .anole;
            }
            /// It keeps what a burst grew to, so a burst queueing more than
            /// any before it allocates (INTENTIONAL.md, the server engine 6);
            /// its warm path is h2/server_test.zig's.
            pub const warm_zero_alloc = false;
            /// Its half-close probe (a PING) is the sync point; there is no
            /// `test_after_peer_end`.
            pub const half_close_probe = true;
        },
        // Until M6.
        .nghttp2 => struct {
            pub const mod = @import("h2_nghttp2.zig");
            pub fn Server(comptime Ctx: type) type {
                return dusty.Server(Ctx);
            }
            pub const registry = "h2_conns_nghttp2";
            pub fn select(s: anytype) void {
                if (@TypeOf(s.test_h2_engine) != void) s.test_h2_engine = .nghttp2;
            }
            /// A warm connection serves requests without allocating.
            pub const warm_zero_alloc = true;
            pub const half_close_probe = false;
        },
    };
}

/// A blocking HTTP/2 client over one connection, for tests: submit
/// requests, then `run` until every stream is closed. Every read from the
/// socket has `wait.deadline()` (`test_socket.DeadlineReader`), so a
/// server that stops answering fails the test instead of hanging it.
pub const TestClient = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    read_buf: [16 * 1024 + 1024]u8 = undefined,
    write_buf: [16 * 1024 + 1024]u8 = undefined,
    reader: test_socket.DeadlineReader = undefined,
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
    /// The error code of the last GOAWAY received.
    goaway_error: u32 = 0,
    /// DATA frames received with no payload and END_STREAM: an end that
    /// could have gone on the frame before it.
    empty_ends: usize = 0,
    closes: usize = 0,
    /// WINDOW_UPDATE frames received for a stream (not the connection).
    stream_window_updates: usize = 0,
    /// PING ACKs received, and PINGs.
    ping_acks: usize = 0,
    pings: usize = 0,

    pub const Resp = struct {
        status: u16 = 0,
        content_length: ?[]u8 = null,
        has_date: bool = false,
        body: std.ArrayList(u8) = .empty,
        trailer: ?[]u8 = null,
        closed: bool = false,
        /// When it closed: 1 for the first stream of the client to close.
        close_seq: usize = 0,
        error_code: u32 = 0,
        /// RST_STREAM frames received for the stream, and how much of the
        /// body had come when the first one did.
        rsts: usize = 0,
        body_at_rst: usize = 0,
        /// The request body to send, if any.
        send: []const u8 = "",
        /// How much of `send` has gone to the session. Read by a test's
        /// helper thread (`SentGate`).
        sent: usize = 0,
        /// Never end the request side (a tunnel the peer keeps open).
        keep_open: bool = false,
        /// The server's END_STREAM came: the response is whole.
        answered: bool = false,
    };

    pub fn init(self: *TestClient, gpa: std.mem.Allocator, io: std.Io, addr: std.Io.net.IpAddress) !void {
        self.* = .{ .gpa = gpa, .io = io, .stream = try addr.connect(io, .{ .mode = .stream }) };
        self.reader = .init(self.stream, io, &self.read_buf);
        self.writer = self.stream.writer(io, &self.write_buf);
        self.r = &self.reader.interface;
        self.w = &self.writer.interface;
        try self.initSession();
    }

    /// Over TLS, offering only "h2" through ALPN.
    pub fn initTls(self: *TestClient, gpa: std.mem.Allocator, io: std.Io, addr: std.Io.net.IpAddress, ca: *std.crypto.Certificate.Bundle) !void {
        return self.initTlsAfter(gpa, io, addr, ca, "");
    }

    /// `initTls`, with `preamble` (a PROXY protocol header) sent in the
    /// clear before the handshake.
    pub fn initTlsAfter(self: *TestClient, gpa: std.mem.Allocator, io: std.Io, addr: std.Io.net.IpAddress, ca: *std.crypto.Certificate.Bundle, preamble: []const u8) !void {
        self.* = .{ .gpa = gpa, .io = io, .stream = try addr.connect(io, .{ .mode = .stream }) };
        self.reader = .init(self.stream, io, &self.read_buf);
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

    pub fn initSession(self: *TestClient) !void {
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

    pub fn deinit(self: *TestClient) void {
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

    pub fn request(self: *TestClient, method: []const u8, path: []const u8, body: ?[]const u8) !i32 {
        return self.requestProtocol(method, path, null, body);
    }

    /// `request`, with a `:protocol` for an extended CONNECT (RFC 8441).
    pub fn requestProtocol(self: *TestClient, method: []const u8, path: []const u8, protocol: ?[]const u8, body: ?[]const u8) !i32 {
        return self.requestFull(method, path, protocol, &.{}, body);
    }

    /// `request`, with `extra` fields after the pseudo-headers (such as a
    /// content-length, which `request` never sends).
    pub fn requestHeaders(self: *TestClient, method: []const u8, path: []const u8, extra: []const c.nghttp2_nv, body: ?[]const u8) !i32 {
        return self.requestFull(method, path, null, extra, body);
    }

    pub fn requestFull(self: *TestClient, method: []const u8, path: []const u8, protocol: ?[]const u8, extra: []const c.nghttp2_nv, body: ?[]const u8) !i32 {
        var all: [16]c.nghttp2_nv = undefined;
        all[0] = nv(":method", method);
        all[1] = nv(":path", path);
        all[2] = nv(":scheme", "http");
        all[3] = nv(":authority", "localhost");
        var n: usize = 4;
        if (protocol) |p| {
            all[n] = nv(":protocol", p);
            n += 1;
        }
        for (extra) |f| {
            all[n] = f;
            n += 1;
        }
        const nva = all[0..n];
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
    pub fn requestWith(self: *TestClient, path: []const u8, authority: ?[]const u8, extra: []const c.nghttp2_nv) !i32 {
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

    pub fn get(self: *TestClient, id: i32) *Resp {
        return self.responses.get(id).?;
    }

    /// Sends what the session has, without waiting for anything.
    pub fn sendPending(self: *TestClient) !void {
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
    pub fn run(self: *TestClient) !void {
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

    /// Sends and receives until stream `id` is closed (others may still be
    /// open).
    pub fn runUntilDone(self: *TestClient, id: i32) !void {
        while (true) {
            try self.sendPending();
            if (self.get(id).closed) return;
            const bytes = try self.r.peekGreedy(1);
            const rv = c.nghttp2_session_mem_recv2(self.session, bytes.ptr, bytes.len);
            if (rv < 0) return error.Http2Recv;
            self.r.toss(@intCast(rv));
        }
    }

    /// Sends and receives until a PING ACK more than before has come.
    pub fn runUntilPingAck(self: *TestClient) !void {
        const want = self.ping_acks + 1;
        while (true) {
            try self.sendPending();
            if (self.ping_acks >= want) return;
            const bytes = try self.r.peekGreedy(1);
            const rv = c.nghttp2_session_mem_recv2(self.session, bytes.ptr, bytes.len);
            if (rv < 0) return error.Http2Recv;
            self.r.toss(@intCast(rv));
        }
    }

    /// Sends and receives until the response on stream `id` is whole,
    /// whether or not the stream is closed.
    pub fn runUntilAnswered(self: *TestClient, id: i32) !void {
        while (true) {
            try self.sendPending();
            if (self.get(id).answered) return;
            const bytes = try self.r.peekGreedy(1);
            const rv = c.nghttp2_session_mem_recv2(self.session, bytes.ptr, bytes.len);
            if (rv < 0) return error.Http2Recv;
            self.r.toss(@intCast(rv));
        }
    }

    pub fn nv(name: []const u8, value: []const u8) c.nghttp2_nv {
        return .{ .name = @constCast(name.ptr), .namelen = name.len, .value = @constCast(value.ptr), .valuelen = value.len, .flags = c.NGHTTP2_NV_FLAG_NONE };
    }

    pub fn respFor(session: ?*c.nghttp2_session, id: i32) ?*Resp {
        const ptr = c.nghttp2_session_get_stream_user_data(session, id) orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    pub fn onHeader(session: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, name: [*c]const u8, namelen: usize, value: [*c]const u8, valuelen: usize, _: u8, user_data: ?*anyopaque) callconv(.c) c_int {
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

    pub fn onData(session: ?*c.nghttp2_session, _: u8, id: i32, data: [*c]const u8, len: usize, user_data: ?*anyopaque) callconv(.c) c_int {
        const self: *TestClient = @ptrCast(@alignCast(user_data.?));
        const resp = respFor(session, id) orelse return 0;
        resp.body.appendSlice(self.gpa, data[0..len]) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
        return 0;
    }

    pub fn onFrame(session: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, user_data: ?*anyopaque) callconv(.c) c_int {
        const self: *TestClient = @ptrCast(@alignCast(user_data.?));
        if (frame.*.hd.type == c.NGHTTP2_DATA and frame.*.hd.length == 0 and frame.*.hd.flags & c.NGHTTP2_FLAG_END_STREAM != 0) self.empty_ends += 1;
        if (frame.*.hd.type == c.NGHTTP2_WINDOW_UPDATE and frame.*.hd.stream_id != 0) self.stream_window_updates += 1;
        if (frame.*.hd.type == c.NGHTTP2_PING) {
            if (frame.*.hd.flags & c.NGHTTP2_FLAG_ACK != 0) self.ping_acks += 1 else self.pings += 1;
        }
        if ((frame.*.hd.type == c.NGHTTP2_DATA or frame.*.hd.type == c.NGHTTP2_HEADERS) and frame.*.hd.flags & c.NGHTTP2_FLAG_END_STREAM != 0) {
            if (respFor(session, frame.*.hd.stream_id)) |resp| resp.answered = true;
        }
        if (frame.*.hd.type == c.NGHTTP2_RST_STREAM) if (respFor(session, frame.*.hd.stream_id)) |resp| {
            if (resp.rsts == 0) resp.body_at_rst = resp.body.items.len;
            resp.rsts += 1;
        };
        if (frame.*.hd.type == c.NGHTTP2_GOAWAY) self.goaway_error = frame.*.goaway.error_code;
        if (frame.*.hd.type == c.NGHTTP2_GOAWAY and self.goaway_count < self.goaways.len) {
            self.goaways[self.goaway_count] = frame.*.goaway.last_stream_id;
            // Read by a test's helper thread (`releaseOnFinalGoaway`).
            @atomicStore(usize, &self.goaway_count, self.goaway_count + 1, .release);
        }
        return 0;
    }

    /// Receives, sending nothing (the SETTINGS ACK the session owes stays
    /// queued), until a WINDOW_UPDATE for a stream has come.
    /// Receives until stream `id` and the connection each have room for
    /// `n` more body bytes (the server's WINDOW_UPDATEs are on their way).
    pub fn recvUntilRoom(self: *TestClient, id: i32, n: usize) !void {
        while (@min(c.nghttp2_session_get_stream_remote_window_size(self.session, id), c.nghttp2_session_get_remote_window_size(self.session)) < n) {
            try self.sendPending();
            const bytes = try self.r.peekGreedy(1);
            const rv = c.nghttp2_session_mem_recv2(self.session, bytes.ptr, bytes.len);
            if (rv < 0) return error.Http2Recv;
            self.r.toss(@intCast(rv));
        }
    }

    pub fn recvUntilStreamWindowUpdate(self: *TestClient) !void {
        while (self.stream_window_updates == 0) {
            const bytes = try self.r.peekGreedy(1);
            const rv = c.nghttp2_session_mem_recv2(self.session, bytes.ptr, bytes.len);
            if (rv < 0) return error.Http2Recv;
            self.r.toss(@intCast(rv));
        }
    }

    /// Keeps the connection going (answering PINGs and SETTINGS) until the
    /// server closes it, then shuts the socket as a real client does, so
    /// the server's lingering close ends at once.
    pub fn runUntilClosed(self: *TestClient) !void {
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
                error.EndOfStream => {
                    self.stream.shutdown(self.io, .both) catch {};
                    return;
                },
                else => |e| return e,
            };
            const rv = c.nghttp2_session_mem_recv2(self.session, bytes.ptr, bytes.len);
            if (rv < 0) return error.Http2Recv;
            self.r.toss(@intCast(rv));
        }
    }

    pub fn onClose(session: ?*c.nghttp2_session, id: i32, error_code: u32, user_data: ?*anyopaque) callconv(.c) c_int {
        const self: *TestClient = @ptrCast(@alignCast(user_data.?));
        const resp = respFor(session, id) orelse return 0;
        self.closes += 1;
        resp.close_seq = self.closes;
        resp.closed = true;
        resp.error_code = error_code;
        return 0;
    }

    pub fn provide(_: ?*c.nghttp2_session, _: i32, buf: [*c]u8, length: usize, flags: [*c]u32, source: [*c]c.nghttp2_data_source, _: ?*anyopaque) callconv(.c) c.nghttp2_ssize {
        const resp: *Resp = @ptrCast(@alignCast(source.*.ptr.?));
        const rest = resp.send[resp.sent..];
        const n = @min(rest.len, length);
        @memcpy(buf[0..n], rest[0..n]);
        @atomicStore(usize, &resp.sent, resp.sent + n, .release);
        if (resp.sent == resp.send.len) {
            if (resp.keep_open) {
                if (n == 0) return c.NGHTTP2_ERR_DEFERRED;
            } else flags.* |= c.NGHTTP2_DATA_FLAG_EOF;
        }
        return @intCast(n);
    }
};

pub const Handlers = struct {
    /// The cookie header, how many `accept` fields came, and the host.
    pub fn fields(req: *dusty.Request, res: *dusty.Response) !void {
        var accepts: usize = 0;
        var it = req.headers.iterator();
        while (it.next()) |e| {
            if (std.ascii.eqlIgnoreCase(e.key, "accept")) accepts += 1;
        }
        try res.print(.text, "cookie={s} accepts={d} host={s}", .{ req.headers.get("cookie") orelse "-", accepts, req.host() orelse "-" });
    }
    pub fn hello(_: *dusty.Request, res: *dusty.Response) !void {
        try res.print(.text, "hello", .{});
    }
    pub fn user(req: *dusty.Request, res: *dusty.Response) !void {
        try std.testing.expectEqual(@as(u8, 2), req.version_major);
        try res.print(.text, "user {s}", .{req.params.get("id").?});
    }
    pub fn echo(req: *dusty.Request, res: *dusty.Response) !void {
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
    pub fn trailers(_: *dusty.Request, res: *dusty.Response) !void {
        res.body = "with trailers";
        try res.trailer("x-done", "yes");
    }
    pub fn ignoreBody(_: *dusty.Request, res: *dusty.Response) !void {
        res.body = "not reading that";
    }
    pub fn who(req: *dusty.Request, res: *dusty.Response) !void {
        try res.print(.text, "{f} secure={}", .{ req.remote_address, req.secure });
    }
    pub fn slow(req: *dusty.Request, res: *dusty.Response) !void {
        try req.io.sleep(.fromMilliseconds(300), .awake);
        res.body = "slow but whole";
    }
    /// Answers once the test sets `held_gate`; counts itself in first.
    pub fn held(req: *dusty.Request, res: *dusty.Response) !void {
        _ = held_entered.fetchAdd(1, .acq_rel);
        try wait.waitEvent(req.io, "the test opened the held handler's gate", &held_gate);
        res.body = "held but whole";
    }
    pub var held_gate: std.Io.Event = .unset;
    pub var held_entered: std.atomic.Value(u32) = .init(0);
    /// `held`, after reading its (small) body.
    pub fn heldBody(req: *dusty.Request, res: *dusty.Response) !void {
        const raw = req._body_source.?.reader;
        var hash: std.hash.Wyhash = .init(0);
        while (true) _ = takeBody(raw, &hash, 4096) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        return held(req, res);
    }
    /// A streamed body far past the client's 64 KiB stream window.
    pub fn big(_: *dusty.Request, res: *dusty.Response) !void {
        var buf: [4096]u8 = undefined;
        var out = try res.stream(&buf);
        for (0..big_len / 1000) |i| try out.interface.print("{d:0>999}\n", .{i});
        try out.end();
    }
    pub const big_len = 1000 * 1000;
    /// Reads the body only once the test opens `late_gate` (after a full
    /// window of it has queued up, `SentGate`), and answers with its
    /// length and a checksum. Counts itself in first.
    pub fn late(req: *dusty.Request, res: *dusty.Response) !void {
        _ = late_entered.fetchAdd(1, .acq_rel);
        try wait.waitEvent(req.io, "the test opened the late handlers' gate", &late_gate);
        return sum(req, res);
    }
    pub var late_gate: std.Io.Event = .unset;
    pub var late_entered: std.atomic.Value(u32) = .init(0);
    /// `sum`, as a handler starved of CPU at the worst moment: it reads
    /// exactly `stall_credit` bytes, twice the window its first read
    /// raised it to, which returns credit for all of them, then stops
    /// until the test opens `stall_gate` (once the peer has sent a whole
    /// raised window again, `SentGate`), then reads the rest.
    pub fn stall(req: *dusty.Request, res: *dusty.Response) !void {
        const raw = req._body_source.?.reader;
        var hash: std.hash.Wyhash = .init(0);
        var n: usize = 0;
        while (n < stall_credit) n += try takeBody(raw, &hash, stall_credit - n);
        try wait.waitEvent(req.io, "the test opened the stalled handler's gate", &stall_gate);
        while (true) n += takeBody(raw, &hash, 4096) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        try res.print(.text, "{d} {x}", .{ n, hash.final() });
    }
    pub const stall_credit = 512 * 1024;
    pub var stall_gate: std.Io.Event = .unset;
    /// `sum`, reading one byte each time the server has seen the peer send
    /// a whole window since the last raise (the engine's window-full counter past
    /// `stepper_base`), twice, then the rest: each of those reads raises
    /// the window one step.
    pub fn stepper(req: *dusty.Request, res: *dusty.Response) !void {
        const raw = req._body_source.?.reader;
        var hash: std.hash.Wyhash = .init(0);
        var n: usize = 0;
        for (0..2) |k| {
            try wait.waitAtLeast(req.io, "the peer used up the stream window", stepper_fulls, stepper_base + @as(u32, @intCast(k)) + 1);
            n += try takeBody(raw, &hash, 1);
        }
        while (true) n += takeBody(raw, &hash, 4096) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        try res.print(.text, "{d} {x}", .{ n, hash.final() });
    }
    pub var stepper_base: u32 = 0;
    /// The engine's count of times the peer used up a stream window
    /// (`test_window.fulls`); the test sets it.
    pub var stepper_fulls: *const std.atomic.Value(u32) = undefined;
    /// `sum`, reading the body straight from the stream as it comes, and
    /// telling the test how much it has read so far (`reader_got`).
    pub fn reader(req: *dusty.Request, res: *dusty.Response) !void {
        _ = reader_entered.fetchAdd(1, .acq_rel);
        const raw = req._body_source.?.reader;
        var hash: std.hash.Wyhash = .init(0);
        var n: usize = 0;
        while (true) {
            n += takeBody(raw, &hash, 4096) catch |err| switch (err) {
                error.EndOfStream => break,
                else => |e| return e,
            };
            reader_got.store(@intCast(n), .release);
        }
        try res.print(.text, "{d} {x}", .{ n, hash.final() });
    }
    pub var reader_got: std.atomic.Value(u32) = .init(0);
    pub var reader_entered: std.atomic.Value(u32) = .init(0);
    /// At most `limit` body bytes, straight from the stream: each read is
    /// what the engine credits back.
    pub fn takeBody(raw: *std.Io.Reader, hash: *std.hash.Wyhash, limit: usize) !usize {
        var scratch: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&scratch);
        const n = try raw.stream(&w, .limited(@min(limit, scratch.len)));
        hash.update(scratch[0..n]);
        return n;
    }
    /// The body's length and checksum.
    pub fn sum(req: *dusty.Request, res: *dusty.Response) !void {
        _ = sum_entered.fetchAdd(1, .acq_rel);
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
    /// `sum` handlers started (the ones before have all answered by the
    /// time a test reads it).
    pub var sum_entered: std.atomic.Value(u32) = .init(0);
};

/// Sets `gate` once each of `resps` has sent at least `n` bytes of its
/// body, and `entered` (handlers that count themselves in) has reached
/// `want`: a handler held at the gate then has that much of its body
/// queued or on its way, however slow the machine. A late server read can
/// only make a test miss its case, never fail it. The test awaits
/// `release` after its client is done, so a wait that timed out (and
/// opened the gate anyway) fails it.
pub const SentGate = struct {
    resps: []const *const TestClient.Resp,
    n: usize,
    entered: ?*const std.atomic.Value(u32) = null,
    want: u32 = 0,

    pub fn reached(g: *const SentGate) bool {
        if (g.entered) |e| if (e.load(.acquire) < g.want) return false;
        for (g.resps) |r| if (@atomicLoad(usize, &r.sent, .acquire) < g.n) return false;
        return true;
    }

    pub fn release(io: std.Io, g: *const SentGate, gate: *std.Io.Event) wait.WaitError!void {
        defer gate.set(io);
        try wait.waitUntil(io, "the client sent each body up to the window", g, reached);
    }
};

/// What a client may send on a stream before the server reads any of it,
/// whether or not it has seen the server's SETTINGS yet: the default
/// initial window (65535), one byte under the server's `stream_window`.
pub const default_window = 65535;

/// `sendFile` from `file_dir`, on its own route.
pub var file_dir: std.Io.Dir = undefined;
fn sendFileHandler(_: *dusty.Request, res: *dusty.Response) !void {
    _ = try res.sendFile(file_dir, "body.bin", .{});
}

pub fn Fixture(comptime E: type) type {
    const Srv = E.Server(void);
    return struct {
        const Self = @This();
        server: Srv,
        future: std.Io.Future(anyerror!void) = undefined,

        pub fn start(self: *Self, io: std.Io) !void {
            self.server = Srv.init(std.testing.allocator, io, .{
                .listeners = &.{.{ .address = loopback_addr, .http2_prior_knowledge = true }},
                .request = .{ .max_body_size = 8 << 20 },
                // Off by default; the extended CONNECT tests need it.
                .http2 = .{ .enable_connect_protocol = true },
            }, {});
            E.select(&self.server);
            self.server.router.get("/hello", Handlers.hello);
            self.server.router.get("/file", sendFileHandler);
            self.server.router.get("/fields", Handlers.fields);
            self.server.router.get("/users/:id", Handlers.user);
            self.server.router.post("/echo", Handlers.echo);
            self.server.router.get("/trailers", Handlers.trailers);
            self.server.router.post("/ignore", Handlers.ignoreBody);
            self.server.router.get("/slow", Handlers.slow);
            self.server.router.get("/held", Handlers.held);
            self.server.router.post("/late", Handlers.late);
            self.server.router.post("/stall", Handlers.stall);
            self.server.router.post("/stepper", Handlers.stepper);
            self.server.router.post("/reader", Handlers.reader);
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

        pub fn run(s: *Srv) anyerror!void {
            try s.run();
        }

        pub fn stop(self: *Self, io: std.Io) void {
            self.future.cancel(io) catch {};
            self.server.deinit();
        }
    };
}

/// Counts allocations through it, for the hot-path test below.
pub const CountingAllocator = struct {
    inner: std.mem.Allocator,
    count: std.atomic.Value(usize) = .init(0),

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    pub fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        _ = self.count.fetchAdd(1, .monotonic);
        return self.inner.rawAlloc(len, alignment, ra);
    }
    pub fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.inner.rawResize(memory, alignment, new_len, ra);
    }
    pub fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        _ = self.count.fetchAdd(1, .monotonic);
        return self.inner.rawRemap(memory, alignment, new_len, ra);
    }
    pub fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.inner.rawFree(memory, alignment, ra);
    }
};

/// Waits until the server has freed every stream. The response can reach
/// the client before its handler's task has let go of the stream (each
/// task is a thread of its own under std.testing.io), and a request sent
/// meanwhile rightly takes a second stream, which the pool then keeps:
/// one request at a time is what the warm-path test measures.
pub fn awaitStreamsFreed(server: anytype, io: std.Io) !void {
    try wait.waitUntil(io, "the server freed every stream", server, struct {
        fn f(s: @TypeOf(server)) bool {
            return s.busy.load(.acquire).count == 0;
        }
    }.f);
}
