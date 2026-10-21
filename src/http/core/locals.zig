// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

//! Per-request values, keyed by name and checked by type: what a middleware
//! found (a user, a tenant, verified token claims) handed to the handler
//! without going through the session. `Request.setLocal` and
//! `Request.local` are the usual way in and out.
const std = @import("std");

pub const Locals = struct {
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct {
        key: []const u8,
        type_id: TypeId,
        value: *anyopaque,
    };

    /// Stores a copy of `value` under `key`, in `arena` (the request's).
    /// `key` is not copied. A second value under a key replaces the first,
    /// whatever its type.
    pub fn put(self: *Locals, arena: std.mem.Allocator, key: []const u8, value: anytype) !void {
        const T = @TypeOf(value);
        const copy = try arena.create(T);
        copy.* = value;
        const entry: Entry = .{ .key = key, .type_id = typeId(T), .value = @ptrCast(copy) };
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.key, key)) {
                e.* = entry;
                return;
            }
        }
        try self.entries.append(arena, entry);
    }

    /// The value under `key`, if it was stored as a `T`.
    pub fn get(self: *const Locals, comptime T: type, key: []const u8) ?T {
        const p = self.getPtr(T, key) orelse return null;
        return p.*;
    }

    /// The stored value itself, to change in place.
    pub fn getPtr(self: *const Locals, comptime T: type, key: []const u8) ?*T {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.key, key)) {
                if (e.type_id != typeId(T)) return null;
                return @ptrCast(@alignCast(e.value));
            }
        }
        return null;
    }

    /// Whether anything is stored under `key`.
    pub fn contains(self: *const Locals, key: []const u8) bool {
        for (self.entries.items) |e| if (std.mem.eql(u8, e.key, key)) return true;
        return false;
    }

    pub fn remove(self: *Locals, key: []const u8) void {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.key, key)) {
                _ = self.entries.orderedRemove(i);
                return;
            }
        }
    }
};

/// One address per type: a distinct static for each `T`.
const TypeId = *const u8;

fn typeId(comptime T: type) TypeId {
    return &struct {
        comptime {
            _ = T;
        }
        var id: u8 = 0;
    }.id;
}

test "Locals: typed values by key, replaced, removed" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var locals: Locals = .{};
    const User = struct { id: u64, name: []const u8 };

    try locals.put(a, "user", User{ .id = 7, .name = "ann" });
    try locals.put(a, "tenant", @as([]const u8, "acme"));
    try std.testing.expectEqual(@as(u64, 7), locals.get(User, "user").?.id);
    try std.testing.expectEqualStrings("acme", locals.get([]const u8, "tenant").?);
    // The wrong type is no value, not a reinterpretation.
    try std.testing.expect(locals.get(u64, "user") == null);
    try std.testing.expect(locals.get([]const u8, "nobody") == null);

    locals.getPtr(User, "user").?.id = 8;
    try std.testing.expectEqual(@as(u64, 8), locals.get(User, "user").?.id);

    try locals.put(a, "user", @as(u32, 3));
    try std.testing.expect(locals.get(User, "user") == null);
    try std.testing.expectEqual(@as(u32, 3), locals.get(u32, "user").?);
    try std.testing.expectEqual(@as(usize, 2), locals.entries.items.len);

    locals.remove("user");
    try std.testing.expect(!locals.contains("user"));
    try std.testing.expect(locals.contains("tenant"));
}

test "typeId: one per type" {
    try std.testing.expect(typeId(u8) == typeId(u8));
    try std.testing.expect(typeId(u8) != typeId(i8));
    try std.testing.expect(typeId([]const u8) != typeId([]u8));
}
