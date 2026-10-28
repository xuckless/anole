//! Blocking work off the executors: CPU-heavy or blocking calls (Argon2id,
//! a blocking C library) run on a pool thread while the calling coroutine
//! waits, so the executor goes on serving everything else.
//!
//!     var app = try anole.App.init(gpa, .{ .blocking = .{} });
//!     // in a handler:
//!     const n = try anole.blocking.run(req.io, expensive, .{ input });
//!
//! The threads are zio's own thread pool (`Runtime.blockingIo`, the pool
//! zio already runs file I/O and DNS on); a `Pool` only caps how many jobs
//! run at once (`threads`), so heavy jobs cannot crowd out zio's own work,
//! and lets `run` find it from a request's `std.Io`. With no pool for that
//! runtime (none configured, or code outside `anole.Server`), `run` calls
//! the function directly.
//!
//! Cancellation: a job is never cut short from outside (CPU work has no
//! cancelation points). When the caller is canceled while its job runs, it
//! still waits for the job to finish, because the job may borrow the
//! caller's memory, and then gets `error.Canceled`; a job that can be asked
//! to stop early (a SQLite query, through `sqlite3_interrupt`) gets that
//! request from `RunOptions.on_cancel`. A job whose caller was canceled
//! before it started does not start.
const std = @import("std");
const test_wait = @import("anole_test_wait");
const zio = @import("zio");

/// The pool's settings: `ServerOptions.blocking`, or `Pool.init`.
pub const Options = struct {
    /// Jobs that run at once; more wait for a free slot. Null: half the
    /// CPUs, at least 2.
    threads: ?usize = null,
};

/// What a caller asks for besides the job (`runWith`).
pub const RunOptions = struct {
    /// Called when the caller is canceled while its job runs, before it
    /// waits for the job to end: to make the job end soon (SQLite's
    /// `sqlite3_interrupt` on the job's connection). Runs on the caller's
    /// task, at most once, and only after the job has started; the job may
    /// be about to finish, or between two steps, so a job that checks
    /// state of its own set by the hook misses nothing. Not called when
    /// there is no pool (`run` then calls the function on the caller's
    /// task, which nothing cancels meanwhile).
    on_cancel: ?OnCancel = null,
};

/// A callback and its context: `call(context)`.
pub const OnCancel = struct {
    context: ?*anyopaque,
    call: *const fn (context: ?*anyopaque) void,
};

/// What `run(io, func, args)` returns: `func`'s result, with
/// `error.Canceled` added.
pub fn Result(comptime Func: type) type {
    const R = @typeInfo(Func).@"fn".return_type.?;
    return switch (@typeInfo(R)) {
        .error_union => |eu| (eu.error_set || error{Canceled})!eu.payload,
        else => error{Canceled}!R,
    };
}

/// A cap on how many jobs run at once on the runtime's blocking threads.
/// `ServerOptions.blocking` makes one for the server; `anole.blocking.run`
/// finds it from a request's `std.Io`.
pub const Pool = struct {
    rt: *zio.Runtime,
    threads: usize,
    /// Guards the counts; a job holds a slot (`running`) while it runs.
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    running: usize = 0,
    /// Callers waiting for a slot.
    waiting: usize = 0,
    closed: bool = false,

    /// Starts a pool on `rt`'s thread pool, in place: `run` finds it
    /// through any `std.Io` of `rt` until `deinit`. `self` must stay put
    /// until then.
    pub fn init(self: *Pool, rt: *zio.Runtime, opts: Options) !void {
        const threads = opts.threads orelse @max(2, (std.Thread.getCpuCount() catch 4) / 2);
        if (threads == 0) return error.InvalidThreadCount;
        self.* = .{ .rt = rt, .threads = threads };
        try register(self);
    }

    /// Refuses new jobs (`error.PoolClosed`; `anole.blocking.run` then
    /// calls the function directly) and waits for the running ones and
    /// for callers still waiting for a slot to leave. The memory may go
    /// once it returns.
    pub fn deinit(self: *Pool) void {
        unregister(self);
        const io = self.rt.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        @atomicStore(bool, &self.closed, true, .release); // read by jobs spinning in its tests
        self.changed.broadcast(io);
        while (self.running > 0 or self.waiting > 0) self.changed.waitUncancelable(io, &self.mutex);
    }

    fn acquire(self: *Pool, io: std.Io) error{ Canceled, PoolClosed }!void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        self.waiting += 1;
        defer {
            self.waiting -= 1;
            if (self.closed) self.changed.broadcast(io);
        }
        while (!self.closed and self.running >= self.threads) try self.changed.wait(io, &self.mutex);
        if (self.closed) return error.PoolClosed;
        self.running += 1;
    }

    fn release(self: *Pool, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.running -= 1;
        self.changed.broadcast(io);
    }

    /// Runs `func(args...)` on a pool thread; the calling coroutine waits
    /// for it without holding its executor. `args` may point into the
    /// caller's memory: `run` returns only after the job has finished,
    /// even when canceled. `func` runs outside any coroutine, so whatever
    /// it blocks on blocks only its own thread.
    pub fn run(self: *Pool, io: std.Io, comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) (error{PoolClosed} || ErrorOf(Result(@TypeOf(func))))!PayloadOf(Result(@TypeOf(func))) {
        return self.runWith(io, .{}, func, args);
    }

    /// `run`, with `options`.
    pub fn runWith(self: *Pool, io: std.Io, options: RunOptions, comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) (error{PoolClosed} || ErrorOf(Result(@TypeOf(func))))!PayloadOf(Result(@TypeOf(func))) {
        try self.acquire(io);
        defer self.release(io);

        const R = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
        const Job = struct {
            args: @TypeOf(args),
            io: std.Io,
            result: R = undefined,
            done: std.Io.Event = .unset,
            /// Who came first: the pool thread starting the job, or the
            /// caller giving up on it.
            state: std.atomic.Value(State) = .init(.queued),

            const State = enum(u8) { queued, started, abandoned };

            fn work(job: *@This()) void {
                if (job.state.cmpxchgStrong(.queued, .started, .acq_rel, .acquire) == null) {
                    job.result = @call(.auto, func, job.args);
                }
                job.done.set(job.io);
            }
        };
        var job: Job = .{ .args = args, .io = io };
        var future = self.rt.blockingIo().concurrent(Job.work, .{&job}) catch {
            // No thread to be had: run it here rather than fail.
            Job.work(&job);
            return job.result;
        };
        job.done.wait(io) catch |err| {
            const abandoned = job.state.cmpxchgStrong(.queued, .abandoned, .acq_rel, .acquire) == null;
            if (!abandoned) if (options.on_cancel) |hook| hook.call(hook.context);
            job.done.waitUncancelable(io);
            future.await(io);
            return err;
        };
        future.await(io);
        return job.result;
    }
};

fn ErrorOf(comptime T: type) type {
    return @typeInfo(T).error_union.error_set;
}

fn PayloadOf(comptime T: type) type {
    return @typeInfo(T).error_union.payload;
}

/// Runs `func(args...)` on the pool of `io`'s runtime (see `Pool.run`), or
/// directly when that runtime has none.
pub fn run(io: std.Io, comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) Result(@TypeOf(func)) {
    return runWith(io, .{}, func, args);
}

/// `run`, with `options` (see `RunOptions`).
pub fn runWith(io: std.Io, options: RunOptions, comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) Result(@TypeOf(func)) {
    if (find(io)) |pool| {
        return pool.runWith(io, options, func, args) catch |err| switch (err) {
            error.PoolClosed => @call(.auto, func, args),
            else => |e| e,
        };
    }
    return @call(.auto, func, args);
}

/// Whether `run` on `io` would use a pool.
pub fn available(io: std.Io) bool {
    return find(io) != null;
}

/// The pools by runtime; a handful at most (one per `anole.Server`).
var registry: [8]std.atomic.Value(?*Pool) = @splat(.init(null));

fn register(pool: *Pool) !void {
    for (&registry) |*slot| {
        if (slot.cmpxchgStrong(null, pool, .acq_rel, .acquire) == null) return;
    }
    return error.TooManyPools;
}

fn unregister(pool: *Pool) void {
    for (&registry) |*slot| {
        if (slot.cmpxchgStrong(pool, null, .acq_rel, .acquire) == null) return;
    }
}

fn find(io: std.Io) ?*Pool {
    const rt = zio.Runtime.fromIo(io) orelse return null;
    for (&registry) |*slot| {
        const pool = slot.load(.acquire) orelse continue;
        if (pool.rt == rt) return pool;
    }
    return null;
}

/// Keeps a thread busy for `ms` without yielding (a stand-in for a hash).
fn spin(io: std.Io, ms: i64) u32 {
    const start = std.Io.Clock.awake.now(io);
    var n: u32 = 0;
    while (start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < ms) n +%= 1;
    return n;
}

/// Keeps a thread busy, without yielding, until `ticks` reaches `want` (or
/// the wait helper's deadline passes): a job that ends once the executor
/// has shown it kept running, however slow the machine.
fn spinUntilTicks(io: std.Io, ticks: *const std.atomic.Value(u32), want: u32) u32 {
    const start = std.Io.Clock.awake.now(io);
    var n: u32 = 0;
    while (ticks.load(.monotonic) < want) : (n +%= 1) {
        if (start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds >= test_wait.deadline().nanoseconds) break;
    }
    return n;
}

fn fails() error{Nope}!u8 {
    return error.Nope;
}

test "blocking.run: the one executor keeps running other tasks while a job spins" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    var pool: Pool = undefined;
    try pool.init(rt, .{ .threads = 2 });
    defer pool.deinit();
    try std.testing.expect(available(io));
    try std.testing.expect(!available(std.testing.io));

    const Ticker = struct {
        fn tick(_io: std.Io, ticks: *std.atomic.Value(u32)) std.Io.Cancelable!void {
            while (true) {
                try _io.sleep(.fromMilliseconds(5), .awake);
                _ = ticks.fetchAdd(1, .monotonic);
            }
        }
    };
    var ticks: std.atomic.Value(u32) = .init(0);
    var ticker = try io.concurrent(Ticker.tick, .{ io, &ticks });
    defer ticker.cancel(io) catch {};

    // The job spins until the ticker, which shares the only executor, has
    // ticked ten times: it ran beside the job.
    _ = try run(io, spinUntilTicks, .{ io, &ticks, 10 });
    try std.testing.expect(ticks.load(.monotonic) >= 10);

    // Errors come back as the function returned them.
    try std.testing.expectError(error.Nope, run(io, fails, .{}));

    // The same job without a pool holds the executor: no ticks meanwhile.
    const before = ticks.load(.monotonic);
    _ = spin(io, 100);
    try std.testing.expect(ticks.load(.monotonic) - before <= 1);
}

test "blocking.Pool: a canceled caller gets error.Canceled after its job finishes; deinit waits for jobs" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var pool: Pool = undefined;
    try pool.init(rt, .{ .threads = 1 });

    // A job that runs until its caller's cancel has arrived (the cancel
    // hook only tells it so), then a little longer.
    const Job = struct {
        started: std.atomic.Value(bool) = .init(false),
        cancel_seen: std.atomic.Value(bool) = .init(false),
        finished: std.atomic.Value(bool) = .init(false),

        fn work(job: *@This(), _io: std.Io) u32 {
            job.started.store(true, .release);
            while (!job.cancel_seen.load(.acquire)) std.atomic.spinLoopHint();
            const n = spin(_io, 20);
            job.finished.store(true, .release);
            return n;
        }
        fn seen(context: ?*anyopaque) void {
            const job: *@This() = @ptrCast(@alignCast(context.?));
            job.cancel_seen.store(true, .release);
        }
        fn call(p: *Pool, _io: std.Io, job: *@This()) !u32 {
            return p.runWith(_io, .{ .on_cancel = .{ .context = job, .call = seen } }, work, .{ job, _io });
        }
    };
    var job: Job = .{};
    var caller = try io.concurrent(Job.call, .{ &pool, io, &job });
    try test_wait.waitFlag(io, "the job started on the pool", &job.started);
    try std.testing.expectError(error.Canceled, caller.cancel(io));
    // The job was not cut short: cancel returned only once it had finished.
    try std.testing.expect(job.finished.load(.acquire));

    // With the one slot busy, the other job waits; deinit waits for the
    // running one (which runs until the pool is closing), and the waiting
    // one is refused.
    const Held = struct {
        fn work(p: *const Pool, finished: *std.atomic.Value(bool)) u32 {
            var n: u32 = 0;
            while (!@atomicLoad(bool, &p.closed, .acquire)) : (n +%= 1) std.atomic.spinLoopHint();
            finished.store(true, .release);
            return n;
        }
        fn call(p: *Pool, _io: std.Io, finished: *std.atomic.Value(bool)) !u32 {
            return p.run(_io, work, .{ p, finished });
        }
        fn oneRunsOneWaits(p: *Pool) bool {
            const pio = p.rt.io();
            p.mutex.lockUncancelable(pio);
            defer p.mutex.unlock(pio);
            return p.running == 1 and p.waiting == 1;
        }
    };
    var finished2: std.atomic.Value(bool) = .init(false);
    var finished3: std.atomic.Value(bool) = .init(false);
    var second = try io.concurrent(Held.call, .{ &pool, io, &finished2 });
    var third = try io.concurrent(Held.call, .{ &pool, io, &finished3 });
    try test_wait.waitUntil(io, "one job runs and one waits for the slot", &pool, Held.oneRunsOneWaits);
    pool.deinit();
    // Whatever ran had finished by the time deinit returned.
    const done = [_]bool{ finished2.load(.acquire), finished3.load(.acquire) };
    var ran: usize = 0;
    for ([_]*std.Io.Future(@typeInfo(@TypeOf(Held.call)).@"fn".return_type.?){ &second, &third }, done) |f, done_at_deinit| {
        if (f.await(io)) |_| {
            try std.testing.expect(done_at_deinit);
            ran += 1;
        } else |err| try std.testing.expectEqual(error.PoolClosed, err);
    }
    try std.testing.expectEqual(@as(usize, 1), ran);
    // Unregistered: `run` calls directly now.
    try std.testing.expect(!available(io));
    try std.testing.expectEqual(@as(u8, 7), try run(io, struct {
        fn seven() u8 {
            return 7;
        }
    }.seven, .{}));
}

test "blocking.runWith: on_cancel asks a running job to stop, and the caller gets error.Canceled" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var pool: Pool = undefined;
    try pool.init(rt, .{ .threads = 1 });
    defer pool.deinit();

    // A job that runs until told to stop, as a SQLite query runs until
    // `sqlite3_interrupt`.
    const Interruptible = struct {
        started: std.atomic.Value(bool) = .init(false),
        stop: std.atomic.Value(bool) = .init(false),
        hooks: std.atomic.Value(u32) = .init(0),

        fn work(self: *@This()) error{Interrupted}!u32 {
            self.started.store(true, .release);
            var n: u32 = 0;
            while (!self.stop.load(.acquire)) n +%= 1;
            return error.Interrupted;
        }
        fn interrupt(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            _ = self.hooks.fetchAdd(1, .monotonic);
            self.stop.store(true, .release);
        }
        fn call(self: *@This(), _io: std.Io) !u32 {
            return runWith(_io, .{ .on_cancel = .{ .context = self, .call = interrupt } }, work, .{self});
        }
    };
    var job: Interruptible = .{};
    var caller = try io.concurrent(Interruptible.call, .{ &job, io });
    try test_wait.waitFlag(io, "the job started on the pool", &job.started);
    try std.testing.expectError(error.Canceled, caller.cancel(io));
    try std.testing.expectEqual(@as(u32, 1), job.hooks.load(.monotonic));

    // Not canceled: the hook is not called.
    job = .{ .stop = .init(true) };
    try std.testing.expectError(error.Interrupted, Interruptible.call(&job, io));
    try std.testing.expectEqual(@as(u32, 0), job.hooks.load(.monotonic));
}
