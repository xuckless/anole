//! WebSocket: dusty's RFC 6455 implementation over HTTP/1.1 (MIT). The RFC 8441
//! bridge over HTTP/2 and permessage-deflate are later work.
const std = @import("std");
const dusty = @import("dusty");

/// A server-side or client-side WebSocket connection.
pub const WebSocket = dusty.WebSocket;
/// dusty's client for `ws://` URLs (`wss://` once the TLS seam lands).
pub const Client = dusty.WebSocketClient;
pub const UpgradeOptions = dusty.WebSocketUpgradeOptions;

test "WebSocket accept key matches RFC 6455 section 1.3" {
    var out: [28]u8 = undefined;
    WebSocket.computeAcceptKey("dGhlIHNhbXBsZSBub25jZQ==", &out);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &out);
}
