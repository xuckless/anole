//! A body between an executor and a consumer thread, one per direction of
//! a slot: the request body the executor reads from the client and the
//! consumer takes with `anole_req_read`, or a streamed response the
//! consumer writes with `anole_stream_write` and the executor sends.
//!
//! Embedded in its slot and never freed while the engine lives, so a stale
//! handle can always take the lock and find the pipe serves another
//! generation (`gen`): its call gets `error.Gone`, never a freed pointer.
//! The lock is a spin lock held only to move bytes or flags, never across a
//! wait.
const std = @import("std");

const engine = @import("engine.zig");
pub const gpa = engine.gpa;

pub const Chunk = struct {
    data: []const u8,
    off: usize = 0,
    owner: Owner,
    /// For `.consumer` chunks: the `ANOLE_EV_SENT` record the borrowing call
    /// built, posted when the chunk is no longer read.
    sent: ?[]align(8) u8 = null,

    pub const Owner = enum {
        /// Allocated here (the thread-safe allocator, exactly `data`'s
        /// length): freed once used.
        pipe,
        /// Borrowed from the consumer (`ANOLE_BODY_BORROW`), which hears
        /// when it is no longer read (`ANOLE_EV_SENT`).
        consumer,
        /// The request's own memory (its arena), which outlives the pipe's
        /// use of it.
        request,
    };
};

pub const Pipe = struct {
    lock: std.atomic.Mutex = .unlocked,
    /// The slot generation this pipe serves; 0 when it serves none.
    gen: u32 = 0,
    chunks: std.ArrayList(Chunk) = .empty,
    head: usize = 0,
    /// Bytes waiting.
    bytes: usize = 0,
    /// The producer has finished (the body ended, `anole_stream_end`).
    ended: bool = false,
    /// The pipe broke: the request body failed (`body_error`), or the
    /// response stream was given up (`anole_release`).
    failed: bool = false,
    /// The consumer was told "nothing now" (`ANOLE_E_AGAIN`) or "full"
    /// (`ANOLE_BUSY`) and waits for an event.
    want_event: bool = false,
    /// The executor's task waits for this pipe (more response body, room
    /// for more request body): set its slot's event.
    exec_waiting: bool = false,
    /// A consumer thread blocked in a call with a timeout waits on this.
    seq: std.atomic.Value(u32) = .init(0),
    blocked: std.atomic.Value(u32) = .init(0),

    pub fn acquire(p: *Pipe) void {
        while (!p.lock.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn release(p: *Pipe) void {
        p.lock.unlock();
    }

    /// Starts serving generation `gen`. Locked.
    pub fn open(p: *Pipe, gen: u32) void {
        std.debug.assert(p.chunks.items.len == p.head);
        p.gen = gen;
        p.bytes = 0;
        p.ended = false;
        p.failed = false;
        p.want_event = false;
        p.exec_waiting = false;
    }

    /// Serves no generation any more; returns what was left, for the caller
    /// to free (owned) or report sent (borrowed) outside the lock. Locked.
    pub fn close(p: *Pipe) []Chunk {
        p.gen = 0;
        const rest = p.chunks.items[p.head..];
        p.bytes = 0;
        return rest;
    }

    /// After `close` and dealing with what it returned: forget them.
    /// Locked, or once nobody else can reach the pipe.
    pub fn clear(p: *Pipe) void {
        p.chunks.clearRetainingCapacity();
        p.head = 0;
        if (p.chunks.capacity > 64) p.chunks.clearAndFree(gpa);
    }

    pub fn live(p: *const Pipe, gen: u32) bool {
        return p.gen != 0 and p.gen == gen;
    }

    /// Appends a chunk. Locked.
    pub fn push(p: *Pipe, chunk: Chunk) error{OutOfMemory}!void {
        if (p.head > 0 and p.head == p.chunks.items.len) {
            p.chunks.clearRetainingCapacity();
            p.head = 0;
        }
        try p.chunks.append(gpa, chunk);
        p.bytes += chunk.data.len - chunk.off;
    }

    /// The next chunk, if any; consumed with `pop`. Locked.
    pub fn front(p: *Pipe) ?*Chunk {
        if (p.head == p.chunks.items.len) return null;
        return &p.chunks.items[p.head];
    }

    /// Takes `n` bytes of the front chunk; returns it when it is used up
    /// (the caller frees or reports it outside the lock). Locked.
    pub fn take(p: *Pipe, n: usize) ?Chunk {
        const ch = &p.chunks.items[p.head];
        ch.off += n;
        p.bytes -= n;
        if (ch.off < ch.data.len) return null;
        const done = ch.*;
        p.head += 1;
        if (p.head == p.chunks.items.len) {
            p.chunks.clearRetainingCapacity();
            p.head = 0;
        }
        return done;
    }

    /// Copies up to `out.len` bytes out, freeing owned chunks used up.
    /// Borrowed ones used up go to `sent` (when given room). Locked.
    pub fn read(p: *Pipe, out: []u8) usize {
        var n: usize = 0;
        while (n < out.len) {
            const ch = p.front() orelse break;
            const rest = ch.data[ch.off..];
            const k = @min(rest.len, out.len - n);
            @memcpy(out[n..][0..k], rest[0..k]);
            n += k;
            if (p.take(k)) |done| {
                if (done.owner == .pipe) gpa.free(done.data);
            }
        }
        return n;
    }

    /// Bumps the futex word and wakes consumer threads blocked on it.
    /// Unlocked or locked; any thread.
    pub fn notifyBlocked(p: *Pipe) void {
        _ = p.seq.fetchAdd(1, .release);
        if (p.blocked.load(.acquire) > 0) {
            const tio = std.Io.Threaded.global_single_threaded.io();
            tio.futexWake(u32, &p.seq.raw, std.math.maxInt(u32));
        }
    }

    /// Frees the pipe's own list (the engine's end).
    pub fn deinit(p: *Pipe) void {
        for (p.chunks.items[p.head..]) |ch| {
            if (ch.owner == .pipe) gpa.free(ch.data);
            if (ch.sent) |r| engine.freeRecord(r.ptr);
        }
        p.chunks.deinit(gpa);
    }
};
