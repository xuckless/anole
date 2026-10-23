//! Column width of a code point: 0, 1 or 2.
const std = @import("std");
const table = @import("width_table.zig");

fn inTable(comptime t: []const table.Range, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = t.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < t[mid].lo) {
            hi = mid;
        } else if (cp > t[mid].hi) {
            lo = mid + 1;
        } else return true;
    }
    return false;
}

/// 0 for combining marks and format characters, 2 for wide and emoji, else 1.
/// Control characters are not drawn as themselves (the screen shows U+FFFD,
/// width 1), so they answer 1 here.
pub fn width(cp: u21) u2 {
    if (cp < 0x300) return 1;
    if (inTable(&table.zero, cp)) return 0;
    if (inTable(&table.wide, cp)) return 2;
    return 1;
}

test "width: ASCII, CJK, combining, emoji" {
    try std.testing.expectEqual(@as(u2, 1), width('a'));
    try std.testing.expectEqual(@as(u2, 2), width(0x4E2D)); // 中
    try std.testing.expectEqual(@as(u2, 0), width(0x0301)); // combining acute
    try std.testing.expectEqual(@as(u2, 2), width(0x1F600)); // 😀
    try std.testing.expectEqual(@as(u2, 0), width(0x200B));
    try std.testing.expectEqual(@as(u2, 1), width(0x7));
    try std.testing.expectEqual(@as(u2, 2), width(0xAC00)); // Hangul
}

test "width tables are sorted and disjoint" {
    inline for (.{ table.wide, table.zero }) |t| {
        var prev: u32 = 0;
        for (t, 0..) |r, i| {
            try std.testing.expect(r.lo <= r.hi);
            if (i > 0) try std.testing.expect(r.lo > prev);
            prev = r.hi;
        }
    }
}
