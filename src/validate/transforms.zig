// Copied from vkiryakov/zefir src/validator/transforms.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! Transforms: `trim`, `trimStart`, `trimEnd`, `toLower`, `toUpper` and
//! `transformWith(f)`. A transform brings a value to its normal form before
//! the rules check it: `v.transform` runs the transforms of `field_rules`,
//! and `v.check` and `v.checkAll` skip them. In the entry of a field they
//! come after the outside name and before the rules, so that the rules
//! check the transformed value:
//! `.email = .{ v.trim, v.toLower, v.email }`.
//!
//! The built-in transforms take exactly `[]const u8` once the optionals are
//! unwrapped (on a `?[]const u8` field they run when the value is there);
//! for a list of strings they go inside `v.each`. The trims never fail and
//! never allocate; `toLower` and `toUpper` fail only with
//! `error.OutOfMemory`, when a letter changes.
const std = @import("std");
const core = @import("core.zig");
const schema = @import("schema.zig");
const strings = @import("strings.zig");
const Allocator = std.mem.Allocator;
const Transform = core.Transform;

/// Strips Unicode White_Space from both ends of a string: the 25 code points
/// that `v.notBlank` treats as blank (TAB to CR, space, U+0085, U+00A0,
/// U+1680, U+2000-200A, U+2028, U+2029, U+202F, U+205F, U+3000). The result
/// is a part of the same string: nothing is allocated. A string of
/// White_Space alone becomes "". A string that is not valid UTF-8 stays as
/// it is, for `v.utf8` or a rule that reads code points to reject.
pub const trim: Transform = builtIn(.trim, trimBoth);

/// Strips Unicode White_Space from the start of a string, as `trim` does.
pub const trimStart: Transform = builtIn(.trim_start, trimLeading);

/// Strips Unicode White_Space from the end of a string, as `trim` does.
pub const trimEnd: Transform = builtIn(.trim_end, trimTrailing);

/// The ASCII letters `A-Z` to `a-z`. Every other byte stays: in this
/// version the case of other letters does not change (`"ÄRGER"` becomes
/// `"Ärger"`). A new string is allocated only when some letter changes;
/// otherwise the value stays the same string.
pub const toLower: Transform = builtIn(.to_lower, lower);

/// The ASCII letters `a-z` to `A-Z`, every other byte as it is (`"ärger"`
/// becomes `"äRGER"`), allocated as `toLower` allocates.
pub const toUpper: Transform = builtIn(.to_upper, upper);

/// A transform with a function of your own, `f`:
/// `fn (allocator: std.mem.Allocator, value: T) E!T`, or
/// `fn (allocator: std.mem.Allocator, value: T) T` for one that cannot fail,
/// where `T` is exactly the field type without its optionals (inside
/// `v.each`, the item type without its optionals). `f` gets the value and
/// returns the new one; what it allocates comes from `allocator`, the one
/// given to `v.transform`, and it does not free the value it got. An error
/// of `f` stops `v.transform` and comes out of it as it is:
/// `v.TransformError` of the DTO includes the errors of `f`. A mistake in
/// the signature is a compile error that shows the one to write.
pub fn transformWith(comptime f: anytype) Transform {
    const F = @TypeOf(f);
    if (@typeInfo(F) != .@"fn")
        @compileError("validator: transformWith(...): f must be a function such as fn (allocator: std.mem.Allocator, value: T) E!T, got " ++ @typeName(F));
    return .{
        .kind = .transform_with,
        .run = struct {
            pub const call = f;
        },
        .fits = struct {
            fn fits(comptime t: *const Transform, comptime T: type, comptime where: []const u8) void {
                if (signatureProblem(t, T, F, where)) |text| @compileError(text);
            }
        }.fits,
    };
}

/// The schema of a transform, for `v.schemaOf`: a transform checks nothing,
/// so it has no keywords, and its note says what the server does to the
/// value before its rules check it.
pub fn schemaOf(comptime t: Transform) schema.RuleSchema {
    return .{ .accuracy = .exact, .note = switch (t.kind) {
        .trim => "Leading and trailing spaces are removed.",
        .trim_start => "Leading spaces are removed.",
        .trim_end => "Trailing spaces are removed.",
        .to_lower => "Converted to lowercase.",
        .to_upper => "Converted to uppercase.",
        .transform_with => "The server changes the value before it checks it.",
    } };
}

/// The arguments the hints show for `transformWith` used without a call:
/// `transformWith must be called, e.g. v.transformWith(normalizePhone)`.
pub const call_examples = .{ .transformWith = "normalizePhone" };

/// A built-in transform of `kind` that runs `f` on strings.
fn builtIn(comptime kind: core.TransformKind, comptime f: anytype) Transform {
    return .{
        .kind = kind,
        .run = struct {
            pub const call = f;
        },
        .fits = fitsString,
    };
}

/// The field-type check of the built-in transforms.
fn fitsString(comptime t: *const Transform, comptime T: type, comptime where: []const u8) void {
    if (stringProblem(t, T, where)) |text| @compileError(text);
}

/// The declaration error of a built-in transform on the unwrapped field type
/// `T`, or null when `T` is `[]const u8`. Another kind of string gets the
/// reason: the transform returns `[]const u8`. A list of strings gets the
/// `each` hint, `[N]u8` and a volatile, allowzero or under-aligned slice of
/// bytes the hints that rules get.
fn stringProblem(comptime t: *const Transform, comptime T: type, comptime where: []const u8) ?[]const u8 {
    if (T == []const u8) return null;
    const head = "validator: " ++ where ++ ": " ++ t.label();
    if (core.isString(T)) return head ++ " expects []const u8, field is " ++ @typeName(T) ++ "; transforms take and return []const u8";
    const hint: ?[]const u8 = if (core.isU8Array(T))
        core.hints.u8_array
    else if (core.ListChild(T)) |Item|
        (if (core.Unwrap(Item) == []const u8) core.hints.useEachTransform(t.*) else null)
    else if (isOddByteSlice(T))
        core.hints.odd_slice
    else
        null;
    return head ++ " expects a string, field is " ++ @typeName(T) ++ if (hint) |h| "; " ++ h else "";
}

/// A slice of bytes that is no string for its `volatile`, `allowzero` or
/// alignment.
fn isOddByteSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .slice and p.child == u8 and !core.isString(T) and (p.attrs.@"addrspace" orelse .generic) == .generic,
        else => false,
    };
}

/// The declaration error of `transformWith` whose function is of type `F`
/// on the unwrapped field type `T`, or null. On a list whose items `F` would
/// take, the error ends with the hint to move it into `each`.
fn signatureProblem(comptime t: *const Transform, comptime T: type, comptime F: type, comptime where: []const u8) ?[]const u8 {
    if (takes(F, T)) return null;
    const each_hint = if (core.ListChild(T)) |Item|
        (if (takes(F, core.Unwrap(Item))) "; " ++ core.hints.use_each_transform_with else "")
    else
        "";
    return "validator: " ++ where ++ ": " ++ t.label() ++ " is " ++ @typeName(F) ++
        "; write fn (allocator: std.mem.Allocator, value: " ++ @typeName(T) ++ ") E!" ++ @typeName(T) ++ each_hint;
}

/// `F` is `fn (std.mem.Allocator, T) T` or `fn (std.mem.Allocator, T) E!T`,
/// not generic.
fn takes(comptime F: type, comptime T: type) bool {
    const info = @typeInfo(F).@"fn";
    if (info.is_generic or info.param_types.len != 2) return false;
    if ((info.param_types[0] orelse return false) != Allocator) return false;
    if ((info.param_types[1] orelse return false) != T) return false;
    const R = info.return_type orelse return false;
    return R == T or (@typeInfo(R) == .error_union and @typeInfo(R).error_union.payload == T);
}

fn trimBoth(_: Allocator, s: []const u8) []const u8 {
    return trimmed(s, true, true);
}

fn trimLeading(_: Allocator, s: []const u8) []const u8 {
    return trimmed(s, true, false);
}

fn trimTrailing(_: Allocator, s: []const u8) []const u8 {
    return trimmed(s, false, true);
}

/// `s` without the White_Space at its start and at its end, as asked, or
/// `s` itself when it is not valid UTF-8.
fn trimmed(s: []const u8, comptime start: bool, comptime end: bool) []const u8 {
    if (!std.unicode.utf8ValidateSlice(s)) return s;
    // Where the content starts, and where its last code point ends.
    var first: ?usize = null;
    var last_end: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (true) {
        const at = it.i;
        const cp = it.nextCodepoint() orelse break;
        if (strings.isWhiteSpace(cp)) continue;
        if (first == null) {
            first = at;
            if (!end) break;
        }
        last_end = it.i;
    }
    const from = first orelse return if (start) s[s.len..] else s[0..0];
    return s[(if (start) from else 0)..(if (end) last_end else s.len)];
}

fn lower(allocator: Allocator, s: []const u8) Allocator.Error![]const u8 {
    return mapBytes(allocator, s, std.ascii.toLower);
}

fn upper(allocator: Allocator, s: []const u8) Allocator.Error![]const u8 {
    return mapBytes(allocator, s, std.ascii.toUpper);
}

/// `s` with `map` applied to every byte: a new string when some byte
/// changes, else `s` itself.
fn mapBytes(allocator: Allocator, s: []const u8, comptime map: fn (u8) u8) Allocator.Error![]const u8 {
    const first = for (s, 0..) |c, i| {
        if (map(c) != c) break i;
    } else return s;
    const out = try allocator.alloc(u8, s.len);
    @memcpy(out[0..first], s[0..first]);
    for (out[first..], s[first..]) |*o, c| o.* = map(c);
    return out;
}

const testing = std.testing;

/// The 25 code points of Unicode White_Space, as UTF-8.
const white_space = [_][]const u8{
    "\t",       "\n",       "\x0b",     "\x0c",     "\r",       " ",        "\u{85}",   "\u{a0}",   "\u{1680}",
    "\u{2000}", "\u{2001}", "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}", "\u{2006}", "\u{2007}", "\u{2008}",
    "\u{2009}", "\u{200a}", "\u{2028}", "\u{2029}", "\u{202f}", "\u{205f}", "\u{3000}",
};

/// What `transform` makes of `s`; built-in transforms take no memory from
/// `failing`, so the call proves that they allocate nothing.
fn run(comptime transform: Transform, s: []const u8) ![]const u8 {
    return transform.run.call(testing.failing_allocator, s);
}

test "the trims strip each of the 25 White_Space code points, and only those" {
    try testing.expectEqual(25, white_space.len);
    inline for (white_space) |ws| {
        const padded = ws ++ "a" ++ ws ++ "b" ++ ws;
        try testing.expectEqualStrings("a" ++ ws ++ "b", try run(trim, padded));
        try testing.expectEqualStrings("a" ++ ws ++ "b" ++ ws, try run(trimStart, padded));
        try testing.expectEqualStrings(ws ++ "a" ++ ws ++ "b", try run(trimEnd, padded));
    }
    // Format characters and fillers are content, as for v.notBlank.
    inline for (.{ "\u{200b}", "\u{feff}", "\u{2060}", "\u{3164}", "\u{180e}" }) |content| {
        try testing.expectEqualStrings(content, try run(trim, " " ++ content ++ " "));
    }
}

test "the trims return a part of the same string, and the string itself when there is nothing to strip" {
    const s: []const u8 = "\u{a0} Ann\u{3000}";
    const trimmed_s = try run(trim, s);
    try testing.expectEqualStrings("Ann", trimmed_s);
    try testing.expectEqual(s.ptr + 3, trimmed_s.ptr);
    const clean: []const u8 = "Ann";
    inline for (.{ trim, trimStart, trimEnd }) |t| {
        const same = try run(t, clean);
        try testing.expectEqual(clean.ptr, same.ptr);
        try testing.expectEqual(clean.len, same.len);
    }
    const empty: []const u8 = "";
    try testing.expectEqual(empty.ptr, (try run(trim, empty)).ptr);
}

test "a string of White_Space alone becomes empty" {
    const blank = " \t\u{a0}\u{3000}\n";
    inline for (.{ trim, trimStart, trimEnd }) |t| try testing.expectEqualStrings("", try run(t, blank));
}

test "a string that is not valid UTF-8 stays as it is" {
    inline for (.{ " a\xff ", "\xc3 ", " \xed\xa0\x80", "\u{a0}\xc0\xaf" }) |bad| {
        inline for (.{ trim, trimStart, trimEnd }) |t| {
            const kept = try run(t, bad);
            try testing.expectEqual(@as([]const u8, bad).ptr, kept.ptr);
            try testing.expectEqual(bad.len, kept.len);
        }
    }
}

test "toLower and toUpper change the ASCII letters only" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("ann@example.com", try toLower.run.call(a, "Ann@Example.COM"));
    try testing.expectEqualStrings("ANN@EXAMPLE.COM", try toUpper.run.call(a, "Ann@Example.com"));
    // Other letters keep their case: the tables of Unicode case are not in std.
    try testing.expectEqualStrings("\u{c4}rger", try toLower.run.call(a, "\u{c4}RGER"));
    try testing.expectEqualStrings("\u{e4}RGER", try toUpper.run.call(a, "\u{e4}rger"));
    try testing.expectEqualStrings("straße", try toLower.run.call(a, "STRAße"));
    // Bytes that are not ASCII stay, valid UTF-8 or not.
    try testing.expectEqualStrings("a\xffb", try toLower.run.call(a, "A\xffB"));
    try testing.expectEqualStrings("@[`{", try toLower.run.call(a, "@[`{"));
}

test "toLower and toUpper allocate only when a letter changes" {
    // Nothing to change: the same string, and no memory asked for.
    inline for (.{ .{ toLower, "ann 42 \u{c4}" }, .{ toUpper, "ANN 42 \u{e4}" } }) |case| {
        const s: []const u8 = case[1];
        const same = try case[0].run.call(testing.failing_allocator, s);
        try testing.expectEqual(s.ptr, same.ptr);
        try testing.expectEqual(s.len, same.len);
    }
    // A letter to change: one new string.
    try testing.expectError(error.OutOfMemory, toLower.run.call(testing.failing_allocator, "Ann"));
    var counting: std.testing.FailingAllocator = .init(testing.allocator, .{});
    const changed = try toUpper.run.call(counting.allocator(), "ann");
    defer testing.allocator.free(changed);
    try testing.expectEqualStrings("ANN", changed);
    try testing.expectEqual(1, counting.allocations);
}

test "the transforms are named by their public names and their snake_case labels" {
    const expect = testing.expectEqualStrings;
    inline for (.{ trim, trimStart, trimEnd, toLower, toUpper }, .{ "trim", "trimStart", "trimEnd", "toLower", "toUpper" }, .{ "trim", "trim_start", "trim_end", "to_lower", "to_upper" }) |t, name, label| {
        try expect(name, comptime t.name());
        try expect(label, comptime t.label());
        try expect(label, comptime core.snakeCase(t.name()));
    }
    const custom = comptime transformWith(normalizeTag);
    try expect("transformWith", comptime custom.name());
    try expect("transform_with(...)", comptime custom.label());
}

const test_where = "Dto.field_rules.x";

fn stringText(comptime t: Transform, comptime T: type) ?[]const u8 {
    return comptime stringProblem(&t, T, test_where);
}

test "a built-in transform takes []const u8; another type is named, with the hint that applies" {
    const expect = testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: ";
    try testing.expectEqual(null, stringText(trim, []const u8));
    try expect(head ++ "trim expects a string, field is u8", stringText(trim, u8).?);
    try expect(head ++ "to_lower expects a string, field is bool", stringText(toLower, bool).?);
    // Other kinds of strings: the result is a []const u8.
    try expect(head ++ "trim expects []const u8, field is [:0]const u8; transforms take and return []const u8", stringText(trim, [:0]const u8).?);
    try expect(head ++ "to_upper expects []const u8, field is []u8; transforms take and return []const u8", stringText(toUpper, []u8).?);
    // A list of strings, optional ones too: the transform goes into each.
    try expect(head ++ "trim_start expects a string, field is []const []const u8; use v.each(v.trimStart)", stringText(trimStart, []const []const u8).?);
    try expect(head ++ "trim_end expects a string, field is [2]?[]const u8; use v.each(v.trimEnd)", stringText(trimEnd, [2]?[]const u8).?);
    try expect(head ++ "trim expects a string, field is []const [:0]const u8", stringText(trim, []const [:0]const u8).?);
    try expect(head ++ "trim expects a string, field is [4]u8; [N]u8 is an array of numbers, not a string: use []const u8", stringText(trim, [4]u8).?);
    try expect(head ++ "trim expects a string, field is []volatile u8; volatile, allowzero and under-aligned slices are neither strings nor lists", stringText(trim, []volatile u8).?);
}

fn normalizeTag(_: Allocator, tag: []const u8) error{TooLong}![]const u8 {
    if (tag.len > 32) return error.TooLong;
    return tag;
}

fn double(_: Allocator, n: u32) u32 {
    return n *% 2;
}

fn generic(_: Allocator, value: anytype) @TypeOf(value) {
    return value;
}

fn signatureText(comptime f: anytype, comptime T: type) ?[]const u8 {
    return comptime signatureProblem(&transformWith(f), T, @TypeOf(f), test_where);
}

test "transformWith takes fn (std.mem.Allocator, T) E!T or fn (std.mem.Allocator, T) T, T exactly the field type" {
    const expect = testing.expectEqualStrings;
    try testing.expectEqual(null, signatureText(normalizeTag, []const u8));
    try testing.expectEqual(null, signatureText(double, u32));
    try expect(
        "validator: Dto.field_rules.x: transform_with(...) is fn (mem.Allocator, u32) u32; write fn (allocator: std.mem.Allocator, value: u64) E!u64",
        signatureText(double, u64).?,
    );
    try expect(
        "validator: Dto.field_rules.x: transform_with(...) is fn (mem.Allocator, []const u8) error{TooLong}![]const u8; write fn (allocator: std.mem.Allocator, value: [:0]const u8) E![:0]const u8",
        signatureText(normalizeTag, [:0]const u8).?,
    );
    try expect(
        "validator: Dto.field_rules.x: transform_with(...) is fn (mem.Allocator, anytype) anytype; write fn (allocator: std.mem.Allocator, value: u32) E!u32",
        signatureText(generic, u32).?,
    );
    try expect(
        "validator: Dto.field_rules.x: transform_with(...) is fn ([]const u8) bool; write fn (allocator: std.mem.Allocator, value: []const u8) E![]const u8",
        signatureText(isShort, []const u8).?,
    );
    try expect(
        "validator: Dto.field_rules.x: transform_with(...) is fn (mem.Allocator, []const u8) ?[]const u8; write fn (allocator: std.mem.Allocator, value: []const u8) E![]const u8",
        signatureText(maybeTag, []const u8).?,
    );
}

fn isShort(s: []const u8) bool {
    return s.len < 8;
}

fn maybeTag(_: Allocator, tag: []const u8) ?[]const u8 {
    return if (tag.len == 0) null else tag;
}

test "transformWith on a list whose items its function takes gets the each hint" {
    const expect = testing.expectEqualStrings;
    try expect(
        "validator: Dto.field_rules.x: transform_with(...) is fn (mem.Allocator, []const u8) error{TooLong}![]const u8; write fn (allocator: std.mem.Allocator, value: []const []const u8) E![]const []const u8; use v.each(v.transformWith(...))",
        signatureText(normalizeTag, []const []const u8).?,
    );
    try expect(
        "validator: Dto.field_rules.x: transform_with(...) is fn (mem.Allocator, u32) u32; write fn (allocator: std.mem.Allocator, value: [3]?u32) E![3]?u32; use v.each(v.transformWith(...))",
        signatureText(double, [3]?u32).?,
    );
}

test "a transform's error set is that of its function" {
    try testing.expect((comptime trim.Error()) == error{});
    try testing.expect((comptime toLower.Error()) == Allocator.Error);
    try testing.expect((comptime transformWith(normalizeTag).Error()) == error{TooLong});
    try testing.expect((comptime transformWith(double).Error()) == error{});
}
