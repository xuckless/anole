//! HTTP/2 (-Dhttp2): the client connection, on the HTTP core's own
//! protocol core (src/http/core/h2/conn.zig's client role). The server side needs
//! nothing from here: `anole.App` serves HTTP/2 over TLS (ALPN "h2") and
//! cleartext (h2c) through the HTTP core's engine
//! (src/http/core/h2/server.zig).
//!
//!     const conn = try anole.h2.ClientConnection.connect(gpa, io, .{ .host = "127.0.0.1", .port = 8080 });
//!     defer conn.close();
//!
//! `anole.h3` has the same client names, and its options mean the same
//! where they share a name, so code can be written over either; options
//! only one protocol has say so. For plain HTTPS requests
//! `anole.client(req).fetch` is simpler; it speaks HTTP/2 when the server
//! picks it.
const std = @import("std");

const client = @import("anole_h2_client");

/// An HTTP/2 client connection (cleartext or TLS), many streams at once.
/// `anole.h3` has the same names for HTTP/3.
pub const ClientConnection = client.ClientConnection;
/// One request and its response.
pub const Stream = client.Stream;
/// A header field, name and value.
pub const Header = client.Header;
/// Host, port, TLS, windows and timeouts for `ClientConnection.connect`.
pub const ConnectOptions = client.ConnectOptions;
/// Per request: `body`, `timeout`, and HTTP/2's own `body_bytes`.
pub const RequestOptions = client.ClientConnection.RequestOptions;
/// Why a stream ended early (`Stream.waitHead`, `readError`, `writeError`).
pub const StreamError = client.StreamError;

/// The HTTP/2 implementation in this build: Anole's own core (the codecs
/// and `Conn` translate nghttp2 1.70.0's rules; nothing of nghttp2 is
/// linked). `anole.h3.version()` has the same shape.
pub fn version() []const u8 {
    return "anole-h2";
}

test {
    _ = @import("client_test.zig");
}
