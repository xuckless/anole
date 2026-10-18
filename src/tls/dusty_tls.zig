//! dusty's `tls` module, backed by BoringSSL.
//!
//! dusty (built with `use_tls = true, use_bundled_tls = false`) imports this
//! module as `tls` and drives it exactly as it drives lalinsky/tls.zig: the
//! declarations below are the surface dusty compiles against, and the Reader
//! and Writer adapters follow tls.zig's `Connection.Reader`/`Writer` (MIT,
//! 60d0ced), so dusty's buffer swapping and error descent work unchanged.
//!
//! I/O: each SSL gets a custom BIO that reads and writes dusty's ciphertext
//! `std.Io.Reader`/`Writer` directly. Under zio a BIO read or write yields the
//! coroutine inside `SSL_do_handshake`/`SSL_read`/`SSL_write`, so the TLS code
//! is straight-line and BoringSSL never sees WANT_READ/WANT_WRITE.
//!
//! BoringSSL's error queue is per OS thread. Every SSL call below clears it
//! first and reads it before anything can yield, and zio's pinned scheduling
//! keeps a coroutine on its thread across the yields inside a call.
const std = @import("std");
const c = @import("anole_boringssl_c");

const log = std.log.scoped(.anole_tls);
const Allocator = std.mem.Allocator;

/// Ciphertext read buffer dusty gives the TCP reader. BoringSSL reassembles
/// records itself, so this only batches socket reads (tls.zig needs a whole
/// 16 KiB record here).
pub const input_buffer_len: usize = 8 * 1024;
/// Ciphertext write buffer dusty gives the TCP writer.
pub const output_buffer_len: usize = 8 * 1024;

/// Largest TLS record payload; SSL_write is called with at most this much.
const max_plaintext_len = 16 * 1024;

pub const config = struct {
    /// A certificate chain and private key. On a server listener it also owns
    /// the SSL_CTX that every connection accepted on that listener shares;
    /// on a client it is the identity presented for mutual TLS.
    pub const CertKeyPair = struct {
        server_ctx: *c.SSL_CTX,
        cert: *c.X509,
        /// Intermediates, leaf first excluded.
        chain: []*c.X509,
        key: *c.EVP_PKEY,

        pub fn fromFilePath(
            gpa: Allocator,
            io: std.Io,
            dir: std.Io.Dir,
            cert_path: []const u8,
            key_path: []const u8,
        ) !CertKeyPair {
            const cert_pem = try dir.readFileAlloc(io, cert_path, gpa, .limited(max_pem_len));
            defer gpa.free(cert_pem);
            const key_pem = try dir.readFileAlloc(io, key_path, gpa, .limited(max_pem_len));
            defer {
                std.crypto.secureZero(u8, key_pem);
                gpa.free(key_pem);
            }
            return fromSlice(gpa, io, cert_pem, key_pem);
        }

        /// `cert_pem` holds the leaf certificate followed by any intermediates.
        pub fn fromSlice(gpa: Allocator, io: std.Io, cert_pem: []const u8, key_pem: []const u8) !CertKeyPair {
            _ = io;
            c.ERR_clear_error();
            const cert_bio = c.BIO_new_mem_buf(cert_pem.ptr, @intCast(cert_pem.len)) orelse return error.OutOfMemory;
            defer _ = c.BIO_free(cert_bio);
            const cert = c.PEM_read_bio_X509(cert_bio, null, null, null) orelse {
                logErrors("reading the certificate PEM");
                return error.TlsInvalidCertificate;
            };
            errdefer c.X509_free(cert);

            var chain: std.ArrayList(*c.X509) = .empty;
            errdefer {
                for (chain.items) |x| c.X509_free(x);
                chain.deinit(gpa);
            }
            while (c.PEM_read_bio_X509(cert_bio, null, null, null)) |x| {
                chain.append(gpa, x) catch |err| {
                    c.X509_free(x);
                    return err;
                };
            }
            // The loop ends on "no start line", which is the normal end of the file.
            c.ERR_clear_error();

            const key_bio = c.BIO_new_mem_buf(key_pem.ptr, @intCast(key_pem.len)) orelse return error.OutOfMemory;
            defer _ = c.BIO_free(key_bio);
            const key = c.PEM_read_bio_PrivateKey(key_bio, null, null, null) orelse {
                logErrors("reading the private key PEM");
                return error.TlsInvalidPrivateKey;
            };
            errdefer c.EVP_PKEY_free(key);

            const ctx = try newServerCtx();
            errdefer c.SSL_CTX_free(ctx);
            if (c.SSL_CTX_use_certificate(ctx, cert) != 1) return sslError("SSL_CTX_use_certificate", error.TlsInvalidCertificate);
            for (chain.items) |x| {
                if (c.SSL_CTX_add1_chain_cert(ctx, x) != 1) return sslError("SSL_CTX_add1_chain_cert", error.TlsInvalidCertificate);
            }
            if (c.SSL_CTX_use_PrivateKey(ctx, key) != 1) return sslError("SSL_CTX_use_PrivateKey", error.TlsInvalidPrivateKey);
            if (c.SSL_CTX_check_private_key(ctx) != 1) return sslError("SSL_CTX_check_private_key", error.TlsKeyMismatch);

            return .{
                .server_ctx = ctx,
                .cert = cert,
                .chain = try chain.toOwnedSlice(gpa),
                .key = key,
            };
        }

        pub fn deinit(self: *CertKeyPair, gpa: Allocator) void {
            c.SSL_CTX_free(self.server_ctx);
            c.X509_free(self.cert);
            for (self.chain) |x| c.X509_free(x);
            gpa.free(self.chain);
            c.EVP_PKEY_free(self.key);
            self.* = undefined;
        }
    };

    /// Server handshake options, as dusty builds them (server.zig `initTls`).
    pub const Server = struct {
        auth: ?*CertKeyPair,
        client_auth: ?ClientAuth = null,
        /// Unused: BoringSSL verifies against the wall clock.
        now: std.Io.Timestamp,
        /// Unused: BoringSSL has its own CSPRNG.
        rng: std.Random,
        /// Server preference order. A client whose offer shares nothing with
        /// it is served without ALPN (RFC 7301 allows this), not refused.
        alpn_protocols: []const []const u8 = &.{},
    };

    pub const ClientAuth = struct {
        root_ca: std.crypto.Certificate.Bundle,
        auth_type: enum { request, require } = .require,
    };

    /// Client handshake options, as dusty builds them (client.zig `Connection.init`).
    pub const Client = struct {
        host: []const u8,
        root_ca: std.crypto.Certificate.Bundle,
        insecure_skip_verify: bool = false,
        auth: ?*CertKeyPair = null,
        now: std.Io.Timestamp,
        rng: std.Random,
        alpn_protocols: []const []const u8 = &.{},
    };
};

const max_pem_len = 1024 * 1024;

/// dusty switches on `ReadFailed`/`WriteFailed` ("the cause is on the TCP
/// layer, ask getReadError/getWriteError"), so both are here. A handshake
/// deadline reaches us as a canceled TCP read, recorded on dusty's reader,
/// and comes out as `ReadFailed`, never as `Canceled`.
pub const HandshakeError = error{
    ReadFailed,
    WriteFailed,
    EndOfStream,
    OutOfMemory,
    TlsAlert,
    TlsBadRecordMac,
    TlsCertificateVerifyFailed,
    TlsNoApplicationProtocol,
    TlsInvalidHostname,
    TlsFailure,
};

pub fn server(input: *std.Io.Reader, output: *std.Io.Writer, opt: config.Server) HandshakeError!Connection {
    const auth = opt.auth orelse return error.TlsFailure;
    c.ERR_clear_error();
    const ssl = c.SSL_new(auth.server_ctx) orelse return error.OutOfMemory;
    errdefer c.SSL_free(ssl);
    try attachBio(ssl, input, output);
    c.SSL_set_accept_state(ssl);

    if (opt.client_auth) |ca| {
        try setVerifyStore(ssl, ca.root_ca);
        const mode: c_int = switch (ca.auth_type) {
            .request => c.SSL_VERIFY_PEER,
            .require => c.SSL_VERIFY_PEER | c.SSL_VERIFY_FAIL_IF_NO_PEER_CERT,
        };
        c.SSL_set_verify(ssl, mode, null);
    }

    // alpnSelect (set on the server SSL_CTX) reads the list from here. It
    // runs only inside SSL_do_handshake below, while `alpn` is alive.
    var alpn: []const []const u8 = opt.alpn_protocols;
    _ = c.SSL_set_ex_data(ssl, alpn_ex_index, @ptrCast(&alpn));
    defer _ = c.SSL_set_ex_data(ssl, alpn_ex_index, null);

    try handshake(ssl);
    return .{ .ssl = ssl, .alpn_protocol = selectedAlpn(ssl, opt.alpn_protocols) };
}

pub fn client(input: *std.Io.Reader, output: *std.Io.Writer, opt: config.Client) HandshakeError!Connection {
    const ctx = try clientCtx();
    c.ERR_clear_error();
    const ssl = c.SSL_new(ctx) orelse return error.OutOfMemory;
    errdefer c.SSL_free(ssl);
    try attachBio(ssl, input, output);
    c.SSL_set_connect_state(ssl);

    var host_buf: [256]u8 = undefined;
    if (opt.host.len >= host_buf.len or std.mem.indexOfScalar(u8, opt.host, 0) != null) return error.TlsInvalidHostname;
    const host = std.fmt.bufPrintSentinel(&host_buf, "{s}", .{opt.host}, 0) catch unreachable;
    const host_is_ip = if (std.Io.net.IpAddress.parse(opt.host, 0)) |_| true else |_| false;

    if (opt.insecure_skip_verify) {
        c.SSL_set_verify(ssl, c.SSL_VERIFY_NONE, null);
    } else {
        try setVerifyStore(ssl, opt.root_ca);
        c.SSL_set_verify(ssl, c.SSL_VERIFY_PEER, null);
        const ok = if (host_is_ip)
            c.X509_VERIFY_PARAM_set1_ip_asc(c.SSL_get0_param(ssl), host.ptr)
        else
            c.SSL_set1_host(ssl, host.ptr);
        if (ok != 1) return error.TlsInvalidHostname;
    }
    // RFC 6066: SNI carries host names only, never IP literals.
    if (!host_is_ip and c.SSL_set_tlsext_host_name(ssl, host.ptr) != 1) return error.TlsInvalidHostname;

    if (opt.auth) |id| {
        if (c.SSL_use_certificate(ssl, id.cert) != 1) return sslError("SSL_use_certificate", error.TlsFailure);
        for (id.chain) |x| {
            if (c.SSL_add1_chain_cert(ssl, x) != 1) return sslError("SSL_add1_chain_cert", error.TlsFailure);
        }
        if (c.SSL_use_PrivateKey(ssl, id.key) != 1) return sslError("SSL_use_PrivateKey", error.TlsFailure);
    }

    if (opt.alpn_protocols.len > 0) {
        var wire_buf: [512]u8 = undefined;
        var wire: std.Io.Writer = .fixed(&wire_buf);
        for (opt.alpn_protocols) |p| {
            if (p.len == 0 or p.len > 255) return error.TlsFailure;
            wire.writeByte(@intCast(p.len)) catch return error.TlsFailure;
            wire.writeAll(p) catch return error.TlsFailure;
        }
        const bytes = wire.buffered();
        // Returns 0 on success, unlike most of the API.
        if (c.SSL_set_alpn_protos(ssl, bytes.ptr, bytes.len) != 0) return error.OutOfMemory;
    }

    try handshake(ssl);
    return .{ .ssl = ssl, .alpn_protocol = selectedAlpn(ssl, opt.alpn_protocols) };
}

/// One TLS connection: owns its SSL (and through it the BIO). dusty stores it
/// in place after the handshake and frees it with `deinit` (dusty fork patch:
/// TLS state teardown).
pub const Connection = struct {
    ssl: ?*c.SSL = null,
    /// The negotiated ALPN protocol: one of the strings the caller passed in
    /// `alpn_protocols`, so it outlives the connection.
    alpn_protocol: ?[]const u8 = null,

    // Inert; only dusty's own test fixture sets them
    // (`tls.Connection{ .input = undefined, .output = undefined, .cipher = undefined }`).
    input: *std.Io.Reader = undefined,
    output: *std.Io.Writer = undefined,
    cipher: ?*anyopaque = null,

    pub const ReadError = error{
        ReadFailed,
        TlsConnectionTruncated,
        TlsBadRecordMac,
        TlsAlert,
        TlsFailure,
    };
    pub const WriteError = error{ WriteFailed, TlsFailure };

    pub fn deinit(self: *Connection) void {
        if (self.ssl) |ssl| c.SSL_free(ssl);
        self.ssl = null;
    }

    /// Sends close_notify. Best effort: the peer may already be gone.
    pub fn close(self: *Connection) void {
        const ssl = self.ssl orelse return;
        c.ERR_clear_error();
        _ = c.SSL_shutdown(ssl);
        c.ERR_clear_error();
    }

    /// Cleartext into `buf`; 0 means the peer ended the stream, with
    /// close_notify or by closing the transport between records.
    ///
    /// A transport EOF without close_notify is taken as a clean end, as
    /// tls.zig does by default: many peers skip close_notify, and HTTP's own
    /// framing (Content-Length, chunked) detects a truncated message.
    /// BoringSSL does not say whether the EOF fell inside a record, so
    /// `TlsConnectionTruncated` is never reported.
    fn read(self: *Connection, buf: []u8) ReadError!usize {
        const ssl = self.ssl.?;
        const len: c_int = @intCast(@min(buf.len, std.math.maxInt(c_int)));
        c.ERR_clear_error();
        const rc = c.SSL_read(ssl, buf.ptr, len);
        if (rc > 0) return @intCast(rc);
        const bio = bioState(ssl);
        switch (c.SSL_get_error(ssl, rc)) {
            c.SSL_ERROR_ZERO_RETURN => return 0,
            c.SSL_ERROR_SYSCALL => {
                if (bio.read_failed) return error.ReadFailed;
                if (bio.eof) return 0;
                return error.TlsFailure;
            },
            else => return switch (queuedError("SSL_read")) {
                error.TlsBadRecordMac => error.TlsBadRecordMac,
                error.TlsAlert => error.TlsAlert,
                else => error.TlsFailure,
            },
        }
    }

    /// Writes all of `bytes` as TLS records into the ciphertext writer,
    /// without flushing it.
    fn writeAll(self: *Connection, bytes: []const u8) WriteError!void {
        const ssl = self.ssl.?;
        var rest = bytes;
        while (rest.len > 0) {
            const n = @min(rest.len, max_plaintext_len);
            c.ERR_clear_error();
            const rc = c.SSL_write(ssl, rest.ptr, @intCast(n));
            if (rc <= 0) {
                if (c.SSL_get_error(ssl, rc) == c.SSL_ERROR_SYSCALL and bioState(ssl).write_failed) return error.WriteFailed;
                logErrors("SSL_write");
                return error.TlsFailure;
            }
            rest = rest[@intCast(rc)..];
        }
    }

    fn flush(self: *Connection) WriteError!void {
        bioState(self.ssl.?).output.flush() catch return error.WriteFailed;
    }

    /// dusty passes an empty buffer and later swaps `interface.buffer`,
    /// `seek` and `end` in place, so only `stream` is implemented and the
    /// default `rebase` is kept.
    pub const Reader = struct {
        conn: *Connection,
        interface: std.Io.Reader,
        err: ?ReadError = null,

        fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
            const self: *Reader = @fieldParentPtr("interface", r);
            const dest = limit.slice(try w.writableSliceGreedy(1));
            const n = self.conn.read(dest) catch |err| {
                self.err = err;
                return error.ReadFailed;
            };
            if (n == 0) return error.EndOfStream;
            w.advance(n);
            return n;
        }
    };

    pub fn reader(self: *Connection, buffer: []u8) Reader {
        return .{
            .conn = self,
            .interface = .{ .vtable = &.{ .stream = Reader.stream }, .buffer = buffer, .seek = 0, .end = 0 },
        };
    }

    pub const Writer = struct {
        conn: *Connection,
        interface: std.Io.Writer,
        err: ?WriteError = null,

        /// The buffered bytes, then each slice of `data`, then the last one
        /// `splat` times, then one flush of the ciphertext writer, so a
        /// response leaves in as few socket writes as possible. Returns the
        /// bytes consumed from `data` (tls.zig `Connection.Writer.drain`).
        fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *Writer = @fieldParentPtr("interface", w);
            try self.writeAll(w.buffered());
            w.end = 0;

            var n: usize = 0;
            if (data.len > 0) {
                for (data[0 .. data.len - 1]) |bytes| {
                    try self.writeAll(bytes);
                    n += bytes.len;
                }
                const pattern = data[data.len - 1];
                switch (pattern.len) {
                    0 => {},
                    1 => {
                        var chunk: [max_plaintext_len]u8 = undefined;
                        @memset(&chunk, pattern[0]);
                        var remaining = splat;
                        while (remaining > 0) {
                            const len = @min(remaining, chunk.len);
                            try self.writeAll(chunk[0..len]);
                            remaining -= len;
                        }
                        n += splat;
                    },
                    else => for (0..splat) |_| {
                        try self.writeAll(pattern);
                        n += pattern.len;
                    },
                }
            }
            self.conn.flush() catch |err| {
                self.err = err;
                return error.WriteFailed;
            };
            return n;
        }

        fn writeAll(self: *Writer, bytes: []const u8) std.Io.Writer.Error!void {
            self.conn.writeAll(bytes) catch |err| {
                self.err = err;
                return error.WriteFailed;
            };
        }
    };

    pub fn writer(self: *Connection, buffer: []u8) Writer {
        return .{
            .conn = self,
            .interface = .{ .vtable = &.{ .drain = Writer.drain }, .buffer = buffer, .end = 0 },
        };
    }
};

// ---------------------------------------------------------------------------
// Handshake helpers

fn handshake(ssl: *c.SSL) HandshakeError!void {
    c.ERR_clear_error();
    const rc = c.SSL_do_handshake(ssl);
    if (rc == 1) return;
    const bio = bioState(ssl);
    switch (c.SSL_get_error(ssl, rc)) {
        c.SSL_ERROR_SYSCALL => {
            if (bio.read_failed) return error.ReadFailed;
            if (bio.write_failed) return error.WriteFailed;
            if (bio.eof) return error.EndOfStream;
            return error.TlsFailure;
        },
        c.SSL_ERROR_ZERO_RETURN => return error.EndOfStream,
        else => {
            const err = queuedError("SSL_do_handshake");
            // A verification failure is pushed with the reason code
            // SSL_R_CERTIFICATE_VERIFY_FAILED; the X.509 detail is here.
            if (err == error.TlsCertificateVerifyFailed) {
                const v = c.SSL_get_verify_result(ssl);
                log.debug("certificate verification failed: {s}", .{std.mem.span(c.X509_verify_cert_error_string(v))});
            }
            return err;
        },
    }
}

/// The caller's string for what ALPN selected, so it outlives the SSL.
fn selectedAlpn(ssl: *c.SSL, offered: []const []const u8) ?[]const u8 {
    var proto: [*c]const u8 = null;
    var len: c_uint = 0;
    c.SSL_get0_alpn_selected(ssl, &proto, &len);
    if (len == 0) return null;
    const got = proto[0..len];
    for (offered) |p| if (std.mem.eql(u8, p, got)) return p;
    return null;
}

/// Index 0 is BoringSSL's reserved "app data" slot, which nothing else uses
/// on these SSL objects.
const alpn_ex_index = 0;

/// Walks the server's list (from the SSL's ex data) in preference order and
/// picks the first protocol the client offered. No overlap, or no list, is
/// NOACK: the handshake continues without ALPN.
fn alpnSelect(
    ssl: ?*c.SSL,
    out: [*c][*c]const u8,
    out_len: [*c]u8,
    in: [*c]const u8,
    in_len: c_uint,
    arg: ?*anyopaque,
) callconv(.c) c_int {
    _ = arg;
    const list_ptr = c.SSL_get_ex_data(ssl, alpn_ex_index) orelse return c.SSL_TLSEXT_ERR_NOACK;
    const prefs: *const []const []const u8 = @ptrCast(@alignCast(list_ptr));
    const offered = in[0..in_len];
    for (prefs.*) |want| {
        var i: usize = 0;
        while (i < offered.len) {
            const n = offered[i];
            if (i + 1 + n > offered.len) break;
            const proto = offered[i + 1 ..][0..n];
            if (std.mem.eql(u8, proto, want)) {
                out.* = proto.ptr;
                out_len.* = n;
                return c.SSL_TLSEXT_ERR_OK;
            }
            i += 1 + n;
        }
    }
    return c.SSL_TLSEXT_ERR_NOACK;
}

fn newServerCtx() !*c.SSL_CTX {
    const ctx = c.SSL_CTX_new(c.TLS_method()) orelse return error.OutOfMemory;
    errdefer c.SSL_CTX_free(ctx);
    if (c.SSL_CTX_set_min_proto_version(ctx, c.TLS1_2_VERSION) != 1) return error.TlsFailure;
    // Idle keep-alive connections give their record buffers back.
    _ = c.SSL_CTX_set_mode(ctx, c.SSL_MODE_RELEASE_BUFFERS);
    // Resumption through stateless session tickets only. The stateful cache
    // holds up to 20k sessions per listener behind one lock that every
    // executor thread would share.
    _ = c.SSL_CTX_set_session_cache_mode(ctx, c.SSL_SESS_CACHE_OFF);
    c.SSL_CTX_set_alpn_select_cb(ctx, alpnSelect, null);
    return ctx;
}

// ---------------------------------------------------------------------------
// Process-wide state: the BIO method, the client SSL_CTX, the trust stores.
// Created on first use under one spin lock; the critical sections are short
// except building a trust store, which happens once per bundle.

var global_lock: std.atomic.Mutex = .unlocked;

fn lockGlobal() void {
    while (!global_lock.tryLock()) std.atomic.spinLoopHint();
}

var client_ctx: ?*c.SSL_CTX = null;

/// One SSL_CTX for every outbound connection; per-connection settings
/// (verification, host name, client certificate, ALPN) go on the SSL.
fn clientCtx() HandshakeError!*c.SSL_CTX {
    lockGlobal();
    defer global_lock.unlock();
    if (client_ctx) |ctx| return ctx;
    const ctx = c.SSL_CTX_new(c.TLS_method()) orelse return error.OutOfMemory;
    if (c.SSL_CTX_set_min_proto_version(ctx, c.TLS1_2_VERSION) != 1) {
        c.SSL_CTX_free(ctx);
        return error.TlsFailure;
    }
    _ = c.SSL_CTX_set_mode(ctx, c.SSL_MODE_RELEASE_BUFFERS);
    client_ctx = ctx;
    return ctx;
}

/// dusty hands over its trust store as a `std.crypto.Certificate.Bundle`
/// by value on every handshake. Converting ~150 system roots per connection
/// would be far too slow, so each distinct bundle becomes an X509_STORE once.
/// The key is the bundle's contents (hash and length), not its address,
/// because a freed bundle's memory can be reused for a different one.
/// Planned dusty fork patch P4 (load the trust store once through this
/// module) removes the conversion.
const StoreEntry = struct { hash: u64, len: usize, store: *c.X509_STORE };
var store_cache: [8]?StoreEntry = @splat(null);
var store_cache_next: usize = 0;

fn setVerifyStore(ssl: *c.SSL, bundle: std.crypto.Certificate.Bundle) HandshakeError!void {
    const store = try trustStore(bundle);
    defer c.X509_STORE_free(store);
    if (c.SSL_set1_verify_cert_store(ssl, store) != 1) return error.OutOfMemory;
}

/// Returns a new reference; the caller frees it.
fn trustStore(bundle: std.crypto.Certificate.Bundle) HandshakeError!*c.X509_STORE {
    const der = bundle.bytes.items;
    const hash = std.hash.Wyhash.hash(0, der);
    lockGlobal();
    defer global_lock.unlock();
    for (store_cache) |entry| {
        const e = entry orelse continue;
        if (e.hash == hash and e.len == der.len) {
            _ = c.X509_STORE_up_ref(e.store);
            return e.store;
        }
    }

    const store = c.X509_STORE_new() orelse return error.OutOfMemory;
    // The bundle is DER certificates back to back.
    var p: [*c]const u8 = der.ptr;
    const end = der.ptr + der.len;
    while (p != end) {
        const x = c.d2i_X509(null, &p, @intCast(end - p)) orelse break;
        defer c.X509_free(x);
        _ = c.X509_STORE_add_cert(store, x);
    }
    c.ERR_clear_error();

    const slot = &store_cache[store_cache_next];
    store_cache_next = (store_cache_next + 1) % store_cache.len;
    if (slot.*) |old| c.X509_STORE_free(old.store);
    slot.* = .{ .hash = hash, .len = der.len, .store = store };
    _ = c.X509_STORE_up_ref(store);
    return store;
}

// ---------------------------------------------------------------------------
// The BIO over std.Io

/// Per-SSL BIO state, heap-allocated because the Connection holding the SSL
/// is copied after the handshake. Freed by the BIO's destroy callback when
/// SSL_free releases the BIO.
const BioState = struct {
    input: *std.Io.Reader,
    output: *std.Io.Writer,
    /// What the last read or write saw, for mapping SSL_ERROR_SYSCALL.
    read_failed: bool = false,
    write_failed: bool = false,
    eof: bool = false,
};

var bio_method: ?*c.BIO_METHOD = null;

fn bioMethod() HandshakeError!*c.BIO_METHOD {
    lockGlobal();
    defer global_lock.unlock();
    if (bio_method) |m| return m;
    const m = c.BIO_meth_new(0, "anole std.Io") orelse return error.OutOfMemory;
    if (c.BIO_meth_set_read(m, bioRead) != 1 or
        c.BIO_meth_set_write(m, bioWrite) != 1 or
        c.BIO_meth_set_ctrl(m, bioCtrl) != 1 or
        c.BIO_meth_set_destroy(m, bioDestroy) != 1)
    {
        c.BIO_meth_free(m);
        return error.OutOfMemory;
    }
    bio_method = m;
    return m;
}

fn attachBio(ssl: *c.SSL, input: *std.Io.Reader, output: *std.Io.Writer) HandshakeError!void {
    const state = std.heap.c_allocator.create(BioState) catch return error.OutOfMemory;
    state.* = .{ .input = input, .output = output };
    const bio = c.BIO_new(try bioMethod()) orelse {
        std.heap.c_allocator.destroy(state);
        return error.OutOfMemory;
    };
    c.BIO_set_data(bio, state);
    c.BIO_set_init(bio, 1);
    // The SSL takes the one reference for both directions.
    c.SSL_set_bio(ssl, bio, bio);
}

fn bioState(ssl: *c.SSL) *BioState {
    return @ptrCast(@alignCast(c.BIO_get_data(c.SSL_get_rbio(ssl)).?));
}

fn bioRead(bio: ?*c.BIO, out: [*c]u8, len: c_int) callconv(.c) c_int {
    const state: *BioState = @ptrCast(@alignCast(c.BIO_get_data(bio).?));
    c.BIO_clear_retry_flags(bio);
    // Whatever is buffered, or one read from the socket: never wait for more
    // than the peer has sent (BoringSSL asks for up to a whole record).
    const got = state.input.peekGreedy(1) catch |err| switch (err) {
        error.EndOfStream => {
            state.eof = true;
            return 0;
        },
        error.ReadFailed => {
            state.read_failed = true;
            return -1;
        },
    };
    const n = @min(got.len, @as(usize, @intCast(len)));
    @memcpy(out[0..n], got[0..n]);
    state.input.toss(n);
    return @intCast(n);
}

fn bioWrite(bio: ?*c.BIO, in: [*c]const u8, len: c_int) callconv(.c) c_int {
    const state: *BioState = @ptrCast(@alignCast(c.BIO_get_data(bio).?));
    c.BIO_clear_retry_flags(bio);
    state.output.writeAll(in[0..@intCast(len)]) catch {
        state.write_failed = true;
        return -1;
    };
    return len;
}

fn bioCtrl(bio: ?*c.BIO, cmd: c_int, larg: c_long, parg: ?*anyopaque) callconv(.c) c_long {
    _ = larg;
    _ = parg;
    switch (cmd) {
        c.BIO_CTRL_FLUSH => {
            const state: *BioState = @ptrCast(@alignCast(c.BIO_get_data(bio).?));
            state.output.flush() catch {
                state.write_failed = true;
                return 0;
            };
            return 1;
        },
        else => return 0,
    }
}

fn bioDestroy(bio: ?*c.BIO) callconv(.c) c_int {
    if (c.BIO_get_data(bio)) |data| {
        const state: *BioState = @ptrCast(@alignCast(data));
        std.heap.c_allocator.destroy(state);
        c.BIO_set_data(bio, null);
    }
    return 1;
}

// ---------------------------------------------------------------------------
// Errors

fn errLib(packed_error: u32) u32 {
    return packed_error >> 24;
}
fn errReason(packed_error: u32) u32 {
    return packed_error & 0xfff;
}

/// Maps the oldest queued error to an error code, logs the whole queue at
/// debug level, and empties it.
fn queuedError(what: []const u8) HandshakeError {
    const first = c.ERR_peek_error();
    logErrors(what);
    if (first == 0 or errLib(first) != c.ERR_LIB_SSL) return error.TlsFailure;
    const reason = errReason(first);
    if (reason >= c.SSL_AD_REASON_OFFSET) return error.TlsAlert;
    return switch (reason) {
        c.SSL_R_DECRYPTION_FAILED_OR_BAD_RECORD_MAC => error.TlsBadRecordMac,
        c.SSL_R_CERTIFICATE_VERIFY_FAILED => error.TlsCertificateVerifyFailed,
        c.SSL_R_NO_APPLICATION_PROTOCOL => error.TlsNoApplicationProtocol,
        else => error.TlsFailure,
    };
}

fn sslError(what: []const u8, err: anytype) @TypeOf(err) {
    logErrors(what);
    return err;
}

fn logErrors(what: []const u8) void {
    var first = true;
    while (true) {
        const code = c.ERR_get_error();
        if (code == 0) break;
        if (first) log.debug("{s} failed", .{what});
        first = false;
        var buf: [256]u8 = undefined;
        _ = c.ERR_error_string_n(code, &buf, buf.len);
        log.debug("  {s}", .{std.mem.sliceTo(&buf, 0)});
    }
}
