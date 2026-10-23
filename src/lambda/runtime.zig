//! The Lambda Runtime API client: the next invocation, its answer or error,
//! init errors, and the no-op extension that makes Lambda send SIGTERM. It
//! speaks through the core `http.Client` (a private instance: no timeout on
//! `/next`, a 16 MiB response cap, no private-address ban), so it works on
//! zio and over the plain-HTTP socket Lambda and the Runtime Interface
//! Emulator provide.
//!
//! API: https://docs.aws.amazon.com/lambda/latest/dg/runtimes-api.html

const std = @import("std");
const dusty = @import("dusty");
const build_options = @import("build_options");

const log = std.log.scoped(.anole);

pub const Invocation = struct {
    request_id: []const u8,
    /// Lambda-Runtime-Invocation-Id; empty when Lambda sent none.
    invocation_id: []const u8,
    /// Unix milliseconds.
    deadline_ms: i64,
    function_arn: []const u8,
    trace_id: []const u8,
    client_context: []const u8,
    cognito_identity: []const u8,
    event: []const u8,
};

pub const NextError = error{ Canceled, RuntimeApiFailed, OutOfMemory };
pub const PostError = error{ Canceled, RuntimeApiFailed, InvalidInvocationId, PayloadTooLarge, OutOfMemory };

/// Posts wait this long for the Runtime API's answer.
const post_timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } };

/// Lambda's default when no deadline header is sent or it is unreadable.
const default_deadline_ms: i64 = 15 * 60 * 1000;

pub const Runtime = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    client: dusty.Client,
    /// "http://<api>/2018-06-01"
    base: []const u8,
    /// "http://<api>/2020-01-01/extension"
    ext_base: []const u8,

    /// `api` is "host:port" (AWS_LAMBDA_RUNTIME_API).
    pub fn init(gpa: std.mem.Allocator, io: std.Io, api: []const u8) !Runtime {
        const base = try std.fmt.allocPrint(gpa, "http://{s}/2018-06-01", .{api});
        errdefer gpa.free(base);
        const ext_base = try std.fmt.allocPrint(gpa, "http://{s}/2020-01-01/extension", .{api});
        errdefer gpa.free(ext_base);
        return .{
            .gpa = gpa,
            .io = io,
            .client = dusty.Client.init(gpa, io, .{
                .timeout = null,
                .max_response_size = 16 << 20,
                .max_idle_per_host = 4,
                .idle_timeout = null,
                .max_redirects = 0,
                .user_agent = "anole/" ++ build_options.version ++ " lambda",
                .http2 = false,
            }),
            .base = base,
            .ext_base = ext_base,
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.client.deinit();
        self.gpa.free(self.base);
        self.gpa.free(self.ext_base);
    }

    /// GET /runtime/invocation/next, with no timeout (Lambda holds the
    /// request until an invocation exists, or the environment freezes).
    /// Header slices and the event are copied into `arena`.
    pub fn next(self: *Runtime, arena: std.mem.Allocator) NextError!Invocation {
        const url = try std.fmt.allocPrint(arena, "{s}/runtime/invocation/next", .{self.base});
        var response = self.client.fetch(url, .{ .timeout = .none, .decompress = false }) catch |err| return nextError(err);
        defer response.deinit();
        if (response.status() != .ok) {
            log.warn("lambda: the Runtime API answered {d} to /next", .{@intFromEnum(response.status())});
            return error.RuntimeApiFailed;
        }
        const h = response.headers();
        const request_id = h.get("Lambda-Runtime-Aws-Request-Id") orelse return error.RuntimeApiFailed;
        const body = (response.body() catch |err| return nextError(err)) orelse "";
        return .{
            .request_id = try arena.dupe(u8, request_id),
            .invocation_id = try arena.dupe(u8, h.get("Lambda-Runtime-Invocation-Id") orelse ""),
            .deadline_ms = if (h.get("Lambda-Runtime-Deadline-Ms")) |v|
                std.fmt.parseInt(i64, std.mem.trim(u8, v, " "), 10) catch self.nowMs() + default_deadline_ms
            else
                self.nowMs() + default_deadline_ms,
            .function_arn = try arena.dupe(u8, h.get("Lambda-Runtime-Invoked-Function-Arn") orelse ""),
            .trace_id = try arena.dupe(u8, h.get("Lambda-Runtime-Trace-Id") orelse ""),
            .client_context = try arena.dupe(u8, h.get("Lambda-Runtime-Client-Context") orelse ""),
            .cognito_identity = try arena.dupe(u8, h.get("Lambda-Runtime-Cognito-Identity") orelse ""),
            .event = try arena.dupe(u8, body),
        };
    }

    /// POST /runtime/invocation/{id}/response, Content-Type
    /// application/json, echoing Lambda-Runtime-Invocation-Id when set.
    pub fn respond(self: *Runtime, inv: *const Invocation, body: []const u8) PostError!void {
        var url_buf: [256]u8 = undefined;
        const url = try self.invocationUrl(&url_buf, inv, "response");
        var storage: [512]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&storage);
        var headers = try dusty.Headers.init(fba.allocator(), 2);
        try headers.put("Content-Type", "application/json");
        if (inv.invocation_id.len > 0) try headers.put("Lambda-Runtime-Invocation-Id", inv.invocation_id);
        return self.post(url, &headers, body);
    }

    /// The same as a stream, for a streamed answer: the head carries
    /// `Lambda-Runtime-Function-Response-Mode: streaming`, the body is
    /// chunked, and `Lambda-Runtime-Function-Error-Type` /
    /// `Lambda-Runtime-Function-Error-Body` may come as trailers.
    /// `content_type` is `application/vnd.awslambda.http-integration-response`
    /// for HTTP events. End it with `finishStream`.
    pub fn respondStream(self: *Runtime, inv: *const Invocation, content_type: []const u8) PostError!dusty.Upload {
        var url_buf: [256]u8 = undefined;
        const url = try self.invocationUrl(&url_buf, inv, "response");
        var storage: [768]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&storage);
        var headers = try dusty.Headers.init(fba.allocator(), 4);
        try headers.put("Content-Type", content_type);
        try headers.put("Lambda-Runtime-Function-Response-Mode", "streaming");
        if (inv.invocation_id.len > 0) try headers.put("Lambda-Runtime-Invocation-Id", inv.invocation_id);
        return self.client.upload(url, .{
            .headers = &headers,
            .trailer_names = &.{ "Lambda-Runtime-Function-Error-Type", "Lambda-Runtime-Function-Error-Body" },
            .timeout = post_timeout,
        }) catch |err| return postError(err);
    }

    /// Ends a streamed answer (`trailers`: see `errorTrailers`) and reads
    /// the Runtime API's verdict.
    pub fn finishStream(self: *Runtime, up: *dusty.Upload, trailers: ?*const dusty.Headers) PostError!void {
        _ = self;
        var response = up.finish(trailers) catch |err| return postError(err);
        defer response.deinit();
        return statusResult(response.status());
    }

    /// The trailers that report a failure after the head of a streamed
    /// answer went out: the error type and the base64 of `message`.
    pub fn errorTrailers(arena: std.mem.Allocator, error_type: []const u8, message: []const u8) !dusty.Headers {
        var trailers = try dusty.Headers.init(arena, 2);
        try trailers.put("Lambda-Runtime-Function-Error-Type", error_type);
        const encoded = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(message.len));
        _ = std.base64.standard.Encoder.encode(encoded, message);
        try trailers.put("Lambda-Runtime-Function-Error-Body", encoded);
        return trailers;
    }

    /// POST /runtime/invocation/{id}/error.
    pub fn fail(self: *Runtime, inv: *const Invocation, error_type: []const u8, message: []const u8) PostError!void {
        var url_buf: [256]u8 = undefined;
        const url = try self.invocationUrl(&url_buf, inv, "error");
        return self.postJsonError(url, inv.invocation_id, error_type, message);
    }

    /// POST /runtime/init/error.
    pub fn initError(self: *Runtime, error_type: []const u8, message: []const u8) PostError!void {
        const url = try std.fmt.allocPrint(self.gpa, "{s}/runtime/init/error", .{self.base});
        defer self.gpa.free(url);
        return self.postJsonError(url, "", error_type, message);
    }

    /// POST /extension/register {"events":[]} as "anole-sigterm"; the
    /// identifier for `holdExtension`, copied into `arena`.
    pub fn registerExtension(self: *Runtime, arena: std.mem.Allocator) PostError![]const u8 {
        const url = try std.fmt.allocPrint(arena, "{s}/register", .{self.ext_base});
        var storage: [256]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&storage);
        var headers = try dusty.Headers.init(fba.allocator(), 2);
        try headers.put("Lambda-Extension-Name", "anole-sigterm");
        try headers.put("Content-Type", "application/json");
        var response = self.client.fetch(url, .{ .method = .post, .headers = &headers, .body = "{\"events\":[]}", .timeout = post_timeout, .decompress = false }) catch |err| return postError(err);
        defer response.deinit();
        if (response.status() != .ok) return error.RuntimeApiFailed;
        const id = response.headers().get("Lambda-Extension-Identifier") orelse return error.RuntimeApiFailed;
        return arena.dupe(u8, id);
    }

    /// GET /extension/event/next, held until canceled (an extension with
    /// no events is never answered; Lambda sends SIGTERM at shutdown).
    pub fn holdExtension(self: *Runtime, id: []const u8) void {
        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/event/next", .{self.ext_base}) catch return;
        var storage: [256]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&storage);
        var headers = dusty.Headers.init(fba.allocator(), 1) catch return;
        headers.put("Lambda-Extension-Identifier", id) catch return;
        var response = self.client.fetch(url, .{ .headers = &headers, .timeout = .none, .decompress = false }) catch return;
        response.deinit();
    }

    fn nowMs(self: *const Runtime) i64 {
        return @intCast(@divTrunc(std.Io.Clock.real.now(self.io).nanoseconds, std.time.ns_per_ms));
    }

    fn invocationUrl(self: *Runtime, buf: []u8, inv: *const Invocation, what: []const u8) error{OutOfMemory}![]const u8 {
        return std.fmt.bufPrint(buf, "{s}/runtime/invocation/{s}/{s}", .{ self.base, inv.request_id, what }) catch error.OutOfMemory;
    }

    fn post(self: *Runtime, url: []const u8, headers: *const dusty.Headers, body: []const u8) PostError!void {
        var response = self.client.fetch(url, .{ .method = .post, .headers = headers, .body = body, .timeout = post_timeout, .decompress = false }) catch |err| return postError(err);
        defer response.deinit();
        return statusResult(response.status());
    }

    fn postJsonError(self: *Runtime, url: []const u8, invocation_id: []const u8, error_type: []const u8, message: []const u8) PostError!void {
        const body = try std.fmt.allocPrint(self.gpa, "{{\"errorMessage\":{f},\"errorType\":{f},\"stackTrace\":[]}}", .{ std.json.fmt(message, .{}), std.json.fmt(error_type, .{}) });
        defer self.gpa.free(body);
        var storage: [768]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&storage);
        var headers = try dusty.Headers.init(fba.allocator(), 3);
        try headers.put("Content-Type", "application/json");
        // Header values cannot carry control characters; the type is ours.
        try headers.put("Lambda-Runtime-Function-Error-Type", error_type);
        if (invocation_id.len > 0) try headers.put("Lambda-Runtime-Invocation-Id", invocation_id);
        return self.post(url, &headers, body);
    }
};

fn statusResult(status: dusty.Status) PostError!void {
    return switch (@intFromEnum(status)) {
        200...299 => {},
        400 => error.InvalidInvocationId,
        // The environment may not answer for this invocation (it timed
        // out already): logged, and serving carries on.
        403 => log.err("lambda: the Runtime API answered 403 Forbidden", .{}),
        413 => error.PayloadTooLarge,
        else => error.RuntimeApiFailed,
    };
}

fn nextError(err: anyerror) NextError {
    return switch (err) {
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
        else => blk: {
            log.warn("lambda: GET /next failed: {s}", .{@errorName(err)});
            break :blk error.RuntimeApiFailed;
        },
    };
}

fn postError(err: anyerror) PostError {
    return switch (err) {
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
        else => blk: {
            log.warn("lambda: a Runtime API request failed: {s}", .{@errorName(err)});
            break :blk error.RuntimeApiFailed;
        },
    };
}

// ---- tests ----

const testing = std.testing;

test "lambda runtime: error trailers carry the type and the base64 message" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const t = try Runtime.errorTrailers(arena_state.allocator(), "Function.Timeout", "deadline passed");
    try testing.expectEqualStrings("Function.Timeout", t.get("Lambda-Runtime-Function-Error-Type").?);
    try testing.expectEqualStrings("ZGVhZGxpbmUgcGFzc2Vk", t.get("Lambda-Runtime-Function-Error-Body").?);
}

test "lambda runtime: status mapping" {
    try statusResult(.accepted);
    try testing.expectError(error.InvalidInvocationId, statusResult(.bad_request));
    try testing.expectError(error.PayloadTooLarge, statusResult(.payload_too_large));
    try testing.expectError(error.RuntimeApiFailed, statusResult(.internal_server_error));
}
