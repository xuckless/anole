//! Turns the cumulative `stats` frames (wrapping u32 sums over executors)
//! into rates and latency percentiles over a time window. Pure: the caller
//! pushes frames, the window never reads a clock.
const std = @import("std");
const protocol = @import("protocol.zig");

pub const bucket_count = protocol.bucket_count;
/// The longest window kept (ms); older samples are dropped.
pub const keep_ms: i64 = 70_000;

/// Bucket b in 1..96 spans [lo, hi) microseconds; 0 is below 16 us, 97 is
/// 2^28 us and up (design 6.2).
pub fn bucketBounds(b: u32) struct { lo_us: u64, hi_us: u64 } {
    if (b == 0) return .{ .lo_us = 0, .hi_us = 16 };
    if (b >= 97) return .{ .lo_us = @as(u64, 1) << 28, .hi_us = @as(u64, 1) << 29 };
    const o: u6 = @intCast(4 + (b - 1) / 4);
    const sub: u64 = (b - 1) % 4;
    const step = @as(u64, 1) << (o - 2);
    const lo = (4 + sub) * step;
    return .{ .lo_us = lo, .hi_us = lo + step };
}

pub fn bucketMidUs(b: u32) f64 {
    const r = bucketBounds(b);
    return @as(f64, @floatFromInt(r.lo_us + r.hi_us)) / 2.0;
}

pub const Hist = [bucket_count]u32;

const RouteCum = struct {
    i: u32,
    method: []const u8,
    pattern: []const u8,
    n: u32,
    s2: u32,
    s3: u32,
    s4: u32,
    s5: u32,
    h: Hist,
};

const DbCum = struct { i: u32, n: u32, e: u32, h: Hist };

const Sample = struct {
    mono_ms: i64,
    routes: []RouteCum,
    dbs: []DbCum,
    conns_total: u32,

    fn free(self: Sample, gpa: std.mem.Allocator) void {
        for (self.routes) |r| {
            gpa.free(r.method);
            gpa.free(r.pattern);
        }
        gpa.free(self.routes);
        gpa.free(self.dbs);
    }
};

pub const Row = struct {
    i: u32,
    method: []const u8,
    pattern: []const u8,
    count: u32,
    rps: f64,
    /// null when no request finished in the window.
    p50_us: ?f64,
    p99_us: ?f64,
    r4: f64,
    r5: f64,
};

pub const DbRow = struct { i: u32, rps: f64, p50_us: ?f64, p99_us: ?f64, eps: f64 };

pub const Totals = struct {
    /// Requests per second over the latest interval (about 1 s).
    rps: f64 = 0,
    /// The 99th percentile over `p99_window_ms`, all routes together.
    p99_us: ?f64 = null,
    /// 5xx answers per minute, from the last 60 s.
    err_per_min: f64 = 0,
    conns: u32 = 0,
};

pub const Window = struct {
    gpa: std.mem.Allocator,
    samples: std.ArrayList(Sample) = .empty,

    pub fn init(gpa: std.mem.Allocator) Window {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Window) void {
        for (self.samples.items) |s| s.free(self.gpa);
        self.samples.deinit(self.gpa);
    }

    pub fn clear(self: *Window) void {
        for (self.samples.items) |s| s.free(self.gpa);
        self.samples.clearRetainingCapacity();
    }

    /// Adds a frame; drops samples older than `keep_ms`. The frame's strings
    /// are copied.
    pub fn push(self: *Window, st: protocol.Stats) !void {
        const gpa = self.gpa;
        const routes = try gpa.alloc(RouteCum, st.routes.len);
        var made: usize = 0;
        errdefer {
            for (routes[0..made]) |r| {
                gpa.free(r.method);
                gpa.free(r.pattern);
            }
            gpa.free(routes);
        }
        for (st.routes, routes) |r, *out| {
            const m = try gpa.dupe(u8, r.m);
            errdefer gpa.free(m);
            const p = try gpa.dupe(u8, r.p);
            out.* = .{ .i = r.i, .method = m, .pattern = p, .n = r.n, .s2 = r.s2, .s3 = r.s3, .s4 = r.s4, .s5 = r.s5, .h = dense(r.h) };
            made += 1;
        }
        const dbs = try gpa.alloc(DbCum, st.db.len);
        errdefer gpa.free(dbs);
        for (st.db, dbs) |d, *out| out.* = .{ .i = d.i, .n = d.n, .e = d.e, .h = dense(d.h) };
        try self.samples.append(gpa, .{
            .mono_ms = st.mono_ms,
            .routes = routes,
            .dbs = dbs,
            .conns_total = if (st.conns) |c| c.total else 0,
        });
        while (self.samples.items.len > 1 and st.mono_ms - self.samples.items[0].mono_ms > keep_ms) {
            self.samples.orderedRemove(0).free(gpa);
        }
    }

    /// The oldest sample no older than `window_ms` before the newest, with
    /// the newest; null with fewer than two samples.
    fn span(self: *const Window, window_ms: i64) ?struct { old: *const Sample, new: *const Sample } {
        const n = self.samples.items.len;
        if (n < 2) return null;
        const new = &self.samples.items[n - 1];
        var old = &self.samples.items[n - 2];
        var k = n - 2;
        while (true) {
            const s = &self.samples.items[k];
            if (new.mono_ms - s.mono_ms > window_ms) break;
            old = s;
            if (k == 0) break;
            k -= 1;
        }
        if (new.mono_ms <= old.mono_ms) return null;
        return .{ .old = old, .new = new };
    }

    /// Per-route numbers over the window. Routes with no requests in it are
    /// left out. Caller frees the slice (the strings point into the window).
    pub fn rows(self: *const Window, gpa: std.mem.Allocator, window_ms: i64) ![]Row {
        const sp = self.span(window_ms) orelse return gpa.alloc(Row, 0);
        const secs = @as(f64, @floatFromInt(sp.new.mono_ms - sp.old.mono_ms)) / 1000.0;
        var out: std.ArrayList(Row) = .empty;
        errdefer out.deinit(gpa);
        for (sp.new.routes) |nr| {
            const base: ?*const RouteCum = for (sp.old.routes) |*o| {
                if (o.i == nr.i) break o;
            } else null;
            const dn = nr.n -% (if (base) |b| b.n else 0);
            if (dn == 0) continue;
            var h: Hist = undefined;
            for (&h, nr.h, 0..) |*d, v, b| d.* = v -% (if (base) |bb| bb.h[b] else 0);
            try out.append(gpa, .{
                .i = nr.i,
                .method = nr.method,
                .pattern = nr.pattern,
                .count = dn,
                .rps = @as(f64, @floatFromInt(dn)) / secs,
                .p50_us = percentile(&h, 0.50),
                .p99_us = percentile(&h, 0.99),
                .r4 = @as(f64, @floatFromInt(nr.s4 -% (if (base) |b| b.s4 else 0))) / secs,
                .r5 = @as(f64, @floatFromInt(nr.s5 -% (if (base) |b| b.s5 else 0))) / secs,
            });
        }
        return out.toOwnedSlice(gpa);
    }

    pub fn dbRows(self: *const Window, gpa: std.mem.Allocator, window_ms: i64) ![]DbRow {
        const sp = self.span(window_ms) orelse return gpa.alloc(DbRow, 0);
        const secs = @as(f64, @floatFromInt(sp.new.mono_ms - sp.old.mono_ms)) / 1000.0;
        var out: std.ArrayList(DbRow) = .empty;
        errdefer out.deinit(gpa);
        for (sp.new.dbs) |nd| {
            const base: ?*const DbCum = for (sp.old.dbs) |*o| {
                if (o.i == nd.i) break o;
            } else null;
            const dn = nd.n -% (if (base) |b| b.n else 0);
            var h: Hist = undefined;
            for (&h, nd.h, 0..) |*d, v, b| d.* = v -% (if (base) |bb| bb.h[b] else 0);
            try out.append(gpa, .{
                .i = nd.i,
                .rps = @as(f64, @floatFromInt(dn)) / secs,
                .p50_us = percentile(&h, 0.50),
                .p99_us = percentile(&h, 0.99),
                .eps = @as(f64, @floatFromInt(nd.e -% (if (base) |b| b.e else 0))) / secs,
            });
        }
        return out.toOwnedSlice(gpa);
    }

    /// The status line numbers.
    pub fn totals(self: *const Window, p99_window_ms: i64) Totals {
        var t: Totals = .{};
        const n = self.samples.items.len;
        if (n == 0) return t;
        t.conns = self.samples.items[n - 1].conns_total;
        if (self.span(1500)) |sp| {
            const secs = @as(f64, @floatFromInt(sp.new.mono_ms - sp.old.mono_ms)) / 1000.0;
            t.rps = @as(f64, @floatFromInt(sumN(sp.new.routes) -% sumN(sp.old.routes))) / secs;
        }
        if (self.span(p99_window_ms)) |sp| t.p99_us = percentile(&mergedDelta(sp.old, sp.new), 0.99);
        if (self.span(60_000)) |sp| {
            const secs = @as(f64, @floatFromInt(sp.new.mono_ms - sp.old.mono_ms)) / 1000.0;
            var d5: u32 = 0;
            for (sp.new.routes) |nr| {
                const base: u32 = for (sp.old.routes) |o| {
                    if (o.i == nr.i) break o.s5;
                } else 0;
                d5 +%= nr.s5 -% base;
            }
            t.err_per_min = @as(f64, @floatFromInt(d5)) / secs * 60.0;
        }
        return t;
    }
};

fn sumN(routes: []const RouteCum) u32 {
    var s: u32 = 0;
    for (routes) |r| s +%= r.n;
    return s;
}

fn mergedDelta(old: *const Sample, new: *const Sample) Hist {
    var h: Hist = @splat(0);
    for (new.routes) |nr| {
        const base: ?*const RouteCum = for (old.routes) |*o| {
            if (o.i == nr.i) break o;
        } else null;
        for (&h, nr.h, 0..) |*d, v, b| d.* +%= v -% (if (base) |bb| bb.h[b] else 0);
    }
    return h;
}

fn dense(pairs: []const [2]u32) Hist {
    var h: Hist = @splat(0);
    for (pairs) |p| if (p[0] < bucket_count) {
        h[p[0]] = p[1];
    };
    return h;
}

/// The bucket midpoint (microseconds) holding quantile q of the histogram;
/// null when it is empty.
pub fn percentile(h: *const Hist, q: f64) ?f64 {
    var total: u64 = 0;
    for (h) |c| total += c;
    if (total == 0) return null;
    const need: u64 = @max(1, @as(u64, @intFromFloat(@ceil(q * @as(f64, @floatFromInt(total))))));
    var acc: u64 = 0;
    for (h, 0..) |c, b| {
        acc += c;
        if (acc >= need) return bucketMidUs(@intCast(b));
    }
    return bucketMidUs(bucket_count - 1);
}

fn frame(t: i64, n: u32, s5: u32, hist: []const [2]u32) protocol.Stats {
    const routes = std.testing.allocator.alloc(protocol.RouteStat, 1) catch @panic("oom");
    routes[0] = .{ .i = 1, .m = "GET", .p = "/x", .n = n, .s2 = n -% s5, .s5 = s5, .h = hist };
    return .{ .mono_ms = t, .routes = routes, .conns = .{ .total = 5 } };
}

test "stats_window: bucket bounds" {
    try std.testing.expectEqual(@as(u64, 16), bucketBounds(1).lo_us);
    try std.testing.expectEqual(@as(u64, 20), bucketBounds(1).hi_us);
    try std.testing.expectEqual(@as(u64, 1) << 28, bucketBounds(96).hi_us);
    try std.testing.expectEqual(@as(f64, 18), bucketMidUs(1));
    try std.testing.expectEqual(@as(f64, 8), bucketMidUs(0));
}

test "stats_window: deltas across u32 wrap" {
    var w = Window.init(std.testing.allocator);
    defer w.deinit();
    const f1 = frame(0, 4_294_967_290, 0, &.{});
    defer std.testing.allocator.free(f1.routes);
    const f2 = frame(1000, 10, 0, &.{});
    defer std.testing.allocator.free(f2.routes);
    try w.push(f1);
    try w.push(f2);
    const rows = try w.rows(std.testing.allocator, 10_000);
    defer std.testing.allocator.free(rows);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(@as(u32, 16), rows[0].count);
    try std.testing.expectEqual(@as(f64, 16), rows[0].rps);
}

test "stats_window: p50 and p99 are bucket midpoints" {
    var w = Window.init(std.testing.allocator);
    defer w.deinit();
    const f1 = frame(0, 0, 0, &.{});
    defer std.testing.allocator.free(f1.routes);
    // 98 requests in bucket 1 (16..20 us), 2 in bucket 5 (32..40 us).
    const hist = [_][2]u32{ .{ 1, 98 }, .{ 5, 2 } };
    const f2 = frame(1000, 100, 0, &hist);
    defer std.testing.allocator.free(f2.routes);
    try w.push(f1);
    try w.push(f2);
    const rows = try w.rows(std.testing.allocator, 10_000);
    defer std.testing.allocator.free(rows);
    try std.testing.expectEqual(@as(f64, 18), rows[0].p50_us.?);
    try std.testing.expectEqual(@as(f64, 36), rows[0].p99_us.?);
}

test "stats_window: 10 s window drops older frames" {
    var w = Window.init(std.testing.allocator);
    defer w.deinit();
    var t: i64 = 0;
    var n: u32 = 0;
    while (t <= 20_000) : (t += 1000) {
        const f = frame(t, n, 0, &.{});
        defer std.testing.allocator.free(f.routes);
        try w.push(f);
        // 100 requests per second for the first 10 s, then 10 per second.
        n += if (t < 10_000) 100 else 10;
    }
    const rows = try w.rows(std.testing.allocator, 10_000);
    defer std.testing.allocator.free(rows);
    try std.testing.expectEqual(@as(f64, 10), rows[0].rps);
    const all = try w.rows(std.testing.allocator, 60_000);
    defer std.testing.allocator.free(all);
    try std.testing.expect(all[0].rps > 10);
    try std.testing.expectEqual(@as(f64, 10), w.totals(10_000).rps);
}

test "stats_window: totals and 5xx per minute" {
    var w = Window.init(std.testing.allocator);
    defer w.deinit();
    const f1 = frame(0, 0, 0, &.{});
    defer std.testing.allocator.free(f1.routes);
    const f2 = frame(30_000, 300, 6, &.{.{ 1, 300 }});
    defer std.testing.allocator.free(f2.routes);
    try w.push(f1);
    try w.push(f2);
    const t = w.totals(10_000);
    try std.testing.expectEqual(@as(f64, 12), t.err_per_min);
    try std.testing.expectEqual(@as(u32, 5), t.conns);
}
