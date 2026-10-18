//! TLS: BoringSSL (Apache-2.0) at 22a0079b, built by build/boringssl.zig, with
//! bindings from the official translate-c package over src/tls/bssl.h.
//!
//! `dusty_tls` is the module dusty uses for every HTTPS listener and every
//! HTTPS/WSS client connection; `selfSigned` makes a development certificate
//! in memory.
//!
//! The smoke test below is the M1 BoringSSL proof: an in-memory TLS handshake
//! between a client SSL and a server SSL over a BIO pair, with an ALPN select
//! callback that prefers "h2" then "http/1.1". The server key and self-signed
//! certificate are generated at run time and never touch the filesystem.
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

/// A certificate and private key as PEM text, owned by the allocator that
/// made them.
pub const Pem = struct {
    cert: []u8,
    key: []u8,

    pub fn deinit(self: *Pem, gpa: std.mem.Allocator) void {
        gpa.free(self.cert);
        std.crypto.secureZero(u8, self.key);
        gpa.free(self.key);
        self.* = undefined;
    }
};

pub const SelfSignedOptions = struct {
    /// Subject CN, also the first DNS subjectAltName.
    common_name: []const u8 = "localhost",
    /// subjectAltName entries, in OpenSSL config syntax.
    alt_names: []const u8 = "DNS:localhost,IP:127.0.0.1,IP:::1",
    valid_for_seconds: i64 = 7 * 24 * 3600,
};

/// A fresh P-256 key and a self-signed certificate for it, for development
/// and tests: nothing touches the disk. The certificate is its own CA
/// (`CA:TRUE`), so a client can trust it directly.
pub fn selfSigned(gpa: std.mem.Allocator, opt: SelfSignedOptions) !Pem {
    c.ERR_clear_error();
    defer c.ERR_clear_error();
    const pkey = c.EVP_PKEY_new() orelse return error.OutOfMemory;
    defer c.EVP_PKEY_free(pkey);
    {
        const ec = c.EC_KEY_new_by_curve_name(c.NID_X9_62_prime256v1) orelse return error.OutOfMemory;
        if (c.EC_KEY_generate_key(ec) != 1 or c.EVP_PKEY_assign_EC_KEY(pkey, ec) != 1) {
            c.EC_KEY_free(ec);
            return error.TlsKeyGenerationFailed;
        }
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
        const gpa = std.testing.allocator;
        const rt = try zio.Runtime.init(gpa, .{});
        errdefer rt.deinit();
        var pem = try selfSigned(gpa, .{});
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
            try s.ready.wait(_io);
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
            try s.ready.wait(_io);
            var client = dusty.Client.init(std.testing.allocator, _io, .{
                .tls = .{ .ca = .{ .file = .{ .path = "other.pem", .dir = dir } } },
            });
            defer client.deinit();
            var url_buf: [64]u8 = undefined;
            const url = try std.fmt.bufPrint(&url_buf, "https://localhost:{d}/", .{s.address.ip.getPort()});
            try std.testing.expectError(error.TlsCertificateVerifyFailed, client.fetch(url, .{}));
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
            try s.ready.wait(_io);
            var url_buf: [64]u8 = undefined;
            const url = try std.fmt.bufPrint(&url_buf, "https://localhost:{d}/", .{s.address.ip.getPort()});
            {
                var anon = dusty.Client.init(std.testing.allocator, _io, .{ .tls = .{ .ca = ca } });
                defer anon.deinit();
                // TLS 1.3: the client's flight is done before the server
                // refuses it, so the refusal is the alert on the first read,
                // or a reset when the server closed with the client's request
                // still unread (it does not linger), whichever arrives first.
                if (anon.fetch(url, .{})) |r| {
                    var resp = r;
                    resp.deinit();
                    return error.ServedWithoutClientCertificate;
                } else |err| switch (err) {
                    error.TlsAlert, error.ConnectionResetByPeer => {},
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
    try server.ready.wait(io);

    // A plain BoringSSL client on its own thread (blocking socket I/O must
    // not hold up the runtime), which only reads what the server asked for.
    const Probe = struct {
        port: u16,
        names: usize = 0,
        matches: bool = false,
        failed: ?anyerror = null,
        done: std.atomic.Value(bool) = .init(false),

        expected: []const u8 = &.{},

        fn run(p: *@This()) void {
            defer p.done.store(true, .release);
            p.probe() catch |err| {
                p.failed = err;
            };
        }

        /// The requested CAs are readable only during the handshake.
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

        fn probe(p: *@This()) !void {
            const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
            if (fd < 0) return error.Socket;
            defer _ = std.c.close(fd);
            var addr: std.c.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, p.port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
            if (std.c.connect(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) != 0) return error.Connect;
            const ctx = c.SSL_CTX_new(c.TLS_method()) orelse return error.OutOfMemory;
            defer c.SSL_CTX_free(ctx);
            c.SSL_CTX_set_cert_cb(ctx, certCb, p);
            const ssl = c.SSL_new(ctx) orelse return error.OutOfMemory;
            defer c.SSL_free(ssl);
            _ = c.SSL_set_fd(ssl, fd);
            // Unverified: this client only looks at the request.
            if (c.SSL_connect(ssl) != 1) return error.Handshake;
            _ = c.SSL_shutdown(ssl);
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

    var probe: Probe = .{ .port = server.address.ip.getPort(), .expected = subject_der[0..subject_len] };
    const thread = try std.Thread.spawn(.{}, Probe.run, .{&probe});
    while (!probe.done.load(.acquire)) try io.sleep(.fromMilliseconds(2), .awake);
    thread.join();
    if (probe.failed) |err| return err;
    try std.testing.expectEqual(1, probe.names);
    try std.testing.expect(probe.matches);
}
