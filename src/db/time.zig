//! `anole.db.Time`: a timestamp as every connector hands it over, in JSON
//! as RFC 3339.
const std = @import("std");

/// An instant, in microseconds since 1970-01-01T00:00:00Z: PostgreSQL's
/// resolution (`timestamptz`, `timestamp` read as UTC), MongoDB's dates
/// (milliseconds) and SQLite's text and integer timestamps fit it. In
/// JSON it is an RFC 3339 string in UTC (`"2026-10-21T09:30:00.25Z"`),
/// both ways, so `res.json(row)` and `req.bind(T)` carry it as clients
/// expect.
pub const Time = struct {
    /// Microseconds since 1970-01-01T00:00:00Z.
    us: i64,

    /// The instant `us` microseconds after the epoch.
    pub fn fromMicros(us: i64) Time {
        return .{ .us = us };
    }

    /// The instant `ms` milliseconds after the epoch (MongoDB's date).
    /// Beyond what microseconds hold (about 292,000 years either way), the
    /// end of the range; `fromMillisChecked` says so instead.
    pub fn fromMillis(ms: i64) Time {
        return .{ .us = ms *| std.time.us_per_ms };
    }

    /// The instant `s` seconds after the epoch (a Unix timestamp). Beyond
    /// what microseconds hold, the end of the range; `fromSecondsChecked`
    /// says so instead.
    pub fn fromSeconds(s: i64) Time {
        return .{ .us = s *| std.time.us_per_s };
    }

    /// As `fromMillis`, or `error.OutOfRange` beyond what it holds.
    pub fn fromMillisChecked(ms: i64) error{OutOfRange}!Time {
        return .{ .us = std.math.mul(i64, ms, std.time.us_per_ms) catch return error.OutOfRange };
    }

    /// As `fromSeconds`, or `error.OutOfRange` beyond what it holds: for
    /// numbers read from storage, which may hold anything.
    pub fn fromSecondsChecked(s: i64) error{OutOfRange}!Time {
        return .{ .us = std.math.mul(i64, s, std.time.us_per_s) catch return error.OutOfRange };
    }

    /// A Julian day number (SQLite's `julianday()`), to the millisecond;
    /// `error.OutOfRange` for one beyond what `Time` holds, or not a number.
    pub fn fromJulianDay(days: f64) error{OutOfRange}!Time {
        const ms = @round((days - 2440587.5) * 86400e3);
        // NaN fails both comparisons; 9.2e15 ms is within i64 microseconds.
        if (!(ms >= -9.2e15 and ms <= 9.2e15)) return error.OutOfRange;
        return fromMillisChecked(@intFromFloat(ms));
    }

    /// Whole milliseconds, rounded down (MongoDB's date).
    pub fn toMillis(self: Time) i64 {
        return @divFloor(self.us, std.time.us_per_ms);
    }

    /// Whole seconds, rounded down.
    pub fn toSeconds(self: Time) i64 {
        return @divFloor(self.us, std.time.us_per_s);
    }

    /// The wall clock's time now (`std.Io.Clock.real`).
    pub fn now(io: std.Io) Time {
        return .{ .us = std.Io.Clock.real.now(io).toMicroseconds() };
    }

    /// Whether `a` is before, at or after `b`.
    pub fn order(a: Time, b: Time) std.math.Order {
        return std.math.order(a.us, b.us);
    }

    /// RFC 3339 and the forms databases print: `2026-10-21T09:30:00Z`,
    /// `2026-10-21 09:30:00.123456+02:00` (a space for the `T`, as
    /// PostgreSQL and SQLite write it), offsets as `+02`, `+0200` or
    /// `+02:00`, no offset (taken as UTC, SQLite's convention), or a date
    /// alone (midnight UTC). Fractions beyond microseconds are cut.
    pub fn parse(text: []const u8) error{InvalidTime}!Time {
        var p: Parser = .{ .s = text };
        const year = try p.int(4);
        try p.expect('-');
        const month = try p.int(2);
        try p.expect('-');
        const day = try p.int(2);
        if (month < 1 or month > 12 or day < 1 or day > daysInMonth(year, @intCast(month))) return error.InvalidTime;
        var secs: i64 = daysFromCivil(year, @intCast(month), @intCast(day)) * std.time.s_per_day;
        var frac: i64 = 0;
        if (p.i < p.s.len) {
            switch (p.s[p.i]) {
                'T', 't', ' ' => p.i += 1,
                else => return error.InvalidTime,
            }
            const hour = try p.int(2);
            try p.expect(':');
            const minute = try p.int(2);
            try p.expect(':');
            const second = try p.int(2);
            // 60: a leap second, as the next one.
            if (hour > 23 or minute > 59 or second > 60) return error.InvalidTime;
            secs += hour * 3600 + minute * 60 + second;
            if (p.peek() == '.') {
                p.i += 1;
                var digits: usize = 0;
                while (p.peek()) |ch| {
                    if (!std.ascii.isDigit(ch)) break;
                    if (digits < 6) frac = frac * 10 + (ch - '0');
                    digits += 1;
                    p.i += 1;
                }
                if (digits == 0) return error.InvalidTime;
                for (@min(digits, 6)..6) |_| frac *= 10;
            }
            if (p.peek()) |ch| switch (ch) {
                'Z', 'z' => p.i += 1,
                '+', '-' => {
                    p.i += 1;
                    const oh = try p.int(2);
                    var om: i64 = 0;
                    if (p.peek() == ':') p.i += 1;
                    if (p.i < p.s.len) om = try p.int(2);
                    if (oh > 23 or om > 59) return error.InvalidTime;
                    const offset = oh * 3600 + om * 60;
                    secs += if (ch == '+') -offset else offset;
                },
                else => return error.InvalidTime,
            };
        }
        if (p.i != p.s.len) return error.InvalidTime;
        const us = std.math.mul(i64, secs, std.time.us_per_s) catch return error.InvalidTime;
        return .{ .us = std.math.add(i64, us, frac) catch return error.InvalidTime };
    }

    /// RFC 3339 in UTC: `2026-10-21T09:30:00Z`, with the fraction when
    /// there is one, its trailing zeros left out (`.25`, `.000123`).
    pub fn format(self: Time, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const secs = @divFloor(self.us, std.time.us_per_s);
        const frac: u64 = @intCast(@mod(self.us, std.time.us_per_s));
        const days = @divFloor(secs, std.time.s_per_day);
        const in_day: u64 = @intCast(@mod(secs, std.time.s_per_day));
        const date = civilFromDays(days);
        if (date.year >= 0 and date.year <= 9999)
            try w.print("{d:0>4}", .{@as(u64, @intCast(date.year))})
        else
            try w.print("{d}", .{date.year});
        try w.print("-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{ date.month, date.day, in_day / 3600, in_day / 60 % 60, in_day % 60 });
        if (frac != 0) {
            var digits: [6]u8 = undefined;
            _ = std.fmt.bufPrint(&digits, "{d:0>6}", .{frac}) catch unreachable;
            try w.print(".{s}", .{std.mem.trimEnd(u8, &digits, "0")});
        }
        try w.writeByte('Z');
    }

    /// For `std.json`: an RFC 3339 string, as `format` writes it.
    pub fn jsonStringify(self: Time, jw: anytype) !void {
        try jw.print("\"{f}\"", .{self});
    }

    /// For `std.json`: a string `parse` takes; anything else is
    /// `error.UnexpectedToken`.
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Time {
        const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        const text = switch (token) {
            inline .string, .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };
        defer if (token == .allocated_string) allocator.free(text);
        return parse(text) catch error.UnexpectedToken;
    }

    /// For `std.json`, from a parsed `std.json.Value`, as `jsonParse`.
    pub fn jsonParseFromValue(_: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) !Time {
        return switch (source) {
            .string => |s| parse(s) catch error.UnexpectedToken,
            else => error.UnexpectedToken,
        };
    }
};

const Parser = struct {
    s: []const u8,
    i: usize = 0,

    fn peek(p: *const Parser) ?u8 {
        return if (p.i < p.s.len) p.s[p.i] else null;
    }

    fn expect(p: *Parser, ch: u8) error{InvalidTime}!void {
        if (p.peek() != ch) return error.InvalidTime;
        p.i += 1;
    }

    /// Exactly `n` digits.
    fn int(p: *Parser, n: usize) error{InvalidTime}!i64 {
        if (p.i + n > p.s.len) return error.InvalidTime;
        var v: i64 = 0;
        for (p.s[p.i..][0..n]) |ch| {
            if (!std.ascii.isDigit(ch)) return error.InvalidTime;
            v = v * 10 + (ch - '0');
        }
        p.i += n;
        return v;
    }
};

fn isLeap(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

fn daysInMonth(year: i64, month: u8) i64 {
    return switch (month) {
        2 => if (isLeap(year)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

/// Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's
/// `days_from_civil`).
fn daysFromCivil(year: i64, month: u8, day: u8) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = month;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

const Date = struct { year: i64, month: u8, day: u8 };

/// The inverse (`civil_from_days`).
fn civilFromDays(days: i64) Date {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const month: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ .year = yoe + era * 400 + @intFromBool(month <= 2), .month = month, .day = day };
}

const testing = std.testing;

fn expectFormat(expected: []const u8, t: Time) !void {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(expected, try std.fmt.bufPrint(&buf, "{f}", .{t}));
}

test "Time: format, and parse back" {
    try expectFormat("1970-01-01T00:00:00Z", .fromMicros(0));
    try expectFormat("2026-10-21T09:30:00.25Z", .fromMicros(1792575000_250000));
    try expectFormat("2000-02-29T23:59:59.000001Z", try Time.parse("2000-02-29T23:59:59.000001Z"));
    try expectFormat("1969-12-31T23:59:59.999Z", .fromMillis(-1));
    try expectFormat("1900-03-01T00:00:00Z", try Time.parse("1900-03-01"));
    for ([_]i64{ 0, 1, -1, 1792575000_250000, -2208988800_000000, 253402300799_999999, 951782400_000000 }) |us| {
        var buf: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{f}", .{Time.fromMicros(us)});
        try testing.expectEqual(us, (try Time.parse(text)).us);
    }
}

test "Time: numbers beyond the range" {
    const max = std.math.maxInt(i64);
    const min = std.math.minInt(i64);
    try testing.expectError(error.OutOfRange, Time.fromSecondsChecked(max));
    try testing.expectError(error.OutOfRange, Time.fromSecondsChecked(min));
    try testing.expectError(error.OutOfRange, Time.fromMillisChecked(max / 10));
    try testing.expectEqual(@as(i64, 5_000_000), (try Time.fromSecondsChecked(5)).us);
    try testing.expectEqual(max, Time.fromSeconds(max).us);
    try testing.expectEqual(min, Time.fromMillis(min).us);
    for ([_]f64{ 1e300, -1e300, std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64), 1e13 }) |jd| {
        try testing.expectError(error.OutOfRange, Time.fromJulianDay(jd));
    }
    try testing.expectEqual(@as(i64, 0), (try Time.fromJulianDay(2440587.5)).us);
    try testing.expectEqual(@as(i64, 86_400_000_000), (try Time.fromJulianDay(2440588.5)).us);
}

test "Time: the forms databases print" {
    const base = try Time.parse("2026-10-21T09:30:00Z");
    try testing.expectEqual(base, try Time.parse("2026-10-21 09:30:00"));
    try testing.expectEqual(base, try Time.parse("2026-10-21t09:30:00z"));
    try testing.expectEqual(base, try Time.parse("2026-10-21 11:30:00+02"));
    try testing.expectEqual(base, try Time.parse("2026-10-21 11:30:00+0200"));
    try testing.expectEqual(base, try Time.parse("2026-10-21T04:00:00-05:30"));
    try testing.expectEqual(base.us + 123456, (try Time.parse("2026-10-21 09:30:00.123456789+00:00")).us);
    try testing.expectEqual(base.us + 100000, (try Time.parse("2026-10-21T09:30:00.1Z")).us);
    for ([_][]const u8{ "", "2026-1-21", "2026-13-01", "2026-02-29", "2026-10-21T25:00:00Z", "2026-10-21T09:30", "2026-10-21T09:30:00.Z", "2026-10-21T09:30:00Zx", "2026-10-21T09:30:00+2" }) |bad| {
        try testing.expectError(error.InvalidTime, Time.parse(bad));
    }
}

test "Time: JSON both ways" {
    const Row = struct { id: i64, created_at: Time, deleted_at: ?Time = null };
    const json = try std.json.Stringify.valueAlloc(testing.allocator, Row{ .id = 1, .created_at = .fromMillis(1792575000250) }, .{});
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{\"id\":1,\"created_at\":\"2026-10-21T09:30:00.25Z\",\"deleted_at\":null}", json);
    const parsed = try std.json.parseFromSlice(Row, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 1792575000250), parsed.value.created_at.toMillis());
    try testing.expectError(error.UnexpectedToken, std.json.parseFromSlice(Row, testing.allocator, "{\"id\":1,\"created_at\":\"yesterday\"}", .{}));
    const value = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer value.deinit();
    try testing.expectEqual(parsed.value.created_at, try std.json.parseFromValueLeaky(Time, testing.allocator, value.value.object.get("created_at").?, .{}));
}
