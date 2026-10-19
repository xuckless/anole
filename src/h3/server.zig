//! The HTTP/3 server: a QUIC endpoint on one UDP socket (ngtcp2), HTTP/3
//! on each connection (nghttp3), and every request handed to the same
//! router, middleware and `(req, res)` handlers as HTTP/1.1 and HTTP/2,
//! through dusty's `Server.dispatch` with a sink-backed `Response`. On
//! Linux a listener has one endpoint per executor, each on a socket of one
//! SO_REUSEPORT group (`Endpoint`, `steer`).
//!
//! Tasks, all placed on the endpoint's executor (`placement .local`):
//!
//!   * the endpoint task: the only reader of the socket. It routes each
//!     packet to its connection by destination connection ID, accepts new
//!     connections (optionally after a Retry), and answers what belongs to
//!     no connection (version negotiation, stateless reset); it passes a
//!     packet for another endpoint's connection on to that endpoint;
//!   * the inbox task: handles what other endpoints pass on;
//!   * one driver task per connection: writes the connection's packets,
//!     runs its timers, and its closing and draining periods;
//!   * one task per request: builds the `Request` and the `Response` and
//!     runs the router.
//!
//! ngtcp2 and nghttp3 are not reentrant, so a connection's mutex covers
//! every call into them; under it they only compute. Socket I/O and the
//! handlers run outside it.
//!
//! Request bodies: queued per stream as nghttp3 delivers them, and the
//! stream's flow-control credit is returned as the handler reads.
//! Response bodies: written into a fixed ring per stream that nghttp3
//! reads from without copying, so bytes stay there until the peer has
//! acknowledged them; a handler blocks while the ring is full.
//!
//! Ported from ngtcp2's examples/server.cc and
//! http3_server_proto_codec.cc (MIT, ngtcp2 1.25.0); the request and
//! response plumbing follows dusty's HTTP/2 engine (src/server/h2.zig in
//! the xuckless/dusty fork).
const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");
const ngtcp2 = @import("ngtcp2.zig");
const nghttp3 = @import("nghttp3.zig");
const quic_tls = @import("quic_tls.zig");
const dusty_tls = @import("anole_dusty_tls");
const net = @import("net.zig");
const bridge = @import("bridge.zig");
const webtransport = @import("webtransport.zig");
const early_data = @import("../early_data.zig");
const steer = @import("steer.zig");
const builtin = @import("builtin");
const Addr = net.Addr;
const CidKey = net.CidKey;
const now = net.now;
const wallClock = net.wallClock;

const c = ngtcp2.c;
const h = nghttp3.c;
const placement = dusty.placement;

const log = std.log.scoped(.anole_h3);

/// What a request body read can fail with, as dusty's engines report it.
const ReadError = @typeInfo(@typeInfo(@typeInfo(@FieldType(dusty.BodySource, "err")).pointer.child).@"fn".return_type.?).optional.child;
const SendError = dusty.Response.SendError;

/// Our connection IDs' length, as ngtcp2's examples use; one byte of them
/// names the endpoint (`steer`).
const scid_len = steer.cid_len;
/// Packets written per driver round (one send each).
const burst = 10;
/// Stateless resets sent per second at most (ngtcp2's examples' figure).
const stateless_reset_burst = 100;
/// QUIC v2 first when the client offers both.
const preferred_versions = [_]u32{ c.NGTCP2_PROTO_VER_V2, c.NGTCP2_PROTO_VER_V1 };

pub const Options = struct {
    address: std.Io.net.IpAddress,
    /// PEM: the certificate chain (leaf first) and its key. Read by
    /// `init` only; a reload passes its own (`Endpoint.loadTls`).
    cert_pem: []const u8,
    key_pem: []const u8,
    /// Requests a client may have open at once on a connection.
    max_streams_bidi: u64 = 100,
    /// Connection and per-stream receive windows.
    max_data: u64 = 16 << 20,
    max_stream_data: u64 = 1 << 20,
    idle_timeout_ms: u32 = 30_000,
    /// Validate every client address with a Retry round trip before
    /// keeping state for it (costs one RTT; resists spoofed floods).
    validate_address: bool = false,
    /// How long a drain lets requests finish before closing connections.
    drain_timeout_ms: u32 = 10_000,
    /// Largest request header section.
    max_field_section_size: u64 = 64 * 1024,
    /// Also speak HTTP/0.9 over QUIC (ALPN "hq-interop"), serving the files
    /// under this directory: what the QUIC interop runner's tests use. Only
    /// for interop testing; it bypasses the router and every middleware.
    hq_interop_root: ?[]const u8 = null,
    /// Mutual TLS: ask for client certificates and verify them, as the TCP
    /// listener does. Handlers read the certificate with
    /// `Request.peerCertificate`.
    client_auth: ?quic_tls.ClientAuth = null,
    /// UDP sockets, each served by an endpoint on an executor of its own:
    /// on Linux several share `address` through SO_REUSEPORT, and the
    /// kernel steers datagrams among them by connection ID (`Endpoint`).
    /// Elsewhere always one. At most 255.
    sockets: u16 = 1,
    /// Serve this UDP socket, opened elsewhere (systemd, or the process
    /// this one replaces), instead of binding `address`.
    fd: ?std.posix.fd_t = null,
    /// Or these: one SO_REUSEPORT group's sockets, in the order they were
    /// bound in (a predecessor passes them so). `sockets` is then their
    /// count. Sockets in another order still work, through the endpoints
    /// passing packets on to each other, only slower.
    fds: []const std.posix.fd_t = &.{},
    /// The key for stateless reset and address validation tokens; random
    /// when null. A process that takes over the socket gets its
    /// predecessor's, so the predecessor's clients accept the stateless
    /// resets it sends them.
    secret: ?[32]u8 = null,
    /// Take 0-RTT from clients that resume a session: their first requests
    /// arrive with the handshake, one round trip sooner. Such a request may
    /// be a replay until the handshake completes, so GET, HEAD and OPTIONS
    /// run at once (with `Early-Data: 1` among their headers) and every
    /// other method waits for the handshake, which a replay never
    /// completes (RFC 8470 §3).
    early_data: bool = false,
    /// Advertise extended CONNECT (RFC 9220), so a client may open a
    /// WebSocket, or another protocol, on a request stream. Such a request
    /// reaches the router as a GET with `Request.protocol` set, as over
    /// HTTP/2.
    enable_connect_protocol: bool = true,
    /// Speak WebTransport (draft-02, what Chrome and Firefox use): its
    /// SETTINGS, HTTP datagrams, and its streams beside the requests.
    /// Sessions reach the router as extended CONNECTs (`:protocol
    /// webtransport`), for `anole.webtransport.accept`. Read when each
    /// connection starts, so it may be turned on after `init`.
    webtransport: bool = false,
    /// WebTransport streams the peer may open beside requests: the
    /// unidirectional ones (the bidirectional ones share
    /// `max_streams_bidi`).
    webtransport_max_streams_uni: u64 = 100,
};

/// The SETTINGS every connection of an endpoint sends.
fn http3Settings(options: *const Options) nghttp3.Settings {
    var settings: nghttp3.Settings = undefined;
    nghttp3.settingsDefault(&settings);
    settings.qpack_max_dtable_capacity = 4096;
    settings.qpack_blocked_streams = 100;
    settings.max_field_section_size = options.max_field_section_size;
    settings.enable_connect_protocol = @intFromBool(options.enable_connect_protocol or options.webtransport);
    settings.h3_datagram = @intFromBool(options.webtransport);
    return settings;
}

/// The transport parameters `options` decide; a connection adds its
/// connection IDs and tokens.
fn transportParams(options: *const Options) ngtcp2.TransportParams {
    var params: ngtcp2.TransportParams = undefined;
    ngtcp2.transportParamsDefault(&params);
    params.initial_max_stream_data_bidi_local = options.max_stream_data;
    params.initial_max_stream_data_bidi_remote = options.max_stream_data;
    params.initial_max_stream_data_uni = options.max_stream_data;
    params.initial_max_data = options.max_data;
    params.initial_max_streams_bidi = options.max_streams_bidi;
    // The control and QPACK streams, and WebTransport's.
    params.initial_max_streams_uni = 3 + if (options.webtransport) options.webtransport_max_streams_uni else 0;
    // HTTP datagrams (RFC 9297), for WebTransport.
    if (options.webtransport) params.max_datagram_frame_size = 65535;
    params.max_idle_timeout = @as(u64, options.idle_timeout_ms) * c.NGTCP2_MILLISECONDS;
    return params;
}

/// Room for `earlyDataContext`'s output.
pub const early_context_max = 1 + 256 + 6 * 8;
/// Bumped whenever the layout below changes, so older tickets stop
/// carrying 0-RTT rather than being misread.
const early_context_version = 2;

/// What 0-RTT tickets are tied to (`quic_tls.setEarlyDataContext`): a
/// version byte, ngtcp2's encoding of the transport parameters a client
/// remembers (limits, idle timeout and so on, not the per-connection IDs and
/// tokens), and the SETTINGS values a client may assume (RFC 9114 §7.2.4.2).
/// Any change to either, such as a new `max_streams_bidi`, makes old
/// tickets resume without 0-RTT.
fn earlyDataContext(q: *const c.ngtcp2_conn, settings: nghttp3.Settings, wt: bool, buf: *[early_context_max]u8) ![]const u8 {
    buf[0] = early_context_version;
    const n = c.ngtcp2_conn_encode_0rtt_transport_params2(q, buf[1..].ptr, buf.len - 1 - 6 * 8);
    if (n < 0) return error.QuicSetupFailed;
    var len: usize = 1 + @as(usize, @intCast(n));
    for ([_]u64{
        settings.max_field_section_size,
        settings.qpack_max_dtable_capacity,
        settings.qpack_blocked_streams,
        settings.enable_connect_protocol,
        settings.h3_datagram,
        // SETTINGS_ENABLE_WEBTRANSPORT, sent beside nghttp3's.
        @intFromBool(wt),
    }) |v| {
        std.mem.writeInt(u64, buf[len..][0..8], v, .little);
        len += 8;
    }
    return buf[0..len];
}

/// Packets waiting in an endpoint's inbox at most (`Endpoint.forward`);
/// more are dropped, which QUIC takes as loss.
const inbox_len = 256;

/// One endpoint's counters. Several endpoints serve one listener on Linux
/// (`Options.sockets`); these show how the kernel's steering does.
pub const Stats = struct {
    /// Packets this endpoint handled: from its own socket, and passed on to
    /// it by another endpoint (`forwarded_in`).
    packets: std.atomic.Value(u64) = .init(0),
    /// Of those, the ones another endpoint's socket received.
    forwarded_in: std.atomic.Value(u64) = .init(0),
    /// Packets this endpoint's socket received for another endpoint's
    /// connection, and passed on to it.
    forwarded_out: std.atomic.Value(u64) = .init(0),
    /// Packets for another endpoint dropped: its inbox was full, or it had
    /// stopped.
    dropped: std.atomic.Value(u64) = .init(0),
    /// Connections accepted.
    accepted: std.atomic.Value(u64) = .init(0),
    /// Packets handled on another thread than the endpoint's own: always
    /// zero; counted in test builds only.
    foreign: std.atomic.Value(u64) = .init(0),
};

/// One HTTP/3 listener, serving `server`'s router: one endpoint per UDP
/// socket. On Linux a listener may have several (`Options.sockets`), each
/// bound to the same address with SO_REUSEPORT and served by an endpoint on
/// an executor of its own, so HTTP/3 uses every core as TCP does. The
/// kernel steers each datagram to the socket whose endpoint owns its
/// connection, by a byte of the connection ID (`steer`); a datagram that
/// lands on another endpoint's socket all the same is passed on to the
/// owner's inbox and handled there, never where it landed. `init` returns
/// the first endpoint, which owns the others: `run`, `deinit`, `handOver`,
/// `loadTls`, `useTls` and `address` act on the whole listener through it.
pub fn Endpoint(comptime Ctx: type) type {
    return struct {
        const Self = @This();
        const HttpServer = dusty.Server(Ctx);

        gpa: std.mem.Allocator,
        io: std.Io,
        http: *HttpServer,
        /// A copy per endpoint of the listener's options. They must stay
        /// the same on every endpoint: a client resumes on whichever one
        /// the kernel picks, and its 0-RTT is refused where the SETTINGS or
        /// limits differ. Change them through the listener (as
        /// `enableWebTransport` does), never on one endpoint.
        options: Options,
        udp: net.Udp,
        local: Addr,
        /// This endpoint's place among the listener's: its socket's index in
        /// the reuseport group (the order they were bound in), the executor
        /// it runs on (modulo their count), and the byte its connection IDs
        /// carry when there are several.
        index: u8,
        /// What the listener's endpoints share.
        shared: *Shared,
        /// Keys stateless reset tokens and address validation tokens: the
        /// same in every endpoint of the listener.
        secret: [32]u8,
        /// The connection IDs in use, ours and the clients' first ones: this
        /// endpoint's connections only.
        map_mutex: std.Io.Mutex = .init,
        conns: std.AutoHashMapUnmanaged(CidKey, *Conn) = .empty,
        /// The connections' driver tasks.
        group: std.Io.Group = .init,
        draining: bool = false,
        /// Stateless resets left in the current second.
        reset_budget: u32 = 0,
        reset_window: u64 = 0,
        /// The listener requests report (address, `secure`).
        listener: dusty.Listener,
        /// Requests that came in 0-RTT: run before the handshake completed
        /// (GET, HEAD, OPTIONS), and held until it had (the rest).
        early_served: std.atomic.Value(u64) = .init(0),
        early_held: std.atomic.Value(u64) = .init(0),
        /// Packets other endpoints' sockets received for this one's
        /// connections, handled by a task of this endpoint's.
        inbox: std.Io.Queue(*Forwarded),
        inbox_buf: [inbox_len]*Forwarded = undefined,
        /// What the socket is read into.
        rx: []u8,
        stats: Stats = .{},
        /// The thread serving the endpoint, in test builds (`Stats.foreign`).
        thread: ?std.Thread.Id = null,

        /// What a listener's endpoints share; the first endpoint owns it.
        const Shared = struct {
            /// In socket order: `endpoints[i].index == i`.
            endpoints: []*Self,
            /// What new connections handshake with, on every endpoint, so a
            /// session ticket from one resumes (with 0-RTT) on any other;
            /// `useTls` replaces it, so it is read under `tls_lock`
            /// (`newTlsSession`).
            tls: quic_tls.Context,
            tls_lock: std.atomic.Mutex = .unlocked,
            /// The sockets go to another process: close every connection at
            /// once and stop reading (see `handOver`).
            hand_over: std.atomic.Value(bool) = .init(false),
        };

        /// A datagram passed from the endpoint whose socket received it to
        /// the one that owns its connection.
        const Forwarded = struct {
            from: std.Io.net.IpAddress,
            local: ?std.Io.net.IpAddress,
            ecn: u8,
            data: []u8,
        };

        /// The listener: its endpoints, their sockets bound (or adopted) in
        /// order, and the steering program on them. Returns the first.
        pub fn init(gpa: std.mem.Allocator, io: std.Io, http: *HttpServer, options: Options) !*Self {
            const inherited: []const std.posix.fd_t = if (options.fd) |*fd| fd[0..1] else options.fds;
            const count: usize = if (inherited.len > 0)
                inherited.len
            else if (builtin.os.tag == .linux) options.sockets else 1;
            if (count == 0 or count > steer.max_sockets) return error.InvalidSocketCount;

            const shared = try gpa.create(Shared);
            errdefer gpa.destroy(shared);
            shared.* = .{ .endpoints = try gpa.alloc(*Self, count), .tls = undefined };
            errdefer gpa.free(shared.endpoints);
            shared.tls = try newTlsContext(options);
            errdefer shared.tls.deinit();
            var secret: [32]u8 = undefined;
            if (options.secret) |s| secret = s else io.random(&secret);

            // Several sockets share the port: none but ours may be on it
            // already. An inherited group is ours.
            if (inherited.len == 0 and count > 1) try net.checkUdpAddressFree(options.address);
            var made: usize = 0;
            errdefer for (shared.endpoints[0..made]) |ep| ep.deinitOne();
            var bind_to = options.address;
            for (0..count) |i| {
                const socket = if (inherited.len > 0)
                    try adoptSocket(io, inherited[i], options.address)
                else if (count == 1)
                    try bind_to.bind(io, .{ .mode = .dgram, .protocol = .udp })
                else
                    try bindMember(io, bind_to);
                shared.endpoints[i] = initOne(gpa, io, http, options, socket, @intCast(i), shared, secret) catch |err| {
                    socket.close(io);
                    return err;
                };
                made += 1;
                // The port the first got, when 0 was asked for.
                bind_to = socket.address;
            }
            // The group numbers its sockets in bind order, as we did, so
            // the program's index is the endpoint's. Inherited sockets keep
            // the order their first owner bound them in.
            if (count > 1) steer.attach(shared.endpoints[0].udp.socket.handle, @intCast(count)) catch
                log.warn("HTTP/3: no connection-ID steering (classic BPF on SO_REUSEPORT needs Linux 4.5+); the {d} endpoints pass packets on to each other instead", .{count});
            net.rand_io = io;
            return shared.endpoints[0];
        }

        /// One more socket of the group, SO_REUSEPORT, as zio wants it.
        fn bindMember(io: std.Io, at: std.Io.net.IpAddress) !std.Io.net.Socket {
            const fd = try net.bindReusePort(at);
            return adoptSocket(io, fd, at) catch |err| {
                _ = std.c.close(fd);
                return err;
            };
        }

        fn initOne(gpa: std.mem.Allocator, io: std.Io, http: *HttpServer, options: Options, socket: std.Io.net.Socket, index: u8, shared: *Shared, secret: [32]u8) !*Self {
            const self = try gpa.create(Self);
            errdefer gpa.destroy(self);
            self.* = .{
                .gpa = gpa,
                .io = io,
                .http = http,
                .options = options,
                .udp = .init(socket),
                .local = .from(socket.address),
                .index = index,
                .shared = shared,
                .secret = secret,
                .listener = .{ .address = .{ .ip = socket.address } },
                .inbox = undefined,
                .rx = try gpa.alloc(u8, net.Udp.batch_buffer_len),
            };
            self.inbox = .init(&self.inbox_buf);
            return self;
        }

        /// Wraps a UDP socket this process did not open. Under zio, which
        /// drives its own sockets non-blocking, it is made so too.
        fn adoptSocket(io: std.Io, fd: std.posix.fd_t, configured: std.Io.net.IpAddress) !std.Io.net.Socket {
            const sc = std.c;
            var kind: c_int = 0;
            var kind_len: std.posix.socklen_t = @sizeOf(c_int);
            if (sc.getsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.TYPE, @ptrCast(&kind), &kind_len) != 0 or
                kind != std.posix.SOCK.DGRAM) return error.InheritedSocketNotDatagram;
            if (placement.executorCount(io) != null) {
                const flags = sc.fcntl(fd, sc.F.GETFL, @as(c_int, 0));
                if (flags < 0) return error.InvalidInheritedSocket;
                _ = sc.fcntl(fd, sc.F.SETFL, flags | @as(c_int, 1 << @bitOffsetOf(std.posix.O, "NONBLOCK")));
            }
            var storage: std.Io.Threaded.PosixAddress = undefined;
            var len: std.posix.socklen_t = @sizeOf(std.Io.Threaded.PosixAddress);
            const bound: std.Io.net.IpAddress = if (sc.getsockname(fd, &storage.any, &len) == 0 and
                (storage.any.family == std.posix.AF.INET or storage.any.family == std.posix.AF.INET6))
                std.Io.Threaded.addressFromPosix(&storage)
            else
                configured;
            return .{ .handle = fd, .address = bound };
        }

        /// For a restart that passes the sockets to a new process: when
        /// `run` is canceled next, every connection gets a final GOAWAY and
        /// a CONNECTION_CLOSE at once, and the endpoints stop reading, so
        /// every datagram goes to the new process. Requests in flight are
        /// cut. Safe from any task or thread.
        pub fn handOver(self: *Self) void {
            self.shared.hand_over.store(true, .release);
        }

        /// The whole listener; on the first endpoint, once `run` is over.
        pub fn deinit(self: *Self) void {
            const shared = self.shared;
            const gpa = self.gpa;
            for (shared.endpoints) |ep| ep.deinitOne();
            shared.tls.deinit();
            gpa.free(shared.endpoints);
            gpa.destroy(shared);
        }

        fn deinitOne(self: *Self) void {
            self.udp.socket.close(self.io);
            self.conns.deinit(self.gpa);
            // What other endpoints passed on after this one stopped.
            var left: [1]*Forwarded = undefined;
            while ((self.inbox.getUncancelable(self.io, &left, 0) catch 0) == 1) self.freeForwarded(left[0]);
            self.gpa.free(self.rx);
            self.gpa.destroy(self);
        }

        /// The listener's endpoints, in socket order (`sockets` of them):
        /// their sockets, to hand to a successor, and their `stats`.
        pub fn endpoints(self: *const Self) []const *Self {
            return self.shared.endpoints;
        }

        /// The TLS context for `options`, with session ticket keys of its
        /// own (see `useTls`).
        fn newTlsContext(options: Options) !quic_tls.Context {
            var tls = try quic_tls.Context.init(.{
                .cert_pem = options.cert_pem,
                .key_pem = options.key_pem,
                .hq_interop = options.hq_interop_root != null,
                .client_auth = options.client_auth,
                .early_data = options.early_data,
            });
            errdefer tls.deinit();
            try dusty_tls.installTicketKeys(tls.ctx);
            return tls;
        }

        /// A certificate reload, first step: the TLS context for a new
        /// certificate and key (PEM) and client CAs, the rest as before.
        /// Nothing changes until `useTls`; `deinit` it to drop it.
        pub fn loadTls(self: *const Self, cert_pem: []const u8, key_pem: []const u8, client_auth: ?quic_tls.ClientAuth) !quic_tls.Context {
            var options = self.options;
            options.cert_pem = cert_pem;
            options.key_pem = key_pem;
            options.client_auth = client_auth;
            return newTlsContext(options);
        }

        /// A certificate reload, second step: connections that start from
        /// now on, on every endpoint of the listener, handshake with `tls`,
        /// which takes over the session ticket keys, so tickets issued
        /// before still resume. Connections already open keep the context
        /// they started with (each `SSL` holds a reference to it). Safe from
        /// any task or thread.
        /// Turns WebTransport on for every endpoint of the listener, for
        /// connections that start from now on.
        pub fn enableWebTransport(self: *Self) void {
            for (self.shared.endpoints) |e| e.options.webtransport = true;
        }

        pub fn useTls(self: *Self, tls: quic_tls.Context) void {
            const shared = self.shared;
            lockTls(shared);
            dusty_tls.carryTicketKeys(tls.ctx, shared.tls.ctx);
            var old = shared.tls;
            shared.tls = tls;
            shared.tls_lock.unlock();
            old.deinit();
        }

        fn lockTls(shared: *Shared) void {
            while (!shared.tls_lock.tryLock()) std.atomic.spinLoopHint();
        }

        /// A server `SSL` for a new connection, from the context in place.
        fn newTlsSession(self: *Self, conn_ref: *c.ngtcp2_crypto_conn_ref) !*c.SSL {
            const shared = self.shared;
            lockTls(shared);
            var tls = shared.tls;
            // A reference of our own, so a reload cannot free it between
            // here and `SSL_new`, which takes the `SSL`'s.
            _ = c.SSL_CTX_up_ref(tls.ctx);
            shared.tls_lock.unlock();
            defer tls.deinit();
            return tls.newSession(conn_ref);
        }

        /// A connection ID of ours, new: random, and with several endpoints
        /// this one's index in the byte the kernel steers by (`steer`).
        fn newCid(self: *const Self, bytes: []u8) void {
            self.io.random(bytes);
            if (self.shared.endpoints.len > 1 and bytes.len > steer.index_byte) bytes[steer.index_byte] = self.index;
        }

        /// The bound address (the real port when 0 was asked for); the
        /// same for every endpoint of the listener.
        pub fn address(self: *const Self) std.Io.net.IpAddress {
            return self.udp.socket.address;
        }

        /// Serves until canceled, then drains: every connection gets a
        /// GOAWAY, requests in flight finish (within `drain_timeout_ms`),
        /// and the connections close. Every endpoint of the listener, each
        /// on its executor; call it on the first.
        pub fn run(self: *Self) !void {
            const io = self.io;
            var group: std.Io.Group = .init;
            for (self.shared.endpoints) |ep| placement.concurrent(&group, io, .{ .executor = ep.index }, serve, .{ep}) catch |err| {
                group.cancel(io);
                return err;
            };
            // Canceled: the endpoints have drained by the time it returns.
            group.await(io) catch io.recancel();
        }

        /// One endpoint, on its executor: reads its socket, and its inbox
        /// in a task beside it.
        fn serve(self: *Self) std.Io.Cancelable!void {
            const io = self.io;
            if (builtin.is_test) self.thread = std.Thread.getCurrentId();
            var reader: std.Io.Group = .init;
            // Without the task, packets passed on to it are dropped.
            placement.concurrent(&reader, io, .local, readInbox, .{self}) catch self.inbox.close(io);
            var batch: net.Udp.Batch = .{};
            while (true) {
                const n = self.udp.receiveBatch(io, self.rx, &batch, .none) catch |err| switch (err) {
                    error.Canceled => break,
                    else => {
                        log.debug("receive: {t}", .{err});
                        continue;
                    },
                };
                for (0..n) |i| {
                    var dg = batch.datagram(&self.udp, i);
                    self.onDatagram(&dg);
                }
            }
            self.shutdown(&batch.controls[0]);
            self.inbox.close(io);
            reader.cancel(io);
        }

        /// Handles what other endpoints pass on, until the inbox closes.
        fn readInbox(self: *Self) std.Io.Cancelable!void {
            while (true) {
                const f = self.inbox.getOne(self.io) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    error.Closed => return,
                };
                defer self.freeForwarded(f);
                _ = self.stats.forwarded_in.fetchAdd(1, .monotonic);
                self.onPacket(f.from, f.local, f.ecn, f.data);
            }
        }

        fn freeForwarded(self: *Self, f: *Forwarded) void {
            self.gpa.free(f.data);
            self.gpa.destroy(f);
        }

        /// The endpoint that owns the connection `packet`'s destination
        /// connection ID names, when that is another one: the steering
        /// program's rule, so user space and the kernel agree.
        fn owner(self: *const Self, packet: []const u8) ?*Self {
            const eps = self.shared.endpoints;
            if (eps.len < 2) return null;
            const i = steer.indexOf(packet, eps.len) orelse return null;
            return if (i == self.index) null else eps[i];
        }

        /// Passes a packet to the endpoint that owns its connection: it
        /// landed here because the kernel had no program to steer by, or a
        /// GRO batch began with another connection's packet, or a client
        /// moved before the program could see its new ID.
        fn forward(self: *Self, to: *Self, from: std.Io.net.IpAddress, local: ?std.Io.net.IpAddress, ecn: u8, data: []const u8) void {
            const f = self.gpa.create(Forwarded) catch return self.dropForwarded(null);
            f.* = .{ .from = from, .local = local, .ecn = ecn, .data = self.gpa.dupe(u8, data) catch {
                self.gpa.destroy(f);
                return self.dropForwarded(null);
            } };
            // Never waits: a full inbox drops it, as a full socket would.
            const n = to.inbox.putUncancelable(self.io, &.{f}, 0) catch 0;
            if (n == 0) return self.dropForwarded(f);
            _ = self.stats.forwarded_out.fetchAdd(1, .monotonic);
        }

        fn dropForwarded(self: *Self, f: ?*Forwarded) void {
            if (f) |p| self.freeForwarded(p);
            _ = self.stats.dropped.fetchAdd(1, .monotonic);
        }

        fn onDatagram(self: *Self, dg: *net.Udp.Datagram) void {
            while (dg.next()) |data| self.onPacket(dg.from, dg.local, dg.ecn, data);
        }

        fn shutdown(self: *Self, control: *align(std.Io.net.cmsg_align) net.Udp.Control) void {
            const protection = self.io.swapCancelProtection(.blocked);
            defer _ = self.io.swapCancelProtection(protection);
            self.draining = true;
            if (self.shared.hand_over.load(.acquire)) {
                // Not another read: what arrives now is the new process's.
                const conns = self.liveConns();
                for (conns) |conn| {
                    conn.handOver();
                    conn.unref();
                }
                self.gpa.free(conns);
                self.group.cancel(self.io);
                return;
            }
            const live = self.liveConns();
            for (live) |conn| {
                conn.beginDrain();
                conn.unref();
            }
            self.gpa.free(live);
            // Keep reading: the connections need the peers' ACKs and
            // requests to finish. Until every endpoint's are done, since
            // packets for another's may land on this socket.
            const deadline = now(self.io) + @as(u64, self.options.drain_timeout_ms) * std.time.ns_per_ms;
            while (now(self.io) < deadline) {
                if (self.listenerIdle()) break;
                var dg = self.udp.receive(self.io, self.rx, control, .{ .duration = .{
                    .raw = .fromMilliseconds(50),
                    .clock = .awake,
                } }) catch continue;
                self.onDatagram(&dg);
            }
            // Whatever is left is closed now.
            const left = self.liveConns();
            for (left) |conn| {
                conn.abort();
                conn.unref();
            }
            self.gpa.free(left);
            self.group.cancel(self.io);
        }

        /// No endpoint of the listener has a connection left.
        fn listenerIdle(self: *Self) bool {
            for (self.shared.endpoints) |ep| {
                ep.map_mutex.lockUncancelable(self.io);
                const remaining = ep.conns.count();
                ep.map_mutex.unlock(self.io);
                if (remaining > 0) return false;
            }
            return true;
        }

        /// Each live connection once, with a reference each.
        fn liveConns(self: *Self) []*Conn {
            self.map_mutex.lockUncancelable(self.io);
            defer self.map_mutex.unlock(self.io);
            var list: std.ArrayList(*Conn) = .empty;
            var it = self.conns.valueIterator();
            while (it.next()) |conn| {
                if (std.mem.indexOfScalar(*Conn, list.items, conn.*) != null) continue;
                list.append(self.gpa, conn.*) catch break;
                conn.*.ref();
            }
            return list.toOwnedSlice(self.gpa) catch &.{};
        }

        fn lookup(self: *Self, key: CidKey) ?*Conn {
            self.map_mutex.lockUncancelable(self.io);
            defer self.map_mutex.unlock(self.io);
            const conn = self.conns.get(key) orelse return null;
            conn.ref();
            return conn;
        }

        fn associate(self: *Self, key: CidKey, conn: *Conn) !void {
            self.map_mutex.lockUncancelable(self.io);
            defer self.map_mutex.unlock(self.io);
            try self.conns.put(self.gpa, key, conn);
        }

        fn dissociate(self: *Self, key: CidKey) void {
            self.map_mutex.lockUncancelable(self.io);
            defer self.map_mutex.unlock(self.io);
            _ = self.conns.remove(key);
        }

        /// A stateless reply, from `from` (a wildcard socket's address the
        /// packet answered was sent to).
        fn send(self: *Self, to: std.Io.net.IpAddress, from: ?std.Io.net.IpAddress, data: []const u8) void {
            self.udp.send(self.io, to, from, 0, data, data.len);
        }

        // -- Packets in ------------------------------------------------------

        /// One packet, from this endpoint's socket or passed on to it. The
        /// endpoint task and its inbox task both call it, on one executor,
        /// so it keeps nothing in the endpoint across a yield.
        fn onPacket(self: *Self, from: std.Io.net.IpAddress, local: ?std.Io.net.IpAddress, ecn: u8, data: []u8) void {
            var vc: c.ngtcp2_version_cid = undefined;
            switch (c.ngtcp2_pkt_decode_version_cid(&vc, data.ptr, data.len, scid_len)) {
                0 => {},
                c.NGTCP2_ERR_VERSION_NEGOTIATION => {
                    self.sendVersionNegotiation(from, local, &vc);
                    return;
                },
                else => return,
            }
            if (self.owner(data)) |ep| return self.forward(ep, from, local, ecn, data);
            _ = self.stats.packets.fetchAdd(1, .monotonic);
            if (builtin.is_test) if (self.thread) |t| if (t != std.Thread.getCurrentId()) {
                _ = self.stats.foreign.fetchAdd(1, .monotonic);
            };
            const remote: Addr = .from(from);
            if (self.lookup(.of(vc.dcid[0..vc.dcidlen]))) |conn| {
                defer conn.unref();
                conn.onPacket(remote, local, ecn, data);
                return;
            }
            if (self.draining) return;
            self.accept(remote, local, ecn, data, &vc);
        }

        fn accept(self: *Self, remote_in: Addr, local: ?std.Io.net.IpAddress, ecn: u8, data: []u8, vc: *const c.ngtcp2_version_cid) void {
            var remote = remote_in;
            var hd: c.ngtcp2_pkt_hd = undefined;
            if (c.ngtcp2_accept(&hd, data.ptr, data.len) != 0) {
                // A short-header packet for a connection we do not know:
                // tell the peer it is gone, if it is long enough to be one.
                if (data[0] & 0x80 == 0 and data.len >= scid_len + 21)
                    self.sendStatelessReset(remote.ip(), local, data.len, vc.dcid[0..vc.dcidlen]);
                return;
            }

            var ocid: c.ngtcp2_cid = undefined;
            var pocid: ?*c.ngtcp2_cid = null;
            var token_type: c.ngtcp2_token_type = c.NGTCP2_TOKEN_TYPE_UNKNOWN;
            if (self.options.validate_address or hd.tokenlen > 0) {
                if (hd.tokenlen == 0) return self.sendRetry(&hd, remote, local, data.len * 3);
                if (hd.token[0] != c.NGTCP2_CRYPTO_TOKEN_MAGIC_RETRY2 and hd.dcid.datalen < c.NGTCP2_MIN_INITIAL_DCIDLEN)
                    return self.sendStatelessClose(&hd, remote, local);
                switch (hd.token[0]) {
                    c.NGTCP2_CRYPTO_TOKEN_MAGIC_RETRY2 => {
                        const rv = c.ngtcp2_crypto_verify_retry_token2(&ocid, hd.token, hd.tokenlen, &self.secret, self.secret.len, hd.version, @ptrCast(&remote.storage), remote.len, &hd.dcid, 10 * c.NGTCP2_SECONDS, wallClock(self.io));
                        if (rv == 0) {
                            pocid = &ocid;
                            token_type = c.NGTCP2_TOKEN_TYPE_RETRY;
                        } else if (rv == c.NGTCP2_CRYPTO_ERR_VERIFY_TOKEN or self.options.validate_address) {
                            return self.sendStatelessClose(&hd, remote, local);
                        } else {
                            hd.token = null;
                            hd.tokenlen = 0;
                        }
                    },
                    c.NGTCP2_CRYPTO_TOKEN_MAGIC_REGULAR => {
                        if (c.ngtcp2_crypto_verify_regular_token(hd.token, hd.tokenlen, &self.secret, self.secret.len, @ptrCast(&remote.storage), remote.len, 3600 * c.NGTCP2_SECONDS, wallClock(self.io)) == 0) {
                            token_type = c.NGTCP2_TOKEN_TYPE_NEW_TOKEN;
                        } else if (self.options.validate_address) {
                            return self.sendRetry(&hd, remote, local, data.len * 3);
                        } else {
                            hd.token = null;
                            hd.tokenlen = 0;
                        }
                    },
                    else => {
                        if (self.options.validate_address) return self.sendRetry(&hd, remote, local, data.len * 3);
                        hd.token = null;
                        hd.tokenlen = 0;
                    },
                }
            }

            const conn = Conn.create(self, remote, local, &hd, pocid, token_type) catch |err| {
                log.debug("new connection: {t}", .{err});
                return;
            };
            // From here the connection is reached through the map; the
            // driver holds the first reference.
            conn.lock();
            const pi: c.ngtcp2_pkt_info = .{ .ecn = ecn };
            const rv = ngtcp2.connReadPkt(conn.q, &conn.path(), &pi, data, now(self.io));
            if (rv != 0) {
                conn.unlock();
                if (rv == c.NGTCP2_ERR_RETRY) self.sendRetry(&hd, remote, local, data.len * 3);
                conn.destroy();
                return;
            }
            conn.unlock();

            self.associate(.ofCid(&hd.dcid), conn) catch {
                conn.destroy();
                return;
            };
            var scids: [8]c.ngtcp2_cid = undefined;
            const n = c.ngtcp2_conn_get_scid2(conn.q, null);
            _ = c.ngtcp2_conn_get_scid2(conn.q, &scids);
            for (scids[0..@min(n, scids.len)]) |*cid| self.associate(.ofCid(cid), conn) catch {};

            placement.concurrent(&self.group, self.io, .local, Conn.drive, .{conn}) catch {
                conn.forget();
                conn.destroy();
                return;
            };
            _ = self.stats.accepted.fetchAdd(1, .monotonic);
        }

        fn sendVersionNegotiation(self: *Self, to: std.Io.net.IpAddress, from: ?std.Io.net.IpAddress, vc: *const c.ngtcp2_version_cid) void {
            var buf: [c.NGTCP2_MAX_UDP_PAYLOAD_SIZE]u8 = undefined;
            var unused: [1]u8 = undefined;
            self.io.random(&unused);
            // A reserved version (RFC 9000 §15) first, as greasing.
            const versions = [_]u32{ (vc.version & 0xf0f0f0f0) | 0x0a0a0a0a, c.NGTCP2_PROTO_VER_V2, c.NGTCP2_PROTO_VER_V1 };
            const n = c.ngtcp2_pkt_write_version_negotiation(&buf, buf.len, unused[0], vc.scid, vc.scidlen, vc.dcid, vc.dcidlen, &versions, versions.len);
            if (n > 0) self.send(to, from, buf[0..@intCast(n)]);
        }

        fn sendRetry(self: *Self, chd: *const c.ngtcp2_pkt_hd, remote_in: Addr, from: ?std.Io.net.IpAddress, max_len: usize) void {
            var remote = remote_in;
            var scid: c.ngtcp2_cid = undefined;
            scid.datalen = scid_len;
            // Ours, so the Initial that answers it comes back here.
            self.newCid(scid.data[0..scid_len]);
            var token: [c.NGTCP2_CRYPTO_MAX_RETRY_TOKENLEN2]u8 = undefined;
            const token_len = c.ngtcp2_crypto_generate_retry_token2(&token, &self.secret, self.secret.len, chd.version, @ptrCast(&remote.storage), remote.len, &scid, &chd.dcid, wallClock(self.io));
            if (token_len < 0) return;
            var buf: [c.NGTCP2_MAX_UDP_PAYLOAD_SIZE]u8 = undefined;
            const n = c.ngtcp2_crypto_write_retry(&buf, @min(buf.len, max_len), chd.version, &chd.scid, &scid, &chd.dcid, &token, @intCast(token_len));
            if (n > 0) self.send(remote.ip(), from, buf[0..@intCast(n)]);
        }

        fn sendStatelessClose(self: *Self, chd: *const c.ngtcp2_pkt_hd, remote: Addr, from: ?std.Io.net.IpAddress) void {
            var buf: [c.NGTCP2_MAX_UDP_PAYLOAD_SIZE]u8 = undefined;
            const n = c.ngtcp2_crypto_write_connection_close(&buf, buf.len, chd.version, &chd.scid, &chd.dcid, c.NGTCP2_INVALID_TOKEN, null, 0);
            if (n > 0) self.send(remote.ip(), from, buf[0..@intCast(n)]);
        }

        /// At most `NGTCP2_STATELESS_RESET_BURST` a second, so the endpoint
        /// cannot be made to amplify a flood of garbage.
        fn sendStatelessReset(self: *Self, to: std.Io.net.IpAddress, from: ?std.Io.net.IpAddress, pkt_len: usize, dcid: []const u8) void {
            const t = now(self.io);
            if (t -% self.reset_window >= std.time.ns_per_s) {
                self.reset_window = t;
                self.reset_budget = stateless_reset_burst;
            }
            if (self.reset_budget == 0) return;
            self.reset_budget -= 1;

            var cid: c.ngtcp2_cid = undefined;
            c.ngtcp2_cid_init(&cid, dcid.ptr, dcid.len);
            var token: c.ngtcp2_stateless_reset_token = undefined;
            if (c.ngtcp2_crypto_generate_stateless_reset_token(&token.data, &self.secret, self.secret.len, &cid) != 0) return;
            const max_rand = c.NGTCP2_MAX_CIDLEN + 22 - c.NGTCP2_STATELESS_RESET_TOKENLEN;
            // Smaller than the packet that caused it (RFC 9000 §10.3).
            const rand_len: usize = if (pkt_len <= 43) pkt_len - c.NGTCP2_STATELESS_RESET_TOKENLEN - 1 else max_rand;
            var rand: [max_rand]u8 = undefined;
            self.io.random(rand[0..rand_len]);
            var buf: [c.NGTCP2_MAX_UDP_PAYLOAD_SIZE]u8 = undefined;
            const n = c.ngtcp2_pkt_write_stateless_reset2(&buf, buf.len, &token, &rand, rand_len);
            if (n > 0) self.send(to, from, buf[0..@intCast(n)]);
        }

        // -- A connection ----------------------------------------------------

        const Conn = struct {
            ep: *Self,
            q: *c.ngtcp2_conn,
            h3: ?*h.nghttp3_conn = null,
            ssl: *c.SSL,
            conn_ref: c.ngtcp2_crypto_conn_ref,
            scid: c.ngtcp2_cid,
            local: Addr,
            remote: Addr,
            mutex: std.Io.Mutex = .init,
            /// Bumped to wake the driver (and stream tasks waiting on it).
            gen: std.atomic.Value(u32) = .init(0),
            refs: std.atomic.Value(u32) = .init(1),
            state: State = .open,
            last_error: c.ngtcp2_ccerr = undefined,
            /// The CONNECTION_CLOSE to repeat in the closing period.
            close_pkt: []u8 = &.{},
            close_pkts_seen: u32 = 0,
            close_next_reply: u32 = 1,
            /// When the closing or draining period ends.
            period_end: u64 = 0,
            streams: std.AutoHashMapUnmanaged(i64, *Stream) = .empty,
            /// The request tasks.
            group: std.Io.Group = .init,
            tx: []u8,
            drain: enum { none, notice, final } = .none,
            /// The connection speaks "hq-interop", not HTTP/3.
            hq: bool = false,
            hq_streams: std.AutoArrayHashMapUnmanaged(i64, *HqStream) = .empty,
            drain_at: u64 = 0,
            /// WebTransport's streams, sessions and datagrams, when the
            /// endpoint speaks it.
            wt: ?*webtransport.Core = null,

            const State = enum { open, closing, draining, closed };

            fn create(ep: *Self, remote: Addr, local: ?std.Io.net.IpAddress, hd: *const c.ngtcp2_pkt_hd, ocid: ?*const c.ngtcp2_cid, token_type: c.ngtcp2_token_type) !*Conn {
                const gpa = ep.gpa;
                const conn = try gpa.create(Conn);
                errdefer gpa.destroy(conn);
                const tx = try gpa.alloc(u8, burst * c.NGTCP2_MAX_UDP_PAYLOAD_SIZE);
                errdefer gpa.free(tx);
                conn.* = .{
                    .ep = ep,
                    .q = undefined,
                    .ssl = undefined,
                    .conn_ref = .{ .get_conn = getConn, .user_data = conn },
                    .scid = undefined,
                    .local = if (local) |l| .from(l) else ep.local,
                    .remote = remote,
                    .tx = tx,
                };
                c.ngtcp2_ccerr_default(&conn.last_error);
                conn.scid.datalen = scid_len;
                ep.newCid(conn.scid.data[0..scid_len]);

                var settings: ngtcp2.Settings = undefined;
                ngtcp2.settingsDefault(&settings);
                settings.initial_ts = now(ep.io);
                settings.token = hd.token;
                settings.tokenlen = hd.tokenlen;
                settings.token_type = token_type;
                settings.rand_ctx = .{ .native_handle = conn };
                settings.max_window = 6 * ep.options.max_data;
                // QUIC v2 (RFC 9369) when the client offers it, through
                // compatible version negotiation; v1 otherwise.
                settings.preferred_versions = &preferred_versions;
                settings.preferred_versionslen = preferred_versions.len;
                settings.max_stream_window = 6 * ep.options.max_stream_data;
                // qlog stays off: both of ngtcp2's high-severity
                // advisories were in its qlog code.
                settings.qlog_write = null;
                var initial_pkt_num: [4]u8 = undefined;
                ep.io.random(&initial_pkt_num);
                settings.initial_pkt_num = std.mem.readInt(u32, &initial_pkt_num, .little) & 0x7fffffff;

                var params = transportParams(&ep.options);
                params.stateless_reset_token_present = 1;
                params.active_connection_id_limit = 7;
                params.grease_quic_bit = 1;
                if (ocid) |o| {
                    params.original_dcid = o.*;
                    params.retry_scid = hd.dcid;
                    params.retry_scid_present = 1;
                } else {
                    params.original_dcid = hd.dcid;
                }
                params.original_dcid_present = 1;
                if (c.ngtcp2_crypto_generate_stateless_reset_token(&params.stateless_reset_token, &ep.secret, ep.secret.len, &conn.scid) != 0)
                    return error.QuicSetupFailed;

                var p = conn.path();
                var q: ?*c.ngtcp2_conn = null;
                if (ngtcp2.connServerNew(&q, &hd.scid, &conn.scid, &p, hd.version, &callbacks, &settings, &params, null, conn) != 0)
                    return error.QuicSetupFailed;
                conn.q = q.?;
                errdefer c.ngtcp2_conn_del(conn.q);
                conn.ssl = try ep.newTlsSession(&conn.conn_ref);
                errdefer c.SSL_free(conn.ssl);
                if (ep.options.early_data) {
                    var buf: [early_context_max]u8 = undefined;
                    try quic_tls.setEarlyDataContext(conn.ssl, try earlyDataContext(conn.q, http3Settings(&ep.options), ep.options.webtransport, &buf));
                }
                c.ngtcp2_conn_set_tls_native_handle(conn.q, conn.ssl);
                return conn;
            }

            fn getConn(conn_ref: [*c]c.ngtcp2_crypto_conn_ref) callconv(.c) ?*c.ngtcp2_conn {
                const conn: *Conn = @ptrCast(@alignCast(conn_ref.*.user_data));
                return conn.q;
            }

            /// Frees everything. Nothing may reach the connection anymore.
            fn destroy(conn: *Conn) void {
                const gpa = conn.ep.gpa;
                for (conn.hq_streams.values()) |hs| hs.free(gpa);
                conn.hq_streams.deinit(gpa);
                var it = conn.streams.valueIterator();
                while (it.next()) |s| s.*.free();
                conn.streams.deinit(gpa);
                if (conn.wt) |w| w.destroy();
                if (conn.h3) |hc| h.nghttp3_conn_del(hc);
                c.ngtcp2_conn_del(conn.q);
                c.SSL_free(conn.ssl);
                if (conn.close_pkt.len > 0) gpa.free(conn.close_pkt);
                gpa.free(conn.tx);
                gpa.destroy(conn);
            }

            fn ref(conn: *Conn) void {
                _ = conn.refs.fetchAdd(1, .monotonic);
            }

            fn unref(conn: *Conn) void {
                if (conn.refs.fetchSub(1, .acq_rel) == 1) conn.destroy();
            }

            fn lock(conn: *Conn) void {
                conn.mutex.lockUncancelable(conn.ep.io);
            }

            fn unlock(conn: *Conn) void {
                conn.mutex.unlock(conn.ep.io);
            }

            fn kick(conn: *Conn) void {
                _ = conn.gen.fetchAdd(1, .release);
                conn.ep.io.futexWake(u32, &conn.gen.raw, std.math.maxInt(u32));
            }

            /// How WebTransport's sessions and streams reach the
            /// connection.
            fn wtHost(conn: *Conn) webtransport.Host {
                const S = struct {
                    fn of(ctx: *anyopaque) *Conn {
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
                return .{ .ctx = conn, .gen = &conn.gen, .lock_fn = S.lock, .unlock_fn = S.unlock, .kick_fn = S.kick };
            }

            fn path(conn: *Conn) c.ngtcp2_path {
                return .{ .local = conn.local.ngtcp2Addr(), .remote = conn.remote.ngtcp2Addr(), .user_data = null };
            }

            /// Takes the connection's IDs out of the endpoint's map.
            fn forget(conn: *Conn) void {
                const ep = conn.ep;
                ep.dissociate(.ofCid(c.ngtcp2_conn_get_client_initial_dcid2(conn.q)));
                var scids: [16]c.ngtcp2_cid = undefined;
                const n = c.ngtcp2_conn_get_scid2(conn.q, null);
                if (n <= scids.len) {
                    _ = c.ngtcp2_conn_get_scid2(conn.q, &scids);
                    for (scids[0..n]) |*cid| ep.dissociate(.ofCid(cid));
                }
                // And any left over (a CID retired while we were not looking).
                ep.map_mutex.lockUncancelable(ep.io);
                defer ep.map_mutex.unlock(ep.io);
                var stale: std.ArrayList(CidKey) = .empty;
                defer stale.deinit(ep.gpa);
                var it = ep.conns.iterator();
                while (it.next()) |e| if (e.value_ptr.* == conn) stale.append(ep.gpa, e.key_ptr.*) catch {};
                for (stale.items) |k| _ = ep.conns.remove(k);
            }

            // -- In: a packet from the endpoint task --------------------

            fn onPacket(conn: *Conn, remote: Addr, local: ?std.Io.net.IpAddress, ecn: u8, data: []u8) void {
                conn.lock();
                defer conn.unlock();
                switch (conn.state) {
                    .open => {},
                    .closing => {
                        // Answer with the CONNECTION_CLOSE again, less and
                        // less often (RFC 9000 §10.2.1).
                        conn.close_pkts_seen += 1;
                        if (conn.close_pkts_seen >= conn.close_next_reply and conn.close_pkt.len > 0) {
                            conn.close_next_reply *= 2;
                            // Back the way the packet came: the client may
                            // have moved since the connection began.
                            conn.ep.udp.send(conn.ep.io, remote.ip(), local, 0, conn.close_pkt, conn.close_pkt.len);
                        }
                        return;
                    },
                    .draining, .closed => return,
                }
                var r = remote;
                var l: Addr = if (local) |a| .from(a) else conn.local;
                var p: c.ngtcp2_path = .{ .local = l.ngtcp2Addr(), .remote = r.ngtcp2Addr(), .user_data = null };
                const pi: c.ngtcp2_pkt_info = .{ .ecn = ecn };
                const rv = ngtcp2.connReadPkt(conn.q, &p, &pi, data, now(conn.ep.io));
                if (rv != 0) {
                    switch (rv) {
                        c.NGTCP2_ERR_DRAINING => {
                            conn.enterPeriod(.draining);
                            conn.kick();
                            return;
                        },
                        c.NGTCP2_ERR_DROP_CONN => {
                            conn.close(.closed);
                            return;
                        },
                        c.NGTCP2_ERR_CRYPTO => if (conn.last_error.error_code == 0)
                            c.ngtcp2_ccerr_set_tls_alert(&conn.last_error, c.ngtcp2_conn_get_tls_alert2(conn.q), null, 0),
                        else => if (conn.last_error.error_code == 0)
                            c.ngtcp2_ccerr_set_liberr(&conn.last_error, rv, null, 0),
                    }
                    log.debug("read_pkt: {s}", .{c.ngtcp2_strerror(rv)});
                    conn.fail();
                }
                conn.kick();
            }

            // -- Out: the driver task -----------------------------------

            fn drive(conn: *Conn) std.Io.Cancelable!void {
                const io = conn.ep.io;
                defer conn.finish();
                while (true) {
                    const gen = conn.gen.load(.acquire);
                    conn.flush();

                    conn.lock();
                    const state = conn.state;
                    const t = now(io);
                    var deadline: u64 = switch (state) {
                        .open => c.ngtcp2_conn_get_expiry2(conn.q),
                        .closing, .draining => conn.period_end,
                        .closed => 0,
                    };
                    if (state == .open and conn.drain != .none) {
                        deadline = @min(deadline, conn.drainStep(t));
                        // The drain may have closed the connection, its
                        // CONNECTION_CLOSE written at a later time than
                        // `t`. ngtcp2 must never see time go back (it
                        // asserts so, and its timers assume it), so `t` is
                        // done with: start over.
                        if (conn.state != .open) {
                            conn.unlock();
                            continue;
                        }
                    }
                    if (state == .closed) {
                        conn.unlock();
                        return;
                    }
                    if (deadline <= t) {
                        switch (state) {
                            .open => if (deadline == c.ngtcp2_conn_get_expiry2(conn.q)) conn.expire(t),
                            else => conn.close(.closed),
                        }
                        conn.unlock();
                        continue;
                    }
                    conn.unlock();
                    const wait: std.Io.Timeout = if (deadline == std.math.maxInt(u64)) .none else .{ .duration = .{
                        .raw = .fromNanoseconds(@intCast(deadline - t)),
                        .clock = .awake,
                    } };
                    io.futexWaitTimeout(u32, &conn.gen.raw, gen, wait) catch {
                        // Canceled: the endpoint is shutting down.
                        conn.lock();
                        conn.abortLocked();
                        conn.unlock();
                        return;
                    };
                }
            }

            /// Writes and sends whatever the connection has to send.
            fn flush(conn: *Conn) void {
                const ep = conn.ep;
                while (true) {
                    conn.lock();
                    if (conn.state != .open) {
                        conn.unlock();
                        return;
                    }
                    var ps: c.ngtcp2_path_storage = undefined;
                    c.ngtcp2_path_storage_zero(&ps);
                    var pi: c.ngtcp2_pkt_info = undefined;
                    var gso: usize = 0;
                    const ts = now(ep.io);
                    const quantum = c.ngtcp2_conn_get_send_quantum(conn.q);
                    const len = @min(conn.tx.len, @max(quantum, c.NGTCP2_MAX_UDP_PAYLOAD_SIZE));
                    const n = ngtcp2.connWriteAggregatePkt2(conn.q, &ps.path, &pi, conn.tx[0..len], &gso, writePkt, burst, ts);
                    if (n < 0) {
                        if (conn.last_error.error_code == 0)
                            c.ngtcp2_ccerr_set_liberr(&conn.last_error, @intCast(n), null, 0);
                        conn.fail();
                        conn.unlock();
                        return;
                    }
                    c.ngtcp2_conn_update_pkt_tx_time(conn.q, ts);
                    conn.unlock();
                    if (n == 0) return;
                    const to = Addr.fromNgtcp2(ps.path.remote).ip();
                    const from = Addr.fromNgtcp2(ps.path.local).ip();
                    ep.udp.send(ep.io, to, from, pi.ecn, conn.tx[0..@intCast(n)], gso);
                }
            }

            /// Timers: loss detection, ACK delay, idle timeout. Locked.
            fn expire(conn: *Conn, t: u64) void {
                const rv = c.ngtcp2_conn_handle_expiry(conn.q, t);
                if (rv == 0) return;
                c.ngtcp2_ccerr_set_liberr(&conn.last_error, rv, null, 0);
                conn.fail();
            }

            /// Drains in two steps (RFC 9114 §5.2): a GOAWAY that still
            /// takes the requests in flight, then the final one a few RTTs
            /// later. Then, once nghttp3 has no streams left, close.
            /// Returns when to look again. Locked.
            fn drainStep(conn: *Conn, t: u64) u64 {
                const hc = conn.h3 orelse {
                    conn.closeGracefully();
                    return t;
                };
                switch (conn.drain) {
                    .none => return std.math.maxInt(u64),
                    .notice => {
                        if (t < conn.drain_at) return conn.drain_at;
                        _ = h.nghttp3_conn_shutdown(hc);
                        conn.drain = .final;
                        conn.kick();
                        return t + 50 * std.time.ns_per_ms;
                    },
                    .final => {
                        if (h.nghttp3_conn_is_drained(hc) != 0) {
                            conn.closeGracefully();
                            return t;
                        }
                        return t + 50 * std.time.ns_per_ms;
                    },
                }
            }

            fn beginDrain(conn: *Conn) void {
                conn.lock();
                defer conn.unlock();
                if (conn.state != .open or conn.drain != .none) return;
                if (conn.h3) |hc| _ = h.nghttp3_conn_submit_shutdown_notice(hc);
                conn.drain = .notice;
                conn.drain_at = now(conn.ep.io) + 3 * c.ngtcp2_conn_get_pto2(conn.q);
                conn.kick();
            }

            /// The final GOAWAY, sent, then CONNECTION_CLOSE: for a hand-over,
            /// which cannot wait for requests to finish.
            fn handOver(conn: *Conn) void {
                conn.lock();
                if (conn.state == .open) if (conn.h3) |hc| {
                    _ = h.nghttp3_conn_shutdown(hc);
                };
                conn.unlock();
                conn.flush();
                conn.abort();
            }

            /// CONNECTION_CLOSE with H3_NO_ERROR. Locked.
            fn closeGracefully(conn: *Conn) void {
                c.ngtcp2_ccerr_set_application_error(&conn.last_error, h.NGHTTP3_H3_NO_ERROR, null, 0);
                conn.fail();
            }

            /// Closes now, for a shutdown that cannot wait any longer.
            fn abort(conn: *Conn) void {
                conn.lock();
                defer conn.unlock();
                conn.abortLocked();
            }

            fn abortLocked(conn: *Conn) void {
                if (conn.state == .open) {
                    c.ngtcp2_ccerr_set_application_error(&conn.last_error, h.NGHTTP3_H3_NO_ERROR, null, 0);
                    conn.fail();
                }
                conn.close(.closed);
            }

            /// The connection failed or ends: send CONNECTION_CLOSE and
            /// enter the closing period, or go quietly for an idle timeout.
            /// Locked.
            fn fail(conn: *Conn) void {
                if (conn.state != .open) return;
                if (conn.last_error.type == c.NGTCP2_CCERR_TYPE_IDLE_CLOSE) return conn.close(.closed);
                if (c.ngtcp2_conn_in_draining_period2(conn.q) != 0) return conn.enterPeriod(.draining);
                var ps: c.ngtcp2_path_storage = undefined;
                c.ngtcp2_path_storage_zero(&ps);
                var pi: c.ngtcp2_pkt_info = undefined;
                var buf: [c.NGTCP2_MAX_UDP_PAYLOAD_SIZE]u8 = undefined;
                const n = ngtcp2.connWriteConnectionClose(conn.q, &ps.path, &pi, &buf, &conn.last_error, now(conn.ep.io));
                conn.enterPeriod(.closing);
                if (n > 0) {
                    conn.close_pkt = conn.ep.gpa.dupe(u8, buf[0..@intCast(n)]) catch &.{};
                    // On the path in use now, which a migration may have
                    // changed since the connection began.
                    const to = Addr.fromNgtcp2(ps.path.remote).ip();
                    const from = Addr.fromNgtcp2(ps.path.local).ip();
                    conn.ep.udp.send(conn.ep.io, to, from, 0, buf[0..@intCast(n)], @intCast(n));
                }
            }

            /// The closing or draining period: three PTOs (RFC 9000 §10.2).
            /// Locked.
            fn enterPeriod(conn: *Conn, state: State) void {
                conn.state = state;
                conn.period_end = now(conn.ep.io) + 3 * c.ngtcp2_conn_get_pto2(conn.q);
                conn.wakeStreams();
                conn.kick();
            }

            /// Locked.
            fn close(conn: *Conn, state: State) void {
                conn.state = state;
                conn.wakeStreams();
                conn.kick();
            }

            /// Every stream's handler sees the connection gone.
            fn wakeStreams(conn: *Conn) void {
                var it = conn.streams.valueIterator();
                while (it.next()) |s| s.*.reset = true;
                if (conn.wt) |w| w.connectionClosed();
            }

            /// The driver's end: requests finish, the IDs go, the driver's
            /// reference goes.
            fn finish(conn: *Conn) void {
                const io = conn.ep.io;
                const protection = io.swapCancelProtection(.blocked);
                defer _ = io.swapCancelProtection(protection);
                conn.lock();
                conn.close(.closed);
                conn.unlock();
                conn.group.cancel(io);
                conn.forget();
                conn.unref();
            }

            // -- The HTTP/3 layer ---------------------------------------

            /// Once 1-RTT keys are there: the control and QPACK streams.
            /// Locked (inside an ngtcp2 callback).
            fn setupHttp3(conn: *Conn) !void {
                if (conn.h3 != null) return;
                if (c.ngtcp2_conn_get_streams_uni_left2(conn.q) < 3) return error.Http3SetupFailed;
                const options = &conn.ep.options;
                const settings = http3Settings(options);
                var hc: ?*h.nghttp3_conn = null;
                if (nghttp3.connServerNew(&hc, &h3_callbacks, &settings, h.nghttp3_mem_default(), conn) != 0) return error.Http3SetupFailed;
                errdefer h.nghttp3_conn_del(hc);
                if (options.webtransport) {
                    // Chrome and Firefox (draft-02), and Safari (draft-07
                    // on), through the nghttp3 fork's extra SETTINGS.
                    if (h.nghttp3_conn_add_extra_setting(hc, webtransport.setting_enable_webtransport, 1) != 0 or
                        h.nghttp3_conn_add_extra_setting(hc, webtransport.setting_max_sessions, 1) != 0)
                        return error.Http3SetupFailed;
                    conn.wt = webtransport.Core.create(conn.ep.gpa, conn.ep.io, conn.q, conn.wtHost(), true, .{}) catch return error.Http3SetupFailed;
                }
                errdefer if (conn.wt) |w| {
                    w.destroy();
                    conn.wt = null;
                };
                const params = c.ngtcp2_conn_get_local_transport_params2(conn.q);
                h.nghttp3_conn_set_max_client_streams_bidi(hc, params.*.initial_max_streams_bidi);
                var ctrl: i64 = 0;
                var enc: i64 = 0;
                var dec: i64 = 0;
                if (c.ngtcp2_conn_open_uni_stream(conn.q, &ctrl, null) != 0) return error.Http3SetupFailed;
                if (h.nghttp3_conn_bind_control_stream(hc, ctrl) != 0) return error.Http3SetupFailed;
                if (c.ngtcp2_conn_open_uni_stream(conn.q, &enc, null) != 0) return error.Http3SetupFailed;
                if (c.ngtcp2_conn_open_uni_stream(conn.q, &dec, null) != 0) return error.Http3SetupFailed;
                if (h.nghttp3_conn_bind_qpack_streams(hc, enc, dec) != 0) return error.Http3SetupFailed;
                conn.h3 = hc;
            }

            fn side(conn: *Conn) bridge.Side {
                return .{ .q = conn.q, .h3 = conn.h3, .last_error = &conn.last_error, .wt = conn.wt };
            }

            fn consume(conn: *Conn, stream_id: i64, n: u64) void {
                bridge.consume(conn.q, stream_id, n);
            }

            /// The client's Finished has arrived: what it sent can no longer
            /// be a replay. Locked.
            fn handshakeDone(conn: *Conn) bool {
                return c.ngtcp2_conn_get_handshake_completed2(conn.q) != 0;
            }

            // -- hq-interop (HTTP/0.9), for the QUIC interop runner -------

            /// A request line in; once complete, the file it names becomes
            /// the response. Locked (inside an ngtcp2 callback).
            fn hqRecv(conn: *Conn, flags: u32, stream_id: i64, data: []const u8) c_int {
                const gpa = conn.ep.gpa;
                bridge.consume(conn.q, stream_id, data.len);
                const hs = conn.hq_streams.get(stream_id) orelse return 0;
                if (hs.ready) return 0;
                hs.request.appendSlice(gpa, data) catch return c.NGTCP2_ERR_CALLBACK_FAILURE;
                const fin = flags & c.NGTCP2_STREAM_DATA_FLAG_FIN != 0;
                const line_end = std.mem.indexOfScalar(u8, hs.request.items, '\n');
                if (line_end == null and !fin) {
                    if (hs.request.items.len > 4096) _ = c.ngtcp2_conn_shutdown_stream(conn.q, 0, stream_id, 0);
                    return 0;
                }
                const line = std.mem.trim(u8, hs.request.items[0 .. line_end orelse hs.request.items.len], " \r\n");
                hs.response = conn.hqLoad(line) catch |err| blk: {
                    log.debug("hq-interop {s}: {t}", .{ line, err });
                    break :blk &.{};
                };
                hs.ready = true;
                conn.kick();
                return 0;
            }

            /// "GET /path": the file at path under the root, or an error.
            fn hqLoad(conn: *Conn, line: []const u8) ![]u8 {
                const root = conn.ep.options.hq_interop_root.?;
                if (!std.mem.startsWith(u8, line, "GET /")) return error.BadRequest;
                const file = line["GET /".len..];
                var parts = std.mem.splitScalar(u8, file, '/');
                while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return error.BadPath;
                const io = conn.ep.io;
                var dir = try std.Io.Dir.cwd().openDir(io, root, .{});
                defer dir.close(io);
                return dir.readFileAlloc(io, file, conn.ep.gpa, .limited(1 << 30));
            }

            /// Like `bridge.writePacket`, with the hq streams' responses for
            /// data. Locked (inside `flush`).
            fn hqWritePacket(conn: *Conn, p: [*c]c.ngtcp2_path, pi: [*c]c.ngtcp2_pkt_info, dest: [*c]u8, dest_len: usize, ts: u64) c.ngtcp2_ssize {
                var next: usize = 0;
                while (true) {
                    var picked: ?*HqStream = null;
                    var stream_id: i64 = -1;
                    while (next < conn.hq_streams.count()) : (next += 1) {
                        const hs = conn.hq_streams.values()[next];
                        if (hs.ready and !hs.fin_sent) {
                            picked = hs;
                            stream_id = conn.hq_streams.keys()[next];
                            break;
                        }
                    }
                    var vec: [1]c.ngtcp2_vec = undefined;
                    var datav: []const c.ngtcp2_vec = &.{};
                    var flags: u32 = c.NGTCP2_WRITE_STREAM_FLAG_MORE | c.NGTCP2_WRITE_STREAM_FLAG_PADDING;
                    if (picked) |hs| {
                        const rest = hs.response[hs.sent..];
                        vec[0] = .{ .base = @constCast(rest.ptr), .len = rest.len };
                        datav = &vec;
                        flags |= c.NGTCP2_WRITE_STREAM_FLAG_FIN;
                    }
                    var data_len: c.ngtcp2_ssize = -1;
                    const n = ngtcp2.connWritevStream(conn.q, p, pi, dest[0..dest_len], &data_len, flags, stream_id, datav, ts);
                    if (picked) |hs| if (data_len >= 0) {
                        hs.sent += @intCast(data_len);
                        if (hs.sent == hs.response.len) hs.fin_sent = true;
                    };
                    if (n < 0) switch (n) {
                        // This one waits for credit or is gone; try the next.
                        c.NGTCP2_ERR_STREAM_DATA_BLOCKED, c.NGTCP2_ERR_STREAM_SHUT_WR => {
                            next += 1;
                            continue;
                        },
                        c.NGTCP2_ERR_WRITE_MORE => continue,
                        else => {
                            c.ngtcp2_ccerr_set_liberr(&conn.last_error, @intCast(n), null, 0);
                            return c.NGTCP2_ERR_CALLBACK_FAILURE;
                        },
                    };
                    return n;
                }
            }

            fn streamOf(conn: *Conn, stream_id: i64) ?*Stream {
                return conn.streams.get(stream_id);
            }

            /// A request's head is complete: give it a task. Locked.
            fn startStream(conn: *Conn, stream: *Stream) void {
                stream.started = true;
                stream.refs.handler = true;
                placement.concurrent(&conn.group, conn.ep.io, .local, Stream.run, .{stream}) catch {
                    log.err("HTTP/3: no task for stream {d}", .{stream.id});
                    stream.refs.handler = false;
                    _ = c.ngtcp2_conn_shutdown_stream(conn.q, 0, stream.id, h.NGHTTP3_H3_REQUEST_REJECTED);
                    conn.kick();
                };
            }
        };

        /// An hq-interop request: its line in, then the file out.
        const HqStream = struct {
            request: std.ArrayList(u8) = .empty,
            /// The file; stays until the stream closes (ngtcp2 resends
            /// from it until the peer acknowledges).
            response: []u8 = &.{},
            sent: usize = 0,
            ready: bool = false,
            fin_sent: bool = false,

            fn free(hs: *HqStream, gpa: std.mem.Allocator) void {
                hs.request.deinit(gpa);
                if (hs.response.len > 0) gpa.free(hs.response);
                gpa.destroy(hs);
            }
        };

        // -- A request -------------------------------------------------------

        const Field = struct { name: []const u8, value: []const u8 };

        const Stream = struct {
            conn: *Conn,
            id: i64,
            arena: std.heap.ArenaAllocator,
            method: []const u8 = "",
            path: []const u8 = "",
            authority: []const u8 = "",
            headers: std.ArrayList(Field) = .empty,
            /// Request body bytes not yet read by the handler.
            body: std.ArrayList(u8) = .empty,
            body_start: usize = 0,
            body_done: bool = false,
            /// The peer reset the stream, or the connection is gone.
            reset: bool = false,
            started: bool = false,
            /// The request's head came in 0-RTT, before the handshake
            /// completed.
            early: bool = false,
            /// `:protocol`, on an extended CONNECT (RFC 9220).
            protocol: []const u8 = "",
            /// Who still holds the stream.
            refs: struct { quic: bool = true, handler: bool = false } = .{},

            // The response.
            response_nv: []h.nghttp3_nv = &.{},
            trailer_nv: []h.nghttp3_nv = &.{},
            submitted: bool = false,
            ended: bool = false,
            /// nghttp3 asked for data and got none: resume it on the next.
            deferred: bool = false,
            /// The response body until the peer acknowledges it.
            out: bridge.Ring = .{},

            fn create(conn: *Conn, id: i64) !*Stream {
                const gpa = conn.ep.gpa;
                const s = try gpa.create(Stream);
                s.* = .{ .conn = conn, .id = id, .arena = .init(gpa) };
                return s;
            }

            fn free(s: *Stream) void {
                const gpa = s.conn.ep.gpa;
                s.body.deinit(gpa);
                s.out.deinit(gpa);
                s.arena.deinit();
                gpa.destroy(s);
            }

            /// Drops one holder; the last frees the stream. Locked.
            fn release(s: *Stream, who: enum { quic, handler }) void {
                switch (who) {
                    .quic => s.refs.quic = false,
                    .handler => s.refs.handler = false,
                }
                if (s.refs.quic or s.refs.handler) return;
                _ = s.conn.streams.remove(s.id);
                s.free();
            }

            fn run(s: *Stream) std.Io.Cancelable!void {
                const conn = s.conn;
                defer {
                    conn.lock();
                    // A handler done before the request body is: the rest
                    // is not wanted (RFC 9114 §4.1).
                    if (!s.body_done and !s.reset)
                        _ = c.ngtcp2_conn_shutdown_stream_read(conn.q, 0, s.id, h.NGHTTP3_H3_NO_ERROR);
                    s.release(.handler);
                    conn.unlock();
                    conn.kick();
                }
                s.serve() catch |err| {
                    if (err == error.Canceled) {
                        s.resetStream(h.NGHTTP3_H3_REQUEST_CANCELLED);
                        return error.Canceled;
                    }
                    // `Response.abort`: the reset is the abort.
                    if (err == error.ResponseAborted) {
                        log.debug("HTTP/3 stream {d}: response aborted", .{s.id});
                        s.resetStream(h.NGHTTP3_H3_REQUEST_CANCELLED);
                        return;
                    }
                    conn.lock();
                    const gone = s.reset;
                    conn.unlock();
                    if (gone) {
                        log.debug("HTTP/3 stream {d} reset: {t}", .{ s.id, err });
                    } else {
                        log.err("HTTP/3 stream {d}: {t}", .{ s.id, err });
                        s.resetStream(h.NGHTTP3_H3_INTERNAL_ERROR);
                    }
                };
            }

            fn setTimeout(context: *anyopaque, _: std.Io, timeout: std.Io.Timeout) void {
                const timer: *zio.AutoCancel = @ptrCast(@alignCast(context));
                timer.setClock(.fromStd(timeout), .fromStdTimeout(timeout));
            }

            fn resetStream(s: *Stream, code: u64) void {
                const conn = s.conn;
                conn.lock();
                defer conn.unlock();
                if (s.reset) return;
                s.reset = true;
                _ = c.ngtcp2_conn_shutdown_stream(conn.q, 0, s.id, code);
                conn.kick();
            }

            fn serve(s: *Stream) !void {
                const conn = s.conn;
                const ep = conn.ep;
                const server = ep.http;
                const arena = s.arena.allocator();
                const io = ep.io;

                // `timeout.request` bounds the whole exchange, as on HTTP/1.1
                // and HTTP/2; a handler may move it (`Request.setTimeout`).
                // Running out cancels the task, which resets the stream.
                var timer: zio.AutoCancel = .init;
                defer timer.clear();
                if (server.config.timeout.request) |d| setTimeout(&timer, io, .{ .duration = .{ .raw = d, .clock = .awake } });

                var request: dusty.Request = .{
                    .arena = arena,
                    .io = io,
                    .parser = undefined,
                    .transport = undefined,
                    .config = server.config.request,
                    .listener = &ep.listener,
                    .secure = true,
                    .version_major = 3,
                    .version_minor = 0,
                    .drain = &server.draining,
                    .drain_hooks = &server.drain_hooks,
                    ._timeout_context = &timer,
                    ._set_timeout = setTimeout,
                };
                var body_reader: BodyReader = .init(s);
                request.body_source = .{ .reader = &body_reader.interface, .err = BodyReader.errorOf };

                var sink_state: StreamSink = .{ .stream = s };
                var response = try dusty.Response.initSink(arena, io, sink_state.sink(), server.config.response.max_header_count);
                server.configureResponse(&response);
                defer response.deinit();
                response.request = &request;
                request.response = &response;

                if (s.method.len == 0 or s.path.len == 0) {
                    response.status = .bad_request;
                    return response.write();
                }
                request.method = parseMethod(s.method) orelse {
                    response.status = .not_implemented;
                    return response.write();
                };
                if (request.method == .connect) {
                    // A plain CONNECT (a proxy's tunnel) is not served.
                    if (s.protocol.len == 0) {
                        response.status = .not_implemented;
                        return response.write();
                    }
                    // An extended CONNECT (RFC 9220; nghttp3 has checked
                    // its pseudo-headers) is routed as the GET that the
                    // HTTP/1.1 upgrade it replaces would be, as over
                    // HTTP/2.
                    request.method = .get;
                    request.protocol = s.protocol;
                    // A WebTransport session: `anole.webtransport.accept`
                    // finds the connection's WebTransport here.
                    if (conn.wt) |w| if (isWebTransport(s.protocol))
                        try request.setLocal(webtransport.local_key, webtransport.Connect{ .core = w, .session_id = s.id });
                }
                response.head = request.method == .head;
                request.url = s.path;

                // 0-RTT (RFC 8470 §3): what came in early data may be a
                // replay until the handshake completes, which a replay
                // never does. Safe methods run now and say so with
                // `Early-Data: 1`, as a proxy would; the rest wait.
                conn.lock();
                var early = s.early and !conn.handshakeDone();
                conn.unlock();
                // A WebSocket or WebTransport session (an extended
                // CONNECT, routed as a GET) waits too: what runs on it is
                // anything but a safe request.
                if (early and (!early_data.isSafe(request.method) or request.protocol != null)) {
                    _ = ep.early_held.fetchAdd(1, .monotonic);
                    try s.awaitHandshake();
                    early = false;
                }

                request.headers = dusty.Headers.init(arena, server.config.request.max_header_count) catch return error.OutOfMemory;
                var too_many = false;
                for (s.headers.items) |f| request.headers.put(f.name, f.value) catch {
                    too_many = true;
                    break;
                };
                if (!too_many and request.headers.get("Host") == null and s.authority.len > 0) {
                    request.headers.put("Host", s.authority) catch {
                        too_many = true;
                    };
                }
                if (!too_many and early) {
                    _ = ep.early_served.fetchAdd(1, .monotonic);
                    if (request.headers.get(early_data.header) == null) request.headers.put(early_data.header, "1") catch {
                        too_many = true;
                    };
                }
                if (too_many) {
                    response.status = .request_header_fields_too_large;
                    return response.write();
                }
                request.applyEntityHeaders();
                if (server.config.request.max_content_length) |max| {
                    if (request.content_length) |len| if (len > max) {
                        response.status = .payload_too_large;
                        response.content_type = .text;
                        response.body = "413 Content Too Large\n";
                        return response.write();
                    };
                }
                // Where the client is now: a migration moves it.
                conn.lock();
                const peer = Addr.fromNgtcp2(c.ngtcp2_conn_get_path2(conn.q).*.remote).ip();
                request.peer_certificate = quic_tls.peerCertificate(conn.ssl);
                conn.unlock();
                server.applyForwardedFrom(&request, peer);
                // The client is on our TLS, whatever proxies say.
                request.secure = true;

                if (request.headers.get("Expect")) |expect| {
                    if (std.ascii.eqlIgnoreCase(expect, "100-continue")) {
                        conn.lock();
                        request.expects_continue = !s.body_done;
                        conn.unlock();
                    } else {
                        response.status = .expectation_failed;
                        return response.write();
                    }
                }

                server.dispatch(&request, &response) catch |err| switch (err) {
                    error.ReadFailed => return body_reader.err orelse error.Unexpected,
                    error.WriteFailed => return sink_state.err orelse error.Unexpected,
                    else => |e| return e,
                };
                try response.write();
            }

            /// Tells nghttp3 there is more of the body, if it was waiting
            /// for some. Locked.
            fn resume_(s: *Stream) void {
                if (!s.deferred) return;
                s.deferred = false;
                if (s.conn.h3) |hc| _ = h.nghttp3_conn_resume_stream(hc, s.id);
            }

            /// Waits for the connection to change. Unlocked.
            fn wait(s: *Stream, gen: u32) std.Io.Cancelable!void {
                try s.conn.ep.io.futexWait(u32, &s.conn.gen.raw, gen);
            }

            /// Waits until the handshake completes; fails if the stream or
            /// the connection goes first (a replayed 0-RTT flight: its
            /// connection never completes). Unlocked.
            fn awaitHandshake(s: *Stream) !void {
                const conn = s.conn;
                while (true) {
                    const gen = conn.gen.load(.acquire);
                    conn.lock();
                    const done = conn.handshakeDone();
                    const gone = s.reset;
                    conn.unlock();
                    if (done) return;
                    if (gone) return error.ConnectionResetByPeer;
                    try s.wait(gen);
                }
            }
        };

        fn isWebTransport(protocol: []const u8) bool {
            // "webtransport" in draft-02 (Chrome, Firefox) and up to
            // draft-14, "webtransport-h3" since draft-15.
            return std.mem.eql(u8, protocol, "webtransport") or std.mem.eql(u8, protocol, "webtransport-h3");
        }

        fn parseMethod(name: []const u8) ?dusty.Method {
            var lower: [16]u8 = undefined;
            if (name.len == 0 or name.len > lower.len) return null;
            return std.meta.stringToEnum(dusty.Method, std.ascii.lowerString(&lower, name));
        }

        /// The request body, from the stream's queue. Gives the stream its
        /// flow-control credit back as the handler reads.
        const BodyReader = struct {
            stream: *Stream,
            interface: std.Io.Reader,
            err: ?ReadError = null,

            fn init(stream: *Stream) BodyReader {
                return .{ .stream = stream, .interface = .{
                    .vtable = &.{ .stream = streamFn },
                    .buffer = &.{},
                    .seek = 0,
                    .end = 0,
                } };
            }

            fn errorOf(r: *std.Io.Reader) ?ReadError {
                const self: *BodyReader = @alignCast(@fieldParentPtr("interface", r));
                return self.err;
            }

            fn streamFn(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
                const self: *BodyReader = @alignCast(@fieldParentPtr("interface", r));
                const s = self.stream;
                const conn = s.conn;
                const dest = limit.slice(try w.writableSliceGreedy(1));
                if (dest.len == 0) return 0;
                while (true) {
                    const gen = conn.gen.load(.acquire);
                    conn.lock();
                    const have = s.body.items[s.body_start..];
                    if (have.len > 0) {
                        const n = @min(have.len, dest.len);
                        @memcpy(dest[0..n], have[0..n]);
                        s.body_start += n;
                        if (s.body_start == s.body.items.len) {
                            s.body.clearRetainingCapacity();
                            s.body_start = 0;
                        }
                        if (!s.reset) conn.consume(s.id, n);
                        conn.unlock();
                        conn.kick();
                        w.advance(n);
                        return n;
                    }
                    const done = s.body_done;
                    const reset = s.reset;
                    conn.unlock();
                    if (done) return error.EndOfStream;
                    if (reset) return self.fail(error.ConnectionResetByPeer);
                    s.wait(gen) catch return self.fail(error.Canceled);
                }
            }

            fn fail(self: *BodyReader, err: ReadError) std.Io.Reader.StreamError {
                self.err = err;
                return error.ReadFailed;
            }
        };

        /// The response side of a stream, for `Response.initSink`.
        const StreamSink = struct {
            stream: *Stream,
            writer: std.Io.Writer = .{ .vtable = &.{ .drain = drain, .flush = flushFn }, .buffer = &.{} },
            err: ?SendError = null,

            fn sink(self: *StreamSink) dusty.Sink {
                return .{ .ptr = self, .vtable = &.{
                    .head = head,
                    .interim = interim,
                    .body = body,
                    .end = end,
                    .writeError = writeError,
                    .peerGone = peerGone,
                } };
            }

            fn fromPtr(ptr: *anyopaque) *StreamSink {
                return @ptrCast(@alignCast(ptr));
            }

            fn fail(self: *StreamSink, err: SendError) std.Io.Writer.Error {
                self.err = err;
                return error.WriteFailed;
            }

            /// Records the head; it goes out with the first body bytes, a
            /// flush, or the end.
            fn head(ptr: *anyopaque, status: dusty.Status, headers: *const dusty.Headers, content_length: ?usize) std.Io.Writer.Error!void {
                const self = fromPtr(ptr);
                const s = self.stream;
                const arena = s.arena.allocator();
                var nv: std.ArrayList(h.nghttp3_nv) = .empty;
                const status_text = std.fmt.allocPrint(arena, "{d}", .{@backingInt(status)}) catch return self.fail(error.SystemResources);
                nv.append(arena, field(":status", status_text)) catch return self.fail(error.SystemResources);
                var has_length = false;
                var it = headers.iterator();
                while (it.next()) |entry| {
                    // RFC 9114 §4.2: connection-specific fields are malformed.
                    if (isConnectionSpecific(entry.key)) continue;
                    if (std.ascii.eqlIgnoreCase(entry.key, "content-length")) has_length = true;
                    const name = std.ascii.allocLowerString(arena, entry.key) catch return self.fail(error.SystemResources);
                    nv.append(arena, field(name, entry.value)) catch return self.fail(error.SystemResources);
                }
                if (!has_length and statusHasLength(status)) {
                    if (content_length) |len| {
                        const text = std.fmt.allocPrint(arena, "{d}", .{len}) catch return self.fail(error.SystemResources);
                        nv.append(arena, field("content-length", text)) catch return self.fail(error.SystemResources);
                    }
                }
                s.response_nv = nv.items;
            }

            fn interim(ptr: *anyopaque, status: dusty.Status) std.Io.Writer.Error!void {
                const self = fromPtr(ptr);
                const s = self.stream;
                const conn = s.conn;
                var status_buf: [3]u8 = undefined;
                const text = std.fmt.bufPrint(&status_buf, "{d}", .{@backingInt(status)}) catch unreachable;
                const nva = [_]h.nghttp3_nv{field(":status", text)};
                conn.lock();
                defer conn.unlock();
                if (s.reset) return self.fail(error.ConnectionResetByPeer);
                const hc = conn.h3 orelse return self.fail(error.ConnectionResetByPeer);
                if (h.nghttp3_conn_submit_info(hc, s.id, &nva, nva.len) != 0) return self.fail(error.Unexpected);
                conn.kick();
            }

            fn body(ptr: *anyopaque) *std.Io.Writer {
                const self = fromPtr(ptr);
                if (self.writer.buffer.len == 0) {
                    self.writer.buffer = self.stream.arena.allocator().alloc(u8, 16 * 1024) catch &.{};
                }
                return &self.writer;
            }

            /// Submits the head, with the body reader, once. Locked.
            fn submit(self: *StreamSink) std.Io.Writer.Error!void {
                const s = self.stream;
                const conn = s.conn;
                if (s.submitted) return;
                if (s.reset) return self.fail(error.ConnectionResetByPeer);
                const hc = conn.h3 orelse return self.fail(error.ConnectionResetByPeer);
                const reader: h.nghttp3_data_reader = .{ .read_data = readData };
                const rv = h.nghttp3_conn_submit_response(hc, s.id, s.response_nv.ptr, s.response_nv.len, &reader);
                if (rv != 0) {
                    log.debug("nghttp3_conn_submit_response: {s}", .{h.nghttp3_strerror(rv)});
                    return self.fail(error.ConnectionResetByPeer);
                }
                s.submitted = true;
                conn.kick();
            }

            fn flushFn(w: *std.Io.Writer) std.Io.Writer.Error!void {
                const self: *StreamSink = @alignCast(@fieldParentPtr("writer", w));
                try self.put(w.buffered());
                w.end = 0;
                const conn = self.stream.conn;
                conn.lock();
                defer conn.unlock();
                try self.submit();
            }

            fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
                const self: *StreamSink = @alignCast(@fieldParentPtr("writer", w));
                try self.put(w.buffered());
                w.end = 0;
                var n: usize = 0;
                if (data.len > 0) {
                    for (data[0 .. data.len - 1]) |bytes| {
                        try self.put(bytes);
                        n += bytes.len;
                    }
                    const pattern = data[data.len - 1];
                    for (0..splat) |_| {
                        try self.put(pattern);
                        n += pattern.len;
                    }
                }
                return n;
            }

            /// Copies body bytes into the ring, waiting while it is full
            /// (the peer has not acknowledged enough yet).
            fn put(self: *StreamSink, bytes: []const u8) std.Io.Writer.Error!void {
                const s = self.stream;
                const conn = s.conn;
                var rest = bytes;
                while (rest.len > 0) {
                    const gen = conn.gen.load(.acquire);
                    conn.lock();
                    if (s.reset) {
                        conn.unlock();
                        return self.fail(error.ConnectionResetByPeer);
                    }
                    self.submit() catch |err| {
                        conn.unlock();
                        return err;
                    };
                    const n = s.out.write(conn.ep.gpa, rest) catch {
                        conn.unlock();
                        return self.fail(error.SystemResources);
                    };
                    if (n > 0) {
                        rest = rest[n..];
                        s.resume_();
                    }
                    conn.unlock();
                    // Kick only for new bytes: a kick would also move `gen`
                    // on, the wait below would return at once, and the
                    // handler would spin, starving the connection's other
                    // tasks on this executor.
                    if (n > 0) conn.kick() else s.wait(gen) catch return self.fail(error.Canceled);
                }
            }

            fn end(ptr: *anyopaque, trailers: ?*const dusty.Headers) std.Io.Writer.Error!void {
                const self = fromPtr(ptr);
                const s = self.stream;
                const conn = s.conn;
                const arena = s.arena.allocator();
                var trailer_nv: std.ArrayList(h.nghttp3_nv) = .empty;
                if (trailers) |t| {
                    var it = t.iterator();
                    while (it.next()) |entry| {
                        const name = std.ascii.allocLowerString(arena, entry.key) catch return self.fail(error.SystemResources);
                        trailer_nv.append(arena, field(name, entry.value)) catch return self.fail(error.SystemResources);
                    }
                }
                conn.lock();
                defer conn.unlock();
                s.trailer_nv = trailer_nv.items;
                s.ended = true;
                try self.submit();
                s.resume_();
                conn.kick();
            }

            fn writeError(ptr: *anyopaque) ?SendError {
                return fromPtr(ptr).err;
            }

            fn peerGone(ptr: *anyopaque) bool {
                const s = fromPtr(ptr).stream;
                s.conn.lock();
                defer s.conn.unlock();
                return s.reset;
            }
        };

        fn field(name: []const u8, value: []const u8) h.nghttp3_nv {
            return .{
                .name = name.ptr,
                .namelen = name.len,
                .value = value.ptr,
                .valuelen = value.len,
                .flags = h.NGHTTP3_NV_FLAG_NONE,
            };
        }

        fn isConnectionSpecific(name: []const u8) bool {
            const banned = [_][]const u8{ "connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade" };
            for (banned) |b| if (std.ascii.eqlIgnoreCase(name, b)) return true;
            return false;
        }

        fn statusHasLength(status: dusty.Status) bool {
            const code = @backingInt(status);
            return !(code < 200 or code == 204 or code == 304);
        }

        // -- ngtcp2 callbacks: each runs inside an ngtcp2_conn_* call, with
        // -- the connection's mutex held by the caller.

        const callbacks: c.ngtcp2_callbacks = blk: {
            var cb = std.mem.zeroes(c.ngtcp2_callbacks);
            cb.recv_client_initial = c.ngtcp2_crypto_recv_client_initial_cb;
            cb.recv_crypto_data = c.ngtcp2_crypto_recv_crypto_data_cb;
            cb.handshake_completed = onHandshakeCompleted;
            cb.encrypt = c.ngtcp2_crypto_encrypt_cb;
            cb.decrypt = c.ngtcp2_crypto_decrypt_cb;
            cb.hp_mask = c.ngtcp2_crypto_hp_mask_cb;
            cb.recv_stream_data = onRecvStreamData;
            cb.acked_stream_data_offset = onAckedStreamDataOffset;
            cb.stream_open = onStreamOpen;
            cb.rand = onRand;
            cb.remove_connection_id = onRemoveConnectionId;
            cb.update_key = c.ngtcp2_crypto_update_key_cb;
            cb.stream_reset = onStreamReset;
            cb.extend_max_remote_streams_bidi = onExtendMaxRemoteStreamsBidi;
            cb.extend_max_stream_data = onExtendMaxStreamData;
            cb.delete_crypto_aead_ctx = c.ngtcp2_crypto_delete_crypto_aead_ctx_cb;
            cb.delete_crypto_cipher_ctx = c.ngtcp2_crypto_delete_crypto_cipher_ctx_cb;
            cb.stream_stop_sending = onStreamStopSending;
            cb.version_negotiation = c.ngtcp2_crypto_version_negotiation_cb;
            cb.recv_tx_key = onRecvTxKey;
            cb.get_new_connection_id2 = onGetNewConnectionId;
            cb.get_path_challenge_data2 = c.ngtcp2_crypto_get_path_challenge_data2_cb;
            cb.stream_close2 = onStreamClose;
            cb.path_validation = onPathValidation;
            cb.recv_datagram = onRecvDatagram;
            cb.extend_max_local_streams_bidi = onExtendMaxLocalStreams;
            cb.extend_max_local_streams_uni = onExtendMaxLocalStreams;
            break :blk cb;
        };

        fn connOf(user_data: ?*anyopaque) *Conn {
            return @ptrCast(@alignCast(user_data.?));
        }

        fn onHandshakeCompleted(_: ?*c.ngtcp2_conn, user_data: ?*anyopaque) callconv(.c) c_int {
            const conn = connOf(user_data);
            // A token for the next connection from this address, so it
            // can skip the Retry round trip.
            var token: [c.NGTCP2_CRYPTO_MAX_REGULAR_TOKENLEN]u8 = undefined;
            const p = c.ngtcp2_conn_get_path2(conn.q);
            const n = c.ngtcp2_crypto_generate_regular_token(&token, &conn.ep.secret, conn.ep.secret.len, p.*.remote.addr, p.*.remote.addrlen, wallClock(conn.ep.io));
            if (n > 0) _ = c.ngtcp2_conn_submit_new_token(conn.q, &token, @intCast(n));
            if (conn.ep.options.early_data and c.SSL_session_reused(conn.ssl) != 0)
                log.debug("resumed; 0-RTT: {s}", .{quic_tls.earlyDataReason(conn.ssl)});
            // Requests held for the handshake may go on.
            conn.kick();
            return 0;
        }

        /// The client moved (a NAT rebinding, or a migration of its own) and
        /// the new path checked out. If its address changed, not just the
        /// port, a token for that address lets its next connection skip
        /// the Retry round trip, as at the handshake.
        fn onPathValidation(_: ?*c.ngtcp2_conn, flags: u32, p: [*c]const c.ngtcp2_path, _: [*c]const c.ngtcp2_path, res: c.ngtcp2_path_validation_result, user_data: ?*anyopaque) callconv(.c) c_int {
            if (res != c.NGTCP2_PATH_VALIDATION_RESULT_SUCCESS or flags & c.NGTCP2_PATH_VALIDATION_FLAG_NEW_TOKEN == 0) return 0;
            const conn = connOf(user_data);
            var token: [c.NGTCP2_CRYPTO_MAX_REGULAR_TOKENLEN]u8 = undefined;
            const n = c.ngtcp2_crypto_generate_regular_token(&token, &conn.ep.secret, conn.ep.secret.len, p.*.remote.addr, p.*.remote.addrlen, wallClock(conn.ep.io));
            if (n <= 0) return 0;
            if (c.ngtcp2_conn_submit_new_token(conn.q, &token, @intCast(n)) != 0) return c.NGTCP2_ERR_CALLBACK_FAILURE;
            return 0;
        }

        fn onRecvStreamData(_: ?*c.ngtcp2_conn, flags: u32, stream_id: i64, offset: u64, data: [*c]const u8, len: usize, user_data: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
            const conn = connOf(user_data);
            const bytes: []const u8 = if (len == 0) &.{} else data[0..len];
            if (conn.hq) return conn.hqRecv(flags, stream_id, bytes);
            const rv = bridge.recvStreamData(conn.side(), flags, stream_id, offset, bytes);
            // A bidirectional stream WebTransport took is no request.
            if (conn.wt) |w| if (w.owns(stream_id)) if (conn.streams.fetchRemove(stream_id)) |e| e.value.free();
            return rv;
        }

        fn onRecvDatagram(_: ?*c.ngtcp2_conn, _: u32, data: [*c]const u8, len: usize, user_data: ?*anyopaque) callconv(.c) c_int {
            const conn = connOf(user_data);
            if (conn.wt) |w| w.onDatagram(if (len == 0) &.{} else data[0..len]);
            return 0;
        }

        fn onExtendMaxLocalStreams(_: ?*c.ngtcp2_conn, _: u64, user_data: ?*anyopaque) callconv(.c) c_int {
            // A WebTransport handler waiting to open a stream may go on.
            connOf(user_data).kick();
            return 0;
        }

        fn onAckedStreamDataOffset(_: ?*c.ngtcp2_conn, stream_id: i64, _: u64, len: u64, user_data: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
            const conn = connOf(user_data);
            if (conn.wt) |w| if (w.onAcked(stream_id, len)) return 0;
            const hc = conn.h3 orelse return 0;
            if (h.nghttp3_conn_add_ack_offset(hc, stream_id, len) != 0) return c.NGTCP2_ERR_CALLBACK_FAILURE;
            return 0;
        }

        fn onStreamOpen(_: ?*c.ngtcp2_conn, stream_id: i64, user_data: ?*anyopaque) callconv(.c) c_int {
            const conn = connOf(user_data);
            if (c.ngtcp2_is_bidi_stream(stream_id) == 0) return 0;
            if (conn.hq) {
                const hs = conn.ep.gpa.create(HqStream) catch return c.NGTCP2_ERR_CALLBACK_FAILURE;
                hs.* = .{};
                conn.hq_streams.put(conn.ep.gpa, stream_id, hs) catch {
                    conn.ep.gpa.destroy(hs);
                    return c.NGTCP2_ERR_CALLBACK_FAILURE;
                };
                return 0;
            }
            const s = Stream.create(conn, stream_id) catch return c.NGTCP2_ERR_CALLBACK_FAILURE;
            conn.streams.put(conn.ep.gpa, stream_id, s) catch {
                s.free();
                return c.NGTCP2_ERR_CALLBACK_FAILURE;
            };
            return 0;
        }

        fn onStreamClose(_: ?*c.ngtcp2_conn, flags: u32, stream_id: i64, rx_code: u64, tx_code: u64, user_data: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
            const conn = connOf(user_data);
            // WebTransport's: nghttp3 never knew it, and the core gives
            // the peer its stream credit back.
            if (conn.wt) |w| if (w.onClose(stream_id)) {
                conn.kick();
                return 0;
            };
            const rv = bridge.closeStream(conn.side(), flags, stream_id, rx_code, tx_code);
            if (rv != 0) return rv;
            if (conn.hq_streams.fetchSwapRemove(stream_id)) |e| e.value.free(conn.ep.gpa);
            if (c.ngtcp2_is_bidi_stream(stream_id) != 0) {
                _ = c.ngtcp2_conn_extend_max_streams_bidi(conn.q, 1);
                if (conn.streamOf(stream_id)) |s| {
                    // Unless it ended cleanly, the handler sees it gone.
                    if (!(s.ended and s.out.allSent() and s.body_done)) s.reset = true;
                    s.release(.quic);
                }
            }
            conn.kick();
            return 0;
        }

        fn onStreamReset(_: ?*c.ngtcp2_conn, stream_id: i64, _: u64, code: u64, user_data: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
            const conn = connOf(user_data);
            if (conn.wt) |w| if (w.onReset(stream_id, code)) return 0;
            if (conn.h3) |hc| if (h.nghttp3_conn_shutdown_stream_read(hc, stream_id) != 0) return c.NGTCP2_ERR_CALLBACK_FAILURE;
            if (conn.streamOf(stream_id)) |s| s.reset = true;
            conn.kick();
            return 0;
        }

        fn onStreamStopSending(_: ?*c.ngtcp2_conn, stream_id: i64, code: u64, user_data: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
            const conn = connOf(user_data);
            if (conn.wt) |w| if (w.onStopSending(stream_id, code)) return 0;
            if (conn.h3) |hc| if (h.nghttp3_conn_shutdown_stream_read(hc, stream_id) != 0) return c.NGTCP2_ERR_CALLBACK_FAILURE;
            // The peer wants no more of the response.
            if (conn.streamOf(stream_id)) |s| s.reset = true;
            conn.kick();
            return 0;
        }

        fn onRand(dest: [*c]u8, len: usize, rand_ctx: [*c]const c.ngtcp2_rand_ctx) callconv(.c) void {
            const conn: *Conn = @ptrCast(@alignCast(rand_ctx.*.native_handle));
            conn.ep.io.random(dest[0..len]);
        }

        fn onGetNewConnectionId(_: ?*c.ngtcp2_conn, cid: [*c]c.ngtcp2_cid, token: [*c]c.ngtcp2_stateless_reset_token, len: usize, user_data: ?*anyopaque) callconv(.c) c_int {
            const conn = connOf(user_data);
            const ep = conn.ep;
            ep.newCid(cid.*.data[0..len]);
            cid.*.datalen = len;
            if (c.ngtcp2_crypto_generate_stateless_reset_token(&token.*.data, &ep.secret, ep.secret.len, cid) != 0)
                return c.NGTCP2_ERR_CALLBACK_FAILURE;
            ep.associate(.ofCid(cid), conn) catch return c.NGTCP2_ERR_CALLBACK_FAILURE;
            return 0;
        }

        fn onRemoveConnectionId(_: ?*c.ngtcp2_conn, cid: [*c]const c.ngtcp2_cid, user_data: ?*anyopaque) callconv(.c) c_int {
            const conn = connOf(user_data);
            conn.ep.dissociate(.ofCid(cid));
            return 0;
        }

        fn onExtendMaxRemoteStreamsBidi(_: ?*c.ngtcp2_conn, max_streams: u64, user_data: ?*anyopaque) callconv(.c) c_int {
            const conn = connOf(user_data);
            if (conn.h3) |hc| h.nghttp3_conn_set_max_client_streams_bidi(hc, max_streams);
            return 0;
        }

        fn onExtendMaxStreamData(_: ?*c.ngtcp2_conn, stream_id: i64, _: u64, user_data: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
            const conn = connOf(user_data);
            // More credit: the driver writes again.
            if (conn.hq) conn.kick();
            if (conn.wt) |w| if (w.onUnblocked(stream_id)) return 0;
            const hc = conn.h3 orelse return 0;
            if (h.nghttp3_conn_unblock_stream(hc, stream_id) != 0) return c.NGTCP2_ERR_CALLBACK_FAILURE;
            return 0;
        }

        fn onRecvTxKey(_: ?*c.ngtcp2_conn, level: c.ngtcp2_encryption_level, user_data: ?*anyopaque) callconv(.c) c_int {
            if (level != c.NGTCP2_ENCRYPTION_LEVEL_1RTT) return 0;
            const conn = connOf(user_data);
            if (quic_tls.isHq(conn.ssl)) {
                conn.hq = true;
                return 0;
            }
            conn.setupHttp3() catch return c.NGTCP2_ERR_CALLBACK_FAILURE;
            return 0;
        }

        fn writePkt(_: ?*c.ngtcp2_conn, p: [*c]c.ngtcp2_path, pi: [*c]c.ngtcp2_pkt_info, dest: [*c]u8, len: usize, ts: c.ngtcp2_tstamp, user_data: ?*anyopaque) callconv(.c) c.ngtcp2_ssize {
            const conn = connOf(user_data);
            if (conn.hq) return conn.hqWritePacket(p, pi, dest, len, ts);
            return bridge.writePacket(conn.side(), p, pi, dest, len, ts);
        }

        // -- nghttp3 callbacks: inside nghttp3_conn_* calls, locked.

        const h3_callbacks: h.nghttp3_callbacks = blk: {
            var cb = std.mem.zeroes(h.nghttp3_callbacks);
            cb.acked_stream_data = onH3AckedStreamData;
            cb.recv_data = onH3RecvData;
            cb.deferred_consume = onH3DeferredConsume;
            cb.begin_headers = onH3BeginHeaders;
            cb.recv_header = onH3RecvHeader;
            cb.end_headers = onH3EndHeaders;
            cb.stop_sending = onH3StopSending;
            cb.end_stream = onH3EndStream;
            cb.reset_stream = onH3ResetStream;
            cb.rand = net.h3Rand;
            break :blk cb;
        };

        fn streamOfUser(stream_user_data: ?*anyopaque) ?*Stream {
            return @ptrCast(@alignCast(stream_user_data orelse return null));
        }

        fn onH3AckedStreamData(_: ?*h.nghttp3_conn, _: i64, len: u64, _: ?*anyopaque, sud: ?*anyopaque) callconv(.c) c_int {
            const s = streamOfUser(sud) orelse return 0;
            s.out.acked += len;
            // Room in the ring: a handler waiting to write may go on.
            s.conn.kick();
            return 0;
        }

        fn onH3RecvData(_: ?*h.nghttp3_conn, stream_id: i64, data: [*c]const u8, len: usize, user_data: ?*anyopaque, sud: ?*anyopaque) callconv(.c) c_int {
            const conn = connOf(user_data);
            const s = streamOfUser(sud) orelse {
                conn.consume(stream_id, len);
                return 0;
            };
            // The peer cannot send past the stream's window, so this is
            // bounded by `max_stream_data`.
            s.body.appendSlice(conn.ep.gpa, data[0..len]) catch return h.NGHTTP3_ERR_CALLBACK_FAILURE;
            conn.kick();
            return 0;
        }

        fn onH3DeferredConsume(_: ?*h.nghttp3_conn, stream_id: i64, n: usize, user_data: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
            connOf(user_data).consume(stream_id, n);
            return 0;
        }

        fn onH3BeginHeaders(hc: ?*h.nghttp3_conn, stream_id: i64, user_data: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
            const conn = connOf(user_data);
            const s = conn.streamOf(stream_id) orelse return 0;
            _ = h.nghttp3_conn_set_stream_user_data(hc, stream_id, s);
            return 0;
        }

        fn onH3RecvHeader(_: ?*h.nghttp3_conn, _: i64, token: i32, name: ?*h.nghttp3_rcbuf, value: ?*h.nghttp3_rcbuf, _: u8, _: ?*anyopaque, sud: ?*anyopaque) callconv(.c) c_int {
            const s = streamOfUser(sud) orelse return 0;
            // Trailers on a request are not passed on.
            if (s.started) return 0;
            const arena = s.arena.allocator();
            const v = h.nghttp3_rcbuf_get_buf(value);
            const val = arena.dupe(u8, v.base[0..v.len]) catch return h.NGHTTP3_ERR_CALLBACK_FAILURE;
            switch (token) {
                h.NGHTTP3_QPACK_TOKEN__PATH => s.path = val,
                h.NGHTTP3_QPACK_TOKEN__METHOD => s.method = val,
                h.NGHTTP3_QPACK_TOKEN__AUTHORITY => s.authority = val,
                h.NGHTTP3_QPACK_TOKEN__PROTOCOL => s.protocol = val,
                h.NGHTTP3_QPACK_TOKEN__SCHEME => {},
                else => {
                    const n = h.nghttp3_rcbuf_get_buf(name);
                    const key = arena.dupe(u8, n.base[0..n.len]) catch return h.NGHTTP3_ERR_CALLBACK_FAILURE;
                    s.headers.append(arena, .{ .name = key, .value = val }) catch return h.NGHTTP3_ERR_CALLBACK_FAILURE;
                },
            }
            return 0;
        }

        fn onH3EndHeaders(_: ?*h.nghttp3_conn, _: i64, fin: c_int, user_data: ?*anyopaque, sud: ?*anyopaque) callconv(.c) c_int {
            const conn = connOf(user_data);
            const s = streamOfUser(sud) orelse return 0;
            if (s.started) return 0;
            if (fin != 0) s.body_done = true;
            // On a server, 1-RTT data is only read once the handshake has
            // completed, so a head that ends before came in 0-RTT.
            s.early = !conn.handshakeDone();
            conn.startStream(s);
            return 0;
        }

        fn onH3EndStream(_: ?*h.nghttp3_conn, _: i64, user_data: ?*anyopaque, sud: ?*anyopaque) callconv(.c) c_int {
            const conn = connOf(user_data);
            const s = streamOfUser(sud) orelse return 0;
            s.body_done = true;
            conn.kick();
            return 0;
        }

        fn onH3StopSending(_: ?*h.nghttp3_conn, stream_id: i64, code: u64, user_data: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
            const conn = connOf(user_data);
            if (c.ngtcp2_conn_shutdown_stream_read(conn.q, 0, stream_id, code) != 0) return h.NGHTTP3_ERR_CALLBACK_FAILURE;
            return 0;
        }

        fn onH3ResetStream(_: ?*h.nghttp3_conn, stream_id: i64, code: u64, user_data: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
            const conn = connOf(user_data);
            if (c.ngtcp2_conn_shutdown_stream_write(conn.q, 0, stream_id, code) != 0) return h.NGHTTP3_ERR_CALLBACK_FAILURE;
            return 0;
        }

        /// nghttp3 pulls response body bytes: what is in the ring and not
        /// yet handed over, then the end (with trailers, if any). Locked.
        fn readData(_: ?*h.nghttp3_conn, stream_id: i64, vec: [*c]h.nghttp3_vec, veccnt: usize, pflags: [*c]u32, _: ?*anyopaque, sud: ?*anyopaque) callconv(.c) h.nghttp3_ssize {
            const s = streamOfUser(sud) orelse return h.NGHTTP3_ERR_CALLBACK_FAILURE;
            if (s.out.allSent()) {
                if (!s.ended) {
                    s.deferred = true;
                    return h.NGHTTP3_ERR_WOULDBLOCK;
                }
                pflags.* |= h.NGHTTP3_DATA_FLAG_EOF;
                if (s.trailer_nv.len > 0) {
                    pflags.* |= h.NGHTTP3_DATA_FLAG_NO_END_STREAM;
                    if (h.nghttp3_conn_submit_trailers(s.conn.h3, stream_id, s.trailer_nv.ptr, s.trailer_nv.len) != 0)
                        return h.NGHTTP3_ERR_CALLBACK_FAILURE;
                }
                return 0;
            }
            const count = s.out.take(vec, veccnt);
            if (s.ended and s.out.allSent()) {
                pflags.* |= h.NGHTTP3_DATA_FLAG_EOF;
                if (s.trailer_nv.len > 0) {
                    pflags.* |= h.NGHTTP3_DATA_FLAG_NO_END_STREAM;
                    if (h.nghttp3_conn_submit_trailers(s.conn.h3, stream_id, s.trailer_nv.ptr, s.trailer_nv.len) != 0)
                        return h.NGHTTP3_ERR_CALLBACK_FAILURE;
                }
            }
            return @intCast(count);
        }
    };
}

/// The 0-RTT context a connection of an endpoint with `options` gets, from
/// a throwaway connection with fixed IDs: for tests that compare endpoints
/// or settings.
pub fn earlyDataContextOf(options: *const Options, buf: *[early_context_max]u8) ![]const u8 {
    const S = struct {
        fn rand(dest: [*c]u8, len: usize, _: [*c]const c.ngtcp2_rand_ctx) callconv(.c) void {
            @memset(dest[0..len], 7);
        }
        fn newCid(_: ?*c.ngtcp2_conn, cid: [*c]c.ngtcp2_cid, token: [*c]c.ngtcp2_stateless_reset_token, len: usize, _: ?*anyopaque) callconv(.c) c_int {
            @memset(cid.*.data[0..len], 9);
            cid.*.datalen = len;
            @memset(&token.*.data, 9);
            return 0;
        }
    };
    var settings: ngtcp2.Settings = undefined;
    ngtcp2.settingsDefault(&settings);
    settings.initial_ts = 1;
    var params = transportParams(options);
    var cid: c.ngtcp2_cid = undefined;
    const bytes: [8]u8 = @splat(1);
    c.ngtcp2_cid_init(&cid, &bytes, bytes.len);
    params.original_dcid = cid;
    params.original_dcid_present = 1;
    var local: net.Addr = .from(.{ .ip4 = .loopback(4433) });
    var remote: net.Addr = .from(.{ .ip4 = .loopback(50000) });
    const p: c.ngtcp2_path = .{ .local = local.ngtcp2Addr(), .remote = remote.ngtcp2Addr(), .user_data = null };
    var cb = std.mem.zeroes(c.ngtcp2_callbacks);
    cb.recv_client_initial = c.ngtcp2_crypto_recv_client_initial_cb;
    cb.recv_crypto_data = c.ngtcp2_crypto_recv_crypto_data_cb;
    cb.encrypt = c.ngtcp2_crypto_encrypt_cb;
    cb.decrypt = c.ngtcp2_crypto_decrypt_cb;
    cb.hp_mask = c.ngtcp2_crypto_hp_mask_cb;
    cb.update_key = c.ngtcp2_crypto_update_key_cb;
    cb.delete_crypto_aead_ctx = c.ngtcp2_crypto_delete_crypto_aead_ctx_cb;
    cb.delete_crypto_cipher_ctx = c.ngtcp2_crypto_delete_crypto_cipher_ctx_cb;
    cb.get_path_challenge_data2 = c.ngtcp2_crypto_get_path_challenge_data2_cb;
    cb.rand = S.rand;
    cb.get_new_connection_id2 = S.newCid;
    var q: ?*c.ngtcp2_conn = null;
    if (ngtcp2.connServerNew(&q, &cid, &cid, &p, c.NGTCP2_PROTO_VER_V1, &cb, &settings, &params, null, null) != 0)
        return error.QuicSetupFailed;
    defer c.ngtcp2_conn_del(q);
    return earlyDataContext(q.?, http3Settings(options), options.webtransport, buf);
}

test "0-RTT context: the same for the same settings, different when a limit or a SETTINGS value changes" {
    const Ctx = struct {
        fn of(options: Options, buf: *[early_context_max]u8) ![]const u8 {
            return earlyDataContextOf(&options, buf);
        }
    };
    const base: Options = .{ .address = .{ .ip4 = .loopback(0) }, .cert_pem = "", .key_pem = "" };
    var a: [early_context_max]u8 = undefined;
    var b: [early_context_max]u8 = undefined;
    try std.testing.expectEqualSlices(u8, try Ctx.of(base, &a), try Ctx.of(base, &b));
    var more_streams = base;
    more_streams.max_streams_bidi += 1;
    try std.testing.expect(!std.mem.eql(u8, try Ctx.of(base, &a), try Ctx.of(more_streams, &b)));
    var bigger_headers = base;
    bigger_headers.max_field_section_size *= 2;
    try std.testing.expect(!std.mem.eql(u8, try Ctx.of(base, &a), try Ctx.of(bigger_headers, &b)));
    var with_webtransport = base;
    with_webtransport.webtransport = true;
    try std.testing.expect(!std.mem.eql(u8, try Ctx.of(base, &a), try Ctx.of(with_webtransport, &b)));
    try std.testing.expectEqual(@as(u8, early_context_version), (try Ctx.of(base, &a))[0]);
}
