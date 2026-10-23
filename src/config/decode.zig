// Adapted from vkiryakov/zefir src/confy/decode.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! Reads the configuration tree into the user's struct.
//!
//! - A field that no source sets gets its default value; without one, `?T` is
//!   null, a nested struct is read field by field, and anything else is `missing`.
//! - The default of a struct field (`db: Db = .{ .host = "x" }`) supplies the
//!   fields of `db` that no source sets, ahead of the defaults declared in `Db`.
//! - JSON `null` counts as not set.
//! - Strings (from `.env`, INI and the environment) are parsed into the field
//!   type; a list can be written comma-separated there (`HOSTS=a,b`).
//! - Keys in files that match no field are `unknown_key`, with a suggestion when
//!   one is close.
//! - A struct with `pub fn validate(self) !void` is checked once all its fields
//!   decoded without problems.
//!
//! The result points into the tree's memory; `copy.dupe` makes it independent.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Diagnostics = @import("Diagnostics.zig");
const tree = @import("tree.zig");
const Node = tree.Node;
const Object = tree.Object;
const naming = @import("naming.zig");
const Secret = @import("Secret.zig");
const Environment = @import("../modes.zig").Environment;

pub const Duration = std.Io.Duration;

pub const Context = struct {
    arena: Allocator,
    diag: *Diagnostics,
    env_prefix: []const u8 = "",
    /// Whether any source reads environment variables; used in hints.
    has_env_source: bool = false,
    /// Whether any source reads a JSON or INI file; used in hints.
    has_file_source: bool = false,
    /// Whose `pub const development` / `pub const production` overrides apply.
    environment: Environment = .production,
};

/// Problems go to `ctx.diag`; the result is only meaningful when none were added.
pub fn decode(comptime T: type, ctx: Context, root: *const Object) Allocator.Error!T {
    return decodeStruct(T, null, .{}, ctx, "", root);
}

/// `base`, when set, replaces the defaults declared in `T`. `ov` holds the
/// overrides a parent's `development`/`production` declaration gives this struct.
fn decodeStruct(comptime T: type, comptime base: ?T, comptime ov: anytype, ctx: Context, path: []const u8, object: ?*const Object) Allocator.Error!T {
    return switch (ctx.environment) {
        inline else => |e| decodeStructIn(T, base, ov, overridesOf(T, e), ctx, path, object),
    };
}

fn overridesOf(comptime T: type, comptime e: Environment) @TypeOf(if (@hasDecl(T, @tagName(e))) @field(T, @tagName(e)) else .{}) {
    return if (@hasDecl(T, @tagName(e))) @field(T, @tagName(e)) else .{};
}

fn checkOverrideNames(comptime T: type, comptime ov: anytype, comptime what: []const u8) void {
    comptime {
        for (@typeInfo(@TypeOf(ov)).@"struct".field_names) |n| {
            if (!@hasField(T, n)) @compileError("anole.config: " ++ @typeName(T) ++ "." ++ what ++ "." ++ n ++ " names no field of " ++ @typeName(T));
        }
    }
}

fn isNested(comptime FieldType: type) bool {
    return @typeInfo(FieldType) == .@"struct" and FieldType != Secret and FieldType != Duration;
}

fn decodeStructIn(comptime T: type, comptime base: ?T, comptime ov: anytype, comptime own: anytype, ctx: Context, path: []const u8, object: ?*const Object) Allocator.Error!T {
    comptime checkOverrideNames(T, own, "development/production");
    comptime checkOverrideNames(T, ov, "override");
    const problems_before = ctx.diag.problems.items.len;

    var result: T = undefined;
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types, info.field_attrs) |name, FieldType, attrs| {
        if (attrs.@"comptime") continue;
        const field_path = try joinPath(ctx.arena, path, name);
        const node = if (object) |o| o.fields.getPtr(name) else null;
        const has_override = comptime @hasField(@TypeOf(ov), name) or @hasField(@TypeOf(own), name);
        const field_override = comptime if (@hasField(@TypeOf(ov), name)) @field(ov, name) else if (@hasField(@TypeOf(own), name)) @field(own, name) else .{};
        // A struct literal for a struct field overrides some of its fields; anything else replaces the default.
        const nested = comptime has_override and isNested(FieldType) and @TypeOf(field_override) != FieldType;
        const child_ov = comptime if (nested) field_override else .{};
        const default: ?FieldType = comptime if (has_override and !nested)
            @as(FieldType, field_override)
        else if (base) |b| @field(b, name) else attrs.defaultValue(FieldType);
        @field(result, name) = try decodeField(FieldType, default, child_ov, ctx, field_path, node);
    }
    if (object) |o| try reportUnknownKeys(T, ctx, path, o);

    if (@hasDecl(T, "validate") and ctx.diag.problems.items.len == problems_before) {
        result.validate() catch |err| {
            try ctx.diag.addFmt(.invalid, path, null, "validate() returned error.{s}", .{@errorName(err)});
        };
    }
    return result;
}

fn decodeField(
    comptime T: type,
    comptime default: ?T,
    comptime ov: anytype,
    ctx: Context,
    path: []const u8,
    node: ?*const Node,
) Allocator.Error!T {
    if (node) |n| {
        if (n.value != .null) return decodeValue(T, default, ov, ctx, path, n);
    }
    // Overrides of a nested struct still apply when no source sets it.
    if (comptime isNested(T) and @typeInfo(@TypeOf(ov)).@"struct".field_names.len > 0) return decodeStruct(T, default, ov, ctx, path, null);
    if (default) |value| return value;
    if (@typeInfo(T) == .optional) return null;
    if (comptime isNested(T)) return decodeStruct(T, null, .{}, ctx, path, null);

    try ctx.diag.add(.{ .kind = .missing, .path = path, .detail = try missingHint(ctx, path) });
    return undefined;
}

/// `base` is the field's default; only structs use it, for the fields `node` doesn't set.
fn decodeValue(comptime T: type, comptime base: ?T, comptime ov: anytype, ctx: Context, path: []const u8, node: *const Node) Allocator.Error!T {
    if (T == Duration) {
        if (node.value == .string) {
            if (parseDuration(node.value.string)) |d| return d;
        }
        return invalid(T, ctx, path, node, "expected a duration with a unit, like \"30s\", \"250ms\" or \"1m30s\"");
    }
    if (T == Secret) {
        if (node.value == .string) return Secret.init(node.value.string);
        return invalid(T, ctx, path, node, "expected a string");
    }
    switch (@typeInfo(T)) {
        .optional => |optional| {
            if (node.value == .null) return null;
            return try decodeValue(optional.child, if (base) |b| b else null, ov, ctx, path, node);
        },
        .bool => {
            switch (node.value) {
                .boolean => |boolean| return boolean,
                .string => |string| if (parseBool(string)) |boolean| return boolean,
                else => {},
            }
            return invalid(T, ctx, path, node, "expected true or false");
        },
        .int => {
            switch (node.value) {
                .integer => |integer| if (std.math.cast(T, integer)) |value| return value,
                .string => |string| if (std.fmt.parseInt(T, std.mem.trim(u8, string, " \t"), 0)) |value| return value else |_| {},
                else => {},
            }
            return invalid(T, ctx, path, node, comptime std.fmt.comptimePrint(
                "expected an integer {d}..{d}",
                .{ std.math.minInt(T), std.math.maxInt(T) },
            ));
        },
        .float => {
            switch (node.value) {
                .float => |float| return @floatCast(float),
                .integer => |integer| return @floatFromInt(integer),
                .string => |string| if (std.fmt.parseFloat(T, std.mem.trim(u8, string, " \t"))) |value| return value else |_| {},
                else => {},
            }
            return invalid(T, ctx, path, node, "expected a number");
        },
        .@"enum" => {
            if (node.value == .string) {
                if (std.meta.stringToEnum(T, std.mem.trim(u8, node.value.string, " \t"))) |value| return value;
            }
            return invalid(T, ctx, path, node, comptime enumHint(T));
        },
        .pointer => |pointer| {
            if (pointer.size != .slice or !pointer.attrs.@"const") @compileError(unsupported(T));
            if (pointer.child == u8) {
                if (node.value == .string) return node.value.string;
                return invalid(T, ctx, path, node, "expected a string");
            }
            return decodeList(pointer.child, ctx, path, node);
        },
        .@"struct" => {
            if (node.value == .object) return decodeStruct(T, base, ov, ctx, path, node.value.object);
            return invalid(T, ctx, path, node, "expected a section with fields");
        },
        else => @compileError(unsupported(T)),
    }
}

fn decodeList(comptime E: type, ctx: Context, path: []const u8, node: *const Node) Allocator.Error![]const E {
    switch (node.value) {
        .array => |array| {
            const items = array.items.items;
            const list = try ctx.arena.alloc(E, items.len);
            for (items, list, 0..) |*item, *slot, i| {
                const item_path = try std.fmt.allocPrint(ctx.arena, "{s}[{d}]", .{ path, i });
                slot.* = try decodeValue(E, null, .{}, ctx, item_path, item);
            }
            return list;
        },
        .string => |string| if (comptime naming.StructOf(E) == null) {
            const trimmed = std.mem.trim(u8, string, " \t");
            if (trimmed.len == 0) return &.{};
            const list = try ctx.arena.alloc(E, std.mem.countScalar(u8, trimmed, ',') + 1);
            var parts = std.mem.splitScalar(u8, trimmed, ',');
            for (list, 0..) |*slot, i| {
                const part: Node = .{
                    .value = .{ .string = std.mem.trim(u8, parts.next().?, " \t") },
                    .origin = node.origin,
                };
                const item_path = try std.fmt.allocPrint(ctx.arena, "{s}[{d}]", .{ path, i });
                slot.* = try decodeValue(E, null, .{}, ctx, item_path, &part);
            }
            return list;
        },
        else => {},
    }
    return invalid([]const E, ctx, path, node, "expected a list");
}

fn invalid(comptime T: type, ctx: Context, path: []const u8, node: *const Node, detail: []const u8) Allocator.Error!T {
    try ctx.diag.add(.{ .kind = .invalid, .path = path, .origin = node.origin, .detail = detail });
    return undefined;
}

fn reportUnknownKeys(comptime T: type, ctx: Context, path: []const u8, object: *const Object) Allocator.Error!void {
    const names = comptime fieldNames(T);
    for (object.fields.keys(), object.fields.values()) |key, node| {
        if (isOneOf(key, names)) continue;
        const key_path = try joinPath(ctx.arena, path, key);
        if (closest(key, names)) |name| {
            try ctx.diag.addFmt(.unknown_key, key_path, node.origin, "did you mean \"{s}\"?", .{name});
        } else {
            try ctx.diag.add(.{ .kind = .unknown_key, .path = key_path, .origin = node.origin });
        }
    }
}

fn missingHint(ctx: Context, path: []const u8) Allocator.Error![]const u8 {
    const in_list = std.mem.findScalar(u8, path, '[') != null;
    if (ctx.has_env_source and !in_list) {
        const name = try envName(ctx.arena, ctx.env_prefix, path);
        if (ctx.has_file_source) return std.fmt.allocPrint(ctx.arena, "set {s}, or \"{s}\" in a config file", .{ name, path });
        return std.fmt.allocPrint(ctx.arena, "set {s}", .{name});
    }
    if (ctx.has_file_source) return std.fmt.allocPrint(ctx.arena, "set \"{s}\" in a config file", .{path});
    return "no source sets it";
}

fn envName(arena: Allocator, prefix: []const u8, path: []const u8) Allocator.Error![]const u8 {
    const name = try arena.alloc(u8, prefix.len + path.len);
    @memcpy(name[0..prefix.len], prefix);
    for (path, name[prefix.len..]) |c, *out| out.* = if (c == '.') '_' else std.ascii.toUpper(c);
    return name;
}

fn joinPath(arena: Allocator, parent: []const u8, key: []const u8) Allocator.Error![]const u8 {
    if (parent.len == 0) return key;
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ parent, key });
}

fn parseBool(raw: []const u8) ?bool {
    const string = std.mem.trim(u8, raw, " \t");
    for ([_][]const u8{ "true", "yes", "on", "1" }) |word| {
        if (std.ascii.eqlIgnoreCase(string, word)) return true;
    }
    for ([_][]const u8{ "false", "no", "off", "0" }) |word| {
        if (std.ascii.eqlIgnoreCase(string, word)) return false;
    }
    return null;
}

fn fieldNames(comptime T: type) []const []const u8 {
    var names: []const []const u8 = &.{};
    for (@typeInfo(T).@"struct".field_names) |name| names = names ++ [_][]const u8{name};
    return names;
}

fn enumHint(comptime T: type) []const u8 {
    var hint: []const u8 = "expected one of:";
    for (@typeInfo(T).@"enum".field_names, 0..) |name, i| {
        hint = hint ++ (if (i == 0) " " else ", ") ++ name;
    }
    return hint;
}

fn unsupported(comptime T: type) []const u8 {
    return "anole.config: fields of type " ++ @typeName(T) ++ " are not supported; use bool, an integer, a float, " ++
        "an enum, []const u8, anole.Secret, anole.Duration, a []const slice of these, a struct, or an optional of any of them";
}

fn isOneOf(key: []const u8, names: []const []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, key, name)) return true;
    }
    return false;
}

/// The name closest to `key`, if it is close enough to be a likely typo.
fn closest(key: []const u8, names: []const []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_distance: usize = 3;
    for (names) |name| {
        const distance = editDistance(key, name) orelse continue;
        if (distance < best_distance and distance < key.len) {
            best = name;
            best_distance = distance;
        }
    }
    return best;
}

/// Levenshtein distance ignoring case; null for strings longer than 64 bytes.
fn editDistance(a: []const u8, b: []const u8) ?usize {
    if (a.len > 64 or b.len > 64) return null;
    var previous: [65]usize = undefined;
    var current: [65]usize = undefined;
    for (previous[0 .. b.len + 1], 0..) |*cell, j| cell.* = j;
    for (a, 0..) |char_a, i| {
        current[0] = i + 1;
        for (b, 0..) |char_b, j| {
            const cost: usize = if (std.ascii.toLower(char_a) == std.ascii.toLower(char_b)) 0 else 1;
            current[j + 1] = @min(previous[j + 1] + 1, current[j] + 1, previous[j] + cost);
        }
        @memcpy(previous[0 .. b.len + 1], current[0 .. b.len + 1]);
    }
    return previous[b.len];
}

test "edit distance and suggestions" {
    try std.testing.expectEqual(1, editDistance("databse", "database"));
    try std.testing.expectEqual(2, editDistance("prot", "port"));
    try std.testing.expectEqualStrings("database", closest("databse", &.{ "name", "database" }).?);
    try std.testing.expectEqual(null, closest("x", &.{ "name", "database" }));
}

test "bools in every spelling" {
    try std.testing.expectEqual(true, parseBool(" Yes "));
    try std.testing.expectEqual(false, parseBool("OFF"));
    try std.testing.expectEqual(null, parseBool("maybe"));
}

test "edit distance ignores case and gives up on long strings" {
    try std.testing.expectEqual(0, editDistance("PORT", "port"));
    try std.testing.expectEqual(3, editDistance("", "abc"));
    try std.testing.expectEqual(null, editDistance(&@as([65]u8, @splat('a')), "a"));
    try std.testing.expectEqual(null, closest("ab", &.{"xy"}));
}

test "hints spell out environment names and enum tags" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectEqualStrings("APP_DB_POOL_SIZE", try envName(arena_state.allocator(), "APP_", "db.pool_size"));
    try std.testing.expectEqualStrings("expected one of: low, high", comptime enumHint(enum { low, high }));
}

/// `"30s"`, `"250ms"`, `"1m30s"`, `"1h"`; `"0"` alone is zero. No sign, no
/// fractions, no spaces inside, no bare numbers.
pub fn parseDuration(text: []const u8) ?Duration {
    const t = std.mem.trim(u8, text, " \t");
    if (t.len == 0) return null;
    if (std.mem.eql(u8, t, "0")) return .zero;
    var total: i96 = 0;
    var i: usize = 0;
    while (i < t.len) {
        const start = i;
        while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
        if (i == start) return null;
        const n = std.fmt.parseInt(i96, t[start..i], 10) catch return null;
        const unit_start = i;
        while (i < t.len and std.ascii.isAlphabetic(t[i])) i += 1;
        const unit = t[unit_start..i];
        const unit_ns: i96 = if (std.mem.eql(u8, unit, "ms"))
            std.time.ns_per_ms
        else if (std.mem.eql(u8, unit, "s"))
            std.time.ns_per_s
        else if (std.mem.eql(u8, unit, "m"))
            std.time.ns_per_min
        else if (std.mem.eql(u8, unit, "h"))
            std.time.ns_per_hour
        else
            return null;
        const part = std.math.mul(i96, n, unit_ns) catch return null;
        total = std.math.add(i96, total, part) catch return null;
    }
    return .{ .nanoseconds = total };
}

test "parseDuration" {
    try std.testing.expectEqual(@as(i96, 30 * std.time.ns_per_s), parseDuration("30s").?.nanoseconds);
    try std.testing.expectEqual(@as(i96, 250 * std.time.ns_per_ms), parseDuration("250ms").?.nanoseconds);
    try std.testing.expectEqual(@as(i96, 90 * std.time.ns_per_s), parseDuration("1m30s").?.nanoseconds);
    try std.testing.expectEqual(@as(i96, std.time.ns_per_hour), parseDuration("1h").?.nanoseconds);
    try std.testing.expectEqual(@as(i96, 0), parseDuration("0").?.nanoseconds);
    for ([_][]const u8{ "30", "1.5s", "-1s", "1d", "", "s", "1 s" }) |bad| try std.testing.expectEqual(null, parseDuration(bad));
}
