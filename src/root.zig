//! Anole: one Zig server core for REST, WebSockets and gRPC.
//!
//! Pre-alpha. `Server` is the entry point: HTTP/1.1, HTTP/2 (h2c and over
//! TLS) and HTTPS on BoringSSL, with routing, middleware and compression from
//! the dusty fork. Each namespace below wraps a library built under Zig 0.17;
//! one whose feature is turned off at build time is an empty struct, and its
//! C library is neither fetched nor compiled.
const std = @import("std");

/// The feature flags this build was configured with (`-Dprofile`, `-Dtls`,
/// `-Dhttp2`, `-Dhttp3`, `-Dgrpc`, `-Dwebsocket`, `-Dauth`).
pub const features = @import("build_options");

/// The async runtime (lalinsky/zio). Executables pick the scheduling mode with
/// `pub const zio_options: anole.zio.Options = .{ .scheduling = .pinned };`
/// in their root file.
pub const zio = @import("zio");

/// The server: runtime, listeners, signals and drain in one call. See
/// `server.zig`.
pub const Server = @import("server.zig").Server;
pub const ServerOptions = @import("server.zig").Options;
/// Declare in the executable's root file: `pub const zio_options =
/// anole.zio_options;` (pinned scheduling).
pub const zio_options = @import("server.zig").zio_options;
/// Log output with the underlying libraries' scopes renamed to Anole's:
/// `pub const std_options: std.Options = .{ .logFn = anole.logFn };`.
pub const logFn = @import("log.zig").logFn;

/// HTTP/1.1 and HTTP/2 server, router and client (the xuckless/dusty fork of
/// lalinsky/dusty, on zio), for everything `Server` does not wrap.
pub const http = @import("http/root.zig");
pub const Request = http.Request;
pub const Response = http.Response;
pub const middleware = http.middleware;
pub const Middleware = http.Middleware;

/// TLS on BoringSSL (-Dtls=boringssl): the bindings, the module dusty uses for
/// HTTPS, and `selfSigned` for development certificates.
pub const tls = if (features.tls == .boringssl) @import("tls/root.zig") else struct {};

/// nghttp2 bindings (-Dhttp2). The HTTP/2 server engine lives in the dusty
/// fork and serves through `Server`.
pub const h2 = if (features.http2) @import("h2/root.zig") else struct {};

/// ngtcp2 + nghttp3 bindings (-Dhttp3). The QUIC endpoint is later work.
pub const h3 = if (features.http3) @import("h3/root.zig") else struct {};

/// gzip/deflate on zlib-ng and zstd (-Dcompression). dusty uses the zlib
/// side for response compression and request decoding.
pub const compression = if (features.compression) @import("compression/root.zig") else struct {};

/// dusty's RFC 6455 WebSocket over HTTP/1.1 (-Dwebsocket).
pub const websocket = if (features.websocket) @import("websocket/root.zig") else struct {};

// -Dgrpc and -Dauth are accepted and validated (gRPC needs HTTP/2), but no
// gRPC or auth code exists yet, so there is no namespace for them.

test {
    _ = @import("server.zig");
    _ = @import("log.zig");
    _ = http;
    _ = tls;
    _ = h2;
    _ = h3;
    _ = websocket;
    _ = compression;
}

test "feature constraints hold" {
    if (features.grpc) try std.testing.expect(features.http2);
    if (features.http3) try std.testing.expect(features.tls != .none);
}
