// Adapted from vkiryakov/zefir src/confy/copy.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! Deep copies of decoded values, so the result owns its strings and lists.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Secret = @import("Secret.zig");

/// Copies every slice in `value` with `gpa`. On failure, nothing is leaked.
pub fn dupe(comptime T: type, gpa: Allocator, value: T) Allocator.Error!T {
    if (T == Secret) return .init(try gpa.dupe(u8, value.expose()));
    switch (@typeInfo(T)) {
        .optional => |optional| return if (value) |child| try dupe(optional.child, gpa, child) else null,
        .pointer => |pointer| {
            // `decode` rejects other pointers; returning keeps its error the only one.
            if (pointer.size != .slice) return value;
            if (pointer.child == u8) return gpa.dupe(u8, value);
            const list = try gpa.alloc(pointer.child, value.len);
            var copied: usize = 0;
            errdefer {
                for (list[0..copied]) |item| free(pointer.child, gpa, item);
                gpa.free(list);
            }
            for (value, list) |item, *slot| {
                slot.* = try dupe(pointer.child, gpa, item);
                copied += 1;
            }
            return list;
        },
        .@"struct" => |info| {
            var result: T = undefined;
            var copied: usize = 0;
            errdefer inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, FieldType, attrs, i| {
                if (!attrs.@"comptime" and i < copied) free(FieldType, gpa, @field(result, name));
            };
            inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, FieldType, attrs, i| {
                if (!attrs.@"comptime") @field(result, name) = try dupe(FieldType, gpa, @field(value, name));
                copied = i + 1;
            }
            return result;
        },
        else => return value,
    }
}

/// Frees what `dupe` allocated in `value`. Secrets are wiped first.
pub fn free(comptime T: type, gpa: Allocator, value: T) void {
    if (T == Secret) {
        wipe(value);
        gpa.free(value.expose());
        return;
    }
    switch (@typeInfo(T)) {
        .optional => |optional| if (value) |child| free(optional.child, gpa, child),
        .pointer => |pointer| {
            if (pointer.size != .slice) return;
            if (pointer.child != u8) {
                for (value) |item| free(pointer.child, gpa, item);
            }
            gpa.free(value);
        },
        .@"struct" => |info| inline for (info.field_names, info.field_types, info.field_attrs) |name, FieldType, attrs| {
            if (!attrs.@"comptime") free(FieldType, gpa, @field(value, name));
        },
        else => {},
    }
}

/// Overwrites a secret that `dupe` allocated with zeros. Unlike a plain
/// `@memset`, the compiler can't remove it, and `Allocator.free` only fills
/// freed memory with `undefined`, which release builds may skip.
fn wipe(secret: Secret) void {
    // `dupe` allocated these bytes, so they are writable.
    std.crypto.secureZero(u8, @constCast(secret.expose()));
}

const Example = struct {
    name: []const u8,
    hosts: []const []const u8,
    db: struct { password: ?Secret, port: u16 },
};

fn dupeAndFree(gpa: Allocator) !void {
    const original: Example = .{
        .name = "anole",
        .hosts = &.{ "a", "b" },
        .db = .{ .password = .init("s3cret"), .port = 5432 },
    };
    const copy = try dupe(Example, gpa, original);
    defer free(Example, gpa, copy);

    try std.testing.expectEqualStrings("anole", copy.name);
    try std.testing.expect(copy.name.ptr != original.name.ptr);
    try std.testing.expectEqualStrings("b", copy.hosts[1]);
    try std.testing.expectEqualStrings("s3cret", copy.db.password.?.expose());
    try std.testing.expect(copy.db.password.?.ptr != original.db.password.?.ptr);
    try std.testing.expectEqual(5432, copy.db.port);
}

test "dupe copies every slice and free releases them" {
    try std.testing.checkAllAllocationFailures(@import("../testing/no_resize.zig").allocator, dupeAndFree, .{});
}

const Lists = struct {
    servers: []const struct { host: []const u8, token: ?Secret },
    tokens: []const Secret,
    tags: ?[]const []const u8,
};

fn dupeAndFreeLists(gpa: Allocator) !void {
    const original: Lists = .{
        .servers = &.{ .{ .host = "a", .token = .init("t1") }, .{ .host = "b", .token = null } },
        .tokens = &.{ .init("t2"), .init("t3") },
        .tags = &.{ "x", "y" },
    };
    const copy = try dupe(Lists, gpa, original);
    defer free(Lists, gpa, copy);

    try std.testing.expectEqualStrings("b", copy.servers[1].host);
    try std.testing.expectEqualStrings("t1", copy.servers[0].token.?.expose());
    try std.testing.expectEqual(null, copy.servers[1].token);
    try std.testing.expectEqualStrings("t3", copy.tokens[1].expose());
    try std.testing.expectEqualStrings("y", copy.tags.?[1]);
}

test "dupe and free handle lists of structs, lists of secrets and optional lists" {
    try std.testing.checkAllAllocationFailures(@import("../testing/no_resize.zig").allocator, dupeAndFreeLists, .{});
}

test "wipe zeroes the bytes of a secret" {
    const gpa = std.testing.allocator;
    const secret = try dupe(Secret, gpa, .init("s3cret"));
    defer gpa.free(secret.expose());

    wipe(secret);
    try std.testing.expectEqualSlices(u8, &@as([6]u8, @splat(0)), secret.expose());
}
