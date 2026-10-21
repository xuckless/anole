//! Rows and parameters as `anole.db`'s caches handle them: a deep copy of
//! a value into other memory (a result into each caller's arena, into a
//! cache entry and back out), the bytes such a copy needs, and parameters
//! encoded as bytes for a cache key.
//!
//! What can be copied: numbers, `bool`, enums, optionals, arrays, structs,
//! tagged unions, and slices of those (strings included). Not pointers to
//! a single value, many-item pointers or opaque types (an allocator, a
//! `std.json.Value`'s maps): `copyable` is false for a type that has one,
//! and a call with such a row type takes the plain path.
const std = @import("std");

const Allocator = std.mem.Allocator;

/// Whether `deepCopy` can copy a `T`.
pub fn copyable(comptime T: type) bool {
    return comptime copyableDepth(T, 0);
}

fn copyableDepth(comptime T: type, comptime depth: u32) bool {
    // A type that holds itself (through a slice) is not followed far.
    if (depth > 12) return false;
    return switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum", .void, .null, .comptime_int, .comptime_float, .enum_literal => true,
        .optional => |o| copyableDepth(o.child, depth + 1),
        .array => |a| copyableDepth(a.child, depth + 1),
        .@"struct" => |s| {
            for (s.field_types) |F| if (!copyableDepth(F, depth + 1)) return false;
            return true;
        },
        .@"union" => |u| {
            if (u.tag_type == null) return false;
            for (u.field_types) |F| if (!copyableDepth(F, depth + 1)) return false;
            return true;
        },
        .pointer => |p| switch (p.size) {
            .slice => copyableDepth(p.child, depth + 1),
            // A string literal (`*const [N:0]u8`), say.
            .one => @typeInfo(p.child) == .array and copyableDepth(p.child, depth + 1),
            else => false,
        },
        else => false,
    };
}

/// Whether a `T` holds memory of its own (a slice), so copying it takes
/// more than its bytes.
fn deep(comptime T: type) bool {
    return comptime deepDepth(T, 0);
}

fn deepDepth(comptime T: type, comptime depth: u32) bool {
    if (depth > 12) return true;
    return switch (@typeInfo(T)) {
        .optional => |o| deepDepth(o.child, depth + 1),
        .array => |a| deepDepth(a.child, depth + 1),
        .@"struct" => |s| {
            for (s.field_types) |F| if (deepDepth(F, depth + 1)) return true;
            return false;
        },
        .@"union" => |u| {
            for (u.field_types) |F| if (deepDepth(F, depth + 1)) return true;
            return false;
        },
        .pointer => true,
        else => false,
    };
}

/// A copy of `value` whose memory (strings, slices) comes from `a`.
pub fn deepCopy(comptime T: type, value: T, a: Allocator) Allocator.Error!T {
    if (comptime !deep(T)) return value;
    switch (@typeInfo(T)) {
        .optional => |o| return if (value) |v| try deepCopy(o.child, v, a) else null,
        .array => |info| {
            var out: T = undefined;
            for (value, 0..) |v, i| out[i] = try deepCopy(info.child, v, a);
            return out;
        },
        .@"struct" => |s| {
            var out: T = value;
            inline for (s.field_names, s.field_types, 0..) |name, F, i| {
                if (comptime s.field_attrs[i].@"comptime") continue;
                @field(out, name) = try deepCopy(F, @field(value, name), a);
            }
            return out;
        },
        .@"union" => switch (value) {
            inline else => |v, tag| {
                const F = @FieldType(T, @tagName(tag));
                return @unionInit(T, @tagName(tag), try deepCopy(F, v, a));
            },
        },
        .pointer => |p| switch (p.size) {
            .slice => {
                const out = if (p.sentinel()) |s| try a.allocSentinel(p.child, value.len, s) else try a.alloc(p.child, value.len);
                if (comptime deep(p.child)) {
                    for (value, 0..) |v, i| out[i] = try deepCopy(p.child, v, a);
                } else {
                    @memcpy(out, value);
                }
                return out;
            },
            .one => {
                const out = try a.create(p.child);
                out.* = try deepCopy(p.child, value.*, a);
                return out;
            },
            else => comptime unreachable,
        },
        else => comptime unreachable,
    }
}

/// At least the bytes `deepCopy(T, value, a)` takes from `a` when `a`
/// hands out memory back to back (a `FixedBufferAllocator`): each slice's
/// length, plus room to align it.
pub fn deepSize(comptime T: type, value: T) usize {
    if (comptime !deep(T)) return 0;
    switch (@typeInfo(T)) {
        .optional => |o| return if (value) |v| deepSize(o.child, v) else 0,
        .array => |info| {
            var n: usize = 0;
            for (value) |v| n += deepSize(info.child, v);
            return n;
        },
        .@"struct" => |s| {
            var n: usize = 0;
            inline for (s.field_names, s.field_types, 0..) |name, F, i| {
                if (comptime s.field_attrs[i].@"comptime") continue;
                n += deepSize(F, @field(value, name));
            }
            return n;
        },
        .@"union" => switch (value) {
            inline else => |v, tag| return deepSize(@FieldType(T, @tagName(tag)), v),
        },
        .pointer => |p| switch (p.size) {
            .slice => {
                var n = (value.len + @intFromBool(p.sentinel() != null)) * @sizeOf(p.child) + @alignOf(p.child);
                if (comptime deep(p.child)) for (value) |v| {
                    n += deepSize(p.child, v);
                };
                return n;
            },
            .one => return @sizeOf(p.child) + @alignOf(p.child) + deepSize(p.child, value.*),
            else => comptime unreachable,
        },
        else => comptime unreachable,
    }
}

/// Whether `encode` can write a `T`: what `copyable` takes, with numbers
/// and strings compared by value.
pub fn encodable(comptime T: type) bool {
    return copyable(T);
}

/// `value` as bytes that two values share only when a database binds them
/// alike: integers of any width as one integer, floats as `f64`, strings
/// and enum labels by their bytes, each tagged with its kind and every
/// length written out.
pub fn encode(w: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .bool => try w.writeAll(if (value) "b1" else "b0"),
        .int, .comptime_int => {
            try w.writeByte('i');
            try w.writeInt(i128, @intCast(value), .little);
        },
        .float, .comptime_float => {
            try w.writeByte('f');
            try w.writeInt(u64, @bitCast(@as(f64, @floatCast(value))), .little);
        },
        .@"enum" => try str(w, 'e', @tagName(value)),
        .enum_literal => try str(w, 'e', @tagName(value)),
        .void => {},
        .null => try w.writeByte('n'),
        .optional => if (value) |v| try encode(w, v) else try w.writeByte('n'),
        .array => |a| if (a.child == u8) try str(w, 's', &value) else {
            try w.writeByte('a');
            try w.writeInt(u64, value.len, .little);
            for (value) |v| try encode(w, v);
        },
        .@"struct" => |s| {
            try w.writeByte('r');
            try w.writeInt(u32, s.field_names.len, .little);
            inline for (s.field_names) |name| {
                // By name, unless a tuple: a document filter `.{ .age = 18 }`
                // is not `.{ .score = 18 }`.
                if (!s.is_tuple) try str(w, 'k', name);
                try encode(w, @field(value, name));
            }
        },
        .@"union" => switch (value) {
            inline else => |v, tag| {
                try str(w, 'u', @tagName(tag));
                try encode(w, v);
            },
        },
        .pointer => |p| switch (p.size) {
            .slice => if (p.child == u8) try str(w, 's', value) else {
                try w.writeByte('a');
                try w.writeInt(u64, value.len, .little);
                for (value) |v| try encode(w, v);
            },
            .one => try encode(w, value.*),
            else => @compileError("anole.db: cannot encode " ++ @typeName(T)),
        },
        else => @compileError("anole.db: cannot encode " ++ @typeName(T)),
    }
}

fn str(w: *std.Io.Writer, tag: u8, bytes: []const u8) !void {
    try w.writeByte(tag);
    try w.writeInt(u64, bytes.len, .little);
    try w.writeAll(bytes);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

const Kind = enum { note, link };
const Meta = struct { lang: []const u8, words: u32 = 0 };
const Row = struct {
    id: i64,
    body: []const u8,
    tags: []const []const u8,
    meta: ?Meta,
    kind: Kind,
    name: [:0]const u8,
    fixed: [2]u16,
    either: union(enum) { n: i32, s: []const u8 },
};

test "deepCopy: every slice in new memory, and deepSize enough for it" {
    var src_tags = [_][]const u8{ "zig", "db" };
    var body = "hello".*;
    const row: Row = .{
        .id = 7,
        .body = &body,
        .tags = &src_tags,
        .meta = .{ .lang = "en", .words = 3 },
        .kind = .link,
        .name = "row",
        .fixed = .{ 1, 2 },
        .either = .{ .s = "text" },
    };
    const rows = [_]Row{ row, row };
    const all: []const Row = &rows;
    try testing.expect(copyable([]const Row));

    // Into a buffer of exactly `deepSize` (plus the outer value), back to back.
    const size = deepSize([]const Row, all);
    const buf = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(buf);
    var fba: std.heap.FixedBufferAllocator = .init(buf);
    const copy = try deepCopy([]const Row, all, fba.allocator());
    // The source changes; the copy does not.
    body[0] = 'j';
    src_tags[0] = "other";
    try testing.expectEqual(@as(usize, 2), copy.len);
    try testing.expectEqualStrings("hello", copy[1].body);
    try testing.expectEqualStrings("zig", copy[0].tags[0]);
    try testing.expectEqualStrings("en", copy[0].meta.?.lang);
    try testing.expectEqualStrings("row", copy[0].name);
    try testing.expectEqual(@as(u8, 0), copy[0].name.ptr[3]);
    try testing.expectEqualStrings("text", copy[0].either.s);
    try testing.expectEqual(Kind.link, copy[1].kind);
    try testing.expect(@intFromPtr(copy.ptr) >= @intFromPtr(buf.ptr) and @intFromPtr(copy.ptr) < @intFromPtr(buf.ptr) + buf.len);

    // Types with pointers of other kinds are not copyable.
    try testing.expect(!copyable(std.json.Value));
    try testing.expect(!copyable(struct { p: *u8 }));
    try testing.expect(!copyable(std.mem.Allocator));
    try testing.expect(copyable(@TypeOf(.{ "literal", @as(u32, 3), null })));
}

fn encoded(buf: []u8, value: anytype) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    encode(&w, value) catch unreachable;
    return w.buffered();
}

test "encode: equal when bound alike, different otherwise" {
    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;
    // An integer is an integer, whatever its width or comptime-ness.
    try testing.expectEqualStrings(encoded(&b1, .{@as(u8, 5)}), encoded(&b2, .{5}));
    try testing.expectEqualStrings(encoded(&b1, .{@as(i64, -1)}), encoded(&b2, .{@as(i16, -1)}));
    // A literal and a slice of the same bytes.
    const s: []const u8 = "abc";
    try testing.expectEqualStrings(encoded(&b1, .{"abc"}), encoded(&b2, .{s}));
    // But a string is not a number, and lengths keep fields apart.
    try testing.expect(!std.mem.eql(u8, encoded(&b1, .{"5"}), encoded(&b2, .{5})));
    try testing.expect(!std.mem.eql(u8, encoded(&b1, .{ "ab", "c" }), encoded(&b2, .{ "a", "bc" })));
    try testing.expect(!std.mem.eql(u8, encoded(&b1, .{@as(?i32, null)}), encoded(&b2, .{0})));
    try testing.expectEqualStrings(encoded(&b1, .{Kind.note}), encoded(&b2, .{.note}));
    // Documents differ by their field names.
    try testing.expect(!std.mem.eql(u8, encoded(&b1, .{.{ .age = 18 }}), encoded(&b2, .{.{ .score = 18 }})));
    try testing.expectEqualStrings(encoded(&b1, .{.{ .age = 18 }}), encoded(&b2, .{.{ .age = @as(u8, 18) }}));
}
