//! Raw TCP servers (p3/net, design-net.md §2.2 to §3): the application's own
//! protocol on Anole's listeners. The HTTP core's accept loops, connection
//! cap, PROXY protocol, TLS and parking do the work up to a ready
//! connection (`Listener.raw`); from there a `TcpConn` serves it, as the
//! WebSocket-callbacks adopter does: a task for each burst of input, no
//! task while the connection waits for the peer.
//!
//! Writing never waits on the peer. `Conn.send` appends to the connection's
//! outbox and returns; one *net driver* task per executor writes the
//! outboxes that were kicked since its last round, straight from the driver
//! with a non-blocking `sendmsg` on plain TCP, so every connection a
//! consumer answered in one round costs one syscall and no task switch. A
//! TLS connection, or one whose socket buffer filled, gets a flusher task.
//! Exactly one party is responsible for an outbox at any time (the
//! `scheduled` flag), so bytes leave in send order.
const std = @import("std");
const builtin = @import("builtin");
const dusty = @import("dusty");
const anole_log = @import("anole_log");
const framing_mod = @import("framing.zig");

pub const Framing = framing_mod.Framing;
pub const FrameIterator = framing_mod.FrameIterator;

const placement = dusty.placement;
const Duration = std.Io.Duration;
const native_os = builtin.os.tag;
const log = std.log.scoped(.anole);

/// How a connection ended.
pub const CloseReason = enum {
    /// The peer closed (FIN after its data, with nothing more owed).
    peer,
    /// The handler closed it (`close`, `end` once flushed, a task handler that returned).
    local,
    /// The peer reset it (RST), or it broke mid-write (EPIPE).
    reset,
    /// A read, write or TLS failure; a callback that failed (logged at warn).
    failed,
    idle,
    write_timeout,
    lifetime,
    /// A frame over its `max`, or a malformed length prefix.
    frame,
    /// The drain's deadline (`timeouts.shutdown`) or the server's stop.
    drain,
    /// Anole could not go on (out of memory).
    server,
};

pub const Tcp = struct {
    pub const Options = struct {
        /// How input is cut into messages: see `Framing`.
        framing: Framing = .none,
        /// After the peer ends its side (FIN), the connection stays open for
        /// writing until the handler ends it (`conn.end()`/`close()`). False:
        /// Anole ends this side once what is queued is out, and closes.
        half_open: bool = false,
        /// TCP_NODELAY: small writes go out at once (no Nagle).
        no_delay: bool = true,
        /// TCP keep-alive probes after this much silence (SO_KEEPALIVE,
        /// TCP_KEEPIDLE; 10 s apart, 6 tries), so a peer that vanished is
        /// found within about two minutes. Null: off.
        keepalive: ?Duration = .fromSeconds(60),
        /// The PROXY header and the TLS handshake, together.
        handshake_timeout: ?Duration = .fromSeconds(10),
        /// No input for this long closes the connection (reason `.idle`).
        /// Null: never (keep-alive still finds dead peers).
        idle_timeout: ?Duration = null,
        /// The longest a connection may stay open (reason `.lifetime`).
        lifetime: ?Duration = null,
        /// A flush the peer does not take for this long closes the
        /// connection (reason `.write_timeout`).
        write_timeout: ?Duration = .fromSeconds(30),
        /// Past this many queued bytes `send` answers `.busy` (and
        /// `writable` follows once under half).
        write_high_water: u32 = 256 * 1024,
        /// Past this many, `send` takes nothing (`error.QueueFull`).
        write_max: u32 = 8 * 1024 * 1024,
        /// The read buffer of each burst, on its task's stack (4 KiB to
        /// 64 KiB). A frame larger than it is gathered on the heap.
        read_window: u32 = 16 * 1024,
        /// C ABI: bytes of one connection posted and not yet polled, at most.
        read_ahead: u32 = 256 * 1024,
        /// Open connections on this listener, at most (the server's
        /// `limits.max_connections` still bounds them all). Null: no own cap.
        max_connections: ?u32 = null,
        /// One log line (scope `access`) per closed connection: listener,
        /// remote, duration, bytes in and out, reason.
        log_connections: bool = false,

        /// Why `options` cannot be served, if so.
        pub fn check(o: Options) error{InvalidFraming}!void {
            try o.framing.validate();
            if (o.read_window < 4096 or o.read_window > 65536) return error.InvalidFraming;
        }
    };
};

/// What one burst read: raw bytes (`Framing.none`), or whole frames.
pub const Input = union(enum) {
    bytes: []const u8,
    frames: *FrameIterator,
};

/// The callbacks behind plain function pointers, for the C ABI (as
/// `websocket.Table`). `task` set: the task form, the rest unused.
pub const TcpTable = struct {
    open: ?*const fn (state: ?*anyopaque, *Conn) anyerror!void = null,
    data: ?*const fn (state: ?*anyopaque, *Conn, Input) anyerror!void = null,
    end: ?*const fn (state: ?*anyopaque, *Conn) anyerror!void = null,
    writable: ?*const fn (state: ?*anyopaque, *Conn) anyerror!void = null,
    drain: ?*const fn (state: ?*anyopaque, *Conn) anyerror!void = null,
    close: ?*const fn (state: ?*anyopaque, *Conn, CloseReason) void = null,
    task: ?*const fn (state: ?*anyopaque, *Conn) anyerror!void = null,
    /// A borrowed write (`Conn.sendBorrowed`) was written or dropped.
    sent: ?*const fn (state: ?*anyopaque, *Conn, token: u64) void = null,
    /// Size and alignment of `Handler.State` (0: none) and its init/deinit.
    state_size: u32 = 0,
    state_align: u8 = 1,
    state_init: ?*const fn (*anyopaque) void = null,
    state_deinit: ?*const fn (*anyopaque) void = null,
    /// The callbacks never wait (the C ABI's post events): they may run on
    /// the net driver and in any order with one another, instead of on a
    /// task of their own one at a time.
    inline_events: bool = false,
};

/// A TCP service for `Listener.tcp`: what `app.tcp` builds.
pub const TcpService = struct {
    table: *const TcpTable,
    options: Tcp.Options,
    /// `@typeName(Ctx)`; the server refuses a mismatch (`NetHandlerContext`).
    ctx_type: []const u8,
    /// Set by the server: its `*Ctx`, or the C ABI's engine.
    state: ?*anyopaque = null,
};

/// A TCP service for `Listener.tcp`. `handler` is a callbacks type (see
/// docs/net.md) or a function `fn (*Conn) !void` that serves one
/// connection on a task of its own, either with the server's `*Ctx`
/// first. Callbacks run one at a time on a task on the connection's
/// executor, and may wait; an idle connection holds no task. Each callback
/// may take the server's `*Ctx` first; with a framing, `message(conn,
/// frame)` is called for each whole frame, else `data(conn, bytes)`.
pub fn tcp(comptime Ctx: type, comptime handler: anytype, comptime options: Tcp.Options) TcpService {
    comptime {
        options.check() catch @compileError("anole.net.tcp: the options are not valid: a framing max of 1 byte to 1 GiB, a read_window of 4 KiB to 64 KiB");
    }
    const H = Hooks(Ctx, handler, options.framing);
    return .{
        .table = &H.table,
        .options = options,
        .ctx_type = @typeName(Ctx),
    };
}

fn Hooks(comptime Ctx: type, comptime handler: anytype, comptime framing: Framing) type {
    const is_fn = @typeInfo(@TypeOf(handler)) == .@"fn";
    return struct {
        const table: TcpTable = build();

        fn build() TcpTable {
            var t: TcpTable = .{};
            if (is_fn) {
                t.task = task;
                return t;
            }
            const H = handler;
            if (framing == .none) {
                if (!@hasDecl(H, "data")) @compileError("anole.net.tcp: " ++ @typeName(H) ++ " has no data(conn, bytes), which framing .none calls");
            } else if (!@hasDecl(H, "message")) {
                @compileError("anole.net.tcp: " ++ @typeName(H) ++ " has no message(conn, frame), which framing ." ++ @tagName(framing) ++ " calls");
            }
            if (@hasDecl(H, "open")) t.open = open;
            t.data = data;
            if (@hasDecl(H, "end")) t.end = end;
            if (@hasDecl(H, "writable")) t.writable = writable;
            if (@hasDecl(H, "drain")) t.drain = drain;
            if (@hasDecl(H, "close")) t.close = close;
            if (@hasDecl(H, "State")) {
                t.state_size = @sizeOf(H.State);
                t.state_align = @alignOf(H.State);
                t.state_init = stateInit;
                if (@hasDecl(H.State, "deinit")) t.state_deinit = stateDeinit;
            }
            return t;
        }

        fn arity(comptime f: anytype, comptime plain: usize, comptime name: []const u8) bool {
            const n = @typeInfo(@TypeOf(f)).@"fn".params.len;
            if (n == plain) return false;
            if (n == plain + 1 and Ctx != void) return true;
            @compileError("anole.net callback " ++ name ++ " has the wrong parameters: " ++ @typeName(@TypeOf(f)));
        }

        fn ctxOf(state: ?*anyopaque) *Ctx {
            return @ptrCast(@alignCast(state.?));
        }

        fn task(state: ?*anyopaque, conn: *Conn) anyerror!void {
            return if (comptime arity(handler, 1, "task")) handler(ctxOf(state), conn) else handler(conn);
        }

        fn open(state: ?*anyopaque, conn: *Conn) anyerror!void {
            const f = handler.open;
            return if (comptime arity(f, 1, "open")) f(ctxOf(state), conn) else f(conn);
        }

        fn data(state: ?*anyopaque, conn: *Conn, input: Input) anyerror!void {
            switch (input) {
                .bytes => |b| {
                    if (comptime framing != .none) return;
                    const f = handler.data;
                    return if (comptime arity(f, 2, "data")) f(ctxOf(state), conn, b) else f(conn, b);
                },
                .frames => |it| {
                    if (comptime framing == .none) return;
                    const f = handler.message;
                    while (it.next()) |frame| {
                        try if (comptime arity(f, 2, "message")) f(ctxOf(state), conn, frame) else f(conn, frame);
                    }
                },
            }
        }

        fn end(state: ?*anyopaque, conn: *Conn) anyerror!void {
            const f = handler.end;
            return if (comptime arity(f, 1, "end")) f(ctxOf(state), conn) else f(conn);
        }

        fn writable(state: ?*anyopaque, conn: *Conn) anyerror!void {
            const f = handler.writable;
            return if (comptime arity(f, 1, "writable")) f(ctxOf(state), conn) else f(conn);
        }

        fn drain(state: ?*anyopaque, conn: *Conn) anyerror!void {
            const f = handler.drain;
            return if (comptime arity(f, 1, "drain")) f(ctxOf(state), conn) else f(conn);
        }

        fn close(state: ?*anyopaque, conn: *Conn, reason: CloseReason) void {
            const f = handler.close;
            return if (comptime arity(f, 2, "close")) f(ctxOf(state), conn, reason) else f(conn, reason);
        }

        fn stateInit(p: *anyopaque) void {
            const s: *handler.State = @ptrCast(@alignCast(p));
            s.* = .{};
        }

        fn stateDeinit(p: *anyopaque) void {
            const s: *handler.State = @ptrCast(@alignCast(p));
            s.deinit();
        }
    };
}

// ---------------------------------------------------------------------------
// The public connection

/// One TCP connection, as a handler sees it.
pub const Conn = struct {
    /// Free for the handler: what it keeps per connection (`State`'s
    /// instance when the handler declares one).
    context: ?*anyopaque = null,

    fn tc(c: *const Conn) *TcpConn {
        return @alignCast(@constCast(@fieldParentPtr("conn", c)));
    }

    pub fn contextAs(c: *const Conn, comptime T: type) *T {
        return @ptrCast(@alignCast(c.context.?));
    }

    /// Unique in the process; never reused (log lines, maps).
    pub fn id(c: *const Conn) u64 {
        return c.tc().id;
    }

    /// The client: the PROXY header's source when proxied, else the peer.
    /// Null on a unix socket (and for a PROXY LOCAL health check over one).
    pub fn remote(c: *const Conn) ?std.Io.net.IpAddress {
        const t = c.tc();
        if (t.info.listener.address == .unix) return t.connection.proxied_peer;
        return t.connection.peerAddress();
    }

    /// The socket's own peer (the proxy, when proxied).
    pub fn direct(c: *const Conn) ?std.Io.net.IpAddress {
        const t = c.tc();
        if (t.info.listener.address == .unix) return null;
        return dusty.unmapIpv4(t.connection.stream.socket.address);
    }

    /// The address the client connected to (the PROXY header's destination
    /// when proxied).
    pub fn local(c: *const Conn) ?std.Io.net.IpAddress {
        const t = c.tc();
        if (t.connection.proxied_local) |a| return dusty.unmapIpv4(a);
        if (t.info.listener.address == .unix) return null;
        if (t.local_cache) |a| return a;
        t.local_cache = socketName(t.connection.stream.socket.handle);
        return t.local_cache;
    }

    pub fn listener(c: *const Conn) []const u8 {
        return c.tc().info.listener.name;
    }

    /// TLS on this listener, or (proxied) the PROXY v2 SSL TLV.
    pub fn secure(c: *const Conn) bool {
        const t = c.tc();
        return t.info.listener.tls != null or t.connection.proxied_secure;
    }

    pub fn alpn(c: *const Conn) ?[]const u8 {
        return c.tc().connection.negotiatedProtocol();
    }

    /// SNI: the name the client asked for in its TLS ClientHello.
    pub fn serverName(c: *const Conn) ?[]const u8 {
        return c.tc().connection.serverName();
    }

    /// Mutual TLS: the client's certificate (DER), verified.
    pub fn peerCertificate(c: *const Conn) ?[]const u8 {
        return c.tc().connection.peerCertificate();
    }

    /// TLS on this connection itself (not just the PROXY v2 SSL TLV).
    pub fn isTls(c: *const Conn) bool {
        return c.tc().connection.tls_conn != null;
    }

    /// Its addresses came from a PROXY header.
    pub fn proxied(c: *const Conn) bool {
        const t = c.tc();
        return t.connection.proxied_peer != null or t.connection.proxied_local != null;
    }

    pub fn isUnix(c: *const Conn) bool {
        return c.tc().info.listener.address == .unix;
    }

    /// What the connection moved so far, for the end-of-life records.
    pub const Totals = struct { bytes_in: u64, bytes_out: u64, duration_ms: u64, errno: i32 };

    pub fn totals(c: *const Conn) Totals {
        const t = c.tc();
        const now = std.Io.Clock.Timestamp.now(t.io, .awake);
        const ms = @divTrunc(t.opened_at.durationTo(now).raw.nanoseconds, std.time.ns_per_ms);
        return .{
            .bytes_in = t.bytes_in,
            .bytes_out = t.bytes_out.load(.monotonic),
            .duration_ms = @intCast(@max(0, ms)),
            .errno = t.errno_value.load(.monotonic),
        };
    }

    pub const Sent = enum { ok, busy };
    pub const SendError = error{
        /// The connection is over.
        Closed,
        /// This side was ended (`end`).
        Ended,
        /// Past `write_max`: nothing taken; `writable` / `waitWritable` follow.
        QueueFull,
        /// `sendFrame` with a payload over the framing's `max`.
        FrameTooLarge,
        /// `sendFrame` on a listener with `Framing.none`.
        NoFraming,
        OutOfMemory,
    };

    /// Queues `bytes` (copied) and returns: any task, any executor, any
    /// time; never waits. Sent in order with this connection's other sends.
    pub fn send(c: *Conn, bytes: []const u8) SendError!Sent {
        return c.tc().queue(&.{bytes}, 0);
    }

    /// `send` with the listener's framing around `payload`, in one piece
    /// (never interleaved with another task's send).
    pub fn sendFrame(c: *Conn, payload: []const u8) SendError!Sent {
        const t = c.tc();
        var pbuf: [Framing.max_prefix]u8 = undefined;
        const prefix = try t.service.options.framing.prefix(payload.len, &pbuf);
        return t.queue(&.{ prefix, payload, t.service.options.framing.suffix() }, 0);
    }

    /// `send` without a copy: `bytes` must stay valid until `sent` (the
    /// table's) says `token` was written or dropped. For the C ABI.
    pub fn sendBorrowed(c: *Conn, bytes: []const u8, token: u64) SendError!Sent {
        return c.tc().queue(&.{bytes}, token);
    }

    /// Bytes queued and not yet written.
    pub fn queued(c: *const Conn) usize {
        return c.tc().queued.load(.acquire);
    }

    /// Waits until fewer than half `write_high_water` bytes are queued.
    /// `error.Closed` when it closes meanwhile.
    pub fn waitWritable(c: *Conn) error{ Closed, Canceled }!void {
        return c.tc().waitUnder(c.tc().service.options.write_high_water / 2);
    }

    /// Ends this side once what is queued is out (TLS close_notify, then
    /// FIN). Reading goes on until the peer ends too (or `close`).
    pub fn end(c: *Conn) void {
        c.tc().requestEnd(false);
    }

    /// Closes once what is queued is out: this side ends, input is read and
    /// dropped until the peer ends or 2 s pass, then the socket closes.
    pub fn close(c: *Conn) void {
        c.tc().requestEnd(true);
    }

    /// Closes now with a reset (SO_LINGER 0); what is queued is dropped.
    pub fn reset(c: *Conn) void {
        c.tc().resetNow();
    }

    /// Stops reading (Anole leaves the input in the kernel: TCP flow
    /// control slows the peer) until `resumeReading`. Holds the connection's
    /// task while paused.
    pub fn pauseReading(c: *Conn) void {
        c.tc().paused.store(1, .release);
    }

    pub fn resumeReading(c: *Conn) void {
        const t = c.tc();
        if (t.paused.swap(0, .acq_rel) != 0) t.io.futexWake(u32, &t.paused.raw, 1);
    }

    /// Replaces the listener's `idle_timeout` for this connection (null: none).
    pub fn setIdleTimeout(c: *Conn, timeout: ?Duration) void {
        c.tc().idle_ns.store(if (timeout) |d| @intCast(d.nanoseconds) else -1, .release);
    }

    /// The server is draining: say goodbye and close.
    pub fn draining(c: *const Conn) bool {
        return c.tc().info.draining.isSet();
    }

    /// The server's drain event (set once, never reset), for a task-form
    /// handler to wait on beside its reads.
    pub fn drainEvent(c: *const Conn) *std.Io.Event {
        return c.tc().info.draining;
    }

    // The task form only (`fn (*Conn) !void`), on the handler's own task.

    /// The connection's input, buffered (`read_window` bytes on the heap).
    pub fn reader(c: *Conn) *std.Io.Reader {
        return c.tc().connection.reader;
    }

    pub const ReadError = error{ Closed, FrameTooLarge, InvalidFrame, IdleTimeout, Canceled, NotTaskForm, OutOfMemory };

    /// The next frame by the listener's framing (valid until the next
    /// read), or null when the peer ended its side. `Framing.none`: what
    /// is buffered (at least one byte).
    pub fn readFrame(c: *Conn) ReadError!?[]const u8 {
        return c.tc().readFrameTask();
    }

    pub const WriteError = error{ Closed, Ended, WriteTimeout, Canceled, NotTaskForm, OutOfMemory };

    /// `send`, waiting first while past `write_high_water`: back-pressure by
    /// waiting, which only the connection's own task may do.
    pub fn write(c: *Conn, bytes: []const u8) WriteError!void {
        const t = c.tc();
        if (!t.task_form) return error.NotTaskForm;
        try t.waitOpen(t.service.options.write_high_water);
        _ = t.queue(&.{bytes}, 0) catch |err| return sendToWrite(err);
    }

    pub fn writeFrame(c: *Conn, payload: []const u8) (WriteError || error{ FrameTooLarge, NoFraming })!void {
        const t = c.tc();
        if (!t.task_form) return error.NotTaskForm;
        try t.waitOpen(t.service.options.write_high_water);
        var pbuf: [Framing.max_prefix]u8 = undefined;
        const prefix = try t.service.options.framing.prefix(payload.len, &pbuf);
        _ = t.queue(&.{ prefix, payload, t.service.options.framing.suffix() }, 0) catch |err| switch (err) {
            error.FrameTooLarge => return error.FrameTooLarge,
            error.NoFraming => return error.NoFraming,
            else => |e| return sendToWrite(e),
        };
    }

    /// Waits until everything queued is written (or `write_timeout`).
    pub fn flush(c: *Conn) WriteError!void {
        const t = c.tc();
        if (!t.task_form) return error.NotTaskForm;
        try t.waitUnder(1);
    }

    /// A buffered writer (`read_window` bytes) whose drains go to `send`:
    /// for `print`. A message longer than the buffer may interleave with
    /// sends from other tasks; `send` a whole message for that.
    pub fn writer(c: *Conn) *std.Io.Writer {
        return &c.tc().task_writer.interface;
    }
};

fn sendToWrite(err: Conn.SendError) Conn.WriteError {
    return switch (err) {
        error.Closed => error.Closed,
        error.Ended => error.Ended,
        error.OutOfMemory => error.OutOfMemory,
        // Past write_max after waiting under the high-water mark: a single
        // message bigger than the room.
        error.QueueFull => error.WriteTimeout,
        error.FrameTooLarge, error.NoFraming => error.Closed,
    };
}

// ---------------------------------------------------------------------------
// The listener

/// Counters over one TCP listener's connections.
pub const ListenerStats = struct {
    open: std.atomic.Value(u64) = .init(0),
    total: std.atomic.Value(u64) = .init(0),
    bytes_in: std.atomic.Value(u64) = .init(0),
    bytes_out: std.atomic.Value(u64) = .init(0),
    queue_full: std.atomic.Value(u64) = .init(0),
    closes: [std.enums.values(CloseReason).len]std.atomic.Value(u64) = @splat(.init(0)),
};

var next_conn_id: std.atomic.Value(u64) = .init(1);

/// A raw TCP listener's service and per-executor drivers: the object behind
/// `http.Listener.raw`. Made by the server (`create`), freed by `destroy`
/// after the core has stopped.
pub const TcpListener = struct {
    raw: dusty.Raw,
    gpa: std.mem.Allocator,
    service: TcpService,
    drivers: []Driver,
    stats: ListenerStats = .{},

    pub fn create(gpa: std.mem.Allocator, io: std.Io, service: TcpService) !*TcpListener {
        const self = try gpa.create(TcpListener);
        errdefer gpa.destroy(self);
        const n = @max(1, placement.executorCount(io) orelse 1);
        const drivers = try gpa.alloc(Driver, n);
        for (drivers) |*d| d.* = .{};
        self.* = .{ .raw = .{ .start = start }, .gpa = gpa, .service = service, .drivers = drivers };
        return self;
    }

    pub fn destroy(self: *TcpListener) void {
        const gpa = self.gpa;
        gpa.free(self.drivers);
        gpa.destroy(self);
    }

    fn driverFor(self: *TcpListener, info: *const dusty.RawInfo) !*Driver {
        const d = &self.drivers[info.executor % self.drivers.len];
        if (d.state.load(.acquire) == 2) return d;
        d.start_lock.lockUncancelable(info.io);
        defer d.start_lock.unlock(info.io);
        if (d.state.load(.acquire) == 2) return d;
        d.io = info.io;
        try placement.concurrent(info.group, info.io, .local, Driver.run, .{d});
        d.state.store(2, .release);
        return d;
    }

    fn start(raw: *const dusty.Raw, connection: *dusty.Connection, info: *const dusty.RawInfo) anyerror!?*dusty.Adopter {
        const self: *TcpListener = @alignCast(@constCast(@fieldParentPtr("raw", raw)));
        return TcpConn.open(self, connection, info);
    }
};

// ---------------------------------------------------------------------------
// The net driver

/// One per executor and listener: writes the outboxes kicked since its last
/// round.
const Driver = struct {
    io: std.Io = undefined,
    state: std.atomic.Value(u32) = .init(0),
    start_lock: std.Io.Mutex = .init,
    stack: std.atomic.Value(?*TcpConn) = .init(null),
    signal: placement.Signal = .{},
    stopped: std.atomic.Value(bool) = .init(false),

    /// Puts `t` on the stack and wakes the driver. `t` counts as a helper
    /// until the driver is done with it.
    fn kick(d: *Driver, t: *TcpConn) void {
        _ = t.helpers.fetchAdd(1, .acq_rel);
        var head = d.stack.load(.acquire);
        while (true) {
            t.next = head;
            head = d.stack.cmpxchgWeak(head, t, .release, .acquire) orelse break;
        }
        d.signal.set(d.io);
        // The driver ended meanwhile: nobody will take it.
        if (d.stopped.load(.acquire)) d.abandon();
    }

    fn abandon(d: *Driver) void {
        var head = d.stack.swap(null, .acq_rel);
        while (head) |t| {
            head = t.next;
            t.next = null;
            t.helperDone();
        }
    }

    fn run(d: *Driver) std.Io.Cancelable!void {
        defer {
            d.stopped.store(true, .release);
            d.abandon();
        }
        while (true) {
            try d.signal.wait(d.io);
            d.signal.reset(d.io);
            var head = d.stack.swap(null, .acq_rel);
            // Oldest first.
            var rev: ?*TcpConn = null;
            while (head) |t| {
                head = t.next;
                t.next = rev;
                rev = t;
            }
            while (rev) |t| {
                rev = t.next;
                t.next = null;
                t.serviceOutbox();
                t.helperDone();
            }
        }
    }
};

// ---------------------------------------------------------------------------
// One connection

const Chunk = struct {
    ptr: [*]u8,
    len: usize,
    /// The allocation size when the chunk is owned, else 0.
    cap: usize,
    /// A borrowed chunk's token (nonzero).
    token: u64 = 0,

    fn bytes(c: Chunk) []const u8 {
        return c.ptr[0..c.len];
    }
};

const TcpConn = struct {
    adopter: dusty.Adopter,
    conn: Conn = .{},
    listener: *TcpListener,
    service: *const TcpService,
    connection: *dusty.Connection,
    info: dusty.RawInfo,
    io: std.Io,
    gpa: std.mem.Allocator,
    driver: *Driver,
    id: u64,
    next: ?*TcpConn = null,
    drain_hook: dusty.DrainHooks.Hook,
    state_buf: []u8 = &.{},
    task_form: bool,
    local_cache: ?std.Io.net.IpAddress = null,

    // Writing (any thread): `lock` guards `out`, `scheduled`, `dead`,
    // `ended`. Never held across I/O.
    lock: std.atomic.Mutex = .unlocked,
    out: std.ArrayList(Chunk) = .empty,
    out_bytes: usize = 0,
    scheduled: bool = false,
    dead: bool = false,
    ended: bool = false,
    /// Bytes queued and not yet written (out and inflight).
    queued: std.atomic.Value(u32) = .init(0),
    waiters: std.atomic.Value(u32) = .init(0),
    want_writable: std.atomic.Value(bool) = .init(false),
    // Owned by whoever is responsible for the outbox.
    inflight: std.ArrayList(Chunk) = .empty,
    inflight_head: usize = 0,

    // State flags.
    end_requested: std.atomic.Value(bool) = .init(false),
    end_done: std.atomic.Value(bool) = .init(false),
    close_graceful: std.atomic.Value(bool) = .init(false),
    peer_ended: std.atomic.Value(bool) = .init(false),
    reset_requested: std.atomic.Value(bool) = .init(false),
    closed: std.atomic.Value(bool) = .init(false),
    /// Futex word: 1 once the connection's serving is to end.
    over: std.atomic.Value(u32) = .init(0),
    paused: std.atomic.Value(u32) = .init(0),
    /// 0: none yet; else `CloseReason` + 1.
    reason: std.atomic.Value(u8) = .init(0),
    errno_value: std.atomic.Value(i32) = .init(0),
    helpers: std.atomic.Value(u32) = .init(0),
    release_waiting: std.atomic.Value(bool) = .init(false),
    writable_pending: std.atomic.Value(bool) = .init(false),
    /// Serves callbacks one at a time on the Zig path.
    cb_lock: std.Io.Mutex = .init,
    ending: bool = false,

    // Reading (its task).
    decoder: framing_mod.Decoder,
    frames: std.ArrayList([]const u8) = .empty,
    opened_at: std.Io.Clock.Timestamp,
    last_input: std.Io.Clock.Timestamp,
    idle_ns: std.atomic.Value(i64),
    bytes_in: u64 = 0,
    bytes_out: std.atomic.Value(u64) = .init(0),
    burst: ?*dusty.Burst = null,
    task_window: []u8 = &.{},
    task_frames_at: usize = 0,
    task_writer: TaskWriter = undefined,

    const linger: Duration = .fromSeconds(2);

    // -- Start and release ---------------------------------------------------

    fn open(listener: *TcpListener, connection: *dusty.Connection, info: *const dusty.RawInfo) anyerror!?*dusty.Adopter {
        const service = &listener.service;
        const o = service.options;
        const gpa = listener.gpa;
        const driver = try listener.driverFor(info);
        const t = try gpa.create(TcpConn);
        errdefer gpa.destroy(t);
        const now = std.Io.Clock.Timestamp.now(info.io, .awake);
        t.* = .{
            .adopter = .{ .serve = serve, .release = release },
            .listener = listener,
            .service = service,
            .connection = connection,
            .info = info.*,
            .io = info.io,
            .gpa = gpa,
            .driver = driver,
            .id = next_conn_id.fetchAdd(1, .monotonic),
            .drain_hook = .{ .callback = onDrain },
            .task_form = service.table.task != null,
            .decoder = .init(gpa, o.framing),
            .opened_at = now,
            .last_input = now,
            .idle_ns = .init(if (o.idle_timeout) |d| @intCast(d.nanoseconds) else -1),
        };
        t.task_writer = .{ .conn = t, .interface = .{ .vtable = &.{ .drain = TaskWriter.drain }, .buffer = &.{} } };
        t.conn.context = null;
        t.tuneSocket(o);
        const table = service.table;
        if (table.state_size > 0) {
            std.debug.assert(table.state_align <= 16);
            t.state_buf = try gpa.alignedAlloc(u8, .@"16", table.state_size);
            table.state_init.?(t.state_buf.ptr);
            t.conn.context = t.state_buf.ptr;
        }
        t.adopter.deadline = t.lifetimeAt();
        _ = listener.stats.open.fetchAdd(1, .monotonic);
        _ = listener.stats.total.fetchAdd(1, .monotonic);
        info.drain_hooks.add(info.io, &t.drain_hook);
        if (table.open) |f| {
            t.callLock();
            defer t.callUnlock();
            f(service.state, &t.conn) catch |err| {
                if (err != error.Canceled) log.warn("tcp {s}: open failed: {t}", .{ info.listener.name, err });
                t.setReason(.failed);
                t.ending = true;
            };
        }
        return &t.adopter;
    }

    fn release(a: *dusty.Adopter) void {
        const t: *TcpConn = @alignCast(@fieldParentPtr("adopter", a));
        const io = t.io;
        // No more output; unblock anything writing or waiting.
        t.closed.store(true, .release);
        t.shutdownSocket(.both);
        t.over.store(1, .release);
        io.futexWake(u32, &t.over.raw, std.math.maxInt(u32));
        io.futexWake(u32, &t.paused.raw, std.math.maxInt(u32));
        io.futexWake(u32, &t.queued.raw, std.math.maxInt(u32));
        // The driver and the helper tasks are done with it.
        t.release_waiting.store(true, .release);
        while (true) {
            const n = t.helpers.load(.acquire);
            if (n == 0) break;
            io.futexWaitUncancelable(u32, &t.helpers.raw, n);
        }
        t.info.drain_hooks.remove(io, &t.drain_hook);
        t.dropOutput();
        const reason = t.finalReason();
        const stats = &t.listener.stats;
        _ = stats.open.fetchSub(1, .monotonic);
        _ = stats.closes[@intFromEnum(reason)].fetchAdd(1, .monotonic);
        _ = stats.bytes_in.fetchAdd(t.bytes_in, .monotonic);
        const out = t.bytes_out.load(.monotonic);
        _ = stats.bytes_out.fetchAdd(out, .monotonic);
        if (t.service.options.log_connections) t.logClosed(reason, out);
        if (t.service.table.close) |f| f(t.service.state, &t.conn, reason);
        if (t.state_buf.len > 0) {
            if (t.service.table.state_deinit) |f| f(t.state_buf.ptr);
            t.gpa.free(t.state_buf);
        }
        t.decoder.deinit();
        t.frames.deinit(t.gpa);
        t.out.deinit(t.gpa);
        t.inflight.deinit(t.gpa);
        t.gpa.destroy(t);
    }

    fn logClosed(t: *TcpConn, reason: CloseReason, bytes_out: u64) void {
        var buf: [96]u8 = undefined;
        var remote: []const u8 = "-";
        if (t.conn.remote()) |a| {
            var w: std.Io.Writer = .fixed(&buf);
            if (a.format(&w)) |_| remote = w.buffered() else |_| {}
        }
        const ms: u64 = @intCast(@max(0, @divTrunc(t.opened_at.durationTo(std.Io.Clock.Timestamp.now(t.io, .awake)).raw.nanoseconds, std.time.ns_per_ms)));
        anole_log.scoped(.access).info("tcp connection closed", .{
            .listener = t.info.listener.name,
            .remote = remote,
            .duration_ms = ms,
            .bytes_in = t.bytes_in,
            .bytes_out = bytes_out,
            .reason = @tagName(reason),
        });
    }

    fn setReason(t: *TcpConn, r: CloseReason) void {
        _ = t.reason.cmpxchgStrong(0, @intFromEnum(r) + 1, .acq_rel, .acquire);
    }

    fn finalReason(t: *TcpConn) CloseReason {
        const v = t.reason.load(.acquire);
        if (v != 0) return @enumFromInt(v - 1);
        const now = std.Io.Clock.Timestamp.now(t.io, .awake);
        if (t.lifetimeAt()) |d| if (now.compare(.gte, d)) return .lifetime;
        if (t.idleAt()) |d| if (now.compare(.gte, d)) return .idle;
        return .drain;
    }

    fn tuneSocket(t: *TcpConn, o: Tcp.Options) void {
        if (comptime native_os == .windows) return;
        if (t.info.listener.address == .unix) return;
        const fd = t.connection.stream.socket.handle;
        const one: c_int = 1;
        if (o.no_delay) _ = std.c.setsockopt(fd, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, &one, @sizeOf(c_int));
        if (comptime native_os.isDarwin()) _ = std.c.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.NOSIGPIPE, &one, @sizeOf(c_int));
        if (o.keepalive) |d| {
            _ = std.c.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.KEEPALIVE, &one, @sizeOf(c_int));
            const secs: c_int = @intCast(@max(1, @divTrunc(d.nanoseconds, std.time.ns_per_s)));
            const interval: c_int = 10;
            const count: c_int = 6;
            if (comptime native_os == .linux) {
                _ = std.c.setsockopt(fd, std.posix.IPPROTO.TCP, 4, &secs, @sizeOf(c_int)); // TCP_KEEPIDLE
                _ = std.c.setsockopt(fd, std.posix.IPPROTO.TCP, 5, &interval, @sizeOf(c_int)); // TCP_KEEPINTVL
                _ = std.c.setsockopt(fd, std.posix.IPPROTO.TCP, 6, &count, @sizeOf(c_int)); // TCP_KEEPCNT
            } else if (comptime native_os.isDarwin()) {
                _ = std.c.setsockopt(fd, std.posix.IPPROTO.TCP, 0x10, &secs, @sizeOf(c_int)); // TCP_KEEPALIVE
                _ = std.c.setsockopt(fd, std.posix.IPPROTO.TCP, 0x101, &interval, @sizeOf(c_int)); // TCP_KEEPINTVL
                _ = std.c.setsockopt(fd, std.posix.IPPROTO.TCP, 0x102, &count, @sizeOf(c_int)); // TCP_KEEPCNT
            }
        }
    }

    // -- Callbacks -------------------------------------------------------------

    fn callLock(t: *TcpConn) void {
        if (t.service.table.inline_events) return;
        t.cb_lock.lockUncancelable(t.io);
    }

    fn callUnlock(t: *TcpConn) void {
        if (t.service.table.inline_events) return;
        t.cb_lock.unlock(t.io);
    }

    // -- Helpers (tasks that touch the connection) ----------------------------

    fn helperDone(t: *TcpConn) void {
        const was = t.helpers.fetchSub(1, .acq_rel);
        if (was == 1 and t.release_waiting.load(.acquire)) t.io.futexWake(u32, &t.helpers.raw, std.math.maxInt(u32));
    }

    /// Runs `func(t)` on a task on the connection's executor, counted as a
    /// helper. False when no task could be had.
    fn spawn(t: *TcpConn, comptime func: fn (*TcpConn) void) bool {
        _ = t.helpers.fetchAdd(1, .acq_rel);
        const Runner = struct {
            fn run(c: *TcpConn) void {
                defer c.helperDone();
                func(c);
            }
        };
        placement.concurrent(t.info.group, t.io, .{ .executor = t.info.executor }, Runner.run, .{t}) catch {
            t.helperDone();
            return false;
        };
        return true;
    }

    // -- Writing: queue --------------------------------------------------------

    fn spinLock(t: *TcpConn) void {
        while (!t.lock.tryLock()) std.atomic.spinLoopHint();
    }

    /// Appends `parts` as one piece of the outbox. `token` nonzero: one
    /// borrowed part, without a copy.
    fn queue(t: *TcpConn, parts: []const []const u8, token: u64) Conn.SendError!Conn.Sent {
        var total: usize = 0;
        for (parts) |p| total += p.len;
        const o = &t.service.options;
        // Allocated before the lock.
        var fresh: ?[]u8 = null;
        if (token == 0 and total > 0) {
            fresh = t.gpa.alloc(u8, @max(total, @min(o.write_high_water, 16 * 1024))) catch return error.OutOfMemory;
        }
        errdefer if (fresh) |f| t.gpa.free(f);
        var kick_it = false;
        var busy = false;
        {
            t.spinLock();
            defer t.lock.unlock();
            if (t.dead or t.closed.load(.monotonic)) return error.Closed;
            if (t.ended) return error.Ended;
            const q = t.queued.load(.monotonic);
            if (total > 0 and q + total > o.write_max) {
                t.want_writable.store(true, .release);
                _ = t.listener.stats.queue_full.fetchAdd(1, .monotonic);
                return error.QueueFull;
            }
            if (total > 0) {
                if (token != 0) {
                    t.out.append(t.gpa, .{ .ptr = @constCast(parts[0].ptr), .len = parts[0].len, .cap = 0, .token = token }) catch return error.OutOfMemory;
                } else {
                    // Into the last chunk when it has room: many small sends
                    // cost one allocation.
                    var placed = false;
                    if (t.out.items.len > 0) {
                        const last = &t.out.items[t.out.items.len - 1];
                        if (last.cap != 0 and last.cap - last.len >= total) {
                            var at = last.len;
                            for (parts) |p| {
                                @memcpy(last.ptr[at..][0..p.len], p);
                                at += p.len;
                            }
                            last.len = at;
                            placed = true;
                        }
                    }
                    if (!placed) {
                        const buf = fresh.?;
                        var at: usize = 0;
                        for (parts) |p| {
                            @memcpy(buf[at..][0..p.len], p);
                            at += p.len;
                        }
                        t.out.append(t.gpa, .{ .ptr = buf.ptr, .len = total, .cap = buf.len }) catch return error.OutOfMemory;
                        fresh = null;
                    }
                }
                _ = t.queued.fetchAdd(@intCast(total), .acq_rel);
                t.out_bytes += total;
                busy = q + total > o.write_high_water;
                if (busy) t.want_writable.store(true, .release);
            }
            if (!t.scheduled) {
                t.scheduled = true;
                kick_it = true;
            }
        }
        if (fresh) |f| t.gpa.free(f);
        if (kick_it) t.driver.kick(t);
        return if (busy) .busy else .ok;
    }

    /// Makes sure someone looks at the outbox (and the end flags).
    fn schedule(t: *TcpConn) void {
        var kick_it = false;
        {
            t.spinLock();
            defer t.lock.unlock();
            if (!t.scheduled) {
                t.scheduled = true;
                kick_it = true;
            }
        }
        if (kick_it) t.driver.kick(t);
    }

    fn requestEnd(t: *TcpConn, graceful: bool) void {
        {
            t.spinLock();
            defer t.lock.unlock();
            t.ended = true;
        }
        if (graceful) t.close_graceful.store(true, .release);
        t.end_requested.store(true, .release);
        t.schedule();
    }

    fn resetNow(t: *TcpConn) void {
        t.setReason(.local);
        t.reset_requested.store(true, .release);
        {
            t.spinLock();
            defer t.lock.unlock();
            t.dead = true;
            t.ended = true;
        }
        if (comptime native_os != .windows) {
            const lg: std.c.linger = .{ .onoff = 1, .linger = 0 };
            _ = std.c.setsockopt(t.connection.stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.LINGER, &lg, @sizeOf(@TypeOf(lg)));
        }
        t.shutdownSocket(.both);
        t.over.store(1, .release);
        t.io.futexWake(u32, &t.over.raw, std.math.maxInt(u32));
        t.io.futexWake(u32, &t.queued.raw, std.math.maxInt(u32));
        t.schedule();
    }

    /// Ends the connection for `reason` (the first reason stands): nothing
    /// more is written, the socket is shut down and the reading side ends.
    fn abort(t: *TcpConn, reason: CloseReason) void {
        t.setReason(reason);
        {
            t.spinLock();
            defer t.lock.unlock();
            t.dead = true;
            t.ended = true;
        }
        t.shutdownSocket(.both);
        t.over.store(1, .release);
        t.io.futexWake(u32, &t.over.raw, std.math.maxInt(u32));
        t.io.futexWake(u32, &t.queued.raw, std.math.maxInt(u32));
    }

    fn shutdownSocket(t: *TcpConn, how: std.Io.net.ShutdownHow) void {
        if (comptime native_os == .windows) {
            t.connection.stream.shutdown(t.io, how) catch {};
            return;
        }
        const h: c_int = switch (how) {
            .recv => std.posix.SHUT.RD,
            .send => std.posix.SHUT.WR,
            .both => std.posix.SHUT.RDWR,
        };
        _ = std.c.shutdown(t.connection.stream.socket.handle, h);
    }

    // -- Writing: the responsible party ---------------------------------------

    /// Under `lock`: takes the outbox as the batch to write. False when
    /// there is none.
    fn takeBatch(t: *TcpConn) bool {
        t.spinLock();
        defer t.lock.unlock();
        if (t.out.items.len == 0) return false;
        std.mem.swap(std.ArrayList(Chunk), &t.out, &t.inflight);
        t.inflight_head = 0;
        t.out_bytes = 0;
        return true;
    }

    /// The driver's turn with a kicked connection.
    fn serviceOutbox(t: *TcpConn) void {
        if (comptime native_os != .windows) {
            if (t.connection.tls_conn == null and !t.close_graceful.load(.acquire)) return t.serviceDirect();
        }
        t.handOver();
    }

    /// Passes the outbox to a flusher task.
    fn handOver(t: *TcpConn) void {
        if (!t.spawn(flusher)) {
            t.failWrite(.server);
        }
    }

    fn serviceDirect(t: *TcpConn) void {
        while (true) {
            if (t.dead) {
                t.discardAll();
                t.done();
                return;
            }
            if (t.inflight_head >= t.inflight.items.len) {
                t.inflight.clearRetainingCapacity();
                t.inflight_head = 0;
                if (!t.takeBatch()) {
                    // Nothing queued: the end, if asked for.
                    if (t.end_requested.load(.acquire) and !t.end_done.load(.acquire)) {
                        t.shutdownSocket(.send);
                        t.endFinished();
                    }
                    t.spinLock();
                    if (t.out.items.len != 0) {
                        t.lock.unlock();
                        continue;
                    }
                    t.scheduled = false;
                    t.lock.unlock();
                    return;
                }
            }
            switch (t.writeNow()) {
                .done => {},
                .would_block => return t.handOver(),
                .failed => {
                    t.failWrite(.reset);
                    t.discardAll();
                    t.done();
                    return;
                },
            }
        }
    }

    /// The outbox was emptied and the end handled: the party lets go.
    fn done(t: *TcpConn) void {
        t.spinLock();
        t.scheduled = false;
        t.lock.unlock();
    }

    const NowResult = enum { done, would_block, failed };

    /// Writes `inflight` without waiting: `sendmsg` with MSG_DONTWAIT.
    fn writeNow(t: *TcpConn) NowResult {
        const fd = t.connection.stream.socket.handle;
        var flags: u32 = std.c.MSG.DONTWAIT;
        if (comptime native_os == .linux) flags |= std.c.MSG.NOSIGNAL;
        while (t.inflight_head < t.inflight.items.len) {
            var iov: [64]std.posix.iovec_const = undefined;
            var n: usize = 0;
            for (t.inflight.items[t.inflight_head..]) |c| {
                if (n == iov.len) break;
                iov[n] = .{ .base = c.ptr, .len = c.len };
                n += 1;
            }
            const msg: std.c.msghdr_const = .{
                .name = null,
                .namelen = 0,
                .iov = &iov,
                .iovlen = @intCast(n),
                .control = null,
                .controllen = 0,
                .flags = 0,
            };
            const rc = std.c.sendmsg(fd, &msg, flags);
            if (rc < 0) switch (std.posix.errno(rc)) {
                .INTR => continue,
                .AGAIN => return .would_block,
                else => |e| {
                    t.errno_value.store(@intFromEnum(e), .release);
                    return .failed;
                },
            };
            t.consume(@intCast(rc));
        }
        return .done;
    }

    /// `n` bytes of the batch are written: frees what is whole, advances
    /// into the chunk that is not, and tells the writable waiters.
    fn consume(t: *TcpConn, n: usize) void {
        var left = n;
        while (left > 0 and t.inflight_head < t.inflight.items.len) {
            const c = &t.inflight.items[t.inflight_head];
            if (left >= c.len) {
                left -= c.len;
                t.finishChunk(c.*);
                t.inflight_head += 1;
            } else {
                c.ptr += left;
                c.len -= left;
                left = 0;
            }
        }
        _ = t.bytes_out.fetchAdd(n, .monotonic);
        const was = t.queued.fetchSub(@intCast(n), .acq_rel);
        const now_queued = was - @as(u32, @intCast(n));
        if (t.waiters.load(.acquire) != 0) t.io.futexWake(u32, &t.queued.raw, std.math.maxInt(u32));
        const half = t.service.options.write_high_water / 2;
        if (now_queued < half and t.want_writable.load(.acquire) and t.want_writable.swap(false, .acq_rel)) t.notifyWritable();
    }

    fn finishChunk(t: *TcpConn, c: Chunk) void {
        if (c.cap != 0) {
            t.gpa.free(c.ptr[0..c.cap]);
        } else if (c.token != 0) {
            if (t.service.table.sent) |f| f(t.service.state, &t.conn, c.token);
        }
    }

    /// WRITABLE: the C ABI's table posts it from here; a Zig handler's
    /// `writable` runs on a task of its own.
    fn notifyWritable(t: *TcpConn) void {
        const f = t.service.table.writable orelse return;
        if (t.service.table.inline_events) {
            f(t.service.state, &t.conn) catch {};
            return;
        }
        if (t.writable_pending.swap(true, .acq_rel)) return;
        if (!t.spawn(writableTask)) t.writable_pending.store(false, .release);
    }

    fn writableTask(t: *TcpConn) void {
        t.writable_pending.store(false, .release);
        if (t.closed.load(.acquire)) return;
        t.callLock();
        defer t.callUnlock();
        const f = t.service.table.writable.?;
        f(t.service.state, &t.conn) catch |err| {
            if (err != error.Canceled) log.warn("tcp {s}: writable failed: {t}", .{ t.info.listener.name, err });
            t.abort(.failed);
        };
    }

    /// Drops whatever is queued (a reset or a failed connection): borrowed
    /// chunks report `sent`.
    fn discardAll(t: *TcpConn) void {
        t.dropOutput();
        _ = t.queued.swap(0, .acq_rel);
        if (t.waiters.load(.acquire) != 0) t.io.futexWake(u32, &t.queued.raw, std.math.maxInt(u32));
    }

    fn dropOutput(t: *TcpConn) void {
        while (t.inflight_head < t.inflight.items.len) : (t.inflight_head += 1) t.finishChunk(t.inflight.items[t.inflight_head]);
        t.inflight.clearRetainingCapacity();
        t.inflight_head = 0;
        t.spinLock();
        defer t.lock.unlock();
        for (t.out.items) |c| t.finishChunk(c);
        t.out.clearRetainingCapacity();
        t.out_bytes = 0;
    }

    fn failWrite(t: *TcpConn, reason: CloseReason) void {
        const e = t.errno_value.load(.acquire);
        t.abort(if (reason == .reset and e != 0 and e != @intFromEnum(std.posix.E.PIPE) and e != @intFromEnum(std.posix.E.CONNRESET)) .failed else reason);
    }

    /// The local end is finished (FIN sent): the connection is over when
    /// the peer's side is too.
    fn endFinished(t: *TcpConn) void {
        t.end_done.store(true, .release);
        if (t.peer_ended.load(.acquire)) t.setOver();
    }

    fn setOver(t: *TcpConn) void {
        t.over.store(1, .release);
        t.io.futexWake(u32, &t.over.raw, std.math.maxInt(u32));
    }

    // -- The flusher task ------------------------------------------------------

    fn flusher(t: *TcpConn) void {
        const io = t.io;
        const o = &t.service.options;
        while (true) {
            if (t.dead) {
                t.discardAll();
                t.done();
                return;
            }
            if (t.inflight_head >= t.inflight.items.len) {
                t.inflight.clearRetainingCapacity();
                t.inflight_head = 0;
                if (!t.takeBatch()) {
                    if (t.end_requested.load(.acquire) and !t.end_done.load(.acquire)) {
                        t.finishOutput();
                        continue;
                    }
                    t.spinLock();
                    if (t.out.items.len != 0) {
                        t.lock.unlock();
                        continue;
                    }
                    t.scheduled = false;
                    t.lock.unlock();
                    return;
                }
            }
            // Direct first on plain TCP: the batch may go without a wait.
            if (comptime native_os != .windows) {
                if (t.connection.tls_conn == null) switch (t.writeNow()) {
                    .done => continue,
                    .would_block => {},
                    .failed => {
                        t.failWrite(.reset);
                        continue;
                    },
                };
            }
            const timeout: std.Io.Timeout = if (o.write_timeout) |d| .{ .duration = .{ .raw = d, .clock = .awake } } else .none;
            const deadline = dusty.Deadline.init(io, timeout);
            const result = deadline.run(writeBatch, .{t});
            if (result) |_| {} else |err| switch (err) {
                error.Timeout => t.abort(.write_timeout),
                error.Canceled => {
                    // The server stops: the connection task ends it.
                    t.abort(.drain);
                },
                else => t.failWrite(.reset),
            }
        }
    }

    /// Writes the batch through the connection's writer (TLS records
    /// included), waiting as the socket needs.
    fn writeBatch(t: *TcpConn) error{WriteFailed}!void {
        const w = t.connection.writer;
        while (t.inflight_head < t.inflight.items.len) {
            var slices: [32][]const u8 = undefined;
            var n: usize = 0;
            var bytes: usize = 0;
            for (t.inflight.items[t.inflight_head..]) |c| {
                if (n == slices.len) break;
                slices[n] = c.bytes();
                bytes += c.len;
                n += 1;
            }
            w.writeVecAll(slices[0..n]) catch return error.WriteFailed;
            w.flush() catch return error.WriteFailed;
            t.consume(bytes);
        }
    }

    /// The end of the local side, by the flusher: TLS close_notify, FIN,
    /// and for a graceful close the wait for the peer's side to end.
    fn finishOutput(t: *TcpConn) void {
        const io = t.io;
        t.connection.closeNotify() catch {};
        t.shutdownSocket(.send);
        t.endFinished();
        if (!t.close_graceful.load(.acquire)) return;
        // The reading side drops input until the peer ends: a bound on it.
        if (t.over.load(.acquire) == 0) {
            io.futexWaitTimeout(u32, &t.over.raw, 0, .{ .duration = .{ .raw = linger, .clock = .awake } }) catch {};
        }
        if (t.over.load(.acquire) == 0) {
            t.shutdownSocket(.both);
            t.setOver();
        }
    }

    // -- Waiting on the outbox -------------------------------------------------

    /// Waits until fewer than `below` bytes are queued.
    fn waitUnder(t: *TcpConn, below: u32) error{ Closed, Canceled }!void {
        _ = t.waiters.fetchAdd(1, .acq_rel);
        defer _ = t.waiters.fetchSub(1, .acq_rel);
        while (true) {
            if (t.closed.load(.acquire) or t.dead) return error.Closed;
            const q = t.queued.load(.acquire);
            if (q < below) return;
            try t.io.futexWait(u32, &t.queued.raw, q);
        }
    }

    fn waitOpen(t: *TcpConn, high: u32) Conn.WriteError!void {
        t.waitUnder(@max(1, high)) catch |err| return switch (err) {
            error.Closed => error.Closed,
            error.Canceled => error.Canceled,
        };
    }

    // -- The drain -------------------------------------------------------------

    /// Runs under the drain's lock: must not wait.
    fn onDrain(hook: *dusty.DrainHooks.Hook) void {
        const t: *TcpConn = @alignCast(@fieldParentPtr("drain_hook", hook));
        if (t.service.table.drain == null) return;
        _ = t.spawn(drainTask);
    }

    fn drainTask(t: *TcpConn) void {
        if (t.closed.load(.acquire)) return;
        t.callLock();
        defer t.callUnlock();
        const f = t.service.table.drain.?;
        f(t.service.state, &t.conn) catch |err| {
            if (err != error.Canceled) log.warn("tcp {s}: drain failed: {t}", .{ t.info.listener.name, err });
            t.abort(.failed);
        };
    }

    // -- Deadlines ---------------------------------------------------------------

    fn lifetimeAt(t: *const TcpConn) ?std.Io.Clock.Timestamp {
        const d = t.service.options.lifetime orelse return null;
        return t.opened_at.addDuration(.{ .raw = d, .clock = .awake });
    }

    fn idleAt(t: *const TcpConn) ?std.Io.Clock.Timestamp {
        const ns = t.idle_ns.load(.acquire);
        if (ns < 0) return null;
        return t.last_input.addDuration(.{ .raw = .{ .nanoseconds = ns }, .clock = .awake });
    }

    fn sooner(a: ?std.Io.Clock.Timestamp, b: ?std.Io.Clock.Timestamp) ?std.Io.Clock.Timestamp {
        const x = a orelse return b;
        const y = b orelse return a;
        return if (x.compare(.lte, y)) x else y;
    }

    // -- Serving ---------------------------------------------------------------

    fn serve(a: *dusty.Adopter, burst: *dusty.Burst) anyerror!dusty.Burst.End {
        const t: *TcpConn = @alignCast(@fieldParentPtr("adopter", a));
        if (t.ending) return .close;
        if (t.task_form) return t.serveTask(burst);
        const w = t.service.options.read_window;
        if (w <= 4096) return t.serveCallbacks(4096, burst);
        if (w <= 16384) return t.serveCallbacks(16384, burst);
        return t.serveCallbacks(65536, burst);
    }

    fn serveCallbacks(t: *TcpConn, comptime window_len: usize, burst: *dusty.Burst) anyerror!dusty.Burst.End {
        var window: [window_len]u8 = undefined;
        const r = burst.connection.reader;
        std.debug.assert(r.bufferedLen() == 0);
        r.buffer = &window;
        r.seek = 0;
        r.end = 0;
        defer {
            r.buffer = &.{};
            r.seek = 0;
            r.end = 0;
        }
        return t.loop(burst, r);
    }

    fn loop(t: *TcpConn, burst: *dusty.Burst, r: *std.Io.Reader) anyerror!dusty.Burst.End {
        const o = &t.service.options;
        while (true) {
            if (t.over.load(.acquire) != 0) return .close;
            if (t.paused.load(.acquire) != 0) {
                try t.waitResumed();
                continue;
            }
            if (t.close_graceful.load(.acquire) or t.ending) return t.finishGraceful(burst, r);
            burst.deadline = sooner(t.lifetimeAt(), t.idleAt());
            burst.armDeadline();
            const input = burst.waitInput() catch |err| return t.readEnded(burst, err);
            burst.deadline = t.lifetimeAt();
            burst.armDeadline();
            if (input == .idle) {
                t.adopter.deadline = sooner(t.lifetimeAt(), t.idleAt());
                return .park;
            }
            if (t.paused.load(.acquire) != 0) continue; // the bytes wait in the reader
            const bytes = r.buffered();
            r.toss(bytes.len);
            r.seek = 0;
            r.end = 0;
            t.last_input = std.Io.Clock.Timestamp.now(t.io, .awake);
            t.bytes_in += bytes.len;
            if (t.close_graceful.load(.acquire)) continue; // input is dropped
            if (!(try t.deliver(bytes))) return .close;
            _ = o;
        }
    }

    /// Hands a burst's bytes to the handler. False when the connection
    /// ended meanwhile (a bad frame, a failed callback).
    fn deliver(t: *TcpConn, bytes: []const u8) anyerror!bool {
        const table = t.service.table;
        const f = table.data orelse return true;
        const o = &t.service.options;
        var bad: ?anyerror = null;
        var it: FrameIterator = .{};
        var input: Input = .{ .bytes = bytes };
        if (o.framing != .none) {
            t.frames.clearRetainingCapacity();
            t.decoder.feed(bytes, &t.frames, t.gpa) catch |err| {
                bad = err;
            };
            it = .{ .frames = t.frames.items };
            input = .{ .frames = &it };
        }
        if (o.framing == .none or it.frames.len > 0) {
            t.callLock();
            defer t.callUnlock();
            f(t.service.state, &t.conn, input) catch |err| {
                if (err == error.Canceled) return err;
                if (!t.closed.load(.acquire) and !t.dead) log.warn("tcp {s}: handler failed: {t}", .{ t.info.listener.name, err });
                t.abort(.failed);
                return false;
            };
        }
        if (bad) |err| {
            t.abort(if (err == error.OutOfMemory) .server else .frame);
            return false;
        }
        return true;
    }

    fn waitResumed(t: *TcpConn) !void {
        while (t.paused.load(.acquire) != 0 and t.over.load(.acquire) == 0) {
            try t.io.futexWait(u32, &t.paused.raw, 1);
        }
    }

    /// A wait for input failed or the peer ended.
    fn readEnded(t: *TcpConn, burst: *dusty.Burst, err: anyerror) anyerror!dusty.Burst.End {
        switch (err) {
            error.EndOfStream => return t.peerEnded(burst),
            error.Canceled => {
                if (burst.timer.fired()) {
                    const now = std.Io.Clock.Timestamp.now(t.io, .awake);
                    const life = t.lifetimeAt();
                    t.abort(if (life != null and now.compare(.gte, life.?)) .lifetime else .idle);
                    return .close;
                }
                return err;
            },
            else => {
                t.setReason(if (dusty.Connection.isPeerGone(err)) .reset else .failed);
                t.abort(.failed);
                return .close;
            },
        }
    }

    /// The peer's FIN. A half-open listener tells the handler (`end`) and
    /// waits for it to end its side; else this side ends once what is
    /// queued is out.
    fn peerEnded(t: *TcpConn, burst: *dusty.Burst) anyerror!dusty.Burst.End {
        t.setReason(.peer);
        t.peer_ended.store(true, .release);
        const o = &t.service.options;
        if (o.half_open) {
            if (t.service.table.end) |f| {
                t.callLock();
                defer t.callUnlock();
                f(t.service.state, &t.conn) catch |err| {
                    if (err == error.Canceled) return err;
                    log.warn("tcp {s}: end failed: {t}", .{ t.info.listener.name, err });
                    t.abort(.failed);
                    return .close;
                };
            }
            if (t.end_done.load(.acquire)) t.setOver();
        } else {
            t.requestEnd(false);
        }
        burst.deadline = t.lifetimeAt();
        burst.armDeadline();
        while (t.over.load(.acquire) == 0) {
            t.io.futexWait(u32, &t.over.raw, 0) catch |err| {
                if (burst.timer.fired()) {
                    t.abort(.lifetime);
                    return .close;
                }
                return err;
            };
        }
        return .close;
    }

    /// The local side closes: what is queued goes out, this side ends, and
    /// input is read and dropped until the peer ends or `linger` passes.
    fn finishGraceful(t: *TcpConn, burst: *dusty.Burst, r: *std.Io.Reader) anyerror!dusty.Burst.End {
        t.setReason(.local);
        if (!t.end_requested.load(.acquire)) {
            t.close_graceful.store(true, .release);
            t.requestEnd(true);
        }
        burst.deadline = std.Io.Clock.Timestamp.now(t.io, .awake).addDuration(.{ .raw = linger, .clock = .awake });
        burst.armDeadline();
        while (t.over.load(.acquire) == 0) {
            const input = burst.waitInput() catch |err| switch (err) {
                error.Canceled => {
                    if (burst.timer.fired()) return .close;
                    return err;
                },
                else => return .close,
            };
            if (input == .idle) {
                t.adopter.deadline = burst.deadline;
                return .park;
            }
            const n = r.bufferedLen();
            r.toss(n);
            r.seek = 0;
            r.end = 0;
        }
        return .close;
    }

    // -- The task form -----------------------------------------------------------

    fn serveTask(t: *TcpConn, burst: *dusty.Burst) anyerror!dusty.Burst.End {
        const o = &t.service.options;
        const window = try t.gpa.alloc(u8, o.read_window);
        defer t.gpa.free(window);
        const r = burst.connection.reader;
        r.buffer = window;
        r.seek = 0;
        r.end = 0;
        t.task_window = window;
        t.burst = burst;
        t.task_writer.interface.buffer = try t.gpa.alloc(u8, o.read_window);
        defer {
            t.gpa.free(t.task_writer.interface.buffer);
            t.task_writer.interface.buffer = &.{};
            r.buffer = &.{};
            r.seek = 0;
            r.end = 0;
            t.burst = null;
        }
        const task = t.service.table.task.?;
        task(t.service.state, &t.conn) catch |err| {
            switch (err) {
                error.Canceled => return err,
                error.Closed, error.EndOfStream, error.IdleTimeout, error.WriteTimeout => {},
                else => if (!t.closed.load(.acquire) and !t.dead) log.warn("tcp {s}: handler failed: {t}", .{ t.info.listener.name, err }),
            }
            t.abort(switch (err) {
                error.IdleTimeout => .idle,
                error.WriteTimeout => .write_timeout,
                error.FrameTooLarge, error.InvalidFrame => .frame,
                else => if (t.over.load(.acquire) != 0) .local else .failed,
            });
            return .close;
        };
        // Returned: closes, after what is queued is out.
        t.flushTaskWriter();
        return t.finishGraceful(burst, r);
    }

    fn flushTaskWriter(t: *TcpConn) void {
        t.task_writer.interface.flush() catch {};
    }

    fn readFrameTask(t: *TcpConn) Conn.ReadError!?[]const u8 {
        if (!t.task_form) return error.NotTaskForm;
        const burst = t.burst orelse return error.NotTaskForm;
        const o = &t.service.options;
        const r = burst.connection.reader;
        while (true) {
            // Frames from the last burst first.
            if (o.framing != .none) {
                if (t.task_frames_at < t.frames.items.len) {
                    defer t.task_frames_at += 1;
                    return t.frames.items[t.task_frames_at];
                }
                t.frames.clearRetainingCapacity();
                t.task_frames_at = 0;
            }
            if (t.over.load(.acquire) != 0 or t.closed.load(.acquire)) return error.Closed;
            burst.deadline = sooner(t.lifetimeAt(), t.idleAt());
            burst.armDeadline();
            r.seek = 0;
            r.end = 0;
            r.fillMore() catch |err| {
                burst.deadline = t.lifetimeAt();
                burst.armDeadline();
                switch (err) {
                    error.EndOfStream => {
                        t.setReason(.peer);
                        t.peer_ended.store(true, .release);
                        return null;
                    },
                    error.ReadFailed => {
                        const cause = burst.connection.getReadError() orelse error.Unexpected;
                        if (cause == error.Canceled) {
                            if (burst.timer.fired()) {
                                burst.connection.clearReadError();
                                const now = std.Io.Clock.Timestamp.now(t.io, .awake);
                                const life = t.lifetimeAt();
                                if (life != null and now.compare(.gte, life.?)) {
                                    t.setReason(.lifetime);
                                    return error.Closed;
                                }
                                return error.IdleTimeout;
                            }
                            return error.Canceled;
                        }
                        if (dusty.Connection.isPeerGone(cause)) t.setReason(.reset);
                        return error.Closed;
                    },
                }
            };
            burst.deadline = t.lifetimeAt();
            burst.armDeadline();
            const bytes = r.buffered();
            r.toss(bytes.len);
            t.last_input = std.Io.Clock.Timestamp.now(t.io, .awake);
            t.bytes_in += bytes.len;
            if (o.framing == .none) return bytes;
            t.decoder.feed(bytes, &t.frames, t.gpa) catch |err| return switch (err) {
                error.FrameTooLarge => error.FrameTooLarge,
                error.InvalidFrame => error.InvalidFrame,
                error.OutOfMemory => error.OutOfMemory,
            };
            t.task_frames_at = 0;
        }
    }
};

/// `Conn.writer`: a buffered writer whose drains go to the outbox.
const TaskWriter = struct {
    conn: *TcpConn,
    interface: std.Io.Writer,

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *TaskWriter = @alignCast(@fieldParentPtr("interface", w));
        const t = self.conn;
        if (w.end > 0) {
            _ = t.queue(&.{w.buffered()}, 0) catch return error.WriteFailed;
            w.end = 0;
        }
        var n: usize = 0;
        if (data.len == 0) return 0;
        for (data[0 .. data.len - 1]) |d| {
            if (d.len > 0) _ = t.queue(&.{d}, 0) catch return error.WriteFailed;
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            if (last.len > 0) _ = t.queue(&.{last}, 0) catch return error.WriteFailed;
            n += last.len;
        }
        return n;
    }
};

fn socketName(fd: std.posix.fd_t) ?std.Io.net.IpAddress {
    if (comptime native_os == .windows) return null;
    var storage: std.Io.Threaded.PosixAddress = undefined;
    var len: std.posix.socklen_t = @sizeOf(std.Io.Threaded.PosixAddress);
    if (std.c.getsockname(fd, &storage.any, &len) != 0) return null;
    if (storage.any.family != std.posix.AF.INET and storage.any.family != std.posix.AF.INET6) return null;
    return dusty.unmapIpv4(std.Io.Threaded.addressFromPosix(&storage));
}
