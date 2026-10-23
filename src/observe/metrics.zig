//! Prometheus metrics: counters, gauges and histograms with labels, the
//! text exposition format, a middleware for the HTTP metrics, and the
//! `/metrics` route.
//!
//! In an app, `app.metrics(.{})` sets all of this up and returns the
//! registry for metrics of your own:
//!
//!     const registry = app.metrics(.{});
//!     const jobs = try registry.counter("jobs_total", "Jobs run.", &.{"queue"});
//!     jobs.with(&.{"email"}).inc();
//!
//! By hand, with a registry of your own:
//!
//!     var registry = anole.observe.metrics.Registry.init(gpa, io);
//!     defer registry.deinit();
//!     app.use(try anole.observe.metrics.HttpMetrics.init(&registry, .{}));
//!     registry.serveOn(void, app.router, "/metrics");
//!
//! HTTP series are labelled by route pattern (`/users/:id`), never by the
//! raw path, so their number stays bounded.
const std = @import("std");
const dusty = @import("dusty");
const common = @import("common.zig");

/// A value that only goes up (requests, errors, bytes). Safe from any
/// thread.
pub const Counter = struct {
    value: std.atomic.Value(u64) = .init(0),

    /// Adds one.
    pub fn inc(self: *Counter) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }
    /// Adds `n`.
    pub fn add(self: *Counter, n: u64) void {
        _ = self.value.fetchAdd(n, .monotonic);
    }
};

/// A value that goes up and down (connections open, queue length). Safe
/// from any thread.
pub const Gauge = struct {
    value: std.atomic.Value(i64) = .init(0),

    /// Sets the value to `v`.
    pub fn set(self: *Gauge, v: i64) void {
        self.value.store(v, .monotonic);
    }
    /// Adds `v`, which may be negative.
    pub fn add(self: *Gauge, v: i64) void {
        _ = self.value.fetchAdd(v, .monotonic);
    }
};

/// Prometheus' default buckets, in seconds.
pub const default_buckets = [_]f64{ 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10 };

/// A distribution of observed values (latencies, sizes), counted into
/// buckets, with their sum and count. Safe from any thread.
pub const Histogram = struct {
    /// Upper bounds (`le`), strictly increasing and finite.
    bounds: []const f64,
    /// One more than `bounds`, cumulative: `counts[i]` counts the values
    /// at most `bounds[i]`, and the last counts everything (+Inf).
    counts: []std.atomic.Value(u64),
    /// The sum of the values as an `f64`'s bits, added to by compare and
    /// swap (as Prometheus' own clients do): exact to the float, in the
    /// values' own unit, with no truncation or overflow.
    sum_bits: std.atomic.Value(u64) = .init(@bitCast(@as(f64, 0))),

    /// Counts `v` into its buckets and the sum.
    pub fn observe(self: *Histogram, v: f64) void {
        // From +Inf down, each release: a scrape reads upward with acquire,
        // so a bucket it sees counted has every larger one counted too, and
        // the buckets it renders never decrease.
        _ = self.counts[self.bounds.len].fetchAdd(1, .release);
        var i = self.bounds.len;
        while (i > 0) {
            i -= 1;
            if (!(v <= self.bounds[i])) break;
            _ = self.counts[i].fetchAdd(1, .release);
        }
        var old = self.sum_bits.load(.monotonic);
        while (self.sum_bits.cmpxchgWeak(old, @bitCast(@as(f64, @bitCast(old)) + v), .monotonic, .monotonic)) |seen| old = seen;
    }

    /// The sum of every value observed so far.
    pub fn sum(self: *const Histogram) f64 {
        return @bitCast(self.sum_bits.load(.monotonic));
    }

    /// Observes a duration in seconds, from its nanoseconds.
    pub fn observeDuration(self: *Histogram, d: std.Io.Duration) void {
        self.observe(@as(f64, @floatFromInt(d.nanoseconds)) / std.time.ns_per_s);
    }
};

/// Whether `buckets` can be a histogram's bounds: finite and strictly
/// increasing (+Inf is always there, after them).
pub fn validBuckets(buckets: []const f64) bool {
    for (buckets, 0..) |b, i| {
        if (!std.math.isFinite(b)) return false;
        if (i > 0 and !(buckets[i - 1] < b)) return false;
    }
    return true;
}

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
                        try w.print(" {d}\n", .{s.counts[i].load(.acquire)});
                    }
                    const total = s.counts[s.bounds.len].load(.acquire);
                    try w.print("{s}_bucket", .{self.name});
                    try writeLabels(w, self.labels, key, "le", null);
                    try w.print(" {d}\n", .{total});
                    try w.print("{s}_sum", .{self.name});
                    try writeLabels(w, self.labels, key, null, null);
                    try w.writeByte(' ');
                    try writeFloat(w, s.sum());
                    try w.writeByte('\n');
                    try w.print("{s}_count", .{self.name});
                    try writeLabels(w, self.labels, key, null, null);
                    try w.print(" {d}\n", .{total});
                } else {
                    try w.writeAll(self.name);
                    try writeLabels(w, self.labels, key, null, null);
                    try w.print(" {d}\n", .{s.value.load(.monotonic)});
                }
            }
        }
    };
}

/// A sample value as the exposition format spells floats: the shortest
/// decimal that reads back as the same `f64`, or `+Inf`, `-Inf`, `NaN`.
fn writeFloat(w: *std.Io.Writer, v: f64) !void {
    if (std.math.isNan(v)) return w.writeAll("NaN");
    if (std.math.isInf(v)) return w.writeAll(if (v > 0) "+Inf" else "-Inf");
    try w.print("{d}", .{v});
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

/// The metrics an application exposes, rendered at once for a scrape.
/// `app.metrics(.{})` makes one owned by the server; make your own for
/// anything else.
pub const Registry = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    counters: std.ArrayList(*Family(Counter)) = .empty,
    gauges: std.ArrayList(*Family(Gauge)) = .empty,
    histograms: std.ArrayList(*Family(Histogram)) = .empty,

    /// An empty registry.
    pub fn init(gpa: std.mem.Allocator, io: std.Io) Registry {
        return .{ .gpa = gpa, .io = io };
    }

    /// Frees every metric; no `Family` or series pointer may be used after.
    pub fn deinit(self: *Registry) void {
        inline for (.{ &self.counters, &self.gauges, &self.histograms }) |list| {
            for (list.items) |f| {
                f.deinit();
                self.gpa.destroy(f);
            }
            list.deinit(self.gpa);
        }
    }

    /// A counter family named `name` (by convention ending in `_total`) with
    /// these label names; `.with(values)` picks a series. A name already
    /// registered returns that family. `name`, `help` and `labels` must
    /// outlive the registry.
    pub fn counter(self: *Registry, name: []const u8, help: []const u8, labels: []const []const u8) !*Family(Counter) {
        return self.add(Counter, &self.counters, name, help, labels, &.{});
    }
    /// A gauge family, as `counter`.
    pub fn gauge(self: *Registry, name: []const u8, help: []const u8, labels: []const []const u8) !*Family(Gauge) {
        return self.add(Gauge, &self.gauges, name, help, labels, &.{});
    }
    /// `buckets` must be finite and strictly increasing (`error.InvalidBuckets`
    /// otherwise), and outlive the registry.
    pub fn histogram(self: *Registry, name: []const u8, help: []const u8, labels: []const []const u8, buckets: []const f64) !*Family(Histogram) {
        if (!validBuckets(buckets)) return error.InvalidBuckets;
        return self.add(Histogram, &self.histograms, name, help, labels, buckets);
    }

    /// A second metric of a name returns the first one (its labels must
    /// be the same), so two users of one metric (two databases, say)
    /// share it rather than render it twice.
    fn add(self: *Registry, comptime T: type, list: *std.ArrayList(*Family(T)), name: []const u8, help: []const u8, labels: []const []const u8, buckets: []const f64) !*Family(T) {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (list.items) |f| if (std.mem.eql(u8, f.name, name)) {
            std.debug.assert(f.labels.len == labels.len);
            return f;
        };
        const f = try self.gpa.create(Family(T));
        errdefer self.gpa.destroy(f);
        f.* = .{ .registry = self, .name = name, .help = help, .labels = labels };
        if (T == Histogram) f.buckets = buckets;
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

    /// Serves `render` at `path` ("/metrics" by convention) on `router`.
    /// Each registry serves its own metrics, so two servers in one process
    /// can each have one. The registry must outlive the router. The route
    /// names routes, errors and databases: serve it where only the scraper
    /// reaches (`serveOnListener`).
    pub fn serveOn(self: *Registry, comptime Ctx: type, router: *dusty.Router(Ctx), path: []const u8) void {
        common.serve(Ctx, router, path, Registry, self, handle, null);
    }

    /// `serveOn`, answering only on the listener called `listener`
    /// (`req.listener.name`), and 404 on the others.
    pub fn serveOnListener(self: *Registry, comptime Ctx: type, router: *dusty.Router(Ctx), path: []const u8, listener: ?[]const u8) void {
        common.serve(Ctx, router, path, Registry, self, handle, listener);
    }

    fn handle(self: *Registry, _: *dusty.Request, res: *dusty.Response) anyerror!void {
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
    options: Options = .{},

    pub const Options = struct {
        /// Paths not measured: exact, or a prefix when the entry ends in
        /// `*`. `&anole.observe.probe_paths` leaves out health checks and
        /// scrapes.
        exclude: []const []const u8 = &.{},
    };

    /// Registers the HTTP metrics in `registry` and returns the middleware
    /// that keeps them. `app.metrics(.{})` does this for you.
    pub fn init(registry: *Registry, options: Options) !HttpMetrics {
        return .{
            .options = options,
            .requests = try registry.counter("anole_http_requests_total", "HTTP requests answered.", &.{ "method", "route", "status" }),
            .duration = try registry.histogram("anole_http_request_duration_seconds", "Time to answer an HTTP request.", &.{ "method", "route" }, &default_buckets),
            .in_flight = try registry.gauge("anole_http_requests_in_flight", "HTTP requests being answered.", &.{}),
        };
    }

    /// A detached response (`dusty.Detached`) is counted when it is
    /// finished.
    pub const detach_safe = true;

    /// Never waits: no I/O, so `no_wait` routes may sit behind it.
    pub const no_wait = true;

    pub fn execute(self: *const HttpMetrics, req: *dusty.Request, res: *dusty.Response, next: anytype) !void {
        if (common.excluded(req, self.options.exclude)) return next.call();
        const gauge = self.in_flight.with(&.{});
        gauge.add(1);
        const start: std.Io.Clock.Timestamp = .now(req.io, .awake);
        const result = next.call();
        if (res.isDetached()) {
            const later = req.arena.create(Later) catch {
                gauge.add(-1);
                return result;
            };
            later.* = .{ .metrics = self, .start = start };
            res.onFinish(&later.finisher);
            return result;
        }
        gauge.add(-1);
        return self.record(req, res, result, start);
    }

    /// The counts of a detached response, once it is finished.
    const Later = struct {
        finisher: dusty.Detached.Finisher = .{ .func = run },
        metrics: *const HttpMetrics,
        start: std.Io.Clock.Timestamp,

        fn run(f: *dusty.Detached.Finisher, req: *dusty.Request, res: *dusty.Response, result: anyerror!void) void {
            const later: *Later = @alignCast(@fieldParentPtr("finisher", f));
            later.metrics.in_flight.with(&.{}).add(-1);
            later.metrics.record(req, res, result, later.start) catch {};
        }
    };

    fn record(self: *const HttpMetrics, req: *dusty.Request, res: *dusty.Response, result: anyerror!void, start: std.Io.Clock.Timestamp) anyerror!void {
        const elapsed = start.durationTo(.now(req.io, .awake)).raw;
        var method_buf: [16]u8 = undefined;
        const method = std.fmt.bufPrint(&method_buf, "{f}", .{req.method}) catch "?";
        const route_path = if (req.route) |r| r.path else "unmatched";
        var status_buf: [4]u8 = undefined;
        const status = std.fmt.bufPrint(&status_buf, "{d}", .{common.statusOf(req, res, result)}) catch "?";
        self.requests.with(&.{ method, route_path, status }).inc();
        self.duration.with(&.{ method, route_path }).observeDuration(elapsed);
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

test "histograms: sums kept to the float, buckets checked and cumulative" {
    const gpa = std.testing.allocator;
    var r = Registry.init(gpa, std.testing.io);
    defer r.deinit();
    try std.testing.expectError(error.InvalidBuckets, r.histogram("a", "A.", &.{}, &.{ 1, 0.5 }));
    try std.testing.expectError(error.InvalidBuckets, r.histogram("b", "B.", &.{}, &.{ 1, 1 }));
    try std.testing.expectError(error.InvalidBuckets, r.histogram("c", "C.", &.{}, &.{ 1, std.math.inf(f64) }));
    try std.testing.expectError(error.InvalidBuckets, r.histogram("d", "D.", &.{}, &.{std.math.nan(f64)}));

    const lat = try r.histogram("latency_seconds", "Latency.", &.{}, &default_buckets);
    const h = lat.with(&.{});
    // 1.5 microseconds: whole microseconds kept 1 of it.
    h.observeDuration(.fromNanoseconds(1500));
    try std.testing.expectEqual(@as(f64, 1.5e-6), h.sum());
    // On a bound counts in that bucket (le is "at most").
    h.observe(0.005);
    h.observe(0.0051);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try r.render(&out.writer);
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "latency_seconds_bucket{le=\"0.005\"} 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "latency_seconds_bucket{le=\"0.01\"} 3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "latency_seconds_bucket{le=\"10\"} 3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "latency_seconds_bucket{le=\"+Inf\"} 3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "latency_seconds_count 3\n") != null);
    // The sum reads back as the same float.
    const at = std.mem.indexOf(u8, text, "latency_seconds_sum ").? + "latency_seconds_sum ".len;
    const line = text[at .. at + std.mem.indexOfScalar(u8, text[at..], '\n').?];
    try std.testing.expectEqual(h.sum(), try std.fmt.parseFloat(f64, line));
    try std.testing.expectEqual(@as(f64, 1.5e-6 + 0.005 + 0.0051), h.sum());
}
