// Adapted from vkiryakov/zefir src/http/input/strings.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! Strings into DTOs. The parameters of the path, the
//! query, a form, the headers and the cookies are names with string
//! values; the fields of a DTO are typed. Each field is found by its
//! outside name (`v.rename`, else its Zig name), a field of a DTO of
//! headers by its name with '_' as '-' in any case (`idempotency_key` reads
//! `Idempotency-Key`), and its values become its type:
//!
//! | Field        | From the string                                    |
//! |--------------|----------------------------------------------------|
//! | an integer   | decimal digits, '-' first for a signed type        |
//! | a float      | a decimal number that is finite                    |
//! | `bool`       | `true`, `false`, `1`, `0`                          |
//! | an enum      | the name of a variant: `high`                      |
//! | `[]const u8` | the string itself, valid UTF-8                     |
//! | `?T`         | null when the name is absent                       |
//! | `[]const T`  | one item per repeat of the name: `?tag=a&tag=b`    |
//!
//! A field with a default value keeps it when its name is absent. Every
//! problem is a violation (`http.invalid_type`, `http.missing_field`,
//! `http.unknown_field`), all of them at once; then the rules of the DTO
//! are not checked.
const std = @import("std");
const v = @import("validate");
const violations = @import("bind_violations.zig");
const dto = violations;

const Allocator = std.mem.Allocator;
const Collector = violations.Collector;
const messages = violations.messages;

/// Where the strings come from.
pub const Source = enum { path, query, form, headers, cookies };

/// A name and its value, decoded.
pub const Pair = struct { name: []const u8, value: []const u8 };

/// `InvalidRequest`: a string for a `[]const u8` field that is not valid
/// UTF-8.
pub const MapError = error{InvalidRequest} || Allocator.Error;

/// The call of `source`, as compile errors name it.
pub fn callName(comptime source: Source) []const u8 {
    return "req.bind" ++ switch (source) {
        .path => "Path",
        .query => "Query",
        .headers => "Headers",
        else => "",
    };
}

/// The compile-time checks that anole adds to the validator's for a
/// DTO of `source`: a struct, fields that a string can give, no `v.rename`
/// in a DTO of headers, and an `unknown_fields` that is a
/// `http.UnknownFields`.
pub fn check(comptime T: type, comptime source: Source) void {
    comptime {
        if (@typeInfo(T) != .@"struct") @compileError("anole: " ++ callName(source) ++ " takes a struct, got " ++ @typeName(T));
        const info = @typeInfo(T).@"struct";
        for (info.field_names, info.field_types, info.field_attrs) |name, F, attrs| {
            if (attrs.@"comptime") continue;
            if (shapeOf(F) == null) @compileError(fieldProblem(T, name, F));
        }
        if (@hasDecl(T, "unknown_fields")) _ = @as(dto.UnknownFields, T.unknown_fields);
    }
}

/// The policy for the unknown names of a DTO: its own `unknown_fields`,
/// typed or written as `.ignore`, else `server`'s.
pub fn unknownPolicy(comptime T: type, server: dto.UnknownFields) dto.UnknownFields {
    if (@hasDecl(T, "unknown_fields")) return comptime @as(dto.UnknownFields, T.unknown_fields);
    return server;
}

/// The header a field of a DTO of headers reads: `idempotency_key` is
/// `Idempotency-Key`; any case matches.
pub fn headerName(comptime field: []const u8) []const u8 {
    comptime {
        var name: [field.len]u8 = undefined;
        var start = true;
        for (field, &name) |c, *out| {
            out.* = if (c == '_') '-' else if (start) std.ascii.toUpper(c) else c;
            start = c == '_';
        }
        const final = name;
        return &final;
    }
}

/// Fills a `T` from `pairs`. Null when a value does not fit its field, a
/// field without a default is absent, a single field comes more than once,
/// or a name is unknown and `unknown` is `.reject`; the violations are in
/// `sink`. For cookies, the first of several values wins. The strings of
/// the result are those of `pairs`.
pub fn map(comptime T: type, comptime source: Source, arena: Allocator, pairs: []const Pair, unknown: dto.UnknownFields, sink: *Collector) MapError!?T {
    const info = @typeInfo(T).@"struct";
    const Field = std.meta.FieldEnum(T);
    // The field of each pair, null for an unknown name.
    const owners = try arena.alloc(?Field, pairs.len);
    var counts: [info.field_names.len]usize = @splat(0);
    for (pairs, owners) |pair, *owner| {
        owner.* = fieldOf(T, source, pair.name);
        if (owner.*) |f| {
            counts[@backingInt(f)] += 1;
        } else if (unknown == .reject and !sink.has(violations.unknown_field, pair.name)) {
            try sink.add(violations.unknown_field, messages.unknown, pair.name);
        }
    }
    // Headers and cookies have not been checked for UTF-8 yet.
    const check_utf8 = source == .headers or source == .cookies;

    var out: T = undefined;
    inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, F, attrs, i| {
        if (comptime attrs.@"comptime") continue;
        const field = @field(Field, name);
        const outside = comptime outsideName(T, source, name);
        const shape = comptime shapeOf(F).?;
        const target = &@field(out, name);
        const given = counts[i];
        if (given == 0) {
            if (comptime attrs.defaultValue(F)) |default| {
                target.* = default;
            } else if (shape.optional) {
                target.* = null;
            } else {
                try sink.add(violations.missing_field, messages.required, outside);
            }
        } else if (shape.list) {
            const items = try arena.alloc(shape.Item, if (source == .cookies) 1 else given);
            var k: usize = 0;
            for (pairs, owners) |pair, owner| {
                if (k == items.len) break;
                if ((owner orelse continue) != field) continue;
                if (try parse(shape.Item, check_utf8, pair.value)) |value| {
                    items[k] = value;
                } else {
                    try sink.addItem(violations.invalid_type, comptime messageOf(shape.Item), outside, k);
                }
                k += 1;
            }
            target.* = items;
        } else if (given > 1 and source != .cookies) {
            try sink.add(violations.invalid_type, messages.once, outside);
        } else {
            const text = for (pairs, owners) |pair, owner| {
                if ((owner orelse continue) == field) break pair.value;
            } else unreachable;
            if (try parse(shape.Item, check_utf8, text)) |value| {
                target.* = value;
            } else {
                try sink.add(violations.invalid_type, comptime messageOf(shape.Item), outside);
            }
        }
    }
    if (sink.items().len > 0) return null;
    return out;
}

/// A path of the validator in a DTO of headers, with its field under the
/// header's name, copied into `arena`: `idempotency_key` is
/// `Idempotency-Key`, `tags[1]` is `Tags[1]`.
pub fn headerPath(comptime T: type, arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    if (comptime @typeInfo(T) != .@"struct") return arena.dupe(u8, path);
    const end = std.mem.findAny(u8, path, "[.") orelse path.len;
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_attrs) |field, attrs| {
        if (comptime attrs.@"comptime") continue;
        if (std.mem.eql(u8, path[0..end], field)) return std.fmt.allocPrint(arena, "{s}{s}", .{ comptime outsideName(T, .headers, field), path[end..] });
    }
    return arena.dupe(u8, path);
}

/// What a field is made of: one value or a list of them, maybe optional.
const Shape = struct { optional: bool, list: bool, Item: type };

/// The shape of a field of type `F`, or null when no string gives it.
fn shapeOf(comptime F: type) ?Shape {
    const optional = @typeInfo(F) == .optional;
    const X = if (optional) @typeInfo(F).optional.child else F;
    if (isScalar(X)) return .{ .optional = optional, .list = false, .Item = X };
    if (listItem(X)) |Item| {
        if (isScalar(Item)) return .{ .optional = optional, .list = true, .Item = Item };
    }
    return null;
}

/// A value one string gives.
fn isScalar(comptime X: type) bool {
    return switch (@typeInfo(X)) {
        .int, .float, .bool, .@"enum" => true,
        else => X == []const u8,
    };
}

/// The item of `[]const Item`, else null.
pub fn listItem(comptime X: type) ?type {
    const info = @typeInfo(X);
    if (info != .pointer or info.pointer.size != .slice) return null;
    const Item = info.pointer.child;
    return if (X == []const Item) Item else null;
}

/// Whether `F` holds a struct or a union: inside an optional, a list or an
/// array too.
fn holdsStruct(comptime F: type) bool {
    return switch (@typeInfo(F)) {
        .@"struct", .@"union" => true,
        .optional => |o| holdsStruct(o.child),
        .pointer => |p| holdsStruct(p.child),
        .array => |a| holdsStruct(a.child),
        else => false,
    };
}

fn fieldProblem(comptime T: type, comptime name: []const u8, comptime F: type) []const u8 {
    const where = "anole: " ++ @typeName(T) ++ "." ++ name ++ ": ";
    if (holdsStruct(F)) return where ++ "a struct field comes only from JSON; query, form, path, headers and cookies hold strings";
    return where ++ @typeName(F) ++ " does not come from a string; query, form, path, headers and cookies give integers, floats, bool, enums and []const u8, alone, as ?T or as []const T";
}

/// The type of `v.rename(...)`: a constant, so that `rename` runs at
/// compile time.
const rename_example = v.rename("x");
const Rename = @TypeOf(rename_example);

/// Whether the entry of `field` in `T.field_rules` holds a `v.rename`.
pub fn hasRename(comptime T: type, comptime field: []const u8) bool {
    if (!@hasDecl(T, "field_rules")) return false;
    const Rules = @TypeOf(T.field_rules);
    if (@typeInfo(Rules) != .@"struct" or !@hasField(Rules, field)) return false;
    const E = @TypeOf(@field(T.field_rules, field));
    if (E == Rename) return true;
    if (@typeInfo(E) != .@"struct" or !@typeInfo(E).@"struct".is_tuple) return false;
    for (@typeInfo(E).@"struct".field_types) |Part| {
        if (Part == Rename) return true;
    }
    return false;
}

/// The name a field has in the source: its header name, else its outside
/// name.
fn outsideName(comptime T: type, comptime source: Source, comptime field: []const u8) []const u8 {
    if (source == .headers and !hasRename(T, field)) return headerName(field);
    return v.nameOf(T, @field(std.meta.FieldEnum(T), field));
}

/// The field that `name` fills, or null.
fn fieldOf(comptime T: type, comptime source: Source, name: []const u8) ?std.meta.FieldEnum(T) {
    if (source != .headers) return v.fieldNamed(T, name);
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_attrs) |field, attrs| {
        if (comptime attrs.@"comptime") continue;
        if (std.ascii.eqlIgnoreCase(name, comptime outsideName(T, .headers, field))) return @field(std.meta.FieldEnum(T), field);
    }
    return null;
}

/// `text` as an `Item`, or null when it is not one. With `check_utf8`, a
/// string that is not valid UTF-8 is a bad request.
fn parse(comptime Item: type, check_utf8: bool, text: []const u8) error{InvalidRequest}!?Item {
    if (Item == []const u8) {
        if (check_utf8 and !std.unicode.utf8ValidateSlice(text)) return error.InvalidRequest;
        return text;
    } else return switch (@typeInfo(Item)) {
        .int => integer(Item, text),
        .float => number(Item, text),
        .bool => if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "1"))
            true
        else if (std.mem.eql(u8, text, "false") or std.mem.eql(u8, text, "0"))
            false
        else
            null,
        .@"enum" => std.meta.stringToEnum(Item, text),
        else => comptime unreachable,
    };
}

/// Decimal digits, with '-' first for a signed type; null when they are
/// something else or do not fit.
fn integer(comptime I: type, text: []const u8) ?I {
    const digits = if (@typeInfo(I).int.signedness == .signed and text.len > 0 and text[0] == '-') text[1..] else text;
    if (digits.len == 0) return null;
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(I, text, 10) catch null;
}

/// A decimal number such as `2.5`, `-1e3`: digits, '.', an exponent and
/// signs only, so no `inf`, `nan`, hex or '_'; null when it is not finite.
fn number(comptime F: type, text: []const u8) ?F {
    for (text) |c| switch (c) {
        '0'...'9', '.', 'e', 'E', '+', '-' => {},
        else => return null,
    };
    const value = std.fmt.parseFloat(F, text) catch return null;
    return if (std.math.isFinite(value)) value else null;
}

/// The message of a value that is not an `Item`.
fn messageOf(comptime Item: type) []const u8 {
    return switch (@typeInfo(Item)) {
        .int => messages.integer,
        .float => messages.number,
        .bool => messages.boolean,
        .@"enum" => messages.oneOf(Item),
        // A string is never refused here.
        else => "must be a string",
    };
}

const testing = std.testing;

const Priority = enum { low, normal, high };

/// One field of each kind of the table.
const Every = struct {
    count: u32,
    delta: i64,
    ratio: f64,
    done: bool,
    priority: Priority,
    title: []const u8,
    note: ?[]const u8,
    level: ?u8 = null,
    page: u32 = 1,
    tags: []const []const u8 = &.{},
    ids: []const u64,
    comptime version: u32 = 1,
};

/// What mapping `pairs` into a `T` gave: the value or the violations.
fn Mapped(comptime T: type) type {
    return struct { value: ?T, sink: Collector };
}

fn mapInto(comptime T: type, comptime source: Source, arena: Allocator, pairs: []const Pair, unknown: dto.UnknownFields) MapError!Mapped(T) {
    comptime check(T, source);
    var sink: Collector = .init(arena);
    const value = try map(T, source, arena, pairs, unknown, &sink);
    return .{ .value = value, .sink = sink };
}

fn expectViolations(sink: *const Collector, expected: []const [3][]const u8) !void {
    const got = sink.items();
    errdefer for (got) |g| std.debug.print("  {s} at {?s}: {s}\n", .{ g.code, g.field, g.message });
    try testing.expectEqual(expected.len, got.len);
    for (expected, got) |want, g| {
        try testing.expectEqualStrings(want[0], g.code);
        try testing.expectEqualStrings(want[1], g.field orelse "(root)");
        try testing.expectEqualStrings(want[2], g.message);
    }
}

test "query: each field type takes its own string form, refuses the others, and names absent required fields" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const good = try mapInto(Every, .query, arena, &.{
        .{ .name = "count", .value = "42" },
        .{ .name = "delta", .value = "-7" },
        .{ .name = "ratio", .value = "2.5e1" },
        .{ .name = "done", .value = "1" },
        .{ .name = "priority", .value = "high" },
        .{ .name = "title", .value = "Buy milk" },
        .{ .name = "tags", .value = "home" },
        .{ .name = "ids", .value = "1" },
        .{ .name = "tags", .value = "shop" },
        .{ .name = "ids", .value = "3" },
    }, .ignore);
    const e = good.value orelse return error.TestUnexpectedResult;
    try testing.expectEqual(42, e.count);
    try testing.expectEqual(-7, e.delta);
    try testing.expectEqual(25.0, e.ratio);
    try testing.expect(e.done);
    try testing.expectEqual(.high, e.priority);
    try testing.expectEqualStrings("Buy milk", e.title);
    // Absent: an optional is null, a default stays.
    try testing.expectEqual(null, e.note);
    try testing.expectEqual(null, e.level);
    try testing.expectEqual(1, e.page);
    try testing.expectEqual(2, e.tags.len);
    try testing.expectEqualStrings("home", e.tags[0]);
    try testing.expectEqualStrings("shop", e.tags[1]);
    try testing.expectEqualSlices(u64, &.{ 1, 3 }, e.ids);

    // Each kind refuses what is not its own; the absent required fields
    // are named too.
    const bad = try mapInto(Every, .query, arena, &.{
        .{ .name = "count", .value = "-1" },
        .{ .name = "delta", .value = "1_000" },
        .{ .name = "ratio", .value = "inf" },
        .{ .name = "done", .value = "yes" },
        .{ .name = "priority", .value = "High" },
        .{ .name = "level", .value = "256" },
        .{ .name = "page", .value = "+1" },
        .{ .name = "ids", .value = "1" },
        .{ .name = "ids", .value = "x" },
    }, .ignore);
    try testing.expectEqual(null, bad.value);
    try expectViolations(&bad.sink, &.{
        .{ violations.invalid_type, "count", messages.integer },
        .{ violations.invalid_type, "delta", messages.integer },
        .{ violations.invalid_type, "ratio", messages.number },
        .{ violations.invalid_type, "done", messages.boolean },
        .{ violations.invalid_type, "priority", "must be one of low, normal, high" },
        .{ violations.missing_field, "title", messages.required },
        .{ violations.invalid_type, "level", messages.integer },
        .{ violations.invalid_type, "page", messages.integer },
        .{ violations.invalid_type, "ids[1]", messages.integer },
    });

    // The edges of numbers and booleans.
    const Numbers = struct { a: u8 = 0, b: i8 = 0, c: f32 = 0, d: bool = false };
    for ([_]struct { []const u8, []const u8, bool }{
        .{ "a", "255", true },  .{ "a", "256", false },  .{ "a", "007", true },   .{ "a", "-0", false },
        .{ "a", "", false },    .{ "a", " 1", false },   .{ "b", "-128", true },  .{ "b", "-129", false },
        .{ "b", "-", false },   .{ "b", "--1", false },  .{ "c", "-1.5", true },  .{ "c", "1e3", true },
        .{ "c", "nan", false }, .{ "c", "1e39", false }, .{ "c", "0x10", false }, .{ "c", "1_0", false },
        .{ "c", ".", false },   .{ "d", "true", true },  .{ "d", "0", true },     .{ "d", "TRUE", false },
        .{ "d", "", false },
    }) |case| {
        const got = try mapInto(Numbers, .query, arena, &.{.{ .name = case[0], .value = case[1] }}, .ignore);
        testing.expectEqual(case[2], got.value != null) catch |err| {
            std.debug.print("{s}={s}\n", .{ case[0], case[1] });
            return err;
        };
    }
}

const SearchQuery = struct {
    page: u32 = 1,
    per_page: u32 = 20,

    pub const field_rules = .{
        .page = v.range(1, 10_000),
        .per_page = .{ v.rename("perPage"), v.range(1, 100) },
    };
};

test "query: all violations at once, by outside names" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // page=0 breaks a rule, which mapping does not check; extra is ignored.
    const got = try mapInto(SearchQuery, .query, arena, &.{
        .{ .name = "perPage", .value = "x" },
        .{ .name = "page", .value = "0" },
        .{ .name = "extra", .value = "1" },
    }, .ignore);
    try testing.expectEqual(null, got.value);
    try expectViolations(&got.sink, &.{.{ violations.invalid_type, "perPage", messages.integer }});

    // The Zig name of a renamed field is an unknown name.
    const zig_name = try mapInto(SearchQuery, .query, arena, &.{
        .{ .name = "per_page", .value = "5" },
        .{ .name = "page", .value = "x" },
        .{ .name = "per_page", .value = "6" },
    }, .reject);
    try expectViolations(&zig_name.sink, &.{
        .{ violations.unknown_field, "per_page", messages.unknown },
        .{ violations.invalid_type, "page", messages.integer },
    });
    const renamed = try mapInto(SearchQuery, .query, arena, &.{.{ .name = "perPage", .value = "50" }}, .reject);
    try testing.expectEqual(50, (renamed.value orelse return error.TestUnexpectedResult).per_page);
}

test "query: a single-valued parameter given twice is a \"must be given once\" violation" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const got = try mapInto(SearchQuery, .query, arena_state.allocator(), &.{
        .{ .name = "page", .value = "1" },
        .{ .name = "page", .value = "2" },
    }, .ignore);
    try testing.expectEqual(null, got.value);
    try expectViolations(&got.sink, &.{.{ violations.invalid_type, "page", messages.once }});
}

test "headers: names with '-' for '_' in any case; strings must be UTF-8" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Headers = struct {
        idempotency_key: ?[]const u8 = null,
        x_forwarded_host: []const []const u8 = &.{},
        content_length: ?u64 = null,
    };
    try testing.expectEqualStrings("Idempotency-Key", comptime headerName("idempotency_key"));
    try testing.expectEqualStrings("X-Forwarded-Host", comptime headerName("x_forwarded_host"));
    const got = try mapInto(Headers, .headers, arena, &.{
        .{ .name = "IDEMPOTENCY-KEY", .value = "k-1" },
        .{ .name = "x-forwarded-host", .value = "a.example" },
        .{ .name = "Host", .value = "ignored" },
        .{ .name = "X-Forwarded-Host", .value = "b.example" },
        // The Zig name is no header name.
        .{ .name = "content_length", .value = "x" },
    }, .ignore);
    const h = got.value orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("k-1", h.idempotency_key orelse "");
    try testing.expectEqual(2, h.x_forwarded_host.len);
    try testing.expectEqualStrings("b.example", h.x_forwarded_host[1]);
    try testing.expectEqual(null, h.content_length);
    // Two of a single header; a header that is not UTF-8.
    const twice = try mapInto(Headers, .headers, arena, &.{
        .{ .name = "idempotency-key", .value = "a" },
        .{ .name = "Idempotency-Key", .value = "b" },
        .{ .name = "content-length", .value = "x" },
    }, .ignore);
    try expectViolations(&twice.sink, &.{
        .{ violations.invalid_type, "Idempotency-Key", messages.once },
        .{ violations.invalid_type, "Content-Length", messages.integer },
    });
    try testing.expectError(error.InvalidRequest, mapInto(Headers, .headers, arena, &.{.{ .name = "idempotency-key", .value = "\xff" }}, .ignore));
    // A path of the validator under the header's name.
    try testing.expectEqualStrings("Idempotency-Key", try headerPath(Headers, arena, "idempotency_key"));
    try testing.expectEqualStrings("X-Forwarded-Host[1]", try headerPath(Headers, arena, "x_forwarded_host[1]"));
}

test "cookies: the first of two equal names wins" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const Cookies = struct {
        session: []const u8,
        theme: []const []const u8 = &.{},
        pub const field_rules = .{ .session = v.rename("sid") };
    };
    const got = try mapInto(Cookies, .cookies, arena_state.allocator(), &.{
        .{ .name = "sid", .value = "first" },
        .{ .name = "theme", .value = "dark" },
        .{ .name = "sid", .value = "second" },
        .{ .name = "theme", .value = "light" },
        .{ .name = "other", .value = "x" },
    }, .ignore);
    const c = got.value orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("first", c.session);
    try testing.expectEqual(1, c.theme.len);
    try testing.expectEqualStrings("dark", c.theme[0]);
}
