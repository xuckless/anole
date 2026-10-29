// Adapted from vkiryakov/zefir src/nats/engine/Outbound.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! The outbound queue: frames waiting for the writer, in order. A frame is
//! copied once, into a chunk; the writer sends whole chunks in batches.
//!
//! `limits.outbound_bytes` is a soft limit: a frame waits for room while
//! the queue holds that much or more, and is then taken whole, so a frame
//! of any size gets in once the queue drains below the limit. Frames that
//! wait for room wait in line, first come first: room wakes only the first,
//! and once its frame is in it wakes the next if room is left; a put that
//! gives up (canceled, or at its deadline) passes its turn on. PINGs skip
//! the limit but keep their place in the stream, and `putNow` frames skip
//! the wait but count. PONGs owed to the server go out before the next
//! batch, outside the queue.
//!
//! The queue outlives connections. While there is none, it is `buffering`:
//! nothing is sent, SUB and UNSUB are not queued (the subscriptions are
//! restored from the registry), and publishes and requests wait in the
//! reconnect buffer, up to `reconnect.buffer_bytes` and never longer than
//! that: a frame that does not fit fails at once with BufferFull, and with
//! no buffer at all with Disconnected. When a connection ends, `halt` stops
//! its writer and wakes every waiter, and once the writer is gone `settle`
//! sorts out what the connection left: PUB and HPUB written after the PING
//! the last PONG answered may or may not have reached the server, and are
//! counted as uncertain; publishes never written move to the buffer while
//! it has room, ahead of those made after the loss, and the rest are
//! dropped and counted; requests, SUB, UNSUB and PING go. Nothing is ever
//! sent twice. A new connection begins with `restore`, which drops what
//! the new server would refuse and puts the frames that bring the server
//! up to date before everything that waits. Frames are moved only inside
//! the chunks they are in, so none is ever lost for lack of memory.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Writer = Io.Writer;
const encoder = @import("../protocol/encoder.zig");
const time = @import("time.zig");
const Broadcast = @import("Broadcast.zig");
const Outbound = @This();

/// A put waiting for room, in line.
const RoomWaiter = struct {
    node: std.DoublyLinkedList.Node = .{},
    /// Set when it is this put's turn, the queue closed or its connection
    /// ended.
    turn: Io.Event = .unset,
};

pub const Kind = enum {
    /// PUB or HPUB of a publish or a reply.
    publish,
    /// PUB or HPUB of a request; it is dropped when the connection is lost.
    request,
    /// SUB and UNSUB; the subscriptions restore them after a reconnect.
    service,
    /// PING; it skips the limit.
    ping,
};

/// A frame in the queue.
pub const Frame = struct {
    kind: Kind,
    len: usize,
    /// Bytes of it the socket already took: only the first frame in the
    /// queue can have some.
    written: usize = 0,
    /// The request a `.request` frame carries; 0 for others.
    request: u64 = 0,
    /// Its request ended while the frame waited for a connection: it is
    /// never sent.
    dead: bool = false,
    /// A PING the heartbeat asked for: once written, it is outstanding
    /// until a PONG comes.
    heartbeat: bool = false,
    /// A publish the ended connection never began: it holds its room in
    /// the reconnect buffer until `settle`.
    reserved: bool = false,
};

/// The request a request frame carries. The frame goes in only when
/// `admit(context, io, id, generation)` agrees, under the queue's mutex:
/// the request learns which connection its frame goes out on, and one
/// that has failed already queues nothing.
pub const Ticket = struct {
    id: u64,
    context: *anyopaque,
    admit: *const fn (context: *anyopaque, io: Io, id: u64, generation: u64) bool,
};

pub const PingKind = enum { flush, heartbeat };

/// A PING written to the socket, and how many PUB and HPUB had been written
/// on its connection by then: once its PONG comes, those reached the
/// server.
const PingMark = struct { number: u64 = 0, data_frames: u64 = 0 };

/// Written PINGs remembered for their PONGs; a PONG for a PING forgotten
/// confirms nothing, which only makes the uncertain count larger.
const ping_marks = 64;

/// A PING to wait for: PONG number `number` of connection `generation`
/// answers it.
pub const Ping = struct {
    number: u64,
    generation: u64 = 0,
};

/// What `take` lends the writer.
pub const Batch = struct {
    slices: []const []const u8,
    /// The bytes of all slices.
    len: usize,
};

pub const Mode = enum {
    /// A connection is up and its writer sends the frames.
    live,
    /// No connection: frames wait for the next one.
    buffering,
    /// The client closed.
    closed,
};

pub const PutError = error{ Closed, Disconnected, BufferFull, Canceled, OutOfMemory, ProtocolError, ConnectionDraining };
pub const WaitError = error{ Closed, Disconnected, Timeout, Canceled };

/// The size of a chunk; a larger frame gets a chunk of its own size.
pub const chunk_size = 64 * 1024;

const Chunk = struct {
    bytes: []u8,
    /// Bytes the socket took.
    head: usize = 0,
    /// Bytes filled.
    tail: usize = 0,
};

/// What a frame's record costs on top of its bytes.
const record_cost = @sizeOf(Frame);
/// The most PONGs sent in one batch.
const max_pongs_per_batch = 16;
const pong_run: [max_pongs_per_batch * encoder.pong.len]u8 = run: {
    var bytes: [max_pongs_per_batch * encoder.pong.len]u8 = undefined;
    for (0..max_pongs_per_batch) |i| @memcpy(bytes[i * encoder.pong.len ..][0..encoder.pong.len], encoder.pong);
    break :run bytes;
};

gpa: Allocator,
/// Frames other than PINGs wait while `queued` is at least this.
limit: usize,
mutex: Io.Mutex = .init,
mode: Mode = .live,
/// Counts the connections that ended: a PING of an older one is never
/// answered.
generation: u64 = 0,
/// The puts waiting for room, first come first; any number of them.
room_line: std.DoublyLinkedList = .{},
/// How many wait in `room_line`.
room_waiters: u32 = 0,
/// Tests only: how far waiting puts see the awake clock ahead of the real
/// one when they check their deadlines (`testAdvanceClock`), so a test
/// expires a deadline on command instead of sleeping until it.
test_clock_ahead: if (builtin.is_test) i96 else void = if (builtin.is_test) 0 else {},
/// Signaled when there is something to write.
ready: Io.Condition = .init,
/// Woken when a PONG arrives.
answered: Broadcast = .{},
/// The bytes of the frames, oldest first.
chunks: std.Deque(*Chunk) = .empty,
/// An empty chunk kept for the next frames.
spare: ?*Chunk = null,
/// The frames in `chunks`, oldest first.
frames: std.Deque(Frame) = .empty,
/// What the frames other than PINGs cost: their bytes and their records.
queued: usize = 0,
/// Times a put waiting for room woke up; tests check that a wake lets one
/// frame in.
room_wakeups: u64 = 0,
/// PONGs owed to the server.
pongs_owed: u32 = 0,
/// PONGs in the batch the writer has.
pongs_in_flight: u32 = 0,
/// PINGs queued and PONGs received on this connection: PONG number n
/// answers PING number n.
pings_queued: u64 = 0,
pongs_received: u64 = 0,
/// The PONGs the last connection that ended received: a PING of it they
/// answered stays answered for the task that looks only later.
ended_pongs: u64 = 0,
/// Heartbeat PINGs written since the last PONG: a PING still waiting
/// behind other frames cannot have been answered yet, and does not count.
pings_out: u32 = 0,
/// What the frames may cost while there is no connection.
buffer_limit: usize = 0,
/// What the frames that wait for the next connection cost.
buffered: usize = 0,
/// Room the publishes the ended connection never began hold in the
/// buffer until `settle`, ahead of the publishes made since.
reserved: usize = 0,
/// What dead frames still hold until they are dropped.
dead_bytes: usize = 0,
/// Frames at the front that the ended connection left, until `settle`.
stale_frames: usize = 0,
/// PUB and HPUB written whole on this connection, and how many of them the
/// server confirmed with the PONG of a later PING.
data_written: u64 = 0,
data_confirmed: u64 = 0,
/// PINGs written whole on this connection, and the last of them.
pings_written: u64 = 0,
marks: [ping_marks]PingMark = @splat(.{}),
/// PUB and HPUB of ended connections that may or may not have reached the
/// server.
uncertain_frames: u64 = 0,
/// The client's drain sent its last PING: publishes and requests are
/// refused from then on (`stopPublishes`).
publishes_stopped: bool = false,
/// Publishes that never reached the socket and were dropped: no room in
/// the reconnect buffer, or the client closed.
dropped_publishes: u64 = 0,

/// A queue for a connection that is up, as tests use it.
pub fn init(gpa: Allocator, limit: usize) Outbound {
    return .{ .gpa = gpa, .limit = limit };
}

/// A queue that waits for the first connection; without one, frames cost
/// at most `buffer_limit`.
pub fn initBuffering(gpa: Allocator, limit: usize, buffer_limit: usize) Outbound {
    return .{ .gpa = gpa, .limit = limit, .mode = .buffering, .buffer_limit = buffer_limit };
}

/// Frees whatever is queued. The writer must have stopped.
pub fn deinit(q: *Outbound) void {
    q.freeFrames();
    q.chunks.deinit(q.gpa);
    if (q.spare) |chunk| q.destroyChunk(chunk);
    q.frames.deinit(q.gpa);
    q.* = undefined;
}

/// Queues one frame of exactly `len` bytes, written by
/// `encode(writer, args...)`. Unless it is a PING, it waits while the queue
/// is full; the wait can be canceled. Without a connection it never waits:
/// SUB and UNSUB are not queued, a publish or a request goes into the
/// reconnect buffer or fails with BufferFull (Disconnected without a
/// buffer), and a PING fails with Disconnected.
pub fn put(q: *Outbound, io: Io, kind: Kind, len: usize, encode: anytype, args: anytype) PutError!void {
    return q.putUntil(io, null, kind, len, encode, args) catch |err| switch (err) {
        error.Timeout => unreachable, // no deadline, no timeout
        else => |e| e,
    };
}

pub const PutUntilError = PutError || error{Timeout};

/// Like `putUntil`, but the frame goes in only when `ticket` agrees, under
/// the queue's mutex, as for a SUB that its subscription's drain must not
/// follow.
pub fn putTicket(q: *Outbound, io: Io, deadline: ?Io.Clock.Timestamp, kind: Kind, ticket: Ticket, len: usize, encode: anytype, args: anytype) PutUntilError!void {
    return q.putTicketed(io, deadline, kind, ticket, len, encode, args);
}

/// Like `put`, but the wait for room ends at `deadline` with Timeout, and
/// the frame is not queued, nor when `deadline` has passed already; null
/// waits as long as it takes.
pub fn putUntil(q: *Outbound, io: Io, deadline: ?Io.Clock.Timestamp, kind: Kind, len: usize, encode: anytype, args: anytype) PutUntilError!void {
    return q.putTicketed(io, deadline, kind, null, len, encode, args);
}

/// Queues the PUB or HPUB of a request, the way `putUntil` does, tagged
/// with the request so that both share a fate: the frame goes in only when
/// `ticket` agrees, and when the connection ended while it waited for
/// room, it does not go in at all (Disconnected): the request ends with
/// that connection, and nothing of it is sent later.
pub fn putRequest(q: *Outbound, io: Io, deadline: ?Io.Clock.Timestamp, ticket: Ticket, len: usize, encode: anytype, args: anytype) PutUntilError!void {
    return q.putTicketed(io, deadline, .request, ticket, len, encode, args);
}

fn putTicketed(q: *Outbound, io: Io, deadline: ?Io.Clock.Timestamp, kind: Kind, ticket: ?Ticket, len: usize, encode: anytype, args: anytype) PutUntilError!void {
    try q.mutex.lock(io);
    defer q.mutex.unlock(io);
    if (kind == .ping) return q.admit(io, kind, null, len, encode, args);
    if (q.stopped(kind)) return error.ConnectionDraining;
    // A request that ran out of time while it got here sends nothing.
    if (deadline) |d| if (time.expired(io, d)) return error.Timeout;
    const generation = q.generation;
    try q.awaitRoom(io, deadline);
    // In or not, the next put in line may go if room is left.
    defer q.passRoom(io);
    if (kind == .request and q.generation != generation and q.mode != .closed) return error.Disconnected;
    // Publishes stopped while it waited: the drain's last PING went first.
    if (q.stopped(kind)) return error.ConnectionDraining;
    return q.admit(io, kind, ticket, len, encode, args);
}

pub const TryPutError = PutError || error{
    /// The queue is at its limit: nothing was queued, nothing waited.
    Full,
};

/// Queues a frame only if there is room now; it never waits. `.busy` says
/// the queue is past half its limit (the caller should slow down). A
/// reconnect buffer that is full is BufferFull, as for `put`.
pub const Room = enum { ok, busy };

pub fn tryPut(q: *Outbound, io: Io, kind: Kind, len: usize, encode: anytype, args: anytype) TryPutError!Room {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    if (q.stopped(kind)) return error.ConnectionDraining;
    if (q.mode == .live and (q.queued >= q.limit or q.room_line.first != null)) return error.Full;
    try q.admit(io, kind, null, len, encode, args);
    return if (q.mode == .live and q.queued > q.limit / 2) .busy else .ok;
}

/// Whether a publish now would be taken and not be `.busy`: a live queue
/// at most half full (as `tryPut` judges it, so a limit of 1 has room when
/// empty), or room in the reconnect buffer.
pub fn hasRoom(q: *Outbound, io: Io) bool {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    return switch (q.mode) {
        .closed => false,
        .live => q.queued <= q.limit / 2 and q.room_line.first == null,
        .buffering => q.buffer_limit -| q.buffered -| q.reserved > record_cost,
    };
}

pub const PutNowError = error{ Closed, Disconnected, BufferFull, OutOfMemory, ProtocolError };

/// Like `put`, but the frame goes in at once, full queue or not; it still
/// counts against the limit. For frames that cannot wait and stay few,
/// such as the one UNSUB a subscription sends when it ends.
pub fn putNow(q: *Outbound, io: Io, kind: Kind, len: usize, encode: anytype, args: anytype) PutNowError!void {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    return q.admit(io, kind, null, len, encode, args);
}

/// Takes a frame as the mode says.
fn admit(q: *Outbound, io: Io, kind: Kind, ticket: ?Ticket, len: usize, encode: anytype, args: anytype) PutNowError!void {
    switch (q.mode) {
        .closed => return error.Closed,
        .live => {
            try q.agree(io, ticket);
            return q.append(io, kind, ticket, len, encode, args);
        },
        .buffering => switch (kind) {
            // The registry restores the subscriptions on the next
            // connection.
            .service => return,
            .ping => return error.Disconnected,
            .publish, .request => {
                if (q.buffer_limit == 0) return error.Disconnected;
                const cost = len +| record_cost;
                if (cost > q.buffer_limit -| q.buffered -| q.reserved) return error.BufferFull;
                try q.agree(io, ticket);
                try q.append(io, kind, ticket, len, encode, args);
                q.buffered += cost;
            },
        },
    }
}

/// The request of `ticket` takes its frame for the current connection, or
/// the next; Disconnected when it has failed already.
fn agree(q: *Outbound, io: Io, ticket: ?Ticket) error{Disconnected}!void {
    const t = ticket orelse return;
    if (!t.admit(t.context, io, t.id, q.generation)) return error.Disconnected;
}

fn append(q: *Outbound, io: Io, kind: Kind, ticket: ?Ticket, len: usize, encode: anytype, args: anytype) PutNowError!void {
    const chunk = try q.reserve(len);
    var w: Writer = .fixed(chunk.bytes[chunk.tail..][0..len]);
    // `len` comes from the encoder's *Len twin; a frame of another length
    // would break the stream, so it is refused.
    @call(.auto, encode, .{&w} ++ args) catch return error.ProtocolError;
    if (w.end != len) return error.ProtocolError;
    q.commit(chunk, .{ .kind = kind, .len = len, .request = if (ticket) |t| t.id else 0 });
    q.ready.signal(io);
}

/// Waits until there is room and no put ahead of this one in line, or
/// until `deadline`. Only a live queue makes puts wait.
fn awaitRoom(q: *Outbound, io: Io, deadline: ?Io.Clock.Timestamp) error{ Canceled, Timeout }!void {
    if (q.mode != .live or (q.queued < q.limit and q.room_line.first == null)) return;
    var waiter: RoomWaiter = .{};
    // A put that leaves the line early may have been woken for its turn:
    // the next one gets it, once this one is out of the line.
    errdefer q.passRoom(io);
    q.room_line.append(&waiter.node);
    q.room_waiters += 1;
    defer {
        q.room_line.remove(&waiter.node);
        q.room_waiters -= 1;
    }
    while (q.mode == .live and !(q.queued < q.limit and q.room_line.first == &waiter.node)) {
        if (deadline) |d| if (q.putExpired(io, d)) return error.Timeout;
        // Only this put waits on its event, and others set it under the
        // mutex: resetting it here loses no wake.
        waiter.turn.reset();
        q.mutex.unlock(io);
        const woken = waiter.turn.waitTimeout(io, time.until(deadline));
        q.mutex.lockUncancelable(io);
        woken catch |err| switch (err) {
            // The deadline, or a spurious wakeup: the loop looks again.
            error.Timeout => continue,
            error.Canceled => return error.Canceled,
        };
        q.room_wakeups += 1;
    }
}

/// A waiting put's deadline has passed (on the clock tests may move ahead).
fn putExpired(q: *const Outbound, io: Io, at: Io.Clock.Timestamp) bool {
    if (comptime builtin.is_test) return Io.Clock.awake.now(io).nanoseconds + q.test_clock_ahead >= at.raw.nanoseconds;
    return time.expired(io, at);
}

/// Tests only: moves the clock waiting puts check their deadlines on ahead
/// by `by` and wakes them all to look again.
fn testAdvanceClock(q: *Outbound, io: Io, by: Io.Duration) void {
    comptime std.debug.assert(builtin.is_test);
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    q.test_clock_ahead += by.nanoseconds;
    var node = q.room_line.first;
    while (node) |n| : (node = n.next) {
        const waiter: *RoomWaiter = @fieldParentPtr("node", n);
        waiter.turn.set(io);
    }
}

/// Wakes the first put in line when there is room for it.
fn passRoom(q: *Outbound, io: Io) void {
    if (q.mode != .live or q.queued >= q.limit) return;
    const first = q.room_line.first orelse return;
    const waiter: *RoomWaiter = @fieldParentPtr("node", first);
    waiter.turn.set(io);
}

/// A publish or request frame that the drain's last PING refuses.
fn stopped(q: *const Outbound, kind: Kind) bool {
    return q.publishes_stopped and q.mode != .closed and (kind == .publish or kind == .request);
}

/// The last PING of the client's drain: from it on, publishes and requests
/// fail with ConnectionDraining, also those waiting for room, so its PONG
/// confirms every frame published before. One step under the mutex.
pub fn stopPublishes(q: *Outbound, io: Io) error{ Closed, Disconnected, OutOfMemory }!Ping {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    const ping = try q.queuePing(io, .flush);
    q.publishes_stopped = true;
    return ping;
}

/// Queues a PING and returns it; PONG number n answers PING number n. When
/// the last frame queued is a PING the writer has not begun, that one is
/// returned instead: it marks the same point in the stream. So PINGs skip
/// the limit, yet there is at most one more than other frames.
pub fn putPing(q: *Outbound, io: Io, kind: PingKind) error{ Closed, Disconnected, OutOfMemory }!Ping {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    return q.queuePing(io, kind);
}

fn queuePing(q: *Outbound, io: Io, kind: PingKind) error{ Closed, Disconnected, OutOfMemory }!Ping {
    switch (q.mode) {
        .closed => return error.Closed,
        .buffering => return error.Disconnected,
        .live => {},
    }
    const heartbeat = kind == .heartbeat;
    const last = q.frames.backPtr();
    if (last != null and last.?.kind == .ping and last.?.written == 0) {
        if (heartbeat) last.?.heartbeat = true;
    } else {
        const chunk = try q.reserve(encoder.ping.len);
        @memcpy(chunk.bytes[chunk.tail..][0..encoder.ping.len], encoder.ping);
        q.commit(chunk, .{ .kind = .ping, .len = encoder.ping.len, .heartbeat = heartbeat });
        q.pings_queued += 1;
        q.ready.signal(io);
    }
    return .{ .number = q.pings_queued, .generation = q.generation };
}

/// A PONG came: it answers the oldest PING still unanswered.
pub fn pongReceived(q: *Outbound, io: Io) void {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    q.pongs_received += 1;
    // Read after its connection ended, before the reader stopped.
    if (q.mode != .live) q.ended_pongs = q.pongs_received;
    q.pings_out = 0;
    // PONG n answers the n-th PING written: what was written before it
    // reached the server.
    const mark = q.marks[q.pongs_received % ping_marks];
    if (mark.number == q.pongs_received) q.data_confirmed = mark.data_frames;
    q.answered.wake(io);
}

/// Waits until `ping` is answered, `deadline` passes, its connection ends
/// (Disconnected) or the queue closes. A PONG that came before its
/// connection ended answers it, however late the waiter looks.
pub fn waitPong(q: *Outbound, io: Io, ping: Ping, deadline: ?Io.Clock.Timestamp) WaitError!void {
    try q.mutex.lock(io);
    defer q.mutex.unlock(io);
    while (true) {
        if (q.generation == ping.generation) {
            if (q.pongs_received >= ping.number) return;
        } else if (q.generation == ping.generation + 1 and q.ended_pongs >= ping.number) {
            // Answered before its connection ended.
            return;
        }
        if (q.mode == .closed) return error.Closed;
        if (q.generation != ping.generation) return error.Disconnected;
        if (deadline) |d| if (time.expired(io, d)) return error.Timeout;
        try q.answered.wait(io, &q.mutex, deadline);
    }
}

/// Heartbeat PINGs written since the last PONG.
pub fn pingsOut(q: *Outbound, io: Io) u32 {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    return q.pings_out;
}

/// What the heartbeat looks at.
pub const Health = struct {
    /// Heartbeat PINGs written since the last PONG.
    pings_out: u32,
    /// Frames or PONGs wait for the writer, or are being written.
    waiting: bool,
};

pub fn health(q: *Outbound, io: Io) Health {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    return .{ .pings_out = q.pings_out, .waiting = q.frames.len > 0 or q.pongs_owed > 0 };
}

/// The server sent PING: a PONG goes out before the next batch.
pub fn queuePong(q: *Outbound, io: Io) void {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    if (q.mode != .live) return;
    q.pongs_owed +|= 1;
    q.ready.signal(io);
}

/// For the writer: waits for something to write and lends it out, PONGs
/// first, then whole frames, at most `slices.len` slices. Null once the
/// connection ended or the queue closed: what is left is not sent by this
/// writer. Call `written` before the next `take`.
pub fn take(q: *Outbound, io: Io, slices: [][]const u8) Io.Cancelable!?Batch {
    try q.mutex.lock(io);
    defer q.mutex.unlock(io);
    while (q.mode == .live and q.pongs_owed == 0 and q.frames.len == 0) try q.ready.wait(io, &q.mutex);
    if (q.mode != .live) return null;
    var count: usize = 0;
    var len: usize = 0;
    q.pongs_in_flight = if (slices.len > 0) @min(q.pongs_owed, max_pongs_per_batch) else 0;
    if (q.pongs_in_flight > 0) {
        slices[0] = pong_run[0 .. q.pongs_in_flight * encoder.pong.len];
        len = slices[0].len;
        count = 1;
    }
    var chunks = q.chunks.iterator();
    while (count < slices.len) {
        const chunk = chunks.next() orelse break;
        if (chunk.head == chunk.tail) continue;
        slices[count] = chunk.bytes[chunk.head..chunk.tail];
        len += slices[count].len;
        count += 1;
    }
    return .{ .slices = slices[0..count], .len = len };
}

/// For the writer: the socket took the first `n` bytes of the last batch.
pub fn written(q: *Outbound, io: Io, n: usize) void {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    const pong_bytes = q.pongs_in_flight * encoder.pong.len;
    q.pongs_owed -= @intCast(@min(n, pong_bytes) / encoder.pong.len);
    q.pongs_in_flight = 0;
    q.advance(n -| pong_bytes);
    q.passRoom(io);
}

/// Copies the queued frames, oldest first, into `out` as far as it holds
/// them.
pub fn unsent(q: *Outbound, io: Io, out: []Frame) []Frame {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    var frames = q.frames.iterator();
    var count: usize = 0;
    while (count < out.len) : (count += 1) out[count] = frames.next() orelse break;
    return out[0..count];
}

/// The connection ended and another is to come: from now on frames wait
/// for it (see `put`), the writer stops, puts waiting for room look again,
/// and PING waiters learn that the connection is gone. Once the writer has
/// stopped, `settle` deals with what the connection left. A closed queue
/// stays closed.
pub fn halt(q: *Outbound, io: Io) u64 {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    if (q.mode == .live) {
        q.ended_pongs = q.pongs_received;
        q.mode = .buffering;
        q.generation += 1;
        q.stale_frames = q.frames.len;
        q.buffered = 0;
        q.dead_bytes = 0;
        q.reserveUnsent();
        q.wakeAll(io);
    }
    return q.generation;
}

/// The publishes the ended connection never began take their room in the
/// buffer first, in order while it has room, as `settle` keeps them:
/// publishes made after the loss find what is left, or BufferFull.
fn reserveUnsent(q: *Outbound) void {
    q.reserved = 0;
    for (0..q.frames.len) |index| {
        const frame = q.frames.atPtr(index);
        if (frame.kind != .publish or frame.written > 0) continue;
        const cost = frame.len + record_cost;
        if (cost > q.buffer_limit - q.reserved) break;
        frame.reserved = true;
        q.reserved += cost;
    }
}

/// A request ended: while there is no connection, its frame waiting for
/// the next one is dropped, so a request that ended is never sent and its
/// room goes to others. The frames are compacted in place once the dead
/// ones hold as much as the living, so memory stays within twice the
/// buffer and a compaction allocates nothing.
pub fn forgetRequest(q: *Outbound, io: Io, id: u64) void {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    if (q.mode != .buffering or id == 0) return;
    // Frames the ended connection left are `settle`'s.
    var index = q.stale_frames;
    while (index < q.frames.len) : (index += 1) {
        const frame = q.frames.atPtr(index);
        if (frame.request != id or frame.dead) continue;
        q.markDead(frame);
        break;
    }
    q.compactDead();
}

/// While there is no connection, the request frames waiting for it whose
/// request no longer waits (`waiting(context, id)` false, as a stream of
/// requestMany past its deadline that nobody reads) give their room back,
/// as a request that ends does; true when some did. A publish that finds
/// the buffer full asks it before it gives up.
pub fn pruneRequests(q: *Outbound, io: Io, context: anytype, comptime waiting: fn (@TypeOf(context), u64) bool) bool {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    if (q.mode != .buffering) return false;
    var pruned = false;
    var index = q.stale_frames;
    while (index < q.frames.len) : (index += 1) {
        const frame = q.frames.atPtr(index);
        if (frame.kind != .request or frame.dead or waiting(context, frame.request)) continue;
        q.markDead(frame);
        pruned = true;
    }
    q.compactDead();
    return pruned;
}

/// A frame waiting for the next connection that is never to be sent: its
/// room goes back at once, its bytes when the queue is compacted.
fn markDead(q: *Outbound, frame: *Frame) void {
    frame.dead = true;
    const cost = frame.len + record_cost;
    q.buffered -|= cost;
    q.queued -|= cost;
    q.dead_bytes += cost;
}

/// Compacts once the dead frames hold as much as the living; with a
/// writer still on the stale frames, nothing moves yet.
fn compactDead(q: *Outbound) void {
    if (q.stale_frames == 0 and q.dead_bytes > 0 and q.dead_bytes >= q.buffered) q.compact(&KeepLiving{});
}

/// What `settle` and `discard` found.
pub const Settled = struct {
    /// PUB and HPUB written after the PING the last PONG answered.
    uncertain: u64 = 0,
    /// Publishes never written that were dropped.
    dropped: u64 = 0,
};

/// After `halt`, once the writer has stopped: sorts out the frames the
/// ended connection left. PUB and HPUB written after the last confirmed
/// PING count as uncertain; publishes never written stay for the next
/// connection while the buffer has room, after what waits there already,
/// and the rest are dropped; requests, SUB, UNSUB and PING go, and so does
/// a frame written in part. The count of PINGs and PONGs starts over.
pub fn settle(q: *Outbound, io: Io) Settled {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    var settled: Settled = .{ .uncertain = q.data_written - q.data_confirmed };
    if (q.mode != .closed) {
        q.keepBuffered(&settled);
    } else {
        settled.dropped = q.unsentPublishes();
        q.freeFrames();
    }
    q.uncertain_frames += settled.uncertain;
    q.dropped_publishes += settled.dropped;
    q.startOver();
    return settled;
}

/// The client closed and the writer has stopped: what was never written is
/// dropped, publishes counted, and what was written after the last
/// confirmed PING counts as uncertain. Again, it finds nothing.
pub fn discard(q: *Outbound, io: Io) Settled {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    const settled: Settled = .{ .uncertain = q.data_written - q.data_confirmed, .dropped = q.unsentPublishes() };
    q.freeFrames();
    q.uncertain_frames += settled.uncertain;
    q.dropped_publishes += settled.dropped;
    q.startOver();
    return settled;
}

/// Publishes in the queue: none reached the server whole, the one written
/// in part included.
fn unsentPublishes(q: *const Outbound) u64 {
    var count: u64 = 0;
    var frames = q.frames.iterator();
    while (frames.next()) |frame| {
        if (frame.kind == .publish) count += 1;
    }
    return count;
}

fn startOver(q: *Outbound) void {
    q.stale_frames = 0;
    q.pongs_owed = 0;
    q.pongs_in_flight = 0;
    q.pings_queued = 0;
    q.pongs_received = 0;
    q.pings_out = 0;
    q.data_written = 0;
    q.data_confirmed = 0;
    q.pings_written = 0;
    q.marks = @splat(.{});
}

/// Keeps the publishes the ended connection never wrote, in order, while
/// the buffer has room after the frames that came since; drops the other
/// frames it left, and the dead ones.
fn keepBuffered(q: *Outbound, settled: *Settled) void {
    var keeper: KeepBuffered = .{ .stale = q.stale_frames, .room = q.buffer_limit -| q.buffered, .settled = settled };
    q.compact(&keeper);
}

/// For `compact` in `settle`: the stale frames are those of the ended
/// connection.
const KeepBuffered = struct {
    stale: usize,
    room: usize,
    full: bool = false,
    settled: *Settled,

    fn keep(k: *KeepBuffered, index: usize, frame: Frame, _: []const u8) bool {
        if (frame.dead) return false;
        if (index >= k.stale) return true;
        if (frame.kind != .publish) return false;
        // Written in part: it never reached the server whole, and is not
        // sent again.
        const cost = frame.len + record_cost;
        if (frame.written > 0 or k.full or cost > k.room) {
            k.full = k.full or frame.written == 0;
            k.settled.dropped += 1;
            return false;
        }
        k.room -= cost;
        return true;
    }
};

/// For `compact`: every frame but the dead.
const KeepLiving = struct {
    fn keep(_: *const KeepLiving, _: usize, frame: Frame, _: []const u8) bool {
        return !frame.dead;
    }
};

/// What a new server takes: `restore` drops the frames waiting for it that
/// it would refuse, and close the connection for.
pub const ServerLimits = struct {
    /// Headers and payload together; 0 when the server did not say.
    max_payload: u64 = 0,
    /// HPUB.
    headers: bool = true,
};

/// For `compact` in `restore`: the living frames, requests only while
/// their request still waits, and publishes and requests only when the new
/// server takes them; a request it would not take is refused.
fn KeepWaiting(
    comptime Context: type,
    comptime waiting: fn (Context, u64) bool,
    comptime refused: fn (Context, u64) void,
) type {
    return struct {
        context: Context,
        server: ServerLimits,
        /// Publishes the server would refuse.
        dropped: u64 = 0,

        fn keep(k: *@This(), _: usize, frame: Frame, bytes: []const u8) bool {
            if (frame.dead) return false;
            switch (frame.kind) {
                .request => {
                    if (!waiting(k.context, frame.request)) return false;
                    if (takes(k.server, bytes)) return true;
                    refused(k.context, frame.request);
                    return false;
                },
                .publish => {
                    if (takes(k.server, bytes)) return true;
                    k.dropped += 1;
                    return false;
                },
                .service, .ping => return true,
            }
        }
    };
}

/// The server takes the PUB or HPUB in `bytes`: within its `max_payload`,
/// and with headers only when it has them. The frame was encoded here, so
/// its line is well formed: the last argument is the size of headers and
/// payload together.
fn takes(server: ServerLimits, bytes: []const u8) bool {
    const line_end = std.mem.findScalar(u8, bytes, '\r') orelse return true;
    const line = bytes[0..line_end];
    if (std.mem.startsWith(u8, line, "HPUB ") and !server.headers) return false;
    if (server.max_payload == 0) return true;
    const size_at = (std.mem.findScalarLast(u8, line, ' ') orelse return true) + 1;
    const size = std.fmt.parseInt(u64, line[size_at..], 10) catch return true;
    return size <= server.max_payload;
}

/// Keeps the frames `keeper.keep(index, frame, bytes)` keeps, in order,
/// and drops the rest. The kept bytes move forward inside the chunks they
/// lie in, never past where they were, so nothing is allocated, no kept
/// frame can be lost, and memory never grows; chunks left empty go. Only
/// when no writer has a batch: in buffering mode after `settle`, or in
/// `settle` itself.
fn compact(q: *Outbound, keeper: anytype) void {
    q.queued = 0;
    q.buffered = 0;
    q.dead_bytes = 0;
    q.reserved = 0;
    // Where the frames are read: every frame lies in one chunk, and the
    // first may be written in part.
    var read_chunk: usize = 0;
    var read_at: usize = if (q.chunks.front()) |first| first.head - (if (q.frames.front()) |f| f.written else 0) else 0;
    // Where the kept ones go.
    var write_chunk: usize = 0;
    var write_at: usize = 0;
    var kept: usize = 0;
    for (0..q.frames.len) |index| {
        var frame = q.frames.at(index);
        if (read_at + frame.len > q.chunks.at(read_chunk).tail) {
            read_chunk += 1;
            read_at = 0;
        }
        const bytes = q.chunks.at(read_chunk).bytes[read_at..][0..frame.len];
        read_at += frame.len;
        if (!keeper.keep(index, frame, bytes)) continue;
        // The chunk it is read from has room at the latest: a chunk passed
        // over is read to its end already.
        while (q.chunks.at(write_chunk).bytes.len - write_at < frame.len) {
            q.chunks.at(write_chunk).tail = write_at;
            write_chunk += 1;
            write_at = 0;
        }
        std.mem.copyForwards(u8, q.chunks.at(write_chunk).bytes[write_at..][0..frame.len], bytes);
        write_at += frame.len;
        frame.written = 0;
        frame.reserved = false;
        q.frames.atPtr(kept).* = frame;
        kept += 1;
        if (frame.kind != .ping) {
            q.queued += frame.len + record_cost;
            q.buffered += frame.len + record_cost;
        }
    }
    if (kept > 0) q.chunks.at(write_chunk).tail = write_at;
    var chunks_kept: usize = 0;
    for (0..q.chunks.len) |index| {
        const chunk = q.chunks.at(index);
        if (kept > 0 and index <= write_chunk and chunk.tail > 0) {
            chunk.head = 0;
            q.chunks.atPtr(chunks_kept).* = chunk;
            chunks_kept += 1;
        } else {
            q.recycle(chunk);
        }
    }
    q.chunks.len = chunks_kept;
    q.frames.len = kept;
}

/// A new connection is up: the frames `build(context, gpa)` returns, which
/// bring the server up to date, go before everything that waits, and the
/// writer may send. What waits is checked first: a request frame whose
/// request no longer waits (`waiting(context, id)` false) is dropped, and
/// so is a publish or request the new server would refuse (`server`): the
/// publishes are counted as dropped and their number returned, and such a
/// request fails (`refused(context, id)`). All of it runs under the queue's
/// mutex, so no frame gets in meanwhile; the bytes `build` returns are the
/// queue's. Out of memory, nothing changes.
pub fn restore(
    q: *Outbound,
    io: Io,
    context: anytype,
    comptime build: fn (@TypeOf(context), Allocator) Allocator.Error![]u8,
    comptime waiting: fn (@TypeOf(context), u64) bool,
    comptime refused: fn (@TypeOf(context), u64) void,
    server: ServerLimits,
) error{ Closed, OutOfMemory }!u64 {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    if (q.mode == .closed) return error.Closed;
    // Whatever may fail comes first: the frames change once nothing can.
    const bytes = try build(context, q.gpa);
    errdefer q.gpa.free(bytes);
    try q.frames.ensureUnusedCapacity(q.gpa, 1);
    try q.chunks.ensureUnusedCapacity(q.gpa, 1);
    const chunk: ?*Chunk = if (bytes.len > 0) try q.gpa.create(Chunk) else null;
    var keeper: KeepWaiting(@TypeOf(context), waiting, refused) = .{ .context = context, .server = server };
    q.compact(&keeper);
    q.dropped_publishes += keeper.dropped;
    if (chunk) |c| {
        c.* = .{ .bytes = bytes, .tail = bytes.len };
        q.chunks.pushFrontAssumeCapacity(c);
        q.frames.pushFrontAssumeCapacity(.{ .kind = .service, .len = bytes.len });
        q.queued += bytes.len + record_cost;
    } else {
        q.gpa.free(bytes);
    }
    q.mode = .live;
    q.ready.signal(io);
    return keeper.dropped;
}

/// Refuses new frames and wakes everyone: waiting puts and PING waiters get
/// Closed, the writer gets null.
pub fn close(q: *Outbound, io: Io) void {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    if (q.mode == .closed) return;
    q.ended_pongs = if (q.mode == .live) q.pongs_received else 0;
    q.mode = .closed;
    q.generation += 1;
    q.wakeAll(io);
}

fn wakeAll(q: *Outbound, io: Io) void {
    var waiting = q.room_line.first;
    while (waiting) |node| : (waiting = node.next) {
        const waiter: *RoomWaiter = @fieldParentPtr("node", node);
        waiter.turn.set(io);
    }
    q.ready.broadcast(io);
    q.answered.wake(io);
}

/// A chunk with room for `len` bytes after its tail: the last one, or a
/// new one at the end.
fn reserve(q: *Outbound, len: usize) error{OutOfMemory}!*Chunk {
    try q.frames.ensureUnusedCapacity(q.gpa, 1);
    if (q.chunks.back()) |last| {
        if (last.bytes.len - last.tail >= len) return last;
        // An empty chunk too small for this frame must not stay in front
        // of the new one.
        if (last.head == last.tail) {
            _ = q.chunks.popBack();
            q.recycle(last);
        }
    }
    const chunk = try q.createChunk(len);
    q.chunks.pushBack(q.gpa, chunk) catch |err| {
        q.recycle(chunk);
        return err;
    };
    return chunk;
}

fn commit(q: *Outbound, chunk: *Chunk, frame: Frame) void {
    chunk.tail += frame.len;
    q.frames.pushBackAssumeCapacity(frame);
    if (frame.kind != .ping) q.queued += frame.len + record_cost;
}

/// The socket took `n` more bytes of the frames: their chunks give them
/// up, and the frames the socket took whole are forgotten.
fn advance(q: *Outbound, n: usize) void {
    var left = n;
    while (left > 0) {
        const chunk = q.chunks.front() orelse break;
        const step = @min(left, chunk.tail - chunk.head);
        if (step == 0) break;
        chunk.head += step;
        left -= step;
        q.dropWritten(step);
        if (chunk.head < chunk.tail) break;
        if (q.chunks.len > 1) {
            _ = q.chunks.popFront();
            q.recycle(chunk);
        } else {
            chunk.head = 0;
            chunk.tail = 0;
        }
    }
}

/// Marks `bytes` more of the oldest frames written and forgets those the
/// socket took whole.
fn dropWritten(q: *Outbound, bytes: usize) void {
    var left = bytes;
    while (left > 0) {
        const frame = q.frames.frontPtr() orelse return;
        const rest = frame.len - frame.written;
        if (left < rest) {
            frame.written += left;
            return;
        }
        left -= rest;
        switch (frame.kind) {
            .publish, .request => q.data_written += 1,
            .ping => {
                q.pings_written += 1;
                q.marks[q.pings_written % ping_marks] = .{ .number = q.pings_written, .data_frames = q.data_written };
                // Its PONG came before the writer said it was written.
                if (q.pongs_received >= q.pings_written) q.data_confirmed = q.data_written;
                // The server may see it now: unanswered, it is outstanding.
                if (frame.heartbeat and q.pongs_received < q.pings_written) q.pings_out +|= 1;
            },
            .service => {},
        }
        if (frame.kind != .ping) q.queued -= frame.len + record_cost;
        // The writer of the ended connection finished it after all.
        if (frame.reserved) q.reserved -= frame.len + record_cost;
        q.stale_frames -|= 1;
        _ = q.frames.popFront();
    }
}

/// Drops every frame and every chunk but the spare.
fn freeFrames(q: *Outbound) void {
    while (q.chunks.popFront()) |chunk| q.recycle(chunk);
    q.frames.head = 0;
    q.frames.len = 0;
    q.queued = 0;
    q.reserved = 0;
}

fn createChunk(q: *Outbound, len: usize) error{OutOfMemory}!*Chunk {
    if (len <= chunk_size) {
        if (q.spare) |chunk| {
            q.spare = null;
            return chunk;
        }
    }
    const chunk = try q.gpa.create(Chunk);
    errdefer q.gpa.destroy(chunk);
    chunk.* = .{ .bytes = try q.gpa.alloc(u8, @max(len, chunk_size)) };
    return chunk;
}

/// Keeps an emptied chunk of the usual size as the spare, frees others.
fn recycle(q: *Outbound, chunk: *Chunk) void {
    if (q.spare == null and chunk.bytes.len == chunk_size) {
        chunk.head = 0;
        chunk.tail = 0;
        q.spare = chunk;
    } else {
        q.destroyChunk(chunk);
    }
}

fn destroyChunk(q: *Outbound, chunk: *Chunk) void {
    q.gpa.free(chunk.bytes);
    q.gpa.destroy(chunk);
}

/// What `stats()` reports of the queue.
pub const Counts = struct { queued: usize, uncertain_frames: u64, dropped_publishes: u64 };

pub fn counts(q: *Outbound, io: Io) Counts {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    return .{ .queued = q.queued, .uncertain_frames = q.uncertain_frames, .dropped_publishes = q.dropped_publishes };
}

/// Puts waiting for room; tests use it to know that a put waits.
pub fn roomWaiters(q: *Outbound, io: Io) u32 {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    return q.room_waiters;
}

const testing = std.testing;

fn writePub(w: *Writer, subject: []const u8, payload: []const u8) Writer.Error!void {
    return encoder.writePub(w, subject, null, payload);
}

fn putPub(q: *Outbound, io: Io, kind: Kind, subject: []const u8, payload: []const u8) PutError!void {
    return q.put(io, kind, encoder.pubLen(subject, null, payload.len), writePub, .{ subject, payload });
}

/// Takes one batch, appends its bytes to `out` and marks them written.
fn drainOnce(q: *Outbound, io: Io, out: *std.ArrayList(u8)) !void {
    var slices: [16][]const u8 = undefined;
    const batch = (try q.take(io, &slices)) orelse return error.TestClosed;
    var len: usize = 0;
    for (batch.slices) |slice| {
        try out.appendSlice(testing.allocator, slice);
        len += slice.len;
    }
    try testing.expectEqual(len, batch.len);
    q.written(io, batch.len);
}

fn awaitRoomWaiter(q: *Outbound, io: Io) !void {
    const give_up = time.after(io, .fromSeconds(5 * @as(i64, @import("anole_test_wait").timeoutFactor())));
    while (q.roomWaiters(io) == 0) {
        if (time.expired(io, give_up)) return error.TestPutNeverWaited;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "frames come out whole and in order, PONGs first" {
    const io = testing.io;
    var q: Outbound = .init(testing.allocator, 1 << 20);
    defer q.deinit();
    try putPub(&q, io, .publish, "a", "1");
    try putPub(&q, io, .request, "b", "22");
    try testing.expectEqual(1, (try q.putPing(io, .flush)).number);
    q.queuePong(io);
    q.queuePong(io);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try drainOnce(&q, io, &out);
    try testing.expectEqualStrings("PONG\r\nPONG\r\nPUB a 1\r\n1\r\nPUB b 2\r\n22\r\nPING\r\n", out.items);
    var frames: [4]Frame = undefined;
    try testing.expectEqual(0, q.unsent(io, &frames).len);
}

test "a frame larger than a chunk, among small ones in many chunks" {
    const io = testing.io;
    var q: Outbound = .init(testing.allocator, 1 << 24);
    defer q.deinit();
    const big = try testing.allocator.alloc(u8, chunk_size + 100);
    defer testing.allocator.free(big);
    @memset(big, 'x');

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    var subject_buffer: [16]u8 = undefined;
    for (0..3000) |i| {
        const subject = try std.fmt.bufPrint(&subject_buffer, "s.{d}", .{i});
        const payload: []const u8 = if (i == 1500) big else "payload";
        try putPub(&q, io, .publish, subject, payload);
        var w: Writer.Allocating = .init(testing.allocator);
        defer w.deinit();
        try encoder.writePub(&w.writer, subject, null, payload);
        try expected.appendSlice(testing.allocator, w.written());
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    while (out.items.len < expected.items.len) try drainOnce(&q, io, &out);
    try testing.expectEqualSlices(u8, expected.items, out.items);
}

fn putLater(q: *Outbound, io: Io) PutError!void {
    return putPub(q, io, .publish, "late", "x");
}

test "a full queue makes put wait until the writer takes frames" {
    const io = testing.io;
    var q: Outbound = .init(testing.allocator, 64);
    defer q.deinit();
    try putPub(&q, io, .publish, "first", "0123456789");
    try putPub(&q, io, .publish, "second", "0123456789");
    var putter = try io.concurrent(putLater, .{ &q, io });
    defer putter.cancel(io) catch {};
    try awaitRoomWaiter(&q, io);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try drainOnce(&q, io, &out);
    try putter.await(io);
    try drainOnce(&q, io, &out);
    try testing.expectEqualStrings("PUB first 10\r\n0123456789\r\nPUB second 10\r\n0123456789\r\nPUB late 1\r\nx\r\n", out.items);
}

test "a canceled put queues nothing" {
    const io = testing.io;
    var q: Outbound = .init(testing.allocator, 16);
    defer q.deinit();
    try putPub(&q, io, .publish, "first", "0123456789");
    var putter = try io.concurrent(putLater, .{ &q, io });
    defer putter.cancel(io) catch {};
    try awaitRoomWaiter(&q, io);
    try testing.expectError(error.Canceled, putter.cancel(io));
    var frames: [4]Frame = undefined;
    try testing.expectEqual(1, q.unsent(io, &frames).len);
}

fn writeUnsub(w: *Writer, sid: u64) Writer.Error!void {
    return encoder.writeUnsub(w, sid, null);
}

test "after the drain's last PING, publishes and requests are refused, those waiting for room too" {
    const io = testing.io;
    var q: Outbound = .init(testing.allocator, 16);
    defer q.deinit();
    try putPub(&q, io, .publish, "first", "0123456789");
    var putter = try io.concurrent(putLater, .{ &q, io });
    defer putter.cancel(io) catch {};
    try awaitRoomWaiter(&q, io);
    _ = try q.stopPublishes(io);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try drainOnce(&q, io, &out);
    // Room came after the PING: the waiting publish did not go in.
    try testing.expectError(error.ConnectionDraining, putter.await(io));
    try testing.expectEqualStrings("PUB first 10\r\n0123456789\r\nPING\r\n", out.items);
    try testing.expectError(error.ConnectionDraining, putPub(&q, io, .publish, "p", "1"));
    try testing.expectError(error.ConnectionDraining, putPub(&q, io, .request, "r", "1"));
    // An UNSUB still goes, and a closed queue says so.
    try q.putNow(io, .service, encoder.unsubLen(7, null), writeUnsub, .{7});
    q.close(io);
    try testing.expectError(error.Closed, putPub(&q, io, .publish, "p", "1"));
}

test "putNow skips the wait for room, yet counts against the limit" {
    const io = testing.io;
    var q: Outbound = .init(testing.allocator, 16);
    defer q.deinit();
    try putPub(&q, io, .publish, "first", "0123456789");
    try q.putNow(io, .service, encoder.unsubLen(7, null), writeUnsub, .{7});
    try testing.expect(q.queued >= q.limit);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try drainOnce(&q, io, &out);
    try testing.expectEqualStrings("PUB first 10\r\n0123456789\r\nUNSUB 7\r\n", out.items);
    q.close(io);
    try testing.expectError(error.Closed, q.putNow(io, .service, encoder.unsubLen(7, null), writeUnsub, .{7}));
}

test "PINGs skip the limit but keep their place" {
    const io = testing.io;
    var q: Outbound = .init(testing.allocator, 1);
    defer q.deinit();
    try putPub(&q, io, .publish, "a", "1");
    try testing.expectEqual(1, (try q.putPing(io, .flush)).number);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try drainOnce(&q, io, &out);
    try testing.expectEqualStrings("PUB a 1\r\n1\r\nPING\r\n", out.items);
}

fn takeOne(q: *Outbound, io: Io) Io.Cancelable!?Batch {
    var slices: [4][]const u8 = undefined;
    return q.take(io, &slices);
}

fn waitFirstPong(q: *Outbound, io: Io) WaitError!void {
    return q.waitPong(io, .{ .number = 1 }, null);
}

test "close wakes a waiting put, the writer and PING waiters" {
    const io = testing.io;
    {
        var q: Outbound = .init(testing.allocator, 16);
        defer q.deinit();
        try putPub(&q, io, .publish, "first", "0123456789");
        var putter = try io.concurrent(putLater, .{ &q, io });
        defer putter.cancel(io) catch {};
        try awaitRoomWaiter(&q, io);
        q.close(io);
        try testing.expectError(error.Closed, putter.await(io));
        try testing.expectError(error.Closed, putPub(&q, io, .publish, "after", "close"));
        try testing.expectError(error.Closed, q.putPing(io, .flush));
    }
    {
        var q: Outbound = .init(testing.allocator, 16);
        defer q.deinit();
        var writer = try io.concurrent(takeOne, .{ &q, io });
        defer _ = writer.cancel(io) catch null;
        try io.sleep(.fromMilliseconds(10), .awake);
        q.close(io);
        try testing.expect(try writer.await(io) == null);
    }
    {
        var q: Outbound = .init(testing.allocator, 16);
        defer q.deinit();
        _ = try q.putPing(io, .flush);
        var waiter = try io.concurrent(waitFirstPong, .{ &q, io });
        defer waiter.cancel(io) catch {};
        try io.sleep(.fromMilliseconds(10), .awake);
        q.close(io);
        try testing.expectError(error.Closed, waiter.await(io));
    }
}

test "PINGs are numbered and each PONG answers the oldest" {
    const io = testing.io;
    var q: Outbound = .init(testing.allocator, 1024);
    defer q.deinit();
    try testing.expectEqual(1, (try q.putPing(io, .flush)).number);
    try putPub(&q, io, .publish, "a", "1");
    try testing.expectEqual(2, (try q.putPing(io, .heartbeat)).number);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try drainOnce(&q, io, &out);
    try testing.expectEqual(1, q.pingsOut(io));
    try testing.expectError(error.Timeout, q.waitPong(io, .{ .number = 1 }, time.after(io, .zero)));

    q.pongReceived(io);
    try q.waitPong(io, .{ .number = 1 }, null);
    try testing.expectEqual(0, q.pingsOut(io));
    try testing.expectError(error.Timeout, q.waitPong(io, .{ .number = 2 }, time.after(io, .fromMilliseconds(10))));
    q.pongReceived(io);
    try q.waitPong(io, .{ .number = 2 }, time.after(io, .fromSeconds(5)));
}

test "a heartbeat PING counts as outstanding once it is written, not while it waits behind other frames" {
    const io = testing.io;
    var q: Outbound = .init(testing.allocator, 1 << 20);
    defer q.deinit();
    try putPub(&q, io, .publish, "a", "1"); // 12 bytes
    _ = try q.putPing(io, .heartbeat);
    // Still behind the publish: the server cannot have seen it.
    try testing.expectEqual(0, q.pingsOut(io));
    var slices: [4][]const u8 = undefined;
    const batch = (try q.take(io, &slices)).?;
    q.written(io, 12);
    try testing.expectEqual(0, q.pingsOut(io));
    q.written(io, batch.len - 12);
    try testing.expectEqual(1, q.pingsOut(io));
    q.pongReceived(io);
    try testing.expectEqual(0, q.pingsOut(io));

    // Its PONG came before the writer said it was written: not outstanding.
    _ = try q.putPing(io, .heartbeat);
    const next = (try q.take(io, &slices)).?;
    q.pongReceived(io);
    q.written(io, next.len);
    try testing.expectEqual(0, q.pingsOut(io));
}

test "a partial write marks the frame it stopped in" {
    const io = testing.io;
    var q: Outbound = .init(testing.allocator, 1024);
    defer q.deinit();
    try putPub(&q, io, .publish, "a", "1"); // 12 bytes
    _ = try q.putPing(io, .heartbeat); // 6 bytes
    try putPub(&q, io, .request, "b", "2");

    var slices: [4][]const u8 = undefined;
    const batch = (try q.take(io, &slices)).?;
    try testing.expectEqual(30, batch.len);
    q.written(io, 12 + 2);
    var frames: [4]Frame = undefined;
    const left = q.unsent(io, &frames);
    try testing.expectEqual(2, left.len);
    try testing.expectEqual(Frame{ .kind = .ping, .len = 6, .written = 2, .heartbeat = true }, left[0]);
    try testing.expectEqual(Frame{ .kind = .request, .len = 12, .written = 0 }, left[1]);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try drainOnce(&q, io, &out);
    try testing.expectEqualStrings("NG\r\nPUB b 1\r\n2\r\n", out.items);
}

fn exercise(gpa: Allocator) !void {
    const io = testing.io;
    var q: Outbound = .init(gpa, 1 << 20);
    defer q.deinit();
    const big = try gpa.alloc(u8, chunk_size + 1);
    defer gpa.free(big);
    @memset(big, 'y');
    for (0..20) |i| {
        try putPub(&q, io, if (i % 2 == 0) .publish else .request, "s", if (i == 10) big else "p");
        if (i % 7 == 0) _ = try q.putPing(io, .flush);
    }
    var slices: [16][]const u8 = undefined;
    const batch = (try q.take(io, &slices)).?;
    q.written(io, batch.len / 2);
}

test "nothing leaks when an allocation fails" {
    try testing.checkAllAllocationFailures(@import("../../../testing/no_resize.zig").allocator, exercise, .{});
}

test "a PING answered before its connection ended is answered, whenever its waiter looks" {
    const io = testing.io;
    var q: Outbound = .initBuffering(testing.allocator, 1024, 1024);
    defer q.deinit();
    _ = try q.restore(io, @as([]const u8, ""), restoreSub, allWaiting, refuseNone, .{});
    const answered = try q.putPing(io, .flush);
    const unanswered = try q.putPing(io, .heartbeat);
    try testing.expectEqual(answered, unanswered);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try drainOnce(&q, io, &out);
    q.pongReceived(io);
    _ = q.halt(io);
    try q.waitPong(io, answered, null);
    // The next PING of that connection was never answered.
    try putPub(&q, io, .publish, "p", "1");
    _ = q.settle(io);
    _ = try q.restore(io, @as([]const u8, ""), restoreSub, allWaiting, refuseNone, .{});
    const second = try q.putPing(io, .flush);
    try drainOnce(&q, io, &out);
    _ = q.halt(io);
    // The reader still read its PONG before it stopped.
    q.pongReceived(io);
    try q.waitPong(io, second, null);
    _ = q.settle(io);
    _ = try q.restore(io, @as([]const u8, ""), restoreSub, allWaiting, refuseNone, .{});
    const third = try q.putPing(io, .flush);
    _ = q.halt(io);
    try testing.expectError(error.Disconnected, q.waitPong(io, third, null));
    // A close after the PONG too.
    _ = q.settle(io);
    _ = try q.restore(io, @as([]const u8, ""), restoreSub, allWaiting, refuseNone, .{});
    const last = try q.putPing(io, .flush);
    try drainOnce(&q, io, &out);
    q.pongReceived(io);
    q.close(io);
    try q.waitPong(io, last, null);
}

test "PINGs in a row share one frame, so they stay bounded" {
    const io = testing.io;
    var q: Outbound = .init(testing.allocator, 1024);
    defer q.deinit();
    var frames: [8]Frame = undefined;

    // Flushes that time out leave their PING behind; with nothing queued
    // after it, the next one waits on the same PING.
    const first = try q.putPing(io, .flush);
    for (0..1000) |_| try testing.expectEqual(first, try q.putPing(io, .flush));
    try testing.expectEqual(first, try q.putPing(io, .heartbeat));
    // The shared PING carries the heartbeat's: outstanding once written.
    try testing.expect(q.unsent(io, &frames)[0].heartbeat);
    try testing.expectEqual(1, q.unsent(io, &frames).len);

    // A frame after it needs a PING of its own.
    try putPub(&q, io, .publish, "a", "1");
    const second = try q.putPing(io, .flush);
    try testing.expectEqual(first.number + 1, second.number);
    try testing.expectEqual(3, q.unsent(io, &frames).len);

    // A PING the writer has begun is not shared.
    var slices: [4][]const u8 = undefined;
    const batch = (try q.take(io, &slices)) orelse return error.TestClosed;
    q.written(io, batch.len - 3);
    const third = try q.putPing(io, .flush);
    try testing.expectEqual(second.number + 1, third.number);

    // Each PONG answers every caller that shared its PING.
    q.pongReceived(io);
    try q.waitPong(io, first, null);
    try testing.expectError(error.Timeout, q.waitPong(io, second, time.after(io, .zero)));
}

fn roomWakeups(q: *Outbound, io: Io) u64 {
    q.mutex.lockUncancelable(io);
    defer q.mutex.unlock(io);
    return q.room_wakeups;
}

const hundred: [100]u8 = @splat('x');

/// Puts `count` frames of 100 bytes, each waiting for room as it must. A
/// failure closes the queue, so the test fails rather than waits.
fn putMany(q: *Outbound, io: Io, count: usize) Io.Cancelable!void {
    for (0..count) |_| putPub(q, io, .publish, "s", &hundred) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return q.close(io),
    };
}

/// Like a slow socket, takes one frame per batch until `frames` went out.
fn writeSlowly(q: *Outbound, io: Io, frames: usize) !void {
    const frame_len = encoder.pubLen("s", null, hundred.len);
    var slices: [16][]const u8 = undefined;
    var left = frames * frame_len;
    while (left > 0) {
        const batch = (try q.take(io, &slices)) orelse return error.TestClosed;
        const n = @min(batch.len, frame_len, left);
        q.written(io, n);
        left -= n;
    }
}

test "room for one frame wakes one waiting put, not all of them" {
    const io = testing.io;
    var q: Outbound = .init(testing.allocator, 1);
    defer q.deinit();
    const publishers = 16;
    const each = 50;
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (0..publishers) |_| try group.concurrent(io, putMany, .{ &q, io, each });
    try writeSlowly(&q, io, publishers * each);
    try group.await(io);
    // Waking every waiter for each frame costs several wakeups per frame
    // with this many publishers; one per frame is the aim.
    try testing.expect(q.roomWakeups(io) <= publishers * each);
}

/// Puts one frame with `subject`, waiting for room.
fn putNamed(q: *Outbound, io: Io, subject: []const u8) PutError!void {
    return putPub(q, io, .publish, subject, "x");
}

/// Waits until `count` puts wait for room, for 5 s at most.
fn awaitRoomWaiters(q: *Outbound, io: Io, count: u32) !void {
    const give_up = time.after(io, .fromSeconds(5 * @as(i64, @import("anole_test_wait").timeoutFactor())));
    while (q.roomWaiters(io) < count) {
        if (time.expired(io, give_up)) return error.TestPutNeverWaited;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "puts that wait for room go in the order they came" {
    const io = testing.io;
    var q: Outbound = .init(testing.allocator, 16);
    defer q.deinit();
    try putPub(&q, io, .publish, "first", "0123456789");
    var futures: [3]Io.Future(PutError!void) = undefined;
    var started: usize = 0;
    defer for (futures[0..started]) |*f| f.cancel(io) catch {};
    for ([_][]const u8{ "a", "b", "c" }, 0..) |subject, i| {
        futures[i] = try io.concurrent(putNamed, .{ &q, io, subject });
        started += 1;
        try awaitRoomWaiters(&q, io, @intCast(i + 1));
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    // One frame fits at a time: each drain lets the next in line in.
    for (0..4) |_| try drainOnce(&q, io, &out);
    for (&futures) |*f| try f.await(io);
    try testing.expectEqualStrings("PUB first 10\r\n0123456789\r\nPUB a 1\r\nx\r\nPUB b 1\r\nx\r\nPUB c 1\r\nx\r\n", out.items);
}

test "a put that leaves the line lets the next one in" {
    const io = testing.io;
    var q: Outbound = .init(testing.allocator, 16);
    defer q.deinit();
    try putPub(&q, io, .publish, "first", "0123456789");
    var a = try io.concurrent(putNamed, .{ &q, io, "a" });
    defer a.cancel(io) catch {};
    try awaitRoomWaiters(&q, io, 1);
    var b = try io.concurrent(putNamed, .{ &q, io, "b" });
    defer b.cancel(io) catch {};
    try awaitRoomWaiters(&q, io, 2);
    try testing.expectError(error.Canceled, a.cancel(io));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try drainOnce(&q, io, &out);
    try b.await(io);
    try drainOnce(&q, io, &out);
    try testing.expectEqualStrings("PUB first 10\r\n0123456789\r\nPUB b 1\r\nx\r\n", out.items);
}

fn putNamedUntil(q: *Outbound, io: Io, subject: []const u8, deadline: Io.Clock.Timestamp) PutUntilError!void {
    return q.putUntil(io, deadline, .request, encoder.pubLen(subject, null, 1), writePub, .{ subject, "x" });
}

test "a put with a deadline gives up waiting for room at it, and leaves the line" {
    const io = testing.io;
    var q: Outbound = .init(testing.allocator, 16);
    defer q.deinit();
    try putPub(&q, io, .publish, "first", "0123456789");
    const deadline = time.after(io, .fromMilliseconds(20));
    try testing.expectError(error.Timeout, putNamedUntil(&q, io, "late", deadline));
    try testing.expect(time.expired(io, deadline));
    try testing.expectEqual(0, q.roomWaiters(io));
    var frames: [4]Frame = undefined;
    try testing.expectEqual(1, q.unsent(io, &frames).len);
}

test "a put with a deadline goes in when room comes in time, and one that timed out lets the next in" {
    const io = testing.io;
    var q: Outbound = .init(testing.allocator, 16);
    defer q.deinit();
    // Past its deadline it goes nowhere, room or not; with room it goes in
    // at once.
    try testing.expectError(error.Timeout, putNamedUntil(&q, io, "gone", time.after(io, .zero)));
    try putNamedUntil(&q, io, "a", time.after(io, .fromSeconds(5)));
    // Its deadline leaves the next put ample time to get in line behind it,
    // even where sleeps are counted in ticks of ~15.6 ms, as on Windows.
    const soon_deadline = time.after(io, .fromSeconds(1));
    var soon = try io.concurrent(putNamedUntil, .{ &q, io, "soon", soon_deadline });
    defer soon.cancel(io) catch {};
    try awaitRoomWaiters(&q, io, 1);
    var later = try io.concurrent(putNamedUntil, .{ &q, io, "later", time.after(io, .fromSeconds(30)) });
    defer later.cancel(io) catch {};
    try awaitRoomWaiters(&q, io, 2);
    try testing.expectError(error.Timeout, soon.await(io));
    // Not before its deadline, on the deadline's own clock; the put behind
    // it still waits.
    try testing.expect(time.expired(io, soon_deadline));
    try testing.expectEqual(1, q.roomWaiters(io));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try drainOnce(&q, io, &out);
    try later.await(io);
    try drainOnce(&q, io, &out);
    try testing.expectEqualStrings("PUB a 1\r\nx\r\nPUB later 1\r\nx\r\n", out.items);
}

test "close wakes every put in line" {
    const io = testing.io;
    var q: Outbound = .init(testing.allocator, 16);
    defer q.deinit();
    try putPub(&q, io, .publish, "first", "0123456789");
    var futures: [3]Io.Future(PutError!void) = undefined;
    var started: usize = 0;
    defer for (futures[0..started]) |*f| f.cancel(io) catch {};
    for (&futures, 0..) |*f, i| {
        f.* = try io.concurrent(putNamed, .{ &q, io, "w" });
        started += 1;
        try awaitRoomWaiters(&q, io, @intCast(i + 1));
    }
    q.close(io);
    for (&futures) |*f| try testing.expectError(error.Closed, f.await(io));
    try testing.expectEqual(0, q.roomWaiters(io));
}

fn waitPing(q: *Outbound, io: Io, ping: Ping) WaitError!void {
    return q.waitPong(io, ping, null);
}

test "a connection that ends stops the writer, and PING waiters and puts in line learn it" {
    const io = testing.io;
    var q: Outbound = .init(testing.allocator, 16);
    defer q.deinit();
    try putPub(&q, io, .publish, "first", "0123456789");
    const ping = try q.putPing(io, .flush);
    var waiter = try io.concurrent(waitPing, .{ &q, io, ping });
    defer waiter.cancel(io) catch {};
    var putter = try io.concurrent(putLater, .{ &q, io });
    defer putter.cancel(io) catch {};
    try awaitRoomWaiter(&q, io);

    _ = q.halt(io);
    try testing.expectError(error.Disconnected, waiter.await(io));
    // Without a connection a publish fails at once.
    try testing.expectError(error.Disconnected, putter.await(io));
    try testing.expect(try takeOne(&q, io) == null);
    try testing.expectError(error.Disconnected, q.putPing(io, .flush));

    // What the connection left goes; nothing is sent again.
    _ = q.settle(io);
    var frames: [4]Frame = undefined;
    try testing.expectEqual(0, q.unsent(io, &frames).len);
    try testing.expectEqual(0, q.queued);
}

test "without a connection SUB and UNSUB are left to the restore, the rest fails with Disconnected" {
    const io = testing.io;
    var q: Outbound = .initBuffering(testing.allocator, 16, 0);
    defer q.deinit();
    try q.put(io, .service, encoder.unsubLen(7, null), writeUnsub, .{7});
    try q.putNow(io, .service, encoder.unsubLen(7, null), writeUnsub, .{7});
    try testing.expectError(error.Disconnected, putPub(&q, io, .publish, "a", "1"));
    try testing.expectError(error.Disconnected, putPub(&q, io, .request, "b", "2"));
    try testing.expectError(error.Disconnected, q.putPing(io, .flush));
    var frames: [4]Frame = undefined;
    try testing.expectEqual(0, q.unsent(io, &frames).len);
}

fn restoreSub(text: []const u8, gpa: Allocator) Allocator.Error![]u8 {
    return gpa.dupe(u8, text);
}

fn allWaiting(_: []const u8, _: u64) bool {
    return true;
}

fn refuseNone(_: []const u8, _: u64) void {}

test "restore puts its frames first and lets the writer send" {
    const io = testing.io;
    var q: Outbound = .initBuffering(testing.allocator, 1024, 0);
    defer q.deinit();
    _ = try q.restore(io, @as([]const u8, "SUB a 1\r\n"), restoreSub, allWaiting, refuseNone, .{});
    try putPub(&q, io, .publish, "a", "1");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try drainOnce(&q, io, &out);
    try testing.expectEqualStrings("SUB a 1\r\nPUB a 1\r\n1\r\n", out.items);

    // The next connection starts with its own restore and its own PINGs.
    _ = try q.putPing(io, .flush);
    _ = q.halt(io);
    _ = q.settle(io);
    _ = try q.restore(io, @as([]const u8, ""), restoreSub, allWaiting, refuseNone, .{});
    try testing.expectEqual(1, (try q.putPing(io, .flush)).number);
}

test "a closed queue stays closed when its connection ends" {
    const io = testing.io;
    var q: Outbound = .init(testing.allocator, 16);
    defer q.deinit();
    q.close(io);
    _ = q.halt(io);
    try testing.expectError(error.Closed, putPub(&q, io, .publish, "a", "1"));
    try testing.expectError(error.Closed, q.restore(io, @as([]const u8, "SUB a 1\r\n"), restoreSub, allWaiting, refuseNone, .{}));
}

fn frameCost(subject: []const u8, payload: []const u8) usize {
    return encoder.pubLen(subject, null, payload.len) + record_cost;
}

test "a lost connection: PUB and HPUB written after the last confirmed PING are uncertain, and unsent publishes wait for the next one" {
    const io = testing.io;
    var q: Outbound = .initBuffering(testing.allocator, 1 << 20, 1 << 20);
    defer q.deinit();
    _ = try q.restore(io, @as([]const u8, ""), restoreSub, allWaiting, refuseNone, .{});
    try putPub(&q, io, .publish, "a", "1");
    const first = try q.putPing(io, .flush);
    try putPub(&q, io, .publish, "b", "2");
    try putPub(&q, io, .request, "c", "3");
    try q.putNow(io, .service, encoder.unsubLen(7, null), writeUnsub, .{7});
    _ = try q.putPing(io, .heartbeat);
    try putPub(&q, io, .publish, "d", "4");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try drainOnce(&q, io, &out);
    // The first PING is answered: "a" reached the server; the second never.
    q.pongReceived(io);
    try q.waitPong(io, first, null);
    try putPub(&q, io, .publish, "e", "5");
    try putPub(&q, io, .request, "f", "6");

    _ = q.halt(io);
    // While there is no connection, a publish waits for the next one.
    try putPub(&q, io, .publish, "g", "7");
    const settled = q.settle(io);
    try testing.expectEqual(3, settled.uncertain);
    try testing.expectEqual(0, settled.dropped);
    try testing.expectEqual(3, q.uncertain_frames);

    // The next connection: its restore, then what waited, in order; the
    // request is gone.
    _ = try q.restore(io, @as([]const u8, "SUB x 1\r\n"), restoreSub, allWaiting, refuseNone, .{});
    out.clearRetainingCapacity();
    try drainOnce(&q, io, &out);
    try testing.expectEqualStrings("SUB x 1\r\nPUB e 1\r\n5\r\nPUB g 1\r\n7\r\n", out.items);
}

test "unsent publishes keep their order in the buffer while it has room; the rest are dropped and counted" {
    const io = testing.io;
    var q: Outbound = .initBuffering(testing.allocator, 1 << 20, 2 * frameCost("p", "1"));
    defer q.deinit();
    _ = try q.restore(io, @as([]const u8, ""), restoreSub, allWaiting, refuseNone, .{});
    try putPub(&q, io, .publish, "p", "1");
    try putPub(&q, io, .publish, "p", "2");
    try putPub(&q, io, .publish, "p", "3");
    try putPub(&q, io, .request, "r", "4");
    try q.putNow(io, .service, encoder.unsubLen(7, null), writeUnsub, .{7});
    _ = q.halt(io);
    const settled = q.settle(io);
    try testing.expectEqual(1, settled.dropped);
    try testing.expectEqual(0, settled.uncertain);
    try testing.expectEqual(1, q.dropped_publishes);
    // The buffer is full: a publish now does not fit.
    try testing.expectError(error.BufferFull, putPub(&q, io, .publish, "p", "5"));
    _ = try q.restore(io, @as([]const u8, ""), restoreSub, allWaiting, refuseNone, .{});
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try drainOnce(&q, io, &out);
    try testing.expectEqualStrings("PUB p 1\r\n1\r\nPUB p 1\r\n2\r\n", out.items);
}

test "without a connection a frame waits up to the buffer's room, else BufferFull at once; with no buffer, Disconnected" {
    const io = testing.io;
    var q: Outbound = .initBuffering(testing.allocator, 16, frameCost("a", "1") + frameCost("b", "2") - 1);
    defer q.deinit();
    try putPub(&q, io, .publish, "a", "1");
    try testing.expectError(error.BufferFull, putPub(&q, io, .publish, "b", "2"));
    try testing.expectError(error.BufferFull, putPub(&q, io, .request, "b", "2"));
    // Larger than the whole buffer: it fails at once, and never waits.
    const big: [256]u8 = @splat('x');
    try testing.expectError(error.BufferFull, putPub(&q, io, .publish, "big", &big));
    var frames: [4]Frame = undefined;
    try testing.expectEqual(1, q.unsent(io, &frames).len);

    var none: Outbound = .initBuffering(testing.allocator, 16, 0);
    defer none.deinit();
    try testing.expectError(error.Disconnected, putPub(&none, io, .publish, "a", "1"));
    try testing.expectError(error.Disconnected, putPub(&none, io, .request, "a", "1"));
}

test "a frame written in part is dropped, never sent again" {
    const io = testing.io;
    var q: Outbound = .initBuffering(testing.allocator, 1 << 20, 1 << 20);
    defer q.deinit();
    _ = try q.restore(io, @as([]const u8, ""), restoreSub, allWaiting, refuseNone, .{});
    try putPub(&q, io, .publish, "p", "1");
    try putPub(&q, io, .publish, "q", "2");
    var slices: [4][]const u8 = undefined;
    _ = (try q.take(io, &slices)).?;
    q.written(io, 5);
    _ = q.halt(io);
    const settled = q.settle(io);
    try testing.expectEqual(1, settled.dropped);
    try testing.expectEqual(0, settled.uncertain);
    _ = try q.restore(io, @as([]const u8, ""), restoreSub, allWaiting, refuseNone, .{});
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try drainOnce(&q, io, &out);
    try testing.expectEqualStrings("PUB q 1\r\n2\r\n", out.items);
}

test "close drops what was never written, counts the publishes, and does so once" {
    const io = testing.io;
    var q: Outbound = .init(testing.allocator, 1 << 20);
    defer q.deinit();
    try putPub(&q, io, .publish, "p", "1");
    try putPub(&q, io, .request, "r", "2");
    try putPub(&q, io, .publish, "p", "3");
    q.close(io);
    try testing.expectEqual(2, q.discard(io).dropped);
    try testing.expectEqual(0, q.discard(io).dropped);
    try testing.expectEqual(2, q.dropped_publishes);
}

fn exerciseSettle(gpa: Allocator) !void {
    const io = testing.io;
    var q: Outbound = .initBuffering(gpa, 1 << 20, 1 << 20);
    defer q.deinit();
    _ = try q.restore(io, @as([]const u8, "SUB a 1\r\n"), restoreSub, allWaiting, refuseNone, .{});
    const big = try gpa.alloc(u8, chunk_size + 1);
    defer gpa.free(big);
    @memset(big, 'y');
    for (0..10) |i| try putPub(&q, io, if (i % 3 == 0) .request else .publish, "s", if (i == 5) big else "p");
    _ = q.halt(io);
    _ = q.settle(io);
    _ = try q.restore(io, @as([]const u8, "SUB a 1\r\n"), restoreSub, allWaiting, refuseNone, .{});
}

test "nothing leaks when an allocation fails while settling and restoring" {
    try testing.checkAllAllocationFailures(@import("../../../testing/no_resize.zig").allocator, exerciseSettle, .{});
}

/// A ticket that admits its frame, or not, as `admit` says, and notes the
/// connection it went to.
const TestTicket = struct {
    admit: bool = true,
    generation: ?u64 = null,

    fn decide(context: *anyopaque, _: Io, _: u64, generation: u64) bool {
        const t: *TestTicket = @ptrCast(@alignCast(context));
        if (t.admit) t.generation = generation;
        return t.admit;
    }

    fn of(t: *TestTicket, id: u64) Ticket {
        return .{ .id = id, .context = t, .admit = decide };
    }
};

fn putRequestFrame(q: *Outbound, io: Io, ticket: Ticket, subject: []const u8) PutUntilError!void {
    return q.putRequest(io, null, ticket, encoder.pubLen(subject, null, 1), writePub, .{ subject, "x" });
}

test "a request frame goes in only when its request agrees, and learns its connection" {
    const io = testing.io;
    var q: Outbound = .init(testing.allocator, 1024);
    defer q.deinit();
    var refused: TestTicket = .{ .admit = false };
    try testing.expectError(error.Disconnected, putRequestFrame(&q, io, refused.of(1), "r"));
    var frames: [4]Frame = undefined;
    try testing.expectEqual(0, q.unsent(io, &frames).len);
    var admitted: TestTicket = .{};
    try putRequestFrame(&q, io, admitted.of(2), "r");
    try testing.expectEqual(0, admitted.generation.?);
    try testing.expectEqual(2, q.unsent(io, &frames)[0].request);
}

fn putRequestLater(q: *Outbound, io: Io, ticket: Ticket) PutUntilError!void {
    return putRequestFrame(q, io, ticket, "late");
}

test "a request waiting for room when its connection ends goes nowhere: Disconnected" {
    const io = testing.io;
    var q: Outbound = .initBuffering(testing.allocator, 16, 1 << 20);
    defer q.deinit();
    _ = try q.restore(io, @as([]const u8, ""), restoreSub, allWaiting, refuseNone, .{});
    try putPub(&q, io, .publish, "first", "0123456789");
    var ticket: TestTicket = .{};
    var requester = try io.concurrent(putRequestLater, .{ &q, io, ticket.of(7) });
    defer requester.cancel(io) catch {};
    try awaitRoomWaiter(&q, io);
    _ = q.halt(io);
    // Not into the reconnect buffer: its request ends with the connection.
    try testing.expectError(error.Disconnected, requester.await(io));
    try testing.expect(ticket.generation == null);
    _ = q.settle(io);
    var frames: [4]Frame = undefined;
    // The publish waits for the next connection; nothing of the request.
    const left = q.unsent(io, &frames);
    try testing.expectEqual(1, left.len);
    try testing.expectEqual(.publish, left[0].kind);
}

fn waitingBut(gone: []const u8, id: u64) bool {
    return std.mem.findScalar(u8, gone, @intCast(id)) == null;
}

fn buildNothing(_: []const u8, gpa: Allocator) Allocator.Error![]u8 {
    return gpa.alloc(u8, 0);
}

test "a request that ends while its frame waits for the next connection is never sent, and gives its room back" {
    const io = testing.io;
    var q: Outbound = .initBuffering(testing.allocator, 1 << 20, 1 << 20);
    defer q.deinit();
    var tickets: [3]TestTicket = .{ .{}, .{}, .{} };
    try putRequestFrame(&q, io, tickets[0].of(1), "one");
    try putPub(&q, io, .publish, "p", "1");
    try putRequestFrame(&q, io, tickets[1].of(2), "two");
    try putRequestFrame(&q, io, tickets[2].of(3), "three");
    const before = q.counts(io).queued;
    q.forgetRequest(io, 1);
    try testing.expect(q.counts(io).queued < before);
    q.forgetRequest(io, 1);
    // Request 3 ended too, without a word: the restore asks.
    _ = try q.restore(io, @as([]const u8, &.{3}), buildNothing, waitingBut, refuseNone, .{});
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try drainOnce(&q, io, &out);
    try testing.expectEqualStrings("PUB p 1\r\n1\r\nPUB two 1\r\nx\r\n", out.items);
}

test "dead frames are moved out once they hold as much as the living, so the buffer stays bounded" {
    const io = testing.io;
    var q: Outbound = .initBuffering(testing.allocator, 1 << 20, 4 * frameCost("r", "x"));
    defer q.deinit();
    var tickets: [8]TestTicket = @splat(.{});
    // Requests that time out one after another while the server is down.
    for (0..8) |i| {
        try putRequestFrame(&q, io, tickets[i].of(i + 1), "r");
        q.forgetRequest(io, i + 1);
    }
    try testing.expectEqual(0, q.counts(io).queued);
    try testing.expectEqual(0, q.frames.len);
}

test "a PONG that comes before the writer marks its PING written still confirms what went before" {
    const io = testing.io;
    var q: Outbound = .initBuffering(testing.allocator, 1 << 20, 1 << 20);
    defer q.deinit();
    _ = try q.restore(io, @as([]const u8, ""), restoreSub, allWaiting, refuseNone, .{});
    try putPub(&q, io, .publish, "a", "1");
    const ping = try q.putPing(io, .flush);
    var slices: [4][]const u8 = undefined;
    const batch = (try q.take(io, &slices)).?;
    // The socket took the batch and the server answered; the reader got
    // the PONG before the writer called written().
    q.pongReceived(io);
    q.written(io, batch.len);
    try q.waitPong(io, ping, null);
    _ = q.halt(io);
    try testing.expectEqual(0, q.settle(io).uncertain);
}

test "close counts a publish written in part as dropped, with those not begun" {
    const io = testing.io;
    var q: Outbound = .init(testing.allocator, 1 << 20);
    defer q.deinit();
    try putPub(&q, io, .publish, "p", "1");
    try putPub(&q, io, .publish, "q", "2");
    var slices: [4][]const u8 = undefined;
    _ = (try q.take(io, &slices)).?;
    q.written(io, 5);
    q.close(io);
    const settled = q.discard(io);
    try testing.expectEqual(2, settled.dropped);
    try testing.expectEqual(0, settled.uncertain);
}

fn putRequestSized(q: *Outbound, io: Io, ticket: Ticket, payload: []const u8) PutUntilError!void {
    return q.putRequest(io, null, ticket, encoder.pubLen("r", null, payload.len), writePub, .{ "r", payload });
}

test "a restore or a compaction finds no memory: nothing waiting is lost, and nothing is allocated to compact" {
    const io = testing.io;
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var q: Outbound = .initBuffering(failing.allocator(), 1 << 20, 1 << 20);
    defer q.deinit();
    try putPub(&q, io, .publish, "p", "1");
    var ticket: TestTicket = .{};
    try putRequestSized(&q, io, ticket.of(7), &hundred);
    try putPub(&q, io, .publish, "p", "2");
    // From here on every allocation fails.
    failing.fail_index = failing.alloc_index;
    // The dead request holds more than the living: the frames are
    // compacted, with no allocation.
    q.forgetRequest(io, 7);
    var frames: [4]Frame = undefined;
    try testing.expectEqual(2, q.unsent(io, &frames).len);
    try testing.expectEqual(2 * frameCost("p", "1"), q.counts(io).queued);
    // A restore with no memory changes nothing; the connection is dropped.
    try testing.expectError(error.OutOfMemory, q.restore(io, @as([]const u8, "SUB a 1\r\n"), restoreSub, allWaiting, refuseNone, .{}));
    try testing.expectEqual(2, q.unsent(io, &frames).len);
    try testing.expectEqual(0, q.dropped_publishes);
    failing.fail_index = std.math.maxInt(usize);
    _ = try q.restore(io, @as([]const u8, "SUB a 1\r\n"), restoreSub, allWaiting, refuseNone, .{});
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try drainOnce(&q, io, &out);
    try testing.expectEqualStrings("SUB a 1\r\nPUB p 1\r\n1\r\nPUB p 1\r\n2\r\n", out.items);
}

test "the publishes a lost connection never began keep their room ahead of those made after the loss" {
    const io = testing.io;
    var q: Outbound = .initBuffering(testing.allocator, 1 << 20, 2 * frameCost("p", "1"));
    defer q.deinit();
    _ = try q.restore(io, @as([]const u8, ""), restoreSub, allWaiting, refuseNone, .{});
    try putPub(&q, io, .publish, "p", "1");
    try putPub(&q, io, .publish, "p", "2");
    _ = q.halt(io);
    // Made after the loss: the buffer is the unsent ones'.
    try testing.expectError(error.BufferFull, putPub(&q, io, .publish, "p", "3"));
    try testing.expectEqual(0, q.settle(io).dropped);
    _ = try q.restore(io, @as([]const u8, ""), restoreSub, allWaiting, refuseNone, .{});
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try drainOnce(&q, io, &out);
    try testing.expectEqualStrings("PUB p 1\r\n1\r\nPUB p 1\r\n2\r\n", out.items);
}

test "a publish waiting for room when the connection is lost finds the buffer taken by those before it" {
    const io = testing.io;
    const two = frameCost("first", "0123456789") + frameCost("secnd", "0123456789");
    var q: Outbound = .initBuffering(testing.allocator, two, two);
    defer q.deinit();
    _ = try q.restore(io, @as([]const u8, ""), restoreSub, allWaiting, refuseNone, .{});
    try putPub(&q, io, .publish, "first", "0123456789");
    try putPub(&q, io, .publish, "secnd", "0123456789");
    var putter = try io.concurrent(putLater, .{ &q, io });
    defer putter.cancel(io) catch {};
    try awaitRoomWaiter(&q, io);
    _ = q.halt(io);
    try testing.expectError(error.BufferFull, putter.await(io));
    try testing.expectEqual(0, q.settle(io).dropped);
    _ = try q.restore(io, @as([]const u8, ""), restoreSub, allWaiting, refuseNone, .{});
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try drainOnce(&q, io, &out);
    try testing.expectEqualStrings("PUB first 10\r\n0123456789\r\nPUB secnd 10\r\n0123456789\r\n", out.items);
}

fn writeHpubTest(w: *Writer, subject: []const u8, payload: []const u8) Writer.Error!void {
    return encoder.writeHpub(w, subject, null, &.{.{ .name = "X", .value = "1" }}, payload);
}

/// Notes the requests `restore` refused.
fn noteRefused(refused: *std.ArrayList(u64), id: u64) void {
    refused.append(testing.allocator, id) catch {};
}

fn buildFor(_: *std.ArrayList(u64), gpa: Allocator) Allocator.Error![]u8 {
    return gpa.alloc(u8, 0);
}

fn waitingFor(_: *std.ArrayList(u64), _: u64) bool {
    return true;
}

test "a restore drops what the new server would refuse: over its max_payload, or headers it has not" {
    const io = testing.io;
    var q: Outbound = .initBuffering(testing.allocator, 1 << 20, 1 << 20);
    defer q.deinit();
    try putPub(&q, io, .publish, "small", "12345");
    try putPub(&q, io, .publish, "big", &hundred);
    const header_block = encoder.headerBlockLen(&.{.{ .name = "X", .value = "1" }});
    try q.put(io, .publish, encoder.hpubLen("headers", null, header_block, 1), writeHpubTest, .{ "headers", "h" });
    var ticket: TestTicket = .{};
    try putRequestSized(&q, io, ticket.of(9), &hundred);
    var refused: std.ArrayList(u64) = .empty;
    defer refused.deinit(testing.allocator);
    const dropped = try q.restore(io, &refused, buildFor, waitingFor, noteRefused, .{ .max_payload = 50, .headers = false });
    try testing.expectEqual(2, dropped);
    try testing.expectEqual(2, q.dropped_publishes);
    try testing.expectEqualSlices(u64, &.{9}, refused.items);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try drainOnce(&q, io, &out);
    try testing.expectEqualStrings("PUB small 5\r\n12345\r\n", out.items);
}

fn requestWaitsBut(gone: []const u8, id: u64) bool {
    return std.mem.findScalar(u8, gone, @intCast(id)) == null;
}

test "while reconnecting, request frames whose request no longer waits give their room back when asked" {
    const io = testing.io;
    var q: Outbound = .initBuffering(testing.allocator, 1 << 20, frameCost("r", &hundred) + frameCost("p", "1"));
    defer q.deinit();
    var ticket: TestTicket = .{};
    try putRequestSized(&q, io, ticket.of(4), &hundred);
    try putPub(&q, io, .publish, "p", "1");
    try testing.expectError(error.BufferFull, putPub(&q, io, .publish, "p", "2"));
    // Request 4 still waits: nothing to give back.
    try testing.expect(!q.pruneRequests(io, @as([]const u8, &.{}), requestWaitsBut));
    try testing.expect(q.pruneRequests(io, @as([]const u8, &.{4}), requestWaitsBut));
    try putPub(&q, io, .publish, "p", "2");
}
