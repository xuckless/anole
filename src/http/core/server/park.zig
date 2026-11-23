// Anole code, written for the HTTP core after it left lalinsky/dusty; see
// LICENSE.dusty and THIRD_PARTY_NOTICES for the rest of src/http/core.

//! Idle connections without a task. A connection that has waited
//! `timeout.idle_park` for its next request (or a callback WebSocket for its
//! next message) with nothing buffered ends its task and waits here as a heap
//! object. When its socket becomes readable, a task is started on the same
//! executor to serve it, and that task parks it again when it goes idle once
//! more: at once if it had been parked for the park delay or longer
//! (`Shelf.long_park`), after the delay otherwise.
//!
//! Each executor has a `Shelf` and a driver task (`drive`) that owns the
//! shelf's zio `CompletionQueue`. A connection parks from its own task by
//! submitting a readiness poll, which lives in its heap state, to the queue;
//! the driver takes the polls as they complete and starts a task for each
//! connection. Every second it looks for parked connections past their
//! deadline (keep-alive, or the first request's) and shuts their sockets
//! down, so that their polls come back through the queue, where the driver
//! closes them: in any order, and without canceling polls one by one, which
//! costs a walk of the queue each. When the server stops (`stop`), the driver
//! does the same with all of them, and ends once every poll is back. It also
//! tells the tasks serving adopted connections (WebSockets with callbacks)
//! when a wait for input has lasted the park delay (`Watch`), so that they
//! need no timer per wait.
//! Everything here happens on the shelf's executor, between tasks that do not
//! yield while they touch it, so nothing takes a lock (the doorbell that
//! `stop` rings is thread-safe).
//!
//! Only on zio with pinned executors: elsewhere `supported` is false, or the
//! drivers cannot be placed (`spawnOn` fails), and connections keep their
//! task while idle, as before. Not on Windows, a development target, where
//! idle connections keep their task too.

const std = @import("std");
const zio = @import("zio");
const placement = @import("../placement.zig");

/// The `zio` in use has the completion queue and placement: not the core's
/// test stub. Not Windows.
pub const supported = @import("builtin").os.tag != .windows and !placement.is_stub;

const NetPoll = if (supported) zio.ev.NetPoll else void;
/// A zio task, as `zio.currentTask` returns it.
const TaskPtr = if (supported) @typeInfo(@typeInfo(@TypeOf(zio.currentTask)).@"fn".return_type.?).optional.child else void;

/// How often a shelf looks for parked connections past their deadline:
/// the deadlines are kept to about this.
pub const sweep_interval: std.Io.Duration = .fromSeconds(1);

/// Test builds only: a shorter sweep set by a test (time injection,
/// TESTING.md D4), in nanoseconds; 0 for `sweep_interval`.
var test_sweep_ns: std.atomic.Value(u64) = .init(0);

/// Test builds only: sweeps every `interval` instead of `sweep_interval`
/// (null restores it), for shelves that start after the call.
pub fn setSweepIntervalForTest(interval: ?std.Io.Duration) void {
    if (comptime !@import("builtin").is_test) @compileError("setSweepIntervalForTest is for tests");
    test_sweep_ns.store(if (interval) |d| @intCast(d.nanoseconds) else 0, .monotonic);
}

fn sweepInterval() std.Io.Duration {
    if (comptime @import("builtin").is_test) {
        const ns = test_sweep_ns.load(.monotonic);
        if (ns != 0) return .fromNanoseconds(ns);
    }
    return sweep_interval;
}

/// The awake clock as the calling executor last read it (`placement.tickNow`),
/// read afresh off an executor: the clock every deadline a shelf enforces is
/// taken from, so the sweep never finds one past before it is.
pub fn now(io: std.Io) std.Io.Timestamp {
    return placement.tickNow(io) orelse std.Io.Timestamp.now(io, .awake);
}

/// Whether a deadline at `deadline` (nanoseconds on `now`'s clock) is far
/// enough off for the sweep: one sooner than a sweep from now could come
/// many times its length late, so it goes on an exact timer instead.
pub fn sweepable(io: std.Io, deadline: i96) bool {
    return deadline - now(io).nanoseconds >= sweepInterval().nanoseconds;
}

/// What a parked connection keeps for its shelf, in the connection's own
/// heap state.
pub const Parked = struct {
    vtable: *const VTable,
    /// The readiness poll in the shelf's queue, while parked.
    poll: NetPoll = undefined,
    /// On `Shelf.timed` or `Shelf.untimed` while `phase` is `parked`.
    node: std.DoublyLinkedList.Node = .{},
    /// When the driver closes it (awake clock); null for never.
    deadline: ?std.Io.Timestamp = null,
    phase: Phase = .running,
    /// When it parked (awake clock).
    parked_at: std.Io.Timestamp = .zero,
    /// It woke after being parked for `Shelf.long_park` or more: the task
    /// started for it parks it again once it has served what woke it (see
    /// `Shelf.long_park`).
    woke_from_long: bool = false,

    /// From `VTable.expire`'s work, once done with the connection: shuts
    /// its socket down so that its poll comes back for the driver to close
    /// it, or closes it now if the poll is back already. On the shelf's
    /// executor.
    pub fn expireDone(self: *Parked) void {
        self.apply(self.step(.expire_done));
    }

    /// Where the connection is between its task and its shelf. Owner: the
    /// shelf's executor (the connection's task parks it there, the driver
    /// and the tasks it spawns `.local` do the rest), so no lock; tasks
    /// interleave only where one yields, which is `VTable.expire`'s work
    /// (a TLS close_notify) while `expiring`. Every transition is a cell of
    /// `table`, written only by `step`; a new case is a cell or a phase
    /// there, not a flag beside it.
    ///
    /// | phase \ event | park | expire | poll_back | canceled | expire_done | wake_failed |
    /// |---|---|---|---|---|---|---|
    /// | running | parked | - (1) | - (2) | - (2) | - (3) | closed, close |
    /// | parked | - (4) | expiring | running, wake | closed, close | - (3) | - (5) |
    /// | expiring | - (6) | - (6) | expiring_back | expiring_back | shut, shutdown | - (5) |
    /// | expiring_back | - (6) | - (6) | - (7) | - (7) | closed, close | - (5) |
    /// | shut | - (6) | - (6) | closed, close | closed, close | - (8) | - (5) |
    /// | closed | - (9) | - (9) | - (9) | - (9) | - (9) | - (9) |
    ///
    /// "-": ignored, the phase stays and nothing is done. (1) Not on a list:
    /// sweep and expireAll find only parked entries. (2) No poll is queued.
    /// (3) `expire` has not begun. (4) `settle` parks once per task end; a
    /// second park would queue the poll twice. (5) No wake began. (6) Off
    /// the lists and its poll still queued: only the poll's return or
    /// `expireDone` reach it. (7) One poll per park, and it is back. (8)
    /// `VTable.expire` finishes once. (9) Freed, or about to be: `closed`
    /// is set just before `VTable.close`, so that a repeat cannot close
    /// twice. The callers unlist a `parked` entry before stepping it out of
    /// `parked` (`expire`, `pollBack`); `pollBack` sets `woke_from_long`
    /// before a wake. A connection whose poll is back while `expiring` is
    /// closed by whichever of `expireDone` and the poll's return comes
    /// second.
    pub const Phase = enum {
        /// A task serves it, or it never parked.
        running,
        /// On a list, its poll in the shelf's queue.
        parked,
        /// Off the lists, poll queued, `VTable.expire` not done with it
        /// (it may wait).
        expiring,
        /// The poll came back while `expiring`: `expireDone` closes it.
        expiring_back,
        /// `VTable.expire` is done and the socket shut down: the poll's
        /// return closes it.
        shut,
        /// Handed to `VTable.close`.
        closed,
    };

    const Event = enum {
        park,
        /// Its deadline passed (`Shelf.sweep`) or the server stops
        /// (`Shelf.expireAll`).
        expire,
        /// Its poll is back: readable, failed or shut down.
        poll_back,
        /// The driver was canceled and zio returned its poll.
        canceled,
        /// `VTable.expire` is done with it, or failed at once.
        expire_done,
        /// `VTable.wake` failed.
        wake_failed,
    };

    /// What follows a transition (list work stays with the shelf).
    const Act = enum { none, wake, shutdown, close };

    const Step = struct { next: Phase, act: Act = .none };

    /// The doc table on `Phase`, every cell listed.
    const table = std.EnumArray(Phase, std.EnumArray(Event, Step)).init(.{
        .running = .init(.{
            .park = .{ .next = .parked },
            .expire = .{ .next = .running },
            .poll_back = .{ .next = .running },
            .canceled = .{ .next = .running },
            .expire_done = .{ .next = .running },
            .wake_failed = .{ .next = .closed, .act = .close },
        }),
        .parked = .init(.{
            .park = .{ .next = .parked },
            .expire = .{ .next = .expiring },
            .poll_back = .{ .next = .running, .act = .wake },
            .canceled = .{ .next = .closed, .act = .close },
            .expire_done = .{ .next = .parked },
            .wake_failed = .{ .next = .parked },
        }),
        .expiring = .init(.{
            .park = .{ .next = .expiring },
            .expire = .{ .next = .expiring },
            .poll_back = .{ .next = .expiring_back },
            .canceled = .{ .next = .expiring_back },
            .expire_done = .{ .next = .shut, .act = .shutdown },
            .wake_failed = .{ .next = .expiring },
        }),
        .expiring_back = .init(.{
            .park = .{ .next = .expiring_back },
            .expire = .{ .next = .expiring_back },
            .poll_back = .{ .next = .expiring_back },
            .canceled = .{ .next = .expiring_back },
            .expire_done = .{ .next = .closed, .act = .close },
            .wake_failed = .{ .next = .expiring_back },
        }),
        .shut = .init(.{
            .park = .{ .next = .shut },
            .expire = .{ .next = .shut },
            .poll_back = .{ .next = .closed, .act = .close },
            .canceled = .{ .next = .closed, .act = .close },
            .expire_done = .{ .next = .shut },
            .wake_failed = .{ .next = .shut },
        }),
        .closed = .init(.{
            .park = .{ .next = .closed },
            .expire = .{ .next = .closed },
            .poll_back = .{ .next = .closed },
            .canceled = .{ .next = .closed },
            .expire_done = .{ .next = .closed },
            .wake_failed = .{ .next = .closed },
        }),
    });

    /// The only writer of `phase`.
    fn step(self: *Parked, ev: Event) Act {
        const s = table.get(self.phase).get(ev);
        self.phase = s.next;
        return s.act;
    }

    /// Runs `act`; after `.close`, `self` is freed.
    fn apply(self: *Parked, act: Act) void {
        switch (act) {
            .none => {},
            // Only `pollBack` gets it, and runs it there (it needs the shelf).
            .wake => unreachable,
            .shutdown => if (comptime supported) zio.os.net.shutdown(self.poll.handle, .both) catch {},
            .close => self.vtable.close(self),
        }
    }
};

/// Idle detection for a task that serves a connection and waits for its
/// input many times over (an adopted connection, a WebSocket with
/// callbacks), without a timer armed and cleared around every wait: the
/// task marks its waits (`begin`, `end`) and is registered with its shelf
/// for as long as it serves (`Shelf.watch`), and the shelf's driver, which
/// looks at every registered task each quarter `Shelf.long_park`, ends a
/// wait that has gone on for `long_park` (or up to a quarter less) the way
/// a timer would, with an auto-cancel of the task's wait. A busy connection
/// then pays two stores per wait, where a timer took a clock read, a lock
/// and two operations on the executor's timer heap, whose cost grows with
/// the number of sockets waiting.
pub const Watch = struct {
    node: std.DoublyLinkedList.Node = .{},
    task: TaskPtr = undefined,
    /// Bumped as each wait begins.
    seq: u32 = 0,
    waiting: bool = false,
    /// What the driver last saw: the wait, and how many of its looks found
    /// that same wait going on.
    seen_seq: u32 = 0,
    seen_count: u8 = 0,
    /// The driver canceled the current wait, which the task's `delivered`
    /// count was at.
    poked: bool = false,
    delivered: u7 = 0,

    /// Before the task waits for input.
    pub fn begin(self: *Watch) void {
        self.seq +%= 1;
        self.waiting = true;
    }

    /// After the wait returned, with `canceled` whether it failed with
    /// `error.Canceled`: true when this watch ended the wait (the input has
    /// been idle for the park delay), and the cancel is used up. A wait that
    /// returned anyway takes back a cancel that came too late to end it, so
    /// no later wait of the task's sees it.
    pub fn end(self: *Watch, canceled: bool) bool {
        self.waiting = false;
        if (comptime !supported) return false;
        if (!self.poked) return false;
        self.poked = false;
        if (canceled) return self.task.checkAutoCancel();
        _ = self.task.retractAutoCancel(self.delivered);
        return false;
    }

    /// From the driver, on the task's executor: cancels the task's wait.
    fn poke(self: *Watch) void {
        if (comptime !supported) return;
        self.poked = true;
        if (self.task.setCanceled(.auto)) |d| {
            self.delivered = d;
            self.task.wake();
        } else {
            // Canceled already (the server stops): nothing to take back.
            self.poked = false;
        }
    }
};

/// A deadline of a task serving a connection (a request's, the wait for
/// the next one's, a write's), kept to the shelf's sweep rather than to a
/// timer: the task stores it (`set`, `clear`), is registered with its shelf
/// for as long as it serves (`Shelf.register`), and every
/// `sweep_interval` the driver ends whatever the task is doing past it
/// with an auto-cancel, the way a timer would, up to about a second late.
/// A request then pays a few stores for its deadlines, where timers took a
/// clock read, the executor's timer lock and two heap operations each.
pub const Lazy = struct {
    node: std.DoublyLinkedList.Node = .{},
    // SAFETY: set by `Shelf.register`, and read only while registered.
    task: TaskPtr = undefined,
    /// When the driver cancels the task, in nanoseconds on the awake clock
    /// (`now`); `never` for no deadline.
    deadline: i96 = never,
    /// The driver canceled the task, which the task's `delivered` count was
    /// at, and nobody has claimed or taken the cancel back yet.
    poked: bool = false,
    delivered: u7 = 0,
    /// The task is in a wait that the server's drain should end
    /// (`Shelf.drainWake`): an HTTP/2 reader waiting for input, which then
    /// sends the drain's GOAWAY. Set and cleared by the task around the
    /// wait only, so a drain never cuts what it does in between (a write).
    wake_on_drain: bool = false,

    pub const never = std.math.maxInt(i96);

    /// A new deadline, in place of the last. A cancel the last one made and
    /// no cancelation point reported yet is taken back, as
    /// `zio.AutoCancel.clear` does, so that it does not fail what the task
    /// does next.
    pub fn set(self: *Lazy, deadline: i96) void {
        self.retract();
        self.deadline = deadline;
    }

    pub fn clear(self: *Lazy) void {
        self.set(never);
    }

    /// Whether the cancel the task just got was this deadline's, which it
    /// then consumes (`zio.AutoCancel.check`).
    pub fn fired(self: *Lazy) bool {
        if (comptime !supported) return false;
        if (!self.poked) return false;
        self.poked = false;
        return self.task.checkAutoCancel();
    }

    /// Ends the task's wait now, as its deadline would, if it is in a
    /// wait the drain may end (`wake_on_drain`) and no cancel of this
    /// deadline is pending: the drain's bell (`Shelf.drainWake`), or
    /// another task of the same connection with news for it. On the
    /// task's executor, while it is registered.
    pub fn wakeWait(self: *Lazy) void {
        if (self.wake_on_drain and !self.poked) self.poke();
    }

    fn retract(self: *Lazy) void {
        if (comptime !supported) return;
        if (!self.poked) return;
        self.poked = false;
        _ = self.task.retractAutoCancel(self.delivered);
    }

    /// From the driver, on the task's executor: the deadline passed. It
    /// fires once, as a timer does.
    fn poke(self: *Lazy) void {
        if (comptime !supported) return;
        self.deadline = never;
        self.poked = true;
        if (self.task.setCanceled(.auto)) |d| {
            self.delivered = d;
            self.task.wake();
        } else {
            // Canceled already (the server stops): nothing to take back.
            self.poked = false;
        }
    }
};

/// What a shelf does with a connection, supplied by its owner. Each is
/// called from the shelf's driver task.
pub const VTable = struct {
    /// Starts a task to serve the connection (`spawnLocal`). An error
    /// leaves it to the shelf, which closes it.
    wake: *const fn (*Parked) anyerror!void,
    /// Ends a connection whose deadline passed or whose server is stopping,
    /// gracefully where that takes a write (a TLS close_notify, which may
    /// wait): starts a task that does that and then calls
    /// `Parked.expireDone`, or calls it at once. An error calls it from the
    /// shelf.
    expire: *const fn (*Parked) anyerror!void,
    /// Closes the connection and frees it.
    close: *const fn (*Parked) void,
};

/// One executor's parked connections.
pub const Shelf = struct {
    /// Those with a deadline, soonest first. A connection is added as it
    /// parks, and every deadline is "parked at, plus a constant" for each
    /// kind of wait, so it is nearly always added at the tail.
    timed: std.DoublyLinkedList = .{},
    untimed: std.DoublyLinkedList = .{},
    /// How many polls are in the queue: parked connections, and expired
    /// ones not closed yet. Written on the shelf's executor only, read from
    /// anywhere (`Server.parkedConnections`).
    count: std.atomic.Value(usize) = .init(0),
    /// The server stopped taking parked connections (`stop`).
    closed: bool = false,
    cq: if (supported) zio.CompletionQueue else void = if (supported) .init() else {},
    /// The driver's doorbell, rung by `stop` from any thread.
    bell: if (supported) zio.ev.Async else void = if (supported) .init() else {},
    stopping: std.atomic.Value(bool) = .init(false),
    /// The server's drain has news for the tasks waiting with
    /// `Lazy.wake_on_drain` (`drainWake`).
    draining: std.atomic.Value(bool) = .init(false),
    /// The driver has ended, every connection parked here closed.
    done: std.Io.Event = .unset,
    /// For the clock.
    io: std.Io,
    /// A connection that was parked this long or longer when its socket
    /// became readable is woken with `Parked.woke_from_long` set: it is
    /// mostly idle, so it parks again as soon as it has served what woke it,
    /// rather than holding a task for the whole park delay. That keeps the
    /// tasks (and stacks) a burst of such wakes needs to about the burst's
    /// concurrency, where holding each task for the delay would need one for
    /// every connection woken within it, on stacks that the stack pool has
    /// given back to the system meanwhile, each costing an mprotect and page
    /// faults to make again. One that comes back sooner keeps its task, so
    /// a connection that turns busy pays for one extra park at most.
    long_park: std.Io.Duration,
    /// The tasks serving adopted connections on this executor (`Watch`).
    watches: std.DoublyLinkedList = .{},
    /// The deadlines of the tasks serving connections on this executor
    /// (`Lazy`).
    lazies: std.DoublyLinkedList = .{},
    /// Test builds only: connections ended by `sweep` because their
    /// deadline passed while they were parked (not by the stop).
    test_deadline_expired: if (@import("builtin").is_test) std.atomic.Value(u32) else void = if (@import("builtin").is_test) .init(0) else {},
    /// Test builds only: `Lazy` deadlines `sweep` found past, and how many
    /// sweeps ran.
    test_lazy_fired: if (@import("builtin").is_test) std.atomic.Value(u32) else void = if (@import("builtin").is_test) .init(0) else {},
    test_sweeps: if (@import("builtin").is_test) std.atomic.Value(u32) else void = if (@import("builtin").is_test) .init(0) else {},

    /// Registers the calling task, on the shelf's executor, for idle
    /// detection while it serves a connection: `unwatch` before it is done
    /// with `w`.
    pub fn watch(self: *Shelf, w: *Watch) void {
        if (comptime !supported) return;
        w.* = .{ .task = zio.currentTask().? };
        const first = self.watches.first == null;
        self.watches.append(&w.node);
        // The driver looks at watches only while it has any.
        if (first) self.bell.notify();
    }

    /// Takes `w` off the shelf's watch list (`watch`), on the same executor,
    /// before the task that registered it is done with the connection.
    pub fn unwatch(self: *Shelf, w: *Watch) void {
        if (comptime !supported) return;
        self.watches.remove(&w.node);
    }

    /// Registers the calling task's deadline `l`, on the shelf's executor,
    /// for the sweep to enforce: `unregister` before the task is done with
    /// `l`. False when the shelf is closed (the server stops), whose driver
    /// is ending: the task keeps its deadlines on a timer.
    pub fn register(self: *Shelf, l: *Lazy) bool {
        if (comptime !supported) return false;
        if (self.closed) return false;
        l.* = .{ .task = zio.currentTask().? };
        self.lazies.append(&l.node);
        return true;
    }

    /// Takes `l` off the shelf (`register`), on the same executor.
    pub fn unregister(self: *Shelf, l: *Lazy) void {
        if (comptime !supported) return;
        self.lazies.remove(&l.node);
    }

    /// How often the driver looks at the watches: each quarter
    /// `long_park`, so that a wait seen at four looks in a row
    /// (`lookAtWatches`) has gone on for 3/4 to all of `long_park`, never
    /// longer, as with a timer armed for it.
    fn watchInterval(self: *const Shelf) std.Io.Duration {
        return .fromNanoseconds(@max(self.long_park.nanoseconds >> 2, std.time.ns_per_ms));
    }

    /// The driver's look at the watches: ends each wait seen going on at
    /// the last three looks too.
    pub fn lookAtWatches(self: *Shelf) void {
        if (self.closed) return;
        var it = self.watches.first;
        while (it) |n| : (it = n.next) {
            const w: *Watch = @alignCast(@fieldParentPtr("node", n));
            if (!w.waiting or w.seen_seq != w.seq) {
                w.seen_seq = w.seq;
                w.seen_count = 0;
                continue;
            }
            if (w.poked) continue;
            w.seen_count +|= 1;
            if (w.seen_count >= 3) w.poke();
        }
    }

    /// Parks `p`, its socket `handle` watched for input. False when it
    /// cannot be (the shelf is closed, or its queue refuses): the caller
    /// keeps or closes the connection. Called on the executor that owns the
    /// shelf, as the last thing the connection's task does with the
    /// connection: from then on a task may be serving it.
    pub fn park(self: *Shelf, p: *Parked, handle: anytype) bool {
        if (comptime !supported) return false;
        if (self.closed) return false;
        p.poll = .init(handle, .recv);
        p.parked_at = now(self.io);
        self.cq.submit(&p.poll.c) catch return false;
        _ = p.step(.park);
        self.insert(p);
        _ = self.count.fetchAdd(1, .monotonic);
        return true;
    }

    /// Asks the driver to close every parked connection and end. From any
    /// thread; `done` is set once it has.
    pub fn stop(self: *Shelf) void {
        if (comptime !supported) return;
        self.stopping.store(true, .release);
        self.bell.notify();
    }

    /// Asks the driver to end the waits of the tasks registered with
    /// `Lazy.wake_on_drain` set, as a deadline would: the server's drain
    /// has something for them to send. From any thread.
    pub fn drainWake(self: *Shelf) void {
        if (comptime !supported) return;
        self.draining.store(true, .release);
        self.bell.notify();
    }

    /// The driver's answer to `drainWake`, on the shelf's executor.
    fn pokeDraining(self: *Shelf) void {
        var it = self.lazies.first;
        while (it) |n| : (it = n.next) {
            // SAFETY: only `Lazy` nodes are on `lazies` (`register`).
            const l: *Lazy = @alignCast(@fieldParentPtr("node", n));
            l.wakeWait();
        }
    }

    fn insert(self: *Shelf, p: *Parked) void {
        const deadline = p.deadline orelse return self.untimed.append(&p.node);
        var after = self.timed.last;
        while (after) |n| : (after = n.prev) {
            const other: *Parked = @alignCast(@fieldParentPtr("node", n));
            if (other.deadline.?.nanoseconds <= deadline.nanoseconds) break;
        }
        if (after) |n| self.timed.insertAfter(n, &p.node) else self.timed.prepend(&p.node);
    }

    fn remove(self: *Shelf, p: *Parked) void {
        if (p.deadline != null) self.timed.remove(&p.node) else self.untimed.remove(&p.node);
    }

    /// Takes `p` off the lists and ends it: it closes when its poll is
    /// back. `p` may be freed once `VTable.expire` is called.
    fn expire(self: *Shelf, p: *Parked) void {
        self.remove(p);
        _ = p.step(.expire);
        p.vtable.expire(p) catch p.expireDone();
    }

    /// Expires the parked connections whose deadline is not after `at`,
    /// and cancels the tasks whose `Lazy` deadline is not. From the driver
    /// (tests call it directly), on the shelf's executor.
    pub fn sweep(self: *Shelf, at: std.Io.Timestamp) void {
        if (@import("builtin").is_test) _ = self.test_sweeps.fetchAdd(1, .monotonic);
        while (self.timed.first) |n| {
            const p: *Parked = @alignCast(@fieldParentPtr("node", n));
            if (p.deadline.?.nanoseconds > at.nanoseconds) break;
            if (@import("builtin").is_test) _ = self.test_deadline_expired.fetchAdd(1, .monotonic);
            self.expire(p);
        }
        var it = self.lazies.first;
        while (it) |n| : (it = n.next) {
            // SAFETY: only `Lazy` nodes are on `lazies` (`register`).
            const l: *Lazy = @alignCast(@fieldParentPtr("node", n));
            if (l.deadline <= at.nanoseconds) {
                if (@import("builtin").is_test) _ = self.test_lazy_fired.fetchAdd(1, .monotonic);
                l.poke();
            }
        }
    }

    /// Expires every parked connection, and takes no more.
    fn expireAll(self: *Shelf) void {
        self.closed = true;
        while (self.timed.first orelse self.untimed.first) |n| {
            self.expire(@alignCast(@fieldParentPtr("node", n)));
        }
    }

    /// `p`'s poll is back (`ev` `.poll_back`): its socket is readable (or
    /// failed, which the next read reports), or was shut down; or zio
    /// returned it as the driver was canceled (`.canceled`).
    fn pollBack(self: *Shelf, p: *Parked, ev: Parked.Event) void {
        _ = self.count.fetchSub(1, .monotonic);
        if (p.phase == .parked) self.remove(p);
        switch (p.step(ev)) {
            .wake => {
                const parked_for = p.parked_at.durationTo(now(self.io));
                p.woke_from_long = parked_for.nanoseconds >= self.long_park.nanoseconds;
                p.vtable.wake(p) catch p.apply(p.step(.wake_failed));
            },
            else => |act| p.apply(act),
        }
    }
};

/// A shelf's driver, on its executor: starts a task for each parked
/// connection whose socket becomes readable, expires those past their
/// deadline every `sweep_interval`, ends the waits of watched tasks that
/// have gone on for the park delay (`Watch`), and once the shelf stops,
/// expires the rest and ends when all of them are closed.
pub fn drive(shelf: *Shelf, io: std.Io) std.Io.Cancelable!void {
    if (comptime !supported) return;
    defer shelf.done.set(io);
    // Refused only when the queue cannot be used at all.
    shelf.cq.submit(&shelf.bell.c) catch {
        shelf.closed = true;
        return;
    };
    const start: std.Io.Clock.Timestamp = .{ .raw = now(io), .clock = .awake };
    var next_sweep = start.addDuration(.{ .raw = sweepInterval(), .clock = .awake });
    var next_look: ?std.Io.Clock.Timestamp = null;
    while (!shelf.closed or shelf.count.load(.monotonic) > 0) {
        // The same clock as every deadline the sweep enforces.
        const tick: std.Io.Clock.Timestamp = .{ .raw = now(io), .clock = .awake };
        // Here rather than on a timeout only, which a steady stream of
        // wakes would never let happen.
        if (tick.compare(.gte, next_sweep)) {
            shelf.sweep(tick.raw);
            next_sweep = tick.addDuration(.{ .raw = sweepInterval(), .clock = .awake });
        }
        if (shelf.watches.first == null) {
            next_look = null;
        } else if (next_look == null) {
            next_look = tick.addDuration(.{ .raw = shelf.watchInterval(), .clock = .awake });
        } else if (tick.compare(.gte, next_look.?)) {
            shelf.lookAtWatches();
            next_look = tick.addDuration(.{ .raw = shelf.watchInterval(), .clock = .awake });
        }
        const until = if (next_look) |l| (if (l.compare(.lt, next_sweep)) l else next_sweep) else next_sweep;
        const left = tick.durationTo(until).raw.nanoseconds;
        const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromNanoseconds(@max(0, left)), .clock = .awake } };
        const c = shelf.cq.waitTimeout(.fromStd(timeout)) catch |err| switch (err) {
            error.Timeout => continue,
            // Canceled rather than stopped: zio has canceled every poll and
            // closed the queue, and what comes back is closed here.
            error.Canceled => {
                shelf.closed = true;
                while (shelf.cq.next()) |back| {
                    if (back == &shelf.bell.c) continue;
                    shelf.pollBack(@alignCast(@fieldParentPtr("poll", back.cast(NetPoll))), .canceled);
                }
                return error.Canceled;
            },
            error.Closed => break,
        };
        if (c == &shelf.bell.c) {
            if (shelf.draining.swap(false, .acq_rel)) shelf.pokeDraining();
            if (shelf.stopping.load(.acquire)) shelf.expireAll() else shelf.cq.submit(&shelf.bell.c) catch {};
            continue;
        }
        shelf.pollBack(@alignCast(@fieldParentPtr("poll", c.cast(NetPoll))), .poll_back);
    }
    shelf.cq.close();
}

/// `group`'s `spawnInto(.local, func, args)`, from a task on an executor.
pub fn spawnLocal(group: *std.Io.Group, func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) !void {
    if (comptime !supported) return error.Unsupported;
    return zio.Group.fromStd(group).spawnInto(.local, func, args);
}

/// `group`'s `spawnInto(.{ .executor = index }, func, args)`. Fails with
/// `error.InvalidPlacement` where tasks cannot be pinned (zio's
/// work-stealing scheduling), and so where nothing can park.
pub fn spawnOn(group: *std.Io.Group, index: usize, func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) !void {
    if (comptime !supported) return error.Unsupported;
    return zio.Group.fromStd(group).spawnInto(.{ .executor = @intCast(index) }, func, args);
}

/// Whether the zio running `io` can park connections: placement applies
/// (see `spawnOn` for the scheduling part).
pub fn usable(io: std.Io) bool {
    if (comptime !supported) return false;
    return placement.runtime(io) != null;
}

test "Parked.phase: every (phase, event) pair" {
    const P = Parked.Phase;
    const Row = struct { from: P, event: Parked.Event, to: P, act: Parked.Act = .none };
    // Written apart from `Parked.table`, so that the table is not checked
    // against itself.
    const rows = [_]Row{
        .{ .from = .running, .event = .park, .to = .parked },
        .{ .from = .running, .event = .expire, .to = .running },
        .{ .from = .running, .event = .poll_back, .to = .running },
        .{ .from = .running, .event = .canceled, .to = .running },
        .{ .from = .running, .event = .expire_done, .to = .running },
        .{ .from = .running, .event = .wake_failed, .to = .closed, .act = .close },

        .{ .from = .parked, .event = .park, .to = .parked },
        .{ .from = .parked, .event = .expire, .to = .expiring },
        .{ .from = .parked, .event = .poll_back, .to = .running, .act = .wake },
        .{ .from = .parked, .event = .canceled, .to = .closed, .act = .close },
        .{ .from = .parked, .event = .expire_done, .to = .parked },
        .{ .from = .parked, .event = .wake_failed, .to = .parked },

        .{ .from = .expiring, .event = .park, .to = .expiring },
        .{ .from = .expiring, .event = .expire, .to = .expiring },
        .{ .from = .expiring, .event = .poll_back, .to = .expiring_back },
        .{ .from = .expiring, .event = .canceled, .to = .expiring_back },
        .{ .from = .expiring, .event = .expire_done, .to = .shut, .act = .shutdown },
        .{ .from = .expiring, .event = .wake_failed, .to = .expiring },

        .{ .from = .expiring_back, .event = .park, .to = .expiring_back },
        .{ .from = .expiring_back, .event = .expire, .to = .expiring_back },
        .{ .from = .expiring_back, .event = .poll_back, .to = .expiring_back },
        .{ .from = .expiring_back, .event = .canceled, .to = .expiring_back },
        .{ .from = .expiring_back, .event = .expire_done, .to = .closed, .act = .close },
        .{ .from = .expiring_back, .event = .wake_failed, .to = .expiring_back },

        .{ .from = .shut, .event = .park, .to = .shut },
        .{ .from = .shut, .event = .expire, .to = .shut },
        .{ .from = .shut, .event = .poll_back, .to = .closed, .act = .close },
        .{ .from = .shut, .event = .canceled, .to = .closed, .act = .close },
        .{ .from = .shut, .event = .expire_done, .to = .shut },
        .{ .from = .shut, .event = .wake_failed, .to = .shut },

        .{ .from = .closed, .event = .park, .to = .closed },
        .{ .from = .closed, .event = .expire, .to = .closed },
        .{ .from = .closed, .event = .poll_back, .to = .closed },
        .{ .from = .closed, .event = .canceled, .to = .closed },
        .{ .from = .closed, .event = .expire_done, .to = .closed },
        .{ .from = .closed, .event = .wake_failed, .to = .closed },
    };
    // A new phase or event needs its rows.
    comptime std.debug.assert(rows.len == std.enums.values(P).len * std.enums.values(Parked.Event).len);
    var seen = std.EnumArray(P, std.EnumSet(Parked.Event)).initFill(.empty);
    for (rows) |r| {
        try std.testing.expect(!seen.getPtr(r.from).contains(r.event));
        seen.getPtr(r.from).insert(r.event);
        var p: Parked = .{ .vtable = undefined, .phase = r.from };
        errdefer std.debug.print("{t} + {t}\n", .{ r.from, r.event });
        try std.testing.expectEqual(r.act, p.step(r.event));
        try std.testing.expectEqual(r.to, p.phase);
    }
}

// Runs on the core's zio stub (core-test), where nothing is polled and the
// shutdown act compiles out; on the real zio it would shut down an unset
// poll's socket, so it skips there. The real shutdown is covered end to end
// by park_test.zig's deadline and TLS rows.
test "Parked.phase: a shelf closes each connection once, in every order" {
    if (comptime supported) return error.SkipZigTest;
    const Conn = struct {
        p: Parked = .{ .vtable = &vtable },
        expire_mode: enum { deferred, done_inline, fails } = .deferred,
        wake_fails: bool = false,
        wakes: u32 = 0,
        closes: u32 = 0,

        const vtable: VTable = .{ .wake = wake, .expire = expire, .close = close };
        fn of(p: *Parked) *@This() {
            return @fieldParentPtr("p", p);
        }
        fn wake(p: *Parked) anyerror!void {
            of(p).wakes += 1;
            if (of(p).wake_fails) return error.RuntimeShutdown;
        }
        fn expire(p: *Parked) anyerror!void {
            switch (of(p).expire_mode) {
                .deferred => {},
                .done_inline => p.expireDone(),
                .fails => return error.RuntimeShutdown,
            }
        }
        // Counts and does not free, so that the test can look afterwards.
        fn close(p: *Parked) void {
            of(p).closes += 1;
        }
    };
    const Op = enum { park, expire, poll_back, canceled, expire_done };
    // After `op`: the phase and how many closes so far.
    const Check = struct { op: Op, phase: Parked.Phase, closes: u32 };
    const Row = struct {
        name: []const u8,
        conn: Conn = .{},
        timed: bool = false,
        ops: []const Check,
        wakes: u32 = 0,
        /// Polls still counted at the end: null where the row returns a
        /// poll twice, which never happens outside this test.
        count: ?usize = 0,
        /// How long it had been parked when its poll came back.
        parked_for: std.Io.Duration = .zero,
        woke_from_long: bool = false,
    };
    const rows = [_]Row{
        .{ .name = "poll back while expiring, then expireDone closes once", .ops = &.{
            .{ .op = .park, .phase = .parked, .closes = 0 },
            .{ .op = .expire, .phase = .expiring, .closes = 0 },
            .{ .op = .poll_back, .phase = .expiring_back, .closes = 0 },
            .{ .op = .expire_done, .phase = .closed, .closes = 1 },
        } },
        .{ .name = "expireDone first, then the poll back, closes once", .timed = true, .ops = &.{
            .{ .op = .park, .phase = .parked, .closes = 0 },
            .{ .op = .expire, .phase = .expiring, .closes = 0 },
            .{ .op = .expire_done, .phase = .shut, .closes = 0 },
            .{ .op = .poll_back, .phase = .closed, .closes = 1 },
        } },
        .{ .name = "expire finishing inline, then the poll back", .conn = .{ .expire_mode = .done_inline }, .ops = &.{
            .{ .op = .park, .phase = .parked, .closes = 0 },
            .{ .op = .expire, .phase = .shut, .closes = 0 },
            .{ .op = .poll_back, .phase = .closed, .closes = 1 },
        } },
        .{ .name = "expire failing at once", .conn = .{ .expire_mode = .fails }, .timed = true, .ops = &.{
            .{ .op = .park, .phase = .parked, .closes = 0 },
            .{ .op = .expire, .phase = .shut, .closes = 0 },
            .{ .op = .poll_back, .phase = .closed, .closes = 1 },
        } },
        .{ .name = "the Canceled sweep on a parked one", .timed = true, .ops = &.{
            .{ .op = .park, .phase = .parked, .closes = 0 },
            .{ .op = .canceled, .phase = .closed, .closes = 1 },
        } },
        .{ .name = "the Canceled sweep on an expiring one", .ops = &.{
            .{ .op = .park, .phase = .parked, .closes = 0 },
            .{ .op = .expire, .phase = .expiring, .closes = 0 },
            .{ .op = .canceled, .phase = .expiring_back, .closes = 0 },
            .{ .op = .expire_done, .phase = .closed, .closes = 1 },
        } },
        .{ .name = "the Canceled sweep on a shut one", .conn = .{ .expire_mode = .done_inline }, .ops = &.{
            .{ .op = .park, .phase = .parked, .closes = 0 },
            .{ .op = .expire, .phase = .shut, .closes = 0 },
            .{ .op = .canceled, .phase = .closed, .closes = 1 },
        } },
        .{ .name = "wake fails: closed once, off the lists", .conn = .{ .wake_fails = true }, .timed = true, .wakes = 1, .ops = &.{
            .{ .op = .park, .phase = .parked, .closes = 0 },
            .{ .op = .poll_back, .phase = .closed, .closes = 1 },
        } },
        .{ .name = "wake succeeds after a short park", .wakes = 1, .ops = &.{
            .{ .op = .park, .phase = .parked, .closes = 0 },
            .{ .op = .poll_back, .phase = .running, .closes = 0 },
        } },
        .{ .name = "wake succeeds after a long park", .timed = true, .wakes = 1, .parked_for = .fromSeconds(7200), .woke_from_long = true, .ops = &.{
            .{ .op = .park, .phase = .parked, .closes = 0 },
            .{ .op = .poll_back, .phase = .running, .closes = 0 },
        } },
        .{ .name = "double events do not double close", .count = null, .ops = &.{
            .{ .op = .park, .phase = .parked, .closes = 0 },
            .{ .op = .expire, .phase = .expiring, .closes = 0 },
            .{ .op = .poll_back, .phase = .expiring_back, .closes = 0 },
            .{ .op = .expire_done, .phase = .closed, .closes = 1 },
            .{ .op = .expire_done, .phase = .closed, .closes = 1 },
            .{ .op = .poll_back, .phase = .closed, .closes = 1 },
            .{ .op = .canceled, .phase = .closed, .closes = 1 },
        } },
    };
    for (rows) |row| {
        errdefer std.debug.print("row: {s}\n", .{row.name});
        var shelf: Shelf = .{ .io = std.testing.io, .long_park = .fromSeconds(3600) };
        var c = row.conn;
        if (row.timed) c.p.deadline = now(shelf.io).addDuration(.fromSeconds(60));
        for (row.ops) |check| {
            switch (check.op) {
                // `Shelf.park` without the queue, which needs a runtime.
                .park => {
                    c.p.parked_at = now(shelf.io).subDuration(row.parked_for);
                    _ = c.p.step(.park);
                    shelf.insert(&c.p);
                    _ = shelf.count.fetchAdd(1, .monotonic);
                    try std.testing.expect((if (row.timed) shelf.timed.first else shelf.untimed.first) != null);
                },
                .expire => shelf.expire(&c.p),
                .poll_back => shelf.pollBack(&c.p, .poll_back),
                .canceled => shelf.pollBack(&c.p, .canceled),
                .expire_done => c.p.expireDone(),
            }
            errdefer std.debug.print("after {t}\n", .{check.op});
            try std.testing.expectEqual(check.phase, c.p.phase);
            try std.testing.expectEqual(check.closes, c.closes);
        }
        try std.testing.expectEqual(row.wakes, c.wakes);
        try std.testing.expectEqual(row.woke_from_long, c.p.woke_from_long);
        try std.testing.expect(shelf.timed.first == null and shelf.untimed.first == null);
        if (row.count) |n| try std.testing.expectEqual(n, shelf.count.load(.monotonic));
    }
}
