// StreamTable translated from nghttp2 (MIT, Copyright (c) 2017 ngtcp2
// contributors; Copyright (c) 2012 nghttp2 contributors), and the window and
// content-length helpers and the closed-stream memory from nghttp2 (MIT,
// Copyright (c) 2012, 2015 Tatsuhiro Tsujikawa), v1.70.0 via Anole's fork
// xuckless/nghttp2 0f8bc1c: lib/nghttp2_map.c, lib/nghttp2_session.c (the
// fork patch's closed-stream memory), lib/nghttp2_stream.c and
// lib/nghttp2_http.c. See LICENSE.nghttp2 and THIRD_PARTY_NOTICES. The slab
// is Anole's own.

//! HTTP/2 stream state (research/h2h3-takeover/PLAN.md §3.1, §3.4): the
//! `Stream`, the slab it lives in, the table of live streams keyed by ID, and
//! the memory of recently closed peer streams the RFC 9113 §5.1 checks need
//! (`ClosedRing`, `OpenedBitmap`, `peerFate`; §5.2 of the plan). conn.zig
//! owns one of each per connection, on one executor: nothing here reads a
//! clock, yields or takes a lock.

const std = @import("std");
const Allocator = std.mem.Allocator;
const frame = @import("frame.zig");
const max_window_size = frame.max_window_size;

/// RFC 9113 §5.1, without the reserved states (server push is dropped).
pub const State = enum(u8) { idle, open, half_closed_remote, half_closed_local, closed };

pub const Flags = packed struct(u8) {
    /// A HEADERS block has been received: the next one is trailers
    /// (RFC 9113 §8.1).
    headers_received: bool = false,
    /// The header block being received is trailers (until END_HEADERS).
    in_trailers: bool = false,
    /// END_STREAM is queued (not yet sent): the stream was answered, so a
    /// reset after this is not charged to the reset budget (PLAN §5.4, D15).
    answered: bool = false,
    /// The response's HEADERS went out (conn.zig's submitHead).
    head_sent: bool = false,
    /// The stream's ID is in conn.zig's ready queue (out.zig): it has
    /// output to frame and send credit.
    ready: bool = false,
    _: u3 = 0,
};

/// One stream. END_STREAM received and sent are the state (half_closed_remote
/// and half_closed_local), not flags. A `*Stream` is stable from
/// `Slab.create` to `Slab.destroy`.
pub const Stream = struct {
    id: u31,
    /// The peer's credit for us. May go negative after the peer lowers
    /// SETTINGS_INITIAL_WINDOW_SIZE (RFC 9113 §6.9.2).
    send_window: i32,
    /// Our credit for the peer: DATA past it is FLOW_CONTROL_ERROR.
    recv_window: i32,
    /// Consumed but not yet announced in a WINDOW_UPDATE (conn batches).
    recv_unacked: u32 = 0,
    /// The declared content-length minus the DATA received so far; -1 when
    /// none was declared.
    content_left: i64 = -1,
    state: State = .idle,
    flags: Flags = .{},
    /// The code it closed with (RST_STREAM's, or NO_ERROR), for
    /// conn.zig's deferred onStreamClose. Sits in padding: the size stays
    /// 64 bytes.
    code: frame.ErrorCode = .no_error,
    /// The handler's side of the stream.
    user: ?*anyopaque = null,
    /// The queued output (conn.zig's `Pending` nodes: borrowed DATA parts
    /// and trailers), oldest first.
    pending: std.DoublyLinkedList = .{},
    /// The slab's freelist while the stream is free; conn.zig's list of
    /// closed streams awaiting onStreamClose once it is closed. Never both.
    link: std.SinglyLinkedList.Node = .{},

    /// Receiving END_STREAM (open -> half_closed_remote -> closed). The
    /// caller has checked the stream can receive.
    pub fn recvEnd(s: *Stream) void {
        s.state = switch (s.state) {
            .open => .half_closed_remote,
            .half_closed_local => .closed,
            else => unreachable,
        };
    }

    /// Sending END_STREAM (open -> half_closed_local -> closed). The caller
    /// has checked the stream can send.
    pub fn sendEnd(s: *Stream) void {
        s.state = switch (s.state) {
            .open => .half_closed_local,
            .half_closed_remote => .closed,
            else => unreachable,
        };
    }

    /// The peer may still send frames that carry data on it.
    pub fn canRecv(s: *const Stream) bool {
        return s.state == .open or s.state == .half_closed_local;
    }

    /// We may still send DATA or HEADERS on it.
    pub fn canSend(s: *const Stream) bool {
        return s.state == .open or s.state == .half_closed_remote;
    }

    /// nghttp2_http_on_data_chunk: `n` bytes of DATA arrived. More than the
    /// declared content-length makes the request malformed (RFC 9113 §8.1.1).
    /// One counter replaces nghttp2's two (`content_length` and
    /// `recv_content_length`). The client role's EXPECT_FINAL_RESPONSE check
    /// is M5's.
    pub fn onDataChunk(s: *Stream, n: usize) error{Malformed}!void {
        if (s.content_left == -1) return;
        if (n > s.content_left) return error.Malformed;
        s.content_left -= @intCast(n);
    }

    /// nghttp2_http_on_remote_end_stream: at END_STREAM the DATA must add up
    /// to the declared content-length.
    pub fn onRemoteEnd(s: *const Stream) error{Malformed}!void {
        if (s.content_left > 0) return error.Malformed;
    }
};

/// nghttp2_stream.c update_initial_window_size: moves a stream window by the
/// change of SETTINGS_INITIAL_WINDOW_SIZE (the send window on the peer's
/// SETTINGS, the receive window on the ACK of ours). The window may go
/// negative; past 2^31-1 (or below the i32 range) is FLOW_CONTROL_ERROR
/// (RFC 9113 §6.9.2), and the window is left as it was.
pub fn updateInitialWindow(w: *i32, new: u31, old: u31) error{FlowControl}!void {
    const v: i64 = @as(i64, w.*) + new - old;
    if (v < std.math.minInt(i32) or v > max_window_size) return error.FlowControl;
    w.* = @intCast(v);
}

/// Streams from 31-stream chunks with a LIFO freelist (PLAN §3.4). 31 x 64 B
/// plus the link is 1992 B, which with malloc's 16 B header still fits the
/// allocators' 2 KiB size class (32 streams would spill into 4 KiB and waste
/// half of it). Chunks are kept until `deinit`, so a connection keeps its
/// high-water mark (9 chunks, 18 KiB, at 250 streams); returning idle chunks
/// is M3 (the block cache's smallest class is 64 KiB, so chunks stay on the
/// general allocator).
pub const Slab = struct {
    gpa: Allocator,
    chunks: ?*Chunk = null,
    free: std.SinglyLinkedList = .{},

    pub const chunk_len = 31;
    pub const Chunk = struct {
        next: ?*Chunk,
        streams: [chunk_len]Stream,
    };

    pub fn init(gpa: Allocator) Slab {
        return .{ .gpa = gpa };
    }

    /// Frees every chunk; streams still out are gone with them.
    pub fn deinit(sl: *Slab) void {
        while (sl.chunks) |c| {
            sl.chunks = c.next;
            sl.gpa.destroy(c);
        }
        sl.free = .{};
    }

    pub fn create(sl: *Slab, id: u31, send_window: i32, recv_window: i32) Allocator.Error!*Stream {
        const node = sl.free.popFirst() orelse node: {
            const c = try sl.gpa.create(Chunk);
            c.next = sl.chunks;
            sl.chunks = c;
            var i: usize = chunk_len;
            while (i > 1) {
                i -= 1;
                sl.free.prepend(&c.streams[i].link);
            }
            break :node &c.streams[0].link;
        };
        const s: *Stream = @fieldParentPtr("link", node);
        s.* = .{ .id = id, .send_window = send_window, .recv_window = recv_window };
        return s;
    }

    /// In safe builds the ID is poisoned to 0 (never a stream's), so a
    /// holder of a stale pointer can check `s.id` against the one it expects
    /// (hyperium/h2's ABA guard, without the extra field).
    pub fn destroy(sl: *Slab, s: *Stream) void {
        std.debug.assert(s.pending.first == null);
        if (std.debug.runtime_safety) s.id = 0;
        sl.free.prepend(&s.link);
    }
};

/// The live streams by ID: nghttp2_map.c (Robin Hood open addressing with a
/// per-slot probe sequence length, 0 = empty, and backward-shift deletion:
/// no tombstones) specialised to `u31 -> *Stream`.
///
/// The one change is the sizing: nothing is allocated until the first
/// insert, then 16 slots, doubling when the load would pass 1/2 (nghttp2:
/// 7/8), and never shrinking. At 250 concurrent streams that is 512 slots
/// of 13 B (6656 B, an 8 KiB size class); once a connection has reached its high-water mark it never
/// rehashes again. nghttp2's resize at a probe length of 128 stays as the
/// safety net that keeps the u8 lengths from overflowing; long probes need
/// many IDs on one home slot, which a peer can only aim for if it knows the
/// seed, so conn.zig (M3) takes a fresh CSPRNG seed per connection.
pub const StreamTable = struct {
    gpa: Allocator,
    seed: u64,
    /// Only for the Debug bound check: the table holds the streams that count
    /// toward SETTINGS_MAX_CONCURRENT_STREAMS (RFC 9113 §5.1.2).
    max_live: u32,
    size: u32 = 0,
    /// log2 of the slot count; 0 before the first insert.
    hashbits: u6 = 0,
    // One allocation, laid out as in map_resize: vals, keys, psl.
    // SAFETY: set by the first resize; nothing reads them while hashbits is 0.
    vals: [*]*Stream = undefined,
    // SAFETY: as `vals`.
    keys: [*]u32 = undefined,
    // SAFETY: as `vals`.
    psl: [*]u8 = undefined,

    const initial_hashbits = 4; // NGHTTP2_INITIAL_HASHBITS
    const max_psl_resize_thresh = 128; // NGHTTP2_MAX_PSL_RESIZE_THRESH
    const hasher = 0xF1357AEA2E62A9C5; // NGHTTP2_MAP_HASHER (rustc-hash)
    const fibo = 0x9E3779B97F4A7C15; // NGHTTP2_MAP_FIBO
    const slot_bytes = @sizeOf(*Stream) + @sizeOf(u32) + @sizeOf(u8);

    /// `seed` must come from a CSPRNG per connection in production (hash
    /// flooding; nghttp2 falls back to 0 without a rand callback); tests pass
    /// fixed ones.
    pub fn init(gpa: Allocator, max_live: u32, seed: u64) StreamTable {
        return .{ .gpa = gpa, .max_live = max_live, .seed = seed };
    }

    pub fn deinit(t: *StreamTable) void {
        if (t.hashbits != 0) t.gpa.free(buffer(t.vals, t.hashbits));
        // SAFETY: the table is dead after deinit.
        t.* = undefined;
    }

    pub fn slots(t: *const StreamTable) usize {
        return if (t.hashbits == 0) 0 else @as(usize, 1) << t.hashbits;
    }

    fn buffer(vals: [*]*Stream, hashbits: u6) []align(@alignOf(*Stream)) u8 {
        // SAFETY: `vals` is the start of resize's allocation.
        const p: [*]align(@alignOf(*Stream)) u8 = @ptrCast(vals);
        return p[0 .. (@as(usize, 1) << hashbits) * slot_bytes];
    }

    /// map_index: a key's home slot (public for the tests' invariants).
    pub fn index(t: *const StreamTable, key: u32) usize {
        const k = (@as(u64, key) +% t.seed) *% hasher;
        return @intCast((k *% fibo) >> @intCast(@as(u7, 64) - t.hashbits));
    }

    fn setEntry(t: *StreamTable, idx: usize, key: u32, val: *Stream, psl: usize) void {
        t.keys[idx] = key;
        t.vals[idx] = val;
        t.psl[idx] = @intCast(psl);
    }

    /// map_insert: returns the slot the last displaced entry landed in. The
    /// key must be absent (nghttp2 returns INVALID_ARGUMENT; conn.zig never
    /// inserts twice).
    fn place(t: *StreamTable, key_in: u32, val_in: *Stream) usize {
        var key = key_in;
        var val = val_in;
        var idx = t.index(key);
        const mask = t.slots() - 1;
        var psl: usize = 1;
        while (true) {
            const kpsl = t.psl[idx];
            if (kpsl == 0) {
                t.setEntry(idx, key, val, psl);
                t.size += 1;
                return idx;
            }
            if (psl > kpsl) {
                std.mem.swap(u32, &key, &t.keys[idx]);
                std.mem.swap(*Stream, &val, &t.vals[idx]);
                const old: usize = kpsl;
                t.psl[idx] = @intCast(psl);
                psl = old;
            } else std.debug.assert(t.keys[idx] != key);
            psl += 1;
            idx = (idx + 1) & mask;
        }
    }

    /// map_resize.
    fn resize(t: *StreamTable, new_hashbits: u6) Allocator.Error!void {
        const len = @as(usize, 1) << new_hashbits;
        const buf = try t.gpa.alignedAlloc(u8, .of(*Stream), len * slot_bytes);
        var new: StreamTable = .{
            .gpa = t.gpa,
            .seed = t.seed,
            .max_live = t.max_live,
            .hashbits = new_hashbits,
            // SAFETY: the buffer is aligned for pointers and has room for
            // `len` of each array, in this order (map_resize's layout).
            .vals = @ptrCast(buf.ptr),
            // SAFETY: as `vals`; 4-byte aligned after `len` pointers.
            .keys = @ptrCast(@alignCast(buf.ptr + len * @sizeOf(*Stream))),
            .psl = buf.ptr + len * (@sizeOf(*Stream) + @sizeOf(u32)),
        };
        @memset(new.psl[0..len], 0);
        for (0..t.slots()) |i| {
            if (t.psl[i] != 0) _ = new.place(t.keys[i], t.vals[i]);
        }
        std.debug.assert(new.size == t.size);
        if (t.hashbits != 0) t.gpa.free(buffer(t.vals, t.hashbits));
        t.* = new;
    }

    /// nghttp2_map_insert. `s.id` is the key, and must not be in the table.
    /// On an error the table is as it was: `s` is not in it, so the caller
    /// may destroy it (nghttp2 leaves the entry in when the probe-length
    /// resize fails, and its caller then frees the stream).
    pub fn insert(t: *StreamTable, s: *Stream) Allocator.Error!void {
        std.debug.assert(t.size < @as(u64, t.max_live) * 2);
        if (t.hashbits == 0 or t.size + 1 > t.slots() / 2) {
            try t.resize(if (t.hashbits == 0) initial_hashbits else t.hashbits + 1);
        }
        const idx = t.place(s.id, s);
        // Resize if psl reaches a really large value, which is almost
        // improbable, but just in case (nghttp2).
        if (t.psl[idx] - 1 < max_psl_resize_thresh) return;
        t.resize(t.hashbits + 1) catch |err| {
            std.debug.assert(t.remove(s.id));
            return err;
        };
    }

    /// nghttp2_map_find.
    pub fn get(t: *const StreamTable, id: u31) ?*Stream {
        if (t.size == 0) return null;
        var idx = t.index(id);
        const mask = t.slots() - 1;
        var psl: usize = 1;
        while (true) {
            if (psl > t.psl[idx]) return null;
            if (t.keys[idx] == id) return t.vals[idx];
            psl += 1;
            idx = (idx + 1) & mask;
        }
    }

    /// nghttp2_map_remove: backward-shift deletion. Returns whether `id` was
    /// there.
    pub fn remove(t: *StreamTable, id: u31) bool {
        if (t.size == 0) return false;
        var idx = t.index(id);
        const mask = t.slots() - 1;
        var psl: usize = 1;
        while (true) {
            if (psl > t.psl[idx]) return false;
            if (t.keys[idx] == id) {
                var dest = idx;
                idx = (idx + 1) & mask;
                while (true) {
                    const kpsl = t.psl[idx];
                    if (kpsl <= 1) {
                        t.psl[dest] = 0;
                        break;
                    }
                    t.setEntry(dest, t.keys[idx], t.vals[idx], kpsl - 1);
                    dest = idx;
                    idx = (idx + 1) & mask;
                }
                t.size -= 1;
                return true;
            }
            psl += 1;
            idx = (idx + 1) & mask;
        }
    }

    /// nghttp2_map_each as a cursor, so the caller's errors propagate:
    /// `var i: usize = 0; while (t.next(&i)) |s| ...`. The table must not
    /// change during the walk.
    pub fn next(t: *const StreamTable, i: *usize) ?*Stream {
        const n = t.slots();
        while (i.* < n) {
            const at = i.*;
            i.* += 1;
            if (t.psl[at] != 0) return t.vals[at];
        }
        return null;
    }
};

/// What became of a peer stream that has no `Stream` and is not idle
/// (the fork patch's nghttp2_peer_stream_fate). conn.zig maps it to the
/// PLAN §5.2 answers.
pub const Fate = enum(u3) {
    /// Not remembered: closed too long ago, or never seen.
    unknown = 0,
    /// The peer reset it with RST_STREAM.
    rst_received = 1,
    /// It closed normally after the peer sent END_STREAM.
    end_stream = 2,
    /// We reset it: the peer may still have frames in flight. Wins over
    /// end_stream when we reset a stream the peer had ended.
    rst_sent = 3,
    /// Below the highest ID received and never opened, so closed implicitly
    /// (RFC 9113 §5.1.1). Comes from `OpenedBitmap`, never stored.
    never_opened = 4,
};

/// The last 256 closed peer streams and how each closed
/// (NGHTTP2_CLOSED_STREAM_LOG_LEN). Packed to 4 bytes an entry: only peer IDs
/// are recorded (one parity), so `id >> 1` fits in 30 bits, and the three
/// stored fates fit in 2 with 0 meaning an empty slot. 1028 B against the
/// patch's 2056. Because of the packing an ID of our parity would alias its
/// peer neighbour, so `record` and `peerFate` keep the patch's
/// is_my_stream_id guard and ignore those IDs.
pub const ClosedRing = struct {
    slots: [len]Record = @splat(.{}),
    next: u8 = 0,

    pub const len = 256;
    const Record = packed struct(u32) { fate: u2 = 0, half_id: u30 = 0 };

    /// session_log_peer_stream_closed. `peer_parity` is 1 for a server (the
    /// client opens odd IDs); our own IDs are not recorded.
    pub fn record(r: *ClosedRing, peer_parity: u1, id: u31, how: Fate) void {
        std.debug.assert(how == .rst_received or how == .end_stream or how == .rst_sent);
        if (id & 1 != peer_parity) return;
        r.slots[r.next] = .{ .fate = @intCast(@backingInt(how)), .half_id = @intCast(id >> 1) };
        r.next +%= 1;
    }

    /// The ring half of session_peer_stream_fate: a scan of all 256 entries
    /// (only for a frame on a stream without a `Stream`). Peer IDs only; use
    /// `peerFate`, which checks the parity.
    pub fn lookup(r: *const ClosedRing, id: u31) Fate {
        const half: u30 = @intCast(id >> 1);
        for (r.slots) |rec| {
            if (rec.fate != 0 and rec.half_id == half) return @fromBackingInt(@as(u3, rec.fate));
        }
        return .unknown;
    }
};

/// Which of the last 2048 peer stream IDs (one parity, so a span of 4096
/// IDs; NGHTTP2_OPENED_STREAM_WINDOW) were opened, so an ID that was skipped
/// can be told from one that closed and was forgotten. `last_recv` is
/// conn.zig's highest peer stream ID received (0 before the first).
pub const OpenedBitmap = struct {
    bits: std.StaticBitSet(window) = .empty,

    pub const window = 2048;

    fn bit(id: u31) usize {
        return (id >> 1) & (window - 1);
    }

    /// session_mark_peer_stream_opened: the peer opened `id`, above
    /// `last_recv`; the IDs skipped in between were closed without being
    /// opened. Call it before `last_recv` moves to `id`.
    pub fn markOpened(b: *OpenedBitmap, last_recv: u31, id: u31) void {
        std.debug.assert(last_recv == 0 or (last_recv ^ id) & 1 == 0);
        const from: u32 = if (last_recv == 0) id & 1 else @as(u32, last_recv) + 2;
        if (id < from or (id - from) / 2 >= window) {
            b.bits = .empty;
        } else {
            // The patch clears the skipped IDs one by one; a range clears a
            // word at a time, wrapping past the end of the window.
            const start = bit(@intCast(from));
            const end = start + (id - from) / 2;
            b.bits.setRangeValue(.{ .start = start, .end = @min(end, window) }, false);
            if (end > window) b.bits.setRangeValue(.{ .start = 0, .end = end - window }, false);
        }
        b.bits.set(bit(id));
    }

    /// The bitmap half of session_peer_stream_fate. Peer IDs only.
    pub fn neverOpened(b: *const OpenedBitmap, last_recv: u31, id: u31) bool {
        std.debug.assert(last_recv == 0 or (last_recv ^ id) & 1 == 0);
        return id < last_recv and (last_recv - id) / 2 < window and !b.bits.isSet(bit(id));
    }
};

/// session_peer_stream_fate for an ID with no `Stream` that is not idle: a
/// ring entry first, then the bitmap. One of our own IDs is `.unknown`, as
/// the patch's is_my_stream_id guard returns (`peer_parity` as in `record`).
pub fn peerFate(r: *const ClosedRing, b: *const OpenedBitmap, peer_parity: u1, last_recv: u31, id: u31) Fate {
    if (id & 1 != peer_parity) return .unknown;
    const f = r.lookup(id);
    if (f != .unknown) return f;
    return if (b.neverOpened(last_recv, id)) .never_opened else .unknown;
}
