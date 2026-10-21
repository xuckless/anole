//! IEEE 754-2008 decimal128 in the binary integer (BID) encoding, as BSON
//! stores it (specifications/source/bson-decimal128/decimal128.md). An
//! immutable value: no arithmetic, only conversion to and from strings.
//! Parsing rounds only when that is exact (dropping trailing zeros) and
//! clamps the exponent when the value allows; anything else is an error.
const std = @import("std");

const Decimal128 = @This();

/// The low and high 64 bits; on the wire, low first, both little-endian.
low: u64,
high: u64,

const exponent_max = 6111;
const exponent_min = -6176;
const exponent_bias = 6176;
const max_digits = 34;
const coefficient_limit: u128 = std.math.pow(u128, 10, max_digits);

const sign_bit: u64 = 1 << 63;
const nan_bits: u64 = 0x7C00_0000_0000_0000;
const infinity_bits: u64 = 0x7800_0000_0000_0000;

pub const nan: Decimal128 = .{ .low = 0, .high = nan_bits };
pub const infinity: Decimal128 = .{ .low = 0, .high = infinity_bits };
pub const negative_infinity: Decimal128 = .{ .low = 0, .high = infinity_bits | sign_bit };

/// The longest `toString` result ("-0.000000" and 34 digits).
pub const max_string_len = 48;

pub const ParseError = error{
    /// Not a numeric string (decimal128.md, "From String Representation").
    InvalidDecimal,
    /// More than 34 significant digits, or an exponent below the minimum,
    /// that could only be stored by rounding away a non-zero digit.
    Inexact,
    /// An exponent above the maximum that clamping cannot absorb.
    Overflow,
};

pub fn fromInt(v: i64) Decimal128 {
    return fromParts(v < 0, @abs(v), 0);
}

/// `coefficient` × 10^`exponent`; the caller keeps both in range
/// (coefficient below 10^34, exponent within -6176..6111).
pub fn fromParts(negative: bool, coefficient: u128, exponent: i32) Decimal128 {
    std.debug.assert(coefficient < coefficient_limit);
    std.debug.assert(exponent >= exponent_min and exponent <= exponent_max);
    const biased: u64 = @intCast(exponent + exponent_bias);
    return .{
        .low = @truncate(coefficient),
        .high = (if (negative) sign_bit else 0) | (biased << 49) | @as(u64, @truncate(coefficient >> 64)),
    };
}

pub fn parse(s: []const u8) ParseError!Decimal128 {
    var i: usize = 0;
    var negative = false;
    if (s.len > 0 and (s[0] == '+' or s[0] == '-')) {
        negative = s[0] == '-';
        i = 1;
    }
    const rest = s[i..];
    if (std.ascii.eqlIgnoreCase(rest, "inf") or std.ascii.eqlIgnoreCase(rest, "infinity"))
        return if (negative) negative_infinity else infinity;
    if (std.ascii.eqlIgnoreCase(rest, "nan"))
        return .{ .low = 0, .high = nan_bits | (if (negative) sign_bit else 0) };

    var coefficient: u128 = 0;
    // Significant digits kept, digits after the point, and zeros past the
    // 34th significant digit (dropped, each raising the exponent by one).
    var digits: u32 = 0;
    var fraction: i64 = 0;
    var dropped: i64 = 0;
    var any_digit = false;
    var point = false;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '.') {
            if (point) return error.InvalidDecimal;
            point = true;
            continue;
        }
        if (c < '0' or c > '9') break;
        any_digit = true;
        if (point) fraction += 1;
        if (digits == 0 and c == '0') continue;
        if (digits < max_digits) {
            coefficient = coefficient * 10 + (c - '0');
            digits += 1;
        } else {
            if (c != '0') return error.Inexact;
            dropped += 1;
        }
    }
    if (!any_digit) return error.InvalidDecimal;

    var written: i64 = 0;
    if (i < s.len) {
        if (s[i] != 'e' and s[i] != 'E') return error.InvalidDecimal;
        i += 1;
        var exp_negative = false;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) {
            exp_negative = s[i] == '-';
            i += 1;
        }
        if (i == s.len) return error.InvalidDecimal;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            if (c < '0' or c > '9') return error.InvalidDecimal;
            // Saturates far beyond any representable exponent; only zeros
            // clamp from there, and the loops below are bounded by 34 digits.
            written = @min(written * 10 + (c - '0'), 1 << 40);
        }
        if (exp_negative) written = -written;
    }
    var exponent = written - fraction + dropped;

    if (coefficient == 0) {
        exponent = std.math.clamp(exponent, exponent_min, exponent_max);
    } else {
        while (exponent > exponent_max) {
            if (digits >= max_digits) return error.Overflow;
            coefficient *= 10;
            digits += 1;
            exponent -= 1;
        }
        while (exponent < exponent_min) {
            if (coefficient % 10 != 0) return error.Inexact;
            coefficient /= 10;
            exponent += 1;
        }
    }
    return fromParts(negative, coefficient, @intCast(exponent));
}

pub fn isNan(d: Decimal128) bool {
    return (d.high >> 58) & 0x1F == 0x1F;
}

pub fn isInfinite(d: Decimal128) bool {
    return (d.high >> 58) & 0x1F == 0x1E;
}

pub fn isNegative(d: Decimal128) bool {
    return d.high & sign_bit != 0;
}

pub fn fromBytes(b: [16]u8) Decimal128 {
    return .{ .low = std.mem.readInt(u64, b[0..8], .little), .high = std.mem.readInt(u64, b[8..16], .little) };
}

pub fn toBytes(d: Decimal128) [16]u8 {
    var b: [16]u8 = undefined;
    std.mem.writeInt(u64, b[0..8], d.low, .little);
    std.mem.writeInt(u64, b[8..16], d.high, .little);
    return b;
}

pub fn eql(a: Decimal128, b: Decimal128) bool {
    return a.low == b.low and a.high == b.high;
}

/// The coefficient and exponent of a finite value. Encodings that do not
/// hold a valid coefficient (above 10^34 - 1, or the "11" combination
/// form) read as zero, as IEEE 754-2008 asks.
fn parts(d: Decimal128) struct { coefficient: u128, exponent: i32 } {
    var biased: u64 = undefined;
    var coefficient: u128 = undefined;
    if ((d.high >> 61) & 3 == 3) {
        biased = (d.high >> 47) & 0x3FFF;
        coefficient = 0;
    } else {
        biased = (d.high >> 49) & 0x3FFF;
        coefficient = (@as(u128, d.high & 0x1_FFFF_FFFF_FFFF) << 64) | d.low;
        if (coefficient >= coefficient_limit) coefficient = 0;
    }
    return .{ .coefficient = coefficient, .exponent = @as(i32, @intCast(biased)) - exponent_bias };
}

/// The spec's string form ("1.23E+5", "0.001", "-Infinity", "NaN").
pub fn toString(d: Decimal128, buf: *[max_string_len]u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    d.format(&w) catch unreachable;
    return w.buffered();
}

pub fn format(d: Decimal128, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (d.isNan()) return w.writeAll("NaN");
    if (d.isNegative()) try w.writeByte('-');
    if (d.isInfinite()) return w.writeAll("Infinity");

    const p = d.parts();
    var digit_buf: [max_digits]u8 = undefined;
    var n: usize = 0;
    var c = p.coefficient;
    while (true) {
        digit_buf[digit_buf.len - 1 - n] = '0' + @as(u8, @intCast(c % 10));
        n += 1;
        c /= 10;
        if (c == 0) break;
    }
    const digits = digit_buf[digit_buf.len - n ..];
    const exponent: i64 = p.exponent;
    const adjusted = exponent + @as(i64, @intCast(n)) - 1;

    if (exponent > 0 or adjusted < -6) {
        // Scientific: d[.ddd]E±n.
        try w.writeByte(digits[0]);
        if (n > 1) {
            try w.writeByte('.');
            try w.writeAll(digits[1..]);
        }
        try w.print("E{c}{d}", .{ @as(u8, if (adjusted < 0) '-' else '+'), @abs(adjusted) });
    } else if (exponent == 0) {
        try w.writeAll(digits);
    } else {
        // Plain, with -exponent digits after the point.
        const after: usize = @intCast(-exponent);
        if (n > after) {
            try w.writeAll(digits[0 .. n - after]);
            try w.writeByte('.');
            try w.writeAll(digits[n - after ..]);
        } else {
            try w.writeAll("0.");
            try w.splatByteAll('0', after - n);
            try w.writeAll(digits);
        }
    }
}

const testing = std.testing;

fn roundTrip(in: []const u8, out: []const u8) !void {
    var buf: [max_string_len]u8 = undefined;
    try testing.expectEqualStrings(out, (try parse(in)).toString(&buf));
}

test "parse and print" {
    try roundTrip("0", "0");
    try roundTrip("-0", "-0");
    try roundTrip("12.70", "12.70");
    try roundTrip("+0.003", "0.003");
    try roundTrip("017.", "17");
    try roundTrip(".5", "0.5");
    try roundTrip("4E+9", "4E+9");
    try roundTrip("0.73e-7", "7.3E-8");
    try roundTrip("-Inf", "-Infinity");
    try roundTrip("nan", "NaN");
    try roundTrip("1E6112", "1.0E+6112");
    try roundTrip("0E+2147483647", "0E+6111");
    try roundTrip("1.1111111111111111111111111111123450", "1.111111111111111111111111111112345");
    try testing.expectError(error.Inexact, parse("1.11111111111111111111111111111234549"));
    try testing.expectError(error.Inexact, parse("1E-6177"));
    try testing.expectError(error.Overflow, parse("7e10000"));
    try testing.expectError(error.InvalidDecimal, parse("1e"));
    try testing.expectError(error.InvalidDecimal, parse("."));
    try testing.expectError(error.InvalidDecimal, parse("1..3"));
    try testing.expectError(error.InvalidDecimal, parse("0sNaN"));
}

test "fromInt" {
    var buf: [max_string_len]u8 = undefined;
    try testing.expectEqualStrings("-42", fromInt(-42).toString(&buf));
    try testing.expectEqualStrings("-9223372036854775808", fromInt(std.math.minInt(i64)).toString(&buf));
}
