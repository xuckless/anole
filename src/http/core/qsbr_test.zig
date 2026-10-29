//! The QSBR helper (src/http/core/qsbr.zig) on the real zio runtime, with
//! the fork's `quiescent_state`: part of anole's suite (the core's own
//! tests run on its stub zio, where every read is in lock mode).
//! research/s15/lock-inventory.md §3, cases 1-6; case 7 is in zio's suite.
//!
//! Objects live in pages of their own from the never-reuse allocator, so a
//! read after a free faults at once instead of reading stale bytes, and
//! each object carries a magic number and a checksum that every read
//! checks. Nothing waits on time: order comes from atomics, and every wait
//! has the test deadline (src/testing/wait.zig).
const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");
const safety = @import("anole_safety");
const wait = @import("anole_test_wait");
const qsbr = dusty.qsbr;
const placement = dusty.placement;

const magic: u64 = 0x5153_4252_4f42_4a31;

/// What the objects' `destroy` hooks and the readers record.
const Stats = struct {
    created: std.atomic.Value(u64) = .init(0),
    freed: std.atomic.Value(u64) = .init(0),
    failures: std.atomic.Value(u64) = .init(0),
    /// Freed generations, for the first 64.
    freed_gen: [64]std.atomic.Value(bool) = @splat(.init(false)),

    fn isFreed(s: *const Stats, gen: u64) bool {
        return s.freed_gen[gen].load(.acquire);
    }
};

const Obj = struct {
    magic: u64,
    gen: u64,
    payload: [64]u8,
    checksum: u64,
    stats: *Stats,

    fn make(stats: *Stats, gen: u64) Obj {
        var o: Obj = .{ .magic = magic, .gen = gen, .payload = undefined, .checksum = 0, .stats = stats };
        for (&o.payload, 0..) |*b, i| b.* = @truncate(gen *% 31 +% i);
        o.checksum = o.sum();
        _ = stats.created.fetchAdd(1, .monotonic);
        return o;
    }

    fn sum(o: *const Obj) u64 {
        return std.hash.Wyhash.hash(o.gen, &o.payload);
    }

    fn intact(o: *const Obj) bool {
        return o.magic == magic and o.checksum == o.sum();
    }

    /// Intact, and not older than what this reader saw before (with one
    /// writer, generations are published in order).
    fn valid(o: *const Obj, last: *u64) bool {
        if (!o.intact() or o.gen < last.*) return false;
        last.* = o.gen;
        return true;
    }

    pub fn destroy(self: *Obj) void {
        if (!self.intact()) _ = self.stats.failures.fetchAdd(1, .monotonic);
        if (self.gen < self.stats.freed_gen.len) self.stats.freed_gen[self.gen].store(true, .release);
        _ = self.stats.freed.fetchAdd(1, .release);
        self.magic = 0;
    }
};

const ObjCell = qsbr.Cell(Obj);

/// A task's error other than a cancel, as a failure the test checks (a
/// group's task returns only `Cancelable!void`).
fn taskResult(stats: *Stats, what: []const u8, result: anyerror!void) std.Io.Cancelable!void {
    result catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            std.debug.print("{s} failed: {t}\n", .{ what, err });
            _ = stats.failures.fetchAdd(1, .monotonic);
        },
    };
}

/// Objects in pages of their own that become inaccessible when freed.
const object_gpa = safety.never_reuse_allocator;

/// The test thread is executor 0's main task: it places the tasks, and
/// its waits are suspensions, so it holds up no grace period while it
/// waits (it does while it joins OS threads, which no writer waits for).
fn startRuntime(executors: u6) !*zio.Runtime {
    return zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(executors) });
}

/// Waits on the main task for `n` tasks to report done.
fn waitDone(io: std.Io, comptime what: []const u8, done: *std.atomic.Value(u32), n: u32) !void {
    try wait.waitAtLeast(io, what, done, n);
}

// ---- 1. The K7 read pattern ----

const Pattern = struct {
    executors: u6,
    readers_per_executor: u32,
    /// `read()`s per iteration, as a request reading its cache entries.
    reads_per_iteration: u32,
    iterations: u32,
    /// A store every this many reader iterations, over all readers.
    store_every: u64,
    burst: u32,
    max_retired: u32,
};

const PatternRun = struct {
    cell: *ObjCell,
    stats: *Stats,
    p: Pattern,
    iterations: std.atomic.Value(u64) = .init(0),
    readers_done: std.atomic.Value(u32) = .init(0),
    next_gen: u64 = 1,

    fn reader(run: *PatternRun, io: std.Io) std.Io.Cancelable!void {
        var last: u64 = 0;
        for (0..run.p.iterations) |i| {
            for (0..run.p.reads_per_iteration) |_| {
                const g = run.cell.read(io);
                if (!g.get().valid(&last)) _ = run.stats.failures.fetchAdd(1, .monotonic);
                g.end();
            }
            _ = run.iterations.fetchAdd(1, .monotonic);
            if (i % 16 == 15) try zio.yield();
        }
        _ = run.readers_done.fetchAdd(1, .release);
    }

    fn store(run: *PatternRun) !void {
        try run.cell.store(.make(run.stats, run.next_gen));
        run.next_gen += 1;
    }

    fn writer(run: *PatternRun) std.Io.Cancelable!void {
        return taskResult(run.stats, "the writer", run.write());
    }

    fn write(run: *PatternRun) !void {
        const readers = run.p.readers_per_executor * run.p.executors;
        const total = @as(u64, run.p.iterations) * readers;
        var next_store = run.p.store_every;
        var burst_done = false;
        while (run.readers_done.load(.acquire) < readers) {
            const done = run.iterations.load(.monotonic);
            if (!burst_done and done >= total / 2) {
                // Back to back: the retire list fills and `retire` waits
                // for grace periods (max_retired).
                for (0..run.p.burst) |_| try run.store();
                burst_done = true;
            }
            if (done >= next_store) {
                try run.store();
                next_store += run.p.store_every;
            }
            try zio.yield();
        }
        // The readers were quicker than the writer looked: the burst runs
        // without them.
        if (!burst_done) for (0..run.p.burst) |_| try run.store();
    }
};

fn readPattern(p: Pattern) !void {
    const rt = try startRuntime(p.executors);
    defer rt.deinit();
    const io = rt.io();
    var stats: Stats = .{};
    var d: qsbr.Domain = undefined;
    d.init(io, .{ .max_retired = p.max_retired });
    defer d.deinit();
    var cell: ObjCell = try .init(&d, object_gpa, .make(&stats, 0));
    var run: PatternRun = .{ .cell = &cell, .stats = &stats, .p = p };
    {
        var group: std.Io.Group = .init;
        defer group.cancel(io);
        for (0..p.executors) |e| {
            for (0..p.readers_per_executor) |_| try placement.concurrent(&group, io, .{ .executor = e }, PatternRun.reader, .{ &run, io });
        }
        try placement.concurrent(&group, io, .{ .executor = 0 }, PatternRun.writer, .{&run});
        try group.await(io);
    }
    try d.synchronize(io);
    cell.deinit();
    try std.testing.expectEqual(@as(u64, 0), stats.failures.load(.acquire));
    try std.testing.expect(run.next_gen > p.burst);
    // Every object made was freed exactly once: none leaked, none freed
    // while a reader could see it (that would have faulted or failed a
    // check above).
    try std.testing.expectEqual(stats.created.load(.acquire), stats.freed.load(.acquire));
}

test "qsbr: many reads per task on every executor, with rare and burst stores, never see a freed or torn object" {
    try readPattern(.{ .executors = 4, .readers_per_executor = 4, .reads_per_iteration = 8, .iterations = 100, .store_every = 100, .burst = 64, .max_retired = 16 });
}

test "qsbr: many reads per task on every executor, with rare and burst stores, never see a freed or torn object [stress]" {
    try wait.requireStress();
    try readPattern(.{ .executors = 8, .readers_per_executor = 64, .reads_per_iteration = 8, .iterations = 2000, .store_every = 10_000, .burst = 1000, .max_retired = 256 });
}

// ---- 2. A held guard blocks reclamation ----

const Held = struct {
    cell: *ObjCell,
    domain: *qsbr.Domain,
    stats: *Stats,
    holding: std.atomic.Value(bool) = .init(false),
    go: std.atomic.Value(bool) = .init(false),
    freed_while_held: bool = true,
    freed_after: bool = false,
    done: std.atomic.Value(u32) = .init(0),

    /// On executor 1: holds a guard on generation 0 without suspending
    /// until `go`, so its executor passes no scheduler meanwhile.
    fn reader(h: *Held, io: std.Io) void {
        const g = h.cell.read(io);
        h.holding.store(true, .release);
        while (!h.go.load(.acquire)) std.atomic.spinLoopHint();
        var last: u64 = 0;
        if (!g.get().valid(&last) or g.get().gen != 0) _ = h.stats.failures.fetchAdd(1, .monotonic);
        g.end();
        _ = h.done.fetchAdd(1, .release);
    }

    fn writer(h: *Held, io: std.Io) std.Io.Cancelable!void {
        defer _ = h.done.fetchAdd(1, .release);
        return taskResult(h.stats, "the writer", h.write(io));
    }

    fn write(h: *Held, io: std.Io) !void {
        try wait.waitUntil(io, "the reader holds its guard", h, struct {
            fn holding(x: *Held) bool {
                return x.holding.load(.acquire);
            }
        }.holding);
        try h.cell.store(.make(h.stats, 1));
        try h.cell.store(.make(h.stats, 2));
        h.domain.poll();
        h.freed_while_held = h.stats.isFreed(0);
        h.go.store(true, .release);
        try h.domain.synchronize(io);
        h.freed_after = h.stats.isFreed(0) and h.stats.isFreed(1);
    }
};

test "qsbr: an object a reader still reads is not freed until the reader's executor passes its scheduler" {
    const rt = try startRuntime(2);
    defer rt.deinit();
    const io = rt.io();
    var stats: Stats = .{};
    var d: qsbr.Domain = undefined;
    d.init(io, .{});
    defer d.deinit();
    var cell: ObjCell = try .init(&d, object_gpa, .make(&stats, 0));
    defer cell.deinit();
    var h: Held = .{ .cell = &cell, .domain = &d, .stats = &stats };
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    // A failed wait in the writer still lets the reader go.
    defer h.go.store(true, .release);
    try placement.concurrent(&group, io, .{ .executor = 1 }, Held.reader, .{ &h, io });
    try placement.concurrent(&group, io, .{ .executor = 0 }, Held.writer, .{ &h, io });
    try waitDone(io, "the reader and the writer end", &h.done, 2);
    try group.await(io);
    try std.testing.expect(!h.freed_while_held);
    try std.testing.expect(h.freed_after);
    try std.testing.expectEqual(@as(u64, 0), stats.failures.load(.acquire));
}

// ---- 3. Idle executors don't block a grace period ----

test "qsbr: executors with no tasks don't hold up a grace period" {
    const rt = try startRuntime(4);
    defer rt.deinit();
    const io = rt.io();
    var stats: Stats = .{};
    var d: qsbr.Domain = undefined;
    d.init(io, .{});
    defer d.deinit();
    var cell: ObjCell = try .init(&d, object_gpa, .make(&stats, 0));
    defer cell.deinit();
    const W = struct {
        fn run(c: *ObjCell, dom: *qsbr.Domain, s: *Stats, done: *std.atomic.Value(u32), i: std.Io) std.Io.Cancelable!void {
            defer _ = done.fetchAdd(1, .release);
            return taskResult(s, "the writer", storeAndSync(c, dom, s, i));
        }

        fn storeAndSync(c: *ObjCell, dom: *qsbr.Domain, s: *Stats, i: std.Io) !void {
            try c.store(.make(s, 1));
            try dom.synchronize(i);
        }
    };
    var done: std.atomic.Value(u32) = .init(0);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    // Executors 1-3 have nothing to run: they park, offline.
    try placement.concurrent(&group, io, .{ .executor = 0 }, W.run, .{ &cell, &d, &stats, &done, io });
    try waitDone(io, "synchronize returns with three executors parked", &done, 1);
    try group.await(io);
    try std.testing.expectEqual(@as(u64, 0), stats.failures.load(.acquire));
    try std.testing.expect(stats.isFreed(0));
}

// ---- 4. Threads that are not executors ----

const Foreign = struct {
    cell: *ObjCell,
    stats: *Stats,
    io: std.Io,
    stop: std.atomic.Value(bool) = .init(false),
    writers_done: std.atomic.Value(u32) = .init(0),
    next_gen: std.atomic.Value(u64) = .init(1),

    /// Several writers publish: generations come in any order, so only
    /// intactness is checked.
    fn thread(f: *Foreign, reads: u32) void {
        var n: u32 = 0;
        while (n < reads or !f.stop.load(.acquire)) : (n += 1) {
            const g = f.cell.read(f.io);
            if (!g.get().intact()) _ = f.stats.failures.fetchAdd(1, .monotonic);
            g.end();
            const r = f.cell.acquire(f.io);
            if (!r.get().intact()) _ = f.stats.failures.fetchAdd(1, .monotonic);
            r.release();
        }
    }

    fn writer(f: *Foreign, stores: u32) std.Io.Cancelable!void {
        defer _ = f.writers_done.fetchAdd(1, .release);
        return taskResult(f.stats, "a writer", f.write(stores));
    }

    fn write(f: *Foreign, stores: u32) !void {
        for (0..stores) |_| {
            try f.cell.store(.make(f.stats, f.next_gen.fetchAdd(1, .monotonic)));
            try zio.yield();
        }
    }
};

fn foreignReaders(threads: usize, reads: u32, executors: u6, stores: u32) !void {
    const rt = try startRuntime(executors);
    defer rt.deinit();
    const io = rt.io();
    var stats: Stats = .{};
    var d: qsbr.Domain = undefined;
    d.init(io, .{});
    defer d.deinit();
    var cell: ObjCell = try .init(&d, object_gpa, .make(&stats, 0));
    var f: Foreign = .{ .cell = &cell, .stats = &stats, .io = io };
    {
        var pool: [8]std.Thread = undefined;
        var started: usize = 0;
        defer {
            f.stop.store(true, .release);
            for (pool[0..started]) |t| t.join();
        }
        for (pool[0..threads]) |*t| {
            t.* = try std.Thread.spawn(.{}, Foreign.thread, .{ &f, reads });
            started += 1;
        }
        var group: std.Io.Group = .init;
        defer group.cancel(io);
        for (0..executors) |e| try placement.concurrent(&group, io, .{ .executor = e }, Foreign.writer, .{ &f, stores });
        try group.await(io);
    }
    try d.synchronize(io);
    // Every reference the threads counted was given back: `deinit`
    // asserts it of the current value, and every retired one was freed.
    cell.deinit();
    try std.testing.expectEqual(@as(u64, 0), stats.failures.load(.acquire));
    try std.testing.expectEqual(stats.created.load(.acquire), stats.freed.load(.acquire));
}

test "qsbr: reads on threads that are not executors count references, and every one is given back" {
    try foreignReaders(4, 200, 2, 50);
}

test "qsbr: reads on threads that are not executors count references, and every one is given back [stress]" {
    try wait.requireStress();
    try foreignReaders(8, 50_000, 8, 2000);
}

// ---- 5. acquire across suspensions ----

const Holders = struct {
    cell: *ObjCell,
    stats: *Stats,
    holders_done: std.atomic.Value(u32) = .init(0),
    next_gen: std.atomic.Value(u64) = .init(1),

    fn holder(h: *Holders, io: std.Io, yields: u32) std.Io.Cancelable!void {
        defer _ = h.holders_done.fetchAdd(1, .release);
        const r = h.cell.acquire(io);
        defer r.release();
        const gen = r.get().gen;
        for (0..yields) |_| try zio.yield();
        if (!r.get().intact() or r.get().gen != gen) _ = h.stats.failures.fetchAdd(1, .monotonic);
    }

    fn writer(h: *Holders, holders: u32) std.Io.Cancelable!void {
        return taskResult(h.stats, "a writer", h.write(holders));
    }

    fn write(h: *Holders, holders: u32) !void {
        while (h.holders_done.load(.acquire) < holders) {
            try h.cell.store(.make(h.stats, h.next_gen.fetchAdd(1, .monotonic)));
            try zio.yield();
        }
    }
};

fn acquireAcross(executors: u6, holders: u32, yields: u32) !void {
    const rt = try startRuntime(executors);
    defer rt.deinit();
    const io = rt.io();
    var stats: Stats = .{};
    var d: qsbr.Domain = undefined;
    d.init(io, .{});
    defer d.deinit();
    var cell: ObjCell = try .init(&d, object_gpa, .make(&stats, 0));
    var h: Holders = .{ .cell = &cell, .stats = &stats };
    {
        var group: std.Io.Group = .init;
        defer group.cancel(io);
        for (0..holders) |i| try placement.concurrent(&group, io, .{ .executor = i % executors }, Holders.holder, .{ &h, io, yields });
        for (0..executors) |e| try placement.concurrent(&group, io, .{ .executor = e }, Holders.writer, .{ &h, holders });
        try group.await(io);
    }
    try d.synchronize(io);
    cell.deinit();
    try std.testing.expectEqual(@as(u64, 0), stats.failures.load(.acquire));
    try std.testing.expectEqual(stats.created.load(.acquire), stats.freed.load(.acquire));
}

test "qsbr: a reference from acquire stays valid across suspensions while stores run" {
    try acquireAcross(4, 100, 4);
}

test "qsbr: a reference from acquire stays valid across suspensions while stores run [stress]" {
    try wait.requireStress();
    try acquireAcross(8, 1000, 16);
}

// ---- 6. The debug check ----

/// Yields inside a read section on `io`'s runtime, at the lines it
/// returns (the read, then the suspension); `cell` null only computes them.
fn yieldInSection(cell: ?*ObjCell, io: std.Io) [2]u32 {
    const read_line = @src().line + 3;
    const yield_line = read_line + 1;
    if (cell) |c| {
        const g = c.read(io);
        io.sleep(.fromMilliseconds(1), .awake) catch {};
        g.end();
    }
    return .{ read_line, yield_line };
}

test "qsbr: a task that suspends inside a read section panics, naming where the section began" {
    if (!safety.enabled or !zio.held_locks.enabled) return error.SkipZigTest;
    const key = "a task that suspends inside a read section panics";
    if (safety.child.isChild(key)) {
        // The child panics; nothing is cleaned up.
        const rt = try zio.Runtime.init(std.heap.page_allocator, .{ .executors = .exact(1) });
        const io = rt.io();
        const d = try std.heap.page_allocator.create(qsbr.Domain);
        d.init(io, .{});
        var stats: Stats = .{};
        var cell: ObjCell = try .init(d, std.heap.page_allocator, .make(&stats, 0));
        // The main task runs on executor 0: the read is the free one.
        _ = yieldInSection(&cell, io);
        return;
    }
    const out = try safety.child.runPanicking(std.testing.allocator, key);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "SAFETY.md L2: a task suspended while holding 1 lock(s)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "a read section, begun at:") != null);
    // Debug only: an optimized binary inlines the read, and the site is
    // then the nearest frame left out of line (as in safety/lock.zig).
    if (@import("builtin").mode == .debug) {
        const lines = yieldInSection(null, undefined);
        for (lines) |line| {
            var buf: [32]u8 = undefined;
            const needle = try std.fmt.bufPrint(&buf, "qsbr_test.zig:{d}:", .{line});
            if (std.mem.indexOf(u8, out, needle) == null) {
                std.debug.print("expected {s} in the child's stderr:\n{s}\n", .{ needle, out });
                return error.SiteNotNamed;
            }
        }
    }
}
