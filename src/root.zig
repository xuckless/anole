//! Anole: one Zig server core for REST, WebSockets and gRPC.
//!
//! Pre-alpha (Milestone 1). What exists today is the dependency layer: each
//! namespace below wraps a library that is built, linked and smoke-tested under
//! Zig 0.17. A namespace whose feature is turned off at build time is an empty
//! struct, and its C library is neither fetched nor compiled.
const std = @import("std");

/// The feature flags this build was configured with (`-Dprofile`, `-Dtls`,
/// `-Dhttp2`, `-Dhttp3`, `-Dgrpc`, `-Dwebsocket`, `-Dauth`).
pub const features = @import("build_options");

/// The async runtime (lalinsky/zio). Executables pick the scheduling mode with
/// `pub const zio_options: anole.zio.Options = .{ .scheduling = .pinned };`
/// in their root file.
pub const zio = @import("zio");

/// HTTP/1.1 server, router and client (lalinsky/dusty, on zio). Always on.
pub const http = @import("http/root.zig");

/// TLS on BoringSSL (-Dtls=boringssl): the bindings, the module dusty uses for
/// HTTPS, and `selfSigned` for development certificates.
pub const tls = if (features.tls == .boringssl) @import("tls/root.zig") else struct {};

/// nghttp2 bindings (-Dhttp2). The HTTP/2 server engine is Milestone 2.
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
