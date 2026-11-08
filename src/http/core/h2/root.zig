//! The HTTP/2 codecs and protocol core (research/h2h3-takeover/PLAN.md §3.1),
//! translated from nghttp2 where noted (see LICENSE.nghttp2 and
//! THIRD_PARTY_NOTICES): HPACK, frames, request field checks and the flood
//! limits. Nothing uses them yet: the engine is still nghttp2
//! (src/http/core/server/h2_nghttp2.zig).

const std = @import("std");

pub const huffman = @import("huffman.zig");
pub const hpack = @import("hpack.zig");
pub const frame = @import("frame.zig");
pub const fields = @import("fields.zig");
pub const limits = @import("limits.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("hpack_test.zig");
    _ = @import("frame_test.zig");
    _ = @import("fields_test.zig");
    _ = @import("limits_test.zig");
    // Against nghttp2's own inflater; compiled out with -Dhttp2=false.
    if (@import("build_options").use_http2) _ = @import("hpack_diff_test.zig");
}
