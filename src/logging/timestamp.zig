// Copied from vkiryakov/zefir src/log/timestamp.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! Record timestamps: RFC 3339 in UTC with milliseconds.

const std = @import("std");

/// Length of a timestamp: `2026-10-10T21:08:00.123Z`.
pub const len = 24;

/// 9999-12-31T23:59:59.999Z, the last instant with a four-digit year.
const last_nanosecond: i96 = 253_402_300_799_999 * std.time.ns_per_ms + (std.time.ns_per_ms - 1);

/// Formats `ts` into `out`. Instants before 1970 (a failed clock reads as
/// zero) and after 9999 are clamped, so every record has a valid time.
pub fn format(ts: std.Io.Timestamp, out: *[len]u8) void {
    const ns = std.math.clamp(ts.nanoseconds, 0, last_nanosecond);
    const ms: u64 = @intCast(@divTrunc(ns, std.time.ns_per_ms));
    const seconds: std.time.epoch.EpochSeconds = .{ .secs = ms / 1000 };
    const year_day = seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = seconds.getDaySeconds();
    putDigits(out[0..4], year_day.year);
    out[4] = '-';
    putDigits(out[5..7], month_day.month.numeric());
    out[7] = '-';
    putDigits(out[8..10], @as(u32, month_day.day_index) + 1);
    out[10] = 'T';
    putDigits(out[11..13], day_seconds.getHoursIntoDay());
    out[13] = ':';
    putDigits(out[14..16], day_seconds.getMinutesIntoHour());
    out[16] = ':';
    putDigits(out[17..19], day_seconds.getSecondsIntoMinute());
    out[19] = '.';
    putDigits(out[20..23], ms % 1000);
    out[23] = 'Z';
}

/// Fills `out` with the decimal digits of `value`, zero-padded on the left.
fn putDigits(out: []u8, value: u64) void {
    var rest = value;
    var i = out.len;
    while (i > 0) {
        i -= 1;
        out[i] = '0' + @as(u8, @intCast(rest % 10));
        rest /= 10;
    }
}

fn formatted(ns: i96) [len]u8 {
    var out: [len]u8 = undefined;
    format(.{ .nanoseconds = ns }, &out);
    return out;
}

test "known instants, a leap day included" {
    try std.testing.expectEqualStrings("1970-01-01T00:00:00.000Z", &formatted(0));
    try std.testing.expectEqualStrings("2000-02-29T00:00:00.123Z", &formatted(951_782_400_123 * std.time.ns_per_ms));
    try std.testing.expectEqualStrings("2026-10-10T21:08:00.999Z", &formatted(1_791_666_480_999 * std.time.ns_per_ms));
}

test "fractions below a millisecond are cut, not rounded" {
    try std.testing.expectEqualStrings("1970-01-01T00:00:00.001Z", &formatted(1_999_999));
}

test "instants outside 1970-9999 are clamped" {
    try std.testing.expectEqualStrings("1970-01-01T00:00:00.000Z", &formatted(-1));
    try std.testing.expectEqualStrings("9999-12-31T23:59:59.999Z", &formatted(std.math.maxInt(i96)));
}
