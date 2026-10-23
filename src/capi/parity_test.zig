//! The schema parity gate's tests (see parity.zig).
const std = @import("std");
const anole = @import("../root.zig");
const parity = @import("parity.zig");
const config = @import("config.zig");
const features = anole.features;

// A new ServerOptions field without a JSON key or a reason is a compile
// error here, naming it.
comptime {
    parity.checkCoverage(anole.ServerOptions, &parity.server_options);
}

test "parity: every ServerOptions leaf has a C ABI key or a reason" {
    // The check is the comptime block above; this names it in the test list.
    comptime parity.checkCoverage(anole.ServerOptions, &parity.server_options);
}

test "parity: mapped keys exist in the schema and defaults agree" {
    const text = @import("anole_capi_schema").text;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), text, .{});
    try parity.checkSchemaAndDefaults(anole.ServerOptions, config.Config, &parity.server_options, root);
}

test "parity: shutdown drains for 10 s by default, in Zig and in the JSON" {
    try std.testing.expectEqual(std.Io.Duration.fromSeconds(10), (anole.ServerOptions{}).timeouts.shutdown.?);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var buf: [256]u8 = undefined;
    var why: std.Io.Writer = .fixed(&buf);
    const cfg = try config.parse(arena.allocator(), "{}", &why);
    try std.testing.expectEqual(@as(?u32, 10_000), cfg.timeouts.shutdown_ms);
}

comptime {
    if (anole.features.websocket) parity.checkCoverage(anole.websocket.UpgradeOptions, &parity.websocket_options);
}

test "parity: every WebSocket UpgradeOptions leaf has a C ABI key or a reason, and the keys are in the schema" {
    if (comptime !anole.features.websocket) return error.SkipZigTest;
    const text = @import("anole_capi_schema").text;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), text, .{});
    try parity.checkSchemaAndDefaults(anole.websocket.UpgradeOptions, config.Config, &parity.websocket_options, root);
}

test "capi config: every connector option is in the schema or listed" {
    const text = @import("anole_capi_schema").text;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), text, .{});
    if (comptime features.postgres) {
        comptime parity.checkCoverage(anole.pg.Options, &parity.pg_options);
        try parity.checkSchemaAndDefaults(anole.pg.Options, config.Config, &parity.pg_options, root);
    }
    if (comptime features.sqlite) {
        comptime parity.checkCoverage(anole.sqlite.Options, &parity.sqlite_options);
        try parity.checkSchemaAndDefaults(anole.sqlite.Options, config.Config, &parity.sqlite_options, root);
    }
    if (comptime features.redis) {
        comptime parity.checkCoverage(anole.redis.Options, &parity.redis_options);
        try parity.checkSchemaAndDefaults(anole.redis.Options, config.Config, &parity.redis_options, root);
    }
    if (comptime features.mongodb) {
        comptime parity.checkCoverage(anole.mongodb.Options, &parity.mongodb_options);
        try parity.checkSchemaAndDefaults(anole.mongodb.Options, config.Config, &parity.mongodb_options, root);
    }
    if (comptime features.nats) {
        comptime parity.checkCoverage(anole.nats.Options, &parity.nats_options);
        try parity.checkSchemaAndDefaults(anole.nats.Options, config.Config, &parity.nats_options, root);
    }
}

test "capi config: mongodb max_connections 0 is E_CONFIG; sqlite statement_cache is an unknown key" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var buf: [512]u8 = undefined;
    var why: std.Io.Writer = .fixed(&buf);
    try std.testing.expectError(error.Config, config.parse(arena.allocator(),
        \\{"databases":[{"name":"m","mongodb":{"max_connections":0}}]}
    , &why));
    var why2: std.Io.Writer = .fixed(&buf);
    try std.testing.expectError(error.Config, config.parse(arena.allocator(),
        \\{"databases":[{"name":"s","sqlite":{"path":":memory:","statement_cache":8}}]}
    , &why2));
}

test "capi config: brokers parse with the defaults, and bad combinations are E_CONFIG" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var buf: [512]u8 = undefined;
    var why: std.Io.Writer = .fixed(&buf);
    if (comptime features.nats) {
        const cfg = try config.parse(arena.allocator(),
            \\{"brokers":[{"name":"events","nats":{"url":"nats://127.0.0.1:4222","jetstream":{"streams":[{"name":"ORDERS","subjects":["orders.>"]}]}}}]}
        , &why);
        try std.testing.expectEqual(@as(usize, 1), cfg.brokers.len);
        try std.testing.expectEqual(@as(u32, 30_000), cfg.brokers[0].timeout_ms);
        try std.testing.expectEqual(@as(u8, 5), cfg.brokers[0].retry.attempts);
        try std.testing.expectEqualStrings("one", cfg.brokers[0].nats.?.connections);
        try std.testing.expectEqual(@as(usize, 1), cfg.brokers[0].nats.?.jetstream.streams.len);
        try std.testing.expectEqualStrings("limits", cfg.brokers[0].nats.?.jetstream.streams[0].retention);
    }
    for ([_][]const u8{
        \\{"brokers":[{"name":"e"}]}
        ,
        \\{"brokers":[{"name":"e","nats":{"token":"a","user":"u","password":"p"}}]}
        ,
        \\{"brokers":[{"name":"e","nats":{"connections":"many"}}]}
        ,
        \\{"brokers":[{"name":"e","nats":{}},{"name":"e","nats":{}}]}
        ,
        \\{"brokers":[{"name":"e","nats":{"ca_file":"a","ca_pem":"b"}}]}
        ,
    }) |text| {
        var w: std.Io.Writer = .fixed(&buf);
        try std.testing.expectError(error.Config, config.parse(arena.allocator(), text, &w));
    }
}

test "capi config: databases breaker and retry default to Zig's, and breaker null turns it off" {
    if (comptime !features.redis) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var buf: [512]u8 = undefined;
    var why: std.Io.Writer = .fixed(&buf);
    const cfg = try config.parse(arena.allocator(),
        \\{"databases":[{"name":"a","redis":{}},{"name":"b","redis":{},"breaker":null,"retry":{"attempts":2}}]}
    , &why);
    const defaults = anole.resilience.Breaker.Options{};
    try std.testing.expectEqual(defaults.consecutive_failures, cfg.databases[0].breaker.?.consecutive_failures);
    try std.testing.expectEqual(@as(u32, @intCast(@divTrunc(defaults.open_for.nanoseconds, std.time.ns_per_ms))), cfg.databases[0].breaker.?.open_ms);
    try std.testing.expect(cfg.databases[1].breaker == null);
    try std.testing.expectEqual(@as(u8, 2), cfg.databases[1].retry.attempts);
}
