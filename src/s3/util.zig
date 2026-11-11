//! Small helpers the S3 client shares: HTTP dates, Content-MD5.
const std = @import("std");
const dusty = @import("dusty");

const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const day_names = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };

/// IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`) to seconds since the epoch.
pub const parseHttpDate = dusty.parseHttpDate;

/// `seconds` as an IMF-fixdate.
pub fn formatHttpDate(buf: *[29]u8, seconds: i64) []const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(std.math.clamp(seconds, 0, 253402300799)) };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        day_names[day.day % 7], md.day_index + 1,        month_names[md.month.numeric() - 1], yd.year,
        ds.getHoursIntoDay(),   ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    }) catch unreachable;
}

/// MD5 of `bytes`, base64: the `Content-MD5` header DeleteObjects needs.
pub fn contentMd5(buf: *[24]u8, bytes: []const u8) []const u8 {
    var d: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(bytes, &d, .{});
    return std.base64.standard.Encoder.encode(buf, &d);
}

/// The method as it is signed and written: upper case.
pub fn methodName(m: anytype) []const u8 {
    return switch (m) {
        .get => "GET",
        .head => "HEAD",
        .put => "PUT",
        .post => "POST",
        .delete => "DELETE",
        .options => "OPTIONS",
        else => "GET",
    };
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

test "util: Content-MD5 is the base64 of the MD5 digest" {
    var buf: [24]u8 = undefined;
    try testing.expectEqualStrings("1B2M2Y8AsgTpgAmY7PhCfg==", contentMd5(&buf, ""));
}
