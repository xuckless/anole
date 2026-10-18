//! HTTP/2: nghttp2 1.70.0 (MIT) bindings from the official translate-c package.
//! Only the bindings exist so far; the server engine is Milestone 2.
const std = @import("std");

/// The translated nghttp2.h.
pub const c = @import("anole_nghttp2_c");

/// The nghttp2 version this build links (runtime value, e.g. "1.70.0").
pub fn version() []const u8 {
    const info = c.nghttp2_version(0);
    return std.mem.span(info.*.version_str);
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

test "nghttp2 version" {
    const info = c.nghttp2_version(0);
    try std.testing.expect(info != null);
    try std.testing.expectEqualStrings("1.70.0", version());
    try std.testing.expectEqualStrings("1.70.0", c.NGHTTP2_VERSION);
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
