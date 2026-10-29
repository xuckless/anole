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

/// What a parked connection keeps for its shelf, in the connection's own
/// heap state.
pub const Parked = struct {
    vtable: *const VTable,
    /// The readiness poll in the shelf's queue, while parked.
    poll: NetPoll = undefined,
    node: std.DoublyLinkedList.Node = .{},
    /// The shelf it is on, while parked.
    shelf: ?*Shelf = null,
    /// When the driver closes it (awake clock); null for never.
    deadline: ?std.Io.Timestamp = null,
    /// Its deadline passed, or the server is stopping: its socket is shut
    /// down, and it closes when its poll comes back.
    expired: bool = false,
    /// `VTable.expire` is not done with it yet (it may wait).
    expiring: bool = false,
    /// Its poll came back while `expiring`: `expireDone` closes it.
    back: bool = false,
    /// When it parked (awake clock).
    parked_at: std.Io.Timestamp = .zero,
    /// It woke after being parked for `Shelf.long_park` or more: the task
    /// started for it parks it again once it has served what woke it (see
    /// `Shelf.long_park`).
    woke_from_long: bool = false,

    /// Whether the connection is on a shelf now.
    pub fn isParked(self: *const Parked) bool {
        return self.shelf != null;
    }

    /// From `VTable.expire`'s work, once done with the connection: shuts
    /// its socket down so that its poll comes back for the driver to close
    /// it, or closes it now if the poll is back already. On the shelf's
    /// executor.
    pub fn expireDone(self: *Parked) void {
        self.expiring = false;
        if (self.back) return self.vtable.close(self);
        if (comptime supported) zio.os.net.shutdown(self.poll.handle, .both) catch {};
    }
};

/// Idle detection for a task that serves a connection and waits for its
/// input many times over (an adopted connection, a WebSocket with
/// callbacks), without a timer armed and cleared around every wait: the
/// task marks its waits (`begin`, `end`) and is registered with its shelf
/// for as long as it serves (`Shelf.watch`), and the shelf's driver, which
/// looks at every registered task each half `Shelf.long_park`, ends a wait
/// that has gone on for `long_park` (up to half as long again) the way a
/// timer would, with an auto-cancel of the task's wait. A busy connection
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
    /// Test builds only: connections ended by `sweep` because their
    /// deadline passed while they were parked (not by the stop).
    test_deadline_expired: if (@import("builtin").is_test) std.atomic.Value(u32) else void = if (@import("builtin").is_test) .init(0) else {},

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

    /// How often the driver looks at the watches.
    fn watchInterval(self: *const Shelf) std.Io.Duration {
        return .fromNanoseconds(@max(self.long_park.nanoseconds >> 1, std.time.ns_per_ms));
    }

    /// The driver's look at the watches: ends each wait seen going on at
    /// the last two looks too.
    fn lookAtWatches(self: *Shelf) void {
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
            if (w.seen_count >= 2) w.poke();
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
        p.expired = false;
        p.expiring = false;
        p.back = false;
        p.parked_at = std.Io.Timestamp.now(self.io, .awake);
        self.cq.submit(&p.poll.c) catch return false;
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

    fn insert(self: *Shelf, p: *Parked) void {
        p.shelf = self;
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
        p.shelf = null;
    }

    /// Takes `p` off the lists and ends it: it closes when its poll is
    /// back.
    fn expire(self: *Shelf, p: *Parked) void {
        self.remove(p);
        p.expired = true;
        p.expiring = true;
        p.vtable.expire(p) catch p.expireDone();
    }

    /// Expires the connections whose deadline is not after `now`.
    fn sweep(self: *Shelf, now: std.Io.Timestamp) void {
        while (self.timed.first) |n| {
            const p: *Parked = @alignCast(@fieldParentPtr("node", n));
            if (p.deadline.?.nanoseconds > now.nanoseconds) break;
            if (@import("builtin").is_test) _ = self.test_deadline_expired.fetchAdd(1, .monotonic);
            self.expire(p);
        }
    }

    /// Expires every parked connection, and takes no more.
    fn expireAll(self: *Shelf) void {
        self.closed = true;
        while (self.timed.first orelse self.untimed.first) |n| {
            self.expire(@alignCast(@fieldParentPtr("node", n)));
        }
    }

    /// `p`'s poll is back: its socket is readable (or failed, which the
    /// next read reports), or was shut down.
    fn pollBack(self: *Shelf, p: *Parked) void {
        _ = self.count.fetchSub(1, .monotonic);
        if (p.expired) {
            if (p.expiring) p.back = true else p.vtable.close(p);
            return;
        }
        self.remove(p);
        const parked_for = p.parked_at.durationTo(std.Io.Timestamp.now(self.io, .awake));
        p.woke_from_long = parked_for.nanoseconds >= self.long_park.nanoseconds;
        p.vtable.wake(p) catch p.vtable.close(p);
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
    var next_sweep = std.Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .raw = sweep_interval, .clock = .awake });
    var next_look: ?std.Io.Clock.Timestamp = null;
    while (!shelf.closed or shelf.count.load(.monotonic) > 0) {
        const now = std.Io.Clock.Timestamp.now(io, .awake);
        // Here rather than on a timeout only, which a steady stream of
        // wakes would never let happen.
        if (now.compare(.gte, next_sweep)) {
            shelf.sweep(now.raw);
            next_sweep = now.addDuration(.{ .raw = sweep_interval, .clock = .awake });
        }
        if (shelf.watches.first == null) {
            next_look = null;
        } else if (next_look == null) {
            next_look = now.addDuration(.{ .raw = shelf.watchInterval(), .clock = .awake });
        } else if (now.compare(.gte, next_look.?)) {
            shelf.lookAtWatches();
            next_look = now.addDuration(.{ .raw = shelf.watchInterval(), .clock = .awake });
        }
        const until = if (next_look) |l| (if (l.compare(.lt, next_sweep)) l else next_sweep) else next_sweep;
        const left = now.durationTo(until).raw.nanoseconds;
        const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromNanoseconds(@max(0, left)), .clock = .awake } };
        const c = shelf.cq.waitTimeout(.fromStd(timeout)) catch |err| switch (err) {
            error.Timeout => continue,
            // Canceled rather than stopped: zio has canceled every poll and
            // closed the queue, and what comes back is closed here.
            error.Canceled => {
                shelf.closed = true;
                while (shelf.cq.next()) |back| {
                    if (back == &shelf.bell.c) continue;
                    const p: *Parked = @alignCast(@fieldParentPtr("poll", back.cast(NetPoll)));
                    _ = shelf.count.fetchSub(1, .monotonic);
                    if (!p.expired) {
                        shelf.remove(p);
                        p.vtable.close(p);
                    } else if (p.expiring) p.back = true else p.vtable.close(p);
                }
                return error.Canceled;
            },
            error.Closed => break,
        };
        if (c == &shelf.bell.c) {
            if (shelf.stopping.load(.acquire)) shelf.expireAll() else shelf.cq.submit(&shelf.bell.c) catch {};
            continue;
        }
        shelf.pollBack(@alignCast(@fieldParentPtr("poll", c.cast(NetPoll))));
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
    return zio.Runtime.fromIo(io) != null;
}
