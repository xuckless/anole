//! The Prometheus side of `anole.resilience`: `anole_breaker_state`,
//! `anole_breaker_opened_total`, `anole_breaker_rejected_total`,
//! `anole_retries_total` and `anole_retries_throttled_total`, labelled
//! `client` and `target` (`target` is capped at 256 distinct values per
//! client; the rest report as "other").
const std = @import("std");
const core = @import("resilience_core");
const observe = @import("../observe/root.zig");
const safety = @import("anole_safety");

const metrics = observe.metrics;

pub const max_targets = 256;
comptime {
    std.debug.assert(@backingInt(core.Kind.kafka) == 7);
}

/// The series of one registry, and the hooks that feed them. Pin it (the
/// hooks point at it); one per registry is enough, every breaker and
/// client of it can share one.
pub const Binding = struct {
    gpa: std.mem.Allocator,
    state: *metrics.Family(metrics.Gauge),
    opened: *metrics.Family(metrics.Counter),
    rejected: *metrics.Family(metrics.Counter),
    retries: *metrics.Family(metrics.Counter),
    throttled: *metrics.Family(metrics.Counter),
    /// Over `seen`: a lookup or an insert into room made beforehand, never
    /// an allocation (SAFETY.md L5).
    lock: safety.SpinLock(.leaf) = .init,
    /// Targets seen per client kind, each with room for `max_targets`
    /// from `init` on.
    seen: [8]std.StringHashMapUnmanaged(void) = @splat(.empty),
    hooks: core.Metrics = .{},

    pub fn init(gpa: std.mem.Allocator, registry: *metrics.Registry) !Binding {
        const labels = &.{ "client", "target" };
        var seen: [8]std.StringHashMapUnmanaged(void) = @splat(.empty);
        errdefer for (&seen) |*m| m.deinit(gpa);
        for (&seen) |*m| try m.ensureTotalCapacity(gpa, max_targets);
        return .{
            .gpa = gpa,
            .seen = seen,
            .state = try registry.gauge("anole_breaker_state", "Circuit breaker state: 0 closed, 1 half-open, 2 open.", labels),
            .opened = try registry.counter("anole_breaker_opened_total", "Times a circuit breaker opened.", labels),
            .rejected = try registry.counter("anole_breaker_rejected_total", "Calls a circuit breaker rejected.", labels),
            .retries = try registry.counter("anole_retries_total", "Retries made, by reason.", &.{ "client", "target", "reason" }),
            .throttled = try registry.counter("anole_retries_throttled_total", "Retries the retry throttle refused.", labels),
        };
    }

    pub fn deinit(self: *Binding) void {
        for (&self.seen) |*m| {
            var it = m.keyIterator();
            while (it.next()) |k| self.gpa.free(k.*);
            m.deinit(self.gpa);
        }
    }

    /// The hooks to give a `Breaker`, `Breakers` or `Policy`.
    pub fn metricsHooks(self: *Binding) *const core.Metrics {
        self.hooks = .{
            .context = self,
            .on_state = onState,
            .on_rejected = onRejected,
            .on_retry = onRetry,
            .on_throttled = onThrottled,
        };
        return &self.hooks;
    }

    /// The `target` label of `target`: its own until `max_targets` are
    /// taken, then "other". The copy of a new one is made and, when another
    /// thread put it first, freed with the lock let go.
    fn label(self: *Binding, kind: core.Kind, target: []const u8) []const u8 {
        const set = &self.seen[@backingInt(kind)];
        {
            self.lock.lock();
            defer self.lock.unlock();
            if (set.getKey(target)) |k| return k;
            if (set.count() >= max_targets) return "other";
        }
        const owned = self.gpa.dupe(u8, target) catch return "other";
        const kept: ?[]const u8 = kept: {
            self.lock.lock();
            defer self.lock.unlock();
            if (set.getKey(target)) |k| break :kept k;
            if (set.count() >= max_targets) break :kept null;
            set.putAssumeCapacityNoClobber(owned, {});
            return owned;
        };
        self.gpa.free(owned);
        return kept orelse "other";
    }

    fn cast(ctx: ?*anyopaque) *Binding {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn onState(ctx: ?*anyopaque, kind: core.Kind, target: []const u8, st: core.Breaker.State) void {
        const self = cast(ctx);
        const t = self.label(kind, target);
        self.state.with(&.{ @tagName(kind), t }).set(@backingInt(st));
        if (st == .open) self.opened.with(&.{ @tagName(kind), t }).inc();
    }
    fn onRejected(ctx: ?*anyopaque, kind: core.Kind, target: []const u8) void {
        const self = cast(ctx);
        self.rejected.with(&.{ @tagName(kind), self.label(kind, target) }).inc();
    }
    fn onRetry(ctx: ?*anyopaque, kind: core.Kind, target: []const u8, reason: []const u8) void {
        const self = cast(ctx);
        self.retries.with(&.{ @tagName(kind), self.label(kind, target), reason }).inc();
    }
    fn onThrottled(ctx: ?*anyopaque, kind: core.Kind, target: []const u8) void {
        const self = cast(ctx);
        self.throttled.with(&.{ @tagName(kind), self.label(kind, target) }).inc();
    }
};

const testing = std.testing;

test "metrics: target labels capped at 256, then other" {
    const gpa = testing.allocator;
    var registry = metrics.Registry.init(gpa, testing.io);
    defer registry.deinit();
    // The binding's allocations are checked against its spin lock (L5).
    var checked: safety.SpinCheckedAllocator = .init(gpa);
    var binding = try Binding.init(checked.allocator(), &registry);
    defer binding.deinit();
    const hooks = binding.metricsHooks();
    var buf: [32]u8 = undefined;
    for (0..max_targets + 5) |i| {
        const t = try std.fmt.bufPrint(&buf, "h{d}", .{i});
        hooks.on_rejected(hooks.context, .http, t);
    }
    // Another client has its own budget.
    hooks.on_rejected(hooks.context, .grpc, "x");
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try registry.render(&out.writer);
    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "anole_breaker_rejected_total{client=\"http\",target=\"other\"} 5") != null);
    try testing.expect(std.mem.indexOf(u8, text, "anole_breaker_rejected_total{client=\"http\",target=\"h1\"} 1") != null);
    // The first target past the cap (h256) and the last one (h260) get no series of their own.
    try testing.expect(std.mem.indexOf(u8, text, "target=\"h256\"") == null);
    try testing.expect(std.mem.indexOf(u8, text, "target=\"h260\"") == null);
    try testing.expect(std.mem.indexOf(u8, text, "anole_breaker_rejected_total{client=\"grpc\",target=\"x\"} 1") != null);
}

test "metrics: a breaker's state reaches the metrics when it is made, and when the breakers are observed" {
    const gpa = testing.allocator;
    const io = testing.io;
    var registry = metrics.Registry.init(gpa, io);
    defer registry.deinit();
    var binding = try Binding.init(gpa, &registry);
    defer binding.deinit();
    var breakers = core.Breakers.init(gpa, .{}, .http, 64);
    defer breakers.deinit();
    // Made before the metrics: reported when they are observed.
    _ = try breakers.get(io, "a");
    breakers.observe(io, binding.metricsHooks());
    // Made after: reported as it is made.
    _ = try breakers.get(io, "b");
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try registry.render(&out.writer);
    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "anole_breaker_state{client=\"http\",target=\"a\"} 0") != null);
    try testing.expect(std.mem.indexOf(u8, text, "anole_breaker_state{client=\"http\",target=\"b\"} 0") != null);
}

/// The tasks of the breakers stress test: each makes and looks up breakers
/// over the same keys, with the metrics on.
const BreakersStress = struct {
    breakers: *core.Breakers,
    io: std.Io,
    failures: std.atomic.Value(u32) = .init(0),

    const keys = 200;
    const gets_each = 10_000;

    fn worker(t: *BreakersStress, seed: u64) void {
        var prng: std.Random.DefaultPrng = .init(seed);
        var buf: [16]u8 = undefined;
        for (0..gets_each) |_| {
            const key = std.fmt.bufPrint(&buf, "k{d}", .{prng.random().uintLessThan(u32, keys)}) catch unreachable;
            const b = t.breakers.get(t.io, key) catch {
                _ = t.failures.fetchAdd(1, .monotonic);
                return;
            };
            if (!std.mem.eql(u8, b.name(), key)) _ = t.failures.fetchAdd(1, .monotonic);
        }
    }
};

test "metrics: [stress] breakers made and reported from every executor: one state series per key" {
    try @import("anole_test_wait").requireStress();
    const zio = @import("zio");
    const placement = @import("dusty").placement;
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(4) });
    defer rt.deinit();
    const io = rt.io();
    var registry = metrics.Registry.init(gpa, io);
    defer registry.deinit();
    var binding = try Binding.init(gpa, &registry);
    defer binding.deinit();
    // Room for every key: nothing is evicted.
    var breakers = core.Breakers.init(gpa, .{}, .http, 16 * BreakersStress.keys);
    defer breakers.deinit();
    breakers.observe(io, binding.metricsHooks());
    var t: BreakersStress = .{ .breakers = &breakers, .io = io };
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (0..4) |i| try placement.concurrent(&group, io, .{ .executor = i }, BreakersStress.worker, .{ &t, 0x5eed_0126 + i });
    try group.await(io);
    try testing.expectEqual(@as(u32, 0), t.failures.load(.monotonic));
    try testing.expectEqual(@as(usize, BreakersStress.keys), breakers.count(io));
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try registry.render(&out.writer);
    try testing.expectEqual(@as(usize, BreakersStress.keys), std.mem.count(u8, out.written(), "anole_breaker_state{"));
}
