//! The four connectors' `Options` use one vocabulary: the same concept has
//! the same field name and type everywhere it exists, durations carry no
//! unit suffix, and `max_connections = 0` is refused.
const std = @import("std");
const features = @import("build_options");
const anole = @import("root.zig");
const db = anole.db;

const Duration = std.Io.Duration;

const connectors: []const type = blk: {
    var list: []const type = &.{};
    if (features.postgres) list = list ++ [_]type{anole.pg.Options};
    if (features.sqlite) list = list ++ [_]type{anole.sqlite.Options};
    if (features.redis) list = list ++ [_]type{anole.redis.Options};
    if (features.mongodb) list = list ++ [_]type{anole.mongodb.Options};
    break :blk list;
};

test "db: the connectors' options agree" {
    const shared = .{
        .{ "timeout", ?Duration },
        .{ "max_connections", ?u32 },
        .{ "connect_timeout", ?Duration },
        .{ "idle_timeout", ?Duration },
        .{ "ping_timeout", Duration },
        .{ "tls", db.Tls },
        .{ "name", ?[]const u8 },
        .{ "statement_cache_size", u16 },
        .{ "errors", db.ErrorMap },
        .{ "cache", db.CacheOptions },
        .{ "connect_at_start", bool },
        .{ "acquire_timeout", Duration },
    };
    inline for (connectors) |Options| {
        inline for (shared) |entry| {
            if (@hasField(Options, entry[0])) {
                const T = @FieldType(Options, entry[0]);
                try std.testing.expect(T == entry[1]);
            }
        }
        inline for (@typeInfo(Options).@"struct".field_names) |name| {
            try std.testing.expect(!std.mem.endsWith(u8, name, "_ms"));
            try std.testing.expect(!std.mem.endsWith(u8, name, "_seconds"));
        }
    }
}

test "pg and redis: max_connections = 0 is InvalidOptions" {
    const expected_log = @import("errors.zig").expectLog();
    defer expected_log.deinit();
    const io = std.testing.io;
    if (features.postgres) try std.testing.expectError(error.InvalidOptions, anole.pg.Client.init(std.testing.allocator, io, .{ .max_connections = 0, .environ = .empty }));
    if (features.redis) try std.testing.expectError(error.InvalidOptions, anole.redis.Client.init(std.testing.allocator, io, .{ .max_connections = 0, .environ = .empty }));
}

test "redis: tls.ca with redis:// is InvalidOptions" {
    const expected_log = @import("errors.zig").expectLog();
    defer expected_log.deinit();
    if (!features.redis) return error.SkipZigTest;
    try std.testing.expectError(error.InvalidOptions, anole.redis.Client.init(std.testing.allocator, std.testing.io, .{
        .url = "redis://127.0.0.1:1",
        .environ = .empty,
        .tls = .{ .ca = .system },
    }));
}
