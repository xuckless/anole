// Adapted from vkiryakov/zefir src/confy/naming.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! Field paths of a config struct and the environment variable names for them,
//! all computed at compile time.

const std = @import("std");
const Secret = @import("Secret.zig");
const Duration = std.Io.Duration;

/// A field that holds a value rather than a nested struct.
pub const Leaf = struct {
    /// Keys from the root to the field, e.g. `{ "db", "port" }`.
    path: []const []const u8,
    /// Environment variable name without the prefix, e.g. `DB_PORT`.
    env_name: []const u8,
};

/// Every leaf field of `T`, nested structs included. Two fields that map to the
/// same environment variable (`db_port` and `db.port`) are a compile error.
pub fn leaves(comptime T: type) []const Leaf {
    comptime {
        @setEvalBranchQuota(100_000);
        const list = collect(T, &.{});
        // Each pair below compares two names byte by byte.
        @setEvalBranchQuota(100_000 + 100 * list.len * list.len);
        for (list, 0..) |a, i| {
            for (list[i + 1 ..]) |b| {
                if (std.mem.eql(u8, a.env_name, b.env_name)) @compileError(
                    "anole.config: fields '" ++ join(a.path) ++ "' and '" ++ join(b.path) ++
                        "' both map to the environment variable " ++ a.env_name,
                );
            }
        }
        return list;
    }
}

/// The struct type behind `T` or `?T`; null when `T` is not a struct with
/// fields of its own (a `Secret` is a single value).
pub fn StructOf(comptime T: type) ?type {
    const Child = switch (@typeInfo(T)) {
        .optional => |optional| optional.child,
        else => T,
    };
    if (@typeInfo(Child) != .@"struct" or Child == Secret or Child == Duration) return null;
    return Child;
}

fn collect(comptime T: type, comptime prefix: []const []const u8) []const Leaf {
    var list: []const Leaf = &.{};
    const info = @typeInfo(T).@"struct";
    for (info.field_names, info.field_types) |name, FieldType| {
        const path = prefix ++ [_][]const u8{name};
        if (StructOf(FieldType)) |Child| {
            list = list ++ collect(Child, path);
        } else {
            list = list ++ [_]Leaf{.{ .path = path, .env_name = envName(path) }};
        }
    }
    return list;
}

fn envName(comptime path: []const []const u8) []const u8 {
    var name: []const u8 = "";
    for (path, 0..) |key, i| {
        if (i != 0) name = name ++ "_";
        for (key) |c| name = name ++ [_]u8{std.ascii.toUpper(c)};
    }
    return name;
}

fn join(comptime path: []const []const u8) []const u8 {
    var joined: []const u8 = "";
    for (path, 0..) |key, i| {
        if (i != 0) joined = joined ++ ".";
        joined = joined ++ key;
    }
    return joined;
}

test "leaves of a nested struct" {
    const Config = struct {
        name: []const u8,
        db: struct {
            host: []const u8,
            pool: ?struct { size: u8 = 4 },
            password: ?Secret,
        },
        log_level: enum { debug, info } = .info,
    };
    const list = comptime leaves(Config);

    try std.testing.expectEqual(5, list.len);
    try std.testing.expectEqualStrings("NAME", list[0].env_name);
    try std.testing.expectEqualStrings("DB_HOST", list[1].env_name);
    try std.testing.expectEqualStrings("DB_POOL_SIZE", list[2].env_name);
    try std.testing.expectEqualStrings("DB_PASSWORD", list[3].env_name);
    try std.testing.expectEqualStrings("LOG_LEVEL", list[4].env_name);
    try std.testing.expectEqual(3, list[2].path.len);
    try std.testing.expectEqualStrings("size", list[2].path[2]);
}

test "lists and secrets are leaves" {
    const Config = struct {
        servers: []const struct { host: []const u8 },
        token: Secret,
        tls: ?struct { cert: []const u8 },
    };
    const list = comptime leaves(Config);

    try std.testing.expectEqual(3, list.len);
    try std.testing.expectEqualStrings("SERVERS", list[0].env_name);
    try std.testing.expectEqualStrings("TOKEN", list[1].env_name);
    try std.testing.expectEqualStrings("TLS_CERT", list[2].env_name);
    try std.testing.expect(StructOf(Secret) == null);
    try std.testing.expect(StructOf(?Config).? == Config);
}
