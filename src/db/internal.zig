//! What the connectors share that is not part of `anole.db`'s API: error
//! recording (`fail`), call timeouts (`bounded`), the pool per executor
//! (`PerExecutor`), and the request behind a context (`requestOf`).
//! The connectors and src/db's own files import this file directly; the
//! root does not re-export it.
const std = @import("std");
const dusty = @import("dusty");
const placement = dusty.placement;
const db = @import("root.zig");
const resilience = @import("../resilience/root.zig");
const obs = @import("../observe/root.zig");

const ErrorDetail = db.ErrorDetail;
const ErrorMap = db.ErrorMap;
const Error = db.Error;
const System = db.System;

const log = std.log.scoped(.anole);

// ---------------------------------------------------------------------------
// The caller's context and its last error

/// Where a request keeps its last error.
const last_error_key = "anole.db.last_error";

/// Records `detail` as `c`'s last error (copied into its arena), logs it,
/// and returns the `Error` that `map` gives its class: what a connector
/// returns for any server error.
///
///     return internal.fail(req, self.errors, .{ .system = .postgresql, .class = .unique,
///         .code = "23505", .message = msg, .constraint = name });
///
/// 5xx classes are logged at warn, the rest at debug: a 404 or a 409 is
/// the client's doing.
pub fn fail(c: anytype, map: ErrorMap, detail: ErrorDetail) Error {
    const err = map.errorFor(detail.class);
    record(c, detail, err);
    return err;
}

fn record(c: anytype, detail: ErrorDetail, err: Error) void {
    keepError(c, detail);
    const kept = lastError(c).?;
    const id: []const u8 = if (comptime @hasField(Pointee(@TypeOf(c)), "id") and @FieldType(Pointee(@TypeOf(c)), "id") == []const u8) c.id else "";
    switch (err) {
        error.Database, error.ServiceUnavailable, error.GatewayTimeout => log.warn("{s}{s}database error: {f}", .{ id, if (id.len > 0) " " else "", kept }),
        else => log.debug("{s}{s}database error: {f}", .{ id, if (id.len > 0) " " else "", kept }),
    }
}

/// Records `detail` as `c`'s last error (copied into its arena) without
/// logging it: for a failure that was logged where it happened, such as
/// a shared call's (`QueryOptions.coalesce`) for each caller.
pub fn keepError(c: anytype, detail: ErrorDetail) void {
    comptime checkContext(@TypeOf(c));
    const kept = dupe(detail, c.arena) catch ErrorDetail{ .system = detail.system, .class = detail.class, .message = "(detail lost: out of memory)" };
    if (comptime hasLocals(@TypeOf(c))) {
        c.locals.put(c.arena, last_error_key, kept) catch {};
    } else {
        c.last_error = kept;
    }
}

/// `anole.db.lastError`.
pub fn lastError(c: anytype) ?ErrorDetail {
    comptime checkContext(@TypeOf(c));
    if (comptime hasLocals(@TypeOf(c))) return c.locals.get(ErrorDetail, last_error_key);
    return c.last_error;
}

/// Where a request keeps its last shared call's source.
const last_source_key = "anole.db.last_source";

/// Records where a shared call's answer came from, for `lastSource`. A
/// context without room for it (a test's own) is left alone.
pub fn keepSource(c: anytype, source: db.Source) void {
    if (comptime hasLocals(@TypeOf(c))) {
        // In place after the first: no allocation per call.
        if (c.locals.getPtr(db.Source, last_source_key)) |p| {
            p.* = source;
        } else c.locals.put(c.arena, last_source_key, source) catch {};
    } else if (comptime @hasField(Pointee(@TypeOf(c)), "last_source")) {
        c.last_source = source;
    }
}

/// `anole.db.lastSource`.
pub fn lastSource(c: anytype) ?db.Source {
    comptime checkContext(@TypeOf(c));
    if (comptime hasLocals(@TypeOf(c))) return c.locals.get(db.Source, last_source_key);
    if (comptime @hasField(Pointee(@TypeOf(c)), "last_source")) return c.last_source;
    return null;
}

fn dupe(detail: ErrorDetail, arena: std.mem.Allocator) !ErrorDetail {
    var out = detail;
    out.code = try arena.dupe(u8, detail.code);
    out.message = try arena.dupe(u8, detail.message);
    if (detail.constraint) |v| out.constraint = try arena.dupe(u8, v);
    if (detail.table) |v| out.table = try arena.dupe(u8, v);
    return out;
}

fn Pointee(comptime C: type) type {
    return switch (@typeInfo(C)) {
        .pointer => |p| p.child,
        else => C,
    };
}

fn hasLocals(comptime C: type) bool {
    return @hasField(Pointee(C), "locals");
}

fn checkContext(comptime C: type) void {
    const T = Pointee(C);
    if (@typeInfo(C) != .pointer or @typeInfo(T) != .@"struct" or !@hasField(T, "io") or !@hasField(T, "arena") or
        !(@hasField(T, "locals") or @hasField(T, "last_error")))
        @compileError("anole.db: a call takes the request (*anole.Request) or a *anole.db.Ctx, not " ++ @typeName(C));
}

/// The request behind `c`, for its trace context; null for a `Ctx`.
pub fn requestOf(c: anytype) ?*const dusty.Request {
    if (comptime Pointee(@TypeOf(c)) == dusty.Request) return c;
    return null;
}

// ---------------------------------------------------------------------------
// Timeouts

/// What `bounded(c, ..., func, args)` returns: `func`'s result, with the
/// timeout's errors added.
pub fn Bounded(comptime func: anytype) type {
    const R = dusty.Deadline.Result(func);
    const eu = @typeInfo(R).error_union;
    return (eu.error_set || error{GatewayTimeout})!eu.payload;
}

/// The bound a call runs under: its own, else the connector's; `.max` is none.
pub fn callTimeout(call: ?std.Io.Duration, connector: ?std.Io.Duration) ?std.Io.Duration {
    const t = call orelse connector orelse return null;
    return if (t.nanoseconds == std.Io.Duration.max.nanoseconds) null else t;
}

/// Runs `func(args...)` under `timeout` (a call's `QueryOptions.timeout`);
/// null runs it as it is. Past it, the call is canceled where it waits,
/// which `func` handles as any cancel (leaving the connection reset or
/// closed), and `bounded` fails with `error.GatewayTimeout`, recorded for
/// `lastError` with class `timeout`.
pub fn bounded(c: anytype, system: System, timeout: ?std.Io.Duration, func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) Bounded(func) {
    const d = timeout orelse return @call(.auto, func, args);
    const deadline: dusty.Deadline = .init(c.io, .{ .duration = .{ .raw = d, .clock = .awake } });
    return deadline.run(func, args) catch |err| switch (err) {
        error.Timeout => {
            record(c, .{ .system = system, .class = .timeout, .message = "the call ran past its timeout" }, error.GatewayTimeout);
            return error.GatewayTimeout;
        },
        else => |e| return e,
    };
}

// ---------------------------------------------------------------------------
// Breaker and retry

/// What a connector keeps for breaking and retrying. Pin it (the metrics
/// hooks point into it): a connector makes it in `init`, on the heap.
pub const Guard = struct {
    system: System,
    breaker: ?resilience.Breaker,
    retry: resilience.Retry,
    throttle: resilience.Throttle,
    binding: ?resilience.Binding = null,

    /// SQLite has no network to fail: its breaker is always off.
    pub fn init(system: System, name: []const u8, breaker: ?resilience.Breaker.Options, retry: resilience.Retry) error{InvalidOptions}!Guard {
        try retry.validate();
        if (breaker) |o| try o.validate();
        const kind: resilience.Kind = switch (system) {
            .postgresql => .postgresql,
            .mongodb => .mongodb,
            .redis => .redis,
            .nats => .nats,
            .kafka => .kafka,
            .s3 => .s3,
            .smtp => .smtp,
            .sqlite => .postgresql,
        };
        return .{
            .system = system,
            .breaker = if (breaker != null and system != .sqlite) resilience.Breaker.init(breaker.?, kind, name) else null,
            .retry = retry,
            .throttle = .init(retry.throttle orelse .{}),
        };
    }

    /// Reports the breaker and the retries to `registry`; once serving
    /// has started the guard must not move.
    pub fn observe(g: *Guard, gpa: std.mem.Allocator, registry: ?*obs.metrics.Registry) !void {
        const r = registry orelse return;
        g.binding = try resilience.Binding.init(gpa, r);
        if (g.breaker) |*b| b.observe(g.binding.?.metricsHooks());
    }

    pub fn deinit(g: *Guard) void {
        if (g.binding) |*b| b.deinit();
    }
};

/// A connector's own context type (pg's erased `Ctx`) may carry `fail` and
/// `lastDetail`; a request or `db.Ctx` goes through `fail`/`lastError`.
fn failIn(c: anytype, map: ErrorMap, detail: ErrorDetail) Error {
    if (comptime @hasDecl(Pointee(@TypeOf(c)), "lastDetail")) return c.fail(map, detail);
    return fail(c, map, detail);
}

fn lastIn(c: anytype) ?ErrorDetail {
    if (comptime @hasDecl(Pointee(@TypeOf(c)), "lastDetail")) return c.lastDetail();
    return lastError(c);
}

/// What a guarded call returns: what `func` returns.
pub fn Guarded(comptime func: anytype) type {
    return @typeInfo(@TypeOf(func)).@"fn".return_type.?;
}

/// Whether `Retry.attempt_timeout` can bound `func`'s attempts: its errors
/// include GatewayTimeout (the bound's error) and `record` can name the
/// failure (a connector with its own context type records itself).
fn canBoundAttempt(comptime func: anytype) bool {
    const R = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
    const eu = switch (@typeInfo(R)) {
        .error_union => |e| e,
        else => return false,
    };
    const names = @typeInfo(eu.error_set).error_set.error_names orelse return true;
    var timeout = false;
    var canceled = false;
    inline for (names) |n| {
        if (comptime std.mem.eql(u8, n, "GatewayTimeout")) timeout = true;
        if (comptime std.mem.eql(u8, n, "Canceled")) canceled = true;
    }
    return timeout and canceled;
}

/// Runs `func(args)` (a connector's call, already `bounded`) under the
/// guard: breaker gate, and with `retry` the policy. A rejected call fails
/// with `fail(c, map, ...)`: class `unavailable`, code "circuit_open".
/// The verdict comes from `lastError(c)` after a failure: class
/// `unavailable` with a code other than "pool_timeout" is transient
/// (retried only when `retry`), anything else is neutral (the server
/// answered). A success is a success.
pub fn guarded(c: anytype, g: *Guard, map: ErrorMap, retry: bool, deadline: ?std.Io.Clock.Timestamp, func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) Guarded(func) {
    if (g.breaker == null and !retry) return @call(.auto, func, args);
    const io = c.io;
    var n: u32 = 1;
    while (true) : (n += 1) {
        const now = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        var permit: ?resilience.Breaker.Permit = null;
        if (g.breaker) |*b| {
            permit = b.allow(now) orelse {
                var buf: [160]u8 = undefined;
                const left: i96 = if (b.openUntil()) |u| @max(0, u - now) else 0;
                const msg = std.fmt.bufPrint(&buf, "circuit breaker open after repeated connection failures; next try in {d} s", .{@divTrunc(left + std.time.ns_per_s - 1, std.time.ns_per_s)}) catch "circuit breaker open";
                return failIn(c, map, .{ .system = g.system, .class = .unavailable, .code = "circuit_open", .message = msg });
            };
        }
        var attempt_timed_out = false;
        const r = if (comptime canBoundAttempt(func)) blk: {
            const at = (if (retry) g.retry.attempt_timeout else null) orelse break :blk @call(.auto, func, args);
            const dl: dusty.Deadline = .init(io, .{ .duration = .{ .raw = at, .clock = .awake } });
            break :blk dl.run(func, args) catch |err| switch (err) {
                error.Timeout => {
                    attempt_timed_out = true;
                    break :blk failIn(c, map, .{ .system = g.system, .class = .timeout, .message = "the attempt ran past its attempt_timeout" });
                },
                else => |e| break :blk e,
            };
        } else @call(.auto, func, args);
        const transient = if (r) |_| false else |_| blk: {
            if (attempt_timed_out) break :blk true;
            const d = lastIn(c) orelse break :blk false;
            break :blk d.class == .unavailable and !std.mem.eql(u8, d.code, "pool_timeout") and !std.mem.eql(u8, d.code, "circuit_open");
        };
        const failed = if (r) |_| false else |_| transient;
        if (permit) |p| g.breaker.?.record(p, if (failed) .failure else if (r) |_| .success else |_| .neutral, std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds);
        if (retry) {
            if (failed) g.throttle.onFailure() else if (r) |_| g.throttle.onSuccess() else |_| {}
        }
        if (!failed or !retry or n >= g.retry.attempts or !g.throttle.allowRetry()) return r;
        var rb: [8]u8 = undefined;
        io.random(&rb);
        const wait = g.retry.backoff.delay(n, std.mem.readInt(u64, &rb, .little));
        const after = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        if (deadline) |d| if (after + wait.nanoseconds >= d.raw.nanoseconds) return r;
        if (g.binding) |*bd| {
            const h = bd.metricsHooks();
            h.on_retry(h.context, if (g.breaker) |b| b.kind else .postgresql, if (g.breaker) |*b| b.name() else "", "transport");
        }
        io.sleep(wait, .awake) catch {
            io.recancel();
            return r;
        };
    }
}

// ---------------------------------------------------------------------------
// Pools

/// The index of the calling task's executor, or null off zio's executors
/// (`std.Io.Threaded`, a thread of zio's blocking pool).
pub fn executorIndex(io: std.Io) ?usize {
    return placement.currentExecutor(io);
}

/// How many executors `io`'s runtime has; 1 off zio.
pub fn executorCount(io: std.Io) usize {
    return placement.executorCount(io) orelse 1;
}

/// Part `index` of `total` connections split over `parts` pools: the
/// parts add up to `total`, and differ by one at most. Each pool gets at
/// least one, so with fewer connections than pools the total becomes the
/// number of pools.
pub fn split(total: usize, parts: usize, index: usize) usize {
    std.debug.assert(parts > 0 and index < parts);
    if (total <= parts) return 1;
    return total / parts + @intFromBool(index < total % parts);
}

/// One `Pool` per executor of the runtime, so a task only ever takes
/// connections from its own executor's pool: no lock is contended across
/// threads, and a connection stays with the executor its tasks run on.
/// The connection limit is split between them (`share`); a busy executor
/// does not borrow from an idle one.
///
///     var pools = try internal.PerExecutor(Pool).init(gpa, io);
///     for (pools.pools, 0..) |*p, i| p.* = Pool.init(.{ .max = pools.share(opts.max_connections, i) });
///     ...
///     const pool = pools.get(req.io);
///
/// `Pool` must still be safe to use from any task (`std.Io.Mutex`, not
/// thread-unsafe state): calls from outside the executors (a blocking-pool
/// thread, `std.Io.Threaded`) all use pool 0.
pub fn PerExecutor(comptime Pool: type) type {
    return struct {
        const Self = @This();

        /// By executor index; undefined until the connector sets each.
        pools: []Pool,

        /// One slot per executor of `io`'s runtime (one off zio).
        pub fn init(gpa: std.mem.Allocator, io: std.Io) error{OutOfMemory}!Self {
            return .{ .pools = try gpa.alloc(Pool, executorCount(io)) };
        }

        /// Frees the slots; the connector closes each pool first.
        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            gpa.free(self.pools);
            self.* = undefined;
        }

        /// Pool `index`'s part of `total` connections (`split`).
        pub fn share(self: *const Self, total: usize, index: usize) usize {
            return split(total, self.pools.len, index);
        }

        /// The pool of the executor the calling task runs on.
        pub fn get(self: *const Self, io: std.Io) *Pool {
            const index = executorIndex(io) orelse 0;
            return &self.pools[index % self.pools.len];
        }
    };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "fail and lastError: on a Ctx and on a request, copied into the arena" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ctx: db.Ctx = .{ .io = testing.io, .arena = arena };
    try testing.expect(db.lastError(&ctx) == null);
    var message = "duplicate key value violates unique constraint \"users_email_key\"".*;
    const err = fail(&ctx, .{}, .{ .system = .postgresql, .class = .unique, .code = "23505", .message = &message, .constraint = "users_email_key" });
    try testing.expectEqual(error.Conflict, err);
    // The connector's buffer may be reused at once.
    @memset(&message, 'x');
    const detail = db.lastError(&ctx).?;
    try testing.expectEqualStrings("23505", detail.code);
    try testing.expectStringStartsWith(detail.message, "duplicate key");
    try testing.expectEqualStrings("users_email_key", detail.constraint.?);
    try testing.expect(!db.retryable(&ctx, err));

    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "postgresql 23505 (unique): duplicate key value violates unique constraint \"users_email_key\" [constraint users_email_key]",
        try std.fmt.bufPrint(&buf, "{f}", .{detail}),
    );

    var req: dusty.Request = .{ .arena = arena, .io = testing.io, ._parser = undefined, ._transport = undefined };
    try testing.expect(db.lastError(&req) == null);
    const lost = fail(&req, .{}, .{ .system = .postgresql, .class = .serialization, .code = "40001", .message = "could not serialize access" });
    try testing.expectEqual(error.Conflict, lost);
    try testing.expectEqual(db.Class.serialization, db.lastError(&req).?.class);
    try testing.expect(db.retryable(&req, lost));
    try testing.expect(!db.retryable(&req, error.Database));
    try testing.expect(requestOf(&req) == &req);
    try testing.expect(requestOf(&ctx) == null);
}

test "bounded: past its timeout a call is canceled and fails with GatewayTimeout" {
    const zio = @import("zio");
    const rt = try zio.Runtime.init(testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var ctx: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };

    const Slow = struct {
        fn wait(_io: std.Io, ms: i64) error{Gone}!u8 {
            _io.sleep(.fromMilliseconds(ms), .awake) catch return error.Gone;
            return 7;
        }
    };
    try testing.expectEqual(@as(u8, 7), try bounded(&ctx, .postgresql, null, Slow.wait, .{ io, 1 }));
    // A 1 ms call well inside its timeout (the wait helper's deadline, a
    // hang guard): it is not canceled.
    try testing.expectEqual(@as(u8, 7), try bounded(&ctx, .postgresql, @import("anole_test_wait").deadline(), Slow.wait, .{ io, 1 }));
    // It logs a warning, as a 5xx does; not in the test's output.
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    try testing.expectError(error.GatewayTimeout, bounded(&ctx, .postgresql, .fromMilliseconds(20), Slow.wait, .{ io, 10_000 }));
    try testing.expectEqual(db.Class.timeout, db.lastError(&ctx).?.class);
}

test "db: callTimeout" {
    const D = std.Io.Duration;
    try std.testing.expectEqual(@as(i96, 5 * std.time.ns_per_s), internal_ns(callTimeout(D.fromSeconds(5), D.fromSeconds(30))));
    try std.testing.expectEqual(@as(i96, 30 * std.time.ns_per_s), internal_ns(callTimeout(null, D.fromSeconds(30))));
    try std.testing.expect(callTimeout(D.max, D.fromSeconds(30)) == null);
    try std.testing.expect(callTimeout(null, null) == null);
}

fn internal_ns(d: ?std.Io.Duration) i96 {
    return d.?.nanoseconds;
}

test "split: the parts add up, differ by one at most, and none is empty" {
    for ([_]usize{ 1, 2, 3, 4, 7, 16 }) |parts| {
        for ([_]usize{ 0, 1, 3, 4, 10, 17, 100 }) |total| {
            var sum: usize = 0;
            var lo: usize = std.math.maxInt(usize);
            var hi: usize = 0;
            for (0..parts) |i| {
                const n = split(total, parts, i);
                sum += n;
                lo = @min(lo, n);
                hi = @max(hi, n);
            }
            try testing.expect(lo >= 1 and hi - lo <= 1);
            try testing.expectEqual(@max(total, parts), sum);
        }
    }
}

test "PerExecutor: on 4 pinned executors each task gets its own executor's pool" {
    const zio = @import("zio");
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(4) });
    defer rt.deinit();
    const io = rt.io();

    // A pool that records which executors used it.
    const Pool = struct {
        index: usize,
        limit: usize,
        users: std.atomic.Value(u64) = .init(0),
    };
    var pools = try PerExecutor(Pool).init(gpa, io);
    defer pools.deinit(gpa);
    try testing.expectEqual(@as(usize, 4), pools.pools.len);
    for (pools.pools, 0..) |*p, i| p.* = .{ .index = i, .limit = pools.share(10, i) };
    try testing.expectEqual(@as(usize, 3), pools.pools[0].limit);
    try testing.expectEqual(@as(usize, 2), pools.pools[3].limit);

    const Worker = struct {
        fn run(p: *const PerExecutor(Pool), _io: std.Io, rounds: usize, wrong: *std.atomic.Value(u32)) std.Io.Cancelable!void {
            for (0..rounds) |_| {
                const here = executorIndex(_io) orelse 99;
                const pool = p.get(_io);
                if (here != pool.index) _ = wrong.fetchAdd(1, .monotonic);
                _ = pool.users.fetchOr(@as(u64, 1) << @intCast(pool.index), .monotonic);
                try _io.sleep(.fromMicroseconds(100), .awake);
            }
        }
    };
    var wrong: std.atomic.Value(u32) = .init(0);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (0..16) |i| try placement.concurrent(&group, io, .{ .executor = i % 4 }, Worker.run, .{ &pools, io, 20, &wrong });
    try group.await(io);
    try testing.expectEqual(@as(u32, 0), wrong.load(.monotonic));
    // Every pool was used, each by its own executor alone.
    for (pools.pools, 0..) |*p, i| try testing.expectEqual(@as(u64, 1) << @intCast(i), p.users.load(.monotonic));

    // Off the executors (a thread of the blocking pool): pool 0.
    const off = try rt.blockingIo().concurrent(struct {
        fn run(p: *const PerExecutor(Pool), _io: std.Io) usize {
            return p.get(_io).index;
        }
    }.run, .{ &pools, rt.blockingIo() });
    var f = off;
    try testing.expectEqual(@as(usize, 0), f.await(io));
}

test "PerExecutor: one pool off zio" {
    var pools = try PerExecutor(u32).init(testing.allocator, testing.io);
    defer pools.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), pools.pools.len);
    try testing.expectEqual(@as(usize, 25), pools.share(25, 0));
    try testing.expect(pools.get(testing.io) == &pools.pools[0]);
}

const guard_test = struct {
    var calls: u32 = 0;
    var mode: enum { down, pool, unique, flaky } = .down;

    fn run(c: *db.Ctx) db.Error!u8 {
        calls += 1;
        switch (mode) {
            .down => return fail(c, .{}, .{ .system = .redis, .class = .unavailable, .code = "conn", .message = "down" }),
            .pool => return fail(c, .{}, .{ .system = .redis, .class = .unavailable, .code = "pool_timeout", .message = "busy" }),
            .unique => return fail(c, .{}, .{ .system = .redis, .class = .unique, .code = "23505", .message = "dup" }),
            .flaky => {
                if (calls < 3) return fail(c, .{}, .{ .system = .redis, .class = .unavailable, .code = "conn", .message = "down" });
                return 7;
            },
        }
    }
};

fn guardCtx(arena: *std.heap.ArenaAllocator) db.Ctx {
    return .{ .io = testing.io, .arena = arena.allocator() };
}

test "guarded: unavailable failures open the breaker; the next call is ServiceUnavailable with code circuit_open and no call" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var ctx = guardCtx(&arena);
    var g: Guard = try .init(.redis, "t", .{ .consecutive_failures = 3 }, .{});
    defer g.deinit();
    guard_test.calls = 0;
    guard_test.mode = .down;
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    for (0..3) |_| try testing.expectError(error.ServiceUnavailable, guarded(&ctx, &g, .{}, false, null, guard_test.run, .{&ctx}));
    try testing.expectEqual(@as(u32, 3), guard_test.calls);
    try testing.expectError(error.ServiceUnavailable, guarded(&ctx, &g, .{}, false, null, guard_test.run, .{&ctx}));
    try testing.expectEqual(@as(u32, 3), guard_test.calls);
    try testing.expectEqualStrings("circuit_open", lastError(&ctx).?.code);
}

test "guarded: pool_timeout and answers from a live server never open it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var ctx = guardCtx(&arena);
    var g: Guard = try .init(.redis, "t", .{ .consecutive_failures = 2 }, .{});
    defer g.deinit();
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    guard_test.calls = 0;
    guard_test.mode = .pool;
    for (0..5) |_| try testing.expectError(error.ServiceUnavailable, guarded(&ctx, &g, .{}, false, null, guard_test.run, .{&ctx}));
    guard_test.mode = .unique;
    for (0..5) |_| try testing.expectError(error.Conflict, guarded(&ctx, &g, .{}, false, null, guard_test.run, .{&ctx}));
    try testing.expectEqual(@as(u32, 10), guard_test.calls);
    try testing.expectEqual(resilience.Breaker.State.closed, g.breaker.?.state());
}

test "guarded: with retry a transient failure is run again until it succeeds; without it, once" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var ctx = guardCtx(&arena);
    var g: Guard = try .init(.redis, "t", null, .{ .attempts = 5, .backoff = .{ .base = .fromMilliseconds(1), .max = .fromMilliseconds(1), .jitter = .none } });
    defer g.deinit();
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    guard_test.mode = .flaky;
    guard_test.calls = 0;
    try testing.expectError(error.ServiceUnavailable, guarded(&ctx, &g, .{}, false, null, guard_test.run, .{&ctx}));
    try testing.expectEqual(@as(u32, 1), guard_test.calls);
    guard_test.calls = 0;
    try testing.expectEqual(@as(u8, 7), try guarded(&ctx, &g, .{}, true, null, guard_test.run, .{&ctx}));
    try testing.expectEqual(@as(u32, 3), guard_test.calls);
}
