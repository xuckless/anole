//! What `QueryOptions.coalesce` and `QueryOptions.cache` do for a
//! connector's reads (`one`, `optional`, `all`), built once here so that
//! every connector gets it by sending those verbs through `Cache.read`:
//!
//!     const posts = try app.db.with(.{ .coalesce = true }).all(Post, req, sql, .{limit});
//!     const top = try app.db.with(.{ .cache = .{ .ttl = .fromSeconds(5), .tag = "posts" } }).all(Post, req, sql, .{});
//!     app.db.cache.invalidate(.{ .tag = "posts" }); // after a write
//!
//! Nothing is shared unless a call asks: a call without either option is
//! the plain call, with nothing added (no key, no lookup, no allocation).
//!
//! Coalescing: identical reads in flight at once on one executor (the
//! same connector, row type, verb, statement and parameters) share one
//! round trip. The statement runs on a task of its own, on that executor;
//! each caller waits for it, under its own deadline and cancellation, and
//! gets its own copy of the rows in its own arena. A caller that is
//! canceled or runs out of time leaves alone: the others still get the
//! rows. When the last one leaves, the statement is canceled (as a plain
//! call's would be), unless its result is to be cached, in which case it
//! runs to the end and fills the cache.
//!
//! Caching: a result is kept per executor for `ttl`, in memory of the
//! executor's own, and copied into the caller's arena on a hit. A miss
//! coalesces, so a stampede of misses runs the statement once per
//! executor. Errors are never kept (`one`'s `NotFound` included; an empty
//! `optional` or `all` is a result and is, unless the call says
//! `.keep_empty = false`). Each executor fills its own cache, so two
//! executors may hold results from different moments, up to `ttl` apart;
//! `invalidate` reaches all of them at once.
//!
//! Each shared call records where its answer came from (`db.Source`:
//! this cache, an identical call in flight, or a round trip of its own),
//! which `anole.db.lastSource(c)` reads back.
const std = @import("std");
const dusty = @import("dusty");
const db = @import("root.zig");
const internal = @import("internal.zig");
const copy = @import("copy.zig");
const store = @import("../cache/store.zig");
const observe_mod = @import("../observe/root.zig");

const placement = dusty.placement;
const Generations = store.Generations;
const log = std.log.scoped(.anole);

/// What a read fails with: the connectors' error set.
pub const ReadError = db.Error || error{ Canceled, OutOfMemory };

/// What a read returns, for telling an empty result from another
/// (`QueryOptions.Cache.keep_empty`). Each runner passed to `Cache.read`
/// names its own as `pub const shape`.
pub const Shape = enum {
    /// One value (`one`, a count): never empty.
    one,
    /// An optional (`optional`): empty when null.
    optional,
    /// A slice of rows (`all`): empty with none.
    all,
    /// Rows under run-time column names (`anole.db.Table`): empty with
    /// no row.
    table,
    /// A reply whose shape is known only at run time (`anole.redis.Reply`):
    /// empty when nil, or an empty array or map.
    reply,
};

/// Whether `out`, a read's result of `shape`, is empty.
fn isEmpty(comptime shape: Shape, out: anytype) bool {
    return switch (shape) {
        .one => false,
        .optional => out == null,
        .all => out.len == 0,
        .table => out.rows.len == 0,
        .reply => switch (out) {
            .nil => true,
            .array, .map => |items| items.len == 0,
            else => false,
        },
    };
}

/// A connector's cache bounds (`Options.cache` of each connector): totals
/// over every executor, each executor getting its share.
pub const Options = struct {
    /// Results kept at most.
    max_entries: usize = 4096,
    /// Bytes the kept results take at most (rows, strings, keys); a
    /// result larger than an executor's share is not kept.
    max_bytes: usize = 32 << 20,
};

/// What `invalidate` drops.
pub const Target = union(enum) {
    /// Every result.
    all,
    /// The results cached with `QueryOptions.Cache.tag` this tag.
    tag: []const u8,
};

/// A connector's coalescing and result cache: the `cache` field of its
/// handle (`app.db.cache`).
pub const Cache = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    system: db.System,
    name: []const u8,
    locals: store.PerExecutor(Local),
    gens: Generations = .{},
    metrics: ?store.Metrics = null,

    const Local = struct {
        store: store.Store,
        /// Calls in flight that identical ones may join, by key.
        flights: std.StringHashMapUnmanaged(*Flight) = .empty,
        /// Where a call's key is built: reused, never held across a wait.
        key: std.Io.Writer.Allocating,
        /// The statements' tasks.
        group: std.Io.Group = .init,
    };

    /// `name` (the connector's) must outlive the cache.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, system: db.System, name: []const u8, opts: Options) !Cache {
        const locals: store.PerExecutor(Local) = try .init(gpa, io);
        const n = locals.items.len;
        for (locals.items, 0..) |*l, i| l.* = .{
            .store = .init(gpa, if (opts.max_entries == 0) 0 else internal.split(opts.max_entries, n, i), internal.split(opts.max_bytes, n, i)),
            .key = .init(gpa),
        };
        return .{ .gpa = gpa, .io = io, .system = system, .name = name, .locals = locals };
    }

    /// After the server drained: stops the statements still running for
    /// the cache alone, and frees what is kept.
    pub fn deinit(self: *Cache) void {
        for (self.locals.items) |*l| {
            l.group.cancel(self.io);
            // Each statement's task freed its own flight on the way out.
            l.flights.deinit(self.gpa);
            l.store.deinit();
            l.key.deinit();
        }
        self.locals.deinit(self.gpa);
    }

    /// Reports to `registry` (`anole_cache_*{kind="db",name}`), from the
    /// connector's `start`.
    pub fn observe(self: *Cache, registry: ?*observe_mod.metrics.Registry) !void {
        const r = registry orelse return;
        if (self.metrics != null) return;
        self.metrics = try .init(r, "db", self.name);
        for (self.locals.items) |*l| self.metrics.?.attach(&l.store);
    }

    /// Every executor's counters, added up.
    pub fn stats(self: *const Cache) store.Totals {
        var t: store.Totals = .{};
        for (self.locals.items) |*l| t.add(&l.store.stats);
        return t;
    }

    /// Drops cached results, on every executor at once, and keeps calls
    /// from joining one in flight that started before: what a write calls
    /// once it has committed. `.all`, or `.{ .tag = "posts" }` for the
    /// results cached with that tag.
    pub fn invalidate(self: *Cache, target: Target) void {
        switch (target) {
            .all => self.gens.invalidateAll(),
            .tag => |t| self.gens.invalidateTag(t),
        }
    }

    /// Drops the cached results of `sql` with `args`, whatever verb and
    /// row type read them.
    pub fn invalidateQuery(self: *Cache, sql: []const u8, args: anytype) void {
        if (comptime !copy.encodable(@TypeOf(args))) return self.gens.invalidateAll();
        var buf: [256]u8 = undefined;
        var h: std.Io.Writer.Hashing(std.hash.Wyhash) = .initHasher(.init(0), &buf);
        writeBody(&h.writer, sql, args) catch unreachable;
        h.writer.flush() catch unreachable;
        self.gens.invalidateKey(h.hasher.final());
    }

    /// A read (`one`, `optional`, `all`), shared as `opts` asks:
    /// `runner.run(c, sql, args)` makes the plain call, with `c` the
    /// caller's context, or a `*anole.db.Ctx` of a statement's own task
    /// when the call is shared; `@TypeOf(runner).shape` is the verb's
    /// `Shape`. `Out` is what the verb returns. A shared call records its
    /// `db.Source` for `lastSource`.
    pub fn read(self: *Cache, comptime Out: type, c: anytype, opts: db.QueryOptions, sql: []const u8, args: anytype, runner: anytype) ReadError!Out {
        if (!opts.coalesce and opts.cache == null) return runner.run(c, sql, args);
        return self.shared(Out, c, opts, sql, args, runner);
    }

    fn shared(self: *Cache, comptime Out: type, c: anytype, opts: db.QueryOptions, sql: []const u8, args: anytype, runner: anytype) ReadError!Out {
        const Args = @TypeOf(args);
        if (comptime !copy.copyable(Out) or !copy.encodable(Args)) {
            unsupported(Out, Args);
            internal.keepSource(c, .database);
            return runner.run(c, sql, args);
        }
        // Off the executors there is nothing to share with.
        const local = self.locals.get(c.io) orelse {
            internal.keepSource(c, .database);
            return runner.run(c, sql, args);
        };
        const io = c.io;

        local.key.clearRetainingCapacity();
        writeKey(&local.key.writer, typeId(Out), sql, args) catch return error.OutOfMemory;
        const key = local.key.written();
        const stamp = self.gens.stamp(Generations.tagSlot(if (opts.cache) |o| o.tag else null), Generations.keySlot(std.hash.Wyhash.hash(0, key[@sizeOf(usize)..])));

        if (opts.cache != null) {
            if (local.store.get(key, store.now(io), &self.gens)) |entry| {
                local.store.count(.hit);
                internal.keepSource(c, .cache);
                return copy.deepCopy(Out, entry.as(Out).*, c.arena);
            }
            local.store.count(.miss);
        }

        var joined: ?*Flight = null;
        if (local.flights.get(key)) |found| {
            if (self.gens.fresh(found.stamp)) {
                joined = found;
                found.waiters += 1;
                local.store.count(.coalesced);
            } else {
                // Started before an invalidation: let it finish for its
                // own callers, and start a new one.
                found.unlist();
            }
        }
        internal.keepSource(c, if (joined != null) .coalesced else .database);
        const f = if (joined) |found| found else (try self.start(Out, local, io, key, stamp, opts, sql, args, runner)) orelse
            return runner.run(c, sql, args);
        const T = Typed(Out, Args, @TypeOf(runner));
        defer f.leave();
        internal.bounded(c, self.system, opts.timeout, Flight.wait, .{ f, io }) catch |err| return switch (err) {
            error.Canceled => error.Canceled,
            else => error.GatewayTimeout,
        };
        const typed: *T = @fieldParentPtr("base", f);
        const out = typed.result catch |err| {
            if (f.ctx.last_error) |detail| internal.keepError(c, detail);
            return err;
        };
        return copy.deepCopy(Out, out, c.arena);
    }

    /// A flight for `key` with the caller as its first waiter, listed and
    /// its statement's task spawned; null when no task can be spawned.
    fn start(self: *Cache, comptime Out: type, local: *Local, io: std.Io, key: []const u8, stamp: store.Stamp, opts: db.QueryOptions, sql: []const u8, args: anytype, runner: anytype) !?*Flight {
        const T = Typed(Out, @TypeOf(args), @TypeOf(runner));
        const t = try self.gpa.create(T);
        t.* = .{
            .base = .{
                .cache = self,
                .local = local,
                .io = io,
                .key = undefined,
                .stamp = stamp,
                .arena = .init(self.gpa),
                .ctx = undefined,
                .ttl = if (opts.cache) |o| o.ttl else null,
                .keep_empty = if (opts.cache) |o| o.keep_empty else true,
                .waiters = 1,
                .destroy = T.destroy,
            },
            .sql = undefined,
            .args = undefined,
            .runner = runner,
        };
        errdefer T.destroy(&t.base);
        const a = t.base.arena.allocator();
        t.base.ctx = .{ .io = io, .arena = a };
        // The callers' memory (the key's buffer, a request's arena) may
        // go before the statement is done.
        t.base.key = try a.dupe(u8, key);
        t.sql = try a.dupe(u8, sql);
        t.args = try copy.deepCopy(@TypeOf(args), args, a);
        try local.flights.put(self.gpa, t.base.key, &t.base);
        placement.concurrent(&local.group, io, .local, T.task, .{t}) catch {
            t.base.unlist();
            T.destroy(&t.base);
            return null;
        };
        return &t.base;
    }

    /// Keeps `out` in `local`'s store under `key` for `ttl`: copied into
    /// one allocation with the key, unless an invalidation came since
    /// `stamp` was taken or it does not fit.
    fn keep(self: *Cache, comptime Out: type, local: *Local, key: []const u8, stamp: store.Stamp, ttl: std.Io.Duration, out: Out) void {
        if (!self.gens.fresh(stamp)) return;
        const len = @sizeOf(Out) + copy.deepSize(Out, out);
        const entry = local.store.create(key, len, .of(Out), store.now(self.io) + ttl.nanoseconds, stamp) orelse return;
        var fba: std.heap.FixedBufferAllocator = .init(entry.value()[@sizeOf(Out)..]);
        entry.as(Out).* = copy.deepCopy(Out, out, fba.allocator()) catch return local.store.discard(entry);
        local.store.insert(entry);
    }
};

/// A statement in flight for one or more callers on one executor. Only
/// tasks of that executor touch it.
const Flight = struct {
    cache: *Cache,
    local: *Cache.Local,
    io: std.Io,
    /// In `arena`.
    key: []const u8,
    stamp: store.Stamp,
    /// The statement's copy of the arguments, and its result.
    arena: std.heap.ArenaAllocator,
    /// The statement's context: its arena, and its error's detail.
    ctx: db.Ctx,
    /// Callers waiting, or copying the result.
    waiters: u32 = 0,
    state: enum { queued, running, done } = .queued,
    /// In `local.flights`, where identical calls join it.
    listed: bool = true,
    /// No caller waits any more and nothing keeps the result: the task
    /// does not start the statement, or is canceled in it.
    abandoned: bool = false,
    /// The task, while it runs the statement.
    task: ?placement.Task = null,
    done: std.Io.Event = .unset,
    /// Kept this long once done; null: not kept.
    ttl: ?std.Io.Duration,
    /// An empty result is kept too (`QueryOptions.Cache.keep_empty`).
    keep_empty: bool = true,
    destroy: *const fn (*Flight) void,

    fn wait(f: *Flight, io: std.Io) std.Io.Cancelable!void {
        return f.done.wait(io);
    }

    fn unlist(f: *Flight) void {
        if (!f.listed) return;
        f.listed = false;
        _ = f.local.flights.remove(f.key);
    }

    /// A caller is done with `f`: the last one frees it, or, before it is
    /// done and when nothing would keep its result, stops it.
    fn leave(f: *Flight) void {
        f.waiters -= 1;
        if (f.waiters > 0) return;
        switch (f.state) {
            .done => f.destroy(f),
            .queued, .running => if (f.ttl == null) {
                f.unlist();
                f.abandoned = true;
                if (f.task) |t| placement.cancelTask(t);
            },
        }
    }
};

fn Typed(comptime Out: type, comptime Args: type, comptime Runner: type) type {
    return struct {
        const Self = @This();

        base: Flight,
        sql: []const u8,
        args: Args,
        runner: Runner,
        result: ReadError!Out = error.Canceled,

        fn task(self: *Self) void {
            const f = &self.base;
            if (!f.abandoned) {
                f.task = placement.currentTask(f.io);
                f.state = .running;
                self.result = self.runner.run(&f.ctx, self.sql, self.args);
                f.task = null;
            }
            f.state = .done;
            f.unlist();
            if (f.ttl) |ttl| if (self.result) |out| {
                if (f.keep_empty or !isEmpty(Runner.shape, out)) f.cache.keep(Out, f.local, f.key, f.stamp, ttl, out);
            } else |_| {};
            f.done.set(f.io);
            if (f.waiters == 0) destroy(f);
        }

        fn destroy(f: *Flight) void {
            const self: *Self = @fieldParentPtr("base", f);
            const gpa = f.cache.gpa;
            f.arena.deinit();
            gpa.destroy(self);
        }
    };
}

/// A key: the result's type (`Out`), then the statement and its
/// parameters (`writeBody`), which `invalidateQuery` hashes alone.
fn writeKey(w: *std.Io.Writer, type_id: usize, sql: []const u8, args: anytype) !void {
    try w.writeInt(usize, type_id, .little);
    try writeBody(w, sql, args);
}

fn writeBody(w: *std.Io.Writer, sql: []const u8, args: anytype) !void {
    try copy.encode(w, sql);
    try copy.encode(w, args);
}

/// A number for `T`, the same for every use of it and different from
/// any other type's.
fn typeId(comptime T: type) usize {
    const S = struct {
        const t = T;
        var byte: u8 = 0;
    };
    return @intFromPtr(&S.byte);
}

/// A call asked for sharing with a row type or arguments that cannot be
/// copied: it goes the plain way, said once per type.
fn unsupported(comptime Out: type, comptime Args: type) void {
    const S = struct {
        const t = .{ Out, Args };
        var said: std.atomic.Value(bool) = .init(false);
    };
    if (S.said.swap(true, .monotonic)) return;
    log.warn("anole.db: .coalesce and .cache take rows and arguments made of numbers, strings, enums, optionals, arrays, structs and slices; " ++
        "{s} with arguments {s} has a pointer of another kind, so those calls run unshared", .{ @typeName(Out), @typeName(Args) });
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const zio = @import("zio");
const wait = @import("anole_test_wait");

const Row = struct { id: i64, sql: []const u8, tags: []const []const u8 };

/// A context of a test's own, so a test sees whether a call reached the
/// runner with the caller's context (the plain path) or a flight's.
const TestCtx = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    last_error: ?db.ErrorDetail = null,
    last_source: ?db.Source = null,
};

/// A connector that counts its statements, takes `delay_ms` for each (or,
/// with a `gate`, runs until the test sets it), and returns two rows built
/// from the statement and its first argument.
const Fake = struct {
    calls: *std.atomic.Value(u32),
    canceled: *std.atomic.Value(u32),
    plain: *std.atomic.Value(u32),
    delay_ms: i64 = 20,
    /// Set: the statement runs until the test sets it, so calls that
    /// should join it find it in flight however slow the machine is.
    gate: ?*std.Io.Event = null,
    fail: bool = false,
    /// No rows at all: an empty result.
    empty: bool = false,

    pub const shape: Shape = .all;

    pub fn run(self: Fake, ctx: anytype, sql: []const u8, args: anytype) ReadError![]Row {
        _ = self.calls.fetchAdd(1, .monotonic);
        if (@TypeOf(ctx) == *TestCtx) _ = self.plain.fetchAdd(1, .monotonic);
        const waited = if (self.gate) |g| g.wait(ctx.io) else ctx.io.sleep(.fromMilliseconds(self.delay_ms), .awake);
        waited catch {
            _ = self.canceled.fetchAdd(1, .monotonic);
            return error.Canceled;
        };
        if (self.fail) return internal.fail(ctx, .{}, .{ .system = .postgresql, .class = .unique, .code = "23505", .message = "duplicate" });
        if (self.empty) return &.{};
        const rows = try ctx.arena.alloc(Row, 2);
        const tags = try ctx.arena.alloc([]const u8, 1);
        tags[0] = try ctx.arena.dupe(u8, "tag");
        for (rows, 0..) |*r, i| r.* = .{ .id = args[0] + @as(i64, @intCast(i)), .sql = try ctx.arena.dupe(u8, sql), .tags = tags };
        return rows;
    }
};

const Harness = struct {
    calls: std.atomic.Value(u32) = .init(0),
    canceled: std.atomic.Value(u32) = .init(0),
    plain: std.atomic.Value(u32) = .init(0),

    fn fake(h: *Harness, delay_ms: i64) Fake {
        return .{ .calls = &h.calls, .canceled = &h.canceled, .plain = &h.plain, .delay_ms = delay_ms };
    }

    /// A statement that runs until `gate` is set.
    fn held(h: *Harness, gate: *std.Io.Event) Fake {
        return .{ .calls = &h.calls, .canceled = &h.canceled, .plain = &h.plain, .gate = gate };
    }

    /// Waits until `n` statements have started.
    fn waitCalls(h: *Harness, io: std.Io, n: u32) !void {
        try wait.waitAtLeast(io, "the statement started", &h.calls, n);
    }
};

/// Waits until `n` calls in all have joined one in flight.
fn waitCoalesced(cache: *Cache, io: std.Io, n: u64) !void {
    const C = struct {
        cache: *Cache,
        n: u64,
        fn f(c: @This()) bool {
            return c.cache.stats().coalesced >= c.n;
        }
    };
    try wait.waitUntil(io, "the identical calls joined the one in flight", C{ .cache = cache, .n = n }, C.f);
}

/// One caller: reads with `opts` into an arena of its own, checks the rows
/// are its own copy, and counts what it got.
fn caller(cache: *Cache, io: std.Io, runner: Fake, opts: db.QueryOptions, id: i64, ok: *std.atomic.Value(u32), errors: *std.atomic.Value(u32)) void {
    var buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    var c: TestCtx = .{ .io = io, .arena = fba.allocator() };
    const rows = cache.read([]Row, &c, opts, "SELECT id FROM t WHERE id = $1", .{id}, runner) catch {
        _ = errors.fetchAdd(1, .monotonic);
        return;
    };
    // In this caller's memory, and no other caller's.
    const mine = struct {
        fn in(b: []const u8, p: [*]const u8) bool {
            return @intFromPtr(p) >= @intFromPtr(b.ptr) and @intFromPtr(p) < @intFromPtr(b.ptr) + b.len;
        }
    }.in;
    const owned = mine(&buf, @ptrCast(rows.ptr)) and mine(&buf, rows[1].sql.ptr) and mine(&buf, rows[0].tags[0].ptr);
    if (rows.len == 2 and rows[0].id == id and owned and std.mem.eql(u8, rows[0].tags[0], "tag")) _ = ok.fetchAdd(1, .monotonic);
}

test "db cache: N identical calls in flight on each of 4 executors run one statement per executor" {
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(4) });
    defer rt.deinit();
    const io = rt.io();
    var cache: Cache = try .init(gpa, io, .postgresql, "test", .{});
    defer cache.deinit();
    var h: Harness = .{};

    var ok: std.atomic.Value(u32) = .init(0);
    var errors: std.atomic.Value(u32) = .init(0);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    const per_executor = 16;
    // Each executor's statement runs until all its callers have joined.
    var gate: std.Io.Event = .unset;
    defer gate.set(io);
    for (0..4 * per_executor) |i| try placement.concurrent(&group, io, .{ .executor = i % 4 }, caller, .{ &cache, io, h.held(&gate), .{ .coalesce = true }, 7, &ok, &errors });
    try waitCoalesced(&cache, io, 4 * (per_executor - 1));
    gate.set(io);
    try group.await(io);
    try testing.expectEqual(@as(u32, 4 * per_executor), ok.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), errors.load(.monotonic));
    try testing.expectEqual(@as(u32, 4), h.calls.load(.monotonic));
    try testing.expectEqual(@as(u64, 4 * (per_executor - 1)), cache.stats().coalesced);

    // Other arguments are another statement: both run at once, neither
    // joins the other (both statements started while both are held).
    var gate2: std.Io.Event = .unset;
    defer gate2.set(io);
    try placement.concurrent(&group, io, .{ .executor = 0 }, caller, .{ &cache, io, h.held(&gate2), .{ .coalesce = true }, 8, &ok, &errors });
    try placement.concurrent(&group, io, .{ .executor = 0 }, caller, .{ &cache, io, h.held(&gate2), .{ .coalesce = true }, 9, &ok, &errors });
    try h.waitCalls(io, 6);
    gate2.set(io);
    try group.await(io);
    try testing.expectEqual(@as(u32, 6), h.calls.load(.monotonic));
    try testing.expectEqual(@as(u32, 4 * per_executor + 2), ok.load(.monotonic));
    try testing.expectEqual(@as(u64, 4 * (per_executor - 1)), cache.stats().coalesced);
    // A flight left behind would be reported by testing.allocator's leak
    // check at cache.deinit.
}

test "db cache: the first caller canceled, the others still get the rows; all gone, the statement stops" {
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var cache: Cache = try .init(gpa, io, .postgresql, "test", .{});
    defer cache.deinit();
    var h: Harness = .{};
    var ok: std.atomic.Value(u32) = .init(0);
    var errors: std.atomic.Value(u32) = .init(0);

    // The leader starts the statement, and is canceled while it runs.
    var gate: std.Io.Event = .unset;
    defer gate.set(io);
    var leader: std.Io.Group = .init;
    defer leader.cancel(io);
    try placement.concurrent(&leader, io, .{ .executor = 1 }, caller, .{ &cache, io, h.held(&gate), .{ .coalesce = true }, 1, &ok, &errors });
    try h.waitCalls(io, 1);
    var followers: std.Io.Group = .init;
    defer followers.cancel(io);
    for (0..3) |_| try placement.concurrent(&followers, io, .{ .executor = 1 }, caller, .{ &cache, io, h.held(&gate), .{ .coalesce = true }, 1, &ok, &errors });
    try waitCoalesced(&cache, io, 3);
    leader.cancel(io);
    gate.set(io);
    try followers.await(io);
    try testing.expectEqual(@as(u32, 3), ok.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), errors.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), h.calls.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), h.canceled.load(.monotonic));

    // Every caller gone before the end: the statement is canceled.
    var never: std.Io.Event = .unset;
    var all: std.Io.Group = .init;
    defer all.cancel(io);
    for (0..3) |_| try placement.concurrent(&all, io, .{ .executor = 1 }, caller, .{ &cache, io, h.held(&never), .{ .coalesce = true }, 2, &ok, &errors });
    try h.waitCalls(io, 2);
    try waitCoalesced(&cache, io, 3 + 2);
    all.cancel(io);
    try wait.waitAtLeast(io, "the abandoned statement canceled", &h.canceled, 1);
    try testing.expectEqual(@as(u32, 1), h.canceled.load(.monotonic));
    try testing.expectEqual(@as(u32, 2), h.calls.load(.monotonic));
}

test "db cache: a caller's own timeout ends its wait alone" {
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    var cache: Cache = try .init(gpa, io, .postgresql, "test", .{});
    defer cache.deinit();
    var h: Harness = .{};
    var ok: std.atomic.Value(u32) = .init(0);
    var errors: std.atomic.Value(u32) = .init(0);
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;

    // The statement runs until the second caller has timed out.
    var gate: std.Io.Event = .unset;
    defer gate.set(io);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try placement.concurrent(&group, io, .{ .executor = 0 }, caller, .{ &cache, io, h.held(&gate), .{ .coalesce = true }, 3, &ok, &errors });
    try h.waitCalls(io, 1);
    try placement.concurrent(&group, io, .{ .executor = 0 }, caller, .{ &cache, io, h.held(&gate), .{ .coalesce = true, .timeout = .fromMilliseconds(20) }, 3, &ok, &errors });
    try wait.waitAtLeast(io, "the second caller's timeout", &errors, 1);
    gate.set(io);
    try group.await(io);
    try testing.expectEqual(@as(u32, 1), ok.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), errors.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), h.calls.load(.monotonic));
}

test "db cache: errors reach every caller with their detail, and are not kept" {
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    var cache: Cache = try .init(gpa, io, .postgresql, "test", .{});
    defer cache.deinit();
    var h: Harness = .{};

    const Run = struct {
        fn one(cache_: *Cache, io_: std.Io, runner: Fake, conflicts: *std.atomic.Value(u32)) void {
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            var c: TestCtx = .{ .io = io_, .arena = arena.allocator() };
            _ = cache_.read([]Row, &c, .{ .cache = .{ .ttl = .fromSeconds(60) } }, "INSERT", .{1}, runner) catch |err| {
                if (err == error.Conflict and std.mem.eql(u8, db.lastError(&c).?.code, "23505")) _ = conflicts.fetchAdd(1, .monotonic);
            };
        }
    };
    var gate: std.Io.Event = .unset;
    defer gate.set(io);
    var failing = h.held(&gate);
    failing.fail = true;
    var conflicts: std.atomic.Value(u32) = .init(0);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (0..3) |_| try placement.concurrent(&group, io, .{ .executor = 0 }, Run.one, .{ &cache, io, failing, &conflicts });
    try waitCoalesced(&cache, io, 2);
    gate.set(io);
    try group.await(io);
    try testing.expectEqual(@as(u32, 3), conflicts.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), h.calls.load(.monotonic));
    try placement.concurrent(&group, io, .{ .executor = 0 }, Run.one, .{ &cache, io, failing, &conflicts });
    try group.await(io);
    try testing.expectEqual(@as(u32, 2), h.calls.load(.monotonic));
}

/// Runs one caller on executor 0 and waits for it.
fn once(cache: *Cache, io: std.Io, runner: Fake, opts: db.QueryOptions, id: i64) !void {
    var ok: std.atomic.Value(u32) = .init(0);
    var errors: std.atomic.Value(u32) = .init(0);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try placement.concurrent(&group, io, .{ .executor = 0 }, caller, .{ cache, io, runner, opts, id, &ok, &errors });
    try group.await(io);
    if (ok.load(.monotonic) != 1) return error.CallFailed;
}

test "db cache: a result is kept for its ttl, then read again" {
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var cache: Cache = try .init(gpa, io, .postgresql, "test", .{});
    defer cache.deinit();
    var h: Harness = .{};
    const short: db.QueryOptions = .{ .cache = .{ .ttl = .fromMilliseconds(20), .tag = "posts" } };
    try once(&cache, io, h.fake(1), short, 3);
    try once(&cache, io, h.fake(1), short, 3);
    try testing.expectEqual(@as(u32, 1), h.calls.load(.monotonic));
    // Past the ttl: time passing on purpose, 5x the ttl (a sleep never
    // ends early). Moves to an injected clock once store.zig's now() takes one.
    try io.sleep(.fromMilliseconds(100), .awake);
    try once(&cache, io, h.fake(1), short, 3);
    try testing.expectEqual(@as(u32, 2), h.calls.load(.monotonic));
}

test "db cache: kept within its ttl; invalidation by tag, by query, of all and during a flight drops it" {
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var cache: Cache = try .init(gpa, io, .postgresql, "test", .{});
    defer cache.deinit();
    var h: Harness = .{};
    // A ttl no run of this test outlives, so the hits below never depend
    // on how fast the machine is.
    const opts: db.QueryOptions = .{ .cache = .{ .ttl = .fromSeconds(600), .tag = "posts" } };

    try once(&cache, io, h.fake(1), opts, 1);
    try once(&cache, io, h.fake(1), opts, 1);
    try once(&cache, io, h.fake(1), opts, 1);
    try testing.expectEqual(@as(u32, 1), h.calls.load(.monotonic));
    try testing.expectEqual(@as(u64, 2), cache.stats().hits);
    // Another tag leaves it; its own tag drops it.
    cache.invalidate(.{ .tag = "users" });
    try once(&cache, io, h.fake(1), opts, 1);
    try testing.expectEqual(@as(u32, 1), h.calls.load(.monotonic));
    cache.invalidate(.{ .tag = "posts" });
    try once(&cache, io, h.fake(1), opts, 1);
    try testing.expectEqual(@as(u32, 2), h.calls.load(.monotonic));

    // By the statement and its arguments, whatever the width of the integer.
    cache.invalidateQuery("SELECT id FROM t WHERE id = $1", .{@as(i64, 2)});
    try once(&cache, io, h.fake(1), opts, 1);
    try testing.expectEqual(@as(u32, 2), h.calls.load(.monotonic));
    cache.invalidateQuery("SELECT id FROM t WHERE id = $1", .{1});
    try once(&cache, io, h.fake(1), opts, 1);
    try testing.expectEqual(@as(u32, 3), h.calls.load(.monotonic));

    cache.invalidate(.all);
    try once(&cache, io, h.fake(1), opts, 1);
    try testing.expectEqual(@as(u32, 4), h.calls.load(.monotonic));

    // An invalidation while the statement runs: its result is not kept.
    var gate: std.Io.Event = .unset;
    defer gate.set(io);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    var ok: std.atomic.Value(u32) = .init(0);
    var errors: std.atomic.Value(u32) = .init(0);
    try placement.concurrent(&group, io, .{ .executor = 0 }, caller, .{ &cache, io, h.held(&gate), opts, 4, &ok, &errors });
    try h.waitCalls(io, 5);
    cache.invalidate(.{ .tag = "posts" });
    gate.set(io);
    try group.await(io);
    try testing.expectEqual(@as(u32, 1), ok.load(.monotonic));
    try once(&cache, io, h.fake(1), opts, 4);
    try testing.expectEqual(@as(u32, 6), h.calls.load(.monotonic));
}

/// One call on executor 0 with a context of its own: how many rows came
/// back, and where from (`lastSource`).
fn sourced(cache: *Cache, io: std.Io, runner: Fake, opts: db.QueryOptions) !struct { rows: usize, source: ?db.Source } {
    const Out = struct { rows: usize = 0, source: ?db.Source = null, failed: bool = false };
    const Run = struct {
        fn one(cache_: *Cache, io_: std.Io, runner_: Fake, opts_: db.QueryOptions, out: *Out) void {
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            var c: TestCtx = .{ .io = io_, .arena = arena.allocator() };
            const rows = cache_.read([]Row, &c, opts_, "SELECT id FROM t WHERE id = $1", .{1}, runner_) catch {
                out.failed = true;
                return;
            };
            out.* = .{ .rows = rows.len, .source = internal.lastSource(&c) };
        }
    };
    var out: Out = .{};
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try placement.concurrent(&group, io, .{ .executor = 0 }, Run.one, .{ cache, io, runner, opts, &out });
    try group.await(io);
    if (out.failed) return error.CallFailed;
    return .{ .rows = out.rows, .source = out.source };
}

test "db cache: keep_empty = false serves an empty result without keeping it; a full one is kept" {
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    var cache: Cache = try .init(gpa, io, .postgresql, "test", .{});
    defer cache.deinit();
    var h: Harness = .{};
    var empty = h.fake(1);
    empty.empty = true;

    // Kept by default: the second call is a hit.
    const keeping: db.QueryOptions = .{ .cache = .{ .ttl = .fromSeconds(60), .tag = "a" } };
    try testing.expectEqual(@as(usize, 0), (try sourced(&cache, io, empty, keeping)).rows);
    try testing.expectEqual(@as(usize, 0), (try sourced(&cache, io, empty, keeping)).rows);
    try testing.expectEqual(@as(u32, 1), h.calls.load(.monotonic));
    try testing.expectEqual(@as(u64, 1), cache.stats().hits);

    // Not kept: each call asks again, and once the rows exist they are
    // served at once, not "none" for the rest of the ttl.
    cache.invalidate(.all);
    const cache_aside: db.QueryOptions = .{ .cache = .{ .ttl = .fromSeconds(60), .keep_empty = false } };
    try testing.expectEqual(@as(usize, 0), (try sourced(&cache, io, empty, cache_aside)).rows);
    try testing.expectEqual(@as(usize, 0), (try sourced(&cache, io, empty, cache_aside)).rows);
    try testing.expectEqual(@as(u32, 3), h.calls.load(.monotonic));
    try testing.expectEqual(@as(usize, 2), (try sourced(&cache, io, h.fake(1), cache_aside)).rows);
    try testing.expectEqual(@as(u32, 4), h.calls.load(.monotonic));
    // A result with rows is kept as before.
    try testing.expectEqual(@as(usize, 2), (try sourced(&cache, io, h.fake(1), cache_aside)).rows);
    try testing.expectEqual(@as(u32, 4), h.calls.load(.monotonic));

    try testing.expect(isEmpty(.optional, @as(?u8, null)));
    try testing.expect(!isEmpty(.optional, @as(?[]const u8, "")));
    try testing.expect(!isEmpty(.one, @as([]const u8, "")));
    try testing.expect(isEmpty(.all, @as([]const Row, &.{})));
}

test "db cache: lastSource says where each answer came from" {
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    var cache: Cache = try .init(gpa, io, .postgresql, "test", .{});
    defer cache.deinit();
    var h: Harness = .{};
    const opts: db.QueryOptions = .{ .cache = .{ .ttl = .fromSeconds(60) } };

    try testing.expectEqual(@as(?db.Source, .database), (try sourced(&cache, io, h.fake(1), opts)).source);
    try testing.expectEqual(@as(?db.Source, .cache), (try sourced(&cache, io, h.fake(1), opts)).source);
    // A plain call records nothing.
    try testing.expectEqual(@as(?db.Source, null), (try sourced(&cache, io, h.fake(1), .{})).source);

    // Joining an identical call in flight: coalesced.
    const Join = struct {
        fn run(cache_: *Cache, io_: std.Io, runner: Fake, source: *?db.Source) void {
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            var c: TestCtx = .{ .io = io_, .arena = arena.allocator() };
            _ = cache_.read([]Row, &c, .{ .coalesce = true }, "SELECT id FROM t WHERE id = $1", .{9}, runner) catch return;
            source.* = internal.lastSource(&c);
        }
    };
    var first: ?db.Source = null;
    var second: ?db.Source = null;
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    var gate: std.Io.Event = .unset;
    defer gate.set(io);
    try placement.concurrent(&group, io, .{ .executor = 0 }, Join.run, .{ &cache, io, h.held(&gate), &first });
    try h.waitCalls(io, 3);
    try placement.concurrent(&group, io, .{ .executor = 0 }, Join.run, .{ &cache, io, h.held(&gate), &second });
    try waitCoalesced(&cache, io, 1);
    gate.set(io);
    try group.await(io);
    try testing.expectEqual(@as(?db.Source, .database), first);
    try testing.expectEqual(@as(?db.Source, .coalesced), second);

    // Off the executors: the plain call, a round trip of its own.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var c: db.Ctx = .{ .io = testing.io, .arena = arena.allocator() };
    _ = try cache.read([]Row, &c, opts, "SELECT", .{1}, h.fake(0));
    try testing.expectEqual(@as(?db.Source, .database), db.lastSource(&c));
}

test "db cache: bounded in bytes, least recently used out first" {
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    // Room for about three results of this size.
    var cache: Cache = try .init(gpa, io, .postgresql, "test", .{ .max_bytes = 3 * 400 });
    defer cache.deinit();
    var h: Harness = .{};
    const opts: db.QueryOptions = .{ .cache = .{ .ttl = .fromSeconds(60) } };
    for (1..7) |id| try once(&cache, io, h.fake(1), opts, @intCast(id));
    try testing.expectEqual(@as(u32, 6), h.calls.load(.monotonic));
    const s = cache.stats();
    try testing.expect(s.evictions >= 3);
    try testing.expect(s.bytes <= 3 * 400);
    // The newest is still there; the oldest is not.
    try once(&cache, io, h.fake(1), opts, 6);
    try testing.expectEqual(@as(u32, 6), h.calls.load(.monotonic));
    try once(&cache, io, h.fake(1), opts, 1);
    try testing.expectEqual(@as(u32, 7), h.calls.load(.monotonic));
}

test "db cache: a call without options is the plain call: no key, no lookup, no allocation" {
    const rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    // Counts every allocation the cache makes after its setup.
    var counting: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var cache: Cache = try .init(counting.allocator(), io, .postgresql, "test", .{});
    defer cache.deinit();
    var h: Harness = .{};
    const before = counting.allocations;
    for (0..10) |_| try once(&cache, io, h.fake(0), .{}, 1);
    try testing.expectEqual(before, counting.allocations);
    try testing.expectEqual(@as(u32, 10), h.plain.load(.monotonic));
    try testing.expectEqual(store.Totals{}, cache.stats());

    // Off the executors, sharing is skipped: the plain call again.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var c: TestCtx = .{ .io = testing.io, .arena = arena.allocator() };
    _ = try cache.read([]Row, &c, .{ .coalesce = true }, "SELECT", .{1}, h.fake(0));
    try testing.expectEqual(@as(u32, 11), h.plain.load(.monotonic));
}

test "db cache: typeId tells types apart, and is stable" {
    try testing.expect(typeId([]Row) != typeId(?Row));
    try testing.expect(typeId(Row) != typeId([]Row));
    try testing.expectEqual(typeId([]Row), typeId([]Row));
}
