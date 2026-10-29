//! C ABI tests for p3/lambda (the `lambda` group), imported from
//! engine_test.zig. The end-to-end cases at the end run against the fake
//! Runtime API of src/lambda/fake_runtime_test.zig: a consumer route answered
//! through Lambda, `timeout_us` following the invocation, and
//! `anole_server_drain` during a held `/next`.
const std = @import("std");
const wait = @import("anole_test_wait");
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

// ---- end to end against the fake Runtime API (design-lambda §12.5, 51-53)

const fake_rt = @import("../lambda/fake_runtime_test.zig");
const abi = engine.abi;

fn httpApiEvent(comptime path: []const u8) []const u8 {
    return "{\"version\":\"2.0\",\"routeKey\":\"$default\",\"rawPath\":\"" ++ path ++ "\",\"rawQueryString\":\"\"," ++
        "\"headers\":{\"host\":\"api.example.com\"},\"requestContext\":{\"domainName\":\"api.example.com\"," ++
        "\"http\":{\"method\":\"GET\",\"path\":\"" ++ path ++ "\",\"protocol\":\"HTTP/1.1\",\"sourceIp\":\"203.0.113.9\",\"userAgent\":\"curl\"}," ++
        "\"requestId\":\"r1\",\"stage\":\"$default\"},\"isBase64Encoded\":false}";
}

fn lambdaEngine(f: *fake_rt.Fake, comptime routes: []const u8) !struct { *engine.Engine, *engine.Consumer } {
    const json = try std.fmt.allocPrint(std.testing.allocator, "{{\"deployment\":\"lambda\",\"lambda\":{{\"runtime_api\":\"{s}\",\"sigterm\":false}}," ++
        "\"timeouts\":{{\"shutdown_ms\":200}},\"listeners\":[{{\"port\":0}}],\"routes\":" ++ routes ++ "}}", .{f.api()});
    defer std.testing.allocator.free(json);
    var why_buf: [256]u8 = undefined;
    var why: std.Io.Writer = .fixed(&why_buf);
    const e = engine.Engine.create(json, false, &why) catch |err| {
        std.debug.print("{s}\n", .{why.buffered()});
        return err;
    };
    errdefer e.destroy();
    const c = try e.attach(null, null, false);
    try e.start();
    return .{ e, c };
}

fn span(rec: []const u8, s: abi.Span) []const u8 {
    return rec[s.off..][0..s.len];
}

/// The value of header `name` in a request record, or null.
fn recHeader(rec: []const u8, r: *const abi.RequestEvent, name: []const u8) ?[]const u8 {
    const spans: [*]const abi.Span = @ptrCast(@alignCast(&rec[r.spans_off]));
    for (0..r.nheaders) |i| {
        if (std.ascii.eqlIgnoreCase(span(rec, spans[2 * i]), name)) return span(rec, spans[2 * i + 1]);
    }
    return null;
}

/// Polls until a request record arrives; copies it into `out`.
fn nextRequest(c: *engine.Consumer, out: []align(8) u8) ![]align(8) u8 {
    var buf: [64 * 1024]u8 align(8) = undefined;
    var need: u32 = 0;
    const tio = engine.threadedIo();
    const started = std.Io.Clock.awake.now(tio);
    while (started.untilNow(tio, .awake).nanoseconds < wait.deadline().nanoseconds) {
        const n = try engine.pollWait(c, &buf, 50, &need);
        var off: usize = 0;
        while (off < n) {
            const ev: *const abi.Event = @ptrCast(@alignCast(&buf[off]));
            if (ev.type == @backingInt(abi.EventType.request)) {
                @memcpy(out[0..ev.len], buf[off..][0..ev.len]);
                return out[0..ev.len];
            }
            off += ev.len;
        }
    }
    return error.TimedOut;
}

fn waitPosts(f: *fake_rt.Fake, n: usize) !void {
    const Posts = struct { f: *fake_rt.Fake, n: usize };
    try wait.waitUntil(engine.threadedIo(), "the Runtime API got the posts and was drained", Posts{ .f = f, .n = n }, struct {
        fn done(c: Posts) bool {
            return c.f.postCount() >= c.n and c.f.drained.load(.acquire);
        }
    }.done);
}

test "capi lambda: a consumer route and a fixed route answered through the Runtime API" {
    if (comptime !features.lambda) return error.SkipZigTest;
    var f: fake_rt.Fake = undefined;
    try f.start(&.{
        .{ .request_id = "r-hi", .event = httpApiEvent("/hi") },
        .{ .request_id = "r-fixed", .event = httpApiEvent("/fixed") },
    });
    defer f.stop();
    const e, const c = try lambdaEngine(&f,
        \\[{{"path":"/hi","handler":1}},{{"path":"/fixed","respond":{{"status":200,"body":"ok"}}}}]
    );
    defer e.destroy();
    var rbuf: [64 * 1024]u8 align(8) = undefined;
    const rec = try nextRequest(c, &rbuf);
    const r: *const abi.RequestEvent = @ptrCast(@alignCast(rec.ptr));
    try std.testing.expectEqual(@as(u32, 1), r.route_id);
    try std.testing.expectEqualStrings("/hi", span(rec, r.path));
    try std.testing.expectEqualStrings("lambda", span(rec, r.listener));
    try std.testing.expectEqualStrings("203.0.113.9:0", span(rec, r.remote_addr));
    try std.testing.expect(recHeader(rec, r, "x-amzn-request-context") != null);
    try std.testing.expect(recHeader(rec, r, "x-amzn-lambda-context") != null);
    try engine.respond(e, r.ev.handle, 200, &.{.{ .name = .of("content-type"), .value = .of("text/plain") }}, "hi from C", false);
    try waitPosts(&f, 2);
    var saw_hi = false;
    var saw_fixed = false;
    for (0..f.postCount()) |i| {
        const p = f.post(i);
        if (std.mem.indexOf(u8, p.path, "r-hi/response") != null) saw_hi = std.mem.indexOf(u8, p.body, "hi from C") != null;
        if (std.mem.indexOf(u8, p.path, "r-fixed/response") != null) saw_fixed = std.mem.indexOf(u8, p.body, "\"body\":\"ok\"") != null;
    }
    try std.testing.expect(saw_hi and saw_fixed);
    // The listener in the configuration is set aside: it reports port 0.
    try std.testing.expectEqual(@as(u16, 0), e.listeners[0].port);
    try e.drain();
    try std.testing.expect(e.wait(@intCast(wait.deadlineMs())));
}

test "capi lambda: timeout_us follows the invocation's deadline, not the longer route timeout" {
    if (comptime !features.lambda) return error.SkipZigTest;
    var f: fake_rt.Fake = undefined;
    const now_ms: i64 = @intCast(@divTrunc(std.Io.Clock.real.now(std.testing.io).nanoseconds, std.time.ns_per_ms));
    try f.start(&.{.{ .request_id = "r-t", .event = httpApiEvent("/hi"), .deadline_ms = now_ms + 60_000 }});
    defer f.stop();
    const e, const c = try lambdaEngine(&f,
        \\[{{"path":"/hi","handler":1,"timeout_ms":120000}}]
    );
    defer e.destroy();
    var rbuf: [64 * 1024]u8 align(8) = undefined;
    const rec = try nextRequest(c, &rbuf);
    const r: *const abi.RequestEvent = @ptrCast(@alignCast(rec.ptr));
    try std.testing.expect(r.timeout_us > 0 and r.timeout_us < 60_000_000);
    try engine.respond(e, r.ev.handle, 204, &.{}, "", false);
    try waitPosts(&f, 1);
    try e.drain();
    try std.testing.expect(e.wait(@intCast(wait.deadlineMs())));
}

test "capi lambda: anole_server_drain during a held /next ends with ANOLE_EV_STOPPED" {
    if (comptime !features.lambda) return error.SkipZigTest;
    var f: fake_rt.Fake = undefined;
    try f.start(&.{});
    defer f.stop();
    const e, const c = try lambdaEngine(&f,
        \\[{{"path":"/hi","handler":1}}]
    );
    defer e.destroy();
    try waitPosts(&f, 0);
    try e.drain();
    var buf: [16 * 1024]u8 align(8) = undefined;
    var need: u32 = 0;
    var stopped = false;
    var waited: u32 = 0;
    while (!stopped and waited < 10_000) : (waited += 50) {
        const n = try engine.pollWait(c, &buf, 50, &need);
        var off: usize = 0;
        while (off < n) {
            const ev: *const abi.Event = @ptrCast(@alignCast(&buf[off]));
            if (ev.type == @backingInt(abi.EventType.stopped)) stopped = true;
            off += ev.len;
        }
    }
    try std.testing.expect(stopped);
    try std.testing.expect(e.wait(@intCast(wait.deadlineMs())));
}
