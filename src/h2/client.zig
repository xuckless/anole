//! An HTTP/2 client connection on nghttp2: many concurrent streams over one
//! TCP connection, cleartext (prior knowledge) or TLS with ALPN "h2". The
//! shape follows the server engine in the the core fork: a reader task feeds
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
//!
//! Its own module (`anole_h2_client`), because the core's client takes it as
//! its `h2_client` import: when a server picks "h2" through ALPN, the core
//! hands the TLS connection over (`adopt`), so `anole.http.Client` speaks
//! HTTP/2 too.
const std = @import("std");
const c = @import("anole_nghttp2_c");
const options = @import("anole_h2_options");
const tls = if (options.tls) @import("anole_dusty_tls") else struct {};
const dusty = @import("dusty");
const placement = dusty.placement;
const Deadline = dusty.Deadline;

/// A header field: request fields (pseudo-headers first, lower-case
/// names) and the response's `headers` and `trailers`.
pub const Header = struct { name: []const u8, value: []const u8 };

/// Where and how `ClientConnection.connect` connects. `host` and `port`
/// are required; the rest has defaults. The fields mean the same as in
/// `anole.h3.ConnectOptions`, except where a field says it is HTTP/2's own.
pub const ConnectOptions = struct {
    /// The server's name (for TLS: SNI and certificate checks) or address.
    /// Or a Unix domain socket, named as gRPC names targets: "unix:/path"
    /// or "unix:///path"; on Linux also "unix-abstract:name". Calls then
    /// run cleartext (prior knowledge) with no TLS, and `port` is ignored.
    host: []const u8,
    port: u16,
    /// Connect here instead of resolving `host`.
    address: ?std.Io.net.IpAddress = null,
    /// TLS with ALPN "h2"; null for cleartext HTTP/2 (prior knowledge).
    /// HTTP/2 only: HTTP/3 always runs over TLS, so its `tls` is not
    /// optional.
    tls: ?Tls = null,
    /// Bytes the server may send on a stream before its reader takes them.
    /// 64 KiB here (256 KiB over HTTP/3) because each HTTP/2 stream
    /// allocates a receive queue of this size up front, where HTTP/3's
    /// grows as data arrives.
    stream_window: u31 = 64 * 1024,
    /// The same for the whole connection.
    max_data: u31 = 16 * 1024 * 1024,
    /// For `connect`: the TCP connection and the TLS handshake. Null for no
    /// limit. Past it, `connect` fails with `error.Timeout`.
    connect_timeout: ?std.Io.Duration = .fromSeconds(10),
    /// Each request's budget, from `request` to the end of the response
    /// body, unless its `RequestOptions.timeout` says otherwise. Null for
    /// no limit, which a long-lived stream wants.
    timeout: ?std.Io.Duration = .fromSeconds(30),
    /// The most a response's header fields may take, decoded (each field
    /// counts its name, its value and 32 bytes, as HTTP/2 counts them),
    /// informational responses and trailers included; advertised as
    /// SETTINGS_MAX_HEADER_LIST_SIZE. Past it the stream is reset and
    /// fails with `error.HeadersTooLarge`.
    max_header_list_size: u32 = default_max_header_list_size,

    /// The fields of `anole.http.TlsOptions`, with the same defaults.
    pub const Tls = struct {
        /// The certificate authorities the server's certificate must chain
        /// to. The system store (the default) is loaded on the first
        /// `connect` and kept for the process; a file, directory or PEM is
        /// read on every `connect`. `.none` only with `insecure_skip_verify`.
        ca: dusty.Ca = .system,
        /// A certificate to present when the server asks for one (mutual
        /// TLS): files or PEM in memory, read on every `connect`.
        client_certificate: ?dusty.Cert = null,
        /// Accept any certificate, for any name. For tests only.
        insecure_skip_verify: bool = false,
    };
};

/// `ConnectOptions.max_header_list_size` by default, and for `adopt`.
pub const default_max_header_list_size = 64 * 1024;

/// How many informational (1xx) responses may come before the final one,
/// as in the HTTP/1.1 client.
const max_interim_responses = 5;

/// Connection-level failures. `NoH2`: the TLS server did not pick "h2"
/// by ALPN.
pub const Error = error{ ConnectionClosed, StreamReset, NoH2, OutOfMemory, Unexpected };

/// Why a stream ended early: what `waitHead` returns, and what `readError`
/// and `writeError` say behind a `ReadFailed` or `WriteFailed`.
pub const StreamError = error{
    /// The server reset the stream (or refused it, after a GOAWAY).
    StreamReset,
    /// The connection failed or was closed.
    ConnectionClosed,
    /// The request's `timeout` passed; the stream was reset.
    Timeout,
    /// The stream was canceled (`cancel`, or the task waiting on it).
    Canceled,
    /// The response's header fields passed `max_header_list_size`; the
    /// stream was reset.
    HeadersTooLarge,
    /// More informational (1xx) responses than the client takes before a
    /// final one; the stream was reset.
    TooManyInterimResponses,
};

/// A Unix socket named as gRPC names targets.
pub const UnixTarget = struct {
    path: []const u8,
    /// Linux's abstract namespace ("unix-abstract:name").
    abstract: bool,
};

/// The socket a `ConnectOptions.host` of the form "unix:/path",
/// "unix:///path" or "unix-abstract:name" names; null for a host name.
pub fn unixTarget(host: []const u8) ?UnixTarget {
    if (std.mem.startsWith(u8, host, "unix-abstract:")) return .{ .path = host["unix-abstract:".len..], .abstract = true };
    if (!std.mem.startsWith(u8, host, "unix:")) return null;
    var rest = host["unix:".len..];
    if (std.mem.startsWith(u8, rest, "//")) rest = rest[2..];
    return .{ .path = rest, .abstract = false };
}

test "unixTarget parses gRPC's unix targets" {
    try std.testing.expectEqualStrings("/run/a.sock", unixTarget("unix:/run/a.sock").?.path);
    try std.testing.expectEqualStrings("/run/a.sock", unixTarget("unix:///run/a.sock").?.path);
    try std.testing.expectEqualStrings("rel.sock", unixTarget("unix:rel.sock").?.path);
    const a = unixTarget("unix-abstract:name").?;
    try std.testing.expect(a.abstract and std.mem.eql(u8, a.path, "name"));
    try std.testing.expect(unixTarget("localhost") == null);
    try std.testing.expect(unixTarget("unixhost") == null);
}

fn timeoutFrom(duration: ?std.Io.Duration) std.Io.Timeout {
    const d = duration orelse return .none;
    return .{ .duration = .{ .raw = d, .clock = .awake } };
}

/// An HTTP/2 client connection: `connect`, then `request` once per
/// request (concurrent ones share the connection, and several tasks may
/// make them at once), and `close`. See the file's example.
pub const ClientConnection = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Shut down by the writer when the session ends, to end the reader's
    /// wait. Closed by `close` only when `owned` (not after `adopt`).
    socket: std.Io.net.Stream,
    /// The socket's and the TLS layer's state, when `connect` made them.
    owned: ?*Owned,
    r: *std.Io.Reader,
    w: *std.Io.Writer,
    stream_window: u31,
    /// The connection's receive window (`ConnectOptions.max_data`).
    max_data: u31,
    max_header_list_size: u32,
    /// The default for `RequestOptions.timeout`.
    timeout: std.Io.Timeout,

    /// Serializes every nghttp2 call and guards what follows.
    mutex: std.Io.Mutex = .init,
    session: ?*c.nghttp2_session = null,
    /// The connection is going or gone: no new streams. A GOAWAY sets it,
    /// and the streams it covers carry on.
    closing: bool = false,
    /// The last stream ID the server's GOAWAY says it may have processed;
    /// above it, a stream never ran (`Stream.unprocessed`).
    goaway_last_id: i32 = std.math.maxInt(i32),
    /// The session is over: the reader has ended or a write failed. From
    /// here nothing calls into nghttp2 but `close`, so no callback can
    /// reach a stream any more.
    dead: bool = false,
    /// Why it went, when it failed.
    failure: ?anyerror = null,
    write_gen: std.atomic.Value(u32) = .init(0),
    group: std.Io.Group = .init,
    /// Streams the caller still holds or nghttp2 still knows.
    live: std.DoublyLinkedList = .{},

    const has_tls = options.tls;

    const Owned = struct {
        read_buf: [32 * 1024]u8 = undefined,
        write_buf: [32 * 1024]u8 = undefined,
        tcp_reader: std.Io.net.Stream.Reader = undefined,
        tcp_writer: std.Io.net.Stream.Writer = undefined,
        tls_conn: if (has_tls) ?tls.Connection else void = if (has_tls) null else {},
        tls_reader: if (has_tls) tls.Connection.Reader else void = undefined,
        tls_writer: if (has_tls) tls.Connection.Writer else void = undefined,
        tls_read_buf: [16 * 1024]u8 = undefined,
        tls_write_buf: [16 * 1024]u8 = undefined,
    };

    /// Connects (TCP, then TLS when `tls` is set) within `connect_timeout`
    /// and starts the reader and writer tasks on the caller's executor.
    pub fn connect(gpa: std.mem.Allocator, io: std.Io, opts: ConnectOptions) !*ClientConnection {
        const owned = try gpa.create(Owned);
        errdefer gpa.destroy(owned);
        owned.* = .{};
        if (opts.tls != null and unixTarget(opts.host) != null) return error.TlsOnUnixSocket;
        const deadline: Deadline = .init(io, timeoutFrom(opts.connect_timeout));
        const socket = try deadline.run(dial, .{ io, opts });
        errdefer socket.close(io);
        owned.tcp_reader = socket.reader(io, &owned.read_buf);
        owned.tcp_writer = socket.writer(io, &owned.write_buf);
        var r = &owned.tcp_reader.interface;
        var w = &owned.tcp_writer.interface;
        errdefer if (comptime has_tls) if (owned.tls_conn) |*t| t.deinit();
        if (opts.tls) |t| {
            if (comptime !has_tls) return error.TlsNotBuilt;
            try deadline.run(handshake, .{ owned, gpa, io, opts.host, t });
            if (!std.mem.eql(u8, owned.tls_conn.?.alpn_protocol orelse "", "h2")) return error.NoH2;
            owned.tls_reader = owned.tls_conn.?.reader(&owned.tls_read_buf);
            owned.tls_writer = owned.tls_conn.?.writer(&owned.tls_write_buf);
            r = &owned.tls_reader.interface;
            w = &owned.tls_writer.interface;
        }
        return start(gpa, io, socket, owned, r, w, opts.stream_window, opts.max_data, opts.max_header_list_size, timeoutFrom(opts.timeout));
    }

    /// Takes over a connection on which the TLS handshake picked "h2", as
    /// the core's client does (its `h2_client` seam): `reader` and `writer`
    /// carry the cleartext from here on, and only this connection's tasks
    /// use them. `socket` is shut down when the session ends but not
    /// closed; the caller closes it, and frees the TLS state, after
    /// `close`. Requests have no timeout unless they ask for one.
    pub fn adopt(gpa: std.mem.Allocator, io: std.Io, reader: *std.Io.Reader, writer: *std.Io.Writer, socket: std.Io.net.Stream) !*ClientConnection {
        const defaults: ConnectOptions = .{ .host = "", .port = 0 };
        return start(gpa, io, socket, null, reader, writer, defaults.stream_window, defaults.max_data, defaults.max_header_list_size, .none);
    }

    fn dial(io: std.Io, opts: ConnectOptions) !std.Io.net.Stream {
        if (unixTarget(opts.host)) |t| {
            var buf: [std.Io.net.UnixAddress.max_len]u8 = undefined;
            var path = t.path;
            if (t.abstract) {
                if (comptime @import("builtin").os.tag != .linux) return error.UnixAbstractUnsupported;
                if (t.path.len + 1 > buf.len) return error.NameTooLong;
                buf[0] = 0;
                @memcpy(buf[1..][0..t.path.len], t.path);
                path = buf[0 .. t.path.len + 1];
            }
            const ua = try std.Io.net.UnixAddress.init(path);
            return ua.connect(io);
        }
        if (opts.address) |a| return a.connect(io, .{ .mode = .stream });
        if (std.Io.net.IpAddress.parse(opts.host, opts.port)) |a| return a.connect(io, .{ .mode = .stream }) else |_| {}
        return (try std.Io.net.HostName.init(opts.host)).connect(io, opts.port, .{ .mode = .stream });
    }

    fn handshake(owned: *Owned, gpa: std.mem.Allocator, io: std.Io, host: []const u8, t: ConnectOptions.Tls) !void {
        const store = if (t.insecure_skip_verify)
            null
        else
            try tls.clientStore(gpa, io, t.ca) orelse return error.NoCertificateAuthority;
        defer if (store) |s| tls.releaseStore(s);
        var pair: ?tls.config.CertKeyPair = if (t.client_certificate) |cc| try loadCertificate(gpa, io, cc) else null;
        // The SSL takes its own references to the certificate and key.
        defer if (pair) |*p| p.deinit(gpa);
        var rng: std.Random.IoSource = .{ .io = io };
        owned.tls_conn = tls.client(&owned.tcp_reader.interface, &owned.tcp_writer.interface, .{
            .host = host,
            .root_ca = .empty,
            .store = store,
            .insecure_skip_verify = t.insecure_skip_verify,
            .auth = if (pair) |*p| p else null,
            .now = std.Io.Clock.real.now(io),
            .rng = rng.interface(),
            .alpn_protocols = &.{"h2"},
        }) catch |err| return switch (err) {
            // The cause is a layer down, on the socket.
            error.ReadFailed => owned.tcp_reader.err orelse error.ConnectionClosed,
            error.WriteFailed => owned.tcp_writer.err orelse error.ConnectionClosed,
            else => |e| e,
        };
    }

    fn start(
        gpa: std.mem.Allocator,
        io: std.Io,
        socket: std.Io.net.Stream,
        owned: ?*Owned,
        r: *std.Io.Reader,
        w: *std.Io.Writer,
        stream_window: u31,
        max_data: u31,
        max_header_list_size: u32,
        timeout: std.Io.Timeout,
    ) !*ClientConnection {
        const self = try gpa.create(ClientConnection);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .socket = socket,
            .owned = owned,
            .r = r,
            .w = w,
            .stream_window = stream_window,
            .max_data = max_data,
            .max_header_list_size = max_header_list_size,
            .timeout = timeout,
        };
        try self.initSession();
        errdefer c.nghttp2_session_del(self.session);
        errdefer self.group.cancel(io);
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
            .{ .settings_id = c.NGHTTP2_SETTINGS_MAX_HEADER_LIST_SIZE, .value = self.max_header_list_size },
        };
        if (c.nghttp2_submit_settings(self.session, c.NGHTTP2_FLAG_NONE, &iv, iv.len) != 0) return error.OutOfMemory;
        // A connection window big enough for several busy streams.
        _ = c.nghttp2_session_set_local_window_size(self.session, c.NGHTTP2_FLAG_NONE, 0, self.max_data);
    }

    /// Sends GOAWAY, waits for the reader and writer, and frees everything
    /// (after `adopt`, everything but the transport). Streams still open
    /// fail with `ConnectionClosed`; release them all first.
    pub fn close(self: *ClientConnection) void {
        {
            self.lock();
            defer self.unlock();
            // Also after the server's GOAWAY, whose streams may still be
            // open.
            if (!self.dead) _ = c.nghttp2_session_terminate_session(self.session, c.NGHTTP2_NO_ERROR);
            self.closing = true;
        }
        self.kickWriter();
        // The tasks have ended either way; a cancel is the caller's to see.
        self.group.await(self.io) catch self.io.recancel();
        {
            self.lock();
            defer self.unlock();
            c.nghttp2_session_del(self.session);
            self.session = null;
            // Streams released but never closed by the server.
            var it = self.live.first;
            while (it) |node| {
                it = node.next;
                const stream: *Stream = @alignCast(@fieldParentPtr("node", node));
                if (!stream.user_done) continue;
                stream.protocol_done = true;
                stream.maybeFree();
            }
        }
        if (self.owned) |o| {
            if (comptime has_tls) if (o.tls_conn) |*t| t.deinit();
            self.socket.close(self.io);
            self.gpa.destroy(o);
        }
        self.gpa.destroy(self);
    }

    /// Whether new requests may still go out: no GOAWAY, no failure, no
    /// `close`.
    pub fn isOpen(self: *ClientConnection) bool {
        self.lock();
        defer self.unlock();
        return !self.closing;
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

    /// Per request: a body (streamed or given whole) and the timeout.
    pub const RequestOptions = struct {
        /// The request has a body, written through `Stream.writer` and
        /// ended with `Stream.closeSend`.
        body: bool = false,
        /// The whole request body at once, in place of `body` and the
        /// writer: copied, and sent as the server's flow control allows
        /// while the caller goes on to `waitHead`, so a server that answers
        /// while it reads (an echo) cannot stall the call. HTTP/2 only.
        body_bytes: ?[]const u8 = null,
        /// Replaces `ConnectOptions.timeout` for this request. Null inherits
        /// it; `.none` lifts it. A duration runs from the call to `request`.
        /// Past it the stream is reset, and `waitHead`, reads and writes
        /// fail with `error.Timeout` (reads and writes behind `ReadFailed`
        /// and `WriteFailed`; see `Stream.readError`).
        timeout: ?std.Io.Timeout = null,
    };

    /// Opens a stream. `headers` holds the pseudo-headers first, names in
    /// lower case; they are copied.
    pub fn request(self: *ClientConnection, headers: []const Header, opts: RequestOptions) !*Stream {
        const stream = try Stream.create(self, opts.body, opts.body_bytes, .init(self.io, opts.timeout orelse self.timeout));
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
            const has_body = opts.body or opts.body_bytes != null;
            const id = c.nghttp2_submit_request2(self.session, null, nva.ptr, nva.len, if (has_body) &provider else null, stream);
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
        self.dead = true;
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
            const stream: *Stream = @alignCast(@fieldParentPtr("node", node));
            stream.finishLocked(error.ConnectionClosed);
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
                // A GOAWAY only stops new streams: what is open finishes,
                // and `finished` ends the loop after that.
                closing = self.dead;
                while (!closing and staging.items.len < 64 * 1024) {
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
        self.dead = true;
        if (self.failure == null) self.failure = error.ConnectionClosed;
        self.unlock();
        self.socket.shutdown(self.io, .both) catch {};
    }

    fn streamFrom(session: ?*c.nghttp2_session, id: i32) ?*Stream {
        const p = c.nghttp2_session_get_stream_user_data(session, id) orelse return null;
        return @ptrCast(@alignCast(p));
    }

    /// Fails the stream with `cause` from a header callback: nghttp2
    /// resets it and ignores the rest of its header block.
    fn failHeaders(stream: *Stream, cause: StreamError) c_int {
        if (stream.cause == null) stream.cause = cause;
        return c.NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
    }

    fn onHeader(session: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, name: [*c]const u8, namelen: usize, value: [*c]const u8, valuelen: usize, _: u8, _: ?*anyopaque) callconv(.c) c_int {
        const stream = streamFrom(session, frame.*.hd.stream_id) orelse return 0;
        if (frame.*.hd.type != c.NGHTTP2_HEADERS) return 0;
        const n = name[0..namelen];
        const v = value[0..valuelen];
        // Every field of the stream's heads and trailers, counted as
        // SETTINGS_MAX_HEADER_LIST_SIZE counts them, before any is kept.
        stream.header_list_size +|= namelen + valuelen + 32;
        if (stream.header_list_size > stream.conn.max_header_list_size) return failHeaders(stream, error.HeadersTooLarge);
        const arena = stream.arena.allocator();
        // After a 1xx the final response comes as HCAT_HEADERS, so what a
        // block is goes by whether the head has come.
        if (!stream.head_ready) {
            if (std.mem.eql(u8, n, ":status")) {
                stream.status = std.fmt.parseInt(u16, v, 10) catch 0;
                if (stream.status >= 100 and stream.status < 200) {
                    stream.interim += 1;
                    if (stream.interim > max_interim_responses) return failHeaders(stream, error.TooManyInterimResponses);
                }
                return 0;
            }
            stream.headers.append(arena, .{
                .name = arena.dupe(u8, n) catch return failHeaders(stream, error.StreamReset),
                .value = arena.dupe(u8, v) catch return failHeaders(stream, error.StreamReset),
            }) catch return failHeaders(stream, error.StreamReset);
        } else {
            stream.trailers.append(arena, .{
                .name = arena.dupe(u8, n) catch return failHeaders(stream, error.StreamReset),
                .value = arena.dupe(u8, v) catch return failHeaders(stream, error.StreamReset),
            }) catch return failHeaders(stream, error.StreamReset);
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
            self.goaway_last_id = frame.*.goaway.last_stream_id;
            return 0;
        }
        const stream = streamFrom(session, hd.stream_id) orelse return 0;
        const end = hd.flags & c.NGHTTP2_FLAG_END_STREAM != 0;
        switch (hd.type) {
            c.NGHTTP2_HEADERS => {
                if (!stream.head_ready and stream.status >= 200) {
                    stream.head_ready = true;
                    stream.head_event.set(self.io);
                } else if (!stream.head_ready) {
                    // 1xx: its fields are not the response's.
                    stream.headers.clearRetainingCapacity();
                    stream.status = 0;
                }
                if (end) stream.endBody();
            },
            c.NGHTTP2_DATA => if (end) stream.endBody(),
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
        stream.finishLocked(if (code != c.NGHTTP2_NO_ERROR) error.StreamReset else null);
        stream.protocol_done = true;
        _ = c.nghttp2_session_set_stream_user_data(session, id, null);
        stream.maybeFree();
        return 0;
    }

    fn provideData(_: ?*c.nghttp2_session, _: i32, buf: [*c]u8, length: usize, flags: [*c]u32, source: [*c]c.nghttp2_data_source, _: ?*anyopaque) callconv(.c) c.nghttp2_ssize {
        const stream: *Stream = @ptrCast(@alignCast(source.*.ptr.?));
        if (stream.fixed_body) |b| {
            const n = @min(length, b.len - stream.fixed_sent);
            @memcpy(buf[0..n], b[stream.fixed_sent..][0..n]);
            stream.fixed_sent += n;
            if (stream.fixed_sent == b.len) flags.* |= c.NGHTTP2_DATA_FLAG_EOF;
            return @intCast(n);
        }
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
    /// The request's budget, shared by every wait on the stream.
    deadline: Deadline,

    status: u16 = 0,
    /// Informational responses so far.
    interim: u8 = 0,
    /// What the response's header fields have taken, as
    /// `max_header_list_size` counts it.
    header_list_size: usize = 0,
    headers: std.ArrayList(Header) = .empty,
    trailers: std.ArrayList(Header) = .empty,
    head_ready: bool = false,
    head_event: std.Io.Event = .unset,
    /// The response is complete (END_STREAM).
    body_done: bool = false,
    /// Why the stream ended early. Under the connection's mutex.
    cause: ?StreamError = null,
    error_code: u32 = 0,
    /// Behind the last `ReadFailed` (the reading task's) and `WriteFailed`
    /// (the writing task's).
    read_err: ?StreamError = null,
    write_err: ?StreamError = null,

    body: std.Io.Queue(u8),
    body_reader: std.Io.Reader,
    out: std.Io.Queue(u8),
    out_writer: std.Io.Writer,
    send_closed: bool = false,
    /// The request was opened with `.body = true`: the writer is its body.
    has_body: bool,
    /// `RequestOptions.body_bytes`, copied, and how much of it nghttp2 took.
    fixed_body: ?[]const u8 = null,
    fixed_sent: usize = 0,

    /// Both the caller (`release`) and nghttp2 (stream close) are done.
    user_done: bool = false,
    protocol_done: bool = false,

    fn create(conn: *ClientConnection, has_body: bool, fixed_body: ?[]const u8, deadline: Deadline) !*Stream {
        const self = try conn.gpa.create(Stream);
        errdefer conn.gpa.destroy(self);
        self.* = .{
            .conn = conn,
            .arena = .init(conn.gpa),
            .deadline = deadline,
            .body = undefined,
            .body_reader = .{ .buffer = &.{}, .seek = 0, .end = 0, .vtable = &.{ .stream = readBody } },
            .out = undefined,
            .out_writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drainOut, .flush = flushOut } },
            .send_closed = !has_body,
            .has_body = has_body,
        };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        self.body = .init(try a.alloc(u8, conn.stream_window));
        self.body_reader.buffer = try a.alloc(u8, 16 * 1024);
        if (has_body) {
            self.out = .init(try a.alloc(u8, 32 * 1024));
            self.out_writer.buffer = try a.alloc(u8, 16 * 1024);
        } else {
            self.out = .init(&.{});
        }
        if (fixed_body) |b| self.fixed_body = try a.dupe(u8, b);
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

    /// Under the connection's mutex: END_STREAM arrived. The reader sees
    /// the end once it has taken what is queued.
    fn endBody(self: *Stream) void {
        self.body_done = true;
        self.body.close(self.conn.io);
    }

    /// Under the connection's mutex: no more body, wake every waiter. A
    /// `cause` marks the stream as ended early, unless its response was
    /// complete or it already has one.
    fn finishLocked(self: *Stream, cause: ?StreamError) void {
        if (cause) |e| if (self.cause == null and !self.body_done) {
            self.cause = e;
        };
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

    /// True when the server provably did not process the request: it
    /// refused the stream (REFUSED_STREAM) or its GOAWAY's last stream ID
    /// is below this stream's. Such a request can be sent again on another
    /// connection whatever its method.
    pub fn unprocessed(self: *const Stream) bool {
        if (self.error_code == c.NGHTTP2_REFUSED_STREAM) return true;
        return self.id > self.conn.goaway_last_id and !self.head_ready;
    }

    /// The error code of the RST_STREAM that ended the stream (the
    /// server's, or the echo of one sent here); null when it did not end
    /// in a reset.
    pub fn resetCode(self: *const Stream) ?u64 {
        if (self.cause != null and self.cause.? == error.StreamReset) return self.error_code;
        return null;
    }

    /// Waits for the response head (`status`, `headers`).
    pub fn waitHead(self: *Stream) StreamError!void {
        const conn = self.conn;
        self.deadline.run(waitHeadEvent, .{self}) catch |err| switch (err) {
            error.Timeout => {
                self.expire();
                return error.Timeout;
            },
            else => return error.Canceled,
        };
        conn.lock();
        defer conn.unlock();
        if (!self.head_ready) return self.cause orelse error.ConnectionClosed;
    }

    fn waitHeadEvent(self: *Stream) std.Io.Cancelable!void {
        try self.head_event.wait(self.conn.io);
    }

    /// The first response header named `name` (any case), once `waitHead`
    /// has returned; null when absent.
    pub fn header(self: *const Stream, name: []const u8) ?[]const u8 {
        for (self.headers.items) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }

    /// The first trailer named `name` (any case), once the body has been
    /// read to its end; null when absent.
    pub fn trailer(self: *const Stream, name: []const u8) ?[]const u8 {
        for (self.trailers.items) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }

    /// The response body. `error.EndOfStream` at its end; then `trailers`
    /// are in. A stream that ended early fails the read with `ReadFailed`,
    /// and `readError` says why.
    pub fn reader(self: *Stream) *std.Io.Reader {
        return &self.body_reader;
    }

    /// The request body (for a request opened with `.body = true`).
    /// `flush` sends what is written; `closeSend` ends it. A stream that
    /// ended early fails the write with `WriteFailed`, and `writeError`
    /// says why.
    pub fn writer(self: *Stream) *std.Io.Writer {
        return &self.out_writer;
    }

    /// The stream whose `reader` this is.
    pub fn ofReader(r: *std.Io.Reader) *Stream {
        return @alignCast(@fieldParentPtr("body_reader", r));
    }

    /// What the last `ReadFailed` from `reader` was.
    pub fn readError(self: *const Stream) ?StreamError {
        return self.read_err;
    }

    /// What the last `WriteFailed` from `writer` was.
    pub fn writeError(self: *const Stream) ?StreamError {
        return self.write_err;
    }

    /// Ends the request body (END_STREAM).
    pub fn closeSend(self: *Stream) !void {
        try self.out_writer.flush();
        const conn = self.conn;
        conn.lock();
        self.send_closed = true;
        if (self.submitted and self.cause == null) _ = c.nghttp2_session_resume_data(conn.session, self.id);
        conn.unlock();
        conn.kickWriter();
    }

    /// Resets the stream (RST_STREAM CANCEL) if it is still open.
    pub fn cancel(self: *Stream) void {
        self.end(error.Canceled);
    }

    /// The request's time ran out: the stream is reset.
    fn expire(self: *Stream) void {
        self.end(error.Timeout);
    }

    fn end(self: *Stream, cause: StreamError) void {
        const conn = self.conn;
        conn.lock();
        defer conn.unlock();
        if (!self.protocol_done and self.submitted and conn.session != null) {
            _ = c.nghttp2_submit_rst_stream(conn.session, c.NGHTTP2_FLAG_NONE, self.id, c.NGHTTP2_CANCEL);
        }
        self.finishLocked(cause);
        conn.kickWriter();
    }

    /// Done with the stream: an unfinished one is canceled first, and
    /// freed once nghttp2 has closed it.
    pub fn release(self: *Stream) void {
        const conn = self.conn;
        conn.lock();
        // Also after a GOAWAY, which leaves the streams it covers open.
        const open = !self.protocol_done and self.submitted and conn.session != null and !conn.dead;
        conn.unlock();
        if (open) self.cancel();
        conn.lock();
        defer conn.unlock();
        self.user_done = true;
        // A stream nghttp2 never got, or one a dead session left behind,
        // has no close to wait for. nghttp2 must not hand it out again.
        if (!self.submitted or conn.session == null or conn.dead) {
            if (self.submitted and !self.protocol_done and conn.session != null)
                _ = c.nghttp2_session_set_stream_user_data(conn.session, self.id, null);
            self.protocol_done = true;
        }
        self.maybeFree();
    }

    fn takeBody(self: *Stream, dest: []u8) (std.Io.QueueClosedError || std.Io.Cancelable)!usize {
        return self.body.get(self.conn.io, dest, 1);
    }

    fn readBody(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Stream = @alignCast(@fieldParentPtr("body_reader", r));
        const conn = self.conn;
        const dest = limit.slice(try w.writableSliceGreedy(1));
        if (dest.len == 0) return 0;
        const n = self.deadline.run(takeBody, .{ self, dest }) catch |err| switch (err) {
            error.Closed => {
                conn.lock();
                const cause = self.cause;
                conn.unlock();
                self.read_err = cause orelse return error.EndOfStream;
                return error.ReadFailed;
            },
            error.Timeout => {
                self.expire();
                self.read_err = error.Timeout;
                return error.ReadFailed;
            },
            else => {
                self.read_err = error.Canceled;
                return error.ReadFailed;
            },
        };
        w.advance(n);
        conn.lock();
        if (conn.session != null and !self.protocol_done) _ = c.nghttp2_session_consume(conn.session, self.id, n);
        conn.unlock();
        conn.kickWriter();
        return n;
    }

    fn putSome(self: *Stream, bytes: []const u8) (std.Io.QueueClosedError || std.Io.Cancelable)!usize {
        return self.out.put(self.conn.io, bytes, 1);
    }

    fn put(self: *Stream, bytes: []const u8) std.Io.Writer.Error!void {
        const conn = self.conn;
        if (!self.has_body and bytes.len > 0) return error.WriteFailed;
        var rest = bytes;
        while (rest.len > 0) {
            const n = self.deadline.run(putSome, .{ self, rest }) catch |err| {
                self.write_err = switch (err) {
                    error.Closed => blk: {
                        conn.lock();
                        defer conn.unlock();
                        break :blk self.cause orelse error.StreamReset;
                    },
                    error.Timeout => blk: {
                        self.expire();
                        break :blk error.Timeout;
                    },
                    else => error.Canceled,
                };
                return error.WriteFailed;
            };
            rest = rest[n..];
            conn.lock();
            if (self.submitted and self.cause == null and !self.protocol_done) _ = c.nghttp2_session_resume_data(conn.session, self.id);
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

fn loadCertificate(gpa: std.mem.Allocator, io: std.Io, cc: dusty.Cert) !tls.config.CertKeyPair {
    return switch (cc) {
        .pem => |pem| tls.config.CertKeyPair.fromSlice(gpa, io, pem.cert, pem.key),
        .files => |f| tls.config.CertKeyPair.fromFilePath(gpa, io, std.Io.Dir.cwd(), f.cert_path, f.key_path),
        .dev_self_signed => error.DevCertificateUnavailable,
    };
}
