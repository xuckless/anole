//! The C ABI's server-sent events and watch configuration (p3/realtime).
const std = @import("std");
const anole = @import("../root.zig");
const parity = @import("parity.zig");
const config = @import("config.zig");
const features = anole.features;

comptime {
    parity.checkCoverage(anole.sse.Topics.Options, &parity.sse_options);
    parity.checkCoverage(anole.sse.RouteOptions, &parity.sse_route_options);
    parity.checkCoverage(anole.watch.Options, &parity.watch_options);
    parity.checkCoverage(anole.watch.Postgres, &parity.watch_postgres);
    parity.checkCoverage(anole.watch.Redis, &parity.watch_redis);
    parity.checkCoverage(anole.watch.RedisStream, &parity.watch_redis_stream);
    parity.checkCoverage(anole.watch.MongoDb, &parity.watch_mongodb);
}

test "parity: the SSE and watch options have keys in the schema, and the defaults agree" {
    const text = @import("anole_capi_schema").text;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), text, .{});
    try parity.checkSchemaAndDefaults(anole.sse.Topics.Options, config.Config, &parity.sse_options, root);
    try parity.checkSchemaAndDefaults(anole.sse.RouteOptions, config.Config, &parity.sse_route_options, root);
    try parity.checkSchemaAndDefaults(anole.watch.Options, config.Config, &parity.watch_options, root);
    try parity.checkSchemaAndDefaults(anole.watch.Postgres, config.Config, &parity.watch_postgres, root);
    try parity.checkSchemaAndDefaults(anole.watch.Redis, config.Config, &parity.watch_redis, root);
    try parity.checkSchemaAndDefaults(anole.watch.RedisStream, config.Config, &parity.watch_redis_stream, root);
    try parity.checkSchemaAndDefaults(anole.watch.MongoDb, config.Config, &parity.watch_mongodb, root);
}

fn expectConfig(text: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var buf: [512]u8 = undefined;
    var why: std.Io.Writer = .fixed(&buf);
    _ = try config.parse(arena.allocator(), text, &why);
}

fn expectRefused(text: []const u8, needle: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var buf: [512]u8 = undefined;
    var why: std.Io.Writer = .fixed(&buf);
    try std.testing.expectError(error.Config, config.parse(arena.allocator(), text, &why));
    if (std.mem.indexOf(u8, why.buffered(), needle) == null) {
        std.debug.print("expected \"{s}\" in: {s}\n", .{ needle, why.buffered() });
        return error.WrongMessage;
    }
}

test "capi config: sse routes and the sse block" {
    try expectConfig(
        \\{"sse":{"heartbeat_ms":5000,"replay":null,"on_full":"drop"},"limits":{"sse_max_event":4096},
        \\ "routes":[{"path":"/rooms/:room/events","sse":{"topics":["news","room:{room}"],"last":3}},
        \\           {"path":"/me","sse":{"handler":7}}]}
    );
    try expectRefused(
        \\{"routes":[{"path":"/x","sse":{"topics":["room:{room}"]}}]}
    , "not a parameter of the path");
    try expectRefused(
        \\{"routes":[{"path":"/x","sse":{}}]}
    , "sse.topics");
    try expectRefused(
        \\{"routes":[{"path":"/x","method":"POST","sse":{"topics":["a"]}}]}
    , "an sse route is GET");
    try expectRefused(
        \\{"routes":[{"path":"/x","handler":1,"sse":{"topics":["a"]}}]}
    , "exactly one of handler");
    try expectRefused(
        \\{"sse":{"replay":{"events":0}}}
    , "sse.replay.events");
}

test "capi config: watches name their database and exactly one source" {
    if (comptime !features.postgres) return error.SkipZigTest;
    try expectConfig(
        \\{"databases":[{"name":"main","postgres":{"url":"postgres://u@localhost/db"}}],
        \\ "watches":[{"name":"orders","database":"main","postgres":{"channels":["orders"]},
        \\             "to":[{"sse":"orders"},{"ws":"orders","type":"binary"}]}]}
    );
    try expectRefused(
        \\{"watches":[{"name":"a","database":"nope","postgres":{"channels":["a"]}}]}
    , "is not in databases");
    try expectRefused(
        \\{"databases":[{"name":"main","postgres":{"url":"postgres://u@localhost/db"}}],
        \\ "watches":[{"name":"a","database":"main","postgres":{"channels":["a"]},"redis":{"channels":["b"]}}]}
    , "exactly one of postgres");
    try expectRefused(
        \\{"databases":[{"name":"main","postgres":{"url":"postgres://u@localhost/db"}}],
        \\ "watches":[{"name":"a","database":"main","redis":{"channels":["b"]}}]}
    , "is not Redis");
    try expectRefused(
        \\{"databases":[{"name":"main","postgres":{"url":"postgres://u@localhost/db"}}],
        \\ "watches":[{"name":"a","database":"main","postgres":{"channels":["a"]},"to":[{"sse":"x","ws":"y"}]}]}
    , "exactly one of sse and ws");
    try expectRefused(
        \\{"databases":[{"name":"main","postgres":{"url":"postgres://u@localhost/db"}}],
        \\ "watches":[{"name":"a","database":"main","postgres":{"channels":[]}}]}
    , "watches[0].postgres.channels");
}

test "capi config: a watch on SQLite says it has no change feed" {
    if (comptime !features.sqlite) return error.SkipZigTest;
    try expectRefused(
        \\{"databases":[{"name":"main","sqlite":{"path":":memory:"}}],
        \\ "watches":[{"name":"a","database":"main","postgres":{"channels":["a"]}}]}
    , "main");
}
