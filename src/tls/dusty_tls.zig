//! dusty's `tls` module, backed by BoringSSL.
//!
//! dusty (built with `use_tls = true, use_bundled_tls = false`) imports this
//! module as `tls` and drives it exactly as it drives lalinsky/tls.zig: the
//! declarations below are the surface dusty compiles against, and the Reader
//! and Writer adapters follow tls.zig's `Connection.Reader`/`Writer` (MIT,
//! 60d0ced), so dusty's buffer swapping and error descent work unchanged.
//!
//! I/O: one reader task and one writer task may use a connection at the same
//! time, possibly on different executor threads (HTTP/2 does), which is the
//! guarantee tls.zig gives. BoringSSL allows one caller per SSL at a time, so:
//!
//! - every `SSL_*` call runs under the connection's spin lock, which is never
//!   held across I/O, and BoringSSL's per-thread error queue is cleared and
//!   read inside it. `SSL_read`, `SSL_write`, `SSL_do_handshake` and
//!   `SSL_shutdown` clear the queue themselves on entry (ssl_lib.cc
//!   `ssl_reset_error_state`), so it is cleared here only after a call that
//!   failed: `ERR_clear_error` walks all 16 slots and frees each, and calling
//!   it around every record was a tenth of a TLS request's CPU;
//! - the BIO never waits. Its read callback hands over only ciphertext that the
//!   reader task already has buffered (WANT_READ otherwise, and the reader
//!   refills from the socket with the lock released); its write callback
//!   appends to a pending buffer that only the writer side sends, so ciphertext
//!   leaves in the order BoringSSL produced it. Output that `SSL_read` itself
//!   produces (alerts, KeyUpdate) goes out with the next write.
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

        /// A certificate reload (dusty fork, `Server.reloadTls`): this new
        /// pair takes over the session ticket keys of the `old` one it
        /// replaces, so tickets issued before the reload still resume.
        pub fn carryOver(self: *CertKeyPair, old: *const CertKeyPair) void {
            carryTicketKeys(self.server_ctx, old.server_ctx);
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
        /// `root_ca` loaded once (dusty sets it when the module has
        /// `TrustStore`); without it each handshake looks `root_ca` up.
        trust: ?*const TrustStore = null,
    };

    /// Client handshake options, as dusty builds them (client.zig `Connection.init`).
    pub const Client = struct {
        host: []const u8,
        root_ca: std.crypto.Certificate.Bundle,
        /// `root_ca` loaded once, as in `ClientAuth.trust`.
        trust: ?*const TrustStore = null,
        /// A store from `clientStore`, for clients outside dusty; taken over
        /// `trust` and `root_ca`.
        store: ?*c.X509_STORE = null,
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
    TlsBadRecordMac,
    TlsCertificateVerifyFailed,
    TlsNoApplicationProtocol,
    TlsInvalidHostname,
    TlsFailure,
} || AlertError || VerifyError;

/// An alert the peer sent, by tls.zig's names (protocol.zig `toError`), so
/// code written against tls.zig sees the same errors.
pub const AlertError = error{
    TlsAlertUnexpectedMessage,
    TlsAlertBadRecordMac,
    TlsAlertRecordOverflow,
    TlsAlertHandshakeFailure,
    TlsAlertBadCertificate,
    TlsAlertUnsupportedCertificate,
    TlsAlertCertificateRevoked,
    TlsAlertCertificateExpired,
    TlsAlertCertificateUnknown,
    TlsAlertIllegalParameter,
    TlsAlertUnknownCa,
    TlsAlertAccessDenied,
    TlsAlertDecodeError,
    TlsAlertDecryptError,
    TlsAlertProtocolVersion,
    TlsAlertInsufficientSecurity,
    TlsAlertInternalError,
    TlsAlertInappropriateFallback,
    TlsAlertMissingExtension,
    TlsAlertUnsupportedExtension,
    TlsAlertUnrecognizedName,
    TlsAlertBadCertificateStatusResponse,
    TlsAlertUnknownPskIdentity,
    TlsAlertCertificateRequired,
    TlsAlertNoApplicationProtocol,
    TlsAlertUnknown,
};

/// Why the peer's certificate did not verify, by the names of
/// `std.crypto.Certificate` (what tls.zig reports); anything else is
/// `TlsCertificateVerifyFailed`.
pub const VerifyError = error{
    CertificateIssuerNotFound,
    CertificateExpired,
    CertificateNotYetValid,
    CertificateHostMismatch,
    CertificateSignatureInvalid,
};

fn alertError(description: c_int) AlertError {
    return switch (description) {
        c.SSL_AD_UNEXPECTED_MESSAGE => error.TlsAlertUnexpectedMessage,
        c.SSL_AD_BAD_RECORD_MAC => error.TlsAlertBadRecordMac,
        c.SSL_AD_RECORD_OVERFLOW => error.TlsAlertRecordOverflow,
        c.SSL_AD_HANDSHAKE_FAILURE => error.TlsAlertHandshakeFailure,
        c.SSL_AD_BAD_CERTIFICATE => error.TlsAlertBadCertificate,
        c.SSL_AD_UNSUPPORTED_CERTIFICATE => error.TlsAlertUnsupportedCertificate,
        c.SSL_AD_CERTIFICATE_REVOKED => error.TlsAlertCertificateRevoked,
        c.SSL_AD_CERTIFICATE_EXPIRED => error.TlsAlertCertificateExpired,
        c.SSL_AD_CERTIFICATE_UNKNOWN => error.TlsAlertCertificateUnknown,
        c.SSL_AD_ILLEGAL_PARAMETER => error.TlsAlertIllegalParameter,
        c.SSL_AD_UNKNOWN_CA => error.TlsAlertUnknownCa,
        c.SSL_AD_ACCESS_DENIED => error.TlsAlertAccessDenied,
        c.SSL_AD_DECODE_ERROR => error.TlsAlertDecodeError,
        c.SSL_AD_DECRYPT_ERROR => error.TlsAlertDecryptError,
        c.SSL_AD_PROTOCOL_VERSION => error.TlsAlertProtocolVersion,
        c.SSL_AD_INSUFFICIENT_SECURITY => error.TlsAlertInsufficientSecurity,
        c.SSL_AD_INTERNAL_ERROR => error.TlsAlertInternalError,
        c.SSL_AD_INAPPROPRIATE_FALLBACK => error.TlsAlertInappropriateFallback,
        c.SSL_AD_MISSING_EXTENSION => error.TlsAlertMissingExtension,
        c.SSL_AD_UNSUPPORTED_EXTENSION => error.TlsAlertUnsupportedExtension,
        c.SSL_AD_UNRECOGNIZED_NAME => error.TlsAlertUnrecognizedName,
        c.SSL_AD_BAD_CERTIFICATE_STATUS_RESPONSE => error.TlsAlertBadCertificateStatusResponse,
        c.SSL_AD_UNKNOWN_PSK_IDENTITY => error.TlsAlertUnknownPskIdentity,
        c.SSL_AD_CERTIFICATE_REQUIRED => error.TlsAlertCertificateRequired,
        c.SSL_AD_NO_APPLICATION_PROTOCOL => error.TlsAlertNoApplicationProtocol,
        else => error.TlsAlertUnknown,
    };
}

fn verifyError(result: c_long) HandshakeError {
    return switch (result) {
        c.X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT,
        c.X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT_LOCALLY,
        c.X509_V_ERR_UNABLE_TO_VERIFY_LEAF_SIGNATURE,
        c.X509_V_ERR_DEPTH_ZERO_SELF_SIGNED_CERT,
        c.X509_V_ERR_SELF_SIGNED_CERT_IN_CHAIN,
        => error.CertificateIssuerNotFound,
        c.X509_V_ERR_CERT_HAS_EXPIRED => error.CertificateExpired,
        c.X509_V_ERR_CERT_NOT_YET_VALID => error.CertificateNotYetValid,
        c.X509_V_ERR_HOSTNAME_MISMATCH, c.X509_V_ERR_IP_ADDRESS_MISMATCH => error.CertificateHostMismatch,
        c.X509_V_ERR_CERT_SIGNATURE_FAILURE => error.CertificateSignatureInvalid,
        else => error.TlsCertificateVerifyFailed,
    };
}

/// `err` if it is an alert the peer sent, for the read path's narrower set.
fn asAlert(err: HandshakeError) ?AlertError {
    return switch (err) {
        inline else => |e| if (comptime inSet(AlertError, e)) @errorCast(e) else null,
    };
}

fn inSet(comptime Set: type, comptime err: anyerror) bool {
    @setEvalBranchQuota(100_000);
    for (@typeInfo(Set).error_set.error_names.?) |name| if (std.mem.eql(u8, name, @errorName(err))) return true;
    return false;
}

pub fn server(input: *std.Io.Reader, output: *std.Io.Writer, opt: config.Server) HandshakeError!Connection {
    const auth = opt.auth orelse return error.TlsFailure;
    c.ERR_clear_error();
    const ssl = c.SSL_new(auth.server_ctx) orelse return error.OutOfMemory;
    errdefer c.SSL_free(ssl);
    const shared = try attachShared(ssl, input, output);
    c.SSL_set_accept_state(ssl);

    if (opt.client_auth) |ca| {
        // The CertificateRequest also names the acceptable CAs, so a client
        // holding several certificates can pick the right one.
        const trust = if (ca.trust) |t| try t.share(true) else try trustStore(ca.root_ca, true);
        defer c.X509_STORE_free(trust.store);
        if (c.SSL_set1_verify_cert_store(ssl, trust.store) != 1) return error.OutOfMemory;
        c.SSL_set0_client_CAs(ssl, trust.names);
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

    try handshake(shared);
    return .{
        .shared = shared,
        .alpn_protocol = selectedAlpn(ssl, opt.alpn_protocols),
        .peer_certificate = peerLeaf(ssl),
    };
}

/// The peer's leaf certificate (DER), if it sent one: on a server, the
/// first of `SSL_get0_peer_certificates` (BoringSSL keeps the leaf there,
/// unlike `SSL_get_peer_cert_chain`). Owned by the SSL's session, which a
/// server never replaces (no renegotiation), so valid until `SSL_free`.
pub fn peerLeaf(ssl: *const c.SSL) ?[]const u8 {
    const certs = c.SSL_get0_peer_certificates(ssl) orelse return null;
    if (c.sk_CRYPTO_BUFFER_num(certs) == 0) return null;
    const leaf = c.sk_CRYPTO_BUFFER_value(certs, 0);
    return c.CRYPTO_BUFFER_data(leaf)[0..c.CRYPTO_BUFFER_len(leaf)];
}

pub fn client(input: *std.Io.Reader, output: *std.Io.Writer, opt: config.Client) HandshakeError!Connection {
    const ctx = try clientCtx();
    c.ERR_clear_error();
    const ssl = c.SSL_new(ctx) orelse return error.OutOfMemory;
    errdefer c.SSL_free(ssl);
    const shared = try attachShared(ssl, input, output);
    c.SSL_set_connect_state(ssl);

    var host_buf: [256]u8 = undefined;
    if (opt.host.len >= host_buf.len or std.mem.indexOfScalar(u8, opt.host, 0) != null) return error.TlsInvalidHostname;
    const host = std.fmt.bufPrintSentinel(&host_buf, "{s}", .{opt.host}, 0) catch unreachable;
    const host_is_ip = if (std.Io.net.IpAddress.parse(opt.host, 0)) |_| true else |_| false;

    if (opt.insecure_skip_verify) {
        c.SSL_set_verify(ssl, c.SSL_VERIFY_NONE, null);
    } else {
        if (opt.store orelse if (opt.trust) |t| t.store else null) |store| {
            if (c.SSL_set1_verify_cert_store(ssl, store) != 1) return error.OutOfMemory;
        } else try setVerifyStore(ssl, opt.root_ca);
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

    try handshake(shared);
    return .{ .shared = shared, .alpn_protocol = selectedAlpn(ssl, opt.alpn_protocols) };
}

/// One TLS connection: owns its SSL (and through it the BIO and the shared
/// state). dusty stores it in place after the handshake and frees it with
/// `deinit` (dusty fork patch: TLS state teardown).
///
/// After the handshake, one task may read while another writes. `deinit`
/// and `close` must not overlap either of them: join both first.
pub const Connection = struct {
    shared: ?*Shared = null,
    /// The negotiated ALPN protocol: one of the strings the caller passed in
    /// `alpn_protocols`, so it outlives the connection.
    alpn_protocol: ?[]const u8 = null,
    /// A server's verified client certificate (mutual TLS); see
    /// `peerCertificate`.
    peer_certificate: ?[]const u8 = null,

    // Inert; only dusty's own test fixture sets them
    // (`tls.Connection{ .input = undefined, .output = undefined, .cipher = undefined }`).
    input: *std.Io.Reader = undefined,
    output: *std.Io.Writer = undefined,
    cipher: ?*anyopaque = null,

    pub const ReadError = error{
        ReadFailed,
        TlsConnectionTruncated,
        TlsBadRecordMac,
        TlsFailure,
    } || AlertError;
    pub const WriteError = error{ WriteFailed, TlsFailure };

    /// The client's certificate (the leaf, DER) on a server connection
    /// whose handshake verified one, else null. dusty fork seam: dusty puts
    /// it in `Request.peer_certificate`. Valid until `deinit`.
    pub fn peerCertificate(self: *const Connection) ?[]const u8 {
        return self.peer_certificate;
    }

    /// Frees the SSL, which frees the BIO and the shared state with it.
    pub fn deinit(self: *Connection) void {
        if (self.shared) |sh| c.SSL_free(sh.ssl);
        self.shared = null;
    }

    /// Sends close_notify. Best effort: the peer may already be gone. Belongs
    /// to the writing side.
    pub fn close(self: *Connection) void {
        const sh = self.shared orelse return;
        sh.lock();
        // SSL_shutdown clears the error queue on entry.
        if (c.SSL_shutdown(sh.ssl) < 0) c.ERR_clear_error();
        sh.unlock();
        sh.sendPending() catch return;
        sh.output.flush() catch {};
    }

    /// Cleartext into `buf`; 0 means the peer ended the stream, with
    /// close_notify or by closing the transport between records. Belongs to
    /// the reading side.
    ///
    /// A transport EOF without close_notify is taken as a clean end, as
    /// tls.zig does by default: many peers skip close_notify, and HTTP's own
    /// framing (Content-Length, chunked) detects a truncated message.
    /// BoringSSL does not say whether the EOF fell inside a record, so
    /// `TlsConnectionTruncated` is never reported.
    fn read(self: *Connection, buf: []u8) ReadError!usize {
        const sh = self.shared.?;
        const len: c_int = @intCast(@min(buf.len, std.math.maxInt(c_int)));
        while (true) {
            sh.lock();
            // Nothing buffered on either side of BoringSSL: wait for the
            // socket first, rather than call SSL_read only to hear
            // WANT_READ. That is the usual state between requests, and it
            // saves an SSL_read (and its error-queue reset) per request.
            if (sh.input.bufferedLen() == 0 and !sh.input_eof and c.SSL_has_pending(sh.ssl) == 0) {
                sh.unlock();
                sh.fill() catch |err| switch (err) {
                    error.ReadFailed => return error.ReadFailed,
                };
                continue;
            }
            // SSL_read empties the error queue on entry.
            const rc = c.SSL_read(sh.ssl, buf.ptr, len);
            // It may have queued handshake messages (a KeyUpdate reply) for
            // the writing side to send.
            sh.write_owed = true;
            const code = if (rc > 0) c.SSL_ERROR_NONE else c.SSL_get_error(sh.ssl, rc);
            const failure: ?HandshakeError = if (code == c.SSL_ERROR_SSL) queuedError("SSL_read") else null;
            if (rc <= 0) c.ERR_clear_error();
            const eof = sh.input_eof;
            sh.unlock();

            switch (code) {
                c.SSL_ERROR_NONE => return @intCast(rc),
                c.SSL_ERROR_WANT_READ => sh.fill() catch |err| switch (err) {
                    error.ReadFailed => return error.ReadFailed,
                },
                c.SSL_ERROR_ZERO_RETURN => return 0,
                c.SSL_ERROR_SYSCALL => return if (eof) 0 else error.TlsFailure,
                else => {
                    const f = failure orelse return error.TlsFailure;
                    if (asAlert(f)) |alert| return alert;
                    return if (f == error.TlsBadRecordMac) error.TlsBadRecordMac else error.TlsFailure;
                },
            }
        }
    }

    /// Encrypts all of `bytes` and hands the records to the ciphertext
    /// writer, without flushing it. Belongs to the writing side.
    fn writeAll(self: *Connection, bytes: []const u8) WriteError!void {
        const sh = self.shared.?;
        var rest = bytes;
        while (rest.len > 0) {
            const n = @min(rest.len, max_plaintext_len);
            sh.lock();
            // SSL_write empties the error queue on entry, and a non-empty
            // one sends whatever the reading side queued ahead of its record.
            const rc = c.SSL_write(sh.ssl, rest.ptr, @intCast(n));
            if (rc > 0) {
                sh.write_owed = false;
            } else {
                logErrors("SSL_write");
                c.ERR_clear_error();
            }
            sh.unlock();
            // The memory BIO cannot fail a write, so any failure is TLS-level.
            if (rc <= 0) return error.TlsFailure;
            rest = rest[@intCast(rc)..];
            try sh.sendPending();
        }
    }

    /// Sends everything queued. A zero-length SSL_write first makes
    /// BoringSSL emit anything the reading side queued without writing it
    /// (a KeyUpdate reply rides on the next write; ssl.h `SSL_write`), so a
    /// connection that only reads still answers its peer. It is needed only
    /// when SSL_read has run since the last SSL_write that sent a record,
    /// which already carried anything queued before it: a response written
    /// and flushed costs one SSL_write, not two.
    fn flush(self: *Connection) WriteError!void {
        const sh = self.shared.?;
        sh.lock();
        if (sh.write_owed) {
            // Returns 0 for success as well as for some failures.
            _ = c.SSL_write(sh.ssl, "", 0);
            if (c.ERR_peek_error() != 0) c.ERR_clear_error();
            sh.write_owed = false;
        }
        sh.unlock();
        try sh.sendPending();
        sh.output.flush() catch return error.WriteFailed;
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

fn handshake(sh: *Shared) HandshakeError!void {
    while (true) {
        sh.lock();
        // SSL_do_handshake empties the error queue on entry.
        const rc = c.SSL_do_handshake(sh.ssl);
        const code = if (rc == 1) c.SSL_ERROR_NONE else c.SSL_get_error(sh.ssl, rc);
        var failure: ?HandshakeError = if (code == c.SSL_ERROR_SSL) queuedError("SSL_do_handshake") else null;
        if (failure != null and failure.? == error.TlsCertificateVerifyFailed) {
            // The reason code is SSL_R_CERTIFICATE_VERIFY_FAILED; the X.509 detail is here.
            const v = c.SSL_get_verify_result(sh.ssl);
            log.debug("certificate verification failed: {s}", .{std.mem.span(c.X509_verify_cert_error_string(v))});
            failure = verifyError(v);
        }
        if (rc != 1) c.ERR_clear_error();
        const eof = sh.input_eof;
        sh.unlock();

        // Send each flight, and on failure the alert explaining it, before
        // waiting for the peer.
        sh.sendPending() catch return error.WriteFailed;
        sh.output.flush() catch return error.WriteFailed;

        switch (code) {
            c.SSL_ERROR_NONE => return,
            c.SSL_ERROR_WANT_READ => try sh.fill(),
            c.SSL_ERROR_ZERO_RETURN => return error.EndOfStream,
            c.SSL_ERROR_SYSCALL => return if (eof) error.EndOfStream else error.TlsFailure,
            else => return failure orelse error.TlsFailure,
        }
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
    try installTicketKeys(ctx);
    return ctx;
}

// ---------------------------------------------------------------------------
// Session ticket keys

/// The keys that seal a server's session tickets. BoringSSL keeps its own
/// inside the SSL_CTX, so a new SSL_CTX (a certificate reload) would start
/// with new ones and every ticket issued before would stop resuming. These
/// live beside the SSL_CTX instead: a reload hands them to the new one
/// (`carryTicketKeys`), and any number of SSL_CTXs can share them.
///
/// Used the way BoringSSL uses its default keys (ssl/ssl_session.cc): AES-128-CBC
/// and HMAC-SHA256 with 16-byte keys, a new key every two days, and the
/// previous one still accepted, its tickets renewed, until the rotation
/// after. In memory only, so tickets do not survive a restart.
///
/// Reference-counted: each SSL_CTX using them holds a reference, which
/// BoringSSL's ex_data free callback drops when the SSL_CTX is freed.
const TicketKeys = struct {
    refs: std.atomic.Value(u32) = .init(1),
    mutex: std.atomic.Mutex = .unlocked,
    current: Key,
    previous: ?Key = null,

    const Key = struct {
        name: [16]u8,
        hmac_key: [16]u8,
        aes_key: [16]u8,
        /// Seconds on the monotonic clock.
        created: i64,

        fn fresh(now: i64) error{TlsFailure}!Key {
            var k: Key = .{ .name = undefined, .hmac_key = undefined, .aes_key = undefined, .created = now };
            if (c.RAND_bytes(&k.name, k.name.len) != 1 or
                c.RAND_bytes(&k.hmac_key, k.hmac_key.len) != 1 or
                c.RAND_bytes(&k.aes_key, k.aes_key.len) != 1) return error.TlsFailure;
            return k;
        }
    };

    /// BoringSSL's SSL_DEFAULT_TICKET_KEY_ROTATION_INTERVAL.
    const rotation_interval: i64 = 2 * std.time.s_per_day;

    fn create() error{ OutOfMemory, TlsFailure }!*TicketKeys {
        const keys = std.heap.c_allocator.create(TicketKeys) catch return error.OutOfMemory;
        errdefer std.heap.c_allocator.destroy(keys);
        keys.* = .{ .current = try .fresh(monotonicSeconds()) };
        return keys;
    }

    fn unref(keys: *TicketKeys) void {
        if (keys.refs.fetchSub(1, .acq_rel) != 1) return;
        std.crypto.secureZero(u8, std.mem.asBytes(keys));
        std.heap.c_allocator.destroy(keys);
    }

    fn lock(keys: *TicketKeys) void {
        while (!keys.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    /// The key to seal a new ticket with, rotated first if it is due.
    fn sealing(keys: *TicketKeys, now: i64) error{TlsFailure}!Key {
        keys.lock();
        defer keys.mutex.unlock();
        if (now - keys.current.created >= rotation_interval) {
            const next = try Key.fresh(now);
            // A current key two intervals old has nothing worth keeping.
            keys.previous = if (now - keys.current.created < 2 * rotation_interval) keys.current else null;
            keys.current = next;
        }
        return keys.current;
    }

    /// The key a ticket names, and whether it is the current one; null for
    /// a key rotated out (or never ours).
    fn opening(keys: *TicketKeys, name: *const [16]u8, now: i64) ?struct { key: Key, current: bool } {
        keys.lock();
        defer keys.mutex.unlock();
        if (std.mem.eql(u8, name, &keys.current.name)) return .{ .key = keys.current, .current = true };
        const prev = keys.previous orelse return null;
        if (now - prev.created >= 2 * rotation_interval) return null;
        if (std.mem.eql(u8, name, &prev.name)) return .{ .key = prev, .current = false };
        return null;
    }
};

fn monotonicSeconds() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @intCast(ts.sec);
}

/// The SSL_CTX ex_data slot holding a `*TicketKeys`; -1 until created.
var ticket_keys_index: std.atomic.Value(c_int) = .init(-1);

fn ticketKeysIndex() error{TlsFailure}!c_int {
    lockGlobal();
    defer global_lock.unlock();
    const existing = ticket_keys_index.load(.acquire);
    if (existing >= 0) return existing;
    const index = c.SSL_CTX_get_ex_new_index(0, null, null, null, freeTicketKeys);
    if (index < 0) return error.TlsFailure;
    ticket_keys_index.store(index, .release);
    return index;
}

fn freeTicketKeys(_: ?*anyopaque, ptr: ?*anyopaque, _: ?*c.CRYPTO_EX_DATA, _: c_int, _: c_long, _: ?*anyopaque) callconv(.c) void {
    const keys: *TicketKeys = @ptrCast(@alignCast(ptr orelse return));
    keys.unref();
}

fn ticketKeysOf(ctx: *const c.SSL_CTX) ?*TicketKeys {
    const index = ticket_keys_index.load(.acquire);
    if (index < 0) return null;
    return @ptrCast(@alignCast(c.SSL_CTX_get_ex_data(ctx, index) orelse return null));
}

/// Gives a server's SSL_CTX session ticket keys of its own (`TicketKeys`).
/// `ctx` is an `SSL_CTX` from any of Anole's bindings of BoringSSL (the
/// HTTP/3 endpoint's comes from ngtcp2's).
pub fn installTicketKeys(ctx_any: *anyopaque) error{ OutOfMemory, TlsFailure }!void {
    const ctx: *c.SSL_CTX = @ptrCast(ctx_any);
    const index = try ticketKeysIndex();
    const keys = try TicketKeys.create();
    if (c.SSL_CTX_set_ex_data(ctx, index, keys) != 1) {
        keys.unref();
        return error.OutOfMemory;
    }
    _ = c.SSL_CTX_set_tlsext_ticket_key_cb(ctx, ticketKeyCallback);
}

/// For a certificate reload: `new` (a server SSL_CTX that has had
/// `installTicketKeys`) seals and opens tickets with `old`'s keys from now
/// on, before any handshake uses it. Both from any of Anole's bindings.
pub fn carryTicketKeys(new_any: *anyopaque, old_any: *anyopaque) void {
    const new: *c.SSL_CTX = @ptrCast(new_any);
    const old: *c.SSL_CTX = @ptrCast(old_any);
    const keys = ticketKeysOf(old) orelse return;
    const replaced = ticketKeysOf(new);
    if (replaced == keys) return;
    _ = keys.refs.fetchAdd(1, .monotonic);
    // The slot already exists (`installTicketKeys` filled it), so this
    // allocates nothing and cannot fail.
    if (c.SSL_CTX_set_ex_data(new, ticket_keys_index.load(.acquire), keys) != 1) {
        keys.unref();
        return;
    }
    if (replaced) |r| r.unref();
    _ = c.SSL_CTX_set_tlsext_ticket_key_cb(new, ticketKeyCallback);
}

/// BoringSSL's ticket key callback (`SSL_CTX_set_tlsext_ticket_key_cb`):
/// sets up `cipher_ctx` and `hmac_ctx` to seal a ticket (`encrypt` 1) or
/// to open one whose key `name` names. Returns 1, 2 (opened with the
/// previous key: issue a new ticket), 0 (not our key: a full handshake) or
/// -1 (an error).
fn ticketKeyCallback(
    ssl: ?*c.SSL,
    name: [*c]u8,
    iv: [*c]u8,
    cipher_ctx: ?*c.EVP_CIPHER_CTX,
    hmac_ctx: ?*c.HMAC_CTX,
    encrypt: c_int,
) callconv(.c) c_int {
    const keys = ticketKeysOf(c.SSL_get_SSL_CTX(ssl) orelse return -1) orelse return -1;
    const now = monotonicSeconds();
    if (encrypt == 1) {
        const key = keys.sealing(now) catch return -1;
        if (c.RAND_bytes(iv, 16) != 1) return -1;
        @memcpy(name[0..16], &key.name);
        if (c.EVP_EncryptInit_ex(cipher_ctx, c.EVP_aes_128_cbc(), null, &key.aes_key, iv) != 1) return -1;
        if (c.HMAC_Init_ex(hmac_ctx, &key.hmac_key, key.hmac_key.len, c.EVP_sha256(), null) != 1) return -1;
        return 1;
    }
    const found = keys.opening(name[0..16], now) orelse return 0;
    if (c.HMAC_Init_ex(hmac_ctx, &found.key.hmac_key, found.key.hmac_key.len, c.EVP_sha256(), null) != 1) return -1;
    if (c.EVP_DecryptInit_ex(cipher_ctx, c.EVP_aes_128_cbc(), null, &found.key.aes_key, iv) != 1) return -1;
    return if (found.current) 1 else 2;
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
const StoreEntry = struct {
    hash: u64,
    len: usize,
    store: *c.X509_STORE,
    /// The certificates' subject names (DER), for a server's client CA list.
    names: *c.struct_stack_st_CRYPTO_BUFFER,
};

const Trust = struct {
    store: *c.X509_STORE,
    /// A new stack sharing the cached name buffers, or null when not asked
    /// for; ownership passes to `SSL_set0_client_CAs`.
    names: ?*c.struct_stack_st_CRYPTO_BUFFER,
};
var store_cache: [8]?StoreEntry = @splat(null);
var store_cache_next: usize = 0;

fn setVerifyStore(ssl: *c.SSL, bundle: std.crypto.Certificate.Bundle) HandshakeError!void {
    const trust = try trustStore(bundle, false);
    defer c.X509_STORE_free(trust.store);
    if (c.SSL_set1_verify_cert_store(ssl, trust.store) != 1) return error.OutOfMemory;
}

/// Returns a new reference to the store; the caller frees it.
fn trustStore(bundle: std.crypto.Certificate.Bundle, want_names: bool) HandshakeError!Trust {
    const der = bundle.bytes.items;
    const hash = std.hash.Wyhash.hash(0, der);
    lockGlobal();
    defer global_lock.unlock();
    for (store_cache) |entry| {
        const e = entry orelse continue;
        if (e.hash == hash and e.len == der.len) return trustFrom(e, want_names);
    }

    const built = try TrustStore.fromDer(der);
    const slot = &store_cache[store_cache_next];
    store_cache_next = (store_cache_next + 1) % store_cache.len;
    if (slot.*) |old| {
        var t: TrustStore = .{ .store = old.store, .names = old.names };
        t.deinit();
    }
    slot.* = .{ .hash = hash, .len = der.len, .store = built.store, .names = built.names };
    return trustFrom(slot.*.?, want_names);
}

/// A trust store loaded once from a bundle, for dusty to keep beside the
/// bundle and hand to every handshake (`config.Client.trust`,
/// `config.ClientAuth.trust`), so none of them converts or looks up the
/// bundle. Immutable after `init`; any thread may use it.
pub const TrustStore = struct {
    store: *c.X509_STORE,
    /// The certificates' subject names (DER), for a server's client CA list.
    names: *c.struct_stack_st_CRYPTO_BUFFER,

    pub fn init(bundle: std.crypto.Certificate.Bundle) error{OutOfMemory}!TrustStore {
        return fromDer(bundle.bytes.items);
    }

    pub fn deinit(self: *TrustStore) void {
        c.X509_STORE_free(self.store);
        c.sk_CRYPTO_BUFFER_pop_free(self.names, c.CRYPTO_BUFFER_free);
        self.* = undefined;
    }

    /// The bundle's bytes: DER certificates back to back.
    fn fromDer(der: []const u8) error{OutOfMemory}!TrustStore {
        const store = c.X509_STORE_new() orelse return error.OutOfMemory;
        errdefer c.X509_STORE_free(store);
        const names = c.sk_CRYPTO_BUFFER_new_null() orelse return error.OutOfMemory;
        errdefer c.sk_CRYPTO_BUFFER_pop_free(names, c.CRYPTO_BUFFER_free);
        var p: [*c]const u8 = der.ptr;
        const end = der.ptr + der.len;
        while (p != end) {
            const x = c.d2i_X509(null, &p, @intCast(end - p)) orelse break;
            defer c.X509_free(x);
            _ = c.X509_STORE_add_cert(store, x);
            var name_der: [*c]const u8 = undefined;
            var name_len: usize = 0;
            if (c.X509_NAME_get0_der(c.X509_get_subject_name(x), &name_der, &name_len) != 1) continue;
            const buf = c.CRYPTO_BUFFER_new(name_der, name_len, null) orelse return error.OutOfMemory;
            if (c.sk_CRYPTO_BUFFER_push(names, buf) == 0) {
                c.CRYPTO_BUFFER_free(buf);
                return error.OutOfMemory;
            }
        }
        c.ERR_clear_error();
        return .{ .store = store, .names = names };
    }

    /// New references to the store and, if asked, the names.
    fn share(self: *const TrustStore, want_names: bool) HandshakeError!Trust {
        return trustFrom(.{ .hash = 0, .len = 0, .store = self.store, .names = self.names }, want_names);
    }
};

/// The trust store for a client connection made outside dusty (Anole's
/// HTTP/2 and HTTP/3 clients), from `ca`, a `dusty.TlsCa`. `.system` is
/// loaded on first use and kept for the process; a file, directory or PEM is
/// read on every call and its store cached by content, as dusty's bundles
/// are. Null for `.none`. A new reference: `X509_STORE_free` it.
pub fn clientStore(gpa: Allocator, io: std.Io, ca: anytype) !?*c.X509_STORE {
    switch (ca) {
        .none => return null,
        .system => return try systemStore(io),
        else => {
            var bundle = try ca.load(gpa, io);
            defer bundle.deinit(gpa);
            return (try trustStore(bundle, false)).store;
        },
    }
}

/// Drops a reference `clientStore` returned.
pub fn releaseStore(store: *c.X509_STORE) void {
    c.X509_STORE_free(store);
}

var system_store: ?*c.X509_STORE = null;
var system_store_mutex: std.Io.Mutex = .init;

/// The platform's trust store (`std.crypto.Certificate.Bundle.rescan`, what
/// dusty's `.system` reads), loaded once. A new reference.
fn systemStore(io: std.Io) !*c.X509_STORE {
    system_store_mutex.lockUncancelable(io);
    defer system_store_mutex.unlock(io);
    if (system_store == null) {
        const gpa = std.heap.c_allocator;
        var bundle: std.crypto.Certificate.Bundle = .empty;
        defer bundle.deinit(gpa);
        try bundle.rescan(gpa, io, std.Io.Clock.real.now(io));
        const built = try TrustStore.fromDer(bundle.bytes.items);
        // Only a server's client CA list needs the names.
        c.sk_CRYPTO_BUFFER_pop_free(built.names, c.CRYPTO_BUFFER_free);
        system_store = built.store;
    }
    _ = c.X509_STORE_up_ref(system_store.?);
    return system_store.?;
}

/// How many certificates `store` holds (for tests).
pub fn storeCertCount(store: *c.X509_STORE) usize {
    const objects = c.X509_STORE_get1_objects(store) orelse return 0;
    defer c.sk_X509_OBJECT_pop_free(objects, c.X509_OBJECT_free);
    var n: usize = 0;
    for (0..c.sk_X509_OBJECT_num(objects)) |i| {
        if (c.X509_OBJECT_get0_X509(c.sk_X509_OBJECT_value(objects, i)) != null) n += 1;
    }
    return n;
}

/// New references to an entry's store and, if asked, its names. Under the
/// global lock for a cached entry.
fn trustFrom(e: StoreEntry, want_names: bool) HandshakeError!Trust {
    var names: ?*c.struct_stack_st_CRYPTO_BUFFER = null;
    if (want_names) {
        const copy = c.sk_CRYPTO_BUFFER_new_null() orelse return error.OutOfMemory;
        for (0..c.sk_CRYPTO_BUFFER_num(e.names)) |i| {
            const buf = c.sk_CRYPTO_BUFFER_value(e.names, i);
            _ = c.CRYPTO_BUFFER_up_ref(buf);
            if (c.sk_CRYPTO_BUFFER_push(copy, buf) == 0) {
                c.CRYPTO_BUFFER_free(buf);
                c.sk_CRYPTO_BUFFER_pop_free(copy, c.CRYPTO_BUFFER_free);
                return error.OutOfMemory;
            }
        }
        names = copy;
    }
    _ = c.X509_STORE_up_ref(e.store);
    return .{ .store = e.store, .names = names };
}

// ---------------------------------------------------------------------------
// Shared state and the BIO

/// Per-SSL state shared by the reading and writing sides. Heap-allocated
/// because the Connection holding it is copied after the handshake; freed by
/// the BIO's destroy callback when SSL_free releases the BIO.
const Shared = struct {
    ssl: *c.SSL,
    /// dusty's ciphertext reader. Only the reading side touches it: `fill`
    /// with the lock released, the BIO read callback with it held.
    input: *std.Io.Reader,
    /// dusty's ciphertext writer. Only the writing side touches it.
    output: *std.Io.Writer,
    mutex: std.atomic.Mutex = .unlocked,

    // Guarded by `mutex`.
    /// The socket reached end of stream; the BIO reports EOF once `input`
    /// is drained.
    input_eof: bool = false,
    /// Set while `fill` reads into `input`, so the BIO leaves it alone.
    filling: bool = false,
    /// Records BoringSSL produced, not yet handed to `output`.
    pending: std.ArrayList(u8) = .empty,
    /// SSL_read has run since the last SSL_write that sent a record, so
    /// BoringSSL may hold handshake messages (a KeyUpdate reply) that only
    /// a write sends; `Connection.flush` then writes zero bytes to send
    /// them. Set from the start, for anything the handshake left queued.
    write_owed: bool = true,

    /// Owned by the writing side: the other half of the double buffer.
    sending: std.ArrayList(u8) = .empty,

    fn lock(sh: *Shared) void {
        while (!sh.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(sh: *Shared) void {
        sh.mutex.unlock();
    }

    /// Reads more ciphertext from the socket, with the lock released. Called
    /// by the reading side after WANT_READ, when the BIO has consumed
    /// everything buffered.
    fn fill(sh: *Shared) error{ReadFailed}!void {
        sh.lock();
        sh.filling = true;
        sh.unlock();
        const result = sh.input.fillMore();
        sh.lock();
        sh.filling = false;
        if (result) |_| {} else |err| switch (err) {
            error.EndOfStream => sh.input_eof = true,
            error.ReadFailed => {},
        }
        sh.unlock();
        return result catch |err| switch (err) {
            error.EndOfStream => {},
            error.ReadFailed => error.ReadFailed,
        };
    }

    /// Hands every pending record to `output`. Writing side only: swapping
    /// the buffers under the lock and writing with it released keeps records
    /// in order, since nothing else takes from `pending`.
    fn sendPending(sh: *Shared) error{WriteFailed}!void {
        sh.lock();
        std.mem.swap(std.ArrayList(u8), &sh.pending, &sh.sending);
        sh.unlock();
        defer sh.sending.clearRetainingCapacity();
        if (sh.sending.items.len == 0) return;
        sh.output.writeAll(sh.sending.items) catch return error.WriteFailed;
        // An idle connection keeps at most a modest buffer.
        if (sh.sending.capacity > 64 * 1024) sh.sending.clearAndFree(std.heap.c_allocator);
    }
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

fn attachShared(ssl: *c.SSL, input: *std.Io.Reader, output: *std.Io.Writer) HandshakeError!*Shared {
    const sh = std.heap.c_allocator.create(Shared) catch return error.OutOfMemory;
    sh.* = .{ .ssl = ssl, .input = input, .output = output };
    const bio = c.BIO_new(try bioMethod()) orelse {
        std.heap.c_allocator.destroy(sh);
        return error.OutOfMemory;
    };
    c.BIO_set_data(bio, sh);
    c.BIO_set_init(bio, 1);
    // The SSL takes the one reference for both directions.
    c.SSL_set_bio(ssl, bio, bio);
    return sh;
}

fn bioShared(bio: ?*c.BIO) *Shared {
    return @ptrCast(@alignCast(c.BIO_get_data(bio).?));
}

/// Runs inside an SSL call, so with the lock held. Hands over what the
/// reading side has buffered; never reads the socket.
fn bioRead(bio: ?*c.BIO, out: [*c]u8, len: c_int) callconv(.c) c_int {
    const sh = bioShared(bio);
    c.BIO_clear_retry_flags(bio);
    const got = if (sh.filling) "" else sh.input.buffered();
    if (got.len == 0) {
        if (sh.input_eof and !sh.filling) return 0;
        c.BIO_set_retry_read(bio);
        return -1;
    }
    const n = @min(got.len, @as(usize, @intCast(len)));
    @memcpy(out[0..n], got[0..n]);
    sh.input.toss(n);
    return @intCast(n);
}

/// Runs inside an SSL call, so with the lock held. Queues the records for
/// the writing side.
fn bioWrite(bio: ?*c.BIO, in: [*c]const u8, len: c_int) callconv(.c) c_int {
    const sh = bioShared(bio);
    c.BIO_clear_retry_flags(bio);
    sh.pending.appendSlice(std.heap.c_allocator, in[0..@intCast(len)]) catch return -1;
    return len;
}

fn bioCtrl(bio: ?*c.BIO, cmd: c_int, larg: c_long, parg: ?*anyopaque) callconv(.c) c_long {
    _ = bio;
    _ = larg;
    _ = parg;
    // Flushing is the writing side's job (`sendPending`, `Connection.flush`).
    return switch (cmd) {
        c.BIO_CTRL_FLUSH => 1,
        else => 0,
    };
}

fn bioDestroy(bio: ?*c.BIO) callconv(.c) c_int {
    if (c.BIO_get_data(bio)) |data| {
        const sh: *Shared = @ptrCast(@alignCast(data));
        sh.pending.deinit(std.heap.c_allocator);
        sh.sending.deinit(std.heap.c_allocator);
        std.heap.c_allocator.destroy(sh);
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
    // A received alert's reason is the offset plus its description.
    if (reason >= c.SSL_AD_REASON_OFFSET) return alertError(@intCast(reason - c.SSL_AD_REASON_OFFSET));
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
