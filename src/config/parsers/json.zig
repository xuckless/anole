// Copied from vkiryakov/zefir src/confy/parsers/json.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! JSON files. The top level must be an object.
//!
//! Integers that fit in `i128` stay integers; other numbers become floats.
//! A repeated key in one object is reported to `diag` and the first value is kept.
//! A syntax error is reported with its line, and the file is skipped; so is
//! nesting deeper than 64 objects and arrays.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Diagnostics = @import("../Diagnostics.zig");
const tree = @import("../tree.zig");
const Node = tree.Node;
const Object = tree.Object;
const Array = tree.Array;

/// The root object, or null when the file is not valid JSON (the problem is in `diag`).
pub fn parse(arena: Allocator, text: []const u8, file: []const u8, diag: *Diagnostics) Allocator.Error!?*Object {
    var scanner: std.json.Scanner = .initCompleteInput(arena, text);
    var position: std.json.Scanner.Diagnostics = .{};
    scanner.enableDiagnostics(&position);

    var parser: Parser = .{ .arena = arena, .scanner = &scanner, .position = &position, .file = file, .diag = diag };
    return parser.parseDocument() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooDeep => {
            try diag.addFmt(.syntax, "", parser.here(), "nested deeper than {d} levels", .{Parser.max_depth});
            return null;
        },
        error.NotAnObject => {
            try diag.add(.{ .kind = .syntax, .origin = parser.here(), .detail = "expected an object at the top level" });
            return null;
        },
        else => {
            try diag.add(.{ .kind = .syntax, .origin = parser.here(), .detail = "invalid JSON" });
            return null;
        },
    };
}

const Parser = struct {
    arena: Allocator,
    scanner: *std.json.Scanner,
    position: *std.json.Scanner.Diagnostics,
    file: []const u8,
    diag: *Diagnostics,
    /// Objects and arrays open around the current token.
    depth: u32 = 0,

    const max_depth = 64;
    const Error = std.json.Scanner.AllocError || error{ NotAnObject, SyntaxError, TooDeep };

    fn here(parser: *const Parser) tree.Origin {
        return .{ .file = parser.file, .line = @intCast(parser.position.getLine()) };
    }

    fn next(parser: *Parser) Error!std.json.Token {
        return parser.scanner.nextAlloc(parser.arena, .alloc_if_needed);
    }

    fn parseDocument(parser: *Parser) Error!*Object {
        if (try parser.next() != .object_begin) return error.NotAnObject;
        const object = try parser.parseObject();
        if (try parser.next() != .end_of_document) return error.SyntaxError;
        return object;
    }

    /// Parses the members of an object whose `{` has been read.
    fn parseObject(parser: *Parser) Error!*Object {
        if (parser.depth == max_depth) return error.TooDeep;
        parser.depth += 1;
        defer parser.depth -= 1;

        const object = try parser.arena.create(Object);
        object.* = .{};
        while (true) {
            const key = switch (try parser.next()) {
                .object_end => return object,
                .string, .allocated_string => |key| key,
                else => return error.SyntaxError,
            };
            const node = try parser.parseValue(try parser.next());
            const gop = try object.fields.getOrPut(parser.arena, key);
            if (gop.found_existing) {
                try parser.diag.addFmt(.duplicate_key, key, node.origin, "first set on line {d}", .{gop.value_ptr.origin.line});
            } else {
                gop.value_ptr.* = node;
            }
        }
    }

    /// Parses the value that starts with `token`.
    fn parseValue(parser: *Parser, token: std.json.Token) Error!Node {
        const origin = parser.here();
        const value: tree.Value = switch (token) {
            .object_begin => .{ .object = try parser.parseObject() },
            .array_begin => .{ .array = try parser.parseArray() },
            .true => .{ .boolean = true },
            .false => .{ .boolean = false },
            .null => .null,
            .number, .allocated_number => |number| if (std.fmt.parseInt(i128, number, 10)) |integer|
                .{ .integer = integer }
            else |_|
                .{ .float = std.fmt.parseFloat(f64, number) catch return error.SyntaxError },
            .string, .allocated_string => |string| .{ .string = string },
            else => return error.SyntaxError,
        };
        return .{ .value = value, .origin = origin };
    }

    /// Parses the items of an array whose `[` has been read.
    fn parseArray(parser: *Parser) Error!*Array {
        if (parser.depth == max_depth) return error.TooDeep;
        parser.depth += 1;
        defer parser.depth -= 1;

        const array = try parser.arena.create(Array);
        array.* = .{};
        while (true) {
            const token = try parser.next();
            if (token == .array_end) return array;
            try array.items.append(parser.arena, try parser.parseValue(token));
        }
    }
};

test "values, nesting, arrays and lines" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();

    const root = (try parse(arena_state.allocator(),
        \\{
        \\  "name": "zefir \"app\"",
        \\  "db": {
        \\    "port": 5432,
        \\    "ratio": 0.5,
        \\    "tls": true,
        \\    "password": null
        \\  },
        \\  "hosts": ["a", "b"]
        \\}
    , "config.json", &diag)).?;

    try std.testing.expectEqual(0, diag.problems.items.len);
    try std.testing.expectEqualStrings("zefir \"app\"", root.fields.get("name").?.value.string);
    const db = root.fields.get("db").?.value.object;
    try std.testing.expectEqual(5432, db.fields.get("port").?.value.integer);
    try std.testing.expectEqual(4, db.fields.get("port").?.origin.line);
    try std.testing.expectEqual(0.5, db.fields.get("ratio").?.value.float);
    try std.testing.expect(db.fields.get("tls").?.value.boolean);
    try std.testing.expect(db.fields.get("password").?.value == .null);
    const hosts = root.fields.get("hosts").?.value.array.items.items;
    try std.testing.expectEqual(2, hosts.len);
    try std.testing.expectEqualStrings("b", hosts[1].value.string);
}

test "problems" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();

    const duplicate = (try parse(arena,
        \\{
        \\  "port": 1,
        \\  "port": 2
        \\}
    , "dup.json", &diag)).?;
    try std.testing.expectEqual(1, duplicate.fields.get("port").?.value.integer);
    try std.testing.expectEqual(null, try parse(arena, "[1, 2]", "array.json", &diag));
    try std.testing.expectEqual(null, try parse(arena, "{\n  \"port\": 1,\n  oops\n}", "broken.json", &diag));

    const text = try std.fmt.allocPrint(std.testing.allocator, "{f}", .{&diag});
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        \\3 configuration problems:
        \\  dup.json:3: port: duplicate key (first set on line 2)
        \\  array.json:1: syntax error (expected an object at the top level)
        \\  broken.json:3: syntax error (invalid JSON)
    , text);
}

test "escaped keys and numbers" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();

    const root = (try parse(arena_state.allocator(),
        \\{
        \\  "name": "line\nnext",
        \\  "negative": -3,
        \\  "exponent": 1e3,
        \\  "max": 9223372036854775807
        \\}
    , "config.json", &diag)).?;

    try std.testing.expectEqual(0, diag.problems.items.len);
    try std.testing.expectEqualStrings("line\nnext", root.fields.get("name").?.value.string);
    try std.testing.expectEqual(-3, root.fields.get("negative").?.value.integer);
    try std.testing.expectEqual(1000, root.fields.get("exponent").?.value.float);
    try std.testing.expectEqual(std.math.maxInt(i64), root.fields.get("max").?.value.integer);
}

test "a document must be exactly one object" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();

    try std.testing.expectEqual(null, try parse(arena, "", "empty.json", &diag));
    try std.testing.expectEqual(null, try parse(arena, "{} x", "trailing.json", &diag));
    try std.testing.expectEqual(null, try parse(arena, "\"text\"", "string.json", &diag));
    try std.testing.expectEqual(null, try parse(arena, "{} {}", "two.json", &diag));

    const text = try std.fmt.allocPrint(std.testing.allocator, "{f}", .{&diag});
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        \\4 configuration problems:
        \\  empty.json:1: syntax error (invalid JSON)
        \\  trailing.json:1: syntax error (invalid JSON)
        \\  string.json:1: syntax error (expected an object at the top level)
        \\  two.json:1: syntax error (invalid JSON)
    , text);
}

test "deep nesting is a problem, not a crash" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();

    const prefix = "{\"a\":";
    const text = try arena.alloc(u8, prefix.len + 100_000);
    @memcpy(text[0..prefix.len], prefix);
    @memset(text[prefix.len..], '[');

    try std.testing.expectEqual(null, try parse(arena, text, "deep.json", &diag));
    try std.testing.expectEqual(1, diag.problems.items.len);
}
