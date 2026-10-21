//! What the connectors share that is not part of `anole.db`'s API: error
//! recording (`fail`), call timeouts (`bounded`), the pool per executor
//! (`PerExecutor`), and the request behind a context (`requestOf`).
//! The connectors and src/db's own files import this file directly; the
//! root does not re-export it.
const std = @import("std");
const dusty = @import("dusty");
const placement = dusty.placement;
const db = @import("root.zig");

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
    const id = if (comptime @hasField(Pointee(@TypeOf(c)), "id")) c.id else "";
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

    var req: dusty.Request = .{ .arena = arena, .io = testing.io, .parser = undefined, .transport = undefined };
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
    try testing.expectEqual(@as(u8, 7), try bounded(&ctx, .postgresql, .fromSeconds(5), Slow.wait, .{ io, 1 }));
    // It logs a warning, as a 5xx does; not in the test's output.
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    try testing.expectError(error.GatewayTimeout, bounded(&ctx, .postgresql, .fromMilliseconds(20), Slow.wait, .{ io, 10_000 }));
    try testing.expectEqual(db.Class.timeout, db.lastError(&ctx).?.class);
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
