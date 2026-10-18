//! Copied from fanyang89/grpc-lite (MIT, Copyright (c) 2026 grpc-lite contributors),
//! src/compression.zig at commit db3c400bf70419742ebcb42fe316ba8b754b4975; see THIRD_PARTY_NOTICES.
const std = @import("std");

pub const Compression = enum {
    identity,
    gzip,

    pub fn name(self: Compression) []const u8 {
        return @tagName(self);
    }

    pub fn parse(value: []const u8) ?Compression {
        if (std.mem.eql(u8, value, "identity")) return .identity;
        if (std.mem.eql(u8, value, "gzip")) return .gzip;
        return null;
    }
};

test "compression names parse" {
    try std.testing.expectEqual(Compression.identity, Compression.parse("identity").?);
    try std.testing.expectEqual(Compression.gzip, Compression.parse("gzip").?);
    try std.testing.expectEqual(@as(?Compression, null), Compression.parse("deflate"));
}
