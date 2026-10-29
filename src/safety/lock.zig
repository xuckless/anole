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
//! The global order, outer first (SAFETY.md L4): `table`, `protocol`, `tls`,
//! then `leaf`. A lock of rank `leaf` (most locks) is the innermost level:
//! it may be taken while holding any lock above it, but nothing is taken
//! while it is held, not even another leaf.
const std = @import("std");
const zio = @import("zio");
const enabled = @import("root.zig").enabled;

pub const Rank = enum(u8) {
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

/// A lock the thread holds: its rank and the return address of the call
/// that took it.
const Held = struct { rank: Rank, site: usize };

threadlocal var held: [max_held]Held = undefined;
threadlocal var held_len: u8 = 0;

/// The locks the calling thread holds through these types (0 outside debug builds).
pub fn heldLocks() usize {
    return if (enabled) held_len else 0;
}

/// About to wait for a suspending lock at `site`: nothing may be held (L2).
fn beforeWait(rank: Rank, site: usize) void {
    if (!enabled or held_len == 0) return;
    report(site, "SAFETY.md L2: waiting for a {s} lock while holding a {s} lock: a lock wait is a suspension point", .{ @tagName(rank), @tagName(held[held_len - 1].rank) }, rank, "waited for");
}

fn acquired(rank: Rank, site: usize) void {
    if (!enabled) return;
    if (held_len > 0) {
        const top = held[held_len - 1].rank;
        // Ranks rise strictly. `leaf` is the highest, so a leaf may be taken
        // under any other rank, and nothing (not even a leaf) under a leaf.
        if (top == .leaf)
            report(site, "SAFETY.md L4: taking a {s} lock while holding a leaf lock: no lock is taken under a leaf lock", .{@tagName(rank)}, rank, "taken")
        else if (@backingInt(rank) <= @backingInt(top))
            report(site, "SAFETY.md L4: taking a {s} lock while holding a {s} lock breaks the lock order", .{ @tagName(rank), @tagName(top) }, rank, "taken");
        if (held_len == max_held) report(site, "SAFETY.md L4: more than {d} locks held", .{max_held}, rank, "taken");
    }
    held[held_len] = .{ .rank = rank, .site = site };
    held_len += 1;
    zio_held.acquired();
    installSuspendReport();
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
        if (held[i].rank == rank) {
            std.mem.copyForwards(Held, held[i .. held_len - 1], held[i + 1 .. held_len]);
            held_len -= 1;
            zio_held.released();
            return;
        }
    }
    report(site, "SAFETY.md L4: releasing a {s} lock this thread does not hold", .{@tagName(rank)}, rank, "released");
}

/// Panics with `fmt`, followed by where the `rank` lock is being `verb`
/// (`site`) and where each lock the thread holds was taken, outer first,
/// each symbolized with its source line. Like lockdep's report (the new
/// acquisition, then "N locks held by ..." with each one's `acquire_ip`),
/// Abseil's (both acquisition stacks) and Go's lockrank (the held list).
fn report(site: usize, comptime fmt: []const u8, args: anytype, rank: Rank, verb: []const u8) noreturn {
    @branchHint(.cold);
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
    try w.print("locks held by this thread, outer first ({d}):\n", .{locks.len});
    for (locks, 0..) |h, i| {
        try w.print("#{d} a {s} lock, taken at:\n", .{ i, @tagName(h.rank) });
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
            if (enabled) acquired(rank, @returnAddress());
        }

        pub fn tryLock(self: *Self) bool {
            if (!self.inner.tryLock()) return false;
            if (enabled) acquired(rank, @returnAddress());
            return true;
        }

        pub fn unlock(self: *Self) void {
            if (enabled) releasing(rank, @returnAddress());
            self.inner.unlock();
        }
    };
}

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

const child = @import("child.zig");

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
