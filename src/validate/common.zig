// Copied from vkiryakov/zefir src/validator/common.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! Common rules: `equals`, `notEquals`, `oneOf`, `noneOf`, `empty` and
//! `notEmpty`.
const std = @import("std");
const core = @import("core.zig");
const schema = @import("schema.zig");
const Rule = core.Rule;
const Outcome = core.Outcome;

// ------------------------------------------------------------------ equals, notEquals

/// `value == expected`. Integers and bools compare exactly at every width;
/// floats by IEEE `==` after the parameter is rounded to the field type, so
/// -0.0 equals 0 and `equals(0.1)` on f32 accepts the f32 nearest to 0.1,
/// with no epsilon (NaN and infinities fail with the precondition
/// `validation.finite`); an enum by its tag, so an unnamed value of a
/// non-exhaustive enum never matches; strings byte for byte, with no
/// decoding, trimming or case folding. The parameter is one integer, finite
/// float, bool, named enum tag or non-empty valid UTF-8 string, and must fit
/// the field type; a typed float narrower than a float field must also show
/// the same value there, as for `v.min`. The message shows it as written:
/// `v.equals(.admin)` says "must be equal to admin".
pub fn equals(comptime expected: anytype) Rule {
    return comparison(.equals, expected);
}

/// `value != forbidden`, with the parameters and comparisons of `equals`.
/// On a float field NaN and infinities fail with the precondition, so
/// `notEquals(0)` does not pass them; an unnamed value of a non-exhaustive
/// enum always passes.
pub fn notEquals(comptime forbidden: anytype) Rule {
    return comparison(.not_equals, forbidden);
}

/// `equals(x)` or `notEquals(x)`.
fn comparison(comptime kind: core.Kind, comptime x: anytype) Rule {
    @setEvalBranchQuota(core.eval_quota);
    if (comparisonProblem(kind, x)) |text| @compileError(text);
    const is_equals = kind == .equals;
    return core.define(kind, .{
        .message = (if (is_equals) "must be equal to " else "must not be equal to ") ++ core.renderValue(x),
        .fallback = if (is_equals) "must be equal to the expected value" else "must not be equal to the forbidden value",
        .args = core.renderArg(x),
        .params = &.{core.param(if (is_equals) "expected" else "forbidden", x)},
        .precondition = core.preconditions.finite,
        .fits = struct {
            fn fits(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void {
                if (scalarProblem(rule, x, T, where)) |text| @compileError(text);
            }
        }.fits,
        .eval = struct {
            fn eval(value: anytype) Outcome {
                const T = @TypeOf(value.*);
                const same = if (comptime core.isString(T)) std.mem.eql(u8, value.*, x) else switch (@typeInfo(T)) {
                    .float => blk: {
                        if (!std.math.isFinite(value.*)) return .precondition;
                        break :blk value.* == comptime core.valueAs(T, x);
                    },
                    .int, .bool, .@"enum" => value.* == comptime core.valueAs(T, x),
                    else => @compileError("validator: internal: " ++ @tagName(kind) ++ "'s eval was instantiated for a type its fits rejected"),
                };
                return core.passIf(same == is_equals);
            }
        }.eval,
    });
}

/// The error of the call `equals(x)` or `notEquals(x)`, or null: `x` is an
/// integer, a finite float, a bool, a named enum tag or a non-empty valid
/// UTF-8 string.
fn comparisonProblem(comptime kind: core.Kind, comptime x: anytype) ?[]const u8 {
    @setEvalBranchQuota(core.eval_quota);
    const X = @TypeOf(x);
    const shown = core.renderArg(x);
    const head = "validator: " ++ core.info(kind).name ++ "(" ++ shown ++ "): ";
    switch (comptime core.valueKind(X)) {
        .int, .bool => return null,
        .float => return if (core.isFiniteNumber(x)) null else head ++ shown ++ " is not finite",
        .tag => return if (core.tagName(x) != null) null else head ++ shown ++ " is not a named tag of " ++ @typeName(X),
        .string => {
            if (x.len == 0) return head ++ if (kind == .equals)
                "the expected value is the empty string; " ++ core.hints.use_empty
            else
                "the forbidden value is the empty string; " ++ core.hints.use_not_empty;
            if (!std.unicode.utf8ValidateSlice(x)) return head ++ shown ++ " is not valid UTF-8";
            return null;
        },
        .list, .other => return head ++ "expects an integer, a float, a bool, an enum tag or a string, got " ++ @typeName(X),
    }
}

/// The declaration error of `equals(x)` or `notEquals(x)` on the unwrapped
/// field type `T`, or null. A number field takes a number that fits it
/// (`numberParamProblem`), a bool field a bool, an enum field one of its
/// tags (and not a single-tag exhaustive enum, where the rule would be
/// decided), a string field a string; other fields are a type error, with
/// the `each` hint for a list whose items take a parameter of this kind.
fn scalarProblem(comptime rule: *const Rule, comptime x: anytype, comptime T: type, comptime where: []const u8) ?[]const u8 {
    @setEvalBranchQuota(core.eval_quota);
    const kind = comptime core.valueKind(@TypeOf(x));
    const is_equals = rule.kind == .equals;
    if (core.isNumber(T)) {
        const outside = if (is_equals) "; the rule would never pass" else "; the rule would always pass";
        const text = core.numberParamProblem(x, T, "use an integer", outside) orelse return null;
        return core.ruleErrorText(rule, where, text);
    }
    if (T == bool) return if (kind == .bool) null else core.ruleErrorText(rule, where, wrongParamText(x, T, "use true or false"));
    if (@typeInfo(T) == .@"enum") {
        const e = @typeInfo(T).@"enum";
        if (kind != .tag) {
            const hint = if (e.field_names.len == 0) null else "use a tag such as ." ++ core.tagIdentifier(e.field_names[0]);
            return core.ruleErrorText(rule, where, wrongParamText(x, T, hint));
        }
        if (core.tagProblem(x, T)) |text| return core.ruleErrorText(rule, where, text);
        if (e.mode == .exhaustive and e.field_names.len == 1)
            return core.ruleErrorText(rule, where, ": " ++ @typeName(T) ++ " has a single tag; the rule would " ++ (if (is_equals) "always" else "never") ++ " pass");
        return null;
    }
    if (core.isString(T)) return if (kind == .string) null else core.ruleErrorText(rule, where, wrongParamText(x, T, "use a string"));
    return core.typeErrorText(rule, T, where, "a number, a bool, an enum or a string", scalarAccepts(kind), null);
}

/// The field types that `equals` and `notEquals` take with a parameter of
/// `kind`: numbers for a number, bool for a bool, enums for a tag, strings
/// for a string. It picks the type error's hint.
fn scalarAccepts(comptime kind: core.ValueKind) fn (comptime type) bool {
    return struct {
        fn accepts(comptime F: type) bool {
            return switch (kind) {
                .int, .float => core.isNumber(F),
                .bool => F == bool,
                .tag => @typeInfo(F) == .@"enum",
                .string => core.isString(F),
                .list, .other => false,
            };
        }
    }.accepts;
}

/// A parameter of the wrong kind for the field, as the text after the rule's
/// label: `: "admin" is a string, field is Role; use a tag such as .admin`.
fn wrongParamText(comptime x: anytype, comptime T: type, comptime hint: ?[]const u8) []const u8 {
    return ": " ++ core.renderArg(x) ++ " is " ++ core.describeValueType(@TypeOf(x)) ++ ", field is " ++ @typeName(T) ++
        if (hint) |h| "; " ++ h else "";
}

// ------------------------------------------------------------------ oneOf, noneOf

/// The value equals one of the listed values. The list is a tuple or an
/// array `[N]T` (not a pointer to one, not a slice) of at least one value,
/// none twice: strings, compared byte for byte (`""` may be listed); enum
/// tags, so an unnamed value of a non-exhaustive enum never matches; or
/// integers, compared exactly in the field type. Listing every tag of an
/// enum is allowed: it pins the current set. The message lists the values:
/// "must be one of: a, b", "must be admin" for one value, and "must be one
/// of the allowed values" when the list would make it longer than 512
/// bytes. A value that contains ", " reads ambiguously in the list: give
/// such a list a message of its own.
pub fn oneOf(comptime values: anytype) Rule {
    @setEvalBranchQuota(core.eval_quota);
    const list = core.analyzeList("oneOf", values, one_of_list);
    const message = if (list.len == 1) "must be " ++ list.text else "must be one of: " ++ list.text;
    return membership(.one_of, values, list, message, "must be one of the allowed values");
}

/// The value equals none of the listed values, with the lists and
/// comparisons of `oneOf`; exact matches only, without prefixes, case
/// folding or look-alike characters. `""` cannot be listed (use
/// `v.notEmpty`), and the list may not leave the field type without a value
/// that passes. An unnamed value of a non-exhaustive enum always passes.
pub fn noneOf(comptime values: anytype) Rule {
    @setEvalBranchQuota(core.eval_quota);
    const list = core.analyzeList("noneOf", values, none_of_list);
    const message = if (list.len == 1) "must not be " ++ list.text else "must not be one of: " ++ list.text;
    return membership(.none_of, values, list, message, "must not be one of the forbidden values");
}

/// The lists `oneOf` and `noneOf` take.
const one_of_list: core.ListOptions = .{};
const none_of_list: core.ListOptions = .{ .empty_string = "the empty string cannot be listed; " ++ core.hints.use_not_empty };

/// `oneOf` or `noneOf` over a checked list.
fn membership(comptime kind: core.Kind, comptime values: anytype, comptime list: core.ValueList, comptime message: []const u8, comptime fallback: []const u8) Rule {
    const is_one_of = kind == .one_of;
    return core.define(kind, .{
        .message = message,
        .fallback = fallback,
        .args = list.args,
        .params = &.{core.param("values", values)},
        .fits = struct {
            fn fits(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void {
                if (membershipProblem(rule, values, list, T, where)) |text| @compileError(text);
            }
        }.fits,
        .eval = struct {
            fn eval(value: anytype) Outcome {
                const T = @TypeOf(value.*);
                const found = if (comptime core.isString(T)) blk: {
                    const strings = comptime core.listAs([]const u8, values);
                    for (strings) |s| {
                        if (std.mem.eql(u8, value.*, s)) break :blk true;
                    }
                    break :blk false;
                } else switch (@typeInfo(T)) {
                    .int, .@"enum" => blk: {
                        const items = comptime core.listAs(T, values);
                        for (items) |item| {
                            if (value.* == item) break :blk true;
                        }
                        break :blk false;
                    },
                    else => @compileError("validator: internal: " ++ @tagName(kind) ++ "'s eval was instantiated for a type its fits rejected"),
                };
                return core.passIf(found == is_one_of);
            }
        }.eval,
    });
}

/// The declaration error of `oneOf` or `noneOf` with the checked list
/// `values` on the unwrapped field type `T`, or null. The list holds the
/// field's kind of value: strings on a string field, the enum's own tags on
/// an enum field, integers within the type on an integer field; a `noneOf`
/// list may not hold every tag of an exhaustive enum or every value of an
/// integer type. Other fields are a type error, with the `each` hint for a
/// list whose items take the listed kind.
fn membershipProblem(comptime rule: *const Rule, comptime values: anytype, comptime list: core.ValueList, comptime T: type, comptime where: []const u8) ?[]const u8 {
    @setEvalBranchQuota(core.eval_quota);
    const field: core.ListKind = if (core.isString(T)) .string else switch (@typeInfo(T)) {
        .@"enum" => .tag,
        .int => .int,
        else => return core.typeErrorText(rule, T, where, "a string, an enum or an integer", listAccepts(list.kind), null),
    };
    if (list.kind != field) {
        const instead: ?[]const u8 = switch (field) {
            .string => "list strings instead: .{ \"a\", ... }",
            // An enum without named tags has no tag to list.
            .tag => if (@typeInfo(T).@"enum".field_names.len == 0) null else "list the enum's tags instead: .{ .tag, ... }",
            .int => "list integers instead: .{ 1, ... }",
            .bool => @compileError("validator: internal: no field takes a list of bools here"),
        };
        return core.ruleErrorText(rule, where, " lists " ++ list.kind.plural() ++ ", field is " ++ @typeName(T) ++ if (instead) |hint| "; " ++ hint else "");
    }
    const excludes_all = rule.kind == .none_of;
    switch (field) {
        .tag => {
            inline for (0..values.len) |i| {
                if (core.tagProblem(values[i], T)) |text| return core.ruleErrorText(rule, where, text);
            }
            const e = @typeInfo(T).@"enum";
            if (excludes_all and e.mode == .exhaustive and list.len == e.field_names.len)
                return core.ruleErrorText(rule, where, " lists every tag of " ++ @typeName(T) ++ "; no value would pass");
        },
        .int => {
            inline for (0..values.len) |i| {
                if (core.numberParamProblem(values[i], T, "use an integer", "; remove it")) |text| return core.ruleErrorText(rule, where, text);
            }
            if (excludes_all and @as(comptime_int, list.len) == std.math.maxInt(T) - std.math.minInt(T) + 1)
                return core.ruleErrorText(rule, where, " lists every value of " ++ @typeName(T) ++ "; no value would pass");
        },
        .string, .bool => {},
    }
    return null;
}

/// The field types a list of `kind` takes: strings, enums or integers. It
/// picks the type error's hint.
fn listAccepts(comptime kind: core.ListKind) fn (comptime type) bool {
    return struct {
        fn accepts(comptime F: type) bool {
            return switch (kind) {
                .string => core.isString(F),
                .tag => @typeInfo(F) == .@"enum",
                .int => @typeInfo(F) == .int,
                .bool => F == bool,
            };
        }
    }.accepts;
}

// ------------------------------------------------------------------ empty, notEmpty

/// `len == 0`. Strings count bytes without decoding them, so `" "`,
/// `"\x00"`, `"\xff"` and U+200B are not empty; slices count items, null
/// items included. On a fixed-size array `[N]T` it is a compile error: the
/// length of an array never changes.
pub const empty: Rule = core.define(.empty, .{
    .message = "must be empty",
    .bounds = &.{ .atMost(.bytes, 0), .atMost(.items, 0) },
    .fits = lengthFits,
    .eval = struct {
        fn eval(value: anytype) Outcome {
            return core.passIf(value.*.len == 0);
        }
    }.eval,
});

/// `len > 0`. Strings count bytes without decoding them, so `" "` and
/// `"\xff"` pass; slices count items, null items included. On a fixed-size
/// array `[N]T` it is a compile error: the length of an array never changes.
pub const notEmpty: Rule = core.define(.not_empty, .{
    .message = "must not be empty",
    .bounds = &.{ .atLeast(.bytes, 1), .atLeast(.items, 1) },
    .fits = lengthFits,
    .eval = struct {
        fn eval(value: anytype) Outcome {
            return core.passIf(value.*.len != 0);
        }
    }.eval,
});

/// The field-type check of the length rules.
fn lengthFits(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void {
    if (lengthProblem(rule, T, where)) |text| @compileError(text);
}

/// The declaration error of `empty` or `notEmpty` on the unwrapped field
/// type `T`, or null: a string or a slice that is not a string. On a
/// fixed-size array the rule's verdict never changes, so it is an error,
/// with the hint that `[N]u8` is not a string.
fn lengthProblem(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) ?[]const u8 {
    switch (@typeInfo(T)) {
        .array => |a| {
            const always = (a.len == 0) == (rule.kind == .empty);
            return core.ruleErrorText(rule, where, " on " ++ @typeName(T) ++ " is always " ++ (if (always) "true" else "false") ++
                ": the length of an array is fixed" ++ (if (a.child == u8) "; " ++ core.hints.u8_array else ""));
        },
        else => {},
    }
    if (core.isString(T) or core.isListSlice(T)) return null;
    return core.typeErrorText(rule, T, where, "a string or a slice", struct {
        fn accepts(comptime F: type) bool {
            return core.isString(F) or core.isListSlice(F);
        }
    }.accepts, null);
}

// ------------------------------------------------------------------ schema

/// The JSON Schema keywords of a rule of this file on the unwrapped field
/// type `T`, for `v.schemaOf`; all exact. A tag is its name, as JSON writes
/// an enum; an empty string or list has no characters or no items.
pub fn schemaOf(comptime rule: Rule, comptime T: type) schema.RuleSchema {
    return switch (rule.kind) {
        .equals => schema.exact(&.{schema.keyword("const", schema.param(rule.params[0]))}),
        .not_equals => schema.exact(&.{schema.keyword("not", schema.object(&.{schema.keyword("const", schema.param(rule.params[0]))}))}),
        .one_of => schema.exact(&.{schema.keyword("enum", schema.value(rule.params[0].value))}),
        .none_of => schema.exact(&.{schema.keyword("not", schema.object(&.{schema.keyword("enum", schema.value(rule.params[0].value))}))}),
        .empty => schema.exact(&.{schema.count(if (core.isString(T)) "maxLength" else "maxItems", 0)}),
        .not_empty => schema.exact(&.{schema.count(if (core.isString(T)) "minLength" else "minItems", 1)}),
        else => unreachable,
    };
}

/// The arguments the hints show for an uncalled constructor of this file:
/// `equals must be called, e.g. v.equals(true)`.
pub const call_examples = .{ .equals = "true", .notEquals = "0", .oneOf = ".{ \"a\", \"b\" }", .noneOf = ".{ \"a\", \"b\" }" };

const expectOutcome = core.expectOutcome;

test "notEmpty has its documented code and message and no precondition" {
    try std.testing.expectEqualStrings("validation.not_empty", notEmpty.code);
    try std.testing.expectEqualStrings("must not be empty", notEmpty.message);
    try std.testing.expectEqual(core.Kind.not_empty, notEmpty.kind);
    try std.testing.expectEqual(null, notEmpty.args);
    try std.testing.expectEqual(null, notEmpty.precondition);
}

test "notEmpty counts the bytes of a string without decoding them" {
    try expectOutcome(.fail, notEmpty, @as([]const u8, ""));
    try expectOutcome(.pass, notEmpty, @as([]const u8, " "));
    try expectOutcome(.pass, notEmpty, @as([]const u8, "\xff"));
    try expectOutcome(.pass, notEmpty, @as([]const u8, "a"));
    try expectOutcome(.fail, notEmpty, @as([:0]const u8, ""));
    var buffer = "x".*;
    try expectOutcome(.pass, notEmpty, @as([]u8, &buffer));
    try expectOutcome(.fail, notEmpty, @as([]u8, buffer[0..0]));
}

test "notEmpty counts the items of a slice, null items included" {
    try expectOutcome(.fail, notEmpty, @as([]const u32, &.{}));
    try expectOutcome(.pass, notEmpty, @as([]const u32, &.{0}));
    try expectOutcome(.pass, notEmpty, @as([]const ?u32, &.{null}));
    try expectOutcome(.pass, notEmpty, @as([]const []const u8, &.{""}));
}

test "notEmpty fits strings of every kind and slices" {
    comptime {
        for ([_]type{ []const u8, []u8, [:0]const u8, [:0]u8, []const u32, []u32, []const ?u32, []const []const u8 }) |T| {
            notEmpty.fits(&notEmpty, T, "Dto.field_rules.x");
        }
    }
}

/// Types for the tests below: an exhaustive enum, another enum with a tag
/// of the same name, a non-exhaustive enum, single-tag enums, sparse tag
/// values, an enum without named tags, an enum whose tags need `@"..."` and
/// a struct.
const Role = enum { admin, user, guest };
const Color = enum { red, admin };
const Open = enum(u8) { a, b, _ };
const OpenOne = enum(u8) { only, _ };
const Only = enum { only };
const Sparse = enum(u32) { low = 1, high = 1_000_000 };
const NoTags = enum(u8) { _ };
const Quoted = enum { @"error", @"a\nb", plain };
const Item = struct { id: u32 };

const test_where = "Dto.field_rules.x";

/// The declaration error of `equals(x)` on a field of type `T`, or null.
fn equalsText(comptime x: anytype, comptime T: type) ?[]const u8 {
    return scalarProblem(&equals(x), x, T, test_where);
}

fn notEqualsText(comptime x: anytype, comptime T: type) ?[]const u8 {
    return scalarProblem(&notEquals(x), x, T, test_where);
}

/// The declaration error of `empty` or `notEmpty` on a field of type `T`, or null.
fn lengthText(comptime rule: Rule, comptime T: type) ?[]const u8 {
    return lengthProblem(&rule, T, test_where);
}

/// The error a rule constructor used without a call raises in `field_rules`.
fn uncalledText(comptime name: []const u8, comptime F: type) []const u8 {
    return "validator: " ++ test_where ++ ": " ++ core.hints.mustBeCalled(name, F);
}

test "equals and notEquals have their documented codes, messages, parameters and the finite precondition" {
    const t = std.testing;
    const same = equals(5);
    try t.expectEqual(core.Kind.equals, same.kind);
    try t.expectEqualStrings("validation.equals", same.code);
    try t.expectEqualStrings("must be equal to 5", same.message);
    try t.expectEqualStrings("5", same.args.?);
    try t.expectEqual(1, same.params.len);
    try t.expectEqualStrings("expected", same.params[0].name);
    try t.expectEqualStrings("5", same.params[0].text);
    try t.expect(same.params[0].placeholder);
    try t.expectEqualStrings("validation.finite", same.precondition.?.code);
    try t.expectEqualStrings("must be a finite number", same.precondition.?.message);

    const other = notEquals("root");
    try t.expectEqual(core.Kind.not_equals, other.kind);
    try t.expectEqualStrings("validation.not_equals", other.code);
    try t.expectEqualStrings("must not be equal to root", other.message);
    try t.expectEqualStrings("\"root\"", other.args.?);
    try t.expectEqual(1, other.params.len);
    try t.expectEqualStrings("forbidden", other.params[0].name);
    try t.expectEqualStrings("root", other.params[0].text);
    try t.expectEqualStrings("root", other.params[0].value.string);
    try t.expectEqualStrings("validation.finite", other.precondition.?.code);
}

test "equals and notEquals show the parameter as written: -0.0 as 0, floats as written, tags by name, strings escaped" {
    const expect = std.testing.expectEqualStrings;
    try expect("must be equal to 0", equals(-0.0).message);
    try expect("equals(0)", comptime equals(-0.0).call());
    try expect("must be equal to 0.1", equals(@as(f32, 0.1)).message);
    try expect("must be equal to 1e-7", equals(1e-7).message);
    try expect("must be equal to -170141183460469231731687303715884105728", equals(std.math.minInt(i128)).message);
    try expect("must not be equal to false", notEquals(false).message);
    try expect("must be equal to admin", equals(.admin).message);
    try expect("equals(.admin)", comptime equals(.admin).call());
    try expect("must be equal to guest", equals(Role.guest).message);
    try expect("must be equal to tab\\there", equals("tab\there").message);
    try expect("equals(\"tab\\there\")", comptime equals("tab\there").call());
    try expect("must not be equal to \\xe2\\x80\\xa8", notEquals("\u{2028}").message);
    try expect("must be equal to имя", equals("имя").message);
    try expect("not_equals(.only)", comptime notEquals(.only).label());
    // A tag that is no plain identifier: escaped in the message, quoted as
    // zig fmt writes it in the call.
    try expect("must be equal to a\\nb", equals(Quoted.@"a\nb").message);
    try expect("equals(.@\"error\")", comptime equals(.@"error").call());
    try expect("must be equal to \\xff", equals(.@"\xff").message);
}

test "equals and notEquals keep a default message of exactly 512 bytes and take the fallback above it" {
    const t = std.testing;
    // "must be equal to " is 17 bytes, "must not be equal to " 21.
    const fits: [495]u8 = @splat('x');
    const over: [496]u8 = @splat('x');
    try t.expectEqual(512, equals(&fits).message.len);
    try t.expectEqualStrings("must be equal to " ++ fits, equals(&fits).message);
    try t.expectEqualStrings("must be equal to the expected value", equals(&over).message);
    const fits_not: [491]u8 = @splat('x');
    const over_not: [492]u8 = @splat('x');
    try t.expectEqual(512, notEquals(&fits_not).message.len);
    try t.expectEqualStrings("must not be equal to the forbidden value", notEquals(&over_not).message);
    // The parameter counts as the message shows it: 248 quotes are 496 bytes escaped.
    const quotes: [248]u8 = @splat('"');
    try t.expectEqualStrings("must be equal to the expected value", equals(&quotes).message);
    // Only the message falls back: the parameter keeps its whole text.
    try t.expectEqualStrings(&over, equals(&over).params[0].text);
    try t.expectEqualStrings("\"" ++ over ++ "\"", equals(&over).args.?);
}

test "equals and notEquals take one integer, finite float, bool, named tag or non-empty valid UTF-8 string" {
    const expect = std.testing.expectEqualStrings;
    const kinds = "expects an integer, a float, a bool, an enum tag or a string, got ";
    try expect("validator: equals(\"\"): the expected value is the empty string; use v.empty", comptime comparisonProblem(.equals, "").?);
    try expect("validator: notEquals(\"\"): the forbidden value is the empty string; use v.notEmpty", comptime comparisonProblem(.not_equals, "").?);
    try expect("validator: equals(\"\\xff\"): \"\\xff\" is not valid UTF-8", comptime comparisonProblem(.equals, "\xff").?);
    try expect("validator: notEquals(\"\\xff\"): \"\\xff\" is not valid UTF-8", comptime comparisonProblem(.not_equals, "\xff").?);
    try expect("validator: equals(\"caf\\xc3\"): \"caf\\xc3\" is not valid UTF-8", comptime comparisonProblem(.equals, "caf\xc3").?);
    try expect("validator: equals(nan): nan is not finite", comptime comparisonProblem(.equals, std.math.nan(f64)).?);
    try expect("validator: notEquals(nan): nan is not finite", comptime comparisonProblem(.not_equals, std.math.nan(f64)).?);
    try expect("validator: equals(inf): inf is not finite", comptime comparisonProblem(.equals, std.math.inf(f64)).?);
    try expect("validator: notEquals(-inf): -inf is not finite", comptime comparisonProblem(.not_equals, -std.math.inf(f32)).?);
    try expect("validator: equals(inf): inf is not finite", comptime comparisonProblem(.equals, @as(comptime_float, std.math.inf(f64))).?);
    try expect("validator: equals(...): " ++ kinds ++ "@TypeOf(null)", comptime comparisonProblem(.equals, null).?);
    try expect("validator: notEquals(...): " ++ kinds ++ "@TypeOf(null)", comptime comparisonProblem(.not_equals, null).?);
    try expect("validator: equals(...): " ++ kinds ++ "?u8", comptime comparisonProblem(.equals, @as(?u8, 5)).?);
    try expect("validator: equals(...): " ++ kinds ++ "common.Item", comptime comparisonProblem(.equals, Item{ .id = 1 }).?);
    try expect("validator: equals(...): " ++ kinds ++ "[]const u32", comptime comparisonProblem(.equals, @as([]const u32, &.{ 1, 2 })).?);
    try expect("validator: equals(.{ 1, 2 }): " ++ kinds ++ "[2]u32", comptime comparisonProblem(.equals, [_]u32{ 1, 2 }).?);
    try expect("validator: equals(@fromBackingInt(7)): @fromBackingInt(7) is not a named tag of common.Open", comptime comparisonProblem(.equals, @as(Open, @fromBackingInt(7))).?);
    try expect("validator: notEquals(@fromBackingInt(7)): @fromBackingInt(7) is not a named tag of common.Open", comptime comparisonProblem(.not_equals, @as(Open, @fromBackingInt(7))).?);
    inline for (.{ 0, -1, @as(u8, 5), std.math.maxInt(u128), 0.5, -0.0, @as(f16, 0.1), std.math.floatMax(f64), true, false, .admin, Role.guest, Open.a, "a", @as([]const u8, "x"), "имя" }) |x| {
        try std.testing.expectEqual(null, comptime comparisonProblem(.equals, x));
        try std.testing.expectEqual(null, comptime comparisonProblem(.not_equals, x));
    }
}

test "on an integer field the parameter of equals and notEquals is an integer within the field type" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: Dto.field_rules.x: equals(300): 300 is outside u8 (0..255); the rule would never pass", comptime equalsText(300, u8).?);
    try expect("validator: Dto.field_rules.x: not_equals(-1): -1 is outside u32 (0..4294967295); the rule would always pass", comptime notEqualsText(-1, u32).?);
    try expect("validator: Dto.field_rules.x: equals(-129): -129 is outside i8 (-128..127); the rule would never pass", comptime equalsText(-129, i8).?);
    try expect("validator: Dto.field_rules.x: equals(1.5): 1.5 is a float (comptime_float), field is i32; use an integer", comptime equalsText(1.5, i32).?);
    try expect("validator: Dto.field_rules.x: not_equals(1.5): 1.5 is a float (comptime_float), field is i32; use an integer", comptime notEqualsText(1.5, i32).?);
    try expect("validator: Dto.field_rules.x: equals(2): 2 is a float (comptime_float), field is i32; use an integer", comptime equalsText(2.0, i32).?);
    try expect("validator: Dto.field_rules.x: equals(10): 10 is a float (f64), field is u64; use an integer", comptime equalsText(@as(f64, 10), u64).?);
    try expect("validator: Dto.field_rules.x: equals(\"5\"): \"5\" is a string, field is i32; use an integer", comptime equalsText("5", i32).?);
    try expect("validator: Dto.field_rules.x: not_equals(\"5\"): \"5\" is a string, field is i32; use an integer", comptime notEqualsText("5", i32).?);
    try expect("validator: Dto.field_rules.x: equals(true): true is a bool, field is u8; use an integer", comptime equalsText(true, u8).?);
    try expect("validator: Dto.field_rules.x: equals(.admin): .admin is an enum tag, field is u8; use an integer", comptime equalsText(.admin, u8).?);
    try expect("validator: Dto.field_rules.x: not_equals(.admin): .admin is an enum tag, field is u8; use an integer", comptime notEqualsText(.admin, u8).?);
    inline for (.{ u8, i8, u64, i64, u128, i128, usize }) |T| {
        try std.testing.expectEqual(null, comptime equalsText(std.math.minInt(T), T));
        try std.testing.expectEqual(null, comptime equalsText(std.math.maxInt(T), T));
        try std.testing.expectEqual(null, comptime notEqualsText(std.math.minInt(T), T));
        try std.testing.expectEqual(null, comptime notEqualsText(std.math.maxInt(T), T));
    }
    try std.testing.expectEqual(null, comptime equalsText(@as(u64, 7), i8));
}

test "on a float field the parameter is a number that stays finite and non-zero in it, and an integer it holds exactly" {
    const expect = std.testing.expectEqualStrings;
    try expect(
        "validator: Dto.field_rules.x: equals(9007199254740993): 9007199254740993 is not exactly representable in f64 (nearest: 9007199254740992)",
        comptime equalsText(9007199254740993, f64).?,
    );
    try expect(
        "validator: Dto.field_rules.x: not_equals(9007199254740993): 9007199254740993 is not exactly representable in f64 (nearest: 9007199254740992)",
        comptime notEqualsText(9007199254740993, f64).?,
    );
    try expect("validator: Dto.field_rules.x: equals(1e300): 1e300 is outside the finite range of f32; the rule would never pass", comptime equalsText(1e300, f32).?);
    try expect("validator: Dto.field_rules.x: not_equals(1e300): 1e300 is outside the finite range of f32; the rule would always pass", comptime notEqualsText(1e300, f32).?);
    try expect("validator: Dto.field_rules.x: equals(65520): 65520 is outside the finite range of f16; the rule would never pass", comptime equalsText(65520, f16).?);
    try expect("validator: Dto.field_rules.x: equals(1e-50): 1e-50 rounds to 0 in f32", comptime equalsText(1e-50, f32).?);
    try expect("validator: Dto.field_rules.x: not_equals(1e-50): 1e-50 rounds to 0 in f32", comptime notEqualsText(1e-50, f32).?);
    try expect("validator: Dto.field_rules.x: equals(true): true is a bool, field is f64; use a number", comptime equalsText(true, f64).?);
    try expect("validator: Dto.field_rules.x: not_equals(true): true is a bool, field is f64; use a number", comptime notEqualsText(true, f64).?);
    try expect("validator: Dto.field_rules.x: equals(.admin): .admin is an enum tag, field is f32; use a number", comptime equalsText(.admin, f32).?);
    try expect("validator: Dto.field_rules.x: equals(\"1\"): \"1\" is a string, field is f16; use a number", comptime equalsText("1", f16).?);
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| {
        try std.testing.expectEqual(null, comptime equalsText(0.5, F));
        try std.testing.expectEqual(null, comptime equalsText(-0.0, F));
        try std.testing.expectEqual(null, comptime notEqualsText(2, F));
        try std.testing.expectEqual(null, comptime equalsText(0.1, F));
    }
    try std.testing.expectEqual(null, comptime equalsText(@as(f64, 0.1), f32));
    try std.testing.expectEqual(null, comptime equalsText(9007199254740993, f80));
    // A typed float narrower than the field must show the value it has there.
    try expect(
        "validator: Dto.field_rules.x: equals(0.1): 0.1 is a float (f32), 0.10000000149011612 in f64; write it as a literal or as f64",
        comptime equalsText(@as(f32, 0.1), f64).?,
    );
    try expect(
        "validator: Dto.field_rules.x: not_equals(0.1): 0.1 is a float (f32), 0.10000000149011612 in f64; write it as a literal or as f64",
        comptime notEqualsText(@as(f32, 0.1), f64).?,
    );
    try std.testing.expectEqual(null, comptime equalsText(@as(f32, 0.5), f64));
}

test "on a bool field the parameter of equals and notEquals is true or false; on a string field, a string" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: Dto.field_rules.x: equals(1): 1 is an integer, field is bool; use true or false", comptime equalsText(1, bool).?);
    try expect("validator: Dto.field_rules.x: not_equals(1): 1 is an integer, field is bool; use true or false", comptime notEqualsText(1, bool).?);
    try expect("validator: Dto.field_rules.x: equals(\"true\"): \"true\" is a string, field is bool; use true or false", comptime equalsText("true", bool).?);
    try expect("validator: Dto.field_rules.x: equals(.yes): .yes is an enum tag, field is bool; use true or false", comptime equalsText(.yes, bool).?);
    try expect("validator: Dto.field_rules.x: equals(0.5): 0.5 is a float (comptime_float), field is bool; use true or false", comptime equalsText(0.5, bool).?);
    try expect("validator: Dto.field_rules.x: equals(5): 5 is an integer, field is []const u8; use a string", comptime equalsText(5, []const u8).?);
    try expect("validator: Dto.field_rules.x: not_equals(5): 5 is an integer, field is []const u8; use a string", comptime notEqualsText(5, []const u8).?);
    try expect("validator: Dto.field_rules.x: equals(0.5): 0.5 is a float (comptime_float), field is [:0]const u8; use a string", comptime equalsText(0.5, [:0]const u8).?);
    try expect("validator: Dto.field_rules.x: equals(true): true is a bool, field is []u8; use a string", comptime equalsText(true, []u8).?);
    try expect("validator: Dto.field_rules.x: equals(.admin): .admin is an enum tag, field is [:0]u8; use a string", comptime equalsText(.admin, [:0]u8).?);
    try std.testing.expectEqual(null, comptime equalsText(true, bool));
    try std.testing.expectEqual(null, comptime notEqualsText(false, bool));
    inline for (.{ []const u8, []u8, [:0]const u8, [:0]u8 }) |S| {
        try std.testing.expectEqual(null, comptime equalsText("a", S));
        try std.testing.expectEqual(null, comptime notEqualsText(@as([]const u8, "root"), S));
    }
}

test "on an enum field the parameter of equals and notEquals is a tag of that enum" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: Dto.field_rules.x: equals(\"admin\"): \"admin\" is a string, field is common.Role; use a tag such as .admin", comptime equalsText("admin", Role).?);
    try expect("validator: Dto.field_rules.x: not_equals(\"admin\"): \"admin\" is a string, field is common.Role; use a tag such as .admin", comptime notEqualsText("admin", Role).?);
    try expect("validator: Dto.field_rules.x: equals(5): 5 is an integer, field is common.Open; use a tag such as .a", comptime equalsText(5, Open).?);
    try expect("validator: Dto.field_rules.x: equals(true): true is a bool, field is common.Sparse; use a tag such as .low", comptime equalsText(true, Sparse).?);
    try expect("validator: Dto.field_rules.x: equals(.root): common.Role has no tag root; tags: admin, user, guest", comptime equalsText(.root, Role).?);
    try expect("validator: Dto.field_rules.x: not_equals(.root): common.Role has no tag root; tags: admin, user, guest", comptime notEqualsText(.root, Role).?);
    try expect("validator: Dto.field_rules.x: equals(.red): .red is a tag of common.Color, the field is common.Role", comptime equalsText(Color.red, Role).?);
    try expect("validator: Dto.field_rules.x: not_equals(.red): .red is a tag of common.Color, the field is common.Role", comptime notEqualsText(Color.red, Role).?);
    try expect("validator: Dto.field_rules.x: equals(.admin): .admin is a tag of common.Color, the field is common.Role", comptime equalsText(Color.admin, Role).?);
    try expect("validator: Dto.field_rules.x: equals(.only): common.Only has a single tag; the rule would always pass", comptime equalsText(.only, Only).?);
    try expect("validator: Dto.field_rules.x: not_equals(.only): common.Only has a single tag; the rule would never pass", comptime notEqualsText(.only, Only).?);
    // An enum without named tags has no tag to suggest or to list.
    try expect("validator: Dto.field_rules.x: equals(\"a\"): \"a\" is a string, field is common.NoTags", comptime equalsText("a", NoTags).?);
    try expect("validator: Dto.field_rules.x: equals(.a): common.NoTags has no tag a", comptime equalsText(.a, NoTags).?);
    // Tags are written as Zig source writes them.
    try expect("validator: Dto.field_rules.x: equals(\"x\"): \"x\" is a string, field is common.Quoted; use a tag such as .@\"error\"", comptime equalsText("x", Quoted).?);
    try expect("validator: Dto.field_rules.x: equals(.x): common.Quoted has no tag x; tags: @\"error\", @\"a\\nb\", plain", comptime equalsText(.x, Quoted).?);
    try std.testing.expectEqual(null, comptime equalsText(.admin, Role));
    try std.testing.expectEqual(null, comptime notEqualsText(Role.guest, Role));
    try std.testing.expectEqual(null, comptime equalsText(.b, Open));
    // A non-exhaustive single-tag enum also holds unnamed values.
    try std.testing.expectEqual(null, comptime equalsText(.only, OpenOne));
    try std.testing.expectEqual(null, comptime notEqualsText(.only, OpenOne));
    try std.testing.expectEqual(null, comptime equalsText(.high, Sparse));
}

test "equals and notEquals on a field that is not a number, a bool, an enum or a string name the field type" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: ";
    const expects = " expects a number, a bool, an enum or a string, field is ";
    try expect(head ++ "equals" ++ expects ++ "[]const u32; use v.each(v.equals(5))", comptime equalsText(5, []const u32).?);
    try expect(head ++ "not_equals" ++ expects ++ "[]const u32; use v.each(v.notEquals(5))", comptime notEqualsText(5, []const u32).?);
    try expect(head ++ "equals" ++ expects ++ "[4]u8; [N]u8 is an array of numbers, not a string: use []const u8", comptime equalsText("abcd", [4]u8).?);
    try expect(head ++ "not_equals" ++ expects ++ "[4]u8; [N]u8 is an array of numbers, not a string: use []const u8", comptime notEqualsText("abcd", [4]u8).?);
    try expect(head ++ "equals" ++ expects ++ "common.Item", comptime equalsText(5, Item).?);
    try expect(head ++ "not_equals" ++ expects ++ "common.Item", comptime notEqualsText(5, Item).?);
    // The each hint follows the kind of the parameter.
    try expect(head ++ "equals" ++ expects ++ "[]const []const u8; use v.each(v.equals(\"a\"))", comptime equalsText("a", []const []const u8).?);
    try expect(head ++ "equals" ++ expects ++ "[2]common.Role; use v.each(v.equals(.admin))", comptime equalsText(.admin, [2]Role).?);
    try expect(head ++ "equals" ++ expects ++ "[]const ?bool; use v.each(v.equals(true))", comptime equalsText(true, []const ?bool).?);
    try expect(head ++ "equals" ++ expects ++ "[4]u8; use v.each(v.equals(5))", comptime equalsText(5, [4]u8).?);
    try expect(head ++ "equals" ++ expects ++ "[]const []const u8", comptime equalsText(5, []const []const u8).?);
    try expect(head ++ "equals" ++ expects ++ "*const u8", comptime equalsText(5, *const u8).?);
    try expect(head ++ "equals" ++ expects ++ "[]volatile u8; volatile, allowzero and under-aligned slices are neither strings nor lists", comptime equalsText("a", []volatile u8).?);
}

test "an uncalled equals or notEquals gets an example call" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: Dto.field_rules.x: equals must be called, e.g. v.equals(true)", comptime uncalledText("equals", @TypeOf(equals)));
    try expect("validator: Dto.field_rules.x: notEquals must be called, e.g. v.notEquals(0)", comptime uncalledText("notEquals", @TypeOf(notEquals)));
}

test "equals compares integers and bools exactly, floats in the field type after the finite precondition, tags by name and strings by bytes" {
    try expectOutcome(.pass, equals(5), @as(u8, 5));
    try expectOutcome(.fail, equals(5), @as(u8, 6));
    try expectOutcome(.pass, equals(std.math.maxInt(u128)), @as(u128, std.math.maxInt(u128)));
    try expectOutcome(.pass, equals(std.math.minInt(i128)), @as(i128, std.math.minInt(i128)));
    try expectOutcome(.fail, equals(std.math.minInt(i128)), @as(i128, std.math.maxInt(i128)));
    try expectOutcome(.pass, equals(@as(u8, 7)), @as(i64, 7));
    try expectOutcome(.pass, equals(9007199254740993), @as(u64, 9007199254740993));
    try expectOutcome(.fail, equals(9007199254740993), @as(u64, 9007199254740992));
    try expectOutcome(.pass, equals(0), @as(f64, -0.0));
    try expectOutcome(.pass, equals(-0.0), @as(f16, 0.0));
    try expectOutcome(.pass, equals(0.1), @as(f32, 0.1));
    try expectOutcome(.fail, equals(0.1), std.math.nextAfter(f32, 0.1, 1));
    try expectOutcome(.precondition, equals(0.5), std.math.nan(f32));
    try expectOutcome(.precondition, equals(0.5), -std.math.inf(f128));
    try expectOutcome(.pass, equals(true), true);
    try expectOutcome(.fail, equals(true), false);
    try expectOutcome(.pass, equals(.b), Open.b);
    try expectOutcome(.fail, equals(.b), @as(Open, @fromBackingInt(200)));
    try expectOutcome(.pass, equals(Role.guest), Role.guest);
    try expectOutcome(.pass, equals("abc"), @as([]const u8, "abc"));
    try expectOutcome(.fail, equals("abc"), @as([]const u8, "ABC"));
    try expectOutcome(.fail, equals("abc"), @as([:0]const u8, "abcd"));
}

test "notEquals passes what equals fails; NaN and infinities are the precondition, not a pass" {
    try expectOutcome(.fail, notEquals(5), @as(i8, 5));
    try expectOutcome(.pass, notEquals(5), @as(i8, -5));
    try expectOutcome(.fail, notEquals(0), @as(f16, -0.0));
    try expectOutcome(.pass, notEquals(0), std.math.floatTrueMin(f64));
    try expectOutcome(.precondition, notEquals(0), std.math.nan(f64));
    try expectOutcome(.precondition, notEquals(0), std.math.inf(f64));
    try expectOutcome(.pass, notEquals(.a), @as(Open, @fromBackingInt(200)));
    try expectOutcome(.fail, notEquals(.a), Open.a);
    try expectOutcome(.pass, notEquals("root"), @as([]const u8, ""));
    try expectOutcome(.fail, notEquals("root"), @as([]const u8, "root"));
    try expectOutcome(.fail, notEquals(false), false);
}

test "empty has its documented code and message and no precondition" {
    try std.testing.expectEqualStrings("validation.empty", empty.code);
    try std.testing.expectEqualStrings("must be empty", empty.message);
    try std.testing.expectEqual(core.Kind.empty, empty.kind);
    try std.testing.expectEqual(null, empty.args);
    try std.testing.expectEqual(0, empty.params.len);
    try std.testing.expectEqual(null, empty.precondition);
}

test "empty counts the bytes of a string without decoding them and the items of a slice, null items included" {
    try expectOutcome(.pass, empty, @as([]const u8, ""));
    try expectOutcome(.fail, empty, @as([]const u8, " "));
    try expectOutcome(.fail, empty, @as([]const u8, "\x00"));
    try expectOutcome(.fail, empty, @as([]const u8, "\xff"));
    try expectOutcome(.fail, empty, @as([]const u8, "\u{200b}"));
    try expectOutcome(.pass, empty, @as([:0]const u8, ""));
    try expectOutcome(.pass, empty, @as([]const u32, &.{}));
    try expectOutcome(.fail, empty, @as([]const u32, &.{0}));
    try expectOutcome(.fail, empty, @as([]const ?u32, &.{null}));
}

test "empty and notEmpty on a fixed-size array or a type without a length are errors" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: Dto.field_rules.x: empty on [3]u32 is always false: the length of an array is fixed", comptime lengthText(empty, [3]u32).?);
    try expect("validator: Dto.field_rules.x: empty on [0]u32 is always true: the length of an array is fixed", comptime lengthText(empty, [0]u32).?);
    try expect(
        "validator: Dto.field_rules.x: empty on [4]u8 is always false: the length of an array is fixed; [N]u8 is an array of numbers, not a string: use []const u8",
        comptime lengthText(empty, [4]u8).?,
    );
    try expect("validator: Dto.field_rules.x: empty expects a string or a slice, field is u32", comptime lengthText(empty, u32).?);
    try expect("validator: Dto.field_rules.x: not_empty on [3]u32 is always true: the length of an array is fixed", comptime lengthText(notEmpty, [3]u32).?);
    try expect("validator: Dto.field_rules.x: not_empty expects a string or a slice, field is bool", comptime lengthText(notEmpty, bool).?);
    inline for (.{ []const u8, []u8, [:0]const u8, [:0]u8, []const u32, []u32, []const ?u32, []const []const u8 }) |T| {
        try std.testing.expectEqual(null, comptime lengthText(empty, T));
        try std.testing.expectEqual(null, comptime lengthText(notEmpty, T));
    }
}

/// The error of the call `oneOf(values)` or `noneOf(values)`, or null.
fn oneOfCallText(comptime values: anytype) ?[]const u8 {
    return core.listProblem("oneOf", values, one_of_list);
}

fn noneOfCallText(comptime values: anytype) ?[]const u8 {
    return core.listProblem("noneOf", values, none_of_list);
}

/// The declaration error of `oneOf(values)` or `noneOf(values)` on a field
/// of type `T`, or null.
fn oneOfText(comptime values: anytype, comptime T: type) ?[]const u8 {
    return membershipProblem(&oneOf(values), values, core.analyzeList("oneOf", values, one_of_list), T, test_where);
}

fn noneOfText(comptime values: anytype, comptime T: type) ?[]const u8 {
    return membershipProblem(&noneOf(values), values, core.analyzeList("noneOf", values, none_of_list), T, test_where);
}

/// Ten values whose list is longer than compile errors show it.
const ten_values = .{ "value_000", "value_001", "value_002", "value_003", "value_004", "value_005", "value_006", "value_007", "value_008", "value_009" };
const ten_values_cut = ".{ \"value_000\", \"value_001\", \"value_002\", \"value_003\", \"value_004\", ... }";

test "oneOf and noneOf have their documented codes, messages, parameters and no precondition" {
    const t = std.testing;
    const allowed = oneOf(.{ "a", "b" });
    try t.expectEqual(core.Kind.one_of, allowed.kind);
    try t.expectEqualStrings("validation.one_of", allowed.code);
    try t.expectEqualStrings("must be one of: a, b", allowed.message);
    try t.expectEqualStrings(".{ \"a\", \"b\" }", allowed.args.?);
    try t.expectEqual(1, allowed.params.len);
    try t.expectEqualStrings("values", allowed.params[0].name);
    try t.expectEqualStrings("a, b", allowed.params[0].text);
    try t.expectEqual(2, allowed.params[0].value.list.len);
    try t.expectEqual(null, allowed.precondition);
    try t.expectEqualStrings("must be admin", oneOf(.{.admin}).message);
    try t.expectEqualStrings(".{.admin}", oneOf(.{.admin}).args.?);

    const forbidden = noneOf(.{ "admin", "root" });
    try t.expectEqual(core.Kind.none_of, forbidden.kind);
    try t.expectEqualStrings("validation.none_of", forbidden.code);
    try t.expectEqualStrings("must not be one of: admin, root", forbidden.message);
    try t.expectEqualStrings("values", forbidden.params[0].name);
    try t.expectEqualStrings("admin, root", forbidden.params[0].text);
    try t.expectEqual(null, forbidden.precondition);
    try t.expectEqualStrings("must not be root", noneOf(.{"root"}).message);
}

test "oneOf and noneOf show the values as written: strings escaped, the empty string as \"\", tags by name, integers in decimal" {
    const expect = std.testing.expectEqualStrings;
    try expect("must be one of: \"\", x", oneOf(.{ "", "x" }).message);
    try expect("must be \\xe2\\x80\\xa8", oneOf(.{"\u{2028}"}).message);
    try expect("must be one of: tab\\there, имя", oneOf(.{ "tab\there", "имя" }).message);
    try expect("must be one of: user, admin", oneOf(.{ .user, Role.admin }).message);
    try expect("must not be one of: 0, -170141183460469231731687303715884105728", noneOf(.{ 0, std.math.minInt(i128) }).message);
    try expect("must be one of: 1, 2, 3", oneOf([_]u8{ 1, 2, 3 }).message);
    try expect("must be one of: DE, FR", oneOf([_][]const u8{ "DE", "FR" }).message);
    try expect("one_of(.{ 1, 2, 3 })", comptime oneOf([_]u8{ 1, 2, 3 }).label());
    try expect("oneOf(" ++ ten_values_cut ++ ")", comptime oneOf(ten_values).call());
}

test "oneOf and noneOf keep a default message of exactly 512 bytes and take the fallback above it" {
    const t = std.testing;
    // "must be one of: " is 16 bytes and ", " 2.
    const a: [247]u8 = @splat('a');
    const b: [247]u8 = @splat('b');
    const b_over: [248]u8 = @splat('b');
    try t.expectEqual(512, oneOf(.{ &a, &b }).message.len);
    try t.expectEqualStrings("must be one of: " ++ a ++ ", " ++ b, oneOf(.{ &a, &b }).message);
    try t.expectEqualStrings("must be one of the allowed values", oneOf(.{ &a, &b_over }).message);
    // "must not be one of: " is 20 bytes.
    const c: [245]u8 = @splat('c');
    const d: [245]u8 = @splat('d');
    const d_over: [246]u8 = @splat('d');
    try t.expectEqual(512, noneOf(.{ &c, &d }).message.len);
    try t.expectEqualStrings("must not be one of the forbidden values", noneOf(.{ &c, &d_over }).message);
    // One value: "must be " is 8 bytes, "must not be " 12.
    const one: [504]u8 = @splat('s');
    const one_over: [505]u8 = @splat('s');
    try t.expectEqualStrings("must be " ++ one, oneOf(.{&one}).message);
    try t.expectEqualStrings("must be one of the allowed values", oneOf(.{&one_over}).message);
    const one_not: [500]u8 = @splat('s');
    const one_not_over: [501]u8 = @splat('s');
    try t.expectEqualStrings("must not be " ++ one_not, noneOf(.{&one_not}).message);
    try t.expectEqualStrings("must not be one of the forbidden values", noneOf(.{&one_not_over}).message);
    // Only the message falls back: the parameter keeps every value.
    try t.expectEqualStrings(a ++ ", " ++ b_over, oneOf(.{ &a, &b_over }).params[0].text);
}

test "oneOf and noneOf take a tuple or an array of strings, enum tags or integers, none listed twice" {
    const expect = std.testing.expectEqualStrings;
    const expected_list = "expected a tuple or an array of values, e.g. .{ \"a\", \"b\" }, got ";
    const pointer_hint = "; pass the array itself, not a pointer to it";
    const allowed = [_][]const u8{ "a", "b" };
    try expect("validator: oneOf(.{}): the list is empty", comptime oneOfCallText(.{}).?);
    try expect("validator: noneOf(.{}): the list is empty", comptime noneOfCallText(.{}).?);
    try expect("validator: oneOf(.{}): the list is empty", comptime oneOfCallText([0]u8{}).?);
    try expect("validator: oneOf(\"a\"): " ++ expected_list ++ "*const [1:0]u8", comptime oneOfCallText("a").?);
    try expect("validator: noneOf(\"a\"): " ++ expected_list ++ "*const [1:0]u8", comptime noneOfCallText("a").?);
    try expect("validator: oneOf(5): " ++ expected_list ++ "comptime_int", comptime oneOfCallText(5).?);
    try expect("validator: oneOf(...): " ++ expected_list ++ "[]const []const u8", comptime oneOfCallText(@as([]const []const u8, &allowed)).?);
    try expect("validator: oneOf(...): " ++ expected_list ++ "@TypeOf(null)", comptime oneOfCallText(null).?);
    try expect("validator: oneOf(...): " ++ expected_list ++ "*const [2][]const u8" ++ pointer_hint, comptime oneOfCallText(&allowed).?);
    try expect("validator: noneOf(...): " ++ expected_list ++ "*const [2][]const u8" ++ pointer_hint, comptime noneOfCallText(&allowed).?);
    try expect("validator: oneOf(...): " ++ expected_list ++ "*const [2]u32" ++ pointer_hint, comptime oneOfCallText(&[_]u32{ 1, 2 }).?);
    // &.{ ... } is named by what it is, not by its generated type.
    const tuple_pointer = "a pointer to a tuple; drop the &: write .{ ... }, not &.{ ... }";
    try expect("validator: oneOf(...): " ++ expected_list ++ tuple_pointer, comptime oneOfCallText(&.{ "a", "b" }).?);
    try expect("validator: noneOf(...): " ++ expected_list ++ tuple_pointer, comptime noneOfCallText(&.{ 1, 2, 3 }).?);
    try expect("validator: oneOf(...): " ++ expected_list ++ tuple_pointer, comptime oneOfCallText(&.{}).?);
    try expect("validator: oneOf(.{ \"a\", \"b\", \"a\" }): \"a\" is listed twice", comptime oneOfCallText(.{ "a", "b", "a" }).?);
    try expect("validator: noneOf(.{ \"root\", \"admin\", \"root\" }): \"root\" is listed twice", comptime noneOfCallText(.{ "root", "admin", "root" }).?);
    try expect("validator: oneOf(.{ 1, 1 }): 1 is listed twice", comptime oneOfCallText(.{ 1, @as(u8, 1) }).?);
    try expect("validator: oneOf(.{ .admin, .admin }): .admin is listed twice", comptime oneOfCallText(.{ .admin, Role.admin }).?);
    try expect("validator: oneOf(" ++ ten_values_cut ++ "): \"value_000\" is listed twice", comptime oneOfCallText(ten_values ++ .{"value_000"}).?);
    try expect("validator: oneOf(.{ \"a\", .b }): the list mixes strings and enum tags", comptime oneOfCallText(.{ "a", .b }).?);
    try expect("validator: noneOf(.{ .admin, \"root\" }): the list mixes enum tags and strings", comptime noneOfCallText(.{ .admin, "root" }).?);
    try expect("validator: oneOf(.{ 1, \"a\" }): the list mixes integers and strings", comptime oneOfCallText(.{ 1, "a" }).?);
    try expect("validator: oneOf(.{ 0.5, 1.5 }): floats cannot be listed: exact float equality is fragile", comptime oneOfCallText(.{ 0.5, 1.5 }).?);
    try expect("validator: noneOf(.{ 0.5, 1.5 }): floats cannot be listed: exact float equality is fragile", comptime noneOfCallText(.{ 0.5, 1.5 }).?);
    // A float that holds an integer is shown as one, as compile errors show floats.
    try expect("validator: oneOf(.{ 1, 2 }): floats cannot be listed: exact float equality is fragile", comptime oneOfCallText(.{ 1, 2.0 }).?);
    try expect("validator: oneOf(.{true}): bools cannot be listed; use v.equals or v.notEquals", comptime oneOfCallText(.{true}).?);
    try expect("validator: noneOf(.{true}): bools cannot be listed; use v.equals or v.notEquals", comptime noneOfCallText(.{true}).?);
    try expect("validator: noneOf(.{ true, false }): bools cannot be listed; use v.equals or v.notEquals", comptime noneOfCallText([_]bool{ true, false }).?);
    try expect("validator: oneOf(.{...}): cannot list a value of type @TypeOf(null)", comptime oneOfCallText(.{null}).?);
    try expect("validator: noneOf(.{...}): cannot list a value of type @TypeOf(null)", comptime noneOfCallText(.{null}).?);
    try expect("validator: oneOf(.{ \"a\", ... }): cannot list a value of type ?u8", comptime oneOfCallText(.{ "a", @as(?u8, 1) }).?);
    try expect("validator: oneOf(.{...}): cannot list a value of type common.Item", comptime oneOfCallText(.{Item{ .id = 1 }}).?);
    try expect("validator: oneOf(.{\"\\xff\"}): \"\\xff\" is not valid UTF-8", comptime oneOfCallText(.{"\xff"}).?);
    try expect("validator: noneOf(.{ \"ok\", \"\\xc0\\x80\" }): \"\\xc0\\x80\" is not valid UTF-8", comptime noneOfCallText(.{ "ok", "\xc0\x80" }).?);
    try expect("validator: oneOf(.{ .a, @fromBackingInt(7) }): @fromBackingInt(7) is not a named tag of common.Open", comptime oneOfCallText(.{ .a, @as(Open, @fromBackingInt(7)) }).?);
    try expect("validator: noneOf(.{ .a, @fromBackingInt(7) }): @fromBackingInt(7) is not a named tag of common.Open", comptime noneOfCallText(.{ .a, @as(Open, @fromBackingInt(7)) }).?);
    try expect("validator: noneOf(.{ \"\", \"root\" }): the empty string cannot be listed; use v.notEmpty", comptime noneOfCallText(.{ "", "root" }).?);
    inline for (.{ .{ "a", "" }, .{"x"}, allowed, .{ .admin, .user }, .{Role.guest}, .{ 1, 2, 3 }, [_]u8{ 1, 2 }, .{ @as(u64, std.math.maxInt(u64)), 0 }, ten_values }) |values| {
        try std.testing.expectEqual(null, comptime oneOfCallText(values));
    }
    try std.testing.expectEqual(null, comptime noneOfCallText(.{ "admin", "root" }));
}

test "the values listed by oneOf and noneOf are of the field's kind: strings, enum tags or integers" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: ";
    const strings = "; list strings instead: .{ \"a\", ... }";
    const tags = "; list the enum's tags instead: .{ .tag, ... }";
    const integers = "; list integers instead: .{ 1, ... }";
    try expect(head ++ "one_of(.{\"admin\"}) lists strings, field is common.Role" ++ tags, comptime oneOfText(.{"admin"}, Role).?);
    try expect(head ++ "one_of(.{.a}) lists enum tags, field is []const u8" ++ strings, comptime oneOfText(.{.a}, []const u8).?);
    try expect(head ++ "one_of(.{\"1\"}) lists strings, field is u32" ++ integers, comptime oneOfText(.{"1"}, u32).?);
    try expect(head ++ "one_of(.{ 1, 2 }) lists integers, field is []const u8" ++ strings, comptime oneOfText(.{ 1, 2 }, []const u8).?);
    try expect(head ++ "one_of(.{ 1, 2 }) lists integers, field is common.Role" ++ tags, comptime oneOfText(.{ 1, 2 }, Role).?);
    try expect(head ++ "one_of(.{.a}) lists enum tags, field is u32" ++ integers, comptime oneOfText(.{.a}, u32).?);
    try expect(head ++ "none_of(.{\"admin\"}) lists strings, field is common.Role" ++ tags, comptime noneOfText(.{"admin"}, Role).?);
    try expect(head ++ "none_of(.{.a}) lists enum tags, field is []const u8" ++ strings, comptime noneOfText(.{.a}, []const u8).?);
    try expect(head ++ "none_of(.{\"1\"}) lists strings, field is u32" ++ integers, comptime noneOfText(.{"1"}, u32).?);
    try expect(head ++ "none_of(.{ 1, 2 }) lists integers, field is []const u8" ++ strings, comptime noneOfText(.{ 1, 2 }, []const u8).?);
    try expect(head ++ "none_of(.{ 1, 2 }) lists integers, field is common.Role" ++ tags, comptime noneOfText(.{ 1, 2 }, Role).?);
    try expect(head ++ "none_of(.{.a}) lists enum tags, field is u32" ++ integers, comptime noneOfText(.{.a}, u32).?);
    // The call is cut after 72 bytes.
    try expect(head ++ "one_of(" ++ ten_values_cut ++ ") lists strings, field is common.Role" ++ tags, comptime oneOfText(ten_values, Role).?);
    // An enum without named tags has no tag to list instead.
    try expect(head ++ "none_of(.{ 1, 2 }) lists integers, field is common.NoTags", comptime noneOfText(.{ 1, 2 }, NoTags).?);
    try expect(head ++ "one_of(.{\"a\"}) lists strings, field is common.NoTags", comptime oneOfText(.{"a"}, NoTags).?);
    inline for (.{ []const u8, []u8, [:0]const u8, [:0]u8 }) |S| {
        try std.testing.expectEqual(null, comptime oneOfText(.{ "a", "" }, S));
        try std.testing.expectEqual(null, comptime noneOfText(.{"root"}, S));
    }
}

test "on an enum field oneOf and noneOf list tags of that enum; noneOf may not list every tag of an exhaustive enum" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: ";
    try expect(head ++ "one_of(.{ .admin, .root }): common.Role has no tag root; tags: admin, user, guest", comptime oneOfText(.{ .admin, .root }, Role).?);
    try expect(head ++ "none_of(.{ .admin, .root }): common.Role has no tag root; tags: admin, user, guest", comptime noneOfText(.{ .admin, .root }, Role).?);
    try expect(head ++ "one_of(.{.red}): .red is a tag of common.Color, the field is common.Role", comptime oneOfText(.{Color.red}, Role).?);
    try expect(head ++ "none_of(.{.red}): .red is a tag of common.Color, the field is common.Role", comptime noneOfText(.{Color.red}, Role).?);
    try expect(head ++ "one_of(.{ .user, .admin }): .admin is a tag of common.Color, the field is common.Role", comptime oneOfText(.{ .user, Color.admin }, Role).?);
    try expect(head ++ "none_of(.{ .admin, .user, .guest }) lists every tag of common.Role; no value would pass", comptime noneOfText(.{ .admin, .user, .guest }, Role).?);
    try expect(head ++ "none_of(.{.only}) lists every tag of common.Only; no value would pass", comptime noneOfText(.{.only}, Only).?);
    try expect(head ++ "none_of(.{ .guest, .user, .admin }) lists every tag of common.Role; no value would pass", comptime noneOfText([_]Role{ .guest, .user, .admin }, Role).?);
    // Tags are written as Zig source writes them, in the call and in the message.
    try expect(
        head ++ "none_of(.{ .@\"error\", .@\"a\\nb\", .plain }) lists every tag of common.Quoted; no value would pass",
        comptime noneOfText(.{ .@"error", .@"a\nb", .plain }, Quoted).?,
    );
    try std.testing.expectEqualStrings("must be one of: error, a\\nb", oneOf(.{ .@"error", Quoted.@"a\nb" }).message);
    // oneOf may list every tag: it pins the set. A non-exhaustive enum may
    // list every named tag in noneOf: its unnamed values pass.
    try std.testing.expectEqual(null, comptime oneOfText(.{ .admin, .user, .guest }, Role));
    try std.testing.expectEqual(null, comptime noneOfText(.{ .a, .b }, Open));
    try std.testing.expectEqual(null, comptime noneOfText(.{.only}, OpenOne));
    try std.testing.expectEqual(null, comptime noneOfText(.{ .admin, .user }, Role));
    try std.testing.expectEqual(null, comptime oneOfText(.{ Role.guest, .admin }, Role));
    try std.testing.expectEqual(null, comptime oneOfText(.{.high}, Sparse));
}

test "on an integer field oneOf and noneOf list integers within the type; noneOf may not list every value" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: ";
    try expect(head ++ "one_of(.{ 1, 300 }): 300 is outside u8 (0..255); remove it", comptime oneOfText(.{ 1, 300 }, u8).?);
    try expect(head ++ "none_of(.{ 1, 300 }): 300 is outside u8 (0..255); remove it", comptime noneOfText(.{ 1, 300 }, u8).?);
    try expect(head ++ "one_of(.{ -1, 0 }): -1 is outside u64 (0..18446744073709551615); remove it", comptime oneOfText(.{ -1, 0 }, u64).?);
    try expect(head ++ "none_of(.{ 0, 1 }) lists every value of u1; no value would pass", comptime noneOfText(.{ 0, 1 }, u1).?);
    try expect(head ++ "none_of(.{ -1, 0 }) lists every value of i1; no value would pass", comptime noneOfText(.{ -1, 0 }, i1).?);
    try expect(head ++ "none_of(.{0}) lists every value of u0; no value would pass", comptime noneOfText(.{0}, u0).?);
    try std.testing.expectEqual(null, comptime oneOfText(.{ 0, 1 }, u1));
    try std.testing.expectEqual(null, comptime noneOfText(.{1}, u1));
    try std.testing.expectEqual(null, comptime noneOfText(.{ 0, 1 }, u8));
    try std.testing.expectEqual(null, comptime oneOfText(.{ std.math.minInt(i128), std.math.maxInt(i128) }, i128));
    try std.testing.expectEqual(null, comptime oneOfText([_]u64{ std.math.maxInt(u64), 0 }, u64));
    try std.testing.expectEqual(null, comptime oneOfText(.{ @as(u8, 7), 9 }, i8));
}

test "oneOf and noneOf on a field that is not a string, an enum or an integer name the field type" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: ";
    const expects = " expects a string, an enum or an integer, field is ";
    try expect(head ++ "one_of" ++ expects ++ "f64", comptime oneOfText(.{ 1, 2 }, f64).?);
    try expect(head ++ "none_of" ++ expects ++ "f64", comptime noneOfText(.{ 1, 2 }, f64).?);
    try expect(head ++ "one_of" ++ expects ++ "bool", comptime oneOfText(.{"true"}, bool).?);
    try expect(head ++ "one_of" ++ expects ++ "common.Item", comptime oneOfText(.{.a}, Item).?);
    try expect(head ++ "one_of" ++ expects ++ "[]const []const u8; use v.each(v.oneOf(.{ \"a\", \"b\" }))", comptime oneOfText(.{ "a", "b" }, []const []const u8).?);
    try expect(head ++ "none_of" ++ expects ++ "[]const []const u8; use v.each(v.noneOf(.{ \"a\", \"b\" }))", comptime noneOfText(.{ "a", "b" }, []const []const u8).?);
    try expect(head ++ "one_of" ++ expects ++ "[2]u8; [N]u8 is an array of numbers, not a string: use []const u8", comptime oneOfText(.{"ab"}, [2]u8).?);
    try expect(head ++ "none_of" ++ expects ++ "[2]u8; [N]u8 is an array of numbers, not a string: use []const u8", comptime noneOfText(.{"ab"}, [2]u8).?);
    // The each hint follows the listed kind, and its call is cut after 72 bytes.
    try expect(head ++ "one_of" ++ expects ++ "[]const common.Role; use v.each(v.oneOf(.{.admin}))", comptime oneOfText(.{.admin}, []const Role).?);
    try expect(head ++ "one_of" ++ expects ++ "[4]u8; use v.each(v.oneOf(.{ 1, 2 }))", comptime oneOfText(.{ 1, 2 }, [4]u8).?);
    try expect(head ++ "none_of" ++ expects ++ "[]const ?u16; use v.each(v.noneOf(.{ 1, 2 }))", comptime noneOfText(.{ 1, 2 }, []const ?u16).?);
    try expect(head ++ "one_of" ++ expects ++ "[]const []const u8; use v.each(v.oneOf(" ++ ten_values_cut ++ "))", comptime oneOfText(ten_values, []const []const u8).?);
    try expect(head ++ "one_of" ++ expects ++ "[]const u32", comptime oneOfText(.{"a"}, []const u32).?);
}

test "an uncalled oneOf or noneOf gets an example call" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: Dto.field_rules.x: oneOf must be called, e.g. v.oneOf(.{ \"a\", \"b\" })", comptime uncalledText("oneOf", @TypeOf(oneOf)));
    try expect("validator: Dto.field_rules.x: noneOf must be called, e.g. v.noneOf(.{ \"a\", \"b\" })", comptime uncalledText("noneOf", @TypeOf(noneOf)));
}

test "oneOf passes a listed value: strings by bytes, tags by name, integers exactly in the field type" {
    try expectOutcome(.pass, oneOf(.{ "a", "b" }), @as([]const u8, "b"));
    try expectOutcome(.fail, oneOf(.{ "a", "b" }), @as([]const u8, "A"));
    try expectOutcome(.fail, oneOf(.{ "a", "b" }), @as([:0]const u8, "ab"));
    try expectOutcome(.pass, oneOf(.{ "", "a" }), @as([]const u8, ""));
    try expectOutcome(.pass, oneOf([_][]const u8{ "DE", "FR" }), @as([]const u8, "FR"));
    try expectOutcome(.pass, oneOf(.{ .user, .admin }), Role.admin);
    try expectOutcome(.fail, oneOf(.{ .user, .admin }), Role.guest);
    try expectOutcome(.fail, oneOf(.{ .a, .b }), @as(Open, @fromBackingInt(9)));
    try expectOutcome(.pass, oneOf(.{ 1, 300 }), @as(u16, 300));
    try expectOutcome(.pass, oneOf([_]u64{ std.math.maxInt(u64), 0 }), @as(u64, std.math.maxInt(u64)));
    try expectOutcome(.fail, oneOf(.{9007199254740993}), @as(u64, 9007199254740992));
    try expectOutcome(.pass, oneOf(.{ std.math.minInt(i128), 0 }), @as(i128, std.math.minInt(i128)));
}

test "noneOf passes a value that is not listed; an unnamed value of a non-exhaustive enum passes" {
    try expectOutcome(.fail, noneOf(.{ "admin", "root" }), @as([]const u8, "root"));
    try expectOutcome(.pass, noneOf(.{ "admin", "root" }), @as([]const u8, "Root"));
    try expectOutcome(.pass, noneOf(.{ "admin", "root" }), @as([]const u8, ""));
    try expectOutcome(.fail, noneOf(.{.guest}), Role.guest);
    try expectOutcome(.pass, noneOf(.{.guest}), Role.user);
    try expectOutcome(.pass, noneOf(.{ .a, .b }), @as(Open, @fromBackingInt(77)));
    try expectOutcome(.fail, noneOf(.{ 0, 13 }), @as(i32, 13));
    try expectOutcome(.pass, noneOf(.{0}), @as(u1, 1));
}
