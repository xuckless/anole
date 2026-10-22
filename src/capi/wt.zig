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

fn spin(l: *std.atomic.Mutex) void {
    while (!l.tryLock()) std.atomic.spinLoopHint();
}

/// Slots of one kind on one executor: grown a chunk at a time, never
/// moved or freed until the engine goes.
fn Table(comptime T: type) type {
    return struct {
        const Self = @This();
        const chunk_len = 256;
        const max_chunks = 4096;
        const Chunk = [chunk_len]T;

        chunks: [max_chunks]std.atomic.Value(?*Chunk) = @splat(.init(null)),
        nchunks: u32 = 0,
        free_head: u32 = engine.no_slot,
        lock: std.atomic.Mutex = .unlocked,

        fn slot(t: *Self, i: u32) ?*T {
            // `i` may come from a made-up handle: past the table is nothing.
            if (i / chunk_len >= max_chunks) return null;
            const c = t.chunks[i / chunk_len].load(.acquire) orelse return null;
            return &c[i % chunk_len];
        }

        fn alloc(t: *Self, x: *Exec) !*T {
            spin(&t.lock);
            defer t.lock.unlock();
            if (t.free_head == engine.no_slot) {
                if (t.nchunks == max_chunks) return error.OutOfMemory;
                const c = try gpa.create(Chunk);
                const base = t.nchunks * chunk_len;
                for (c, 0..) |*s, j| s.* = .{
                    .word = .init(pack(x.engine.first_gen, .free)),
                    .exec = x,
                    .index = @intCast(base + j),
                    .next_free = if (j + 1 < chunk_len) @intCast(base + j + 1) else engine.no_slot,
                };
                t.chunks[t.nchunks].store(c, .release);
                t.nchunks += 1;
                t.free_head = base;
            }
            const s = t.slot(t.free_head).?;
            t.free_head = s.next_free;
            return s;
        }

        fn free(t: *Self, s: *T) void {
            spin(&t.lock);
            defer t.lock.unlock();
            s.next_free = t.free_head;
            t.free_head = s.index;
        }

        fn maxGen(t: *const Self) u32 {
            var max: u32 = 0;
            for (t.chunks[0..t.nchunks]) |*cv| {
                for (cv.load(.acquire).?) |*s| max = @max(max, s.gen());
            }
            return max;
        }

        fn deinit(t: *Self) void {
            for (t.chunks[0..t.nchunks]) |*cv| {
                const c = cv.load(.acquire).?;
                for (c) |*s| s.clear();
                gpa.destroy(c);
            }
            t.nchunks = 0;
        }
    };
}

// ---------------------------------------------------------------------------
// Slots

pub const SessionSlot = struct {
    word: std.atomic.Value(u64) = .init(pack(1, .free)),
    /// Over the fields consumers fill; never held across a wait.
    lock: std.atomic.Mutex = .unlocked,
    /// Streams `anole_wt_open_stream` asked for, to open in order.
    opens: std.ArrayList(*StreamSlot) = .empty,
    datagrams: std.ArrayList([]u8) = .empty,
    close_code: ?u32 = null,
    close_reason: []u8 = &.{},
    /// `kick` is in the executor's inbox (never posted twice).
    kick_pending: bool = false,
    /// The largest datagram the session takes now (0: none), for
    /// consumers to check against.
    max_datagram: usize = 0,
    /// The route's `datagram_queue`.
    datagram_queue: u32 = 0,

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

    fn clear(s: *SessionSlot) void {
        for (s.datagrams.items) |d| gpa.free(d);
        s.datagrams.deinit(gpa);
        s.opens.deinit(gpa);
        gpa.free(s.close_reason);
        s.close_reason = &.{};
        s.streams.deinit(gpa);
    }
};

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
    released: bool = false,
    /// A write got ANOLE_BUSY: ANOLE_EV_WRITABLE when there is room.
    want_writable: bool = false,
    /// The sending side is over (stopped by the peer, reset, the session
    /// gone): writes are refused.
    send_over: bool = false,

    // Executor-local from here.
    stream: ?*Stream = null,
    exec: *Exec = undefined,
    index: u32 = 0,
    next_free: u32 = engine.no_slot,
    /// Bytes taken from `out`, going into the stream.
    sending: std.ArrayList(u8) = .empty,
    sent_off: usize = 0,
    recv_done: bool = false,
    send_done: bool = false,
    fin_done: bool = false,

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
        s.released = false;
        s.want_writable = false;
        s.send_over = dir == .uni_in;
        s.stream = null;
        s.sent_off = 0;
        s.recv_done = dir == .uni_out;
        s.send_done = dir == .uni_in;
        s.fin_done = false;
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
        st.sessions.deinit();
        st.streams.deinit();
    }
};

fn sessionOf(e: *Engine, hv: u64) ?struct { *SessionSlot, u32 } {
    const h = Handle.decode(hv);
    if (h.gen == 0 or h.kind != .wt_session or h.exec >= e.execs.len) return null;
    const s = e.execs[h.exec].wt.sessions.slot(h.slot) orelse return null;
    return .{ s, h.gen };
}

fn streamOf(e: *Engine, hv: u64) ?struct { *StreamSlot, u32 } {
    const h = Handle.decode(hv);
    if (h.gen == 0 or h.kind != .wt_stream or h.exec >= e.execs.len) return null;
    const s = e.execs[h.exec].wt.streams.slot(h.slot) orelse return null;
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
    if (s.session) |session| session.wake();
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

    const s = x.wt.sessions.alloc(x) catch return;
    const g = s.gen();
    s.route = route;
    s.session = session;
    s.drain_posted = false;
    spin(&s.lock);
    s.close_code = null;
    s.max_datagram = session.maxDatagramSize();
    s.datagram_queue = opts.datagram_queue;
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
    if (gpa.alignedAlloc(u8, .@"8", head.size())) |rec| {
        _ = head.encode(.wt_open, s.handle(g), rec);
        x.postRecord(rec, true);
    } else |_| {}

    const result = drive(s, g, session, opts);
    finish(s, g, session);
    return result;
}

/// Runs the session until it closes (or the task is canceled).
fn drive(s: *SessionSlot, g: u32, session: *Session, opts: Options) std.Io.Cancelable!void {
    const x = s.exec;
    const e = x.engine;
    const high = e.stream_high_water;
    var buf: [32 * 1024]u8 = undefined;
    while (true) {
        const change = session.generation();
        var progress = false;

        // What consumers asked of the session.
        spin(&s.lock);
        const opens = s.opens;
        s.opens = .empty;
        var datagrams = s.datagrams;
        s.datagrams = .empty;
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
        var sent: usize = 0;
        for (datagrams.items) |d| {
            const ok = session.trySendDatagram(d) catch |err| switch (err) {
                error.DatagramTooLarge, error.OutOfMemory => blk: {
                    _ = e.wt_datagrams_dropped.fetchAdd(1, .monotonic);
                    break :blk true;
                },
                else => blk: {
                    // The session is over: the rest are dropped with it.
                    break :blk true;
                },
            };
            if (!ok) break;
            gpa.free(d);
            sent += 1;
        }
        if (sent < datagrams.items.len) {
            // The connection's queue is full: the rest wait, in front of
            // any queued since, within the session's bound.
            spin(&s.lock);
            const later = s.datagrams;
            s.datagrams = .empty;
            s.datagrams.appendSlice(gpa, datagrams.items[sent..]) catch {};
            s.datagrams.appendSlice(gpa, later.items) catch {};
            var l = later;
            l.deinit(gpa);
            while (s.datagrams.items.len > opts.datagram_queue) {
                gpa.free(s.datagrams.orderedRemove(0));
                _ = e.wt_datagrams_dropped.fetchAdd(1, .monotonic);
            }
            s.lock.unlock();
        } else if (sent > 0) progress = true;
        datagrams.deinit(gpa);

        // The peer's new streams.
        inline for (.{ Session.Direction.bidi, Session.Direction.uni }) |dir| {
            while (session.tryAccept(dir)) |stream| {
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
        if (!progress) try session.waitChange(change);
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
        x.wt.streams.free(st);
        return stream.release();
    };
    const sg = st.gen();
    st.word.store(pack(sg, .open), .release);
    const rec = newRecord(@sizeOf(abi.WtStreamEvent), .wt_stream, st.handle(sg)) catch return;
    const ev: *abi.WtStreamEvent = @ptrCast(rec.ptr);
    ev.route_id = s.route.id;
    ev.flags = if (dir == .uni_in) abi.WT_UNI else 0;
    ev.session = s.handle(g);
    x.postRecord(rec, true);
}

/// One round for a stream; false once its slot is free again (released).
fn serveStream(s: *SessionSlot, st: *StreamSlot, session: *Session, buf: []u8, high: usize, progress: *bool) bool {
    const x = s.exec;
    const sg = st.gen();
    const h = st.handle(sg);

    // Not opened yet (the peer's limit): try again.
    if (st.stream == null) {
        spin(&st.lock);
        // Released before it opened: only its end still matters.
        const drop = st.released and !st.fin;
        st.lock.unlock();
        if (drop) {
            x.wt.streams.free(st);
            return false;
        }
        const stream = session.tryOpen(if (st.dir == .bidi) .bidi else .uni) catch {
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
    const released = st.released;
    st.lock.unlock();

    // Released with its end asked for: what was written still goes out
    // first, then the stream is let go.
    if (released and (st.send_done or !fin)) {
        stream.release();
        st.stream = null;
        x.wt.streams.free(st);
        progress.* = true;
        return false;
    }
    if (reset_code) |code| if (!st.send_done) {
        stream.reset(code);
        st.send_done = true;
        dropOutput(st, if (released) 0 else h);
        progress.* = true;
    };
    if (stop_code) |code| if (!st.recv_done) {
        stream.stopSending(code);
        st.recv_done = true;
        progress.* = true;
    };

    // Out.
    if (!st.send_done) {
        var wrote: usize = 0;
        var failed = false;
        while (st.sent_off < st.sending.items.len) {
            const n = stream.tryWrite(st.sending.items[st.sent_off..]) catch {
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
        if (!failed and fin and all_out and !st.fin_done) {
            stream.closeSend() catch {};
            st.fin_done = true;
            st.send_done = true;
            progress.* = true;
        }
        const send_err = stream.sendError();
        if (!st.fin_done and (failed or send_err != null)) {
            // Stopped by the peer, or the session went.
            st.send_done = true;
            dropOutput(st, if (released) 0 else h);
            if (!released and send_err != null and send_err.? == error.StreamStopped) {
                postCode(x, .wt_stream_stop, h, stream.stopCode() orelse 0);
                progress.* = true;
            }
        }
    }

    if (released) {
        if (st.send_done) {
            stream.release();
            st.stream = null;
            x.wt.streams.free(st);
            progress.* = true;
            return false;
        }
        // Nobody reads it any more.
        return true;
    }

    // In: a chunk per round, so one stream does not hold up the others.
    if (!st.recv_done) {
        const r = stream.tryRead(buf);
        if (r.n > 0 or r.fin) {
            progress.* = true;
            const size = @sizeOf(abi.WtDataEvent) + r.n;
            if (newRecord(size, .wt_data, h)) |rec| {
                const ev: *abi.WtDataEvent = @ptrCast(rec.ptr);
                ev.flags = if (r.fin) abi.WT_FIN else 0;
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
    const x = st.exec;
    spin(&st.lock);
    st.word.store(pack(engine.nextGen(st.gen()), .free), .release);
    st.lock.unlock();
    x.wt.streams.free(st);
}

/// The session is over: its handles go stale, ANOLE_EV_WT_CLOSE.
fn finish(s: *SessionSlot, g: u32, session: *Session) void {
    const x = s.exec;
    spin(&s.lock);
    s.word.store(pack(engine.nextGen(g), .free), .release);
    const opens = s.opens;
    s.opens = .empty;
    for (s.datagrams.items) |d| gpa.free(d);
    s.datagrams.clearAndFree(gpa);
    gpa.free(s.close_reason);
    s.close_reason = &.{};
    s.close_code = null;
    s.lock.unlock();
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
        x.wt.streams.free(st);
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
    const s, const g = sessionOf(e, hv) orelse return e.gone();
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
/// stream is past its high-water mark (ANOLE_EV_WRITABLE follows).
pub fn write(e: *Engine, hv: u64, data: []const u8, fin: bool) engine.AnswerError!bool {
    const st, const g = streamOf(e, hv) orelse return e.gone();
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
    st.out.appendSlice(gpa, data) catch {
        st.lock.unlock();
        return error.OutOfMemory;
    };
    st.bytes += data.len;
    if (fin) st.fin = true;
    const busy = st.bytes > e.stream_high_water;
    if (busy) st.want_writable = true;
    const session = st.session;
    st.lock.unlock();
    session.wake();
    return busy;
}

pub const Op = enum { reset, stop, release };

/// Resets the sending side, asks the peer to stop sending, or lets go of
/// the stream (resetting what is unfinished; the handle is stale at once).
pub fn streamOp(e: *Engine, hv: u64, op: Op, code: u32) engine.AnswerError!void {
    const st, const g = streamOf(e, hv) orelse return e.gone();
    spin(&st.lock);
    if (!st.live(g)) {
        st.lock.unlock();
        return e.gone();
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
/// past it the oldest is dropped (a datagram that waits goes stale).
pub fn sendDatagram(e: *Engine, hv: u64, data: []const u8) engine.AnswerError!void {
    const s, const g = sessionOf(e, hv) orelse return e.gone();
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
    s.datagrams.append(gpa, copy) catch {
        s.lock.unlock();
        gpa.free(copy);
        return error.OutOfMemory;
    };
    var dropped: u64 = 0;
    while (s.datagrams.items.len > s.datagram_queue) {
        gpa.free(s.datagrams.orderedRemove(0));
        dropped += 1;
    }
    s.lock.unlock();
    if (dropped > 0) _ = e.wt_datagrams_dropped.fetchAdd(dropped, .monotonic);
    s.wake();
}

/// The largest datagram the session takes now; 0 when the peer takes
/// none.
pub fn maxDatagram(e: *Engine, hv: u64) engine.AnswerError!usize {
    const s, const g = sessionOf(e, hv) orelse return e.gone();
    spin(&s.lock);
    defer s.lock.unlock();
    if (!s.live(g)) return e.gone();
    return s.max_datagram;
}

/// Closes the session with an application code and a reason (at most
/// 1024 bytes); ANOLE_EV_WT_CLOSE follows.
pub fn close(e: *Engine, hv: u64, code: u32, reason: []const u8) engine.AnswerError!void {
    if (reason.len > 1024) return error.Invalid;
    const s, const g = sessionOf(e, hv) orelse return e.gone();
    const copy = try gpa.dupe(u8, reason);
    spin(&s.lock);
    if (!s.live(g) or s.close_code != null) {
        s.lock.unlock();
        gpa.free(copy);
        return e.gone();
    }
    s.close_code = code;
    gpa.free(s.close_reason);
    s.close_reason = copy;
    s.lock.unlock();
    s.wake();
}
