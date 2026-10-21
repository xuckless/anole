//! BSON values and read-only document views (https://bsonspec.org/spec.html).
//!
//! `Document.init` checks a whole document in one pass (lengths,
//! terminators, element types, UTF-8, booleans, nesting depth); after that
//! the iterator and `get` cannot fail, and every string, binary and
//! sub-document they return points into the original bytes.
const std = @import("std");
const ObjectId = @import("ObjectId.zig");
const Decimal128 = @import("Decimal128.zig");

/// The element type byte.
pub const Type = enum(u8) {
    double = 0x01,
    string = 0x02,
    document = 0x03,
    array = 0x04,
    binary = 0x05,
    /// Deprecated.
    undefined = 0x06,
    object_id = 0x07,
    boolean = 0x08,
    datetime = 0x09,
    null = 0x0A,
    regex = 0x0B,
    /// Deprecated.
    db_pointer = 0x0C,
    javascript = 0x0D,
    /// Deprecated.
    symbol = 0x0E,
    /// Deprecated since MongoDB 4.4 for queries, still readable.
    javascript_with_scope = 0x0F,
    int32 = 0x10,
    timestamp = 0x11,
    int64 = 0x12,
    decimal128 = 0x13,
    min_key = 0xFF,
    max_key = 0x7F,

    pub fn fromByte(b: u8) ?Type {
        return switch (b) {
            0x01...0x13, 0x7F, 0xFF => @fromBackingInt(b),
            else => null,
        };
    }
};

pub const Binary = struct {
    subtype: Subtype = .generic,
    /// For the old binary subtype (0x02) this is the payload without its
    /// inner length; the encoder writes the length back.
    data: []const u8,

    pub const Subtype = enum(u8) {
        generic = 0x00,
        function = 0x01,
        binary_old = 0x02,
        uuid_old = 0x03,
        uuid = 0x04,
        md5 = 0x05,
        encrypted = 0x06,
        column = 0x07,
        sensitive = 0x08,
        vector = 0x09,
        user_defined = 0x80,
        _,
    };
};

pub const Regex = struct {
    pattern: []const u8,
    /// Flags such as "imsx"; the encoder writes them sorted, as the spec asks.
    options: []const u8 = "",
};

/// Deprecated reference type: a namespace and an ObjectId.
pub const DbPointer = struct {
    namespace: []const u8,
    id: ObjectId,
};

pub const CodeWithScope = struct {
    code: []const u8,
    scope: Document,
};

/// Internal MongoDB timestamp (replication, `$currentDate`): seconds and an
/// ordinal within that second.
pub const Timestamp = struct {
    t: u32,
    i: u32,
};

/// UTC datetime: milliseconds since the Unix epoch.
pub const Datetime = struct {
    ms: i64,

    pub fn fromSeconds(s: i64) Datetime {
        return .{ .ms = s * std.time.ms_per_s };
    }

    pub fn fromTimestamp(t: std.Io.Timestamp) Datetime {
        return .{ .ms = t.toMilliseconds() };
    }
};

pub const Value = union(Type) {
    double: f64,
    string: []const u8,
    document: Document,
    array: Array,
    binary: Binary,
    undefined,
    object_id: ObjectId,
    boolean: bool,
    datetime: Datetime,
    null,
    regex: Regex,
    db_pointer: DbPointer,
    javascript: []const u8,
    symbol: []const u8,
    javascript_with_scope: CodeWithScope,
    int32: i32,
    timestamp: Timestamp,
    int64: i64,
    decimal128: Decimal128,
    min_key,
    max_key,

    /// Relaxed Extended JSON, for logs: `{f}`.
    pub fn format(v: Value, w: *std.Io.Writer) std.Io.Writer.Error!void {
        return @import("extjson.zig").writeValue(w, v, .relaxed);
    }

    /// A copy whose strings, binary data and documents live in `arena`.
    pub fn dupe(v: Value, arena: std.mem.Allocator) error{OutOfMemory}!Value {
        return switch (v) {
            .string => |s| .{ .string = try arena.dupe(u8, s) },
            .javascript => |s| .{ .javascript = try arena.dupe(u8, s) },
            .symbol => |s| .{ .symbol = try arena.dupe(u8, s) },
            .document => |d| .{ .document = try d.dupe(arena) },
            .array => |a| .{ .array = .{ .doc = try a.doc.dupe(arena) } },
            .binary => |b| .{ .binary = .{ .subtype = b.subtype, .data = try arena.dupe(u8, b.data) } },
            .regex => |r| .{ .regex = .{ .pattern = try arena.dupe(u8, r.pattern), .options = try arena.dupe(u8, r.options) } },
            .db_pointer => |p| .{ .db_pointer = .{ .namespace = try arena.dupe(u8, p.namespace), .id = p.id } },
            .javascript_with_scope => |c| .{ .javascript_with_scope = .{ .code = try arena.dupe(u8, c.code), .scope = try c.scope.dupe(arena) } },
            else => v,
        };
    }
};

pub const Element = struct {
    name: []const u8,
    value: Value,
};

pub const DecodeError = error{
    /// A length prefix that is negative, too small, or runs past its
    /// container, or a document shorter than its stated length.
    InvalidLength,
    /// A document whose last byte is not 0x00, or whose terminator comes
    /// before its stated end.
    InvalidTerminator,
    /// A string without its trailing 0x00, or a key, regex or other
    /// C string without a terminator.
    InvalidString,
    InvalidUtf8,
    UnknownType,
    /// A boolean byte other than 0 or 1.
    InvalidBoolean,
    /// An old-binary (0x02) payload whose inner length disagrees.
    InvalidBinary,
    /// Code-with-scope whose parts do not fill its stated length.
    InvalidCodeWithScope,
    /// Nested deeper than the limit (`default_max_depth`).
    TooDeep,
};

/// Nesting limit for documents read off the wire. MongoDB's own default is
/// 200 (`BSONDepth::kDefaultMaxAllowableDepth`); user documents are capped
/// at 100 by the server, so replies wrapping them fit.
pub const default_max_depth = 200;

/// A validated BSON document: the bytes from its length prefix to its
/// terminator. Build one with `init` (or `fromPrefix`); a `Document`
/// made by hand from unchecked bytes may panic when read.
pub const Document = struct {
    bytes: []const u8,

    /// `{}`.
    pub const empty: Document = .{ .bytes = &.{ 5, 0, 0, 0, 0 } };

    /// Validates `bytes` as exactly one document.
    pub fn init(bytes: []const u8) DecodeError!Document {
        return initDepth(bytes, default_max_depth);
    }

    pub fn initDepth(bytes: []const u8, max_depth: u32) DecodeError!Document {
        try validate(bytes, 0, max_depth);
        return .{ .bytes = bytes };
    }

    /// Validates the document at the start of `bytes`, by its own length;
    /// what follows it is the caller's (OP_MSG document sequences).
    pub fn fromPrefix(bytes: []const u8) DecodeError!Document {
        if (bytes.len < 5) return error.InvalidLength;
        const len = std.mem.readInt(i32, bytes[0..4], .little);
        if (len < 5 or len > bytes.len) return error.InvalidLength;
        return init(bytes[0..@intCast(len)]);
    }

    pub fn iterator(d: Document) Iterator {
        return .{ .bytes = d.bytes, .pos = 4 };
    }

    /// The value of the first element named `name`. Duplicate keys are
    /// legal BSON; the first one wins here and in the struct mapping.
    pub fn get(d: Document, name: []const u8) ?Value {
        var it = d.iterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, e.name, name)) return e.value;
        }
        return null;
    }

    /// Follows a dotted path through sub-documents ("cursor.firstBatch").
    /// Array elements are reached by index ("a.0").
    pub fn getPath(d: Document, path: []const u8) ?Value {
        var doc = d;
        var it = std.mem.splitScalar(u8, path, '.');
        while (it.next()) |part| {
            const v = doc.get(part) orelse return null;
            if (it.peek() == null) return v;
            doc = switch (v) {
                .document => |sub| sub,
                .array => |a| a.doc,
                else => return null,
            };
        }
        return null;
    }

    pub fn count(d: Document) usize {
        var n: usize = 0;
        var it = d.iterator();
        while (it.next()) |_| n += 1;
        return n;
    }

    pub fn isEmpty(d: Document) bool {
        return d.bytes.len == 5;
    }

    pub fn dupe(d: Document, arena: std.mem.Allocator) error{OutOfMemory}!Document {
        return .{ .bytes = try arena.dupe(u8, d.bytes) };
    }

    /// Relaxed Extended JSON, for logs: `{f}`.
    pub fn format(d: Document, w: *std.Io.Writer) std.Io.Writer.Error!void {
        return @import("extjson.zig").write(w, d, .relaxed);
    }
};

/// A BSON array: a document whose keys are "0", "1", ... Readers ignore the
/// keys (the spec calls other keys degenerate, not invalid).
pub const Array = struct {
    doc: Document,

    pub const empty: Array = .{ .doc = .empty };

    pub fn iterator(a: Array) ValueIterator {
        return .{ .inner = a.doc.iterator() };
    }

    pub fn count(a: Array) usize {
        return a.doc.count();
    }

    pub fn at(a: Array, index: usize) ?Value {
        var it = a.iterator();
        var i: usize = 0;
        while (it.next()) |v| : (i += 1) {
            if (i == index) return v;
        }
        return null;
    }

    pub fn format(a: Array, w: *std.Io.Writer) std.Io.Writer.Error!void {
        return @import("extjson.zig").writeValue(w, .{ .array = a }, .relaxed);
    }
};

pub const ValueIterator = struct {
    inner: Iterator,

    pub fn next(it: *ValueIterator) ?Value {
        return if (it.inner.next()) |e| e.value else null;
    }
};

/// Walks the elements of a validated document in order.
pub const Iterator = struct {
    bytes: []const u8,
    pos: usize,

    pub fn next(it: *Iterator) ?Element {
        if (it.pos + 1 >= it.bytes.len) return null;
        const t: Type = @fromBackingInt(it.bytes[it.pos]);
        const name_start = it.pos + 1;
        const name_end = name_start + std.mem.indexOfScalar(u8, it.bytes[name_start..], 0).?;
        it.pos = name_end + 1;
        return .{ .name = it.bytes[name_start..name_end], .value = it.readValue(t) };
    }

    fn take(it: *Iterator, n: usize) []const u8 {
        defer it.pos += n;
        return it.bytes[it.pos..][0..n];
    }

    fn int(it: *Iterator, comptime T: type) T {
        return std.mem.readInt(T, it.take(@sizeOf(T))[0..@sizeOf(T)], .little);
    }

    fn string(it: *Iterator) []const u8 {
        const len: usize = @intCast(it.int(i32));
        return it.take(len)[0 .. len - 1];
    }

    fn cstring(it: *Iterator) []const u8 {
        const len = std.mem.indexOfScalar(u8, it.bytes[it.pos..], 0).?;
        defer it.pos += 1;
        return it.take(len);
    }

    fn document(it: *Iterator) Document {
        const len: usize = @intCast(std.mem.readInt(i32, it.bytes[it.pos..][0..4], .little));
        return .{ .bytes = it.take(len) };
    }

    fn readValue(it: *Iterator, t: Type) Value {
        return switch (t) {
            .double => .{ .double = @bitCast(it.int(u64)) },
            .string => .{ .string = it.string() },
            .document => .{ .document = it.document() },
            .array => .{ .array = .{ .doc = it.document() } },
            .binary => b: {
                const len: usize = @intCast(it.int(i32));
                const subtype: Binary.Subtype = @fromBackingInt(it.take(1)[0]);
                var data = it.take(len);
                if (subtype == .binary_old) data = data[4..];
                break :b .{ .binary = .{ .subtype = subtype, .data = data } };
            },
            .undefined => .undefined,
            .object_id => .{ .object_id = .{ .bytes = it.take(12)[0..12].* } },
            .boolean => .{ .boolean = it.take(1)[0] == 1 },
            .datetime => .{ .datetime = .{ .ms = it.int(i64) } },
            .null => .null,
            .regex => .{ .regex = .{ .pattern = it.cstring(), .options = it.cstring() } },
            .db_pointer => .{ .db_pointer = .{ .namespace = it.string(), .id = .{ .bytes = it.take(12)[0..12].* } } },
            .javascript => .{ .javascript = it.string() },
            .symbol => .{ .symbol = it.string() },
            .javascript_with_scope => c: {
                _ = it.int(i32);
                const code = it.string();
                break :c .{ .javascript_with_scope = .{ .code = code, .scope = it.document() } };
            },
            .int32 => .{ .int32 = it.int(i32) },
            .timestamp => .{ .timestamp = .{ .i = it.int(u32), .t = it.int(u32) } },
            .int64 => .{ .int64 = it.int(i64) },
            .decimal128 => .{ .decimal128 = .{ .low = it.int(u64), .high = it.int(u64) } },
            .min_key => .min_key,
            .max_key => .max_key,
        };
    }
};

// Validation. `bytes` is exactly one document as its container sized it.
fn validate(bytes: []const u8, depth: u32, max_depth: u32) DecodeError!void {
    if (depth > max_depth) return error.TooDeep;
    if (bytes.len < 5) return error.InvalidLength;
    const len = std.mem.readInt(i32, bytes[0..4], .little);
    if (len < 5 or len != bytes.len) return error.InvalidLength;
    const end = bytes.len - 1;
    if (bytes[end] != 0) return error.InvalidTerminator;
    // Elements live in body; the terminator is not part of it, so a length
    // that reaches it is caught as running past its container.
    const body = bytes[0..end];
    var pos: usize = 4;
    while (pos < end) {
        const type_byte = body[pos];
        if (type_byte == 0) return error.InvalidTerminator;
        const t = Type.fromByte(type_byte) orelse return error.UnknownType;
        pos += 1;
        _ = try cstring(body, &pos);
        try validateValue(body, &pos, t, depth, max_depth);
    }
}

fn validateValue(body: []const u8, pos: *usize, t: Type, depth: u32, max_depth: u32) DecodeError!void {
    switch (t) {
        .double, .datetime, .timestamp, .int64 => try skip(body, pos, 8),
        .int32 => try skip(body, pos, 4),
        .decimal128 => try skip(body, pos, 16),
        .object_id => try skip(body, pos, 12),
        .undefined, .null, .min_key, .max_key => {},
        .boolean => {
            try skip(body, pos, 1);
            if (body[pos.* - 1] > 1) return error.InvalidBoolean;
        },
        .string, .javascript, .symbol => _ = try string(body, pos),
        .document, .array => try subdocument(body, pos, depth, max_depth),
        .binary => {
            const len = try length(body, pos);
            try skip(body, pos, 1);
            const subtype = body[pos.* - 1];
            try skip(body, pos, len);
            if (subtype == @backingInt(Binary.Subtype.binary_old)) {
                if (len < 4) return error.InvalidBinary;
                const inner = std.mem.readInt(i32, body[pos.* - len ..][0..4], .little);
                if (inner < 0 or inner != len - 4) return error.InvalidBinary;
            }
        },
        .regex => {
            _ = try cstring(body, pos);
            _ = try cstring(body, pos);
        },
        .db_pointer => {
            _ = try string(body, pos);
            try skip(body, pos, 12);
        },
        .javascript_with_scope => {
            // The length counts itself: int32 + string (4 + at least 1) +
            // a document (at least 5).
            const start = pos.*;
            if (body.len - start < 4) return error.InvalidLength;
            const total = std.mem.readInt(i32, body[start..][0..4], .little);
            if (total < 14) return error.InvalidCodeWithScope;
            if (total > body.len - start) return error.InvalidLength;
            pos.* += 4;
            const part = body[0 .. start + @as(usize, @intCast(total))];
            _ = string(part, pos) catch return error.InvalidCodeWithScope;
            if (part.len - pos.* < 5) return error.InvalidCodeWithScope;
            const scope_len = std.mem.readInt(i32, part[pos.*..][0..4], .little);
            if (scope_len < 5 or scope_len != part.len - pos.*) return error.InvalidCodeWithScope;
            try subdocument(part, pos, depth, max_depth);
        },
    }
}

fn skip(body: []const u8, pos: *usize, n: usize) DecodeError!void {
    if (body.len - pos.* < n) return error.InvalidLength;
    pos.* += n;
}

/// A non-negative int32 length that fits in what is left of `body`.
fn length(body: []const u8, pos: *usize) DecodeError!usize {
    if (body.len - pos.* < 4) return error.InvalidLength;
    const len = std.mem.readInt(i32, body[pos.*..][0..4], .little);
    pos.* += 4;
    if (len < 0 or len > body.len - pos.*) return error.InvalidLength;
    return @intCast(len);
}

fn string(body: []const u8, pos: *usize) DecodeError![]const u8 {
    const len = try length(body, pos);
    if (len < 1) return error.InvalidLength;
    const s = body[pos.*..][0..len];
    pos.* += len;
    if (s[len - 1] != 0) return error.InvalidString;
    // Strings may hold 0x00 bytes; only the terminator is required.
    if (!std.unicode.utf8ValidateSlice(s[0 .. len - 1])) return error.InvalidUtf8;
    return s[0 .. len - 1];
}

fn cstring(body: []const u8, pos: *usize) DecodeError![]const u8 {
    const len = std.mem.indexOfScalar(u8, body[pos.*..], 0) orelse return error.InvalidString;
    const s = body[pos.*..][0..len];
    pos.* += len + 1;
    if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidUtf8;
    return s;
}

fn subdocument(body: []const u8, pos: *usize, depth: u32, max_depth: u32) DecodeError!void {
    if (body.len - pos.* < 4) return error.InvalidLength;
    const len = std.mem.readInt(i32, body[pos.*..][0..4], .little);
    if (len < 5 or len > body.len - pos.*) return error.InvalidLength;
    const n: usize = @intCast(len);
    try validate(body[pos.*..][0..n], depth + 1, max_depth);
    pos.* += n;
}

const testing = std.testing;

fn hex(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

test "reads every element of a document in order" {
    // {"a": 1, "b": "x", "c": {"d": true}, "e": [null]}
    const bytes = hex("2C00000010610001000000026200020000007800036300090000000864000100046500080000000A30000000");
    const doc = try Document.init(&bytes);
    var it = doc.iterator();
    try testing.expectEqualStrings("a", it.next().?.name);
    const b = it.next().?;
    try testing.expectEqualStrings("x", b.value.string);
    const c = it.next().?.value.document;
    try testing.expect(c.get("d").?.boolean);
    const e = it.next().?.value.array;
    try testing.expectEqual(1, e.count());
    try testing.expect(e.at(0).? == .null);
    try testing.expect(it.next() == null);
    try testing.expectEqual(4, doc.count());
    try testing.expect(doc.getPath("c.d").?.boolean);
    try testing.expect(doc.getPath("e.0").? == .null);
    try testing.expect(doc.getPath("c.x") == null);
}

test "rejects malformed documents" {
    try testing.expectError(error.InvalidLength, Document.init(&hex("0400000000")));
    try testing.expectError(error.InvalidTerminator, Document.init(&hex("0500000001")));
    try testing.expectError(error.UnknownType, Document.init(&hex("07000000800000")));
    try testing.expectError(error.InvalidBoolean, Document.init(&hex("090000000862000200")));
    try testing.expectError(error.InvalidUtf8, Document.init(&hex("0E00000002610002000000E90000")));
    // A key with no terminator before the document's own.
    try testing.expectError(error.InvalidString, Document.init(&hex("07000000106100")));
}

test "fromPrefix reads one document and leaves the rest" {
    const two = hex("0500000000" ++ "0C0000001061000100000000");
    const first = try Document.fromPrefix(&two);
    try testing.expect(first.isEmpty());
    const second = try Document.fromPrefix(two[first.bytes.len..]);
    try testing.expectEqual(1, second.get("a").?.int32);
    try testing.expectError(error.InvalidLength, Document.fromPrefix(two[0..3]));
}

test "nesting deeper than the limit is refused" {
    // 3 levels: {"a": {"a": {}}}
    const bytes = hex("15000000036100" ++ "0D000000036100" ++ "0500000000" ++ "00" ++ "00");
    _ = try Document.initDepth(&bytes, 2);
    try testing.expectError(error.TooDeep, Document.initDepth(&bytes, 1));
}

test "duplicate keys: get returns the first" {
    const bytes = hex("1700000010666f6f000100000010666f6f000200000000");
    const doc = try Document.init(&bytes);
    try testing.expectEqual(1, doc.get("foo").?.int32);
    try testing.expectEqual(2, doc.count());
}
