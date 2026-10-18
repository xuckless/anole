//! The TLS side of an HTTP/3 listener: a BoringSSL `SSL_CTX` set up by
//! ngtcp2's crypto helper for QUIC, with ALPN "h3" and the listener's
//! certificate, and the per-connection `SSL` that ngtcp2 drives. After
//! ngtcp2's examples/tls_server_context_boringssl.cc and
//! tls_server_session_boringssl.cc (MIT).
const std = @import("std");
const c = @import("ngtcp2.zig").c;

const log = std.log.scoped(.anole_h3);

/// "h3" in ALPN wire format.
const alpn_h3 = "\x02h3";

pub const Context = struct {
    ctx: *c.SSL_CTX,

    /// `cert_pem`: the leaf certificate followed by any intermediates.
    pub fn init(cert_pem: []const u8, key_pem: []const u8) !Context {
        c.ERR_clear_error();
        const ctx = c.SSL_CTX_new(c.TLS_server_method()) orelse return error.OutOfMemory;
        errdefer c.SSL_CTX_free(ctx);
        // TLS 1.3 only, and the QUIC method, key callbacks and settings.
        if (c.ngtcp2_crypto_boringssl_configure_server_context(ctx) != 0) return error.TlsSetupFailed;
        _ = c.SSL_CTX_set_mode(ctx, c.SSL_MODE_RELEASE_BUFFERS);
        c.SSL_CTX_set_alpn_select_cb(ctx, selectAlpn, null);
        const sid_ctx = "anole h3";
        _ = c.SSL_CTX_set_session_id_context(ctx, sid_ctx, sid_ctx.len);

        const cert_bio = c.BIO_new_mem_buf(cert_pem.ptr, @intCast(cert_pem.len)) orelse return error.OutOfMemory;
        defer _ = c.BIO_free(cert_bio);
        const cert = c.PEM_read_bio_X509(cert_bio, null, null, null) orelse return error.TlsInvalidCertificate;
        defer c.X509_free(cert);
        if (c.SSL_CTX_use_certificate(ctx, cert) != 1) return error.TlsInvalidCertificate;
        while (c.PEM_read_bio_X509(cert_bio, null, null, null)) |x| {
            defer c.X509_free(x);
            if (c.SSL_CTX_add1_chain_cert(ctx, x) != 1) return error.TlsInvalidCertificate;
        }
        // The loop ends on "no start line", the normal end of the file.
        c.ERR_clear_error();

        const key_bio = c.BIO_new_mem_buf(key_pem.ptr, @intCast(key_pem.len)) orelse return error.OutOfMemory;
        defer _ = c.BIO_free(key_bio);
        const key = c.PEM_read_bio_PrivateKey(key_bio, null, null, null) orelse return error.TlsInvalidPrivateKey;
        defer c.EVP_PKEY_free(key);
        if (c.SSL_CTX_use_PrivateKey(ctx, key) != 1) return error.TlsInvalidPrivateKey;
        if (c.SSL_CTX_check_private_key(ctx) != 1) return error.TlsKeyMismatch;
        return .{ .ctx = ctx };
    }

    pub fn deinit(self: *Context) void {
        c.SSL_CTX_free(self.ctx);
        self.* = undefined;
    }

    /// A server-side `SSL` for one QUIC connection. `conn_ref` must stay
    /// put for the life of the `SSL`: the crypto helper finds the
    /// connection through it.
    pub fn newSession(self: *const Context, conn_ref: *c.ngtcp2_crypto_conn_ref) !*c.SSL {
        const ssl = c.SSL_new(self.ctx) orelse return error.OutOfMemory;
        // SSL_set_app_data is SSL_set_ex_data(ssl, 0, ...).
        _ = c.SSL_set_ex_data(ssl, 0, conn_ref);
        c.SSL_set_accept_state(ssl);
        return ssl;
    }
};

/// Picks "h3" from the client's offer, or refuses the handshake: an
/// HTTP/3 endpoint speaks nothing else.
fn selectAlpn(
    _: ?*c.SSL,
    out: [*c][*c]const u8,
    out_len: [*c]u8,
    in: [*c]const u8,
    in_len: c_uint,
    _: ?*anyopaque,
) callconv(.c) c_int {
    var offer = in[0..in_len];
    while (offer.len > 0) {
        const n = offer[0];
        if (1 + @as(usize, n) > offer.len) break;
        if (std.mem.eql(u8, offer[0 .. 1 + n], alpn_h3)) {
            out.* = offer[1..].ptr;
            out_len.* = n;
            return c.SSL_TLSEXT_ERR_OK;
        }
        offer = offer[1 + n ..];
    }
    log.debug("client offered no h3 ALPN", .{});
    return c.SSL_TLSEXT_ERR_ALERT_FATAL;
}
