//! `anole_net_*`: raw TCP and UDP listeners whose connections and datagrams
//! go to a consumer (p3/net, design-net.md §6.4). Handle kinds 10
//! (`anole_net_conn`) and 11 (`anole_net_udp`); events 96-100.
//!
//! The listeners are Anole's own (`anole.net`): the configuration's "tcp"
//! and "udp" keys become `net.TcpService` / `net.UdpService` whose callbacks
//! (below) turn each connection event into a record for the consumer's ring,
//! on the connection's own executor and task. Writes come back by handle
//! from any thread: into the connection's outbox (`Conn.send`), which the
//! net driver of its executor writes, so the consumer never waits for a
//! peer. A connection posts at most `read_ahead` bytes the consumer has not
//! polled (the credit, below); the rest waits in the kernel.
//!
//! Each executor keeps a table of connection slots, grown a chunk at a time
//! and never moved or freed while the engine lives, so a stale
//! `anole_net_conn` always lands on a slot whose generation says it is
//! gone. A UDP socket's handle is made of the listener's ordinal and the
//! socket's index (nothing is allocated for it).
const std = @import("std");
const anole = @import("../root.zig");
const dusty = @import("dusty");
const safety = @import("anole_safety");
const abi = @import("abi.zig");
const engine = @import("engine.zig");
const config_mod = @import("config.zig");
const net = anole.net;
const placement = dusty.placement;
const Engine = engine.Engine;
const Exec = engine.Exec;
const Handle = engine.Handle;
const AnswerError = engine.AnswerError;
const gpa = engine.gpa;
/// The writes' chunks come from it: in Debug and test builds an allocation
/// or a free under a slot's spin lock panics (L5); elsewhere it is `gpa`.
var chunk_checked: safety.SpinCheckedAllocator = .init(engine.gpa);

const chunk_len = 256;
const max_chunks = 4096;
comptime {
    std.debug.assert(chunk_len * max_chunks <= engine.max_slots);
}

/// The most a DATA record holds of one connection's bytes: bigger bursts
/// come as several records (a frame larger than this in one of its own).
const max_data_record = 64 * 1024;

const SlotState = enum(u32) { free, open };

fn pack(g: u32, st: SlotState) u64 {
    return (@as(u64, g) << 32) | @backingInt(st);
}

pub const NetSlot = struct {
    word: std.atomic.Value(u64) = .init(pack(1, .free)),
    /// Over `conn`: a call from a consumer thread holds it while it uses
    /// the connection, `onClose` while it takes it away. A leaf (L4):
    /// nothing is taken, allocated, freed or woken under it but the
    /// connection's atomics (a reset's non-blocking `setsockopt`/`shutdown`
    /// and its gated wakes); a call's chunk is made before it and, when the
    /// connection refuses it, freed after it (`chunk_checked` panics
    /// otherwise in Debug and tests); its kick is made after it.
    lock: safety.SpinLock(.leaf) = .init,
    conn: ?*net.Conn = null,
    state: *TcpState = undefined,
    /// Bytes of this connection posted and not yet polled.
    unpolled: std.atomic.Value(u32) = .init(0),
    /// A futex word: 1 while the connection's task waits for credit.
    credit_wait: std.atomic.Value(u32) = .init(0),
    exec: *Exec = undefined,
    index: u32 = 0,
    next_free: u32 = engine.no_slot,

    fn acquire(s: *NetSlot) void {
        s.lock.lock();
    }
    fn release(s: *NetSlot) void {
        s.lock.unlock();
    }
    fn gen(s: *const NetSlot) u32 {
        return @intCast(s.word.load(.acquire) >> 32);
    }
    fn live(s: *const NetSlot, g: u32) bool {
        return s.word.load(.acquire) == pack(g, .open);
    }
    fn handle(s: *const NetSlot, g: u32) u64 {
        return Handle.encode(.{ .gen = @intCast(g), .kind = .net_conn, .slot = @intCast(s.index), .exec = s.exec.index });
    }
};

const Chunk = [chunk_len]NetSlot;

/// Per executor (`Exec.net`).
pub const ExecState = struct {
    chunks: [max_chunks]std.atomic.Value(?*Chunk) = @splat(.init(null)),
    nchunks: u32 = 0,
    free_head: u32 = engine.no_slot,

    fn slot(st: *ExecState, i: u32) ?*NetSlot {
        // `i` may come from a made-up handle: past the table is no connection.
        if (i / chunk_len >= max_chunks) return null;
        const c = st.chunks[i / chunk_len].load(.acquire) orelse return null;
        return &c[i % chunk_len];
    }

    fn alloc(st: *ExecState, x: *Exec) !*NetSlot {
        if (st.free_head == engine.no_slot) {
            if (st.nchunks == max_chunks) return error.TooManyConnections;
            const c = try gpa.create(Chunk);
            const base = st.nchunks * chunk_len;
            for (c, 0..) |*s, j| s.* = .{
                .word = .init(pack(x.engine.first_gen, .free)),
                .exec = x,
                .index = @intCast(base + j),
                .next_free = if (j + 1 < chunk_len) @intCast(base + j + 1) else engine.no_slot,
            };
            st.chunks[st.nchunks].store(c, .release);
            st.nchunks += 1;
            st.free_head = base;
        }
        const s = st.slot(st.free_head).?;
        st.free_head = s.next_free;
        return s;
    }

    /// The tasks it runs (the net drivers) belong to the server's group and
    /// end with it.
    pub fn cancel(st: *ExecState, io: std.Io) void {
        _ = st;
        _ = io;
    }

    /// The highest generation handed out (`Engine.destroy`).
    pub fn maxGen(st: *const ExecState) u32 {
        var max: u32 = 0;
        for (st.chunks[0..st.nchunks]) |*cv| {
            for (cv.load(.acquire).?) |*s| max = @max(max, s.gen());
        }
        return max;
    }

    pub fn deinit(st: *ExecState) void {
        for (st.chunks[0..st.nchunks]) |*cv| gpa.destroy(cv.load(.acquire).?);
        st.nchunks = 0;
    }
};

/// A "tcp" listener's settings, the `state` of its service.
pub const TcpState = struct {
    engine: *Engine,
    handler_id: u32,
    read_ahead: u32,
    framing: u32,
};

/// A "udp" listener's settings, the `state` of its service.
pub const UdpState = struct {
    engine: *Engine,
    handler_id: u32,
    ordinal: u32,
    max_datagram: u16,
    /// Set once the sockets exist (the first batch, or the start), cleared
    /// at the stop before they are freed.
    group: std.atomic.Value(?*net.UdpGroup) = .init(null),
    /// The calls from consumer threads inside the group (T5): closed at the
    /// stop, which waits for those inside. A send queues its batch inside
    /// it (the batch's one allocation included): short, never a wait.
    gate: safety.IoGate = .{},

    fn enter(u: *UdpState) ?*net.UdpGroup {
        if (!u.gate.enter()) return null;
        return u.group.load(.acquire) orelse {
            u.gate.leave();
            return null;
        };
    }

    fn leave(u: *UdpState) void {
        u.gate.leave();
    }
};

/// Engine-wide state (`Engine.net_state`).
pub const State = struct {
    first_gen: u32 = 1,
    conns: std.atomic.Value(u64) = .init(0),
    bytes_in: std.atomic.Value(u64) = .init(0),
    bytes_out: std.atomic.Value(u64) = .init(0),
    /// The "udp" listeners, by ordinal (engine arena).
    udps: std.ArrayList(*UdpState) = .empty,

    pub fn init(s: *State, first_gen: u32) void {
        s.* = .{ .first_gen = first_gen };
    }

    /// The highest generation handed out (`Engine.destroy`).
    pub fn maxGen(s: *State) u32 {
        return s.first_gen;
    }

    pub fn deinit(s: *State) void {
        _ = s;
    }
};

// ---------------------------------------------------------------------------
// The services, from the configuration

fn framingConst(f: ?config_mod.Config.NetFraming) u32 {
    return switch (config_mod.netFraming(f)) {
        .none => abi.NET_FRAMING_NONE,
        .lines => abi.NET_FRAMING_LINES,
        .length => abi.NET_FRAMING_LENGTH,
        .varint => abi.NET_FRAMING_VARINT,
    };
}

/// The service of a "tcp" listener.
pub fn tcpService(e: *Engine, a: std.mem.Allocator, t: config_mod.Config.NetTcp) !net.TcpService {
    const st = try a.create(TcpState);
    st.* = .{ .engine = e, .handler_id = t.handler, .read_ahead = t.read_ahead, .framing = framingConst(t.framing) };
    return .{
        .table = &tcp_table,
        .options = .{
            .framing = config_mod.netFraming(t.framing),
            .half_open = t.half_open,
            .no_delay = t.no_delay,
            .keepalive = config_mod.netMs(t.keepalive_ms),
            .handshake_timeout = config_mod.netMs(t.handshake_timeout_ms),
            .idle_timeout = config_mod.netMs(t.idle_timeout_ms),
            .lifetime = config_mod.netMs(t.lifetime_ms),
            .write_timeout = config_mod.netMs(t.write_timeout_ms),
            .write_high_water = t.write_high_water,
            .write_max = t.write_max,
            .read_window = t.read_window,
            .read_ahead = t.read_ahead,
            .max_connections = t.max_connections,
            .log_connections = t.log_connections,
        },
        .ctx_type = @typeName(void),
        .state = st,
    };
}

/// The service of a "udp" listener; `ordinal` counts the UDP listeners.
pub fn udpService(e: *Engine, a: std.mem.Allocator, u: config_mod.Config.NetUdp) !net.UdpService {
    const st = try a.create(UdpState);
    st.* = .{ .engine = e, .handler_id = u.handler, .ordinal = @intCast(e.net_state.udps.items.len), .max_datagram = u.max_datagram };
    try e.net_state.udps.append(a, st);
    return .{
        .table = &udp_table,
        .options = .{
            .sockets = u.sockets,
            .max_datagram = u.max_datagram,
            .batch = u.batch,
            .send_queue = u.send_queue,
            .receive_buffer = u.receive_buffer,
            .send_buffer = u.send_buffer,
        },
        .ctx_type = @typeName(void),
        .state = st,
    };
}

/// The configuration's listener index of the core's listener `core_i`
/// (UDP listeners are not the core's).
pub fn configIndex(e: *const Engine, core_i: usize) usize {
    var n: usize = 0;
    for (e.config.listeners, 0..) |l, i| {
        if (l.udp != null) continue;
        if (n == core_i) return i;
        n += 1;
    }
    return e.config.listeners.len;
}

/// After the server listens: the UDP listeners' bound ports and sockets.
pub fn opened(e: *Engine, app: *anole.App) void {
    var ordinal: usize = 0;
    for (e.config.listeners, e.listeners) |lc, *l| {
        if (lc.udp == null) continue;
        defer ordinal += 1;
        for (app.net_udp.items) |g| {
            if (!std.mem.eql(u8, g.name, l.name)) continue;
            l.port = 0;
            l.udp_port = g.address().getPort();
            var w: std.Io.Writer = .fixed(&l.bound_buf);
            w.print("{f}", .{g.address()}) catch {};
            l.bound_len = @intCast(w.end);
            e.net_state.udps.items[ordinal].group.store(g, .release);
        }
    }
}

/// Before the sockets are freed: no call is inside them, none gets in.
pub fn close(e: *Engine) void {
    for (e.net_state.udps.items) |u| {
        u.group.store(null, .release);
        u.gate.close();
    }
}

// ---------------------------------------------------------------------------
// TCP callbacks (on the connection's task, on its executor)

const tcp_table: net.TcpTable = .{
    .open = onOpen,
    .data = onData,
    .end = onEnd,
    .writable = onWritable,
    .close = onClose,
    .sent = onSent,
    .inline_events = true,
};

fn execOf(e: *Engine) ?*Exec {
    const xi = placement.currentExecutor(e.io) orelse return null;
    return &e.execs[xi];
}

fn slotOfConn(conn: *net.Conn) ?*NetSlot {
    return @ptrCast(@alignCast(conn.context orelse return null));
}

fn fillAddr(a: *abi.NetAddr, ip: ?std.Io.net.IpAddress) void {
    a.* = .{};
    const addr = ip orelse return;
    switch (addr) {
        .ip4 => |v| {
            a.family = 4;
            a.port = v.port;
            @memcpy(a.addr[0..4], &v.bytes);
        },
        .ip6 => |v| {
            a.family = 6;
            a.port = v.port;
            a.scope_id = v.interface.index;
            a.addr = v.bytes;
        },
    }
}

fn onOpen(state: ?*anyopaque, conn: *net.Conn) anyerror!void {
    const st: *TcpState = @ptrCast(@alignCast(state.?));
    const e = st.engine;
    const x = execOf(e) orelse return error.Unexpected;
    const slot = try x.net.alloc(x);
    const g = slot.gen();
    slot.acquire();
    slot.conn = conn;
    slot.release();
    slot.state = st;
    slot.unpolled.store(0, .monotonic);
    slot.credit_wait.store(0, .monotonic);
    conn.context = slot;
    slot.word.store(pack(g, .open), .release);
    _ = e.net_state.conns.fetchAdd(1, .monotonic);

    const remote = conn.remote();
    const local = conn.local();
    var text_buf: [64]u8 = undefined;
    var remote_text: []const u8 = "";
    if (remote) |r| if (!conn.isUnix()) {
        var w: std.Io.Writer = .fixed(&text_buf);
        if (r.format(&w)) |_| remote_text = w.buffered() else |_| {}
    };
    const listener = conn.listener();
    const alpn = conn.alpn() orelse "";
    const sni = conn.serverName() orelse "";
    const cert = conn.peerCertificate() orelse "";
    const size = abi.alignUp(@sizeOf(abi.NetOpenEvent) + listener.len + remote_text.len + alpn.len + sni.len + cert.len);
    const rec = try engine.newRecord(size, .net_open, slot.handle(g));
    const ev: *abi.NetOpenEvent = @ptrCast(rec.ptr);
    ev.handler_id = st.handler_id;
    ev.flags = (if (conn.isTls()) abi.NET_OPEN_F_TLS else 0) |
        (if (cert.len > 0) abi.NET_OPEN_F_PEER_CERT else 0) |
        (if (conn.proxied()) abi.NET_OPEN_F_PROXIED else 0) |
        (if (conn.secure()) abi.NET_OPEN_F_SECURE else 0) |
        (if (conn.isUnix()) abi.NET_OPEN_F_UNIX else 0);
    fillAddr(&ev.remote, if (conn.isUnix()) null else remote);
    fillAddr(&ev.local, local);
    var at: u32 = @sizeOf(abi.NetOpenEvent);
    inline for (.{ .{ "listener", listener }, .{ "remote_text", remote_text }, .{ "alpn", alpn }, .{ "server_name", sni }, .{ "peer_cert", cert } }) |f| {
        const bytes: []const u8 = f[1];
        @field(ev, f[0]) = .{ .off = at, .len = @intCast(bytes.len) };
        @memcpy(rec[at..][0..bytes.len], bytes);
        at += @intCast(bytes.len);
    }
    ev.framing = st.framing;
    x.postRecord(rec, true);
}

/// Waits until this connection's unpolled bytes leave room for `need` more:
/// the credit a poll returns. One record may always exceed it when nothing
/// else is waiting.
fn awaitCredit(e: *Engine, slot: *NetSlot, need: u32, limit: u32) error{Canceled}!void {
    while (true) {
        const cur = slot.unpolled.load(.seq_cst);
        if (cur == 0 or cur +| need <= limit) return;
        slot.credit_wait.store(1, .seq_cst);
        const again = slot.unpolled.load(.seq_cst);
        if (again == 0 or again +| need <= limit) return;
        e.io.futexWait(u32, &slot.credit_wait.raw, 1) catch return error.Canceled;
    }
}

/// A record `frames` make: the spans, then the bytes.
fn postData(x: *Exec, slot: *NetSlot, g: u32, frames: []const []const u8, framed: bool) !void {
    const e = x.engine;
    var total: usize = 0;
    for (frames) |f| total += f.len;
    const spans_off: u32 = @sizeOf(abi.NetDataEvent);
    const bytes_off = spans_off + frames.len * @sizeOf(abi.Span);
    const rec = try engine.newRecord(bytes_off + total, .net_data, slot.handle(g));
    const ev: *abi.NetDataEvent = @ptrCast(rec.ptr);
    ev.flags = if (framed) abi.NET_DATA_F_FRAMES else 0;
    ev.nframes = @intCast(frames.len);
    ev.frames_off = spans_off;
    var at: usize = bytes_off;
    for (frames, 0..) |f, i| {
        const sp: *abi.Span = @ptrCast(@alignCast(rec[spans_off + i * @sizeOf(abi.Span) ..].ptr));
        sp.* = .{ .off = @intCast(at), .len = @intCast(f.len) };
        @memcpy(rec[at..][0..f.len], f);
        at += f.len;
    }
    const len: u32 = @intCast(rec.len);
    awaitCredit(e, slot, len, slot.state.read_ahead) catch {
        engine.freeRecord(rec.ptr);
        return error.Canceled;
    };
    _ = slot.unpolled.fetchAdd(len, .seq_cst);
    x.postRecord(rec, true);
}

fn onData(state: ?*anyopaque, conn: *net.Conn, input: net.Input) anyerror!void {
    _ = state;
    const slot = slotOfConn(conn) orelse return;
    const x = slot.exec;
    const g = slot.gen();
    switch (input) {
        .bytes => |b| {
            var rest = b;
            while (rest.len > 0) {
                const n = @min(rest.len, max_data_record);
                try postData(x, slot, g, &.{rest[0..n]}, false);
                rest = rest[n..];
            }
        },
        .frames => |it| {
            // Records of up to 64 KiB of frames; a bigger frame by itself.
            var from: usize = 0;
            var bytes: usize = 0;
            for (it.frames, 0..) |f, i| {
                if (bytes > 0 and bytes + f.len > max_data_record) {
                    try postData(x, slot, g, it.frames[from..i], true);
                    from = i;
                    bytes = 0;
                }
                bytes += f.len;
            }
            if (from < it.frames.len) try postData(x, slot, g, it.frames[from..], true);
        },
    }
}

fn onEnd(state: ?*anyopaque, conn: *net.Conn) anyerror!void {
    _ = state;
    const slot = slotOfConn(conn) orelse return;
    const rec = try engine.newRecord(@sizeOf(abi.Event), .net_end, slot.handle(slot.gen()));
    slot.exec.postRecord(rec, true);
}

fn onWritable(state: ?*anyopaque, conn: *net.Conn) anyerror!void {
    _ = state;
    const slot = slotOfConn(conn) orelse return;
    slot.exec.postEvent(.writable, slot.handle(slot.gen()));
}

fn onSent(state: ?*anyopaque, conn: *net.Conn, token: u64) void {
    _ = state;
    const slot = slotOfConn(conn) orelse return;
    // The record the borrowing call built: its header says how long it is.
    const first: [*]align(8) u8 = @ptrFromInt(token);
    const ev: *const abi.Event = @ptrCast(first);
    slot.exec.postSentRec(slot.handle(slot.gen()), first[0..ev.len]);
}

fn reasonConst(r: net.CloseReason) u32 {
    return switch (r) {
        .peer => abi.NET_CLOSED_PEER,
        .local => abi.NET_CLOSED_LOCAL,
        .reset => abi.NET_CLOSED_RESET,
        .failed => abi.NET_CLOSED_FAILED,
        .idle => abi.NET_CLOSED_IDLE,
        .write_timeout => abi.NET_CLOSED_WRITE_TIMEOUT,
        .lifetime => abi.NET_CLOSED_LIFETIME,
        .frame => abi.NET_CLOSED_FRAME,
        .drain => abi.NET_CLOSED_DRAIN,
        .server => abi.NET_CLOSED_SERVER,
    };
}

fn reasonToken(r: net.CloseReason) []const u8 {
    return switch (r) {
        .reset => "ConnectionReset",
        .failed => "Failed",
        .frame => "InvalidFrame",
        .write_timeout => "WriteTimeout",
        .server => "OutOfMemory",
        else => "",
    };
}

fn onClose(state: ?*anyopaque, conn: *net.Conn, reason: net.CloseReason) void {
    _ = state;
    const slot = slotOfConn(conn) orelse return;
    const x = slot.exec;
    const e = x.engine;
    const g = slot.gen();
    const h = slot.handle(g);
    const totals = conn.totals();
    // Stale from here: the consumer's calls get ANOLE_E_GONE, or are over.
    slot.acquire();
    slot.word.store(pack(engine.nextGen(g), .free), .release);
    slot.conn = null;
    slot.release();
    conn.context = null;
    slot.credit_wait.store(0, .seq_cst);
    slot.exec.wakeFutex(&slot.credit_wait);
    slot.unpolled.store(0, .monotonic);
    slot.next_free = x.net.free_head;
    x.net.free_head = slot.index;
    _ = e.net_state.conns.fetchSub(1, .monotonic);
    _ = e.net_state.bytes_in.fetchAdd(totals.bytes_in, .monotonic);
    _ = e.net_state.bytes_out.fetchAdd(totals.bytes_out, .monotonic);

    const token = reasonToken(reason);
    const rec = engine.newRecord(@sizeOf(abi.NetCloseEvent) + token.len, .net_close, h) catch return;
    const ev: *abi.NetCloseEvent = @ptrCast(rec.ptr);
    ev.reason = reasonConst(reason);
    ev.error_errno = if (reason == .reset or reason == .failed) totals.errno else 0;
    ev.bytes_in = totals.bytes_in;
    ev.bytes_out = totals.bytes_out;
    ev.duration_ms = totals.duration_ms;
    ev.@"error" = .{ .off = @sizeOf(abi.NetCloseEvent), .len = @intCast(token.len) };
    @memcpy(rec[@sizeOf(abi.NetCloseEvent)..][0..token.len], token);
    x.postRecord(rec, true);
}

/// The poll hook: a DATA record of `len` bytes was copied out, so its
/// connection may post that much more.
pub fn polled(e: *Engine, hv: u64, len: u32) void {
    const slot, const g = slotOf(e, hv) catch return;
    if (slot.gen() != g) return;
    // Saturating: a stale decrement must not wrap.
    var cur = slot.unpolled.load(.monotonic);
    while (true) {
        const next = cur -| len;
        cur = slot.unpolled.cmpxchgWeak(cur, next, .seq_cst, .monotonic) orelse break;
    }
    if (slot.credit_wait.load(.seq_cst) != 0) {
        slot.credit_wait.store(0, .seq_cst);
        slot.exec.wakeFutex(&slot.credit_wait);
    }
}

// ---------------------------------------------------------------------------
// Calls from consumer threads

fn slotOf(e: *Engine, hv: u64) engine.HandleError!struct { *NetSlot, u32 } {
    const h = Handle.decode(hv);
    if (hv == 0 or h.gen == 0 or h.kind != .net_conn) return error.WrongKind;
    if (h.exec >= e.execs.len) return error.Over;
    const s = e.execs[h.exec].net.slot(h.slot) orelse return error.Over;
    return .{ s, h.gen };
}

/// Why the last `Invalid` answer on this thread was one: the token and text
/// `anole_last_error` shows.
pub threadlocal var invalid_token: []const u8 = "Invalid";
pub threadlocal var invalid_text: []const u8 = "invalid argument";

fn invalid(token: []const u8, text: []const u8) error{Invalid} {
    invalid_token = token;
    invalid_text = text;
    return error.Invalid;
}

/// `anole_net_write`: true when the outbox is past its high-water mark
/// (ANOLE_BUSY).
pub fn write(e: *Engine, hv: u64, data: []const u8, flags: u32) AnswerError!bool {
    const s, const g = slotOf(e, hv) catch |err| return e.badHandle(err);
    const borrow = flags & abi.BODY_BORROW != 0;
    const frame = flags & abi.NET_F_FRAME != 0;
    // A framed or empty write is copied (there is nothing to borrow): its
    // SENT follows at once, when the call took it.
    const copy = frame or data.len == 0;
    // The SENT record first: a call that fails takes nothing.
    const sent: ?[]align(8) u8 = if (borrow) try engine.newSent(data) else null;
    errdefer if (sent) |r| engine.freeRecord(r.ptr);
    // The chunk before the lock (L5): nothing allocates under it, and one
    // the call did not take is freed here, after it.
    var chunk: ?*net.OutChunk = null;
    defer if (chunk) |c| c.destroy();
    if (sent != null and !copy) {
        chunk = try net.OutChunk.borrowed(chunk_checked.allocator(), data, @intFromPtr(sent.?.ptr));
    } else if (frame or data.len > 0) {
        const c = try net.OutChunk.create(chunk_checked.allocator(), data.len);
        @memcpy(c.payload(), data);
        chunk = c;
    }
    // The wakes are made after the lock is let go.
    var kicks: [2]?net.Kick = .{ null, null };
    const result: net.Conn.Sent = locked: {
        s.acquire();
        defer s.release();
        const conn = s.conn orelse return e.gone();
        if (!s.live(g)) return e.gone();
        var r: net.Conn.Sent = .ok;
        if (chunk) |c| {
            // Taken on success; refused, it stays `chunk`.
            const q = conn.queueChunk(c, frame) catch |err| return writeError(e, err);
            if (q.taken) chunk = null;
            r = q.sent;
            kicks[0] = q.kick;
        } else {
            // Empty: the checks only.
            _ = conn.send("") catch |err| return writeError(e, err);
        }
        if (flags & abi.NET_F_END != 0) kicks[1] = conn.endKick();
        break :locked r;
    };
    // After the unlock the connection may be gone; the kicks touch only its
    // driver and kick slot, which the server frees at destroy. That rests
    // on the ABI's rule: anole_server_destroy overlaps nothing on its
    // server (anole.h), so no anole_net_* call is running then.
    for (kicks) |k| if (k) |kick| kick.run();
    if (sent) |rec| if (copy) s.exec.postSentRec(s.handle(g), rec);
    return result == .busy;
}

fn writeError(e: *Engine, err: net.Conn.SendError) AnswerError {
    return switch (err) {
        error.Closed => e.gone(),
        error.Ended => invalid("Ended", "this side of the connection was ended already (ANOLE_NET_F_END, or a close)"),
        error.NoFraming => invalid("NoFraming", "ANOLE_NET_F_FRAME on a listener without framing"),
        error.FrameTooLarge => invalid("FrameTooLarge", "the payload is over the listener's framing max"),
        error.QueueFull => error.Again,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// `anole_net_close`: a cleanup call.
pub fn closeConn(e: *Engine, hv: u64, how: u32) AnswerError!void {
    if (how != abi.NET_CLOSE_GRACEFUL and how != abi.NET_CLOSE_RESET) return error.Invalid;
    const s, const g = try slotOf(e, hv);
    const kick = locked: {
        s.acquire();
        defer s.release();
        const conn = s.conn orelse return error.Over;
        if (!s.live(g)) return error.Over;
        break :locked if (how == abi.NET_CLOSE_RESET) conn.resetKick() else conn.closeKick();
    };
    // After the unlock: see `write`'s kicks.
    if (kick) |k| k.run();
}

pub fn pause(e: *Engine, hv: u64, on: bool) AnswerError!void {
    const s, const g = slotOf(e, hv) catch |err| return e.badHandle(err);
    s.acquire();
    defer s.release();
    const conn = s.conn orelse return e.gone();
    if (!s.live(g)) return e.gone();
    if (on) conn.pauseReading() else conn.resumeReading();
}

pub fn setIdleTimeout(e: *Engine, hv: u64, ms: u32) AnswerError!void {
    const s, const g = slotOf(e, hv) catch |err| return e.badHandle(err);
    s.acquire();
    defer s.release();
    const conn = s.conn orelse return e.gone();
    if (!s.live(g)) return e.gone();
    conn.setIdleTimeout(if (ms == 0) null else std.Io.Duration.fromMilliseconds(ms));
}

/// `anole_handle_release` for the kinds `net_conn` and `net_udp` (a cleanup call: a handle that is
/// over answers `error.Over`, which is `ANOLE_OK`).
pub fn release(e: *Engine, hv: u64) AnswerError!void {
    const h = Handle.decode(hv);
    if (h.kind == .net_udp) return error.Over;
    try closeConn(e, hv, abi.NET_CLOSE_GRACEFUL);
    return error.Over;
}

// ---------------------------------------------------------------------------
// UDP

const udp_table: net.UdpTable = .{
    .batch = onBatch,
    .writable = onUdpWritable,
};

fn udpHandle(st: *UdpState, socket_index: u8, exec: usize) u64 {
    return Handle.encode(.{
        .gen = @intCast(st.engine.first_gen),
        .kind = .net_udp,
        .slot = @intCast((st.ordinal << 8) | socket_index),
        .exec = @intCast(exec),
    });
}

fn onBatch(state: ?*anyopaque, socket: *net.UdpSocket, dgrams: []net.Datagram, dropped: u32) anyerror!void {
    const st: *UdpState = @ptrCast(@alignCast(state.?));
    const e = st.engine;
    // Calls find the sockets through here from now on.
    if (st.group.load(.monotonic) == null) st.group.store(socket.group, .release);
    if (dgrams.len == 0 and dropped == 0) return;
    const x = &e.execs[socket.exec];
    var total: usize = 0;
    for (dgrams) |d| total += d.data.len;
    const off: u32 = @sizeOf(abi.NetDatagramsEvent);
    const bytes_off = off + dgrams.len * @sizeOf(abi.NetDatagramIn);
    const rec = try engine.newRecord(bytes_off + total, .net_datagrams, udpHandle(st, socket.index, socket.exec));
    const ev: *abi.NetDatagramsEvent = @ptrCast(rec.ptr);
    ev.handler_id = st.handler_id;
    ev.ndatagrams = @intCast(dgrams.len);
    ev.datagrams_off = off;
    ev.dropped = dropped;
    var at: usize = bytes_off;
    for (dgrams, 0..) |d, i| {
        const rec_in: *abi.NetDatagramIn = @ptrCast(@alignCast(rec[off + i * @sizeOf(abi.NetDatagramIn) ..].ptr));
        rec_in.* = .{ .remote = .{}, .local = .{}, .data = .{ .off = @intCast(at), .len = @intCast(d.data.len) } };
        fillAddr(&rec_in.remote, d.remote);
        fillAddr(&rec_in.local, d.local);
        @memcpy(rec[at..][0..d.data.len], d.data);
        at += d.data.len;
    }
    // A consumer far behind stops this socket's reader; the kernel then
    // drops, and `dropped` says so.
    x.postRecord(rec, true);
}

fn onUdpWritable(state: ?*anyopaque, socket: *net.UdpSocket) void {
    const st: *UdpState = @ptrCast(@alignCast(state.?));
    const x = &st.engine.execs[socket.exec];
    x.postEvent(.writable, udpHandle(st, socket.index, socket.exec));
}

fn ipOf(a: abi.NetAddr) ?std.Io.net.IpAddress {
    return switch (a.family) {
        4 => .{ .ip4 = .{ .bytes = a.addr[0..4].*, .port = a.port } },
        6 => .{ .ip6 = .{ .bytes = a.addr, .port = a.port, .interface = .{ .index = a.scope_id } } },
        else => null,
    };
}

/// `anole_net_udp_send`: true when the socket's queue is past half full.
pub fn udpSend(e: *Engine, hv: u64, items: []const abi.NetDatagram, flags: u32) AnswerError!bool {
    const h = Handle.decode(hv);
    if (hv == 0 or h.gen == 0 or h.kind != .net_udp) return error.WrongKind;
    if (flags != 0 or items.len == 0) return error.Invalid;
    if (e.phase.load(.acquire) == .stopped) return e.gone();
    const ordinal = h.slot >> 8;
    const sock_i: u8 = @truncate(h.slot);
    if (h.gen != e.first_gen or ordinal >= e.net_state.udps.items.len) return e.gone();
    const st = e.net_state.udps.items[ordinal];
    const g = st.enter() orelse return e.gone();
    defer st.leave();
    if (sock_i >= g.sockets.len) return e.gone();
    const sock = &g.sockets[sock_i];
    var stack: [32]net.UdpSocket.Outgoing = undefined;
    const out: []net.UdpSocket.Outgoing = if (items.len <= stack.len) stack[0..items.len] else try gpa.alloc(net.UdpSocket.Outgoing, items.len);
    defer if (items.len > stack.len) gpa.free(out);
    for (items, out) |d, *o| {
        const to = ipOf(d.to) orelse return error.Invalid;
        if (d.len > 65507 or d.len > st.max_datagram) return error.Invalid;
        o.* = .{
            .to = to,
            .from = ipOf(d.from),
            .bytes = if (d.len == 0) "" else @as([*]const u8, @ptrCast(d.data orelse return error.Invalid))[0..d.len],
        };
    }
    sock.sendMany(out) catch |err| return switch (err) {
        error.TooLarge => error.Invalid,
        error.QueueFull => error.Again,
        error.Closed => e.gone(),
        error.OutOfMemory => error.OutOfMemory,
    };
    return sock.queueBusy();
}

/// `anole_net_udp_find`: the first socket of the UDP listener `name`.
pub fn udpFind(e: *Engine, name: []const u8) AnswerError!u64 {
    if (e.phase.load(.acquire) != .running) return error.State;
    var ordinal: u32 = 0;
    for (e.config.listeners, e.listeners) |lc, l| {
        if (lc.udp == null) continue;
        defer ordinal += 1;
        if (!std.mem.eql(u8, l.name, name)) continue;
        const st = e.net_state.udps.items[ordinal];
        return udpHandle(st, 0, 0);
    }
    return error.Invalid;
}

/// Fills this area's fields of `anole_stats`.
pub fn stats(e: *Engine, out: *abi.Stats) void {
    out.net_connections = e.net_state.conns.load(.monotonic);
    out.net_bytes_in = e.net_state.bytes_in.load(.monotonic);
    out.net_bytes_out = e.net_state.bytes_out.load(.monotonic);
    for (e.net_state.udps.items) |u| {
        const g = u.enter() orelse continue;
        defer u.leave();
        const t = g.totals();
        out.udp_datagrams_in += t.datagrams_in;
        out.udp_datagrams_out += t.datagrams_out;
        out.udp_datagrams_dropped += t.dropped;
    }
}
