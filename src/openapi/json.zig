// Adapted from vkiryakov/zefir src/openapi/json.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.

//! The tree of a document: the compiler builds it with every check, as
//! data of the program, and `write` turns it into the bytes of the document
//! when the program runs. Building a large text at compile time costs the
//! compiler far more than building this tree (docs/openapi/research,
//! comptime-probe-2.0), so the text is never built there.
//!
//! The bytes are those of `JSON.stringify(value, null, 2)` and of
//! `std.json` with `.whitespace = .indent_2`: a member or an item per line,
//! two spaces a level, `{}` and `[]` when empty, LF, and a newline at the
//! end. The keys keep the order of the tree.
const std = @import("std");

const Writer = std.Io.Writer;

/// A JSON value of a document.
pub const Node = union(enum) {
    object: []const Member,
    array: []const Node,
    /// A string as it reads; the writer escapes it as `std.json` does.
    string: []const u8,
    /// JSON text, written as it is but laid out as the rest of the
    /// document: a number (`"200"`), or a value of `v.schemaOf`, such as
    /// `{"not":{"enum":["a"]}}`. It holds no whitespace outside its strings.
    raw: []const u8,
    boolean: bool,
    null,
    /// A reference to a named schema (`{"$ref": "#/components/schemas/<name>"}`).
    /// The name is resolved when the document is written (renames, clashes),
    /// so no name is ever baked in at compile time. A function, so a type
    /// that refers to itself builds without a comptime cycle.
    ref: RefFn,
};

/// A named, reusable schema: one comptime value per Zig type, so its address
/// identifies the type. `schema` may hold `.ref` nodes to other components.
pub const Component = struct {
    /// The default name (`Doc(T).name` or the last part of the type's name).
    name: []const u8,
    /// `@typeName`, for renames and clash messages.
    type_name: []const u8,
    schema: Node,
    /// The components `schema` refers to.
    deps: []const RefFn,
};

/// Returns a component's address; evaluated at run time.
pub const RefFn = *const fn () *const Component;

/// The names the writer gives components: `names[i]` for `components[i]`.
pub const NameTable = struct {
    components: []const *const Component = &.{},
    names: []const []const u8 = &.{},

    pub fn nameOf(self: NameTable, c: *const Component) []const u8 {
        for (self.components, self.names) |k, n| if (k == c) return n;
        return c.name;
    }
};

/// A member of an object.
pub const Member = struct { key: []const u8, value: Node };

/// Writes `node` as the text of a document, a newline at its end.
pub fn write(node: Node, w: *Writer) Writer.Error!void {
    return writeNamed(node, w, .{});
}

/// `write`, with `names` for the components `.ref` nodes point at.
pub fn writeNamed(node: Node, w: *Writer, names: NameTable) Writer.Error!void {
    try writeValue(node, w, 0, names);
    try w.writeByte('\n');
}

fn writeValue(node: Node, w: *Writer, depth: usize, names: NameTable) Writer.Error!void {
    switch (node) {
        .object => |members| {
            if (members.len == 0) return w.writeAll("{}");
            try w.writeByte('{');
            for (members, 0..) |m, i| {
                if (i > 0) try w.writeByte(',');
                try newline(w, depth + 1);
                try std.json.Stringify.encodeJsonString(m.key, .{}, w);
                try w.writeAll(": ");
                try writeValue(m.value, w, depth + 1, names);
            }
            try newline(w, depth);
            try w.writeByte('}');
        },
        .array => |items| {
            if (items.len == 0) return w.writeAll("[]");
            try w.writeByte('[');
            for (items, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try newline(w, depth + 1);
                try writeValue(item, w, depth + 1, names);
            }
            try newline(w, depth);
            try w.writeByte(']');
        },
        .string => |s| try std.json.Stringify.encodeJsonString(s, .{}, w),
        .raw => |text| try writeRaw(text, w, depth),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .null => try w.writeAll("null"),
        .ref => |f| {
            try w.writeByte('{');
            try newline(w, depth + 1);
            try w.writeAll("\"$ref\": ");
            try w.writeAll("\"#/components/schemas/");
            try w.writeAll(names.nameOf(f()));
            try w.writeByte('"');
            try newline(w, depth);
            try w.writeByte('}');
        },
    }
}

/// A line break and the indent of `depth`.
fn newline(w: *Writer, depth: usize) Writer.Error!void {
    try w.writeByte('\n');
    try w.splatByteAll(' ', 2 * depth);
}

/// The compact JSON text `text` at `depth`, laid out as `writeValue` lays
/// out a tree: strings go as they are, escapes included.
fn writeRaw(text: []const u8, w: *Writer, start: usize) Writer.Error!void {
    var depth = start;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        switch (c) {
            '"' => {
                // The string to its closing quote, past escaped ones.
                var end = i + 1;
                while (end < text.len and text[end] != '"') : (end += 1) {
                    if (text[end] == '\\') end += 1;
                }
                try w.writeAll(text[i..@min(end + 1, text.len)]);
                i = end;
            },
            '{', '[' => {
                const close: u8 = if (c == '{') '}' else ']';
                if (i + 1 < text.len and text[i + 1] == close) {
                    try w.writeAll(text[i .. i + 2]);
                    i += 1;
                } else {
                    try w.writeByte(c);
                    depth += 1;
                    try newline(w, depth);
                }
            },
            '}', ']' => {
                depth -= 1;
                try newline(w, depth);
                try w.writeByte(c);
            },
            ',' => {
                try w.writeByte(',');
                try newline(w, depth);
            },
            ':' => try w.writeAll(": "),
            ' ', '\t', '\n', '\r' => {},
            else => try w.writeByte(c),
        }
    }
}

// ------------------------------------------------------------------ at compile time

/// An object of `members`.
pub fn object(comptime members: []const Member) Node {
    return .{ .object = members };
}

/// The value of `key` in the members of an object, or null.
pub fn get(comptime members: []const Member, comptime key: []const u8) ?Node {
    for (members) |m| {
        if (std.mem.eql(u8, m.key, key)) return m.value;
    }
    return null;
}

/// Whether two trees are the same document.
pub fn eql(comptime a: Node, comptime b: Node) bool {
    @setEvalBranchQuota(100_000);
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .object => |members| blk: {
            if (members.len != b.object.len) break :blk false;
            for (members, b.object) |x, y| {
                if (!std.mem.eql(u8, x.key, y.key) or !eql(x.value, y.value)) break :blk false;
            }
            break :blk true;
        },
        .array => |items| blk: {
            if (items.len != b.array.len) break :blk false;
            for (items, b.array) |x, y| {
                if (!eql(x, y)) break :blk false;
            }
            break :blk true;
        },
        .string => |s| std.mem.eql(u8, s, b.string),
        .raw => |s| std.mem.eql(u8, s, b.raw),
        .boolean => |x| x == b.boolean,
        .null => true,
        .ref => |f| f == b.ref,
    };
}

const testing = std.testing;

fn written(node: Node) ![]u8 {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(node, &out.writer);
    return out.toOwnedSlice();
}

test "write: a member or an item per line, two spaces a level, {} and [] when empty, a newline at the end" {
    const node = comptime object(&.{
        .{ .key = "openapi", .value = .{ .string = "3.1.2" } },
        .{ .key = "tags", .value = .{ .array = &.{object(&.{.{ .key = "name", .value = .{ .string = "Todos" } }})} } },
        .{ .key = "paths", .value = object(&.{}) },
        .{ .key = "list", .value = .{ .array = &.{} } },
        .{ .key = "flags", .value = .{ .array = &.{ .{ .boolean = true }, .null, .{ .raw = "200" } } } },
    });
    const text = try written(node);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        \\{
        \\  "openapi": "3.1.2",
        \\  "tags": [
        \\    {
        \\      "name": "Todos"
        \\    }
        \\  ],
        \\  "paths": {},
        \\  "list": [],
        \\  "flags": [
        \\    true,
        \\    null,
        \\    200
        \\  ]
        \\}
        \\
    , text);
}

test "write: raw JSON text is laid out as the rest; its strings stay as they are" {
    const node = comptime object(&.{
        .{ .key = "pattern", .value = .{ .raw = "\"[^\\\\t\\u0085]{1,}\"" } },
        .{ .key = "not", .value = .{ .raw = "{\"type\":\"string\",\"pattern\":\"^[a-z,:{}\\\"]+$\"}" } },
        .{ .key = "allOf", .value = .{ .raw = "[{\"contains\":{\"const\":1}},{\"contains\":{\"enum\":[]}}]" } },
    });
    const text = try written(node);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        \\{
        \\  "pattern": "[^\\t\u0085]{1,}",
        \\  "not": {
        \\    "type": "string",
        \\    "pattern": "^[a-z,:{}\"]+$"
        \\  },
        \\  "allOf": [
        \\    {
        \\      "contains": {
        \\        "const": 1
        \\      }
        \\    },
        \\    {
        \\      "contains": {
        \\        "enum": []
        \\      }
        \\    }
        \\  ]
        \\}
        \\
    , text);
}

test "write: the bytes of std.json with indent_2, strings escaped as it escapes them" {
    const node = comptime object(&.{
        .{ .key = "title", .value = .{ .string = "Todos \"API\"\n\ttab \\ é 😀 \x01" } },
        .{ .key = "a/b", .value = .{ .array = &.{ .{ .raw = "-1.5e-7" }, .{ .raw = "{\"x\":[1,{\"y\":null}],\"z\":{}}" }, object(&.{}) } } },
        .{ .key = "nested", .value = object(&.{.{ .key = "deeper", .value = object(&.{.{ .key = "ok", .value = .{ .boolean = false } }}) }}) },
    });
    const text = try written(node);
    defer testing.allocator.free(text);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{ .parse_numbers = false });
    defer parsed.deinit();
    var again: Writer.Allocating = .init(testing.allocator);
    defer again.deinit();
    try std.json.Stringify.value(parsed.value, .{ .whitespace = .indent_2 }, &again.writer);
    try again.writer.writeByte('\n');
    try testing.expectEqualStrings(again.written(), text);
}

test "eql compares nodes by value; get finds an object member or returns null" {
    const a = comptime object(&.{ .{ .key = "type", .value = .{ .string = "integer" } }, .{ .key = "minimum", .value = .{ .raw = "0" } } });
    const b = comptime object(&.{ .{ .key = "type", .value = .{ .string = "integer" } }, .{ .key = "minimum", .value = .{ .raw = "1" } } });
    try testing.expect(comptime eql(a, a));
    try testing.expect(comptime !eql(a, b));
    try testing.expectEqualStrings("1", comptime get(b.object, "minimum").?.raw);
    try testing.expectEqual(null, comptime get(b.object, "maximum"));
}

const Target = struct {
    fn get() *const Component {
        return &target;
    }
    const target: Component = .{ .name = "Target", .type_name = "json.Target", .schema = .{ .object = &.{} }, .deps = &.{} };
};

test "write: a ref is resolved through the name table" {
    const node = comptime object(&.{.{ .key = "schema", .value = .{ .ref = &Target.get } }});
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeNamed(node, &out.writer, .{ .components = &.{&Target.target}, .names = &.{"Renamed"} });
    try testing.expectEqualStrings(
        \\{
        \\  "schema": {
        \\    "$ref": "#/components/schemas/Renamed"
        \\  }
        \\}
        \\
    , out.written());
    var plain: Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    try write(node, &plain.writer);
    try testing.expect(std.mem.indexOf(u8, plain.written(), "schemas/Target\"") != null);
}
