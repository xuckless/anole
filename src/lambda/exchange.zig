//! One Lambda invocation through the router: the event becomes a request on
//! a sink-backed response (the seam HTTP/2, HTTP/3 and `anole.testing` use),
//! `Server.dispatch` runs it under the invocation's deadline, and the answer
//! goes back through the Runtime API, buffered or streamed.
//!
//! `answer` is the whole of it; the sinks and the pieces below are what its
//! tests exercise without a Runtime API.

const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");
const lambda = @import("root.zig");
const event = @import("event.zig");
const encode = @import("encode.zig");
const runtime = @import("runtime.zig");
const inmem = @import("../inmem.zig");

const log = std.log.scoped(.anole);

/// The function's own settings, read once at start (AWS_LAMBDA_FUNCTION_NAME
/// and the like); they appear in `x-amzn-lambda-context`.
pub const Env = struct {
    function_name: []const u8 = "",
    memory_mb: u32 = 0,
    version: []const u8 = "",
    log_stream: []const u8 = "",
    log_group: []const u8 = "",
};

pub const Config = struct {
    parse: event.ParseOptions = .{},
    /// Where events that are not HTTP requests go; null: they fail.
    event_path: ?[]const u8 = lambda.default_event_path,
    context_headers: bool = true,
    /// Answer Function URL and REST events as streams.
    stream: bool = false,
    /// `timeouts.request`: the most a request may take, if Lambda's
    /// deadline allows it.
    request_timeout: ?std.Io.Duration = null,
    /// Taken off the invocation's deadline.
    deadline_margin: std.Io.Duration = .fromMilliseconds(100),
    /// Run the `X-Forwarded-For` walk from the event's client address
    /// (`proxy.trusted` was set).
    trusted_proxies: bool = false,
    env: Env = .{},
};

pub const AnswerError = error{ Canceled, RuntimeApiFailed, OutOfMemory };

/// The listener every Runtime API request reports.
var lambda_listener: dusty.Listener = .{ .address = .{ .ip = .{ .ip4 = .unspecified(0) } }, .name = "lambda" };

const unspecified: std.Io.net.IpAddress = .{ .ip4 = .unspecified(0) };

// ------------------------------------------------------------------ sinks

/// A buffered answer: the head, the body in parts or pieces, up to a cap.
pub const BufferedSink = struct {
    arena: std.mem.Allocator,
    /// The most body bytes kept.
    limit: usize,
    status: dusty.Status = .ok,
    headers: ?*const dusty.Headers = null,
    seen_head: bool = false,
    finished: bool = false,
    too_large: bool = false,
    trailers_dropped: bool = false,
    /// From `complete`.
    parts: ?[]const []const u8 = null,
    /// From `body`.
    streamed: std.ArrayList(u8) = .empty,
    /// `result`'s one part when the body was streamed: the answer's
    /// `parts` points here, so it lives as long as the sink.
    streamed_part: [1][]const u8 = undefined,
    writer: std.Io.Writer,

    pub fn init(arena: std.mem.Allocator, limit: usize) BufferedSink {
        return .{ .arena = arena, .limit = limit, .writer = .{ .vtable = &writer_vtable, .buffer = &.{} } };
    }

    const writer_vtable: std.Io.Writer.VTable = .{ .drain = drainBody };

    fn drainBody(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *BufferedSink = @alignCast(@fieldParentPtr("writer", w));
        var total: usize = 0;
        for (data[0 .. data.len - 1]) |d| total += d.len;
        total += data[data.len - 1].len * splat;
        if (self.streamed.items.len + total > self.limit) {
            self.too_large = true;
            return error.WriteFailed;
        }
        for (data[0 .. data.len - 1]) |d| self.streamed.appendSlice(self.arena, d) catch return error.WriteFailed;
        const last = data[data.len - 1];
        for (0..splat) |_| self.streamed.appendSlice(self.arena, last) catch return error.WriteFailed;
        return total;
    }

    pub fn sink(self: *BufferedSink) dusty.Sink {
        return .{ .ptr = self, .vtable = &sink_vtable };
    }

    const sink_vtable: dusty.Sink.VTable = .{
        .head = headFn,
        .interim = interimFn,
        .body = bodyFn,
        .end = endFn,
        .writeError = writeErrorFn,
        .peerGone = peerGoneFn,
        .complete = completeFn,
    };

    fn headFn(ptr: *anyopaque, status: dusty.Status, headers: *const dusty.Headers, _: ?usize) std.Io.Writer.Error!void {
        const self: *BufferedSink = @ptrCast(@alignCast(ptr));
        self.status = status;
        self.headers = headers;
        self.seen_head = true;
    }

    fn interimFn(_: *anyopaque, _: dusty.Status) std.Io.Writer.Error!void {}

    fn bodyFn(ptr: *anyopaque) *std.Io.Writer {
        const self: *BufferedSink = @ptrCast(@alignCast(ptr));
        return &self.writer;
    }

    fn endFn(ptr: *anyopaque, trailers: ?*const dusty.Headers) std.Io.Writer.Error!void {
        const self: *BufferedSink = @ptrCast(@alignCast(ptr));
        if (trailers != null) self.trailers_dropped = true;
        self.finished = true;
    }

    fn writeErrorFn(_: *anyopaque) ?dusty.Response.SendError {
        return null;
    }

    fn peerGoneFn(_: *anyopaque) bool {
        return false;
    }

    fn completeFn(ptr: *anyopaque, status: dusty.Status, headers: *const dusty.Headers, _: ?usize, parts: []const []const u8, trailers: ?*const dusty.Headers) std.Io.Writer.Error!void {
        const self: *BufferedSink = @ptrCast(@alignCast(ptr));
        self.status = status;
        self.headers = headers;
        self.seen_head = true;
        self.finished = true;
        if (trailers != null) self.trailers_dropped = true;
        var total: usize = 0;
        for (parts) |p| total += p.len;
        if (total > self.limit) {
            self.too_large = true;
            return error.WriteFailed;
        }
        // The slice itself does not outlive the call.
        self.parts = self.arena.dupe([]const u8, parts) catch return error.WriteFailed;
    }

    /// What was written, ready to encode.
    pub fn result(self: *BufferedSink, head_only: bool) encode.Answer {
        const parts: []const []const u8 = if (self.parts) |p| p else blk: {
            self.streamed_part = .{self.streamed.items};
            break :blk &self.streamed_part;
        };
        return .{ .status = statusCode(self.status), .headers = self.headers.?, .parts = parts, .head = head_only };
    }

    /// Whether the handler wrote anything to the sink yet.
    pub fn touched(self: *const BufferedSink) bool {
        return self.seen_head;
    }
};

/// Headers for a text answer the adapter writes itself.
fn plainHeaders(arena: std.mem.Allocator) error{OutOfMemory}!dusty.Headers {
    var h = try dusty.Headers.init(arena, 2);
    h.put("Content-Type", "text/plain") catch return error.OutOfMemory;
    return h;
}

fn statusCode(status: dusty.Status) u16 {
    return @intCast(@backingInt(status));
}

/// A streamed answer over the Runtime API's streaming response: the prelude
/// and 8 NULs at the head, the body as chunks, the end as the last chunk.
pub const StreamSink = struct {
    rt: *runtime.Runtime,
    inv: *const runtime.Invocation,
    source: lambda.Source,
    upload: ?dusty.Upload = null,
    ended: bool = false,
    err: ?anyerror = null,

    pub fn sink(self: *StreamSink) dusty.Sink {
        return .{ .ptr = self, .vtable = &sink_vtable };
    }

    const sink_vtable: dusty.Sink.VTable = .{
        .head = headFn,
        .interim = interimFn,
        .body = bodyFn,
        .end = endFn,
        .writeError = writeErrorFn,
        .peerGone = peerGoneFn,
        .complete = completeFn,
    };

    fn open(self: *StreamSink, status: dusty.Status, headers: *const dusty.Headers) std.Io.Writer.Error!void {
        if (self.upload != null) return;
        var up = self.rt.respondStream(self.inv, "application/vnd.awslambda.http-integration-response") catch |e| {
            self.err = e;
            return error.WriteFailed;
        };
        errdefer up.abort();
        try encode.writePrelude(up.writer, self.source, statusCode(status), headers);
        try up.writer.writeAll(&encode.delimiter);
        self.upload = up;
    }

    fn headFn(ptr: *anyopaque, status: dusty.Status, headers: *const dusty.Headers, _: ?usize) std.Io.Writer.Error!void {
        const self: *StreamSink = @ptrCast(@alignCast(ptr));
        return self.open(status, headers);
    }

    fn interimFn(_: *anyopaque, _: dusty.Status) std.Io.Writer.Error!void {}

    fn bodyFn(ptr: *anyopaque) *std.Io.Writer {
        const self: *StreamSink = @ptrCast(@alignCast(ptr));
        return self.upload.?.writer;
    }

    fn finish(self: *StreamSink, trailers: ?*const dusty.Headers) std.Io.Writer.Error!void {
        if (self.ended) return;
        self.ended = true;
        var up = self.upload orelse return;
        self.rt.finishStream(&up, trailers) catch |e| {
            self.err = e;
            return error.WriteFailed;
        };
    }

    fn endFn(ptr: *anyopaque, trailers: ?*const dusty.Headers) std.Io.Writer.Error!void {
        const self: *StreamSink = @ptrCast(@alignCast(ptr));
        // Lambda carries two trailers of its own; the response's are not sent.
        if (trailers != null) log.debug("lambda: response trailers are not sent (Lambda answers carry none)", .{});
        return self.finish(null);
    }

    fn writeErrorFn(_: *anyopaque) ?dusty.Response.SendError {
        return null;
    }

    fn peerGoneFn(_: *anyopaque) bool {
        return false;
    }

    fn completeFn(ptr: *anyopaque, status: dusty.Status, headers: *const dusty.Headers, _: ?usize, parts: []const []const u8, trailers: ?*const dusty.Headers) std.Io.Writer.Error!void {
        const self: *StreamSink = @ptrCast(@alignCast(ptr));
        try self.open(status, headers);
        for (parts) |p| try self.upload.?.writer.writeAll(p);
        if (trailers != null) log.debug("lambda: response trailers are not sent (Lambda answers carry none)", .{});
        return self.finish(null);
    }

    /// Whether the head went out.
    pub fn touched(self: *const StreamSink) bool {
        return self.upload != null;
    }

    /// Ends an open stream with error trailers (the deadline passed, or the
    /// handler failed after the head).
    pub fn abortWith(self: *StreamSink, arena: std.mem.Allocator, error_type: []const u8, message: []const u8) void {
        if (self.ended or self.upload == null) return;
        self.ended = true;
        var up = self.upload.?;
        const trailers = runtime.Runtime.errorTrailers(arena, error_type, message) catch {
            up.abort();
            return;
        };
        self.rt.finishStream(&up, &trailers) catch {};
    }
};

// ------------------------------------------------------------------ the deadline

/// The invocation's timer: Lambda's deadline minus the margin is a ceiling
/// that `timeouts.request` and a handler's `Request.setTimeout` can move
/// down but never past.
const Timer = struct {
    auto: zio.AutoCancel = .init,
    limit: std.Io.Clock.Timestamp,

    fn arm(self: *Timer, io: std.Io, timeout: std.Io.Timeout) void {
        var d: std.Io.Timeout = .{ .deadline = self.limit };
        if (timeout.toDurationFromNow(io)) |dur| {
            const want = std.Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .raw = dur.raw, .clock = .awake });
            if (want.raw.nanoseconds < self.limit.raw.nanoseconds) d = .{ .deadline = want };
        }
        self.auto.setClock(.fromStd(d), .fromStdTimeout(d));
    }

    /// `Request._set_timeout`.
    fn set(context: *anyopaque, io: std.Io, timeout: std.Io.Timeout) void {
        const self: *Timer = @ptrCast(@alignCast(context));
        self.arm(io, timeout);
    }
};

fn realMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms));
}

// ------------------------------------------------------------------ headers the adapter adds

/// "Root=1-5759e988-bd862e3fe1be46a994272793;Parent=53995c3f42cd8ad8;Sampled=1"
/// as a W3C `traceparent` so the span tracer joins X-Ray's trace; null when
/// it does not parse.
pub fn traceparent(buf: *[55]u8, trace_id: []const u8) ?[]const u8 {
    var root: ?[]const u8 = null;
    var parent: ?[]const u8 = null;
    var sampled = false;
    var it = std.mem.splitScalar(u8, trace_id, ';');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " ");
        if (std.mem.startsWith(u8, t, "Root=")) root = t[5..];
        if (std.mem.startsWith(u8, t, "Parent=")) parent = t[7..];
        if (std.mem.eql(u8, t, "Sampled=1")) sampled = true;
    }
    const r = root orelse return null;
    const p = parent orelse return null;
    // 1-<8 hex>-<24 hex>
    if (r.len != 35 or r[0] != '1' or r[1] != '-' or r[10] != '-') return null;
    if (p.len != 16) return null;
    for (r[2..10]) |ch| if (!std.ascii.isHex(ch)) return null;
    for (r[11..35]) |ch| if (!std.ascii.isHex(ch)) return null;
    for (p) |ch| if (!std.ascii.isHex(ch)) return null;
    return std.fmt.bufPrint(buf, "00-{s}{s}-{s}-0{c}", .{ r[2..10], r[11..35], p, @as(u8, if (sampled) '1' else '0') }) catch null;
}

fn rawJsonOrNull(arena: std.mem.Allocator, w: *std.Io.Writer, text: []const u8) !void {
    if (text.len > 0) {
        const ok = std.json.validate(arena, text) catch false;
        if (ok) return w.writeAll(text);
    }
    try w.writeAll("null");
}

/// `x-amzn-lambda-context`: lambda_runtime's `Context` as Lambda Web
/// Adapter serializes it.
pub fn lambdaContextJson(arena: std.mem.Allocator, inv: *const runtime.Invocation, env: Env) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.print("{{\"request_id\":{f},\"deadline\":{d},\"invoked_function_arn\":{f},\"xray_trace_id\":", .{
        std.json.fmt(inv.request_id, .{}), inv.deadline_ms, std.json.fmt(inv.function_arn, .{}),
    });
    if (inv.trace_id.len > 0) try w.print("{f}", .{std.json.fmt(inv.trace_id, .{})}) else try w.writeAll("null");
    try w.writeAll(",\"client_context\":");
    try rawJsonOrNull(arena, w, inv.client_context);
    try w.writeAll(",\"identity\":");
    try rawJsonOrNull(arena, w, inv.cognito_identity);
    try w.print(",\"env_config\":{{\"function_name\":{f},\"memory\":{d},\"version\":{f},\"log_stream\":{f},\"log_group\":{f}}}}}", .{
        std.json.fmt(env.function_name, .{}), env.memory_mb,                    std.json.fmt(env.version, .{}),
        std.json.fmt(env.log_stream, .{}),    std.json.fmt(env.log_group, .{}),
    });
    return out.written();
}

fn parseMethod(name: []const u8) ?dusty.Method {
    var lower: [16]u8 = undefined;
    if (name.len == 0 or name.len > lower.len) return null;
    return std.meta.stringToEnum(dusty.Method, std.ascii.lowerString(&lower, name));
}

fn pathOf(target: []const u8) []const u8 {
    return target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
}

/// The keys of an event that could not be used, for the log: never values.
fn eventKeys(arena: std.mem.Allocator, bytes: []const u8) []const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch return "(not JSON)";
    if (parsed != .object) return "(not an object)";
    var out: std.Io.Writer.Allocating = .init(arena);
    var it = parsed.object.iterator();
    while (it.next()) |e| {
        if (out.written().len >= 200) break;
        if (out.written().len > 0) out.writer.writeByte(' ') catch break;
        out.writer.writeAll(e.key_ptr.*) catch break;
    }
    return out.written()[0..@min(out.written().len, 200)];
}

// ------------------------------------------------------------------ the exchange

/// Warned once per process: a response set several cookies for a front door
/// that takes one value per header.
var warned_cookies: std.atomic.Value(bool) = .init(false);

pub fn Exchange(comptime Ctx: type) type {
    return struct {
        const Run = struct {
            core: *dusty.Server(Ctx),
            exchange: inmem.Exchange(Ctx),
            limit: std.Io.Clock.Timestamp,
            request_timeout: ?std.Io.Duration,
            timed_out: bool = false,
            canceled: bool = false,
            /// An error after the head went out.
            failed: bool = false,

            fn task(self: *Run) void {
                const io = self.core.io;
                const req = &self.exchange.request;
                const res = &self.exchange.response;
                // A timer needs a zio task to cancel; off one (tests on
                // std.Io.Threaded) the request runs without a deadline.
                const timed = dusty.placement.currentTask(io) != null;
                var timer: Timer = .{ .limit = self.limit };
                defer if (timed) timer.auto.clear();
                // What the C ABI reports as the request's `timeout_us`: never
                // past Lambda's deadline minus the margin.
                req._handler_deadline = self.limit;
                if (timed) {
                    timer.arm(io, if (self.request_timeout) |d| .{ .duration = .{ .raw = d, .clock = .awake } } else .none);
                    req._timeout_context = &timer;
                    req._set_timeout = Timer.set;
                }
                self.core.dispatch(req, res) catch |err| return self.fail(err, timed, &timer);
                res.write() catch |err| return self.fail(err, timed, &timer);
            }

            fn fail(self: *Run, err: anyerror, timed: bool, timer: *Timer) void {
                const res = &self.exchange.response;
                if (err == error.Canceled) {
                    if (timed and timer.auto.check(error.Canceled)) self.timed_out = true else self.canceled = true;
                    return;
                }
                if (timed and timer.auto.check(error.Canceled)) {
                    self.timed_out = true;
                    return;
                }
                if (res.headersSent()) {
                    self.failed = true;
                    return;
                }
                // As the HTTP/2 engine answers an error out of dispatch.
                res.resetBody() catch {};
                res.status = .internal_server_error;
                res.content_type = .text;
                res.body = "500 Internal Server Error\n";
                res.write() catch {
                    self.failed = true;
                };
            }
        };

        /// What one request needs from the event.
        const Plan = struct {
            method: []const u8,
            target: []const u8,
            headers: []const event.Field,
            body: []const u8,
            client: ?std.Io.net.IpAddress,
            secure: bool,
            source: lambda.Source,
            multi_value: bool,
            stage: ?[]const u8,
            request_context: ?std.json.Value,
        };

        /// Answers invocation `inv`: parses its event, runs the request and
        /// posts the answer or the error. `Canceled` and `RuntimeApiFailed`
        /// are the only ways out; a bad event, a failing handler and a
        /// timeout are answers.
        pub fn answer(
            core: *dusty.Server(Ctx),
            rt: *runtime.Runtime,
            inv: *const runtime.Invocation,
            arena: std.mem.Allocator,
            cfg: *const Config,
        ) AnswerError!void {
            const in = event.parse(arena, inv.event, cfg.parse) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidEvent => {
                    log.warn("lambda: an event could not be read as a request (keys: {s})", .{eventKeys(arena, inv.event)});
                    return rt.fail(inv, "Runtime.InvalidEvent", "the event is not a request this adapter can read") catch |e| return postFailure(e);
                },
            };
            const io = core.io;
            const ctx = try arena.create(lambda.Context);
            ctx.* = .{
                .request_id = inv.request_id,
                .invocation_id = inv.invocation_id,
                .deadline_ms = inv.deadline_ms,
                .function_arn = inv.function_arn,
                .trace_id = inv.trace_id,
                .source = in.source,
                .stage = in.stage,
                .request_context = in.request_context,
                .event = inv.event,
                .client_context = inv.client_context,
                .cognito_identity = inv.cognito_identity,
            };

            if (in.source == .event) {
                const path = cfg.event_path orelse
                    return rt.fail(inv, "Runtime.UnsupportedEvent", "no event_path: set lambda.event_path to receive events that are not HTTP requests") catch |e| return postFailure(e);
                const plan: Plan = .{
                    .method = "POST",
                    .target = path,
                    .headers = &.{.{ .name = "content-type", .value = "application/json" }},
                    .body = inv.event,
                    .client = null,
                    .secure = true,
                    .source = .event,
                    .multi_value = false,
                    .stage = null,
                    .request_context = null,
                };
                return runAndPost(core, rt, inv, arena, cfg, ctx, plan, io);
            }

            const plan: Plan = .{
                .method = in.method,
                .target = in.target,
                .headers = in.headers,
                .body = in.body,
                .client = in.client,
                .secure = in.secure,
                .source = in.source,
                .multi_value = in.multi_value,
                .stage = in.stage,
                .request_context = in.request_context,
            };
            // The event path is reserved for events: a web client cannot
            // forge an SQS batch through the front door.
            if (cfg.event_path) |ep| if (std.mem.eql(u8, pathOf(plan.target), ep)) {
                var headers = try plainHeaders(arena);
                const out = encode.Answer{ .status = 404, .headers = &headers, .parts = &.{"404 Not Found\n"}, .head = std.ascii.eqlIgnoreCase(plan.method, "HEAD") };
                return postBuffered(rt, inv, arena, plan, out);
            };
            return runAndPost(core, rt, inv, arena, cfg, ctx, plan, io);
        }

        fn postFailure(err: runtime.PostError) AnswerError!void {
            return switch (err) {
                error.Canceled => error.Canceled,
                error.OutOfMemory => error.OutOfMemory,
                error.RuntimeApiFailed => error.RuntimeApiFailed,
                // Lambda no longer wants this invocation's answer (it timed
                // out already) or it is too big: logged, serving goes on.
                error.InvalidInvocationId, error.PayloadTooLarge => log.warn("lambda: the Runtime API refused an answer: {t}", .{err}),
            };
        }

        fn runAndPost(
            core: *dusty.Server(Ctx),
            rt: *runtime.Runtime,
            inv: *const runtime.Invocation,
            arena: std.mem.Allocator,
            cfg: *const Config,
            ctx: *const lambda.Context,
            plan: Plan,
            io: std.Io,
        ) AnswerError!void {
            const streaming = cfg.stream and (plan.source == .function_url or plan.source == .rest_api);
            const limit_bytes: usize = if (plan.source == .alb) lambda.max_alb_response_bytes else lambda.max_response_bytes;
            var buffered = BufferedSink.init(arena, limit_bytes);
            var streamed: StreamSink = .{ .rt = rt, .inv = inv, .source = plan.source };
            const sink = if (streaming) streamed.sink() else buffered.sink();

            const remaining_ms = inv.deadline_ms - realMs(io) - cfg.deadline_margin.toMilliseconds();
            if (remaining_ms <= 0) {
                // Past the deadline already: no dispatch.
                return postTimeout(rt, inv, arena, plan, streaming, &buffered, &streamed, null);
            }
            const limit = std.Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .raw = .fromMilliseconds(remaining_ms), .clock = .awake });

            const method = parseMethod(plan.method) orelse {
                var headers = try plainHeaders(arena);
                return postBuffered(rt, inv, arena, plan, .{ .status = 501, .headers = &headers, .parts = &.{"501 Not Implemented\n"}, .head = false });
            };

            // The fields the request is built from: the event's, then the
            // adapter's own.
            var fields: std.ArrayList(event.Field) = .empty;
            try fields.appendSlice(arena, plan.headers);
            if (cfg.context_headers) {
                if (plan.request_context) |rc| {
                    const text = std.json.Stringify.valueAlloc(arena, rc, .{}) catch return error.OutOfMemory;
                    try fields.append(arena, .{ .name = "x-amzn-request-context", .value = text });
                }
                try fields.append(arena, .{ .name = "x-amzn-lambda-context", .value = lambdaContextJson(arena, inv, cfg.env) catch return error.OutOfMemory });
            }
            var has_traceparent = false;
            for (plan.headers) |f| if (std.ascii.eqlIgnoreCase(f.name, "traceparent")) {
                has_traceparent = true;
            };
            if (!has_traceparent) {
                const buf = try arena.create([55]u8);
                if (traceparent(buf, inv.trace_id)) |tp| try fields.append(arena, .{ .name = "traceparent", .value = tp });
            }

            const run = try arena.create(Run);
            run.* = .{ .core = core, .exchange = undefined, .limit = limit, .request_timeout = cfg.request_timeout };
            const ready = run.exchange.init(core, arena, sink, .{
                .method = method,
                .target = plan.target,
                .headers = fields.items,
                .body = plan.body,
                .client = null,
                .secure = plan.secure,
                .listener = &lambda_listener,
                .id = inv.request_id,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.OutOfMemory,
            };
            const req = &run.exchange.request;
            const res = &run.exchange.response;
            defer res.deinit();
            if (ready == .ready) {
                req.remote_address = plan.client orelse unspecified;
                req.secure = plan.secure;
                if (cfg.trusted_proxies) {
                    core.applyForwardedFrom(req, req.remote_address);
                    if (plan.source != .alb) req.secure = plan.secure;
                }
                try req.setLocal(lambda.local_key, ctx);

                var group: std.Io.Group = .init;
                dusty.placement.concurrent(&group, io, .local, Run.task, .{run}) catch {
                    return rt.fail(inv, "Function.ConcurrencyUnavailable", "no task could be started for the request") catch |e| return postFailure(e);
                };
                group.await(io) catch {
                    group.cancel(io);
                    return error.Canceled;
                };
                if (run.canceled) return error.Canceled;
            }

            if (run.timed_out or run.failed) {
                const touched = if (streaming) streamed.touched() else buffered.touched();
                if (!touched and !res.headersSent()) {
                    // Nothing written yet: the status goes through the app's
                    // error mapping (JSON or text, as `errors` says).
                    res.fail(if (run.timed_out) .gateway_timeout else .internal_server_error, "");
                    res.write() catch {};
                } else if (streaming) {
                    streamed.abortWith(arena, if (run.timed_out) "Function.Timeout" else "Function.StreamFailed", if (run.timed_out) "deadline passed" else "the handler failed after the response began");
                    return;
                } else {
                    return postTimeout(rt, inv, arena, plan, false, &buffered, &streamed, run);
                }
            }

            if (streaming) {
                if (streamed.err) |e| return postFailure(if (e == error.Canceled) error.Canceled else error.RuntimeApiFailed);
                // An answer that reached no sink (a 413 or 431 written
                // before the task) was written through it already.
                return;
            }
            if (plan.source == .event) return postEvent(rt, inv, arena, &buffered);
            if (!buffered.touched()) {
                // Nothing came out of the handler at all.
                var headers = try plainHeaders(arena);
                return postBuffered(rt, inv, arena, plan, .{ .status = 500, .headers = &headers, .parts = &.{"500 Internal Server Error\n"}, .head = false });
            }
            if (buffered.too_large) return postTooLarge(rt, inv, arena, plan, req, buffered.limit, null);
            return postBuffered(rt, inv, arena, plan, buffered.result(req.method == .head));
        }

        /// The 504 for a request past Lambda's deadline (or one whose handler
        /// began a buffered answer it could not finish).
        fn postTimeout(
            rt: *runtime.Runtime,
            inv: *const runtime.Invocation,
            arena: std.mem.Allocator,
            plan: Plan,
            streaming: bool,
            buffered: *BufferedSink,
            streamed: *StreamSink,
            run: ?*Run,
        ) AnswerError!void {
            _ = streaming;
            _ = buffered;
            _ = streamed;
            _ = run;
            if (plan.source == .event) return rt.fail(inv, "Function.Timeout", "deadline passed") catch |e| return postFailure(e);
            var headers = try plainHeaders(arena);
            return postBuffered(rt, inv, arena, plan, .{ .status = 504, .headers = &headers, .parts = &.{"504 Gateway Timeout\n"}, .head = false });
        }

        fn postTooLarge(rt: *runtime.Runtime, inv: *const runtime.Invocation, arena: std.mem.Allocator, plan: Plan, req: *const dusty.Request, limit: usize, size: ?usize) AnswerError!void {
            const route = if (req.route) |r| r.path else "(no route)";
            if (size) |n| {
                log.err("lambda: the response to {s} is {d} bytes, past Lambda's limit of {d}; answering 500", .{ route, n, limit });
            } else {
                log.err("lambda: the response to {s} is past Lambda's limit of {d} bytes; answering 500", .{ route, limit });
            }
            var headers = try plainHeaders(arena);
            const message = if (size) |n|
                try std.fmt.allocPrint(arena, "response too large for Lambda ({d} bytes; the limit is {d})\n", .{ n, limit })
            else
                try std.fmt.allocPrint(arena, "response too large for Lambda (the limit is {d} bytes)\n", .{limit});
            return postEncoded(rt, inv, arena, plan, .{ .status = 500, .headers = &headers, .parts = &.{message}, .head = false });
        }

        /// A non-HTTP event's answer: a 2xx body is the invocation's result,
        /// anything else fails the invocation.
        fn postEvent(rt: *runtime.Runtime, inv: *const runtime.Invocation, arena: std.mem.Allocator, buffered: *BufferedSink) AnswerError!void {
            const out = buffered.result(false);
            if (buffered.too_large) {
                return rt.fail(inv, "Function.ResponseTooLarge", "the event's answer is past Lambda's response limit") catch |e| return postFailure(e);
            }
            if (out.status >= 200 and out.status < 300) {
                var body: std.ArrayList(u8) = .empty;
                for (out.parts) |p| try body.appendSlice(arena, p);
                return rt.respond(inv, if (body.items.len == 0) "null" else body.items) catch |e| return postFailure(e);
            }
            var message: std.ArrayList(u8) = .empty;
            for (out.parts) |p| {
                if (message.items.len >= 1024) break;
                try message.appendSlice(arena, p[0..@min(p.len, 1024 - message.items.len)]);
            }
            const text = if (message.items.len > 0 and std.unicode.utf8ValidateSlice(message.items))
                message.items
            else if (dusty.Status.fromCode(out.status)) |s| s.phrase() else |_| "error";
            const error_type = try std.fmt.allocPrint(arena, "Function.Status{d}", .{out.status});
            return rt.fail(inv, error_type, text) catch |e| return postFailure(e);
        }

        fn postBuffered(rt: *runtime.Runtime, inv: *const runtime.Invocation, arena: std.mem.Allocator, plan: Plan, out: encode.Answer) AnswerError!void {
            const limit: usize = if (plan.source == .alb) lambda.max_alb_response_bytes else lambda.max_response_bytes;
            var enc: std.Io.Writer.Allocating = .init(arena);
            var dropped: usize = 0;
            encode.writeBuffered(&enc.writer, plan.source, plan.multi_value, out, &dropped) catch return error.OutOfMemory;
            if (dropped > 0 and !warned_cookies.swap(true, .monotonic)) {
                log.warn("lambda: a response set {d} cookies, but this {s} takes one value per header, so only the first was sent; for ALB, turn on the target group attribute lambda.multi_value_headers.enabled", .{
                    dropped + 1,
                    if (plan.source == .alb) "ALB target group" else "VPC Lattice service",
                });
            }
            const size = enc.written().len;
            if (size > limit) {
                // Replace the answer with a 500 the app can see in its logs.
                var headers = try plainHeaders(arena);
                log.err("lambda: a response of {d} bytes is past Lambda's limit of {d}; answering 500", .{ size, limit });
                const message = try std.fmt.allocPrint(arena, "response too large for Lambda ({d} bytes; the limit is {d})\n", .{ size, limit });
                return postEncoded(rt, inv, arena, plan, .{ .status = 500, .headers = &headers, .parts = &.{message}, .head = false });
            }
            return rt.respond(inv, enc.written()) catch |e| return postFailure(e);
        }

        fn postEncoded(rt: *runtime.Runtime, inv: *const runtime.Invocation, arena: std.mem.Allocator, plan: Plan, out: encode.Answer) AnswerError!void {
            var enc: std.Io.Writer.Allocating = .init(arena);
            var dropped: usize = 0;
            encode.writeBuffered(&enc.writer, plan.source, plan.multi_value, out, &dropped) catch return error.OutOfMemory;
            return rt.respond(inv, enc.written()) catch |e| return postFailure(e);
        }
    };
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "lambda exchange: traceparent from an X-Ray trace id" {
    var buf: [55]u8 = undefined;
    try testing.expectEqualStrings(
        "00-5759e988bd862e3fe1be46a994272793-53995c3f42cd8ad8-01",
        traceparent(&buf, "Root=1-5759e988-bd862e3fe1be46a994272793;Parent=53995c3f42cd8ad8;Sampled=1").?,
    );
    try testing.expectEqualStrings(
        "00-5759e988bd862e3fe1be46a994272793-53995c3f42cd8ad8-00",
        traceparent(&buf, "Root=1-5759e988-bd862e3fe1be46a994272793;Parent=53995c3f42cd8ad8;Sampled=0").?,
    );
    try testing.expect(traceparent(&buf, "") == null);
    try testing.expect(traceparent(&buf, "Root=1-5759e988-bd862e3fe1be46a994272793") == null);
    try testing.expect(traceparent(&buf, "Root=1-5759e98-bd862e3fe1be46a994272793;Parent=53995c3f42cd8ad8") == null);
    try testing.expect(traceparent(&buf, "Root=1-5759e988-bd862e3fe1be46a99427279z;Parent=53995c3f42cd8ad8") == null);
}

test "lambda exchange: the Lambda context header" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const inv: runtime.Invocation = .{
        .request_id = "req-1",
        .invocation_id = "",
        .deadline_ms = 1_700_000_000_000,
        .function_arn = "arn:aws:lambda:eu-west-1:1:function:f",
        .trace_id = "Root=1-5759e988-bd862e3fe1be46a994272793;Parent=53995c3f42cd8ad8;Sampled=1",
        .client_context = "{\"client\":{\"app_title\":\"a\"}}",
        .cognito_identity = "not json",
        .event = "{}",
    };
    const text = try lambdaContextJson(arena_state.allocator(), &inv, .{ .function_name = "f", .memory_mb = 128, .version = "$LATEST", .log_stream = "s", .log_group = "g" });
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try testing.expectEqualStrings("req-1", o.get("request_id").?.string);
    try testing.expectEqual(@as(i64, 1_700_000_000_000), o.get("deadline").?.integer);
    try testing.expectEqualStrings("arn:aws:lambda:eu-west-1:1:function:f", o.get("invoked_function_arn").?.string);
    try testing.expect(o.get("xray_trace_id").? == .string);
    try testing.expectEqualStrings("a", o.get("client_context").?.object.get("client").?.object.get("app_title").?.string);
    // Not JSON: null rather than a broken document.
    try testing.expect(o.get("identity").? == .null);
    try testing.expectEqual(@as(i64, 128), o.get("env_config").?.object.get("memory").?.integer);
    try testing.expectEqualStrings("$LATEST", o.get("env_config").?.object.get("version").?.string);
}

test "lambda exchange: the buffered sink keeps a complete answer, and caps a streamed one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var headers = try dusty.Headers.init(a, 4);
    try headers.put("Content-Type", "text/plain");

    var s = BufferedSink.init(a, 16);
    const sink = s.sink();
    try testing.expect(sink.canComplete());
    try sink.complete(.created, &headers, 5, &.{ "he", "llo" }, null);
    try testing.expect(s.finished and s.touched() and !s.too_large);
    const out = s.result(false);
    try testing.expectEqual(@as(u16, 201), out.status);
    try testing.expectEqual(@as(usize, 2), out.parts.len);

    // A streamed body past the cap fails the write and says so.
    var t = BufferedSink.init(a, 8);
    const tsink = t.sink();
    try tsink.head(.ok, &headers, null);
    try tsink.body().writeAll("12345");
    try tsink.body().flush();
    try testing.expectError(error.WriteFailed, tsink.body().writeAll("6789"));
    try testing.expect(t.too_large);
    try tsink.end(&headers);
    try testing.expect(t.finished and t.trailers_dropped);

    // A `complete` over the cap fails as well.
    var u = BufferedSink.init(a, 4);
    try testing.expectError(error.WriteFailed, u.sink().complete(.ok, &headers, null, &.{"12345"}, null));
    try testing.expect(u.too_large);
}

test "lambda exchange: a streamed body reaches result in order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var headers = try dusty.Headers.init(a, 4);
    try headers.put("Content-Type", "text/plain");
    var s = BufferedSink.init(a, 1024);
    const sink = s.sink();
    try sink.head(.ok, &headers, null);
    try sink.body().writeAll("ab");
    try sink.body().writeAll("cd");
    try sink.end(null);
    const out = s.result(false);
    try testing.expectEqual(@as(usize, 1), out.parts.len);
    try testing.expectEqualStrings("abcd", out.parts[0]);
}
