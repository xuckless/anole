//! TLS on BoringSSL (-Dtls=boringssl). Most programs need nothing here:
//! listeners take a certificate through `anole.Cert` (`.fromFiles`,
//! `.fromPem`, `.dev_self_signed`) and the clients verify against the
//! system store by default. What this namespace adds:
//!
//! - `selfSigned`: a fresh key and certificate in memory, for development
//!   and tests;
//! - `dusty_tls`: the TLS module every HTTPS/WSS listener and client
//!   connection runs on;
//! - `c`: the raw BoringSSL bindings, for anything else.
//!
//! BoringSSL (Apache-2.0) is pinned at 22a0079b and built by
//! build/boringssl.zig, with bindings from the official translate-c package
//! over src/tls/bssl.h.
const std = @import("std");

/// The translated BoringSSL headers listed in bssl.h.
pub const c = @import("anole_boringssl_c");

/// dusty's `tls` module, on BoringSSL (src/tls/dusty_tls.zig).
pub const dusty_tls = @import("anole_dusty_tls");

/// Test helpers that other test binaries reuse.
pub const testing = struct {
    /// Full-duplex check of `dusty_tls` (also run multi-threaded by tests/tls_duplex.zig).
    pub const duplex = @import("duplex_check.zig");

    /// A CA bundle holding the first PEM certificate in `pem` (for a client
    /// to trust a `selfSigned` server).
    pub fn bundleFromPem(gpa: std.mem.Allocator, now_sec: i64, pem: []const u8) !std.crypto.Certificate.Bundle {
        var bundle: std.crypto.Certificate.Bundle = .empty;
        errdefer bundle.deinit(gpa);
        const begin = "-----BEGIN CERTIFICATE-----";
        const end = "-----END CERTIFICATE-----";
        const start = (std.mem.indexOf(u8, pem, begin) orelse return error.NoCertificate) + begin.len;
        const stop = std.mem.indexOfPos(u8, pem, start, end) orelse return error.NoCertificate;
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        for (pem[start..stop]) |ch| if (ch != '\n' and ch != '\r') try text.append(gpa, ch);
        const len = try std.base64.standard.Decoder.calcSizeForSlice(text.items);
        const decoded_start: u32 = @intCast(bundle.bytes.items.len);
        try bundle.bytes.ensureUnusedCapacity(gpa, len);
        try std.base64.standard.Decoder.decode(bundle.bytes.unusedCapacitySlice()[0..len], text.items);
        bundle.bytes.items.len += len;
        try bundle.parseCert(gpa, decoded_start, now_sec);
        return bundle;
    }
};

test "TLS: one connection read and written at once (one executor, tasks interleaved)" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    try testing.duplex.run(std.testing.allocator, rt.io(), .{ .bytes_per_direction = 2 * 1024 * 1024 });
}

test "TLS: an idle connection keeps no ciphertext buffer beyond its stash" {
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    try testing.duplex.idle(std.testing.allocator, rt.io());
}

/// A certificate and private key as PEM text, owned by the allocator that
/// made them.
pub const Pem = struct {
    /// The certificate, PEM.
    cert: []u8,
    /// The private key, PEM (PKCS#8).
    key: []u8,

    /// Frees both, zeroing the key first.
    pub fn deinit(self: *Pem, gpa: std.mem.Allocator) void {
        gpa.free(self.cert);
        std.crypto.secureZero(u8, self.key);
        gpa.free(self.key);
        self.* = undefined;
    }
};

/// What `selfSigned` makes. The defaults suit a server on this machine:
/// localhost, 127.0.0.1 and ::1, valid for a week, a P-256 key.
pub const SelfSignedOptions = struct {
    /// Subject CN, also the first DNS subjectAltName.
    common_name: []const u8 = "localhost",
    /// subjectAltName entries, in OpenSSL config syntax.
    alt_names: []const u8 = "DNS:localhost,IP:127.0.0.1,IP:::1",
    /// How long the certificate is valid from now.
    valid_for_seconds: i64 = 7 * 24 * 3600,
    /// P-256 is fast to make and to use; RSA-4096 is the heaviest key a
    /// handshake meets in practice (and takes a second or more to make).
    key: enum { p256, rsa4096 } = .p256,
};

/// A fresh key and a self-signed certificate for it, for development
/// and tests: nothing touches the disk. The certificate is its own CA
/// (`CA:TRUE`), so a client can trust it directly. Free it with
/// `Pem.deinit`. A listener that only needs one can name
/// `.dev_self_signed` instead.
///
///     var pem = try anole.tls.selfSigned(gpa, .{});
///     defer pem.deinit(gpa);
///     // .https = .{ .cert = .fromPem(pem.cert, pem.key) }
pub fn selfSigned(gpa: std.mem.Allocator, opt: SelfSignedOptions) !Pem {
    c.ERR_clear_error();
    defer c.ERR_clear_error();
    const pkey = c.EVP_PKEY_new() orelse return error.OutOfMemory;
    defer c.EVP_PKEY_free(pkey);
    switch (opt.key) {
        .p256 => {
            const ec = c.EC_KEY_new_by_curve_name(c.NID_X9_62_prime256v1) orelse return error.OutOfMemory;
            if (c.EC_KEY_generate_key(ec) != 1 or c.EVP_PKEY_assign_EC_KEY(pkey, ec) != 1) {
                c.EC_KEY_free(ec);
                return error.TlsKeyGenerationFailed;
            }
        },
        .rsa4096 => {
            const rsa = c.RSA_new() orelse return error.OutOfMemory;
            const e = c.BN_new() orelse {
                c.RSA_free(rsa);
                return error.OutOfMemory;
            };
            defer c.BN_free(e);
            if (c.BN_set_word(e, 65537) != 1 or c.RSA_generate_key_ex(rsa, 4096, e, null) != 1 or c.EVP_PKEY_assign_RSA(pkey, rsa) != 1) {
                c.RSA_free(rsa);
                return error.TlsKeyGenerationFailed;
            }
        },
    }

    const x = c.X509_new() orelse return error.OutOfMemory;
    defer c.X509_free(x);
    var serial: [16]u8 = undefined;
    if (c.RAND_bytes(&serial, serial.len) != 1) return error.TlsKeyGenerationFailed;
    serial[0] &= 0x7f; // positive
    const bn = c.BN_bin2bn(&serial, serial.len, null) orelse return error.OutOfMemory;
    defer c.BN_free(bn);
    if (c.X509_set_version(x, c.X509_VERSION_3) != 1 or
        c.BN_to_ASN1_INTEGER(bn, c.X509_get_serialNumber(x)) == null or
        c.X509_gmtime_adj(c.X509_getm_notBefore(x), -60) == null or
        c.X509_gmtime_adj(c.X509_getm_notAfter(x), @intCast(opt.valid_for_seconds)) == null)
        return error.TlsCertificateFailed;

    var cn_buf: [256]u8 = undefined;
    const cn = std.fmt.bufPrintSentinel(&cn_buf, "{s}", .{opt.common_name}, 0) catch return error.NameTooLong;
    const name = c.X509_get_subject_name(x);
    if (c.X509_NAME_add_entry_by_txt(name, "CN", c.MBSTRING_UTF8, cn.ptr, -1, -1, 0) != 1 or
        c.X509_set_issuer_name(x, name) != 1 or
        c.X509_set_pubkey(x, pkey) != 1)
        return error.TlsCertificateFailed;

    var san_buf: [1024]u8 = undefined;
    const san = std.fmt.bufPrintSentinel(&san_buf, "{s}", .{opt.alt_names}, 0) catch return error.NameTooLong;
    const exts = [_]struct { nid: c_int, value: [*:0]const u8 }{
        .{ .nid = c.NID_subject_alt_name, .value = san.ptr },
        .{ .nid = c.NID_basic_constraints, .value = "critical,CA:TRUE" },
        .{ .nid = c.NID_key_usage, .value = "critical,digitalSignature,keyCertSign" },
        .{ .nid = c.NID_ext_key_usage, .value = "serverAuth,clientAuth" },
    };
    var v3: c.X509V3_CTX = undefined;
    c.X509V3_set_ctx(&v3, x, x, null, null, 0);
    for (exts) |e| {
        const ext = c.X509V3_EXT_nconf_nid(null, &v3, e.nid, e.value) orelse return error.TlsCertificateFailed;
        defer c.X509_EXTENSION_free(ext);
        if (c.X509_add_ext(x, ext, -1) != 1) return error.TlsCertificateFailed;
    }
    if (c.X509_sign(x, pkey, c.EVP_sha256()) <= 0) return error.TlsCertificateFailed;

    const cert = try toPem(gpa, x, null);
    errdefer gpa.free(cert);
    return .{ .cert = cert, .key = try toPem(gpa, null, pkey) };
}

fn toPem(gpa: std.mem.Allocator, x: ?*c.X509, pkey: ?*c.EVP_PKEY) ![]u8 {
    const bio = c.BIO_new(c.BIO_s_mem()) orelse return error.OutOfMemory;
    defer _ = c.BIO_free(bio);
    const ok = if (x) |cert|
        c.PEM_write_bio_X509(bio, cert)
    else
        c.PEM_write_bio_PrivateKey(bio, pkey, null, null, 0, null, null);
    if (ok != 1) return error.TlsCertificateFailed;
    var contents: [*c]const u8 = null;
    var len: usize = 0;
    if (c.BIO_mem_contents(bio, &contents, &len) != 1) return error.OutOfMemory;
    const out = try gpa.dupe(u8, contents[0..len]);
    // The memory BIO's copy of a private key is wiped before BIO_free.
    std.crypto.secureZero(u8, @constCast(contents[0..len]));
    return out;
}

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

// The M1 BoringSSL proof: an in-memory TLS handshake between a client SSL
// and a server SSL over a BIO pair, with an ALPN select callback that
// prefers "h2" then "http/1.1". The server key and self-signed certificate
// are generated at run time and never touch the filesystem.
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

// HTTPS over loopback through dusty's TLS seam: a dusty server and a dusty
// client, both on the BoringSSL module, as tasks of one zio runtime. The
// harness shape follows dusty's client_test.zig (lalinsky/dusty, MIT).

const dusty = @import("dusty");
const zio = @import("zio");

const loopback: dusty.Address = .{ .ip = .{ .ip4 = .loopback(0) } };

const Https = struct {
    rt: *zio.Runtime,
    io: std.Io,
    pem: Pem,
    /// Holds cert.pem for the client's CA file (dusty's client reads its
    /// trust anchors from a file); the key never leaves memory.
    tmp: std.testing.TmpDir,

    fn init() !Https {
        return initWith(.{});
    }

    fn initWith(opt: SelfSignedOptions) !Https {
        const gpa = std.testing.allocator;
        const rt = try zio.Runtime.init(gpa, .{});
        errdefer rt.deinit();
        var pem = try selfSigned(gpa, opt);
        errdefer pem.deinit(gpa);
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(rt.io(), .{ .sub_path = "cert.pem", .data = pem.cert });
        return .{ .rt = rt, .io = rt.io(), .pem = pem, .tmp = tmp };
    }

    fn deinit(self: *Https) void {
        self.tmp.cleanup();
        self.pem.deinit(std.testing.allocator);
        self.rt.deinit();
    }

    fn caFile(self: *Https) dusty.TlsCa {
        return .{ .file = .{ .path = "cert.pem", .dir = self.tmp.dir } };
    }
};

/// A blocking BoringSSL client over a plain socket, for tests that need to
/// see what dusty's client hides. Run it off the runtime (`onThread`): its
/// I/O blocks.
const RawClient = struct {
    fd: c_int,
    ssl: *c.SSL,

    fn connect(ctx: *c.SSL_CTX, port: u16, session: ?*c.SSL_SESSION) !RawClient {
        const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (fd < 0) return error.Socket;
        errdefer _ = std.c.close(fd);
        var addr: std.c.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        if (std.c.connect(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) != 0) return error.Connect;
        const ssl = c.SSL_new(ctx) orelse return error.OutOfMemory;
        errdefer c.SSL_free(ssl);
        _ = c.SSL_set_fd(ssl, fd);
        if (session) |sess| _ = c.SSL_set_session(ssl, sess);
        // Unverified: these clients look at the protocol, not the identity.
        if (c.SSL_connect(ssl) != 1) return error.Handshake;
        return .{ .fd = fd, .ssl = ssl };
    }

    /// One `Connection: close` GET of "/"; true when the hello came back.
    /// Reads to the end, so a TLS 1.3 session ticket has arrived.
    fn get(self: RawClient) !struct { hello: bool, close_notify: bool } {
        const req = "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        if (c.SSL_write(self.ssl, req, req.len) != req.len) return error.Write;
        var hello = false;
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = c.SSL_read(self.ssl, &buf, buf.len);
            if (n > 0) {
                if (std.mem.indexOf(u8, buf[0..@intCast(n)], "hello over tls") != null) hello = true;
                continue;
            }
            // ZERO_RETURN: close_notify; SYSCALL with no error: a bare EOF.
            return .{ .hello = hello, .close_notify = c.SSL_get_error(self.ssl, n) == c.SSL_ERROR_ZERO_RETURN };
        }
    }

    fn close(self: RawClient) void {
        _ = c.SSL_shutdown(self.ssl);
        c.SSL_free(self.ssl);
        _ = std.c.close(self.fd);
    }

    /// Runs `func(args)` on a thread of its own and waits for it without
    /// blocking the runtime's executors.
    fn onThread(io: std.Io, comptime func: anytype, args: anytype) !void {
        const Wrap = struct {
            done: std.atomic.Value(bool) = .init(false),
            result: anyerror!void = {},
            fn run(w: *@This(), a: @TypeOf(args)) void {
                w.result = @call(.auto, func, a);
                w.done.store(true, .release);
            }
        };
        var w: Wrap = .{};
        const thread = try std.Thread.spawn(.{}, Wrap.run, .{ &w, args });
        while (!w.done.load(.acquire)) try io.sleep(.fromMilliseconds(2), .awake);
        thread.join();
        return w.result;
    }
};

fn handleHello(req: *dusty.Request, res: *dusty.Response) !void {
    try std.testing.expect(req.secure);
    try res.print(.text, "hello over {s}", .{"tls"});
}

fn runServer(s: *dusty.Server(void)) !void {
    try s.run();
}

test "TLS hello: HTTPS GET through dusty's seam, certificate verified, ALPN http/1.1" {
    var h = try Https.init();
    defer h.deinit();
    const io = h.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .listeners = &.{.{ .address = loopback, .tls = .{
            .pem = .{ .cert = h.pem.cert, .key = h.pem.key },
            .alpn_protocols = &.{"http/1.1"},
        } }},
    }, {});
    defer server.deinit();
    server.router.get("/", handleHello);

    var server_future = try io.concurrent(runServer, .{&server});
    defer server_future.cancel(io) catch {};

    var client_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void), _io: std.Io, ca: dusty.TlsCa) !void {
            try s.waitReady(_io);
            var client = dusty.Client.init(std.testing.allocator, _io, .{ .tls = .{ .ca = ca } });
            defer client.deinit();

            var url_buf: [64]u8 = undefined;
            // Two requests: the second reuses the pooled TLS connection.
            for (0..2) |_| {
                const url = try std.fmt.bufPrint(&url_buf, "https://localhost:{d}/", .{s.address.ip.getPort()});
                var response = try client.fetch(url, .{});
                defer response.deinit();
                try std.testing.expectEqual(.ok, response.status());
                try std.testing.expectEqualStrings("hello over tls", (try response.body()).?);
            }
            // By IP literal: no SNI, verified against the IP subjectAltName.
            const url = try std.fmt.bufPrint(&url_buf, "https://127.0.0.1:{d}/", .{s.address.ip.getPort()});
            var response = try client.fetch(url, .{});
            defer response.deinit();
            try std.testing.expectEqual(.ok, response.status());
        }
    }.run, .{ &server, io, h.caFile() });
    try client_future.await(io);
}

test "TLS hello: a client that does not trust the certificate is refused" {
    var h = try Https.init();
    defer h.deinit();
    const io = h.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .listeners = &.{.{ .address = loopback, .tls = .{ .pem = .{ .cert = h.pem.cert, .key = h.pem.key } } }},
    }, {});
    defer server.deinit();
    server.router.get("/", handleHello);

    var server_future = try io.concurrent(runServer, .{&server});
    defer server_future.cancel(io) catch {};

    // A different self-signed certificate as the only trust anchor.
    var other = try selfSigned(std.testing.allocator, .{});
    defer other.deinit(std.testing.allocator);
    try h.tmp.dir.writeFile(io, .{ .sub_path = "other.pem", .data = other.cert });

    var client_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void), _io: std.Io, dir: std.Io.Dir) !void {
            try s.waitReady(_io);
            var client = dusty.Client.init(std.testing.allocator, _io, .{
                .tls = .{ .ca = .{ .file = .{ .path = "other.pem", .dir = dir } } },
            });
            defer client.deinit();
            var url_buf: [64]u8 = undefined;
            const url = try std.fmt.bufPrint(&url_buf, "https://localhost:{d}/", .{s.address.ip.getPort()});
            try std.testing.expectError(error.CertificateIssuerNotFound, client.fetch(url, .{}));
        }
    }.run, .{ &server, io, h.tmp.dir });
    try client_future.await(io);
}

test "TLS hello: mutual TLS rejects a client without a certificate and accepts one with it" {
    var h = try Https.init();
    defer h.deinit();
    const io = h.io;
    // dusty's client loads its certificate from files; this one is a test key.
    try h.tmp.dir.writeFile(io, .{ .sub_path = "key.pem", .data = h.pem.key });

    // The self-signed certificate is CA:TRUE, so it is the server identity,
    // the client identity and the CA that verifies both.
    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .listeners = &.{.{ .address = loopback, .tls = .{
            .pem = .{ .cert = h.pem.cert, .key = h.pem.key },
            .client_auth = .{ .ca = h.caFile() },
        } }},
    }, {});
    defer server.deinit();
    server.router.get("/", handleHello);

    var server_future = try io.concurrent(runServer, .{&server});
    defer server_future.cancel(io) catch {};

    var client_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void), _io: std.Io, ca: dusty.TlsCa, dir: std.Io.Dir) !void {
            try s.waitReady(_io);
            var url_buf: [64]u8 = undefined;
            const url = try std.fmt.bufPrint(&url_buf, "https://localhost:{d}/", .{s.address.ip.getPort()});
            {
                var anon = dusty.Client.init(std.testing.allocator, _io, .{ .tls = .{ .ca = ca } });
                defer anon.deinit();
                // TLS 1.3: the client's flight is done before the server
                // refuses it, so the refusal is the alert on the first read.
                // The server lingers after refusing, so no reset (from
                // closing with the client's request unread) overtakes it.
                if (anon.fetch(url, .{})) |r| {
                    var resp = r;
                    resp.deinit();
                    return error.ServedWithoutClientCertificate;
                } else |err| switch (err) {
                    error.TlsAlertCertificateRequired => {},
                    else => return err,
                }
            }
            var authed = dusty.Client.init(std.testing.allocator, _io, .{ .tls = .{
                .ca = ca,
                .client_certificate = .{ .cert_path = "cert.pem", .key_path = "key.pem", .dir = dir },
            } });
            defer authed.deinit();
            var response = try authed.fetch(url, .{});
            defer response.deinit();
            try std.testing.expectEqual(.ok, response.status());
        }
    }.run, .{ &server, io, h.caFile(), h.tmp.dir });
    try client_future.await(io);
}

test "TLS hello: mutual TLS names the acceptable CAs in the CertificateRequest" {
    var h = try Https.init();
    defer h.deinit();
    const io = h.io;
    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .listeners = &.{.{ .address = loopback, .tls = .{
            .pem = .{ .cert = h.pem.cert, .key = h.pem.key },
            .client_auth = .{ .ca = h.caFile(), .mode = .request },
        } }},
    }, {});
    defer server.deinit();
    server.router.get("/", handleHello);
    var server_future = try io.concurrent(runServer, .{&server});
    defer server_future.cancel(io) catch {};
    try server.waitReady(io);

    // Reads what the server asked for, in the cert callback: the requested
    // CAs are readable only during the handshake.
    const Probe = struct {
        names: usize = 0,
        matches: bool = false,
        expected: []const u8,

        fn certCb(ssl: ?*c.SSL, arg: ?*anyopaque) callconv(.c) c_int {
            const p: *@This() = @ptrCast(@alignCast(arg.?));
            const names = c.SSL_get0_server_requested_CAs(ssl) orelse return 1;
            p.names = c.sk_CRYPTO_BUFFER_num(names);
            for (0..p.names) |i| {
                const buf = c.sk_CRYPTO_BUFFER_value(names, i);
                const der = c.CRYPTO_BUFFER_data(buf)[0..c.CRYPTO_BUFFER_len(buf)];
                if (std.mem.eql(u8, der, p.expected)) p.matches = true;
            }
            return 1;
        }

        fn run(p: *@This(), port: u16) !void {
            const ctx = c.SSL_CTX_new(c.TLS_method()) orelse return error.OutOfMemory;
            defer c.SSL_CTX_free(ctx);
            c.SSL_CTX_set_cert_cb(ctx, certCb, p);
            const conn = try RawClient.connect(ctx, port, null);
            conn.close();
        }
    };

    // The expected name: the certificate's own subject (it is its own CA).
    const bio_mem = c.BIO_new_mem_buf(h.pem.cert.ptr, @intCast(h.pem.cert.len)) orelse return error.OutOfMemory;
    defer _ = c.BIO_free(bio_mem);
    const x = c.PEM_read_bio_X509(bio_mem, null, null, null) orelse return error.BadCertificate;
    defer c.X509_free(x);
    var subject_der: [*c]const u8 = undefined;
    var subject_len: usize = 0;
    try std.testing.expectEqual(1, c.X509_NAME_get0_der(c.X509_get_subject_name(x), &subject_der, &subject_len));

    var probe: Probe = .{ .expected = subject_der[0..subject_len] };
    try RawClient.onThread(io, Probe.run, .{ &probe, server.address.ip.getPort() });
    try std.testing.expectEqual(1, probe.names);
    try std.testing.expect(probe.matches);
}

test "TLS hello: a connection the server closes ends with close_notify" {
    var h = try Https.init();
    defer h.deinit();
    const io = h.io;
    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .listeners = &.{.{ .address = loopback, .tls = .{ .pem = .{ .cert = h.pem.cert, .key = h.pem.key } } }},
    }, {});
    defer server.deinit();
    server.router.get("/", handleHello);
    var server_future = try io.concurrent(runServer, .{&server});
    defer server_future.cancel(io) catch {};
    try server.waitReady(io);

    const Peer = struct {
        fn run(port: u16) !void {
            const ctx = c.SSL_CTX_new(c.TLS_method()) orelse return error.OutOfMemory;
            defer c.SSL_CTX_free(ctx);
            const conn = try RawClient.connect(ctx, port, null);
            defer conn.close();
            const got = try conn.get();
            try std.testing.expect(got.hello);
            try std.testing.expect(got.close_notify);
        }
    };
    try RawClient.onThread(io, Peer.run, .{server.address.ip.getPort()});
}

test "TLS hello: an RSA-4096 handshake fits the default coroutine stacks on both ends" {
    // The heaviest key a handshake meets in practice: signing on the server
    // and verifying on the client both run on zio coroutine stacks of the
    // default size. Overflowing one would crash here.
    var h = try Https.initWith(.{ .key = .rsa4096 });
    defer h.deinit();
    const io = h.io;
    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .listeners = &.{.{ .address = loopback, .tls = .{ .pem = .{ .cert = h.pem.cert, .key = h.pem.key } } }},
    }, {});
    defer server.deinit();
    server.router.get("/", handleHello);
    var server_future = try io.concurrent(runServer, .{&server});
    defer server_future.cancel(io) catch {};

    var client_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void), _io: std.Io, ca: dusty.TlsCa) !void {
            try s.waitReady(_io);
            var url_buf: [64]u8 = undefined;
            const url = try std.fmt.bufPrint(&url_buf, "https://localhost:{d}/", .{s.address.ip.getPort()});
            // Two clients, so two connections and two full handshakes.
            for (0..2) |_| {
                var client = dusty.Client.init(std.testing.allocator, _io, .{ .tls = .{ .ca = ca } });
                defer client.deinit();
                var response = try client.fetch(url, .{});
                defer response.deinit();
                try std.testing.expectEqualStrings("hello over tls", (try response.body()).?);
            }
        }
    }.run, .{ &server, io, h.caFile() });
    try client_future.await(io);
}

test "TLS hello: a returning client resumes its session with a ticket" {
    var h = try Https.init();
    defer h.deinit();
    const io = h.io;
    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .listeners = &.{.{ .address = loopback, .tls = .{ .pem = .{ .cert = h.pem.cert, .key = h.pem.key } } }},
    }, {});
    defer server.deinit();
    server.router.get("/", handleHello);
    var server_future = try io.concurrent(runServer, .{&server});
    defer server_future.cancel(io) catch {};
    try server.waitReady(io);

    const Returning = struct {
        /// The latest session the server issued: in TLS 1.3 sessions come
        /// in NewSessionTicket messages after the handshake, and BoringSSL
        /// hands them to this callback rather than to `SSL_get1_session`.
        var latest: ?*c.SSL_SESSION = null;

        fn onNewSession(_: ?*c.SSL, session: ?*c.SSL_SESSION) callconv(.c) c_int {
            if (latest) |old| c.SSL_SESSION_free(old);
            latest = session;
            return 1; // keeps the reference
        }

        fn run(port: u16, version: u16) !void {
            const ctx = c.SSL_CTX_new(c.TLS_method()) orelse return error.OutOfMemory;
            defer c.SSL_CTX_free(ctx);
            _ = c.SSL_CTX_set_min_proto_version(ctx, version);
            _ = c.SSL_CTX_set_max_proto_version(ctx, version);
            // Client sessions reach the callback only with a client cache
            // mode set.
            _ = c.SSL_CTX_set_session_cache_mode(ctx, c.SSL_SESS_CACHE_CLIENT);
            c.SSL_CTX_sess_set_new_cb(ctx, onNewSession);
            defer if (latest) |sess| {
                c.SSL_SESSION_free(sess);
                latest = null;
            };

            const first = try RawClient.connect(ctx, port, null);
            const got = try first.get();
            try std.testing.expect(got.hello);
            try std.testing.expectEqual(0, c.SSL_session_reused(first.ssl));
            first.close();
            const session = latest orelse return error.NoSession;

            const second = try RawClient.connect(ctx, port, session);
            defer second.close();
            try std.testing.expectEqual(1, c.SSL_session_reused(second.ssl));
            try std.testing.expect((try second.get()).hello);
        }
    };
    try RawClient.onThread(io, Returning.run, .{ server.address.ip.getPort(), @as(u16, c.TLS1_3_VERSION) });
    try RawClient.onThread(io, Returning.run, .{ server.address.ip.getPort(), @as(u16, c.TLS1_2_VERSION) });
}

test "TLS hello: a certificate reload serves the new certificate, and tickets from before it still resume" {
    var h = try Https.init();
    defer h.deinit();
    const io = h.io;
    const gpa = std.testing.allocator;
    var next = try selfSigned(gpa, .{});
    defer next.deinit(gpa);
    // The configuration the server reads again on a reload.
    var listeners = [_]dusty.Listener{.{ .address = loopback, .tls = .{ .pem = .{ .cert = h.pem.cert, .key = h.pem.key } } }};
    var server = dusty.Server(void).init(gpa, io, .{ .listeners = &listeners }, {});
    defer server.deinit();
    server.router.get("/", handleHello);
    var server_future = try io.concurrent(runServer, .{&server});
    defer server_future.cancel(io) catch {};
    try server.waitReady(io);

    const Client = struct {
        var latest: ?*c.SSL_SESSION = null;
        ctx: *c.SSL_CTX,
        /// The leaf certificate (DER) the last handshake was served.
        leaf: [4096]u8 = undefined,
        leaf_len: usize = 0,
        reused: bool = false,

        fn onNewSession(_: ?*c.SSL, session: ?*c.SSL_SESSION) callconv(.c) c_int {
            if (latest) |old| c.SSL_SESSION_free(old);
            latest = session;
            return 1;
        }

        fn visit(cl: *@This(), port: u16, session: ?*c.SSL_SESSION) !void {
            const conn = try RawClient.connect(cl.ctx, port, session);
            defer conn.close();
            try std.testing.expect((try conn.get()).hello);
            cl.reused = c.SSL_session_reused(conn.ssl) == 1;
            const certs = c.SSL_get0_peer_certificates(conn.ssl) orelse return error.NoCertificate;
            const leaf = c.sk_CRYPTO_BUFFER_value(certs, 0);
            cl.leaf_len = c.CRYPTO_BUFFER_len(leaf);
            @memcpy(cl.leaf[0..cl.leaf_len], c.CRYPTO_BUFFER_data(leaf)[0..cl.leaf_len]);
        }
    };

    for ([_]u16{ c.TLS1_3_VERSION, c.TLS1_2_VERSION }) |version| {
        const ctx = c.SSL_CTX_new(c.TLS_method()) orelse return error.OutOfMemory;
        defer c.SSL_CTX_free(ctx);
        _ = c.SSL_CTX_set_min_proto_version(ctx, version);
        _ = c.SSL_CTX_set_max_proto_version(ctx, version);
        _ = c.SSL_CTX_set_session_cache_mode(ctx, c.SSL_SESS_CACHE_CLIENT);
        c.SSL_CTX_sess_set_new_cb(ctx, Client.onNewSession);
        defer if (Client.latest) |sess| {
            c.SSL_SESSION_free(sess);
            Client.latest = null;
        };
        const port = server.address.ip.getPort();

        listeners[0].tls.?.pem = .{ .cert = h.pem.cert, .key = h.pem.key };
        try server.reloadTls();
        var before: Client = .{ .ctx = ctx };
        try RawClient.onThread(io, Client.visit, .{ &before, port, null });
        // The ticket sealed before the reload, kept apart from the ones
        // issued after it.
        const sealed_before = Client.latest orelse return error.NoSession;
        Client.latest = null;
        defer c.SSL_SESSION_free(sealed_before);

        listeners[0].tls.?.pem = .{ .cert = next.cert, .key = next.key };
        try server.reloadTls();
        // A new handshake gets the new certificate...
        var fresh: Client = .{ .ctx = ctx };
        try RawClient.onThread(io, Client.visit, .{ &fresh, port, null });
        try std.testing.expect(!fresh.reused);
        try std.testing.expect(!std.mem.eql(u8, before.leaf[0..before.leaf_len], fresh.leaf[0..fresh.leaf_len]));
        // ...and a ticket sealed before the reload still resumes.
        var returning: Client = .{ .ctx = ctx };
        try RawClient.onThread(io, Client.visit, .{ &returning, port, sealed_before });
        try std.testing.expect(returning.reused);
    }
}
