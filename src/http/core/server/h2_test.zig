// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

//! HTTP/2 engine tests: a the core server with cleartext HTTP/2 (prior
//! knowledge) on loopback, driven by a minimal nghttp2 client.
const std = @import("std");
const dusty = @import("../root.zig");
const c = @import("nghttp2");
const build_options = @import("build_options");
const tls = @import("tls");
const h2 = @import("h2.zig");
const wait = @import("anole_test_wait");
const test_socket = @import("test_socket.zig");

const loopback_addr: dusty.Address = .{ .ip = .{ .ip4 = .loopback(0) } };

/// A blocking HTTP/2 client over one connection, for tests: submit
/// requests, then `run` until every stream is closed. Every read from the
/// socket has `wait.deadline()` (`test_socket.DeadlineReader`), so a
/// server that stops answering fails the test instead of hanging it.
const TestClient = struct {
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
    };

    fn init(self: *TestClient, gpa: std.mem.Allocator, io: std.Io, addr: std.Io.net.IpAddress) !void {
        self.* = .{ .gpa = gpa, .io = io, .stream = try addr.connect(io, .{ .mode = .stream }) };
        self.reader = .init(self.stream, io, &self.read_buf);
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

    /// Sends and receives until stream `id` is closed (others may still be
    /// open).
    fn runUntilDone(self: *TestClient, id: i32) !void {
        while (true) {
            try self.sendPending();
            if (self.get(id).closed) return;
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

    fn onFrame(session: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, user_data: ?*anyopaque) callconv(.c) c_int {
        const self: *TestClient = @ptrCast(@alignCast(user_data.?));
        if (frame.*.hd.type == c.NGHTTP2_DATA and frame.*.hd.length == 0 and frame.*.hd.flags & c.NGHTTP2_FLAG_END_STREAM != 0) self.empty_ends += 1;
        if (frame.*.hd.type == c.NGHTTP2_WINDOW_UPDATE and frame.*.hd.stream_id != 0) self.stream_window_updates += 1;
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
    fn recvUntilStreamWindowUpdate(self: *TestClient) !void {
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
        @atomicStore(usize, &resp.sent, resp.sent + n, .release);
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
    /// Answers once the test sets `held_gate`; counts itself in first.
    fn held(req: *dusty.Request, res: *dusty.Response) !void {
        _ = held_entered.fetchAdd(1, .acq_rel);
        try wait.waitEvent(req.io, "the test opened the held handler's gate", &held_gate);
        res.body = "held but whole";
    }
    var held_gate: std.Io.Event = .unset;
    var held_entered: std.atomic.Value(u32) = .init(0);
    /// A streamed body far past the client's 64 KiB stream window.
    fn big(_: *dusty.Request, res: *dusty.Response) !void {
        var buf: [4096]u8 = undefined;
        var out = try res.stream(&buf);
        for (0..big_len / 1000) |i| try out.interface.print("{d:0>999}\n", .{i});
        try out.end();
    }
    const big_len = 1000 * 1000;
    /// Reads the body only once the test opens `late_gate` (after a full
    /// window of it has queued up, `SentGate`), and answers with its
    /// length and a checksum. Counts itself in first.
    fn late(req: *dusty.Request, res: *dusty.Response) !void {
        _ = late_entered.fetchAdd(1, .acq_rel);
        try wait.waitEvent(req.io, "the test opened the late handlers' gate", &late_gate);
        return sum(req, res);
    }
    var late_gate: std.Io.Event = .unset;
    var late_entered: std.atomic.Value(u32) = .init(0);
    /// `sum`, as a handler starved of CPU at the worst moment: it reads
    /// exactly `stall_credit` bytes, half the window its first read raised
    /// it to, which returns credit for all of them, then stops until the
    /// test opens `stall_gate` (once the peer has sent the whole window
    /// again, `SentGate`), then reads the rest.
    fn stall(req: *dusty.Request, res: *dusty.Response) !void {
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
    const stall_credit = 512 * 1024;
    var stall_gate: std.Io.Event = .unset;
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
    var sum_entered: std.atomic.Value(u32) = .init(0);
};

/// Sets `gate` once each of `resps` has sent at least `n` bytes of its
/// body, and `entered` (handlers that count themselves in) has reached
/// `want`: a handler held at the gate then has that much of its body
/// queued or on its way, however slow the machine. A late server read can
/// only make a test miss its case, never fail it. The test awaits
/// `release` after its client is done, so a wait that timed out (and
/// opened the gate anyway) fails it.
const SentGate = struct {
    resps: []const *const TestClient.Resp,
    n: usize,
    entered: ?*const std.atomic.Value(u32) = null,
    want: u32 = 0,

    fn reached(g: *const SentGate) bool {
        if (g.entered) |e| if (e.load(.acquire) < g.want) return false;
        for (g.resps) |r| if (@atomicLoad(usize, &r.sent, .acquire) < g.n) return false;
        return true;
    }

    fn release(io: std.Io, g: *const SentGate, gate: *std.Io.Event) wait.WaitError!void {
        defer gate.set(io);
        try wait.waitUntil(io, "the client sent each body up to the window", g, reached);
    }
};

/// What a client may send on a stream before the server reads any of it,
/// whether or not it has seen the server's SETTINGS yet: the default
/// initial window (65535), one byte under the server's `stream_window`.
const default_window = 65535;

const Fixture = struct {
    server: dusty.Server(void),
    future: std.Io.Future(anyerror!void) = undefined,

    fn start(self: *Fixture, io: std.Io) !void {
        self.server = dusty.Server(void).init(std.testing.allocator, io, .{
            .listeners = &.{.{ .address = loopback_addr, .http2_prior_knowledge = true }},
            .request = .{ .max_body_size = 8 << 20 },
            // Off by default; the extended CONNECT tests need it.
            .http2 = .{ .enable_connect_protocol = true },
        }, {});
        self.server.router.get("/hello", Handlers.hello);
        self.server.router.get("/fields", Handlers.fields);
        self.server.router.get("/users/:id", Handlers.user);
        self.server.router.post("/echo", Handlers.echo);
        self.server.router.get("/trailers", Handlers.trailers);
        self.server.router.post("/ignore", Handlers.ignoreBody);
        self.server.router.get("/slow", Handlers.slow);
        self.server.router.get("/held", Handlers.held);
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
}

test "HTTP/2: a no_wait request reset with its body half sent lets its handler go, and the connection carries on" {
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);

    var body: [1000]u8 = undefined;
    for (&body, 0..) |*b, i| b.* = @truncate(i *% 77 +% (i >> 13));

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    var expect: [64]u8 = undefined;
    const sums = Handlers.sum_entered.load(.acquire);
    const cut = try client.request("POST", "/nw/sum", body[0..1000]);
    client.get(cut).keep_open = true;
    try client.sendPending();
    // The server has the stream: its handler runs (and waits for the rest).
    try wait.waitAtLeast(io, "the half-sent request's handler runs", &Handlers.sum_entered, sums + 1);
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
    // The handler stops after `stall_credit` until the client has sent
    // that plus the whole raised window (1 MiB): the window filled again
    // behind a handler that does not read.
    Handlers.stall_gate = .unset;
    const resps = [_]*const TestClient.Resp{client.get(id)};
    const gate: SentGate = .{ .resps = &resps, .n = Handlers.stall_credit + 1024 * 1024 };
    var releaser = try io.concurrent(SentGate.release, .{ io, &gate, &Handlers.stall_gate });
    defer releaser.cancel(io) catch {};
    // The preface, SETTINGS, the head and a default window of the body,
    // then nothing until the handler's first read has raised the stream's
    // window: the client's ACK of the server's SETTINGS (whose initial
    // window differs from the default) arrives after the raise.
    try client.sendPending();
    try client.recvUntilStreamWindowUpdate();
    try client.run();
    try releaser.await(io);
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

    // On tasks, the quick one does not wait: it is answered while the
    // other is still held (a gate, not a race against a sleep).
    Handlers.held_gate = .unset;
    const held_task = try client.request("GET", "/held", null);
    const hello_task = try client.request("GET", "/hello", null);
    try client.runUntilDone(hello_task);
    try std.testing.expect(!client.get(held_task).closed);
    Handlers.held_gate.set(io);
    try client.run();
    try std.testing.expectEqualStrings("held but whole", client.get(held_task).body.items);
    try std.testing.expect(client.get(hello_task).close_seq < client.get(held_task).close_seq);
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
    Handlers.late_gate = .unset;
    const resps = [_]*const TestClient.Resp{ client.get(a), client.get(b) };
    const gate: SentGate = .{
        .resps = &resps,
        .n = default_window,
        .entered = &Handlers.late_entered,
        .want = Handlers.late_entered.load(.acquire) + 2,
    };
    var releaser = try io.concurrent(SentGate.release, .{ io, &gate, &Handlers.late_gate });
    defer releaser.cancel(io) catch {};
    try client.run();
    try releaser.await(io);
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
    // Ended by both sides' END_STREAM: the client's went out with the
    // whole body, and no RST_STREAM came.
    try std.testing.expectEqual(body.len, client.get(id).sent);
    try std.testing.expectEqual(@as(usize, 0), client.get(id).rsts);
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
    const resp = client.get(id);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("not reading that", resp.body.items);
    // One RST_STREAM, with NO_ERROR, once the whole response was in.
    try std.testing.expectEqual(@as(usize, 1), resp.rsts);
    try std.testing.expectEqual(resp.body.items.len, resp.body_at_rst);
    try std.testing.expectEqual(@as(u32, c.NGHTTP2_NO_ERROR), resp.error_code);
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

    const ca: dusty.Ca = .{ .file = "certs/cert.pem" };
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
    try wait.waitUntil(io, "the server freed every stream", server, struct {
        fn f(s: *dusty.Server(void)) bool {
            return s.busy.load(.acquire).count == 0;
        }
    }.f);
}

/// Sets `gate` once `client` has taken both of the drain's GOAWAYs: a
/// response held until then is in flight through the whole drain, however
/// slow the machine. Not on the first: the test client's nghttp2 session
/// stops reading once it has a GOAWAY and no open stream
/// (`nghttp2_session_want_read`), so a response that closed the stream
/// before the final GOAWAY arrived would have that GOAWAY dropped unread.
fn releaseOnFinalGoaway(io: std.Io, client: *const TestClient, gate: *std.Io.Event) std.Io.Cancelable!void {
    defer gate.set(io);
    wait.waitUntil(io, "the client took the drain's final GOAWAY", client, struct {
        fn f(cl: *const TestClient) bool {
            return @atomicLoad(usize, &cl.goaway_count, .acquire) >= 2;
        }
    }.f) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.WaitTimedOut => {},
    };
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
    if (wait.timing()) try std.testing.expect(started.durationTo(.now(io, .awake)).raw.toMilliseconds() < 900);
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

    // Start a request held until both of the drain's GOAWAYs reached the
    // client, then shut down while it runs.
    Handlers.held_gate = .unset;
    const helds = Handlers.held_entered.load(.acquire);
    const id = try client.request("GET", "/held", null);
    try client.sendPending();
    try wait.waitAtLeast(io, "the held request's handler runs", &Handlers.held_entered, helds + 1);
    var releaser = try io.concurrent(releaseOnFinalGoaway, .{ io, &client, &Handlers.held_gate });
    defer releaser.cancel(io) catch {};
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
    try std.testing.expectEqualStrings("held but whole", resp.body.items);
}

/// `holdUnreadAtDrain` holds the reader after the final GOAWAY. It acts
/// once: a later entry (the reader going on) passes straight through.
var unread_held: std.atomic.Value(bool) = .init(false);
/// The server's socket, once `holdUnreadAtDrain` has held the reader with
/// the client's PING unread and let it go (-1 before).
var unread_socket: std.atomic.Value(std.Io.net.Socket.Handle) = .init(-1);
/// `holdUnreadAtDrain` let the reader go with a cancel.
var unread_canceled: std.atomic.Value(bool) = .init(false);

fn hasUnreadInput(fd: std.Io.net.Socket.Handle) bool {
    var n: c_int = 0;
    if (std.c.ioctl(fd, std.c.T.FIONREAD, &n) != 0) return false;
    return n > 0;
}

fn isSet(flag: *std.atomic.Value(bool)) bool {
    return flag.load(.acquire);
}

fn never(_: void) bool {
    return false;
}

/// `h2.test_before_fill` for the test below. The first time the reader
/// waits for input after the drain's final GOAWAY is submitted, holds it,
/// uncancelably, until the client's PING is in the server's socket. The
/// PING follows the response, which the writer takes only after it has
/// flushed the final GOAWAY, so by then a drain that lets go of a
/// connection at that flush (#135) has done so: it cancels the connection
/// once the held stream is done, and the cancel is taken here, with the
/// PING unread. A drain still holding the connection lets the reader go
/// on. (The server's in-flight count cannot tell the two apart: the
/// stream's count and the drain's hold are one each, and the stream's may
/// go back before or after the server's FIN.)
fn holdUnreadAtDrain(io: std.Io, probe: h2.FillProbe) std.Io.Cancelable!void {
    if (!probe.goaway_sent) return;
    if (unread_held.swap(true, .acq_rel)) return;
    defer unread_socket.store(probe.socket, .release);
    {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        wait.waitUntil(io, "the client's PING is in the server's socket", probe.socket, hasUnreadInput) catch |err| switch (err) {
            error.Canceled => unreachable,
            error.WaitTimedOut => return,
        };
    }
    if (probe.drainHolds()) return;
    wait.waitUntil(io, "the drain's cancel", {}, never) catch |err| switch (err) {
        error.Canceled => {
            unread_canceled.store(true, .release);
            return error.Canceled;
        },
        error.WaitTimedOut => {},
    };
}

/// The server took the client's PING (its reader went on), or a reset came
/// (its reader was canceled, and the connection closes with the PING
/// unread); `reset` keeps the reset's error.
const TookOrReset = struct {
    client: std.Io.net.Socket.Handle,
    reset: *c_int,

    fn holds(x: TookOrReset) bool {
        const err = socketError(x.client);
        if (err != 0) {
            x.reset.* = err;
            return true;
        }
        const server = unread_socket.load(.acquire);
        if (server == -1 or unread_canceled.load(.acquire)) return false;
        // Read, or the connection closed after reading it.
        return !hasUnreadInput(server);
    }
};

/// One HTTP/2 frame, written by hand.
fn writeFrame(w: *std.Io.Writer, kind: u8, flags: u8, stream_id: u31, payload: []const u8) !void {
    var head: [9]u8 = undefined;
    std.mem.writeInt(u24, head[0..3], @intCast(payload.len), .big);
    head[3] = kind;
    head[4] = flags;
    std.mem.writeInt(u32, head[5..9], stream_id, .big);
    try w.writeAll(&head);
    try w.writeAll(payload);
    try w.flush();
}

/// The socket's pending error (SO_ERROR), which a reset sets; reading it
/// clears it.
fn socketError(fd: std.Io.net.Socket.Handle) c_int {
    var err: c_int = 0;
    var len: std.c.socklen_t = @sizeOf(c_int);
    if (std.c.getsockopt(fd, std.c.SOL.SOCKET, std.c.SO.ERROR, &err, &len) != 0) return -1;
    return err;
}

test "HTTP/2: a drain ends with a clean close when the peer's last frames are unread" {
    // Windows: not supported, not pending. The probes are POSIX ioctl and
    // getsockopt through libc; the drain code is the same everywhere.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    // A peer may still send after the final GOAWAY (a PING, a
    // WINDOW_UPDATE). The connection must not close with that unread: the
    // kernel then sends a reset after the FIN, and a peer may drop what it
    // has not read yet. The client frames by hand: an nghttp2 session
    // reads nothing once it has a GOAWAY and no stream open.
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.server.deinit();

    unread_held.store(false, .release);
    unread_socket.store(-1, .release);
    unread_canceled.store(false, .release);
    h2.test_before_fill = holdUnreadAtDrain;
    defer h2.test_before_fill = null;

    const sock = try fx.server.address.ip.connect(io, .{ .mode = .stream });
    defer sock.close(io);
    var read_buf: [32 * 1024]u8 = undefined;
    var write_buf: [1024]u8 = undefined;
    var sr = sock.reader(io, &read_buf);
    var sw = sock.writer(io, &write_buf);
    const r = &sr.interface;
    const w = &sw.interface;

    // A request held until the final GOAWAY is out: its open stream keeps
    // the server's reader reading after that GOAWAY, into the hook.
    Handlers.held_gate = .unset;
    defer Handlers.held_gate.set(io);
    const helds = Handlers.held_entered.load(.acquire);
    try w.writeAll(h2.preface);
    try writeFrame(w, 0x4, 0, 0, ""); // SETTINGS
    // HPACK: GET, http, then :path and :authority as literals.
    try writeFrame(w, 0x1, 0x1 | 0x4, 1, "\x82\x86\x04\x05/held\x01\x09localhost");
    try wait.waitAtLeast(io, "the held request's handler runs", &Handlers.held_entered, helds + 1);
    var stopper: ?std.Io.Future(void) = try io.concurrent(stopFixture, .{ &fx, io });
    defer if (stopper) |*s| s.await(io);

    var goaways: usize = 0;
    var answered = false;
    var end: ?anyerror = null;
    while (end == null) {
        const head = r.takeArray(9) catch |err| {
            end = err;
            break;
        };
        const len = std.mem.readInt(u24, head[0..3], .big);
        const kind = head[3];
        const flags = head[4];
        const payload = r.take(len) catch |err| {
            end = err;
            break;
        };
        switch (kind) {
            0x0, 0x1 => if (flags & 0x1 != 0) { // the response's END_STREAM
                answered = true;
                // After the final GOAWAY and the last response: what the
                // server has not read when its drain is done with the
                // connection.
                try writeFrame(w, 0x6, 0, 0, "unread!!");
            },
            0x4 => if (flags & 0x1 == 0) try writeFrame(w, 0x4, 0x1, 0, ""), // SETTINGS: ACK
            0x6 => if (flags & 0x1 == 0) try writeFrame(w, 0x6, 0x1, 0, payload), // PING: ACK
            0x7 => { // GOAWAY
                goaways += 1;
                const last = std.mem.readInt(u32, payload[0..4], .big) & 0x7fff_ffff;
                if (last != std.math.maxInt(u31)) {
                    try wait.waitUntil(io, "the server's reader is held after the final GOAWAY", &unread_held, isSet);
                    Handlers.held_gate.set(io);
                }
            },
            else => {},
        }
    }
    try std.testing.expect(answered);
    try std.testing.expectEqual(@as(usize, 2), goaways);
    if (end.? == error.ReadFailed) return sr.err orelse error.ReadFailed;
    try std.testing.expect(end.? == error.EndOfStream);

    // The server's FIN came first either way. Before hanging up, wait for
    // the server to take the PING, or for the reset.
    var reset: c_int = 0;
    try wait.waitUntil(io, "the server took the PING, or a reset", TookOrReset{ .client = sock.socket.handle, .reset = &reset }, TookOrReset.holds);
    if (reset == 0) reset = socketError(sock.socket.handle);
    sock.shutdown(io, .send) catch {};
    stopper.?.await(io);
    stopper = null;
    if (reset == 0) reset = socketError(sock.socket.handle);
    // No reset came after the server's FIN.
    try std.testing.expectEqual(@as(c_int, 0), reset);
}

/// `holdFlush` holds the writer's writes once set.
var flush_held: std.atomic.Value(bool) = .init(false);

/// Holds each write of the HTTP/2 writer for 200 ms once `flush_held` is
/// set (`h2.test_before_flush`): a deliberate window, not a wait for
/// anything.
fn holdFlush(io: std.Io) std.Io.Cancelable!void {
    if (!flush_held.load(.acquire)) return;
    try io.sleep(.fromMilliseconds(200), .awake);
}

/// `releaseOnFinalGoaway`, holding the writer's writes (`holdFlush`) from
/// just before the gate opens: the held response is then taken from the
/// session after the final GOAWAY and written 200 ms later.
fn holdAndReleaseOnFinalGoaway(io: std.Io, client: *const TestClient, gate: *std.Io.Event) std.Io.Cancelable!void {
    defer gate.set(io);
    wait.waitUntil(io, "the client took the drain's final GOAWAY", client, struct {
        fn f(cl: *const TestClient) bool {
            return @atomicLoad(usize, &cl.goaway_count, .acquire) >= 2;
        }
    }.f) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.WaitTimedOut => return,
    };
    flush_held.store(true, .release);
}

test "HTTP/2: a drain waits for a response that is taken from the session but not yet written" {
    // nghttp2 closes a stream when the writer takes its last frame, before
    // the write. The stream's count in the in-flight requests must last
    // until that write is done, or the drain sees zero and cancels the
    // connection with the response still in the writer's buffer. The
    // response is held until both GOAWAYs reached the client, then its
    // write is held 200 ms: the drain decides inside that window.
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

    flush_held.store(false, .release);
    h2.test_before_flush = holdFlush;
    defer h2.test_before_flush = null;
    Handlers.held_gate = .unset;
    const helds = Handlers.held_entered.load(.acquire);
    const id = try client.request("GET", "/held", null);
    try client.sendPending();
    try wait.waitAtLeast(io, "the held request's handler runs", &Handlers.held_entered, helds + 1);
    var releaser = try io.concurrent(holdAndReleaseOnFinalGoaway, .{ io, &client, &Handlers.held_gate });
    defer releaser.cancel(io) catch {};
    var stopper = try io.concurrent(stopFixture, .{ &fx, io });
    defer stopper.await(io);

    try client.runUntilClosed();
    try std.testing.expectEqual(@as(usize, 2), client.goaway_count);
    const resp = client.get(id);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("held but whole", resp.body.items);
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

    const ca: dusty.Ca = .{ .file = "certs/cert.pem" };
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
    Handlers.held_gate = .unset;
    const helds = Handlers.held_entered.load(.acquire);
    const id = try client.request("GET", "/held", null);
    while (true) {
        var data: [*c]const u8 = undefined;
        const n = c.nghttp2_session_mem_send2(client.session, &data);
        if (n <= 0) break;
        try client.w.writeAll(data[0..@intCast(n)]);
    }
    try client.w.flush();
    try wait.waitAtLeast(io, "the held request's handler runs", &Handlers.held_entered, helds + 1);
    // Done sending, with the request in flight; the handler answers only
    // once the server has read the EOF and handled it (the hook runs on the
    // connection's clean end of input), so the half-close always lands
    // while the response is in flight.
    h2.test_after_peer_end = struct {
        fn release(hook_io: std.Io) void {
            Handlers.held_gate.set(hook_io);
        }
    }.release;
    defer h2.test_after_peer_end = null;
    try client.stream.shutdown(io, .send);
    // Nothing more goes out from here; read until the response is in (each
    // read with the client's deadline).
    while (!client.get(id).closed) {
        const bytes = try client.r.peekGreedy(1);
        const rv = c.nghttp2_session_mem_recv2(client.session, bytes.ptr, bytes.len);
        if (rv < 0) return error.Http2Recv;
        client.r.toss(@intCast(rv));
    }
    try std.testing.expectEqual(@as(u16, 200), client.get(id).status);
    try std.testing.expectEqualStrings("held but whole", client.get(id).body.items);
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

/// A handler that waits up to 60 s for its client to leave. On zio the
/// wait itself is canceled; elsewhere `peerGone` tells. `let_go` says the
/// client's leaving ended it, not the end of its wait.
const Waiter = struct {
    var done: std.atomic.Value(bool) = .init(false);
    var started: std.atomic.Value(bool) = .init(false);
    var let_go: std.atomic.Value(bool) = .init(false);

    fn handle(req: *dusty.Request, res: *dusty.Response) !void {
        started.store(true, .release);
        defer done.store(true, .release);
        for (0..1200) |_| {
            req.io.sleep(.fromMilliseconds(50), .awake) catch |err| {
                let_go.store(true, .release);
                return err;
            };
            if (res.peerGone()) {
                let_go.store(true, .release);
                return;
            }
        }
        res.body = "nobody asked";
    }

    /// Sends what the client has queued (the request) and waits until the
    /// handler is running (a fixed sleep was not enough on a busy Windows
    /// runner: the reset then came before the handler started, so it never
    /// ran and never set `done`).
    fn start(client: *TestClient, io: std.Io) !void {
        done.store(false, .release);
        started.store(false, .release);
        let_go.store(false, .release);
        while (true) {
            var data: [*c]const u8 = undefined;
            const n = c.nghttp2_session_mem_send2(client.session, &data);
            if (n <= 0) break;
            try client.w.writeAll(data[0..@intCast(n)]);
        }
        try client.w.flush();
        try wait.waitFlag(io, "the waiting handler started", &started);
        try std.testing.expect(!done.load(.acquire));
    }

    /// The handler ended because its client left.
    fn expectLetGo(io: std.Io) !void {
        try wait.waitFlag(io, "the waiting handler ended", &done);
        try std.testing.expect(let_go.load(.acquire));
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

    _ = c.nghttp2_submit_rst_stream(client.session, c.NGHTTP2_FLAG_NONE, id, c.NGHTTP2_CANCEL);
    try client.run();
    try std.testing.expectEqual(@as(u32, c.NGHTTP2_CANCEL), client.get(id).error_code);
    try Waiter.expectLetGo(io);

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
    client.deinit();
    try Waiter.expectLetGo(io);
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

/// Counts the bytes allocated and not yet freed.
const LiveAllocator = struct {
    inner: std.mem.Allocator,
    live: std.atomic.Value(isize) = .init(0),
    peak: std.atomic.Value(isize) = .init(0),

    fn grew(self: *LiveAllocator, by: isize) void {
        const now = self.live.fetchAdd(by, .monotonic) + by;
        _ = self.peak.fetchMax(now, .monotonic);
    }

    fn allocator(self: *LiveAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *LiveAllocator = @ptrCast(@alignCast(ctx));
        const p = self.inner.rawAlloc(len, alignment, ra) orelse return null;
        self.grew(@intCast(len));
        return p;
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *LiveAllocator = @ptrCast(@alignCast(ctx));
        if (!self.inner.rawResize(memory, alignment, new_len, ra)) return false;
        self.grew(@as(isize, @intCast(new_len)) - @as(isize, @intCast(memory.len)));
        return true;
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *LiveAllocator = @ptrCast(@alignCast(ctx));
        const p = self.inner.rawRemap(memory, alignment, new_len, ra) orelse return null;
        self.grew(@as(isize, @intCast(new_len)) - @as(isize, @intCast(memory.len)));
        return p;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *LiveAllocator = @ptrCast(@alignCast(ctx));
        self.inner.rawFree(memory, alignment, ra);
        _ = self.live.fetchSub(@intCast(memory.len), .monotonic);
    }
};

/// Streams whose head the server refuses: a header list past the limit,
/// and two host fields (refused by nghttp2's own checks).
fn sendRefusedHeads(client: *TestClient, n: usize) !void {
    const big: [1500]u8 = @splat('x');
    for (0..n) |i| {
        if (i % 2 == 0) {
            _ = try client.requestWith("/hello", "localhost", &.{ TestClient.nv("x-a", &big), TestClient.nv("x-b", &big) });
        } else {
            _ = try client.requestWith("/hello", null, &.{ TestClient.nv("host", "a.example"), TestClient.nv("x-a", &big), TestClient.nv("host", "b.example") });
        }
    }
    try client.run();
}

test "HTTP/2: a stream whose head is refused is freed when it closes, not with the connection" {
    const io = std.testing.io;
    var live: LiveAllocator = .{ .inner = std.testing.allocator };
    var server = dusty.Server(void).init(live.allocator(), io, .{
        .listeners = &.{.{ .address = loopback_addr, .http2_prior_knowledge = true }},
        // The refusal budget is the next test's.
        .http2 = .{ .max_header_list_size = 2048, .refused_stream_burst = 1000 },
    }, {});
    defer server.deinit();
    server.router.get("/hello", Handlers.hello);
    var future = try io.concurrent(Fixture.run, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, server.address.ip);
    defer client.deinit();
    // The first round fills the connection's spare streams.
    try sendRefusedHeads(&client, 40);
    const before = live.live.load(.monotonic);
    try sendRefusedHeads(&client, 80);
    const after = live.live.load(.monotonic);
    try std.testing.expect(after - before < 32 * 1024);
    // The connection still serves.
    const ok = try client.request("GET", "/hello", null);
    try client.run();
    try std.testing.expectEqualStrings("hello", client.get(ok).body.items);
}

test "HTTP/2: a peer whose streams keep being refused is sent GOAWAY(ENHANCE_YOUR_CALM)" {
    const io = std.testing.io;
    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .listeners = &.{.{ .address = loopback_addr, .http2_prior_knowledge = true }},
        .http2 = .{ .max_header_list_size = 2048, .refused_stream_burst = 20, .refused_stream_rate = 1 },
    }, {});
    defer server.deinit();
    server.router.get("/hello", Handlers.hello);
    var future = try io.concurrent(Fixture.run, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, server.address.ip);
    defer client.deinit();
    sendRefusedHeads(&client, 60) catch {};
    try client.runUntilClosed();
    try std.testing.expect(client.goaway_count >= 1);
    try std.testing.expectEqual(@as(u32, c.NGHTTP2_ENHANCE_YOUR_CALM), client.goaway_error);
}

test "HTTP/2: a finished response the peer never takes is reset at the request timeout" {
    const io = std.testing.io;
    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .listeners = &.{.{ .address = loopback_addr, .http2_prior_knowledge = true }},
        .timeout = .{ .request = .fromMilliseconds(300) },
    }, {});
    defer server.deinit();
    server.router.get("/whole", struct {
        const body: [100 * 1024]u8 = @splat('z');
        fn handle(_: *dusty.Request, res: *dusty.Response) !void {
            res.body = &body;
        }
    }.handle);
    var future = try io.concurrent(Fixture.run, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, server.address.ip);
    defer client.deinit();
    // A stream window of zero: the server may send the head, never the body.
    const zero = [_]c.nghttp2_settings_entry{.{ .settings_id = c.NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE, .value = 0 }};
    if (c.nghttp2_submit_settings(client.session, c.NGHTTP2_FLAG_NONE, &zero, zero.len) != 0) return error.Http2Init;
    // The request timeout (300 ms) ends the stream; without it, only the
    // keep-alive timeout (60 s) would, which only test-timing tells apart.
    const started: std.Io.Clock.Timestamp = .now(io, .awake);
    const id = try client.request("GET", "/whole", null);
    try client.run();
    try std.testing.expectEqual(@as(u32, c.NGHTTP2_CANCEL), client.get(id).error_code);
    if (wait.timing()) try std.testing.expect(started.durationTo(.now(io, .awake)).raw.toMilliseconds() < 3000);
    try awaitStreamsFreed(&server, io);
}

test "HTTP/2: the raised body windows of a connection share one budget" {
    const io = std.testing.io;
    var live: LiveAllocator = .{ .inner = std.testing.allocator };
    var server = dusty.Server(void).init(live.allocator(), io, .{
        .listeners = &.{.{ .address = loopback_addr, .http2_prior_knowledge = true }},
        .http2 = .{ .reading_window_budget = 1024 * 1024 },
    }, {});
    defer server.deinit();
    server.router.post("/late", Handlers.late);
    var future = try io.concurrent(Fixture.run, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, server.address.ip);
    defer client.deinit();
    const body = try std.testing.allocator.alloc(u8, 300 * 1024);
    defer std.testing.allocator.free(body);
    for (body, 0..) |*b, i| b.* = @truncate(i *% 7);
    var ids: [8]i32 = undefined;
    for (&ids) |*id| id.* = try client.request("POST", "/late", body);
    // The eight handlers read only once all of them have started and each
    // stream has a window of its body sent: they raise their windows
    // together.
    Handlers.late_gate = .unset;
    var resps: [ids.len]*const TestClient.Resp = undefined;
    for (&resps, ids) |*r, id| r.* = client.get(id);
    const gate: SentGate = .{
        .resps = &resps,
        .n = default_window,
        .entered = &Handlers.late_entered,
        .want = Handlers.late_entered.load(.acquire) + @as(u32, ids.len),
    };
    var releaser = try io.concurrent(SentGate.release, .{ io, &gate, &Handlers.late_gate });
    defer releaser.cancel(io) catch {};
    try client.run();
    try releaser.await(io);
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(std.testing.allocator);
    try want.print(std.testing.allocator, "{d} {x}", .{ body.len, std.hash.Wyhash.hash(0, body) });
    for (ids) |id| try std.testing.expectEqualStrings(want.items, client.get(id).body.items);
    // Eight streams reading at once would raise eight 1 MiB windows.
    try std.testing.expect(live.peak.load(.monotonic) < 4 * 1024 * 1024);
}

test "HTTP/2: an event stream outlives timeouts.request" {
    const io = std.testing.io;
    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .listeners = &.{.{ .address = loopback_addr, .http2_prior_knowledge = true }},
        .timeout = .{ .request = .fromMilliseconds(100), .write = .fromSeconds(5) },
    }, {});
    defer server.deinit();
    server.router.get("/slow", struct {
        // Time passing on purpose (TESTING.md D1, margin >= 5x): sleeps are
        // lower bounds, so the stream lives at least 6 x 100 ms = 600 ms,
        // 6x the 100 ms request timeout, on any machine.
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            var buf: [256]u8 = undefined;
            var events = try res.startEventStream(&buf);
            for (0..6) |_| {
                try events.send("tick", .{});
                try req.io.sleep(.fromMilliseconds(100), .awake);
            }
            try events.end();
        }
    }.handle);
    var future = try io.concurrent(Fixture.run, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, server.address.ip);
    defer client.deinit();
    const id = try client.request("GET", "/slow", null);
    try client.run();
    try std.testing.expectEqual(@as(u16, 200), client.get(id).status);
    try std.testing.expectEqual(@as(usize, 6), std.mem.count(u8, client.get(id).body.items, "data: tick"));
}

/// A parked response (`Response._park`): the handler returns, and bursts
/// from any task write DATA.
const ParkProbe = struct {
    var parked: ?*dusty.Parked = null;
    var opened: std.Io.Event = .unset;
    var gone: std.Io.Event = .unset;
    var gone_calls: std.atomic.Value(u32) = .init(0);

    fn reset() void {
        parked = null;
        opened = .unset;
        gone = .unset;
        gone_calls.store(0, .monotonic);
    }

    fn onGone(_: *anyopaque) void {
        _ = gone_calls.fetchAdd(1, .monotonic);
        gone.set(std.testing.io);
    }

    /// Waits first, as a handler that talks to a database before it parks.
    fn handle(req: *dusty.Request, res: *dusty.Response) !void {
        try req.io.sleep(.fromMilliseconds(1), .awake);
        try res.header("Content-Type", "text/event-stream");
        var dummy: u8 = 0;
        parked = try res._park(req, .{ .gone = onGone, .ctx = &dummy });
        opened.set(req.io);
    }

    fn flushClient(client: *TestClient) !void {
        while (true) {
            var data: [*c]const u8 = undefined;
            const n = c.nghttp2_session_mem_send2(client.session, &data);
            if (n <= 0) break;
            try client.w.writeAll(data[0..@intCast(n)]);
        }
        try client.w.flush();
    }
};

test "parked h2: a handler that waited first parks; bursts arrive as DATA; end finishes the stream and release frees it" {
    const io = std.testing.io;
    ParkProbe.reset();
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);
    fx.server.router.get("/live", ParkProbe.handle);

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    const id = try client.request("GET", "/live", null);
    try ParkProbe.flushClient(&client);
    try wait.waitEvent(io, "the handler parked", &ParkProbe.opened);
    const p = ParkProbe.parked.?;
    try std.testing.expect(p.begin());
    try p.write(&.{ "id: 1\n", "data: a\n\n" });
    p.endBurst();
    try std.testing.expect(p.begin());
    try p.write(&.{"data: b\n\n"});
    p.end();
    try client.run();
    try std.testing.expectEqual(@as(u16, 200), client.get(id).status);
    try std.testing.expectEqualStrings("id: 1\ndata: a\n\ndata: b\n\n", client.get(id).body.items);
    try std.testing.expectEqual(@as(u32, c.NGHTTP2_NO_ERROR), client.get(id).error_code);
    try std.testing.expect(!p.begin());
    p.release();
    // The stream is freed (the fixture's allocator checks the rest).
    const next = try client.request("GET", "/hello", null);
    try client.run();
    try std.testing.expectEqualStrings("hello", client.get(next).body.items);
    try std.testing.expectEqual(@as(u32, 0), ParkProbe.gone_calls.load(.monotonic));
}

test "parked h2: RST_STREAM tells the owner once; release frees the stream" {
    const io = std.testing.io;
    ParkProbe.reset();
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);
    fx.server.router.get("/live", ParkProbe.handle);

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    const id = try client.request("GET", "/live", null);
    try ParkProbe.flushClient(&client);
    try wait.waitEvent(io, "the handler parked", &ParkProbe.opened);
    _ = c.nghttp2_submit_rst_stream(client.session, c.NGHTTP2_FLAG_NONE, id, c.NGHTTP2_CANCEL);
    try ParkProbe.flushClient(&client);
    try wait.waitEvent(io, "the parked stream's owner was told it is gone", &ParkProbe.gone);
    try std.testing.expectEqual(@as(u32, 1), ParkProbe.gone_calls.load(.monotonic));
    try std.testing.expect(!ParkProbe.parked.?.begin());
    ParkProbe.parked.?.release();
    const next = try client.request("GET", "/hello", null);
    try client.run();
    try std.testing.expectEqualStrings("hello", client.get(next).body.items);
}

test "parked h2: the connection closing with a parked stream tells the owner, and teardown waits for release" {
    const io = std.testing.io;
    ParkProbe.reset();
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);
    fx.server.router.get("/live", ParkProbe.handle);

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    _ = try client.request("GET", "/live", null);
    try ParkProbe.flushClient(&client);
    try wait.waitEvent(io, "the handler parked", &ParkProbe.opened);
    client.deinit();
    try wait.waitEvent(io, "the parked stream's owner was told it is gone", &ParkProbe.gone);
    try std.testing.expectEqual(@as(u32, 1), ParkProbe.gone_calls.load(.monotonic));
    ParkProbe.parked.?.release();
}

test "parked h2: the connection closing with a burst blocked on a full outbox: the burst fails, gone comes after it, teardown waits for release" {
    const io = std.testing.io;
    ParkProbe.reset();
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);
    fx.server.router.get("/live", ParkProbe.handle);

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    _ = try client.request("GET", "/live", null);
    try ParkProbe.flushClient(&client);
    try wait.waitEvent(io, "the handler parked", &ParkProbe.opened);

    // The client reads nothing: no WINDOW_UPDATE, so past the stream's
    // window and the 1 MiB outbox the burst waits for room.
    const Writer = struct {
        written: std.atomic.Value(u32) = .init(0),
        failed: ?dusty.Parked.WriteError = null,
        gone_before_end: u32 = 0,
        /// The burst is over (set last, on every way out).
        done: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This(), p: *dusty.Parked) void {
            defer self.done.store(true, .release);
            if (!p.begin()) return;
            const chunk: [16 * 1024]u8 = @splat('x');
            while (true) {
                p.write(&.{&chunk}) catch |err| {
                    self.failed = err;
                    break;
                };
                _ = self.written.fetchAdd(1, .release);
            }
            // No `gone` during the burst: it is deferred to its end.
            self.gone_before_end = ParkProbe.gone_calls.load(.acquire);
            p.endBurst();
        }
    };
    var w: Writer = .{};
    var writing = try io.concurrent(Writer.run, .{ &w, ParkProbe.parked.? });
    // A failed wait ends the burst (its write is cancelable) before `w`
    // goes; after the await below this does nothing.
    defer writing.cancel(io);
    // 1 MiB + 64 KiB fills the outbox and the window: wait until most of it
    // is written, then close the connection under the waiting burst.
    try wait.waitAtLeast(io, "most of the burst written", &w.written, 66);
    client.deinit();
    try wait.waitFlag(io, "the blocked burst failed and ended", &w.done);
    writing.await(io);
    try std.testing.expect(w.failed != null);
    try std.testing.expectEqual(@as(u32, 0), w.gone_before_end);
    try wait.waitEvent(io, "the parked stream's owner was told it is gone", &ParkProbe.gone);
    try std.testing.expectEqual(@as(u32, 1), ParkProbe.gone_calls.load(.monotonic));
    try std.testing.expect(!ParkProbe.parked.?.begin());
    ParkProbe.parked.?.release();
}

/// A park that fails inside the handler (the peer reset the stream first):
/// the park finishes the exchange, the handler returns the error, and the
/// stream is let go exactly once, by `serveStream`'s caller.
const FailedPark = struct {
    var result: ?anyerror = null;
    var started: std.Io.Event = .unset;
    var done: std.Io.Event = .unset;

    fn handle(req: *dusty.Request, res: *dusty.Response) !void {
        const io = req.io;
        started.set(io);
        const prev = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(prev);
        // Wait for the reset (the body reader reports it), so the park
        // meets a reset stream.
        const body = req._body_source.?.reader;
        wait.waitUntil(io, "the body reader reports the reset", body, struct {
            fn f(r: *std.Io.Reader) bool {
                var buf: [1]u8 = undefined;
                _ = r.readSliceShort(&buf) catch return true;
                return false;
            }
        }.f) catch |err| {
            result = err;
            done.set(io);
            return err;
        };
        try res.header("Content-Type", "text/event-stream");
        var dummy: u8 = 0;
        const p = res._park(req, .{ .gone = ParkProbe.onGone, .ctx = &dummy }) catch |err| {
            result = err;
            done.set(io);
            return err;
        };
        p.release();
        result = null;
        done.set(io);
    }
};

test "parked h2: a park that fails on a reset stream lets go of the stream once" {
    const io = std.testing.io;
    ParkProbe.reset();
    FailedPark.result = null;
    FailedPark.done = .unset;
    FailedPark.started = .unset;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);
    fx.server.router.get("/live", FailedPark.handle);

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    const id = try client.request("GET", "/live", null);
    try ParkProbe.flushClient(&client);
    try wait.waitEvent(io, "the failing park's handler started", &FailedPark.started);
    _ = c.nghttp2_submit_rst_stream(client.session, c.NGHTTP2_FLAG_NONE, id, c.NGHTTP2_CANCEL);
    try ParkProbe.flushClient(&client);
    try wait.waitEvent(io, "the failing park's handler finished", &FailedPark.done);
    try std.testing.expectEqual(@as(?anyerror, error.WriteFailed), FailedPark.result);
    // The connection serves on (a double release would have broken its
    // stream count), and the fixture's allocator checks the rest.
    const next = try client.request("GET", "/hello", null);
    try client.run();
    try std.testing.expectEqualStrings("hello", client.get(next).body.items);
    try std.testing.expectEqual(@as(u32, 0), ParkProbe.gone_calls.load(.monotonic));
}
