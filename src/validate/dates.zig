// Copied from vkiryakov/zefir src/validator/dates.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! Date and time rules for string fields: `date`, `rfc3339`, `iso8601` and
//! `militaryTime`, each with its predicate (`v.isDate(s)`, ...), and the
//! bound rules `minDate` and `maxDate`. Zig has no date type, so a DTO
//! carries a date as the string it arrived as, and these rules read its
//! bytes: only 0x30-0x39 are digits, nothing is trimmed, and the calendar is
//! the proleptic Gregorian one for the years 0000-9999, always checked. There
//! is no clock and no time zone database: an offset is a number, and a
//! date-time stands for the UTC instant "local time minus the offset" (RFC
//! 3339 §4.2). A second 60 passes only as a leap second: at 23:59:60 UTC on
//! the last day of a month, without a table of the leap seconds that really
//! happened. The predicates take any bytes, never allocate, never backtrack
//! and run in time linear in the input.
const std = @import("std");
const core = @import("core.zig");
const schema = @import("schema.zig");
const Rule = core.Rule;
const Outcome = core.Outcome;

// ------------------------------------------------------------------ date, rfc3339, iso8601, militaryTime

/// An RFC 3339 full-date, the `date` format of JSON Schema: exactly
/// `YYYY-MM-DD`, a year 0000-9999 and a day that exists in its month
/// (`2020-02-29` passes, `2021-02-29` fails). No sign, no basic form
/// (`20200517`), no week or ordinal date, no time.
pub const date: Rule = core.predicateRule(.date, core.preconditions.date.message, isDate);

/// Whether `v.date` passes `s`.
pub fn isDate(s: []const u8) bool {
    return parseFullDate(s) != null;
}

/// An RFC 3339 date-time with an offset: `2020-05-17T10:30:00.5+05:30`. `T`,
/// `t` or a space between the date and the time; any number of fraction
/// digits after `.`; `Z`, `z` or `±HH:MM` with HH 00-23 and MM 00-59 (`Z`,
/// `+00:00` and `-00:00` are the same offset). Second 60 passes only as a
/// leap second. No offset, `+05` or `+0530`, a comma before the fraction and
/// a zone name such as `[Europe/Paris]` fail.
pub const rfc3339: Rule = core.predicateRule(.rfc3339, core.preconditions.rfc3339.message, isRfc3339);

/// Whether `v.rfc3339` passes `s`.
pub fn isRfc3339(s: []const u8) bool {
    return parseRfc3339(s) != null;
}

/// ISO 8601 dates and date-times as zefir reads them (the grammar of RFC
/// 3339 Appendix A, with the calendar always checked): a year (`2020`), a
/// year and month (`2020-05`), a calendar date (`2020-05-17`, `20200517`),
/// an ordinal date (`2020-138`, `2020138`), a week (`2020-W20`, `2020W20`)
/// or a week date (`2020-W20-7`, `2020W207`). Only after a complete
/// calendar, ordinal or week date may `T`, `t` or a space and a time follow:
/// `hh`, `hh:mm`, `hh:mm:ss` or `hhmm`, `hhmmss`, an optional fraction after
/// `.` or `,`, and an optional zone `Z`, `z`, `±hh`, `±hhmm` or `±hh:mm`.
/// The basic and extended forms may differ between the date, the time and
/// the zone, but not inside one of them. `24:00` (with zero seconds and
/// fraction) is the end of a day, and second 60 needs a zone and passes only
/// as a leap second. Every value that `v.date` or `v.rfc3339` passes passes
/// too.
pub const iso8601: Rule = core.predicateRule(.iso8601, "must be a valid ISO 8601 date", isIso8601);

/// Whether `v.iso8601` passes `s`.
pub fn isIso8601(s: []const u8) bool {
    const year = digitsAt(s, 0, 4) orelse return false;
    if (s.len == 4) return true;
    // The day number of the complete date and the index after it.
    var days: i64 = undefined;
    var i: usize = undefined;
    if (s[4] == '-') {
        if (s.len > 5 and s[5] == 'W') {
            // YYYY-Www or YYYY-Www-D
            const week = digitsAt(s, 6, 2) orelse return false;
            if (week < 1 or week > weeksInYear(year)) return false;
            if (s.len == 8) return true;
            if (s[8] != '-') return false;
            const weekday = digitsAt(s, 9, 1) orelse return false;
            if (weekday < 1 or weekday > 7) return false;
            days = daysFromWeekDate(year, week, weekday);
            i = 10;
        } else switch (digitRun(s, 5)) {
            2 => {
                // YYYY-MM or YYYY-MM-DD
                const month = digitsAt(s, 5, 2).?;
                if (month < 1 or month > 12) return false;
                if (s.len == 7) return true;
                if (s[7] != '-' or digitRun(s, 8) != 2) return false;
                const day = digitsAt(s, 8, 2).?;
                if (day < 1 or day > daysInMonth(year, month)) return false;
                days = daysFromCivil(year, month, day);
                i = 10;
            },
            3 => {
                // YYYY-DDD
                const day_of_year = digitsAt(s, 5, 3).?;
                if (day_of_year < 1 or day_of_year > daysInYear(year)) return false;
                days = daysFromCivil(year, 1, 1) + day_of_year - 1;
                i = 8;
            },
            else => return false,
        }
    } else if (s[4] == 'W') {
        // YYYYWww or YYYYWwwD
        const week = digitsAt(s, 5, 2) orelse return false;
        if (week < 1 or week > weeksInYear(year)) return false;
        if (s.len == 7) return true;
        const weekday = digitsAt(s, 7, 1) orelse return false;
        if (weekday < 1 or weekday > 7) return false;
        days = daysFromWeekDate(year, week, weekday);
        i = 8;
    } else switch (digitRun(s, 4)) {
        4 => {
            // YYYYMMDD
            const month = digitsAt(s, 4, 2).?;
            const day = digitsAt(s, 6, 2).?;
            if (month < 1 or month > 12) return false;
            if (day < 1 or day > daysInMonth(year, month)) return false;
            days = daysFromCivil(year, month, day);
            i = 8;
        },
        3 => {
            // YYYYDDD
            const day_of_year = digitsAt(s, 4, 3).?;
            if (day_of_year < 1 or day_of_year > daysInYear(year)) return false;
            days = daysFromCivil(year, 1, 1) + day_of_year - 1;
            i = 7;
        },
        // YYYYMM included: ISO 8601 has no basic year and month.
        else => return false,
    }
    if (i == s.len) return true;
    switch (s[i]) {
        'T', 't', ' ' => {},
        else => return false,
    }
    return isIsoTime(s[i + 1 ..], days);
}

/// The time of `isIso8601` after a complete date whose day number is
/// `days`: a clock, an optional fraction of its last component, an optional
/// zone, and the limits of each.
fn isIsoTime(t: []const u8, days: i64) bool {
    const hour = digitsAt(t, 0, 2) orelse return false;
    var i: usize = 2;
    var minute: ?u32 = null;
    var second: ?u32 = null;
    if (i < t.len and t[i] == ':') {
        // Extended: hh:mm[:ss]
        minute = digitsAt(t, 3, 2) orelse return false;
        i = 5;
        if (i < t.len and t[i] == ':') {
            second = digitsAt(t, 6, 2) orelse return false;
            i = 8;
        }
    } else if (digitsAt(t, 2, 2)) |m| {
        // Basic: hhmm[ss]
        minute = m;
        i = 4;
        if (digitsAt(t, 4, 2)) |sec| {
            second = sec;
            i = 6;
        }
    }
    var fraction: []const u8 = "";
    if (i < t.len and (t[i] == '.' or t[i] == ',')) {
        const n = digitRun(t, i + 1);
        if (n == 0) return false;
        fraction = t[i + 1 ..][0..n];
        i += 1 + n;
    }
    var offset: ?i32 = null;
    if (i < t.len) offset = parseIsoOffset(t[i..]) orelse return false;
    if (hour == 24) {
        // The end of the day: 24:00, 24:00:00, a fraction of zeros only.
        if (minute == null or minute.? != 0) return false;
        if (second != null and second.? != 0) return false;
        for (fraction) |c| {
            if (c != '0') return false;
        }
    } else if (hour > 23) return false;
    if (minute) |m| {
        if (m > 59) return false;
    }
    if (second) |sec| {
        if (sec == 60) {
            const zone = offset orelse return false;
            return toInstant(days, hour, minute.?, 60, fraction, zone) != null;
        }
        if (sec > 59) return false;
    }
    return true;
}

/// A zone of `isIso8601`: `Z`, `z`, `±hh`, `±hhmm` or `±hh:mm`, as minutes
/// east of UTC; null when malformed.
fn parseIsoOffset(z: []const u8) ?i32 {
    if (z.len == 1 and (z[0] == 'Z' or z[0] == 'z')) return 0;
    if (z[0] != '+' and z[0] != '-') return null;
    const hours = digitsAt(z, 1, 2) orelse return null;
    const minutes: u32 = switch (z.len) {
        3 => 0,
        5 => digitsAt(z, 3, 2) orelse return null,
        6 => minutes: {
            if (z[3] != ':') return null;
            break :minutes digitsAt(z, 4, 2) orelse return null;
        },
        else => return null,
    };
    return signedOffset(z[0], hours, minutes);
}

/// The 24-hour time of class-validator's `IsMilitaryTime`: `HH:MM` or
/// `HHMM`, from 00:00 to 23:59. No seconds, no `24:00`, no single-digit
/// hour or minute, no zone.
pub const militaryTime: Rule = core.predicateRule(.military_time, "must be a valid time in 24-hour HH:MM format", isMilitaryTime);

/// Whether `v.militaryTime` passes `s`.
pub fn isMilitaryTime(s: []const u8) bool {
    const colon = s.len == 5;
    if (s.len != 4 and !colon) return false;
    if (colon and s[2] != ':') return false;
    const hours = digitsAt(s, 0, 2) orelse return false;
    const minutes = digitsAt(s, if (colon) 3 else 2, 2) orelse return false;
    return hours <= 23 and minutes <= 59;
}

// ------------------------------------------------------------------ minDate, maxDate

/// A date or a date-time not before `min`, inclusive. `min` is known at
/// compile time: an RFC 3339 full-date (`"2020-01-01"`) or an RFC 3339
/// date-time with an offset (`"2020-01-01T00:00:00Z"`). The value must have
/// the form of the bound: with a date bound a value that `v.date` fails
/// reports the precondition `validation.date`, with a date-time bound a value
/// that `v.rfc3339` fails reports `validation.rfc3339`, each with the message
/// of that rule. Dates compare by the calendar; date-times as UTC instants,
/// exactly: fractions of any length (`.5` equals `.50`), and a leap second
/// after 23:59:59.999… and before the next midnight. There is no "now":
/// compare with the current time in the handler. Its placeholder is `{min}`,
/// the bound as written.
pub fn minDate(comptime min: []const u8) Rule {
    @setEvalBranchQuota(core.eval_quota);
    if (boundCallProblem(.min_date, min)) |text| @compileError(text);
    return boundRule(.min_date, min);
}

/// A date or a date-time not after `max`, inclusive; the bound and the
/// precondition as for `minDate`. Its placeholder is `{max}`.
pub fn maxDate(comptime max: []const u8) Rule {
    @setEvalBranchQuota(core.eval_quota);
    if (boundCallProblem(.max_date, max)) |text| @compileError(text);
    return boundRule(.max_date, max);
}

// ------------------------------------------------------------------ schema

/// A full-date of `isDate`, without anchors: a year 0000-9999 and a day that
/// exists in its month, 29 February in the leap years of the proleptic
/// Gregorian calendar (0000 among them).
const date_pattern = "(?:[0-9]{4}-(?:(?:0[13578]|1[02])-(?:0[1-9]|[12][0-9]|3[01])|(?:0[469]|11)-(?:0[1-9]|[12][0-9]|30)|02-(?:0[1-9]|1[0-9]|2[0-8]))" ++
    "|(?:[0-9]{2}(?:0[48]|[2468][048]|[13579][26])|(?:[02468][048]|[13579][26])00)-02-29)";

/// The shape of a date-time of `isRfc3339`, without the limits of its
/// numbers and of leap seconds.
const rfc3339_shape_pattern = "^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt ][0-9]{2}:[0-9]{2}:[0-9]{2}(?:\\.[0-9]+)?(?:[Zz]|[+-][0-9]{2}:[0-9]{2})$";

/// The shapes of the forms of `isIso8601`, without the calendar and the
/// limits of the time.
const iso8601_shape_pattern = "^[0-9]{4}(?:-[0-9]{2}|-?W[0-9]{2}|(?:-[0-9]{2}-[0-9]{2}|[0-9]{4}|-?[0-9]{3}|-W[0-9]{2}-[0-9]|W[0-9]{3})" ++
    "(?:[Tt ][0-9]{2}(?::[0-9]{2}(?::[0-9]{2})?|[0-9]{2}(?:[0-9]{2})?)?(?:[.,][0-9]+)?(?:[Zz]|[+-][0-9]{2}(?::?[0-9]{2})?)?)?)?$";

/// The JSON Schema keywords of a rule of this file on the unwrapped field
/// type `T`, for `v.schemaOf`. `date` and `militaryTime` are exact patterns,
/// the calendar included; `rfc3339` and `iso8601` get their shapes, since a
/// leap second depends on the offset; JSON Schema has no keyword that
/// compares dates, so `minDate` and `maxDate` have a note only.
pub fn schemaOf(comptime rule: Rule, comptime T: type) schema.RuleSchema {
    _ = T;
    return switch (rule.kind) {
        .date => schema.exact(&.{ schema.format("date"), schema.pattern("^" ++ date_pattern ++ "$") }),
        .rfc3339 => schema.approximate(&.{ schema.format("date-time"), schema.pattern(rfc3339_shape_pattern) }, "a valid RFC 3339 date-time"),
        .iso8601 => schema.approximate(&.{schema.pattern(iso8601_shape_pattern)}, "a valid ISO 8601 date or date-time"),
        .min_date, .max_date => blk: {
            const bound = rule.params[0].value.string;
            const form = if (isDate(bound)) "a date" else "an RFC 3339 date-time";
            break :blk schema.none(form ++ (if (rule.kind == .min_date) " not before " else " not after ") ++ bound);
        },
        .military_time => schema.exact(&.{schema.pattern("^(?:[01][0-9]|2[0-3]):?[0-5][0-9]$")}),
        else => unreachable,
    };
}

/// The arguments the hints show for an uncalled constructor of this file:
/// `minDate must be called, e.g. v.minDate("2020-01-01")`.
pub const call_examples = .{ .minDate = "\"2020-01-01\"", .maxDate = "\"2020-12-31\"" };

/// A bound: a full-date, whose 10 bytes order like the calendar, or an
/// exact UTC instant.
const Bound = union(enum) { date: []const u8, date_time: Instant };

fn parseBound(s: []const u8) ?Bound {
    if (isDate(s)) return .{ .date = s };
    if (parseRfc3339(s)) |instant| return .{ .date_time = instant };
    return null;
}

/// The earliest instant a date-time can stand for: every date-time passes a
/// `minDate` with this bound.
const earliest: Instant = parseRfc3339("0000-01-01T00:00:00+23:59").?;

/// The error of the call `minDate(bound)` or `maxDate(bound)`, or null: the
/// bound is a full-date or a date-time with an offset that some valid value
/// of its form fails. No date-time is after every other (fractions have no
/// last digit), so only a date bound can make `maxDate` vacuous.
fn boundCallProblem(comptime kind: core.Kind, comptime bound: []const u8) ?[]const u8 {
    @setEvalBranchQuota(core.eval_quota);
    const head = "validator: " ++ core.info(kind).name ++ "(" ++ core.renderArg(bound) ++ "): ";
    if (std.ascii.eqlIgnoreCase(bound, "now") or std.ascii.eqlIgnoreCase(bound, "today"))
        return head ++ "\"now\" is not supported: rules have no clock; compare with the current time in the handler";
    const parsed = parseBound(bound) orelse
        return head ++ "the bound must be an RFC 3339 full-date (2020-01-31) or date-time (2020-01-31T00:00:00Z)";
    switch (parsed) {
        .date => |text| if (std.mem.eql(u8, text, if (kind == .min_date) "0000-01-01" else "9999-12-31"))
            return head ++ "accepts every valid date; " ++ core.hints.use_date,
        .date_time => |instant| if (kind == .min_date and instant.order(earliest) != .gt)
            return head ++ "accepts every valid date-time; " ++ core.hints.use_rfc3339,
    }
    return null;
}

/// `minDate(bound)` or `maxDate(bound)`, for a bound that `boundCallProblem`
/// accepted.
fn boundRule(comptime kind: core.Kind, comptime bound: []const u8) Rule {
    const is_min = kind == .min_date;
    const parsed = comptime parseBound(bound).?;
    return core.define(kind, .{
        .message = (if (is_min) "must not be before " else "must not be after ") ++ core.renderValue(bound),
        .fallback = if (is_min) "must not be before the minimum date" else "must not be after the maximum date",
        .args = core.renderArg(bound),
        .params = &.{core.param(if (is_min) "min" else "max", bound)},
        .precondition = if (parsed == .date) core.preconditions.date else core.preconditions.rfc3339,
        .bounds = &.{contradictionBound(is_min, parsed)},
        .fits = fitsBound,
        .check_list = checkBoundList,
        .eval = struct {
            fn eval(value: anytype) Outcome {
                const s: []const u8 = value.*;
                const order: std.math.Order = switch (parsed) {
                    // Fixed-width ASCII digits: byte order is calendar order.
                    .date => |b| if (isDate(s)) std.mem.order(u8, s, b) else return .precondition,
                    .date_time => |b| (parseRfc3339(s) orelse return .precondition).order(b),
                };
                return core.passIf(if (is_min) order != .lt else order != .gt);
            }
        }.eval,
    });
}

/// The bound of `minDate` (`is_min`) or `maxDate` that the contradiction
/// check compares with the other bounds of the same form: a date as the
/// number `YYYYMMDD`, which orders as the calendar does; a date-time as its
/// exact UTC instant, on a scale of 86,401 seconds a day (the leap second
/// 23:59:60 included), with every digit of its fraction.
fn contradictionBound(comptime is_min: bool, comptime parsed: Bound) core.Bound {
    const side: core.Bound.Side = if (is_min) .lower else .upper;
    return switch (parsed) {
        .date => |text| .{
            .measure = .date,
            .side = side,
            .value = .{ .int = @as(comptime_int, digitsAt(text, 0, 4).?) * 10000 + @as(comptime_int, digitsAt(text, 5, 2).?) * 100 + @as(comptime_int, digitsAt(text, 8, 2).?) },
        },
        .date_time => |instant| .{
            .measure = .date_time,
            .side = side,
            .value = .{ .int = instantNumber(instant) },
            .scale = instant.fraction.len,
        },
    };
}

/// `instant` as `(days * 86401 + second) * 10^n + fraction`, where `n` is
/// the number of digits of its fraction.
fn instantNumber(comptime instant: Instant) comptime_int {
    comptime {
        var n: comptime_int = @as(comptime_int, instant.days) * 86401 + @as(comptime_int, instant.second);
        for (instant.fraction) |c| n = n * 10 + @as(comptime_int, c - '0');
        return n;
    }
}

/// The field-type check of `minDate` and `maxDate`.
fn fitsBound(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void {
    if (boundFieldProblem(rule, T, where)) |text| @compileError(text);
}

/// The declaration error of `minDate` or `maxDate` on the unwrapped field
/// type `T`, or null: the field is a string. A number field gets the number
/// rules as the hint: a numeric timestamp is a number.
fn boundFieldProblem(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) ?[]const u8 {
    const hint: ?[]const u8 = if (!core.isNumber(T)) null else if (rule.kind == .min_date) core.hints.timestamp_min else core.hints.timestamp_max;
    return core.stringProblem(rule, T, where, hint);
}

/// What the values of a date rule look like, as the errors name it.
const Form = enum {
    date,
    date_time,
    time,

    fn text(form: Form) []const u8 {
        return switch (form) {
            .date => "date",
            .date_time => "date-time",
            .time => "time",
        };
    }
};

/// The form of the values that `rule` takes, or null for a rule of another
/// kind; `iso8601` takes several.
fn formOf(comptime rule: *const Rule) ?Form {
    return switch (rule.kind) {
        .date => .date,
        .rfc3339 => .date_time,
        .military_time => .time,
        .min_date, .max_date => if (isDate(rule.params[0].value.string)) .date else .date_time,
        else => null,
    };
}

/// The error text of two rules of one value whose forms differ; `a` comes
/// first in the tuple.
fn differentFormsText(comptime a: *const Rule, comptime b: *const Rule, comptime where: []const u8) []const u8 {
    return core.ruleErrorText(a, where, " and " ++ b.label() ++ " need different forms (" ++ formOf(a).?.text() ++ " vs " ++ formOf(b).?.text() ++ "); no value can pass");
}

/// The list check of `minDate` and `maxDate`.
fn checkBoundList(comptime rule: *const Rule, comptime rules: []const Rule, comptime index: usize, comptime T: type, comptime where: []const u8) void {
    _ = T;
    if (boundListProblem(rule, rules, index, where)) |text| @compileError(text);
}

/// The error of the `minDate` or `maxDate` at `rules[index]` against the
/// other rules of its value, or null. A rule of another form beside it
/// (`date`, `rfc3339`, `militaryTime`, or a bound of the other form) leaves no
/// value that passes both, and `iso8601` beside it would pass values that
/// most often fail the bound's form; a pair of bounds is reported by the
/// first of the two.
fn boundListProblem(comptime rule: *const Rule, comptime rules: []const Rule, comptime index: usize, comptime where: []const u8) ?[]const u8 {
    @setEvalBranchQuota(core.eval_quota);
    const form = formOf(rule).?;
    for (rules, 0..) |*other, j| {
        if (j == index) continue;
        switch (other.kind) {
            .date, .rfc3339, .military_time => if (formOf(other).? != form)
                return if (j < index) differentFormsText(other, rule, where) else differentFormsText(rule, other, where),
            .iso8601 => return core.ruleErrorText(rule, where, " accepts only the form of its bound, so most iso8601 values would fail it; " ++
                (if (form == .date) core.hints.iso8601_with_date else core.hints.iso8601_with_date_time)),
            .min_date, .max_date => if (j > index and formOf(other).? != form) return differentFormsText(rule, other, where),
            else => {},
        }
    }
    return null;
}

// ------------------------------------------------------------------ the calendar

/// The value of the `n` ASCII digits at `s[i..]`, or null when `s` is too
/// short or one of them is not 0-9.
fn digitsAt(s: []const u8, i: usize, comptime n: usize) ?u32 {
    if (i > s.len or s.len - i < n) return null;
    var value: u32 = 0;
    for (s[i..][0..n]) |c| {
        if (c < '0' or c > '9') return null;
        value = value * 10 + (c - '0');
    }
    return value;
}

/// The number of ASCII digits in a row from `s[i]`.
fn digitRun(s: []const u8, i: usize) usize {
    var j = i;
    while (j < s.len and s[j] >= '0' and s[j] <= '9') j += 1;
    return j - i;
}

/// RFC 3339 Appendix C, for the years 0-9999.
fn isLeapYear(year: u32) bool {
    return std.time.epoch.isLeapYear(@intCast(year));
}

fn daysInYear(year: u32) u32 {
    return if (isLeapYear(year)) 366 else 365;
}

/// The table of RFC 3339 §5.7, for the years 0-9999 and the months 1-12.
fn daysInMonth(year: u32, month: u32) u32 {
    return std.time.epoch.getDaysInMonth(@intCast(year), @fromBackingInt(@as(u4, @intCast(month))));
}

/// Days since 1970-01-01 of a proleptic Gregorian date (H. Hinnant's
/// `days_from_civil`).
fn daysFromCivil(year: i64, month: u32, day: u32) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const year_of_era = y - era * 400;
    // March is month 0, so that the leap day ends the year.
    const shifted_month: i64 = @mod(@as(i64, month) + 9, 12);
    const day_of_year = @divFloor(153 * shifted_month + 2, 5) + @as(i64, day) - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

/// A proleptic Gregorian date; the year may be -1 for an instant that an
/// offset moves before 0000-01-01 in UTC.
const Civil = struct { year: i64, month: u32, day: u32 };

/// The inverse of `daysFromCivil` (H. Hinnant's `civil_from_days`).
fn civilFromDays(days: i64) Civil {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const day_of_era = z - era * 146097;
    const year_of_era = @divFloor(day_of_era - @divFloor(day_of_era, 1460) + @divFloor(day_of_era, 36524) - @divFloor(day_of_era, 146096), 365);
    const day_of_year = day_of_era - (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const shifted_month = @divFloor(5 * day_of_year + 2, 153);
    const day: u32 = @intCast(day_of_year - @divFloor(153 * shifted_month + 2, 5) + 1);
    const month: u32 = @intCast(if (shifted_month < 10) shifted_month + 3 else shifted_month - 9);
    const y = year_of_era + era * 400;
    return .{ .year = if (month <= 2) y + 1 else y, .month = month, .day = day };
}

/// The ISO weekday of a day number: 1 is Monday, 7 Sunday (1970-01-01 was a
/// Thursday).
fn isoWeekday(days: i64) u32 {
    return @intCast(@mod(days + 3, 7) + 1);
}

/// The weeks of an ISO week-numbering year: 53 when 1 January is a
/// Thursday, or a Wednesday in a leap year; 52 otherwise.
fn weeksInYear(year: u32) u32 {
    const january_first = isoWeekday(daysFromCivil(year, 1, 1));
    return if (january_first == 4 or (january_first == 3 and isLeapYear(year))) 53 else 52;
}

/// The day number of the ISO week date `year`-W`week`-`weekday`: week 1 is
/// the week of 4 January.
fn daysFromWeekDate(year: u32, week: u32, weekday: u32) i64 {
    const january_fourth = daysFromCivil(year, 1, 4);
    const first_monday = january_fourth - (@as(i64, isoWeekday(january_fourth)) - 1);
    return first_monday + (@as(i64, week) - 1) * 7 + (@as(i64, weekday) - 1);
}

// ------------------------------------------------------------------ instants

/// A point in time in UTC, ordered by day, then second, then fraction.
const Instant = struct {
    /// UTC days since 1970-01-01.
    days: i64,
    /// The UTC second of the day, 0-86400; 86400 is the leap second 23:59:60.
    second: u32,
    /// The digits of the fraction of the second, without the separator.
    fraction: []const u8,

    /// The exact order: no rounding, fractions of any length, missing
    /// digits read as 0 (`.5` equals `.50`).
    fn order(a: Instant, b: Instant) std.math.Order {
        if (a.days != b.days) return std.math.order(a.days, b.days);
        if (a.second != b.second) return std.math.order(a.second, b.second);
        for (0..@max(a.fraction.len, b.fraction.len)) |k| {
            const x = if (k < a.fraction.len) a.fraction[k] else '0';
            const y = if (k < b.fraction.len) b.fraction[k] else '0';
            if (x != y) return std.math.order(x, y);
        }
        return .eq;
    }
};

/// The UTC instant of a local time with an offset of `offset` minutes east
/// of UTC: local time minus the offset (RFC 3339 §4.2). A `second` of 60
/// must land on 23:59:60 UTC on the last day of a month, or the result is
/// null.
fn toInstant(local_days: i64, hour: u32, minute: u32, second: u32, fraction: []const u8, offset: i32) ?Instant {
    const local = local_days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @min(second, 59);
    const utc = local - @as(i64, offset) * 60;
    const days = @divFloor(utc, 86400);
    var second_of_day: u32 = @intCast(@mod(utc, 86400));
    if (second == 60) {
        if (second_of_day != 86399) return null;
        if (civilFromDays(days + 1).day != 1) return null;
        second_of_day = 86400;
    }
    return .{ .days = days, .second = second_of_day, .fraction = fraction };
}

/// An RFC 3339 full-date with the day limits of §5.7: its day number, or
/// null.
fn parseFullDate(s: []const u8) ?i64 {
    if (s.len != 10 or s[4] != '-' or s[7] != '-') return null;
    const year = digitsAt(s, 0, 4) orelse return null;
    const month = digitsAt(s, 5, 2) orelse return null;
    const day = digitsAt(s, 8, 2) orelse return null;
    if (month < 1 or month > 12) return null;
    if (day < 1 or day > daysInMonth(year, month)) return null;
    return daysFromCivil(year, month, day);
}

/// An RFC 3339 date-time (§5.6 with its notes on `t`, `z` and the space,
/// and the limits of §5.7): its UTC instant, or null.
fn parseRfc3339(s: []const u8) ?Instant {
    if (s.len < 20) return null;
    const days = parseFullDate(s[0..10]) orelse return null;
    switch (s[10]) {
        'T', 't', ' ' => {},
        else => return null,
    }
    if (s[13] != ':' or s[16] != ':') return null;
    const hour = digitsAt(s, 11, 2) orelse return null;
    const minute = digitsAt(s, 14, 2) orelse return null;
    const second = digitsAt(s, 17, 2) orelse return null;
    if (hour > 23 or minute > 59 or second > 60) return null;
    var i: usize = 19;
    var fraction: []const u8 = "";
    if (s[i] == '.') {
        const n = digitRun(s, i + 1);
        if (n == 0) return null;
        fraction = s[i + 1 ..][0..n];
        i += 1 + n;
    }
    const offset = parseRfc3339Offset(s[i..]) orelse return null;
    return toInstant(days, hour, minute, second, fraction, offset);
}

/// `Z`, `z` or `±HH:MM` as minutes east of UTC, or null.
fn parseRfc3339Offset(z: []const u8) ?i32 {
    if (z.len == 1 and (z[0] == 'Z' or z[0] == 'z')) return 0;
    if (z.len != 6 or (z[0] != '+' and z[0] != '-') or z[3] != ':') return null;
    const hours = digitsAt(z, 1, 2) orelse return null;
    const minutes = digitsAt(z, 4, 2) orelse return null;
    return signedOffset(z[0], hours, minutes);
}

/// An offset of `hours` 00-23 and `minutes` 00-59 with the sign `sign`, in
/// minutes, or null when out of range.
fn signedOffset(sign: u8, hours: u32, minutes: u32) ?i32 {
    if (hours > 23 or minutes > 59) return null;
    const total: i32 = @intCast(hours * 60 + minutes);
    return if (sign == '-') -total else total;
}

// ------------------------------------------------------------------ tests

const expectOutcome = core.expectOutcome;

const test_where = "Dto.field_rules.x";

/// A struct for the tests below.
const TestStamp = struct { seconds: i64 };

/// Runs `predicate` on each string and fails with the first that it does not
/// answer with `expected`.
fn expectAll(comptime name: []const u8, predicate: fn ([]const u8) bool, expected: bool, inputs: []const []const u8) !void {
    for (inputs) |s| {
        if (predicate(s) != expected) {
            std.debug.print("{s} {s} \"{f}\"\n", .{ name, if (expected) "rejected" else "accepted", std.zig.fmtString(s) });
            return error.TestUnexpectedResult;
        }
    }
}

/// The error of the list check of the bound rule at `rules[index]`, or null.
fn listText(comptime rules: anytype, comptime index: usize) ?[]const u8 {
    const list = core.entryParts(rules, test_where, false).rules;
    return boundListProblem(&list[index], list, index, test_where);
}

test "date, rfc3339, iso8601 and militaryTime are values with their documented codes and messages and no precondition" {
    const t = std.testing;
    const rules = .{ date, rfc3339, iso8601, militaryTime };
    const kinds = [_]core.Kind{ .date, .rfc3339, .iso8601, .military_time };
    const codes = [_][]const u8{ "validation.date", "validation.rfc3339", "validation.iso8601", "validation.military_time" };
    const messages = [_][]const u8{ "must be a valid date in YYYY-MM-DD format", "must be a valid RFC 3339 date-time", "must be a valid ISO 8601 date", "must be a valid time in 24-hour HH:MM format" };
    inline for (rules, kinds, codes, messages) |rule, kind, code, message| {
        try t.expectEqual(kind, rule.kind);
        try t.expectEqualStrings(code, rule.code);
        try t.expectEqualStrings(message, rule.message);
        try t.expectEqual(null, rule.args);
        try t.expectEqual(0, rule.params.len);
        try t.expectEqual(null, rule.precondition);
    }
    // The preconditions of minDate and maxDate are these rules' codes and messages.
    try t.expectEqualStrings(date.code, core.preconditions.date.code);
    try t.expectEqualStrings(date.message, core.preconditions.date.message);
    try t.expectEqualStrings(rfc3339.code, core.preconditions.rfc3339.code);
    try t.expectEqualStrings(rfc3339.message, core.preconditions.rfc3339.message);
}

test "minDate and maxDate have their documented codes, messages and bound parameters; the bound's form picks the precondition" {
    const t = std.testing;
    const after = minDate("2020-01-01");
    try t.expectEqual(core.Kind.min_date, after.kind);
    try t.expectEqualStrings("validation.min_date", after.code);
    try t.expectEqualStrings("must not be before 2020-01-01", after.message);
    try t.expectEqualStrings("\"2020-01-01\"", after.args.?);
    try t.expectEqual(1, after.params.len);
    try t.expectEqualStrings("min", after.params[0].name);
    try t.expectEqualStrings("2020-01-01", after.params[0].text);
    try t.expect(after.params[0].placeholder);
    try t.expectEqualStrings("validation.date", after.precondition.?.code);
    try t.expectEqualStrings("must be a valid date in YYYY-MM-DD format", after.precondition.?.message);
    try t.expectEqualStrings("minDate(\"2020-01-01\")", comptime after.call());
    try t.expectEqualStrings("min_date(\"2020-01-01\")", comptime after.label());

    const before = maxDate("2020-12-31 23:59:59.5z");
    try t.expectEqual(core.Kind.max_date, before.kind);
    try t.expectEqualStrings("validation.max_date", before.code);
    try t.expectEqualStrings("must not be after 2020-12-31 23:59:59.5z", before.message);
    try t.expectEqualStrings("max", before.params[0].name);
    try t.expectEqualStrings("2020-12-31 23:59:59.5z", before.params[0].text);
    try t.expectEqualStrings("validation.rfc3339", before.precondition.?.code);
    try t.expectEqualStrings("must be a valid RFC 3339 date-time", before.precondition.?.message);
}

/// A date-time bound of `len` bytes: `2020-01-01T00:00:00.` and zeros, then `Z`.
fn longBound(comptime len: usize) []const u8 {
    return "2020-01-01T00:00:00." ++ @as([len - 21]u8, @splat('0')) ++ "Z";
}

test "a bound of 493 bytes keeps the message of minDate at 512 bytes, 494 take the fallback; maxDate at 494 and 495" {
    const t = std.testing;
    try t.expectEqual(512, comptime minDate(longBound(493)).message.len);
    try t.expectEqualStrings("must not be before the minimum date", comptime minDate(longBound(494)).message);
    try t.expectEqual(512, comptime maxDate(longBound(494)).message.len);
    try t.expectEqualStrings("must not be after the maximum date", comptime maxDate(longBound(495)).message);
    // The placeholder and the comparison keep the whole bound.
    try t.expectEqualStrings(comptime longBound(494), comptime minDate(longBound(494)).params[0].text);
    try expectOutcome(.pass, minDate(longBound(494)), @as([]const u8, "2020-01-01T00:00:00Z"));
    try expectOutcome(.fail, minDate(longBound(494)), @as([]const u8, "2019-12-31T23:59:59.999Z"));
}

test "a bound is an RFC 3339 full-date or date-time with an offset, not now or today, and not vacuous" {
    const expect = std.testing.expectEqualStrings;
    const bad_form = "the bound must be an RFC 3339 full-date (2020-01-31) or date-time (2020-01-31T00:00:00Z)";
    inline for (.{ "2020-02-30", "2020-01-01T00:00:00", "20200101", "2020-W01-1", "2020-001", "2020-01-01T10:30:60Z", "", "+2020-01-01", "yesterday", "2020-01-01T00:00:00+0100", " 2020-01-01" }) |bound| {
        try expect(comptime "validator: minDate(" ++ core.renderArg(bound) ++ "): " ++ bad_form, comptime boundCallProblem(.min_date, bound).?);
    }
    try expect("validator: maxDate(\"2020-12-32\"): " ++ bad_form, comptime boundCallProblem(.max_date, "2020-12-32").?);
    try expect("validator: minDate(\"2020-01-01\\n\"): " ++ bad_form, comptime boundCallProblem(.min_date, "2020-01-01\n").?);
    const no_clock = "\"now\" is not supported: rules have no clock; compare with the current time in the handler";
    try expect("validator: minDate(\"now\"): " ++ no_clock, comptime boundCallProblem(.min_date, "now").?);
    try expect("validator: minDate(\"NOW\"): " ++ no_clock, comptime boundCallProblem(.min_date, "NOW").?);
    try expect("validator: maxDate(\"today\"): " ++ no_clock, comptime boundCallProblem(.max_date, "today").?);
    try expect("validator: maxDate(\"Today\"): " ++ no_clock, comptime boundCallProblem(.max_date, "Today").?);
    try expect("validator: minDate(\"0000-01-01\"): accepts every valid date; use v.date", comptime boundCallProblem(.min_date, "0000-01-01").?);
    try expect("validator: maxDate(\"9999-12-31\"): accepts every valid date; use v.date", comptime boundCallProblem(.max_date, "9999-12-31").?);
    inline for (.{ "0000-01-01T00:00:00+23:59", "0000-01-01t00:00:00.000+23:59", "0000-01-01 00:00:00+23:59" }) |bound| {
        try expect("validator: minDate(\"" ++ bound ++ "\"): accepts every valid date-time; use v.rfc3339", comptime boundCallProblem(.min_date, bound).?);
    }
    // Not vacuous: a positive offset reaches before these, and no date-time
    // is after every other.
    inline for (.{ "0000-01-01T00:00:00Z", "0000-01-01T00:00:00+23:58", "0000-01-02", "9999-12-31" }) |bound| {
        try std.testing.expectEqual(null, comptime boundCallProblem(.min_date, bound));
    }
    inline for (.{ "9999-12-31T23:59:60Z", "9999-12-30", "0000-01-01", "2020-01-01 00:00:00z" }) |bound| {
        try std.testing.expectEqual(null, comptime boundCallProblem(.max_date, bound));
    }
}

test "minDate and maxDate take strings; a number field gets the number rules as the hint" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: ";
    const after = minDate("2020-01-01");
    const before = maxDate("2020-12-31");
    try expect(head ++ "min_date expects a string, field is i64; for a numeric timestamp use v.min", comptime boundFieldProblem(&after, i64, test_where).?);
    try expect(head ++ "max_date expects a string, field is f64; for a numeric timestamp use v.max", comptime boundFieldProblem(&before, f64, test_where).?);
    try expect(head ++ "min_date expects a string, field is bool", comptime boundFieldProblem(&after, bool, test_where).?);
    try expect(head ++ "min_date expects a string, field is dates.TestStamp", comptime boundFieldProblem(&after, TestStamp, test_where).?);
    try expect(head ++ "min_date expects a string, field is []const i64", comptime boundFieldProblem(&after, []const i64, test_where).?);
    try expect(head ++ "max_date expects a string, field is [10]u8; [N]u8 is an array of numbers, not a string: use []const u8", comptime boundFieldProblem(&before, [10]u8, test_where).?);
    try expect(head ++ "min_date expects a string, field is []const []const u8; use v.each(v.minDate(\"2020-01-01\"))", comptime boundFieldProblem(&after, []const []const u8, test_where).?);
    try expect(head ++ "max_date expects a string, field is []const ?[]const u8; use v.each(v.maxDate(\"2020-12-31\"))", comptime boundFieldProblem(&before, []const ?[]const u8, test_where).?);
    inline for (.{ []const u8, []u8, [:0]const u8 }) |T| {
        try std.testing.expectEqual(null, comptime boundFieldProblem(&after, T, test_where));
    }
    try expect(head ++ "date expects a string, field is u32", comptime core.stringProblem(&date, u32, test_where, null).?);
    try expect(head ++ "military_time expects a string, field is [10]u8; [N]u8 is an array of numbers, not a string: use []const u8", comptime core.stringProblem(&militaryTime, [10]u8, test_where, null).?);
    try expect(head ++ "iso8601 expects a string, field is []const []const u8; use v.each(v.iso8601)", comptime core.stringProblem(&iso8601, []const []const u8, test_where, null).?);
}

test "an uncalled minDate or maxDate gets an example call" {
    const expect = std.testing.expectEqualStrings;
    try expect("minDate must be called, e.g. v.minDate(\"2020-01-01\")", comptime core.hints.mustBeCalled("minDate", @TypeOf(minDate)));
    try expect("maxDate must be called, e.g. v.maxDate(\"2020-12-31\")", comptime core.hints.mustBeCalled("maxDate", @TypeOf(maxDate)));
}

test "a bound beside a rule or a bound of another form leaves no value; iso8601 beside a bound gets the rule of its form" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: ";
    const no_value = "; no value can pass";
    try expect(head ++ "rfc3339 and min_date(\"2020-01-01\") need different forms (date-time vs date)" ++ no_value, comptime listText(.{ rfc3339, minDate("2020-01-01") }, 1).?);
    try expect(head ++ "min_date(\"2020-01-01\") and rfc3339 need different forms (date vs date-time)" ++ no_value, comptime listText(.{ minDate("2020-01-01"), rfc3339 }, 0).?);
    try expect(head ++ "date and min_date(\"2020-01-01T00:00:00Z\") need different forms (date vs date-time)" ++ no_value, comptime listText(.{ date, minDate("2020-01-01T00:00:00Z") }, 1).?);
    try expect(head ++ "military_time and min_date(\"2020-01-01\") need different forms (time vs date)" ++ no_value, comptime listText(.{ militaryTime, minDate("2020-01-01") }, 1).?);
    try expect(head ++ "max_date(\"2020-12-31T23:59:59Z\") and military_time need different forms (date-time vs time)" ++ no_value, comptime listText(.{ maxDate("2020-12-31T23:59:59Z"), militaryTime }, 0).?);
    try expect(head ++ "rfc3339 and max_date(\"2020-12-31\") need different forms (date-time vs date)" ++ no_value, comptime listText(.{ rfc3339, maxDate("2020-12-31") }, 1).?);
    try expect(head ++ "date and max_date(\"2020-12-31T23:59:59Z\") need different forms (date vs date-time)" ++ no_value, comptime listText(.{ date, maxDate("2020-12-31T23:59:59Z") }, 1).?);
    try expect(head ++ "min_date(\"2020-01-01\") and max_date(\"2020-12-31T00:00:00Z\") need different forms (date vs date-time)" ++ no_value, comptime listText(.{ minDate("2020-01-01"), maxDate("2020-12-31T00:00:00Z") }, 0).?);
    try expect(head ++ "min_date(\"2020-01-01\") and min_date(\"2020-01-01T00:00:00Z\") need different forms (date vs date-time)" ++ no_value, comptime listText(.{ minDate("2020-01-01"), minDate("2020-01-01T00:00:00Z") }, 0).?);
    try expect(head ++ "max_date(\"2020-12-31\") and max_date(\"2020-12-31T23:59:59Z\") need different forms (date vs date-time)" ++ no_value, comptime listText(.{ maxDate("2020-12-31"), maxDate("2020-12-31T23:59:59Z") }, 0).?);
    // The first bound of a pair reports it; the second one stays silent.
    try std.testing.expectEqual(null, comptime listText(.{ minDate("2020-01-01"), maxDate("2020-12-31T00:00:00Z") }, 1));
    const iso = " accepts only the form of its bound, so most iso8601 values would fail it; ";
    try expect(head ++ "min_date(\"2020-01-01\")" ++ iso ++ "use v.date instead of v.iso8601", comptime listText(.{ iso8601, minDate("2020-01-01") }, 1).?);
    try expect(head ++ "min_date(\"2020-01-01T00:00:00Z\")" ++ iso ++ "use v.rfc3339 instead of v.iso8601", comptime listText(.{ iso8601, minDate("2020-01-01T00:00:00Z") }, 1).?);
    try expect(head ++ "max_date(\"2020-12-31\")" ++ iso ++ "use v.date instead of v.iso8601", comptime listText(.{ maxDate("2020-12-31"), iso8601 }, 0).?);
    try expect(head ++ "max_date(\"2020-12-31T23:59:59Z\")" ++ iso ++ "use v.rfc3339 instead of v.iso8601", comptime listText(.{ iso8601, maxDate("2020-12-31T23:59:59Z") }, 1).?);
    // Rules of the bound's form, rules of no form and bounds of one form fit.
    const not_empty = @import("common.zig").notEmpty;
    inline for (.{ 1, 2 }) |i| {
        try std.testing.expectEqual(null, comptime listText(.{ date, minDate("2020-01-01"), maxDate("2020-12-31"), not_empty }, i));
        try std.testing.expectEqual(null, comptime listText(.{ rfc3339.withMessage("a date-time"), minDate("2020-01-01T00:00:00Z"), maxDate("2020-12-31T23:59:59Z"), not_empty }, i));
    }
}

test "the calendar agrees with std.time.epoch and maps every day of 0000-9999 to the next day number and back" {
    const t = std.testing;
    // std.time.epoch counts from 1970: compare 200 years day by day.
    var d: i64 = 0;
    while (d < 365 * 200) : (d += 1) {
        const year_day = (std.time.epoch.EpochDay{ .day = @intCast(d) }).calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const c = civilFromDays(d);
        try t.expectEqual(@as(i64, year_day.year), c.year);
        try t.expectEqual(@as(u32, month_day.month.numeric()), c.month);
        try t.expectEqual(@as(u32, month_day.day_index) + 1, c.day);
    }
    var previous = daysFromCivil(0, 1, 1) - 1;
    var year: u32 = 0;
    while (year <= 9999) : (year += 1) {
        var month: u32 = 1;
        while (month <= 12) : (month += 1) {
            var day: u32 = 1;
            while (day <= daysInMonth(year, month)) : (day += 1) {
                const n = daysFromCivil(year, month, day);
                try t.expectEqual(previous + 1, n);
                const c = civilFromDays(n);
                try t.expect(c.year == year and c.month == month and c.day == day);
                previous = n;
            }
        }
    }
    try t.expectEqual(-719528, daysFromCivil(0, 1, 1));
    try t.expectEqual(2932896, daysFromCivil(9999, 12, 31));
    // The day before 0000-01-01 is in year -1, which an offset can reach.
    const before = civilFromDays(daysFromCivil(0, 1, 1) - 1);
    try t.expect(before.year == -1 and before.month == 12 and before.day == 31);
}

test "ISO weeks: 1775 long years in 0000-9999, and week 1 starts on the Monday of the week of 4 January" {
    const t = std.testing;
    var long_years: usize = 0;
    var year: u32 = 0;
    while (year <= 9999) : (year += 1) {
        const weeks = weeksInYear(year);
        if (weeks == 53) long_years += 1;
        if (year < 9999) try t.expectEqual(@as(i64, weeks) * 7, daysFromWeekDate(year + 1, 1, 1) - daysFromWeekDate(year, 1, 1));
        try t.expectEqual(1, isoWeekday(daysFromWeekDate(year, 1, 1)));
    }
    try t.expectEqual(1775, long_years);
    // 2020-W53-4 is 2020-12-31; 2021-W01-1 is 2021-01-04.
    try t.expectEqual(daysFromCivil(2020, 12, 31), daysFromWeekDate(2020, 53, 4));
    try t.expectEqual(daysFromCivil(2021, 1, 4), daysFromWeekDate(2021, 1, 1));
}

test "instants order exactly: leap seconds after 23:59:59.999..., fractions digit by digit, offsets subtracted" {
    const t = std.testing;
    const ordered = comptime [_]Instant{
        parseRfc3339("2016-12-31T23:59:59Z").?,
        parseRfc3339("2016-12-31T23:59:59.999999999999Z").?,
        parseRfc3339("2016-12-31T23:59:60Z").?,
        parseRfc3339("2017-01-01T08:59:60.5+09:00").?,
        parseRfc3339("2017-01-01T00:00:00Z").?,
        parseRfc3339("2017-01-01T00:00:00.0000000001Z").?,
        parseRfc3339("2017-01-01T00:00:00.000000001Z").?,
    };
    for (ordered, 0..) |a, i| {
        for (ordered, 0..) |b, j| try t.expectEqual(std.math.order(i, j), a.order(b));
    }
    const same = .{
        .{ "2020-01-01T00:00:00.5Z", "2020-01-01T01:00:00.50+01:00" },
        .{ "2020-01-01T00:00:00Z", "2020-01-01 00:00:00.000-00:00" },
        .{ "2020-01-01T00:00:00z", "2019-12-31T19:00:00-05:00" },
        .{ "0000-01-01T00:00:00+23:59", "0000-01-01t00:00:00.000+23:59" },
    };
    inline for (same) |pair| try t.expectEqual(.eq, comptime parseRfc3339(pair[0]).?.order(parseRfc3339(pair[1]).?));
    try t.expectEqual(.lt, earliest.order(comptime parseRfc3339("0000-01-01T00:00:00+23:58").?));
}

test "date passes YYYY-MM-DD days that exist in the proleptic Gregorian calendar" {
    try expectAll("isDate", isDate, true, &.{ "2020-05-17", "2020-02-29", "2000-02-29", "0000-01-01", "9999-12-31", "1582-10-10", "2020-01-31", "2020-04-30", "0400-02-29" });
    try expectAll("isDate", isDate, false, &.{
        "",                                                       "2021-02-29",            "1900-02-29",  "2020-04-31",   "2020-13-01",           "2020-00-01",
        "2020-01-00",                                             "2020-01-32",            "20200517",    "2020-5-17",    "2020-05-17T00:00:00Z", "2020-05-17 ",
        "2020-05",                                                "2020-W20-7",            "2020-138",    "+2020-05-17",  "12020-05-17",          "2020/05/17",
        "\xef\xbc\x92\xef\xbc\x90\xef\xbc\x92\xef\xbc\x90-05-17", "2020-05-1\xe0\xa7\xaa", " 2020-05-17", "2020-05-17\n",
    });
}

test "rfc3339 passes date-times with an offset, any fraction and leap seconds at the end of a month in UTC" {
    try expectAll("isRfc3339", isRfc3339, true, &.{
        "1985-04-12T23:20:50.52Z",              "1996-12-19T16:39:57-08:00",    "1990-12-31T23:59:60Z",
        "1990-12-31T15:59:60-08:00",            "1937-01-01T12:00:27.87+00:20", "2020-05-17t10:30:00z",
        "2020-05-17 10:30:00Z",                 "2020-05-17T10:30:00-00:00",    "2020-05-17T10:30:00+14:00",
        "2020-05-17T10:30:00+23:59",            "2020-02-29T00:00:00Z",         "0000-01-01T00:00:00Z",
        "9999-12-31T23:59:59.999999999999999Z", "2017-01-01T08:59:60+09:00",    "1998-12-31T23:59:60.5Z",
        "1999-01-01T01:29:60+01:30",            "1998-12-31T00:29:60-23:30",    "2017-01-31T23:59:60Z",
        "0000-01-01T00:00:60+00:01",            "9999-12-31T23:59:60Z",         "9999-12-31T00:00:60-23:59",
    });
    try expectAll("isRfc3339", isRfc3339, false, &.{
        "",                           "2020-05-17",                         "2020-05-17T10:30Z",
        "2020-05-17T10:30:00",        "2021-02-29T00:00:00Z",               "2020-04-31T10:00:00Z",
        "2020-05-17T10:30:60Z",       "2020-05-17T23:59:60Z",               "1998-12-31T23:59:60+01:00",
        "2020-05-17T24:00:00Z",       "2020-05-17T10:60:00Z",               "2020-05-17T10:30:61Z",
        "2020-05-17T10:30:00+24:00",  "2020-05-17T10:30:00+05:60",          "2020-05-17T10:30:00+0530",
        "2020-05-17T10:30:00+05",     "2020-05-17T10:30:00,5Z",             "2020-05-17T10:30:00.Z",
        "20200517T103000Z",           "2020-05-17T10:30:00Z\n",             " 2020-05-17T10:30:00Z",
        "2020-05-17\t10:30:00Z",      "+2020-05-17T10:30:00Z",              "2020-05-17T10:30:00 +05:30",
        "2020-05-17T10:30:00Z+05:30", "2020-05-17T10:30:00Z[Europe/Paris]", "2020-05-17T10:30:00+05:30:00",
    });
}

test "iso8601 passes reduced, basic, extended, ordinal and week forms, and a time only after a complete date" {
    try expectAll("isIso8601", isIso8601, true, &.{
        "2020",                      "2020-05",                 "2020-05-17",                     "20200517",
        "2020-138",                  "2020138",                 "2020-W20",                       "2020W20",
        "2020-W20-7",                "2020W207",                "2020-05-17T10:30:00Z",           "2020-05-17T10:30:00.123+05:30",
        "2020-05-17T10:30",          "2020-05-17T10",           "2020-05-17T10.5",                "2020-05-17T10:30,25",
        "20200517T103000Z",          "2020-05-17T103000+0530",  "2020-138T10:30:00Z",             "2020-W20-7T10:30:00Z",
        "2020-05-17 10:30:00Z",      "2020-05-17t10:30:00z",    "2020-05-17T10:30:00+14:00",      "2020-05-17T10:30:00-00:00",
        "2020-05-17T10:30:00+05",    "2020-05-17T24:00",        "2020-05-17T24:00:00",            "2020-366",
        "2020-360",                  "2020-W53-1",              "2016-12-31T23:59:60Z",           "2017-01-01T08:59:60+09:00",
        "0000-01-01",                "0400-02-29",              "9999-12-31T23:59:59.999999999Z", "2020-05-17T10:30+0530",
        "0000-01-01T00:00:60+00:01", "2020-05-17T24:00:00.000", "2020-W53-4T23:59:60Z",           "2020-366T23:59:60Z",
        "2017-01-01T08:59:60+09",    "0000",
    });
    try expectAll("isIso8601", isIso8601, false, &.{
        "",                      "202005",                   "202005T10",                 "2020-05T10:00",
        "2020-W20T10:00",        "2020-05-17T",              "2020-05-17TZ",              "2020-05-17 ",
        "2020-05-17\n",          "2020-05-17\t10:30",        "2020-05-17\xc2\xa010:30",   "2021-02-29",
        "1900-02-29",            "2020-04-31",               "2021-366",                  "2021-W53",
        "2020-W00",              "2020-W20-8",               "2020-W201",                 "2020-13-01",
        "2020-00-10",            "2020-0517",                "2020-05-17T25:00",          "2020-05-17T24:30",
        "2020-05-17T24",         "2020-05-17T45",            "2020-05-17T24:0059",        "2020-05-17T24:00.5",
        "2020-05-17T10:60",      "2020-05-17T10:3000",       "2020-05-17T10:30:00.",      "2020-05-17T10:30:60Z",
        "2020-05-31T23:59:60",   "2020-05-17T23:59:60Z",     "2020-05-17T10:30:00+24:00", "2020-05-17T10:30:00+05:",
        "2020-05-17T10:30:00+5", "2020-05-17T10:30:00 Z",    "2020-05-17T10:30:00ZZ",     "+2020-05-17",
        "-2020-05-17",           "12020-05-17",              "2020-5-17",                 "2020/05/17",
        "17.05.2020",            "2020-05-17T10:30:00Z\x00", "P1D",                       "10:30",
        "2020-05-17/2020-05-18", "2020-05-17T24:00:00.001",  "2020-W53-3T23:59:60Z",      "202",
        "2020-W5",               "2020W5",                   "2020-1",                    "2020-05-1",
    });
}

test "militaryTime passes HH:MM and HHMM from 00:00 to 23:59" {
    try expectAll("isMilitaryTime", isMilitaryTime, true, &.{ "00:00", "23:59", "09:30", "0930", "1200", "12:30", "0000", "2359" });
    try expectAll("isMilitaryTime", isMilitaryTime, false, &.{
        "",       "24:00",   "2400",                        "9:30",  "09:60", "09:30:00", "09-30",  "093",
        " 09:30", "09:30\n", "\xef\xbc\x90\xef\xbc\x99:30", "23:60", "09:5",  "12.30",    "12::30", "1230Z",
        "12:3a",  "2a:30",   "-1:30",
    });
}

test "minDate and maxDate compare dates by the calendar and report the date precondition on any other value" {
    const after = minDate("2020-01-01");
    try expectOutcome(.pass, after, @as([]const u8, "2020-01-01"));
    try expectOutcome(.pass, after, @as([]const u8, "2020-01-02"));
    try expectOutcome(.pass, after, @as([]const u8, "9999-12-31"));
    try expectOutcome(.fail, after, @as([]const u8, "2019-12-31"));
    try expectOutcome(.fail, after, @as([]const u8, "0000-01-01"));
    inline for (.{ "2020-02-30", "2020-01-01T00:00:00Z", "20200101", "", "2020-01-01\n" }) |value| {
        try expectOutcome(.precondition, after, @as([]const u8, value));
    }
    const before = maxDate("2020-12-31");
    try expectOutcome(.pass, before, @as([]const u8, "2020-12-31"));
    try expectOutcome(.pass, before, @as([]const u8, "0000-01-01"));
    try expectOutcome(.fail, before, @as([]const u8, "2021-01-01"));
    try expectOutcome(.fail, before, @as([]const u8, "9999-12-31"));
    try expectOutcome(.precondition, before, @as([]const u8, "2020-12-31T10:00:00Z"));
    try expectOutcome(.fail, maxDate("9999-12-30"), @as([]const u8, "9999-12-31"));
}

test "minDate and maxDate compare date-times as exact UTC instants and report the rfc3339 precondition on any other value" {
    const after = minDate("2020-01-01T00:00:00Z");
    for ([_][]const u8{ "2020-01-01T00:00:00Z", "2020-01-01T00:00:00.000Z", "2020-01-01T01:00:00+01:00", "2019-12-31T19:00:00-05:00", "2020-01-01T00:00:00-00:00", "2020-01-01 00:00:00z" }) |value| {
        try expectOutcome(.pass, after, value);
    }
    for ([_][]const u8{ "2019-12-31T23:59:59.999999999Z", "2020-01-01T00:59:59+01:00", "2020-01-01T13:59:59+14:00", "2019-12-31T23:59:60Z" }) |value| {
        try expectOutcome(.fail, after, value);
    }
    for ([_][]const u8{ "2020-01-01", "2020-01-01T00:00:00", "" }) |value| {
        try expectOutcome(.precondition, after, value);
    }
    const half = minDate("2020-01-01T00:00:00.5Z");
    try expectOutcome(.fail, half, @as([]const u8, "2020-01-01T00:00:00.49999Z"));
    try expectOutcome(.pass, half, @as([]const u8, "2020-01-01T01:00:00.5+01:00"));
    try expectOutcome(.pass, minDate("2020-01-01 00:00:00z"), @as([]const u8, "2020-01-01T00:00:00Z"));
    try expectOutcome(.fail, minDate("0000-01-01T00:00:00Z"), @as([]const u8, "0000-01-01T00:00:00+01:00"));
    const before = maxDate("2016-12-31T23:59:59Z");
    for ([_][]const u8{ "2016-12-31T23:59:59Z", "2017-01-01T08:59:59+09:00", "2016-12-31T15:59:59-08:00", "2016-12-31T23:59:59.0000000000Z" }) |value| {
        try expectOutcome(.pass, before, value);
    }
    for ([_][]const u8{ "2016-12-31T23:59:59.000001Z", "2016-12-31T23:59:60Z", "2016-12-31T16:00:00-08:00" }) |value| {
        try expectOutcome(.fail, before, value);
    }
    const leap = maxDate("2016-12-31T23:59:60Z");
    try expectOutcome(.pass, leap, @as([]const u8, "2016-12-31T23:59:60Z"));
    try expectOutcome(.pass, leap, @as([]const u8, "2017-01-01T08:59:60+09:00"));
    try expectOutcome(.fail, leap, @as([]const u8, "2016-12-31T23:59:60.5Z"));
    try expectOutcome(.fail, leap, @as([]const u8, "2017-01-01T00:00:00Z"));
}
