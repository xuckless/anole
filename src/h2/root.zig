//! HTTP/2 (-Dhttp2): the client connection, on nghttp2 1.70.0 (MIT, bound
//! through the official translate-c package). The server side needs
//! nothing from here: `anole.App` serves HTTP/2 over TLS (ALPN "h2") and
//! cleartext (h2c) through the HTTP core's engine
//! (src/http/core/server/h2.zig).
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

/// The translated nghttp2.h, for this file's tests.
const c = @import("anole_nghttp2_c");

/// The library under HTTP/2 in this build, as "nghttp2/1.70.0".
/// `anole.h3.version()` has the same shape.
pub fn version() []const u8 {
    return "nghttp2/" ++ c.NGHTTP2_VERSION;
}

// Smoke tests, from the M1 nghttp2 proof.
const Ctx = struct {
    frames_recv: usize = 0,
    settings_recv: bool = false,
};

fn onFrameRecv(session: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = session;
    const ctx: *Ctx = @ptrCast(@alignCast(user_data.?));
    ctx.frames_recv += 1;
    if (frame.*.hd.type == c.NGHTTP2_SETTINGS) ctx.settings_recv = true;
    return 0;
}

test {
    _ = @import("client_test.zig");
}

test "nghttp2 version" {
    const info = c.nghttp2_version(0);
    try std.testing.expect(info != null);
    // The library linked is the one the header describes.
    try std.testing.expectEqualStrings(c.NGHTTP2_VERSION, std.mem.span(info.*.version_str));
    try std.testing.expectEqualStrings("nghttp2/1.70.0", version());
}

test "nghttp2 server session: submit settings, mem_send2, mem_recv2 preface + SETTINGS" {
    var callbacks: ?*c.nghttp2_session_callbacks = null;
    try std.testing.expectEqual(@as(c_int, 0), c.nghttp2_session_callbacks_new(&callbacks));
    defer c.nghttp2_session_callbacks_del(callbacks);
    c.nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks, onFrameRecv);

    var ctx: Ctx = .{};
    var session: ?*c.nghttp2_session = null;
    try std.testing.expectEqual(@as(c_int, 0), c.nghttp2_session_server_new(&session, callbacks, &ctx));
    defer c.nghttp2_session_del(session);

    const iv = [_]c.nghttp2_settings_entry{
        .{ .settings_id = c.NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS, .value = 100 },
    };
    try std.testing.expectEqual(@as(c_int, 0), c.nghttp2_submit_settings(session, c.NGHTTP2_FLAG_NONE, &iv, iv.len));

    // Drain everything the session wants to send.
    var total: usize = 0;
    while (true) {
        var data: [*c]const u8 = null;
        const n = c.nghttp2_session_mem_send2(session, &data);
        try std.testing.expect(n >= 0);
        if (n == 0) break;
        total += @intCast(n);
    }
    // 9-byte frame header + one 6-byte settings entry.
    try std.testing.expect(total > 0);
    try std.testing.expectEqual(@as(usize, 15), total);

    // Client connection preface (24 bytes) + an empty SETTINGS frame (9 bytes).
    const preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
    comptime std.debug.assert(preface.len == 24);
    const empty_settings = [_]u8{ 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const input = preface ++ empty_settings;
    const consumed = c.nghttp2_session_mem_recv2(session, input, input.len);
    try std.testing.expectEqual(@as(isize, input.len), consumed);
    try std.testing.expect(ctx.settings_recv);
    try std.testing.expectEqual(@as(usize, 1), ctx.frames_recv);

    // The server must now owe a SETTINGS ACK.
    try std.testing.expect(c.nghttp2_session_want_write(session) != 0);
    var data: [*c]const u8 = null;
    const ack_len = c.nghttp2_session_mem_send2(session, &data);
    try std.testing.expectEqual(@as(isize, 9), ack_len);
    try std.testing.expectEqual(@as(u8, c.NGHTTP2_SETTINGS), data[3]);
    try std.testing.expectEqual(@as(u8, c.NGHTTP2_FLAG_ACK), data[4]);
}
