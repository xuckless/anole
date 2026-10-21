// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

const std = @import("std");
const builtin = @import("builtin");
const tls = @import("tls");
/// See client.zig: the TLS module's trust store, loaded once per listener.
const has_trust_store = build_options.use_tls and @hasDecl(tls, "TrustStore");
const TrustStore = if (has_trust_store) tls.TrustStore else void;
const build_options = @import("build_options");

const Router = @import("router.zig").Router;
const Action = @import("router.zig").Action;
const RequestParser = @import("parser.zig").RequestParser;
const RequestBodyReader = @import("parser.zig").RequestBodyReader;
const ParseError = @import("parser.zig").ParseError;
const Request = @import("request.zig").Request;
const parseHeaders = @import("request.zig").parseHeaders;
const Headers = @import("http.zig").Headers;
const Response = @import("response.zig").Response;
const ServerConfig = @import("config.zig").ServerConfig;
const default_listeners = @import("config.zig").default_listeners;
const body_read_reserve = @import("config.zig").body_read_reserve;
const RequestBuffersPool = @import("server/request_buffers.zig").RequestBuffersPool;
const RequestBuffers = @import("server/request_buffers.zig").RequestBuffers;
const Executor = @import("middleware.zig").Executor;
const Middleware = @import("middleware.zig").Middleware;
const Transport = @import("transport.zig").Transport;
const have_auto_cancel = @import("deadline.zig").have_auto_cancel;
const Watch = @import("deadline.zig").Watch;
const Timer = @import("deadline.zig").Timer;
const placement = @import("placement.zig");
const DrainHooks = @import("drain_hooks.zig").DrainHooks;
/// The HTTP/2 engine, with the `use_http2` build option.
const proxy_protocol = @import("proxy_protocol.zig");
const h2 = if (build_options.use_http2) @import("server/h2.zig") else struct {};
const MiddlewareConfig = @import("middleware.zig").MiddlewareConfig;
const cgroup = @import("cgroup.zig");
const somaxconn = @import("somaxconn.zig").somaxconn;
const fd_limit = @import("fd_limit.zig");

const log = std.log.scoped(.anole);

/// How long the accept loop waits after failing for want of a file
/// descriptor or memory, doubling up to the cap. Short enough that a brief
/// shortage costs a little latency, capped so a sustained one settles into
/// one attempt a second rather than a spin.
const min_accept_backoff_ms = 5;
const max_accept_backoff_ms = 1000;

/// Walks all X-Forwarded-For fields as one comma-separated list. Repeated
/// fields are equivalent to one combined field, in their wire order.
const ForwardedForIterator = struct {
    headers: Headers.Iterator,
    addresses: ?std.mem.SplitIterator(u8, .scalar) = null,

    fn init(headers: *const Headers) ForwardedForIterator {
        return .{ .headers = headers.iterator() };
    }

    fn next(self: *ForwardedForIterator) ?[]const u8 {
        while (true) {
            if (self.addresses) |*addresses| {
                if (addresses.next()) |address| return std.mem.trim(u8, address, " \t");
                self.addresses = null;
            }

            const header = self.headers.next() orelse return null;
            if (std.ascii.eqlIgnoreCase(header.key, "X-Forwarded-For")) {
                self.addresses = std.mem.splitScalar(u8, header.value, ',');
            }
        }
    }
};

/// Returns the address `trusted_proxy_hops` hops away from this server. The
/// socket peer is hop zero, so hop one is the rightmost forwarded address.
/// Rejecting the whole chain on malformed input fails closed to the peer.
fn forwardedRemoteAddress(headers: *const Headers, trusted_proxy_hops: usize) ?std.Io.net.IpAddress {
    if (trusted_proxy_hops == 0) return null;

    var count: usize = 0;
    var counting = ForwardedForIterator.init(headers);
    while (counting.next()) |text| {
        if (text.len == 0) return null;
        count += 1;
    }
    if (count < trusted_proxy_hops) return null;

    const wanted = count - trusted_proxy_hops;
    var index: usize = 0;
    var selected: ?std.Io.net.IpAddress = null;
    var parsing = ForwardedForIterator.init(headers);
    while (parsing.next()) |text| : (index += 1) {
        const address = std.Io.net.IpAddress.parse(text, 0) catch return null;
        if (index == wanted) selected = address;
    }
    return selected;
}

fn remoteAddress(peer: std.Io.net.IpAddress, headers: *const Headers, trusted_proxy_hops: usize) std.Io.net.IpAddress {
    return forwardedRemoteAddress(headers, trusted_proxy_hops) orelse peer;
}

/// The last value of a comma-separated forwarding header: the one the
/// nearest proxy wrote or appended. Null when absent or empty.
fn lastForwardedValue(headers: *const Headers, name: []const u8) ?[]const u8 {
    var last: ?[]const u8 = null;
    var it = headers.iterator();
    while (it.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.key, name)) continue;
        var values = std.mem.splitScalar(u8, header.value, ',');
        while (values.next()) |v| last = std.mem.trim(u8, v, " \t");
    }
    const value = last orelse return null;
    return if (value.len == 0) null else value;
}

/// Applies what trusted proxies say about a request: its client address
/// (`X-Forwarded-For`), whether the client's connection is TLS
/// (`X-Forwarded-Proto`) and the host it asked for (`X-Forwarded-Host`).
/// With no trusted hops, only the peer address applies.
fn applyForwardedFn(request: *Request, peer: std.Io.net.IpAddress, trusted_proxy_hops: usize) void {
    request.remote_address = remoteAddress(peer, &request.headers, trusted_proxy_hops);
    request.forwarded_host = null;
    if (trusted_proxy_hops == 0) return;
    if (lastForwardedValue(&request.headers, "X-Forwarded-Proto")) |proto| {
        if (std.ascii.eqlIgnoreCase(proto, "https")) request.secure = true;
        if (std.ascii.eqlIgnoreCase(proto, "http")) request.secure = false;
    }
    if (lastForwardedValue(&request.headers, "X-Forwarded-Host")) |host| {
        // A host name or address with an optional port: nothing that could
        // break a URL or a log line built from it.
        const ok = host.len <= 255 and for (host) |ch| {
            if (!(std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, ".-:[]_", ch) != null)) break false;
        } else true;
        if (ok) request.forwarded_host = host;
    }
}

/// Borrowed view of the client-certificate settings, handed to each accepted
/// connection. The bundle is owned by the connection's `TlsMaterial`, which
/// outlives the connection.
const ClientAuthRef = struct {
    bundle: *std.crypto.Certificate.Bundle,
    trust: ?*const TrustStore,
    mode: ServerConfig.Tls.ClientAuth.Mode,
};

/// What every connection accepted on a TLS listener handshakes with: the
/// certificate and key, and the CAs that verify client certificates.
/// Reference-counted: the listener holds one reference and each connection
/// accepted with it another, so `Server.reloadTls` can put a new one in the
/// listener's place while the connections keep theirs, and the last of them
/// to close frees it.
const TlsMaterial = struct {
    refs: std.atomic.Value(u32) = .init(1),
    auth: tls.config.CertKeyPair,
    client_ca: ?std.crypto.Certificate.Bundle = null,
    client_trust: ?TrustStore = null,
    client_auth_mode: ServerConfig.Tls.ClientAuth.Mode = .require,

    /// Reads the certificate, key and client CAs `cfg` names (files are
    /// read now).
    fn load(allocator: std.mem.Allocator, io: std.Io, cfg: ServerConfig.Tls) !*TlsMaterial {
        if (cfg.client_auth) |client_auth| if (client_auth.ca == .none) {
            log.err("tls.client_auth.ca is .none, so no client certificate could ever verify", .{});
            return error.NoCertificateAuthority;
        };
        const dir = cfg.dir orelse std.Io.Dir.cwd();
        const loaded = if (cfg.pem) |pem|
            tls.config.CertKeyPair.fromSlice(allocator, io, pem.cert, pem.key)
        else if (cfg.cert_path.len == 0 or cfg.key_path.len == 0) {
            log.err("tls needs either pem or both cert_path and key_path", .{});
            return error.MissingTlsCertificate;
        } else tls.config.CertKeyPair.fromFilePath(allocator, io, dir, cfg.cert_path, cfg.key_path);
        var auth = loaded catch |err| {
            if (cfg.pem != null) {
                log.err("cannot load the TLS certificate and key (PEM in memory): {t}", .{err});
            } else {
                log.err("cannot load the TLS certificate \"{s}\" and key \"{s}\": {t}", .{ cfg.cert_path, cfg.key_path, err });
            }
            return err;
        };
        errdefer auth.deinit(allocator);

        const m = try allocator.create(TlsMaterial);
        errdefer allocator.destroy(m);
        m.* = .{ .auth = auth };
        if (cfg.client_auth) |client_auth| {
            m.client_auth_mode = client_auth.mode;
            m.client_ca = client_auth.ca.load(allocator, io) catch |err| {
                log.err("Failed to load client certificate authorities: {}", .{err});
                return err;
            };
            errdefer m.client_ca.?.deinit(allocator);
            if (comptime has_trust_store) m.client_trust = try TrustStore.init(m.client_ca.?);
        }
        return m;
    }

    fn clientAuth(m: *TlsMaterial) ?ClientAuthRef {
        const bundle = if (m.client_ca) |*b| b else return null;
        return .{
            .bundle = bundle,
            .trust = if (comptime has_trust_store) (if (m.client_trust) |*t| t else null) else null,
            .mode = m.client_auth_mode,
        };
    }

    fn release(m: *TlsMaterial, allocator: std.mem.Allocator) void {
        if (m.refs.fetchSub(1, .acq_rel) != 1) return;
        m.auth.deinit(allocator);
        if (m.client_ca) |*bundle| bundle.deinit(allocator);
        if (comptime has_trust_store) if (m.client_trust) |*t| t.deinit();
        allocator.destroy(m);
    }
};

/// Primed into each pooled request arena, so an ordinary request is served
/// without growing it. A request that needs more grows it once, and the
/// arena keeps what it grew to.
const request_arena_reserve = 8 * 1024;

/// How often each executor frees the request buffer sets that no request
/// took since the last time, past a few (`RequestBuffersPool.trimLocal`):
/// what a burst of connections needed at once goes back after it.
const request_buffers_trim_interval: std.Io.Duration = .fromSeconds(5);

/// What a connection reads into while it waits for a request without a set
/// of request buffers -- its first, or any with
/// `request.keep_buffers_between_requests` off -- in place of the pooled
/// read buffer it takes once one arrives. An ordinary
/// head fits, so it moves across in one copy; a longer one is read the rest
/// of the way into the pooled buffer.
const idle_read_buffer_len = 1024;

/// Owns the reader/writer (and, for TLS, the whole TLS + underlying TCP
/// layer) and their buffers for one accepted connection. The buffer a
/// request is read into and its arena are not the connection's: they come
/// from the server's pool once its first request arrives, and go back when
/// it closes.
///
/// Initialized in place: `tls_conn` stores pointers into
/// `tcp_reader`/`tcp_writer`, and `tls_reader`/`tls_writer` store a pointer
/// back into `tls_conn`, so a `Connection` must never be moved after
/// `initPlain`/`initTls` runs.
pub const Connection = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    allocator: std.mem.Allocator,

    /// The TLS record buffers, under TLS; empty otherwise.
    buffers: []u8,
    /// Where request heads are read, set with `useReadBuffer`. The parsed
    /// headers are slices into it, and what a head does not use is what the
    /// body reader reads into, so the reader's view of it shrinks as a
    /// request is parsed; `rewindReader` restores it for the next one.
    read_buffer: []u8,

    tcp_reader: std.Io.net.Stream.Reader = undefined,
    tcp_writer: std.Io.net.Stream.Writer = undefined,

    // TLS layer: tcp_reader/tcp_writer above carry ciphertext; tls_conn wraps
    // them, and tls_reader/tls_writer expose the cleartext Reader/Writer used
    // for HTTP I/O.
    tls_conn: ?tls.Connection = null,
    /// `closeNotify` ran.
    close_notify_sent: bool = false,
    /// What a PROXY protocol header said, on a `Listener.proxy_protocol`
    /// listener: the client address, and whether the client spoke TLS to
    /// the proxy.
    proxied_peer: ?std.Io.net.IpAddress = null,
    proxied_secure: bool = false,
    tls_rng: std.Random.IoSource = undefined,
    tls_reader: tls.Connection.Reader = undefined,
    tls_writer: tls.Connection.Writer = undefined,

    // Active reader/writer, whichever path is in use.
    //
    // Public, and bare interfaces, so they can only report
    // `ReadFailed`/`WriteFailed`. That is allowed here because there is no
    // layer above them to lose the answer: `getReadError`/`getWriteError`
    // beside them resolve what actually failed.
    reader: *std.Io.Reader = undefined,
    writer: *std.Io.Writer = undefined,

    /// Whole before anything can fail, so `deinit` is safe after a failed
    /// init. `tls_buffers_len` is how much the TLS layer gets.
    fn init(
        self: *Connection,
        allocator: std.mem.Allocator,
        io: std.Io,
        stream: std.Io.net.Stream,
        tls_buffers_len: usize,
    ) !void {
        self.* = .{
            .io = io,
            .stream = stream,
            .allocator = allocator,
            .buffers = &.{},
            .read_buffer = &.{},
        };
        self.buffers = try allocator.alloc(u8, tls_buffers_len);
    }

    pub fn initPlain(
        self: *Connection,
        allocator: std.mem.Allocator,
        io: std.Io,
        stream: std.Io.net.Stream,
    ) !void {
        try self.init(allocator, io, stream, 0);
        self.tcp_reader = stream.reader(io, &.{});
        self.tcp_writer = stream.writer(io, &.{});
        self.reader = &self.tcp_reader.interface;
        self.writer = &self.tcp_writer.interface;
    }

    pub noinline fn initTls(
        self: *Connection,
        allocator: std.mem.Allocator,
        io: std.Io,
        stream: std.Io.net.Stream,
        auth: *tls.config.CertKeyPair,
        client_auth: ?ClientAuthRef,
        alpn_protocols: []const []const u8,
    ) !void {
        try self.init(allocator, io, stream, tls.input_buffer_len + tls.output_buffer_len);

        // The tls.Connection points into these for the whole connection.
        const tcp_read_buffer = self.buffers[0..tls.input_buffer_len];
        const tcp_write_buffer = self.buffers[tls.input_buffer_len..][0..tls.output_buffer_len];

        self.tcp_reader = stream.reader(io, tcp_read_buffer);
        self.tcp_writer = stream.writer(io, tcp_write_buffer);
        self.tls_rng = .{ .io = io };
        self.tls_conn = try tls.server(&self.tcp_reader.interface, &self.tcp_writer.interface, .{
            .auth = auth,
            // Built here rather than passed in as a tls.config.ClientAuth, so
            // tls_stub.zig does not have to mirror the type.
            .client_auth = if (client_auth) |ca| blk: {
                var auth_options: tls.config.ClientAuth = .{
                    .root_ca = ca.bundle.*,
                    .auth_type = switch (ca.mode) {
                        .request => .request,
                        .require => .require,
                    },
                };
                if (comptime has_trust_store) auth_options.trust = ca.trust;
                break :blk auth_options;
            } else null,
            .now = std.Io.Clock.real.now(io),
            .rng = self.tls_rng.interface(),
            .alpn_protocols = alpn_protocols,
        });
        self.tls_reader = self.tls_conn.?.reader(&.{});
        self.tls_writer = self.tls_conn.?.writer(&.{});
        self.reader = &self.tls_reader.interface;
        self.writer = &self.tls_writer.interface;
    }

    /// Reads into `buffer` from now on, with what the reader holds moved
    /// into it.
    pub fn useReadBuffer(self: *Connection, buffer: []u8) void {
        const r = self.reader;
        const buffered = r.buffered();
        std.debug.assert(buffered.len <= buffer.len);
        @memcpy(buffer[0..buffered.len], buffered);
        r.buffer = buffer;
        r.seek = 0;
        r.end = buffered.len;
        self.read_buffer = buffer;
    }

    /// Writes through `buffer` from now on, until `releaseWriteBuffer`.
    /// Without one, each write goes out as it is made, which is all that
    /// is written between requests: responses that are one constant string.
    pub fn useWriteBuffer(self: *Connection, buffer: []u8) void {
        std.debug.assert(self.writer.end == 0);
        self.writer.buffer = buffer;
    }

    /// Takes the write buffer back, throwing away what it holds. Every
    /// response is flushed as it ends, so only a failed write leaves
    /// anything, on a connection that is closing.
    pub fn releaseWriteBuffer(self: *Connection) void {
        self.writer.buffer = &.{};
        self.writer.end = 0;
    }

    /// Reads into `buffer` from now on, throwing away what the reader holds.
    pub fn replaceReadBuffer(self: *Connection, buffer: []u8) void {
        const r = self.reader;
        r.buffer = buffer;
        r.seek = 0;
        r.end = 0;
        self.read_buffer = buffer;
    }

    /// Gives the reader the whole read buffer back for the next request.
    /// What the last request left unread is the start of the next one,
    /// pipelined behind it, and it moves to the front.
    pub fn rewindReader(self: *Connection) void {
        const r = self.reader;
        // `parseHeaders` left the reader a window past the head, with its
        // positions relative to that window.
        const head_len = self.read_buffer.len - r.buffer.len;
        r.buffer = self.read_buffer;
        r.seek += head_len;
        r.end += head_len;
        // Neither the stream reader nor the TLS reader overrides the
        // default rebase, which is a move within the buffer and cannot
        // fail.
        r.rebase(r.buffer.len) catch unreachable;
    }

    /// Smallest reader and writer windows `shrinkForUpgrade` leaves. A frame
    /// bigger than its window still goes through in one call: a read that
    /// big lands straight in the caller's slice, and a write goes out with
    /// what the window holds in one vectored write.
    pub const upgrade_window_min = 1024;

    /// For a connection the request upgraded (a WebSocket): it lives on as
    /// long as the peer keeps it open, mostly idle, with the request's
    /// buffers still under it, because the head the handler may still read
    /// (its URL, headers and parameters) is in them. So the reader and the
    /// writer move to small windows just past the head, and the rest of the
    /// buffers' pages go back to the OS (Linux, `MADV_DONTNEED`): the socket
    /// keeps the pages the head and the windows touch, rather than every
    /// page of the set a bigger request, here or earlier, dirtied. The
    /// windows reach to the end of the page the minimums end in, so that
    /// page is used whole. What the peer already sent past the head stays
    /// buffered. Before anything is written to the connection after the
    /// head was read, so the 101 goes through the new window.
    pub fn shrinkForUpgrade(self: *Connection) void {
        const r = self.reader;
        const w = self.writer;
        // Not reading from the pooled buffer (a test's fixed reader), or
        // the writer holds something already.
        if (self.read_buffer.len == 0 or w.end != 0) return;
        const read_end = @intFromPtr(self.read_buffer.ptr) + self.read_buffer.len;
        if (@intFromPtr(r.buffer.ptr) < @intFromPtr(self.read_buffer.ptr) or @intFromPtr(r.buffer.ptr) + r.buffer.len != read_end) return;

        // What is buffered past the head, to the front of the reader's view.
        const buffered_len = r.end - r.seek;
        std.mem.copyForwards(u8, r.buffer[0..buffered_len], r.buffer[r.seek..r.end]);
        r.seek = 0;
        r.end = buffered_len;
        const room = r.buffer;

        const start = @intFromPtr(room.ptr);
        const page = std.heap.pageSize();
        const min_read = @max(buffered_len, upgrade_window_min);
        const end = std.mem.alignForward(usize, start + min_read + upgrade_window_min, page);
        const span = end - start;
        if (span > room.len) {
            // No room for both: the reader keeps its view, the writer a
            // window of its own buffer.
            w.buffer = w.buffer[0..@min(w.buffer.len, @max(upgrade_window_min, page))];
            return;
        }
        const read_len = @max(min_read, span / 2);
        r.buffer = room[0..read_len];
        const old_write = w.buffer;
        w.buffer = room[read_len..span];

        // Give back the pages past the windows: the rest of the read buffer
        // and, where it follows it in the same allocation (the pool's
        // sets), the write buffer.
        if (comptime builtin.os.tag != .linux) return;
        var release_end = read_end;
        if (@intFromPtr(old_write.ptr) == read_end) release_end += old_write.len;
        const from = std.mem.alignForward(usize, end, page);
        const to = std.mem.alignBackward(usize, release_end, page);
        if (to <= from) return;
        _ = std.os.linux.madvise(@ptrFromInt(from), to - from, std.os.linux.MADV.DONTNEED);
    }

    /// For tests: wraps a bare writer with no real TLS/TCP layer behind it.
    /// `tcp_writer.err` is left settable so a test can simulate the real
    /// error a write failure should surface.
    pub fn initWriterForTesting(self: *Connection, w: *std.Io.Writer) void {
        self.* = .{
            .io = undefined,
            .stream = undefined,
            .allocator = undefined,
            .buffers = &.{},
            .read_buffer = &.{},
            .reader = undefined,
            .writer = w,
        };
        self.tcp_reader.err = null;
        self.tcp_writer.err = null;
        self.tcp_writer.write_file_err = null;
    }

    pub fn deinit(self: *Connection) void {
        if (build_options.use_tls) {
            // tls.zig's Connection owns no memory and has no deinit; a TLS
            // module backed by a C library (one SSL object per connection)
            // frees it here.
            if (@hasDecl(tls.Connection, "deinit")) {
                if (self.tls_conn) |*c| c.deinit();
            }
            self.tls_conn = null;
        }
        self.allocator.free(self.buffers);
    }

    /// Sends TLS close_notify, once, so the peer can tell the end of the
    /// stream from a truncation. Best effort: the peer may be gone. Only
    /// while no other task writes to the connection, and before the
    /// transport is shut down. Nothing for a plain connection, or for a TLS
    /// module without `close`.
    pub fn closeNotify(self: *Connection) void {
        if (!build_options.use_tls) return;
        const c = if (self.tls_conn) |*c| c else return;
        if (self.close_notify_sent) return;
        self.close_notify_sent = true;
        if (comptime !@hasDecl(tls.Connection, "close")) return;
        const R = @typeInfo(@TypeOf(tls.Connection.close)).@"fn".return_type.?;
        if (comptime @typeInfo(R) == .error_union) c.close() catch {} else c.close();
    }

    /// The protocol the client and server agreed on through ALPN, or null
    /// for a plain connection or a TLS one that negotiated none. Points into
    /// `ServerConfig.Tls.alpn_protocols`.
    pub fn negotiatedProtocol(self: *const Connection) ?[]const u8 {
        if (!build_options.use_tls) return null;
        return if (self.tls_conn) |c| c.alpn_protocol else null;
    }

    /// The client's certificate (the leaf, DER) on a TLS connection whose
    /// handshake verified one, when the TLS module exposes it
    /// (`tls.Connection.peerCertificate`); null otherwise. Owned by the TLS
    /// connection, so valid until `deinit`.
    pub fn peerCertificate(self: *const Connection) ?[]const u8 {
        if (!build_options.use_tls) return null;
        if (comptime !@hasDecl(tls.Connection, "peerCertificate")) return null;
        return if (self.tls_conn) |*c| c.peerCertificate() else null;
    }

    /// A borrowed view of the layers above, for the parts of the library
    /// that are shared with the client and so can hold neither `Connection`.
    pub fn transport(self: *Connection) Transport {
        const has_tls = build_options.use_tls and self.tls_conn != null;
        return .{
            .reader = self.reader,
            .writer = self.writer,
            .tcp_reader = &self.tcp_reader,
            .tcp_writer = &self.tcp_writer,
            .tls_reader = if (has_tls) &self.tls_reader else null,
            .tls_writer = if (has_tls) &self.tls_writer else null,
        };
    }

    pub const ReadError = Transport.ReadError;
    pub const WriteError = Transport.WriteError;

    /// The real error behind a generic `error.ReadFailed`, if any was recorded.
    pub fn getReadError(self: *Connection) ?ReadError {
        return self.transport().getReadError();
    }

    /// The real error behind a generic `error.WriteFailed`, if any was
    /// recorded.
    pub fn getWriteError(self: *Connection) ?WriteError {
        return self.transport().getWriteError();
    }

    pub const isPeerGone = Transport.isPeerGone;

    /// Whether a read or write on this connection failed because the peer
    /// is gone. Asked instead of judging an error by its name: a handler's
    /// own `EndOfStream`, from a file or from a std helper at the end of
    /// the body, is spelled like a disconnect and is not one.
    /// The client's address: the socket peer, or what a PROXY protocol
    /// header named.
    pub fn peerAddress(self: *const Connection) std.Io.net.IpAddress {
        return self.proxied_peer orelse self.stream.socket.address;
    }

    pub fn peerGone(self: *Connection) bool {
        if (self.getWriteError()) |e| if (isPeerGone(e)) return true;
        if (self.getReadError()) |e| if (isPeerGone(e)) return true;
        return false;
    }
};

/// The one reply that cannot go through `Response`: what overran is the head
/// that would have said how to frame it. Fixed bytes instead, and
/// `Connection: close`, because the rest of that head is still queued on the
/// socket and there is no framing to skip it by.
fn sendServiceUnavailable(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("HTTP/1.1 503 Service Unavailable\r\n" ++
        "Connection: close\r\n" ++
        "Content-Length: 0\r\n" ++
        "\r\n");
    return w.flush();
}

/// How much unread input is thrown away before hanging up on the peer,
/// and how long that is given: a peer that has read the answer hangs up
/// within a round trip, and the request deadline may be off.
pub const linger_limit: usize = 64 * 1024;
pub const linger_timeout: std.Io.Duration = .fromSeconds(1);

fn sendHeadersTooLarge(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("HTTP/1.1 431 Request Header Fields Too Large\r\n" ++
        "Connection: close\r\n" ++
        "Content-Length: 0\r\n" ++
        "\r\n");
    return w.flush();
}

/// For a head llhttp refused: fixed bytes, since there is no request to
/// answer through `Response`, and `Connection: close`, since there is no
/// framing to find the next request by.
fn sendBadRequest(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("HTTP/1.1 400 Bad Request\r\n" ++
        "Connection: close\r\n" ++
        "Content-Length: 0\r\n" ++
        "\r\n");
    return w.flush();
}

/// The first line of the HTTP/2 connection preface (RFC 9113 3.4).
const h2_preface_line = "PRI * HTTP/2.0\r\n";

pub const Address = @import("config.zig").Address;
pub const Listener = @import("config.zig").Listener;

/// Fails with `error.AddressInUse` when some other socket is already bound
/// to `address`, which binding with SO_REUSEPORT (`Listener.reuse_address`)
/// would otherwise join without a word: a second copy of a server, or a
/// stale one, would then take a share of the connections. The probe binds
/// with SO_REUSEADDR alone, which conflicts with any listening socket on the
/// address, SO_REUSEPORT or not, but not with connections in TIME_WAIT
/// from a server that just stopped. Port zero is not checked (it binds a
/// fresh port), and nothing is checked when the probe socket cannot be had:
/// the real bind reports what it reports.
///
/// The server calls it before binding an IP listener that sets
/// `reuse_address`, and not for an inherited socket (`Listener.fd`), which
/// is already bound; call it before opening a socket of your own that is to
/// be handed over.
pub fn checkAddressFree(address: std.Io.net.IpAddress) error{AddressInUse}!void {
    if (address.getPort() == 0) return;
    const posix = std.posix;
    const sys = posix.system;
    const family: u32 = switch (address) {
        .ip4 => posix.AF.INET,
        .ip6 => posix.AF.INET6,
    };
    // Not on macOS, where the flag does not exist for socket(2).
    const cloexec: u32 = if (builtin.os.tag == .linux) posix.SOCK.CLOEXEC else 0;
    const rc = sys.socket(family, posix.SOCK.STREAM | cloexec, 0);
    if (posix.errno(rc) != .SUCCESS) return;
    const fd: posix.fd_t = @intCast(rc);
    defer _ = sys.close(fd);
    const one: c_int = 1;
    if (posix.errno(sys.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, @ptrCast(&one), @sizeOf(c_int))) != .SUCCESS) return;
    var storage: std.Io.Threaded.PosixAddress = undefined;
    const len = std.Io.Threaded.addressToPosix(&address, &storage);
    if (posix.errno(sys.bind(fd, &storage.any, len)) == .ADDRINUSE) {
        log.err("{f} is already in use: another process is listening on it", .{address});
        return error.AddressInUse;
    }
}

/// Where a listener is and what it speaks, for the line logged when it
/// starts: "https://127.0.0.1:8443 (HTTP/2, HTTP/1.1, HTTP/3)".
pub fn describeListener(w: *std.Io.Writer, cfg: *const Listener, address: Address) std.Io.Writer.Error!void {
    const secure = cfg.tls != null;
    switch (address) {
        .ip => |ip| try w.print("{s}://{f}", .{ if (secure) "https" else "http", ip }),
        .unix => |unix| try w.print("unix:{s}", .{unix.path}),
    }
    try w.writeAll(" (");
    var first = true;
    if (cfg.tls) |t| {
        for (t.alpn_protocols) |p| {
            const name = if (std.mem.eql(u8, p, "h2")) "HTTP/2" else if (std.mem.eql(u8, p, "http/1.1")) "HTTP/1.1" else p;
            try w.print("{s}{s}", .{ if (first) "" else ", ", name });
            first = false;
        }
    }
    if (first) {
        const h2c = !secure and cfg.http2_prior_knowledge and build_options.use_http2;
        if (cfg.http1 or !h2c) try w.writeAll("HTTP/1.1");
        if (h2c) try w.writeAll(if (cfg.http1) ", HTTP/2 cleartext" else "HTTP/2 cleartext");
        first = false;
    }
    for (cfg.extra_protocols) |p| try w.print(", {s}", .{p});
    if (cfg.proxy_protocol) try w.writeAll("; PROXY protocol");
    try w.writeAll(")");
}

fn setRequestTimeout(context: *anyopaque, io: std.Io, timeout: std.Io.Timeout) void {
    const timer: *Timer = @ptrCast(@alignCast(context));
    timer.set(io, timeout);
}

pub fn Server(comptime Ctx: type) type {
    const MiddlewareItem = struct {
        middleware: Middleware(Ctx),
        node: std.SinglyLinkedList.Node = .{},
    };

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        io: std.Io,
        router: Router(Ctx),
        ctx: if (Ctx == void) void else *Ctx,
        config: ServerConfig,
        active_connections: std.atomic.Value(u32),
        /// What the drain waits on: connections with a request in flight,
        /// from accept or the first byte of a request until they go back to
        /// waiting for one, and whether the drain is on. One word, so a
        /// request arriving as the drain starts is either counted before
        /// the drain looks or refused after seeing the flag: the two
        /// updates are ordered by the word, whichever comes second sees the
        /// first. A connection waiting between requests is not counted; it
        /// has nothing to lose to the cancel that follows the drain.
        busy: std.atomic.Value(Busy),
        /// The open HTTP/2 connections, so a drain can tell each one with
        /// GOAWAY that no new streams will be taken.
        h2_conns: if (build_options.use_http2) h2.Engine(Ctx).Registry else void =
            if (build_options.use_http2) .{} else {},
        /// The first listener's bound address, once `ready` is set. A
        /// listener given port zero has its real port here.
        address: Address,
        /// Every listener's bound address, in `config.listeners` order. Filled
        /// in before `ready` is set, and empty again once `run` has
        /// returned.
        addresses: []const Address = &.{},
        /// Set once `run` is listening. A server that fails before then
        /// never sets it: wait with `waitReady` instead, which also
        /// returns when `run` has stopped without getting there.
        ready: std.Io.Event,
        /// Set when the drain starts (and never reset). Long-lived handlers
        /// (WebSockets, event streams) can wait on it, through
        /// `Request.drain`, to finish early rather than be cut off at
        /// `timeout.shutdown`.
        draining: std.Io.Event = .unset,
        /// Run when `draining` is set: see `Request.drain_hooks`.
        drain_hooks: DrainHooks = .{},
        /// Set with `ready`, or when `run` stops before it is listening,
        /// with `start_error` saying why.
        settled: std.Io.Event = .unset,
        /// Why `run` stopped before it was listening.
        start_error: ?anyerror = null,
        _middleware_registry: std.SinglyLinkedList,
        request_buffers: RequestBuffersPool,
        /// The listeners while `run` serves them, for `reloadTls`; empty
        /// otherwise. Guarded by `tls_lock`, as is each one's
        /// `tls_material`.
        active_listeners: []ActiveListener = &.{},
        tls_lock: std.atomic.Mutex = .unlocked,

        /// A listener while `run` serves it: the socket, and the TLS
        /// material every connection accepted on it shares.
        const ActiveListener = struct {
            config: *const Listener,
            address: Address,
            server: std.Io.net.Server,
            /// Under `socket_per_acceptor`, the sockets for every accept
            /// loop after the first, which takes `server`.
            extra_servers: []std.Io.net.Server = &.{},
            /// On a TLS listener, what new connections handshake with.
            /// `reloadTls` replaces it, so it is read through `acquireTls`,
            /// under `tls_lock`.
            tls_material: ?*TlsMaterial = null,

            fn freeTls(l: *ActiveListener, allocator: std.mem.Allocator) void {
                if (build_options.use_tls) if (l.tls_material) |m| {
                    m.release(allocator);
                    l.tls_material = null;
                };
            }

            fn close(l: *ActiveListener, io: std.Io, allocator: std.mem.Allocator) void {
                for (l.extra_servers) |*s| s.deinit(io);
                allocator.free(l.extra_servers);
                l.extra_servers = &.{};
                l.server.deinit(io);
                l.freeTls(allocator);
            }

            /// The socket the `index`th accept loop takes connections from.
            fn socketFor(l: *ActiveListener, index: usize) *std.Io.net.Server {
                if (index == 0 or l.extra_servers.len == 0) return &l.server;
                return &l.extra_servers[index - 1];
            }
        };

        /// One accept loop. Several can share a listener's socket, so each
        /// keeps its own error rather than racing the others to store one on
        /// the listener.
        const Acceptor = struct {
            listener: *ActiveListener,
            /// Which executor the loop runs on, where the runtime has several.
            executor: usize = 0,
            /// The listener's socket, or under `socket_per_acceptor` one of
            /// its own.
            socket: *std.Io.net.Server,
            /// Why this loop gave up, once it has.
            err: ?AcceptError = null,
        };

        const AcceptError = @typeInfo(@typeInfo(@TypeOf(acceptConnections)).@"fn".return_type.?).error_union.error_set;

        const Busy = packed struct(u32) {
            count: u31 = 0,
            draining: bool = false,
        };

        pub fn init(allocator: std.mem.Allocator, io: std.Io, config: ServerConfig, ctx: if (Ctx == void) void else *Ctx) Self {
            return .{
                .allocator = allocator,
                .io = io,
                .router = Router(Ctx).init(allocator),
                .ctx = ctx,
                .config = config,
                .active_connections = std.atomic.Value(u32).init(0),
                .busy = .init(.{}),
                .address = undefined,
                .ready = .unset,
                ._middleware_registry = .{},
                .request_buffers = .init(allocator, io, config.request.buffer_size + body_read_reserve, config.response.write_buffer_size, request_arena_reserve),
            };
        }

        pub fn deinit(self: *Self) void {
            // Call deinit on all registered middlewares
            var it = self._middleware_registry.first;
            while (it) |node| {
                it = node.next;
                const item: *MiddlewareItem = @fieldParentPtr("node", node);
                item.middleware.deinit();
            }
            self.router.deinit();
            self.request_buffers.deinit();
        }

        /// Creates a middleware instance managed by the server.
        /// The middleware is allocated on the router's arena and will be freed when the server is deinit'd.
        /// Supports middlewares with init(Config) or init(Config, MiddlewareConfig) signatures.
        pub fn middleware(self: *Self, comptime M: type, config: M.Config) !Middleware(Ctx) {
            const arena = self.router.arena.allocator();
            const m = try arena.create(M);
            const init_info = @typeInfo(@TypeOf(M.init)).@"fn";
            // Zig 0.17 replaced `params` with `param_types`.
            const init_param_count = if (@hasField(@TypeOf(init_info), "params")) init_info.params.len else init_info.param_types.len;
            const made = switch (init_param_count) {
                1 => M.init(config),
                2 => M.init(config, MiddlewareConfig{
                    .arena = arena,
                    .allocator = self.allocator,
                }),
                else => @compileError(@typeName(M) ++ ".init must accept 1 or 2 parameters"),
            };
            // `init` may or may not be fallible.
            m.* = if (@typeInfo(@TypeOf(made)) == .error_union) try made else made;

            const mw = Middleware(Ctx).init(m);

            // Register for cleanup on deinit
            const item = try arena.create(MiddlewareItem);
            item.* = .{ .middleware = mw };
            self._middleware_registry.prepend(&item.node);

            return mw;
        }

        /// Accepts on every listener in `config.listeners` until canceled, then
        /// drains the connections in flight. Returns `error.Canceled` whenever
        /// it was canceled, even if it was failing for another reason by then.
        pub fn run(self: *Self) !void {
            self.serve() catch |err| {
                // Wakes whoever waits in `waitReady`; they would otherwise
                // wait for good.
                if (!self.settled.isSet()) {
                    self.start_error = err;
                    self.settled.set(self.io);
                }
                // A cancel that arrived while `serve` failed for another
                // reason is still pending, and is what the caller asked about.
                if (err != error.Canceled) try self.io.checkCancel();
                return err;
            };
        }

        /// Waits until `run` is listening, and returns what stopped it if it
        /// never got there.
        pub fn waitReady(self: *Self, io: std.Io) !void {
            try self.settled.wait(io);
            if (self.start_error) |err| return err;
        }

        fn serve(self: *Self) !void {
            const listeners = self.configuredListeners();
            if (self.config.max_connections) |max| {
                if (max == 0) {
                    log.err("config.max_connections is 0, so no connection could ever be served", .{});
                    return error.NoConnectionsAllowed;
                }
            }
            if (self.config.response.write_buffer_size == 0) {
                log.err("config.response.write_buffer_size is 0, which leaves no room to send a file through", .{});
                return error.NoWriteBuffer;
            }

            // Read once, and only when a listener sizes itself from it.
            const cpu_count: usize = for (listeners) |cfg| {
                if (cfg.acceptors == null) break try cgroup.cpuCount(self.io);
            } else 1;
            const executors = placement.executorCount(self.io);
            var acceptor_count: usize = 0;
            for (listeners) |cfg| acceptor_count += cfg.acceptorCountFor(cpu_count, executors);
            const default_backlog: u31 = for (listeners) |cfg| {
                if (cfg.kernel_backlog == null) break try somaxconn(self.io);
            } else 0;

            const active = try self.allocator.alloc(ActiveListener, listeners.len);
            defer self.allocator.free(active);
            const addresses = try self.allocator.alloc(Address, listeners.len);
            defer self.allocator.free(addresses);
            const acceptors = try self.allocator.alloc(Acceptor, acceptor_count);
            defer self.allocator.free(acceptors);
            var opened: usize = 0;
            defer for (active[0..opened]) |*l| l.close(self.io, self.allocator);
            for (listeners, active, addresses) |*cfg, *l, *address| {
                l.* = try self.open(cfg, cfg.kernel_backlog orelse default_backlog, cfg.acceptorCountFor(cpu_count, executors));
                opened += 1;
                address.* = l.address;
            }
            if (self.config.max_connections == ServerConfig.max_connections_from_fd_limit) {
                var sockets: usize = 0;
                for (active) |*l| sockets += 1 + l.extra_servers.len;
                const soft = fd_limit.softLimit();
                self.config.max_connections = if (soft) |n| fd_limit.maxConnections(n, executors orelse 1, sockets) else fd_limit.fallback_max_connections;
                // Logging allocates, which can swallow a cancel (see
                // `placement.concurrent`).
                const protection = self.io.swapCancelProtection(.blocked);
                defer _ = self.io.swapCancelProtection(protection);
                log.debug("at most {d} connections at once (open-file limit {?d})", .{ self.config.max_connections.?, soft });
            }
            // Out of `reloadTls`'s reach before the listeners close.
            self.lockTls();
            self.active_listeners = active;
            self.tls_lock.unlock();
            defer {
                self.lockTls();
                self.active_listeners = &.{};
                self.tls_lock.unlock();
            }
            // Grouped by listener, in listener order.
            var next_acceptor: usize = 0;
            for (active) |*l| {
                const n = l.config.acceptorCountFor(cpu_count, executors);
                for (acceptors[next_acceptor..][0..n], 0..) |*a, j| a.* = .{ .listener = l, .executor = j, .socket = l.socketFor(j) };
                next_acceptor += n;
            }

            self.addresses = addresses;
            defer self.addresses = &.{};
            self.address = addresses[0];
            self.ready.set(self.io);
            self.settled.set(self.io);

            {
                // Logging allocates, which can swallow a cancel (see
                // `placement.concurrent`): it must reach the wait below.
                const protection = self.io.swapCancelProtection(.blocked);
                defer _ = self.io.swapCancelProtection(protection);
                for (active) |*l| logListening(l.config, l.address);
            }

            var connections: std.Io.Group = .init;
            defer {
                _ = self.busy.fetchOr(.{ .draining = true }, .release);
                self.draining.set(self.io);
                self.drain_hooks.fire(self.io);
                connections.cancel(self.io);
            }

            // Set by the first accept loop to give up; a cancel arrives
            // through the wait instead. Either way the accept loops are
            // stopped before the connections are, so nothing new arrives
            // while the drain waits, and the drain runs either way: a
            // listener failing takes the whole server down, and the
            // requests in flight on the others deserve the same chance to
            // finish as on a shutdown.
            var stopped: std.Io.Event = .unset;
            var accepting: std.Io.Group = .init;
            defer accepting.cancel(self.io);
            for (acceptors, 0..) |*a, i| {
                // One loop per executor where the runtime has several, so each
                // accepts, and keeps, its own connections.
                placement.concurrent(&accepting, self.io, .{ .executor = a.executor }, acceptLoop, .{ self, a, &connections, &stopped }) catch |err| {
                    // A listener that already has a loop running is still
                    // served, only with fewer accepts waiting. The loops for
                    // a listener are spawned in a row, and a first one that
                    // fails ends the run below, so a predecessor on the same
                    // listener means one is running. Not so for a socket of
                    // its own: the kernel keeps handing it connections that
                    // no loop would ever take.
                    if (i > 0 and acceptors[i - 1].listener == a.listener and a.socket == acceptors[i - 1].socket) {
                        log.warn("Failed to spawn an extra accept loop for {f}: {}", .{ a.listener.address, err });
                        continue;
                    }
                    log.err("Failed to spawn the accept loop for {f}: {}", .{ a.listener.address, err });
                    // The loops already running may have accepted by now.
                    accepting.cancel(self.io);
                    self.drainConnections();
                    return err;
                };
            }

            // One per executor, so that each trims its own free list.
            for (0..executors orelse 1) |i| {
                placement.concurrent(&accepting, self.io, .{ .executor = i }, trimLoop, .{ self, i == 0 }) catch |err| {
                    log.debug("No task to trim the request buffers on executor {d}: {}", .{ i, err });
                };
            }

            stopped.wait(self.io) catch |err| switch (err) {
                error.Canceled => {
                    accepting.cancel(self.io);
                    self.drainConnections();
                    return err;
                },
            };

            accepting.cancel(self.io);
            self.drainConnections();
            for (acceptors) |*a| {
                if (a.err) |err| return err;
            }
            // Cannot happen: `stopped` is only set by an accept loop that
            // stored its error first, and every loop was joined above.
            unreachable;
        }

        fn lockTls(self: *Self) void {
            while (!self.tls_lock.tryLock()) std.atomic.spinLoopHint();
        }

        /// A reference to what a new connection on `l` handshakes with, or
        /// null on a listener without TLS. The caller releases it.
        fn acquireTls(self: *Self, l: *ActiveListener) ?*TlsMaterial {
            self.lockTls();
            defer self.tls_lock.unlock();
            const m = l.tls_material orelse return null;
            _ = m.refs.fetchAdd(1, .monotonic);
            return m;
        }

        /// Loads every TLS listener's certificate, key and client CAs again
        /// from its `tls` configuration (reading files again; for `pem`,
        /// whatever it holds now) and swaps them in. Connections accepted
        /// from then on handshake with the new ones. Connections already
        /// accepted, handshakes in progress included, keep the ones they
        /// started with, which are freed when the last of them closes.
        ///
        /// All or nothing: when any listener's fails to load, that error is
        /// returned and every listener keeps what it had. While the server
        /// is not running, it only checks that everything loads (`run`
        /// loads it when it starts). Safe from any task of the server's
        /// `Io`, concurrently with serving.
        ///
        /// What the TLS module must carry from a listener's old certificate
        /// to its new one, it does in `CertKeyPair.carryOver(new, old)`, if
        /// it declares that: BoringSSL's adapter keeps the session ticket
        /// keys, so tickets issued before a reload still resume.
        pub fn reloadTls(self: *Self) !void {
            if (!build_options.use_tls) return;
            const listeners = self.configuredListeners();
            const loaded = try self.allocator.alloc(?*TlsMaterial, listeners.len);
            defer self.allocator.free(loaded);
            @memset(loaded, null);
            defer for (loaded) |m| if (m) |x| x.release(self.allocator);
            for (listeners, loaded) |*cfg, *slot| {
                const tls_cfg = cfg.tls orelse continue;
                slot.* = try TlsMaterial.load(self.allocator, self.io, tls_cfg);
            }

            // Swapped in one go, so no listener serves the old material
            // after another has the new. What each had is released below
            // (in `loaded`'s place), outside the lock.
            self.lockTls();
            defer self.tls_lock.unlock();
            if (self.active_listeners.len != listeners.len) return;
            for (self.active_listeners, loaded) |*l, *slot| {
                const new = slot.* orelse continue;
                const old = l.tls_material orelse continue;
                if (comptime @hasDecl(tls.config.CertKeyPair, "carryOver")) new.auth.carryOver(&old.auth);
                l.tls_material = new;
                slot.* = old;
            }
        }

        /// One line per listener as it starts: where, and what it speaks.
        /// "listening on https://127.0.0.1:8443 (HTTP/2, HTTP/1.1)".
        fn logListening(cfg: *const Listener, address: Address) void {
            var buf: [256]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            describeListener(&w, cfg, address) catch {};
            log.info("listening on {s}", .{w.buffered()});
        }

        fn configuredListeners(self: *const Self) []const Listener {
            return if (self.config.listeners.len == 0) &default_listeners else self.config.listeners;
        }

        /// Loads the listener's TLS material and binds its socket.
        fn open(self: *Self, cfg: *const Listener, kernel_backlog: u31, acceptor_count: usize) !ActiveListener {
            var l: ActiveListener = .{ .config = cfg, .address = cfg.address, .server = undefined };
            errdefer l.freeTls(self.allocator);

            if (!cfg.http1 and (!build_options.use_http2 or (cfg.tls == null and !cfg.http2_prior_knowledge))) {
                log.err("{f} serves neither HTTP/1.x (http1 is off) nor HTTP/2 (needs use_http2, and http2_prior_knowledge on a cleartext listener)", .{cfg.address});
                return error.NoProtocols;
            }

            if (cfg.tls) |tls_cfg| {
                if (!build_options.use_tls) {
                    log.err("tls is set but the library was built with use_tls=false", .{});
                    return error.TlsNotConfigured;
                }
                if (!build_options.use_http2) {
                    for (tls_cfg.alpn_protocols) |p| if (std.mem.eql(u8, p, "h2")) {
                        log.err("tls.alpn_protocols offers h2, but the library was built without use_http2", .{});
                        return error.Http2NotConfigured;
                    };
                }
                l.tls_material = try TlsMaterial.load(self.allocator, self.io, tls_cfg);
            }

            if (cfg.socket_per_acceptor) try checkSocketPerAcceptor(cfg);

            if (cfg.fd) |fd| {
                if (cfg.socket_per_acceptor) {
                    log.err("socket_per_acceptor cannot be used with an inherited socket (fd)", .{});
                    return error.SocketPerAcceptorUnsupported;
                }
                l.server = try inheritSocket(self.io, fd, cfg.address);
                if (l.server.socket.address.getPort() != 0) l.address = .{ .ip = l.server.socket.address };
                return l;
            }

            l.server = switch (cfg.address) {
                .ip => |ip| blk: {
                    // SO_REUSEPORT would share the port with whoever has it.
                    if (cfg.reuse_address) try checkAddressFree(ip);
                    break :blk try ip.listen(self.io, .{
                        .kernel_backlog = kernel_backlog,
                        .reuse_address = cfg.reuse_address,
                    });
                },
                .unix => |unix| try unix.listen(self.io, .{ .kernel_backlog = kernel_backlog }),
            };
            errdefer l.server.deinit(self.io);
            if (cfg.address == .ip) l.address = .{ .ip = l.server.socket.address };

            if (cfg.socket_per_acceptor and acceptor_count > 1) {
                const extra = try self.allocator.alloc(std.Io.net.Server, acceptor_count - 1);
                var bound: usize = 0;
                errdefer {
                    for (extra[0..bound]) |*s| s.deinit(self.io);
                    self.allocator.free(extra);
                }
                // The address the first socket got, so a listener given port
                // zero binds every socket to the same port.
                for (extra) |*s| {
                    s.* = try l.address.ip.listen(self.io, .{
                        .kernel_backlog = kernel_backlog,
                        .reuse_address = true,
                    });
                    bound += 1;
                }
                l.extra_servers = extra;
            }
            return l;
        }

        /// Wraps a listening socket this process did not open. Under zio,
        /// which drives its own sockets non-blocking, it is made so too.
        fn inheritSocket(io: std.Io, fd: std.posix.fd_t, configured: Address) !std.Io.net.Server {
            const c = std.c;
            if (placement.executorCount(io) != null) {
                const flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
                if (flags < 0) return error.InvalidInheritedSocket;
                _ = c.fcntl(fd, c.F.SETFL, flags | @as(c_int, 1 << @bitOffsetOf(std.posix.O, "NONBLOCK")));
            }
            var storage: std.Io.Threaded.PosixAddress = undefined;
            var len: std.posix.socklen_t = @sizeOf(std.Io.Threaded.PosixAddress);
            const address: std.Io.net.IpAddress = if (c.getsockname(fd, &storage.any, &len) == 0 and
                (storage.any.family == std.posix.AF.INET or storage.any.family == std.posix.AF.INET6))
                std.Io.Threaded.addressFromPosix(&storage)
            else switch (configured) {
                .ip => |ip| ip,
                .unix => .{ .ip4 = .loopback(0) },
            };
            return .{ .socket = .{ .handle = fd, .address = address }, .options = {} };
        }

        fn checkSocketPerAcceptor(cfg: *const Listener) error{SocketPerAcceptorUnsupported}!void {
            if (builtin.os.tag != .linux) {
                log.err("socket_per_acceptor needs Linux, where SO_REUSEPORT spreads connections across the sockets", .{});
                return error.SocketPerAcceptorUnsupported;
            }
            if (cfg.address != .ip) {
                log.err("socket_per_acceptor needs an IP address, not a unix socket", .{});
                return error.SocketPerAcceptorUnsupported;
            }
            if (!cfg.reuse_address) {
                log.err("socket_per_acceptor needs reuse_address, which sets SO_REUSEPORT", .{});
                return error.SocketPerAcceptorUnsupported;
            }
        }

        /// A cancel is the normal end and is reported to nobody: the group
        /// swallows it, and `run` learns of it from its own wait. Anything
        /// else is the listener failing, and stops the whole run.
        fn acceptLoop(
            self: *Self,
            a: *Acceptor,
            connections: *std.Io.Group,
            stopped: *std.Io.Event,
        ) std.Io.Cancelable!void {
            self.acceptConnections(a.listener, a.socket, connections) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {
                    log.err("Listener {f} failed: {}", .{ a.listener.address, err });
                    a.err = err;
                    stopped.set(self.io);
                },
            };
        }

        /// Gives back, every `request_buffers_trim_interval`, the request
        /// buffer sets this executor's connections left unused since the
        /// last time, and the first executor's the shared ones too
        /// (`RequestBuffersPool.trimLocal`, `trimShards`).
        fn trimLoop(self: *Self, shards: bool) std.Io.Cancelable!void {
            while (true) {
                try self.io.sleep(request_buffers_trim_interval, .awake);
                self.request_buffers.trimLocal();
                if (shards) self.request_buffers.trimShards();
            }
        }

        fn acceptConnections(self: *Self, l: *ActiveListener, socket: *std.Io.net.Server, connections: *std.Io.Group) !void {
            // Grows while accepting keeps failing for want of resources, and
            // is reset by the first connection that gets through.
            var backoff_ms: u64 = 0;

            while (true) {
                try self.waitForConnectionSlot();

                const stream = socket.accept(self.io) catch |err| switch (err) {
                    // One connection went away between its SYN and our
                    // accept, which says nothing about the listener. Routine
                    // on a public address, where clients reset and scanners
                    // probe, so it is not worth a log line or a pause.
                    error.ConnectionAborted,
                    // Linux reports an error already pending on the new
                    // connection from accept itself (see accept(2)), so it
                    // belongs to one client, not to the listener.
                    error.ProtocolFailure,
                    => continue,
                    // The machine is out of something, for now. Sleeping and
                    // trying again turns that into latency; returning would
                    // turn a condition that clears on its own into an outage
                    // that needs a restart. `NetworkDown` is also a pending
                    // connection error on Linux, and `Unexpected` is where the
                    // rest of those (EHOSTUNREACH, ENETUNREACH, ...) end up.
                    // `BlockedByFirewall` can also be a security policy
                    // denying every accept, which would spin without a pause.
                    error.ProcessFdQuotaExceeded,
                    error.SystemFdQuotaExceeded,
                    error.SystemResources,
                    error.WouldBlock,
                    error.NetworkDown,
                    error.BlockedByFirewall,
                    error.Unexpected,
                    => {
                        backoff_ms = if (backoff_ms == 0) min_accept_backoff_ms else @min(backoff_ms * 2, max_accept_backoff_ms);
                        {
                            // Logging allocates, which can swallow a cancel
                            // (see `placement.concurrent`): it must reach the
                            // sleep below.
                            const protection = self.io.swapCancelProtection(.blocked);
                            defer _ = self.io.swapCancelProtection(protection);
                            log.warn("Accept failed: {}; retrying in {d}ms", .{ err, backoff_ms });
                        }
                        // A cancel is taken here, not deferred to the accept
                        // above with `recancel`. That accept keeps failing
                        // for its own reason -- the fd table is full, which
                        // is why we are in the backoff -- and an operation
                        // that completes with a result of its own has the
                        // cancellation re-armed rather than reported, so
                        // deferring would livelock.
                        try self.io.sleep(.fromMilliseconds(@intCast(backoff_ms)), .awake);
                        continue;
                    },
                    // The socket itself is gone, and no retry brings it back.
                    error.SocketNotListening,
                    error.Canceled,
                    => return err,
                };
                backoff_ms = 0;

                self.reserveConnectionSlot() catch |err| {
                    stream.close(self.io);
                    return err;
                };
                _ = self.busy.fetchAdd(.{ .count = 1 }, .acq_rel);
                // On the executor that accepted it, for its whole life.
                placement.concurrent(connections, self.io, .local, handleConnectionWrapper, .{ self, l, stream }) catch |err| {
                    log.err("Failed to spawn connection handler: {}", .{err});
                    self.finishRequest();
                    self.releaseConnectionSlot();
                    stream.close(self.io);
                    continue;
                };
            }
        }

        /// Waits for the connections already in flight, once the accept
        /// loops have been stopped.
        ///
        /// Runs under cancel protection: this is the shutdown, and a further
        /// cancel arriving mid-drain would abandon connections rather than
        /// finish with them. What bounds it is its own policy below, not
        /// whoever asked it to stop.
        ///
        /// Infallible, so that `run` reports what stopped it rather than a
        /// detail of how the drain went. Connections that
        /// outlast the wait are logged and left to the caller's deferred
        /// `group.cancel`, which tears them down either way.
        /// How long the final GOAWAY waits for the peer to answer the
        /// notice's PING.
        const h2_notice_wait: std.Io.Duration = .fromSeconds(1);

        fn drainConnections(self: *Self) void {
            const protection = self.io.swapCancelProtection(.blocked);
            defer _ = self.io.swapCancelProtection(protection);

            log.info("Graceful shutdown requested", .{});
            _ = self.busy.fetchOr(.{ .draining = true }, .acq_rel);
            self.draining.set(self.io);
            self.drain_hooks.fire(self.io);

            // HTTP/2 connections get a two-phase GOAWAY (RFC 9113 §6.8): a
            // notice now, the final one a round trip later, when the PING
            // sent with the notice comes back, or after `h2_notice_wait` for
            // a peer that does not answer. Each holds the drain open until
            // its final GOAWAY is out.
            var notice_deadline: ?std.Io.Clock.Timestamp = null;
            if (comptime build_options.use_http2) {
                if (self.h2_conns.beginDrain())
                    notice_deadline = std.Io.Clock.Timestamp.now(self.io, .awake).addDuration(.{ .raw = h2_notice_wait, .clock = .awake });
            }

            // Turned into a deadline once, so the budget covers the drain as
            // a whole. A per-wait duration would restart it every time a
            // connection closed, and a steady trickle would then hold the
            // shutdown open indefinitely.
            const timeout: std.Io.Timeout = if (self.config.timeout.shutdown) |duration|
                std.Io.Timeout.toDeadline(.{ .duration = .{ .raw = duration, .clock = .awake } }, self.io)
            else
                .none;

            while (true) {
                const state = self.busy.load(.acquire);
                const remaining = state.count;
                if (remaining == 0) return;

                if (timeout.toTimestamp(self.io)) |deadline| {
                    if (std.Io.Clock.Timestamp.now(self.io, .awake).compare(.gte, deadline)) {
                        log.warn("Shutdown timed out with {d} request(s) still in flight", .{remaining});
                        return;
                    }
                }

                var wait = timeout;
                if (notice_deadline) |nd| {
                    if (std.Io.Clock.Timestamp.now(self.io, .awake).compare(.gte, nd)) {
                        if (comptime build_options.use_http2) self.h2_conns.finishDrain();
                        notice_deadline = null;
                        continue;
                    }
                    const nd_timeout: std.Io.Timeout = .{ .deadline = nd };
                    wait = if (timeout.toTimestamp(self.io)) |d| (if (d.compare(.lt, nd)) timeout else nd_timeout) else nd_timeout;
                }

                log.info("Waiting for {} in-flight request(s) to finish", .{remaining});
                // Wakes when a request finishes, or when the deadline
                // arrives; the loop above decides which happened. Spurious
                // wakeups just re-read the count.
                self.io.futexWaitTimeout(Busy, &self.busy.raw, state, wait) catch |err| switch (err) {
                    // Cannot happen: protection is blocked for this whole
                    // function, so no Io call here is a cancelation point.
                    error.Canceled => unreachable,
                };
            }
        }

        /// Blocks while every connection slot is taken. Not accepting is the
        /// backpressure: what arrives meanwhile waits in the kernel's accept
        /// queue, `Listener.kernel_backlog` deep.
        fn waitForConnectionSlot(self: *Self) std.Io.Cancelable!void {
            const max = self.config.max_connections orelse return;
            while (true) {
                const active = self.active_connections.load(.acquire);
                if (active < max) return;
                log.debug("At the {d} connection cap; waiting for a slot", .{max});
                try self.io.futexWait(u32, &self.active_connections.raw, active);
            }
        }

        /// Takes the slot for a connection just accepted. The check above is
        /// what keeps a loop from accepting at the cap, but it is not one
        /// step with this, and every accept loop, on every listener, races
        /// for the same slots. A loop that lost the race waits here, holding its
        /// connection the way the backlog would have, so the cap is exact.
        fn reserveConnectionSlot(self: *Self) std.Io.Cancelable!void {
            const max = self.config.max_connections orelse {
                _ = self.active_connections.fetchAdd(1, .acq_rel);
                return;
            };
            var active = self.active_connections.load(.acquire);
            while (true) {
                if (active >= max) {
                    log.debug("At the {d} connection cap; waiting for a slot", .{max});
                    try self.io.futexWait(u32, &self.active_connections.raw, active);
                    active = self.active_connections.load(.acquire);
                    continue;
                }
                active = self.active_connections.cmpxchgWeak(active, active + 1, .acq_rel, .acquire) orelse return;
            }
        }

        /// Wakes every accept loop waiting for a slot. Waking one is not
        /// enough: it may be a loop that goes back to blocking in `accept`
        /// on an idle listener, while another holds a connection it cannot
        /// serve until it is woken.
        ///
        /// Only a release from the cap can have anyone to wake: the count
        /// never exceeds it, and every waiter sleeps on it being there.
        fn releaseConnectionSlot(self: *Self) void {
            const was = self.active_connections.fetchSub(1, .acq_rel);
            const max = self.config.max_connections orelse return;
            if (was >= max) self.io.futexWake(u32, &self.active_connections.raw, std.math.maxInt(u32));
        }

        /// Wakes the drain when this was the last one: zero is the only
        /// count it acts on, so the others are not worth a syscall.
        pub fn finishRequest(self: *Self) void {
            const was = self.busy.fetchSub(.{ .count = 1 }, .acq_rel);
            if (was.count == 1) self.io.futexWake(Busy, &self.busy.raw, 1);
        }

        const RequestWait = enum {
            arrived,
            peer_gone,
            /// The drain is on. The peer was told so, with a 503, and the
            /// connection is done.
            refused,
        };

        /// Waits for the first byte of a request, with nothing in flight:
        /// the drain does not wait for a connection here, and the cancel
        /// that follows it closes the socket cleanly.
        fn waitForRequest(self: *Self, connection: *Connection, busy: *bool) !RequestWait {
            busy.* = false;
            self.finishRequest();

            connection.reader.fillMore() catch |err| switch (err) {
                error.EndOfStream => return .peer_gone,
                error.ReadFailed => {
                    const e = connection.getReadError() orelse error.Unexpected;
                    // Nothing is in flight between requests, so a peer that
                    // went away here has cost us nothing.
                    if (Connection.isPeerGone(e)) return .peer_gone;
                    return e;
                },
            };

            const was = self.busy.fetchAdd(.{ .count = 1 }, .acq_rel);
            busy.* = true;
            if (was.draining) {
                busy.* = false;
                self.finishRequest();
                sendServiceUnavailable(connection.writer) catch
                    return connection.getWriteError() orelse error.Unexpected;
                return .refused;
            }
            return .arrived;
        }

        fn handleConnectionWrapper(self: *Self, l: *ActiveListener, stream: std.Io.net.Stream) std.Io.Cancelable!void {
            if (comptime have_auto_cancel) return runConnection(self, l, stream, null);

            if (self.config.timeout.request == null and self.config.timeout.keepalive == null) {
                return runConnection(self, l, stream, null);
            }

            var watch: Watch = .{};
            var future = self.io.concurrent(runConnection, .{ self, l, stream, &watch }) catch |err| {
                log.warn("No task to watch the connection deadline: {}; refusing", .{err});
                self.finishRequest();
                self.releaseConnectionSlot();
                stream.close(self.io);
                return;
            };
            defer future.cancel(self.io);

            watch.wait(self.io) catch |err| switch (err) {
                error.Timeout => {
                    log.debug("Connection exceeded its deadline", .{});
                    return;
                },
                error.Canceled => return error.Canceled,
            };

            // Collected here rather than by the defer, which would put a
            // cancelation request to a task partway through its teardown.
            future.await(self.io);
        }

        /// Runs on this task under zio, on a task of its own otherwise.
        fn runConnection(self: *Self, l: *ActiveListener, stream: std.Io.net.Stream, watch: ?*Watch) void {
            defer if (watch) |w| w.finish(self.io);

            handleConnection(self, l, stream, watch) catch |err| {
                if (err == error.Canceled) {
                    log.debug("Connection canceled", .{});
                    return;
                }
                // A peer disappearing mid-request is ordinary and would drown
                // out the failures worth looking at.
                if (Connection.isPeerGone(err)) {
                    log.debug("Connection closed by peer: {}", .{err});
                } else if (isMalformedRequest(err)) {
                    // Anyone who can reach the port can send bytes that are
                    // not HTTP, so this is not the server's error and must
                    // not flood the error log (nginx logs these at info, as
                    // the TLS handshake failures above are).
                    log.info("Malformed request: {}", .{err});
                } else {
                    log.err("Connection error: {}", .{err});
                }
            };
        }

        /// A request head the peer got wrong: llhttp refused it, or the
        /// connection ended inside it.
        fn isMalformedRequest(err: anyerror) bool {
            if (err == error.IncompleteRequest) return true;
            inline for (comptime std.meta.fieldNames(ParseError)) |name| {
                if (err == @field(anyerror, name)) return true;
            }
            return false;
        }

        /// Hangs up on a peer whose input was not all read, so the peer
        /// still gets the answer. Closing with input unread makes the kernel
        /// send a reset instead of a FIN, and a peer can throw the buffered
        /// answer away when a reset arrives. So the send side is shut first,
        /// which tells the peer there is nothing more to wait for, and what
        /// it sent is thrown away until it hangs up, or `linger_timeout`
        /// passes, or `linger_limit` bytes for a peer that keeps sending.
        ///
        /// Without a deadline to bound the reads, it waits out
        /// `linger_timeout` without reading instead, as Go's net/http does:
        /// time for the peer to read the answer before a reset can arrive.
        ///
        /// Throwing input away needs no request buffers, so the set is given
        /// back first and the reads go through `idle_read_buffer`.
        noinline fn lingeringClose(
            self: *Self,
            connection: *Connection,
            timer: *Timer,
            idle_read_buffer: []u8,
            buffers: *?*RequestBuffers,
        ) !void {
            if (buffers.*) |b| {
                connection.replaceReadBuffer(idle_read_buffer);
                connection.releaseWriteBuffer();
                self.request_buffers.release(b);
                buffers.* = null;
            }
            self.closeNotify(connection, timer);
            connection.stream.shutdown(self.io, .send) catch |err| switch (err) {
                // Already gone: nothing left to throw away.
                error.SocketUnconnected, error.ConnectionResetByPeer, error.ConnectionAborted => return,
                else => |e| return e,
            };
            if (!timer.canBound()) return self.io.sleep(linger_timeout, .awake);
            timer.set(self.io, .{ .duration = .{ .raw = linger_timeout, .clock = .awake } });
            defer timer.clear(self.io);
            _ = connection.reader.discardShort(linger_limit) catch {
                const cause = connection.getReadError() orelse error.Unexpected;
                // The peer hanging up is the end this waits for. The
                // deadline arrives as a cancel, and stays one.
                if (Connection.isPeerGone(cause)) return;
                return cause;
            };
        }

        /// `Connection.closeNotify`, bounded by `linger_timeout` where the
        /// timer can bound it: a peer that stopped reading must not hold the
        /// task on the last 24 bytes.
        fn closeNotify(self: *Self, connection: *Connection, timer: *Timer) void {
            if (connection.tls_conn == null or connection.close_notify_sent) return;
            const bounded = timer.canBound();
            if (bounded) timer.set(self.io, .{ .duration = .{ .raw = linger_timeout, .clock = .awake } });
            defer if (bounded) timer.clear(self.io);
            connection.closeNotify();
        }

        /// After a refused TLS handshake: the alert has been flushed, but
        /// closing with the client's flight still unread would make the
        /// kernel send a reset, which can overtake the alert. So shut down
        /// the send side and read what the client still sends, until it
        /// hangs up, `linger_timeout`, or `linger_limit` bytes. Skipped
        /// where the timer cannot bound the reads.
        noinline fn lingerAfterRefusal(self: *Self, stream: std.Io.net.Stream, timer: *Timer) void {
            if (!timer.canBound()) return;
            stream.shutdown(self.io, .send) catch return;
            timer.set(self.io, .{ .duration = .{ .raw = linger_timeout, .clock = .awake } });
            defer timer.clear(self.io);
            var buf: [512]u8 = undefined;
            var r = stream.reader(self.io, &buf);
            _ = r.interface.discardShort(linger_limit) catch {};
        }

        fn handleConnection(self: *Self, l: *ActiveListener, stream: std.Io.net.Stream, watch: ?*Watch) !void {
            defer self.releaseConnectionSlot();
            // The first request's deadlines run from here, handshake included.
            const accepted_at: std.Io.Clock.Timestamp = .now(self.io, .awake);

            // Counted since accept, so a handshake in progress is waited for
            // like a request. Handed back and taken again in `waitForRequest`.
            var busy = true;
            defer if (busy) self.finishRequest();

            defer stream.close(self.io);

            var timer: Timer = .init(watch);
            defer timer.clear(self.io);

            // The PROXY protocol header comes first, ahead of TLS.
            var proxied: proxy_protocol.Header = .{};
            if (l.config.proxy_protocol) {
                defer timer.clear(self.io);
                self.armDeadline(&timer, earlier(
                    deadlineAfter(accepted_at, self.config.timeout.read_header),
                    deadlineAfter(accepted_at, self.config.timeout.request),
                ));
                proxied = proxy_protocol.read(self.io, stream) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => {
                        log.info("PROXY protocol header refused: {}", .{err});
                        return;
                    },
                };
            }

            // What this connection handshakes with, held until it closes
            // (after `connection.deinit`), whatever `reloadTls` swaps in
            // meanwhile.
            const material: ?*TlsMaterial = if (build_options.use_tls) self.acquireTls(l) else null;
            defer if (material) |m| m.release(self.allocator);

            var connection: Connection = undefined;
            defer connection.deinit();

            // When the listener is TLS, upgrade the accepted stream and run
            // the request loop over the cleartext reader/writer. Otherwise
            // run it directly over the raw stream.
            if (build_options.use_tls) {
                if (material) |m| {
                    // The handshake is the one part of a connection's life
                    // the request loop's timeout cannot cover, since that
                    // loop does not exist yet. A peer that opens a socket
                    // and then stalls mid-handshake would otherwise hold a
                    // task and the connection's whole buffer reservation
                    // for as long as it likes -- cheaper for it than a
                    // slow request, which is bounded.
                    {
                        defer timer.clear(self.io);
                        self.armTimer(&timer, self.config.timeout.request);

                        connection.initTls(self.allocator, self.io, stream, &m.auth, m.clientAuth(), l.config.tls.?.alpn_protocols) catch |err| {
                            // tls.zig only saw the ciphertext reader or
                            // writer fail generically, so the cause is a
                            // layer down -- and when the handshake ran out
                            // of time, that cause is the cancel.
                            const cause = switch (err) {
                                error.ReadFailed => connection.getReadError() orelse err,
                                error.WriteFailed => connection.getWriteError() orelse err,
                                else => err,
                            };
                            if (cause == error.Canceled) {
                                log.debug("TLS handshake canceled", .{});
                                return error.Canceled;
                            }
                            if (Connection.isPeerGone(cause)) {
                                log.debug("TLS handshake abandoned by peer: {}", .{cause});
                            } else if (cause == error.OutOfMemory) {
                                log.err("TLS handshake failed: {}", .{cause});
                            } else {
                                // Anyone who can reach the port can fail a
                                // handshake at will (a scanner, a client that
                                // rejects the certificate or sends none), so
                                // this is not the server's error and must not
                                // flood the error log (nginx logs these at
                                // info too).
                                log.info("TLS handshake failed: {}", .{cause});
                                self.lingerAfterRefusal(stream, &timer);
                            }
                            return;
                        };
                    }

                    connection.proxied_peer = proxied.source;
                    connection.proxied_secure = proxied.ssl;
                    if (build_options.use_http2) {
                        if (connection.negotiatedProtocol()) |p| if (std.mem.eql(u8, p, "h2")) {
                            // The engine's tasks have all ended when it
                            // returns, so this is the only writer left.
                            try h2.Engine(Ctx).serve(self, l.config, true, &connection, &busy);
                            return self.closeNotify(&connection, &timer);
                        };
                    }
                    // An HTTP/2-only listener, and ALPN did not agree on it.
                    if (!l.config.http1) {
                        log.debug("closing a TLS connection that did not choose h2 on an HTTP/2-only listener", .{});
                        return self.closeNotify(&connection, &timer);
                    }
                    try self.handleRequests(l, &connection, &timer, &busy, accepted_at);
                    return self.closeNotify(&connection, &timer);
                }
            }

            try connection.initPlain(self.allocator, self.io, stream);
            connection.proxied_peer = proxied.source;
            connection.proxied_secure = proxied.ssl;
            return self.handleRequests(l, &connection, &timer, &busy, accepted_at);
        }

        /// Whether the peer sent, or may still send, input that was not
        /// read: the rest of a body, or a request pipelined behind this one.
        fn hasUnreadInput(connection: *Connection, parser: *RequestParser) bool {
            return !parser.isBodyComplete() or connection.reader.bufferedLen() > 0;
        }

        /// `start + duration` on the awake clock, or null for no limit.
        /// Whether `buffered`, the start of a request, holds its whole head:
        /// the blank line that ends it is there. A head ended by bare LFs
        /// is not recognized, which only costs a header deadline.
        fn headBuffered(buffered: []const u8) bool {
            return std.mem.indexOf(u8, buffered, "\r\n\r\n") != null;
        }

        fn deadlineAfter(start: std.Io.Clock.Timestamp, duration: ?std.Io.Duration) ?std.Io.Clock.Timestamp {
            const d = duration orelse return null;
            return start.addDuration(.{ .raw = d, .clock = .awake });
        }

        /// The sooner of two optional deadlines.
        fn earlier(a: ?std.Io.Clock.Timestamp, b: ?std.Io.Clock.Timestamp) ?std.Io.Clock.Timestamp {
            const x = a orelse return b;
            const y = b orelse return a;
            return if (x.compare(.lt, y)) x else y;
        }

        /// Arms the timer for `deadline`, or clears it for none.
        fn armDeadline(self: *Self, timer: *Timer, deadline: ?std.Io.Clock.Timestamp) void {
            if (deadline) |d| timer.set(self.io, .{ .deadline = d }) else timer.clear(self.io);
        }

        /// Cleared when `duration` is unset, so an earlier deadline does not
        /// carry into a wait meant to be unbounded.
        fn armTimer(self: *Self, timer: *Timer, duration: ?std.Io.Duration) void {
            if (duration) |d| {
                timer.set(self.io, .{ .duration = .{ .raw = d, .clock = .awake } });
            } else {
                timer.clear(self.io);
            }
        }

        /// Applies `ServerConfig.response` to a response the server built,
        /// for every engine.
        pub fn configureResponse(self: *const Self, res: *Response) void {
            res.send_date = self.config.response.date;
            res.default_content_type = self.config.response.default_content_type;
            res.error_format = self.config.errors;
        }

        /// The client address for a request from `peer` with `headers`,
        /// through `X-Forwarded-For` as far as `trusted_proxy_hops` allows.
        pub fn clientAddress(self: *const Self, peer: std.Io.net.IpAddress, headers: *const Headers) std.Io.net.IpAddress {
            return remoteAddress(peer, headers, self.config.trusted_proxy_hops);
        }

        /// `remote_address`, `secure` and `forwarded_host` for a request
        /// from `connection`, through the trusted proxies, for an engine
        /// other than the HTTP/1.x loop.
        pub fn applyForwarded(self: *const Self, request: *Request, connection: *const Connection) void {
            applyForwardedFn(request, connection.peerAddress(), self.config.trusted_proxy_hops);
        }

        /// `applyForwarded` for an engine with no `Connection` (HTTP/3 over
        /// UDP): the peer address is given directly.
        pub fn applyForwardedFrom(self: *const Self, request: *Request, peer: std.Io.net.IpAddress) void {
            applyForwardedFn(request, peer, self.config.trusted_proxy_hops);
        }

        /// Routes `req` and runs its handler, with the middleware, writing to
        /// `res`. For a protocol engine other than the HTTP/1.x loop -- an
        /// HTTP/2 stream, whose request and response are built over a body
        /// source and a sink -- so it serves the same router. A URL the
        /// router cannot parse is answered 400 here; any other error is the
        /// handler's, and the caller decides what it means for its stream.
        pub fn dispatch(self: *Self, req: *Request, res: *Response) !void {
            const found = self.router.findHandler(req) catch |err| switch (err) {
                error.InvalidEscapeSequence, error.TooManyQueryParams, error.TooManyParams => {
                    res.status = .bad_request;
                    return;
                },
                else => |e| return e,
            };
            const miss: ?Router(Ctx).Miss = if (found == null) try self.router.miss(req) else null;
            var executor = Executor(Ctx){
                .req = req,
                .res = res,
                .ctx = self.ctx,
                .action = if (found) |r| r.action else null,
                .middlewares = if (found) |r| r.middlewares else miss.?.middlewares,
                .allow = if (miss) |m| m.allow else null,
                .error_handler = self.config.error_handler,
            };
            try executor.run();
        }

        /// Throws away the rest of a request body the handler left unread,
        /// up to `max` bytes: whether the connection can carry on. On a
        /// frame of its own, so the scratch buffer is not part of the
        /// request loop's frame, under every handler, for the life of the
        /// connection (an upgraded one's included).
        noinline fn discardBody(parser: *RequestParser, connection: *Connection, max: usize) error{Canceled}!bool {
            var scratch: [4096]u8 = undefined;
            // No decoding: this is throwing the body away to get back to the
            // connection, and `max` bounds what the peer sent rather than
            // what it would decode to.
            var body_reader = RequestBodyReader.init(parser, connection.transport(), &scratch);
            if (body_reader.interface.discardShort(max + 1)) |consumed| {
                return consumed <= max;
            } else |_| {
                // A cancel is the request timing out, not a body worth
                // giving up on quietly.
                if (body_reader.err) |e| if (e == error.Canceled) return error.Canceled;
                return false;
            }
        }

        /// Runs the HTTP request loop over a connection: each request is
        /// parsed, served and answered before the next is looked at, so
        /// pipelined requests are answered in order without any more
        /// machinery than a keepalive connection needs.
        fn handleRequests(
            self: *Self,
            l: *ActiveListener,
            connection: *Connection,
            timer: *Timer,
            busy: *bool,
            accepted_at: std.Io.Clock.Timestamp,
        ) !void {
            var idle_read_buffer: [idle_read_buffer_len]u8 = undefined;
            connection.useReadBuffer(&idle_read_buffer);
            var buffers: ?*RequestBuffers = null;
            defer if (buffers) |b| {
                connection.releaseWriteBuffer();
                self.request_buffers.release(b);
            };

            var request: Request = .{
                // The pooled arena, once a request has arrived.
                .arena = undefined,
                .io = self.io,
                .transport = connection.transport(),
                .parser = undefined,
                .config = self.config.request,
                .remote_address = connection.peerAddress(),
                .listener = l.config,
                .secure = (build_options.use_tls and l.config.tls != null) or connection.proxied_secure,
                .drain = &self.draining,
                .drain_hooks = &self.drain_hooks,
                .peer_certificate = connection.peerCertificate(),
                ._timeout_context = timer,
                ._set_timeout = setRequestTimeout,
            };

            var parser: RequestParser = undefined;
            try parser.init(&request);
            defer parser.deinit();

            request.parser = &parser;

            var request_count: usize = 0;

            while (true) {
                // Nothing buffered means the next request has not begun.
                // The first is waited for under the request deadline, which
                // runs from accept; a later one under the keepalive
                // deadline, and its request deadline runs from arrival. A
                // request pipelined behind the last one is already here.
                const first = request_count == 0;
                // Whether the wait below left a timer armed that the request
                // itself must replace or clear.
                var wait_armed = false;
                if (connection.reader.bufferedLen() == 0) {
                    if (!self.config.request.keep_buffers_between_requests) {
                        if (buffers) |b| {
                            connection.useReadBuffer(&idle_read_buffer);
                            connection.releaseWriteBuffer();
                            self.request_buffers.release(b);
                            buffers = null;
                        }
                    }
                    const wait_timeout = if (first) self.config.timeout.request else self.config.timeout.keepalive;
                    self.armTimer(timer, wait_timeout);
                    wait_armed = wait_timeout != null;
                    switch (try self.waitForRequest(connection, busy)) {
                        .arrived => {},
                        .peer_gone => return,
                        // The request it refused was not read.
                        .refused => return self.lingeringClose(connection, timer, &idle_read_buffer, &buffers),
                    }
                }
                // Cleartext HTTP/2 with prior knowledge: the first bytes are
                // the HTTP/2 preface rather than a request line.
                if (build_options.use_http2 and first and l.config.http2_prior_knowledge and !(build_options.use_tls and l.config.tls != null)) {
                    const is_h2 = h2.sniffPreface(connection.reader) catch
                        return connection.getReadError() orelse error.Unexpected;
                    if (is_h2) {
                        timer.clear(self.io);
                        return h2.Engine(Ctx).serve(self, l.config, false, connection, busy);
                    }
                }
                // An HTTP/2-only cleartext listener: no preface, no service.
                if (!l.config.http1 and !(build_options.use_tls and l.config.tls != null)) {
                    log.debug("closing a connection that did not open with the HTTP/2 preface on an HTTP/2-only listener", .{});
                    return;
                }
                // A request runs to `timeout.request` from its arrival (the
                // first from accept), and its head must arrive within
                // `timeout.read_header` of the same point, whichever is
                // sooner; then the request deadline alone applies.
                //
                // A head that is already buffered whole (the usual case: it
                // came in one read) is parsed without waiting, so it needs no
                // header deadline: the timer is set once per request rather
                // than twice, and without a request deadline the clock is not
                // read at all. A wait timer still armed then lasts through
                // the parse, which does not wait, and is replaced after it.
                const head_buffered = headBuffered(connection.reader.buffered());
                const needs_clock = self.config.timeout.request != null or
                    (!head_buffered and self.config.timeout.read_header != null);
                const started_at: std.Io.Clock.Timestamp = if (first or !needs_clock) accepted_at else .now(self.io, .awake);
                const request_deadline = if (needs_clock) deadlineAfter(started_at, self.config.timeout.request) else null;
                const header_deadline = earlier(deadlineAfter(started_at, self.config.timeout.read_header), request_deadline);
                if (!head_buffered) self.armDeadline(timer, header_deadline);
                request_count += 1;

                if (buffers == null) {
                    const b = try self.request_buffers.acquire(@intFromPtr(connection));
                    buffers = b;
                    connection.useReadBuffer(b.read_buffer);
                    connection.useWriteBuffer(b.write_buffer);
                    request.arena = b.arena.allocator();
                }

                parseHeaders(connection.reader, &parser) catch |err| switch (err) {
                    error.EndOfStream => return,
                    error.ReadFailed => return connection.getReadError() orelse error.Unexpected,
                    error.HeadersTooLarge => {
                        log.debug("Request head did not fit in {d} bytes", .{self.config.request.buffer_size});
                        sendHeadersTooLarge(connection.writer) catch
                            return connection.getWriteError() orelse error.Unexpected;
                        return self.lingeringClose(connection, timer, &idle_read_buffer, &buffers);
                    },
                    error.TooManyHeaders => {
                        log.debug("Request had more than {d} headers", .{self.config.request.max_header_count});
                        sendHeadersTooLarge(connection.writer) catch
                            return connection.getWriteError() orelse error.Unexpected;
                        return self.lingeringClose(connection, timer, &idle_read_buffer, &buffers);
                    },
                    // A head that is not HTTP/1.x: 400, and a lingering
                    // close, so the peer reads the answer and a FIN rather
                    // than a reset for the bytes it sent after. An HTTP/2
                    // preface (a client that went ahead with HTTP/2 although
                    // ALPN did not agree on it) gets the close alone: it
                    // would read an HTTP/1.1 answer as a frame. Logged at
                    // info, as `runConnection` logs the other malformed
                    // requests: any peer can send one.
                    //
                    // So does a first request line that does not start with
                    // a method on a listener that also takes HTTP/2 with
                    // prior knowledge: it may be an HTTP/2 client's preface
                    // gone wrong, which RFC 9113 section 3.4 makes a
                    // connection error, and that client would read a 400 as
                    // a broken frame. A malformed HTTP/1.x head after a
                    // method still gets the 400.
                    error.InvalidMethod,
                    error.InvalidUrl,
                    error.InvalidHeaderToken,
                    error.InvalidHeaderValue,
                    error.InvalidVersion,
                    error.InvalidStatus,
                    error.InvalidChunkSize,
                    error.UnexpectedContentLength,
                    error.ParseFailed,
                    => |e| {
                        log.info("Malformed request: {}", .{e});
                        const h2c = build_options.use_http2 and l.config.http2_prior_knowledge and
                            !(build_options.use_tls and l.config.tls != null);
                        const bad_preface = h2c and first and e == error.InvalidMethod;
                        if (!bad_preface and !std.mem.startsWith(u8, connection.reader.buffered(), h2_preface_line)) {
                            sendBadRequest(connection.writer) catch
                                return connection.getWriteError() orelse error.Unexpected;
                        }
                        return self.lingeringClose(connection, timer, &idle_read_buffer, &buffers);
                    },
                    else => |e| return e,
                };
                // The head is in: from here the request deadline alone.
                if (head_buffered) {
                    if (request_deadline != null or wait_armed) self.armDeadline(timer, request_deadline);
                } else if (header_deadline != null and (request_deadline == null or !header_deadline.?.compare(.eq, request_deadline.?))) {
                    self.armDeadline(timer, request_deadline);
                }

                // This is per request, not per connection: a keepalive
                // connection may carry a different forwarding chain on every
                // request. Starting from the socket peer also makes an absent
                // or invalid chain fail closed instead of retaining the last
                // request's forwarded address.
                request.secure = (build_options.use_tls and l.config.tls != null) or connection.proxied_secure;
                applyForwardedFn(&request, connection.peerAddress(), self.config.trusted_proxy_hops);

                var response = try Response.init(request.arena, connection, self.config.response.max_header_count);
                self.configureResponse(&response);
                defer response.deinit();
                response.head = request.method == .head;
                response.http10 = request.version_major == 1 and request.version_minor == 0;
                response.request = &request;
                request.response = &response;

                // A body declared longer than allowed is refused unread
                // (and before any 100 Continue): 413, and the connection
                // closes, since the body may still be coming.
                if (self.config.request.max_content_length) |max| {
                    if (request.content_length) |len| if (len > max) {
                        response.status = .payload_too_large;
                        response.content_type = .text;
                        response.body = "413 Content Too Large\n";
                        response.keepalive = false;
                        try response.write();
                        if (hasUnreadInput(connection, &parser)) try self.lingeringClose(connection, timer, &idle_read_buffer, &buffers);
                        return;
                    };
                }

                // Handle Expect header (100-continue)
                if (request.headers.get("Expect")) |expect| {
                    if (std.ascii.eqlIgnoreCase(expect, "100-continue")) {
                        // RFC 9110 10.1.1: ignored in an HTTP/1.0 request.
                        request.expects_continue = !response.http10;
                    } else {
                        // Unknown Expect value - return 417
                        response.status = .expectation_failed;
                        response.keepalive = false;
                        try response.write();
                        if (hasUnreadInput(connection, &parser)) try self.lingeringClose(connection, timer, &idle_read_buffer, &buffers);
                        return;
                    }
                }

                // llhttp ends a CONNECT at its head, Content-Length or not,
                // so whatever follows is not a request.
                if (!parser.shouldKeepAlive() or request.method == .connect) {
                    response.keepalive = false;
                }

                // Check if we've reached the request count limit
                if (self.config.timeout.request_count) |max_count| {
                    if (request_count >= max_count) {
                        response.keepalive = false;
                    }
                }

                const found = self.router.findHandler(&request) catch |err| switch (err) {
                    // The request's own doing, and the connection is fine.
                    error.InvalidEscapeSequence, error.TooManyQueryParams, error.TooManyParams => {
                        response.status = .bad_request;
                        response.keepalive = false;
                        try response.write();
                        if (hasUnreadInput(connection, &parser)) try self.lingeringClose(connection, timer, &idle_read_buffer, &buffers);
                        return;
                    },
                    else => |e| return e,
                };
                const miss: ?Router(Ctx).Miss = if (found == null) try self.router.miss(&request) else null;
                var executor = Executor(Ctx){
                    .req = &request,
                    .res = &response,
                    .ctx = self.ctx,
                    .action = if (found) |r| r.action else null,
                    .middlewares = if (found) |r| r.middlewares else miss.?.middlewares,
                    .allow = if (miss) |m| m.allow else null,
                    .error_handler = self.config.error_handler,
                };
                executor.run() catch |err| switch (err) {
                    error.ReadFailed => return connection.getReadError() orelse error.Unexpected,
                    error.WriteFailed => return connection.getWriteError() orelse error.Unexpected,
                    // `Response.abort`: the connection closes under the
                    // unfinished response, which is the abort.
                    error.ResponseAborted => {
                        log.debug("Response aborted ({f} {s})", .{ request.method, request.url });
                        return;
                    },
                    else => |e| return e,
                };

                if (!parser.isBodyComplete()) {
                    const max = self.config.request.max_body_size;
                    const drainable = blk: {
                        // The peer is holding the body until it hears 100
                        // Continue, which was never sent. There is nothing
                        // to drain, and a read would wait for it. A
                        // peer that sent the body anyway is not waiting, and
                        // its body is drained like any other.
                        if (request.expects_continue and connection.reader.bufferedLen() == 0) break :blk false;
                        // What the wire carried, which is what there is left
                        // to throw away -- and still readable after decoding
                        // took the header off.
                        const n = request.content_length orelse break :blk false;
                        break :blk n <= max;
                    };
                    if (drainable) {
                        if (!try discardBody(&parser, connection, max)) response.keepalive = false;
                    } else {
                        response.keepalive = false;
                    }
                }

                if (self.busy.load(.acquire).draining) {
                    response.keepalive = false;
                }

                try response.write();

                if (!response.keepalive) {
                    // Input after a 101 belongs to the upgraded protocol.
                    if (response.status != .switching_protocols and hasUnreadInput(connection, &parser)) {
                        try self.lingeringClose(connection, timer, &idle_read_buffer, &buffers);
                    }
                    break;
                }

                parser.reset();
                request.reset();
                _ = buffers.?.arena.reset(.retain_capacity);
                connection.rewindReader();
            }
        }
    };
}

test {
    _ = RequestParser;
}

test "Server: an empty listener list resolves to the default" {
    var server = Server(void).init(std.testing.allocator, std.testing.io, .{ .listeners = &.{} }, {});
    defer server.deinit();

    const listeners = server.configuredListeners();
    try std.testing.expectEqual(@as(usize, 1), listeners.len);
    const ip = listeners[0].address.ip;
    try std.testing.expect(ip == .ip4);
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, ip.ip4.bytes);
    try std.testing.expectEqual(@as(u16, 8080), ip.ip4.port);
}

test "trusted proxy hops select X-Forwarded-For from the right" {
    var headers = try Headers.init(std.testing.allocator, 4);
    defer headers.deinit(std.testing.allocator);
    try headers.add("X-Forwarded-For", "192.0.2.99, 203.0.113.10");
    try headers.add("x-forwarded-for", "198.51.100.7");

    const peer = try std.Io.net.IpAddress.parse("127.0.0.1", 4321);

    const direct = remoteAddress(peer, &headers, 0);
    try std.testing.expect(direct.ip4.eql(peer.ip4));

    const one = remoteAddress(peer, &headers, 1);
    try std.testing.expectEqual([4]u8{ 198, 51, 100, 7 }, one.ip4.bytes);
    try std.testing.expectEqual(@as(u16, 0), one.ip4.port);

    const two = remoteAddress(peer, &headers, 2);
    try std.testing.expectEqual([4]u8{ 203, 0, 113, 10 }, two.ip4.bytes);

    const three = remoteAddress(peer, &headers, 3);
    try std.testing.expectEqual([4]u8{ 192, 0, 2, 99 }, three.ip4.bytes);

    // More trusted hops than the proxy supplied cannot establish a client
    // address, so it is safer to expose the connected peer.
    const too_short = remoteAddress(peer, &headers, 4);
    try std.testing.expect(too_short.ip4.eql(peer.ip4));

    // A malformed address anywhere in the chain makes its ordering
    // ambiguous/untrustworthy and likewise falls back to the peer.
    try headers.put("X-Forwarded-For", "not-an-address, 203.0.113.10");
    const malformed = remoteAddress(peer, &headers, 2);
    try std.testing.expect(malformed.ip4.eql(peer.ip4));
}

/// A Connection with no real transport, in TLS mode, so the error accessors
/// can be driven directly. Only the `err` fields are read.
fn testTlsConnection() Connection {
    var conn: Connection = undefined;
    conn.initWriterForTesting(undefined);
    conn.tls_conn = .{ .input = undefined, .output = undefined, .cipher = undefined };
    conn.tls_reader.err = null;
    conn.tls_writer.err = null;
    return conn;
}

test "Connection: error accessors descend past the TLS layer's generic error" {
    if (!build_options.use_tls) return error.SkipZigTest;

    { // a transport write failure: TLS records WriteFailed, TCP has the cause
        var conn = testTlsConnection();
        conn.tls_writer.err = error.WriteFailed;
        conn.tcp_writer.err = error.ConnectionResetByPeer;
        try std.testing.expectEqual(error.ConnectionResetByPeer, conn.getWriteError().?);
    }
    { // same on the read side
        var conn = testTlsConnection();
        conn.tls_reader.err = error.ReadFailed;
        conn.tcp_reader.err = error.Canceled;
        try std.testing.expectEqual(error.Canceled, conn.getReadError().?);
    }
}

test "Connection: a TLS-level failure is reported as itself" {
    if (!build_options.use_tls) return error.SkipZigTest;

    { // not a transport failure, so there is nothing below to descend to
        var conn = testTlsConnection();
        conn.tls_reader.err = error.TlsBadRecordMac;
        conn.tcp_reader.err = error.ConnectionResetByPeer;
        try std.testing.expectEqual(error.TlsBadRecordMac, conn.getReadError().?);
    }
    { // and with nothing recorded anywhere there is no error to report
        var conn = testTlsConnection();
        try std.testing.expectEqual(@as(?anyerror, null), conn.getWriteError());
    }
}

test "Connection: the placeholders it descends past stay out of its error sets" {
    // `ReadFailed`/`WriteFailed` mean only "the layer below failed", which
    // is what the accessors exist to look past. They must not survive into
    // what a caller can be handed.
    inline for (comptime std.meta.fieldNames(Connection.ReadError)) |e_name| {
        try std.testing.expect(!std.mem.eql(u8, e_name, "ReadFailed"));
    }
    inline for (comptime std.meta.fieldNames(Connection.WriteError)) |e_name| {
        try std.testing.expect(!std.mem.eql(u8, e_name, "WriteFailed"));
    }
}

test "Connection: isPeerGone separates a departed peer from a real failure" {
    try std.testing.expect(Connection.isPeerGone(error.EndOfStream));
    try std.testing.expect(Connection.isPeerGone(error.ConnectionResetByPeer));
    // Closed mid-record: a record was cut, which is worth hearing about.
    try std.testing.expect(!Connection.isPeerGone(error.TlsConnectionTruncated));
    try std.testing.expect(!Connection.isPeerGone(error.TlsBadRecordMac));
    try std.testing.expect(!Connection.isPeerGone(error.Canceled));
}

/// One connection's bytes through `handleConnectionWrapper` over a socket pair:
/// HTTP/1.1, or HTTP/2 with prior knowledge when the library has it. The
/// handlers hand request headers back as response headers and the body
/// back as the body, so what the peer controls reaches the response side
/// too (the HTTP/1 writer, or the HTTP/2 engine's sink).
fn fuzzConnection(input: []const u8) !void {
    // An `Io` of its own: under `--fuzz`, Zig 0.17's test runner gives every
    // input a fresh `std.testing.allocator` but keeps `std.testing.io`,
    // which allocates its tasks from the allocator it was made with, so its
    // tasks would outlive the allocator they came from.
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const listener: @import("config.zig").Listener = .{
        .address = .{ .ip = .{ .ip4 = .loopback(0) } },
        .http2_prior_knowledge = build_options.use_http2,
    };
    var server = Server(void).init(std.testing.allocator, io, .{ .listeners = &.{listener} }, {});
    defer server.deinit();
    const handlers = struct {
        fn echo(req: *Request, res: *Response) !void {
            for (req.headers.keys[0..req.headers.len], req.headers.values[0..req.headers.len]) |name, value| {
                if (std.ascii.startsWithIgnoreCase(name, "x-")) try res.header(name, value);
            }
            if (req.headers.get("x-trailer")) |value| try res.trailer("x-trailer", value);
            // As a handler should: a body the peer got wrong is its error.
            res.body = (req.body() catch {
                res.status = .bad_request;
                return;
            }) orelse "";
        }
    };
    server.router.get("/", handlers.echo);
    server.router.post("/", handlers.echo);
    server.router.put("/*rest", handlers.echo);

    var l: Server(void).ActiveListener = .{ .config = &listener, .address = listener.address, .server = undefined };
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) return error.SocketPair;
    defer _ = std.c.close(fds[1]);
    const stream: std.Io.net.Stream = .{ .socket = .{ .handle = fds[0], .address = .{ .ip4 = .loopback(40000) } } };

    // As the accept loop leaves it.
    _ = server.busy.fetchAdd(.{ .count = 1 }, .acq_rel);
    try server.reserveConnectionSlot();
    // With the deadline watch the accept loop gives it, which also bounds
    // a lingering close rather than sleeping it out.
    var future = try io.concurrent(Server(void).handleConnectionWrapper, .{ &server, &l, stream });
    var finished = false;
    defer if (!finished) future.cancel(io) catch {};
    var wrote: usize = 0;
    while (wrote < input.len) {
        const n = std.c.write(fds[1], input[wrote..].ptr, input.len - wrote);
        if (n <= 0) break; // the server hung up first
        wrote += @intCast(n);
    }
    _ = std.c.shutdown(fds[1], std.c.SHUT.WR);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    while (true) {
        var pfd = [_]std.c.pollfd{.{ .fd = fds[1], .events = std.c.POLL.IN, .revents = 0 }};
        // The peer is done, so the server must finish on its own.
        if (std.c.poll(&pfd, 1, 5_000) == 0) return error.ConnectionHung;
        var buf: [4096]u8 = undefined;
        const n = std.c.read(fds[1], &buf, buf.len);
        if (n <= 0) break;
        try out.appendSlice(std.testing.allocator, buf[0..@intCast(n)]);
    }
    finished = true;
    future.await(io) catch {};

    // Every response the server wrote is a response: an HTTP/1.1 status
    // line, or (HTTP/2) frames that start with its SETTINGS.
    if (out.items.len > 0) {
        if (std.mem.startsWith(u8, out.items, "HTTP/1.")) {
            var it = std.mem.splitSequence(u8, out.items, "\r\n");
            while (it.next()) |line| for (line) |ch| {
                // No header value smuggled a line break or a NUL out.
                try std.testing.expect(ch != '\r' and ch != '\n' and ch != 0 or !std.ascii.startsWithIgnoreCase(line, "x-"));
            };
        } else {
            try std.testing.expect(build_options.use_http2);
            try std.testing.expect(out.items.len >= 9 and out.items[3] == 0x04);
        }
    }
    // The connection gave back what it held.
    try std.testing.expectEqual(@as(u32, 0), server.active_connections.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), server.busy.load(.acquire).count);
}

test "fuzz: a connection's bytes, HTTP/1.1 or HTTP/2 with prior knowledge" {
    const preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
    // A client's SETTINGS (empty), then HEADERS on stream 1 with END_STREAM
    // and END_HEADERS: :method GET, :scheme http, :path /, :authority
    // localhost, x-a: b (HPACK, literal without indexing for the last two).
    const h2_get = preface ++ "\x00\x00\x00\x04\x00\x00\x00\x00\x00" ++
        "\x00\x00\x16\x01\x05\x00\x00\x00\x01" ++ "\x82\x86\x84\x01\x09localhost" ++ "\x00\x03x-a\x01b";
    try @import("fuzz.zig").bytes(struct {
        fn check(input: []const u8) !void {
            try fuzzConnection(input);
        }
    }.check, &.{
        "GET / HTTP/1.1\r\nHost: a\r\nX-A: 1\r\n\r\nGET / HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\nX-Trailer: t\r\nTE: trailers\r\n\r\n3\r\nabc\r\n0\r\n\r\n",
        "PUT /a/b HTTP/1.1\r\nContent-Length: 4\r\nExpect: 100-continue\r\n\r\nbody",
        "GET / HTTP/1.0\r\n\r\n",
        h2_get,
        preface ++ "\x00\x00\x00\x04\x00\x00\x00\x00\x00" ++ "\x00\x00\x08\x07\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
        // HEADERS waiting for a CONTINUATION that never comes: the stream
        // never gets a handler, and must not hold the connection open.
        preface ++ "\x00\x00\x00\x04\x00\x00\x00\x00\x00" ++ "\x00\x00\x04\x01\x01\x00\x00\x00\x01" ++ "\x82\x86\x84\x41",
    });
}
