//! WebTransport routes of the C ABI: sessions, their streams both ways in
//! either direction, and datagrams, through the same rings as requests.
//!
//! Each session is run by one task on its connection's executor: the
//! route's handler, which accepts the session (`anole.webtransport.accept`)
//! and then drives it with the session's calls that never wait
//! (`tryAccept`, `tryRead`, `tryWrite`, `takeDatagram`...). It waits only
//! for the connection to change (`waitChange`), and what a consumer asks
//! for wakes it the way a WebSocket's sender is woken: the consumer's call
//! leaves the work in the slot and posts the session's `kick` command to
//! the executor, which wakes the connection's waiters.
//!
//! Sessions and streams live in per-executor tables of slots that are
//! never moved or freed while the engine lives, so a stale handle always
//! lands on a slot whose generation says it is gone. Stream slots are also
//! taken from consumer threads (`anole_wt_open_stream`), so the tables'
//! free lists are under a lock.
const std = @import("std");
const anole = @import("../root.zig");
const dusty = @import("dusty");
const abi = @import("abi.zig");
const engine = @import("engine.zig");
const slot_table = @import("slot_table.zig");
const SlotTable = slot_table.SlotTable;
const spin = slot_table.spin;
const placement = dusty.placement;
const webtransport = anole.webtransport;
const Session = webtransport.Session;
const Stream = webtransport.Stream;
const Engine = engine.Engine;
const Exec = engine.Exec;
const Route = engine.Route;
const Command = engine.Command;
const Handle = engine.Handle;
const gpa = engine.gpa;

const log = std.log.scoped(.anole_capi);

/// What a WebTransport route asks for (the route's config).
pub const Options = struct {
    accept: webtransport.AcceptOptions,
    /// Datagrams a session holds for sending; past it, the oldest goes.
    datagram_queue: u32,
};

const State = enum(u32) { free, open };

fn pack(gen: u32, state: State) u64 {
    return (@as(u64, gen) << 32) | @backingInt(state);
}

fn freeWord(gen: u32) u64 {
    return pack(gen, .free);
}

/// Slots of one kind on one executor; also taken from consumer threads, so
/// the free list is under a lock.
fn Table(comptime T: type) type {
    return SlotTable(T, .{ .chunk_len = 256, .max_chunks = 4096, .full = error.OutOfMemory, .locked = true }, freeWord);
}

// ---------------------------------------------------------------------------
// Slots

pub const SessionSlot = struct {
    word: std.atomic.Value(u64) = .init(pack(1, .free)),
    /// Over the fields consumers fill; never held across a wait.
    lock: std.atomic.Mutex = .unlocked,
    /// Streams `anole_wt_open_stream` asked for, to open in order.
    opens: std.ArrayList(*StreamSlot) = .empty,
    /// Datagrams to send, oldest first; its capacity is the route's
    /// `datagram_queue`, set when the session opens, so nothing is
    /// allocated or freed under `lock` (`pushNewest`, `putBackOldest`).
    datagrams: std.Deque([]u8) = .empty,
    close_code: ?u32 = null,
    close_reason: []u8 = &.{},
    /// `kick` is in the executor's inbox (never posted twice).
    kick_pending: bool = false,
    /// The largest datagram the session takes now (0: none), for
    /// consumers to check against.
    max_datagram: usize = 0,

    // Executor-local from here.
    session: ?*Session = null,
    route: *const Route = undefined,
    exec: *Exec = undefined,
    index: u32 = 0,
    next_free: u32 = engine.no_slot,
    kick: Command = .{ .run = runKick },
    /// The streams it has handed out, open or waiting to open.
    streams: std.ArrayList(*StreamSlot) = .empty,
    drain_posted: bool = false,

    fn gen(s: *const SessionSlot) u32 {
        return @intCast(s.word.load(.acquire) >> 32);
    }
    fn live(s: *const SessionSlot, g: u32) bool {
        return s.word.load(.acquire) == pack(g, .open);
    }
    fn handle(s: *const SessionSlot, g: u32) u64 {
        return Handle.encode(.{ .gen = @intCast(g), .kind = .wt_session, .slot = @intCast(s.index), .exec = s.exec.index });
    }

    /// Wakes the session's task.
    fn wake(s: *SessionSlot) void {
        spin(&s.lock);
        const post = !s.kick_pending;
        s.kick_pending = true;
        s.lock.unlock();
        if (post) s.exec.post(&s.kick);
    }

    /// Under `lock`: queues `d` behind the others; when the queue is
    /// full, the oldest makes room and is returned, for the caller to
    /// free (after unlocking) and count.
    fn pushNewest(s: *SessionSlot, d: []u8) ?[]u8 {
        const dropped = if (s.datagrams.len == s.datagrams.buffer.len) s.datagrams.popFront() else null;
        s.datagrams.pushBackBounded(d) catch unreachable;
        return dropped;
    }

    /// Under `lock`: puts `d`, just taken from the front, back there.
    /// False when consumers filled the queue meanwhile: `d` is the
    /// oldest, for the caller to drop.
    fn putBackOldest(s: *SessionSlot, d: []u8) bool {
        s.datagrams.pushFrontBounded(d) catch return false;
        return true;
    }

    /// Datagrams out, oldest first, moved into the connection's queue
    /// one at a time; the lock is held only to take one or put it back.
    /// At most a queue's worth per round, so consumers that keep sending
    /// don't hold the rest of the round back. `session` has
    /// `trySendDatagramOwned` (a `*Session`; a fake in the test), `a` is
    /// what the datagrams came from (`gpa`). True when one moved.
    fn flushDatagrams(s: *SessionSlot, session: anytype, a: std.mem.Allocator, dropped: *std.atomic.Value(u64)) bool {
        var moved_any = false;
        for (0..s.datagrams.buffer.len) |_| {
            spin(&s.lock);
            const next = s.datagrams.popFront();
            s.lock.unlock();
            const d = next orelse break;
            const moved = session.trySendDatagramOwned(d) catch |err| {
                a.free(d);
                switch (err) {
                    error.DatagramTooLarge, error.OutOfMemory => _ = dropped.fetchAdd(1, .monotonic),
                    // The session is over: the rest are dropped with it.
                    else => {},
                }
                continue;
            };
            if (!moved) {
                // The connection's queue is full: it waits in front, unless
                // consumers filled the slot meanwhile; then it is the oldest
                // and goes.
                spin(&s.lock);
                const kept = s.putBackOldest(d);
                s.lock.unlock();
                if (!kept) {
                    a.free(d);
                    _ = dropped.fetchAdd(1, .monotonic);
                }
                break;
            }
            moved_any = true;
        }
        return moved_any;
    }

    fn clear(s: *SessionSlot) void {
        while (s.datagrams.popFront()) |d| gpa.free(d);
        s.datagrams.deinit(gpa);
        s.opens.deinit(gpa);
        gpa.free(s.close_reason);
        s.close_reason = &.{};
        s.streams.deinit(gpa);
    }
};

/// A consumer's memory passed with `ANOLE_BODY_BORROW`, and the handle it
/// was passed with (`ANOLE_EV_SENT` names it).
const Borrowed = struct { handle: u64, data: []const u8, sent: []align(8) u8 };

pub const StreamSlot = struct {
    word: std.atomic.Value(u64) = .init(pack(1, .free)),
    lock: std.atomic.Mutex = .unlocked,
    /// Set when it is handed out, then fixed until it is free again.
    session: *SessionSlot = undefined,
    dir: enum { bidi, uni_in, uni_out } = .bidi,

    // Under `lock`, from consumers:
    /// Bytes to send, after those the task holds (`sending`).
    out: std.ArrayList(u8) = .empty,
    /// Bytes waiting to go into the stream: `out` and `sending`.
    bytes: usize = 0,
    /// Send the end after the bytes.
    fin: bool = false,
    reset_code: ?u32 = null,
    stop_code: ?u32 = null,
    /// A new urgency (0..7) for the executor to apply to the stream.
    priority: ?u3 = null,
    released: bool = false,
    /// A write got ANOLE_BUSY: ANOLE_EV_WRITABLE when there is room.
    want_writable: bool = false,
    /// The sending side is over (stopped by the peer, reset, the session
    /// gone): writes are refused.
    send_over: bool = false,
    /// Writes made with `ANOLE_BODY_BORROW`: copied into `out` already,
    /// owed an `ANOLE_EV_SENT` (posted by the executor, `postBorrowed`).
    borrowed: std.ArrayList(Borrowed) = .empty,

    // Executor-local from here.
    stream: ?*Stream = null,
    exec: *Exec = undefined,
    index: u32 = 0,
    next_free: u32 = engine.no_slot,
    /// Bytes taken from `out`, going into the stream.
    sending: std.ArrayList(u8) = .empty,
    sent_off: usize = 0,
    recv_done: bool = false,
    send: Send = .open,

    /// The executor's view of the sending half.
    const Send = enum {
        /// Bytes (and the end, if asked for) may still go into the stream.
        open,
        /// The end went out after every byte.
        finished,
        /// Over without the end: reset by us, stopped by the peer, the
        /// session gone, or no sending half at all (`uni_in`).
        over,
    };

    fn gen(s: *const StreamSlot) u32 {
        return @intCast(s.word.load(.acquire) >> 32);
    }
    fn live(s: *const StreamSlot, g: u32) bool {
        return s.word.load(.acquire) == pack(g, .open);
    }
    fn handle(s: *const StreamSlot, g: u32) u64 {
        return Handle.encode(.{ .gen = @intCast(g), .kind = .wt_stream, .slot = @intCast(s.index), .exec = s.exec.index });
    }

    fn clear(s: *StreamSlot) void {
        s.out.deinit(gpa);
        s.sending.deinit(gpa);
        for (s.borrowed.items) |b| engine.freeRecord(b.sent.ptr);
        s.borrowed.deinit(gpa);
    }

    /// `ANOLE_EV_SENT` for the borrowed writes taken so far (they were
    /// copied when taken). On the executor; before the slot is freed, so
    /// none is lost.
    fn postBorrowed(s: *StreamSlot) void {
        spin(&s.lock);
        if (s.borrowed.items.len == 0) {
            s.lock.unlock();
            return;
        }
        var list = s.borrowed;
        s.borrowed = .empty;
        s.lock.unlock();
        defer list.deinit(gpa);
        for (list.items) |b| s.exec.postSentRec(b.handle, b.sent);
    }

    /// Frees the slot (`ANOLE_EV_SENT` first for what it borrowed).
    fn free(s: *StreamSlot) void {
        s.postBorrowed();
        s.exec.wt.streams.free(s);
    }

    /// Takes the slot for a stream of `session`; the caller makes it open.
    fn reset(s: *StreamSlot, session: *SessionSlot, dir: @FieldType(StreamSlot, "dir")) void {
        s.out.clearRetainingCapacity();
        s.sending.clearRetainingCapacity();
        s.session = session;
        s.dir = dir;
        s.bytes = 0;
        s.fin = false;
        s.reset_code = null;
        s.stop_code = null;
        s.priority = null;
        s.released = false;
        s.want_writable = false;
        s.send_over = dir == .uni_in;
        s.stream = null;
        s.sent_off = 0;
        s.recv_done = dir == .uni_out;
        s.send = if (dir == .uni_in) .over else .open;
    }
};

pub const ExecState = struct {
    sessions: Table(SessionSlot) = .{},
    streams: Table(StreamSlot) = .{},

    /// The highest generation of any slot (`Engine.destroy`).
    pub fn maxGen(st: *const ExecState) u32 {
        return @max(st.sessions.maxGen(), st.streams.maxGen());
    }

    pub fn deinit(st: *ExecState) void {
        st.sessions.deinit(SessionSlot.clear);
        st.streams.deinit(StreamSlot.clear);
    }
};

fn sessionOf(e: *Engine, hv: u64) engine.HandleError!struct { *SessionSlot, u32 } {
    const h = Handle.decode(hv);
    if (hv == 0 or h.gen == 0 or h.kind != .wt_session) return error.WrongKind;
    if (h.exec >= e.execs.len) return error.Over;
    const s = e.execs[h.exec].wt.sessions.slot(h.slot) orelse return error.Over;
    return .{ s, h.gen };
}

fn streamOf(e: *Engine, hv: u64) engine.HandleError!struct { *StreamSlot, u32 } {
    const h = Handle.decode(hv);
    if (hv == 0 or h.gen == 0 or h.kind != .wt_stream) return error.WrongKind;
    if (h.exec >= e.execs.len) return error.Over;
    const s = e.execs[h.exec].wt.streams.slot(h.slot) orelse return error.Over;
    return .{ s, h.gen };
}

fn newRecord(size: usize, typ: abi.EventType, h: u64) ![]align(8) u8 {
    return engine.newRecord(size, typ, h);
}

fn runKick(cmd: *Command, _: *Exec) void {
    const s: *SessionSlot = @fieldParentPtr("kick", cmd);
    spin(&s.lock);
    s.kick_pending = false;
    s.lock.unlock();
    if (s.session) |session| Session.Driver.wake(session);
}

// ---------------------------------------------------------------------------
// The route: accepts, then runs the session until it ends.

pub fn handler(req: *dusty.Request, res: *dusty.Response) anyerror!void {
    const route: *const Route = @ptrCast(@alignCast(req.route.?.data.?));
    const e = route.engine;
    const xi = placement.currentExecutor(req.io) orelse return error.InternalServerError;
    const x = &e.execs[xi];
    if (x.consumer == null) return res.fail(.service_unavailable, "no consumer");
    const opts = route.wt.?;
    const session = (try webtransport.accept(req, res, opts.accept)) orelse
        return res.fail(.bad_request, "this endpoint speaks WebTransport over HTTP/3");
    defer session.deinit();
    // Datagrams move from the slot's queue into the session's as they
    // are: both must be the engine's allocator. The vtable says which; in
    // release builds `gpa` is `smp_allocator`, whose `ptr` is undefined.
    std.debug.assert(session.allocator().vtable == gpa.vtable);

    var queue = std.Deque([]u8).initCapacity(gpa, @max(opts.datagram_queue, 1)) catch return;
    const s = x.wt.sessions.alloc(x) catch {
        queue.deinit(gpa);
        return;
    };
    const g = s.gen();
    s.route = route;
    s.session = session;
    s.drain_posted = false;
    spin(&s.lock);
    s.close_code = null;
    s.max_datagram = session.maxDatagramSize();
    s.datagrams = queue;
    s.lock.unlock();
    s.word.store(pack(g, .open), .release);
    _ = e.wt_sessions.fetchAdd(1, .monotonic);
    defer _ = e.wt_sessions.fetchSub(1, .monotonic);

    var remote: [64]u8 = undefined;
    const head: engine.Head = .{
        .req = req,
        .route_id = route.id,
        .flags = abi.REQ_SECURE,
        .remote = remote[0..engine.remoteText(req, &remote)],
        .claims = engine.claimsOf(req),
    };
    if (engine.allocRecord(head.size())) |rec| {
        _ = head.encode(.wt_open, s.handle(g), rec);
        x.postRecord(rec, true);
    } else |_| {}

    const result = drive(s, g, session);
    finish(s, g, session);
    return result;
}

/// Runs the session until it closes (or the task is canceled).
fn drive(s: *SessionSlot, g: u32, session: *Session) std.Io.Cancelable!void {
    const x = s.exec;
    const e = x.engine;
    const high = e.stream_high_water;
    var buf: [32 * 1024]u8 = undefined;
    while (true) {
        const change = Session.Driver.generation(session);
        var progress = false;

        // What consumers asked of the session.
        spin(&s.lock);
        const opens = s.opens;
        s.opens = .empty;
        const close_code = s.close_code;
        const reason = s.close_reason;
        s.close_reason = &.{};
        s.lock.unlock();
        if (close_code != null) {
            defer gpa.free(reason);
            session.close(close_code.?, reason) catch {};
            progress = true;
        }
        for (opens.items) |st| {
            s.streams.append(gpa, st) catch {
                abandon(st);
                continue;
            };
        }
        var opens_list = opens;
        opens_list.deinit(gpa);
        if (s.flushDatagrams(session, gpa, &e.wt_datagrams_dropped)) progress = true;

        // The peer's new streams.
        inline for (.{ Session.Driver.Direction.bidi, Session.Driver.Direction.uni }) |dir| {
            while (Session.Driver.tryAccept(session, dir)) |stream| {
                progress = true;
                adopt(s, g, stream, if (dir == .bidi) .bidi else .uni_in);
            }
        }

        // Datagrams in.
        while (session.takeDatagram()) |d| {
            defer session.freeDatagram(d);
            progress = true;
            const size = @sizeOf(abi.WtDatagramEvent) + d.len;
            const rec = newRecord(size, .wt_datagram, s.handle(g)) catch continue;
            const ev: *abi.WtDatagramEvent = @ptrCast(rec.ptr);
            ev.route_id = s.route.id;
            ev.data = .{ .off = @sizeOf(abi.WtDatagramEvent), .len = @intCast(d.len) };
            @memcpy(rec[@sizeOf(abi.WtDatagramEvent)..][0..d.len], d);
            x.postRecord(rec, true);
        }

        // Each stream: what the consumer asked, what the peer sent.
        var i: usize = 0;
        while (i < s.streams.items.len) {
            const st = s.streams.items[i];
            if (serveStream(s, st, session, &buf, high, &progress)) {
                i += 1;
            } else {
                _ = s.streams.swapRemove(i);
            }
        }

        if (!s.drain_posted and session.draining()) {
            s.drain_posted = true;
            progress = true;
            postSmall(x, .wt_drain, s.handle(g));
        }
        if (!session.isOpen()) return;
        const max = session.maxDatagramSize();
        spin(&s.lock);
        s.max_datagram = max;
        s.lock.unlock();
        if (!progress) try Session.Driver.waitChange(session, change);
        try std.Io.checkCancel(e.io);
    }
}

/// A stream the peer opened: a slot, and ANOLE_EV_WT_STREAM.
fn adopt(s: *SessionSlot, g: u32, stream: *Stream, dir: @FieldType(StreamSlot, "dir")) void {
    const x = s.exec;
    const st = x.wt.streams.alloc(x) catch return stream.release();
    st.reset(s, dir);
    st.stream = stream;
    s.streams.append(gpa, st) catch {
        st.free();
        return stream.release();
    };
    const sg = st.gen();
    st.word.store(pack(sg, .open), .release);
    const rec = newRecord(@sizeOf(abi.WtStreamEvent), .wt_stream, st.handle(sg)) catch return;
    const ev: *abi.WtStreamEvent = @ptrCast(rec.ptr);
    ev.route_id = s.route.id;
    ev.flags = if (dir == .uni_in) abi.WT_F_UNI else 0;
    ev.session = s.handle(g);
    x.postRecord(rec, true);
}

/// One round for a stream; false once its slot is free again (released).
fn serveStream(s: *SessionSlot, st: *StreamSlot, session: *Session, buf: []u8, high: usize, progress: *bool) bool {
    const x = s.exec;
    const sg = st.gen();
    const h = st.handle(sg);
    st.postBorrowed();

    // Not opened yet (the peer's limit): try again.
    if (st.stream == null) {
        spin(&st.lock);
        // Released before it opened: only its end still matters.
        const drop = st.released and !st.fin;
        st.lock.unlock();
        if (drop) {
            st.free();
            return false;
        }
        const stream = Session.Driver.tryOpen(session, if (st.dir == .bidi) .bidi else .uni) catch {
            // The session is over: it ends with it.
            return true;
        } orelse return true;
        st.stream = stream;
        progress.* = true;
    }
    const stream = st.stream.?;

    spin(&st.lock);
    if (st.sent_off == st.sending.items.len) {
        st.sending.clearRetainingCapacity();
        st.sent_off = 0;
        std.mem.swap(std.ArrayList(u8), &st.out, &st.sending);
    }
    const fin = st.fin;
    const reset_code = st.reset_code;
    st.reset_code = null;
    const stop_code = st.stop_code;
    st.stop_code = null;
    const priority = st.priority;
    st.priority = null;
    const released = st.released;
    st.lock.unlock();
    if (priority) |p| Stream.Driver.setPriority(stream, p);

    // Released with its end asked for: what was written still goes out
    // first, then the stream is let go.
    const let_go = switch (st.send) {
        .open => released and !fin,
        .finished, .over => released,
    };
    if (let_go) {
        stream.release();
        st.stream = null;
        st.free();
        progress.* = true;
        return false;
    }
    if (reset_code) |code| if (st.send == .open) {
        stream.reset(code);
        st.send = .over;
        dropOutput(st, if (released) 0 else h);
        progress.* = true;
    };
    if (stop_code) |code| if (!st.recv_done) {
        stream.stopSending(code);
        st.recv_done = true;
        progress.* = true;
    };

    // Out.
    if (st.send == .open) {
        var wrote: usize = 0;
        var failed = false;
        while (st.sent_off < st.sending.items.len) {
            const n = Stream.Driver.tryWrite(stream, st.sending.items[st.sent_off..]) catch {
                failed = true;
                break;
            };
            if (n == 0) break;
            st.sent_off += n;
            wrote += n;
        }
        if (wrote > 0) progress.* = true;
        var writable = false;
        spin(&st.lock);
        st.bytes -|= wrote;
        if (st.want_writable and st.bytes <= high / 2) {
            st.want_writable = false;
            writable = true;
        }
        const all_out = st.bytes == 0;
        st.lock.unlock();
        if (writable and !released) postSmall(x, .writable, h);
        if (!failed and fin and all_out) {
            stream.closeSend() catch {};
            st.send = .finished;
            progress.* = true;
        }
        const send_err = Stream.Driver.sendError(stream);
        if (st.send == .open and (failed or send_err != null)) {
            // Stopped by the peer, or the session went.
            st.send = .over;
            dropOutput(st, if (released) 0 else h);
            if (!released and send_err != null and send_err.? == error.StreamStopped) {
                postCode(x, .wt_stream_stop, h, stream.stopCode() orelse 0);
                progress.* = true;
            }
        }
    }

    if (released) switch (st.send) {
        .finished, .over => {
            stream.release();
            st.stream = null;
            st.free();
            progress.* = true;
            return false;
        },
        // Nobody reads it any more.
        .open => return true,
    };

    // In: a chunk per round, so one stream does not hold up the others.
    if (!st.recv_done) {
        const r = Stream.Driver.tryRead(stream, buf);
        if (r.n > 0 or r.fin) {
            progress.* = true;
            const size = @sizeOf(abi.WtDataEvent) + r.n;
            if (newRecord(size, .wt_data, h)) |rec| {
                const ev: *abi.WtDataEvent = @ptrCast(rec.ptr);
                ev.flags = if (r.fin) abi.WT_F_FIN else 0;
                ev.data = .{ .off = @sizeOf(abi.WtDataEvent), .len = @intCast(r.n) };
                @memcpy(rec[@sizeOf(abi.WtDataEvent)..][0..r.n], buf[0..r.n]);
                x.postRecord(rec, true);
            } else |_| {}
            if (r.fin) st.recv_done = true;
        } else if (r.err) |err| {
            st.recv_done = true;
            progress.* = true;
            // The session's end says it for every stream.
            if (err != error.SessionClosed and err != error.ConnectionClosed)
                postCode(x, .wt_stream_reset, h, stream.resetCode() orelse 0);
        }
    }
    return true;
}

/// What waits to be sent goes: the sending side is over. A consumer
/// waiting for room hears it (ANOLE_EV_WRITABLE; its next write is
/// ANOLE_E_GONE).
fn dropOutput(st: *StreamSlot, h: u64) void {
    st.sending.clearRetainingCapacity();
    st.sent_off = 0;
    spin(&st.lock);
    st.out.clearRetainingCapacity();
    st.bytes = 0;
    st.send_over = true;
    const wake = st.want_writable;
    st.want_writable = false;
    st.lock.unlock();
    if (wake and h != 0) postSmall(st.exec, .writable, h);
}

/// A stream slot of a session that is gone, never opened.
fn abandon(st: *StreamSlot) void {
    spin(&st.lock);
    st.word.store(pack(engine.nextGen(st.gen()), .free), .release);
    st.lock.unlock();
    st.free();
}

/// The session is over: its handles go stale, ANOLE_EV_WT_CLOSE.
fn finish(s: *SessionSlot, g: u32, session: *Session) void {
    const x = s.exec;
    spin(&s.lock);
    s.word.store(pack(engine.nextGen(g), .free), .release);
    const opens = s.opens;
    s.opens = .empty;
    var datagrams = s.datagrams;
    s.datagrams = .empty;
    const reason = s.close_reason;
    s.close_reason = &.{};
    s.close_code = null;
    s.lock.unlock();
    gpa.free(reason);
    while (datagrams.popFront()) |d| gpa.free(d);
    datagrams.deinit(gpa);
    for (opens.items) |st| abandon(st);
    var ol = opens;
    ol.deinit(gpa);
    for (s.streams.items) |st| {
        spin(&st.lock);
        st.word.store(pack(engine.nextGen(st.gen()), .free), .release);
        st.out.clearRetainingCapacity();
        st.bytes = 0;
        st.lock.unlock();
        // Session.deinit lets go of every stream the session had.
        st.stream = null;
        st.sending.clearRetainingCapacity();
        st.free();
    }
    s.streams.clearRetainingCapacity();
    s.session = null;

    const info = session.closeInfo() orelse webtransport.CloseInfo{ .code = 0, .reason = "", .by = .connection };
    const size = @sizeOf(abi.WtCloseEvent) + info.reason.len;
    if (newRecord(size, .wt_close, s.handle(g))) |rec| {
        const ev: *abi.WtCloseEvent = @ptrCast(rec.ptr);
        ev.route_id = s.route.id;
        ev.code = info.code;
        ev.by = switch (info.by) {
            .local => abi.WT_CLOSED_LOCAL,
            .peer => abi.WT_CLOSED_PEER,
            .connection => abi.WT_CLOSED_CONNECTION,
        };
        ev.reason = .{ .off = @sizeOf(abi.WtCloseEvent), .len = @intCast(info.reason.len) };
        @memcpy(rec[@sizeOf(abi.WtCloseEvent)..][0..info.reason.len], info.reason);
        x.postRecord(rec, true);
    } else |_| {}
    x.wt.sessions.free(s);
}

/// A small event that must arrive (it waits for room in the ring).
fn postSmall(x: *Exec, typ: abi.EventType, h: u64) void {
    const rec = newRecord(@sizeOf(abi.Event), typ, h) catch return;
    x.postRecord(rec, true);
}

fn postCode(x: *Exec, typ: abi.EventType, h: u64, code: u32) void {
    const rec = newRecord(@sizeOf(abi.WtCodeEvent), typ, h) catch return;
    const ev: *abi.WtCodeEvent = @ptrCast(rec.ptr);
    ev.code = code;
    x.postRecord(rec, true);
}

// ---------------------------------------------------------------------------
// From consumers

/// Opens a stream of the session (`uni`: write-only). The handle is good
/// at once: what is written waits until the stream opens (the peer's
/// stream limit may hold it).
pub fn openStream(e: *Engine, hv: u64, uni: bool) engine.AnswerError!u64 {
    const s, const g = sessionOf(e, hv) catch |err| return e.badHandle(err);
    const x = s.exec;
    spin(&s.lock);
    if (!s.live(g) or s.close_code != null) {
        s.lock.unlock();
        return e.gone();
    }
    const st = x.wt.streams.alloc(x) catch {
        s.lock.unlock();
        return error.OutOfMemory;
    };
    st.reset(s, if (uni) .uni_out else .bidi);
    s.opens.append(gpa, st) catch {
        s.lock.unlock();
        // A consumer thread: nothing was written to it, so no SENT is owed.
        x.wt.streams.free(st);
        return error.OutOfMemory;
    };
    const sg = st.gen();
    st.word.store(pack(sg, .open), .release);
    s.lock.unlock();
    s.wake();
    return st.handle(sg);
}

/// Queues `data` (and, with `fin`, the end after it); true when the
/// stream is past its high-water mark (ANOLE_EV_WRITABLE follows). The
/// bytes are copied; with `borrow` (`ANOLE_BODY_BORROW`) the consumer also
/// gets `ANOLE_EV_SENT` for them, as for every borrowing call, so one
/// borrow rule holds everywhere.
pub fn write(e: *Engine, hv: u64, data: []const u8, fin: bool, borrow: bool) engine.AnswerError!bool {
    const st, const g = streamOf(e, hv) catch |err| return e.badHandle(err);
    // The SENT record first: a write that fails takes nothing.
    const sent: ?[]align(8) u8 = if (borrow) try engine.newSent(data) else null;
    errdefer if (sent) |r| engine.freeRecord(r.ptr);
    spin(&st.lock);
    if (!st.live(g)) {
        st.lock.unlock();
        return e.gone();
    }
    if (st.dir == .uni_in or st.fin) {
        st.lock.unlock();
        return error.Invalid;
    }
    if (st.send_over) {
        st.lock.unlock();
        return e.gone();
    }
    if (borrow) st.borrowed.ensureUnusedCapacity(gpa, 1) catch {
        st.lock.unlock();
        return error.OutOfMemory;
    };
    st.out.appendSlice(gpa, data) catch {
        st.lock.unlock();
        return error.OutOfMemory;
    };
    if (borrow) st.borrowed.appendAssumeCapacity(.{ .handle = hv, .data = data, .sent = sent.? });
    st.bytes += data.len;
    if (fin) st.fin = true;
    const busy = st.bytes > e.stream_high_water;
    if (busy) st.want_writable = true;
    const session = st.session;
    st.lock.unlock();
    session.wake();
    return busy;
}

/// Sets the stream's urgency (0 most urgent, 7 least, 3 the default; RFC
/// 9218) for its next packets.
pub fn setPriority(e: *Engine, hv: u64, urgency: u3) engine.AnswerError!void {
    const st, const g = streamOf(e, hv) catch |err| return e.badHandle(err);
    spin(&st.lock);
    if (!st.live(g)) {
        st.lock.unlock();
        return e.gone();
    }
    if (st.dir == .uni_in) {
        st.lock.unlock();
        return error.Invalid;
    }
    st.priority = urgency;
    const session = st.session;
    st.lock.unlock();
    session.wake();
}

pub const Op = enum { reset, stop, release };

/// Resets the sending side, asks the peer to stop sending, or lets go of
/// the stream (resetting what is unfinished; the handle is stale at once).
pub fn streamOp(e: *Engine, hv: u64, op: Op, code: u32) engine.AnswerError!void {
    const st, const g = try streamOf(e, hv);
    spin(&st.lock);
    if (!st.live(g)) {
        st.lock.unlock();
        return error.Over;
    }
    switch (op) {
        .reset => {
            if (st.dir == .uni_in) {
                st.lock.unlock();
                return error.Invalid;
            }
            st.reset_code = code;
            st.send_over = true;
            st.out.clearRetainingCapacity();
        },
        .stop => {
            if (st.dir == .uni_out) {
                st.lock.unlock();
                return error.Invalid;
            }
            st.stop_code = code;
        },
        .release => {
            st.released = true;
            st.word.store(pack(engine.nextGen(g), .free), .release);
        },
    }
    const session = st.session;
    st.lock.unlock();
    session.wake();
}

/// Queues a datagram. The session keeps `datagram_queue` of them waiting;
/// past it the oldest is dropped (a datagram that waits goes stale). With
/// `borrow` the bytes are copied all the same, and `ANOLE_EV_SENT` follows
/// once the copy is queued.
pub fn sendDatagram(e: *Engine, hv: u64, data: []const u8, borrow: bool) engine.AnswerError!void {
    const s, const g = sessionOf(e, hv) catch |err| return e.badHandle(err);
    const sent: ?[]align(8) u8 = if (borrow) try engine.newSent(data) else null;
    errdefer if (sent) |r| engine.freeRecord(r.ptr);
    const copy = try gpa.dupe(u8, data);
    spin(&s.lock);
    if (!s.live(g) or s.close_code != null) {
        s.lock.unlock();
        gpa.free(copy);
        return e.gone();
    }
    if (data.len > s.max_datagram) {
        s.lock.unlock();
        gpa.free(copy);
        return error.TooBig;
    }
    const dropped = s.pushNewest(copy);
    s.lock.unlock();
    if (dropped) |d| {
        gpa.free(d);
        _ = e.wt_datagrams_dropped.fetchAdd(1, .monotonic);
    }
    if (sent) |r| s.exec.postSentRec(hv, r);
    s.wake();
}

/// The largest datagram the session takes now; 0 when the peer takes
/// none.
pub fn maxDatagram(e: *Engine, hv: u64) engine.AnswerError!usize {
    const s, const g = sessionOf(e, hv) catch |err| return e.badHandle(err);
    spin(&s.lock);
    defer s.lock.unlock();
    if (!s.live(g)) return e.gone();
    return s.max_datagram;
}

/// Closes the session with an application code and a reason (at most
/// 1024 bytes); ANOLE_EV_WT_CLOSE follows.
pub fn close(e: *Engine, hv: u64, code: u32, reason: []const u8) engine.AnswerError!void {
    if (reason.len > 1024) return error.Invalid;
    const s, const g = try sessionOf(e, hv);
    const copy = try gpa.dupe(u8, reason);
    spin(&s.lock);
    if (!s.live(g) or s.close_code != null) {
        s.lock.unlock();
        gpa.free(copy);
        return error.Over;
    }
    s.close_code = code;
    gpa.free(s.close_reason);
    s.close_reason = copy;
    s.lock.unlock();
    s.wake();
}

test "capi engine: WebTransport: a session's datagram queue keeps the newest and puts a held one back in front" {
    const t = std.testing.allocator;
    var s: SessionSlot = .{};
    s.datagrams = try .initCapacity(t, 4);
    defer {
        while (s.datagrams.popFront()) |d| t.free(d);
        s.datagrams.deinit(t);
    }
    var name: [8]u8 = undefined;
    // Ten into four: the six oldest come back, in order.
    for (0..10) |i| {
        const d = try t.dupe(u8, try std.fmt.bufPrint(&name, "{d}", .{i}));
        if (s.pushNewest(d)) |old| {
            defer t.free(old);
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&name, "{d}", .{i - 4}), old);
        } else try std.testing.expect(i < 4);
    }
    try std.testing.expectEqual(@as(usize, 4), s.datagrams.len);
    try std.testing.expectEqualStrings("6", s.datagrams.front().?);

    // Held by the flush while a consumer refills the queue: it is the
    // oldest, so it is the one to go.
    const held = s.datagrams.popFront().?;
    try std.testing.expectEqualStrings("6", held);
    const d10 = try t.dupe(u8, "10");
    try std.testing.expectEqual(@as(?[]u8, null), s.pushNewest(d10));
    try std.testing.expect(!s.putBackOldest(held));
    t.free(held);

    // With room, it goes back in front.
    const again = s.datagrams.popFront().?;
    try std.testing.expectEqualStrings("7", again);
    try std.testing.expect(s.putBackOldest(again));
    try std.testing.expectEqualStrings("7", s.datagrams.front().?);
    try std.testing.expectEqual(@as(usize, 4), s.datagrams.len);
}

test "capi engine: WebTransport: the datagram flush moves, puts back, drops and counts, allocating nothing" {
    var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const a = fa.allocator();
    var s: SessionSlot = .{};
    s.datagrams = try .initCapacity(a, 4);
    defer {
        while (s.datagrams.popFront()) |d| a.free(d);
        s.datagrams.deinit(a);
    }
    var dropped: std.atomic.Value(u64) = .init(0);
    var name: [8]u8 = undefined;

    // The connection's queue: takes `room`, then is full. On the first
    // full answer it can play a consumer that refills the slot.
    const Fake = struct {
        slot: *SessionSlot,
        room: usize,
        refill: ?[]u8 = null,
        got: [8][]u8 = undefined,
        n: usize = 0,
        fn trySendDatagramOwned(f: *@This(), d: []u8) error{ SessionClosed, DatagramTooLarge, OutOfMemory }!bool {
            if (std.mem.eql(u8, d, "big")) return error.DatagramTooLarge;
            if (f.n == f.room) {
                if (f.refill) |r| {
                    f.refill = null;
                    spin(&f.slot.lock);
                    std.debug.assert(f.slot.pushNewest(r) == null);
                    f.slot.lock.unlock();
                }
                return false;
            }
            f.got[f.n] = d;
            f.n += 1;
            return true;
        }
    };

    // Ten sends into four, as `sendDatagram` does: one allocation each,
    // the six oldest dropped and counted.
    const before_sends = fa.allocations;
    for (0..10) |i| {
        const d = try a.dupe(u8, try std.fmt.bufPrint(&name, "{d}", .{i}));
        spin(&s.lock);
        const old = s.pushNewest(d);
        s.lock.unlock();
        if (old) |o| {
            a.free(o);
            _ = dropped.fetchAdd(1, .monotonic);
        }
    }
    try std.testing.expectEqual(@as(usize, 10), fa.allocations - before_sends);
    try std.testing.expectEqual(@as(u64, 6), dropped.load(.monotonic));

    // The connection's queue is full: the held one goes back in front.
    var full: Fake = .{ .slot = &s, .room = 0 };
    var allocs = fa.allocations;
    try std.testing.expect(!s.flushDatagrams(&full, a, &dropped));
    try std.testing.expectEqual(allocs, fa.allocations);
    try std.testing.expectEqual(@as(usize, 4), s.datagrams.len);
    try std.testing.expectEqualStrings("6", s.datagrams.front().?);
    try std.testing.expectEqual(@as(u64, 6), dropped.load(.monotonic));

    // Full, and a consumer refills the slot meanwhile: the held one is
    // now the oldest, so it is dropped and counted.
    var refilled: Fake = .{ .slot = &s, .room = 0, .refill = try a.dupe(u8, "10") };
    const big = try a.dupe(u8, "big");
    allocs = fa.allocations;
    const frees = fa.deallocations;
    try std.testing.expect(!s.flushDatagrams(&refilled, a, &dropped));
    try std.testing.expectEqual(allocs, fa.allocations);
    try std.testing.expectEqual(frees + 1, fa.deallocations);
    try std.testing.expectEqual(@as(u64, 7), dropped.load(.monotonic));
    try std.testing.expectEqualStrings("7", s.datagrams.front().?);

    // One too large behind the rest: the others move in order, it is
    // dropped and counted, and nothing is left.
    spin(&s.lock);
    const seven = s.pushNewest(big).?;
    s.lock.unlock();
    a.free(seven);
    _ = dropped.fetchAdd(1, .monotonic);
    var open: Fake = .{ .slot = &s, .room = 8 };
    defer for (open.got[0..open.n]) |d| a.free(d);
    allocs = fa.allocations;
    try std.testing.expect(s.flushDatagrams(&open, a, &dropped));
    try std.testing.expectEqual(allocs, fa.allocations);
    try std.testing.expectEqual(@as(usize, 3), open.n);
    for (open.got[0..open.n], [_][]const u8{ "8", "9", "10" }) |d, want| try std.testing.expectEqualStrings(want, d);
    try std.testing.expectEqual(@as(u64, 9), dropped.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), s.datagrams.len);
}
