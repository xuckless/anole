//! MongoDB Extended JSON v2 (specifications/source/extended-json/
//! extended-json.md): canonical and relaxed output, and a parser that takes
//! either form back to BSON (legacy forms are not accepted).
//!
//! Output is compact (no spaces), keeps BSON's key order, and is meant for
//! logs, the JSON layer and tests; JSON objects are unordered and `$`-keys
//! are ambiguous, so it is not a faithful round trip of every document.
const std = @import("std");
const document = @import("document.zig");
const Builder = @import("Builder.zig");
const ObjectId = @import("ObjectId.zig");
const Decimal128 = @import("Decimal128.zig");
const Value = document.Value;
const Document = document.Document;

pub const Mode = enum {
    /// Every type in a wrapper (`{"$numberInt": "1"}`): type-preserving.
    canonical,
    /// Plain JSON numbers and ISO dates where they fit: readable.
    relaxed,
};

const Writer = std.Io.Writer;

pub fn write(w: *Writer, doc: Document, mode: Mode) Writer.Error!void {
    try w.writeByte('{');
    var it = doc.iterator();
    var first = true;
    while (it.next()) |e| {
        if (!first) try w.writeByte(',');
        first = false;
        try writeString(w, e.name);
        try w.writeByte(':');
        try writeValue(w, e.value, mode);
    }
    try w.writeByte('}');
}

/// `doc` as Extended JSON through `{f}`.
pub fn fmt(doc: Document, mode: Mode) Formatter {
    return .{ .doc = doc, .mode = mode };
}

pub const Formatter = struct {
    doc: Document,
    mode: Mode,

    pub fn format(f: Formatter, w: *Writer) Writer.Error!void {
        return write(w, f.doc, f.mode);
    }
};

/// `doc` as Extended JSON, owned by the caller.
pub fn allocPrint(gpa: std.mem.Allocator, doc: Document, mode: Mode) error{OutOfMemory}![]u8 {
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    write(&out.writer, doc, mode) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

pub fn writeValue(w: *Writer, v: Value, mode: Mode) Writer.Error!void {
    switch (v) {
        .double => |f| {
            if (!std.math.isFinite(f)) {
                try w.writeAll("{\"$numberDouble\":\"");
                try w.writeAll(if (std.math.isNan(f)) "NaN" else if (f > 0) "Infinity" else "-Infinity");
                return w.writeAll("\"}");
            }
            if (mode == .relaxed) return writeDouble(w, f);
            try w.writeAll("{\"$numberDouble\":\"");
            try writeDouble(w, f);
            try w.writeAll("\"}");
        },
        .string => |s| try writeString(w, s),
        .document => |d| try write(w, d, mode),
        .array => |a| {
            try w.writeByte('[');
            var it = a.iterator();
            var first = true;
            while (it.next()) |item| {
                if (!first) try w.writeByte(',');
                first = false;
                try writeValue(w, item, mode);
            }
            try w.writeByte(']');
        },
        .binary => |b| {
            try w.writeAll("{\"$binary\":{\"base64\":\"");
            try std.base64.standard.Encoder.encodeWriter(w, b.data);
            try w.print("\",\"subType\":\"{x:0>2}\"}}}}", .{@backingInt(b.subtype)});
        },
        .undefined => try w.writeAll("{\"$undefined\":true}"),
        .object_id => |id| try w.print("{{\"$oid\":\"{f}\"}}", .{id}),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .datetime => |d| {
            // ISO-8601 only for years 1970 to 9999, as the spec says.
            if (mode == .relaxed and d.ms >= 0 and d.ms <= max_iso_ms) {
                try w.writeAll("{\"$date\":\"");
                try writeIsoDate(w, d.ms);
                return w.writeAll("\"}");
            }
            try w.print("{{\"$date\":{{\"$numberLong\":\"{d}\"}}}}", .{d.ms});
        },
        .null => try w.writeAll("null"),
        .regex => |r| {
            try w.writeAll("{\"$regularExpression\":{\"pattern\":");
            try writeString(w, r.pattern);
            try w.writeAll(",\"options\":");
            try writeSortedOptions(w, r.options);
            try w.writeAll("}}");
        },
        .db_pointer => |p| {
            try w.writeAll("{\"$dbPointer\":{\"$ref\":");
            try writeString(w, p.namespace);
            try w.print(",\"$id\":{{\"$oid\":\"{f}\"}}}}}}", .{p.id});
        },
        .javascript => |s| {
            try w.writeAll("{\"$code\":");
            try writeString(w, s);
            try w.writeByte('}');
        },
        .symbol => |s| {
            try w.writeAll("{\"$symbol\":");
            try writeString(w, s);
            try w.writeByte('}');
        },
        .javascript_with_scope => |c| {
            try w.writeAll("{\"$code\":");
            try writeString(w, c.code);
            try w.writeAll(",\"$scope\":");
            try write(w, c.scope, mode);
            try w.writeByte('}');
        },
        .int32 => |x| if (mode == .relaxed) try w.print("{d}", .{x}) else try w.print("{{\"$numberInt\":\"{d}\"}}", .{x}),
        .int64 => |x| if (mode == .relaxed) try w.print("{d}", .{x}) else try w.print("{{\"$numberLong\":\"{d}\"}}", .{x}),
        .timestamp => |t| try w.print("{{\"$timestamp\":{{\"t\":{d},\"i\":{d}}}}}", .{ t.t, t.i }),
        .decimal128 => |d| try w.print("{{\"$numberDecimal\":\"{f}\"}}", .{d}),
        .min_key => try w.writeAll("{\"$minKey\":1}"),
        .max_key => try w.writeAll("{\"$maxKey\":1}"),
    }
}

/// A JSON string: quotes, backslashes and control characters escaped,
/// everything else (valid UTF-8 after validation) as it is.
pub fn writeString(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    var start: usize = 0;
    for (s, 0..) |c, i| {
        if (c >= 0x20 and c != '"' and c != '\\') continue;
        try w.writeAll(s[start..i]);
        try writeEscaped(w, c);
        start = i + 1;
    }
    try w.writeAll(s[start..]);
    try w.writeByte('"');
}

fn writeEscaped(w: *Writer, c: u8) Writer.Error!void {
    switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x08 => try w.writeAll("\\b"),
        0x0C => try w.writeAll("\\f"),
        0x00...0x07, 0x0B, 0x0E...0x1F => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    }
}

/// Regex flags in alphabetical order (the spec's requirement for output).
/// Non-ASCII flags, which no server accepts, are left as they are rather
/// than split mid-character.
fn writeSortedOptions(w: *Writer, options: []const u8) Writer.Error!void {
    for (options) |c| if (c >= 0x80) return writeString(w, options);
    var counts: [128]u32 = @splat(0);
    for (options) |c| counts[c] += 1;
    try w.writeByte('"');
    for (counts, 0..) |n, c| {
        for (0..n) |_| try writeEscaped(w, @intCast(c));
    }
    try w.writeByte('"');
}

/// The shortest decimal that reads back as `f`, always with a fraction or
/// an exponent so relaxed JSON keeps it a double: "1.0", "0.001",
/// "1.2345678921232E+18" (scientific below 1e-4 and from 1e16, as Python's
/// repr).
fn writeDouble(w: *Writer, f: f64) Writer.Error!void {
    var buf: [std.fmt.float.min_buffer_size]u8 = undefined;
    const sci = std.fmt.float.render(&buf, f, .{ .mode = .scientific }) catch unreachable;
    // "[-]D[.DDD]e[-]X"
    const e = std.mem.indexOfScalar(u8, sci, 'e').?;
    const exp = std.fmt.parseInt(i32, sci[e + 1 ..], 10) catch unreachable;
    var mantissa = sci[0..e];
    if (mantissa[0] == '-') {
        try w.writeByte('-');
        mantissa = mantissa[1..];
    }
    var digit_buf: [24]u8 = undefined;
    var n: usize = 0;
    for (mantissa) |c| if (c != '.') {
        digit_buf[n] = c;
        n += 1;
    };
    const digits = digit_buf[0..n];

    if (exp >= -5 and exp < 16) {
        if (exp >= 0) {
            const int_len: usize = @intCast(exp + 1);
            if (n <= int_len) {
                try w.writeAll(digits);
                try w.splatByteAll('0', int_len - n);
                try w.writeAll(".0");
            } else {
                try w.writeAll(digits[0..int_len]);
                try w.writeByte('.');
                try w.writeAll(digits[int_len..]);
            }
        } else {
            try w.writeAll("0.");
            try w.splatByteAll('0', @intCast(-exp - 1));
            try w.writeAll(digits);
        }
        return;
    }
    try w.writeByte(digits[0]);
    if (n > 1) {
        try w.writeByte('.');
        try w.writeAll(digits[1..]);
    }
    try w.print("E{c}{d}", .{ @as(u8, if (exp < 0) '-' else '+'), @abs(exp) });
}

/// 9999-12-31T23:59:59.999Z
const max_iso_ms: i64 = 253402300799999;

fn writeIsoDate(w: *Writer, ms: i64) Writer.Error!void {
    const days = @divFloor(ms, std.time.ms_per_day);
    const in_day = @mod(ms, std.time.ms_per_day);
    const date = civilFromDays(days);
    const secs = @divFloor(in_day, 1000);
    const hours: u64 = @intCast(@divFloor(secs, 3600));
    const minutes: u64 = @intCast(@mod(@divFloor(secs, 60), 60));
    const seconds: u64 = @intCast(@mod(secs, 60));
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{ @as(u64, @intCast(date.year)), date.month, date.day, hours, minutes, seconds });
    const frac = @mod(in_day, 1000);
    if (frac != 0) try w.print(".{d:0>3}", .{@as(u64, @intCast(frac))});
    try w.writeByte('Z');
}

const Civil = struct { year: i64, month: u8, day: u8 };

// Howard Hinnant's days_from_civil and civil_from_days, proleptic Gregorian.
fn civilFromDays(days: i64) Civil {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .year = yoe + era * 400 + @intFromBool(m <= 2), .month = @intCast(m), .day = @intCast(d) };
}

fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = if (month > 2) month - 3 else month + 9;
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

// Parsing.

pub const ParseError = Builder.Error || error{
    /// Not JSON, or JSON whose top level is not an object.
    InvalidJson,
    /// A type wrapper with missing or extra keys, or a value of the wrong
    /// type or form inside one.
    InvalidExtJson,
    /// A JSON number outside the double range.
    InvalidNumber,
    /// The same key twice in one object (the spec allows refusing it).
    DuplicateKey,
    TooDeep,
};

/// Nesting limit for parsing; the spec asks for at least 200 levels.
pub const max_depth = 200;

/// Extended JSON (canonical or relaxed, mixed freely) to a BSON document
/// owned by the caller.
pub fn parse(gpa: std.mem.Allocator, text: []const u8) ParseError![]u8 {
    var b: Builder = .init(gpa);
    errdefer b.deinit();
    try b.begin();
    try parseInto(&b, text);
    try b.end();
    return b.toOwnedSlice();
}

/// Appends the elements of the Extended JSON object `text` to the open
/// document in `b`.
pub fn parseInto(b: *Builder, text: []const u8) ParseError!void {
    var arena_state: std.heap.ArenaAllocator = .init(b.gpa);
    defer arena_state.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), text, .{
        .parse_numbers = false,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateField => error.DuplicateKey,
        else => error.InvalidJson,
    };
    if (root != .object) return error.InvalidJson;
    try appendObject(b, arena_state.allocator(), root.object, 0);
}

// `arena` holds the JSON tree and anything decoded from it (binary data,
// code-with-scope scopes) until the builder has copied it.
fn appendObject(b: *Builder, arena: std.mem.Allocator, object: std.json.ObjectMap, depth: u32) ParseError!void {
    var it = object.iterator();
    while (it.next()) |entry| try appendJson(b, arena, entry.key_ptr.*, entry.value_ptr.*, depth);
}

fn appendJson(b: *Builder, arena: std.mem.Allocator, name: []const u8, v: std.json.Value, depth: u32) ParseError!void {
    switch (v) {
        .null => try b.append(name, .null),
        .bool => |x| try b.append(name, .{ .boolean = x }),
        .number_string => |s| try b.append(name, try number(s)),
        .string => |s| try b.append(name, .{ .string = s }),
        .array => |items| {
            if (depth >= max_depth) return error.TooDeep;
            try b.beginArray(name);
            for (items.items) |item| try appendJson(b, arena, "", item, depth + 1);
            try b.end();
        },
        .object => |object| {
            if (depth >= max_depth) return error.TooDeep;
            if (try wrapper(b, arena, name, object, depth)) return;
            try b.beginDocument(name);
            try appendObject(b, arena, object, depth + 1);
            try b.end();
        },
        // parse_numbers = false leaves every number as a string.
        .integer, .float => unreachable,
    }
}

/// A plain JSON number: the smallest integer type that holds it exactly,
/// else a double.
fn number(s: []const u8) ParseError!Value {
    if (std.mem.indexOfAny(u8, s, ".eE") == null) {
        if (std.fmt.parseInt(i32, s, 10)) |x| return .{ .int32 = x } else |_| {}
        if (std.fmt.parseInt(i64, s, 10)) |x| return .{ .int64 = x } else |_| {}
    }
    const f = std.fmt.parseFloat(f64, s) catch return error.InvalidNumber;
    if (!std.math.isFinite(f)) return error.InvalidNumber;
    return .{ .double = f };
}

const Wrapper = enum { oid, symbol, int32, int64, double, decimal, binary, code, scope, timestamp, regex, db_pointer, date, min_key, max_key, undefined, uuid };

const wrappers = std.StaticStringMap(Wrapper).initComptime(.{
    .{ "$oid", .oid },                 .{ "$symbol", .symbol },
    .{ "$numberInt", .int32 },         .{ "$numberLong", .int64 },
    .{ "$numberDouble", .double },     .{ "$numberDecimal", .decimal },
    .{ "$binary", .binary },           .{ "$code", .code },
    .{ "$scope", .scope },             .{ "$timestamp", .timestamp },
    .{ "$regularExpression", .regex }, .{ "$dbPointer", .db_pointer },
    .{ "$date", .date },               .{ "$minKey", .min_key },
    .{ "$maxKey", .max_key },          .{ "$undefined", .undefined },
    .{ "$uuid", .uuid },
});

/// If `object` uses a type wrapper's key, appends the value it stands for
/// and returns true; a wrapper with missing or extra keys, or a value of
/// the wrong type, is an error. Objects with other `$` keys (`$regex`
/// queries, DBRefs) stay documents.
fn wrapper(b: *Builder, arena: std.mem.Allocator, name: []const u8, object: std.json.ObjectMap, depth: u32) ParseError!bool {
    var kind: ?Wrapper = null;
    var key: []const u8 = undefined;
    for (object.keys()) |k| if (wrappers.get(k)) |w| {
        kind = w;
        key = k;
        break;
    };
    // Code with scope is the one wrapper with two keys, in either order.
    if (object.get("$code")) |code| {
        const s = try str(code);
        if (object.count() == 1) {
            try b.append(name, .{ .javascript = s });
            return true;
        }
        const scope = object.get("$scope") orelse return error.InvalidExtJson;
        if (object.count() != 2 or scope != .object) return error.InvalidExtJson;
        var inner: Builder = .init(arena);
        try inner.begin();
        try appendObject(&inner, arena, scope.object, depth + 1);
        try inner.end();
        try b.append(name, .{ .javascript_with_scope = .{ .code = s, .scope = .{ .bytes = inner.bytes() } } });
        return true;
    }
    if (kind == null) return false;
    if (object.count() != 1) return error.InvalidExtJson;
    const v = object.get(key).?;

    const value: Value = switch (kind.?) {
        .oid => .{ .object_id = ObjectId.parse(try str(v)) catch return error.InvalidExtJson },
        .symbol => .{ .symbol = try str(v) },
        .int32 => .{ .int32 = try strictInt(i32, try str(v)) },
        .int64 => .{ .int64 = try strictInt(i64, try str(v)) },
        .double => .{ .double = try double(try str(v)) },
        .decimal => .{ .decimal128 = Decimal128.parse(try str(v)) catch return error.InvalidExtJson },
        .binary => try binary(arena, v),
        .uuid => try uuid(arena, try str(v)),
        .timestamp => ts: {
            const o = try exactly(v, &.{ "t", "i" });
            break :ts .{ .timestamp = .{ .t = try uint32(o.get("t").?), .i = try uint32(o.get("i").?) } };
        },
        .regex => re: {
            const o = try exactly(v, &.{ "pattern", "options" });
            break :re .{ .regex = .{ .pattern = try str(o.get("pattern").?), .options = try str(o.get("options").?) } };
        },
        .db_pointer => ptr: {
            const o = try exactly(v, &.{ "$ref", "$id" });
            const id = try exactly(o.get("$id").?, &.{"$oid"});
            break :ptr .{ .db_pointer = .{
                .namespace = try str(o.get("$ref").?),
                .id = ObjectId.parse(try str(id.get("$oid").?)) catch return error.InvalidExtJson,
            } };
        },
        .date => date: {
            if (v == .string) break :date .{ .datetime = .{ .ms = try isoDate(v.string) } };
            const o = try exactly(v, &.{"$numberLong"});
            break :date .{ .datetime = .{ .ms = try strictInt(i64, try str(o.get("$numberLong").?)) } };
        },
        .min_key, .max_key => |k| m: {
            if (v != .number_string or !std.mem.eql(u8, v.number_string, "1")) return error.InvalidExtJson;
            break :m if (k == .min_key) .min_key else .max_key;
        },
        .undefined => if (v == .bool and v.bool) .undefined else return error.InvalidExtJson,
        // "$scope" without "$code"; "$code" was handled above.
        .scope, .code => return error.InvalidExtJson,
    };
    try b.append(name, value);
    return true;
}

fn str(v: std.json.Value) ParseError![]const u8 {
    return if (v == .string) v.string else error.InvalidExtJson;
}

/// An object with exactly these keys.
fn exactly(v: std.json.Value, keys: []const []const u8) ParseError!std.json.ObjectMap {
    if (v != .object or v.object.count() != keys.len) return error.InvalidExtJson;
    for (keys) |k| if (!v.object.contains(k)) return error.InvalidExtJson;
    return v.object;
}

/// Digits with an optional leading minus; `std.fmt.parseInt` alone would
/// also take "+1" and "1_000".
fn strictInt(comptime T: type, s: []const u8) ParseError!T {
    const digits = if (s.len > 0 and s[0] == '-') s[1..] else s;
    if (digits.len == 0) return error.InvalidExtJson;
    for (digits) |c| if (c < '0' or c > '9') return error.InvalidExtJson;
    return std.fmt.parseInt(T, s, 10) catch error.InvalidExtJson;
}

fn uint32(v: std.json.Value) ParseError!u32 {
    if (v != .number_string) return error.InvalidExtJson;
    for (v.number_string) |c| if (c < '0' or c > '9') return error.InvalidExtJson;
    return std.fmt.parseInt(u32, v.number_string, 10) catch error.InvalidExtJson;
}

fn double(s: []const u8) ParseError!f64 {
    if (std.mem.eql(u8, s, "Infinity")) return std.math.inf(f64);
    if (std.mem.eql(u8, s, "-Infinity")) return -std.math.inf(f64);
    if (std.mem.eql(u8, s, "NaN")) return std.math.nan(f64);
    // [-]digits[.digits][e[+-]digits], digits on at least one side of the point.
    var i: usize = @intFromBool(s.len > 0 and s[0] == '-');
    var digits: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) digits += 1;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) digits += 1;
    }
    if (digits == 0) return error.InvalidExtJson;
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        const start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
        if (i == start) return error.InvalidExtJson;
    }
    if (i != s.len) return error.InvalidExtJson;
    return std.fmt.parseFloat(f64, s) catch error.InvalidExtJson;
}

fn binary(arena: std.mem.Allocator, v: std.json.Value) ParseError!Value {
    const o = try exactly(v, &.{ "base64", "subType" });
    const text = try str(o.get("base64").?);
    const sub = try str(o.get("subType").?);
    if (sub.len < 1 or sub.len > 2) return error.InvalidExtJson;
    const subtype = std.fmt.parseInt(u8, sub, 16) catch return error.InvalidExtJson;
    const decoder = std.base64.standard.Decoder;
    const len = decoder.calcSizeForSlice(text) catch return error.InvalidExtJson;
    const data = try arena.alloc(u8, len);
    decoder.decode(data, text) catch return error.InvalidExtJson;
    return .{ .binary = .{ .subtype = @fromBackingInt(subtype), .data = data } };
}

fn uuid(arena: std.mem.Allocator, s: []const u8) ParseError!Value {
    var hex: [32]u8 = undefined;
    if (s.len == 36) {
        for ([_]usize{ 8, 13, 18, 23 }) |at| if (s[at] != '-') return error.InvalidExtJson;
        var n: usize = 0;
        for (s, 0..) |c, i| {
            if (i == 8 or i == 13 or i == 18 or i == 23) continue;
            hex[n] = c;
            n += 1;
        }
    } else if (s.len == 32) {
        hex = s[0..32].*;
    } else return error.InvalidExtJson;
    const data = try arena.alloc(u8, 16);
    _ = std.fmt.hexToBytes(data, &hex) catch return error.InvalidExtJson;
    return .{ .binary = .{ .subtype = .uuid, .data = data } };
}

/// RFC 3339 "YYYY-MM-DDTHH:MM:SS[.fff]Z" or with a "+HH:MM" / "+HHMM"
/// offset; digits past milliseconds are dropped.
fn isoDate(s: []const u8) ParseError!i64 {
    var p: Cursor = .{ .s = s };
    const year = try p.num(4);
    try p.lit('-');
    const month = try p.num(2);
    try p.lit('-');
    const day = try p.num(2);
    try p.lit('T');
    const hour = try p.num(2);
    try p.lit(':');
    const minute = try p.num(2);
    try p.lit(':');
    const second = try p.num(2);
    var ms: i64 = 0;
    if (p.peek() == '.') {
        p.i += 1;
        var scale: i64 = 100;
        const start = p.i;
        while (p.i < s.len and std.ascii.isDigit(s[p.i])) : (p.i += 1) {
            ms += (s[p.i] - '0') * scale;
            scale = @divTrunc(scale, 10);
        }
        if (p.i == start) return error.InvalidExtJson;
    }
    var offset: i64 = 0;
    switch (p.peek() orelse return error.InvalidExtJson) {
        'Z' => p.i += 1,
        '+', '-' => |sign| {
            p.i += 1;
            const oh = try p.num(2);
            if (p.peek() == ':') p.i += 1;
            const om = try p.num(2);
            if (oh > 23 or om > 59) return error.InvalidExtJson;
            offset = (oh * 60 + om) * 60 * 1000;
            if (sign == '-') offset = -offset;
        },
        else => return error.InvalidExtJson,
    }
    if (p.i != s.len) return error.InvalidExtJson;
    if (month < 1 or month > 12 or day < 1 or day > daysInMonth(year, month)) return error.InvalidExtJson;
    if (hour > 23 or minute > 59 or second > 60) return error.InvalidExtJson;
    const days = daysFromCivil(year, month, day);
    return ((days * 24 + hour) * 60 + minute) * 60_000 + second * 1000 + ms - offset;
}

fn daysInMonth(year: i64, month: i64) i64 {
    return switch (month) {
        2 => if (@mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

const Cursor = struct {
    s: []const u8,
    i: usize = 0,

    fn peek(c: *Cursor) ?u8 {
        return if (c.i < c.s.len) c.s[c.i] else null;
    }

    fn lit(c: *Cursor, ch: u8) ParseError!void {
        if (c.peek() != ch) return error.InvalidExtJson;
        c.i += 1;
    }

    fn num(c: *Cursor, n: usize) ParseError!i64 {
        if (c.s.len - c.i < n) return error.InvalidExtJson;
        var x: i64 = 0;
        for (c.s[c.i..][0..n]) |ch| {
            if (!std.ascii.isDigit(ch)) return error.InvalidExtJson;
            x = x * 10 + (ch - '0');
        }
        c.i += n;
        return x;
    }
};

const testing = std.testing;

fn expectJson(expected: []const u8, bson: []const u8, mode: Mode) !void {
    const out = try allocPrint(testing.allocator, try Document.init(bson), mode);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(expected, out);
}

test "canonical and relaxed output" {
    const bytes = try @import("mapping.zig").encode(testing.allocator, .{
        .i = 1,
        .l = @as(i64, 2),
        .d = 1.5,
        .whole = 3.0,
        .big = 1.2345678921232e18,
        .small = 0.00001,
        .tiny = 1e-7,
        .t = document.Datetime{ .ms = 1356351330501 },
        .s = "a\"b\\c\n\x01é",
        .r = document.Regex{ .pattern = "x", .options = "mi" },
    }, .{});
    defer testing.allocator.free(bytes);
    try expectJson(
        \\{"i":{"$numberInt":"1"},"l":{"$numberLong":"2"},"d":{"$numberDouble":"1.5"},"whole":{"$numberDouble":"3.0"},"big":{"$numberDouble":"1.2345678921232E+18"},"small":{"$numberDouble":"0.00001"},"tiny":{"$numberDouble":"1E-7"},"t":{"$date":{"$numberLong":"1356351330501"}},"s":"a\"b\\c\n\u0001é","r":{"$regularExpression":{"pattern":"x","options":"im"}}}
    , bytes, .canonical);
    try expectJson(
        \\{"i":1,"l":2,"d":1.5,"whole":3.0,"big":1.2345678921232E+18,"small":0.00001,"tiny":1E-7,"t":{"$date":"2012-12-24T12:15:30.501Z"},"s":"a\"b\\c\n\u0001é","r":{"$regularExpression":{"pattern":"x","options":"im"}}}
    , bytes, .relaxed);
}

test "Document formats as relaxed Extended JSON" {
    const bytes = try @import("mapping.zig").encode(testing.allocator, .{ .a = .{ 1, "x" } }, .{});
    defer testing.allocator.free(bytes);
    var buf: [64]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{f}", .{try Document.init(bytes)});
    try testing.expectEqualStrings("{\"a\":[1,\"x\"]}", s);
}

test "parse accepts both forms and dates with offsets" {
    const bytes = try parse(testing.allocator,
        \\{"a": 1, "b": 3000000000, "c": 1.0, "d": {"$numberLong": "7"},
        \\ "e": {"$date": "2012-12-24T13:15:30.501+01:00"}, "f": {"$uuid": "73ffd264-44b3-4c69-90e8-e7d1dfc035d4"},
        \\ "g": {"$code": "x", "$scope": {"y": {"$minKey": 1}}}, "h": {"$regex": "plain"}}
    );
    defer testing.allocator.free(bytes);
    const doc = try Document.init(bytes);
    try testing.expectEqual(1, doc.get("a").?.int32);
    try testing.expectEqual(3000000000, doc.get("b").?.int64);
    try testing.expectEqual(1.0, doc.get("c").?.double);
    try testing.expectEqual(7, doc.get("d").?.int64);
    try testing.expectEqual(1356351330501, doc.get("e").?.datetime.ms);
    try testing.expectEqual(.uuid, doc.get("f").?.binary.subtype);
    try testing.expect(doc.get("g").?.javascript_with_scope.scope.get("y").? == .min_key);
    try testing.expectEqualStrings("plain", doc.getPath("h.$regex").?.string);

    try testing.expectError(error.InvalidExtJson, parse(testing.allocator, "{\"a\": {\"$numberInt\": \"+1\"}}"));
    try testing.expectError(error.InvalidExtJson, parse(testing.allocator, "{\"a\": {\"$date\": \"2012-02-30T00:00:00Z\"}}"));
    try testing.expectError(error.InvalidJson, parse(testing.allocator, "[1]"));
    try testing.expectError(error.DuplicateKey, parse(testing.allocator, "{\"a\": 1, \"a\": 2}"));
}

test "duplicate keys: both written, refused when parsed (corpus prose test 2)" {
    var bytes: [23]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, "1700000010666f6f000100000010666f6f000200000000");
    try expectJson("{\"foo\":1,\"foo\":2}", &bytes, .relaxed);
    try testing.expectError(error.DuplicateKey, parse(testing.allocator, "{ \"foo\": 1, \"foo\": 2 }"));
}

test "civil date conversions agree" {
    var days: i64 = -800_000;
    while (days < 3_000_000) : (days += 997) {
        const c = civilFromDays(days);
        try testing.expectEqual(days, daysFromCivil(c.year, c.month, c.day));
    }
}
