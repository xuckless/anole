//! The engine under Anole's C ABI (`include/anole.h`): requests a route
//! hands to a consumer (a language thread: Node, Python, a C program) cross
//! through a lock-free ring per executor, and the consumer answers by
//! handle. docs/c-abi.md is the binding author's view; this is how it works.
//!
//! Rules (research/c-abi-design-2026-10-21.md, as amended by the spike):
//! - No executor ever runs consumer code. An executor fills a slot, pushes
//!   its handle onto the ring of the consumer it feeds, and rings the
//!   consumer's doorbell only when the consumer has said it is going to
//!   sleep (`awake` false). The doorbell is the consumer's own non-blocking
//!   callback (a threadsafe function, an eventfd write) or Anole's fd. A
//!   doorbell may be lost (Bun's threadsafe functions drop calls), so each
//!   executor rings again after `timeouts.rewake_ms` when its ring stays
//!   unpolled: "at least once, may repeat".
//! - The consumer drains a whole batch with one `poll` into its own buffer
//!   and answers with `respond` (or a stream), which writes the reply into
//!   the slot and pushes the slot onto its executor's done list. Only the
//!   push that finds the list empty wakes the executor's capi task, which
//!   hands each reply to its request: one remote wake per burst.
//! - Handles are 64-bit: executor (8 bits), slot (24), generation (32). A
//!   slot's state and generation share one atomic word, so a stale handle
//!   can never claim a reused slot: it gets `error.Gone`.
//! - Over HTTP/1.1 the request's task waits for the reply. Over HTTP/2 and
//!   HTTP/3, a request that arrived whole runs on the connection's reader
//!   and its response is detached (`anole.http.core.Detached`): no task
//!   waits, and the capi task writes the reply into the connection, whose
//!   writer sends it. A streamed reply or a file gets a task then.
//! - Anole enforces deadlines with one sweeper per executor (the capi task)
//!   over a deadline-ordered list per distinct timeout: no timer per
//!   request. At the deadline the client gets 504 and the slot is freed
//!   at once; a reply after that gets `error.Gone`.
const std = @import("std");
const builtin = @import("builtin");
const anole = @import("../root.zig");
const dusty = @import("dusty");
pub const abi = @import("abi.zig");
const config_mod = @import("config.zig");
const pipe_mod = @import("pipe.zig");
const features = anole.features;
const http = anole.http;
const zio = anole.zio;
const placement = dusty.placement;
const Detached = dusty.Detached;
const Pipe = pipe_mod.Pipe;
const Chunk = pipe_mod.Chunk;
pub const Config = config_mod.Config;
pub const ws = if (features.websocket) @import("ws.zig") else struct {
    pub const ExecState = struct {
        pub fn deinit(_: *ExecState) void {}
        pub fn maxGen(_: *const ExecState) u32 {
            return 0;
        }
    };
};
/// gRPC services implemented by consumers (`anole_grpc_*`).
pub const grpc = if (features.grpc) @import("grpc.zig") else struct {
    pub const SlotState = struct {};
    pub const ExecState = struct {
        pub fn deinit(_: *ExecState) void {}
    };
    pub const EngineState = struct {};
};
pub const wt = if (features.http3) @import("wt.zig") else struct {
    pub const ExecState = struct {
        pub fn deinit(_: *ExecState) void {}
        pub fn maxGen(_: *const ExecState) u32 {
            return 0;
        }
    };
};
pub const pipe = pipe_mod;
pub const db = @import("db.zig");
pub const config = config_mod;

const log = std.log.scoped(.anole_capi);

/// The allocator for everything here: thread-safe, since consumers and
/// executors both use it.
pub const gpa = if (builtin.mode == .debug) debug_gpa.allocator() else std.heap.smp_allocator;
var debug_gpa: std.heap.DebugAllocator(.{ .thread_safe = true, .stack_trace_frames = 8 }) = .init;

/// The `std.Io` for consumer threads that block (`poll_wait`, blocking
/// reads and writes) and for `start`/`wait`, outside the runtime.
pub fn threadedIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

// ---------------------------------------------------------------------------
// Slots and handles

pub const SlotState = enum(u32) {
    /// On the executor's free list.
    free,
    /// Filled, its handle in the consumer's ring.
    queued,
    /// `poll` is copying its head out (request memory is being read).
    polling,
    /// Delivered: the consumer owes an answer.
    out,
    /// The consumer is writing its answer in.
    responding,
    /// The answer is in; the executor takes it.
    done,
    /// A streamed answer: the head is in, the body comes through `out`.
    streaming,
    /// The executor gave up on it (deadline, client gone): no answer is
    /// taken.
    expired,
};

pub fn pack(gen: u32, state: SlotState) u64 {
    return (@as(u64, gen) << 32) | @backingInt(state);
}
pub fn genOf(word: u64) u32 {
    return @intCast(word >> 32);
}
pub fn stateOf(word: u64) SlotState {
    return @fromBackingInt(@intCast(@as(u32, @truncate(word))));
}

/// A handle as the consumer sees it: which executor, which slot, which
/// generation of it, and which kind of thing (a function given a handle of
/// another kind answers `ANOLE_E_GONE`, never acts on the wrong object).
pub const Handle = packed struct(u64) {
    gen: u28,
    kind: Kind,
    slot: u24,
    exec: u8,

    /// Room for what ABI 0.x adds before it freezes: gRPC calls, WebTransport
    /// sessions and streams, database queries.
    pub const Kind = enum(u4) {
        request = 1,
        websocket = 2,
        grpc_call = 3,
        wt_session = 4,
        wt_stream = 5,
        db_query = 6,
        _,
    };

    pub fn encode(h: Handle) u64 {
        return @bitCast(h);
    }
    pub fn decode(v: u64) Handle {
        return @bitCast(v);
    }
};

/// Generations count 1..max_gen and wrap to 1 (0 is never valid).
pub const max_gen: u32 = std.math.maxInt(u28);

pub fn nextGen(gen: u32) u32 {
    return if (gen >= max_gen) 1 else gen + 1;
}

/// The generation every slot of the next server starts at (requests,
/// WebSockets, WebTransport): past every generation a server before it in
/// this process handed out, so a handle kept from a destroyed server is
/// stale on the next one too, where the same slot may hold another request.
/// Set by `destroy`, read by `create` (one server at a time).
var next_first_gen: u32 = 1;

pub const ReplyHeader = struct { name_off: u32, name_len: u32, value_off: u32, value_len: u32 };

const Reply = enum { respond, release, fd };

pub const Slot = struct {
    word: std.atomic.Value(u64) = .init(pack(1, .free)),
    /// What its handles are (`Handle.Kind`): a request, or a gRPC call.
    /// Set by the executor while the slot is free.
    kind: std.atomic.Value(u8) = .init(@backingInt(Handle.Kind.request)),
    /// What a waiting request's task waits on (an answer, the deadline,
    /// stream data), and what an attached stream task waits on.
    event: std.Io.Event = .unset,
    /// What the request body's pump task waits on (room in `in`): an event
    /// of its own, since it waits beside the request's task.
    pump_event: std.Io.Event = .unset,

    // The request: set by the executor before the handle is queued, read by
    // `poll` while `polling`.
    req: *http.Request = undefined,
    route: *const Route = undefined,
    /// The body when it came inline.
    body: []const u8 = "",
    flags: u16 = 0,
    content_length: u64 = std.math.maxInt(u64),
    remote: [64]u8 = undefined,
    remote_len: u8 = 0,
    claims: []const u8 = "",

    // The answer: written by the consumer while `responding`, read by the
    // executor once `done` or `streaming`. Owned by the slot (the
    // thread-safe allocator), reused across requests.
    reply: Reply = .respond,
    status: u16 = 0,
    headers: std.ArrayList(ReplyHeader) = .empty,
    bytes: std.ArrayList(u8) = .empty,
    body_off: u32 = 0,
    body_len: u32 = 0,
    /// `ANOLE_BODY_BORROW`: the consumer's own memory.
    borrowed: ?[]const u8 = null,
    /// A file to send (`anole_respond_fd`; POSIX only).
    fd: c_int = -1,
    fd_offset: u64 = 0,
    fd_len: u64 = 0,
    /// Trailers of a streamed answer (`stream_end`), written under `out`'s
    /// lock before it is marked ended.
    trailers: std.ArrayList(ReplyHeader) = .empty,
    trailer_bytes: std.ArrayList(u8) = .empty,

    /// The request body when it is streamed (executor to consumer), and a
    /// streamed answer's body (consumer to executor).
    in: Pipe = .{},
    out: Pipe = .{},

    // Executor-local from here.
    /// The request's response is detached (HTTP/2, HTTP/3): no task waits.
    detached: ?*Detached = null,
    /// The detached request went away while the consumer was in a call on
    /// it: the capi task (or the sweeper) frees the slot once it can.
    orphan: bool = false,
    /// The sweeper's verdict for a waiting task.
    timed_out: bool = false,
    /// The request body failed (too large, cut short): the answer.
    body_error: ?http.Status = null,
    deadline: i96 = 0,
    list: u8 = 0,
    prev: u32 = no_slot,
    next: u32 = no_slot,
    linked: bool = false,
    next_done: u32 = no_slot,
    /// Taken off the done list by the capi task (a task woken some other
    /// way must not free a slot still on it).
    drained: std.atomic.Value(bool) = .init(true),
    next_free: u32 = no_slot,
    /// A gRPC call's own state (`kind` grpc_call).
    grpc: grpc.SlotState = .{},

    /// Above this, a slot's answer buffer is freed after use.
    const keep_capacity = 64 * 1024;

    pub fn replyBody(s: *const Slot) []const u8 {
        if (s.borrowed) |b| return b;
        return s.bytes.items[s.body_off..][0..s.body_len];
    }
};

pub const no_slot = std.math.maxInt(u32);

/// Records up to this size never wait for `Exec.record_bytes` to fall.
const small_record = 1024;

fn closeFd(fd: c_int) void {
    if (comptime builtin.os.tag == .windows) return;
    _ = std.c.close(fd);
}

// ---------------------------------------------------------------------------
// The SPSC ring: one executor produces, one consumer thread consumes.

/// A request whose record `poll` builds from its slot (`rec` null), or a
/// record built already (owned, freed by `poll`).
const Entry = struct {
    handle: u64,
    rec: ?[*]align(8) u8,
};

const Ring = struct {
    head: std.atomic.Value(u64) align(std.atomic.cache_line) = .init(0),
    tail: std.atomic.Value(u64) align(std.atomic.cache_line) = .init(0),
    buf: []Entry,
    mask: u64,

    fn init(capacity: usize) !Ring {
        const cap = std.math.ceilPowerOfTwo(usize, @max(capacity, 2)) catch return error.OutOfMemory;
        return .{ .buf = try gpa.alloc(Entry, cap), .mask = cap - 1 };
    }
    fn deinit(r: *Ring) void {
        // Records nobody polled.
        var h = r.head.raw;
        while (h != r.tail.raw) : (h += 1) if (r.buf[h & r.mask].rec) |rec| freeRecord(rec);
        gpa.free(r.buf);
    }
    /// Producer. False when full.
    pub fn push(r: *Ring, e: Entry) bool {
        const tail = r.tail.raw;
        if (tail - r.head.load(.acquire) == r.buf.len) return false;
        r.buf[tail & r.mask] = e;
        // seq_cst: ordered before the producer's read of `awake` (Dekker
        // with the consumer's store of `awake` and read of `tail`).
        r.tail.store(tail + 1, .seq_cst);
        return true;
    }
    pub fn full(r: *Ring) bool {
        return r.tail.raw - r.head.load(.acquire) == r.buf.len;
    }
    /// Consumer.
    fn peek(r: *Ring) ?Entry {
        const head = r.head.raw;
        if (head == r.tail.load(.seq_cst)) return null;
        return r.buf[head & r.mask];
    }
    fn pop(r: *Ring) void {
        r.head.store(r.head.raw + 1, .release);
    }
    fn isEmpty(r: *Ring) bool {
        return r.head.load(.acquire) == r.tail.load(.seq_cst);
    }
};

fn freeRecord(rec: [*]align(8) u8) void {
    const ev: *const abi.Event = @ptrCast(rec);
    gpa.free(rec[0..ev.len]);
}

/// A record of `size` bytes (rounded up), its header filled in.
pub fn newRecord(size: usize, typ: abi.EventType, handle: u64) ![]align(8) u8 {
    const n = abi.alignUp(size);
    const rec = try gpa.alignedAlloc(u8, .@"8", n);
    @memset(rec[@sizeOf(abi.Event)..], 0);
    const ev: *abi.Event = @ptrCast(rec.ptr);
    ev.* = .{ .type = @backingInt(typ), .len = @intCast(n), .handle = handle };
    return rec;
}

// ---------------------------------------------------------------------------
// Work for an executor's capi task, from any thread.

pub const Command = struct {
    next: ?*Command = null,
    /// On the executor's capi task. Frees the command.
    run: *const fn (cmd: *Command, x: *Exec) void,
};

// ---------------------------------------------------------------------------
// Executors and consumers

const DeadlineList = struct {
    head: u32 = no_slot,
    tail: u32 = no_slot,
};

pub const Exec = struct {
    engine: *Engine,
    index: u8,
    slots: []Slot,
    /// Only this executor touches the free list.
    free_head: u32,
    ring: Ring,
    consumer: ?*Consumer = null,
    /// One list per distinct timeout: appending keeps each in deadline
    /// order, and the capi task sleeps until the earliest head.
    lists: [config_mod.max_timeouts]DeadlineList = @splat(.{}),
    /// The capi task's wake: an answer, a command, a deadline to look at.
    kick: std.Io.Event = .unset,
    /// The capi task sleeps a whole request timeout while nothing is out;
    /// the first request handed over wakes it, so that it watches for lost
    /// doorbells.
    idle: bool = false,
    /// Answered slots not yet handed to their requests: an intrusive stack
    /// pushed by consumers, taken whole by the capi task.
    done_head: std.atomic.Value(u32) = .init(no_slot),
    /// Commands (WebSocket sends, publishes), likewise.
    inbox: std.atomic.Value(?*Command) = .init(null),
    /// Bytes of built records (WebSocket messages and the like) in the
    /// ring: added by the executor, taken off by `poll`. Bounded by
    /// `record_budget`, so a consumer that falls behind holds back the
    /// sockets feeding it rather than the ring growing to its length in
    /// whole messages.
    record_bytes: std.atomic.Value(usize) = .init(0),
    ws: ws.ExecState = .{},
    grpc: grpc.ExecState = .{},
    wt: wt.ExecState = .{},
    db: db.ExecState = .{},

    /// The capi task is asleep for a whole request timeout: wakes it, as a
    /// deadline (or a lost doorbell) now needs watching.
    pub fn wakeIfIdle(x: *Exec) void {
        if (x.idle) {
            x.idle = false;
            x.kick.set(x.engine.io);
        }
    }

    fn link(x: *Exec, i: u32, list: u8, deadline: i96) void {
        x.wakeIfIdle();
        const s = &x.slots[i];
        s.deadline = deadline;
        s.list = list;
        s.timed_out = false;
        s.linked = true;
        s.next = no_slot;
        const l = &x.lists[list];
        s.prev = l.tail;
        if (l.tail != no_slot) x.slots[l.tail].next = i else l.head = i;
        l.tail = i;
    }

    fn unlink(x: *Exec, i: u32) void {
        const s = &x.slots[i];
        if (!s.linked) return;
        const l = &x.lists[s.list];
        if (s.prev != no_slot) x.slots[s.prev].next = s.next else l.head = s.next;
        if (s.next != no_slot) x.slots[s.next].prev = s.prev else l.tail = s.prev;
        s.linked = false;
    }

    pub fn alloc(x: *Exec) ?u32 {
        const i = x.free_head;
        if (i == no_slot) return null;
        x.free_head = x.slots[i].next_free;
        return i;
    }

    /// Frees slot `i`: a new generation makes every handle to the old one
    /// stale. What its pipes still hold is freed or reported sent.
    pub fn release(x: *Exec, i: u32) void {
        x.unlink(i);
        const s = &x.slots[i];
        const gen = genOf(s.word.load(.monotonic));
        x.closePipe(&s.in, gen, i);
        x.closePipe(&s.out, gen, i);
        if (s.fd >= 0) {
            closeFd(s.fd);
            s.fd = -1;
        }
        if (s.borrowed) |b| {
            x.postSent(x.handleOf(i, gen), b);
            s.borrowed = null;
        }
        if (s.bytes.capacity > Slot.keep_capacity) {
            s.bytes.clearAndFree(gpa);
            s.headers.clearAndFree(gpa);
        }
        if (s.trailer_bytes.capacity > Slot.keep_capacity) {
            s.trailer_bytes.clearAndFree(gpa);
            s.trailers.clearAndFree(gpa);
        }
        s.detached = null;
        s.orphan = false;
        s.body_error = null;
        s.claims = "";
        if (comptime features.grpc) if (s.kind.load(.monotonic) == @backingInt(Handle.Kind.grpc_call)) grpc.onRelease(x, i);
        s.kind.store(@backingInt(Handle.Kind.request), .monotonic);
        _ = x.engine.inflight.fetchSub(1, .monotonic);
        // 0 is skipped so that no handle is ever 0.
        const next = nextGen(gen);
        s.word.store(pack(next, .free), .release);
        s.next_free = x.free_head;
        x.free_head = i;
    }

    pub fn closePipe(x: *Exec, p: *Pipe, gen: u32, i: u32) void {
        p.acquire();
        const was_open = p.gen != 0;
        const rest = p.close();
        p.release();
        if (!was_open and rest.len == 0) return;
        for (rest) |ch| {
            dropChunk(x, i, gen, ch);
        }
        p.acquire();
        p.clear();
        p.release();
        // A consumer thread blocked on it sees the end.
        p.notifyBlocked();
    }

    /// Queues an owned record for the consumer, waiting for room in the
    /// ring if `wait` (else dropping it when full: advisory events only).
    /// A large record that waits also waits while the records already
    /// queued pass `record_budget` bytes (one always fits in an empty
    /// ring); small ones (events, `ANOLE_EV_SENT`) are bounded by the ring.
    pub fn postRecord(x: *Exec, rec: []align(8) u8, wait: bool) void {
        const c = x.consumer orelse return freeRecord(rec.ptr);
        if (wait and rec.len > small_record) while (true) {
            const queued = x.record_bytes.load(.acquire);
            if (queued == 0 or queued + rec.len <= x.engine.record_budget) break;
            // The consumer is behind: make sure it hears there is work.
            c.wake();
            zio.yield() catch return freeRecord(rec.ptr);
        };
        _ = x.record_bytes.fetchAdd(rec.len, .monotonic);
        while (!x.ring.push(.{ .handle = 0, .rec = rec.ptr })) {
            if (wait) if (zio.yield()) |_| continue else |_| {};
            _ = x.record_bytes.fetchSub(rec.len, .monotonic);
            return freeRecord(rec.ptr);
        }
        c.wake();
    }

    /// A small advisory event (`ANOLE_EV_ABORT`, `_BODY`, `_WRITABLE`,
    /// `_WS_DRAIN`).
    pub fn postEvent(x: *Exec, typ: abi.EventType, handle: u64) void {
        const rec = newRecord(@sizeOf(abi.Event), typ, handle) catch return;
        x.postRecord(rec, false);
    }

    /// `ANOLE_EV_SENT` for a borrowed body: it must arrive, so it waits for
    /// room when it can.
    pub fn postSent(x: *Exec, handle: u64, data: []const u8) void {
        const rec = newRecord(@sizeOf(abi.SentEvent), .sent, handle) catch return;
        const ev: *abi.SentEvent = @ptrCast(rec.ptr);
        ev.data = @intFromPtr(data.ptr);
        ev.len = data.len;
        x.postRecord(rec, placement.currentExecutor(x.engine.io) != null);
    }

    pub fn post(x: *Exec, cmd: *Command) void {
        var old = x.inbox.load(.monotonic);
        while (true) {
            cmd.next = old;
            old = x.inbox.cmpxchgWeak(old, cmd, .release, .monotonic) orelse break;
        }
        if (old == null) x.kick.set(x.engine.io);
    }

    pub fn handleOf(x: *const Exec, i: u32, gen: u32) u64 {
        const kind: Handle.Kind = @fromBackingInt(@intCast(x.slots[i].kind.load(.monotonic)));
        return Handle.encode(.{ .gen = @intCast(gen), .kind = kind, .slot = @intCast(i), .exec = x.index });
    }
};

pub const WakeFn = abi.WakeFn;

/// Windows has no pollable doorbell fd: consumers there pass a callback.
const have_fd = builtin.os.tag != .windows;

pub const Consumer = struct {
    engine: *Engine,
    wake_fn: ?WakeFn,
    wake_ud: ?*anyopaque,
    shared: bool,
    /// Anole's own doorbell when the consumer gave no callback: an eventfd
    /// (Linux) or a pipe (elsewhere).
    fd_read: c_int = -1,
    fd_write: c_int = -1,
    /// True while the consumer will poll again without being woken.
    awake: std.atomic.Value(bool) align(std.atomic.cache_line) = .init(false),
    /// Bumped by every wake, for threads blocked in `poll_wait`.
    bell: std.atomic.Value(u32) = .init(0),
    waiters: std.atomic.Value(u32) = .init(0),
    /// Serializes a shared consumer's polls.
    poll_lock: std.Io.Mutex = .init,
    /// The executors this consumer is fed by (set at start).
    execs: std.ArrayList(*Exec) = .empty,
    next_exec: usize = 0,
    /// Spreads `anole_db_*` queries over `execs`.
    next_db: std.atomic.Value(usize) = .init(0),
    stopped_sent: bool = false,
    /// When `poll` last ran (awake clock, ns), for the lost-wake check.
    last_poll: std.atomic.Value(i64) = .init(0),
    wakes: std.atomic.Value(u64) = .init(0),
    rewakes: std.atomic.Value(u64) = .init(0),

    pub fn wake(c: *Consumer) void {
        // Cheap when the consumer is busy: one load of a line it rarely
        // writes.
        if (c.awake.load(.seq_cst)) return;
        if (c.awake.swap(true, .seq_cst)) return;
        c.ring();
    }

    fn ring(c: *Consumer) void {
        _ = c.wakes.fetchAdd(1, .monotonic);
        _ = c.bell.fetchAdd(1, .release);
        if (c.waiters.load(.acquire) > 0) threadedIo().futexWake(u32, &c.bell.raw, std.math.maxInt(u32));
        if (c.wake_fn) |f| return f(c.wake_ud);
        if (have_fd and c.fd_write >= 0) {
            if (comptime builtin.os.tag == .linux) {
                const one: u64 = 1;
                _ = std.c.write(c.fd_write, std.mem.asBytes(&one), 8);
            } else {
                const b: u8 = 1;
                _ = std.c.write(c.fd_write, @ptrCast(&b), 1);
            }
        }
    }

    /// Rings again although the doorbell is up: the runtime lost the first
    /// ring (Bun 1.3's threadsafe functions drop calls; a loop shutting
    /// down drops call_soon_threadsafe). From any executor's capi task.
    fn rewake(c: *Consumer) void {
        _ = c.rewakes.fetchAdd(1, .monotonic);
        c.ring();
    }

    fn drainFd(c: *Consumer) void {
        if (!have_fd or c.fd_read < 0) return;
        var buf: [64]u8 = undefined;
        while (true) {
            const n = std.c.read(c.fd_read, &buf, buf.len);
            if (n <= 0) return;
            if (comptime builtin.os.tag == .linux) return;
        }
    }

    fn openFd(c: *Consumer) !void {
        if (comptime builtin.os.tag == .linux) {
            const fd = std.c.eventfd(0, std.os.linux.EFD.NONBLOCK | std.os.linux.EFD.CLOEXEC);
            if (fd < 0) return error.SystemResources;
            c.fd_read = fd;
            c.fd_write = fd;
        } else if (comptime !have_fd) {
            return error.Unsupported;
        } else {
            var fds: [2]std.c.fd_t = undefined;
            if (std.c.pipe(&fds) != 0) return error.SystemResources;
            for (fds) |fd| {
                const fl = std.c.fcntl(fd, std.c.F.GETFL);
                _ = std.c.fcntl(fd, std.c.F.SETFL, fl | @as(c_int, @bitCast(std.c.O{ .NONBLOCK = true })));
                _ = std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
            }
            c.fd_read = fds[0];
            c.fd_write = fds[1];
        }
    }

    fn deinit(c: *Consumer) void {
        if (have_fd) {
            if (c.fd_read >= 0) closeFd(c.fd_read);
            if (c.fd_write >= 0 and c.fd_write != c.fd_read) closeFd(c.fd_write);
        }
        c.execs.deinit(gpa);
    }
};

// ---------------------------------------------------------------------------
// Routes

pub const Route = struct {
    engine: *Engine,
    /// The consumer's route id ("handler").
    id: u32,
    /// Which deadline list (and timeout) its requests use.
    list: u8 = 0,
    /// Its requests may detach: nothing in its chain waits.
    detachable: bool = true,
    /// A WebSocket endpoint's settings.
    ws: if (features.websocket) ?anole.websocket.UpgradeOptions else void = if (features.websocket) null else {},
    /// A WebTransport endpoint's settings.
    wt: if (features.http3) ?wt.Options else void = if (features.http3) null else {},
};

// ---------------------------------------------------------------------------
// The engine: one per process.

pub const Phase = enum(u8) { created, starting, running, draining, stopped, failed };

pub var global: ?*Engine = null;

/// Tests: runs inside a control call (drain, reload) once it holds the
/// server, before it calls into it.
pub var test_control_hook: ?*const fn () void = null;

pub const Engine = struct {
    arena: std.heap.ArenaAllocator,
    config: Config,
    signals: bool,
    consumers: std.ArrayList(*Consumer) = .empty,
    execs: []Exec = &.{},
    thread: ?std.Thread = null,
    phase: std.atomic.Value(Phase) = .init(.created),
    /// Set by the anole main thread once listening (or failed); waited on by
    /// `start` with a plain threaded Io (no runtime yet).
    started: std.Io.Event = .unset,
    start_error: ?anyerror = null,
    /// What `start_error` was about, when there is more to say
    /// (`error.RouteConflict`: the routes).
    start_why: [400]u8 = undefined,
    start_why_len: usize = 0,
    stopped: std.Io.Event = .unset,
    /// The server, on the run thread's stack: freed when `run` returns.
    /// Control calls from other threads (`drain`, the reloads) reach it
    /// only through `enter`.
    app: ?*anole.App = null,
    /// `ctl_closed` while there is no server to call into (before it
    /// serves, once `run` returned), plus the control calls inside it: the
    /// run thread closes it and waits for those before it frees the server.
    ctl: std.atomic.Value(u32) = .init(ctl_closed),
    /// The generation its slots start at (`next_first_gen` at create).
    first_gen: u32 = 1,
    /// The runtime's Io, for waking executor tasks from consumer threads
    /// (zio's wakes work from any thread).
    io: std.Io = undefined,
    ports: std.ArrayList(u16) = .empty,
    /// One capi task per executor.
    tasks: std.Io.Group = .init,
    /// The timeout of each deadline list.
    timeouts: [config_mod.max_timeouts]i96 = @splat(0),
    ntimeouts: u8 = 1,
    inline_body_max: u32,
    stream_high_water: usize,
    /// Bytes of built records each executor's ring may hold (see
    /// `Exec.record_bytes`).
    record_budget: usize = 0,
    rewake: i96,
    // Counters.
    requests: std.atomic.Value(u64) = .init(0),
    detached_count: std.atomic.Value(u64) = .init(0),
    inflight: std.atomic.Value(u64) = .init(0),
    expired_count: std.atomic.Value(u64) = .init(0),
    aborted_count: std.atomic.Value(u64) = .init(0),
    gone_count: std.atomic.Value(u64) = .init(0),
    busy_count: std.atomic.Value(u64) = .init(0),
    websockets: std.atomic.Value(u64) = .init(0),
    ws_in: std.atomic.Value(u64) = .init(0),
    ws_out: std.atomic.Value(u64) = .init(0),
    /// Publishes taken and not yet fanned out (`ws.publishLimits`), and
    /// those refused for it.
    publishing: std.atomic.Value(usize) = .init(0),
    publish_bytes: std.atomic.Value(usize) = .init(0),
    publish_dropped: std.atomic.Value(u64) = .init(0),
    /// `anole_ws_subscribe` calls taken, and those applied on the socket's
    /// executor (or dropped): a publish waits for the ones taken before it,
    /// so it reaches a socket that subscribed before it was called.
    topic_changes: std.atomic.Value(u32) = .init(0),
    topic_changes_done: std.atomic.Value(u32) = .init(0),
    wt_sessions: std.atomic.Value(u64) = .init(0),
    wt_datagrams_dropped: std.atomic.Value(u64) = .init(0),
    /// The configuration's databases (`anole_db *`).
    dbs: []db.Db = &.{},
    /// WebSocket topics, shared by every executor.
    rooms: if (features.websocket) anole.websocket.Rooms else void = if (features.websocket) .init(gpa) else {},
    /// gRPC services, methods, descriptors and health.
    grpc: grpc.EngineState = .{},

    pub fn create(json: []const u8, signals: bool, why: *std.Io.Writer) !*Engine {
        const e = try gpa.create(Engine);
        errdefer gpa.destroy(e);
        e.* = .{
            .arena = .init(gpa),
            .config = undefined,
            .signals = signals,
            .inline_body_max = 0,
            .stream_high_water = 0,
            .rewake = 0,
            .first_gen = next_first_gen,
        };
        errdefer e.arena.deinit();
        const a = e.arena.allocator();
        // The document is copied: parsed values may point into it.
        e.config = try config_mod.parse(a, try a.dupe(u8, json), why);
        if (comptime features.grpc) try grpc.init(e, why);
        errdefer if (comptime features.grpc) grpc.deinit(e);
        const cfg = &e.config;
        e.inline_body_max = cfg.limits.inline_body_max;
        e.stream_high_water = cfg.limits.stream_high_water;
        e.record_budget = @max(16 * @as(usize, cfg.limits.ws_high_water), 2 * @as(usize, cfg.limits.ws_max_message));
        // A topic's subscriber gets as much queued as `anole_ws_send` lets
        // wait for a socket; past it, publishes skip it, and one stuck that
        // way is closed.
        if (comptime features.websocket) e.rooms.options.max_queued_bytes = cfg.limits.ws_high_water;
        e.rewake = @as(i96, cfg.timeouts.rewake_ms) * std.time.ns_per_ms;
        e.timeouts[0] = @as(i96, cfg.timeouts.request_ms) * std.time.ns_per_ms;
        e.dbs = try a.alloc(db.Db, cfg.databases.len);
        for (e.dbs, cfg.databases) |*d, dc| d.* = .{ .engine = e, .config = dc };
        // One per process: `respond` and the handlers find it here.
        global = e;
        return e;
    }

    /// The deadline list for a route's `timeout_ms`.
    fn listFor(e: *Engine, timeout_ms: ?u32) u8 {
        const t: i96 = @as(i96, timeout_ms orelse return 0) * std.time.ns_per_ms;
        for (e.timeouts[0..e.ntimeouts], 0..) |have, i| if (have == t) return @intCast(i);
        e.timeouts[e.ntimeouts] = t;
        e.ntimeouts += 1;
        return e.ntimeouts - 1;
    }

    /// Whether any route sends events to a consumer.
    pub fn needsConsumer(e: *const Engine) bool {
        for (e.config.routes) |r| if (r.handler != null or r.websocket != null or r.webtransport != null) return true;
        if (e.config.grpc) |g| if (g.services.len > 0) return true;
        return false;
    }

    pub fn attach(e: *Engine, wake_fn: ?WakeFn, wake_ud: ?*anyopaque, shared: bool) !*Consumer {
        if (e.phase.load(.acquire) != .created) return error.State;
        if (e.consumers.items.len >= 256) return error.State;
        const c = try gpa.create(Consumer);
        errdefer gpa.destroy(c);
        c.* = .{ .engine = e, .wake_fn = wake_fn, .wake_ud = wake_ud, .shared = shared };
        if (wake_fn == null and !shared and have_fd) try c.openFd();
        errdefer c.deinit();
        try e.consumers.append(gpa, c);
        return c;
    }

    pub fn start(e: *Engine) !void {
        if (e.phase.cmpxchgStrong(.created, .starting, .acq_rel, .acquire) != null) return error.State;
        e.thread = std.Thread.spawn(.{}, mainThread, .{e}) catch |err| {
            e.phase.store(.failed, .release);
            return err;
        };
        e.started.waitUncancelable(threadedIo());
        if (e.start_error) |err| {
            e.thread.?.join();
            e.thread = null;
            return err;
        }
    }

    /// The anole main thread: owns the runtime (it becomes executor 0),
    /// serves until `drain`, then frees the server.
    fn mainThread(e: *Engine) void {
        const cfg = e.config;
        const a = e.arena.allocator();
        var server_cfg: http.ServerConfig = .{};
        // Anole's own backstop, past the consumer deadline.
        var longest: u32 = cfg.timeouts.request_ms;
        for (cfg.routes) |r| if (r.timeout_ms) |t| {
            longest = @max(longest, t);
        };
        server_cfg.timeout.request = .fromMilliseconds(@as(i64, longest) + 5000);
        server_cfg.timeout.shutdown = .fromMilliseconds(cfg.timeouts.shutdown_ms);
        server_cfg.timeout.keepalive = .fromMilliseconds(cfg.timeouts.keepalive_ms);
        server_cfg.request.max_body_size = std.math.cast(usize, cfg.limits.body_max) orelse std.math.maxInt(usize);
        server_cfg.request.max_content_length = std.math.cast(usize, cfg.limits.body_max) orelse std.math.maxInt(usize);
        server_cfg.trusted_proxy_hops = cfg.trusted_proxy_hops;
        server_cfg.trust_forwarded_proto = cfg.trust_forwarded_proto;
        server_cfg.trust_forwarded_host = cfg.trust_forwarded_host;
        if (cfg.limits.max_connections > 0) server_cfg.max_connections = cfg.limits.max_connections;
        const listeners = buildListeners(a, cfg) catch |err| return e.failStart(err);
        var app = anole.App.init(gpa, .{
            .listeners = listeners,
            .executors = if (cfg.executors == 0) .auto else .exact(@intCast(cfg.executors)),
            .signals = e.signals,
            .raise_fd_limit = true,
            .server = server_cfg,
            .http3 = if (comptime features.http3) if (!wantsHttp3(cfg)) null else .{
                .max_streams_bidi = cfg.http3.max_streams_bidi,
                .idle_timeout = .fromMilliseconds(cfg.http3.idle_timeout_ms),
                .alt_svc = cfg.http3.alt_svc,
                .early_data = cfg.http3.early_data,
                .webtransport = wantsWebTransport(cfg),
            } else null,
        }) catch |err| return e.failStart(err);
        e.app = &app;
        e.io = app.io();
        const nexec = app.rt.executors.items.len;
        if (nexec > 256) return e.failStartDeinit(&app, error.TooManyExecutors);
        e.setupExecs(nexec) catch |err| return e.failStartDeinit(&app, err);
        // The routes come from the configuration: a conflict between them
        // is ANOLE_E_CONFIG, not a panic in the host process. Those Anole
        // adds while starting (metrics, health) are checked by `run`.
        app.router.record_conflicts = true;
        e.buildRoutes(&app) catch |err| return e.failStartDeinit(&app, err);
        if (app.router.conflict) |why| {
            e.setWhy(why);
            return e.failStartDeinit(&app, error.RouteConflict);
        }
        db.open(e, &app) catch |err| return e.failStartDeinit(&app, err);
        for (e.execs, 0..) |*x, i| placement.concurrent(&e.tasks, app.io(), .{ .executor = i }, capiTask, .{ e, x }) catch |err| {
            e.tasks.cancel(app.io());
            return e.failStartDeinit(&app, err);
        };
        var watcher = app.io().concurrent(watchReady, .{ e, &app }) catch |err| {
            e.tasks.cancel(app.io());
            return e.failStartDeinit(&app, err);
        };
        // Control calls may reach the server from here until `run` returns.
        _ = e.ctl.fetchAnd(~ctl_closed, .release);
        e.phase.store(.running, .release);
        const result = app.run();
        e.closeControl(app.io());
        watcher.cancel(app.io());
        e.tasks.cancel(app.io());
        if (comptime features.websocket) for (e.execs) |*x| x.ws.cancel(app.io());
        for (e.execs) |*x| x.db.cancel(app.io());
        db.close(e);
        if (result) |_| {} else |err| {
            if (!e.started.isSet()) {
                e.start_error = err;
                e.started.set(threadedIo());
            } else if (e.start_error == null) log.err("server stopped: {t}", .{err});
        }
        e.phase.store(.stopped, .release);
        e.app = null;
        app.deinit();
        if (comptime features.websocket) e.rooms.deinit();
        // Every consumer hears of the stop (ANOLE_EV_STOPPED).
        for (e.consumers.items) |c| {
            c.awake.store(false, .seq_cst);
            c.wake();
        }
        e.stopped.set(threadedIo());
    }

    fn wantsWebTransport(cfg: Config) bool {
        for (cfg.routes) |r| if (r.webtransport != null) return true;
        return false;
    }

    fn wantsHttp3(cfg: Config) bool {
        for (cfg.listeners) |l| if (l.http3) return true;
        return false;
    }

    fn buildListeners(a: std.mem.Allocator, cfg: Config) ![]const anole.ServerOptions.Listener {
        const out = try a.alloc(anole.ServerOptions.Listener, cfg.listeners.len);
        for (cfg.listeners, out) |l, *o| {
            o.* = .{
                .name = l.name,
                .address = l.address,
                .port = l.port,
                .unix = l.unix,
                .http1 = l.http1,
                .http2 = l.http2 and features.http2,
                .http3 = l.http3,
                .proxy_protocol = l.proxy_protocol,
                .proxy_protocol_from = l.proxy_protocol_from,
            };
            if (l.tls) |t| {
                if (comptime features.tls != .boringssl) return error.Unsupported;
                o.tls = .{
                    .cert = if (t.self_signed)
                        .dev_self_signed
                    else if (t.cert_file) |f|
                        .fromFiles(f, t.key_file.?)
                    else
                        .fromPem(t.cert_pem.?, t.key_pem.?),
                    .alpn_protocols = t.alpn,
                    .client_auth = switch (config_mod.clientAuth(t.client_auth).?) {
                        .none => null,
                        inline .request, .require => |m| .{
                            .ca = if (t.client_ca_file) |f| .{ .file = .{ .path = f } } else .{ .pem = t.client_ca_pem.? },
                            .mode = @field(http.ServerConfig.Tls.ClientAuth.Mode, @tagName(m)),
                        },
                    },
                };
            }
        }
        return out;
    }

    /// The configured middleware and routes, on `app`.
    fn buildRoutes(e: *Engine, app: *anole.App) !void {
        const cfg = e.config;
        const a = e.arena.allocator();
        const M = http.Middleware(void);
        if (cfg.observe.metrics) |m| _ = app.metrics(.{ .path = m.path });
        if (cfg.observe.health) |h| _ = app.health(.{ .healthz_path = h.live, .readyz_path = h.ready });
        for (cfg.middleware) |m| app.use(try config_mod.middleware(app, a, m));
        const global_ok = config_mod.neverWaits(cfg.middleware);
        if (comptime features.grpc) try grpc.buildRoutes(e, app, global_ok);
        for (cfg.routes) |rc| {
            const method: ?http.Method = if (rc.method) |m| config_mod.methodOf(m) else null;
            var chain: std.ArrayList(M) = .empty;
            for (rc.middleware) |m| try chain.append(a, try config_mod.middleware(app, a, m));
            if (rc.cache) |cc| {
                const cache = app.responseCache(.{
                    .ttl = .fromMilliseconds(cc.ttl_ms),
                    .authenticated = cc.authenticated,
                    .max_entries = cc.max_entries,
                    .max_bytes = std.math.cast(usize, cc.max_bytes) orelse std.math.maxInt(usize),
                    .name = rc.path,
                });
                try chain.append(a, M.init(cache));
            }
            const group = app.with(chain.items);
            if (rc.respond) |f| {
                group.inner.addRouteWith(method, rc.path, config_mod.FixedRoute.handler, .{ .data = try config_mod.fixed(a, f), .no_wait = rc.no_wait });
            } else if (rc.static) |st| {
                try group.staticDir(rc.path, st.dir, .{
                    .index = st.index,
                    .precompressed = try config_mod.precompressed(a, st.precompressed),
                    .cache_control = st.cache_control,
                    .hide_dotfiles = st.hide_dotfiles,
                });
            } else if (rc.handler) |id| {
                const route = try a.create(Route);
                route.* = .{
                    .engine = e,
                    .id = id,
                    .list = e.listFor(rc.timeout_ms),
                    .detachable = rc.no_wait and global_ok and config_mod.neverWaits(rc.middleware),
                };
                group.inner.addRouteWith(method, rc.path, consumerHandler, .{ .data = route, .no_wait = route.detachable });
            } else if (rc.websocket) |wc| {
                if (comptime !features.websocket) unreachable;
                const route = try a.create(Route);
                route.* = .{ .engine = e, .id = wc.handler, .ws = .{
                    .max_message_size = cfg.limits.ws_max_message,
                    .compression = wc.compression and features.compression,
                    .close_on_drain = wc.close_on_drain,
                    .allowed_origins = wsOrigins(wc.origins),
                } };
                group.inner.addRouteWith(.get, rc.path, ws.handler, .{ .data = route });
            } else if (rc.webtransport) |wc| {
                if (comptime !features.http3) unreachable;
                const route = try a.create(Route);
                route.* = .{ .engine = e, .id = wc.handler, .wt = .{
                    .accept = .{
                        .allowed_origins = wtOrigins(wc.origins),
                        .close_on_drain = wc.close_on_drain,
                    },
                    .datagram_queue = wc.datagram_queue,
                } };
                // Extended CONNECT is routed as GET.
                group.inner.addRouteWith(.get, rc.path, wt.handler, .{ .data = route });
            }
        }
    }

    /// A WebSocket route's `origins`: none is the same origin only, "*"
    /// any.
    fn wtOrigins(origins: []const []const u8) anole.webtransport.Origins {
        if (origins.len == 0) return .same_origin;
        for (origins) |o| if (std.mem.eql(u8, o, "*")) return .any;
        return .{ .list = origins };
    }

    fn wsOrigins(origins: []const []const u8) anole.websocket.Origins {
        if (origins.len == 0) return .same_origin;
        for (origins) |o| if (std.mem.eql(u8, o, "*")) return .any;
        return .{ .list = origins };
    }

    fn setWhy(e: *Engine, why: []const u8) void {
        const n = @min(why.len, e.start_why.len);
        @memcpy(e.start_why[0..n], why[0..n]);
        e.start_why_len = n;
    }

    fn watchReady(e: *Engine, app: *anole.App) void {
        app.waitReady() catch |err| {
            if (err == error.RouteConflict) if (app.router.conflict) |why| e.setWhy(why);
            e.start_error = err;
            e.started.set(threadedIo());
            return;
        };
        for (app.addresses()) |addr| e.ports.append(gpa, switch (addr) {
            .ip => |ip| ip.getPort(),
            else => 0,
        }) catch {};
        // After the listeners: HTTP/3's UDP port, when one serves it.
        if (app.http3Address()) |q| e.ports.append(gpa, q.getPort()) catch {};
        e.started.set(threadedIo());
    }

    fn failStart(e: *Engine, err: anyerror) void {
        e.start_error = err;
        e.phase.store(.failed, .release);
        e.started.set(threadedIo());
    }

    fn failStartDeinit(e: *Engine, app: *anole.App, err: anyerror) void {
        e.app = null;
        app.deinit();
        e.failStart(err);
    }

    fn setupExecs(e: *Engine, n: usize) !void {
        const per = e.config.limits.max_inflight;
        const queue = if (e.config.limits.queue > 0) e.config.limits.queue else per * 2;
        e.execs = try gpa.alloc(Exec, n);
        var made: usize = 0;
        errdefer {
            for (e.execs[0..made]) |*x| {
                gpa.free(x.slots);
                x.ring.deinit();
            }
            gpa.free(e.execs);
            e.execs = &.{};
        }
        for (e.execs, 0..) |*x, i| {
            const slots = try gpa.alloc(Slot, per);
            errdefer gpa.free(slots);
            x.* = .{ .engine = e, .index = @intCast(i), .slots = slots, .free_head = 0, .ring = try Ring.init(queue) };
            for (x.slots, 0..) |*s, j| s.* = .{ .word = .init(pack(e.first_gen, .free)), .next_free = if (j + 1 < per) @intCast(j + 1) else no_slot };
            made += 1;
            if (e.consumers.items.len > 0) {
                const c = e.consumers.items[i % e.consumers.items.len];
                x.consumer = c;
                try c.execs.append(gpa, x);
            }
        }
    }

    const ctl_closed: u32 = 1 << 31;

    /// The server, for a control call from any thread, or null when there
    /// is none to call into (not serving yet, or `run` returned): then the
    /// run thread may be freeing it. `leave` after.
    fn enter(e: *Engine) ?*anole.App {
        const prev = e.ctl.fetchAdd(1, .acquire);
        if (prev & ctl_closed != 0) {
            _ = e.ctl.fetchSub(1, .release);
            return null;
        }
        const app = e.app.?;
        if (comptime builtin.is_test) if (test_control_hook) |f| f();
        return app;
    }

    fn leave(e: *Engine) void {
        _ = e.ctl.fetchSub(1, .release);
    }

    /// On the run thread once `run` returned: no control call enters from
    /// now on, and those inside have left when this returns, so the server
    /// can be freed. Waits on the runtime (`io`), which a control call
    /// inside may still need.
    fn closeControl(e: *Engine, io: std.Io) void {
        _ = e.ctl.fetchOr(ctl_closed, .acq_rel);
        while (e.ctl.load(.acquire) & ~ctl_closed != 0) {
            io.sleep(.fromMilliseconds(1), .awake) catch std.Thread.yield() catch {};
        }
    }

    pub fn drain(e: *Engine) !void {
        switch (e.phase.load(.acquire)) {
            .running => {},
            .draining, .stopped => return,
            .created, .starting, .failed => return error.State,
        }
        // None: `run` returned (a signal, an error), and the server stops
        // on its own.
        const app = e.enter() orelse return;
        defer e.leave();
        _ = e.phase.cmpxchgStrong(.running, .draining, .acq_rel, .acquire);
        app.stop();
    }

    /// Waits for the stop; false when `timeout_ms` passed first.
    pub fn wait(e: *Engine, timeout_ms: i32) bool {
        if (e.thread == null) return true;
        if (timeout_ms < 0) {
            e.stopped.waitUncancelable(threadedIo());
            return true;
        }
        e.stopped.waitTimeout(threadedIo(), .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } }) catch return e.stopped.isSet();
        return true;
    }

    pub fn reloadCertificates(e: *Engine) !void {
        if (e.phase.load(.acquire) != .running) return error.State;
        const app = e.enter() orelse return error.State;
        defer e.leave();
        try app.reloadCertificates();
    }

    /// Swaps every TLS listener's certificate (HTTP/3 too) for `cert`;
    /// handshakes under way keep the old one. On success later reloads
    /// (and SIGHUP) read from it.
    pub fn setCertificate(e: *Engine, cert: anole.Cert) !void {
        if (e.phase.load(.acquire) != .running) return error.State;
        const app = e.enter() orelse return error.State;
        defer e.leave();
        try app.setCertificate(cert);
    }

    pub fn destroy(e: *Engine) void {
        if (e.thread) |t| {
            if (e.phase.load(.acquire) == .running) e.drain() catch {};
            t.join();
        }
        // The next server's handles start past every one handed out here.
        var last = e.first_gen;
        for (e.execs) |*x| {
            for (x.slots) |*s| last = @max(last, genOf(s.word.load(.acquire)));
            last = @max(last, x.ws.maxGen(), x.wt.maxGen());
        }
        next_first_gen = nextGen(last);
        if (global == e) global = null;
        for (e.execs) |*x| {
            for (x.slots) |*s| {
                s.bytes.deinit(gpa);
                s.headers.deinit(gpa);
                s.trailers.deinit(gpa);
                s.trailer_bytes.deinit(gpa);
                s.in.deinit();
                s.out.deinit();
                if (s.fd >= 0) closeFd(s.fd);
            }
            gpa.free(x.slots);
            x.ring.deinit();
            // Commands nobody ran.
            var cmd = x.inbox.swap(null, .acquire);
            while (cmd) |c| {
                cmd = c.next;
                c.next = null;
                c.run(c, x);
            }
            x.ws.deinit();
            x.grpc.deinit();
            x.wt.deinit();
        }
        gpa.free(e.execs);
        if (comptime features.grpc) grpc.deinit(e);
        for (e.consumers.items) |c| {
            c.deinit();
            gpa.destroy(c);
        }
        e.consumers.deinit(gpa);
        e.ports.deinit(gpa);
        e.arena.deinit();
        gpa.destroy(e);
        // Debug builds: everything the engine allocated is freed by now
        // (the leaks, with where they were made, go to the log).
        if (builtin.mode == .debug) if (debug_gpa.detectLeaks() > 0) log.err("the C ABI engine leaked memory", .{});
    }

    pub fn stats(e: *Engine) abi.Stats {
        var wakes: u64 = 0;
        var rewakes: u64 = 0;
        for (e.consumers.items) |c| {
            wakes += c.wakes.load(.monotonic);
            rewakes += c.rewakes.load(.monotonic);
        }
        return .{
            .size = @sizeOf(abi.Stats),
            .requests = e.requests.load(.monotonic),
            .detached = e.detached_count.load(.monotonic),
            .inflight = e.inflight.load(.monotonic),
            .expired = e.expired_count.load(.monotonic),
            .aborted = e.aborted_count.load(.monotonic),
            .gone = e.gone_count.load(.monotonic),
            .busy = e.busy_count.load(.monotonic),
            .wakes = wakes,
            .rewakes = rewakes,
            .websockets = e.websockets.load(.monotonic),
            .ws_messages_in = e.ws_in.load(.monotonic),
            .ws_messages_out = e.ws_out.load(.monotonic),
            .wt_sessions = e.wt_sessions.load(.monotonic),
            .wt_datagrams_dropped = e.wt_datagrams_dropped.load(.monotonic),
        };
    }

    pub fn gone(e: *Engine) error{Gone} {
        _ = e.gone_count.fetchAdd(1, .monotonic);
        return error.Gone;
    }
};

// ---------------------------------------------------------------------------
// The handler for consumer routes (on executors)

pub fn remoteText(req: *const http.Request, buf: *[64]u8) u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print("{f}", .{req.remote_address}) catch return 0;
    return @intCast(w.end);
}

/// The verified JWT's claims as JSON, when a jwt middleware ran.
pub fn claimsOf(req: *http.Request) []const u8 {
    if (comptime !features.auth) return "";
    const v = anole.auth.claims(req) orelse return "";
    return std.json.Stringify.valueAlloc(req.arena, std.json.Value{ .object = v.claims }, .{}) catch "";
}

/// What a request's body is, before it is handed over.
const BodyPlan = union(enum) {
    /// Whole, inline in the record.
    inline_body: []const u8,
    /// Whole but too big to be inline: it goes into the slot's pipe at once.
    whole: []const u8,
    /// Still coming: `first` is what came so far, and a pump task reads
    /// the rest.
    streamed: struct { first: []const u8, reader: *std.Io.Reader, body: *dusty.RequestBodyReader },
    /// Refused before the handover.
    refused: http.Status,
};

/// Reads up to `inline_body_max + 1` bytes: a body that ends within it is
/// inline. Over HTTP/2 and HTTP/3 on the reader (`whole_only`) the body is
/// all there, so it is read to its end without waiting.
fn planBody(e: *Engine, req: *http.Request, whole_only: bool) !BodyPlan {
    if (req.content_length) |len| {
        if (len == 0) return .{ .inline_body = "" };
        if (len > e.config.limits.body_max) return .{ .refused = .payload_too_large };
    } else if (req.version_major == 1 and req.headers.get("Transfer-Encoding") == null) {
        // HTTP/1.x: no length and no chunked coding is no body.
        return .{ .inline_body = "" };
    }
    if (whole_only or (req.content_length != null and req.content_length.? <= e.inline_body_max)) {
        const whole = (req.body() catch |err| switch (err) {
            error.BodyTooBig => return .{ .refused = .payload_too_large },
            error.Canceled => return error.Canceled,
            else => return .{ .refused = .bad_request },
        }) orelse "";
        return if (whole.len <= e.inline_body_max) .{ .inline_body = whole } else .{ .whole = whole };
    }
    const body = try req.arena.create(dusty.RequestBodyReader);
    body.* = req.reader(&.{}) catch return .{ .refused = .unsupported_media_type };
    const first = try req.arena.alloc(u8, e.inline_body_max + 1);
    const n = body.interface.readSliceShort(first) catch {
        if (body.err) |err| if (err == error.Canceled) return error.Canceled;
        return .{ .refused = .bad_request };
    };
    if (n <= e.inline_body_max) return .{ .inline_body = first[0..n] };
    return .{ .streamed = .{ .first = first[0..n], .reader = &body.interface, .body = body } };
}

fn consumerHandler(req: *http.Request, res: *http.Response) anyerror!void {
    const route: *const Route = @ptrCast(@alignCast(req.route.?.data.?));
    const e = route.engine;
    const io = req.io;
    const xi = placement.currentExecutor(io) orelse return error.InternalServerError;
    const x = &e.execs[xi];
    if (x.consumer == null) {
        res.fail(.service_unavailable, "no consumer");
        return;
    }
    const detach = res.canDetach() and route.detachable;
    const plan = try planBody(e, req, detach);
    switch (plan) {
        .refused => |status| {
            res.fail(status, "");
            return;
        },
        else => {},
    }
    // On a reader a full ring (the consumer far behind) is refused at
    // once: nothing here may wait. Only this executor pushes onto its
    // ring, and nothing below yields before the push, so room now is room
    // then.
    if (detach and x.ring.full()) {
        _ = e.busy_count.fetchAdd(1, .monotonic);
        res.fail(.service_unavailable, "the application is behind");
        return;
    }
    const si = x.alloc() orelse {
        _ = e.busy_count.fetchAdd(1, .monotonic);
        res.fail(.service_unavailable, "too many requests in flight");
        return;
    };
    const s = &x.slots[si];
    // Detached, the request and response move off the reader's stack:
    // the slot keeps the moved ones.
    const d: ?*Detached = if (detach) res.detach(req, .{ .abort = detachedAborted, .ctx = s }) catch |err| {
        x.free_head = si;
        return err;
    } else null;
    const r = if (d) |dd| dd.request else req;
    _ = e.inflight.fetchAdd(1, .monotonic);
    _ = e.requests.fetchAdd(1, .monotonic);
    const gen = genOf(s.word.load(.monotonic));
    s.req = r;
    s.route = route;
    s.flags = if (r.secure) abi.REQ_SECURE else 0;
    if (anole.early_data.isEarly(r)) s.flags |= abi.REQ_EARLY_DATA;
    s.content_length = if (r.content_length) |l| l else std.math.maxInt(u64);
    s.remote_len = remoteText(r, &s.remote);
    s.claims = claimsOf(r);
    s.detached = d;
    s.body = "";
    s.event.reset();
    s.pump_event.reset();
    s.drained.store(true, .monotonic);
    switch (plan) {
        .inline_body => |b| {
            s.body = b;
            s.flags |= abi.REQ_BODY_INLINE;
        },
        .whole => |b| {
            s.flags |= abi.REQ_BODY_STREAM;
            s.in.acquire();
            s.in.open(gen);
            s.in.push(.{ .data = b, .owner = .request }) catch {};
            s.in.ended = true;
            s.in.release();
        },
        .streamed => |st| {
            s.flags |= abi.REQ_BODY_STREAM;
            s.in.acquire();
            s.in.open(gen);
            s.in.push(.{ .data = st.first, .owner = .request }) catch {};
            s.in.release();
        },
        .refused => unreachable,
    }
    s.word.store(pack(gen, .queued), .release);
    x.link(si, route.list, std.Io.Clock.awake.now(io).nanoseconds + e.timeouts[route.list]);

    // Hand over. A full ring (the consumer far behind) is backpressure:
    // wait for room, up to the deadline; on a reader, refuse instead.
    var canceled = false;
    while (!x.ring.push(.{ .handle = x.handleOf(si, gen), .rec = null })) {
        std.debug.assert(d == null);
        if (s.timed_out) {
            x.unlink(si);
            x.release(si);
            _ = e.busy_count.fetchAdd(1, .monotonic);
            res.fail(.service_unavailable, "the application is behind");
            return;
        }
        zio.yield() catch {
            canceled = true;
            break;
        };
    }
    x.consumer.?.wake();

    if (d != null) {
        _ = e.detached_count.fetchAdd(1, .monotonic);
        return;
    }

    // The rest of a streamed body comes through a pump task, while this
    // one waits for the answer.
    var pump: std.Io.Group = .init;
    defer pump.cancel(io);
    switch (plan) {
        .streamed => |st| placement.concurrent(&pump, io, .local, pumpBody, .{ x, si, gen, st.reader, st.body }) catch {
            s.in.acquire();
            s.in.failed = true;
            s.in.release();
        },
        else => {},
    }
    return waitForAnswer(x, si, gen, req, res, canceled);
}

/// The request's task waits for its answer (HTTP/1.1, and requests that
/// could not detach), and writes it.
fn waitForAnswer(x: *Exec, si: u32, gen: u32, req: *http.Request, res: *http.Response, canceled_in: bool) anyerror!void {
    const e = x.engine;
    const io = req.io;
    const s = &x.slots[si];
    var canceled = canceled_in;
    const outcome: enum { done, streaming, expired } = while (true) {
        const w = s.word.load(.acquire);
        std.debug.assert(genOf(w) == gen);
        switch (stateOf(w)) {
            .done => break .done,
            .streaming => break .streaming,
            // Short windows on the consumer thread: let them finish.
            .polling, .responding => {
                zio.yield() catch {
                    canceled = true;
                };
                continue;
            },
            .queued, .out => {
                if (canceled or s.timed_out or s.body_error != null) {
                    if (s.word.cmpxchgStrong(w, pack(gen, .expired), .acq_rel, .acquire) == null) {
                        // The consumer saw it: it hears that it is over.
                        if (stateOf(w) == .out) x.postEvent(.abort, x.handleOf(si, gen));
                        break .expired;
                    }
                    continue;
                }
                // No timer of its own: the capi task sets the event at the
                // deadline.
                s.event.wait(io) catch {
                    canceled = true;
                };
                s.event.reset();
            },
            .free, .expired => unreachable,
        }
    };

    switch (outcome) {
        .expired => {
            const body_error = s.body_error;
            x.release(si);
            if (canceled) {
                _ = e.aborted_count.fetchAdd(1, .monotonic);
                return error.Canceled;
            }
            if (body_error) |status| {
                res.fail(status, "");
                return;
            }
            _ = e.expired_count.fetchAdd(1, .monotonic);
            res.fail(.gateway_timeout, "the application did not answer in time");
        },
        .done => {
            // Woken some other way (deadline, cancel) just as the answer
            // came: the slot is still on the done list, so it may not be
            // reused until the capi task has taken it.
            while (!s.drained.load(.acquire)) zio.yield() catch {
                canceled = true;
            };
            if (canceled) io.recancel();
            x.unlink(si);
            defer x.release(si);
            try applyAnswer(x, si, req, res);
            // A borrowed body must be out before the consumer hears it may
            // let go of it.
            if (s.borrowed != null) try res.write();
        },
        .streaming => {
            while (!s.drained.load(.acquire)) zio.yield() catch {
                canceled = true;
            };
            if (canceled) io.recancel();
            x.unlink(si);
            defer x.release(si);
            return streamAnswer(x, si, gen, req, res);
        },
    }
}

/// The consumer's answer (`done`) into `res`.
fn applyAnswer(x: *Exec, si: u32, req: *http.Request, res: *http.Response) !void {
    const s = &x.slots[si];
    if (s.reply == .release) {
        res.fail(.internal_server_error, "");
        return;
    }
    res.status = http.Status.fromCode(s.status) catch .internal_server_error;
    try applyHeaders(s, req, res);
    switch (s.reply) {
        .respond => {
            if (s.borrowed) |b| {
                // HTTP/2 keeps a reference to a body past `write` (its
                // frames are cut as the writer sends), so there it is
                // copied; elsewhere `write` copies it into the connection.
                if (req.version_major == 2) {
                    res.body = try req.arena.dupe(u8, b);
                } else res.body = b;
            } else res.body = try req.arena.dupe(u8, s.replyBody());
        },
        .fd => {
            if (comptime builtin.os.tag == .windows) unreachable; // respondFd refuses
            const len = s.fd_len;
            res.file = .{
                .handle = .{ .handle = s.fd, .flags = .{ .nonblocking = false } },
                .offset = s.fd_offset,
                .size = std.math.cast(usize, len) orelse return error.FileTooBig,
            };
            s.fd = -1;
        },
        .release => unreachable,
    }
}

fn applyHeaders(s: *const Slot, req: *http.Request, res: *http.Response) !void {
    const bytes = s.bytes.items;
    for (s.headers.items) |h| {
        const name = try req.arena.dupe(u8, bytes[h.name_off..][0..h.name_len]);
        const value = try req.arena.dupe(u8, bytes[h.value_off..][0..h.value_len]);
        res.addHeader(name, value) catch {};
    }
}

/// Sends a streamed answer: the head, then what the consumer writes, until
/// `stream_end` (or `release`, which cuts it short). On a task.
fn streamAnswer(x: *Exec, si: u32, gen: u32, req: *http.Request, res: *http.Response) anyerror!void {
    const s = &x.slots[si];
    const e = x.engine;
    res.status = http.Status.fromCode(s.status) catch .internal_server_error;
    try applyHeaders(s, req, res);
    const buf = try req.arena.alloc(u8, 16 * 1024);
    var w = res.stream(buf) catch |err| {
        streamGone(x, si, gen);
        return err;
    };
    var batch: [16]Chunk = undefined;
    while (true) {
        s.event.reset();
        var n: usize = 0;
        var ended = false;
        var failed = false;
        var writable = false;
        {
            s.out.acquire();
            defer s.out.release();
            while (n < batch.len) {
                const ch = s.out.front() orelse break;
                batch[n] = ch.*;
                n += 1;
                _ = s.out.take(ch.data.len - ch.off);
            }
            ended = s.out.ended and s.out.front() == null;
            failed = s.out.failed;
            if (n == 0 and !ended and !failed) s.out.exec_waiting = true;
            if (s.out.want_event and s.out.bytes <= e.stream_high_water / 2) {
                s.out.want_event = false;
                writable = true;
            }
        }
        if (writable) x.postEvent(.writable, x.handleOf(si, gen));
        s.out.notifyBlocked();
        for (batch[0..n], 0..) |ch, k| {
            w.interface.writeAll(ch.data[ch.off..]) catch |err| {
                for (batch[k..n]) |rest| releaseChunk(x, si, gen, rest);
                streamGone(x, si, gen);
                return w.err orelse err;
            };
            releaseChunk(x, si, gen, ch);
        }
        if (n > 0) {
            w.interface.flush() catch |err| {
                streamGone(x, si, gen);
                return w.err orelse err;
            };
            continue;
        }
        if (failed) {
            streamGone(x, si, gen);
            return res.abort();
        }
        if (ended) {
            const tb = s.trailer_bytes.items;
            for (s.trailers.items) |t| {
                const name = try req.arena.dupe(u8, tb[t.name_off..][0..t.name_len]);
                const value = try req.arena.dupe(u8, tb[t.value_off..][0..t.value_len]);
                res.trailer(name, value) catch {};
            }
            try w.end();
            return;
        }
        s.event.wait(req.io) catch |err| {
            streamGone(x, si, gen);
            _ = e.aborted_count.fetchAdd(1, .monotonic);
            return err;
        };
    }
}

fn releaseChunk(x: *Exec, si: u32, gen: u32, ch: Chunk) void {
    dropChunk(x, si, gen, ch);
}

/// A chunk nobody reads any more: freed, reported sent, or left to the
/// request's arena.
pub fn dropChunk(x: *Exec, si: u32, gen: u32, ch: Chunk) void {
    switch (ch.owner) {
        .pipe => gpa.free(ch.data),
        .consumer => x.postSent(x.handleOf(si, gen), ch.data),
        .request => {},
    }
}

/// A streamed answer that cannot go on (the client left, `release`): the
/// consumer hears it, and its writes get `ANOLE_E_GONE` from here on.
fn streamGone(x: *Exec, si: u32, gen: u32) void {
    const s = &x.slots[si];
    s.out.acquire();
    const failed = s.out.failed;
    s.out.release();
    x.closePipe(&s.out, gen, si);
    if (!failed) x.postEvent(.abort, x.handleOf(si, gen));
}

/// Reads the rest of a request body into the slot's pipe, `limits.body_max`
/// at most, holding back while the consumer is behind. A task beside the
/// request's.
fn pumpBody(x: *Exec, si: u32, gen: u32, reader: *std.Io.Reader, body: *dusty.RequestBodyReader) std.Io.Cancelable!void {
    const e = x.engine;
    const s = &x.slots[si];
    const high: usize = @max(64 * 1024, e.inline_body_max);
    var total: u64 = s.in.bytes;
    while (true) {
        // Room first.
        while (true) {
            s.pump_event.reset();
            s.in.acquire();
            const live = s.in.live(gen);
            const room = s.in.bytes < high;
            if (live and !room) s.in.exec_waiting = true;
            s.in.release();
            if (!live) return;
            if (room) break;
            try s.pump_event.wait(e.io);
        }
        const chunk = gpa.alloc(u8, 16 * 1024) catch return failBody(x, si, gen, .internal_server_error);
        const n = reader.readSliceShort(chunk) catch {
            gpa.free(chunk);
            if (body.err) |err| if (err == error.Canceled) return error.Canceled;
            return failBody(x, si, gen, .bad_request);
        };
        total += n;
        if (total > e.config.limits.body_max) {
            gpa.free(chunk);
            return failBody(x, si, gen, .payload_too_large);
        }
        var notify = false;
        s.in.acquire();
        if (!s.in.live(gen)) {
            s.in.release();
            gpa.free(chunk);
            return;
        }
        const eof = n < chunk.len;
        // Freed by length later: exactly what was read.
        const data: []u8 = if (eof) blk: {
            const exact = gpa.dupe(u8, chunk[0..n]) catch {
                gpa.free(chunk);
                s.in.release();
                return failBody(x, si, gen, .internal_server_error);
            };
            gpa.free(chunk);
            break :blk exact;
        } else chunk;
        if (n > 0) {
            s.in.push(.{ .data = data, .owner = .pipe }) catch {
                gpa.free(data);
                s.in.release();
                return failBody(x, si, gen, .internal_server_error);
            };
        } else gpa.free(data);
        if (eof) s.in.ended = true;
        if (s.in.want_event) {
            s.in.want_event = false;
            notify = true;
        }
        s.in.release();
        s.in.notifyBlocked();
        if (notify) x.postEvent(.body, x.handleOf(si, gen));
        if (eof) return;
    }
}

/// The request body failed: a waiting request answers `status` (if the
/// consumer has not answered yet), and the consumer's reads end.
fn failBody(x: *Exec, si: u32, gen: u32, status: http.Status) void {
    const s = &x.slots[si];
    s.in.acquire();
    const live = s.in.live(gen);
    if (live) s.in.failed = true;
    const notify = live and s.in.want_event;
    s.in.release();
    if (!live) return;
    s.in.notifyBlocked();
    if (notify) x.postEvent(.body, x.handleOf(si, gen));
    if (genOf(s.word.load(.acquire)) == gen) {
        s.body_error = status;
        s.event.set(x.engine.io);
    }
}

// ---------------------------------------------------------------------------
// Detached requests (HTTP/2, HTTP/3)

/// The engine let go of a detached request (its stream or connection
/// ended). On the request's executor; afterwards nothing here may touch
/// the request.
pub fn detachedAborted(ctx: *anyopaque) void {
    const s: *Slot = @ptrCast(@alignCast(ctx));
    const e = global.?;
    const x = execOfSlot(e, s);
    const si: u32 = @intCast(s - x.slots.ptr);
    s.detached = null;
    _ = e.aborted_count.fetchAdd(1, .monotonic);
    while (true) {
        const w = s.word.load(.acquire);
        const gen = genOf(w);
        switch (stateOf(w)) {
            .queued, .out => {
                if (s.word.cmpxchgStrong(w, pack(gen, .expired), .acq_rel, .acquire) != null) continue;
                if (stateOf(w) == .out) x.postEvent(.abort, x.handleOf(si, gen));
                x.release(si);
                return;
            },
            // `poll` is reading the request, which is about to go: wait
            // for it (a copy, on the consumer's thread).
            .polling => std.atomic.spinLoopHint(),
            // The consumer is answering, or has: the capi task frees it.
            // The request body may live in the request's memory, which
            // goes once this returns: reads of it end now.
            .responding, .done, .streaming => {
                s.orphan = true;
                x.closePipe(&s.in, gen, si);
                return;
            },
            .free, .expired => return,
        }
    }
}

fn execOfSlot(e: *Engine, s: *Slot) *Exec {
    for (e.execs) |*x| {
        const lo = @intFromPtr(x.slots.ptr);
        if (@intFromPtr(s) >= lo and @intFromPtr(s) < lo + x.slots.len * @sizeOf(Slot)) return x;
    }
    unreachable;
}

/// An answered detached request: written now, or on a task when it needs
/// one (a stream, a file).
fn finishDetached(x: *Exec, si: u32) void {
    const s = &x.slots[si];
    const d = s.detached.?;
    const w = s.word.load(.acquire);
    const gen = genOf(w);
    x.unlink(si);
    if (stateOf(w) == .streaming or (stateOf(w) == .done and s.reply == .fd)) {
        const spawned = if (d.attach()) |group| placement.concurrent(group, x.engine.io, .local, attachedTask, .{ x, si, gen }) else error.ConnectionClosed;
        spawned catch {
            // The connection is going (or no task could start): a stream
            // the consumer is writing hears it is over.
            if (stateOf(w) == .streaming) x.postEvent(.abort, x.handleOf(si, gen));
            x.closePipe(&s.in, gen, si);
            d.finish(error.ConnectionResetByPeer);
            x.release(si);
        };
        return;
    }
    s.detached = null;
    const result = applyAnswer(x, si, d.request, d.response);
    // `finish` lets the request's memory go, which a streamed request body
    // may still be read from: the reads end first.
    x.closePipe(&s.in, gen, si);
    d.finish(result);
    x.release(si);
}

/// A detached answer that needs a task: a streamed body or a file.
fn attachedTask(x: *Exec, si: u32, gen: u32) std.Io.Cancelable!void {
    const s = &x.slots[si];
    const d = s.detached.?;
    s.detached = null;
    d.enter();
    const result: anyerror!void = if (stateOf(s.word.load(.acquire)) == .streaming)
        streamAnswer(x, si, gen, d.request, d.response)
    else
        applyAnswer(x, si, d.request, d.response);
    x.closePipe(&s.in, gen, si);
    d.finish(result);
    x.release(si);
    if (result) |_| {} else |err| if (err == error.Canceled) return error.Canceled;
}

/// A detached request past its deadline: 504 now. The consumer, if it saw
/// it, hears it is over.
fn expireDetached(x: *Exec, si: u32, w: u64) void {
    const s = &x.slots[si];
    const gen = genOf(w);
    if (s.word.cmpxchgStrong(w, pack(gen, .expired), .acq_rel, .acquire) != null) return;
    if (stateOf(w) == .out) x.postEvent(.abort, x.handleOf(si, gen));
    _ = x.engine.expired_count.fetchAdd(1, .monotonic);
    if (s.detached) |d| {
        s.detached = null;
        x.closePipe(&s.in, gen, si);
        d.response.fail(.gateway_timeout, "the application did not answer in time");
        d.finish({});
    }
    x.release(si);
}

// ---------------------------------------------------------------------------
// The capi task: one per executor.

/// Hands answers to their requests, runs commands, enforces deadlines and
/// rings lost doorbells again.
fn capiTask(e: *Engine, x: *Exec) std.Io.Cancelable!void {
    const io = e.io;
    while (true) {
        x.kick.reset();
        // Answers: wake their tasks (local wakes, no syscalls), or finish
        // detached requests here.
        var list = x.done_head.swap(no_slot, .acquire);
        // Oldest first.
        var rev: u32 = no_slot;
        while (list != no_slot) {
            const s = &x.slots[list];
            const next = s.next_done;
            s.next_done = rev;
            rev = list;
            list = next;
        }
        while (rev != no_slot) {
            const si = rev;
            const s = &x.slots[si];
            rev = s.next_done;
            s.drained.store(true, .release);
            if (s.orphan) {
                const w = s.word.load(.acquire);
                if (stateOf(w) == .streaming) x.postEvent(.abort, x.handleOf(si, genOf(w)));
                x.release(si);
            } else if (s.detached != null) {
                if (comptime features.grpc) if (s.kind.load(.monotonic) == @backingInt(Handle.Kind.grpc_call)) {
                    grpc.finishDetached(x, si);
                    continue;
                };
                finishDetached(x, si);
            } else s.event.set(io);
        }
        // Commands.
        var cmds = x.inbox.swap(null, .acquire);
        var fifo: ?*Command = null;
        while (cmds) |c| {
            cmds = c.next;
            c.next = fifo;
            fifo = c;
        }
        while (fifo) |c| {
            fifo = c.next;
            c.next = null;
            c.run(c, x);
        }
        // Deadlines.
        const now = std.Io.Clock.awake.now(io).nanoseconds;
        var until: i96 = now + e.timeouts[0];
        var any_out = false;
        for (x.lists[0..e.ntimeouts]) |*l| {
            while (l.head != no_slot) {
                const si = l.head;
                const s = &x.slots[si];
                if (s.deadline > now) break;
                const w = s.word.load(.acquire);
                switch (stateOf(w)) {
                    .queued, .out => {
                        if (s.orphan) {
                            if (s.word.cmpxchgStrong(w, pack(genOf(w), .expired), .acq_rel, .acquire) != null) continue;
                            if (stateOf(w) == .out) x.postEvent(.abort, x.handleOf(si, genOf(w)));
                            x.release(si);
                        } else if (s.detached != null) {
                            expireDetached(x, si, w);
                        } else {
                            x.unlink(si);
                            s.timed_out = true;
                            s.event.set(io);
                        }
                    },
                    // The consumer is in a call on it: look again shortly.
                    else => {
                        until = @min(until, now + std.time.ns_per_ms);
                        break;
                    },
                }
            }
            if (l.head != no_slot) {
                until = @min(until, x.slots[l.head].deadline);
                any_out = true;
            }
        }
        // gRPC calls' deadlines (each call's own).
        if (comptime features.grpc) if (grpc.sweep(x, now)) |next| {
            until = @min(until, next);
            any_out = true;
        };
        // Requests out: also watch for a lost doorbell, every rewake_ms.
        if (e.rewake > 0 and (any_out or !x.ring.isEmpty())) if (x.consumer) |c| {
            if (!x.ring.isEmpty() and c.awake.load(.acquire) and now - c.last_poll.load(.monotonic) > e.rewake) c.rewake();
            until = @min(until, now + e.rewake);
        };
        x.idle = !any_out and x.ring.isEmpty();
        x.kick.waitTimeout(io, .{ .duration = .{ .raw = .{ .nanoseconds = @max(until - now, 0) }, .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => return error.Canceled,
        };
    }
}

// ---------------------------------------------------------------------------
// Consumer side: poll (on the consumer's thread)

fn methodCode(m: http.Method) u8 {
    return switch (m) {
        .get => 1,
        .head => 2,
        .post => 3,
        .put => 4,
        .delete => 5,
        .connect => 6,
        .options => 7,
        .trace => 8,
        .patch => 9,
        else => 0,
    };
}

/// What a request record is built from: a slot's request (`poll`), or the
/// upgrade request of a WebSocket (`ws_open`).
pub const Head = struct {
    req: *const http.Request,
    route_id: u32,
    body: []const u8 = "",
    flags: u16 = 0,
    content_length: u64 = std.math.maxInt(u64),
    remote: []const u8 = "",
    claims: []const u8 = "",

    pub fn size(h: Head) usize {
        const req = h.req;
        var n: usize = @sizeOf(abi.RequestEvent);
        const nh = req.headers.len;
        n += nh * 2 * @sizeOf(abi.Span);
        n += req.params.count() * 2 * @sizeOf(abi.Span);
        n += methodName(req).len + req.url.len + h.body.len + h.remote.len + req.listener.name.len + req.id.len + h.claims.len;
        for (req.headers.keys[0..nh], req.headers.values[0..nh]) |k, v| n += k.len + v.len;
        var it = req.params.map.iterator();
        while (it.next()) |kv| n += kv.key_ptr.len + kv.value_ptr.len;
        // Mutual TLS: the client's certificate last, a u32 length then the
        // DER, 4-aligned.
        if (req.peerCertificate()) |der| n = std.mem.alignForward(usize, n, 4) + 4 + der.len;
        return abi.alignUp(n);
    }

    /// Writes the record into `out` (exactly `size()` bytes).
    pub fn encode(h: Head, typ: abi.EventType, handle: u64, out: []u8) usize {
        const req = h.req;
        const size_ = out.len;
        const nh = req.headers.len;
        const np = req.params.count();
        const spans: [*]align(1) abi.Span = @ptrCast(out[@sizeOf(abi.RequestEvent)..].ptr);
        var pos: usize = @sizeOf(abi.RequestEvent) + (nh + np) * 2 * @sizeOf(abi.Span);
        const put = struct {
            fn f(buf: []u8, p: *usize, s: []const u8, lower: bool) abi.Span {
                const at = p.*;
                if (lower) {
                    for (s, buf[at..][0..s.len]) |ch, *d| d.* = std.ascii.toLower(ch);
                } else @memcpy(buf[at..][0..s.len], s);
                p.* += s.len;
                return .{ .off = @intCast(at), .len = @intCast(s.len) };
            }
        }.f;
        const url = req.url;
        const q = std.mem.indexOfScalar(u8, url, '?');
        const method_name = put(out, &pos, methodName(req), false);
        const url_span = put(out, &pos, url, false);
        const path: abi.Span = .{ .off = url_span.off, .len = @intCast(q orelse url.len) };
        const query: abi.Span = if (q) |i| .{ .off = url_span.off + @as(u32, @intCast(i + 1)), .len = @intCast(url.len - i - 1) } else .{};
        var k: usize = 0;
        for (req.headers.keys[0..nh], req.headers.values[0..nh]) |hk, hv| {
            spans[k] = put(out, &pos, hk, true);
            spans[k + 1] = put(out, &pos, hv, false);
            k += 2;
        }
        var it = req.params.map.iterator();
        while (it.next()) |kv| {
            spans[k] = put(out, &pos, kv.key_ptr.*, false);
            spans[k + 1] = put(out, &pos, kv.value_ptr.*, false);
            k += 2;
        }
        const body = put(out, &pos, h.body, false);
        const remote = put(out, &pos, h.remote, false);
        const listener = put(out, &pos, req.listener.name, false);
        const id = put(out, &pos, req.id, false);
        const claims = put(out, &pos, h.claims, false);
        var peer_cert: u32 = 0;
        if (req.peerCertificate()) |der| {
            const at = std.mem.alignForward(usize, pos, 4);
            @memset(out[pos..at], 0);
            std.mem.writeInt(u32, out[at..][0..4], @intCast(der.len), .little);
            @memcpy(out[at + 4 ..][0..der.len], der);
            pos = at + 4 + der.len;
            peer_cert = @intCast(at);
        }
        std.debug.assert(abi.alignUp(pos) == size_);
        @memset(out[pos..size_], 0);
        const rec: *align(1) abi.RequestEvent = @ptrCast(out.ptr);
        rec.* = .{
            .ev = .{ .type = @backingInt(typ), .len = @intCast(size_), .handle = handle },
            .route_id = h.route_id,
            .method = methodCode(req.method),
            .version = req.version_major * 10 + req.version_minor,
            .flags = h.flags | if (peer_cert != 0) abi.REQ_PEER_CERT else 0,
            .method_name = method_name,
            .path = path,
            .query = query,
            .body = body,
            .remote_addr = remote,
            .listener = listener,
            .id = id,
            .claims = claims,
            .nheaders = @intCast(nh),
            .nparams = @intCast(np),
            .peer_cert = peer_cert,
            .content_length = h.content_length,
        };
        return size_;
    }

    fn methodName(req: *const http.Request) []const u8 {
        // An extended CONNECT is routed as GET; the record says GET too.
        return req.method.name();
    }
};

fn headOf(s: *const Slot) Head {
    return .{
        .req = s.req,
        .route_id = s.route.id,
        .body = s.body,
        .flags = s.flags,
        .content_length = s.content_length,
        .remote = s.remote[0..s.remote_len],
        .claims = s.claims,
    };
}

pub const PollError = error{TooBig};

/// Drains up to `out.len` bytes of events (one event for a shared
/// consumer). 0: nothing pending, and the doorbell is armed again (unless
/// `!arm`).
pub fn poll(c: *Consumer, out: []u8, arm: bool) PollError!usize {
    if (c.shared) {
        c.poll_lock.lockUncancelable(threadedIo());
        defer c.poll_lock.unlock(threadedIo());
        return pollLocked(c, out, arm, true);
    }
    return pollLocked(c, out, arm, false);
}

fn pollLocked(c: *Consumer, out: []u8, arm: bool, one: bool) PollError!usize {
    const e = c.engine;
    if (e.phase.load(.acquire) != .created and e.phase.load(.acquire) != .starting)
        c.last_poll.store(@intCast(std.Io.Clock.awake.now(e.io).nanoseconds), .monotonic);
    var pos: usize = 0;
    var rechecked = false;
    outer: while (true) {
        var progressed = false;
        var i: usize = 0;
        while (i < c.execs.items.len) : (i += 1) {
            const x = c.execs.items[(c.next_exec + i) % c.execs.items.len];
            while (x.ring.peek()) |entry| {
                if (one and pos > 0) break :outer;
                if (entry.rec) |rec| {
                    const ev: *const abi.Event = @ptrCast(rec);
                    if (ev.len > out.len - pos) {
                        if (pos == 0) return error.TooBig;
                        c.next_exec = (c.next_exec + i) % c.execs.items.len;
                        break :outer;
                    }
                    @memcpy(out[pos..][0..ev.len], rec[0..ev.len]);
                    pos += ev.len;
                    const len = ev.len;
                    freeRecord(rec);
                    x.ring.pop();
                    _ = x.record_bytes.fetchSub(len, .release);
                    progressed = true;
                    continue;
                }
                const h = Handle.decode(entry.handle);
                const s = &x.slots[h.slot];
                const queued = pack(h.gen, .queued);
                if (s.word.cmpxchgStrong(queued, pack(h.gen, .polling), .acquire, .monotonic) != null) {
                    // Expired (or reused since): skip it.
                    x.ring.pop();
                    continue;
                }
                const is_grpc = features.grpc and h.kind == .grpc_call;
                const size = if (is_grpc) grpc.recordSize(s) else headOf(s).size();
                if (size > out.len - pos) {
                    s.word.store(queued, .release);
                    if (pos == 0) return error.TooBig;
                    c.next_exec = (c.next_exec + i) % c.execs.items.len;
                    break :outer;
                }
                pos += if (is_grpc) grpc.encodeRecord(s, entry.handle, out[pos..][0..size]) else headOf(s).encode(.request, entry.handle, out[pos..][0..size]);
                s.word.store(pack(h.gen, .out), .release);
                x.ring.pop();
                progressed = true;
            }
        }
        c.next_exec = (c.next_exec + 1) % @max(c.execs.items.len, 1);
        if (pos > 0 or progressed) break;
        if (e.phase.load(.acquire) == .stopped and !c.stopped_sent) {
            if (out.len < @sizeOf(abi.Event)) return error.TooBig;
            const hdr: *align(1) abi.Event = @ptrCast(out.ptr);
            hdr.* = .{ .type = @backingInt(abi.EventType.stopped), .len = @sizeOf(abi.Event), .handle = 0 };
            c.stopped_sent = true;
            return @sizeOf(abi.Event);
        }
        if (rechecked or !arm) break;
        // Nothing: arm the doorbell, then look once more (a producer that
        // pushed before seeing `awake` false is found here).
        c.drainFd();
        c.awake.store(false, .seq_cst);
        rechecked = true;
        var any = false;
        for (c.execs.items) |x| if (!x.ring.isEmpty()) {
            any = true;
        };
        if (!any) break;
        // Found work: take the doorbell back (a wake may still come; it is
        // harmless).
        c.awake.store(true, .seq_cst);
        continue :outer;
    }
    return pos;
}

/// `poll`, blocking up to `timeout_ms` (< 0: for ever) for an event.
pub fn pollWait(c: *Consumer, out: []u8, timeout_ms: i32) PollError!usize {
    const tio = threadedIo();
    const deadline: ?std.Io.Clock.Timestamp = if (timeout_ms < 0) null else std.Io.Clock.Timestamp.now(tio, .awake).addDuration(.{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake });
    while (true) {
        const seq = c.bell.load(.acquire);
        const n = try poll(c, out, true);
        if (n > 0) return n;
        if (c.stopped_sent) return 0;
        _ = c.waiters.fetchAdd(1, .acq_rel);
        defer _ = c.waiters.fetchSub(1, .acq_rel);
        if (deadline) |d| {
            const now = std.Io.Clock.Timestamp.now(tio, .awake);
            if (now.compare(.gte, d)) return 0;
            tio.futexWaitTimeout(u32, &c.bell.raw, seq, .{ .deadline = d }) catch {};
        } else tio.futexWaitUncancelable(u32, &c.bell.raw, seq);
    }
}

// ---------------------------------------------------------------------------
// Consumer side: answers (any thread)

pub const AnswerError = error{ Gone, Invalid, OutOfMemory, Unsupported, Timeout, Again, State, TooBig };

pub const CHeader = abi.Header;

fn slotOf(e: *Engine, hv: u64) ?struct { *Exec, *Slot, Handle } {
    return slotOfKind(e, hv, .request);
}

/// The slot a handle of `kind` names, if it could be one: the generation
/// is the caller's to check (a stale handle finds its slot moved on).
pub fn slotOfKind(e: *Engine, hv: u64, kind: Handle.Kind) ?struct { *Exec, *Slot, Handle } {
    const h = Handle.decode(hv);
    if (h.gen == 0 or h.kind != kind or h.exec >= e.execs.len) return null;
    const x = &e.execs[h.exec];
    if (h.slot >= x.slots.len) return null;
    const s = &x.slots[h.slot];
    if (s.kind.load(.acquire) != @backingInt(kind)) return null;
    return .{ x, s, h };
}

/// Claims slot `hv` for an answer: `out` to `responding`.
fn claim(e: *Engine, hv: u64) error{Gone}!struct { *Exec, *Slot, Handle } {
    const x, const s, const h = slotOf(e, hv) orelse return e.gone();
    if (s.word.cmpxchgStrong(pack(h.gen, .out), pack(h.gen, .responding), .acquire, .monotonic) != null) return e.gone();
    return .{ x, s, h };
}

/// Hands slot `si` to its executor (`done` or `streaming`).
pub fn handBack(x: *Exec, s: *Slot, h: Handle, state: SlotState) void {
    s.drained.store(false, .monotonic);
    s.word.store(pack(h.gen, state), .release);
    // Onto the executor's done list; only the push that finds it empty
    // wakes the capi task (one remote wake per burst).
    var old = x.done_head.load(.monotonic);
    while (true) {
        s.next_done = old;
        old = x.done_head.cmpxchgWeak(old, h.slot, .release, .monotonic) orelse break;
    }
    if (old == no_slot) x.kick.set(x.engine.io);
}

pub fn checkHeaders(headers: []const CHeader) error{Invalid}!usize {
    var total: usize = 0;
    for (headers) |hd| {
        total += hd.name.len + hd.value.len;
        dusty.validateHeaderName(hd.name.slice()) catch return error.Invalid;
        // Framing fields are the server's to write (`Response.header`
        // refuses them): refused here rather than dropped later.
        if (dusty.isReservedHeader(hd.name.slice())) return error.Invalid;
        dusty.validateHeaderValue(hd.value.slice()) catch return error.Invalid;
    }
    return total;
}

pub fn storeHeaders(list: *std.ArrayList(ReplyHeader), bytes: *std.ArrayList(u8), headers: []const CHeader, extra: usize) !void {
    var total = extra;
    for (headers) |hd| total += hd.name.len + hd.value.len;
    if (total > std.math.maxInt(u32)) return error.Invalid;
    bytes.clearRetainingCapacity();
    list.clearRetainingCapacity();
    try bytes.ensureTotalCapacity(gpa, total);
    try list.ensureTotalCapacity(gpa, headers.len);
    for (headers) |hd| {
        const no: u32 = @intCast(bytes.items.len);
        bytes.appendSliceAssumeCapacity(hd.name.slice());
        const vo: u32 = @intCast(bytes.items.len);
        bytes.appendSliceAssumeCapacity(hd.value.slice());
        list.appendAssumeCapacity(.{ .name_off = no, .name_len = @intCast(hd.name.len), .value_off = vo, .value_len = @intCast(hd.value.len) });
    }
}

fn checkStatus(status: u16) error{Invalid}!void {
    _ = http.Status.fromCode(status) catch return error.Invalid;
}

pub fn respond(e: *Engine, hv: u64, status: u16, headers: []const CHeader, body: []const u8, borrow: bool) AnswerError!void {
    try checkStatus(status);
    _ = try checkHeaders(headers);
    const x, const s, const h = try claim(e, hv);
    errdefer s.word.store(pack(h.gen, .out), .release);
    try storeHeaders(&s.headers, &s.bytes, headers, if (borrow) 0 else body.len);
    s.body_off = @intCast(s.bytes.items.len);
    if (borrow) {
        s.borrowed = body;
        s.body_len = 0;
    } else {
        if (body.len > std.math.maxInt(u32)) return error.Invalid;
        s.borrowed = null;
        s.body_len = @intCast(body.len);
        s.bytes.appendSliceAssumeCapacity(body);
    }
    s.reply = .respond;
    s.status = status;
    handBack(x, s, h, .done);
}

pub fn release(e: *Engine, hv: u64) AnswerError!void {
    const x, const s, const h = slotOf(e, hv) orelse return e.gone();
    // A stream under way: cut it short.
    if (s.out.gen == h.gen) {
        s.out.acquire();
        if (s.out.live(h.gen) and !s.out.ended) {
            s.out.failed = true;
            const wake = s.out.exec_waiting;
            s.out.exec_waiting = false;
            s.out.release();
            if (wake) s.event.set(e.io);
            return;
        }
        s.out.release();
    }
    if (s.word.cmpxchgStrong(pack(h.gen, .out), pack(h.gen, .responding), .acquire, .monotonic) != null) return e.gone();
    s.reply = .release;
    s.headers.clearRetainingCapacity();
    s.bytes.clearRetainingCapacity();
    handBack(x, s, h, .done);
}

pub fn respondFd(e: *Engine, hv: u64, status: u16, headers: []const CHeader, fd: c_int, offset: u64, len: u64) AnswerError!void {
    if (comptime builtin.os.tag == .windows) return error.Unsupported;
    try checkStatus(status);
    _ = try checkHeaders(headers);
    // A regular file, and how much of it.
    if (fd < 0) return error.Invalid;
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    const st = file.stat(threadedIo()) catch return error.Invalid;
    if (st.kind != .file) return error.Invalid;
    const size: u64 = st.size;
    if (offset > size) return error.Invalid;
    const n = if (len == 0) size - offset else len;
    if (n > size - offset) return error.Invalid;
    const x, const s, const h = try claim(e, hv);
    errdefer s.word.store(pack(h.gen, .out), .release);
    const dup = std.c.fcntl(fd, std.c.F.DUPFD_CLOEXEC, @as(c_int, 0));
    if (dup < 0) return error.Invalid;
    errdefer closeFd(dup);
    try storeHeaders(&s.headers, &s.bytes, headers, 0);
    s.reply = .fd;
    s.status = status;
    s.fd = dup;
    s.fd_offset = offset;
    s.fd_len = n;
    handBack(x, s, h, .done);
}

pub fn streamStart(e: *Engine, hv: u64, status: u16, headers: []const CHeader) AnswerError!void {
    try checkStatus(status);
    _ = try checkHeaders(headers);
    const x, const s, const h = try claim(e, hv);
    errdefer s.word.store(pack(h.gen, .out), .release);
    try storeHeaders(&s.headers, &s.bytes, headers, 0);
    s.trailers.clearRetainingCapacity();
    s.trailer_bytes.clearRetainingCapacity();
    s.status = status;
    s.out.acquire();
    s.out.open(h.gen);
    s.out.release();
    handBack(x, s, h, .streaming);
}

/// `ANOLE_BUSY` is `true`.
pub fn streamWrite(e: *Engine, hv: u64, data: []const u8, borrow: bool) AnswerError!bool {
    _, const s, const h = slotOf(e, hv) orelse return e.gone();
    if (data.len == 0) return false;
    const owned: ?[]u8 = if (borrow) null else try gpa.dupe(u8, data);
    errdefer if (owned) |o| gpa.free(o);
    s.out.acquire();
    if (!s.out.live(h.gen) or s.out.ended or s.out.failed) {
        s.out.release();
        return e.gone();
    }
    s.out.push(.{ .data = owned orelse data, .owner = if (borrow) .consumer else .pipe }) catch |err| {
        s.out.release();
        return err;
    };
    const busy = s.out.bytes > e.stream_high_water;
    if (busy) s.out.want_event = true;
    const wake = s.out.exec_waiting;
    s.out.exec_waiting = false;
    s.out.release();
    if (wake) s.event.set(e.io);
    return busy;
}

/// Waits (a blocking consumer thread) for the stream to fall below the
/// high-water mark, then writes `data` (copied).
pub fn streamWriteWait(e: *Engine, hv: u64, data: []const u8, timeout_ms: i32) AnswerError!void {
    _, const s, const h = slotOf(e, hv) orelse return e.gone();
    const tio = threadedIo();
    const deadline: ?std.Io.Clock.Timestamp = if (timeout_ms < 0) null else std.Io.Clock.Timestamp.now(tio, .awake).addDuration(.{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake });
    while (true) {
        const seq = s.out.seq.load(.acquire);
        s.out.acquire();
        const live = s.out.live(h.gen) and !s.out.ended and !s.out.failed;
        const room = s.out.bytes <= e.stream_high_water;
        s.out.release();
        if (!live) return e.gone();
        if (room) break;
        _ = s.out.blocked.fetchAdd(1, .acq_rel);
        defer _ = s.out.blocked.fetchSub(1, .acq_rel);
        if (deadline) |d| {
            if (std.Io.Clock.Timestamp.now(tio, .awake).compare(.gte, d)) return error.Timeout;
            tio.futexWaitTimeout(u32, &s.out.seq.raw, seq, .{ .deadline = d }) catch {};
        } else tio.futexWaitUncancelable(u32, &s.out.seq.raw, seq);
    }
    _ = try streamWrite(e, hv, data, false);
}

pub fn streamEnd(e: *Engine, hv: u64, trailers: []const CHeader) AnswerError!void {
    _ = try checkHeaders(trailers);
    _, const s, const h = slotOf(e, hv) orelse return e.gone();
    s.out.acquire();
    if (!s.out.live(h.gen) or s.out.ended or s.out.failed) {
        s.out.release();
        return e.gone();
    }
    storeHeaders(&s.trailers, &s.trailer_bytes, trailers, 0) catch |err| {
        s.out.release();
        return err;
    };
    s.out.ended = true;
    const wake = s.out.exec_waiting;
    s.out.exec_waiting = false;
    s.out.release();
    if (wake) s.event.set(e.io);
}

/// Copies request body bytes out; 0 at the end. `error.Again` with
/// `timeout_ms` 0 and nothing there (an `ANOLE_EV_BODY` follows).
pub fn reqRead(e: *Engine, hv: u64, out: []u8, timeout_ms: i32) AnswerError!usize {
    const x, const s, const h = slotOf(e, hv) orelse return e.gone();
    const tio = threadedIo();
    const deadline: ?std.Io.Clock.Timestamp = if (timeout_ms <= 0) null else std.Io.Clock.Timestamp.now(tio, .awake).addDuration(.{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake });
    while (true) {
        const seq = s.in.seq.load(.acquire);
        s.in.acquire();
        const word = s.word.load(.acquire);
        const state = stateOf(word);
        // Answered (`done`) is gone too: the body may live in the
        // request's memory, which goes with the answer.
        const mine = genOf(word) == h.gen and state != .free and state != .expired and state != .done;
        if (!mine) {
            s.in.release();
            return e.gone();
        }
        if (!s.in.live(h.gen)) {
            // No streamed body: an inline one (or none) reads as ended.
            s.in.release();
            return 0;
        }
        if (s.in.failed) {
            s.in.release();
            return e.gone();
        }
        const n = s.in.read(out);
        const ended = s.in.ended and s.in.front() == null;
        const wake = s.in.exec_waiting and n > 0;
        if (wake) s.in.exec_waiting = false;
        if (n == 0 and !ended and timeout_ms == 0) s.in.want_event = true;
        s.in.release();
        if (wake) s.pump_event.set(e.io);
        if (n > 0) return n;
        if (ended) return 0;
        _ = x;
        if (timeout_ms == 0) return error.Again;
        _ = s.in.blocked.fetchAdd(1, .acq_rel);
        defer _ = s.in.blocked.fetchSub(1, .acq_rel);
        if (deadline) |d| {
            if (std.Io.Clock.Timestamp.now(tio, .awake).compare(.gte, d)) return error.Timeout;
            tio.futexWaitTimeout(u32, &s.in.seq.raw, seq, .{ .deadline = d }) catch {};
        } else tio.futexWaitUncancelable(u32, &s.in.seq.raw, seq);
    }
}

test {
    _ = config_mod;
    _ = @import("engine_test.zig");
    if (features.grpc) _ = grpc;
}
