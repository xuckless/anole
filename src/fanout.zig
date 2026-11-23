//! What the two broadcast hubs, `websocket.Rooms` and `sse.Topics`, share:
//! the refcounted message they fan out (`Shared`), the per-receiver queue
//! of references to it (`Queue`), and the HTTP version a receiver came
//! over. The queue-full policy stays in each hub. Imports only std: sse is
//! always built, websocket only with `-Dwebsocket`.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The most queued messages a sender writes before one flush.
pub const send_round = 64;

/// Receivers a broadcast notes on the stack for starting their senders;
/// the 65th one needing a start borrows from the allocator.
pub const stack_snapshot = 64;

/// What a queued message costs on top of its bytes.
pub const item_overhead = 64;

/// `Queue.pop` moves the rest to the front once at least this many are
/// popped and they are at least half the list.
const compact_head = 64;

/// The HTTP version a WebSocket or an SSE stream came over.
pub const HttpVersion = enum { http1, http2, http3 };

/// One allocation holding a `P` header and its bytes right behind it,
/// shared by reference count. `P` has `refs: std.atomic.Value(u32)` and
/// `len: usize` beside its own fields.
pub fn Shared(comptime P: type) type {
    return struct {
        /// `header` with `refs = 1` and `len = data.len`.
        pub fn alloc(gpa: Allocator, header: P, data: []const u8) Allocator.Error!*P {
            std.debug.assert(header.refs.raw == 1 and header.len == data.len);
            const block = try gpa.alignedAlloc(u8, .of(P), @sizeOf(P) + data.len);
            const p: *P = @ptrCast(block.ptr);
            p.* = header;
            @memcpy(block[@sizeOf(P)..], data);
            return p;
        }

        pub fn bytes(p: *const P) []const u8 {
            const base: [*]const u8 = @ptrCast(p);
            return base[@sizeOf(P)..][0..p.len];
        }

        pub fn retain(p: *P) void {
            _ = p.refs.fetchAdd(1, .monotonic);
        }

        pub fn release(p: *P, gpa: Allocator) void {
            if (p.refs.fetchSub(1, .acq_rel) != 1) return;
            const base: [*]align(@alignOf(P)) u8 = @ptrCast(p);
            gpa.free(base[0 .. @sizeOf(P) + p.len]);
        }
    };
}

/// A receiver's messages waiting to be sent, oldest first, and their
/// summed `cost()`. Plain data under the owning hub's mutex. It holds one
/// reference per item: `push` takes the caller's, `pop` hands it back,
/// `drop` releases the rest.
pub fn Queue(comptime P: type) type {
    return struct {
        const Self = @This();

        /// Messages waiting, from `head` on.
        items: std.ArrayList(*P) = .empty,
        head: usize = 0,
        /// Sum of `cost()` of what waits.
        queued_bytes: usize = 0,

        pub inline fn len(q: *const Self) usize {
            return q.items.items.len - q.head;
        }

        /// Whether `p` fits under `max`: a message is always taken when
        /// nothing waits.
        pub inline fn admits(q: *const Self, p: *const P, max: usize) bool {
            return q.queued_bytes == 0 or q.queued_bytes + p.cost() <= max;
        }

        pub inline fn push(q: *Self, gpa: Allocator, p: *P) Allocator.Error!void {
            try q.items.append(gpa, p);
            q.queued_bytes += p.cost();
        }

        pub fn pop(q: *Self) ?*P {
            if (q.head == q.items.items.len) return null;
            const p = q.items.items[q.head];
            q.head += 1;
            q.queued_bytes -= p.cost();
            if (q.head == q.items.items.len) {
                q.items.clearRetainingCapacity();
                q.head = 0;
            } else if (q.head >= compact_head and q.head * 2 >= q.items.items.len) {
                const rest = q.items.items[q.head..];
                std.mem.copyForwards(*P, q.items.items[0..rest.len], rest);
                q.items.items.len = rest.len;
                q.head = 0;
            }
            return p;
        }

        /// Pops up to `send_round` into `out`, oldest first; the count.
        pub fn popRound(q: *Self, out: *[send_round]*P) usize {
            var n: usize = 0;
            while (n < out.len) : (n += 1) out[n] = q.pop() orelse break;
            return n;
        }

        /// Releases everything waiting; the list keeps its capacity.
        pub fn drop(q: *Self, gpa: Allocator) void {
            for (q.items.items[q.head..]) |p| p.release(gpa);
            q.items.clearRetainingCapacity();
            q.head = 0;
            q.queued_bytes = 0;
        }

        pub fn deinit(q: *Self, gpa: Allocator) void {
            q.drop(gpa);
            q.items.deinit(gpa);
        }
    };
}

test "fanout: Queue and the shared payload" {
    const gpa = std.testing.allocator;
    const anole = @import("root.zig");
    comptime std.debug.assert(anole.sse.HttpVersion == HttpVersion);
    if (@hasDecl(anole.websocket, "HttpVersion")) comptime std.debug.assert(anole.websocket.HttpVersion == HttpVersion);
    inline for (.{ false, true }) |with_id| {
        // The ws cost rule, then the sse one.
        const P = struct {
            refs: std.atomic.Value(u32),
            id_len: u8,
            len: usize,
            const shared = Shared(@This());
            const bytes = shared.bytes;
            const retain = shared.retain;
            const release = shared.release;
            fn create(a: Allocator, data: []const u8, id_len: u8) !*@This() {
                return shared.alloc(a, .{ .refs = .init(1), .id_len = id_len, .len = data.len }, data);
            }
            fn cost(x: *const @This()) usize {
                return x.len + (if (with_id) x.id_len else 0) + item_overhead;
            }
        };
        const Q = Queue(P);
        comptime std.debug.assert(@sizeOf(Q) == @sizeOf(std.ArrayList(*P)) + 2 * @sizeOf(usize) and @alignOf(Q) == @alignOf(*P));
        // One allocation per message, empty ones too.
        var fa: std.testing.FailingAllocator = .init(gpa, .{ .fail_index = 1 });
        const one = try P.create(fa.allocator(), "hey", 0);
        defer one.release(fa.allocator());
        try std.testing.expectEqual(1, fa.alloc_index);
        try std.testing.expectEqualStrings("hey", one.bytes());
        const p = try P.create(gpa, "", 0);
        defer p.release(gpa);
        var q: Q = .{};
        defer q.deinit(gpa);
        var round: [send_round]*P = undefined;
        try std.testing.expect(q.pop() == null and q.popRound(&round) == 0 and q.len() == 0 and q.admits(p, 0));
        // Order and cost; admits up to max, not past it.
        const lens = [_]usize{ 0, 1, 7, 100, 3 };
        const filler: [100]u8 = @splat('x');
        var want: usize = 0;
        for (lens, 0..) |n, i| {
            try q.push(gpa, try P.create(gpa, filler[0..n], @intCast(i * 9)));
            want += n + (if (with_id) i * 9 else 0) + item_overhead;
        }
        try std.testing.expectEqual(want, q.queued_bytes);
        try std.testing.expect(q.admits(p, want + p.cost()) and !q.admits(p, want + p.cost() - 1));
        for (lens) |n| {
            const got = q.pop().?;
            defer got.release(gpa);
            try std.testing.expectEqual(n, got.len);
        }
        try std.testing.expectEqual(0, q.queued_bytes);
        // {pushed, popped, head, items}: compacts at 64 of 128, not of 129; drained resets.
        for ([_][4]usize{ .{ 128, 64, 0, 64 }, .{ 129, 64, 64, 129 }, .{ 129, 65, 0, 64 }, .{ 5, 5, 0, 0 } }) |row| {
            for (0..row[0]) |_| {
                p.retain();
                try q.push(gpa, p);
            }
            for (0..row[1]) |_| q.pop().?.release(gpa);
            try std.testing.expectEqual(.{ row[2], row[3] }, .{ q.head, q.items.items.len });
            try std.testing.expect(q.items.capacity >= row[0]);
            q.drop(gpa);
        }
        // popRound caps at send_round; drop releases each reference once.
        var other: Q = .{};
        defer other.deinit(gpa);
        for (0..71) |i| {
            p.retain();
            try (if (i < 70) &q else &other).push(gpa, p);
        }
        for ([_]usize{ 64, 6 }) |n| {
            try std.testing.expectEqual(n, q.popRound(&round));
            for (round[0..n]) |r| r.release(gpa);
        }
        p.retain();
        try q.push(gpa, p);
        q.drop(gpa);
        try std.testing.expect(q.len() == 0 and p.refs.raw == 2 and other.len() == 1);
    }
}
