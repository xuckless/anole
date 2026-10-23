// Copied from vkiryakov/zefir src/validator/walk.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! The walkers, the public entry points built on them, and the declaration
//! checks of every type the walkers visit.
//!
//! Before walking, an entry point runs `verify(T)` at comptime: the checks of
//! `T` and of each type the walk can reach from it, each struct once per
//! root. The check walk runs a value's own rules left to right, reports the
//! first one that fails as the value's only violation, and descends into the
//! value (the items of a list, the fields of a struct) only when they all
//! passed; it names fields in paths by their outside names. The transform
//! walk runs the transforms of `field_rules`, a value's nested parts before
//! the value itself. Each walk is pruned at compile time to the types that
//! have something for it: rules for the one, transforms for the other.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("core.zig");
const names = @import("names.zig");
const Allocator = std.mem.Allocator;
const Rule = core.Rule;
const Transform = core.Transform;
const Violation = core.Violation;

// ------------------------------------------------------------------ entry points

/// The first violation of `value.*` in walk order, or null. `value` is a
/// single-item pointer (`&dto`); the path is written into `path_buf`, and
/// `field` is null when it does not fit. A path names fields by their
/// outside names (`v.rename`). `path_buf` must not overlap the checked
/// value: the walk writes the path while it still reads the value. The
/// transforms in `field_rules` are not run: call `v.transform` first so
/// that the rules check the transformed value. Allocates nothing. Calls on
/// several threads at once are safe when each has its own `path_buf` and no
/// thread changes the value meanwhile.
pub fn check(value: anytype, path_buf: []u8) ?Violation {
    const T = comptime pointee(@TypeOf(value));
    comptime verify(T);
    var sink: First = .{ .buf = path_buf };
    walkRoot(T, value, &sink) catch |err| switch (err) {};
    return sink.found;
}

/// The violations of `value.*` in walk order: at most one per path, since the
/// walk does not descend into a value that failed, and at most
/// `max_report_violations` in all. `value` is passed as for `check`, and
/// paths name fields as `check`'s do. The report owns its memory, one arena
/// from `gpa`, even when it is empty: call `deinit` once. On
/// `error.OutOfMemory` everything is already freed. Calls on several threads
/// at once are safe when `gpa` is thread-safe and no thread changes the
/// value meanwhile.
pub fn checkAll(gpa: Allocator, value: anytype) Allocator.Error!Report {
    const T = comptime pointee(@TypeOf(value));
    comptime verify(T);
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    var sink: All = .{ .arena = arena.allocator() };
    try walkRoot(T, value, &sink);
    return .{ .violations = sink.list.items, .truncated = sink.truncated, .arena = arena };
}

/// The result of `checkAll`, like `std.json.Parsed`: the violations and
/// their paths live in `arena`. Copies share the memory; call `deinit` once.
pub const Report = struct {
    /// In walk order; the first one equals `check`'s result (its `field` too
    /// when the path fits `check`'s `path_buf`).
    violations: []const Violation,
    /// More than `max_report_violations` violations existed: the walk stopped
    /// at the next one, which is not in `violations`.
    truncated: bool,
    /// Implementation detail: holds `violations` and every `field` (code and
    /// message are static). Do not read or free it; call `deinit`.
    arena: *std.heap.ArenaAllocator,

    /// Frees `violations` and every `field` through the allocator given to
    /// `checkAll`.
    pub fn deinit(report: Report) void {
        const gpa = report.arena.child_allocator;
        report.arena.deinit();
        gpa.destroy(report.arena);
    }
};

/// The compile-time declaration check of `T` and of every type the walker
/// would visit from it, without walking a value: exactly the checks that
/// `check`, `checkAll` and `transform` run for a `*T`, names and transforms
/// included. Zig analyzes only code that is referenced, so a package that
/// declares DTOs calls it in a test to have their declarations checked where
/// they are written: `test { comptime v.assertRules(CreateUserRequest); }`.
/// Pass the DTO type itself (`CreateUserRequest`, `[]const User`), not a
/// pointer type: pointers are not walked. It also analyzes the body of every
/// `validateSelf`, an `inline fn` included, so the compile-time checks of
/// `v.fail` run too. Does nothing at run time.
pub fn assertRules(comptime T: type) void {
    comptime verify(T);
}

/// Runs the transforms of `field_rules` on `value.*` and on everything the
/// walk reaches from it: struct fields, optionals, the items of slices and
/// arrays, nested structs, as `checkAll` reaches them. The rules are
/// skipped: call `v.check` or `v.checkAll` afterwards, so that they check
/// the transformed value. `value` is a pointer to a `var` (`&value`) of a
/// struct, an optional, a list slice or an array; a type without transforms
/// is left as it is, without a look at the value.
///
/// The parts of a value come first, then its own transforms, left to right:
/// the items of a list before the transforms of the list, the fields of a
/// struct before those of the field that holds it. A slice is never written
/// to: when an item changes, the slice is replaced by a copy in `allocator`,
/// made once, at the first item that changes. Arrays and fields change in
/// place. New strings and copies come from `allocator`, and nothing is
/// freed, so `allocator` must be an arena (or another allocator that is
/// freed as a whole) that lives as long as the value: the transformed value
/// mixes its own memory with memory from `allocator` (a trimmed string is a
/// part of the original, a string or a list that did not change is the
/// original), so its parts cannot be freed one by one.
///
/// An error of a `v.transformWith` function stops the walk and comes back
/// as it is, and so does `error.OutOfMemory`; the value may then be partly
/// transformed. The error set is exact: `v.TransformError(T)`.
pub fn transform(allocator: Allocator, value: anytype) TransformError(transformPointee(@TypeOf(value)))!void {
    const T = comptime transformPointee(@TypeOf(value));
    comptime verify(T);
    const E = TransformError(T);
    // A type without transforms costs nothing: nothing is read or written.
    if (comptime !containsTransforms(T)) return;
    if (comptime inPlace(@TypeOf(value), T)) {
        _ = try transformValue(E, T, value, &.{}, &.{}, allocator);
        return;
    }
    // A pointer that does not coerce to *T (volatile, allowzero,
    // under-aligned, a bit pointer): the value is transformed as a copy,
    // which is written back when it changed.
    var copy: T = value.*;
    if (try transformValue(E, T, &copy, &.{}, &.{}, allocator)) value.* = copy;
}

/// The error set of `v.transform` on a `*T`: `error.OutOfMemory` and the
/// errors of every `v.transformWith` function in the `field_rules` that the
/// walk reaches from `T`, exactly; `error{OutOfMemory}` for a type without
/// them. Runs the declaration check of `T` first.
pub fn TransformError(comptime T: type) type {
    comptime {
        @setEvalBranchQuota(core.eval_quota);
        var E: type = Allocator.Error;
        // The structs that the declaration check visited.
        for (visit(T, @typeName(T), &.{}, &.{})) |S| {
            const info = @typeInfo(S).@"struct";
            for (info.field_names, info.field_attrs) |name, attrs| {
                if (attrs.@"comptime") continue;
                const parts = entryFor(S, name);
                E = E || transformErrors(parts.transforms, parts.rules);
            }
        }
        return E;
    }
}

/// The errors of `transforms` and of the item transforms of the `each` in
/// `rules`, at every depth.
fn transformErrors(comptime transforms: []const Transform, comptime rules: []const Rule) type {
    var E: type = error{};
    for (transforms) |t| E = E || t.Error();
    for (rules) |rule| {
        if (rule.kind == .each) E = E || transformErrors(rule.item_transforms, rule.inner);
    }
    return E;
}

/// Builds the result of a `validateSelf`, checked at compile time: `T` is the
/// struct that declares `validateSelf` (usually `@This()`), `field` names one
/// of its non-comptime fields (`.end`) or is null for the struct itself, and
/// `code` and `message` follow the rules of `v.custom`. `field` is the Zig
/// name of the field, which `Violation.field` holds; the walk reports the
/// violation at the field's outside name (`v.rename`).
///
///     return v.fail(@This(), .end, "orders.end_before_start", "must not be before start");
pub fn fail(comptime T: type, comptime field: ?FailField(T), comptime code: []const u8, comptime message: []const u8) Violation {
    comptime {
        @setEvalBranchQuota(core.eval_quota);
        const where = failCall(T, field);
        if (failFieldProblem(T, field)) |text| @compileError(text);
        core.checkCode(where, code);
        core.checkMessage(where, message);
    }
    return .{ .code = code, .message = message, .field = if (field) |f| @tagName(f) else null };
}

/// The call of `fail` as its errors show it: `fail(orders.Booking, .end)`,
/// or `null` for the struct itself; the field is written as zig fmt writes
/// it (`.@"error"`).
fn failCall(comptime T: type, comptime field: ?FailField(T)) []const u8 {
    // A struct declared in place has a generated name: show the name its
    // own code uses for it.
    const type_name = if (isAnonymous(T)) "@This()" else @typeName(T);
    return "fail(" ++ type_name ++ ", " ++ (if (field) |f| "." ++ core.tagIdentifier(@tagName(f)) else "null") ++ ")";
}

/// The error of `fail` about its `field`, or null: a comptime field is not
/// validated, so no violation may name it.
fn failFieldProblem(comptime T: type, comptime field: ?FailField(T)) ?[]const u8 {
    const f = field orelse return null;
    if (!isComptimeField(T, @tagName(f))) return null;
    return "validator: " ++ failCall(T, field) ++ ": " ++ core.tagIdentifier(@tagName(f)) ++ " is a comptime field; comptime fields are not validated";
}

/// A struct with fields that Zig source writes with `@"..."`, for the tests of
/// `fail`'s texts.
const TestQuotedFields = struct {
    @"error": u32,
    plain: u32,
    comptime @"while": u32 = 0,
};

test "fail's errors show the call with the field as zig fmt writes it" {
    const expect = std.testing.expectEqualStrings;
    try expect("fail(walk.TestQuotedFields, .@\"error\")", comptime failCall(TestQuotedFields, .@"error"));
    try expect("fail(walk.TestQuotedFields, .plain)", comptime failCall(TestQuotedFields, .plain));
    try expect("fail(walk.TestQuotedFields, null)", comptime failCall(TestQuotedFields, null));
    try expect(
        "validator: fail(walk.TestQuotedFields, .@\"while\"): @\"while\" is a comptime field; comptime fields are not validated",
        comptime failFieldProblem(TestQuotedFields, .@"while").?,
    );
    try std.testing.expectEqual(null, comptime failFieldProblem(TestQuotedFields, .@"error"));
    try std.testing.expectEqual(null, comptime failFieldProblem(TestQuotedFields, null));
}

/// The type of `fail`'s `field`: the field names of `T` as an enum, so that a
/// misspelled field is Zig's own error at the caller's line. A `T` that is not
/// a struct is rejected here, before `std.meta.FieldEnum` would fail inside std.
fn FailField(comptime T: type) type {
    if (@typeInfo(T) != .@"struct")
        @compileError("validator: fail(" ++ @typeName(T) ++ "): expects the struct that declares validateSelf, e.g. v.fail(@This(), .field, code, message)");
    return std.meta.FieldEnum(T);
}

/// The root type behind `&value`. A value or a bare slice is a compile error:
/// the root must be passed by pointer, so that a slice root is unambiguous.
/// So is `&request` when `request` is already a pointer to rules, the usual
/// slip in a handler that takes `request: *const T`.
fn pointee(comptime P: type) type {
    switch (@typeInfo(P)) {
        .pointer => |p| if (p.size == .one) {
            const inner = @typeInfo(p.child);
            if (inner == .pointer and inner.pointer.size == .one and containsRules(p.child))
                @compileError("validator: pass a pointer to the value (&value), got " ++ @typeName(P) ++ "; the value is already a pointer: pass it without &");
            return p.child;
        },
        else => {},
    }
    const slice_hint = if (@typeInfo(P) == .pointer and @typeInfo(P).pointer.size == .slice) "; pass &slice, not the slice" else "";
    @compileError("validator: pass a pointer to the value (&value), got " ++ @typeName(P) ++ slice_hint);
}

/// The root type behind `&value` for `transform`: as `pointee`, and the
/// pointer may not be const, since the value changes. Any root type, even
/// one without transforms.
fn transformPointee(comptime P: type) type {
    const T = pointee(P);
    if (@typeInfo(P).pointer.attrs.@"const")
        @compileError("validator: transform changes the value: pass a pointer to a var (&value), got " ++ @typeName(P));
    return T;
}

// ------------------------------------------------------------------ which types carry rules

/// A type declares rules: `field_rules`, `validateSelf`, or rules written
/// under confy's hook name `validate` (see `misnamedRules`).
fn declaresRules(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "field_rules") or @hasDecl(T, "validateSelf") or misnamedRules(T),
        else => false,
    };
}

/// A `validate` that is not a function (a `field_rules` table under the
/// wrong name), or a `pub fn validate` shaped like `validateSelf`: one
/// parameter `*const T`, `T` or `*T`, returning `?Violation`. Confy's hook
/// returns an error union, so it and every other signature are left alone.
fn misnamedRules(comptime T: type) bool {
    if (!@hasDecl(T, "validate")) return false;
    return switch (@typeInfo(@TypeOf(T.validate))) {
        .@"fn" => |f| f.param_types.len == 1 and
            (f.param_types[0] == *const T or f.param_types[0] == T or f.param_types[0] == *T) and
            f.return_type != null and f.return_type.? == ?Violation,
        else => true,
    };
}

fn includes(comptime list: []const type, comptime T: type) bool {
    for (list) |X| {
        if (X == T) return true;
    }
    return false;
}

/// Types reached from `X` when looking for rules: the non-comptime fields of
/// a struct, the fields of a union, and the children of optionals, pointers
/// of every size, arrays, vectors and error-union payloads.
fn reachable(comptime X: type) []const type {
    return switch (@typeInfo(X)) {
        .@"struct" => |s| blk: {
            var out: []const type = &.{};
            for (s.field_types, s.field_attrs) |F, attrs| {
                if (!attrs.@"comptime") out = out ++ &[_]type{F};
            }
            break :blk out;
        },
        .@"union" => |u| u.field_types,
        .optional => |o| &.{o.child},
        .pointer => |p| &.{p.child},
        .array => |a| &.{a.child},
        .vector => |v| &.{v.child},
        .error_union => |e| &.{e.payload},
        else => &.{},
    };
}

/// A type declares something for the check walk: `validateSelf`, a misnamed
/// `validate`, or rules in its `field_rules`; names and transforms, those
/// of an `each` included, are not rules. Anything but a struct with a
/// well-formed `field_rules` that declares rules at all counts, so that the
/// declaration check reports what is wrong with it.
fn declaresChecks(comptime T: type) bool {
    if (!declaresRules(T)) return false;
    if (@typeInfo(T) != .@"struct" or @hasDecl(T, "validateSelf") or misnamedRules(T)) return true;
    if (!core.isFieldRulesTable(@TypeOf(T.field_rules))) return true;
    const info = @typeInfo(T).@"struct";
    for (info.field_names, info.field_attrs) |name, attrs| {
        if (!attrs.@"comptime" and core.hasCheckRules(entryFor(T, name).rules)) return true;
    }
    return false;
}

/// A struct declares transforms: some entry of its `field_rules` has
/// transforms of its own or for its items, inside `each`.
fn declaresTransforms(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct" or !@hasDecl(T, "field_rules") or !core.isFieldRulesTable(@TypeOf(T.field_rules))) return false;
    const info = @typeInfo(T).@"struct";
    for (info.field_names, info.field_attrs) |name, attrs| {
        if (attrs.@"comptime") continue;
        const parts = entryFor(T, name);
        if (parts.transforms.len > 0 or core.hasItemTransforms(parts.rules)) return true;
    }
    return false;
}

/// What a search looks for: anything in `field_rules` or `validateSelf`
/// (the declaration checks), rules (the check walk) or transforms (the
/// transform walk).
const Search = enum { rules, checks, transforms };

/// The nearest type reachable from `T` (`T` included) that declares what
/// `search` looks for. Breadth-first with one visited set, so each type is
/// looked at once per query; Zig memoizes the result per type.
fn findDeclaring(comptime T: type, comptime search: Search) ?type {
    comptime {
        @setEvalBranchQuota(core.eval_quota);
        var queue: []const type = &.{T};
        var next: usize = 0;
        while (next < queue.len) : (next += 1) {
            const X = queue[next];
            const found = switch (search) {
                .rules => declaresRules(X),
                .checks => declaresChecks(X),
                .transforms => declaresTransforms(X),
            };
            if (found) return X;
            for (reachable(X)) |C| {
                if (!includes(queue, C)) queue = queue ++ &[_]type{C};
            }
        }
        return null;
    }
}

/// The nearest type reachable from `T` (`T` included) that declares rules.
fn findRuleType(comptime T: type) ?type {
    return findDeclaring(T, .rules);
}

fn containsRules(comptime T: type) bool {
    return findRuleType(T) != null;
}

/// Something in or below `T` has rules to check. Only after `verify(T)`:
/// the search reads the entries of `field_rules`.
fn containsChecks(comptime T: type) bool {
    return findDeclaring(T, .checks) != null;
}

/// Something in or below `T` has transforms. Only after `verify(T)`, as
/// `containsChecks`.
fn containsTransforms(comptime T: type) bool {
    return findDeclaring(T, .transforms) != null;
}

/// A struct (not a tuple) with rules in it or below it: the check walk
/// visits its fields.
fn isWalkedStruct(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and !@typeInfo(T).@"struct".is_tuple and containsChecks(T);
}

/// A struct (not a tuple) with transforms in it or below it: the transform
/// walk visits its fields.
fn isTransformedStruct(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and !@typeInfo(T).@"struct".is_tuple and containsTransforms(T);
}

// ------------------------------------------------------------------ declaration checks

/// Every compile-time check of `Root` and of each type the walker visits from
/// it: `check`, `checkAll` and `assertRules` run it before anything else.
/// Each struct is checked once per root.
fn verify(comptime Root: type) void {
    comptime {
        @setEvalBranchQuota(core.eval_quota);
        _ = visit(Root, @typeName(Root), &.{}, &.{});
    }
}

/// Checks `T` and every type the walker visits below it, and returns `done`
/// plus the structs it finished. `where` names `T` in errors: the root type
/// or the nearest named struct above `T`, then `.field` per field and `[]`
/// per list level (`shop.Order.items[]`). `stack` holds the structs being
/// visited, so a struct that reaches itself is an error instead of an
/// endless descent.
fn visit(comptime T: type, comptime where: []const u8, comptime stack: []const type, comptime done: []const type) []const type {
    @setEvalBranchQuota(core.eval_quota);
    switch (@typeInfo(T)) {
        .optional => |o| return visit(o.child, where, stack, done),
        .array => |a| return visit(a.child, where ++ "[]", stack, done),
        .pointer => {
            // A string is a leaf and a list slice is walked item by item, as
            // in walkValue; every other pointer is opaque: one-item, many-item
            // and C pointers, and volatile, allowzero or under-aligned slices.
            if (core.isString(T)) return done;
            if (core.ListChild(T)) |Item| return visit(Item, where ++ "[]", stack, done);
            hidden(T, "pointers", where);
        },
        .@"struct" => |s| {
            if (s.is_tuple) {
                hidden(T, "tuples", where);
                return done;
            }
            if (!containsRules(T) or includes(done, T)) return done;
            if (includes(stack, T))
                @compileError("validator: " ++ where ++ ": recursive types are not supported; " ++ @typeName(T) ++ " contains itself");
            const label = if (isAnonymous(T)) where else @typeName(T);
            checkStruct(T, label);
            var finished = done;
            for (s.field_names, s.field_types, s.field_attrs) |name, F, attrs| {
                if (!attrs.@"comptime") finished = visit(F, label ++ "." ++ name, stack ++ &[_]type{T}, finished);
            }
            return finished ++ &[_]type{T};
        },
        .@"union" => hidden(T, "unions", where),
        .@"enum" => hidden(T, "enums", where),
        .@"opaque" => hidden(T, "opaque types", where),
        .vector => hidden(T, "vectors", where),
        .error_union => hidden(T, "error unions", where),
        else => {},
    }
    return done;
}

/// `T` is a type the walker does not descend into; `what` names its kind in
/// the error ("pointers", "unions", ...). Rules, `validateSelf` and
/// transforms declared below `T` would be skipped without a word, so
/// reaching a type that declares them is a compile error. Outside names
/// alone are not: no path goes below `T`, so nothing would use them. To
/// tell them apart, the search reads the entries of `field_rules` below
/// `T`, which no declaration check visits: an entry with something other
/// than a name, transforms and rules stops compilation there.
fn hidden(comptime T: type, comptime what: []const u8, comptime where: []const u8) void {
    const skipped: ?type = findDeclaring(T, .checks) orelse findDeclaring(T, .transforms);
    if (skipped) |R| {
        const reach = if (R == T) @typeName(T) ++ " declares" else @typeName(T) ++ " reaches " ++ @typeName(R) ++ ", which declares";
        // A type that declares only a misnamed validate has neither name.
        const declared = if (@hasDecl(R, "field_rules") or @hasDecl(R, "validateSelf"))
            " field_rules or validateSelf that would be skipped"
        else if (@typeInfo(@TypeOf(R.validate)) == .@"fn")
            " a pub fn validate shaped like validateSelf, which counts as rules that would be skipped"
        else
            " a non-function validate, which counts as rules that would be skipped; rename it (rules belong in pub const field_rules)";
        @compileError("validator: " ++ where ++ ": " ++ what ++ " are not walked; " ++ reach ++ declared);
    }
}

/// Errors name a struct declared in place by its path instead of its
/// generated name (`users.Request.address`, not `users.Request__struct_1234`).
const isAnonymous = core.isAnonymous;

/// The declaration checks of one walked struct, named `label` in errors: a
/// misnamed `validate`, `field_rules`, the outside names of the fields (one
/// that would make paths ambiguous, two fields with one name), then
/// `validateSelf`.
fn checkStruct(comptime T: type, comptime label: []const u8) void {
    @setEvalBranchQuota(core.eval_quota);
    if (misnamedRules(T)) {
        const fix = if (@typeInfo(@TypeOf(T.validate)) == .@"fn")
            "returns ?validator.Violation; rename it to validateSelf (a pub fn validate returning !void is left to confy)"
        else
            "rules are declared in pub const field_rules; rename validate to field_rules (a pub fn validate returning !void is left to confy)";
        @compileError("validator: " ++ label ++ ".validate: " ++ fix);
    }
    if (@hasDecl(T, "field_rules")) checkFieldRules(T, label);
    // Paths name fields by their outside names: a `v.rename` takes away
    // the ambiguity of a Zig name with a dot or a bracket.
    const info = @typeInfo(T).@"struct";
    const outside = names.namesOf(T);
    for (info.field_names, info.field_attrs, outside) |name, attrs, outside_name| {
        if (attrs.@"comptime") continue;
        if (std.mem.findAny(u8, outside_name, ".[]") != null)
            @compileError("validator: " ++ label ++ "." ++ name ++ ": a field name with '.', '[' or ']' makes paths ambiguous; " ++ core.hints.outside_name);
    }
    if (names.duplicateText(T, label, outside)) |text| @compileError(text);
    if (@hasDecl(T, "validateSelf")) checkValidateSelf(T, label);
}

/// `field_rules` is a struct literal whose keys are non-comptime fields of
/// `T` and whose values are entries that fit those fields: an outside
/// name, transforms and rules, in this order.
fn checkFieldRules(comptime T: type, comptime label: []const u8) void {
    @setEvalBranchQuota(core.eval_quota);
    const R = @TypeOf(T.field_rules);
    const shape = @typeInfo(R);
    if (!core.isFieldRulesTable(R)) {
        const got = if (shape == .@"struct" and shape.@"struct".is_tuple) "a tuple" else @typeName(R);
        @compileError("validator: " ++ label ++ ".field_rules: must be a struct literal .{ .field = element or .{ elements } }, got " ++ got);
    }
    for (shape.@"struct".field_names) |key| {
        const where = label ++ ".field_rules." ++ key;
        if (fieldIndex(T, key) == null) @compileError("validator: " ++ where ++ ": no such field" ++ core.suggestion(T, key));
        if (isComptimeField(T, key)) @compileError("validator: " ++ where ++ ": comptime fields are not validated");
        // An entry is one element or a tuple of one or more: `.x = .{}` is
        // usually a leftover whose rules were deleted.
        const value = @field(T.field_rules, key);
        const entry = @typeInfo(@TypeOf(value));
        if (entry == .@"struct" and entry.@"struct".is_tuple and entry.@"struct".field_names.len == 0)
            @compileError("validator: " ++ where ++ ": the list is empty");
        const parts = core.entryParts(value, where, false);
        if (parts.problem) |problem| @compileError(core.entryProblemText(problem, where));
        const U = core.Unwrap(@FieldType(T, key));
        core.checkTransforms(parts.transforms, U, where);
        core.checkRuleList(parts.rules, U, where);
    }
}

/// `validateSelf` must be `pub fn validateSelf(self: *const T) ?Violation`;
/// an `inline fn` is accepted (only the parameter and return types are
/// compared). The body is then analyzed through a generated caller, so the
/// compile-time checks of `v.fail` inside it run under `assertRules` too
/// (taking `&T.validateSelf` would not analyze an inline body).
fn checkValidateSelf(comptime T: type, comptime label: []const u8) void {
    const F = @TypeOf(T.validateSelf);
    const ok = switch (@typeInfo(F)) {
        .@"fn" => |f| f.param_types.len == 1 and f.param_types[0] == *const T and
            f.return_type != null and f.return_type.? == ?Violation,
        else => false,
    };
    const self_type = if (isAnonymous(T)) "@This()" else @typeName(T);
    if (!ok) @compileError("validator: " ++ label ++ ".validateSelf: must be `pub fn validateSelf(self: *const " ++ self_type ++
        ") ?validator.Violation`, got " ++ @typeName(F));
    _ = &struct {
        fn call(self: *const T) ?Violation {
            return T.validateSelf(self);
        }
    }.call;
}

fn fieldIndex(comptime T: type, comptime name: []const u8) ?usize {
    for (@typeInfo(T).@"struct".field_names, 0..) |field, i| {
        if (std.mem.eql(u8, field, name)) return i;
    }
    return null;
}

fn isComptimeField(comptime T: type, comptime name: []const u8) bool {
    const i = fieldIndex(T, name) orelse return false;
    return @typeInfo(T).@"struct".field_attrs[i].@"comptime";
}

/// The entry of field `name` of `T` taken apart, or an empty one. For the
/// walks, after `verify`: the declaration check has reported what is wrong
/// with it, with the path of `T`.
fn entryFor(comptime T: type, comptime name: []const u8) core.EntryParts {
    if (!@hasDecl(T, "field_rules")) return .{};
    const R = @TypeOf(T.field_rules);
    if (!core.isFieldRulesTable(R) or !@hasField(R, name)) return .{};
    return core.entryParts(@field(T.field_rules, name), @typeName(T) ++ ".field_rules." ++ name, false);
}

/// The rules of field `name` of `T` as a slice, or none.
fn rulesFor(comptime T: type, comptime name: []const u8) []const Rule {
    return entryFor(T, name).rules;
}

/// The indices of the fields of struct `T` that the check walk visits, in
/// declaration order: not comptime, with rules in or below them. A field
/// with only a name or transforms, for itself or in its `each`, is not
/// among them.
fn walkedFields(comptime T: type) []const usize {
    comptime {
        @setEvalBranchQuota(core.eval_quota);
        const info = @typeInfo(T).@"struct";
        var out: []const usize = &.{};
        for (info.field_names, info.field_types, info.field_attrs, 0..) |name, F, attrs, i| {
            if (attrs.@"comptime") continue;
            if (!core.hasCheckRules(rulesFor(T, name)) and !containsChecks(F)) continue;
            out = out ++ &[_]usize{i};
        }
        return out;
    }
}

/// The indices of the fields of struct `T` that the transform walk visits,
/// in declaration order: not comptime, with transforms in their entries or
/// below them.
fn transformedFields(comptime T: type) []const usize {
    comptime {
        @setEvalBranchQuota(core.eval_quota);
        const info = @typeInfo(T).@"struct";
        var out: []const usize = &.{};
        for (info.field_names, info.field_types, info.field_attrs, 0..) |name, F, attrs, i| {
            if (attrs.@"comptime") continue;
            const parts = entryFor(T, name);
            if (hasTransforms(F, parts.transforms, parts.rules)) out = out ++ &[_]usize{i};
        }
        return out;
    }
}

/// The names of the comptime fields of struct `T` (`comptime_fields` true)
/// or of its other fields.
fn fieldNames(comptime T: type, comptime comptime_fields: bool) []const []const u8 {
    comptime {
        const info = @typeInfo(T).@"struct";
        var out: []const []const u8 = &.{};
        for (info.field_names, info.field_attrs) |name, attrs| {
            if (attrs.@"comptime" == comptime_fields) out = out ++ &[_][]const u8{name};
        }
        return out;
    }
}

/// The outside names of the non-comptime fields of struct `T`, in the order
/// of `fieldNames(T, false)`.
fn outsideFieldNames(comptime T: type) []const []const u8 {
    comptime {
        const info = @typeInfo(T).@"struct";
        var out: []const []const u8 = &.{};
        for (info.field_attrs, names.namesOf(T)) |attrs, name| {
            if (!attrs.@"comptime") out = out ++ &[_][]const u8{name};
        }
        return out;
    }
}

// ------------------------------------------------------------------ paths

const Segment = union(enum) { field: []const u8, index: usize };

/// The only place that produces path text: `.name` (no dot at the root) and
/// `[index]` (0-based decimal).
fn writeSegment(out: anytype, at_root: bool, segment: Segment) !void {
    switch (segment) {
        .field => |name| {
            if (!at_root) try out.writeAll(".");
            try out.writeAll(name);
        },
        .index => |index| {
            var digits: [20]u8 = undefined;
            var start: usize = digits.len;
            var rest = index;
            while (true) {
                start -= 1;
                digits[start] = @intCast('0' + rest % 10);
                rest /= 10;
                if (rest == 0) break;
            }
            try out.writeAll("[");
            try out.writeAll(digits[start..]);
            try out.writeAll("]");
        },
    }
}

// ------------------------------------------------------------------ sinks

/// `check`: the first violation; the path goes into the caller's buffer.
/// `len` is the logical path length: writes past the buffer are dropped, so
/// a path that fits after a longer sibling's overflow is still exact.
const First = struct {
    buf: []u8,
    len: usize = 0,
    found: ?Violation = null,

    const Error = error{};

    fn writeAll(sink: *First, bytes: []const u8) Error!void {
        if (sink.len < sink.buf.len) {
            const n = @min(bytes.len, sink.buf.len - sink.len);
            @memcpy(sink.buf[sink.len..][0..n], bytes[0..n]);
        }
        sink.len += bytes.len;
    }

    /// The mark that `pop` takes the path back to.
    fn pathLen(sink: *const First) usize {
        return sink.len;
    }

    fn push(sink: *First, segment: Segment) Error!void {
        try writeSegment(sink, sink.len == 0, segment);
    }

    fn pop(sink: *First, mark: usize) void {
        sink.len = mark;
    }

    /// Keeps the violation; its field is the path only when the whole path
    /// fits the buffer.
    fn report(sink: *First, code: []const u8, message: []const u8) Error!void {
        const fits = sink.len != 0 and sink.len <= sink.buf.len;
        sink.found = .{ .code = code, .message = message, .field = if (fits) sink.buf[0..sink.len] else null };
    }

    /// True after the first violation: the walk stops there.
    fn stopped(sink: *const First) bool {
        return sink.found != null;
    }

    /// Violations reported so far: 0 or 1.
    fn count(sink: *const First) usize {
        return @intFromBool(sink.found != null);
    }
};

/// `checkAll`: every violation up to the cap; the paths and the list live
/// in the report's arena.
const All = struct {
    arena: Allocator,
    path: std.ArrayList(u8) = .empty,
    list: std.ArrayList(Violation) = .empty,
    truncated: bool = false,

    const Error = Allocator.Error;

    fn writeAll(sink: *All, bytes: []const u8) Error!void {
        try sink.path.appendSlice(sink.arena, bytes);
    }

    /// The mark that `pop` takes the path back to.
    fn pathLen(sink: *const All) usize {
        return sink.path.items.len;
    }

    fn push(sink: *All, segment: Segment) Error!void {
        try writeSegment(sink, sink.path.items.len == 0, segment);
    }

    fn pop(sink: *All, mark: usize) void {
        sink.path.shrinkRetainingCapacity(mark);
    }

    /// Keeps the violation, or marks the report truncated when the cap is
    /// already reached.
    fn report(sink: *All, code: []const u8, message: []const u8) Error!void {
        if (sink.list.items.len == core.max_report_violations) {
            sink.truncated = true;
            return;
        }
        const field: ?[]const u8 = if (sink.path.items.len == 0) null else try sink.arena.dupe(u8, sink.path.items);
        try sink.list.append(sink.arena, .{ .code = code, .message = message, .field = field });
    }

    /// True only after a violation beyond the cap showed up: the walk stops
    /// there.
    fn stopped(sink: *const All) bool {
        return sink.truncated;
    }

    /// Violations kept so far.
    fn count(sink: *const All) usize {
        return sink.list.items.len;
    }
};

fn ErrorOf(comptime SinkPtr: type) type {
    return @typeInfo(SinkPtr).pointer.child.Error;
}

// ------------------------------------------------------------------ the walk

/// Walks the root of `check` and `checkAll` behind `value`, the pointer they
/// were given. A pointer that coerces to the `*const T` that the walk takes
/// is walked in place, an over-aligned or explicitly aligned one too (a
/// `std.heap.MemoryPool(T)` item is a `*align(N) T`, a pointer type of its
/// own). `*volatile T`, `*allowzero T`, an under-aligned `*align(1) const T`
/// and a bit pointer to a packed field do not coerce: such a root is walked
/// through a copy of its value, as walkStruct walks a packed or under-aligned
/// field, and the copy takes the whole value onto the stack.
fn walkRoot(comptime T: type, value: anytype, sink: anytype) ErrorOf(@TypeOf(sink))!void {
    // A root without rules is never read: there is nothing to walk, an opaque
    // type has no value to copy, and inPlace would ask for its alignment.
    if (comptime !containsChecks(T)) return;
    if (comptime inPlace(@TypeOf(value), T)) return walkValue(T, value, &.{}, sink);
    const copy: T = value.*;
    return walkValue(T, &copy, &.{}, sink);
}

/// `P`, a single-item pointer to `T`, coerces to `*const T`: it is neither
/// volatile nor allowzero, points into the generic address space, is aligned
/// at least as `T`, and is not a bit pointer (rebuilt from its attributes, a
/// bit pointer gives another type).
fn inPlace(comptime P: type, comptime T: type) bool {
    const p = @typeInfo(P).pointer;
    if (p.attrs.@"volatile" or p.attrs.@"allowzero") return false;
    if ((p.attrs.@"addrspace" orelse .generic) != .generic) return false;
    if ((p.attrs.@"align" orelse @alignOf(T)) < @alignOf(T)) return false;
    return P == @Pointer(.one, p.attrs, T, null);
}

/// Walks one value: its own rules left to right (the first failure is its
/// only violation and nothing inside it is visited); then, if all passed,
/// its items (with the list's `each` rules) or its fields and then its
/// `validateSelf`. Whether the walk stops is not returned: the caller asks
/// `sink.stopped()` afterwards, since every unrolled call in walkStruct
/// would keep a returned flag in a stack slot of its own.
fn walkValue(comptime T: type, value: *const T, comptime rules: []const Rule, sink: anytype) ErrorOf(@TypeOf(sink))!void {
    @setEvalBranchQuota(core.eval_quota);
    if (@typeInfo(T) == .optional) {
        const payload = if (value.*) |*p| p else return;
        return walkValue(@typeInfo(T).optional.child, payload, rules, sink);
    }
    inline for (comptime core.ownRules(rules)) |rule| {
        switch (rule.eval(value)) {
            .pass => {},
            .fail => return sink.report(rule.code, rule.message),
            .precondition => if (comptime rule.precondition) |p| return sink.report(p.code, p.message) else unreachable,
        }
    }
    if (comptime core.ListChild(T)) |Child| {
        const item_rules = comptime core.itemRules(rules);
        if (comptime (!core.hasCheckRules(item_rules) and !containsChecks(Child))) return;
        const items: []const Child = if (@typeInfo(T) == .array) value else value.*;
        for (items, 0..) |*item, i| {
            const mark = sink.pathLen();
            defer sink.pop(mark);
            try sink.push(.{ .index = i });
            try walkValue(Child, item, item_rules, sink);
            if (sink.stopped()) return;
        }
        return;
    }
    if (comptime isWalkedStruct(T)) return walkStruct(T, value, sink);
}

/// Walks the fields of a struct in declaration order; comptime fields and
/// fields with no rules in or below them are skipped. A field goes into the
/// path by its outside name. Then, when nothing in the struct's subtree
/// failed, runs `validateSelf` and reports its result through `reportSelf`.
fn walkStruct(comptime T: type, value: *const T, sink: anytype) ErrorOf(@TypeOf(sink))!void {
    @setEvalBranchQuota(core.eval_quota);
    const info = @typeInfo(T).@"struct";
    const before = sink.count();
    // The loop is unrolled, and each unrolled copy gets stack slots of its
    // own, so the frame grows with every unrolled field: fields without rules
    // are not unrolled, the mark is taken once (every field is pushed onto the
    // same path), and neither push nor walkValue returns a value (whether to
    // stop is read from the sink).
    const mark = sink.pathLen();
    inline for (comptime walkedFields(T)) |i| {
        const name = info.field_names[i];
        const F = info.field_types[i];
        const attrs = info.field_attrs[i];
        const rules = comptime rulesFor(T, name);
        defer sink.pop(mark);
        try sink.push(.{ .field = comptime names.namesOf(T)[i] });
        // A packed field has a bit pointer, and a field declared below the
        // alignment of its type (`n: u32 align(1)`) an under-aligned one:
        // neither coerces to `*const F`, so such a field is walked as a copy,
        // which takes the whole field onto the stack.
        const by_copy = comptime (info.layout == .@"packed" or (attrs.@"align" != null and attrs.@"align".? < @alignOf(F)));
        if (by_copy) {
            const copy: F = @field(value.*, name);
            try walkValue(F, &copy, rules, sink);
        } else try walkValue(F, &@field(value.*, name), rules, sink);
        if (sink.stopped()) return;
    }
    // validateSelf runs only when nothing in this struct's subtree failed.
    if (@hasDecl(T, "validateSelf") and sink.count() == before) {
        if (T.validateSelf(value)) |violation| return reportSelf(T, violation, sink);
    }
}

/// Checks a `validateSelf` result at run time, because a hand-built result
/// is not checked by the compiler: the code follows the custom-code grammar,
/// the message is 1-512 bytes of valid UTF-8, and `field` is null or the Zig
/// name of a non-comptime field of `T`. The result is reported at the
/// struct's path plus that field's outside name taken from `T`, so the path
/// never points into the caller's memory. A malformed result is a programmer
/// error: Debug builds panic; other modes report `validation.invalid` / "is
/// invalid" at the struct's path, so the value is rejected, not accepted.
fn reportSelf(comptime T: type, violation: Violation, sink: anytype) ErrorOf(@TypeOf(sink))!void {
    if (core.codeProblem(violation.code) != null) {
        if (builtin.mode == .debug)
            std.debug.panic("validator: {s}.validateSelf returned a malformed violation: code \"{f}\" is not a valid custom code", .{ @typeName(T), std.zig.fmtString(violation.code) });
        return sink.report("validation.invalid", "is invalid");
    }
    if (core.messageProblem(violation.message) != null) {
        if (builtin.mode == .debug)
            std.debug.panic("validator: {s}.validateSelf returned a malformed violation: its message is not 1-{d} bytes of valid UTF-8", .{ @typeName(T), core.max_message_bytes });
        return sink.report("validation.invalid", "is invalid");
    }
    const field = violation.field orelse return sink.report(violation.code, violation.message);
    // Run-time loops over the names: unrolling them would give every field its
    // own stack slots.
    for (comptime fieldNames(T, false), comptime outsideFieldNames(T)) |name, outside| {
        if (std.mem.eql(u8, name, field)) {
            const mark = sink.pathLen();
            defer sink.pop(mark);
            try sink.push(.{ .field = outside });
            return sink.report(violation.code, violation.message);
        }
    }
    if (builtin.mode == .debug) {
        for (comptime fieldNames(T, true)) |name| {
            if (std.mem.eql(u8, name, field))
                std.debug.panic("validator: {s}.validateSelf returned a malformed violation: field \"{f}\" is a comptime field of {s}; comptime fields are not validated", .{ @typeName(T), std.zig.fmtString(field), @typeName(T) });
        }
        std.debug.panic("validator: {s}.validateSelf returned a malformed violation: field \"{f}\" is not a field of {s}", .{ @typeName(T), std.zig.fmtString(field), @typeName(T) });
    }
    return sink.report("validation.invalid", "is invalid");
}

// ------------------------------------------------------------------ the transform walk

/// There is something to transform in a value of type `T` whose entry has
/// the transforms `own` and the rules `rules`: its own transforms, item
/// transforms in its `each`, or transforms below `T`.
fn hasTransforms(comptime T: type, comptime own: []const Transform, comptime rules: []const Rule) bool {
    return own.len > 0 or core.hasItemTransforms(rules) or containsTransforms(T);
}

/// Transforms one value: first its parts (the items of a list, with the
/// item transforms of the `each` in `rules`, or the fields of a struct),
/// then its own transforms `own`, left to right; an optional only when the
/// value is there. Returns whether the value changed: a string or a list
/// replaced, a field or an item changed. `E` is the error set of the whole
/// walk.
fn transformValue(comptime E: type, comptime T: type, value: *T, comptime own: []const Transform, comptime rules: []const Rule, allocator: Allocator) E!bool {
    @setEvalBranchQuota(core.eval_quota);
    if (comptime !hasTransforms(T, own, rules)) return false;
    if (@typeInfo(T) == .optional) {
        const payload = if (value.*) |*p| p else return false;
        return transformValue(E, @typeInfo(T).optional.child, payload, own, rules, allocator);
    }
    var changed = false;
    if (comptime core.ListChild(T)) |Item| {
        changed = try transformItems(E, T, Item, value, comptime core.itemTransforms(rules), comptime core.itemRules(rules), allocator);
    } else if (comptime isTransformedStruct(T)) {
        changed = try transformStruct(E, T, value, allocator);
    }
    inline for (own) |t| {
        const before = value.*;
        value.* = try apply(t, allocator, value.*);
        if (!same(T, before, value.*)) changed = true;
    }
    return changed;
}

/// `t` on `value`, as an error union whatever its function returns.
fn apply(comptime t: Transform, allocator: Allocator, value: anytype) t.Error()!@TypeOf(value) {
    return t.run.call(allocator, value);
}

/// Transforms the items of the list `value.*` with `own` and `rules`, as
/// `transformValue` transforms a value. An array changes in place. A slice
/// is never written to: at the first item that changes, a copy of the slice
/// is made in `allocator`, once, and takes the place of `value.*`. Returns
/// whether the list changed.
fn transformItems(comptime E: type, comptime T: type, comptime Item: type, value: *T, comptime own: []const Transform, comptime rules: []const Rule, allocator: Allocator) E!bool {
    if (comptime !hasTransforms(Item, own, rules)) return false;
    if (@typeInfo(T) == .array) {
        var changed = false;
        for (value) |*item| {
            if (try transformValue(E, Item, item, own, rules, allocator)) changed = true;
        }
        return changed;
    }
    const items = value.*;
    var copy: ?MutableList(T) = null;
    for (items, 0..) |original, i| {
        var item = original;
        const item_changed = try transformValue(E, Item, &item, own, rules, allocator);
        if (copy) |list| {
            list[i] = item;
        } else if (item_changed) {
            const list = try copyList(T, allocator, items);
            list[i] = item;
            copy = list;
        }
    }
    value.* = copy orelse return false;
    return true;
}

/// The list slice type `T` without `const`: the type of its copy.
fn MutableList(comptime T: type) type {
    const p = @typeInfo(T).pointer;
    var attrs = p.attrs;
    attrs.@"const" = false;
    return @Pointer(.slice, attrs, p.child, p.sentinel());
}

/// A copy of `items` in `allocator`, with the alignment and the sentinel of
/// `T`.
fn copyList(comptime T: type, allocator: Allocator, items: T) Allocator.Error!MutableList(T) {
    const p = @typeInfo(T).pointer;
    const alignment: ?std.mem.Alignment = comptime if (p.attrs.@"align") |a| .fromByteUnits(a) else null;
    const list = try allocator.allocWithOptions(p.child, items.len, alignment, comptime p.sentinel());
    @memcpy(list, items);
    return list;
}

/// Transforms the fields of a struct with transforms in or below them, in
/// declaration order. Returns whether a field changed.
fn transformStruct(comptime E: type, comptime T: type, value: *T, allocator: Allocator) E!bool {
    @setEvalBranchQuota(core.eval_quota);
    const info = @typeInfo(T).@"struct";
    var changed = false;
    inline for (comptime transformedFields(T)) |i| {
        const name = info.field_names[i];
        const F = info.field_types[i];
        const attrs = info.field_attrs[i];
        const parts = comptime entryFor(T, name);
        // A packed or under-aligned field has no *F, as in walkStruct: it is
        // transformed as a copy, written back when it changed.
        const by_copy = comptime (info.layout == .@"packed" or (attrs.@"align" != null and attrs.@"align".? < @alignOf(F)));
        if (by_copy) {
            var copy: F = @field(value.*, name);
            if (try transformValue(E, F, &copy, parts.transforms, parts.rules, allocator)) {
                @field(value.*, name) = copy;
                changed = true;
            }
        } else if (try transformValue(E, F, &@field(value.*, name), parts.transforms, parts.rules, allocator)) {
            changed = true;
        }
    }
    return changed;
}

/// `a` and `b` are the same value at a cheap look, which is how the walk
/// tells that a transform changed nothing: slices by address and length,
/// other pointers by address, numbers by their bits, bools and tags by
/// value, optionals, arrays and structs part by part. Any other type counts
/// as changed, which costs no more than the copy of a list.
fn same(comptime T: type, a: T, b: T) bool {
    switch (@typeInfo(T)) {
        .void => return true,
        .bool, .int, .@"enum" => return a == b,
        .float => {
            const Bits = @Int(.unsigned, @bitSizeOf(T));
            return @as(Bits, @bitCast(a)) == @as(Bits, @bitCast(b));
        },
        .pointer => |p| return if (p.size == .slice) a.ptr == b.ptr and a.len == b.len else a == b,
        .optional => |o| {
            const x = a orelse return b == null;
            const y = b orelse return false;
            return same(o.child, x, y);
        },
        .array => |arr| {
            for (a, b) |x, y| {
                if (!same(arr.child, x, y)) return false;
            }
            return true;
        },
        .@"struct" => |s| {
            if (s.backing_integer) |Int| return @as(Int, @bitCast(a)) == @as(Int, @bitCast(b));
            inline for (s.field_names, s.field_types, s.field_attrs) |name, F, attrs| {
                if (!attrs.@"comptime" and !same(F, @field(a, name), @field(b, name))) return false;
            }
            return true;
        },
        else => return false,
    }
}
