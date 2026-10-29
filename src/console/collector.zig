//! The snapshots the console asks for that need the runtime's locks (the
//! rooms, the SSE topics, the database pools): a task of the runtime makes
//! them under those locks, and the console's thread, which must not take a
//! lock of the runtime, waits for the answer (up to `wait_ms`).
const std = @import("std");

pub const What = enum(u8) { ws, db };

/// Writes the snapshot `what` as JSON. Runs on the collector's task.
pub const CollectFn = *const fn (ctx: *anyopaque, what: What, w: *std.Io.Writer) anyerror!void;

/// The console's threads wait on the blocking `Io`, never the runtime's.
fn blockingIo() std.Io {
    return std.Options.debug_io;
}

fn spin(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) std.atomic.spinLoopHint();
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
    /// Over `out`, `out_seq` and `out_ok`; held only to copy.
    lock: std.atomic.Mutex = .unlocked,
    out: std.ArrayList(u8) = .empty,
    out_seq: u32 = 0,
    out_ok: bool = false,
    /// One asker at a time (the console serves up to four clients).
    serial: std.atomic.Mutex = .unlocked,
    task: ?std.Io.Future(void) = null,

    pub const wait_ms = 200;

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
            var ok = if (c.collect(c.ctx, what, &buf.writer)) |_| true else |_| false;
            spin(&c.lock);
            c.out.clearRetainingCapacity();
            c.out.appendSlice(c.gpa, buf.written()) catch {
                ok = false;
            };
            c.out_seq = seq;
            c.out_ok = ok;
            c.lock.unlock();
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
        const deadline = std.Io.Clock.Timestamp.now(blockingIo(), .awake).addDuration(.{ .raw = .fromMilliseconds(wait_ms), .clock = .awake });
        while (true) {
            if (try c.take(seq, w)) return;
            // A late answer to an earlier ask woke this: look again after
            // the reset, so an answer that came meanwhile is not missed.
            c.answered.reset();
            if (try c.take(seq, w)) return;
            c.answered.waitTimeout(blockingIo(), .{ .deadline = deadline }) catch return error.Busy;
        }
    }

    /// The answer to `seq` into `w`, if it is in.
    fn take(c: *Collector, seq: u32, w: *std.Io.Writer) !bool {
        spin(&c.lock);
        defer c.lock.unlock();
        if (c.out_seq != seq) return false;
        if (!c.out_ok) return error.CollectFailed;
        try w.writeAll(c.out.items);
        return true;
    }
};
