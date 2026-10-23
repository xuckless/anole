// Copied from vkiryakov/zefir src/validator/names.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! Outside names: `v.rename` gives a field the name it has outside the
//! program. The validator itself uses it only in the paths of violations;
//! `v.nameOf` and `v.fieldNamed` give the names of a struct to code that
//! reads and writes its values by those names, such as a codec of your own.
//! `std.json` does not know them: it reads and writes the Zig names. A field
//! without `v.rename` is called outside as it is in Zig.
const std = @import("std");
const core = @import("core.zig");

/// The longest outside name, in bytes.
const max_name_bytes = 64;

/// The outside name of a field: the first element of its entry in
/// `field_rules`, `.user_name = .{ v.rename("userName"), v.trim, v.notBlank }`.
/// The paths of violations call the field so (`userName`,
/// `items[2].userName`), and `v.nameOf` and `v.fieldNamed` give the name to
/// a codec that reads and writes values by it; `std.json` does not know it
/// and keeps the Zig name. A name is 1 to 64 characters from `A-Z`, `a-z`,
/// `0-9`, `_` and `-`, so that it fits a JSON key and a query parameter
/// alike; the outside names of the fields of a struct must differ. List
/// items have no name: it never goes inside `v.each`. A mistake is a
/// compile error.
pub fn rename(comptime name: []const u8) core.Rename {
    comptime {
        @setEvalBranchQuota(core.eval_quota);
        if (!isOutsideName(name))
            @compileError("validator: rename(\"" ++ core.escape(name) ++ "\"): an outside name is 1 to 64 characters from A-Z, a-z, 0-9, '_' and '-'");
        return .{ .name = name };
    }
}

/// The arguments the hints show for `rename` used without a call:
/// `rename must be called, e.g. v.rename("userName")`.
pub const call_examples = .{ .rename = "\"userName\"" };

/// 1 to 64 bytes from `A-Z`, `a-z`, `0-9`, `_` and `-`.
fn isOutsideName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes) return false;
    for (name) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '-' => {},
        else => return false,
    };
    return true;
}

/// The outside name of `field` of the struct `T`: the name its entry in
/// `field_rules` gives it with `v.rename`, or else its Zig name. Works for
/// any struct, with `field_rules` or without, and is known at compile time:
/// `v.nameOf(CreateUserRequest, .user_name)` is "userName".
pub fn nameOf(comptime T: type, comptime field: FieldOf(T, "nameOf")) []const u8 {
    return comptime checkedNames(T)[@backingInt(field)];
}

/// The non-comptime field of the struct `T` whose outside name is `name`,
/// or null: the reverse of `nameOf`. A field renamed with `v.rename` is
/// found by its outside name only, not by its Zig name. A table built at
/// compile time answers, so it works at run time, for the keys a decoder
/// reads, and at compile time.
pub fn fieldNamed(comptime T: type, name: []const u8) ?FieldOf(T, "fieldNamed") {
    const table = comptime lookup(T);
    return table.get(name);
}

/// The fields of `T` as an enum, for `nameOf` and `fieldNamed`. Any type
/// but a struct is refused here, before `std.meta.FieldEnum` would fail
/// inside std.
fn FieldOf(comptime T: type, comptime function: []const u8) type {
    if (@typeInfo(T) != .@"struct") @compileError("validator: " ++ function ++ "(" ++ @typeName(T) ++ "): expects a struct");
    return std.meta.FieldEnum(T);
}

/// The outside name of every field of the struct `T`, in declaration order;
/// a comptime field keeps its Zig name. Not checked: the declaration check
/// of `T` reports two fields with one name, with the path of `T` (see
/// `duplicateText`).
pub fn namesOf(comptime T: type) []const []const u8 {
    comptime {
        @setEvalBranchQuota(core.eval_quota);
        const info = @typeInfo(T).@"struct";
        var out: [info.field_names.len][]const u8 = undefined;
        for (info.field_names, info.field_attrs, &out) |field, attrs, *slot| {
            slot.* = if (attrs.@"comptime") field else renamedTo(T, field) orelse field;
        }
        const final = out;
        return &final;
    }
}

/// `namesOf(T)`, which stops compilation when two non-comptime fields share
/// an outside name: a decoder could not tell them apart.
fn checkedNames(comptime T: type) []const []const u8 {
    comptime {
        const names = namesOf(T);
        if (duplicateText(T, @typeName(T), names)) |text| @compileError(text);
        return names;
    }
}

/// The name that the entry of `field` of `T` gives it with `v.rename`, or
/// null. A misplaced element of the entry is reported here too, so that the
/// table of names never takes a name the declaration check refuses.
fn renamedTo(comptime T: type, comptime field: []const u8) ?[]const u8 {
    if (!@hasDecl(T, "field_rules")) return null;
    const R = @TypeOf(T.field_rules);
    if (!core.isFieldRulesTable(R) or !@hasField(R, field)) return null;
    const where = @typeName(T) ++ ".field_rules." ++ field;
    const parts = core.entryParts(@field(T.field_rules, field), where, false);
    if (parts.problem) |problem| @compileError(core.entryProblemText(problem, where));
    return parts.name;
}

/// The error for the first two non-comptime fields of `T` that share an
/// outside name in `names`, or null. `label` names `T` as the errors of its
/// declaration check do.
pub fn duplicateText(comptime T: type, comptime label: []const u8, comptime names: []const []const u8) ?[]const u8 {
    @setEvalBranchQuota(core.eval_quota);
    const info = @typeInfo(T).@"struct";
    for (info.field_names, info.field_attrs, names, 0..) |field, attrs, name, i| {
        if (attrs.@"comptime") continue;
        for (info.field_names[0..i], info.field_attrs[0..i], names[0..i]) |earlier, earlier_attrs, earlier_name| {
            if (!earlier_attrs.@"comptime" and std.mem.eql(u8, earlier_name, name))
                return "validator: " ++ label ++ ".field_rules: " ++ earlier ++ " and " ++ field ++ " are both named \"" ++ core.escape(name) ++ "\" outside";
        }
    }
    return null;
}

/// The table of `fieldNamed`: the outside name of each non-comptime field
/// of `T` and the field.
fn lookup(comptime T: type) std.StaticStringMap(std.meta.FieldEnum(T)) {
    comptime {
        @setEvalBranchQuota(core.eval_quota);
        const Field = std.meta.FieldEnum(T);
        const names = checkedNames(T);
        var pairs: []const struct { []const u8, Field } = &.{};
        for (@typeInfo(T).@"struct".field_attrs, names, 0..) |attrs, name, i| {
            if (!attrs.@"comptime") pairs = pairs ++ .{.{ name, @as(Field, @fromBackingInt(i)) }};
        }
        return .initComptime(pairs);
    }
}

const testing = std.testing;

test "an outside name is 1 to 64 characters from A-Z, a-z, 0-9, '_' and '-'" {
    inline for (.{ "userName", "user_name", "user-name", "X", "a1", "_", "-", "0" }) |name| try testing.expect(comptime isOutsideName(name));
    try testing.expect(comptime isOutsideName(&@as([64]u8, @splat('a'))));
    inline for (.{ "", "user name", "user.name", "a[0]", "имя", "a\nb", "a\"b", "a/b", "a=b", "a&b", "a%20" }) |name| {
        try testing.expect(!comptime isOutsideName(name));
    }
    try testing.expect(!comptime isOutsideName(&@as([65]u8, @splat('a'))));
    try testing.expectEqualStrings("userName", (comptime rename("userName")).name);
}

const Plain = struct { id: u64, user_name: []const u8, comptime version: u32 = 1 };

const Renamed = struct {
    id: u64,
    user_name: []const u8,
    email: ?[]const u8 = null,

    pub const field_rules = .{
        .user_name = .{ rename("userName"), @import("strings.zig").notBlank },
        .email = rename("e-mail"),
    };
};

test "the names of a struct are its outside names, the Zig name where no rename is given" {
    try testing.expectEqualStrings("id", comptime nameOf(Renamed, .id));
    try testing.expectEqualStrings("userName", comptime nameOf(Renamed, .user_name));
    try testing.expectEqualStrings("e-mail", comptime nameOf(Renamed, .email));
    try testing.expectEqualStrings("user_name", comptime nameOf(Plain, .user_name));
    try testing.expectEqualStrings("version", comptime nameOf(Plain, .version));
}

test "fieldNamed finds a non-comptime field by its outside name only" {
    try testing.expectEqual(.user_name, fieldNamed(Renamed, "userName").?);
    try testing.expectEqual(.email, fieldNamed(Renamed, "e-mail").?);
    try testing.expectEqual(.id, fieldNamed(Renamed, "id").?);
    try testing.expectEqual(null, fieldNamed(Renamed, "user_name"));
    try testing.expectEqual(null, fieldNamed(Renamed, "email"));
    try testing.expectEqual(null, fieldNamed(Renamed, "UserName"));
    try testing.expectEqual(null, fieldNamed(Renamed, ""));
    try testing.expectEqual(.user_name, fieldNamed(Plain, "user_name").?);
    // A comptime field is not read from outside.
    try testing.expectEqual(null, fieldNamed(Plain, "version"));
    try testing.expectEqual(null, fieldNamed(struct {}, "x"));
}

test "two fields with one outside name are named in declaration order, a rename onto another field's Zig name too" {
    const Twice = struct {
        user_name: []const u8,
        login: []const u8,
        pub const field_rules = .{ .user_name = rename("userName"), .login = rename("userName") };
    };
    try testing.expectEqualStrings(
        "validator: names.Twice.field_rules: user_name and login are both named \"userName\" outside",
        comptime duplicateText(Twice, "names.Twice", namesOf(Twice)).?,
    );
    const OntoZig = struct {
        userName: []const u8,
        user_name: []const u8,
        pub const field_rules = .{ .user_name = rename("userName") };
    };
    try testing.expectEqualStrings(
        "validator: names.OntoZig.field_rules: userName and user_name are both named \"userName\" outside",
        comptime duplicateText(OntoZig, "names.OntoZig", namesOf(OntoZig)).?,
    );
    try testing.expectEqual(null, comptime duplicateText(Renamed, "names.Renamed", namesOf(Renamed)));
    // Swapped names are no clash.
    const Swapped = struct {
        a: u32,
        b: u32,
        pub const field_rules = .{ .a = rename("b"), .b = rename("a") };
    };
    try testing.expectEqual(null, comptime duplicateText(Swapped, "names.Swapped", namesOf(Swapped)));
    try testing.expectEqual(.b, fieldNamed(Swapped, "a").?);
}
