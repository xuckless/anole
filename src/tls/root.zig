//! TLS: BoringSSL (Apache-2.0) at 22a0079b, built by build/boringssl.zig, with
//! bindings from the official translate-c package over src/tls/bssl.h.
//! Only the bindings exist so far; a TLS module for dusty's TLS seam comes next.
//!
//! The smoke test below is the M1 BoringSSL proof: an in-memory TLS handshake
//! between a client SSL and a server SSL over a BIO pair, with an ALPN select
//! callback that prefers "h2" then "http/1.1". The server key and self-signed
//! certificate are generated at run time and never touch the filesystem.
const std = @import("std");

/// The translated BoringSSL headers listed in bssl.h.
pub const c = @import("anole_boringssl_c");

/// BORINGSSL_API_VERSION from base.h of the pinned tree.
pub const api_version: c_int = c.BORINGSSL_API_VERSION;

/// OpenSSL_version(OPENSSL_VERSION): "BoringSSL".
pub fn versionText() []const u8 {
    return std.mem.span(c.OpenSSL_version(c.OPENSSL_VERSION));
}

test "BoringSSL identifies itself" {
    try std.testing.expectEqualStrings("BoringSSL", versionText());
    try std.testing.expect(api_version > 0);
}

const log = std.log.scoped(.tls_smoke);

/// Set while a handshake is expected to fail, so the test runner (which fails
/// a test on any error log) does not see the expected BoringSSL errors.
var expecting_failure = false;

fn sslFail(what: []const u8) error{Boring} {
    if (expecting_failure) {
        c.ERR_clear_error();
        return error.Boring;
    }
    log.err("{s} failed", .{what});
    while (true) {
        const code = c.ERR_get_error();
        if (code == 0) break;
        var buf: [256]u8 = undefined;
        _ = c.ERR_error_string_n(code, &buf, buf.len);
        log.err("  {s}", .{std.mem.sliceTo(&buf, 0)});
    }
    return error.Boring;
}

fn check(ok: c_int, what: []const u8) !void {
    if (ok != 1) return sslFail(what);
}

/// Server ALPN preference order (protocol names, not wire format).
const server_prefs = [_][]const u8{ "h2", "http/1.1" };

/// ALPN select callback: walk the server's preference list and pick the first
/// protocol the client also offered.
fn alpnSelect(
    ssl: ?*c.SSL,
    out: [*c][*c]const u8,
    out_len: [*c]u8,
    in: [*c]const u8,
    in_len: c_uint,
    arg: ?*anyopaque,
) callconv(.c) c_int {
    _ = ssl;
    _ = arg;
    const offered = in[0..in_len];
    for (server_prefs) |want| {
        var i: usize = 0;
        while (i < offered.len) {
            const n = offered[i];
            const proto = offered[i + 1 ..][0..n];
            if (std.mem.eql(u8, proto, want)) {
                out.* = proto.ptr;
                out_len.* = n;
                return c.SSL_TLSEXT_ERR_OK;
            }
            i += 1 + n;
        }
    }
    return c.SSL_TLSEXT_ERR_ALERT_FATAL;
}

const KeyAndCert = struct { pkey: *c.EVP_PKEY, cert: *c.X509 };

/// P-256 key plus a self-signed X.509v3 certificate for CN=localhost, valid for one hour.
fn makeKeyAndCert() !KeyAndCert {
    const ec = c.EC_KEY_new_by_curve_name(c.NID_X9_62_prime256v1) orelse return sslFail("EC_KEY_new_by_curve_name");
    try check(c.EC_KEY_generate_key(ec), "EC_KEY_generate_key");
    const pkey = c.EVP_PKEY_new() orelse return sslFail("EVP_PKEY_new");
    try check(c.EVP_PKEY_assign_EC_KEY(pkey, ec), "EVP_PKEY_assign_EC_KEY"); // pkey owns ec now

    const x = c.X509_new() orelse return sslFail("X509_new");
    try check(c.X509_set_version(x, c.X509_VERSION_3), "X509_set_version");
    try check(c.ASN1_INTEGER_set(c.X509_get_serialNumber(x), 1), "ASN1_INTEGER_set");
    if (c.X509_gmtime_adj(c.X509_getm_notBefore(x), -60) == null) return sslFail("notBefore");
    if (c.X509_gmtime_adj(c.X509_getm_notAfter(x), 3600) == null) return sslFail("notAfter");
    const name = c.X509_get_subject_name(x);
    try check(c.X509_NAME_add_entry_by_txt(name, "CN", c.MBSTRING_ASC, "localhost", -1, -1, 0), "X509_NAME_add_entry_by_txt");
    try check(c.X509_set_issuer_name(x, name), "X509_set_issuer_name");
    try check(c.X509_set_pubkey(x, pkey), "X509_set_pubkey");
    if (c.X509_sign(x, pkey, c.EVP_sha256()) <= 0) return sslFail("X509_sign");
    return .{ .pkey = pkey, .cert = x };
}

fn newCtx() !*c.SSL_CTX {
    const ctx = c.SSL_CTX_new(c.TLS_method()) orelse return sslFail("SSL_CTX_new");
    try check(c.SSL_CTX_set_min_proto_version(ctx, c.TLS1_2_VERSION), "SSL_CTX_set_min_proto_version");
    return ctx;
}

const Side = enum { client, server };

/// Drive one side's handshake one step. Returns true when that side is done.
fn step(ssl: *c.SSL, side: Side) !bool {
    const rc = c.SSL_do_handshake(ssl);
    if (rc == 1) return true;
    const e = c.SSL_get_error(ssl, rc);
    if (e == c.SSL_ERROR_WANT_READ or e == c.SSL_ERROR_WANT_WRITE) return false;
    if (!expecting_failure) log.err("{t} SSL_do_handshake: SSL_get_error={d}", .{ side, e });
    return sslFail("SSL_do_handshake");
}

test "BoringSSL smoke: in-memory TLS 1.3/1.2 handshakes negotiate ALPN h2; TLS 1.1 refused" {
    const kc = try makeKeyAndCert();
    defer c.X509_free(kc.cert);
    defer c.EVP_PKEY_free(kc.pkey);

    // Server context: TLS 1.2+, in-memory key and certificate, ALPN select callback.
    const server_ctx = try newCtx();
    defer c.SSL_CTX_free(server_ctx);
    try check(c.SSL_CTX_use_certificate(server_ctx, kc.cert), "SSL_CTX_use_certificate");
    try check(c.SSL_CTX_use_PrivateKey(server_ctx, kc.pkey), "SSL_CTX_use_PrivateKey");
    try check(c.SSL_CTX_check_private_key(server_ctx), "SSL_CTX_check_private_key");
    c.SSL_CTX_set_alpn_select_cb(server_ctx, alpnSelect, null);

    // Client context: trusts exactly the generated certificate, offers http/1.1 first then h2,
    // so a server-preference result of "h2" proves the callback ran.
    const client_ctx = try newCtx();
    defer c.SSL_CTX_free(client_ctx);
    try check(c.X509_STORE_add_cert(c.SSL_CTX_get_cert_store(client_ctx), kc.cert), "X509_STORE_add_cert");
    c.SSL_CTX_set_verify(client_ctx, c.SSL_VERIFY_PEER, null);
    const client_alpn = "\x08http/1.1\x02h2";
    if (c.SSL_CTX_set_alpn_protos(client_ctx, client_alpn, client_alpn.len) != 0) // 0 means success here
        return sslFail("SSL_CTX_set_alpn_protos");

    // TLS 1.3 (default max) and TLS 1.2 must both negotiate h2.
    try handshake(client_ctx, server_ctx, null);
    try handshake(client_ctx, server_ctx, c.TLS1_2_VERSION);

    // A TLS 1.1-only client must be refused by the server's TLS 1.2 floor.
    expecting_failure = true;
    defer expecting_failure = false;
    if (handshake(client_ctx, server_ctx, c.TLS1_1_VERSION)) |_| {
        return error.Tls11Accepted;
    } else |_| {
        c.ERR_clear_error();
    }
}

/// One client/server session over a fresh BIO pair. `client_max` caps the client's version
/// (and, below TLS 1.2, also lowers the client's own floor so it can try).
fn handshake(client_ctx: *c.SSL_CTX, server_ctx: *c.SSL_CTX, client_max: ?u16) !void {
    const client = c.SSL_new(client_ctx) orelse return sslFail("SSL_new client");
    defer c.SSL_free(client);
    const server = c.SSL_new(server_ctx) orelse return sslFail("SSL_new server");
    defer c.SSL_free(server);
    try check(c.SSL_set1_host(client, "localhost"), "SSL_set1_host");
    try check(c.SSL_set_tlsext_host_name(client, "localhost"), "SSL_set_tlsext_host_name");
    if (client_max) |max| {
        if (max < c.TLS1_2_VERSION) try check(c.SSL_set_min_proto_version(client, c.TLS1_VERSION), "SSL_set_min_proto_version");
        try check(c.SSL_set_max_proto_version(client, max), "SSL_set_max_proto_version");
    }

    var client_bio: ?*c.BIO = null;
    var server_bio: ?*c.BIO = null;
    try check(c.BIO_new_bio_pair(&client_bio, 0, &server_bio, 0), "BIO_new_bio_pair");
    c.SSL_set_bio(client, client_bio, client_bio); // each SSL takes its end's reference
    c.SSL_set_bio(server, server_bio, server_bio);
    c.SSL_set_connect_state(client);
    c.SSL_set_accept_state(server);

    var client_done = false;
    var server_done = false;
    var rounds: usize = 0;
    while (!(client_done and server_done)) : (rounds += 1) {
        if (rounds > 32) return error.HandshakeStalled;
        if (!client_done) client_done = try step(client, .client);
        if (!server_done) server_done = try step(server, .server);
    }

    var proto: [*c]const u8 = null;
    var proto_len: c_uint = 0;
    c.SSL_get0_alpn_selected(client, &proto, &proto_len);
    const client_alpn_got = if (proto_len == 0) "" else proto[0..proto_len];
    c.SSL_get0_alpn_selected(server, &proto, &proto_len);
    const server_alpn_got = if (proto_len == 0) "" else proto[0..proto_len];

    const verify = c.SSL_get_verify_result(client);
    const version = std.mem.span(c.SSL_get_version(client));
    const cipher = std.mem.span(c.SSL_CIPHER_get_name(c.SSL_get_current_cipher(client)));

    // Round-trip application data in both directions.
    const ping = "ping";
    if (c.SSL_write(client, ping, ping.len) != ping.len) return sslFail("SSL_write client");
    var buf: [16]u8 = undefined;
    const n = c.SSL_read(server, &buf, buf.len);
    if (n != ping.len or !std.mem.eql(u8, buf[0..ping.len], ping)) return sslFail("SSL_read server");
    const pong = "pong";
    if (c.SSL_write(server, pong, pong.len) != pong.len) return sslFail("SSL_write server");
    const m = c.SSL_read(client, &buf, buf.len);
    if (m != pong.len or !std.mem.eql(u8, buf[0..pong.len], pong)) return sslFail("SSL_read client");

    log.debug(
        \\handshake ok in {d} rounds: {s} {s}
        \\  alpn client={s} server={s}
        \\  verify_result={d} (0 = X509_V_OK), app data ping/pong ok
    , .{ rounds, version, cipher, client_alpn_got, server_alpn_got, verify });

    if (!std.mem.eql(u8, client_alpn_got, "h2") or !std.mem.eql(u8, server_alpn_got, "h2")) return error.AlpnNotH2;
    if (verify != c.X509_V_OK) return error.VerifyFailed;
}
