//! End-to-end tests of `deployment = lambda` against a fake Lambda Runtime
//! API (design-lambda §12.3). The fake is the HTTP core's own server on
//! `std.testing.io`, beside the app's runtime: it hands out scripted
//! invocations on `GET /next`, records every post, and holds `/next` once
//! the script is over (as Lambda holds it until there is work). The tests
//! wait for "N posts recorded"; nothing waits on a time window.
//!
//! `Fake` is public: the C ABI's lambda tests use it too.

const std = @import("std");
const dusty = @import("dusty");
const anole = @import("../root.zig");
const lambda = @import("root.zig");
const serve_mod = @import("serve.zig");

const gpa = std.testing.allocator;
const tio = std.testing.io;

const loopback: []const dusty.Listener = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }};

pub const Invocation = struct {
    request_id: []const u8,
    event: []const u8,
    /// Unix ms; null: now + 60 s.
    deadline_ms: ?i64 = null,
    trace_id: []const u8 = "",
    invocation_id: []const u8 = "",
};

pub const Post = struct {
    path: []u8,
    body: []u8,
    content_type: []u8,
    error_type: []u8,
    mode: []u8,
    invocation_id: []u8,
};

/// The fake Runtime API.
pub const Fake = struct {
    script: []const Invocation = &.{},
    index: usize = 0,
    posts: std.ArrayList(Post) = .empty,
    lock_flag: std.atomic.Value(bool) = .init(false),
    /// The script is over and a `/next` is held.
    drained: std.atomic.Value(bool) = .init(false),
    registered: std.atomic.Value(bool) = .init(false),
    /// What `/response` posts are answered with.
    response_status: dusty.Status = .accepted,
    /// Never set: held requests wait on it until the fake stops.
    hold: std.Io.Event = .unset,
    server: dusty.Server(Fake) = undefined,
    future: std.Io.Future(anyerror!void) = undefined,
    addr_buf: [32]u8 = undefined,

    fn lock(f: *Fake) void {
        while (f.lock_flag.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(f: *Fake) void {
        f.lock_flag.store(false, .release);
    }

    /// Starts serving on 127.0.0.1 (a free port). `f` must not move.
    pub fn start(f: *Fake, script: []const Invocation) !void {
        f.* = .{ .script = script };
        f.server = dusty.Server(Fake).init(gpa, tio, .{
            .listeners = loopback,
            // One request per connection: the core's keep-alive wait needs a zio
            // task, and this server runs on std.testing.io.
            .timeout = .{ .shutdown = .fromMilliseconds(200), .request = null, .read_header = null, .keepalive = null, .idle_park = null, .request_count = 1 },
            .request = .{ .max_body_size = 16 << 20, .max_content_length = 16 << 20 },
        }, f);
        const r = &f.server.router;
        r.get("/2018-06-01/runtime/invocation/next", next);
        r.post("/2018-06-01/runtime/invocation/:id/:what", record);
        r.post("/2018-06-01/runtime/init/error", record);
        r.post("/2020-01-01/extension/register", register);
        r.get("/2020-01-01/extension/event/next", holdRequest);
        f.future = try tio.concurrent(runServer, .{&f.server});
        f.server.waitReady(tio) catch |err| {
            f.future.cancel(tio) catch {};
            return err;
        };
    }

    fn runServer(s: *dusty.Server(Fake)) anyerror!void {
        try s.run();
    }

    /// "127.0.0.1:<port>"
    pub fn api(f: *Fake) []const u8 {
        return std.fmt.bufPrint(&f.addr_buf, "127.0.0.1:{d}", .{f.server.address.ip.getPort()}) catch unreachable;
    }

    pub fn stop(f: *Fake) void {
        // Release held `/next` and extension requests first: the server's
        // shutdown then has nothing to wait out.
        f.hold.set(tio);
        f.future.cancel(tio) catch {};
        f.server.deinit();
        for (f.posts.items) |p| {
            inline for (.{ "path", "body", "content_type", "error_type", "mode", "invocation_id" }) |name| gpa.free(@field(p, name));
        }
        f.posts.deinit(gpa);
    }

    pub fn postCount(f: *Fake) usize {
        f.lock();
        defer f.unlock();
        return f.posts.items.len;
    }

    /// Post `i` (copied out under the lock; the slices stay valid until `stop`).
    pub fn post(f: *Fake, i: usize) Post {
        f.lock();
        defer f.unlock();
        return f.posts.items[i];
    }

    fn next(f: *Fake, req: *dusty.Request, res: *dusty.Response) !void {
        f.lock();
        if (f.index < f.script.len) {
            const inv = f.script[f.index];
            f.index += 1;
            f.unlock();
            const now_ms: i64 = @intCast(@divTrunc(std.Io.Clock.real.now(req.io).nanoseconds, std.time.ns_per_ms));
            try res.header("Lambda-Runtime-Aws-Request-Id", inv.request_id);
            try res.header("Lambda-Runtime-Deadline-Ms", try std.fmt.allocPrint(req.arena, "{d}", .{inv.deadline_ms orelse now_ms + 60_000}));
            try res.header("Lambda-Runtime-Invoked-Function-Arn", "arn:aws:lambda:us-east-1:123456789012:function:test");
            if (inv.trace_id.len > 0) try res.header("Lambda-Runtime-Trace-Id", inv.trace_id);
            if (inv.invocation_id.len > 0) try res.header("Lambda-Runtime-Invocation-Id", inv.invocation_id);
            try res.header("Content-Type", "application/json");
            res.body = inv.event;
            return;
        }
        f.drained.store(true, .release);
        f.unlock();
        try f.hold.wait(req.io);
    }

    fn holdRequest(f: *Fake, req: *dusty.Request, _: *dusty.Response) !void {
        try f.hold.wait(req.io);
    }

    fn register(f: *Fake, req: *dusty.Request, res: *dusty.Response) !void {
        // Read: an unread body is discarded under a deadline, which needs
        // a zio task (this server runs on std.testing.io).
        _ = try req.body();
        f.registered.store(true, .release);
        try res.header("Lambda-Extension-Identifier", "ext-1");
        res.body = "{}";
    }

    fn record(f: *Fake, req: *dusty.Request, res: *dusty.Response) !void {
        const body = (try req.body()) orelse "";
        const h = &req.headers;
        const p: Post = .{
            .path = try gpa.dupe(u8, req.url),
            .body = try gpa.dupe(u8, body),
            .content_type = try gpa.dupe(u8, h.get("Content-Type") orelse ""),
            .error_type = try gpa.dupe(u8, h.get("Lambda-Runtime-Function-Error-Type") orelse ""),
            .mode = try gpa.dupe(u8, h.get("Lambda-Runtime-Function-Response-Mode") orelse ""),
            .invocation_id = try gpa.dupe(u8, h.get("Lambda-Runtime-Invocation-Id") orelse ""),
        };
        f.lock();
        f.posts.append(gpa, p) catch {};
        const status = if (std.mem.endsWith(u8, req.url, "/response")) f.response_status else .accepted;
        f.unlock();
        res.status = status;
        res.body = "{}";
    }
};

/// Stops `app` once `n` posts are recorded and the script is over (or
/// past the wait helper's deadline, failing the test then).
fn stopAfter(app: *anole.App, f: *Fake, n: usize) anyerror!void {
    defer app.stop();
    const Ctx = struct { f: *Fake, n: usize };
    try @import("anole_test_wait").waitUntil(app.io(), "the Runtime API got the posts and was drained", Ctx{ .f = f, .n = n }, struct {
        fn done(c: Ctx) bool {
            return c.f.postCount() >= c.n and c.f.drained.load(.acquire);
        }
    }.done);
}

/// Runs `app` against `f` until `n` posts are recorded.
fn serveUntil(app: *anole.App, f: *Fake, n: usize) !void {
    var stopper = try app.io().concurrent(stopAfter, .{ app, f, n });
    app.run() catch |err| {
        stopper.cancel(app.io()) catch {};
        return err;
    };
    try stopper.await(app.io());
}

fn lambdaApp(f: *Fake, extra: anole.ServerOptions.Lambda) !anole.App {
    var o = extra;
    o.runtime_api = f.api();
    return anole.App.init(gpa, .{ .deployment = .lambda, .executors = .exact(1), .lambda = o });
}

fn has(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

const http_api_get =
    \\{"version":"2.0","routeKey":"$default","rawPath":"/hello","rawQueryString":"a=1",
    \\ "headers":{"host":"api.example.com","accept":"application/json"},
    \\ "requestContext":{"domainName":"api.example.com","http":{"method":"GET","path":"/hello","protocol":"HTTP/1.1","sourceIp":"203.0.113.9","userAgent":"curl"},
    \\  "requestId":"r1","stage":"$default"},"isBase64Encoded":false}
;

const function_url_get =
    \\{"version":"2.0","routeKey":"$default","rawPath":"/hello","rawQueryString":"",
    \\ "headers":{"host":"abc.lambda-url.us-east-1.on.aws"},
    \\ "requestContext":{"domainName":"abc.lambda-url.us-east-1.on.aws","http":{"method":"GET","path":"/hello","protocol":"HTTP/1.1","sourceIp":"203.0.113.9","userAgent":"curl"},
    \\  "requestId":"r1"},"isBase64Encoded":false}
;

const sqs_event =
    \\{"Records":[{"messageId":"m1","body":"hi","eventSource":"aws:sqs"}]}
;

fn hello(_: *anole.Request, res: *anole.Response) !void {
    try res.addHeader("Set-Cookie", "a=1");
    try res.addHeader("Set-Cookie", "b=2");
    try res.json(.{ .hello = "world" });
}

test "lambda: buffered round trip (HTTP API)" {
    var f: Fake = undefined;
    try f.start(&.{.{ .request_id = "req-1", .event = http_api_get, .invocation_id = "inv-1" }});
    defer f.stop();
    var app = try lambdaApp(&f, .{ .sigterm = false });
    defer app.deinit();
    app.get("/hello", hello);
    try serveUntil(&app, &f, 1);
    const p = f.post(0);
    try std.testing.expectEqualStrings("/2018-06-01/runtime/invocation/req-1/response", p.path);
    try std.testing.expectEqualStrings("application/json", p.content_type);
    try std.testing.expectEqualStrings("inv-1", p.invocation_id);
    try std.testing.expect(has(p.body, "\"statusCode\":200"));
    try std.testing.expect(has(p.body, "\"cookies\":[\"a=1\",\"b=2\"]"));
    try std.testing.expect(has(p.body, "{\\\"hello\\\":\\\"world\\\"}"));
    // Nothing was bound.
    try std.testing.expectEqual(@as(usize, 0), app.addresses().len);
}

const Seen = struct {
    var id_buf: [64]u8 = undefined;
    var id_len: usize = 0;
    var arn_ok = false;
    var secure = false;
    var context_header = false;
    var traceparent_buf: [64]u8 = undefined;
    var traceparent_len: usize = 0;
    var remote_ok = false;

    fn handle(req: *anole.Request, res: *anole.Response) !void {
        id_len = req.id.len;
        @memcpy(id_buf[0..req.id.len], req.id);
        if (lambda.context(req)) |c| arn_ok = std.mem.endsWith(u8, c.function_arn, ":function:test");
        secure = req.secure;
        context_header = req.headers.get("x-amzn-lambda-context") != null and req.headers.get("x-amzn-request-context") != null;
        if (req.headers.get("traceparent")) |t| {
            traceparent_len = @min(t.len, traceparent_buf.len);
            @memcpy(traceparent_buf[0..traceparent_len], t[0..traceparent_len]);
        }
        remote_ok = switch (req.remote_address) {
            .ip4 => |a| std.mem.eql(u8, &a.bytes, &.{ 203, 0, 113, 9 }),
            else => false,
        };
        res.body = "ok";
    }
};

test "lambda: request sees Lambda's context" {
    var f: Fake = undefined;
    try f.start(&.{.{ .request_id = "req-ctx", .event = http_api_get, .trace_id = "Root=1-5759e988-bd862e3fe1be46a994272793;Parent=53995c3f42cd8ad8;Sampled=1" }});
    defer f.stop();
    var app = try lambdaApp(&f, .{ .sigterm = false });
    defer app.deinit();
    app.get("/hello", Seen.handle);
    try serveUntil(&app, &f, 1);
    try std.testing.expectEqualStrings("req-ctx", Seen.id_buf[0..Seen.id_len]);
    try std.testing.expect(Seen.arn_ok);
    try std.testing.expect(Seen.secure);
    try std.testing.expect(Seen.context_header);
    try std.testing.expect(Seen.remote_ok);
    try std.testing.expectEqualStrings("00-5759e988bd862e3fe1be46a994272793-53995c3f42cd8ad8-01", Seen.traceparent_buf[0..Seen.traceparent_len]);
}

fn onQueue(_: *anole.Request, res: *anole.Response) !void {
    res.content_type = .json;
    res.body = "{\"batchItemFailures\":[]}";
}

fn onQueueFails(_: *anole.Request, res: *anole.Response) !void {
    res.status = .internal_server_error;
    res.body = "queue broke";
}

test "lambda: non-HTTP events go to the event path; a non-2xx answer fails the invocation" {
    var f: Fake = undefined;
    try f.start(&.{.{ .request_id = "sqs-1", .event = sqs_event }});
    defer f.stop();
    {
        var app = try lambdaApp(&f, .{ .sigterm = false });
        defer app.deinit();
        app.post(lambda.default_event_path, onQueue);
        try serveUntil(&app, &f, 1);
    }
    const p = f.post(0);
    try std.testing.expectEqualStrings("/2018-06-01/runtime/invocation/sqs-1/response", p.path);
    try std.testing.expectEqualStrings("{\"batchItemFailures\":[]}", p.body);

    var g: Fake = undefined;
    try g.start(&.{.{ .request_id = "sqs-2", .event = sqs_event }});
    defer g.stop();
    {
        var app = try lambdaApp(&g, .{ .sigterm = false });
        defer app.deinit();
        app.post(lambda.default_event_path, onQueueFails);
        try serveUntil(&app, &g, 1);
    }
    const q = g.post(0);
    try std.testing.expectEqualStrings("/2018-06-01/runtime/invocation/sqs-2/error", q.path);
    try std.testing.expectEqualStrings("Function.Status500", q.error_type);
    try std.testing.expect(has(q.body, "queue broke"));
}

test "lambda: with event_path null nothing is reserved and non-HTTP events are refused; an unreadable event" {
    var f: Fake = undefined;
    const reserved =
        \\{"version":"2.0","rawPath":"/_lambda/event","rawQueryString":"","headers":{"host":"h"},
        \\ "requestContext":{"domainName":"h","http":{"method":"POST","path":"/_lambda/event","sourceIp":"203.0.113.9"},"stage":"$default"},"isBase64Encoded":false}
    ;
    try f.start(&.{
        .{ .request_id = "r-reserved", .event = reserved },
        .{ .request_id = "r-sqs", .event = sqs_event },
        .{ .request_id = "r-bad", .event = "not json" },
    });
    defer f.stop();
    var app = try lambdaApp(&f, .{ .sigterm = false, .event_path = null });
    defer app.deinit();
    app.post("/_lambda/event", onQueue);
    try serveUntil(&app, &f, 3);
    // No event path: a web request to that path is an ordinary request.
    try std.testing.expect(has(f.post(0).body, "\"statusCode\":200"));
    try std.testing.expectEqualStrings("Runtime.UnsupportedEvent", f.post(1).error_type);
    try std.testing.expectEqualStrings("Runtime.InvalidEvent", f.post(2).error_type);
}

test "lambda: streaming Function URL" {
    var f: Fake = undefined;
    try f.start(&.{.{ .request_id = "stream-1", .event = function_url_get }});
    defer f.stop();
    var app = try lambdaApp(&f, .{ .sigterm = false, .invoke_mode = .response_stream });
    defer app.deinit();
    app.get("/hello", struct {
        fn h(_: *anole.Request, res: *anole.Response) !void {
            res.content_type = .text;
            res.body = "streamed";
        }
    }.h);
    try serveUntil(&app, &f, 1);
    const p = f.post(0);
    try std.testing.expectEqualStrings("streaming", p.mode);
    try std.testing.expectEqualStrings("application/vnd.awslambda.http-integration-response", p.content_type);
    const delim = std.mem.indexOf(u8, p.body, &lambda.encode.delimiter) orelse return error.TestUnexpectedResult;
    try std.testing.expect(has(p.body[0..delim], "\"statusCode\":200"));
    try std.testing.expectEqualStrings("streamed", p.body[delim + 8 ..]);
}

test "lambda: init errors go to /runtime/init/error" {
    var f: Fake = undefined;
    try f.start(&.{});
    defer f.stop();
    var app = try lambdaApp(&f, .{ .sigterm = false });
    defer app.deinit();
    app.router.record_conflicts = true;
    app.get("/x/:a", hello);
    app.get("/x/:b", hello);
    try std.testing.expectError(error.RouteConflict, app.run());
    try std.testing.expectEqual(@as(usize, 1), f.postCount());
    try std.testing.expectEqualStrings("/2018-06-01/runtime/init/error", f.post(0).path);
    try std.testing.expectEqualStrings("Function.RouteConflict", f.post(0).error_type);
}

test "lambda: SnapStart is refused at init" {
    var f: Fake = undefined;
    try f.start(&.{});
    defer f.stop();
    serve_mod._test_initialization_type = "snap-start";
    defer serve_mod._test_initialization_type = null;
    var app = try lambdaApp(&f, .{ .sigterm = false });
    defer app.deinit();
    try std.testing.expectError(error.SnapStartUnsupported, app.run());
    try std.testing.expectEqualStrings("Function.SnapStartUnsupported", f.post(0).error_type);
}

test "lambda: a Runtime API 500 ends run" {
    var f: Fake = undefined;
    try f.start(&.{.{ .request_id = "r-500", .event = http_api_get }});
    defer f.stop();
    f.response_status = .internal_server_error;
    var app = try lambdaApp(&f, .{ .sigterm = false });
    defer app.deinit();
    app.get("/hello", hello);
    try std.testing.expectError(error.LambdaRuntimeApiFailed, app.run());
}

test "lambda: SIGTERM extension is registered before the first /next" {
    var f: Fake = undefined;
    try f.start(&.{.{ .request_id = "r-ext", .event = http_api_get }});
    defer f.stop();
    var app = try lambdaApp(&f, .{ .sigterm = true });
    defer app.deinit();
    app.get("/hello", hello);
    try serveUntil(&app, &f, 1);
    try std.testing.expect(f.registered.load(.acquire));
}

test "lambda: listen() is set aside, and idle connections close after a long gap" {
    var f: Fake = undefined;
    try f.start(&.{
        .{ .request_id = "r-1", .event = http_api_get },
        .{ .request_id = "r-2", .event = http_api_get },
    });
    defer f.stop();
    serve_mod._test_close_idle_count.store(0, .monotonic);
    serve_mod._test_clock_offset_ms.store(301_000, .monotonic);
    defer serve_mod._test_clock_offset_ms.store(0, .monotonic);
    var app = try lambdaApp(&f, .{ .sigterm = false });
    defer app.deinit();
    app.get("/hello", hello);
    var stopper = try app.io().concurrent(stopAfter, .{ &app, &f, 2 });
    try app.listen(":0");
    try stopper.await(app.io());
    try std.testing.expectEqual(@as(usize, 0), app.addresses().len);
    try std.testing.expectEqual(@as(u32, 1), serve_mod._test_close_idle_count.load(.monotonic));
    // The startup line names it (modes.writeSetAside); the test runner's
    // log does not go through anole's sink, so the record is checked.
    try std.testing.expectEqualStrings(":0", app.mode.set_aside.listen.?);
}

test "lambda: under lambda, jobs only enqueue (R14 lines)" {
    if (comptime !anole.features.jobs) return error.SkipZigTest;
    var f: Fake = undefined;
    try f.start(&.{.{ .request_id = "r-jobs", .event = http_api_get }});
    defer f.stop();
    var app = try lambdaApp(&f, .{ .sigterm = false });
    defer app.deinit();
    app.get("/hello", hello);
    const j = try app.jobs(.{ .store = .memory });
    try serveUntil(&app, &f, 1);
    try std.testing.expect(j.suppress_workers);
}

test "lambda: the event path is reserved for events" {
    var f: Fake = undefined;
    const web_to_event_path =
        \\{"version":"2.0","rawPath":"/_lambda/event","rawQueryString":"","headers":{"host":"h"},
        \\ "requestContext":{"domainName":"h","http":{"method":"POST","path":"/_lambda/event","sourceIp":"203.0.113.9"},"stage":"$default"},"isBase64Encoded":false}
    ;
    try f.start(&.{.{ .request_id = "r-reserved", .event = web_to_event_path }});
    defer f.stop();
    var app = try lambdaApp(&f, .{ .sigterm = false });
    defer app.deinit();
    app.post(lambda.default_event_path, onQueue);
    try serveUntil(&app, &f, 1);
    try std.testing.expect(has(f.post(0).body, "\"statusCode\":404"));
}

test "lambda: a watch is not started under lambda; invocations are served" {
    if (comptime !anole.features.redis) return error.SkipZigTest;
    var f: Fake = undefined;
    try f.start(&.{.{ .request_id = "r-watch", .event = http_api_get }});
    defer f.stop();
    var app = try lambdaApp(&f, .{ .sigterm = false });
    defer app.deinit();
    app.get("/hello", hello);
    // Nothing listens on port 1: a started watch would keep reconnecting.
    const rc = try app.redis(.{ .url = "redis://127.0.0.1:1", .environ = .empty });
    const w = try app.watch(.{ .redis = .{ .client = rc, .channels = &.{"orders"} } }, .{});
    try serveUntil(&app, &f, 1);
    try std.testing.expect(w.disabled and !w.started);
    try std.testing.expect(has(f.post(0).body, "\"statusCode\":200"));
}
