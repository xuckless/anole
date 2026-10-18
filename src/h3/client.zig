//! An HTTP/3 client connection on ngtcp2 and nghttp3: many concurrent
//! requests over one QUIC connection, with the HTTP/2 client's API
//! (`anole.h2.ClientConnection`). A reader task feeds ngtcp2 the datagrams
//! that arrive, a driver task writes packets and runs the timers, one mutex
//! serializes every ngtcp2 and nghttp3 call, and nothing blocks while
//! holding it. After ngtcp2's examples/client.cc and
//! http3_client_proto_codec.cc (MIT).
//!
//!     var conn = try anole.h3.ClientConnection.connect(gpa, io, .{
//!         .host = "localhost", .port = 8443, .tls = .{ .root_ca = bundle },
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
const std = @import("std");
const dusty = @import("dusty");
const ngtcp2 = @import("ngtcp2.zig");
const nghttp3 = @import("nghttp3.zig");
const quic_tls = @import("quic_tls.zig");
const net = @import("net.zig");
const bridge = @import("bridge.zig");

const c = ngtcp2.c;
const h = nghttp3.c;
const Addr = net.Addr;
const now = net.now;
const placement = dusty.placement;

const log = std.log.scoped(.anole_h3);

/// Packets written per driver round.
const burst = 10;
/// Largest UDP payload read.
const max_datagram = 65527;

pub const Header = struct { name: []const u8, value: []const u8 };

pub const ConnectOptions = struct {
    /// The server's name (SNI and the certificate check) or address.
    host: []const u8,
    port: u16,
    /// Send here instead of resolving `host`.
    address: ?std.Io.net.IpAddress = null,
    tls: Tls = .{},
    /// Bytes the server may send on a stream before its reader takes them.
    stream_window: u32 = 256 * 1024,
    /// The same for the whole connection.
    max_data: u32 = 16 * 1024 * 1024,
    idle_timeout_ms: u32 = 30_000,
    /// How long `connect` waits for the handshake.
    handshake_timeout_ms: u32 = 10_000,

    pub const Tls = struct {
        root_ca: std.crypto.Certificate.Bundle = .empty,
        insecure_skip_verify: bool = false,
    };
};

pub const Error = error{ ConnectionClosed, StreamReset, OutOfMemory, Unexpected };

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
    /// The server sent GOAWAY, or `close` began: no new requests.
    closing: bool = false,
    last_error: c.ngtcp2_ccerr = undefined,
    /// The reader and the driver.
    group: std.Io.Group = .init,
    /// Streams the caller still holds or QUIC still knows.
    live: std.DoublyLinkedList = .{},

    /// Resolves `host` (unless `address` is set), handshakes with ALPN
    /// "h3", and returns once the connection is ready for requests.
    pub fn connect(gpa: std.mem.Allocator, io: std.Io, options: ConnectOptions) !*ClientConnection {
        const remote_ip = options.address orelse try resolve(io, options.host, options.port);
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
        };
        self.conn_ref = .{ .get_conn = getConn, .user_data = self };
        c.ngtcp2_ccerr_default(&self.last_error);
        net.rand_io = io;

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
        settings.handshake_timeout = @as(u64, options.handshake_timeout_ms) * c.NGTCP2_MILLISECONDS;
        // qlog stays off: both of ngtcp2's high-severity advisories were in
        // its qlog code.
        settings.qlog_write = null;
        var initial_pkt_num: [4]u8 = undefined;
        io.random(&initial_pkt_num);
        settings.initial_pkt_num = std.mem.readInt(u32, &initial_pkt_num, .little) & 0x7fffffff;

        var params: ngtcp2.TransportParams = undefined;
        ngtcp2.transportParamsDefault(&params);
        params.initial_max_stream_data_bidi_local = options.stream_window;
        params.initial_max_stream_data_bidi_remote = options.stream_window;
        params.initial_max_stream_data_uni = options.stream_window;
        params.initial_max_data = options.max_data;
        // HTTP/3 servers open no request streams.
        params.initial_max_streams_bidi = 0;
        params.initial_max_streams_uni = 3;
        params.max_idle_timeout = @as(u64, options.idle_timeout_ms) * c.NGTCP2_MILLISECONDS;
        params.active_connection_id_limit = 7;
        params.grease_quic_bit = 1;

        var p = self.path();
        var q: ?*c.ngtcp2_conn = null;
        if (ngtcp2.connClientNew(&q, &dcid, &scid, &p, c.NGTCP2_PROTO_VER_V1, &callbacks, &settings, &params, null, self) != 0)
            return error.QuicSetupFailed;
        self.q = q.?;
        errdefer c.ngtcp2_conn_del(self.q);
        self.ssl = try quic_tls.clientSession(&self.conn_ref, .{
            .host = options.host,
            .root_ca = options.tls.root_ca,
            .insecure_skip_verify = options.tls.insecure_skip_verify,
        });
        errdefer c.SSL_free(self.ssl);
        c.ngtcp2_conn_set_tls_native_handle(self.q, self.ssl);
        errdefer if (self.h3) |hc| h.nghttp3_conn_del(hc);

        errdefer self.group.cancel(io);
        try placement.concurrent(&self.group, io, .local, readerLoop, .{self});
        try placement.concurrent(&self.group, io, .local, drive, .{self});
        try self.waitHandshake();
        if (!std.mem.eql(u8, quic_tls.negotiated(self.ssl), "h3")) return error.NoH3;
        return self;
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
                    log.debug("HTTP/3 handshake failed: {s}", .{c.ngtcp2_strerror(@intCast(self.last_error.error_code))});
                    return error.HandshakeFailed;
                },
                // ngtcp2's handshake timeout ends this.
                .handshaking => try self.io.futexWait(u32, &self.gen.raw, gen),
            }
        }
    }

    /// Sends CONNECTION_CLOSE (H3_NO_ERROR), stops the reader and the
    /// driver, and frees everything. Release every stream first.
    pub fn close(self: *ClientConnection) void {
        const io = self.io;
        self.lock();
        self.closing = true;
        if (self.state != .closed) {
            c.ngtcp2_ccerr_set_application_error(&self.last_error, h.NGHTTP3_H3_NO_ERROR, null, 0);
            self.fail();
        }
        self.unlock();
        self.group.cancel(io);
        if (self.h3) |hc| h.nghttp3_conn_del(hc);
        // Streams released but not yet closed by QUIC.
        while (self.live.popFirst()) |node| {
            const stream: *Stream = @fieldParentPtr("node", node);
            stream.free();
        }
        c.ngtcp2_conn_del(self.q);
        c.SSL_free(self.ssl);
        self.udp.socket.close(io);
        self.gpa.free(self.tx);
        self.gpa.free(self.rx);
        self.gpa.destroy(self);
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

    fn wait(self: *ClientConnection, gen: u32) std.Io.Cancelable!void {
        try self.io.futexWait(u32, &self.gen.raw, gen);
    }

    fn path(self: *ClientConnection) c.ngtcp2_path {
        return .{ .local = self.local.ngtcp2Addr(), .remote = self.remote.ngtcp2Addr(), .user_data = null };
    }

    fn side(self: *ClientConnection) bridge.Side {
        return .{ .q = self.q, .h3 = self.h3, .last_error = &self.last_error };
    }

    pub const RequestOptions = struct {
        /// The request has a body, written through `Stream.writer` and
        /// ended with `Stream.closeSend`.
        body: bool = false,
    };

    /// Opens a request stream, waiting while the server's stream limit is
    /// reached. `headers` holds the pseudo-headers first, names in lower
    /// case; they are copied.
    pub fn request(self: *ClientConnection, headers: []const Header, options: RequestOptions) !*Stream {
        const stream = try Stream.create(self, options.body);
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
            if (self.closing or self.state != .open) {
                self.unlock();
                return error.ConnectionClosed;
            }
            const hc = self.h3 orelse {
                self.unlock();
                return error.ConnectionClosed;
            };
            var id: i64 = -1;
            const rv = c.ngtcp2_conn_open_bidi_stream(self.q, &id, stream);
            if (rv == c.NGTCP2_ERR_STREAM_ID_BLOCKED) {
                self.unlock();
                try self.wait(gen);
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
            self.unlock();
            break;
        }
        self.kick();
        return stream;
    }

    // -- In: the reader task -------------------------------------------------

    fn readerLoop(self: *ClientConnection) std.Io.Cancelable!void {
        var control: net.Udp.Control align(std.Io.net.cmsg_align) = undefined;
        while (true) {
            var dg = self.udp.receive(self.io, self.rx, &control, .none) catch |err| switch (err) {
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
        var it = self.live.first;
        while (it) |node| : (it = node.next) {
            const stream: *Stream = @fieldParentPtr("node", node);
            stream.reset = true;
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
        var hc: ?*h.nghttp3_conn = null;
        if (nghttp3.connClientNew(&hc, &h3_callbacks, &settings, h.nghttp3_mem_default(), self) != 0) return error.Http3SetupFailed;
        errdefer h.nghttp3_conn_del(hc);
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
        self.kick();
        return 0;
    }

    fn onRecvStreamData(_: ?*c.ngtcp2_conn, flags: u32, stream_id: i64, _: u64, data: [*c]const u8, len: usize, user_data: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        return bridge.recvStreamData(connOf(user_data).side(), flags, stream_id, if (len == 0) &.{} else data[0..len]);
    }

    fn onAckedStreamDataOffset(_: ?*c.ngtcp2_conn, stream_id: i64, _: u64, len: u64, user_data: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        const hc = connOf(user_data).h3 orelse return 0;
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

    fn onStreamReset(_: ?*c.ngtcp2_conn, stream_id: i64, _: u64, _: u64, user_data: ?*anyopaque, sud: ?*anyopaque) callconv(.c) c_int {
        const self = connOf(user_data);
        if (self.h3) |hc| if (h.nghttp3_conn_shutdown_stream_read(hc, stream_id) != 0) return c.NGTCP2_ERR_CALLBACK_FAILURE;
        if (streamOfUser(sud)) |s| if (!s.body_done) {
            s.reset = true;
        };
        self.kick();
        return 0;
    }

    fn onStreamStopSending(_: ?*c.ngtcp2_conn, stream_id: i64, _: u64, user_data: ?*anyopaque, sud: ?*anyopaque) callconv(.c) c_int {
        const self = connOf(user_data);
        if (self.h3) |hc| if (h.nghttp3_conn_shutdown_stream_read(hc, stream_id) != 0) return c.NGTCP2_ERR_CALLBACK_FAILURE;
        // The server wants no more of the request body; its response may
        // still come.
        if (streamOfUser(sud)) |s| s.send_stopped = true;
        self.kick();
        return 0;
    }

    fn onExtendMaxStreamData(_: ?*c.ngtcp2_conn, stream_id: i64, _: u64, user_data: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        const hc = connOf(user_data).h3 orelse return 0;
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
        const rv = bridge.closeStream(self.side(), flags, stream_id, rx_code, tx_code);
        if (rv != 0) return rv;
        if (streamOfUser(sud)) |s| {
            if (!s.body_done) s.reset = true;
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

    fn onH3RecvHeader(_: ?*h.nghttp3_conn, _: i64, token: i32, name: ?*h.nghttp3_rcbuf, value: ?*h.nghttp3_rcbuf, _: u8, _: ?*anyopaque, sud: ?*anyopaque) callconv(.c) c_int {
        const s = streamOfUser(sud) orelse return 0;
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
        if (s.status >= 200) {
            s.head_ready = true;
        } else {
            // 1xx: its fields are not the response's.
            s.headers.clearRetainingCapacity();
            s.status = 0;
        }
        if (fin != 0) s.body_done = true;
        self.kick();
        return 0;
    }

    fn onH3RecvTrailer(_: ?*h.nghttp3_conn, _: i64, _: i32, name: ?*h.nghttp3_rcbuf, value: ?*h.nghttp3_rcbuf, _: u8, _: ?*anyopaque, sud: ?*anyopaque) callconv(.c) c_int {
        const s = streamOfUser(sud) orelse return 0;
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

    status: u16 = 0,
    headers: std.ArrayList(Header) = .empty,
    trailers: std.ArrayList(Header) = .empty,
    head_ready: bool = false,
    /// The stream ended badly (reset, or the connection went).
    reset: bool = false,

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
    protocol_done: bool = false,

    fn create(conn: *ClientConnection, has_body: bool) !*Stream {
        const self = try conn.gpa.create(Stream);
        errdefer conn.gpa.destroy(self);
        self.* = .{
            .conn = conn,
            .arena = .init(conn.gpa),
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

    fn addField(self: *Stream, list: *std.ArrayList(Header), name: []const u8, value: []const u8) !void {
        const a = self.arena.allocator();
        try list.append(a, .{ .name = try a.dupe(u8, name), .value = try a.dupe(u8, value) });
    }

    /// Waits for the response head (`status`, `headers`).
    pub fn waitHead(self: *Stream) !void {
        const conn = self.conn;
        while (true) {
            const gen = conn.gen.load(.acquire);
            conn.lock();
            const ready = self.head_ready;
            const reset = self.reset;
            const gone = conn.state == .closed;
            conn.unlock();
            if (ready) return;
            if (reset) return if (gone) error.ConnectionClosed else error.StreamReset;
            try conn.wait(gen);
        }
    }

    pub fn header(self: *const Stream, name: []const u8) ?[]const u8 {
        for (self.headers.items) |f| if (std.ascii.eqlIgnoreCase(f.name, name)) return f.value;
        return null;
    }

    pub fn trailer(self: *const Stream, name: []const u8) ?[]const u8 {
        for (self.trailers.items) |f| if (std.ascii.eqlIgnoreCase(f.name, name)) return f.value;
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
        self.cancelLocked();
    }

    fn cancelLocked(self: *Stream) void {
        const conn = self.conn;
        if (self.submitted and !self.protocol_done and conn.state != .closed)
            _ = c.ngtcp2_conn_shutdown_stream(conn.q, 0, self.id, h.NGHTTP3_H3_REQUEST_CANCELLED);
        self.reset = true;
        conn.kick();
    }

    /// Done with the stream: an unfinished one is canceled first.
    pub fn release(self: *Stream) void {
        const conn = self.conn;
        conn.lock();
        defer conn.unlock();
        const sent = !self.has_body or self.send_stopped or (self.send_closed and self.out.allSent());
        if (!(self.body_done and sent)) self.cancelLocked();
        self.user_done = true;
        // A stream QUIC never got, or one the connection's end left
        // behind, has no close to wait for.
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
            const reset = self.reset;
            conn.unlock();
            if (done) return error.EndOfStream;
            if (reset) return error.ReadFailed;
            conn.wait(gen) catch return error.ReadFailed;
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
            if (self.reset or self.send_stopped or conn.state == .closed) {
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
            if (n > 0) conn.kick() else conn.wait(gen) catch return error.WriteFailed;
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
