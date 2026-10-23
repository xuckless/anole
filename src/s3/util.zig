//! Small helpers the S3 client shares: HTTP dates, Content-MD5.
const std = @import("std");

const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const day_names = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };

/// IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`) to seconds since the epoch.
pub fn parseHttpDate(value: []const u8) ?i64 {
    const v = std.mem.trim(u8, value, " \t");
    if (v.len != 29) return null;
    if (v[3] != ',' or v[4] != ' ' or v[7] != ' ' or v[11] != ' ' or v[16] != ' ' or v[19] != ':' or v[22] != ':') return null;
    if (!std.mem.eql(u8, v[25..], " GMT")) return null;
    const day = std.fmt.parseInt(u8, v[5..7], 10) catch return null;
    const month: u8 = for (month_names, 1..) |name, i| {
        if (std.mem.eql(u8, v[8..11], name)) break @intCast(i);
    } else return null;
    const year = std.fmt.parseInt(u16, v[12..16], 10) catch return null;
    const hour = std.fmt.parseInt(u8, v[17..19], 10) catch return null;
    const minute = std.fmt.parseInt(u8, v[20..22], 10) catch return null;
    const second = std.fmt.parseInt(u8, v[23..25], 10) catch return null;
    if (day == 0 or day > std.time.epoch.getDaysInMonth(year, @enumFromInt(month))) return null;
    if (hour > 23 or minute > 59 or second > 60) return null;
    return daysFromCivil(year, month, day) * std.time.s_per_day + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second;
}

fn daysFromCivil(year: u16, month: u8, day: u8) i64 {
    const y: i64 = if (month <= 2) @as(i64, year) - 1 else year;
    const era = @divFloor(y, 400);
    const year_of_era = y - era * 400;
    const month_from_march: i64 = (month + 9) % 12;
    const day_of_year = @divFloor(153 * month_from_march + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

/// `seconds` as an IMF-fixdate.
pub fn formatHttpDate(buf: *[29]u8, seconds: i64) []const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(std.math.clamp(seconds, 0, 253402300799)) };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        day_names[day.day % 7],         md.day_index + 1,          month_names[md.month.numeric() - 1], yd.year,
        ds.getHoursIntoDay(),           ds.getMinutesIntoHour(),   ds.getSecondsIntoMinute(),
    }) catch unreachable;
}

/// MD5 of `bytes`, base64: the `Content-MD5` header DeleteObjects needs.
pub fn contentMd5(buf: *[24]u8, bytes: []const u8) []const u8 {
    var d: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(bytes, &d, .{});
    return std.base64.standard.Encoder.encode(buf, &d);
}

/// Current wall-clock seconds.
pub fn nowSeconds(io: std.Io) i64 {
    return @intCast(@divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
}

const testing = std.testing;

test "util: HTTP dates round-trip" {
    try testing.expectEqual(@as(?i64, 784111777), parseHttpDate("Sun, 06 Nov 1994 08:49:37 GMT"));
    var buf: [29]u8 = undefined;
    try testing.expectEqualStrings("Sun, 06 Nov 1994 08:49:37 GMT", formatHttpDate(&buf, 784111777));
    try testing.expectEqual(@as(?i64, null), parseHttpDate("nonsense"));
}

test "util: Content-MD5" {
    var buf: [24]u8 = undefined;
    try testing.expectEqualStrings("1B2M2Y8AsgTpgAmY7PhCfg==", contentMd5(&buf, ""));
}
