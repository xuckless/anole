//! The ngtcp2-to-nghttp3 bridge that the HTTP/3 server and client share:
//! stream data in, and packets out with nghttp3's frames in them. Each
//! runs with the connection's mutex held. After ngtcp2's
//! examples/http3_server_proto_codec.cc and http3_client_proto_codec.cc
//! (MIT).
const std = @import("std");
const builtin = @import("builtin");
const ngtcp2 = @import("ngtcp2.zig");
const nghttp3 = @import("nghttp3.zig");
const webtransport = @import("webtransport.zig");

const c = ngtcp2.c;
const h = nghttp3.c;

const log = std.log.scoped(.anole_h3);

/// One side of a connection, as the bridge sees it.
pub const Side = struct {
    q: *c.ngtcp2_conn,
    h3: ?*h.nghttp3_conn,
    last_error: *c.ngtcp2_ccerr,
    /// WebTransport's streams and datagrams, when the connection speaks it.
    wt: ?*webtransport.Core = null,
};

/// Feeds nghttp3 the stream data ngtcp2 delivered, and gives back the
/// flow-control credit for nghttp3's own framing (a body's comes back as
/// it is read). WebTransport's streams are taken out first, so nghttp3
/// never sees them. Returns an ngtcp2 callback result.
pub fn recvStreamData(side: Side, flags: u32, stream_id: i64, offset: u64, data: []const u8) c_int {
    const fin = flags & c.NGTCP2_STREAM_DATA_FLAG_FIN != 0;
    var replay: []const u8 = &.{};
    var head: webtransport.Partial = .{};
    if (side.wt) |w| {
        const route = w.route(stream_id, offset, data, fin) catch return c.NGTCP2_ERR_CALLBACK_FAILURE;
        switch (route) {
            .taken => return 0,
            .http3 => |partial| {
                head = partial;
                replay = head.bytes[0..head.len];
            },
        }
    }
    const hc = side.h3 orelse return 0;
    // The first bytes of a stream WebTransport held back to look at.
    if (replay.len > 0) if (readStream(side, hc, stream_id, replay, false) != 0) return c.NGTCP2_ERR_CALLBACK_FAILURE;
    return readStream(side, hc, stream_id, data, fin);
}

fn readStream(side: Side, hc: *h.nghttp3_conn, stream_id: i64, data: []const u8, fin: bool) c_int {
    const n = h.nghttp3_conn_read_stream2(hc, stream_id, data.ptr, data.len, @intFromBool(fin), c.ngtcp2_conn_get_timestamp(side.q));
    if (n < 0) {
        log.debug("nghttp3_conn_read_stream2: {s}", .{h.nghttp3_strerror(@intCast(n))});
        c.ngtcp2_ccerr_set_application_error(side.last_error, h.nghttp3_err_infer_quic_app_error_code(@intCast(n)), null, 0);
        return c.NGTCP2_ERR_CALLBACK_FAILURE;
    }
    consume(side.q, stream_id, @intCast(n));
    return 0;
}

/// Returns `n` bytes of flow-control credit, to the stream and the
/// connection.
pub fn consume(q: *c.ngtcp2_conn, stream_id: i64, n: u64) void {
    _ = c.ngtcp2_conn_extend_max_stream_offset(q, stream_id, n);
    c.ngtcp2_conn_extend_max_offset(q, n);
}

/// ngtcp2 pulls packets; nghttp3 supplies what goes in them. The body of
/// the `write_pkt` callback of `ngtcp2_conn_write_aggregate_pkt2`.
pub fn writePacket(side: Side, p: [*c]c.ngtcp2_path, pi: [*c]c.ngtcp2_pkt_info, dest: [*c]u8, dest_len: usize, ts: u64) c.ngtcp2_ssize {
    const q = side.q;
    var vec: [16]h.nghttp3_vec = undefined;
    // WebTransport: datagrams first (they are small and go stale), then
    // its streams and nghttp3's take turns at leading a packet.
    var datagrams = side.wt != null;
    const wt_first = if (side.wt) |w| w.leads() else false;
    while (true) {
        if (side.wt) |w| {
            if (datagrams) if (w.writeDatagram(p, pi, dest[0..dest_len], ts)) |wrote| switch (wrote) {
                .more => continue,
                .packet => |n| return n,
                .skip => datagrams = false,
                .failed => |rv| return fail(side, rv),
            };
            if (wt_first) if (w.writeStream(p, pi, dest[0..dest_len], ts)) |wrote| switch (wrote) {
                .more => continue,
                .skip => {},
                .packet => |n| return n,
                .failed => |rv| return fail(side, rv),
            };
        }
        var stream_id: i64 = -1;
        var fin: c_int = 0;
        var count: h.nghttp3_ssize = 0;
        if (side.h3) |hc| if (c.ngtcp2_conn_get_max_data_left2(q) > 0) {
            count = h.nghttp3_conn_writev_stream(hc, &stream_id, &fin, &vec, vec.len);
            if (count < 0) {
                c.ngtcp2_ccerr_set_application_error(side.last_error, h.nghttp3_err_infer_quic_app_error_code(@intCast(count)), null, 0);
                return c.NGTCP2_ERR_CALLBACK_FAILURE;
            }
        };
        // Nothing from nghttp3: WebTransport's streams, if they did not
        // go first, before a packet of only acknowledgements and the like.
        if (stream_id < 0 and !wt_first) if (side.wt) |w| if (w.writeStream(p, pi, dest[0..dest_len], ts)) |wrote| switch (wrote) {
            .more => continue,
            .skip => {},
            .packet => |n| return n,
            .failed => |rv| return fail(side, rv),
        };
        var flags: u32 = c.NGTCP2_WRITE_STREAM_FLAG_MORE | c.NGTCP2_WRITE_STREAM_FLAG_PADDING;
        if (fin != 0) flags |= c.NGTCP2_WRITE_STREAM_FLAG_FIN;
        var data_len: c.ngtcp2_ssize = -1;
        const datav: []const c.ngtcp2_vec = @as([*]const c.ngtcp2_vec, @ptrCast(&vec))[0..@intCast(count)];
        const n = ngtcp2.connWritevStream(q, p, pi, dest[0..dest_len], &data_len, flags, stream_id, datav, ts);
        if (n < 0) {
            switch (n) {
                c.NGTCP2_ERR_STREAM_DATA_BLOCKED => {
                    _ = h.nghttp3_conn_block_stream(side.h3, stream_id);
                    continue;
                },
                c.NGTCP2_ERR_STREAM_SHUT_WR => {
                    _ = h.nghttp3_conn_shutdown_stream_write(side.h3, stream_id);
                    continue;
                },
                c.NGTCP2_ERR_WRITE_MORE => {
                    if (h.nghttp3_conn_add_write_offset(side.h3, stream_id, @intCast(data_len)) != 0)
                        return c.NGTCP2_ERR_CALLBACK_FAILURE;
                    continue;
                },
                else => {
                    c.ngtcp2_ccerr_set_liberr(side.last_error, @intCast(n), null, 0);
                    return c.NGTCP2_ERR_CALLBACK_FAILURE;
                },
            }
        }
        if (data_len >= 0) {
            if (h.nghttp3_conn_add_write_offset(side.h3, stream_id, @intCast(data_len)) != 0)
                return c.NGTCP2_ERR_CALLBACK_FAILURE;
        }
        return n;
    }
}

/// A write that failed with ngtcp2 error `rv`: the connection ends with it.
fn fail(side: Side, rv: c.ngtcp2_ssize) c.ngtcp2_ssize {
    if (side.last_error.error_code == 0) c.ngtcp2_ccerr_set_liberr(side.last_error, @intCast(rv), null, 0);
    return c.NGTCP2_ERR_CALLBACK_FAILURE;
}

/// Tells nghttp3 a QUIC stream closed. Returns an ngtcp2 callback result.
pub fn closeStream(side: Side, flags: u32, stream_id: i64, rx_code: u64, tx_code: u64) c_int {
    const hc = side.h3 orelse return 0;
    var h3_flags: u32 = h.NGHTTP3_STREAM_CLOSE_FLAG_NONE;
    if (flags & c.NGTCP2_STREAM_CLOSE2_FLAG_RX_APP_ERROR_CODE_SET != 0) h3_flags |= h.NGHTTP3_STREAM_CLOSE_FLAG_RX_APP_ERROR_CODE_SET;
    if (flags & c.NGTCP2_STREAM_CLOSE2_FLAG_TX_APP_ERROR_CODE_SET != 0) h3_flags |= h.NGHTTP3_STREAM_CLOSE_FLAG_TX_APP_ERROR_CODE_SET;
    const rv = h.nghttp3_conn_close_stream2(hc, h3_flags, stream_id, rx_code, tx_code);
    if (rv != 0 and rv != h.NGHTTP3_ERR_STREAM_NOT_FOUND) {
        c.ngtcp2_ccerr_set_application_error(side.last_error, h.nghttp3_err_infer_quic_app_error_code(rv), null, 0);
        return c.NGTCP2_ERR_CALLBACK_FAILURE;
    }
    return 0;
}

// -- Block-backed queues ------------------------------------------------------

pub const block_size = 4096;

/// One allocation: the link and the bytes behind it.
pub const Block = struct {
    next: ?*Block,
    data: [block_size - @sizeOf(?*Block)]u8,
};
const block_data = @sizeOf(@FieldType(Block, "data"));

/// Free blocks of one endpoint (or one client connection). All users run on
/// the owner's executor; the spin lock only keeps other Io's safe.
pub const BlockPool = struct {
    gpa: std.mem.Allocator,
    lock: std.atomic.Mutex = .unlocked,
    free: ?*Block = null,
    free_count: u32 = 0,
    /// Blocks kept for reuse; the rest go back to the allocator. Adaptive
    /// (`initAdaptive`): at least the most blocks live at once in the last
    /// window, so a steady load never mallocs or frees one.
    keep: u32,
    /// The fewest `keep` falls to, adaptive only.
    keep_min: u32,
    adaptive: bool = false,
    /// Blocks handed out and not yet returned. Under `lock`.
    live: u32 = 0,
    /// The most blocks live at once since `window_start`. Under `lock`.
    peak: u32 = 0,
    /// When the window began (`trim`), in `net.now` nanoseconds; written
    /// by the owner only.
    window_start: u64 = 0,

    /// How long a peak keeps its blocks.
    pub const window_ns: u64 = 2 * std.time.ns_per_s;

    pub fn init(gpa: std.mem.Allocator, keep: u32) BlockPool {
        return .{ .gpa = gpa, .keep = keep, .keep_min = keep };
    }

    /// A pool that keeps as many free blocks as were live at once in the
    /// last `window_ns`, at least `keep_min`: the owner calls `trim`.
    pub fn initAdaptive(gpa: std.mem.Allocator, keep_min: u32) BlockPool {
        return .{ .gpa = gpa, .keep = keep_min, .keep_min = keep_min, .adaptive = true };
    }

    fn acquire(p: *BlockPool) void {
        while (!p.lock.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn get(p: *BlockPool) error{OutOfMemory}!*Block {
        p.acquire();
        p.live += 1;
        if (p.live > p.peak) {
            p.peak = p.live;
            if (p.adaptive and p.peak > p.keep) p.keep = p.peak;
        }
        if (p.free) |b| {
            p.free = b.next;
            p.free_count -= 1;
            p.lock.unlock();
            b.next = null;
            return b;
        }
        p.lock.unlock();
        const b = p.gpa.create(Block) catch |err| {
            p.acquire();
            p.live -= 1;
            p.lock.unlock();
            return err;
        };
        b.next = null;
        return b;
    }

    pub fn put(p: *BlockPool, b: *Block) void {
        p.acquire();
        p.live -= 1;
        if (p.free_count < p.keep) {
            b.next = p.free;
            p.free = b;
            p.free_count += 1;
            p.lock.unlock();
            return;
        }
        p.lock.unlock();
        p.gpa.destroy(b);
    }

    /// Adaptive: once a window has passed since the last, `keep` becomes
    /// that window's peak (at least `keep_min`) and the free blocks past it
    /// go back to the allocator. By the owner, with `t` from `net.now`.
    pub fn trim(p: *BlockPool, t: u64) void {
        if (!p.adaptive or t -% p.window_start < window_ns) return;
        p.window_start = t;
        var extra: ?*Block = null;
        p.acquire();
        p.keep = @max(p.keep_min, p.peak);
        p.peak = p.live;
        while (p.free_count > p.keep) {
            const b = p.free.?;
            p.free = b.next;
            p.free_count -= 1;
            b.next = extra;
            extra = b;
        }
        p.lock.unlock();
        while (extra) |b| {
            extra = b.next;
            p.gpa.destroy(b);
        }
    }

    /// When `trim` next has something to give back, if it may: never while
    /// the pool keeps no more than `keep_min`. By the owner.
    pub fn trimAt(p: *BlockPool) u64 {
        if (!p.adaptive) return std.math.maxInt(u64);
        p.acquire();
        const idle = p.keep <= p.keep_min and p.free_count <= p.keep_min;
        p.lock.unlock();
        return if (idle) std.math.maxInt(u64) else p.window_start + window_ns;
    }

    pub fn liveCount(p: *BlockPool) u32 {
        p.acquire();
        defer p.lock.unlock();
        return p.live;
    }

    pub fn pooled(p: *BlockPool) u32 {
        p.acquire();
        defer p.lock.unlock();
        return p.free_count;
    }

    pub fn deinit(p: *BlockPool) void {
        var it = p.free;
        while (it) |b| {
            it = b.next;
            p.gpa.destroy(b);
        }
        p.free = null;
        p.free_count = 0;
    }
};

/// A wait point with a sleeper count, so a notify nobody waits for costs one
/// atomic add and one load (no futex bucket lock).
pub const Signal = struct {
    gen: std.atomic.Value(u32) = .init(0),
    sleepers: std.atomic.Value(u32) = .init(0),
    /// Test builds: how many waits returned.
    returns: std.atomic.Value(u32) = .init(0),
    /// Test builds: futex wake calls made.
    wakes: std.atomic.Value(u32) = .init(0),

    /// Read this BEFORE checking the state it guards.
    pub fn epoch(s: *const Signal) u32 {
        return s.gen.load(.acquire);
    }

    /// Sleeps until `notify` after `seen`.
    pub fn wait(s: *Signal, io: std.Io, seen: u32) std.Io.Cancelable!void {
        _ = s.sleepers.fetchAdd(1, .seq_cst);
        defer {
            _ = s.sleepers.fetchSub(1, .seq_cst);
            if (builtin.is_test) _ = s.returns.fetchAdd(1, .monotonic);
        }
        try io.futexWait(u32, &s.gen.raw, seen);
    }

    /// `wait`, giving up at `timeout` (returns normally then too).
    pub fn waitTimeout(s: *Signal, io: std.Io, seen: u32, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        _ = s.sleepers.fetchAdd(1, .seq_cst);
        defer {
            _ = s.sleepers.fetchSub(1, .seq_cst);
            if (builtin.is_test) _ = s.returns.fetchAdd(1, .monotonic);
        }
        try io.futexWaitTimeout(u32, &s.gen.raw, seen, timeout);
    }

    pub fn notify(s: *Signal, io: std.Io) void {
        _ = s.gen.fetchAdd(1, .seq_cst);
        if (s.sleepers.load(.seq_cst) > 0) {
            if (builtin.is_test) _ = s.wakes.fetchAdd(1, .monotonic);
            io.futexWake(u32, &s.gen.raw, std.math.maxInt(u32));
        }
    }
};

/// Bytes a connection holds unacknowledged across all its send queues.
pub const Budget = struct {
    used: usize = 0,
    max: usize = 4 << 20,
    waiting: std.DoublyLinkedList = .{},
    io: std.Io,

    pub const Waiter = struct {
        node: std.DoublyLinkedList.Node = .{},
        signal: *Signal,
        linked: bool = false,
    };

    pub fn init(io: std.Io, max: usize) Budget {
        return .{ .io = io, .max = max };
    }

    pub fn room(b: *const Budget) usize {
        return b.max -| b.used;
    }

    pub fn charge(b: *Budget, n: usize) void {
        b.used += n;
    }

    /// Frees `n` and wakes every writer waiting for room.
    pub fn release(b: *Budget, n: usize) void {
        b.used -= @min(n, b.used);
        while (b.waiting.popFirst()) |node| {
            const w: *Waiter = @alignCast(@fieldParentPtr("node", node));
            w.linked = false;
            w.signal.notify(b.io);
        }
    }

    pub fn link(b: *Budget, w: *Waiter) void {
        if (w.linked) return;
        w.linked = true;
        b.waiting.append(&w.node);
    }

    pub fn unlink(b: *Budget, w: *Waiter) void {
        if (!w.linked) return;
        w.linked = false;
        b.waiting.remove(&w.node);
    }
};

/// Send data until the peer acknowledges it. Offsets only grow: [acked,
/// sent) is handed to ngtcp2/nghttp3 (they point into it) and [sent,
/// written) is not yet. Blocks are freed as `acked` passes their end; when
/// acked == written every block goes (an idle stream holds none, unless it
/// keeps its first: `keep_first`). Only the tail block is partly filled, so
/// offsets map to blocks by arithmetic.
pub const SendQueue = struct {
    /// The queue keeps the block it first takes (`first`) when it would go
    /// back to the pool, and starts with it whenever it is empty: a pooled
    /// stream that sends small responses takes no block from the pool per
    /// response. Its owner gives it back (`releaseFirst`) when the queue
    /// goes for good.
    keep_first: bool = false,
    first: ?*Block = null,
    head: ?*Block = null,
    tail: ?*Block = null,
    /// Stream offset of head.data[0] and tail.data[0].
    head_base: u64 = 0,
    tail_base: u64 = 0,
    /// A block at or before the one holding `sent` (null: start at head).
    cursor: ?*Block = null,
    cursor_base: u64 = 0,
    acked: u64 = 0,
    sent: u64 = 0,
    written: u64 = 0,

    pub fn buffered(q: *const SendQueue) u64 {
        return q.written - q.acked;
    }

    pub fn pending(q: *const SendQueue) u64 {
        return q.written - q.sent;
    }

    pub fn allSent(q: *const SendQueue) bool {
        return q.sent == q.written;
    }

    /// Copies what fits under `cap` and the budget; returns how much. `force`
    /// ignores both (inline answers, capsules, stream prefixes) but still
    /// charges the budget.
    pub fn write(q: *SendQueue, pool: *BlockPool, budget: *Budget, bytes: []const u8, cap: usize, force: bool) error{OutOfMemory}!usize {
        var want = bytes.len;
        if (!force) {
            want = @min(want, cap -| @as(usize, @intCast(q.buffered())));
            want = @min(want, budget.room());
        }
        var done: usize = 0;
        while (done < want) {
            if (q.tail == null or q.written - q.tail_base == block_data) {
                const b = q.newBlock(pool) catch {
                    budget.charge(done);
                    if (done > 0) return done;
                    return error.OutOfMemory;
                };
                if (q.tail) |t| {
                    t.next = b;
                    q.tail_base += block_data;
                } else {
                    q.head = b;
                    q.head_base = q.written;
                    q.tail_base = q.written;
                }
                q.tail = b;
            }
            const t = q.tail.?;
            const fill: usize = @intCast(q.written - q.tail_base);
            const n = @min(want - done, block_data - fill);
            @memcpy(t.data[fill..][0..n], bytes[done..][0..n]);
            q.written += n;
            done += n;
        }
        budget.charge(done);
        return done;
    }

    fn newBlock(q: *SendQueue, pool: *BlockPool) error{OutOfMemory}!*Block {
        if (!q.keep_first or q.head != null) return pool.get();
        if (q.first) |b| {
            b.next = null;
            return b;
        }
        const b = try pool.get();
        q.first = b;
        return b;
    }

    /// A block the queue is done with: back to the pool, unless it is the
    /// one it keeps.
    fn release(q: *SendQueue, pool: *BlockPool, b: *Block) void {
        if (b == q.first) return;
        pool.put(b);
    }

    /// Gives back the block the queue keeps (`keep_first`). With nothing
    /// queued (after `deinit`).
    pub fn releaseFirst(q: *SendQueue, pool: *BlockPool) void {
        std.debug.assert(q.head == null);
        const b = q.first orelse return;
        q.first = null;
        pool.put(b);
    }

    /// The block holding offset `off` (>= acked), and its base.
    fn blockAt(q: *SendQueue, off: u64) ?struct { *Block, u64 } {
        var b = q.cursor orelse q.head orelse return null;
        var base = if (q.cursor != null) q.cursor_base else q.head_base;
        if (base > off) {
            b = q.head.?;
            base = q.head_base;
        }
        while (off >= base + block_data) {
            b = b.next orelse return null;
            base += block_data;
        }
        q.cursor = b;
        q.cursor_base = base;
        return .{ b, base };
    }

    /// What is written and not yet sent, in up to `runs.len` runs, leaving
    /// `sent` where it is.
    pub fn unsent(q: *SendQueue, runs: *[4][]const u8) usize {
        var count: usize = 0;
        var from = q.sent;
        if (from >= q.written) return 0;
        var cur = q.blockAt(from) orelse return 0;
        while (from < q.written and count < runs.len) {
            const off: usize = @intCast(from - cur[1]);
            const k: usize = @intCast(@min(@as(u64, block_data - off), q.written - from));
            runs[count] = cur[0].data[off..][0..k];
            count += 1;
            from += k;
            if (from < q.written) {
                cur = .{ cur[0].next orelse break, cur[1] + block_data };
            }
        }
        return count;
    }

    pub fn advance(q: *SendQueue, n: usize) void {
        q.sent += n;
    }

    /// Hands what is unsent to nghttp3 in up to `veccnt` runs and marks it
    /// sent. Returns the vector count.
    pub fn take(q: *SendQueue, vec: [*c]h.nghttp3_vec, veccnt: usize) usize {
        var count: usize = 0;
        var runs: [4][]const u8 = undefined;
        while (count < veccnt and q.sent < q.written) {
            const k = q.unsent(&runs);
            if (k == 0) break;
            for (runs[0..k]) |run| {
                if (count >= veccnt) break;
                vec[count] = .{ .base = @constCast(run.ptr), .len = run.len };
                count += 1;
                q.sent += run.len;
            }
        }
        return count;
    }

    /// The peer acknowledged `n` more bytes: frees the blocks passed.
    pub fn ack(q: *SendQueue, pool: *BlockPool, budget: *Budget, n: u64) void {
        const m = @min(n, q.written - q.acked);
        q.acked += m;
        // Acknowledged counts as sent: `sent` never falls behind `acked`,
        // whose blocks may be freed below.
        q.sent = @max(q.sent, q.acked);
        if (q.acked == q.written) {
            q.freeAll(pool);
            q.head_base = q.written;
            q.tail_base = q.written;
        } else {
            while (q.head) |b| {
                if (q.acked < q.head_base + block_data) break;
                q.head = b.next;
                q.head_base += block_data;
                if (q.cursor == b) {
                    q.cursor = b.next;
                    q.cursor_base += block_data;
                }
                q.release(pool, b);
            }
        }
        budget.release(m);
    }

    fn freeAll(q: *SendQueue, pool: *BlockPool) void {
        var it = q.head;
        while (it) |b| {
            it = b.next;
            q.release(pool, b);
        }
        q.head = null;
        q.tail = null;
        q.cursor = null;
    }

    /// Returns every block and the whole charge.
    pub fn deinit(q: *SendQueue, pool: *BlockPool, budget: *Budget) void {
        q.freeAll(pool);
        budget.release(@intCast(q.written - q.acked));
        q.acked = q.written;
    }
};

/// The least a stream whose cap follows its path may queue ahead of the
/// peer: the old fixed cap, so a small response, a slow path and a reader
/// that stopped reading cost what they did.
pub const send_floor: usize = 64 * 1024;

/// The cap (`SendQueue.write`'s, on bytes written and not yet acknowledged)
/// of a stream that follows its path: what it has in flight, plus as much
/// again unsent as the congestion window or the stream's flow-control
/// credit allows (the less of the two), at least `send_floor`; at most
/// three quarters of the connection's budget, so the connection's other
/// streams always have room. A fixed cap held a download to that much per
/// round trip (#151); this bounds only the unsent part by the path, as
/// quiche's send capacity and Linux's `tcp_notsent_lowat` do, so a reader
/// whose credit ran out holds `send_floor` once its bytes in flight are
/// acknowledged (research/s15/h3-send-cap.md).
pub fn pathCap(in_flight: u64, cwnd: u64, credit: u64, budget_max: usize) usize {
    const ceiling: u64 = @max(send_floor, budget_max - budget_max / 4);
    const unsent = std.math.clamp(@min(cwnd, credit), send_floor, ceiling);
    return @intCast(@min(in_flight + unsent, ceiling));
}

/// `pathCap` for `queue`, the send queue of stream `stream_id` of
/// connection `q`. Asks ngtcp2 only once `want` more bytes would take the
/// queue past `send_floor`. With the connection's mutex held.
pub fn pathCapOf(q: *c.ngtcp2_conn, stream_id: i64, queue: *const SendQueue, budget_max: usize, want: usize) usize {
    if (queue.buffered() + want <= send_floor) return send_floor;
    var info: ngtcp2.ConnInfo = undefined;
    ngtcp2.connGetConnInfo2(q, &info);
    const credit = c.ngtcp2_conn_get_max_stream_data_left2(q, stream_id);
    return pathCap(queue.sent - queue.acked, info.cwnd, credit, budget_max);
}

/// Received and not yet read; in order (ngtcp2 delivers in order).
pub const RecvQueue = struct {
    head: ?*Block = null,
    tail: ?*Block = null,
    read_off: usize = 0,
    tail_fill: usize = 0,
    len: usize = 0,

    pub fn append(q: *RecvQueue, pool: *BlockPool, bytes: []const u8) error{OutOfMemory}!void {
        var done: usize = 0;
        while (done < bytes.len) {
            if (q.tail == null or q.tail_fill == block_data) {
                const b = try pool.get();
                if (q.tail) |t| t.next = b else {
                    q.head = b;
                    q.read_off = 0;
                }
                q.tail = b;
                q.tail_fill = 0;
            }
            const t = q.tail.?;
            const n = @min(bytes.len - done, block_data - q.tail_fill);
            @memcpy(t.data[q.tail_fill..][0..n], bytes[done..][0..n]);
            q.tail_fill += n;
            q.len += n;
            done += n;
        }
    }

    /// Copies up to `dest.len` bytes out, freeing emptied blocks.
    pub fn take(q: *RecvQueue, pool: *BlockPool, dest: []u8) usize {
        var done: usize = 0;
        while (done < dest.len and q.len > 0) {
            const b = q.head.?;
            const end = if (b == q.tail) q.tail_fill else block_data;
            const n = @min(dest.len - done, end - q.read_off);
            @memcpy(dest[done..][0..n], b.data[q.read_off..][0..n]);
            q.read_off += n;
            q.len -= n;
            done += n;
            if (q.read_off == end and (b != q.tail or q.len == 0)) {
                q.head = b.next;
                q.read_off = 0;
                if (b == q.tail) {
                    q.tail = null;
                    q.tail_fill = 0;
                }
                pool.put(b);
            }
        }
        return done;
    }

    pub fn deinit(q: *RecvQueue, pool: *BlockPool) void {
        var it = q.head;
        while (it) |b| {
            it = b.next;
            pool.put(b);
        }
        q.* = .{};
    }
};

fn testIo() std.Io {
    return undefined;
}

test "send queue spans blocks, frees acked ones and holds none when idle" {
    const gpa = std.testing.allocator;
    var pool = BlockPool.init(gpa, 2);
    defer pool.deinit();
    var budget = Budget.init(testIo(), 1 << 20);
    var q: SendQueue = .{};
    const big = try gpa.alloc(u8, block_data * 3 + 10);
    defer gpa.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i *% 7);
    try std.testing.expectEqual(big.len, try q.write(&pool, &budget, big, 1 << 20, false));
    try std.testing.expectEqual(@as(u32, 4), pool.liveCount());
    try std.testing.expectEqual(big.len, budget.used);
    // unsent over a block boundary: four runs, in order.
    var runs: [4][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), q.unsent(&runs));
    var got: usize = 0;
    for (runs) |r| {
        try std.testing.expectEqualSlices(u8, big[got..][0..r.len], r);
        got += r.len;
    }
    try std.testing.expectEqual(big.len, got);
    // A partial advance, then the runs start where it stopped.
    q.advance(block_data + 5);
    try std.testing.expectEqual(@as(usize, 3), q.unsent(&runs));
    try std.testing.expectEqualSlices(u8, big[block_data + 5 ..][0 .. block_data - 5], runs[0]);
    q.advance(big.len - q.sent);
    try std.testing.expectEqual(@as(usize, 0), q.unsent(&runs));
    // Acking frees the blocks passed.
    q.ack(&pool, &budget, block_data * 2);
    try std.testing.expectEqual(@as(u32, 2), pool.liveCount());
    try std.testing.expectEqual(big.len - block_data * 2, budget.used);
    // More data after a partial free still maps right.
    try std.testing.expectEqual(@as(usize, 20), try q.write(&pool, &budget, big[0..20], 1 << 20, false));
    try std.testing.expectEqual(@as(usize, 1), q.unsent(&runs));
    try std.testing.expectEqualSlices(u8, big[0..20], runs[0]);
    q.ack(&pool, &budget, q.written - q.acked);
    try std.testing.expectEqual(@as(u32, 0), pool.liveCount());
    try std.testing.expectEqual(@as(usize, 0), budget.used);
    try std.testing.expect(q.head == null);
    // And it starts again from the offset it reached.
    try std.testing.expectEqual(@as(usize, 3), try q.write(&pool, &budget, "abc", 1 << 20, false));
    try std.testing.expectEqual(@as(usize, 1), q.unsent(&runs));
    try std.testing.expectEqualStrings("abc", runs[0]);
    q.deinit(&pool, &budget);
    try std.testing.expectEqual(@as(u32, 0), pool.liveCount());
    try std.testing.expectEqual(@as(usize, 0), budget.used);
}

test "send queue: the cap and the budget stop a write, force passes both and still charges" {
    const gpa = std.testing.allocator;
    var pool = BlockPool.init(gpa, 0);
    defer pool.deinit();
    var budget = Budget.init(testIo(), 150);
    var q: SendQueue = .{};
    defer q.deinit(&pool, &budget);
    const data: [400]u8 = @splat(1);
    try std.testing.expectEqual(@as(usize, 100), try q.write(&pool, &budget, &data, 100, false));
    try std.testing.expectEqual(@as(usize, 0), try q.write(&pool, &budget, &data, 100, false));
    // The cap is 300 now, but the budget has 50 left.
    try std.testing.expectEqual(@as(usize, 50), try q.write(&pool, &budget, &data, 300, false));
    try std.testing.expectEqual(@as(usize, 0), try q.write(&pool, &budget, &data, 300, false));
    try std.testing.expectEqual(@as(usize, 400), try q.write(&pool, &budget, &data, 100, true));
    try std.testing.expectEqual(@as(usize, 550), budget.used);
    q.ack(&pool, &budget, 100);
    try std.testing.expectEqual(@as(usize, 450), budget.used);
}

test "h3 send cap: in flight plus unsent up to the congestion window or the stream's credit, between 64 KiB and three quarters of the budget" {
    const KiB: usize = 1024;
    const MiB = 1024 * KiB;
    const budget = 4 * MiB;
    // A cold connection (initial window) or a stream with no credit left:
    // the floor.
    try std.testing.expectEqual(64 * KiB, pathCap(0, 14 * KiB, 1 * MiB, budget));
    try std.testing.expectEqual(64 * KiB, pathCap(0, 2 * MiB, 0, budget));
    // A reader that stopped: what is in flight, plus the floor.
    try std.testing.expectEqual(100 * KiB + 64 * KiB, pathCap(100 * KiB, 2 * MiB, 0, budget));
    // The window grows, and so does the unsent part, up to the credit.
    try std.testing.expectEqual(256 * KiB + 512 * KiB, pathCap(256 * KiB, 512 * KiB, 1 * MiB, budget));
    try std.testing.expectEqual(256 * KiB + 300 * KiB, pathCap(256 * KiB, 512 * KiB, 300 * KiB, budget));
    // The window falls after a loss: the cap with it.
    try std.testing.expectEqual(80 * KiB + 80 * KiB, pathCap(80 * KiB, 80 * KiB, 1 * MiB, budget));
    // Never past three quarters of the budget.
    try std.testing.expectEqual(3 * MiB, pathCap(2 * MiB, 16 * MiB, 16 * MiB, budget));
    try std.testing.expectEqual(3 * MiB, pathCap(0, 64 * MiB, 64 * MiB, budget));
    // A budget below the floor (tests lower it) leaves the floor.
    try std.testing.expectEqual(64 * KiB, pathCap(0, 1 * MiB, 1 * MiB, 32 * KiB));
}

test "send queue take hands nghttp3 the same runs and marks them sent" {
    const gpa = std.testing.allocator;
    var pool = BlockPool.init(gpa, 4);
    defer pool.deinit();
    var budget = Budget.init(testIo(), 1 << 20);
    var q: SendQueue = .{};
    defer q.deinit(&pool, &budget);
    const data: [block_data + 100]u8 = @splat(9);
    _ = try q.write(&pool, &budget, &data, 1 << 20, false);
    var vec: [16]h.nghttp3_vec = undefined;
    try std.testing.expectEqual(@as(usize, 2), q.take(&vec, vec.len));
    try std.testing.expectEqual(@as(usize, block_data), vec[0].len);
    try std.testing.expectEqual(@as(usize, 100), vec[1].len);
    try std.testing.expect(q.allSent());
}

test "recv queue appends and takes across blocks and frees every block when drained" {
    const gpa = std.testing.allocator;
    var pool = BlockPool.init(gpa, 0);
    defer pool.deinit();
    var q: RecvQueue = .{};
    const data = try gpa.alloc(u8, block_data * 2 + 50);
    defer gpa.free(data);
    for (data, 0..) |*b, i| b.* = @truncate(i *% 13);
    try q.append(&pool, data[0..10]);
    try q.append(&pool, data[10..]);
    try std.testing.expectEqual(data.len, q.len);
    try std.testing.expectEqual(@as(u32, 3), pool.liveCount());
    const out = try gpa.alloc(u8, data.len);
    defer gpa.free(out);
    var got: usize = 0;
    while (got < data.len) got += q.take(&pool, out[got..@min(out.len, got + 1000)]);
    try std.testing.expectEqualSlices(u8, data, out);
    try std.testing.expectEqual(@as(u32, 0), pool.liveCount());
    try std.testing.expectEqual(@as(usize, 0), q.take(&pool, out));
    // Usable again after it drained.
    try q.append(&pool, "xyz");
    try std.testing.expectEqual(@as(usize, 3), q.take(&pool, out));
    try std.testing.expectEqual(@as(u32, 0), pool.liveCount());
}

test "block pool keeps up to `keep` blocks and frees the rest" {
    const gpa = std.testing.allocator;
    var pool = BlockPool.init(gpa, 2);
    defer pool.deinit();
    const a = try pool.get();
    const b = try pool.get();
    const c3 = try pool.get();
    pool.put(a);
    pool.put(b);
    pool.put(c3);
    try std.testing.expectEqual(@as(u32, 2), pool.pooled());
    try std.testing.expectEqual(@as(u32, 0), pool.liveCount());
}

test "adaptive block pool keeps the last window's peak, then trims to its floor" {
    const gpa = std.testing.allocator;
    var pool = BlockPool.initAdaptive(gpa, 2);
    defer pool.deinit();
    const t0: u64 = 1000 * BlockPool.window_ns;
    pool.trim(t0);
    var held: [5]*Block = undefined;
    for (&held) |*b| b.* = try pool.get();
    for (held) |b| pool.put(b);
    // All five kept: as many were live at once.
    try std.testing.expectEqual(@as(u32, 5), pool.pooled());
    try std.testing.expectEqual(@as(u32, 0), pool.liveCount());
    // Within the window nothing changes.
    pool.trim(t0 + BlockPool.window_ns / 2);
    try std.testing.expectEqual(@as(u32, 5), pool.pooled());
    try std.testing.expectEqual(t0 + BlockPool.window_ns, pool.trimAt());
    // The next window keeps the last one's peak; the one after, idle,
    // falls back to the floor.
    pool.trim(t0 + BlockPool.window_ns);
    try std.testing.expectEqual(@as(u32, 5), pool.pooled());
    pool.trim(t0 + 2 * BlockPool.window_ns);
    try std.testing.expectEqual(@as(u32, 2), pool.pooled());
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), pool.trimAt());
}

test "send queue with keep_first keeps its first block across idle spells and gives it back once" {
    const gpa = std.testing.allocator;
    var pool = BlockPool.init(gpa, 0);
    defer pool.deinit();
    var budget = Budget.init(testIo(), 1 << 20);
    var q: SendQueue = .{ .keep_first = true };
    _ = try q.write(&pool, &budget, "small", 1 << 20, false);
    const first = q.first.?;
    try std.testing.expectEqual(@as(u32, 1), pool.liveCount());
    q.ack(&pool, &budget, 5);
    try std.testing.expect(q.head == null);
    try std.testing.expectEqual(@as(u32, 1), pool.liveCount());
    // The next response starts in the same block, from the pool's view
    // still the one live block.
    const data: [block_data + 10]u8 = @splat(3);
    _ = try q.write(&pool, &budget, &data, 1 << 20, false);
    try std.testing.expectEqual(first, q.head.?);
    try std.testing.expectEqual(@as(u32, 2), pool.liveCount());
    // Acked past the first block only: it is kept, not pooled, and the
    // next empty start takes it again with its link cleared.
    q.ack(&pool, &budget, block_data);
    try std.testing.expectEqual(@as(u32, 2), pool.liveCount());
    q.deinit(&pool, &budget);
    try std.testing.expectEqual(@as(u32, 1), pool.liveCount());
    _ = try q.write(&pool, &budget, "again", 1 << 20, false);
    try std.testing.expectEqual(first, q.head.?);
    try std.testing.expect(first.next == null);
    q.deinit(&pool, &budget);
    q.releaseFirst(&pool);
    try std.testing.expectEqual(@as(u32, 0), pool.liveCount());
}

test "signal: a notify between epoch and wait makes wait return at once; no sleepers, no futex call" {
    var s: Signal = .{};
    const seen = s.epoch();
    // Nobody sleeps, so notify makes no wake call: testIo() is undefined,
    // and a futex wake through it would crash.
    s.notify(testIo());
    try std.testing.expect(s.epoch() != seen);
    // The epoch moved, so wait returns without sleeping (it would block
    // here forever otherwise: nothing else notifies).
    try s.wait(std.testing.io, seen);
}
