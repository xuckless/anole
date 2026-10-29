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
/// The HTTP/3 server endpoint for a the core server's router.
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
/// The `h3` alternative of an `Alt-Svc` header field value (RFC 7838), for
/// clients that switch to HTTP/3.
pub const parseAltSvc = @import("alt_svc.zig").parse;
/// What `parseAltSvc` found.
pub const AltSvc = @import("alt_svc.zig").Result;
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

test "h3.version() names the pinned ngtcp2 and nghttp3, and the libraries match their headers" {
    const c = ngtcp2.c;
    const h = nghttp3.c;
    const qi = c.ngtcp2_version(0) orelse return error.Ngtcp2Version;
    const hi = h.nghttp3_version(0) orelse return error.Nghttp3Version;
    // The libraries linked are the ones the translated headers describe.
    try std.testing.expectEqual(@as(c_int, c.NGTCP2_VERSION_NUM), qi.*.version_num);
    try std.testing.expectEqual(@as(c_int, h.NGHTTP3_VERSION_NUM), hi.*.version_num);
    try std.testing.expectEqualStrings("1.25.0", ngtcp2Version());
    try std.testing.expectEqualStrings("1.18.0", nghttp3Version());
    try std.testing.expectEqualStrings("ngtcp2/1.25.0 nghttp3/1.18.0", version());
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
    _ = @import("alt_svc.zig");
}
