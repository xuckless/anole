//! gRPC JSON transcoding: REST routes for the methods a .proto file
//! annotates with `google.api.http` (google/api/http.proto), the way Envoy's
//! grpc_json_transcoder and grpc-gateway read them.
//!
//!     rpc GetBook(GetBookRequest) returns (Book) {
//!       option (google.api.http) = { get: "/v1/{name=shelves/*/books/*}" };
//!     }
//!
//! zig-protobuf's codegen keeps the option in the service's
//! `_method_options`, so `registerWith` finds the rules at compile time: each
//! binding's path template is parsed then, and its fields checked against the
//! request type. A template becomes a router route (`:param` for `*`,
//! `*wildcard` for `**`); what the router cannot say (literals inside a
//! variable, a `:verb` after a variable) the binding matches itself, so
//! several bindings may share one route and are tried in turn.
//!
//! The request message is built as JSON and decoded with the generated
//! `jsonDecode` (the proto3 JSON mapping): the body (`*`, or one field),
//! then the path variables, then the query parameters for the fields the
//! path and body leave. The response is the generated `jsonEncode`, or one
//! field of it (`response_body`).
const std = @import("std");
const dusty = @import("dusty");
const protobuf = @import("protobuf");
const server = @import("server.zig");

/// The most segments a path template has, and the most variables.
pub const max_segments = 32;
pub const max_variables = 8;
/// The deepest nesting of a JSON request body, and of a field path.
pub const max_json_depth = 100;
pub const max_field_depth = 16;

// ---------------------------------------------------------------------------
// Path templates
// ---------------------------------------------------------------------------

pub const Segment = union(enum) {
    literal: []const u8,
    /// `*`: one path segment.
    one,
    /// `**`: the rest of the path.
    rest,
};

/// `{field=...}`: template segments `first` up to `end` bind `field`.
pub const Variable = struct {
    field: []const u8,
    first: u8,
    end: u8,
};

/// A variable's text in a matched path, still percent-encoded. `multi`
/// when the variable can span segments, so `%2F` stays encoded.
pub const Capture = struct {
    field: []const u8,
    raw: []const u8,
    multi: bool,
};

/// google/api/http.proto's grammar:
///
///     Template = "/" Segments [ Verb ] ;
///     Segments = Segment { "/" Segment } ;
///     Segment  = "*" | "**" | LITERAL | Variable ;
///     Variable = "{" FieldPath [ "=" Segments ] "}" ;
///     FieldPath = IDENT { "." IDENT } ;
///     Verb     = ":" LITERAL ;
///
/// `**` may only be the last segment. Parsed at compile time for the
/// annotations; the slices point into the template text.
pub const Template = struct {
    segment_buf: [max_segments]Segment = @splat(.one),
    segment_count: u8 = 0,
    variable_buf: [max_variables]Variable = @splat(.{ .field = "", .first = 0, .end = 0 }),
    variable_count: u8 = 0,
    verb: []const u8 = "",

    pub const Error = error{InvalidTemplate};

    pub fn segments(self: *const Template) []const Segment {
        return self.segment_buf[0..self.segment_count];
    }

    pub fn variables(self: *const Template) []const Variable {
        return self.variable_buf[0..self.variable_count];
    }

    pub fn parse(text: []const u8) Error!Template {
        var t: Template = .{};
        if (text.len == 0 or text[0] != '/') return error.InvalidTemplate;
        var i: usize = 1;
        // "/" alone: the root, no segments.
        if (i == text.len) return t;
        while (true) {
            if (text[i] == '{') {
                const close = std.mem.indexOfScalarPos(u8, text, i, '}') orelse return error.InvalidTemplate;
                const inner = text[i + 1 .. close];
                const eq = std.mem.indexOfScalar(u8, inner, '=');
                const field = inner[0 .. eq orelse inner.len];
                if (!validFieldPath(field)) return error.InvalidTemplate;
                for (t.variables()) |v| if (std.mem.eql(u8, v.field, field)) return error.InvalidTemplate;
                if (t.variable_count == max_variables) return error.InvalidTemplate;
                const first = t.segment_count;
                if (eq) |e| {
                    var it = std.mem.splitScalar(u8, inner[e + 1 ..], '/');
                    while (it.next()) |s| try t.add(try segmentOf(s));
                } else try t.add(.one);
                t.variable_buf[t.variable_count] = .{ .field = field, .first = first, .end = t.segment_count };
                t.variable_count += 1;
                i = close + 1;
            } else {
                const end = std.mem.indexOfAnyPos(u8, text, i, "/:") orelse text.len;
                try t.add(try segmentOf(text[i..end]));
                i = end;
            }
            if (i == text.len) break;
            switch (text[i]) {
                '/' => {
                    i += 1;
                    if (i == text.len) return error.InvalidTemplate;
                },
                ':' => {
                    t.verb = text[i + 1 ..];
                    if (!validLiteral(t.verb)) return error.InvalidTemplate;
                    break;
                },
                else => return error.InvalidTemplate,
            }
        }
        for (t.segments()[0 .. t.segment_count - 1]) |s| if (s == .rest) return error.InvalidTemplate;
        return t;
    }

    fn add(self: *Template, segment: Segment) Error!void {
        if (self.segment_count == max_segments) return error.InvalidTemplate;
        self.segment_buf[self.segment_count] = segment;
        self.segment_count += 1;
    }

    fn segmentOf(s: []const u8) Error!Segment {
        if (std.mem.eql(u8, s, "*")) return .one;
        if (std.mem.eql(u8, s, "**")) return .rest;
        if (!validLiteral(s)) return error.InvalidTemplate;
        return .{ .literal = s };
    }

    fn validLiteral(s: []const u8) bool {
        if (s.len == 0) return false;
        for (s) |ch| switch (ch) {
            0...0x20, 0x7f...0xff, '/', ':', '{', '}', '*', '?', '#', '=' => return false,
            else => {},
        };
        return true;
    }

    fn validFieldPath(s: []const u8) bool {
        var it = std.mem.splitScalar(u8, s, '.');
        while (it.next()) |ident| {
            if (ident.len == 0 or std.ascii.isDigit(ident[0])) return false;
            for (ident) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
        }
        return true;
    }

    /// Whether the two match the same paths: the same segments and verb,
    /// whatever their variables are called.
    pub fn sameShape(a: *const Template, b: *const Template) bool {
        if (a.segment_count != b.segment_count or !std.mem.eql(u8, a.verb, b.verb)) return false;
        for (a.segments(), b.segments()) |x, y| {
            if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
            if (x == .literal and !std.mem.eql(u8, x.literal, y.literal)) return false;
        }
        return true;
    }

    /// Matches a request path (without the query, still percent-encoded),
    /// with empty segments skipped as the router skips them. Returns the
    /// variables' captures, in `out`.
    pub fn match(self: *const Template, request_path: []const u8, out: *[max_variables]Capture) ?[]const Capture {
        var path = request_path;
        if (self.verb.len > 0) {
            if (path.len < self.verb.len + 1 or !std.mem.endsWith(u8, path, self.verb)) return null;
            const colon = path.len - self.verb.len - 1;
            if (path[colon] != ':') return null;
            path = path[0..colon];
            // Something must come before the verb.
            if (path.len == 0 or path[path.len - 1] == '/') return null;
        }
        var starts: [max_segments]usize = undefined;
        var ends: [max_segments]usize = undefined;
        var pos: usize = 0;
        for (self.segments(), 0..) |segment, k| {
            while (pos < path.len and path[pos] == '/') pos += 1;
            if (segment == .rest) {
                starts[k] = pos;
                ends[k] = path.len;
                pos = path.len;
                break;
            }
            if (pos == path.len) return null;
            const end = std.mem.indexOfScalarPos(u8, path, pos, '/') orelse path.len;
            if (segment == .literal and !std.mem.eql(u8, segment.literal, path[pos..end])) return null;
            starts[k] = pos;
            ends[k] = end;
            pos = end;
        }
        while (pos < path.len and path[pos] == '/') pos += 1;
        if (pos != path.len) return null;
        for (self.variables(), 0..) |v, n| {
            out[n] = .{
                .field = v.field,
                .raw = path[starts[v.first]..ends[v.end - 1]],
                .multi = !(v.end - v.first == 1 and self.segment_buf[v.first] == .one),
            };
        }
        return out[0..self.variable_count];
    }
};

/// Percent-decodes a path variable: all of it for one segment; for several,
/// all but `%2F`, which stays as it is (google/api/http.proto).
pub fn decodePath(arena: std.mem.Allocator, raw: []const u8, multi: bool) error{ InvalidEscape, OutOfMemory }![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '%') == null) return raw;
    var out: std.ArrayList(u8) = try .initCapacity(arena, raw.len);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] != '%') {
            out.appendAssumeCapacity(raw[i]);
            continue;
        }
        if (i + 2 >= raw.len) return error.InvalidEscape;
        const hi = std.fmt.charToDigit(raw[i + 1], 16) catch return error.InvalidEscape;
        const lo = std.fmt.charToDigit(raw[i + 2], 16) catch return error.InvalidEscape;
        const byte = hi << 4 | lo;
        if (multi and byte == '/') {
            out.appendSliceAssumeCapacity(raw[i .. i + 3]);
        } else {
            out.appendAssumeCapacity(byte);
        }
        i += 2;
    }
    return out.items;
}

// ---------------------------------------------------------------------------
// Rules from the annotations
// ---------------------------------------------------------------------------

/// One HTTP binding of a method: its `google.api.http` rule, or one of the
/// rule's `additional_bindings`.
pub const Rule = struct {
    method: dusty.Method,
    pattern: []const u8,
    body: []const u8 = "",
    response_body: []const u8 = "",
};

/// Whether the method carries a `google.api.http` option.
pub fn annotated(comptime Service: type, comptime method: []const u8) bool {
    if (!@hasDecl(Service, "_method_options")) return false;
    const all = Service._method_options;
    if (!@hasField(@TypeOf(all), method)) return false;
    return @hasField(@TypeOf(@field(all, method)), "google.api.http");
}

/// The method's bindings: the rule, then its additional bindings.
pub fn rules(comptime Service: type, comptime method: []const u8) []const Rule {
    return comptime rulesOf(Service, method);
}

fn rulesOf(comptime Service: type, comptime method: []const u8) []const Rule {
    if (!annotated(Service, method)) return &.{};
    const http = @field(@field(Service._method_options, method), "google.api.http");
    const where = Service.package ++ "." ++ Service.service_name ++ "." ++ method;
    var list: []const Rule = &.{ruleOf(http, where)};
    if (@hasField(@TypeOf(http), "additional_bindings")) {
        for (http.additional_bindings) |extra| list = list ++ .{ruleOf(extra, where)};
    }
    return list;
}

fn ruleOf(comptime http: anytype, comptime where: []const u8) Rule {
    const H = @TypeOf(http);
    var rule: ?Rule = null;
    for (.{ "get", "put", "post", "delete", "patch" }) |verb| {
        if (@hasField(H, verb)) rule = .{ .method = @field(dusty.Method, verb), .pattern = @field(http, verb) };
    }
    if (@hasField(H, "custom")) {
        var lower: [http.custom.kind.len]u8 = undefined;
        _ = std.ascii.lowerString(&lower, http.custom.kind);
        const method = std.meta.stringToEnum(dusty.Method, &lower) orelse
            @compileError("google.api.http on " ++ where ++ ": unknown HTTP method \"" ++ http.custom.kind ++ "\"");
        rule = .{ .method = method, .pattern = http.custom.path };
    }
    var r = rule orelse @compileError("google.api.http on " ++ where ++ " has no path pattern");
    if (@hasField(H, "body")) r.body = http.body;
    if (@hasField(H, "response_body")) r.response_body = http.response_body;
    return r;
}

// ---------------------------------------------------------------------------
// Fields of the request message, by path
// ---------------------------------------------------------------------------

/// What a path variable or query parameter can set, and how its text
/// becomes JSON.
pub const Kind = enum {
    string,
    bytes,
    bool,
    number,
    enumeration,
    /// A well-known type whose JSON is a string or a number
    /// (Timestamp, Duration, FieldMask, the wrappers but BoolValue).
    wkt_text,
    wkt_bool,
    message,
    map,
};

pub const Leaf = struct {
    kind: Kind,
    repeated: bool = false,
    /// For an enum: whether a name is one of its values. Checked here, as
    /// the body's decoding skips unknown values.
    known: ?*const fn (name: []const u8) bool = null,
    /// Or, for an enum known only at run time: `known_in(enum_ctx, name)`.
    known_in: ?*const fn (ctx: *const anyopaque, name: []const u8) bool = null,
    enum_ctx: ?*const anyopaque = null,

    fn isKnown(leaf: Leaf, name: []const u8) bool {
        if (leaf.known) |f| return f(name);
        if (leaf.known_in) |f| return f(leaf.enum_ctx.?, name);
        return false;
    }
};

fn EnumNames(comptime E: type) type {
    return struct {
        fn known(name: []const u8) bool {
            inline for (@typeInfo(E).@"enum".field_names) |field| {
                if (std.ascii.eqlIgnoreCase(field, name)) return true;
            }
            return false;
        }
    };
}

/// A field path as the message's own field names (snake_case), whichever
/// spelling (`book_id`, `bookId`) asked for it.
pub const Names = struct {
    buf: [max_field_depth][]const u8 = undefined,
    len: usize = 0,

    fn push(self: *Names, name: []const u8) bool {
        if (self.len == max_field_depth) return false;
        self.buf[self.len] = name;
        self.len += 1;
        return true;
    }

    pub fn slice(self: *const Names) []const []const u8 {
        return self.buf[0..self.len];
    }

    /// Adds the next name of the path; false past `max_field_depth`.
    pub fn append(self: *Names, name: []const u8) bool {
        return self.push(name);
    }
};

/// The field `path` (dot-separated, proto or JSON names) names in `T`.
pub fn lookup(comptime T: type, path: []const u8, names: *Names) ?Leaf {
    @setEvalBranchQuota(100_000);
    const dot = std.mem.indexOfScalar(u8, path, '.');
    const head = path[0 .. dot orelse path.len];
    const rest: ?[]const u8 = if (dot) |d| path[d + 1 ..] else null;
    const table = T._desc_table;
    inline for (@typeInfo(@TypeOf(table)).@"struct".field_names) |name| {
        const desc = @field(table, name);
        if (comptime desc.ftype == .oneof) {
            // A oneof's members are fields of the message in JSON.
            const U = desc.ftype.oneof;
            inline for (@typeInfo(@TypeOf(U._desc_table)).@"struct".field_names) |member| {
                if (nameIs(member, head)) {
                    if (!names.push(member)) return null;
                    return leafOf(@FieldType(U, member), @field(U._desc_table, member).ftype, rest, names);
                }
            }
        } else if (nameIs(name, head)) {
            if (!names.push(name)) return null;
            return leafOf(@FieldType(T, name), desc.ftype, rest, names);
        }
    }
    return null;
}

fn leafOf(comptime F: type, comptime ftype: protobuf.FieldType, rest: ?[]const u8, names: *Names) ?Leaf {
    switch (ftype) {
        .scalar => |s| return if (rest != null) null else .{ .kind = scalarKind(s) },
        .@"enum" => return if (rest != null) null else .{ .kind = .enumeration, .known = EnumNames(Unwrap(F)).known },
        .submessage => {
            const Child = Unwrap(F);
            if (comptime wktKind(Child)) |k| return if (rest != null) null else .{ .kind = k };
            const r = rest orelse return .{ .kind = .message };
            return lookup(Child, r, names);
        },
        .repeated, .packed_repeated => |r| {
            if (rest != null) return null;
            const Elem = @typeInfo(F.Slice).pointer.child;
            if (comptime isMapEntry(Elem)) return .{ .kind = .map };
            return switch (r) {
                .scalar => |s| .{ .repeated = true, .kind = scalarKind(s) },
                .@"enum" => .{ .repeated = true, .kind = .enumeration, .known = EnumNames(Elem).known },
                .submessage => .{ .repeated = true, .kind = comptime wktKind(Elem) orelse .message },
            };
        },
        .oneof => return null,
    }
}

fn scalarKind(comptime s: protobuf.FieldType.Scalar) Kind {
    return switch (s) {
        .string => .string,
        .bytes => .bytes,
        .bool => .bool,
        else => .number,
    };
}

fn wktKind(comptime T: type) ?Kind {
    const wkt = protobuf.wkt;
    if (T == wkt.BoolValue) return .wkt_bool;
    inline for (.{ wkt.Timestamp, wkt.Duration, wkt.FieldMask, wkt.StringValue, wkt.BytesValue, wkt.Int32Value, wkt.UInt32Value, wkt.Int64Value, wkt.UInt64Value, wkt.FloatValue, wkt.DoubleValue }) |W| {
        if (T == W) return .wkt_text;
    }
    return null;
}

fn Unwrap(comptime F: type) type {
    return switch (@typeInfo(F)) {
        .optional => |o| Unwrap(o.child),
        .pointer => |p| p.child,
        else => F,
    };
}

fn isMapEntry(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") return false;
    const names = info.@"struct".field_names;
    return names.len == 2 and std.mem.eql(u8, names[0], "key") and std.mem.eql(u8, names[1], "value");
}

/// `name` (a proto field name) asked for as itself or as its JSON name.
fn nameIs(comptime name: []const u8, asked: []const u8) bool {
    return std.mem.eql(u8, asked, name) or std.mem.eql(u8, asked, comptime jsonName(name));
}

/// protobuf's ToJsonName: each `_` dropped and the next character upper-cased.
fn jsonName(comptime name: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        var upper = false;
        for (name) |ch| {
            if (ch == '_') {
                upper = true;
            } else {
                out = out ++ .{if (upper) std.ascii.toUpper(ch) else ch};
                upper = false;
            }
        }
        return out;
    }
}

fn jsonNameAlloc(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, name, '_') == null) return name;
    var out: std.ArrayList(u8) = try .initCapacity(arena, name.len);
    var upper = false;
    for (name) |ch| {
        if (ch == '_') {
            upper = true;
        } else {
            out.appendAssumeCapacity(if (upper) std.ascii.toUpper(ch) else ch);
            upper = false;
        }
    }
    return out.items;
}

/// Checks a binding against the method's types, at compile time: each
/// variable names a non-repeated field of a primitive type, `body` a
/// top-level field (or `*`), `response_body` a top-level field.
pub fn validate(comptime Req: type, comptime Resp: type, comptime rule: Rule, comptime template: Template, comptime where: []const u8) void {
    comptime {
        @setEvalBranchQuota(1_000_000);
        for (template.variables()) |v| {
            var names: Names = .{};
            const leaf = lookup(Req, v.field, &names) orelse
                @compileError("google.api.http on " ++ where ++ ": " ++ v.field ++ " is not a field of " ++ @typeName(Req));
            if (leaf.repeated or leaf.kind == .message or leaf.kind == .map)
                @compileError("google.api.http on " ++ where ++ ": path variable " ++ v.field ++ " must be a single field of a primitive type");
        }
        if (rule.body.len > 0 and !std.mem.eql(u8, rule.body, "*")) {
            if (std.mem.indexOfScalar(u8, rule.body, '.') != null or !@hasField(@TypeOf(Req._desc_table), rule.body))
                @compileError("google.api.http on " ++ where ++ ": body \"" ++ rule.body ++ "\" is not a top-level field of " ++ @typeName(Req));
        }
        if (rule.response_body.len > 0) {
            if (!@hasField(@TypeOf(Resp._desc_table), rule.response_body) or @field(Resp._desc_table, rule.response_body).ftype == .oneof)
                @compileError("google.api.http on " ++ where ++ ": response_body \"" ++ rule.response_body ++ "\" is not a top-level field of " ++ @typeName(Resp));
        }
    }
}

// ---------------------------------------------------------------------------
// The request message
// ---------------------------------------------------------------------------

/// Why a request could not become a message (`error.InvalidArgument`).
pub const Diagnostic = struct { message: []const u8 = "" };

pub const DecodeError = error{ InvalidArgument, OutOfMemory };

fn invalid(diag: *Diagnostic, message: []const u8) DecodeError {
    diag.message = message;
    return error.InvalidArgument;
}

/// The request message of a binding: `body_text` read as the `body` field
/// (or as the whole message for `*`), the path variables over it, and for
/// a binding whose body is not `*`, the query parameters naming the other
/// fields. Query parameters for unknown fields are ignored; a parameter
/// may repeat for a repeated field; values follow the proto3 JSON mapping
/// as strings (enum names or numbers, `true`/`false`, RFC 3339 timestamps,
/// base64 bytes).
pub fn decodeRequest(
    comptime Req: type,
    arena: std.mem.Allocator,
    comptime body: []const u8,
    body_text: []const u8,
    captures: []const Capture,
    query: []const u8,
    diag: *Diagnostic,
) DecodeError!Req {
    const fields = struct {
        pub fn lookup(_: @This(), path: []const u8, names: *Names) ?Leaf {
            return transcodeLookup(Req, path, names);
        }
    }{};
    return decodeJson(Req, arena, try requestJson(arena, body, body_text, captures, query, diag, fields), diag);
}

const transcodeLookup = lookup;

/// `decodeRequest`'s message as JSON text, for any message description:
/// `fields.lookup(path, *Names) ?Leaf` says what a field path names (the C
/// ABI's gRPC server answers from descriptors, at run time).
pub fn requestJson(
    arena: std.mem.Allocator,
    body: []const u8,
    body_text: []const u8,
    captures: []const Capture,
    query: []const u8,
    diag: *Diagnostic,
    fields: anytype,
) DecodeError![]const u8 {
    const whole_body = std.mem.eql(u8, body, "*");
    const has_body = body.len > 0 and std.mem.trim(u8, body_text, " \t\r\n").len > 0;
    if (has_body and !jsonDepthWithin(body_text, max_json_depth)) return invalid(diag, "the request body nests too deeply");
    // The common case for a custom method: the body is the message.
    if (whole_body and captures.len == 0) return if (has_body) body_text else "{}";

    var root: std.json.ObjectMap = .empty;
    if (has_body) {
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, body_text, .{ .parse_numbers = false }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return invalid(diag, "the request body is not JSON"),
        };
        if (whole_body) {
            if (value != .object) return invalid(diag, "the request body is not a JSON object");
            root = value.object;
        } else {
            try setField(arena, &root, &.{body}, value, false);
        }
    }
    // Each variable's field as the message's own names, whichever spelling
    // the template used, for the query parameters to be checked against.
    var bound_names: [max_variables]Names = undefined;
    if (captures.len > max_variables) return invalid(diag, "too many path variables");
    for (captures, 0..) |capture, i| {
        const names = &bound_names[i];
        names.* = .{};
        const leaf = fields.lookup(capture.field, names) orelse return invalid(diag, "a path variable names no field");
        const text = decodePath(arena, capture.raw, capture.multi) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidEscape => return invalid(diag, "malformed percent-encoding in the path"),
        };
        const value = valueOf(leaf, text) orelse
            return invalid(diag, try std.fmt.allocPrint(arena, "path variable {s}: invalid value", .{capture.field}));
        try setField(arena, &root, names.slice(), value, false);
    }
    if (!whole_body) {
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |pair| {
            if (pair.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, pair, '=');
            const key = dusty.Request.urlUnescape(arena, pair[0 .. eq orelse pair.len]) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return invalid(diag, "malformed percent-encoding in the query"),
            };
            const text = if (eq) |e| dusty.Request.urlUnescape(arena, pair[e + 1 ..]) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return invalid(diag, "malformed percent-encoding in the query"),
            } else "";
            var names: Names = .{};
            // Not a field: ignored, like a cache-buster or a tracking tag.
            const leaf = fields.lookup(key, &names) orelse continue;
            // Fields the path or the body set are theirs.
            if (bound(names.slice(), bound_names[0..captures.len], body)) continue;
            const value = valueOf(leaf, text) orelse
                return invalid(diag, try std.fmt.allocPrint(arena, "query parameter {s}: invalid value", .{key}));
            try setField(arena, &root, names.slice(), value, leaf.repeated);
        }
    }
    return std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = root }, .{}) catch return error.OutOfMemory;
}

fn decodeJson(comptime Req: type, arena: std.mem.Allocator, text: []const u8, diag: *Diagnostic) DecodeError!Req {
    const parsed = Req.jsonDecode(text, .{ .ignore_unknown_fields = true }, arena) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return invalid(diag, "the request does not decode as the method's message"),
    };
    return parsed.value;
}

/// Whether a field path is set by the path (a variable at it, above it or
/// below it) or by the body field. Both sides are the message's own field
/// names, as `lookup` resolves them, so the template and the query may
/// each spell a field either way.
fn bound(names: []const []const u8, variables: []const Names, body: []const u8) bool {
    if (body.len > 0 and std.mem.eql(u8, names[0], body)) return true;
    for (variables) |variable| {
        const parts = variable.slice();
        const n = @min(parts.len, names.len);
        for (parts[0..n], names[0..n]) |a, b| {
            if (!std.mem.eql(u8, a, b)) break;
        } else return true;
    }
    return false;
}

/// The JSON a path or query value stands for, as the field's kind reads it.
fn valueOf(leaf: Leaf, text: []const u8) ?std.json.Value {
    return switch (leaf.kind) {
        // Numbers too: the proto3 JSON mapping takes them as strings, and a
        // string cannot smuggle anything into the JSON.
        .string, .bytes, .number, .wkt_text => .{ .string = text },
        .bool, .wkt_bool => if (std.mem.eql(u8, text, "true"))
            .{ .bool = true }
        else if (std.mem.eql(u8, text, "false"))
            .{ .bool = false }
        else
            null,
        .enumeration => if (std.fmt.parseInt(i32, text, 10)) |n|
            .{ .integer = n }
        else |_| if (leaf.isKnown(text)) .{ .string = text } else null,
        .message, .map => null,
    };
}

/// Sets the field at `names` in the JSON object, creating the objects on
/// the way; either spelling of a name already there is replaced. `append`
/// adds to an array instead (a repeated query parameter).
fn setField(arena: std.mem.Allocator, root: *std.json.ObjectMap, names: []const []const u8, value: std.json.Value, append: bool) !void {
    var object = root;
    for (names[0 .. names.len - 1]) |name| {
        const json_name = try jsonNameAlloc(arena, name);
        if (object.getPtr(name) orelse object.getPtr(json_name)) |existing| {
            if (existing.* != .object) existing.* = .{ .object = .empty };
            object = &existing.object;
        } else {
            try object.put(arena, name, .{ .object = .empty });
            object = &object.getPtr(name).?.object;
        }
    }
    const name = names[names.len - 1];
    const json_name = try jsonNameAlloc(arena, name);
    var previous: ?std.json.Value = null;
    if (object.fetchOrderedRemove(name)) |kv| previous = kv.value;
    if (object.fetchOrderedRemove(json_name)) |kv| previous = kv.value;
    var new = value;
    if (append) {
        var array: std.json.Array = if (previous) |p| (if (p == .array) p.array else .init(arena)) else .init(arena);
        try array.append(value);
        new = .{ .array = array };
    }
    try object.put(arena, name, new);
}

/// Whether JSON text nests at most `limit` arrays and objects deep (strings
/// skipped), so a hostile body cannot exhaust the stack of what reads it.
pub fn jsonDepthWithin(text: []const u8, limit: usize) bool {
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (text) |ch| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (ch == '\\') {
                escaped = true;
            } else if (ch == '"') {
                in_string = false;
            }
            continue;
        }
        switch (ch) {
            '"' => in_string = true,
            '{', '[' => {
                depth += 1;
                if (depth > limit) return false;
            },
            '}', ']' => depth -|= 1,
            else => {},
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// The response
// ---------------------------------------------------------------------------

const json_options = server.json_options;

/// The response message as JSON, or its `response_body` field alone.
pub fn encodeResponse(comptime Resp: type, arena: std.mem.Allocator, message: Resp, comptime response_body: []const u8) ![]const u8 {
    if (response_body.len == 0) return message.jsonEncode(.{}, json_options, arena);
    const F = @FieldType(Resp, response_body);
    const ftype = @field(Resp._desc_table, response_body).ftype;
    if (comptime ftype == .submessage) {
        const value = @field(message, response_body);
        const present = switch (@typeInfo(F)) {
            .optional => value orelse return comptime defaultJson(F, ftype),
            else => value,
        };
        const inner = if (@typeInfo(@TypeOf(present)) == .pointer) present.* else present;
        return inner.jsonEncode(.{}, json_options, arena);
    }
    // A scalar or repeated field: its JSON within the message's.
    const full = try message.jsonEncode(.{}, json_options, arena);
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, full, .{ .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable, // jsonEncode wrote it
    };
    const field = value.object.get(comptime jsonName(response_body)) orelse value.object.get(response_body) orelse
        return comptime defaultJson(F, ftype);
    return std.json.Stringify.valueAlloc(arena, field, .{});
}

/// The JSON of a field jsonEncode leaves out for holding its default.
fn defaultJson(comptime F: type, comptime ftype: protobuf.FieldType) []const u8 {
    return switch (ftype) {
        .scalar => |s| if (@typeInfo(F) == .optional) "null" else switch (s) {
            .string, .bytes => "\"\"",
            .bool => "false",
            .int64, .uint64, .sint64, .fixed64, .sfixed64 => "\"0\"",
            else => "0",
        },
        .@"enum" => if (@typeInfo(F) == .optional) "null" else "\"" ++ @typeInfo(F).@"enum".field_names[0] ++ "\"",
        .submessage => if (@hasDecl(Unwrap(F), "jsonStringify")) "null" else "{}",
        .repeated, .packed_repeated => if (isMapEntry(@typeInfo(F.Slice).pointer.child)) "{}" else "[]",
        .oneof => unreachable,
    };
}

/// The JSON error body: google.rpc.Status, as grpc-gateway and Envoy send it.
pub fn errorBody(arena: std.mem.Allocator, code: u32, message: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{{\"code\":{d},\"message\":{f},\"details\":[]}}", .{ code, std.json.fmt(message, .{}) });
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

/// Serves one binding once its template matched.
pub const ServeFn = fn (ctx: ?*anyopaque, req: *dusty.Request, res: *dusty.Response, captures: []const Capture, options: *const server.RegisterOptions) anyerror!void;

/// The bindings that share one router route, tried in turn: those with a
/// verb first, then the others in the order they were registered.
const Binding = struct {
    template: *const Template,
    serve: *const ServeFn,
    options: *const server.RegisterOptions,
    where: []const u8,
    next: ?*Binding = null,
};

const Bindings = struct { first: ?*Binding = null };

/// The route handler shared by every transcoding route of a router.
fn Dispatch(comptime Ctx: type) type {
    return struct {
        fn run(ctx: ?*anyopaque, req: *dusty.Request, res: *dusty.Response) anyerror!void {
            const bindings: *const Bindings = @ptrCast(@alignCast(req.route.?.data.?));
            const path = req.url[0 .. std.mem.indexOfScalar(u8, req.url, '?') orelse req.url.len];
            var captures: [max_variables]Capture = undefined;
            var it = bindings.first;
            while (it) |b| : (it = b.next) {
                const found = b.template.match(path, &captures) orelse continue;
                return b.serve(ctx, req, res, found, b.options);
            }
            // The route matched and no binding did: a 404, as for no route.
            return error.NotFound;
        }

        pub const handle = if (Ctx == void) struct {
            fn h(req: *dusty.Request, res: *dusty.Response) anyerror!void {
                return run(null, req, res);
            }
        }.h else struct {
            fn h(ctx: *Ctx, req: *dusty.Request, res: *dusty.Response) anyerror!void {
                return run(ctx, req, res);
            }
        }.h;
    };
}

/// Adds the REST routes of one method's bindings to `router`.
pub fn registerMethod(
    comptime Ctx: type,
    target: anytype,
    comptime Service: type,
    comptime name: []const u8,
    comptime M: type,
    comptime handler: anytype,
    options: *const server.RegisterOptions,
) void {
    const where = Service.package ++ "." ++ Service.service_name ++ "." ++ name;
    inline for (comptime rules(Service, name)) |rule| {
        const B = struct {
            const template = Template.parse(rule.pattern) catch
                @compileError("google.api.http on " ++ where ++ ": invalid path template \"" ++ rule.pattern ++ "\"");
            comptime {
                validate(M.Request, M.Response, rule, template, where);
            }
            fn serve(ctx: ?*anyopaque, req: *dusty.Request, res: *dusty.Response, captures: []const Capture, opts: *const server.RegisterOptions) anyerror!void {
                return server.serveTranscoded(M, handler, rule.body, rule.response_body, ctx, req, res, captures, opts);
            }
        };
        addBinding(Ctx, target, rule.method, &B.template, B.serve, options, where ++ " (" ++ rule.pattern ++ ")", false);
    }
}

/// Adds one binding (its `template`, which lives as long as the router)
/// to `router`: its own route, or a route other bindings of the same shape
/// share. `serve` runs when the template matched, with `options` (whose
/// `data` it may read). `no_wait`: the route's requests may run on the
/// protocol's reader (`dusty.RouteOptions.no_wait`), for the first binding
/// that makes its route.
pub fn addBinding(
    comptime Ctx: type,
    target: anytype,
    method: dusty.Method,
    template: *const Template,
    serve: *const ServeFn,
    options: *const server.RegisterOptions,
    where: []const u8,
    no_wait: bool,
) void {
    const router = server.routerOf(Ctx, target);
    const alloc = router.arena.allocator();
    const binding = alloc.create(Binding) catch @panic("OOM");
    binding.* = .{ .template = template, .serve = serve, .options = options, .where = where };

    // The router path: literals as they are, `*` as a parameter, `**` as a
    // wildcard; a verb rides on a last literal, and is checked by the
    // binding after a parameter or wildcard. Parameter names follow the
    // route already at that position, if any (the router wants one name
    // per position, and the binding reads its values from the path, not
    // from the parameters).
    var path: std.ArrayList(u8) = .empty;
    var node = router.trees[@backingInt(method)];
    const segments = template.segments();
    for (segments, 0..) |segment, k| {
        path.append(alloc, '/') catch @panic("OOM");
        switch (segment) {
            .literal => |literal| {
                const last_with_verb = k == segments.len - 1 and template.verb.len > 0;
                const text = if (last_with_verb)
                    std.mem.concat(alloc, u8, &.{ literal, ":", template.verb }) catch @panic("OOM")
                else
                    literal;
                path.appendSlice(alloc, text) catch @panic("OOM");
                var found: @TypeOf(node) = null;
                if (node) |n| {
                    var child = n.static_children;
                    while (child) |c| : (child = c.next_sibling) {
                        if (std.mem.eql(u8, c.segment, text)) {
                            found = c;
                            break;
                        }
                    }
                }
                node = found;
            },
            .one, .rest => {
                const child = if (node) |n| (if (segment == .one) n.param_child else n.wildcard_child) else null;
                path.append(alloc, if (segment == .one) ':' else '*') catch @panic("OOM");
                const param = if (child) |c| c.param_name.? else defaultParamName(alloc, template, k);
                path.appendSlice(alloc, param) catch @panic("OOM");
                node = child;
            },
        }
    }
    if (segments.len == 0) path.append(alloc, '/') catch @panic("OOM");

    if (node) |n| if (n.route) |opaque_route| {
        const route: *const dusty.Router(Ctx).Route = @ptrCast(@alignCast(opaque_route));
        if (route.action != &Dispatch(Ctx).handle) {
            router.conflicted("google.api.http on {s}: {s} {s} is already a route", .{ where, method.name(), route.info.path }) catch @panic("OOM");
            return;
        }
        if (!sameChain(Ctx, route.middlewares, server.chainOf(Ctx, target))) {
            router.conflicted("google.api.http on {s}: {s} {s} is already a route of a service registered with other middleware", .{ where, method.name(), route.info.path }) catch @panic("OOM");
            return;
        }
        const bindings: *Bindings = @ptrCast(@alignCast(@constCast(route.info.data.?)));
        insert(bindings, binding, method);
        return;
    };
    const bindings = alloc.create(Bindings) catch @panic("OOM");
    bindings.* = .{ .first = binding };
    server.addRoute(Ctx, target, method, path.items, Dispatch(Ctx).handle, .{ .data = bindings, .no_wait = no_wait });
}

/// Whether two middleware chains are the same handles in the same order.
fn sameChain(comptime Ctx: type, a: []const dusty.Middleware(Ctx), b: []const dusty.Middleware(Ctx)) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x.ptr != y.ptr or x.executeFn != y.executeFn) return false;
    return true;
}

fn insert(bindings: *Bindings, binding: *Binding, method: dusty.Method) void {
    var it = bindings.first;
    while (it) |b| : (it = b.next) {
        if (b.template.sameShape(binding.template)) {
            std.debug.panic("google.api.http on {s}: {s} matches the same paths as {s}", .{ binding.where, method.name(), b.where });
        }
    }
    var link = &bindings.first;
    if (binding.template.verb.len > 0) {
        // After the other bindings with a verb, before those without.
        while (link.*) |b| : (link = &b.next) if (b.template.verb.len == 0) break;
    } else {
        while (link.*) |b| link = &b.next;
    }
    binding.next = link.*;
    link.* = binding;
}

/// A parameter's name when nothing is at its position yet: the variable's
/// field for a variable of exactly that segment, else its position.
fn defaultParamName(alloc: std.mem.Allocator, template: *const Template, k: usize) []const u8 {
    for (template.variables()) |v| {
        if (v.first == k and v.end == k + 1) return v.field;
    }
    return std.fmt.allocPrint(alloc, "_{d}", .{k}) catch @panic("OOM");
}

test "templates parse into segments, variables and a verb" {
    const t = try Template.parse("/v1/{name=shelves/*/books/*}:publish");
    try std.testing.expectEqual(@as(usize, 5), t.segments().len);
    try std.testing.expectEqualStrings("v1", t.segments()[0].literal);
    try std.testing.expectEqual(Segment.one, t.segments()[2]);
    try std.testing.expectEqualStrings("publish", t.verb);
    try std.testing.expectEqual(@as(usize, 1), t.variables().len);
    try std.testing.expectEqual(@as(u8, 1), t.variables()[0].first);
    try std.testing.expectEqual(@as(u8, 5), t.variables()[0].end);

    const files = try Template.parse("/files/*/{path=**}");
    try std.testing.expectEqual(Segment.rest, files.segments()[2]);
    const root = try Template.parse("/");
    try std.testing.expectEqual(@as(usize, 0), root.segments().len);
    const nested = try Template.parse("/v1/{book.name}/x:y");
    try std.testing.expectEqualStrings("book.name", nested.variables()[0].field);
    try std.testing.expectEqualStrings("y", nested.verb);

    for ([_][]const u8{
        "",         "v1",    "/v1/",  "/v1//x",   "/{a}/{a}",  "/{a=**}/x", "/**/x",
        "/{a",      "/{1a}", "/{a.}", "/{a=}",    "/v1:",      "/v1:a/b",   "/v1/{a}b",
        "/{a={b}}", "/a b",  "/a?b",  "/{a=b:c}", "/x/{a}{b}",
    }) |bad| {
        if (Template.parse(bad)) |_| {
            std.debug.print("accepted {s}\n", .{bad});
            return error.Accepted;
        } else |_| {}
    }
}

test "templates match paths and capture variables" {
    var out: [max_variables]Capture = undefined;
    const t = try Template.parse("/v1/{name=shelves/*/books/*}:publish");
    const c = t.match("/v1/shelves/s1/books/b%2F1:publish", &out).?;
    try std.testing.expectEqualStrings("shelves/s1/books/b%2F1", c[0].raw);
    try std.testing.expect(c[0].multi);
    try std.testing.expect(t.match("/v1/shelves/s1/books/b1", &out) == null);
    try std.testing.expect(t.match("/v1/shelves/s1/books:publish", &out) == null);
    try std.testing.expect(t.match("/v1/shelves/s1/papers/b1:publish", &out) == null);

    const files = try Template.parse("/files/*/{path=**}");
    try std.testing.expectEqualStrings("a/b/c.txt", files.match("/files/x/a/b/c.txt", &out).?[0].raw);
    const single = try Template.parse("/v1/books/{name}");
    const s = single.match("/v1/books/a:b", &out).?;
    try std.testing.expectEqualStrings("a:b", s[0].raw);
    try std.testing.expect(!s[0].multi);
    try std.testing.expect(single.match("/v1/books/a/b", &out) == null);
    try std.testing.expect(single.match("/v1/books", &out) == null);

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("a/b", try decodePath(a, "a%2Fb", false));
    try std.testing.expectEqualStrings("a%2Fb c", try decodePath(a, "a%2Fb%20c", true));
    try std.testing.expectError(error.InvalidEscape, decodePath(a, "a%2", false));
    try std.testing.expectError(error.InvalidEscape, decodePath(a, "a%zz", false));
}

test "fuzz: path templates parse and match without crashing" {
    try @import("../fuzz.zig").bytes(struct {
        fn check(input: []const u8) !void {
            // The template up to the first newline, a path after it.
            const nl = std.mem.indexOfScalar(u8, input, '\n') orelse input.len;
            const t = Template.parse(input[0..nl]) catch return;
            for (t.segments()[0..t.segments().len -| 1]) |s| if (s == .rest) return error.RestNotLast;
            for (t.variables()) |v| if (v.first >= v.end or v.end > t.segments().len) return error.BadVariable;
            const path = if (nl < input.len) input[nl + 1 ..] else "";
            var out: [max_variables]Capture = undefined;
            const captures = t.match(path, &out) orelse return;
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            for (captures) |c| {
                if (c.raw.len > path.len) return error.CaptureTooLong;
                _ = decodePath(arena.allocator(), c.raw, c.multi) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    error.InvalidEscape => {},
                };
            }
        }
    }.check, &.{
        "/v1/{name=shelves/*/books/*}:publish\n/v1/shelves/a/books/b:publish",
        "/files/*/{path=**}\n/files/x/a/b%2Fc",
        "/v1/books:batchGet\n/v1/books:batchGet",
        "/v1/{book.name}\n/v1/x%20y",
        "/{a=**}:v\n/x/y:v",
        "/\n/",
    });
}

test "JSON depth guard" {
    try std.testing.expect(jsonDepthWithin("{\"a\":[1,{\"b\":2}]}", 3));
    try std.testing.expect(!jsonDepthWithin("{\"a\":[1,{\"b\":2}]}", 2));
    try std.testing.expect(jsonDepthWithin("{\"a\":\"[[[[\"}", 1));
    try std.testing.expect(jsonDepthWithin("{\"a\":\"\\\"[[[[\"}", 1));
}
