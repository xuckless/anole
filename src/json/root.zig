//! JSON on yyjson (ibireme/yyjson, MIT), mapped onto Zig types:
//!
//!     const User = struct { id: u64, name: []const u8, tags: []const []const u8 = &.{}, admin: ?bool = null };
//!     const user = try anole.json.parse(User, arena, body, .{});
//!     const text = try anole.json.stringify(arena, user, .{});
//!
//! In a handler, `req.bind(User)` and `res.json(value)` (std.json, in every
//! build) are the usual way; `try anole.json.readBody(User, req)` and
//! `try anole.json.respond(res, value)` are the same contract on yyjson,
//! for large documents.
//!
//! Everything is allocated from the allocator given, which should be an
//! arena (the request's): yyjson's document lives there, and parsed strings
//! point into it rather than being copied.
//!
//! Mapping: structs are objects (fields by name; a missing field takes its
//! default, or null for an optional, else it is an error), optionals take
//! null, slices are arrays (`[]const u8` is a string), enums are their tag
//! names, bool and numbers as such (integers range-checked).
const std = @import("std");
const c = @import("anole_yyjson_c");
const dusty = @import("dusty");

/// How `parse` (and `readBody`) maps a document onto a type.
pub const ParseOptions = struct {
    /// Object keys with no field are skipped; false makes them an error.
    ignore_unknown_fields: bool = true,
    /// yyjson read flags (`YYJSON_READ_*`), e.g. to allow comments.
    flags: u32 = 0,
};

/// How `stringify` (and `respond`) writes a value.
pub const StringifyOptions = struct {
    /// Indent the output; compact by default.
    pretty: bool = false,
    /// Optional fields that are null are left out instead of written as null.
    omit_null_fields: bool = false,
};

/// What `parse` fails with.
pub const Error = error{
    /// Not JSON.
    SyntaxError,
    /// A value of another kind than the field's type (a string for a
    /// number, say).
    UnexpectedType,
    /// An object lacks a field that has no default and is not optional.
    MissingField,
    /// An object key with no field, under `ignore_unknown_fields = false`.
    UnknownField,
    /// A number out of the integer type's range.
    Overflow,
    /// A string that names no tag of the enum.
    InvalidEnumTag,
    OutOfMemory,
};

/// yyjson's allocator hooks over a Zig arena: yyjson passes the old size
/// to realloc, and freeing waits for the arena.
fn alcFor(arena: *const std.mem.Allocator) c.yyjson_alc {
    return .{ .malloc = alcMalloc, .realloc = alcRealloc, .free = alcFree, .ctx = @constCast(arena) };
}

fn alcMalloc(ctx: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    const a: *const std.mem.Allocator = @ptrCast(@alignCast(ctx.?));
    const mem = a.alignedAlloc(u8, .@"16", @max(size, 1)) catch return null;
    return mem.ptr;
}

fn alcRealloc(ctx: ?*anyopaque, ptr: ?*anyopaque, old_size: usize, size: usize) callconv(.c) ?*anyopaque {
    const a: *const std.mem.Allocator = @ptrCast(@alignCast(ctx.?));
    const new = a.alignedAlloc(u8, .@"16", @max(size, 1)) catch return null;
    if (ptr) |p| {
        const old: [*]const u8 = @ptrCast(p);
        @memcpy(new[0..@min(old_size, size)], old[0..@min(old_size, size)]);
    }
    return new.ptr;
}

fn alcFree(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {}

/// Parses `input` into a `T`, allocating from `arena`.
pub fn parse(comptime T: type, arena: std.mem.Allocator, input: []const u8, options: ParseOptions) Error!T {
    const alc = alcFor(&arena);
    var err: c.yyjson_read_err = undefined;
    const doc = c.yyjson_read_opts(@constCast(input.ptr), input.len, options.flags, &alc, &err) orelse {
        return if (err.code == c.YYJSON_READ_ERROR_MEMORY_ALLOCATION) error.OutOfMemory else error.SyntaxError;
    };
    return fromValue(T, arena, c.yyjson_doc_get_root(doc), options);
}

fn typeOf(v: ?*c.yyjson_val) u8 {
    return @intCast(c.yyjson_get_type(v));
}

fn fromValue(comptime T: type, arena: std.mem.Allocator, v: ?*c.yyjson_val, options: ParseOptions) Error!T {
    const t = typeOf(v);
    switch (@typeInfo(T)) {
        .optional => |o| {
            if (t == c.YYJSON_TYPE_NULL) return null;
            return try fromValue(o.child, arena, v, options);
        },
        .bool => {
            if (t != c.YYJSON_TYPE_BOOL) return error.UnexpectedType;
            return c.yyjson_get_bool(v);
        },
        .int => {
            if (t != c.YYJSON_TYPE_NUM) return error.UnexpectedType;
            const sub: u8 = @intCast(c.yyjson_get_subtype(v));
            if (sub == c.YYJSON_SUBTYPE_UINT) return std.math.cast(T, c.yyjson_get_uint(v)) orelse error.Overflow;
            if (sub == c.YYJSON_SUBTYPE_SINT) return std.math.cast(T, c.yyjson_get_sint(v)) orelse error.Overflow;
            // A real with no fraction is still a whole number.
            const f = c.yyjson_get_real(v);
            if (@floor(f) != f or !std.math.isFinite(f)) return error.UnexpectedType;
            if (f < @as(f64, @floatFromInt(std.math.minInt(T))) or f > @as(f64, @floatFromInt(std.math.maxInt(T)))) return error.Overflow;
            return @intFromFloat(f);
        },
        .float => {
            if (t != c.YYJSON_TYPE_NUM) return error.UnexpectedType;
            return @floatCast(c.yyjson_get_num(v));
        },
        .@"enum" => |e| {
            if (t == c.YYJSON_TYPE_STR) {
                const name = c.yyjson_get_str(v)[0..c.yyjson_get_len(v)];
                return std.meta.stringToEnum(T, name) orelse error.InvalidEnumTag;
            }
            if (t == c.YYJSON_TYPE_NUM) {
                const n = try fromValue(e.tag_type, arena, v, options);
                return std.enums.fromInt(T, n) orelse error.InvalidEnumTag;
            }
            return error.UnexpectedType;
        },
        .pointer => |p| {
            if (p.size != .slice) @compileError("anole.json: unsupported pointer type " ++ @typeName(T));
            if (p.child == u8 and t == c.YYJSON_TYPE_STR) {
                // Lives in the document, in the arena.
                return c.yyjson_get_str(v)[0..c.yyjson_get_len(v)];
            }
            if (t != c.YYJSON_TYPE_ARR) return error.UnexpectedType;
            const out = try arena.alloc(p.child, c.yyjson_arr_size(v));
            var it: c.yyjson_arr_iter = undefined;
            _ = c.yyjson_arr_iter_init(v, &it);
            for (out) |*slot| slot.* = try fromValue(p.child, arena, c.yyjson_arr_iter_next(&it), options);
            return out;
        },
        .array => |a| {
            if (t != c.YYJSON_TYPE_ARR or c.yyjson_arr_size(v) != a.len) return error.UnexpectedType;
            var out: T = undefined;
            var it: c.yyjson_arr_iter = undefined;
            _ = c.yyjson_arr_iter_init(v, &it);
            for (&out) |*slot| slot.* = try fromValue(a.child, arena, c.yyjson_arr_iter_next(&it), options);
            return out;
        },
        .@"struct" => |s| {
            if (t != c.YYJSON_TYPE_OBJ) return error.UnexpectedType;
            var out: T = undefined;
            inline for (s.field_names, s.field_types, s.field_attrs) |name, F, attrs| {
                const field = c.yyjson_obj_getn(v, name.ptr, name.len);
                if (field != null) {
                    @field(out, name) = try fromValue(F, arena, field, options);
                } else if (comptime attrs.defaultValue(F)) |d| {
                    @field(out, name) = d;
                } else if (@typeInfo(F) == .optional) {
                    @field(out, name) = null;
                } else {
                    return error.MissingField;
                }
            }
            if (!options.ignore_unknown_fields) {
                var it: c.yyjson_obj_iter = undefined;
                _ = c.yyjson_obj_iter_init(v, &it);
                while (c.yyjson_obj_iter_next(&it)) |key| {
                    const k = c.yyjson_get_str(key)[0..c.yyjson_get_len(key)];
                    const known = inline for (s.field_names) |name| {
                        if (std.mem.eql(u8, k, name)) break true;
                    } else false;
                    if (!known) return error.UnknownField;
                }
            }
            return out;
        },
        else => @compileError("anole.json: unsupported type " ++ @typeName(T)),
    }
}

/// `value` as JSON text, allocated from `arena`.
pub fn stringify(arena: std.mem.Allocator, value: anytype, options: StringifyOptions) Error![]const u8 {
    const alc = alcFor(&arena);
    const doc = c.yyjson_mut_doc_new(&alc) orelse return error.OutOfMemory;
    const root = try toValue(doc, value, options);
    c.yyjson_mut_doc_set_root(doc, root);
    var len: usize = 0;
    var err: c.yyjson_write_err = undefined;
    const flags: u32 = if (options.pretty) c.YYJSON_WRITE_PRETTY else 0;
    const text = c.yyjson_mut_write_opts(doc, flags, &alc, &len, &err) orelse return error.OutOfMemory;
    return text[0..len];
}

fn toValue(doc: *c.yyjson_mut_doc, value: anytype, options: StringifyOptions) Error!*c.yyjson_mut_val {
    const T = @TypeOf(value);
    const v: ?*c.yyjson_mut_val = switch (@typeInfo(T)) {
        .optional => if (value) |inner| return toValue(doc, inner, options) else c.yyjson_mut_null(doc),
        .bool => c.yyjson_mut_bool(doc, value),
        .int, .comptime_int => if (value < 0) c.yyjson_mut_sint(doc, @intCast(value)) else c.yyjson_mut_uint(doc, @intCast(value)),
        .float, .comptime_float => c.yyjson_mut_real(doc, @floatCast(value)),
        .@"enum" => blk: {
            const name = @tagName(value);
            break :blk c.yyjson_mut_strn(doc, name.ptr, name.len);
        },
        .pointer => |p| blk: {
            if (p.size == .one) return toValue(doc, value.*, options);
            if (p.size != .slice) @compileError("anole.json: unsupported pointer type " ++ @typeName(T));
            if (p.child == u8) break :blk c.yyjson_mut_strncpy(doc, value.ptr, value.len);
            const arr = c.yyjson_mut_arr(doc) orelse return error.OutOfMemory;
            for (value) |item| _ = c.yyjson_mut_arr_append(arr, try toValue(doc, item, options));
            break :blk arr;
        },
        .array => blk: {
            const arr = c.yyjson_mut_arr(doc) orelse return error.OutOfMemory;
            for (value) |item| _ = c.yyjson_mut_arr_append(arr, try toValue(doc, item, options));
            break :blk arr;
        },
        .@"struct" => |s| blk: {
            const obj = c.yyjson_mut_obj(doc) orelse return error.OutOfMemory;
            inline for (s.field_names) |name| {
                const field = @field(value, name);
                const skip = options.omit_null_fields and @typeInfo(@TypeOf(field)) == .optional and field == null;
                if (!skip) {
                    const key = c.yyjson_mut_strn(doc, name.ptr, name.len);
                    _ = c.yyjson_mut_obj_add(obj, key, try toValue(doc, field, options));
                }
            }
            break :blk obj;
        },
        else => @compileError("anole.json: unsupported type " ++ @typeName(T)),
    };
    return v orelse error.OutOfMemory;
}

/// The request body parsed as a `T` with yyjson, in the request's arena:
/// `req.bind(T)`'s contract on the faster parser. Unknown fields are
/// ignored; a request without a body fails with `error.MissingBody`, and
/// one that is not JSON or does not fit `T` with `error.InvalidJsonBody`,
/// both answered 400.
pub fn readBody(comptime T: type, req: *dusty.Request) !T {
    const body = (try req.body()) orelse return error.MissingBody;
    return parse(T, req.arena, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidJsonBody,
    };
}

/// Sends `value` as the JSON body, with its content type.
pub fn respond(res: *dusty.Response, value: anytype) !void {
    res.content_type = .json;
    res.body = try stringify(res.arena, value, .{});
}

test "parse: structs, defaults, optionals, slices, enums and numbers" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Role = enum { admin, user };
    const User = struct {
        id: u64,
        name: []const u8,
        role: Role = .user,
        score: f64 = 0,
        tags: []const []const u8 = &.{},
        nickname: ?[]const u8 = null,
        point: [2]i32 = .{ 0, 0 },
    };
    const u = try parse(User, arena,
        \\{"id": 7, "name": "ann", "role": "admin", "score": 1.5, "tags": ["a","b"], "point": [1, -2], "extra": {"x": 1}}
    , .{});
    try std.testing.expectEqual(@as(u64, 7), u.id);
    try std.testing.expectEqualStrings("ann", u.name);
    try std.testing.expectEqual(Role.admin, u.role);
    try std.testing.expectEqual(@as(f64, 1.5), u.score);
    try std.testing.expectEqualStrings("b", u.tags[1]);
    try std.testing.expect(u.nickname == null);
    try std.testing.expectEqual(@as(i32, -2), u.point[1]);

    try std.testing.expectError(error.MissingField, parse(User, arena, "{\"id\": 1}", .{}));
    try std.testing.expectError(error.UnknownField, parse(User, arena, "{\"id\":1,\"name\":\"x\",\"zzz\":0}", .{ .ignore_unknown_fields = false }));
    try std.testing.expectError(error.Overflow, parse(u8, arena, "300", .{}));
    try std.testing.expectError(error.UnexpectedType, parse(u8, arena, "\"7\"", .{}));
    try std.testing.expectError(error.SyntaxError, parse(u8, arena, "{", .{}));
}

test "readBody: bind's contract, answered 400 by the server" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var req: dusty.Request = .{ .arena = arena_state.allocator(), .parser = undefined, .transport = undefined };
    const T = struct { name: []const u8 };
    req._body_read = true;
    req._body = null;
    try std.testing.expectError(error.MissingBody, readBody(T, &req));
    req._body = "{\"name\":\"ann\",\"extra\":1}";
    try std.testing.expectEqualStrings("ann", (try readBody(T, &req)).name);
    req._body = "{\"name\":7}";
    try std.testing.expectError(error.InvalidJsonBody, readBody(T, &req));
    req._body = "{";
    try std.testing.expectError(error.InvalidJsonBody, readBody(T, &req));
    try std.testing.expectEqual(dusty.Status.bad_request, dusty.errorStatus(error.InvalidJsonBody).?);
    try std.testing.expectEqual(dusty.Status.bad_request, dusty.errorStatus(error.MissingBody).?);
}

test "stringify round-trips through parse" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Item = struct { name: []const u8, qty: u32, price: f64, note: ?[]const u8 = null, ok: bool = true };
    const items = [_]Item{ .{ .name = "a\"b", .qty = 2, .price = 9.5 }, .{ .name = "c", .qty = 0, .price = -1, .note = "n" } };
    const text = try stringify(arena, &items, .{ .omit_null_fields = true });
    try std.testing.expect(std.mem.indexOf(u8, text, "\"note\"") != null);
    try std.testing.expectEqualStrings(
        \\[{"name":"a\"b","qty":2,"price":9.5,"ok":true},{"name":"c","qty":0,"price":-1.0,"note":"n","ok":true}]
    , text);
    const back = try parse([]const Item, arena, text, .{});
    try std.testing.expectEqualStrings("a\"b", back[0].name);
    try std.testing.expectEqualStrings("n", back[1].note.?);
}

test "fuzz: JSON into a struct" {
    try @import("../fuzz.zig").bytes(struct {
        const T = struct {
            name: []const u8 = "",
            age: ?i64 = null,
            tags: []const []const u8 = &.{},
            scores: []const i32 = &.{},
            inner: ?struct { ok: bool = false, ratio: f64 = 0 } = null,
            kind: enum { a, b } = .a,
        };
        fn check(input: []const u8) !void {
            var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena_state.deinit();
            _ = parse(T, arena_state.allocator(), input, .{}) catch return;
        }
    }.check, &.{
        \\{"name":"anole","age":3,"tags":["a","b"],"scores":[1,-2,3],"inner":{"ok":true,"ratio":0.5},"kind":"b"}
        ,
        \\{"name":"\u00e9\ud83d\ude00","age":9223372036854775807,"scores":[2147483648]}
        ,
        \\{"inner":null,"extra":{"deep":[[[[[]]]]]}}
        ,
        "[1,2,3]",
    });
}
