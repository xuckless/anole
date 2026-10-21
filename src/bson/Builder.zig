//! Writes BSON into a growing buffer. Documents open with `begin` (or
//! `beginDocument`/`beginArray` inside one) and close with `end`, which
//! writes the length back; inside an array the element names are the
//! indexes, whatever name the caller passes.
//!
//!     var b: bson.Builder = .init(gpa);
//!     defer b.deinit();
//!     try b.begin();
//!     try b.append("find", .{ .string = "users" });
//!     try b.appendAny("filter", .{ .age = .{ .@"$gte" = 18 } });
//!     try b.end();
//!     const doc = b.bytes();
//!
//! Several documents may follow one another in the buffer (an OP_MSG body
//! and its document sequences); bytes written before `begin` stay as they are.
const std = @import("std");
const document = @import("document.zig");
const Value = document.Value;
const Type = document.Type;
const Document = document.Document;

const Builder = @This();

gpa: std.mem.Allocator,
buf: std.ArrayList(u8) = .empty,
frames: std.ArrayList(Frame) = .empty,

const Frame = struct {
    start: usize,
    /// The next index inside an array; null inside a document.
    index: ?u32,
};

pub const Error = error{
    OutOfMemory,
    /// A key with a 0x00 byte (it would end the key early) or invalid UTF-8.
    InvalidKey,
    /// A regex pattern or options with a 0x00 byte.
    InvalidRegex,
    /// A string, code or namespace that is not valid UTF-8.
    InvalidUtf8,
    /// A document longer than an int32 length can say.
    DocumentTooLarge,
};

pub fn init(gpa: std.mem.Allocator) Builder {
    return .{ .gpa = gpa };
}

pub fn deinit(b: *Builder) void {
    b.buf.deinit(b.gpa);
    b.frames.deinit(b.gpa);
}

/// Everything written so far.
pub fn bytes(b: *const Builder) []const u8 {
    return b.buf.items;
}

/// The finished buffer, owned by the caller; the builder is empty after.
pub fn toOwnedSlice(b: *Builder) error{OutOfMemory}![]u8 {
    std.debug.assert(b.frames.items.len == 0);
    b.frames.clearAndFree(b.gpa);
    return b.buf.toOwnedSlice(b.gpa);
}

/// Empties the buffer, keeping its memory.
pub fn reset(b: *Builder) void {
    b.buf.clearRetainingCapacity();
    b.frames.clearRetainingCapacity();
}

/// Opens a top-level document at the end of the buffer.
pub fn begin(b: *Builder) Error!void {
    std.debug.assert(b.frames.items.len == 0);
    try b.open(null);
}

pub fn beginDocument(b: *Builder, name: []const u8) Error!void {
    try b.key(.document, name);
    try b.open(null);
}

pub fn beginArray(b: *Builder, name: []const u8) Error!void {
    try b.key(.array, name);
    try b.open(0);
}

/// Closes the innermost open document or array.
pub fn end(b: *Builder) Error!void {
    const frame = b.frames.pop().?;
    try b.buf.append(b.gpa, 0);
    const len = b.buf.items.len - frame.start;
    if (len > std.math.maxInt(i32)) return error.DocumentTooLarge;
    std.mem.writeInt(i32, b.buf.items[frame.start..][0..4], @intCast(len), .little);
}

fn open(b: *Builder, index: ?u32) Error!void {
    try b.frames.append(b.gpa, .{ .start = b.buf.items.len, .index = index });
    try b.buf.appendSlice(b.gpa, &.{ 0, 0, 0, 0 });
}

/// The type byte and the element name (or the next index inside an array).
fn key(b: *Builder, t: Type, name: []const u8) Error!void {
    const frame = &b.frames.items[b.frames.items.len - 1];
    try b.buf.append(b.gpa, @backingInt(t));
    if (frame.index) |*i| {
        var digits: [10]u8 = undefined;
        try b.buf.appendSlice(b.gpa, std.fmt.bufPrint(&digits, "{d}", .{i.*}) catch unreachable);
        i.* += 1;
    } else {
        if (std.mem.indexOfScalar(u8, name, 0) != null or !std.unicode.utf8ValidateSlice(name)) return error.InvalidKey;
        try b.buf.appendSlice(b.gpa, name);
    }
    try b.buf.append(b.gpa, 0);
}

/// Appends one element. Documents and arrays are copied as they are.
pub fn append(b: *Builder, name: []const u8, v: Value) Error!void {
    try b.key(std.meta.activeTag(v), name);
    try b.value(v);
}

/// Appends `v` through the struct mapping (see `mapping.zig`): structs,
/// anonymous literals, slices, optionals, enums, numbers, strings and the
/// BSON types.
pub fn appendAny(b: *Builder, name: []const u8, v: anytype) Error!void {
    return @import("mapping.zig").appendField(b, name, v, .{});
}

/// Appends every element of `doc` into the open document.
pub fn appendElements(b: *Builder, doc: Document) Error!void {
    var it = doc.iterator();
    while (it.next()) |e| try b.append(e.name, e.value);
}

fn value(b: *Builder, v: Value) Error!void {
    const gpa = b.gpa;
    switch (v) {
        .double => |f| try b.int(u64, @bitCast(f)),
        .string, .javascript, .symbol => |s| try b.string(s),
        .document => |d| try b.buf.appendSlice(gpa, d.bytes),
        .array => |a| try b.buf.appendSlice(gpa, a.doc.bytes),
        .binary => |bin| {
            const old = bin.subtype == .binary_old;
            const len = bin.data.len + @as(usize, if (old) 4 else 0);
            if (len > std.math.maxInt(i32)) return error.DocumentTooLarge;
            try b.int(i32, @intCast(len));
            try b.buf.append(gpa, @backingInt(bin.subtype));
            if (old) try b.int(i32, @intCast(bin.data.len));
            try b.buf.appendSlice(gpa, bin.data);
        },
        .undefined, .null, .min_key, .max_key => {},
        .object_id => |id| try b.buf.appendSlice(gpa, &id.bytes),
        .boolean => |x| try b.buf.append(gpa, @intFromBool(x)),
        .datetime => |d| try b.int(i64, d.ms),
        .regex => |r| {
            for ([_][]const u8{ r.pattern, r.options }) |s| {
                if (std.mem.indexOfScalar(u8, s, 0) != null) return error.InvalidRegex;
                if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidUtf8;
            }
            try b.buf.appendSlice(gpa, r.pattern);
            try b.buf.append(gpa, 0);
            // Sorted: the spec asks encoders for alphabetical flags.
            const at = b.buf.items.len;
            try b.buf.appendSlice(gpa, r.options);
            std.mem.sortUnstable(u8, b.buf.items[at..], {}, std.sort.asc(u8));
            try b.buf.append(gpa, 0);
        },
        .db_pointer => |p| {
            try b.string(p.namespace);
            try b.buf.appendSlice(gpa, &p.id.bytes);
        },
        .javascript_with_scope => |c| {
            const total = 4 + 4 + c.code.len + 1 + c.scope.bytes.len;
            if (total > std.math.maxInt(i32)) return error.DocumentTooLarge;
            try b.int(i32, @intCast(total));
            try b.string(c.code);
            try b.buf.appendSlice(gpa, c.scope.bytes);
        },
        .int32 => |x| try b.int(i32, x),
        .timestamp => |t| {
            try b.int(u32, t.i);
            try b.int(u32, t.t);
        },
        .int64 => |x| try b.int(i64, x),
        .decimal128 => |d| {
            try b.int(u64, d.low);
            try b.int(u64, d.high);
        },
    }
}

fn int(b: *Builder, comptime T: type, x: T) Error!void {
    var raw: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &raw, x, .little);
    try b.buf.appendSlice(b.gpa, &raw);
}

fn string(b: *Builder, s: []const u8) Error!void {
    if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidUtf8;
    if (s.len + 1 > std.math.maxInt(i32)) return error.DocumentTooLarge;
    try b.int(i32, @intCast(s.len + 1));
    try b.buf.appendSlice(b.gpa, s);
    try b.buf.append(b.gpa, 0);
}

/// Re-encodes `doc` element by element, all the way down: array keys
/// become "0", "1", ... and regex flags are sorted, as the spec's canonical
/// form asks. Code-with-scope scopes and documents nested in them too.
pub fn appendCanonical(b: *Builder, doc: Document) Error!void {
    var it = doc.iterator();
    while (it.next()) |e| switch (e.value) {
        .document => |d| {
            try b.beginDocument(e.name);
            try b.appendCanonical(d);
            try b.end();
        },
        .array => |a| {
            try b.beginArray(e.name);
            try b.appendCanonical(a.doc);
            try b.end();
        },
        .javascript_with_scope => |c| {
            // The scope is re-encoded at the end of the buffer, then the
            // element is written from it.
            var inner: Builder = .init(b.gpa);
            defer inner.deinit();
            try inner.begin();
            try inner.appendCanonical(c.scope);
            try inner.end();
            try b.append(e.name, .{ .javascript_with_scope = .{ .code = c.code, .scope = .{ .bytes = inner.bytes() } } });
        },
        else => try b.append(e.name, e.value),
    };
}

/// `doc` in canonical form (see `appendCanonical`), owned by the caller.
pub fn canonicalize(gpa: std.mem.Allocator, doc: Document) Error![]u8 {
    var b: Builder = .init(gpa);
    errdefer b.deinit();
    try b.begin();
    try b.appendCanonical(doc);
    try b.end();
    return b.toOwnedSlice();
}

const testing = std.testing;
const ObjectId = @import("ObjectId.zig");

test "builds nested documents and arrays" {
    var b: Builder = .init(testing.allocator);
    defer b.deinit();
    try b.begin();
    try b.append("a", .{ .int32 = 1 });
    try b.beginDocument("c");
    try b.append("d", .{ .boolean = true });
    try b.end();
    try b.beginArray("e");
    try b.append("ignored", .null);
    try b.append("", .{ .string = "x" });
    try b.end();
    try b.end();
    const doc = try Document.init(b.bytes());
    try testing.expectEqual(1, doc.get("a").?.int32);
    try testing.expect(doc.getPath("c.d").?.boolean);
    try testing.expectEqualStrings("x", doc.getPath("e.1").?.string);
}

test "every type round-trips" {
    const id = try ObjectId.parse("56e1fc72e0c917e9c4714161");
    const scope_bytes = [_]u8{ 5, 0, 0, 0, 0 };
    const values = [_]Value{
        .{ .double = -1.5 },
        .{ .string = "h\x00é" },
        .{ .document = .empty },
        .{ .array = .empty },
        .{ .binary = .{ .subtype = .uuid, .data = "0123456789abcdef" } },
        .{ .binary = .{ .subtype = .binary_old, .data = "\xff\xff" } },
        .undefined,
        .{ .object_id = id },
        .{ .boolean = true },
        .{ .datetime = .{ .ms = -5 } },
        .null,
        .{ .regex = .{ .pattern = "a/b", .options = "mi" } },
        .{ .db_pointer = .{ .namespace = "db.c", .id = id } },
        .{ .javascript = "f()" },
        .{ .symbol = "s" },
        .{ .javascript_with_scope = .{ .code = "g()", .scope = .{ .bytes = &scope_bytes } } },
        .{ .int32 = -7 },
        .{ .timestamp = .{ .t = 4000000000, .i = 3 } },
        .{ .int64 = std.math.minInt(i64) },
        .{ .decimal128 = .fromInt(12) },
        .min_key,
        .max_key,
    };
    var b: Builder = .init(testing.allocator);
    defer b.deinit();
    try b.begin();
    for (values) |v| try b.append(@tagName(v), v);
    try b.end();
    const doc = try Document.init(b.bytes());
    var it = doc.iterator();
    for (values) |v| {
        const e = it.next().?;
        try testing.expectEqualStrings(@tagName(v), e.name);
        try testing.expectEqual(std.meta.activeTag(v), std.meta.activeTag(e.value));
    }
    try testing.expectEqualStrings("im", doc.get("regex").?.regex.options);
    var old_binary: ?[]const u8 = null;
    it = doc.iterator();
    while (it.next()) |e| if (e.value == .binary and e.value.binary.subtype == .binary_old) {
        old_binary = e.value.binary.data;
    };
    try testing.expectEqualStrings("\xff\xff", old_binary.?);
    try testing.expectEqual(4000000000, doc.get("timestamp").?.timestamp.t);
    try testing.expectEqualStrings("h\x00é", doc.get("string").?.string);
}

test "keys and regexes with 0x00 are refused (corpus prose test 1)" {
    var b: Builder = .init(testing.allocator);
    defer b.deinit();
    try b.begin();
    try testing.expectError(error.InvalidKey, b.append("a\x00", .null));
    try b.beginDocument("sub");
    try testing.expectError(error.InvalidKey, b.append("b\x00", .null));
    try testing.expectError(error.InvalidRegex, b.append("r", .{ .regex = .{ .pattern = "a\x00" } }));
    try testing.expectError(error.InvalidRegex, b.append("r", .{ .regex = .{ .pattern = "a", .options = "i\x00" } }));
    try testing.expectError(error.InvalidUtf8, b.append("s", .{ .string = "\xe9" }));
}

test "duplicate keys are kept in order (corpus prose test 2)" {
    var b: Builder = .init(testing.allocator);
    defer b.deinit();
    try b.begin();
    try b.append("foo", .{ .int32 = 1 });
    try b.append("foo", .{ .int32 = 2 });
    try b.end();
    var expected: [23]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "1700000010666f6f000100000010666f6f000200000000");
    try testing.expectEqualSlices(u8, &expected, b.bytes());
    // A round trip keeps both.
    const again = try canonicalize(testing.allocator, try .init(b.bytes()));
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, &expected, again);
}
