//! The schema parity gate's tests (see parity.zig).
const std = @import("std");
const anole = @import("../root.zig");
const parity = @import("parity.zig");
const config = @import("config.zig");

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
