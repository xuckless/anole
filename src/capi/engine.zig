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
const server_mod = @import("../server.zig");
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
        /// A database transaction (an `anole_handle_release` rolls it back).
        db_tx = 6,
        /// Reserved for a per-query handle.
        db_query = 7,
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

const Reply = enum { respond, fail, abort, fd, ws_accept };

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
    /// The `ANOLE_EV_SENT` record that goes with `borrowed`, allocated by
    /// the call that borrowed (so a full queue or a failed allocation can
    /// never lose it); posted when the slot is released.
    borrowed_sent: ?[]align(8) u8 = null,
    /// `anole_req_fail`: the detail text is in `bytes` after the headers.
    fail_len: u32 = 0,
    /// A file to send (`anole_req_respond_fd`; POSIX only).
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
    /// `destroy` on a server not drained: this request is answered 503 and
    /// the consumer hears nothing more.
    abandoned: bool = false,
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
    /// A WebSocket handshake the consumer decides (ANOLE_EV_WS_UPGRADE),
    /// with the WebSocket slot reserved for it (executor-local, set before
    /// the `queued` store and read by `poll` after its CAS).
    ws_upgrade: bool = false,
    ws_slot: u32 = no_slot,
    /// `anole_ws_accept`: the extra headers are stored as a response's are,
    /// the accepted subprotocol's bytes follow them in `bytes`.
    subprotocol_off: u32 = 0,
    subprotocol_len: u32 = 0,
    /// Database queries and transactions that serve this request or call
    /// (`anole_db_options.req`): cut when it ends unanswered.
    db_tied: ?*db.Tied = null,
    /// The consumer answered it (any `handBack`): what is tied to it is then
    /// left to finish.
    answered: std.atomic.Value(bool) = .init(false),

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
    /// Producer: only the ring's executor (SPSC). False when full.
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
        return r.tail.raw - r.head.load(.seq_cst) == r.buf.len;
    }
    /// Consumer.
    fn peek(r: *Ring) ?Entry {
        const head = r.head.raw;
        if (head == r.tail.load(.seq_cst)) return null;
        return r.buf[head & r.mask];
    }
    fn pop(r: *Ring) void {
        // seq_cst: pairs with a waiter's `room_waiters` increment (Dekker).
        r.head.store(r.head.raw + 1, .seq_cst);
    }
    fn isEmpty(r: *Ring) bool {
        return r.head.load(.acquire) == r.tail.load(.seq_cst);
    }
};

/// Every record has a hidden 8-byte link word in front of it: the overflow
/// list threads through it, so queueing a record never allocates.
const link_bytes = 8;

fn linkOf(rec: [*]align(8) u8) *?[*]align(8) u8 {
    const base: [*]align(8) u8 = @alignCast(rec - link_bytes);
    return @ptrCast(base);
}

/// `n` bytes (already a multiple of 8) for a record, with its link word.
pub fn allocRecord(n: usize) ![]align(8) u8 {
    const all = try gpa.alignedAlloc(u8, .@"8", n + link_bytes);
    const rec: []align(8) u8 = @alignCast(all[link_bytes..]);
    linkOf(rec.ptr).* = null;
    return rec;
}

pub fn freeRecord(rec: [*]align(8) u8) void {
    const ev: *const abi.Event = @ptrCast(rec);
    const base: [*]align(8) u8 = @alignCast(rec - link_bytes);
    gpa.free(base[0 .. ev.len + link_bytes]);
}

/// A record of `size` bytes (rounded up), its header filled in.
pub fn newRecord(size: usize, typ: abi.EventType, handle: u64) ![]align(8) u8 {
    const n = abi.alignUp(size);
    const rec = try allocRecord(n);
    @memset(rec[@sizeOf(abi.Event)..], 0);
    const ev: *abi.Event = @ptrCast(rec.ptr);
    ev.* = .{ .type = @backingInt(typ), .len = @intCast(n), .handle = handle };
    return rec;
}

/// An `ANOLE_EV_SENT` record for a body about to be borrowed, built by the
/// call that borrows it (so `ANOLE_E_NOMEM` means nothing was taken); the
/// handle is filled in when it is posted (`Exec.postSentRec`).
pub fn newSent(data: []const u8) ![]align(8) u8 {
    const rec = try newRecord(@sizeOf(abi.SentEvent), .sent, 0);
    const ev: *abi.SentEvent = @ptrCast(rec.ptr);
    ev.data = @intFromPtr(data.ptr);
    ev.len = data.len;
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
    /// Records and events that did not go onto the ring (it was full, or the
    /// poster is not this executor): a stack any thread pushes onto, taken
    /// whole by `poll` into a private FIFO. Never dropped.
    overflow: std.atomic.Value(?[*]align(8) u8) = .init(null),
    ovf_head: ?[*]align(8) u8 = null,
    ovf_tail: ?[*]align(8) u8 = null,
    /// Executor tasks that need room in the ring wait on this futex word;
    /// `poll` bumps it after it takes anything, when `room_waiters` says
    /// someone waits.
    room: std.atomic.Value(u32) = .init(0),
    room_waiters: std.atomic.Value(u32) = .init(0),
    /// Tests: returns from the futex wait.
    room_wakeups: if (builtin.is_test) std.atomic.Value(u32) else void = if (builtin.is_test) .init(0) else {},
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
        db.endTied(x, i, !s.answered.load(.acquire));
        s.answered.store(false, .monotonic);
        const gen = genOf(s.word.load(.monotonic));
        x.closePipe(&s.in, gen, i);
        x.closePipe(&s.out, gen, i);
        if (s.fd >= 0) {
            closeFd(s.fd);
            s.fd = -1;
        }
        if (s.borrowed_sent) |rec| {
            x.postSentRec(x.handleOf(i, gen), rec);
            s.borrowed_sent = null;
        }
        s.borrowed = null;
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
        s.abandoned = false;
        s.body_error = null;
        s.claims = "";
        s.ws_upgrade = false;
        s.ws_slot = no_slot;
        s.subprotocol_off = 0;
        s.subprotocol_len = 0;
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

    /// Queues an owned record for the consumer. On this executor's own
    /// tasks the ring takes it; `wait` parks the task on the room futex
    /// while the ring is full (a large record also while the records
    /// already queued pass `record_budget` bytes: one always fits in an
    /// empty ring). Everywhere else (another thread, or no `wait` and a
    /// full ring) it goes onto the overflow list: nothing is ever dropped,
    /// and nothing spins.
    pub fn postRecord(x: *Exec, rec: []align(8) u8, wait: bool) void {
        const c = x.consumer orelse return freeRecord(rec.ptr);
        if (!x.onThisExecutor()) {
            x.pushOverflow(rec);
            return c.wake();
        }
        if (wait) {
            const need: usize = if (rec.len > small_record) rec.len else 0;
            while (!x.hasRoom(need)) x.waitRoom(need, null) catch return freeRecord(rec.ptr);
            _ = x.record_bytes.fetchAdd(rec.len, .monotonic);
            const pushed = x.ring.push(.{ .handle = 0, .rec = rec.ptr });
            std.debug.assert(pushed);
            return c.wake();
        }
        _ = x.record_bytes.fetchAdd(rec.len, .monotonic);
        if (!x.ring.push(.{ .handle = 0, .rec = rec.ptr })) {
            _ = x.record_bytes.fetchSub(rec.len, .monotonic);
            x.pushOverflow(rec);
        }
        c.wake();
    }

    fn onThisExecutor(x: *const Exec) bool {
        const i = placement.currentExecutor(x.engine.io) orelse return false;
        return i == x.index;
    }

    /// The ring can take one more entry (and, for a large record of `need`
    /// bytes, the queued records fit the budget).
    fn hasRoom(x: *Exec, need: usize) bool {
        if (x.ring.full()) return false;
        if (need == 0) return true;
        const queued = x.record_bytes.load(.seq_cst);
        return queued == 0 or queued + need <= x.engine.record_budget;
    }

    /// Waits (a task of this executor) until `poll` has made room, or until
    /// `deadline` (awake clock, ns). The caller re-checks its own condition.
    pub fn waitRoom(x: *Exec, need: usize, deadline: ?i96) error{ Canceled, Timeout }!void {
        const seen = x.room.load(.acquire);
        _ = x.room_waiters.fetchAdd(1, .seq_cst);
        defer _ = x.room_waiters.fetchSub(1, .monotonic);
        // Announced: look again (Dekker with the consumer's pop and
        // `signalRoom`).
        if (x.hasRoom(need)) return;
        // The consumer is behind: make sure it hears there is work.
        if (x.consumer) |c| c.wake();
        const io = x.engine.io;
        const t: std.Io.Timeout = if (deadline) |d| .{ .deadline = .{ .raw = .{ .nanoseconds = d }, .clock = .awake } } else .none;
        io.futexWaitTimeout(u32, &x.room.raw, seen, t) catch return error.Canceled;
        if (comptime builtin.is_test) _ = x.room_wakeups.fetchAdd(1, .monotonic);
        if (deadline) |d| if (std.Io.Clock.awake.now(io).nanoseconds >= d) return error.Timeout;
    }

    /// Consumer side: after `poll` took anything from this executor's ring.
    pub fn signalRoom(x: *Exec) void {
        if (x.room_waiters.load(.seq_cst) != 0) {
            _ = x.room.fetchAdd(1, .release);
            x.engine.io.futexWake(u32, &x.room.raw, std.math.maxInt(u32));
        }
    }

    /// Any thread.
    fn pushOverflow(x: *Exec, rec: []align(8) u8) void {
        const lw = linkOf(rec.ptr);
        var old = x.overflow.load(.monotonic);
        while (true) {
            lw.* = old;
            old = x.overflow.cmpxchgWeak(old, rec.ptr, .seq_cst, .monotonic) orelse break;
        }
    }

    /// Consumer side: moves the overflow stack, oldest first, onto the
    /// private FIFO.
    fn takeOverflow(x: *Exec) void {
        var list = x.overflow.swap(null, .acquire);
        var rev: ?[*]align(8) u8 = null;
        while (list) |r| {
            const next = linkOf(r).*;
            linkOf(r).* = rev;
            rev = r;
            list = next;
        }
        while (rev) |r| {
            const next = linkOf(r).*;
            linkOf(r).* = null;
            if (x.ovf_tail) |t| linkOf(t).* = r else x.ovf_head = r;
            x.ovf_tail = r;
            rev = next;
        }
    }

    /// Anything the consumer has not taken from this executor (consumer
    /// side: it knows its private FIFO).
    fn hasPending(x: *Exec) bool {
        return !x.ring.isEmpty() or x.overflow.load(.seq_cst) != null or x.ovf_head != null;
    }

    /// The engine's end: records nobody polled.
    fn freeOverflow(x: *Exec) void {
        x.takeOverflow();
        while (x.ovf_head) |rec| {
            x.ovf_head = linkOf(rec).*;
            freeRecord(rec);
        }
        x.ovf_tail = null;
    }

    /// The same for any thread: the ring and the overflow stack.
    fn hasPendingShared(x: *Exec) bool {
        return !x.ring.isEmpty() or x.overflow.load(.seq_cst) != null;
    }

    /// A small advisory event (`ANOLE_EV_BODY`, `_WRITABLE`, `_WS_DRAIN`):
    /// never dropped.
    pub fn postEvent(x: *Exec, typ: abi.EventType, handle: u64) void {
        const rec = newRecord(@sizeOf(abi.Event), typ, handle) catch return;
        x.postRecord(rec, false);
    }

    /// `ANOLE_EV_ABORT`: why the request or call `handle` is over, and what
    /// the client was sent.
    pub fn postAbort(x: *Exec, handle: u64, reason: u16, status: u16) void {
        const rec = newRecord(@sizeOf(abi.AbortEvent), .abort, handle) catch return;
        const ev: *abi.AbortEvent = @ptrCast(rec.ptr);
        ev.reason = reason;
        ev.status = status;
        x.postRecord(rec, false);
    }

    /// `ANOLE_EV_SENT` for a borrowed body, from the record the borrowing
    /// call built: never allocates, never dropped.
    pub fn postSentRec(x: *Exec, handle: u64, rec: []align(8) u8) void {
        const ev: *abi.Event = @ptrCast(rec.ptr);
        ev.handle = handle;
        x.postRecord(rec, false);
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

/// What a consumer's doorbell does: a callback, or (null) the fd.
/// Replaced by `anole_consumer_set_wake`; old targets live until destroy.
pub const WakeTarget = struct { f: ?WakeFn, ud: ?*anyopaque };

/// Windows has no pollable doorbell fd: consumers there pass a callback.
const have_fd = builtin.os.tag != .windows;

pub const Consumer = struct {
    engine: *Engine,
    target: std.atomic.Value(*const WakeTarget),
    /// Wake calls under way (`setWake` waits for them to finish).
    ringing: std.atomic.Value(u32) = .init(0),
    targets: std.ArrayList(*WakeTarget) = .empty,
    target_lock: std.atomic.Mutex = .unlocked,
    /// Debug builds: a non-shared consumer's poll is running.
    in_poll: std.atomic.Value(bool) = .init(false),
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
        // Announced before the target is read, so `setWake` cannot return
        // while an old callback is about to run.
        _ = c.ringing.fetchAdd(1, .seq_cst);
        defer _ = c.ringing.fetchSub(1, .seq_cst);
        const t = c.target.load(.seq_cst);
        _ = c.wakes.fetchAdd(1, .monotonic);
        _ = c.bell.fetchAdd(1, .release);
        if (c.waiters.load(.acquire) > 0) threadedIo().futexWake(u32, &c.bell.raw, std.math.maxInt(u32));
        if (t.f) |f| return f(t.ud);
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

    /// `anole_consumer_set_wake`: a callback, or null for the doorbell fd
    /// (opened now if it was not). Once it returns the old callback is not
    /// called again. The new wake fires once if events are pending.
    pub fn setWake(c: *Consumer, f: ?WakeFn, ud: ?*anyopaque) !void {
        if (f == null and (c.shared or !have_fd)) return error.Unsupported;
        if (f == null and c.fd_read < 0) try c.openFd();
        const t = try gpa.create(WakeTarget);
        errdefer gpa.destroy(t);
        t.* = .{ .f = f, .ud = ud };
        while (!c.target_lock.tryLock()) std.atomic.spinLoopHint();
        c.targets.append(gpa, t) catch |err| {
            c.target_lock.unlock();
            return err;
        };
        c.target_lock.unlock();
        c.target.store(t, .seq_cst);
        while (c.ringing.load(.seq_cst) != 0) std.atomic.spinLoopHint();
        // Armed again, and rung if anything waits.
        c.awake.store(false, .seq_cst);
        for (c.execs.items) |x| if (x.hasPendingShared()) {
            c.wake();
            break;
        };
    }

    fn deinit(c: *Consumer) void {
        if (have_fd) {
            if (c.fd_read >= 0) closeFd(c.fd_read);
            if (c.fd_write >= 0 and c.fd_write != c.fd_read) closeFd(c.fd_write);
        }
        for (c.targets.items) |t| gpa.destroy(t);
        c.targets.deinit(gpa);
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
    /// A WebSocket route whose handshakes the consumer decides
    /// (`"accept": "consumer"`).
    ws_consumer: bool = false,
    /// A WebSocket route that is also a plain route (`handler` and
    /// `websocket` together): the route plain requests go to.
    plain: ?*const Route = null,
    /// A WebSocket endpoint's settings.
    ws: if (features.websocket) ?anole.websocket.UpgradeOptions else void = if (features.websocket) null else {},
    /// A WebTransport endpoint's settings.
    wt: if (features.http3) ?wt.Options else void = if (features.http3) null else {},
};

// ---------------------------------------------------------------------------
// The engine: one per process.

pub const Phase = enum(u8) { created, opening, open, starting, running, draining, stopped, failed };

pub var global: ?*Engine = null;

/// One listener of the configuration, as `anole_server_listener` shows it.
pub const ListenerState = struct {
    name: []const u8,
    /// The configured address text; the bound one once listening.
    cfg_address: []const u8,
    bound_buf: [96]u8 = undefined,
    bound_len: u8 = 0,
    port: u16 = 0,
    udp_port: u16 = 0,
    flags: u32,
    /// `abi.LISTENER_*`; the fields above and below are written before the
    /// store that makes them visible.
    state: std.atomic.Value(u32) = .init(abi.LISTENER_PENDING),
    error_errno: i32 = 0,
    error_name: []const u8 = "",

    pub fn address(l: *const ListenerState, st: u32) []const u8 {
        return if (st == abi.LISTENER_PENDING or l.bound_len == 0) l.cfg_address else l.bound_buf[0..l.bound_len];
    }
};

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
    /// The configuration's listeners, in order.
    listeners: []ListenerState = &.{},
    /// The listener whose socket could not be bound (a failed start).
    failed_listener: ?usize = null,
    /// Readiness flags of `observe.health.checks` (`anole_server_set_ready`).
    ready: []std.atomic.Value(bool) = &.{},
    /// Set by the main thread once the databases are open and the routes
    /// are built (or failed): `open` waits for it.
    opened: std.Io.Event = .unset,
    /// Set by `start` (or `destroy`, with `abandon`): the main thread binds
    /// the listeners (or tears down).
    go: std.Io.Event = .unset,
    /// `destroy` was called on a server that is not drained: everything a
    /// consumer still owes is answered 503 at once.
    abandon: std.atomic.Value(bool) = .init(false),
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
    rooms: if (features.websocket) anole.websocket.Rooms else void = if (features.websocket) .init(gpa, .{}) else {},
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
        e.timeouts[0] = if (cfg.timeouts.request_ms) |ms| @as(i96, ms) * std.time.ns_per_ms else no_deadline;
        e.dbs = try a.alloc(db.Db, cfg.databases.len);
        for (e.dbs, cfg.databases) |*d, dc| d.* = .{ .engine = e, .config = dc };
        e.listeners = try a.alloc(ListenerState, cfg.listeners.len);
        for (cfg.listeners, e.listeners) |l, *ls| ls.* = try listenerState(a, l);
        if (cfg.observe.health) |h| {
            e.ready = try a.alloc(std.atomic.Value(bool), h.checks.len);
            for (e.ready) |*r| r.* = .init(false);
        }
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
        const t = try gpa.create(WakeTarget);
        errdefer gpa.destroy(t);
        t.* = .{ .f = wake_fn, .ud = wake_ud };
        c.* = .{ .engine = e, .target = .init(t), .shared = shared };
        try c.targets.append(gpa, t);
        if (wake_fn == null and !shared and have_fd) try c.openFd();
        errdefer c.deinit();
        try e.consumers.append(gpa, c);
        return c;
    }

    /// Starts Anole's threads and opens the databases, binding nothing
    /// (`anole_server_open`).
    pub fn open(e: *Engine) !void {
        if (e.consumers.items.len == 0 and e.needsConsumer()) {
            e.setWhy("routes name handlers but no consumer is attached");
            return error.NoConsumer;
        }
        if (e.phase.cmpxchgStrong(.created, .opening, .acq_rel, .acquire) != null) return error.State;
        e.thread = std.Thread.spawn(.{}, mainThread, .{e}) catch |err| {
            e.phase.store(.failed, .release);
            return err;
        };
        e.opened.waitUncancelable(threadedIo());
        if (e.start_error) |err| {
            e.thread.?.join();
            e.thread = null;
            return err;
        }
    }

    /// Binds the listeners; opens first when `open` was not called.
    pub fn start(e: *Engine) !void {
        switch (e.phase.load(.acquire)) {
            .created => try e.open(),
            .open => {},
            else => return error.State,
        }
        if (e.phase.cmpxchgStrong(.open, .starting, .acq_rel, .acquire) != null) return error.State;
        e.go.set(e.io);
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
        // Embedded: the host owns the process's signals; Anole's threads
        // (this one, and the executors, databases and pools it starts)
        // take none.
        if (!e.signals) blockSignals();
        server_mod.failed_listener_index = null;
        const cfg = e.config;
        const a = e.arena.allocator();
        // Anole's own backstop, past the consumer deadline.
        const request: ?std.Io.Duration = if (cfg.timeouts.request_ms) |default_ms| blk: {
            var longest: u32 = default_ms;
            for (cfg.routes) |r| if (r.timeout_ms) |t| {
                longest = @max(longest, t);
            };
            break :blk .fromMilliseconds(@as(i64, longest) + 5000);
        } else null;
        const listeners = buildListeners(a, cfg) catch |err| return e.failStart(err);
        var app = anole.App.init(gpa, .{
            .listeners = listeners,
            .executors = if (cfg.executors == 0) .auto else .exact(@intCast(cfg.executors)),
            .signals = e.signals,
            .raise_fd_limit = true,
            .timeouts = .{
                .request = request,
                .read_header = msOrNull(cfg.timeouts.read_header_ms),
                .write = msOrNull(cfg.timeouts.write_ms),
                .keepalive = msOrNull(cfg.timeouts.keepalive_ms),
                .idle_park = msOrNull(cfg.timeouts.idle_park_ms),
                .shutdown = msOrNull(cfg.timeouts.shutdown_ms),
            },
            .limits = .{
                .body_max = std.math.cast(usize, cfg.limits.body_max) orelse std.math.maxInt(usize),
                .max_head_size = cfg.limits.max_head_size,
                .max_header_count = cfg.limits.max_header_count,
                .max_param_count = cfg.limits.max_param_count,
                .max_query_count = cfg.limits.max_query_count,
                .max_form_count = cfg.limits.max_form_count,
                .max_multiform_count = cfg.limits.max_multiform_count,
                .max_connections = cfg.limits.max_connections,
                .max_requests_per_connection = cfg.limits.max_requests_per_connection,
                .ws_max_message = cfg.limits.ws_max_message,
            },
            .proxy = cfg.proxy,
            .request = cfg.request,
            .response = cfg.response,
            .http2 = cfg.http2,
            .errors = cfg.errors,
            .http3 = if (comptime features.http3) if (!wantsHttp3(cfg)) null else .{
                .address = cfg.http3.address,
                .port = cfg.http3.port,
                .max_streams_bidi = cfg.http3.max_streams_bidi,
                .validate_address = cfg.http3.validate_address,
                .idle_timeout = .fromMilliseconds(cfg.http3.idle_timeout_ms),
                .alt_svc = cfg.http3.alt_svc,
                .early_data = cfg.http3.early_data,
                .prefer_v2 = cfg.http3.prefer_v2,
                .sockets = cfg.http3.sockets,
                .enable_connect_protocol = cfg.http3.enable_connect_protocol,
                .inline_no_wait = cfg.http3.inline_no_wait,
                .webtransport = wantsWebTransport(cfg),
            } else null,
        }) catch |err| return e.failStart(err);
        e.app = &app;
        e.io = app.io();
        const nexec = app.rt.executors.items.len;
        if (nexec > 256) return e.failStartDeinit(&app, error.TooManyExecutors);
        // Executor e feeds consumer e mod M: one past the executors would
        // never get an event.
        if (e.consumers.items.len > nexec) {
            var w: std.Io.Writer = .fixed(&e.start_why);
            w.print("{d} consumers but only {d} executors: consumer {d} would get no events", .{ e.consumers.items.len, nexec, nexec }) catch {};
            e.start_why_len = w.end;
            return e.failStartDeinit(&app, error.ConsumerWithoutExecutor);
        }
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
        // The databases connect now (`connect_at_start` included): the
        // consumers can query before anything listens.
        app.startConnectors() catch |err| {
            e.tasks.cancel(app.io());
            db.close(e);
            return e.failStartDeinit(&app, err);
        };
        e.phase.store(.open, .release);
        e.opened.set(threadedIo());
        e.go.waitUncancelable(app.io());
        var result: anyerror!void = {};
        var watcher: ?std.Io.Future(void) = null;
        if (!e.abandon.load(.acquire)) {
            watcher = app.io().concurrent(watchReady, .{ e, &app }) catch |err| {
                e.tasks.cancel(app.io());
                db.close(e);
                return e.failStartDeinit(&app, err);
            };
            // Control calls may reach the server from here until `run` returns.
            _ = e.ctl.fetchAnd(~ctl_closed, .release);
            e.phase.store(.running, .release);
            result = app.run();
        }
        e.closeControl(app.io());
        if (watcher) |*w| w.cancel(app.io());
        e.tasks.cancel(app.io());
        if (comptime features.websocket) for (e.execs) |*x| x.ws.cancel(app.io());
        for (e.execs) |*x| x.db.cancel(app.io());
        db.close(e);
        if (result) |_| {} else |err| {
            if (!e.started.isSet()) {
                e.noteFailedListener(app.failedListenerIndex(), err);
                e.start_error = err;
                e.started.set(threadedIo());
            } else if (e.start_error == null) log.err("server stopped: {t}", .{err});
        }
        e.phase.store(.stopped, .release);
        for (e.listeners) |*l| {
            const st = l.state.load(.acquire);
            if (st == abi.LISTENER_LISTENING or st == abi.LISTENER_PENDING) l.state.store(abi.LISTENER_CLOSED, .release);
        }
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
                    .alpn = t.alpn,
                    .client_auth = switch (config_mod.clientAuth(t.client_auth).?) {
                        .none => null,
                        inline .request, .require => |m| .{
                            .ca = if (t.client_ca_file) |f| .{ .file = f } else if (t.client_ca_dir) |d| .{ .dir = d } else if (t.client_ca_system) .system else .{ .pem = t.client_ca_pem.? },
                            .mode = @field(http.ClientAuth.Mode, @tagName(m)),
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
        if (cfg.observe.health) |hc| {
            const h = app.health(.{ .healthz_path = hc.live, .readyz_path = hc.ready, .listener = hc.listener });
            // Each check starts not ready, until `anole_server_set_ready`.
            for (hc.checks, e.ready) |name, *flag| try h.addCheck(name, readyFn, flag);
        }
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
                group.inner.addRouteWith(method, rc.path, config_mod.FixedRoute.handler, .{ .data = try config_mod.fixed(a, f), .no_wait = rc.no_wait and global_ok and config_mod.neverWaits(rc.middleware) });
            } else if (rc.static) |st| {
                try group.staticDir(rc.path, st.dir, .{
                    .index = st.index,
                    .precompressed = try config_mod.precompressed(a, st.precompressed),
                    .cache_control = st.cache_control,
                    .hide_dotfiles = st.hide_dotfiles,
                });
            } else if (rc.websocket) |wc| {
                if (comptime !features.websocket) unreachable;
                // `handler` beside `websocket` (consumer-decided
                // handshakes): plain requests of the path go to it.
                var plain: ?*const Route = null;
                if (rc.handler) |id| {
                    const pr = try a.create(Route);
                    pr.* = .{
                        .engine = e,
                        .id = id,
                        .list = e.listFor(rc.timeout_ms),
                        .detachable = rc.no_wait and global_ok and config_mod.neverWaits(rc.middleware),
                    };
                    plain = pr;
                }
                const route = try a.create(Route);
                route.* = .{
                    .engine = e,
                    .id = wc.handler,
                    .list = e.listFor(rc.timeout_ms),
                    .ws_consumer = wc.accept == .consumer,
                    .plain = plain,
                    .ws = .{
                        .max_message_size = cfg.limits.ws_max_message,
                        .compression = wc.compression and features.compression,
                        .close_on_drain = wc.close_on_drain,
                        .allowed_origins = wsOrigins(wc.origins),
                        .subprotocols = wc.subprotocols,
                    },
                };
                // An extended CONNECT never arrives whole, so handshakes
                // always get a task; `no_wait` is for the plain requests.
                group.inner.addRouteWith(if (plain != null) method else .get, rc.path, ws.handler, .{
                    .data = route,
                    .no_wait = if (plain) |pr| pr.detachable else false,
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

    fn readyFn(ctx: ?*anyopaque) bool {
        const flag: *std.atomic.Value(bool) = @ptrCast(@alignCast(ctx.?));
        return flag.load(.acquire);
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
            e.noteFailedListener(app.failedListenerIndex(), err);
            e.start_error = err;
            e.started.set(threadedIo());
            return;
        };
        for (app.addresses(), 0..) |addr, i| {
            if (i >= e.listeners.len) break;
            const l = &e.listeners[i];
            var w: std.Io.Writer = .fixed(&l.bound_buf);
            switch (addr) {
                .ip => |ip| {
                    l.port = ip.getPort();
                    w.print("{f}", .{ip}) catch {};
                },
                else => w.print("unix:{s}", .{l.cfg_address}) catch {},
            }
            l.bound_len = @intCast(w.end);
        }
        // HTTP/3's UDP port, on the listener that serves it.
        if (app.http3Address()) |q| for (e.config.listeners, e.listeners) |lc, *l| {
            if (lc.http3) l.udp_port = q.getPort();
        };
        for (e.listeners) |*l| l.state.store(abi.LISTENER_LISTENING, .release);
        e.started.set(threadedIo());
    }

    /// A start that failed binding listener `index` (or none known): its
    /// state turns FAILED with the reason.
    fn noteFailedListener(e: *Engine, index: ?usize, err: anyerror) void {
        const i = index orelse return;
        if (i >= e.listeners.len) return;
        e.failed_listener = i;
        const l = &e.listeners[i];
        l.error_name = errorName(err);
        l.error_errno = errorErrno(err);
        l.state.store(abi.LISTENER_FAILED, .release);
    }

    fn failStart(e: *Engine, err: anyerror) void {
        e.noteFailedListener(server_mod.failed_listener_index, err);
        e.start_error = err;
        e.phase.store(.failed, .release);
        e.opened.set(threadedIo());
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
            .created, .opening, .open, .starting, .failed => return error.State,
        }
        // None: `run` returned (a signal, an error), and the server stops
        // on its own.
        const app = e.enter() orelse return;
        defer e.leave();
        // The first drain call tells every consumer (once each), before the
        // server starts closing sockets and cutting requests.
        if (e.phase.cmpxchgStrong(.running, .draining, .acq_rel, .acquire) == null) e.notifyDraining();
        app.stop();
    }

    /// `ANOLE_EV_DRAINING` (handle 0) to every consumer, once: long-poll,
    /// SSE and similar consumers finish up before the drain's deadline.
    fn notifyDraining(e: *Engine) void {
        for (e.consumers.items) |c| {
            if (c.execs.items.len == 0) continue;
            c.execs.items[0].postEvent(.draining, 0);
        }
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
            switch (e.phase.load(.acquire)) {
                // Opened, never started: the main thread skips `run`.
                .open => {
                    e.abandon.store(true, .release);
                    e.go.set(e.io);
                },
                // Not drained: what consumers still owe is answered 503 at
                // once (the capi tasks), so this does not wait for answers
                // that cannot come (it may run on a consumer's own thread).
                .running, .draining => {
                    e.abandon.store(true, .release);
                    for (e.execs) |*x| x.kick.set(e.io);
                    e.drain() catch {};
                },
                else => {},
            }
            t.join();
        }
        // The next server's handles start past every one handed out here.
        var last = e.first_gen;
        for (e.execs) |*x| {
            for (x.slots) |*s| last = @max(last, genOf(s.word.load(.acquire)));
            last = @max(last, x.ws.maxGen(), x.wt.maxGen(), x.db.maxGen());
        }
        next_first_gen = nextGen(last);
        if (global == e) global = null;
        for (e.execs) |*x| {
            for (x.slots) |*s| {
                if (s.borrowed_sent) |r| freeRecord(r.ptr);
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
            x.freeOverflow();
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
            x.db.deinit();
        }
        gpa.free(e.execs);
        if (comptime features.grpc) grpc.deinit(e);
        for (e.consumers.items) |c| {
            c.deinit();
            gpa.destroy(c);
        }
        e.consumers.deinit(gpa);
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

    /// `anole_server_set_ready`.
    pub fn setReady(e: *Engine, name: []const u8, ready: bool) error{UnknownCheck}!void {
        const checks = (e.config.observe.health orelse return error.UnknownCheck).checks;
        for (checks, e.ready) |c, *flag| if (std.mem.eql(u8, c, name)) {
            flag.store(ready, .release);
            return;
        };
        return error.UnknownCheck;
    }

    /// The bound TCP port of listener `i`; `i` = the number of listeners:
    /// the HTTP/3 (UDP) port, when a listener serves it. 0 before.
    pub fn port(e: *const Engine, i: usize) u16 {
        if (i < e.listeners.len) return e.listeners[i].port;
        if (i == e.listeners.len) for (e.listeners) |l| if (l.udp_port != 0) return l.udp_port;
        return 0;
    }

    /// A handle error as an answer call reports it: over is `Gone`
    /// (counted).
    pub fn badHandle(e: *Engine, err: HandleError) AnswerError {
        return switch (err) {
            error.WrongKind => error.WrongKind,
            error.Over => e.gone(),
        };
    }

    /// Why a client-side end happens: the drain's deadline cut it, or the
    /// client left.
    pub fn clientReason(e: *const Engine) u16 {
        return if (e.phase.load(.acquire) == .draining) abi.ABORT_DRAIN else abi.ABORT_CLIENT;
    }

    pub fn gone(e: *Engine) error{Gone} {
        _ = e.gone_count.fetchAdd(1, .monotonic);
        return error.Gone;
    }
};

fn listenerState(a: std.mem.Allocator, l: Config.Listener) !ListenerState {
    var flags: u32 = 0;
    if (l.tls != null) flags |= abi.LISTENER_F_TLS;
    if (l.http1) flags |= abi.LISTENER_F_HTTP1;
    if (l.http2 and features.http2) flags |= abi.LISTENER_F_HTTP2;
    if (l.http3) flags |= abi.LISTENER_F_HTTP3;
    if (l.unix != null) flags |= abi.LISTENER_F_UNIX;
    if (l.proxy_protocol) flags |= abi.LISTENER_F_PROXY_PROTOCOL;
    const scheme = if (l.tls != null) "https" else "http";
    const name: []const u8 = l.name orelse if (l.unix) |path|
        try std.fmt.allocPrint(a, "unix-{s}", .{path})
    else
        try std.fmt.allocPrint(a, "{s}-{d}", .{ scheme, l.port });
    // "127.0.0.1:8080", "[::]:8443", "unix:/run/app.sock".
    const address: []const u8 = if (l.unix) |path|
        try std.fmt.allocPrint(a, "unix:{s}", .{path})
    else if (l.address.len == 0)
        try std.fmt.allocPrint(a, "[::]:{d}", .{l.port})
    else if (std.mem.indexOfScalar(u8, l.address, ':') != null)
        try std.fmt.allocPrint(a, "[{s}]:{d}", .{ l.address, l.port })
    else
        try std.fmt.allocPrint(a, "{s}:{d}", .{ l.address, l.port });
    return .{ .name = name, .cfg_address = address, .flags = flags };
}

/// Embedded mode: every asynchronous signal is blocked on Anole's threads
/// (the ones a crash raises stay deliverable), so a host's SIGCHLD, SIGINT
/// or profiler handler runs on the host's threads only.
fn blockSignals() void {
    if (comptime builtin.os.tag == .windows or !builtin.link_libc) return;
    var set: std.c.sigset_t = undefined;
    var old: std.c.sigset_t = undefined;
    _ = std.c.sigfillset(&set);
    inline for (.{ "SEGV", "BUS", "FPE", "ILL", "TRAP", "SYS", "ABRT" }) |name| {
        if (comptime @hasDecl(std.c.SIG, name)) _ = std.c.sigdelset(&set, @field(std.c.SIG, name));
    }
    _ = std.c.pthread_sigmask(std.c.SIG.BLOCK, &set, &old);
}

/// The stable token of a start or TLS failure (`anole_last_error_name`):
/// the error's own name when it is one of `abi.error_names`.
pub fn errorName(err: anyerror) []const u8 {
    const name = @errorName(err);
    for (abi.error_names) |t| if (std.mem.eql(u8, t, name)) return t;
    return switch (err) {
        error.PermissionDenied => "AccessDenied",
        error.AddressUnavailable => "AddressNotAvailable",
        error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => "TooManyOpenFiles",
        error.TlsInvalidCertificate => "InvalidCertificate",
        error.TlsInvalidPrivateKey => "InvalidKey",
        error.TlsKeyMismatch => "KeyMismatch",
        else => "Unexpected",
    };
}

/// The OS error behind a failure, for `anole_last_errno`; 0 when it did not
/// come from the OS.
pub fn errorErrno(err: anyerror) i32 {
    if (comptime builtin.os.tag == .windows) return 0;
    const E = std.posix.E;
    const code: E = switch (err) {
        error.AddressInUse => .ADDRINUSE,
        error.AddressNotAvailable, error.AddressUnavailable => .ADDRNOTAVAIL,
        error.AccessDenied, error.PermissionDenied => .ACCES,
        error.FileNotFound => .NOENT,
        error.ProcessFdQuotaExceeded => .MFILE,
        error.SystemFdQuotaExceeded => .NFILE,
        error.SystemResources, error.OutOfMemory => .NOMEM,
        error.ConnectionRefused => .CONNREFUSED,
        error.NetworkUnreachable => .NETUNREACH,
        error.IsDir => .ISDIR,
        error.NotDir => .NOTDIR,
        else => return 0,
    };
    return @backingInt(code);
}

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
    return serveConsumer(route, req, res);
}

/// A WebSocket handshake being decided by the consumer: the WebSocket slot
/// reserved for it, and what the answer was.
pub const Upgrade = struct {
    ws_slot: u32,
    accepted: bool = false,
    /// `accepted`: the subprotocol and extra headers the consumer chose,
    /// copied into the request's arena.
    subprotocol: []const u8 = "",
    headers: []const std.http.Header = &.{},
};

/// A plain request of `route`, handed to the consumer (`ANOLE_EV_REQUEST`).
pub fn serveConsumer(route: *const Route, req: *http.Request, res: *http.Response) anyerror!void {
    return serve(route, req, res, null);
}

/// A WebSocket handshake of `route`, handed to the consumer
/// (`ANOLE_EV_WS_UPGRADE`); `up.accepted` tells whether it was accepted.
/// Any other answer was applied to `res`.
pub fn serveUpgrade(route: *const Route, req: *http.Request, res: *http.Response, up: *Upgrade) anyerror!void {
    return serve(route, req, res, up);
}

fn serve(route: *const Route, req: *http.Request, res: *http.Response, up: ?*Upgrade) anyerror!void {
    const e = route.engine;
    const io = req.io;
    const xi = placement.currentExecutor(io) orelse return error.InternalServerError;
    const x = &e.execs[xi];
    if (x.consumer == null) {
        res.fail(.service_unavailable, "no consumer");
        return;
    }
    if (e.abandon.load(.acquire)) {
        res.fail(.service_unavailable, "the server is stopping");
        return;
    }
    // A handshake never detaches (an extended CONNECT never arrives whole).
    const detach = up == null and res.canDetach() and route.detachable;
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
    s.ws_upgrade = up != null;
    s.ws_slot = if (up) |u| u.ws_slot else no_slot;
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
        if (s.timed_out or std.Io.Clock.awake.now(io).nanoseconds >= s.deadline) {
            x.unlink(si);
            x.release(si);
            _ = e.busy_count.fetchAdd(1, .monotonic);
            res.fail(.service_unavailable, "the application is behind");
            return;
        }
        x.waitRoom(0, s.deadline) catch |err| switch (err) {
            error.Canceled => {
                canceled = true;
                break;
            },
            error.Timeout => continue,
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
    return waitForAnswer(x, si, gen, req, res, canceled, up);
}

/// The request's task waits for its answer (HTTP/1.1, and requests that
/// could not detach), and writes it.
fn waitForAnswer(x: *Exec, si: u32, gen: u32, req: *http.Request, res: *http.Response, canceled_in: bool, up: ?*Upgrade) anyerror!void {
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
                    // Why it is over, for the consumer that saw it.
                    var reason: u16 = abi.ABORT_BODY;
                    var status: u16 = if (s.body_error) |b| @intCast(@backingInt(b)) else 0;
                    if (canceled) {
                        reason = e.clientReason();
                        status = 0;
                    } else if (s.timed_out) {
                        reason = abi.ABORT_DEADLINE;
                        status = 504;
                    }
                    if (s.word.cmpxchgStrong(w, pack(gen, .expired), .acq_rel, .acquire) == null) {
                        // The consumer saw it: it hears that it is over
                        // (not when the server is going away under it).
                        if (stateOf(w) == .out and !s.abandoned) x.postAbort(x.handleOf(si, gen), reason, status);
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
            const abandoned = s.abandoned;
            x.release(si);
            if (abandoned and !canceled) {
                res.fail(.service_unavailable, "the server is stopping");
                return;
            }
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
            if (s.reply == .ws_accept) {
                // The handshake is accepted: what the consumer chose, out
                // of the slot before it is freed.
                const u = up.?;
                const bytes = s.bytes.items;
                u.subprotocol = try req.arena.dupe(u8, bytes[s.subprotocol_off..][0..s.subprotocol_len]);
                const list = try req.arena.alloc(std.http.Header, s.headers.items.len);
                for (s.headers.items, list) |h, *out| out.* = .{
                    .name = try req.arena.dupe(u8, bytes[h.name_off..][0..h.name_len]),
                    .value = try req.arena.dupe(u8, bytes[h.value_off..][0..h.value_len]),
                };
                u.headers = list;
                u.accepted = true;
                return;
            }
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
    switch (s.reply) {
        // `res.fail` may keep its message: it goes in the request's arena.
        .fail => {
            const detail = try req.arena.dupe(u8, s.bytes.items[0..s.fail_len]);
            res.fail(http.Status.fromCode(s.status) catch .internal_server_error, detail);
            return;
        },
        // HTTP/1.1 closes the connection, HTTP/2 resets the stream
        // (CANCEL), HTTP/3 cancels it (H3_REQUEST_CANCELLED).
        .abort => return res.abort(),
        else => {},
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
        .fail, .abort, .ws_accept => unreachable,
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
        .consumer => if (ch.sent) |r| x.postSentRec(x.handleOf(si, gen), r),
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
    if (!failed) x.postAbort(x.handleOf(si, gen), x.engine.clientReason(), 0);
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
                if (stateOf(w) == .out) x.postAbort(x.handleOf(si, gen), e.clientReason(), 0);
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
            if (stateOf(w) == .streaming) x.postAbort(x.handleOf(si, gen), abi.ABORT_CLIENT, 0);
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
    endDetached(x, si, w, false);
}

/// A detached request ended by the sweeper: 504 at its deadline, or 503
/// when the server is being destroyed (`abandon`: the consumer hears
/// nothing more).
fn endDetached(x: *Exec, si: u32, w: u64, abandoning: bool) void {
    const s = &x.slots[si];
    const gen = genOf(w);
    if (s.word.cmpxchgStrong(w, pack(gen, .expired), .acq_rel, .acquire) != null) return;
    if (!abandoning) {
        if (stateOf(w) == .out) x.postAbort(x.handleOf(si, gen), abi.ABORT_DEADLINE, 504);
        _ = x.engine.expired_count.fetchAdd(1, .monotonic);
    }
    if (s.detached) |d| {
        s.detached = null;
        x.closePipe(&s.in, gen, si);
        if (abandoning)
            d.response.fail(.service_unavailable, "the server is stopping")
        else
            d.response.fail(.gateway_timeout, "the application did not answer in time");
        d.finish({});
    }
    x.release(si);
}

/// `destroy` on a server not drained: every request and call a consumer
/// still owes is answered at once (503, UNAVAILABLE; streams are cut) and
/// the consumer hears nothing more. Run by the capi task while `abandon`
/// is set.
fn abandonAll(x: *Exec) void {
    const io = x.engine.io;
    for (x.slots, 0..) |*s, i| {
        const si: u32 = @intCast(i);
        const w = s.word.load(.acquire);
        if (comptime features.grpc) if (s.kind.load(.monotonic) == @backingInt(Handle.Kind.grpc_call)) {
            grpc.abandon(x, si, w);
            continue;
        };
        switch (stateOf(w)) {
            .queued, .out => {
                if (s.orphan) {
                    if (s.word.cmpxchgStrong(w, pack(genOf(w), .expired), .acq_rel, .acquire) != null) continue;
                    x.release(si);
                } else if (s.detached != null) {
                    endDetached(x, si, w, true);
                } else if (!s.abandoned) {
                    x.unlink(si);
                    s.abandoned = true;
                    s.timed_out = true;
                    s.event.set(io);
                }
            },
            .streaming => {
                s.out.acquire();
                s.out.failed = true;
                s.out.exec_waiting = false;
                s.out.release();
                s.event.set(io);
            },
            else => {},
        }
    }
}

// ---------------------------------------------------------------------------
// The capi task: one per executor.

/// Hands answers to their requests, runs commands, enforces deadlines and
/// rings lost doorbells again.
fn capiTask(e: *Engine, x: *Exec) std.Io.Cancelable!void {
    const io = e.io;
    while (true) {
        x.kick.reset();
        if (e.abandon.load(.acquire)) abandonAll(x);
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
                if (stateOf(w) == .streaming) x.postAbort(x.handleOf(si, genOf(w)), abi.ABORT_CLIENT, 0);
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
                            if (stateOf(w) == .out) x.postAbort(x.handleOf(si, genOf(w)), abi.ABORT_CLIENT, 0);
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
        if (e.rewake > 0 and (any_out or x.hasPendingShared())) if (x.consumer) |c| {
            if (x.hasPendingShared() and c.awake.load(.acquire) and now - c.last_poll.load(.monotonic) > e.rewake) c.rewake();
            until = @min(until, now + e.rewake);
        };
        x.idle = !any_out and !x.hasPendingShared();
        x.kick.waitTimeout(io, .{ .duration = .{ .raw = .{ .nanoseconds = @max(until - now, 0) }, .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => return error.Canceled,
        };
    }
}

// ---------------------------------------------------------------------------
// Consumer side: poll (on the consumer's thread)

/// What `timeouts.request_ms: null` stands for in the deadline lists: a day.
const no_deadline: i96 = 24 * 3600 * std.time.ns_per_s;

fn msOrNull(ms: ?u32) ?std.Io.Duration {
    return if (ms) |v| std.Io.Duration.fromMilliseconds(v) else null;
}

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
    /// When Anole answers 504 (awake clock, ns) and the clock when the
    /// record is built; no deadline: `timeout_us` is -1.
    deadline: ?i96 = null,
    now: i96 = 0,
    /// ANOLE_EV_WS_OPEN: the selected subprotocol.
    subprotocol: []const u8 = "",

    pub fn size(h: Head) usize {
        const req = h.req;
        var n: usize = @sizeOf(abi.RequestEvent);
        const nh = req.headers.len;
        n += nh * 2 * @sizeOf(abi.Span);
        n += req.params.count() * 2 * @sizeOf(abi.Span);
        n += methodName(req).len + req.url.len + h.body.len + h.remote.len + req.listener.name.len + req.id.len + h.claims.len + h.subprotocol.len;
        for (req.headers.keys[0..nh], req.headers.values[0..nh]) |k, v| n += k.len + v.len;
        var it = req.params.map.iterator();
        while (it.next()) |kv| n += kv.key_ptr.len + kv.value_ptr.len;
        // Mutual TLS: the client's certificate (DER) last.
        if (req.peerCertificate()) |der| n += der.len;
        return abi.alignUp(n);
    }

    /// Writes the record into `out` (exactly `size()` bytes).
    pub fn encode(h: Head, typ: abi.EventType, handle: u64, out: []u8) usize {
        const req = h.req;
        const size_ = out.len;
        const nh = req.headers.len;
        const np = req.params.count();
        const spans_off: usize = @sizeOf(abi.RequestEvent);
        const spans: [*]align(1) abi.Span = @ptrCast(out[spans_off..].ptr);
        var pos: usize = spans_off + (nh + np) * 2 * @sizeOf(abi.Span);
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
        const subprotocol = put(out, &pos, h.subprotocol, false);
        var peer_cert: abi.Span = .{};
        if (req.peerCertificate()) |der| peer_cert = put(out, &pos, der, false);
        std.debug.assert(abi.alignUp(pos) == size_);
        @memset(out[pos..size_], 0);
        const rec: *align(1) abi.RequestEvent = @ptrCast(out.ptr);
        rec.* = .{
            .ev = .{ .type = @backingInt(typ), .len = @intCast(size_), .handle = handle },
            .route_id = h.route_id,
            .method = methodCode(req.method),
            .version = req.version_major * 10 + req.version_minor,
            .flags = h.flags | if (peer_cert.len != 0) abi.REQ_PEER_CERT else 0,
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
            .spans_off = @intCast(spans_off),
            .content_length = h.content_length,
            .peer_cert = peer_cert,
            .timeout_us = if (h.deadline) |d| @intCast(@divTrunc(@max(d - h.now, 0), std.time.ns_per_us)) else -1,
            .subprotocol = subprotocol,
        };
        return size_;
    }

    fn methodName(req: *const http.Request) []const u8 {
        // An extended CONNECT is routed as GET; the record says GET too.
        return req.method.name();
    }
};

fn headOf(s: *const Slot, now: i96) Head {
    return .{
        .deadline = if (s.linked) s.deadline else null,
        .now = now,
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
/// `!arm`). On `error.TooBig`, `need` is the size of the record that did
/// not fit.
pub fn poll(c: *Consumer, out: []u8, arm: bool, need: *u32) PollError!usize {
    if (c.shared) {
        c.poll_lock.lockUncancelable(threadedIo());
        defer c.poll_lock.unlock(threadedIo());
        return pollLocked(c, out, arm, true, need);
    }
    if (comptime builtin.mode == .debug) {
        if (c.in_poll.swap(true, .acq_rel)) @panic("anole_poll overlapped on one consumer");
    }
    defer if (comptime builtin.mode == .debug) c.in_poll.store(false, .release);
    return pollLocked(c, out, arm, false, need);
}

fn pollLocked(c: *Consumer, out: []u8, arm: bool, one: bool, need: *u32) PollError!usize {
    const e = c.engine;
    const phase = e.phase.load(.acquire);
    const now: i96 = std.Io.Clock.awake.now(e.io).nanoseconds;
    if (phase != .created and phase != .opening and phase != .open and phase != .starting)
        c.last_poll.store(@intCast(now), .monotonic);
    var pos: usize = 0;
    var rechecked = false;
    outer: while (true) {
        var progressed = false;
        var i: usize = 0;
        while (i < c.execs.items.len) : (i += 1) {
            const x = c.execs.items[(c.next_exec + i) % c.execs.items.len];
            var popped = false;
            defer if (popped) x.signalRoom();
            while (x.ring.peek()) |entry| {
                if (one and pos > 0) break :outer;
                if (entry.rec) |rec| {
                    const ev: *const abi.Event = @ptrCast(rec);
                    if (ev.len > out.len - pos) {
                        if (pos == 0) {
                            need.* = ev.len;
                            return error.TooBig;
                        }
                        c.next_exec = (c.next_exec + i) % c.execs.items.len;
                        break :outer;
                    }
                    @memcpy(out[pos..][0..ev.len], rec[0..ev.len]);
                    pos += ev.len;
                    const len = ev.len;
                    freeRecord(rec);
                    x.ring.pop();
                    popped = true;
                    _ = x.record_bytes.fetchSub(len, .seq_cst);
                    progressed = true;
                    continue;
                }
                const h = Handle.decode(entry.handle);
                const s = &x.slots[h.slot];
                const queued = pack(h.gen, .queued);
                if (s.word.cmpxchgStrong(queued, pack(h.gen, .polling), .acquire, .monotonic) != null) {
                    // Expired (or reused since): skip it.
                    x.ring.pop();
                    popped = true;
                    continue;
                }
                const is_grpc = features.grpc and h.kind == .grpc_call;
                const size = if (is_grpc) grpc.recordSize(s) else headOf(s, now).size();
                if (size > out.len - pos) {
                    s.word.store(queued, .release);
                    if (pos == 0) {
                        need.* = @intCast(size);
                        return error.TooBig;
                    }
                    c.next_exec = (c.next_exec + i) % c.execs.items.len;
                    break :outer;
                }
                pos += if (is_grpc) grpc.encodeRecord(s, entry.handle, out[pos..][0..size], now) else headOf(s, now).encode(if (s.ws_upgrade) .ws_upgrade else .request, entry.handle, out[pos..][0..size]);
                s.word.store(pack(h.gen, .out), .release);
                x.ring.pop();
                popped = true;
                progressed = true;
            }
            // Records that did not fit the ring (or came from another
            // thread), oldest first.
            x.takeOverflow();
            while (x.ovf_head) |rec| {
                if (one and pos > 0) break :outer;
                const ev: *const abi.Event = @ptrCast(rec);
                if (ev.len > out.len - pos) {
                    if (pos == 0) {
                        need.* = ev.len;
                        return error.TooBig;
                    }
                    c.next_exec = (c.next_exec + i) % c.execs.items.len;
                    break :outer;
                }
                @memcpy(out[pos..][0..ev.len], rec[0..ev.len]);
                pos += ev.len;
                x.ovf_head = linkOf(rec).*;
                if (x.ovf_head == null) x.ovf_tail = null;
                freeRecord(rec);
                progressed = true;
            }
        }
        c.next_exec = (c.next_exec + 1) % @max(c.execs.items.len, 1);
        if (pos > 0 or progressed) break;
        if (e.phase.load(.acquire) == .stopped and !c.stopped_sent) {
            if (out.len < @sizeOf(abi.Event)) {
                need.* = @sizeOf(abi.Event);
                return error.TooBig;
            }
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
        for (c.execs.items) |x| if (x.hasPending()) {
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
pub fn pollWait(c: *Consumer, out: []u8, timeout_ms: i32, need: *u32) PollError!usize {
    const tio = threadedIo();
    const deadline: ?std.Io.Clock.Timestamp = if (timeout_ms < 0) null else std.Io.Clock.Timestamp.now(tio, .awake).addDuration(.{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake });
    while (true) {
        const seq = c.bell.load(.acquire);
        const n = try poll(c, out, true, need);
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

/// `Over` and `WrongKind` come from a handle: the object is over (an answer
/// call turns it into `Gone`, a cleanup call into success), or the handle is
/// 0 or of another kind (`ANOLE_E_INVALID` everywhere).
pub const AnswerError = error{ Gone, Invalid, OutOfMemory, Unsupported, Timeout, Again, State, TooBig, Over, WrongKind, System };
pub const HandleError = error{ WrongKind, Over };

pub const CHeader = abi.Header;

fn slotOf(e: *Engine, hv: u64) HandleError!struct { *Exec, *Slot, Handle } {
    return slotOfKind(e, hv, .request);
}

/// The slot a handle of `kind` names, if it could be one: the generation
/// is the caller's to check (a stale handle finds its slot moved on).
pub fn slotOfKind(e: *Engine, hv: u64, kind: Handle.Kind) HandleError!struct { *Exec, *Slot, Handle } {
    const h = Handle.decode(hv);
    if (hv == 0 or h.gen == 0 or h.kind != kind) return error.WrongKind;
    if (h.exec >= e.execs.len) return error.Over;
    const x = &e.execs[h.exec];
    if (h.slot >= x.slots.len) return error.Over;
    const s = &x.slots[h.slot];
    if (s.kind.load(.acquire) != @backingInt(kind)) return error.Over;
    return .{ x, s, h };
}

/// Claims slot `hv` for an answer: `out` to `responding`. `Over` when it is
/// no longer owed.
fn claimOrOver(e: *Engine, hv: u64) HandleError!struct { *Exec, *Slot, Handle } {
    const x, const s, const h = try slotOf(e, hv);
    if (s.word.cmpxchgStrong(pack(h.gen, .out), pack(h.gen, .responding), .acquire, .monotonic) != null) return error.Over;
    return .{ x, s, h };
}

/// An answer call's claim: over is `Gone`.
fn claim(e: *Engine, hv: u64) AnswerError!struct { *Exec, *Slot, Handle } {
    return claimOrOver(e, hv) catch |err| return e.badHandle(err);
}

/// Hands slot `si` to its executor (`done` or `streaming`).
pub fn handBack(x: *Exec, s: *Slot, h: Handle, state: SlotState) void {
    s.answered.store(true, .release);
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
    if (!borrow and body.len > std.math.maxInt(u32)) return error.Invalid;
    // The SENT record first: a call that fails takes nothing.
    const sent: ?[]align(8) u8 = if (borrow) try newSent(body) else null;
    errdefer if (sent) |r| freeRecord(r.ptr);
    const x, const s, const h = try claim(e, hv);
    errdefer s.word.store(pack(h.gen, .out), .release);
    try storeHeaders(&s.headers, &s.bytes, headers, if (borrow) 0 else body.len);
    s.body_off = @intCast(s.bytes.items.len);
    if (borrow) {
        s.borrowed = body;
        s.borrowed_sent = sent;
        s.body_len = 0;
    } else {
        s.borrowed = null;
        s.body_len = @intCast(body.len);
        s.bytes.appendSliceAssumeCapacity(body);
    }
    s.reply = .respond;
    s.status = status;
    handBack(x, s, h, .done);
}

/// An error answer in the server's configured error format: status 400-599
/// (0: 500), `message` the detail (at most 4096 bytes, copied). An answer
/// call.
pub fn fail(e: *Engine, hv: u64, status: u16, message: []const u8) AnswerError!void {
    return failWith(e, hv, status, message, true);
}

fn failWith(e: *Engine, hv: u64, status_in: u16, message: []const u8, counted: bool) AnswerError!void {
    const status: u16 = if (status_in == 0) 500 else status_in;
    if (status < 400 or status > 599) return error.Invalid;
    if (message.len > 4096) return error.Invalid;
    try checkStatus(status);
    const x, const s, const h = if (counted) try claim(e, hv) else try claimOrOver(e, hv);
    errdefer s.word.store(pack(h.gen, .out), .release);
    s.headers.clearRetainingCapacity();
    s.bytes.clearRetainingCapacity();
    try s.bytes.appendSlice(gpa, message);
    s.fail_len = @intCast(message.len);
    s.reply = .fail;
    s.status = status;
    handBack(x, s, h, .done);
}

/// Drops the request without an answer (`res.abort()`); a stream under way
/// is cut short. A cleanup call: `error.Over` when it is already over.
pub fn abort(e: *Engine, hv: u64) AnswerError!void {
    const x, const s, const h = try slotOf(e, hv);
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
    if (s.word.cmpxchgStrong(pack(h.gen, .out), pack(h.gen, .responding), .acquire, .monotonic) != null) return error.Over;
    s.reply = .abort;
    s.headers.clearRetainingCapacity();
    s.bytes.clearRetainingCapacity();
    handBack(x, s, h, .done);
}

/// `anole_ws_accept`: the consumer accepts the WebSocket handshake `hv`
/// (an `ANOLE_EV_WS_UPGRADE`). Returns the socket's handle, open at once;
/// the handshake's answer goes out from the request's task.
pub fn wsAccept(e: *Engine, hv: u64, subprotocol: []const u8, headers: []const CHeader) AnswerError!u64 {
    if (comptime !features.websocket) return error.Unsupported;
    _ = try checkHeaders(headers);
    for (headers) |h| if (!anole.websocket.handshakeHeaderAllowed(h.name.slice())) return error.Invalid;
    if (subprotocol.len > 0 and (subprotocol.len > 255 or !anole.websocket.isToken(subprotocol))) return error.Invalid;
    const x, const s, const h = try claim(e, hv);
    errdefer s.word.store(pack(h.gen, .out), .release);
    if (!s.ws_upgrade) return error.State;
    // The request's memory is alive: its task waits for this answer.
    if (subprotocol.len > 0) {
        var offered = anole.websocket.offeredSubprotocols(s.req);
        const found = while (offered.next()) |o| {
            if (std.mem.eql(u8, o, subprotocol)) break true;
        } else false;
        if (!found) return error.Invalid;
    }
    try storeHeaders(&s.headers, &s.bytes, headers, subprotocol.len);
    s.subprotocol_off = @intCast(s.bytes.items.len);
    s.subprotocol_len = @intCast(subprotocol.len);
    s.bytes.appendSliceAssumeCapacity(subprotocol);
    s.reply = .ws_accept;
    s.status = 200;
    // Cannot fail: the slot was reserved for this request.
    const handle = ws.openReserved(x, s.ws_slot);
    handBack(x, s, h, .done);
    return handle;
}

/// `anole_handle_release`: ends whatever the handle is, the way the
/// application giving up would. A cleanup call.
pub fn handleRelease(e: *Engine, hv: u64) AnswerError!void {
    const h = Handle.decode(hv);
    if (hv == 0) return error.WrongKind;
    switch (h.kind) {
        .request => {
            _, const s, const hh = try slotOf(e, hv);
            // A stream under way is cut short; otherwise the client gets 500.
            if (s.out.gen == hh.gen) {
                s.out.acquire();
                const streaming = s.out.live(hh.gen) and !s.out.ended;
                s.out.release();
                if (streaming) return abort(e, hv);
            }
            return failWith(e, hv, 0, "", false);
        },
        .websocket => {
            if (comptime !features.websocket) return error.Over;
            return ws.close(e, hv, 1001, "");
        },
        .grpc_call => {
            if (comptime !features.grpc) return error.Over;
            return grpc.release(e, hv);
        },
        .wt_session => {
            if (comptime !features.http3) return error.Over;
            return wt.close(e, hv, 0, "");
        },
        .wt_stream => {
            if (comptime !features.http3) return error.Over;
            return wt.streamOp(e, hv, .release, 0);
        },
        // A database transaction: rolled back (a cleanup call: nothing to
        // say when it is over).
        .db_tx => {
            if (comptime !features.sqlite and !features.postgres) return error.Over;
            return db.txRelease(e, hv);
        },
        .db_query, _ => return error.WrongKind,
    }
}

/// The OS error behind the last `Invalid`/`System` answer of `respondFd`
/// on this thread (`anole_last_errno`).
pub threadlocal var engine_errno: i32 = 0;

pub fn respondFd(e: *Engine, hv: u64, status: u16, headers: []const CHeader, fd: c_int, offset: u64, len: u64) AnswerError!void {
    if (comptime builtin.os.tag == .windows) return error.Unsupported;
    try checkStatus(status);
    _ = try checkHeaders(headers);
    // A regular file, and how much of it.
    if (fd < 0) return error.Invalid;
    // A descriptor that is none (std treats EBADF from fstat as a bug).
    if (std.c.fcntl(fd, std.c.F.GETFD) < 0) {
        engine_errno = std.c._errno().*;
        return error.Invalid;
    }
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    const st = file.stat(threadedIo()) catch {
        engine_errno = @backingInt(std.posix.E.BADF);
        return error.Invalid;
    };
    if (st.kind != .file) return error.Invalid;
    const size: u64 = st.size;
    if (offset > size) return error.Invalid;
    const n = if (len == 0) size - offset else len;
    if (n > size - offset) return error.Invalid;
    const x, const s, const h = try claim(e, hv);
    errdefer s.word.store(pack(h.gen, .out), .release);
    const dup = std.c.fcntl(fd, std.c.F.DUPFD_CLOEXEC, @as(c_int, 0));
    if (dup < 0) {
        engine_errno = std.c._errno().*;
        return error.System;
    }
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
    const x, const s, const h = slotOf(e, hv) catch |err| return e.badHandle(err);
    // The SENT record first: a call that fails takes nothing.
    const sent: ?[]align(8) u8 = if (borrow) try newSent(data) else null;
    errdefer if (sent) |r| freeRecord(r.ptr);
    const owned: ?[]u8 = if (borrow or data.len == 0) null else try gpa.dupe(u8, data);
    errdefer if (owned) |o| gpa.free(o);
    s.out.acquire();
    if (!s.out.live(h.gen) or s.out.ended or s.out.failed) {
        s.out.release();
        return e.gone();
    }
    if (data.len == 0) {
        // Nothing to queue; a borrowed empty write is already "sent".
        s.out.release();
        if (sent) |r| x.postSentRec(hv, r);
        return false;
    }
    s.out.push(.{ .data = owned orelse data, .owner = if (borrow) .consumer else .pipe, .sent = sent }) catch |err| {
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
    _, const s, const h = slotOf(e, hv) catch |err| return e.badHandle(err);
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
    _, const s, const h = slotOf(e, hv) catch |err| return e.badHandle(err);
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
    const x, const s, const h = slotOf(e, hv) catch |err| return e.badHandle(err);
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
    _ = @import("parity_test.zig");
    if (features.grpc) _ = grpc;
}
