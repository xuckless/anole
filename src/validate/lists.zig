// Copied from vkiryakov/zefir src/validator/lists.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! List rules: `minItems`, `maxItems`, `uniqueItems`, `uniqueBy`,
//! `containsAll`, `containsNone` and `each`. A list is a slice whose items
//! are not `u8`, or an array `[N]T` (`[N]u8` included: it is an array of
//! numbers).
const std = @import("std");
const core = @import("core.zig");
const naming = @import("names.zig");
const schema = @import("schema.zig");
const Rule = core.Rule;
const Outcome = core.Outcome;

fn acceptsList(comptime T: type) bool {
    return core.ListChild(T) != null;
}

// ------------------------------------------------------------------ minItems, maxItems

/// `len >= min` on a slice: items are counted, null items included, never
/// checked. `min` is at least 1 (`minItems(0)` is always true). `v.notEmpty`
/// says the same as `minItems(1)` with its own code: prefer `v.notEmpty`
/// unless clients branch on `validation.min_items`. A fixed-size array `[N]T`
/// is a compile error: its length never changes.
pub fn minItems(comptime min: usize) Rule {
    @setEvalBranchQuota(core.eval_quota);
    if (countCallProblem(.min_items, min)) |text| @compileError(text);
    return countRule(.min_items, min, "must have at least " ++ core.plural(min, "item", "items"), "min");
}

/// `len <= max` on a slice, null items included. `max` is at least 1: for
/// no items use `v.empty`. A fixed-size array `[N]T` is a compile error.
pub fn maxItems(comptime max: usize) Rule {
    @setEvalBranchQuota(core.eval_quota);
    if (countCallProblem(.max_items, max)) |text| @compileError(text);
    return countRule(.max_items, max, "must have at most " ++ core.plural(max, "item", "items"), "max");
}

/// The error of the call `minItems(n)` or `maxItems(n)`, or null: the count
/// is at least 1.
fn countCallProblem(comptime kind: core.Kind, comptime n: usize) ?[]const u8 {
    if (n != 0) return null;
    return switch (kind) {
        .min_items => "validator: minItems(0): min must be at least 1 (minItems(0) is always true; remove it)",
        .max_items => "validator: maxItems(0): max must be at least 1; " ++ core.hints.use_empty,
        else => @compileError("validator: internal: " ++ @tagName(kind) ++ " is not a count rule"),
    };
}

/// `minItems(n)` or `maxItems(n)`, whose count is the placeholder `name`.
fn countRule(comptime kind: core.Kind, comptime n: usize, comptime message: []const u8, comptime name: []const u8) Rule {
    return core.define(kind, .{
        .message = message,
        .args = core.renderArg(n),
        .params = &.{core.param(name, n)},
        .bounds = &.{if (kind == .min_items) .atLeast(.items, n) else .atMost(.items, n)},
        .fits = countFits(n),
        .eval = struct {
            fn eval(value: anytype) Outcome {
                return core.passIf(if (kind == .min_items) value.*.len >= n else value.*.len <= n);
            }
        }.eval,
    });
}

/// The field-type check of `minItems(n)` and `maxItems(n)`.
fn countFits(comptime n: usize) fn (comptime *const Rule, comptime type, comptime []const u8) void {
    return struct {
        fn fits(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void {
            if (countProblem(rule, n, T, where)) |text| @compileError(text);
        }
    }.fits;
}

/// The declaration error of `minItems(n)` or `maxItems(n)` on the unwrapped
/// field type `T`, or null: the field is a slice that is not a string. On a
/// fixed-size array the verdict never changes, so the error says which it
/// is; a string field gets the string rules as the hint.
fn countProblem(comptime rule: *const Rule, comptime n: usize, comptime T: type, comptime where: []const u8) ?[]const u8 {
    switch (@typeInfo(T)) {
        .array => |a| {
            const always = if (rule.kind == .min_items) a.len >= n else a.len <= n;
            return core.ruleErrorText(rule, where, " on " ++ @typeName(T) ++ " is always " ++ (if (always) "true" else "false") ++ ": the length of an array is fixed");
        },
        else => {},
    }
    if (core.isListSlice(T)) return null;
    const strings = if (rule.kind == .min_items) core.hints.min_items_on_string else core.hints.max_items_on_string;
    return core.typeErrorText(rule, T, where, "a slice", core.isListSlice, if (core.isString(T)) strings else null);
}

// ------------------------------------------------------------------ uniqueItems, uniqueBy

/// No two items are equal: bools, enums and integers by value (exactly, at
/// every width; a non-exhaustive enum by its integer), strings byte for byte,
/// without case folding or normalization. Bools and exhaustive enums are
/// checked with a bitset in O(n), at any length. Integers, strings and
/// non-exhaustive enums are sorted on the stack in O(n log n), without
/// allocating: on a slice an earlier `v.maxItems(n)` in the same tuple must
/// cap the list at `max_unique_items` (1000), and on `[N]T` N must be at most
/// 1000. Float, optional, struct and other items are compile errors (for
/// structs use `v.uniqueBy`), and so is `[N]T` with N below 2 (always true)
/// or with more items than the item type has values (always false).
pub const uniqueItems: Rule = core.define(.unique_items, .{
    .message = "must not contain duplicates",
    .fits = struct {
        fn fits(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void {
            if (uniqueItemsProblem(rule, T, where)) |text| @compileError(text);
        }
    }.fits,
    .check_list = capCheck(null),
    .eval = uniqueEval(null),
});

/// No two struct items have equal values of the field `key`, written as a
/// field name: `v.uniqueBy(.id)`. Only the key is compared, as `uniqueItems`
/// compares items, with the same cap by the key's type; the key is a bool,
/// enum, integer or string field that is not comptime. The code is
/// `validation.unique_items`, as for `uniqueItems`; the message names the
/// key, which is also the placeholder `{key}`.
pub fn uniqueBy(comptime key: anytype) Rule {
    @setEvalBranchQuota(core.eval_quota);
    if (keyCallProblem(key)) |text| @compileError(text);
    const name = @tagName(key);
    return core.define(.unique_by, .{
        .message = "must not contain duplicate " ++ core.renderValue(key) ++ " values",
        .args = core.renderArg(key),
        .params = &.{core.param("key", key)},
        .fits = struct {
            fn fits(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void {
                if (uniqueByProblem(rule, name, T, where)) |text| @compileError(text);
            }
        }.fits,
        .check_list = capCheck(name),
        .eval = uniqueEval(name),
    });
}

/// The error of the call `uniqueBy(key)`, or null: the key is a field name
/// written as an enum literal.
fn keyCallProblem(comptime key: anytype) ?[]const u8 {
    const K = @TypeOf(key);
    if (@typeInfo(K) == .enum_literal) return null;
    return "validator: uniqueBy(" ++ core.renderArg(key) ++ "): the key must be a field name such as .id, got " ++ @typeName(K);
}

/// The declaration error of `uniqueItems` on the unwrapped field type `T`,
/// or null: a list of bools, enums, integers or strings, and on `[N]T` a
/// length the rule can decide at run time.
fn uniqueItemsProblem(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) ?[]const u8 {
    @setEvalBranchQuota(core.eval_quota);
    const Item = core.ListChild(T) orelse return core.typeErrorText(rule, T, where, "a slice or an array", acceptsList, null);
    const struct_text = "; struct items are not supported; " ++ core.hints.use_unique_by;
    if (keyTypeProblem(Item, "items are " ++ @typeName(Item), "items", struct_text)) |text| return core.ruleErrorText(rule, where, text);
    return uniqueArrayProblem(rule, T, Item, where);
}

/// The declaration error of `uniqueBy(.name)` on the unwrapped field type
/// `T`, or null: a list of structs whose non-comptime field `name` is a bool,
/// enum, integer or string, and on `[N]T` a length the rule can decide.
fn uniqueByProblem(comptime rule: *const Rule, comptime name: []const u8, comptime T: type, comptime where: []const u8) ?[]const u8 {
    @setEvalBranchQuota(core.eval_quota);
    const Item = core.ListChild(T) orelse return core.typeErrorText(rule, T, where, "a slice or an array of structs", acceptsList, null);
    const not_structs = ": items are " ++ @typeName(Item) ++ ", not structs; " ++ core.hints.use_unique_items;
    switch (@typeInfo(Item)) {
        .@"struct" => |s| if (s.is_tuple) return core.ruleErrorText(rule, where, not_structs),
        .optional => return core.ruleErrorText(rule, where, ": items are " ++ @typeName(Item) ++ "; optional items are not supported"),
        else => return core.ruleErrorText(rule, where, not_structs),
    }
    const shown = core.tagIdentifier(name);
    const info = @typeInfo(Item).@"struct";
    const index = for (info.field_names, 0..) |field, i| {
        if (std.mem.eql(u8, field, name)) break i;
    } else return core.ruleErrorText(rule, where, ": " ++ @typeName(Item) ++ " has no field " ++ shown ++ core.suggestion(Item, name));
    if (info.field_attrs[index].@"comptime") return core.ruleErrorText(rule, where, ": " ++ shown ++ " is a comptime field");
    const Key = info.field_types[index];
    if (keyTypeProblem(Key, "the key " ++ shown ++ " is " ++ @typeName(Key), "keys", null)) |text| return core.ruleErrorText(rule, where, text);
    return uniqueArrayProblem(rule, T, Key, where);
}

/// Why the compared values of type `K` (`noun`: "items" or "keys") cannot
/// be checked for uniqueness, as the text after the rule's label, or null:
/// they are bools, enums, integers or strings. `what` names them
/// (`items are f64`); `struct_text` is the text for structs, null for the
/// general one.
fn keyTypeProblem(comptime K: type, comptime what: []const u8, comptime noun: []const u8, comptime struct_text: ?[]const u8) ?[]const u8 {
    if (core.isString(K)) return null;
    const other = ": " ++ what ++ "; only bool, enum, integer and string " ++ noun ++ " are supported";
    return switch (@typeInfo(K)) {
        .bool, .int, .@"enum" => null,
        .float => ": " ++ what ++ "; float " ++ noun ++ " are not supported (NaN != NaN, -0.0 == 0.0)",
        .optional => ": " ++ what ++ "; optional " ++ noun ++ " are not supported",
        .@"struct" => |s| if (s.is_tuple) other else if (struct_text) |text| ": " ++ what ++ text else other,
        else => other,
    };
}

/// The declaration error of a uniqueness rule on `[N]T` with compared values
/// of type `K`, or null; a slice has none here. N below 2 is always true, N
/// above the number of values of `K` always false, and a sorted `K` needs N
/// to be at most `max_unique_items`.
fn uniqueArrayProblem(comptime rule: *const Rule, comptime T: type, comptime K: type, comptime where: []const u8) ?[]const u8 {
    const n = switch (@typeInfo(T)) {
        .array => |a| a.len,
        else => return null,
    };
    if (n <= 1) return core.ruleErrorText(rule, where, " on " ++ @typeName(T) ++ " is always true; remove it");
    if (n > valueCount(K)) return core.ruleErrorText(rule, where, std.fmt.comptimePrint(" on {s} is always false: {d} items cannot all differ", .{ @typeName(T), n }));
    if (needsCap(K) and n > core.max_unique_items)
        return core.ruleErrorText(rule, where, std.fmt.comptimePrint(" on {s}: {d} items is more than max_unique_items ({d})", .{ @typeName(T), n, core.max_unique_items }));
    return null;
}

/// How many different values of type `K` a list may hold: 2 for bool, the
/// number of tags of an exhaustive enum, every value of an integer type;
/// unbounded otherwise.
fn valueCount(comptime K: type) comptime_int {
    if (K == bool) return 2;
    return switch (@typeInfo(K)) {
        .@"enum" => |e| if (e.mode == .exhaustive) e.field_names.len else std.math.maxInt(e.tag_type) - std.math.minInt(e.tag_type) + 1,
        .int => std.math.maxInt(K) - std.math.minInt(K) + 1,
        else => std.math.maxInt(u128),
    };
}

/// Integers, strings and non-exhaustive enums are sorted on the stack, so
/// their lists are capped; bools and exhaustive enums use a bitset.
fn needsCap(comptime K: type) bool {
    return K != bool and !core.isExhaustiveEnum(K);
}

/// The type a uniqueness rule compares: the item, or its field `key`.
fn KeyOf(comptime Item: type, comptime key: ?[]const u8) type {
    return if (key) |name| @FieldType(Item, name) else Item;
}

/// The list check of `uniqueItems` (`key` null) and `uniqueBy(.key)`: a
/// slice whose compared values are sorted needs an earlier `maxItems(n)`
/// with `n <= max_unique_items` in the same tuple; the smallest earlier one
/// counts.
fn capCheck(comptime key: ?[]const u8) core.ListCheck {
    return struct {
        fn check(comptime rule: *const Rule, comptime rules: []const Rule, comptime index: usize, comptime T: type, comptime where: []const u8) void {
            if (capProblem(rule, rules[0..index], KeyOf(core.ListChild(T).?, key), T, where)) |text| @compileError(text);
        }
    }.check;
}

/// The cap error of a uniqueness rule that compares values of type `K` on
/// the unwrapped field type `T`, after the rules `earlier`, or null.
fn capProblem(comptime rule: *const Rule, comptime earlier: []const Rule, comptime K: type, comptime T: type, comptime where: []const u8) ?[]const u8 {
    @setEvalBranchQuota(core.eval_quota);
    if (!core.isListSlice(T) or !needsCap(K)) return null;
    var cap: ?comptime_int = null;
    var source: []const u8 = "";
    for (earlier) |*other| {
        for (other.bounds) |bound| {
            if (bound.measure != .items or bound.side != .upper) continue;
            const n: comptime_int = if (bound.inclusive) bound.value.int else bound.value.int - 1;
            if (cap == null or n < cap.?) {
                cap = n;
                source = other.label();
            }
        }
    }
    const n = cap orelse return core.ruleErrorText(rule, where, " " ++ core.hints.unique_cap);
    if (n > core.max_unique_items)
        return core.ruleErrorText(rule, where, std.fmt.comptimePrint(" after {s}: {d} is more than max_unique_items ({d})", .{ source, n, core.max_unique_items }));
    return null;
}

/// The run-time check of `uniqueItems` (`key` null) and `uniqueBy(.key)`.
fn uniqueEval(comptime key: ?[]const u8) fn (anytype) Outcome {
    return struct {
        fn eval(value: anytype) Outcome {
            const T = @TypeOf(value.*);
            const Item = core.ListChild(T) orelse @compileError("validator: internal: a uniqueness rule's eval was instantiated for a type its fits rejected");
            const K = KeyOf(Item, key);
            const items: []const Item = if (@typeInfo(T) == .array) value else value.*;
            const length: ?usize = if (@typeInfo(T) == .array) @typeInfo(T).array.len else null;
            return core.passIf(allUnique(Item, K, keyFn(Item, key), items, length));
        }
    }.eval;
}

/// The function that reads the compared value of an item.
fn keyFn(comptime Item: type, comptime key: ?[]const u8) fn (*const Item) KeyOf(Item, key) {
    return struct {
        fn get(item: *const Item) KeyOf(Item, key) {
            return if (key) |name| @field(item.*, name) else item.*;
        }
    }.get;
}

/// Lists of up to this many items are sorted in small buffers.
const short_list = 64;

/// No two of `items` have equal keys. Bools and exhaustive enums: a bitset,
/// O(n). Other keys are sorted on the stack by `sortedUnique`, which only a
/// list of 2 or more items reaches: a slice of up to `short_list` items in
/// buffers of that size, a longer one in buffers of `max_unique_items`, and
/// `[N]T` (`length` N) in buffers of N. A list longer than
/// `max_unique_items` fails: the declaration checks keep lists shorter, and
/// a list that got past them is rejected rather than accepted unchecked.
fn allUnique(comptime Item: type, comptime K: type, comptime key: fn (*const Item) K, items: []const Item, comptime length: ?usize) bool {
    if (K == bool) {
        var seen = [2]bool{ false, false };
        for (items) |*item| {
            const i = @intFromBool(key(item));
            if (seen[i]) return false;
            seen[i] = true;
        }
        return true;
    }
    if (comptime core.isExhaustiveEnum(K)) {
        var seen: std.bit_set.Static(@typeInfo(K).@"enum".field_names.len) = .empty;
        for (items) |*item| {
            const i = tagIndex(K, key(item));
            if (seen.isSet(i)) return false;
            seen.set(i);
        }
        return true;
    }
    if (items.len < 2) return true;
    if (items.len > core.max_unique_items) return false;
    if (length) |n| return sortedUnique(n, Item, K, key, items);
    if (items.len <= short_list) return sortedUnique(short_list, Item, K, key, items);
    return sortedUnique(core.max_unique_items, Item, K, key, items);
}

/// No two of `items`, 2 to `capacity` of them, have equal keys: their
/// indexes, sorted on the stack by key, have no two equal neighbours.
/// Strings are sorted by their 64-bit Wyhash, then by bytes, so only strings
/// with equal hashes are compared byte for byte; integers and non-exhaustive
/// enums by value. `noinline`, so that the walk does not keep the buffers'
/// frame while it visits the items of nested lists.
noinline fn sortedUnique(comptime capacity: usize, comptime Item: type, comptime K: type, comptime key: fn (*const Item) K, items: []const Item) bool {
    var index_buf: [capacity]u16 = undefined;
    const order = index_buf[0..items.len];
    for (order, 0..) |*slot, i| slot.* = @intCast(i);
    if (comptime core.isString(K)) {
        var hash_buf: [capacity]u64 = undefined;
        const hashes = hash_buf[0..items.len];
        for (items, hashes) |*item, *hash| hash.* = std.hash.Wyhash.hash(0, key(item));
        const ByHash = struct { items: []const Item, hashes: []const u64 };
        std.mem.sortUnstable(u16, order, ByHash{ .items = items, .hashes = hashes }, struct {
            fn lessThan(by: ByHash, a: u16, b: u16) bool {
                if (by.hashes[a] != by.hashes[b]) return by.hashes[a] < by.hashes[b];
                return std.mem.order(u8, key(&by.items[a]), key(&by.items[b])) == .lt;
            }
        }.lessThan);
        for (order[0 .. order.len - 1], order[1..]) |a, b| {
            if (hashes[a] == hashes[b] and std.mem.eql(u8, key(&items[a]), key(&items[b]))) return false;
        }
        return true;
    }
    std.mem.sortUnstable(u16, order, items, struct {
        fn lessThan(list: []const Item, a: u16, b: u16) bool {
            return ordinal(key(&list[a])) < ordinal(key(&list[b]));
        }
    }.lessThan);
    for (order[0 .. order.len - 1], order[1..]) |a, b| {
        if (ordinal(key(&items[a])) == ordinal(key(&items[b]))) return false;
    }
    return true;
}

/// An integer as it is, a non-exhaustive enum by its integer value.
fn ordinal(x: anytype) switch (@typeInfo(@TypeOf(x))) {
    .@"enum" => |e| e.tag_type,
    else => @TypeOf(x),
} {
    return switch (@typeInfo(@TypeOf(x))) {
        .@"enum" => @backingInt(x),
        else => x,
    };
}

/// The bit of an exhaustive enum's tag: its rank among the tags by value,
/// found at compile time for each tag (an `inline else` prong), so sparse
/// tag values need no larger bitset. The values are sorted once, and each
/// prong searches them, so an enum of thousands of tags stays within the
/// comptime branch quota.
fn tagIndex(comptime E: type, tag: E) usize {
    @setEvalBranchQuota(core.eval_quota);
    const values = comptime sortedTagValues(E);
    switch (tag) {
        inline else => |t| return comptime rankIn(values, @backingInt(t)),
    }
}

/// The number of `values`, sorted in increasing order, that are below `value`.
fn rankIn(comptime values: []const comptime_int, comptime value: comptime_int) usize {
    var lo: usize = 0;
    var hi: usize = values.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (values[mid] < value) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// The values of the tags of `E`, in increasing order.
fn sortedTagValues(comptime E: type) []const comptime_int {
    comptime {
        @setEvalBranchQuota(core.eval_quota);
        const e = @typeInfo(E).@"enum";
        var values = e.field_values[0..e.field_names.len].*;
        std.mem.sortUnstable(comptime_int, &values, {}, struct {
            fn lessThan(_: void, a: comptime_int, b: comptime_int) bool {
                return a < b;
            }
        }.lessThan);
        const final = values;
        return &final;
    }
}

// ------------------------------------------------------------------ containsAll, containsNone

/// Every listed value is among the items. The list is a tuple or an array
/// `[N]T` (not a pointer to one, not a slice) of at least one value, none
/// twice, all of one kind matching the items: non-empty strings, compared
/// byte for byte; enum tags of the item type; integers within it, compared
/// exactly; or bools. Items are scanned in index order and the rule passes
/// once every value was found, so one item never counts for two values; an
/// empty list fails. The message lists the values: "must contain all of: a,
/// b", "must contain a" for one value, and "must contain all of the required
/// values" when the list would make it longer than 512 bytes.
pub fn containsAll(comptime values: anytype) Rule {
    @setEvalBranchQuota(core.eval_quota);
    const list = core.analyzeList("containsAll", values, contains_all_list);
    const message = if (list.len == 1) "must contain " ++ list.text else "must contain all of: " ++ list.text;
    return itemMembership(.contains_all, values, list, message, "must contain all of the required values");
}

/// No item equals a listed value, with the lists and comparisons of
/// `containsAll`; an empty list passes. The list may not hold every value
/// of the item type (both bools, every tag of an exhaustive enum, every
/// value of an integer type): use `v.empty` on a slice. To reject empty
/// strings among the items, use `v.each(v.notEmpty)`.
pub fn containsNone(comptime values: anytype) Rule {
    @setEvalBranchQuota(core.eval_quota);
    const list = core.analyzeList("containsNone", values, contains_none_list);
    const message = if (list.len == 1) "must not contain " ++ list.text else "must not contain any of: " ++ list.text;
    return itemMembership(.contains_none, values, list, message, "must not contain any of the forbidden values");
}

/// The lists `containsAll` and `containsNone` take.
const contains_all_list: core.ListOptions = .{ .allow_bool = true, .empty_string = "the empty string cannot be listed" };
const contains_none_list: core.ListOptions = .{ .allow_bool = true, .empty_string = "the empty string cannot be listed; " ++ core.hints.reject_empty_items };

/// `containsAll` or `containsNone` over a checked list.
fn itemMembership(comptime kind: core.Kind, comptime values: anytype, comptime list: core.ValueList, comptime message: []const u8, comptime fallback: []const u8) Rule {
    const all = kind == .contains_all;
    return core.define(kind, .{
        .message = message,
        .fallback = fallback,
        .args = list.args,
        .params = &.{core.param("values", values)},
        .fits = struct {
            fn fits(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void {
                if (itemsProblem(rule, values, list, T, where)) |text| @compileError(text);
            }
        }.fits,
        .eval = struct {
            fn eval(value: anytype) Outcome {
                const T = @TypeOf(value.*);
                const Item = core.ListChild(T) orelse @compileError("validator: internal: " ++ @tagName(kind) ++ "'s eval was instantiated for a type its fits rejected");
                const items: []const Item = if (@typeInfo(T) == .array) value else value.*;
                const wanted = comptime core.listAs(if (core.isString(Item)) []const u8 else Item, values);
                if (!all) {
                    for (items) |item| {
                        for (wanted) |w| {
                            if (itemEql(Item, item, w)) return .fail;
                        }
                    }
                    return .pass;
                }
                var found: [wanted.len]bool = @splat(false);
                var missing: usize = wanted.len;
                for (items) |item| {
                    for (wanted, &found) |w, *seen| {
                        if (!seen.* and itemEql(Item, item, w)) {
                            seen.* = true;
                            missing -= 1;
                            if (missing == 0) return .pass;
                            // The values differ, so no other one equals this item.
                            break;
                        }
                    }
                }
                return .fail;
            }
        }.eval,
    });
}

/// An item equals a listed value: strings byte for byte, the rest by `==`.
fn itemEql(comptime Item: type, item: Item, listed: if (core.isString(Item)) []const u8 else Item) bool {
    return if (comptime core.isString(Item)) std.mem.eql(u8, item, listed) else item == listed;
}

/// The declaration error of `containsAll` or `containsNone` with the checked
/// list `values` on the unwrapped field type `T`, or null. The field is a
/// list whose items are not optional or floats and are of the listed kind:
/// strings, the enum of the listed tags, an integer type holding the listed
/// integers, or bools. On `[N]T`, an array without items decides the rule,
/// `containsAll` cannot list more values than the array has items, and
/// `containsNone` cannot list every value of the item type, which leaves a
/// slice only the empty list.
fn itemsProblem(comptime rule: *const Rule, comptime values: anytype, comptime list: core.ValueList, comptime T: type, comptime where: []const u8) ?[]const u8 {
    @setEvalBranchQuota(core.eval_quota);
    const all = rule.kind == .contains_all;
    const string_hint = if (all) core.hints.contains_all_on_string else core.hints.contains_none_on_string;
    const Item = core.ListChild(T) orelse return core.typeErrorText(rule, T, where, "a slice or an array", acceptsList, if (core.isString(T)) string_hint else null);
    switch (@typeInfo(Item)) {
        .optional => return core.ruleErrorText(rule, where, ": items are " ++ @typeName(Item) ++ "; optional items are not supported"),
        .float => return core.ruleErrorText(rule, where, ": items are " ++ @typeName(Item) ++ "; float items are not supported"),
        else => {},
    }
    const matches = switch (list.kind) {
        .string => core.isString(Item),
        .tag => @typeInfo(Item) == .@"enum",
        .int => @typeInfo(Item) == .int,
        .bool => Item == bool,
    };
    if (!matches) return core.ruleErrorText(rule, where, " lists " ++ list.kind.plural() ++ ", items are " ++ @typeName(Item));
    switch (list.kind) {
        .tag => inline for (0..values.len) |i| {
            if (core.itemTagProblem(values[i], Item)) |text| return core.ruleErrorText(rule, where, text);
        },
        .int => inline for (0..values.len) |i| {
            if (core.numberParamProblem(values[i], Item, "use an integer", if (all) "; the rule would never pass" else "; remove it")) |text|
                return core.ruleErrorText(rule, where, text);
        },
        .string, .bool => {},
    }
    const array_len: ?usize = switch (@typeInfo(T)) {
        .array => |a| a.len,
        else => null,
    };
    if (array_len) |n| {
        if (n == 0) return core.ruleErrorText(rule, where, " on " ++ @typeName(T) ++ if (all) " is always false: the array has no items" else " is always true: the array has no items; remove it");
        if (all and list.len > n)
            return core.ruleErrorText(rule, where, std.fmt.comptimePrint(" on {s}: an array of {d} items cannot contain {d} different values", .{ @typeName(T), n, list.len }));
    }
    if (!all and list.len == valueCount(Item)) {
        const tail = if (array_len == null) "; only an empty list would pass; " ++ core.hints.use_empty else "; no value would pass";
        return core.ruleErrorText(rule, where, " lists every value of " ++ @typeName(Item) ++ tail);
    }
    return null;
}

// ------------------------------------------------------------------ each

/// The transforms and the rules for every item of a slice or an array: one
/// of them or a tuple, transforms first (`v.each(.{ v.trim, v.notBlank })`;
/// `v.each(v.trim)` alone is valid too). It declares what applies to the
/// items rather than checking the list: it must be the last rule of its
/// tuple and appear once, and it has no code or message of its own. Items
/// have no name, so `v.rename` does not go inside it. Null items are
/// skipped; item paths are `tags[3]`.
pub fn each(comptime items: anytype) Rule {
    @setEvalBranchQuota(core.eval_quota);
    const parts = core.entryParts(items, "each(...)", true);
    if (parts.name == null and parts.transforms.len == 0 and parts.rules.len == 0) @compileError("validator: each(.{}): the list is empty");
    return .{
        .kind = .each,
        .code = "",
        .message = "",
        .args = "...",
        .inner = parts.rules,
        .item_transforms = parts.transforms,
        .item_problem = parts.problem,
        .fits = struct {
            fn fits(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void {
                // A name is about each itself; the order, about its items.
                if (rule.item_problem) |problem|
                    @compileError(core.entryProblemText(problem, if (problem == .name_in_each) where else where ++ "[]"));
                const Item = core.ListChild(T) orelse core.typeError(rule, T, where, "a slice or an array", acceptsList, null);
                core.checkTransforms(rule.item_transforms, core.Unwrap(Item), where ++ "[]");
                core.checkRuleList(rule.inner, core.Unwrap(Item), where ++ "[]");
            }
        }.fits,
        .eval = struct {
            fn eval(value: anytype) Outcome {
                _ = value;
                @compileError("validator: internal: each is applied by the walker and never evaluated");
            }
        }.eval,
    };
}

// ------------------------------------------------------------------ schema

/// The JSON Schema keywords of a rule of this file on the unwrapped field
/// type `T`, for `v.schemaOf`. Items compare by value, as JSON Schema
/// compares them; a key of `uniqueBy` has no keyword.
pub fn schemaOf(comptime rule: Rule, comptime T: type) schema.RuleSchema {
    return switch (rule.kind) {
        .min_items => schema.exact(&.{schema.count("minItems", rule.params[0].value.int)}),
        .max_items => schema.exact(&.{schema.count("maxItems", rule.params[0].value.int)}),
        .unique_items => schema.exact(&.{schema.keyword("uniqueItems", "true")}),
        .unique_by => blk: {
            const Item = core.Unwrap(core.ListChild(T).?);
            const key = rule.params[0].value.tag;
            break :blk schema.none("no two items with the same " ++ naming.namesOf(Item)[std.meta.fieldIndex(Item, key).?]);
        },
        .contains_all => blk: {
            var each_value: []const []const u8 = &.{};
            for (rule.params[0].value.list) |x| {
                each_value = each_value ++ &[_][]const u8{schema.object(&.{schema.keyword("contains", schema.object(&.{schema.keyword("const", schema.value(x))}))})};
            }
            break :blk schema.exact(&.{schema.keyword("allOf", schema.array(each_value))});
        },
        // Not `not: {contains: ...}`, which a null list would fail.
        .contains_none => schema.exact(&.{schema.keyword("items", schema.object(&.{schema.keyword("not", schema.object(&.{schema.keyword("enum", schema.value(rule.params[0].value))}))}))}),
        .each => eachSchema(rule, core.ListChild(T).?),
        else => unreachable,
    };
}

/// `each`: no keywords of its own, the schemas of its item transforms and
/// item rules on the item type `Item` (an optional item, `?U`, as declared),
/// and the accuracy of the least accurate of them.
fn eachSchema(comptime rule: Rule, comptime Item: type) schema.RuleSchema {
    var items: []const schema.RuleSchema = &.{};
    for (rule.item_transforms) |t| items = items ++ &[_]schema.RuleSchema{schema.schemaOf(t, Item)};
    for (rule.inner) |inner| items = items ++ &[_]schema.RuleSchema{schema.schemaOf(inner, Item)};
    var accuracy: schema.RuleSchema.Accuracy = .exact;
    for (items) |item| {
        if (@backingInt(item.accuracy) > @backingInt(accuracy)) accuracy = item.accuracy;
    }
    return .{ .accuracy = accuracy, .items = items };
}

/// The arguments the hints show for an uncalled constructor of this file:
/// `each must be called, e.g. v.each(v.notEmpty)`.
pub const call_examples = .{ .minItems = "1", .maxItems = "100", .uniqueBy = ".id", .containsAll = ".{\"a\"}", .containsNone = ".{\"a\"}", .each = "v.notEmpty" };

const expectOutcome = core.expectOutcome;

/// A struct for the tests below.
const Record = struct { id: u32 };

const test_where = "Dto.field_rules.x";

/// The declaration error of `minItems(n)` or `maxItems(n)` on a field of
/// type `T`, or null.
fn minItemsText(comptime n: usize, comptime T: type) ?[]const u8 {
    return countProblem(&minItems(n), n, T, test_where);
}

fn maxItemsText(comptime n: usize, comptime T: type) ?[]const u8 {
    return countProblem(&maxItems(n), n, T, test_where);
}

/// The error a rule constructor used without a call raises in `field_rules`.
fn uncalledText(comptime name: []const u8, comptime F: type) []const u8 {
    return "validator: " ++ test_where ++ ": " ++ core.hints.mustBeCalled(name, F);
}

test "minItems and maxItems have their documented codes, messages and count parameters and no precondition" {
    const t = std.testing;
    const at_least = minItems(2);
    try t.expectEqual(core.Kind.min_items, at_least.kind);
    try t.expectEqualStrings("validation.min_items", at_least.code);
    try t.expectEqualStrings("must have at least 2 items", at_least.message);
    try t.expectEqualStrings("2", at_least.args.?);
    try t.expectEqual(1, at_least.params.len);
    try t.expectEqualStrings("min", at_least.params[0].name);
    try t.expectEqualStrings("2", at_least.params[0].text);
    try t.expect(at_least.params[0].placeholder);
    try t.expect(comptime at_least.params[0].value.int == 2);
    try t.expectEqual(null, at_least.precondition);
    try t.expectEqualStrings("minItems(2)", comptime at_least.call());
    try t.expectEqualStrings("min_items(2)", comptime at_least.label());

    const at_most = maxItems(100);
    try t.expectEqual(core.Kind.max_items, at_most.kind);
    try t.expectEqualStrings("validation.max_items", at_most.code);
    try t.expectEqualStrings("must have at most 100 items", at_most.message);
    try t.expectEqualStrings("100", at_most.args.?);
    try t.expectEqual(1, at_most.params.len);
    try t.expectEqualStrings("max", at_most.params[0].name);
    try t.expectEqualStrings("100", at_most.params[0].text);
    try t.expect(at_most.params[0].placeholder);
    try t.expectEqual(null, at_most.precondition);
    try t.expectEqualStrings("max_items(100)", comptime at_most.label());

    // One item is singular; counts are decimal at every size.
    try t.expectEqualStrings("must have at least 1 item", minItems(1).message);
    try t.expectEqualStrings("must have at most 1 item", maxItems(1).message);
    // The largest count of the target: 18446744073709551615 on 64-bit ones.
    try t.expectEqualStrings(std.fmt.comptimePrint("must have at most {d} items", .{std.math.maxInt(usize)}), maxItems(std.math.maxInt(usize)).message);
}

test "minItems and maxItems take a count of at least 1" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: minItems(0): min must be at least 1 (minItems(0) is always true; remove it)", comptime countCallProblem(.min_items, 0).?);
    try expect("validator: maxItems(0): max must be at least 1; use v.empty", comptime countCallProblem(.max_items, 0).?);
    try std.testing.expectEqual(null, comptime countCallProblem(.min_items, 1));
    try std.testing.expectEqual(null, comptime countCallProblem(.max_items, 1));
    try std.testing.expectEqual(null, comptime countCallProblem(.min_items, std.math.maxInt(usize)));
}

test "minItems and maxItems on a fixed-size array are errors: its length never changes" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: ";
    const fixed = ": the length of an array is fixed";
    try expect(head ++ "min_items(1) on [3]u32 is always true" ++ fixed, comptime minItemsText(1, [3]u32).?);
    try expect(head ++ "min_items(3) on [3]u32 is always true" ++ fixed, comptime minItemsText(3, [3]u32).?);
    try expect(head ++ "min_items(4) on [3]u32 is always false" ++ fixed, comptime minItemsText(4, [3]u32).?);
    try expect(head ++ "min_items(1) on [0]u32 is always false" ++ fixed, comptime minItemsText(1, [0]u32).?);
    try expect(head ++ "max_items(2) on [3]u32 is always false" ++ fixed, comptime maxItemsText(2, [3]u32).?);
    try expect(head ++ "max_items(3) on [3]u32 is always true" ++ fixed, comptime maxItemsText(3, [3]u32).?);
    try expect(head ++ "max_items(1) on [0]u32 is always true" ++ fixed, comptime maxItemsText(1, [0]u32).?);
    try expect(head ++ "min_items(2) on [3:0]u32 is always true" ++ fixed, comptime minItemsText(2, [3:0]u32).?);
    try expect(head ++ "max_items(1) on [2][]const u8 is always false" ++ fixed, comptime maxItemsText(1, [2][]const u8).?);
    // [N]u8 is an array too; these rules take no strings, so no string hint follows.
    try expect(head ++ "min_items(1) on [4]u8 is always true" ++ fixed, comptime minItemsText(1, [4]u8).?);
}

test "minItems and maxItems take slices; a string field gets the string rules as the hint" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: ";
    const min_strings = "; for strings use v.minLength or v.minBytes";
    const max_strings = "; for strings use v.maxLength or v.maxBytes";
    try expect(head ++ "min_items expects a slice, field is []const u8" ++ min_strings, comptime minItemsText(1, []const u8).?);
    try expect(head ++ "min_items expects a slice, field is [:0]u8" ++ min_strings, comptime minItemsText(1, [:0]u8).?);
    try expect(head ++ "max_items expects a slice, field is []const u8" ++ max_strings, comptime maxItemsText(3, []const u8).?);
    try expect(head ++ "max_items expects a slice, field is []u8" ++ max_strings, comptime maxItemsText(3, []u8).?);
    try expect(head ++ "min_items expects a slice, field is u32", comptime minItemsText(1, u32).?);
    try expect(head ++ "max_items expects a slice, field is u32", comptime maxItemsText(3, u32).?);
    try expect(head ++ "min_items expects a slice, field is lists.Record", comptime minItemsText(1, Record).?);
    try expect(head ++ "max_items expects a slice, field is *const [3]u32", comptime maxItemsText(3, *const [3]u32).?);
    try expect(
        head ++ "min_items expects a slice, field is []volatile u32; volatile, allowzero and under-aligned slices are neither strings nor lists",
        comptime minItemsText(1, []volatile u32).?,
    );
    inline for (.{ []const u32, []u32, [:0]const u32, []const ?u32, []const []const u8, [][]u32, []const Record, []const f64 }) |T| {
        try std.testing.expectEqual(null, comptime minItemsText(1, T));
        try std.testing.expectEqual(null, comptime maxItemsText(1, T));
    }
}

test "an uncalled minItems or maxItems gets an example call" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: Dto.field_rules.x: minItems must be called, e.g. v.minItems(1)", comptime uncalledText("minItems", @TypeOf(minItems)));
    try expect("validator: Dto.field_rules.x: maxItems must be called, e.g. v.maxItems(100)", comptime uncalledText("maxItems", @TypeOf(maxItems)));
}

test "minItems and maxItems count the items of a slice, null items included" {
    try expectOutcome(.fail, minItems(2), @as([]const u32, &.{1}));
    try expectOutcome(.pass, minItems(2), @as([]const u32, &.{ 1, 2 }));
    try expectOutcome(.pass, minItems(2), @as([]const u32, &.{ 1, 2, 3 }));
    try expectOutcome(.fail, minItems(1), @as([]const []const u8, &.{}));
    try expectOutcome(.pass, minItems(1), @as([]const ?u32, &.{null}));
    try expectOutcome(.pass, maxItems(2), @as([]const u32, &.{ 1, 2 }));
    try expectOutcome(.fail, maxItems(2), @as([]const ?u32, &.{ null, null, null }));
    try expectOutcome(.pass, maxItems(1), @as([]const u32, &.{}));
    try expectOutcome(.pass, maxItems(std.math.maxInt(usize)), @as([]const u32, &.{ 1, 2 }));
}

/// Types for the uniqueness tests: enums of every kind and a struct item
/// with keys of every kind.
const Role = enum { admin, user, guest };
const Sparse = enum(u32) { high = 1_000_000, low = 1, mid = 500 };
const Open = enum(u8) { a, b, _ };
const OpenWide = enum(u16) { a, _ };
const Line = struct {
    sku: []const u8,
    qty: u32 = 1,
    active: bool = true,
    role: Role = .user,
    comptime kind: u8 = 1,
    price: f64 = 0,
    ref: ?u32 = null,
    tags: []const []const u8 = &.{},
};

/// The declaration error of `uniqueItems` on a field of type `T`, or null.
fn uniqueItemsText(comptime T: type) ?[]const u8 {
    return uniqueItemsProblem(&uniqueItems, T, test_where);
}

/// The declaration error of `uniqueBy(key)` on a field of type `T`, or null.
fn uniqueByText(comptime key: @EnumLiteral(), comptime T: type) ?[]const u8 {
    return uniqueByProblem(&uniqueBy(key), @tagName(key), T, test_where);
}

/// The cap error of the last rule of `rules`, a uniqueness rule, on a field
/// of type `T`, or null.
fn capText(comptime rules: []const Rule, comptime T: type) ?[]const u8 {
    const rule = &rules[rules.len - 1];
    const Item = core.ListChild(T).?;
    const K = if (rule.kind == .unique_by) @FieldType(Item, rule.params[0].value.tag) else Item;
    return capProblem(rule, rules[0 .. rules.len - 1], K, T, test_where);
}

test "uniqueItems and uniqueBy share the code validation.unique_items; uniqueBy names its key in the message and in {key}" {
    const t = std.testing;
    try t.expectEqual(core.Kind.unique_items, uniqueItems.kind);
    try t.expectEqualStrings("validation.unique_items", uniqueItems.code);
    try t.expectEqualStrings("must not contain duplicates", uniqueItems.message);
    try t.expectEqual(null, uniqueItems.args);
    try t.expectEqual(0, uniqueItems.params.len);
    try t.expectEqual(null, uniqueItems.precondition);
    const by_email = uniqueBy(.email);
    try t.expectEqual(core.Kind.unique_by, by_email.kind);
    try t.expectEqualStrings("validation.unique_items", by_email.code);
    try t.expectEqualStrings("must not contain duplicate email values", by_email.message);
    try t.expectEqualStrings(".email", by_email.args.?);
    try t.expectEqualStrings("unique_by(.email)", comptime by_email.label());
    try t.expectEqual(1, by_email.params.len);
    try t.expectEqualStrings("key", by_email.params[0].name);
    try t.expectEqualStrings("email", by_email.params[0].text);
    try t.expect(by_email.params[0].placeholder);
    try t.expectEqual(null, by_email.precondition);
    // A key that is no plain identifier: escaped in the message, quoted in the call.
    try t.expectEqualStrings("must not contain duplicate a\\nb values", uniqueBy(.@"a\nb").message);
    try t.expectEqualStrings("unique_by(.@\"error\")", comptime uniqueBy(.@"error").label());
}

test "uniqueBy takes a field name written as an enum literal" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: uniqueBy(\"id\"): the key must be a field name such as .id, got *const [2:0]u8", comptime keyCallProblem("id").?);
    try expect("validator: uniqueBy(1): the key must be a field name such as .id, got comptime_int", comptime keyCallProblem(1).?);
    try expect("validator: uniqueBy(.user): the key must be a field name such as .id, got lists.Role", comptime keyCallProblem(Role.user).?);
    try std.testing.expectEqual(null, comptime keyCallProblem(.id));
}

test "uniqueItems takes lists of bools, enums, integers and strings" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: unique_items";
    try expect(head ++ " expects a slice or an array, field is []const u8 (a string)", comptime uniqueItemsText([]const u8).?);
    try expect(head ++ " expects a slice or an array, field is u32", comptime uniqueItemsText(u32).?);
    try expect(head ++ ": items are f64; float items are not supported (NaN != NaN, -0.0 == 0.0)", comptime uniqueItemsText([]const f64).?);
    try expect(head ++ ": items are lists.Record; struct items are not supported; use v.uniqueBy(.field)", comptime uniqueItemsText([]const Record).?);
    try expect(head ++ ": items are ?u32; optional items are not supported", comptime uniqueItemsText([]const ?u32).?);
    try expect(head ++ ": items are []const u32; only bool, enum, integer and string items are supported", comptime uniqueItemsText([]const []const u32).?);
    try expect(head ++ ": items are struct { u32, u32 }; only bool, enum, integer and string items are supported", comptime uniqueItemsText([]const struct { u32, u32 }).?);
    try expect(head ++ ": items are [2]u8; only bool, enum, integer and string items are supported", comptime uniqueItemsText([3][2]u8).?);
    inline for (.{ []const u32, []i8, [:0]const u64, []const bool, []const Role, []const Sparse, []const Open, []const []const u8, [][:0]u8, []const u128, [4]u8, [2]bool, [3]Role }) |T| {
        try std.testing.expectEqual(null, comptime uniqueItemsText(T));
    }
}

test "uniqueItems on [N]T needs 2 to 1000 items, and no more than the item type has values" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: unique_items on ";
    try expect(head ++ "[1]u32 is always true; remove it", comptime uniqueItemsText([1]u32).?);
    try expect(head ++ "[0][]const u8 is always true; remove it", comptime uniqueItemsText([0][]const u8).?);
    try expect(head ++ "[3]bool is always false: 3 items cannot all differ", comptime uniqueItemsText([3]bool).?);
    try expect(head ++ "[4]lists.Role is always false: 4 items cannot all differ", comptime uniqueItemsText([4]Role).?);
    try expect(head ++ "[3]u1 is always false: 3 items cannot all differ", comptime uniqueItemsText([3]u1).?);
    try expect(head ++ "[1001]u32: 1001 items is more than max_unique_items (1000)", comptime uniqueItemsText([1001]u32).?);
    try expect(head ++ "[1001][]const u8: 1001 items is more than max_unique_items (1000)", comptime uniqueItemsText([1001][]const u8).?);
    try expect(head ++ "[1001]lists.OpenWide: 1001 items is more than max_unique_items (1000)", comptime uniqueItemsText([1001]OpenWide).?);
    // A non-exhaustive enum holds every value of its integer type: 256 for u8.
    try expect(head ++ "[257]lists.Open is always false: 257 items cannot all differ", comptime uniqueItemsText([257]Open).?);
    // Bitset items need no cap.
    try std.testing.expectEqual(null, comptime uniqueItemsText([1000]u32));
    try std.testing.expectEqual(null, comptime uniqueItemsText([2]u1));
    try std.testing.expectEqual(null, comptime uniqueItemsText([3]Sparse));
}

test "uniqueBy takes lists of structs whose key is a bool, enum, integer or string field" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: unique_by";
    try expect(head ++ " expects a slice or an array of structs, field is lists.Line", comptime uniqueByText(.sku, Line).?);
    try expect(head ++ " expects a slice or an array of structs, field is []const u8 (a string)", comptime uniqueByText(.sku, []const u8).?);
    try expect(head ++ "(.id): items are u32, not structs; use v.uniqueItems", comptime uniqueByText(.id, []const u32).?);
    try expect(head ++ "(.id): items are struct { u32, u32 }, not structs; use v.uniqueItems", comptime uniqueByText(.id, []const struct { u32, u32 }).?);
    try expect(head ++ "(.id): items are ?lists.Record; optional items are not supported", comptime uniqueByText(.id, []const ?Record).?);
    try expect(head ++ "(.skus): lists.Line has no field skus; did you mean \"sku\"?", comptime uniqueByText(.skus, []const Line).?);
    try expect(head ++ "(.zzz): lists.Line has no field zzz", comptime uniqueByText(.zzz, []const Line).?);
    try expect(head ++ "(.kind): kind is a comptime field", comptime uniqueByText(.kind, []const Line).?);
    try expect(head ++ "(.price): the key price is f64; float keys are not supported (NaN != NaN, -0.0 == 0.0)", comptime uniqueByText(.price, []const Line).?);
    try expect(head ++ "(.ref): the key ref is ?u32; optional keys are not supported", comptime uniqueByText(.ref, []const Line).?);
    try expect(head ++ "(.tags): the key tags is []const []const u8; only bool, enum, integer and string keys are supported", comptime uniqueByText(.tags, []const Line).?);
    try expect(head ++ "(.sku) on [1]lists.Line is always true; remove it", comptime uniqueByText(.sku, [1]Line).?);
    try expect(head ++ "(.active) on [3]lists.Line is always false: 3 items cannot all differ", comptime uniqueByText(.active, [3]Line).?);
    try expect(head ++ "(.qty) on [1001]lists.Line: 1001 items is more than max_unique_items (1000)", comptime uniqueByText(.qty, [1001]Line).?);
    inline for (.{ []const Line, [2]Line, []Line }) |T| {
        try std.testing.expectEqual(null, comptime uniqueByText(.sku, T));
        try std.testing.expectEqual(null, comptime uniqueByText(.qty, T));
        try std.testing.expectEqual(null, comptime uniqueByText(.active, T));
        try std.testing.expectEqual(null, comptime uniqueByText(.role, T));
    }
}

test "on a slice, integer, string and non-exhaustive enum items need an earlier maxItems(n) with n <= 1000" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: ";
    const needs = " needs an earlier v.maxItems(n) with n <= 1000 (max_unique_items) in the same tuple";
    try expect(head ++ "unique_items" ++ needs, comptime capText(&.{uniqueItems}, []const u32).?);
    try expect(head ++ "unique_items" ++ needs, comptime capText(&.{uniqueItems}, []const []const u8).?);
    try expect(head ++ "unique_items" ++ needs, comptime capText(&.{uniqueItems}, []const Open).?);
    try expect(head ++ "unique_items" ++ needs, comptime capText(&.{ minItems(1), uniqueItems }, []const u32).?);
    try expect(head ++ "unique_by(.sku)" ++ needs, comptime capText(&.{uniqueBy(.sku)}, []const Line).?);
    try expect(head ++ "unique_items after max_items(1001): 1001 is more than max_unique_items (1000)", comptime capText(&.{ maxItems(1001), uniqueItems }, []const u32).?);
    try expect(head ++ "unique_by(.qty) after max_items(5000): 5000 is more than max_unique_items (1000)", comptime capText(&.{ maxItems(5000), maxItems(9000), uniqueBy(.qty) }, []const Line).?);
    // The smallest earlier maxItems counts.
    try std.testing.expectEqual(null, comptime capText(&.{ maxItems(1000), uniqueItems }, []const u32));
    try std.testing.expectEqual(null, comptime capText(&.{ maxItems(5000), maxItems(10), uniqueItems }, []const u32));
    try std.testing.expectEqual(null, comptime capText(&.{ maxItems(50), uniqueBy(.sku) }, []const Line));
    // Bools and exhaustive enums, and arrays, need no maxItems.
    try std.testing.expectEqual(null, comptime capText(&.{uniqueItems}, []const bool));
    try std.testing.expectEqual(null, comptime capText(&.{uniqueItems}, []const Role));
    try std.testing.expectEqual(null, comptime capText(&.{uniqueBy(.role)}, []const Line));
    try std.testing.expectEqual(null, comptime capText(&.{uniqueBy(.active)}, []const Line));
    try std.testing.expectEqual(null, comptime capText(&.{uniqueItems}, [1000]u32));
}

test "an uncalled uniqueBy gets an example call" {
    try std.testing.expectEqualStrings("validator: Dto.field_rules.x: uniqueBy must be called, e.g. v.uniqueBy(.id)", comptime uncalledText("uniqueBy", @TypeOf(uniqueBy)));
}

test "uniqueItems compares integers exactly at every width, by value" {
    try expectOutcome(.pass, uniqueItems, @as([]const u32, &.{}));
    try expectOutcome(.pass, uniqueItems, @as([]const u32, &.{7}));
    try expectOutcome(.pass, uniqueItems, @as([]const u32, &.{ 1, 2, 3 }));
    try expectOutcome(.fail, uniqueItems, @as([]const u32, &.{ 1, 2, 1 }));
    try expectOutcome(.fail, uniqueItems, @as([]const i8, &.{ -128, 127, -128 }));
    try expectOutcome(.pass, uniqueItems, @as([]const u64, &.{ 9007199254740992, 9007199254740993 }));
    try expectOutcome(.fail, uniqueItems, @as([]const u128, &.{ std.math.maxInt(u128), 0, std.math.maxInt(u128) }));
    try expectOutcome(.pass, uniqueItems, @as([:0]const u32, &.{ 1, 2 }));
    try expectOutcome(.pass, uniqueItems, [4]u8{ 1, 2, 3, 4 });
    try expectOutcome(.fail, uniqueItems, [4]u8{ 1, 2, 3, 1 });
}

test "uniqueItems compares strings byte for byte, case and normalization included" {
    try expectOutcome(.pass, uniqueItems, @as([]const []const u8, &.{ "a", "A", "", "a " }));
    try expectOutcome(.fail, uniqueItems, @as([]const []const u8, &.{ "a", "b", "a" }));
    try expectOutcome(.fail, uniqueItems, @as([]const []const u8, &.{ "", "" }));
    // "é" composed and decomposed are different bytes.
    try expectOutcome(.pass, uniqueItems, @as([]const []const u8, &.{ "\u{e9}", "e\u{301}" }));
    try expectOutcome(.fail, uniqueItems, @as([]const [:0]const u8, &.{ "x", "y", "x" }));
    try expectOutcome(.pass, uniqueItems, [2][]const u8{ "x", "y" });
}

test "uniqueItems compares bools and enums by tag, sparse and non-exhaustive ones too" {
    try expectOutcome(.pass, uniqueItems, @as([]const bool, &.{ true, false }));
    try expectOutcome(.fail, uniqueItems, @as([]const bool, &.{ false, true, false }));
    try expectOutcome(.fail, uniqueItems, @as([]const bool, &.{ true, true }));
    try expectOutcome(.pass, uniqueItems, @as([]const Role, &.{ .guest, .admin, .user }));
    try expectOutcome(.fail, uniqueItems, @as([]const Role, &.{ .guest, .admin, .guest }));
    try expectOutcome(.pass, uniqueItems, @as([]const Sparse, &.{ .high, .low, .mid }));
    try expectOutcome(.fail, uniqueItems, @as([]const Sparse, &.{ .mid, .high, .mid }));
    try expectOutcome(.pass, uniqueItems, @as([]const Open, &.{ .a, .b, @fromBackingInt(7) }));
    try expectOutcome(.fail, uniqueItems, @as([]const Open, &.{ @fromBackingInt(7), .a, @fromBackingInt(7) }));
    try expectOutcome(.pass, uniqueItems, [3]Role{ .user, .guest, .admin });
    try expectOutcome(.fail, uniqueItems, [2]bool{ true, true });
}

test "uniqueBy compares only the key of each item" {
    const lines: []const Line = &.{ .{ .sku = "A", .qty = 1 }, .{ .sku = "B", .qty = 1 } };
    try expectOutcome(.pass, uniqueBy(.sku), lines);
    try expectOutcome(.fail, uniqueBy(.qty), lines);
    try expectOutcome(.fail, uniqueBy(.active), lines);
    try expectOutcome(.fail, uniqueBy(.role), lines);
    try expectOutcome(.fail, uniqueBy(.sku), @as([]const Line, &.{ .{ .sku = "A" }, .{ .sku = "B" }, .{ .sku = "A", .qty = 2 } }));
    try expectOutcome(.pass, uniqueBy(.role), [3]Line{ .{ .sku = "", .role = .admin }, .{ .sku = "", .role = .user }, .{ .sku = "", .role = .guest } });
    try expectOutcome(.pass, uniqueBy(.active), [2]Line{ .{ .sku = "", .active = true }, .{ .sku = "", .active = false } });
    try expectOutcome(.pass, uniqueBy(.id), @as([]const Record, &.{}));
    try expectOutcome(.pass, uniqueBy(.id), @as([]const Record, &.{.{ .id = 1 }}));
}

/// `n` different integers, the last one repeated when `duplicate`.
fn distinctInts(comptime n: usize, comptime duplicate: bool) [n]u64 {
    var out: [n]u64 = undefined;
    for (&out, 0..) |*slot, i| slot.* = (n - i) * 7919;
    if (duplicate) out[n - 1] = out[0];
    return out;
}

/// `n` different strings of `len` bytes that differ only in their last
/// bytes, the last one repeated when `duplicate`.
fn distinctStrings(comptime n: usize, comptime len: usize, comptime duplicate: bool) [n][]const u8 {
    comptime {
        @setEvalBranchQuota(core.eval_quota);
        var out: [n][]const u8 = undefined;
        for (&out, 0..) |*slot, i| slot.* = &(@as([len - 4]u8, @splat('s')) ++ std.fmt.comptimePrint("{d:0>4}", .{i}).*);
        if (duplicate) out[n - 1] = out[(n - 1) / 2];
        const final = out;
        return final;
    }
}

test "uniqueItems finds a duplicate in lists of 2, 64, 65 and 1000 items, slices and arrays" {
    // Short lists (up to 64 items), longer ones and an array of 1000 items.
    inline for (.{ 2, 64, 65, 1000 }) |n| {
        const ints = comptime distinctInts(n, false);
        const ints_dup = comptime distinctInts(n, true);
        try expectOutcome(.pass, uniqueItems, @as([]const u64, &ints));
        try expectOutcome(.fail, uniqueItems, @as([]const u64, &ints_dup));
        try expectOutcome(.pass, uniqueItems, ints);
        try expectOutcome(.fail, uniqueItems, ints_dup);
        const strings = comptime distinctStrings(n, 40, false);
        const strings_dup = comptime distinctStrings(n, 40, true);
        try expectOutcome(.pass, uniqueItems, @as([]const []const u8, &strings));
        try expectOutcome(.fail, uniqueItems, @as([]const []const u8, &strings_dup));
        try expectOutcome(.fail, uniqueItems, strings_dup);
    }
}

/// The declaration error of `containsAll(values)` or `containsNone(values)`
/// on a field of type `T`, or null.
fn containsAllText(comptime values: anytype, comptime T: type) ?[]const u8 {
    return itemsProblem(&containsAll(values), values, core.analyzeList("containsAll", values, contains_all_list), T, test_where);
}

fn containsNoneText(comptime values: anytype, comptime T: type) ?[]const u8 {
    return itemsProblem(&containsNone(values), values, core.analyzeList("containsNone", values, contains_none_list), T, test_where);
}

/// Another enum with a tag of the same name, for the tag tests.
const Color = enum { red, admin };

test "containsAll and containsNone have their documented codes, messages and {values} placeholder" {
    const t = std.testing;
    const both = containsAll(.{ "read", "write" });
    try t.expectEqual(core.Kind.contains_all, both.kind);
    try t.expectEqualStrings("validation.contains_all", both.code);
    try t.expectEqualStrings("must contain all of: read, write", both.message);
    try t.expectEqualStrings(".{ \"read\", \"write\" }", both.args.?);
    try t.expectEqualStrings("values", both.params[0].name);
    try t.expectEqualStrings("read, write", both.params[0].text);
    try t.expectEqual(null, both.precondition);
    try t.expectEqualStrings("must contain read", containsAll(.{"read"}).message);
    try t.expectEqualStrings("must contain all of: 1, 2", containsAll(.{ 1, 2 }).message);
    const none = containsNone(.{ .guest, .root });
    try t.expectEqual(core.Kind.contains_none, none.kind);
    try t.expectEqualStrings("validation.contains_none", none.code);
    try t.expectEqualStrings("must not contain any of: guest, root", none.message);
    try t.expectEqualStrings("must not contain root", containsNone(.{"root"}).message);
    try t.expectEqualStrings("must not contain true", containsNone(.{true}).message);
    try t.expectEqualStrings("contains_none(.{.guest})", comptime containsNone(.{.guest}).label());
    // A message that would be longer than 512 bytes falls back; the placeholder keeps every value.
    const long = .{ &@as([300]u8, @splat('a')), &@as([300]u8, @splat('b')) };
    try t.expectEqualStrings("must contain all of the required values", containsAll(long).message);
    try t.expectEqualStrings("must not contain any of the forbidden values", containsNone(long).message);
    try t.expectEqual(602, containsAll(long).params[0].text.len);
}

test "containsAll and containsNone take a tuple or an array of distinct strings, tags, integers or bools" {
    const expect = std.testing.expectEqualStrings;
    const list_args = contains_all_list;
    try expect("validator: containsAll(.{}): the list is empty", comptime core.listProblem("containsAll", .{}, list_args).?);
    try expect("validator: containsAll(\"a\"): expected a tuple or an array of values, e.g. .{ \"a\", \"b\" }, got *const [1:0]u8", comptime core.listProblem("containsAll", "a", list_args).?);
    const required = [_][]const u8{ "a", "b" };
    try expect(
        "validator: containsAll(...): expected a tuple or an array of values, e.g. .{ \"a\", \"b\" }, got *const [2][]const u8; pass the array itself, not a pointer to it",
        comptime core.listProblem("containsAll", &required, list_args).?,
    );
    try expect(
        "validator: containsNone(...): expected a tuple or an array of values, e.g. .{ \"a\", \"b\" }, got a pointer to a tuple; drop the &: write .{ ... }, not &.{ ... }",
        comptime core.listProblem("containsNone", &.{ "a", "b" }, contains_none_list).?,
    );
    try expect("validator: containsAll(.{ 1, 2, 1 }): 1 is listed twice", comptime core.listProblem("containsAll", .{ 1, 2, 1 }, list_args).?);
    try expect("validator: containsAll(.{ 1, \"a\" }): the list mixes integers and strings", comptime core.listProblem("containsAll", .{ 1, "a" }, list_args).?);
    try expect("validator: containsAll(.{1.5}): floats cannot be listed: exact float equality is fragile", comptime core.listProblem("containsAll", .{1.5}, list_args).?);
    try expect("validator: containsAll(.{\"\"}): the empty string cannot be listed", comptime core.listProblem("containsAll", .{""}, contains_all_list).?);
    try expect("validator: containsNone(.{\"\"}): the empty string cannot be listed; use v.each(v.notEmpty) to reject empty items", comptime core.listProblem("containsNone", .{""}, contains_none_list).?);
    try expect("validator: containsAll(.{\"\\xff\"}): \"\\xff\" is not valid UTF-8", comptime core.listProblem("containsAll", .{"\xff"}, contains_all_list).?);
    try expect("validator: containsNone(.{...}): cannot list a value of type @TypeOf(null)", comptime core.listProblem("containsNone", .{null}, contains_none_list).?);
    try expect("validator: containsAll(.{@fromBackingInt(7)}): @fromBackingInt(7) is not a named tag of lists.Open", comptime core.listProblem("containsAll", .{@as(Open, @fromBackingInt(7))}, contains_all_list).?);
    // Bools may be listed.
    try std.testing.expectEqual(null, comptime core.listProblem("containsAll", .{ true, false }, contains_all_list));
    try std.testing.expectEqual(null, comptime core.listProblem("containsNone", [_]u8{ 1, 2 }, contains_none_list));
}

test "containsAll and containsNone take lists of the listed kind of value, not strings" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: ";
    try expect(head ++ "contains_all expects a slice or an array, field is []const u8; for a substring use v.contains", comptime containsAllText(.{"a"}, []const u8).?);
    try expect(head ++ "contains_none expects a slice or an array, field is [:0]const u8; for a substring use v.notContains", comptime containsNoneText(.{"a"}, [:0]const u8).?);
    try expect(head ++ "contains_all expects a slice or an array, field is u32", comptime containsAllText(.{1}, u32).?);
    try expect(head ++ "contains_all(.{1}): items are ?u32; optional items are not supported", comptime containsAllText(.{1}, []const ?u32).?);
    try expect(head ++ "contains_none(.{1}): items are f64; float items are not supported", comptime containsNoneText(.{1}, []const f64).?);
    try expect(head ++ "contains_all(.{\"1\"}) lists strings, items are u32", comptime containsAllText(.{"1"}, []const u32).?);
    try expect(head ++ "contains_none(.{1}) lists integers, items are lists.Record", comptime containsNoneText(.{1}, []const Record).?);
    try expect(head ++ "contains_all(.{true}) lists bools, items are u8", comptime containsAllText(.{true}, [2]u8).?);
    try expect(head ++ "contains_all(.{.admin}) lists enum tags, items are []const u8", comptime containsAllText(.{.admin}, []const []const u8).?);
    try expect(head ++ "contains_all(.{300}): 300 is outside i8 (-128..127); the rule would never pass", comptime containsAllText(.{300}, []const i8).?);
    try expect(head ++ "contains_none(.{300}): 300 is outside i8 (-128..127); remove it", comptime containsNoneText(.{300}, []const i8).?);
    try expect(head ++ "contains_all(.{.root}): lists.Role has no tag root; tags: admin, user, guest", comptime containsAllText(.{.root}, []const Role).?);
    try expect(head ++ "contains_none(.{.red}): .red is a tag of lists.Color, the items are lists.Role", comptime containsNoneText(.{Color.red}, []const Role).?);
    try expect(head ++ "contains_all(.{.admin}): .admin is a tag of lists.Color, the items are lists.Role", comptime containsAllText(.{Color.admin}, []const Role).?);
    inline for (.{ []const []const u8, [][:0]u8, [3][]const u8 }) |T| try std.testing.expectEqual(null, comptime containsAllText(.{ "a", "b" }, T));
    inline for (.{ []const u16, []const i64, [4]u8, []const u128 }) |T| try std.testing.expectEqual(null, comptime containsNoneText(.{ 1, 2 }, T));
    try std.testing.expectEqual(null, comptime containsAllText(.{ .admin, Role.user }, []const Role));
    try std.testing.expectEqual(null, comptime containsAllText(.{ .a, .b }, []const Open));
    try std.testing.expectEqual(null, comptime containsNoneText(.{true}, []const bool));
}

test "containsAll and containsNone are errors when an array cannot hold the values or the list leaves no value" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: ";
    try expect(head ++ "contains_all(.{ 1, 2, 3 }) on [2]u8: an array of 2 items cannot contain 3 different values", comptime containsAllText(.{ 1, 2, 3 }, [2]u8).?);
    try expect(head ++ "contains_all(.{1}) on [0]u8 is always false: the array has no items", comptime containsAllText(.{1}, [0]u8).?);
    try expect(head ++ "contains_none(.{1}) on [0]u8 is always true: the array has no items; remove it", comptime containsNoneText(.{1}, [0]u8).?);
    try expect(head ++ "contains_none(.{ true, false }) lists every value of bool; only an empty list would pass; use v.empty", comptime containsNoneText(.{ true, false }, []const bool).?);
    try expect(head ++ "contains_none(.{ true, false }) lists every value of bool; no value would pass", comptime containsNoneText(.{ true, false }, [2]bool).?);
    try expect(head ++ "contains_none(.{ .guest, .admin, .user }) lists every value of lists.Role; no value would pass", comptime containsNoneText(.{ .guest, .admin, .user }, [1]Role).?);
    try expect(head ++ "contains_none(.{ 0, 1 }) lists every value of u1; only an empty list would pass; use v.empty", comptime containsNoneText(.{ 0, 1 }, []const u1).?);
    // As many values as items, and every value in containsAll, are fine.
    try std.testing.expectEqual(null, comptime containsAllText(.{ 1, 2 }, [2]u8));
    try std.testing.expectEqual(null, comptime containsAllText(.{ true, false }, []const bool));
    try std.testing.expectEqual(null, comptime containsNoneText(.{ .a, .b }, []const Open));
}

test "an uncalled containsAll or containsNone gets an example call" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: Dto.field_rules.x: containsAll must be called, e.g. v.containsAll(.{\"a\"})", comptime uncalledText("containsAll", @TypeOf(containsAll)));
    try expect("validator: Dto.field_rules.x: containsNone must be called, e.g. v.containsNone(.{\"a\"})", comptime uncalledText("containsNone", @TypeOf(containsNone)));
}

test "containsAll finds every listed value among the items, one item per value" {
    try expectOutcome(.pass, containsAll(.{ "read", "write" }), @as([]const []const u8, &.{ "write", "x", "read" }));
    try expectOutcome(.fail, containsAll(.{ "read", "write" }), @as([]const []const u8, &.{ "read", "read" }));
    try expectOutcome(.fail, containsAll(.{"read"}), @as([]const []const u8, &.{}));
    try expectOutcome(.fail, containsAll(.{"read"}), @as([]const []const u8, &.{ "Read", "read " }));
    try expectOutcome(.pass, containsAll(.{ 1, 2 }), @as([]const u64, &.{ 2, 2, 1 }));
    try expectOutcome(.fail, containsAll(.{9007199254740993}), @as([]const u64, &.{9007199254740992}));
    try expectOutcome(.pass, containsAll(.{ .admin, .guest }), @as([]const Role, &.{ .guest, .user, .admin }));
    try expectOutcome(.fail, containsAll(.{.a}), @as([]const Open, &.{ .b, @fromBackingInt(0xff) }));
    try expectOutcome(.pass, containsAll(.{true}), @as([]const bool, &.{ false, true }));
    try expectOutcome(.pass, containsAll(.{ 3, 4 }), [4]u8{ 1, 2, 3, 4 });
    try expectOutcome(.pass, containsAll([_][]const u8{ "x", "y" }), @as([]const [:0]const u8, &.{ "y", "x" }));
}

test "containsNone fails on any listed value among the items" {
    try expectOutcome(.pass, containsNone(.{ "root", "admin" }), @as([]const []const u8, &.{ "user", "Root" }));
    try expectOutcome(.fail, containsNone(.{ "root", "admin" }), @as([]const []const u8, &.{ "user", "admin" }));
    try expectOutcome(.pass, containsNone(.{"root"}), @as([]const []const u8, &.{}));
    try expectOutcome(.fail, containsNone(.{ -1, 0 }), @as([]const i32, &.{ 5, 0 }));
    try expectOutcome(.pass, containsNone(.{.guest}), @as([]const Role, &.{ .admin, .user }));
    try expectOutcome(.fail, containsNone(.{.guest}), [2]Role{ .admin, .guest });
    try expectOutcome(.pass, containsNone(.{.a}), @as([]const Open, &.{ .b, @fromBackingInt(9) }));
    try expectOutcome(.fail, containsNone(.{.a}), @as([]const Open, &.{ @fromBackingInt(9), @fromBackingInt(0) }));
    try expectOutcome(.fail, containsNone(.{false}), @as([]const bool, &.{ true, false }));
}

/// No two of `items` are equal, by comparing every pair.
fn naiveUnique(comptime T: type, items: []const T) bool {
    for (items, 0..) |a, i| {
        for (items[i + 1 ..]) |b| {
            const same = if (comptime core.isString(T)) std.mem.eql(u8, a, b) else a == b;
            if (same) return false;
        }
    }
    return true;
}

test "uniqueItems agrees with a pairwise comparison on random lists of integers, strings and enums" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    var ints: [200]u16 = undefined;
    var modes: [200]Open = undefined;
    var bytes: [200][3]u8 = undefined;
    var strings: [200][]const u8 = undefined;
    for (0..2000) |_| {
        const n = random.uintAtMost(usize, ints.len);
        // Small ranges make duplicates likely, at every length.
        const range = random.uintAtMost(u16, 400) + 1;
        for (ints[0..n], modes[0..n], bytes[0..n], strings[0..n]) |*int, *mode, *string_bytes, *string| {
            int.* = random.uintLessThan(u16, range);
            mode.* = @fromBackingInt(@truncate(int.*));
            for (string_bytes) |*b| b.* = 'a' + random.uintLessThan(u8, 3);
            string.* = string_bytes[0..random.uintAtMost(usize, 3)];
        }
        try std.testing.expectEqual(naiveUnique(u16, ints[0..n]), uniqueItems.eval(&@as([]const u16, ints[0..n])) == .pass);
        try std.testing.expectEqual(naiveUnique(Open, modes[0..n]), uniqueItems.eval(&@as([]const Open, modes[0..n])) == .pass);
        try std.testing.expectEqual(naiveUnique([]const u8, strings[0..n]), uniqueItems.eval(&@as([]const []const u8, strings[0..n])) == .pass);
    }
}

/// An exhaustive enum of `n` tags, `t0` to `t<n - 1>`, whose values are
/// declared out of order.
fn ShuffledEnum(comptime n: usize) type {
    @setEvalBranchQuota(core.eval_quota);
    var names: [n][]const u8 = undefined;
    var values: [n]u32 = undefined;
    // 100003 is prime, so these values differ for every n below it.
    for (&names, &values, 0..) |*name, *value, i| {
        name.* = std.fmt.comptimePrint("t{d}", .{i});
        value.* = @intCast((i * 7919) % 100003);
    }
    const final_names = names;
    const final_values = values;
    return @Enum(u32, .exhaustive, &final_names, &final_values);
}

test "uniqueItems and uniqueBy take exhaustive enums of thousands of tags declared out of order" {
    const Big = ShuffledEnum(2000);
    try expectOutcome(.pass, uniqueItems, @as([]const Big, &.{ .t0, .t1999, .t17, .t1000, .t3 }));
    try expectOutcome(.fail, uniqueItems, @as([]const Big, &.{ .t17, .t3, .t1999, .t17 }));
    try expectOutcome(.fail, uniqueItems, [3]Big{ .t1999, .t0, .t1999 });
    const Keyed = struct { k: Big };
    try expectOutcome(.pass, uniqueBy(.k), @as([]const Keyed, &.{ .{ .k = .t1 }, .{ .k = .t2 } }));
    try expectOutcome(.fail, uniqueBy(.k), @as([]const Keyed, &.{ .{ .k = .t1998 }, .{ .k = .t5 }, .{ .k = .t1998 } }));
    // Every tag gets its own bit: all 2000 tags are unique, and one more repeats.
    const all = comptime std.enums.values(Big);
    try expectOutcome(.pass, uniqueItems, @as([]const Big, all));
    try expectOutcome(.fail, uniqueItems, @as([]const Big, all ++ &[_]Big{.t1234}));
}
