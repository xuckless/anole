//! The ngtcp2-to-nghttp3 bridge that the HTTP/3 server and client share:
//! stream data in, and packets out with nghttp3's frames in them. Each
//! runs with the connection's mutex held. After ngtcp2's
//! examples/http3_server_proto_codec.cc and http3_client_proto_codec.cc
//! (MIT).
const std = @import("std");
const ngtcp2 = @import("ngtcp2.zig");
const nghttp3 = @import("nghttp3.zig");
const webtransport = @import("webtransport.zig");

const c = ngtcp2.c;
const h = nghttp3.c;

const log = std.log.scoped(.anole_h3);

/// One side of a connection, as the bridge sees it.
pub const Side = struct {
    q: *c.ngtcp2_conn,
    h3: ?*h.nghttp3_conn,
    last_error: *c.ngtcp2_ccerr,
    /// WebTransport's streams and datagrams, when the connection speaks it.
    wt: ?*webtransport.Core = null,
};

/// Feeds nghttp3 the stream data ngtcp2 delivered, and gives back the
/// flow-control credit for nghttp3's own framing (a body's comes back as
/// it is read). WebTransport's streams are taken out first, so nghttp3
/// never sees them. Returns an ngtcp2 callback result.
pub fn recvStreamData(side: Side, flags: u32, stream_id: i64, offset: u64, data: []const u8) c_int {
    const fin = flags & c.NGTCP2_STREAM_DATA_FLAG_FIN != 0;
    var replay: []const u8 = &.{};
    var head: webtransport.Partial = .{};
    if (side.wt) |w| {
        const route = w.route(stream_id, offset, data, fin) catch return c.NGTCP2_ERR_CALLBACK_FAILURE;
        switch (route) {
            .taken => return 0,
            .http3 => |partial| {
                head = partial;
                replay = head.bytes[0..head.len];
            },
        }
    }
    const hc = side.h3 orelse return 0;
    // The first bytes of a stream WebTransport held back to look at.
    if (replay.len > 0) if (readStream(side, hc, stream_id, replay, false) != 0) return c.NGTCP2_ERR_CALLBACK_FAILURE;
    return readStream(side, hc, stream_id, data, fin);
}

fn readStream(side: Side, hc: *h.nghttp3_conn, stream_id: i64, data: []const u8, fin: bool) c_int {
    const n = h.nghttp3_conn_read_stream2(hc, stream_id, data.ptr, data.len, @intFromBool(fin), c.ngtcp2_conn_get_timestamp(side.q));
    if (n < 0) {
        log.debug("nghttp3_conn_read_stream2: {s}", .{h.nghttp3_strerror(@intCast(n))});
        c.ngtcp2_ccerr_set_application_error(side.last_error, h.nghttp3_err_infer_quic_app_error_code(@intCast(n)), null, 0);
        return c.NGTCP2_ERR_CALLBACK_FAILURE;
    }
    consume(side.q, stream_id, @intCast(n));
    return 0;
}

/// Returns `n` bytes of flow-control credit, to the stream and the
/// connection.
pub fn consume(q: *c.ngtcp2_conn, stream_id: i64, n: u64) void {
    _ = c.ngtcp2_conn_extend_max_stream_offset(q, stream_id, n);
    c.ngtcp2_conn_extend_max_offset(q, n);
}

/// ngtcp2 pulls packets; nghttp3 supplies what goes in them. The body of
/// the `write_pkt` callback of `ngtcp2_conn_write_aggregate_pkt2`.
pub fn writePacket(side: Side, p: [*c]c.ngtcp2_path, pi: [*c]c.ngtcp2_pkt_info, dest: [*c]u8, dest_len: usize, ts: u64) c.ngtcp2_ssize {
    const q = side.q;
    var vec: [16]h.nghttp3_vec = undefined;
    // WebTransport: datagrams first (they are small and go stale), then
    // its streams and nghttp3's take turns at leading a packet.
    var datagrams = side.wt != null;
    const wt_first = if (side.wt) |w| w.takeTurn() else false;
    while (true) {
        if (side.wt) |w| {
            if (datagrams) if (w.writeDatagram(p, pi, dest[0..dest_len], ts)) |wrote| switch (wrote) {
                .more => continue,
                .packet => |n| return n,
                .skip => datagrams = false,
                .failed => |rv| return fail(side, rv),
            };
            if (wt_first) if (w.writeStream(p, pi, dest[0..dest_len], ts)) |wrote| switch (wrote) {
                .more => continue,
                .skip => {},
                .packet => |n| return n,
                .failed => |rv| return fail(side, rv),
            };
        }
        var stream_id: i64 = -1;
        var fin: c_int = 0;
        var count: h.nghttp3_ssize = 0;
        if (side.h3) |hc| if (c.ngtcp2_conn_get_max_data_left2(q) > 0) {
            count = h.nghttp3_conn_writev_stream(hc, &stream_id, &fin, &vec, vec.len);
            if (count < 0) {
                c.ngtcp2_ccerr_set_application_error(side.last_error, h.nghttp3_err_infer_quic_app_error_code(@intCast(count)), null, 0);
                return c.NGTCP2_ERR_CALLBACK_FAILURE;
            }
        };
        // Nothing from nghttp3: WebTransport's streams, if they did not
        // go first, before a packet of only acknowledgements and the like.
        if (stream_id < 0 and !wt_first) if (side.wt) |w| if (w.writeStream(p, pi, dest[0..dest_len], ts)) |wrote| switch (wrote) {
            .more => continue,
            .skip => {},
            .packet => |n| return n,
            .failed => |rv| return fail(side, rv),
        };
        var flags: u32 = c.NGTCP2_WRITE_STREAM_FLAG_MORE | c.NGTCP2_WRITE_STREAM_FLAG_PADDING;
        if (fin != 0) flags |= c.NGTCP2_WRITE_STREAM_FLAG_FIN;
        var data_len: c.ngtcp2_ssize = -1;
        const datav: []const c.ngtcp2_vec = @as([*]const c.ngtcp2_vec, @ptrCast(&vec))[0..@intCast(count)];
        const n = ngtcp2.connWritevStream(q, p, pi, dest[0..dest_len], &data_len, flags, stream_id, datav, ts);
        if (n < 0) {
            switch (n) {
                c.NGTCP2_ERR_STREAM_DATA_BLOCKED => {
                    _ = h.nghttp3_conn_block_stream(side.h3, stream_id);
                    continue;
                },
                c.NGTCP2_ERR_STREAM_SHUT_WR => {
                    _ = h.nghttp3_conn_shutdown_stream_write(side.h3, stream_id);
                    continue;
                },
                c.NGTCP2_ERR_WRITE_MORE => {
                    if (h.nghttp3_conn_add_write_offset(side.h3, stream_id, @intCast(data_len)) != 0)
                        return c.NGTCP2_ERR_CALLBACK_FAILURE;
                    continue;
                },
                else => {
                    c.ngtcp2_ccerr_set_liberr(side.last_error, @intCast(n), null, 0);
                    return c.NGTCP2_ERR_CALLBACK_FAILURE;
                },
            }
        }
        if (data_len >= 0) {
            if (h.nghttp3_conn_add_write_offset(side.h3, stream_id, @intCast(data_len)) != 0)
                return c.NGTCP2_ERR_CALLBACK_FAILURE;
        }
        return n;
    }
}

/// A write that failed with ngtcp2 error `rv`: the connection ends with it.
fn fail(side: Side, rv: c.ngtcp2_ssize) c.ngtcp2_ssize {
    if (side.last_error.error_code == 0) c.ngtcp2_ccerr_set_liberr(side.last_error, @intCast(rv), null, 0);
    return c.NGTCP2_ERR_CALLBACK_FAILURE;
}

/// Tells nghttp3 a QUIC stream closed. Returns an ngtcp2 callback result.
pub fn closeStream(side: Side, flags: u32, stream_id: i64, rx_code: u64, tx_code: u64) c_int {
    const hc = side.h3 orelse return 0;
    var h3_flags: u32 = h.NGHTTP3_STREAM_CLOSE_FLAG_NONE;
    if (flags & c.NGTCP2_STREAM_CLOSE2_FLAG_RX_APP_ERROR_CODE_SET != 0) h3_flags |= h.NGHTTP3_STREAM_CLOSE_FLAG_RX_APP_ERROR_CODE_SET;
    if (flags & c.NGTCP2_STREAM_CLOSE2_FLAG_TX_APP_ERROR_CODE_SET != 0) h3_flags |= h.NGHTTP3_STREAM_CLOSE_FLAG_TX_APP_ERROR_CODE_SET;
    const rv = h.nghttp3_conn_close_stream2(hc, h3_flags, stream_id, rx_code, tx_code);
    if (rv != 0 and rv != h.NGHTTP3_ERR_STREAM_NOT_FOUND) {
        c.ngtcp2_ccerr_set_application_error(side.last_error, h.nghttp3_err_infer_quic_app_error_code(rv), null, 0);
        return c.NGTCP2_ERR_CALLBACK_FAILURE;
    }
    return 0;
}

/// A body ring: [acked, sent) handed to nghttp3 and not yet acknowledged,
/// [sent, written) not yet handed over. nghttp3 does not copy body data, so
/// bytes stay here until the peer acknowledges them. Counters only grow;
/// positions are taken modulo the ring.
pub const Ring = struct {
    buf: []u8 = &.{},
    acked: u64 = 0,
    sent: u64 = 0,
    written: u64 = 0,

    pub const len = 64 * 1024;

    pub fn deinit(r: *Ring, gpa: std.mem.Allocator) void {
        if (r.buf.len > 0) gpa.free(r.buf);
        r.* = undefined;
    }

    /// Copies in what fits; returns how much did.
    pub fn write(r: *Ring, gpa: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!usize {
        if (r.buf.len == 0) r.buf = try gpa.alloc(u8, len);
        const free = r.buf.len - @as(usize, @intCast(r.written - r.acked));
        const n = @min(free, bytes.len);
        var i: usize = 0;
        while (i < n) {
            const pos: usize = @intCast((r.written + i) % r.buf.len);
            const k = @min(n - i, r.buf.len - pos);
            @memcpy(r.buf[pos..][0..k], bytes[i..][0..k]);
            i += k;
        }
        r.written += n;
        return n;
    }

    /// Everything written has been handed to nghttp3.
    pub fn allSent(r: *const Ring) bool {
        return r.sent == r.written;
    }

    /// Hands what is written and not yet sent to nghttp3, in one or two
    /// runs (the ring may wrap). Returns the vector count.
    pub fn take(r: *Ring, vec: [*c]h.nghttp3_vec, veccnt: usize) usize {
        var count: usize = 0;
        var from = r.sent;
        while (from < r.written and count < veccnt) {
            const pos: usize = @intCast(from % r.buf.len);
            const k: usize = @min(@as(usize, @intCast(r.written - from)), r.buf.len - pos);
            vec[count] = .{ .base = r.buf[pos..].ptr, .len = k };
            count += 1;
            from += k;
        }
        r.sent = from;
        return count;
    }

    /// What is written and not yet sent, in one or two runs (the ring may
    /// wrap), leaving `sent` where it is: for a writer that learns only
    /// afterwards how much went (`ngtcp2_conn_writev_stream`). Returns the
    /// run count.
    pub fn unsent(r: *const Ring, runs: *[2][]const u8) usize {
        var count: usize = 0;
        var from = r.sent;
        while (from < r.written and count < runs.len) {
            const pos: usize = @intCast(from % r.buf.len);
            const k: usize = @min(@as(usize, @intCast(r.written - from)), r.buf.len - pos);
            runs[count] = r.buf[pos..][0..k];
            count += 1;
            from += k;
        }
        return count;
    }
};

test "ring wraps and keeps unacknowledged bytes" {
    const gpa = std.testing.allocator;
    var r: Ring = .{};
    defer r.deinit(gpa);
    const big = try gpa.alloc(u8, Ring.len + 10);
    defer gpa.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i);
    try std.testing.expectEqual(@as(usize, Ring.len), try r.write(gpa, big));
    try std.testing.expectEqual(@as(usize, 0), try r.write(gpa, big[Ring.len..]));
    var vec: [2]h.nghttp3_vec = undefined;
    try std.testing.expectEqual(@as(usize, 1), r.take(&vec, vec.len));
    try std.testing.expectEqual(@as(usize, Ring.len), vec[0].len);
    r.acked += 100;
    try std.testing.expectEqual(@as(usize, 10), try r.write(gpa, big[Ring.len..]));
    try std.testing.expectEqual(@as(usize, 1), r.take(&vec, vec.len));
    try std.testing.expectEqual(@as(usize, 10), vec[0].len);
    try std.testing.expectEqual(big[Ring.len], vec[0].base[0]);
    try std.testing.expect(r.allSent());
}
