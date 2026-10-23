// Copied from vkiryakov/zefir src/confy/parsers/ini.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! INI files.
//!
//! - `[section]` and `[section.sub]` start a section; keys before the first
//!   section belong to the root.
//! - `key = value`; a dotted key is nested (`pool.size = 4` in `[db]` is `db.pool.size`).
//! - Lines starting with `;` or `#` are comments.
//! - A value in matching "double" or 'single' quotes loses the quotes; there are no escapes.
//! - Every value is a string; `decode` converts it to the field type.
//! - Malformed lines and repeated keys are reported to `diag`; the rest of the file is still read.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Diagnostics = @import("../Diagnostics.zig");
const tree = @import("../tree.zig");
const Object = tree.Object;
const Origin = tree.Origin;

pub fn parse(arena: Allocator, text: []const u8, file: []const u8, diag: *Diagnostics) Allocator.Error!*Object {
    const root = try arena.create(Object);
    root.* = .{};

    var section = root;
    var section_name: []const u8 = "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_number: u32 = 0;
    while (lines.next()) |raw_line| {
        line_number += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == ';' or line[0] == '#') continue;
        const origin: Origin = .{ .file = file, .line = line_number };

        if (line[0] == '[') {
            if (line[line.len - 1] != ']') {
                try diag.add(.{ .kind = .syntax, .origin = origin, .detail = "expected ']' at the end of the section name" });
                continue;
            }
            const name = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            if (!isValidPath(name)) {
                try diag.add(.{ .kind = .syntax, .origin = origin, .detail = "expected a section name like [db] or [db.pool]" });
                continue;
            }
            section = try descend(arena, root, name, "", origin, diag) orelse continue;
            section_name = name;
            continue;
        }

        const eq = std.mem.findScalar(u8, line, '=') orelse {
            try diag.add(.{ .kind = .syntax, .origin = origin, .detail = "expected key = value" });
            continue;
        };
        const key = std.mem.trimEnd(u8, line[0..eq], " \t");
        if (!isValidPath(key)) {
            try diag.add(.{ .kind = .syntax, .origin = origin, .detail = "expected a key like port or pool.size before '='" });
            continue;
        }

        const last_dot = std.mem.findScalarLast(u8, key, '.');
        const parent = if (last_dot) |dot|
            try descend(arena, section, key[0..dot], section_name, origin, diag) orelse continue
        else
            section;
        const name = if (last_dot) |dot| key[dot + 1 ..] else key;

        const gop = try parent.fields.getOrPut(arena, name);
        if (gop.found_existing) {
            const path = try joinPath(arena, section_name, key);
            try diag.addFmt(.duplicate_key, path, origin, "first set on line {d}", .{gop.value_ptr.origin.line});
            continue;
        }
        gop.value_ptr.* = .{
            .value = .{ .string = unquote(std.mem.trimStart(u8, line[eq + 1 ..], " \t")) },
            .origin = origin,
        };
    }
    return root;
}

/// The object at dotted `path` below `base`, created when missing.
/// Returns null, after reporting it, when a value is already where an object should be.
fn descend(
    arena: Allocator,
    base: *Object,
    path: []const u8,
    base_name: []const u8,
    origin: Origin,
    diag: *Diagnostics,
) Allocator.Error!?*Object {
    var object = base;
    var keys = std.mem.splitScalar(u8, path, '.');
    while (keys.next()) |key| {
        const gop = try object.fields.getOrPut(arena, key);
        if (!gop.found_existing) {
            const child = try arena.create(Object);
            child.* = .{};
            gop.value_ptr.* = .{ .value = .{ .object = child }, .origin = origin };
        } else if (gop.value_ptr.value != .object) {
            const full_path = try joinPath(arena, base_name, path);
            try diag.addFmt(.duplicate_key, full_path, origin, "line {d} already sets it to a value", .{gop.value_ptr.origin.line});
            return null;
        }
        object = gop.value_ptr.value.object;
    }
    return object;
}

fn isValidPath(path: []const u8) bool {
    var keys = std.mem.splitScalar(u8, path, '.');
    while (keys.next()) |key| {
        if (key.len == 0) return false;
        for (key) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
        }
    }
    return true;
}

fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2 and (value[0] == '"' or value[0] == '\'') and value[value.len - 1] == value[0]) {
        return value[1 .. value.len - 1];
    }
    return value;
}

fn joinPath(arena: Allocator, parent: []const u8, key: []const u8) Allocator.Error![]const u8 {
    if (parent.len == 0) return key;
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ parent, key });
}

test "sections, nested keys, comments and quotes" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();

    const root = try parse(arena_state.allocator(),
        \\; comment
        \\name = "zefir app"
        \\
        \\[db]
        \\host = localhost
        \\pool.size = 4
        \\
        \\# another comment
        \\[db.tls]
        \\enabled = 'true'
    , "config.ini", &diag);

    try std.testing.expectEqual(0, diag.problems.items.len);
    try std.testing.expectEqualStrings("zefir app", root.fields.get("name").?.value.string);
    const db = root.fields.get("db").?.value.object;
    try std.testing.expectEqualStrings("localhost", db.fields.get("host").?.value.string);
    try std.testing.expectEqual(5, db.fields.get("host").?.origin.line);
    try std.testing.expectEqualStrings("4", db.fields.get("pool").?.value.object.fields.get("size").?.value.string);
    try std.testing.expectEqualStrings("true", db.fields.get("tls").?.value.object.fields.get("enabled").?.value.string);
}

test "problems are reported and the rest is read" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();

    const root = try parse(arena_state.allocator(),
        \\[db
        \\[db]
        \\host = localhost
        \\no pair here
        \\bad key = 1
        \\host = other
        \\port = 5432
    , "config.ini", &diag);

    try std.testing.expectEqualStrings("5432", root.fields.get("db").?.value.object.fields.get("port").?.value.string);

    const text = try std.fmt.allocPrint(std.testing.allocator, "{f}", .{&diag});
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        \\4 configuration problems:
        \\  config.ini:1: syntax error (expected ']' at the end of the section name)
        \\  config.ini:4: syntax error (expected key = value)
        \\  config.ini:5: syntax error (expected a key like port or pool.size before '=')
        \\  config.ini:6: db.host: duplicate key (first set on line 3)
    , text);
}

test "a section or a dotted key can't replace a value" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();

    _ = try parse(arena_state.allocator(),
        \\db = x
        \\[db]
        \\[app]
        \\log = 1
        \\log.level = 2
    , "config.ini", &diag);

    const text = try std.fmt.allocPrint(std.testing.allocator, "{f}", .{&diag});
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        \\2 configuration problems:
        \\  config.ini:2: db: duplicate key (line 1 already sets it to a value)
        \\  config.ini:5: app.log: duplicate key (line 4 already sets it to a value)
    , text);
}

test "invalid section names" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();

    const root = try parse(arena_state.allocator(),
        \\[]
        \\[db..pool]
        \\[my db]
        \\[db]
        \\host = localhost
    , "config.ini", &diag);

    try std.testing.expectEqualStrings("localhost", root.fields.get("db").?.value.object.fields.get("host").?.value.string);

    const text = try std.fmt.allocPrint(std.testing.allocator, "{f}", .{&diag});
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        \\3 configuration problems:
        \\  config.ini:1: syntax error (expected a section name like [db] or [db.pool])
        \\  config.ini:2: syntax error (expected a section name like [db] or [db.pool])
        \\  config.ini:3: syntax error (expected a section name like [db] or [db.pool])
    , text);
}

test "a value is everything after the first '='" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();

    const root = try parse(arena_state.allocator(),
        \\url = postgres://db/app?sslmode=require
        \\password = a;b#c
        \\empty =
        \\mismatched = "a'
    , "config.ini", &diag);

    try std.testing.expectEqual(0, diag.problems.items.len);
    try std.testing.expectEqualStrings("postgres://db/app?sslmode=require", root.fields.get("url").?.value.string);
    try std.testing.expectEqualStrings("a;b#c", root.fields.get("password").?.value.string);
    try std.testing.expectEqualStrings("", root.fields.get("empty").?.value.string);
    try std.testing.expectEqualStrings("\"a'", root.fields.get("mismatched").?.value.string);
}

test "reopened sections and dotted keys share objects" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();

    const root = try parse(arena_state.allocator(),
        \\[db]
        \\pool.size = 4
        \\[cache]
        \\ttl = 60
        \\[db.pool]
        \\max = 8
        \\[db]
        \\host = localhost
    , "config.ini", &diag);

    try std.testing.expectEqual(0, diag.problems.items.len);
    const db = root.fields.get("db").?.value.object;
    const pool = db.fields.get("pool").?.value.object;
    try std.testing.expectEqualStrings("4", pool.fields.get("size").?.value.string);
    try std.testing.expectEqualStrings("8", pool.fields.get("max").?.value.string);
    try std.testing.expectEqualStrings("localhost", db.fields.get("host").?.value.string);
}
