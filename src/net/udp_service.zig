//! Raw UDP servers (p3/net, design-net.md §2.6 and §4): datagram handlers
//! on Anole's runtime. One SO_REUSEPORT socket per executor on Linux (the
//! kernel's 4-tuple hash keeps a peer on one socket, so per-peer state needs
//! no lock), one elsewhere. Each socket has a reader task, which receives
//! in batches (`recvmmsg`) and runs the handler inline, like a `noWait`
//! route, and a sender task, which sends what other tasks queued. Replies
//! made inside a handler go out together after the batch, in one
//! `sendmmsg`.
const std = @import("std");
const builtin = @import("builtin");
const dusty = @import("dusty");
const safety = @import("anole_safety");
const low = @import("udp.zig");
const sessions_mod = @import("sessions.zig");
const handoff = @import("../handoff.zig");
const net_metrics = @import("metrics.zig");

const placement = dusty.placement;
const push_list = dusty.push_list;
const Duration = std.Io.Duration;
const native_os = builtin.os.tag;
const log = std.log.scoped(.anole);
const cmsg_align = std.Io.net.cmsg_align;

/// Options of a UDP listener.
pub const Udp = struct {
    pub const Options = struct {
        /// Linux: SO_REUSEPORT sockets bound in order, each served on an
        /// executor of its own; a peer's datagrams always reach the same one
        /// (the kernel hashes source and destination). Null: one per
        /// executor, at most 255. Elsewhere one.
        sockets: ?u16 = null,
        /// The largest datagram taken (up to 65507); a larger one is dropped
        /// and counted (`truncated`).
        max_datagram: u16 = 2048,
        /// Datagrams per receive call (recvmmsg on Linux), 1 to 64.
        batch: u8 = 32,
        /// Bytes waiting to go out per socket; past it `send` / `reply`
        /// take nothing (`error.QueueFull`).
        send_queue: u32 = 1 << 20,
        /// SO_RCVBUF / SO_SNDBUF; null: the system's.
        receive_buffer: ?u32 = null,
        send_buffer: ?u32 = null,
        /// Per-peer sessions (the handler's callbacks take a `*Session`).
        sessions: ?Sessions = null,

        pub fn check(o: Options) error{InvalidFraming}!void {
            if (o.batch == 0 or o.batch > 64 or o.max_datagram == 0 or o.max_datagram > 65507) return error.InvalidFraming;
            if (o.sockets) |n| if (n == 0 or n > 255) return error.InvalidFraming;
        }
    };

    pub const Sessions = struct {
        /// No datagram from the peer for this long ends the session.
        idle_timeout: Duration = .fromSeconds(30),
        /// Sessions per socket at most; a new peer past it is not served
        /// (its datagram dropped, counted `sessions_refused`).
        max: u32 = 65_536,
    };
};

pub const UdpTable = struct {
    datagram: ?*const fn (state: ?*anyopaque, *Datagram) anyerror!void = null,
    /// Batches, for the C ABI: called once per receive batch instead of
    /// `datagram` when set. `dropped` is the datagrams lost on this socket
    /// since the last call.
    batch: ?*const fn (state: ?*anyopaque, *UdpSocket, []Datagram, dropped: u32) anyerror!void = null,
    /// The send queue drained under a quarter after a refused or busy send.
    writable: ?*const fn (state: ?*anyopaque, *UdpSocket) void = null,
    session_open: ?*const fn (state: ?*anyopaque, *Session) anyerror!void = null,
    session_datagram: ?*const fn (state: ?*anyopaque, *Session, *Datagram) anyerror!void = null,
    session_close: ?*const fn (state: ?*anyopaque, *Session) void = null,
    state_size: u32 = 0,
    state_align: u8 = 1,
    state_init: ?*const fn (*anyopaque) void = null,
    state_deinit: ?*const fn (*anyopaque) void = null,
};

pub const UdpService = struct {
    table: *const UdpTable,
    options: Udp.Options,
    ctx_type: []const u8,
    state: ?*anyopaque = null,
};

/// A UDP service for `Listener.udp`. `handler` has `datagram(d)` (or, with
/// `options.sessions`, `datagram(session, d)` and optionally `open(session)`
/// and `close(session)`, with a `State` per session), each with the
/// server's `*Ctx` first when it has one. Handlers run inline on the
/// socket's task, like a `noWait` route: they must not wait (use
/// `d.socket.go`).
pub fn udp(comptime Ctx: type, comptime handler: type, comptime options: Udp.Options) UdpService {
    comptime {
        options.check() catch @compileError("anole.net.udp: the options are not valid: batch 1 to 64, max_datagram 1 to 65507, sockets 1 to 255");
    }
    const H = Hooks(Ctx, handler, options.sessions != null);
    return .{ .table = &H.table, .options = options, .ctx_type = @typeName(Ctx) };
}

fn Hooks(comptime Ctx: type, comptime Handler: type, comptime with_sessions: bool) type {
    return struct {
        const table: UdpTable = build();

        fn build() UdpTable {
            if (!@hasDecl(Handler, "datagram")) @compileError("anole.net.udp: " ++ @typeName(Handler) ++ " has no datagram(...)");
            var t: UdpTable = .{};
            if (with_sessions) {
                t.session_datagram = sessionDatagram;
                if (@hasDecl(Handler, "open")) t.session_open = sessionOpen;
                if (@hasDecl(Handler, "close")) t.session_close = sessionClose;
                if (@hasDecl(Handler, "State")) {
                    t.state_size = @sizeOf(Handler.State);
                    t.state_align = @alignOf(Handler.State);
                    t.state_init = stateInit;
                    if (@hasDecl(Handler.State, "deinit")) t.state_deinit = stateDeinit;
                }
            } else {
                t.datagram = datagram;
            }
            return t;
        }

        fn arity(comptime f: anytype, comptime plain: usize, comptime name: []const u8) bool {
            const n = @typeInfo(@TypeOf(f)).@"fn".param_types.len;
            if (n == plain) return false;
            if (n == plain + 1 and Ctx != void) return true;
            @compileError("anole.net UDP callback " ++ name ++ " has the wrong parameters: " ++ @typeName(@TypeOf(f)));
        }

        fn ctxOf(state: ?*anyopaque) *Ctx {
            return @ptrCast(@alignCast(state.?));
        }

        fn datagram(state: ?*anyopaque, d: *Datagram) anyerror!void {
            const f = Handler.datagram;
            return if (comptime arity(f, 1, "datagram")) f(ctxOf(state), d) else f(d);
        }

        fn sessionDatagram(state: ?*anyopaque, s: *Session, d: *Datagram) anyerror!void {
            const f = Handler.datagram;
            return if (comptime arity(f, 2, "datagram")) f(ctxOf(state), s, d) else f(s, d);
        }

        fn sessionOpen(state: ?*anyopaque, s: *Session) anyerror!void {
            const f = Handler.open;
            return if (comptime arity(f, 1, "open")) f(ctxOf(state), s) else f(s);
        }

        fn sessionClose(state: ?*anyopaque, s: *Session) void {
            const f = Handler.close;
            return if (comptime arity(f, 1, "close")) f(ctxOf(state), s) else f(s);
        }

        fn stateInit(p: *anyopaque) void {
            const s: *Handler.State = @ptrCast(@alignCast(p));
            s.* = .{};
        }

        fn stateDeinit(p: *anyopaque) void {
            const s: *Handler.State = @ptrCast(@alignCast(p));
            s.deinit();
        }
    };
}

/// One datagram, valid during the handler call.
pub const Datagram = struct {
    data: []u8,
    /// IPv4 peers of a dual-stack socket come as plain IPv4.
    remote: std.Io.net.IpAddress,
    /// The address it was sent to (a wildcard-bound socket); replies leave from it.
    local: ?std.Io.net.IpAddress,
    socket: *UdpSocket,

    /// TooLarge: a datagram over 65507 bytes, or datagrams together over
    /// `send_queue`: never taken, so no WRITABLE follows for them.
    /// QueueFull: no room now; WRITABLE follows.
    pub const SendError = error{ TooLarge, QueueFull, Closed, OutOfMemory };

    /// A datagram back to `remote` from `local`, sent with the rest of the
    /// batch's replies (one sendmmsg). Copied.
    pub fn reply(d: *Datagram, bytes: []const u8) SendError!void {
        return d.socket.replyTo(d.remote, d.local, bytes);
    }
};

/// How a session ended.
const SessionEnd = enum { idle, local, stop };

/// A peer's session (`Udp.Options.sessions`).
pub const Session = struct {
    pub const EndReason = SessionEnd;

    context: ?*anyopaque = null,
    socket_: *UdpSocket,
    remote_: std.Io.net.IpAddress,
    last_local: ?std.Io.net.IpAddress = null,
    end_reason: SessionEnd = .idle,
    close_requested: bool = false,
    state_buf: []align(16) u8 = &.{},

    pub fn contextAs(s: *const Session, comptime T: type) *T {
        return @ptrCast(@alignCast(s.context.?));
    }

    pub fn remote(s: *const Session) std.Io.net.IpAddress {
        return s.remote_;
    }

    pub fn socket(s: *Session) *UdpSocket {
        return s.socket_;
    }

    /// To the peer (from the address it last wrote to): queued, never waits.
    pub fn send(s: *Session, bytes: []const u8) Datagram.SendError!void {
        return s.socket_.send(s.remote_, s.last_local, bytes);
    }

    /// Ends it after this callback (`close` runs).
    pub fn close(s: *Session) void {
        s.close_requested = true;
    }

    pub fn endReason(s: *const Session) SessionEnd {
        return s.end_reason;
    }
};

/// Counters over one UDP socket.
pub const SocketStats = struct {
    datagrams_in: std.atomic.Value(u64) = .init(0),
    datagrams_out: std.atomic.Value(u64) = .init(0),
    dropped_kernel: std.atomic.Value(u64) = .init(0),
    dropped_truncated: std.atomic.Value(u64) = .init(0),
    dropped_queue_full: std.atomic.Value(u64) = .init(0),
    dropped_send_failed: std.atomic.Value(u64) = .init(0),
    dropped_sessions_full: std.atomic.Value(u64) = .init(0),
    sessions: std.atomic.Value(u64) = .init(0),
    batches: std.atomic.Value(u64) = .init(0),
    send_flushes: std.atomic.Value(u64) = .init(0),
};

const Pending = struct { to: std.Io.net.IpAddress, from: ?std.Io.net.IpAddress, off: usize, len: usize };

/// One `send`/`sendMany` call: its datagrams' addresses and bytes in one
/// allocation (this header, the `Pending` entries, then the bytes), made
/// before anything shared is touched (L5). owner: the caller until it is
/// pushed; then the socket's sender, which frees it once sent.
const Batch = struct {
    node: push_list.Node = .{},
    gpa: std.mem.Allocator,
    count: u32,
    /// Datagram bytes in all.
    bytes: u32,
    size: usize,

    const header = std.mem.alignForward(usize, @sizeOf(Batch), @alignOf(Pending));
    comptime {
        std.debug.assert(@alignOf(Batch) >= @alignOf(Pending));
    }

    fn create(gpa: std.mem.Allocator, s: *const UdpSocket, items: []const UdpSocket.Outgoing) error{OutOfMemory}!*Batch {
        var total: usize = 0;
        for (items) |it| total += it.bytes.len;
        const size = header + items.len * @sizeOf(Pending) + total;
        const mem = try gpa.alignedAlloc(u8, .of(Batch), size);
        // SAFETY: `mem` is aligned for a Batch and starts with `header` bytes for one.
        const b: *Batch = @ptrCast(mem.ptr);
        b.* = .{ .gpa = gpa, .count = @intCast(items.len), .bytes = @intCast(total), .size = size };
        const slots = b.entries();
        const data = b.payload();
        var off: usize = 0;
        for (items, slots) |it, *p| {
            @memcpy(data[off..][0..it.bytes.len], it.bytes);
            p.* = .{ .to = s.onWire(it.to), .from = if (it.from) |f| s.onWire(f) else null, .off = off, .len = it.bytes.len };
            off += it.bytes.len;
        }
        return b;
    }

    fn base(b: *Batch) [*]align(@alignOf(Batch)) u8 {
        // SAFETY: a Batch heads the allocation `create` made.
        return @ptrCast(b);
    }

    fn entries(b: *Batch) []Pending {
        // SAFETY: `create` placed `count` entries at `header`, aligned for them (`header` is aligned forward to `Pending`).
        const at: [*]Pending = @ptrCast(@alignCast(b.base() + header));
        return at[0..b.count];
    }

    fn payload(b: *Batch) []u8 {
        return (b.base() + header + @as(usize, b.count) * @sizeOf(Pending))[0..b.bytes];
    }

    fn destroy(b: *Batch) void {
        b.gpa.free(b.base()[0..b.size]);
    }

    fn of(n: *push_list.Node) *Batch {
        return @fieldParentPtr("node", n);
    }
};
const SessionNode = sessions_mod.SessionTable(Session);

/// One socket of a UDP listener.
pub const UdpSocket = struct {
    group: *UdpGroup,
    udp: low.Udp,
    index: u8,
    /// The executor its tasks run on.
    exec: usize,
    stats: SocketStats = .{},

    // Reader task only.
    rx: []u8,
    msgs: []std.Io.net.IncomingMessage,
    controls: []align(cmsg_align) low.Udp.Control,
    dgrams: []Datagram,
    outbox: ?low.Udp.Outbox = null,
    replying: bool = false,
    last_dropped: ?u32 = null,
    table: ?SessionNode = null,

    /// The executor its tasks run on (T3): `go` and the sender check it.
    owner: safety.Owner = .none,
    // Sends from any task or thread: no lock.
    /// Batches to send; owner: the sender, which seals it when it ends.
    pending: push_list.PushList = .{},
    /// Bytes in `pending` and in the batch being sent: reserved with a
    /// compare-and-swap bounded by `send_queue`.
    queue_bytes: std.atomic.Value(u64) = .init(0),
    want_writable: std.atomic.Value(bool) = .init(false),
    signal: placement.Signal = .{},
    /// `go`'s tasks: children of the socket, on its executor (T1).
    tasks: std.Io.Group = .init,
    // Sender task only.
    send_box: ?low.Udp.Outbox = null,
    closed: std.atomic.Value(bool) = .init(false),

    pub fn listener(s: *const UdpSocket) []const u8 {
        return s.group.name;
    }

    pub fn index_(s: *const UdpSocket) u8 {
        return s.index;
    }

    pub fn address(s: *const UdpSocket) std.Io.net.IpAddress {
        return s.udp.socket.address;
    }

    pub fn handlerState(s: *const UdpSocket) ?*anyopaque {
        return s.group.service.state;
    }

    /// `ip` as the socket sends to it: an IPv4 peer of a dual-stack socket
    /// is addressed in IPv4-mapped form (the handlers see plain IPv4).
    fn onWire(s: *const UdpSocket, ip: std.Io.net.IpAddress) std.Io.net.IpAddress {
        if (!s.udp.ip6) return ip;
        switch (ip) {
            .ip6 => return ip,
            .ip4 => |a| {
                var bytes: [16]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 0, 0, 0, 0 };
                @memcpy(bytes[12..16], &a.bytes);
                return .{ .ip6 = .{ .bytes = bytes, .port = a.port } };
            },
        }
    }

    /// A drop, counted here and in the Prometheus series.
    /// Seals the send queue and drops what is in it, counted (`send_failed`).
    /// Nothing for a socket whose sender ended (it sealed its own queue).
    fn dropUnsent(s: *UdpSocket) void {
        var it = s.pending.seal();
        while (it) |n| {
            it = n.next;
            const b = Batch.of(n);
            _ = s.queue_bytes.fetchSub(b.bytes, .monotonic);
            s.countDrop(.send_failed, b.count);
            b.destroy();
        }
    }

    fn countDrop(s: *UdpSocket, why: net_metrics.DropReason, n: u64) void {
        const field = switch (why) {
            .kernel => &s.stats.dropped_kernel,
            .truncated => &s.stats.dropped_truncated,
            .queue_full => &s.stats.dropped_queue_full,
            .send_failed => &s.stats.dropped_send_failed,
            .sessions_full => &s.stats.dropped_sessions_full,
        };
        _ = field.fetchAdd(n, .monotonic);
        if (s.group.series) |m| m.drop(why, n);
    }

    /// A datagram to `to` (from `from` when given): any task or thread;
    /// queued and sent by the socket's sender, never waits. A send that
    /// races the stop answers `error.Closed`: it is never taken and lost.
    pub fn send(s: *UdpSocket, to: std.Io.net.IpAddress, from: ?std.Io.net.IpAddress, bytes: []const u8) Datagram.SendError!void {
        if (bytes.len > 65507) return error.TooLarge;
        if (s.closed.load(.acquire)) return error.Closed;
        return s.enqueue(&.{.{ .to = to, .from = from, .bytes = bytes }});
    }

    /// Whether the queue is past half full (the ABI's BUSY).
    pub fn queueBusy(s: *UdpSocket) bool {
        return s.queue_bytes.load(.acquire) > s.group.service.options.send_queue / 2;
    }

    /// Queues many datagrams, all or none (the ABI's `anole_net_udp_send`),
    /// copied into one batch.
    pub fn sendMany(s: *UdpSocket, items: []const Outgoing) Datagram.SendError!void {
        if (s.closed.load(.acquire)) return error.Closed;
        for (items) |it| if (it.bytes.len > 65507) return error.TooLarge;
        return s.enqueue(items);
    }

    /// The batch is made first (the only allocation), then its bytes are
    /// reserved, then it is pushed; the sender is woken when the list was
    /// empty, through the group's gate (T5).
    fn enqueue(s: *UdpSocket, items: []const Outgoing) Datagram.SendError!void {
        const cap = s.group.service.options.send_queue;
        var total: u64 = 0;
        for (items) |it| total += it.bytes.len;
        // More than the queue holds empty: never taken (not QueueFull,
        // which promises a WRITABLE).
        if (total > cap) return error.TooLarge;
        const b = try Batch.create(s.group.gpa, s, items);
        const n: u64 = b.bytes;
        var q = s.queue_bytes.load(.monotonic);
        while (true) {
            if (q + n > cap) {
                testHold(&test_full_hold);
                // Asks for WRITABLE, then looks again (the store-buffering
                // pair with `finishWork`'s subtraction then flag load, all
                // `.seq_cst`): a batch that left after the look above read
                // the flag unset, so the send is tried again. Still full:
                // what is queued now leaves later, and that `finishWork`
                // sees the flag. (A retry that fits leaves the flag set:
                // one WRITABLE too many, which the contract allows.)
                s.want_writable.store(true, .seq_cst);
                const again = s.queue_bytes.load(.seq_cst);
                if (again + n <= cap) {
                    q = again;
                    continue;
                }
                b.destroy();
                s.countDrop(.queue_full, items.len);
                return error.QueueFull;
            }
            q = s.queue_bytes.cmpxchgWeak(q, q + n, .acq_rel, .monotonic) orelse break;
        }
        if (q + n > cap / 2) s.want_writable.store(true, .release);
        testHold(&test_send_hold);
        // Sealed: the sender has ended (the stop).
        const was_empty = s.pending.push(&b.node) catch {
            _ = s.queue_bytes.fetchSub(n, .acq_rel);
            b.destroy();
            return error.Closed;
        };
        if (was_empty) s.group.wake(s);
    }

    pub const Outgoing = struct { to: std.Io.net.IpAddress, from: ?std.Io.net.IpAddress, bytes: []const u8 };

    /// Runs `func(args...)` on a task on this socket's executor (work a
    /// datagram handler must not wait for). From a handler (the socket's
    /// executor). Canceled at the stop.
    pub fn go(s: *UdpSocket, comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) error{ OutOfMemory, Closed }!void {
        if (s.closed.load(.acquire)) return error.Closed;
        s.owner.check(s.group.io);
        placement.concurrent(&s.tasks, s.group.io, .local, func, args) catch return error.OutOfMemory;
    }

    // -- Replies made inside a handler ---------------------------------------

    fn replyTo(s: *UdpSocket, to: std.Io.net.IpAddress, from: ?std.Io.net.IpAddress, bytes: []const u8) Datagram.SendError!void {
        if (!s.replying) return s.send(to, from, bytes);
        if (bytes.len > 65507 or bytes.len > low.Udp.Outbox.buf_len) return error.TooLarge;
        if (s.outbox == null) s.outbox = low.Udp.Outbox.init(s.group.gpa) catch return error.OutOfMemory;
        var box = &s.outbox.?;
        if (!box.fits(bytes.len, 1)) {
            s.flushOutbox();
            box = &s.outbox.?;
        }
        @memcpy(box.space()[0..bytes.len], bytes);
        box.commit(&s.udp, s.onWire(to), if (from) |f| s.onWire(f) else null, 0, bytes.len, 0);
    }

    fn flushOutbox(s: *UdpSocket) void {
        const box = &(s.outbox orelse return);
        if (box.count == 0) return;
        const n = box.datagrams;
        s.udp.sendOutbox(s.group.io, box);
        _ = s.stats.datagrams_out.fetchAdd(n, .monotonic);
        if (s.group.series) |m| m.sent.add(n);
        _ = s.stats.send_flushes.fetchAdd(1, .monotonic);
    }

    // -- The reader --------------------------------------------------------------

    fn nowNs(s: *const UdpSocket) i96 {
        return std.Io.Clock.Timestamp.now(s.group.io, .awake).raw.nanoseconds;
    }

    fn reader(s: *UdpSocket) std.Io.Cancelable!void {
        const g = s.group;
        const io = g.io;
        // The reader and the sender run on this socket's executor.
        s.owner = .here(io);
        const o = &g.service.options;
        const table = g.service.table;
        defer {
            s.closeAllSessions(.stop);
            s.flushOutbox();
        }
        while (true) {
            var timeout: std.Io.Timeout = .none;
            if (s.table) |*t| if (t.nextExpiry()) |at| {
                timeout = .{ .deadline = .{ .raw = .{ .nanoseconds = at }, .clock = .awake } };
            };
            const n = s.udp.receiveInto(io, s.msgs[0..o.batch], s.controls[0..o.batch], s.rx, timeout) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.Timeout => {
                    s.expireSessions();
                    continue;
                },
                else => {
                    log.debug("udp {s}: receive: {t}", .{ g.name, err });
                    try io.sleep(.fromMilliseconds(1), .awake);
                    continue;
                },
            };
            _ = s.stats.batches.fetchAdd(1, .monotonic);
            s.dispatch(n, table);
            if (s.table != null) s.expireSessions();
        }
    }

    fn dispatch(s: *UdpSocket, n: usize, table: *const UdpTable) void {
        const o = &s.group.service.options;
        var count: usize = 0;
        var dropped: u32 = 0;
        for (s.msgs[0..n]) |*m| {
            const d0 = s.udp.datagramFrom(m);
            if (d0.dropped != 0 or s.last_dropped != null) {
                if (s.last_dropped) |last| {
                    if (d0.dropped != last) {
                        const delta = d0.dropped -% last;
                        dropped +%= delta;
                        s.countDrop(.kernel, delta);
                    }
                }
                s.last_dropped = d0.dropped;
            }
            if (m.flags.trunc or d0.data.len > o.max_datagram) {
                s.countDrop(.truncated, 1);
                continue;
            }
            s.dgrams[count] = .{
                .data = d0.data,
                .remote = dusty.unmapIpv4(d0.from),
                .local = if (d0.local) |l| dusty.unmapIpv4(l) else null,
                .socket = s,
            };
            count += 1;
        }
        _ = s.stats.datagrams_in.fetchAdd(count, .monotonic);
        if (s.group.series) |m| m.received.add(count);
        s.replying = true;
        defer {
            s.replying = false;
            s.flushOutbox();
        }
        if (table.batch) |f| {
            f(s.group.service.state, s, s.dgrams[0..count], dropped) catch |err| {
                if (err != error.Canceled) log.debug("udp {s}: batch handler failed: {t}", .{ s.group.name, err });
            };
            return;
        }
        for (s.dgrams[0..count]) |*d| {
            if (s.table != null) {
                s.sessionDatagram(table, d);
            } else if (table.datagram) |f| {
                f(s.group.service.state, d) catch |err| {
                    if (err != error.Canceled) log.debug("udp {s}: handler failed: {t}", .{ s.group.name, err });
                };
            }
        }
    }

    // -- Sessions ------------------------------------------------------------------

    fn sessionDatagram(s: *UdpSocket, table: *const UdpTable, d: *Datagram) void {
        const t = &s.table.?;
        const key = sessions_mod.PeerKey.of(d.remote);
        const now = s.nowNs();
        const hstate = s.group.service.state;
        const node = t.get(key) orelse blk: {
            const node = t.open(key, now, .{ .socket_ = s, .remote_ = d.remote }) catch |err| {
                if (err == error.Full) s.countDrop(.sessions_full, 1);
                return;
            };
            const sess = &node.value;
            if (table.state_size > 0) {
                std.debug.assert(table.state_align <= 16);
                sess.state_buf = s.group.gpa.alignedAlloc(u8, .@"16", table.state_size) catch {
                    t.remove(node);
                    return;
                };
                table.state_init.?(sess.state_buf.ptr);
                sess.context = sess.state_buf.ptr;
            }
            _ = s.stats.sessions.fetchAdd(1, .monotonic);
            if (s.group.series) |m| m.sessions.add(1);
            if (table.session_open) |f| f(hstate, sess) catch |err| {
                log.debug("udp {s}: session open failed: {t}", .{ s.group.name, err });
                s.endSession(node, .local);
                return;
            };
            break :blk node;
        };
        t.touch(node, now);
        const sess = &node.value;
        sess.last_local = d.local;
        const f = table.session_datagram.?;
        f(hstate, sess, d) catch |err| {
            log.debug("udp {s}: session handler failed: {t}", .{ s.group.name, err });
            s.endSession(node, .local);
            return;
        };
        if (sess.close_requested) s.endSession(node, .local);
    }

    /// Runs `close`, frees the session's state and takes it out.
    fn endSession(s: *UdpSocket, node: *SessionNode.Node, reason: SessionEnd) void {
        const table = s.group.service.table;
        const sess = &node.value;
        sess.end_reason = reason;
        if (table.session_close) |f| f(s.group.service.state, sess);
        s.freeSession(sess);
        s.table.?.remove(node);
    }

    fn freeSession(s: *UdpSocket, sess: *Session) void {
        const table = s.group.service.table;
        if (sess.state_buf.len > 0) {
            if (table.state_deinit) |f| f(sess.state_buf.ptr);
            s.group.gpa.free(sess.state_buf);
            sess.state_buf = &.{};
        }
        _ = s.stats.sessions.fetchSub(1, .monotonic);
        if (s.group.series) |m| m.sessions.add(-1);
    }

    fn expireSessions(s: *UdpSocket) void {
        const t = &(s.table orelse return);
        const table = s.group.service.table;
        const now = s.nowNs();
        while (t.popExpired(now)) |node| {
            node.value.end_reason = .idle;
            if (table.session_close) |f| f(s.group.service.state, &node.value);
            s.freeSession(&node.value);
            t.destroy(node);
        }
    }

    fn closeAllSessions(s: *UdpSocket, reason: SessionEnd) void {
        const t = &(s.table orelse return);
        const table = s.group.service.table;
        while (t.popOldest()) |node| {
            node.value.end_reason = reason;
            if (table.session_close) |f| f(s.group.service.state, &node.value);
            s.freeSession(&node.value);
            t.destroy(node);
        }
    }

    // -- The sender ------------------------------------------------------------------

    fn sender(s: *UdpSocket) std.Io.Cancelable!void {
        const io = s.group.io;
        s.owner = .here(io);
        defer {
            // Sealed first, so a later send gets Closed; what got in goes
            // out before the socket does.
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            s.sendBatches(s.pending.seal());
        }
        while (true) {
            try s.signal.wait(io);
            s.signal.reset(io);
            s.drainQueue();
        }
    }

    fn drainQueue(s: *UdpSocket) void {
        s.owner.check(s.group.io);
        s.sendBatches(s.pending.takeAll());
    }

    /// Sends the batches of `first` (oldest first) and frees them.
    fn sendBatches(s: *UdpSocket, first: ?*push_list.Node) void {
        if (first == null) return;
        const gpa = s.group.gpa;
        var bytes: u64 = 0;
        var it = first;
        if (s.send_box == null) s.send_box = low.Udp.Outbox.init(gpa) catch null;
        while (it) |node| {
            it = node.next;
            const b = Batch.of(node);
            bytes += b.bytes;
            if (s.send_box) |*box| {
                const dgram_bytes = b.payload();
                for (b.entries()) |p| {
                    if (!box.fits(p.len, 1)) s.sendBox(box);
                    @memcpy(box.space()[0..p.len], dgram_bytes[p.off..][0..p.len]);
                    box.commit(&s.udp, p.to, p.from, 0, p.len, 0);
                }
            } else {
                // No memory for a box: the datagrams are dropped, counted.
                s.countDrop(.send_failed, b.count);
            }
            b.destroy();
        }
        if (s.send_box) |*box| s.sendBox(box);
        s.finishWork(bytes);
    }

    fn sendBox(s: *UdpSocket, box: *low.Udp.Outbox) void {
        const n = box.datagrams;
        if (n == 0) return;
        s.udp.sendOutbox(s.group.io, box);
        _ = s.stats.datagrams_out.fetchAdd(n, .monotonic);
        if (s.group.series) |m| m.sent.add(n);
        _ = s.stats.send_flushes.fetchAdd(1, .monotonic);
    }

    /// The batches are out: their bytes leave the queue's account, and a
    /// sender that was told to wait hears it may go on (on this task).
    fn finishWork(s: *UdpSocket, bytes: u64) void {
        const cap = s.group.service.options.send_queue;
        // `.seq_cst` subtraction, then flag load: see `enqueue`.
        const was = s.queue_bytes.fetchSub(bytes, .seq_cst);
        if (was - bytes < cap / 4 and s.want_writable.load(.seq_cst) and s.want_writable.swap(false, .acq_rel)) {
            if (s.group.service.table.writable) |f| f(s.group.service.state, s);
        }
    }
};

/// Test hooks (test builds only): the next `send` stops at a point and
/// holds there (`held` set) until the test sets `release`. Taken once.
/// `test_send_hold`: after the reservation, where a stop can race it;
/// `test_full_hold`: a send found the queue full and has not yet asked for
/// WRITABLE.
pub const TestHold = struct {
    held: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
};
pub var test_send_hold: if (builtin.is_test) std.atomic.Value(?*TestHold) else void = if (builtin.is_test) .init(null) else {};
pub var test_full_hold: if (builtin.is_test) std.atomic.Value(?*TestHold) else void = if (builtin.is_test) .init(null) else {};

fn testHold(which: anytype) void {
    if (comptime !builtin.is_test) return;
    const h = which.swap(null, .acq_rel) orelse return;
    h.held.store(true, .release);
    while (!h.release.load(.acquire)) std.Thread.yield() catch {};
}

/// One UDP listener: its sockets and their tasks.
pub const UdpGroup = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    service: UdpService,
    name: []const u8,
    sockets: []UdpSocket,
    readers: std.Io.Group = .init,
    senders: std.Io.Group = .init,
    /// Every wake of a sender from off its executor goes through it (T5);
    /// closed at the end of `run`, once the senders have ended.
    gate: safety.IoGate = .{},
    handed_over: std.atomic.Value(bool) = .init(false),
    /// The Prometheus series, set before serving when the app has metrics.
    series: ?*net_metrics.UdpSeries = null,

    pub const BindOptions = struct {
        address: std.Io.net.IpAddress,
        ipv6_only: ?bool = null,
        /// Sockets handed over (hand-off or socket activation): used
        /// instead of binding.
        fds: []const std.posix.fd_t = &.{},
        executors: usize = 1,
    };

    /// Binds (or adopts) the listener's sockets. `name` outlives the group.
    pub fn create(gpa: std.mem.Allocator, io: std.Io, service: UdpService, name: []const u8, bind: BindOptions) !*UdpGroup {
        const o = service.options;
        const inherited = bind.fds;
        const executors = @max(1, bind.executors);
        const count: usize = if (inherited.len > 0)
            inherited.len
        else if (native_os == .linux)
            (o.sockets orelse @as(u16, @intCast(@min(executors, 255))))
        else
            1;
        if (count == 0 or count > 255) return error.InvalidFraming;
        const g = try gpa.create(UdpGroup);
        errdefer gpa.destroy(g);
        g.* = .{ .gpa = gpa, .io = io, .service = service, .name = name, .sockets = try gpa.alloc(UdpSocket, count) };
        errdefer gpa.free(g.sockets);
        if (inherited.len == 0 and count > 1) try low.checkUdpAddressFree(bind.address, bind.ipv6_only);
        const ipv6_only: ?bool = if (bind.address == .ip6) bind.ipv6_only else null;
        var made: usize = 0;
        errdefer for (g.sockets[0..made]) |*s| g.deinitSocket(s);
        var bind_to = bind.address;
        for (0..count) |i| {
            const socket = if (inherited.len > 0)
                try adoptSocket(io, inherited[i], bind.address)
            else if (count == 1)
                try bind_to.bind(io, .{ .mode = .dgram, .protocol = .udp, .ip6_only = ipv6_only })
            else
                try bindMember(io, bind_to, ipv6_only);
            errdefer socket.close(io);
            try g.initSocket(&g.sockets[i], socket, @intCast(i), i % executors);
            made += 1;
            // The port the first got, when 0 was asked for.
            bind_to = socket.address;
        }
        return g;
    }

    fn bindMember(io: std.Io, at: std.Io.net.IpAddress, ipv6_only: ?bool) !std.Io.net.Socket {
        if (comptime native_os == .windows) unreachable;
        const handle = try low.bindReusePort(at, ipv6_only);
        return adoptSocket(io, handle, at) catch |err| {
            _ = std.c.close(handle);
            return err;
        };
    }

    /// Wraps a UDP socket this process did not open (or just made). Under
    /// zio, which drives its sockets non-blocking, it is made so too.
    fn adoptSocket(io: std.Io, handle: std.posix.fd_t, configured: std.Io.net.IpAddress) !std.Io.net.Socket {
        if (comptime native_os == .windows) return error.InheritedSocketUnsupported;
        const sc = std.c;
        var kind: c_int = 0;
        var kind_len: std.posix.socklen_t = @sizeOf(c_int);
        if (sc.getsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.TYPE, @ptrCast(&kind), &kind_len) != 0 or
            kind != std.posix.SOCK.DGRAM) return error.InheritedSocketNotDatagram;
        if (placement.executorCount(io) != null) {
            const flags = sc.fcntl(handle, sc.F.GETFL, @as(c_int, 0));
            if (flags < 0) return error.InvalidInheritedSocket;
            _ = sc.fcntl(handle, sc.F.SETFL, flags | @as(c_int, 1 << @bitOffsetOf(std.posix.O, "NONBLOCK")));
        }
        var storage: std.Io.Threaded.PosixAddress = undefined;
        var len: std.posix.socklen_t = @sizeOf(std.Io.Threaded.PosixAddress);
        const bound: std.Io.net.IpAddress = if (sc.getsockname(handle, &storage.any, &len) == 0 and
            (storage.any.family == std.posix.AF.INET or storage.any.family == std.posix.AF.INET6))
            std.Io.Threaded.addressFromPosix(&storage)
        else
            configured;
        return .{ .handle = handle, .address = bound };
    }

    fn initSocket(g: *UdpGroup, s: *UdpSocket, socket: std.Io.net.Socket, index: u8, exec: usize) !void {
        const o = g.service.options;
        const gpa = g.gpa;
        var udp_sock: low.Udp = .init(socket, .{ .ecn = false, .gro = false, .gso = false, .pmtu_probe = false, .rxq_ovfl = native_os == .linux });
        if (native_os != .windows) {
            if (o.receive_buffer) |n| {
                const v: c_int = @intCast(@min(n, std.math.maxInt(c_int)));
                _ = std.c.setsockopt(socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, &v, @sizeOf(c_int));
            }
            if (o.send_buffer) |n| {
                const v: c_int = @intCast(@min(n, std.math.maxInt(c_int)));
                _ = std.c.setsockopt(socket.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, &v, @sizeOf(c_int));
            }
        }
        udp_sock.gso.store(false, .monotonic);
        const batch: usize = o.batch;
        const rx = try gpa.alloc(u8, batch * (@as(usize, o.max_datagram) + 1));
        errdefer gpa.free(rx);
        const msgs = try gpa.alloc(std.Io.net.IncomingMessage, batch);
        errdefer gpa.free(msgs);
        const controls = try gpa.alignedAlloc(low.Udp.Control, .fromByteUnits(cmsg_align), batch);
        errdefer gpa.free(controls);
        const dgrams = try gpa.alloc(Datagram, batch);
        errdefer gpa.free(dgrams);
        s.* = .{
            .group = g,
            .udp = udp_sock,
            .index = index,
            .exec = exec,
            .rx = rx,
            .msgs = msgs,
            .controls = controls,
            .dgrams = dgrams,
        };
        if (o.sessions) |se| {
            s.table = SessionNode.init(gpa, @intCast(se.idle_timeout.nanoseconds), se.max);
        }
    }

    fn deinitSocket(g: *UdpGroup, s: *UdpSocket) void {
        const gpa = g.gpa;
        s.udp.socket.close(g.io);
        if (s.table) |*t| t.deinit();
        if (s.outbox) |*b| b.deinit(gpa);
        if (s.send_box) |*b| b.deinit(gpa);
        // Never served (or a send after the stop): what is still queued.
        var it = s.pending.seal();
        while (it) |n| {
            it = n.next;
            Batch.of(n).destroy();
        }
        gpa.free(s.rx);
        gpa.free(s.msgs);
        gpa.free(s.controls);
        gpa.free(s.dgrams);
    }

    pub fn destroy(g: *UdpGroup) void {
        for (g.sockets) |*s| g.deinitSocket(s);
        g.gpa.free(g.sockets);
        g.gpa.destroy(g);
    }

    /// The bound address (the real port when 0 was asked for).
    pub fn address(g: *const UdpGroup) std.Io.net.IpAddress {
        return g.sockets[0].udp.socket.address;
    }

    /// The file descriptors, in socket order (hand-off holds them by name).
    pub fn socketFd(g: *const UdpGroup, i: usize) std.posix.fd_t {
        return g.sockets[i].udp.socket.handle;
    }

    /// Serves until canceled: each socket's reader and sender on its
    /// executor. After a cancel the sessions are closed (`.stop`) and what
    /// is queued is sent.
    pub fn run(g: *UdpGroup) anyerror!void {
        const io = g.io;
        defer {
            g.readers.cancel(io);
            for (g.sockets) |*s| s.closed.store(true, .release);
            for (g.sockets) |*s| s.tasks.cancel(io);
            // Each sender seals its queue as it ends: a send after that
            // answers Closed.
            g.senders.cancel(io);
            // A socket whose sender never started (a spawn failed part way)
            // is sealed here: its later sends answer Closed too, and what
            // got in is dropped and counted.
            for (g.sockets) |*s| s.dropUnsent();
            g.gate.close();
        }
        for (g.sockets) |*s| {
            try placement.concurrent(&g.readers, io, .{ .executor = s.exec }, UdpSocket.reader, .{s});
            try placement.concurrent(&g.senders, io, .{ .executor = s.exec }, UdpSocket.sender, .{s});
        }
        // Until canceled; a hand-over ends the readers, not the group.
        var forever: std.Io.Event = .unset;
        forever.wait(io) catch return error.Canceled;
    }

    /// Wakes `s`'s sender from any thread (T5).
    fn wake(g: *UdpGroup, s: *UdpSocket) void {
        if (!g.gate.enter()) return;
        defer g.gate.leave();
        s.signal.set(g.io);
    }

    /// A restart passes the sockets to a new process: the readers stop at
    /// once so every datagram goes to it; what is queued is still sent.
    pub fn handOver(g: *UdpGroup) void {
        if (g.handed_over.swap(true, .acq_rel)) return;
        g.readers.cancel(g.io);
    }

    /// Counters over every socket.
    pub fn totals(g: *const UdpGroup) Totals {
        var t: Totals = .{};
        for (g.sockets) |*s| {
            t.datagrams_in += s.stats.datagrams_in.load(.monotonic);
            t.datagrams_out += s.stats.datagrams_out.load(.monotonic);
            t.dropped += s.stats.dropped_kernel.load(.monotonic) + s.stats.dropped_truncated.load(.monotonic) +
                s.stats.dropped_queue_full.load(.monotonic) + s.stats.dropped_send_failed.load(.monotonic) +
                s.stats.dropped_sessions_full.load(.monotonic);
            t.sessions += s.stats.sessions.load(.monotonic);
        }
        return t;
    }

    pub const Totals = struct { datagrams_in: u64 = 0, datagrams_out: u64 = 0, dropped: u64 = 0, sessions: u64 = 0 };
};
