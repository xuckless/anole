//! The snapshots the console asks for that need the runtime's locks (the
//! rooms, the SSE topics, the database pools): a task of the runtime makes
//! them under those locks, and the console's thread, which must not take a
//! lock of the runtime, waits for the answer (up to `wait_ms`).
const std = @import("std");
const builtin = @import("builtin");
const safety = @import("anole_safety");

pub const What = enum(u8) { ws, db };

/// Writes the snapshot `what` as JSON. Runs on the collector's task.
pub const CollectFn = *const fn (ctx: *anyopaque, what: What, w: *std.Io.Writer) anyerror!void;

/// The console's threads wait on the blocking `Io`, never the runtime's.
fn blockingIo() std.Io {
    return std.Options.debug_io;
}

pub const Collector = struct {
    gpa: std.mem.Allocator,
    /// The runtime's.
    io: std.Io,
    ctx: *anyopaque,
    collect: CollectFn,
    /// The console asked (set from its thread: a wake of the runtime).
    ask: std.Io.Event = .unset,
    asked: std.atomic.Value(u32) = .init(0),
    what: std.atomic.Value(u8) = .init(0),
    /// An answer is in `out` (set on the blocking `Io`).
    answered: std.Io.Event = .unset,
    /// Over `out`, `out_seq` and `out_ok`; held only to swap or move `out`,
    /// never to allocate (SAFETY.md L5).
    lock: safety.SpinLock(.leaf) = .init,
    /// The latest answer: made by the collector's task, taken (and freed)
    /// by the console thread that asked for it, or replaced by the next.
    out: std.ArrayList(u8) = .empty,
    out_seq: u32 = 0,
    out_ok: bool = false,
    /// One asker at a time (the console serves up to four clients).
    // SAFETY: L2/L5 do not fit this lock: only console OS threads take it
    // (never a zio task), and it is held across their blocking wait for the
    // runtime's answer (up to `wait_ms`) on `std.Options.debug_io`, by
    // design: one asker at a time. Waiters sleep-poll (1 ms).
    serial: std.atomic.Mutex = .unlocked,
    task: ?std.Io.Future(void) = null,

    pub const wait_ms = 200;
    /// Tests: replaces `wait_ms`, so that a test's ask waits for the answer
    /// however slow the machine is (its own deadline still holds). Test
    /// builds only.
    pub var test_wait_ms: if (builtin.is_test) ?u32 else void = if (builtin.is_test) null else {};

    /// On a task of the runtime (the server's run).
    pub fn start(c: *Collector) !void {
        c.task = try c.io.concurrent(run, .{c});
    }

    /// After the console stopped (no thread of its asks any more).
    pub fn stop(c: *Collector) void {
        // An ask wakes the runtime from a console thread (`ask.set`), which
        // is safe only while the runtime lives: `Console.stop` joins every
        // such thread before this, and this runs before the runtime goes.
        // A thread still inside `snapshot` holds `serial`.
        if (std.debug.runtime_safety and !c.serial.tryLock())
            @panic("console collector: stopped while a console thread is still asking");
        if (c.task) |*t| t.cancel(c.io);
        c.task = null;
        c.out.deinit(c.gpa);
    }

    fn run(c: *Collector) void {
        while (true) {
            c.ask.wait(c.io) catch return;
            c.ask.reset();
            // `what` was stored before `asked`.
            const seq = c.asked.load(.acquire);
            const what: What = @fromBackingInt(@intCast(c.what.load(.acquire)));
            var buf: std.Io.Writer.Allocating = .init(c.gpa);
            defer buf.deinit();
            const ok = if (c.collect(c.ctx, what, &buf.writer)) |_| true else |_| false;
            // The answer is made outside the lock; under it, only swapped
            // in. The one it replaces is freed after.
            var answer = buf.toArrayList();
            c.lock.lock();
            // An answer to an older seq is dropped here: only the current asker (`serial`) reads one.
            std.mem.swap(std.ArrayList(u8), &c.out, &answer);
            c.out_seq = seq;
            c.out_ok = ok;
            c.lock.unlock();
            answer.deinit(c.gpa);
            c.answered.set(blockingIo());
        }
    }

    /// From a console thread: the snapshot `what` into `w`. `error.Busy`
    /// when the runtime did not answer within `wait_ms`.
    pub fn snapshot(c: *Collector, what: What, w: *std.Io.Writer) !void {
        while (!c.serial.tryLock()) std.Io.sleep(blockingIo(), .fromMilliseconds(1), .awake) catch {};
        defer c.serial.unlock();
        const seq = c.asked.load(.monotonic) +% 1;
        c.answered.reset();
        c.what.store(@backingInt(what), .release);
        c.asked.store(seq, .release);
        c.ask.set(c.io);
        const ms: u32 = if (comptime builtin.is_test) test_wait_ms orelse wait_ms else wait_ms;
        const deadline = std.Io.Clock.Timestamp.now(blockingIo(), .awake).addDuration(.{ .raw = .fromMilliseconds(ms), .clock = .awake });
        while (true) {
            if (try c.take(seq, w)) return;
            // A late answer to an earlier ask woke this: look again after
            // the reset, so an answer that came meanwhile is not missed.
            c.answered.reset();
            if (try c.take(seq, w)) return;
            c.answered.waitTimeout(blockingIo(), .{ .deadline = deadline }) catch return error.Busy;
        }
    }

    /// The answer to `seq` into `w`, if it is in: moved out under the
    /// lock, written and freed after it.
    fn take(c: *Collector, seq: u32, w: *std.Io.Writer) !bool {
        var answer, const ok = taken: {
            c.lock.lock();
            defer c.lock.unlock();
            if (c.out_seq != seq) return false;
            const moved = c.out;
            c.out = .empty;
            break :taken .{ moved, c.out_ok };
        };
        defer answer.deinit(c.gpa);
        if (!ok) return error.CollectFailed;
        try w.writeAll(answer.items);
        return true;
    }
};
