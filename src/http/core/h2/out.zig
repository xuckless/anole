//! The HTTP/2 connection's output queue (research/h2h3-takeover/PLAN.md
//! §3.1, §3.4): what conn.zig has produced and the transport has not yet
//! written, as a FIFO of segments over two kinds of bytes:
//!
//!   * owned: control frames, HEADERS/CONTINUATION blocks and DATA frame
//!     headers, copied into fixed blocks of `block_len` (one of its own for
//!     a bigger frame) that never move or grow;
//!   * borrowed: DATA payloads, slices of the caller's parts, never copied.
//!
//! The writer takes `iovecs` (a writev's worth), writes what it can and
//! calls `advance` with the count. **The slices stay valid until `advance`
//! passes them, whatever is queued meanwhile**: PLAN §3.3's flush-token
//! holder writes while the reader and the stream tasks keep queueing. A
//! block is freed once its last segment is written (the newest is kept for
//! the next frames until `release`). Nothing here frames DATA (conn.zig
//! does, lazily, at `Conn.pending`) or knows about streams beyond the ready
//! queue of stream IDs conn.zig keeps here.
//!
//! **Borrowed bytes** stay referenced until written: a borrower may reuse
//! its parts once `sent_total >= mark()` taken after they were framed, or
//! once `borrowing()` is false (M3's batch arena reset point).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Out = struct {
    gpa: Allocator,
    /// The owned bytes' blocks, oldest first. Every block but the newest
    /// holds unsent segments, so the oldest holds the first one.
    blocks: std.ArrayList(Block) = .empty,
    segs: std.ArrayList(Seg) = .empty,
    /// The first unsent segment, and how much of it was already written.
    head: usize = 0,
    head_off: usize = 0,
    /// Bytes ever queued and written.
    queued_total: u64 = 0,
    sent_total: u64 = 0,
    /// Unsent borrowed segments.
    borrowed: usize = 0,
    /// IDs of streams with output to frame, oldest first (conn.zig's
    /// round robin). An ID may outlive its stream: the reader skips it.
    ready: std.ArrayList(u31) = .empty,
    ready_head: usize = 0,

    /// The block-cache class PLAN §3.4 takes the write buffer from (its
    /// smallest, 16 KiB).
    pub const block_len = 16 * 1024;

    const Block = struct {
        buf: []u8,
        used: usize = 0,
        /// Unsent owned segments in it.
        segs: usize = 0,
    };

    pub const Seg = union(enum) {
        owned: []const u8,
        borrowed: []const u8,

        fn bytes(s: Seg) []const u8 {
            return switch (s) {
                inline else => |b| b,
            };
        }
    };

    pub fn init(gpa: Allocator) Out {
        return .{ .gpa = gpa };
    }

    pub fn deinit(o: *Out) void {
        for (o.blocks.items) |b| o.gpa.free(b.buf);
        o.blocks.deinit(o.gpa);
        o.segs.deinit(o.gpa);
        o.ready.deinit(o.gpa);
        // SAFETY: dead after deinit.
        o.* = undefined;
    }

    fn tail(o: *Out) ?*Block {
        return if (o.blocks.items.len > 0) &o.blocks.items[o.blocks.items.len - 1] else null;
    }

    /// Room for `n` owned bytes at the end of the queue, to be written in
    /// place and then queued with `commit`. Valid until the next call.
    pub fn writable(o: *Out, n: usize) Allocator.Error![]u8 {
        try o.segs.ensureUnusedCapacity(o.gpa, 1);
        if (o.tail()) |t| {
            // All of it written: it starts over.
            if (t.segs == 0) t.used = 0;
            if (t.buf.len - t.used >= n) return t.buf[t.used..][0..n];
            if (t.segs == 0) {
                o.gpa.free(t.buf);
                o.blocks.items.len -= 1;
            }
        }
        try o.blocks.ensureUnusedCapacity(o.gpa, 1);
        const buf = try o.gpa.alloc(u8, @max(n, block_len));
        o.blocks.appendAssumeCapacity(.{ .buf = buf });
        return buf[0..n];
    }

    /// Queues the first `n` bytes of the last `writable` slice. Merges with
    /// the last segment when it is owned and ends where these begin.
    pub fn commit(o: *Out, n: usize) void {
        if (n == 0) return;
        const t = o.tail().?;
        std.debug.assert(t.used + n <= t.buf.len);
        const b = t.buf[t.used..][0..n];
        t.used += n;
        o.queued_total += n;
        // With unsent segments in the newest block, the last owned segment
        // is one of them.
        if (t.segs > 0) {
            const last = &o.segs.items[o.segs.items.len - 1];
            if (last.* == .owned and last.owned.ptr + last.owned.len == b.ptr) {
                last.owned = last.owned.ptr[0 .. last.owned.len + n];
                return;
            }
        }
        o.segs.appendAssumeCapacity(.{ .owned = b });
        t.segs += 1;
    }

    /// Room for `n` more segments, so that the `borrow` calls they cover
    /// can't fail (a frame is queued whole or not at all).
    pub fn reserve(o: *Out, n: usize) Allocator.Error!void {
        try o.segs.ensureUnusedCapacity(o.gpa, n);
    }

    /// Queues `b` by reference: it must stay valid until written.
    pub fn borrow(o: *Out, b: []const u8) Allocator.Error!void {
        if (b.len == 0) return;
        try o.segs.append(o.gpa, .{ .borrowed = b });
        o.queued_total += b.len;
        o.borrowed += 1;
    }

    /// Segments not yet (fully) written.
    pub fn unsent(o: *const Out) usize {
        return o.segs.items.len - o.head;
    }

    pub fn idle(o: *const Out) bool {
        return o.head == o.segs.items.len;
    }

    /// Some caller's bytes are still referenced.
    pub fn borrowing(o: *const Out) bool {
        return o.borrowed != 0;
    }

    /// `sent_total` reaches this once everything queued so far is written.
    pub fn mark(o: *const Out) u64 {
        return o.queued_total;
    }

    /// Up to `vecs.len` slices of the unsent bytes, in order. Each stays
    /// valid until `advance` passes it.
    pub fn iovecs(o: *const Out, vecs: [][]const u8) []const []const u8 {
        var n: usize = 0;
        for (o.segs.items[o.head..]) |s| {
            if (n == vecs.len) break;
            vecs[n] = s.bytes()[if (n == 0) o.head_off else 0..];
            n += 1;
        }
        return vecs[0..n];
    }

    /// `n` bytes from the front were written.
    pub fn advance(o: *Out, n: usize) void {
        o.sent_total += n;
        var left = n;
        while (left > 0) {
            const s = o.segs.items[o.head];
            const len = s.bytes().len - o.head_off;
            if (left < len) {
                o.head_off += left;
                break;
            }
            left -= len;
            switch (s) {
                .borrowed => o.borrowed -= 1,
                .owned => o.ownedSent(),
            }
            o.head += 1;
            o.head_off = 0;
        }
        if (o.head == o.segs.items.len) {
            o.segs.clearRetainingCapacity();
            o.head = 0;
            // The one block left is kept for the next frames, unless it
            // was sized for one big frame.
            if (o.tail()) |t| if (t.buf.len > block_len) {
                o.gpa.free(t.buf);
                o.blocks.clearRetainingCapacity();
            };
        } else if (o.head >= 32 and o.head * 2 >= o.segs.items.len) {
            // Drops the written segments, so a queue that never empties
            // doesn't grow forever (only the descriptors move).
            const rest = o.segs.items[o.head..];
            std.mem.copyForwards(Seg, o.segs.items[0..rest.len], rest);
            o.segs.items.len = rest.len;
            o.head = 0;
        }
    }

    /// An owned segment was written: it was in the oldest block, which goes
    /// once it holds no more (unless it is the newest).
    fn ownedSent(o: *Out) void {
        const b = &o.blocks.items[0];
        b.segs -= 1;
        if (b.segs == 0 and o.blocks.items.len > 1) {
            o.gpa.free(b.buf);
            _ = o.blocks.orderedRemove(0);
        }
    }

    /// Frees the buffers while nothing is queued (PLAN §3.4: the write
    /// buffer is released when idle). The ready queue stays: it is a few
    /// bytes a stream.
    pub fn release(o: *Out) void {
        if (!o.idle()) return;
        for (o.blocks.items) |b| o.gpa.free(b.buf);
        o.blocks.clearAndFree(o.gpa);
        o.segs.clearAndFree(o.gpa);
        o.head = 0;
        o.head_off = 0;
    }

    pub fn pushReady(o: *Out, id: u31) Allocator.Error!void {
        if (o.ready_head > 0 and o.ready_head * 2 >= o.ready.items.len and o.ready.items.len == o.ready.capacity) {
            const rest = o.ready.items[o.ready_head..];
            std.mem.copyForwards(u31, o.ready.items[0..rest.len], rest);
            o.ready.items.len = rest.len;
            o.ready_head = 0;
        }
        try o.ready.append(o.gpa, id);
    }

    pub fn peekReady(o: *const Out) ?u31 {
        return if (o.ready_head < o.ready.items.len) o.ready.items[o.ready_head] else null;
    }

    pub fn popReady(o: *Out) void {
        o.ready_head += 1;
        if (o.ready_head == o.ready.items.len) {
            o.ready.clearRetainingCapacity();
            o.ready_head = 0;
        }
    }
};
