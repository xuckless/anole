//! An HTTP/2 client connection on nghttp2: many concurrent streams over one
//! TCP connection, cleartext (prior knowledge) or TLS with ALPN "h2". The
//! shape follows the server engine in the dusty fork: a reader task feeds
//! the session, a writer task drains it, one mutex serializes every
//! nghttp2 call, and nothing blocks while holding it.
//!
//!     var conn = try anole.h2.ClientConnection.connect(gpa, io, .{ .host = "127.0.0.1", .port = 8080 });
//!     defer conn.close();
//!     const s = try conn.request(&.{
//!         .{ .name = ":method", .value = "GET" },  .{ .name = ":path", .value = "/" },
//!         .{ .name = ":scheme", .value = "http" }, .{ .name = ":authority", .value = "localhost" },
//!     }, .{});
//!     defer s.release();
//!     try s.waitHead();
//!     const body = try s.reader().allocRemaining(gpa, .unlimited);
//!
//! A stream's request body is written through `writer()` and ended with
//! `closeSend()`; its response body is read through `reader()`, and the
//! trailers are in `trailers` once that reports the end.
const std = @import("std");
const c = @import("anole_nghttp2_c");
const features = @import("build_options");
const tls = if (features.tls == .boringssl) @import("anole_dusty_tls") else struct {};
const placement = @import("dusty").placement;

pub const Header = struct { name: []const u8, value: []const u8 };

pub const ConnectOptions = struct {
    /// The server's name (for TLS: SNI and certificate checks) or address.
    host: []const u8,
    port: u16,
    /// Connect here instead of resolving `host`.
    address: ?std.Io.net.IpAddress = null,
    /// TLS with ALPN "h2"; null for cleartext HTTP/2 (prior knowledge).
    tls: ?Tls = null,
    /// Bytes a stream may receive before the reader takes them; also the
    /// size of each stream's receive queue.
    stream_window: u31 = 64 * 1024,

    pub const Tls = struct {
        root_ca: std.crypto.Certificate.Bundle = .empty,
        insecure_skip_verify: bool = false,
        /// A certificate (and key, PEM) to present when the server asks
        /// for one: mutual TLS.
        certificate: ?Identity = null,
    };

    /// A certificate chain (leaf first) and its private key, in PEM.
    pub const Identity = struct { cert_pem: []const u8, key_pem: []const u8 };
};

pub const Error = error{ ConnectionClosed, StreamReset, NoH2, OutOfMemory, Unexpected };

pub const ClientConnection = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    socket: std.Io.net.Stream,
    read_buf: [32 * 1024]u8 = undefined,
    write_buf: [32 * 1024]u8 = undefined,
    tcp_reader: std.Io.net.Stream.Reader = undefined,
    tcp_writer: std.Io.net.Stream.Writer = undefined,
    tls_conn: if (features.tls == .boringssl) ?tls.Connection else void = if (features.tls == .boringssl) null else {},
    tls_reader: if (features.tls == .boringssl) tls.Connection.Reader else void = undefined,
    tls_writer: if (features.tls == .boringssl) tls.Connection.Writer else void = undefined,
    tls_read_buf: [16 * 1024]u8 = undefined,
    tls_write_buf: [16 * 1024]u8 = undefined,
    r: *std.Io.Reader = undefined,
    w: *std.Io.Writer = undefined,
    stream_window: u31,

    /// Serializes every nghttp2 call and guards what follows.
    mutex: std.Io.Mutex = .init,
    session: ?*c.nghttp2_session = null,
    /// The connection is going or gone: no new streams.
    closing: bool = false,
    /// Why it went, when it failed.
    failure: ?anyerror = null,
    write_gen: std.atomic.Value(u32) = .init(0),
    group: std.Io.Group = .init,
    /// Streams the caller still holds or nghttp2 still knows.
    live: std.DoublyLinkedList = .{},

    pub fn connect(gpa: std.mem.Allocator, io: std.Io, options: ConnectOptions) !*ClientConnection {
        const self = try gpa.create(ClientConnection);
        errdefer gpa.destroy(self);
        const socket = if (options.address) |a|
            try a.connect(io, .{ .mode = .stream })
        else if (std.Io.net.IpAddress.parse(options.host, options.port)) |a|
            try a.connect(io, .{ .mode = .stream })
        else |_|
            try (try std.Io.net.HostName.init(options.host)).connect(io, options.port, .{ .mode = .stream });
        self.* = .{ .gpa = gpa, .io = io, .socket = socket, .stream_window = options.stream_window };
        errdefer self.socket.close(io);
        self.tcp_reader = self.socket.reader(io, &self.read_buf);
        self.tcp_writer = self.socket.writer(io, &self.write_buf);
        self.r = &self.tcp_reader.interface;
        self.w = &self.tcp_writer.interface;
        if (options.tls) |t| {
            if (comptime features.tls != .boringssl) return error.TlsNotBuilt;
            var rng: std.Random.IoSource = .{ .io = io };
            // The handshake takes its own references to the certificate
            // and key.
            var identity: ?tls.config.CertKeyPair = if (t.certificate) |id|
                try tls.config.CertKeyPair.fromSlice(gpa, io, id.cert_pem, id.key_pem)
            else
                null;
            defer if (identity) |*id| id.deinit(gpa);
            self.tls_conn = try tls.client(&self.tcp_reader.interface, &self.tcp_writer.interface, .{
                .host = options.host,
                .root_ca = t.root_ca,
                .insecure_skip_verify = t.insecure_skip_verify,
                .auth = if (identity) |*id| id else null,
                .now = std.Io.Clock.real.now(io),
                .rng = rng.interface(),
                .alpn_protocols = &.{"h2"},
            });
            if (!std.mem.eql(u8, self.tls_conn.?.alpn_protocol orelse "", "h2")) return error.NoH2;
            self.tls_reader = self.tls_conn.?.reader(&self.tls_read_buf);
            self.tls_writer = self.tls_conn.?.writer(&self.tls_write_buf);
            self.r = &self.tls_reader.interface;
            self.w = &self.tls_writer.interface;
        }
        try self.initSession();
        // On the caller's executor, as every task of a connection is.
        try placement.concurrent(&self.group, io, .local, readerLoop, .{self});
        try placement.concurrent(&self.group, io, .local, writerLoop, .{self});
        return self;
    }

    fn initSession(self: *ClientConnection) !void {
        var cbs: ?*c.nghttp2_session_callbacks = null;
        if (c.nghttp2_session_callbacks_new(&cbs) != 0) return error.OutOfMemory;
        defer c.nghttp2_session_callbacks_del(cbs);
        c.nghttp2_session_callbacks_set_on_header_callback(cbs, onHeader);
        c.nghttp2_session_callbacks_set_on_frame_recv_callback(cbs, onFrameRecv);
        c.nghttp2_session_callbacks_set_on_data_chunk_recv_callback(cbs, onData);
        c.nghttp2_session_callbacks_set_on_stream_close_callback(cbs, onStreamClose);
        var option: ?*c.nghttp2_option = null;
        if (c.nghttp2_option_new(&option) != 0) return error.OutOfMemory;
        defer c.nghttp2_option_del(option);
        // Window credit goes back as the reader takes bytes, so a stream's
        // queue never overflows.
        c.nghttp2_option_set_no_auto_window_update(option, 1);
        if (c.nghttp2_session_client_new2(&self.session, cbs, self, option) != 0) return error.OutOfMemory;
        const iv = [_]c.nghttp2_settings_entry{
            .{ .settings_id = c.NGHTTP2_SETTINGS_ENABLE_PUSH, .value = 0 },
            .{ .settings_id = c.NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE, .value = self.stream_window },
        };
        if (c.nghttp2_submit_settings(self.session, c.NGHTTP2_FLAG_NONE, &iv, iv.len) != 0) return error.OutOfMemory;
        // A connection window big enough for several busy streams.
        _ = c.nghttp2_session_set_local_window_size(self.session, c.NGHTTP2_FLAG_NONE, 0, 1 << 24);
    }

    /// Sends GOAWAY, waits for the reader and writer, and frees everything.
    /// Streams still open fail with `ConnectionClosed`.
    pub fn close(self: *ClientConnection) void {
        {
            self.lock();
            defer self.unlock();
            if (!self.closing) {
                self.closing = true;
                _ = c.nghttp2_session_terminate_session(self.session, c.NGHTTP2_NO_ERROR);
            }
        }
        self.kickWriter();
        self.group.await(self.io) catch {};
        {
            self.lock();
            defer self.unlock();
            c.nghttp2_session_del(self.session);
            self.session = null;
        }
        if (comptime features.tls == .boringssl) if (self.tls_conn) |*t| t.deinit();
        self.socket.close(self.io);
        self.gpa.destroy(self);
    }

    fn lock(self: *ClientConnection) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *ClientConnection) void {
        self.mutex.unlock(self.io);
    }

    fn kickWriter(self: *ClientConnection) void {
        _ = self.write_gen.fetchAdd(1, .release);
        self.io.futexWake(u32, &self.write_gen.raw, std.math.maxInt(u32));
    }

    pub const RequestOptions = struct {
        /// The request has a body, written through `Stream.writer` and
        /// ended with `Stream.closeSend`.
        body: bool = false,
    };

    /// Opens a stream. `headers` holds the pseudo-headers first, names in
    /// lower case; they are copied.
    pub fn request(self: *ClientConnection, headers: []const Header, options: RequestOptions) !*Stream {
        const stream = try Stream.create(self, options.body);
        errdefer stream.destroy();
        const nva = try self.gpa.alloc(c.nghttp2_nv, headers.len);
        defer self.gpa.free(nva);
        for (headers, nva) |h, *nv| nv.* = .{
            .name = @constCast(h.name.ptr),
            .namelen = h.name.len,
            .value = @constCast(h.value.ptr),
            .valuelen = h.value.len,
            .flags = c.NGHTTP2_NV_FLAG_NONE,
        };
        {
            self.lock();
            defer self.unlock();
            if (self.closing) return error.ConnectionClosed;
            var provider: c.nghttp2_data_provider2 = .{ .source = .{ .ptr = stream }, .read_callback = provideData };
            const id = c.nghttp2_submit_request2(self.session, null, nva.ptr, nva.len, if (options.body) &provider else null, stream);
            if (id < 0) return error.Unexpected;
            stream.id = id;
            stream.submitted = true;
        }
        self.kickWriter();
        return stream;
    }

    fn readerLoop(self: *ClientConnection) std.Io.Cancelable!void {
        const err = self.runReader();
        self.lock();
        self.closing = true;
        if (self.failure == null) self.failure = err;
        self.unlock();
        self.failAll();
        self.kickWriter();
    }

    fn runReader(self: *ClientConnection) anyerror {
        while (true) {
            const buffered = self.r.buffered();
            if (buffered.len > 0) {
                self.lock();
                const rv = c.nghttp2_session_mem_recv2(self.session, buffered.ptr, buffered.len);
                const done = c.nghttp2_session_want_read(self.session) == 0 and c.nghttp2_session_want_write(self.session) == 0;
                self.unlock();
                if (rv < 0) return error.Http2ProtocolError;
                self.r.toss(@intCast(rv));
                self.kickWriter();
                if (done) return error.ConnectionClosed;
                continue;
            }
            self.r.fillMore() catch |e| return switch (e) {
                error.EndOfStream => error.ConnectionClosed,
                error.ReadFailed => error.ConnectionClosed,
            };
        }
    }

    /// Ends every stream still waiting, as the connection is gone.
    fn failAll(self: *ClientConnection) void {
        self.lock();
        defer self.unlock();
        var it = self.live.first;
        while (it) |node| : (it = node.next) {
            const stream: *Stream = @fieldParentPtr("node", node);
            stream.finishLocked(true);
        }
    }

    fn writerLoop(self: *ClientConnection) std.Io.Cancelable!void {
        var staging: std.ArrayList(u8) = .empty;
        defer staging.deinit(self.gpa);
        while (true) {
            const gen = self.write_gen.load(.acquire);
            var closing = false;
            var finished = false;
            {
                self.lock();
                defer self.unlock();
                closing = self.closing;
                while (staging.items.len < 64 * 1024) {
                    var data: [*c]const u8 = undefined;
                    const n = c.nghttp2_session_mem_send2(self.session, &data);
                    if (n <= 0) break;
                    staging.appendSlice(self.gpa, data[0..@intCast(n)]) catch break;
                }
                finished = c.nghttp2_session_want_read(self.session) == 0 and c.nghttp2_session_want_write(self.session) == 0;
            }
            if (staging.items.len > 0) {
                self.w.writeAll(staging.items) catch return self.writeFailed();
                self.w.flush() catch return self.writeFailed();
                staging.clearRetainingCapacity();
                continue;
            }
            if (finished or closing) {
                // Ends the reader's wait too.
                self.socket.shutdown(self.io, .both) catch {};
                return;
            }
            try self.io.futexWait(u32, &self.write_gen.raw, gen);
        }
    }

    fn writeFailed(self: *ClientConnection) void {
        self.lock();
        self.closing = true;
        if (self.failure == null) self.failure = error.ConnectionClosed;
        self.unlock();
        self.socket.shutdown(self.io, .both) catch {};
    }

    fn streamFrom(session: ?*c.nghttp2_session, id: i32) ?*Stream {
        const p = c.nghttp2_session_get_stream_user_data(session, id) orelse return null;
        return @ptrCast(@alignCast(p));
    }

    fn onHeader(session: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, name: [*c]const u8, namelen: usize, value: [*c]const u8, valuelen: usize, _: u8, _: ?*anyopaque) callconv(.c) c_int {
        const stream = streamFrom(session, frame.*.hd.stream_id) orelse return 0;
        const n = name[0..namelen];
        const v = value[0..valuelen];
        const arena = stream.arena.allocator();
        if (frame.*.headers.cat == c.NGHTTP2_HCAT_RESPONSE) {
            if (std.mem.eql(u8, n, ":status")) {
                stream.status = std.fmt.parseInt(u16, v, 10) catch 0;
                return 0;
            }
            stream.headers.append(arena, .{
                .name = arena.dupe(u8, n) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE,
                .value = arena.dupe(u8, v) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE,
            }) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
        } else if (frame.*.headers.cat == c.NGHTTP2_HCAT_HEADERS and stream.head_ready) {
            stream.trailers.append(arena, .{
                .name = arena.dupe(u8, n) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE,
                .value = arena.dupe(u8, v) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE,
            }) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
        }
        return 0;
    }

    fn onFrameRecv(session: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, user: ?*anyopaque) callconv(.c) c_int {
        const self: *ClientConnection = @ptrCast(@alignCast(user.?));
        const hd = frame.*.hd;
        if (hd.type == c.NGHTTP2_GOAWAY) {
            // Streams above the last one taken never ran; nghttp2 closes
            // them. No new ones from here.
            self.closing = true;
            return 0;
        }
        const stream = streamFrom(session, hd.stream_id) orelse return 0;
        const end = hd.flags & c.NGHTTP2_FLAG_END_STREAM != 0;
        switch (hd.type) {
            c.NGHTTP2_HEADERS => {
                if (frame.*.headers.cat == c.NGHTTP2_HCAT_RESPONSE and stream.status >= 200) {
                    stream.head_ready = true;
                    stream.head_event.set(self.io);
                } else if (frame.*.headers.cat == c.NGHTTP2_HCAT_RESPONSE) {
                    // 1xx: its fields are not the response's.
                    stream.headers.clearRetainingCapacity();
                    stream.status = 0;
                }
                if (end) stream.body.close(self.io);
            },
            c.NGHTTP2_DATA => if (end) stream.body.close(self.io),
            else => {},
        }
        return 0;
    }

    fn onData(session: ?*c.nghttp2_session, _: u8, id: i32, data: [*c]const u8, len: usize, _: ?*anyopaque) callconv(.c) c_int {
        const stream = streamFrom(session, id) orelse return 0;
        // The window is the queue's size, so this fits.
        const n = stream.body.putUncancelable(stream.conn.io, data[0..len], 0) catch 0;
        if (n < len) _ = c.nghttp2_session_consume(session, id, len - n);
        return 0;
    }

    fn onStreamClose(session: ?*c.nghttp2_session, id: i32, code: u32, _: ?*anyopaque) callconv(.c) c_int {
        const stream = streamFrom(session, id) orelse return 0;
        stream.error_code = code;
        stream.finishLocked(code != c.NGHTTP2_NO_ERROR);
        stream.protocol_done = true;
        _ = c.nghttp2_session_set_stream_user_data(session, id, null);
        stream.maybeFree();
        return 0;
    }

    fn provideData(_: ?*c.nghttp2_session, _: i32, buf: [*c]u8, length: usize, flags: [*c]u32, source: [*c]c.nghttp2_data_source, _: ?*anyopaque) callconv(.c) c.nghttp2_ssize {
        const stream: *Stream = @ptrCast(@alignCast(source.*.ptr.?));
        const n = stream.out.getUncancelable(stream.conn.io, buf[0..length], 0) catch 0;
        if (n == 0) {
            if (!stream.send_closed) return c.NGHTTP2_ERR_DEFERRED;
            flags.* |= c.NGHTTP2_DATA_FLAG_EOF;
        }
        return @intCast(n);
    }
};

/// One request and its response.
pub const Stream = struct {
    conn: *ClientConnection,
    id: i32 = -1,
    node: std.DoublyLinkedList.Node = .{},
    arena: std.heap.ArenaAllocator,
    submitted: bool = false,

    status: u16 = 0,
    headers: std.ArrayList(Header) = .empty,
    trailers: std.ArrayList(Header) = .empty,
    head_ready: bool = false,
    head_event: std.Io.Event = .unset,
    /// The stream ended badly (RST_STREAM, or the connection went).
    reset: bool = false,
    error_code: u32 = 0,

    body: std.Io.Queue(u8),
    body_reader: std.Io.Reader,
    out: std.Io.Queue(u8),
    out_writer: std.Io.Writer,
    send_closed: bool = false,

    /// Both the caller (`release`) and nghttp2 (stream close) are done.
    user_done: bool = false,
    protocol_done: bool = false,

    fn create(conn: *ClientConnection, has_body: bool) !*Stream {
        const self = try conn.gpa.create(Stream);
        errdefer conn.gpa.destroy(self);
        self.* = .{
            .conn = conn,
            .arena = .init(conn.gpa),
            .body = undefined,
            .body_reader = .{ .buffer = &.{}, .seek = 0, .end = 0, .vtable = &.{ .stream = readBody } },
            .out = undefined,
            .out_writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drainOut, .flush = flushOut } },
            .send_closed = !has_body,
        };
        const a = self.arena.allocator();
        self.body = .init(try a.alloc(u8, conn.stream_window));
        self.out = .init(try a.alloc(u8, 32 * 1024));
        self.body_reader.buffer = try a.alloc(u8, 16 * 1024);
        self.out_writer.buffer = try a.alloc(u8, 16 * 1024);
        conn.lock();
        conn.live.append(&self.node);
        conn.unlock();
        return self;
    }

    fn destroy(self: *Stream) void {
        const conn = self.conn;
        conn.lock();
        conn.live.remove(&self.node);
        conn.unlock();
        self.arena.deinit();
        conn.gpa.destroy(self);
    }

    /// Under the connection's mutex: no more body, wake every waiter.
    fn finishLocked(self: *Stream, failed: bool) void {
        if (failed) self.reset = true;
        self.body.close(self.conn.io);
        self.out.close(self.conn.io);
        self.head_event.set(self.conn.io);
    }

    /// Under the connection's mutex: frees the stream when both sides let go.
    fn maybeFree(self: *Stream) void {
        if (!(self.user_done and self.protocol_done)) return;
        const conn = self.conn;
        conn.live.remove(&self.node);
        self.arena.deinit();
        conn.gpa.destroy(self);
    }

    /// Waits for the response head (`status`, `headers`).
    pub fn waitHead(self: *Stream) !void {
        try self.head_event.wait(self.conn.io);
        if (!self.head_ready) return if (self.reset) error.StreamReset else error.ConnectionClosed;
    }

    pub fn header(self: *const Stream, name: []const u8) ?[]const u8 {
        for (self.headers.items) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }

    pub fn trailer(self: *const Stream, name: []const u8) ?[]const u8 {
        for (self.trailers.items) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }

    /// The response body. `error.EndOfStream` at its end; then `trailers`
    /// are in. A reset stream fails the read.
    pub fn reader(self: *Stream) *std.Io.Reader {
        return &self.body_reader;
    }

    /// The request body (for a request opened with `.body = true`).
    /// `flush` sends what is written; `closeSend` ends it.
    pub fn writer(self: *Stream) *std.Io.Writer {
        return &self.out_writer;
    }

    /// Ends the request body (END_STREAM).
    pub fn closeSend(self: *Stream) !void {
        try self.out_writer.flush();
        const conn = self.conn;
        conn.lock();
        self.send_closed = true;
        if (self.submitted and !self.reset) _ = c.nghttp2_session_resume_data(conn.session, self.id);
        conn.unlock();
        conn.kickWriter();
    }

    /// Resets the stream (RST_STREAM CANCEL) if it is still open.
    pub fn cancel(self: *Stream) void {
        const conn = self.conn;
        conn.lock();
        defer conn.unlock();
        if (!self.protocol_done and self.submitted and conn.session != null) {
            _ = c.nghttp2_submit_rst_stream(conn.session, c.NGHTTP2_FLAG_NONE, self.id, c.NGHTTP2_CANCEL);
        }
        self.finishLocked(true);
        conn.kickWriter();
    }

    /// Done with the stream: an unfinished one is canceled first.
    pub fn release(self: *Stream) void {
        const conn = self.conn;
        conn.lock();
        const open = !self.protocol_done and self.submitted and conn.session != null and !conn.closing;
        conn.unlock();
        if (open) self.cancel();
        conn.lock();
        defer conn.unlock();
        self.user_done = true;
        // A stream nghttp2 never got, or one the connection's end left
        // behind, has no close to wait for.
        if (!self.submitted or conn.session == null or conn.closing) self.protocol_done = true;
        self.maybeFree();
    }

    fn readBody(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Stream = @alignCast(@fieldParentPtr("body_reader", r));
        const conn = self.conn;
        const dest = limit.slice(try w.writableSliceGreedy(1));
        if (dest.len == 0) return 0;
        const n = self.body.get(conn.io, dest, 1) catch |err| switch (err) {
            error.Closed => {
                conn.lock();
                const failed = self.reset;
                conn.unlock();
                return if (failed) error.ReadFailed else error.EndOfStream;
            },
            error.Canceled => return error.ReadFailed,
        };
        w.advance(n);
        conn.lock();
        if (conn.session != null and !self.protocol_done) _ = c.nghttp2_session_consume(conn.session, self.id, n);
        conn.unlock();
        conn.kickWriter();
        return n;
    }

    fn put(self: *Stream, bytes: []const u8) std.Io.Writer.Error!void {
        const conn = self.conn;
        var rest = bytes;
        while (rest.len > 0) {
            const n = self.out.put(conn.io, rest, 1) catch return error.WriteFailed;
            rest = rest[n..];
            conn.lock();
            if (self.submitted and !self.reset and !self.protocol_done) _ = c.nghttp2_session_resume_data(conn.session, self.id);
            conn.unlock();
            conn.kickWriter();
        }
    }

    fn drainOut(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Stream = @alignCast(@fieldParentPtr("out_writer", w));
        try self.put(w.buffered());
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.put(bytes);
            n += bytes.len;
        }
        for (0..splat) |_| try self.put(data[data.len - 1]);
        return n + data[data.len - 1].len * splat;
    }

    fn flushOut(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *Stream = @alignCast(@fieldParentPtr("out_writer", w));
        try self.put(w.buffered());
        w.end = 0;
    }
};
