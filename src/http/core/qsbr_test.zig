//! The QSBR helper (src/http/core/qsbr.zig) on the real zio runtime, with
//! the fork's `quiescent_state`: part of anole's suite (the core's own
//! tests run on its stub zio, where every read is in lock mode).
//! research/s15/lock-inventory.md §3, cases 1-6; case 7 is in zio's suite;
//! case 8 is K7's table of slots (research/s2/tier2/k7-qsbr.md §1).
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

// ---- 8. A table of slots (K7's index) ----

/// An object in the table: `obj.gen` holds its key in the high 32 bits and
/// a version in the low ones (the checksum covers both).
const Entry = struct {
    link: qsbr.Retired = .{ .destroy = destroyLink },
    obj: Obj,

    fn create(stats: *Stats, key: u32, version: u32) !*Entry {
        const e = try object_gpa.create(Entry);
        e.* = .{ .obj = .make(stats, @as(u64, key) << 32 | version) };
        return e;
    }

    fn keyOf(e: *const Entry) u32 {
        return @intCast(e.obj.gen >> 32);
    }

    fn destroyLink(r: *qsbr.Retired) void {
        const e: *Entry = @fieldParentPtr("link", r);
        e.obj.destroy();
        object_gpa.destroy(e);
    }
};

const TableTest = struct {
    executors: u6,
    readers_per_executor: u32,
    /// Readers on threads that are not executors (lock mode), at most 8.
    threads: usize,
    iterations: u32,
    writers_per_executor: u32 = 2,
    ops: u32,
    max_retired: u32,
};

/// 256 atomic slots, two choices per key (k7-qsbr §2), read through
/// `Domain.enter`; writers follow k7-qsbr §5's publish rule. The
/// never-reuse allocator rules out ABA on a kept pointer here; in K7 a
/// stale cmpxchg only removes a valid entry (one miss), and whoever wins a
/// cmpxchg retires what it took out, once.
const Table = struct {
    const n_slots = 256;
    const n_keys = 384;

    domain: *qsbr.Domain,
    stats: *Stats,
    io: std.Io,
    t: TableTest,
    slots: [n_slots]std.atomic.Value(?*Entry) = @splat(.init(null)),
    next_version: std.atomic.Value(u32) = .init(1),
    /// Writes skipped at the gate (`pending()`), and fills with no slot.
    skipped: std.atomic.Value(u64) = .init(0),
    skipped_table: std.atomic.Value(u64) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),

    fn slotsOf(k: u32) [2]u8 {
        const h1: u8 = @truncate(std.hash.Wyhash.hash(1, std.mem.asBytes(&k)));
        const h2: u8 = @truncate(std.hash.Wyhash.hash(2, std.mem.asBytes(&k)));
        return .{ h1, if (h2 == h1) h1 ^ 1 else h2 };
    }

    const Copy = struct { gen: u64, payload: [64]u8, checksum: u64 };

    /// One request: 1-3 lookups in one read section, the payloads copied
    /// into a buffer taken before it, the copies checked after `end`.
    fn lookup(tb: *Table, io: std.Io, r: std.Random) void {
        var out: [3]Copy = undefined;
        var keys: [3]u32 = undefined;
        const want = 1 + r.uintLessThan(usize, 3);
        for (keys[0..want]) |*k| k.* = r.uintLessThan(u32, n_keys);
        var n: usize = 0;
        var bad: u64 = 0;
        const s = tb.domain.enter(io);
        for (keys[0..want]) |k| {
            for (slotsOf(k)) |i| {
                const e = tb.slots[i].load(.seq_cst) orelse continue;
                // Whatever a slot holds is intact and hashes there.
                const home = slotsOf(e.keyOf());
                if (!e.obj.intact() or (home[0] != i and home[1] != i)) bad += 1;
                if (e.keyOf() != k) continue;
                out[n] = .{ .gen = e.obj.gen, .payload = e.obj.payload, .checksum = e.obj.checksum };
                n += 1;
                break;
            }
        }
        s.end();
        for (out[0..n]) |c| {
            if (std.hash.Wyhash.hash(c.gen, &c.payload) != c.checksum) bad += 1;
        }
        if (bad != 0) _ = tb.stats.failures.fetchAdd(bad, .monotonic);
    }

    fn reader(tb: *Table, io: std.Io, seed: u64) std.Io.Cancelable!void {
        var prng: std.Random.DefaultPrng = .init(seed);
        for (0..tb.t.iterations) |i| {
            tb.lookup(io, prng.random());
            if (i % 16 == 15) try zio.yield();
        }
    }

    /// On a thread that is not an executor: `enter` is in lock mode.
    fn thread(tb: *Table, seed: u64) void {
        var prng: std.Random.DefaultPrng = .init(seed);
        var n: u32 = 0;
        while (n < tb.t.iterations or !tb.stop.load(.acquire)) : (n += 1) tb.lookup(tb.io, prng.random());
    }

    fn writer(tb: *Table, seed: u64) std.Io.Cancelable!void {
        return taskResult(tb.stats, "a writer", tb.write(seed));
    }

    /// Fills and replaces (7 in 10) and removes, as K7's request tasks and
    /// sweep do.
    fn write(tb: *Table, seed: u64) !void {
        var prng: std.Random.DefaultPrng = .init(seed);
        const r = prng.random();
        for (0..tb.t.ops) |_| {
            const k = r.uintLessThan(u32, n_keys);
            if (r.uintLessThan(u32, 10) < 7) _ = try tb.fill(k) else tb.remove(k);
            try zio.yield();
        }
    }

    /// A writer skips at half of `max_retired`. K7's trim loop polls
    /// (`pollAll`); here the writer that skips does.
    fn gated(tb: *Table) bool {
        if (tb.domain.pending() < tb.t.max_retired / 2) return false;
        _ = tb.skipped.fetchAdd(1, .monotonic);
        tb.domain.poll();
        return true;
    }

    const Found = struct { slot: u8, e: *Entry };

    /// The first of `slots` holding `k`'s entry: the key is read inside a
    /// read section, and the pointer is kept only for a cmpxchg and a
    /// retire, never dereferenced after `end`.
    fn find(tb: *Table, k: u32, slots: []const u8) ?Found {
        const s = tb.domain.enter(tb.io);
        defer s.end();
        for (slots) |i| {
            const e = tb.slots[i].load(.seq_cst) orelse continue;
            if (e.keyOf() == k) return .{ .slot = i, .e = e };
        }
        return null;
    }

    /// k7-qsbr §5: replace this key's entry, else take the first empty of
    /// its two slots in fixed order, rescanning once; after publishing,
    /// take out a copy a racing writer put in the other slot (seq_cst
    /// store then load on both sides: at least one of two racers sees the
    /// other). Whether `k` was published.
    fn fill(tb: *Table, k: u32) !bool {
        if (tb.gated()) return false;
        const slots = slotsOf(k);
        const new = try Entry.create(tb.stats, k, tb.next_version.fetchAdd(1, .monotonic));
        const at: u8 = publish: for (0..2) |_| {
            if (tb.find(k, &slots)) |f| {
                if (tb.slots[f.slot].cmpxchgStrong(f.e, new, .seq_cst, .seq_cst) == null) {
                    tb.domain.retire(&f.e.link);
                    break :publish f.slot;
                }
                continue;
            }
            for (slots) |i| {
                if (tb.slots[i].cmpxchgStrong(null, new, .seq_cst, .seq_cst) == null) break :publish i;
            }
        } else {
            // Never published: freed at once.
            _ = tb.skipped_table.fetchAdd(1, .monotonic);
            Entry.destroyLink(&new.link);
            return false;
        };
        const other = if (at == slots[0]) slots[1] else slots[0];
        if (tb.find(k, &.{other})) |dup| {
            if (tb.slots[other].cmpxchgStrong(dup.e, null, .seq_cst, .seq_cst) == null) tb.domain.retire(&dup.e.link);
        }
        return true;
    }

    fn remove(tb: *Table, k: u32) void {
        if (tb.gated()) return;
        const f = tb.find(k, &slotsOf(k)) orelse return;
        if (tb.slots[f.slot].cmpxchgStrong(f.e, null, .seq_cst, .seq_cst) == null) tb.domain.retire(&f.e.link);
    }
};

fn slotTable(t: TableTest) !void {
    const rt = try startRuntime(t.executors);
    defer rt.deinit();
    const io = rt.io();
    var stats: Stats = .{};
    var d: qsbr.Domain = undefined;
    d.init(io, .{ .max_retired = t.max_retired });
    defer d.deinit();
    var tb: Table = .{ .domain = &d, .stats = &stats, .io = io, .t = t };
    {
        var pool: [8]std.Thread = undefined;
        var started: usize = 0;
        defer {
            tb.stop.store(true, .release);
            for (pool[0..started]) |th| th.join();
        }
        for (pool[0..t.threads], 0..) |*th, i| {
            th.* = try std.Thread.spawn(.{}, Table.thread, .{ &tb, 0x7ab1e000 + i });
            started += 1;
        }
        var group: std.Io.Group = .init;
        defer group.cancel(io);
        for (0..t.executors) |e| {
            for (0..t.readers_per_executor) |i| try placement.concurrent(&group, io, .{ .executor = e }, Table.reader, .{ &tb, io, e << 32 | i });
            for (0..t.writers_per_executor) |i| try placement.concurrent(&group, io, .{ .executor = e }, Table.writer, .{ &tb, 1 << 48 | e << 32 | i });
        }
        try group.await(io);
    }
    // The writers are done: no key is left in both of its slots.
    var dups: u32 = 0;
    for (0..Table.n_keys) |k| {
        const slots = Table.slotsOf(@intCast(k));
        const a = tb.slots[slots[0]].load(.seq_cst) orelse continue;
        const b = tb.slots[slots[1]].load(.seq_cst) orelse continue;
        if (a.keyOf() == k and b.keyOf() == k) dups += 1;
    }
    try std.testing.expectEqual(@as(u32, 0), dups);
    {
        // The gate: with half of max_retired held retired by counted
        // references, a fill skips.
        var cell: ObjCell = try .init(&d, object_gpa, .make(&stats, 0));
        defer cell.deinit();
        var held: [32]ObjCell.Ref = undefined;
        const half = held[0 .. t.max_retired / 2];
        for (half) |*h| {
            h.* = cell.acquire(io);
            try cell.store(.make(&stats, 0));
        }
        defer for (half) |h| h.release();
        const skipped = tb.skipped.load(.monotonic);
        try std.testing.expect(!try tb.fill(0));
        try std.testing.expectEqual(skipped + 1, tb.skipped.load(.monotonic));
    }
    for (&tb.slots) |*slot| {
        if (slot.swap(null, .seq_cst)) |e| d.retire(&e.link);
    }
    try d.synchronize(io);
    try std.testing.expectEqual(@as(u64, 0), stats.failures.load(.acquire));
    try std.testing.expectEqual(stats.created.load(.acquire), stats.freed.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), d.pending());
}

test "qsbr: a table of atomic slots, filled, replaced and removed by tasks on every executor under many readers (executor and lock mode), never shows a freed or torn object, keeps no key twice and leaks nothing" {
    try slotTable(.{ .executors = 4, .readers_per_executor = 4, .threads = 2, .iterations = 100, .ops = 200, .max_retired = 8 });
}

test "qsbr: a table of atomic slots, filled, replaced and removed by tasks on every executor under many readers (executor and lock mode), never shows a freed or torn object, keeps no key twice and leaks nothing [stress]" {
    try wait.requireStress();
    try slotTable(.{ .executors = 8, .readers_per_executor = 64, .threads = 8, .iterations = 2000, .ops = 2000, .max_retired = 64 });
}

// ---- Writers at the retire list's cap ----

/// Fills `cell`'s domain (max_retired 2) to its cap with objects that
/// acquired references hold, so they stay retired; returns the holders.
fn fillToCap(cell: *ObjCell, stats: *Stats, io: std.Io, gen: *u64) ![2]ObjCell.Ref {
    var held: [2]ObjCell.Ref = undefined;
    for (&held) |*h| {
        h.* = cell.acquire(io);
        try cell.store(.make(stats, gen.*));
        gen.* += 1;
    }
    return held;
}

test "qsbr: compareAndStore at max_retired on an executor ends its read section before it waits" {
    const rt = try startRuntime(1);
    defer rt.deinit();
    // The main task is executor 0's: its reads are the free ones.
    const io = rt.io();
    var stats: Stats = .{};
    var d: qsbr.Domain = undefined;
    d.init(io, .{ .max_retired = 2 });
    defer d.deinit();
    var cell: ObjCell = try .init(&d, object_gpa, .make(&stats, 0));
    defer cell.deinit();
    var gen: u64 = 1;
    const held = try fillToCap(&cell, &stats, io, &gen);
    defer for (held) |h| h.release();
    const g = cell.read(io);
    // At the cap, with no lock held once its section has ended, the retire
    // waits for a grace period: a suspension, which inside the section
    // would panic (L2) or let the object be freed under the guard (M3).
    try std.testing.expect(try cell.compareAndStore(g, .make(&stats, 9)));
    const now = cell.read(io);
    defer now.end();
    try std.testing.expectEqual(@as(u64, 9), now.get().gen);
}

test "qsbr: a store that can't wait (a read section open) goes past max_retired instead of suspending" {
    if (!safety.enabled) return error.SkipZigTest;
    const rt = try startRuntime(1);
    defer rt.deinit();
    const io = rt.io();
    var stats: Stats = .{};
    var d: qsbr.Domain = undefined;
    d.init(io, .{ .max_retired = 2 });
    defer d.deinit();
    var cell: ObjCell = try .init(&d, object_gpa, .make(&stats, 0));
    defer cell.deinit();
    var other: ObjCell = try .init(&d, object_gpa, .make(&stats, 100));
    defer other.deinit();
    var gen: u64 = 1;
    const held = try fillToCap(&cell, &stats, io, &gen);
    defer for (held) |h| h.release();
    {
        // A section on another cell stays open across the stores: they
        // must not suspend (Debug and test builds see the section).
        const g = other.read(io);
        defer g.end();
        for (0..4) |_| {
            try cell.store(.make(&stats, gen));
            gen += 1;
        }
        try std.testing.expectEqual(@as(u64, 100), g.get().gen);
    }
    const now = cell.read(io);
    defer now.end();
    try std.testing.expectEqual(gen - 1, now.get().gen);
}

/// Stores into a domain at its cap with a read section open until the
/// retire list reaches the hard bound (which panics).
fn storePastHardBound(io: std.Io) !void {
    var stats: Stats = .{};
    const d = try std.heap.page_allocator.create(qsbr.Domain);
    d.init(io, .{ .max_retired = 2 });
    var cell: ObjCell = try .init(d, std.heap.page_allocator, .make(&stats, 0));
    var other: ObjCell = try .init(d, std.heap.page_allocator, .make(&stats, 100));
    var gen: u64 = 1;
    _ = try fillToCap(&cell, &stats, io, &gen);
    const g = other.read(io);
    // max_retired 2 times the factor; a ninth retire passes the bound.
    for (0..2 * qsbr.hard_bound_factor + 1) |_| {
        // Hold each new object too, so nothing can be freed meanwhile.
        _ = cell.acquire(io);
        try cell.store(.make(&stats, gen));
        gen += 1;
    }
    g.end();
}

test "qsbr: a store that can't wait panics at the retire list's hard bound" {
    if (!safety.enabled) return error.SkipZigTest;
    const key = "a store that can't wait panics at the retire list's hard bound";
    if (safety.child.isChild(key)) {
        // The child panics; nothing is cleaned up.
        const rt = try zio.Runtime.init(std.heap.page_allocator, .{ .executors = .exact(1) });
        try storePastHardBound(rt.io());
        return;
    }
    const out = try safety.child.runPanicking(std.testing.allocator, key);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "SAFETY.md U4: a qsbr domain has 8 objects retired and not freed (4 times max_retired)") != null);
}

// ---- pollAll and deinit ----

const DeinitRace = struct {
    var copied: std.atomic.Value(bool) = .init(false);
    var go: std.atomic.Value(bool) = .init(false);
    var deinit_waiting: std.atomic.Value(bool) = .init(false);
    var done: std.atomic.Value(bool) = .init(false);

    fn isSet(flag: *std.atomic.Value(bool)) bool {
        return flag.load(.acquire);
    }

    /// pollAll has copied and pinned its batch: it waits for `go`.
    fn afterCopy() void {
        copied.store(true, .release);
        wait.waitUntil(std.testing.io, "the test lets the poll go on", &go, isSet) catch {};
    }

    fn deinitWaits() void {
        deinit_waiting.store(true, .release);
    }

    fn poller() void {
        qsbr.pollAll();
    }

    fn deinitAndFree(d: *qsbr.Domain) void {
        d.deinit();
        object_gpa.destroy(d);
        done.store(true, .release);
    }

    fn deinitWaitingOrDone(_: void) bool {
        return deinit_waiting.load(.acquire) or done.load(.acquire);
    }
};

test "qsbr: a domain deinitialized while pollAll is between copying and polling it waits for that poll" {
    const io = std.testing.io;
    // In pages of its own: polled after a free, it faults.
    const d = try object_gpa.create(qsbr.Domain);
    d.init(io, .{});
    qsbr.test_hooks = .{ .after_copy = DeinitRace.afterCopy, .deinit_waits = DeinitRace.deinitWaits };
    defer qsbr.test_hooks = .{};
    const poller = try std.Thread.spawn(.{}, DeinitRace.poller, .{});
    var poller_joined = false;
    defer if (!poller_joined) {
        DeinitRace.go.store(true, .release);
        poller.join();
    };
    try wait.waitUntil(io, "pollAll has copied the domain", &DeinitRace.copied, DeinitRace.isSet);
    const deiniter = try std.Thread.spawn(.{}, DeinitRace.deinitAndFree, .{d});
    // Either deinit waits for the pinned poll, or (the bug) it has already
    // freed the domain; then the poll goes on.
    const waited = wait.waitUntil(io, "deinit waits or ends", {}, DeinitRace.deinitWaitingOrDone);
    DeinitRace.go.store(true, .release);
    poller.join();
    poller_joined = true;
    deiniter.join();
    try waited;
    try std.testing.expect(DeinitRace.done.load(.acquire));
}
