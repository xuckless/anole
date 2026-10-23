// Adapted from vkiryakov/zefir src/openapi/schema.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.

//! The JSON Schema of the values of a Zig type, as `std.json` reads and writes
//! them (what `req.bind` and `res.json` use). One schema per type: a field
//! with a default or a `?T` field is not required, a union is an object of one
//! key, and a type with a `jsonStringify` says what it writes with
//! `Doc(T).as`.
//!
//! Every named struct, enum and union is a `Component`, a comptime value whose
//! address identifies the type. Other schemas refer to it with a `.ref` node;
//! the document assembler resolves the names when it writes. Anonymous types
//! stand inline.
//!
//! The validator's `field_rules` are merged into each field's schema
//! (`withRules`, over `validate.schemaOf`): `maxLength`, `minimum`, `pattern`
//! and the like come from the rules, and a field's outside name from
//! `v.rename`.
const std = @import("std");
const json = @import("json.zig");
const example = @import("example.zig");
const declarations = @import("declarations.zig");
const v = @import("validate");

pub const Component = json.Component;

/// The single component of the named type `T`.
pub fn componentOf(comptime T: type) *const Component {
    return &Holder(T).value;
}

fn Holder(comptime T: type) type {
    return struct {
        pub const value: Component = .{
            .name = checkedName(T),
            .type_name = @typeName(T),
            .schema = blk: {
                @setEvalBranchQuota(quota);
                break :blk node(bodyParts(T, false, typeName(T), &.{}, true));
            },
            .deps = blk: {
                @setEvalBranchQuota(quota);
                break :blk bodyDeps(T, &.{});
            },
        };
        fn get() *const Component {
            return &value;
        }
    };
}

/// The function a `.ref` node holds for the named type `T`.
pub fn refFn(comptime T: type) json.RefFn {
    return &Holder(T).get;
}

/// The schema of a value of `T` as a use: a `.ref` to the component of a named
/// struct, enum or union, else the schema itself.
pub fn schemaOf(comptime T: type) json.Node {
    comptime {
        @setEvalBranchQuota(quota);
        return node(typeParts(T, false, typeName(T), &.{}, true));
    }
}

/// The schema of a value of `T` with nothing by reference: every struct,
/// enum and union stands inline. For parameters (a query enum lists its
/// values in the parameter).
pub fn inlineSchemaOf(comptime T: type) json.Node {
    comptime {
        @setEvalBranchQuota(quota);
        return node(typeParts(T, false, typeName(T), &.{}, false));
    }
}

/// The components a use of `T` refers to directly.
pub fn depsOf(comptime T: type) []const json.RefFn {
    comptime {
        @setEvalBranchQuota(quota);
        return useDeps(T, &.{});
    }
}

// ------------------------------------------------------------------ dependencies

fn useDeps(comptime T: type, comptime stack: []const type) []const json.RefFn {
    if (T == std.json.Value) return &.{};
    switch (@typeInfo(T)) {
        .optional => |o| return useDeps(o.child, stack),
        .pointer => |p| return if (isString(T)) &.{} else useDeps(p.child, stack),
        .array => |a| return if (a.child == u8) &.{} else useDeps(a.child, stack),
        .@"struct" => |s| {
            if (mapValue(T)) |V| return useDeps(V, stack);
            if (s.is_tuple) {
                var out: []const json.RefFn = &.{};
                for (s.field_types) |F| out = out ++ useDeps(F, stack);
                return out;
            }
            if (isNamed(T)) return &.{refFn(T)};
            return bodyDeps(T, stack);
        },
        .@"union" => |u| if (u.tag_type != null) {
            if (isNamed(T)) return &.{refFn(T)};
            return bodyDeps(T, stack);
        },
        .@"enum" => {
            if (isNamed(T)) return &.{refFn(T)};
            return bodyDeps(T, stack);
        },
        else => {},
    }
    return &.{};
}

fn bodyDeps(comptime T: type, comptime stack: []const type) []const json.RefFn {
    for (stack) |S| if (S == T) return &.{};
    const inner = stack ++ [_]type{T};
    if (declarations.writesItself(T)) return useDeps(asOf(T), inner);
    var out: []const json.RefFn = &.{};
    switch (@typeInfo(T)) {
        .@"struct" => |s| for (s.field_types, s.field_attrs) |F, attrs| {
            if (F == void or attrs.@"comptime") continue;
            out = out ++ useDeps(F, inner);
        },
        .@"union" => |u| for (u.field_types) |F| {
            if (F != void) out = out ++ useDeps(F, inner);
        },
        else => {},
    }
    return out;
}

// ------------------------------------------------------------------ parts

/// A schema in the making, its members by what they say; `node` puts them in
/// their order.
const Parts = struct {
    /// What the value is: `type` and `format`, or `oneOf` / `anyOf` of what it may be.
    kind: []const json.Member = &.{},
    /// A reference to a component (instead of `kind`).
    ref: ?json.RefFn = null,
    /// Sentences of the description, joined by spaces.
    description: []const []const u8 = &.{},
    deprecated: bool = false,
    /// The keywords of the type (`enum`, `const`, bounds).
    keywords: []const json.Member = &.{},
    default: ?json.Node = null,
    /// The schema of the items of a list.
    items: ?*const Parts = null,
    required: []const []const u8 = &.{},
    /// The properties of an object.
    properties: ?[]const json.Member = null,
    examples: []const json.Node = &.{},
};

/// The schema of `p`: `kind`, `description`, `deprecated`, the keywords,
/// `default`, `items`, `required`, `properties` and `examples`, in this order.
fn node(comptime p: Parts) json.Node {
    if (p.ref) |r| {
        const plain = p.description.len == 0 and !p.deprecated and p.default == null and p.examples.len == 0;
        if (plain) return .{ .ref = r };
        var m: []const json.Member = &.{};
        if (p.description.len > 0) m = m ++ [_]json.Member{.{ .key = "description", .value = .{ .string = joined(p.description) } }};
        if (p.deprecated) m = m ++ [_]json.Member{.{ .key = "deprecated", .value = .{ .boolean = true } }};
        m = m ++ [_]json.Member{.{ .key = "allOf", .value = .{ .array = &.{.{ .ref = r }} } }};
        if (p.default) |d| m = m ++ [_]json.Member{.{ .key = "default", .value = d }};
        if (p.examples.len > 0) m = m ++ [_]json.Member{.{ .key = "examples", .value = .{ .array = p.examples } }};
        return .{ .object = m };
    }
    var m: []const json.Member = p.kind;
    if (p.description.len > 0) m = m ++ [_]json.Member{.{ .key = "description", .value = .{ .string = joined(p.description) } }};
    if (p.deprecated) m = m ++ [_]json.Member{.{ .key = "deprecated", .value = .{ .boolean = true } }};
    m = m ++ p.keywords;
    if (p.default) |default| m = m ++ [_]json.Member{.{ .key = "default", .value = default }};
    if (p.items) |items| m = m ++ [_]json.Member{.{ .key = "items", .value = node(items.*) }};
    if (p.required.len > 0) {
        var names: [p.required.len]json.Node = undefined;
        for (p.required, &names) |name, *n| n.* = .{ .string = name };
        const final = names;
        m = m ++ [_]json.Member{.{ .key = "required", .value = .{ .array = &final } }};
    }
    if (p.properties) |properties| m = m ++ [_]json.Member{.{ .key = "properties", .value = .{ .object = properties } }};
    if (p.examples.len > 0) m = m ++ [_]json.Member{.{ .key = "examples", .value = .{ .array = p.examples } }};
    return .{ .object = m };
}

fn joined(comptime sentences: []const []const u8) []const u8 {
    var out: []const u8 = sentences[0];
    for (sentences[1..]) |s| out = out ++ " " ++ s;
    return out;
}

const null_schema = json.object(&.{.{ .key = "type", .value = .{ .string = "null" } }});

/// `type`, with `null` too when `nullable`.
fn typeKind(comptime name: []const u8, comptime nullable: bool) []const json.Member {
    const value: json.Node = if (nullable) .{ .array = &.{ .{ .string = name }, .{ .string = "null" } } } else .{ .string = name };
    return &.{.{ .key = "type", .value = value }};
}

fn formatOf(comptime format: ?[]const u8) []const json.Member {
    const name = format orelse return &.{};
    return &.{.{ .key = "format", .value = .{ .string = name } }};
}

/// A keyword with a number.
fn count(comptime key: []const u8, comptime n: comptime_int) json.Member {
    return .{ .key = key, .value = .{ .raw = std.fmt.comptimePrint("{d}", .{n}) } };
}

/// A reference to `T`'s component; with `nullable`, `oneOf` it and `null`.
fn refParts(comptime T: type, comptime nullable: bool) Parts {
    if (!nullable) return .{ .ref = refFn(T) };
    return .{ .kind = &.{.{ .key = "oneOf", .value = .{ .array = &.{ .{ .ref = refFn(T) }, null_schema } } }} };
}

/// An integer: its `format` from the registry of OpenAPI, and its bounds up to
/// 32 bits; a wider one has only `minimum: 0` when unsigned, since tools in
/// JavaScript read numbers beyond 2^53 inexactly. `usize` and `isize` have no
/// format: their size is the target's.
fn intParts(comptime T: type, comptime i: std.lang.Type.Int, comptime nullable: bool) Parts {
    const sized = T != usize and T != isize;
    const prefix = if (i.signedness == .signed) "int" else "uint";
    const format: ?[]const u8 = switch (i.bits) {
        8, 16, 32, 64 => if (sized) std.fmt.comptimePrint("{s}{d}", .{ prefix, i.bits }) else null,
        else => null,
    };
    const keywords: []const json.Member = if (sized and i.bits <= 32)
        &.{ count("minimum", std.math.minInt(T)), count("maximum", std.math.maxInt(T)) }
    else if (i.signedness == .unsigned)
        &.{count("minimum", 0)}
    else
        &.{};
    return .{ .kind = typeKind("integer", nullable) ++ formatOf(format), .keywords = keywords };
}

/// The schema of a value of `T`; `nullable` adds `null`. `refs`: a named
/// struct, enum or union is a `.ref` (else inline). `where` names the value in
/// a message.
fn typeParts(comptime T: type, comptime nullable: bool, comptime where: []const u8, comptime stack: []const type, comptime refs: bool) Parts {
    // Any JSON, null too.
    if (T == std.json.Value) return .{};
    switch (@typeInfo(T)) {
        .optional => |o| return typeParts(o.child, true, where, stack, refs),
        .bool => return .{ .kind = typeKind("boolean", nullable) },
        .int => |i| return intParts(T, i, nullable),
        .comptime_int => return .{ .kind = typeKind("integer", nullable) },
        .float => |f| if (f.bits <= 64) return .{ .kind = typeKind("number", nullable) ++ formatOf(switch (f.bits) {
            32 => "float",
            64 => "double",
            else => null,
        }) },
        .pointer => |p| switch (p.size) {
            .one => return typeParts(p.child, nullable, where, stack, refs),
            .slice, .many => if (isString(T)) {
                return .{ .kind = typeKind("string", nullable) };
            } else if (p.size == .slice) {
                const item = typeParts(p.child, false, where ++ "[]", stack, refs);
                return .{ .kind = typeKind("array", nullable), .items = &item };
            },
            .c => {},
        },
        .array => |a| {
            if (a.child == u8) return .{ .kind = typeKind("string", nullable), .keywords = &.{count("maxLength", a.len)} };
            const item = typeParts(a.child, false, where ++ "[]", stack, refs);
            return .{ .kind = typeKind("array", nullable), .keywords = &.{ count("minItems", a.len), count("maxItems", a.len) }, .items = &item };
        },
        .@"struct" => |s| {
            if (mapValue(T)) |V| {
                const values = typeParts(V, false, where ++ "[]", stack, refs);
                return .{ .kind = typeKind("object", nullable), .keywords = &.{.{ .key = "additionalProperties", .value = node(values) }} };
            }
            // An empty tuple is an empty array: prefixItems takes one schema at least.
            if (s.is_tuple and s.field_types.len == 0) return .{ .kind = typeKind("array", nullable), .keywords = &.{count("maxItems", 0)} };
            if (s.is_tuple) {
                var prefix: [s.field_types.len]json.Node = undefined;
                for (s.field_types, &prefix, 0..) |F, *item, i| item.* = node(typeParts(F, false, std.fmt.comptimePrint("{s}[{d}]", .{ where, i }), stack, refs));
                const final = prefix;
                return .{ .kind = typeKind("array", nullable), .keywords = &.{
                    .{ .key = "prefixItems", .value = .{ .array = &final } },
                    count("minItems", final.len),
                    count("maxItems", final.len),
                } };
            }
            return namedParts(T, nullable, where, stack, refs);
        },
        .@"union" => |u| if (u.tag_type != null) return namedParts(T, nullable, where, stack, refs),
        .@"enum" => return namedParts(T, nullable, where, stack, refs),
        else => {},
    }
    @compileError("anole.openapi: " ++ where ++ ": " ++ @typeName(T) ++ " has no JSON Schema: a value of the document is a bool, an integer, " ++
        "a float of up to 64 bits, an enum, a string, a struct, a union(enum), a slice, an array, a tuple or ?T of them");
}

/// A reference to the component of the named type `T`, or its schema inline
/// for an anonymous one (or when `refs` is off).
fn namedParts(comptime T: type, comptime nullable: bool, comptime where: []const u8, comptime stack: []const type, comptime refs: bool) Parts {
    if (refs and isNamed(T)) return refParts(T, nullable);
    for (stack) |S| {
        if (S == T) @compileError("anole.openapi: " ++ where ++ ": the anonymous type " ++ @typeName(T) ++ " holds itself, which an inline schema cannot; give it a name, such as const Node = struct { ... }");
    }
    return bodyParts(T, nullable, where, stack, refs);
}

/// The schema of a struct, an enum or a union `T` itself.
fn bodyParts(comptime T: type, comptime nullable: bool, comptime where: []const u8, comptime stack: []const type, comptime refs: bool) Parts {
    if (declarations.writesItself(T)) {
        var p = typeParts(asOf(T), nullable, where, stack ++ [_]type{T}, refs);
        p.description = typeTexts(T);
        p.deprecated = typeDeprecated(T);
        return p;
    }
    return switch (@typeInfo(T)) {
        .@"struct" => structParts(T, nullable, stack, refs),
        .@"enum" => enumParts(T, nullable),
        .@"union" => unionParts(T, nullable, stack, refs),
        else => unreachable,
    };
}

fn structParts(comptime T: type, comptime nullable: bool, comptime stack: []const type, comptime refs: bool) Parts {
    const s = @typeInfo(T).@"struct";
    const inner = stack ++ [_]type{T};
    var properties: []const json.Member = &.{};
    var required: []const []const u8 = &.{};
    for (s.field_names, s.field_types, s.field_attrs) |name, F, attrs| {
        if (F == void or attrs.@"comptime") continue;
        const key = example.outsideName(T, name);
        properties = properties ++ [_]json.Member{.{ .key = key, .value = node(fieldParts(T, name, F, attrs, inner, refs)) }};
        if (@typeInfo(F) != .optional and attrs.default_value_ptr == null) required = required ++ [_][]const u8{key};
    }
    return .{
        .kind = typeKind("object", nullable),
        .description = typeTexts(T),
        .deprecated = typeDeprecated(T),
        .required = required,
        .properties = properties,
        .examples = typeExamples(T),
    };
}

/// The schema of the field `name` of `T`, of type `F`.
fn fieldParts(comptime T: type, comptime name: []const u8, comptime F: type, comptime attrs: std.lang.Type.Struct.FieldAttributes, comptime stack: []const type, comptime refs: bool) Parts {
    const where = typeName(T) ++ "." ++ name;
    var p = typeParts(F, false, where, stack, refs);
    const doc = fieldDocOf(T, name);
    if (doc.description) |text| p.description = &.{text};
    p = withRules(p, rulesOf(T, name));
    p.deprecated = doc.deprecated;
    if (!declarations.writesItself(F)) {
        if (attrs.defaultValue(F)) |default| p.default = example.value(F, default, .input, where);
    }
    const examples = fieldExamples(T, name);
    p.examples = (if (examples.example) |one| &[_]json.Node{one} else &[_]json.Node{}) ++ examples.examples;
    return p;
}

fn enumParts(comptime T: type, comptime nullable: bool) Parts {
    const e = @typeInfo(T).@"enum";
    var names: []const json.Node = &.{};
    for (e.field_names) |name| names = names ++ [_]json.Node{.{ .string = name }};
    if (nullable) names = names ++ [_]json.Node{.null};
    return .{
        .kind = typeKind("string", nullable),
        .description = typeTexts(T),
        .deprecated = typeDeprecated(T),
        .keywords = &.{.{ .key = "enum", .value = .{ .array = names } }},
        .examples = typeExamples(T),
    };
}

/// A union: an object of one key, its active variant.
fn unionParts(comptime T: type, comptime nullable: bool, comptime stack: []const type, comptime refs: bool) Parts {
    const u = @typeInfo(T).@"union";
    const inner = stack ++ [_]type{T};
    var variants: []const json.Node = &.{};
    for (u.field_names, u.field_types) |name, P| {
        var payload: Parts = if (P == void)
            .{ .kind = typeKind("object", false), .keywords = &.{count("maxProperties", 0)} }
        else
            typeParts(P, false, typeName(T) ++ "." ++ name, inner, refs);
        const doc = fieldDocOf(T, name);
        if (doc.description) |text| payload.description = &.{text};
        payload.deprecated = doc.deprecated;
        variants = variants ++ [_]json.Node{node(.{
            .kind = typeKind("object", false),
            .required = &.{name},
            .properties = &.{.{ .key = name, .value = node(payload) }},
        })};
    }
    if (nullable) variants = variants ++ [_]json.Node{null_schema};
    return .{
        .kind = &.{.{ .key = "oneOf", .value = .{ .array = variants } }},
        .description = typeTexts(T),
        .deprecated = typeDeprecated(T),
        .examples = typeExamples(T),
    };
}

// ------------------------------------------------------------------ parameters

/// What a parameter of a path, query or header DTO needs in the document.
pub const ParamInfo = struct {
    schema: json.Node,
    description: ?[]const u8,
    deprecated: bool,
    /// A `[]const T` query field (repeated keys).
    is_list: bool,
    required: bool,
};

fn fieldAttrs(comptime T: type, comptime name: []const u8) std.lang.Type.Struct.FieldAttributes {
    const s = @typeInfo(T).@"struct";
    for (s.field_names, s.field_attrs) |n, a| {
        if (std.mem.eql(u8, n, name)) return a;
    }
    unreachable;
}

/// The parameter of the field `field` of the DTO `Dto`: its schema with the
/// rules of the field merged in, its default, its text.
pub fn paramOf(comptime Dto: type, comptime field: []const u8) ParamInfo {
    comptime {
        @setEvalBranchQuota(quota);
        const F = @FieldType(Dto, field);
        const where = typeName(Dto) ++ "." ++ field;
        const Value = if (@typeInfo(F) == .optional) @typeInfo(F).optional.child else F;
        const Item = @import("dusty").input.strings.listItem(Value) orelse Value;
        var p = typeParts(Value, false, where, &.{}, false);
        p = withRules(p, rulesAs(Dto, field, Value));
        const attrs = fieldAttrs(Dto, field);
        if (attrs.defaultValue(F)) |default| {
            if (@typeInfo(F) != .optional or default != null) p.default = example.value(F, default, .input, where);
        }
        const doc = fieldDocOf(Dto, field);
        var description: []const []const u8 = if (doc.description) |text| &.{text} else &.{};
        description = description ++ p.description;
        p.description = &.{};
        return .{
            .schema = node(p),
            .description = if (description.len > 0) joined(description) else null,
            .deprecated = doc.deprecated,
            .is_list = Item != Value,
            .required = @typeInfo(F) != .optional and attrs.default_value_ptr == null,
        };
    }
}

// ------------------------------------------------------------------ rules

const rename_example = v.rename("x");
const Rename = @TypeOf(rename_example);
const Transform = @TypeOf(v.trim);

/// The schemas of the rules and transforms of the field `name` of `T`, in
/// the order of its entry in `field_rules`.
fn rulesOf(comptime T: type, comptime name: []const u8) []const v.RuleSchema {
    return rulesAs(T, name, @FieldType(T, name));
}

fn rulesAs(comptime T: type, comptime name: []const u8, comptime F: type) []const v.RuleSchema {
    if (@typeInfo(T) != .@"struct" or !@hasDecl(T, "field_rules")) return &.{};
    if (!@hasField(@TypeOf(T.field_rules), name)) return &.{};
    const entry = @field(T.field_rules, name);
    const E = @TypeOf(entry);
    if (E == v.Rule or E == Transform) return &.{v.schemaOf(entry, F)};
    if (E == Rename) return &.{};
    var out: []const v.RuleSchema = &.{};
    for (0..entry.len) |i| {
        const Element = @TypeOf(entry[i]);
        if (Element == v.Rule or Element == Transform) out = out ++ [_]v.RuleSchema{v.schemaOf(entry[i], F)};
    }
    return out;
}

/// `p` with the keywords of `schemas` merged in and their notes after its
/// description; `each`'s item rules apply to the items.
fn withRules(comptime p: Parts, comptime schemas: []const v.RuleSchema) Parts {
    var out = p;
    var fragments: []const []const json.Member = &.{};
    var notes: []const []const u8 = &.{};
    for (schemas) |rs| {
        if (rs.note) |note| notes = notes ++ [_][]const u8{note};
        if (rs.keywords.len > 0) {
            var members: [rs.keywords.len]json.Member = undefined;
            for (rs.keywords, &members) |k, *m| m.* = .{ .key = k.name, .value = .{ .raw = k.value } };
            const final = members;
            fragments = fragments ++ [_][]const json.Member{&final};
        }
        if (rs.items.len > 0 and out.items != null) {
            const items = withRules(out.items.?.*, rs.items);
            out.items = &items;
        }
    }
    out.keywords = merged(out, fragments);
    out.description = out.description ++ notes;
    return out;
}

fn merged(comptime p: Parts, comptime fragments: []const []const json.Member) []const json.Member {
    if (fragments.len == 0) return p.keywords;
    const taken = takenKeys(p);
    var keywords = p.keywords;
    var names: []const []const u8 = &.{};
    for (fragments) |fragment| {
        for (fragment) |k| {
            if (contains(names, k.key) or contains(taken, k.key)) return withAllOf(p.keywords, fragments);
            names = names ++ [_][]const u8{k.key};
            for (keywords, 0..) |own, i| {
                if (!std.mem.eql(u8, own.key, k.key)) continue;
                const kept = tighter(own, k) orelse return withAllOf(p.keywords, fragments);
                keywords = keywords[0..i] ++ [_]json.Member{kept} ++ keywords[i + 1 ..];
                break;
            } else keywords = keywords ++ [_]json.Member{k};
        }
    }
    return keywords;
}

fn withAllOf(comptime keywords: []const json.Member, comptime fragments: []const []const json.Member) []const json.Member {
    var all: []const json.Node = &.{};
    for (fragments) |fragment| all = all ++ [_]json.Node{.{ .object = fragment }};
    return keywords ++ [_]json.Member{.{ .key = "allOf", .value = .{ .array = all } }};
}

fn takenKeys(comptime p: Parts) []const []const u8 {
    var out: []const []const u8 = &.{ "description", "deprecated", "default", "examples" };
    for (p.kind) |m| out = out ++ [_][]const u8{m.key};
    if (p.items != null) out = out ++ [_][]const u8{"items"};
    if (p.properties != null) out = out ++ [_][]const u8{ "required", "properties", "additionalProperties" };
    return out;
}

fn tighter(comptime own: json.Member, comptime rule: json.Member) ?json.Member {
    const key = own.key;
    if (std.mem.eql(u8, key, "enum")) return rule;
    if (own.value != .raw or rule.value != .raw) return null;
    const lower = contains(&.{ "minimum", "exclusiveMinimum", "minLength", "minItems" }, key);
    const upper = contains(&.{ "maximum", "exclusiveMaximum", "maxLength", "maxItems" }, key);
    if (!lower and !upper) return null;
    const rule_less = lessNumber(rule.value.raw, own.value.raw) orelse return null;
    return if (rule_less == upper) rule else own;
}

fn lessNumber(comptime a: []const u8, comptime b: []const u8) ?bool {
    if (integerOf(a)) |x| if (integerOf(b)) |y| return x < y;
    const x = std.fmt.parseFloat(f128, a) catch return null;
    const y = std.fmt.parseFloat(f128, b) catch return null;
    return x < y;
}

fn integerOf(comptime text: []const u8) ?comptime_int {
    const negative = text.len > 0 and text[0] == '-';
    const digits = if (negative) text[1..] else text;
    if (digits.len == 0) return null;
    var n: comptime_int = 0;
    for (digits) |c| {
        if (!std.ascii.isDigit(c)) return null;
        n = n * 10 + @as(comptime_int, c - '0');
    }
    return if (negative) -n else n;
}

fn contains(comptime list: []const []const u8, comptime key: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, key)) return true;
    }
    return false;
}

// ------------------------------------------------------------------ examples

/// The `examples` of the schema of `T`: its `Doc(T).example`.
fn typeExamples(comptime T: type) []const json.Node {
    if (!hasDoc(T)) return &.{};
    const doc = docOf(T);
    if (!@hasField(@TypeOf(doc), "example")) return &.{};
    const x = doc.example orelse return &.{};
    return &.{example.value(T, x, .output, typeName(T) ++ ".openapi.example")};
}

const FieldExamples = struct { example: ?json.Node = null, examples: []const json.Node = &.{} };

/// The examples of the field `name` of `T`.
fn fieldExamples(comptime T: type, comptime name: []const u8) FieldExamples {
    const F = @FieldType(T, name);
    const doc = fieldDocOf(T, name);
    if (!@hasField(@TypeOf(doc), "example")) return .{};
    const where = typeName(T) ++ ".openapi.fields." ++ name;
    var out: FieldExamples = .{};
    if (doc.example) |x| out.example = example.value(F, x, .output, where ++ ".example");
    for (doc.examples, 0..) |x, i| {
        out.examples = out.examples ++ [_]json.Node{example.value(F, x, .output, std.fmt.comptimePrint("{s}.examples[{d}]", .{ where, i }))};
    }
    return out;
}

// ------------------------------------------------------------------ helpers

/// The type of the values of `std.json.ArrayHashMap(V)`, `V`, or null for
/// another type.
fn mapValue(comptime T: type) ?type {
    if (!@hasField(T, "map")) return null;
    const M = @FieldType(T, "map");
    if (@typeInfo(M) != .@"struct" or !@hasDecl(M, "KV") or @TypeOf(M.KV) != type) return null;
    if (@typeInfo(M.KV) != .@"struct" or !@hasField(M.KV, "value")) return null;
    const V = @FieldType(M.KV, "value");
    return if (T == std.json.ArrayHashMap(V)) V else null;
}

/// A string: bytes, of a slice or of a many-item pointer with a sentinel.
fn isString(comptime T: type) bool {
    const p = switch (@typeInfo(T)) {
        .pointer => |p| p,
        else => return false,
    };
    return p.child == u8 and (p.size == .slice or (p.size == .many and p.sentinel() != null));
}

/// The `openapi` of `T`, which declares one: `hasDoc(T)`. One of another type
/// stops the build.
pub fn docOf(comptime T: type) declarations.Doc(T) {
    if (@TypeOf(T.openapi) != declarations.Doc(T))
        @compileError("anole.openapi: " ++ typeName(T) ++ ".openapi must be of type anole.openapi.Doc(" ++ typeName(T) ++ ")");
    return T.openapi;
}

/// Whether `T`, a struct, an enum or a union, declares its `openapi`.
pub fn hasDoc(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union" => @hasDecl(T, "openapi"),
        else => false,
    };
}

/// The texts of the field `name` of `T`, `.{}` when it has none.
fn fieldDocOf(comptime T: type, comptime name: []const u8) declarations.FieldDoc(@FieldType(T, name)) {
    if (!hasDoc(T)) return .{};
    const doc = docOf(T);
    if (!@hasField(@TypeOf(doc), "fields")) return .{};
    return @field(doc.fields, name);
}

/// The sentences of the description of `T` itself.
fn typeTexts(comptime T: type) []const []const u8 {
    if (!hasDoc(T)) return &.{};
    return if (docOf(T).description) |text| &.{text} else &.{};
}

fn typeDeprecated(comptime T: type) bool {
    return hasDoc(T) and docOf(T).deprecated;
}

/// The type whose JSON a type that writes itself writes: its `Doc(T).as`.
fn asOf(comptime T: type) type {
    if (!hasDoc(T)) @compileError("anole.openapi: " ++ typeName(T) ++ " writes itself with jsonStringify, so the document does not know its JSON; " ++
        "say what it looks like: pub const openapi: anole.openapi.Doc(" ++ typeName(T) ++ ") = .{ .as = []const u8 }");
    return docOf(T).as;
}

/// A type with a schema of its own in `components`: a struct, an enum or a
/// union with a name, or with a `.name` in its `Doc`. An anonymous type, named
/// by the compiler with a number that changes as the program does, stands
/// inline, and so does a generic of one.
pub fn isNamed(comptime T: type) bool {
    if (hasDoc(T) and !declarations.writesItself(T) and docOf(T).name != null) return true;
    if (hasDoc(T) and declarations.writesItself(T) and docOf(T).name != null) return true;
    return !isAnonymous(T);
}

/// The compiler names an anonymous type after its place and a number,
/// `dto.Order__struct_931`, and a generic of one by it too.
fn isAnonymous(comptime T: type) bool {
    return hasCompilerNumber(schemaName(@typeName(T)));
}

/// Whether `name` holds the number of an anonymous type anywhere:
/// `__struct_`, `__union_`, `__enum_` or `__opaque_`, then a digit.
pub fn hasCompilerNumber(comptime name: []const u8) bool {
    var rest = name;
    while (std.mem.find(u8, rest, "__")) |at| {
        rest = rest[at + 2 ..];
        for ([_][]const u8{ "struct_", "union_", "enum_", "opaque_" }) |kind| {
            if (std.mem.startsWith(u8, rest, kind) and rest.len > kind.len and std.ascii.isDigit(rest[kind.len])) return true;
        }
    }
    return false;
}

/// The name of the schema of `T`: its `Doc(T).name`, else the one of
/// `schemaName`; a name that is not one stops the build.
fn checkedName(comptime T: type) []const u8 {
    const rule = "1 or more of A-Z, a-z, 0-9, '.', '-' and '_'";
    if (hasDoc(T)) if (docOf(T).name) |name| {
        if (!isSchemaName(name)) @compileError("anole.openapi: " ++ typeName(T) ++ ".openapi.name \"" ++ name ++ "\" is not a schema name: " ++ rule);
        return name;
    };
    const name = schemaName(@typeName(T));
    if (!isSchemaName(name)) @compileError("anole.openapi: the schema of " ++ @typeName(T) ++ " would be named " ++ name ++ ", which is not a schema name (" ++ rule ++
        "); give it one: pub const openapi: anole.openapi.Doc(@This()) = .{ .name = \"...\" }");
    return name;
}

/// A name the document can give a schema: `^[a-zA-Z0-9.\-_]+$`.
pub fn isSchemaName(comptime name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != '_') return false;
    }
    return true;
}

/// The name of a schema from the name of its type, `@typeName`: its last part,
/// a generic's arguments after it, each by its own last part:
/// "dto.TodoResponse" is "TodoResponse", "dto.Page(dto.TodoResponse)" is
/// "Page_TodoResponse", "dto.Pair(dto.Todo,u8)" is "Pair_Todo_u8", and an
/// argument "[]const dto.Todo" or "?dto.Todo" is "Todo".
pub fn schemaName(comptime full: []const u8) []const u8 {
    const name = bare(lastWord(full));
    const open = std.mem.findScalar(u8, name, '(') orelse return name;
    if (name[name.len - 1] != ')') return name;
    var out: []const u8 = name[0..open];
    var depth: usize = 0;
    var start = open + 1;
    for (name[open + 1 .. name.len - 1], open + 1..) |c, i| switch (c) {
        '(' => depth += 1,
        ')' => depth -= 1,
        ',' => if (depth == 0) {
            out = out ++ "_" ++ schemaName(name[start..i]);
            start = i + 1;
        },
        else => {},
    };
    if (start < name.len - 1) out = out ++ "_" ++ schemaName(name[start .. name.len - 1]);
    return out;
}

/// The last word of a type's name outside parentheses, after its last '.' or
/// ' ': "[]const dto.Todo" is "Todo", "dto.Page(dto.Todo)" is "Page(dto.Todo)".
fn lastWord(comptime full: []const u8) []const u8 {
    var depth: usize = 0;
    var start: usize = 0;
    for (full, 0..) |c, i| switch (c) {
        '(' => depth += 1,
        ')' => depth -= 1,
        '.', ' ' => if (depth == 0) {
            start = i + 1;
        },
        else => {},
    };
    return full[start..];
}

/// A name without the `?`, `*` and `[N]` in front of it.
fn bare(comptime name: []const u8) []const u8 {
    var rest = name;
    while (rest.len > 0) {
        switch (rest[0]) {
            '?', '*' => rest = rest[1..],
            '[' => rest = rest[(std.mem.findScalar(u8, rest, ']') orelse return rest) + 1 ..],
            else => return rest,
        }
    }
    return rest;
}

/// How messages name `T`: the last part of its name.
pub fn typeName(comptime T: type) []const u8 {
    return shortName(@typeName(T));
}

/// The last part of a type's name, outside parentheses.
fn shortName(comptime full: []const u8) []const u8 {
    var depth: usize = 0;
    var start: usize = 0;
    for (full, 0..) |c, i| switch (c) {
        '(' => depth += 1,
        ')' => depth -= 1,
        '.' => if (depth == 0) {
            start = i + 1;
        },
        else => {},
    };
    return full[start..];
}

/// The eval branch quota of a schema build.
const quota = 10_000_000;

// ------------------------------------------------------------------ tests

const testing = std.testing;

/// Writes `n` with `c` and the names the table gives.
fn written(n: json.Node, comptime named: []const type) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    var comps: [named.len]*const Component = undefined;
    var names: [named.len][]const u8 = undefined;
    inline for (named, 0..) |T, i| {
        comps[i] = componentOf(T);
        names[i] = componentOf(T).name;
    }
    try json.writeNamed(n, &out.writer, .{ .components = &comps, .names = &names });
    return out.toOwnedSlice();
}

fn expectSchema(comptime T: type, expected: []const u8) !void {
    const text = try written(comptime schemaOf(T), &.{});
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(expected, text);
}

fn compactOf(comptime T: type) ![]u8 {
    const text = try written(comptime schemaOf(T), &.{});
    defer testing.allocator.free(text);
    // Collapse the indent: parse and print compactly.
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(parsed.value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn expectCompact(comptime T: type, expected: []const u8) !void {
    const text = try compactOf(T);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(expected, text);
}

test "schemaName: the last part of a type's name, a generic's arguments each by its own" {
    try testing.expectEqualStrings("TodoResponse", comptime schemaName("dto.TodoResponse"));
    try testing.expectEqualStrings("Inner", comptime schemaName("dto.Outer.Inner"));
    try testing.expectEqualStrings("Page_TodoResponse", comptime schemaName("dto.Page(dto.TodoResponse)"));
    try testing.expectEqualStrings("Pair_Todo_u8", comptime schemaName("dto.Pair(dto.Todo,u8)"));
    try testing.expectEqualStrings("Page_Page_Todo", comptime schemaName("dto.Page(dto.Page(dto.Todo))"));
    try testing.expectEqualStrings("Page_Todo", comptime schemaName("dto.Page(?dto.Todo)"));
    try testing.expectEqualStrings("Page_Todo", comptime schemaName("dto.Page([]const dto.Todo)"));
    try testing.expect(!comptime isSchemaName(schemaName("dto.Named(\"abc\"[0..3])")));
}

test "isSchemaName: ^[a-zA-Z0-9.\\-_]+$" {
    try testing.expect(comptime isSchemaName("Page_Todo-Input.v2"));
    try testing.expect(!comptime isSchemaName(""));
    try testing.expect(!comptime isSchemaName("Page Todo"));
}

test "integer formats and bounds" {
    try expectCompact(u8, "{\"type\":\"integer\",\"format\":\"uint8\",\"minimum\":0,\"maximum\":255}");
    try expectCompact(i16, "{\"type\":\"integer\",\"format\":\"int16\",\"minimum\":-32768,\"maximum\":32767}");
    try expectCompact(u32, "{\"type\":\"integer\",\"format\":\"uint32\",\"minimum\":0,\"maximum\":4294967295}");
    try expectCompact(u64, "{\"type\":\"integer\",\"format\":\"uint64\",\"minimum\":0}");
    try expectCompact(i64, "{\"type\":\"integer\",\"format\":\"int64\"}");
    try expectCompact(usize, "{\"type\":\"integer\",\"minimum\":0}");
    try expectCompact(i128, "{\"type\":\"integer\"}");
    try expectCompact(f32, "{\"type\":\"number\",\"format\":\"float\"}");
    try expectCompact(f64, "{\"type\":\"number\",\"format\":\"double\"}");
    try expectCompact([]const u8, "{\"type\":\"string\"}");
    try expectCompact(bool, "{\"type\":\"boolean\"}");
}

const Priority = enum { low, high };
const Todo = struct {
    id: u64,
    title: []const u8,
    done: bool = false,
    note: ?[]const u8 = null,
    priority: Priority = .low,
};

fn Page(comptime T: type) type {
    return struct { items: []const T, next: ?u32 = null };
}

test "optional, default, required" {
    const Opt = struct { a: ?u8, b: u8 = 3, c: []const u8 };
    const text = try written(componentOf(Opt).schema, &.{});
    defer testing.allocator.free(text);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try std.json.Stringify.value(parsed.value, .{}, &out.writer);
    try testing.expectEqualStrings("{\"type\":\"object\",\"required\":[\"c\"],\"properties\":{\"a\":{\"type\":[\"integer\",\"null\"],\"format\":\"uint8\",\"minimum\":0,\"maximum\":255}," ++
        "\"b\":{\"type\":\"integer\",\"format\":\"uint8\",\"minimum\":0,\"maximum\":255,\"default\":3},\"c\":{\"type\":\"string\"}}}", out.written());
}

test "named vs anonymous structs, and a generic's name" {
    // Todo is named: a ref in a use; its component holds the schema.
    try testing.expect((comptime schemaOf(Todo)) == .ref);
    try testing.expectEqualStrings("Todo", componentOf(Todo).name);
    try testing.expectEqualStrings("Page_Todo", componentOf(Page(Todo)).name);
    // An anonymous struct stands inline.
    try testing.expect((comptime schemaOf(struct { a: u8 })) == .object);
    // Page(Todo) refers to Todo: one dep.
    try testing.expectEqual(1, componentOf(Page(Todo)).deps.len);
    try testing.expect(componentOf(Page(Todo)).deps[0]() == componentOf(Todo));
}

test "enum and a component's schema" {
    const text = try written(componentOf(Todo).schema, &.{ Todo, Priority });
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "\"$ref\": \"#/components/schemas/Priority\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"required\": [\n    \"id\",\n    \"title\"\n  ]") != null);
    const en = try written(componentOf(Priority).schema, &.{});
    defer testing.allocator.free(en);
    try testing.expect(std.mem.indexOf(u8, en, "\"enum\": [\n    \"low\",\n    \"high\"\n  ]") != null);
}

const Tree = struct { value: u8, left: ?*const Tree = null, right: ?*const Tree = null };

test "a recursive type has a component that refers to itself" {
    try testing.expectEqualStrings("Tree", componentOf(Tree).name);
    try testing.expect(componentOf(Tree).deps.len == 2);
    try testing.expect(componentOf(Tree).deps[0]() == componentOf(Tree));
}

test "arrays, fixed arrays, ArrayHashMap, union(enum), json.Value" {
    try expectCompact([]const u32, "{\"type\":\"array\",\"items\":{\"type\":\"integer\",\"format\":\"uint32\",\"minimum\":0,\"maximum\":4294967295}}");
    try expectCompact([2]bool, "{\"type\":\"array\",\"minItems\":2,\"maxItems\":2,\"items\":{\"type\":\"boolean\"}}");
    try expectCompact(std.json.ArrayHashMap(bool), "{\"type\":\"object\",\"additionalProperties\":{\"type\":\"boolean\"}}");
    try expectCompact(std.json.Value, "{}");
    try expectCompact(union(enum) { circle: u8, none }, "{\"oneOf\":[{\"type\":\"object\",\"required\":[\"circle\"],\"properties\":{\"circle\":{\"type\":\"integer\",\"format\":\"uint8\",\"minimum\":0,\"maximum\":255}}}," ++
        "{\"type\":\"object\",\"required\":[\"none\"],\"properties\":{\"none\":{\"type\":\"object\",\"maxProperties\":0}}}]}");
}

const Texts = struct {
    id: u32,
    pub const openapi: declarations.Doc(@This()) = .{
        .name = "Documented",
        .description = "A documented thing.",
        .example = .{ .id = 5 },
        .deprecated = true,
        .fields = .{ .id = .{ .description = "Its id.", .example = 9 } },
    };
};

test "Doc texts and examples" {
    try testing.expectEqualStrings("Documented", componentOf(Texts).name);
    const text = try written(componentOf(Texts).schema, &.{});
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "\"description\": \"A documented thing.\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"deprecated\": true") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"description\": \"Its id.\"") != null);
    // The field's example (9) and the type's example ({"id": 5}), both under "examples".
    try testing.expect(std.mem.indexOf(u8, text, "\"examples\": [\n        9\n      ]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"id\": 5") != null);
}

const Money = struct {
    cents: u64,
    pub const openapi: declarations.Doc(@This()) = .{ .as = []const u8, .description = "An amount." };
    pub fn jsonStringify(self: Money, w: anytype) !void {
        try w.print("\"{d}\"", .{self.cents});
    }
};

test "a jsonStringify type uses Doc.as" {
    const text = try written(componentOf(Money).schema, &.{});
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("{\n  \"type\": \"string\",\n  \"description\": \"An amount.\"\n}\n", text);
}

test {
    std.testing.refAllDecls(@This());
}
