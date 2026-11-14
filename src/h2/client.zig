//! An HTTP/2 client connection on the HTTP core's protocol core
//! (src/http/core/h2/conn.zig in its client role, M5 of
//! research/h2h3-takeover/PLAN.md): many concurrent streams over one TCP
//! connection, cleartext (prior knowledge) or TLS with ALPN "h2". A reader
//! task feeds the core, a writer task drains it, and one mutex guards it
//! and everything below: the caller's tasks may run on any executor, so
//! the server engine's executor-local lock doesn't fit here. Nothing waits
//! while holding the mutex.
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
//! Request bodies go to the core by reference (`Conn.submitData`) and are
//! written from where they lie: `body_bytes` from the stream's copy, a
//! streamed body from two 16 KiB blocks it fills in turn (the server
//! engine's sink pattern). Such memory is let go only once the writer has
//! written past it (`Stream.retire_mark`), even after the stream closed.
//!
//! Its own module (`anole_h2_client`), because the core's client takes it as
//! its `h2_client` import: when a server picks "h2" through ALPN, the core
//! hands the TLS connection over (`adopt`), so `anole.http.Client` speaks
//! HTTP/2 too.
const std = @import("std");
const builtin = @import("builtin");
const options = @import("anole_h2_options");
const tls = if (options.tls) @import("anole_dusty_tls") else struct {};
const dusty = @import("dusty");
const placement = dusty.placement;
const Deadline = dusty.Deadline;
const Signal = dusty.Signal;
const proto = dusty.h2_proto;
const hpack = proto.hpack;
const ErrorCode = proto.conn.ErrorCode;
/// The core's stream (the protocol side of a `Stream`).
const PStream = proto.conn.Stream;
const Proto = proto.conn.Conn(.client, ClientConnection.Handler);

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
    /// Shut down by the writer when the connection ends, to end the
    /// reader's wait. Closed by `close` only when `owned` (not after
    /// `adopt`).
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

    /// Guards `proto`, every stream's state and what follows.
    mutex: std.Io.Mutex = .init,
    // SAFETY: set by `start` (`Proto.initAt`) before anything reads it.
    proto: Proto = undefined,
    // SAFETY: set by `start`, before `proto` can call it.
    handler: Handler = undefined,
    /// `proto` is freed (`close`).
    proto_gone: bool = false,
    /// The connection is going or gone: no new streams. A GOAWAY sets it,
    /// and the streams it covers carry on.
    closing: bool = false,
    /// The last stream ID the server's GOAWAY says it may have processed;
    /// above it, a stream never ran (`Stream.unprocessed`).
    goaway_last_id: i32 = std.math.maxInt(i32),
    /// The connection is over: the reader has ended or a write failed.
    /// From here nothing calls into `proto` but the writer (draining it)
    /// and `close`, so no callback can reach a stream any more.
    dead: bool = false,
    /// The writer writes what `proto` holds, then shuts the socket down and
    /// ends: `close`, or the reader is done.
    shut: bool = false,
    /// Why it went, when it failed.
    failure: ?anyerror = null,
    /// Wakes the writer: output was queued.
    write_wake: Signal = .{},
    /// Wakes the request and body-writer waits: a stream closed, the
    /// writer wrote, the server's frames came in, or the connection ended.
    progress: Signal = .{},
    group: std.Io.Group = .init,
    /// Streams the caller still holds or `proto` still knows.
    live: std.DoublyLinkedList = .{},
    /// Freed streams whose request body `out` may still be writing from,
    /// in `retire_mark` order.
    retiring: std.DoublyLinkedList = .{},
    /// Tests only: writes of the writer task (each a flush of whatever the
    /// core held: concurrent requests share them).
    test_writes: if (builtin.is_test) u32 else void = if (builtin.is_test) 0 else {},

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

    /// The receive window per stream of an adopted connection (the HTTP
    /// client's). Its queue is sized per response (`allocBody`), so a large
    /// window costs nothing for small answers.
    const adopted_stream_window: u31 = 1 << 20;

    /// Takes over a connection on which the TLS handshake picked "h2", as
    /// the core's client does (its `h2_client` seam): `reader` and `writer`
    /// carry the cleartext from here on, and only this connection's tasks
    /// use them. `socket` is shut down when the session ends but not
    /// closed; the caller closes it, and frees the TLS state, after
    /// `close`. Requests have no timeout unless they ask for one.
    pub fn adopt(gpa: std.mem.Allocator, io: std.Io, reader: *std.Io.Reader, writer: *std.Io.Writer, socket: std.Io.net.Stream) !*ClientConnection {
        const defaults: ConnectOptions = .{ .host = "", .port = 0 };
        return start(gpa, io, socket, null, reader, writer, adopted_stream_window, defaults.max_data, defaults.max_header_list_size, .none);
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
        self.handler = .{ .owner = self };
        var seed: u64 = 0;
        io.random(std.mem.asBytes(&seed));
        // Window credit goes back as the reader takes bytes (`consumed`),
        // so a stream's queue never overflows. Into the heap connection:
        // no copy of the core's HPACK tables through this frame (#223).
        try self.proto.initAt(gpa, &self.handler, .{
            .initial_window = stream_window,
            .connection_window = max_data,
            .max_header_list_size = max_header_list_size,
            .seed = seed,
        });
        errdefer self.proto.deinit();
        errdefer self.group.cancel(io);
        // On the caller's executor, as every task of a connection is.
        try placement.concurrent(&self.group, io, .local, readerLoop, .{self});
        try placement.concurrent(&self.group, io, .local, writerLoop, .{self});
        return self;
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
            if (!self.dead) self.proto.goaway(.no_error, "") catch {};
            self.closing = true;
            self.shut = true;
        }
        self.kickWriter();
        // The tasks have ended either way; a cancel is the caller's to see.
        self.group.await(self.io) catch self.io.recancel();
        {
            self.lock();
            defer self.unlock();
            var it = self.live.first;
            while (it) |node| : (it = node.next) {
                const stream: *Stream = @alignCast(@fieldParentPtr("node", node));
                if (stream.ps) |ps| ps.user = null;
                stream.ps = null;
            }
            self.proto.deinit();
            self.proto_gone = true;
            // Nothing writes any more: what waited for the writer goes.
            while (self.retiring.popFirst()) |node| {
                const stream: *Stream = @alignCast(@fieldParentPtr("retire_node", node));
                stream.free();
            }
            // Streams released but never closed by the server.
            it = self.live.first;
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
        self.write_wake.notify(self.io);
    }

    fn waitProgress(self: *ClientConnection, seen: u32) std.Io.Cancelable!void {
        try self.progress.wait(self.io, seen);
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
    /// lower case; they are encoded at once. With the server's limit on
    /// concurrent streams reached, it waits for one to close, within the
    /// request's timeout (`error.Timeout`), as Go's Transport waits.
    pub fn request(self: *ClientConnection, headers: []const Header, opts: RequestOptions) !*Stream {
        const fixed = if (opts.body_bytes) |b| (if (b.len > 0) b else null) else null;
        const stream = try Stream.create(self, opts.body, fixed, .init(self.io, opts.timeout orelse self.timeout));
        errdefer stream.destroy();
        // SAFETY: the first headers.len are set below.
        var stack: [32]hpack.Field = undefined;
        const on_heap = headers.len > stack.len;
        const fields = if (on_heap) try self.gpa.alloc(hpack.Field, headers.len) else stack[0..headers.len];
        defer if (on_heap) self.gpa.free(fields);
        for (headers, fields) |h, *f| f.* = .{ .name = h.name, .value = h.value };
        const end_stream = !opts.body and fixed == null;
        while (true) {
            const seen = self.progress.epoch();
            {
                self.lock();
                defer self.unlock();
                if (self.closing or self.dead) return error.ConnectionClosed;
                if (self.proto.submitRequest(fields, end_stream, stream)) |ps| {
                    stream.ps = ps;
                    stream.id = ps.id;
                    stream.submitted = true;
                    if (fixed != null) {
                        stream.borrowed = true;
                        self.proto.submitData(ps, &stream.fixed_part, true) catch |err| {
                            self.proto.reset(ps, .internal_error) catch {};
                            return err;
                        };
                    }
                    break;
                } else |err| switch (err) {
                    error.StreamLimit => {},
                    error.GoawayReceived => return error.ConnectionClosed,
                    // A new connection is due (RFC 9113 §5.1.1).
                    error.StreamIdsExhausted => {
                        self.closing = true;
                        return error.ConnectionClosed;
                    },
                    error.HeadersTooLarge, error.OutOfMemory => |e| return e,
                }
            }
            stream.deadline.run(waitProgress, .{ self, seen }) catch |err| return switch (err) {
                error.Timeout => error.Timeout,
                else => error.Canceled,
            };
        }
        self.kickWriter();
        return stream;
    }

    fn readerLoop(self: *ClientConnection) std.Io.Cancelable!void {
        const err = self.runReader();
        self.lock();
        self.closing = true;
        self.dead = true;
        // What the core holds (a GOAWAY after a connection error) still
        // goes out, but no more DATA is framed: `release` frees a stream
        // of a dead connection at once, while its unframed body (lent to
        // the core) is still queued.
        self.proto.dead = true;
        self.shut = true;
        if (self.failure == null) self.failure = err;
        self.unlock();
        self.failAll();
        self.kickWriter();
        self.progress.notify(self.io);
    }

    fn runReader(self: *ClientConnection) anyerror {
        while (true) {
            const buffered = self.r.buffered();
            if (buffered.len > 0) {
                const fed = self.feed(buffered) catch |err| return err;
                self.r.toss(fed.n);
                // A GOAWAY's streams are all done: the connection is.
                if (fed.ended) return error.ConnectionClosed;
                // The core took every whole frame: what is left is the
                // start of the next one, so more must be read first.
                if (fed.n < buffered.len and buffered.len - fed.n == self.r.buffer.len) {
                    if (try self.feedLarge()) return error.ConnectionClosed;
                    continue;
                }
            }
            self.r.fillMore() catch return error.ConnectionClosed;
        }
    }

    const Fed = struct { n: usize, ended: bool };

    /// Hands `bytes` to the core: how many it took, and whether the
    /// server's GOAWAY came and every stream it let finish has.
    fn feed(self: *ClientConnection, bytes: []const u8) !Fed {
        const fed: Fed = fed: {
            self.lock();
            defer self.unlock();
            const buf = try scratch(@max(self.max_header_list_size, hpack.table_capacity));
            const now = std.Io.Clock.awake.now(self.io);
            const n = self.proto.recv(bytes, @intCast(@max(0, now.toSeconds())), buf) catch |err| switch (err) {
                error.ConnectionError, error.BadPreface => return error.Http2ProtocolError,
                error.OutOfMemory => return error.OutOfMemory,
            };
            break :fed .{ .n = n, .ended = self.proto.goaway_recv and self.proto.table.size == 0 };
        };
        self.kickWriter();
        self.progress.notify(self.io);
        return fed;
    }

    /// A frame longer than the reader's buffer holds (a 16 KiB HEADERS
    /// behind a small TLS buffer): gathered whole in a buffer of its own,
    /// freed once fed. DATA never comes here: the core takes its payload
    /// as it arrives. Whether the connection has ended (`Fed.ended`).
    fn feedLarge(self: *ClientConnection) !bool {
        const head = self.r.buffered();
        const need = 9 + @as(usize, std.mem.readInt(u24, head[0..3], .big));
        var frame_buf = try self.gpa.alloc(u8, need);
        defer self.gpa.free(frame_buf);
        @memcpy(frame_buf[0..head.len], head);
        self.r.toss(head.len);
        const got = self.r.readSliceShort(frame_buf[head.len..]) catch return error.ConnectionClosed;
        if (head.len + got < need) return error.ConnectionClosed;
        const fed = try self.feed(frame_buf);
        if (fed.n != need) return error.Http2ProtocolError;
        return fed.ended;
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

    /// Writes what the core has queued, by reference (`pending` and
    /// `advance`: the slices stay valid across the unlock, whatever is
    /// queued meanwhile), then lets go of the request bodies written past.
    fn writerLoop(self: *ClientConnection) std.Io.Cancelable!void {
        var vecs: [64][]const u8 = undefined;
        while (true) {
            const seen = self.write_wake.epoch();
            var len: usize = 0;
            var shut = false;
            {
                self.lock();
                defer self.unlock();
                const got = self.proto.pending(&vecs) catch {
                    self.failure = self.failure orelse error.OutOfMemory;
                    self.dead = true;
                    self.closing = true;
                    shut = true;
                    break;
                };
                len = got.len;
                shut = self.shut;
            }
            if (len > 0) {
                var n: usize = 0;
                for (vecs[0..len]) |v| n += v.len;
                self.w.writeVecAll(vecs[0..len]) catch return self.writeFailed();
                self.w.flush() catch return self.writeFailed();
                {
                    self.lock();
                    defer self.unlock();
                    self.proto.advance(n);
                    self.retire();
                    if (builtin.is_test) self.test_writes += 1;
                }
                self.progress.notify(self.io);
                continue;
            }
            if (shut) break;
            try self.write_wake.wait(self.io, seen);
        }
        // Ends the reader's wait too.
        self.socket.shutdown(self.io, .both) catch {};
    }

    fn writeFailed(self: *ClientConnection) void {
        self.lock();
        self.closing = true;
        self.dead = true;
        if (self.failure == null) self.failure = error.ConnectionClosed;
        self.unlock();
        self.socket.shutdown(self.io, .both) catch {};
        self.progress.notify(self.io);
    }

    /// The freed streams whose marks `out` has passed are let go. Under
    /// the lock.
    fn retire(self: *ClientConnection) void {
        const sent = self.proto.out.sent_total;
        while (self.retiring.first) |node| {
            const stream: *Stream = @alignCast(@fieldParentPtr("retire_node", node));
            if (stream.retire_mark > sent) break;
            _ = self.retiring.popFirst();
            stream.free();
        }
    }

    /// The core's handler (conn.zig's client role), called inside its
    /// calls, under the connection's mutex.
    const Handler = struct {
        owner: *ClientConnection,

        /// Fails the stream with `cause` from a header callback: the core
        /// resets it and skips the rest of its header block.
        fn failHeaders(stream: *Stream, cause: StreamError) proto.conn.Error {
            if (stream.cause == null) stream.cause = cause;
            return error.ResetStream;
        }

        pub fn onField(h: *Handler, s: *PStream, name: []const u8, value: []const u8) proto.conn.Error!void {
            _ = h;
            const stream = Stream.of(s) orelse return;
            // Every field of the stream's heads and trailers, counted as
            // SETTINGS_MAX_HEADER_LIST_SIZE counts them, before any is kept.
            stream.header_list_size +|= name.len + value.len + 32;
            if (stream.header_list_size > stream.conn.max_header_list_size) return failHeaders(stream, error.HeadersTooLarge);
            const arena = stream.arena.allocator();
            const list = if (s.flags.in_trailers) &stream.trailers else list: {
                if (std.mem.eql(u8, name, ":status")) {
                    // The core checked it: three digits.
                    stream.status = std.fmt.parseInt(u16, value, 10) catch 0;
                    if (stream.status < 200) {
                        stream.interim += 1;
                        if (stream.interim > max_interim_responses) return failHeaders(stream, error.TooManyInterimResponses);
                    }
                    return;
                }
                break :list &stream.headers;
            };
            list.append(arena, .{
                .name = arena.dupe(u8, name) catch return failHeaders(stream, error.StreamReset),
                .value = arena.dupe(u8, value) catch return failHeaders(stream, error.StreamReset),
            }) catch return failHeaders(stream, error.StreamReset);
        }

        pub fn onHeadersEnd(h: *Handler, s: *PStream, end_stream: bool) proto.conn.Error!void {
            const stream = Stream.of(s) orelse return;
            const io = h.owner.io;
            if (s.flags.in_trailers) {
                stream.endBody();
                return;
            }
            if (s.flags.expect_final) {
                // 1xx: its fields are not the response's.
                stream.headers.clearRetainingCapacity();
                stream.status = 0;
                return;
            }
            if (!end_stream) stream.allocBody() catch return failHeaders(stream, error.StreamReset);
            stream.head_ready = true;
            stream.head_event.set(io);
            if (end_stream) stream.endBody();
        }

        pub fn onData(h: *Handler, s: *PStream, bytes: []const u8, end_stream: bool) proto.conn.Error!void {
            const c = h.owner;
            const stream = Stream.of(s) orelse {
                c.proto.consumed(s, bytes.len) catch {};
                return;
            };
            // The window is the queue's size, so this fits; what doesn't
            // (the queue closed) goes back at once.
            const n = stream.body.putUncancelable(c.io, bytes, 0) catch 0;
            if (n < bytes.len) c.proto.consumed(s, bytes.len - n) catch {};
            if (end_stream) stream.endBody();
        }

        pub fn onStreamClose(h: *Handler, s: *PStream, code: ErrorCode) void {
            const c = h.owner;
            const stream = Stream.of(s) orelse return;
            s.user = null;
            stream.ps = null;
            stream.error_code = @backingInt(code);
            stream.finishLocked(if (code != .no_error) error.StreamReset else null);
            stream.protocol_done = true;
            // Room under the server's limit.
            c.progress.notify(c.io);
            stream.maybeFree();
        }

        pub fn onHeadRefused(h: *Handler, s: *PStream) void {
            _ = h;
            const stream = Stream.of(s) orelse return;
            if (stream.cause == null) stream.cause = error.HeadersTooLarge;
        }

        pub fn onWindow(h: *Handler, s: ?*PStream) void {
            // The reader kicks the writer after every read.
            _ = h;
            _ = s;
        }

        pub fn onGoaway(h: *Handler, last_id: u31, code: ErrorCode) void {
            _ = code;
            const c = h.owner;
            // Streams above the last one taken never ran; the core closes
            // them. No new ones from here.
            c.closing = true;
            c.goaway_last_id = last_id;
        }

        pub fn onPingAck(h: *Handler, data: [8]u8) void {
            _ = h;
            _ = data;
        }
    };
};

/// The HPACK scratch `recv` decodes into, one per thread (recv never
/// yields, and runs under the connection's mutex), never given back, as the
/// server engine's.
threadlocal var scratch_buf: []u8 = &.{};

fn scratch(need: usize) error{OutOfMemory}![]u8 {
    if (scratch_buf.len >= need) return scratch_buf;
    const buf = try std.heap.page_allocator.alloc(u8, need);
    if (scratch_buf.len > 0) std.heap.page_allocator.free(scratch_buf);
    scratch_buf = buf;
    return buf;
}

/// One request and its response.
pub const Stream = struct {
    conn: *ClientConnection,
    id: i32 = -1,
    node: std.DoublyLinkedList.Node = .{},
    arena: std.heap.ArenaAllocator,
    submitted: bool = false,
    /// The request's budget, shared by every wait on the stream.
    deadline: Deadline,
    /// The core's side of the stream, until it closes.
    ps: ?*PStream = null,

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
    out_writer: std.Io.Writer,
    send_closed: bool = false,
    /// The request was opened with `.body = true`: the writer is its body.
    has_body: bool,
    /// `RequestOptions.body_bytes`, copied: one part for `submitData`.
    fixed_part: [1][]const u8 = .{""},
    /// A streamed body's blocks: the writer fills `blocks[cur]` (its
    /// buffer), and a full or flushed one goes to the core by reference.
    blocks: [2]Block = .{ .{}, .{} },
    cur: u1 = 0,
    /// Some of the request body went to the core by reference: freeing
    /// the stream waits for the writer to pass it (`retire_mark`).
    borrowed: bool = false,
    retire_node: std.DoublyLinkedList.Node = .{},
    retire_mark: u64 = 0,
    /// A write waits for a block to come free (the window is spent).
    /// Under the connection's mutex; for tests.
    waiting_room: bool = false,

    /// Both the caller (`release`) and the core (stream close) are done.
    user_done: bool = false,
    protocol_done: bool = false,

    const block_len = 16 * 1024;

    const Block = struct {
        mem: []u8 = &.{},
        part: [1][]const u8 = .{""},
        /// Submitted, and not yet known to be framed and written.
        inflight: bool = false,
        /// `out`'s position once the block was framed.
        mark: ?u64 = null,
    };

    fn of(s: *PStream) ?*Stream {
        // SAFETY: `user` is only ever a Stream (`request`).
        return @ptrCast(@alignCast(s.user orelse return null));
    }

    fn create(conn: *ClientConnection, has_body: bool, fixed_body: ?[]const u8, deadline: Deadline) !*Stream {
        const self = try conn.gpa.create(Stream);
        errdefer conn.gpa.destroy(self);
        self.* = .{
            .conn = conn,
            .arena = .init(conn.gpa),
            .deadline = deadline,
            .body = undefined,
            .body_reader = .{ .buffer = &.{}, .seek = 0, .end = 0, .vtable = &.{ .stream = readBody } },
            .out_writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drainOut, .flush = flushOut } },
            .send_closed = !has_body,
            .has_body = has_body,
        };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        // The receive queue comes with the response head (`allocBody`),
        // sized by what the response says it will carry.
        self.body = .init(&.{});
        self.body_reader.buffer = try a.alloc(u8, 16 * 1024);
        if (has_body) {
            for (&self.blocks) |*b| b.mem = try a.alloc(u8, block_len);
            self.out_writer.buffer = self.blocks[0].mem;
        }
        if (fixed_body) |b| self.fixed_part[0] = try a.dupe(u8, b);
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

    /// Under the connection's mutex, when the final response head is in:
    /// the receive queue. As large as the flow-control window needs to be,
    /// but no larger than a response with a `content-length` will fill, so
    /// a stream for a small answer costs a small buffer whatever the
    /// window is.
    fn allocBody(self: *Stream) !void {
        var size: usize = self.conn.stream_window;
        for (self.headers.items) |f| {
            if (!std.ascii.eqlIgnoreCase(f.name, "content-length")) continue;
            const n = std.fmt.parseInt(usize, f.value, 10) catch break;
            size = @min(size, @max(n, 1));
            break;
        }
        self.body = .init(try self.arena.allocator().alloc(u8, size));
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
        self.head_event.set(self.conn.io);
    }

    /// Under the connection's mutex: frees the stream when both sides let
    /// go, once the writer is past the request body it lent the core.
    fn maybeFree(self: *Stream) void {
        if (!(self.user_done and self.protocol_done)) return;
        const conn = self.conn;
        if (self.borrowed and !conn.proto_gone) {
            const mark = conn.proto.out.mark();
            if (conn.proto.out.sent_total < mark) {
                self.retire_mark = mark;
                conn.retiring.append(&self.retire_node);
                return;
            }
        }
        self.free();
    }

    /// Under the connection's mutex.
    fn free(self: *Stream) void {
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
        if (self.error_code == @backingInt(ErrorCode.refused_stream)) return true;
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

    /// True when `cancel` or `release` ended the stream: its
    /// `error.Canceled` is that call's, not a cancel of the waiting task.
    pub fn canceledLocally(self: *const Stream) bool {
        const conn = self.conn;
        conn.lock();
        defer conn.unlock();
        return if (self.cause) |e| e == error.Canceled else false;
    }

    /// Ends the request body (END_STREAM).
    pub fn closeSend(self: *Stream) !void {
        try self.out_writer.flush();
        const conn = self.conn;
        conn.lock();
        self.send_closed = true;
        // An empty end rides on the last DATA still queued.
        if (self.ps) |ps| if (self.cause == null and !conn.dead) conn.proto.submitData(ps, &.{}, true) catch {};
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
        // The cause first: the reset closes the stream inside the call.
        self.finishLocked(cause);
        if (self.ps) |ps| if (!conn.dead) conn.proto.reset(ps, .cancel) catch {};
        conn.kickWriter();
    }

    /// Done with the stream: an unfinished one is canceled first, and
    /// freed once the core has closed it.
    pub fn release(self: *Stream) void {
        const conn = self.conn;
        conn.lock();
        // Also after a GOAWAY, which leaves the streams it covers open.
        const open = self.ps != null and !conn.dead;
        conn.unlock();
        if (open) self.cancel();
        conn.lock();
        defer conn.unlock();
        self.user_done = true;
        self.creditUnread();
        // A stream the core never got, or one a dead connection left
        // behind, has no close to wait for; the core must not hand it out
        // again.
        if (!self.protocol_done and (self.ps == null or conn.dead)) {
            if (self.ps) |ps| ps.user = null;
            self.ps = null;
            self.protocol_done = true;
        }
        self.maybeFree();
    }

    /// Under the connection's mutex, once the caller is done: the body
    /// bytes it never read are dropped, and their window goes back to the
    /// connection (#149), as `readBody` gives back what it reads. The
    /// queue is closed (`finishLocked`), so what arrives later is given
    /// back by `onData`.
    fn creditUnread(self: *Stream) void {
        const conn = self.conn;
        var buf: [4096]u8 = undefined;
        var dropped: usize = 0;
        while (true) {
            const n = self.body.getUncancelable(conn.io, &buf, 0) catch break;
            if (n == 0) break;
            dropped += n;
        }
        if (dropped == 0 or conn.dead or conn.proto_gone) return;
        conn.proto.consumed(self.ps, dropped) catch {};
        conn.kickWriter();
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
        // The connection's window gets the bytes back even once the stream
        // is closed (`ps` null: its whole response may have come before
        // this read): else every response read late keeps its size of it,
        // and the connection stops carrying DATA once that adds up (#149).
        if (!conn.dead) conn.proto.consumed(self.ps, n) catch {};
        conn.unlock();
        conn.kickWriter();
        return n;
    }

    /// Hands the writer's buffered bytes (`blocks[cur]`) to the core and
    /// waits until the other block is free to fill.
    fn sendBuffered(self: *Stream) std.Io.Writer.Error!void {
        const w = &self.out_writer;
        const bytes = w.buffered();
        if (bytes.len == 0) return;
        const conn = self.conn;
        {
            conn.lock();
            defer conn.unlock();
            const ps = self.ps orelse {
                self.write_err = self.cause orelse error.StreamReset;
                return error.WriteFailed;
            };
            if (self.cause != null or conn.dead) {
                self.write_err = self.cause orelse error.ConnectionClosed;
                return error.WriteFailed;
            }
            const b = &self.blocks[self.cur];
            b.part[0] = bytes;
            conn.proto.submitData(ps, &b.part, false) catch {
                self.write_err = error.StreamReset;
                return error.WriteFailed;
            };
            b.inflight = true;
            b.mark = null;
            self.borrowed = true;
            self.cur ^= 1;
            // Nothing to write into until the next block is free.
            w.buffer = &.{};
            w.end = 0;
        }
        conn.kickWriter();
        try self.waitRoom();
        w.buffer = self.blocks[self.cur].mem;
    }

    /// Waits until `blocks[cur]` is free, within the request's budget.
    fn waitRoom(self: *Stream) std.Io.Writer.Error!void {
        const conn = self.conn;
        while (true) {
            const seen = conn.progress.epoch();
            {
                conn.lock();
                defer conn.unlock();
                self.waiting_room = false;
                // The stream or the connection is gone: the block may still
                // be lent to `out`, so it is never handed back to write into.
                if (self.ps == null or conn.dead) {
                    self.write_err = self.cause orelse if (conn.dead) error.ConnectionClosed else error.StreamReset;
                    return error.WriteFailed;
                }
                if (self.roomFree()) {
                    if (self.cause) |e| {
                        self.write_err = e;
                        return error.WriteFailed;
                    }
                    return;
                }
                self.waiting_room = true;
            }
            self.deadline.run(ClientConnection.waitProgress, .{ conn, seen }) catch |err| {
                conn.lock();
                self.waiting_room = false;
                conn.unlock();
                self.write_err = switch (err) {
                    error.Timeout => blk: {
                        self.expire();
                        break :blk error.Timeout;
                    },
                    else => error.Canceled,
                };
                return error.WriteFailed;
            };
        }
    }

    /// Whether the block the writer wants next (`blocks[cur]`) is free:
    /// never submitted, or framed (the stream's queue no longer holds it:
    /// blocks go in order, the other one after it) and written
    /// (`out.sent_total` past a mark taken once it was framed). Only while
    /// the stream is open (`waitRoom` checks). Under the lock.
    fn roomFree(self: *Stream) bool {
        const conn = self.conn;
        const b = &self.blocks[self.cur];
        if (!b.inflight) return true;
        const ps = self.ps.?;
        if (b.mark == null) {
            var queued: usize = 0;
            var it = ps.pending.first;
            while (it) |n| : (it = n.next) queued += 1;
            const after: usize = if (self.blocks[self.cur ^ 1].inflight) 1 else 0;
            if (queued > after) return false;
            b.mark = conn.proto.out.mark();
        }
        if (conn.proto.out.sent_total < b.mark.?) return false;
        b.inflight = false;
        b.mark = null;
        return true;
    }

    fn drainOut(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Stream = @alignCast(@fieldParentPtr("out_writer", w));
        try self.sendBuffered();
        if (w.buffer.len == 0) {
            // No body (`.body = false`), or a block never came free.
            var any = false;
            for (data) |d| any = any or d.len > 0;
            if (!any) return 0;
            if (self.write_err == null) self.write_err = error.StreamReset;
            return error.WriteFailed;
        }
        // Into the free block, as far as it goes.
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            const k = @min(bytes.len, w.buffer.len - w.end);
            @memcpy(w.buffer[w.end..][0..k], bytes[0..k]);
            w.end += k;
            n += k;
            if (k < bytes.len) return n;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            const k = @min(pattern.len, w.buffer.len - w.end);
            @memcpy(w.buffer[w.end..][0..k], pattern[0..k]);
            w.end += k;
            n += k;
            if (k < pattern.len) return n;
        }
        return n;
    }

    fn flushOut(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *Stream = @alignCast(@fieldParentPtr("out_writer", w));
        try self.sendBuffered();
        if (w.buffer.len == 0 and self.has_body) {
            if (self.write_err == null) self.write_err = error.StreamReset;
            return error.WriteFailed;
        }
    }
};

fn loadCertificate(gpa: std.mem.Allocator, io: std.Io, cc: dusty.Cert) !tls.config.CertKeyPair {
    return switch (cc) {
        .pem => |pem| tls.config.CertKeyPair.fromSlice(gpa, io, pem.cert, pem.key),
        .files => |f| tls.config.CertKeyPair.fromFilePath(gpa, io, std.Io.Dir.cwd(), f.cert_path, f.key_path),
        .dev_self_signed => error.DevCertificateUnavailable,
    };
}
