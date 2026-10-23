//! Time zones for schedules: fixed offsets, UTC and the system's TZif files
//! (with the POSIX rule of the file's footer for instants past the last
//! transition). std.tz parses TZif but does not evaluate the footer, so this
//! reads the files itself (p3/jobs, design-jobs.md C4).
const std = @import("std");
const builtin = @import("builtin");
const Time = @import("../db/time.zig").Time;

/// Days since 1970-01-01 of a civil date (proleptic Gregorian).
pub fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub const Civil = struct { year: i64, month: u8, day: u8 };

pub fn civilFromDays(z_in: i64) Civil {
    const z = z_in + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .year = if (m <= 2) y + 1 else y, .month = @intCast(m), .day = @intCast(d) };
}

pub fn isLeap(y: i64) bool {
    return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
}

pub fn daysInMonth(y: i64, m: u8) u8 {
    return switch (m) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        else => if (isLeap(y)) 29 else 28,
    };
}

/// 0 = Sunday.
pub fn weekday(days: i64) u8 {
    return @intCast(@mod(days + 4, 7));
}

const RuleDate = struct {
    kind: enum { m, j, n },
    month: u8 = 0,
    week: u8 = 0,
    day: u16 = 0,
    /// Seconds after local midnight (may be negative or over 24 h).
    time: i32 = 7200,

    /// Seconds since the epoch of this date in `year` as a local wall time.
    fn wall(self: RuleDate, year: i64) i64 {
        const days: i64 = switch (self.kind) {
            .j => blk: { // 1..365, Feb 29 never counted
                var d: i64 = self.day;
                if (isLeap(year) and d >= 60) d += 1;
                break :blk daysFromCivil(year, 1, 1) + d - 1;
            },
            .n => daysFromCivil(year, 1, 1) + self.day,
            .m => blk: {
                const first = daysFromCivil(year, self.month, 1);
                const wd = weekday(first);
                var d: i64 = first + @mod(@as(i64, self.day) - wd, 7);
                d += (@as(i64, self.week) - 1) * 7;
                const last = first + daysInMonth(year, self.month) - 1;
                while (d > last) d -= 7;
                break :blk d;
            },
        };
        return days * 86400 + self.time;
    }
};

const Rule = struct {
    std_off: i32,
    dst_off: i32 = 0,
    has_dst: bool = false,
    start: RuleDate = undefined,
    end: RuleDate = undefined,

    fn offsetAt(self: Rule, t: i64) i32 {
        if (!self.has_dst) return self.std_off;
        const year = civilFromDays(@divFloor(t + self.std_off, 86400)).year;
        const s = self.start.wall(year) - self.std_off;
        const e = self.end.wall(year) - self.dst_off;
        const dst = if (s < e) (t >= s and t < e) else (t >= s or t < e);
        return if (dst) self.dst_off else self.std_off;
    }
};

fn parseName(s: []const u8, i: *usize) bool {
    if (i.* < s.len and s[i.*] == '<') {
        while (i.* < s.len and s[i.*] != '>') i.* += 1;
        if (i.* >= s.len) return false;
        i.* += 1;
        return true;
    }
    const start = i.*;
    while (i.* < s.len and std.ascii.isAlphabetic(s[i.*])) i.* += 1;
    return i.* - start >= 3;
}

/// [+-]hh[:mm[:ss]] in seconds.
fn parseHms(s: []const u8, i: *usize) ?i32 {
    var sign: i32 = 1;
    if (i.* < s.len and (s[i.*] == '+' or s[i.*] == '-')) {
        if (s[i.*] == '-') sign = -1;
        i.* += 1;
    }
    var parts: [3]i32 = .{ 0, 0, 0 };
    var n: usize = 0;
    while (n < 3) : (n += 1) {
        const st = i.*;
        var v: i32 = 0;
        while (i.* < s.len and std.ascii.isDigit(s[i.*])) : (i.* += 1) v = v * 10 + (s[i.*] - '0');
        if (i.* == st) return if (n == 0) null else sign * (parts[0] * 3600 + parts[1] * 60 + parts[2]);
        parts[n] = v;
        if (i.* < s.len and s[i.*] == ':' and n < 2) i.* += 1 else {
            n += 1;
            break;
        }
    }
    return sign * (parts[0] * 3600 + parts[1] * 60 + parts[2]);
}

fn parseRuleDate(s: []const u8, i: *usize) ?RuleDate {
    var rd: RuleDate = undefined;
    if (i.* >= s.len) return null;
    const num = struct {
        fn f(str: []const u8, k: *usize) ?u16 {
            const st = k.*;
            var v: u16 = 0;
            while (k.* < str.len and std.ascii.isDigit(str[k.*])) : (k.* += 1) v = v *% 10 +% (str[k.*] - '0');
            return if (k.* == st) null else v;
        }
    }.f;
    if (s[i.*] == 'M') {
        i.* += 1;
        rd = .{ .kind = .m };
        rd.month = @intCast(num(s, i) orelse return null);
        if (i.* >= s.len or s[i.*] != '.') return null;
        i.* += 1;
        rd.week = @intCast(num(s, i) orelse return null);
        if (i.* >= s.len or s[i.*] != '.') return null;
        i.* += 1;
        rd.day = num(s, i) orelse return null;
        if (rd.month < 1 or rd.month > 12 or rd.week < 1 or rd.week > 5 or rd.day > 6) return null;
    } else if (s[i.*] == 'J') {
        i.* += 1;
        rd = .{ .kind = .j };
        rd.day = num(s, i) orelse return null;
    } else {
        rd = .{ .kind = .n };
        rd.day = num(s, i) orelse return null;
    }
    rd.time = 7200;
    if (i.* < s.len and s[i.*] == '/') {
        i.* += 1;
        rd.time = parseHms(s, i) orelse return null;
    }
    return rd;
}

/// A POSIX TZ string such as `CET-1CEST,M3.5.0,M10.5.0/3`.
fn parseRule(s: []const u8) ?Rule {
    var i: usize = 0;
    if (!parseName(s, &i)) return null;
    const so = parseHms(s, &i) orelse return null;
    var r: Rule = .{ .std_off = -so };
    if (i >= s.len) return r;
    if (!parseName(s, &i)) return null;
    r.has_dst = true;
    r.dst_off = r.std_off + 3600;
    if (i < s.len and s[i] != ',') r.dst_off = -(parseHms(s, &i) orelse return null);
    if (i >= s.len or s[i] != ',') return null;
    i += 1;
    r.start = parseRuleDate(s, &i) orelse return null;
    if (i >= s.len or s[i] != ',') return null;
    i += 1;
    r.end = parseRuleDate(s, &i) orelse return null;
    return r;
}

pub const Zone = struct {
    fixed_offset: i32 = 0,
    transitions: []const i64 = &.{},
    type_of: []const u8 = &.{},
    offsets: []const i32 = &.{},
    footer: ?Rule = null,
    gpa: ?std.mem.Allocator = null,

    pub const utc: Zone = .{};

    /// "+05:30", "-08:00", "UTC", "Z".
    pub fn fixed(offset_seconds: i32) Zone {
        return .{ .fixed_offset = offset_seconds };
    }

    pub fn deinit(self: *Zone) void {
        if (self.gpa) |g| {
            g.free(self.transitions);
            g.free(self.type_of);
            g.free(self.offsets);
        }
        self.* = .{};
    }

    /// The offset from UTC in seconds at instant `t`.
    pub fn offsetAt(self: *const Zone, t: Time) i32 {
        return self.offsetAtSeconds(@divFloor(t.us, std.time.us_per_s));
    }

    pub fn offsetAtSeconds(self: *const Zone, t: i64) i32 {
        if (self.transitions.len == 0) {
            if (self.footer) |f| return f.offsetAt(t);
            return if (self.offsets.len > 0) self.offsets[0] else self.fixed_offset;
        }
        const n = self.transitions.len;
        if (t >= self.transitions[n - 1]) {
            if (self.footer) |f| return f.offsetAt(t);
            return self.offsets[self.type_of[n - 1]];
        }
        if (t < self.transitions[0]) return self.offsets[0];
        // last transition <= t
        var lo: usize = 0;
        var hi: usize = n;
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (self.transitions[mid] <= t) lo = mid else hi = mid;
        }
        return self.offsets[self.type_of[lo]];
    }

    /// An IANA name, "UTC", or an offset; reads the system's TZif file.
    pub fn load(gpa: std.mem.Allocator, io: std.Io, name: []const u8) !Zone {
        if (std.mem.eql(u8, name, "UTC") or std.mem.eql(u8, name, "Z") or std.mem.eql(u8, name, "GMT")) return utc;
        if (name.len >= 2 and (name[0] == '+' or name[0] == '-')) {
            var i: usize = 0;
            const off = parseHms(name, &i) orelse return error.UnknownTimeZone;
            if (i != name.len) return error.UnknownTimeZone;
            return fixed(off);
        }
        if (name.len == 0 or name.len > 64 or name[0] == '/') return error.UnknownTimeZone;
        if (std.mem.indexOf(u8, name, "..") != null) return error.UnknownTimeZone;
        for (name) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '+' or c == '-' or c == '/')) return error.UnknownTimeZone;
        }
        const dirs: []const []const u8 = if (builtin.os.tag == .windows) &.{} else &.{ "/usr/share/zoneinfo", "/usr/lib/zoneinfo", "/usr/share/lib/zoneinfo", "/etc/zoneinfo" };
        var path_buf: [256]u8 = undefined;
        if (std.c.getenv("ZONEINFO")) |z| {
            const dir = std.mem.span(z);
            if (std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name })) |p| {
                if (tryFile(gpa, io, p)) |zone| return zone else |_| {}
            } else |_| {}
        }
        for (dirs) |dir| {
            const p = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch continue;
            if (tryFile(gpa, io, p)) |zone| return zone else |_| {}
        }
        std.log.scoped(.anole).err("cron: unknown time zone \"{s}\": install tzdata, or set ZONEINFO to its directory", .{name});
        return error.UnknownTimeZone;
    }

    fn tryFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Zone {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
        defer gpa.free(data);
        return parse(gpa, data);
    }

    /// Parses TZif bytes (version 2+ preferred, else version 1).
    pub fn parse(gpa: std.mem.Allocator, data: []const u8) !Zone {
        if (data.len < 44 or !std.mem.eql(u8, data[0..4], "TZif")) return error.UnknownTimeZone;
        const version = data[4];
        var pos: usize = 0;
        var wide = false;
        var counts = readCounts(data, 0);
        if (version >= '2') {
            const skip = 44 + counts.timecnt * 4 + counts.timecnt + counts.typecnt * 6 + counts.charcnt + counts.leapcnt * 8 + counts.isstdcnt + counts.isutcnt;
            if (data.len < skip + 44) return error.UnknownTimeZone;
            pos = skip;
            counts = readCounts(data, pos);
            wide = true;
        }
        var p = pos + 44;
        const tsz: usize = if (wide) 8 else 4;
        const need = counts.timecnt * tsz + counts.timecnt + counts.typecnt * 6;
        if (data.len < p + need or counts.typecnt == 0) return error.UnknownTimeZone;
        const trans = try gpa.alloc(i64, counts.timecnt);
        errdefer gpa.free(trans);
        for (trans, 0..) |*t, k| {
            t.* = if (wide) std.mem.readInt(i64, data[p + k * 8 ..][0..8], .big) else std.mem.readInt(i32, data[p + k * 4 ..][0..4], .big);
        }
        p += counts.timecnt * tsz;
        const idx = try gpa.dupe(u8, data[p .. p + counts.timecnt]);
        errdefer gpa.free(idx);
        p += counts.timecnt;
        const offs = try gpa.alloc(i32, counts.typecnt);
        errdefer gpa.free(offs);
        for (offs, 0..) |*o, k| o.* = std.mem.readInt(i32, data[p + k * 6 ..][0..4], .big);
        for (idx) |i| if (i >= counts.typecnt) return error.UnknownTimeZone;
        p += counts.typecnt * 6 + counts.charcnt + counts.leapcnt * (tsz + 4) + counts.isstdcnt + counts.isutcnt;
        var footer: ?Rule = null;
        if (wide and p < data.len and data[p] == '\n') {
            const rest = data[p + 1 ..];
            if (std.mem.indexOfScalar(u8, rest, '\n')) |e| {
                if (e > 0) footer = parseRule(rest[0..e]);
            }
        }
        return .{ .transitions = trans, .type_of = idx, .offsets = offs, .footer = footer, .gpa = gpa };
    }

    /// Test helper: a zone from a POSIX rule alone.
    pub fn fromPosix(rule: []const u8) !Zone {
        return .{ .footer = parseRule(rule) orelse return error.UnknownTimeZone };
    }
};

const Counts = struct { isutcnt: usize, isstdcnt: usize, leapcnt: usize, timecnt: usize, typecnt: usize, charcnt: usize };
fn readCounts(data: []const u8, at: usize) Counts {
    const r = struct {
        fn f(d: []const u8, o: usize) usize {
            return std.mem.readInt(u32, d[o..][0..4], .big);
        }
    }.f;
    return .{ .isutcnt = r(data, at + 20), .isstdcnt = r(data, at + 24), .leapcnt = r(data, at + 28), .timecnt = r(data, at + 32), .typecnt = r(data, at + 36), .charcnt = r(data, at + 40) };
}

test "civil dates round trip" {
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try std.testing.expectEqual(@as(i64, 20541), daysFromCivil(2026, 3, 29));
    const c = civilFromDays(20541);
    try std.testing.expectEqual(@as(u8, 3), c.month);
    try std.testing.expectEqual(@as(u8, 29), c.day);
    try std.testing.expectEqual(@as(u8, 0), weekday(20541)); // a Sunday
}

test "zone: posix footer CET transitions" {
    const z = try Zone.fromPosix("CET-1CEST,M3.5.0,M10.5.0/3");
    // 2026-03-29 01:00 UTC is the switch to summer time.
    const sw = (daysFromCivil(2026, 3, 29)) * 86400 + 3600;
    try std.testing.expectEqual(@as(i32, 3600), z.offsetAtSeconds(sw - 1));
    try std.testing.expectEqual(@as(i32, 7200), z.offsetAtSeconds(sw));
    // 2026-10-25 01:00 UTC back to winter time.
    const sb = (daysFromCivil(2026, 10, 25)) * 86400 + 3600;
    try std.testing.expectEqual(@as(i32, 7200), z.offsetAtSeconds(sb - 1));
    try std.testing.expectEqual(@as(i32, 3600), z.offsetAtSeconds(sb));
}

test "zone: names that could escape are refused" {
    const io = std.testing.io;
    try std.testing.expectError(error.UnknownTimeZone, Zone.load(std.testing.allocator, io, ".."));
    try std.testing.expectError(error.UnknownTimeZone, Zone.load(std.testing.allocator, io, "/etc/passwd"));
    try std.testing.expectError(error.UnknownTimeZone, Zone.load(std.testing.allocator, io, "Europe/../x"));
    var z = try Zone.load(std.testing.allocator, io, "+05:30");
    defer z.deinit();
    try std.testing.expectEqual(@as(i32, 19800), z.offsetAtSeconds(0));
}
