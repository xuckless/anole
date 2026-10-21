// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

//! Stub `h2_client` module: no HTTP/2 client is injected, so the client
//! never offers "h2" through ALPN and speaks HTTP/1.1 only. An application
//! with an HTTP/2 client (Anole's, on nghttp2) overrides this import:
//!
//!     dusty_mod.addImport("h2_client", its_h2_client_module);
//!
//! What dusty needs from it (see `client.zig`, `has_h2_client`):
//!
//!     ClientConnection.adopt(gpa, io, reader, writer, socket) !*ClientConnection
//!         takes over a TLS connection that negotiated "h2": the cleartext
//!         reader and writer and the socket (shut down, not closed, when the
//!         session ends)
//!     conn.request(headers: []const Header, .{ .body_bytes = ?[]const u8, .timeout = .none }) !*Stream
//!     conn.isOpen() bool, conn.close()
//!     Header = struct { name: []const u8, value: []const u8 }
//!     stream.waitHead(), stream.status (u16),
//!     stream.headers.items ([]Header), stream.reader(), stream.readError(),
//!     Stream.ofReader(reader) *Stream, stream.release()

pub const is_stub = true;
