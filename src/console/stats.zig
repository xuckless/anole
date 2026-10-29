//! Per-route request statistics and the 5xx ring (design 6.1 to 6.3).
//!
//! The request path pays one relaxed load while no console collects
//! (`dusty.hooks.collecting`) and one status compare for the 5xx ring. While
//! a console subscribed to `stats`, each request updates five counters and
//! one latency bucket on its executor's own slot (single writer, so plain
//! load-add-store).
const std = @import("std");
const dusty = @import("dusty");
const ui = @import("anole_console_ui");
const safety = @import("anole_safety");
const observe_common = @import("../observe/common.zig");

pub const bucket_count = ui.protocol.bucket_count;

/// Latency bucket of a duration: 0 below 16 us, 97 from 2^28 us (~268 s);
/// between, 4 linear sub-buckets per power of two.
pub fn bucketOf(ns: u64) u8 {
    const us = ns / 1000;
    if (us < 16) return 0;
    if (us >= 1 << 28) return 97;
    const o: u6 = @intCast(63 - @clz(us));
    const sub: u8 = @intCast((us >> (o - 2)) & 3);
    return 1 + (@as(u8, o) - 4) * 4 + sub;
}

const Counter = std.atomic.Value(u32);

/// One route on one executor.
pub const Counters = struct {
    n: Counter = .init(0),
    s2: Counter = .init(0),
    s3: Counter = .init(0),
    s4: Counter = .init(0),
    s5: Counter = .init(0),
    h: [bucket_count]Counter = @splat(.init(0)),
};

/// The sums over executors of one route, wrapping.
pub const Sum = struct {
    n: u32 = 0,
    s2: u32 = 0,
    s3: u32 = 0,
    s4: u32 = 0,
    s5: u32 = 0,
    h: [bucket_count]u32 = @splat(0),
};

pub const ErrorEntry = struct {
    seq: u64 = 0,
    time_ms: i64 = 0,
    status: u16 = 0,
    route_index: u32 = 0,
    duration_us: u64 = 0,
    method_len: u8 = 0,
    path_len: u8 = 0,
    err_len: u8 = 0,
    rid_len: u8 = 0,
    method: [8]u8 = undefined,
    path: [96]u8 = undefined,
    err: [48]u8 = undefined,
    rid: [40]u8 = undefined,

    pub fn methodStr(self: *const ErrorEntry) []const u8 {
        return self.method[0..self.method_len];
    }
    pub fn pathStr(self: *const ErrorEntry) []const u8 {
        return self.path[0..self.path_len];
    }
    pub fn errStr(self: *const ErrorEntry) []const u8 {
        return self.err[0..self.err_len];
    }
    pub fn ridStr(self: *const ErrorEntry) []const u8 {
        return self.rid[0..self.rid_len];
    }
};

fn copyCut(dst: []u8, src: []const u8) u8 {
    // Keep whole UTF-8 characters.
    var n = @min(dst.len, src.len);
    while (n > 0 and n < src.len and (src[n] & 0xc0) == 0x80) n -= 1;
    @memcpy(dst[0..n], src[0..n]);
    return @intCast(n);
}

/// The recent 5xx answers: a ring under a spin lock held for the copy only.
pub const ErrorRing = struct {
    /// Over the fields below; held for a bounded struct copy only.
    lock: safety.SpinLock(.leaf) = .init,
    entries: []ErrorEntry,
    /// Entries ever pushed.
    seq: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, n: usize) !ErrorRing {
        return .{ .entries = try gpa.alloc(ErrorEntry, @max(n, 1)) };
    }

    pub fn deinit(self: *ErrorRing, gpa: std.mem.Allocator) void {
        gpa.free(self.entries);
    }

    pub fn push(self: *ErrorRing, e: ErrorEntry) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.seq += 1;
        var x = e;
        x.seq = self.seq;
        self.entries[@intCast((self.seq - 1) % self.entries.len)] = x;
    }

    /// Copies up to `out.len` newest entries, newest last; returns how many.
    pub fn copyRecent(self: *ErrorRing, out: []ErrorEntry) usize {
        self.lock.lock();
        defer self.lock.unlock();
        const have: usize = @intCast(@min(self.seq, self.entries.len));
        const n = @min(have, out.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const s = self.seq - n + i + 1;
            out[i] = self.entries[@intCast((s - 1) % self.entries.len)];
        }
        return n;
    }

    /// Entries with seq > `after`, oldest first, up to `out.len`.
    pub fn copyAfter(self: *ErrorRing, after: u64, out: []ErrorEntry) usize {
        self.lock.lock();
        defer self.lock.unlock();
        const oldest: u64 = if (self.seq > self.entries.len) self.seq - self.entries.len else 0;
        var s = @max(after, oldest) + 1;
        var n: usize = 0;
        while (s <= self.seq and n < out.len) : (s += 1) {
            out[n] = self.entries[@intCast((s - 1) % self.entries.len)];
            n += 1;
        }
        return n;
    }

    pub fn current(self: *ErrorRing) u64 {
        self.lock.lock();
        defer self.lock.unlock();
        return self.seq;
    }
};

pub const Stats = struct {
    gpa: std.mem.Allocator,
    executors: u32,
    /// Slots per executor: no route (0), routes 1..max_routes, other routes.
    route_slots: u32,
    max_routes: u32,
    /// Published once by `ensureTables` (compare and swap), freed only by
    /// `deinit` (process-wide).
    tables: std.atomic.Value(?[*]Counters) = .init(null),
    errors: ErrorRing,

    pub fn init(gpa: std.mem.Allocator, executors: u32, max_routes: u32, errors_kept: u32) !Stats {
        return .{
            .gpa = gpa,
            .executors = @max(executors, 1),
            .route_slots = max_routes + 2,
            .max_routes = max_routes,
            .errors = try ErrorRing.init(gpa, errors_kept),
        };
    }

    pub fn deinit(self: *Stats) void {
        if (self.tables.load(.acquire)) |t| self.gpa.free(t[0..self.tableLen()]);
        self.errors.deinit(self.gpa);
    }

    fn tableLen(self: *const Stats) usize {
        return @as(usize, self.executors + 1) * self.route_slots;
    }

    /// Allocates the counters on first use (the first `stats` subscription):
    /// a table made with no lock held is published by compare and swap, and
    /// the thread that loses the race frees its own.
    pub fn ensureTables(self: *Stats) !void {
        if (self.tables.load(.acquire) != null) return;
        const t = try self.gpa.alloc(Counters, self.tableLen());
        for (t) |*c| c.* = .{};
        if (self.tables.cmpxchgStrong(null, t.ptr, .acq_rel, .acquire) != null) self.gpa.free(t);
    }

    /// The slot index of a route for counting: 0 no route, past
    /// `max_routes` the shared "other routes" slot.
    pub fn routeSlot(self: *const Stats, route_index: u32) u32 {
        if (route_index == 0) return 0;
        if (route_index > self.max_routes) return self.max_routes + 1;
        return route_index;
    }

    /// Counts one finished request. `exec` is the executor's index, null for
    /// a thread that is none (the shared slot, atomic adds).
    pub fn count(self: *Stats, exec: ?usize, route_index: u32, status: u16, ns: u64) void {
        const t = self.tables.load(.acquire) orelse return;
        const shared = exec == null or exec.? >= self.executors;
        const e: usize = if (shared) self.executors else exec.?;
        const c = &t[e * self.route_slots + self.routeSlot(route_index)];
        const b = bucketOf(ns);
        if (shared) {
            _ = c.n.fetchAdd(1, .monotonic);
            _ = statusCounter(c, status).fetchAdd(1, .monotonic);
            _ = c.h[b].fetchAdd(1, .monotonic);
        } else {
            bump(&c.n);
            bump(statusCounter(c, status));
            bump(&c.h[b]);
        }
    }

    inline fn bump(c: *Counter) void {
        c.store(c.load(.monotonic) +% 1, .monotonic);
    }

    fn statusCounter(c: *Counters, status: u16) *Counter {
        return switch (status / 100) {
            2 => &c.s2,
            3 => &c.s3,
            4 => &c.s4,
            5 => &c.s5,
            else => &c.s2,
        };
    }

    /// The wrapping sums over executors of route slot `slot`.
    pub fn sum(self: *const Stats, slot: u32) Sum {
        var s: Sum = .{};
        const t = self.tables.load(.acquire) orelse return s;
        var e: u32 = 0;
        while (e <= self.executors) : (e += 1) {
            const c = &t[@as(usize, e) * self.route_slots + slot];
            s.n +%= c.n.load(.monotonic);
            s.s2 +%= c.s2.load(.monotonic);
            s.s3 +%= c.s3.load(.monotonic);
            s.s4 +%= c.s4.load(.monotonic);
            s.s5 +%= c.s5.load(.monotonic);
            for (&s.h, 0..) |*h, i| h.* +%= c.h[i].load(.monotonic);
        }
        return s;
    }

    pub fn recordError(self: *Stats, req: *const dusty.Request, status: u16, err: ?anyerror, duration_ns: u64, now_ms: i64) void {
        var e: ErrorEntry = .{ .time_ms = now_ms, .status = status, .duration_us = duration_ns / 1000 };
        e.route_index = if (req.route) |r| r.index else 0;
        var mb: [16]u8 = undefined;
        const m = std.fmt.bufPrint(&mb, "{f}", .{req.method}) catch "?";
        e.method_len = copyCut(&e.method, m);
        const path = if (std.mem.indexOfScalar(u8, req.url, '?')) |q| req.url[0..q] else req.url;
        e.path_len = copyCut(&e.path, path);
        if (err) |x| e.err_len = copyCut(&e.err, @errorName(x));
        e.rid_len = copyCut(&e.rid, req.id);
        self.errors.push(e);
    }
};

// ------------------------------------------------------------ the hook

/// What the installed hook records into. Set by `Console.start`.
pub var global: ?*Stats = null;

/// `dusty.hooks.request_end`: when the answer is known (a detached
/// response's at its finish). `start_ns` is non-zero only while a console
/// collects; with 0 the answer may be a 5xx (the core calls nothing else
/// while nobody collects).
pub fn requestEnd(req: *dusty.Request, res: *dusty.Response, err: ?anyerror, answered: ?anyerror, start_ns: u64) void {
    const st = global orelse return;
    const result: anyerror!void = if (err) |e| e else {};
    const status = observe_common.statusOf(req, res, result);
    const dur: u64 = if (start_ns != 0) dusty.hooks.now(req.io) -% start_ns else 0;
    if (status >= 500) {
        const now_ms = std.Io.Clock.real.now(req.io).toMilliseconds();
        st.recordError(req, status, err orelse answered, dur, now_ms);
    }
    if (start_ns != 0) {
        const ri: u32 = if (req.route) |r| r.index else 0;
        st.count(dusty.placement.currentExecutor(req.io), ri, status, dur);
    }
}

pub fn install(st: *Stats) void {
    global = st;
    dusty.hooks.request_end = requestEnd;
}

pub fn uninstall() void {
    dusty.hooks.request_end = null;
    global = null;
}

/// Subscribers of the `stats` stream: counters allocate on the first.
pub fn collectStart(st: *Stats) !void {
    try st.ensureTables();
    _ = dusty.hooks.collecting.fetchAdd(1, .monotonic);
}

pub fn collectStop() void {
    _ = dusty.hooks.collecting.fetchSub(1, .monotonic);
}

// ------------------------------------------------------------------ tests

test "stats: bucketOf boundaries" {
    try std.testing.expectEqual(@as(u8, 0), bucketOf(15 * 1000));
    try std.testing.expectEqual(@as(u8, 1), bucketOf(16 * 1000));
    try std.testing.expectEqual(@as(u8, 1), bucketOf(19 * 1000));
    try std.testing.expectEqual(@as(u8, 2), bucketOf(20 * 1000));
    try std.testing.expectEqual(@as(u8, 4), bucketOf(31 * 1000));
    try std.testing.expectEqual(@as(u8, 5), bucketOf(32 * 1000));
    try std.testing.expectEqual(@as(u8, 96), bucketOf((@as(u64, 1 << 28) - 1) * 1000));
    try std.testing.expectEqual(@as(u8, 97), bucketOf(@as(u64, 1 << 28) * 1000));
}

test "stats: bucket bounds round-trip with the client's table" {
    var b: u8 = 1;
    while (b <= 96) : (b += 1) {
        const r = ui.stats_window.bucketBounds(b);
        try std.testing.expectEqual(b, bucketOf(r.lo_us * 1000));
        try std.testing.expectEqual(b, bucketOf((r.hi_us - 1) * 1000));
    }
}

test "stats: nothing recorded without tables; per-executor sums; other routes" {
    var st = try Stats.init(std.testing.allocator, 2, 3, 16);
    defer st.deinit();
    st.count(0, 1, 200, 20_000);
    try std.testing.expectEqual(@as(u32, 0), st.sum(1).n);
    try st.ensureTables();
    st.count(0, 1, 200, 20_000);
    st.count(1, 1, 503, 40_000);
    st.count(null, 1, 404, 1_000);
    st.count(0, 0, 404, 1_000); // no route
    st.count(0, 9, 200, 1_000); // past max_routes: the other slot
    const s = st.sum(1);
    try std.testing.expectEqual(@as(u32, 3), s.n);
    try std.testing.expectEqual(@as(u32, 1), s.s2);
    try std.testing.expectEqual(@as(u32, 1), s.s4);
    try std.testing.expectEqual(@as(u32, 1), s.s5);
    try std.testing.expectEqual(@as(u32, 1), st.sum(0).n);
    try std.testing.expectEqual(@as(u32, 1), st.sum(4).n);
}

test "stats: the 5xx ring wraps at its size and reads after a sequence" {
    var ring = try ErrorRing.init(std.testing.allocator, 4);
    defer ring.deinit(std.testing.allocator);
    var i: u16 = 0;
    while (i < 6) : (i += 1) ring.push(.{ .status = 500 + i });
    var out: [8]ErrorEntry = undefined;
    const n = ring.copyRecent(&out);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqual(@as(u16, 502), out[0].status);
    try std.testing.expectEqual(@as(u16, 505), out[3].status);
    const m = ring.copyAfter(4, &out);
    try std.testing.expectEqual(@as(usize, 2), m);
    try std.testing.expectEqual(@as(u64, 5), out[0].seq);
}
