//! Prometheus metrics: counters, gauges and histograms with labels, the
//! text exposition format, a middleware for the HTTP metrics, and the
//! `/metrics` route.
//!
//!     var registry = anole.observe.metrics.Registry.init(gpa, io);
//!     var http = try anole.observe.metrics.HttpMetrics.init(&registry);
//!     app.use(http.middleware());
//!     registry.serveOn(void, app.router, "/metrics");
//!     const jobs = try registry.counter("jobs_total", "Jobs run.", &.{"queue"});
//!     jobs.with(&.{"email"}).inc();
//!
//! HTTP series are labelled by route pattern (`/users/:id`), never by the
//! raw path, so their number stays bounded.
const std = @import("std");
const dusty = @import("dusty");

pub const Counter = struct {
    value: std.atomic.Value(u64) = .init(0),

    pub fn inc(self: *Counter) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }
    pub fn add(self: *Counter, n: u64) void {
        _ = self.value.fetchAdd(n, .monotonic);
    }
};

pub const Gauge = struct {
    value: std.atomic.Value(i64) = .init(0),

    pub fn set(self: *Gauge, v: i64) void {
        self.value.store(v, .monotonic);
    }
    pub fn add(self: *Gauge, v: i64) void {
        _ = self.value.fetchAdd(v, .monotonic);
    }
};

/// Prometheus' default buckets, in seconds.
pub const default_buckets = [_]f64{ 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10 };

pub const Histogram = struct {
    bounds: []const f64,
    /// One more than `bounds`: the last counts everything (+Inf).
    counts: []std.atomic.Value(u64),
    /// The sum, in millionths, so it stays atomic.
    sum_micro: std.atomic.Value(u64) = .init(0),

    pub fn observe(self: *Histogram, v: f64) void {
        for (self.bounds, 0..) |b, i| {
            if (v <= b) _ = self.counts[i].fetchAdd(1, .monotonic);
        }
        _ = self.counts[self.bounds.len].fetchAdd(1, .monotonic);
        _ = self.sum_micro.fetchAdd(@intFromFloat(@max(0, v) * 1e6), .monotonic);
    }
};

const Kind = enum { counter, gauge, histogram };

/// A metric with labels: one series per label-value combination, made on
/// first use.
pub fn Family(comptime T: type) type {
    return struct {
        const Self = @This();
        registry: *Registry,
        name: []const u8,
        help: []const u8,
        labels: []const []const u8,
        buckets: []const f64 = &default_buckets,
        mutex: std.Io.Mutex = .init,
        series: std.StringArrayHashMapUnmanaged(*T) = .empty,

        /// The series for these label values (as many as the labels).
        pub fn with(self: *Self, values: []const []const u8) *T {
            std.debug.assert(values.len == self.labels.len);
            const io = self.registry.io;
            const gpa = self.registry.gpa;
            var key_buf: [512]u8 = undefined;
            var w: std.Io.Writer = .fixed(&key_buf);
            for (values) |v| {
                w.writeAll(v) catch break;
                w.writeByte(0) catch break;
            }
            const key = w.buffered();
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.series.get(key)) |s| return s;
            const s = gpa.create(T) catch @panic("OOM");
            s.* = if (T == Histogram) .{
                .bounds = self.buckets,
                .counts = blk: {
                    const c = gpa.alloc(std.atomic.Value(u64), self.buckets.len + 1) catch @panic("OOM");
                    for (c) |*x| x.* = .init(0);
                    break :blk c;
                },
            } else .{};
            self.series.put(gpa, gpa.dupe(u8, key) catch @panic("OOM"), s) catch @panic("OOM");
            return s;
        }

        fn deinit(self: *Self) void {
            const gpa = self.registry.gpa;
            for (self.series.keys(), self.series.values()) |k, v| {
                gpa.free(k);
                if (T == Histogram) gpa.free(v.counts);
                gpa.destroy(v);
            }
            self.series.deinit(gpa);
        }

        fn render(self: *Self, w: *std.Io.Writer) !void {
            const kind = if (T == Counter) "counter" else if (T == Gauge) "gauge" else "histogram";
            try w.print("# HELP {s} {s}\n# TYPE {s} {s}\n", .{ self.name, self.help, self.name, kind });
            const io = self.registry.io;
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            for (self.series.keys(), self.series.values()) |key, s| {
                if (T == Histogram) {
                    for (s.bounds, 0..) |b, i| {
                        try w.print("{s}_bucket", .{self.name});
                        try writeLabels(w, self.labels, key, "le", b);
                        try w.print(" {d}\n", .{s.counts[i].load(.monotonic)});
                    }
                    try w.print("{s}_bucket", .{self.name});
                    try writeLabels(w, self.labels, key, "le", null);
                    try w.print(" {d}\n", .{s.counts[s.bounds.len].load(.monotonic)});
                    try w.print("{s}_sum", .{self.name});
                    try writeLabels(w, self.labels, key, null, null);
                    try w.print(" {d}\n", .{@as(f64, @floatFromInt(s.sum_micro.load(.monotonic))) / 1e6});
                    try w.print("{s}_count", .{self.name});
                    try writeLabels(w, self.labels, key, null, null);
                    try w.print(" {d}\n", .{s.counts[s.bounds.len].load(.monotonic)});
                } else {
                    try w.writeAll(self.name);
                    try writeLabels(w, self.labels, key, null, null);
                    try w.print(" {d}\n", .{s.value.load(.monotonic)});
                }
            }
        }
    };
}

/// `{a="x",b="y"}` from the NUL-separated values in `key`, plus `le`.
fn writeLabels(w: *std.Io.Writer, names: []const []const u8, key: []const u8, le_name: ?[]const u8, le: ?f64) !void {
    if (names.len == 0 and le_name == null) return;
    try w.writeByte('{');
    var it = std.mem.splitScalar(u8, key, 0);
    for (names, 0..) |n, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{s}=\"", .{n});
        try escape(w, it.next() orelse "");
        try w.writeByte('"');
    }
    if (le_name) |ln| {
        if (names.len > 0) try w.writeByte(',');
        if (le) |b| try w.print("{s}=\"{d}\"", .{ ln, b }) else try w.print("{s}=\"+Inf\"", .{ln});
    }
    try w.writeByte('}');
}

fn escape(w: *std.Io.Writer, v: []const u8) !void {
    for (v) |ch| switch (ch) {
        '\\' => try w.writeAll("\\\\"),
        '"' => try w.writeAll("\\\""),
        '\n' => try w.writeAll("\\n"),
        else => try w.writeByte(ch),
    };
}

pub const Registry = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    counters: std.ArrayList(*Family(Counter)) = .empty,
    gauges: std.ArrayList(*Family(Gauge)) = .empty,
    histograms: std.ArrayList(*Family(Histogram)) = .empty,

    var served: ?*Registry = null;

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Registry {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *Registry) void {
        inline for (.{ &self.counters, &self.gauges, &self.histograms }) |list| {
            for (list.items) |f| {
                f.deinit();
                self.gpa.destroy(f);
            }
            list.deinit(self.gpa);
        }
        if (served == self) served = null;
    }

    pub fn counter(self: *Registry, name: []const u8, help: []const u8, labels: []const []const u8) !*Family(Counter) {
        return self.add(Counter, &self.counters, name, help, labels, &.{});
    }
    pub fn gauge(self: *Registry, name: []const u8, help: []const u8, labels: []const []const u8) !*Family(Gauge) {
        return self.add(Gauge, &self.gauges, name, help, labels, &.{});
    }
    pub fn histogram(self: *Registry, name: []const u8, help: []const u8, labels: []const []const u8, buckets: []const f64) !*Family(Histogram) {
        return self.add(Histogram, &self.histograms, name, help, labels, buckets);
    }

    fn add(self: *Registry, comptime T: type, list: *std.ArrayList(*Family(T)), name: []const u8, help: []const u8, labels: []const []const u8, buckets: []const f64) !*Family(T) {
        const f = try self.gpa.create(Family(T));
        f.* = .{ .registry = self, .name = name, .help = help, .labels = labels };
        if (T == Histogram) f.buckets = buckets;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try list.append(self.gpa, f);
        return f;
    }

    /// Every metric in the text exposition format (version 0.0.4).
    pub fn render(self: *Registry, w: *std.Io.Writer) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.counters.items) |f| try f.render(w);
        for (self.gauges.items) |f| try f.render(w);
        for (self.histograms.items) |f| try f.render(w);
    }

    /// Serves `render` at `path` (one registry per process serves).
    pub fn serveOn(self: *Registry, comptime Ctx: type, router: *dusty.Router(Ctx), path: []const u8) void {
        served = self;
        if (Ctx == void) router.get(path, handle) else router.get(path, struct {
            fn h(_: *Ctx, req: *dusty.Request, res: *dusty.Response) anyerror!void {
                return handle(req, res);
            }
        }.h);
    }

    fn handle(_: *dusty.Request, res: *dusty.Response) anyerror!void {
        const self = served orelse return error.NotFound;
        var out: std.Io.Writer.Allocating = .init(res.arena);
        try self.render(&out.writer);
        try res.header("Content-Type", "text/plain; version=0.0.4; charset=utf-8");
        res.body = out.written();
    }
};

/// The HTTP server metrics, kept by a middleware:
/// `anole_http_requests_total{method,route,status}`,
/// `anole_http_request_duration_seconds{method,route}` and
/// `anole_http_requests_in_flight`.
pub const HttpMetrics = struct {
    requests: *Family(Counter),
    duration: *Family(Histogram),
    in_flight: *Family(Gauge),

    pub fn init(registry: *Registry) !HttpMetrics {
        return .{
            .requests = try registry.counter("anole_http_requests_total", "HTTP requests answered.", &.{ "method", "route", "status" }),
            .duration = try registry.histogram("anole_http_request_duration_seconds", "Time to answer an HTTP request.", &.{ "method", "route" }, &default_buckets),
            .in_flight = try registry.gauge("anole_http_requests_in_flight", "HTTP requests being answered.", &.{}),
        };
    }

    pub fn execute(self: *const HttpMetrics, req: *dusty.Request, res: *dusty.Response, executor: anytype) !void {
        const gauge = self.in_flight.with(&.{});
        gauge.add(1);
        defer gauge.add(-1);
        const start: std.Io.Clock.Timestamp = .now(req.io, .awake);
        const result = executor.next();
        const seconds = @as(f64, @floatFromInt(start.durationTo(.now(req.io, .awake)).raw.nanoseconds)) / 1e9;
        var method_buf: [16]u8 = undefined;
        const method = std.fmt.bufPrint(&method_buf, "{f}", .{req.method}) catch "?";
        const route = if (req.route) |r| r.path else "unmatched";
        var status_buf: [4]u8 = undefined;
        const status = std.fmt.bufPrint(&status_buf, "{d}", .{@backingInt(res.status)}) catch "?";
        self.requests.with(&.{ method, route, if (result) |_| status else |_| "500" }).inc();
        self.duration.with(&.{ method, route }).observe(seconds);
        return result;
    }
};

test "registry renders counters, gauges and histograms" {
    const gpa = std.testing.allocator;
    var r = Registry.init(gpa, std.testing.io);
    defer r.deinit();
    const jobs = try r.counter("jobs_total", "Jobs run.", &.{"queue"});
    jobs.with(&.{"email"}).inc();
    jobs.with(&.{"email"}).add(2);
    jobs.with(&.{"we\"ird"}).inc();
    const temp = try r.gauge("temperature", "Degrees.", &.{});
    temp.with(&.{}).set(-3);
    const lat = try r.histogram("latency_seconds", "Latency.", &.{}, &.{ 0.1, 1 });
    lat.with(&.{}).observe(0.05);
    lat.with(&.{}).observe(0.5);
    lat.with(&.{}).observe(5);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try r.render(&out.writer);
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "# TYPE jobs_total counter\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "jobs_total{queue=\"email\"} 3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "jobs_total{queue=\"we\\\"ird\"} 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "temperature -3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "latency_seconds_bucket{le=\"0.1\"} 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "latency_seconds_bucket{le=\"1\"} 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "latency_seconds_bucket{le=\"+Inf\"} 3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "latency_seconds_count 3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "latency_seconds_sum 5.55\n") != null);
}
