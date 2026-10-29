//! Protobuf services in the OpenAPI document (`-Dgrpc`): the schemas of
//! messages by the proto3 JSON mapping (what Connect and transcoding encode)
//! and the operations of a service's methods, read at compile time from the
//! tables zig-protobuf generates (`_desc_table`, `_method_options`,
//! `_field_options`, and the `_doc` / `_field_docs` / `_method_docs` comments
//! of the xuckless/zig-protobuf fork).
//!
//! Per unary method: a Connect form (`POST /pkg.Svc/Method`, plus `GET` for
//! NO_SIDE_EFFECTS) and, when `google.api.http` annotates it, the REST
//! bindings. A server-streaming method appears in its transcoded form only
//! (the whole stream as one JSON array). Client and bidi streams have no
//! form. Which forms the document keeps is decided when it is assembled
//! (`Options.grpc`), so each operation says whether it was annotated.
const std = @import("std");
const protobuf = @import("protobuf");
const json = @import("json.zig");
const operation = @import("operation.zig");
const schema = @import("schema.zig");
const transcode = @import("../grpc/transcode.zig");
const server = @import("../grpc/server.zig");

const Operation = operation.Operation;
pub const Component = json.Component;

// ------------------------------------------------------------------ fixed components

/// `ConnectError`: the error body of the Connect protocol.
pub const connect_error: Component = .{
    .name = "ConnectError",
    .type_name = "anole.openapi.ConnectError",
    .schema = obj(&.{
        m("type", str("object")),
        m("description", str("The HTTP status follows the code (Connect protocol).")),
        m("required", arr(&.{str("code")})),
        m("properties", obj(&.{
            m("code", obj(&.{
                m("type", str("string")),
                m("enum", arr(&.{
                    str("canceled"),            str("unknown"),        str("invalid_argument"),  str("deadline_exceeded"),
                    str("not_found"),           str("already_exists"), str("permission_denied"), str("resource_exhausted"),
                    str("failed_precondition"), str("aborted"),        str("out_of_range"),      str("unimplemented"),
                    str("internal"),            str("unavailable"),    str("data_loss"),         str("unauthenticated"),
                })),
            })),
            m("message", obj(&.{m("type", str("string"))})),
            m("details", obj(&.{
                m("type", str("array")),
                m("items", obj(&.{
                    m("type", str("object")),
                    m("properties", obj(&.{
                        m("type", obj(&.{m("type", str("string"))})),
                        m("value", obj(&.{ m("type", str("string")), m("format", str("byte")) })),
                        m("debug", obj(&.{})),
                    })),
                })),
            })),
        })),
    }),
    .deps = &.{},
};

/// `Status`: google.rpc.Status, the error body of transcoded routes.
pub const status_error: Component = .{
    .name = "Status",
    .type_name = "anole.openapi.Status",
    .schema = obj(&.{
        m("type", str("object")),
        m("description", str("google.rpc.Status: the gRPC status of a failed call.")),
        m("properties", obj(&.{
            m("code", obj(&.{ m("type", str("integer")), m("format", str("int32")) })),
            m("message", obj(&.{m("type", str("string"))})),
            m("details", obj(&.{ m("type", str("array")), m("items", obj(&.{})) })),
        })),
    }),
    .deps = &.{},
};

fn connectErrorFn() *const Component {
    return &connect_error;
}
fn statusErrorFn() *const Component {
    return &status_error;
}
pub const connect_error_ref: json.Node = .{ .ref = &connectErrorFn };
pub const status_error_ref: json.Node = .{ .ref = &statusErrorFn };

// ------------------------------------------------------------------ node builders

fn m(comptime key: []const u8, comptime value: json.Node) json.Member {
    return .{ .key = key, .value = value };
}
fn obj(comptime members: []const json.Member) json.Node {
    return .{ .object = members };
}
fn arr(comptime items: []const json.Node) json.Node {
    return .{ .array = items };
}
fn str(comptime s: []const u8) json.Node {
    return .{ .string = s };
}
fn raw(comptime s: []const u8) json.Node {
    return .{ .raw = s };
}
fn typeOnly(comptime t: []const u8) json.Node {
    return obj(&.{m("type", str(t))});
}
fn typeFormat(comptime t: []const u8, comptime f: []const u8) json.Node {
    return obj(&.{ m("type", str(t)), m("format", str(f)) });
}
/// `node` or null.
fn orNull(comptime node: json.Node) json.Node {
    return obj(&.{m("oneOf", arr(&.{ node, typeOnly("null") }))});
}
/// `node` with a description and flags, as an object (a ref goes under allOf).
fn annotate(comptime node: json.Node, comptime description: ?[]const u8, comptime deprecated: bool, comptime read_only: bool, comptime write_only: bool) json.Node {
    if (description == null and !deprecated and !read_only and !write_only) return node;
    var members: []const json.Member = &.{};
    if (description) |d| members = members ++ [_]json.Member{m("description", str(d))};
    if (deprecated) members = members ++ [_]json.Member{m("deprecated", .{ .boolean = true })};
    if (read_only) members = members ++ [_]json.Member{m("readOnly", .{ .boolean = true })};
    if (write_only) members = members ++ [_]json.Member{m("writeOnly", .{ .boolean = true })};
    switch (node) {
        .object => |own| return obj(own ++ members),
        else => return obj(members ++ [_]json.Member{m("allOf", arr(&.{node}))}),
    }
}

// ------------------------------------------------------------------ messages

/// The component of a message or an enum type: its protojson schema.
pub fn componentOf(comptime T: type) *const Component {
    return &Holder(T).value;
}

fn Holder(comptime T: type) type {
    return struct {
        pub const value: Component = .{
            .name = schema.schemaName(@typeName(T)),
            .type_name = @typeName(T),
            .schema = blk: {
                @setEvalBranchQuota(quota);
                break :blk if (@typeInfo(T) == .@"enum") enumSchema(T) else messageSchema(T);
            },
            .deps = blk: {
                @setEvalBranchQuota(quota);
                break :blk if (@typeInfo(T) == .@"enum") &.{} else messageDeps(T);
            },
        };
        fn get() *const Component {
            return &value;
        }
    };
}

const quota = 10_000_000;

fn refTo(comptime T: type) json.Node {
    return .{ .ref = &Holder(T).get };
}

/// The schema of a use of the message or enum `T`: a `$ref` to its component
/// (well-known types stand inline).
pub fn schemaOf(comptime T: type) json.Node {
    comptime {
        @setEvalBranchQuota(quota);
        return if (@typeInfo(T) == .@"enum") refTo(T) else messageNode(T);
    }
}

/// The components a use of `T` refers to directly.
pub fn depsOf(comptime T: type) []const json.RefFn {
    comptime {
        @setEvalBranchQuota(quota);
        if (@typeInfo(T) == .@"enum") return &.{&Holder(T).get};
        if (wkt(T) != null) return &.{};
        return &.{&Holder(T).get};
    }
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

fn isProtoField(comptime T: type, comptime name: []const u8) bool {
    return @hasDecl(T, "_desc_table") and @hasField(@TypeOf(T._desc_table), name);
}

fn enumSchema(comptime E: type) json.Node {
    const info = @typeInfo(E).@"enum";
    var names: []const json.Node = &.{};
    for (info.field_names) |name| names = names ++ [_]json.Node{str(name)};
    var members: []const json.Member = &.{ m("type", str("string")), m("enum", arr(names)) };
    if (docOf(E)) |d| members = members ++ [_]json.Member{m("description", str(d))};
    return obj(members);
}

/// The comment of a message or enum, if the generator emitted one.
fn docOf(comptime T: type) ?[]const u8 {
    if (@hasDecl(T, "_doc")) return T._doc;
    return null;
}

fn fieldDoc(comptime T: type, comptime name: []const u8) ?[]const u8 {
    if (!@hasDecl(T, "_field_docs")) return null;
    if (!@hasField(@TypeOf(T._field_docs), name)) return null;
    return @field(T._field_docs, name);
}

const Behavior = struct { required: bool = false, output_only: bool = false, input_only: bool = false, deprecated: bool = false };

/// `[(google.api.field_behavior) = REQUIRED]`, `OUTPUT_ONLY`, `INPUT_ONLY`
/// and `[deprecated = true]` of a field.
fn behaviorOf(comptime T: type, comptime name: []const u8) Behavior {
    var b: Behavior = .{};
    if (!@hasDecl(T, "_field_options")) return b;
    if (!@hasField(@TypeOf(T._field_options), name)) return b;
    const o = @field(T._field_options, name);
    const O = @TypeOf(o);
    if (@hasField(O, "deprecated")) b.deprecated = o.deprecated;
    if (@hasField(O, "google.api.field_behavior")) {
        const v = @field(o, "google.api.field_behavior");
        const V = @TypeOf(v);
        switch (@typeInfo(V)) {
            .@"struct" => |s| inline for (0..s.field_names.len) |i| markBehavior(&b, @tagName(v[i])),
            .@"enum" => markBehavior(&b, @tagName(v)),
            .pointer => for (v) |item| markBehavior(&b, @tagName(item)),
            else => {},
        }
    }
    return b;
}

fn markBehavior(comptime b: *Behavior, comptime tag: []const u8) void {
    if (std.mem.eql(u8, tag, "REQUIRED")) b.required = true;
    if (std.mem.eql(u8, tag, "OUTPUT_ONLY")) b.output_only = true;
    if (std.mem.eql(u8, tag, "INPUT_ONLY")) b.input_only = true;
}

/// One property of a message schema.
const Prop = struct { key: []const u8, node: json.Node, required: bool };

fn propFor(comptime T: type, comptime name: []const u8, comptime F: type, comptime ft: protobuf.FieldType) Prop {
    const b = behaviorOf(T, name);
    var node = valueNode(F, ft);
    // proto3 `optional` scalars may be null on input.
    if (ft == .scalar and @typeInfo(F) == .optional) node = orNull(node);
    return .{
        .key = transcode.jsonName(name),
        .node = annotate(node, fieldDoc(T, name), b.deprecated, b.output_only, b.input_only),
        .required = b.required,
    };
}

fn messageSchema(comptime T: type) json.Node {
    const info = @typeInfo(T).@"struct";
    var props: []const json.Member = &.{};
    var required: []const json.Node = &.{};
    for (info.field_names, info.field_types) |name, F| {
        if (name.len > 0 and name[0] == '_') continue;
        if (!isProtoField(T, name)) continue;
        const ft = @field(T._desc_table, name).ftype;
        if (ft == .oneof) {
            const U = Unwrap(F);
            const union_info = @typeInfo(U).@"union";
            var listed: []const u8 = "";
            for (union_info.field_names, 0..) |member, i| listed = listed ++ (if (i > 0) ", " else "") ++ member;
            for (union_info.field_names, union_info.field_types) |member, MF| {
                const mft = @field(U._desc_table, member).ftype;
                var p = propFor(T, member, MF, mft);
                p.node = annotate(p.node, "At most one of: " ++ listed ++ ".", false, false, false);
                props = props ++ [_]json.Member{m(p.key, p.node)};
                if (p.required) required = required ++ [_]json.Node{str(p.key)};
            }
            continue;
        }
        const p = propFor(T, name, F, ft);
        props = props ++ [_]json.Member{m(p.key, p.node)};
        if (p.required) required = required ++ [_]json.Node{str(p.key)};
    }
    var members: []const json.Member = &.{m("type", str("object"))};
    if (docOf(T)) |d| members = members ++ [_]json.Member{m("description", str(d))};
    if (required.len > 0) members = members ++ [_]json.Member{m("required", arr(required))};
    members = members ++ [_]json.Member{m("properties", obj(props))};
    return obj(members);
}

fn messageDeps(comptime T: type) []const json.RefFn {
    const info = @typeInfo(T).@"struct";
    var out: []const json.RefFn = &.{};
    for (info.field_names, info.field_types) |name, F| {
        if (name.len > 0 and name[0] == '_') continue;
        if (!isProtoField(T, name)) continue;
        const ft = @field(T._desc_table, name).ftype;
        if (ft == .oneof) {
            const U = Unwrap(F);
            const union_info = @typeInfo(U).@"union";
            for (union_info.field_names, union_info.field_types) |member, MF| {
                out = out ++ fieldDeps(MF, @field(U._desc_table, member).ftype);
            }
            continue;
        }
        out = out ++ fieldDeps(F, ft);
    }
    return out;
}

fn fieldDeps(comptime F: type, comptime ft: protobuf.FieldType) []const json.RefFn {
    switch (ft) {
        .scalar => return &.{},
        .@"enum" => return depsOf(Unwrap(F)),
        .submessage => return depsOf(Unwrap(F)),
        .repeated, .packed_repeated => |r| {
            const Elem = @typeInfo(F.Slice).pointer.child;
            if (isMapEntry(Elem)) return fieldDeps(@FieldType(Elem, "value"), @field(Elem._desc_table, "value").ftype);
            return switch (r) {
                .scalar => &.{},
                .@"enum", .submessage => depsOf(Elem),
            };
        },
        .oneof => return &.{},
    }
}

/// The schema of a field's value, by the proto3 JSON mapping.
fn valueNode(comptime F: type, comptime ft: protobuf.FieldType) json.Node {
    switch (ft) {
        .scalar => |s| return scalarNode(s),
        .@"enum" => return refTo(Unwrap(F)),
        .submessage => return messageNode(Unwrap(F)),
        .repeated, .packed_repeated => |r| {
            const Elem = @typeInfo(F.Slice).pointer.child;
            if (isMapEntry(Elem)) {
                const V = @FieldType(Elem, "value");
                return obj(&.{
                    m("type", str("object")),
                    m("additionalProperties", valueNode(V, @field(Elem._desc_table, "value").ftype)),
                });
            }
            const item: json.Node = switch (r) {
                .scalar => |s| scalarNode(s),
                .@"enum" => refTo(Elem),
                .submessage => messageNode(Elem),
            };
            return obj(&.{ m("type", str("array")), m("items", item) });
        },
        .oneof => unreachable,
    }
}

fn scalarNode(comptime s: protobuf.FieldType.Scalar) json.Node {
    return switch (s) {
        .string => typeOnly("string"),
        .bytes => typeFormat("string", "byte"),
        .bool => typeOnly("boolean"),
        .int32, .sint32, .sfixed32 => typeFormat("integer", "int32"),
        .uint32, .fixed32 => obj(&.{ m("type", str("integer")), m("format", str("uint32")), m("minimum", raw("0")) }),
        // protojson writes 64-bit integers as strings.
        .int64, .sint64, .sfixed64 => typeFormat("string", "int64"),
        .uint64, .fixed64 => typeFormat("string", "uint64"),
        .float => typeFormat("number", "float"),
        .double => typeFormat("number", "double"),
    };
}

/// A message type's schema: a well-known type inline, else a `$ref`.
fn messageNode(comptime M: type) json.Node {
    if (wkt(M)) |node| return node;
    return refTo(M);
}

/// The JSON shapes of the well-known types.
fn wkt(comptime M: type) ?json.Node {
    const w = protobuf.wkt;
    if (M == w.Timestamp) return typeFormat("string", "date-time");
    if (M == w.Duration) return obj(&.{ m("type", str("string")), m("pattern", str("^-?[0-9]+(\\.[0-9]+)?s$")) });
    if (M == w.FieldMask) return typeOnly("string");
    if (M == w.StringValue) return orNull(typeOnly("string"));
    if (M == w.BytesValue) return orNull(typeFormat("string", "byte"));
    if (M == w.BoolValue) return orNull(typeOnly("boolean"));
    if (M == w.Int32Value) return orNull(typeFormat("integer", "int32"));
    if (M == w.UInt32Value) return orNull(typeFormat("integer", "uint32"));
    if (M == w.Int64Value) return orNull(typeFormat("string", "int64"));
    if (M == w.UInt64Value) return orNull(typeFormat("string", "uint64"));
    if (M == w.FloatValue) return orNull(typeFormat("number", "float"));
    if (M == w.DoubleValue) return orNull(typeFormat("number", "double"));
    if (M == w.Struct) return typeOnly("object");
    if (M == w.Value) return obj(&.{});
    if (M == w.ListValue) return obj(&.{ m("type", str("array")), m("items", obj(&.{})) });
    if (M == w.Any) return obj(&.{
        m("type", str("object")),
        m("properties", obj(&.{m("@type", typeOnly("string"))})),
        m("additionalProperties", .{ .boolean = true }),
    });
    if (M == w.Empty) return obj(&.{ m("type", str("object")), m("properties", obj(&.{})) });
    return null;
}

// ------------------------------------------------------------------ path templates

/// A path parameter of a transcoded route.
pub const PathParam = struct {
    /// The parameter's name in the OpenAPI path.
    name: []const u8,
    /// The proto field path it fills (`author.name`); for a multi-segment
    /// variable, the same for each of its parameters.
    field: []const u8,
    description: ?[]const u8 = null,
    rest_of_path: bool = false,
    /// Whether the parameter is a whole field (its schema), or a string
    /// segment of one.
    whole_field: bool = true,
};

/// The OpenAPI path of a template and its parameters:
/// - `{field}` / `{field=*}` -> `{field}`;
/// - `{field=lit/*/lit/*}` -> literals kept, each `*` a string parameter
///   `field_1`, `field_2`;
/// - `**` (rest of the path) -> a parameter `field`, `x-anole-rest-of-path`;
/// - a `:verb` suffix stays literal.
pub fn templatePath(comptime t: transcode.Template) struct { path: []const u8, params: []const PathParam } {
    comptime {
        var path: []const u8 = "";
        var params: []const PathParam = &.{};
        const segs = t.segments();
        if (segs.len == 0) path = "/";
        var k: usize = 0;
        while (k < segs.len) {
            var var_of: ?transcode.Variable = null;
            for (t.variables()) |v| {
                if (v.first == k) var_of = v;
            }
            if (var_of) |v| {
                const count = v.end - v.first;
                if (count == 1 and segs[k] == .one) {
                    path = path ++ "/{" ++ v.field ++ "}";
                    params = params ++ [_]PathParam{.{ .name = v.field, .field = v.field }};
                } else if (count == 1 and segs[k] == .rest) {
                    path = path ++ "/{" ++ v.field ++ "}";
                    params = params ++ [_]PathParam{.{
                        .name = v.field,
                        .field = v.field,
                        .description = "The rest of the path; slashes as they are.",
                        .rest_of_path = true,
                    }};
                } else {
                    var n: usize = 0;
                    var template_text: []const u8 = "";
                    for (segs[v.first..v.end]) |s| {
                        switch (s) {
                            .literal => |lit| {
                                path = path ++ "/" ++ lit;
                                template_text = template_text ++ "/" ++ lit;
                            },
                            .one => {
                                n += 1;
                                const pname = v.field ++ "_" ++ std.fmt.comptimePrint("{d}", .{n});
                                path = path ++ "/{" ++ pname ++ "}";
                                template_text = template_text ++ "/{" ++ pname ++ "}";
                                params = params ++ [_]PathParam{.{ .name = pname, .field = v.field, .whole_field = false }};
                            },
                            .rest => {
                                path = path ++ "/{" ++ v.field ++ "}";
                                params = params ++ [_]PathParam{.{
                                    .name = v.field,
                                    .field = v.field,
                                    .description = "The rest of the path; slashes as they are.",
                                    .rest_of_path = true,
                                    .whole_field = false,
                                }};
                            },
                        }
                    }
                    // Describe each segment parameter once the count is known.
                    var fixed: []const PathParam = &.{};
                    for (params) |p| {
                        if (!p.whole_field and !p.rest_of_path and std.mem.eql(u8, p.field, v.field)) {
                            var q = p;
                            q.description = "A segment of `" ++ v.field ++ "` (`" ++ std.mem.trimStart(u8, template_text, "/") ++ "`); the server joins the segments.";
                            fixed = fixed ++ [_]PathParam{q};
                        } else fixed = fixed ++ [_]PathParam{p};
                    }
                    params = fixed;
                }
                k = v.end;
            } else {
                switch (segs[k]) {
                    .literal => |lit| path = path ++ "/" ++ lit,
                    .one => {
                        path = path ++ "/{wildcard}";
                        params = params ++ [_]PathParam{.{ .name = "wildcard", .field = "", .whole_field = false }};
                    },
                    .rest => {
                        path = path ++ "/{rest}";
                        params = params ++ [_]PathParam{.{
                            .name = "rest",
                            .field = "",
                            .description = "The rest of the path; slashes as they are.",
                            .rest_of_path = true,
                            .whole_field = false,
                        }};
                    },
                }
                k += 1;
            }
        }
        if (t.verb.len > 0) path = path ++ ":" ++ t.verb;
        return .{ .path = path, .params = params };
    }
}

// ------------------------------------------------------------------ fields by path

const FieldRef = struct { Parent: type, name: []const u8, F: type, ft: protobuf.FieldType };

/// The field a (possibly dotted) path names, by its proto name or its JSON name.
fn fieldAt(comptime T: type, comptime path: []const u8) ?FieldRef {
    const dot = std.mem.indexOfScalar(u8, path, '.');
    const head = path[0 .. dot orelse path.len];
    if (@typeInfo(T) != .@"struct") return null;
    inline for (@typeInfo(T).@"struct".field_names) |name| {
        if (comptime (name.len > 0 and name[0] != '_' and isProtoField(T, name))) {
            if (std.mem.eql(u8, head, name) or std.mem.eql(u8, head, comptime transcode.jsonName(name))) {
                const ft = @field(T._desc_table, name).ftype;
                const F = @FieldType(T, name);
                if (dot) |d| {
                    if (ft != .submessage) return null;
                    return fieldAt(Unwrap(F), path[d + 1 ..]);
                }
                return .{ .Parent = T, .name = name, .F = F, .ft = ft };
            }
        }
    }
    return null;
}

/// A parameter's schema: inline (a path or query parameter lists its enum values).
fn paramValueNode(comptime F: type, comptime ft: protobuf.FieldType) json.Node {
    switch (ft) {
        .@"enum" => return enumInline(Unwrap(F)),
        .repeated, .packed_repeated => |r| {
            const Elem = @typeInfo(F.Slice).pointer.child;
            const item: json.Node = switch (r) {
                .scalar => |s| scalarNode(s),
                .@"enum" => enumInline(Elem),
                .submessage => messageNode(Elem),
            };
            return obj(&.{ m("type", str("array")), m("items", item) });
        },
        else => return valueNode(F, ft),
    }
}

fn enumInline(comptime E: type) json.Node {
    const info = @typeInfo(E).@"enum";
    var names: []const json.Node = &.{};
    for (info.field_names) |name| names = names ++ [_]json.Node{str(name)};
    return obj(&.{ m("type", str("string")), m("enum", arr(names)) });
}

/// Whether a query parameter can carry the field.
fn queryable(comptime F: type, comptime ft: protobuf.FieldType) bool {
    return switch (ft) {
        .scalar, .@"enum" => true,
        .submessage => blk: {
            const M = Unwrap(F);
            break :blk wkt(M) != null and M != protobuf.wkt.Struct and M != protobuf.wkt.Value and M != protobuf.wkt.ListValue and M != protobuf.wkt.Any and M != protobuf.wkt.Empty;
        },
        .repeated, .packed_repeated => |r| blk: {
            const Elem = @typeInfo(F.Slice).pointer.child;
            if (isMapEntry(Elem)) break :blk false;
            break :blk switch (r) {
                .scalar, .@"enum" => true,
                .submessage => wkt(Elem) != null,
            };
        },
        .oneof => false,
    };
}

// ------------------------------------------------------------------ operations

/// One operation of a service method.
pub const ServiceOp = struct {
    verb: operation.Verb,
    /// The OpenAPI path.
    path: []const u8,
    op: Operation,
    kind: Operation.Kind,
    /// Whether the method has a `google.api.http` annotation (both its
    /// forms carry the flag; the document keeps one by `Options.grpc`).
    annotated: bool,
    no_side_effects: bool,
};

fn hasNoSideEffects(comptime Svc: type, comptime method: []const u8) bool {
    if (!@hasDecl(Svc, "_method_options")) return false;
    const all = Svc._method_options;
    if (!@hasField(@TypeOf(all), method)) return false;
    const options = @field(all, method);
    if (!@hasField(@TypeOf(options), "idempotency_level")) return false;
    return std.mem.eql(u8, @tagName(options.idempotency_level), "NO_SIDE_EFFECTS");
}

fn methodDeprecated(comptime Svc: type, comptime method: []const u8) bool {
    if (!@hasDecl(Svc, "_method_options")) return false;
    const all = Svc._method_options;
    if (!@hasField(@TypeOf(all), method)) return false;
    const options = @field(all, method);
    return @hasField(@TypeOf(options), "deprecated") and options.deprecated;
}

/// The service's tag: `package.Service`.
pub fn serviceTag(comptime Svc: type) []const u8 {
    return Svc.package ++ "." ++ Svc.service_name;
}

/// The service's comment (the tag's description), if any.
pub fn serviceDoc(comptime Svc: type) ?[]const u8 {
    if (@hasDecl(Svc, "_doc")) return Svc._doc;
    return null;
}

/// The first paragraph of a comment, and the rest after a blank line.
fn splitDoc(comptime text: ?[]const u8) struct { summary: ?[]const u8, description: ?[]const u8 } {
    const t = text orelse return .{ .summary = null, .description = null };
    if (std.mem.indexOf(u8, t, "\n\n")) |i| {
        return .{ .summary = oneLine(t[0..i]), .description = t[i + 2 ..] };
    }
    return .{ .summary = oneLine(t), .description = null };
}

fn oneLine(comptime t: []const u8) []const u8 {
    var out: []const u8 = "";
    for (t) |c| out = out ++ &[_]u8{if (c == '\n') ' ' else c};
    return out;
}

fn methodDocText(comptime Svc: type, comptime method: []const u8) ?[]const u8 {
    if (!@hasDecl(Svc, "_method_docs")) return null;
    if (!@hasField(@TypeOf(Svc._method_docs), method)) return null;
    return @field(Svc._method_docs, method);
}

fn verbOf(comptime v: anytype) ?operation.Verb {
    return std.meta.stringToEnum(operation.Verb, @tagName(v));
}

/// The documented operations of the service `Svc` (comptime): per unary
/// method its Connect form (and a GET for NO_SIDE_EFFECTS) and, for each
/// `google.api.http` binding of a unary or server-streaming method, the REST
/// route. Client and bidi streams have none.
pub fn serviceOperations(comptime Svc: type) []const ServiceOp {
    comptime {
        @setEvalBranchQuota(quota);
        var out: []const ServiceOp = &.{};
        const info = @typeInfo(Svc).@"struct";
        for (info.field_names, info.field_types) |name, F| {
            const M = server.MethodOf(F);
            const texts = splitDoc(methodDocText(Svc, name));
            const annotated = transcode.annotated(Svc, name);
            const nse = hasNoSideEffects(Svc, name);
            const deprecated = methodDeprecated(Svc, name);
            const id_base = Svc.service_name ++ "_" ++ name;
            if (M.kind == .unary) {
                const connect_path = "/" ++ Svc.package ++ "." ++ Svc.service_name ++ "/" ++ name;
                const id = id_base ++ if (annotated) "_connect" else "";
                out = out ++ [_]ServiceOp{.{
                    .verb = .post,
                    .path = connect_path,
                    .kind = .connect,
                    .annotated = annotated,
                    .no_side_effects = nse,
                    .op = .{
                        .summary = texts.summary,
                        .description = texts.description,
                        .operation_id = id,
                        .deprecated = deprecated,
                        .kind = .connect,
                        .grpc_service = serviceTag(Svc),
                        .body = .{ .required = true, .content_type = "application/json", .schema = messageNode(M.Request) },
                        .responses = &.{
                            .{ .status = 200, .description = "OK", .contents = &.{.{ .content_type = "application/json", .schema = messageNode(M.Response) }} },
                            .{ .status = 0, .description = "Error", .contents = &.{.{ .content_type = "application/json", .schema = connect_error_ref }} },
                        },
                    },
                }};
                if (nse) out = out ++ [_]ServiceOp{.{
                    .verb = .get,
                    .path = connect_path,
                    .kind = .connect,
                    .annotated = annotated,
                    .no_side_effects = true,
                    .op = .{
                        .summary = texts.summary,
                        .description = texts.description,
                        .operation_id = id ++ "_get",
                        .deprecated = deprecated,
                        .kind = .connect,
                        .grpc_service = serviceTag(Svc),
                        .params = &.{
                            .{ .name = "message", .in = .query, .required = true, .schema = typeOnly("string"), .description = "The request as JSON." },
                            .{ .name = "encoding", .in = .query, .required = true, .schema = obj(&.{ m("type", str("string")), m("enum", arr(&.{str("json")})) }) },
                            .{ .name = "connect", .in = .query, .required = false, .schema = obj(&.{ m("type", str("string")), m("enum", arr(&.{str("v1")})) }) },
                        },
                        .responses = &.{
                            .{ .status = 200, .description = "OK", .contents = &.{.{ .content_type = "application/json", .schema = messageNode(M.Response) }} },
                            .{ .status = 0, .description = "Error", .contents = &.{.{ .content_type = "application/json", .schema = connect_error_ref }} },
                        },
                    },
                }};
            }
            if (annotated and (M.kind == .unary or M.kind == .server_streaming)) {
                for (transcode.rules(Svc, name), 0..) |rule, n| {
                    const verb = verbOf(rule.method) orelse continue;
                    const template = transcode.Template.parse(rule.pattern) catch continue;
                    const tp = templatePath(template);
                    out = out ++ [_]ServiceOp{.{
                        .verb = verb,
                        .path = tp.path,
                        .kind = .transcoded,
                        .annotated = true,
                        .no_side_effects = nse,
                        .op = transcodedOp(Svc, name, M, rule, tp.params, texts, deprecated, if (n == 0) id_base else id_base ++ std.fmt.comptimePrint("_{d}", .{n + 1})),
                    }};
                }
            }
        }
        return out;
    }
}

fn transcodedOp(
    comptime Svc: type,
    comptime name: []const u8,
    comptime M: type,
    comptime rule: transcode.Rule,
    comptime path_params: []const PathParam,
    comptime texts: anytype,
    comptime deprecated: bool,
    comptime id: []const u8,
) Operation {
    _ = name;
    var params: []const Operation.Param = &.{};
    // Path parameters.
    var bound: []const []const u8 = &.{};
    for (path_params) |p| {
        var schema_node: json.Node = typeOnly("string");
        var description = p.description;
        if (p.whole_field and p.field.len > 0) {
            if (fieldAt(M.Request, p.field)) |f| {
                schema_node = paramValueNode(f.F, f.ft);
                if (description == null) description = fieldDoc(f.Parent, f.name);
            }
        }
        params = params ++ [_]Operation.Param{.{
            .name = p.name,
            .in = .path,
            .required = true,
            .schema = schema_node,
            .description = description,
            .rest_of_path = p.rest_of_path,
        }};
        if (p.field.len > 0) bound = bound ++ [_][]const u8{topLevel(p.field)};
    }
    // The body.
    var body: ?Operation.Body = null;
    if (rule.body.len > 0) {
        if (std.mem.eql(u8, rule.body, "*")) {
            body = .{ .required = true, .content_type = "application/json", .schema = messageNode(M.Request) };
        } else if (fieldAt(M.Request, rule.body)) |f| {
            body = .{ .required = true, .content_type = "application/json", .schema = valueNode(f.F, f.ft) };
            bound = bound ++ [_][]const u8{f.name};
        }
    }
    // Query parameters: the request's top-level fields neither the path nor the body bind.
    if (!std.mem.eql(u8, rule.body, "*")) {
        const info = @typeInfo(M.Request).@"struct";
        for (info.field_names, info.field_types) |fname, F| {
            if (fname.len > 0 and fname[0] == '_') continue;
            if (!isProtoField(M.Request, fname)) continue;
            const ft = @field(M.Request._desc_table, fname).ftype;
            if (!queryable(F, ft)) continue;
            var is_bound = false;
            for (bound) |b| {
                if (std.mem.eql(u8, b, fname)) is_bound = true;
            }
            if (is_bound) continue;
            const beh = behaviorOf(M.Request, fname);
            const repeated = ft == .repeated or ft == .packed_repeated;
            params = params ++ [_]Operation.Param{.{
                .name = transcode.jsonName(fname),
                .in = .query,
                .required = beh.required,
                .schema = paramValueNode(F, ft),
                .description = fieldDoc(M.Request, fname),
                .deprecated = beh.deprecated,
                .explode = repeated,
            }};
        }
    }
    // The response: the message, one field of it, and an array for a stream.
    var response_node: json.Node = messageNode(M.Response);
    if (rule.response_body.len > 0) {
        if (fieldAt(M.Response, rule.response_body)) |f| response_node = valueNode(f.F, f.ft);
    }
    if (M.kind == .server_streaming) {
        response_node = obj(&.{
            m("type", str("array")),
            m("description", str("The whole stream as one JSON array.")),
            m("items", response_node),
        });
    }
    return .{
        .summary = texts.summary,
        .description = texts.description,
        .operation_id = id,
        .deprecated = deprecated,
        .kind = .transcoded,
        .grpc_service = serviceTag(Svc),
        .params = params,
        .body = body,
        .responses = &.{
            .{ .status = 200, .description = "OK", .contents = &.{.{ .content_type = "application/json", .schema = response_node }} },
            .{ .status = 0, .description = "Error", .contents = &.{.{ .content_type = "application/json", .schema = status_error_ref }} },
        },
    };
}

fn topLevel(comptime path: []const u8) []const u8 {
    const head = path[0 .. std.mem.indexOfScalar(u8, path, '.') orelse path.len];
    return head;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

const tpb = @import("anole_transcode_pb");
const wpb = tpb;
const Widgets = wpb.Widgets(server.Call, anyerror);
const Library = tpb.Library(server.Call, anyerror);

fn written(n: json.Node) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    // Names are the components' own in these tests.
    try json.write(n, &out.writer);
    return out.toOwnedSlice();
}

fn contains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("missing {s}\nin {s}\n", .{ needle, haystack });
        return error.TestExpectedContains;
    }
}

test "scalar mapping: protojson forms" {
    const text = try written(componentOf(wpb.Widget).schema);
    defer testing.allocator.free(text);
    // 64-bit integers are strings; bytes are base64.
    try contains(text, "\"big\": {\n      \"type\": \"string\",\n      \"format\": \"int64\"\n    }");
    try contains(text, "\"ubig\": {\n      \"type\": \"string\",\n      \"format\": \"uint64\"\n    }");
    try contains(text, "\"blob\": {\n      \"type\": \"string\",\n      \"format\": \"byte\"\n    }");
    try contains(text, "\"count\": {\n      \"type\": \"integer\",\n      \"format\": \"int32\"\n    }");
    try contains(text, "\"ucount\": {\n      \"type\": \"integer\",\n      \"format\": \"uint32\",\n      \"minimum\": 0\n    }");
    try contains(text, "\"ratio\": {\n      \"type\": \"number\",\n      \"format\": \"double\"\n    }");
    try contains(text, "\"on\": {\n      \"type\": \"boolean\"\n    }");
}

test "enums, repeated, maps, oneof flat, well-known types" {
    const text = try written(componentOf(wpb.Widget).schema);
    defer testing.allocator.free(text);
    try contains(text, "\"labels\": {\n      \"type\": \"array\"");
    try contains(text, "\"scores\": {\n      \"type\": \"object\",\n      \"additionalProperties\": {\n        \"type\": \"integer\",\n        \"format\": \"int32\"");
    try contains(text, "At most one of: a, b.");
    try contains(text, "\"a\": {");
    try contains(text, "\"b\": {");
    try contains(text, "\"format\": \"date-time\"");
    try contains(text, "\"pattern\": \"^-?[0-9]+(\\\\.[0-9]+)?s$\"");
    // proto3 optional: nullable.
    try contains(text, "\"maybe\": {\n      \"oneOf\"");
    // StringValue: string or null.
    try contains(text, "\"nick\": {\n      \"oneOf\"");
    const color = try written(componentOf(wpb.Color).schema);
    defer testing.allocator.free(color);
    try contains(color, "\"RED\"");
    try contains(color, "Paint colours.");
}

test "field_behavior, deprecated and comments" {
    const text = try written(componentOf(wpb.Widget).schema);
    defer testing.allocator.free(text);
    try contains(text, "\"required\": [\n    \"name\"\n  ]");
    try contains(text, "\"description\": \"The widget's resource name.\"");
    try contains(text, "\"readOnly\": true");
    try contains(text, "\"writeOnly\": true");
    try contains(text, "\"deprecated\": true");
    try contains(text, "\"description\": \"A widget.\"");
}

test "template paths" {
    const T = transcode.Template;
    const a = comptime templatePath(T.parse("/v1/{name}") catch unreachable);
    try testing.expectEqualStrings("/v1/{name}", a.path);
    try testing.expectEqual(1, a.params.len);
    const b = comptime templatePath(T.parse("/v1/shelves/{name=shelves/*/books/*}") catch unreachable);
    try testing.expectEqualStrings("/v1/shelves/shelves/{name_1}/books/{name_2}", b.path);
    try testing.expectEqual(2, b.params.len);
    try testing.expect(!b.params[0].whole_field);
    const c = comptime templatePath(T.parse("/v1/files/{path=**}") catch unreachable);
    try testing.expectEqualStrings("/v1/files/{path}", c.path);
    try testing.expect(c.params[0].rest_of_path);
    const d = comptime templatePath(T.parse("/v1/{name}:publish") catch unreachable);
    try testing.expectEqualStrings("/v1/{name}:publish", d.path);
    const e = comptime templatePath(T.parse("/v1/{a=*}/x") catch unreachable);
    try testing.expectEqualStrings("/v1/{a}/x", e.path);
}

fn findOp(comptime ops: []const ServiceOp, comptime id: []const u8) ?ServiceOp {
    inline for (ops) |o| {
        if (std.mem.eql(u8, o.op.operation_id.?, id)) return o;
    }
    return null;
}

test "Connect and transcoded forms per method" {
    const ops = comptime serviceOperations(Widgets);
    // Unannotated unary: Connect POST only. NO_SIDE_EFFECTS: POST and GET.
    const make = comptime findOp(ops, "Widgets_Make").?;
    try testing.expectEqual(operation.Verb.post, make.verb);
    try testing.expectEqualStrings("/transcode.Widgets/Make", make.path);
    try testing.expect(!make.annotated);
    const peek = comptime findOp(ops, "Widgets_Peek").?;
    try testing.expect(peek.no_side_effects);
    const peek_get = comptime findOp(ops, "Widgets_Peek_get").?;
    try testing.expectEqual(operation.Verb.get, peek_get.verb);
    try testing.expectEqual(3, peek_get.op.params.len);
    // Annotated unary: transcoded GET, and a Connect form flagged annotated.
    const get = comptime findOp(ops, "Widgets_GetWidget").?;
    try testing.expectEqual(Operation.Kind.transcoded, get.kind);
    try testing.expectEqualStrings("/v1/widgets/{name_1}", get.path);
    try testing.expectEqualStrings("Gets a widget.", get.op.summary.?);
    try testing.expectEqualStrings("It must exist.", get.op.description.?);
    const get_connect = comptime findOp(ops, "Widgets_GetWidget_connect").?;
    try testing.expect(get_connect.annotated);
    try testing.expectEqual(Operation.Kind.connect, get_connect.kind);
    // The query parameters of a list: the fields the path leaves.
    const list = comptime findOp(ops, "Widgets_ListWidgets").?;
    try testing.expectEqual(2, list.op.params.len);
    try testing.expectEqualStrings("pageSize", list.op.params[0].name);
    try testing.expect(list.op.params[1].explode);
    // Server stream: transcoded only, an array; client stream: none.
    const watch = comptime findOp(ops, "Widgets_Watch").?;
    try testing.expectEqual(Operation.Kind.transcoded, watch.kind);
    try testing.expect(comptime findOp(ops, "Widgets_Upload") == null);
    try testing.expect(comptime findOp(ops, "Widgets_Watch_connect") == null);
    // The service tag and comment.
    try testing.expectEqualStrings("transcode.Widgets", comptime serviceTag(Widgets));
    try testing.expectEqualStrings("Widgets of the shop.", comptime serviceDoc(Widgets).?);
}

test "the Library test service: bindings, bodies and verbs" {
    const ops = comptime serviceOperations(Library);
    const create = comptime findOp(ops, "Library_CreateBook").?;
    try testing.expectEqual(operation.Verb.post, create.verb);
    try testing.expect(create.op.body != null);
    // body "book": the rest of the request is query.
    const update = comptime findOp(ops, "Library_UpdateBook").?;
    try testing.expectEqual(operation.Verb.patch, update.verb);
    try testing.expectEqualStrings("/v1/shelves/{book.name_1}/books/{book.name_2}", update.path);
}

test {
    std.testing.refAllDecls(@This());
}
