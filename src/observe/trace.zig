//! OpenTelemetry tracing for the server: a span per request, its context
//! from the W3C `traceparent` header when the caller sent one (a new trace
//! otherwise), and batches of finished spans sent to an OTLP/HTTP collector
//! as JSON (`POST {endpoint}/v1/traces`).
//!
//! In an app, `_ = try app.tracing(.{ .service_name = "api" });` does all
//! of this (see `TracingOptions` for the endpoint). By hand:
//!
//!     var exporter = try anole.observe.trace.Exporter.init(gpa, app.io(), app.client(), .{
//!         .endpoint = "http://otel-collector:4318", .service_name = "api" });
//!     defer exporter.deinit();
//!     try exporter.start();  // the batching task
//!     app.use(anole.observe.trace.Middleware.init(&exporter));
//!
//! Handlers see `req.trace_id` and `req.span_id`; `outgoing(req, &buf)`
//! makes the `traceparent` to pass downstream.
const std = @import("std");
const dusty = @import("dusty");
const common = @import("common.zig");
const Client = @import("../client.zig").Client;

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

    /// Writes the context as a `traceparent` value (`{f}`).
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

/// The `traceparent` for a call made from within `req`'s span. Sampled,
/// unless the request was not recorded and passes its caller's unsampled
/// context on as it came.
pub fn outgoing(req: *const dusty.Request, buf: *[55]u8) ?[]const u8 {
    if (req.trace_id.len != 32 or req.span_id.len != 16) return null;
    const passed_on = if (req.headers.get("traceparent")) |h| Context.parse(h) else null;
    const sampled = if (passed_on) |p| p.sampled or !std.mem.eql(u8, &p.span_id, req.span_id) else true;
    return std.fmt.bufPrint(buf, "00-{s}-{s}-{s}", .{ req.trace_id, req.span_id, if (sampled) "01" else "00" }) catch null;
}

/// Whether `req`'s span is recorded here, so calls it makes get child
/// spans: the middleware gave it a span ID of its own, rather than
/// passing an unsampled caller's context on as it came.
pub fn recording(req: *const dusty.Request) bool {
    if (req.trace_id.len != 32 or req.span_id.len != 16) return false;
    const passed_on = if (req.headers.get("traceparent")) |h| Context.parse(h) else null;
    const p = passed_on orelse return true;
    return !std.mem.eql(u8, &p.span_id, req.span_id);
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
    /// Set for a database call made while serving a request (a client
    /// span, child of the request's; `Exporter.child`), when the HTTP
    /// fields above are unused. Null for the request's own span.
    db: ?Db = null,

    /// OpenTelemetry's database attributes, cut to fit.
    pub const Db = struct {
        /// `db.system.name`: "postgresql", "sqlite", "mongodb", "redis".
        system: [16]u8 = undefined,
        system_len: u8 = 0,
        /// `db.namespace`: the database.
        namespace: [48]u8 = undefined,
        namespace_len: u8 = 0,
        /// `db.operation.name`: "SELECT", "find".
        operation: [24]u8 = undefined,
        operation_len: u8 = 0,
        /// `db.collection.name`: the table or collection, when known.
        collection: [48]u8 = undefined,
        collection_len: u8 = 0,
        /// `error.type` (the error's name) for a failed call; empty for
        /// success.
        error_type: [32]u8 = undefined,
        error_type_len: u8 = 0,

        /// The attributes from their values, each cut to its field's size.
        pub fn init(system: []const u8, namespace: []const u8, operation: []const u8, collection: ?[]const u8, error_type: ?[]const u8) Db {
            var d: Db = .{};
            d.system_len = put(&d.system, system);
            d.namespace_len = put(&d.namespace, namespace);
            d.operation_len = put(&d.operation, operation);
            d.collection_len = put(&d.collection, collection orelse "");
            d.error_type_len = put(&d.error_type, error_type orelse "");
            return d;
        }

        fn put(dst: []u8, src: []const u8) u8 {
            const n = @min(dst.len, src.len);
            @memcpy(dst[0..n], src[0..n]);
            return @intCast(n);
        }
    };
};

/// `Exporter` settings.
pub const Options = struct {
    /// The collector's OTLP/HTTP base URL ("http://localhost:4318").
    endpoint: []const u8,
    /// `service.name` on every span.
    service_name: []const u8,
    /// Spans sent per request to the collector, and how often.
    batch_size: usize = 256,
    interval_ms: u32 = 2000,
    /// Spans waiting beyond this are dropped (and counted).
    queue_len: usize = 4096,
    /// Record only requests whose caller asked for it (sampled flag), or
    /// every request.
    sample_all: bool = true,
    /// Paths the middleware does not trace: exact, or a prefix when the
    /// entry ends in `*`. `&anole.observe.probe_paths` leaves out health
    /// checks and scrapes.
    exclude: []const []const u8 = &.{},
};

/// Queues finished spans and sends them to the collector in batches from a
/// task of its own, through `client`. A full queue drops spans rather than
/// slow requests. `app.tracing(.{})` makes one owned by the server,
/// already started.
pub const Exporter = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    client: Client,
    options: Options,
    queue: std.Io.Queue(Span),
    buffer: []Span,
    task: ?std.Io.Future(void) = null,
    /// Set by `deinit`: wakes the task from its pause between batches.
    closing: std.Io.Event = .unset,
    /// Spans dropped: the queue was full, or the collector did not take
    /// them.
    dropped: std.atomic.Value(u64) = .init(0),
    /// Spans the collector accepted.
    exported: std.atomic.Value(u64) = .init(0),

    /// An exporter with its queue allocated, sending through `client` (the
    /// server's, `app.client()`). Nothing is sent until `start`. `client`'s
    /// server must outlive it.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, client: Client, options: Options) !Exporter {
        const buffer = try gpa.alloc(Span, options.queue_len);
        return .{ .gpa = gpa, .io = io, .client = client, .options = options, .queue = .init(buffer), .buffer = buffer };
    }

    /// Starts the batching task.
    pub fn start(self: *Exporter) !void {
        self.task = try self.io.concurrent(run, .{self});
    }

    /// Sends what is queued and stops the task.
    pub fn deinit(self: *Exporter) void {
        self.closing.set(self.io);
        self.queue.close(self.io);
        if (self.task) |*t| t.await(self.io);
        self.gpa.free(self.buffer);
    }

    /// Queues a client span for a call made while serving `req` (a
    /// database query), as a child of the request's span, from
    /// `start_ns` to `end_ns` (real clock). Nothing when the request is
    /// not recorded (`recording`).
    pub fn child(self: *Exporter, req: *const dusty.Request, start_ns: i96, end_ns: i96, db: Span.Db) void {
        if (!recording(req)) return;
        var span: Span = undefined;
        @memcpy(&span.trace_id, req.trace_id[0..32]);
        randomHex(req.io, &span.span_id);
        span.parent_span_id = req.span_id[0..16].*;
        const collection = db.collection[0..db.collection_len];
        const name = std.fmt.bufPrint(&span.name, "{s} {s}", .{
            db.operation[0..db.operation_len],
            if (collection.len > 0) collection else db.namespace[0..db.namespace_len],
        }) catch span.name[0..0];
        span.name_len = @intCast(std.mem.trimEnd(u8, name, " ").len);
        span.start_ns = start_ns;
        span.end_ns = end_ns;
        span.method_len = 0;
        span.route_len = 0;
        span.status_code = 0;
        span.db = db;
        self.submit(span);
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
            // A pause before the next batch, cut short by `deinit`.
            if (n < batch.len) self.closing.waitTimeout(self.io, .{ .duration = .{
                .raw = .fromMilliseconds(self.options.interval_ms),
                .clock = .awake,
            } }) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => return,
            };
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
        var response = self.client.http.fetch(url, .{ .method = .post, .headers = &headers, .body = body }) catch {
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
        if (s.db) |d| {
            try w.print("\"name\":{f},\"kind\":3,\"startTimeUnixNano\":\"{d}\",\"endTimeUnixNano\":\"{d}\",", .{ std.json.fmt(s.name[0..s.name_len], .{}), s.start_ns, s.end_ns });
            try w.print("\"attributes\":[{{\"key\":\"db.system.name\",\"value\":{{\"stringValue\":{f}}}}}", .{std.json.fmt(d.system[0..d.system_len], .{})});
            const optional = [_]struct { []const u8, []const u8 }{
                .{ "db.namespace", d.namespace[0..d.namespace_len] },
                .{ "db.operation.name", d.operation[0..d.operation_len] },
                .{ "db.collection.name", d.collection[0..d.collection_len] },
                .{ "error.type", d.error_type[0..d.error_type_len] },
            };
            for (optional) |a| if (a[1].len > 0) try w.print(",{{\"key\":\"{s}\",\"value\":{{\"stringValue\":{f}}}}}", .{ a[0], std.json.fmt(a[1], .{}) });
            try w.print("],\"status\":{{\"code\":{d}}}}}", .{@as(u8, if (d.error_type_len > 0) 2 else 0)});
            continue;
        }
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

    /// The middleware, queueing spans on `exporter`, which must outlive it.
    pub fn init(exporter: *Exporter) Middleware {
        return .{ .exporter = exporter };
    }

    pub fn execute(self: *const Middleware, req: *dusty.Request, res: *dusty.Response, executor: anytype) !void {
        if (common.excluded(req, self.exporter.options.exclude)) return executor.next();
        const parent = if (req.headers.get("traceparent")) |h| Context.parse(h) else null;
        if (!self.exporter.options.sample_all) if (parent == null or !parent.?.sampled) {
            // Not recorded here, but the caller's context still goes on to
            // the calls this request makes, unchanged (W3C Trace Context:
            // `outgoing` keeps its sampled flag).
            if (parent) |p| {
                req.trace_id = try req.arena.dupe(u8, &p.trace_id);
                req.span_id = try req.arena.dupe(u8, &p.span_id);
            }
            return executor.next();
        };
        var span: Span = undefined;
        span.db = null;
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
        span.status_code = common.statusOf(req, res, result);
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

test "fuzz: traceparent parsing round-trips" {
    try @import("../fuzz.zig").bytes(struct {
        fn check(input: []const u8) !void {
            const ctx = Context.parse(input) orelse return;
            var buf: [64]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            try ctx.format(&w);
            const again = Context.parse(w.buffered()) orelse return error.RoundTrip;
            try std.testing.expectEqual(ctx, again);
        }
    }.check, &.{
        "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
        " 00-0AF7651916CD43DD8448EB211C80319C-B7AD6B7169203331-00\t",
        "01-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01-future",
    });
}
