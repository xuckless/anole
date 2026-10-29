// Copied from vkiryakov/zefir src/validator/strings.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! String rules: the length of a string in code points (`minLength`,
//! `maxLength`, `length`) or in bytes (`minBytes`, `maxBytes`); `utf8` and
//! `notBlank`; the ASCII classes (`ascii`, `printableAscii`, `alphanumeric`,
//! `alpha`, `digits`, `lowercase`, `uppercase`) and `multibyte`; the widths
//! of validator.js (`fullWidth`, `halfWidth`, `variableWidth`); substrings
//! (`contains`, `notContains`); and `strongPassword`. A string is a slice of
//! u8 (`core.isString`).
//!
//! The rules that read code points (`minLength`, `maxLength`, `length`,
//! `notBlank`, the width rules and `strongPassword`) validate the whole value
//! first and fail invalid UTF-8 with the precondition `validation.utf8` /
//! "must be valid UTF-8"; the others read bytes and never decode. Every rule
//! without a parameter, and `strongPassword`, has a public predicate
//! `is<Name>` that answers what the rule does, with `false` for invalid UTF-8
//! where the rule reports the precondition.
const std = @import("std");
const core = @import("core.zig");
const schema = @import("schema.zig");
const Rule = core.Rule;
const Outcome = core.Outcome;

// ------------------------------------------------------------------ field types

/// The field-type check of `minLength`, `maxLength` and `length`.
fn lengthFits(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void {
    if (lengthProblem(rule, T, where)) |text| @compileError(text);
}

/// The declaration error of `minLength`, `maxLength` or `length` on the
/// unwrapped field type `T`, or null: on a slice of other items the hint
/// names the list rules with the same counts (an array has a fixed length, so
/// it gets none).
fn lengthProblem(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) ?[]const u8 {
    return core.stringProblem(rule, T, where, if (core.isListSlice(T)) core.hints.itemCount(rule.*) else null);
}

/// The field-type check of `digits`.
fn digitsFits(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void {
    if (digitsProblem(rule, T, where)) |text| @compileError(text);
}

/// The declaration error of `digits` on the unwrapped field type `T`, or
/// null: a number field is already a number.
fn digitsProblem(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) ?[]const u8 {
    return core.stringProblem(rule, T, where, if (core.isNumber(T)) core.hints.already_a_number else null);
}

/// The field-type check of `contains` and `notContains`.
fn seedFits(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void {
    if (seedProblem(rule, T, where)) |text| @compileError(text);
}

/// The declaration error of `contains` or `notContains` on the unwrapped
/// field type `T`, or null. On a list of strings the hint offers the search
/// inside each item or the list rule for whole items; on a list of other
/// items, the list rule alone. `[N]u8` gets the core's hint.
fn seedProblem(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) ?[]const u8 {
    if (core.isString(T)) return null;
    if (!core.isU8Array(T)) {
        if (core.ListChild(T)) |Item| {
            const hint = if (core.isString(core.Unwrap(Item)))
                core.hints.searchItems(rule.*)
            else if (rule.kind == .contains) core.hints.require_items else core.hints.forbid_items;
            // Nothing is accepted, so the core keeps this hint.
            return core.typeErrorText(rule, T, where, "a string", rejectsAll, hint);
        }
    }
    return core.typeErrorText(rule, T, where, "a string", core.isString, null);
}

fn rejectsAll(comptime _: type) bool {
    return false;
}

// ------------------------------------------------------------------ minLength, maxLength, length

/// At least `min` code points (Unicode scalar values); `min` is at least 1.
/// Every code point counts as one character, with no trimming, no Unicode
/// normalization and no grapheme clusters: `"e\u{301}"` and
/// `"\u{2764}\u{FE0F}"` are 2 characters. Invalid UTF-8 fails with the
/// precondition `validation.utf8`, checked first even when the number of
/// bytes alone would decide. Its placeholder is `{min}`.
pub fn minLength(comptime min: usize) Rule {
    @setEvalBranchQuota(core.eval_quota);
    if (boundCallProblem(.min_length, min)) |text| @compileError(text);
    return codePointRule(.min_length, min, null, core.renderArg(min), "must be at least " ++ core.plural(min, "character", "characters"), &.{core.param("min", min)});
}

/// At most `max` code points, counted as `minLength` counts them; `max` is
/// at least 1 (for no characters use `v.empty`). Invalid UTF-8 fails with the
/// precondition `validation.utf8`. Its placeholder is `{max}`.
pub fn maxLength(comptime max: usize) Rule {
    @setEvalBranchQuota(core.eval_quota);
    if (boundCallProblem(.max_length, max)) |text| @compileError(text);
    return codePointRule(.max_length, null, max, core.renderArg(max), "must be at most " ++ core.plural(max, "character", "characters"), &.{core.param("max", max)});
}

/// From `min` to `max` code points, counted as `minLength` counts them;
/// `1 <= min <= max`, and equal bounds ask for an exact length ("must be
/// exactly 5 characters"). Invalid UTF-8 fails with the precondition
/// `validation.utf8`. Its placeholders are `{min}` and `{max}`.
pub fn length(comptime min: usize, comptime max: usize) Rule {
    @setEvalBranchQuota(core.eval_quota);
    if (lengthCallProblem(min, max)) |text| @compileError(text);
    const message = if (min == max)
        "must be exactly " ++ core.plural(min, "character", "characters")
    else
        "must be from " ++ core.renderValue(min) ++ " to " ++ core.renderValue(max) ++ " characters";
    return codePointRule(.length, min, max, core.renderArg(min) ++ ", " ++ core.renderArg(max), message, &.{ core.param("min", min), core.param("max", max) });
}

/// The error of the call `minLength(n)`, `maxLength(n)`, `minBytes(n)` or
/// `maxBytes(n)`, or null: the count is at least 1.
fn boundCallProblem(comptime kind: core.Kind, comptime n: usize) ?[]const u8 {
    if (n != 0) return null;
    return switch (kind) {
        .min_length => "validator: minLength(0): min must be at least 1 (minLength(0) is always true; " ++ core.hints.use_utf8 ++ ")",
        .max_length => "validator: maxLength(0): max must be at least 1; " ++ core.hints.use_empty,
        .min_bytes => "validator: minBytes(0): min must be at least 1 (minBytes(0) is always true; remove it)",
        .max_bytes => "validator: maxBytes(0): max must be at least 1; " ++ core.hints.use_empty,
        else => @compileError("validator: internal: " ++ @tagName(kind) ++ " is not a string bound rule"),
    };
}

/// The error of the call `length(min, max)`, or null: `1 <= min <= max`.
fn lengthCallProblem(comptime min: usize, comptime max: usize) ?[]const u8 {
    if (min != 0 and min <= max) return null;
    const head = "validator: length(" ++ core.renderArg(min) ++ ", " ++ core.renderArg(max) ++ "): ";
    if (min == 0) return head ++ "min must be at least 1; " ++ if (max == 0) core.hints.use_empty else core.hints.useMaxLength(max);
    return head ++ "min is greater than max";
}

/// A rule of `kind` that keeps strings of `lo` to `hi` code points; null
/// stands for no bound on that side.
fn codePointRule(comptime kind: core.Kind, comptime lo: ?usize, comptime hi: ?usize, comptime args: []const u8, comptime message: []const u8, comptime params: []const core.Param) Rule {
    const lower: []const core.Bound = if (lo) |n| &.{.atLeast(.code_points, n)} else &.{};
    const upper: []const core.Bound = if (hi) |n| &.{.atMost(.code_points, n)} else &.{};
    return core.define(kind, .{
        .message = message,
        .args = args,
        .params = params,
        .precondition = core.preconditions.utf8,
        .bounds = lower ++ upper,
        .fits = lengthFits,
        .eval = struct {
            fn eval(value: anytype) Outcome {
                // It validates while it counts and fails exactly on the
                // inputs that utf8ValidateSlice rejects.
                const count = std.unicode.utf8CountCodepoints(value.*) catch return .precondition;
                if (comptime lo) |bound| {
                    if (count < bound) return .fail;
                }
                if (comptime hi) |bound| {
                    if (count > bound) return .fail;
                }
                return .pass;
            }
        }.eval,
    });
}

// ------------------------------------------------------------------ minBytes, maxBytes

/// At least `min` bytes: the length of the slice, without decoding, so an
/// invalid byte counts as one; `min` is at least 1. Its placeholder is
/// `{min}`.
pub fn minBytes(comptime min: usize) Rule {
    @setEvalBranchQuota(core.eval_quota);
    if (boundCallProblem(.min_bytes, min)) |text| @compileError(text);
    return byteRule(.min_bytes, min, "must be at least " ++ core.plural(min, "byte", "bytes"), "min");
}

/// At most `max` bytes, without decoding; `max` is at least 1 (for no bytes
/// use `v.empty`). Put first in a tuple, it rejects a long value before rules
/// that read the whole string. Its placeholder is `{max}`.
pub fn maxBytes(comptime max: usize) Rule {
    @setEvalBranchQuota(core.eval_quota);
    if (boundCallProblem(.max_bytes, max)) |text| @compileError(text);
    return byteRule(.max_bytes, max, "must be at most " ++ core.plural(max, "byte", "bytes"), "max");
}

/// `minBytes(n)` or `maxBytes(n)`, whose count is the placeholder `name`.
fn byteRule(comptime kind: core.Kind, comptime n: usize, comptime message: []const u8, comptime name: []const u8) Rule {
    return core.define(kind, .{
        .message = message,
        .args = core.renderArg(n),
        .params = &.{core.param(name, n)},
        .bounds = &.{if (kind == .min_bytes) .atLeast(.bytes, n) else .atMost(.bytes, n)},
        .fits = core.fitsString,
        .eval = struct {
            fn eval(value: anytype) Outcome {
                return core.passIf(if (kind == .min_bytes) value.*.len >= n else value.*.len <= n);
            }
        }.eval,
    });
}

// ------------------------------------------------------------------ utf8, notBlank

/// Well-formed UTF-8 (RFC 3629), as `std.unicode.utf8ValidateSlice` checks
/// it: C0, C1 and F5-FF, stray continuation bytes, truncated and overlong
/// sequences, surrogates and code points above U+10FFFF fail; "" passes.
pub fn isUtf8(s: []const u8) bool {
    return std.unicode.utf8ValidateSlice(s);
}

/// Valid UTF-8. Its failure is its own check with the code of the
/// precondition, so its `.withMessage` applies: put it first in a tuple to
/// word the case for the rules that report the precondition,
/// `.{ v.utf8.withMessage("..."), v.maxLength(64) }`.
pub const utf8: Rule = core.predicateRule(.utf8, "must be valid UTF-8", isUtf8);

/// Unicode White_Space (PropList.txt): 25 code points. The trims of
/// transforms.zig strip these too.
pub fn isWhiteSpace(cp: u21) bool {
    return switch (cp) {
        0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

/// `s`, which must be valid UTF-8, has a code point outside White_Space.
fn hasContent(s: []const u8) bool {
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| {
        if (!isWhiteSpace(cp)) return true;
    }
    return false;
}

/// Valid UTF-8 with at least one code point outside Unicode White_Space.
/// Format characters and fillers such as U+200B, U+FEFF, U+2060 and U+3164
/// are content. False on invalid UTF-8, on "" and on White_Space alone.
pub fn isNotBlank(s: []const u8) bool {
    return std.unicode.utf8ValidateSlice(s) and hasContent(s);
}

/// At least one code point outside Unicode White_Space (25 code points:
/// TAB to CR, space, U+0085, U+00A0, U+1680, U+2000-200A, U+2028, U+2029,
/// U+202F, U+205F, U+3000). The whole value is validated before the scan:
/// invalid UTF-8 anywhere fails with the precondition `validation.utf8`.
pub const notBlank: Rule = core.define(.not_blank, .{
    .message = "must not be blank",
    .precondition = core.preconditions.utf8,
    .fits = core.fitsString,
    .eval = struct {
        fn eval(value: anytype) Outcome {
            if (!std.unicode.utf8ValidateSlice(value.*)) return .precondition;
            return core.passIf(hasContent(value.*));
        }
    }.eval,
});

// ------------------------------------------------------------------ ASCII classes, multibyte

/// Every byte is at most 0x7F; control bytes, NUL and DEL included.
pub fn isAscii(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isAscii(c)) return false;
    }
    return true;
}

/// Every byte is printable ASCII, 0x20-0x7E: TAB, LF, CR, other control
/// bytes and DEL fail.
pub fn isPrintableAscii(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isPrint(c)) return false;
    }
    return true;
}

/// Every byte is an ASCII letter or digit: `0-9`, `A-Z`, `a-z`.
pub fn isAlphanumeric(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c)) return false;
    }
    return true;
}

/// Every byte is an ASCII letter: `A-Z`, `a-z`.
pub fn isAlpha(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isAlphabetic(c)) return false;
    }
    return true;
}

/// Every byte is an ASCII digit `0-9`: no sign, point, exponent or
/// separator; leading zeros stay.
pub fn isDigits(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// No byte is an uppercase ASCII letter `A-Z`; other bytes are not
/// inspected, so `"Émile"` passes.
pub fn isLowercase(s: []const u8) bool {
    for (s) |c| {
        if (std.ascii.isUpper(c)) return false;
    }
    return true;
}

/// No byte is a lowercase ASCII letter `a-z`; other bytes are not
/// inspected, so `"STRAßE"` passes.
pub fn isUppercase(s: []const u8) bool {
    for (s) |c| {
        if (std.ascii.isLower(c)) return false;
    }
    return true;
}

/// At least one byte is 0x80 or above, invalid UTF-8 included: the opposite
/// of `isAscii` on every input.
pub fn isMultibyte(s: []const u8) bool {
    return !isAscii(s);
}

/// Only ASCII: a byte of 0x80 or above fails, valid UTF-8 or not; "" passes.
pub const ascii: Rule = core.predicateRule(.ascii, "must contain only ASCII characters", isAscii);
/// Only printable ASCII (0x20-0x7E): also TAB, LF and CR fail; "" passes.
pub const printableAscii: Rule = core.predicateRule(.printable_ascii, "must contain only printable ASCII characters", isPrintableAscii);
/// Only ASCII letters and digits (en-US): `_`, `-`, a space and letters or
/// digits outside ASCII fail; "" passes.
pub const alphanumeric: Rule = core.predicateRule(.alphanumeric, "must contain only ASCII letters and digits", isAlphanumeric);
/// Only ASCII letters (en-US); "" passes.
pub const alpha: Rule = core.predicateRule(.alpha, "must contain only ASCII letters", isAlpha);
/// Only ASCII digits: a code or a PIN, not a number (its size is not
/// bounded; leading zeros stay); "" passes. On a number field it is a
/// compile error: the field is already a number.
pub const digits: Rule = core.predicateRuleFits(.digits, "must contain only ASCII digits", isDigits, digitsFits);
/// No ASCII uppercase letter; letters outside ASCII are not inspected (the
/// standard library has no case tables); "" passes.
pub const lowercase: Rule = core.predicateRule(.lowercase, "must be lowercase", isLowercase);
/// No ASCII lowercase letter; letters outside ASCII are not inspected; ""
/// passes.
pub const uppercase: Rule = core.predicateRule(.uppercase, "must be uppercase", isUppercase);
/// At least one byte of 0x80 or above, without decoding, so invalid UTF-8
/// passes; "" fails.
pub const multibyte: Rule = core.predicateRule(.multibyte, "must contain at least one non-ASCII character", isMultibyte);

// ------------------------------------------------------------------ fullWidth, halfWidth, variableWidth

/// The half-width class H of validator.js: printable ASCII U+0020-007E and
/// the half-width forms U+FF61-FFDC and U+FFE8-FFEE, 226 scalar values. It
/// is not Unicode East Asian Width: control characters, Latin-1, Cyrillic
/// and emoji are outside H, so the width rules count them as full-width.
fn isHalfWidthCodePoint(cp: u21) bool {
    return switch (cp) {
        0x20...0x7E, 0xFF61...0xFFDC, 0xFFE8...0xFFEE => true,
        else => false,
    };
}

/// Whether `s` has a code point outside H (when `full`) and one in H (when
/// `half`); null when `s` is not valid UTF-8. After the validation the scan
/// stops as soon as both are seen.
fn hasWidths(s: []const u8, comptime full: bool, comptime half: bool) ?bool {
    if (!std.unicode.utf8ValidateSlice(s)) return null;
    var seen_full = !full;
    var seen_half = !half;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| {
        if (isHalfWidthCodePoint(cp)) seen_half = true else seen_full = true;
        if (seen_full and seen_half) return true;
    }
    return false;
}

/// Valid UTF-8 with a code point outside the half-width class of
/// validator.js (see `v.fullWidth`).
pub fn isFullWidth(s: []const u8) bool {
    return hasWidths(s, true, false) orelse false;
}

/// Valid UTF-8 with a code point in the half-width class of validator.js:
/// printable ASCII or a half-width form.
pub fn isHalfWidth(s: []const u8) bool {
    return hasWidths(s, false, true) orelse false;
}

/// Valid UTF-8 with code points both in and outside the half-width class of
/// validator.js.
pub fn isVariableWidth(s: []const u8) bool {
    return hasWidths(s, true, true) orelse false;
}

/// At least one code point outside the half-width class of validator.js
/// (printable ASCII U+0020-007E, U+FF61-FFDC, U+FFE8-FFEE). Kept for parity
/// with validator.js, it is not Unicode East Asian Width: `"😀"`,
/// `"café"` and `"\n"` count as full-width. Invalid UTF-8 fails with the
/// precondition `validation.utf8`; "" fails.
pub const fullWidth: Rule = widthRule(.full_width, "must contain at least one full-width character", true, false);
/// At least one code point in the half-width class of validator.js (see
/// `fullWidth`). Invalid UTF-8 fails with the precondition; "" fails.
pub const halfWidth: Rule = widthRule(.half_width, "must contain at least one half-width character", false, true);
/// Code points both in and outside the half-width class of validator.js
/// (see `fullWidth`): `"abc\n"` and `"café"` pass. Invalid UTF-8 fails with
/// the precondition; "" fails.
pub const variableWidth: Rule = widthRule(.variable_width, "must contain both full-width and half-width characters", true, true);

fn widthRule(comptime kind: core.Kind, comptime message: []const u8, comptime full: bool, comptime half: bool) Rule {
    return core.define(kind, .{
        .message = message,
        .precondition = core.preconditions.utf8,
        .fits = core.fitsString,
        .eval = struct {
            fn eval(value: anytype) Outcome {
                const found = hasWidths(value.*, full, half) orelse return .precondition;
                return core.passIf(found);
            }
        }.eval,
    });
}

// ------------------------------------------------------------------ contains, notContains

/// `seed` occurs in the value as a contiguous run of bytes: case-sensitive,
/// without decoding, case folding or Unicode normalization (`"\u{FF21}"` is
/// not `"A"`). `seed` is a non-empty valid UTF-8 string of any length; the
/// search takes linear time whatever its length. The message shows the seed
/// escaped, or "must contain the required text" when that would be longer
/// than 512 bytes. Its placeholder is `{seed}`, without the quotes.
pub fn contains(comptime seed: []const u8) Rule {
    return seedRule(.contains, seed);
}

/// `seed` does not occur in the value as a contiguous run of bytes; the
/// seed and the search are those of `contains`, and "" passes. An overlong
/// encoding is not the character it would decode to: `"x\xc0\xafy"` passes
/// `notContains("/")`, so put `v.utf8` first when a lenient decoder reads
/// the value later. The fallback message is "must not contain the forbidden
/// text".
pub fn notContains(comptime seed: []const u8) Rule {
    return seedRule(.not_contains, seed);
}

/// The error of the call `contains(seed)` or `notContains(seed)`, or null:
/// the seed is non-empty valid UTF-8.
fn seedCallProblem(comptime kind: core.Kind, comptime seed: []const u8) ?[]const u8 {
    @setEvalBranchQuota(core.eval_quota);
    if (seed.len != 0 and std.unicode.utf8ValidateSlice(seed)) return null;
    const head = "validator: " ++ core.info(kind).name ++ "(" ++ core.renderArg(seed) ++ "): ";
    if (seed.len == 0) return head ++ "an empty seed is " ++ (if (kind == .contains) "vacuous" else "unsatisfiable") ++ ": every string contains \"\"";
    return head ++ "the seed must be valid UTF-8";
}

fn seedRule(comptime kind: core.Kind, comptime seed: []const u8) Rule {
    @setEvalBranchQuota(core.eval_quota);
    if (seedCallProblem(kind, seed)) |text| @compileError(text);
    const found = kind == .contains;
    return core.define(kind, .{
        .message = (if (found) "must contain \"" else "must not contain \"") ++ core.renderValue(seed) ++ "\"",
        .fallback = if (found) "must contain the required text" else "must not contain the forbidden text",
        .args = core.renderArg(seed),
        .params = &.{core.param("seed", seed)},
        .fits = seedFits,
        .eval = struct {
            fn eval(value: anytype) Outcome {
                return core.passIf(occurs(seed, value.*) == found);
            }
        }.eval,
    });
}

/// `needle` occurs in `haystack`, in O(n) for any needle. A needle of 1-4
/// bytes takes `std.mem.find`, linear for such needles; a longer one the
/// Knuth-Morris-Pratt scan over a failure table that the compiler builds,
/// since `std.mem.find` turns to Boyer-Moore-Horspool there, which is
/// O(n·m) on periodic input. The table is read-only data: the needle's m
/// bytes and m integers of the smallest type that holds m.
fn occurs(comptime needle: []const u8, haystack: []const u8) bool {
    if (comptime needle.len <= 4) return std.mem.find(u8, haystack, needle) != null;
    const Index = std.math.IntFittingRange(0, needle.len);
    const table = struct {
        const bytes: [needle.len]u8 = needle[0..needle.len].*;
        const failure: [needle.len]Index = kmpTable(Index, needle);
    };
    // The length of the needle's prefix that ends here; below needle.len at
    // the top of every iteration.
    var matched: Index = 0;
    for (haystack) |c| {
        while (matched > 0 and c != table.bytes[matched]) matched = table.failure[matched - 1];
        if (c == table.bytes[matched]) {
            matched += 1;
            if (matched == needle.len) return true;
        }
    }
    return false;
}

/// `failure[i]` is the length of the longest proper prefix of
/// `needle[0..i + 1]` that is also its suffix.
fn kmpTable(comptime Index: type, comptime needle: []const u8) [needle.len]Index {
    @setEvalBranchQuota(core.eval_quota);
    var failure: [needle.len]Index = undefined;
    failure[0] = 0;
    var k: Index = 0;
    for (1..needle.len) |i| {
        while (k > 0 and needle[i] != needle[k]) k = failure[k - 1];
        if (needle[i] == needle[k]) k += 1;
        failure[i] = k;
    }
    return failure;
}

// ------------------------------------------------------------------ strongPassword

/// The options of `v.strongPassword` and `v.isStrongPassword`, with the
/// defaults of validator.js. `min_length` counts code points; the other
/// minima count occurrences, not distinct characters, of ASCII lowercase
/// letters, ASCII uppercase letters, ASCII digits and symbols: a space, the
/// 32 ASCII punctuation characters and `£` (34 in all). Any other code point
/// (TAB, NBSP, `€`, `é`, an emoji) counts toward the length only.
pub const StrongPasswordOptions = struct {
    min_length: usize = 8,
    min_lowercase: usize = 1,
    min_uppercase: usize = 1,
    min_numbers: usize = 1,
    min_symbols: usize = 1,
};

/// What a password has: its code points and the four classes.
const PasswordCounts = struct {
    length: usize = 0,
    lower: usize = 0,
    upper: usize = 0,
    numbers: usize = 0,
    symbols: usize = 0,

    fn meets(counts: PasswordCounts, options: StrongPasswordOptions) bool {
        return counts.length >= options.min_length and counts.lower >= options.min_lowercase and
            counts.upper >= options.min_uppercase and counts.numbers >= options.min_numbers and
            counts.symbols >= options.min_symbols;
    }
};

/// The symbols of validator.js: U+0020-002F, U+003A-0040, U+005B-0060,
/// U+007B-007E and U+00A3 (`£`), 34 code points.
fn isPasswordSymbol(cp: u21) bool {
    return switch (cp) {
        0x20...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E, 0xA3 => true,
        else => false,
    };
}

/// The counts of `s`, or null when it is not valid UTF-8.
fn countPassword(s: []const u8) ?PasswordCounts {
    if (!std.unicode.utf8ValidateSlice(s)) return null;
    var counts: PasswordCounts = .{};
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| {
        counts.length += 1;
        switch (cp) {
            'a'...'z' => counts.lower += 1,
            'A'...'Z' => counts.upper += 1,
            '0'...'9' => counts.numbers += 1,
            else => {
                if (isPasswordSymbol(cp)) counts.symbols += 1;
            },
        }
    }
    return counts;
}

/// Valid UTF-8 that meets every minimum of `options`. The options may be
/// run-time values and are not checked: with every minimum 0 any valid
/// UTF-8 string passes, "" included, although the rule rejects such options
/// at compile time. False on invalid UTF-8.
pub fn isStrongPassword(s: []const u8, options: StrongPasswordOptions) bool {
    const counts = countPassword(s) orelse return false;
    return counts.meets(options);
}

/// At least `options.min_length` code points and at least the minimum of
/// each class (`StrongPasswordOptions`); `.{}` takes the defaults of
/// validator.js. Not every minimum may be 0, and `min_length` is at least
/// the sum of the four class minima. Invalid UTF-8 fails with the
/// precondition `validation.utf8`; "" fails. The message names the minima
/// that are not 0, and its placeholders are the five option names, all of
/// them available also when 0. Compile errors show the call as
/// `strongPassword(.{...})`.
pub fn strongPassword(comptime options: StrongPasswordOptions) Rule {
    @setEvalBranchQuota(core.eval_quota);
    if (passwordCallProblem(options)) |text| @compileError(text);
    return core.define(.strong_password, .{
        .message = passwordMessage(options),
        .args = ".{...}",
        .params = &.{
            core.param("min_length", options.min_length),
            core.param("min_lowercase", options.min_lowercase),
            core.param("min_uppercase", options.min_uppercase),
            core.param("min_numbers", options.min_numbers),
            core.param("min_symbols", options.min_symbols),
        },
        .precondition = core.preconditions.utf8,
        // `min_length` is a lower bound on code points, the measure of
        // `maxLength` and `length`.
        .bounds = &.{.atLeast(.code_points, options.min_length)},
        .fits = core.fitsString,
        .eval = struct {
            fn eval(value: anytype) Outcome {
                const counts = countPassword(value.*) orelse return .precondition;
                return core.passIf(counts.meets(options));
            }
        }.eval,
    });
}

/// The error of the call `strongPassword(options)`, or null: not every
/// minimum is 0, and `min_length` is at least the sum of the class minima,
/// so that some string passes. When that sum is more than any usize, no
/// `min_length` can be set, and the error asks to lower the minima instead.
fn passwordCallProblem(comptime options: StrongPasswordOptions) ?[]const u8 {
    const head = "validator: strongPassword(.{...}): ";
    // In comptime_int, so that huge minima cannot overflow the sum.
    const sum = @as(comptime_int, options.min_lowercase) + @as(comptime_int, options.min_uppercase) +
        @as(comptime_int, options.min_numbers) + @as(comptime_int, options.min_symbols);
    if (options.min_length == 0 and sum == 0) return head ++ "every minimum is 0, so every string passes; set at least one minimum";
    if (options.min_length < sum) {
        const problem = std.fmt.comptimePrint("min_length = {d} is less than the {s} the other minima already require; ", .{ options.min_length, core.plural(sum, "character", "characters") });
        const max = std.math.maxInt(usize);
        if (sum > max) return head ++ problem ++ std.fmt.comptimePrint("no min_length can satisfy them, since a usize holds at most {d}: lower the other minima", .{max});
        return head ++ problem ++ std.fmt.comptimePrint("set min_length to at least {d}", .{sum});
    }
    return null;
}

/// "must be at least 8 characters and contain at least 1 lowercase letter,
/// 1 uppercase letter, 1 digit and 1 symbol": a class whose minimum is 0 is
/// left out, the parts are joined by ", " with " and " before the last, and
/// a noun is singular for 1.
fn passwordMessage(comptime options: StrongPasswordOptions) []const u8 {
    var parts: []const []const u8 = &.{};
    if (options.min_lowercase > 0) parts = parts ++ &[_][]const u8{core.plural(options.min_lowercase, "lowercase letter", "lowercase letters")};
    if (options.min_uppercase > 0) parts = parts ++ &[_][]const u8{core.plural(options.min_uppercase, "uppercase letter", "uppercase letters")};
    if (options.min_numbers > 0) parts = parts ++ &[_][]const u8{core.plural(options.min_numbers, "digit", "digits")};
    if (options.min_symbols > 0) parts = parts ++ &[_][]const u8{core.plural(options.min_symbols, "symbol", "symbols")};
    var out: []const u8 = "must be at least " ++ core.plural(options.min_length, "character", "characters");
    for (parts, 0..) |part, i| {
        out = out ++ (if (i == 0) " and contain at least " else if (i == parts.len - 1) " and " else ", ") ++ part;
    }
    return out;
}

// ------------------------------------------------------------------ schema

/// Unicode White_Space as `isWhiteSpace` lists it, the inside of a
/// character class.
const white_space_class = "\t\n\x0b\x0c\r \u{85}\u{a0}\u{1680}\u{2000}-\u{200a}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}";

/// The half-width class H of `isHalfWidthCodePoint`, the inside of a
/// character class.
const half_width_class = " -~\u{ff61}-\u{ffdc}\u{ffe8}-\u{ffee}";

/// A code point outside H: what `fullWidth` looks for.
const full_width_pattern = "[^" ++ half_width_class ++ "]";

/// A code point in H: what `halfWidth` looks for.
const half_width_pattern = "[" ++ half_width_class ++ "]";

/// The classes of `strongPassword` and the inside of a character class for
/// each, in the order of its options: the symbols are U+0020-002F,
/// U+003A-0040, U+005B-0060, U+007B-007E and U+00A3, as `isPasswordSymbol`
/// has them.
const password_classes = [_][]const u8{ "a-z", "A-Z", "0-9", " -/:-@\\[-`{-~\u{a3}" };

/// The JSON Schema keywords of a rule of this file on the unwrapped field
/// type `T`, for `v.schemaOf`. JSON Schema counts code points, as the length
/// rules do; bytes it cannot count, so `minBytes` and `maxBytes` are
/// approximate. The other rules are patterns, exact on the valid UTF-8 that
/// a JSON string is.
pub fn schemaOf(comptime rule: Rule, comptime T: type) schema.RuleSchema {
    _ = T;
    return switch (rule.kind) {
        .min_length => schema.exact(&.{schema.count("minLength", rule.params[0].value.int)}),
        .max_length => schema.exact(&.{schema.count("maxLength", rule.params[0].value.int)}),
        .length => schema.exact(&.{ schema.count("minLength", rule.params[0].value.int), schema.count("maxLength", rule.params[1].value.int) }),
        // A code point takes 1 to 4 bytes.
        .min_bytes => schema.approximate(
            &.{schema.count("minLength", @divFloor(rule.params[0].value.int + 3, 4))},
            "at least " ++ core.plural(rule.params[0].value.int, "byte", "bytes") ++ " in UTF-8",
        ),
        .max_bytes => schema.approximate(
            &.{schema.count("maxLength", rule.params[0].value.int)},
            "at most " ++ core.plural(rule.params[0].value.int, "byte", "bytes") ++ " in UTF-8",
        ),
        // A JSON string is valid Unicode.
        .utf8 => schema.exact(&.{}),
        .not_blank => schema.exact(&.{schema.pattern("[^" ++ white_space_class ++ "]")}),
        .ascii => schema.exact(&.{schema.pattern("^[\x00-\x7f]*$")}),
        .printable_ascii => schema.exact(&.{schema.pattern("^[ -~]*$")}),
        .alphanumeric => schema.exact(&.{schema.pattern("^[0-9A-Za-z]*$")}),
        .alpha => schema.exact(&.{schema.pattern("^[A-Za-z]*$")}),
        .digits => schema.exact(&.{schema.pattern("^[0-9]*$")}),
        .lowercase => schema.exact(&.{schema.pattern("^[^A-Z]*$")}),
        .uppercase => schema.exact(&.{schema.pattern("^[^a-z]*$")}),
        .multibyte => schema.exact(&.{schema.pattern("[^\x00-\x7f]")}),
        .full_width => schema.exact(&.{schema.pattern(full_width_pattern)}),
        .half_width => schema.exact(&.{schema.pattern(half_width_pattern)}),
        .variable_width => schema.exact(&.{schema.allPatterns(&.{ full_width_pattern, half_width_pattern })}),
        .contains => schema.exact(&.{schema.pattern(schema.literal(rule.params[0].value.string))}),
        .not_contains => schema.exact(&.{schema.keyword("not", schema.stringPattern(schema.literal(rule.params[0].value.string)))}),
        .strong_password => passwordSchema(rule),
        else => unreachable,
    };
}

/// `strongPassword`: `minLength` for `min_length` and, for each class with a
/// minimum, a pattern that finds that many characters of the class. A
/// minimum above `schema.max_repeat` is written as that many, which RE2 still
/// reads: the schema is then approximate.
fn passwordSchema(comptime rule: Rule) schema.RuleSchema {
    var regexes: []const []const u8 = &.{};
    var capped = false;
    for (password_classes, rule.params[1..]) |class, minimum| {
        const n = minimum.value.int;
        if (n == 0) continue;
        if (n > schema.max_repeat) capped = true;
        const repeat = @min(n, schema.max_repeat);
        regexes = regexes ++ &[_][]const u8{"^(?:[^" ++ class ++ "]*[" ++ class ++ "])" ++ schema.repetition(repeat, repeat)};
    }
    const min_length = schema.count("minLength", rule.params[0].value.int);
    const keywords: []const schema.RuleSchema.Keyword = if (regexes.len == 0) &.{min_length} else &.{ min_length, schema.allPatterns(regexes) };
    if (capped) return schema.approximate(keywords, "every minimum of strongPassword, of which a pattern counts at most " ++ schema.integer(schema.max_repeat));
    return schema.exact(keywords);
}

/// The arguments the hints show for an uncalled constructor of this file:
/// `minLength must be called, e.g. v.minLength(1)`.
pub const call_examples = .{
    .minLength = "1",
    .maxLength = "100",
    .length = "1, 100",
    .minBytes = "1",
    .maxBytes = "100",
    .contains = "\"@\"",
    .notContains = "\" \"",
    .strongPassword = ".{}",
};

const expectOutcome = core.expectOutcome;

const test_where = "Dto.field_rules.x";

/// A struct for the tests below.
const Record = struct { id: u32 };

/// The declaration error of `rule` on a field of type `T`, or null.
fn fitsText(comptime rule: Rule, comptime T: type) ?[]const u8 {
    return switch (rule.kind) {
        .min_length, .max_length, .length => lengthProblem(&rule, T, test_where),
        .digits => digitsProblem(&rule, T, test_where),
        .contains, .not_contains => seedProblem(&rule, T, test_where),
        else => core.stringProblem(&rule, T, test_where, null),
    };
}

/// The error a rule constructor used without a call raises in `field_rules`.
fn uncalledText(comptime name: []const u8, comptime F: type) []const u8 {
    return "validator: " ++ test_where ++ ": " ++ core.hints.mustBeCalled(name, F);
}

test "the length rules have their documented codes, messages, parameters and the utf8 precondition" {
    const t = std.testing;
    const at_least = minLength(3);
    try t.expectEqual(core.Kind.min_length, at_least.kind);
    try t.expectEqualStrings("validation.min_length", at_least.code);
    try t.expectEqualStrings("must be at least 3 characters", at_least.message);
    try t.expectEqualStrings("3", at_least.args.?);
    try t.expectEqual(1, at_least.params.len);
    try t.expectEqualStrings("min", at_least.params[0].name);
    try t.expectEqualStrings("3", at_least.params[0].text);
    try t.expect(comptime at_least.params[0].value.int == 3);
    try t.expectEqualStrings("validation.utf8", at_least.precondition.?.code);
    try t.expectEqualStrings("must be valid UTF-8", at_least.precondition.?.message);
    try t.expectEqualStrings("minLength(3)", comptime at_least.call());
    try t.expectEqualStrings("min_length(3)", comptime at_least.label());

    const at_most = maxLength(64);
    try t.expectEqual(core.Kind.max_length, at_most.kind);
    try t.expectEqualStrings("validation.max_length", at_most.code);
    try t.expectEqualStrings("must be at most 64 characters", at_most.message);
    try t.expectEqualStrings("max", at_most.params[0].name);
    try t.expectEqualStrings("64", at_most.params[0].text);
    try t.expectEqualStrings("validation.utf8", at_most.precondition.?.code);

    const between = length(3, 32);
    try t.expectEqual(core.Kind.length, between.kind);
    try t.expectEqualStrings("validation.length", between.code);
    try t.expectEqualStrings("must be from 3 to 32 characters", between.message);
    try t.expectEqualStrings("3, 32", between.args.?);
    try t.expectEqual(2, between.params.len);
    try t.expectEqualStrings("min", between.params[0].name);
    try t.expectEqualStrings("max", between.params[1].name);
    try t.expectEqualStrings("32", between.params[1].text);
    try t.expectEqualStrings("validation.utf8", between.precondition.?.code);
    try t.expectEqualStrings("length(3, 32)", comptime between.call());

    // One character is singular; equal bounds ask for an exact length.
    try t.expectEqualStrings("must be at least 1 character", minLength(1).message);
    try t.expectEqualStrings("must be at most 1 character", maxLength(1).message);
    try t.expectEqualStrings("must be exactly 5 characters", length(5, 5).message);
    try t.expectEqualStrings("must be exactly 1 character", length(1, 1).message);
    try t.expectEqualStrings("must be from 1 to 2 characters", length(1, 2).message);
    // The largest count of the target: 18446744073709551615 on 64-bit ones.
    try t.expectEqualStrings(std.fmt.comptimePrint("must be at most {d} characters", .{std.math.maxInt(usize)}), maxLength(std.math.maxInt(usize)).message);
}

test "minBytes and maxBytes have their documented codes, messages and parameters and no precondition" {
    const t = std.testing;
    const at_least = minBytes(8);
    try t.expectEqual(core.Kind.min_bytes, at_least.kind);
    try t.expectEqualStrings("validation.min_bytes", at_least.code);
    try t.expectEqualStrings("must be at least 8 bytes", at_least.message);
    try t.expectEqualStrings("8", at_least.args.?);
    try t.expectEqualStrings("min", at_least.params[0].name);
    try t.expectEqual(null, at_least.precondition);
    try t.expectEqualStrings("min_bytes(8)", comptime at_least.label());

    const at_most = maxBytes(255);
    try t.expectEqual(core.Kind.max_bytes, at_most.kind);
    try t.expectEqualStrings("validation.max_bytes", at_most.code);
    try t.expectEqualStrings("must be at most 255 bytes", at_most.message);
    try t.expectEqualStrings("max", at_most.params[0].name);
    try t.expectEqualStrings("255", at_most.params[0].text);
    try t.expectEqual(null, at_most.precondition);

    try t.expectEqualStrings("must be at least 1 byte", minBytes(1).message);
    try t.expectEqualStrings("must be at most 1 byte", maxBytes(1).message);
}

test "the length and byte rules take a count of at least 1; length takes min <= max" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: minLength(0): min must be at least 1 (minLength(0) is always true; use v.utf8 to require valid UTF-8)", comptime boundCallProblem(.min_length, 0).?);
    try expect("validator: maxLength(0): max must be at least 1; use v.empty", comptime boundCallProblem(.max_length, 0).?);
    try expect("validator: minBytes(0): min must be at least 1 (minBytes(0) is always true; remove it)", comptime boundCallProblem(.min_bytes, 0).?);
    try expect("validator: maxBytes(0): max must be at least 1; use v.empty", comptime boundCallProblem(.max_bytes, 0).?);
    try expect("validator: length(0, 5): min must be at least 1; use v.maxLength(5)", comptime lengthCallProblem(0, 5).?);
    try expect("validator: length(0, 0): min must be at least 1; use v.empty", comptime lengthCallProblem(0, 0).?);
    try expect("validator: length(5, 3): min is greater than max", comptime lengthCallProblem(5, 3).?);
    inline for (.{ .min_length, .max_length, .min_bytes, .max_bytes }) |kind| {
        try std.testing.expectEqual(null, comptime boundCallProblem(kind, 1));
        try std.testing.expectEqual(null, comptime boundCallProblem(kind, std.math.maxInt(usize)));
    }
    try std.testing.expectEqual(null, comptime lengthCallProblem(1, 1));
    try std.testing.expectEqual(null, comptime lengthCallProblem(1, std.math.maxInt(usize)));
}

test "the length and byte rules take strings; [N]u8, lists of strings and odd slices get their hints" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: ";
    try expect(head ++ "min_bytes expects a string, field is u32", comptime fitsText(minBytes(8), u32).?);
    try expect(head ++ "max_length expects a string, field is [4]u8; [N]u8 is an array of numbers, not a string: use []const u8", comptime fitsText(maxLength(64), [4]u8).?);
    try expect(head ++ "max_bytes expects a string, field is []const []const u8; use v.each(v.maxBytes(255))", comptime fitsText(maxBytes(255), []const []const u8).?);
    try expect(head ++ "length expects a string, field is [2]?[]const u8; use v.each(v.length(1, 2))", comptime fitsText(length(1, 2), [2]?[]const u8).?);
    try expect(head ++ "min_bytes expects a string, field is []const u32", comptime fitsText(minBytes(8), []const u32).?);
    try expect(head ++ "min_length expects a string, field is []volatile u8; volatile, allowzero and under-aligned slices are neither strings nor lists", comptime fitsText(minLength(1), []volatile u8).?);
    inline for (.{ []const u8, []u8, [:0]const u8, [:0]u8, []align(4) const u8 }) |T| {
        inline for (.{ minLength(1), maxLength(1), length(1, 2), minBytes(1), maxBytes(1) }) |rule| {
            try std.testing.expectEqual(null, comptime fitsText(rule, T));
        }
    }
}

test "minLength, maxLength and length on a slice of other items name the list rules; an array gets no hint" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: ";
    try expect(head ++ "min_length expects a string, field is []const u32; for the number of items use v.minItems(3)", comptime fitsText(minLength(3), []const u32).?);
    try expect(head ++ "max_length expects a string, field is []const u32; for the number of items use v.maxItems(64)", comptime fitsText(maxLength(64), []const u32).?);
    try expect(head ++ "length expects a string, field is []const u32; for the number of items use v.minItems(3) and v.maxItems(32)", comptime fitsText(length(3, 32), []const u32).?);
    try expect(head ++ "min_length expects a string, field is []const ?u32; for the number of items use v.minItems(3)", comptime fitsText(minLength(3), []const ?u32).?);
    try expect(head ++ "max_length expects a string, field is []u32; for the number of items use v.maxItems(64)", comptime fitsText(maxLength(64), []u32).?);
    try expect(head ++ "length expects a string, field is []const f64; for the number of items use v.minItems(1) and v.maxItems(1)", comptime fitsText(length(1, 1), []const f64).?);
    try expect(head ++ "min_length expects a string, field is []const []const u8; use v.each(v.minLength(3))", comptime fitsText(minLength(3), []const []const u8).?);
    try expect(head ++ "length expects a string, field is [4]u8; [N]u8 is an array of numbers, not a string: use []const u8", comptime fitsText(length(3, 32), [4]u8).?);
    try expect(head ++ "max_length expects a string, field is [3]u32", comptime fitsText(maxLength(64), [3]u32).?);
    try expect(head ++ "min_length expects a string, field is u32", comptime fitsText(minLength(3), u32).?);
}

test "an uncalled length or byte rule gets an example call" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: Dto.field_rules.x: minLength must be called, e.g. v.minLength(1)", comptime uncalledText("minLength", @TypeOf(minLength)));
    try expect("validator: Dto.field_rules.x: maxLength must be called, e.g. v.maxLength(100)", comptime uncalledText("maxLength", @TypeOf(maxLength)));
    try expect("validator: Dto.field_rules.x: length must be called, e.g. v.length(1, 100)", comptime uncalledText("length", @TypeOf(length)));
    try expect("validator: Dto.field_rules.x: minBytes must be called, e.g. v.minBytes(1)", comptime uncalledText("minBytes", @TypeOf(minBytes)));
    try expect("validator: Dto.field_rules.x: maxBytes must be called, e.g. v.maxBytes(100)", comptime uncalledText("maxBytes", @TypeOf(maxBytes)));
}

test "the length rules count code points after the utf8 precondition" {
    try expectOutcome(.fail, minLength(2), @as([]const u8, "a"));
    try expectOutcome(.pass, minLength(2), @as([]const u8, "\u{E9}\u{E9}"));
    try expectOutcome(.fail, minLength(3), @as([]const u8, "\u{1F600}"));
    try expectOutcome(.pass, maxLength(1), @as([]const u8, "\u{1F600}"));
    try expectOutcome(.fail, maxLength(1), @as([]const u8, "e\u{301}"));
    try expectOutcome(.pass, maxLength(1), @as([]const u8, ""));
    try expectOutcome(.fail, minLength(1), @as([]const u8, ""));
    try expectOutcome(.pass, length(2, 2), @as([:0]const u8, "\u{2764}\u{FE0F}"));
    try expectOutcome(.precondition, minLength(3), @as([]const u8, "\xff"));
    try expectOutcome(.precondition, maxLength(100), @as([]const u8, "\xff"));
    try expectOutcome(.precondition, length(1, 5), @as([]const u8, "abc\xe6\x97"));
}

test "minBytes and maxBytes read the length of the slice and never decode" {
    try expectOutcome(.pass, minBytes(3), @as([]const u8, "\xed\xa0\x80"));
    try expectOutcome(.fail, minBytes(2), @as([]const u8, "\xff"));
    try expectOutcome(.pass, maxBytes(3), @as([]const u8, "\xff\xff\xff"));
    try expectOutcome(.fail, maxBytes(2), @as([]const u8, "\xff\xff\xff"));
    try expectOutcome(.fail, maxBytes(8), @as([]const u8, "日本語"));
    try expectOutcome(.pass, maxBytes(9), @as([]const u8, "日本語"));
}

test "the rules without parameters have their documented codes and messages; the decoding ones have the utf8 precondition" {
    const t = std.testing;
    const Case = struct { rule: Rule, kind: core.Kind, code: []const u8, message: []const u8, decodes: bool };
    const cases = [_]Case{
        .{ .rule = utf8, .kind = .utf8, .code = "validation.utf8", .message = "must be valid UTF-8", .decodes = false },
        .{ .rule = notBlank, .kind = .not_blank, .code = "validation.not_blank", .message = "must not be blank", .decodes = true },
        .{ .rule = ascii, .kind = .ascii, .code = "validation.ascii", .message = "must contain only ASCII characters", .decodes = false },
        .{ .rule = printableAscii, .kind = .printable_ascii, .code = "validation.printable_ascii", .message = "must contain only printable ASCII characters", .decodes = false },
        .{ .rule = alphanumeric, .kind = .alphanumeric, .code = "validation.alphanumeric", .message = "must contain only ASCII letters and digits", .decodes = false },
        .{ .rule = alpha, .kind = .alpha, .code = "validation.alpha", .message = "must contain only ASCII letters", .decodes = false },
        .{ .rule = digits, .kind = .digits, .code = "validation.digits", .message = "must contain only ASCII digits", .decodes = false },
        .{ .rule = lowercase, .kind = .lowercase, .code = "validation.lowercase", .message = "must be lowercase", .decodes = false },
        .{ .rule = uppercase, .kind = .uppercase, .code = "validation.uppercase", .message = "must be uppercase", .decodes = false },
        .{ .rule = multibyte, .kind = .multibyte, .code = "validation.multibyte", .message = "must contain at least one non-ASCII character", .decodes = false },
        .{ .rule = fullWidth, .kind = .full_width, .code = "validation.full_width", .message = "must contain at least one full-width character", .decodes = true },
        .{ .rule = halfWidth, .kind = .half_width, .code = "validation.half_width", .message = "must contain at least one half-width character", .decodes = true },
        .{ .rule = variableWidth, .kind = .variable_width, .code = "validation.variable_width", .message = "must contain both full-width and half-width characters", .decodes = true },
    };
    inline for (cases) |c| {
        try t.expectEqual(c.kind, c.rule.kind);
        try t.expectEqualStrings(c.code, c.rule.code);
        try t.expectEqualStrings(c.message, c.rule.message);
        try t.expectEqual(null, c.rule.args);
        try t.expectEqual(0, c.rule.params.len);
        if (c.decodes) {
            try t.expectEqualStrings("validation.utf8", c.rule.precondition.?.code);
        } else {
            try t.expectEqual(null, c.rule.precondition);
        }
    }
}

test "the rules without parameters take strings; [N]u8, lists of strings and odd slices get their hints" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: ";
    try expect(head ++ "ascii expects a string, field is u32", comptime fitsText(ascii, u32).?);
    try expect(head ++ "utf8 expects a string, field is bool", comptime fitsText(utf8, bool).?);
    try expect(head ++ "not_blank expects a string, field is [4]u8; [N]u8 is an array of numbers, not a string: use []const u8", comptime fitsText(notBlank, [4]u8).?);
    try expect(head ++ "full_width expects a string, field is [2:0]u8; [N]u8 is an array of numbers, not a string: use []const u8", comptime fitsText(fullWidth, [2:0]u8).?);
    try expect(head ++ "lowercase expects a string, field is []const []const u8; use v.each(v.lowercase)", comptime fitsText(lowercase, []const []const u8).?);
    try expect(head ++ "multibyte expects a string, field is [2]?[]const u8; use v.each(v.multibyte)", comptime fitsText(multibyte, [2]?[]const u8).?);
    try expect(head ++ "alpha expects a string, field is []volatile u8; volatile, allowzero and under-aligned slices are neither strings nor lists", comptime fitsText(alpha, []volatile u8).?);
    try expect(head ++ "uppercase expects a string, field is strings.Record", comptime fitsText(uppercase, Record).?);
    inline for (.{ []const u8, []u8, [:0]const u8, [:0]u8, []align(4) const u8 }) |T| {
        inline for (.{ utf8, notBlank, ascii, printableAscii, alphanumeric, alpha, digits, lowercase, uppercase, multibyte, fullWidth, halfWidth, variableWidth }) |rule| {
            try std.testing.expectEqual(null, comptime fitsText(rule, T));
        }
    }
}

test "digits on a number field says the field is already a number" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: ";
    const number = "; the field is already a number: use v.min, v.max or v.range";
    try expect(head ++ "digits expects a string, field is u32" ++ number, comptime fitsText(digits, u32).?);
    try expect(head ++ "digits expects a string, field is i8" ++ number, comptime fitsText(digits, i8).?);
    try expect(head ++ "digits expects a string, field is f64" ++ number, comptime fitsText(digits, f64).?);
    try expect(head ++ "digits expects a string, field is f32" ++ number, comptime fitsText(digits, f32).?);
    try expect(head ++ "digits expects a string, field is f16" ++ number, comptime fitsText(digits, f16).?);
    try expect(head ++ "digits expects a string, field is bool", comptime fitsText(digits, bool).?);
    try expect(head ++ "digits expects a string, field is []const []const u8; use v.each(v.digits)", comptime fitsText(digits, []const []const u8).?);
    try expect(head ++ "digits expects a string, field is []const u32", comptime fitsText(digits, []const u32).?);
}

test "contains and notContains show the seed escaped and fall back to a general message past 512 bytes" {
    const t = std.testing;
    const at = contains("@");
    try t.expectEqual(core.Kind.contains, at.kind);
    try t.expectEqualStrings("validation.contains", at.code);
    try t.expectEqualStrings("must contain \"@\"", at.message);
    try t.expectEqualStrings("\"@\"", at.args.?);
    try t.expectEqualStrings("seed", at.params[0].name);
    try t.expectEqualStrings("@", at.params[0].text);
    try t.expectEqual(null, at.precondition);
    try t.expectEqualStrings("contains(\"@\")", comptime at.call());

    const no_space = notContains(" ");
    try t.expectEqual(core.Kind.not_contains, no_space.kind);
    try t.expectEqualStrings("validation.not_contains", no_space.code);
    try t.expectEqualStrings("must not contain \" \"", no_space.message);
    try t.expectEqualStrings("not_contains(\" \")", comptime no_space.label());
    try t.expectEqual(null, no_space.precondition);

    // Escaped as Zig string literals are; the quotes come from the message.
    try t.expectEqualStrings("must contain \"\\n\"", contains("\n").message);
    try t.expectEqualStrings("must contain \"say \\\"hi\\\"\"", contains("say \"hi\"").message);
    try t.expectEqualStrings("must not contain \"\\xe2\\x80\\xa8\"", notContains("\u{2028}").message);
    try t.expectEqualStrings("must not contain \"\u{E4}\"", notContains("\u{E4}").message);

    // 15 bytes and the escaped seed for contains, 19 for notContains.
    const fits_contains: [497]u8 = @splat('x');
    const over_contains: [498]u8 = @splat('x');
    try t.expectEqual(512, contains(&fits_contains).message.len);
    try t.expectEqualStrings("must contain the required text", contains(&over_contains).message);
    const newlines: [249]u8 = @splat('\n');
    try t.expectEqualStrings("must contain the required text", contains(&newlines).message);
    const fits_not: [493]u8 = @splat('y');
    const over_not: [494]u8 = @splat('y');
    try t.expectEqual(512, notContains(&fits_not).message.len);
    try t.expectEqualStrings("must not contain the forbidden text", notContains(&over_not).message);
    // The placeholder keeps the whole seed.
    try t.expectEqualStrings(&over_not, notContains(&over_not).params[0].text);
}

test "strongPassword names the minima that are not 0, singular for 1, and keeps all five as parameters" {
    const t = std.testing;
    const defaults = strongPassword(.{});
    try t.expectEqual(core.Kind.strong_password, defaults.kind);
    try t.expectEqualStrings("validation.strong_password", defaults.code);
    try t.expectEqualStrings("must be at least 8 characters and contain at least 1 lowercase letter, 1 uppercase letter, 1 digit and 1 symbol", defaults.message);
    try t.expectEqualStrings(".{...}", defaults.args.?);
    try t.expectEqualStrings("strongPassword(.{...})", comptime defaults.call());
    try t.expectEqualStrings("strong_password(.{...})", comptime defaults.label());
    try t.expectEqualStrings("validation.utf8", defaults.precondition.?.code);
    try t.expectEqual(5, defaults.params.len);
    inline for (.{ "min_length", "min_lowercase", "min_uppercase", "min_numbers", "min_symbols" }, .{ "8", "1", "1", "1", "1" }, 0..) |name, text, i| {
        try t.expectEqualStrings(name, defaults.params[i].name);
        try t.expectEqualStrings(text, defaults.params[i].text);
    }
    try t.expectEqualStrings("must be at least 12 characters", strongPassword(.{ .min_length = 12, .min_lowercase = 0, .min_uppercase = 0, .min_numbers = 0, .min_symbols = 0 }).message);
    try t.expectEqualStrings("must be at least 1 character", strongPassword(.{ .min_length = 1, .min_lowercase = 0, .min_uppercase = 0, .min_numbers = 0, .min_symbols = 0 }).message);
    try t.expectEqualStrings("must be at least 8 characters and contain at least 1 digit and 1 symbol", strongPassword(.{ .min_lowercase = 0, .min_uppercase = 0 }).message);
    try t.expectEqualStrings("must be at least 10 characters and contain at least 1 digit", strongPassword(.{ .min_length = 10, .min_lowercase = 0, .min_uppercase = 0, .min_symbols = 0 }).message);
    try t.expectEqualStrings("must be at least 8 characters and contain at least 1 lowercase letter, 1 uppercase letter and 1 symbol", strongPassword(.{ .min_numbers = 0 }).message);
    try t.expectEqualStrings(
        "must be at least 12 characters and contain at least 2 lowercase letters, 2 uppercase letters, 2 digits and 2 symbols",
        strongPassword(.{ .min_length = 12, .min_lowercase = 2, .min_uppercase = 2, .min_numbers = 2, .min_symbols = 2 }).message,
    );
    try t.expectEqualStrings("must be at least 4 characters and contain at least 4 digits", strongPassword(.{ .min_length = 4, .min_lowercase = 0, .min_uppercase = 0, .min_numbers = 4, .min_symbols = 0 }).message);
    // min_length may equal the sum of the class minima.
    try t.expectEqualStrings("must be at least 4 characters and contain at least 1 lowercase letter, 1 uppercase letter, 1 digit and 1 symbol", strongPassword(.{ .min_length = 4 }).message);
}

test "contains and notContains take a non-empty valid UTF-8 seed" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: contains(\"\"): an empty seed is vacuous: every string contains \"\"", comptime seedCallProblem(.contains, "").?);
    try expect("validator: notContains(\"\"): an empty seed is unsatisfiable: every string contains \"\"", comptime seedCallProblem(.not_contains, "").?);
    try expect("validator: contains(\"\\xff\"): the seed must be valid UTF-8", comptime seedCallProblem(.contains, "\xff").?);
    try expect("validator: notContains(\"\\xc0\\xaf\"): the seed must be valid UTF-8", comptime seedCallProblem(.not_contains, "\xc0\xaf").?);
    try std.testing.expectEqual(null, comptime seedCallProblem(.contains, "@"));
    try std.testing.expectEqual(null, comptime seedCallProblem(.not_contains, "\u{1F600}"));
}

test "strongPassword needs a minimum that is not 0 and a min_length that holds the class minima" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: strongPassword(.{...}): ";
    try expect(head ++ "every minimum is 0, so every string passes; set at least one minimum", comptime passwordCallProblem(.{ .min_length = 0, .min_lowercase = 0, .min_uppercase = 0, .min_numbers = 0, .min_symbols = 0 }).?);
    try expect(head ++ "min_length = 3 is less than the 4 characters the other minima already require; set min_length to at least 4", comptime passwordCallProblem(.{ .min_length = 3 }).?);
    try expect(head ++ "min_length = 0 is less than the 1 character the other minima already require; set min_length to at least 1", comptime passwordCallProblem(.{ .min_length = 0, .min_lowercase = 1, .min_uppercase = 0, .min_numbers = 0, .min_symbols = 0 }).?);
    const max = std.math.maxInt(usize);
    try expect(
        head ++ std.fmt.comptimePrint("min_length = {d} is less than the {d} characters the other minima already require; set min_length to at least {d}", .{ 8, max, max }),
        comptime passwordCallProblem(.{ .min_length = 8, .min_lowercase = max - 1, .min_uppercase = 1, .min_numbers = 0, .min_symbols = 0 }).?,
    );
    // Minima that add up to more than any usize: no min_length can hold them.
    try expect(
        head ++ std.fmt.comptimePrint("min_length = {d} is less than the {d} characters the other minima already require; no min_length can satisfy them, since a usize holds at most {d}: lower the other minima", .{ 8, @as(comptime_int, max) + 1, max }),
        comptime passwordCallProblem(.{ .min_length = 8, .min_lowercase = max, .min_uppercase = 1, .min_numbers = 0, .min_symbols = 0 }).?,
    );
    try expect(
        head ++ std.fmt.comptimePrint("min_length = {d} is less than the {d} characters the other minima already require; no min_length can satisfy them, since a usize holds at most {d}: lower the other minima", .{ max, 2 * @as(comptime_int, max) + 2, max }),
        comptime passwordCallProblem(.{ .min_length = max, .min_lowercase = max, .min_uppercase = max }).?,
    );
    try std.testing.expectEqual(null, comptime passwordCallProblem(.{}));
    try std.testing.expectEqual(null, comptime passwordCallProblem(.{ .min_length = 4 }));
    try std.testing.expectEqual(null, comptime passwordCallProblem(.{ .min_length = 1, .min_lowercase = 0, .min_uppercase = 0, .min_numbers = 0, .min_symbols = 0 }));
}

test "contains and notContains on a list point at the search inside each item or at the list rules" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: ";
    try expect(
        head ++ "contains expects a string, field is []const []const u8; use v.each(v.contains(\"@\")) to search inside each item, or v.containsAll(.{ ... }) to require whole items",
        comptime fitsText(contains("@"), []const []const u8).?,
    );
    try expect(
        head ++ "not_contains expects a string, field is [2][]const u8; use v.each(v.notContains(\" \")) to search inside each item, or v.containsNone(.{ ... }) to forbid whole items",
        comptime fitsText(notContains(" "), [2][]const u8).?,
    );
    try expect(head ++ "contains expects a string, field is []const u32; use v.containsAll(.{ ... }) to require list items", comptime fitsText(contains("1"), []const u32).?);
    try expect(head ++ "contains expects a string, field is [3]u32; use v.containsAll(.{ ... }) to require list items", comptime fitsText(contains("1"), [3]u32).?);
    try expect(head ++ "not_contains expects a string, field is []const strings.Record; use v.containsNone(.{ ... }) to forbid list items", comptime fitsText(notContains("a"), []const Record).?);
    try expect(head ++ "contains expects a string, field is [4]u8; [N]u8 is an array of numbers, not a string: use []const u8", comptime fitsText(contains("@"), [4]u8).?);
    try expect(head ++ "not_contains expects a string, field is u32", comptime fitsText(notContains("\n"), u32).?);
    try expect(head ++ "contains expects a string, field is []allowzero const u8; volatile, allowzero and under-aligned slices are neither strings nor lists", comptime fitsText(contains("@"), []allowzero const u8).?);
}

test "strongPassword takes strings; on a list of strings the each hint shows the options as .{...}" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: Dto.field_rules.x: strong_password expects a string, field is []const []const u8; use v.each(v.strongPassword(.{...}))", comptime fitsText(strongPassword(.{}), []const []const u8).?);
    try expect("validator: Dto.field_rules.x: strong_password expects a string, field is u32", comptime fitsText(strongPassword(.{}), u32).?);
    inline for (.{ []const u8, []u8, [:0]const u8, [:0]u8, []align(4) const u8 }) |T| {
        inline for (.{ contains("a"), notContains("a"), strongPassword(.{}) }) |rule| {
            try std.testing.expectEqual(null, comptime fitsText(rule, T));
        }
    }
}

test "an uncalled contains, notContains or strongPassword gets an example call" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: Dto.field_rules.x: contains must be called, e.g. v.contains(\"@\")", comptime uncalledText("contains", @TypeOf(contains)));
    try expect("validator: Dto.field_rules.x: notContains must be called, e.g. v.notContains(\" \")", comptime uncalledText("notContains", @TypeOf(notContains)));
    try expect("validator: Dto.field_rules.x: strongPassword must be called, e.g. v.strongPassword(.{})", comptime uncalledText("strongPassword", @TypeOf(strongPassword)));
}

test "contains finds seeds with repeated prefixes on both search paths" {
    // Seeds of 1-4 bytes take std.mem.find, longer ones the KMP table.
    try expectOutcome(.pass, contains("aaaab"), @as([]const u8, "aaaaaaaab"));
    try expectOutcome(.fail, contains("aaaab"), @as([]const u8, "aaabaaa"));
    try expectOutcome(.pass, contains("aabaab"), @as([]const u8, "aabaabaab"));
    try expectOutcome(.fail, contains("aabaab"), @as([]const u8, "aabaa"));
    try expectOutcome(.pass, contains("ab"), @as([]const u8, "xxab"));
    try expectOutcome(.fail, contains("ab"), @as([]const u8, "a\xffb"));
    try expectOutcome(.fail, contains("abcde"), @as([]const u8, ""));
    try expectOutcome(.fail, contains("a"), @as([]const u8, ""));
    try expectOutcome(.fail, notContains("aaaab"), @as([]const u8, "aaaaaaaab"));
    try expectOutcome(.pass, notContains("aaaab"), @as([]const u8, "aaabaaa"));
    try expectOutcome(.fail, notContains("aabaab"), @as([]const u8, "aabaabaab"));
    try expectOutcome(.pass, notContains("aabaab"), @as([]const u8, "aabaa"));
    try expectOutcome(.fail, notContains("ab"), @as([]const u8, "xxab"));
    try expectOutcome(.pass, notContains("ab"), @as([]const u8, "a\xffb"));
    try expectOutcome(.pass, notContains("abcde"), @as([]const u8, ""));
}

test "a strong password counts code points, ASCII letters and digits, and 34 symbols" {
    const t = std.testing;
    const password = "Ab1! \u{A3}\u{20AC}\t";
    const options: StrongPasswordOptions = .{ .min_length = 8, .min_lowercase = 1, .min_uppercase = 1, .min_numbers = 1, .min_symbols = 3 };
    try t.expect(isStrongPassword(password, options));
    var longer = options;
    longer.min_length = 9;
    try t.expect(!isStrongPassword(password, longer));
    var more_symbols = options;
    more_symbols.min_symbols = 4;
    try t.expect(!isStrongPassword(password, more_symbols));
    var more_lowercase = options;
    more_lowercase.min_lowercase = 2;
    try t.expect(!isStrongPassword(password, more_lowercase));
    var more_uppercase = options;
    more_uppercase.min_uppercase = 2;
    try t.expect(!isStrongPassword(password, more_uppercase));
    var more_numbers = options;
    more_numbers.min_numbers = 2;
    try t.expect(!isStrongPassword(password, more_numbers));
    try t.expect(!isStrongPassword("Ab1!\xff", .{ .min_length = 1, .min_lowercase = 0, .min_uppercase = 0, .min_numbers = 0, .min_symbols = 0 }));
    var symbols: usize = 0;
    var cp: u21 = 0;
    while (cp < 0x100) : (cp += 1) {
        var buf: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(cp, &buf);
        if (isStrongPassword(buf[0..n], .{ .min_length = 1, .min_lowercase = 0, .min_uppercase = 0, .min_numbers = 0, .min_symbols = 1 })) symbols += 1;
    }
    try t.expectEqual(34, symbols);
}
