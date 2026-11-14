//! The HTTP/2 codecs and protocol core (research/h2h3-takeover/PLAN.md §3.1),
//! translated from nghttp2 where noted (see LICENSE.nghttp2 and
//! THIRD_PARTY_NOTICES): HPACK, frames, request field checks, the flood
//! limits, the stream state, and the sans-IO connection core (conn.zig) with
//! its output queue (out.zig), and the server engine on them (server.zig),
//! which serves the server's HTTP/2. src/h2/client.zig is the client on the
//! core's client role (`conn.Conn(.client, H)`, M5).

const std = @import("std");

pub const huffman = @import("huffman.zig");
pub const hpack = @import("hpack.zig");
pub const frame = @import("frame.zig");
pub const fields = @import("fields.zig");
pub const limits = @import("limits.zig");
pub const streams = @import("streams.zig");
pub const out = @import("out.zig");
pub const conn = @import("conn.zig");
pub const server = @import("server.zig");
/// Tests only: connections served by `server` without `Server.run`.
pub const test_server = if (@import("builtin").is_test) @import("test_server.zig") else struct {};

test {
    std.testing.refAllDecls(@This());
    _ = @import("hpack_test.zig");
    _ = @import("frame_test.zig");
    _ = @import("fields_test.zig");
    _ = @import("limits_test.zig");
    _ = @import("streams_test.zig");
    _ = @import("conn_test.zig");
    _ = @import("conn_client_test.zig");
    _ = @import("conn_limits_test.zig");
    // Against nghttp2's own inflater; compiled out with -Dhttp2=false.
    if (@import("build_options").use_http2) {
        _ = @import("hpack_diff_test.zig");
        _ = @import("conn_diff_test.zig");
        // `Server(Ctx)` has its HTTP/2 fields only then.
        _ = @import("server_test.zig");
    }
}
