//! C ABI tests for p3/webhooks, imported from engine_test.zig.
const std = @import("std");
const anole = @import("../root.zig");
const abi = @import("abi.zig");
const config = @import("config.zig");
const parity = @import("parity.zig");
const features = anole.features;

comptime {
    if (features.webhooks) {
        parity.checkCoverage(anole.webhooks.Options, &parity.webhooks_options);
        parity.checkCoverage(anole.webhooks.Verify.Options, &parity.webhook_verify_options);
    }
}

test "webhooks: the records are the sizes anole.h states" {
    try std.testing.expectEqual(@as(usize, 112), @sizeOf(abi.WebhookOut));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(abi.WebhookPublishedEvent));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(abi.WebhookStatusEvent));
}

test "webhooks: the configuration parses, with defaults" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var buf: [400]u8 = undefined;
    var why: std.Io.Writer = .fixed(&buf);
    const c = try config.parse(arena.allocator(),
        \\{"webhooks": {"attempts": 5, "backoff": {"jitter": "none"}},
        \\ "middleware": [{"webhook_verify": {"preset": "stripe", "secrets": ["whsec_x"]}},
        \\                {"webhook_verify": {"preset": "hmac", "secrets_env": "K", "dedup": "none",
        \\                 "hmac": {"header": "X-Sig", "prefix": "sha256="}}}]}
    , &why);
    const w = c.webhooks.?;
    try std.testing.expectEqual(@as(u16, 5), w.attempts);
    try std.testing.expectEqualStrings("webhooks", w.queue);
    try std.testing.expectEqual(@as(u32, 5_000), w.backoff.base_ms);
    try std.testing.expect(w.backoff.jitter == .none);
    try std.testing.expect(w.breaker != null);
    const v = c.middleware[0].webhook_verify;
    try std.testing.expect(v.preset == .stripe);
    try std.testing.expectEqual(@as(u32, 300_000), v.tolerance_ms);
    try std.testing.expectEqualStrings("memory", v.dedup);
    const h = c.middleware[1].webhook_verify;
    try std.testing.expectEqualStrings("sha256=", h.hmac.?.prefix);
}

test "webhooks: bad webhook_verify settings are refused with the key named" {
    if (comptime !features.webhooks) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { json: []const u8, needle: []const u8 }{
        .{ .json = "{\"middleware\": [{\"webhook_verify\": {\"preset\": \"stripe\"}}]}", .needle = "exactly one of secrets and secrets_env" },
        .{ .json = "{\"middleware\": [{\"webhook_verify\": {\"preset\": \"hmac\", \"secrets\": [\"a\"]}}]}", .needle = "needs the hmac settings" },
        .{ .json = "{\"middleware\": [{\"webhook_verify\": {\"preset\": \"github\", \"secrets\": [\"a\"], \"dedup\": \"disk\"}}]}", .needle = "dedup" },
        .{ .json = "{\"middleware\": [{\"webhook_verify\": {\"preset\": \"github\", \"secrets\": [\"a\"], \"hmac\": {\"header\": \"x\"}}}]}", .needle = "only with preset" },
    };
    for (cases) |case| {
        var buf: [400]u8 = undefined;
        var why: std.Io.Writer = .fixed(&buf);
        try std.testing.expectError(error.Config, config.parse(arena.allocator(), case.json, &why));
        try std.testing.expect(std.mem.indexOf(u8, why.buffered(), case.needle) != null);
    }
}
