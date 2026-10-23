//! An HTTP/3 client connection on ngtcp2 and nghttp3: many concurrent
//! requests over one QUIC connection, with the HTTP/2 client's API
//! (`anole.h2.ClientConnection`). A reader task feeds ngtcp2 the datagrams
//! that arrive, a driver task writes packets and runs the timers, one mutex
//! serializes every ngtcp2 and nghttp3 call, and nothing blocks while
//! holding it. After ngtcp2's examples/client.cc and
//! http3_client_proto_codec.cc (MIT).
//!
//!     var conn = try anole.h3.ClientConnection.connect(gpa, io, .{
//!         .host = "localhost", .port = 8443, .tls = .{ .ca = .{ .pem = ca_pem } },
//!     });
//!     defer conn.close();
//!     const s = try conn.request(&.{
//!         .{ .name = ":method", .value = "GET" },   .{ .name = ":path", .value = "/" },
//!         .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
//!     }, .{});
//!     defer s.release();
//!     try s.waitHead();
//!     const body = try s.reader().allocRemaining(gpa, .unlimited);
//!
//! A stream's request body is written through `writer()` and ended with
//! `closeSend()`; its response body is read through `reader()`, and the
//! trailers are in `trailers` once that reports the end. Release every
//! stream before `close`.
//!
//! With a `SessionCache`, a connection resumes the session of an earlier
//! one to the same server, and with `early_data` it sends its first
//! requests in 0-RTT, before the handshake completes: `connect` returns at
//! once. A server that refuses the early data gets the same requests again
//! once the handshake is done.
const std = @import("std");
const dusty = @import("dusty");
const tls = @import("anole_dusty_tls");
const ngtcp2 = @import("ngtcp2.zig");
const nghttp3 = @import("nghttp3.zig");
const quic_tls = @import("quic_tls.zig");
const net = @import("net.zig");
const bridge = @import("bridge.zig");
const webtransport = @import("webtransport.zig");
pub const SessionCache = @import("session_cache.zig").SessionCache;

const c = ngtcp2.c;
const h = nghttp3.c;
const Addr = net.Addr;
const now = net.now;
const placement = dusty.placement;
const Deadline = dusty.Deadline;

const log = std.log.scoped(.anole_h3);

/// Packets written per driver round.
const burst = 10;
/// Largest UDP payload read.
const max_datagram = 65527;

/// A header field: request fields (pseudo-headers first, lower-case
/// names) and the response's `headers` and `trailers`.
pub const Header = struct { name: []const u8, value: []const u8 };

/// Where and how `ClientConnection.connect` connects. `host` and `port`
/// are required; the rest has defaults. Always TLS: QUIC has no
/// cleartext.
pub const ConnectOptions = struct {
    /// The server's name (SNI and the certificate check) or address.
    host: []const u8,
    port: u16,
    /// Send here instead of resolving `host`.
    address: ?std.Io.net.IpAddress = null,
    /// How the server's certificate is checked, and the client's own.
    /// Always TLS: QUIC has no cleartext form (HTTP/2's `tls` is optional).
    tls: Tls = .{},
    /// Bytes the server may send on a stream before its reader takes them,
    /// as in `anole.h2`. 256 KiB here (64 KiB over HTTP/2): an HTTP/3
    /// stream's receive buffer grows as data arrives rather than being
    /// allocated whole, and ngtcp2 widens the window (up to 6x) on a fast
    /// path.
    stream_window: u31 = 256 * 1024,
    /// The same for the whole connection.
    max_data: u31 = 16 * 1024 * 1024,
    /// HTTP/3 only: QUIC closes the connection after this long with
    /// nothing received (its idle timeout). HTTP/2 over TCP has none.
    idle_timeout: std.Io.Duration = .fromSeconds(30),
    /// For `connect`: resolving `host` and the QUIC handshake. Null for no
    /// limit. Past it, `connect` fails with `error.Timeout`.
    connect_timeout: ?std.Io.Duration = .fromSeconds(10),
    /// Each request's budget, from `request` to the end of the response
    /// body, unless its `RequestOptions.timeout` says otherwise. Null for
    /// no limit, which a long-lived stream wants.
    timeout: ?std.Io.Duration = .fromSeconds(30),
    /// The most a response's header fields may take, decoded (name, value
    /// and 32 bytes per field), informational responses and trailers
    /// included; advertised as SETTINGS_MAX_FIELD_SECTION_SIZE. Past it the
    /// stream fails with `error.HeadersTooLarge`.
    max_header_list_size: u32 = 64 * 1024,
    /// HTTP/3 only: where tickets are kept, to resume sessions (one round
    /// trip less, no certificate) and for `early_data`. Shared by any
    /// connections.
    session_cache: ?*SessionCache = null,
    /// HTTP/3 only: with a ticket for this server that allows it, send
    /// requests in 0-RTT, before the handshake completes. `connect` then returns at
    /// once, and `request` sends GET, HEAD and OPTIONS (or any request, with
    /// `RequestOptions.early`) right away; others wait for the handshake.
    /// Early data can be replayed by anyone who records it, so send in it
    /// only what is harmless to repeat.
    early_data: bool = false,
    /// HTTP/3 only: speak WebTransport (draft-02), for `openWebTransport`: its SETTINGS,
    /// HTTP datagrams, and streams the server may open.
    webtransport: bool = false,
    /// HTTP/3 only: start in QUIC v1 and offer v2 (RFC 9369) beside it,
    /// so a server that prefers v2 moves the connection there through
    /// compatible version negotiation (RFC 9368). `quicVersion` says which
    /// one it ended on.
    quic_v2: bool = false,

    /// The fields of `anole.h2.ConnectOptions.Tls`, with the same defaults.
    pub const Tls = struct {
        /// The certificate authorities the server's certificate must chain
        /// to, as for `anole.h2`: the system store by default, loaded on the
        /// first `connect` and kept for the process. `.none` only with
        /// `insecure_skip_verify`.
        ca: dusty.Ca = .system,
        /// Accept any certificate, for any name. For tests only.
        insecure_skip_verify: bool = false,
        /// A certificate to present when the server asks for one (mutual
        /// TLS): files or PEM in memory, read on every `connect`.
        client_certificate: ?dusty.Cert = null,
    };
};

/// Connection-level failures.
pub const Error = error{ ConnectionClosed, StreamReset, OutOfMemory, Unexpected };

/// `Tls.client_certificate` as PEM for `quic_tls`: read from its files, or
/// borrowed.
const Identity = struct {
    pem: quic_tls.Identity,
    /// Read from files, so freed by `deinit`.
    owned: bool,

    fn load(gpa: std.mem.Allocator, io: std.Io, cc: dusty.Cert) !Identity {
        switch (cc) {
            .pem => |p| return .{ .pem = .{ .cert_pem = p.cert, .key_pem = p.key }, .owned = false },
            .files => |f| {
                const dir = std.Io.Dir.cwd();
                const cert = try dir.readFileAlloc(io, f.cert_path, gpa, .limited(1 << 20));
                errdefer gpa.free(cert);
                const key = try dir.readFileAlloc(io, f.key_path, gpa, .limited(1 << 20));
                return .{ .pem = .{ .cert_pem = cert, .key_pem = key }, .owned = true };
            },
            .dev_self_signed => return error.DevCertificateUnavailable,
        }
    }

    fn deinit(self: *Identity, gpa: std.mem.Allocator) void {
        if (!self.owned) return;
        gpa.free(self.pem.cert_pem);
        const key = @constCast(self.pem.key_pem);
        std.crypto.secureZero(u8, key);
        gpa.free(key);
    }
};

/// Why a stream ended early: what `waitHead` returns, and what `readError`
/// and `writeError` say behind a `ReadFailed` or `WriteFailed`. The same as
/// `anole.h2.StreamError`.
pub const StreamError = error{
    /// The server reset the stream.
    StreamReset,
    /// The connection failed or was closed.
    ConnectionClosed,
    /// The request's `timeout` passed; the stream was reset.
    Timeout,
    /// The stream was canceled (`cancel`, or the task waiting on it).
    Canceled,
    /// The response's header fields passed `max_header_list_size`.
    HeadersTooLarge,
    /// More informational (1xx) responses than the client takes before a
    /// final one.
    TooManyInterimResponses,
};

/// How many informational (1xx) responses may come before the final one,
/// as in the HTTP/1.1 and HTTP/2 clients.
const max_interim_responses = 5;

fn timeoutFrom(duration: ?std.Io.Duration) std.Io.Timeout {
    const d = duration orelse return .none;
    return .{ .duration = .{ .raw = d, .clock = .awake } };
}

/// What became of 0-RTT on a connection.
pub const EarlyData = enum {
    /// Not tried: no ticket that allows it, or `early_data` is off.
    none,
    /// Sent; the handshake has not said yet.
    pending,
    accepted,
    /// The server refused it; what was sent early went again after the
    /// handshake.
    rejected,
};

/// How `ClientConnection.rebind` moves the connection.
pub const Rebind = enum {
    /// A migration (RFC 9000 §9): the client tells QUIC, which switches to
    /// a fresh connection ID and validates the new path. What a client
    /// does when its network changes.
    migrate,
    /// The new port without telling QUIC, as a NAT rebinding looks to both
    /// ends: the server notices the new address and validates it.
    nat,
};
/// An HTTP/3 client connection: `connect`, then `request` once per
/// request (concurrent ones share the connection, and several tasks may
/// make them at once), and `close`. See the file's example.
pub const ClientConnection = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    udp: net.Udp,
    /// The socket's address; every path uses it as is, so the connection
    /// never looks migrated.
    local: Addr,
    remote: Addr,
    q: *c.ngtcp2_conn = undefined,
    h3: ?*h.nghttp3_conn = null,
    ssl: *c.SSL = undefined,
    conn_ref: c.ngtcp2_crypto_conn_ref = undefined,
    tx: []u8,
    rx: []u8,

    /// Serializes every ngtcp2 and nghttp3 call and guards what follows.
    mutex: std.Io.Mutex = .init,
    /// Bumped on every change; the driver and waiting callers wait on it.
    gen: std.atomic.Value(u32) = .init(0),
    state: enum { handshaking, open, closed } = .handshaking,
    /// ngtcp2 ended the handshake for taking too long.
    handshake_timed_out: bool = false,
    /// The default for `RequestOptions.timeout`.
    timeout: std.Io.Timeout,
    /// The server sent GOAWAY, or `close` began: no new requests.
    closing: bool = false,
    last_error: c.ngtcp2_ccerr = undefined,
    /// The reader and the driver.
    group: std.Io.Group = .init,
    /// Streams the caller still holds or QUIC still knows.
    live: std.DoublyLinkedList = .{},
    /// The task reading the socket (apart from `group`, so a rebind can
    /// replace it).
    readers: std.Io.Group = .init,
    /// Tickets go here, filed under `cache_key`.
    cache: ?*SessionCache = null,
    cache_key: []u8 = &.{},
    early: EarlyData = .none,
    /// A socket for the driver to move to (`rebind`), and how.
    rebind_to: ?struct { socket: std.Io.net.Socket, how: Rebind } = null,
    rebind_error: ?anyerror = null,
    /// WebTransport's streams, sessions and datagrams
    /// (`ConnectOptions.webtransport`).
    wt: ?*webtransport.Core = null,
    /// The server's SETTINGS, once they arrived.
    peer_settings: ?PeerSettings = null,
    /// `ConnectOptions.max_header_list_size`.
    max_header_list_size: u32 = 64 * 1024,

    /// What the server's SETTINGS allow (`waitSettings`).
    pub const PeerSettings = struct {
        /// Extended CONNECT (RFC 9220): WebSocket, WebTransport.
        connect_protocol: bool,
        /// HTTP datagrams (RFC 9297).
        h3_datagram: bool,
    };

    /// Resolves `host` (unless `address` is set), handshakes with ALPN
    /// "h3", and returns once the connection is ready for requests.
    pub fn connect(gpa: std.mem.Allocator, io: std.Io, options: ConnectOptions) !*ClientConnection {
        const deadline: Deadline = .init(io, timeoutFrom(options.connect_timeout));
        const remote_ip = options.address orelse try deadline.run(resolve, .{ io, options.host, options.port });
        // Before anything that needs undoing: the first `.system` loads the
        // platform's store.
        const store = if (options.tls.insecure_skip_verify)
            null
        else
            try tls.clientStore(gpa, io, options.tls.ca) orelse return error.NoCertificateAuthority;
        defer if (store) |st| tls.releaseStore(st);
        var identity: ?Identity = if (options.tls.client_certificate) |cc| try .load(gpa, io, cc) else null;
        defer if (identity) |*id| id.deinit(gpa);
        const any: std.Io.net.IpAddress = switch (remote_ip) {
            .ip4 => .{ .ip4 = .unspecified(0) },
            .ip6 => .{ .ip6 = .unspecified(0) },
        };
        const socket = try any.bind(io, .{ .mode = .dgram, .protocol = .udp });
        errdefer socket.close(io);
        const tx = try gpa.alloc(u8, burst * c.NGTCP2_MAX_UDP_PAYLOAD_SIZE);
        errdefer gpa.free(tx);
        const rx = try gpa.alloc(u8, max_datagram);
        errdefer gpa.free(rx);
        const self = try gpa.create(ClientConnection);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .udp = .init(socket),
            .local = .from(socket.address),
            .remote = .from(remote_ip),
            .tx = tx,
            .rx = rx,
            .timeout = timeoutFrom(options.timeout),
            .max_header_list_size = options.max_header_list_size,
        };
        self.conn_ref = .{ .get_conn = getConn, .user_data = self };
        c.ngtcp2_ccerr_default(&self.last_error);
        net.rand_io = io;
        if (options.session_cache) |cache| {
            self.cache = cache;
            self.cache_key = try cacheKey(gpa, options, identity);
        }
        errdefer if (self.cache != null) gpa.free(self.cache_key);

        var scid: c.ngtcp2_cid = undefined;
        scid.datalen = 17;
        io.random(scid.data[0..scid.datalen]);
        var dcid: c.ngtcp2_cid = undefined;
        dcid.datalen = 18;
        io.random(dcid.data[0..dcid.datalen]);

        var settings: ngtcp2.Settings = undefined;
        ngtcp2.settingsDefault(&settings);
        settings.initial_ts = now(io);
        settings.rand_ctx = .{ .native_handle = self };
        settings.max_window = 6 * @as(u64, options.max_data);
        settings.max_stream_window = 6 * @as(u64, options.stream_window);
        settings.handshake_timeout = if (options.connect_timeout) |t| @intCast(@max(1, t.nanoseconds)) else std.math.maxInt(u64);
        // qlog stays off: both of ngtcp2's high-severity advisories were in
        // its qlog code.
        settings.qlog_write = null;
        var initial_pkt_num: [4]u8 = undefined;
        io.random(&initial_pkt_num);
        settings.initial_pkt_num = std.mem.readInt(u32, &initial_pkt_num, .little) & 0x7fffffff;
        const v1_and_v2 = [_]u32{ c.NGTCP2_PROTO_VER_V1, c.NGTCP2_PROTO_VER_V2 };
        if (options.quic_v2) {
            settings.available_versions = &v1_and_v2;
            settings.available_versionslen = v1_and_v2.len;
        }

        var params: ngtcp2.TransportParams = undefined;
        ngtcp2.transportParamsDefault(&params);
        params.initial_max_stream_data_bidi_local = options.stream_window;
        params.initial_max_stream_data_bidi_remote = options.stream_window;
        params.initial_max_stream_data_uni = options.stream_window;
        params.initial_max_data = options.max_data;
        // HTTP/3 servers open no request streams, but a WebTransport
        // session's may.
        params.initial_max_streams_bidi = if (options.webtransport) 100 else 0;
        params.initial_max_streams_uni = if (options.webtransport) 103 else 3;
        if (options.webtransport) params.max_datagram_frame_size = 65535;
        params.max_idle_timeout = std.math.lossyCast(u64, options.idle_timeout.toNanoseconds());
        params.active_connection_id_limit = 7;
        params.grease_quic_bit = 1;

        var p = self.path();
        var q: ?*c.ngtcp2_conn = null;
        if (ngtcp2.connClientNew(&q, &dcid, &scid, &p, c.NGTCP2_PROTO_VER_V1, &callbacks, &settings, &params, null, self) != 0)
            return error.QuicSetupFailed;
        self.q = q.?;
        errdefer c.ngtcp2_conn_del(self.q);
        if (options.webtransport) self.wt = try webtransport.Core.create(gpa, io, self.q, self.wtHost(), false, .{});
        errdefer if (self.wt) |w| w.destroy();
        // A ticket is used once, whatever happens to this connection.
        var ticket: ?SessionCache.Entry = if (self.cache) |cache| cache.take(self.cache_key) else null;
        defer if (ticket) |*t| t.deinit(gpa);
        self.ssl = try quic_tls.clientSession(&self.conn_ref, .{
            .host = options.host,
            .store = if (store) |st| @ptrCast(st) else null,
            .insecure_skip_verify = options.tls.insecure_skip_verify,
            .certificate = if (identity) |id| id.pem else null,
            .session = if (ticket) |t| t.session else null,
            .early_data = options.early_data,
            .on_new_session = if (self.cache != null) onNewSession else null,
        });
        errdefer c.SSL_free(self.ssl);
        c.ngtcp2_conn_set_tls_native_handle(self.q, self.ssl);
        errdefer if (self.h3) |hc| h.nghttp3_conn_del(hc);
        // 0-RTT: under the limits the server had, as the ticket recorded
        // them, with HTTP/3 set up now so requests can go at once.
        if (ticket) |t| if (options.early_data and c.SSL_SESSION_early_data_capable(t.session) != 0) {
            const ready = c.ngtcp2_conn_decode_and_set_0rtt_transport_params(self.q, t.params.ptr, t.params.len) == 0 and
                if (self.setupHttp3()) |_| true else |_| false;
            if (ready) self.early = .pending else c.SSL_set_early_data_enabled(self.ssl, 0);
        };

        errdefer self.group.cancel(io);
        errdefer self.readers.cancel(io);
        try placement.concurrent(&self.readers, io, .local, readerLoop, .{ self, self.udp });
        try placement.concurrent(&self.group, io, .local, drive, .{self});
        if (self.early == .pending) return self;
        try self.waitHandshake();
        if (!std.mem.eql(u8, quic_tls.negotiated(self.ssl), "h3")) return error.NoH3;
        return self;
    }

    /// Where this connection's tickets are filed: the server, and every
    /// TLS setting that decides whether a session may be trusted.
    /// One field of `cacheKey`'s digest, length first, so fields cannot
    /// run into each other.
    fn hashField(hash: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
        var len: [8]u8 = undefined;
        std.mem.writeInt(u64, &len, bytes.len, .little);
        hash.update(&len);
        hash.update(bytes);
    }

    /// The TLS settings by SHA-256: a ticket must never go to a connection
    /// that trusts other CAs or presents another identity.
    fn cacheKey(gpa: std.mem.Allocator, options: ConnectOptions, identity: ?Identity) ![]u8 {
        var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
        const ca = options.tls.ca;
        hashField(&hash, @tagName(ca));
        switch (ca) {
            .file, .dir => |ca_path| hashField(&hash, ca_path),
            .pem => |text| hashField(&hash, text),
            .system, .none => {},
        }
        hashField(&hash, &.{@intFromBool(options.tls.insecure_skip_verify)});
        if (identity) |id| hashField(&hash, id.pem.cert_pem);
        return std.fmt.allocPrint(gpa, "{s}|{d}|{x}", .{ options.host, options.port, &hash.finalResult() });
    }

    /// What became of 0-RTT on this connection.
    pub fn earlyData(self: *ClientConnection) EarlyData {
        self.lock();
        defer self.unlock();
        return self.early;
    }

    /// The QUIC version the connection runs on (1, or 0x6b3343cf for v2):
    /// v1 unless `ConnectOptions.quic_v2` offered v2 and the server took
    /// it. Final once the handshake has completed.
    pub fn quicVersion(self: *ClientConnection) u32 {
        self.lock();
        defer self.unlock();
        return c.ngtcp2_conn_get_negotiated_version(self.q);
    }

    /// The handshake resumed an earlier session (from `session_cache`).
    pub fn resumed(self: *ClientConnection) bool {
        self.lock();
        defer self.unlock();
        return c.SSL_session_reused(self.ssl) != 0;
    }

    /// Waits until the handshake has completed (after an early `connect`).
    pub fn waitConnected(self: *ClientConnection) !void {
        return self.waitHandshake();
    }

    /// Moves the connection to a new UDP socket, on a new local port, and
    /// carries on: requests in flight continue on the new path. See
    /// `Rebind` for the two ways. A migration needs the handshake done and
    /// a spare connection ID from the server.
    pub fn rebind(self: *ClientConnection, how: Rebind) !void {
        const any: std.Io.net.IpAddress = switch (self.remote.ip()) {
            .ip4 => .{ .ip4 = .unspecified(0) },
            .ip6 => .{ .ip6 = .unspecified(0) },
        };
        const socket = try any.bind(self.io, .{ .mode = .dgram, .protocol = .udp });
        self.lock();
        if (self.state == .closed or self.rebind_to != null) {
            self.unlock();
            socket.close(self.io);
            return error.ConnectionClosed;
        }
        self.rebind_to = .{ .socket = socket, .how = how };
        self.rebind_error = null;
        self.unlock();
        self.kick();
        // The driver moves it, as the only task that sends.
        while (true) {
            const gen = self.gen.load(.acquire);
            self.lock();
            const pending = self.rebind_to != null;
            const err = self.rebind_error;
            const closed = self.state == .closed;
            self.unlock();
            if (!pending) return if (err) |e| e else {};
            if (closed) return error.ConnectionClosed;
            try self.wait(gen);
        }
    }

    /// The driver's half of `rebind`: QUIC told (for a migration), the
    /// socket swapped, a reader on the new one, the old one closed.
    fn switchSocket(self: *ClientConnection) void {
        const io = self.io;
        self.lock();
        const next = self.rebind_to orelse {
            self.unlock();
            return;
        };
        if (next.how == .migrate) {
            var local: Addr = .from(next.socket.address);
            var p: c.ngtcp2_path = .{ .local = local.ngtcp2Addr(), .remote = self.remote.ngtcp2Addr(), .user_data = null };
            const rv = c.ngtcp2_conn_initiate_immediate_migration(self.q, &p, now(io));
            if (rv != 0) {
                log.debug("HTTP/3 client migration: {s}", .{c.ngtcp2_strerror(rv)});
                self.rebind_to = null;
                self.rebind_error = error.MigrationRefused;
                self.unlock();
                next.socket.close(io);
                self.kick();
                return;
            }
            self.local = local;
        }
        const old = self.udp.socket;
        self.udp = .init(next.socket);
        const udp = self.udp;
        self.unlock();
        // What arrives on the old socket from here on is lost, as it would
        // be on a network the client left.
        self.readers.cancel(io);
        old.close(io);
        placement.concurrent(&self.readers, io, .local, readerLoop, .{ self, udp }) catch {
            self.lock();
            self.rebind_error = error.ConcurrencyUnavailable;
            self.closeLocked();
            self.unlock();
        };
        self.lock();
        self.rebind_to = null;
        self.unlock();
        self.kick();
    }

    fn resolve(io: std.Io, host: []const u8, port: u16) !std.Io.net.IpAddress {
        if (std.Io.net.IpAddress.parse(host, port)) |a| return a else |_| {}
        var buf: [16]std.Io.net.HostName.LookupResult = undefined;
        var results: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&buf);
        try (try std.Io.net.HostName.init(host)).lookup(io, &results, .{ .port = port });
        while (results.getOne(io)) |r| switch (r) {
            .address => |a| return a,
            .canonical_name => {},
        } else |err| switch (err) {
            error.Canceled => |e| return e,
            error.Closed => return error.UnknownHostName,
        }
    }

    fn waitHandshake(self: *ClientConnection) !void {
        while (true) {
            const gen = self.gen.load(.acquire);
            self.lock();
            const state = self.state;
            self.unlock();
            switch (state) {
                .open => return,
                .closed => {
                    if (self.handshake_timed_out) return error.Timeout;
                    log.debug("HTTP/3 handshake failed: {s}", .{c.ngtcp2_strerror(@intCast(self.last_error.error_code))});
                    return error.HandshakeFailed;
                },
                // ngtcp2's handshake timeout ends this.
                .handshaking => try self.io.futexWait(u32, &self.gen.raw, gen),
            }
        }
    }

    /// Sends CONNECTION_CLOSE (H3_NO_ERROR), stops the reader and the
    /// driver, and frees everything. Release every stream first. A stream
    /// let go while its end was still on its way (a WebTransport session's
    /// close capsule and FIN) gets a moment to reach the server first:
    /// `close` waits until QUIC closes it, for about three PTOs at most (at
    /// least 100 ms, at most a second).
    pub fn close(self: *ClientConnection) void {
        const io = self.io;
        self.settle();
        self.lock();
        self.closing = true;
        if (self.state != .closed) {
            c.ngtcp2_ccerr_set_application_error(&self.last_error, h.NGHTTP3_H3_NO_ERROR, null, 0);
            self.fail();
        }
        self.unlock();
        // The driver first: it may be starting a reader (`rebind`).
        self.group.cancel(io);
        self.readers.cancel(io);
        if (self.rebind_to) |r| r.socket.close(io);
        if (self.cache != null) self.gpa.free(self.cache_key);
        if (self.h3) |hc| h.nghttp3_conn_del(hc);
        if (self.wt) |w| w.destroy();
        // Streams released but not yet closed by QUIC.
        while (self.live.popFirst()) |node| {
            const stream: *Stream = @alignCast(@fieldParentPtr("node", node));
            stream.free();
        }
        c.ngtcp2_conn_del(self.q);
        c.SSL_free(self.ssl);
        self.udp.socket.close(io);
        self.gpa.free(self.tx);
        self.gpa.free(self.rx);
        self.gpa.destroy(self);
    }

    /// Before a close: waits while a stream let go with `releaseSent`
    /// is still open in QUIC, that is until the server has everything it
    /// was sent, the end included, and ended its own side (as a
    /// WebTransport peer does on a close), or the time runs out. Without it
    /// the CONNECTION_CLOSE could overtake data still waiting to go out
    /// (paced, or lost and not yet resent), which the server would then
    /// never see.
    fn settle(self: *ClientConnection) void {
        const io = self.io;
        self.lock();
        const pto: u64 = if (self.state == .open) c.ngtcp2_conn_get_pto2(self.q) else 0;
        self.unlock();
        const deadline = now(io) + @min(@max(3 * pto, 100 * std.time.ns_per_ms), std.time.ns_per_s);
        while (true) {
            const gen = self.gen.load(.acquire);
            self.lock();
            const waiting = self.state == .open and self.lingering();
            self.unlock();
            if (!waiting) return;
            const t = now(io);
            if (t >= deadline) return;
            io.futexWaitTimeout(u32, &self.gen.raw, gen, .{ .duration = .{
                .raw = .fromNanoseconds(@intCast(deadline - t)),
                .clock = .awake,
            } }) catch return;
        }
    }

    /// A stream let go with `releaseSent` is still open in QUIC. Locked.
    fn lingering(self: *ClientConnection) bool {
        var it = self.live.first;
        while (it) |node| : (it = node.next) {
            const stream: *Stream = @alignCast(@fieldParentPtr("node", node));
            if (stream.lingering and !stream.protocol_done) return true;
        }
        return false;
    }

    fn getConn(conn_ref: [*c]c.ngtcp2_crypto_conn_ref) callconv(.c) ?*c.ngtcp2_conn {
        const self: *ClientConnection = @ptrCast(@alignCast(conn_ref.*.user_data));
        return self.q;
    }

    fn lock(self: *ClientConnection) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *ClientConnection) void {
        self.mutex.unlock(self.io);
    }

    fn kick(self: *ClientConnection) void {
        _ = self.gen.fetchAdd(1, .release);
        self.io.futexWake(u32, &self.gen.raw, std.math.maxInt(u32));
    }

    /// How WebTransport's sessions and streams reach the connection.
    fn wtHost(self: *ClientConnection) webtransport.Host {
        const S = struct {
            fn of(ctx: *anyopaque) *ClientConnection {
                return @ptrCast(@alignCast(ctx));
            }
            fn lock(ctx: *anyopaque) void {
                of(ctx).lock();
            }
            fn unlock(ctx: *anyopaque) void {
                of(ctx).unlock();
            }
            fn kick(ctx: *anyopaque) void {
                of(ctx).kick();
            }
        };
        return .{ .ctx = self, .gen = &self.gen, .lock_fn = S.lock, .unlock_fn = S.unlock, .kick_fn = S.kick };
    }

    fn wait(self: *ClientConnection, gen: u32) std.Io.Cancelable!void {
        try self.io.futexWait(u32, &self.gen.raw, gen);
    }

    fn path(self: *ClientConnection) c.ngtcp2_path {
        return .{ .local = self.local.ngtcp2Addr(), .remote = self.remote.ngtcp2Addr(), .user_data = null };
    }

    fn side(self: *ClientConnection) bridge.Side {
        return .{ .q = self.q, .h3 = self.h3, .last_error = &self.last_error, .wt = self.wt };
    }

    /// Waits for the server's SETTINGS (which follow the handshake).
    pub fn waitSettings(self: *ClientConnection) !PeerSettings {
        while (true) {
            const gen = self.gen.load(.acquire);
            self.lock();
            const settings = self.peer_settings;
            const closed = self.state == .closed;
            self.unlock();
            if (settings) |got| return got;
            if (closed) return error.ConnectionClosed;
            try self.wait(gen);
        }
    }

    /// The CONNECT request `openWebTransport` sends.
    pub const WebTransportOptions = struct {
        /// `:authority`, the server's name (and port, if not 443).
        authority: []const u8,
        /// `:path`, the WebTransport endpoint's route.
        path: []const u8 = "/",
        /// The `Origin` a browser would send, if any.
        origin: ?[]const u8 = null,
        /// More request fields, names in lower case.
        headers: []const Header = &.{},
    };

    /// Opens a WebTransport session (draft-02): an extended CONNECT that
    /// the server answers with 200. Needs `ConnectOptions.webtransport`.
    /// Close it with `Session.close`, and `deinit` it before `close`.
    pub fn openWebTransport(self: *ClientConnection, options: WebTransportOptions) !*webtransport.Session {
        const core = self.wt orelse return error.WebTransportNotEnabled;
        const settings = try self.waitSettings();
        if (!settings.connect_protocol) return error.ExtendedConnectRefused;
        var fields: std.ArrayList(Header) = .empty;
        defer fields.deinit(self.gpa);
        try fields.appendSlice(self.gpa, &.{
            .{ .name = ":method", .value = "CONNECT" },
            .{ .name = ":protocol", .value = "webtransport" },
            .{ .name = ":scheme", .value = "https" },
            .{ .name = ":authority", .value = options.authority },
            .{ .name = ":path", .value = options.path },
            // What Chrome sends for draft-02.
            .{ .name = "sec-webtransport-http3-draft02", .value = "1" },
        });
        if (options.origin) |o| try fields.append(self.gpa, .{ .name = "origin", .value = o });
        try fields.appendSlice(self.gpa, options.headers);
        const stream = try self.request(fields.items, .{ .body = true, .timeout = .none });
        errdefer stream.release();
        try stream.waitHead();
        if (stream.status != 200) return error.WebTransportRefused;
        const holder = try self.gpa.create(ClientSession);
        errdefer self.gpa.destroy(holder);
        holder.* = .{ .session = undefined, .stream = stream, .gpa = self.gpa };
        try webtransport.Session.Driver.start(&holder.session, core, stream.id, .{
            .reader = stream.reader(),
            .writer = stream.writer(),
            .ctx = holder,
            .end_fn = ClientSession.end,
            .release_fn = ClientSession.release,
        }, .{});
        return &holder.session;
    }

    /// A client's session and the CONNECT stream it runs on.
    const ClientSession = struct {
        session: webtransport.Session,
        stream: *Stream,
        gpa: std.mem.Allocator,

        fn end(ctx: *anyopaque) void {
            const self: *ClientSession = @ptrCast(@alignCast(ctx));
            self.stream.closeSend() catch {};
        }

        fn release(ctx: *anyopaque) void {
            const self: *ClientSession = @ptrCast(@alignCast(ctx));
            // The session ended its side with a capsule (a close) and FIN:
            // they must still go out. `release` would reset the stream,
            // and the close with it, while the server's side is open.
            self.stream.releaseSent();
            self.gpa.destroy(self);
        }
    };

    /// Per request: a body, the timeout, and 0-RTT.
    pub const RequestOptions = struct {
        /// The request has a body, written through `Stream.writer` and
        /// ended with `Stream.closeSend`.
        body: bool = false,
        /// Replaces `ConnectOptions.timeout` for this request, as in
        /// `anole.h2`: null inherits it, `.none` lifts it, and past it the
        /// stream is reset and its waits fail with `error.Timeout`.
        timeout: ?std.Io.Timeout = null,
        /// HTTP/3 only. While a 0-RTT handshake is going (`ConnectOptions.early_data`):
        /// true sends this request in early data, false waits for the
        /// handshake, null decides by method (GET, HEAD and OPTIONS go).
        /// Only what is harmless to repeat belongs in early data.
        early: ?bool = null,
    };

    /// Opens a request stream, waiting while the server's stream limit is
    /// reached. `headers` holds the pseudo-headers first, names in lower
    /// case; they are copied.
    pub fn request(self: *ClientConnection, headers: []const Header, options: RequestOptions) !*Stream {
        const stream = try Stream.create(self, options.body, .init(self.io, options.timeout orelse self.timeout));
        errdefer stream.destroy();
        const nva = try self.gpa.alloc(h.nghttp3_nv, headers.len);
        defer self.gpa.free(nva);
        for (headers, nva) |f, *nv| nv.* = .{
            .name = f.name.ptr,
            .namelen = f.name.len,
            .value = f.value.ptr,
            .valuelen = f.value.len,
            .flags = h.NGHTTP3_NV_FLAG_NONE,
        };
        while (true) {
            const gen = self.gen.load(.acquire);
            self.lock();
            if (self.closing or self.state == .closed) {
                self.unlock();
                return error.ConnectionClosed;
            }
            const early = self.state == .handshaking;
            if (early and !(self.early == .pending and (options.early orelse safeMethod(headers)))) {
                self.unlock();
                try stream.deadline.run(wait, .{ self, gen });
                continue;
            }
            // Kept, to send again should the server refuse the early data.
            if (early and stream.early_headers == null) stream.early_headers = stream.copyHeaders(headers) catch {
                self.unlock();
                return error.OutOfMemory;
            };
            const hc = self.h3 orelse {
                self.unlock();
                return error.ConnectionClosed;
            };
            var id: i64 = -1;
            const rv = c.ngtcp2_conn_open_bidi_stream(self.q, &id, stream);
            if (rv == c.NGTCP2_ERR_STREAM_ID_BLOCKED) {
                self.unlock();
                try stream.deadline.run(wait, .{ self, gen });
                continue;
            }
            if (rv != 0) {
                self.unlock();
                return error.Unexpected;
            }
            const reader: h.nghttp3_data_reader = .{ .read_data = readData };
            if (h.nghttp3_conn_submit_request(hc, id, nva.ptr, nva.len, if (options.body) &reader else null, stream) != 0) {
                _ = c.ngtcp2_conn_set_stream_user_data(self.q, id, null);
                _ = c.ngtcp2_conn_shutdown_stream(self.q, 0, id, h.NGHTTP3_H3_INTERNAL_ERROR);
                self.unlock();
                return error.Unexpected;
            }
            stream.id = id;
            stream.submitted = true;
            if (!early) stream.early_headers = null;
            self.unlock();
            break;
        }
        self.kick();
        return stream;
    }

    fn safeMethod(headers: []const Header) bool {
        for (headers) |f| if (std.mem.eql(u8, f.name, ":method")) {
            for ([_][]const u8{ "GET", "HEAD", "OPTIONS" }) |m| if (std.mem.eql(u8, f.value, m)) return true;
            return false;
        };
        return false;
    }

    /// Sends the requests that went in refused early data again, on new
    /// streams (QUIC forgot the old ones). Locked, once the handshake is
    /// done.
    fn resendEarly(self: *ClientConnection) void {
        const hc = self.h3 orelse return;
        var it = self.live.first;
        while (it) |node| {
            it = node.next;
            const s: *Stream = @alignCast(@fieldParentPtr("node", node));
            const headers = s.early_headers orelse continue;
            s.early_headers = null;
            // Released or canceled meanwhile: nothing to send again.
            if (s.user_done or s.cause != null) {
                s.endEarly(error.Canceled);
                s.protocol_done = true;
                s.maybeFree();
                continue;
            }
            var id: i64 = -1;
            const reader: h.nghttp3_data_reader = .{ .read_data = readData };
            if (c.ngtcp2_conn_open_bidi_stream(self.q, &id, s) != 0 or
                h.nghttp3_conn_submit_request(hc, id, headers.ptr, headers.len, if (s.has_body) &reader else null, s) != 0)
            {
                if (id >= 0) _ = c.ngtcp2_conn_shutdown_stream(self.q, 0, id, h.NGHTTP3_H3_INTERNAL_ERROR);
                s.endEarly(error.StreamReset);
                s.protocol_done = id < 0;
                continue;
            }
            s.id = id;
            // The body from its start: none of it was acknowledged.
            s.out.sent = s.out.acked;
            s.deferred = false;
        }
        self.kick();
    }

    // -- In: the reader task -------------------------------------------------

    fn readerLoop(self: *ClientConnection, udp: net.Udp) std.Io.Cancelable!void {
        var control: net.Udp.Control align(std.Io.net.cmsg_align) = undefined;
        while (true) {
            var dg = udp.receive(self.io, self.rx, &control, .none) catch |err| switch (err) {
                error.Canceled => |e| return e,
                else => {
                    log.debug("HTTP/3 client receive: {t}", .{err});
                    self.lock();
                    self.closeLocked();
                    self.unlock();
                    return;
                },
            };
            while (dg.next()) |data| self.onPacket(dg.from, dg.ecn, data);
        }
    }

    fn onPacket(self: *ClientConnection, from: std.Io.net.IpAddress, ecn: u8, data: []u8) void {
        self.lock();
        defer self.unlock();
        if (self.state == .closed) return;
        var remote: Addr = .from(from);
        var p: c.ngtcp2_path = .{ .local = self.local.ngtcp2Addr(), .remote = remote.ngtcp2Addr(), .user_data = null };
        const pi: c.ngtcp2_pkt_info = .{ .ecn = ecn };
        const rv = ngtcp2.connReadPkt(self.q, &p, &pi, data, now(self.io));
        if (rv != 0) {
            log.debug("HTTP/3 client read_pkt: {s}", .{c.ngtcp2_strerror(rv)});
            switch (rv) {
                // The server closed, or there is nothing left to say.
                c.NGTCP2_ERR_DRAINING, c.NGTCP2_ERR_DROP_CONN => self.closeLocked(),
                c.NGTCP2_ERR_CRYPTO => {
                    if (self.last_error.error_code == 0)
                        c.ngtcp2_ccerr_set_tls_alert(&self.last_error, c.ngtcp2_conn_get_tls_alert2(self.q), null, 0);
                    self.fail();
                },
                else => {
                    if (self.last_error.error_code == 0)
                        c.ngtcp2_ccerr_set_liberr(&self.last_error, rv, null, 0);
                    self.fail();
                },
            }
        }
        self.kick();
    }

    // -- Out: the driver task ------------------------------------------------

    fn drive(self: *ClientConnection) std.Io.Cancelable!void {
        const io = self.io;
        while (true) {
            const gen = self.gen.load(.acquire);
            self.switchSocket();
            self.flush();
            self.lock();
            if (self.state == .closed) {
                self.unlock();
                return;
            }
            const t = now(io);
            const deadline = c.ngtcp2_conn_get_expiry2(self.q);
            if (deadline <= t) {
                const rv = c.ngtcp2_conn_handle_expiry(self.q, t);
                if (rv != 0) {
                    if (rv == c.NGTCP2_ERR_HANDSHAKE_TIMEOUT) self.handshake_timed_out = true;
                    c.ngtcp2_ccerr_set_liberr(&self.last_error, rv, null, 0);
                    self.fail();
                }
                self.unlock();
                continue;
            }
            self.unlock();
            const timeout: std.Io.Timeout = if (deadline == std.math.maxInt(u64)) .none else .{ .duration = .{
                .raw = .fromNanoseconds(@intCast(deadline - t)),
                .clock = .awake,
            } };
            try io.futexWaitTimeout(u32, &self.gen.raw, gen, timeout);
        }
    }

    /// Writes and sends whatever the connection has to send.
    fn flush(self: *ClientConnection) void {
        while (true) {
            self.lock();
            if (self.state == .closed) {
                self.unlock();
                return;
            }
            var ps: c.ngtcp2_path_storage = undefined;
            c.ngtcp2_path_storage_zero(&ps);
            var pi: c.ngtcp2_pkt_info = undefined;
            var gso: usize = 0;
            const ts = now(self.io);
            const quantum = c.ngtcp2_conn_get_send_quantum(self.q);
            const len = @min(self.tx.len, @max(quantum, c.NGTCP2_MAX_UDP_PAYLOAD_SIZE));
            const n = ngtcp2.connWriteAggregatePkt2(self.q, &ps.path, &pi, self.tx[0..len], &gso, writePkt, burst, ts);
            if (n < 0) {
                if (self.last_error.error_code == 0)
                    c.ngtcp2_ccerr_set_liberr(&self.last_error, @intCast(n), null, 0);
                self.fail();
                self.unlock();
                return;
            }
            c.ngtcp2_conn_update_pkt_tx_time(self.q, ts);
            self.unlock();
            if (n == 0) return;
            // Only this task uses `tx`.
            self.udp.send(self.io, self.remote.ip(), null, pi.ecn, self.tx[0..@intCast(n)], gso);
        }
    }

    /// The connection failed or ends: one CONNECTION_CLOSE (a client keeps
    /// no closing period), or nothing for an idle timeout. Locked.
    fn fail(self: *ClientConnection) void {
        if (self.state == .closed) return;
        defer self.closeLocked();
        if (self.last_error.type == c.NGTCP2_CCERR_TYPE_IDLE_CLOSE) return;
        if (c.ngtcp2_conn_in_draining_period2(self.q) != 0) return;
        var ps: c.ngtcp2_path_storage = undefined;
        c.ngtcp2_path_storage_zero(&ps);
        var pi: c.ngtcp2_pkt_info = undefined;
        var buf: [c.NGTCP2_MAX_UDP_PAYLOAD_SIZE]u8 = undefined;
        const n = ngtcp2.connWriteConnectionClose(self.q, &ps.path, &pi, &buf, &self.last_error, now(self.io));
        if (n > 0) {
            self.udp.send(self.io, self.remote.ip(), null, 0, buf[0..@intCast(n)], @intCast(n));
        }
    }

    /// Every stream sees the connection gone. Locked.
    fn closeLocked(self: *ClientConnection) void {
        self.state = .closed;
        self.closing = true;
        if (self.wt) |w| w.connectionClosed();
        var it = self.live.first;
        while (it) |node| : (it = node.next) {
            const stream: *Stream = @alignCast(@fieldParentPtr("node", node));
            stream.endEarly(error.ConnectionClosed);
        }
        self.kick();
    }

    /// Once 1-RTT keys are in: the control and QPACK streams. Locked
    /// (inside an ngtcp2 callback).
    fn setupHttp3(self: *ClientConnection) !void {
        if (self.h3 != null) return;
        if (c.ngtcp2_conn_get_streams_uni_left2(self.q) < 3) return error.Http3SetupFailed;
        var settings: nghttp3.Settings = undefined;
        nghttp3.settingsDefault(&settings);
        settings.qpack_max_dtable_capacity = 4096;
        settings.qpack_blocked_streams = 100;
        settings.h3_datagram = @intFromBool(self.wt != null);
        settings.max_field_section_size = self.max_header_list_size;
        var hc: ?*h.nghttp3_conn = null;
        if (nghttp3.connClientNew(&hc, &h3_callbacks, &settings, h.nghttp3_mem_default(), self) != 0) return error.Http3SetupFailed;
        errdefer h.nghttp3_conn_del(hc);
        // As Chrome does: SETTINGS_ENABLE_WEBTRANSPORT from the client too.
        if (self.wt != null and h.nghttp3_conn_add_extra_setting(hc, webtransport.setting_enable_webtransport, 1) != 0)
            return error.Http3SetupFailed;
        var ctrl: i64 = 0;
        var enc: i64 = 0;
        var dec: i64 = 0;
        if (c.ngtcp2_conn_open_uni_stream(self.q, &ctrl, null) != 0) return error.Http3SetupFailed;
        if (h.nghttp3_conn_bind_control_stream(hc, ctrl) != 0) return error.Http3SetupFailed;
        if (c.ngtcp2_conn_open_uni_stream(self.q, &enc, null) != 0) return error.Http3SetupFailed;
        if (c.ngtcp2_conn_open_uni_stream(self.q, &dec, null) != 0) return error.Http3SetupFailed;
        if (h.nghttp3_conn_bind_qpack_streams(hc, enc, dec) != 0) return error.Http3SetupFailed;
        self.h3 = hc;
    }

    // -- ngtcp2 callbacks: each runs inside an ngtcp2_conn_* call, with the
    // -- connection's mutex held by the caller.

    const callbacks: c.ngtcp2_callbacks = blk: {
        var cb = std.mem.zeroes(c.ngtcp2_callbacks);
        cb.client_initial = c.ngtcp2_crypto_client_initial_cb;
        cb.recv_crypto_data = c.ngtcp2_crypto_recv_crypto_data_cb;
        cb.handshake_completed = onHandshakeCompleted;
        cb.encrypt = c.ngtcp2_crypto_encrypt_cb;
        cb.decrypt = c.ngtcp2_crypto_decrypt_cb;
        cb.hp_mask = c.ngtcp2_crypto_hp_mask_cb;
        cb.recv_stream_data = onRecvStreamData;
        cb.acked_stream_data_offset = onAckedStreamDataOffset;
        cb.recv_retry = c.ngtcp2_crypto_recv_retry_cb;
        cb.extend_max_local_streams_bidi = onExtendMaxLocalStreamsBidi;
        cb.rand = onRand;
        cb.update_key = c.ngtcp2_crypto_update_key_cb;
        cb.stream_reset = onStreamReset;
        cb.extend_max_stream_data = onExtendMaxStreamData;
        cb.delete_crypto_aead_ctx = c.ngtcp2_crypto_delete_crypto_aead_ctx_cb;
        cb.delete_crypto_cipher_ctx = c.ngtcp2_crypto_delete_crypto_cipher_ctx_cb;
        cb.stream_stop_sending = onStreamStopSending;
        cb.version_negotiation = c.ngtcp2_crypto_version_negotiation_cb;
        cb.recv_rx_key = onRecvRxKey;
        cb.get_new_connection_id2 = onGetNewConnectionId;
        cb.get_path_challenge_data2 = c.ngtcp2_crypto_get_path_challenge_data2_cb;
        cb.stream_close2 = onStreamClose;
        cb.tls_early_data_rejected = onEarlyDataRejected;
        cb.recv_datagram = onRecvDatagram;
        cb.extend_max_local_streams_uni = onExtendMaxLocalStreamsUni;
        break :blk cb;
    };

    fn connOf(user_data: ?*anyopaque) *ClientConnection {
        return @ptrCast(@alignCast(user_data.?));
    }

    fn streamOfUser(stream_user_data: ?*anyopaque) ?*Stream {
        return @ptrCast(@alignCast(stream_user_data orelse return null));
    }

    fn onHandshakeCompleted(_: ?*c.ngtcp2_conn, user_data: ?*anyopaque) callconv(.c) c_int {
        const self = connOf(user_data);
        if (self.state == .handshaking) self.state = .open;
        // BoringSSL says so as soon as the server's answer arrives (and
        // `onEarlyDataRejected` has run); this is for any other way.
        if (self.early == .pending and c.SSL_early_data_accepted(self.ssl) == 0) {
            if (c.ngtcp2_conn_tls_early_data_rejected(self.q) != 0) return c.NGTCP2_ERR_CALLBACK_FAILURE;
            self.early = .rejected;
        }
        switch (self.early) {
            .pending => self.early = .accepted,
            .rejected => {
                // HTTP/3 again (if the 1-RTT keys did not already), then
                // what was refused.
                self.setupHttp3() catch return c.NGTCP2_ERR_CALLBACK_FAILURE;
                self.resendEarly();
            },
            else => {},
        }
        self.kick();
        return 0;
    }

    /// The server refused the 0-RTT data: QUIC has dropped the streams sent
    /// in it, and HTTP/3 starts over once the handshake is done.
    fn onEarlyDataRejected(_: ?*c.ngtcp2_conn, user_data: ?*anyopaque) callconv(.c) c_int {
        const self = connOf(user_data);
        log.debug("HTTP/3 client: 0-RTT refused, requests go again after the handshake", .{});
        self.early = .rejected;
        if (self.h3) |hc| h.nghttp3_conn_del(hc);
        self.h3 = null;
        return 0;
    }

    /// A session ticket from the server: kept with the transport parameters
    /// that 0-RTT on it would need.
    fn onNewSession(ssl: ?*c.SSL, session: ?*c.SSL_SESSION) callconv(.c) c_int {
        const conn_ref: *c.ngtcp2_crypto_conn_ref = @ptrCast(@alignCast(c.SSL_get_ex_data(ssl, 0) orelse return 0));
        const self: *ClientConnection = @ptrCast(@alignCast(conn_ref.user_data));
        const cache = self.cache orelse return 0;
        var params: [256]u8 = undefined;
        const n = c.ngtcp2_conn_encode_0rtt_transport_params2(self.q, &params, params.len);
        if (n < 0) return 0;
        cache.put(self.cache_key, session.?, params[0..@intCast(n)]) catch return 0;
        return 1;
    }

    fn onRecvStreamData(_: ?*c.ngtcp2_conn, flags: u32, stream_id: i64, offset: u64, data: [*c]const u8, len: usize, user_data: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        return bridge.recvStreamData(connOf(user_data).side(), flags, stream_id, offset, if (len == 0) &.{} else data[0..len]);
    }

    fn onRecvDatagram(_: ?*c.ngtcp2_conn, _: u32, data: [*c]const u8, len: usize, user_data: ?*anyopaque) callconv(.c) c_int {
        const self = connOf(user_data);
        if (self.wt) |w| w.onDatagram(if (len == 0) &.{} else data[0..len]);
        return 0;
    }

    fn onExtendMaxLocalStreamsUni(_: ?*c.ngtcp2_conn, _: u64, user_data: ?*anyopaque) callconv(.c) c_int {
        // A WebTransport session waiting to open a stream may go on.
        connOf(user_data).kick();
        return 0;
    }

    fn onAckedStreamDataOffset(_: ?*c.ngtcp2_conn, stream_id: i64, _: u64, len: u64, user_data: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        const self = connOf(user_data);
        if (self.wt) |w| if (w.onAcked(stream_id, len)) return 0;
        const hc = self.h3 orelse return 0;
        if (h.nghttp3_conn_add_ack_offset(hc, stream_id, len) != 0) return c.NGTCP2_ERR_CALLBACK_FAILURE;
        return 0;
    }

    fn onExtendMaxLocalStreamsBidi(_: ?*c.ngtcp2_conn, _: u64, user_data: ?*anyopaque) callconv(.c) c_int {
        // A request waiting for a stream may go on.
        connOf(user_data).kick();
        return 0;
    }

    fn onRand(dest: [*c]u8, len: usize, rand_ctx: [*c]const c.ngtcp2_rand_ctx) callconv(.c) void {
        const self: *ClientConnection = @ptrCast(@alignCast(rand_ctx.*.native_handle));
        self.io.random(dest[0..len]);
    }

    fn onStreamReset(_: ?*c.ngtcp2_conn, stream_id: i64, _: u64, code: u64, user_data: ?*anyopaque, sud: ?*anyopaque) callconv(.c) c_int {
        const self = connOf(user_data);
        if (self.wt) |w| if (w.onReset(stream_id, code)) return 0;
        if (self.h3) |hc| if (h.nghttp3_conn_shutdown_stream_read(hc, stream_id) != 0) return c.NGTCP2_ERR_CALLBACK_FAILURE;
        if (streamOfUser(sud)) |s| s.endEarly(error.StreamReset);
        self.kick();
        return 0;
    }

    fn onStreamStopSending(_: ?*c.ngtcp2_conn, stream_id: i64, code: u64, user_data: ?*anyopaque, sud: ?*anyopaque) callconv(.c) c_int {
        const self = connOf(user_data);
        if (self.wt) |w| if (w.onStopSending(stream_id, code)) return 0;
        if (self.h3) |hc| if (h.nghttp3_conn_shutdown_stream_read(hc, stream_id) != 0) return c.NGTCP2_ERR_CALLBACK_FAILURE;
        // The server wants no more of the request body; its response may
        // still come.
        if (streamOfUser(sud)) |s| s.send_stopped = true;
        self.kick();
        return 0;
    }

    fn onExtendMaxStreamData(_: ?*c.ngtcp2_conn, stream_id: i64, _: u64, user_data: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        const self = connOf(user_data);
        if (self.wt) |w| if (w.onUnblocked(stream_id)) return 0;
        const hc = self.h3 orelse return 0;
        if (h.nghttp3_conn_unblock_stream(hc, stream_id) != 0) return c.NGTCP2_ERR_CALLBACK_FAILURE;
        return 0;
    }

    fn onRecvRxKey(_: ?*c.ngtcp2_conn, level: c.ngtcp2_encryption_level, user_data: ?*anyopaque) callconv(.c) c_int {
        if (level != c.NGTCP2_ENCRYPTION_LEVEL_1RTT) return 0;
        connOf(user_data).setupHttp3() catch return c.NGTCP2_ERR_CALLBACK_FAILURE;
        return 0;
    }

    fn onGetNewConnectionId(_: ?*c.ngtcp2_conn, cid: [*c]c.ngtcp2_cid, token: [*c]c.ngtcp2_stateless_reset_token, len: usize, user_data: ?*anyopaque) callconv(.c) c_int {
        const self = connOf(user_data);
        self.io.random(cid.*.data[0..len]);
        cid.*.datalen = len;
        self.io.random(&token.*.data);
        return 0;
    }

    fn onStreamClose(_: ?*c.ngtcp2_conn, flags: u32, stream_id: i64, rx_code: u64, tx_code: u64, user_data: ?*anyopaque, sud: ?*anyopaque) callconv(.c) c_int {
        const self = connOf(user_data);
        if (self.wt) |w| if (w.onClose(stream_id)) {
            self.kick();
            return 0;
        };
        const rv = bridge.closeStream(self.side(), flags, stream_id, rx_code, tx_code);
        if (rv != 0) return rv;
        if (streamOfUser(sud)) |s| {
            s.endEarly(error.StreamReset);
            s.protocol_done = true;
            s.maybeFree();
        }
        self.kick();
        return 0;
    }

    fn writePkt(_: ?*c.ngtcp2_conn, p: [*c]c.ngtcp2_path, pi: [*c]c.ngtcp2_pkt_info, dest: [*c]u8, len: usize, ts: c.ngtcp2_tstamp, user_data: ?*anyopaque) callconv(.c) c.ngtcp2_ssize {
        return bridge.writePacket(connOf(user_data).side(), p, pi, dest, len, ts);
    }

    // -- nghttp3 callbacks: inside nghttp3_conn_* calls, locked.

    const h3_callbacks: h.nghttp3_callbacks = blk: {
        var cb = std.mem.zeroes(h.nghttp3_callbacks);
        cb.acked_stream_data = onH3AckedStreamData;
        cb.recv_data = onH3RecvData;
        cb.deferred_consume = onH3DeferredConsume;
        cb.recv_header = onH3RecvHeader;
        cb.end_headers = onH3EndHeaders;
        cb.recv_trailer = onH3RecvTrailer;
        cb.stop_sending = onH3StopSending;
        cb.end_stream = onH3EndStream;
        cb.reset_stream = onH3ResetStream;
        cb.shutdown = onH3Shutdown;
        cb.recv_settings2 = onH3RecvSettings;
        cb.rand = net.h3Rand;
        break :blk cb;
    };

    fn onH3AckedStreamData(_: ?*h.nghttp3_conn, _: i64, len: u64, _: ?*anyopaque, sud: ?*anyopaque) callconv(.c) c_int {
        const s = streamOfUser(sud) orelse return 0;
        s.out.acked += len;
        // Room in the ring: a writer waiting may go on.
        s.conn.kick();
        return 0;
    }

    fn onH3RecvData(_: ?*h.nghttp3_conn, stream_id: i64, data: [*c]const u8, len: usize, user_data: ?*anyopaque, sud: ?*anyopaque) callconv(.c) c_int {
        const self = connOf(user_data);
        const s = streamOfUser(sud) orelse {
            bridge.consume(self.q, stream_id, len);
            return 0;
        };
        if (s.user_done) {
            // Let go (`releaseSent`): nobody reads it.
            bridge.consume(self.q, stream_id, len);
            return 0;
        }
        // The server cannot send past the stream's window, so this is
        // bounded by `stream_window`.
        s.body.appendSlice(self.gpa, data[0..len]) catch return h.NGHTTP3_ERR_CALLBACK_FAILURE;
        self.kick();
        return 0;
    }

    fn onH3DeferredConsume(_: ?*h.nghttp3_conn, stream_id: i64, n: usize, user_data: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        bridge.consume(connOf(user_data).q, stream_id, n);
        return 0;
    }

    /// Counts a field against `max_header_list_size`; false once the
    /// stream is past it (or ended), when the field is not kept.
    fn countField(s: *Stream, name: ?*h.nghttp3_rcbuf, value: ?*h.nghttp3_rcbuf) bool {
        if (s.cause != null) return false;
        s.header_list_size +|= h.nghttp3_rcbuf_get_buf(name).len + h.nghttp3_rcbuf_get_buf(value).len + 32;
        if (s.header_list_size <= s.conn.max_header_list_size) return true;
        // The rest of the block is dropped; `release` resets the stream.
        s.endEarly(error.HeadersTooLarge);
        return false;
    }

    fn onH3RecvHeader(_: ?*h.nghttp3_conn, _: i64, token: i32, name: ?*h.nghttp3_rcbuf, value: ?*h.nghttp3_rcbuf, _: u8, _: ?*anyopaque, sud: ?*anyopaque) callconv(.c) c_int {
        const s = streamOfUser(sud) orelse return 0;
        if (!countField(s, name, value)) return 0;
        const v = h.nghttp3_rcbuf_get_buf(value);
        if (token == h.NGHTTP3_QPACK_TOKEN__STATUS) {
            s.status = std.fmt.parseInt(u16, v.base[0..v.len], 10) catch 0;
            return 0;
        }
        const n = h.nghttp3_rcbuf_get_buf(name);
        if (n.len > 0 and n.base[0] == ':') return 0;
        s.addField(&s.headers, n.base[0..n.len], v.base[0..v.len]) catch return h.NGHTTP3_ERR_CALLBACK_FAILURE;
        return 0;
    }

    fn onH3EndHeaders(_: ?*h.nghttp3_conn, _: i64, fin: c_int, user_data: ?*anyopaque, sud: ?*anyopaque) callconv(.c) c_int {
        const self = connOf(user_data);
        const s = streamOfUser(sud) orelse return 0;
        if (s.cause != null) {
            // Failed (`countField`): no head.
        } else if (s.status >= 200) {
            s.head_ready = true;
        } else {
            // 1xx: its fields are not the response's.
            s.headers.clearRetainingCapacity();
            s.status = 0;
            s.interim += 1;
            if (s.interim > max_interim_responses) s.endEarly(error.TooManyInterimResponses);
        }
        if (fin != 0) s.body_done = true;
        self.kick();
        return 0;
    }

    fn onH3RecvTrailer(_: ?*h.nghttp3_conn, _: i64, _: i32, name: ?*h.nghttp3_rcbuf, value: ?*h.nghttp3_rcbuf, _: u8, _: ?*anyopaque, sud: ?*anyopaque) callconv(.c) c_int {
        const s = streamOfUser(sud) orelse return 0;
        if (!countField(s, name, value)) return 0;
        const n = h.nghttp3_rcbuf_get_buf(name);
        const v = h.nghttp3_rcbuf_get_buf(value);
        s.addField(&s.trailers, n.base[0..n.len], v.base[0..v.len]) catch return h.NGHTTP3_ERR_CALLBACK_FAILURE;
        return 0;
    }

    fn onH3EndStream(_: ?*h.nghttp3_conn, _: i64, user_data: ?*anyopaque, sud: ?*anyopaque) callconv(.c) c_int {
        const s = streamOfUser(sud) orelse return 0;
        s.body_done = true;
        connOf(user_data).kick();
        return 0;
    }

    fn onH3StopSending(_: ?*h.nghttp3_conn, stream_id: i64, code: u64, user_data: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        if (c.ngtcp2_conn_shutdown_stream_read(connOf(user_data).q, 0, stream_id, code) != 0) return h.NGHTTP3_ERR_CALLBACK_FAILURE;
        return 0;
    }

    fn onH3ResetStream(_: ?*h.nghttp3_conn, stream_id: i64, code: u64, user_data: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        if (c.ngtcp2_conn_shutdown_stream_write(connOf(user_data).q, 0, stream_id, code) != 0) return h.NGHTTP3_ERR_CALLBACK_FAILURE;
        return 0;
    }

    fn onH3RecvSettings(_: ?*h.nghttp3_conn, settings: [*c]const h.nghttp3_proto_settings, user_data: ?*anyopaque) callconv(.c) c_int {
        const self = connOf(user_data);
        self.peer_settings = .{
            .connect_protocol = settings.*.enable_connect_protocol != 0,
            .h3_datagram = settings.*.h3_datagram != 0,
        };
        self.kick();
        return 0;
    }

    /// GOAWAY: requests already sent below `id` still finish; no new ones.
    fn onH3Shutdown(_: ?*h.nghttp3_conn, _: i64, user_data: ?*anyopaque) callconv(.c) c_int {
        const self = connOf(user_data);
        self.closing = true;
        self.kick();
        return 0;
    }

    /// nghttp3 pulls request body bytes: what is in the ring and not yet
    /// handed over, then the end. Locked.
    fn readData(_: ?*h.nghttp3_conn, _: i64, vec: [*c]h.nghttp3_vec, veccnt: usize, pflags: [*c]u32, _: ?*anyopaque, sud: ?*anyopaque) callconv(.c) h.nghttp3_ssize {
        const s = streamOfUser(sud) orelse return h.NGHTTP3_ERR_CALLBACK_FAILURE;
        if (s.out.allSent()) {
            if (!s.send_closed) {
                s.deferred = true;
                return h.NGHTTP3_ERR_WOULDBLOCK;
            }
            pflags.* |= h.NGHTTP3_DATA_FLAG_EOF;
            return 0;
        }
        const count = s.out.take(vec, veccnt);
        if (s.send_closed and s.out.allSent()) pflags.* |= h.NGHTTP3_DATA_FLAG_EOF;
        return @intCast(count);
    }
};

/// One request and its response. Every field is guarded by the
/// connection's mutex.
pub const Stream = struct {
    conn: *ClientConnection,
    id: i64 = -1,
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
    /// Why the stream ended early (reset, the connection went, the time
    /// ran out).
    cause: ?StreamError = null,
    /// Behind the last `ReadFailed` (the reading task's) and `WriteFailed`
    /// (the writing task's).
    read_err: ?StreamError = null,
    write_err: ?StreamError = null,

    /// Response body bytes not yet read.
    body: std.ArrayList(u8) = .empty,
    body_start: usize = 0,
    body_done: bool = false,
    body_reader: std.Io.Reader,

    has_body: bool,
    /// The request body until the server acknowledges it.
    out: bridge.Ring = .{},
    out_writer: std.Io.Writer,
    send_closed: bool,
    /// The server sent STOP_SENDING.
    send_stopped: bool = false,
    /// nghttp3 asked for body and got none: resume it on the next write.
    deferred: bool = false,

    /// Both the caller (`release`) and QUIC (stream close) are done.
    user_done: bool = false,
    /// Let go with `releaseSent`: what it sent is still on its way, and
    /// `ClientConnection.close` waits for it.
    lingering: bool = false,
    protocol_done: bool = false,
    /// The request's head, while it went in 0-RTT that the server may
    /// still refuse.
    early_headers: ?[]h.nghttp3_nv = null,

    fn create(conn: *ClientConnection, has_body: bool, deadline: Deadline) !*Stream {
        const self = try conn.gpa.create(Stream);
        errdefer conn.gpa.destroy(self);
        self.* = .{
            .conn = conn,
            .arena = .init(conn.gpa),
            .deadline = deadline,
            .body_reader = .{ .buffer = &.{}, .seek = 0, .end = 0, .vtable = &.{ .stream = readBody } },
            .out_writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drainOut, .flush = flushOut } },
            .has_body = has_body,
            .send_closed = !has_body,
        };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        self.body_reader.buffer = try a.alloc(u8, 16 * 1024);
        if (has_body) self.out_writer.buffer = try a.alloc(u8, 16 * 1024);
        conn.lock();
        conn.live.append(&self.node);
        conn.unlock();
        return self;
    }

    /// For a stream that never reached QUIC.
    fn destroy(self: *Stream) void {
        const conn = self.conn;
        conn.lock();
        conn.live.remove(&self.node);
        conn.unlock();
        self.free();
    }

    fn free(self: *Stream) void {
        const gpa = self.conn.gpa;
        self.body.deinit(gpa);
        self.out.deinit(gpa);
        self.arena.deinit();
        gpa.destroy(self);
    }

    /// Frees the stream once both sides let go. Locked.
    fn maybeFree(self: *Stream) void {
        if (!(self.user_done and self.protocol_done)) return;
        self.conn.live.remove(&self.node);
        self.free();
    }

    /// The stream ended early, unless its response was complete or it
    /// already has a cause. Locked.
    fn endEarly(self: *Stream, cause: StreamError) void {
        if (self.cause == null and !self.body_done) self.cause = cause;
    }

    fn copyHeaders(self: *Stream, headers: []const Header) ![]h.nghttp3_nv {
        const a = self.arena.allocator();
        const nva = try a.alloc(h.nghttp3_nv, headers.len);
        for (headers, nva) |f, *nv| {
            const name = try a.dupe(u8, f.name);
            const value = try a.dupe(u8, f.value);
            nv.* = .{ .name = name.ptr, .namelen = name.len, .value = value.ptr, .valuelen = value.len, .flags = h.NGHTTP3_NV_FLAG_NONE };
        }
        return nva;
    }

    fn addField(self: *Stream, list: *std.ArrayList(Header), name: []const u8, value: []const u8) !void {
        const a = self.arena.allocator();
        try list.append(a, .{ .name = try a.dupe(u8, name), .value = try a.dupe(u8, value) });
    }

    /// Waits for the response head (`status`, `headers`).
    pub fn waitHead(self: *Stream) StreamError!void {
        const conn = self.conn;
        while (true) {
            const gen = conn.gen.load(.acquire);
            conn.lock();
            const ready = self.head_ready;
            const cause = self.cause;
            conn.unlock();
            if (ready) return;
            if (cause) |e| return e;
            try self.waitFor(gen);
        }
    }

    /// One wait for news on the connection, within the request's budget.
    /// Past it the stream is reset.
    fn waitFor(self: *Stream, gen: u32) error{ Timeout, Canceled }!void {
        self.deadline.run(ClientConnection.wait, .{ self.conn, gen }) catch |err| switch (err) {
            error.Timeout => {
                self.conn.lock();
                defer self.conn.unlock();
                self.cancelLocked(error.Timeout);
                return error.Timeout;
            },
            else => return error.Canceled,
        };
    }

    /// The first response header named `name` (any case), once `waitHead`
    /// has returned; null when absent.
    pub fn header(self: *const Stream, name: []const u8) ?[]const u8 {
        for (self.headers.items) |f| if (std.ascii.eqlIgnoreCase(f.name, name)) return f.value;
        return null;
    }

    /// The first trailer named `name` (any case), once the body has been
    /// read to its end; null when absent.
    pub fn trailer(self: *const Stream, name: []const u8) ?[]const u8 {
        for (self.trailers.items) |f| if (std.ascii.eqlIgnoreCase(f.name, name)) return f.value;
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

    /// What the last `ReadFailed` from `reader` was.
    pub fn readError(self: *const Stream) ?StreamError {
        return self.read_err;
    }

    /// What the last `WriteFailed` from `writer` was.
    pub fn writeError(self: *const Stream) ?StreamError {
        return self.write_err;
    }

    /// Ends the request body.
    pub fn closeSend(self: *Stream) !void {
        try self.out_writer.flush();
        const conn = self.conn;
        conn.lock();
        self.send_closed = true;
        self.resumeLocked();
        conn.unlock();
        conn.kick();
    }

    /// Resets the stream (H3_REQUEST_CANCELLED) if it is still open.
    pub fn cancel(self: *Stream) void {
        const conn = self.conn;
        conn.lock();
        defer conn.unlock();
        self.cancelLocked(error.Canceled);
    }

    fn cancelLocked(self: *Stream, cause: StreamError) void {
        const conn = self.conn;
        if (self.submitted and !self.protocol_done and conn.state != .closed)
            _ = c.ngtcp2_conn_shutdown_stream(conn.q, 0, self.id, h.NGHTTP3_H3_REQUEST_CANCELLED);
        self.endEarly(cause);
        conn.kick();
    }

    /// Done with the stream: an unfinished one is canceled first.
    pub fn release(self: *Stream) void {
        const conn = self.conn;
        conn.lock();
        defer conn.unlock();
        const sent = !self.has_body or self.send_stopped or (self.send_closed and self.out.allSent());
        if (!(self.body_done and sent)) self.cancelLocked(error.Canceled);
        self.user_done = true;
        // A stream QUIC never got, or one the connection's end left
        // behind, has no close to wait for.
        if (!self.submitted or conn.state == .closed) self.protocol_done = true;
        self.maybeFree();
    }

    /// Done with a stream whose request body the caller ended: unlike
    /// `release`, it neither resets the stream nor stops the response
    /// (a server may take STOP_SENDING for a cancel and drop the request
    /// body still in flight), so what was written and the end still reach
    /// the server, and `ClientConnection.close` waits for them. The rest
    /// of the response is dropped. A stream not ended that way is released
    /// as by `release`.
    fn releaseSent(self: *Stream) void {
        const conn = self.conn;
        conn.lock();
        const ended = self.send_closed and self.cause == null and !self.send_stopped;
        if (!ended) {
            conn.unlock();
            return self.release();
        }
        defer conn.unlock();
        // The response from here on is dropped, its credit given back, so
        // the server can always reach its end.
        const unread = self.body.items.len - self.body_start;
        if (unread > 0 and self.submitted and !self.protocol_done and conn.state != .closed)
            bridge.consume(conn.q, self.id, unread);
        self.body.clearRetainingCapacity();
        self.body_start = 0;
        self.lingering = true;
        self.user_done = true;
        if (!self.submitted or conn.state == .closed) self.protocol_done = true;
        self.maybeFree();
    }

    /// Tells nghttp3 there is more body, if it was waiting for some.
    /// Locked.
    fn resumeLocked(self: *Stream) void {
        if (!self.deferred) return;
        self.deferred = false;
        if (self.conn.h3) |hc| _ = h.nghttp3_conn_resume_stream(hc, self.id);
    }

    fn readBody(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Stream = @alignCast(@fieldParentPtr("body_reader", r));
        const conn = self.conn;
        const dest = limit.slice(try w.writableSliceGreedy(1));
        if (dest.len == 0) return 0;
        while (true) {
            const gen = conn.gen.load(.acquire);
            conn.lock();
            const avail = self.body.items[self.body_start..];
            if (avail.len > 0) {
                const n = @min(avail.len, dest.len);
                @memcpy(dest[0..n], avail[0..n]);
                self.body_start += n;
                if (self.body_start == self.body.items.len) {
                    self.body.clearRetainingCapacity();
                    self.body_start = 0;
                } else if (self.body_start >= 64 * 1024) {
                    self.body.replaceRangeAssumeCapacity(0, self.body_start, &.{});
                    self.body_start = 0;
                }
                // The server may send that much more.
                if (!self.protocol_done and conn.state != .closed) bridge.consume(conn.q, self.id, n);
                conn.unlock();
                w.advance(n);
                conn.kick();
                return n;
            }
            const done = self.body_done;
            const cause = self.cause;
            conn.unlock();
            if (done) return error.EndOfStream;
            if (cause) |e| {
                self.read_err = e;
                return error.ReadFailed;
            }
            self.waitFor(gen) catch |e| {
                self.read_err = e;
                return error.ReadFailed;
            };
        }
    }

    /// Copies request body bytes into the ring, waiting while it is full
    /// (the server has not acknowledged enough yet).
    fn put(self: *Stream, bytes: []const u8) std.Io.Writer.Error!void {
        const conn = self.conn;
        if (!self.has_body) return error.WriteFailed;
        var rest = bytes;
        while (rest.len > 0) {
            const gen = conn.gen.load(.acquire);
            conn.lock();
            if (self.cause != null or self.send_stopped or conn.state == .closed) {
                self.write_err = self.cause orelse if (self.send_stopped) error.StreamReset else error.ConnectionClosed;
                conn.unlock();
                return error.WriteFailed;
            }
            const n = self.out.write(conn.gpa, rest) catch {
                conn.unlock();
                return error.WriteFailed;
            };
            if (n > 0) {
                rest = rest[n..];
                self.resumeLocked();
            }
            conn.unlock();
            // Kick only for new bytes; see the server's StreamSink.put.
            if (n > 0) conn.kick() else self.waitFor(gen) catch |e| {
                self.write_err = e;
                return error.WriteFailed;
            };
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
