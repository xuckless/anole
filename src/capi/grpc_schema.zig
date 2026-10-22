//! The descriptors of the C ABI's gRPC services: a FileDescriptorSet the
//! consumer gives (`protoc --include_imports --descriptor_set_out`, `buf
//! build -o`, or what its protobuf library emits), read two ways:
//!
//! - walked here at the wire level for what routing needs: each service's
//!   methods, their call modes, `idempotency_level` (Connect GET) and their
//!   `google.api.http` rules (JSON transcoding), which is an extension upb
//!   would keep as unknown bytes;
//! - handed to upb (protobuf's C runtime, through src/capi/upb_shim.c) for
//!   what needs the message types: JSON to protobuf bytes and back (the
//!   proto3 mapping, well-known types included) and the fields a
//!   transcoding path variable or query parameter names.
//!
//! Consumers always see protobuf bytes; JSON is Anole's side of the wire.
const std = @import("std");
const c = @import("anole_upb_c");
const anole = @import("../root.zig");
const transcode = anole.grpc.transcode;
const http = anole.http;

pub const MethodKind = anole.grpc.MethodKind;

pub const Method = struct {
    name: []const u8,
    /// The message types' full names, without the leading dot.
    input: []const u8,
    output: []const u8,
    kind: MethodKind,
    /// `option idempotency_level = NO_SIDE_EFFECTS`: Connect GET too.
    no_side_effects: bool = false,
    /// `google.api.http`: the rule, then its additional bindings.
    rules: []const transcode.Rule = &.{},
};

pub const Service = struct {
    /// "package.Service".
    name: []const u8,
    methods: []const Method,
};

pub const Schema = struct {
    pool: *c.anole_upb_pool,
    services: []const Service,

    pub fn deinit(s: *Schema) void {
        c.anole_upb_pool_free(s.pool);
    }

    pub fn service(s: *const Schema, name: []const u8) ?*const Service {
        for (s.services) |*svc| if (std.mem.eql(u8, svc.name, name)) return svc;
        return null;
    }

    /// A message type by its full name; null when the set has none.
    pub fn message(s: *const Schema, name: []const u8) ?*const anyopaque {
        return c.anole_upb_message(s.pool, name.ptr, name.len);
    }
};

pub const ParseError = error{ Invalid, OutOfMemory };

/// Reads `set` (a serialized FileDescriptorSet, which the schema's slices
/// point into: it must outlive the schema) into `arena`. `why` says what
/// is wrong on `error.Invalid`.
pub fn parse(arena: std.mem.Allocator, set: []const u8, why: *std.Io.Writer) ParseError!Schema {
    const pool = c.anole_upb_pool_new() orelse return error.OutOfMemory;
    errdefer c.anole_upb_pool_free(pool);
    var services: std.ArrayList(Service) = .empty;
    var files = Wire.init(set);
    while (files.next() catch return bad(why, "the descriptor set is not a FileDescriptorSet", .{})) |field| {
        if (field.number != 1) continue;
        const file = field.bytes() orelse return bad(why, "the descriptor set is not a FileDescriptorSet", .{});
        var err_buf: [256]u8 = undefined;
        if (c.anole_upb_pool_add_file(pool, file.ptr, file.len, &err_buf, err_buf.len) != 0) {
            return bad(why, "{s}", .{std.mem.sliceTo(&err_buf, 0)});
        }
        try readFile(arena, file, &services, why);
    }
    return .{ .pool = pool, .services = services.items };
}

fn bad(why: *std.Io.Writer, comptime fmt: []const u8, args: anytype) error{Invalid} {
    why.print("config: grpc.descriptor_set: " ++ fmt, args) catch {};
    return error.Invalid;
}

/// A FileDescriptorProto's services (field 6), named in its package (2).
fn readFile(arena: std.mem.Allocator, file: []const u8, services: *std.ArrayList(Service), why: *std.Io.Writer) ParseError!void {
    var package: []const u8 = "";
    var it = Wire.init(file);
    while (it.next() catch return bad(why, "a file descriptor does not decode", .{})) |f| {
        if (f.number == 2) package = f.bytes() orelse "";
    }
    it = Wire.init(file);
    while (it.next() catch unreachable) |f| {
        if (f.number != 6) continue;
        const svc = f.bytes() orelse return bad(why, "a service descriptor does not decode", .{});
        var name: []const u8 = "";
        var methods: std.ArrayList(Method) = .empty;
        var s = Wire.init(svc);
        while (s.next() catch return bad(why, "a service descriptor does not decode", .{})) |sf| switch (sf.number) {
            1 => name = sf.bytes() orelse "",
            2 => try methods.append(arena, try readMethod(arena, sf.bytes() orelse "", why)),
            else => {},
        };
        const full = if (package.len == 0) name else try std.fmt.allocPrint(arena, "{s}.{s}", .{ package, name });
        try services.append(arena, .{ .name = full, .methods = methods.items });
    }
}

/// A MethodDescriptorProto: name (1), input_type (2), output_type (3),
/// options (4), client_streaming (5), server_streaming (6).
fn readMethod(arena: std.mem.Allocator, bytes: []const u8, why: *std.Io.Writer) ParseError!Method {
    var m: Method = .{ .name = "", .input = "", .output = "", .kind = .unary };
    var client = false;
    var server = false;
    var options: []const u8 = "";
    var it = Wire.init(bytes);
    while (it.next() catch return bad(why, "a method descriptor does not decode", .{})) |f| switch (f.number) {
        1 => m.name = f.bytes() orelse "",
        2 => m.input = std.mem.trimStart(u8, f.bytes() orelse "", "."),
        3 => m.output = std.mem.trimStart(u8, f.bytes() orelse "", "."),
        4 => options = f.bytes() orelse "",
        5 => client = f.varint != 0,
        6 => server = f.varint != 0,
        else => {},
    };
    m.kind = if (client and server) .bidi_streaming else if (client) .client_streaming else if (server) .server_streaming else .unary;
    // MethodOptions: idempotency_level (34), google.api.http (72295728).
    var rules: std.ArrayList(transcode.Rule) = .empty;
    var o = Wire.init(options);
    while (o.next() catch return bad(why, "{s}: the options do not decode", .{m.name})) |f| switch (f.number) {
        34 => m.no_side_effects = f.varint == 1,
        http_extension => try readRule(arena, f.bytes() orelse "", &rules, m.name, why, 0),
        else => {},
    };
    m.rules = rules.items;
    return m;
}

/// google.api.http's field number in google.protobuf.MethodOptions.
const http_extension = 72295728;

/// An HttpRule (google/api/http.proto): get (2), put (3), post (4),
/// delete (5), patch (6), custom (8: kind 1, path 2), body (7),
/// response_body (12), additional_bindings (11, one level deep).
fn readRule(arena: std.mem.Allocator, bytes: []const u8, rules: *std.ArrayList(transcode.Rule), method: []const u8, why: *std.Io.Writer, depth: u8) ParseError!void {
    var rule: ?transcode.Rule = null;
    var body: []const u8 = "";
    var response_body: []const u8 = "";
    var extra: std.ArrayList([]const u8) = .empty;
    var it = Wire.init(bytes);
    while (it.next() catch return bad(why, "{s}: google.api.http does not decode", .{method})) |f| switch (f.number) {
        2, 3, 4, 5, 6 => rule = .{
            .method = switch (f.number) {
                2 => .get,
                3 => .put,
                4 => .post,
                5 => .delete,
                else => .patch,
            },
            .pattern = f.bytes() orelse "",
        },
        8 => {
            var kind: []const u8 = "";
            var path: []const u8 = "";
            var cit = Wire.init(f.bytes() orelse "");
            while (cit.next() catch return bad(why, "{s}: google.api.http does not decode", .{method})) |cf| switch (cf.number) {
                1 => kind = cf.bytes() orelse "",
                2 => path = cf.bytes() orelse "",
                else => {},
            };
            var lower: [16]u8 = undefined;
            const name = if (kind.len <= lower.len) std.ascii.lowerString(&lower, kind) else "";
            const verb = std.meta.stringToEnum(http.Method, name) orelse
                return bad(why, "{s}: google.api.http: unknown HTTP method \"{s}\"", .{ method, kind });
            rule = .{ .method = verb, .pattern = path };
        },
        7 => body = f.bytes() orelse "",
        12 => response_body = f.bytes() orelse "",
        11 => if (depth == 0) try extra.append(arena, f.bytes() orelse ""),
        else => {},
    };
    var r = rule orelse return bad(why, "{s}: google.api.http has no path pattern", .{method});
    r.body = body;
    r.response_body = response_body;
    try rules.append(arena, r);
    for (extra.items) |e| try readRule(arena, e, rules, method, why, depth + 1);
}

/// Protobuf's wire format, as far as descriptors need it.
const Wire = struct {
    bytes: []const u8,
    pos: usize = 0,

    const Field = struct {
        number: u32,
        wire_type: u3,
        varint: u64 = 0,
        data: []const u8 = "",

        fn bytes(f: Field) ?[]const u8 {
            return if (f.wire_type == 2) f.data else null;
        }
    };

    fn init(bytes: []const u8) Wire {
        return .{ .bytes = bytes };
    }

    fn varint(w: *Wire) error{Malformed}!u64 {
        var out: u64 = 0;
        var shift: u7 = 0;
        while (true) {
            if (w.pos >= w.bytes.len or shift > 63) return error.Malformed;
            const b = w.bytes[w.pos];
            w.pos += 1;
            out |= @as(u64, b & 0x7f) << @intCast(shift);
            if (b & 0x80 == 0) return out;
            shift += 7;
        }
    }

    fn next(w: *Wire) error{Malformed}!?Field {
        if (w.pos >= w.bytes.len) return null;
        const key = try w.varint();
        const number = std.math.cast(u32, key >> 3) orelse return error.Malformed;
        var f: Field = .{ .number = number, .wire_type = @truncate(key) };
        switch (f.wire_type) {
            0 => f.varint = try w.varint(),
            1 => {
                if (w.bytes.len - w.pos < 8) return error.Malformed;
                w.pos += 8;
            },
            2 => {
                const len = try w.varint();
                if (len > w.bytes.len - w.pos) return error.Malformed;
                f.data = w.bytes[w.pos..][0..@intCast(len)];
                w.pos += @intCast(len);
            },
            5 => {
                if (w.bytes.len - w.pos < 4) return error.Malformed;
                w.pos += 4;
            },
            // Groups (3, 4) are not in descriptors.
            else => return error.Malformed,
        }
        return f;
    }
};

// ---------------------------------------------------------------------------
// JSON and protobuf bytes

pub const ConvertError = error{ DecodeFailed, OutOfMemory };

/// JSON text of `msg_type` (the proto3 mapping; fields it does not have
/// are skipped, as Connect and transcoding expect) to protobuf bytes, in
/// `arena`.
pub fn jsonToBinary(s: *const Schema, msg_type: *const anyopaque, json: []const u8, arena: std.mem.Allocator, why: ?*[]const u8) ConvertError![]const u8 {
    var out: [*c]u8 = null;
    var len: usize = 0;
    var err_buf: [256]u8 = undefined;
    err_buf[0] = 0;
    switch (c.anole_upb_json_to_binary(s.pool, msg_type, json.ptr, json.len, 1, &out, &len, &err_buf, err_buf.len)) {
        0 => {},
        -2 => return error.OutOfMemory,
        else => {
            if (why) |w| w.* = arena.dupe(u8, std.mem.sliceTo(&err_buf, 0)) catch "";
            return error.DecodeFailed;
        },
    }
    defer c.anole_upb_free(out);
    if (len == 0) return "";
    return arena.dupe(u8, out[0..len]);
}

/// Protobuf bytes of `msg_type` to JSON text, with `allocator` (its fields
/// at their defaults too with `emit_defaults`).
pub fn binaryToJson(s: *const Schema, msg_type: *const anyopaque, bytes: []const u8, allocator: std.mem.Allocator, emit_defaults: bool) ConvertError![]u8 {
    var out: [*c]u8 = null;
    var len: usize = 0;
    var err_buf: [256]u8 = undefined;
    switch (c.anole_upb_binary_to_json(s.pool, msg_type, bytes.ptr, bytes.len, @intFromBool(emit_defaults), &out, &len, &err_buf, err_buf.len)) {
        0 => {},
        -2 => return error.OutOfMemory,
        else => return error.DecodeFailed,
    }
    defer c.anole_upb_free(out);
    return allocator.dupe(u8, out[0..len]);
}

/// One field of `json` (an object, as `binaryToJson` wrote it with
/// `emit_defaults`), by its proto name: transcoding's `response_body`.
/// JSON `{}` for a message field left out, `null` for anything else.
pub fn jsonField(arena: std.mem.Allocator, msg_type: *const anyopaque, json: []const u8, name: []const u8) ![]const u8 {
    var f: c.anole_upb_field = undefined;
    if (c.anole_upb_find_field(msg_type, name.ptr, name.len, &f) != 0) return "null";
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{ .parse_numbers = false }) catch return error.DecodeFailed;
    if (value != .object) return error.DecodeFailed;
    const proto_name = std.mem.span(f.name);
    const json_name = try jsonNameAlloc(arena, proto_name);
    const field = value.object.get(json_name) orelse value.object.get(proto_name) orelse
        return if (f.kind == c.ANOLE_UPB_MESSAGE or f.kind == c.ANOLE_UPB_MAP) "{}" else "null";
    return std.json.Stringify.valueAlloc(arena, field, .{});
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

// ---------------------------------------------------------------------------
// Fields, for transcoding

/// `transcode.requestJson`'s field lookup over a message type known at run
/// time: what a dotted path (proto or JSON names) names in it.
pub const Fields = struct {
    root: *const anyopaque,

    pub fn lookup(self: Fields, path: []const u8, names: *transcode.Names) ?transcode.Leaf {
        var msg = self.root;
        var it = std.mem.splitScalar(u8, path, '.');
        while (it.next()) |segment| {
            var f: c.anole_upb_field = undefined;
            if (c.anole_upb_find_field(msg, segment.ptr, segment.len, &f) != 0) return null;
            if (!names.append(std.mem.span(f.name))) return null;
            const last = it.peek() == null;
            const kind: transcode.Kind = switch (f.kind) {
                c.ANOLE_UPB_STRING => .string,
                c.ANOLE_UPB_BYTES => .bytes,
                c.ANOLE_UPB_BOOL => .bool,
                c.ANOLE_UPB_NUMBER => .number,
                c.ANOLE_UPB_ENUM => .enumeration,
                c.ANOLE_UPB_WKT_TEXT => .wkt_text,
                c.ANOLE_UPB_WKT_BOOL => .wkt_bool,
                c.ANOLE_UPB_MAP => .map,
                else => .message,
            };
            if (kind == .message and !last) {
                if (f.repeated != 0) return null;
                msg = f.message.?;
                continue;
            }
            if (!last) return null;
            var leaf: transcode.Leaf = .{ .kind = kind, .repeated = f.repeated != 0 };
            if (kind == .enumeration) {
                leaf.known_in = enumHas;
                leaf.enum_ctx = f.enumdef;
            }
            return leaf;
        }
        return null;
    }

    fn enumHas(ctx: *const anyopaque, name: []const u8) bool {
        return c.anole_upb_enum_has(ctx, name.ptr, name.len) != 0;
    }
};

/// Checks a binding against its method's types, as `transcode.validate`
/// does at compile time for generated services: each path variable names
/// a single field of a primitive type, `body` a top-level field (or `*`),
/// `response_body` a top-level field.
pub fn checkRule(input: *const anyopaque, output: *const anyopaque, rule: transcode.Rule, template: *const transcode.Template, where: []const u8, why: *std.Io.Writer) error{Invalid}!void {
    for (template.variables()) |v| {
        var names: transcode.Names = .{};
        const leaf = (Fields{ .root = input }).lookup(v.field, &names) orelse
            return bad(why, "google.api.http on {s}: {s} is not a field of the request", .{ where, v.field });
        if (leaf.repeated or leaf.kind == .message or leaf.kind == .map)
            return bad(why, "google.api.http on {s}: path variable {s} must be a single field of a primitive type", .{ where, v.field });
    }
    var f: c.anole_upb_field = undefined;
    if (rule.body.len > 0 and !std.mem.eql(u8, rule.body, "*")) {
        if (std.mem.indexOfScalar(u8, rule.body, '.') != null or c.anole_upb_find_field(input, rule.body.ptr, rule.body.len, &f) != 0)
            return bad(why, "google.api.http on {s}: body \"{s}\" is not a top-level field of the request", .{ where, rule.body });
    }
    if (rule.response_body.len > 0) {
        if (c.anole_upb_find_field(output, rule.response_body.ptr, rule.response_body.len, &f) != 0)
            return bad(why, "google.api.http on {s}: response_body \"{s}\" is not a top-level field of the response", .{ where, rule.response_body });
    }
}

test "capi grpc: the wire walker reads varints, lengths and skips fixed fields" {
    // field 1 varint 150, field 2 bytes "hi", field 3 fixed32, field 4 fixed64.
    const bytes = [_]u8{ 0x08, 0x96, 0x01, 0x12, 0x02, 'h', 'i', 0x1d, 1, 2, 3, 4, 0x21, 1, 2, 3, 4, 5, 6, 7, 8 };
    var w = Wire.init(&bytes);
    const a = (try w.next()).?;
    try std.testing.expectEqual(@as(u64, 150), a.varint);
    try std.testing.expectEqualStrings("hi", (try w.next()).?.bytes().?);
    try std.testing.expectEqual(@as(u32, 3), (try w.next()).?.number);
    try std.testing.expectEqual(@as(u32, 4), (try w.next()).?.number);
    try std.testing.expect(try w.next() == null);
    var cut = Wire.init(&.{ 0x12, 0x05, 'a' });
    try std.testing.expectError(error.Malformed, cut.next());
}
