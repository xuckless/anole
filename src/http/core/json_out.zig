// Adapted from vkiryakov/zefir src/http/output/json_out.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! Values out as JSON for `res.json`, keys by the outside names of the validator
//! (`v.nameOf`). A field with `v.rename("userName")` is written as
//! `userName`; a DTO without `field_rules` keeps its Zig names. `res.json`
//! uses `write` for every type with std.json's default options, and for a
//! type that renames a field (`hasOutsideNames`) with any options. For a
//! type without renames the bytes are std.json's, but for strings that are
//! not UTF-8 (std.json writes them as arrays of numbers). Keys are encoded
//! at compile time, and a string is escaped and checked in one pass.
//! U+FFFD is for the strings `write` writes itself: a type with its own
//! `jsonStringify` and a `@Vector` of bytes keep std.json's arrays.
//!
//! | Value                        | JSON                                       |
//! |------------------------------|--------------------------------------------|
//! | a struct                     | an object, fields in declaration order     |
//! | `?T`                         | `null`, or the value                       |
//! | `[]const u8`, `[N]u8`        | a string; bytes that are not UTF-8 are U+FFFD |
//! | a slice, an array, a tuple   | an array                                   |
//! | a tagged union               | an object with one key, the active tag     |
//! | a float                      | a number; NaN and the infinities `null` (`non_finite_null`) |
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
    /// Leaves out the field of a struct (or element of a tuple) whose
    /// optional value is null, instead of writing it as `null`.
    omit_null_fields: bool = false,
    /// Writes NaN and the infinities as `null`; off, they are left to
    /// std.json (`"nan"`, `inf`, `-inf`).
    non_finite_null: bool = true,

    fn stringify(options: Options) Stringify.Options {
        return .{ .emit_null_optional_fields = !options.omit_null_fields };
    }
};

/// Whether `T`, or a type inside it, has a field renamed with `v.rename`.
/// Such a type goes through `write` with any options (those json_out does
/// not have are ignored) and writes NaN and the infinities as `null`.
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
            if (comptime std.meta.hasFn(T, "jsonStringify")) return Stringify.value(value, options.stringify(), w);
            // A tuple leaves out what std.json leaves out of it: `void`
            // elements, and null ones with `omit_null_fields`.
            try w.writeByte(if (s.is_tuple) '[' else '{');
            var first = true;
            inline for (s.field_names, s.field_types) |name, F| {
                if (comptime F != void) {
                    const field = @field(value, name);
                    if (!omitted(field, options)) {
                        if (!first) try w.writeByte(',');
                        first = false;
                        if (!s.is_tuple) try w.writeAll(comptime keyOf(T, name));
                        try write(w, field, options);
                    }
                }
            }
            return w.writeByte(if (s.is_tuple) ']' else '}');
        },
        .optional => return if (value) |payload| write(w, payload, options) else w.writeAll("null"),
        .pointer => |p| switch (p.size) {
            // A pointer to an array is a slice, as std.json takes it: no
            // copy of the array onto the stack.
            .one => if (comptime @typeInfo(p.child) == .array)
                return write(w, @as([]const std.meta.Elem(p.child), value), options)
            else
                return write(w, value.*, options),
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
        .float => if (options.non_finite_null and !std.math.isFinite(value)) return w.writeAll("null"),
        .@"union" => |u| {
            if (comptime std.meta.hasFn(T, "jsonStringify") or u.tag_type == null) return Stringify.value(value, options.stringify(), w);
            try w.writeByte('{');
            switch (value) {
                inline else => |payload, tag| {
                    try w.writeAll(comptime keyLiteral(@tagName(tag)));
                    if (@TypeOf(payload) == void) try w.writeAll("{}") else try write(w, payload, options);
                },
            }
            return w.writeByte('}');
        },
        else => {},
    }
    // The leaves: integers, floats, bool, enums, errors, null.
    return Stringify.value(value, options.stringify(), w);
}

/// `"name":` for the field `name` of the struct `T`, by its outside name.
fn keyOf(comptime T: type, comptime name: []const u8) []const u8 {
    if (!@hasDecl(T, "field_rules")) return keyLiteral(name);
    return keyLiteral(v.nameOf(T, @field(std.meta.FieldEnum(T), name)));
}

/// `"name":`, escaped as std.json escapes a key, built at compile time.
fn keyLiteral(comptime name: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(20 * name.len + 1000);
        var buf: [name.len * 6 + 3]u8 = undefined;
        var w: Writer = .fixed(&buf);
        Stringify.encodeJsonString(name, .{}, &w) catch unreachable;
        w.writeByte(':') catch unreachable;
        const out = buf[0..w.end].*;
        return &out;
    }
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

/// The escape of each ASCII byte that needs one, as std.json writes it
/// (lowercase hex); "" for the rest.
const escapes: [128][]const u8 = blk: {
    var table: [128][]const u8 = @splat("");
    for (0..0x20) |c| table[c] = std.fmt.comptimePrint("\\u{x:0>4}", .{c});
    table[0x08] = "\\b";
    table[0x0C] = "\\f";
    table['\n'] = "\\n";
    table['\r'] = "\\r";
    table['\t'] = "\\t";
    table['"'] = "\\\"";
    table['\\'] = "\\\\";
    break :blk table;
};

/// A JSON string of `bytes`; a byte that does not begin a valid UTF-8
/// sequence is U+FFFD, so that the string stays a string. One pass: runs
/// that go out as they are are skipped 16 bytes at a time. At the first
/// byte past ASCII the rest is checked once (std's vectorised check); when
/// it is UTF-8, as it nearly always is, only escapes stop the scan after
/// that. Otherwise each sequence is checked on its own from there.
fn writeString(w: *Writer, bytes: []const u8) Writer.Error!void {
    const V = @Vector(16, u8);
    try w.writeByte('"');
    var start: usize = 0;
    var i: usize = 0;
    // The rest of `bytes` is known to be UTF-8; or it was checked once
    // and is not.
    var rest_valid = false;
    var rest_invalid = false;
    while (true) {
        while (i + 16 <= bytes.len) : (i += 16) {
            const chunk: V = bytes[i..][0..16].*;
            var stop = (chunk < @as(V, @splat(0x20))) | (chunk == @as(V, @splat('"'))) | (chunk == @as(V, @splat('\\')));
            if (!rest_valid) stop |= chunk >= @as(V, @splat(0x80));
            if (std.simd.firstTrue(stop)) |at| {
                i += at;
                break;
            }
        } else while (i < bytes.len) : (i += 1) {
            const b = bytes[i];
            if (b < 0x20 or b == '"' or b == '\\' or (b >= 0x80 and !rest_valid)) break;
        }
        if (i == bytes.len) break;
        const c = bytes[i];
        if (c < 0x80) {
            try w.writeAll(bytes[start..i]);
            try w.writeAll(escapes[c]);
            i += 1;
            start = i;
            continue;
        }
        if (!rest_invalid) {
            if (std.unicode.utf8ValidateSlice(bytes[i..])) {
                rest_valid = true;
                continue;
            }
            // Checked once only, so that a bad byte at the end of a long
            // string costs one more pass, not one per sequence before it.
            rest_invalid = true;
        }
        const len: usize = std.unicode.utf8ByteSequenceLength(c) catch 0;
        if (len > 0 and i + len <= bytes.len) {
            if (std.unicode.utf8Decode(bytes[i..][0..len])) |_| {
                i += len;
                continue;
            } else |_| {}
        }
        try w.writeAll(bytes[start..i]);
        try w.writeAll("\\ufffd");
        i += 1;
        start = i;
    }
    try w.writeAll(bytes[start..]);
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

test "json out: only a type with a rename somewhere inside takes the renaming writer (recursive types end)" {
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

/// The two-pass writer `writeString` replaced, kept as the reference its
/// bytes are checked against.
fn writeStringTwoPass(w: *Writer, bytes: []const u8) Writer.Error!void {
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

fn expectSameString(one: *Writer.Allocating, two: *Writer.Allocating, bytes: []const u8) !void {
    one.clearRetainingCapacity();
    two.clearRetainingCapacity();
    try writeString(&one.writer, bytes);
    try writeStringTwoPass(&two.writer, bytes);
    try testing.expectEqualStrings(two.written(), one.written());
}

test "json out: the one-pass string writer gives the two-pass writer's bytes" {
    var one: Writer.Allocating = .init(testing.allocator);
    defer one.deinit();
    var two: Writer.Allocating = .init(testing.allocator);
    defer two.deinit();
    var buf: [600]u8 = undefined;
    // Each ASCII byte alone, after a 16-byte run, and as a whole string of it.
    for (0..0x80) |c| {
        const b: u8 = @intCast(c);
        try expectSameString(&one, &two, &.{b});
        @memset(buf[0..40], 'a');
        buf[17] = b;
        try expectSameString(&one, &two, buf[0..40]);
        @memset(buf[0..40], b);
        try expectSameString(&one, &two, buf[0..40]);
    }
    try expectSameString(&one, &two, "");
    // A 4-byte sequence across the 16-byte boundary, and a bad byte at
    // 15, 16 and 17, before and after other non-ASCII text.
    try expectSameString(&one, &two, "aaaaaaaaaaaaaa\u{1F600}bbbbbbbbbbbbbbbbbbb");
    for ([_]usize{ 15, 16, 17 }) |at| {
        @memset(buf[0..48], 'a');
        buf[at] = 0xff;
        try expectSameString(&one, &two, buf[0..48]);
        @memcpy(buf[30..32], "é");
        try expectSameString(&one, &two, buf[0..48]);
        @memcpy(buf[2..4], "é");
        try expectSameString(&one, &two, buf[0..48]);
    }
    // Random strings: half from any byte, half from the bytes that matter
    // (escapes, leads, continuations, an overlong, a surrogate, past
    // U+10FFFF); lengths across the vector and tail paths.
    const alphabet = "a\"\\\x01\n\x7f\x80\xbf\xc0\xc2\xc3\xa9\xe2\x82\xac\xed\xa0\xf0\x9f\x98\x80\xf4\x90\xff";
    var prng: std.Random.DefaultPrng = .init(0x6a736f6e);
    const random = prng.random();
    for (0..10_000) |n| {
        const len = random.uintLessThan(usize, buf.len + 1);
        for (buf[0..len]) |*b| b.* = if (n % 2 == 0) random.int(u8) else alphabet[random.uintLessThan(usize, alphabet.len)];
        try expectSameString(&one, &two, buf[0..len]);
    }
}

test "json out: a tuple leaves out void elements, and null ones on request" {
    const t = .{ @as(u8, 1), {}, @as(?u8, null), "x" };
    try expectJson("[1,null,\"x\"]", t, .{});
    try expectJson("[1,\"x\"]", t, .{ .omit_null_fields = true });
}

/// Larger than a thread's stack: a copy of it there would overflow.
// SAFETY: the test fills it before writing it.
var big_array: [16 << 20]u8 = undefined;

test "json out: a pointer to an array is written as a slice, not copied onto the stack" {
    @memset(&big_array, 'a');
    var counter: Writer.Discarding = .init(&.{});
    try write(&counter.writer, .{ .blob = &big_array }, .{});
    try testing.expectEqual(@as(u64, big_array.len + "{\"blob\":\"\"}".len), counter.fullCount());
    const const_ptr: *const [3:0]u8 = "a\xffb";
    try expectJson("\"a\\ufffdb\"", const_ptr, .{});
}
