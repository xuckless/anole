// lint-path: src/capi/t5_capi.zig
const std = @import("std");

pub const IoGate = struct {
    closed: bool = false,

    pub fn setEvent(g: *IoGate, io: std.Io, ev: *std.Io.Event) void {
        _ = g;
        ev.set(io);
    }

    pub fn wakeFutex(g: *IoGate, io: std.Io, word: *const std.atomic.Value(u32)) void {
        _ = g;
        io.futexWake(u32, &word.raw, std.math.maxInt(u32));
    }
};

/// From any thread: rings the executor.
fn foreign(x: anytype, io: std.Io, rt_io: std.Io) void {
    x.event.set(x.io); // expect: T5
    io.futexWake(u32, &x.word.raw, 1); // expect: T5
    x.cond.signal(io); // expect: T5
    x.cond.broadcast(rt_io); // expect: T5
    x.mutex.unlock(io); // expect: T5
    x.queue.putOne(x.app.io(), 1) catch {}; // expect: T5
    x.queue.put(io, &.{1}, 1) catch {}; // expect: T5
    x.gate.setEvent(io, &x.event);
    x.map.put(x.gpa, 1, 2) catch {};
    x.flag.set(true);
    x.started.set(threadedIo());
    threadedIo().futexWake(u32, &x.bell.raw, 1);
    x.done.set(std.Io.Threaded.global_single_threaded.io());
}

/// On the executor: wakes whatever task serves the transfer.
fn onExecutor(x: anytype, io: std.Io) void {
    x.event.set(io);
}

/// Run by the capi task: answers what is due.
fn capiTask(x: anytype) void {
    x.event.set(x.io);
}

/// Hands answers over. Run by the capi task (not at the start: not enough).
fn laterPhrase(x: anytype) void {
    x.event.set(x.io); // expect: T5
}

fn reasoned(x: anytype) void {
    // SAFETY: the run thread is joined before the runtime goes.
    x.event.set(x.io);
}

fn threadedIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

test "test code may wake directly" {
    var ev: std.Io.Event = .unset;
    ev.set(std.testing.io);
}
