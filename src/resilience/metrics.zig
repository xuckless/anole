//! The Prometheus side of `anole.resilience`: `anole_breaker_state`,
//! `anole_breaker_opened_total`, `anole_breaker_rejected_total`,
//! `anole_retries_total` and `anole_retries_throttled_total`, labelled
//! `client` and `target` (`target` is capped at 256 distinct values per
//! client; the rest report as "other").
const std = @import("std");
const core = @import("resilience_core");
const observe = @import("../observe/root.zig");

const metrics = observe.metrics;

pub const max_targets = 256;
comptime {
    std.debug.assert(@intFromEnum(core.Kind.kafka) == 7);
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
    lock: std.atomic.Mutex = .unlocked,
    /// Targets seen per client kind.
    seen: [8]std.StringHashMapUnmanaged(void) = @splat(.empty),
    hooks: core.Metrics = .{},

    pub fn init(gpa: std.mem.Allocator, registry: *metrics.Registry) !Binding {
        const labels = &.{ "client", "target" };
        return .{
            .gpa = gpa,
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

    fn label(self: *Binding, kind: core.Kind, target: []const u8) []const u8 {
        const set = &self.seen[@intFromEnum(kind)];
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
        defer self.lock.unlock();
        if (set.contains(target)) return set.getKey(target).?;
        if (set.count() >= max_targets) return "other";
        const owned = self.gpa.dupe(u8, target) catch return "other";
        set.put(self.gpa, owned, {}) catch {
            self.gpa.free(owned);
            return "other";
        };
        return owned;
    }

    fn cast(ctx: ?*anyopaque) *Binding {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn onState(ctx: ?*anyopaque, kind: core.Kind, target: []const u8, st: core.Breaker.State) void {
        const self = cast(ctx);
        const t = self.label(kind, target);
        self.state.with(&.{ @tagName(kind), t }).set(@intFromEnum(st));
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
    var binding = try Binding.init(gpa, &registry);
    defer binding.deinit();
    const hooks = binding.metricsHooks();
    var buf: [32]u8 = undefined;
    for (0..max_targets + 5) |i| {
        const t = try std.fmt.bufPrint(&buf, "h{d}", .{i});
        hooks.on_rejected(hooks.context, .http, t);
    }
    try testing.expectEqualStrings("other", binding.label(.http, "h300"));
    try testing.expectEqualStrings("h1", binding.label(.http, "h1"));
    // Another client has its own budget.
    try testing.expectEqualStrings("x", binding.label(.grpc, "x"));
}
