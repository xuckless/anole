// Adapted from vkiryakov/zefir src/openapi/example.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.

//! Values in the document as `std.json` writes them (what `res.json` sends and
//! `req.bind` reads): the examples of the declarations and the defaults of
//! fields. `value` writes fields in the order of their declaration, a union
//! as an object of one key, a float that is not finite as `null`. It runs no
//! transforms: an example shows what the type holds.
const std = @import("std");
const json = @import("json.zig");
const declarations = @import("declarations.zig");
const validate = @import("validate");

/// How a value goes: in a request, in a response, or in a response body
/// whose null fields are left out.
pub const Way = enum {
    /// Read: without the comptime fields of a struct, which the server's
    /// reader does not take.
    input,
    /// Written: every field, a comptime one as its constant.
    output,
    /// Written inside a body whose null fields are left out.
    problem,
};

/// The JSON of `x`, a value of `T`, as it goes `way`.
/// `where` names the value in a message.
pub fn value(comptime T: type, comptime x: T, comptime way: Way, comptime where: []const u8) json.Node {
    comptime {
        @setEvalBranchQuota(1_000_000);
        switch (@typeInfo(T)) {
            .bool => return .{ .boolean = x },
            .int, .comptime_int => return .{ .raw = std.fmt.comptimePrint("{d}", .{x}) },
            .float => {
                if (!std.math.isFinite(x)) return .null;
                if (@as(f64, @floatCast(x)) != x) @compileError("anole.openapi: " ++ where ++ ": " ++ @typeName(T) ++ " " ++ std.fmt.comptimePrint("{}", .{x}) ++ " has no JSON number");
                return .{ .raw = std.fmt.comptimePrint("{}", .{@as(f64, @floatCast(x))}) };
            },
            .optional => |o| return if (x) |payload| value(o.child, payload, way, where) else .null,
            .@"enum" => |e| {
                if (declarations.writesItself(T)) writesItself(T, where);
                for (e.field_names) |name| {
                    if (x == @field(T, name)) return .{ .string = name };
                }
                return .{ .raw = std.fmt.comptimePrint("{d}", .{@backingInt(x)}) };
            },
            .pointer => |p| switch (p.size) {
                .one => return value(p.child, x.*, way, where),
                .slice => return if (p.child == u8) string(x, where) else items(p.child, x, way, where),
                .many => if (p.sentinel() != null) return value([]const p.child, std.mem.span(x), way, where),
                .c => {},
            },
            .array => |a| return if (a.child == u8) string(&x, where) else items(a.child, &x, way, where),
            .@"struct" => |s| {
                if (declarations.writesItself(T)) writesItself(T, where);
                if (s.is_tuple) {
                    var out: [s.field_types.len]json.Node = undefined;
                    for (s.field_types, &out, 0..) |F, *item, i| item.* = value(F, x[i], way, where);
                    const final = out;
                    return .{ .array = &final };
                }
                var members: []const json.Member = &.{};
                for (s.field_names, s.field_types, s.field_attrs) |name, F, attrs| {
                    if (F == void or (way == .input and attrs.@"comptime")) continue;
                    const field = @field(x, name);
                    if (way == .problem and @typeInfo(F) == .optional and field == null) continue;
                    const key = outsideName(T, name);
                    members = members ++ [_]json.Member{.{ .key = key, .value = value(F, field, way, where ++ "." ++ key) }};
                }
                return .{ .object = members };
            },
            .@"union" => |u| if (u.tag_type != null) {
                if (declarations.writesItself(T)) writesItself(T, where);
                const tag = @tagName(std.meta.activeTag(x));
                const P = @FieldType(T, tag);
                const payload: json.Node = if (P == void) .{ .object = &.{} } else value(P, @field(x, tag), way, where ++ "." ++ tag);
                return .{ .object = &.{.{ .key = tag, .value = payload }} };
            },
            else => {},
        }
        @compileError("anole.openapi: " ++ where ++ ": a value of " ++ @typeName(T) ++ " has no JSON");
    }
}

/// The outside name of the field `field` of the struct `T`: the field's own
/// name. Part 2 of the tooling lane maps `anole.validate.nameOf` here once the
/// validator exists, so `v.rename` shows in examples as `req.bind` reads it.
pub fn outsideName(comptime T: type, comptime field: []const u8) []const u8 {
    if (@typeInfo(T) != .@"struct") return field;
    return validate.nameOf(T, @field(std.meta.FieldEnum(T), field));
}

fn items(comptime Item: type, comptime list: []const Item, comptime way: Way, comptime where: []const u8) json.Node {
    var out: [list.len]json.Node = undefined;
    for (list, &out, 0..) |item, *node, i| node.* = value(Item, item, way, std.fmt.comptimePrint("{s}[{d}]", .{ where, i }));
    const final = out;
    return .{ .array = &final };
}

/// A string of the document; the server would write bytes that are not
/// UTF-8 as U+FFFD, which an example has no reason to hold.
fn string(comptime bytes: []const u8, comptime where: []const u8) json.Node {
    if (!std.unicode.utf8ValidateSlice(bytes)) @compileError("anole.openapi: " ++ where ++ ": the string is not valid UTF-8");
    return .{ .string = bytes };
}

fn writesItself(comptime T: type, comptime where: []const u8) noreturn {
    @compileError("anole.openapi: " ++ where ++ ": " ++ @typeName(T) ++ " writes itself with jsonStringify, so its JSON is known only when the program runs; leave this value out of the document");
}

const testing = std.testing;

/// `node` as compact JSON, as `res.json` writes it: no whitespace.
fn compact(node: json.Node, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (node) {
        .object => |members| {
            try w.writeByte('{');
            for (members, 0..) |m, i| {
                if (i > 0) try w.writeByte(',');
                try std.json.Stringify.encodeJsonString(m.key, .{}, w);
                try w.writeByte(':');
                try compact(m.value, w);
            }
            try w.writeByte('}');
        },
        .array => |list| {
            try w.writeByte('[');
            for (list, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try compact(item, w);
            }
            try w.writeByte(']');
        },
        .string => |s| try std.json.Stringify.encodeJsonString(s, .{}, w),
        .raw => |text| try w.writeAll(text),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .null => try w.writeAll("null"),
        .ref => try w.writeAll("null"),
    }
}

const Kind = enum { a, b };
const Sample = struct { id: u64, name: []const u8, kind: Kind = .b, tags: []const []const u8 = &.{}, note: ?[]const u8 = null };
const Shape = union(enum) { circle: u32, none };

test "value: the bytes std.json writes" {
    const item: Sample = .{ .id = 7, .name = "a\"b", .tags = &.{ "x", "y" } };
    const node = comptime value(Sample, item, .output, "Sample");
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try compact(node, &out.writer);
    var expected: std.Io.Writer.Allocating = .init(testing.allocator);
    defer expected.deinit();
    try std.json.Stringify.value(item, .{}, &expected.writer);
    try testing.expectEqualStrings(expected.written(), out.written());
}

test "value: unions, optionals and non-finite floats" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try compact(comptime value(Shape, .{ .circle = 3 }, .output, "S"), &out.writer);
    try compact(comptime value(Shape, .none, .output, "S"), &out.writer);
    try compact(comptime value(?u8, null, .output, "o"), &out.writer);
    try compact(comptime value(f64, std.math.inf(f64), .output, "f"), &out.writer);
    try testing.expectEqualStrings("{\"circle\":3}{\"none\":{}}nullnull", out.written());
}
