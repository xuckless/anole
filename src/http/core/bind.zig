// Adapted from vkiryakov/zefir src/http/input/json_in.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! JSON into DTOs. The tokens of the body come from
//! `std.json.Scanner`, which holds them to the syntax of RFC 8259 and
//! refuses invalid UTF-8; the mapping is our own, by the outside names of
//! the validator (`v.fieldNamed`), so that every problem of the input
//! becomes a violation that names its field:
//!
//! | Field        | From JSON                                          |
//! |--------------|----------------------------------------------------|
//! | an integer   | a number without a fraction or an exponent         |
//! | a float      | a number, finite                                   |
//! | `bool`       | `true`, `false`                                    |
//! | an enum      | a string, the name of a variant: `"high"`          |
//! | `[]const u8` | a string                                           |
//! | a struct     | an object, its keys the outside names of the fields |
//! | `[]const T`  | an array                                           |
//! | `?T`         | `null`, or the field absent                        |
//!
//! A field with a default value keeps it when it is absent. What is not
//! JSON, a key given twice in an object and nesting deeper than
//! `.json.max_depth` are `error.InvalidRequest` (400); lists whose items
//! take more memory than `Options.max_list_bytes`, all lists together, are
//! `error.PayloadTooLarge` (413), so that a body of small items, such as
//! `[{},{},…]`, costs no more than a few times its size. A value of the
//! wrong type (`http.invalid_type`), a field that is missing
//! (`http.missing_field`) and a key the struct does not have
//! (`http.unknown_field`, unless its policy ignores it) are violations, all
//! of them at once, in the order of the body; the missing fields of an
//! object come after its other violations. Paths name fields by their
//! outside names: `items[2].displayName`.
const std = @import("std");
const v = @import("validate");
const strings = @import("bind_strings.zig");
const violations = @import("bind_violations.zig");
const dto = violations;
const http = @import("http.zig");

const Allocator = std.mem.Allocator;
const Token = std.json.Token;
const Collector = violations.Collector;
const messages = violations.messages;

/// `InvalidRequest`: the body is not JSON, a key of an object comes twice,
/// or objects and arrays nest deeper than `Options.max_depth`.
/// `PayloadTooLarge`: the items of the lists take more than
/// `Options.max_list_bytes`.
pub const Error = error{ InvalidRequest, PayloadTooLarge } || Allocator.Error;

pub const Options = struct {
    /// The deepest nesting of objects and arrays, the top level included:
    /// `[]` is 1.
    max_depth: usize = 64,
    /// What happens to the unknown keys of a struct that does not say it
    /// itself with `pub const unknown_fields`.
    unknown: dto.UnknownFields = .reject,
    /// The most bytes the items of the lists of the value take, all lists
    /// together, each item as `@sizeOf` its type: `req.bind` gives 4 ×
    /// `.max_body_bytes`.
    max_list_bytes: usize = std.math.maxInt(usize),
};

/// The compile-time check of a DTO of `req.bind`: every type in it is one
/// that JSON gives, and every `unknown_fields` is a `http.UnknownFields`.
pub fn check(comptime T: type) void {
    comptime {
        @setEvalBranchQuota(100_000);
        checkType(T, @typeName(T), &.{});
    }
}

/// Whether the request mapper reads a `T`: integers, floats, `bool`, enums,
/// `[]const u8`, structs (not tuples, not types with a `jsonParse`), `?T` and
/// `[]const T` of those. Anything else (`[N]T`, unions, `std.json.Value`,
/// `[]u8`, sentinel slices) is bound with std.json instead.
pub fn supported(comptime T: type) bool {
    return comptime mappable(T, &.{});
}

fn mappable(comptime X: type, comptime stack: []const type) bool {
    @setEvalBranchQuota(100_000);
    switch (@typeInfo(X)) {
        .bool, .int, .float, .@"enum" => return true,
        .optional => |o| return mappable(o.child, stack),
        .pointer => {
            if (X == []const u8) return true;
            if (strings.listItem(X)) |Item| return mappable(Item, stack);
            return false;
        },
        .@"struct" => |s| {
            if (s.is_tuple or @hasDecl(X, "jsonParse") or @hasDecl(X, "jsonParseFromValue")) return false;
            for (stack) |Seen| {
                if (Seen == X) return true;
            }
            for (s.field_names, s.field_types, s.field_attrs) |_, F, attrs| {
                if (!attrs.@"comptime" and !mappable(F, stack ++ &[_]type{X})) return false;
            }
            return true;
        },
        else => return false,
    }
}

/// Whether a `T`, or a type inside it, renames a field with `v.rename`.
pub fn usesRename(comptime T: type) bool {
    return comptime renameIn(T, &.{});
}

fn renameIn(comptime X: type, comptime stack: []const type) bool {
    @setEvalBranchQuota(100_000);
    for (stack) |Seen| {
        if (Seen == X) return false;
    }
    const next = stack ++ &[_]type{X};
    switch (@typeInfo(X)) {
        .optional => |o| return renameIn(o.child, next),
        .pointer => |p| return switch (p.size) {
            .one, .slice => renameIn(p.child, next),
            else => false,
        },
        .array => |a| return renameIn(a.child, next),
        .@"struct" => |s| {
            for (s.field_names, s.field_types) |name, F| {
                if (!s.is_tuple and strings.hasRename(X, name)) return true;
                if (renameIn(F, next)) return true;
            }
            return false;
        },
        .@"union" => |u| {
            for (u.field_types) |F| if (renameIn(F, next)) return true;
            return false;
        },
        else => return false,
    }
}

/// `bytes` as a `T`. Null when the value does not fit `T`; the violations
/// are then in `sink`. The strings of the result are parts of `bytes`, or
/// come from `arena` when they had escapes.
pub fn parse(comptime T: type, arena: Allocator, bytes: []const u8, options: Options, sink: *Collector) Error!?T {
    var p: Parser = .{ .scanner = .initCompleteInput(arena, bytes), .arena = arena, .sink = sink, .options = options };
    var out: T = undefined;
    const ok = try p.read(T, &out);
    // The value is the whole document: what follows it is a syntax error.
    if (try p.next() != .end_of_document) return error.InvalidRequest;
    if (!ok or sink.items().len > 0) return null;
    return out;
}

const Parser = struct {
    scanner: std.json.Scanner,
    arena: Allocator,
    sink: *Collector,
    options: Options,
    /// The path of the value being read, such as `items[2].displayName`;
    /// empty at the top.
    path: std.ArrayList(u8) = .empty,
    /// The bytes the items of the lists kept so far take.
    list_bytes: usize = 0,

    /// The next token, a string or a number whole.
    fn next(p: *Parser) Error!Token {
        return p.scanner.nextAllocMax(p.arena, .alloc_if_needed, std.math.maxInt(usize)) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidRequest,
        };
    }

    fn peek(p: *Parser) Error!std.json.TokenType {
        return p.scanner.peekNextTokenType() catch error.InvalidRequest;
    }

    /// Just after a `{` or a `[`: one level deeper.
    fn deeper(p: *Parser) Error!void {
        if (p.scanner.stackHeight() > p.options.max_depth) return error.InvalidRequest;
    }

    /// Past the next value, whatever it holds; its nesting counts as any
    /// other.
    fn skip(p: *Parser) Error!void {
        const height = p.scanner.stackHeight();
        while (true) {
            const token = p.scanner.next() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidRequest,
            };
            switch (token) {
                .object_begin, .array_begin => try p.deeper(),
                .partial_number,
                .partial_string,
                .partial_string_escaped_1,
                .partial_string_escaped_2,
                .partial_string_escaped_3,
                .partial_string_escaped_4,
                => continue,
                .end_of_document => return error.InvalidRequest,
                else => {},
            }
            if (p.scanner.stackHeight() == height) return;
        }
    }

    /// A violation at the path of the value being read.
    fn fail(p: *Parser, code: []const u8, message: []const u8) Error!void {
        try p.sink.addCopy(code, message, if (p.path.items.len > 0) p.path.items else null);
    }

    /// Reads the next value into `out`; false when it does not fit `T`, its
    /// violations collected.
    fn read(p: *Parser, comptime T: type, out: *T) Error!bool {
        const kind = try p.peek();
        switch (@typeInfo(T)) {
            .optional => |o| {
                if (kind == .null) {
                    _ = try p.next();
                    out.* = null;
                    return true;
                }
                var payload: o.child = undefined;
                if (!try p.read(o.child, &payload)) return false;
                out.* = payload;
                return true;
            },
            .bool => if (kind == .true or kind == .false) {
                out.* = try p.next() == .true;
                return true;
            },
            .int, .float => if (kind == .number) {
                const token = try p.next();
                const text = switch (token) {
                    .number => |text| text,
                    .allocated_number => |text| text,
                    else => return error.InvalidRequest,
                };
                out.* = number(T, text) orelse {
                    try p.fail(violations.invalid_type, comptime messageOf(T));
                    return false;
                };
                return true;
            },
            .@"enum" => if (kind == .string) {
                const text = stringOf(try p.next()) orelse return error.InvalidRequest;
                out.* = std.meta.stringToEnum(T, text) orelse {
                    try p.fail(violations.invalid_type, comptime messageOf(T));
                    return false;
                };
                return true;
            },
            .pointer => |ptr| if (T == []const u8) {
                if (kind == .string) {
                    out.* = stringOf(try p.next()) orelse return error.InvalidRequest;
                    return true;
                }
            } else if (kind == .array_begin) {
                return p.readList(ptr.child, out);
            },
            .@"struct" => if (kind == .object_begin) return p.readObject(T, out),
            else => comptime unreachable,
        }
        try p.skip();
        try p.fail(violations.invalid_type, comptime messageOf(T));
        return false;
    }

    fn readList(p: *Parser, comptime Item: type, out: *[]const Item) Error!bool {
        _ = try p.next();
        try p.deeper();
        var items: std.ArrayList(Item) = .empty;
        // Once an item fails, the list is of no use: the rest are read into
        // one value and not kept.
        var scratch: Item = undefined;
        var ok = true;
        var index: usize = 0;
        while (try p.peek() != .array_end) : (index += 1) {
            const mark = p.path.items.len;
            defer p.path.shrinkRetainingCapacity(mark);
            try p.path.print(p.arena, "[{d}]", .{index});
            if (ok) {
                p.list_bytes +|= @sizeOf(Item);
                if (p.list_bytes > p.options.max_list_bytes) return error.PayloadTooLarge;
            }
            const slot = if (ok) try items.addOne(p.arena) else &scratch;
            if (!try p.read(Item, slot)) ok = false;
        }
        _ = try p.next();
        out.* = items.items;
        return ok;
    }

    fn readObject(p: *Parser, comptime S: type, out: *S) Error!bool {
        _ = try p.next();
        try p.deeper();
        const info = @typeInfo(S).@"struct";
        const unknown = strings.unknownPolicy(S, p.options.unknown);
        var seen: [@max(1, info.field_names.len)]bool = @splat(false);
        var ok = true;
        while (true) {
            const token = try p.next();
            if (token == .object_end) break;
            const key = stringOf(token) orelse return error.InvalidRequest;
            const mark = p.path.items.len;
            defer p.path.shrinkRetainingCapacity(mark);
            try p.pushName(key);
            const index = fieldIndex(S, key) orelse {
                if (unknown == .reject) {
                    if (!p.sink.has(violations.unknown_field, p.path.items)) try p.fail(violations.unknown_field, messages.unknown);
                    ok = false;
                }
                try p.skip();
                continue;
            };
            // A key given twice: two parsers could each take another value
            // of it.
            if (seen[index]) return error.InvalidRequest;
            seen[index] = true;
            inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, F, attrs, i| {
                if (comptime !attrs.@"comptime") {
                    if (index == i and !try p.read(F, &@field(out, name))) ok = false;
                }
            }
        }
        inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, F, attrs, i| {
            if (comptime !attrs.@"comptime") {
                if (!seen[i]) {
                    if (comptime attrs.defaultValue(F)) |default| {
                        @field(out, name) = default;
                    } else if (comptime @typeInfo(F) == .optional) {
                        @field(out, name) = null;
                    } else {
                        const mark = p.path.items.len;
                        defer p.path.shrinkRetainingCapacity(mark);
                        try p.pushName(comptime v.nameOf(S, @field(std.meta.FieldEnum(S), name)));
                        try p.fail(violations.missing_field, messages.required);
                        ok = false;
                    }
                }
            }
        }
        return ok;
    }

    /// Adds the field `name` to the path: `name`, or `items[2].name`.
    fn pushName(p: *Parser, name: []const u8) Allocator.Error!void {
        if (p.path.items.len > 0) try p.path.append(p.arena, '.');
        try p.path.appendSlice(p.arena, name);
    }
};

/// The index of the non-comptime field of `S` whose outside name is `key`.
fn fieldIndex(comptime S: type, key: []const u8) ?usize {
    if (comptime @typeInfo(S).@"struct".field_names.len == 0) return null;
    const field = v.fieldNamed(S, key) orelse return null;
    return @backingInt(field);
}

fn stringOf(token: Token) ?[]const u8 {
    return switch (token) {
        .string => |text| text,
        .allocated_string => |text| text,
        else => null,
    };
}

/// A JSON number as a `T`, or null when it is not one: an integer has
/// neither a fraction nor an exponent, '-' only when signed, and fits; a
/// float is finite.
fn number(comptime T: type, text: []const u8) ?T {
    switch (@typeInfo(T)) {
        .int => |info| {
            if (std.mem.findAny(u8, text, ".eE") != null) return null;
            if (info.signedness == .unsigned and text[0] == '-') return null;
            return std.fmt.parseInt(T, text, 10) catch null;
        },
        .float => {
            const value = std.fmt.parseFloat(T, text) catch return null;
            return if (std.math.isFinite(value)) value else null;
        },
        else => comptime unreachable,
    }
}

/// What a value of `T` must be.
fn messageOf(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .optional => |o| messageOf(o.child),
        .int => messages.integer,
        .float => messages.number,
        .bool => messages.true_or_false,
        .@"enum" => messages.oneOf(T),
        .@"struct" => messages.object,
        .pointer => if (T == []const u8) messages.string else messages.array,
        else => comptime unreachable,
    };
}

fn checkType(comptime X: type, comptime where: []const u8, comptime stack: []const type) void {
    switch (@typeInfo(X)) {
        .bool, .int, .float, .@"enum" => return,
        .optional => |o| return checkType(o.child, where, stack),
        .pointer => {
            if (X == []const u8) return;
            if (strings.listItem(X)) |Item| return checkType(Item, where ++ "[]", stack);
        },
        .@"struct" => |s| if (!s.is_tuple) {
            // A struct that holds itself, through a list or an optional.
            for (stack) |Seen| {
                if (Seen == X) return;
            }
            for (s.field_names, s.field_types, s.field_attrs) |name, F, attrs| {
                if (!attrs.@"comptime") checkType(F, @typeName(X) ++ "." ++ name, stack ++ &[_]type{X});
            }
            if (@hasDecl(X, "unknown_fields")) _ = @as(dto.UnknownFields, X.unknown_fields);
            return;
        },
        else => {},
    }
    @compileError("anole: " ++ where ++ ": " ++ @typeName(X) ++ " does not come from JSON; req.bind reads integers, floats, bool, enums, []const u8 and structs, alone, as ?T or as []const T");
}

// ------------------------------------------------------------------ the entry points

pub const UnknownFields = violations.UnknownFields;

pub const BindOptions = struct {
    /// The most bytes the items of the lists take (4 x the body limit for
    /// `req.bind`).
    max_list_bytes: usize = 4 * 1024 * 1024,
    /// Null: the type's own `pub const unknown_fields`, else ignored.
    unknown_fields: ?UnknownFields = null,
};

pub fn BindResult(comptime T: type) type {
    return union(enum) { ok: T, invalid: http.Violations };
}

/// The collected mapping violations as the request's, with `in` set.
pub fn toViolations(arena: Allocator, sink: *const Collector, in: http.Violation.Source) Allocator.Error!http.Violations {
    const out = try arena.alloc(http.Violation, sink.items().len);
    for (sink.items(), out) |item, *o| o.* = .{ .in = in, .field = item.field, .code = item.code, .message = item.message };
    return .{ .items = out, .truncated = sink.truncated };
}

/// Runs the transforms of `value`'s `field_rules`, then its rules. Null
/// when every rule holds. `fix` rewrites a rule path (headers).
pub fn applyRules(comptime T: type, arena: Allocator, value: *T, in: http.Violation.Source) error{ OutOfMemory, TransformFailed }!?http.Violations {
    v.transform(arena, value) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.TransformFailed;
    };
    const report = try v.checkAll(arena, value);
    if (report.violations.len == 0) return null;
    const out = try arena.alloc(http.Violation, report.violations.len);
    for (report.violations, out) |item, *o| {
        const field = if (in == .header and item.field != null) try strings.headerPath(T, arena, item.field.?) else item.field;
        o.* = .{ .in = in, .field = field, .code = item.code, .message = item.message };
    }
    return .{ .items = out, .truncated = report.truncated };
}

/// `bytes` as a `T` and checked by its `field_rules`; the context-free
/// entry point `req.bind` is built on (NATS and Kafka messages use it too).
/// A body that is not JSON, repeats a key or nests past 64 levels is
/// `error.InvalidJsonBody`; lists past `max_list_bytes` are
/// `error.BodyTooBig`; a value that does not fit, or breaks a rule, is
/// `.invalid` with every violation (in = body). Types the mapper does not
/// read are parsed with std.json (unknown fields ignored); renames need the
/// mapper's types.
pub fn bindJson(comptime T: type, arena: Allocator, bytes: []const u8, options: BindOptions) error{ InvalidJsonBody, BodyTooBig, OutOfMemory }!BindResult(T) {
    var value: T = undefined;
    if (comptime supported(T)) {
        comptime check(T);
        var sink: Collector = .init(arena);
        const parsed = parse(T, arena, bytes, .{
            .unknown = options.unknown_fields orelse .ignore,
            .max_list_bytes = options.max_list_bytes,
        }, &sink) catch |err| switch (err) {
            error.InvalidRequest => return error.InvalidJsonBody,
            error.PayloadTooLarge => return error.BodyTooBig,
            error.OutOfMemory => return error.OutOfMemory,
        };
        value = parsed orelse return .{ .invalid = try toViolations(arena, &sink, .body) };
    } else {
        comptime if (usesRename(T)) @compileError("anole: binding " ++ @typeName(T) ++ ": a field is renamed with v.rename, but the type holds something the request mapper does not read " ++
            "([N]T, unions, std.json.Value, []u8, a type with jsonParse); renames need the mapper's types: integers, floats, bool, enums, []const u8, structs, ?T and []const T");
        value = std.json.parseFromSliceLeaky(T, arena, bytes, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidJsonBody,
        };
    }
    const bad = applyRules(T, arena, &value, .body) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TransformFailed => return error.InvalidJsonBody,
    };
    if (bad) |violations_found| return .{ .invalid = violations_found };
    return .{ .ok = value };
}

const testing = std.testing;

const Priority = enum { low, normal, high };

const Line = struct {
    display_name: []const u8,
    pub const field_rules = .{ .display_name = v.rename("displayName") };
};

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
    items: []const Line = &.{},
    owner: ?Line = null,
    comptime version: u32 = 1,
};

/// What parsing `bytes` into a `T` gave: the value or the violations.
fn Parsed(comptime T: type) type {
    return struct { value: ?T, sink: Collector };
}

fn parseInto(comptime T: type, arena: Allocator, bytes: []const u8, options: Options) Error!Parsed(T) {
    comptime check(T);
    var sink: Collector = .init(arena);
    const value = try parse(T, arena, bytes, options, &sink);
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

test "json: every type of the section 7 table" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const good = try parseInto(Every, arena,
        \\{"count": 42, "delta": -7, "ratio": 2.5e1, "done": true, "priority": "high",
        \\ "title": "Buy \"milk\" \u00e9", "note": null, "tags": ["home", "shop"],
        \\ "items": [{"displayName": "Ann"}, {"displayName": "Bob"}], "owner": {"displayName": "Eve"}}
    , .{});
    const e = good.value orelse return error.TestUnexpectedResult;
    try testing.expectEqual(42, e.count);
    try testing.expectEqual(-7, e.delta);
    try testing.expectEqual(25.0, e.ratio);
    try testing.expect(e.done);
    try testing.expectEqual(.high, e.priority);
    try testing.expectEqualStrings("Buy \"milk\" é", e.title);
    try testing.expectEqual(null, e.note);
    // Absent: an optional is null, a default stays.
    try testing.expectEqual(null, e.level);
    try testing.expectEqual(1, e.page);
    try testing.expectEqual(2, e.tags.len);
    try testing.expectEqualStrings("shop", e.tags[1]);
    try testing.expectEqualStrings("Bob", e.items[1].display_name);
    try testing.expectEqualStrings("Eve", e.owner.?.display_name);

    // Each kind refuses what is not its own, whatever the value holds.
    const bad = try parseInto(Every, arena,
        \\{"count": -1, "delta": 1.5, "ratio": "2", "done": 1, "priority": "High", "title": 5,
        \\ "note": [1, {"a": [2]}], "level": 256, "page": 1e2, "tags": "home",
        \\ "items": [{"displayName": "Ann"}, {"displayName": false}, 3], "owner": []}
    , .{});
    try testing.expectEqual(null, bad.value);
    try expectViolations(&bad.sink, &.{
        .{ violations.invalid_type, "count", messages.integer },
        .{ violations.invalid_type, "delta", messages.integer },
        .{ violations.invalid_type, "ratio", messages.number },
        .{ violations.invalid_type, "done", messages.true_or_false },
        .{ violations.invalid_type, "priority", "must be one of low, normal, high" },
        .{ violations.invalid_type, "title", messages.string },
        .{ violations.invalid_type, "note", messages.string },
        .{ violations.invalid_type, "level", messages.integer },
        .{ violations.invalid_type, "page", messages.integer },
        .{ violations.invalid_type, "tags", messages.array },
        .{ violations.invalid_type, "items[1].displayName", messages.string },
        .{ violations.invalid_type, "items[2]", messages.object },
        .{ violations.invalid_type, "owner", messages.object },
    });

    // null only for an optional; numbers at their edges.
    const Numbers = struct { a: u8 = 0, b: i8 = 0, c: f32 = 0, d: []const u8 = "" };
    for ([_]struct { []const u8, bool }{
        .{ "{\"a\": 255}", true },    .{ "{\"a\": 256}", false },  .{ "{\"a\": -0}", false },
        .{ "{\"b\": -128}", true },   .{ "{\"b\": -129}", false }, .{ "{\"b\": -0}", true },
        .{ "{\"c\": -1.5e3}", true }, .{ "{\"c\": 1e39}", false }, .{ "{\"c\": 0}", true },
        .{ "{\"d\": null}", false },  .{ "{\"a\": null}", false }, .{ "{}", true },
    }) |case| {
        const got = try parseInto(Numbers, arena, case[0], .{});
        testing.expectEqual(case[1], got.value != null) catch |err| {
            std.debug.print("{s}\n", .{case[0]});
            return err;
        };
    }
}

test "json: outside names in" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const User = struct {
        user_name: []const u8,
        pub const field_rules = .{ .user_name = v.rename("userName") };
    };
    const ok = try parseInto(User, arena, "{\"userName\":\"Ann\"}", .{});
    try testing.expectEqualStrings("Ann", (ok.value orelse return error.TestUnexpectedResult).user_name);
    // The Zig name of a renamed field is an unknown key.
    const zig_name = try parseInto(User, arena, "{\"user_name\":\"Ann\"}", .{});
    try testing.expectEqual(null, zig_name.value);
    try expectViolations(&zig_name.sink, &.{
        .{ violations.unknown_field, "user_name", messages.unknown },
        .{ violations.missing_field, "userName", messages.required },
    });
    // An escaped key is the same key.
    const escaped = try parseInto(User, arena, "{\"user\\u004eame\":\"Ann\"}", .{});
    try testing.expect(escaped.value != null);
}

test "json: every violation at once with paths" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Todo = struct { title: []const u8, items: []const Line = &.{} };
    const got = try parseInto(Todo, arena, "{\"titel\":1,\"items\":[{\"displayName\":5}]}", .{});
    try testing.expectEqual(null, got.value);
    try expectViolations(&got.sink, &.{
        .{ violations.unknown_field, "titel", messages.unknown },
        .{ violations.invalid_type, "items[0].displayName", messages.string },
        .{ violations.missing_field, "title", messages.required },
    });
    // Unknown keys: reported once each, at their paths; or ignored where the
    // struct, or the policy, says so.
    const Loose = struct {
        title: []const u8,
        pub const unknown_fields = .ignore;
    };
    const Outer = struct { inner: Loose, items: []const Line = &.{} };
    const unknown = try parseInto(Outer, arena, "{\"inner\":{\"title\":\"a\",\"x\":1},\"items\":[{\"displayName\":\"b\",\"x\":1,\"x\":2}],\"y\":{}}", .{});
    try expectViolations(&unknown.sink, &.{
        .{ violations.unknown_field, "items[0].x", messages.unknown },
        .{ violations.unknown_field, "y", messages.unknown },
    });
    const ignored = try parseInto(Outer, arena, "{\"inner\":{\"title\":\"a\"},\"y\":[[{}]]}", .{ .unknown = .ignore });
    try testing.expectEqualStrings("a", (ignored.value orelse return error.TestUnexpectedResult).inner.title);
    // The root itself.
    const not_object = try parseInto(Todo, arena, "[]", .{});
    try expectViolations(&not_object.sink, &.{.{ violations.invalid_type, "(root)", messages.object }});
    const list = try parseInto([]const Line, arena, "[{\"displayName\":\"a\"},{}]", .{});
    try expectViolations(&list.sink, &.{.{ violations.missing_field, "[1].displayName", messages.required }});
}

test "json: violations stop at v.max_report_violations" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(arena, "[");
    for (0..150) |i| try body.appendSlice(arena, if (i == 0) "\"x\"" else ",\"x\"");
    try body.appendSlice(arena, "]");
    const got = try parseInto([]const u32, arena, body.items, .{});
    try testing.expectEqual(null, got.value);
    try testing.expectEqual(v.max_report_violations, got.sink.items().len);
    try testing.expect(got.sink.truncated);
    try testing.expectEqualStrings("[99]", got.sink.items()[99].field.?);
}

/// `depth` arrays inside each other, inside an object's unknown key when
/// `in_object`.
fn nested(arena: Allocator, depth: usize, in_object: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (in_object) try out.appendSlice(arena, "{\"x\":");
    const arrays = if (in_object) depth - 1 else depth;
    try out.appendNTimes(arena, '[', arrays);
    try out.appendNTimes(arena, ']', arrays);
    if (in_object) try out.append(arena, '}');
    return out.items;
}

test "json: depth 64 passes, 65 is 400" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Loose = struct {
        pub const unknown_fields = .ignore;
    };
    // In an ignored value: skipping counts the depth too.
    _ = try parseInto(Loose, arena, try nested(arena, 64, true), .{});
    try testing.expectError(error.InvalidRequest, parseInto(Loose, arena, try nested(arena, 65, true), .{}));
    // In values that are read.
    const Lists = []const []const []const u8;
    _ = try parseInto(Lists, arena, try nested(arena, 3, false), .{ .max_depth = 3 });
    try testing.expectError(error.InvalidRequest, parseInto(Lists, arena, "[[[[]]]]", .{ .max_depth = 3 }));
    // In a value of the wrong type.
    const Strict = struct { n: u32 = 0 };
    try testing.expectError(error.InvalidRequest, parseInto(Strict, arena, "{\"n\":[[[]]]}", .{ .max_depth = 3 }));
    _ = try parseInto(Strict, arena, "{\"n\":[[]]}", .{ .max_depth = 3 });
}

test "json: the items of lists past max_list_bytes are PayloadTooLarge" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Four u64 take 32 bytes.
    _ = try parseInto([]const u64, arena, "[1,2,3,4]", .{ .max_list_bytes = 32 });
    try testing.expectError(error.PayloadTooLarge, parseInto([]const u64, arena, "[1,2,3,4]", .{ .max_list_bytes = 31 }));
    // Every list of the value counts, nested ones too.
    const Todo = struct { tags: []const []const u8 = &.{} };
    const body = "[{\"tags\":[\"a\",\"b\"]},{\"tags\":[\"c\"]},{}]";
    const all = 3 * @sizeOf(Todo) + 3 * @sizeOf([]const u8);
    const fits = try parseInto([]const Todo, arena, body, .{ .max_list_bytes = all });
    try testing.expectEqual(3, (fits.value orelse return error.TestUnexpectedResult).len);
    try testing.expectError(error.PayloadTooLarge, parseInto([]const Todo, arena, body, .{ .max_list_bytes = all - 1 }));
    // The items after one that failed are not kept, and take nothing.
    const failed = try parseInto([]const u64, arena, "[\"x\",1,2,3,4,5,6,7,8]", .{ .max_list_bytes = @sizeOf(u64) });
    try testing.expectEqual(null, failed.value);
    try expectViolations(&failed.sink, &.{.{ violations.invalid_type, "[0]", messages.integer }});
}

test "json: a repeated key is 400" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Role = struct {
        role: []const u8,
        user_name: []const u8 = "",
        pub const field_rules = .{ .user_name = v.rename("userName") };
    };
    try testing.expectError(error.InvalidRequest, parseInto(Role, arena, "{\"role\":\"user\",\"role\":\"admin\"}", .{}));
    try testing.expectError(error.InvalidRequest, parseInto(Role, arena, "{\"userName\":\"a\",\"user\\u004eame\":\"b\"}", .{}));
    try testing.expectError(error.InvalidRequest, parseInto([]const Role, arena, "[{\"role\":\"a\"},{\"role\":\"a\",\"role\":\"b\"}]", .{}));
    // A value of the wrong type is a key all the same.
    try testing.expectError(error.InvalidRequest, parseInto(Role, arena, "{\"role\":1,\"role\":\"admin\"}", .{}));
    const once = try parseInto(Role, arena, "{\"role\":\"user\",\"userName\":\"a\"}", .{});
    try testing.expectEqualStrings("user", (once.value orelse return error.TestUnexpectedResult).role);
}

test "json: broken JSON and invalid UTF-8 are 400" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Note = struct {
        text: []const u8 = "",
        pub const unknown_fields = .ignore;
    };
    for ([_][]const u8{
        "",                       "{",             "{\"text\":}",          "{\"text\":\"a\",}",
        "{\"text\":\"a\"} {}",    "{'text':'a'}",  "{\"text\":\"a\xff\"}", "{\"x\":\"\xed\xa0\x80\"}",
        "{\"text\":\"\\ud800\"}", "{\"text\":01}", "{\"x\":NaN}",          "\xef\xbb\xbf{}",
        "{\"text\":\"tab\tin\"}", "[1 2]",         "{\"x\":[1,]}",         "{\"x\":\"\\q\"}",
    }) |bytes| {
        if (parseInto(Note, arena, bytes, .{})) |_| {
            std.debug.print("accepted: {s}\n", .{bytes});
            return error.TestUnexpectedResult;
        } else |err| try testing.expectEqual(error.InvalidRequest, err);
    }
    const fine = try parseInto(Note, arena, " {\"text\" : \"caf\xc3\xa9 \\ud83d\\ude00\"} \n", .{});
    try testing.expectEqualStrings("café 😀", (fine.value orelse return error.TestUnexpectedResult).text);
}

test "bind: supported() is false for unions, arrays, std.json.Value, jsonParse types" {
    const Plain = struct { a: u8, b: ?[]const u8 = null, c: []const Line = &.{} };
    try testing.expect(supported(Plain));
    try testing.expect(supported([]const Plain));
    try testing.expect(!supported(struct { a: [2]i32 }));
    try testing.expect(!supported(struct { a: union(enum) { x: u8 } }));
    try testing.expect(!supported(struct { a: std.json.Value }));
    try testing.expect(!supported(struct { a: []u8 }));
    try testing.expect(!supported(struct {
        a: u8,
        pub fn jsonParse(_: Allocator, _: anytype, _: std.json.ParseOptions) !@This() {
            return .{ .a = 0 };
        }
    }));
    try testing.expect(supported(struct { kids: []const @This() = &.{} }));
}

test "bind: usesRename sees renames inside optionals, lists and fields" {
    try testing.expect(usesRename(Line));
    try testing.expect(usesRename(struct { x: ?[]const Line }));
    try testing.expect(!usesRename(struct { a: u8 }));
}

test "bindJson: ok, invalid with every violation, and the errors" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Todo = struct {
        title: []const u8,
        tags: []const []const u8 = &.{},
        pub const field_rules = .{ .title = .{ v.trim, v.notBlank }, .tags = v.each(v.notEmpty) };
    };
    const ok = try bindJson(Todo, arena, "{\"title\":\"  hi \"}", .{});
    try testing.expectEqualStrings("hi", ok.ok.title);
    const bad = try bindJson(Todo, arena, "{\"title\":\"   \",\"tags\":[\"a\",\"\"]}", .{});
    try testing.expectEqual(@as(usize, 2), bad.invalid.items.len);
    try testing.expectEqualStrings("title", bad.invalid.items[0].field.?);
    try testing.expectEqualStrings("tags[1]", bad.invalid.items[1].field.?);
    const wrong = try bindJson(Todo, arena, "{\"title\":1}", .{});
    try testing.expectEqualStrings("http.invalid_type", wrong.invalid.items[0].code);
    try testing.expectError(error.InvalidJsonBody, bindJson(Todo, arena, "nope", .{}));
    try testing.expectError(error.BodyTooBig, bindJson([]const u64, arena, "[1,2,3]", .{ .max_list_bytes = 8 }));
    // A fallback type maps with std.json and still runs rules.
    const Fallback = struct {
        pair: [2]i32,
        name: []const u8,
        pub const field_rules = .{ .name = v.notBlank };
    };
    const fb = try bindJson(Fallback, arena, "{\"pair\":[1,2],\"name\":\"x\"}", .{});
    try testing.expectEqual(@as(i32, 2), fb.ok.pair[1]);
    const fb_bad = try bindJson(Fallback, arena, "{\"pair\":[1,2],\"name\":\" \"}", .{});
    try testing.expectEqualStrings("validation.not_blank", fb_bad.invalid.items[0].code);
}

fn fuzzBind(bytes: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Item = struct {
        n: u8 = 0,
        s: []const u8 = "",
        pub const field_rules = .{ .s = v.maxLength(8) };
    };
    const Doc = struct { items: []const Item = &.{}, flag: ?bool = null, kind: enum { a, b } = .a };
    if (bindJson(Doc, arena, bytes, .{ .max_list_bytes = 4096 })) |res| switch (res) {
        .ok => {},
        .invalid => |vs| try testing.expect(vs.items.len <= v.max_report_violations),
    } else |_| {}
}

test "fuzz: bindJson" {
    try @import("fuzz.zig").bytes(fuzzBind, &.{
        "{}",
        "{\"items\":[{\"n\":1,\"s\":\"abc\"}],\"flag\":true,\"kind\":\"b\"}",
        "{\"items\":[{\"n\":300}]}",
        "[[[[",
    });
}
