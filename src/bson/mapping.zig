//! Zig values to BSON and back, decided at compile time.
//!
//! | Zig | BSON |
//! | --- | --- |
//! | struct (not a tuple) | document, fields in declaration order |
//! | tuple, slice, array (not of u8) | array |
//! | `[]const u8`, string literals, `[N]u8` | string |
//! | `bool` | boolean |
//! | integers up to 32 bits (unsigned up to 31) | int32; wider ones int64 |
//! | `comptime_int` | int32 if it fits, else int64 |
//! | floats | double |
//! | `?T` | `T`, or nothing when null (`EncodeOptions.nulls`) |
//! | enum | its tag name, or its value with `EnumRepr.int` |
//! | tagged union | its active payload |
//! | `Value`, `Document`, `Array`, `ObjectId`, `Datetime`, ... | themselves |
//!
//! A struct renames fields with `pub const bson_rename = .{ .id = "_id" };`
//! and an enum picks its form with `pub const bson_enum: bson.EnumRepr = .int;`
//! (else `EncodeOptions.enums` decides). Decoding is lenient where MongoDB
//! is loose about numbers: integer fields take int32, int64 and integral
//! doubles (`ok: 1.0`); float fields take all three; enums take either form.
//! A missing field takes its default, then null for an optional, else it is
//! `error.MissingField`; with duplicate keys the first one wins.
const std = @import("std");
const document = @import("document.zig");
const Builder = @import("Builder.zig");
const ObjectId = @import("ObjectId.zig");
const Decimal128 = @import("Decimal128.zig");
const Value = document.Value;
const Document = document.Document;
const Array = document.Array;

pub const EnumRepr = enum { string, int };

pub const EncodeOptions = struct {
    /// Null optionals in a document: left out, or written as BSON null.
    /// Inside an array a null is always written, so indexes stay put.
    nulls: enum { omit, write } = .omit,
    /// For enums that do not declare `bson_enum`.
    enums: EnumRepr = .string,
};

pub const DecodeOptions = struct {
    /// Copy strings, binary data and raw documents into the arena (the
    /// default), or point into the input, which must then outlive the result.
    copy: bool = true,
    /// Elements no field maps to are skipped; false makes them an error.
    ignore_unknown_fields: bool = true,
};

pub const EncodeError = Builder.Error || error{
    /// An unsigned integer above the int64 range.
    Overflow,
};

pub const MappingError = error{
    OutOfMemory,
    MissingField,
    UnknownField,
    /// A BSON type the Zig type cannot take.
    UnexpectedType,
    /// A number outside the integer type's range, or a non-integral double
    /// for an integer.
    Overflow,
    /// A string or number that names no member of the enum.
    InvalidEnum,
    /// An array whose length differs from a Zig array's.
    LengthMismatch,
};

/// `v` (a struct, or anything that maps to a document) as a BSON
/// document owned by the caller.
pub fn encode(gpa: std.mem.Allocator, v: anytype, options: EncodeOptions) EncodeError![]u8 {
    var b: Builder = .init(gpa);
    errdefer b.deinit();
    try b.begin();
    try appendFields(&b, v, options);
    try b.end();
    return b.toOwnedSlice();
}

/// The fields of `v` into the open document.
pub fn appendFields(b: *Builder, v: anytype, options: EncodeOptions) EncodeError!void {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (T == Document) return b.appendElements(v);
            if (comptime info.is_tuple or isBsonType(T)) @compileError("bson: " ++ @typeName(T) ++ " is not a document");
            inline for (info.field_names) |field| {
                try appendField(b, comptime fieldName(T, field), @field(v, field), options);
            }
        },
        .pointer => |p| if (p.size == .one) return appendFields(b, v.*, options) else @compileError("bson: " ++ @typeName(T) ++ " is not a document"),
        else => @compileError("bson: " ++ @typeName(T) ++ " is not a document"),
    }
}

/// One element named `name`.
pub fn appendField(b: *Builder, name: []const u8, v: anytype, options: EncodeOptions) EncodeError!void {
    const T = @TypeOf(v);
    switch (T) {
        Value => return b.append(name, v),
        Document => return b.append(name, .{ .document = v }),
        Array => return b.append(name, .{ .array = v }),
        ObjectId => return b.append(name, .{ .object_id = v }),
        Decimal128 => return b.append(name, .{ .decimal128 = v }),
        document.Datetime => return b.append(name, .{ .datetime = v }),
        document.Timestamp => return b.append(name, .{ .timestamp = v }),
        document.Binary => return b.append(name, .{ .binary = v }),
        document.Regex => return b.append(name, .{ .regex = v }),
        document.DbPointer => return b.append(name, .{ .db_pointer = v }),
        document.CodeWithScope => return b.append(name, .{ .javascript_with_scope = v }),
        else => {},
    }
    switch (@typeInfo(T)) {
        .bool => try b.append(name, .{ .boolean = v }),
        .comptime_int => {
            if (comptime std.math.cast(i32, v)) |x| return b.append(name, .{ .int32 = x });
            if (comptime std.math.cast(i64, v) == null) @compileError("bson: integer out of int64 range");
            try b.append(name, .{ .int64 = v });
        },
        .int => |info| {
            if ((info.signedness == .signed and info.bits <= 32) or (info.signedness == .unsigned and info.bits <= 31))
                return b.append(name, .{ .int32 = v });
            try b.append(name, .{ .int64 = std.math.cast(i64, v) orelse return error.Overflow });
        },
        .float, .comptime_float => try b.append(name, .{ .double = v }),
        .null => try b.append(name, .null),
        .optional => if (v) |x| {
            try appendField(b, name, x, options);
        } else if (options.nulls == .write or b.frames.getLast().index != null) {
            try b.append(name, .null);
        },
        // An unnamed value of a non-exhaustive enum goes out as its number.
        .@"enum" => if (enumRepr(T, options.enums) == .string and std.enums.tagName(T, v) != null)
            try b.append(name, .{ .string = std.enums.tagName(T, v).? })
        else
            try appendField(b, name, @backingInt(v), options),
        .enum_literal => try b.append(name, .{ .string = @tagName(v) }),
        .@"union" => |info| {
            if (info.tag_type == null) @compileError("bson: untagged union " ++ @typeName(T));
            switch (v) {
                inline else => |payload| try appendField(b, name, payload, options),
            }
        },
        .array => |info| {
            if (info.child == u8) return b.append(name, .{ .string = &v });
            try appendArray(b, name, &v, options);
        },
        .pointer => |p| switch (p.size) {
            .one => switch (@typeInfo(p.child)) {
                .array => |a| if (a.child == u8)
                    try b.append(name, .{ .string = v })
                else
                    try appendArray(b, name, v, options),
                else => try appendField(b, name, v.*, options),
            },
            .slice => if (p.child == u8)
                try b.append(name, .{ .string = v })
            else
                try appendArray(b, name, v, options),
            else => @compileError("bson: cannot encode " ++ @typeName(T)),
        },
        .@"struct" => |info| {
            if (info.is_tuple) {
                try b.beginArray(name);
                inline for (info.field_names) |field| try appendField(b, "", @field(v, field), options);
                return b.end();
            }
            try b.beginDocument(name);
            try appendFields(b, v, options);
            try b.end();
        },
        else => @compileError("bson: cannot encode " ++ @typeName(T)),
    }
}

fn appendArray(b: *Builder, name: []const u8, items: anytype, options: EncodeOptions) EncodeError!void {
    try b.beginArray(name);
    for (items) |item| try appendField(b, "", item, options);
    try b.end();
}

fn isBsonType(comptime T: type) bool {
    return switch (T) {
        ObjectId, Decimal128, Array, document.Datetime, document.Timestamp, document.Binary, document.Regex, document.DbPointer, document.CodeWithScope => true,
        else => false,
    };
}

fn enumRepr(comptime T: type, default: EnumRepr) EnumRepr {
    return if (@hasDecl(T, "bson_enum")) T.bson_enum else default;
}

/// The BSON name of a struct field (`bson_rename`, else its own name).
fn fieldName(comptime T: type, comptime field: []const u8) []const u8 {
    if (@hasDecl(T, "bson_rename") and @hasField(@TypeOf(T.bson_rename), field)) return @field(T.bson_rename, field);
    return field;
}

/// Validates `bytes` and maps the document onto `T`. Strings and the like
/// are copied into `arena` (see `DecodeOptions.copy`).
pub fn decode(comptime T: type, arena: std.mem.Allocator, bytes: []const u8, options: DecodeOptions) (document.DecodeError || MappingError)!T {
    return decodeDocument(T, arena, try Document.init(bytes), options);
}

pub fn decodeDocument(comptime T: type, arena: std.mem.Allocator, doc: Document, options: DecodeOptions) MappingError!T {
    return decodeValue(T, arena, .{ .document = doc }, options);
}

pub fn decodeValue(comptime T: type, arena: std.mem.Allocator, v: Value, options: DecodeOptions) MappingError!T {
    switch (T) {
        Value => return if (options.copy) v.dupe(arena) else v,
        Document => return switch (v) {
            .document => |d| if (options.copy) d.dupe(arena) else d,
            else => error.UnexpectedType,
        },
        Array => return switch (v) {
            .array => |a| .{ .doc = if (options.copy) try a.doc.dupe(arena) else a.doc },
            else => error.UnexpectedType,
        },
        ObjectId => return if (v == .object_id) v.object_id else error.UnexpectedType,
        Decimal128 => return if (v == .decimal128) v.decimal128 else error.UnexpectedType,
        document.Datetime => return if (v == .datetime) v.datetime else error.UnexpectedType,
        document.Timestamp => return if (v == .timestamp) v.timestamp else error.UnexpectedType,
        document.Binary => return if (v == .binary) (try copied(v, arena, options)).binary else error.UnexpectedType,
        document.Regex => return if (v == .regex) (try copied(v, arena, options)).regex else error.UnexpectedType,
        document.DbPointer => return if (v == .db_pointer) (try copied(v, arena, options)).db_pointer else error.UnexpectedType,
        document.CodeWithScope => return if (v == .javascript_with_scope) (try copied(v, arena, options)).javascript_with_scope else error.UnexpectedType,
        else => {},
    }
    switch (@typeInfo(T)) {
        .bool => return if (v == .boolean) v.boolean else error.UnexpectedType,
        .int => return switch (v) {
            .int32 => |x| std.math.cast(T, x) orelse error.Overflow,
            .int64 => |x| std.math.cast(T, x) orelse error.Overflow,
            .double => |f| {
                if (!std.math.isFinite(f) or @trunc(f) != f) return error.Overflow;
                if (f < -0x1p63 or f >= 0x1p63) return error.Overflow;
                return std.math.cast(T, @as(i64, @intFromFloat(f))) orelse error.Overflow;
            },
            else => error.UnexpectedType,
        },
        .float => return switch (v) {
            .double => |f| @floatCast(f),
            .int32 => |x| @floatFromInt(x),
            .int64 => |x| @floatFromInt(x),
            else => error.UnexpectedType,
        },
        .optional => |info| return switch (v) {
            .null, .undefined => null,
            else => try decodeValue(info.child, arena, v, options),
        },
        .@"enum" => return switch (v) {
            .string => |s| std.meta.stringToEnum(T, s) orelse error.InvalidEnum,
            .int32 => |x| enumFromInt(T, x),
            .int64 => |x| enumFromInt(T, x),
            else => error.UnexpectedType,
        },
        .array => |info| {
            var out: T = undefined;
            if (info.child == u8) {
                if (v != .string) return error.UnexpectedType;
                if (v.string.len != info.len) return error.LengthMismatch;
                @memcpy(&out, v.string);
                return out;
            }
            if (v != .array) return error.UnexpectedType;
            var it = v.array.iterator();
            var i: usize = 0;
            while (it.next()) |item| : (i += 1) {
                if (i == info.len) return error.LengthMismatch;
                out[i] = try decodeValue(info.child, arena, item, options);
            }
            if (i != info.len) return error.LengthMismatch;
            return out;
        },
        .pointer => |p| switch (p.size) {
            .slice => {
                if (p.child == u8 and p.sentinel_ptr == null) {
                    const s = switch (v) {
                        .string, .symbol => |s| s,
                        else => return error.UnexpectedType,
                    };
                    return if (options.copy or !p.attrs.@"const") try arena.dupe(u8, s) else s;
                }
                if (p.sentinel_ptr != null) @compileError("bson: cannot decode into " ++ @typeName(T));
                if (v != .array) return error.UnexpectedType;
                const out = try arena.alloc(p.child, v.array.count());
                var it = v.array.iterator();
                for (out) |*slot| slot.* = try decodeValue(p.child, arena, it.next().?, options);
                return out;
            },
            .one => {
                const out = try arena.create(p.child);
                out.* = try decodeValue(p.child, arena, v, options);
                return out;
            },
            else => @compileError("bson: cannot decode into " ++ @typeName(T)),
        },
        .@"struct" => |info| {
            if (info.is_tuple) {
                if (v != .array) return error.UnexpectedType;
                var out: T = undefined;
                var it = v.array.iterator();
                inline for (info.field_names, info.field_types) |field, F| {
                    @field(out, field) = try decodeValue(F, arena, it.next() orelse return error.LengthMismatch, options);
                }
                if (it.next() != null) return error.LengthMismatch;
                return out;
            }
            if (v != .document) return error.UnexpectedType;
            return decodeStruct(T, arena, v.document, options);
        },
        else => @compileError("bson: cannot decode into " ++ @typeName(T)),
    }
}

fn copied(v: Value, arena: std.mem.Allocator, options: DecodeOptions) error{OutOfMemory}!Value {
    return if (options.copy) v.dupe(arena) else v;
}

fn enumFromInt(comptime T: type, x: anytype) MappingError!T {
    const Tag = @typeInfo(T).@"enum".tag_type;
    const tag = std.math.cast(Tag, x) orelse return error.InvalidEnum;
    return std.enums.fromInt(T, tag) orelse error.InvalidEnum;
}

fn decodeStruct(comptime T: type, arena: std.mem.Allocator, doc: Document, options: DecodeOptions) MappingError!T {
    const info = @typeInfo(T).@"struct";
    const n = info.field_names.len;
    const names = comptime blk: {
        var kvs: [n]struct { []const u8, usize } = undefined;
        for (info.field_names, 0..) |field, i| kvs[i] = .{ fieldName(T, field), i };
        break :blk std.StaticStringMap(usize).initComptime(kvs);
    };
    var out: T = undefined;
    var seen: [n]bool = @splat(false);
    var it = doc.iterator();
    while (it.next()) |e| {
        const index = names.get(e.name) orelse {
            if (!options.ignore_unknown_fields) return error.UnknownField;
            continue;
        };
        if (seen[index]) continue;
        seen[index] = true;
        inline for (info.field_names, info.field_types, 0..) |field, F, i| {
            if (i == index) @field(out, field) = try decodeValue(F, arena, e.value, options);
        }
    }
    inline for (info.field_names, info.field_types, info.field_attrs, 0..) |field, F, attrs, i| {
        if (!seen[i]) {
            if (attrs.defaultValue(F)) |default| {
                @field(out, field) = default;
            } else if (@typeInfo(F) == .optional) {
                @field(out, field) = null;
            } else {
                return error.MissingField;
            }
        }
    }
    return out;
}

const testing = std.testing;

const Role = enum { admin, user };
const Level = enum(u8) {
    low = 1,
    high = 9,
    pub const bson_enum: EnumRepr = .int;
};

const User = struct {
    id: ObjectId,
    name: []const u8,
    age: u16,
    score: f64 = 0,
    email: ?[]const u8 = null,
    nick: ?[]const u8,
    role: Role,
    level: Level,
    tags: []const []const u8,
    address: struct { city: []const u8, zip: ?u32 = null },
    created: document.Datetime,

    pub const bson_rename = .{ .id = "_id", .created = "createdAt" };
};

test "a struct round-trips with renames, optionals, enums and nesting" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const user: User = .{
        .id = try .parse("56e1fc72e0c917e9c4714161"),
        .name = "Ada",
        .age = 36,
        .nick = null,
        .role = .admin,
        .level = .high,
        .tags = &.{ "a", "b" },
        .address = .{ .city = "London" },
        .created = .{ .ms = 1356351330501 },
    };
    const bytes = try encode(testing.allocator, user, .{});
    defer testing.allocator.free(bytes);

    const doc = try Document.init(bytes);
    try testing.expect(doc.get("_id").? == .object_id);
    try testing.expect(doc.get("id") == null);
    try testing.expectEqual(36, doc.get("age").?.int32);
    try testing.expect(doc.get("email") == null);
    try testing.expectEqualStrings("admin", doc.get("role").?.string);
    try testing.expectEqual(9, doc.get("level").?.int32);
    try testing.expectEqualStrings("b", doc.getPath("tags.1").?.string);
    try testing.expect(doc.getPath("address.zip") == null);
    try testing.expectEqual(1356351330501, doc.get("createdAt").?.datetime.ms);

    const back = try decode(User, arena, bytes, .{});
    try testing.expectEqualStrings("Ada", back.name);
    try testing.expect(back.id.eql(user.id));
    try testing.expectEqual(null, back.email);
    try testing.expectEqual(Level.high, back.level);
    try testing.expectEqualStrings("b", back.tags[1]);
    try testing.expectEqualStrings("London", back.address.city);
    try testing.expectEqual(user.created, back.created);
    // Copied: nothing points into the encoded bytes.
    try testing.expect(@intFromPtr(back.name.ptr) < @intFromPtr(bytes.ptr) or @intFromPtr(back.name.ptr) >= @intFromPtr(bytes.ptr) + bytes.len);
}

test "anonymous literals encode as filters" {
    const bytes = try encode(testing.allocator, .{
        .age = .{ .@"$gte" = 18, .@"$lt" = 5_000_000_000 },
        .name = "x",
        .tags = .{ "a", 1, true },
        .sort = .asc,
        .gone = @as(?u8, null),
        .kept = null,
    }, .{});
    defer testing.allocator.free(bytes);
    const doc = try Document.init(bytes);
    try testing.expectEqual(18, doc.getPath("age.$gte").?.int32);
    try testing.expectEqual(5_000_000_000, doc.getPath("age.$lt").?.int64);
    try testing.expectEqual(3, doc.get("tags").?.array.count());
    try testing.expectEqualStrings("asc", doc.get("sort").?.string);
    try testing.expect(doc.get("gone") == null);
    try testing.expect(doc.get("kept").? == .null);
}

test "numbers decode leniently, within range" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(1, try decodeValue(i32, arena, .{ .double = 1.0 }, .{}));
    try testing.expectEqual(7, try decodeValue(u8, arena, .{ .int64 = 7 }, .{}));
    try testing.expectEqual(2.0, try decodeValue(f32, arena, .{ .int32 = 2 }, .{}));
    try testing.expectError(error.Overflow, decodeValue(u8, arena, .{ .int32 = 300 }, .{}));
    try testing.expectError(error.Overflow, decodeValue(i64, arena, .{ .double = 1.5 }, .{}));
    try testing.expectError(error.Overflow, decodeValue(i64, arena, .{ .double = 1e300 }, .{}));
    try testing.expectError(error.UnexpectedType, decodeValue(i64, arena, .{ .string = "1" }, .{}));
    try testing.expectEqual(Role.user, try decodeValue(Role, arena, .{ .int32 = 1 }, .{}));
    try testing.expectError(error.InvalidEnum, decodeValue(Role, arena, .{ .string = "root" }, .{}));
}

test "missing, unknown and duplicate fields" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const S = struct { a: i32, b: i32 = 5 };

    const dup = try encode(arena, .{ .a = 1, .x = 0 }, .{});
    try testing.expectEqual(S{ .a = 1, .b = 5 }, try decode(S, arena, dup, .{}));
    try testing.expectError(error.UnknownField, decode(S, arena, dup, .{ .ignore_unknown_fields = false }));
    const missing = try encode(arena, .{ .b = 1 }, .{});
    try testing.expectError(error.MissingField, decode(S, arena, missing, .{}));

    var b: Builder = .init(arena);
    try b.begin();
    try b.append("a", .{ .int32 = 1 });
    try b.append("a", .{ .int32 = 2 });
    try b.end();
    try testing.expectEqual(1, (try decode(S, arena, b.bytes(), .{})).a);
}

test "dynamic values, tuples and zero-copy decoding" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bytes = try encode(arena, .{ .any = .{ .x = 1 }, .pair = .{ "k", 2 }, .s = "text" }, .{});
    const S = struct { any: Value, pair: struct { []const u8, i64 }, s: []const u8 };
    const v = try decode(S, arena, bytes, .{ .copy = false });
    try testing.expectEqual(1, v.any.document.get("x").?.int32);
    try testing.expectEqualStrings("k", v.pair[0]);
    try testing.expectEqual(2, v.pair[1]);
    // Zero-copy: the string is a slice of the input.
    try testing.expect(@intFromPtr(v.s.ptr) > @intFromPtr(bytes.ptr) and @intFromPtr(v.s.ptr) < @intFromPtr(bytes.ptr) + bytes.len);
}

test "std.json: ObjectId as hex, dates as ISO strings, documents as relaxed Extended JSON" {
    const id = try ObjectId.parse("5f1f7f1f7f1f7f1f7f1f7f1f");
    const bytes = try encode(testing.allocator, .{ .n = 1, .d = document.Datetime{ .ms = 0 } }, .{});
    defer testing.allocator.free(bytes);
    const Out = struct { id: ObjectId, at: document.Datetime, doc: Document };
    const text = try std.json.Stringify.valueAlloc(testing.allocator, Out{ .id = id, .at = .{ .ms = 1_600_000_000_123 }, .doc = .{ .bytes = bytes } }, .{});
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        \\{"id":"5f1f7f1f7f1f7f1f7f1f7f1f","at":"2020-09-13T12:26:40.123Z","doc":{"n":1,"d":{"$date":"1970-01-01T00:00:00Z"}}}
    , text);
}
