//! HTTP/3 over QUIC (-Dhttp3). A server needs nothing from here:
//! `app.listenTls` serves HTTP/3 on the same port by default, and
//! `ServerOptions.http3` sets it up for `https`. This namespace has the
//! client, `ClientConnection`, with the HTTP/2 client's API (the same
//! names as `anole.h2`), and `Endpoint`, the QUIC server endpoint the
//! server runs, for full control.
//!
//! Underneath: ngtcp2 1.25.0 (QUIC transport, from Anole's xuckless/ngtcp2
//! fork) with its BoringSSL crypto helper, and nghttp3 1.18.0 (HTTP/3 +
//! QPACK, from Anole's xuckless/nghttp3 fork), all MIT. WebTransport's
//! streams and datagrams sit beside nghttp3 (`anole.webtransport`).
const std = @import("std");

// The ngtcp2 and nghttp3 bindings, for this file's tests; the engine and
// the client import them directly.
const ngtcp2 = @import("ngtcp2.zig");
const nghttp3 = @import("nghttp3.zig");
/// The HTTP/3 server endpoint for a dusty server's router.
pub const Endpoint = @import("server.zig").Endpoint;
/// An `Endpoint`'s settings; `ServerOptions.Http3` is the usual way in.
pub const EndpointOptions = @import("server.zig").Options;
/// An endpoint's counters (`Endpoint.stats`): packets handled, passed on
/// between endpoints, connections accepted.
pub const EndpointStats = @import("server.zig").Stats;
/// Mutual TLS for an endpoint (`EndpointOptions.client_auth`).
pub const ClientAuth = @import("quic_tls.zig").ClientAuth;
/// A listener's TLS context; see `Endpoint.loadTls` and `Endpoint.useTls`.
pub const TlsContext = @import("quic_tls.zig").Context;
/// An HTTP/3 client connection: many concurrent requests over one QUIC
/// connection. The same names as `anole.h2`'s.
pub const ClientConnection = @import("client.zig").ClientConnection;
/// One request and its response.
pub const Stream = @import("client.zig").Stream;
/// A header field, name and value.
pub const Header = @import("client.zig").Header;
/// Host, port, TLS, windows, timeouts, session cache, 0-RTT and
/// WebTransport for `ClientConnection.connect`.
pub const ConnectOptions = @import("client.zig").ConnectOptions;
/// Per request: `body`, `timeout`, and HTTP/3's own `early`.
pub const RequestOptions = @import("client.zig").ClientConnection.RequestOptions;
/// Why a stream ended early (`Stream.waitHead`, `readError`, `writeError`).
pub const StreamError = @import("client.zig").StreamError;
/// Session tickets for resumption and 0-RTT (`ConnectOptions.session_cache`).
pub const SessionCache = @import("client.zig").SessionCache;
/// What became of a client connection's 0-RTT (`ClientConnection.earlyData`).
pub const EarlyData = @import("client.zig").EarlyData;
/// How `ClientConnection.rebind` moves a connection to a new socket.
pub const Rebind = @import("client.zig").Rebind;

/// The libraries under HTTP/3 in this build, as
/// "ngtcp2/1.25.0 nghttp3/1.18.0". `anole.h2.version()` has the same shape.
pub fn version() []const u8 {
    return "ngtcp2/" ++ ngtcp2.c.NGTCP2_VERSION ++ " nghttp3/" ++ nghttp3.c.NGHTTP3_VERSION;
}

fn ngtcp2Version() []const u8 {
    return std.mem.span(ngtcp2.c.ngtcp2_version(0).*.version_str);
}
fn nghttp3Version() []const u8 {
    return std.mem.span(nghttp3.c.nghttp3_version(0).*.version_str);
}

// Smoke test from the M1 QUIC proof: version info, SSL_CTX + the BoringSSL
// helper's configure_server_context, versioned settings/transport-params
// defaults, a real ngtcp2 server conn wired to the crypto helper callbacks, and
// an nghttp3 server conn.
test "HTTP/3 smoke: ngtcp2 + BoringSSL helper + nghttp3 server conns" {
    try std.testing.expectEqualStrings("1.25.0", ngtcp2Version());
    try std.testing.expectEqualStrings("1.18.0", nghttp3Version());
    try std.testing.expectEqualStrings("ngtcp2/1.25.0 nghttp3/1.18.0", version());
    try smoke();
}

fn smoke() !void {
    const q = ngtcp2;
    const h3 = nghttp3;
    const c = q.c;
    const h = h3.c;

    // 1. Versions.
    const qi = c.ngtcp2_version(0) orelse return error.Ngtcp2Version;
    const hi = h.nghttp3_version(0) orelse return error.Nghttp3Version;
    if (qi.*.version_num != c.NGTCP2_VERSION_NUM) return error.Ngtcp2HeaderLibMismatch;
    if (hi.*.version_num != h.NGHTTP3_VERSION_NUM) return error.Nghttp3HeaderLibMismatch;

    // 2. BoringSSL SSL_CTX configured by ngtcp2's crypto helper.
    const ssl_ctx = c.SSL_CTX_new(c.TLS_method()) orelse return error.SslCtxNew;
    defer c.SSL_CTX_free(ssl_ctx);
    if (c.ngtcp2_crypto_boringssl_configure_server_context(ssl_ctx) != 0) return error.ConfigureServerContext;

    // 3. Versioned defaults.
    var settings: q.Settings = undefined;
    q.settingsDefault(&settings);
    settings.initial_ts = 1;
    var params: q.TransportParams = undefined;
    q.transportParamsDefault(&params);
    params.initial_max_streams_bidi = 100;
    params.initial_max_streams_uni = 3;
    params.initial_max_data = 1 << 20;
    params.initial_max_stream_data_bidi_remote = 256 << 10;
    params.initial_max_stream_data_uni = 256 << 10;

    // 4. ngtcp2 server conn wired to the BoringSSL helper's callbacks, then freed.
    var dcid: q.Cid = undefined;
    var scid: q.Cid = undefined;
    var odcid: q.Cid = undefined;
    const dcid_bytes = [_]u8{ 0xd1, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8 };
    const scid_bytes = [_]u8{ 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58 };
    c.ngtcp2_cid_init(&dcid, &dcid_bytes, dcid_bytes.len);
    c.ngtcp2_cid_init(&scid, &scid_bytes, scid_bytes.len);
    c.ngtcp2_cid_init(&odcid, &dcid_bytes, dcid_bytes.len);
    params.original_dcid = odcid;
    params.original_dcid_present = 1;

    var local_sa = std.mem.zeroes(c.ngtcp2_sockaddr_in);
    var remote_sa = std.mem.zeroes(c.ngtcp2_sockaddr_in);
    local_sa.sin_family = c.AF_INET;
    remote_sa.sin_family = c.AF_INET;
    local_sa.sin_port = std.mem.nativeToBig(u16, 4433);
    remote_sa.sin_port = std.mem.nativeToBig(u16, 50000);
    var path: q.Path = .{
        .local = .{ .addr = @ptrCast(&local_sa), .addrlen = @sizeOf(c.ngtcp2_sockaddr_in) },
        .remote = .{ .addr = @ptrCast(&remote_sa), .addrlen = @sizeOf(c.ngtcp2_sockaddr_in) },
        .user_data = null,
    };

    var callbacks = std.mem.zeroes(q.Callbacks);
    callbacks.recv_client_initial = c.ngtcp2_crypto_recv_client_initial_cb;
    callbacks.recv_crypto_data = c.ngtcp2_crypto_recv_crypto_data_cb;
    callbacks.encrypt = c.ngtcp2_crypto_encrypt_cb;
    callbacks.decrypt = c.ngtcp2_crypto_decrypt_cb;
    callbacks.hp_mask = c.ngtcp2_crypto_hp_mask_cb;
    callbacks.update_key = c.ngtcp2_crypto_update_key_cb;
    callbacks.delete_crypto_aead_ctx = c.ngtcp2_crypto_delete_crypto_aead_ctx_cb;
    callbacks.delete_crypto_cipher_ctx = c.ngtcp2_crypto_delete_crypto_cipher_ctx_cb;
    callbacks.get_path_challenge_data2 = c.ngtcp2_crypto_get_path_challenge_data2_cb;
    callbacks.version_negotiation = c.ngtcp2_crypto_version_negotiation_cb;
    callbacks.rand = randCb;
    callbacks.get_new_connection_id2 = getNewConnectionIdCb;

    var conn: ?*q.Conn = null;
    const rv = q.connServerNew(&conn, &dcid, &scid, &path, c.NGTCP2_PROTO_VER_V1, &callbacks, &settings, &params, null, null);
    if (rv != 0) {
        return error.Ngtcp2ConnServerNew;
    }
    var cinfo: q.ConnInfo = undefined;
    q.connGetConnInfo(conn.?, &cinfo);
    try std.testing.expect(cinfo.cwnd > 0);
    c.ngtcp2_conn_del(conn);

    // 5. nghttp3 server conn, then freed.
    var h3_settings: h3.Settings = undefined;
    h3.settingsDefault(&h3_settings);
    const h3_callbacks = std.mem.zeroes(h3.Callbacks);
    var h3conn: ?*h3.Conn = null;
    const hrv = h3.connServerNew(&h3conn, &h3_callbacks, &h3_settings, null, null);
    if (hrv != 0) {
        return error.Nghttp3ConnServerNew;
    }
    h.nghttp3_conn_del(h3conn);
}

/// From the TLS bindings (src/tls/bssl.h): ngtcp2_crypto_boringssl.h does not
/// pull in <openssl/rand.h>. HTTP/3 always builds with BoringSSL.
const RAND_bytes = @import("anole_boringssl_c").RAND_bytes;

fn randCb(dest: [*c]u8, destlen: usize, _: [*c]const ngtcp2.c.ngtcp2_rand_ctx) callconv(.c) void {
    _ = RAND_bytes(dest, destlen);
}

fn getNewConnectionIdCb(
    _: ?*ngtcp2.c.ngtcp2_conn,
    cid: [*c]ngtcp2.c.ngtcp2_cid,
    token: [*c]ngtcp2.c.ngtcp2_stateless_reset_token,
    cidlen: usize,
    _: ?*anyopaque,
) callconv(.c) c_int {
    const c = ngtcp2.c;
    if (RAND_bytes(&cid.*.data, cidlen) != 1) return c.NGTCP2_ERR_CALLBACK_FAILURE;
    cid.*.datalen = cidlen;
    if (RAND_bytes(@ptrCast(token), @sizeOf(c.ngtcp2_stateless_reset_token)) != 1) return c.NGTCP2_ERR_CALLBACK_FAILURE;
    return 0;
}

test "ngtcp2/nghttp3 struct layouts match the C compiler" {
    try layoutTest();
}

fn layoutTest() !void {
    const q = ngtcp2;
    const h3 = nghttp3;
    const layout = @import("anole_h3_layout");
    const expect = std.testing.expectEqual;
    try expect(layout.ngtcp2_settings_size_get(), @as(usize, @sizeOf(q.Settings)));
    try expect(layout.ngtcp2_transport_params_size_get(), @as(usize, @sizeOf(q.TransportParams)));
    try expect(layout.ngtcp2_callbacks_size_get(), @as(usize, @sizeOf(q.Callbacks)));
    try expect(layout.ngtcp2_cid_size_get(), @as(usize, @sizeOf(q.Cid)));
    try expect(layout.ngtcp2_path_size_get(), @as(usize, @sizeOf(q.Path)));
    try expect(layout.ngtcp2_pkt_info_size_get(), @as(usize, @sizeOf(q.PktInfo)));
    try expect(layout.ngtcp2_pkt_info_align_get(), @as(usize, @alignOf(q.PktInfo)));
    try expect(layout.ngtcp2_conn_info_size_get(), @as(usize, @sizeOf(q.ConnInfo)));
    try expect(layout.ngtcp2_settings_initial_ts_off_get(), @as(usize, @offsetOf(q.Settings, "initial_ts")));
    try expect(layout.ngtcp2_settings_pmtud_probes_off_get(), @as(usize, @offsetOf(q.Settings, "pmtud_probes")));
    try expect(layout.ngtcp2_transport_params_original_dcid_present_off_get(), @as(usize, @offsetOf(q.TransportParams, "original_dcid_present")));
    try expect(layout.ngtcp2_callbacks_stream_close2_off_get(), @as(usize, @offsetOf(q.Callbacks, "stream_close2")));
    try expect(layout.nghttp3_settings_size_get(), @as(usize, @sizeOf(h3.Settings)));
    try expect(layout.nghttp3_callbacks_size_get(), @as(usize, @sizeOf(h3.Callbacks)));
    try expect(layout.nghttp3_pri_size_get(), @as(usize, @sizeOf(h3.Pri)));
    try expect(layout.nghttp3_pri_align_get(), @as(usize, @alignOf(h3.Pri)));
}

test {
    _ = @import("bridge.zig");
    _ = @import("net.zig");
    _ = @import("client_test.zig");
    _ = @import("steer.zig");
    _ = @import("percore_test.zig");
    _ = @import("session_cache.zig");
    _ = @import("quic_tls.zig");
}
