// Adapted from vkiryakov/zefir src/http/output/json_out.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! Values out as JSON for `res.json`, keys by the outside names of the validator
//! (`v.nameOf`). A field with `v.rename("userName")` is written as
//! `userName`; a DTO without `field_rules` keeps its Zig names. `res.json`
//! uses `write` only for a type that renames a field (`hasOutsideNames`);
//! every other type keeps the std.json path.
//!
//! | Value                        | JSON                                       |
//! |------------------------------|--------------------------------------------|
//! | a struct                     | an object, fields in declaration order     |
//! | `?T`                         | `null`, or the value                       |
//! | `[]const u8`, `[N]u8`        | a string; bytes that are not UTF-8 are U+FFFD |
//! | a slice, an array, a tuple   | an array                                   |
//! | a tagged union               | an object with one key, the active tag     |
//! | a float                      | a number; NaN and the infinities `null`    |
//! | integers, bool, enums        | as `std.json.Stringify` writes them        |
//!
//! A type with a `jsonStringify` of its own, such as `std.json.Value`,
//! writes itself through `std.json.Stringify`.
const std = @import("std");
const v = @import("validate");
const strings = @import("bind_strings.zig");

const Writer = std.Io.Writer;
const Stringify = std.json.Stringify;

pub const Options = struct {
    /// Leaves out the field of a struct whose optional value is null,
    /// instead of writing it as `null`.
    omit_null_fields: bool = false,
};

/// Whether writing a `T` needs `write`: it, or a type inside it, has a
/// field renamed with `v.rename`. Every other type keeps the std.json path
/// byte for byte.
pub fn hasOutsideNames(comptime T: type) bool {
    return comptime holdsRename(T, &.{});
}

fn holdsRename(comptime T: type, comptime stack: []const type) bool {
    @setEvalBranchQuota(100_000);
    for (stack) |seen| {
        if (seen == T) return false;
    }
    const next = stack ++ [_]type{T};
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            if (std.meta.hasFn(T, "jsonStringify")) return false;
            for (s.field_names, s.field_types) |name, F| {
                if (!s.is_tuple and strings.hasRename(T, name)) return true;
                if (holdsRename(F, next)) return true;
            }
            return false;
        },
        .@"union" => |u| {
            if (std.meta.hasFn(T, "jsonStringify")) return false;
            for (u.field_types) |F| {
                if (holdsRename(F, next)) return true;
            }
            return false;
        },
        .optional => |o| return holdsRename(o.child, next),
        .pointer => |p| return switch (p.size) {
            .one, .slice => holdsRename(p.child, next),
            else => false,
        },
        .array => |a| return holdsRename(a.child, next),
        else => return false,
    }
}

/// Writes `value` as JSON, keys by outside names; call it after
/// `v.transform`.
pub fn write(w: *Writer, value: anytype, options: Options) Writer.Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            if (comptime std.meta.hasFn(T, "jsonStringify")) return Stringify.value(value, .{}, w);
            if (s.is_tuple) {
                try w.writeByte('[');
                inline for (0..s.field_names.len) |i| {
                    if (i > 0) try w.writeByte(',');
                    try write(w, value[i], options);
                }
                return w.writeByte(']');
            }
            try w.writeByte('{');
            var first = true;
            inline for (s.field_names, s.field_types) |name, F| {
                if (comptime F != void) {
                    const field = @field(value, name);
                    if (!omitted(field, options)) {
                        if (!first) try w.writeByte(',');
                        first = false;
                        try Stringify.encodeJsonString(comptime v.nameOf(T, @field(std.meta.FieldEnum(T), name)), .{}, w);
                        try w.writeByte(':');
                        try write(w, field, options);
                    }
                }
            }
            return w.writeByte('}');
        },
        .optional => return if (value) |payload| write(w, payload, options) else w.writeAll("null"),
        .pointer => |p| switch (p.size) {
            .one => return write(w, value.*, options),
            .slice => {
                if (p.child == u8) return writeString(w, value);
                return writeItems(w, value, options);
            },
            .many => if (comptime p.sentinel() != null) return write(w, std.mem.span(value), options),
            .c => {},
        },
        .array => |a| {
            if (a.child == u8) return writeString(w, &value);
            return writeItems(w, &value, options);
        },
        .float => if (!std.math.isFinite(value)) return w.writeAll("null"),
        .@"union" => |u| {
            if (comptime std.meta.hasFn(T, "jsonStringify") or u.tag_type == null) return Stringify.value(value, .{}, w);
            try w.writeByte('{');
            switch (value) {
                inline else => |payload, tag| {
                    try Stringify.encodeJsonString(@tagName(tag), .{}, w);
                    try w.writeByte(':');
                    if (@TypeOf(payload) == void) try w.writeAll("{}") else try write(w, payload, options);
                },
            }
            return w.writeByte('}');
        },
        else => {},
    }
    // The leaves: integers, finite floats, bool, enums, errors, null.
    return Stringify.value(value, .{}, w);
}

fn writeItems(w: *Writer, items: anytype, options: Options) Writer.Error!void {
    try w.writeByte('[');
    for (items, 0..) |item, i| {
        if (i > 0) try w.writeByte(',');
        try write(w, item, options);
    }
    try w.writeByte(']');
}

fn omitted(field: anytype, options: Options) bool {
    if (@typeInfo(@TypeOf(field)) != .optional) return false;
    return options.omit_null_fields and field == null;
}

/// A JSON string of `bytes`; a byte that does not begin a valid UTF-8
/// sequence is U+FFFD, so that the string stays a string.
fn writeString(w: *Writer, bytes: []const u8) Writer.Error!void {
    if (std.unicode.utf8ValidateSlice(bytes)) return Stringify.encodeJsonString(bytes, .{}, w);
    try w.writeByte('"');
    var start: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const len: usize = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 0;
        if (len > 0 and i + len <= bytes.len) {
            if (std.unicode.utf8Decode(bytes[i..][0..len])) |_| {
                i += len;
                continue;
            } else |_| {}
        }
        try Stringify.encodeJsonStringChars(bytes[start..i], .{}, w);
        try w.writeAll("\\ufffd");
        i += 1;
        start = i;
    }
    try Stringify.encodeJsonStringChars(bytes[start..], .{}, w);
    try w.writeByte('"');
}

const testing = std.testing;

const Priority = enum { low, normal, high };

const Line = struct {
    display_name: []const u8,
    done: bool = false,
    pub const field_rules = .{ .display_name = v.rename("displayName") };
};

const TodoResponse = struct {
    id: u64,
    user_name: []const u8,
    priority: Priority,
    note: ?[]const u8,
    ratio: f64,
    lines: []const Line,
    tags: [2][]const u8,
    owner: ?Line,

    pub const field_rules = .{
        .user_name = v.rename("userName"),
    };
};

fn expectJson(expected: []const u8, value: anytype, options: Options) !void {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, value, options);
    try testing.expectEqualStrings(expected, out.written());
}

test "json out: renamed fields by outside names, nested and in slices" {
    const value: TodoResponse = .{
        .id = 7,
        .user_name = "Ann",
        .priority = .high,
        .note = "call back",
        .ratio = 2.5,
        .lines = &.{ .{ .display_name = "milk" }, .{ .display_name = "bread", .done = true } },
        .tags = .{ "home", "shop" },
        .owner = null,
    };
    try expectJson(
        \\{"id":7,"userName":"Ann","priority":"high","note":"call back","ratio":2.5,"lines":[{"displayName":"milk","done":false},{"displayName":"bread","done":true}],"tags":["home","shop"],"owner":null}
    , value, .{});
    try expectJson("{\"displayName\":\"x\"}", struct {
        display_name: []const u8,
        missing: ?u8 = null,
        pub const field_rules = .{ .display_name = v.rename("displayName") };
    }{ .display_name = "x" }, .{ .omit_null_fields = true });
}

test "json out: hasOutsideNames" {
    try testing.expect(hasOutsideNames(TodoResponse));
    try testing.expect(hasOutsideNames([]const Line));
    try testing.expect(hasOutsideNames(?Line));
    try testing.expect(!hasOutsideNames(struct { a: u8, b: []const u8 }));
    try testing.expect(!hasOutsideNames(struct {
        a: u8,
        pub const field_rules = .{ .a = v.min(1) };
    }));
    const Tree = struct { kids: []const @This() = &.{} };
    try testing.expect(!hasOutsideNames(Tree));
}

test "json out: strings, numbers, unions and types that write themselves" {
    try expectJson("\"a\\ufffdb\\ufffd\\ufffdc\\\"\\n\\u0001é\"", @as([]const u8, "a\xffb\xed\xa0c\"\n\x01é"), .{});
    try expectJson("[null,null,null,1.5,-3]", .{ std.math.nan(f64), std.math.inf(f32), -std.math.inf(f64), @as(f32, 1.5), @as(i8, -3) }, .{});
    const Shape = union(enum) {
        circle: struct {
            radius_mm: u32,
            pub const field_rules = .{ .radius_mm = v.rename("radiusMm") };
        },
        none,
    };
    try expectJson("[{\"circle\":{\"radiusMm\":3}},{\"none\":{}}]", [_]Shape{ .{ .circle = .{ .radius_mm = 3 } }, .none }, .{});
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"a\":[1,true,null]}", .{});
    defer parsed.deinit();
    try expectJson("{\"a\":[1,true,null]}", parsed.value, .{});
    try expectJson("\"ab\"", @as([2]u8, .{ 'a', 'b' }), .{});
}
