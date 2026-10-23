// Copied from vkiryakov/zefir src/confy/tree.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! The configuration tree. File sources parse into it, environment variables are
//! placed into it at the paths of the fields they name, and `decode` reads it
//! into the user's struct.
//!
//! Every node remembers where its value came from, so problems can point at a
//! file and line.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Where a value came from.
pub const Origin = struct {
    /// Path of the file; null for the process environment.
    file: ?[]const u8 = null,
    /// 1-based line in `file`; 0 when unknown.
    line: u32 = 0,
    /// Name of the variable, when the value came from the environment or a `.env` file.
    env_key: ?[]const u8 = null,
};

pub const Value = union(enum) {
    null,
    string: []const u8,
    integer: i128,
    float: f64,
    boolean: bool,
    object: *Object,
    array: *Array,
};

pub const Node = struct {
    value: Value,
    origin: Origin = .{},
};

pub const Object = struct {
    fields: std.array_hash_map.String(Node) = .empty,
};

pub const Array = struct {
    items: std.ArrayList(Node) = .empty,
};

/// Owns every node in one arena; `deinit` frees them all.
///
/// Create it once with `var tree = try Tree.init(gpa);` and pass `*Tree` around:
/// `allocator()` points into this value, so don't copy a `Tree` after calling it.
/// Nodes keep keys and strings without copying them, so anything put into the
/// tree must live at least as long as the tree (allocate it with `allocator()`).
pub const Tree = struct {
    arena: std.heap.ArenaAllocator,
    root_object: *Object,

    pub fn init(gpa: Allocator) Allocator.Error!Tree {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();

        const root_object = try arena.allocator().create(Object);
        root_object.* = .{};

        return .{
            .arena = arena,
            .root_object = root_object,
        };
    }

    pub fn allocator(self: *Tree) Allocator {
        return self.arena.allocator();
    }

    pub fn root(self: *Tree) *Object {
        return self.root_object;
    }

    pub fn deinit(self: *Tree) void {
        self.arena.deinit();
    }

    /// Sets the node at `path` (one key per element), creating objects on the way.
    /// Whatever is already at `path`, and any non-object in the way, is replaced.
    pub fn put(self: *Tree, path: []const []const u8, node: Node) Allocator.Error!void {
        std.debug.assert(path.len > 0);
        const arena = self.allocator();

        var object = self.root_object;
        for (path[0 .. path.len - 1]) |key| {
            const gop = try object.fields.getOrPut(arena, key);
            if (!gop.found_existing or gop.value_ptr.value != .object) {
                const child = try arena.create(Object);
                child.* = .{};
                gop.value_ptr.* = .{ .value = .{ .object = child }, .origin = node.origin };
            }
            object = gop.value_ptr.value.object;
        }
        try object.fields.put(arena, path[path.len - 1], node);
    }

    /// Merges `source` into the root. Objects merge key by key; anything else in
    /// `source` replaces what is there. `source` must live in this tree's arena.
    pub fn merge(self: *Tree, source: *const Object) Allocator.Error!void {
        try mergeObject(self.allocator(), self.root_object, source);
    }
};

fn mergeObject(arena: Allocator, target: *Object, source: *const Object) Allocator.Error!void {
    for (source.fields.keys(), source.fields.values()) |key, node| {
        const gop = try target.fields.getOrPut(arena, key);
        if (gop.found_existing and gop.value_ptr.value == .object and node.value == .object) {
            try mergeObject(arena, gop.value_ptr.value.object, node.value.object);
        } else {
            gop.value_ptr.* = node;
        }
    }
}

test "put creates objects on the way" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();

    try tree.put(&.{ "db", "port" }, .{ .value = .{ .string = "5432" }, .origin = .{ .env_key = "APP_DB_PORT" } });

    const db = tree.root().fields.get("db").?;
    const port = db.value.object.fields.get("port").?;
    try std.testing.expectEqualStrings("5432", port.value.string);
    try std.testing.expectEqualStrings("APP_DB_PORT", port.origin.env_key.?);
}

test "put replaces a non-object in the way" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();

    try tree.put(&.{"db"}, .{ .value = .{ .string = "oops" } });
    try tree.put(&.{ "db", "host" }, .{ .value = .{ .string = "localhost" } });

    const db = tree.root().fields.get("db").?;
    try std.testing.expectEqualStrings("localhost", db.value.object.fields.get("host").?.value.string);
}

test "merge combines objects and replaces values" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const arena = tree.allocator();

    try tree.put(&.{ "db", "host" }, .{ .value = .{ .string = "db.internal" } });
    try tree.put(&.{ "db", "port" }, .{ .value = .{ .integer = 5432 } });

    const db = try arena.create(Object);
    db.* = .{};
    try db.fields.put(arena, "port", .{ .value = .{ .integer = 6543 } });
    const source = try arena.create(Object);
    source.* = .{};
    try source.fields.put(arena, "db", .{ .value = .{ .object = db } });

    try tree.merge(source);

    const merged = tree.root().fields.get("db").?.value.object;
    try std.testing.expectEqualStrings("db.internal", merged.fields.get("host").?.value.string);
    try std.testing.expectEqual(6543, merged.fields.get("port").?.value.integer);
}

test "merge replaces an object with a value and a value with an object" {
    var tree = try Tree.init(std.testing.allocator);
    defer tree.deinit();
    const arena = tree.allocator();

    try tree.put(&.{ "db", "host" }, .{ .value = .{ .string = "db.internal" } });
    try tree.put(&.{"hosts"}, .{ .value = .{ .string = "a,b" } });

    const hosts = try arena.create(Object);
    hosts.* = .{};
    try hosts.fields.put(arena, "first", .{ .value = .{ .string = "a" } });
    const source = try arena.create(Object);
    source.* = .{};
    try source.fields.put(arena, "db", .{ .value = .{ .string = "flat" } });
    try source.fields.put(arena, "hosts", .{ .value = .{ .object = hosts } });

    try tree.merge(source);

    try std.testing.expectEqualStrings("flat", tree.root().fields.get("db").?.value.string);
    const merged = tree.root().fields.get("hosts").?.value.object;
    try std.testing.expectEqualStrings("a", merged.fields.get("first").?.value.string);
}

fn initAndDeinit(gpa: Allocator) !void {
    var tree = try Tree.init(gpa);
    tree.deinit();
}

test "init frees everything when memory runs out" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, initAndDeinit, .{});
}
