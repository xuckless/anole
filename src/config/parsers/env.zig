// Adapted from vkiryakov/zefir src/confy/parsers/env.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! Places environment variables into the tree at the paths of the fields they name.
//!
//! Variables are looked up by the names computed from the config struct
//! (`naming.leaves`), so `APP_DB_PORT` lands at `db.port` without guessing where
//! one key ends and the next begins. Other variables are ignored.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Tree = @import("../tree.zig").Tree;
const naming = @import("../naming.zig");
const dotenv = @import("dotenv.zig");

/// `names[i]` is the full variable name (prefix included) of `leaves[i]`.
pub fn placeDotEnv(
    tree: *Tree,
    leaves: []const naming.Leaf,
    names: []const []const u8,
    vars: *const dotenv.Vars,
    file: []const u8,
) Allocator.Error!void {
    for (leaves, names) |leaf, name| {
        const entry = vars.get(name) orelse continue;
        try tree.put(leaf.path, .{
            .value = .{ .string = entry.value },
            .origin = .{ .file = file, .line = entry.line, .env_key = name },
        });
    }
}

/// The entries of Anole's `.env` files; each keeps its file and line.
pub fn placeOverlay(
    tree: *Tree,
    leaves: []const naming.Leaf,
    names: []const []const u8,
    files: *const @import("../../env.zig").Files,
) Allocator.Error!void {
    for (leaves, names) |leaf, name| {
        const entry = files.entries.get(name) orelse continue;
        try tree.put(leaf.path, .{
            .value = .{ .string = entry.value },
            .origin = .{ .file = entry.file, .line = entry.line, .env_key = name },
        });
    }
}

/// `names[i]` is the full variable name (prefix included) of `leaves[i]`.
/// Values are not copied, so `environ` must outlive `tree`.
pub fn placeEnviron(
    tree: *Tree,
    leaves: []const naming.Leaf,
    names: []const []const u8,
    environ: *const std.process.Environ.Map,
) Allocator.Error!void {
    for (leaves, names) |leaf, name| {
        const value = environ.get(name) orelse continue;
        try tree.put(leaf.path, .{
            .value = .{ .string = value },
            .origin = .{ .env_key = name },
        });
    }
}

test "only variables that name a field are placed" {
    const Config = struct { db: struct { port: u16 }, name: []const u8 };
    const leaves = comptime naming.leaves(Config);
    const names = [_][]const u8{ "APP_DB_PORT", "APP_NAME" };

    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("APP_DB_PORT", "5432");
    try environ.put("HOME", "/home/me");

    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    try placeEnviron(&tree, leaves, &names, &environ);

    try std.testing.expectEqual(1, tree.root().fields.count());
    const port = tree.root().fields.get("db").?.value.object.fields.get("port").?;
    try std.testing.expectEqualStrings("5432", port.value.string);
    try std.testing.expectEqualStrings("APP_DB_PORT", port.origin.env_key.?);
}

test "variables from a .env file keep their file and line" {
    const Config = struct { port: u16 };
    const leaves = comptime naming.leaves(Config);
    const names = [_][]const u8{"APP_PORT"};

    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    var vars: dotenv.Vars = .empty;
    try vars.put(tree.allocator(), "APP_PORT", .{ .value = "8080", .line = 3 });
    try placeDotEnv(&tree, leaves, &names, &vars, ".env");

    const port = tree.root().fields.get("port").?;
    try std.testing.expectEqualStrings("8080", port.value.string);
    try std.testing.expectEqualStrings(".env", port.origin.file.?);
    try std.testing.expectEqual(3, port.origin.line);
    try std.testing.expectEqualStrings("APP_PORT", port.origin.env_key.?);
}
