//! OpenTelemetry tracing for the server: a span per request, its context
//! from the W3C `traceparent` header when the caller sent one (a new trace
//! otherwise), and batches of finished spans sent to an OTLP/HTTP collector
//! as JSON (`POST {endpoint}/v1/traces`).
//!
//!     var exporter = try anole.observe.trace.Exporter.init(gpa, io, &client, .{
//!         .endpoint = "http://otel-collector:4318", .service_name = "api" });
//!     defer exporter.deinit();
//!     try exporter.start();  // the batching task
//!     app.use(anole.observe.trace.Middleware.init(&exporter));
//!
//! Handlers see `req.trace_id` and `req.span_id`; `outgoing(req, &buf)`
//! makes the `traceparent` to pass downstream.
const std = @import("std");
const dusty = @import("dusty");

/// A parsed `traceparent` (version 00).
pub const Context = struct {
    trace_id: [32]u8,
    span_id: [16]u8,
    sampled: bool,

    /// Null for an absent or malformed header (all-zero IDs included).
    pub fn parse(header: []const u8) ?Context {
        const h = std.mem.trim(u8, header, " \t");
        if (h.len < 55 or h[2] != '-' or h[35] != '-' or h[52] != '-') return null;
        if (!isHex(h[0..2]) or std.mem.eql(u8, h[0..2], "ff")) return null;
        // Version 00 is exactly 55 characters; later ones may add fields.
        if (std.mem.eql(u8, h[0..2], "00") and h.len != 55) return null;
        const tid = h[3..35];
        const sid = h[36..52];
        if (!isHex(tid) or !isHex(sid) or !isHex(h[53..55])) return null;
        if (allZero(tid) or allZero(sid)) return null;
        const flags = std.fmt.parseInt(u8, h[53..55], 16) catch return null;
        var c: Context = .{ .trace_id = undefined, .span_id = undefined, .sampled = flags & 1 == 1 };
        for (tid, 0..) |ch, i| c.trace_id[i] = std.ascii.toLower(ch);
        for (sid, 0..) |ch, i| c.span_id[i] = std.ascii.toLower(ch);
        return c;
    }

    pub fn format(self: Context, w: *std.Io.Writer) !void {
        try w.print("00-{s}-{s}-{s}", .{ &self.trace_id, &self.span_id, if (self.sampled) "01" else "00" });
    }
};

fn isHex(s: []const u8) bool {
    for (s) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}

fn allZero(s: []const u8) bool {
    for (s) |ch| if (ch != '0') return false;
    return true;
}

fn randomHex(io: std.Io, out: []u8) void {
    var bytes: [16]u8 = undefined;
    io.random(bytes[0 .. out.len / 2]);
    const hex = "0123456789abcdef";
    for (bytes[0 .. out.len / 2], 0..) |b, i| {
        out[2 * i] = hex[b >> 4];
        out[2 * i + 1] = hex[b & 15];
    }
}

/// The `traceparent` for a call made from within `req`'s span.
pub fn outgoing(req: *const dusty.Request, buf: *[55]u8) ?[]const u8 {
    if (req.trace_id.len != 32 or req.span_id.len != 16) return null;
    return std.fmt.bufPrint(buf, "00-{s}-{s}-01", .{ req.trace_id, req.span_id }) catch null;
}

/// A finished span, as the exporter queues it.
pub const Span = struct {
    trace_id: [32]u8,
    span_id: [16]u8,
    parent_span_id: ?[16]u8,
    /// "GET /users/:id"
    name: [96]u8,
    name_len: u8,
    start_ns: i96,
    end_ns: i96,
    method: [12]u8,
    method_len: u8,
    route: [64]u8,
    route_len: u8,
    status_code: u16,
};

pub const Options = struct {
    /// The collector's OTLP/HTTP base URL ("http://localhost:4318").
    endpoint: []const u8,
    service_name: []const u8,
    /// Spans sent per request to the collector, and how often.
    batch_size: usize = 256,
    interval_ms: u32 = 2000,
    /// Spans waiting beyond this are dropped (and counted).
    queue_len: usize = 4096,
    /// Record only requests whose caller asked for it (sampled flag), or
    /// every request.
    sample_all: bool = true,
};

pub const Exporter = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    client: *dusty.Client,
    options: Options,
    queue: std.Io.Queue(Span),
    buffer: []Span,
    task: ?std.Io.Future(void) = null,
    dropped: std.atomic.Value(u64) = .init(0),
    exported: std.atomic.Value(u64) = .init(0),

    pub fn init(gpa: std.mem.Allocator, io: std.Io, client: *dusty.Client, options: Options) !Exporter {
        const buffer = try gpa.alloc(Span, options.queue_len);
        return .{ .gpa = gpa, .io = io, .client = client, .options = options, .queue = .init(buffer), .buffer = buffer };
    }

    /// Starts the batching task.
    pub fn start(self: *Exporter) !void {
        self.task = try self.io.concurrent(run, .{self});
    }

    /// Sends what is queued and stops the task.
    pub fn deinit(self: *Exporter) void {
        self.queue.close(self.io);
        if (self.task) |*t| t.await(self.io);
        self.gpa.free(self.buffer);
    }

    fn submit(self: *Exporter, span: Span) void {
        const n = self.queue.putUncancelable(self.io, &.{span}, 0) catch 0;
        if (n == 0) _ = self.dropped.fetchAdd(1, .monotonic);
    }

    fn run(self: *Exporter) void {
        const batch = self.gpa.alloc(Span, self.options.batch_size) catch return;
        defer self.gpa.free(batch);
        while (true) {
            // Whatever is there, or wait for one span (closing ends it).
            const n = self.queue.getUncancelable(self.io, batch, 1) catch {
                // Closed: one last drain of what is left.
                const rest = self.queue.getUncancelable(self.io, batch, 0) catch 0;
                if (rest > 0) self.send(batch[0..rest]);
                return;
            };
            self.send(batch[0..n]);
            if (n < batch.len) self.io.sleep(.fromMilliseconds(self.options.interval_ms), .awake) catch return;
        }
    }

    fn send(self: *Exporter, spans: []const Span) void {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const body = encode(arena, self.options.service_name, spans) catch return;
        const url = std.fmt.allocPrint(arena, "{s}/v1/traces", .{std.mem.trimEnd(u8, self.options.endpoint, "/")}) catch return;
        var headers = dusty.Headers.init(arena, 2) catch return;
        headers.put("Content-Type", "application/json") catch return;
        var response = self.client.fetch(url, .{ .method = .post, .headers = &headers, .body = body }) catch {
            _ = self.dropped.fetchAdd(spans.len, .monotonic);
            return;
        };
        defer response.deinit();
        if (response.status() == .ok) _ = self.exported.fetchAdd(spans.len, .monotonic) else _ = self.dropped.fetchAdd(spans.len, .monotonic);
    }
};

/// OTLP/HTTP JSON (opentelemetry-proto's JSON mapping: IDs in hex, times
/// as decimal strings).
pub fn encode(arena: std.mem.Allocator, service: []const u8, spans: []const Span) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.print("{{\"resourceSpans\":[{{\"resource\":{{\"attributes\":[{{\"key\":\"service.name\",\"value\":{{\"stringValue\":{f}}}}}]}},", .{std.json.fmt(service, .{})});
    try w.writeAll("\"scopeSpans\":[{\"scope\":{\"name\":\"anole\"},\"spans\":[");
    for (spans, 0..) |s, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"traceId\":\"{s}\",\"spanId\":\"{s}\",", .{ &s.trace_id, &s.span_id });
        if (s.parent_span_id) |p| try w.print("\"parentSpanId\":\"{s}\",", .{&p});
        try w.print("\"name\":{f},\"kind\":2,\"startTimeUnixNano\":\"{d}\",\"endTimeUnixNano\":\"{d}\",", .{ std.json.fmt(s.name[0..s.name_len], .{}), s.start_ns, s.end_ns });
        try w.print("\"attributes\":[{{\"key\":\"http.request.method\",\"value\":{{\"stringValue\":{f}}}}},", .{std.json.fmt(s.method[0..s.method_len], .{})});
        try w.print("{{\"key\":\"http.route\",\"value\":{{\"stringValue\":{f}}}}},", .{std.json.fmt(s.route[0..s.route_len], .{})});
        try w.print("{{\"key\":\"http.response.status_code\",\"value\":{{\"intValue\":\"{d}\"}}}}],", .{s.status_code});
        // ERROR for 5xx (the server's failure), unset otherwise.
        try w.print("\"status\":{{\"code\":{d}}}}}", .{@as(u8, if (s.status_code >= 500) 2 else 0)});
    }
    try w.writeAll("]}]}]}");
    return out.written();
}

/// Starts a span for each request (continuing the caller's trace), sets
/// `req.trace_id`/`span_id`, and queues the span when the response is done.
pub const Middleware = struct {
    exporter: *Exporter,

    pub fn init(exporter: *Exporter) Middleware {
        return .{ .exporter = exporter };
    }

    pub fn execute(self: *const Middleware, req: *dusty.Request, res: *dusty.Response, executor: anytype) !void {
        const parent = if (req.headers.get("traceparent")) |h| Context.parse(h) else null;
        if (!self.exporter.options.sample_all) if (parent == null or !parent.?.sampled) return executor.next();
        var span: Span = undefined;
        if (parent) |p| span.trace_id = p.trace_id else randomHex(req.io, &span.trace_id);
        randomHex(req.io, &span.span_id);
        span.parent_span_id = if (parent) |p| p.span_id else null;
        req.trace_id = try req.arena.dupe(u8, &span.trace_id);
        req.span_id = try req.arena.dupe(u8, &span.span_id);
        span.start_ns = std.Io.Clock.real.now(req.io).nanoseconds;

        const result = executor.next();

        span.end_ns = std.Io.Clock.real.now(req.io).nanoseconds;
        var mbuf: [12]u8 = undefined;
        const method = std.fmt.bufPrint(&mbuf, "{f}", .{req.method}) catch "?";
        const route = if (req.route) |r| r.path else "unmatched";
        span.method_len = @intCast(method.len);
        @memcpy(span.method[0..method.len], method);
        span.route_len = @intCast(@min(route.len, span.route.len));
        @memcpy(span.route[0..span.route_len], route[0..span.route_len]);
        const name = std.fmt.bufPrint(&span.name, "{s} {s}", .{ method, route[0..span.route_len] }) catch span.name[0..0];
        span.name_len = @intCast(name.len);
        span.status_code = if (result) |_| @intCast(@backingInt(res.status)) else |_| 500;
        self.exporter.submit(span);
        return result;
    }
};

test "traceparent: parse, round trip, and what is refused" {
    const c = Context.parse("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01").?;
    try std.testing.expectEqualStrings("4bf92f3577b34da6a3ce929d0e0e4736", &c.trace_id);
    try std.testing.expect(c.sampled);
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try c.format(&w);
    try std.testing.expectEqualStrings("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", w.buffered());
    try std.testing.expect(Context.parse("00-00000000000000000000000000000000-00f067aa0ba902b7-01") == null);
    try std.testing.expect(Context.parse("ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01") == null);
    try std.testing.expect(Context.parse("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-extra") == null);
    try std.testing.expect(Context.parse("garbage") == null);
}
