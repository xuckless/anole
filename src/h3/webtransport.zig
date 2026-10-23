//! WebTransport over HTTP/3, as Chrome and Firefox speak it by default
//! (draft-ietf-webtrans-http3-02): a session is an extended CONNECT
//! (`:protocol webtransport`) answered with 200; its streams are QUIC
//! streams that start with a type (0x54, unidirectional) or a signal
//! (0x41, bidirectional) and the session's ID (the CONNECT stream's); its
//! datagrams are HTTP datagrams (RFC 9297) that start with the session ID
//! divided by four. The CONNECT stream carries capsules: the close
//! (CLOSE_WEBTRANSPORT_SESSION) and the drain (DRAIN_WEBTRANSPORT_SESSION).
//!
//! nghttp3 knows none of this (its WebTransport, ngtcp2/nghttp3 PR #442,
//! waits for the RFC). The SETTINGS that announce it go out through
//! Anole's nghttp3 fork (`nghttp3_conn_add_extra_setting`), and `Core`
//! takes a connection's WebTransport streams before nghttp3 sees them: it
//! looks at the first varint of each stream the peer opens, and keeps the
//! streams that are WebTransport's (`bridge.recvStreamData`). Their data
//! and datagrams go out through `bridge.writePacket`, beside nghttp3's.
//!
//! One `Core` per connection, shared by the server (src/h3/server.zig) and
//! the client (src/h3/client.zig). Everything in it is guarded by the
//! connection's mutex: the `Core` methods are called with it held (from
//! ngtcp2's callbacks), and `Session` and `Stream` take it themselves.
const std = @import("std");
const dusty = @import("dusty");
const ngtcp2 = @import("ngtcp2.zig");
const nghttp3 = @import("nghttp3.zig");
const bridge = @import("bridge.zig");

const c = ngtcp2.c;
const h = nghttp3.c;
const placement = dusty.placement;

const log = std.log.scoped(.anole_h3);

/// SETTINGS_ENABLE_WEBTRANSPORT (draft-02): what Chrome and Firefox look
/// for.
pub const setting_enable_webtransport: u64 = 0x2b603742;
/// SETTINGS_WT_MAX_SESSIONS (draft-07 and later): what Safari reportedly
/// looks for.
pub const setting_max_sessions: u64 = 0x14e9cd29;
/// The type of a unidirectional WebTransport stream.
pub const stream_type_uni: u64 = 0x54;
/// The signal that starts a bidirectional WebTransport stream.
pub const signal_bidi: u64 = 0x41;
/// CLOSE_WEBTRANSPORT_SESSION: an error code (u32) and a message.
pub const capsule_close: u64 = 0x2843;
/// DRAIN_WEBTRANSPORT_SESSION: no payload.
pub const capsule_drain: u64 = 0x78ae;
/// Streams of a session that is gone are reset with this.
pub const error_session_gone: u64 = 0x170d7b68;
/// A stream for a session that does not exist (yet) and could not be kept.
pub const error_buffered_stream_rejected: u64 = 0x3994bd84;
/// H3_ID_ERROR: a stream names something that cannot be a session.
const error_id: u64 = 0x108;
/// The longest close message (draft-02 §5).
pub const max_close_message = 1024;

/// The HTTP/3 error codes that carry WebTransport's (u32) application
/// codes on RESET_STREAM and STOP_SENDING.
const app_error_first: u64 = 0x52e4a40fa8db;
const app_error_last: u64 = 0x52e5ac983162;

/// A WebTransport application error code as the HTTP/3 code on the wire.
pub fn toHttp3Error(code: u32) u64 {
    return app_error_first + code + code / 0x1e;
}

/// The WebTransport code in an HTTP/3 code, or null when it carries none
/// (outside the range, or one of the reserved values in it).
pub fn fromHttp3Error(code: u64) ?u32 {
    if (code < app_error_first or code > app_error_last) return null;
    if ((code - 0x21) % 0x1f == 0) return null;
    const shifted = code - app_error_first;
    return @intCast(shifted - shifted / 0x1f);
}

// -- QUIC variable-length integers (RFC 9000 §16) ---------------------------

pub fn varintLen(v: u64) usize {
    return if (v < 1 << 6) 1 else if (v < 1 << 14) 2 else if (v < 1 << 30) 4 else 8;
}

/// Writes `v` (below 2^62) at the start of `buf`; returns its length.
pub fn putVarint(buf: []u8, v: u64) usize {
    const n = varintLen(v);
    var x = v;
    var i = n;
    while (i > 0) {
        i -= 1;
        buf[i] = @truncate(x);
        x >>= 8;
    }
    buf[0] |= switch (n) {
        1 => 0x00,
        2 => 0x40,
        4 => 0x80,
        else => 0xc0,
    };
    return n;
}

pub const Varint = struct { value: u64, len: usize };

/// The varint at the start of `b`, or null when `b` is too short for it.
pub fn getVarint(b: []const u8) ?Varint {
    if (b.len == 0) return null;
    const n = @as(usize, 1) << @intCast(b[0] >> 6);
    if (b.len < n) return null;
    var v: u64 = b[0] & 0x3f;
    for (b[1..n]) |x| v = v << 8 | x;
    return .{ .value = v, .len = n };
}

fn readVarint(r: *std.Io.Reader) std.Io.Reader.Error!u64 {
    const first = try r.takeByte();
    const n = @as(usize, 1) << @intCast(first >> 6);
    var v: u64 = first & 0x3f;
    for (1..n) |_| v = v << 8 | try r.takeByte();
    return v;
}

// -- A connection's WebTransport --------------------------------------------

/// How `Core` reaches the connection it belongs to.
pub const Host = struct {
    ctx: *anyopaque,
    /// Bumped on every change; the C ABI's session driver sleeps on it.
    gen: *bridge.Signal,
    /// The endpoint's (or client connection's) free blocks, and what the
    /// connection holds unacknowledged.
    pool: *bridge.BlockPool,
    budget: *bridge.Budget,
    /// Server only: gives the session the CONNECT stream's bytes that are
    /// already queued (`Session.onCapsuleBytes`) and routes later ones to
    /// it (`Options.inline_capsules`). Called with the connection locked.
    bind_session_fn: ?*const fn (*anyopaque, i64, *Session) void = null,
    /// Server only: ends the CONNECT stream's response without waiting;
    /// false while its 200 has not gone out. Called with the connection
    /// locked.
    end_connect_fn: ?*const fn (*anyopaque, i64) bool = null,
    lock_fn: *const fn (*anyopaque) void,
    unlock_fn: *const fn (*anyopaque) void,
    kick_fn: *const fn (*anyopaque) void,

    fn lock(self: Host) void {
        self.lock_fn(self.ctx);
    }
    fn unlock(self: Host) void {
        self.unlock_fn(self.ctx);
    }
    fn kick(self: Host) void {
        self.kick_fn(self.ctx);
    }
};

pub const Limits = struct {
    /// Streams kept for sessions not established yet (their CONNECT still
    /// on the way, or its handler not yet accepting), on one connection.
    /// Past it, such streams are refused.
    buffered_streams: usize = 32,
    /// A session's streams from the peer that its handler has not
    /// accepted yet, each way. Past it, new ones are refused. The peer's
    /// stream credit comes back only as streams are released, so this
    /// bounds what a handler that accepts slowly (or never) holds.
    incoming_streams: usize = 100,
    /// Datagrams kept for a session's handler, and their bytes; past
    /// either, new ones are dropped (datagrams are unreliable). A burst of
    /// small ones (a client's requests, say) arrives faster than any
    /// handler answers them, so the count is generous and the bytes bound
    /// the memory.
    datagrams_in: usize = 256,
    datagrams_in_bytes: usize = 1 << 20,
    /// Datagrams waiting to go out on one connection; `sendDatagram` waits
    /// while there are this many. Each is at most a packet.
    datagrams_out: usize = 256,
    /// Bytes one stream holds unacknowledged before a write waits.
    send_buffer: usize = 1 << 20,
};

/// The bytes a peer's stream started with while its first varint is not
/// complete: given back for nghttp3 when it turns out not to be
/// WebTransport's.
pub const Partial = struct {
    bytes: [8]u8 = undefined,
    len: u8 = 0,
};

pub const Route = union(enum) {
    /// WebTransport's (or held until that is known).
    taken,
    /// nghttp3's: feed it these bytes first, then the data.
    http3: Partial,
};

/// What a write into a packet did (`bridge.writePacket`).
pub const Wrote = union(enum) {
    /// Written, and the packet has room for more (`NGTCP2_ERR_WRITE_MORE`).
    more,
    /// A packet is complete (or 0: nothing can go now).
    packet: c.ngtcp2_ssize,
    /// Nothing written; let the others write.
    skip,
    /// An ngtcp2 error that ends the connection.
    failed: c.ngtcp2_ssize,
};

pub const Core = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    q: *c.ngtcp2_conn,
    host: Host,
    /// This side is the server (it opens the even-numbered... the odd
    /// streams; the client's are even).
    server: bool,
    limits: Limits,
    /// Every WebTransport stream QUIC still knows, by ID.
    streams: std.AutoHashMapUnmanaged(i64, *Stream) = .empty,
    /// Streams of the peer whose first varint has not fully arrived.
    undecided: std.AutoHashMapUnmanaged(i64, Partial) = .empty,
    /// Established sessions, by ID.
    sessions: std.AutoHashMapUnmanaged(i64, *Session) = .empty,
    /// The peer's streams for sessions not established (yet).
    orphans: std.ArrayList(*Stream) = .empty,
    /// The last sessions that ended, so their late streams are refused.
    gone: [16]i64 = @splat(-1),
    gone_next: usize = 0,
    /// Streams with something to send, by urgency and in turn.
    sched: Sched = .{},
    /// Datagrams to send, oldest first, each with its session prefix.
    datagrams_out: std.ArrayList([]u8) = .empty,
    /// Which of WebTransport's streams and nghttp3's leads the next packet
    /// (when no WebTransport stream is more urgent than nghttp3's default).
    turn: bool = false,
    /// The connection is gone: nothing reaches QUIC anymore.
    closed: bool = false,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, q: *c.ngtcp2_conn, host: Host, server: bool, limits: Limits) !*Core {
        const core = try gpa.create(Core);
        core.* = .{ .gpa = gpa, .io = io, .q = q, .host = host, .server = server, .limits = limits };
        return core;
    }

    /// Frees what is left. Every session is gone by now (their handlers
    /// have ended), and the connection with them.
    pub fn destroy(core: *Core) void {
        const gpa = core.gpa;
        // Orphans are among them, but for those QUIC is done with.
        var it = core.streams.valueIterator();
        while (it.next()) |s| s.*.free();
        for (core.orphans.items) |s| if (s.protocol_done) s.free();
        core.streams.deinit(gpa);
        core.orphans.deinit(gpa);
        core.undecided.deinit(gpa);
        core.sessions.deinit(gpa);
        for (core.datagrams_out.items) |d| gpa.free(d);
        core.datagrams_out.deinit(gpa);
        gpa.destroy(core);
    }

    fn pool(core: *const Core) *bridge.BlockPool {
        return core.host.pool;
    }

    fn budget(core: *const Core) *bridge.Budget {
        return core.host.budget;
    }

    /// The peer raised its stream limits: sessions waiting to open wake.
    /// Locked.
    pub fn onStreamCredit(core: *Core) void {
        var it = core.sessions.valueIterator();
        while (it.next()) |session| session.*.ev.notify(core.io);
    }

    fn isUni(stream_id: i64) bool {
        return stream_id & 2 != 0;
    }

    /// Opened by the other side.
    fn isPeers(core: *const Core, stream_id: i64) bool {
        const by_server = stream_id & 1 != 0;
        return by_server != core.server;
    }

    /// The connection is gone: every waiter wakes to it. Locked.
    ///
    /// Sessions are not ended here but by their capsule readers, which
    /// first read what their CONNECT streams had already received and
    /// then see those streams fail (`.connection`) or end (`.peer`). A
    /// peer's close capsule that arrived just before its CONNECTION_CLOSE,
    /// possibly in the same batch of datagrams with no task run in
    /// between, so still counts as the peer's close, whichever task runs
    /// first.
    pub fn connectionClosed(core: *Core) void {
        if (core.closed) return;
        core.closed = true;
        var it = core.streams.valueIterator();
        while (it.next()) |s| {
            const stream = s.*;
            if (stream.recv_err == null and !stream.in_fin) stream.recv_err = error.ConnectionClosed;
            if (stream.send_err == null) stream.send_err = error.ConnectionClosed;
            stream.wakeAll();
        }
        var sit = core.sessions.valueIterator();
        while (sit.next()) |session| session.*.ev.notify(core.io);
        core.host.kick();
    }

    // -- In ------------------------------------------------------------------

    /// Stream data from ngtcp2: WebTransport's, or nghttp3's. Locked.
    pub fn route(core: *Core, stream_id: i64, offset: u64, data: []const u8, fin: bool) error{OutOfMemory}!Route {
        if (core.streams.get(stream_id)) |s| {
            s.onData(data, fin);
            return .taken;
        }
        if (!core.isPeers(stream_id)) return .{ .http3 = .{} };
        var part: Partial = .{};
        if (core.undecided.fetchRemove(stream_id)) |e| {
            part = e.value;
        } else if (offset != 0) {
            return .{ .http3 = .{} };
        }
        // A unidirectional stream's type, or the first frame type of a
        // bidirectional one (0x41 is WebTransport's signal).
        var head: [8]u8 = undefined;
        @memcpy(head[0..part.len], part.bytes[0..part.len]);
        const more = @min(data.len, head.len - part.len);
        @memcpy(head[part.len..][0..more], data[0..more]);
        const first = getVarint(head[0 .. part.len + more]) orelse {
            // Too short to tell: wait for more, unless that was all.
            if (fin) return .{ .http3 = part };
            @memcpy(part.bytes[part.len..][0..data.len], data);
            part.len += @intCast(data.len);
            try core.undecided.put(core.gpa, stream_id, part);
            return .taken;
        };
        const uni = isUni(stream_id);
        const ours = if (uni) first.value == stream_type_uni else first.value == signal_bidi;
        if (!ours) return .{ .http3 = part };
        const s = try Stream.create(core, stream_id, if (uni) .uni_in else .bidi, false);
        errdefer s.free();
        try core.streams.put(core.gpa, stream_id, s);
        s.onData(part.bytes[0..part.len], false);
        s.onData(data, fin);
        return .taken;
    }

    /// Whether the stream is WebTransport's (so it is not a request).
    pub fn owns(core: *const Core, stream_id: i64) bool {
        return core.streams.contains(stream_id);
    }

    /// A stream's type and session are in: to its session, held for it,
    /// or refused. Locked.
    fn attach(core: *Core, s: *Stream, session_id: u64) void {
        // Sessions are CONNECT requests: client-initiated bidirectional
        // streams.
        if (session_id & 3 != 0) return s.disown(error_id);
        const id: i64 = @intCast(session_id);
        s.session_id = id;
        if (core.sessions.get(id)) |session| {
            if (session.state != .open) return s.disown(error_session_gone);
            return session.deliver(s);
        }
        if (core.isGone(id)) return s.disown(error_session_gone);
        if (core.orphans.items.len >= core.limits.buffered_streams) return s.disown(error_buffered_stream_rejected);
        core.orphans.append(core.gpa, s) catch return s.disown(error_buffered_stream_rejected);
    }

    fn isGone(core: *const Core, id: i64) bool {
        return std.mem.indexOfScalar(i64, &core.gone, id) != null;
    }

    fn markGone(core: *Core, id: i64) void {
        core.gone[core.gone_next] = id;
        core.gone_next = (core.gone_next + 1) % core.gone.len;
    }

    /// A DATAGRAM frame: to its session's queue, or dropped. Locked.
    pub fn onDatagram(core: *Core, data: []const u8) void {
        const qsid = getVarint(data) orelse return;
        if (qsid.value >= 1 << 60) return;
        const session = core.sessions.get(@intCast(qsid.value * 4)) orelse return;
        const payload = data[qsid.len..];
        if (session.state != .open or
            session.datagrams_in.items.len >= core.limits.datagrams_in or
            session.datagrams_in_bytes + payload.len > core.limits.datagrams_in_bytes) return;
        const copy = core.gpa.dupe(u8, payload) catch return;
        session.datagrams_in.append(core.gpa, copy) catch {
            core.gpa.free(copy);
            return;
        };
        session.datagrams_in_bytes += copy.len;
        session.ev.notify(core.io);
        core.host.kick();
    }

    /// The peer acknowledged `len` more bytes of a stream. Whether it was
    /// WebTransport's. Locked.
    pub fn onAcked(core: *Core, stream_id: i64, len: u64) bool {
        const s = core.streams.get(stream_id) orelse return false;
        s.out.ack(core.pool(), core.budget(), len);
        s.tx.notify(core.io);
        core.host.kick();
        return true;
    }

    /// The peer let a stream send more. Locked.
    pub fn onUnblocked(core: *Core, stream_id: i64) bool {
        const s = core.streams.get(stream_id) orelse return false;
        s.blocked = false;
        s.enqueue();
        core.host.kick();
        return true;
    }

    /// RESET_STREAM from the peer. Locked.
    pub fn onReset(core: *Core, stream_id: i64, code: u64) bool {
        const s = core.streams.get(stream_id) orelse return false;
        if (s.recv_err == null and !s.in_fin) {
            s.recv_err = error.StreamReset;
            s.reset_code = fromHttp3Error(code);
        }
        // Reset before it said its session: no use to anyone. Refused
        // both ways, so QUIC closes it and it is freed.
        if (!s.prefix_done) s.disown(error_id);
        s.wakeAll();
        core.host.kick();
        return true;
    }

    /// STOP_SENDING from the peer (ngtcp2 resets the sending side). Locked.
    pub fn onStopSending(core: *Core, stream_id: i64, code: u64) bool {
        const s = core.streams.get(stream_id) orelse return false;
        if (s.send_err == null) {
            s.send_err = error.StreamStopped;
            s.stop_code = fromHttp3Error(code);
        }
        s.dequeue();
        s.wakeAll();
        core.host.kick();
        return true;
    }

    /// QUIC is done with a stream. Whether it was WebTransport's. Locked.
    pub fn onClose(core: *Core, stream_id: i64) bool {
        if (core.undecided.remove(stream_id)) return false;
        // A CONNECT stream that never became a session: the streams kept
        // for it are refused.
        if (!isUni(stream_id) and stream_id & 1 == 0 and !core.sessions.contains(stream_id)) core.dropOrphans(stream_id);
        const e = core.streams.fetchRemove(stream_id) orelse return false;
        const s = e.value;
        s.protocol_done = true;
        if (std.mem.indexOfScalar(*Stream, core.orphans.items, s)) |i| {
            // A one-way stream that arrived whole before its session was
            // established (the server opened it right after its 200): kept,
            // with its data and end, for the session. `destroy` or
            // `dropOrphans` frees it if the session never comes.
            if (s.in_fin and s.recv_err == null) {
                s.dequeue();
                s.wakeAll();
                core.host.kick();
                return true;
            }
            _ = core.orphans.swapRemove(i);
            s.user_done = true;
        }
        // A peer's stream no session took (its prefix never completed):
        // nobody else will let go of it.
        if (!s.local and s.session == null) s.user_done = true;
        if (!s.in_fin and s.recv_err == null and s.kind != .uni_out) s.recv_err = error.StreamReset;
        if (!s.fin_sent and s.send_err == null and s.kind != .uni_in) s.send_err = error.StreamReset;
        s.dequeue();
        s.wakeAll();
        s.maybeFree();
        core.host.kick();
        return true;
    }

    fn dropOrphans(core: *Core, session_id: i64) void {
        var i: usize = 0;
        var dropped = false;
        while (i < core.orphans.items.len) {
            const s = core.orphans.items[i];
            if (s.session_id != session_id) {
                i += 1;
                continue;
            }
            _ = core.orphans.swapRemove(i);
            s.disown(error_buffered_stream_rejected);
            dropped = true;
        }
        // Later ones are refused at once.
        if (dropped) core.markGone(session_id);
    }

    // -- Out (inside `bridge.writePacket`, locked) ---------------------------

    /// Whether WebTransport's streams lead the next packet: always when
    /// one is more urgent than nghttp3's default (3), else they alternate
    /// with nghttp3's.
    pub fn leads(core: *Core) bool {
        if (core.sched.mostUrgent()) |u| if (u < 3) return true;
        core.turn = !core.turn;
        return core.turn;
    }

    /// The oldest datagram into the packet.
    pub fn writeDatagram(core: *Core, p: [*c]c.ngtcp2_path, pi: [*c]c.ngtcp2_pkt_info, dest: []u8, ts: u64) ?Wrote {
        if (core.datagrams_out.items.len == 0) return null;
        const d = core.datagrams_out.items[0];
        var accepted: c_int = 0;
        const vec = [_]c.ngtcp2_vec{.{ .base = d.ptr, .len = d.len }};
        const n = ngtcp2.connWritevDatagram(core.q, p, pi, dest, &accepted, c.NGTCP2_WRITE_DATAGRAM_FLAG_MORE, 0, &vec, ts);
        // Taken, or never will be (too big for the peer, or the peer takes
        // none): off the queue either way.
        if (accepted != 0 or n == c.NGTCP2_ERR_INVALID_ARGUMENT or n == c.NGTCP2_ERR_INVALID_STATE) {
            _ = core.datagrams_out.orderedRemove(0);
            core.gpa.free(d);
            // A slot is free: sessions waiting to send wake.
            var sit = core.sessions.valueIterator();
            while (sit.next()) |session| session.*.ev.notify(core.io);
            core.host.kick();
        }
        return switch (n) {
            c.NGTCP2_ERR_WRITE_MORE => .more,
            c.NGTCP2_ERR_INVALID_ARGUMENT, c.NGTCP2_ERR_INVALID_STATE => .skip,
            0 => .skip,
            else => if (n < 0) .{ .failed = n } else .{ .packet = n },
        };
    }

    /// The next stream in turn into the packet; null when none has
    /// anything to send.
    pub fn writeStream(core: *Core, p: [*c]c.ngtcp2_path, pi: [*c]c.ngtcp2_pkt_info, dest: []u8, ts: u64) ?Wrote {
        while (core.sched.first()) |s| {
            var runs: [4][]const u8 = undefined;
            const count = s.out.unsent(&runs);
            const pending = s.out.pending();
            const fin = s.send_closed and !s.fin_sent;
            if (pending == 0 and !fin) {
                s.dequeue();
                continue;
            }
            var vec: [4]c.ngtcp2_vec = undefined;
            for (runs[0..count], vec[0..count]) |run, *v| v.* = .{ .base = @constCast(run.ptr), .len = run.len };
            var flags: u32 = c.NGTCP2_WRITE_STREAM_FLAG_MORE | c.NGTCP2_WRITE_STREAM_FLAG_PADDING;
            if (fin) flags |= c.NGTCP2_WRITE_STREAM_FLAG_FIN;
            var data_len: c.ngtcp2_ssize = -1;
            const n = ngtcp2.connWritevStream(core.q, p, pi, dest, &data_len, flags, s.id, vec[0..count], ts);
            if (data_len >= 0) {
                s.out.advance(@intCast(data_len));
                if (fin and s.out.allSent()) s.fin_sent = true;
            }
            if (n < 0) switch (n) {
                c.NGTCP2_ERR_STREAM_DATA_BLOCKED => {
                    s.blocked = true;
                    s.dequeue();
                    continue;
                },
                c.NGTCP2_ERR_STREAM_SHUT_WR, c.NGTCP2_ERR_STREAM_NOT_FOUND => {
                    if (s.send_err == null) s.send_err = error.StreamReset;
                    s.dequeue();
                    s.wakeAll();
                    core.host.kick();
                    continue;
                },
                c.NGTCP2_ERR_WRITE_MORE => {
                    s.rotate();
                    return .more;
                },
                else => return .{ .failed = n },
            };
            s.rotate();
            return .{ .packet = n };
        }
        return null;
    }
};

// -- Scheduling and capsules ------------------------------------------------

/// WebTransport streams with something to send, by urgency (RFC 9218: 0
/// most urgent, 7 least, 3 the default) and, within one, in turn.
pub const Sched = struct {
    lists: [8]std.DoublyLinkedList = @splat(.{}),
    /// Bit u is set while `lists[u]` is not empty.
    ready: u8 = 0,

    pub fn push(q: *Sched, node: *std.DoublyLinkedList.Node, urgency: u3) void {
        q.lists[urgency].append(node);
        q.ready |= @as(u8, 1) << urgency;
    }

    pub fn remove(q: *Sched, node: *std.DoublyLinkedList.Node, urgency: u3) void {
        q.lists[urgency].remove(node);
        if (q.lists[urgency].first == null) q.ready &= ~(@as(u8, 1) << urgency);
    }

    /// The node first in turn in the most urgent class that has any.
    pub fn firstNode(q: *const Sched) ?*std.DoublyLinkedList.Node {
        if (q.ready == 0) return null;
        return q.lists[@ctz(q.ready)].first;
    }

    /// The most urgent class with a stream waiting.
    pub fn mostUrgent(q: *const Sched) ?u3 {
        if (q.ready == 0) return null;
        return @intCast(@ctz(q.ready));
    }

    pub fn first(q: *const Sched) ?*Stream {
        const node = q.firstNode() orelse return null;
        return @alignCast(@fieldParentPtr("node", node));
    }
};

/// Parses the capsules on a session's CONNECT stream (RFC 9297), fed in
/// pieces of any size. Only the close and the drain are understood; others
/// are skipped.
pub const CapsuleParser = struct {
    state: enum { kind, length, payload, skip, done } = .kind,
    in_varint: bool = false,
    vleft: u8 = 0,
    acc: u64 = 0,
    kind: u64 = 0,
    len: u64 = 0,
    have: usize = 0,
    payload: [4 + max_close_message]u8 = undefined,

    pub const Event = union(enum) {
        /// The reason points into the parser, valid until the next feed.
        close: struct { code: u32, reason: []const u8 },
        drain,
        /// A close capsule that is too short or too long; the parser stops.
        malformed,
    };

    pub const Fed = struct { used: usize, event: ?Event = null };

    /// Takes bytes until one event, or all of them. Call again with the
    /// rest until `used` covers it.
    pub fn feed(p: *CapsuleParser, bytes: []const u8) Fed {
        var i: usize = 0;
        while (i < bytes.len) {
            switch (p.state) {
                .done => return .{ .used = bytes.len },
                .kind, .length => {
                    const b = bytes[i];
                    i += 1;
                    if (!p.in_varint) {
                        p.in_varint = true;
                        p.vleft = (@as(u8, 1) << @intCast(b >> 6)) - 1;
                        p.acc = b & 0x3f;
                    } else {
                        p.acc = p.acc << 8 | b;
                        p.vleft -= 1;
                    }
                    if (p.vleft != 0) continue;
                    p.in_varint = false;
                    if (p.state == .kind) {
                        p.kind = p.acc;
                        p.state = .length;
                        continue;
                    }
                    p.len = p.acc;
                    p.have = 0;
                    switch (p.kind) {
                        capsule_close => {
                            if (p.len < 4 or p.len > 4 + max_close_message) {
                                p.state = .done;
                                return .{ .used = i, .event = .malformed };
                            }
                            p.state = .payload;
                        },
                        capsule_drain => {
                            p.state = if (p.len == 0) .kind else .skip;
                            return .{ .used = i, .event = .drain };
                        },
                        else => p.state = if (p.len == 0) .kind else .skip,
                    }
                },
                .payload => {
                    const want: usize = @intCast(p.len);
                    const take = @min(bytes.len - i, want - p.have);
                    @memcpy(p.payload[p.have..][0..take], bytes[i..][0..take]);
                    p.have += take;
                    i += take;
                    if (p.have == want) {
                        p.state = .done;
                        return .{ .used = i, .event = .{ .close = .{
                            .code = std.mem.readInt(u32, p.payload[0..4], .big),
                            .reason = p.payload[4..want],
                        } } };
                    }
                },
                .skip => {
                    const take: usize = @intCast(@min(@as(u64, bytes.len - i), p.len - p.have));
                    p.have += take;
                    i += take;
                    if (p.have == p.len) p.state = .kind;
                },
            }
        }
        return .{ .used = i };
    }
};

// -- A session ----------------------------------------------------------------

/// The CONNECT stream as a session uses it: its data both ways (capsules),
/// and how to end it. On the server, the request body and the streamed
/// response; on the client, the request stream.
pub const Channel = struct {
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    ctx: *anyopaque,
    /// Ends the sending side (a FIN).
    end_fn: *const fn (*anyopaque) void,
    /// Called last by `Session.deinit`, which may free the session.
    release_fn: ?*const fn (*anyopaque) void = null,
};

/// How a session ended (`Session.closeInfo`).
pub const CloseInfo = struct {
    /// The application's code from CLOSE_WEBTRANSPORT_SESSION; 0 when the
    /// session ended without one.
    code: u32,
    /// Its message (at most 1024 bytes).
    reason: []const u8,
    by: enum {
        /// `close` on this side.
        local,
        /// The peer's close capsule, or its end of the CONNECT stream.
        peer,
        /// The connection (or the CONNECT stream) went.
        connection,
    },
};

/// What session and stream calls fail with.
pub const Error = error{
    /// The session is closed (by either side, or the connection went).
    SessionClosed,
    /// The peer reset the stream (`Stream.resetCode`), or it was reset
    /// here.
    StreamReset,
    /// The peer asked for no more data on the stream (`Stream.stopCode`).
    StreamStopped,
    /// The QUIC connection closed.
    ConnectionClosed,
    /// The waiting task was canceled (the server stopping).
    Canceled,
};

/// A WebTransport session: streams both ways in either direction, and
/// datagrams. Safe from any task of the runtime.
pub const Session = struct {
    core: *Core,
    /// The CONNECT stream's ID.
    id: i64,
    channel: Channel,
    /// Under the connection's mutex:
    state: enum { open, closed } = .open,
    close_info: CloseInfo = .{ .code = 0, .reason = "", .by = .local },
    reason_buf: [max_close_message]u8 = undefined,
    /// Either side has started to drain.
    draining_flag: bool = false,
    incoming_bidi: std.ArrayList(*Stream) = .empty,
    incoming_uni: std.ArrayList(*Stream) = .empty,
    /// Every stream of the session that QUIC or a handler still holds.
    members: std.ArrayList(*Stream) = .empty,
    datagrams_in: std.ArrayList([]u8) = .empty,
    datagrams_in_bytes: usize = 0,
    /// Unregistered from the core (`deinit`).
    detached: bool = false,
    /// Woken by what a waiting `acceptFrom`, `open`, `receiveDatagram` or
    /// `sendDatagram` looks at: a new stream, a datagram, the session's end,
    /// the drain, stream credit.
    ev: bridge.Signal = .{},
    /// The CONNECT stream's capsules are parsed as they arrive
    /// (`onCapsuleBytes`), not by a task.
    inline_capsules: bool = false,
    parser: CapsuleParser = .{},

    /// Over the channel's writer: capsules from the handler and from the
    /// drain watch.
    write_mutex: std.Io.Mutex = .init,
    /// The CONNECT stream's sending side is ended (or being ended). Under
    /// the connection's lock.
    ended: bool = false,
    /// A capsule is being written: the channel ends after it
    /// (`end_pending`). Under the connection's lock.
    writing: bool = false,
    end_pending: bool = false,
    /// The capsule reader of a client session.
    tasks: std.Io.Group = .init,
    drain_watch: DrainWatch = .{},

    /// For `start`: `anole.webtransport.accept` fills it from its
    /// `AcceptOptions`.
    pub const Options = struct {
        /// The server's drain hooks: on the drain, a task sends a
        /// DRAIN_WEBTRANSPORT_SESSION capsule, and with `close_on_drain`
        /// the session closes.
        drain_hooks: ?*dusty.DrainHooks = null,
        close_on_drain: bool = true,
        drain_reason: []const u8 = "server shutting down",
        /// Parse the CONNECT stream's capsules as they arrive, with no task
        /// (the server's connection must offer `Host.bind_session_fn`).
        inline_capsules: bool = false,
    };

    /// Sends the drain's capsule, through the server's drain hooks: no task
    /// waits for the drain, only this record; the capsule goes from a task
    /// started when the drain does, on the session's executor.
    const DrainWatch = struct {
        hook: dusty.DrainHooks.Hook = .{ .callback = onDrain },
        hooks: ?*dusty.DrainHooks = null,
        session: *Session = undefined,
        close_on_drain: bool = true,
        reason: []const u8 = "",
        executor: ?usize = null,
        sender: std.Io.Group = .init,

        fn onDrain(hook: *dusty.DrainHooks.Hook) void {
            const self: *DrainWatch = @fieldParentPtr("hook", hook);
            const where: placement.Where = if (self.executor) |i| .{ .executor = i } else .local;
            placement.concurrent(&self.sender, self.session.core.io, where, run, .{self}) catch {};
        }

        fn run(self: *DrainWatch) std.Io.Cancelable!void {
            const session = self.session;
            const host = session.core.host;
            host.lock();
            session.draining_flag = true;
            host.unlock();
            session.ev.notify(session.core.io);
            host.kick();
            var capsule: [8 + 1]u8 = undefined;
            var n = putVarint(&capsule, capsule_drain);
            n += putVarint(capsule[n..], 0);
            session.writeCapsule(capsule[0..n]) catch {};
            if (self.close_on_drain) session.close(0, self.reason) catch {};
        }
    };

    /// Starts the session: it takes the streams that arrived for it, and
    /// a task reads the peer's capsules. `self` must stay put until
    /// `deinit`.
    fn start(self: *Session, core: *Core, id: i64, channel: Channel, options: Options) !void {
        self.* = .{ .core = core, .id = id, .channel = channel };
        const host = core.host;
        const inline_mode = options.inline_capsules and host.bind_session_fn != null;
        self.inline_capsules = inline_mode;
        host.lock();
        if (core.closed or core.isGone(id)) {
            host.unlock();
            return error.ConnectionClosed;
        }
        core.sessions.put(core.gpa, id, self) catch {
            host.unlock();
            return error.OutOfMemory;
        };
        var i: usize = 0;
        while (i < core.orphans.items.len) {
            const s = core.orphans.items[i];
            if (s.session_id != id) {
                i += 1;
                continue;
            }
            _ = core.orphans.orderedRemove(i);
            self.deliver(s);
        }
        // Capsules that arrived before the session did, and the ones to
        // come, are parsed in place.
        if (inline_mode) host.bind_session_fn.?(host.ctx, id, self);
        host.unlock();
        host.kick();
        errdefer self.detach();
        if (!inline_mode) try placement.concurrent(&self.tasks, core.io, .local, readCapsules, .{self});
        if (options.drain_hooks) |hooks| {
            const w = &self.drain_watch;
            w.* = .{
                .hooks = hooks,
                .session = self,
                .close_on_drain = options.close_on_drain,
                .reason = options.drain_reason[0..@min(options.drain_reason.len, max_close_message)],
                .executor = placement.currentExecutor(core.io),
            };
            hooks.add(core.io, &w.hook);
        }
    }

    /// Ends the session: closes it (code 0) if it is still open, and lets
    /// go of every stream (those the handler did not release are reset).
    /// Streams must not be used after.
    pub fn deinit(self: *Session) void {
        self.close(0, "") catch {};
        if (self.drain_watch.hooks) |hooks| hooks.remove(self.core.io, &self.drain_watch.hook);
        self.drain_watch.sender.cancel(self.core.io);
        self.tasks.cancel(self.core.io);
        self.detach();
        self.endChannel();
        if (self.channel.release_fn) |release| release(self.channel.ctx);
    }

    /// Takes the session out of the core, with its streams. Unlocked.
    fn detach(self: *Session) void {
        const core = self.core;
        const host = core.host;
        host.lock();
        defer host.unlock();
        if (self.detached) return;
        self.detached = true;
        self.endLocked(.{ .code = 0, .reason = "", .by = .local });
        _ = core.sessions.remove(self.id);
        core.markGone(self.id);
        // Those not accepted are among the members.
        self.incoming_bidi.deinit(core.gpa);
        self.incoming_uni.deinit(core.gpa);
        // What the handler still holds goes too.
        while (self.members.pop()) |s| {
            s.session = null;
            s.user_done = true;
            s.maybeFree();
        }
        self.members.deinit(core.gpa);
        for (self.datagrams_in.items) |d| core.gpa.free(d);
        self.datagrams_in.deinit(core.gpa);
        self.ev.notify(core.io);
        host.kick();
    }

    /// A stream of this session, to its queue. Locked.
    fn deliver(self: *Session, s: *Stream) void {
        const gpa = self.core.gpa;
        const queue = if (s.kind == .bidi) &self.incoming_bidi else &self.incoming_uni;
        if (queue.items.len >= self.core.limits.incoming_streams) return s.disown(error_buffered_stream_rejected);
        s.session = self;
        self.members.append(gpa, s) catch {
            s.session = null;
            return s.disown(error_buffered_stream_rejected);
        };
        queue.append(gpa, s) catch {
            _ = self.members.pop();
            s.session = null;
            return s.disown(error_buffered_stream_rejected);
        };
        self.ev.notify(self.core.io);
        self.core.host.kick();
    }

    /// The session is over, for `info`'s reason: every stream is reset
    /// both ways (WT_SESSION_GONE), and every waiter wakes. Locked.
    fn endLocked(self: *Session, info: CloseInfo) void {
        if (self.state != .open) return;
        self.state = .closed;
        const n = @min(info.reason.len, self.reason_buf.len);
        @memcpy(self.reason_buf[0..n], info.reason[0..n]);
        self.close_info = .{ .code = info.code, .reason = self.reason_buf[0..n], .by = info.by };
        const core = self.core;
        for (self.members.items) |s| {
            if (!s.protocol_done and !core.closed) _ = c.ngtcp2_conn_shutdown_stream(core.q, 0, s.id, error_session_gone);
            if (s.recv_err == null and !s.in_fin) s.recv_err = error.SessionClosed;
            if (s.send_err == null) s.send_err = error.SessionClosed;
            s.discardInput();
            s.dequeue();
            s.wakeAll();
        }
        self.ev.notify(core.io);
        core.host.kick();
    }

    /// Whether neither side has closed the session yet.
    pub fn isOpen(self: *Session) bool {
        const host = self.core.host;
        host.lock();
        defer host.unlock();
        return self.state == .open;
    }

    /// How the session ended; null while it is open.
    pub fn closeInfo(self: *Session) ?CloseInfo {
        const host = self.core.host;
        host.lock();
        defer host.unlock();
        return if (self.state == .open) null else self.close_info;
    }

    /// Whether either side has started to drain (the server is shutting
    /// down, or the peer sent DRAIN_WEBTRANSPORT_SESSION): finish up.
    pub fn draining(self: *Session) bool {
        const host = self.core.host;
        host.lock();
        defer host.unlock();
        return self.draining_flag;
    }

    /// The next bidirectional stream the peer opens.
    pub fn acceptStream(self: *Session) Error!*Stream {
        return self.acceptFrom(.bidi);
    }

    /// The next unidirectional stream the peer opens (read-only).
    pub fn acceptUniStream(self: *Session) Error!*Stream {
        return self.acceptFrom(.uni_in);
    }

    fn acceptFrom(self: *Session, kind: Stream.Kind) Error!*Stream {
        while (true) {
            const seen = self.ev.epoch();
            if (self.tryAccept(if (kind == .bidi) .bidi else .uni)) |s| return s;
            if (!self.isOpen()) return error.SessionClosed;
            try self.ev.wait(self.core.io, seen);
        }
    }

    /// Opens a bidirectional stream, waiting while the peer's stream limit
    /// is reached.
    pub fn openStream(self: *Session) (Error || error{OutOfMemory})!*Stream {
        return self.open(.bidi);
    }

    /// Opens a unidirectional stream (write-only).
    pub fn openUniStream(self: *Session) (Error || error{OutOfMemory})!*Stream {
        return self.open(.uni_out);
    }

    fn open(self: *Session, kind: Stream.Kind) (Error || error{OutOfMemory})!*Stream {
        while (true) {
            const seen = self.ev.epoch();
            if (try self.tryOpen(if (kind == .bidi) .bidi else .uni)) |s| return s;
            try self.ev.wait(self.core.io, seen);
        }
    }

    // -- Without waiting ---------------------------------------------------
    //
    // For a caller that runs a session from one task and does its own
    // waiting (the C ABI's session driver): read `generation`, look with
    // the `try` calls, and `waitChange` only when none had anything.

    /// The connection's change count: read it before looking.
    fn generation(self: *Session) u32 {
        return self.core.host.gen.epoch();
    }

    /// Waits until something on the connection changes after `gen`.
    fn waitChange(self: *Session, gen: u32) std.Io.Cancelable!void {
        return self.core.host.gen.wait(self.core.io, gen);
    }

    /// Wakes `waitChange` (and the connection's other waiters). From a
    /// task of the runtime on the connection's executor.
    fn wake(self: *Session) void {
        self.core.host.kick();
    }

    /// The calls Anole's own drivers make (the C ABI's session driver, the
    /// tests): they never wait. Not for handlers; they change without
    /// notice. For a caller that runs a session from one task and does its
    /// own waiting: read `generation`, look with the `try` calls, and
    /// `waitChange` only when none had anything.
    pub const Driver = struct {
        pub const Direction = enum { bidi, uni };

        /// Starts the session: it takes the streams that arrived for it,
        /// and a task reads the peer's capsules. `s` must stay put until
        /// `deinit`.
        pub fn start(s: *Session, core: *Core, id: i64, channel: Channel, options: Options) !void {
            return s.start(core, id, channel, options);
        }
        /// The connection's change count: read it before looking.
        pub fn generation(s: *Session) u32 {
            return s.generation();
        }
        /// Waits until something on the connection changes after `gen`.
        pub fn waitChange(s: *Session, gen: u32) std.Io.Cancelable!void {
            return s.waitChange(gen);
        }
        /// Wakes `waitChange` (and the connection's other waiters). From a
        /// task of the runtime on the connection's executor.
        pub fn wake(s: *Session) void {
            s.wake();
        }
        /// The next stream the peer opened, if any: both ways (`.bidi`) or
        /// read-only (`.uni`).
        pub fn tryAccept(s: *Session, dir: Direction) ?*Stream {
            return s.tryAccept(dir);
        }
        /// Opens a stream (`.uni`: write-only), or null while the peer's
        /// stream limit is reached.
        pub fn tryOpen(s: *Session, dir: Direction) (Error || error{OutOfMemory})!?*Stream {
            return s.tryOpen(dir);
        }
        /// The next datagram received, if any; give it back with
        /// `freeDatagram`.
        pub fn takeDatagram(s: *Session) ?[]u8 {
            return s.takeDatagram();
        }
        pub fn freeDatagram(s: *Session, d: []u8) void {
            s.freeDatagram(d);
        }
        /// Queues `data` as one datagram; false, with nothing queued, while
        /// the connection's queue is full.
        pub fn trySendDatagram(s: *Session, data: []const u8) (Error || error{ DatagramTooLarge, OutOfMemory })!bool {
            return s.trySendDatagram(data);
        }
        /// Tests only: opens a stream of `kind` that starts with `head`
        /// instead of a whole prefix, held by nobody. Returns its ID, for
        /// `testReset`.
        pub fn testOpenRaw(s: *Session, kind: Stream.Kind, head: []const u8) !i64 {
            return s.testOpenRaw(kind, head);
        }
        /// Tests only: resets a `testOpenRaw` stream's sending side.
        pub fn testReset(s: *Session, id: i64) void {
            s.testReset(id);
        }
    };

    /// The next stream the peer opened, if any: both ways (`.bidi`) or
    /// read-only (`.uni`).
    fn tryAccept(self: *Session, dir: Driver.Direction) ?*Stream {
        const host = self.core.host;
        host.lock();
        defer host.unlock();
        const queue = if (dir == .bidi) &self.incoming_bidi else &self.incoming_uni;
        if (queue.items.len == 0) return null;
        const s = queue.orderedRemove(0);
        // The reader's buffer only now that a handler has the stream.
        s.allocReader() catch {
            s.refuse(error_session_gone);
            s.user_done = true;
            s.maybeFree();
            return null;
        };
        return s;
    }

    /// Opens a stream (`.uni`: write-only), or null while the peer's
    /// stream limit is reached.
    fn tryOpen(self: *Session, dir: Driver.Direction) (Error || error{OutOfMemory})!?*Stream {
        const core = self.core;
        core.host.lock();
        if (self.state != .open or core.closed) {
            core.host.unlock();
            return if (self.state != .open) error.SessionClosed else error.ConnectionClosed;
        }
        var id: i64 = -1;
        const rv = if (dir == .bidi)
            c.ngtcp2_conn_open_bidi_stream(core.q, &id, null)
        else
            c.ngtcp2_conn_open_uni_stream(core.q, &id, null);
        if (rv == c.NGTCP2_ERR_STREAM_ID_BLOCKED) {
            core.host.unlock();
            return null;
        }
        if (rv != 0) {
            core.host.unlock();
            return error.ConnectionClosed;
        }
        const s = self.adopt(id, if (dir == .bidi) .bidi else .uni_out) catch |err| {
            _ = c.ngtcp2_conn_shutdown_stream(core.q, 0, id, error_session_gone);
            core.host.unlock();
            return err;
        };
        core.host.unlock();
        core.host.kick();
        return s;
    }

    /// The next datagram received, if any; give it back with
    /// `freeDatagram`.
    fn takeDatagram(self: *Session) ?[]u8 {
        const host = self.core.host;
        host.lock();
        defer host.unlock();
        if (self.datagrams_in.items.len == 0) return null;
        const d = self.datagrams_in.orderedRemove(0);
        self.datagrams_in_bytes -= d.len;
        return d;
    }

    fn freeDatagram(self: *Session, d: []u8) void {
        self.core.gpa.free(d);
    }

    /// Queues `data` as one datagram; false, with nothing queued, while
    /// the connection's queue is full.
    fn trySendDatagram(self: *Session, data: []const u8) (Error || error{ DatagramTooLarge, OutOfMemory })!bool {
        const d = try self.prefixDatagram(data);
        const queued = self.queueDatagram(d, data.len) catch |err| {
            self.core.gpa.free(d);
            return err;
        };
        if (!queued) self.core.gpa.free(d);
        return queued;
    }

    /// `data` behind the session's prefix, in a new buffer.
    fn prefixDatagram(self: *Session, data: []const u8) error{OutOfMemory}![]u8 {
        const qsid: u64 = @as(u64, @intCast(self.id)) / 4;
        const d = try self.core.gpa.alloc(u8, varintLen(qsid) + data.len);
        const n = putVarint(d, qsid);
        @memcpy(d[n..], data);
        return d;
    }

    /// Takes `d` (a prefixed datagram of `len` payload bytes) into the
    /// connection's queue, or false when it is full.
    fn queueDatagram(self: *Session, d: []u8, len: usize) (Error || error{ DatagramTooLarge, OutOfMemory })!bool {
        const core = self.core;
        core.host.lock();
        if (self.state != .open or core.closed) {
            core.host.unlock();
            return if (self.state != .open) error.SessionClosed else error.ConnectionClosed;
        }
        if (len > self.maxDatagramLocked()) {
            core.host.unlock();
            return error.DatagramTooLarge;
        }
        if (core.datagrams_out.items.len >= core.limits.datagrams_out) {
            core.host.unlock();
            return false;
        }
        core.datagrams_out.append(core.gpa, d) catch {
            core.host.unlock();
            return error.OutOfMemory;
        };
        core.host.unlock();
        core.host.kick();
        return true;
    }

    /// Tests only: opens a stream of `kind` that starts with `head`
    /// instead of a whole prefix, held by nobody. Returns its ID, for
    /// `testReset`.
    fn testOpenRaw(self: *Session, kind: Stream.Kind, head: []const u8) !i64 {
        if (!@import("builtin").is_test) @compileError("tests only");
        const core = self.core;
        core.host.lock();
        defer core.host.unlock();
        var id: i64 = -1;
        const rv = if (kind == .bidi)
            c.ngtcp2_conn_open_bidi_stream(core.q, &id, null)
        else
            c.ngtcp2_conn_open_uni_stream(core.q, &id, null);
        if (rv != 0) return error.StreamIdBlocked;
        const s = try Stream.create(core, id, kind, true);
        s.user_done = true;
        _ = try s.out.write(core.pool(), core.budget(), head, 0, true);
        try core.streams.put(core.gpa, id, s);
        s.enqueue();
        core.host.kick();
        return id;
    }

    /// Tests only: resets a `testOpenRaw` stream's sending side.
    fn testReset(self: *Session, id: i64) void {
        if (!@import("builtin").is_test) @compileError("tests only");
        const core = self.core;
        core.host.lock();
        defer core.host.unlock();
        if (core.streams.get(id)) |s| s.send_err = error.StreamReset;
        _ = c.ngtcp2_conn_shutdown_stream_write(core.q, 0, id, 0);
        core.host.kick();
    }

    /// A stream this side opened: the type (or signal) and the session ID
    /// go first. Locked.
    fn adopt(self: *Session, id: i64, kind: Stream.Kind) !*Stream {
        const core = self.core;
        const s = try Stream.create(core, id, kind, true);
        errdefer s.free();
        var prefix: [16]u8 = undefined;
        var n = putVarint(&prefix, if (kind == .bidi) signal_bidi else stream_type_uni);
        n += putVarint(prefix[n..], @intCast(self.id));
        _ = try s.out.write(core.pool(), core.budget(), prefix[0..n], 0, true);
        if (kind == .bidi) try s.allocReader();
        try self.members.append(core.gpa, s);
        errdefer _ = self.members.pop();
        try core.streams.put(core.gpa, id, s);
        s.session = self;
        s.session_id = self.id;
        s.enqueue();
        return s;
    }

    /// The next datagram, copied into `buf`; `error.NoSpaceLeft` (and the
    /// datagram stays) when it does not fit.
    pub fn receiveDatagram(self: *Session, buf: []u8) (Error || error{NoSpaceLeft})![]u8 {
        const core = self.core;
        while (true) {
            const seen = self.ev.epoch();
            core.host.lock();
            if (self.datagrams_in.items.len > 0) {
                const d = self.datagrams_in.items[0];
                if (d.len > buf.len) {
                    core.host.unlock();
                    return error.NoSpaceLeft;
                }
                _ = self.datagrams_in.orderedRemove(0);
                self.datagrams_in_bytes -= d.len;
                core.host.unlock();
                @memcpy(buf[0..d.len], d);
                core.gpa.free(d);
                return buf[0..d.len];
            }
            const still_open = self.state == .open;
            core.host.unlock();
            if (!still_open) return error.SessionClosed;
            try self.ev.wait(core.io, seen);
        }
    }

    /// The largest datagram payload `sendDatagram` takes now: what fits in
    /// one packet on the current path and in the peer's limit. 0 when the
    /// peer takes no datagrams.
    pub fn maxDatagramSize(self: *Session) usize {
        const host = self.core.host;
        host.lock();
        defer host.unlock();
        return self.maxDatagramLocked();
    }

    fn maxDatagramLocked(self: *Session) usize {
        const core = self.core;
        if (core.closed) return 0;
        const params = c.ngtcp2_conn_get_remote_transport_params2(core.q) orelse return 0;
        const frame_max = params.*.max_datagram_frame_size;
        // The DATAGRAM frame's type and length.
        if (frame_max <= 9) return 0;
        // A short header (flags, the longest connection ID, packet number)
        // and the AEAD tag.
        const udp = c.ngtcp2_conn_get_path_max_tx_udp_payload_size2(core.q);
        const room = @min(@as(u64, frame_max - 9), if (udp > 50) udp - 50 else 0);
        const prefix = varintLen(@as(u64, @intCast(self.id)) / 4);
        return if (room > prefix) @intCast(room - prefix) else 0;
    }

    /// Sends `data` as one datagram, waiting while many are queued. It may
    /// be lost; nothing says whether it arrived.
    pub fn sendDatagram(self: *Session, data: []const u8) (Error || error{ DatagramTooLarge, OutOfMemory })!void {
        const d = try self.prefixDatagram(data);
        var queued = false;
        defer if (!queued) self.core.gpa.free(d);
        while (true) {
            const seen = self.ev.epoch();
            if (try self.queueDatagram(d, data.len)) {
                queued = true;
                return;
            }
            try self.ev.wait(self.core.io, seen);
        }
    }

    /// Closes the session with an application `code` and a `reason` (at
    /// most 1024 bytes): a CLOSE_WEBTRANSPORT_SESSION capsule, then the
    /// end of the CONNECT stream. Every stream of the session is reset.
    pub fn close(self: *Session, code: u32, reason: []const u8) !void {
        const core = self.core;
        const message = reason[0..@min(reason.len, max_close_message)];
        core.host.lock();
        if (self.state != .open) {
            core.host.unlock();
            return;
        }
        self.endLocked(.{ .code = code, .reason = message, .by = .local });
        // The connection is gone (the session's capsule reader has not
        // ended it yet): no capsule can go out.
        const gone = core.closed;
        core.host.unlock();
        if (gone) return self.endChannel();
        var capsule: [8 + 8 + 4 + max_close_message]u8 = undefined;
        var n = putVarint(&capsule, capsule_close);
        n += putVarint(capsule[n..], 4 + message.len);
        std.mem.writeInt(u32, capsule[n..][0..4], code, .big);
        n += 4;
        @memcpy(capsule[n..][0..message.len], message);
        n += message.len;
        defer self.endChannel();
        try self.writeCapsule(capsule[0..n]);
    }

    fn writeCapsule(self: *Session, bytes: []const u8) !void {
        const host = self.core.host;
        self.write_mutex.lockUncancelable(self.core.io);
        defer self.write_mutex.unlock(self.core.io);
        host.lock();
        if (self.ended) {
            host.unlock();
            return error.SessionClosed;
        }
        self.writing = true;
        host.unlock();
        defer {
            host.lock();
            self.writing = false;
            if (self.end_pending) {
                self.end_pending = false;
                self.endChannelLocked();
            }
            host.unlock();
        }
        const w = self.channel.writer;
        try w.writeAll(bytes);
        try w.flush();
    }

    /// Ends the CONNECT stream's sending side, once.
    fn endChannel(self: *Session) void {
        const host = self.core.host;
        self.write_mutex.lockUncancelable(self.core.io);
        defer self.write_mutex.unlock(self.core.io);
        host.lock();
        if (self.ended) {
            host.unlock();
            return;
        }
        self.ended = true;
        host.unlock();
        self.channel.end_fn(self.channel.ctx);
    }

    /// Ends the CONNECT stream's sending side from a callback, which can't
    /// wait: right away, unless a capsule is being written (it ends the
    /// stream when it is done) or the 200 has not gone out (the handler's
    /// `deinit` ends it). Locked.
    fn endChannelLocked(self: *Session) void {
        if (self.ended) return;
        if (self.writing) {
            self.end_pending = true;
            return;
        }
        const host = self.core.host;
        const f = host.end_connect_fn orelse return;
        if (f(host.ctx, self.id)) self.ended = true;
    }

    /// The CONNECT stream's bytes (inline capsules): the parser takes them,
    /// and what they say happens now. Locked.
    pub fn onCapsuleBytes(self: *Session, bytes: []const u8) void {
        var rest = bytes;
        while (rest.len > 0) {
            const fed = self.parser.feed(rest);
            rest = rest[fed.used..];
            const event = fed.event orelse continue;
            switch (event) {
                .close => |info| {
                    self.endLocked(.{ .code = info.code, .reason = info.reason, .by = .peer });
                    // Our side ends too (draft-02 §5).
                    self.endChannelLocked();
                },
                .drain => {
                    self.draining_flag = true;
                    self.ev.notify(self.core.io);
                    self.core.host.kick();
                },
                .malformed => {
                    self.endLocked(.{ .code = 0, .reason = "", .by = .connection });
                    self.endChannelLocked();
                },
            }
        }
    }

    /// The CONNECT stream ended: by the peer's FIN (our side ends too), or
    /// with the connection. Locked.
    pub fn onChannelEnd(self: *Session, by: enum { peer, connection }) void {
        self.endLocked(.{ .code = 0, .reason = "", .by = if (by == .peer) .peer else .connection });
        if (by == .peer) self.endChannelLocked();
    }

    /// Reads the peer's capsules until the CONNECT stream ends (a client's
    /// session; the server parses them as they arrive). Runs beside the
    /// handler until `deinit` cancels it.
    fn readCapsules(self: *Session) std.Io.Cancelable!void {
        const r = self.channel.reader;
        var parser: CapsuleParser = .{};
        var buf: [256]u8 = undefined;
        const info: CloseInfo = outer: while (true) {
            const avail = r.peekGreedy(1) catch |err| break self.readFailed(err);
            const n = @min(avail.len, buf.len);
            @memcpy(buf[0..n], avail[0..n]);
            r.toss(n);
            var rest: []const u8 = buf[0..n];
            while (rest.len > 0) {
                const fed = parser.feed(rest);
                rest = rest[fed.used..];
                const event = fed.event orelse continue;
                switch (event) {
                    .close => |c_info| {
                        // The reason lives in the parser; `endLocked` copies it.
                        break :outer .{ .code = c_info.code, .reason = c_info.reason, .by = .peer };
                    },
                    .drain => {
                        const host = self.core.host;
                        host.lock();
                        self.draining_flag = true;
                        host.unlock();
                        self.ev.notify(self.core.io);
                        host.kick();
                    },
                    .malformed => break :outer .{ .code = 0, .reason = "", .by = .connection },
                }
            }
        };
        const host = self.core.host;
        host.lock();
        self.endLocked(info);
        host.unlock();
        // The peer closed: our side ends too (draft-02 §5).
        self.endChannel();
        try std.Io.checkCancel(self.core.io);
    }

    fn readFailed(self: *Session, err: std.Io.Reader.Error) CloseInfo {
        _ = self;
        return switch (err) {
            // The peer ended the CONNECT stream: a close without a capsule.
            error.EndOfStream => .{ .code = 0, .reason = "", .by = .peer },
            error.ReadFailed => .{ .code = 0, .reason = "", .by = .connection },
        };
    }
};

// -- A stream -------------------------------------------------------------------

/// One WebTransport stream: read with `reader`, write with `writer` and
/// end with `closeSend`, and `release` when done. A unidirectional stream
/// only reads (accepted) or only writes (opened). Safe for one reading and
/// one writing task at once.
pub const Stream = struct {
    core: *Core,
    id: i64,
    kind: Kind,
    /// Opened by this side.
    local: bool,
    session: ?*Session = null,
    session_id: i64 = -1,
    /// In `Core.send_queue`.
    node: std.DoublyLinkedList.Node = .{},
    queued: bool = false,

    /// A peer's stream: its type (or signal) and session ID, until both
    /// are in.
    prefix: [16]u8 = undefined,
    prefix_len: u8 = 0,
    prefix_done: bool,

    /// Received and not yet read.
    in: bridge.RecvQueue = .{},
    in_fin: bool = false,
    /// Woken by new data, the end, or an error on the receiving side; and
    /// by room to write (acknowledgments, the connection's budget), or an
    /// error on the sending side.
    rx: bridge.Signal = .{},
    tx: bridge.Signal = .{},
    /// RFC 9218 urgency of the stream's data against the other streams'
    /// (`setPriority`).
    urgency: u3 = 3,
    waiter: bridge.Budget.Waiter = .{ .signal = undefined },
    /// Small writes (lengths, audio) collect here before they are queued.
    wbuf: [256]u8 = undefined,
    /// Nobody will read: credit goes back as data arrives.
    discarding: bool = false,
    recv_err: ?Error = null,
    reset_code: ?u32 = null,
    read_err: ?Error = null,
    reader_iface: std.Io.Reader,

    /// Sent until the peer acknowledges it, then dropped.
    out: bridge.SendQueue = .{},
    send_closed: bool = false,
    fin_sent: bool = false,
    blocked: bool = false,
    send_err: ?Error = null,
    stop_code: ?u32 = null,
    write_err: ?Error = null,
    writer_iface: std.Io.Writer,

    /// The handler let go (or never had it), and QUIC is done with it.
    user_done: bool,
    protocol_done: bool = false,

    /// Bidirectional, or one-way in (accepted) or out (opened).
    pub const Kind = enum { bidi, uni_in, uni_out };

    fn create(core: *Core, id: i64, kind: Kind, local: bool) !*Stream {
        const gpa = core.gpa;
        const s = try gpa.create(Stream);
        errdefer gpa.destroy(s);
        s.* = .{
            .core = core,
            .id = id,
            .kind = kind,
            .local = local,
            .prefix_done = local,
            // Held from the start: by the handler that opens it, or (a
            // peer's) by the session's queue or the orphans until it is
            // accepted or refused.
            .user_done = false,
            .reader_iface = .{ .buffer = &.{}, .seek = 0, .end = 0, .vtable = &.{ .stream = readStream } },
            .writer_iface = .{ .buffer = &.{}, .vtable = &.{ .drain = drainOut, .flush = flushOut } },
        };
        if (kind != .uni_in) s.writer_iface.buffer = &s.wbuf;
        return s;
    }

    /// The reader's buffer, once a handler has the stream: refused and
    /// orphan streams never get one.
    fn allocReader(s: *Stream) error{OutOfMemory}!void {
        if (s.kind == .uni_out or s.reader_iface.buffer.len > 0) return;
        s.reader_iface.buffer = try s.core.gpa.alloc(u8, 4 * 1024);
    }

    fn free(s: *Stream) void {
        const gpa = s.core.gpa;
        s.core.budget().unlink(&s.waiter);
        s.in.deinit(s.core.pool());
        s.out.deinit(s.core.pool(), s.core.budget());
        if (s.reader_iface.buffer.len > 0) gpa.free(s.reader_iface.buffer);
        gpa.destroy(s);
    }

    /// Wakes the stream's reader and writer. Locked.
    fn wakeAll(s: *Stream) void {
        s.rx.notify(s.core.io);
        s.tx.notify(s.core.io);
    }

    /// Frees the stream once nothing holds it. Locked.
    fn maybeFree(s: *Stream) void {
        if (!(s.user_done and s.protocol_done)) return;
        if (s.session) |session| {
            if (std.mem.indexOfScalar(*Stream, session.members.items, s)) |i| _ = session.members.swapRemove(i);
        }
        s.dequeue();
        // The peer may open another in its place: only now, so streams
        // waiting to be accepted count against its limit.
        const core = s.core;
        if (!s.local and !core.closed) {
            if (Core.isUni(s.id))
                _ = c.ngtcp2_conn_extend_max_streams_uni(core.q, 1)
            else
                _ = c.ngtcp2_conn_extend_max_streams_bidi(core.q, 1);
        }
        s.free();
    }

    fn enqueue(s: *Stream) void {
        if (s.queued or s.blocked) return;
        s.queued = true;
        s.core.sched.push(&s.node, s.urgency);
    }

    fn dequeue(s: *Stream) void {
        if (!s.queued) return;
        s.queued = false;
        s.core.sched.remove(&s.node, s.urgency);
    }

    /// To the back of the queue if it has more to send, else out of it.
    fn rotate(s: *Stream) void {
        s.dequeue();
        if (s.out.pending() > 0 or (s.send_closed and !s.fin_sent)) s.enqueue();
    }

    /// Data from the peer. Locked.
    fn onData(s: *Stream, data: []const u8, fin: bool) void {
        const core = s.core;
        var rest = data;
        if (!s.prefix_done) {
            const take = @min(rest.len, s.prefix.len - s.prefix_len);
            @memcpy(s.prefix[s.prefix_len..][0..take], rest[0..take]);
            s.prefix_len += @intCast(take);
            const buffered = s.prefix[0..s.prefix_len];
            const kind = getVarint(buffered);
            const session = if (kind) |k| getVarint(buffered[k.len..]) else null;
            if (session == null) {
                // A stream that ends before saying its session is no use.
                if (fin) s.disown(error_id);
                return;
            }
            const used = kind.?.len + session.?.len;
            // The prefix's bytes are WebTransport's framing: credit back
            // now. What came after it is data.
            bridge.consume(core.q, s.id, used);
            const extra = s.prefix_len - used;
            rest = rest[take - extra ..];
            s.prefix_done = true;
            s.receive(rest, fin);
            core.attach(s, session.?.value);
            return;
        }
        s.receive(rest, fin);
    }

    fn receive(s: *Stream, data: []const u8, fin: bool) void {
        const core = s.core;
        if (s.discarding) {
            bridge.consume(core.q, s.id, data.len);
        } else if (data.len > 0) {
            // Bounded by the stream's flow-control window.
            s.in.append(core.pool(), data) catch {
                s.refuse(error_session_gone);
                return;
            };
        }
        if (fin) s.in_fin = true;
        s.rx.notify(core.io);
        core.host.kick();
    }

    /// Refuses a peer's stream that nobody holds (yet): reset both ways,
    /// and freed once QUIC is done with it. Locked.
    fn disown(s: *Stream, code: u64) void {
        s.user_done = true;
        s.refuse(code);
        // An orphan QUIC was already done with: nothing else frees it.
        if (s.protocol_done) s.maybeFree();
    }

    /// Resets the stream both ways with `code`. Locked.
    fn refuse(s: *Stream, code: u64) void {
        const core = s.core;
        if (!s.protocol_done and !core.closed) _ = c.ngtcp2_conn_shutdown_stream(core.q, 0, s.id, code);
        if (s.recv_err == null and !s.in_fin) s.recv_err = error.StreamReset;
        if (s.send_err == null) s.send_err = error.StreamReset;
        s.discardInput();
        s.dequeue();
        s.tx.notify(core.io);
    }

    /// Whatever is buffered, and arrives from now on, is dropped, its
    /// credit returned. Locked.
    fn discardInput(s: *Stream) void {
        const core = s.core;
        s.discarding = true;
        const left = s.in.len;
        if (left > 0 and !s.protocol_done and !core.closed) bridge.consume(core.q, s.id, left);
        s.in.deinit(core.pool());
        s.rx.notify(core.io);
    }

    /// Received data (`error.EndOfStream` at the peer's FIN). A stream
    /// that ended early fails with `ReadFailed`; `readError` says why.
    pub fn reader(s: *Stream) *std.Io.Reader {
        return &s.reader_iface;
    }

    /// Data to send; `flush` sends what is buffered, `closeSend` ends it.
    pub fn writer(s: *Stream) *std.Io.Writer {
        return &s.writer_iface;
    }

    /// Why reading failed (`StreamReset`, `SessionClosed`...), or null.
    pub fn readError(s: *const Stream) ?Error {
        return s.read_err;
    }

    /// Why writing failed (`StreamStopped`, `SessionClosed`...), or null.
    pub fn writeError(s: *const Stream) ?Error {
        return s.write_err;
    }

    /// The application code of the peer's RESET_STREAM, if it sent one.
    pub fn resetCode(s: *Stream) ?u32 {
        const host = s.core.host;
        host.lock();
        defer host.unlock();
        return s.reset_code;
    }

    /// The application code of the peer's STOP_SENDING, if it sent one.
    pub fn stopCode(s: *Stream) ?u32 {
        const host = s.core.host;
        host.lock();
        defer host.unlock();
        return s.stop_code;
    }

    /// Sets the stream's urgency (RFC 9218): 0 most urgent, 7 least, 3 the
    /// default. Its data goes out before any more-urgent-numbered stream's
    /// (higher numbers), and streams of one urgency take turns packet by
    /// packet. A busy stream at a low number starves the higher ones, as in
    /// the RFC: mark audio or control 2, not 0. Takes effect for the next
    /// packet.
    pub fn setPriority(s: *Stream, urgency: u3) void {
        const host = s.core.host;
        host.lock();
        if (s.urgency != urgency) {
            const was_queued = s.queued;
            s.dequeue();
            s.urgency = urgency;
            if (was_queued) s.enqueue();
        }
        host.unlock();
        host.kick();
    }

    /// Sends what is buffered and then the end of the stream (FIN).
    pub fn closeSend(s: *Stream) !void {
        try s.writer_iface.flush();
        const host = s.core.host;
        host.lock();
        if (!s.send_closed and s.send_err == null) {
            s.send_closed = true;
            s.enqueue();
        }
        host.unlock();
        host.kick();
    }

    /// Abandons sending: RESET_STREAM with the application `code`.
    pub fn reset(s: *Stream, code: u32) void {
        const core = s.core;
        core.host.lock();
        defer core.host.unlock();
        if (s.kind == .uni_in or s.send_err != null or s.fin_sent) return;
        if (!s.protocol_done and !core.closed) _ = c.ngtcp2_conn_shutdown_stream_write(core.q, 0, s.id, toHttp3Error(code));
        s.send_err = error.StreamReset;
        s.dequeue();
        s.tx.notify(core.io);
        core.host.kick();
    }

    /// Asks the peer to stop sending (STOP_SENDING with `code`); what
    /// arrives from now on is dropped.
    pub fn stopSending(s: *Stream, code: u32) void {
        const core = s.core;
        core.host.lock();
        defer core.host.unlock();
        if (s.kind == .uni_out or s.in_fin or s.recv_err != null) return;
        if (!s.protocol_done and !core.closed) _ = c.ngtcp2_conn_shutdown_stream_read(core.q, 0, s.id, toHttp3Error(code));
        s.recv_err = error.StreamReset;
        s.discardInput();
        s.rx.notify(core.io);
        core.host.kick();
    }

    /// Done with the stream. A sending side not ended with `closeSend` is
    /// reset, and a receiving side not read to its end is stopped (code 0
    /// for both); what was sent with its end still arrives.
    pub fn release(s: *Stream) void {
        const core = s.core;
        core.host.lock();
        defer core.host.unlock();
        if (!s.protocol_done and !core.closed) {
            if (s.kind != .uni_in and !s.send_closed and s.send_err == null) {
                _ = c.ngtcp2_conn_shutdown_stream_write(core.q, 0, s.id, toHttp3Error(0));
                s.send_err = error.StreamReset;
                s.dequeue();
            }
            const all_read = s.in_fin and s.in.len == 0;
            if (s.kind != .uni_out and !all_read and s.recv_err == null) {
                _ = c.ngtcp2_conn_shutdown_stream_read(core.q, 0, s.id, toHttp3Error(0));
                s.recv_err = error.StreamReset;
            }
        }
        s.discardInput();
        s.user_done = true;
        s.wakeAll();
        s.maybeFree();
        core.host.kick();
    }

    /// What `tryRead` found: `n` bytes; `fin` when the peer's end has
    /// been read (with them or before); `err` when the stream ended early
    /// (`resetCode` for the peer's code). All empty: nothing yet.
    /// The calls Anole's own drivers make on a stream: they never wait.
    /// Not for handlers; they change without notice.
    pub const Driver = struct {
        /// What `tryRead` found: `n` bytes; `fin` when the peer's end has
        /// been read (with them or before); `err` when the stream ended
        /// early (`resetCode` for the peer's code). All empty: nothing yet.
        pub const Poll = struct { n: usize = 0, fin: bool = false, err: ?Error = null };

        /// Reads what has arrived into `buf`, without waiting.
        pub fn tryRead(s: *Stream, buf: []u8) Poll {
            return s.tryRead(buf);
        }
        /// Copies what fits of `bytes` into the stream's send buffer
        /// without waiting: 0 while it is full (until the peer acknowledges
        /// more). Bypasses `writer`'s buffer: use one or the other.
        pub fn tryWrite(s: *Stream, bytes: []const u8) Error!usize {
            return s.tryWrite(bytes);
        }
        /// Why the sending side ended early (`StreamStopped`, with
        /// `stopCode`; `StreamReset`; `SessionClosed`...), or null while it
        /// can send.
        pub fn sendError(s: *Stream) ?Error {
            return s.sendError();
        }
        /// Sets the stream's urgency, 0..7 (`Stream.setPriority`).
        pub fn setPriority(s: *Stream, urgency: u3) void {
            s.setPriority(urgency);
        }
    };

    /// Reads what has arrived into `buf`, without waiting.
    fn tryRead(s: *Stream, buf: []u8) Driver.Poll {
        const core = s.core;
        if (s.kind == .uni_out) return .{ .fin = true };
        core.host.lock();
        const n = s.takeLocked(buf);
        const out: Driver.Poll = .{
            .n = n,
            .fin = s.in_fin and s.in.len == 0,
            .err = if (n == 0 and !s.in_fin) s.recv_err else null,
        };
        core.host.unlock();
        if (n > 0) core.host.kick();
        return out;
    }

    /// Copies what fits of `bytes` into the stream's send buffer without
    /// waiting: 0 while it is full (until the peer acknowledges more).
    /// Bypasses `writer`'s buffer: use one or the other.
    fn tryWrite(s: *Stream, bytes: []const u8) Error!usize {
        const core = s.core;
        if (s.kind == .uni_in) return error.StreamReset;
        core.host.lock();
        if (s.send_err != null or s.send_closed or core.closed) {
            const err = s.send_err orelse if (core.closed) error.ConnectionClosed else error.StreamReset;
            core.host.unlock();
            return err;
        }
        const n = s.out.write(core.pool(), core.budget(), bytes, core.limits.send_buffer, false) catch {
            core.host.unlock();
            return error.ConnectionClosed;
        };
        if (n > 0) s.enqueue();
        core.host.unlock();
        if (n > 0) core.host.kick();
        return n;
    }

    /// Why the sending side ended early (`StreamStopped`, with `stopCode`;
    /// `StreamReset`; `SessionClosed`...), or null while it can send.
    fn sendError(s: *Stream) ?Error {
        const host = s.core.host;
        host.lock();
        defer host.unlock();
        return s.send_err;
    }

    /// Up to `dest.len` received bytes, giving the peer that much credit.
    /// Locked.
    fn takeLocked(s: *Stream, dest: []u8) usize {
        const core = s.core;
        if (s.in.len == 0 or dest.len == 0) return 0;
        const n = s.in.take(core.pool(), dest);
        // The peer may send that much more.
        if (!s.protocol_done and !core.closed) bridge.consume(core.q, s.id, n);
        return n;
    }

    fn readStream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const s: *Stream = @alignCast(@fieldParentPtr("reader_iface", r));
        const core = s.core;
        if (s.kind == .uni_out) return error.EndOfStream;
        const dest = limit.slice(try w.writableSliceGreedy(1));
        if (dest.len == 0) return 0;
        while (true) {
            const seen = s.rx.epoch();
            core.host.lock();
            const n = s.takeLocked(dest);
            if (n > 0) {
                core.host.unlock();
                core.host.kick();
                w.advance(n);
                return n;
            }
            const fin = s.in_fin;
            const err = s.recv_err;
            core.host.unlock();
            if (fin) return error.EndOfStream;
            if (err) |e| {
                s.read_err = e;
                return error.ReadFailed;
            }
            s.rx.wait(core.io, seen) catch {
                s.read_err = error.Canceled;
                return error.ReadFailed;
            };
        }
    }

    /// Copies bytes into the ring, waiting while it is full (the peer has
    /// not acknowledged enough yet).
    fn put(s: *Stream, bytes: []const u8) std.Io.Writer.Error!void {
        const core = s.core;
        if (s.kind == .uni_in) return error.WriteFailed;
        var rest = bytes;
        while (rest.len > 0) {
            const seen = s.tx.epoch();
            core.host.lock();
            if (s.send_err != null or s.send_closed or core.closed) {
                s.write_err = s.send_err orelse if (core.closed) error.ConnectionClosed else error.StreamReset;
                core.host.unlock();
                return error.WriteFailed;
            }
            const n = s.out.write(core.pool(), core.budget(), rest, core.limits.send_buffer, false) catch {
                core.host.unlock();
                return error.WriteFailed;
            };
            if (n > 0) {
                rest = rest[n..];
                s.enqueue();
            } else {
                // Woken by an acknowledgment, or when the connection's
                // budget has room.
                s.waiter.signal = &s.tx;
                core.budget().link(&s.waiter);
            }
            core.host.unlock();
            // Kick only for new bytes; see the server's StreamSink.put.
            if (n > 0) core.host.kick() else s.tx.wait(core.io, seen) catch {
                s.write_err = error.Canceled;
                return error.WriteFailed;
            };
        }
    }

    fn drainOut(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const s: *Stream = @alignCast(@fieldParentPtr("writer_iface", w));
        try s.put(w.buffered());
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try s.put(bytes);
            n += bytes.len;
        }
        for (0..splat) |_| try s.put(data[data.len - 1]);
        return n + data[data.len - 1].len * splat;
    }

    fn flushOut(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const s: *Stream = @alignCast(@fieldParentPtr("writer_iface", w));
        try s.put(w.buffered());
        w.end = 0;
    }
};

/// What the HTTP/3 server hands `anole.webtransport.accept` through the
/// request (`Request.setLocal` under `local_key`): the connection's
/// WebTransport and the CONNECT stream.
pub const Connect = struct {
    core: *Core,
    session_id: i64,
};
pub const local_key = "anole.webtransport";

test "varints round trip at every length" {
    var buf: [8]u8 = undefined;
    for ([_]u64{ 0, 63, 64, 16383, 16384, (1 << 30) - 1, 1 << 30, (1 << 62) - 1, stream_type_uni, signal_bidi, setting_enable_webtransport }) |v| {
        const n = putVarint(&buf, v);
        try std.testing.expectEqual(varintLen(v), n);
        const got = getVarint(buf[0..n]).?;
        try std.testing.expectEqual(v, got.value);
        try std.testing.expectEqual(n, got.len);
        if (n > 1) try std.testing.expectEqual(@as(?Varint, null), getVarint(buf[0 .. n - 1]));
    }
    // The examples in RFC 9000 §A.1.
    try std.testing.expectEqual(@as(u64, 151288809941952652), getVarint(&.{ 0xc2, 0x19, 0x7c, 0x5e, 0xff, 0x14, 0xe8, 0x8c }).?.value);
    try std.testing.expectEqual(@as(u64, 494878333), getVarint(&.{ 0x9d, 0x7f, 0x3e, 0x7d }).?.value);
    try std.testing.expectEqual(@as(u64, 15293), getVarint(&.{ 0x7b, 0xbd }).?.value);
    try std.testing.expectEqual(@as(u64, 37), getVarint(&.{0x25}).?.value);
}

test "WebTransport error codes map onto HTTP/3's and back, skipping the reserved ones" {
    try std.testing.expectEqual(app_error_first, toHttp3Error(0));
    try std.testing.expectEqual(app_error_last, toHttp3Error(std.math.maxInt(u32)));
    var code: u32 = 0;
    while (code < 2000) : (code += 1) {
        const wire = toHttp3Error(code);
        try std.testing.expect((wire - 0x21) % 0x1f != 0);
        try std.testing.expectEqual(@as(?u32, code), fromHttp3Error(wire));
    }
    try std.testing.expectEqual(@as(?u32, std.math.maxInt(u32)), fromHttp3Error(app_error_last));
    try std.testing.expectEqual(@as(?u32, null), fromHttp3Error(0x100));
    try std.testing.expectEqual(@as(?u32, null), fromHttp3Error(error_session_gone));
}
