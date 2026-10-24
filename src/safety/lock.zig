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
threadlocal var held: [max_held]Rank = undefined;
threadlocal var held_len: u8 = 0;

/// The locks the calling thread holds through these types (0 outside debug builds).
pub fn heldLocks() usize {
    return if (enabled) held_len else 0;
}

/// About to wait for a suspending lock: nothing may be held (L2).
fn beforeWait(rank: Rank) void {
    if (!enabled or held_len == 0) return;
    std.debug.panic("SAFETY.md L2: waiting for a {s} lock while holding a {s} lock: a lock wait is a suspension point", .{ @tagName(rank), @tagName(held[held_len - 1]) });
}

fn acquired(rank: Rank) void {
    if (!enabled) return;
    if (held_len > 0) {
        const top = held[held_len - 1];
        if (rank == .leaf or top == .leaf or @intFromEnum(rank) <= @intFromEnum(top))
            std.debug.panic("SAFETY.md L4: taking a {s} lock while holding a {s} lock breaks the lock order", .{ @tagName(rank), @tagName(top) });
        if (held_len == max_held) std.debug.panic("SAFETY.md L4: more than {d} locks held", .{max_held});
    }
    held[held_len] = rank;
    held_len += 1;
    zio_held.acquired();
}

fn releasing(rank: Rank) void {
    if (!enabled) return;
    var i: usize = held_len;
    while (i > 0) {
        i -= 1;
        if (held[i] == rank) {
            std.mem.copyForwards(Rank, held[i .. held_len - 1], held[i + 1 .. held_len]);
            held_len -= 1;
            zio_held.released();
            return;
        }
    }
    std.debug.panic("SAFETY.md L4: releasing a {s} lock this thread does not hold", .{@tagName(rank)});
}

/// A lock whose waiters suspend (`std.Io.Mutex`), ranked for L4.
pub fn Mutex(comptime rank: Rank) type {
    return struct {
        inner: std.Io.Mutex = .init,

        const Self = @This();
        pub const init: Self = .{};

        pub fn lock(self: *Self, io: std.Io) std.Io.Cancelable!void {
            beforeWait(rank);
            try self.inner.lock(io);
            acquired(rank);
        }

        pub fn lockUncancelable(self: *Self, io: std.Io) void {
            beforeWait(rank);
            self.inner.lockUncancelable(io);
            acquired(rank);
        }

        pub fn tryLock(self: *Self) bool {
            if (!self.inner.tryLock()) return false;
            acquired(rank);
            return true;
        }

        pub fn unlock(self: *Self, io: std.Io) void {
            releasing(rank);
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
            acquired(rank);
        }

        pub fn tryLock(self: *Self) bool {
            if (!self.inner.tryLock()) return false;
            acquired(rank);
            return true;
        }

        pub fn unlock(self: *Self) void {
            releasing(rank);
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
        releasing(rank);
        beforeWait(rank);
        defer acquired(rank);
        return self.inner.wait(io, &m.inner);
    }

    pub fn waitUncancelable(self: *Condition, io: std.Io, m: anytype) void {
        const rank = rankOf(@TypeOf(m));
        releasing(rank);
        beforeWait(rank);
        defer acquired(rank);
        self.inner.waitUncancelable(io, &m.inner);
    }

    pub fn waitTimeout(self: *Condition, io: std.Io, m: anytype, timeout: std.Io.Timeout) std.Io.Condition.WaitTimeoutError!void {
        const rank = rankOf(@TypeOf(m));
        releasing(rank);
        beforeWait(rank);
        defer acquired(rank);
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
