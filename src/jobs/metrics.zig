//! Prometheus series of the job queue (§7.1). `kind` and `name` labels take
//! at most 256 distinct values; later ones report as "other".
const std = @import("std");
const safety = @import("anole_safety");
const observe = @import("../observe/root.zig");

const m = observe.metrics;

pub const max_labels = 256;

pub const Outcome = enum { completed, retried, dead, snoozed, cancelled, timeout, interrupted };

pub const Series = struct {
    gpa: std.mem.Allocator,
    enqueued: *m.Family(m.Counter),
    duplicates: *m.Family(m.Counter),
    finished: *m.Family(m.Counter),
    run_seconds: *m.Family(m.Histogram),
    running: *m.Family(m.Gauge),
    queued: *m.Family(m.Gauge),
    rescued: *m.Family(m.Counter),
    unsaved: *m.Family(m.Counter),
    leader: *m.Family(m.Gauge),
    cron_enqueued: *m.Family(m.Counter),
    /// Guards `kinds` and `names`. A leaf spin lock: nothing is allocated
    /// under it (SAFETY.md L5).
    lock: safety.SpinLock(.leaf) = .init,
    /// Label sets: at most `max_labels` names each, sized at `init`, so a
    /// put under `lock` never grows them. The names live until `deinit`.
    kinds: std.StringHashMapUnmanaged(void) = .empty,
    names: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(gpa: std.mem.Allocator, registry: *m.Registry) !Series {
        const buckets = [_]f64{ 0.01, 0.05, 0.1, 0.5, 1, 5, 30, 120, 600 };
        var s: Series = .{
            .gpa = gpa,
            .enqueued = try registry.counter("anole_jobs_enqueued_total", "Jobs enqueued.", &.{ "queue", "kind" }),
            .duplicates = try registry.counter("anole_jobs_duplicates_total", "Enqueues answered with an existing unique job.", &.{ "queue", "kind" }),
            .finished = try registry.counter("anole_jobs_finished_total", "Job runs by outcome.", &.{ "queue", "kind", "outcome" }),
            .run_seconds = try registry.histogram("anole_jobs_run_seconds", "How long job runs took.", &.{ "queue", "kind" }, &buckets),
            .running = try registry.gauge("anole_jobs_running", "Jobs running in this process.", &.{"queue"}),
            .queued = try registry.gauge("anole_jobs_queued", "Jobs in the store by state (the leader reports).", &.{ "queue", "state" }),
            .rescued = try registry.counter("anole_jobs_rescued_total", "Jobs put back after their lease lapsed.", &.{"queue"}),
            .unsaved = try registry.counter("anole_jobs_outcome_unsaved_total", "Runs whose outcome could not be saved; they run again after their lease.", &.{ "queue", "kind" }),
            .leader = try registry.gauge("anole_jobs_leader", "1 while this process leads schedules and maintenance.", &.{}),
            .cron_enqueued = try registry.counter("anole_cron_enqueued_total", "Jobs enqueued by cron schedules.", &.{"name"}),
        };
        try s.kinds.ensureTotalCapacity(gpa, max_labels);
        errdefer s.kinds.deinit(gpa);
        try s.names.ensureTotalCapacity(gpa, max_labels);
        return s;
    }

    pub fn deinit(self: *Series) void {
        inline for (.{ &self.kinds, &self.names }) |set| {
            var it = set.keyIterator();
            while (it.next()) |k| self.gpa.free(k.*);
            set.deinit(self.gpa);
        }
    }

    const Lookup = union(enum) { found: []const u8, full, missing };

    fn lookup(self: *Series, set: *std.StringHashMapUnmanaged(void), value: []const u8) Lookup {
        self.lock.lock();
        defer self.lock.unlock();
        if (set.getKey(value)) |k| return .{ .found = k };
        if (set.count() >= max_labels) return .full;
        return .missing;
    }

    /// The label for `value`: its own name while the set has room, else
    /// "other". The name returned lives until `deinit`.
    fn cap(self: *Series, set: *std.StringHashMapUnmanaged(void), value: []const u8) []const u8 {
        switch (self.lookup(set, value)) {
            .found => |k| return k,
            .full => return "other",
            .missing => {},
        }
        // A new label: copied before the lock is taken again (L5).
        const owned = self.gpa.dupe(u8, value) catch return "other";
        var kept = false;
        self.lock.lock();
        const out: []const u8 = if (set.getKey(value)) |k|
            k // another thread added it meanwhile
        else if (set.count() >= max_labels)
            "other"
        else blk: {
            set.putAssumeCapacityNoClobber(owned, {});
            kept = true;
            break :blk owned;
        };
        self.lock.unlock();
        if (!kept) self.gpa.free(owned);
        return out;
    }

    pub fn onEnqueued(self: *Series, queue: []const u8, kind: []const u8, inserted: bool) void {
        const k = self.cap(&self.kinds, kind);
        (if (inserted) self.enqueued else self.duplicates).with(&.{ queue, k }).inc();
    }

    pub fn onFinished(self: *Series, queue: []const u8, kind: []const u8, outcome: Outcome, took: std.Io.Duration) void {
        const k = self.cap(&self.kinds, kind);
        self.finished.with(&.{ queue, k, @tagName(outcome) }).inc();
        self.run_seconds.with(&.{ queue, k }).observeDuration(took);
    }

    pub fn onUnsaved(self: *Series, queue: []const u8, kind: []const u8) void {
        self.unsaved.with(&.{ queue, self.cap(&self.kinds, kind) }).inc();
    }

    pub fn onCron(self: *Series, name: []const u8) void {
        self.cron_enqueued.with(&.{self.cap(&self.names, name)}).inc();
    }
};

test "jobs metrics: a new kind label is recorded without allocating under the label lock" {
    var registry: m.Registry = .init(std.testing.allocator, std.testing.io);
    defer registry.deinit();
    // Panics (SAFETY.md L5) when the series allocates under its spin lock.
    var checked: safety.SpinCheckedAllocator = .init(std.testing.allocator);
    var s = try Series.init(checked.allocator(), &registry);
    defer s.deinit();
    s.onEnqueued("default", "k1", true);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try registry.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "anole_jobs_enqueued_total{queue=\"default\",kind=\"k1\"} 1") != null);
}
