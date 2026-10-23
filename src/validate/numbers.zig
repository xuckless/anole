// Copied from vkiryakov/zefir src/validator/numbers.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! Number rules: `min`, `max`, `range`, `positive`, `nonNegative`,
//! `negative`, `nonPositive`, `divisibleBy` and `finite`. On a float field
//! NaN, +inf and -inf fail every number rule but `finite` with the
//! precondition `validation.finite` / "must be a finite number"; `finite`
//! reports them by its own check, with the same code and message.
const std = @import("std");
const core = @import("core.zig");
const schema = @import("schema.zig");
const Rule = core.Rule;
const Outcome = core.Outcome;

// ------------------------------------------------------------------ min, max, range

/// `value >= bound`, compared in the field type. On an integer field the
/// bound is an integer within the type; on a float field a finite number,
/// rounded to the nearest value of the type, and an integer bound must be
/// exact in it. The message shows the bound as written: `v.min(0.5)` says
/// "must be at least 0.5". A typed float narrower than a float field keeps
/// its exact value there (`@as(f32, 0.1)` is 0.10000000149011612 in f64), so
/// one whose value would show otherwise is a compile error: write the bound
/// as a literal or in the field's type. Its placeholder is `{min}`.
pub fn min(comptime bound: anytype) Rule {
    @setEvalBranchQuota(core.eval_quota);
    if (callProblem("min", .{bound})) |text| @compileError(text);
    return boundRule(.min, bound, null, argsText(.{bound}), "must be at least " ++ core.renderValue(bound), &.{core.param("min", bound)});
}

/// `value <= bound`, compared in the field type; the bound as for `min`. Its
/// placeholder is `{max}`.
pub fn max(comptime bound: anytype) Rule {
    @setEvalBranchQuota(core.eval_quota);
    if (callProblem("max", .{bound})) |text| @compileError(text);
    return boundRule(.max, null, bound, argsText(.{bound}), "must be at most " ++ core.renderValue(bound), &.{core.param("max", bound)});
}

/// `lo <= value <= hi`, compared in the field type; each bound as for `min`,
/// and `lo` not greater than `hi` as written. Equal bounds accept one value:
/// "must be 7". Its placeholders are `{min}` and `{max}`.
pub fn range(comptime lo: anytype, comptime hi: anytype) Rule {
    @setEvalBranchQuota(core.eval_quota);
    if (callProblem("range", .{ lo, hi })) |text| @compileError(text);
    const message = if (lo == hi)
        "must be " ++ core.renderValue(lo)
    else
        "must be from " ++ core.renderValue(lo) ++ " to " ++ core.renderValue(hi);
    return boundRule(.range, lo, hi, argsText(.{ lo, hi }), message, &.{ core.param("min", lo), core.param("max", hi) });
}

/// The arguments of a call as compile errors show them: `1, 100`.
fn argsText(comptime args: anytype) []const u8 {
    var out: []const u8 = "";
    inline for (args, 0..) |arg, i| out = out ++ (if (i == 0) "" else ", ") ++ core.renderArg(arg);
    return out;
}

/// The error of the call `name(bounds...)` of a bound rule, or null: each
/// bound is a finite number, and range's min is not greater than its max.
fn callProblem(comptime name: []const u8, comptime bounds: anytype) ?[]const u8 {
    @setEvalBranchQuota(core.eval_quota);
    const head = "validator: " ++ name ++ "(" ++ argsText(bounds) ++ "): ";
    inline for (bounds) |bound| {
        switch (comptime core.valueKind(@TypeOf(bound))) {
            .int => {},
            .float => if (!core.isFiniteNumber(bound)) return head ++ core.renderArg(bound) ++ " is not finite",
            else => return head ++ "the bound must be a number, got " ++ @typeName(@TypeOf(bound)),
        }
    }
    if (bounds.len == 2) {
        if (bounds[0] > bounds[1]) return head ++ "min is greater than max";
    }
    return null;
}

/// A rule of `kind` that keeps values from `lo` to `hi`; null stands for no
/// bound on that side.
fn boundRule(comptime kind: core.Kind, comptime lo: anytype, comptime hi: anytype, comptime args: []const u8, comptime message: []const u8, comptime params: []const core.Param) Rule {
    const has_lo = @TypeOf(lo) != @TypeOf(null);
    const has_hi = @TypeOf(hi) != @TypeOf(null);
    const lower: []const core.Bound = if (has_lo) &.{.atLeast(.value, lo)} else &.{};
    const upper: []const core.Bound = if (has_hi) &.{.atMost(.value, hi)} else &.{};
    return core.define(kind, .{
        .message = message,
        .args = args,
        .params = params,
        .precondition = core.preconditions.finite,
        .bounds = lower ++ upper,
        .fits = struct {
            fn fits(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void {
                if (boundProblem(rule, lo, hi, T, where)) |text| @compileError(text);
            }
        }.fits,
        .eval = struct {
            fn eval(value: anytype) Outcome {
                const T = @TypeOf(value.*);
                if (comptime core.isFloat(T)) {
                    if (!std.math.isFinite(value.*)) return .precondition;
                }
                if (comptime has_lo) {
                    if (!(value.* >= comptime core.numberAs(T, lo))) return .fail;
                }
                if (comptime has_hi) {
                    if (!(value.* <= comptime core.numberAs(T, hi))) return .fail;
                }
                return .pass;
            }
        }.eval,
    });
}

/// The declaration error of a bound rule with the bounds `lo` and `hi`
/// (null for none) on the unwrapped field type `T`, or null: the field is a
/// number, each bound fits it (`numberParamProblem`), and on an integer
/// field not every value passes.
fn boundProblem(comptime rule: *const Rule, comptime lo: anytype, comptime hi: anytype, comptime T: type, comptime where: []const u8) ?[]const u8 {
    @setEvalBranchQuota(core.eval_quota);
    if (!core.isNumber(T)) return core.typeErrorText(rule, T, where, "a number", core.isNumber, null);
    const has_lo = @TypeOf(lo) != @TypeOf(null);
    const has_hi = @TypeOf(hi) != @TypeOf(null);
    if (has_lo) {
        if (core.numberParamProblem(lo, T, "use an integer bound", "")) |text| return core.ruleErrorText(rule, where, text);
    }
    if (has_hi) {
        if (core.numberParamProblem(hi, T, "use an integer bound", "")) |text| return core.ruleErrorText(rule, where, text);
    }
    if (@typeInfo(T) == .int) {
        const lo_vacuous = if (has_lo) lo == std.math.minInt(T) else true;
        const hi_vacuous = if (has_hi) hi == std.math.maxInt(T) else true;
        if (lo_vacuous and hi_vacuous) return core.ruleErrorText(rule, where, " is always true for " ++ @typeName(T) ++ "; remove it");
    }
    return null;
}

// ------------------------------------------------------------------ sign rules

/// `value > 0` on integers of any width and signedness and on floats: -0.0
/// fails, the smallest subnormal passes.
pub const positive: Rule = core.define(.positive, .{
    .message = "must be greater than 0",
    .precondition = core.preconditions.finite,
    .bounds = &.{.above(.value, 0)},
    .fits = struct {
        fn fits(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void {
            if (!core.isNumber(T)) core.typeError(rule, T, where, "a number", core.isNumber, null);
        }
    }.fits,
    .eval = signEval(.gt),
});

/// The run-time check of a sign rule: `value <op> 0`, after the finite
/// precondition on floats.
fn signEval(comptime op: std.math.CompareOperator) fn (anytype) Outcome {
    return struct {
        fn eval(value: anytype) Outcome {
            const T = @TypeOf(value.*);
            if (comptime core.isFloat(T)) {
                if (!std.math.isFinite(value.*)) return .precondition;
            }
            return core.passIf(std.math.compare(value.*, op, 0));
        }
    }.eval;
}

/// `value >= 0` on signed integers and floats: -0.0 passes. On an unsigned
/// field it is always true: a compile error.
pub const nonNegative: Rule = core.define(.non_negative, .{
    .message = "must not be negative",
    .precondition = core.preconditions.finite,
    .bounds = &.{.atLeast(.value, 0)},
    .fits = signFits,
    .eval = signEval(.gte),
});

/// `value < 0` on signed integers and floats: -0.0 fails, `minInt(T)`
/// passes. On an unsigned field it is always false: a compile error.
pub const negative: Rule = core.define(.negative, .{
    .message = "must be less than 0",
    .precondition = core.preconditions.finite,
    .bounds = &.{.below(.value, 0)},
    .fits = signFits,
    .eval = signEval(.lt),
});

/// `value <= 0` on signed integers and floats: -0.0 passes. On an unsigned
/// field only 0 would pass: a compile error with the hint `v.equals(0)`.
pub const nonPositive: Rule = core.define(.non_positive, .{
    .message = "must not be positive",
    .precondition = core.preconditions.finite,
    .bounds = &.{.atMost(.value, 0)},
    .fits = signFits,
    .eval = signEval(.lte),
});

fn signFits(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void {
    if (signProblem(rule, T, where)) |text| @compileError(text);
}

/// The declaration error of `nonNegative`, `negative` or `nonPositive` on
/// the unwrapped field type `T`, or null: the field is a signed integer or
/// a float.
fn signProblem(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) ?[]const u8 {
    return switch (@typeInfo(T)) {
        .int => |i| if (i.signedness == .signed) null else core.ruleErrorText(rule, where, switch (rule.kind) {
            .non_negative => " is always true for " ++ @typeName(T) ++ "; remove it",
            .negative => " is always false for " ++ @typeName(T) ++ " (an unsigned type)",
            .non_positive => " on " ++ @typeName(T) ++ " only accepts 0; " ++ core.hints.use_equals_zero,
            else => @compileError("validator: internal: " ++ @tagName(rule.kind) ++ " is not a sign rule"),
        }),
        .float => null,
        else => core.typeErrorText(rule, T, where, "a signed integer or a float", core.isSignedNumber, null),
    };
}

// ------------------------------------------------------------------ divisibleBy, finite

/// `value` is a multiple of `divisor`, an integer of at least 1. Integers:
/// exact at every width, `minInt(T)` included; on an integer field the
/// divisor is from 2 to the largest magnitude of the type. Floats:
/// `@rem(value, divisor) == 0` in the field type, which is exact, so
/// `divisibleBy(1)` on a float field means a whole number and -0.0 passes;
/// the divisor must be exact in the type.
pub fn divisibleBy(comptime divisor: anytype) Rule {
    @setEvalBranchQuota(core.eval_quota);
    if (divisorProblem(divisor)) |text| @compileError(text);
    const n: comptime_int = divisor;
    return core.define(.divisible_by, .{
        .message = "must be divisible by " ++ core.renderValue(n),
        .args = core.renderArg(divisor),
        .params = &.{core.param("divisor", n)},
        .precondition = core.preconditions.finite,
        .fits = struct {
            fn fits(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void {
                if (divisibleProblem(rule, n, T, where)) |text| @compileError(text);
            }
        }.fits,
        .eval = divisibleEval(n),
    });
}

/// The error of the call `divisibleBy(divisor)`, or null: the divisor is an
/// integer of at least 1.
fn divisorProblem(comptime divisor: anytype) ?[]const u8 {
    @setEvalBranchQuota(core.eval_quota);
    const D = @TypeOf(divisor);
    const head = "validator: divisibleBy(" ++ core.renderArg(divisor) ++ "): ";
    switch (comptime core.valueKind(D)) {
        .int => {},
        .float => return head ++ "the divisor must be an integer, got " ++ @typeName(D) ++
            "; fractional divisors are inexact on binary floats: count whole units (e.g. cents)",
        else => return head ++ "the divisor must be an integer, got " ++ @typeName(D),
    }
    const n: comptime_int = divisor;
    if (n == 0) return head ++ "division by zero; no value would pass";
    if (n < 0) return head ++ "the divisor is negative; use v.divisibleBy(" ++ core.renderValue(-n) ++ ")";
    return null;
}

/// The declaration error of `divisibleBy(n)` on the unwrapped field type
/// `T`, or null. An integer field takes a divisor from 2 (1 divides every
/// integer) to the largest magnitude of the type (above it only 0 would
/// pass); a float field takes a divisor it holds exactly.
fn divisibleProblem(comptime rule: *const Rule, comptime n: comptime_int, comptime T: type, comptime where: []const u8) ?[]const u8 {
    @setEvalBranchQuota(core.eval_quota);
    switch (@typeInfo(T)) {
        .int => {
            if (n == 1) return core.ruleErrorText(rule, where, " is always true for " ++ @typeName(T) ++ "; remove it");
            if (n > @max(std.math.maxInt(T), -std.math.minInt(T)))
                return core.ruleErrorText(rule, where, " on " ++ @typeName(T) ++ " (" ++ core.intRange(T) ++ "): only 0 would pass; " ++ core.hints.use_equals_zero);
            return null;
        },
        .float => return if (core.numberParamProblem(n, T, "use an integer", "")) |text| core.ruleErrorText(rule, where, text) else null,
        else => return core.typeErrorText(rule, T, where, "a number", core.isNumber, null),
    }
}

/// The run-time check of `divisibleBy(n)`, after the finite precondition on
/// floats. `n` is at least 2 on integer fields, so `@rem` cannot divide by
/// zero or overflow.
fn divisibleEval(comptime n: comptime_int) fn (anytype) Outcome {
    return struct {
        fn eval(value: anytype) Outcome {
            const T = @TypeOf(value.*);
            const x = value.*;
            switch (@typeInfo(T)) {
                .int => {
                    if (comptime n <= std.math.maxInt(T)) return core.passIf(@rem(x, @as(T, n)) == 0);
                    // n is -minInt(T), one past maxInt(T) of a signed T: its
                    // only multiples in the type are 0 and minInt(T).
                    return core.passIf(x == 0 or x == std.math.minInt(T));
                },
                .float => {
                    if (!std.math.isFinite(x)) return .precondition;
                    return core.passIf(@rem(x, comptime core.numberAs(T, n)) == 0);
                },
                else => @compileError("validator: internal: divisibleBy's eval was instantiated for a type its fits rejected"),
            }
        }
    }.eval;
}

/// Not NaN, +inf or -inf, on float fields; -0.0, subnormals and the largest
/// values pass. Its failure is its own check, so a `.withMessage` on it
/// applies: put it first to give NaN and infinities a message of your own.
/// On an integer field it is always true: a compile error.
pub const finite: Rule = core.define(.finite, .{
    .message = "must be a finite number",
    .fits = struct {
        fn fits(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void {
            if (finiteProblem(rule, T, where)) |text| @compileError(text);
        }
    }.fits,
    .eval = struct {
        fn eval(value: anytype) Outcome {
            return core.passIf(std.math.isFinite(value.*));
        }
    }.eval,
});

/// The declaration error of `finite` on the unwrapped field type `T`, or
/// null: the field is a float.
fn finiteProblem(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) ?[]const u8 {
    return switch (@typeInfo(T)) {
        .float => null,
        .int => core.ruleErrorText(rule, where, " is always true for " ++ @typeName(T) ++ "; remove it"),
        else => core.typeErrorText(rule, T, where, "a float", core.isFloat, null),
    };
}

// ------------------------------------------------------------------ schema

/// The JSON Schema keywords of a rule of this file on the unwrapped field
/// type `T`, for `v.schemaOf`; all exact. A bound is written as given: on a
/// float field the rule compares in the field's type, which may differ in
/// the last bit.
pub fn schemaOf(comptime rule: Rule, comptime T: type) schema.RuleSchema {
    return switch (rule.kind) {
        .min => schema.exact(&.{schema.keyword("minimum", schema.param(rule.params[0]))}),
        .max => schema.exact(&.{schema.keyword("maximum", schema.param(rule.params[0]))}),
        .range => schema.exact(&.{ schema.keyword("minimum", schema.param(rule.params[0])), schema.keyword("maximum", schema.param(rule.params[1])) }),
        // An unsigned field has no value between 0 and 1.
        .positive => schema.exact(&.{if (@typeInfo(T) == .int and @typeInfo(T).int.signedness == .unsigned) schema.count("minimum", 1) else schema.count("exclusiveMinimum", 0)}),
        .non_negative => schema.exact(&.{schema.count("minimum", 0)}),
        .negative => schema.exact(&.{schema.count("exclusiveMaximum", 0)}),
        .non_positive => schema.exact(&.{schema.count("maximum", 0)}),
        .divisible_by => schema.exact(&.{schema.keyword("multipleOf", schema.param(rule.params[0]))}),
        // JSON has no NaN and no infinity.
        .finite => schema.exact(&.{}),
        else => unreachable,
    };
}

/// The arguments the hints show for an uncalled constructor of this file:
/// `min must be called, e.g. v.min(0)`.
pub const call_examples = .{ .min = "0", .max = "100", .range = "1, 100", .divisibleBy = "2" };

const expectOutcome = core.expectOutcome;

test "positive has its documented code and message and the finite precondition" {
    try std.testing.expectEqualStrings("validation.positive", positive.code);
    try std.testing.expectEqualStrings("must be greater than 0", positive.message);
    try std.testing.expectEqual(core.Kind.positive, positive.kind);
    try std.testing.expectEqual(null, positive.args);
    try std.testing.expectEqualStrings("validation.finite", positive.precondition.?.code);
    try std.testing.expectEqualStrings("must be a finite number", positive.precondition.?.message);
}

test "positive on integers passes above 0 only" {
    try expectOutcome(.fail, positive, @as(u8, 0));
    try expectOutcome(.pass, positive, @as(u8, 1));
    try expectOutcome(.fail, positive, @as(i64, std.math.minInt(i64)));
    try expectOutcome(.fail, positive, @as(i64, -1));
    try expectOutcome(.fail, positive, @as(i64, 0));
    try expectOutcome(.pass, positive, @as(i64, std.math.maxInt(i64)));
    try expectOutcome(.pass, positive, @as(u64, std.math.maxInt(u64)));
}

test "positive on floats: -0.0 and 0.0 fail, the smallest subnormal passes" {
    try expectOutcome(.fail, positive, @as(f64, -0.0));
    try expectOutcome(.fail, positive, @as(f64, 0.0));
    try expectOutcome(.pass, positive, @as(f64, @bitCast(@as(u64, 1))));
    try expectOutcome(.fail, positive, -@as(f64, @bitCast(@as(u64, 1))));
    try expectOutcome(.pass, positive, std.math.floatTrueMin(f32));
}

test "positive reports the precondition on NaN and infinities" {
    try expectOutcome(.precondition, positive, std.math.nan(f64));
    try expectOutcome(.precondition, positive, std.math.inf(f64));
    try expectOutcome(.precondition, positive, -std.math.inf(f64));
}

test "positive fits integers and floats" {
    comptime {
        for ([_]type{ u8, i8, u64, i64, u128, i128, usize, f16, f32, f64, f80, f128, c_longdouble }) |T| {
            positive.fits(&positive, T, "Dto.field_rules.x");
        }
    }
}

test "min, max and range have their documented codes, messages, parameters and the finite precondition" {
    const t = std.testing;
    const at_least = min(18);
    try t.expectEqual(core.Kind.min, at_least.kind);
    try t.expectEqualStrings("validation.min", at_least.code);
    try t.expectEqualStrings("must be at least 18", at_least.message);
    try t.expectEqualStrings("18", at_least.args.?);
    try t.expectEqual(1, at_least.params.len);
    try t.expectEqualStrings("min", at_least.params[0].name);
    try t.expectEqualStrings("18", at_least.params[0].text);
    try t.expectEqualStrings("validation.finite", at_least.precondition.?.code);
    try t.expectEqualStrings("must be a finite number", at_least.precondition.?.message);

    const at_most = max(0.1);
    try t.expectEqual(core.Kind.max, at_most.kind);
    try t.expectEqualStrings("validation.max", at_most.code);
    try t.expectEqualStrings("must be at most 0.1", at_most.message);
    try t.expectEqualStrings("0.1", at_most.args.?);
    try t.expectEqual(1, at_most.params.len);
    try t.expectEqualStrings("max", at_most.params[0].name);
    try t.expectEqualStrings("0.1", at_most.params[0].text);
    try t.expectEqualStrings("validation.finite", at_most.precondition.?.code);

    const between = range(1, 10);
    try t.expectEqual(core.Kind.range, between.kind);
    try t.expectEqualStrings("validation.range", between.code);
    try t.expectEqualStrings("must be from 1 to 10", between.message);
    try t.expectEqualStrings("1, 10", between.args.?);
    try t.expectEqual(2, between.params.len);
    try t.expectEqualStrings("min", between.params[0].name);
    try t.expectEqualStrings("1", between.params[0].text);
    try t.expectEqualStrings("max", between.params[1].name);
    try t.expectEqualStrings("10", between.params[1].text);
    try t.expectEqualStrings("validation.finite", between.precondition.?.code);

    // Equal bounds read as one value.
    const exactly = range(7, 7);
    try t.expectEqualStrings("must be 7", exactly.message);
    try t.expectEqualStrings("7", exactly.params[0].text);
    try t.expectEqualStrings("7", exactly.params[1].text);
}

test "divisibleBy, the sign rules and finite have their documented codes, messages and preconditions" {
    const t = std.testing;
    const multiple = divisibleBy(5);
    try t.expectEqual(core.Kind.divisible_by, multiple.kind);
    try t.expectEqualStrings("validation.divisible_by", multiple.code);
    try t.expectEqualStrings("must be divisible by 5", multiple.message);
    try t.expectEqualStrings("5", multiple.args.?);
    try t.expectEqual(1, multiple.params.len);
    try t.expectEqualStrings("divisor", multiple.params[0].name);
    try t.expectEqualStrings("5", multiple.params[0].text);
    try t.expectEqualStrings("validation.finite", multiple.precondition.?.code);

    const signs = .{
        .{ nonNegative, core.Kind.non_negative, "validation.non_negative", "must not be negative" },
        .{ negative, core.Kind.negative, "validation.negative", "must be less than 0" },
        .{ nonPositive, core.Kind.non_positive, "validation.non_positive", "must not be positive" },
    };
    inline for (signs) |row| {
        try t.expectEqual(row[1], row[0].kind);
        try t.expectEqualStrings(row[2], row[0].code);
        try t.expectEqualStrings(row[3], row[0].message);
        try t.expectEqual(null, row[0].args);
        try t.expectEqual(0, row[0].params.len);
        try t.expectEqualStrings("validation.finite", row[0].precondition.?.code);
        try t.expectEqualStrings("must be a finite number", row[0].precondition.?.message);
    }

    // finite fails NaN and infinities by its own check, so it has no precondition.
    try t.expectEqual(core.Kind.finite, finite.kind);
    try t.expectEqualStrings("validation.finite", finite.code);
    try t.expectEqualStrings("must be a finite number", finite.message);
    try t.expectEqual(null, finite.args);
    try t.expectEqual(null, finite.precondition);
}

test "bounds show in messages and calls as written, before any conversion to the field type" {
    const expect = std.testing.expectEqualStrings;
    try expect("must be at most 0.1", max(0.1).message);
    try expect("must be at least 0", min(-0.0).message);
    try expect("min(0)", comptime min(-0.0).call());
    try expect("must be at most 0.000001", max(1e-6).message);
    try expect("must be at most 9.99e-7", max(9.99e-7).message);
    try expect("must be at least -1.7976931348623157e308", min(-std.math.floatMax(f64)).message);
    try expect("must be at most 340282366920938463463374607431768211455", max(std.math.maxInt(u128)).message);
    try expect("must be at least -170141183460469231731687303715884105728", min(std.math.minInt(i128)).message);
    try expect("must be from -0.5 to 1e21", range(-0.5, 1e21).message);
    try expect("must be 0", range(-0.0, 0).message);
    try expect("must be at least 5", min(@as(u8, 5)).message);
    try expect("must be divisible by 3", divisibleBy(@as(u8, 3)).message);
    try expect("range(1, 2.5)", comptime range(1, 2.5).call());
    try expect("divisible_by(5)", comptime divisibleBy(5).label());
    try expect("divisibleBy(5)", comptime divisibleBy(5).call());
}

test "min, max and range compare in the field type at their bounds" {
    try expectOutcome(.pass, min(1), @as(u8, 1));
    try expectOutcome(.fail, min(1), @as(u8, 0));
    try expectOutcome(.pass, min(@as(u8, 5)), @as(i64, 5));
    try expectOutcome(.fail, min(@as(u8, 5)), @as(i64, 4));
    try expectOutcome(.pass, max(-1), @as(i64, -1));
    try expectOutcome(.fail, max(-1), @as(i64, 0));
    try expectOutcome(.pass, max(std.math.maxInt(u128) - 1), @as(u128, std.math.maxInt(u128) - 1));
    try expectOutcome(.fail, max(std.math.maxInt(u128) - 1), @as(u128, std.math.maxInt(u128)));
    try expectOutcome(.pass, range(-1, 1), @as(i8, -1));
    try expectOutcome(.pass, range(-1, 1), @as(i8, 1));
    try expectOutcome(.fail, range(-1, 1), @as(i8, -2));
    try expectOutcome(.fail, range(-1, 1), @as(i8, 2));
    // A float bound is rounded to the field type: max(0.1) on f32 accepts
    // the f32 nearest to 0.1 and nothing above it.
    try expectOutcome(.pass, max(0.1), @as(f32, 0.1));
    try expectOutcome(.fail, max(0.1), std.math.nextAfter(f32, 0.1, 1));
    try expectOutcome(.pass, min(-0.0), @as(f64, 0.0));
    try expectOutcome(.pass, min(0), @as(f64, -0.0));
    try expectOutcome(.fail, min(0), -std.math.floatTrueMin(f64));
    try expectOutcome(.pass, range(0.5, 0.5), @as(f16, 0.5));
    try expectOutcome(.fail, range(0.5, 0.5), std.math.nextAfter(f16, 0.5, 1));
}

test "every number rule but finite reports NaN and infinities on a float field as the precondition" {
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| {
        inline for (.{ std.math.nan(F), std.math.inf(F), -std.math.inf(F) }) |bad| {
            try expectOutcome(.precondition, min(0), bad);
            try expectOutcome(.precondition, max(0), bad);
            try expectOutcome(.precondition, range(-1, 1), bad);
            try expectOutcome(.precondition, nonNegative, bad);
            try expectOutcome(.precondition, negative, bad);
            try expectOutcome(.precondition, nonPositive, bad);
            try expectOutcome(.precondition, divisibleBy(1), bad);
            try expectOutcome(.fail, finite, bad);
        }
        try expectOutcome(.pass, finite, -@as(F, 0.0));
        try expectOutcome(.pass, finite, std.math.floatTrueMin(F));
        try expectOutcome(.pass, finite, std.math.floatMax(F));
        try expectOutcome(.pass, finite, -std.math.floatMax(F));
    }
}

test "the sign rules compare with 0: -0.0 is not negative and is not positive" {
    try expectOutcome(.pass, nonNegative, @as(i8, 0));
    try expectOutcome(.fail, nonNegative, @as(i8, -1));
    try expectOutcome(.pass, nonNegative, @as(f64, -0.0));
    try expectOutcome(.fail, nonNegative, -std.math.floatTrueMin(f64));
    try expectOutcome(.pass, negative, @as(i128, std.math.minInt(i128)));
    try expectOutcome(.fail, negative, @as(i128, 0));
    try expectOutcome(.fail, negative, @as(f32, -0.0));
    try expectOutcome(.pass, negative, -std.math.floatTrueMin(f32));
    try expectOutcome(.pass, nonPositive, @as(i64, 0));
    try expectOutcome(.fail, nonPositive, @as(i64, 1));
    try expectOutcome(.pass, nonPositive, @as(f16, -0.0));
    try expectOutcome(.fail, nonPositive, std.math.floatTrueMin(f16));
}

test "divisibleBy is exact on integers, minInt included, and is fmod on floats" {
    try expectOutcome(.pass, divisibleBy(2), @as(i8, std.math.minInt(i8)));
    try expectOutcome(.fail, divisibleBy(3), @as(i8, std.math.minInt(i8)));
    try expectOutcome(.pass, divisibleBy(2), @as(i128, std.math.minInt(i128)));
    try expectOutcome(.fail, divisibleBy(2), @as(i128, std.math.maxInt(i128)));
    try expectOutcome(.fail, divisibleBy(3), @as(u64, 9007199254740993 + 1));
    try expectOutcome(.pass, divisibleBy(3), @as(u64, 9007199254740993));
    // A divisor one past maxInt of a signed type: only 0 and minInt are multiples.
    try expectOutcome(.pass, divisibleBy(128), @as(i8, std.math.minInt(i8)));
    try expectOutcome(.pass, divisibleBy(128), @as(i8, 0));
    try expectOutcome(.fail, divisibleBy(128), @as(i8, 64));
    try expectOutcome(.fail, divisibleBy(128), @as(i8, std.math.maxInt(i8)));
    try expectOutcome(.fail, divisibleBy(128), @as(i8, -1));
    // On a float, divisibleBy(1) means a whole number; -0.0 is one.
    try expectOutcome(.pass, divisibleBy(1), @as(f64, -0.0));
    try expectOutcome(.pass, divisibleBy(1), @as(f64, -3));
    try expectOutcome(.fail, divisibleBy(1), @as(f64, 2.5));
    try expectOutcome(.fail, divisibleBy(1), std.math.floatTrueMin(f64));
    try expectOutcome(.pass, divisibleBy(1), std.math.floatMax(f128));
    try expectOutcome(.pass, divisibleBy(2), @as(f80, -6));
    try expectOutcome(.fail, divisibleBy(2), @as(f80, 3));
}

const test_where = "Dto.field_rules.x";

/// The declaration error of `min(bound)` on a field of type `T`, or null.
fn minText(comptime bound: anytype, comptime T: type) ?[]const u8 {
    return boundProblem(&min(bound), bound, null, T, test_where);
}

fn maxText(comptime bound: anytype, comptime T: type) ?[]const u8 {
    return boundProblem(&max(bound), null, bound, T, test_where);
}

fn rangeText(comptime lo: anytype, comptime hi: anytype, comptime T: type) ?[]const u8 {
    return boundProblem(&range(lo, hi), lo, hi, T, test_where);
}

fn signText(comptime rule: Rule, comptime T: type) ?[]const u8 {
    return signProblem(&rule, T, test_where);
}

fn divisibleText(comptime divisor: anytype, comptime T: type) ?[]const u8 {
    return divisibleProblem(&divisibleBy(divisor), divisor, T, test_where);
}

fn finiteText(comptime T: type) ?[]const u8 {
    return finiteProblem(&finite, T, test_where);
}

/// The error a rule constructor used without a call raises in `field_rules`.
fn uncalledText(comptime name: []const u8, comptime F: type) []const u8 {
    return "validator: " ++ test_where ++ ": " ++ core.hints.mustBeCalled(name, F);
}

test "a bound must be a finite number, and the min of range must not be greater than its max" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: min(\"5\"): the bound must be a number, got *const [1:0]u8", comptime callProblem("min", .{"5"}).?);
    try expect("validator: min(inf): inf is not finite", comptime callProblem("min", .{std.math.inf(f64)}).?);
    try expect("validator: min(inf): inf is not finite", comptime callProblem("min", .{@as(comptime_float, std.math.inf(f64))}).?);
    try expect("validator: max(\"5\"): the bound must be a number, got *const [1:0]u8", comptime callProblem("max", .{"5"}).?);
    try expect("validator: max(nan): nan is not finite", comptime callProblem("max", .{std.math.nan(f64)}).?);
    try expect("validator: range(\"1\", 5): the bound must be a number, got *const [1:0]u8", comptime callProblem("range", .{ "1", 5 }).?);
    try expect("validator: range(-inf, 0): -inf is not finite", comptime callProblem("range", .{ -std.math.inf(f64), 0 }).?);
    try expect("validator: range(10, 5): min is greater than max", comptime callProblem("range", .{ 10, 5 }).?);
    try expect("validator: range(0.5, 0.25): min is greater than max", comptime callProblem("range", .{ 0.5, 0.25 }).?);
    // Other kinds of values are named by their type.
    try expect("validator: min(true): the bound must be a number, got bool", comptime callProblem("min", .{true}).?);
    try expect("validator: max(.admin): the bound must be a number, got @EnumLiteral()", comptime callProblem("max", .{.admin}).?);
    try expect("validator: min(...): the bound must be a number, got @TypeOf(null)", comptime callProblem("min", .{null}).?);
    try std.testing.expectEqual(null, comptime callProblem("range", .{ 7, 7 }));
    try std.testing.expectEqual(null, comptime callProblem("range", .{ -0.0, 0 }));
    try std.testing.expectEqual(null, comptime callProblem("min", .{std.math.floatMax(f128)}));
    try std.testing.expectEqual(null, comptime callProblem("max", .{std.math.maxInt(u128)}));
    // A literal beyond the range of f64 is finite: a bound for f80 and f128 fields.
    try std.testing.expectEqual(null, comptime callProblem("max", .{1e400}));
    try std.testing.expectEqual(null, comptime callProblem("range", .{ 1e-400, 1e400 }));
}

test "an integer field takes integer bounds within its type" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: Dto.field_rules.x: min(1.5): 1.5 is a float (comptime_float), field is u8; use an integer bound", comptime minText(1.5, u8).?);
    try expect("validator: Dto.field_rules.x: min(2): 2 is a float (comptime_float), field is u8; use an integer bound", comptime minText(2.0, u8).?);
    try expect("validator: Dto.field_rules.x: min(-1): -1 is outside u64 (0..18446744073709551615)", comptime minText(-1, u64).?);
    try expect(
        "validator: Dto.field_rules.x: min(-9223372036854775809): -9223372036854775809 is outside i64 (-9223372036854775808..9223372036854775807)",
        comptime minText(std.math.minInt(i64) - 1, i64).?,
    );
    try expect("validator: Dto.field_rules.x: max(10): 10 is a float (f64), field is u64; use an integer bound", comptime maxText(@as(f64, 10), u64).?);
    try expect("validator: Dto.field_rules.x: max(300): 300 is outside u8 (0..255)", comptime maxText(300, u8).?);
    try expect("validator: Dto.field_rules.x: range(1, 2.5): 2.5 is a float (comptime_float), field is u8; use an integer bound", comptime rangeText(1, 2.5, u8).?);
    try expect("validator: Dto.field_rules.x: range(-129, 0): -129 is outside i8 (-128..127)", comptime rangeText(-129, 0, i8).?);
    try expect("validator: Dto.field_rules.x: range(0, 300): 300 is outside u8 (0..255)", comptime rangeText(0, 300, u8).?);
    try std.testing.expectEqual(null, comptime minText(1, u8));
    try std.testing.expectEqual(null, comptime minText(@as(u64, 5), i8));
    try std.testing.expectEqual(null, comptime maxText(254, u8));
    try std.testing.expectEqual(null, comptime rangeText(std.math.minInt(i128) + 1, std.math.maxInt(i128), i128));
}

test "a float field takes bounds that stay finite and non-zero in it, and integer bounds it holds exactly" {
    const expect = std.testing.expectEqualStrings;
    const huge = "1606938044258990275541962092341162602522202993782792835301376";
    try expect("validator: Dto.field_rules.x: min(16777217): 16777217 is not exactly representable in f32 (nearest: 16777216)", comptime minText(16777217, f32).?);
    try expect(
        "validator: Dto.field_rules.x: max(9007199254740993): 9007199254740993 is not exactly representable in f64 (nearest: 9007199254740992)",
        comptime maxText(9007199254740993, f64).?,
    );
    try expect("validator: Dto.field_rules.x: range(0, 16777217): 16777217 is not exactly representable in f32 (nearest: 16777216)", comptime rangeText(0, 16777217, f32).?);
    try expect("validator: Dto.field_rules.x: min(" ++ huge ++ "): " ++ huge ++ " is outside the finite range of f32", comptime minText(1 << 200, f32).?);
    try expect("validator: Dto.field_rules.x: max(" ++ huge ++ "): " ++ huge ++ " is outside the finite range of f32", comptime maxText(1 << 200, f32).?);
    try expect("validator: Dto.field_rules.x: range(0, " ++ huge ++ "): " ++ huge ++ " is outside the finite range of f32", comptime rangeText(0, 1 << 200, f32).?);
    try expect("validator: Dto.field_rules.x: min(1e39): 1e39 is outside the finite range of f32", comptime minText(1e39, f32).?);
    try expect("validator: Dto.field_rules.x: max(1e39): 1e39 is outside the finite range of f32", comptime maxText(1e39, f32).?);
    try expect("validator: Dto.field_rules.x: range(-1e39, 1e39): -1e39 is outside the finite range of f32", comptime rangeText(-1e39, 1e39, f32).?);
    try expect("validator: Dto.field_rules.x: min(1e-50): 1e-50 rounds to 0 in f32", comptime minText(1e-50, f32).?);
    try expect("validator: Dto.field_rules.x: max(1e-50): 1e-50 rounds to 0 in f32", comptime maxText(1e-50, f32).?);
    try expect("validator: Dto.field_rules.x: range(1e-50, 1): 1e-50 rounds to 0 in f32", comptime rangeText(1e-50, 1, f32).?);
    try std.testing.expectEqual(null, comptime minText(0.1, f32));
    try std.testing.expectEqual(null, comptime maxText(-0.0, f16));
    try std.testing.expectEqual(null, comptime minText(16777216, f32));
    try std.testing.expectEqual(null, comptime rangeText(-1, 1, f80));
    try std.testing.expectEqual(null, comptime maxText(9007199254740993, f80));
    try std.testing.expectEqual(null, comptime minText(1 << 200, f64));
    try std.testing.expectEqual(null, comptime minText(-std.math.floatMax(f64), f64));
    // c_longdouble holds 9007199254740993 exactly only when it is wider than f64.
    try std.testing.expectEqual(@bitSizeOf(c_longdouble) > 64, comptime maxText(9007199254740993, c_longdouble) == null);
}

test "a typed float bound narrower than a float field is an error when its value there has another shortest text" {
    const expect = std.testing.expectEqualStrings;
    const t = std.testing;
    const head = "validator: Dto.field_rules.x: ";
    const tail = "; write it as a literal or as f64";
    try expect(head ++ "min(0.1): 0.1 is a float (f32), 0.10000000149011612 in f64" ++ tail, comptime minText(@as(f32, 0.1), f64).?);
    try expect(head ++ "max(0.7): 0.7 is a float (f32), 0.699999988079071 in f64" ++ tail, comptime maxText(@as(f32, 0.7), f64).?);
    try expect(head ++ "range(0.1, 0.7): 0.1 is a float (f32), 0.10000000149011612 in f64" ++ tail, comptime rangeText(@as(f32, 0.1), @as(f32, 0.7), f64).?);
    try expect(head ++ "range(0, 0.7): 0.7 is a float (f32), 0.699999988079071 in f64" ++ tail, comptime rangeText(0, @as(f32, 0.7), f64).?);
    // The constructor compares the bounds as written, in f32 here, so this
    // range reads "must be 0.1"; on an f64 field it would reject every value.
    try expect(head ++ "range(0.1, 0.1): 0.1 is a float (f32), 0.10000000149011612 in f64" ++ tail, comptime rangeText(@as(f32, 0.1), 0.1, f64).?);
    try expect(head ++ "max(65500): 65500 is a float (f16), 65504 in f32; write it as a literal or as f32", comptime maxText(std.math.floatMax(f16), f32).?);
    try t.expectEqual(null, comptime minText(@as(f32, 0.1), f32));
    try t.expectEqual(null, comptime maxText(std.math.floatMax(f16), f16));
    try t.expectEqual(null, comptime maxText(@as(f32, 0.5), f64));
    try t.expectEqual(null, comptime minText(1.0 / 3.0, f64));
    try t.expectEqual(null, comptime maxText(@as(f64, 0.1), f32));
}

test "a bound rule that every value of an integer field passes is an error; one bound at a limit is fine" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: Dto.field_rules.x: min(0) is always true for u8; remove it", comptime minText(0, u8).?);
    try expect("validator: Dto.field_rules.x: min(-9223372036854775808) is always true for i64; remove it", comptime minText(std.math.minInt(i64), i64).?);
    try expect("validator: Dto.field_rules.x: max(18446744073709551615) is always true for u64; remove it", comptime maxText(std.math.maxInt(u64), u64).?);
    try expect("validator: Dto.field_rules.x: range(0, 255) is always true for u8; remove it", comptime rangeText(0, 255, u8).?);
    try expect(
        "validator: Dto.field_rules.x: range(-170141183460469231731687303715884105728, 170141183460469231731687303715884105727) is always true for i128; remove it",
        comptime rangeText(std.math.minInt(i128), std.math.maxInt(i128), i128).?,
    );
    try std.testing.expectEqual(null, comptime rangeText(0, 100, u8));
    try std.testing.expectEqual(null, comptime rangeText(1, 65535, u16));
    try std.testing.expectEqual(null, comptime maxText(0, u8));
    // Floats have no such check: NaN and infinities fail every bound.
    try std.testing.expectEqual(null, comptime minText(-std.math.floatMax(f32), f32));
}

test "a bound rule on a field that is not a number names the field type, with each for a list of numbers" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: Dto.field_rules.x: min expects a number, field is bool", comptime minText(1, bool).?);
    try expect("validator: Dto.field_rules.x: min expects a number, field is []const i32; use v.each(v.min(0))", comptime minText(0, []const i32).?);
    try expect("validator: Dto.field_rules.x: min expects a number, field is [4]u8; use v.each(v.min(0))", comptime minText(0, [4]u8).?);
    try expect("validator: Dto.field_rules.x: max expects a number, field is bool", comptime maxText(1, bool).?);
    try expect("validator: Dto.field_rules.x: max expects a number, field is []const i32; use v.each(v.max(0))", comptime maxText(0, []const i32).?);
    try expect("validator: Dto.field_rules.x: max expects a number, field is core.Kind", comptime maxText(1, core.Kind).?);
    try expect("validator: Dto.field_rules.x: range expects a number, field is []const u8", comptime rangeText(1, 2, []const u8).?);
    try expect("validator: Dto.field_rules.x: range expects a number, field is []const i32; use v.each(v.range(0, 100))", comptime rangeText(0, 100, []const i32).?);
}

test "an uncalled number rule constructor gets an example call" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: Dto.field_rules.x: min must be called, e.g. v.min(0)", comptime uncalledText("min", @TypeOf(min)));
    try expect("validator: Dto.field_rules.x: max must be called, e.g. v.max(100)", comptime uncalledText("max", @TypeOf(max)));
    try expect("validator: Dto.field_rules.x: range must be called, e.g. v.range(1, 100)", comptime uncalledText("range", @TypeOf(range)));
    try expect("validator: Dto.field_rules.x: divisibleBy must be called, e.g. v.divisibleBy(2)", comptime uncalledText("divisibleBy", @TypeOf(divisibleBy)));
}

/// `n` in decimal; a number of hundreds of digits takes more comptime
/// branches than a test body allows by default.
fn decimal(comptime n: comptime_int) []const u8 {
    @setEvalBranchQuota(core.eval_quota);
    return std.fmt.comptimePrint("{d}", .{n});
}

test "a bound or divisor whose default message would be longer than 512 bytes is an error at the field unless withMessage replaces it" {
    const t = std.testing;
    const expect = t.expectEqualStrings;
    const two_1700 = comptime decimal(1 << 1700);
    const two_820 = comptime decimal(1 << 820);
    const two_830 = comptime decimal(1 << 830);
    const two_2000 = comptime decimal(1 << 2000);
    try t.expectEqual(512, two_1700.len);
    try t.expectEqual(247, two_820.len);
    try t.expectEqual(250, two_830.len);
    try t.expectEqual(603, two_2000.len);
    const head = "validator: Dto.field_rules.x: ";
    const tail = " (limit 512); use .withMessage(...)";
    try expect(head ++ "min(" ++ two_1700 ++ "): the default message would be 529 bytes" ++ tail, comptime core.defaultMessageProblem(&min(1 << 1700), test_where).?);
    try expect(head ++ "max(" ++ two_1700 ++ "): the default message would be 528 bytes" ++ tail, comptime core.defaultMessageProblem(&max(1 << 1700), test_where).?);
    try expect(
        head ++ "range(" ++ two_820 ++ ", " ++ two_830 ++ "): the default message would be 514 bytes" ++ tail,
        comptime core.defaultMessageProblem(&range(1 << 820, 1 << 830), test_where).?,
    );
    try expect(
        head ++ "divisible_by(" ++ two_2000 ++ "): the default message would be 624 bytes" ++ tail,
        comptime core.defaultMessageProblem(&divisibleBy(1 << 2000), test_where).?,
    );
    // On these fields the bounds fit: the size of the message is the only problem.
    try t.expectEqual(null, comptime minText(1 << 1700, u2000));
    try t.expectEqual(null, comptime maxText(1 << 1700, u2000));
    try t.expectEqual(null, comptime rangeText(1 << 820, 1 << 830, u1000));
    try t.expectEqual(null, comptime divisibleText(1 << 2000, f128));
    // The rule keeps the message as built; withMessage replaces it.
    try t.expectEqual(529, min(1 << 1700).message.len);
    try t.expectEqual(null, comptime core.defaultMessageProblem(&min(1 << 1700).withMessage("too small"), test_where));
    try t.expectEqual(null, comptime core.defaultMessageProblem(&divisibleBy(1 << 2000).withMessage("must be a multiple of 2^2000"), test_where));
    // A placeholder fills in the whole bound, so it can make the message too long.
    try expect(
        "validator: min(" ++ two_1700 ++ ").withMessage(\"at least {min}\"): message is longer than 512 bytes",
        comptime switch (core.renderTemplate(min(1 << 1700), "at least {min}")) {
            .message, .problem => |text| text,
        },
    );
}

test "the default message of min reaches 513 bytes at a 496-digit bound, max at 497 digits, divisibleBy at 492" {
    const t = std.testing;
    // 2^1644 has 495 digits, 2^1645 496; 2^1647 has 496, 2^1648 497; 2^1630 has 491, 2^1634 492.
    try t.expectEqual(512, min(1 << 1644).message.len);
    try t.expectEqual(null, comptime core.defaultMessageProblem(&min(1 << 1644), test_where));
    try t.expectEqual(513, min(1 << 1645).message.len);
    try t.expect(comptime core.defaultMessageProblem(&min(1 << 1645), test_where) != null);
    try t.expectEqual(512, max(1 << 1647).message.len);
    try t.expectEqual(null, comptime core.defaultMessageProblem(&max(1 << 1647), test_where));
    try t.expectEqual(513, max(1 << 1648).message.len);
    try t.expect(comptime core.defaultMessageProblem(&max(1 << 1648), test_where) != null);
    try t.expectEqual(512, divisibleBy(1 << 1630).message.len);
    try t.expectEqual(null, comptime core.defaultMessageProblem(&divisibleBy(1 << 1630), test_where));
    try t.expectEqual(513, divisibleBy(1 << 1634).message.len);
    try t.expect(comptime core.defaultMessageProblem(&divisibleBy(1 << 1634), test_where) != null);
}

test "the sign rules take signed integers and floats; on an unsigned field each one is an error" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: Dto.field_rules.x: non_negative is always true for u32; remove it", comptime signText(nonNegative, u32).?);
    try expect("validator: Dto.field_rules.x: non_negative expects a signed integer or a float, field is []const u8", comptime signText(nonNegative, []const u8).?);
    try expect(
        "validator: Dto.field_rules.x: non_negative expects a signed integer or a float, field is []const i32; use v.each(v.nonNegative)",
        comptime signText(nonNegative, []const i32).?,
    );
    try expect("validator: Dto.field_rules.x: negative is always false for u32 (an unsigned type)", comptime signText(negative, u32).?);
    try expect("validator: Dto.field_rules.x: negative expects a signed integer or a float, field is []const u8", comptime signText(negative, []const u8).?);
    try expect(
        "validator: Dto.field_rules.x: negative expects a signed integer or a float, field is []const i32; use v.each(v.negative)",
        comptime signText(negative, []const i32).?,
    );
    try expect("validator: Dto.field_rules.x: non_positive on u8 only accepts 0; use v.equals(0)", comptime signText(nonPositive, u8).?);
    try expect("validator: Dto.field_rules.x: non_positive expects a signed integer or a float, field is []const u8", comptime signText(nonPositive, []const u8).?);
    try expect(
        "validator: Dto.field_rules.x: non_positive expects a signed integer or a float, field is []const i32; use v.each(v.nonPositive)",
        comptime signText(nonPositive, []const i32).?,
    );
    // Items the rule would not take either get no each hint.
    try expect("validator: Dto.field_rules.x: negative expects a signed integer or a float, field is []const u32", comptime signText(negative, []const u32).?);
    inline for (.{ i8, i64, i128, isize, f16, f64, c_longdouble }) |T| {
        try std.testing.expectEqual(null, comptime signText(nonNegative, T));
        try std.testing.expectEqual(null, comptime signText(negative, T));
        try std.testing.expectEqual(null, comptime signText(nonPositive, T));
    }
}

test "divisibleBy takes an integer divisor of at least 1" {
    const expect = std.testing.expectEqualStrings;
    const inexact = "; fractional divisors are inexact on binary floats: count whole units (e.g. cents)";
    try expect("validator: divisibleBy(0): division by zero; no value would pass", comptime divisorProblem(0).?);
    try expect("validator: divisibleBy(-5): the divisor is negative; use v.divisibleBy(5)", comptime divisorProblem(-5).?);
    try expect("validator: divisibleBy(-1): the divisor is negative; use v.divisibleBy(1)", comptime divisorProblem(-1).?);
    try expect("validator: divisibleBy(-128): the divisor is negative; use v.divisibleBy(128)", comptime divisorProblem(@as(i8, std.math.minInt(i8))).?);
    try expect("validator: divisibleBy(0.5): the divisor must be an integer, got comptime_float" ++ inexact, comptime divisorProblem(0.5).?);
    try expect("validator: divisibleBy(5): the divisor must be an integer, got comptime_float" ++ inexact, comptime divisorProblem(5.0).?);
    try expect("validator: divisibleBy(2): the divisor must be an integer, got f64" ++ inexact, comptime divisorProblem(@as(f64, 2)).?);
    try expect("validator: divisibleBy(\"5\"): the divisor must be an integer, got *const [1:0]u8", comptime divisorProblem("5").?);
    try expect("validator: divisibleBy(...): the divisor must be an integer, got @TypeOf(null)", comptime divisorProblem(null).?);
    try std.testing.expectEqual(null, comptime divisorProblem(1));
    try std.testing.expectEqual(null, comptime divisorProblem(@as(u8, 3)));
    try std.testing.expectEqual(null, comptime divisorProblem(1 << 200));
}

test "divisibleBy on an integer field takes a divisor from 2 to the largest magnitude of the type" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: Dto.field_rules.x: divisible_by(1) is always true for u32; remove it", comptime divisibleText(1, u32).?);
    try expect("validator: Dto.field_rules.x: divisible_by(1000) on u8 (0..255): only 0 would pass; use v.equals(0)", comptime divisibleText(1000, u8).?);
    try expect("validator: Dto.field_rules.x: divisible_by(256) on u8 (0..255): only 0 would pass; use v.equals(0)", comptime divisibleText(256, u8).?);
    try expect("validator: Dto.field_rules.x: divisible_by(129) on i8 (-128..127): only 0 would pass; use v.equals(0)", comptime divisibleText(129, i8).?);
    try std.testing.expectEqual(null, comptime divisibleText(255, u8));
    try std.testing.expectEqual(null, comptime divisibleText(128, i8));
    try std.testing.expectEqual(null, comptime divisibleText(2, i8));
    try std.testing.expectEqual(null, comptime divisibleText(-std.math.minInt(i128), i128));
    try std.testing.expectEqual(null, comptime divisibleText(std.math.maxInt(u128), u128));
}

test "divisibleBy on a float field takes a divisor the type holds exactly" {
    const expect = std.testing.expectEqualStrings;
    const huge = "1606938044258990275541962092341162602522202993782792835301376";
    try expect(
        "validator: Dto.field_rules.x: divisible_by(9007199254740993): 9007199254740993 is not exactly representable in f64 (nearest: 9007199254740992)",
        comptime divisibleText(9007199254740993, f64).?,
    );
    try expect("validator: Dto.field_rules.x: divisible_by(" ++ huge ++ "): " ++ huge ++ " is outside the finite range of f32", comptime divisibleText(1 << 200, f32).?);
    try std.testing.expectEqual(null, comptime divisibleText(1, f32));
    try std.testing.expectEqual(null, comptime divisibleText(65504, f16));
    try std.testing.expectEqual(null, comptime divisibleText(1 << 200, f64));
}

test "divisibleBy on a field that is not a number names the field type" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: Dto.field_rules.x: divisible_by expects a number, field is bool", comptime divisibleText(5, bool).?);
    try expect(
        "validator: Dto.field_rules.x: divisible_by expects a number, field is []const u32; use v.each(v.divisibleBy(15))",
        comptime divisibleText(15, []const u32).?,
    );
}

test "finite takes floats only; on an integer field it is always true" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: Dto.field_rules.x: finite is always true for u32; remove it", comptime finiteText(u32).?);
    try expect("validator: Dto.field_rules.x: finite is always true for i128; remove it", comptime finiteText(i128).?);
    try expect("validator: Dto.field_rules.x: finite expects a float, field is []const u8", comptime finiteText([]const u8).?);
    try expect("validator: Dto.field_rules.x: finite expects a float, field is []const f64; use v.each(v.finite)", comptime finiteText([]const f64).?);
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| try std.testing.expectEqual(null, comptime finiteText(F));
}
