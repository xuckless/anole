//! Schedules (`-Djobs`): cron expressions and time zones, one runner per
//! process or one per cluster through a lock; works without a jobs store
//! (p3/jobs, design-jobs.md C1-C7).
//!
//!     const s = try anole.cron.Schedule.parse("0 3 * * *", null);
//!     const next = s.next(now, &zone);
const std = @import("std");
const Time = @import("../db/time.zig").Time;
pub const zone = @import("zone.zig");
pub const Zone = zone.Zone;

pub const Diagnostic = struct { field: []const u8 = "", position: usize = 0, message: []const u8 = "" };

const day_names = [_][]const u8{ "SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT" };
const month_names = [_][]const u8{ "JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC" };

pub const Schedule = struct {
    sec: u64 = 1,
    min: u64 = 0,
    hour: u32 = 0,
    dom: u32 = 0,
    last_dom: bool = false,
    month: u16 = 0,
    dow: u8 = 0,
    /// Bit k set: the k-th (1..5) such weekday of the month.
    dow_nth: [7]u8 = @splat(0),
    /// Bit d set: the last such weekday of the month.
    dow_last: u8 = 0,
    every_ms: ?i64 = null,
    dom_star: bool = true,
    dow_star: bool = true,
    /// The hour field is `*` or a step: both occurrences of a repeated hour fire.
    hour_wild: bool = true,
    has_seconds: bool = false,

    /// Parsed per C3. `error.InvalidSchedule` with `why` (field and position).
    pub fn parse(text: []const u8, why: ?*Diagnostic) error{InvalidSchedule}!Schedule {
        var d: Diagnostic = .{};
        const out = parseInner(text, &d) catch {
            if (why) |w| w.* = d;
            return error.InvalidSchedule;
        };
        return out;
    }

    fn parseInner(text_in: []const u8, d: *Diagnostic) error{Bad}!Schedule {
        const text = std.mem.trim(u8, text_in, " \t");
        var s: Schedule = .{};
        if (text.len == 0) return fail(d, "schedule", 0, "empty schedule");
        if (text[0] == '@') {
            if (std.mem.startsWith(u8, text, "@every")) {
                const rest = std.mem.trim(u8, text[6..], " \t");
                const ms = parseDuration(rest) orelse return fail(d, "@every", 7, "expected a duration such as 90s, 5m or 2h");
                if (ms < 1000) return fail(d, "@every", 7, "the interval must be at least 1s");
                s.every_ms = ms;
                return s;
            }
            const map = [_]struct { []const u8, []const u8 }{
                .{ "@yearly", "0 0 1 1 *" }, .{ "@annually", "0 0 1 1 *" }, .{ "@monthly", "0 0 1 * *" },
                .{ "@weekly", "0 0 * * 0" }, .{ "@daily", "0 0 * * *" },    .{ "@midnight", "0 0 * * *" },
                .{ "@hourly", "0 * * * *" },
            };
            for (map) |m| if (std.mem.eql(u8, m[0], text)) return parseInner(m[1], d);
            return fail(d, "schedule", 0, "unknown nickname");
        }
        var fields: [6][]const u8 = undefined;
        var offs: [6]usize = undefined;
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, text, " \t");
        while (it.next()) |f| {
            if (n == 6) return fail(d, "schedule", it.index, "too many fields (5, or 6 with seconds first)");
            fields[n] = f;
            offs[n] = it.index - f.len;
            n += 1;
        }
        if (n != 5 and n != 6) return fail(d, "schedule", 0, "expected 5 fields (minute hour day-of-month month day-of-week), or 6 with seconds first");
        var k: usize = 0;
        if (n == 6) {
            s.has_seconds = true;
            s.sec = try bits(fields[0], 0, 59, null, "second", offs[0], d, &s);
            k = 1;
        }
        s.min = try bits(fields[k], 0, 59, null, "minute", offs[k], d, &s);
        const hf = fields[k + 1];
        s.hour = @intCast(try bits(hf, 0, 23, null, "hour", offs[k + 1], d, &s));
        s.hour_wild = hf[0] == '*' or std.mem.indexOfScalar(u8, hf, '/') != null;
        const dm = fields[k + 2];
        s.dom_star = dm[0] == '*' or dm[0] == '?';
        var dom_s = s;
        s.dom = @intCast(try bits(dm, 1, 31, null, "day-of-month", offs[k + 2], d, &dom_s));
        s.last_dom = dom_s.last_dom;
        const mf = fields[k + 3];
        s.month = @intCast(try bits(mf, 1, 12, &month_names, "month", offs[k + 3], d, &s));
        const wf = fields[k + 4];
        s.dow_star = wf[0] == '*' or wf[0] == '?';
        try parseDow(wf, offs[k + 4], d, &s);
        return s;
    }

    /// The first fire time strictly after `after`, in `z`, or null when none
    /// in the next 5 years.
    pub fn next(self: *const Schedule, after: Time, z: *const Zone) ?Time {
        const after_s = @divFloor(after.us, std.time.us_per_s);
        if (self.every_ms) |ms| {
            const after_ms = @divFloor(after.us, 1000);
            return Time.fromMillis((@divFloor(after_ms, ms) + 1) * ms);
        }
        const unit: i64 = if (self.has_seconds) 1 else 60;
        // Local wall time of `after`, floored to the resolution, plus one unit.
        var l = after_s + z.offsetAtSeconds(after_s);
        l = @divFloor(l, unit) * unit + unit;
        var best = self.search(l, after_s, z);
        // Wall time is not monotone in UTC: when an hour repeats (clocks
        // back), a pattern with a wild hour fires in both passes, so also
        // look from two hours earlier on the wall clock.
        if (self.hour_wild and !self.has_seconds) {
            if (self.search(l - 7200, after_s, z)) |alt| {
                if (best == null or alt < best.?) best = alt;
            }
        }
        return if (best) |b| Time.fromSeconds(b) else null;
    }

    fn search(self: *const Schedule, start: i64, after_s: i64, z: *const Zone) ?i64 {
        const unit: i64 = if (self.has_seconds) 1 else 60;
        var l = start;
        var guard: u32 = 0;
        while (guard < 600) : (guard += 1) {
            const w = self.nextWall(l) orelse return null;
            if (self.resolve(w, after_s, z)) |u| return u;
            l = w + unit;
        }
        return null;
    }

    /// Every fire time in (after, until], at most `out.len`.
    pub fn between(self: *const Schedule, after: Time, until: Time, z: *const Zone, out: []Time) usize {
        var n: usize = 0;
        var cur = after;
        while (n < out.len) {
            const t = self.next(cur, z) orelse break;
            if (t.us > until.us) break;
            out[n] = t;
            n += 1;
            cur = t;
        }
        return n;
    }

    fn dayMatches(self: *const Schedule, days: i64) bool {
        const c = zone.civilFromDays(days);
        if (self.month & (@as(u16, 1) << @intCast(c.month)) == 0) return false;
        const dim = zone.daysInMonth(c.year, c.month);
        var dom_ok = self.dom & (@as(u32, 1) << @intCast(c.day)) != 0;
        if (self.last_dom and c.day == dim) dom_ok = true;
        const wd = zone.weekday(days);
        var dow_ok = self.dow & (@as(u8, 1) << @intCast(wd)) != 0;
        const nth: u3 = @intCast((c.day - 1) / 7 + 1);
        if (self.dow_nth[wd] & (@as(u8, 1) << nth) != 0) dow_ok = true;
        if (self.dow_last & (@as(u8, 1) << @intCast(wd)) != 0 and c.day + 7 > dim) dow_ok = true;
        // Vixie: both restricted means either; otherwise the restricted one decides.
        if (self.dom_star or self.dow_star) return dom_ok and dow_ok;
        return dom_ok or dow_ok;
    }

    /// The first matching wall time >= `l` (seconds of local time since the epoch).
    fn nextWall(self: *const Schedule, l: i64) ?i64 {
        var day = @divFloor(l, 86400);
        const first_day = day;
        var tod = @mod(l, 86400);
        const limit = first_day + 366 * 5 + 2;
        while (day <= limit) : (day += 1) {
            if (self.dayMatches(day)) {
                if (self.timeOfDay(if (day == first_day) tod else 0)) |t| return day * 86400 + t;
            }
            tod = 0;
        }
        return null;
    }

    fn timeOfDay(self: *const Schedule, from: i64) ?i64 {
        var h: i64 = @divFloor(from, 3600);
        var m: i64 = @divFloor(@mod(from, 3600), 60);
        var s: i64 = @mod(from, 60);
        while (h < 24) : (h += 1) {
            if (self.hour & (@as(u32, 1) << @intCast(h)) != 0) {
                while (m < 60) : (m += 1) {
                    if (self.min & (@as(u64, 1) << @intCast(m)) != 0) {
                        while (s < 60) : (s += 1) {
                            if (self.sec & (@as(u64, 1) << @intCast(s)) != 0) return h * 3600 + m * 60 + s;
                        }
                    }
                    s = 0;
                }
            }
            m = 0;
            s = 0;
        }
        return null;
    }

    /// The UTC instant of wall time `w`, or null to carry on with a later one (C5).
    fn resolve(self: *const Schedule, w: i64, after: i64, z: *const Zone) ?i64 {
        const o1 = z.offsetAtSeconds(w - 86400);
        const o2 = z.offsetAtSeconds(w + 86400);
        var cand: [2]i64 = undefined;
        var nc: usize = 0;
        const offs = [2]i32{ o1, o2 };
        for (offs, 0..) |o, i| {
            if (i == 1 and o == o1) break;
            const u = w - o;
            if (z.offsetAtSeconds(u) == o) {
                cand[nc] = u;
                nc += 1;
            }
        }
        if (nc == 1) return if (cand[0] > after) cand[0] else null;
        if (nc == 2) {
            const lo = @min(cand[0], cand[1]);
            const hi = @max(cand[0], cand[1]);
            if (self.hour_wild) {
                if (lo > after) return lo;
                if (hi > after) return hi;
                return null;
            }
            return if (lo > after) lo else null;
        }
        // A gap: fire once at the transition instant.
        var a = w - @max(o1, o2);
        var b = w - @min(o1, o2);
        if (a > b) std.mem.swap(i64, &a, &b);
        while (b - a > 1) {
            const mid = a + @divFloor(b - a, 2);
            if (z.offsetAtSeconds(mid) == o1) a = mid else b = mid;
        }
        const t = b;
        return if (t > after) t else null;
    }
};

fn fail(d: *Diagnostic, field: []const u8, pos: usize, msg: []const u8) error{Bad} {
    d.* = .{ .field = field, .position = pos, .message = msg };
    return error.Bad;
}

fn parseDuration(s: []const u8) ?i64 {
    var total: i64 = 0;
    var i: usize = 0;
    var any = false;
    while (i < s.len) {
        const st = i;
        var v: i64 = 0;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) v = v *| 10 +| (s[i] - '0');
        if (i == st or i >= s.len) return null;
        const mult: i64 = switch (s[i]) {
            's' => 1000,
            'm' => 60_000,
            'h' => 3_600_000,
            'd' => 86_400_000,
            else => return null,
        };
        i += 1;
        total +|= v *| mult;
        any = true;
    }
    return if (any) total else null;
}

fn nameValue(tok: []const u8, names: ?[]const []const u8, first: u32) ?u32 {
    if (names) |ns| {
        if (tok.len == 3) {
            for (ns, 0..) |n, i| if (std.ascii.eqlIgnoreCase(n, tok)) return @as(u32, @intCast(i)) + first;
        }
    }
    return std.fmt.parseInt(u32, tok, 10) catch null;
}

/// One cron field into a bit set. `L` in the day-of-month field is noted on `flags`.
fn bits(text: []const u8, lo: u32, hi: u32, names: ?[]const []const u8, field: []const u8, base: usize, d: *Diagnostic, flags: *Schedule) error{Bad}!u64 {
    const first: u32 = if (names != null and std.mem.eql(u8, field, "month")) 1 else lo;
    var out: u64 = 0;
    var items = std.mem.splitScalar(u8, text, ',');
    while (items.next()) |item| {
        if (item.len == 0) return fail(d, field, base, "empty item");
        if (std.mem.eql(u8, field, "day-of-month") and std.ascii.eqlIgnoreCase(item, "L")) {
            flags.last_dom = true;
            continue;
        }
        if (std.mem.indexOfScalar(u8, item, 'W') != null) return fail(d, field, base, "W (nearest weekday) is not supported");
        var range = item;
        var step: u32 = 1;
        if (std.mem.indexOfScalar(u8, item, '/')) |sl| {
            range = item[0..sl];
            step = std.fmt.parseInt(u32, item[sl + 1 ..], 10) catch return fail(d, field, base + sl + 1, "bad step");
            if (step == 0) return fail(d, field, base + sl + 1, "step must be at least 1");
        }
        var a: u32 = lo;
        var b: u32 = hi;
        if (std.mem.eql(u8, range, "*") or std.mem.eql(u8, range, "?")) {} else if (std.mem.indexOfScalar(u8, range, '-')) |dash| {
            a = nameValue(range[0..dash], names, first) orelse return fail(d, field, base, "bad value");
            b = nameValue(range[dash + 1 ..], names, first) orelse return fail(d, field, base, "bad value");
        } else {
            a = nameValue(range, names, first) orelse return fail(d, field, base, "bad value");
            b = if (step != 1 or std.mem.indexOfScalar(u8, item, '/') != null) hi else a;
        }
        if (a < lo or b > hi or a > b) return fail(d, field, base, "value out of range");
        var v = a;
        while (v <= b) : (v += step) out |= @as(u64, 1) << @intCast(v);
    }
    return out;
}

fn parseDow(text: []const u8, base: usize, d: *Diagnostic, s: *Schedule) error{Bad}!void {
    var items = std.mem.splitScalar(u8, text, ',');
    while (items.next()) |item| {
        if (item.len == 0) return fail(d, "day-of-week", base, "empty item");
        if (std.mem.indexOfScalar(u8, item, '#')) |h| {
            const wd = dowValue(item[0..h]) orelse return fail(d, "day-of-week", base, "bad weekday");
            const k = std.fmt.parseInt(u8, item[h + 1 ..], 10) catch return fail(d, "day-of-week", base + h + 1, "bad ordinal");
            if (k < 1 or k > 5) return fail(d, "day-of-week", base + h + 1, "the ordinal must be 1 to 5");
            s.dow_nth[wd] |= @as(u8, 1) << @intCast(k);
            continue;
        }
        if (item.len >= 2 and (item[item.len - 1] == 'L' or item[item.len - 1] == 'l') and item[0] != '*') {
            const wd = dowValue(item[0 .. item.len - 1]) orelse return fail(d, "day-of-week", base, "bad weekday");
            s.dow_last |= @as(u8, 1) << @intCast(wd);
            continue;
        }
        var tmp: Schedule = .{};
        // Names and 7 = Sunday: map to 0..6 before the generic parser.
        var buf: [32]u8 = undefined;
        var w: usize = 0;
        var i: usize = 0;
        while (i < item.len and w < buf.len - 2) {
            if (i + 3 <= item.len and std.ascii.isAlphabetic(item[i])) {
                const v = dowValue(item[i .. i + 3]) orelse return fail(d, "day-of-week", base, "bad weekday name");
                buf[w] = '0' + v;
                w += 1;
                i += 3;
            } else {
                buf[w] = if (item[i] == '7' and (i == 0 or !std.ascii.isDigit(item[i - 1])) and (i + 1 == item.len or !std.ascii.isDigit(item[i + 1]))) '0' else item[i];
                w += 1;
                i += 1;
            }
        }
        const m = try bits(buf[0..w], 0, 6, null, "day-of-week", base, d, &tmp);
        s.dow |= @intCast(m);
    }
}

fn dowValue(tok: []const u8) ?u8 {
    if (tok.len == 3) for (day_names, 0..) |n, i| if (std.ascii.eqlIgnoreCase(n, tok)) return @intCast(i);
    const v = std.fmt.parseInt(u8, tok, 10) catch return null;
    if (v == 7) return 0;
    return if (v <= 6) v else null;
}

test {
    _ = zone;
}

fn at(y: i64, mo: i64, d: i64, h: i64, mi: i64) Time {
    return Time.fromSeconds(zone.daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60);
}

test "cron parse: forms and refusals" {
    inline for (.{ "* * * * *", "*/15 * * * *", "10-40/5 1,2 * JAN-MAR MON-FRI", "0 0 L * *", "0 0 * * 5L", "0 0 * * MON#2", "@daily", "@every 90s", "30 */5 * * * *", "0 0 * * 7", "0 0 ? * ?" }) |e| {
        _ = Schedule.parse(e, null) catch |err| {
            std.debug.print("failed: {s}\n", .{e});
            return err;
        };
    }
    var d: Diagnostic = .{};
    inline for (.{ "", "* * * *", "61 * * * *", "* * 1W * *", "* * * * * * *", "@every 500ms", "*/0 * * * *", "0 0 * * MON#6" }) |e| {
        try std.testing.expectError(error.InvalidSchedule, Schedule.parse(e, &d));
    }
}

test "cron: next in UTC and Vixie day semantics" {
    const z = Zone.utc;
    const every = try Schedule.parse("*/15 * * * *", null);
    try std.testing.expectEqual(at(2026, 1, 1, 0, 15).us, every.next(at(2026, 1, 1, 0, 0), &z).?.us);
    // dom and dow both restricted: either matches (2026-01-05 is a Monday, the 13th is a Tuesday).
    const either = try Schedule.parse("0 0 13 * MON", null);
    try std.testing.expectEqual(at(2026, 1, 5, 0, 0).us, either.next(at(2026, 1, 1, 0, 0), &z).?.us);
    // Only dow restricted.
    const mon = try Schedule.parse("0 0 * * MON", null);
    try std.testing.expectEqual(at(2026, 1, 5, 0, 0).us, mon.next(at(2026, 1, 1, 0, 0), &z).?.us);
}

test "cron: L, 5L and #" {
    const z = Zone.utc;
    const last = try Schedule.parse("0 0 L * *", null);
    try std.testing.expectEqual(at(2028, 2, 29, 0, 0).us, last.next(at(2028, 2, 1, 0, 0), &z).?.us);
    const lastfri = try Schedule.parse("0 0 * * 5L", null);
    try std.testing.expectEqual(at(2026, 10, 30, 0, 0).us, lastfri.next(at(2026, 10, 1, 0, 0), &z).?.us);
    const second_mon = try Schedule.parse("0 0 * * MON#2", null);
    try std.testing.expectEqual(at(2026, 10, 12, 0, 0).us, second_mon.next(at(2026, 10, 1, 0, 0), &z).?.us);
}

test "cron: @every is aligned to the epoch" {
    const z = Zone.utc;
    const s = try Schedule.parse("@every 90s", null);
    const n = s.next(Time.fromSeconds(100), &z).?;
    try std.testing.expectEqual(@as(i64, 180), @divFloor(n.us, std.time.us_per_s));
}

test "cron DST: 02:30 daily in Europe/Berlin" {
    const z = try Zone.fromPosix("CET-1CEST,M3.5.0,M10.5.0/3");
    const s = try Schedule.parse("30 2 * * *", null);
    // Spring forward 2026-03-29: fires at the end of the gap, 03:00 local = 01:00 UTC.
    const a = s.next(at(2026, 3, 28, 12, 0), &z).?;
    try std.testing.expectEqual(at(2026, 3, 29, 1, 0).us, a.us);
    // The day after, the usual 02:30 local = 00:30 UTC.
    try std.testing.expectEqual(at(2026, 3, 30, 0, 30).us, s.next(a, &z).?.us);
    // Fall back 2026-10-25: first 02:30 only (00:30 UTC), then the next day.
    const b = s.next(at(2026, 10, 24, 12, 0), &z).?;
    try std.testing.expectEqual(at(2026, 10, 25, 0, 30).us, b.us);
    try std.testing.expectEqual(at(2026, 10, 26, 1, 30).us, s.next(b, &z).?.us);
}

test "cron DST: every 30 minutes keeps its interval across the repeated hour" {
    const z = try Zone.fromPosix("CET-1CEST,M3.5.0,M10.5.0/3");
    const s = try Schedule.parse("*/30 * * * *", null);
    var out: [8]Time = undefined;
    const n = s.between(at(2026, 10, 25, 0, 0), at(2026, 10, 25, 2, 0), &z, out[0..]);
    // 00:30 01:00 01:30 02:00 UTC are 02:30 03:00(=02:00 CET)... all four fire.
    try std.testing.expectEqual(@as(usize, 4), n);
}
