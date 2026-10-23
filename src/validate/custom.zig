// Copied from vkiryakov/zefir src/validator/custom.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! `v.custom(code, message, f)`: a rule with the caller's own predicate, code
//! and message. For a check across fields use `validateSelf` with `v.fail`.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core.zig");
const schema = @import("schema.zig");
const Rule = core.Rule;
const Outcome = core.Outcome;

/// A rule that passes when `f(value)` returns true; otherwise the violation
/// has `code` and `message`. `f` is a function (not a function pointer) that
/// returns `bool` and takes one parameter: `P`, or `*const P` (a pointer to
/// the value, or to a copy of it as `P`), where the field type `T` without
/// its optionals coerces to `P`: `P` is `T`; an integer of `T`'s signedness
/// at least as wide, or a wider signed one when `T` is unsigned; a float at
/// least as wide; a slice or pointer like `T` that adds `const` or drops the
/// sentinel; or `?Q` or `E!Q` for such a `Q`. Inside `each` the item type
/// takes the place of the field type. The code is segments of
/// `[a-z][a-z0-9_]*` joined by `.`: at least 2, at most `max_code_bytes`
/// bytes, not starting with `validation.` or `rpc.`. The message is literal
/// (braces are plain text): 1 to `max_message_bytes` bytes of valid UTF-8.
/// `f` sees every value, NaN, invalid UTF-8 and `""` included, and must be
/// pure: no I/O, no global state, no allocation.
pub fn custom(comptime code: []const u8, comptime message: []const u8, comptime f: anytype) Rule {
    @setEvalBranchQuota(core.eval_quota);
    const args = "\"" ++ core.escape(code) ++ "\", ...";
    // Errors about the arguments are named by the call: custom("users.ok", ...).
    const head = "custom(" ++ args ++ ")";
    core.checkCode(head, code);
    core.checkMessage(head, message);
    const F = @TypeOf(f);
    if (@typeInfo(F) != .@"fn")
        @compileError("validator: " ++ head ++ ": f must be a function such as fn (T) bool or fn (*const T) bool, got " ++ @typeName(F));
    return core.define(.custom, .{
        .code = code,
        .message = message,
        .args = args,
        .fits = struct {
            fn fits(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void {
                if (paramProblem(T, F)) |text| core.ruleError(rule, where, text);
            }
        }.fits,
        .eval = struct {
            fn eval(value: anytype) Outcome {
                const T = @TypeOf(value.*);
                const P = @typeInfo(F).@"fn".param_types[0].?;
                return core.passIf(switch (comptime callForm(T, F)) {
                    .by_value => f(value.*),
                    .by_pointer => if (@typeInfo(P).pointer.child == T) f(value) else blk: {
                        const copy: @typeInfo(P).pointer.child = value.*;
                        break :blk f(&copy);
                    },
                    .none => @compileError("validator: internal: custom's eval was instantiated for a type its fits rejected"),
                });
            }
        }.eval,
    });
}

/// The JSON Schema keywords of `custom`, for `v.schemaOf`: none, since its
/// predicate is code; the note gives its message.
pub fn schemaOf(comptime rule: Rule, comptime T: type) schema.RuleSchema {
    _ = T;
    return switch (rule.kind) {
        .custom => schema.none(rule.message),
        else => unreachable,
    };
}

/// The arguments the hints show for `custom` used without a call:
/// `custom must be called, e.g. v.custom("users.name_taken", "is taken", isFree)`.
pub const call_examples = .{ .custom = "\"users.name_taken\", \"is taken\", isFree" };

const CallForm = enum { none, by_value, by_pointer };

/// How a value of type `T` is passed to a predicate of type `F`. A generic
/// predicate (an `anytype` or `comptime` parameter) takes nothing: the value
/// is only known at run time. A pointer parameter must be a plain `*const Q`
/// (no `volatile`, `allowzero`, `align` or address space, as in `coerces`):
/// `eval` passes a plain `*const` pointer to the value or to a copy of it as
/// `Q`.
fn callForm(comptime T: type, comptime F: type) CallForm {
    const info = @typeInfo(F).@"fn";
    if (info.is_generic or info.param_types.len != 1) return .none;
    if (info.return_type == null or info.return_type.? != bool) return .none;
    const P = info.param_types[0] orelse return .none;
    if (core.coerces(T, P)) return .by_value;
    return switch (@typeInfo(P)) {
        .pointer => |p| if (p.size == .one and p.attrs.@"const" and !p.attrs.@"volatile" and
            !p.attrs.@"allowzero" and p.attrs.@"align" == null and
            (p.attrs.@"addrspace" orelse .generic) == .generic and core.coerces(T, p.child)) .by_pointer else .none,
        else => .none,
    };
}

/// The error text after the rule's label when `F` cannot take a `T`, or null.
/// When `T` is a list whose items `F` would take, the text ends with the hint
/// to move the rule into `each`.
fn paramProblem(comptime T: type, comptime F: type) ?[]const u8 {
    if (callForm(T, F) != .none) return null;
    const each_hint = if (core.ListChild(T)) |Item|
        (if (callForm(core.Unwrap(Item), F) != .none) "; " ++ core.hints.use_each_custom else "")
    else
        "";
    return ": f must be fn (P) bool or fn (*const P) bool where " ++ @typeName(T) ++ " coerces to P, got " ++ @typeName(F) ++ each_hint;
}

fn isEven(x: u32) bool {
    return x % 2 == 0;
}
fn isEvenPtr(x: *const u32) bool {
    return x.* % 2 == 0;
}
fn isEvenSigned(x: i64) bool {
    return @rem(x, 2) == 0;
}
fn isEvenWidePtr(x: *const u64) bool {
    return x.* % 2 == 0;
}
fn isEvenOrNull(x: ?u32) bool {
    return (x orelse 0) % 2 == 0;
}
fn isEvenResult(x: anyerror!u32) bool {
    const n = x catch return false;
    return n % 2 == 0;
}
fn isWhole(x: f64) bool {
    return @round(x) == x;
}
fn startsWithAt(s: []const u8) bool {
    return s.len > 0 and s[0] == '@';
}
inline fn isOdd(x: u32) bool {
    return x % 2 == 1;
}
fn isSmall(comptime x: u32) bool {
    return x < 10;
}
fn isEvenAny(x: anytype) bool {
    return x % 2 == 0;
}

const Money = struct { cents: i64 };
fn isPositiveMoney(m: *const Money) bool {
    return m.cents > 0;
}

const expectOutcome = core.expectOutcome;

test "custom keeps the caller's code and message" {
    const rule = custom("numbers.even", "must be even", isEven);
    try std.testing.expectEqualStrings("numbers.even", rule.code);
    try std.testing.expectEqualStrings("must be even", rule.message);
    try std.testing.expectEqual(core.Kind.custom, rule.kind);
    try std.testing.expectEqualStrings("custom(\"numbers.even\", ...)", comptime rule.label());
    try std.testing.expectEqual(null, rule.precondition);
}

test "custom passes the value by value or by *const" {
    try expectOutcome(.fail, custom("numbers.even", "must be even", isEven), @as(u32, 3));
    try expectOutcome(.pass, custom("numbers.even", "must be even", isEven), @as(u32, 4));
    try expectOutcome(.fail, custom("numbers.even", "must be even", isEvenPtr), @as(u32, 3));
    try expectOutcome(.pass, custom("numbers.even", "must be even", isEvenPtr), @as(u32, 4));
    try expectOutcome(.fail, custom("numbers.odd", "must be odd", isOdd), @as(u32, 4));
    try expectOutcome(.fail, custom("money.positive", "must be positive", isPositiveMoney), Money{ .cents = 0 });
    try expectOutcome(.pass, custom("money.positive", "must be positive", isPositiveMoney), Money{ .cents = 1 });
}

test "custom passes a value that coerces to the parameter" {
    try expectOutcome(.fail, custom("numbers.even", "must be even", isEven), @as(u8, 3));
    try expectOutcome(.fail, custom("numbers.even", "must be even", isEvenSigned), @as(i8, -3));
    try expectOutcome(.pass, custom("numbers.even", "must be even", isEvenSigned), @as(u32, 4));
    try expectOutcome(.pass, custom("numbers.even", "must be even", isEvenWidePtr), @as(u16, 4));
    try expectOutcome(.fail, custom("numbers.even", "must be even", isEvenOrNull), @as(u32, 3));
    try expectOutcome(.fail, custom("numbers.even", "must be even", isEvenResult), @as(u32, 3));
    try expectOutcome(.pass, custom("numbers.even", "must be even", isEvenResult), @as(u32, 4));
    try expectOutcome(.fail, custom("numbers.whole", "must be whole", isWhole), @as(f32, 2.5));
    try expectOutcome(.fail, custom("users.handle", "must start with @", startsWithAt), @as([:0]const u8, "bob"));
    var buffer = "@bob".*;
    try expectOutcome(.pass, custom("users.handle", "must start with @", startsWithAt), @as([]u8, &buffer));
}

test "custom names the parameter it needs, with the each hint on a list of fitting items" {
    try std.testing.expectEqual(null, comptime paramProblem(u32, @TypeOf(isEven)));
    try std.testing.expectEqualStrings(
        ": f must be fn (P) bool or fn (*const P) bool where u64 coerces to P, got fn (u32) bool",
        comptime paramProblem(u64, @TypeOf(isEven)).?,
    );
    try std.testing.expectEqualStrings(
        ": f must be fn (P) bool or fn (*const P) bool where []const u32 coerces to P, got fn (u32) bool; use v.each(v.custom(...))",
        comptime paramProblem([]const u32, @TypeOf(isEven)).?,
    );
    try std.testing.expectEqualStrings(
        ": f must be fn (P) bool or fn (*const P) bool where [3]?u8 coerces to P, got fn (*const u32) bool; use v.each(v.custom(...))",
        comptime paramProblem([3]?u8, @TypeOf(isEvenPtr)).?,
    );
    try std.testing.expectEqualStrings(
        ": f must be fn (P) bool or fn (*const P) bool where []const u8 coerces to P, got fn (u32) bool",
        comptime paramProblem([]const u8, @TypeOf(isEven)).?,
    );
    try std.testing.expectEqualStrings(
        ": f must be fn (P) bool or fn (*const P) bool where u32 coerces to P, got fn (comptime u32) bool",
        comptime paramProblem(u32, @TypeOf(isSmall)).?,
    );
    try std.testing.expectEqualStrings(
        ": f must be fn (P) bool or fn (*const P) bool where []allowzero const u8 coerces to P, got fn ([]const u8) bool",
        comptime paramProblem([]allowzero const u8, @TypeOf(startsWithAt)).?,
    );
    try std.testing.expectEqualStrings(
        ": f must be fn (P) bool or fn (*const P) bool where []volatile u8 coerces to P, got fn ([]const u8) bool",
        comptime paramProblem([]volatile u8, @TypeOf(startsWithAt)).?,
    );
}

test "a generic predicate never fits, so a list field gets no each hint" {
    try std.testing.expectEqualStrings(
        ": f must be fn (P) bool or fn (*const P) bool where u32 coerces to P, got fn (anytype) bool",
        comptime paramProblem(u32, @TypeOf(isEvenAny)).?,
    );
    try std.testing.expectEqualStrings(
        ": f must be fn (P) bool or fn (*const P) bool where []const u32 coerces to P, got fn (comptime u32) bool",
        comptime paramProblem([]const u32, @TypeOf(isSmall)).?,
    );
}

test "a pointer parameter fits only as a plain *const P" {
    try std.testing.expectEqual(null, comptime paramProblem(u32, @TypeOf(isEvenPtr)));
    try std.testing.expectEqual(null, comptime paramProblem(u16, @TypeOf(isEvenWidePtr)));
    try std.testing.expectEqualStrings(
        ": f must be fn (P) bool or fn (*const P) bool where u32 coerces to P, got fn (*u32) bool",
        comptime paramProblem(u32, fn (*u32) bool).?,
    );
    try std.testing.expectEqualStrings(
        ": f must be fn (P) bool or fn (*const P) bool where u32 coerces to P, got fn (*const volatile u32) bool",
        comptime paramProblem(u32, fn (*const volatile u32) bool).?,
    );
    try std.testing.expectEqualStrings(
        ": f must be fn (P) bool or fn (*const P) bool where u32 coerces to P, got fn (*allowzero const u32) bool",
        comptime paramProblem(u32, fn (*allowzero const u32) bool).?,
    );
    try std.testing.expectEqualStrings(
        ": f must be fn (P) bool or fn (*const P) bool where u32 coerces to P, got fn (*align(1) const u32) bool",
        comptime paramProblem(u32, fn (*align(1) const u32) bool).?,
    );
    try std.testing.expectEqualStrings(
        ": f must be fn (P) bool or fn (*const P) bool where u32 coerces to P, got fn (*align(4) const u32) bool",
        comptime paramProblem(u32, fn (*align(4) const u32) bool).?,
    );
    // The pointer to the value, or to a copy of it, is not aligned to 16.
    try std.testing.expectEqualStrings(
        ": f must be fn (P) bool or fn (*const P) bool where u32 coerces to P, got fn (*align(16) const u32) bool",
        comptime paramProblem(u32, fn (*align(16) const u32) bool).?,
    );
    try std.testing.expectEqualStrings(
        ": f must be fn (P) bool or fn (*const P) bool where u16 coerces to P, got fn (*align(16) const u64) bool",
        comptime paramProblem(u16, fn (*align(16) const u64) bool).?,
    );
    // Its items do not fit either, so a list gets no each hint.
    try std.testing.expectEqualStrings(
        ": f must be fn (P) bool or fn (*const P) bool where []const u32 coerces to P, got fn (*align(16) const u32) bool",
        comptime paramProblem([]const u32, fn (*align(16) const u32) bool).?,
    );
    // eval passes a pointer in the default address space. Of the targets CI
    // runs, only x86_64 has another one.
    if (builtin.cpu.arch == .x86_64) {
        try std.testing.expectEqualStrings(
            ": f must be fn (P) bool or fn (*const P) bool where u32 coerces to P, got fn (*addrspace(.gs) const u32) bool",
            comptime paramProblem(u32, fn (*addrspace(.gs) const u32) bool).?,
        );
    }
}
