//! C ABI tests for p3/lambda (the `lambda` group), imported from
//! engine_test.zig. The end-to-end cases against a fake Runtime API
//! (a consumer route answered through Lambda, `timeout_us` following the
//! invocation, `anole_server_drain` during a held `/next`) live with the
//! adapter's fake Runtime API helpers (src/lambda/fake_runtime_test.zig).
const std = @import("std");
const anole = @import("../root.zig");
const engine = @import("engine.zig");
const config = @import("config.zig");
const features = anole.features;

test "config: lambda keys" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [400]u8 = undefined;
    {
        var why: std.Io.Writer = .fixed(&buf);
        const c = try config.parse(a, "{}", &why);
        const l = c.lambda;
        try std.testing.expect(l.runtime_api == null);
        try std.testing.expect(l.invoke_mode == null);
        try std.testing.expect(l.concurrency == null);
        try std.testing.expectEqualStrings("/_lambda/event", l.event_path.?);
        try std.testing.expect(l.base_path == null);
        try std.testing.expect(!l.keep_stage);
        try std.testing.expect(l.context_headers);
        try std.testing.expectEqual(@as(u32, 100), l.deadline_margin_ms);
        try std.testing.expectEqual(@as(?u32, 300_000), l.idle_reset_ms);
        try std.testing.expect(l.sigterm);
        try std.testing.expectEqual(@as(u32, 400), l.shutdown_timeout_ms);
        try std.testing.expectEqual(@as(u32, 500), l.flush_timeout_ms);
    }
    {
        var why: std.Io.Writer = .fixed(&buf);
        const c = try config.parse(a,
            \\{"deployment": "lambda", "lambda": {"runtime_api": "127.0.0.1:9001", "invoke_mode": "response_stream",
            \\ "concurrency": 8, "event_path": null, "base_path": "/v1", "keep_stage": true, "context_headers": false,
            \\ "deadline_margin_ms": 250, "idle_reset_ms": null, "sigterm": false, "shutdown_timeout_ms": 300,
            \\ "flush_timeout_ms": 50}}
        , &why);
        const l = c.lambda;
        try std.testing.expectEqualStrings("127.0.0.1:9001", l.runtime_api.?);
        try std.testing.expect(l.invoke_mode.? == .response_stream);
        try std.testing.expectEqual(@as(?u16, 8), l.concurrency);
        try std.testing.expect(l.event_path == null);
        try std.testing.expectEqualStrings("/v1", l.base_path.?);
        try std.testing.expect(l.keep_stage and !l.context_headers and !l.sigterm);
        try std.testing.expectEqual(@as(u32, 250), l.deadline_margin_ms);
        try std.testing.expect(l.idle_reset_ms == null);
        try std.testing.expectEqual(@as(u32, 300), l.shutdown_timeout_ms);
        try std.testing.expectEqual(@as(u32, 50), l.flush_timeout_ms);
    }
    const bad = [_]struct { json: []const u8, needle: []const u8 }{
        .{ .json = "{\"lambda\": {\"invoke_mode\": \"stream\"}}", .needle = "line 1" },
        .{ .json = "{\"lambda\": {\"concurrency\": 0}}", .needle = "lambda.concurrency" },
        .{ .json = "{\"lambda\": {\"concurrency\": 5000}}", .needle = "lambda.concurrency" },
        .{ .json = "{\"lambda\": {\"runtime_api\": \"localhost\"}}", .needle = "lambda.runtime_api" },
        .{ .json = "{\"lambda\": {\"event_path\": \"events\"}}", .needle = "lambda.event_path" },
        .{ .json = "{\"lambda\": {\"nope\": 1}}", .needle = "UnknownField" },
    };
    for (bad) |case| {
        var why: std.Io.Writer = .fixed(&buf);
        try std.testing.expectError(error.Config, config.parse(a, case.json, &why));
        std.testing.expect(std.mem.indexOf(u8, why.buffered(), case.needle) != null) catch |err| {
            std.debug.print("{s}: {s}\n", .{ case.json, why.buffered() });
            return err;
        };
    }
    {
        var why: std.Io.Writer = .fixed(&buf);
        _ = config.parse(a, "{\"lambda\": {\"invoke_mode\": \"stream\"}}", &why) catch {};
        try std.testing.expectEqualStrings("InvalidValue", config.last_problem);
    }
}

fn noVars(_: ?*const anyopaque, _: []const u8) ?[]const u8 {
    return null;
}

fn runtimeApiVars(_: ?*const anyopaque, name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "AWS_LAMBDA_RUNTIME_API")) return "127.0.0.1:9001";
    return null;
}

test "capi lambda: deployment lambda without a Runtime API is LambdaRuntimeApiMissing at create" {
    if (comptime !features.lambda) return error.SkipZigTest;
    engine._test_vars = .{ .real = noVars, .any = noVars };
    defer engine._test_vars = null;
    var why_buf: [256]u8 = undefined;
    var why: std.Io.Writer = .fixed(&why_buf);
    try std.testing.expectError(error.LambdaRuntimeApiMissing, engine.Engine.create("{\"deployment\":\"lambda\"}", false, &why));
    try std.testing.expect(std.mem.indexOf(u8, why.buffered(), "AWS_LAMBDA_RUNTIME_API is not set") != null);
}

test "capi lambda: the lambda group reaches the server options and the modes" {
    if (comptime !features.lambda) return error.SkipZigTest;
    engine._test_vars = .{ .real = runtimeApiVars, .any = runtimeApiVars };
    defer engine._test_vars = null;
    var why_buf: [256]u8 = undefined;
    var why: std.Io.Writer = .fixed(&why_buf);
    const e = try engine.Engine.create("{\"deployment\":\"lambda\",\"lambda\":{\"concurrency\":2,\"deadline_margin_ms\":250,\"idle_reset_ms\":null}}", false, &why);
    defer e.destroy();
    try std.testing.expectEqual(@as(?u16, 2), e.options.lambda.concurrency);
    try std.testing.expectEqual(std.Io.Duration.fromMilliseconds(250), e.options.lambda.deadline_margin);
    try std.testing.expect(e.options.lambda.idle_reset == null);
    const l = e.resolved.lambda.?;
    try std.testing.expectEqualStrings("127.0.0.1:9001", l.endpoint);
    try std.testing.expectEqual(@as(u16, 2), l.concurrency);
}
