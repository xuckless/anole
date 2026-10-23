//! Unique-job keys (J10): SHA-256 over kind, queue, the key or the args and
//! the period bucket; the first 16 bytes.
const std = @import("std");
const root = @import("root.zig");

pub fn derive(kind: []const u8, queue: []const u8, args_json: []const u8, u: root.Unique, now: root.Time) [16]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(kind);
    h.update("\x00");
    h.update(queue);
    h.update("\x00");
    h.update(u.key orelse args_json);
    h.update("\x00");
    if (u.period) |p| {
        const pm = root.millis(p);
        if (pm > 0) {
            var buf: [24]u8 = undefined;
            const bucket = @divFloor(@divFloor(now.us, 1000), pm);
            h.update(std.fmt.bufPrint(&buf, "{d}", .{bucket}) catch "");
        }
    }
    var out: [32]u8 = undefined;
    h.final(&out);
    return out[0..16].*;
}

test "unique keys depend on the period bucket" {
    const t0 = root.Time.fromSeconds(0);
    const u: root.Unique = .{ .period = .fromSeconds(60) };
    const a = derive("k", "q", "{}", u, t0);
    const b = derive("k", "q", "{}", u, root.Time.fromSeconds(30));
    const c = derive("k", "q", "{}", u, root.Time.fromSeconds(61));
    try std.testing.expectEqualSlices(u8, &a, &b);
    try std.testing.expect(!std.mem.eql(u8, &a, &c));
}
