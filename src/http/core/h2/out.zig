//! The HTTP/2 connection's output queue (research/h2h3-takeover/PLAN.md
//! §3.1, §3.4): what conn.zig has produced and the transport has not yet
//! written, as a FIFO of segments over two kinds of bytes:
//!
//!   * owned: control frames, HEADERS/CONTINUATION blocks and DATA frame
//!     headers, copied into one growing byte buffer;
//!   * borrowed: DATA payloads, slices of the caller's parts, never copied.
//!
//! The writer takes `iovecs` (a writev's worth), writes what it can and
//! calls `advance` with the count. Nothing here frames DATA (conn.zig does,
//! lazily, at `Conn.pending`) or knows about streams beyond the ready queue
//! of stream IDs conn.zig keeps here.
//!
//! **Borrowed bytes** stay referenced until written: a borrower may reuse
//! its parts once `sent_total >= mark()` taken after they were framed, or
//! once `borrowing()` is false (M3's batch arena reset point).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Out = struct {
    gpa: Allocator,
    bytes: std.ArrayList(u8) = .empty,
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

    pub const Seg = union(enum) {
        owned: struct { off: u32, len: u32 },
        borrowed: []const u8,
    };

    pub fn init(gpa: Allocator) Out {
        return .{ .gpa = gpa };
    }

    pub fn deinit(o: *Out) void {
        o.bytes.deinit(o.gpa);
        o.segs.deinit(o.gpa);
        o.ready.deinit(o.gpa);
        // SAFETY: dead after deinit.
        o.* = undefined;
    }

    /// Room for `n` owned bytes at the end of the queue, to be written in
    /// place and then queued with `commit`. Valid until the next call.
    pub fn writable(o: *Out, n: usize) Allocator.Error![]u8 {
        try o.segs.ensureUnusedCapacity(o.gpa, 1);
        try o.bytes.ensureUnusedCapacity(o.gpa, n);
        return o.bytes.unusedCapacitySlice()[0..n];
    }

    /// Queues the first `n` bytes of the last `writable` slice. Merges with
    /// the last segment when it is owned and ends where these begin.
    pub fn commit(o: *Out, n: usize) void {
        if (n == 0) return;
        const off = o.bytes.items.len;
        std.debug.assert(off + n <= o.bytes.capacity);
        o.bytes.items.len += n;
        o.queued_total += n;
        if (o.segs.items.len > o.head) {
            const last = &o.segs.items[o.segs.items.len - 1];
            if (last.* == .owned and last.owned.off + last.owned.len == off) {
                last.owned.len += @intCast(n);
                return;
            }
        }
        o.segs.appendAssumeCapacity(.{ .owned = .{ .off = @intCast(off), .len = @intCast(n) } });
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

    fn slice(o: *const Out, s: Seg) []const u8 {
        return switch (s) {
            .owned => |w| o.bytes.items[w.off..][0..w.len],
            .borrowed => |b| b,
        };
    }

    /// Up to `vecs.len` slices of the unsent bytes, in order. Valid until
    /// the next call that changes the queue.
    pub fn iovecs(o: *const Out, vecs: [][]const u8) []const []const u8 {
        var n: usize = 0;
        for (o.segs.items[o.head..]) |s| {
            if (n == vecs.len) break;
            vecs[n] = o.slice(s)[if (n == 0) o.head_off else 0..];
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
            const len = o.slice(s).len - o.head_off;
            if (left < len) {
                o.head_off += left;
                break;
            }
            left -= len;
            if (s == .borrowed) o.borrowed -= 1;
            o.head += 1;
            o.head_off = 0;
        }
        if (o.head == o.segs.items.len) {
            o.segs.clearRetainingCapacity();
            o.bytes.clearRetainingCapacity();
            o.head = 0;
        } else if (o.head >= 32 and o.head * 2 >= o.segs.items.len) {
            o.compact();
        }
    }

    /// Drops the written segments and the owned bytes before the first
    /// unsent one, so a queue that never empties doesn't grow forever.
    fn compact(o: *Out) void {
        const rest = o.segs.items[o.head..];
        const base: u32 = for (rest) |s| {
            if (s == .owned) break s.owned.off;
        } else @intCast(o.bytes.items.len);
        const kept = o.bytes.items.len - base;
        std.mem.copyForwards(u8, o.bytes.items[0..kept], o.bytes.items[base..]);
        o.bytes.items.len = kept;
        for (rest) |*s| if (s.* == .owned) {
            s.owned.off -= base;
        };
        std.mem.copyForwards(Seg, o.segs.items[0..rest.len], rest);
        o.segs.items.len = rest.len;
        o.head = 0;
    }

    /// Frees the buffers while nothing is queued (PLAN §3.4: the write
    /// buffer is released when idle). The ready queue stays: it is a few
    /// bytes a stream.
    pub fn release(o: *Out) void {
        if (!o.idle()) return;
        o.bytes.clearAndFree(o.gpa);
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
