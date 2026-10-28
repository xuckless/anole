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
//! acquisition and of every lock held, symbolized, before it panics. Outside
//! debug builds none of this is compiled in.
//!
//! The global order, outer first (SAFETY.md L4). A lock of rank `leaf`, the
//! default, is held alone: no other lock while it is held, and it is not
//! taken while another is.
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
    /// Held alone (most locks).
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
        if (rank == .leaf or top == .leaf or @backingInt(rank) <= @backingInt(top))
            report(site, "SAFETY.md L4: taking a {s} lock while holding a {s} lock breaks the lock order", .{ @tagName(rank), @tagName(top) }, rank, "taken");
        if (held_len == max_held) report(site, "SAFETY.md L4: more than {d} locks held", .{max_held}, rank, "taken");
    }
    held[held_len] = .{ .rank = rank, .site = site };
    held_len += 1;
    zio_held.acquired();
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

test "lock: tryLock of a held mutex fails and counts nothing" {
    var m: Mutex(.leaf) = .init;
    try std.testing.expect(m.tryLock());
    try std.testing.expect(!m.tryLock());
    if (enabled) try std.testing.expectEqual(@as(usize, 1), heldLocks());
    m.unlock(std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), heldLocks());
}

test "lock: a condition wait gives the lock back while it sleeps" {
    var m: Mutex(.leaf) = .init;
    var c: Condition = .init;
    try m.lock(std.testing.io);
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

/// Fails unless `out` names the source line `line` of this file.
fn expectSite(out: []const u8, line: u32) !void {
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
