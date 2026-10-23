// Adapted from vkiryakov/zefir src/log/encode.zig and src/log/fields.zig (MIT,
// Copyright (c) 2026 vkiryakov), commit dbcc967. See src/LICENSE.zefir and
// THIRD_PARTY_NOTICES.
//! The value writer of Anole's logger: the fields of one record as JSON
//! (`,"name":value`) or text (` name=value`), and the compile-time checks of
//! their names and types. Dropped from zefir: its call-site field, per-call
//! contexts and the compile-time rendering of literal fields.

const std = @import("std");
const escape = @import("escape.zig");
const redact = @import("redact.zig");

pub const Format = enum { json, text };

const Writer = std.Io.Writer;

/// Objects, arrays and unions nested deeper than this are written as
/// "[MAX_DEPTH]", so a cycle through pointers ends.
const max_depth = 8;
const depth_marker = "[MAX_DEPTH]";

/// Keys the record writes itself. A user field with one of these names
/// would collide with them.
pub const reserved = [_][]const u8{
    "time", "level", "scope", "message", "service", "request_id", "trace_id", "span_id", "truncated",
};

// ------------------------------------------------------------------ checks

/// Checks the fields of one call at compile time: a struct literal with
/// names that are not reserved, and values of writable types.
pub fn check(comptime Fields: type) void {
    @setEvalBranchQuota(1_000_000);
    const info = switch (@typeInfo(Fields)) {
        .@"struct" => |s| s,
        else => @compileError("anole.log: fields must be a struct literal such as .{ .user_id = id }, got '" ++ @typeName(Fields) ++ "'"),
    };
    if (info.is_tuple and info.field_names.len > 0)
        @compileError("anole.log: fields are named (.{ .user_id = id }); the message is fixed text; for a format string use std.log");
    if (redactsWhole(Fields))
        @compileError("anole.log: '" ++ @typeName(Fields) ++ "' is sensitive and cannot be the fields; log it as one field: .{ .key = key }");
    inline for (info.field_names, info.field_types) |name, T| {
        checkName(name, name);
        if (comptime !redact.isSensitiveName(name)) checkValue(name, T, &.{});
    }
}

fn checkName(comptime path: []const u8, comptime name: []const u8) void {
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.' and c != '-')
            @compileError("anole.log: field name '" ++ path ++ "' may contain only [A-Za-z0-9_.-]");
    }
    if (path.len == name.len) {
        for (reserved) |taken| {
            if (std.mem.eql(u8, name, taken))
                @compileError("anole.log: field name '" ++ name ++ "' is reserved for the record; rename it, e.g. 'user_" ++ name ++ "'");
        }
    }
}

fn checkValue(comptime path: []const u8, comptime T: type, comptime visited: []const type) void {
    checkMarker(path, T);
    if (redactsWhole(T)) return;
    for (visited) |seen| {
        if (seen == T) return;
    }
    const next = visited ++ [_]type{T};
    if (hasFormat(T) or isString(T)) return;
    switch (@typeInfo(T)) {
        .bool, .int, .float, .comptime_int, .comptime_float, .@"enum", .enum_literal, .error_set, .null, .type => {},
        .optional => |o| checkValue(path, o.child, next),
        .error_union => @compileError("anole.log: field '" ++ path ++ "': cannot log error union '" ++ @typeName(T) ++ "'; handle it with try or catch first"),
        .void => @compileError("anole.log: field '" ++ path ++ "': cannot log 'void'; remove the field"),
        .pointer => |p| switch (p.size) {
            .one => switch (@typeInfo(p.child)) {
                .@"opaque" => if (!hasFormat(p.child))
                    @compileError("anole.log: field '" ++ path ++ "': cannot log '" ++ @typeName(T) ++ "': an opaque type has no value to log"),
                .@"fn" => @compileError("anole.log: field '" ++ path ++ "': cannot log function '" ++ @typeName(T) ++ "'"),
                else => checkValue(path, p.child, next),
            },
            .slice => checkValue(path ++ "[]", p.child, next),
            .many => @compileError("anole.log: field '" ++ path ++ "': cannot log many-item pointer '" ++ @typeName(T) ++ "': it has no length; log a slice"),
            .c => @compileError("anole.log: field '" ++ path ++ "': cannot log C pointer '" ++ @typeName(T) ++ "'"),
        },
        .array => |a| checkValue(path ++ "[]", a.child, next),
        .vector => |v| checkValue(path ++ "[]", v.child, next),
        .@"struct" => |s| if (s.is_tuple) {
            inline for (s.field_types) |Item| checkValue(path ++ "[]", Item, next);
        } else {
            inline for (s.field_names, s.field_types) |name, Field| {
                if (Field == void) continue;
                checkName(path ++ "." ++ name, name);
                if (comptime !redact.isSensitiveName(name)) checkValue(path ++ "." ++ name, Field, next);
            }
        },
        .@"union" => |u| {
            if (u.tag_type == null)
                @compileError("anole.log: field '" ++ path ++ "': cannot log untagged union '" ++ @typeName(T) ++ "'; use union(enum)");
            inline for (u.field_names, u.field_types) |name, Payload| {
                checkName(path ++ "." ++ name, name);
                if (Payload != void and comptime !redact.isSensitiveName(name)) checkValue(path ++ "." ++ name, Payload, next);
            }
        },
        .@"fn" => @compileError("anole.log: field '" ++ path ++ "': cannot log function '" ++ @typeName(T) ++ "'"),
        else => @compileError("anole.log: field '" ++ path ++ "': cannot log '" ++ @typeName(T) ++ "'"),
    }
}

fn checkMarker(comptime path: []const u8, comptime T: type) void {
    switch (@typeInfo(T)) {
        .optional => |o| checkMarker(path, o.child),
        .pointer => |p| checkMarker(path, p.child),
        .array => |a| checkMarker(path, a.child),
        .vector => |v| checkMarker(path, v.child),
        .@"struct", .@"union", .@"enum", .@"opaque" => _ = redact.isSensitiveType(T),
        else => {},
    }
}

fn isContainer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => true,
        else => false,
    };
}

/// Whether a value of `T` is written as one "[REDACTED]": a type marked
/// `pub const anole_sensitive = true;`, or an optional, pointer, slice or
/// array around one.
pub fn redactsWhole(comptime T: type) bool {
    if (redact.isSensitiveType(T)) return true;
    return switch (@typeInfo(T)) {
        .optional => |o| redactsWhole(o.child),
        .pointer => |p| redactsWhole(p.child),
        .array => |a| redactsWhole(a.child),
        .vector => |v| redactsWhole(v.child),
        else => false,
    };
}

/// Whether `T` has `pub fn format(self: @This(), w: *std.Io.Writer) !void`
/// (self by value or `*const`); its output is logged as a string.
pub fn hasFormat(comptime T: type) bool {
    if (!isContainer(T) or !@hasDecl(T, "format")) return false;
    const f = switch (@typeInfo(@TypeOf(T.format))) {
        .@"fn" => |f| f,
        else => return false,
    };
    const name = "'" ++ @typeName(T) ++ ".format'";
    const hint = "write pub fn format(self: @This(), w: *std.Io.Writer) !void";
    const writer_ok = f.param_types.len == 2 and (f.param_types[1] == null or f.param_types[1].? == *Writer);
    const self_ok = f.param_types.len >= 1 and (f.param_types[0] == null or f.param_types[0].? == T or f.param_types[0].? == *const T);
    if (!self_ok or !writer_ok)
        @compileError("anole.log: " ++ name ++ " has another form than the one {f} uses; " ++ hint);
    return true;
}

/// Whether `T` is written as a string: a slice or array of bytes, or a
/// pointer to one.
pub fn isString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .array => |a| a.child == u8,
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| a.child == u8,
                else => false,
            },
            .many => p.child == u8 and p.sentinel() != null,
            .c => false,
        },
        else => false,
    };
}

// ------------------------------------------------------------------ writing

const Class = enum { redacted, format, string, scalar, optional, pointer, sequence, object, tagged };

fn classOf(comptime T: type) Class {
    if (redactsWhole(T)) return .redacted;
    if (hasFormat(T)) return .format;
    if (isString(T)) return .string;
    return switch (@typeInfo(T)) {
        .optional => .optional,
        .pointer => |p| if (p.size != .one)
            .sequence
        else if (@typeInfo(p.child) != .@"opaque")
            .pointer
        else
            .format,
        .array, .vector => .sequence,
        .@"struct" => |s| if (s.is_tuple) .sequence else .object,
        .@"union" => .tagged,
        else => .scalar,
    };
}

/// Writes the fields of one call: `,"name":value` each (JSON) or
/// ` name=value` each (text).
pub fn writeFields(comptime f: Format, w: *Writer, fields: anytype) Writer.Error!void {
    const s = @typeInfo(@TypeOf(fields)).@"struct";
    inline for (s.field_names) |name| {
        if (comptime redact.isSensitiveName(name)) {
            try w.writeAll(comptime key(f, name) ++ placeholderToken(f));
        } else {
            switch (f) {
                .json => {
                    try w.writeAll(comptime key(.json, name));
                    try writeJson(w, @field(fields, name), 0);
                },
                .text => try writeTextField(w, name, @field(fields, name), 0),
            }
        }
    }
}

/// One value as JSON (used by the record for its own members).
pub fn writeJsonValue(w: *Writer, value: anytype) Writer.Error!void {
    return writeJson(w, value, 0);
}

fn key(comptime f: Format, comptime name: []const u8) []const u8 {
    return switch (f) {
        .json => ",\"" ++ name ++ "\":",
        .text => " " ++ name ++ "=",
    };
}

fn writeJson(w: *Writer, value: anytype, comptime depth: u8) Writer.Error!void {
    const T = @TypeOf(value);
    const too_deep = "\"" ++ depth_marker ++ "\"";
    switch (comptime classOf(T)) {
        .redacted => try w.writeAll("\"" ++ redact.placeholder ++ "\""),
        .format => try writeFormatted(.json, w, value, false),
        .string => try writeString(.json, w, stringOf(&value), false),
        .scalar => try writeScalar(.json, w, value, false),
        .optional => if (value) |payload| try writeJson(w, payload, depth) else try w.writeAll("null"),
        .pointer => try writeJson(w, deref(value), depth),
        .sequence => if (depth == max_depth) try w.writeAll(too_deep) else {
            try w.writeByte('[');
            try writeItems(.json, w, value, depth + 1);
            try w.writeByte(']');
        },
        .object => if (depth == max_depth) try w.writeAll(too_deep) else {
            try w.writeByte('{');
            try writeMembers(.json, w, value, depth + 1);
            try w.writeByte('}');
        },
        .tagged => if (depth == max_depth) try w.writeAll(too_deep) else try writeTagged(.json, w, value, depth + 1),
    }
}

fn writeText(w: *Writer, value: anytype, comptime depth: u8, comptime nested: bool) Writer.Error!void {
    const T = @TypeOf(value);
    switch (comptime classOf(T)) {
        .redacted => try w.writeAll(redact.placeholder),
        .format => try writeFormatted(.text, w, value, nested),
        .string => try writeString(.text, w, stringOf(&value), nested),
        .scalar => try writeScalar(.text, w, value, nested),
        .optional => if (value) |payload| try writeText(w, payload, depth, nested) else try w.writeAll("null"),
        .pointer => try writeText(w, deref(value), depth, nested),
        .sequence => if (depth == max_depth) try w.writeAll(depth_marker) else {
            try w.writeByte('[');
            try writeItems(.text, w, value, depth + 1);
            try w.writeByte(']');
        },
        .object => if (depth == max_depth) try w.writeAll(depth_marker) else {
            try w.writeByte('{');
            try writeMembers(.text, w, value, depth + 1);
            try w.writeByte('}');
        },
        .tagged => if (depth == max_depth) try w.writeAll(depth_marker) else try writeTagged(.text, w, value, depth + 1),
    }
}

fn writeNested(comptime f: Format, w: *Writer, value: anytype, comptime depth: u8) Writer.Error!void {
    return switch (f) {
        .json => writeJson(w, value, depth),
        .text => writeText(w, value, depth, true),
    };
}

fn writeItems(comptime f: Format, w: *Writer, value: anytype, comptime depth: u8) Writer.Error!void {
    switch (@typeInfo(@TypeOf(value))) {
        .@"struct" => |s| inline for (s.field_names, 0..) |name, i| {
            if (i > 0) try w.writeByte(',');
            try writeNested(f, w, @field(value, name), depth);
        },
        .vector => |v| {
            const items: [v.len]v.child = value;
            for (items, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try writeNested(f, w, item, depth);
            }
        },
        else => for (value, 0..) |item, i| {
            if (i > 0) try w.writeByte(',');
            try writeNested(f, w, item, depth);
        },
    }
}

fn writeMembers(comptime f: Format, w: *Writer, value: anytype, comptime depth: u8) Writer.Error!void {
    const s = @typeInfo(@TypeOf(value)).@"struct";
    comptime var first = true;
    inline for (s.field_names, s.field_types) |name, Member| {
        if (Member == void) continue;
        try w.writeAll(comptime (if (first) "" else ",") ++ memberKey(f, name));
        first = false;
        if (comptime redact.isSensitiveName(name))
            try w.writeAll(comptime placeholderToken(f))
        else
            try writeNested(f, w, @field(value, name), depth);
    }
}

fn writeTagged(comptime f: Format, w: *Writer, value: anytype, comptime depth: u8) Writer.Error!void {
    switch (value) {
        inline else => |payload, tag| {
            const name = @tagName(tag);
            try w.writeAll(comptime "{" ++ memberKey(f, name));
            if (comptime redact.isSensitiveName(name))
                try w.writeAll(comptime placeholderToken(f))
            else if (@TypeOf(payload) == void)
                try w.writeAll("{}")
            else
                try writeNested(f, w, payload, depth);
            try w.writeByte('}');
        },
    }
}

fn memberKey(comptime f: Format, comptime name: []const u8) []const u8 {
    return switch (f) {
        .json => "\"" ++ name ++ "\":",
        .text => name ++ "=",
    };
}

fn placeholderToken(comptime f: Format) []const u8 {
    return switch (f) {
        .json => "\"" ++ redact.placeholder ++ "\"",
        .text => redact.placeholder,
    };
}

fn writeTextField(w: *Writer, comptime path: []const u8, value: anytype, comptime depth: u8) Writer.Error!void {
    const T = @TypeOf(value);
    if (depth < max_depth) switch (comptime classOf(T)) {
        .pointer => if (@typeInfo(@typeInfo(T).pointer.child) != .array) return writeTextField(w, path, value.*, depth),
        .object => {
            const s = @typeInfo(T).@"struct";
            comptime var empty = true;
            inline for (s.field_names, s.field_types) |name, Member| {
                if (Member == void) continue;
                empty = false;
                const member = path ++ "." ++ name;
                if (comptime redact.isSensitiveName(name))
                    try w.writeAll(" " ++ member ++ "=" ++ redact.placeholder)
                else
                    try writeTextField(w, member, @field(value, name), depth + 1);
            }
            if (empty) try w.writeAll(" " ++ path ++ "={}");
            return;
        },
        .tagged => switch (value) {
            inline else => |payload, tag| {
                const member = path ++ "." ++ @tagName(tag);
                if (comptime redact.isSensitiveName(@tagName(tag)))
                    try w.writeAll(" " ++ member ++ "=" ++ redact.placeholder)
                else if (@TypeOf(payload) == void)
                    try w.writeAll(" " ++ member ++ "={}")
                else
                    try writeTextField(w, member, payload, depth + 1);
                return;
            },
        },
        else => {},
    };
    try w.writeAll(" " ++ path ++ "=");
    try writeText(w, value, depth, false);
}

fn writeFormatted(comptime f: Format, w: *Writer, value: anytype, comptime nested: bool) Writer.Error!void {
    if (f == .json) try w.writeByte('"');
    const start = w.end;
    var e: escape.Escaper = undefined;
    e.init(w);
    e.strict = nested;
    if (@TypeOf(value) == std.Uri) try writeUri(&e.writer, &value) else try value.format(&e.writer);
    try e.finish();
    if (f == .json) return w.writeByte('"');
    if (e.plain and e.count > 0) return;
    std.debug.assert(w.end - start == e.count);
    if (w.unusedCapacityLen() < 2) return error.WriteFailed;
    @memmove(w.buffer[start + 1 ..][0..e.count], w.buffer[start..][0..e.count]);
    w.buffer[start] = '"';
    w.end += 1;
    try w.writeByte('"');
}

fn writeUri(w: *Writer, uri: *const std.Uri) Writer.Error!void {
    if (uri.password == null or uri.user == null or uri.host == null) return uri.format(w);
    try w.print("{s}://", .{uri.scheme});
    try uri.user.?.formatUser(w);
    try w.writeAll(":" ++ redact.placeholder ++ "@");
    try uri.writeToStream(w, .{ .authority = true, .path = true, .query = true, .fragment = true });
}

fn stringOf(ptr: anytype) []const u8 {
    const T = @typeInfo(@TypeOf(ptr)).pointer.child;
    return switch (@typeInfo(T)) {
        .array => ptr,
        .pointer => |p| switch (p.size) {
            .slice, .one => ptr.*,
            .many => std.mem.span(ptr.*),
            .c => unreachable,
        },
        else => unreachable,
    };
}

fn deref(ptr: anytype) Deref(@TypeOf(ptr)) {
    return switch (@typeInfo(@typeInfo(@TypeOf(ptr)).pointer.child)) {
        .array => ptr,
        else => ptr.*,
    };
}

fn Deref(comptime P: type) type {
    const Child = @typeInfo(P).pointer.child;
    return switch (@typeInfo(Child)) {
        .array => |a| []const a.child,
        else => Child,
    };
}

fn writeScalar(comptime f: Format, w: *Writer, value: anytype, comptime nested: bool) Writer.Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .bool => try w.writeAll(if (value) "true" else "false"),
        .int => |int| if (int.bits <= 64) try w.print("{d}", .{value}) else try writeQuotedDigits(f, w, value),
        .comptime_int => if (value >= std.math.minInt(i64) and value <= std.math.maxInt(u64))
            try w.print("{d}", .{value})
        else
            try writeQuotedDigits(f, w, value),
        .float => try writeFloat(f, w, value),
        .comptime_float => try writeFloat(f, w, @as(f128, value)),
        .null => try w.writeAll("null"),
        .@"enum" => |e| if (e.mode == .exhaustive)
            try writeString(f, w, @tagName(value), nested)
        else if (std.enums.tagName(T, value)) |name|
            try writeString(f, w, name, nested)
        else
            try writeQuotedDigits(f, w, @backingInt(value)),
        .enum_literal => try writeString(f, w, @tagName(value), nested),
        .error_set => try writeString(f, w, @errorName(value), nested),
        .type => try writeString(f, w, @typeName(value), nested),
        else => @compileError("unreachable: check lets no other type through"),
    }
}

fn writeString(comptime f: Format, w: *Writer, s: []const u8, comptime nested: bool) Writer.Error!void {
    if (f == .text and escape.isBare(s) and !(nested and std.mem.findAny(u8, s, ",[]{}") != null))
        return w.writeAll(s);
    try w.writeByte('"');
    try escape.write(w, s);
    try w.writeByte('"');
}

fn writeQuotedDigits(comptime f: Format, w: *Writer, value: anytype) Writer.Error!void {
    if (f == .json) try w.writeByte('"');
    try w.print("{d}", .{value});
    if (f == .json) try w.writeByte('"');
}

fn writeFloat(comptime f: Format, w: *Writer, value: anytype) Writer.Error!void {
    const quote = if (f == .json) "\"" else "";
    if (std.math.isNan(value)) return w.writeAll(quote ++ "NaN" ++ quote);
    if (std.math.isInf(value)) return w.writeAll(if (value > 0) quote ++ "+Inf" ++ quote else quote ++ "-Inf" ++ quote);
    const Wide = if (@typeInfo(@TypeOf(value)).float.bits <= 64) f64 else f128;
    const magnitude: Wide = @abs(value);
    if (magnitude == 0 or (magnitude >= 1e-6 and magnitude < 1e21)) {
        try w.print("{d}", .{value});
    } else {
        try w.print("{e}", .{value});
    }
}

// ------------------------------------------------------------------ tests

fn expectFields(fields: anytype, comptime json: []const u8, comptime text: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeFields(.json, &w, fields);
    try std.testing.expectEqualStrings(json, w.buffered());
    w = .fixed(&buf);
    try writeFields(.text, &w, fields);
    try std.testing.expectEqualStrings(text, w.buffered());
}

test "scalars, strings, optionals and enums" {
    const E = enum { a, b };
    try expectFields(.{ .n = 5, .ok = true, .s = "hi there", .o = @as(?u8, null), .e = E.b },
        ",\"n\":5,\"ok\":true,\"s\":\"hi there\",\"o\":null,\"e\":\"b\"",
        " n=5 ok=true s=\"hi there\" o=null e=b");
}

test "redaction by name and by marker" {
    const Key = struct {
        raw: []const u8,
        pub const anole_sensitive = true;
    };
    try expectFields(.{ .password = "x", .k = Key{ .raw = "abc" } },
        ",\"password\":\"[REDACTED]\",\"k\":\"[REDACTED]\"",
        " password=[REDACTED] k=[REDACTED]");
}

test "nested objects and lists" {
    try expectFields(.{ .p = .{ .host = "pg", .port = @as(u16, 5432) }, .xs = [_]u8{ 1, 2 } },
        ",\"p\":{\"host\":\"pg\",\"port\":5432},\"xs\":[1,2]",
        " p.host=pg p.port=5432 xs=[1,2]");
}

test "control bytes are escaped and invalid UTF-8 replaced" {
    try expectFields(.{ .s = "a\nb\xff" }, ",\"s\":\"a\\nb\\ufffd\"", " s=\"a\\nb\\ufffd\"");
}
