//! L2 and L4: locks that know they are held.
//!
//! `Mutex(rank)` wraps `std.Io.Mutex` (a waiter suspends), `SpinLock(rank)`
//! wraps `std.atomic.Mutex` (a waiter spins), with the same calls. In debug
//! builds each acquisition is counted with zio (`zio.held_locks`, which
//! panics when a task suspends while the count is above zero: L2) and
//! pushed on the thread's stack of held ranks, which must rise strictly
//! (L4). Waiting for a `Mutex` is itself a suspension point, so it panics
//! when the caller already holds a lock, contended or not.
//!
//! Each entry of that stack also keeps where the lock was taken (the return
//! address of the `lock` call, as the Linux kernel's lockdep keeps
//! `acquire_ip` per held lock), so a violation names the site of the new
//! acquisition and of every lock held, symbolized, before it panics. zio's
//! own suspension check reports through `suspendReport` too (the fork's
//! `held_locks.report` hook), so a task that suspends holding a lock names
//! each lock's site beside the suspension's trace. Outside debug builds none
//! of this is compiled in.
//!
//! The global order, outer first (SAFETY.md L4): `io`, `table`, `protocol`,
//! `tls`, then `leaf`. A lock of rank `leaf` (most locks) is the innermost
//! level: it may be taken while holding any lock above it, but nothing is
//! taken while it is held, not even another leaf.
//!
//! `IoLock` is L2's exception: a lock that guards an I/O resource (the one
//! writer of a socket, one round trip on a connection) and may be held
//! across a suspension. It is never counted with zio and never pushed on
//! the thread's stack: while its task is suspended, the executor thread
//! runs other tasks, which take locks of their own. It is recorded on the
//! task that takes it instead (a zio task-local; off a task, on the
//! thread): a task takes one only when it holds no other I/O lock and its
//! thread holds no other lock (rank `io`, the outermost), and only the task
//! that took it lets it go.
//!
//! Two more checks use the same stack of held locks: a QSBR read section
//! (`readSectionEntered`, src/http/core/qsbr.zig) is counted with zio like
//! a lock, so a suspension inside it panics and names where it began, and
//! `checkAllocation` (`SpinCheckedAllocator`, `ProcessAllocator`) panics on
//! an allocation while a `SpinLock` is held (L5).
const std = @import("std");
const zio = @import("zio");
const enabled = @import("root.zig").enabled;

pub const Rank = enum(u8) {
    /// I/O locks (`IoLock`, L2's exception): taken only when no other
    /// lock is held.
    io = 5,
    /// Process-wide tables: handle tables, topic registries.
    table = 10,
    /// Per-connection protocol locks: the HTTP/2 session, an HTTP/3 connection.
    protocol = 20,
    /// The per-connection TLS spin lock.
    tls = 30,
    /// The innermost level (most locks): taken under any other rank, and
    /// no lock is taken while it is held.
    leaf = 255,
};

const zio_held = if (@hasDecl(zio, "held_locks")) zio.held_locks else struct {
    inline fn acquired() void {}
    inline fn released() void {}
};

const max_held = 8;

/// What an entry of the held stack is.
const Kind = enum {
    /// A `Mutex`: waiters suspend.
    mutex,
    /// A `SpinLock`: never held across an allocation (L5).
    spin,
    /// A QSBR read section: counted with zio like a lock, outside L4's
    /// order (its rank is not compared).
    section,

    fn noun(k: Kind) []const u8 {
        return switch (k) {
            .mutex => "lock",
            .spin => "spin lock",
            .section => "read section",
        };
    }
};

/// A lock the thread holds: its rank, what it is, and the return address
/// of the call that took it.
const Held = struct { rank: Rank, site: usize, kind: Kind = .mutex };

threadlocal var held: [max_held]Held = undefined;
threadlocal var held_len: u8 = 0;
/// This thread is panicking (a report here, or `notePanic`): the panic's
/// own logging may allocate under the lock that was held, and a second
/// report would hide the first.
threadlocal var reporting: bool = false;

/// A panic handler's first step (src/panic.zig): `checkAllocation` stays
/// quiet on this thread from now on, so logging the panic while a spin
/// lock is still held doesn't panic again over it.
pub fn notePanic() void {
    if (enabled) reporting = true;
}

/// The locks the calling thread holds through these types (0 outside debug
/// builds). An `IoLock` is not one of them: it is its task's (`heldIo`).
pub fn heldLocks() usize {
    return if (enabled) held_len else 0;
}

/// Whether `zio` can tell which task runs (`currentTask`) and keep a value
/// per task (`TaskLocal`): the fork can, the HTTP core's stub can't.
const have_task_local = @hasDecl(zio, "TaskLocal") and @hasDecl(zio, "currentTask");

/// The `IoLock` the running task holds (one at most), bound through the
/// lock's own node while it is held, so it follows the task across its
/// suspensions and whatever else runs on the thread meanwhile.
var task_io: if (have_task_local) zio.TaskLocal(*const IoLock) else void = if (have_task_local) .{} else {};
/// Off a task (a thread that is no executor, zio's scheduler code, the
/// core's stub zio), the thread holds its `IoLock` itself: there nothing
/// else runs on the thread while it waits.
threadlocal var thread_io: ?*const IoLock = null;

/// Whether the caller runs as a zio task.
fn onTask() bool {
    if (comptime !have_task_local) return false;
    return zio.currentTask() != null;
}

/// The `IoLock` the calling task (off a task: thread) holds, if any.
fn heldIo() ?*const IoLock {
    if (comptime !enabled) return null;
    if (comptime have_task_local) if (onTask()) return task_io.get();
    return thread_io;
}

/// Who holds an `IoLock`: a task, or off a task a thread.
const IoHolder = union(enum) {
    task: *const anyopaque,
    thread: std.Thread.Id,

    /// Who would hold an `IoLock` taken here.
    fn current() IoHolder {
        if (comptime have_task_local) if (zio.currentTask()) |t| return .{ .task = t };
        return .{ .thread = std.Thread.getCurrentId() };
    }

    fn eql(a: IoHolder, b: IoHolder) bool {
        return switch (a) {
            .task => |t| b == .task and b.task == t,
            .thread => |id| b == .thread and b.thread == id,
        };
    }
};

/// About to wait for a suspending lock at `site`: the thread may hold
/// nothing (L2). An `IoLock` is not on the thread's stack: it may be held
/// across a suspension.
fn beforeWait(rank: Rank, site: usize) void {
    if (!enabled or held_len == 0) return;
    const top = held[held_len - 1];
    if (top.kind == .section)
        report(site, "SAFETY.md L2: waiting for a {s} lock inside a read section: a lock wait is a suspension point", .{@tagName(rank)}, rank, "waited for")
    else
        report(site, "SAFETY.md L2: waiting for a {s} lock while holding a {s} lock: a lock wait is a suspension point", .{ @tagName(rank), @tagName(top.rank) }, rank, "waited for");
}

/// About to wait for `lock` at `site`: nothing at all may be held, not on
/// the thread and not another I/O lock of the task (L2's exception, L4's
/// `io` rank). I/O locks other tasks of the executor hold don't count.
fn beforeIoWait(lock: *const IoLock, site: usize) void {
    if (!enabled) return;
    if (held_len != 0) {
        const top = held[held_len - 1];
        if (top.kind == .section)
            report(site, "SAFETY.md L2: taking an I/O lock inside a read section: an I/O lock is taken only when no other lock is held", .{}, .io, "taken")
        else
            report(site, "SAFETY.md L2: taking an I/O lock while holding a {s} {s}: an I/O lock is taken only when no other lock is held", .{ @tagName(top.rank), top.kind.noun() }, .io, "taken");
    }
    if (heldIo()) |other| {
        if (other == lock)
            report(site, "SAFETY.md L2: taking an I/O lock this task already holds: it would wait for itself", .{}, .io, "taken")
        else
            report(site, "SAFETY.md L2: taking an I/O lock while this task holds another I/O lock: an I/O lock is taken only when no other lock is held", .{}, .io, "taken");
    }
}

/// `lock` was taken at `site`: it is the calling task's (off a task, the
/// thread's) until it lets it go. Not counted with zio, not on the thread's
/// stack.
fn ioTaken(lock: *IoLock, site: usize) void {
    if (comptime !enabled) return;
    lock.debug.holder = .current();
    lock.debug.site = site;
    if (comptime have_task_local) if (onTask()) return task_io.set(&lock.debug.node, lock);
    thread_io = lock;
}

/// `lock` is let go at `site`: only by the task (or thread) that took it.
fn ioReleasing(lock: *IoLock, site: usize) void {
    if (comptime !enabled) return;
    const holder = lock.debug.holder orelse ioNotHeld(lock, site);
    if (!holder.eql(.current())) ioNotHeld(lock, site);
    lock.debug.holder = null;
    if (comptime have_task_local) if (lock.debug.node.base.key != null) return task_io.clear(&lock.debug.node);
    thread_io = null;
}

/// Releasing an `IoLock` the caller does not hold: names where it is let go
/// and, when someone holds it, where that one took it.
fn ioNotHeld(lock: *const IoLock, site: usize) noreturn {
    @branchHint(.cold);
    reporting = true;
    var buf: [3584]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    writeIoNotHeld(&w, lock, site) catch {};
    std.debug.panic("{s}", .{w.buffered()});
}

fn writeIoNotHeld(w: *std.Io.Writer, lock: *const IoLock, site: usize) std.Io.Writer.Error!void {
    if (lock.debug.holder == null)
        try w.writeAll("SAFETY.md L2: releasing an I/O lock that is not held\n")
    else
        try w.writeAll("SAFETY.md L2: releasing an I/O lock this task does not hold: the task that took it lets it go\n");
    try w.writeAll("the I/O lock is being released at:\n");
    try writeSite(w, site);
    if (lock.debug.holder != null) {
        try w.writeAll("it was taken by another task or thread at:\n");
        try writeSite(w, lock.debug.site);
    }
}

/// The innermost entry that L4's order compares against: any but a read
/// section.
fn topRanked() ?Held {
    var i: usize = held_len;
    while (i > 0) {
        i -= 1;
        if (held[i].kind != .section) return held[i];
    }
    return null;
}

fn acquired(rank: Rank, site: usize) void {
    acquiredKind(rank, site, .mutex);
}

fn acquiredKind(rank: Rank, site: usize, kind: Kind) void {
    if (!enabled) return;
    if (held_len == max_held) report(site, "SAFETY.md L4: more than {d} locks held", .{max_held}, rank, "taken");
    if (kind != .section) if (topRanked()) |h| {
        const top = h.rank;
        // Ranks rise strictly. `leaf` is the highest, so a leaf may be taken
        // under any other rank, and nothing (not even a leaf) under a leaf.
        if (top == .leaf)
            report(site, "SAFETY.md L4: taking a {s} lock while holding a leaf lock: no lock is taken under a leaf lock", .{@tagName(rank)}, rank, "taken")
        else if (@backingInt(rank) <= @backingInt(top))
            report(site, "SAFETY.md L4: taking a {s} lock while holding a {s} lock breaks the lock order", .{ @tagName(rank), @tagName(top) }, rank, "taken");
    };
    held[held_len] = .{ .rank = rank, .site = site, .kind = kind };
    held_len += 1;
    zio_held.acquired();
    installSuspendReport();
}

/// A QSBR read section begins at `site` (src/http/core/qsbr.zig): counted
/// with zio like a lock, so a task that suspends inside it panics and the
/// report names where it began (M3: a borrowed pointer is valid only until
/// the next suspension). Not part of L4's order. Nothing outside debug
/// builds.
pub fn readSectionEntered(site: usize) void {
    if (enabled) acquiredKind(.leaf, site, .section);
}

/// The read section begun last on this thread ends.
pub fn readSectionLeft(site: usize) void {
    if (!enabled) return;
    var i: usize = held_len;
    while (i > 0) {
        i -= 1;
        if (held[i].kind == .section) return removeAt(i);
    }
    report(site, "SAFETY.md M3: ending a read section this thread has not begun", .{}, .leaf, "ended");
}

/// SAFETY.md L5: panics when the calling thread holds a `SpinLock`, naming
/// where the allocation is (`site`, the allocator call's return address)
/// and where each held lock was taken. A spin section never allocates: an
/// allocator may take its own locks, fault pages in or call the kernel,
/// and every waiter spins the whole time. Nothing outside debug builds.
pub fn checkAllocation(site: usize) void {
    if (!enabled or reporting) return;
    for (held[0..held_len]) |h| {
        if (h.kind == .spin) allocationUnderSpin(site, h.rank);
    }
}

fn allocationUnderSpin(site: usize, rank: Rank) noreturn {
    @branchHint(.cold);
    reporting = true;
    var buf: [3584]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    writeAllocationReport(&w, site, rank, held[0..held_len]) catch {};
    std.debug.panic("{s}", .{w.buffered()});
}

fn writeAllocationReport(w: *std.Io.Writer, site: usize, rank: Rank, locks: []const Held) std.Io.Writer.Error!void {
    try w.print("SAFETY.md L5: an allocation while holding a {s} spin lock: a spin section never allocates\nthe allocation is at:\n", .{@tagName(rank)});
    try writeSite(w, site);
    try writeHeld(w, locks);
}

/// Makes zio's suspension check (`debug_held_locks`) report through
/// `suspendReport`, once, before the first lock is counted. Every thread
/// stores the same pointer, so a race between first locks is harmless.
inline fn installSuspendReport() void {
    if (comptime !@hasDecl(zio_held, "report")) return;
    if (@atomicLoad(?*const fn (u32) noreturn, &zio_held.report, .monotonic) == null)
        @atomicStore(?*const fn (u32) noreturn, &zio_held.report, &suspendReport, .monotonic);
}

/// zio's report when a task suspends while this thread counts `count` held
/// locks (L2): like the L4 reports, it names where each held lock was taken;
/// the panic's own stack trace is the suspension site.
fn suspendReport(count: u32) noreturn {
    @branchHint(.cold);
    reporting = true;
    var buf: [3584]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    writeSuspendReport(&w, count, held[0..held_len]) catch {};
    std.debug.panic("{s}", .{w.buffered()});
}

fn writeSuspendReport(w: *std.Io.Writer, count: u32, locks: []const Held) std.Io.Writer.Error!void {
    try w.print("SAFETY.md L2: a task suspended while holding {d} lock(s): never hold a lock across a suspension point (the suspension is the trace below)\n", .{count});
    try writeHeld(w, locks);
}

fn releasing(rank: Rank, site: usize) void {
    if (!enabled) return;
    var i: usize = held_len;
    while (i > 0) {
        i -= 1;
        if (held[i].rank == rank and held[i].kind != .section) return removeAt(i);
    }
    report(site, "SAFETY.md L4: releasing a {s} lock this thread does not hold", .{@tagName(rank)}, rank, "released");
}

fn removeAt(i: usize) void {
    std.mem.copyForwards(Held, held[i .. held_len - 1], held[i + 1 .. held_len]);
    held_len -= 1;
    zio_held.released();
}

/// Panics with `fmt`, followed by where the `rank` lock is being `verb`
/// (`site`) and where each lock the thread holds was taken, outer first,
/// each symbolized with its source line. Like lockdep's report (the new
/// acquisition, then "N locks held by ..." with each one's `acquire_ip`),
/// Abseil's (both acquisition stacks) and Go's lockrank (the held list).
fn report(site: usize, comptime fmt: []const u8, args: anytype, rank: Rank, verb: []const u8) noreturn {
    @branchHint(.cold);
    reporting = true;
    var buf: [3584]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    writeReport(&w, fmt, args, rank, verb, site, held[0..held_len]) catch {};
    std.debug.panic("{s}", .{w.buffered()});
}

fn writeReport(w: *std.Io.Writer, comptime fmt: []const u8, args: anytype, rank: Rank, verb: []const u8, site: usize, locks: []const Held) std.Io.Writer.Error!void {
    try w.print(fmt, args);
    try w.print("\nthe {s} lock is being {s} at:\n", .{ @tagName(rank), verb });
    try writeSite(w, site);
    try writeHeld(w, locks);
}

fn writeHeld(w: *std.Io.Writer, locks: []const Held) std.Io.Writer.Error!void {
    if (comptime enabled) if (heldIo()) |l| {
        try w.writeAll("the I/O lock this task holds, taken at:\n");
        try writeSite(w, l.debug.site);
    };
    try w.print("locks held by this thread, outer first ({d}):\n", .{locks.len});
    for (locks, 0..) |h, i| {
        if (h.kind == .section)
            try w.print("#{d} a read section, begun at:\n", .{i})
        else
            try w.print("#{d} a {s} {s}, taken at:\n", .{ i, @tagName(h.rank), h.kind.noun() });
        try writeSite(w, h.site);
    }
}

/// One return address as a source location (the call before it) and its line.
fn writeSite(w: *std.Io.Writer, site: usize) std.Io.Writer.Error!void {
    var one = [1]usize{site};
    const trace: std.debug.StackTrace = .{ .return_addresses = &one, .skipped = .none };
    // Symbolizing takes the debug info's lock through std's blocking
    // `debug_io`; a cancel there would be dropped (AGENTS.md gotcha), and
    // this path ends in a panic anyway.
    const io = std.Options.debug_io;
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);
    try std.debug.writeStackTrace(&trace, .{ .writer = w, .mode = .no_color });
}

/// A lock whose waiters suspend (`std.Io.Mutex`), ranked for L4.
pub fn Mutex(comptime rank: Rank) type {
    return struct {
        inner: std.Io.Mutex = .init,

        const Self = @This();
        pub const init: Self = .{};

        pub fn lock(self: *Self, io: std.Io) std.Io.Cancelable!void {
            if (enabled) beforeWait(rank, @returnAddress());
            try self.inner.lock(io);
            if (enabled) acquired(rank, @returnAddress());
        }

        pub fn lockUncancelable(self: *Self, io: std.Io) void {
            if (enabled) beforeWait(rank, @returnAddress());
            self.inner.lockUncancelable(io);
            if (enabled) acquired(rank, @returnAddress());
        }

        pub fn tryLock(self: *Self) bool {
            if (!self.inner.tryLock()) return false;
            if (enabled) acquired(rank, @returnAddress());
            return true;
        }

        pub fn unlock(self: *Self, io: std.Io) void {
            if (enabled) releasing(rank, @returnAddress());
            self.inner.unlock(io);
        }
    };
}

/// A lock whose waiters spin (`std.atomic.Mutex`), for short bounded
/// sections that never allocate, wait or call blocking C code (L5).
pub fn SpinLock(comptime rank: Rank) type {
    return struct {
        inner: std.atomic.Mutex = .unlocked,

        const Self = @This();
        pub const init: Self = .{};

        pub fn lock(self: *Self) void {
            while (!self.inner.tryLock()) std.atomic.spinLoopHint();
            if (enabled) acquiredKind(rank, @returnAddress(), .spin);
        }

        pub fn tryLock(self: *Self) bool {
            if (!self.inner.tryLock()) return false;
            if (enabled) acquiredKind(rank, @returnAddress(), .spin);
            return true;
        }

        pub fn unlock(self: *Self) void {
            if (enabled) releasing(rank, @returnAddress());
            self.inner.unlock();
        }
    };
}

/// SAFETY.md L2's exception: a lock that guards an I/O resource, not data
/// (the one writer of a socket or stream, one round trip on a broker
/// connection), and may be held across a suspension. Its waiters suspend
/// (`std.Io.Mutex`). A task takes it only when it holds no other lock, not
/// even another I/O lock (rank `io`, outermost in L4's order): debug builds
/// panic otherwise. While it is held, other locks may be taken in L4's
/// order, and the task may suspend once they are let go; other tasks on
/// the same executor run meanwhile and take locks of their own, I/O locks
/// too. Only the task that took it lets it go. Nothing may wait for it
/// inside a C callback, and it guards no data another lock or an executor
/// also guards. Each one is temporary, until the protocol work that owns
/// its resource gives it an outbox and one writer.
///
/// Not checked: a wait between tasks, such as a task that holds one and
/// awaits a task that waits for the same one (each task holds one lock).
pub const IoLock = struct {
    inner: std.Io.Mutex = .init,
    /// Debug and test builds: who holds it and where it was taken; written
    /// and read by its holder only, under `inner`.
    debug: Debug = .{},

    pub const init: IoLock = .{};

    const Debug = if (enabled) struct {
        /// The task that holds it (off a task, the thread); null when free.
        holder: ?IoHolder = null,
        /// Where it was taken (the `lock` call's return address).
        site: usize = 0,
        /// Binds it as its task's I/O lock (`task_io`) while held.
        node: if (have_task_local) zio.TaskLocal(*const IoLock).Node else void = if (have_task_local) .unset else {},
    } else struct {};

    pub fn lock(self: *IoLock, io: std.Io) std.Io.Cancelable!void {
        if (enabled) beforeIoWait(self, @returnAddress());
        try self.inner.lock(io);
        if (enabled) ioTaken(self, @returnAddress());
    }

    pub fn lockUncancelable(self: *IoLock, io: std.Io) void {
        if (enabled) beforeIoWait(self, @returnAddress());
        self.inner.lockUncancelable(io);
        if (enabled) ioTaken(self, @returnAddress());
    }

    pub fn tryLock(self: *IoLock) bool {
        if (enabled) beforeIoWait(self, @returnAddress());
        if (!self.inner.tryLock()) return false;
        if (enabled) ioTaken(self, @returnAddress());
        return true;
    }

    pub fn unlock(self: *IoLock, io: std.Io) void {
        if (enabled) ioReleasing(self, @returnAddress());
        self.inner.unlock(io);
    }
};

/// `std.Io.Condition` over a `Mutex`: waiting lets the lock go (and its
/// count) while the caller sleeps.
pub const Condition = struct {
    inner: std.Io.Condition = .init,

    pub const init: Condition = .{};

    pub fn wait(self: *Condition, io: std.Io, m: anytype) std.Io.Cancelable!void {
        const rank = rankOf(@TypeOf(m));
        const site = if (enabled) @returnAddress() else 0;
        releasing(rank, site);
        beforeWait(rank, site);
        defer acquired(rank, site);
        return self.inner.wait(io, &m.inner);
    }

    pub fn waitUncancelable(self: *Condition, io: std.Io, m: anytype) void {
        const rank = rankOf(@TypeOf(m));
        const site = if (enabled) @returnAddress() else 0;
        releasing(rank, site);
        beforeWait(rank, site);
        defer acquired(rank, site);
        self.inner.waitUncancelable(io, &m.inner);
    }

    pub fn waitTimeout(self: *Condition, io: std.Io, m: anytype, timeout: std.Io.Timeout) std.Io.Condition.WaitTimeoutError!void {
        const rank = rankOf(@TypeOf(m));
        const site = if (enabled) @returnAddress() else 0;
        releasing(rank, site);
        beforeWait(rank, site);
        defer acquired(rank, site);
        return self.inner.waitTimeout(io, &m.inner, timeout);
    }

    pub fn signal(self: *Condition, io: std.Io) void {
        self.inner.signal(io);
    }

    pub fn broadcast(self: *Condition, io: std.Io) void {
        self.inner.broadcast(io);
    }

    fn rankOf(comptime P: type) Rank {
        inline for (comptime std.enums.values(Rank)) |r| {
            if (P == *Mutex(r)) return r;
        }
        @compileError("Condition waits on a safety.Mutex, not " ++ @typeName(P));
    }
};

test "lock: a leaf mutex counts while held" {
    var m: Mutex(.leaf) = .init;
    try m.lock(std.testing.io);
    if (enabled) try std.testing.expectEqual(@as(usize, 1), heldLocks());
    m.unlock(std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), heldLocks());
}

test "lock: ranks taken in order nest" {
    var t: SpinLock(.table) = .init;
    var p: SpinLock(.protocol) = .init;
    var s: SpinLock(.tls) = .init;
    t.lock();
    p.lock();
    s.lock();
    if (enabled) try std.testing.expectEqual(@as(usize, 3), heldLocks());
    p.unlock();
    s.unlock();
    t.unlock();
    try std.testing.expectEqual(@as(usize, 0), heldLocks());
}

test "lock: a leaf lock may be taken while holding a table lock" {
    var t: SpinLock(.table) = .init;
    var l: SpinLock(.leaf) = .init;
    t.lock();
    l.lock();
    if (enabled) try std.testing.expectEqual(@as(usize, 2), heldLocks());
    l.unlock();
    t.unlock();
    try std.testing.expectEqual(@as(usize, 0), heldLocks());
}

test "lock: tryLock of a held mutex fails and counts nothing" {
    var m: Mutex(.leaf) = .init;
    try std.testing.expect(m.tryLock());
    try std.testing.expect(!m.tryLock());
    if (enabled) try std.testing.expectEqual(@as(usize, 1), heldLocks());
    m.unlock(std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), heldLocks());
}

test "lock: a condition wait on its own mutex is not a wait while holding (L2), and the lock counts again after" {
    var m: Mutex(.leaf) = .init;
    var c: Condition = .init;
    try m.lock(std.testing.io);
    // The 1 ms is time passing on purpose: a timeout or a wake both end it.
    c.waitTimeout(std.testing.io, &m, .{ .duration = .{ .raw = .fromMilliseconds(1), .clock = .awake } }) catch |err| switch (err) {
        error.Timeout => {},
        else => return err,
    };
    if (enabled) try std.testing.expectEqual(@as(usize, 1), heldLocks());
    m.unlock(std.testing.io);
}

test "lock: an I/O lock may be held across a lock wait, and other locks nest under it" {
    var io_lock: IoLock = .init;
    var t: Mutex(.table) = .init;
    var l: SpinLock(.leaf) = .init;
    try io_lock.lock(std.testing.io);
    try t.lock(std.testing.io);
    l.lock();
    // The thread holds the two ranked locks; the I/O lock is the caller's.
    if (enabled) try std.testing.expectEqual(@as(usize, 2), heldLocks());
    if (enabled) try std.testing.expectEqual(@as(?*const IoLock, &io_lock), heldIo());
    l.unlock();
    t.unlock(std.testing.io);
    io_lock.unlock(std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), heldLocks());
    try std.testing.expectEqual(@as(?*const IoLock, null), heldIo());
}

test "lock: a task may suspend holding an I/O lock" {
    if (!enabled or !zio_checks_suspend) return error.SkipZigTest;
    const rt = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    var io_lock: IoLock = .init;
    try io_lock.lock(io);
    // A suspension of the main task on executor 0: zio's check passes it.
    try zio.yield();
    io_lock.unlock(io);
}

/// A connection's task in the tests below: takes its own I/O lock, waits
/// for `go` inside it (a real suspension: the test sets the event), then
/// takes a leaf lock and a table lock under it and lets everything go.
const TaskWithIoLock = struct {
    io_lock: IoLock = .init,
    in_lock: std.Io.Event = .unset,
    go: std.Io.Event = .unset,
    done: std.Io.Event = .unset,

    fn run(h: *TaskWithIoLock, io: std.Io) std.Io.Cancelable!void {
        try h.io_lock.lock(io);
        defer h.io_lock.unlock(io);
        h.in_lock.set(io);
        try h.go.wait(io);
        var l: SpinLock(.leaf) = .init;
        l.lock();
        l.unlock();
        var t: Mutex(.table) = .init;
        try t.lock(io);
        t.unlock(io);
        h.done.set(io);
    }
};

test "lock: a task takes an I/O lock while another task on its executor is suspended holding one" {
    if (!zio_checks_suspend) return error.SkipZigTest;
    const rt = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    var a: TaskWithIoLock = .{};
    var b: TaskWithIoLock = .{};
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    // Both on the only executor: a suspends inside its I/O lock, then b
    // takes another I/O lock, a leaf and a table lock on the same thread.
    try zio.Group.fromStd(&group).spawnInto(.{ .executor = 0 }, TaskWithIoLock.run, .{ &a, io });
    try a.in_lock.wait(io);
    try zio.Group.fromStd(&group).spawnInto(.{ .executor = 0 }, TaskWithIoLock.run, .{ &b, io });
    try b.in_lock.wait(io);
    // b is suspended inside its I/O lock too; a goes on and lets its own go
    // while b still holds one, then b.
    a.go.set(io);
    try a.done.wait(io);
    b.go.set(io);
    try group.await(io);
    try std.testing.expectEqual(@as(usize, 0), heldLocks());
}

test "lock: tasks on two executors each hold an I/O lock across suspensions, two per executor" {
    if (!zio_checks_suspend) return error.SkipZigTest;
    const rt = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var holders: [4]TaskWithIoLock = @splat(.{});
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    // Holder i on executor i % 2: every executor thread runs two tasks
    // that are suspended inside their own I/O lock at the same time.
    for (&holders, 0..) |*h, i| {
        try zio.Group.fromStd(&group).spawnInto(.{ .executor = @intCast(i % 2) }, TaskWithIoLock.run, .{ h, io });
    }
    for (&holders) |*h| try h.in_lock.wait(io);
    // Released in the reverse order of taking, each by its own task.
    var i: usize = holders.len;
    while (i > 0) {
        i -= 1;
        holders[i].go.set(io);
        try holders[i].done.wait(io);
    }
    try group.await(io);
}

test "lock: a read section counts as held but is outside the lock order" {
    var t: SpinLock(.table) = .init;
    readSectionEntered(@returnAddress());
    // A table lock under a section: no L4 report (a section has no rank).
    t.lock();
    if (enabled) try std.testing.expectEqual(@as(usize, 2), heldLocks());
    t.unlock();
    readSectionLeft(@returnAddress());
    try std.testing.expectEqual(@as(usize, 0), heldLocks());
}

const child = @import("child.zig");

/// Takes a table lock, then an I/O lock under it, at the lines it returns.
fn ioUnderLock(run: bool) [2]u32 {
    var t: SpinLock(.table) = .init;
    var io_lock: IoLock = .init;
    const outer = @src().line + 1;
    if (run) t.lock();
    const inner = @src().line + 1;
    if (run) io_lock.lockUncancelable(std.testing.io);
    return .{ outer, inner };
}

test "lock: an I/O lock taken while holding another lock names where both were taken" {
    if (!enabled) return error.SkipZigTest;
    const key = "an I/O lock taken while holding another lock names where both were taken";
    if (child.isChild(key)) _ = ioUnderLock(true);
    const out = try child.runPanicking(std.testing.allocator, key);
    defer std.testing.allocator.free(out);
    const lines = ioUnderLock(false);
    try std.testing.expect(std.mem.indexOf(u8, out, "SAFETY.md L2: taking an I/O lock while holding a table spin lock") != null);
    try expectSite(out, lines[0]);
    try expectSite(out, lines[1]);
}

/// On a zio task, takes an I/O lock, then a second one while holding it, at
/// the lines it returns; `io` null only computes the lines.
fn ioUnderIo(io: ?std.Io) [2]u32 {
    var first: IoLock = .init;
    var second: IoLock = .init;
    const outer = @src().line + 1;
    if (io) |i| first.lockUncancelable(i);
    const inner = @src().line + 1;
    if (io) |i| second.lockUncancelable(i);
    return .{ outer, inner };
}

test "lock: a task taking a second I/O lock names where both were taken" {
    if (!enabled or !zio_checks_suspend) return error.SkipZigTest;
    const key = "a task taking a second I/O lock names where both were taken";
    if (child.isChild(key)) {
        const rt = try zio.Runtime.init(std.heap.page_allocator, .{ .executors = .exact(1) });
        _ = ioUnderIo(rt.io());
    }
    const out = try child.runPanicking(std.testing.allocator, key);
    defer std.testing.allocator.free(out);
    const lines = ioUnderIo(null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SAFETY.md L2: taking an I/O lock while this task holds another I/O lock") != null);
    try expectSite(out, lines[0]);
    try expectSite(out, lines[1]);
}

/// Lets go of `h.io_lock`, which another task holds, at the line it
/// returns; `io` null only computes the line.
fn ioReleasedByOther(io: ?std.Io, h: *TaskWithIoLock) u32 {
    const released = @src().line + 1;
    if (io) |i| h.io_lock.unlock(i);
    return released;
}

test "lock: an I/O lock let go by a task that did not take it names where it was taken" {
    if (!enabled or !zio_checks_suspend) return error.SkipZigTest;
    const key = "an I/O lock let go by a task that did not take it names where it was taken";
    var h: TaskWithIoLock = .{};
    if (child.isChild(key)) {
        const rt = try zio.Runtime.init(std.heap.page_allocator, .{ .executors = .exact(1) });
        const io = rt.io();
        var group: std.Io.Group = .init;
        // A task on executor 0 takes the lock and waits inside it; this
        // task then lets it go.
        try zio.Group.fromStd(&group).spawnInto(.{ .executor = 0 }, TaskWithIoLock.run, .{ &h, io });
        try h.in_lock.wait(io);
        _ = ioReleasedByOther(io, &h);
    }
    const out = try child.runPanicking(std.testing.allocator, key);
    defer std.testing.allocator.free(out);
    const released = ioReleasedByOther(null, &h);
    try std.testing.expect(std.mem.indexOf(u8, out, "SAFETY.md L2: releasing an I/O lock this task does not hold") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "it was taken by another task or thread at:") != null);
    try expectSite(out, released);
}

/// Takes a tls lock, then a protocol lock (out of order), at the lines it
/// returns; `run` false only computes the lines.
fn orderViolation(run: bool) [2]u32 {
    var t: SpinLock(.tls) = .init;
    var p: SpinLock(.protocol) = .init;
    const outer = @src().line + 1;
    if (run) t.lock();
    const inner = @src().line + 1;
    if (run) p.lock();
    return .{ outer, inner };
}

/// Takes a leaf lock, then a table lock under it, at the lines it returns.
fn underLeaf(run: bool) [2]u32 {
    var l: SpinLock(.leaf) = .init;
    var t: SpinLock(.table) = .init;
    const outer = @src().line + 1;
    if (run) l.lock();
    const inner = @src().line + 1;
    if (run) t.lock();
    return .{ outer, inner };
}

/// Holds a table spin lock, then waits for a mutex, at the lines it returns.
fn waitWhileHolding(run: bool) [2]u32 {
    var t: SpinLock(.table) = .init;
    var m: Mutex(.protocol) = .init;
    const outer = @src().line + 1;
    if (run) t.lock();
    const inner = @src().line + 1;
    if (run) m.lockUncancelable(std.testing.io);
    return .{ outer, inner };
}

/// Whether this zio checks suspensions (`debug_held_locks`) and has the
/// fork's report hook; off for the HTTP core's stub zio.
const zio_checks_suspend = @hasDecl(zio, "held_locks") and @hasDecl(zio.held_locks, "report") and zio.held_locks.enabled;

/// Holds a leaf spin lock and sleeps (a suspension) on `io`'s zio runtime,
/// at the lines it returns; `io` null only computes the lines.
fn suspendWhileHolding(io: ?std.Io) [2]u32 {
    var l: SpinLock(.leaf) = .init;
    const outer = @src().line + 1;
    if (io != null) l.lock();
    const inner = @src().line + 1;
    if (io) |i| i.sleep(.fromMilliseconds(1), .awake) catch {};
    return .{ outer, inner };
}

/// Fails unless `out` names the source line `line` of this file. Debug
/// builds only: an optimized test binary (ReleaseSafe) inlines the lock
/// calls, and a site is then the nearest frame left out of line, not the
/// line that took the lock. The report itself is the same.
fn expectSite(out: []const u8, line: u32) !void {
    if (@import("builtin").mode != .debug) return;
    var buf: [32]u8 = undefined;
    const needle = try std.fmt.bufPrint(&buf, "lock.zig:{d}:", .{line});
    if (std.mem.indexOf(u8, out, needle) == null) {
        std.debug.print("expected {s} in the child's stderr:\n{s}\n", .{ needle, out });
        return error.SiteNotNamed;
    }
}

test "lock: an order violation names where both locks were taken" {
    if (!enabled) return error.SkipZigTest;
    const key = "an order violation names where both locks were taken";
    if (child.isChild(key)) _ = orderViolation(true);
    const out = try child.runPanicking(std.testing.allocator, key);
    defer std.testing.allocator.free(out);
    const lines = orderViolation(false);
    try std.testing.expect(std.mem.indexOf(u8, out, "SAFETY.md L4: taking a protocol lock while holding a tls lock") != null);
    try expectSite(out, lines[0]);
    try expectSite(out, lines[1]);
}

test "lock: waiting while holding names where both locks were taken" {
    if (!enabled) return error.SkipZigTest;
    const key = "waiting while holding names where both locks were taken";
    if (child.isChild(key)) _ = waitWhileHolding(true);
    const out = try child.runPanicking(std.testing.allocator, key);
    defer std.testing.allocator.free(out);
    const lines = waitWhileHolding(false);
    try std.testing.expect(std.mem.indexOf(u8, out, "SAFETY.md L2: waiting for a protocol lock while holding a table lock") != null);
    try expectSite(out, lines[0]);
    try expectSite(out, lines[1]);
}

test "lock: a lock taken while holding a leaf names where both were taken" {
    if (!enabled) return error.SkipZigTest;
    const key = "a lock taken while holding a leaf names where both were taken";
    if (child.isChild(key)) _ = underLeaf(true);
    const out = try child.runPanicking(std.testing.allocator, key);
    defer std.testing.allocator.free(out);
    const lines = underLeaf(false);
    try std.testing.expect(std.mem.indexOf(u8, out, "SAFETY.md L4: taking a table lock while holding a leaf lock") != null);
    try expectSite(out, lines[0]);
    try expectSite(out, lines[1]);
}

test "lock: a task suspending while holding a lock names where it was taken and where it suspends" {
    if (!enabled or !zio_checks_suspend) return error.SkipZigTest;
    const key = "a task suspending while holding a lock names where it was taken and where it suspends";
    if (child.isChild(key)) {
        const rt = try zio.Runtime.init(std.heap.page_allocator, .{ .executors = .exact(1) });
        _ = suspendWhileHolding(rt.io());
    }
    const out = try child.runPanicking(std.testing.allocator, key);
    defer std.testing.allocator.free(out);
    const lines = suspendWhileHolding(null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SAFETY.md L2: a task suspended while holding 1 lock(s)") != null);
    try expectSite(out, lines[0]);
    try expectSite(out, lines[1]);
}
