//! Helpers shared by the tests in this directory.
const std = @import("std");

/// `s` repeated `n` times, at compile time (Zig 0.17 has no `**`).
pub fn repeat(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    const Storage = struct {
        const data: [s.len * n]u8 = blk: {
            @setEvalBranchQuota(10_000_000);
            var out: [s.len * n]u8 = undefined;
            for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
            break :blk out;
        };
    };
    return &Storage.data;
}
