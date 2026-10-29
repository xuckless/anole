//! Read-mostly data behind an atomic pointer, freed by quiescent-state-based
//! reclamation (SAFETY.md L7, research/s15/lock-inventory.md §3).
//!
//! Readers load the pointer and take no lock; a writer builds a new copy,
//! swaps it in and retires the old one, which is freed once nothing can
//! still read it. This is the QSBR flavour of userspace RCU (liburcu
//! `urcu-qsbr`), with zio's scheduler pass as `rcu_quiescent_state()` and
//! an executor's park as `rcu_thread_offline()` (the fork's
//! `Options.quiescent_state`): a task reads between two suspension points
//! (M3), so once every executor has passed its scheduler since the swap, or
//! parked, no task still holds the old pointer.
//!
//! Two read modes, after Rust's arc-swap (`load` and `load_full`):
//! - `Cell.read`: a borrow, valid until the caller's next suspension point.
//!   On an executor it takes no lock and counts no reference: the check
//!   that the caller is a task on one of the domain's executors (a vtable
//!   compare, a thread-local call, a runtime compare and a load of the
//!   executor's current task), then the pointer load.
//! - `Cell.acquire`: a counted reference, which may be kept across
//!   suspensions and released later.
//!
//! Threads that are not executors of the domain's runtime (the C ABI
//! consumers, the blocking pool, the SQLite writer, `std.Io.Threaded` in
//! tests, the core's stub zio) can't be tracked by the scheduler: there a
//! read takes the domain's spin lock (a leaf) just long enough to count a
//! reference, and `end` drops it ("lock mode"). Every path is correct
//! anywhere; only executors get the free one.
//!
//! A retired object is freed when its grace period has passed and no
//! reference is counted on it: by `poll`, which runs after every `retire`,
//! from `synchronize`, and from the server's trim loop on executor 0
//! (`pollAll`). The retire list is bounded (`Options.max_retired`, U4): a
//! retire that finds it full waits for a grace period first, when the
//! caller can wait; one that can't (see `Domain.retire`) goes past the cap,
//! up to a hard bound of `hard_bound_factor` times it.
//!
//! Liveness: a grace period ends only when every executor of the runtime
//! has passed its scheduler or parked. An executor stuck in one task, or a
//! main thread that is executor 0 and blocks outside zio (a thread join,
//! an OS wait), holds every grace period up until it gets back; reclamation
//! and writers waiting at the cap wait with it.
//!
//! Debug and test builds count a read section with zio like a lock
//! (`safety.readSectionEntered`), so a task that suspends inside one
//! panics and the report names where the section began.
//!
//! Ordering, with zio's side in its runtime.zig (`quiescentReport`, the
//! park): a writer unpublishes with a seq_cst store and starts the grace
//! period with a seq_cst add; readers load the pointer with seq_cst (a
//! plain load on x86-64, `ldar` on arm64, the cost of an acquire load).
//! The seq_cst pairs are the store-buffering (Dekker) pattern between an
//! executor coming back from a park (its seq_cst store of offline = false)
//! and a writer reading its offline flag: the reader's pointer loads must
//! stay seq_cst. An `.acquire` load could be `ldapr` on arm64 (Apple's
//! cores among them), which may be satisfied before the preceding `stlr`
//! of offline = false is visible, and the executor would read the old
//! pointer while the writer saw it offline. The alternative, a seq_cst
//! fence on the online edge as liburcu's `rcu_thread_online` has, would
//! let the loads be acquire; seq_cst loads cost nothing more on x86-64 and
//! arm64, so the fence is not used.
const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");
const safety = @import("anole_safety");
const placement = @import("placement.zig");

/// The fork's quiescent-state counters are compiled in: executors read for
/// free. Otherwise (the core's stub zio, a zio built without
/// `quiescent_state`) every read is in lock mode.
const have_qs = !placement.is_stub and @hasDecl(zio, "quiescent_state_enabled") and zio.quiescent_state_enabled;

const Runtime = if (have_qs) zio.Runtime else void;

/// One retired object, embedded in it: what `Domain.retire` takes. `refs`
/// counts the references `Cell.acquire` and lock-mode reads hold; `destroy`
/// frees the object it is embedded in.
pub const Retired = struct {
    next: ?*Retired = null,
    /// The grace period that must pass before it is freed (0: none).
    target: u64 = 0,
    refs: std.atomic.Value(u32) = .init(0),
    destroy: *const fn (*Retired) void,
};

pub const Options = struct {
    /// Retired objects not yet freed before `retire` waits for a grace
    /// period (U4), when its caller can wait. Objects a counted reference
    /// still holds may take it past this, by at most one per holder; a
    /// caller that can't wait takes it past this, up to
    /// `hard_bound_factor` times it.
    max_retired: u32 = 1024,
};

/// The hard bound of the retire list, in `max_retired`s: a `retire` that
/// can't wait goes past `max_retired` up to this, and past this only a
/// caller that can wait may retire (U4: never unbounded).
pub const hard_bound_factor = 4;

/// A reclamation domain: one retire list and one lock for the reads off
/// the executors. Process-wide (M2): it must not move after `init`, and
/// `deinit` runs after every task and thread that may use it (and the
/// server's trim loop, which polls it) has been joined.
/// owner: whoever created it, process-wide.
pub const Domain = struct {
    io: std.Io,
    rt: if (have_qs) ?*Runtime else void,
    /// Leaf (L4): guards `head` and `pending`, and the counted reads off
    /// the executors. Never held across an allocation or a free (L5).
    lock: safety.SpinLock(.leaf) = .init,
    head: ?*Retired = null,
    /// Retired and not yet freed, including a batch a `poll` is checking.
    pending: u32 = 0,
    max_retired: u32,
    /// The process-wide list `pollAll` walks (under `registry_lock`).
    next_domain: ?*Domain = null,
    /// `pollAll` calls between copying this domain out of the list and
    /// finishing its poll; `deinit` waits for 0 after unlinking it.
    pins: std.atomic.Value(u32) = .init(0),

    /// Sets up `d` in place and adds it to the list the server's trim loop
    /// polls. `io` decides whether executors read for free: a zio `Io`
    /// whose runtime has `quiescent_state`.
    pub fn init(d: *Domain, io: std.Io, opts: Options) void {
        d.* = .{
            .io = io,
            .rt = if (have_qs) zio.Runtime.fromIo(io) else {},
            .max_retired = @max(opts.max_retired, 1),
        };
        registry_lock.lock();
        defer registry_lock.unlock();
        d.next_domain = registry_head;
        registry_head = d;
    }

    /// Frees everything still retired. Only after every user is joined
    /// (M2), so no read section is open and no reference is counted. A
    /// `pollAll` that copied this domain out of the list before it was
    /// unlinked may still be polling it: `deinit` waits for that poll (a
    /// few lock sections and frees, never a suspension) to end.
    pub fn deinit(d: *Domain) void {
        {
            registry_lock.lock();
            defer registry_lock.unlock();
            var link: *?*Domain = &registry_head;
            while (link.*) |other| : (link = &other.next_domain) {
                if (other == d) {
                    link.* = d.next_domain;
                    break;
                }
            }
        }
        if (d.pins.load(.acquire) != 0) {
            if (builtin.is_test) if (test_hooks.deinit_waits) |f| f();
            while (d.pins.load(.acquire) != 0) std.Thread.yield() catch std.atomic.spinLoopHint();
        }
        d.lock.lock();
        var it = d.head;
        d.head = null;
        d.pending = 0;
        d.lock.unlock();
        while (it) |r| {
            it = r.next;
            std.debug.assert(r.refs.load(.acquire) == 0);
            r.destroy(r);
        }
    }

    /// Whether the caller is a task on an executor of the domain's runtime,
    /// tracked by its scheduler: reads there are free.
    fn onExecutor(d: *Domain, io: std.Io) bool {
        if (comptime !have_qs) return false;
        const rt = d.rt orelse return false;
        const caller = zio.Runtime.fromIo(io) orelse return false;
        if (caller != rt) return false;
        const id = rt.currentExecutor() orelse return false;
        // Scheduler code (a completion callback) runs while the executor
        // may be parked, which counts as offline: not a task, so not free.
        return rt.executors.items[id].current_task != null;
    }

    /// A read section for data structures of one's own (`Cell` covers the
    /// common case): what is loaded inside may be used until `end`, which
    /// must come before the caller's next suspension point (M3). Load the
    /// published pointers with `.seq_cst`, and unpublish with a seq_cst
    /// store before `retire`. On an executor it takes no lock (the same
    /// executor check as `Cell.read`); elsewhere it holds the domain's spin
    /// lock (a leaf) until `end`, so keep it short: no allocation, no other
    /// lock, and no `read`, `acquire`, `store`, `retire` or `poll` on the
    /// same domain inside, which would take that lock again and spin on
    /// itself forever on a thread that is not an executor.
    pub fn enter(d: *Domain, io: std.Io) Section {
        safety.readSectionEntered(@returnAddress());
        if (d.onExecutor(io)) return .{ .domain = d, .locked = false };
        d.lock.lock();
        return .{ .domain = d, .locked = true };
    }

    /// Frees `node` (its `destroy`) once every executor has passed its
    /// scheduler since now and no reference is counted on it. The caller
    /// has already unpublished it (a seq_cst store or swap).
    ///
    /// A suspension point only when `max_retired` objects are pending and
    /// the caller can wait (`callerMayWait`: a task outside a no-suspend
    /// region, or a thread that is not an executor, holding no lock and no
    /// read section): it then waits for a grace period first (U4). A caller
    /// that can't wait never waits here: it goes past `max_retired`, and
    /// `poll` (the next retire, `synchronize`, the trim loop) frees later.
    /// At `hard_bound_factor` times `max_retired` such a caller panics
    /// (U4: a writer that can't wait is retiring faster than anything
    /// frees). Writers are rare tasks (a reload, a refill), never request
    /// handlers.
    pub fn retire(d: *Domain, node: *Retired) void {
        d.lock.lock();
        const pending = d.pending;
        d.lock.unlock();
        if (pending >= d.max_retired) {
            if (callerMayWait(d)) {
                // C2: a writer that started retiring finishes; the wait is
                // bounded by the slowest executor's next scheduler pass.
                const prev = d.io.swapCancelProtection(.blocked);
                defer _ = d.io.swapCancelProtection(prev);
                d.synchronize(d.io) catch unreachable;
            } else if (pending >= @as(u64, d.max_retired) * hard_bound_factor) {
                std.debug.panic("SAFETY.md U4: a qsbr domain has {d} objects retired and not freed ({d} times max_retired), and the caller of retire can't wait for a grace period (scheduler code, a no-suspend region, or a lock or read section held); retire from a task that holds nothing", .{ pending, hard_bound_factor });
            }
        }
        node.target = d.snapshot();
        d.lock.lock();
        node.next = d.head;
        d.head = node;
        d.pending += 1;
        d.lock.unlock();
        d.poll();
    }

    /// Whether `retire` may wait here for a grace period without stalling
    /// it or breaking M3/L2: off the domain's executors a wait blocks the
    /// thread, which holds nothing up; on one, only a task outside a
    /// no-suspend region may wait (scheduler code and no-suspend regions
    /// would block the very executor the grace period waits for). Debug
    /// and test builds also refuse when the thread holds a ranked lock or
    /// a read section (`safety.heldLocks`); release builds can't tell, and
    /// a writer that holds one across `store` breaks L2 or M3 there.
    fn callerMayWait(d: *Domain) bool {
        if (safety.heldLocks() != 0) return false;
        if (comptime !have_qs) return true;
        const rt = d.rt orelse return true;
        const id = rt.currentExecutor() orelse return true;
        const ex = rt.executors.items[id];
        return ex.no_suspend == 0 and ex.current_task != null;
    }

    /// Starts a grace period for what was just unpublished (0: no runtime
    /// to wait for, only references).
    fn snapshot(d: *Domain) u64 {
        if (comptime !have_qs) return 0;
        const rt = d.rt orelse return 0;
        return rt.quiescentSnapshot();
    }

    fn passed(d: *Domain, target: u64) bool {
        if (comptime !have_qs) return true;
        if (target == 0) return true;
        const rt = d.rt orelse return true;
        return rt.quiescentPassed(target);
    }

    /// Frees each retired object whose grace period has passed and on
    /// which no reference is counted. Never waits; any thread.
    pub fn poll(d: *Domain) void {
        d.lock.lock();
        var batch = d.head;
        d.head = null;
        d.lock.unlock();
        if (batch == null) return;

        // Grace periods first, outside the lock: one that has passed means
        // every executor section that could have loaded the object has
        // ended, and the references it counted are visible below.
        // `quiescentPassed` is monotonic in its target, so two bounds
        // spare most calls.
        var passed_upto: u64 = 0;
        var failed_from: u64 = std.math.maxInt(u64);
        var candidates: ?*Retired = null;
        var keep: ?*Retired = null;
        var keep_tail: ?*Retired = null;
        while (batch) |r| {
            batch = r.next;
            const ok = r.target <= passed_upto or (r.target < failed_from and blk: {
                const p = d.passed(r.target);
                if (p) passed_upto = r.target else failed_from = r.target;
                break :blk p;
            });
            if (ok) {
                r.next = candidates;
                candidates = r;
            } else {
                r.next = keep;
                keep = r;
                if (keep_tail == null) keep_tail = r;
            }
        }

        // Then the references, under the lock: a lock-mode read loads the
        // pointer and counts its reference inside one lock section, so a
        // count of 0 here can't be followed by a reference to an object
        // already unpublished.
        var free: ?*Retired = null;
        var freed: u32 = 0;
        d.lock.lock();
        while (candidates) |r| {
            candidates = r.next;
            if (r.refs.load(.acquire) == 0) {
                r.next = free;
                free = r;
                freed += 1;
            } else {
                r.next = keep;
                keep = r;
                if (keep_tail == null) keep_tail = r;
            }
        }
        if (keep_tail) |t| {
            t.next = d.head;
            d.head = keep;
        }
        d.pending -= freed;
        d.lock.unlock();

        // L5: frees (and `destroy` hooks, such as SSL_CTX_free) outside the
        // spin lock.
        while (free) |r| {
            free = r.next;
            r.destroy(r);
        }
    }

    /// Waits until every executor has passed its scheduler since the call
    /// (polling every 1 ms), then frees what qualifies. For writers and
    /// teardown, never a request path; holds no lock and no read section.
    pub fn synchronize(d: *Domain, io: std.Io) std.Io.Cancelable!void {
        if (comptime have_qs) if (d.rt) |rt| {
            const target = rt.quiescentSnapshot();
            while (!rt.quiescentPassed(target)) {
                d.poll();
                try io.sleep(.fromMilliseconds(1), .awake);
            }
        };
        d.poll();
    }
};

/// A read section from `Domain.enter`.
pub const Section = struct {
    domain: *Domain,
    locked: bool,

    pub fn end(s: Section) void {
        if (s.locked) s.domain.lock.unlock();
        safety.readSectionLeft(@returnAddress());
    }
};

/// A leaf spin lock (L4/L5) over the list of domains, held only to copy
/// or unlink entries: nothing allocates or waits under it. A spin lock and
/// not an `Io.Mutex`: the list is reached through different `Io`s (zio's
/// tasks, `std.Io.Threaded`, foreign threads), whose futex waits need not
/// wake each other.
var registry_lock: safety.SpinLock(.leaf) = .init;
var registry_head: ?*Domain = null;

/// Test builds: called at the points tests order a race on.
pub const TestHooks = struct {
    /// In `pollAll`, after copying (and pinning) a batch, before polling it.
    after_copy: ?*const fn () void = null,
    /// In `Domain.deinit`, before it waits for a pinned poll to end.
    deinit_waits: ?*const fn () void = null,
};
pub var test_hooks: TestHooks = .{};

/// Polls every domain in the process: the server's trim loop on executor 0
/// calls it, so objects retired with no writer after them are freed too.
pub fn pollAll() void {
    // The domains are copied out in batches and pinned, so their frees and
    // `destroy` hooks run with no lock held (L3), and a `deinit` meanwhile
    // waits for the poll to end instead of freeing the domain under it.
    var batch: [16]*Domain = undefined;
    var skip: usize = 0;
    while (true) {
        var n: usize = 0;
        {
            registry_lock.lock();
            defer registry_lock.unlock();
            var i: usize = 0;
            var it = registry_head;
            while (it) |d| : (it = d.next_domain) {
                if (i >= skip) {
                    if (n == batch.len) break;
                    _ = d.pins.fetchAdd(1, .monotonic);
                    batch[n] = d;
                    n += 1;
                }
                i += 1;
            }
        }
        if (builtin.is_test) if (test_hooks.after_copy) |f| f();
        for (batch[0..n]) |d| {
            d.poll();
            _ = d.pins.fetchSub(1, .release);
        }
        if (n < batch.len) return;
        skip += n;
    }
}

fn hasDestroy(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "destroy"),
        else => false,
    };
}

/// One published value of `T`, read-mostly. `T` is immutable once
/// published; a writer replaces it whole (`store`). When `T` has
/// `pub fn destroy(self: *T) void`, it runs before the memory is freed
/// (`SSL_CTX_free`, `secureZero` of key material).
/// owner: whoever created it, process-wide (its domain's lifetime).
pub fn Cell(comptime T: type) type {
    return struct {
        domain: *Domain,
        gpa: std.mem.Allocator,
        ptr: std.atomic.Value(*Node),

        const Self = @This();

        const Node = struct {
            link: Retired,
            gpa: std.mem.Allocator,
            value: T,

            fn create(gpa: std.mem.Allocator, value: T) !*Node {
                const n = try gpa.create(Node);
                n.* = .{ .link = .{ .destroy = destroy }, .gpa = gpa, .value = value };
                return n;
            }

            fn destroy(r: *Retired) void {
                const n: *Node = @fieldParentPtr("link", r);
                if (comptime hasDestroy(T)) n.value.destroy();
                const gpa = n.gpa;
                gpa.destroy(n);
            }
        };

        /// A borrowed value from `read`: valid until `end`, which comes
        /// before the caller's next suspension point.
        pub const Guard = struct {
            node: *Node,
            /// Off the executors the guard holds a reference.
            counted: bool,

            pub fn get(g: Guard) *const T {
                return &g.node.value;
            }

            pub fn end(g: Guard) void {
                if (g.counted) _ = g.node.link.refs.fetchSub(1, .release);
                safety.readSectionLeft(@returnAddress());
            }
        };

        /// A counted reference from `acquire`: valid until `release`, across
        /// suspensions.
        pub const Ref = struct {
            node: *Node,

            pub fn get(r: Ref) *const T {
                return &r.node.value;
            }

            pub fn release(r: Ref) void {
                _ = r.node.link.refs.fetchSub(1, .release);
            }
        };

        pub fn init(d: *Domain, gpa: std.mem.Allocator, value: T) !Self {
            return .{ .domain = d, .gpa = gpa, .ptr = .init(try Node.create(gpa, value)) };
        }

        /// Frees the current value. Only at teardown, with no reader left,
        /// before its domain's `deinit`.
        pub fn deinit(c: *Self) void {
            const n = c.ptr.load(.acquire);
            std.debug.assert(n.link.refs.load(.acquire) == 0);
            Node.destroy(&n.link);
        }

        /// The current value, borrowed until the caller's next suspension
        /// point (arc-swap's `load`). On an executor: no lock and nothing
        /// counted, only the executor check (a vtable compare, a
        /// thread-local call, a runtime compare, a load of the executor's
        /// current task) and the seq_cst pointer load. Elsewhere a
        /// reference is counted under the domain's spin lock and dropped
        /// by `end`.
        pub fn read(c: *Self, io: std.Io) Guard {
            const d = c.domain;
            if (d.onExecutor(io)) {
                safety.readSectionEntered(@returnAddress());
                return .{ .node = c.ptr.load(.seq_cst), .counted = false };
            }
            d.lock.lock();
            const n = c.ptr.load(.seq_cst);
            _ = n.link.refs.fetchAdd(1, .monotonic);
            d.lock.unlock();
            safety.readSectionEntered(@returnAddress());
            return .{ .node = n, .counted = true };
        }

        /// The current value with a counted reference (arc-swap's
        /// `load_full`): it may be kept across suspensions, until
        /// `release`. A connection that keeps its certificate takes this.
        pub fn acquire(c: *Self, io: std.Io) Ref {
            const d = c.domain;
            if (d.onExecutor(io)) {
                // No suspension between the load and the count: the
                // grace period that frees the object can't pass between
                // them, and a passed one makes the count visible to `poll`.
                const n = c.ptr.load(.seq_cst);
                _ = n.link.refs.fetchAdd(1, .monotonic);
                return .{ .node = n };
            }
            d.lock.lock();
            const n = c.ptr.load(.seq_cst);
            _ = n.link.refs.fetchAdd(1, .monotonic);
            d.lock.unlock();
            return .{ .node = n };
        }

        /// Publishes `value` and retires the one it replaces. Concurrent
        /// writers are fine. On error.OutOfMemory nothing changed and
        /// `value` is still the caller's. A suspension point only as
        /// `Domain.retire` says (the retire list at `max_retired` and a
        /// caller that can wait): a task holds no read section across it.
        pub fn store(c: *Self, value: T) error{OutOfMemory}!void {
            const n = try Node.create(c.gpa, value);
            const old = c.ptr.swap(n, .seq_cst);
            c.domain.retire(&old.link);
        }

        /// Publishes `value` only if the current one is still `expected`
        /// (a guard the caller holds, so its object can't have been freed
        /// and reused: no ABA), for rotations such as ticket keys.
        /// True: published, and `expected` has been ended (its section
        /// closes before the old value is retired, which may wait as
        /// `store` does); don't use or end it again. False: another writer
        /// came first; `value` and `expected` are still the caller's.
        pub fn compareAndStore(c: *Self, expected: Guard, value: T) error{OutOfMemory}!bool {
            const n = try Node.create(c.gpa, value);
            if (c.ptr.cmpxchgStrong(expected.node, n, .seq_cst, .seq_cst) != null) {
                c.gpa.destroy(n);
                return false;
            }
            const old = expected.node;
            expected.end();
            c.domain.retire(&old.link);
            return true;
        }
    };
}

// Off zio (the core's tests run on std.testing.io and its stub zio) every
// read is in lock mode. The executor side is tested on the real zio in
// qsbr_test.zig, part of anole's suite.

const Counted = struct {
    v: u64,
    freed: *u32,

    pub fn destroy(self: *Counted) void {
        self.freed.* += 1;
    }
};

test "qsbr: off zio, a read keeps its value until it ends, and the store's old value is freed after" {
    const io = std.testing.io;
    var d: Domain = undefined;
    d.init(io, .{});
    defer d.deinit();
    var freed: u32 = 0;
    var c: Cell(Counted) = try .init(&d, std.testing.allocator, .{ .v = 1, .freed = &freed });
    defer c.deinit();

    const g = c.read(io);
    try c.store(.{ .v = 2, .freed = &freed });
    try std.testing.expectEqual(@as(u64, 1), g.get().v);
    d.poll();
    try std.testing.expectEqual(@as(u32, 0), freed);
    g.end();
    d.poll();
    try std.testing.expectEqual(@as(u32, 1), freed);
    const now = c.read(io);
    defer now.end();
    try std.testing.expectEqual(@as(u64, 2), now.get().v);
}

test "qsbr: off zio, an acquired reference outlives later stores until released" {
    const io = std.testing.io;
    var d: Domain = undefined;
    d.init(io, .{});
    defer d.deinit();
    var freed: u32 = 0;
    var c: Cell(Counted) = try .init(&d, std.testing.allocator, .{ .v = 1, .freed = &freed });
    defer c.deinit();

    const r = c.acquire(io);
    try c.store(.{ .v = 2, .freed = &freed });
    try c.store(.{ .v = 3, .freed = &freed });
    // The second value had no holder.
    try std.testing.expectEqual(@as(u32, 1), freed);
    try std.testing.expectEqual(@as(u64, 1), r.get().v);
    r.release();
    try d.synchronize(io);
    try std.testing.expectEqual(@as(u32, 2), freed);
}

test "qsbr: compareAndStore replaces only the value the caller read" {
    const io = std.testing.io;
    var d: Domain = undefined;
    d.init(io, .{});
    defer d.deinit();
    var freed: u32 = 0;
    var c: Cell(Counted) = try .init(&d, std.testing.allocator, .{ .v = 1, .freed = &freed });
    defer c.deinit();

    const stale = c.read(io);
    try c.store(.{ .v = 2, .freed = &freed });
    try std.testing.expect(!try c.compareAndStore(stale, .{ .v = 9, .freed = &freed }));
    stale.end();
    const cur = c.read(io);
    // True ends `cur`.
    try std.testing.expect(try c.compareAndStore(cur, .{ .v = 3, .freed = &freed }));
    const now = c.read(io);
    defer now.end();
    try std.testing.expectEqual(@as(u64, 3), now.get().v);
}

test "qsbr: a retire past max_retired frees what it can first" {
    const io = std.testing.io;
    var d: Domain = undefined;
    d.init(io, .{ .max_retired = 2 });
    defer d.deinit();
    var freed: u32 = 0;
    var c: Cell(Counted) = try .init(&d, std.testing.allocator, .{ .v = 0, .freed = &freed });
    defer c.deinit();
    // Each held reference keeps one object retired, past the cap.
    var held: [3]Cell(Counted).Ref = undefined;
    for (&held, 1..) |*h, i| {
        h.* = c.acquire(io);
        try c.store(.{ .v = i, .freed = &freed });
    }
    try std.testing.expectEqual(@as(u32, 0), freed);
    for (held) |h| h.release();
    try c.store(.{ .v = 9, .freed = &freed });
    try std.testing.expectEqual(@as(u32, 4), freed);
}
